// EvidenceOut — where an evidence-capture test writes its pictures. The reviewer, 11-06 09:41Z: "Tests must not dirty tracked
// files, because a dirty tree blocks the worktree cleanup." So a capture goes to the same path under the temp folder, and into
// the repo's tracked evidence only when someone regenerates a hand-off's pictures on purpose: TOPOPT_EVIDENCE_TO_REPO=1.
import Foundation

enum EvidenceOut {
    /// The folder for `repoPath` (relative to the worktree root, e.g. "docs/handoffs/assets"), created.
    static func dir(_ repoPath: String, file: StaticString = #filePath) -> URL {
        let base: URL
        if ProcessInfo.processInfo.environment["TOPOPT_EVIDENCE_TO_REPO"] == "1" {
            var root = URL(fileURLWithPath: "\(file)")
            for _ in 0..<5 { root.deleteLastPathComponent() }   // …/app/TopOptKit/Tests/TopOptFlowsTests/X.swift → worktree root
            base = root
        } else {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("topopt-evidence", isDirectory: true)
        }
        let dir = base.appendingPathComponent(repoPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
