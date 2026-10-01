// FlexibleSquishVerifyGTests — the batch G verification's page, loop and gate findings, each on
// HIS project through Save & Exit and the page's own debounced refresh (task
// 2026-09-29-flexible-screens, round 5 batch G verification). Each with its RED control:
//   * Save & Exit shows the lattice held at REST until its field lands — never the old column
//     squish first — RED: the sims read before they are started (batch G's order);
//   * a failed ONLY sim plays the column squish — RED: batch G's loop rules (one start per
//     generation) with its read order;
//   * a pick of a sim still solving plays when it lands — RED: batch G's loop rules;
//   * every sim of "Play all" failed: ONE group's column squish plays (never every face at once),
//     and a failed group under "Play all" is said — RED: the combo;
//   * "Play all" plays each group ALONE — its own colours swapped in with its field, the picker
//     and the note following the playing group — RED: the combo.
// (The one claim on core is FlexibleCoreClaimTests.)
#if canImport(MetalKit)
import XCTest
import Combine
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleSquishVerifyGTests: XCTestCase {

    typealias Fx = FlexibleLatticeFixtures
    let P = FlexibleSquishLoop.periodS

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var v: T
        init(_ v: T) { self.v = v }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return v }
            set { lock.lock(); v = newValue; lock.unlock() }
        }
    }

    /// His project through Save & Exit on a main stage, driven ONLY by the page's own debounced
    /// refresh until every sim has landed (`sample` sees each state on the way). `split`: top | sides.
    func stage(_ source: URL? = nil, split: Bool = false, failing: Set<String> = [], failDelayS: Double = 0,
               configure: (FlexibleMainStage) -> Void = { _ in },
               sample: ((FlexibleMainStage, FlexibleStageModel) -> Void)? = nil) async throws
        -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(source)
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { false }
        configure(stage)
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.keepFERequest = true
        m.squishSolver.controlFailSimIDs = failing
        m.squishSolver.controlFailDelayS = failDelayS
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his")
        if split {
            m.edit { s in
                _ = FlexibleSqueezeGroups.newGroup(with: 3, in: &s)
                FlexibleSqueezeGroups.move(5, to: FlexibleSqueezeGroups.group(of: 3, in: s)!.id, in: &s)
            }
            try await FlexibleSquishFixture.settle(m, "his split")
        }
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        let start = Date()
        while Date().timeIntervalSince(start) < 400 {
            sample?(stage, m)
            if m.lattice != nil, !m.squish.isEmpty, !m.squish.values.contains(.pending), m.squishSolver.isIdle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // the page's debounced refreshes after the last sim landed
        for _ in 0..<40 { sample?(stage, m); try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(m.squish.isEmpty, "the sims ran")
        return (r, stage, m)
    }

    // MARK: - Save & Exit: rest until the field lands (UX major)

    func testSaveAndExitHoldsTheLatticeAtRestUntilItsFieldLands() async throws {
        func run(control: Bool) async throws -> (bad: [String], sawPending: Bool, playedAfter: Bool) {
            let bad = Box<[String]>([]), pending = Box(false), trace = Box<[String]>([])
            let t0 = Date()
            var watch: AnyCancellable?
            defer { watch?.cancel() }
            let (_, s, _) = try await stage(split: true, configure: { s in
                s.controlReadSimsBeforeStart = control
                s.controlLoopByGeneration = control
                // ★ AT THE SOURCE: the loop starting to play while the page shows the new lattice and
                // no field moves it — caught inside the refresh that does it (a heavy first refresh
                // holds the main actor, so a sampler can miss a flash the renderer would still draw)
                watch = s.loop.$playing.sink { [weak s] now in
                    guard let s, now, s.drawn != nil, !s.fe.active, s.fe.failure == nil else { return }
                    bad.value.append("started playing · fe pending \(s.fe.pending)")
                }
            }, sample: { s, m in
                let line = "lattice \(m.lattice?.generation ?? -1) drawn \(s.drawn?.generation ?? -1) · sims \(m.squish.values.map { $0 == .pending ? "p" : ($0.field != nil ? "r" : "f") }.sorted().joined()) · fe active \(s.fe.active) pending \(s.fe.pending) · playing \(s.loop.playing) held \(String(format: "%.2f", s.loop.held))"
                if trace.value.last?.hasSuffix(line) != true { trace.value.append(String(format: "%.2f s ", Date().timeIntervalSince(t0)) + line) }
                if s.fe.pending { pending.value = true }
                // the page shows the new lattice and no field moves it yet: it must be AT REST
                guard s.drawn != nil, !s.fe.active, s.fe.failure == nil else { return }
                if s.loop.playing || s.loop.held > 0 {
                    bad.value.append(String(format: "held %.2f playing %d pending %d", s.loop.held, s.loop.playing ? 1 : 0, s.fe.pending ? 1 : 0))
                }
            })
            print("FLEX-GV EXIT\(control ? " control" : "") timeline: " + trace.value.joined(separator: " → "))
            return (bad.value, pending.value, s.fe.active && s.loop.playing)
        }
        let fixed = try await run(control: false)
        print("FLEX-GV EXIT: before the field lands, frames not at rest: \(fixed.bad.count) (\(fixed.bad.prefix(3))) · saw 'Simulating…' \(fixed.sawPending) · the field plays after: \(fixed.playedAfter)")
        XCTAssertTrue(fixed.bad.isEmpty, "the lattice is held at rest until its field lands: \(fixed.bad.prefix(5))")
        XCTAssertTrue(fixed.sawPending, "…with 'Simulating the squish…'")
        XCTAssertTrue(fixed.playedAfter, "…and the field plays once it lands")
        // ★ RED CONTROL: batch G's order — the first refresh read an empty cache and played the column squish
        let red = try await run(control: true)
        print("FLEX-GV EXIT control (sims read before they start): frames not at rest \(red.bad.count) (\(red.bad.prefix(3)))")
        XCTAssertFalse(red.bad.isEmpty, "control: batch G played the old column squish before the field")
    }

    // MARK: - a failed only sim plays the column squish (correctness major)

    func testAFailedOnlySimPlaysTheColumnSquish() async throws {
        // his project as saved: ONE group; its sim fails (after the page saw it pending)
        let (r, s, m) = try await stage(failing: ["group-1"], failDelayS: 1)
        XCTAssertNotNil(m.squish["group-1"]?.failure)
        XCTAssertFalse(s.fe.active)
        print("FLEX-GV FALLBACK one group: note '\(s.simNote ?? "-")' · playing \(s.loop.playing) held \(s.loop.held) · layer faces \(s.layer(r.project, stage: .lattice, pageUp: false)?.faces.count ?? -1)")
        XCTAssertTrue(s.loop.playing, "a failed only sim plays the column squish")
        XCTAssertEqual(s.simNote, FlexibleFE.failed)
        XCTAssertFalse(try XCTUnwrap(s.layer(r.project, stage: .lattice, pageUp: false)).faces.isEmpty)
        // ★ RED CONTROL: batch G's code (its read order, one start per generation) — held at rest
        let (_, s2, m2) = try await stage(failing: ["group-1"], failDelayS: 1, configure: { s in
            s.controlReadSimsBeforeStart = true
            s.controlLoopByGeneration = true
        })
        XCTAssertNotNil(m2.squish["group-1"]?.failure)
        print("FLEX-GV FALLBACK control (batch G): playing \(s2.loop.playing) held \(s2.loop.held)")
        XCTAssertFalse(s2.loop.playing, "control: batch G left the failed only sim at rest")
    }

    // MARK: - a pick of a sim still solving plays when it lands (minor)

    func testAPickOfASolvingSimPlaysWhenItLands() async throws {
        for control in [false, true] {
            let (_, s, m) = try await stage(split: true)
            s.controlLoopByGeneration = control
            let g = try XCTUnwrap(m.lattice?.generation)
            let landed = try XCTUnwrap(m.squish["group-2"])
            XCTAssertTrue(s.loop.playing, "Play all plays")
            // group 2 still solving (its first seconds after Save & Exit)
            m.squishLanded(g, "group-2", .pending)
            s.refresh()
            s.pick("group-2")
            s.refresh()
            let held = (s.loop.playing, s.loop.held, s.simNote)
            m.squishLanded(g, "group-2", landed)
            for _ in 0..<3 { s.refresh() }
            print("FLEX-GV PICK PENDING\(control ? " control" : ""): picked while solving → playing \(held.0) held \(held.1) '\(held.2 ?? "-")' · landed → active \(s.fe.active) playing \(s.loop.playing) held \(s.loop.held)")
            XCTAssertFalse(held.0)
            XCTAssertEqual(held.2, FlexibleFE.pending)
            XCTAssertTrue(s.fe.active)
            if control {
                XCTAssertFalse(s.loop.playing, "control: batch G started once per generation — the late pick sat at rest")
            } else {
                XCTAssertTrue(s.loop.playing, "the picked group plays once its sim lands")
            }
        }
    }

    // MARK: - the column fallback never squishes every group at once (minor)

    func testEveryFailedSimOfPlayAllPlaysOneGroup() async throws {
        let (r, s, _) = try await stage(split: true, failing: ["group-1", "group-2"])
        let l = try XCTUnwrap(s.layer(r.project, stage: .lattice, pageUp: false))
        print("FLEX-GV ALL FAILED: fallback \(s.fallbackSim ?? "-") · picker \(s.shownSimInfo?.title ?? "-") · layer faces \(l.faces.count) loads \(l.faces.map(\.load)) · note '\(s.simNote ?? "-")' · playing \(s.loop.playing)")
        XCTAssertEqual(s.fallbackSim, "group-1")
        XCTAssertEqual(s.shownSimInfo?.id, "group-1", "the picker shows the group that plays")
        XCTAssertEqual(l.faces.count, 2)
        XCTAssertEqual(Set(l.faces.map { $0.load.z }), [-1], "the top's two sectors only (load −Z)")
        XCTAssertEqual(s.simNote, FlexibleFE.failed)
        XCTAssertTrue(s.loop.playing)
        // his pick of group 2 plays ITS column squish; back on Play all, group 1 again
        s.pick("group-2")
        let sides = try XCTUnwrap(s.layer(r.project, stage: .lattice, pageUp: false))
        XCTAssertEqual(Set(sides.faces.map { abs($0.load.x) }), [1])
        s.pick(FlexibleSim.allID)
        XCTAssertEqual(s.layer(r.project, stage: .lattice, pageUp: false)?.faces.count, 2)
        // ★ RED CONTROL: the combo — every group's faces at once
        s.controlPlayAllCombo = true
        s.refresh()
        let combo = try XCTUnwrap(s.layer(r.project, stage: .lattice, pageUp: false))
        print("FLEX-GV ALL FAILED control (combo): layer faces \(combo.faces.count)")
        XCTAssertEqual(combo.faces.count, 4, "control: Play all on the column path squished every face at once")
        // a failed group under Play all is SAID (it used to be skipped silently)
        let (_, s2, _) = try await stage(split: true, failing: ["group-2"])
        print("FLEX-GV ONE FAILED: Play all sequence \(s2.fe.sequence.map { s2.fe.fields[$0].simID }) · note '\(s2.simNote ?? "-")'")
        XCTAssertEqual(s2.fe.sequence.map { s2.fe.fields[$0].simID }, ["group-1"])
        XCTAssertEqual(s2.simNote, FlexibleFE.skipped("Group 2"))
        XCTAssertLessThanOrEqual(FlexibleFE.skipped("Group 2").count, FlexibleRowCopy.maxChars)
    }

    // MARK: - "Play all" plays each group ALONE (UX major)

    /// Face `region`'s map quads in a tint array (8 floats per flat vertex, 6 vertices per column).
    func quads(_ t: [Float], _ o: FlexibleOverlayMesh, _ m: FlexibleStageModel, _ region: Int) throws -> [Float] {
        let k = FlexFaceKey(region: region, rotation: 0)
        let start = try XCTUnwrap(o.flatStart[k]), n = try XCTUnwrap(m.stacks[k]).columns.count * 6
        return Array(t[(start * 8)..<((start + n) * 8)])
    }

    func testPlayAllPlaysEachGroupAlone() async throws {
        let (r, s, m) = try await stage(split: true)
        let o = try XCTUnwrap(s.overlay)
        XCTAssertEqual(s.shownSimInfo?.kind, .playAll, "Play all is the default")
        XCTAssertTrue(s.playAllLive)
        let seq = s.fe.sequence
        XCTAssertEqual(seq.map { s.fe.fields[$0].simID }, ["group-1", "group-2"])
        XCTAssertEqual(Set(s.feBaseTints.keys), ["group-1", "group-2"])
        // the page's tints follow the group the renderer shows — each group's own faces coloured
        s.loop.shownIndex = seq[0]
        let t1 = try XCTUnwrap(s.tints(r.project, on: .lattice, roles: [:], stress: nil))
        s.loop.shownIndex = seq[1]
        let t2 = try XCTUnwrap(s.tints(r.project, on: .lattice, roles: [:], stress: nil))
        let combo = try XCTUnwrap(s.composed)
        let top = [FlexibleHisProject.topA, FlexibleHisProject.topB], sides = [3, 5]
        for f in top {
            XCTAssertEqual(try quads(t1, o, m, f), try quads(combo, o, m, f), "group 1's turn: its face \(f) coloured on the page's one scale")
            XCTAssertNotEqual(try quads(t2, o, m, f), try quads(combo, o, m, f), "group 2's turn: face \(f) is not coloured")
        }
        for f in sides {
            XCTAssertEqual(try quads(t2, o, m, f), try quads(combo, o, m, f), "group 2's turn: its face \(f) coloured")
            XCTAssertNotEqual(try quads(t1, o, m, f), try quads(combo, o, m, f), "group 1's turn: face \(f) is not coloured")
        }
        // the renderer swaps each group's colours in WITH its field and mesh, and the picker learns it
        let device = try Fx.device()
        let rend = try Fx.renderer(device: device)
        rend.setMesh(try XCTUnwrap(s.mesh(r.project, on: .lattice)))
        var t: CFTimeInterval = 1000
        s.loop.clock = { t }
        let l = try XCTUnwrap(s.layer(r.project, stage: .lattice, pageUp: false))
        rend.applyFlexibleLattice(l, device: device)
        let pass = try XCTUnwrap(rend.flexibleLattice)
        s.loop.restartFromRest(reduceMotion: false)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let player = { FlexibleSquishPlayer(loop: s.loop, fullLabel: "", playAllLive: s.playAllLive,
                                            noteFor: { s.simNote(playing: $0) }, sims: s.sims, shown: s.shownSimInfo) }
        var seen: [String] = [], labels = Set<String>(), mismatches = 0
        for i in 0..<40 {
            t = 1000 + Double(i) * P / 10 + P / 20
            rend.stepFlexibleLoop(in: view, now: t)
            let shown = pass.feFields[pass.feShown].simID
            if seen.last != shown { seen.append(shown) }
            if pass.feTintsShown != shown || s.loop.playingSimID != shown { mismatches += 1 }
            labels.insert(player().pickerLabel)
            // the page hands the renderer's group too (a re-upload never shows another group's)
            if s.tints(r.project, on: .lattice, roles: [:], stress: nil) != s.feTintBox.tints(shown) { mismatches += 1 }
            if player().shownNote != m.lattice?.simNote(for: shown) { mismatches += 1 }
        }
        print("FLEX-GV PLAY ALL: turns \(seen) · picker \(labels.sorted()) · tint / label / note mismatches \(mismatches)")
        XCTAssertEqual(Array(seen.prefix(3)), ["group-1", "group-2", "group-1"])
        XCTAssertEqual(mismatches, 0, "each turn: its own colours, its label, its note")
        XCTAssertEqual(labels, ["All · Group 1", "All · Group 2"])
        // ★ RED CONTROL: the combo — every group's colours for every turn, the label 'All'
        s.controlPlayAllCombo = true
        s.refresh()
        s.loop.shownIndex = seq[1]
        let red = try XCTUnwrap(s.tints(r.project, on: .lattice, roles: [:], stress: nil))
        XCTAssertTrue(s.feBaseTints.isEmpty)
        XCTAssertEqual(try quads(red, o, m, FlexibleHisProject.topA), try quads(combo, o, m, FlexibleHisProject.topA),
                       "control: group 2's turn still colours the top")
        XCTAssertEqual(player().pickerLabel, FlexibleRowCopy.simAllShort, "control: the picker says only 'All'")
    }
}
#endif
