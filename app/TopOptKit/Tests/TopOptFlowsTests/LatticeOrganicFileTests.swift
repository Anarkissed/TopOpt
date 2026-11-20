// LatticeOrganicFileTests — ★ ORGANIC CUT 2, the export (his 11-18: "Export as its own install"; organic-cut2-handover.md, f):
//   * core's 3MF read back by the app's own small reader (CoreThreeMF), stored and deflated, for the Results screen's mesh;
//   * the Organic print file made FOR REAL by core's run_file_job from the app's own job (every organic_* key the engine reads,
//     the woven areas, the stress beside it), the same lattice the preview laid (bar for bar), read back as a mesh.
// RED CONTROLS: a damaged 3MF is refused; a 3MF with no model is refused; the job with the layout's own (cell) stress reference
// lays a different lattice than the preview's.
import XCTest
import Compression
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class LatticeOrganicFileTests: XCTestCase {

    // MARK: the reader

    /// A zip as core's writer makes it: each entry stored, or (`deflate`) raw-deflated; no data descriptors.
    static func zip(_ entries: [(String, Data, Bool)]) -> Data {
        var out = Data(), central = Data()
        func le16(_ v: Int, _ d: inout Data) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        func le32(_ v: Int, _ d: inout Data) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        for (name, raw, deflate) in entries {
            let body = deflate ? Self.deflate(raw) : raw
            let offset = out.count, n = Data(name.utf8)
            le32(0x0403_4b50, &out); le16(20, &out); le16(0, &out); le16(deflate ? 8 : 0, &out); le16(0, &out); le16(0, &out)
            le32(0, &out); le32(body.count, &out); le32(raw.count, &out); le16(n.count, &out); le16(0, &out)
            out.append(n); out.append(body)
            le32(0x0201_4b50, &central); le16(20, &central); le16(20, &central); le16(0, &central); le16(deflate ? 8 : 0, &central)
            le16(0, &central); le16(0, &central); le32(0, &central); le32(body.count, &central); le32(raw.count, &central)
            le16(n.count, &central); le16(0, &central); le16(0, &central); le16(0, &central); le16(0, &central); le32(0, &central)
            le32(offset, &central); central.append(n)
        }
        let cdOffset = out.count
        out.append(central)
        le32(0x0605_4b50, &out); le16(0, &out); le16(0, &out); le16(entries.count, &out); le16(entries.count, &out)
        le32(central.count, &out); le32(cdOffset, &out); le16(0, &out)
        return out
    }

    static func deflate(_ raw: Data) -> Data {
        let cap = raw.count + 1024
        var dst = [UInt8](repeating: 0, count: cap)
        let n = raw.withUnsafeBytes { src in
            compression_encode_buffer(&dst, cap, src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
        }
        return Data(dst[0..<n])
    }

    /// A model part as core writes it: \r\n lines, %.6f numbers.
    static func model(_ verts: [SIMD3<Float>], _ tris: [(Int, Int, Int)]) -> Data {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n<model unit=\"millimeter\">\r\n <resources>\r\n  <object id=\"1\" type=\"model\">\r\n   <mesh>\r\n    <vertices>\r\n"
        for v in verts { s += String(format: "     <vertex x=\"%.6f\" y=\"%.6f\" z=\"%.6f\"/>\r\n", v.x, v.y, v.z) }
        s += "    </vertices>\r\n    <triangles>\r\n"
        for t in tris { s += "     <triangle v1=\"\(t.0)\" v2=\"\(t.1)\" v3=\"\(t.2)\"/>\r\n" }
        s += "    </triangles>\r\n   </mesh>\r\n  </object>\r\n </resources>\r\n <build><item objectid=\"1\"/></build>\r\n</model>\r\n"
        return Data(s.utf8)
    }

    func testCoreThreeMFReadsBackStoredAndDeflated() throws {
        // a tetrahedron, one coordinate negative, and enough copies that the deflated part spans several 1 MB chunks
        let base: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(10.5, 0, 0), SIMD3(0, -7.25, 0), SIMD3(0, 0, 3.125)]
        var verts: [SIMD3<Float>] = [], tris: [(Int, Int, Int)] = []
        for k in 0..<20_000 {
            let o = SIMD3<Float>(Float(k % 100), Float(k / 100), 0)
            let b = verts.count
            verts += base.map { $0 + o }
            tris += [(b, b + 1, b + 2), (b, b + 1, b + 3), (b, b + 2, b + 3), (b + 1, b + 2, b + 3)]
        }
        let part = Self.model(verts, tris)
        XCTAssertGreaterThan(part.count, 3 << 20, "premise: the model spans several chunks")
        for deflate in [false, true] {
            let file = Self.zip([("[Content_Types].xml", Data("<Types/>".utf8), false), ("_rels/.rels", Data("<R/>".utf8), false),
                                 ("3D/3dmodel.model", part, deflate)])
            let m = try CoreThreeMF.mesh(file)
            XCTAssertEqual(m.indices.count, 3 * tris.count, "★ every triangle (\(deflate ? "deflated" : "stored"))")
            XCTAssertEqual(m.vertices.count, 3 * verts.count, "★ every point")
            XCTAssertEqual(m.vertices[3 * 2 + 1], -7.25, accuracy: 1e-6, "★ a negative coordinate")
            XCTAssertEqual(m.vertices[3 * 1 + 0], 10.5, accuracy: 1e-6)
            XCTAssertEqual(Array(m.indices[3..<6]), [0, 1, 3])
            XCTAssertEqual(m.vertices[3 * (4 * 1999 + 3) + 1], Float(19), accuracy: 1e-6, "a far copy, read where it is")
        }
        // RED CONTROLS
        var cut = Self.zip([("3D/3dmodel.model", part, true)])
        cut = cut.prefix(cut.count / 2)
        XCTAssertThrowsError(try CoreThreeMF.mesh(cut), "a damaged file is refused")
        XCTAssertThrowsError(try CoreThreeMF.mesh(Self.zip([("[Content_Types].xml", Data("<Types/>".utf8), false)])),
                             "a 3MF with no model is refused")
        let bad = Self.model(base, [(0, 1, 9)])
        XCTAssertThrowsError(try CoreThreeMF.mesh(Self.zip([("3D/3dmodel.model", bad, false)])), "a triangle naming a missing point")
    }

    // MARK: the Organic file, made for real

    /// The sample cube woven whole (a box zone, Grown, its synthetic stress), laid EXACT through the session as the preview lays
    /// it; then the app's own job for it made here by core's run_file_job, and read back.
    @MainActor
    func testTheOrganicFileIsThePreviewsLatticeAndReadsBack() async throws {
        let body = try TopOptKit.latticeSampleBody(cube: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("organic-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent("cube.stl")
        try MeshExport.binarySTL(vertices: body.vertices, indices: body.indices, header: Data()).write(to: model)
        let session = try await LatticeLayoutSession.open(path: model.path)
        addTeardownBlock { session.close() }
        let b = try XCTUnwrap(LatticeLayoutPreview.box(body.vertices))
        var s = LatticeLayoutSession.Settings()
        s.beadMM = 0.45
        s.minStrutLines = 2
        var r = LatticeLayoutSession.Region(id: 1, faces: [], depthMM: 0)
        r.zone = .init(kind: .box, centre: SIMD3<Double>((b.lo + b.hi) / 2), axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                       half: SIMD3<Double>((b.hi - b.lo) / 2) + 1)
        r.weave = true
        s.regions = [r]
        s.bedFloorMM = 0.8
        let lim = try await session.sweepLimits(s, regions: [1], lineMM: 0.45).map(LatticeOrganicLook.Limits.init)
        var look = LatticeOrganicLook()
        look.mode = .grown
        var ask = look.ask(limits: lim, layerMM: 0.2, aesthetic: true)
        ask.quality = .exact
        let groups = [LatticeLayoutSession.OrganicGroup(regions: [1], ask: ask)]
        let made = try await session.synthetic(s, groups: groups, walls: [(region: 1, foci: 1)], fromEmpty: true)
        XCTAssertTrue(made.refused.isEmpty)
        let laid = try await session.layOrganic(s, groups: groups)
        XCTAssertTrue(laid.refused.isEmpty, "\(laid.refused.map(\.text))")
        let previewBars = laid.layout.bars.count / 7
        let tensor = try await session.tensorFile()
        XCTAssertEqual(String(data: tensor.prefix(8), encoding: .ascii), "TOTENSOR", "★ core's stress file, the filled stress")

        let json = try LatticeFileJob.build(s, modelName: "cube.stl", organic: groups, tensor: LatticeFileJob.tensorName)
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(doc["file_format"] as? String, "3mf", "★ a 3MF")
        XCTAssertEqual(doc["tensor"] as? String, LatticeFileJob.tensorName)
        let layout = try XCTUnwrap(doc["layout"] as? [String: Any])
        XCTAssertEqual(layout["region_weave"] as? [Bool], [true])
        XCTAssertEqual(layout["organic_mode"] as? String, "grown")
        XCTAssertEqual(layout["organic_strand_keep"] as? Double, 0.9, "★ his switch reaches the file: on in Aesthetic")
        XCTAssertEqual(layout["reference_mpa"] as? Double, 0, "★ the weave's own reference, as the preview laid it")

        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let materials = core.appendingPathComponent("src/materials/materials.json").path
        let rules = core.appendingPathComponent("src/settings/rules.json").path
        let job = LatticeFileJob.ForPart(json: json, modelPath: model.path, demand: nil, tensor: tensor)
        let t0 = Date()
        let file = try LatticeFileButton.runHere(job: job, strengthJob: nil, materialsPath: materials, rulesPath: rules)
        print(String(format: "ORGANIC-FILE cube Grown: %@ %d bytes, %d bars (preview %d), made in %.1f s", file.report.fileName,
                     file.stl.count, file.report.bars, previewBars, Date().timeIntervalSince(t0)))
        XCTAssertTrue(file.report.isThreeMF, "★ the file is a 3MF: \(file.report.fileName)")
        XCTAssertEqual(file.report.slicerSupports, "off", "★ separate tubes: slice with supports off")
        XCTAssertTrue(file.report.line.contains("supports off"), "and the bar says so: \(file.report.line)")
        XCTAssertEqual(file.report.bars, previewBars, "★ the file is the lattice the preview laid, bar for bar")
        let o = try LatticeFileButton.outcome(file, densityGCm3: 1.24)
        XCTAssertGreaterThan(o.variants.first?.meshIndices.count ?? 0, 1000, "★ the 3MF read back as the Results screen's mesh")

        // RED CONTROL: the layout's own (cell) reference lays a different lattice
        var cellRef = s
        cellRef.referenceMPa = 40
        var wrong = try XCTUnwrap(try JSONSerialization.jsonObject(with: LatticeFileJob.build(cellRef, modelName: "cube.stl",
                                                                                              organic: groups, tensor: LatticeFileJob.tensorName)) as? [String: Any])
        var wl = try XCTUnwrap(wrong["layout"] as? [String: Any])
        wl["reference_mpa"] = 40
        wrong["layout"] = wl
        let other = try LatticeFileButton.runHere(job: .init(json: try JSONSerialization.data(withJSONObject: wrong, options: [.sortedKeys]),
                                                             modelPath: model.path, demand: nil, tensor: tensor),
                                                  strengthJob: nil, materialsPath: materials, rulesPath: rules)
        XCTAssertNotEqual(other.report.bars, previewBars, "RED CONTROL: a stated 40 MPa reference lays another lattice")
    }
}
