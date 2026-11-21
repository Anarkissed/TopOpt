// OrganicVineRunsProbe — OPT-IN (VINE_RUNS_DIR=<folder>): his 11-19 note "redo the entirety of how you generate the organic
// vines ... show me an image first". Writes the engine's own runs (centre-line points and widths, as core's preview gives
// them) for the Lattice page's samples, so the vine look can be prototyped on the real lay outside the app. Writes only to
// the folder given; nothing is judged here.
// File: "VRUN" u32 version 1, u32 run count, then per run u32 point count, i32 region, u8 marks, end_a, end_b, pad, then
// per point x y z width (float32, little-endian). Beside it <name>.box: lo xyz, hi xyz (float32) of the sample body.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

final class OrganicVineRunsProbe: XCTestCase {

    static func write(_ runs: [LatticeLayoutSession.Run], lo: SIMD3<Float>, hi: SIMD3<Float>, to url: URL) throws {
        var d = Data("VRUN".utf8)
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func f32(_ v: Float) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        u32(1); u32(UInt32(runs.count))
        for r in runs {
            u32(UInt32(r.points.count)); u32(UInt32(bitPattern: r.region))
            d.append(contentsOf: [r.marks.rawValue, r.endA, r.endB, 0])
            for (k, p) in r.points.enumerated() { f32(p.x); f32(p.y); f32(p.z); f32(r.widthMM[k]) }
        }
        try d.write(to: url)
        var b = Data()
        for v in [lo.x, lo.y, lo.z, hi.x, hi.y, hi.z] { var x = v.bitPattern.littleEndian; b.append(Data(bytes: &x, count: 4)) }
        try b.write(to: url.deletingPathExtension().appendingPathExtension("box"))
    }

    /// A .vrun read back (version 1 as written above; version 2 as LatticeReview writes the cut 2 engine's: per run 28 bytes,
    /// the pad the section, then proud_a, proud_b, along_face, proud_mm; per point x y z and the file's ring width), and its
    /// .box beside it. Spacing is not in the file (0).
    static func read(_ url: URL) throws -> (runs: [LatticeLayoutSession.Run], lo: SIMD3<Float>, hi: SIMD3<Float>) {
        let d = [UInt8](try Data(contentsOf: url))
        var i = 0
        func u32() throws -> UInt32 {
            guard i + 4 <= d.count else { throw NSError(domain: "vrun", code: 1) }
            defer { i += 4 }
            return UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
        }
        func f32() throws -> Float { Float(bitPattern: try u32()) }
        guard d.count >= 12, String(bytes: d[0..<4], encoding: .ascii) == "VRUN" else { throw NSError(domain: "vrun", code: 2) }
        i = 4
        let ver = try u32(), n = try u32()
        var runs: [LatticeLayoutSession.Run] = []
        for _ in 0..<n {
            let m = Int(try u32()), region = Int32(bitPattern: try u32())
            guard i + 4 <= d.count else { throw NSError(domain: "vrun", code: 3) }
            var r = LatticeLayoutSession.Run(region: region, marks: .init(rawValue: d[i]), endA: d[i + 1], endB: d[i + 2],
                                             points: [], widthMM: [], spacingMM: [])
            if ver >= 2 { r.section = d[i + 3] & 3; r.swept = d[i + 3] & 4 != 0 }   // bits 0-1; bit 2 swept (OV1)
            i += 4
            if ver >= 2 {
                r.proudA = try f32(); r.proudB = try f32(); r.alongFace = Int32(bitPattern: try u32()); r.proudMM = try f32()
            }
            for _ in 0..<m {
                r.points.append(SIMD3(try f32(), try f32(), try f32())); r.widthMM.append(try f32()); r.spacingMM.append(0)
            }
            runs.append(r)
        }
        guard i == d.count else { throw NSError(domain: "vrun", code: 4) }
        let b = [UInt8](try Data(contentsOf: url.deletingPathExtension().appendingPathExtension("box")))
        var f: [Float] = []
        for k in 0..<6 {
            var bits = UInt32(b[4 * k])
            bits |= UInt32(b[4 * k + 1]) << 8
            bits |= UInt32(b[4 * k + 2]) << 16
            bits |= UInt32(b[4 * k + 3]) << 24
            f.append(Float(bitPattern: bits))
        }
        return (runs, SIMD3(f[0], f[1], f[2]), SIMD3(f[3], f[4], f[5]))
    }

