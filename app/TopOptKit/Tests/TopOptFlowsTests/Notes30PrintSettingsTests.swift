// Notes30PrintSettingsTests — ★ notes30 (his word 11-26 12:50, relayed by TOReview): "the print parameters the user set should
// automatically be passed to the 3mf/stl when exporting"; and TOReview's printed grams reads the solid top and bottom skins from
// the job (it assumed 1.0 mm top, 0.6 mm bottom).
//   1. An exported 3MF carries each part's print settings, read back from the file: each object's own, in Bambu Studio's
//      file (Metadata/model_settings.config) and PrusaSlicer's (Metadata/Slic3r_PE_model.config). Core's print file keeps its
//      model part and its painted triangles byte for byte, and its support lines (RED CONTROL: the export as before).
//   2. The TO job carries the solid skins from the part's print settings, as layers and as mm, and core's own schema reads
//      the job (RED CONTROL: the job as before).
import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// The four solid-skin keys out of a job's `loads` (anywhere in the document), so the job pins taken before notes30 still
/// guard every other byte (TopologyStageTests, LatticeStageTests, DesignPrimitivesTests).
enum Notes30PrintSkins {
    static let keys = ["top_solid_layers", "bottom_solid_layers", "top_solid_mm", "bottom_solid_mm"]
    static func without(_ o: Any, key: String? = nil) -> Any {
        if var d = o as? [String: Any] {
            if key == "loads" { for k in keys { d[k] = nil } }
            for (k, v) in d { d[k] = without(v, key: k) }
            return d
        }
        if let a = o as? [Any] { return a.map { without($0) } }
        return o
    }
}

