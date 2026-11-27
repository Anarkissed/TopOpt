// LatticeGrowthTests — ★ his 11-22 ("Can we implement this like an animation? Could the user literally *watch* the lattice
// grow from nothing?"), the app half:
//   * the poller (fed a fake tap): reads accumulate in the engine's order, a new lay starts the growth again (read from its
//     start, the same poll), a lay that landed never grows again, the watch stops when the lay ends or the session closes;
//   * the growth: sealed when the finished lattice lands (a short fade over it, then gone), gone at once after a refusal;
//   * the Lattice button names the engine's phase in five words at most;
//   * FOR REAL through the bridge: the engine hands its vines while it lays, a read never waits on the lay (which holds the
//     session's lock), and every lay counts;
//   * on the app's renderer: the vines drawn in the lattice's purple, the newest brighter; each poll uploads only its own
//     pieces; past the budget the older pieces are thinned, the tips never; faded out, nothing is drawn.
// RED CONTROLS: no growth attached, the frame is the bare one; a lay before the watch is never grown.
// ★ his notes 2026-11-23 (img 49): "It needs to be in 3D. There needs to be depth … only the ones that are visible to me … no
// walls in the way; only seeing what's visible; shadow/highlights" — real tubes at their group's width, in the lattice's
// G-buffer, lit by its shade and depth-tested against the part opened by the lay's map (else the part in X-ray until its map
// comes); the growth and the landed vine alike, and the landing a sink with no pop; 147,000 pieces no dearer than the landed
// vines. Item 3: from phase 2 on the grown lattice keeps moving (a band of light rising) until it lands. RED CONTROLS
// `controlNoXrayStandIn`, `controlNoWorkingBand`, the map not this lay's.
import XCTest
import Combine
import simd
@testable import TopOptFlows
@testable import TopOptKit
#if canImport(MetalKit)
import MetalKit
#endif

/// A tap as core's GrowthTap reads (start, pieces, phase, read from / at most).
final class FakeGrowthTap {
    var lay: UInt64 = 0
    var phase = 0
    var xyz: [Float] = []
    var region: [Int32] = []
    var reads = 0
    var closed = false
    func start() { lay += 1; phase = 1; xyz = []; region = [] }
    /// `n` pieces, piece k of the whole lay at x = k (so their order can be read back).
    func add(_ n: Int) {
        for _ in 0..<n {
            let k = Float(region.count)
            xyz += [k, 0, 0, k, 1, 0]
            region.append(Int32(region.count % 3 + 1))
        }
    }
    func read(_ from: Int, _ most: Int) throws -> LatticeLayoutSession.Growth {
        if closed { throw TopOptError(message: "lattice layout session 1 is not open") }
        reads += 1
        let n = region.count, a = Swift.min(from, n), b = most > 0 ? Swift.min(n, a + most) : n
        return .init(lay: lay, phase: phase, next: b, xyz: Array(xyz[(6 * a)..<(6 * b)]), region: Array(region[a..<b]))
    }
}

@MainActor
final class LatticeGrowthTests: XCTestCase {

    // MARK: the poller

    func testThePollerKeepsTheEnginesOrderStartsAgainOnANewLayAndNeverGrowsALandedOne() throws {
        let tap = FakeGrowthTap()
        tap.start(); tap.add(7)   // a lay before the watch began (lay 1)
        var p = LatticeGrowthPoller(baseline: try tap.read(.max, 1).lay)
        XCTAssertEqual(p.take(try tap.read(0, 0), from: 0), .init(), "★ the lay before the watch is never grown")
        tap.start(); tap.add(5)   // lay 2, this watch's
        var s = p.take(try tap.read(p.next, 0), from: 0)
        XCTAssertTrue(s.restart, "a new lay: the growth starts again")
        XCTAssertEqual(s.xyz.count, 30)
        XCTAssertEqual(s.phase, 1, "its phase")
        tap.add(3)
        s = p.take(try tap.read(p.next, 0), from: p.next)
        XCTAssertFalse(s.restart)
        XCTAssertEqual(stride(from: 0, to: s.xyz.count, by: 6).map { s.xyz[$0] }, [5, 6, 7], "★ only what came since, in order")
        XCTAssertNil(s.phase, "the phase did not move")
        tap.phase = 2
        s = p.take(try tap.read(p.next, 0), from: p.next)
        XCTAssertEqual(s.phase, 2, "★ the phase moved: said")
        XCTAssertTrue(s.xyz.isEmpty)
        // a new lay seen part-way (read from 8): read again from its start, in the same poll
        tap.start(); tap.add(4)
        let from = p.next
        s = p.take(try tap.read(from, 0), from: from)
        XCTAssertTrue(s.restart && s.readAgain && s.xyz.isEmpty, "★ a new lay: its pieces read from its start")
        s = p.take(try tap.read(p.next, 0), from: p.next)
        XCTAssertEqual(stride(from: 0, to: s.xyz.count, by: 6).map { s.xyz[$0] }, [0, 1, 2, 3])
        // it landed: whatever of it a read has not reached is not grown
        tap.add(2)
        p.landed(tap.lay)
        XCTAssertEqual(p.take(try tap.read(p.next, 0), from: p.next).xyz, [], "★ a landed lay never grows again")
        tap.start(); tap.add(1)
        XCTAssertTrue(p.take(try tap.read(0, 0), from: 0).restart, "the next lay grows")
    }

