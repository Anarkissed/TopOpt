// VersionMoves.swift — ★ his iPad notes 2026-11-23 on versions (RESULTS_REPORT §5, §7):
//   "A new version should be made withOUT the export as soon as ANY changes are made onto the version the result is on."
//   "Tapping on "v7 draft" should open up two options: Save, and Save and Start a New Version - which saves what is currently
//    done to v7, then creates a v8 or v7.1 ... for the user to start up changes and save whenever."
//   "When I open up an old Lattice job ... all the settings should already be saved. Currently it resets the Lattice settings
//    each time I jump into a version"
//
// So a version that holds a result (Topology's or a lattice's) is never edited: the FIRST change of any setting writes the
// next version (VersionNumber's rules: from the newest main-line version the next main number, from an older one a branch),
// and the workspace MOVES to it in place — the same live project, the same screen, the same panels; only the number in the top
// bar changes. The result stays on its own version, untouched; whatever runs next (Optimize, the Lattice button) runs on the
// new version. The edits are never parked in a draft the workspace does not show (what made reopening look like a reset).
//
// "Save and start a new version" does the same from the version chip's menu: what is on screen is saved to this version, the
// next version is made from it, and the workspace moves there.
//
// A pick (the active group, a folded region, the load scenario shown) is not a setting: it never makes a version.
import Foundation
import Combine
import SwiftUI
import TopOptKit

// MARK: - what counts as a change

/// Whether two snapshots hold the same SETTINGS — `LibrarySettings.same` (ids, names, save times, result flags left out), with
/// the picks left out too: the active group of either list, a region folded or open in a panel, the load scenario shown.
enum VersionSettings {
    static func same(_ a: ProjectSnapshot, _ b: ProjectSnapshot) -> Bool {
        LibrarySettings.same(picksLeftOut(a), picksLeftOut(b))
    }

    static func picksLeftOut(_ s: ProjectSnapshot) -> ProjectSnapshot {
        var x = s
        x.selection.clearActive()
        if var lat = x.lattice, var l = lat.latticeList {
            l.keepWhenEmpty(lat.zoneGroups)   // (a zone is a shape, never swept: LatticeList.latticeList's own rule)
            l.clearActive()
            lat.latticeList = l
            x.lattice = lat
        }
        if var r = x.faceRegions {
            for reg in r.regions where !reg.collapsed { r.setCollapsed(reg.id, true) }
            x.faceRegions = r
        }
        if var sc = x.force.scenarios, let first = sc.scenarios.first?.id {
            sc.activeID = first
            x.force.scenarios = sc
        }
        return x
    }
}

// MARK: - the link from a version to its draft, kept across launches

/// ★ RESULTS_REPORT §7 ("The draft link lives for the session only, so each session makes another draft"): which draft each
/// version's edits went to, in the store's own folder (beside library.json), so it survives relaunch. A link is used only while
/// its draft is still there and still has no result of its own (never a version that ran).
enum VersionDraftLinks {
    static let fileName = "version_drafts.json"
    static func url(_ store: ProjectStore) -> URL { store.rootDir.appendingPathComponent(fileName) }

    static func read(_ store: ProjectStore) -> [UUID: UUID] {
        guard let data = try? Data(contentsOf: url(store)),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var out: [UUID: UUID] = [:]
        for (k, v) in raw { if let a = UUID(uuidString: k), let b = UUID(uuidString: v) { out[a] = b } }
        return out
    }

    static func write(_ links: [UUID: UUID], _ store: ProjectStore) {
        let raw = Dictionary(uniqueKeysWithValues: links.map { ($0.key.uuidString, $0.value.uuidString) })
        if raw.isEmpty { try? FileManager.default.removeItem(at: url(store)); return }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? FileManager.default.createDirectory(at: store.rootDir, withIntermediateDirectories: true)
        try? data.write(to: url(store), options: .atomic)
    }

    /// The linked draft, if it may take more edits: its folder is there and it holds no result.
    static func usable(_ draft: UUID?, _ store: ProjectStore) -> UUID? {
        guard let draft, store.holdsProject(id: draft), !store.hasPersistedResults(id: draft) else { return nil }
        return draft
    }
}

// MARK: - the moves

extension ProjectModel {
    /// ★ his iPad notes 11-23: this live version becomes `folder` (a new version's, just written) — its model read from that
    /// folder (its sidecars are written there from now on, never into the version it was), the result it held dropped (it is
    /// the old version's, on disk). Nothing else changes: the screen stays as it is.
    func becomeVersion(_ folder: UUID, modelPath: String) {
        objectWillChange.send()
        id = folder
        if let f = importedFile {
            importedFile = ImportedFile(name: f.name, path: modelPath, triangleCount: f.triangleCount, faceCount: f.faceCount,
                                        watertight: f.watertight, pseudoFaces: f.pseudoFaces)
        }
        run.reset()
    }
}

