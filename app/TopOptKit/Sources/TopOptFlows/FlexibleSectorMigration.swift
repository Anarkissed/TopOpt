// FlexibleSectorMigration — I2's edge strips move from the Surface stage to Flexible-only sectors (task
// 2026-09-29-flexible-screens, round 7 batch M2; the reviewer's ruling 3: "If I2 already writes Surface sectors, move them
// to Flexible-only and say what moved.").
//
// TESTS-FIRST STUB (M2): legacy is recognised; nothing is moved yet.

import Foundation
import TopOptKit

public enum FlexibleSectorMigration {

    /// What the move did, said in plain words (the handoff prints it for his project).
    public struct Report: Equatable, Sendable {
        /// Surface regions removed (id, name).
        public var removed: [(id: Int, name: String)] = []
        /// Flexible pieces made (key, wire id, name).
        public var made: [(key: String, id: Int, name: String)] = []
        /// Re-keys: old id → new id, and what it belongs to ("Face 1", "press <id>").
        public var rekeyed: [(old: Int, new: Int, owner: String)] = []
        /// Chains kept on the Surface stage, with the reason.
        public var kept: [(root: Int, line: String)] = []
        public init() {}
        public var isEmpty: Bool { removed.isEmpty && made.isEmpty && rekeyed.isEmpty && kept.isEmpty }
        public static func == (a: Report, b: Report) -> Bool {
            a.removed.map(\.id) == b.removed.map(\.id) && a.removed.map(\.name) == b.removed.map(\.name)
                && a.made.map(\.key) == b.made.map(\.key) && a.made.map(\.id) == b.made.map(\.id)
                && a.rekeyed.map(\.old) == b.rekeyed.map(\.old) && a.rekeyed.map(\.new) == b.rekeyed.map(\.new)
                && a.kept.map(\.root) == b.kept.map(\.root) && a.kept.map(\.line) == b.kept.map(\.line)
        }
    }

    /// ★ RED CONTROL: no migration — I2's strips stay on the Surface stage (Topology keeps carrying them).
    nonisolated(unsafe) static var controlNoMigration = false

    /// I2's form: no Flexible store, and a strip member carries a Surface root (a project FaceRegion id).
    public static func isLegacy(_ s: FlexibleStageSettings) -> Bool {
        s.sectors == nil && (s.presses ?? []).contains { $0.strip?.members.contains { $0.root >= 0 } ?? false }
    }

    /// ★ THE ONE PLACE Flexible code writes the Surface stage's regions — only to give back what I2 cut there.
    @MainActor
    static func assignRegions(_ project: ProjectModel, _ m: FaceRegionModel) {
        project.faceRegions = m
    }
}