    /// The watch (a Task on the main actor) reads every `every` s onto the growth, says each phase, starts again on a new lay,
    /// and stops when the lay ends (no more reads) or the session closes.
    func testTheWatchAccumulatesReadsInOrderRestartsAndStops() async throws {
        let tap = FakeGrowthTap()
        tap.start(); tap.add(3)   // an earlier lay
        let growth = LatticeGrowth()
        var phases: [Int] = []
        var watch: LatticeGrowthWatch? = LatticeGrowthWatch(growth: growth, every: 0.01, most: 4, read: tap.read,
                                                             onPhase: { phases.append($0) })
        func settle(_ s: Double = 0.15) async throws { try await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        try await settle()
        XCTAssertEqual(growth.count, 0, "★ the lay before the watch is not grown")
        tap.start()
        for _ in 0..<5 { tap.add(3); try await settle(0.03) }
        try await settle()
        XCTAssertEqual(growth.count, 15, "every piece, at most 4 a read")
        let xs = stride(from: 0, to: growth.pieces.count, by: 2).map { growth.pieces[$0].x }
        XCTAssertEqual(xs, (0..<15).map(Float.init), "★ in the order the engine laid them")
        tap.phase = 2; try await settle()
        tap.phase = 5; try await settle()
        XCTAssertEqual(phases, [1, 2, 5], "★ each phase said once")
        let e = growth.epoch
        tap.start(); tap.add(2); try await settle()
        XCTAssertGreaterThan(growth.epoch, e, "★ a new lay starts the growth again")
        XCTAssertEqual(growth.count, 2)
        // the lay ends: no more reads
        watch?.stop()
        let n = tap.reads
        tap.add(4); try await settle()
        XCTAssertEqual(tap.reads, n, "★ stopped with its lay: no read after")
        XCTAssertEqual(growth.count, 2)
        XCTAssertFalse(watch?.running ?? true)
        // the session closed under a watch: it stops itself
        watch = LatticeGrowthWatch(growth: growth, every: 0.01, most: 0, read: tap.read, onPhase: { _ in })
        try await settle()
        XCTAssertTrue(watch?.running ?? false)
        tap.closed = true
        try await settle()
        XCTAssertFalse(watch?.running ?? true, "★ the session closed: the watch ended")
        watch = nil
    }

    // MARK: the growth

    func testTheLatticeLandingFadesTheGrowthOutAndARefusalTakesItAtOnce() async throws {
        let g = LatticeGrowth()
        var changes = 0
        let sub = g.changed.sink { changes += 1 }
        defer { sub.cancel() }
        g.append(xyz: [0, 0, 0, 1, 0, 0, 1, 0, 0, 2, 0, 0], region: [1, 1])
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g.pieces[0].w, 0.5, "the first of a poll's two: born half way through it")
        XCTAssertEqual(g.pieces[2].w, 1, "the newest at the poll's own number")
        g.append(xyz: [2, 0, 0, 3, 0, 0], region: [2])
        XCTAssertEqual(g.clock, 2)
        let t0 = CACurrentMediaTime()
        g.seal(landed: true, now: t0)
        XCTAssertEqual(g.count, 3, "★ never a flash of nothing: the growth stays while it fades")
        XCTAssertEqual(g.alpha(at: t0), 1)
        XCTAssertLessThan(g.alpha(at: t0 + LatticeGrowth.fadeS / 2), 0.6)
        XCTAssertEqual(g.alpha(at: t0 + LatticeGrowth.fadeS + 0.01), 0)
        g.append(xyz: [9, 9, 9, 8, 8, 8], region: [1])
        XCTAssertEqual(g.count, 3, "★ sealed: a read behind the lay adds nothing over the finished lattice")
        let c0 = changes
        try await Task.sleep(nanoseconds: UInt64((LatticeGrowth.fadeS + 0.2) * 1e9))
        XCTAssertEqual(g.count, 0, "★ gone once faded")
        XCTAssertGreaterThan(changes - c0, 4, "the fade redraws the view as it goes")
        g.restart()
        g.append(xyz: [0, 0, 0, 1, 1, 1], region: [1])
        XCTAssertEqual(g.count, 1, "a new lay grows again")
        g.seal(landed: false)
        XCTAssertEqual(g.count, 0, "★ a refusal: gone at once")
    }

    // MARK: the Lattice button