extension AppModel {
    /// ★ his iPad notes 11-23 (§5): the open version holds a result and a setting changed since it was saved — the next version
    /// is made now (no export, no question) and the workspace moves to it. `baseline`: the live settings as the page opened (a
    /// change the page made by itself as it opened is never his). True: moved.
    @discardableResult
    public func moveToNextVersionIfEdited(_ project: ProjectModel, baseline: ProjectSnapshot? = nil) -> Bool {
        guard !Self.controlEditsInPlace, self.project === project, library.makesNextVersion(of: project.id),
              project.run.phase != .running, !runningIDs.contains(project.id),
              let ran = library.store.snapshot(id: project.id), let live = project.snapshot(savedAt: Date()),
              !VersionSettings.same(ran, live), !(baseline.map { VersionSettings.same($0, live) } ?? false) else { return false }
        return startNextVersion(project, live: live, keepPreview: false) != nil
    }
    /// RED CONTROL (VersionNotes1123Tests): edits stay on the version with the result (today's draft on Back, the re-run card).
    @MainActor static var controlEditsInPlace = false

    /// ★ his iPad notes 11-23: the version chip's "Save" — what is on screen, saved (to the version it is on now).
    public func saveVersion() {
        guard let project else { return }
        persistCurrentProject()
        if let v = library.version(project.id) { toast = VersionChipCopy.saved("v\(v.number)") }
    }

    /// ★ his iPad notes 11-23: the version chip's "Save and start a new version" — saved, then the next version made from it, the
    /// workspace on it. nil: nothing open, before he groups, or a run in flight.
    @discardableResult
    public func saveAndStartNewVersion() -> RecentProject? {
        guard let project, library.mode == .library, library.version(project.id) != nil,
              project.run.phase != .running, !runningIDs.contains(project.id) else { return nil }
        persistCurrentProject()   // (an edit on a version with a result has moved it already: this saves the new one)
        guard let live = project.snapshot(savedAt: Date()) else { return nil }
        let made = startNextVersion(project, live: live, keepPreview: true)
        if made == nil { AppPopups.shared.show(VersionChipCopy.failedTitle, VersionChipCopy.failedText) }
        return made
    }

    /// A new version's folder from `live` (never a draft already linked), numbered from the open version, and the live project
    /// moved onto it. `keepPreview`: its settings are the version's own, so the laid lattice's store goes with it.
    private func startNextVersion(_ project: ProjectModel, live: ProjectSnapshot, keepPreview: Bool) -> RecentProject? {
        let from = project.id
        guard let made = writeLibraryDraft(of: project, live: live, fresh: true) else { return nil }
        if keepPreview { LatticePreviewStore.copy(from: from, to: made.id, store: library.store) }
        moveLive(project, to: made.id, modelFileName: live.modelFileName)
        library.refresh()
        VersionEditWatch.shared.rebase(project)   // the new version's own settings are its baseline now
        return made
    }
}

extension WorkspacePlaceholder {
    /// ★ his iPad notes 11-23: before a run (Optimize, the Lattice button) — an edit on a version with a result moves the page
    /// to the next version first, so the run is that version's (no re-run card: the result it had stays on its own version).
    func moveOnIfEdited() {
        model.moveToNextVersionIfEdited(project, baseline: VersionEditWatch.shared.baseline(for: project))
    }
}

// MARK: - watching the open version (the first change)

/// ★ his iPad notes 11-23: the workspace's watch on its version — a change (settled for a moment) on a version with a result
/// moves the workspace to the next version (`AppModel.moveToNextVersionIfEdited`). One at a time: the open workspace's.
@MainActor
final class VersionEditWatch {
    static let shared = VersionEditWatch()
    private weak var project: ProjectModel?
    private weak var model: AppModel?
    private var sub: AnyCancellable?
    private var scheduled = false
    /// The live settings as the page opened, and until it settles (`settleS`): what the page does by itself is not his.
    private var baseline: ProjectSnapshot?
    private var settlesAt = Date.distantPast
    static let settleS: TimeInterval = 1.0
    static let waitS: TimeInterval = 0.25

    /// A page opened on `project` (again, too: its settings as it opens are the baseline).
    func watch(_ project: ProjectModel, model: AppModel) {
        if self.project !== project || sub == nil {
            self.project = project
            sub = project.objectWillChange.sink { [weak self] _ in self?.changed() }
        }
        self.model = model
        baseline = project.snapshot(savedAt: Date())
        settlesAt = Date().addingTimeInterval(Self.settleS)
    }

    /// The watched version moved to its next one: its settings now are where its changes count from.
    func rebase(_ project: ProjectModel) {
        guard self.project === project else { return }
        baseline = project.snapshot(savedAt: Date())
    }

    /// The page's own settings as it opened (nil: another project is watched).
    func baseline(for project: ProjectModel) -> ProjectSnapshot? { self.project === project ? baseline : nil }

    func stop(_ project: ProjectModel) {
        guard self.project === project else { return }
        sub = nil; self.project = nil; self.model = nil; baseline = nil
    }

    /// A change is coming: looked at once it has landed (the next turn of the run loop and a moment more), never per tick.
    private func changed() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.waitS) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.check()
        }
    }

    func check() {
        guard let project, let model, model.project === project else { return }
        if Date() < settlesAt {   // the page opening: what it set by itself is the baseline
            baseline = project.snapshot(savedAt: Date())
            return
        }
        model.moveToNextVersionIfEdited(project, baseline: baseline)
    }
}
