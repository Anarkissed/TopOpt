// LibraryGrouping.swift — files his project folders into parts and versions (approved Library mockup
// 2026-10-25, DATA-MODEL.md "How old copies are grouped").
//
// ★ THE MIGRATION MOVES, COPIES OR DELETES NOTHING. It reads every readable project folder and writes
// one file, library.json. Ungroup removes that file. An unreadable folder is not filed here and stays
// on the Library as "Can't open" (round 3 ruling c).
//
// - Same model bytes (SHA-256) = the same part. A missing model file is a part of its own.
// - Versions are numbered in the order the folders were last saved, oldest first. A folder with no
//   results is a draft (read from its snapshot, never stored twice).
// - His decision 9: the old "copy N" names are dropped. The part is named after the oldest copy;
//   a second part whose name is taken is numbered ("Pad 2").
// - `reconcile` keeps the index honest against the disk every time it is read: a folder it does not
//   list is filed (as the next version of its part, or a new part), and an entry whose folder is gone
//   is dropped. Version numbers are never reused or shifted.

import Foundation
import CryptoKit

public enum LibraryGrouping {

    /// A version is a draft until its folder holds results.
    public static func isDraft(_ s: ProjectSnapshot) -> Bool { s.optimized != true }

    /// "Carriage Arms copy 4" → "Carriage Arms" (ProjectDuplication's copy suffix).
    public static func baseName(_ name: String) -> String {
        guard let r = name.range(of: #" copy( \d+)?$"#, options: .regularExpression) else { return name }
        let base = String(name[..<r.lowerBound])
        return base.isEmpty ? name : base
    }

    /// SHA-256 of a file's bytes as lowercase hex, read in 1 MB pieces; nil when it is missing.
    public static func sha256(fileAt url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        do {
            // nil or empty = the end of the file; a THROW is a read error, and then there is no hash
            while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        } catch { return nil }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// First launch: every readable project becomes one version of the part its model bytes belong to.
    public static func group(_ snapshots: [ProjectSnapshot], hash: (ProjectSnapshot) -> String?) -> LibraryIndex {
        reconcile(LibraryIndex(), with: snapshots, hash: hash)
    }

    /// File the folders the index does not list; drop the entries whose folder is gone.
    public static func reconcile(_ index: LibraryIndex, with snapshots: [ProjectSnapshot],
                                 hash: (ProjectSnapshot) -> String?) -> LibraryIndex {
        var out = index
        let onDisk = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // gone
        for i in out.parts.indices { out.parts[i].versions.removeAll { onDisk[$0.folderID] == nil } }
        let emptied = Set(out.parts.filter { $0.versions.isEmpty }.map(\.id))
        if !emptied.isEmpty {
            out.parts.removeAll { emptied.contains($0.id) }
            for i in out.projects.indices { out.projects[i].partIDs.removeAll { emptied.contains($0) } }
        }

        // new, oldest first
        let known = Set(out.folderIDs)
        let new = snapshots.filter { !known.contains($0.id) }
            .sorted { ($0.savedAt, $0.id.uuidString) < ($1.savedAt, $1.id.uuidString) }
        for s in new {
            let h = hash(s)
            if let h, let p = out.parts.firstIndex(where: { $0.modelHash == h }) {
                let parent = out.parts[p].versions.max { $0.number < $1.number }
                let changes = parent.flatMap { onDisk[$0.folderID] }.map { VersionChanges.between($0, s) } ?? []
                out.parts[p].versions.append(LibraryVersion(folderID: s.id, number: out.parts[p].nextNumber,
                                                            parentNumber: parent?.number, changes: changes))
            } else {
                out.parts.append(LibraryPart(name: freeName(baseName(s.name), in: out.parts), modelHash: h,
                                             versions: [LibraryVersion(folderID: s.id, number: 1)]))
            }
        }
        return out
    }

    /// Group what is on disk now and write library.json; nothing else is written.
    @discardableResult
    public static func groupAndSave(store: ProjectStore) throws -> LibraryIndex {
        let index = group(store.loadAll().readable, hash: { store.modelHash(of: $0) })
        try store.saveLibrary(index)
        return index
    }

    /// "Pad", else "Pad 2", "Pad 3", … — a part's name is never shared by two parts.
    private static func freeName(_ base: String, in parts: [LibraryPart]) -> String {
        let taken = Set(parts.map(\.name))
        guard taken.contains(base) else { return base }
        var k = 2
        while taken.contains("\(base) \(k)") { k += 1 }
        return "\(base) \(k)"
    }
}
