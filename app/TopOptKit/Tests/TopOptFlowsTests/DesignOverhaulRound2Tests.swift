// DesignOverhaulRound2Tests.swift — headless coverage for the design-overhaul round 2 layout
// + semantics seams (the maintainer's 15-item punch list). Everything here is pure value/state
// math (the /app/ standard); the pixels (white swoosh arrows, glass see-through, CAD stage,
// glass box) are maintainer device QA, keyed to the punch list in the handoff.

import XCTest
import CoreGraphics
@testable import TopOptFlows

final class DesignOverhaulRound2Tests: XCTestCase {

    // MARK: - Items 2/3/4: gizmo layout — equal insets, centred cube, one size

    /// Item 2: the two arrows and the Home cube share ONE inset from their nearest edges — so
    /// each control's distance to its nearest horizontal AND vertical edge is identical, and all
    /// three match each other.
    func testGizmoControlsShareEqualInset() {
        let s: CGFloat = 210
        let inset = GizmoLayout.controlInset(s)
        let l = GizmoLayout.rotateLeftCenter(s)
        let r = GizmoLayout.rotateRightCenter(s)
        let h = GizmoLayout.homeCenter(s)
        // Distance to nearest edges (min of x,  s−x  and  y,  s−y) equals the one inset.
        func nearest(_ p: CGPoint) -> (CGFloat, CGFloat) { (min(p.x, s - p.x), min(p.y, s - p.y)) }
        for p in [l, r, h] {
            let (nx, ny) = nearest(p)
            XCTAssertEqual(nx, inset, accuracy: 1e-6, "control x-inset differs")
            XCTAssertEqual(ny, inset, accuracy: 1e-6, "control y-inset differs")
        }
        // Mirror symmetry: left/right arrows sit at the same height, mirrored horizontally.
        XCTAssertEqual(l.y, r.y, accuracy: 1e-6)
        XCTAssertEqual(l.x, s - r.x, accuracy: 1e-6)
        // Home shares the arrows' inset but in the bottom-right corner.
        XCTAssertEqual(h.x, r.x, accuracy: 1e-6)
        XCTAssertEqual(h.y, s - inset, accuracy: 1e-6)
    }

    /// Item 3: the housing (and thus the raymarched cube, which renders at the frame centre) has
    /// ZERO offset — the recurring "cube sits high / off-centre" bug is asserted away.
    func testGizmoHousingIsCentred() {
        XCTAssertEqual(GizmoLayout.housingOffset, .zero,
                       "the housing must be centred so the cube sits at the squircle's exact centre")
    }

    /// Item 4: one gizmo size, used on every screen (workspace + results).
    func testGizmoStandardSizeIsShared() {
        XCTAssertEqual(OrientationGizmoView.standardSize, 210)
    }

    /// The inset scales with the widget size (a fraction), so the equal-margin invariant holds
    /// at any point size.
    func testGizmoInsetScalesWithSize() {
        XCTAssertEqual(GizmoLayout.controlInset(400),
                       400 * GizmoLayout.controlInsetFraction, accuracy: 1e-6)
        XCTAssertGreaterThan(GizmoLayout.rotateRightCenter(400).x, GizmoLayout.rotateLeftCenter(400).x)
    }

    // MARK: - Clearance sync (device round 3, items 5+6: per-row membership)

    /// The round-2 `SyncCheckboxState` (hidden / disabled-single-site / active) and the 109 global
    /// toggle are BOTH withdrawn. Sync is per-row now: every keep-clear row carries an
    /// always-enabled checkbox defaulting checked. The membership + fan-out + adopt-on-check
    /// semantics are proven in `ForceModelTests` ("per-row clearance sync membership" block); here
    /// we just pin the default so the row opens checked.
    func testClearanceRowSyncDefaultsChecked() {
        var m = SelectionModel(); m.addGroup()
        let id = m.groups[0].id
        XCTAssertTrue(ForceModel().isClearanceSynced(id), "a fresh keep-clear row opens checked (synced)")
    }

    // MARK: - Item 12: bottom-right chip ordering by measured width, stable

    /// Smallest width sits at the TOP of the list (index 0 in the returned order), largest at the
    /// bottom, so the bottom-anchored stack reads as a tidy width ramp with Optimize beneath.
    func testChipsOrderAscendingByWidth() {
        // handoff 124 added the conditional `.faceProtectDepth` chip; measure it too so
        // this exercises the pure width ramp (its visibility gating is tested elsewhere).
        let widths: [SettingsChipID: CGFloat] = [
            .gravity: 140, .minimizePlastic: 175, .quality: 120, .designBox: 200,
            .faceProtectDepth: 160]
        let order = BottomChipOrder.sorted(SettingsChipID.allCases, widths: widths)
        XCTAssertEqual(order, [.quality, .gravity, .faceProtectDepth, .minimizePlastic, .designBox])
    }

    /// Equal widths keep their default (declaration) order — a stable tie-break.
    func testChipsEqualWidthKeepsDefaultOrder() {
        let widths: [SettingsChipID: CGFloat] = [
            .gravity: 100, .minimizePlastic: 100, .quality: 100, .designBox: 100]
        XCTAssertEqual(BottomChipOrder.sorted(SettingsChipID.allCases, widths: widths),
                       SettingsChipID.allCases)
    }

    /// Before any width is measured (empty dict), the order is the default — no jumping around
    /// on the first frame.
    func testChipsUnmeasuredUseDefaultOrder() {
        XCTAssertEqual(BottomChipOrder.sorted(SettingsChipID.allCases, widths: [:]),
                       SettingsChipID.allCases)
    }

    /// A chip whose width hasn't arrived yet parks at the bottom (treated as maximally wide),
    /// rather than reshuffling the measured ones.
    func testChipsUnmeasuredParksAtBottom() {
        // Measure all but one; the single unmeasured chip parks at the bottom (treated as
        // maximally wide). handoff 124's `.faceProtectDepth` is measured here so `.designBox`
        // is the lone unmeasured one and the intent (unmeasured → last) still reads cleanly.
        let widths: [SettingsChipID: CGFloat] = [
            .quality: 120, .gravity: 130, .minimizePlastic: 150, .faceProtectDepth: 160]
        // .designBox unmeasured → last.
        XCTAssertEqual(BottomChipOrder.sorted(SettingsChipID.allCases, widths: widths).last, .designBox)
    }
}
