import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★ THE ORGANIC CHIP'S ACTION, END TO END — because the simulator harness cannot drive
/// the sheet's capsule chips at all (a pre-existing one, "Simple cubic", does not select
/// under it either), the chip is verified by doing exactly what its closure does and
/// following the value through `apply` into the job document.
final class LatticeWizardOrganicChipTests: XCTestCase {
    func testTheChipSelectsOrganicAndForcesShapeFitThroughToTheJob() throws {
        guard TopOptKit.gradingSchemaAccepts(key: "organic_shape_fit") else { throw XCTSkip("no organic in core") }
        var settings = LatticeSettings(); settings.enabled = true
        settings.stageMode = .aesthetic
        var model = LatticeWizardModel(settings: settings)
        XCTAssertNotEqual(model.cellTransition, .organicGrade)
        // — what `organicTypeChip`'s Button does (the rule lives on the model) —
        XCTAssertFalse(model.selectOrganic(), "an Auto window is not a reset")
        XCTAssertEqual(model.cellTransition, .organicGrade, "★ the chip's own `on` state")
        let out = model.applied(to: settings)
        XCTAssertEqual(out.algorithm, "organic")
        XCTAssertTrue(out.isOrganic)
        XCTAssertTrue(out.organicShapeFit, "★ finish is always grade-to-fit-shape (his item 3)")
        XCTAssertEqual(out.organicBoundaryFinish, .clean,
                       "★ no outline, ONLY lattice (maintainer, 2026-09-03): core's default is a net SKIN")
        // — and the job the run is built from states the intent core demands —
        let lim = TopOptKit.LatticeLimits(rhoMin: 0.1, rhoMax: 0.6, certifiable: true, minCellsPerMember: 1)
        let spec = out.runSpec(limits: lim, generatable: true, memberMM: 8, lineWidthMM: 0.42)
        let g = spec?.gradingDictionary() ?? [:]
        XCTAssertEqual(g["algorithm"] as? String, "organic")
        // ★ NO OUTLINE, ONLY LATTICE (maintainer, 2026-09-03): the bare outer surface
        // (core's default is a solid SHELL), unlocked by the diagrid key core never
        // draws on the organic path; Covered is the user's explicit shell.
        XCTAssertEqual(spec?.outerFinish, "skin")
        XCTAssertEqual(spec?.skin, "diagrid")
        var covered = out; covered.boundary = .covered
        let cs = covered.runSpec(limits: lim, generatable: true, memberMM: 8, lineWidthMM: 0.42)
        XCTAssertEqual(cs?.outerFinish, "shell", "Covered is the user's pick and stays")
        XCTAssertEqual(cs?.skin, "diagrid")
        // — and the octet path is byte-identical: its own boundary, no outer finish —
        var octetLike = out; octetLike.algorithm = ""; octetLike.boundary = .rim
        let os = octetLike.runSpec(limits: lim, generatable: true, memberMM: 8, lineWidthMM: 0.42)
        XCTAssertNil(os?.outerFinish); XCTAssertEqual(os?.skin, "rim")
        XCTAssertEqual(g["intent"] as? String, "aesthetic",
                       "★ core refuses organic without an explicit aesthetic intent (measured on-device 2026-09-02)")
        // — Structural is the stage's own word, so core's refusal stays faithful —
        var structural = out; structural.stageMode = LatticeStageMode.structural
        let g2 = structural.runSpec(limits: lim, generatable: true, memberMM: 8, lineWidthMM: 0.42)?.gradingDictionary() ?? [:]
        XCTAssertEqual(g2["intent"] as? String, "structural")
        // — and no intent key ever appears on a non-organic job (bar U1: byte-identical) —
        var octet = settings; octet.algorithm = ""
        XCTAssertNil((octet.runSpec(limits: lim, generatable: true, memberMM: 8, lineWidthMM: 0.42)?.gradingDictionary() ?? [:])["intent"])
        // — and a lattice-type chip leaves organic again —
        var back = model; back.cellTransition = .defaultGrade
        XCTAssertNotEqual(back.applied(to: settings).algorithm, "organic")
        let finishKey = TopOptKit.gradingSchemaAccepts(key: "organic_boundary_finish")
        XCTAssertEqual(g["organic_boundary_finish"] as? String, finishKey ? "clean" : nil,
                       "★ the job says CLEAN out loud (core's default is skin); written only when core accepts the key (\(finishKey))")
    }

