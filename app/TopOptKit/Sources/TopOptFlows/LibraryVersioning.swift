// LibraryVersioning.swift — Optimize makes the next version (approved Library mockup 2026-10-25, batch 3).
//
// ★ A VERSION'S SETTINGS NEVER CHANGE AFTER IT RAN. Once he has grouped (Library mode), editing a
// version that has results saves into a DRAFT — the next number, "from vN" — and the version's own
// folder keeps the settings its results were made with. One draft per version per session: saving
// again updates it, never a pile. Before he groups, edits save exactly as today.
//
// ★ OPTIMIZE ON A VERSION WITH RESULTS asks "Optimize as vN" (his decision 3), with the automatic name
// he may change; the draft is made (or updated) and runs as it opens (RerunCard.runOnOpen, the path
// today's "Save as new project" uses). The version he came from is left as it ran. There is no
// destructive re-run in Library mode (reviewer ruling 2026-10-26 00:08).
//
// A run he stops with no result leaves its folder without results: a draft again, by definition
// (`LibraryGrouping.isDraft`). The ⌄ next to Open lists the drafts, newest first (decision 6).
// Export from a card opens that version on Smooth with that result, once (`LibraryOpen`).

import Foundation
import TopOptKit

/// What a version's workspace is asked to do as it opens.
@MainActor
public enum LibraryOpen {
    private static var pendingExport: (folder: UUID, result: Int)?
    /// Export from a card: the next workspace that opens `folder` goes to Smooth on `result`.
    public static func exportOnOpen(_ folder: UUID, result: Int) { pendingExport = (folder, result) }
    /// The result to export, exactly once, for the folder that was asked for.
    public static func takeExport(for folder: UUID) -> Int? {
        guard let p = pendingExport, p.folder == folder else { return nil }
        pendingExport = nil
        return p.result
    }
}

/// The "Optimize as vN" card's contents.
public struct NextVersionPreview: Equatable {
    public let number: VersionNumber
    /// The automatic name ("Carriage Arms · v6 · Keep Clear on 2 faces · res 128").
    public let name: String
    public let changes: [VersionChange]
    /// The version it comes from.
    public let from: VersionNumber?
}

/// Whether two snapshots hold the same settings (what a run reads), whatever their ids, names,
/// save times and result flags say.
enum LibrarySettings {
    static func same(_ a: ProjectSnapshot, _ b: ProjectSnapshot) -> Bool {
        var x = normalized(a), y = normalized(b)
        x.id = y.id; x.name = y.name; x.savedAt = y.savedAt
        return x == y
    }
    /// A field a snapshot leaves out means its default (ProjectSnapshot's own back-compat rule), so an
    /// old file and a fresh save of the same setup compare equal.
    private static func normalized(_ s: ProjectSnapshot) -> ProjectSnapshot {
        var x = s
        x.optimized = nil
        x.minimizePlastic = s.minimizePlastic ?? true
        x.quality = s.quality ?? .fast
        x.printParams = s.printParams ?? .fdmDefault
        x.designBox = s.designBox ?? DesignBoxModel()
        x.lattice = s.lattice ?? LatticeSettings()
        x.projectCADFaces = s.projectCADFaces ?? true
        x.faceRegions = s.faceRegions ?? FaceRegionModel()
        return x
    }
}

extension LibraryModel {
    /// Optimize here makes the next version: he has grouped, and this folder holds results.
    public func makesNextVersion(of folder: UUID) -> Bool {
        mode == .library && store.hasPersistedResults(id: folder)
    }

    /// A part's drafts, newest first (the ⌄ next to Open).
    public func drafts(of part: LibraryPart) -> [LibraryVersion] {
        part.versions.filter(isDraft).sorted { $0.number > $1.number }
    }

    /// The card's preview for a draft of `folder` holding `live` (the next number, the automatic name).
    func nextVersionPreview(of folder: UUID, live: ProjectSnapshot, reusing draft: UUID?) -> NextVersionPreview? {
        guard let part = index.part(containing: folder), let v = part.version(folderID: folder),
              let ran = store.snapshot(id: folder) else { return nil }
        let number = draft.flatMap { part.version(folderID: $0)?.number } ?? part.nextNumber(from: v.number)
        let changes = VersionChanges.between(ran, live)
        return NextVersionPreview(number: number,
                                  name: VersionChanges.autoName(part: part.name, number: number, changes: changes,
                                                                resolution: (live.quality ?? .fast).resolution),
                                  changes: changes, from: v.number)
    }

    /// After a draft is written: file it, and keep his own name (the automatic one is not stored).
    func fileDraft(_ draft: UUID, name: String?, auto: String?) {
        refresh()
        guard let name else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != auto, let part = index.part(containing: draft),
              let v = part.version(folderID: draft) else { return }
        // "Carriage Arms · v6 · Fine pass" → "Fine pass"; a name without that prefix is kept whole
        let prefix = "\(part.name) · v\(v.number) · "
        rename(version: draft, to: n.hasPrefix(prefix) ? String(n.dropFirst(prefix.count)) : n)
    }
}

extension AppModel {
    /// The open project's "Optimize as vN" card, or nil when Optimize does not make a next version.
    public func nextVersionPreview() -> NextVersionPreview? {
        guard let project, library.makesNextVersion(of: project.id),
              let live = project.snapshot(savedAt: Date()) else { return nil }
        return library.nextVersionPreview(of: project.id, live: live, reusing: libraryDraft(of: project.id))
    }

    /// Optimize as the next version: write the open version's live settings into its draft (made now,
    /// or the one already made this session) and return it, for the workspace to open and run. The
    /// version itself is left as it ran.
    @discardableResult
    public func optimizeAsNextVersion(id: UUID, name: String?) -> RecentProject? {
        guard let project, project.id == id, let live = project.snapshot(savedAt: Date()) else { return nil }
        let auto = library.nextVersionPreview(of: id, live: live, reusing: libraryDraft(of: id))?.name
        guard let draft = writeLibraryDraft(of: project, live: live) else { return nil }
        library.fileDraft(draft.id, name: name, auto: auto)
        forgetLiveVersion(id)
        return draft
    }
}
