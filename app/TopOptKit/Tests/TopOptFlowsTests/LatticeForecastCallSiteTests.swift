// LatticeForecastCallSiteTests — THE FORECAST IS ACTUALLY INVOKED, AND WHAT IT
// SHOWS DESCRIBES THE CURRENT SETTINGS (task 2026-08-03-variant-postprocessing-fix,
// bar F3, review blocker 1).
//
// WHY THIS FILE EXISTS. Bar F3's first cut had every layer — core computed the
// forecast, the worker served it, RelatticeRun drove it, LatticeForecast parsed it,
// the action row rendered it — and NO CALL SITE. The handoff read "shipped"; the
// user saw nothing. It is the same shape as PR 284 (retention built, never called)
// and PR 289 (31 tests against a path the maintainer could not reach), and
// LatticeForecastTests could not catch it: every one of those tests calls the
// parser or the copy DIRECTLY, which is exactly what production did not do.
//
// So these tests drive `LatticeForecastModel` — the type the page's `.task(id:)`
// calls — and assert the invocation itself: that asking produces a request, that
// re-asking the same question does not, that a moved question cancels the old
// answer, and that an answer is never displayed against settings it does not
// describe.

import XCTest
@testable import TopOptFlows

@MainActor
final class LatticeForecastCallSiteTests: XCTestCase {