    /// ★ A project SAVED before the clean rule (skin, un-fitted, a swept window from the
    /// octet) is repaired the same way on appear — the sheet calls the same method.
    func testASavedSkinProjectIsRepairedToCleanAndFitted() throws {
        var settings = LatticeSettings(); settings.enabled = true; settings.stageMode = .aesthetic
        settings.algorithm = "organic"; settings.organicBoundaryFinish = .skin
        settings.organicShapeFit = false; settings.cellSizeMode = .swept
        var model = LatticeWizardModel(settings: settings)
        XCTAssertTrue(model.selectOrganic(), "the swept window is reset, and the pane is told")
        let out = model.applied(to: settings)
        XCTAssertEqual(out.organicBoundaryFinish, .clean)
        XCTAssertTrue(out.organicShapeFit)
        XCTAssertEqual(out.cellSizeMode, .auto)
        // ★ 2026-09-04: the simulation switch leaves the organic cell mode alone (core
        // traces its own solved field either way)
        var off = model; off.setSimulateStresses(false)
        XCTAssertEqual(off.cellSizeMode, .auto)
        var offSaved = settings; offSaved.simulateStresses = false; offSaved.cellSizeMode = .auto
        var m3 = LatticeWizardModel(settings: offSaved)
        m3.selectOrganic()
        XCTAssertEqual(m3.cellSizeMode, .auto)
        // Fit is the user's pick and SURVIVES (D2: never remapped)
        var fit = settings; fit.cellSizeMode = .fit
        var m2 = LatticeWizardModel(settings: fit)
        XCTAssertFalse(m2.selectOrganic())
        XCTAssertEqual(m2.applied(to: fit).cellSizeMode, .fit)
    }

    /// ★ THE OCTET WINDOW MUST NOT RIDE INTO ORGANIC (reviewer, 2026-09-03). Measured
    /// on-device 2026-09-02: `cellSizeMode: auto` on disk, "Auto · grade" lit, and the
    /// organic job carried `cell_mode: swept, 5.5–6 mm` — the octet ladder's derived
    /// window, which for organic IS the separation field. Under organic an Auto pick
    /// now travels as core's own `auto` with no window; the octet path is the control
    /// and still derives its window (bar U1: byte-identical).
    func testOrganicAutoDoesNotInheritTheOctetsDerivedWindow() throws {
        guard TopOptKit.gradingSchemaAccepts(key: "organic_shape_fit") else { throw XCTSkip("no organic in core") }
        var s = LatticeSettings(); s.enabled = true; s.stageMode = .aesthetic
        s.densityMode = .sim; s.cellSizeMode = .auto
        let lim = TopOptKit.LatticeLimits(rhoMin: 0.1, rhoMax: 0.6, certifiable: true, minCellsPerMember: 1)
        // control: octet Auto derives a window (the PR 310 plan)
        let octet = s.runSpec(limits: lim, generatable: true, memberMM: 12, lineWidthMM: 0.42)?.gradingDictionary() ?? [:]
        XCTAssertNotEqual(octet["cell_mode"] as? String, "auto",
                          "control: the octet ladder still turns Auto into its own plan")
        // organic Auto: core's auto, no window
        var o = s; o.algorithm = "organic"
        let g = o.runSpec(limits: lim, generatable: true, memberMM: 12, lineWidthMM: 0.42)?.gradingDictionary() ?? [:]
        XCTAssertEqual(g["cell_mode"] as? String, "auto")
        XCTAssertNil(g["cell_min_mm"]); XCTAssertNil(g["cell_max_mm"])
        XCTAssertEqual(g["algorithm"] as? String, "organic")
    }

