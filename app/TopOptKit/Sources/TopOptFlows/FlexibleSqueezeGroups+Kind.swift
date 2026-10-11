// FlexibleSqueezeGroups+Kind — a squeeze group holds FACES or EDGES/CORNERS, never both (task 2026-10-08, round 6 item
// 2; his answer to img2: "a group is EITHER faces OR edges/corners (never mixed)").
//
// ★ THE KIND IS DERIVED (nothing new is saved): a group is `.edges` when it holds an edge or a corner press — a
// FlexiblePress over two or more regions — and `.faces` otherwise (pressed faces, and a tilted face press, which is one
// face). [+ New] asks which on one line ([Faces] [Edges/corners]); a face is never moved into an edges group, a group
// removed hands its members to a group of their own kind, and `normalise` SPLITS a mixed group (a project saved before
// this rule, or one AP1's tests made by hand): its edge and corner presses go to a new group after the last, which then
// takes its own number and colour like any new group.

import Foundation

/// What a squeeze group holds.
public enum FlexibleGroupKind: String, Sendable, Equatable {
    case faces, edges
}

extension FlexibleSqueezeGroups {

    /// ★ RED CONTROL (FlexibleEdgeGroupsTests): a mixed group is left mixed.
    nonisolated(unsafe) static var controlNoSplit = false

    /// ★ A MIXED GROUP SPLIT: every group holding a pressed face (or a tilted face press) AND an edge or corner press
    /// keeps its faces; its edge and corner presses move to a new group, numbered after the last (one new group per
    /// mixed group, in stored order). Called first by `normalise`.
    static func splitMixed(_ s: inout FlexibleStageSettings) {
        _ = controlNoSplit   // I2 RED STUB: a mixed group is left mixed
    }

    /// The group a NEW edges/corners group is stored as: after every group there is.
    public static func nextID(_ s: FlexibleStageSettings) -> Int {
        (groups(s).map(\.id).max() ?? 0) + 1
    }
}