@MainActor
final class Notes30PrintSettingsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes30-print-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        ThreeMFPrintSettings.controlNoSettings = false
        RemoteRun.controlNoSolidSkins = false
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - reading a 3MF back (each entry from its own local header: not the writer's code)

    static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    static func u32(_ b: [UInt8], _ i: Int) -> Int { u16(b, i) | u16(b, i + 2) << 16 }

    static func entries(_ d: Data) throws -> [(name: String, local: Int, data: Data)] {
        let b = [UInt8](d)
        var out: [(name: String, local: Int, data: Data)] = []
        var p = 0
        while p + 30 <= b.count, u32(b, p) == 0x0403_4b50 {
            let method = u16(b, p + 8), csize = u32(b, p + 18), size = u32(b, p + 22), n = u16(b, p + 26), x = u16(b, p + 28)
            let s = p + 30 + n + x
            let raw = Data(b[s..<(s + csize)])
            let body = method == 0 ? raw : try XCTUnwrap((try? (raw as NSData).decompressed(using: .zlib)).map { $0 as Data })
            XCTAssertEqual(body.count, size, "an entry's size")
            out.append((name: String(decoding: b[(p + 30)..<(p + 30 + n)], as: UTF8.self), local: p, data: body))
            p = s + csize
        }
        return out
    }
    static func entry(_ d: Data, _ name: String) throws -> Data? { try entries(d).first { $0.name == name }?.data }

    /// A settings file's objects: [id: [key: value]] (object-level metadata only), and each object's volume's last triangle.
    final class Config: NSObject, XMLParserDelegate {
        var objects: [Int: [String: String]] = [:]
        var lastID: [Int: Int] = [:]
        var counts: [String: Int] = [:]
        private var object: Int?
        private var inPart = false
        init(_ text: Data) {
            super.init()
            let p = XMLParser(data: text)
            p.delegate = self
            XCTAssertTrue(p.parse(), "the settings file parses as XML")
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String]) {
            switch name {
            case "object": object = a["id"].flatMap(Int.init); if let o = object { objects[o] = objects[o] ?? [:] }
            case "volume", "part":
                inPart = true
                if let o = object, let l = a["lastid"].flatMap(Int.init) { lastID[o] = l }
            case "metadata":
                guard let o = object, !inPart, let k = a["key"], let v = a["value"], a["type"] == nil || a["type"] == "object" else { return }
                objects[o]?[k] = v
                counts["\(o)/\(k)", default: 0] += 1
            default: break
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "volume" || name == "part" { inPart = false }
            if name == "object" { object = nil }
        }
    }

    #if os(macOS)
    /// The system's own zip reader checks every entry (its CRC and the index).
    static func unzipTest(_ url: URL) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-tq", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
    #endif

    // MARK: - fixtures

    /// A 10 mm cube: 8 corners, 12 triangles.
    static let cube = ChosenExport.Mesh(
        vertices: [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0, 0, 0, 10, 10, 0, 10, 10, 10, 10, 0, 10, 10],
        indices: [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7])

    /// Core's print file as its streaming writer makes it (threemf_stream.cpp, indexed + deflated, painted: the two
    /// settings files after the model, word for word), from the cube. `painted`: its first two triangles painted.
    static func coreFile(painted: Bool) -> (file: Data, settingsAt: Int?) {
        let ns: String = painted ? " xmlns:slic3rpe=\"http://schemas.slic3r.org/3mf/2017/06\"" : ""
        let head: [String] = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n<model unit=\"millimeter\" xml:lang=\"en-US\" ",
                              "xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\"", ns,
                              ">\r\n <resources>\r\n  <object id=\"1\" type=\"model\">\r\n   <mesh>\r\n    <vertices>\r\n"]
        var m = head.joined()
        for i in 0..<8 {
            m += String(format: "     <vertex x=\"%.6f\" y=\"%.6f\" z=\"%.6f\"/>\r\n",
                        cube.vertices[3 * i], cube.vertices[3 * i + 1], cube.vertices[3 * i + 2])
        }
        m += "    </vertices>\r\n    <triangles>\r\n"
        for t in 0..<12 {
            let paint = painted && t < 2 ? " paint_supports=\"4\" slic3rpe:custom_supports=\"4\"" : ""
            m += "     <triangle v1=\"\(cube.indices[3 * t])\" v2=\"\(cube.indices[3 * t + 1])\" v3=\"\(cube.indices[3 * t + 2])\"\(paint)/>\r\n"
        }
        m += "    </triangles>\r\n   </mesh>\r\n  </object>\r\n </resources>\r\n <build>\r\n  <item objectid=\"1\"/>\r\n </build>\r\n</model>\r\n"
        var parts: [(String, Data, Bool)] = [
            ("[Content_Types].xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n<Types/>".utf8), false),
            ("_rels/.rels", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n<Relationships/>".utf8), false),
            ("3D/3dmodel.model", Data(m.utf8), true)]
        if painted {
            let bambu: [String] = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<config>\n  <object id=\"1\">\n",
                                   "    <metadata key=\"name\" value=\"lattice\"/>\n    <metadata key=\"enable_support\" value=\"1\"/>\n",
                                   "    <metadata key=\"support_type\" value=\"tree(manual)\"/>\n  </object>\n</config>\n"]
            let prusa: [String] = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<config>\n",
                                   " <object id=\"1\" instances_count=\"1\">\n  <metadata type=\"object\" key=\"name\" value=\"lattice\"/>\n",
                                   "  <metadata type=\"object\" key=\"support_material\" value=\"1\"/>\n",
                                   "  <metadata type=\"object\" key=\"support_material_auto\" value=\"0\"/>\n  <volume firstid=\"0\" lastid=\"11\">\n",
                                   "   <metadata type=\"volume\" key=\"name\" value=\"lattice\"/>\n  </volume>\n </object>\n</config>\n"]
            parts.append((ThreeMFPrintSettings.bambuFile, Data(bambu.joined().utf8), false))
            parts.append((ThreeMFPrintSettings.prusaFile, Data(prusa.joined().utf8), false))
        }
        func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func le32(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }
        var out = Data(), cd = Data()
        var settingsAt: Int?
        for (name, data, deflate) in parts {
            let body = deflate ? ((try? (data as NSData).compressed(using: .zlib)).map { $0 as Data } ?? data) : data
            let n = Data(name.utf8), crc = Int(StoredZip.crc32(data)), method = deflate ? 8 : 0, at = out.count
            if name == ThreeMFPrintSettings.bambuFile { settingsAt = at }
            let local: [Data] = [le32(0x0403_4b50), le16(20), le16(0), le16(method), le16(0), le16(0), le32(crc), le32(body.count),
                                 le32(data.count), le16(n.count), le16(0), n, body]
            let central: [Data] = [le32(0x0201_4b50), le16(20), le16(20), le16(0), le16(method), le16(0), le16(0), le32(crc),
                                   le32(body.count), le32(data.count), le16(n.count), le16(0), le16(0), le16(0), le16(0), le32(0),
                                   le32(at), n]
            local.forEach { out.append($0) }
            central.forEach { cd.append($0) }
        }
        let cdAt = out.count
        let end: [Data] = [cd, le32(0x0605_4b50), le16(0), le16(0), le16(parts.count), le16(parts.count), le32(cd.count), le32(cdAt), le16(0)]
        end.forEach { out.append($0) }
        return (out, settingsAt)
    }

    /// His kind of settings, none of them the defaults.
    static var his: PrintParams {
        var p = PrintParams.fdmDefault
        p.layerHeightMM = 0.16; p.wallLoops = 2; p.topLayers = 6; p.bottomLayers = 3
        p.infillPercent = 35; p.infillPattern = "lines"; p.wallLineWidthOuterMM = 0.4; p.wallLineWidthInnerMM = 0.44
        return p
    }

    // MARK: - 1 · the exported 3MF carries the part's print settings

    func testAnExported3MFCarriesEachPartsPrintSettings() throws {
        let a = Self.his
        var b = PrintParams.fdmDefault
        b.wallLoops = 4; b.infillPercent = 15; b.infillPattern = "honeycomb"
        let lines = [ChosenExportLine(partID: UUID(), name: "Arm", tag: "v2a", folder: UUID(), result: 0, latticed: false),
                     ChosenExportLine(partID: UUID(), name: "Base", tag: nil, folder: UUID(), result: nil, latticed: false)]

        // (a) the Library's one 3MF for all parts: each object its own part's settings
        func export(control: Bool) throws -> (Data, URL) {
            ThreeMFPrintSettings.controlNoSettings = control
            defer { ThreeMFPrintSettings.controlNoSettings = false }
            let urls = try ChosenExport.write(lines, format: .oneThreeMF, title: "Rig",
                                              into: dir.appendingPathComponent(UUID().uuidString, isDirectory: true),
                                              params: { $0.name == "Arm" ? a : b }) { _ in Self.cube }
            return (try Data(contentsOf: urls[0]), urls[0])
        }
        let (file, url) = try export(control: false)
        let (before, _) = try export(control: true)
        let cdBefore = Self.u32([UInt8](before), before.count - 6)
        XCTAssertEqual(file.prefix(cdBefore), before.prefix(cdBefore), "★ every byte before the index as it was: the shapes untouched")
        let bambu = Config(try XCTUnwrap(try Self.entry(file, ThreeMFPrintSettings.bambuFile), "★ Bambu Studio's settings file"))
        let prusa = Config(try XCTUnwrap(try Self.entry(file, ThreeMFPrintSettings.prusaFile), "★ PrusaSlicer's settings file"))
        let arm = try XCTUnwrap(bambu.objects[1]), base = try XCTUnwrap(bambu.objects[2])
        XCTAssertEqual(arm["layer_height"], "0.16"); XCTAssertEqual(arm["wall_loops"], "2")
        XCTAssertEqual(arm["top_shell_layers"], "6"); XCTAssertEqual(arm["bottom_shell_layers"], "3")
        XCTAssertEqual(arm["sparse_infill_density"], "35%"); XCTAssertEqual(arm["sparse_infill_pattern"], "line", "\"lines\" is \"line\"")
        XCTAssertEqual(arm["outer_wall_line_width"], "0.4"); XCTAssertEqual(arm["inner_wall_line_width"], "0.44")
        XCTAssertEqual(arm["name"], "Arm · v2a", "the object's own name")
        XCTAssertEqual(base["wall_loops"], "4", "★ the second part its own"); XCTAssertEqual(base["sparse_infill_pattern"], "honeycomb")
        XCTAssertEqual(base["sparse_infill_density"], "15%")
        XCTAssertEqual(prusa.objects[1]?["perimeters"], "2"); XCTAssertEqual(prusa.objects[1]?["top_solid_layers"], "6")
        XCTAssertEqual(prusa.objects[1]?["fill_density"], "35%"); XCTAssertEqual(prusa.objects[1]?["fill_pattern"], "line")
        XCTAssertEqual(prusa.objects[1]?["external_perimeter_extrusion_width"], "0.4")
        XCTAssertEqual(prusa.objects[2]?["perimeters"], "4")
        XCTAssertEqual(prusa.lastID, [1: 11, 2: 11], "★ PrusaSlicer's volume names every triangle of each object")
        XCTAssertEqual(PartsThreeMF.read(file)?.map(\.triangleCount), [12, 12], "the file still reads: two objects, 12 triangles each")
        // RED CONTROL: the export as before — no settings in the file
        XCTAssertNil(try Self.entry(before, ThreeMFPrintSettings.bambuFile), "RED CONTROL: no Bambu settings file")
        XCTAssertNil(try Self.entry(before, ThreeMFPrintSettings.prusaFile), "RED CONTROL: no PrusaSlicer settings file")

        // (b) core's print file, painted (Results' Export, the print file's Share, another resolution): merged with its support
        // lines; the model part and its painted triangles byte for byte
        let core = Self.coreFile(painted: true)
        let coreURL = dir.appendingPathComponent("print.3mf")
        try core.file.write(to: coreURL)
        XCTAssertTrue(try ThreeMFPrintSettings.stamp(coreURL, params: a), "stamped")
        XCTAssertTrue(try ThreeMFPrintSettings.stamp(coreURL, params: a), "a second time: replaced, never doubled")
        let stamped = try Data(contentsOf: coreURL)
        let cut = try XCTUnwrap(core.settingsAt)
        XCTAssertEqual(stamped.prefix(cut), core.file.prefix(cut), "★ the model part (deflated, painted) byte for byte")
        let model = String(decoding: try XCTUnwrap(try Self.entry(stamped, "3D/3dmodel.model")), as: UTF8.self)
        XCTAssertEqual(model.components(separatedBy: "paint_supports=\"4\"").count - 1, 2, "★ the painted triangles kept")
        let cb = Config(try XCTUnwrap(try Self.entry(stamped, ThreeMFPrintSettings.bambuFile)))
        let cp = Config(try XCTUnwrap(try Self.entry(stamped, ThreeMFPrintSettings.prusaFile)))
        XCTAssertEqual(cb.objects[1]?["enable_support"], "1", "★ core's support lines kept")
        XCTAssertEqual(cb.objects[1]?["support_type"], "tree(manual)")
        XCTAssertEqual(cb.objects[1]?["wall_loops"], "2"); XCTAssertEqual(cb.objects[1]?["top_shell_layers"], "6")
        XCTAssertEqual(cb.counts["1/wall_loops"], 1, "★ once, after two stamps")
        XCTAssertEqual(cp.objects[1]?["support_material"], "1"); XCTAssertEqual(cp.objects[1]?["perimeters"], "2")
        XCTAssertEqual(cp.counts["1/perimeters"], 1)
        XCTAssertEqual(cp.lastID, [1: 11], "core's volume kept")
        // core's print file with nothing painted: both files made, its triangles counted through the deflated model
        let plain = dir.appendingPathComponent("plain.3mf")
        try Self.coreFile(painted: false).file.write(to: plain)
        XCTAssertTrue(try ThreeMFPrintSettings.stamp(plain, params: a))
        let pp = Config(try XCTUnwrap(try Self.entry(try Data(contentsOf: plain), ThreeMFPrintSettings.prusaFile)))
        XCTAssertEqual(pp.lastID, [1: 11], "★ 12 triangles read from the deflated model")
        XCTAssertEqual(pp.objects[1]?["bottom_solid_layers"], "3")
        #if os(macOS)
        for u in [url, coreURL, plain] { XCTAssertEqual(try Self.unzipTest(u), 0, "the system's unzip checks \(u.lastPathComponent)") }
        #endif
        // RED CONTROL: core's file as before — nothing stamped, its settings file has no print settings
        let red = dir.appendingPathComponent("red.3mf")
        try core.file.write(to: red)
        ThreeMFPrintSettings.controlNoSettings = true
        XCTAssertFalse(try ThreeMFPrintSettings.stamp(red, params: a))
        ThreeMFPrintSettings.controlNoSettings = false
        XCTAssertNil(Config(try XCTUnwrap(try Self.entry(try Data(contentsOf: red), ThreeMFPrintSettings.bambuFile))).objects[1]?["wall_loops"],
                     "RED CONTROL: no print settings")
        let bambuOne: [String: String] = cb.objects[1] ?? [:]
        print("NOTES30-3MF library: \(file.count) bytes (was \(before.count)), arm \(arm.count) keys, base \(base.count)")
        print("NOTES30-3MF core painted: \(stamped.count) bytes (was \(core.file.count)) · Bambu object 1 \(bambuOne)")
    }

    // MARK: - 2 · the TO job carries the solid skins

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String { repoRoot.appendingPathComponent("core/\(rel)").path }

    func testTheTOJobCarriesTheSolidSkinsFromThePrintSettings() throws {
        let m = AppModel(materialsPath: Self.core("src/materials/materials.json"), rulesPath: Self.core("src/settings/rules.json"),
                         store: ProjectStore(rootDir: dir.appendingPathComponent("store", isDirectory: true)))
        m.loadMaterials()
        m.newTopOpt()
        m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.core("tests/fixtures/stl/cube_10mm.stl"), displayName: "Bracket.stl"))
        m.continueToWorkspace()
        let p = try XCTUnwrap(m.project)
        let anchor = p.selection.addGroup()
        p.selection.pickFace(10)
        p.force.makeAnchor(anchor)
        let load = p.selection.addGroup()
        p.selection.pickFace(20)
        p.force.makeLoad(load)
        p.force.setWeight(load, kg: 4.2)
        p.force.sync(groups: p.selection.groups)
        p.printParams = Self.his   // 0.16 mm layers, 6 top, 3 bottom

        func job() throws -> (raw: Data, loads: [String: Any]) {
            let raw = try RemoteRun.buildJobJSON(try XCTUnwrap(m.makeRunRequest(), "the Topology request"))
            let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
            return (raw, try XCTUnwrap(o["loads"] as? [String: Any]))
        }
        let now = try job()
        XCTAssertEqual(now.loads["top_solid_layers"] as? Int, 6, "★ the top layers he set")
        XCTAssertEqual(now.loads["bottom_solid_layers"] as? Int, 3, "★ the bottom layers he set")
        XCTAssertEqual(now.loads["top_solid_mm"] as? Double ?? -1, 0.96, accuracy: 1e-9, "★ 6 × 0.16 mm")
        XCTAssertEqual(now.loads["bottom_solid_mm"] as? Double ?? -1, 0.48, accuracy: 1e-9, "★ 3 × 0.16 mm")
        XCTAssertEqual(now.loads["layer_height_mm"] as? Double ?? -1, 0.16, accuracy: 1e-12, "★ the layer height he set")
        XCTAssertNil(TopOptKit.jobSchemaError(now.raw), "★ core's own schema reads the job")
        // core reads the values: a negative count is refused, and so is a key it does not know (the schema check is live)
        func with(_ key: String, _ value: Any) throws -> Data {
            var o = try XCTUnwrap(try JSONSerialization.jsonObject(with: now.raw) as? [String: Any])
            var l = now.loads
            l[key] = value
            o["loads"] = l
            return try JSONSerialization.data(withJSONObject: o)
        }
        XCTAssertNotNil(TopOptKit.jobSchemaError(try with("top_solid_layers", -1)), "core checks the count")
        XCTAssertNotNil(TopOptKit.jobSchemaError(try with("top_solid_layerz", 6)), "CONTROL: core refuses a key it does not know")
        // RED CONTROL: the job as before notes30 — no skins
        RemoteRun.controlNoSolidSkins = true
        let before = try job()
        RemoteRun.controlNoSolidSkins = false
        for k in Notes30PrintSkins.keys { XCTAssertNil(before.loads[k], "RED CONTROL: no \(k)") }
        let nowWords: [String] = Notes30PrintSkins.keys.map { k in "\(k) \(String(describing: now.loads[k] ?? "none"))" }
        let beforeWords: [String] = Notes30PrintSkins.keys.map { k in String(describing: before.loads[k] ?? "none") }
        let layer = String(describing: now.loads["layer_height_mm"] ?? "none")
        print("NOTES30-JOB loads: \(nowWords.joined(separator: ", ")) · layer \(layer) · before: \(beforeWords.joined(separator: "/"))")
    }
}