    /// ★ THE REAL SOURCE (measured 2026-09-03 01:17): the on-device request runs
    /// `LatticeAutoPosture.applied` BEFORE `runSpec`, and that posture had already
    /// rewritten Auto into the octet's swept window, so a guard in `runSpec` keyed on
    /// `.auto` never fired on device while its unit test passed. The posture now leaves
    /// an organic Auto alone; the octet control still derives its window.
    func testTheAutoPostureLeavesAnOrganicAutoAlone() throws {
        guard TopOptKit.gradingSchemaAccepts(key: "organic_shape_fit") else { throw XCTSkip("no organic in core") }
        var s = LatticeSettings(); s.enabled = true; s.stageMode = .aesthetic
        s.densityMode = .sim; s.cellSizeMode = .auto
        let octet = LatticeAutoPosture.applied(to: s, includeRegionCount: 1,
                                               regionWidthsMM: [12], lineWidthMM: 0.42)
        XCTAssertNotEqual(octet.cellSizeMode, .auto, "control: the octet posture rewrites Auto")
        var o = s; o.algorithm = "organic"
        let organic = LatticeAutoPosture.applied(to: o, includeRegionCount: 1,
                                                 regionWidthsMM: [12], lineWidthMM: 0.42)
        XCTAssertEqual(organic.cellSizeMode, .auto)
        XCTAssertEqual(organic.cellMinMM, o.cellMinMM); XCTAssertEqual(organic.cellMaxMM, o.cellMaxMM)
        // and through the same builder the device uses: core's auto, no window
        let lim = TopOptKit.LatticeLimits(rhoMin: 0.1, rhoMax: 0.6, certifiable: true, minCellsPerMember: 1)
        let g = organic.runSpec(limits: lim, generatable: true, memberMM: 12, lineWidthMM: 0.42)?.gradingDictionary() ?? [:]
        XCTAssertEqual(g["cell_mode"] as? String, "auto"); XCTAssertNil(g["cell_min_mm"])
    }

    /// ★ D2 (maintainer, 2026-09-03): ORGANIC CELL MODES ARE AUTO AND FIT. Anything
    /// else an organic job could inherit — a fixed cell, a swept window — travels as
    /// Auto, never as a size; Fit travels as core's `fit` where a region is declared and
    /// falls back to Auto (not to a fixed cell, as the octet ladder does) where none is.
    /// Both builder paths (graded/sim and uniform) are pinned.
    func testOrganicCellModesAreAutoAndFitOnlyOnBothPaths() throws {
        guard TopOptKit.gradingSchemaAccepts(key: "organic_shape_fit") else { throw XCTSkip("no organic in core") }
        let lim = TopOptKit.LatticeLimits(rhoMin: 0.1, rhoMax: 0.6, certifiable: true, minCellsPerMember: 1)
        func grading(_ s: LatticeSettings, regions: [LatticeRegionSpec] = []) -> [String: Any] {
            s.runSpec(limits: lim, generatable: true, memberMM: 12, lineWidthMM: 0.42,
                      regions: regions)?.gradingDictionary() ?? [:]
        }
        var base = LatticeSettings(); base.enabled = true; base.stageMode = .aesthetic
        base.algorithm = "organic"
        for density in [LatticeDensityMode.sim, .uniform] {
            var s = base; s.densityMode = density
            // fixed → auto, never cell_mm
            s.cellSizeMode = .fixed; s.cellMM = 6
            var g = grading(s)
            XCTAssertEqual(g["cell_mode"] as? String, "auto", "\(density): fixed becomes auto")
            XCTAssertNil(g["cell_mm"], "\(density): no size ever")
            // swept → auto, no window
            s.cellSizeMode = .swept; s.cellMinMM = 4; s.cellMaxMM = 8
            g = grading(s)
            XCTAssertEqual(g["cell_mode"] as? String, "auto", "\(density): swept becomes auto")
            XCTAssertNil(g["cell_min_mm"]); XCTAssertNil(g["cell_max_mm"])
            // ★ OFFER, NEVER SUBSTITUTE (ruling Aug 5): the user's Fit STAYS Fit — with
            // or without a declared region. Without one the wizard disables Fit with
            // its reason and the run button refuses; the job builder never remaps.
            s.cellSizeMode = .fit
            g = grading(s)
            XCTAssertEqual(g["cell_mode"] as? String, "fit", "\(density): a chosen Fit is never remapped")
            XCTAssertNil(g["cell_mm"]); XCTAssertNil(g["cell_min_mm"])
            let region = LatticeRegionSpec(role: .include, kind: .face)
            g = grading(s, regions: [region])
            XCTAssertEqual(g["cell_mode"] as? String, "fit", "\(density): Fit with a region is core's fit")
        }
    }

