// Notes30NozzleInterruptTests — ★ notes30 Q2 (362's follow-up to Q1, 2026-11-26): he taps "Check a 0.2 mm nozzle" and changes a
// setting within a fraction of a second: the newer lay stops the check's map, which came back EMPTY — read as "no lattice
// asked" — and the pop-up said a 0.2 mm nozzle "would not lattice much more" of a part nothing had checked. Now:
//   * a map a newer lay stopped is said stopped (CancellationError), never an empty map: the solid-reason map, the solid
//     view's map and the nozzle check's cure alike;
//   * through the page: an interrupted check is never an answer — it goes back to "not asked" and, as he asked for it, is
//     asked again of the newer lattice once it lands; its one answer comes then, in the pop-up he asked from.
// RED CONTROLS `LatticeLayoutSession.controlStoppedMapReadsEmpty` and `LatticeLayoutPreview.controlNozzleAnswersWhenInterrupted`:
// before Q2 — the stopped map read empty, and the interrupted check answered "would not lattice much more".
// The part: Notes30PlacesGiveWayTests' synthetic 300 x 300 x 20 mm plate (never his files).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import Combine
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class Notes30NozzleInterruptTests: XCTestCase {

    override func tearDown() {
        LatticeLayoutSession.controlStoppedMapReadsEmpty = false
        LatticeLayoutPreview.controlNozzleAnswersWhenInterrupted = false
        LatticeLayoutSession.controlPlacesHoldTheWorker = false
        super.tearDown()
    }

    static let box = Notes30PlacesGiveWayTests.plateBox

    /// What a call gave: its value, or its error.
    static func outcome<T>(_ f: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await f()) } catch { return .failure(error) }
    }

    /// ★ A map a newer lay stopped is said stopped, never empty: the solid-reason map, the solid view's map, the nozzle check's
    /// cure. RED CONTROL: it reads empty — "no lattice asked", and the nozzle check's "would not lattice much more".
    @MainActor
    func testAMapANewerLayStoppedIsSaidStoppedNeverEmpty() async throws {
        let plate = try Notes30PlacesGiveWayTests.flatPlate(self)
        let main = try await LatticeLayoutSession.open(path: plate.path)
        let fine = try await LatticeLayoutSession.open(path: plate.path)
        addTeardownBlock { main.close(); fine.close() }
        let s = Notes30PlacesGiveWayTests.settings(top: plate.top, cellMM: 6)
        XCTAssertGreaterThan(s.beadMM, LatticeLayoutPreview.fineBeadMM + 0.05, "premise: a line the nozzle check asks about")
        _ = try await main.lay(s)
        let whole = try await LatticeLayoutPreview.unheldReport(main, Self.box)
        XCTAssertNotNil(whole, "premise: lattice asked for, read whole when nothing stops it")

        for red in [false, true] {
            LatticeLayoutSession.controlStoppedMapReadsEmpty = red
            let what = red ? "RED CONTROL" : "★"
            _ = try await main.lay(s)
            main.cancel()   // what a newer lay does first: the session's stop (its own lay not begun)
            let report = await Self.outcome { try await LatticeLayoutPreview.unheldReport(main, Self.box) }
            let map = await Self.outcome { try await LatticeLayoutPreview.map(main, Self.box, token: 1) }
            let cure = await Self.outcome { try await LatticeLayoutPreview.cure(main: main, fine: fine, settings: s, box: Self.box) }
            print("NOTES30-Q2 \(what): stopped — the solid-reason map \(report), the solid view's map "
                  + "\((try? map.get()).map { "\($0.grid.rg.count) bytes" } ?? "\(map)"), the nozzle check's cure \(cure)")
            if red {
                XCTAssertNil(try report.get(), "RED CONTROL: read as no lattice asked")
                XCTAssertTrue(try map.get().grid.rg.isEmpty, "RED CONTROL: an empty map")
                XCTAssertNil(try cure.get(), "RED CONTROL: the check finds nothing to say …")
                XCTAssertEqual(SolidPopUp.nozzleAnswer(cure: try cure.get()), "A 0.2 mm nozzle would not lattice much more of it.",
                               "RED CONTROL: … and answers it")
                continue
            }
            for (name, r) in [("the solid-reason map", report.map { _ in () }), ("the solid view's map", map.map { _ in () }),
                              ("the nozzle check's cure", cure.map { _ in () })] {
                XCTAssertThrowsError(try r.get(), "★ \(name): said stopped") { XCTAssertTrue($0 is CancellationError, "\(name): \($0)") }
            }
        }
        // the stop is the newer lay's alone: once it lays, the maps read whole again
        LatticeLayoutSession.controlStoppedMapReadsEmpty = false
        _ = try await main.lay(s)
        let after = try await LatticeLayoutPreview.unheldReport(main, Self.box)
        XCTAssertEqual(after?.share, whole?.share, "the next lay's map, whole")
    }

    /// ★ Through the page: "Check a 0.2 mm nozzle" from the solid pop-up, and a setting changed at once — the newer lay stops the
    /// check's map. No answer comes for that check (it goes back to "not asked"); once the newer lattice lands the check runs
    /// again of it, and its ONE answer comes then, in the pop-up. (The last lattice's places search is made to hold the worker,
    /// so the check's map is surely asked before the newer lay and runs after its stop: what a fraction of a second does on
    /// his iPad.) RED CONTROL: the interrupted check answers "would not lattice much more" before the newer lattice lands.
    @MainActor
    func testANozzleCheckANewerLayInterruptsIsNeverAnAnswer() async throws {
        FlexibleSaid.recording = true
        defer { FlexibleSaid.recording = false; AppPopups.shared.current = nil }
        for red in [false, true] {
            let what = red ? "RED CONTROL" : "★"
            let plate = try Notes30PlacesGiveWayTests.flatPlate(self)
            let p = try Notes30PlacesGiveWayTests.plateProject(plate)
            let preview = LatticeLayoutPreview()
            defer { preview.clear() }
            func answers() -> [AppPopup] { AppPopups.recorded.filter { $0.text.contains("A 0.2 mm nozzle would") } }
            func land(_ cellMM: Double) async throws {
                let before = preview.bars?.token
                p.lattice.cellMM = cellMM
                preview.update(project: p, on: true, live: true)
                try await until(300) { !preview.laying && preview.bars?.token != before }
            }
            func until(_ s: Double, _ ok: () -> Bool) async throws {
                let end = Date().addingTimeInterval(s)
                while !ok(), Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
            }

            // a lattice, and a whole check of it (it opens the check's own session; its answer comes, in the pop-up)
            var asked = LatticeLayoutSession.placesAsked
            try await land(6)
            try await until(300) { LatticeLayoutSession.placesAsked > asked && preview.placesMS > 0 }
            AppPopups.recorded = []
            preview.checkNozzleFromPopUp()
            try await until(600) { preview.nozzleState == .done }
            XCTAssertEqual(answers().count, 1, "\(what): premise: a whole check answers, in the pop-up")
            AppPopups.shared.current = nil

            // the next lattice; while its places search holds the worker, the check from the pop-up, then a setting changed
            LatticeLayoutSession.controlPlacesHoldTheWorker = true
            asked = LatticeLayoutSession.placesAsked
            try await land(7)
            try await until(300) { LatticeLayoutSession.placesAsked > asked }
            LatticeLayoutSession.controlStoppedMapReadsEmpty = red
            LatticeLayoutPreview.controlNozzleAnswersWhenInterrupted = red
            let runs = LatticeLayoutPreview.nozzleChecksRun, before = answers().count
            var states: [LatticeLayoutPreview.NozzleState] = []
            let sub = preview.$nozzleState.dropFirst().sink { states.append($0) }
            defer { sub.cancel() }
            preview.checkNozzleFromPopUp()
            try await Task.sleep(nanoseconds: 200_000_000)   // its map asked, behind the search
            XCTAssertEqual(preview.nozzleState, .checking, "\(what): premise: checking")
            let shown = preview.bars?.token
            p.lattice.cellMM = 6
            asked = LatticeLayoutSession.placesAsked
            preview.update(project: p, on: true, live: true)   // the newer lay: its stop is set before the check's map runs
            LatticeLayoutSession.controlPlacesHoldTheWorker = false
            try await until(300) { !preview.laying && preview.bars?.token != shown }
            let atLanding = answers().count - before
            print("NOTES30-Q2 page \(what): answers before the newer lattice landed: \(atLanding)"
                  + (atLanding > 0 ? " (\(answers().last?.text.split(separator: "\n").last ?? ""))" : "") + "; states \(states)")
            if red {
                XCTAssertEqual(atLanding, 1, "RED CONTROL: the interrupted check answered")
                XCTAssertTrue(answers().last?.text.contains("would not lattice much more") ?? false,
                              "RED CONTROL: \"would not lattice much more\" — of a part nothing had checked")
                try await until(300) { LatticeLayoutSession.placesAsked > asked && preview.nozzleChecksRunSettled(runs + 1) }
                XCTAssertEqual(LatticeLayoutPreview.nozzleChecksRun, runs + 1, "RED CONTROL: never asked of the newer lattice")
                continue
            }
            XCTAssertEqual(atLanding, 0, "★ the interrupted check never answers")
            XCTAssertEqual(Array(states.prefix(2)), [.checking, .notAsked], "★ it went back to \"not asked\"")
            // the newer lattice landed: the check runs again of it, and answers once, in the pop-up he asked from
            try await until(600) { LatticeLayoutPreview.nozzleChecksRun == runs + 2 && preview.nozzleState == .done }
            print("NOTES30-Q2 page ★: checks \(LatticeLayoutPreview.nozzleChecksRun - runs), answers \(answers().count - before); "
                  + "states \(states)")
            XCTAssertEqual(LatticeLayoutPreview.nozzleChecksRun, runs + 2, "★ asked again of the newer lattice")
            XCTAssertEqual(preview.nozzleState, .done)
            XCTAssertEqual(answers().count - before, 1, "★ one answer: the newer lattice's")
            XCTAssertTrue(preview.isCurrent(project: p), "★ of the lattice on screen")
        }
    }
}

extension LatticeLayoutPreview {
    /// (The test's) no more checks than `runs` ran, and none is running.
    fileprivate func nozzleChecksRunSettled(_ runs: Int) -> Bool { Self.nozzleChecksRun == runs && nozzleState != .checking }
}
#endif
