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

    /// A REAL v1 `design.bin` (core's `design_store.hpp` layout) holding one block
    /// per requested volume fraction, with a one-voxel density field. Written here
    /// rather than stubbed so the gate's index reader is exercised against the
    /// actual format — a hand-waved blob would prove nothing about either.
    private func designContainer(holding fractions: [Double]) -> Data {
        var d = Data()
        func u8(_ v: UInt8) { d.append(v) }
        func pad(_ n: Int) { d.append(contentsOf: [UInt8](repeating: 0, count: n)) }
        func i32(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func i64(_ v: Int64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        u8(1); pad(3)                       // version + reserved
        i32(1); i32(1); i32(1)              // nx, ny, nz
        f64(0); f64(0); f64(0)              // origin
        f64(1)                              // spacing
        i32(Int32(fractions.count)); pad(4) // block count + reserved
        for vf in fractions {
            f64(vf); f64(vf)                // requested, achieved
            f64(2.0); f64(2.0); f64(1.0)    // margins + max stress
            i32(1); i32(10)                 // accepted, iterations
            f64(0); f64(0); f64(1)          // applied build dir
            i32(0); i32(0)                  // auto-applied, baked
            u64(0)                          // fingerprint
            i64(1); f64(0.5)                // density count + the one value
        }
        return d
    }

    /// A variant from a healthy worker run: everything green.
    private func healthy(machine: SolvingMachine = .worker(name: "Mac mini"),
                         retainedJob: Data? = nil, retainedDesign: Data? = Data([1, 2]),
                         hasGeometry: Bool = true, latticed: Bool = false,
                         modelPath: String? = "/tmp/part.stl",
                         workerSelected: Bool = true,
                         runInFlight: Bool = false,
                         reattached: Bool = false,
                         requestedVolumeFraction: Double = 0.5) -> VariantEntryFacts {
        VariantEntryFacts(hasGeometry: hasGeometry, machine: machine,
                          retainedJob: retainedJob ?? job(),
                          retainedDesign: retainedDesign,
                          runGeneratedLattice: latticed, modelPath: modelPath,
                          workerSelected: workerSelected, runInFlight: runInFlight,
                          reattached: reattached,
                          requestedVolumeFraction: requestedVolumeFraction)
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

    // MARK: - CONCURRENCY · a running ladder does not freeze what it already made
    //         (task 2026-08-03-variant-postprocessing-concurrency, requirements 2+4)

    /// THE REPLACEMENT FOR THE TWO ROWS REMOVED ABOVE, and a stronger claim than
    /// they made: a variant that has already streamed is FULLY usable while the
    /// ladder keeps solving later rungs.
    ///
    /// Smoothing is an ON-DEVICE computation — `SmoothingModel.live` →
    /// `TopOptKit.smoothAndRecertifyLoadCase` → `smooth_and_recertify_loadcase`
    /// (bridge.cpp) → `analyze_loadcase` → `topopt::analyze_fixed_design`
    /// (bridge.cpp:1297), all in-process. On the maintainer's setup that is a
    /// different computer from the worker entirely. And lattice SETUP is pure
    /// configuration. Neither has any claim on the Mac.
    func testAStreamedVariantIsFullyUsableWhileTheLadderIsStillRunning() {
        let mid = healthy(runInFlight: true)
        XCTAssertTrue(VariantEntry.smoothing(mid).enabled,
                      "smoothing runs on THIS device and must not wait for the "
                      + "Mac: \(VariantEntry.smoothingBlocks(mid))")
        XCTAssertTrue(VariantEntry.lattice(mid).enabled,
                      "lattice SETUP is zero compute and must not wait for the "
                      + "Mac: \(VariantEntry.latticeBlocks(mid))")
        XCTAssertNil(VariantEntry.smoothing(mid).reason)
        XCTAssertNil(VariantEntry.lattice(mid).reason)

        // …and the verdicts are IDENTICAL to the idle case, so "a run is going" is
        // not quietly changing some other reason either.
        XCTAssertEqual(VariantEntry.smoothingBlocks(mid),
                       VariantEntry.smoothingBlocks(healthy()))
        XCTAssertEqual(VariantEntry.latticeBlocks(mid),
                       VariantEntry.latticeBlocks(healthy()))
    }

    /// The one part that IS the Mac's: dispatching a generation. It queues behind
    /// the running job and says so — it never races a second CLI job at a busy
    /// worker, and it never silently refuses either.
    func testTheLatticeActionQueuesWhileTheWorkerIsBusyAndSaysSo() throws {
        let waiting = try XCTUnwrap(
            VariantEntry.latticeActionWaits(healthy(runInFlight: true)),
            "requirement 4: the ACTION must say it will wait")
        XCTAssertTrue(waiting.localizedCaseInsensitiveContains("starts when"),
                      "it must say it WAITS and then runs, not that it is refused: "
                      + "\(waiting)")
        XCTAssertTrue(waiting.localizedCaseInsensitiveContains("set the lattice up now"),
                      "…and that the page is usable meanwhile: \(waiting)")
        // It must NOT claim a worker-side queue: the app holds one run slot, so
        // nothing is actually queued on the Mac (see the constant's note).
        XCTAssertFalse(waiting.localizedCaseInsensitiveContains("queue behind"),
                       "the copy must not describe a queue the app does not create")
        XCTAssertNil(VariantEntry.latticeActionWaits(healthy()),
                     "with nothing running there is nothing to wait for")
        // The waiting sentence is NOT a block: it must not appear in the entry's
        // reasons, or the page would go dark again by another name.
        XCTAssertFalse(VariantEntry.latticeBlocks(healthy(runInFlight: true))
                        .contains(waiting))
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

    // "a job is already running" is NOT in either table any more (task
    // 2026-08-03-variant-postprocessing-concurrency). It used to head both, and
    // that is what made a four-hour ladder freeze every variant it had already
    // produced. The replacement is STRONGER, not absent: two explicit tests below
    // assert both entries stay USABLE mid-run, and that the lattice ACTION — the
    // only part that needs the Mac — queues with its own sentence.
    private var smoothingCases: [Case] {
        [
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
            Case(name: "the rung produced no geometry",
                 facts: healthy(hasGeometry: false),
                 mustSay: ["no geometry"]),
            Case(name: "the run was solved ON DEVICE",
                 facts: healthy(machine: .thisDevice, retainedJob: Data(),
                                retainedDesign: nil),
                 mustSay: ["on this device", "design file"]),
            // "PREDATES RETENTION" IS NOW A NARROWER FACT (task
            // 2026-08-03-variant-postprocessing-fix). The job document is retained
            // at SUBMIT, so a run that kept neither half is genuinely a run from
            // before retention existed. A run that kept the job but not the design
            // is a DIFFERENT fact and gets the sentence below — this case's facts
            // now match its name, which is what it always claimed to test.
            Case(name: "the run predates job/design retention entirely",
                 facts: healthy(retainedJob: Data(), retainedDesign: nil),
                 mustSay: ["before results kept their design file"]),
            Case(name: "the job was kept but the worker served no design",
                 facts: healthy(retainedDesign: nil),
                 mustSay: ["didn’t send", "design file"]),
            Case(name: "the design arrived without THIS rung in it",
                 facts: healthy(retainedDesign: designContainer(holding: [0.9]),
                                requestedVolumeFraction: 0.5),
                 mustSay: ["without this rung"]),
            Case(name: "the app RE-ATTACHED, so it never held the document it sent",
                 facts: healthy(retainedJob: Data(), retainedDesign: nil,
                                reattached: true),
                 mustSay: ["reconnected", "after a restart"]),
            // A DESIGN-BOX RUN IS NO LONGER A BLOCKING PRECONDITION. PR 285 taught
            // core to certify one (resolve_design_domain), so the case moved out of
            // this table and into `testADesignBoxRunIsLatticeableBecauseCoreCanDoIt`
            // below, which asserts the opposite verdict. Leaving it here is what
            // shipped the maintainer a refusal quoting a rule core had dropped.
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
    /// THE VERDICT THAT REPLACED THE BLOCKED ONE (device-failure task). A run that
    /// used a design box is latticeable, because core certifies it. This is the
    /// positive form of the maintainer's reproduction.
    func testADesignBoxRunIsLatticeableBecauseCoreCanDoIt() throws {
        let v = VariantEntry.lattice(healthy(retainedJob: job(designBox: true)))
        XCTAssertTrue(v.enabled,
                      "a design-box run must be latticeable: " + (v.reason ?? "—"))
        XCTAssertFalse(v.allReasons.contains(RelatticeUnavailable.designBoxRun.reason))
    }

    /// Narrowed to core's actual remaining rule (device-failure task): it is
    /// GRADING plus a design box that is refused, not a design box plus lattice.
    func testAGradedLatticeRunWithADesignBoxIsRefusedAtTheBUTTON() throws {
        XCTAssertNil(LatticeCoreCapability.liveConflict(latticeEnabled: false,
                                                        designBoxActive: true,
                                                        graded: true),
                     "a design box alone is fine — it is the COMBINATION core refuses")
        XCTAssertNil(LatticeCoreCapability.liveConflict(latticeEnabled: true,
                                                        designBoxActive: false,
                                                        graded: true))
        XCTAssertNil(LatticeCoreCapability.liveConflict(latticeEnabled: true,
                                                        designBoxActive: true,
                                                        graded: false),
                     "UNIFORM lattice under a design box is what PR 285 BUILT — "
                     + "refusing it is the device failure this task exists for")
        let why = try XCTUnwrap(
            LatticeCoreCapability.liveConflict(latticeEnabled: true,
                                               designBoxActive: true, graded: true))
        XCTAssertTrue(why.contains("design box"))
        XCTAssertTrue(why.contains("grading law"), "it says WHY, not just no")

        // The lattice page's own Optimize surface carries it, disabled — on AUTO
        // density, which is what ships a `grading` block.
        let surface = LatticeOptimizeSurface.compute(
            baseCanOptimize: true, baseSummary: "1 anchor · 1 load",
            latticeEnabled: true, densityMode: .auto,
            topologyDisplayName: "Octet", cellMM: 5, bounds: nil, running: false,
            lineWidthMM: 0.4, designBoxActive: true)
        XCTAssertFalse(surface.enabled,
                       "failure B: the button that would submit a refused job is off")
        XCTAssertEqual(surface.sub, why)

        // …and UNIFORM density under the same box is offered, because core runs it.
        let ok = LatticeOptimizeSurface.compute(
            baseCanOptimize: true, baseSummary: "1 anchor · 1 load",
            latticeEnabled: true, densityMode: .uniform,
            topologyDisplayName: "Octet", cellMM: 5, bounds: nil, running: false,
            lineWidthMM: 0.4, designBoxActive: true)
        XCTAssertTrue(ok.enabled)
    }

    /// THE GATE MIRRORS CORE, AND SAYS SO — IN BOTH DIRECTIONS.
    ///
    /// This test was written by PR 284 to go red the day core dropped its blanket
    /// design-box refusal. PR 285 dropped it hours later and the test DID go red —
    /// but CI is `core-linux` only and has never built this package, so the red
    /// never reached anyone and the app shipped a refusal quoting a core rule that
    /// no longer existed. It now pins the CURRENT truth from both sides, so a
    /// revert in either direction is loud.
    func testTheAppBlockTracksTheCoreRefusalInBothDirections() throws {
        let runJob = Self.repoRoot.appendingPathComponent("core/src/cli/run_job.cpp")
        let src = try String(contentsOf: runJob, encoding: .utf8)

        let coreRefusesEveryDesignBox =
            src.contains(LatticeCoreCapability.designBoxRefusalPhrase)
        XCTAssertEqual(coreRefusesEveryDesignBox,
                       LatticeCoreCapability.designBoxRefused,
                       "the app's design-box block must track core's own refusal, "
                       + "in whichever direction it moved. Core carrying “"
                       + LatticeCoreCapability.designBoxRefusalPhrase
                       + "”: \(coreRefusesEveryDesignBox); app blocking: "
                       + "\(LatticeCoreCapability.designBoxRefused).")

        XCTAssertTrue(
            src.contains(LatticeCoreCapability.gradedDesignBoxRefusalPhrase),
            "core's REMAINING rule — grading with a design box — is what the live "
            + "conflict now mirrors; if core drops that too, drop the live conflict")
    }

    // MARK: - DEFECT 4 · "Rim only" cannot emit on a voxel-derived part

    /// THE CLAIM IS STRUCTURAL, SO IT IS CHECKED STRUCTURALLY — against core's own
    /// source, the same discipline the design-box mirror above uses.
    ///
    /// Both rim emitters (`emit_rim_line`, `emit_rim_torus`) need a PLANE face on the
    /// `LatticeBoundary`. A Plane face can only be added by `add_half_space` (or
    /// `add_box`, which is six of them). If NOTHING in `core/src` calls either, no
    /// boundary a job can build has a plane, and rim output is identically zero.
    ///
    /// The day core starts adding planes on a production path, this test goes red and
    /// `LatticeCoreCapability.rimEmitsNothingOnVoxelParts` is the one line to change.
    func testRimOnlyProducesNothingBecauseCoreAddsNoPlaneFaceOnAnyProductionPath() throws {
        let src = Self.repoRoot.appendingPathComponent("core/src")
        let files = FileManager.default.enumerator(at: src, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "cpp" || $0.pathExtension == "hpp" } ?? []
        XCTAssertFalse(files.isEmpty, "core/src must be readable from the package")

        var callers: [String] = []
        for f in files {
            // The definitions themselves live in lattice_boundary.cpp; every OTHER
            // mention in core/src would be a caller.
            if f.lastPathComponent == "lattice_boundary.cpp" { continue }
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            if text.contains("add_half_space(") || text.contains("add_box(") {
                callers.append(f.lastPathComponent)
            }
        }
        XCTAssertTrue(callers.isEmpty,
                      "core/src now adds analytic PLANE faces (\(callers)) — a rim "
                      + "can finally have something to ride, so revisit "
                      + "LatticeCoreCapability.rimEmitsNothingOnVoxelParts")
        XCTAssertTrue(LatticeCoreCapability.rimEmitsNothingOnVoxelParts,
                      "the app's constant must track what core can do")
    }

    func testChoosingRimOnlyWarnsAndIsNotTheDefault() {
        XCTAssertEqual(LatticeSettings().boundary, .fullSkin,
                       "the DEFAULT must be a treatment that can actually emit — "
                       + "“Rim only” was the default and is provably zero geometry")
        let warn = LatticeCoreCapability.boundaryProducesNothing(
            skinJobValue: LatticeBoundaryTreatment.rim.jobSkinValue, voxelDerived: true)
        XCTAssertNotNil(warn, "choosing “Rim only” must warn")
        XCTAssertTrue(try! XCTUnwrap(warn).contains("emits nothing"))
        // …and the other two do NOT warn: a blanket warning is not a warning.
        XCTAssertNil(LatticeCoreCapability.boundaryProducesNothing(
            skinJobValue: LatticeBoundaryTreatment.fullSkin.jobSkinValue,
            voxelDerived: true))
        XCTAssertNil(LatticeCoreCapability.boundaryProducesNothing(
            skinJobValue: LatticeBoundaryTreatment.none.jobSkinValue,
            voxelDerived: true))
        // An ANALYTIC part (no such path today) keeps the rim: the rule is about the
        // surface, not about disliking the option.
        XCTAssertNil(LatticeCoreCapability.boundaryProducesNothing(
            skinJobValue: LatticeBoundaryTreatment.rim.jobSkinValue,
            voxelDerived: false))
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
        let w = VariantEntry.lattice(healthy(retainedJob: Data(), retainedDesign: nil))
        XCTAssertEqual(w.reason, RelatticeUnavailable.runPredatesDesignStore.reason)
        XCTAssertFalse(try! XCTUnwrap(w.reason).contains("on this device"))

        // …and a RE-ATTACHED worker run gets a third, because "predates retention"
        // would be a false statement about a run that simply outlived the client.
        let r = VariantEntry.lattice(healthy(retainedJob: Data(), retainedDesign: nil,
                                             reattached: true))
        XCTAssertEqual(r.reason, RelatticeUnavailable.jobDocumentNotRecorded.reason)
        XCTAssertNotEqual(r.reason, w.reason)

        // …and a CURRENT worker run that kept its job but whose design did not
        // arrive gets a FOURTH (task 2026-08-03-variant-postprocessing-fix). It used
        // to borrow `w`'s sentence — telling the maintainer his build was too old
        // about a build that had just been rebuilt from a new commit.
        let t = VariantEntry.lattice(healthy(retainedDesign: nil))
        XCTAssertEqual(t.reason, RelatticeUnavailable.designNotTransferred.reason)
        XCTAssertNotEqual(t.reason, w.reason)
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
