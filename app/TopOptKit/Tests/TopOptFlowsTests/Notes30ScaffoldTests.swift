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
//   * the scaffold is one even grid, one lift height, braced, with a stair, thin and pale (RED: a lattice's struts fail it);
//   * ★ v3 (11-27): the scaffold stands through the whole real build, then is struck top to bottom in a second (RED
//     `controlStrikeEachFloor`); nothing placed in mid-air, a floor over an overhang middle-out (RED `controlWalkOrder`); the
//     cut-out never changes at the visible rim at the landing (RED `controlRoughCoarse`); one even beat, no pause between
//     levels (RED `controlLevelPause`).
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
        T.controlWholeLift = false
        T.controlQuickReal = false
        T.controlStrikeEachFloor = false
        T.controlLevelPause = false
        S.controlWalkOrder = false
        S.controlRoughCoarse = false
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
    /// the scaffold rises lift by lift, topping out before the landing, nothing of the real lattice before it lands; then the
    /// real floors go in floor by floor inside it — ★ v3 the whole scaffold standing until the last of them — then it is struck,
    /// nothing of it left before the topped-out beat; at least 7 s. RED CONTROL `controlNoScaffold`: the part stands closed
    /// until it lands (release 21's wait).
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
            let floors = tl.floors, all = tl.piecesAll, allReal = floors * T.perFloorReal
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
            var realSnaps = 0, mostUp = 0, mostStruck = 0
            for e in log {
                guard let s = e.s else { continue }
                if let l = last {
                    XCTAssertGreaterThanOrEqual(s.lifts, l.lifts, "the scaffold only rises")
                    XCTAssertGreaterThanOrEqual(s.snaps, l.snaps, "★ the real lattice only ever grows")
                    XCTAssertLessThanOrEqual(s.snaps - l.snaps, 1, "★ the real floors in sweeping snaps, one at a time")
                    XCTAssertGreaterThanOrEqual(s.struck, l.struck, "a piece struck stays struck")
                    mostUp = Swift.max(mostUp, s.lifts - l.lifts)
                    mostStruck = Swift.max(mostStruck, s.struck - l.struck)
                    if s.snaps > l.snaps { realSnaps += 1 }
                }
                if s.struck > 0 { XCTAssertEqual(s.snaps, allReal, "★ v3: nothing struck before the whole real lattice stands") }
                last = s
            }
            XCTAssertLessThanOrEqual(mostUp, T.piecesMostPerSnap, "★ a piece at a time (a few at most a snap)")
            XCTAssertLessThanOrEqual(mostStruck, tl.strikePlan.per, "★ struck a few pieces a frame at most")
            XCTAssertEqual(realSnaps, allReal, "★ every real floor's snaps seen, one by one")
            XCTAssertEqual(last?.snaps, allReal, "★ it ends on the whole lattice")
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
                if checkpoint == nil, lifts * 5 >= made.members * 2, (r.lastScaffold?.struck ?? 0) == 0 { checkpoint = (lifts, Self.straw(px)) }   // (two fifths of it up)
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
            var peakUp = 0   // (it only rises: a new piece may hide some of the others behind it, never a fifth of them)
            for b in strawUp { XCTAssertGreaterThanOrEqual(b, peakUp - Swift.max(40, peakUp / 5), "it only rises"); peakUp = Swift.max(peakUp, b) }
            XCTAssertLessThan(strawUp.first ?? 0, strawUp.last ?? 0, "★ lift by lift")
            XCTAssertTrue(beat.allSatisfy { $0.straw < 10 }, "★ nothing of the scaffold in the topped-out beat")
            XCTAssertGreaterThan(beat.map(\.purple).min() ?? 0, 300, "★ the finished lattice")
            let peak = after.map(\.straw).max() ?? 0
            XCTAssertGreaterThan(peak, 100, "the scaffold stands at the landing")
            // ★ the shader's snaps are the plan's: the scaffold drawn at n snaps is its members coded under n, drawn whole
            let cp = try XCTUnwrap(checkpoint, "premise: a lift's floor seen before its walls")
            let (r2, d2) = try pocketRenderer()
            var keep: [Float] = []
            keep = Array(made.bars[0..<(7 * Swift.min(cp.n, made.members))])   // (its pieces in the order they come: the first n)
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
            // (★ v3: the second counts from when its lay began — after its rough cut-open, 0.15 s here)
            XCTAssertNil(show.revealScaffold(at: t0 + 1.14), "a quick lay, before the second: no scaffold")
            XCTAssertNil(show.timelapse?.shown(at: t0 + 1.14), "the site")
            let at1 = show.revealScaffold(at: t0 + 1.15)
            let s2 = show.timelapse?.shown(at: t0 + 1.15)
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
            XCTAssertEqual(show.timelapse?.shown(at: end)?.struck, show.timelapse.map { $0.piecesAll }, "★ all struck by the end")
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
        // ★ v3: the rough cut-open's own time (on the exact map's voxels: 0.23 s for the stand on this Mac) never pushes a quick
        // lay into the scaffold — the stand's lay, landing 1.09 s after the ask, rises as stand-solid-7s
        let stand = LatticeBuildShow()
        stand.layBegins(walls: true, mayScaffold: true, expectedS: 0.86, now: t1)
        stand.scaffoldArrived(S.drawing(made, token: stand.scaffoldToken), now: t1 + 0.23)
        for k in 0..<22 { XCTAssertNil(stand.revealScaffold(at: t1 + Double(k) * 0.05), "★ the stand's quick lay: no scaffold") }
        stand.landed(token: 8, now: t1 + 1.09)
        XCTAssertFalse(stand.timelapse?.scaffolding ?? true, "★ the stand's quick lay rises as stand-solid-7s")
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
        let perLift = made.layout.liftPieces
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
                // each piece's lift (its run among the lifts' pieces) and its part, as the plan lays them out in the order they come
                var pieceLift: [Int] = []
                for (k, n) in L.liftPieces.enumerated() { pieceLift += [Int](repeating: k, count: n) }
                XCTAssertEqual(pieceLift.count, made.members, "\(name): premise: every piece in a lift")
                var mismatched = 0, outOfOrder = 0
                for m in 0..<Swift.min(roles.count, L.parts.count) {
                    let part: S.Part
                    switch roles[m] { case .floor: part = .floor; case .roof: part = .roof; case .walls: part = .walls; case .stairs: part = .stairs }
                    if L.parts[m] != part || pieceLift[m] != lifts[m] { mismatched += 1 }
                    // in the order they come: within a lift, never a floor after its walls, nor walls after its stairs
                    if m > 0, pieceLift[m] == pieceLift[m - 1], L.parts[m].rawValue < L.parts[m - 1].rawValue { outOfOrder += 1 }
                }
                // as it rises — a lay judged slow at the ask, and one switched to a second after it — the pieces come in that order
                for switched in [false, true] {
                    let show = LatticeBuildShow()
                    let t0 = CACurrentMediaTime() + 1000
                    show.layBegins(walls: true, scaffold: !switched, mayScaffold: true, expectedS: switched ? 0.6 : 12, now: t0)
                    show.scaffoldArrived(S.drawing(made, token: show.scaffoldToken), now: t0 + 0.2)
                    var t = t0, lastUp = 0
                    let landing = t0 + (switched ? 6 : 12)
                    while t < landing {
                        show.step(t)
                        if let v = show.revealScaffold(at: t) {
                            XCTAssertGreaterThanOrEqual(v.lifts, lastUp, "\(name): it only rises")
                            lastUp = v.lifts
                        }
                        t += 0.02
                    }
                    XCTAssertTrue(show.timelapse?.scaffolding ?? false, "\(name): premise: the scaffold's path (\(switched ? "switched" : "slow at the ask"))")
                    XCTAssertGreaterThan(lastUp, 0, "\(name): premise: it rose")
                }
                print("NOTES30 ORDER (\(name)\(red ? " RED" : "")): \(made.members) members; roles mismatched \(mismatched), out of order \(outOfOrder)")
                if red { XCTAssertGreaterThan(mismatched + outOfOrder, 0, "RED CONTROL: the walls before the floor"); continue }
                XCTAssertEqual(mismatched, 0, "★ \(name): each piece in its lift and its part (floor, walls, stairs)")
                XCTAssertEqual(outOfOrder, 0, "★ \(name): floors, then walls, then stairs, lift by lift — slow or switched")
                XCTAssertFalse(L.flights.isEmpty, "\(name): premise: a stair")
            }
        }
    }

    // MARK: ★ his notes on v2 (11-26 23:50): a piece at a time; the real build slowed

    /// ★ "The floor gets made at the same time. It just comes into existence ... It should be a piece at a time." — as the
    /// scaffold rises (a slow lay on the stand's window and on the cone), each snap brings one piece, a few at most
    /// (`piecesMostPerSnap`), never a lift's whole floor or walls at once; ★ v3 struck "a LOT faster" — a frame's share of
    /// its pieces a frame (`strikePlan`). RED CONTROL `controlWholeLift`: a lift's pieces all in one snap.
    func testTheScaffoldComesAPieceAtATime() throws {
        for red in [false, true] {
            T.controlWholeLift = red
            defer { T.controlWholeLift = false }
            for (name, r) in [("window", Self.window), ("curved", Self.curved)] {
                let made = try XCTUnwrap(S.make(r, up: SIMD3(0, 0, 1), across: SIMD3(1, 0, 0), walls: true), name)
                let show = LatticeBuildShow()
                let t0 = CACurrentMediaTime() + 1000
                show.layBegins(walls: true, scaffold: true, mayScaffold: true, expectedS: 12, now: t0)
                show.scaffoldArrived(S.drawing(made, token: show.scaffoldToken), now: t0 + 0.2)
                // the smallest floor or walls a lift lays (the most one snap may never reach)
                var smallest = Int.max, start = 0
                for n in made.layout.liftPieces {
                    let parts = made.layout.parts[start..<(start + n)]
                    for p in [S.Part.floor, .walls] { let c = parts.filter { $0 == p }.count; if c > 0 { smallest = Swift.min(smallest, c) } }
                    start += n
                }
                var lastUp = 0, lastStruck = 0, mostUp = 0, mostStruck = 0, snapsUp = 0
                show.landed(token: 3, now: t0 + 12)   // (the clock below runs past the landing: the strike too)
                let end = try XCTUnwrap(show.timelapse?.end)
                var t = t0
                while t <= end {
                    if let v = show.revealScaffold(at: t) {
                        if v.lifts > lastUp { mostUp = Swift.max(mostUp, v.lifts - lastUp); snapsUp += 1 }
                        mostStruck = Swift.max(mostStruck, v.struck - lastStruck)
                        lastUp = v.lifts; lastStruck = v.struck
                    }
                    t += 0.005
                }
                print("NOTES30 PIECES (\(name)\(red ? " RED" : "")): \(made.members) pieces in \(snapsUp) snaps; most a snap \(mostUp) up, \(mostStruck) struck; smallest floor or walls \(smallest)")
                if red { XCTAssertGreaterThanOrEqual(mostUp, smallest, "RED CONTROL: a whole floor (or walls) in one snap"); continue }
                XCTAssertLessThanOrEqual(mostUp, T.piecesMostPerSnap, "★ \(name): a piece at a time (\(T.piecesMostPerSnap) at most a snap)")
                XCTAssertLessThan(mostUp, smallest, "★ \(name): never a whole floor or walls at once")
                XCTAssertLessThanOrEqual(mostStruck, show.timelapse?.strikePlan.per ?? 0, "★ \(name): struck a frame's share at a time")
                XCTAssertEqual(lastUp, made.members, "every piece came")
            }
        }
    }

    /// ★ "the scaffolding is super long, but the actual building of the lattice is nearly instant. Can we slow it down a little
    /// bit and give it that time-lapse feel too?" — after the landing the real floors take their own `replaceS` (5 s): each
    /// floor's columns in `sweeps` snaps, then its bays in `sweeps`, one at a time, and every strut in the snap its slice says
    /// (`sweepStep`). RED CONTROL `controlQuickReal`: v1's 2.4 s.
    func testTheRealBuildTakesItsOwnTimeAfterTheLanding() throws {
        let made = try XCTUnwrap(S.make(Self.curved, up: SIMD3(0, 0, 1), across: SIMD3(1, 0, 0), walls: true))
        for red in [false, true] {
            T.controlQuickReal = red
            defer { T.controlQuickReal = false }
            let show = LatticeBuildShow()
            let t0 = CACurrentMediaTime() + 1000
            show.layBegins(walls: true, scaffold: true, mayScaffold: true, expectedS: 12, now: t0)
            show.scaffoldArrived(S.drawing(made, token: show.scaffoldToken), now: t0 + 0.2)
            _ = show.revealScaffold(at: t0 + 11.9)
            show.landed(token: 3, now: t0 + 12)
            let tl = try XCTUnwrap(show.timelapse), end = try XCTUnwrap(tl.end)
            var first: Double?, whole: Double?, last = 0, steps = 0
            var t = t0 + 12
            while t <= end {
                let s = tl.shown(at: t)?.snaps ?? 0
                if s > 0, first == nil { first = t }
                if s > last { XCTAssertEqual(s - last, 1, "one sweep at a time"); steps += 1; last = s }
                if s >= tl.floors * T.perFloorReal, whole == nil { whole = t }
                t += 0.002
            }
            let real = (whole ?? end) - (first ?? end)
            print(String(format: "NOTES30 REAL BUILD%@: %d sweeps over %.2f s after the landing (the whole timelapse %.2f s)",
                         red ? " RED" : "", steps, real, end - t0))
            if red { XCTAssertLessThan(real, 0.7 * T.replaceS, "RED CONTROL: v1's quick real build"); continue }
            XCTAssertEqual(steps, tl.floors * T.perFloorReal, "★ every floor's columns and bays in sweeping snaps")
            XCTAssertGreaterThan(real, 0.7 * T.replaceS, "★ the real build takes its own time (\(real) s)")
            // every strut comes in the sweep its slice says
            let f = try XCTUnwrap(tl.frame)
            let a = SIMD3<Float>(f.across * (f.acrossLow + 0.05 * f.acrossW) + f.up * (f.low + 0.1)), b = a + f.up * f.floorH * 0.9
            XCTAssertEqual(T.sweepStep(a, b, f), 0, "a column at the left of the lowest floor: its first sweep")
            let c = SIMD3<Float>(f.across * (f.acrossLow + 0.95 * f.acrossW) + f.up * (f.low + 0.1))
            XCTAssertEqual(T.sweepStep(c, c + f.across * 0.5, f), 2 * T.sweeps - 1, "a bay's strut at its right: the floor's last sweep")
        }
    }

    // MARK: ★ his notes on v3 (11-27, img 100-102)

    /// A pebble-like area (never his file): in a block 90 × 60 × 42 mm, the lower half of a lying ellipsoid — its area wider at
    /// every lift as it rises (as img 100's pebble's round zone below its middle), so each floor OVERHANGS the lift below.
    static let pebble: S.Rough = {
        let v: Float = 1.5, part = SIMD3<Float>(90, 60, 42)
        let origin = SIMD3<Float>(repeating: -v)
        let dims = SIMD3<Int32>(Int32((part.x / v).rounded(.up)) + 3, Int32((part.y / v).rounded(.up)) + 3, Int32((part.z / v).rounded(.up)) + 3)
        var rg = [Int8]()
        for z in 0..<Int(dims.z) { for y in 0..<Int(dims.y) { for x in 0..<Int(dims.x) {
            let p = origin + SIMD3(Float(x), Float(y), Float(z)) * v
            let inside = all(p .>= SIMD3(repeating: -0.01)) && all(p .<= part + 0.01)
            let q = (p - SIMD3(45, 30, 40)) / SIMD3(40, 26, 38)
            let open = inside && simd_dot(q, q) < 1
            rg += [open ? 127 : -127, inside ? 127 : -127]
        }}}
        return S.Rough(origin: origin, voxel: v, dims: dims, rg: rg)
    }()

    /// The members that, in the order they come, touch nothing standing when they come — no end or point of them on a member
    /// before them (within the ground and roof floors' hair), nor an end on the ground lift's foot: at most five, described.
    static func placedInMidAir(_ m: S.Made) -> [String] {
        let bars = m.bars, n = bars.count / 7, f = m.frame
        guard n > 0, let g = m.layout.ground else { return ["no scaffold"] }
        let tol = S.edgeShare * f.floorH + 1e-3, ground = m.layout.height(g)
        let segs = (0..<n).map { i in (SIMD3(bars[7 * i], bars[7 * i + 1], bars[7 * i + 2]), SIMD3(bars[7 * i + 3], bars[7 * i + 4], bars[7 * i + 5])) }
        func dist(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            let d = b - a, t = Swift.max(0, Swift.min(1, simd_dot(p - a, d) / Swift.max(simd_dot(d, d), 1e-12)))
            return simd_distance(p, a + d * t)
        }
        var fails: [String] = [], count = 0
        for i in 0..<n {
            let (a, b) = segs[i]
            var met = abs(simd_dot(f.up, a) - ground) <= tol || abs(simd_dot(f.up, b) - ground) <= tol
            var j = 0
            while !met, j < i {
                let (c, d) = segs[j]
                met = dist(a, c, d) <= tol || dist(b, c, d) <= tol || dist(c, a, b) <= tol || dist(d, a, b) <= tol
                j += 1
            }
            if !met {
                count += 1
                if fails.count < 5 { fails.append(String(format: "piece %d (%@) in mid-air at (%.1f, %.1f, %.1f)", i, "\(m.layout.parts[i])", a.x, a.y, a.z)) }
            }
        }
        if count > fails.count { fails.append("\(count) in all") }
        return fails
    }

    /// Each level as its ledgers come (a lift's floor, the top lift's roof): it grows MIDDLE-OUT as one piece — its first ledger
    /// within 1.5 bays of its middle, each after it meeting one already laid on it. The failures, at most five.
    static func middleOut(_ m: S.Made) -> [String] {
        let bars = m.bars, n = bars.count / 7, bay = m.layout.bay, f = m.frame
        var levels: [(h: Float, segs: [(SIMD3<Float>, SIMD3<Float>)])] = []
        for i in 0..<n where m.layout.parts[i] == .floor || m.layout.parts[i] == .roof {
            let a = SIMD3(bars[7 * i], bars[7 * i + 1], bars[7 * i + 2]), b = SIMD3(bars[7 * i + 3], bars[7 * i + 4], bars[7 * i + 5])
            let h = simd_dot(f.up, a)
            if let k = levels.lastIndex(where: { abs($0.h - h) < 1e-3 }) { levels[k].segs.append((a, b)) } else { levels.append((h, [(a, b)])) }
        }
        var fails: [String] = []
        for (k, l) in levels.enumerated() {
            let mids = l.segs.map { ($0.0 + $0.1) / 2 }
            let c = mids.reduce(SIMD3<Float>(repeating: 0), +) / Float(mids.count)
            if let first = mids.first, simd_distance(first, c) > 1.5 * bay {
                fails.append(String(format: "level %d (%.1f mm): its first ledger %.1f bays from its middle", k, l.h, simd_distance(first, c) / bay))
            }
            for j in 1..<Swift.max(1, l.segs.count) {
                let (a, b) = l.segs[j]
                let met = l.segs[0..<j].contains { simd_distance(a, $0.0) < 1e-3 || simd_distance(a, $0.1) < 1e-3 || simd_distance(b, $0.0) < 1e-3 || simd_distance(b, $0.1) < 1e-3 }
                if !met { fails.append(String(format: "level %d (%.1f mm): ledger %d meets none laid before it", k, l.h, j)); break }
            }
        }
        return Array(fails.prefix(5))
    }

    /// ★ v3 "nothing placed in mid-air" (img 100: on the pebble "a long ledger sticking out over nothing"): "The floor should go
    /// *middle-out* in scenarios that have overhangs in the scaffolding." — on the pebble (its lower floors overhang the lift
    /// below), the cone and the window, every piece, at the moment it comes, touches a piece already standing or the ground:
    /// floor, walls, stairs, roof alike, and every level grows middle-out as one piece (never a long run along its edge first:
    /// img 100's ledger). (The strike takes them in the reverse order, so what stands then is always a run of them as they rose:
    /// nothing in mid-air coming down either.) RED CONTROL `controlWalkOrder` (v2's order): on the pebble a floor's ledgers come
    /// over the overhang first; every floor starts at its front-left corner.
    func testNothingIsPlacedInMidAirAFloorOverAnOverhangGrowsMiddleOut() throws {
        for red in [false, true] {
            S.controlWalkOrder = red
            defer { S.controlWalkOrder = false }
            for (name, r) in [("pebble", Self.pebble), ("window", Self.window), ("curved", Self.curved)] {
                let made = try XCTUnwrap(S.make(r, up: SIMD3(0, 0, 1), across: SIMD3(1, 0, 0), walls: true), name)
                let L = made.layout
                let overhangs = zip(L.squares, L.squares.dropFirst()).filter { !$0.0.isEmpty && !$0.1.subtracting($0.0).isEmpty }.count
                let fails = Self.placedInMidAir(made), spread = Self.middleOut(made)
                print("NOTES30 MID-AIR (\(name)\(red ? " RED" : "")): \(made.members) members, squares per lift \(L.squares.map(\.count)), \(overhangs) levels overhanging the lift below; \(fails.isEmpty ? "every piece touches what stands as it comes" : fails.joined(separator: "; ")); \(spread.isEmpty ? "every level middle-out" : spread.joined(separator: "; "))")
                if red {
                    if name == "pebble" { XCTAssertFalse(fails.isEmpty, "RED CONTROL: v2's walk lays a ledger over the overhang first") }
                    XCTAssertFalse(spread.isEmpty, "RED CONTROL: v2's walk starts each floor at its front-left corner (\(name))")
                    continue
                }
                XCTAssertEqual(spread, [], "★ \(name): every level grows middle-out as one piece")
                if name == "pebble" { XCTAssertGreaterThan(overhangs, 0, "premise: the pebble's floors overhang the lift below") }
                XCTAssertEqual(fails, [], "★ \(name): every piece, as it comes, touches what already stands")
                XCTAssertEqual(Self.stands(made), [], "★ \(name): and the whole stands as before")
            }
        }
    }

    /// ★ v3 "the scaffolding is clearing out from the bottom to the top. It would go from the top to the bottom and only *after*
    /// the lattice was laid entirely. It can be put down a LOT faster though." — a slow lay (the window, the cone): every piece
    /// of the scaffold stands until the last real snap is in; then it is struck from the top — what stands is always the run it
    /// rose first, each snap's pieces from no higher lift than one already struck — all of it within `strikeS`. RED CONTROL
    /// `controlStrikeEachFloor` (v2): a lift struck after each real floor, bottom up.
    func testTheScaffoldStandsUntilTheLatticeIsLaidThenComesDownTopFirstInASecond() throws {
        for red in [false, true] {
            T.controlStrikeEachFloor = red
            defer { T.controlStrikeEachFloor = false }
            for (name, r) in [("window", Self.window), ("curved", Self.curved)] {
                let made = try XCTUnwrap(S.make(r, up: SIMD3(0, 0, 1), across: SIMD3(1, 0, 0), walls: true), name)
                var pieceLift: [Int] = []
                for (k, n) in made.layout.liftPieces.enumerated() { pieceLift += [Int](repeating: k, count: n) }
                let show = LatticeBuildShow()
                let t0 = CACurrentMediaTime() + 1000
                show.layBegins(walls: true, scaffold: true, mayScaffold: true, expectedS: 12, now: t0)
                show.scaffoldArrived(S.drawing(made, token: show.scaffoldToken), now: t0 + 0.2)
                _ = show.revealScaffold(at: t0 + 11.9)
                show.landed(token: 3, now: t0 + 12)
                let tl = try XCTUnwrap(show.timelapse), end = try XCTUnwrap(tl.end)
                let all = tl.piecesAll, allReal = tl.floors * T.perFloorReal
                var struckEarly = 0, bottomFirst = 0, upward = 0
                var firstStrike: Double?, lastStrike: Double?, lastSnap: Double?
                var lowestLift = Int.max, prev = T.Shown(lifts: all)
                var t = t0 + 12
                while t <= end + 1e-6 {
                    if let s = tl.shown(at: t) {
                        if s.snaps > prev.snaps { lastSnap = t }
                        if s.snaps < allReal, s.struck > 0 { struckEarly += 1 }
                        if s.struck > prev.struck {
                            if firstStrike == nil { firstStrike = t }
                            lastStrike = t
                            let run = s.standing
                            if run.lowerBound > 0 { bottomFirst += 1 }
                            let gone = prev.standing.filter { !run.contains($0) }.map { pieceLift[$0] }
                            if let lo = gone.min(), let hi = gone.max() {
                                if hi > lowestLift { upward += 1 }
                                lowestLift = Swift.min(lowestLift, lo)
                            }
                        }
                        prev = s
                    }
                    t += 0.002
                }
                let took = (lastStrike ?? end) - (firstStrike ?? end)
                print(String(format: "NOTES30 STRIKE (%@%@): %d pieces; last real snap %.2f s, struck %.2f–%.2f s (%.2f s, %d a snap); struck before the lattice stood %d, bottom first %d, upward %d",
                             name, red ? " RED" : "", all, (lastSnap ?? t0) - t0, (firstStrike ?? t0) - t0, (lastStrike ?? t0) - t0, took,
                             tl.strikePlan.per, struckEarly, bottomFirst, upward))
                if red { XCTAssertGreaterThan(struckEarly + bottomFirst, 0, "RED CONTROL: v2 struck bottom up as the floors went in"); continue }
                XCTAssertEqual(struckEarly, 0, "★ \(name): the whole scaffold stands until the lattice is laid entirely")
                XCTAssertGreaterThan(try XCTUnwrap(firstStrike), try XCTUnwrap(lastSnap), "★ \(name): struck only after the last real snap")
                XCTAssertEqual(bottomFirst, 0, "★ \(name): from the top: what stands is always the run it rose first")
                XCTAssertEqual(upward, 0, "★ \(name): lift by lift from the top down")
                XCTAssertLessThanOrEqual(took, T.strikeS + 1.0 / 30, "★ \(name): a LOT faster — in a second")
                XCTAssertEqual(prev.struck, all, "★ \(name): nothing of it left")
                XCTAssertLessThan(try XCTUnwrap(lastStrike), end - T.toppedOutS + 1e-6, "★ \(name): gone before the topped-out beat")
            }
        }
    }

    /// ★ v3 "there is a bit of a pause between each level of lattice laid down. Get rid of that entirely. I want the speed to
    /// be consistent; so going up from the bottom takes the same amount of time as going from one cell to the next on the same
    /// floor." — a slow lay (window, cone, pebble): the real build's snaps ONE even beat apart, floor to floor too; the
    /// scaffold's next snap after a level's last comes its own beat after (never stillness), its pace a piece one even beat over
    /// every level (never slower than `pieceMostS`); the strike a real beat after the last real snap. RED CONTROL
    /// `controlLevelPause` (v2): stillness after each level.
    func testOneEvenBeatWithNoPauseBetweenLevels() throws {
        for red in [false, true] {
            T.controlLevelPause = red
            defer { T.controlLevelPause = false }
            for (name, r) in [("window", Self.window), ("curved", Self.curved), ("pebble", Self.pebble)] {
                let made = try XCTUnwrap(S.make(r, up: SIMD3(0, 0, 1), across: SIMD3(1, 0, 0), walls: true), name)
                let show = LatticeBuildShow()
                let t0 = CACurrentMediaTime() + 1000
                show.layBegins(walls: true, scaffold: true, mayScaffold: true, expectedS: 12, now: t0)
                show.scaffoldArrived(S.drawing(made, token: show.scaffoldToken), now: t0 + 0.2)
                _ = show.revealScaffold(at: t0 + 11.9)
                show.landed(token: 3, now: t0 + 12)
                let tl = try XCTUnwrap(show.timelapse)
                // the scaffold: within a lift, and from a lift's last snap to the next one's first
                let risen = tl.lifts.filter { !$0.snaps.isEmpty }
                var within = 0.0, pause = 0.0
                for (k, l) in risen.enumerated() {
                    for (a, b) in zip(l.snaps.dropFirst(), l.snaps) { within = Swift.max(within, abs((a - b) - l.gap)) }
                    if k + 1 < risen.count, let last = l.snaps.last, let next = risen[k + 1].snaps.first {
                        pause = Swift.max(pause, (next - last) / l.gap)
                    }
                }
                let beats = risen.map(\.beat)
                let beatSpread = (beats.max() ?? 0) / Swift.max(beats.min() ?? 1, 1e-9)
                // the real build: its snaps, then the strike's first
                let beatsAfter = tl.replaceBeats
                let real = beatsAfter.filter { $0.struck == 0 }.map(\.t)
                let gaps = zip(real.dropFirst(), real).map { $0 - $1 }
                let realSpread = (gaps.max() ?? 0) / Swift.max(gaps.min() ?? 1, 1e-9)
                let strikeAfter = (beatsAfter.first { $0.struck > 0 }?.t ?? 0) - (real.last ?? 0)
                print(String(format: "NOTES30 BEAT (%@%@): scaffold %d pieces, a piece every %.3f–%.3f s (spread %.2f), level to level %.2f × its beat; real build %d snaps %.3f–%.3f s apart (spread %.2f), the strike %.3f s after",
                             name, red ? " RED" : "", tl.piecesAll, beats.min() ?? 0, beats.max() ?? 0, beatSpread, pause, real.count,
                             gaps.min() ?? 0, gaps.max() ?? 0, realSpread, strikeAfter))
                if red {
                    XCTAssertGreaterThan(realSpread, 2, "RED CONTROL: v2's pause after each real floor")
                    XCTAssertGreaterThan(pause, 2, "RED CONTROL: v2's stillness after each level of scaffold")
                    continue
                }
                XCTAssertEqual(real.count, tl.floors * T.perFloorReal, "premise: every real snap")
                XCTAssertLessThan(realSpread, 1 + 1e-6, "★ \(name): the real build one even beat, floor to floor too")
                XCTAssertEqual(strikeAfter, gaps.first ?? 0, accuracy: 1e-6, "★ \(name): the strike one beat after the last real snap")
                XCTAssertLessThan(within, 1e-9, "★ \(name): a level's snaps one beat apart")
                XCTAssertLessThan(pause, 1 + 1e-6, "★ \(name): no stillness from one level to the next")
                XCTAssertLessThan(beatSpread, 1.15, "★ \(name): one pace a piece, level to level")
                XCTAssertLessThanOrEqual(beats.max() ?? 0, T.pieceMostS + 1e-9, "★ \(name): never slower than \(T.pieceMostS) s a piece")
            }
        }
    }

    /// ★ v3 "The cut-out must not change" (img 101 at 0:11 → img 102 at 0:12, "landed: the exact cut-open"): "Is there no way
    /// to ensure that doesn't happen?" — through the REAL engine (a block with a round lattice zone): the rough cut-open is made
    /// on the exact map's own voxels and drawn by its own smoothing, so the two differ only where the lay alone knows (cells no
    /// strut holds stay solid); what lands holds the visible rim exactly as the rough one drew it — nothing of the outline
    /// changes at the part's surface (the outside and the voxel layer under it), deeper inside the exact one's. Measured: the
    /// share of the cut-open's voxels whose cut changes at the landing. RED CONTROL `controlRoughCoarse` (v2): twice the voxel,
    /// the rim moves.
    func testTheCutOutDoesNotChangeAtTheLanding() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scaffold-cut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("block.stl").path
        try LatticePlaceChipsTests.gridSTL([0, 40], [0, 30], [0, 24]) { _, _, _ in true }.write(to: URL(fileURLWithPath: path))
        let mesh = try TopOptKit.importMesh(path: path)
        let session = try await LatticeLayoutSession.open(path: path)
        addTeardownBlock { session.close() }
        var set = LatticeLayoutSession.Settings()
        set.topology = "bccz"; set.algorithm = "uniform"; set.cellMM = 5; set.cellMaxMM = 5
        var z = LatticeLayoutSession.Region(id: 1, faces: [], depthMM: 0)   // a round zone through the block front to back
        z.zone = .init(kind: .cylinder, centre: SIMD3(20, 15, 12), axes: [SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)],
                       half: SIMD3(9, 0, 20))
        set.regions = [z]
        let box = try XCTUnwrap(LatticeLayoutPreview.box(mesh.vertices))
        let fine = LatticeLayoutPreview.mapGeometry(box)
        _ = try await session.lay(set)   // (the part read once)
        for red in [false, true] {
            S.controlRoughCoarse = red
            defer { S.controlRoughCoarse = false }
            let g = LatticeLayoutPreview.roughGeometry(box)
            let asked = try await session.gridRough(set, origin: g.origin, voxel: g.voxel, dims: g.dims)
            let rough = S.Rough(origin: g.origin, voxel: g.voxel, dims: g.dims, rg: try XCTUnwrap(asked, "the rough cut-open").rg)
            let made = try XCTUnwrap(S.make(rough, up: SIMD3(0, 0, 1), across: SIMD3(1, 0, 0), walls: true, cutSmooth: true))
            let early = try XCTUnwrap(made.drawn)   // (what the scaffold's pass drew)
            _ = try await session.lay(set)
            let landed = try await LatticeLayoutPreview.map(session, box, token: 5, cutSmooth: true, hold: rough).grid   // (as the page lands it)
            let exact = try await session.grid(origin: fine.origin, voxel: fine.voxel, dims: fine.dims)
            XCTAssertEqual(landed.dims, fine.dims, "premise: the landed map on the exact map's voxels")
            // each of the landed map's voxels: its cut as the scaffold drew it (the rough map's nearest voxel) and as it lands
            let depth = S.rimDepth(landed.rg, dims: fine.dims, most: 2)
            let nx = Int(fine.dims.x), ny = Int(fine.dims.y), nz = Int(fine.dims.z)
            var open = 0, changed = 0, atSurface = 0
            for zz in 0..<nz { for y in 0..<ny { for x in 0..<nx {
                let i = (zz * ny + y) * nx + x
                let p = fine.origin + SIMD3(Float(x), Float(y), Float(zz)) * fine.voxel
                let q = (p - g.origin) / g.voxel
                let a = Swift.min(Int(g.dims.x) - 1, Swift.max(0, Int(q.x.rounded()))), b = Swift.min(Int(g.dims.y) - 1, Swift.max(0, Int(q.y.rounded())))
                let c = Swift.min(Int(g.dims.z) - 1, Swift.max(0, Int(q.z.rounded())))
                let before = early[2 * ((c * Int(g.dims.y) + b) * Int(g.dims.x) + a)] > 0, after = landed.rg[2 * i] > 0
                if after { open += 1 }
                if before != after { changed += 1; if depth[i] <= 1 { atSurface += 1 } }
            }}}
            let unheld = exact.unheld
            print(String(format: "NOTES30 CUT-OUT%@: rough on %.2f mm voxels (the exact map's %.2f); %d voxels open; at the landing %d change (%.2f %%), %d of them at the part's surface; the lay left %d lattice voxels solid (no strut holds them)",
                         red ? " RED" : "", g.voxel, fine.voxel, open, changed, open > 0 ? 100 * Double(changed) / Double(open) : 0,
                         atSurface, unheld))
            if red {
                XCTAssertNotEqual(g.voxel, fine.voxel, "RED CONTROL: v2's rough on twice the voxel")
                XCTAssertGreaterThan(atSurface, 0, "RED CONTROL: the rim moves at the landing")
                continue
            }
            XCTAssertEqual(g.voxel, fine.voxel, "★ the rough cut-open on the exact map's own voxels")
            XCTAssertEqual(g.dims, fine.dims, "★ … and its box")
            XCTAssertGreaterThan(open, 1000, "premise: the cut-open")
            XCTAssertEqual(atSurface, 0, "★ the visible rim never changes at the landing")
            XCTAssertLessThanOrEqual(changed, 3 * unheld + 50, "★ only what the lay alone knows changes, inside the part")
        }
    }
}
#endif
