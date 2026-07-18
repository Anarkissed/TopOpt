// Headless regression tests for handoff 089 — "a completed variant does not appear
// until you leave the project and re-enter".
//
// These are the only tests in the package that HOST SwiftUI (NSHostingView in a
// window, with the runloop pumped by hand). That is deliberate: the bug was not in
// any model — every model here published correctly — it was in how the view graph
// latched the streamed state. A model-level test cannot see it; hosting the REAL
// ResultsScreen can, and does (both tests below fail against the pre-089 code).
//
// The screen owns its ResultsModel as a @StateObject, so the tests inject one
// (`resultsModel:`) and assert on the tabs the screen would actually draw.

import XCTest
import SwiftUI
import Combine
import TopOptKit
@testable import TopOptFlows
#if canImport(AppKit)
import AppKit
#endif

// This suite HOSTS the real SwiftUI ResultsScreen in an AppKit window, so it is
// macOS-only (the M7 test standard runs on `-destination platform=macOS`). Guarded
// so the same test target also COMPILES for an iOS-simulator destination — needed
// by the handoff-097 RemoteRunner E2E, which must run on the simulator (097).
#if canImport(AppKit)
@MainActor
final class StreamedVariantVisibilityTests: XCTestCase {

    // MARK: - fixtures

    private func variant(fraction: Double, margin: Double) -> OptimizeVariant {
        OptimizeVariant(requestedVolumeFraction: fraction, achievedVolumeFraction: fraction,
                        massGrams: 100 * fraction, supportVolumeVoxels: 0,
                        meshTriangleCount: 100, worstCaseMargin: margin, accepted: true,
                        v3Passes: true, minFeatureViolations: 0, minFeatureWarning: "")
    }

