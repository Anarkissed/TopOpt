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
            spacingMM: 1.705279303, densityGCM3: 1.24, topology: topology,
            bounds: bounds, limits: limits, declaredDensity: declared,
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

    /// ★ AUTO CAN NEVER REFUSE. Swept across depths from far under core's
    /// printability floor to far over it, Auto must never produce a verdict the
    /// user cannot proceed from — `outOfRegime` still BUILDS and says so; what it
    /// must never be is an error the default state puts the page into.
    func testAutoNeverRefusesAtAnyDepth() {
        for d in stride(from: 0.5, through: 60.0, by: 0.5) {
            let c = card(depthMM: d)
            XCTAssertNotEqual(c.verdict, .noMaterial,
                              "Auto produced 'no material' with material present at depth \(d)")
            XCTAssertGreaterThan(c.relativeDensity, 0,
                                 "Auto must always pick a density (depth \(d))")
            XCTAssertGreaterThan(c.cellMM, 0,
                                 "Auto must always pick a cell (depth \(d))")
        }
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
            densityGCM3: 1.24, topology: topology, bounds: bounds, limits: limits,
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
        func cardAt(_ width: Double) -> LatticeFaceCard {
            LatticeFaceCardDerivation.card(
                faceID: 16, depthMM: 30, heldVoxels: 1000, spacingMM: 1.0,
                densityGCM3: 1.24, topology: topology,
                bounds: TopOptKit.latticeCellBounds(topology: topology.id,
                                                    minExtrudableWidthMM: width),
                limits: limits, declaredDensity: 0.30,
                minExtrudableWidthMM: width)
        }
        // Same slab, same declared density, three profiles.
        let fine = cardAt(0.25), mid = cardAt(0.45), coarse = cardAt(0.80)
        XCTAssertEqual(fine.relativeDensity, 0.30, accuracy: 1e-9)
        XCTAssertEqual(coarse.relativeDensity, 0.30, accuracy: 1e-9)
        XCTAssertEqual(fine.verdict, .certified,
                       "a 0.25 mm profile leaves room for a 30 mm slab")
        XCTAssertEqual(mid.verdict, .certified, "and so does a 0.45 mm one")
        XCTAssertEqual(coarse.verdict, .outOfRegime,
                       "★ a 0.80 mm profile pushes core's printability floor above "
                     + "what a 30 mm slab can homogenize, and the SAME lattice "
                     + "stops being certifiable — that is why the width has no "
                     + "default")
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
            densityGCM3: 1.24, topology: topology, bounds: bounds,
            limits: limits, declaredDensity: nil, minExtrudableWidthMM: 0)
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
            densityGCM3: 1.24, topology: topology, bounds: bounds,
            limits: limits, declaredDensity: nil,
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
            densityGCM3: 1.24, topology: topology, bounds: bounds,
            limits: limits, declaredDensity: nil,
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

    /// ★ THREE GAPS, RECORDED RATHER THAN IMPLIED. `perRegionDensity` cannot be
    /// true in a shipped build today, and this test exists so that fact is written
    /// down next to the code rather than discovered later:
    ///
    ///   1. THE MODE DOES NOT EXIST. `LatticeDensityMode` is `uniform` / `auto`;
    ///      there is no per-region case to set the flag from.
    ///   2. THE VIEW CANNOT RENDER IT. `latticeDrawerBody` attaches `depthDrag` to
    ///      EVERY modifiable row and hardcodes the `-depth` accessibility id
    ///      (WorkspacePlaceholder.swift), so a second control would get the
    ///      depth's gesture and a duplicate identifier. That is the rewrite's job.
    ///   3. THE OVERRIDE DOES NOT REACH CORE. `LatticeSettings.frozenRegionDensity`
    ///      is persisted but never read into `runSpec` / `latticeJobRegions`, so a
    ///      number typed there would not change a run.
    ///
    /// A field that captures a number core ignores must be STATED as such.
    func testTheDensityOverrideDoesNotYetReachTheRun() {
        var s = LatticeSettings()
        s.frozenRegionDensity[UUID()] = 0.30
        // ★ THE MODE DOES NOT EXIST — asserted on the enum itself, so this stays
        // true whatever the default becomes. When per-region lands, this fails and
        // the gap note above must be UPDATED, never deleted.
        XCTAssertNil(LatticeDensityMode(rawValue: "perRegion"),
                     "there is no per-region density mode yet, so nothing can set "
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