    func testTheButtonNamesThePhaseInFiveWords() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let words = [1: "Growing the vines", 2: "Pruning", 3: "Filling the gaps", 4: "Reaching the walls", 5: "Finishing"]
        XCTAssertEqual(LatticePreviewMode.phaseWords, words, "★ his five phases")
        for (phase, w) in words {
            for q in [LatticeLayoutSession.Organic.Quality.draft, .exact] {
                let p = LatticeLayoutPreview.LayProgress(quality: q, started: t0, expectedS: 40, draftShown: q == .exact, phase: phase)
                let b = LatticePreviewMode.buttonProgress(p)
                XCTAssertEqual(b.words, w)
                for dt in [0.0, 10, 100] {
                    let line = b.line(at: t0.addingTimeInterval(dt))
                    XCTAssertTrue(line.hasPrefix(w), line)
                    XCTAssertLessThanOrEqual(line.split(separator: " ").filter { $0 != "\u{00B7}" }.count, 5, "★ five words: \(line)")
                }
                XCTAssertEqual(b.fraction(at: t0.addingTimeInterval(20)) ?? 0, 0.5, accuracy: 1e-9, "the ring as it was")
            }
        }
        let none = LatticeLayoutPreview.LayProgress(quality: .draft, started: t0, expectedS: nil, draftShown: false)
        XCTAssertEqual(none.phase, 0)
        XCTAssertEqual(LatticePreviewMode.buttonProgress(none).words, LatticePreviewMode.layingDraft, "no phase yet: as before")
    }

    // MARK: FOR REAL, through the bridge

    /// A 30 × 30 × 20 block woven from its top 15 mm deep (DraftOpensFacesTests' block), Grown: the engine's vines read while
    /// it lays, every read quick (it never waits on the lay, which holds the session's lock), the whole lay's pieces read in
    /// parts as one, the phases through pruning, each lay counted.
    func testTheEngineHandsItsVinesWhileItLays() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("growth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("block.stl").path
        try LatticePlaceChipsTests.gridSTL([0, 30], [0, 30], [0, 20]) { _, _, _ in true }.write(to: URL(fileURLWithPath: path))
        let mesh = try TopOptKit.importMesh(path: path)
        let top = try XCTUnwrap(LatticePlaceChipsTests.face(mesh, axis: 2, sign: 1, at: 20))
        let session = try await LatticeLayoutSession.open(path: path)
        addTeardownBlock { session.close() }
        var s = LatticeLayoutSession.Settings()
        var r = LatticeLayoutSession.Region(id: 1, faces: [top], depthMM: 15)
        r.weave = true
        s.regions = [r]
        let n = (16, 16, 11)
        var voigt: [Double] = []
        for _ in 0..<(n.0 * n.1 * n.2) { voigt += [-1, -1, -10, 0.5, 0.2, 0.1] }
        try await session.setTensor(voigt: voigt, nx: n.0, ny: n.1, nz: n.2, origin: SIMD3(-1, -1, -1), spacingMM: 2)
        let limits = try await session.sweepLimits(s, lineMM: 0.45)
        var look = LatticeOrganicLook(); look.mode = .grown; look.lookPercent = 30
        let ask = look.ask(limits: LatticeOrganicLook.Limits(limits[0]))
        let before = try session.growthRead(from: .max, most: 1)
        XCTAssertEqual(before.lay, 0, "no lay yet")
        XCTAssertEqual(before.count, 0)

        final class Done { var yes = false }
        let done = Done()
        let lay = Task { () async throws -> LatticeLayoutSession.OrganicResult in
            defer { done.yes = true }
            return try await session.layOrganic(s, ask)
        }
        var during = 0, slowest = 0.0, reads = 0, phases = Set<Int>()
        var next = 0
        var parts: [Float] = []
        while !done.yes {
            let t = Date()
            let g = try session.growthRead(from: next, most: 500)
            slowest = Swift.max(slowest, Date().timeIntervalSince(t))
            reads += 1
            if g.lay == 1 {
                parts += g.xyz; next = g.next; phases.insert(g.phase)
                if !g.xyz.isEmpty { during += 1 }
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let laid = try await lay.value
        XCTAssertFalse(laid.runs.isEmpty, "premise: it laid")
        let all = try session.growthRead(from: 0)
        print("GROWTH (block, Grown): \(all.count) pieces watched, \(during) reads brought pieces while it laid, \(reads) reads, "
              + "slowest \(String(format: "%.1f", slowest * 1000)) ms, phases \(phases.sorted()), at the end \(all.phase)")
        XCTAssertGreaterThan(during, 0, "★ the vines came while it laid")
        XCTAssertLessThan(slowest, 0.25, "★ a read never waits on the lay")
        XCTAssertEqual(all.lay, 1)
        XCTAssertGreaterThan(all.count, 50)
        XCTAssertEqual(all.xyz.count, 6 * all.count)
        XCTAssertEqual(all.next, all.count)
        XCTAssertGreaterThanOrEqual(all.phase, 2, "★ Grown went through its phases (pruning and on)")
        let rest = try session.growthRead(from: next)
        XCTAssertEqual(parts + rest.xyz, all.xyz, "★ read in parts while it laid, the same pieces as read whole")
        XCTAssertTrue(all.xyz.allSatisfy { $0.isFinite && $0 > -2 && $0 < 32 }, "inside the block")
        var t2 = ask; t2.quality = .draft
        _ = try await session.layOrganic(s, t2)
        XCTAssertEqual(try session.growthRead(from: 0, most: 1).lay, 2, "★ a new lay counts (the Draft too)")
        session.close()
        XCTAssertThrowsError(try session.growthRead(from: 0), "a closed session: an error, never a crash")
    }


    // MARK: ★ notes24 — the widths and the phases on the growth

    /// Each region grows at the width its group asked (a range: its middle; none asked: two print lines); the lay's own poll
    /// restarting the growth keeps them; the map flag is the lay's.
    func testEachRegionGrowsAtItsGroupsWidth() {
        var a1 = LatticeLayoutSession.Organic(); a1.widthMM = 1.0
        var a2 = LatticeLayoutSession.Organic(); a2.widthMM = 0.8; a2.widthHeavyMM = 1.6
        let a3 = LatticeLayoutSession.Organic()   // the engine's own width
        let g = LatticeGrowth()
        g.layBegins([.init(regions: [1, 2], ask: a1), .init(regions: [5], ask: a2), .init(regions: [9], ask: a3)], lineMM: 0.4,
                    opening: .open)
        g.restart()   // the lay's first poll
        XCTAssertTrue(g.mapOpensFaces)
        g.append(xyz: [Float](repeating: 0, count: 6 * 4), region: [1, 5, 9, 7])
        XCTAssertEqual(g.pieces[1].w, 0.5, accuracy: 1e-6, "★ its group's width (1 mm): a 0.5 mm tube")
        XCTAssertEqual(g.pieces[3].w, 0.6, accuracy: 1e-6, "a 0.8 to 1.6 mm range: its middle")
        XCTAssertEqual(g.pieces[5].w, 0.4, accuracy: 1e-6, "none asked: two print lines")
        XCTAssertEqual(g.pieces[7].w, 0.4, accuracy: 1e-6, "a region no group names: two print lines")
        XCTAssertEqual(g.pieces[0].w, 0.25, accuracy: 1e-6, "the birth as before")
        g.layBegins([], lineMM: 0, opening: .xray)
        XCTAssertFalse(g.mapOpensFaces)
        XCTAssertEqual(g.radiusDefault, 0.45, accuracy: 1e-6, "no line known: 0.45 mm lines")
    }

    /// ★ notes24 item 3: "the "Finishing" stayed on for the majority of the time … some sort of animation like the growing of
    /// the lattice would be VERY beneficial". From the engine's phase 2 on (the vines grown) the growth redraws itself (the
    /// band rises) with no new piece, never a frozen picture, until the lattice lands; while it grows, its pieces move it.
    /// RED CONTROL `controlNoWorkingBand`: nothing moves.
    func testTheGrownLatticeKeepsMovingUntilItLands() async throws {
        defer { LatticeGrowth.controlNoWorkingBand = false }
        for red in [false, true] {
            LatticeGrowth.controlNoWorkingBand = red
            let g = LatticeGrowth()
            var changes = 0
            let sub = g.changed.sink { changes += 1 }
            defer { sub.cancel() }
            g.append(xyz: Self.vine(SIMD3(2, 1, 10), SIMD3(2, 9, 10), 20), region: [Int32](repeating: 1, count: 20))
            g.phaseMoved(1)
            XCTAssertFalse(g.working, "growing: the new pieces move it")
            var c = changes
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(changes, c, "nothing new while growing: no redraw of its own")
            g.phaseMoved(5)   // Finishing
            c = changes
            try await Task.sleep(nanoseconds: 500_000_000)
            if red {
                XCTAssertEqual(changes, c, "RED CONTROL: the grown lattice stands still while the lay finishes")
                XCTAssertNil(g.workingSince)
                continue
            }
            XCTAssertTrue(g.working)
            XCTAssertGreaterThanOrEqual(changes - c, 8, "★ Finishing: redrawn about 30 times a second with no new piece")
            g.seal(landed: true)
            XCTAssertFalse(g.working, "★ it ends with the landing")
            try await Task.sleep(nanoseconds: UInt64((LatticeGrowth.fadeS + 0.2) * 1e9))
            c = changes
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(changes, c, "landed: no more redraws")
            XCTAssertNil(g.workingSince)
        }
        // the band's front: from below the floor to past the top, a layer at a time, then again
        let (lo, hi): (Float, Float) = (0, 50)
        var last = -Float.greatestFiniteMagnitude, steps = Set<Float>()
        for k in 0..<280 {
            let t = Double(k) / 100   // one sweep (2.8 s)
            let f = LatticeGrowthPass.bandFront(t: t, lo: lo, hi: hi)
            XCTAssertGreaterThanOrEqual(f, last, "★ it rises")
            last = f; steps.insert(f)
        }
        XCTAssertLessThan(LatticeGrowthPass.bandFront(t: 0, lo: lo, hi: hi), lo, "from below the floor")
        XCTAssertGreaterThan(last, hi, "to past the top")
        XCTAssertEqual(steps.count, LatticeGrowthPass.bandLayers, "★ a print layer at a time")
        XCTAssertEqual(LatticeGrowthPass.bandFront(t: LatticeGrowthPass.bandPeriodS + 0.01, lo: lo, hi: hi),
                       LatticeGrowthPass.bandFront(t: 0.01, lo: lo, hi: hi), "★ and again (a loop)")
        XCTAssertEqual(LatticeGrowthPass.bandStrength(t: 0), 0, "it comes in softly")
        XCTAssertEqual(LatticeGrowthPass.bandStrength(t: 5), LatticeGrowthPass.bandMost)
        XCTAssertLessThanOrEqual(LatticeGrowthPass.bandMost, 0.5, "subtle")
        let b = LatticeGrowthPass.bandColour
        XCTAssertGreaterThan(b.z, b.y + 0.15, "in the lattice's purple (blue over green)")
    }

    // MARK: on the app's renderer

    #if canImport(MetalKit)
    /// The 20 × 10 × 20 box (y up on screen) the renderer tests use.
    static let boxV: [Float] = [0, 0, 0, 20, 0, 0, 20, 10, 0, 0, 10, 0, 0, 0, 20, 20, 0, 20, 20, 10, 20, 0, 10, 20]
    static let boxI: [Int32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6,
                                1, 6, 5]
    static let clear = MTLClearColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)

    /// `n` pieces in a line from `a` to `b` (6 floats each).
    static func vine(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ n: Int) -> [Float] {
        var out: [Float] = []
        for k in 0..<n {
            let p = a + (b - a) * Float(k) / Float(n), q = a + (b - a) * Float(k + 1) / Float(n)
            out += [p.x, p.y, p.z, q.x, q.y, q.z]
        }
        return out
    }
    /// One group asking `width` mm for region 1.
    static func group(_ width: Double) -> [LatticeLayoutSession.OrganicGroup] {
        var a = LatticeLayoutSession.Organic(); a.widthMM = width
        return [.init(regions: [1], ask: a)]
    }

    private func renderer(scale: Float = 1) throws -> (MeshRenderer, MTLDevice) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = MeshRenderer(device: device, sampleCount: 1) else { throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")") }
        r.setMesh(ViewerMesh(vertices: Self.boxV.map { $0 * scale }, indices: Self.boxI,
                             faceIDs: [Int32](repeating: 1, count: Self.boxI.count / 3)))
        r.camera.setOrientation(azimuth: 0.6, elevation: 0.4)
        return (r, device)
    }
    private func frame(_ r: MeshRenderer, _ w: Int = 400, _ h: Int = 300) throws -> [UInt8] {
        try XCTUnwrap(r.renderOffscreen(width: w, height: h, clear: Self.clear, stage: false))
    }
    /// The pixels that differ from `bare`, by index, as RGB.
    private func lit(_ f: [UInt8], _ bare: [UInt8]) -> [Int: SIMD3<Float>] {
        var out: [Int: SIMD3<Float>] = [:]
        for i in stride(from: 0, to: f.count, by: 4) where f[i..<i + 4] != bare[i..<i + 4] {
            out[i / 4] = SIMD3(Float(f[i + 2]), Float(f[i + 1]), Float(f[i]))   // BGRA
        }
        return out
    }
    /// The lattice's purple (blue well over green), lit.
    private static func purple(_ c: SIMD3<Float>) -> Bool { c.z > c.y + 15 && c.z > 40 }

    /// ★ notes24 (img 49: "It needs to be in 3D. There needs to be depth … shadow/highlights"): a vine across the box, laid in
    /// one poll, the lattice alone (the body's own look is the next tests'): real tubes in the G-buffer, lit by the lattice's
    /// shade (light and shadow across each tube, the lattice's purple), the newest brighter but no wider (their true width);
    /// each poll uploads only its own pieces; sunk into the landed lattice, nothing. RED CONTROL: no growth attached, the bare
    /// frame.
    func testTheVinesAreLitTubesTheNewestBrighter() throws {
        let (r, _) = try renderer()
        r.setBodyAlpha(0)
        let bare = try frame(r)
        let g = LatticeGrowth()
        g.layBegins(Self.group(1.2), lineMM: 0.45, opening: .xray)
        g.replayOffForTesting()   // (the replay's own tests: LatticeGrowthReplayTests)
        r.applyGrowth(g)
        XCTAssertEqual(try frame(r), bare, "nothing grown yet: the bare frame")
        g.append(xyz: Self.vine(SIMD3(2, 5, 10), SIMD3(18, 5, 10), 200), region: [Int32](repeating: 1, count: 200))
        let young = try frame(r)
        let pass = try XCTUnwrap(r.growthPass, "★ the growth's pass built: \(LatticeGrowthPass.lastInitError ?? "")")
        XCTAssertEqual(pass.uploaded, 200)
        XCTAssertTrue(r.lastFrameHadLatticeGBuffer, "★ the growth is in the lattice's G-buffer (lit as the landed lattice)")
        for poll in 1...10 {   // ten polls of pieces far off screen: the vine cools
            g.append(xyz: [Float](repeating: 1000, count: 6 * 40), region: [Int32](repeating: 1, count: 40))
            _ = try frame(r)
            XCTAssertEqual(pass.uploaded, 200 + 40 * poll, "★ each poll's own pieces, after the last")
        }
        XCTAssertEqual(pass.buffersMade, 1, "★ never the whole set again: one buffer, appended to")
        XCTAssertEqual(pass.lastDrawn, 600)
        let old = try frame(r)
        let y = lit(young, bare), o = lit(old, bare)
        XCTAssertGreaterThan(o.count, 600, "★ the vine is on screen, a tube 1.2 mm across")
        XCTAssertEqual(Double(y.count), Double(o.count), accuracy: 0.05 * Double(o.count),
                       "★ the newest no wider: every piece at its true width")
        let purple = o.values.filter(Self.purple).count
        XCTAssertGreaterThan(Double(purple), 0.6 * Double(o.count), "★ in the lattice's purple")
        let lum = o.values.map { $0.sum() }.sorted()
        XCTAssertGreaterThan(lum[lum.count * 95 / 100] - lum[lum.count * 5 / 100], 60, "★ lit: light and shadow across the tube")
        let both = o.keys.filter { y[$0] != nil }
        let bYoung = both.map { y[$0]!.sum() }.reduce(0, +) / Float(Swift.max(1, both.count))
        let bOld = both.map { o[$0]!.sum() }.reduce(0, +) / Float(Swift.max(1, both.count))
        print("GROWTH TUBES: newest \(y.count) px at \(bYoung), ten polls old \(o.count) px at \(bOld); purple \(purple); "
              + "lum 5-95% \(lum[lum.count * 5 / 100])-\(lum[lum.count * 95 / 100])")
        XCTAssertGreaterThan(bYoung, bOld * 1.1, "★ the growing tips a little brighter than the vine behind them")
        // landed: sunk into the finished lattice, nothing drawn
        g.seal(landed: true, now: CACurrentMediaTime() - 10)
        XCTAssertEqual(try frame(r), bare, "★ sunk into the finished lattice: nothing drawn")
        XCTAssertEqual(r.growthPass?.lastDrawn, 0)
        // RED CONTROL: no growth attached
        g.restart(); g.append(xyz: [2, 5, 10, 18, 5, 10], region: [1])
        XCTAssertNotEqual(try frame(r), bare, "premise: drawn while attached")
        r.applyGrowth(nil)
        XCTAssertEqual(try frame(r), bare, "RED CONTROL: no growth attached, the bare frame")
    }

    /// The box's map for the solid view: its right half (x > 10) open lattice, the rest solid (LatticeLayoutSession.grid's
    /// two bytes a voxel: open, inside), 1 mm voxels with a voxel of air round it.
    static func halfOpenMap(token: Int) -> LatticeLayoutSolidGrid {
        let dims = SIMD3<Int32>(25, 15, 25), origin = SIMD3<Float>(-2, -2, -2)
        var rg = [Int8]()
        for z in 0..<Int(dims.z) { for y in 0..<Int(dims.y) { for x in 0..<Int(dims.x) {
            let p = origin + SIMD3(Float(x), Float(y), Float(z))
            let inside = p.x >= -0.01 && p.x <= 20.01 && p.y >= -0.01 && p.y <= 10.01 && p.z >= -0.01 && p.z <= 20.01
            rg += [inside && p.x > 10 ? 127 : -127, inside ? 127 : -127]
        }}}
        return LatticeLayoutSolidGrid(token: token, origin: origin, voxel: 1, dims: dims, rg: rg)
    }

    /// ★ notes24 (img 49: "I would prefer having the walls removed and seeing the actual 3d models of the lattices grow - but
    /// only the ones that are visible to me, not the ones behind it"): the solid view, the map on screen this lay's (its right
    /// half open). Seen from the front, the vine in the open half grows inside the opened part; the one behind the closed
    /// wall is hidden — the tubes are depth-tested against the part as the landed lattice is. RED CONTROLS: the map on screen
    /// not this lay's → the X-ray stand-in, both seen; no stand-in and no map → the closed part hides every vine (never drawn
    /// over the frame again).
    func testOnlyWhatHeCanSeeGrowsInsideThePartOpenedByItsMap() throws {
        defer { LatticeGrowthPass.controlNoXrayStandIn = false }
        let (r, device) = try renderer()
        r.setBodyAlpha(1)   // the solid view
        r.camera.setOrientation(azimuth: 0, elevation: 0.12)
        let bars = LatticeLayoutBarsInputs(token: 7, bars: [3, 3, 3, 3.1, 3, 3, 0.05], solid: Self.halfOpenMap(token: 7))
        XCTAssertTrue(r.applyLayoutBars(bars, device: device))
        let g = LatticeGrowth()
        g.layBegins(Self.group(1.2), lineMM: 0.45, opening: .open)
        g.replayOffForTesting()   // (the replay's own tests: LatticeGrowthReplayTests)
        r.applyGrowth(g)
        g.append(xyz: Self.vine(SIMD3(12, 5, 10), SIMD3(18, 5, 10), 60) + Self.vine(SIMD3(2, 5, 10), SIMD3(8, 5, 10), 60),
                 region: [Int32](repeating: 1, count: 120))
        let w = 400
        func halves(_ f: [UInt8]) -> (left: Int, right: Int) {
            var l = 0, rr = 0
            for i in stride(from: 0, to: f.count, by: 4) {
                let c = SIMD3(Float(f[i + 2]), Float(f[i + 1]), Float(f[i]))
                guard Self.purple(c) else { continue }
                if (i / 4) % w < w / 2 { l += 1 } else { rr += 1 }
            }
            return (l, rr)
        }
        let opened = halves(try frame(r, w, 300))
        XCTAssertNotNil(r.layoutBars?.shellClip, "premise: the map is on screen")
        XCTAssertFalse(r.growthXraysBody, "★ the map on screen is this lay's: the part drawn as the landed lattice draws it")
        print("GROWTH IN THE OPENED PART: purple left (behind the closed wall) \(opened.left), right (opened) \(opened.right)")
        XCTAssertGreaterThan(opened.right, 150, "★ through the opened face: the vine grows in 3D")
        XCTAssertLessThan(opened.left, 10, "★ the vine behind the closed wall is hidden (only what he can see)")
        // RED CONTROL: the map on screen is another lay's: the part in X-ray while it grows, both vines seen
        g.layBegins(Self.group(1.2), lineMM: 0.45, opening: .xray)
        g.replayOffForTesting()   // (the replay's own tests: LatticeGrowthReplayTests)
        let xray = halves(try frame(r, w, 300))
        XCTAssertTrue(r.growthXraysBody)
        XCTAssertGreaterThan(xray.left, 100, "RED CONTROL: the X-ray stand-in shows the vine the wall hid")
        // RED CONTROL: no map, no stand-in: the closed part hides them all — they are inside it, depth-tested
        r.applyLayoutBars(nil, device: device)
        LatticeGrowthPass.controlNoXrayStandIn = true
        let closed = halves(try frame(r, w, 300))
        XCTAssertLessThan(closed.left + closed.right, 10, "RED CONTROL: the closed part hides every vine (never over the frame)")
    }

    /// ★ notes24: no map yet (the first lay of these settings): the part in X-ray while the vines grow, and after the lattice
    /// lands until its own map opens it — never a closed part between; then solid, opened by its map; a new lay holds nothing.
    func testThePartStaysInXrayUntilTheLandedLatticesMapOpensIt() throws {
        let (r, device) = try renderer()
        r.setBodyAlpha(1)
        let g = LatticeGrowth()
        g.layBegins(Self.group(1.2), lineMM: 0.45, opening: .xray)
        g.replayOffForTesting()   // (the replay's own tests: LatticeGrowthReplayTests)
        r.applyGrowth(g)
        g.append(xyz: Self.vine(SIMD3(2, 5, 10), SIMD3(18, 5, 10), 50), region: [Int32](repeating: 1, count: 50))
        _ = try frame(r)
        XCTAssertTrue(r.growthXraysBody, "★ no map: the vines grow inside the part in X-ray")
        // it lands: the lattice without its map yet (the engine makes it after the lay)
        var bars = LatticeLayoutBarsInputs(token: 9, bars: [3, 3, 3, 3.1, 3, 3, 0.05])
        r.applyLayoutBars(bars, device: device)
        g.seal(landed: true, now: CACurrentMediaTime() - 10)
        _ = try frame(r)
        XCTAssertFalse(r.growthInFrame, "premise: the growth sank")
        XCTAssertTrue(r.growthXraysBody, "★ held in X-ray until the landed lattice's map opens the part")
        bars.solid = Self.halfOpenMap(token: 9)
        r.applyLayoutBars(bars, device: device)
        _ = try frame(r)
        XCTAssertFalse(r.growthXraysBody, "★ its map came: solid, opened by it")
        g.restart()
        r.applyLayoutBars(nil, device: device)
        _ = try frame(r)
        XCTAssertFalse(r.growthXraysBody, "a new lay holds nothing")
        r.setBodyAlpha(LatticeLayoutPreview.ghostAlpha)
        g.append(xyz: Self.vine(SIMD3(2, 5, 10), SIMD3(18, 5, 10), 50), region: [Int32](repeating: 1, count: 50))
        _ = try frame(r)
        XCTAssertFalse(r.growthXraysBody, "X-ray on: X-ray already")
    }

    /// ★ notes24 ("my preference is to literally have it looking exactly like the final result"; the switch seamless): one vine
    /// drawn as the growth (cooled) and as the landed lattice draws it (OrganicVineShape) cover the same pixels in the same
    /// light; at the landing the growth sinks into the landed vine (no pop) and is gone.
    func testTheGrowthLooksLikeTheLandedLatticeAndSinksIntoIt() throws {
        defer { MeshRenderer.growthClockForTesting = nil }
        let (r, device) = try renderer()
        r.setBodyAlpha(0)   // the lattice alone
        r.camera.setOrientation(azimuth: 0.5, elevation: 0.35)
        let pts: [SIMD3<Float>] = [SIMD3(2, 5, 10), SIMD3(10, 5, 10), SIMD3(18, 5, 10)]
        let run = LatticeLayoutSession.Run(region: 1, marks: [], endA: 0, endB: 0, points: pts,
                                           widthMM: [1.2, 1.2, 1.2], spacingMM: [4, 4, 4])
        var bars = LatticeLayoutBarsInputs(token: 3, bars: LatticeLayoutPreview.segments([run]).bars,
                                           flags: LatticeLayoutPreview.segments([run]).flags)
        bars.vines = OrganicVineShape.tubes(runs: [run])
        let bare = try frame(r)
        XCTAssertTrue(r.applyLayoutBars(bars, device: device))
        let landed = try frame(r)
        r.applyLayoutBars(nil, device: device)
        let g = LatticeGrowth()
        g.layBegins(Self.group(1.2), lineMM: 0.45, opening: .xray)
        g.replayOffForTesting()   // (the replay's own tests: LatticeGrowthReplayTests)
        r.applyGrowth(g)
        g.append(xyz: Self.vine(pts[0], pts[1], 40) + Self.vine(pts[1], pts[2], 40), region: [Int32](repeating: 1, count: 80))
        for _ in 0..<10 { g.append(xyz: [Float](repeating: 1000, count: 6), region: [1]) }   // cooled
        let grown = try frame(r)
        let l = lit(landed, bare), gr = lit(grown, bare)
        let both = Set(l.keys).intersection(gr.keys), either = Set(l.keys).union(gr.keys)
        let iou = Double(both.count) / Double(Swift.max(1, either.count))
        var diff = SIMD3<Float>(repeating: 0)
        for k in both { diff += simd_abs(l[k]! - gr[k]!) }
        diff /= Float(Swift.max(1, both.count))
        print("GROWTH vs LANDED: landed \(l.count) px, grown \(gr.count) px, overlap \(iou), mean colour difference \(diff)")
        XCTAssertGreaterThan(l.count, 500, "premise: the landed vine drawn")
        XCTAssertGreaterThan(iou, 0.85, "★ the same tube on screen")
        XCTAssertLessThan(diff.max(), 16, "★ in the same light (the lattice's own shade)")
        // the landing: the finished vine drawn, the growth sinking into it
        XCTAssertTrue(r.applyLayoutBars(bars, device: device))
        let t0 = CACurrentMediaTime()
        g.seal(landed: true, now: t0)
        var counts: [Int] = []
        for k in 0...6 {
            MeshRenderer.growthClockForTesting = t0 + LatticeGrowth.fadeS * Double(k) / 6
            counts.append(lit(try frame(r), bare).count)
        }
        MeshRenderer.growthClockForTesting = t0 + LatticeGrowth.fadeS + 0.01
        let after = try frame(r)
        print("LANDING: pixels as the growth sinks \(counts), the landed lattice \(l.count)")
        XCTAssertEqual(after, landed, "★ sunk: exactly the landed lattice")
        for c in counts { XCTAssertEqual(Double(c), Double(l.count), accuracy: 0.12 * Double(l.count), "★ no pop as it lands") }
        for (a, b) in zip(counts, counts.dropFirst()) { XCTAssertGreaterThanOrEqual(a + 2, b, "it only sinks") }
    }

    /// ★ notes24 (item 3 on the renderer): Finishing, two moments of the band of light rising through a standing vine draw
    /// differently, its light in the lattice's purple; RED CONTROL `controlNoWorkingBand`: the same picture.
    func testTheBandOfLightRisesThroughTheGrownVines() throws {
        defer { MeshRenderer.growthClockForTesting = nil; LatticeGrowth.controlNoWorkingBand = false }
        let (r, _) = try renderer()
        r.setBodyAlpha(0)
        r.camera.setOrientation(azimuth: 0.3, elevation: 0.15)
        var seen: [[UInt8]] = []
        for red in [false, true] {
            LatticeGrowth.controlNoWorkingBand = red
            let g = LatticeGrowth()
            g.layBegins(Self.group(2), lineMM: 0.45, opening: .xray)
            g.replayOffForTesting()   // (the replay's own tests: LatticeGrowthReplayTests)
            r.applyGrowth(g)
            g.append(xyz: Self.vine(SIMD3(10, 0.5, 10), SIMD3(10, 9.5, 10), 30), region: [Int32](repeating: 1, count: 30))
            for _ in 0..<8 { g.append(xyz: [Float](repeating: 1000, count: 6), region: [1]) }   // cooled
            let t0 = CACurrentMediaTime()
            g.phaseMoved(5, now: t0)
            MeshRenderer.growthClockForTesting = t0 + 1.0
            let a = try frame(r)
            MeshRenderer.growthClockForTesting = t0 + 1.0 + LatticeGrowthPass.bandPeriodS * 0.35
            let b = try frame(r)
            var changed = 0, brighterPurple = 0
            for i in stride(from: 0, to: a.count, by: 4) where a[i..<i + 4] != b[i..<i + 4] {
                changed += 1
                let ca = SIMD3(Float(a[i + 2]), Float(a[i + 1]), Float(a[i])), cb = SIMD3(Float(b[i + 2]), Float(b[i + 1]), Float(b[i]))
                let lighter = ca.sum() > cb.sum() ? ca : cb
                if Self.purple(lighter) { brighterPurple += 1 }
            }
            print("BAND \(red ? "RED CONTROL" : "on"): \(changed) pixels moved, \(brighterPurple) of them lit purple")
            if red {
                XCTAssertEqual(changed, 0, "RED CONTROL: a still picture")
            } else {
                XCTAssertGreaterThan(changed, 80, "★ the band moved up the vine")
                XCTAssertGreaterThan(Double(brighterPurple), 0.7 * Double(changed), "★ its light in the lattice's purple")
            }
            seen.append(a)
            g.seal(landed: false)
        }
    }

    /// ★ notes24: "it must stay smooth on an M1 iPad up to ~150,000 pieces": 147,000 growing pieces cost the GPU no more than
    /// the landed vines he approved at that count (his stand's Grown lattice), measured by Metal on this Mac at 1536².
    func testAHundredAndFiftyThousandPiecesDrawAsFastAsTheLandedVines() throws {
        let (r, device) = try renderer(scale: 5)   // a 100 × 50 × 100 mm box
        r.setBodyAlpha(LatticeLayoutPreview.ghostAlpha)
        var runs: [LatticeLayoutSession.Run] = []
        var xyz: [Float] = []
        for iy in 0..<30 { for iz in 0..<60 {   // 1,800 straight vines 1.6 mm apart (no joints), 81 pieces each
            let y = 1 + Float(iy) * 1.6, z = 1 + Float(iz) * 1.6
            let pts = (0..<82).map { SIMD3<Float>(1 + Float($0) * 1.2, y, z) }
            runs.append(LatticeLayoutSession.Run(region: 1, marks: [], endA: 0, endB: 0, points: pts,
                                                 widthMM: [Float](repeating: 0.6, count: 82), spacingMM: [Float](repeating: 4, count: 82)))
            for k in 0..<81 { xyz += [pts[k].x, pts[k].y, pts[k].z, pts[k + 1].x, pts[k + 1].y, pts[k + 1].z] }
        }}
        let n = xyz.count / 6
        func best() -> Double {
            (0..<4).compactMap { _ in r.measureFrameGPUSeconds(size: 1536, stage: true) }.min() ?? .infinity
        }
        let seg = LatticeLayoutPreview.segments(runs)
        var bars = LatticeLayoutBarsInputs(token: 11, bars: seg.bars, flags: seg.flags)
        bars.vines = OrganicVineShape.tubes(runs: runs)
        XCTAssertTrue(r.applyLayoutBars(bars, device: device))
        let landedS = best()
        r.applyLayoutBars(nil, device: device)
        let g = LatticeGrowth()
        g.layBegins(Self.group(0.6), lineMM: 0.45, opening: .xray)
        g.replayOffForTesting()   // (the replay's own tests: LatticeGrowthReplayTests)
        r.applyGrowth(g)
        g.append(xyz: xyz, region: [Int32](repeating: 1, count: n))
        let grownS = best()
        print(String(format: "GROWTH COST: %d pieces, growing %.2f ms a frame, the landed vines %.2f ms (GPU, 1536²)", n,
                     grownS * 1000, landedS * 1000))
        XCTAssertEqual(r.growthPass?.lastDrawn, n, "every piece drawn (under the budget)")
        XCTAssertLessThanOrEqual(grownS, landedS * 1.25 + 0.002, "★ no dearer than the landed vines he approved")
    }

    /// Past the budget the older pieces are thinned, every newest piece kept; under it, all drawn. One piece is 32 triangles.
    func testPastTheBudgetTheOldestAreThinnedNeverTheTips() {
        XCTAssertEqual(LatticeGrowthPass.plan(1_000).oldCount, 0)
        XCTAssertEqual(LatticeGrowthPass.plan(1_000).tipsFrom, 0, "under the budget: every piece")
        for n in [600_001, 1_000_000, 2_500_000] {
            let p = LatticeGrowthPass.plan(n)
            let drawn = p.oldCount + (n - p.tipsFrom)
            XCTAssertEqual(n - p.tipsFrom, LatticeGrowthPass.tipsKept, "★ \(n): every one of the newest drawn")
            XCTAssertEqual(drawn, LatticeGrowthPass.drawMost, "★ \(n): the budget, no more")
            XCTAssertGreaterThanOrEqual(p.oldStride, 1)
            XCTAssertLessThan(Int(Float(p.oldCount - 1) * p.oldStride), p.tipsFrom, "the thinned ones are the older pieces")
        }
        XCTAssertEqual(LatticeGrowthPass.indices.count, 96, "32 triangles a piece")
        XCTAssertEqual(Set(LatticeGrowthPass.indices).count, 2 * LatticeGrowthPass.sides + 2, "over 18 vertices")
        let src = try? FlexibleSource.code("LatticeGrowthPass.swift")
        XCTAssertFalse(src?.contains("depthCompareFunction = .always") ?? true, "★ never drawn over the frame again")
    }
    #endif
}