    private static let evidence: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("evidence/2026-08-03-variant-postprocessing-fix")
    }()

    private func forecast(_ name: String) throws -> LatticeForecast {
        let url = Self.evidence.appendingPathComponent("f3_forecast_\(name).json")
        return try XCTUnwrap(LatticeForecast.parse(try Data(contentsOf: url)))
    }

    private let jobA = Data(#"{"lattice":{"cell_mm":4}}"#.utf8)
    private let jobB = Data(#"{"lattice":{"cell_mm":2}}"#.utf8)

    /// Wait for the model to leave `.running`, so a test never races the Task the
    /// call site spawns. Fails rather than hanging.
    private func settle(_ m: LatticeForecastModel,
                        file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if case .running = m.state {
                try? await Task.sleep(nanoseconds: 5_000_000)
                continue
            }
            return
        }
        XCTFail("the forecast never settled", file: file, line: line)
    }

    // MARK: - the invocation

    func testAskingForAForecastActuallyRunsIt() async throws {
        let m = LatticeForecastModel()
        let d = try forecast("D_fixed2mm")
        XCTAssertEqual(m.state, .idle, "nothing is forecast until something asks")

        let calls = Counter()
        m.request(jobA, debounceNanoseconds: 0) { _ in await calls.bump(); return d }
        await settle(m)

        let got = await calls.value
        XCTAssertEqual(got, 1, "F3: the driver is INVOKED — the whole defect was that "
                       + "every layer existed and nothing called it")
        XCTAssertEqual(m.forecast(for: jobA), d,
                       "…and the answer reaches the surface that renders it")
    }

    func testTheSameConfigurationIsNotSubmittedTwice() async throws {
        let m = LatticeForecastModel()
        let d = try forecast("D_fixed2mm")
        let calls = Counter()
        let drive: @Sendable (Data) async throws -> LatticeForecast = { _ in
            await calls.bump(); return d
        }
        m.request(jobA, debounceNanoseconds: 0, drive: drive)
        await settle(m)
        // A SwiftUI body re-evaluation re-asks the same question. The worker runs
        // one job at a time; re-submitting on every frame would queue behind the
        // user's own run.
        m.request(jobA, debounceNanoseconds: 0, drive: drive)
        m.request(jobA, debounceNanoseconds: 0, drive: drive)
        await settle(m)
        let got = await calls.value
        XCTAssertEqual(got, 1, "re-asking an answered question must be free")
    }

    // MARK: - staleness (the same hard rule as everywhere else)

    func testAnAnswerIsNeverShownAgainstADifferentConfiguration() async throws {
        let m = LatticeForecastModel()
        let d = try forecast("D_fixed2mm")
        m.request(jobA, debounceNanoseconds: 0) { _ in d }
        await settle(m)
        XCTAssertNotNil(m.forecast(for: jobA))
        // The user changed the cell size. The answer on screen is about the
        // configuration they just left; showing it would be a prediction about a
        // job nobody is going to run.
        XCTAssertNil(m.forecast(for: jobB),
                     "a forecast for other settings is NOT a forecast for these")
        let panel = LatticeForecastPanel.compute(state: m.state,
                                                 describesCurrentJob: false)
        XCTAssertNil(panel.headline,
                     "and the drawer must not render the stale numbers either")
        XCTAssertNotNil(panel.placeholder)
    }

    func testMovingTheSettingsSupersedesTheAnswerInFlight() async throws {
        let m = LatticeForecastModel()
        let d = try forecast("D_fixed2mm")
        // A slow driver stands in for the round trip; the settings move while it
        // is still out.
        m.request(jobA, debounceNanoseconds: 0) { _ in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return d
        }
        let b = try forecast("B_auto_w010")
        m.request(jobB, debounceNanoseconds: 0) { _ in b }
        await settle(m)
        XCTAssertNil(m.forecast(for: jobA),
                     "the superseded answer must not land on the new question")
        XCTAssertNotNil(m.forecast(for: jobB))
    }

    func testClearingDropsEverything() async throws {
        let m = LatticeForecastModel()
        let d = try forecast("D_fixed2mm")
        m.request(jobA, debounceNanoseconds: 0) { _ in d }
        await settle(m)
        m.clear()
        XCTAssertEqual(m.state, .idle)
        XCTAssertNil(m.forecast(for: jobA))
        // Nothing to forecast (page closed, no variant, no worker) is the same as
        // never having asked — not a spinner that never resolves.
        m.request(nil, debounceNanoseconds: 0) { _ in d }
        XCTAssertEqual(m.state, .idle)
    }

    // MARK: - the failure is said out loud

    func testAForecastThatCannotBeProducedSaysSo() async throws {
        struct NoWorker: Error, CustomStringConvertible {
            var description: String { "the worker did not answer" }
        }
        let m = LatticeForecastModel()
        m.request(jobA, debounceNanoseconds: 0) { _ in throw NoWorker() }
        await settle(m)
        XCTAssertNil(m.forecast(for: jobA))
        let why = try XCTUnwrap(m.failure(for: jobA))
        XCTAssertTrue(why.contains("did not answer"), why)
        let panel = LatticeForecastPanel.compute(state: m.state,
                                                 describesCurrentJob: true)
        XCTAssertTrue(panel.warn)
        let placeholder = try XCTUnwrap(panel.placeholder)
        XCTAssertTrue(placeholder.contains("did not answer"), placeholder)
        XCTAssertTrue(placeholder.contains("afterwards"),
                      "the user is told the run will still tell them — silently "
                      + "showing nothing is what this whole task exists to end")
    }

    // MARK: - the drawer carries the WHOLE answer, not one truncated line

    func testTheDrawerCarriesEveryReasonAndEveryMeasuredRemedy() throws {
        let f = try forecast("A_auto_w042")
        let panel = LatticeForecastPanel.compute(state: .ready(f),
                                                 describesCurrentJob: true)
        XCTAssertNil(panel.placeholder)
        XCTAssertEqual(panel.headline, f.headline)
        XCTAssertEqual(panel.reasons, f.reasonLines)
        XCTAssertEqual(panel.advice, f.adviceLines())
        XCTAssertTrue(panel.warn, "A_auto_w042 latticees nothing — it is a warning")
        XCTAssertFalse(panel.reasons.isEmpty,
                       "the per-reason counts are the part the button cannot fit")
    }

    func testAHealthyConfigurationIsNotDressedAsAWarning() throws {
        let f = try forecast("B_auto_w010")
        let panel = LatticeForecastPanel.compute(state: .ready(f),
                                                 describesCurrentJob: true)
        XCTAssertFalse(panel.warn)
        XCTAssertEqual(panel.headline, f.headline)
    }
}

/// A Sendable call counter — the driver runs off the main actor.
private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
