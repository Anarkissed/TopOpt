// ClearanceSidecar.swift — deletion + manual-primitive persistence next to the
// working-copy file (handoff group-editing, BAR B3).
//
// THE PROBLEM (B3): a deleted auto-found primitive must STAY deleted across a
// re-detect, a resolution change, and a re-import of the same file. If the finder
// re-runs and quietly resurrects it, the feature is worthless.
//
// THE PATTERN (precedent: paint's `model.faces.json`): write a sidecar next to the
// working-copy file and auto-apply it on import. Paint's sidecar is written
// core-side because it must re-segment geometry. A clearance sidecar does NOT need
// the core: the RUN already receives the correct resolved set through job.json
// (the app omits a suppressed face and emits a manual primitive's inline geometry),
// so the CLI / worker never read this file. It exists ONLY so the APP remembers a
// user's deletions + additions when it re-imports the file into a fresh project —
// which is a pure app-side concern. So this is an app-authored JSON sidecar,
// read/written directly, rather than a bridge round-trip. (This is the "show a
// better one" the handoff invites: same guarantee, no core coupling.)
//
// The codec is a pure value type (headlessly unit-tested); the file read/write is
// best-effort (a failure is swallowed — the project's own persisted ForceModel is
// the in-session source of truth; the sidecar is the file-travelling copy).

import Foundation

/// The on-disk clearance sidecar: which auto-found faces were DELETED, and the
/// user-placed primitives, per owning group. Versioned so the format can evolve.
public struct ClearanceSidecar: Equatable, Sendable, Codable {
    /// A group's manual primitives, tagged with the owning group id so a same-file
    /// reload can reattach them (a fresh import with new group ids applies only the
    /// deletion set — the B3 requirement — and drops orphaned manual entries).
    public struct GroupPrimitives: Equatable, Sendable, Codable {
        public var group: UUID
        public var primitives: [ManualPrimitive]
        public init(group: UUID, primitives: [ManualPrimitive]) {
            self.group = group
            self.primitives = primitives
        }
    }

    public var version: Int
    /// Auto-found clearance faces the user deleted (the "−" on an auto row). This is
    /// the B3 payload: a phantom bore stays deleted because import re-applies this.
    public var suppressedAutoFaces: [Int32]
    public var manual: [GroupPrimitives]

    public init(version: Int = 1, suppressedAutoFaces: [Int32] = [],
                manual: [GroupPrimitives] = []) {
        self.version = version
        self.suppressedAutoFaces = suppressedAutoFaces.sorted()
        self.manual = manual
    }

    /// Nothing to persist → the sidecar should be DELETED (so a project cleared back
    /// to defaults leaves no stale file, mirroring paint's empty-overlay delete).
    public var isEmpty: Bool { suppressedAutoFaces.isEmpty && manual.allSatisfy { $0.primitives.isEmpty } }

    // ── File location + IO (best-effort). ────────────────────────────────────
    /// The sidecar path for a working-copy model at `modelPath`: `<modelPath>.clearances.json`
    /// (same "beside the working copy" placement as paint's face-overrides sidecar).
    public static func path(forModelPath modelPath: String) -> String {
        modelPath + ".clearances.json"
    }

    /// Read + decode the sidecar beside `modelPath`, or nil if absent/unreadable.
    public static func read(forModelPath modelPath: String) -> ClearanceSidecar? {
        let p = path(forModelPath: modelPath)
        guard let data = FileManager.default.contents(atPath: p) else { return nil }
        return try? JSONDecoder().decode(ClearanceSidecar.self, from: data)
    }

    /// Write the sidecar beside `modelPath`, or DELETE it when empty. Best-effort.
    @discardableResult
    public func write(forModelPath modelPath: String) -> Bool {
        let p = Self.path(forModelPath: modelPath)
        if isEmpty {
            try? FileManager.default.removeItem(atPath: p)
            return true
        }
        guard let data = try? JSONEncoder().encode(self) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: p))) != nil
    }
}
