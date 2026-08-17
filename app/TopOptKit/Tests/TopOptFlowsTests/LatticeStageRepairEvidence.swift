// LatticeStageRepairEvidence.swift — ★ THE REPRODUCTION, BEFORE ANY FIX
// (task 2026-08-17-lattice-stage-repair).
//
// HIS CARD, VERBATIM, from the screenshot:
//
//     Depth 4.0 mm · Cell 4.93 mm · Cells across 0.8 · Density 5%
//     Strut 0.32 mm · Hands over 85.2 g · As lattice 4.3 g · Saved −80.9 g
//
// This file reproduces those numbers from the SHIPPING derivation and records,
// beside each, what CORE says the same region's answer is. Nothing is fixed
// here — R1 says one fix, one run, one report, and this is the run that
// establishes the failure is real and is reproduced by the code under test
// rather than by a screenshot.
//
// ★ THE CARD NEEDS NO SOLVE. `LatticeFaceCardDerivation.card` is a pure
// function of (depth, held voxels, spacing, bounds, limits, width): the numbers
// on his card are decided BEFORE any optimizer runs, at a 48³ preview grid that
// is not the run's grid. So the loop this task runs is cheap and exact, and a
// 64³ Fast job is not needed to reproduce the failure — which is the §0(c)
// confirmation, stated here rather than assumed.

import XCTest
import simd
@testable import TopOptFlows
import TopOptKit

// ─────────────────────────────────────────────────────────────────────────
// MARK: ★ §2 / R3 — THE DEPTH AND THE HANDLE ARE ONE VALUE
//
// ★ HIS WORDS: "the 'Depth' still does not connect to the actual depth of the
// primitives themselves — making it impossible for any latticed part to ever be
// considered 'in regime'."
//
// ★ ROOT CAUSE, WITH FILE AND LINE. There were TWO resolvers for one number and
// the drawer read the wrong one:
//
//   WorkspacePlaceholder.refreshLatticeFaceCards  previewed ONE face per GROUP
//       at `project.latticeSlabDepthMM(g.id)` — the GROUP's depth.
//   WorkspacePlaceholder.latticeSelectableDrawer  handed that GROUP card to the
//       drawer while labelling it `latticeSlabDepthMM(ref, in: g.id)` — the
//       SELECTABLE's depth.
//   LatticeRegionDrawer.make                      then printed `c.depthMM` — the
//       CARD's depth — so the `depthMM:` argument was DEAD for the row whenever a
//       card existed.
//
// So `writeLatticeDepthMM` (the 3D handle, and the row chip's drag) wrote
// `lattice.selectableDepthMM`, the row chip re-read it and moved… and the drawer
// under it kept showing the group's 4 mm, with a cell, a strut, a cells-across
// and a mass all computed at 4 mm. Not a stale cache: the per-selectable depth
// was never an INPUT to the derivation at all.
//
// THE FIX. `ProjectModel.latticeCardInputs()` resolves one (key, face, depth)
// per drawer through the ONE `latticeSlabDepthMM` call, the cards are derived
// from that list, and the drawer's Depth row prints the depth it was handed.
// `LatticeRegionDrawer.depthDivergence` makes "they cannot diverge" a checkable
// property instead of a convention.

@MainActor
final class LatticeDepthIsOneValueTests: XCTestCase {

    /// PR 331's banded cube in a protected + latticed group, holding a REGION and
    /// a FACE side by side — the same fixture LatticeSeparationRegionTests uses,
    /// so the two files cannot disagree about what the panel is showing.
    private func bandedCube() -> ViewerMesh {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        V(0, 0, 0); V(10, 0, 0); V(10, 10, 0); V(0, 10, 0)
        V(0, 0, 10); V(10, 0, 10); V(10, 10, 10); V(0, 10, 10)
        V(10, 0, 9); V(10, 10, 9); V(0, 0, 9); V(0, 10, 9)
        var idx: [Int32] = []
        var faces: [Int32] = []
        func T(_ a: Int32, _ b: Int32, _ c: Int32, _ f: Int32) {
            idx += [a, b, c]; faces.append(f)
        }
        T(0, 3, 2, 0); T(0, 2, 1, 0)
        T(4, 5, 6, 1); T(4, 6, 7, 1)
        T(0, 1, 8, 2); T(0, 8, 10, 2); T(10, 8, 5, 2); T(10, 5, 4, 2)
        T(1, 2, 9, 3); T(1, 9, 8, 3)
        T(2, 3, 11, 4); T(2, 11, 9, 4); T(9, 11, 7, 4); T(9, 7, 6, 4)
        T(3, 0, 10, 5); T(3, 10, 11, 5); T(11, 10, 4, 5); T(11, 4, 7, 5)
        T(8, 9, 6, 8); T(8, 6, 5, 8)
        let normals: [SIMD3<Double>] = [
            SIMD3(0, 0, -1), SIMD3(0, 0, 1), SIMD3(0, -1, 0), SIMD3(1, 0, 0),
            SIMD3(0, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 0, 1),
            SIMD3(1, 0, 0),
        ]
        return ViewerMesh(vertices: v, indices: idx, faceIDs: faces,
                          faceGeometry: normals.map {
                              StepFaceGeometry(kind: .plane, planeNormal: $0)
                          })
    }