    /// OPT-IN (VINE_V2_DIR = LatticeReview's cut 2 runs, version 2, e.g. runs362/out5; VINE_SHOT_DIR = where the pictures go,
    /// outside the repo): his 11-20 skin note drawn on the app's renderer, on the samples' own bodies. "before" = today's
    /// drawing (every run round, nothing cut); "after" = the print file's sections and the flat cut. Counts printed.
    @MainActor
    func testTheSkinsFlatCutOnTheSamples() throws {
        let env = ProcessInfo.processInfo.environment
        guard let src = env["VINE_V2_DIR"], let dir = env["VINE_SHOT_DIR"] else { throw XCTSkip("opt-in: VINE_V2_DIR and VINE_SHOT_DIR") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: src).filter { $0.hasSuffix(".vrun") }.sorted()
        XCTAssertFalse(files.isEmpty, "premise: runs to draw")
        for name in files {
            let (runs, _, _) = try Self.read(URL(fileURLWithPath: src).appendingPathComponent(name))
            let body = try TopOptKit.latticeSampleBody(cube: name.hasPrefix("cube"))
            let mesh = ViewerMesh(vertices: body.vertices, indices: body.indices, faceIDs: [Int32](repeating: 1, count: body.indices.count / 3))
            var round = runs
            for i in round.indices { round[i].section = 0 }
            let before = OrganicVineShape.tubes(runs: round)
            let t0 = Date()
            var after = OrganicVineShape.tubes(runs: runs)
            let t1 = Date()
            let surface = OrganicVineShape.CutSurface(vertices: body.vertices, indices: body.indices)
            let t2 = Date()
            after.cut(runs: runs, surface: surface)
            let ms = Date().timeIntervalSince(t0) * 1000
            print(String(format: "VINE-CUT TIME %@: tubes %.0f ms, surface %.0f ms (%d triangles), cut %.0f ms", name,
                         t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000, body.indices.count / 3,
                         Date().timeIntervalSince(t2) * 1000))
            let net = runs.filter { $0.marks.contains(.net) }
            let netCut = after.pieces.filter { $0.isCut && runs[Int($0.vine)].marks.contains(.net) }.count
            let netPieces = after.pieces.filter { runs[Int($0.vine)].marks.contains(.net) }.count
            print(String(format: "VINE-CUT %@: %d runs (%d net), %d pieces, %d cut (%d of %d net pieces), %d bridges; built and cut in %.0f ms",
                         name, runs.count, net.count, after.pieces.count, after.pieces.filter(\.isCut).count, netCut, netPieces,
                         after.pieces.filter { $0.section != 0 }.count, ms))
            let seg = LatticeLayoutPreview.segments(runs)
            for (tag, shape) in [("before", before), ("after", after)] {
                for (view, az, el, zoom) in [("whole", Float(0.55), Float(0.35), Float(1)), ("top", Float(0.4), Float(1.05), Float(0.45))] {
                    guard let rr = MeshRenderer(device: device, sampleCount: 4) else { throw XCTSkip("renderer") }
                    rr.setMesh(mesh)
                    rr.setBodyAlpha(LatticeLayoutPreview.ghostAlpha)
                    var inputs = LatticeLayoutBarsInputs(token: 1, bars: seg.bars, flags: seg.flags)
                    inputs.vines = shape
                    XCTAssertTrue(rr.applyLayoutBars(inputs, device: device))
                    rr.camera.setOrientation(azimuth: az, elevation: el)
                    if zoom != 1 { rr.camera.zoom(zoom) }
                    let px = try XCTUnwrap(rr.renderOffscreen(width: 1200, height: 900,
                                                              clear: MTLClearColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)))
                    let stem = (name as NSString).deletingPathExtension
                    try LatticeLayoutStandProbe.png(px, 1200, 900, to: (dir as NSString).appendingPathComponent("\(stem)-\(view)-\(tag).png"))
                }
            }
        }
    }

    @MainActor
    func testWriteTheSamplesRuns() async throws {
        guard let dir = ProcessInfo.processInfo.environment["VINE_RUNS_DIR"] else { throw XCTSkip("opt-in: VINE_RUNS_DIR") }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for cube in [true, false] {
            let body = try TopOptKit.latticeSampleBody(cube: cube)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("vine-probe-\(UUID().uuidString).stl")
            try MeshExport.binarySTL(vertices: body.vertices, indices: body.indices, header: Data()).write(to: url)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            try MeshExport.binarySTL(vertices: body.vertices, indices: body.indices, header: Data())
                .write(to: out.appendingPathComponent(cube ? "cube.stl" : "part.stl"))
            let session = try await LatticeLayoutSession.open(path: url.path)
            addTeardownBlock { session.close() }
            let box = LatticeLayoutPreview.box(body.vertices)
            let b = try XCTUnwrap(box)
            var s = LatticeLayoutSession.Settings()
            s.beadMM = 0.45
            s.minStrutLines = 2
            var r = LatticeLayoutSession.Region(id: 1, faces: [], depthMM: 0)
            r.zone = .init(kind: .box, centre: SIMD3<Double>((b.lo + b.hi) / 2),
                           axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)], half: SIMD3<Double>((b.hi - b.lo) / 2) + 1)
            r.weave = true
            s.regions = [r]
            let lim = try await session.sweepLimits(s, regions: [1], lineMM: 0.45).map(LatticeOrganicLook.Limits.init)
            for mode in [LatticeOrganicLook.Mode.traced, .grown] {
                for percent in [50.0, 100.0] {
                    var look = LatticeOrganicLook()
                    look.mode = mode
                    var ask = look.ask(limits: lim.map { $0.looked(percent: percent) }, layerMM: 0.2)
                    ask.quality = .exact
                    let groups = [LatticeLayoutSession.OrganicGroup(regions: [1], ask: ask)]
                    let made = try await session.synthetic(s, groups: groups, walls: [(region: 1, foci: 1)], fromEmpty: true)
                    XCTAssertTrue(made.refused.isEmpty, "\(made.refused.map(\.text))")
                    let laid = try await session.layOrganic(s, groups: groups)
                    XCTAssertTrue(laid.refused.isEmpty, "\(laid.refused.map(\.text))")
                    let name = "\(cube ? "cube" : "part")-\(mode == .grown ? "grown" : "traced")-\(Int(percent)).vrun"
                    try Self.write(laid.runs, lo: SIMD3<Float>(b.lo), hi: SIMD3<Float>(b.hi), to: out.appendingPathComponent(name))
                    print("VINE-RUNS \(name): \(laid.runs.count) runs, \(laid.segments) segments")
                }
            }
        }
    }
}
#endif