    /// ★★ THE graded:false GAP, GENERALISED (reviewer, 2026-09-03): a test that FAILS if
    /// ANY path yields an organic spec whose job lacks `algorithm: organic`. Every
    /// builder (both `runSpec` overloads), both density modes, generatable on/off,
    /// with and without a declared region, every organic cell mode. Also: no organic
    /// path may return nil where the same settings as octet return a spec — an organic
    /// job silently dropped is the same defect as one silently defaulted.
    func testEveryPathThatYieldsAnOrganicSpecWritesTheAlgorithm() throws {
        guard TopOptKit.gradingSchemaAccepts(key: "organic_shape_fit") else { throw XCTSkip("no organic in core") }
        let lim = TopOptKit.LatticeLimits(rhoMin: 0.1, rhoMax: 0.6, certifiable: true, minCellsPerMember: 1)
        let region = LatticeRegionSpec(role: .include, kind: .face)
        var paths = 0, organicSpecs = 0
        for density in [LatticeDensityMode.sim, .uniform] {
            for mode in [LatticeCellSizeMode.auto, .fit, .fixed, .swept] {
                for generatable in [true, false] {
                    for regions in [[LatticeRegionSpec](), [region]] {
                        var s = LatticeSettings(); s.enabled = true; s.stageMode = .aesthetic
                        s.densityMode = density; s.cellSizeMode = mode
                        s.cellMM = 6; s.cellMinMM = 4; s.cellMaxMM = 8
                        var o = s; o.algorithm = "organic"
                        let builders: [(LatticeSettings) -> LatticeSpec?] = [
                            { $0.runSpec(limits: lim, generatable: generatable, memberMM: 12,
                                         lineWidthMM: 0.42, regions: regions) },
                            // the topology overload derives limits/generatable itself
                            { $0.runSpec(topology: nil, memberMM: 12, lineWidthMM: 0.42,
                                         regions: regions) },
                        ]
                        for (i, build) in builders.enumerated() {
                            paths += 1
                            let octet = build(s), organic = build(o)
                            if octet != nil {
                                XCTAssertNotNil(organic, "path \(i) \(density) \(mode) gen=\(generatable) regions=\(regions.count): organic dropped where octet builds")
                            }
                            guard let spec = organic else { continue }
                            organicSpecs += 1
                            let g = spec.gradingDictionary()
                            XCTAssertEqual(g?["algorithm"] as? String, "organic",
                                           "path \(i) \(density) \(mode) gen=\(generatable) regions=\(regions.count): job lacks algorithm organic")
                            XCTAssertNil(g?["cell_mm"], "no size on an organic job (\(density) \(mode))")
                            XCTAssertTrue(["auto", "fit"].contains(g?["cell_mode"] as? String ?? ""),
                                          "organic cell_mode is auto or fit, got \(String(describing: g?["cell_mode"]))")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(organicSpecs, 0, "the sweep must exercise real specs, not skip them all (\(paths) paths)")
    }
}
