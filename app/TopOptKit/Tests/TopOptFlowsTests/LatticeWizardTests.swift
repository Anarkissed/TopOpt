// LatticeWizardTests.swift — task 2026-08-12-lattice-page-redesign §1a/§1d,
// §2, §3, §4 and §5.
//
// The page's PROMISES, as checks:
//   §1a/§1d  only a face that already carries a role may be latticed; keep clear
//            blocks both.
//   §2       the order is the teaching — the type MORPHS, the cell TILES, Auto
//            density plays the stress cinematic — and the persistent modal can
//            jump anywhere without playing one.
//   §3       the sample is fixed and its field is baked; the disclaimer is one
//            line and dismissible; the tessellation stays small.
//   §4       Auto is the default, Auto resolves to a mode core will accept, and
//            Auto NEVER produces a refusal.
//   §5       the per-region verdict is derived per face, and one out-of-regime
//            region does not silently stamp the whole part.
//
//   R3       the longest string this UI can render, counted here so the bar is
//            enforced rather than asserted in prose.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeWizardTests: XCTestCase {

    // MARK: §1a / §1d — the role gate

    func testOnlyARoledFaceMayBeLatticed() {
        // Undeclared: blocked.
        XCTAssertEqual(LatticeFaceRoleGate.block(kind: .pending, protected: false,
                                                 keepClearOn: false),
                       .undeclared)
        // Protect: ALLOWED — and this is the primary workflow (§1c).
        XCTAssertNil(LatticeFaceRoleGate.block(kind: .pending, protected: true,
                                               keepClearOn: false))
        // Anchor and load: allowed.
        XCTAssertNil(LatticeFaceRoleGate.block(kind: .anchor, protected: false,
                                               keepClearOn: false))
        XCTAssertNil(LatticeFaceRoleGate.block(kind: .load(direction: .gravity,
                                                           weightKg: 2),
                                               protected: false, keepClearOn: false))
    }

    func testKeepClearBlocksBoth() {
        // §1d — keep clear beats everything, including protect and a load role.
        XCTAssertEqual(LatticeFaceRoleGate.block(kind: .anchor, protected: true,
                                                 keepClearOn: true),
                       .keepClear)
        XCTAssertFalse(LatticeFaceRoleGate.allowed(kind: .pending, protected: true,
                                                   keepClearOn: true))
    }

    func testAnIneligibleGroupLosesItsRoleRatherThanCarryingADeadOne() {
        let a = UUID(), b = UUID()
        let roles: [UUID: LatticeGroupRole] = [a: .include, b: .exclude]
        let pruned = LatticeFaceRoleGate.pruned(roles: roles) { $0 == a }
        XCTAssertEqual(pruned, [a: .include])
    }

    // MARK: §2 — the order is the teaching

    func testTypeChangeMorphsAndSizeDoesNot() {
        var m = LatticeWizardModel()
        m.setTopology(LatticeType.bcc.id)
        XCTAssertEqual(m.playing, .morph, "§2A: the cell MORPHS into the new type")
        m.finishedPlaying()
        m.cellMM = 4
        XCTAssertNil(m.playing, "§2A: size is live, not a cinematic")
    }

    func testTheCellBecomesALatticeByAnimation() {
        var m = LatticeWizardModel()
        XCTAssertEqual(m.stage, .cell, "§2A: the page opens on ONE cell")
        XCTAssertEqual(LatticeSamplePatch.counts(lattice: m.lattice, cells: 1).struts,
                       LatticeSamplePatch.counts(lattice: m.lattice, cells: 1).struts)
        m.enterLattice()
        XCTAssertEqual(m.stage, .lattice)
        XCTAssertEqual(m.playing, .tile,
                       "§2B: it is ANIMATED into the part, never cut to")
    }

    func testAutoDensityPlaysTheStressCinematicAndUniformDoesNot() {
        var m = LatticeWizardModel()
        m.setDensityMode(.auto)
        XCTAssertEqual(m.playing, .stressWipeAndDive,
                       "§2C: Auto density wipes the field down and dives in")
        m.finishedPlaying()
        m.setDensityMode(.uniform)
        XCTAssertNotEqual(m.playing, .stressWipeAndDive,
                          "a flat field has nothing to explain")
    }

    func testAutoCellSizeJumpsStraightToTheSample() {
        var m = LatticeWizardModel()
        m.setCellSizeMode(.auto)
        XCTAssertEqual(m.stage, .lattice)
        XCTAssertEqual(m.playing, .jumpToSample, "§2C")
    }

    func testTheFourFinishesAreShownOnThePart() {
        var m = LatticeWizardModel(boundary: .none)
        for b in [LatticeBoundaryTreatment.rim, .fullSkin, .none] {
            m.setBoundary(b)
            XCTAssertEqual(m.boundary, b)
            XCTAssertEqual(m.playing, .boundarySwap,
                           "§2C: switching a finish SHOWS it on the part")
            m.finishedPlaying()
        }
    }

    func testAUserWhoKnowsWhatTheyWantIsNeverWalkedThroughTheWizard() {
        var m = LatticeWizardModel()
        m.jump(to: .lattice)
        XCTAssertEqual(m.stage, .lattice)
        XCTAssertNil(m.playing, "§2: a jump is not a lesson")
    }

    func testTheSelectionsRoundTripThroughTheProjectSettings() {
        var s = LatticeSettings()
        s.topologyID = LatticeType.diamond.id
        s.cellMM = 3.5
        s.maxRelativeDensity = 0.42
        s.boundary = .rim
        let m = LatticeWizardModel(settings: s)
        XCTAssertEqual(m.topologyID, LatticeType.diamond.id)
        XCTAssertEqual(m.cellMM, 3.5)
        XCTAssertEqual(m.relativeDensity, 0.42, accuracy: 1e-12)
        let back = m.applied(to: LatticeSettings())
        XCTAssertEqual(back.topologyID, LatticeType.diamond.id)
        XCTAssertEqual(back.cellMM, 3.5)
        XCTAssertEqual(back.boundary, .rim)
        XCTAssertTrue(back.enabled, "saving the page turns lattice mode on")
    }

    // MARK: §3 — the sample, and its disclaimer

    func testTheSampleFieldIsBakedAndPeaksAtTheRootSkin() {
        let mesh = LatticeWizardSample.mesh(subdiv: 6)
        let f = LatticeWizardSample.stress(for: mesh)
        XCTAssertEqual(f.count, mesh.positions.count / 3)
        XCTAssertEqual(f.max() ?? 0, 1.0, accuracy: 1e-6, "normalised to 1")
        XCTAssertEqual(f.min() ?? 1, 0.0, accuracy: 1e-6, "and to 0")
        // The densest point is at the ROOT (−x) and off the neutral axis.
        let p = LatticeWizardSample.densestPoint(for: mesh)
        XCTAssertLessThan(p.x, 0, "§3a: peak stress is at the root")
        XCTAssertGreaterThan(abs(p.z), Float(LatticeWizardSample.heightMM) * 0.4,
                             "§3a: and at the skin, not the neutral axis")
    }

    func testTheSampleIsDeterministic() {
        // A FIXED part: same mesh, same field, every call. Not a solve.
        let a = LatticeWizardSample.stress(for: LatticeWizardSample.mesh(subdiv: 8))
        let b = LatticeWizardSample.stress(for: LatticeWizardSample.mesh(subdiv: 8))
        XCTAssertEqual(a, b)
    }

    func testTheDisclaimerIsOneLineAndDismissible() {
        var m = LatticeWizardModel()
        XCTAssertTrue(m.showDisclaimer)
        let words = LatticeWizardSample.provenanceNote
            .split(separator: " ").count
        XCTAssertLessThanOrEqual(words, 12, "§3b: one line, not a paragraph")
        m.showDisclaimer = false
        XCTAssertFalse(m.showDisclaimer)
    }

    func testThePreviewTessellationStaysSmall() {
        // §3c — the preview is fast because the SAMPLE is small and tessellated
        // at screen resolution. The ceiling is enforced, not hoped for.
        var m = LatticeWizardModel(cellMM: 0.6)      // absurdly fine
        m.jump(to: .lattice)
        XCTAssertLessThanOrEqual(m.cellsAcross, LatticeWizardModel.maxCellsAcross)
        XCTAssertLessThan(m.stageTriangleCount, 150_000,
                          "§3c: the worst case is still a small mesh")
        let one = LatticeWizardModel()
        XCTAssertLessThan(one.stageTriangleCount, 2_000,
                          "§2A: one cell is a handful of triangles")
    }

    // MARK: §4 — Auto

    func testAutoIsTheDefaultOnANewProject() {
        let s = LatticeSettings()
        XCTAssertEqual(s.densityMode, .auto, "§4b")
        XCTAssertEqual(s.cellSizeMode, .auto, "§4b")
        let m = LatticeWizardModel()
        XCTAssertEqual(m.densityMode, .auto)
        XCTAssertEqual(m.cellSizeMode, .auto)
    }

    func testManualFixedAndSweptRemainAvailable() {
        // §4b — Auto is the default, never a lock.
        var m = LatticeWizardModel()
        m.setCellSizeMode(.fixed)
        XCTAssertEqual(m.cellSizeMode, .fixed)
        m.setCellSizeMode(.swept)
        XCTAssertEqual(m.cellSizeMode, .swept)
        m.setDensityMode(.uniform)
        XCTAssertEqual(m.densityMode, .uniform)
    }

    func testAutoResolvesToThePerRegionModeWhenRegionsAreDeclared() {
        // ★ Core's OWN pre-flight names this: at the whole-part Auto cell the
        // maintainer's 7 mm regions come back SOLID, and core says "set
        // cell_mode: fit and core derives exactly that, per region".
        let withRegions = LatticeAutoPosture.resolve(includeRegionCount: 8,
                                                     retainSubfloor: false)
        XCTAssertEqual(withRegions.cellMode, .fit, "§4a: per region")
        XCTAssertEqual(withRegions.densityMode, .auto)

        let none = LatticeAutoPosture.resolve(includeRegionCount: 0,
                                              retainSubfloor: false)
        XCTAssertEqual(none.cellMode, .swept,
                       "§4a: with no region declared, graded across the part")
    }

    func testAutoNeverEmitsACombinationCoreRefuses() {
        // §4c — "fit" with no include region, and "fit" alongside sub-floor
        // retention, are both hard core refusals. Auto cannot produce either.
        var s = LatticeSettings()
        s.cellSizeMode = .auto
        s.retainSubfloorInUnloadedRegions = true

        let noRegions = LatticeAutoPosture.applied(to: s, includeRegionCount: 0)
        XCTAssertNotEqual(noRegions.cellSizeMode, .fit,
                          "§4c: fit needs a region; Auto does not ask for one "
                          + "that is not there")

        let withRegions = LatticeAutoPosture.applied(to: s, includeRegionCount: 3)
        XCTAssertEqual(withRegions.cellSizeMode, .fit)
        XCTAssertFalse(withRegions.retainSubfloorInUnloadedRegions,
                       "§4c: and it drops the mutually-exclusive one rather than "
                       + "emitting a job core will reject")
        XCTAssertTrue(withRegions.reportRegionCells,
                      "§5: Auto asks for the per-region breakdown")
    }

    /// ★ §4c, THE SHARPEST VERSION. Auto is the DEFAULT now, so "Auto produces
    /// no job" is "the lattice silently does nothing on a fresh project". Core's
    /// grading schema needs the strut line width, and without one the app cannot
    /// state a graded job — so it emits the UNIFORM one rather than nothing, and
    /// says so through `graded`. (In production the width always exists:
    /// PrintParams derives it by rule. This is the belt.)
    func testAutoWithNoLineWidthStillProducesAJobAndSaysItIsNotGraded() throws {
        var s = LatticeSettings(enabled: true)
        s.densityMode = .auto
        s.minRelativeDensity = 0.2
        s.maxRelativeDensity = 0.5

        let graded = s.runSpec(lineWidthMM: 0.45)
        XCTAssertNotNil(graded, "with a width, Auto is graded")
        XCTAssertEqual(graded?.graded, true)

        let noWidth = try XCTUnwrap(s.runSpec(lineWidthMM: 0),
                                    "§4c: Auto must NEVER produce no job at all")
        XCTAssertFalse(noWidth.graded,
                       "§4c: it falls back to the buildable option AND says so — "
                       + "bar B6 forbids a SILENT uniform, not an honest one")
    }

    func testAutoLeavesAnExplicitChoiceAlone() {
        var s = LatticeSettings()
        s.cellSizeMode = .fixed
        s.densityMode = .uniform
        s.retainSubfloorInUnloadedRegions = true
        let out = LatticeAutoPosture.applied(to: s, includeRegionCount: 3)
        XCTAssertEqual(out.cellSizeMode, .fixed)
        XCTAssertTrue(out.retainSubfloorInUnloadedRegions)
    }

    // MARK: §5 — per-region verdicts

    private func bounds(floor: Double, cpm: Double) -> TopOptKit.LatticeCellBounds {
        TopOptKit.LatticeCellBounds(printabilityFloorMM: floor,
                                    cellsPerMemberFloor: cpm, valid: true)
    }
    private let limits = TopOptKit.LatticeLimits(rhoMin: 0.2, rhoMax: 0.8,
                                                 certifiable: true,
                                                 minCellsPerMember: 5)

    func testAThickSlabCertifiesAndAThinOneIsOutOfRegime() {
        // 40 mm slab, 5 cells per member floor, 1.2 mm printability floor:
        // coarsest = 8 mm, well above the floor → certified.
        let thick = LatticeFaceCardDerivation.card(
            faceID: 16, depthMM: 40, heldVoxels: 5_000, spacingMM: 1.705,
            densityGCM3: 1.24, topology: .octet,
            bounds: bounds(floor: 1.2, cpm: 5), limits: limits)
        XCTAssertEqual(thick.verdict, .certified)
        XCTAssertEqual(thick.cellMM, 8, accuracy: 1e-9)
        XCTAssertGreaterThan(thick.strutDiameterMM, 0)

        // ★ The maintainer's own case: a 7 mm slab at a 4.6 mm printability
        // floor. coarsest = 1.4 mm < 4.6 → the two bounds CROSS.
        let thin = LatticeFaceCardDerivation.card(
            faceID: 16, depthMM: 7, heldVoxels: 10_554, spacingMM: 1.705,
            densityGCM3: 1.24, topology: .octet,
            bounds: bounds(floor: 4.6026, cpm: 5), limits: limits)
        XCTAssertEqual(thin.verdict, .outOfRegime)
        XCTAssertEqual(thin.cellMM, 4.6026, accuracy: 1e-9,
                       "§4c: Auto still picks the BUILDABLE cell — it does not "
                       + "refuse")
    }

    func testTheCardStatesWhatTheBarrierHandsTheLattice() {
        // §0b — his own numbers: 10,554 voxels at 1.70527 mm spacing.
        let c = LatticeFaceCardDerivation.card(
            faceID: 16, depthMM: 5, heldVoxels: 10_554, spacingMM: 1.70527,
            densityGCM3: 1.24, topology: .octet,
            bounds: bounds(floor: 1.2, cpm: 5), limits: limits)
        let expectVolume = 10_554.0 * pow(1.70527, 3)
        XCTAssertEqual(c.heldVolumeMM3, expectVolume, accuracy: 1e-6)
        XCTAssertEqual(c.heldMassG, expectVolume * 1.24 / 1000, accuracy: 1e-9)
        XCTAssertFalse(c.heldText.isEmpty)
    }

    func testAnEmptyBarrierSaysSoRatherThanShowingAFabricatedCell() {
        let c = LatticeFaceCardDerivation.card(
            faceID: 9, depthMM: 7, heldVoxels: 0, spacingMM: 1.7,
            densityGCM3: 1.24, topology: .octet,
            bounds: bounds(floor: 1.2, cpm: 5), limits: limits)
        XCTAssertEqual(c.verdict, .noMaterial)
        XCTAssertEqual(c.cellText, "—")
        XCTAssertEqual(c.heldText, "—")
    }

    func testOneOutOfRegimeRegionDoesNotSilentlyStampTheWholePart() {
        let ok = LatticeFaceCardDerivation.card(
            faceID: 1, depthMM: 40, heldVoxels: 100, spacingMM: 1.7,
            densityGCM3: 1.24, topology: .octet,
            bounds: bounds(floor: 1.2, cpm: 5), limits: limits)
        let bad = LatticeFaceCardDerivation.card(
            faceID: 2, depthMM: 7, heldVoxels: 100, spacingMM: 1.7,
            densityGCM3: 1.24, topology: .octet,
            bounds: bounds(floor: 4.6, cpm: 5), limits: limits)
        let s = LatticeFaceCardDerivation.partSummary([ok, bad, ok])
        XCTAssertEqual(s.verdict, .outOfRegime, "§5b: the part verdict is stated")
        XCTAssertEqual(s.certified, 2, "§5b: AND the breakdown that produced it")
        XCTAssertEqual(s.outOfRegime, 1)
    }

    // MARK: R3 — the longest string this UI can render

    func testNoWallOfTextAnywhereInTheNewUI() {
        var longest = ""
        func consider(_ s: String) { if s.split(separator: " ").count > longest.split(separator: " ").count { longest = s } }
        consider(LatticeWizardSample.provenanceNote)
        consider(LatticeFaceRoleGate.Block.undeclared.reason)
        consider(LatticeFaceRoleGate.Block.keepClear.reason)
        for v in [LatticeFaceCard.Verdict.certified, .outOfRegime, .noMaterial] {
            consider(v.label)
        }
        for s in LatticeWizardStage.allCases { consider(s.title) }
        consider(LatticeAutoPosture.resolve(includeRegionCount: 1,
                                            retainSubfloor: false).label)
        let words = longest.split(separator: " ").count
        XCTAssertLessThanOrEqual(words, 12,
            "R3: the longest string the new UI renders is \(words) words: “\(longest)”")
    }
}
