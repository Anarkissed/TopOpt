// LatticeAlgorithmSelectorTests — ★★★ THE THREE ALGORITHMS, CONNECTED
// (maintainer, 2026-08-21: "the new algorithms are merged … connect the different
// algorithms").
//
// ★ THE THREE THINGS THAT CAN GO WRONG, and one bar each:
//   1. The app holds its OWN list of algorithm names and drifts from core's enum.
//   2. The key reaches no job — a picker that changes nothing (this branch's recurring
//      failure: `stressRGB`, `boundary`, the prepass library).
//   3. A job that was byte-identical before the selector existed stops being so.
//
// ★★ AND ONE MORE, WHICH IS THE EXPENSIVE ONE: core REFUSES organic under a structural
// claim, because a traced lattice is anisotropic by construction and the certification
// library holds exactly one CUBIC tensor per topology. If the app does not say so at the
// picker, the user learns it from a job that dies after the FEA.

import XCTest
import TopOptKit
@testable import TopOptFlows

final class LatticeAlgorithmSelectorTests: XCTestCase {

    /// ★★ THE NAMES ARE CORE'S. Not a Swift enum, not a literal array — the picker
    /// reads `lattice_algorithm_names()` so a fourth algorithm appears without an app
    /// change. The three we know about are asserted as MEMBERS, not as the whole set,
    /// so adding one to core does not redden this file.
    func testTheNamesComeFromCore() {
        let names = TopOptKit.latticeAlgorithmNames
        XCTAssertFalse(names.isEmpty, "★ core's algorithm list did not cross the bridge")
        for expected in ["doubled", "stepped", "organic"] {
            XCTAssertTrue(names.contains(expected), "★ core no longer offers \(expected)")
        }
        XCTAssertEqual(names.first, "doubled",
                       "★ the DEFAULT is first in core's enum, and the app resolves "
                       + "\"not stated\" to whatever is first rather than to a literal")
    }

    /// ★ AND ONLY CORE'S NAMES ARE ACCEPTED. A typo must never reach a job:
    /// `reject_unknown_keys` kills the whole document over one bad value.
    func testAnUnknownNameIsNotAccepted() {
        for junk in ["", "Doubled", "gyroid", "  organic"] {
            XCTAssertFalse(TopOptKit.latticeAlgorithmIsKnown(junk),
                           "★ \"\(junk)\" must not be treated as an algorithm")
        }
    }

    /// ★★★ AN UNTOUCHED PROJECT'S JOB IS UNCHANGED. "Not stated" writes NO key, and
    /// core resolves an absent key to doubled itself.
    func testAnUnstatedAlgorithmWritesNoKey() throws {
        var lat = LatticeSettings()
        lat.enabled = true
        XCTAssertEqual(lat.algorithm, "", "★ the default is UNSTATED, not \"doubled\"")
        let grading = try XCTUnwrap(gradingBlock(lat))
        XCTAssertNil(grading["algorithm"],
                     "★ an untouched project must produce the job it always did")
    }

    /// ★★★ AND A CHOSEN ONE REACHES THE JOB. The bar that catches "a setting that
    /// travels the whole way and draws nothing".
    func testAChosenAlgorithmReachesTheJob() throws {
        for name in TopOptKit.latticeAlgorithmNames {
            var lat = LatticeSettings()
            lat.enabled = true
            lat.algorithm = name
            let grading = try XCTUnwrap(gradingBlock(lat))
            XCTAssertEqual(grading["algorithm"] as? String, name,
                           "★ \(name) was chosen and the job does not say so")
        }
    }

    /// ★ A junk value is DROPPED rather than written. One bad key kills the document,
    /// and a job that dies on submit is a worse outcome than one that runs the default.
    func testAJunkAlgorithmIsNotWrittenIntoTheJob() throws {
        var lat = LatticeSettings()
        lat.enabled = true
        lat.algorithm = "gyroid"
        XCTAssertNil(try XCTUnwrap(gradingBlock(lat))["algorithm"])
    }

    /// ★★★ CORE'S REFUSAL, SURFACED AT THE PICKER. Organic + structural is refused by
    /// `run_job`; the page must say so before the run, and must say nothing when the
    /// pair is fine.
    func testOrganicUnderAStructuralClaimIsRefusedWithCoresReason() {
        var lat = LatticeSettings()
        lat.algorithm = "organic"
        lat.stageMode = .structural
        let reason = lat.algorithmRefusalReason
        XCTAssertNotNil(reason,
                        "★ core REFUSES organic + structural — the user must not learn "
                        + "that from a job that dies after the FEA")
        XCTAssertTrue(reason?.contains("Aesthetic") ?? false,
                      "★ and the sentence must name the remedy")

        lat.stageMode = .aesthetic
        XCTAssertNil(lat.algorithmRefusalReason,
                     "★ organic is exactly what the aesthetic mode is for")

        for ok in ["doubled", "stepped"] {
            lat.algorithm = ok
            lat.stageMode = .structural
            XCTAssertNil(lat.algorithmRefusalReason,
                         "★ \(ok) is certifiable — refusing it would be an app-authored "
                         + "restriction core does not have")
        }
    }

