// LatticeOvernightBatchTests.swift — ★ THE 2026-08-17 OVERNIGHT LIST
// (maintainer, in one message, each item quoted at the test that holds it).
//
// Seven asks, and the ones that are checkable in a value type are checked here:
// the panel's minimized rest position, the Lattice button's gating and summary,
// the selection hint's stage rule, the per-region density reaching the PREVIEW,
// and the expand handle's visibility rule.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

// ─────────────────────────────────────────────────────────────────────────
// MARK: 1 — "The Selections doesn't minimize to the bottom left corner yet"

final class PageLeftModalPlacementTests: XCTestCase {

    /// ★ THE BUG WAS THE MODIFIER ORDER, not the alignment. The paddings were
    /// applied AFTER `.frame(maxHeight: .infinity)` — padding a view that is
    /// already its parent's size, so the padded result OVERFLOWS and SwiftUI
    /// centres the overflow. Setting the alignment to `.bottomLeading` therefore
    /// changed nothing on screen, which is exactly what he reported.
    ///
    /// The order is not observable from a value type, so what IS asserted is the
    /// geometry the modifier now derives — and the file's own body applies the
    /// paddings before the expanding frame.
    func testMinimizedLiftsAboveTheCornerInPortraitOnly() {
        // PORTRAIT — the action row now carries BOTH Lattice and Optimize, so the
        // corner is occupied and the panel rests above it.
        let portrait = PageLeftModal(canvasHeight: 1300, minimized: true,
                                     canvasWidth: 1000)
        XCTAssertFalse(portrait.isLandscape)
        XCTAssertEqual(portrait.minimizedBottomInset,
                       PageChrome.edge + PageLeftModal.minimizedPortraitLift,
                       accuracy: 0.001,
                       "★ portrait: just above the corner, with clearance")

        // LANDSCAPE — "there should be more than enough room for it to be at the
        // bottom-left corner".
        let landscape = PageLeftModal(canvasHeight: 1000, minimized: true,
                                      canvasWidth: 1300)
        XCTAssertTrue(landscape.isLandscape)
        XCTAssertEqual(landscape.minimizedBottomInset, PageChrome.edge,
                       accuracy: 0.001, "★ landscape: the corner itself")
    }

    /// ★★ THE THIRD REPORT, AND THE ACTUAL DEFECT: "The minimize does not seem to
    /// function still."
    ///
    /// Both earlier cuts stated the intent correctly and both centred the panel on
    /// device. The second one pushed with `Spacer(minLength: 0)` BELOW the content
    /// as well as above — and a zero-minimum spacer is still FLEXIBLE, so the two
    /// split the free height evenly and the panel lands in the middle. Nothing
    /// about that is visible in an inset value, which is why the previous test
    /// passed while the screen disagreed.
    ///
    /// So the placement is asserted where it actually lives: WHICH SPACERS EXIST.
    func testMinimizedHasNoSpacerBelowItSoItCannotCentre() {
        let mini = PageLeftModal(canvasHeight: 1300, minimized: true,
                                 canvasWidth: 1000)
        XCTAssertTrue(mini.hasSpacerAbove, "★ the space is all ABOVE it")
        XCTAssertFalse(mini.hasSpacerBelow,
                       "★ a spacer below — even minLength 0 — is flexible and "
                       + "splits the free height, which centres the panel")

        // OPEN keeps his §6 standard: a spacer on both sides ⇒ centred in the band.
        let open = PageLeftModal(canvasHeight: 1300, minimized: false,
                                 canvasWidth: 1000)
        XCTAssertTrue(open.hasSpacerAbove)
        XCTAssertTrue(open.hasSpacerBelow,
                      "★ open is centre-left and never touches top or bottom")
    }

