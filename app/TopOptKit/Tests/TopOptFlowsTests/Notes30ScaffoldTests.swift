// Notes30ScaffoldTests — ★ his word on the strut lattice's build (2026-11-26): "It would be best if on fast parts, it runs as it is
// now - and on slow parts it runs with the scaffolding"; "open up the walls first ... then start with the vertical struts and
// horizontal struts - like having scaffolding put in place ... we can remove the scaffolding afterwards"; "I don't think
// scaffolds ever differ in heights"; "little stair/diagonal sections to really hammer in the 'Scaffold' effect"; "I would much
// rather two different animations" (Organic keeps its own); Live preview has no animation at all.
//   * a fast lay: no scaffold — stand-solid-7s as he liked it (RED `LatticeBuildShow.controlScaffoldAlways`);
//   * a slow lay: the walls first, the scaffold's lifts before the landing, the real floors replacing it floor by floor, nothing
//     of it left after (RED `controlNoScaffold`; on screen RED `LatticeBuildTimelapse.controlNeverStrike`);
//   * a lay still working a second after the ask switches to the scaffold (RED `LatticeBuildTimelapse.controlNoSwitch`);
//   * Organic, Live preview, Skip all animations and the Settings sample never get it (RED `controlScaffoldAnyLay`,
//     `controlLiveAnimates`, Skip off, an armed show);
//   * no strut of the real lattice is ever shown then taken away (RED `controlStrikeRealToo`);
//   * the rough cut-open is made before the lay for a cube lattice and leaves the lay as it was (RED: `gridAhead`, Organic's);
//   * the scaffold is one even grid, one lift height, braced, with a stair, thin and pale (RED: a lattice's struts fail it).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import AppKit
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes30ScaffoldTests: XCTestCase {
    typealias T = LatticeBuildTimelapse
    typealias S = LatticeBuildScaffold

    override func tearDown() {
        LatticeBuildShow.clockForTesting = nil
        LatticeBuildShow.controlOff = false
        LatticeBuildShow.controlNoScaffold = false
        LatticeBuildShow.controlScaffoldAlways = false
        LatticeBuildShow.controlStrikeRealToo = false
        T.controlNoSwitch = false
        T.controlNeverStrike = false
        T.totalS = T.hisTotalS
        LatticeLayoutPreview.controlScaffoldAnyLay = false
        LatticeLayoutPreview.controlLiveAnimates = false
        LatticeLayoutPreview.roughForTesting = nil
        AppSettings.skipAllAnimations = false
        S.controlRimOnly = false
        S.controlWallsFirst = false
        S.controlNoLandings = false
        super.tearDown()
    }

    // MARK: fixtures

    /// A rough cut-open: a part `part` mm (from the origin) with an open lattice area `lo`…`hi` inside it, voxel `v` mm.
    static func rough(part: SIMD3<Float>, lo: SIMD3<Float>, hi: SIMD3<Float>, v: Float = 1.5) -> S.Rough {
        let origin = SIMD3<Float>(repeating: -v)
        let dims = SIMD3<Int32>(Int32((part.x / v).rounded(.up)) + 3, Int32((part.y / v).rounded(.up)) + 3, Int32((part.z / v).rounded(.up)) + 3)
        var rg = [Int8]()
        rg.reserveCapacity(2 * Int(dims.x * dims.y * dims.z))
        for z in 0..<Int(dims.z) { for y in 0..<Int(dims.y) { for x in 0..<Int(dims.x) {
            let p = origin + SIMD3(Float(x), Float(y), Float(z)) * v
            let inside = all(p .>= SIMD3(repeating: -0.01)) && all(p .<= part + 0.01)
            let open = inside && all(p .> lo) && all(p .< hi)
            rg += [open ? 127 : -127, inside ? 127 : -127]
        }}}
        return S.Rough(origin: origin, voxel: v, dims: dims, rg: rg)
    }
    /// The stand-like window: a part 80 × 50 × 50 mm, its lattice area through it front to back (y), 10…70 across, 6…48 up.
    static let window = rough(part: SIMD3(80, 50, 50), lo: SIMD3(10, -1, 6), hi: SIMD3(70, 51, 48))

    /// The Notes24 pocket cube's map as a rough cut-open (open lattice in 4 < x, z < 16, y > 8).
    static func pocketRough() -> S.Rough {
        let m = Notes24IntoThePartTests.pocketMap(token: 0)
        return S.Rough(origin: m.origin, voxel: m.voxel, dims: m.dims, rg: m.rg)
    }

    /// The straw pixels (the scaffold's pale colour, lit: red and green well over blue; the clay body and the purple lattice
    /// never) in a BGRA frame.
    static func straw(_ f: [UInt8]) -> Int {
        stride(from: 0, to: f.count, by: 4).filter { Int(f[$0 + 2]) > Int(f[$0]) + 40 && Int(f[$0 + 1]) > Int(f[$0]) + 20 }.count
    }

    /// The pocket cube, solid, looking into the pocket's mouth (Notes24's camera).
    private func pocketRenderer(samples: Int = 1) throws -> (MeshRenderer, MTLDevice) {
        guard let device = MTLCreateSystemDefaultDevice(), let r = MeshRenderer(device: device, sampleCount: samples) else {
            throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")")
        }
        r.setMesh(ViewerMesh(vertices: Notes24IntoThePartTests.cubeV, indices: Notes24IntoThePartTests.cubeI,
                             faceIDs: [Int32](repeating: 1, count: Notes24IntoThePartTests.cubeI.count / 3)))
        r.setBodyAlpha(1)   // the solid view
        r.camera.target = SIMD3(10, 14, 10)
        r.camera.setOrientation(azimuth: 0.6, elevation: 1.25)
        r.camera.distance = 48
        return (r, device)
    }
    private func frame(_ r: MeshRenderer) throws -> [UInt8] {
        try XCTUnwrap(r.renderOffscreen(width: 480, height: 360, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1), stage: false))
    }
    /// The pocket's lattice: columns (along y, the pocket's up) and beams (x), every 3 mm.
    static func pocketBars() -> [Float] {
        var out: [Float] = []
        for x in stride(from: Float(6), through: 14, by: 4) { for z in stride(from: Float(6), through: 14, by: 4) {
            for y in stride(from: Float(9), to: 19, by: 3) {
                out += [x, y, z, x, y + 3, z, 0.9]
                if x < 14 { out += [x, y + 3, z, x + 4, y + 3, z, 0.9] }
            }
        }}
        return out
    }

    // MARK: fast or slow, at the ask

    /// ★ "on fast parts ... as it is now": a lay whose last time here (with the map the solid view waits for) is a second or
    /// less is fast; longer, slow; a first lay foreseen from its box and cells (a coarse cell quick, a fine one slow); nothing
    /// known: fast (the switch covers it).
    func testFastOrSlowIsDecidedAtTheAsk() {
        XCTAssertFalse(T.plan(lastLayS: 0.49, mapS: 0.3, estimateS: nil).scaffold, "★ stand-solid-7s' lay (0.8 s): fast")
        XCTAssertTrue(T.plan(lastLayS: 12, mapS: 0.4, estimateS: nil).scaffold, "★ a 12 s lay: the scaffold")
        XCTAssertEqual(T.plan(lastLayS: 12, mapS: 0.4, estimateS: nil).expectedS ?? 0, 12.4, accuracy: 1e-9)
        XCTAssertTrue(T.plan(lastLayS: 0.9, mapS: 0.3, estimateS: nil).scaffold, "over a second with its map: slow")
        XCTAssertFalse(T.plan(lastLayS: nil, mapS: nil, estimateS: nil).scaffold, "nothing known: fast")
        let stand = (lo: SIMD3<Float>(0, 0, 0), hi: SIMD3<Float>(120, 45, 85))
        let coarse = try! XCTUnwrap(T.estimateS(box: stand, cellLoMM: 10, cellHiMM: 10))
        let fine = try! XCTUnwrap(T.estimateS(box: stand, cellLoMM: 4, cellHiMM: 4))
        XCTAssertFalse(T.plan(lastLayS: nil, mapS: nil, estimateS: coarse).scaffold, "a first lay, 10 mm cells: fast (\(coarse) s)")
        XCTAssertTrue(T.plan(lastLayS: nil, mapS: nil, estimateS: fine).scaffold, "a first lay, 4 mm cells: slow (\(fine) s)")
        XCTAssertFalse(T.plan(lastLayS: 0.4, mapS: nil, estimateS: fine).scaffold, "★ the part's own last time wins over the estimate")
    }

    // MARK: a fast lay — no scaffold

    /// ★ A fast lay rises as he liked it (stand-solid-7s): the walls off floor by floor after the landing, then each floor's
    /// columns and bays, 7 s from the ask — never a lift of scaffold, on the clock or on screen, though its rough cut-open was made
    /// (in case it ran past a second). RED CONTROL `controlScaffoldAlways`: the scaffold rises on a quick lay too.
    func testAFastLayRisesAsHeLikedItWithNoScaffold() throws {
        for red in [false, true] {
            LatticeBuildShow.controlScaffoldAlways = red
            let (r, device) = try pocketRenderer()
            let show = LatticeBuildShow()
            r.applyBuildShow(show)
            let t0 = CACurrentMediaTime() + 1000
            LatticeBuildShow.clockForTesting = t0
            let plan = T.plan(lastLayS: 0.5, mapS: 0.2, estimateS: nil)
            XCTAssertFalse(plan.scaffold, "premise: a quick lay")
            show.layBegins(walls: true, scaffold: plan.scaffold, mayScaffold: true, expectedS: plan.expectedS, now: t0)
            _ = try frame(r)
            let made = try XCTUnwrap(S.make(Self.pocketRough(), up: show.viewAxes.up, across: show.viewAxes.across, walls: true))
            LatticeBuildShow.clockForTesting = t0 + 0.2
            show.scaffoldArrived(S.drawing(made, token: show.scaffoldToken), now: t0 + 0.2)
            var strawSeen = 0, lifts = 0
            var t = t0 + 0.2
            let land = t0 + 0.7
            var landed = false
            while t < t0 + 9 {
                LatticeBuildShow.clockForTesting = t
                if !landed, t >= land {
                    landed = true
                    r.applyLayoutBars(LatticeLayoutBarsInputs(token: 2, bars: Self.pocketBars(), solid: Notes24IntoThePartTests.pocketMap(token: 2)),
                                      device: device)
                    show.landed(token: 2, box: LatticeLayoutBarsPass.box(Self.pocketBars()), now: land)
                }
                let px = try frame(r)
                strawSeen = Swift.max(strawSeen, Self.straw(px))
                lifts = Swift.max(lifts, r.lastScaffold?.lifts ?? 0)
                t += 1.0 / 15
            }
            let tl = try XCTUnwrap(show.timelapse)
            print("NOTES30 FAST\(red ? " RED" : ""): scaffolding \(tl.scaffolding); straw px at most \(strawSeen); lifts \(lifts); end \(String(format: "%.2f", (tl.end ?? 0) - t0)) s")
            if red {
                XCTAssertTrue(tl.scaffolding, "RED CONTROL: the scaffold's path on a quick lay")
                XCTAssertGreaterThan(lifts, 0, "RED CONTROL: its lifts drawn")
                XCTAssertGreaterThan(strawSeen, 50, "RED CONTROL: the scaffold on screen")
                continue
            }
            XCTAssertFalse(tl.scaffolding, "★ a quick lay: the fast path")
            XCTAssertNil(tl.liftsFrom, "★ no lift of scaffold planned")
            XCTAssertEqual(lifts, 0, "★ no lift drawn")
            XCTAssertLessThan(strawSeen, 10, "★ nothing of a scaffold on screen")
            XCTAssertNil(r.scaffoldBars, "★ its scaffold never sent to the GPU")
            XCTAssertEqual(try XCTUnwrap(tl.end) - t0, T.totalS, accuracy: 1e-9, "★ his 7 s")
            XCTAssertEqual(tl.snapTimes.count, tl.floors * tl.snapsPerFloor, "★ each floor: its walls, its columns, its bays")
        }
    }

    // MARK: a slow lay — the walls first, the scaffold, the real floors replacing it

    /// ★ A slow lay (12 s): the walls come off first, floor by floor in hard snaps, the moment its rough cut-open is made; then
    /// the scaffold rises lift by lift (each its uprights, then its bays), topping out before the landing, nothing of the real
    /// lattice before it lands; then the real floors replace it floor by floor — each floor's columns and bays, then that lift
    /// struck — until nothing of the scaffold is left, before the topped-out beat; at least 7 s. RED CONTROL `controlNoScaffold`:
    /// the part stands closed until it lands (release 21's wait).
    func testASlowLayOpensTheWallsFirstThenTheScaffoldRisesAndTheRealFloorsReplaceIt() throws {
        for red in [false, true] {
            LatticeBuildShow.controlNoScaffold = red
            let show = LatticeBuildShow()
            let t0 = CACurrentMediaTime() + 1000
            let plan = T.plan(lastLayS: 12, mapS: nil, estimateS: nil)
            show.layBegins(walls: true, scaffold: plan.scaffold, mayScaffold: true, expectedS: plan.expectedS, now: t0)
            let made = try XCTUnwrap(S.make(Self.window, up: SIMD3(0, 0, 1), across: SIMD3(1, 0, 0), walls: true))
            XCTAssertGreaterThan(made.members, 50, "premise: a scaffold")
            show.scaffoldArrived(S.drawing(made, token: show.scaffoldToken), now: t0 + 0.4)
            let land = t0 + 12
            var log: [(t: Double, s: T.Shown?)] = []
            var t = t0
            while t < land {
                _ = show.revealScaffold(at: t)
                log.append((t - t0, show.timelapse?.shown(at: t)))
                t += 0.002
            }
            show.landed(token: 9, now: land)
            let tl = try XCTUnwrap(show.timelapse), end = try XCTUnwrap(tl.end)
            t = land
            while t <= end + 0.01 {
                _ = show.revealScaffold(at: t)
                log.append((t - t0, show.timelapse?.shown(at: t)))
                t += 0.002
            }
            let before = log.filter { $0.t < 12 }
            if red {
                XCTAssertTrue(before.allSatisfy { $0.s == nil }, "RED CONTROL: the part closed and nothing shown until it lands")
                XCTAssertNil(show.revealScaffold(at: land + 1), "RED CONTROL: no scaffold")
                continue
            }
            let floors = tl.floors, all = floors * T.perFloor
            XCTAssertTrue(before.allSatisfy { ($0.s?.snaps ?? 0) == 0 }, "★ nothing of the real lattice before it lands")
            // the walls first: every floor's walls off before the first lift, in hard snaps
            let firstWall = try XCTUnwrap(before.first { ($0.s?.opened ?? 0) > 0 }?.t)
            let allWalls = try XCTUnwrap(before.first { ($0.s?.opened ?? 0) == floors }?.t)
            let firstLift = try XCTUnwrap(before.first { ($0.s?.lifts ?? 0) > 0 }?.t)
            XCTAssertLessThanOrEqual(firstWall, 0.52, "★ the walls come off right away (the site's half second)")
            XCTAssertLessThan(allWalls, firstLift, "★ the walls first, then the scaffold")
            // the scaffold: lift by lift, one snap at a time, topped out before the landing (paced to it)
            let topped = try XCTUnwrap(before.first { ($0.s?.lifts ?? 0) == all }?.t, "★ the scaffold topped out before the landing")
            XCTAssertGreaterThan(topped, 0.75 * (12 - T.marginS), "★ paced to the landing, never all at once (topped at \(topped) s)")
            XCTAssertLessThan(topped, 12 - T.marginS + 1e-6, "★ topped out before the landing")
            var last: T.Shown?
            var liftSnaps = 0, realSnaps = 0, strikes = 0
            for e in log {
                guard let s = e.s else { continue }
                if let l = last {
                    XCTAssertGreaterThanOrEqual(s.lifts, l.lifts, "the scaffold only rises")
                    XCTAssertLessThanOrEqual(s.lifts - l.lifts, 1, "★ a hard snap: one at a time")
                    XCTAssertGreaterThanOrEqual(s.snaps, l.snaps, "★ the real lattice only ever grows")
                    XCTAssertLessThanOrEqual(s.snaps - l.snaps, 1)
                    XCTAssertGreaterThanOrEqual(s.struck, l.struck, "a lift struck stays struck")
                    if s.lifts > l.lifts { liftSnaps += 1 }
                    if s.snaps > l.snaps { realSnaps += 1 }
                    if s.struck > l.struck {
                        strikes += 1
                        XCTAssertEqual(s.struck - l.struck, T.perFloor, "★ a whole lift struck at once")
                    }
                }
                XCTAssertLessThanOrEqual(s.struck, s.snaps / T.perFloor * T.perFloor, "★ a lift struck only once its real floor stands")
                last = s
            }
            XCTAssertEqual(liftSnaps, all, "★ every lift's snaps seen, one by one (its uprights, its bays)")
            XCTAssertEqual(realSnaps, all, "★ every real floor's snaps seen, one by one")
            XCTAssertEqual(strikes, floors, "★ the scaffold struck floor by floor")
            XCTAssertEqual(last?.snaps, all, "★ it ends on the whole lattice")
            XCTAssertEqual(last?.struck, all, "★ nothing of the scaffold left")
            let gone = try XCTUnwrap(log.first { $0.s?.struck == all }?.t)
            XCTAssertLessThanOrEqual(gone, end - t0 - T.toppedOutS + 1e-6, "★ struck before the topped-out beat: the finished lattice stands alone")
            XCTAssertGreaterThanOrEqual(end - t0, T.totalS, "at least 7 s")
            XCTAssertNil(show.revealScaffold(at: end + 0.01), "★ over: no scaffold")
            print(String(format: "NOTES30 SLOW: walls %.2f–%.2f s, lifts from %.2f, topped out %.2f, landed 12.00, scaffold gone %.2f, end %.2f s",
                         firstWall, allWalls, firstLift, topped, gone, end - t0))
        }
    }

    /// ★ The scaffold on screen (the solid view): the rough cut-open opens the part's walls, its inside shaded, before any lift;
    /// the pale scaffold rises lift by lift; at the landing the real (purple) lattice goes in floor by floor as the scaffold comes
    /// down; nothing of the scaffold drawn in the topped-out beat, and none left once it is over (its pass gone). RED CONTROL
    /// `controlNeverStrike`: the scaffold still stands over the finished lattice.
    func testTheScaffoldOnScreenRisesThenComesDownAsTheRealFloorsGoIn() throws {
        for red in [false, true] {
            T.controlNeverStrike = red
            let (r, device) = try pocketRenderer()
            func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
                stride(from: 0, to: a.count, by: 4).filter { abs(Int(a[$0]) - Int(b[$0])) + abs(Int(a[$0 + 1]) - Int(b[$0 + 1])) > 24 }.count
            }
            let closed = try frame(r)
            let show = LatticeBuildShow()
            r.applyBuildShow(show)
            let t0 = CACurrentMediaTime() + 1000
            LatticeBuildShow.clockForTesting = t0
            show.layBegins(walls: true, scaffold: true, mayScaffold: true, expectedS: 6, now: t0)
            _ = try frame(r)   // (the view's axes)
            let made = try XCTUnwrap(S.make(Self.pocketRough(), up: show.viewAxes.up, across: show.viewAxes.across, walls: true))
            show.scaffoldArrived(S.drawing(made, token: show.scaffoldToken), now: t0 + 0.3)
            var opened: [Int] = [], strawUp: [Int] = [], insideShaded = false
            var checkpoint: (n: Int, straw: Int)?
            var t = t0 + 0.3
            while t < t0 + 6 {
                LatticeBuildShow.clockForTesting = t
                let px = try frame(r)
                let lifts = r.lastScaffold?.lifts ?? 0
                if lifts == 0 { opened.append(differing(closed, px)) }
                else if strawUp.count < lifts { strawUp.append(Self.straw(px)) }
                // (a lift's floor up and its walls not yet, high enough in the pocket to be lit)
                if checkpoint == nil, lifts >= 2 * T.perFloor, lifts % T.perFloor == 1 { checkpoint = (lifts, Self.straw(px)) }
                if r.insideMap != nil { insideShaded = true }
                XCTAssertLessThanOrEqual(Notes29AnimationTests.purple(px), 30, "★ no real strut before the landing")
                t += 1.0 / 30
            }
            r.applyLayoutBars(LatticeLayoutBarsInputs(token: 2, bars: Self.pocketBars(), solid: Notes24IntoThePartTests.pocketMap(token: 2)),
                              device: device)
            show.landed(token: 2, now: t0 + 6)
            let end = try XCTUnwrap(show.timelapse?.end)
            var after: [(t: Double, straw: Int, purple: Int)] = []
            t = t0 + 6
            while t < end - 1e-3 {
                LatticeBuildShow.clockForTesting = t
                let px = try frame(r)
                after.append((t - t0, Self.straw(px), Notes29AnimationTests.purple(px)))
                t += 1.0 / 30
            }
            let beat = after.filter { $0.t >= end - t0 - T.toppedOutS + 0.05 }
            print("NOTES30 ON SCREEN\(red ? " RED" : ""): walls \(opened.first ?? -1)→\(opened.last ?? -1) px; straw per lift \(strawUp); after landing straw \(after.map(\.straw)), purple \(after.map(\.purple))")
            if red {
                XCTAssertGreaterThan(beat.map(\.straw).min() ?? 0, 30, "RED CONTROL: the scaffold stands over the finished lattice")
                continue
            }
            XCTAssertGreaterThan(opened.last ?? 0, (opened.first ?? 0) + 1_000, "★ the walls off before the scaffold (the rough cut-open)")
            XCTAssertTrue(insideShaded, "★ the inside shaded by the rough cut-open")
            XCTAssertGreaterThanOrEqual(strawUp.count, 4, "★ the scaffold's snaps drawn")
            XCTAssertGreaterThan(strawUp.last ?? 0, 100, "★ the scaffold on screen")
            for (a, b) in zip(strawUp, strawUp.dropFirst()) { XCTAssertGreaterThanOrEqual(b, a - 20, "it only rises") }
            XCTAssertLessThan(strawUp.first ?? 0, strawUp.last ?? 0, "★ lift by lift")
            XCTAssertTrue(beat.allSatisfy { $0.straw < 10 }, "★ nothing of the scaffold in the topped-out beat")
            XCTAssertGreaterThan(beat.map(\.purple).min() ?? 0, 300, "★ the finished lattice")
            let peak = after.map(\.straw).max() ?? 0
            XCTAssertGreaterThan(peak, 100, "the scaffold stands at the landing")
            // ★ the shader's snaps are the plan's: the scaffold drawn at n snaps is its members coded under n, drawn whole
            let cp = try XCTUnwrap(checkpoint, "premise: a lift's floor seen before its walls")
            let (r2, d2) = try pocketRenderer()
            var keep: [Float] = []
            for (m, c) in made.layout.codes.enumerated() where S.step(code: c) < cp.n { keep += Array(made.bars[(7 * m)..<(7 * m + 7)]) }
            let map = made.drawn.map { LatticeLayoutSolidGrid(token: 9, origin: made.rough.origin, voxel: made.rough.voxel,
                                                              dims: made.rough.dims, rg: $0, smooth: true) }
            r2.applyLayoutBars(LatticeLayoutBarsInputs(token: 9, bars: keep, solid: map, colours: [SIMD4<Float>](repeating: S.colour, count: keep.count / 7),
                                                       colourKey: 9), device: d2)
            let whole = Self.straw(try frame(r2))
            print("NOTES30 SNAPS: at \(cp.n) snaps the scaffold drew \(cp.straw) px; its \(keep.count / 7) members coded under \(cp.n), drawn whole: \(whole) px")
            XCTAssertGreaterThan(whole, 20, "premise: the scaffold so far drawn")
            XCTAssertEqual(Double(cp.straw), Double(whole), accuracy: Double(whole) * 0.1 + 10, "★ the shader shows exactly the members coded under its snaps")
            // over: its pass gone
            _ = show.step(end + 0.01)
            LatticeBuildShow.clockForTesting = end + 0.02
            let px = try frame(r)
            XCTAssertNil(show.scaffold, "★ nothing of the scaffold left")
            XCTAssertNil(r.scaffoldBars, "★ its pass gone")
            XCTAssertLessThan(Self.straw(px), 10)
        }
    }

    // MARK: the switch

    /// ★ "if the engine is still working after about 1 s anyway, switch to the scaffold then": a lay foreseen quick that has not
    /// landed a second after the ask takes the scaffold's path then (its walls at once, its lifts after); one landing before it
    /// never does; one with no rough cut-open made rises as a quick one when it lands. RED CONTROL `controlNoSwitch`: it stays
    /// closed until it lands.
    func testALayStillWorkingAfterOneSecondSwitchesToTheScaffold() throws {
        let made = try XCTUnwrap(S.make(Self.window, up: SIMD3(0, 0, 1), across: SIMD3(1, 0, 0), walls: true))
        for red in [false, true] {
            T.controlNoSwitch = red
            let show = LatticeBuildShow()
            let t0 = CACurrentMediaTime() + 1000
            show.layBegins(walls: true, scaffold: false, mayScaffold: true, expectedS: 0.6, now: t0)
            show.scaffoldArrived(S.drawing(made, token: show.scaffoldToken), now: t0 + 0.15)
            XCTAssertNil(show.revealScaffold(at: t0 + 0.99), "a quick lay, before the second: no scaffold")
            XCTAssertNil(show.timelapse?.shown(at: t0 + 0.99), "the site")
            let at1 = show.revealScaffold(at: t0 + 1.0)
            let s2 = show.timelapse?.shown(at: t0 + 1.0)
            let s3 = show.revealScaffold(at: t0 + 4)
            show.landed(token: 5, now: t0 + 5)
            let end = try XCTUnwrap(show.timelapse?.end)
            if red {
                XCTAssertNil(at1, "RED CONTROL: no switch")
                XCTAssertNil(s3, "RED CONTROL: closed until it lands")
                XCTAssertFalse(show.timelapse?.scaffolding ?? true)
                continue
            }
            XCTAssertNotNil(at1, "★ switched at the second")
            XCTAssertEqual(s2?.opened, 1, "★ its walls first, at once")
            XCTAssertGreaterThan(s3?.lifts ?? 0, 0, "★ the scaffold rises while it works")
            XCTAssertEqual(show.timelapse?.shown(at: end)?.struck, show.timelapse.map { $0.floors * T.perFloor }, "★ all struck by the end")
        }
        // one that lands before the second: never
        T.controlNoSwitch = false
        let quick = LatticeBuildShow()
        let t1 = CACurrentMediaTime() + 2000
        quick.layBegins(walls: true, mayScaffold: true, expectedS: 0.6, now: t1)
        quick.scaffoldArrived(S.drawing(made, token: quick.scaffoldToken), now: t1 + 0.15)
        quick.landed(token: 6, now: t1 + 0.8)
        for k in 0..<200 { XCTAssertNil(quick.revealScaffold(at: t1 + 0.8 + Double(k) * 0.05), "★ landed in time: the fast path") }
        XCTAssertFalse(quick.timelapse?.scaffolding ?? true)
        // no rough cut-open made: the switch shows nothing, and the landing is the fast path's
        let none = LatticeBuildShow()
        none.layBegins(walls: true, mayScaffold: true, expectedS: 0.6, now: t1)
        XCTAssertNil(none.timelapse?.shown(at: t1 + 2), "nothing to show without its rough cut-open")
        none.landed(token: 7, now: t1 + 3)
        XCTAssertFalse(none.timelapse?.scaffolding ?? true, "★ it rises as a quick one")
        XCTAssertNotNil(none.timelapse?.fastPlan)
    }

    // MARK: never the scaffold for Organic, Live preview, Skip all animations or the sample

    /// ★ Organic keeps its own growth ("two different animations"), a Live preview lay has no animation, Skip all animations
    /// shows the card, and the Settings sample is always the fast path: none of them is armed for the scaffold or asks the rough
    /// cut-open. RED CONTROLS: `controlScaffoldAnyLay` (every lay armed); an armed show (the sample's would switch).
    func testOrganicLivePreviewSkipAndTheSampleNeverGetTheScaffold() {
        XCTAssertTrue(LatticeLayoutPreview.armsScaffold(organic: false, quiet: false, skip: false), "premise: a strut lay is armed")
        XCTAssertFalse(LatticeLayoutPreview.armsScaffold(organic: true, quiet: false, skip: false), "★ Organic: its own growth")
        XCTAssertFalse(LatticeLayoutPreview.armsScaffold(organic: false, quiet: true, skip: false), "★ Live preview: no animation")
        XCTAssertFalse(LatticeLayoutPreview.armsScaffold(organic: false, quiet: false, skip: true), "★ Skip all animations: the card")
        LatticeLayoutPreview.controlScaffoldAnyLay = true
        XCTAssertTrue(LatticeLayoutPreview.armsScaffold(organic: true, quiet: true, skip: true), "RED CONTROL: every lay armed")
        LatticeLayoutPreview.controlScaffoldAnyLay = false
        // the Settings sample: `layBegins()` as it calls it — never armed, never switched, never wanting the rough cut-open
        let sample = LatticeBuildShow()
        let t0 = CACurrentMediaTime() + 1000
        sample.layBegins(now: t0)
        XCTAssertFalse(sample.wantsRough, "★ the sample asks no rough cut-open")
        sample.step(t0 + 5)
        XCTAssertFalse(sample.timelapse?.scaffolding ?? true, "★ the sample: the fast path, however long it lays")
        let armed = LatticeBuildShow()
        armed.layBegins(mayScaffold: true, now: t0)
        XCTAssertTrue(armed.wantsRough, "RED CONTROL: an armed show wants it")
        armed.step(t0 + 5)
        XCTAssertTrue(armed.timelapse?.scaffolding ?? false, "RED CONTROL: an armed show switches")
        // Skip all animations: an armed lay is disarmed (the card, the lattice whole at once)
        AppSettings.skipAllAnimations = true
        let skip = LatticeBuildShow()
        skip.layBegins(walls: true, scaffold: true, mayScaffold: true, expectedS: 12, now: t0)
        XCTAssertFalse(skip.wantsRough, "★ Skip all animations: no rough cut-open")
        XCTAssertFalse(skip.timelapse?.scaffolding ?? true, "★ no scaffold")
        skip.landed(token: 3, now: t0 + 12)
        XCTAssertNil(skip.timelapse, "★ shown whole at once")
        AppSettings.skipAllAnimations = false
    }

    /// ★ The page: a Live preview lay (quiet) and a lay with Skip all animations ask no rough cut-open of the engine and get no
    /// scaffold; a Click to refresh lay asks it (before its lay). RED CONTROLS: `controlLiveAnimates` (Live preview animates),
    /// Skip all animations off.
    func testThePageAsksTheRoughCutOpenOnlyForAnAnimatedStrutLay() async throws {
        let p = try FlexiblePressFixtures.cube60Project()
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.lattice.wholePart = true
        p.lattice.enabled = true
        p.lattice.cellSizeMode = .fixed
        p.lattice.cellMM = 10
        XCTAssertFalse(LatticeLayoutPreview.organic(p.lattice), "premise: a strut type")
        func lay(live: Bool, skip: Bool, red: Bool, cell: Double) async throws -> (asked: Int, armed: Bool) {
            LatticeLayoutPreview.controlLiveAnimates = red && live
            AppSettings.skipAllAnimations = skip && !red
            defer { LatticeLayoutPreview.controlLiveAnimates = false; AppSettings.skipAllAnimations = false }
            let preview = LatticeLayoutPreview()
            defer { preview.clear() }
            p.lattice.cellMM = cell
            let before = LatticeLayoutPreview.roughCutsAsked
            preview.update(project: p, on: true, solid: true, live: live)
            let armed = preview.build.timelapse?.mayScaffold ?? false
            let end = Date().addingTimeInterval(300)
            while preview.laying, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
            XCTAssertFalse(preview.laying, "the lay ended")
            XCTAssertNotNil(preview.bars, "premise: laid")
            return (LatticeLayoutPreview.roughCutsAsked - before, armed)
        }
        let quiet = try await lay(live: true, skip: false, red: false, cell: 10)
        XCTAssertEqual(quiet.asked, 0, "★ Live preview: no rough cut-open asked")
        XCTAssertFalse(quiet.armed, "★ Live preview: no scaffold")
        let quietRed = try await lay(live: true, skip: false, red: true, cell: 11)
        XCTAssertEqual(quietRed.asked, 1, "RED CONTROL: Live preview animating asks it")
        let skip = try await lay(live: false, skip: true, red: false, cell: 12)
        XCTAssertEqual(skip.asked, 0, "★ Skip all animations: none asked")
        XCTAssertFalse(skip.armed, "★ Skip all animations: no scaffold")
        let loud = try await lay(live: false, skip: true, red: true, cell: 13)
        XCTAssertEqual(loud.asked, 1, "RED CONTROL (Skip off): a Click to refresh strut lay asks it, before its lay")
        XCTAssertTrue(loud.armed)
    }

    // MARK: never a real strut shown then taken away

    /// ★ img 97 never again, and nothing of the real lattice ever taken away: over quick and slow lays, switched or not, landing
    /// early or late, in the solid view or X-ray, the real lattice's snaps only ever grow and the scaffold's strikes never touch
    /// it; on screen, the real (purple) lattice only rises after its landing while the scaffold comes down. RED CONTROL
    /// `controlStrikeRealToo` (the struck lifts applied to the real lattice too): its floors vanish as the scaffold comes down.
    func testNoStrutOfTheRealLatticeIsEverShownThenRemoved() throws {
        let made = try XCTUnwrap(S.make(Self.window, up: SIMD3(0, 0, 1), across: SIMD3(1, 0, 0), walls: true))
        var cases = 0
        for slow in [false, true] { for walls in [false, true] { for landS in [0.3, 0.9, 1.4, 3.0, 8.0, 20.0] {
            for expected in [nil, 0.6, 6.0, 12.0] as [Double?] { for rough in [true, false] {
                let show = LatticeBuildShow()
                let t0 = CACurrentMediaTime() + 1000
                show.layBegins(walls: walls, scaffold: slow, mayScaffold: true, expectedS: expected, now: t0)
                if rough { show.scaffoldArrived(S.drawing(made, token: show.scaffoldToken), now: t0 + 0.2) }
                var level = -1   // −1: nothing (the site); n: the snaps shown; .max: the whole
                var t = t0
                var landed = false
                let what = "slow \(slow), walls \(walls), land \(landS), expected \(String(describing: expected)), rough \(rough)"
                while t < t0 + landS + 12 {
                    if !landed, t >= t0 + landS { landed = true; show.landed(token: 4, box: (SIMD3(10, 0, 6), SIMD3(70, 50, 48)), now: t0 + landS) }
                    let now: Int
                    switch show.reveal(barsToken: 4, floors: 4, at: t) {
                    case .all: now = .max
                    case .snaps(let n): now = n
                    case .none: now = -1
                    }
                    if !landed { XCTAssertEqual(now, -1, "nothing real before it lands (\(what))") }
                    XCTAssertGreaterThanOrEqual(now, level, "★ the real lattice only grows, never shown then taken away (\(what))")
                    level = Swift.max(level, now)
                    t += 0.01
                }
                XCTAssertEqual(level, .max, "it ends on the whole lattice (\(what))")
                cases += 1
            }}
        }}}
        XCTAssertEqual(cases, 2 * 2 * 6 * 4 * 2)
        // on screen
        for red in [false, true] {
            LatticeBuildShow.controlStrikeRealToo = red
            let (r, device) = try pocketRenderer()
            let show = LatticeBuildShow()
            r.applyBuildShow(show)
            let t0 = CACurrentMediaTime() + 1000
            LatticeBuildShow.clockForTesting = t0
            show.layBegins(walls: true, scaffold: true, mayScaffold: true, expectedS: 4, now: t0)
            _ = try frame(r)
            let pocket = try XCTUnwrap(S.make(Self.pocketRough(), up: show.viewAxes.up, across: show.viewAxes.across, walls: true))
            show.scaffoldArrived(S.drawing(pocket, token: show.scaffoldToken), now: t0 + 0.2)
            r.applyLayoutBars(LatticeLayoutBarsInputs(token: 2, bars: Self.pocketBars(), solid: Notes24IntoThePartTests.pocketMap(token: 2)),
                              device: device)
            show.landed(token: 2, now: t0 + 4)
            let end = try XCTUnwrap(show.timelapse?.end)
            var purple: [Int] = []
            var t = t0 + 4
            while t < end - 1e-3 {
                LatticeBuildShow.clockForTesting = t
                purple.append(Notes29AnimationTests.purple(try frame(r)))
                t += 1.0 / 30
            }
            let peak = purple.max() ?? 0
            let drops = zip(purple, purple.dropFirst()).map { $0 - $1 }.max() ?? 0
            print("NOTES30 REAL\(red ? " RED" : ""): purple after the landing \(purple)")
            if red {
                XCTAssertLessThan(purple.last ?? 0, peak / 3, "RED CONTROL: real floors vanish as the scaffold comes down")
                XCTAssertGreaterThan(drops, 0, "RED CONTROL: taken away")
                continue
            }
            XCTAssertGreaterThan(peak, 300, "premise: the lattice drawn")
            XCTAssertLessThanOrEqual(drops, peak / 30, "★ the real lattice only rises: nothing of it taken away")
        }
    }

    // MARK: the rough cut-open, through the engine

    /// ★ "open up the walls first": for a CUBE lattice (Organic's map ahead cannot serve it: it needs the laid cells), the rough
    /// cut-open is made before the lay — the lattice's area open, the exact map's open voxels within it (its edge may shift
    /// slightly) — and the lay after it is the same lay, strut for strut, as one with nothing asked first. RED CONTROL:
    /// `gridAhead` (Organic's map ahead) has no map for it.
    func testTheRoughCutOpenIsMadeBeforeTheLayAndLeavesTheLayAsItWas() async throws {
        func session() async throws -> (LatticeLayoutSession, LatticeLayoutSession.Settings, (lo: SIMD3<Float>, hi: SIMD3<Float>)) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scaffold-rough-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
            let path = dir.appendingPathComponent("block.stl").path
            try LatticePlaceChipsTests.gridSTL([0, 40], [0, 30], [0, 24]) { _, _, _ in true }.write(to: URL(fileURLWithPath: path))
            let mesh = try TopOptKit.importMesh(path: path)
            let s = try await LatticeLayoutSession.open(path: path)
            addTeardownBlock { s.close() }
            var set = LatticeLayoutSession.Settings()
            set.topology = "bccz"; set.algorithm = "uniform"; set.cellMM = 6; set.cellMaxMM = 6
            // a lattice zone through the block front to back (the stand fixture's kind: Notes29's clips)
            var z = LatticeLayoutSession.Region(id: 1, faces: [], depthMM: 0)
            z.zone = .init(kind: .box, centre: SIMD3(20, 15, 12), axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                           half: SIMD3(14, 20, 8))
            set.regions = [z]
            return (s, set, try XCTUnwrap(LatticeLayoutPreview.box(mesh.vertices)))
        }
        let (s, set, box) = try await session()
        let g = LatticeLayoutPreview.roughGeometry(box)
        let ahead = try await s.gridAhead(set, origin: g.origin, voxel: g.voxel, dims: g.dims)
        XCTAssertNil(ahead, "RED CONTROL: Organic's map ahead cannot serve a cube lattice")
        let t0 = Date()
        let asked = try await s.gridRough(set, origin: g.origin, voxel: g.voxel, dims: g.dims)
        let rough = try XCTUnwrap(asked, "★ the rough cut-open, before the lay")
        let roughMS = Date().timeIntervalSince(t0) * 1000
        let r = S.Rough(origin: g.origin, voxel: g.voxel, dims: g.dims, rg: rough.rg)
        let laid = try await s.lay(set)
        XCTAssertGreaterThan(laid.barCount, 50, "premise: laid")
        // the exact map on the same voxels: its open lattice within the rough area (allowing its edge a voxel's shift)
        let exact = try await s.grid(origin: g.origin, voxel: g.voxel, dims: g.dims)
        var exactOpen = 0, within = 0, roughOpen = 0
        for i in 0..<(rough.rg.count / 2) {
            let ro = rough.rg[2 * i] > 0 && rough.rg[2 * i + 1] > 0, eo = exact.rg[2 * i] > 0 && exact.rg[2 * i + 1] > 0
            if ro { roughOpen += 1 }
            if eo { exactOpen += 1; if ro { within += 1 } }
        }
        print("NOTES30 ROUGH: \(roughOpen) rough-open voxels, \(exactOpen) exact-open (\(within) within the rough), made in \(Int(roughMS)) ms (\(g.dims))")
        XCTAssertGreaterThan(exactOpen, 100, "premise: the exact map opens the lattice")
        XCTAssertGreaterThanOrEqual(Double(within), 0.97 * Double(exactOpen), "★ the exact cut within the rough one")
        XCTAssertLessThan(Double(roughOpen), 2.0 * Double(exactOpen), "★ rough, but the same area (its edge shifts slightly)")
        let made = try XCTUnwrap(S.make(r, up: SIMD3(0, 0, 1), across: SIMD3(1, 0, 0), walls: true))
        XCTAssertGreaterThan(made.members, 10, "★ a scaffold stands in it")
        // the lay after the rough cut-open is the lay with nothing asked first
        let (fresh, set2, _) = try await session()
        let plain = try await fresh.lay(set2)
        XCTAssertEqual(plain.barCount, laid.barCount, "★ the same lay")
        XCTAssertEqual(plain.bars, laid.bars, "★ strut for strut")
    }

    // MARK: the scaffold's look

    /// What makes a scaffold, not a lattice: its uprights all one lift tall on one even grid, ledgers level, braces and a stair
    /// (stringers turning back lift by lift), every member thin and whole in the area, in a pale colour that is not the
    /// lattice's.
    static func scaffoldLike(_ bars: [Float], frame f: T.Frame, bay: Float? = nil, inArea: (SIMD3<Float>) -> Bool,
                             colour: SIMD4<Float>) -> [String] {
        var fails: [String] = []
        let s = bay ?? f.floorH * S.bayShare
        var uprights = 0, diagonals = 0, level = 0
        var risingRight: [Int: [Bool]] = [:]
        var acrossAt: [Float] = []
        for i in stride(from: 0, to: bars.count - 6, by: 7) {
            let a = SIMD3(bars[i], bars[i + 1], bars[i + 2]), b = SIMD3(bars[i + 3], bars[i + 4], bars[i + 5])
            let d = b - a, len = simd_length(d), rise = simd_dot(d, f.up)
            if bars[i + 6] > S.widthMostMM + 1e-4 { fails.append("a member \(bars[i + 6]) mm wide: not thin"); break }
            if !S.samples.allSatisfy({ inArea(a + d * $0) }) { fails.append("a member out of the area"); break }
            if abs(rise) / Swift.max(len, 1e-6) > 0.99 {
                uprights += 1
                if abs(len - f.floorH) > 1e-3 { fails.append("an upright \(len) mm, the lift \(f.floorH) mm: heights differ"); break }
                acrossAt.append(simd_dot(f.across, a))
            } else if abs(rise) < 1e-4 { level += 1 }
            else {
                diagonals += 1
                let lift = f.floor(ofHeight: Swift.min(simd_dot(f.up, a), simd_dot(f.up, b)))
                let run = simd_dot(f.across, d) + simd_dot(f.depth, d)   // (a brace's bay runs along across or along depth)
                risingRight[lift, default: []].append((run > 0) == (rise > 0))
            }
        }
        // one even grid: the uprights stand a whole number of bays apart
        if let a0 = acrossAt.min(), acrossAt.contains(where: { abs(($0 - a0) / s - (($0 - a0) / s).rounded()) > 1e-3 }) {
            fails.append("the uprights off one even grid")
        }
        if uprights == 0 { fails.append("no uprights") }
        if level == 0 { fails.append("no ledgers") }
        if diagonals == 0 { fails.append("no braces or stair") }
        // a zig-zag: the diagonals of one lift lean one way, the next lift's the other (most of them)
        let leans = (0..<f.floors).compactMap { k in risingRight[k].map { v in v.filter { $0 }.count * 2 > v.count } }
        if leans.count >= 2, zip(leans, leans.dropFirst()).contains(where: { $0 == $1 }) { fails.append("the braces do not zig-zag") }
        let lattice = LatticeLayoutBarsPass.colour
        let c = SIMD3(colour.x, colour.y, colour.z)
        if simd_distance(c, SIMD3(Float(lattice.r), Float(lattice.g), Float(lattice.b))) < 0.3 { fails.append("the lattice's colour") }
        if simd_dot(c, SIMD3(0.299, 0.587, 0.114)) < 0.75 { fails.append("not pale") }
        return fails
    }

    /// ★ "I don't think scaffolds ever differ in heights": one even grid, one lift height; uprights and ledgers, braces and a
    /// zig-zag stair; thin and pale, never mistakable for the lattice's struts; every member whole in the area; every lift has its
    /// members (each counted with its own lift by its snap). RED CONTROL: a lattice's struts (the cell frame Notes29 builds, in the
    /// lattice's colour) fail the same test.
    func testTheScaffoldIsOneEvenGridBracedWithAStairThinAndPale() throws {
        let made = try XCTUnwrap(S.make(Self.window, up: SIMD3(0, 0, 1), across: SIMD3(1, 0, 0), walls: true))
        let f = made.frame
        let fails = Self.scaffoldLike(made.bars, frame: f, bay: made.layout.bay, inArea: Self.window.inArea, colour: S.colour)
        XCTAssertEqual(fails, [], "★ a scaffold")
        var perLift = [Int](repeating: 0, count: f.floors)
        for c in made.layout.codes { perLift[S.step(code: c) / T.perFloor] += 1 }
        XCTAssertTrue(perLift.allSatisfy { $0 > 0 }, "★ every lift has its members: \(perLift)")
        XCTAssertLessThan(S.width(liftH: f.floorH), 0.81, "★ thin")
        XCTAssertLessThanOrEqual(made.members, S.membersMost, "★ the instance count bounded")
        print("NOTES30 SCAFFOLD: \(made.members) members over \(f.floors) lifts of \(f.floorH) mm (bay \(made.layout.bay) mm, \(made.layout.nA)×\(made.layout.nD) squares), \(S.width(liftH: f.floorH)) mm wide; per lift \(perLift)")
        // RED CONTROL: a lattice's struts are not a scaffold
        let lattice = Notes29AnimationTests.frameBars(cell: 6)
        let box = try XCTUnwrap(LatticeLayoutBarsPass.box(lattice))
        let lf = T.Frame(lo: box.lo, hi: box.hi, up: SIMD3(0, 0, 1), across: SIMD3(1, 0, 0))
        let c = LatticeLayoutBarsPass.colour
        let red = Self.scaffoldLike(lattice, frame: lf, inArea: { _ in true }, colour: SIMD4(Float(c.r), Float(c.g), Float(c.b), 1))
        XCTAssertFalse(red.isEmpty, "RED CONTROL: a lattice is not a scaffold")
    }

    // MARK: ★ his verdict on the clips (11-26 22:30, 22:40): closed floors, nothing floating, through the whole hole, in order

    /// A curved area (never his file): in a block 90 × 60 × 40 mm, a round lattice area narrowing as it rises (a cone, 30 mm
    /// round at its foot, 10 at its top) — every lift's squares fewer than the one below's: steps at every level.
    static let curved: S.Rough = {
        let v: Float = 1.5, part = SIMD3<Float>(90, 60, 40)
        let origin = SIMD3<Float>(repeating: -v)
        let dims = SIMD3<Int32>(Int32((part.x / v).rounded(.up)) + 3, Int32((part.y / v).rounded(.up)) + 3, Int32((part.z / v).rounded(.up)) + 3)
        var rg = [Int8]()
        for z in 0..<Int(dims.z) { for y in 0..<Int(dims.y) { for x in 0..<Int(dims.x) {
            let p = origin + SIMD3(Float(x), Float(y), Float(z)) * v
            let inside = all(p .>= SIMD3(repeating: -0.01)) && all(p .<= part + 0.01)
            let r = 30 - 0.5 * p.z
            let open = inside && (p.x - 45) * (p.x - 45) + (p.y - 30) * (p.y - 30) < r * r
            rg += [open ? 127 : -127, inside ? 127 : -127]
        }}}
        return S.Rough(origin: origin, voxel: v, dims: dims, rg: rg)
    }()

    /// Whether the scaffold STANDS: every member's ends meet another member (within the ground and roof floors' hair) or the
    /// ground lift's foot, and the whole is ONE structure standing on the ground. The failures, at most five.
    static func stands(_ m: S.Made) -> [String] {
        let bars = m.bars, n = bars.count / 7, f = m.frame
        guard n > 0, let g = m.layout.ground else { return ["no scaffold"] }
        let tol = S.edgeShare * f.floorH + 1e-3, ground = m.layout.height(g)
        let segs = (0..<n).map { i in (SIMD3(bars[7 * i], bars[7 * i + 1], bars[7 * i + 2]), SIMD3(bars[7 * i + 3], bars[7 * i + 4], bars[7 * i + 5])) }
        func dist(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            let d = b - a, t = Swift.max(0, Swift.min(1, simd_dot(p - a, d) / Swift.max(simd_dot(d, d), 1e-12)))
            return simd_distance(p, a + d * t)
        }
        var parent = Array(0...n)   // n: the ground
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        func join(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }
        var fails: [String] = []
        for i in 0..<n { for p in [segs[i].0, segs[i].1] {
            var met = false
            if abs(simd_dot(f.up, p) - ground) <= tol { met = true; join(i, n) }
            for j in 0..<n where j != i && dist(p, segs[j].0, segs[j].1) <= tol { met = true; join(i, j) }
            if !met, fails.count < 5 { fails.append(String(format: "a member's end in mid-air at (%.1f, %.1f, %.1f)", p.x, p.y, p.z)) }
        }}
        let pieces = Set((0...n).map(find)).count
        if pieces != 1 { fails.append("\(pieces) pieces: not one structure on the ground") }
        return fails
    }
    /// Each lift's floor outline is ONE closed loop (every node on it meets two of its edges — four where it pinches — and all
    /// of it connected).
    static func closedLoops(_ L: S.Layout) -> [String] {
        var fails: [String] = []
        for (k, set) in L.squares.enumerated() where !set.isEmpty {
            let o = S.outline(set)
            var degree: [S.Node: Int] = [:], next: [S.Node: [S.Node]] = [:]
            for e in o { degree[e.a, default: 0] += 1; degree[e.b, default: 0] += 1; next[e.a, default: []].append(e.b); next[e.b, default: []].append(e.a) }
            if degree.values.contains(where: { $0 != 2 && $0 != 4 }) { fails.append("lift \(k): its outline is not closed") }
            var seen: Set<S.Node> = [], todo = Array(degree.keys.prefix(1))
            while let x = todo.popLast() { if seen.insert(x).inserted { todo += next[x] ?? [] } }
            if seen.count != degree.count { fails.append("lift \(k): its outline is more than one loop") }
        }
        return fails
    }

    /// ★ "It can't just float": on the curved part (the area steps in and out lift by lift) and on the stand's window, every
    /// lift's floor outline is one closed loop, every member's ends meet another member (or the ground lift's foot), and the
    /// scaffold is one structure standing on the ground — the steps' landings included; every member whole in the area. RED
    /// CONTROL `controlNoLandings` (a level only its own lift's floor, the 22:15 clips'): pieces float on the curved part.
    func testEveryLiftStandsOnAClosedFloorAndNothingFloats() throws {
        for red in [false, true] {
            S.controlNoLandings = red
            defer { S.controlNoLandings = false }
            for (name, r) in [("curved", Self.curved), ("window", Self.window)] {
                let made = try XCTUnwrap(S.make(r, up: SIMD3(0, 0, 1), across: SIMD3(1, 0, 0), walls: true), name)
                let L = made.layout
                let stepsInOrOut = zip(L.squares, L.squares.dropFirst()).filter { !$0.0.isEmpty && !$0.1.isEmpty && $0.0 != $0.1 }.count
                let standing = Self.stands(made)
                print("NOTES30 STANDS (\(name)\(red ? " RED" : "")): \(made.members) members, ground lift \(L.ground ?? -1), squares per lift \(L.squares.map(\.count)), \(stepsInOrOut) steps in or out; \(standing.isEmpty ? "stands" : standing.joined(separator: "; "))")
                if red {
                    if name == "curved" { XCTAssertFalse(standing.isEmpty, "RED CONTROL: without its landings the curved part's scaffold floats") }
                    continue
                }
                if name == "curved" { XCTAssertGreaterThan(stepsInOrOut, 0, "premise: the curved area steps in or out between lifts") }
                XCTAssertGreaterThanOrEqual(L.squares.filter { !$0.isEmpty }.count, 3, "\(name): premise: lifts standing")
                XCTAssertEqual(Self.closedLoops(L), [], "★ \(name): every lift's floor outline one closed loop")
                XCTAssertEqual(standing, [], "★ \(name): nothing in mid-air, one structure on the ground")
                let bars = made.bars
                for i in stride(from: 0, to: bars.count - 6, by: 7) {
                    let a = SIMD3(bars[i], bars[i + 1], bars[i + 2]), b = SIMD3(bars[i + 3], bars[i + 4], bars[i + 5])
                    XCTAssertTrue(S.samples.allSatisfy { r.inArea(a + (b - a) * $0) }, "★ \(name): every member whole in the area")
                }
            }
        }
    }

    /// ★ "make all animation have scaffolding throughout the entire hole": the grid fills the whole opened area — an upright at
    /// every node of each lift's squares, a ledger on every edge of its floor — on the stand's window and the curved part alike,
    /// the instance count bounded. RED CONTROL `controlRimOnly` (the 22:15 clips): the rim alone.
    func testTheScaffoldFillsTheWholeHole() throws {
        for red in [false, true] {
            S.controlRimOnly = red
            defer { S.controlRimOnly = false }
            for (name, r) in [("window", Self.window), ("curved", Self.curved)] {
                let made = try XCTUnwrap(S.make(r, up: SIMD3(0, 0, 1), across: SIMD3(1, 0, 0), walls: true), name)
                let L = made.layout, f = made.frame, bars = made.bars
                var inner = 0, innerNodes = 0
                for (k, set) in L.squares.enumerated() where !set.isEmpty {
                    let rim = S.outline(set)
                    var rimNodes = Set<S.Node>(), all = Set<S.Node>()
                    for e in rim { rimNodes.insert(e.a); rimNodes.insert(e.b) }
                    for q in set { for e in S.edges(q) { all.insert(e.a); all.insert(e.b) } }
                    for nd in all.subtracting(rimNodes) {
                        innerNodes += 1
                        let p = SIMD3<Float>(repeating: 0) + f.across * (L.a0 + Float(nd.i) * L.bay) + f.depth * (L.d0 + Float(nd.j) * L.bay)
                        let foot = p + f.up * L.height(k)
                        let has = stride(from: 0, to: bars.count - 6, by: 7).contains { i in
                            simd_distance(SIMD3(bars[i], bars[i + 1], bars[i + 2]), foot) < 1e-3 && abs(bars[i + 5] - bars[i + 2]) > f.floorH * 0.9
                        }
                        if has { inner += 1 }
                    }
                }
                print("NOTES30 FILL (\(name)\(red ? " RED" : "")): \(made.members) members; inner nodes \(innerNodes), with their uprights \(inner)")
                XCTAssertGreaterThan(innerNodes, 0, "\(name): premise: the area has an inside")
                // (the rim alone keeps only the stair's own bay inside; the cone's inside is that bay)
                if red { if name == "window" { XCTAssertLessThan(inner, innerNodes / 2, "RED CONTROL: the rim alone") }; continue }
                XCTAssertEqual(inner, innerNodes, "★ \(name): an upright at every node through the whole hole")
                XCTAssertLessThanOrEqual(made.members, S.membersMost, "★ \(name): the instance count bounded")
            }
        }
    }

    /// ★ "please ensure the floors are generated before the walls ... the walls go up before the stairs. It should go: floors and
    /// walls, then stairs for the entire level." — every member's snap is its role's (the ledgers of a level: that lift's FLOOR, or
    /// the top lift's roof; uprights and braces: its WALLS; the flights and treads: its STAIRS), and as the scaffold rises — for a
    /// lay judged slow at the ask AND for one switched to a second after it — no lift's walls show before its whole floor, nor its
    /// stairs before its whole walls. RED CONTROL `controlWallsFirst`: the walls before the floor.
    func testEachLiftGoesFloorThenWallsThenStairsSlowOrSwitched() throws {
        for red in [false, true] {
            S.controlWallsFirst = red
            defer { S.controlWallsFirst = false }
            for (name, r) in [("window", Self.window), ("curved", Self.curved)] {
                let made = try XCTUnwrap(S.make(r, up: SIMD3(0, 0, 1), across: SIMD3(1, 0, 0), walls: true), name)
                let L = made.layout, f = made.frame, bars = made.bars
                // each member's role, from where it lies: a level's ledgers (a lift's floor at its foot, or the roof over the top
                // lift standing), uprights and braces (its walls), off the grid's lines (its stairs)
                enum Role: Equatable { case floor, roof, walls, stairs }
                var roles: [Role] = [], lifts: [Int] = []
                func grid(_ p: SIMD3<Float>) -> SIMD2<Float> {
                    SIMD2((simd_dot(f.across, p) - L.a0) / L.bay, (simd_dot(f.depth, p) - L.d0) / L.bay)
                }
                func onGrid(_ g: SIMD2<Float>) -> Bool { abs(g.x - g.x.rounded()) < 1e-3 && abs(g.y - g.y.rounded()) < 1e-3 }
                let e = S.edgeShare * f.floorH
                for i in stride(from: 0, to: bars.count - 6, by: 7) {
                    let a = SIMD3(bars[i], bars[i + 1], bars[i + 2]), b = SIMD3(bars[i + 3], bars[i + 4], bars[i + 5])
                    let lowH = Swift.min(simd_dot(f.up, a), simd_dot(f.up, b)), rise = abs(simd_dot(f.up, b - a))
                    if !onGrid(grid(a)) || !onGrid(grid(b)) {
                        roles.append(.stairs); lifts.append(f.floor(ofHeight: lowH + 0.5 * e))
                    } else if rise < 1e-4 {
                        let level = Int(((lowH - f.low) / f.floorH).rounded())
                        if lowH < L.height(level) - 0.5 * e { roles.append(.roof); lifts.append(level - 1) }
                        else { roles.append(.floor); lifts.append(level) }
                    } else {
                        roles.append(.walls); lifts.append(f.floor(ofHeight: lowH + 0.5 * e))
                    }
                }
                let steps = L.codes.map(S.step(code:))
                var mismatched = 0
                for (m, s) in steps.enumerated() {
                    let part: S.Part
                    switch roles[m] { case .floor: part = .floor; case .roof: part = .roof; case .walls: part = .walls; case .stairs: part = .stairs }
                    if s != lifts[m] * T.perFloor + part.rawValue { mismatched += 1 }
                }
                // as it rises: a lay judged slow at the ask, and one switched to a second after the ask
                var outOfOrder = 0
                for switched in [false, true] {
                    let show = LatticeBuildShow()
                    let t0 = CACurrentMediaTime() + 1000
                    show.layBegins(walls: true, scaffold: !switched, mayScaffold: true, expectedS: switched ? 0.6 : 12, now: t0)
                    show.scaffoldArrived(S.drawing(made, token: show.scaffoldToken), now: t0 + 0.2)
                    var t = t0
                    let landing = t0 + (switched ? 6 : 12)
                    while t < landing {
                        show.step(t)
                        if let v = show.revealScaffold(at: t) {
                            let shown = steps.map { $0 < v.lifts }
                            for k in 0..<f.floors {
                                func all(_ role: Role) -> Bool { roles.indices.filter { roles[$0] == role && steps[$0] / T.perFloor == k }.allSatisfy { shown[$0] } }
                                func any(_ role: Role) -> Bool { roles.indices.contains { roles[$0] == role && steps[$0] / T.perFloor == k && shown[$0] } }
                                if any(.walls) && !all(.floor) { outOfOrder += 1 }
                                if any(.stairs) && !all(.walls) { outOfOrder += 1 }
                            }
                        }
                        t += 0.05
                    }
                    XCTAssertTrue(show.timelapse?.scaffolding ?? false, "\(name): premise: the scaffold's path (\(switched ? "switched" : "slow at the ask"))")
                }
                print("NOTES30 ORDER (\(name)\(red ? " RED" : "")): \(made.members) members; roles mismatched \(mismatched), out of order \(outOfOrder)")
                if red { XCTAssertGreaterThan(mismatched + outOfOrder, 0, "RED CONTROL: the walls before the floor"); continue }
                XCTAssertEqual(mismatched, 0, "★ \(name): each member's snap is its role's (floor, walls, stairs)")
                XCTAssertEqual(outOfOrder, 0, "★ \(name): floors, then walls, then stairs, lift by lift — slow or switched")
                XCTAssertFalse(L.flights.isEmpty, "\(name): premise: a stair")
            }
        }
    }
}
#endif
