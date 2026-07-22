// ClearanceChipLayout.swift — round-5 keep-clear chip layout (Task A6).
//
// Two maintainer-reported readability bugs, both about a group that holds SEVERAL
// keep-clear primitives (bores and/or planes):
//
//   1. IN-VIEWPORT: with the group's Sync ON every primitive shares one value, yet
//      the model drew one chip PER primitive — so the maintainer's device showed
//      duplicate "DEPTH 3 mm" chips stacked on top of each other. When synced the
//      group must show ONE shared chip set, anchored to a deterministic
//      representative (the FIRST primitive of each kind, in selection order).
//
//   2. SELECTIONS PANEL: a group with mixed primitives (bore → margin+axial,
//      plane → depth) crushed every chip into one HStack that wrapped into an
//      unreadable vertical smoosh. Each primitive now lists on its OWN line
//      (kind label + its chips); with Sync ON the row collapses to the one shared
//      set plus a "N primitives · synced" count.
//
// This file is the PURE decision logic behind both — no SwiftUI, no mesh, no GPU —
// so the representative-collapse and the mode/label choices are unit-tested
// headlessly (the /app/ verification standard). The view (`WorkspacePlaceholder`)
// supplies the geometry-classified primitives and renders over these decisions.

import Foundation

/// Which keep-clear primitive a chip belongs to, for the sync-collapse grouping. A
/// bore contributes margin/axial chips; a plane contributes a depth chip.
public enum ClearanceChipKind: Hashable, Sendable {
    case bore
    case plane
}

public enum ClearanceChipLayout {

    /// IN-VIEWPORT sync collapse (Task A6 item 1). Filters on-model chip descriptors
    /// so a SYNCED group shows only its REPRESENTATIVE primitive's chips — the first
    /// primitive of each kind in `items` order (bores collapse to the first bore,
    /// planes to the first plane) — while an UNSYNCED group keeps every primitive's
    /// chips (the existing per-primitive behaviour). Order is preserved.
    ///
    /// The representative is deterministic (first-in-order, not camera-dependent) so
    /// the collapse is testable headlessly and never flickers as the camera orbits.
    /// The drag KNOBS are intentionally NOT collapsed — every wall/cap/face stays
    /// grabbable; only the redundant value labels are removed.
    /// The identity a synced group's representative is tracked under — one per (group,
    /// kind), so bores and planes collapse independently.
    private struct RepKey: Hashable { let group: UUID; let kind: ClearanceChipKind }

    public static func collapseSynced<Item>(
        _ items: [Item],
        group: (Item) -> UUID,
        face: (Item) -> FaceID,
        kind: (Item) -> ClearanceChipKind,
        isSynced: (UUID) -> Bool
    ) -> [Item] {
        var representative: [RepKey: FaceID] = [:]
        return items.filter { item in
            let g = group(item)
            guard isSynced(g) else { return true }
            let key = RepKey(group: g, kind: kind(item))
            if let rep = representative[key] { return face(item) == rep }
            representative[key] = face(item)
            return true
        }
    }

    /// SELECTIONS-PANEL row layout (Task A6 item 2). Given how many keep-clear
    /// primitives a group carries and whether it is synced, decide how the row lays
    /// its clearance chips out.
    public enum RowMode: Equatable, Sendable {
        /// No keep-clear primitives → the row draws no clearance chips.
        case none
        /// Exactly one primitive → a single line (kind label + its chips); syncing is
        /// meaningless for one primitive, so no Sync box and no count.
        case single
        /// Several primitives, Sync OFF → one line PER primitive, the row grows tall.
        case perPrimitive
        /// Several primitives, Sync ON → the one shared chip set plus a count.
        case synced(primitiveCount: Int)
    }

    /// The row mode for a group's keep-clear primitives.
    public static func rowMode(primitiveCount: Int, synced: Bool) -> RowMode {
        switch primitiveCount {
        case ..<1: return .none
        case 1: return .single
        default: return synced ? .synced(primitiveCount: primitiveCount) : .perPrimitive
        }
    }

    /// The synced-collapse count label — "3 primitives · synced" (singular "primitive"
    /// never occurs here because the synced mode is only chosen for count > 1).
    public static func syncedCountLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "primitive" : "primitives") · synced"
    }

    /// The per-primitive kind label leading each line of an unsynced multi-primitive
    /// row (and the single-primitive row).
    public static func kindLabel(_ kind: ClearanceChipKind) -> String {
        switch kind {
        case .bore: return "Bore"
        case .plane: return "Plane"
        }
    }
}
