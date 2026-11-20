// OrganicVinePassTests — the vines on the app's own renderer (his 11-19 verdict on the prototype: "The organic looks great
// now!"): the engine's Organic sample cube laid for real, drawn by OrganicVinePass (smooth round tubes, round ends, blended
// joints) instead of the bars. Pictures with VINE_SHOT_DIR (outside the repo). OPT-IN timing: VINE_RUNS_FILE = a .vrun (his
// stand's, from LatticeOrganicStandProbe) drawn at 2048 x 1536, the time per frame printed.
// His rule 11-19 ("The drawing follows the print file. Always."): the vines are the print file's tubes (OrganicVineShape.tubes).
// The pass first draws release (10)'s round struts and must match its ray-cast capsules to the pixel (so the pass draws
// shapes truly); the file's tubes then sit where the struts are, never fatter.
// RED CONTROLS: the file's tubes differ from release (10)'s balls; the parked smooth shape lands further from the outline.
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
        let round10 = OrganicVineShape.capsules(runs: runs)   // release (10)'s drawing: proves the pass draws what the bars do
        XCTAssertEqual(round10.pieces.count, seg.count, "premise: one round strut per bar")
        let shape = OrganicVineShape.tubes(runs: runs)   // ★ his 11-19 rule: the print file's tubes
        XCTAssertEqual(shape.pieces.count, seg.count, "★ one tube piece per bar")
        XCTAssertLessThan(shape.caps.count, round10.caps.count, "★ round ends only where the file puts them, not at every point")
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
        bars.vines = round10
        XCTAssertTrue(r.applyLayoutBars(bars, device: device))
        XCTAssertNil(OrganicVinePass.lastInitError, "★ the vines' shaders build")
        let roundFrame = try frame()
        bars.token = 4
        bars.vines = shape
        XCTAssertTrue(r.applyLayoutBars(bars, device: device))
        let vineFrame = try frame()
        func covered(_ f: [UInt8]) -> Int { stride(from: 0, to: f.count, by: 4).filter { f[$0..<$0 + 4] != bare[$0..<$0 + 4] }.count }
        let cb = covered(barFrame), cr = covered(roundFrame), cv = covered(vineFrame)
        func differ(_ x: [UInt8], _ y: [UInt8]) -> Int {
            stride(from: 0, to: bare.count, by: 4).filter { (x[$0..<$0 + 4] != bare[$0..<$0 + 4]) != (y[$0..<$0 + 4] != bare[$0..<$0 + 4]) }.count
        }
        let odd = differ(barFrame, roundFrame), tubeOdd = differ(roundFrame, vineFrame)
        print("VINE PASS: bars cover \(cb) pixels, release (10)'s drawing by the pass \(cr) (\(odd) differ), the file's tubes \(cv) "
              + "(\(tubeOdd) differ from release (10)); \(shape.pieces.count) pieces, \(shape.caps.count) round ends")
        // the pass draws release (10)'s round struts to the pixel: so what it draws for the file's rule is the file's rule
        XCTAssertLessThan(Double(odd), 0.03 * Double(cb), "★ the pass draws the same outline as release (10)'s ray-cast capsules")
        XCTAssertGreaterThan(cv, 20_000, "★ the vines are on screen")
        XCTAssertGreaterThan(Double(cv), 0.85 * Double(cb), "★ about where the struts are")
        XCTAssertLessThan(Double(cv), 1.02 * Double(cb), "★ and never fatter (balls only where the file has them)")
        XCTAssertGreaterThan(tubeOdd, 0, "RED CONTROL: the file's tubes are not release (10)'s balls at every point")
        let goo = OrganicVineShape(runs: runs)
        bars.token = 3
        bars.vines = goo
        XCTAssertTrue(r.applyLayoutBars(bars, device: device))
        let gooFrame = try frame()
        var gooOdd = 0
        for i in stride(from: 0, to: bare.count, by: 4)
        where (barFrame[i..<i + 4] != bare[i..<i + 4]) != (gooFrame[i..<i + 4] != bare[i..<i + 4]) { gooOdd += 1 }
        print("VINE PASS: the parked smooth shape differs at \(gooOdd) pixels")
        XCTAssertGreaterThan(gooOdd, odd, "RED CONTROL: the parked smooth blended shape is further from release (10)'s outline")
        if let dir = ProcessInfo.processInfo.environment["VINE_SHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try LatticeLayoutStandProbe.png(vineFrame, 800, 600, to: (dir as NSString).appendingPathComponent("vine-pass-cube.png"))
            try LatticeLayoutStandProbe.png(barFrame, 800, 600, to: (dir as NSString).appendingPathComponent("vine-pass-cube-bars.png"))
        }
    }

    /// ★ The flat cut on the app's renderer (his 11-20 skin note, "the cutting along the plane ... gives it its unique feel"):
    /// a vine lying ON a box's face (as the skin's net does), seen edge-on, loses the half outside the part; seen from
    /// outside, the cut face is drawn where the tube was (no hole). RED CONTROLS: uncut, the outside half is there; with the
    /// cut face off, the cut tube is hollow.
    func testTheFlatCutOnTheRenderer() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = MeshRenderer(device: device, sampleCount: 1) else { throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")") }
        // the box 0..20 x 0..10 x 0..20 (y up on screen), a round vine and a D bridge on its face y = 10
        let v: [Float] = [0, 0, 0, 20, 0, 0, 20, 10, 0, 0, 10, 0, 0, 0, 20, 20, 0, 20, 20, 10, 20, 0, 10, 20]
        let idx: [Int32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5]
        func run(_ pts: [SIMD3<Float>], _ section: UInt8) -> LatticeLayoutSession.Run {
            var x = LatticeLayoutSession.Run(region: 1, marks: .net, endA: 0, endB: 0, points: pts,
                                             widthMM: [Float](repeating: 2, count: pts.count), spacingMM: [Float](repeating: 4, count: pts.count))
            x.section = section
            return x
        }
        let runs = [run([SIMD3(3, 10, 6), SIMD3(10, 10, 6), SIMD3(17, 10, 6)], 0), run([SIMD3(3, 10, 14), SIMD3(17, 10, 14)], 1)]
        let whole = OrganicVineShape.tubes(runs: runs)
        var cut = whole
        cut.cut(runs: runs, surface: OrganicVineShape.CutSurface(vertices: v, indices: idx))
        XCTAssertTrue(cut.pieces.allSatisfy(\.isCut), "premise: both lie on the face")
        r.setMesh(ViewerMesh(vertices: v, indices: idx, faceIDs: [Int32](repeating: 1, count: idx.count / 3)))
        r.setBodyAlpha(0)
        let clear = MTLClearColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        let seg = LatticeLayoutPreview.segments(runs)
        // the camera turns about a point ON the face (y = 10): at elevation 0 the eye is in the face's plane, truly edge-on
        r.camera.target = SIMD3(10, 10, 10)
        var token = 10
        let shots = ProcessInfo.processInfo.environment["VINE_SHOT_DIR"]
        if let shots { try FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true) }
        func covered(_ shape: OrganicVineShape, azimuth: Float, elevation: Float, face: Bool = true, name: String) throws -> Int {
            OrganicVinePass.drawCutFace = face
            defer { OrganicVinePass.drawCutFace = true }
            r.camera.setOrientation(azimuth: azimuth, elevation: elevation)
            token += 1
            var bars = LatticeLayoutBarsInputs(token: token, bars: seg.bars, flags: seg.flags)
            bars.vines = shape
            XCTAssertTrue(r.applyLayoutBars(bars, device: device))
            XCTAssertNil(OrganicVinePass.lastInitError, "★ the cut's shaders build")
            let f = try XCTUnwrap(r.renderOffscreen(width: 600, height: 600, clear: clear, stage: false))
            if let shots { try LatticeLayoutStandProbe.png(f, 600, 600, to: (shots as NSString).appendingPathComponent("vine-cut-\(name).png")) }
            let bg = Array(f[0..<4])
            return stride(from: 0, to: f.count, by: 4).filter { Array(f[$0..<$0 + 4]) != bg }.count
        }
        // edge-on (the face seen as a line): half of each vine is outside the part
        let sideWhole = try covered(whole, azimuth: 0, elevation: 0, name: "side-whole")
        let sideCut = try covered(cut, azimuth: 0, elevation: 0, name: "side-cut")
        // from outside, straight down onto the face: the cut face fills the tube's outline
        let topWhole = try covered(whole, azimuth: 0, elevation: 1.5, name: "top-whole")
        let topCut = try covered(cut, azimuth: 0, elevation: 1.5, name: "top-cut")
        let topHollow = try covered(cut, azimuth: 0, elevation: 1.5, face: false, name: "top-hollow")
        _ = try covered(whole, azimuth: 0.5, elevation: 0.6, name: "whole")
        _ = try covered(cut, azimuth: 0.5, elevation: 0.6, name: "cut")
        print("VINE CUT: edge-on \(sideCut) of \(sideWhole) pixels; from above \(topCut) of \(topWhole) (hollow \(topHollow))")
        XCTAssertGreaterThan(sideWhole, 2_000, "premise: the vines are on screen")
        XCTAssertLessThan(Double(sideCut), 0.6 * Double(sideWhole), "★ edge-on, the half outside the part is gone")
        XCTAssertGreaterThan(Double(sideCut), 0.4 * Double(sideWhole), "★ and the half inside stays")
        XCTAssertGreaterThan(Double(topCut), 0.95 * Double(topWhole), "★ from outside, the cut face is drawn where the tube was")
        XCTAssertLessThan(Double(topHollow), 0.5 * Double(topCut), "RED CONTROL: without the cut face the cut tube is hollow")
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
        let shape = OrganicVineShape.tubes(runs: runs)
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
