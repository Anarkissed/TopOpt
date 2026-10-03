// OrganicBeamLattice3MF.swift — an organic lattice's EMITTED SPANS as a 3MF beam
// lattice (maintainer, 2026-09-04: "editable 3mf files that can have thickness modified
// live — but having cell sizes and any grading already baked in").
//
// The 3MF Beam Lattice Extension (namespace
// http://schemas.microsoft.com/3dmanufacturing/beamlattice/2017/02) stores exactly what
// core emits: vertices, and beams between them with a radius per end. So a cached
// variant IS a standard file: the topology (cell size, grading, traced/grown, shape fit)
// is baked into the beams; the radius is the one number a viewer may change live.
//
// ★ Written and read by this file alone — a STORED zip (no compression, so no third
// library is needed on iOS) holding the three parts every 3MF must carry. Consumer
// slicers ignore beam lattices; what prints is still the welded STL the run writes. This
// is the cache and hand-off format, not the print file.
import Foundation
import simd

public enum OrganicBeamLattice3MF {
    public typealias Span = (a: SIMD3<Double>, b: SIMD3<Double>, r: Double)

    public struct Document: Equatable {
        public var spans: [Span]
        /// Free-form `<metadata name=…>` entries — the census, the picks, core's SHA.
        public var metadata: [String: String]
        public init(spans: [Span], metadata: [String: String]) { self.spans = spans; self.metadata = metadata }
        public static func == (a: Document, b: Document) -> Bool {
            a.metadata == b.metadata && a.spans.count == b.spans.count
                && zip(a.spans, b.spans).allSatisfy { $0.a == $1.a && $0.b == $1.b && $0.r == $1.r }
        }
        public var totalLengthMM: Double { spans.reduce(0) { $0 + simd_length($1.b - $1.a) } }
    }

    public static let beamLatticeNamespace = "http://schemas.microsoft.com/3dmanufacturing/beamlattice/2017/02"
    public static let coreNamespace = "http://schemas.microsoft.com/3dmanufacturing/core/2015/02"

    // MARK: write

    /// The whole .3mf as bytes. Vertices are welded on position (1 µm) so shared span
    /// ends are one vertex, which is what makes the beam graph a graph.
    public static func write(_ doc: Document, name: String = "organic lattice") -> Data {
        var verts: [SIMD3<Double>] = []
        var index: [SIMD3<Int64>: Int] = [:]
        func vid(_ p: SIMD3<Double>) -> Int {
            let key = SIMD3<Int64>(Int64((p.x * 1e6).rounded()), Int64((p.y * 1e6).rounded()), Int64((p.z * 1e6).rounded()))
            if let i = index[key] { return i }
            let i = verts.count; verts.append(p); index[key] = i; return i
        }
        var beams: [(Int, Int, Double)] = []
        beams.reserveCapacity(doc.spans.count)
        for s in doc.spans where s.r > 0 {
            let i = vid(s.a), j = vid(s.b)
            if i != j { beams.append((i, j, s.r)) }
        }
        let rDefault = beams.first?.2 ?? 0.21
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        x += "<model unit=\"millimeter\" xml:lang=\"en-US\" xmlns=\"\(coreNamespace)\" xmlns:b=\"\(beamLatticeNamespace)\" requiredextensions=\"b\">\n"
        for (k, v) in doc.metadata.sorted(by: { $0.key < $1.key }) {
            x += " <metadata name=\"\(escape(k))\">\(escape(v))</metadata>\n"
        }
        x += " <resources>\n  <object id=\"1\" name=\"\(escape(name))\" type=\"model\">\n   <mesh>\n    <vertices>\n"
        for v in verts { x += String(format: "     <vertex x=\"%.6f\" y=\"%.6f\" z=\"%.6f\"/>\n", v.x, v.y, v.z) }
        x += "    </vertices>\n    <triangles/>\n"
        x += String(format: "    <b:beamlattice minlength=\"0.0001\" radius=\"%.6f\" clippingmode=\"none\" cap=\"sphere\">\n     <b:beams>\n", rDefault)
        for (i, j, r) in beams { x += String(format: "      <b:beam v1=\"%d\" v2=\"%d\" r1=\"%.6f\" r2=\"%.6f\"/>\n", i, j, r, r) }
        x += "     </b:beams>\n    </b:beamlattice>\n   </mesh>\n  </object>\n </resources>\n <build>\n  <item objectid=\"1\"/>\n </build>\n</model>\n"
        let contentTypes = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">\n <Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>\n <Default Extension=\"model\" ContentType=\"application/vnd.ms-package.3dmanufacturing-3dmodel+xml\"/>\n</Types>\n"
        let rels = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n <Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/>\n</Relationships>\n"
        return StoredZip.archive([("[Content_Types].xml", Data(contentTypes.utf8)),
                                  ("_rels/.rels", Data(rels.utf8)),
                                  ("3D/3dmodel.model", Data(x.utf8))])
    }

