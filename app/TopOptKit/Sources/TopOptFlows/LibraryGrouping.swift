// LibraryGrouping.swift — files his project folders into parts and versions (approved Library mockup
// 2026-10-25, DATA-MODEL.md "How old copies are grouped").
//
// ★ THE MIGRATION MOVES, COPIES OR DELETES NOTHING. It reads every readable project folder and writes
// one file, library.json. Ungroup removes that file. An unreadable folder is not filed here and stays
// on the Library as "Can't open" (round 3 ruling c).
//
// - Same model bytes (SHA-256) = the same part. A missing or EMPTY model file is a part of its own.
// - Versions are numbered in the order the folders were last saved, oldest first. A folder with no
//   results is a draft (read from its snapshot, never stored twice).
// - His decision 9: the old "copy N" names are dropped. The part is named after the oldest project; a
//   project he named differently ("Bracket light" beside "Bracket stiff") keeps that name as its
//   version's name. A second part whose name is taken is numbered ("Pad 2").
// - `reconcile` keeps the index honest against the disk: a folder it does not list is filed (as the
//   next version of its part, or a new part), and an entry is dropped ONLY when its folder is gone.
//
// ★ AUDIT 2026-10-25 (the one independent check): his marks, names and numbers live only here, so
// - a folder that is there but unreadable for a while KEEPS its entry ("Can't open" is not "gone");
// - a root that cannot be listed changes nothing;
// - a number is never given twice (`LibraryPart.lastNumber` survives deleting the newest);
// - a folder is filed once, however often it is listed;
// - an existing library.json is never replaced by a fresh grouping: a readable one is reconciled, an
//   unreadable or newer one is left exactly as it is.

import Foundation
import CryptoKit

public enum LibraryGroupingError: Error, Equatable {
    /// library.json is there but cannot be read (corrupt, or saved by a newer TopOpt). It is left alone.
    case unreadableIndex(String)
}

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

    /// The hash of no bytes: an empty model file says nothing about which part it is.
    static let emptyHash = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()

    /// First launch: every readable project becomes one version of the part its model bytes belong to.
    public static func group(_ snapshots: [ProjectSnapshot], hash: (ProjectSnapshot) -> String?) -> LibraryIndex {
        reconcile(LibraryIndex(), with: snapshots, hash: hash, exists: { _ in true })
    }

    /// File the folders the index does not list; drop the entries whose folder is GONE (`exists` is
    /// false). An entry whose folder is there but not in `snapshots` (unreadable for now) is kept as it is.
    /// `parents` names the version a new folder was made FROM (a draft, "New draft from vN"): it is
    /// numbered from that one (his decision 11: v4 → v4.1). A folder with none continues the main line.
    public static func reconcile(_ index: LibraryIndex, with snapshots: [ProjectSnapshot],
                                 hash: (ProjectSnapshot) -> String?,
                                 exists: (UUID) -> Bool,
                                 parents: [UUID: UUID] = [:]) -> LibraryIndex {
        var out = index
        let onDisk = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // listed twice: keep the first entry
        var seen = Set<UUID>()
        for i in out.parts.indices {
            out.parts[i].versions.removeAll { !seen.insert($0.folderID).inserted }
        }
        // gone: only when the folder itself is not there
        for i in out.parts.indices {
            let gone = out.parts[i].versions.filter { onDisk[$0.folderID] == nil && !exists($0.folderID) }
            for v in gone { out.parts[i].forget(v) }
        }
        let emptied = Set(out.parts.filter { $0.versions.isEmpty }.map(\.id))
        if !emptied.isEmpty {
            out.parts.removeAll { emptied.contains($0.id) }
            for i in out.projects.indices { out.projects[i].partIDs.removeAll { emptied.contains($0) } }
        }

        // new, oldest first (the id breaks a tie, so the order is the same every time), each once
        var known = Set(out.folderIDs)
        let new = onDisk.values.filter { !known.contains($0.id) }
            .sorted { ($0.savedAt, $0.id.uuidString) < ($1.savedAt, $1.id.uuidString) }
        for s in new where known.insert(s.id).inserted {
            let h = hash(s).flatMap { $0 == emptyHash ? nil : $0 }
            if let h, let p = out.parts.firstIndex(where: { $0.modelHash == h }) {
                let stated = parents[s.id].flatMap { out.parts[p].version(folderID: $0) }
                let parent = stated ?? out.parts[p].newestMainLine
                let changes = parent.flatMap { onDisk[$0.folderID] }.map { VersionChanges.between($0, s) } ?? []
                let own = baseName(s.name)
                out.parts[p].versions.append(LibraryVersion(folderID: s.id, number: out.parts[p].nextNumber(from: parent?.number),
                                                            parentNumber: parent?.number,
                                                            name: own == out.parts[p].name ? nil : own,
                                                            changes: changes))
            } else {
                out.parts.append(LibraryPart(name: freeName(baseName(s.name), in: out.parts), modelHash: h,
                                             versions: [LibraryVersion(folderID: s.id, number: 1)]))
            }
        }
        return out
    }

    /// The app's call: reconcile against the store as it is now. When the root cannot be listed at all
    /// (a transient error, data protection before first unlock), nothing changes.
    public static func reconcile(_ index: LibraryIndex, store: ProjectStore, parents: [UUID: UUID] = [:]) -> LibraryIndex {
        guard let present = store.folderIDsOnDisk() else { return index }
        return reconcile(index, with: store.loadAll().readable, hash: { store.modelHash(of: $0) },
                         exists: { present.contains($0) }, parents: parents)
    }

    /// First launch, and every launch after: group when there is no index; reconcile a readable one
    /// (written only when something changed); never touch one that cannot be read. Nothing but
    /// library.json is ever written.
    @discardableResult
    public static func groupAndSave(store: ProjectStore) throws -> LibraryIndex {
        switch store.libraryState() {
        case .missing:
            guard store.folderIDsOnDisk() != nil else { return LibraryIndex() }
            let index = group(store.loadAll().readable, hash: { store.modelHash(of: $0) })
            try store.saveLibrary(index)
            return index
        case let .readable(existing):
            let index = reconcile(existing, store: store)
            if index != existing { try store.saveLibrary(index) }
            return index
        case let .unreadable(why):
            throw LibraryGroupingError.unreadableIndex(why)
        }
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
