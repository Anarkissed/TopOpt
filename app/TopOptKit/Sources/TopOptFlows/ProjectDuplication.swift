// ProjectDuplication.swift — DUPLICATE / SAVE AS NEW PROJECT.
//
// Lifted from #362 (claude/flexible-screens) at b472880b UNCHANGED below this note (B3, 2026-10-24): the re-run card's
// "Save as new project" needs it on Topology. #362 drops its copy for this one on its next sync of #354.
//
// ★ HIS WORDS (2026-10-24): "… or at the very least be able to copy a project in the library view
// after tapping and holding the project chip."
//
// A copy is the project's SETUP and never its RESULTS. It goes through the store's own `save`, so
// the model file and its sidecars (`.faces`, `.clearances.json`) are copied exactly as an import
// copies them; results.plist, run_job.json and run_design.bin are not written, and `optimized` is
// cleared — the copy opens as "Ready", and a re-run in it retires nothing.
//
// Callers: the Library card's long-press "Duplicate" (hook H51) and the re-run card's
// "Save as new project" (RerunCard), both through `AppModel.duplicateProject` (hook H52).

import Foundation
import TopOptKit

public enum ProjectDuplicationError: Error, Equatable {
    case unreadable(UUID)
}

public enum ProjectDuplication {

    /// "<name> copy", then "<name> copy 2", 3, … — and a copy of a copy counts on from its own
    /// number rather than growing "copy copy".
    public static func copyName(of name: String, existing: [String]) -> String {
        let taken = Set(existing)
        var base = name
        var k = 1
        if let r = name.range(of: #" copy( \d+)?$"#, options: .regularExpression) {
            base = String(name[..<r.lowerBound])
            k = (name[r].split(separator: " ").last.flatMap { Int($0) } ?? 1) + 1
        }
        func label(_ k: Int) -> String { k == 1 ? "\(base) copy" : "\(base) copy \(k)" }
        while taken.contains(label(k)) { k += 1 }
        return label(k)
    }

    /// The Library entry for a freshly made copy.
    public static func recent(for copy: ProjectSnapshot) -> RecentProject {
        RecentProject(id: copy.id, name: copy.name, materialName: copy.material,
                      process: copy.process, optimized: false)
    }
}

extension ProjectStore {

    /// Copy project `id` (setup only) to a new project folder and return the copy's snapshot.
    public func duplicate(id: UUID, newID: UUID = UUID(), name: String,
                          now: Date) throws -> ProjectSnapshot {
        guard var copy = snapshot(id: id) else { throw ProjectDuplicationError.unreadable(id) }
        let model = URL(fileURLWithPath: modelPath(id: id, fileName: copy.modelFileName))
        copy.id = newID
        copy.name = name
        copy.savedAt = now
        copy.optimized = nil
        try save(copy, modelSource: model)
        return copy
    }
}