    // MARK: read

    public static func read(_ data: Data) -> Document? {
        guard let entries = StoredZip.entries(data),
              let model = entries.first(where: { $0.name.lowercased().hasSuffix("3dmodel.model") })?.data
        else { return nil }
        let p = ModelParser()
        let parser = XMLParser(data: model)
        parser.delegate = p
        guard parser.parse(), !p.failed else { return nil }
        var spans: [Span] = []
        spans.reserveCapacity(p.beams.count)
        for b in p.beams {
            guard b.v1 >= 0, b.v1 < p.verts.count, b.v2 >= 0, b.v2 < p.verts.count else { return nil }
            let r = b.r1 ?? p.defaultRadius
            spans.append((a: p.verts[b.v1], b: p.verts[b.v2], r: r))
        }
        return Document(spans: spans, metadata: p.metadata)
    }

    private final class ModelParser: NSObject, XMLParserDelegate {
        var verts: [SIMD3<Double>] = []
        var beams: [(v1: Int, v2: Int, r1: Double?)] = []
        var metadata: [String: String] = [:]
        var defaultRadius = 0.21
        var failed = false
        private var metaName: String?
        private var metaText = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            switch local {
            case "vertex":
                guard let x = a["x"].flatMap(Double.init), let y = a["y"].flatMap(Double.init),
                      let z = a["z"].flatMap(Double.init) else { failed = true; return }
                verts.append(SIMD3(x, y, z))
            case "beamlattice":
                if let r = a["radius"].flatMap(Double.init) { defaultRadius = r }
            case "beam":
                guard let v1 = a["v1"].flatMap(Int.init), let v2 = a["v2"].flatMap(Int.init) else { failed = true; return }
                beams.append((v1, v2, a["r1"].flatMap(Double.init)))
            case "metadata":
                metaName = a["name"]; metaText = ""
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters s: String) { if metaName != nil { metaText += s } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            if local == "metadata", let k = metaName { metadata[k] = metaText; metaName = nil }
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// A minimal STORED (method 0) zip writer/reader — enough for the three parts of a 3MF.
enum StoredZip {
    static func archive(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data(); var central = Data(); var offsets: [UInt32] = []
        for f in files {
            offsets.append(UInt32(out.count))
            let name = Data(f.name.utf8); let crc = crc32(f.data); let n = UInt32(f.data.count)
            out.append(le32(0x04034b50)); out.append(le16(20)); out.append(le16(0)); out.append(le16(0))
            out.append(le16(0)); out.append(le16(0x21)); out.append(le32(crc)); out.append(le32(n)); out.append(le32(n))
            out.append(le16(UInt16(name.count))); out.append(le16(0)); out.append(name); out.append(f.data)
        }
        for (i, f) in files.enumerated() {
            let name = Data(f.name.utf8); let crc = crc32(f.data); let n = UInt32(f.data.count)
            central.append(le32(0x02014b50)); central.append(le16(20)); central.append(le16(20)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le16(0x21)); central.append(le32(crc))
            central.append(le32(n)); central.append(le32(n)); central.append(le16(UInt16(name.count)))
            central.append(le16(0)); central.append(le16(0)); central.append(le16(0)); central.append(le16(0))
            central.append(le32(0)); central.append(le32(offsets[i])); central.append(name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.append(le32(0x06054b50)); out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(files.count))); out.append(le16(UInt16(files.count)))
        out.append(le32(UInt32(central.count))); out.append(le32(cdOffset)); out.append(le16(0))
        return out
    }

    static func entries(_ d: Data) -> [(name: String, data: Data)]? {
        var out: [(String, Data)] = []; var p = 0
        let b = [UInt8](d)
        while p + 30 <= b.count, rd32(b, p) == 0x04034b50 {
            let method = rd16(b, p + 8); let n = Int(rd32(b, p + 18))
            let nameLen = Int(rd16(b, p + 26)), extraLen = Int(rd16(b, p + 28))
            guard method == 0, p + 30 + nameLen + extraLen + n <= b.count else { return nil }
            let name = String(decoding: b[(p + 30)..<(p + 30 + nameLen)], as: UTF8.self)
            let start = p + 30 + nameLen + extraLen
            out.append((name, Data(b[start..<(start + n)])))
            p = start + n
        }
        return out.isEmpty ? nil : out
    }

    private static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8)]) }
    private static func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)]) }
    private static func rd16(_ b: [UInt8], _ p: Int) -> UInt16 { UInt16(b[p]) | UInt16(b[p + 1]) << 8 }
    private static func rd32(_ b: [UInt8], _ p: Int) -> UInt32 { UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24 }
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i); for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }; return c
    }
    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in d { c = table[Int((c ^ UInt32(byte)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}
