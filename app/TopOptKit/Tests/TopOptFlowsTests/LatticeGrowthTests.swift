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

    // MARK: on the app's renderer

    #if canImport(MetalKit)
    /// A 20 × 10 × 20 box, a vine across it laid in five polls: drawn in the lattice's purple over the frame, the newest
    /// brighter; each poll uploads only its own pieces; faded out, nothing. RED CONTROL: no growth attached, the bare frame.
    func testTheVinesDrawOnTheRendererTheNewestBrighter() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = MeshRenderer(device: device, sampleCount: 1) else { throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")") }
        let v: [Float] = [0, 0, 0, 20, 0, 0, 20, 10, 0, 0, 10, 0, 0, 0, 20, 20, 0, 20, 20, 10, 20, 0, 10, 20]
        let idx: [Int32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5]
        r.setMesh(ViewerMesh(vertices: v, indices: idx, faceIDs: [Int32](repeating: 1, count: idx.count / 3)))
        r.camera.setOrientation(azimuth: 0.6, elevation: 0.4)
        r.setBodyAlpha(LatticeLayoutPreview.ghostAlpha)
        let clear = MTLClearColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        func frame() throws -> [UInt8] { try XCTUnwrap(r.renderOffscreen(width: 400, height: 300, clear: clear, stage: false)) }
        let bare = try frame()
        let g = LatticeGrowth()
        r.applyGrowth(g)
        XCTAssertEqual(try frame(), bare, "nothing grown yet: the bare frame")
        // a vine across the box (x, at y = 5, z = 10), 200 pieces of 0.08 mm, laid in ONE poll: all of it the newest
        var vine: [Float] = []
        for k in 0..<200 {
            let x0 = 2 + Float(k) * 0.08
            vine += [x0, 5, 10, x0 + 0.08, 5, 10]
        }
        g.append(xyz: vine, region: [Int32](repeating: 1, count: 200))
        let young = try frame()
        let pass = try XCTUnwrap(r.growthPass, "★ the growth's pass built: \(LatticeGrowthPass.lastInitError ?? "")")
        XCTAssertEqual(pass.uploaded, 200)
        // four more polls of pieces far off screen: the vine is now four polls old
        for poll in 1...4 {
            g.append(xyz: [Float](repeating: 1000, count: 6 * 40), region: [Int32](repeating: 1, count: 40))
            _ = try frame()
            XCTAssertEqual(pass.uploaded, 200 + 40 * poll, "★ each poll's own pieces, after the last")
        }
        XCTAssertEqual(pass.buffersMade, 1, "★ never the whole set again: one buffer, appended to")
        XCTAssertEqual(pass.lastDrawn, 360)
        let old = try frame()
        func lit(_ f: [UInt8]) -> [Int: SIMD3<Float>] {
            var out: [Int: SIMD3<Float>] = [:]
            for i in stride(from: 0, to: f.count, by: 4) where f[i..<i + 4] != bare[i..<i + 4] {
                out[i / 4] = SIMD3(Float(f[i + 2]), Float(f[i + 1]), Float(f[i]))   // BGRA
            }
            return out
        }
        let y = lit(young), o = lit(old)
        XCTAssertGreaterThan(o.count, 150, "★ the vine is on screen")
        XCTAssertGreaterThan(y.count, o.count, "★ the growing tips are drawn wider")
        let purple = o.values.filter { $0.z > $0.y + 20 }.count
        XCTAssertGreaterThan(Double(purple), 0.6 * Double(o.count), "★ in the lattice's purple (blue over green)")
        let both = o.keys.filter { y[$0] != nil }
        let bYoung = both.map { y[$0]!.sum() }.reduce(0, +) / Float(Swift.max(1, both.count))
        let bOld = both.map { o[$0]!.sum() }.reduce(0, +) / Float(Swift.max(1, both.count))
        print("GROWTH PASS: newest \(y.count) px at \(bYoung), four polls old \(o.count) px at \(bOld); purple \(purple)")
        XCTAssertGreaterThan(bYoung, bOld * 1.15, "★ the growing tips brighter than the vine behind them")
        // faded out: nothing drawn
        g.seal(landed: true, now: CACurrentMediaTime() - 10)
        XCTAssertEqual(try frame(), bare, "★ faded out over the finished lattice: nothing drawn")
        XCTAssertEqual(r.growthPass?.lastDrawn, 0)
        // RED CONTROL: no growth attached
        g.restart(); g.append(xyz: [2, 5, 10, 18, 5, 10], region: [1])
        XCTAssertNotEqual(try frame(), bare, "premise: drawn while attached")
        r.applyGrowth(nil)
        XCTAssertEqual(try frame(), bare, "RED CONTROL: no growth attached, the bare frame")
    }

    /// Past the budget the older pieces are thinned, every newest piece kept; under it, all drawn.
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
        XCTAssertEqual(LatticeGrowthPass.halfWidth(short: 2064), 2064 * 0.0009, accuracy: 1e-4, "about 2 pt on his 13″ iPad")
        XCTAssertEqual(LatticeGrowthPass.halfWidth(short: 300), 1, "never under a pixel")
    }
    #endif
}