    private func partial(_ v: OptimizeVariant) -> OptimizeOutcome {
        OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false,
                        acceptedCount: 1, gridNx: 4, gridNy: 4, gridNz: 4, spacing: 1)
    }

    private func request() -> RunRequest {
        RunRequest(modelPath: "/x/part.stl", material: "PLA", materialsPath: "",
                   rulesPath: "", resolution: 64, projectName: "Bracket")
    }

    /// The workspace's results gate, reduced to what these tests exercise: a view
    /// OBSERVING the project, handing the run's growing outcome to the real screen.
    /// Mirrors `WorkspacePlaceholder` (which observes the project, not the run, and
    /// re-creates the ResultsScreen value on each pass).
    private struct Harness: View {
        @ObservedObject var project: ProjectModel
        let resultsModel: ResultsModel

        var body: some View {
            ZStack {
                if let outcome = project.run.outcome,
                   outcome.variants.contains(where: { $0.accepted }) {
                    ResultsScreen(projectName: project.name, outcome: outcome,
                                  materialName: project.material,
                                  streaming: project.run.isStreaming,
                                  run: project.run, runResolution: 64,
                                  runMaterialName: project.material,
                                  resultsModel: resultsModel)
                }
            }
        }
    }

    /// Host `Harness` in a window and return a `pump` that lets SwiftUI run a full
    /// update pass (and the main queue drain the run's `runOnMain` hops).
    private func host(_ project: ProjectModel, _ resultsModel: ResultsModel) -> () -> Void {
        let hosting = NSHostingView(rootView: Harness(project: project, resultsModel: resultsModel))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        return {
            for _ in 0..<10 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                hosting.layoutSubtreeIfNeeded()
                hosting.displayIfNeeded()
            }
        }
    }

    private func makeProject(_ run: RunModel) -> ProjectModel {
        ProjectModel(id: UUID(), name: "Bracket", material: "PLA", process: .fdm,
                     importedFile: nil, importedMesh: nil, run: run)
    }

    // MARK: - the bug

    /// STEP 3. A second accepted variant streams into a LIVE RunModel behind an
    /// already-visible results screen: it must appear as a tab THERE AND THEN, with
    /// no navigation away and back (which is what used to be required — leaving and
    /// reopening rebuilds the ResultsModel from the current outcome, which is why the
    /// variant was there all along).
    ///
    /// Pre-089 this failed with `tabs.count == 1`: `.onChange(of:)` ran the action
    /// closure captured by the PREVIOUS body evaluation, so `model.update(from:
    /// liveOutcome)` re-applied the one-variant outcome the screen already had. The
    /// screen sat permanently one variant behind the run.
    func testSecondStreamedVariantAppearsWithoutLeavingTheProject() throws {
        let run = RunModel(scheduler: GCDRunScheduler(), watchdog: DisabledRunWatchdog())
        let project = makeProject(run)
        let v1 = partial(variant(fraction: 0.70, margin: 3.0))
        let v2 = partial(variant(fraction: 0.55, margin: 2.0))
        // Seeded with v1, exactly as production builds the model when the screen first
        // appears (the first streamed variant is what makes the results visible).
        let resultsModel = ResultsModel(projectName: "Bracket", outcome: v1)
        let pump = host(project, resultsModel)
        pump()

        let afterFirst = DispatchSemaphore(value: 0)
        let afterSecond = DispatchSemaphore(value: 0)
        run.runner = { _, progress, onVariant in
            _ = progress(0, 3, 12)
            onVariant(v1)                      // rung 1 lands → results become visible
            afterFirst.wait()
            _ = progress(1, 3, 9)
            onVariant(v2)                      // rung 2 lands → must show immediately
            afterSecond.wait()
            return OptimizeOutcome(variants: [], stoppedOnMargin: false, cancelled: true,
                                   acceptedCount: 0)
        }
        run.start(request())
        pump()
        XCTAssertEqual(run.outcome?.variants.count, 1)
        XCTAssertEqual(resultsModel.tabs.count, 1, "the first variant shows as one tab")

        afterFirst.signal()
        pump()
        XCTAssertEqual(run.outcome?.variants.count, 2, "the run holds both variants")
        XCTAssertEqual(resultsModel.tabs.count, 2,
                       "a streamed variant must appear when it LANDS — not only after "
                     + "leaving the project and re-entering rebuilds the screen")
        XCTAssertEqual(resultsModel.tabs.last?.isRecommended, true,
                       "the newly arrived lighter variant becomes the recommendation")

        afterSecond.signal()
        pump()
    }

    /// GUARD (089). The honest ETA must produce a NUMBER once a rung has completed —
    /// the maintainer watched "Est. remaining: estimating…" for 1h21m with variants
    /// already done. Drives real progress payloads through a live run behind the
    /// hosted screen; the readout must see the rung advance.
    ///
    /// Pre-089 this failed (`remainingEstimate == nil`): the readout latched the last
    /// non-nil progress into view-local @State, and `appendStreamed` cleared
    /// `RunModel.progress` — so when a tick and the append landed in ONE runloop turn
    /// (as they do here, and as they do on device whenever the main thread is busy
    /// long enough to batch them) SwiftUI only ever observed nil → nil, the latch
    /// never took, and `remainingEstimate` never saw a completed rung.
    func testETAResolvesToANumberOnceARungHasCompleted() throws {
        let run = RunModel(scheduler: GCDRunScheduler(), watchdog: DisabledRunWatchdog())
        let project = makeProject(run)
        let v1 = partial(variant(fraction: 0.70, margin: 3.0))
        let resultsModel = ResultsModel(projectName: "Bracket", outcome: v1)
        let pump = host(project, resultsModel)
        pump()

        let done = DispatchSemaphore(value: 0)
        let v2 = partial(variant(fraction: 0.55, margin: 2.0))
        run.runner = { _, progress, onVariant in
            // Two rungs run and both variants land — the LAST thing to reach the main
            // thread is a streamed variant, which is the ordinary case (a rung ends
            // with its variant, and the next rung's first tick is a whole FEA solve
            // away). Pre-089 that append erased `progress`, so the readout had nothing
            // left to read but its default rung-0 snapshot.
            _ = progress(0, 3, 40)
            onVariant(v1)                      // rung 0 done
            _ = progress(1, 3, 4)              // rung 1 alive: ONE rung is complete
            onVariant(v2)                      // rung 1 done → progress cleared pre-089
            done.wait()
            return OptimizeOutcome(variants: [], stoppedOnMargin: false, cancelled: true,
                                   acceptedCount: 0)
        }
        run.start(request())
        pump()

        // This is exactly what RunProgressReadout.snapshot now reads — no view-local
        // latch stands between the model and the ETA.
        let progress = try XCTUnwrap(run.progress,
                                     "the run's last snapshot must SURVIVE a streamed variant — "
                                   + "erasing it is what left the readout at \"estimating…\"")
        XCTAssertEqual(progress.rung, 1, "the readout reads the completed-rung count off the model")
        let eta = progress.remainingEstimate(elapsed: 4860, currentRungElapsed: 600)
        XCTAssertEqual(try XCTUnwrap(eta, "with a rung completed the ETA is a number, not \"estimating…\""),
                       4260 + 3660, accuracy: 1)

        done.signal()
        pump()
    }

    /// GUARD (089 keeps 088's fix). Not cancelling on Back is what keeps an in-flight
    /// ladder alive; the streamed variants must still survive it.
    func testStreamedVariantsStillSurviveLeavingAnInFlightRun() {
        let run = RunModel(scheduler: SynchronousRunScheduler(), watchdog: DisabledRunWatchdog())
        let v1 = partial(variant(fraction: 0.70, margin: 3.0))
        run.runner = { _, progress, onVariant in
            onVariant(v1)
            run.cancel()                        // the Back chevron's predecessor did this
            let keepGoing = progress(0, 3, 2)
            return OptimizeOutcome(variants: [], stoppedOnMargin: false,
                                   cancelled: !keepGoing, acceptedCount: 0)
        }
        run.start(request())
        XCTAssertEqual(run.outcome?.variants.count, 1)
        XCTAssertEqual(run.phase, .succeeded)
    }
}
#endif  // canImport(AppKit)
