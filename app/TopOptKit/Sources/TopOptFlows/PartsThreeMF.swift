// PartsThreeMF.swift — B5 (approved design 2026-11-02, ledger note 11, Q10, plan.md §B5): "One 3MF (all parts)".
//
// His words: "We should then be able to export from the Project page only the chosen versions of any part selected and/or
// all parts in the project." One 3MF holds one named object per part ("Carriage Arms · v7b"), each its own triangle mesh,
// laid out in a row on the plate so no two overlap — a slicer opens them as separate, named objects. Written like
// OrganicBeamLattice3MF beside it: a STORED zip (StoredZip, no third library on iOS) with the three parts every 3MF
// carries; read back by this file for its tests.

import Foundation
import simd

public enum PartsThreeMF {
    /// One part: its name, and its indexed triangle mesh in mm (the buffers `OptimizeVariant` / the original model carry).
    public struct Object: Equatable {
        public var name: String
        public var vertices: [Float]
        public var indices: [Int32]
        public init(name: String, vertices: [Float], indices: [Int32]) {
            self.name = name; self.vertices = vertices; self.indices = indices
        }
    }

    /// What a read gives back: each object's name, its counts, and where the build put it.
    public struct ReadObject: Equatable {
        public let name: String
        public let vertexCount: Int
        public let triangleCount: Int
        /// The build item's translation (mm).
        public let offset: SIMD3<Double>
        /// The object's bounds after its build translation.
        public let placedMin: SIMD3<Double>
        public let placedMax: SIMD3<Double>
    }

    /// The gap between neighbours on the plate (mm).
    public static let gap: Double = 10

    // MARK: write

    /// The whole .3mf as bytes. Each object keeps its own coordinates; its build item moves it so its bounds start at
    /// (x, 0, 0), the next one `gap` mm further along x.
    public static func write(_ objects: [Object], title: String) -> Data {
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        x += "<model unit=\"millimeter\" xml:lang=\"en-US\" xmlns=\"\(OrganicBeamLattice3MF.coreNamespace)\">\n"
        x += " <metadata name=\"Title\">\(escape(title))</metadata>\n"
        x += " <metadata name=\"Application\">TopOpt</metadata>\n"
        x += " <resources>\n"
        var items: [(id: Int, offset: SIMD3<Double>)] = []
        var cursor = 0.0
        for (k, o) in objects.enumerated() {
            let id = k + 1
            let n = o.vertices.count / 3
            var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
            for i in 0..<n {
                let p = SIMD3<Double>(Double(o.vertices[3 * i]), Double(o.vertices[3 * i + 1]), Double(o.vertices[3 * i + 2]))
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            }
            if n == 0 { lo = .zero; hi = .zero }
            x += "  <object id=\"\(id)\" name=\"\(escape(o.name))\" type=\"model\">\n   <mesh>\n    <vertices>\n"
            for i in 0..<n {
                x += String(format: "     <vertex x=\"%.6f\" y=\"%.6f\" z=\"%.6f\"/>\n",
                            o.vertices[3 * i], o.vertices[3 * i + 1], o.vertices[3 * i + 2])
            }
            x += "    </vertices>\n    <triangles>\n"
            for t in 0..<(o.indices.count / 3) {
                let a = o.indices[3 * t], b = o.indices[3 * t + 1], c = o.indices[3 * t + 2]
                // the same guard MeshExport's STL takes: a bad index drops its triangle, never the file
                guard [a, b, c].allSatisfy({ $0 >= 0 && Int($0) < n }), a != b, b != c, a != c else { continue }
                x += "     <triangle v1=\"\(a)\" v2=\"\(b)\" v3=\"\(c)\"/>\n"
            }
            x += "    </triangles>\n   </mesh>\n  </object>\n"
            items.append((id, SIMD3(cursor - lo.x, -lo.y, -lo.z)))
            cursor += (hi.x - lo.x) + gap
        }
        x += " </resources>\n <build>\n"
        for it in items {
            x += String(format: "  <item objectid=\"%d\" transform=\"1 0 0 0 1 0 0 0 1 %.6f %.6f %.6f\"/>\n",
                        it.id, it.offset.x, it.offset.y, it.offset.z)
        }
        x += " </build>\n</model>\n"
        let contentTypes = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">\n <Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>\n <Default Extension=\"model\" ContentType=\"application/vnd.ms-package.3dmanufacturing-3dmodel+xml\"/>\n</Types>\n"
        let rels = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n <Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/>\n</Relationships>\n"
        return StoredZip.archive([("[Content_Types].xml", Data(contentTypes.utf8)),
                                  ("_rels/.rels", Data(rels.utf8)),
                                  ("3D/3dmodel.model", Data(x.utf8))])
    }

    // MARK: read

    /// The objects of a .3mf this file wrote (or any core-spec 3MF with plain meshes), in build order; nil if unreadable.
    public static func read(_ data: Data) -> [ReadObject]? {
        guard let entries = StoredZip.entries(data),
              let model = entries.first(where: { $0.name.lowercased().hasSuffix("3dmodel.model") })?.data else { return nil }
        let p = Parser()
        let parser = XMLParser(data: model)
        parser.delegate = p
        guard parser.parse(), !p.failed else { return nil }
        return p.items.compactMap { item in
            guard let o = p.objects[item.id] else { return nil }
            let lo = o.lo + item.offset, hi = o.hi + item.offset
            return ReadObject(name: o.name, vertexCount: o.vertices, triangleCount: o.triangles, offset: item.offset,
                              placedMin: lo, placedMax: hi)
        }
    }

    private final class Parser: NSObject, XMLParserDelegate {
        struct O { var name = ""; var vertices = 0; var triangles = 0
                   var lo = SIMD3<Double>(repeating: .infinity); var hi = SIMD3<Double>(repeating: -.infinity) }
        var objects: [Int: O] = [:]
        var items: [(id: Int, offset: SIMD3<Double>)] = []
        var failed = false
        private var current: Int?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String]) {
            switch name.split(separator: ":").last.map(String.init) ?? name {
            case "object":
                guard let id = a["id"].flatMap(Int.init) else { failed = true; return }
                current = id; objects[id] = O(name: a["name"] ?? "")
            case "vertex":
                guard let c = current, let x = a["x"].flatMap(Double.init), let y = a["y"].flatMap(Double.init),
                      let z = a["z"].flatMap(Double.init) else { failed = true; return }
                guard var o = objects[c] else { failed = true; return }
                o.vertices += 1
                o.lo = simd_min(o.lo, SIMD3(x, y, z)); o.hi = simd_max(o.hi, SIMD3(x, y, z))
                objects[c] = o
            case "triangle":
                if let c = current { objects[c]?.triangles += 1 }
            case "item":
                guard let id = a["objectid"].flatMap(Int.init) else { failed = true; return }
                let t = (a["transform"] ?? "").split(separator: " ").compactMap { Double($0) }
                items.append((id, t.count == 12 ? SIMD3(t[9], t[10], t[11]) : .zero))
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if (name.split(separator: ":").last.map(String.init) ?? name) == "object" { current = nil }
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
