// Notes24IntoThePartTests — ★ his words 2026-11-23, after release 16:
//   (b) "Make sure that looking INTO the part actually looks shaded and as if you're looking INTO A PART." What is inside the
//       opened part (the vines, the growing vines, the cut walls) is darker the deeper he looks and shadowed by the walls
//       around it (LatticeInsideShade), the cut walls in the part's own clay. RED CONTROL `LatticeInsideShade.controlOff`: the
//       inside lit as if it stood in the open (as before).
//   (a) "start an animation by removing the walls, allowing that animation to run for 2-3 seconds and THEN starting the
//       growing animation": with the map made before the lay, the latticed walls dissolve away (their edge glowing in the
//       lattice's purple) before any vine shows. RED CONTROL: a lay whose map is already on screen opens nothing.
// Opt-in pictures (VIEWER_SHOT_DIR=<a folder outside the repo>): a pocket, and a block laid FOR REAL, before and after.
#if canImport(MetalKit)
import XCTest
import MetalKit
import QuartzCore
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes24IntoThePartTests: XCTestCase {

    override func tearDown() {
        LatticeInsideShade.controlOff = false
        MeshRenderer.growthClockForTesting = nil
        super.tearDown()
    }

    static func shoot(_ f: [UInt8], _ w: Int, _ h: Int, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["VIEWER_SHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try LatticeLayoutStandProbe.png(f, w, h, to: (dir as NSString).appendingPathComponent(name))
    }

    // MARK: a pocket: a 20 mm cube, its top opened over a 12 × 12 mm pocket 12 mm deep

    static let cubeV: [Float] = [0, 0, 0, 20, 0, 0, 20, 20, 0, 0, 20, 0, 0, 0, 20, 20, 0, 20, 20, 20, 20, 0, 20, 20]
    static let cubeI: [Int32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6,
                                 1, 6, 5]

    /// The engine's map of the cube (two bytes a voxel: open, inside), 1 mm voxels with air round it: open lattice in the
    /// pocket (4 < x, z < 16, y > 8), solid elsewhere inside.
    static func pocketMap(token: Int) -> LatticeLayoutSolidGrid {
        let dims = SIMD3<Int32>(25, 25, 25), origin = SIMD3<Float>(-2, -2, -2)
        var rg = [Int8]()
        for z in 0..<Int(dims.z) { for y in 0..<Int(dims.y) { for x in 0..<Int(dims.x) {
            let p = origin + SIMD3(Float(x), Float(y), Float(z))
            let inside = p.x >= -0.01 && p.x <= 20.01 && p.y >= -0.01 && p.y <= 20.01 && p.z >= -0.01 && p.z <= 20.01
            let open = inside && p.x > 4 && p.x < 16 && p.z > 4 && p.z < 16 && p.y > 8
            rg += [open ? 127 : -127, inside ? 127 : -127]
        }}}
        return LatticeLayoutSolidGrid(token: token, origin: origin, voxel: 1, dims: dims, rg: rg)
    }

    private func cubeRenderer() throws -> (MeshRenderer, MTLDevice) {
        guard let device = MTLCreateSystemDefaultDevice(), let r = MeshRenderer(device: device) else {
            throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")")
        }
        r.setMesh(ViewerMesh(vertices: Self.cubeV, indices: Self.cubeI, faceIDs: [Int32](repeating: 1, count: Self.cubeI.count / 3)))
        r.setBodyAlpha(1)   // the solid view
        r.camera.target = SIMD3(10, 14, 10)
        r.camera.setOrientation(azimuth: 0.6, elevation: 1.25)
        r.camera.distance = 48
        return (r, device)
    }

    /// The screen pixel (x, y) of a point of the part.
    static func pixel(_ r: MeshRenderer, _ p: SIMD3<Float>, _ w: Int, _ h: Int) -> (Int, Int) {
        let c = r.camera.projectionMatrix(aspect: Float(w) / Float(h)) * r.camera.viewMatrix() * SIMD4(p, 1)
        let n = SIMD2(c.x, c.y) / c.w
        return (Int(((n.x + 1) / 2 * Float(w)).rounded()), Int(((1 - n.y) / 2 * Float(h)).rounded()))
    }
    /// The mean RGB of the 3 × 3 pixels about (x, y).
    static func rgb(_ f: [UInt8], _ x: Int, _ y: Int, _ w: Int) -> SIMD3<Float> {
        var s = SIMD3<Float>(repeating: 0)
        for dy in -1...1 { for dx in -1...1 {
            let i = 4 * ((y + dy) * w + x + dx)
            s += SIMD3(Float(f[i + 2]), Float(f[i + 1]), Float(f[i]))
        }}
        return s / 9
    }

    /// ★ (b): three vines standing up the pocket, seen from above: the same vine darker deep in the pocket than at its lip
    /// (the inside lit as the inside of a part), the pocket's floor darker than the part's top; the shade's twin, off, lights
    /// both alike (RED CONTROL, the picture before).
    func testLookingIntoThePocketIsDarkerTheDeeperHeLooks() throws {
        let (r, device) = try cubeRenderer()
        let (w, h) = (800, 600)
        XCTAssertTrue(r.applyLayoutBars(LatticeLayoutBarsInputs(token: 1, bars: [1, 1, 1, 1.1, 1, 1, 0.05],
                                                                solid: Self.pocketMap(token: 1)), device: device))
        let g = LatticeGrowth()
        var a = LatticeLayoutSession.Organic(); a.widthMM = 1.6
        g.layBegins([.init(regions: [1], ask: a)], lineMM: 0.45, opening: .open)
        g.replayOffForTesting()
        r.applyGrowth(g)
        var xyz: [Float] = []
        let stems: [SIMD2<Float>] = [SIMD2(7, 7), SIMD2(10, 10), SIMD2(13, 13)]
        for s in stems { for k in 0..<20 {
            let y0 = 8.6 + Float(k) * 0.55
            xyz += [s.x, y0, s.y, s.x, y0 + 0.55, s.y]
        }}
        g.append(xyz: xyz, region: [Int32](repeating: 1, count: xyz.count / 6))
        for _ in 0..<10 { g.append(xyz: [Float](repeating: 1000, count: 6), region: [1]) }   // cooled
        let clear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let on = try XCTUnwrap(r.renderOffscreen(width: w, height: h, clear: clear, stage: true))
        XCTAssertNotNil(r.insideMap, "premise: the part opened by its map")
        XCTAssertFalse(r.growthXraysBody)
        LatticeInsideShade.controlOff = true
        let off = try XCTUnwrap(r.renderOffscreen(width: w, height: h, clear: clear, stage: true))
        LatticeInsideShade.controlOff = false
        try Self.shoot(on, w, h, "pocket-after.png")
        try Self.shoot(off, w, h, "pocket-before.png")
        XCTAssertNil(LatticeInsideShade.lastInitError)
        func ratio(_ p: SIMD3<Float>) -> Float {
            let (x, y) = Self.pixel(r, p, w, h)
            return Self.rgb(on, x, y, w).sum() / Swift.max(Self.rgb(off, x, y, w).sum(), 1)
        }
        let lip = ratio(SIMD3(10, 18.8, 10)), deep = ratio(SIMD3(10, 10.2, 10))
        let floor = ratio(SIMD3(5, 8.2, 11)), top = ratio(SIMD3(2, 20, 2))
        print("INSIDE: the vine at the lip \(lip), deep \(deep); the pocket's floor \(floor); the part's top \(top)")
        XCTAssertGreaterThan(lip, 0.85, "★ at the lip: as lit as before")
        XCTAssertLessThan(deep, 0.78, "★ deep in the pocket: darker")
        XCTAssertLessThan(deep, lip - 0.12, "★ darker the deeper he looks")
        XCTAssertLessThan(floor, 0.8, "★ the pocket's floor (a cut wall) in the dark of the part")
        XCTAssertEqual(top, 1, accuracy: 0.02, "the part's outside untouched")
        // RED CONTROL: off (the picture before), the pocket's floor lit as if it lay in the open: twice as bright or more
        let (fx, fy) = Self.pixel(r, SIMD3(5, 8.2, 11), w, h)
        XCTAssertGreaterThan(Self.rgb(off, fx, fy, w).sum(), 2 * Self.rgb(on, fx, fy, w).sum(),
                             "RED CONTROL: before, the floor of the pocket lit as brightly as an open face")
    }

    /// ★ (a), walls first: the map made before the lay, no lattice on screen yet — the pocket's top dissolves away over the
    /// walls' 2.5 s (its edge glowing purple half way), then stands open. RED CONTROL: the map on screen this lay's (`.open`),
    /// nothing to dissolve — open from the first frame.
    func testTheWallsDissolveBeforeAnyVineShows() throws {
        let (r, device) = try cubeRenderer()
        let (w, h) = (600, 450)
        let clear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let g = LatticeGrowth()
        r.applyGrowth(g)
        let closed = try XCTUnwrap(r.renderOffscreen(width: w, height: h, clear: clear, stage: false))
        let t0 = CACurrentMediaTime() + 500
        g.layBegins([], lineMM: 0.45, opening: .dissolve(Self.pocketMap(token: 3)), now: t0)
        func at(_ dt: Double) throws -> [UInt8] {
            MeshRenderer.growthClockForTesting = t0 + dt
            return try XCTUnwrap(r.renderOffscreen(width: w, height: h, clear: clear, stage: false))
        }
        let start = try at(0), half = try at(LatticeGrowthReplay.wallsS * 0.5), end = try at(LatticeGrowthReplay.wallsS + 0.1)
        XCTAssertTrue(r.growthFrame.ownMap, "★ the walls open by the lay's own map")
        XCTAssertFalse(r.growthXraysBody, "never X-ray: the map is there")
        try Self.shoot(half, w, h, "walls-dissolving.png")
        try Self.shoot(end, w, h, "walls-open.png")
        func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
            stride(from: 0, to: a.count, by: 4).filter { a[$0..<$0 + 3] != b[$0..<$0 + 3] }.count
        }
        func purple(_ f: [UInt8]) -> Int {
            stride(from: 0, to: f.count, by: 4).filter { Int(f[$0]) > Int(f[$0 + 1]) + 30 && f[$0] > 90 }.count
        }
        let opened = differing(closed, end), started = differing(closed, start), mid = differing(closed, half)
        print("WALLS: pixels changed at the start \(started), half way \(mid), open \(opened); glowing edge half way \(purple(half))")
        XCTAssertLessThan(started, opened / 20, "★ at the start the part stands closed")
        XCTAssertGreaterThan(opened, 2_000, "★ then the pocket is open")
        XCTAssertGreaterThan(mid, opened / 5, "★ half way: dissolving")
        XCTAssertLessThan(mid, opened * 9 / 10)
        XCTAssertGreaterThan(purple(half), 30, "★ its edge glows in the lattice's purple")
        XCTAssertLessThan(purple(end), 10, "no glow once open")
        XCTAssertEqual(g.shownCount(at: t0 + 1), 0, "no vine during the walls")
        // RED CONTROL: the map on screen is this lay's: open already, nothing dissolves
        let g2 = LatticeGrowth()
        r.applyGrowth(g2)
        r.applyLayoutBars(LatticeLayoutBarsInputs(token: 4, bars: [1, 1, 1, 1.1, 1, 1, 0.05], solid: Self.pocketMap(token: 4)),
                          device: device)
        g2.layBegins([], lineMM: 0.45, opening: .open, now: t0)
        let redStart = try at(0)
        XCTAssertGreaterThan(differing(closed, redStart), opened / 2, "RED CONTROL: open from the first frame")
    }

    // MARK: a block laid FOR REAL: its top boss woven down into the block (a pocket under it)

    /// 60 × 35 × 40 mm with a 30 × 5 × 20 boss on top; the boss's top woven 18 mm deep (into the block under it); Grown, Exact.
    struct Scene {
        var mesh: ViewerMesh
        var bars: LatticeLayoutBarsInputs
        var runs: [LatticeLayoutSession.Run]
        var map: LatticeLayoutSolidGrid
    }

    static func scene(_ test: XCTestCase) async throws -> Scene {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("into-part-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("block.stl").path
        try LatticePlaceChipsTests.gridSTL([0, 15, 45, 60], [0, 35, 40], [0, 10, 30, 40]) { i, j, k in j == 0 || (i == 1 && k == 1) }
            .write(to: URL(fileURLWithPath: path))
        let m = try TopOptKit.importMesh(path: path)
        let top = try XCTUnwrap(LatticePlaceChipsTests.face(m, axis: 1, sign: 1, at: 40), "the boss's top")
        let session = try await LatticeLayoutSession.open(path: path)
        test.addTeardownBlock { session.close() }
        var s = LatticeLayoutSession.Settings()
        var r = LatticeLayoutSession.Region(id: 1, faces: [top], depthMM: 18)
        r.weave = true
        s.regions = [r]
        let n = (32, 22, 22)
        var voigt: [Double] = []
        for _ in 0..<(n.0 * n.1 * n.2) { voigt += [-1, -10, -1, 0.5, 0.2, 0.1] }
        try await session.setTensor(voigt: voigt, nx: n.0, ny: n.1, nz: n.2, origin: SIMD3(-1, -1, -1), spacingMM: 2)
        let limits = try await session.sweepLimits(s, lineMM: 0.45)
        var look = LatticeOrganicLook(); look.mode = .grown; look.lookPercent = 5
        let laid = try await session.layOrganic(s, look.ask(limits: LatticeOrganicLook.Limits(limits[0])))
        let box = try XCTUnwrap(LatticeLayoutPreview.box(m.vertices))
        let map = try await LatticeLayoutPreview.map(session, box, token: 1, smooth: true).grid
        var vines = OrganicVineShape.tubes(runs: laid.runs, heldFlat: laid.flatEnds)
        vines.cut(runs: laid.runs, surface: OrganicVineShape.CutSurface(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs))
        let seg = LatticeLayoutPreview.segments(laid.runs)
        var bars = LatticeLayoutBarsInputs(token: 1, bars: seg.bars, solid: map, flags: seg.flags)
        bars.vines = vines
        return Scene(mesh: ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs), bars: bars, runs: laid.runs,
                     map: map)
    }

    /// ★ (a) and (b) on a real lay: the walls dissolving, the replay part way, the landed lattice — and the landed lattice with
    /// the inside's light off (the picture before). The inside darker with it on.
    func testABlockLaidForRealSeenIntoItsPocket() async throws {
        let sc = try await Self.scene(self)
        guard let device = MTLCreateSystemDefaultDevice(), let r = MeshRenderer(device: device) else {
            throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")")
        }
        r.setMesh(sc.mesh)
        r.setBodyAlpha(1)
        r.camera.setOrientation(azimuth: 0.5, elevation: 0.95)
        r.camera.distance *= 0.8
        let (w, h) = (1200, 900)
        let clear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        func frame() throws -> [UInt8] { try XCTUnwrap(r.renderOffscreen(width: w, height: h, clear: clear, stage: true)) }
        // the growth: the lay's own pieces, replayed after the walls (made before the lay)
        let g = LatticeGrowth()
        r.applyGrowth(g)
        let t0 = CACurrentMediaTime() + 500
        var a = LatticeLayoutSession.Organic(); a.widthMM = 1.0
        g.layBegins([.init(regions: [1], ask: a)], lineMM: 0.45, opening: .dissolve(sc.map), now: t0)
        var xyz: [Float] = [], region: [Int32] = []
        for run in sc.runs { for k in 0..<Swift.max(0, run.points.count - 1) {
            let p = run.points[k], q = run.points[k + 1]
            xyz += [p.x, p.y, p.z, q.x, q.y, q.z]; region.append(1)
        }}
        let per = Swift.max(1, region.count / 12)
        for i in stride(from: 0, to: region.count, by: per) {   // twelve polls of it
            let j = Swift.min(region.count, i + per)
            g.append(xyz: Array(xyz[(6 * i)..<(6 * j)]), region: Array(region[i..<j]))
        }
        MeshRenderer.growthClockForTesting = t0 + LatticeGrowthReplay.wallsS * 0.5
        try Self.shoot(try frame(), w, h, "block-walls-dissolving.png")
        MeshRenderer.growthClockForTesting = t0 + LatticeGrowthReplay.wallsS + 2.2
        let growing = try frame()
        try Self.shoot(growing, w, h, "block-growing.png")
        XCTAssertGreaterThan(r.growthFrame.shown, 0, "premise: the replay under way")
        XCTAssertLessThan(r.growthFrame.shown, g.count, "premise: part way")
        // landed
        MeshRenderer.growthClockForTesting = nil
        r.applyGrowth(nil)
        XCTAssertTrue(r.applyLayoutBars(sc.bars, device: device))
        let after = try frame()
        LatticeInsideShade.controlOff = true
        let before = try frame()
        LatticeInsideShade.controlOff = false
        try Self.shoot(after, w, h, "block-landed-after.png")
        try Self.shoot(before, w, h, "block-landed-before.png")
        var changed = 0, darker: [Float] = []
        for i in stride(from: 0, to: after.count, by: 4) where after[i..<i + 3] != before[i..<i + 3] {
            changed += 1
            let a = Float(after[i]) + Float(after[i + 1]) + Float(after[i + 2])
            let b = Float(before[i]) + Float(before[i + 1]) + Float(before[i + 2])
            if b > 30 { darker.append(a / b) }
        }
        darker.sort()
        let p10 = darker.isEmpty ? 1 : darker[darker.count / 10], p90 = darker.isEmpty ? 1 : darker[darker.count * 9 / 10]
        print("BLOCK: \(sc.runs.count) runs; inside light changed \(changed) px; light kept 10% \(p10), 90% \(p90)")
        XCTAssertGreaterThan(changed, 5_000, "★ the inside is shaded")
        XCTAssertLessThan(p10, 0.65, "★ the deep inside dark")
        XCTAssertGreaterThan(p90, 0.8, "★ the lip still lit: a gradient, not a dimmer")
        // what it costs the GPU (his iPad is the judge; this Mac's numbers for the report)
        func gpu() -> Double { (0..<3).compactMap { _ in r.measureFrameGPUSeconds(size: 1536, stage: true) }.min() ?? 0 }
        let costOn = gpu()
        LatticeInsideShade.controlOff = true
        let costOff = gpu()
        LatticeInsideShade.controlOff = false
        print(String(format: "INSIDE COST: %.2f ms a frame with the inside's light, %.2f ms without (GPU, 1536²)",
                     costOn * 1000, costOff * 1000))
        XCTAssertLessThan(costOn - costOff, 0.004, "the inside's light costs a few milliseconds at most")
    }
}
#endif
