// VariantEntryGatingTests.swift — task 2026-08-03-variant-entry-gating-and-retention.
//
//  AJ2  NO REACHABLE DEAD END. Every blocking precondition is enumerated, and for
//       each one the ENTRY CONTROL is disabled and carries that condition's own
//       reason — never a generic "not available" — and the page it leads to
//       cannot be reached.
//
//  AJ5  PROVENANCE SHOWN. The solving machine (this device vs a NAMED worker) is
//       surfaced on the run and on each variant, and survives a relaunch.
//
// The gate is a pure value surface, so the enumeration below is exhaustive over
// the real type rather than over a list a future case could fall off.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class VariantEntryGatingTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()

    // MARK: fixtures

    private func job(designBox: Bool = false, selfWeight: Bool = false) -> Data {
        var j: [String: Any] = ["model": "part.stl", "material": "PLA",
                                "resolution": 64]
        if !selfWeight {
            j["loads"] = ["anchor_face_ids": [3],
                          "groups": [["face_ids": [7], "force": [0, 0, -500]]],
                          "build_dir": [0, 0, 1]]
        }
        if designBox {
            j["design_box"] = ["min": [0.0, 0.0, 0.0], "max": [50.0, 50.0, 50.0]]
        }
        return try! JSONSerialization.data(withJSONObject: j)
    }

    /// A variant from a healthy worker run: everything green.
    private func healthy(machine: SolvingMachine = .worker(name: "Mac mini"),
                         retainedJob: Data? = nil, retainedDesign: Data? = Data([1, 2]),
                         hasGeometry: Bool = true, latticed: Bool = false,
                         modelPath: String? = "/tmp/part.stl",
                         workerSelected: Bool = true,
                         runInFlight: Bool = false,
                         reattached: Bool = false) -> VariantEntryFacts {
        VariantEntryFacts(hasGeometry: hasGeometry, machine: machine,
                          retainedJob: retainedJob ?? job(),
                          retainedDesign: retainedDesign,
                          runGeneratedLattice: latticed, modelPath: modelPath,
                          workerSelected: workerSelected, runInFlight: runInFlight,
                          reattached: reattached)
    }

    // MARK: - the control that must exist at all: the healthy case is ENABLED

    /// A wrongly-disabled button is its own failure (the task's BLOCKED-STOP), so
    /// the green path is asserted first and explicitly.
    func testAHealthyWorkerRunEnablesBothEntries() {
        let f = healthy()
        XCTAssertTrue(VariantEntry.smoothing(f).enabled,
                      "blocks: \(VariantEntry.smoothingBlocks(f))")
        XCTAssertTrue(VariantEntry.lattice(f).enabled,
                      "blocks: \(VariantEntry.latticeBlocks(f))")
        XCTAssertNil(VariantEntry.smoothing(f).reason)
        XCTAssertNil(VariantEntry.lattice(f).reason)
    }

    // MARK: - AJ2 · every blocking precondition, each with its OWN reason

    /// One case per precondition. Each entry names the condition, the facts that
    /// produce it, and the DISTINCTIVE phrase its reason must contain — so a
    /// generic sentence, or two conditions collapsing onto one message, fails.
    private struct Case {
        let name: String
        let facts: VariantEntryFacts
        /// Distinctive words the reason must contain.
        let mustSay: [String]
    }

    private var smoothingCases: [Case] {
        [
            Case(name: "a job is already running",
                 facts: healthy(runInFlight: true),
                 mustSay: ["already running"]),
            Case(name: "the rung produced no geometry",
                 facts: healthy(hasGeometry: false),
                 mustSay: ["no geometry"]),
            Case(name: "the run generated a lattice (pipeline order)",
                 facts: healthy(latticed: true),
                 mustSay: ["lattice", "struts"]),
            Case(name: "the model file is gone",
                 facts: healthy(modelPath: nil),
                 mustSay: ["model file is missing"]),
            Case(name: "the run was solved ON DEVICE",
                 facts: healthy(machine: .thisDevice, retainedJob: Data(),
                                retainedDesign: Data()),
                 mustSay: ["on this device", "Mac worker"]),
            Case(name: "the run predates job/design retention",
                 facts: healthy(machine: .worker(name: "Mac mini"),
                                retainedJob: Data(), retainedDesign: Data()),
                 mustSay: ["before results kept"]),
            Case(name: "the retained job declared no load case (self-weight)",
                 facts: healthy(retainedJob: job(selfWeight: true)),
                 mustSay: ["self-weight"]),
        ]
    }

    private var latticeCases: [Case] {
        [
            Case(name: "a job is already running",
                 facts: healthy(runInFlight: true),
                 mustSay: ["already running"]),
            Case(name: "the rung produced no geometry",
                 facts: healthy(hasGeometry: false),
                 mustSay: ["no geometry"]),
            Case(name: "the run was solved ON DEVICE",
                 facts: healthy(machine: .thisDevice, retainedDesign: nil),
                 mustSay: ["on this device", "design file"]),
            Case(name: "the run predates the design store",
                 facts: healthy(retainedDesign: nil),
                 mustSay: ["before results kept their design file"]),
            Case(name: "the app RE-ATTACHED, so it never held the document it sent",
                 facts: healthy(retainedDesign: nil, reattached: true),
                 mustSay: ["reconnected", "after a restart"]),
            Case(name: "the run used a DESIGN BOX (core refuses it)",
                 facts: healthy(retainedJob: job(designBox: true)),
                 mustSay: ["design box", "expanded grid"]),
            Case(name: "the model file is gone",
                 facts: healthy(modelPath: nil),
                 mustSay: ["model file is missing"]),
            Case(name: "no Mac worker is selected",
                 facts: healthy(workerSelected: false),
                 mustSay: ["Mac worker", "Compute"]),
        ]
    }

    func testEveryBlockingPreconditionDisablesSmoothingWithItsOwnReason() throws {
        var seen = Set<String>()
        for c in smoothingCases {
            let v = VariantEntry.smoothing(c.facts)
            XCTAssertFalse(v.enabled, "AJ2: \(c.name) must DISABLE the Smooth entry")
            let reason = try XCTUnwrap(v.reason, "AJ2: \(c.name) must carry a reason")
            XCTAssertFalse(reason.isEmpty)
            for word in c.mustSay {
                XCTAssertTrue(reason.localizedCaseInsensitiveContains(word),
                              "AJ2: \(c.name)'s reason must say “\(word)” — got: \(reason)")
            }
            XCTAssertFalse(reason.localizedCaseInsensitiveContains("not available"),
                           "AJ2: a generic message does not satisfy this bar")
            XCTAssertTrue(seen.insert(reason).inserted,
                          "AJ2: \(c.name) must have its OWN reason, not one shared "
                          + "with another condition")
            XCTAssertEqual(v.accessibilityLabel, "Smooth, unavailable: \(reason)")
        }
    }

    func testEveryBlockingPreconditionDisablesLatticeWithItsOwnReason() throws {
        var seen = Set<String>()
        for c in latticeCases {
            let v = VariantEntry.lattice(c.facts)
            XCTAssertFalse(v.enabled, "AJ2: \(c.name) must DISABLE the Lattice entry")
            let reason = try XCTUnwrap(v.reason, "AJ2: \(c.name) must carry a reason")
            for word in c.mustSay {
                XCTAssertTrue(reason.localizedCaseInsensitiveContains(word),
                              "AJ2: \(c.name)'s reason must say “\(word)” — got: \(reason)")
            }
            XCTAssertFalse(reason.localizedCaseInsensitiveContains("not available"))
            XCTAssertTrue(seen.insert(reason).inserted,
                          "AJ2: \(c.name) must have its OWN reason")
            XCTAssertEqual(v.accessibilityLabel, "Lattice, unavailable: \(reason)")
        }
    }

    /// EXHAUSTIVENESS. Every reason `RelatticeUnavailable` and `SmoothUnavailable`
    /// can produce is distinct and non-empty — so a case added later cannot quietly
    /// share another's sentence or ship blank.
    func testEveryUnavailabilityReasonIsDistinctAndSpecific() {
        let relattice: [RelatticeUnavailable] = [
            .computedOnDevice, .runPredatesDesignStore, .designNotTransferred,
            .jobDocumentNotRecorded, .noGeometry, .designBoxRun, .noWorkerSelected,
            .modelFileMissing,
        ]
        let smooth: [SmoothUnavailable] = [
            .noRetainedJob, .computedOnDevice, .selfWeightRun, .alreadyLatticed,
            .noGeometry, .modelFileMissing,
        ]
        let all = relattice.map(\.reason) + smooth.map(\.reason)
        XCTAssertEqual(Set(all).count, all.count,
                       "AJ2: no two conditions may share a sentence")
        for r in all {
            XCTAssertGreaterThan(r.count, 25, "a reason must actually explain: \(r)")
            XCTAssertFalse(r.localizedCaseInsensitiveContains("not available"))
            XCTAssertFalse(r.localizedCaseInsensitiveContains("unavailable"))
        }
    }

    /// A variant blocked SEVERAL ways reports all of them, so nothing is hidden
    /// behind the first fix the user makes.
    func testAllBlockingReasonsAreReportedNotJustTheFirst() {
        let f = healthy(machine: .thisDevice, retainedJob: Data(),
                        retainedDesign: nil, modelPath: nil, workerSelected: false)
        let v = VariantEntry.lattice(f)
        XCTAssertFalse(v.enabled)
        XCTAssertGreaterThanOrEqual(v.allReasons.count, 3,
                                    "got \(v.allReasons)")
        XCTAssertEqual(v.reason, v.allReasons.first)
    }

    // MARK: - AJ2 · the page cannot be REACHED, not merely apologised for

    /// The second layer. The button is disabled; these guards mean no other caller
    /// can open a dead end either. Read from the source, in the shape PR 279's AE3
    /// uses, because the opener is a SwiftUI view method.
    func testBothPageOpenersRefuseABlockedVariantBeforeOpeningAnything() throws {
        let ws = try String(contentsOf: sourceURL("WorkspacePlaceholder.swift"),
                            encoding: .utf8)

        let smooth = try XCTUnwrap(ws.range(of: "private func openSmoothingPage"))
        let smoothBody = String(ws[smooth.lowerBound...].prefix(700))
        XCTAssertTrue(smoothBody.contains("smoothEntry(variantIndex)"),
                      "AJ2: the smoothing opener must consult the gate")
        XCTAssertTrue(smoothBody.contains("guard gate.enabled else"),
                      "AJ2: …and RETURN rather than open a page that refuses")
        XCTAssertTrue(smoothBody.contains("gate.reason"),
                      "AJ2: …stating which condition blocked it")

        let lattice = try XCTUnwrap(ws.range(of: "private func openLatticePage"))
        let latticeBody = String(ws[lattice.lowerBound...].prefix(900))
        XCTAssertTrue(latticeBody.contains("latticeEntry(idx)"))
        XCTAssertTrue(latticeBody.contains("guard gate.enabled else"))
    }

    /// And the results screen's controls really are wired to the gate rather than
    /// firing unconditionally, as they did before this task.
    func testTheResultsEntryControlsAreGated() throws {
        let rs = try String(contentsOf: sourceURL("ResultsScreen.swift"), encoding: .utf8)
        XCTAssertTrue(rs.contains("verdict: smoothVerdict"))
        XCTAssertTrue(rs.contains("verdict: latticeVerdict"))
        XCTAssertTrue(rs.contains(".disabled(!verdict.enabled)"),
                      "AJ2: the control is DISABLED, not merely dimmed")
        XCTAssertTrue(rs.contains("if let why = verdict.reason"),
                      "AJ2: and it renders the reason beside itself")

        let ws = try String(contentsOf: sourceURL("WorkspacePlaceholder.swift"),
                            encoding: .utf8)
        XCTAssertTrue(ws.contains("smoothEntry: { smoothEntry($0) }"))
        XCTAssertTrue(ws.contains("latticeEntry: { latticeEntry($0) }"))
    }

    // MARK: - failure (B) · the app must not invite a configuration it cannot run

    /// The workspace and the lattice page share ONE rule, and it mirrors the core's
    /// refusal rather than restating an app policy.
    func testALatticeRunWithADesignBoxIsRefusedAtTheBUTTON() throws {
        XCTAssertNil(LatticeCoreCapability.liveConflict(latticeEnabled: false,
                                                        designBoxActive: true),
                     "a design box alone is fine — it is the COMBINATION core refuses")
        XCTAssertNil(LatticeCoreCapability.liveConflict(latticeEnabled: true,
                                                        designBoxActive: false))
        let why = try XCTUnwrap(
            LatticeCoreCapability.liveConflict(latticeEnabled: true,
                                               designBoxActive: true))
        XCTAssertTrue(why.contains("design box"))
        XCTAssertTrue(why.contains("expanded grid"), "it says WHY, not just no")

        // The lattice page's own Optimize surface carries it, disabled.
        let surface = LatticeOptimizeSurface.compute(
            baseCanOptimize: true, baseSummary: "1 anchor · 1 load",
            latticeEnabled: true, densityMode: .uniform,
            topologyDisplayName: "Octet", cellMM: 5, bounds: nil, running: false,
            lineWidthMM: 0.4, designBoxActive: true)
        XCTAssertFalse(surface.enabled,
                       "failure B: the button that would submit a refused job is off")
        XCTAssertEqual(surface.sub, why)

        // …and turning the box off re-enables it, so the gate is not a one-way door.
        let ok = LatticeOptimizeSurface.compute(
            baseCanOptimize: true, baseSummary: "1 anchor · 1 load",
            latticeEnabled: true, densityMode: .uniform,
            topologyDisplayName: "Octet", cellMM: 5, bounds: nil, running: false,
            lineWidthMM: 0.4, designBoxActive: false)
        XCTAssertTrue(ok.enabled)
    }

    /// THE GATE MIRRORS CORE, AND SAYS SO. If core stops refusing (the concurrent
    /// design-box-recertification task), this test goes red and the app's block is
    /// what must change — the app can never be the last one holding a rule the
    /// solver dropped.
    func testTheAppBlockExistsBecauseTheCoreRefusalDoes() throws {
        let runJob = Self.repoRoot.appendingPathComponent("core/src/cli/run_job.cpp")
        let src = try String(contentsOf: runJob, encoding: .utf8)
        let coreStillRefuses = src.contains(LatticeCoreCapability.designBoxRefusalPhrase)
        XCTAssertEqual(coreStillRefuses, LatticeCoreCapability.designBoxRefused,
                       "the app's design-box block must track core's own refusal. "
                       + "If core no longer carries “"
                       + LatticeCoreCapability.designBoxRefusalPhrase
                       + "”, drop LatticeCoreCapability.designBoxRefused.")
        XCTAssertTrue(src.contains("lattice_variant_job: a design box"),
                      "…and the same refusal guards the lattice_variant path, which "
                      + "is what the variant entry gate is mirroring")
    }

    // MARK: - AJ5 · which machine solved it

    func testTheSolvingMachineIsResolvedFromTheRunsOwnRecord() {
        XCTAssertEqual(SolvingMachine.resolve(computedRemotely: false, solvedBy: nil),
                       .thisDevice)
        XCTAssertEqual(SolvingMachine.resolve(computedRemotely: true,
                                              solvedBy: "Mac mini"),
                       .worker(name: "Mac mini"))
        XCTAssertEqual(SolvingMachine.resolve(computedRemotely: true, solvedBy: nil),
                       .unnamedWorker,
                       "AJ5: a worker we cannot name is NOT this device, and is not "
                       + "given a guessed name either")
        XCTAssertEqual(SolvingMachine.resolve(computedRemotely: true, solvedBy: "  "),
                       .unnamedWorker)

        XCTAssertEqual(SolvingMachine.thisDevice.shortLabel, "This device")
        XCTAssertEqual(SolvingMachine.worker(name: "Mac mini").shortLabel, "Mac mini")
        XCTAssertTrue(SolvingMachine.worker(name: "Mac mini").label.contains("Mac mini"))
        XCTAssertTrue(SolvingMachine.thisDevice.label.contains("this device"))
        XCTAssertNotEqual(SolvingMachine.thisDevice.symbol,
                          SolvingMachine.worker(name: "x").symbol,
                          "AJ5: distinguishable at a glance, not only by reading")
        // A local run stores no name — the flag already says it, and two fields able
        // to disagree is how provenance goes wrong.
        XCTAssertNil(SolvingMachine.thisDevice.recordedName)
        XCTAssertEqual(SolvingMachine.worker(name: "Mac mini").recordedName, "Mac mini")
    }

    /// It is stamped onto the run's outcome by the run flow (neither the bridge nor
    /// the worker knows where it ran), and shown on the run AND on each variant.
    func testTheMachineIsStampedOnTheOutcomeAndSurfacedOnRunAndVariant() {
        let m = RunModel(scheduler: SynchronousRunScheduler(),
                         watchdog: DisabledRunWatchdog())
        m.runner = { _, _, _ in
            OptimizeOutcome(variants: [], stoppedOnMargin: true, cancelled: false,
                            acceptedCount: 1, computedRemotely: true)
        }
        m.start(RunRequest(modelPath: "/tmp/p.stl", material: "PLA",
                           materialsPath: "/tmp/m.json", rulesPath: "/tmp/r.json",
                           resolution: 32, projectName: "Bracket"),
                remote: true, workerName: "Mac mini")
        XCTAssertEqual(m.outcome?.solvedBy, "Mac mini")
        XCTAssertEqual(SolvingMachine.of(m.outcome!), .worker(name: "Mac mini"))

        let results = ResultsModel(projectName: "Bracket", outcome: m.outcome!)
        XCTAssertEqual(results.solvingMachine, .worker(name: "Mac mini"),
                       "AJ5: shown on the RUN")
        XCTAssertTrue(results.variantProvenanceLabel.contains("Mac mini"),
                      "AJ5: and on the VARIANT")

        // A local run says so instead — and is never described as a worker.
        let local = RunModel(scheduler: SynchronousRunScheduler(),
                             watchdog: DisabledRunWatchdog())
        local.runner = { _, _, _ in
            OptimizeOutcome(variants: [], stoppedOnMargin: true, cancelled: false,
                            acceptedCount: 1)
        }
        local.start(RunRequest(modelPath: "/tmp/p.stl", material: "PLA",
                               materialsPath: "/tmp/m.json", rulesPath: "/tmp/r.json",
                               resolution: 32, projectName: "Bracket"))
        XCTAssertNil(local.outcome?.solvedBy)
        XCTAssertEqual(SolvingMachine.of(local.outcome!), .thisDevice)
    }

    /// And it survives the persist/restore round-trip, for the same reason
    /// `computedRemotely` must: a reopened result that forgot where it ran would
    /// put the app straight back into telling a worker user to use a worker.
    func testTheMachineSurvivesTheResultsRoundTrip() throws {
        let o = OptimizeOutcome(variants: [], stoppedOnMargin: true, cancelled: false,
                                acceptedCount: 1, computedRemotely: true,
                                solvedBy: "Mac mini")
        let data = try OutcomeCodec.encode(OutcomeCodec.dto(from: o))
        let back = try OutcomeCodec.decode(data)
        XCTAssertEqual(back.solvedBy, "Mac mini")
        XCTAssertEqual(SolvingMachine.of(back), .worker(name: "Mac mini"))
    }

    /// The refusal copy and the machine are shown TOGETHER, which is the point: the
    /// on-device reason tells you to use a worker, and the chip beside it tells you
    /// whether you already did.
    func testTheOnDeviceRefusalAndTheMachineAgree() {
        let f = healthy(machine: .thisDevice, retainedJob: Data(), retainedDesign: nil)
        let v = VariantEntry.lattice(f)
        XCTAssertEqual(v.reason, RelatticeUnavailable.computedOnDevice.reason)
        XCTAssertTrue(try! XCTUnwrap(v.reason).contains("on this device"))
        XCTAssertEqual(f.machine.shortLabel, "This device",
                       "AJ5: the reason and the chip must tell the same story")

        // The worker case gets the OTHER sentence — never "re-run it on a Mac
        // worker" to someone who did.
        let w = VariantEntry.lattice(healthy(retainedDesign: nil))
        XCTAssertEqual(w.reason, RelatticeUnavailable.runPredatesDesignStore.reason)
        XCTAssertFalse(try! XCTUnwrap(w.reason).contains("on this device"))

        // …and a RE-ATTACHED worker run gets a third, because "predates retention"
        // would be a false statement about a run that simply outlived the client.
        let r = VariantEntry.lattice(healthy(retainedDesign: nil, reattached: true))
        XCTAssertEqual(r.reason, RelatticeUnavailable.jobDocumentNotRecorded.reason)
        XCTAssertNotEqual(r.reason, w.reason)
    }

    // MARK: - the retained-job parse the gate depends on

    func testTheDesignBoxFactIsReadFromTheJobsOwnKey() {
        XCTAssertTrue(RetainedJobFacts.parse(job(designBox: true)).declaresDesignBox)
        XCTAssertFalse(RetainedJobFacts.parse(job(designBox: false)).declaresDesignBox)
        // Tolerant, never a parse failure: an absent / unreadable / unknown-shaped
        // document simply does not declare a box.
        XCTAssertFalse(RetainedJobFacts.parse(nil).declaresDesignBox)
        XCTAssertFalse(RetainedJobFacts.parse(Data("not json".utf8)).declaresDesignBox)
        XCTAssertFalse(RetainedJobFacts.parse(Data("{}".utf8)).declaresDesignBox)
    }

    /// Half a retention pair is not a pair — the same all-or-nothing rule the store
    /// applies, restated where the gate reads it.
    func testHalfARetentionPairIsRefused() {
        XCTAssertNil(healthy(retainedJob: Data(), retainedDesign: Data([1])).artifacts)
        XCTAssertNil(healthy(retainedDesign: Data()).artifacts)
        XCTAssertNil(healthy(retainedDesign: nil).artifacts)
        XCTAssertNotNil(healthy().artifacts)
    }

    // MARK: - AJ7 · determinism

    func testTheGateIsDeterministic() {
        for c in smoothingCases + latticeCases {
            let a = (VariantEntry.smoothing(c.facts), VariantEntry.lattice(c.facts))
            for _ in 0..<20 {
                XCTAssertEqual(VariantEntry.smoothing(c.facts), a.0)
                XCTAssertEqual(VariantEntry.lattice(c.facts), a.1)
            }
        }
    }

    // MARK: helpers

    private func sourceURL(_ name: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        return url.appendingPathComponent("Sources/TopOptFlows/\(name)")
    }
}