    /// ★ AND THE PERMISSION IS CORE'S ANSWER, not a Swift `== "organic"`. If core ever
    /// makes another algorithm uncertifiable, the app follows without an edit.
    func testThePermissionIsAskedOfCore() {
        XCTAssertFalse(TopOptKit.latticeAlgorithmAllowsStructural("organic"))
        XCTAssertTrue(TopOptKit.latticeAlgorithmAllowsStructural("doubled"))
        XCTAssertTrue(TopOptKit.latticeAlgorithmAllowsStructural("stepped"))
        XCTAssertFalse(TopOptKit.latticeAlgorithmAllowsStructural("gyroid"),
                       "★ an unknown name gets no permission")
    }

    /// ★★ THE CHOICE SURVIVES THE SAVE — and an unstated one still writes no key, so a
    /// project file made before the selector existed is byte-identical.
    func testTheChoiceRoundTrips() throws {
        for name in TopOptKit.latticeAlgorithmNames {
            var s = LatticeSettings()
            s.algorithm = name
            let back = try JSONDecoder().decode(
                LatticeSettings.self, from: JSONEncoder().encode(s))
            XCTAssertEqual(back.algorithm, name)
        }
        let plain = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(LatticeSettings())) as? [String: Any]
        XCTAssertNil(plain?["algorithm"],
                     "★ an untouched project must not gain a key")
    }

    /// ★★★ THE BANNER SAYS WHICH ALGORITHM THE PICTURE IS OF.
    ///
    /// The marcher draws the doubled ladder and only that: its cell texture is a base
    /// cell plus an integer DYADIC LEVEL, which is what doubled means. Stepped's
    /// per-region cells are arbitrary reals and organic has no cells at all, so neither
    /// is expressible in that texture. Drawing the doubled ladder under another name
    /// would be the preview/run divergence this branch spent a week closing — so it is
    /// drawn and LABELLED.
    func testTheBannerNamesAnAlgorithmItCannotDraw() throws {
        func banner(_ algorithm: String, faithful: Bool) -> String {
            let v = LatticePreviewSummaryValues(
                interiorVoxelCount: 100, previewLabel: "octet · 8.00 mm",
                algorithmName: algorithm, algorithmDrawnFaithfully: faithful)
            return LatticePreviewBanner.make(previewOn: true, hasModel: true,
                                             scene: v)?.text ?? ""
        }
        let doubled = banner("", faithful: true)
        XCTAssertEqual(doubled, "octet · 8.00 mm",
                       "★ a job that states nothing IS doubled — no caveat is owed")

        for name in ["stepped", "organic"] {
            let t = banner(name, faithful: false)
            XCTAssertTrue(t.contains(name),
                          "★ the banner must NAME what the run will build; it said: \(t)")
            XCTAssertTrue(t.contains("octet · 8.00 mm"),
                          "★ and it must not lose what it already said")
        }
    }

    /// ★★★ THE CONTROL HE ACTUALLY USES IS THE ONE THAT'S WIRED (maintainer,
    /// 2026-08-21: "Please connect the Stepped and Organic algos").
    ///
    /// `LatticeCellTransition` is the wizard's "Cell transition" row. It set a stored
    /// value that NOTHING downstream read — the decorative-control defect its own
    /// header warned about, in the file that warned about it. All three now map onto
    /// core's algorithm names.
    func testEveryCellTransitionMapsOntoAnAlgorithmCoreKnows() {
        for t in LatticeCellTransition.allCases {
            XCTAssertTrue(TopOptKit.latticeAlgorithmIsKnown(t.coreAlgorithm),
                          "★ \(t.title) maps to \"\(t.coreAlgorithm)\", which core "
                          + "does not know")
            XCTAssertNil(t.unavailableReason,
                         "★ \(t.title) is still refused — core carries all three now")
        }
        XCTAssertEqual(LatticeCellTransition.defaultGrade.coreAlgorithm, "doubled",
                       "★ Default Grade IS the dyadic ladder")
        XCTAssertEqual(LatticeCellTransition.stepped.coreAlgorithm, "stepped")
        XCTAssertEqual(LatticeCellTransition.organicGrade.coreAlgorithm, "organic")
    }

    /// ★★ AND THE THREE ARE DISTINCT. A mapping that collapsed two onto one name would
    /// satisfy the bar above and still leave the picker inert for one of them.
    func testTheThreeTransitionsAreThreeDifferentAlgorithms() {
        let names = Set(LatticeCellTransition.allCases.map(\.coreAlgorithm))
        XCTAssertEqual(names.count, LatticeCellTransition.allCases.count,
                       "★ two transitions map to the same algorithm — one of the "
                       + "buttons does nothing")
    }

    /// Builds the `grading` block the way the job builder does — through `runSpec`,
    /// the ONE place a spec is derived from the settings. Going through it is what
    /// makes this a test of the wiring rather than of the struct's field.
    private func gradingBlock(_ lat: LatticeSettings) -> [String: Any]? {
        var lat = lat
        // The graded path is where `grading` exists at all; a uniform lattice job has
        // no grading block for the key to live in.
        lat.densityMode = .sim
        let spec = lat.runSpec(
            limits: TopOptKit.latticeLimits(topology: lat.topologyID),
            generatable: true, lineWidthMM: 0.4)
        return spec?.gradingDictionary()
    }
}
