// OrganicVinePassTests — the vines on the app's own renderer (his 11-19 verdict on the prototype: "The organic looks great
// now!"): the engine's Organic sample cube laid for real, drawn by OrganicVinePass (smooth round tubes, round ends, blended
// joints) instead of the bars. Pictures with VINE_SHOT_DIR (outside the repo). OPT-IN timing: VINE_RUNS_FILE = a .vrun (his
// stand's, from LatticeOrganicStandProbe) drawn at 2048 x 1536, the time per frame printed.
// RED CONTROL: without vines the same inputs draw the bars, a different frame.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class OrganicVinePassTests: XCTestCase {

    func sampleCubeRuns() async throws -> (runs: [LatticeLayoutSession.Run], mesh: ViewerMesh) {
        let body = try TopOptKit.latticeSampleBody(cube: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vine-pass-\(UUID().uuidString).stl")
        try MeshExport.binarySTL(vertices: body.vertices, indices: body.indices, header: Data()).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let session = try await LatticeLayoutSession.open(path: url.path)
        addTeardownBlock { session.close() }
        let b = try XCTUnwrap(LatticeLayoutPreview.box(body.vertices))
        var s = LatticeLayoutSession.Settings()
        var r = LatticeLayoutSession.Region(id: 1, faces: [], depthMM: 0)
        r.zone = .init(kind: .box, centre: SIMD3<Double>((b.lo + b.hi) / 2), axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                       half: SIMD3<Double>((b.hi - b.lo) / 2) + 1)
        r.weave = true
        s.regions = [r]
        let lim = try await session.sweepLimits(s, regions: [1], lineMM: 0.45).map(LatticeOrganicLook.Limits.init)
        let groups = [LatticeLayoutSession.OrganicGroup(regions: [1], ask: LatticeOrganicLook().ask(limits: lim, layerMM: 0.2))]
        _ = try await session.synthetic(s, groups: groups, walls: [(region: 1, foci: 1)], fromEmpty: true)
        let laid = try await session.layOrganic(s, groups: groups)
        XCTAssertTrue(laid.refused.isEmpty)
        return (laid.runs, ViewerMesh(vertices: body.vertices, indices: body.indices,
                                      faceIDs: [Int32](repeating: 1, count: body.indices.count / 3)))
    }

    func testTheVinesDrawOnTheAppsRenderer() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = MeshRenderer(device: device, sampleCount: 1) else { throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")") }
        let (runs, mesh) = try await sampleCubeRuns()
        let seg = LatticeLayoutPreview.segments(runs)
        let shape = OrganicVineShape(runs: runs)
        XCTAssertGreaterThan(shape.pieces.count, seg.count / 2, "premise: the vines are made")
        XCTAssertFalse(shape.joints.isEmpty, "premise: the vines meet")
        XCTAssertEqual(shape.caps.count, 2 * runs.filter { $0.points.count >= 2 }.count, "★ a round end at each run end")
        r.setMesh(mesh)
        r.camera.setOrientation(azimuth: 0.6, elevation: 0.4)
        r.setBodyAlpha(LatticeLayoutPreview.ghostAlpha)
        let clear = MTLClearColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        func frame() throws -> [UInt8] { try XCTUnwrap(r.renderOffscreen(width: 800, height: 600, clear: clear, stage: false)) }
        let bare = try frame()
        var bars = LatticeLayoutBarsInputs(token: 1, bars: seg.bars, flags: seg.flags)
        XCTAssertTrue(r.applyLayoutBars(bars, device: device))
        let barFrame = try frame()
        bars.token = 2
        bars.vines = shape
        XCTAssertTrue(r.applyLayoutBars(bars, device: device))
        XCTAssertNil(OrganicVinePass.lastInitError, "★ the vines' shaders build")
        let vineFrame = try frame()
        func covered(_ f: [UInt8]) -> Int { stride(from: 0, to: f.count, by: 4).filter { f[$0..<$0 + 4] != bare[$0..<$0 + 4] }.count }
        let cb = covered(barFrame), cv = covered(vineFrame)
        print("VINE PASS: bars cover \(cb) pixels, vines \(cv); \(shape.pieces.count) pieces, \(shape.caps.count) ends, \(shape.joints.count) joints")
        XCTAssertGreaterThan(cv, 20_000, "★ the vines are on screen")
        XCTAssertGreaterThan(Double(cv), 0.7 * Double(cb), "★ about where the bars are")
        XCTAssertLessThan(Double(cv), 1.4 * Double(cb), "★ and no fatter")
        XCTAssertNotEqual(vineFrame, barFrame, "RED CONTROL: without vines the bars draw, a different frame")
        if let dir = ProcessInfo.processInfo.environment["VINE_SHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try LatticeLayoutStandProbe.png(vineFrame, 800, 600, to: (dir as NSString).appendingPathComponent("vine-pass-cube.png"))
            try LatticeLayoutStandProbe.png(barFrame, 800, 600, to: (dir as NSString).appendingPathComponent("vine-pass-cube-bars.png"))
        }
    }

    /// OPT-IN timing on a .vrun (his stand's runs): the vines at 2048 x 1536, ten frames, the time per frame.
    func testTheVinesFrameTimeOnHisStand() throws {
        guard let path = ProcessInfo.processInfo.environment["VINE_RUNS_FILE"] else { throw XCTSkip("opt-in: VINE_RUNS_FILE") }
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = MeshRenderer(device: device, sampleCount: 4) else { throw XCTSkip("no renderer") }
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        var at = 0
        func u32() -> UInt32 { let v = d.subdata(in: at..<at + 4).withUnsafeBytes { $0.load(as: UInt32.self) }; at += 4; return v }
        func f32() -> Float { Float(bitPattern: u32()) }
        at = 8
        let n = Int(u32())
        var runs: [LatticeLayoutSession.Run] = []
        for _ in 0..<n {
            let m = Int(u32()); let region = Int32(bitPattern: u32())
            let marks = d[at]; let ea = d[at + 1]; let eb = d[at + 2]; at += 4
            var pts: [SIMD3<Float>] = [], w: [Float] = []
            for _ in 0..<m { pts.append(SIMD3(f32(), f32(), f32())); w.append(f32()) }
            runs.append(.init(region: region, marks: .init(rawValue: marks), endA: ea, endB: eb, points: pts, widthMM: w,
                              spacingMM: [Float](repeating: 4, count: m)))
        }
        let t0 = Date()
        let shape = OrganicVineShape(runs: runs)
        let buildMS = Date().timeIntervalSince(t0) * 1000
        let seg = LatticeLayoutPreview.segments(runs)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for p in runs.flatMap(\.points) { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let v: [Float] = [lo.x, lo.y, lo.z, hi.x, lo.y, lo.z, lo.x, hi.y, hi.z]
        r.setMesh(ViewerMesh(vertices: v, indices: [0, 1, 2], faceIDs: [1]))
        r.camera.setOrientation(azimuth: 0.55, elevation: 0.35)
        var inputs = LatticeLayoutBarsInputs(token: 1, bars: seg.bars, flags: seg.flags)
        inputs.vines = shape
        XCTAssertTrue(r.applyLayoutBars(inputs, device: device))
        let clear = MTLClearColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        func ms() -> Double {
            _ = r.renderOffscreen(width: 2048, height: 1536, clear: clear, stage: false)
            let t1 = Date()
            for _ in 0..<5 { _ = r.renderOffscreen(width: 2048, height: 1536, clear: clear, stage: false) }
            return Date().timeIntervalSince(t1) * 200
        }
        defer { OrganicVinePass.drawTubes = true; OrganicVinePass.drawCaps = true; OrganicVinePass.drawJoints = true }
        let all = ms()
        OrganicVinePass.drawJoints = false
        let noJoints = ms()
        OrganicVinePass.drawCaps = false
        let tubes = ms()
        OrganicVinePass.drawTubes = false
        let empty = ms()
        OrganicVinePass.drawTubes = true; OrganicVinePass.drawCaps = true; OrganicVinePass.drawJoints = true
        var plain = LatticeLayoutBarsInputs(token: 2, bars: seg.bars, flags: seg.flags)
        plain.lightFrom = 0
        XCTAssertTrue(r.applyLayoutBars(plain, device: device))
        let release10 = ms()
        print(String(format: "VINE TIMING %@: %d struts, %d pieces, %d ends, %d joints; built in %.0f ms (debug build); "
                     + "ms a frame at 2048 x 1536 with readback: all %.0f, no joints %.0f, tubes only %.0f, nothing %.0f; "
                     + "release (10)'s light tubes %.0f",
                     (path as NSString).lastPathComponent, seg.count, shape.pieces.count, shape.caps.count, shape.joints.count,
                     buildMS, all, noJoints, tubes, empty, release10))
    }
}
#endif