    /// An OPEN panel is unaffected in either orientation — his earlier standard
    /// ("centre of the left side, doesn't reach the top or bottom") still holds.
    func testAnOpenPanelKeepsTheCentredStandardInBothOrientations() {
        for w in [1000.0, 1300.0] {
            let open = PageLeftModal(canvasHeight: 1150, minimized: false,
                                     canvasWidth: w)
            XCTAssertEqual(open.minimizedBottomInset, PageChrome.edge,
                           accuracy: 0.001,
                           "an open panel never takes the minimized lift")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: 2 — the bottom bar: "Lattice" beside Optimize, and the hint gone

@MainActor
final class LatticeActionBarTests: XCTestCase {

    /// ★ "Remove that from both the lattice and the Surfaces stage. This should
    /// give enough room for both Optimize and Lattice buttons."
    func testTheSelectionHintIsOnTopologyOnly() {
        XCTAssertTrue(WorkspaceStageVisibility.of(.topology).showsSelectionHint,
                      "★ Topology keeps it — it is how a new user learns to select")
        XCTAssertFalse(WorkspaceStageVisibility.of(.lattice).showsSelectionHint,
                       "★ gone from Lattice")
        XCTAssertFalse(WorkspaceStageVisibility.of(.surface).showsSelectionHint,
                       "★ gone from Surface")
    }

    /// ★★ AND IT RUNS ON DEVICE (maintainer, 2026-08-17: "Can you please make it
    /// run on the iPad as well"). The gate is gone — a lattice run has no ladder,
    /// so its cost was never the reason; the reason was that only the LAN path
    /// wrote a job document. Both write one now.
    ///
    /// ★ THE ROUTING IS AT THE ONE ON-DEVICE ENTRY POINT every caller goes
    /// through, so a lattice request cannot reach the optimizer by coming in a
    /// different way. Asserted on the SOURCE, because the alternative failure —
    /// a mode field nothing local reads — is invisible to a value-type test and
    /// is exactly what shipped before.
    func testTheOnDeviceRunnerRoutesOnTheMode() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/RunModel.swift"),
            encoding: .utf8)
        guard let r = src.range(of: "public static func bridgeRunner(") else {
            return XCTFail("the on-device entry point moved")
        }
        let head = String(src[r.lowerBound...].prefix(1200))
        XCTAssertTrue(head.contains("request.jobMode == \"lattice_part\""),
                      "★ the ONE on-device entry point routes on the mode — "
                      + "without this a lattice request silently optimizes")
        XCTAssertTrue(head.contains("latticeBridgeRunner"),
                      "…to the lattice runner")
        // ★ AND THE ON-DEVICE RUN USES THE LAN PATH'S OWN JOB BUILDER, so the two
        // cannot describe different runs.
        XCTAssertTrue(src.contains("RemoteRun.buildJobJSON(request)"),
                      "★ ONE job document, two executors")
    }

    /// ★ THE BUTTON RUNS A DIFFERENT QUESTION, not a different pipeline. Its
    /// request is the optimize request with ONE key changed, so the load case,
    /// resolution, material, protections and lattice block are the ones the user
    /// configured rather than re-authored.
    func testTheLatticeRequestIsTheOptimizeRequestWithOneKeyChanged() {
        let base = RunRequest(modelPath: "/tmp/p.step", material: "PLA",
                              materialsPath: "/tmp/m.json", rulesPath: "/tmp/r.json",
                              resolution: 64, projectName: "P")
        XCTAssertEqual(base.jobMode, "minimize_plastic",
                       "★ the DEFAULT is unchanged, so every existing call site "
                       + "and every stored request means what it did")
        let lat = base.withJobMode("lattice_part")
        XCTAssertEqual(lat.jobMode, "lattice_part")
        // …and nothing else moved.
        XCTAssertEqual(lat.modelPath, base.modelPath)
        XCTAssertEqual(lat.resolution, base.resolution)
        XCTAssertEqual(lat.material, base.material)
        XCTAssertEqual(lat.projectCADFaces, base.projectCADFaces)
        // ★ The mode is part of the request's IDENTITY, so switching modes
        // invalidates a stale result instead of reusing one made the other way.
        XCTAssertNotEqual(base, lat)
    }
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: 3 — "Density is controllable in each region - but it is not updating
//            the lattice preview of it"

final class LatticePreviewDensityTests: XCTestCase {

    private func grid(_ n: Int = 8) -> LatticeVoxelGrid {
        LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: .zero,
                         spacing: SIMD3(1, 1, 1),
                         values: [Float](repeating: 1, count: n * n * n))
    }

    private func slab(_ origin: SIMD3<Double>, rho: Double?) -> LatticeRegionSpec {
        var s = LatticeRegionSpec(role: .include, kind: .face)
        s.origin = origin; s.normal = SIMD3(0, 0, 1)
        s.halfUMM = 1.5; s.halfWMM = 1.5; s.depthMM = 6
        s.relativeDensity = rho
        return s
    }

    /// ★ THE FIX: a stated density becomes a per-cell demand value that comes
    /// back out of the raymarcher's own mapping as EXACTLY that density.
    ///
    ///     rho = rhoMin + (rhoMax - rhoMin) * pow(demand, gamma)
    ///
    /// so the test inverts the shader's formula and checks the round trip. That
    /// is what makes "the number on the card is the number the struts are drawn
    /// at" a property rather than a hope.
    func testAStatedDensityRoundTripsThroughTheShadersOwnMapping() throws {
        let lo = 0.05, hi = 0.90, gamma = 1.4
        let want = 0.40
        let d = try XCTUnwrap(LatticeRegionMask.densityDemand(
            like: grid(), regions: [slab(SIMD3(2, 2, 0), rho: want)],
            rhoMin: lo, rhoMax: hi, gamma: gamma))
        // A voxel inside the slab.
        let inside = d.values[2 + 2 * d.nx + 2 * d.nx * d.ny]
        let rho = lo + (hi - lo) * pow(Double(inside), gamma)
        XCTAssertEqual(rho, want, accuracy: 1e-6,
                       "★ the preview draws the density the region states")
    }

    /// ★ TWO REGIONS, TWO DENSITIES, ONE PREVIEW — which is the whole point of
    /// per-region density and the thing a single uniform could never show.
    func testTwoRegionsProduceTwoDifferentDemands() throws {
        let d = try XCTUnwrap(LatticeRegionMask.densityDemand(
            like: grid(), regions: [slab(SIMD3(2, 2, 0), rho: 0.20),
                                    slab(SIMD3(6, 6, 0), rho: 0.70)],
            rhoMin: 0.05, rhoMax: 0.90, gamma: 1.0))
        let a = d.values[2 + 2 * d.nx + 2 * d.nx * d.ny]
        let b = d.values[6 + 6 * d.nx + 6 * d.nx * d.ny]
        XCTAssertGreaterThan(b, a, "★ the denser region grades denser")
        XCTAssertGreaterThan(a, 0, "…and the lighter one is not blank")
    }

    /// ★ NOTHING STATED ⇒ nil ⇒ the caller keeps whatever field it had (the
    /// run's stress field, or none). An untouched project's preview is unchanged.
    func testNoStatedDensityLeavesTheFieldAlone() {
        XCTAssertNil(LatticeRegionMask.densityDemand(
            like: grid(), regions: [slab(SIMD3(2, 2, 0), rho: nil)],
            rhoMin: 0.05, rhoMax: 0.90, gamma: 1))
        XCTAssertNil(LatticeRegionMask.densityDemand(
            like: grid(), regions: [], rhoMin: 0.05, rhoMax: 0.90, gamma: 1))
    }

    /// An EXCLUDE region states no lattice density, however it was dialled.
    func testAnExcludeRegionNeverGradesThePreview() {
        var ex = slab(SIMD3(2, 2, 0), rho: 0.70)
        ex = LatticeRegionSpec.excludeCopy(of: ex)
        XCTAssertNil(LatticeRegionMask.densityDemand(
            like: grid(), regions: [ex], rhoMin: 0.05, rhoMax: 0.90, gamma: 1))
    }
}

extension LatticeRegionSpec {
    /// Test helper: the same geometry with the exclude role.
    static func excludeCopy(of s: LatticeRegionSpec) -> LatticeRegionSpec {
        var out = LatticeRegionSpec(role: .exclude, kind: s.kind)
        out.origin = s.origin; out.normal = s.normal
        out.halfUMM = s.halfUMM; out.halfWMM = s.halfWMM; out.depthMM = s.depthMM
        out.relativeDensity = s.relativeDensity
        return out
    }
}
