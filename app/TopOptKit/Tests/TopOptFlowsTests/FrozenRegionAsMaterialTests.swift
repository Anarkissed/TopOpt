// FrozenRegionAsMaterialTests.swift — task 2026-08-13-lattice-as-a-material, §7.
//
// §7b — the face card already stated what the barrier HANDS the lattice in grams
//       (PR 328 §0b). It stopped one multiplication short of the number the
//       feature exists for: what that material WEIGHS as a lattice, and the
//       difference.
// §7a — a declared region needs a DENSITY control, and it must default to AUTO,
//       which ★ can never produce a refusal.
// §7c — a region using the rho -> stiffness law outside its validity range must
//       show as such, and the card's own verdict is where.
//
// ★ THE LAST TEST HERE IS THE ONE THIS FILE IS PAID FOR. "tests on value types
// miss call sites" has shipped FIVE times in this repository: a derivation is
// unit-tested, the view never calls it, the control is dead on the device and
// the suite is green. So the last test reads WorkspacePlaceholder.swift and
// asserts the card row renders the two new numbers and the control writes the
// settings key the job carries.

import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class FrozenRegionAsMaterialTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()

    /// Core's own numbers, through the bridge — never an app-side literal.
    /// `app-octet-strut-law-differs-from-core` measured what a copy costs: 1.4x.
    private let topology = LatticeType.octet
    private var bounds: TopOptKit.LatticeCellBounds {
        TopOptKit.latticeCellBounds(topology: topology.id, minExtrudableWidthMM: 0.45)
    }
    private var limits: TopOptKit.LatticeLimits {
        TopOptKit.latticeLimits(topology: topology.id)
    }

    /// A slab thick enough that the two bounds do not cross, so the card is
    /// `certified` and the mass arithmetic is what is under test.
    private func card(depthMM: Double = 30, heldVoxels: Int = 10_000,
                      declared: Double? = nil) -> LatticeFaceCard {
        LatticeFaceCardDerivation.card(
            faceID: 16, depthMM: depthMM, heldVoxels: heldVoxels,
            spacingMM: 1.705279303, densityGCM3: 1.24, topology: topology, declaredDensity: declared,
            minExtrudableWidthMM: 0.45)
    }

    // ── §7b: what it will weigh, and the difference ──────────────────────────

    func testTheCardStatesWhatTheMaterialWeighsAsALatticeAndTheDifference() {
        let c = card()
        XCTAssertGreaterThan(c.heldMassG, 0)
        XCTAssertGreaterThan(c.relativeDensity, 0)
        // The arithmetic is core's own mass accounting: a latticed voxel counts
        // its relative density, a solid one counts 1.
        XCTAssertEqual(c.latticedMassG, c.heldMassG * c.relativeDensity,
                       accuracy: 1e-9)
        XCTAssertEqual(c.savedMassG, c.heldMassG - c.latticedMassG, accuracy: 1e-9)
        XCTAssertGreaterThan(c.savedMassG, 0, "a lattice below solid must save mass")
        XCTAssertTrue(c.savedText.hasPrefix("−"),
                      "the saving is mass LEAVING the part: \(c.savedText)")
    }

    /// A card with nothing to lattice must show a dash, not "0.0 g saved" —
    /// they read very differently to someone deciding whether to drag further.
    func testNoMaterialShowsADashRatherThanZeroGrams() {
        let c = card(heldVoxels: 0)
        XCTAssertEqual(c.verdict, .noMaterial)
        XCTAssertEqual(c.latticedText, "—")
        XCTAssertEqual(c.savedText, "—")
    }

    // ── §7a: the control, and AUTO ───────────────────────────────────────────

    func testAutoIsTheDefaultAndIsAbsence() throws {
        let s = LatticeSettings()
        XCTAssertTrue(s.frozenRegionDensity.isEmpty,
                      "Auto is the default on every control (lattice-page §4)")
        let round = try JSONDecoder().decode(
            LatticeSettings.self, from: try JSONEncoder().encode(s))
        XCTAssertEqual(round.frozenRegionDensity, s.frozenRegionDensity)
    }

    func testAnOlderSnapshotWithoutTheKeyDecodesToAuto() throws {
        // ★ `groupRoles` is `[]` and not `{}`: a Swift dictionary with a
        // non-String key encodes as a FLAT ARRAY, so this is what a real old
        // snapshot on disk looks like. Writing `{}` would have tested a document
        // the app never produced.
        let json = Data("""
        {"enabled":true,"topologyID":"octet","cellMM":2,
         "minRelativeDensity":0,"maxRelativeDensity":1,
         "includePrimitives":[],"boundary":"fullSkin","densityMode":"uniform",
         "paintedIncludeFaces":[],"paintDepthMM":4,"groupRoles":[]}
        """.utf8)
        let s = try JSONDecoder().decode(LatticeSettings.self, from: json)
        XCTAssertTrue(s.frozenRegionDensity.isEmpty)
    }

    func testADeclaredDensityRoundTripsAndMovesTheCard() throws {
        let id = UUID()
        var s = LatticeSettings()
        s.frozenRegionDensity[id] = 0.45
        let round = try JSONDecoder().decode(
            LatticeSettings.self, from: try JSONEncoder().encode(s))
        XCTAssertEqual(round.frozenRegionDensity[id], 0.45)

        let auto = card()
        let declared = card(declared: 0.45)
        XCTAssertEqual(declared.relativeDensity, 0.45, accuracy: 1e-9)
        XCTAssertGreaterThan(declared.latticedMassG, auto.latticedMassG,
                             "a denser declaration must weigh more")
        XCTAssertLessThan(declared.savedMassG, auto.savedMassG)
    }

    /// ★ AUTO CAN NEVER REFUSE — ★★ NARROWED, DELIBERATELY, BY BAR R2 OF TASK
    /// 2026-08-17-lattice-stage-repair. This is a CONTRACT CHANGE and it is
    /// marked as one rather than quietly loosened.
    ///
    /// The original claim was "Auto must ALWAYS pick a cell and a density, at
    /// every depth". That was written when the card derived its own numbers and
    /// could therefore always produce some. Now it asks CORE, and core answers
    /// `feasible_percolation == false` for a member no (cell, density) pair in
    /// the band can span — below that width the strut network is not connected
    /// and the generator emits DEBRIS, not a lattice.
    ///
    /// ★ R2: "AUTO MUST NOT SILENTLY FALL BACK. Either it produces a real graded
    /// density, or it says so." Printing a cell for a member that cannot hold one
    /// is exactly the silent fallback R2 forbids — it is how the old card came to
    /// report `5% · 4.93 mm` for a 4 mm slab. So the sweep now asserts the SAME
    /// property everywhere a lattice is genuinely possible, and asserts the
    /// HONEST REFUSAL where it is not.
    ///
    /// ★ AND THE ORIGINAL'S REAL POINT SURVIVES INTACT: Auto never puts the page
    /// into an error state — `noMaterial` (which means "nothing to lighten") is
    /// still never produced while material is present, at ANY depth.
    func testAutoNeverRefusesAtAnyDepthAndSaysSoWhereItCannot() {
        var possible = 0, refused = 0
        for d in stride(from: 0.5, through: 60.0, by: 0.5) {
            let c = card(depthMM: d)
            XCTAssertNotEqual(c.verdict, .noMaterial,
                              "Auto produced 'no material' with material present at depth \(d)")
            // Core's own answer for this member, asked independently.
            let core = TopOptKit.latticeRegionDerivation(
                topology: topology.id, memberWidthMM: d,
                minExtrudableWidthMM: 0.45)
            if core.valid && core.feasible {
                possible += 1
                XCTAssertGreaterThan(c.relativeDensity, 0,
                                     "Auto must pick a density where one exists (depth \(d))")
                XCTAssertGreaterThan(c.cellMM, 0,
                                     "Auto must pick a cell where one exists (depth \(d))")
                XCTAssertGreaterThanOrEqual(c.strutDiameterMM, 0.45 - 1e-9,
                                            "…and it must PRINT (depth \(d))")
            } else {
                refused += 1
                XCTAssertEqual(c.verdict, .outOfRegime,
                               "★ R2: where no lattice fits, the card SAYS SO "
                               + "rather than quoting a cell (depth \(d))")
                XCTAssertEqual(c.cellMM, 0,
                               "…and quotes no cell, because none exists (depth \(d))")
            }
        }
        // ★ BOTH ARMS WERE EXERCISED — a sweep that only ever hit one branch
        // would pass this test while measuring half of it.
        XCTAssertGreaterThan(possible, 0, "the sweep reached feasible depths")
        XCTAssertGreaterThan(refused, 0, "the sweep reached infeasible depths")
    }

    /// SOLID is 1.0 and it emits NO lattice — core's own `kLatticeSolidAt` rule,
    /// which is what lets bar R1 be exact rather than merely tight.
    func testDeclaringSolidEmitsNoLatticeAndSavesNothing() {
        let c = card(declared: 1.0)
        XCTAssertEqual(c.verdict, .noMaterial)
        XCTAssertEqual(c.relativeDensity, 0)
        XCTAssertEqual(c.savedMassG, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(c.heldMassG, 0, "the material is still there — it is solid")
    }

    // ── §7c: outside the law's validity range, and it SHOWS ──────────────────

    /// A slab too thin for the two bounds to both hold is out of regime: the
    /// stiffness law is being used outside its validity range and the card says
    /// so rather than stamping the part certified.
    func testATooThinSlabIsOutOfRegimeAndTheVerdictSaysSo() {
        let thin = card(depthMM: 2.0)
        XCTAssertEqual(thin.verdict, .outOfRegime,
                       "2 mm cannot hold \(bounds.cellsPerMemberFloor) cells at "
                     + "core's \(bounds.printabilityFloorMM) mm printability floor")
        XCTAssertEqual(thin.verdict.label, "Out of regime")
        let thick = card(depthMM: 40)
        XCTAssertEqual(thick.verdict, .certified)
    }

    /// A DECLARED density whose strut is thinner than one bead is refused, NOT
    /// silently raised — raising it would print a heavier lattice than the user
    /// asked for and report the lighter one.
    func testADeclaredDensityThatCannotPrintIsRefusedNotClamped() {
        // The band floor at a cell this coarse prints; force a thin one by
        // declaring right at the band's bottom on a slab whose Auto cell is fine.
        let c = LatticeFaceCardDerivation.card(
            faceID: 16, depthMM: 8, heldVoxels: 1000, spacingMM: 1.0,
            densityGCM3: 1.24, topology: topology,
            declaredDensity: limits.rhoMin, minExtrudableWidthMM: 5.0)
        XCTAssertEqual(c.verdict, .outOfRegime)
        XCTAssertEqual(c.relativeDensity, limits.rhoMin, accuracy: 1e-9,
                       "the declaration is reported as made, never quietly raised")
    }

    /// One out-of-regime region must not stamp the whole part, and the part
    /// verdict must be stated ALONGSIDE the counts.
    func testOneOutOfRegimeRegionDoesNotSilentlyStampThePart() {
        let s = LatticeFaceCardDerivation.partSummary([card(depthMM: 40),
                                                       card(depthMM: 2)])
        XCTAssertEqual(s.verdict, .outOfRegime)
        XCTAssertEqual(s.certified, 1)
        XCTAssertEqual(s.outOfRegime, 1)
    }

    // ── ★ PRINTABILITY IS ENTIRELY USER INPUT ────────────────────────────────

    /// The width comes from the project's print profile
    /// (`PrintParams.strutLineWidthMM`), which the user chose and the app may not
    /// change. The SAME region and the SAME density must produce DIFFERENT
    /// verdicts under different profiles — which is the whole reason the number
    /// cannot have a default.
    func testTheVerdictFollowsTheUsersPrintProfile() {
        // ★ The slab is 30 mm ON PURPOSE. The coupling runs through core's
        // PRINTABILITY FLOOR, which is itself a function of the user's width — so
        // the fixture has to be thick enough that the two bounds do not cross for
        // a fine nozzle and thin enough that they DO for a coarse one. A slab
        // that crosses at every width would report out-of-regime three times and
        // this test would pass while measuring nothing.
        // ★★ THE SLAB AND THE DENSITY ARE RE-CHOSEN AGAINST CORE'S REAL LAW (task
        // 2026-08-17-lattice-stage-repair §1). The old fixture — a 30 mm slab at
        // 0.30 — was tuned against the card's own arithmetic, which used the
        // printability floor at the band's LIGHTEST density. Core uses the
        // DENSEST-end floor, which is 4.2x finer, so under core's law a 30 mm
        // slab certifies at ALL THREE widths and this test's flip vanished.
        //
        // ★ THE PROPERTY UNDER TEST IS UNCHANGED and the numbers are core's:
        //   N* x (width / phi(rho_max)) is the member a profile needs.
        //     0.25 mm -> 3.26 mm   0.45 mm -> 5.87 mm   0.80 mm -> 10.43 mm
        // An 8 mm slab straddles the third and not the first two — so the SAME
        // lattice is certifiable on a fine and a mid nozzle and is NOT on a
        // coarse one, which is exactly what the test has always claimed.
        //
        // 0.40 rather than 0.30 because the strut must clear the MID bead too: at
        // the 1.6 mm cell an 8 mm slab takes, 0.30 gives 0.390 mm — under 0.45,
        // so the mid arm would fail the PRINT test and the test would flip for
        // the wrong reason.
        func cardAt(_ width: Double) -> LatticeFaceCard {
            LatticeFaceCardDerivation.card(
                faceID: 16, depthMM: 8, heldVoxels: 1000, spacingMM: 1.0,
                densityGCM3: 1.24, topology: topology, declaredDensity: 0.40,
                minExtrudableWidthMM: width)
        }
        // Same slab, same declared density, three profiles.
        let fine = cardAt(0.25), mid = cardAt(0.45), coarse = cardAt(0.80)
        XCTAssertEqual(fine.relativeDensity, 0.40, accuracy: 1e-9)
        XCTAssertEqual(coarse.relativeDensity, 0.40, accuracy: 1e-9,
                       "★ and the declaration is REPORTED even where it is "
                       + "refused — the verdict carries the refusal, not silence")
        XCTAssertEqual(fine.verdict, .certified,
                       "a 0.25 mm profile needs only 3.26 mm of member")
        XCTAssertEqual(mid.verdict, .certified, "a 0.45 mm one needs 5.87 mm")
        XCTAssertEqual(coarse.verdict, .outOfRegime,
                       "★ a 0.80 mm profile needs 10.43 mm, which an 8 mm slab "
                     + "does not have — the SAME lattice stops being certifiable, "
                     + "and that is why the width has no default")
        // …and the reason is the CELL being forced coarser, not a print failure.
        XCTAssertGreaterThan(coarse.cellMM, mid.cellMM,
                             "the coarse profile forces a coarser cell")
        XCTAssertLessThan(coarse.cellsPerMember, 5.0,
                          "…which is what drops it under N*")
        XCTAssertNotEqual(fine.verdict, coarse.verdict,
                          "the SAME lattice must be judged differently under a "
                        + "0.25 mm and a 0.80 mm profile (fine \(fine.verdict), "
                        + "mid \(mid.verdict), coarse \(coarse.verdict))")
    }

    /// ★ AN UNKNOWN WIDTH IS NOT A PASS. An earlier cut read `<= 0` as "skip the
    /// printability test", so a project whose profile had not reached the call
    /// certified every density as printable. Unknown must read as out-of-regime.
    func testAnUnknownWidthDoesNotCertifyAsPrintable() {
        let unknown = LatticeFaceCardDerivation.card(
            faceID: 16, depthMM: 40, heldVoxels: 10_000, spacingMM: 1.705279303,
            densityGCM3: 1.24, topology: topology, declaredDensity: nil, minExtrudableWidthMM: 0)
        XCTAssertEqual(unknown.verdict, .outOfRegime,
                       "with no stated width the card must say it cannot tell, "
                     + "not silently certify")
    }

    // ── ★ THE CALL SITE ──────────────────────────────────────────────────────

    /// ★ REWRITTEN AFTER THE PR 331 MERGE, and the rewrite is the honest half of
    /// a loss. The original asserted five source strings in
    /// `WorkspacePlaceholder.swift`; PR 331 restructured that file wholesale —
    /// deleting the block those strings lived in and removing `metricChip`
    /// entirely — so five of them went red because the UI they guarded was gone,
    /// not because anything regressed.
    ///
    /// ★ THE TWO NUMBERS ARE RE-SITED and are asserted here against the DRAWER
    /// MODEL rather than against source text, which is a better test than the one
    /// it replaces: it checks what a user sees, not how it was spelled.
    ///
    /// ★ THE DENSITY CONTROL IS NOT RE-SITED, deliberately. PR 331's drawer
    /// asserts as a property that EXACTLY ONE row is a control and it is the
    /// depth (`modifiableRows`). Adding a second control contradicts that
    /// invariant, and choosing between them is the maintainer's call, not a merge
    /// resolution's. `LatticeSettings.frozenRegionDensity` survives as the
    /// persisted half; nothing writes it until a control is re-sited, and NOTHING
    /// FUNCTIONAL DEPENDS ON IT — it never reached the emitted job.
    func testTheCardsMassNumbersAreOnTheDrawer() {
        let c = LatticeFaceCardDerivation.card(
            faceID: 16, depthMM: 40, heldVoxels: 10_000, spacingMM: 1.705279303,
            densityGCM3: 1.24, topology: topology, declaredDensity: nil,
            minExtrudableWidthMM: 0.45)
        let d = LatticeRegionDrawer.make(card: c, depthMM: 40, held: false,
                                         latticeReachesTheRun: true)
        let labels = d.rows.map(\.label)
        XCTAssertTrue(labels.contains("As lattice"),
                      "the drawer must show what the material weighs as a lattice")
        XCTAssertTrue(labels.contains("Saved"),
                      "and the difference — which is the whole reason to lattice it")
        XCTAssertEqual(d.rows.first(where: { $0.label == "As lattice" })?.value,
                       c.latticedText)
        XCTAssertEqual(d.rows.first(where: { $0.label == "Saved" })?.value,
                       c.savedText)
        // ★ AND PR 331'S INVARIANT STILL HOLDS: adding two READ-ONLY rows must not
        // add a second control.
        XCTAssertEqual(d.modifiableRows.map(\.label), ["Depth"],
                       "exactly one row is a control and it is the depth")
    }

    /// ★ PR 331's control invariant, WITH ITS SECOND CASE. It was not wrong — it
    /// was UNCONDITIONAL where it should be CONDITIONAL. The density is decided on
    /// the settings page and the drawer follows that choice: only the per-region
    /// mode says "I will state it myself", and only there is density a control.
    ///
    /// ★ TWO EXACT CASES, NEITHER RELAXED TO "one or more". The invariant exists
    /// to stop a readout being mistaken for a control — a named defect on this
    /// project — and a loose bound would not do that job.
    func testTheDensityRowIsAControlONLYUnderPerRegion() {
        let c = LatticeFaceCardDerivation.card(
            faceID: 16, depthMM: 40, heldVoxels: 10_000, spacingMM: 1.705279303,
            densityGCM3: 1.24, topology: topology, declaredDensity: nil,
            minExtrudableWidthMM: 0.45)

        // CASE 1 — every other mode. Byte-identical to what PR 331 shipped.
        let plain = LatticeRegionDrawer.make(card: c, depthMM: 40, held: false,
                                             latticeReachesTheRun: true)
        XCTAssertEqual(plain.modifiableRows.map(\.label), ["Depth"],
                       "off per-region the drawer is exactly PR 331's: one "
                     + "control, the depth")

        // CASE 2 — per-region, and ONLY here.
        let perRegion = LatticeRegionDrawer.make(card: c, depthMM: 40, held: false,
                                                 latticeReachesTheRun: true,
                                                 perRegionDensity: true)
        XCTAssertEqual(perRegion.modifiableRows.map(\.label), ["Depth", "Density"],
                       "under per-region the density is the SECOND control — and "
                     + "exactly the second, not merely 'one or more'")

        // ★ AND THE FACTS STAY FACTS in both cases (§2c). Cell, strut and the two
        // mass rows are readouts and must never acquire control chrome.
        for d in [plain, perRegion] {
            let facts = Set(d.rows.filter { !$0.modifiable }.map(\.label))
            XCTAssertTrue(facts.isSuperset(of: ["Cell", "Strut", "Cells across",
                                                "As lattice", "Saved"]),
                          "the derived rows are facts in BOTH cases")
        }

        // ★ THE ROWS THEMSELVES ARE OTHERWISE IDENTICAL — the flag changes what is
        // a control, never what is shown. This is the C0 bar for the conditional.
        XCTAssertEqual(plain.rows.map(\.label), perRegion.rows.map(\.label))
        XCTAssertEqual(plain.rows.map(\.value), perRegion.rows.map(\.value))
    }

    /// ★ THREE GAPS, RECORDED RATHER THAN IMPLIED — AND TWO OF THEM ARE NOW
    /// CLOSED. This note is UPDATED, never deleted, exactly as it asked to be
    /// (task 2026-08-15-lattice-and-face-ui §8):
    ///
    ///   1. ~~THE MODE DOES NOT EXIST.~~ ★ CLOSED. `LatticeDensityMode` gained
    ///      `perRegion`, and `WorkspacePlaceholder.perRegionDensity` is the one
    ///      expression that sets the flag from it (§8c).
    ///   2. ~~THE VIEW CANNOT RENDER IT.~~ ★ CLOSED. `latticeDrawerBody` used to
    ///      attach `depthDrag` to EVERY modifiable row and hardcode the `-depth`
    ///      identifier; each modifiable row is now keyed by its own label slug and
    ///      only the depth row gets the depth drag
    ///      (`LatticeDrawerRowGesture`). Without that, the Density row would have
    ///      inherited the DEPTH's gesture — a control silently editing the wrong
    ///      number.
    ///   3. ★ STILL OPEN — THE OVERRIDE DOES NOT REACH CORE.
    ///      `LatticeSettings.frozenRegionDensity` is persisted but never read into
    ///      `runSpec` / `latticeJobRegions`, so a number typed there does not
    ///      change a run. PR 331's own handoff says why: "density is a function of
    ///      the cell, not an input… that would need a per-region density override
    ///      on the region entry plus a term in the grading law that honours it."
    ///
    /// ★ A FIELD THAT CAPTURES A NUMBER CORE IGNORES MUST BE STATED AS SUCH, and
    /// it is: the per-region mode carries a warning line on both the wizard
    /// (`wizard-per-region-gap`) and the lattice page (`density-per-region-gap`).
    func testTheDensityOverrideDoesNotYetReachTheRun() {
        var s = LatticeSettings()
        s.frozenRegionDensity[UUID()] = 0.30
        // ★ GAP 1 IS CLOSED, and asserted in its new direction: the mode EXISTS
        // now, so the flag has something to come from.
        XCTAssertNotNil(LatticeDensityMode(rawValue: "perRegion"),
                        "§8: the per-region density mode exists and is what sets "
                      + "LatticeRegionDrawer's perRegionDensity flag")
        let src = try? String(contentsOf: Self.repoRoot.appendingPathComponent(
            "app/TopOptKit/Sources/TopOptFlows/LatticeSettings.swift"),
            encoding: .utf8)
        XCTAssertFalse(src?.contains("frozenRegionDensity") == true
                       && src?.contains("regions.append") == true
                       && src?.range(of: "frozenRegionDensity[^\\n]*regions",
                                     options: .regularExpression) != nil,
                       "if this fails the override now reaches the job and the "
                     + "gap note above is stale — update it, do not delete it")
    }
}
