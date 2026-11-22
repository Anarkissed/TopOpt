// LibraryOrder.swift — ★ his iPad notes 2026-11-22 (img 1, the part page's version cards), his "yes" to each decision:
//
//   "What is up with this sorting? It should default to the newest at the top - with a whole bottom section for those that
//   have been rejected."  (decision 1)
//   "Tapping on an image/modal should open up the project. If I tap on "v1a" it should automatically open up. If I tap on an
//   image it should automatically open up."  (decision 4)
//
// 1. Newest (the default sort): every version card newest first by when it last changed — its folder's saved time, which
//    every save, every new draft and every copy stamps, so created-or-last-saved is that one date — drafts and running
//    versions mixed in by that date (no longer pinned first), a branch (v1.4 from v1) no longer pinned under its parent.
//    The sort menu's other choices are as they were.
// 2. A version goes into the bottom section "Rejected" only when EVERY one of its results is rejected; one with some
//    rejected and some not stays up top, its rejected result marked as before.
// 3. A tap on a card's picture opens that version in the workspace on its Results (on that result); a tap on a result's
//    name ("v1a") does the same. A draft (no results) or a running version simply opens.

import Foundation

enum LibraryOrder {
    /// Newest first by `changed`; the same moment: the higher version number first.
    static func newestFirst(_ versions: [LibraryVersion], changed: (LibraryVersion) -> Date) -> [LibraryVersion] {
        let when = Dictionary(versions.map { ($0.folderID, changed($0)) }, uniquingKeysWith: { a, _ in a })
        return versions.sorted { a, b in
            let (x, y) = (when[a.folderID] ?? .distantPast, when[b.folderID] ?? .distantPast)
            return x != y ? x > y : a.number > b.number
        }
    }

    /// Every one of its results is rejected. A version with no results yet (a draft, a running one, one still being read)
    /// is not.
    static func allRejected(_ v: LibraryVersion) -> Bool {
        guard let s = v.summary, !s.isEmpty else { return false }
        return s.indices.allSatisfy { v.mark(for: $0).rejected }
    }

    /// The cards up top, then the bottom "Rejected" section — each in the order given.
    static func sections(_ cards: [LibraryVersion]) -> (top: [LibraryVersion], rejected: [LibraryVersion]) {
        (cards.filter { !allRejected($0) }, cards.filter(allRejected))
    }
}

extension LibraryModel {
    /// ★ 11-22: when a version last changed — created or last saved, whichever is later: its folder's saved time.
    func lastChanged(_ v: LibraryVersion) -> Date { snapshots[v.folderID]?.savedAt ?? .distantPast }
}

/// ★ His iPad notes 11-22 (decision 4): a card's picture or a result's name opens the version in the workspace.
@MainActor
enum LibraryCardOpen {
    /// The last open a card asked for (the folder, and the result its Results opens on; nil: it simply opened). Hosted tests
    /// read it: the workspace takes the result as it appears.
    private(set) static var lastAsked: (folder: UUID, result: Int?)?

    /// Open `folder` on its Results, on `result` (nil: the one its card shows) — the Library's own way in (Export from a
    /// card's `LibraryOpen`: the workspace opens Results on that result once its results are in). A draft, a running version
    /// or a Flexible one (its results live on its own page) simply opens.
    static func open(model: AppModel, library: LibraryModel, folder: UUID, result: Int?) {
        guard let recent = model.recentProjects.first(where: { $0.id == folder }) else { return }
        var on: Int? = nil
        if let v = library.version(folder), !library.isDraft(v), !model.runningIDs.contains(folder),
           library.snapshots[folder]?.lattice?.flexible == nil {
            let r = result ?? library.shownResult(v)
            LibraryOpen.exportOnOpen(folder, result: r)
            on = r
        }
        lastAsked = (folder, on)
        model.open(recent)
    }
}