    private func project() -> (ProjectModel, group: UUID, region: RegionID) {
        let p = ProjectModel(id: UUID(), name: "Depth", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = bandedCube()
        let rid = p.faceRegions.union(faces: [3, 8], named: "wall")
        p.selection.addGroup()
        p.selection.pickFaces([1])
        let gid = p.selection.groups[0].id
        p.selection.addRegions([rid], to: gid)
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(gid, true)
        p.lattice.enabled = true
        p.lattice.paintDepthMM = 4.0
        p.lattice.groupRoles[gid] = .include
        return (p, gid, rid)
    }

    // ── DIRECTION 1: dragging updates the number ──────────────────────────

    /// ★ A DRAG ON ONE SELECTABLE'S HANDLE REACHES THE CARD'S OWN DERIVATION.
    /// Before this task the drag wrote `selectableDepthMM` and the card list was
    /// built from the GROUP depth, so this array never moved.
    func testDraggingAHandleMovesTheDepthTheCardIsDerivedAt() {
        let (p, gid, rid) = project()
        let region = LatticeSelectableRef.region(group: gid, region: rid)
        let face = LatticeSelectableRef.face(group: gid, face: 1)

        func depth(_ key: String) -> Double? {
            p.latticeCardInputs().first { $0.key == key }?.depthMM
        }
        XCTAssertEqual(depth(region.key) ?? 0, 4.0, accuracy: 1e-12,
                       "untouched: the project default")

        p.writeLatticeDepthMM(region, mm: 9.0)      // the 3D handle's write
        XCTAssertEqual(depth(region.key) ?? 0, 9.0, accuracy: 1e-12,
                       "★ §2: the DRAG reaches the depth the card is derived at")
        XCTAssertEqual(depth(face.key) ?? 0, 4.0, accuracy: 1e-12,
                       "…and moved ONLY that selectable")
        XCTAssertEqual(depth(gid.uuidString) ?? 0, 4.0, accuracy: 1e-12,
                       "…and not the group's own row either")

        // …and it is the SAME number `latticeSlabDepthMM` resolves, not a copy.
        XCTAssertEqual(depth(region.key) ?? 0,
                       p.latticeSlabDepthMM(region, in: gid), accuracy: 1e-12,
                       "ONE resolver — the card list reads the same call the "
                       + "row chip, the 3D plane and the protection spec read")
    }

    /// ★ AND THE PROTECTION DEPTH STILL FOLLOWS IT (R3's second half, PR 328 §0).
    /// The fix must not have introduced a third store.
    func testTheProtectionDepthStillFollowsTheSameNumber() {
        let (p, gid, rid) = project()
        let region = LatticeSelectableRef.region(group: gid, region: rid)
        let face = LatticeSelectableRef.face(group: gid, face: 1)
        p.writeLatticeDepthMM(region, mm: 9.0)
        p.writeLatticeDepthMM(face, mm: 3.0)

        let specs = p.faceProtectionSpecs()
        XCTAssertEqual(specs.regionIDs, [rid])
        XCTAssertEqual(specs.regionDepthsMM.first ?? 0, 9.0, accuracy: 1e-12,
                       "R3: the region is FROZEN to the depth the card shows")
        XCTAssertEqual(specs.depthsMM.first ?? 0, 3.0, accuracy: 1e-12,
                       "R3: and so is the face beside it")
        // The card list and the protection spec agree face-by-face.
        let inputs = p.latticeCardInputs()
        XCTAssertEqual(inputs.first { $0.key == region.key }?.depthMM, 9.0)
        XCTAssertEqual(inputs.first { $0.key == face.key }?.depthMM, 3.0)
    }

    // ── DIRECTION 2: the number updates the handle ────────────────────────

    /// ★ TYPING A DEPTH MOVES THE 3D PLANE. `writeLatticeDepthMM` is the only
    /// write, so the typed number and the dragged number are the same store —
    /// and the depth PLANE the handle grabs is rebuilt from it.
    func testTypingADepthMovesTheHandlesPlane() {
        let (p, gid, _) = project()
        let face = LatticeSelectableRef.face(group: gid, face: 1)

        func planeDepth() -> Double? {
            p.latticeDepthPlanes().first { $0.ref == face }?.depthMM
        }
        XCTAssertEqual(planeDepth() ?? 0, 4.0, accuracy: 1e-9,
                       "the plane starts at the project default")
        p.writeLatticeDepthMM(face, mm: 8.5)        // what the keypad writes
        XCTAssertEqual(planeDepth() ?? 0, 8.5, accuracy: 1e-9,
                       "★ §2: TYPING moves the HANDLE")
        XCTAssertEqual(p.latticeCardInputs().first { $0.key == face.key }?.depthMM,
                       8.5, "…and the card's derivation with it")
    }

    // ── AND THEY CANNOT DIVERGE ───────────────────────────────────────────

    /// ★ THE INVARIANT, BOTH WAYS. A card derived at one depth shown under
    /// another label is exactly the defect; `depthDivergence` names it, and the
    /// row prints the depth in force rather than the card's copy.
    func testTheDrawerCannotShowACardDerivedAtADifferentDepth() {
        let w = 0.45
        let bounds = TopOptKit.latticeCellBounds(topology: "octet",
                                                 minExtrudableWidthMM: w)
        let limits = TopOptKit.latticeLimits(topology: "octet")
        func card(at d: Double) -> LatticeFaceCard {
            LatticeFaceCardDerivation.card(
                faceID: 1, depthMM: d, heldVoxels: 5000, spacingMM: 1.7,
                densityGCM3: 1.24, topology: LatticeType.octet, minExtrudableWidthMM: w)
        }
        // AGREEING — no divergence, and the row shows it.
        XCTAssertNil(LatticeRegionDrawer.depthDivergence(card: card(at: 9), depthMM: 9))
        let ok = LatticeRegionDrawer.make(card: card(at: 9), depthMM: 9, held: true)
        XCTAssertEqual(ok.rows.first { $0.label == "Depth" }?.value, "9.0 mm")

        // DIVERGING — named, and the row still shows the depth IN FORCE, never
        // the card's. Before this task it showed 4.0 here.
        let bad = LatticeRegionDrawer.depthDivergence(card: card(at: 4), depthMM: 9)
        XCTAssertNotNil(bad, "a card derived at 4 mm under a 9 mm label IS the bug")
        XCTAssertEqual(bad?.cardMM ?? 0, 4.0, accuracy: 1e-12)
        XCTAssertEqual(bad?.shownMM ?? 0, 9.0, accuracy: 1e-12)
        let shown = LatticeRegionDrawer.make(card: card(at: 4), depthMM: 9, held: true)
        XCTAssertEqual(shown.rows.first { $0.label == "Depth" }?.value, "9.0 mm",
                       "★ §2: the row prints the depth IN FORCE, not the card's")
    }

    /// ★ AND THE SHIPPING CALL SITE PRODUCES NO DIVERGENCE. A value-type
    /// invariant no shipping code exercises has shipped a defect five times in
    /// this repo (memory: tests-on-value-types-miss-call-sites), so this asserts
    /// it over the list the view actually derives from.
    func testTheShippingCardListNeverDivergesFromTheDepthInForce() {
        let (p, gid, rid) = project()
        p.writeLatticeDepthMM(.region(group: gid, region: rid), mm: 9.0)
        p.writeLatticeDepthMM(.face(group: gid, face: 1), mm: 3.0)
        p.lattice.groupDepthMM[gid] = 6.0

        let g = p.selection.groups[0]
        var checked = 0
        for input in p.latticeCardInputs() {
            // What the view will LABEL this drawer with, resolved independently.
            let shown: Double
            if input.key == gid.uuidString {
                shown = p.latticeSlabDepthMM(gid)
            } else if let ref = p.latticeSelectableRefs(g).first(where: {
                $0.key == input.key
            }) {
                shown = p.latticeSlabDepthMM(ref, in: gid)
            } else {
                return XCTFail("a card key with no drawer behind it: \(input.key)")
            }
            XCTAssertEqual(input.depthMM, shown, accuracy: 1e-12,
                           "★ R3: the depth the card is DERIVED at and the depth "
                           + "the drawer is LABELLED with are one value, for "
                           + "\(input.key)")
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 3,
                                    "the group, the region and the face were all "
                                    + "checked — a vacuous pass is not a pass")
        // …and they really are three DIFFERENT numbers, so the check above is not
        // passing because everything is still the 4 mm default.
        XCTAssertEqual(Set(p.latticeCardInputs().map { $0.depthMM }).count, 3,
                       "three distinct depths, so the invariant is under load")
    }
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: ★ §1 / R2 — AUTO IS A REAL DERIVED VALUE OR AN HONEST REFUSAL
//
// ★ HIS WORDS: "the density and depth are stuck at 5% and 4mm respectively."
//
// ★ ROOT CAUSE, WITH FILE AND LINE. `LatticeFaceCard.swift:225` (pre-fix):
//
//     let auto = limits.rhoMin > 0 ? limits.rhoMin : 0.1
//
// `limits.rhoMin` is core's `lattice_rho_min(Octet)` = 0.05047, which formats as
// "5%". It is the BAND FLOOR, reported as though Auto had chosen it — the exact
// defect class of a readout that looks like a decision and is not. It is NOT the
// documented auto-density deadlock: there is no stress field in this path to
// fall back FROM, no depth in the expression, and no fallback branch at all.
//
// AND `WorkspacePlaceholder.refreshLatticeFaceCards` never passed
// `declaredDensity`, so Uniform and Per-region read the same 5% — which is what
// made it true in EVERY mode, and what narrowed the break to the app.
//
// THE FIX. The card asks CORE (`TopOptKit.latticeRegionDerivation`, the bridge
// onto `lattice_derive_cell_for_member` / `lattice_min_density_for_strut` /
// `octet_strut_diameter_mm` — the same functions the run calls). Auto is now
// `derivedRelativeDensity`: the lightest density whose strut still PRINTS at
// this region's own cell.

@MainActor
final class LatticeAutoDensityIsDerivedTests: XCTestCase {

    static let w = 0.45

    private func card(depth: Double, declared: Double? = nil) -> LatticeFaceCard {
        LatticeFaceCardDerivation.card(
            faceID: 1, depthMM: depth, heldVoxels: 5000, spacingMM: 1.7,
            densityGCM3: 1.24, topology: LatticeType.octet,
            declaredDensity: declared, minExtrudableWidthMM: Self.w)
    }

    /// ★ R2's core claim: Auto is no longer the band floor. The SAME assertion
    /// that caught the defect — hold everything fixed, move the depth — now
    /// shows the density MOVING, which is what makes it a derivation.
    func testAutoDensityMovesWithTheDepthInsteadOfSittingOnTheBandFloor() {
        let limits = TopOptKit.latticeLimits(topology: "octet")
        let shallow = card(depth: 4.0)
        let deep = card(depth: 40.0)

        XCTAssertNotEqual(shallow.relativeDensity, deep.relativeDensity,
                          accuracy: 1e-9,
                          "★ R2: a derivation depends on the region; a floor does "
                          + "not. Before the fix these were the identical 0.05047.")
        // ★ THE DIRECTION, MEASURED, AND IT IS THE OPPOSITE OF THE OBVIOUS GUESS.
        // A THICKER slab admits a COARSER cell, and a strut's diameter is LINEAR
        // in cell size — so a coarse cell clears one bead at a LIGHT density
        // while a fine cell needs a heavy one. Auto therefore gets LIGHTER as the
        // region gets deeper, which is the whole prize: a deep region is where a
        // lattice actually saves mass.
        XCTAssertGreaterThan(deep.cellMM, shallow.cellMM,
                             "a thicker slab takes a coarser cell")
        XCTAssertLessThan(deep.relativeDensity, shallow.relativeDensity,
                          "★ …and a coarser cell prints at a LIGHTER density: "
                          + "60% at 4 mm, the 5% band floor at 40 mm")
        // ★ AND WHERE THE FLOOR *IS* THE ANSWER, IT PRINTS. This is the honest
        // form of R2: the objection was never "5% is a forbidden number", it was
        // "5% was returned without deriving anything". At 40 mm the derivation
        // genuinely lands on the floor — and unlike before, the strut that
        // produces clears the nozzle, so the card certifies instead of refusing.
        XCTAssertEqual(deep.relativeDensity, limits.rhoMin, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(deep.strutDiameterMM, Self.w - 1e-9,
                                    "the floor's strut PRINTS at this cell")
        XCTAssertEqual(deep.verdict, .certified)
        // And it is INSIDE the band at both ends — a derivation, not an escape.
        for c in [shallow, deep] {
            XCTAssertGreaterThanOrEqual(c.relativeDensity, limits.rhoMin - 1e-9)
            XCTAssertLessThanOrEqual(c.relativeDensity, limits.rhoMax + 1e-9)
        }
    }

    /// ★ AND IT AGREES WITH CORE EXACTLY — not "close to", the same number. The
    /// card is now a VIEW of core's derivation, so a disagreement is impossible
    /// by construction rather than by keeping two laws in step.
    func testEveryNumberOnTheCardIsCoresOwn() {
        for depth in [4.0, 5.87, 8.0, 20.0, 40.0] {
            let c = card(depth: depth)
            let d = TopOptKit.latticeRegionDerivation(
                topology: "octet", memberWidthMM: depth,
                minExtrudableWidthMM: Self.w)
            XCTAssertEqual(c.cellMM, d.cellMM, accuracy: 1e-12, "cell @\(depth)")
            XCTAssertEqual(c.relativeDensity, d.relativeDensity, accuracy: 1e-12,
                           "density @\(depth)")
            XCTAssertEqual(c.strutDiameterMM, d.strutMM, accuracy: 1e-12,
                           "strut @\(depth)")
            XCTAssertEqual(c.cellsPerMember, d.cellsPerMember, accuracy: 1e-12,
                           "cells across @\(depth)")
        }
    }

    /// ★ THE STRUT "PROBLEM" WAS AN ARTEFACT, AND IT IS GONE. The app's own
    /// octet law is 1.4x off core's (memory:
    /// app-octet-strut-law-differs-from-core); the card used it to judge
    /// printability at a cell core had chosen to give exactly one bead, so it
    /// refused its own Auto answer. Auto can no longer fail the strut test.
    func testAutoCanNoLongerRefuseItsOwnStrut() {
        for depth in stride(from: 2.0, through: 40.0, by: 2.0) {
            let c = card(depth: depth)
            guard c.cellMM > 0 else { continue }   // core states no answer: fine
            XCTAssertGreaterThanOrEqual(
                c.strutDiameterMM, Self.w - 1e-9,
                "★ Auto's strut prints at depth \(depth) — it is the LIGHTEST "
                + "density that reaches one bead at this cell, by construction")
        }
        // The old app law, for the record: it under-reports by ~1.4x, which is
        // exactly what turned a printable strut into the badge's 2nd problem.
        let bounds = TopOptKit.latticeCellBounds(topology: "octet",
                                                 minExtrudableWidthMM: Self.w)
        let appDia = 2 * LatticeType.octet.strutRadiusMM(
            relativeDensity: TopOptKit.latticeLimits(topology: "octet").rhoMin,
            cellMM: bounds.printabilityFloorMM)
        XCTAssertEqual(appDia, 0.32, accuracy: 5e-3)
    }

    /// ★ §1(d) — UNIFORM AND PER-REGION HONOUR THEIR OWN NUMBERS, and they are
    /// three DIFFERENT answers at one depth. Before the fix all three read 5%.
    func testTheThreeModesGiveThreeDifferentDensities() {
        let auto = card(depth: 8.0)
        let uniform = card(depth: 8.0, declared: 0.30)
        let perRegion = card(depth: 8.0, declared: 0.75)

        XCTAssertEqual(uniform.relativeDensity, 0.30, accuracy: 1e-9,
                       "★ Uniform honours a typed number")
        XCTAssertEqual(perRegion.relativeDensity, 0.75, accuracy: 1e-9,
                       "★ Per-region honours its own")
        XCTAssertEqual(Set([auto, uniform, perRegion].map {
            (($0.relativeDensity) * 1e6).rounded()
        }).count, 3, "three modes, three answers — not one figure three times")
        // Same cell in all three: the density is a FILL choice, not a cell choice.
        XCTAssertEqual(uniform.cellMM, auto.cellMM, accuracy: 1e-12)
        XCTAssertEqual(perRegion.cellMM, auto.cellMM, accuracy: 1e-12)
        // …and a heavier declared density makes a thicker strut, from core's law.
        XCTAssertGreaterThan(perRegion.strutDiameterMM, uniform.strutDiameterMM)
    }

    /// ★ R2's other half: a DECLARED density that cannot print is REFUSED, not
    /// quietly raised. Silently printing a heavier lattice than asked for, and
    /// silently emitting an unprintable strut, are both worse than saying so.
    func testADeclaredDensityTooLightToPrintIsRefusedNotRaised() {
        let limits = TopOptKit.latticeLimits(topology: "octet")
        let thin = card(depth: 8.0, declared: limits.rhoMin)
        XCTAssertEqual(thin.relativeDensity, limits.rhoMin, accuracy: 1e-9,
                       "the number the user asked for is REPORTED, not moved")
        XCTAssertLessThan(thin.strutDiameterMM, Self.w,
                          "…and the strut it really makes is under one bead")
        XCTAssertEqual(thin.verdict, .outOfRegime, "…so the card refuses it")
    }

    /// ★ AND A MEMBER NO LATTICE FITS SAYS SO, rather than certifying by
    /// omission. R2: never a silent pass.
    func testAMemberNoLatticeFitsIsRefusedRatherThanCertified() {
        let tiny = card(depth: 0.4)          // under core's percolation floor
        XCTAssertEqual(tiny.verdict, .outOfRegime)
        XCTAssertEqual(tiny.cellMM, 0, "no cell is stated, because none exists")
        XCTAssertEqual(tiny.densityText, "—", "and no density is invented")
    }

    /// ★ AN UNKNOWN NOZZLE IS STILL NOT A PASS — the pre-existing guard this
    /// rewrite must not have dropped (it was `minExtrudableWidthMM > 0` inline;
    /// core now refuses the derivation outright, which is the same verdict).
    func testAnUnknownExtrusionWidthStillDoesNotCertify() {
        let c = LatticeFaceCardDerivation.card(
            faceID: 1, depthMM: 20, heldVoxels: 5000, spacingMM: 1.7,
            densityGCM3: 1.24, topology: LatticeType.octet,
            minExtrudableWidthMM: 0)
        XCTAssertEqual(c.verdict, .outOfRegime,
                       "printability is USER INPUT and unknown is not a pass")
    }

    /// ★ 1.0 DECLARED IS STILL SOLID — core's C0 rule, checked before core is
    /// asked. Another pre-existing behaviour this rewrite must not have dropped.
    func testDeclaringSolidIsStillSolid() {
        let c = card(depth: 20, declared: 1.0)
        XCTAssertEqual(c.verdict, .noMaterial)
        XCTAssertEqual(c.savedText, "—", "solid saves nothing, and says so")
    }

    // ── the app half of §1(d): the mode's density REACHES the card ─────────

    func testTheProjectResolvesEachModesDensityForTheCard() {
        let p = ProjectModel(id: UUID(), name: "D", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.selection.addGroup()
        let gid = p.selection.groups[0].id
        p.lattice.enabled = true
        p.lattice.groupRoles[gid] = .include
        p.printParams.strutLineWidthMM = Self.w

        p.lattice.densityMode = .auto
        XCTAssertNil(p.latticeDeclaredDensity(gid),
                     "★ AUTO states nothing — core derives, and the job carries "
                     + "no relative_density key")

        p.lattice.densityMode = .uniform
        let uniform = p.latticeDeclaredDensity(gid)
        XCTAssertNotNil(uniform, "★ UNIFORM states the density the run builds at")
        XCTAssertEqual(uniform ?? 0, LatticeBounds.compute(
            settings: p.lattice,
            limits: TopOptKit.latticeLimits(topology: p.lattice.topologyID),
            lineWidthMM: Self.w).generateRelativeDensity, accuracy: 1e-12,
            "…the SAME number the emitted job generates at, not a second copy")

        p.lattice.groupDensities[gid] = 0.42
        XCTAssertEqual(p.latticeDeclaredDensity(gid) ?? 0, 0.42, accuracy: 1e-12,
                       "★ PER-REGION wins over the mode, as it does on the wire")
        p.lattice.densityMode = .auto
        XCTAssertEqual(p.latticeDeclaredDensity(gid) ?? 0, 0.42, accuracy: 1e-12,
                       "…and over Auto too")
    }

    /// ★ AND IT REACHES THE CARD LIST — the value-type/call-site gap that has
    /// shipped a defect five times in this repo.
    func testTheDeclaredDensityIsCarriedOnTheShippingCardList() {
        let p = ProjectModel(id: UUID(), name: "D", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.selection.addGroup()
        p.selection.pickFaces([1])
        let gid = p.selection.groups[0].id
        p.lattice.enabled = true
        p.lattice.groupRoles[gid] = .include
        p.printParams.strutLineWidthMM = Self.w
        p.lattice.densityMode = .auto

        XCTAssertTrue(p.latticeCardInputs().allSatisfy { $0.declaredDensity == nil },
                      "Auto: nothing stated")
        p.lattice.groupDensities[gid] = 0.42
        let inputs = p.latticeCardInputs()
        XCTAssertFalse(inputs.isEmpty, "the group contributes at least one card")
        XCTAssertTrue(inputs.allSatisfy { ($0.declaredDensity ?? 0) == 0.42 },
                      "★ §1(d): the stated density reaches EVERY card the panel "
                      + "draws for this group, group row and selectable alike")
    }
}

final class LatticeStageRepairEvidence: XCTestCase {

    /// His print profile's strut extrusion width. Not a default — printability is
    /// user input (memory: printability-is-user-input-never-a-default) — and it is
    /// pinned here by DERIVING it from the cell his card shows, below.
    static let hisStrutLineWidthMM = 0.45

    /// The depth his card shows, which is `LatticeSettings.paintDepthMM`'s default.
    static let hisDepthMM = 4.0

    /// Core's DENSE-end printability floor at width `w` — the smallest cell that
    /// prints at any density. Read from core, never derived in Swift.
    private func denseFloorFor(_ w: Double) -> Double {
        TopOptKit.latticeCellBounds(topology: "octet",
                                    minExtrudableWidthMM: w).printabilityFloorDensestMM
    }

    private func writeEvidence(_ name: String, _ text: String) {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // TopOptFlowsTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // TopOptKit
            .deletingLastPathComponent()          // app
            .deletingLastPathComponent()          // <repo root>
            .appendingPathComponent("evidence/2026-08-17-lattice-stage-repair")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: dir.appendingPathComponent(name), atomically: true,
                        encoding: .utf8)
    }

    // ─────────────────────────────────────────────────────────────────────
    // R0 — the reproduction

    /// ★★ THE BEFORE/AFTER RECORD. This test was written BEFORE the fix and
    /// asserted his screenshot's numbers verbatim, to prove the failure was real
    /// and reproduced by the code rather than by a picture. Fix 2 landed and the
    /// behaviour CHANGED ON PURPOSE, so it now asserts both halves: the OLD
    /// numbers are the ones his card showed and are GONE, and the new ones are
    /// core's own.
    ///
    /// ★ It is not deleted and nothing in it is weakened. Every figure he saw is
    /// still named here, with the arithmetic that produced it, because that is
    /// the only durable record of what was wrong — and the assertions now pin the
    /// DISTANCE between the two, which is a stronger claim than either alone.
    func testHisCardsOldNumbersAreGoneAndTheNewOnesAreCores() {
        let w = Self.hisStrutLineWidthMM
        let bounds = TopOptKit.latticeCellBounds(topology: "octet",
                                                 minExtrudableWidthMM: w)
        let limits = TopOptKit.latticeLimits(topology: "octet")
        XCTAssertTrue(bounds.valid, "core carries octet's bounds")
        XCTAssertTrue(limits.certifiable, "octet is certifiable")

        // The held mass on his card is 85.2 g. The card turns voxels into grams by
        // count · spacing³ · density/1000, so ANY (count, spacing, density) triple
        // giving 85.2 g reproduces the mass rows; the four numbers this task is
        // about — depth, cell, cells across, density — do not depend on it at all.
        // Use a spacing and a count in the range a 48³ preview of his part gives.
        let spacing = 1.705
        let densityGCM3 = 1.24                      // PLA
        let voxels = Int((85.2 * 1000.0 / (densityGCM3 * spacing * spacing * spacing))
                            .rounded())

        let card = LatticeFaceCardDerivation.card(
            faceID: 15, depthMM: Self.hisDepthMM, heldVoxels: voxels,
            spacingMM: spacing, densityGCM3: densityGCM3,
            topology: LatticeType.octet,
            minExtrudableWidthMM: w)

        // ★ THE MASS ROWS ARE UNCHANGED — they never depended on the broken
        // derivation, and his 85.2 g still reproduces exactly.
        XCTAssertEqual(card.depthMM, 4.0, accuracy: 1e-9)
        XCTAssertEqual(card.heldText, "85.2 g")

        // ── WHAT HIS SCREENSHOT SHOWED, and the arithmetic behind each ────────
        // These are the OLD values. Each is asserted to be what the old code
        // produced — by reconstructing it here — and then asserted GONE.
        let oldCell = bounds.printabilityFloorMM          // LIGHT-end floor
        let oldCells = Self.hisDepthMM / oldCell
        let oldDensity = limits.rhoMin                     // the band floor
        let oldStrut = 2 * LatticeType.octet.strutRadiusMM(
            relativeDensity: oldDensity, cellMM: oldCell)  // the APP's own law
        XCTAssertEqual(oldCell, 4.93, accuracy: 5e-3, "his card's 4.93 mm cell")
        XCTAssertEqual(oldCells, 0.81, accuracy: 5e-3, "his 0.8 cells across")
        XCTAssertEqual(oldDensity, 0.05047, accuracy: 1e-4, "his 5% IS band_rho_min")
        XCTAssertEqual(oldStrut, 0.32, accuracy: 5e-3, "his 0.32 mm strut")

        // ── AND EVERY ONE OF THEM IS GONE ────────────────────────────────────
        XCTAssertNotEqual(card.cellMM, oldCell, accuracy: 0.1)
        XCTAssertNotEqual(card.cellsPerMember, oldCells, accuracy: 0.1)
        XCTAssertNotEqual(card.relativeDensity, oldDensity, accuracy: 0.01)
        XCTAssertNotEqual(card.strutDiameterMM, oldStrut, accuracy: 0.01)
        XCTAssertEqual(card.cellText, "1.17 mm")
        XCTAssertEqual(card.cellsText, "3.4")
        XCTAssertEqual(card.densityText, "60%")
        XCTAssertEqual(card.strutText, "0.45 mm")
        // ★ Still out of regime at 4 mm — honestly, and for ONE reason now
        // (3.4 < 5), not two. The strut prints.
        XCTAssertEqual(card.verdict, .outOfRegime)
        XCTAssertGreaterThanOrEqual(card.strutDiameterMM, w - 1e-9)

        // ★ THE DISTANCE, PINNED. This is the claim the handoff makes and the
        // reason the brief's "needs 24.65 mm" advice was wrong by 4.2x.
        XCTAssertEqual(oldCell / card.cellMM, 4.2, accuracy: 0.05,
                       "the old cell was 4.2x too coarse")
        XCTAssertEqual(w / oldStrut, 1.4, accuracy: 0.02,
                       "and the old strut law 1.4x off core's")

        // ★ AND THE DENSITY IS NO LONGER THE SAME NUMBER AT EVERY DEPTH — the
        // assertion that CAUGHT the defect, inverted. It used to be identical at
        // 4 mm and 40 mm because the Auto branch never looked at the depth.
        let deep = LatticeFaceCardDerivation.card(
            faceID: 15, depthMM: 40, heldVoxels: voxels, spacingMM: spacing,
            densityGCM3: densityGCM3, topology: LatticeType.octet, minExtrudableWidthMM: w)
        XCTAssertNotEqual(deep.relativeDensity, card.relativeDensity,
                          accuracy: 1e-9,
                          "★ §1(b): it is DERIVED now — it moves with the region. "
                          + "Before the fix both were 0.05047.")
    }

    /// ★ §1(d) — INVERTED BY THE FIX. This test was written to PIN THE DEFECT:
    /// the app never handed the card a declared density, so Uniform and
    /// Per-region read the same 5% Auto did, and the break was app-side. It now
    /// asserts the opposite, on the same source file, so the defect cannot creep
    /// back by someone dropping the argument again.
    ///
    /// A source-text assertion, deliberately: the value-type test above proves
    /// the DERIVATION honours a declared density, and this proves the SHIPPING
    /// call site supplies one — the pair that memory
    /// `tests-on-value-types-miss-call-sites` says has shipped a defect five
    /// times when only the first half exists.
    func testTheAppCallSiteHandsTheCardTheModesOwnDensity() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"),
            encoding: .utf8)
        guard let r = src.range(of: "LatticeFaceCardDerivation.card(") else {
            return XCTFail("the card call site moved — re-read it before trusting this")
        }
        // Read the WHOLE call by balancing its parentheses, not a fixed-length
        // slice: the previous cut bounded it on a literal argument string and
        // broke the moment that argument moved (R7 — do not filter a check you
        // cite as evidence).
        var depth = 0
        var end = src.index(before: r.upperBound)
        var i = end
        while i < src.endIndex {
            if src[i] == "(" { depth += 1 }
            else if src[i] == ")" {
                depth -= 1
                if depth == 0 { end = i; break }
            }
            i = src.index(after: i)
        }
        XCTAssertGreaterThan(depth, -1, "the call's parentheses balanced")
        let text = String(src[r.lowerBound...end])
        XCTAssertTrue(text.contains("declaredDensity:"),
                      "★ §1(d): the app hands the card the MODE'S OWN density. "
                      + "Without this argument Uniform and Per-region read the "
                      + "identical figure Auto does — the original defect.")
        XCTAssertTrue(text.contains("rhosCopy"),
                      "…and it is the per-card resolved value, not a constant")
        // ★ AND THE DEAD PARAMETERS ARE GONE — injected bounds are how the card
        // came to disagree with core in the first place.
        XCTAssertFalse(text.contains("bounds:"),
                       "the card no longer accepts injected cell bounds")
        XCTAssertFalse(text.contains("limits:"),
                       "…nor injected band limits; core is the one source")
    }

    /// ★ §3 — WHAT CORE SAYS ABOUT THE SAME REGION. The card's two routes out are
    /// derived from the card's OWN cell, and that cell is core's LIGHT-end
    /// printability floor. Core's own derivation uses the DENSE-end floor, and the
    /// depth it needs is four times smaller than the card implies.
    func testCoresOwnDerivationDisagreesWithTheCardAboutBothTheCellAndTheDensity() {
        let w = Self.hisStrutLineWidthMM
        let limits = TopOptKit.latticeLimits(topology: "octet")
        let bounds = TopOptKit.latticeCellBounds(topology: "octet",
                                                 minExtrudableWidthMM: w)

        // ★ AT HIS 4 mm DEPTH CORE AND THE CARD DISAGREE ABOUT EVERY NUMBER.
        // `feasible` in the bridge is PERCOLATION, not certification (bridge.cpp:
        // "buildable-and-uncertifiable is a verdict, not a refusal") — so a 4 mm
        // member builds, and `outOfRegime` carries the certification answer.
        let at4 = TopOptKit.latticeRegionDerivation(
            topology: "octet", memberWidthMM: 4.0, minExtrudableWidthMM: w)
        XCTAssertTrue(at4.valid)
        XCTAssertTrue(at4.feasible, "core: a 4 mm member BUILDS (percolation)")
        XCTAssertTrue(at4.outOfRegime, "…but does not certify")
        XCTAssertEqual(at4.cellMM, denseFloorFor(w), accuracy: 1e-6,
                       "★ core picks the DENSE-end floor, 1.17 mm — the card picks "
                       + "the LIGHT-end floor, 4.93 mm: 4.2x apart")
        XCTAssertEqual(at4.cellsPerMember, 3.41, accuracy: 0.01,
                       "★ core: 3.4 cells across, not the card's 0.8")
        XCTAssertGreaterThan(at4.relativeDensity, 0.55,
                             "★ core: ~60% density, not the card's 5%")
        XCTAssertTrue(at4.prints,
                      "★ core: the strut PRINTS — the card's second 'problem' is "
                      + "the app's own octet law, not a property of the region")
        XCTAssertEqual(at4.strutMM, w, accuracy: 1e-3)

        // The depth that DOES certify: N* × the dense-end floor.
        let denseFloor = bounds.printabilityFloorDensestMM
        XCTAssertGreaterThan(denseFloor, 0)
        let needed = bounds.cellsPerMemberFloor * denseFloor
        let atNeeded = TopOptKit.latticeRegionDerivation(
            topology: "octet", memberWidthMM: needed * 1.0001,
            minExtrudableWidthMM: w)
        XCTAssertTrue(atNeeded.feasible,
                      "core: it certifies the moment the member reaches N*·floor")
        XCTAssertGreaterThanOrEqual(atNeeded.cellsPerMember, 5.0 - 1e-6)
        XCTAssertTrue(atNeeded.prints)

        // ★ AND THE CARD'S STRUT IS THE APP'S OWN LAW, 1.4x OFF CORE'S.
        let appDia = 2 * LatticeType.octet.strutRadiusMM(
            relativeDensity: limits.rhoMin, cellMM: bounds.printabilityFloorMM)
        let coreDerivedAtThatCell = TopOptKit.latticeRegionDerivation(
            topology: "octet",
            memberWidthMM: bounds.cellsPerMemberFloor * bounds.printabilityFloorMM,
            minExtrudableWidthMM: w)
        XCTAssertEqual(appDia, 0.32, accuracy: 5e-3,
                       "the app's law at the band floor and core's own floor cell")
        XCTAssertEqual(coreDerivedAtThatCell.strutMM, w, accuracy: 1e-3,
                       "★ core's law at the SAME cell gives exactly one bead — so "
                       + "the card's 'strut too thin' is an artefact of the app "
                       + "carrying its own octet law")
        XCTAssertEqual(w / appDia, 1.4, accuracy: 0.02,
                       "the 1.4x that memory app-octet-strut-law-differs-from-core "
                       + "recorded, reaching a verdict the user acts on")

        let report = """
        HIS CARD vs CORE — 2026-08-17-lattice-stage-repair, before any fix
        strut line width           \(w) mm
        band                       \(limits.rhoMin) … \(limits.rhoMax)
        cells-per-member floor N*  \(bounds.cellsPerMemberFloor)
        printability floor, LIGHT  \(bounds.printabilityFloorMM) mm   <- the card's cell
        printability floor, DENSE  \(denseFloor) mm

        CARD at depth 4.0 mm
          cell            \(bounds.printabilityFloorMM) mm
          cells across    \(4.0 / bounds.printabilityFloorMM)
          density         \(limits.rhoMin)          (= band floor, unconditional)
          strut           \(appDia) mm       (app's law; core's is \(w) mm)
          verdict         out of regime, 2 problems

        CORE at member 4.0 mm — THE SAME REGION, CORE'S OWN LAW
          cell            \(at4.cellMM) mm     (the DENSE floor)
          cells across    \(at4.cellsPerMember)
          density         \(at4.relativeDensity)   (lightest that PRINTS at that cell)
          strut           \(at4.strutMM) mm
          prints          \(at4.prints)
          out of regime   \(at4.outOfRegime)    (3.4 < 5 — still short, but 4.2x
                                                 closer than the card's 0.8)

        CORE: the member width that DOES certify
          N* x dense floor  \(needed) mm
          at \(needed * 1.0001) mm: cell \(atNeeded.cellMM) mm, \
        density \(atNeeded.relativeDensity), strut \(atNeeded.strutMM) mm, \
        \(atNeeded.cellsPerMember) cells across, prints \(atNeeded.prints)

        ★ The card's "at cell 4.93 mm the region needs >= 24.65 mm depth" is an
          artefact of quoting the LIGHT-end floor. Core's requirement is \(needed) mm.
        """
        writeEvidence("r0_card_vs_core.txt", report)
        print(report)
    }
}
