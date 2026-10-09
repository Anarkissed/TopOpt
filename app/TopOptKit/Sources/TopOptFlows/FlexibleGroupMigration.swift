// FlexibleGroupMigration — the Settings groups linked to the main page's at PROJECT RESTORE (task
// 2026-09-29-flexible-screens, round 6 item 4; hook H18 in ProjectModel.init(restoring:)).
// TESTS FIRST: the API only — the implementation follows in the next commit.

import Foundation

@MainActor
public enum FlexibleGroupMigration {
    /// RED CONTROL (tests only): restore WITHOUT the migration — his img4 as he saw it.
    public static var controlSkip = false

    /// H18: link the project's Settings groups to its main-page groups (pure on its values, idempotent).
    public static func migrate(_ project: ProjectModel) {}

    /// What the migration did to a project, per face (one line each) — kept for the handoff's table.
    public static func report(for id: UUID) -> [String] { reports[id] ?? [] }
    static var reports: [UUID: [String]] = [:]

    /// The ONE line the main page shows on the project's first Flexible open (then forgotten).
    public static func takeNote(for id: UUID) -> String? { notes.removeValue(forKey: id) }
    static var notes: [UUID: String] = [:]
}
