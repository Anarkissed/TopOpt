// Headless macOS tests for the round-5 keep-clear chip layout (Task A6) — the pure
// decision logic in `ClearanceChipLayout` behind the two maintainer-reported
// readability bugs:
//
//   1. IN-VIEWPORT: a SYNCED group must collapse to ONE shared chip set (the
//      representative primitive), not one chip per primitive (`collapseSynced`).
//   2. SELECTIONS PANEL: a multi-primitive group lists per-primitive lines when
//      unsynced, and one shared set + a "N primitives · synced" count when synced
//      (`rowMode` / `syncedCountLabel` / `kindLabel`).
//
// These stand in for the "layout snapshot" evidence: 1-primitive, 3-mixed-primitive,
// and synced states are each pinned. GPU-free, so they run under `swift test`.

import XCTest
import Foundation
@testable import TopOptFlows

final class ClearanceChipLayoutTests: XCTestCase {

    // A lightweight stand-in for the view's `ClearanceHandleItem` — group + face + the
    // chip kind the collapse groups on.
    private struct Chip: Equatable {
        let group: UUID
        let face: FaceID
        let kind: ClearanceChipKind
    }

    private func collapse(_ chips: [Chip], synced: Set<UUID>) -> [Chip] {
        ClearanceChipLayout.collapseSynced(
            chips,
            group: { $0.group }, face: { $0.face }, kind: { $0.kind },
            isSynced: { synced.contains($0) })
    }

    // MARK: - item 1: in-viewport sync collapse

    /// A single primitive is unaffected by the collapse whether synced or not.
    func testSinglePrimitivePassesThrough() {
        let g = UUID()
        let chips = [Chip(group: g, face: 1, kind: .bore), Chip(group: g, face: 1, kind: .bore)]
        XCTAssertEqual(collapse(chips, synced: [g]), chips)
        XCTAssertEqual(collapse(chips, synced: []), chips)
    }

    /// Sync OFF → every primitive keeps its chips (existing per-primitive behavior).
    func testUnsyncedKeepsEveryPrimitive() {
        let g = UUID()
        // Three planes, each with its own DEPTH chip — the maintainer's duplicate case.
        let chips = [Chip(group: g, face: 10, kind: .plane),
                     Chip(group: g, face: 11, kind: .plane),
                     Chip(group: g, face: 12, kind: .plane)]
        XCTAssertEqual(collapse(chips, synced: []), chips)
    }

    /// Sync ON → the three duplicate DEPTH chips collapse to the FIRST plane only.
    func testSyncedCollapsesDuplicatePlanesToRepresentative() {
        let g = UUID()
        let chips = [Chip(group: g, face: 10, kind: .plane),
                     Chip(group: g, face: 11, kind: .plane),
                     Chip(group: g, face: 12, kind: .plane)]
        XCTAssertEqual(collapse(chips, synced: [g]), [Chip(group: g, face: 10, kind: .plane)])
    }

    /// Sync ON, MIXED kinds → the shared set keeps one bore (its margin+axial chips) and
    /// one plane (its depth chip): first bore + first plane, the rest dropped.
    func testSyncedMixedKeepsFirstBoreAndFirstPlane() {
        let g = UUID()
        // bore face 1 → margin + axial (two chips); bore face 2 → duplicate; plane 3,4.
        let chips = [Chip(group: g, face: 1, kind: .bore),   // margin
                     Chip(group: g, face: 1, kind: .bore),   // axial (same face)
                     Chip(group: g, face: 2, kind: .bore),   // duplicate bore
                     Chip(group: g, face: 3, kind: .plane),  // depth
                     Chip(group: g, face: 4, kind: .plane)]  // duplicate plane
        let out = collapse(chips, synced: [g])
        XCTAssertEqual(out, [Chip(group: g, face: 1, kind: .bore),
                             Chip(group: g, face: 1, kind: .bore),
                             Chip(group: g, face: 3, kind: .plane)])
    }

    /// The collapse is per-group: two synced groups keep their OWN representatives and
    /// never couple, and an unsynced group in the mix keeps all of its chips.
    func testCollapseIsPerGroup() {
        let a = UUID(), b = UUID(), c = UUID()
        let chips = [Chip(group: a, face: 1, kind: .bore), Chip(group: a, face: 2, kind: .bore),
                     Chip(group: b, face: 5, kind: .plane), Chip(group: b, face: 6, kind: .plane),
                     Chip(group: c, face: 8, kind: .bore), Chip(group: c, face: 9, kind: .bore)]
        let out = collapse(chips, synced: [a, b])   // c unsynced
        XCTAssertEqual(out, [Chip(group: a, face: 1, kind: .bore),
                             Chip(group: b, face: 5, kind: .plane),
                             Chip(group: c, face: 8, kind: .bore),
                             Chip(group: c, face: 9, kind: .bore)])
    }

    // MARK: - item 2: selections-panel row mode

    func testRowModeEmpty() {
        XCTAssertEqual(ClearanceChipLayout.rowMode(primitiveCount: 0, synced: true), .none)
        XCTAssertEqual(ClearanceChipLayout.rowMode(primitiveCount: 0, synced: false), .none)
    }

    /// One primitive → the single-line layout regardless of the sync flag (syncing one
    /// primitive is meaningless).
    func testRowModeSingle() {
        XCTAssertEqual(ClearanceChipLayout.rowMode(primitiveCount: 1, synced: true), .single)
        XCTAssertEqual(ClearanceChipLayout.rowMode(primitiveCount: 1, synced: false), .single)
    }

    /// Three mixed primitives, Sync OFF → per-primitive lines (the un-smooshed layout).
    func testRowModeThreeMixedUnsynced() {
        XCTAssertEqual(ClearanceChipLayout.rowMode(primitiveCount: 3, synced: false), .perPrimitive)
    }

    /// Three mixed primitives, Sync ON → the shared set + a count of 3.
    func testRowModeThreeMixedSynced() {
        XCTAssertEqual(ClearanceChipLayout.rowMode(primitiveCount: 3, synced: true),
                       .synced(primitiveCount: 3))
    }

    func testSyncedCountLabel() {
        XCTAssertEqual(ClearanceChipLayout.syncedCountLabel(3), "3 primitives · synced")
        XCTAssertEqual(ClearanceChipLayout.syncedCountLabel(2), "2 primitives · synced")
        // Singular never renders in the UI (synced mode needs count > 1) but the string is correct.
        XCTAssertEqual(ClearanceChipLayout.syncedCountLabel(1), "1 primitive · synced")
    }

    func testKindLabel() {
        XCTAssertEqual(ClearanceChipLayout.kindLabel(.bore), "Bore")
        XCTAssertEqual(ClearanceChipLayout.kindLabel(.plane), "Plane")
    }
}
