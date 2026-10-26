// LibraryModel.swift — what the Library screens read and change (approved Library mockup 2026-10-25,
// batch 2). The index is LibraryIndex (batch 1); this is its one owner on screen.
//
// ★ THE LIBRARY ASKS BEFORE GROUPING. With projects on disk and no library.json, the Library stays
// today's flat Home until he taps Group on the first-launch sheet (screen 9); Not now keeps it so. An
// index that cannot be read (corrupt, or a newer TopOpt's) also shows today's Home and is never
// written. So today's Home — and #362's hooks H46 / H51 on it — keep working exactly where they did.
//
// - Marks are per result: stars in half steps (the same star again clears it), Print this, Rejected
//   (his decision 1: no Favourite). A rejected result is not for print, and the other way round.
// - A card's numbers and pictures come from each version's OWN results file, read once in the
//   background: the numbers are kept in the index (`summary`), the pictures in LibraryCache/.
// - The suggested result is the Results screen's rule: the last result that passes.
// - A new part joins the project chosen on the import sheet (`importTargetProject`), used once.
// - Storage: all of a version's results are kept while one is rated ★4+ or marked Print this, and for
//   the newest 2 versions with results. Trim (always his tap) keeps only the result he picked; his
//   marks on it follow it, and the run's design file goes (its results no longer match it) while the
//   run's job stays, so Smooth still works.

import Foundation
import CoreGraphics
import ImageIO
import TopOptKit

public enum LibraryMode: Equatable, Sendable {
    /// Today's flat Home (no index yet, or he chose Not now). The first-launch sheet offers grouping.
    case flat
    /// Project → Part → Version.
    case library
    /// library.json is there but can't be read: today's Home, a note why, and the file left alone.
    case unreadable(String)
}

/// One result of a version, read from its results file.
public struct LibraryResult: Identifiable {
    public let index: Int
    public let mesh: ViewerMesh
    public let massGrams: Double
    public let margin: Double
    /// The printed fraction of the part as drawn (1.03 = 103 %), the Results screen's basis.
    public let fraction: Double
    public let accepted: Bool
    public var id: Int { index }
}

@MainActor
public final class LibraryModel: ObservableObject {
    public let store: ProjectStore
    @Published public private(set) var index = LibraryIndex()
    @Published public private(set) var mode: LibraryMode = .flat
    /// Every readable project folder, by id.
    @Published public private(set) var snapshots: [UUID: ProjectSnapshot] = [:]
    /// One picture per result, rendered from its mesh.
    @Published public private(set) var thumbnails: [CompareItem: CGImage] = [:]
    /// The project the next new part joins (the import sheet's Project row). Used once.
    @Published public var importTargetProject: UUID?
    /// The proposal shown on the first-launch sheet, so Group saves exactly what he saw.
    private var lastProposal: LibraryIndex?
    /// The last few versions' decoded results (each can be tens of MB).
    private var resultsCache: [UUID: [LibraryResult]] = [:]
    private var resultsOrder: [UUID] = []
    private var loadingSummaries = false
    /// The version each new folder was made FROM (a draft, "New draft from vN"), until it is filed — so it
    /// is numbered from that version (his decision 11: v4 → v4.1).
    private var pendingParents: [UUID: UUID] = [:]

    private static let queue = DispatchQueue(label: "topopt.library.results", qos: .utility)

    public init(store: ProjectStore) { self.store = store }

    public var cacheDir: URL { store.rootDir.appendingPathComponent("LibraryCache", isDirectory: true) }

    // MARK: - reading the disk

    /// Re-read the folders and the index; file what is new; keep the index honest.
    public func refresh() {
        snapshots = Dictionary(store.loadAll().readable.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        switch store.libraryState() {
        case .missing:
            index = LibraryIndex()
            // a root that is not there yet is an empty Library; one that is there but can't be listed is not
            let rootMissing = !FileManager.default.fileExists(atPath: store.rootDir.path)
            if snapshots.isEmpty, rootMissing || store.folderIDsOnDisk() != nil {
                // nothing to review: a new install goes straight to the Library
                try? store.saveLibrary(index)
                mode = .library
            } else {
                mode = .flat
            }
        case let .readable(existing):
            let before = Set(existing.parts.map(\.id))
            var r = LibraryGrouping.reconcile(existing, store: store, parents: pendingParents)
            pendingParents = pendingParents.filter { r.part(containing: $0.key) == nil }
            if let t = importTargetProject, let p = r.projects.firstIndex(where: { $0.id == t }) {
                let filed = Set(r.projects.flatMap(\.partIDs))
                for part in r.parts where !before.contains(part.id) && !filed.contains(part.id) {
                    r.projects[p].partIDs.append(part.id)
                }
            }
            importTargetProject = nil
            if r != existing { try? store.saveLibrary(r) }
            index = r
            mode = .library
            loadThumbnailsFromCache()
        case let .unreadable(why):
            mode = .unreadable(why)
        }
    }

    /// What Group would make, for the first-launch sheet.
    public func proposal() -> LibraryIndex {
        let p = LibraryGrouping.group(store.loadAll().readable, hash: { [store] in store.modelHash(of: $0) })
        lastProposal = p
        return p
    }

    /// Group: write the index (the proposal he saw), with the parts he ticked in a new project.
    public func group(projectName: String?, partIDs: [UUID]?) throws {
        var idx: LibraryIndex
        switch store.libraryState() {
        case let .unreadable(why): throw LibraryGroupingError.unreadableIndex(why)
        case let .readable(existing): idx = LibraryGrouping.reconcile(existing, store: store)
        case .missing: idx = LibraryGrouping.reconcile(lastProposal ?? proposal(), store: store)
        }
        if let name = projectName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let known = Set(idx.parts.map(\.id))
            let ids = (partIDs ?? idx.parts.map(\.id)).filter { known.contains($0) }
            idx.projects.append(LibraryProject(name: name, partIDs: ids))
        }
        try store.saveLibrary(idx)
        lastProposal = nil
        index = idx
        mode = .library
        loadThumbnailsFromCache()
    }

    /// A new folder was made from `version` (a draft, or "New draft from vN"): number it from that one.
    public func noteParent(_ version: UUID, of folder: UUID) { pendingParents[folder] = version }

    /// Not now: the sheet closes; today's Home stays, and Library ⋯ offers grouping again.
    public func notNow() { lastProposal = nil }

    /// Ungroup: back to today's Home. Only the Library's own files go (library.json, its pictures).
    public func ungroup() {
        store.ungroupLibrary()
        try? FileManager.default.removeItem(at: cacheDir)
        index = LibraryIndex()
        thumbnails = [:]
        resultsCache = [:]; resultsOrder = []
        mode = .flat
    }

    // MARK: - looking things up

    public func version(_ folder: UUID) -> LibraryVersion? {
        for p in index.parts { if let v = p.version(folderID: folder) { return v } }
        return nil
    }

    public func part(_ id: UUID) -> LibraryPart? { index.parts.first { $0.id == id } }
    public func project(_ id: UUID) -> LibraryProject? { index.projects.first { $0.id == id } }
    public func parts(in project: LibraryProject) -> [LibraryPart] { project.partIDs.compactMap(part) }
    public func projectOf(part: UUID) -> LibraryProject? { index.projects.first { $0.partIDs.contains(part) } }

    /// No results yet (read from the folder, never stored twice).
    public func isDraft(_ v: LibraryVersion) -> Bool {
        snapshots[v.folderID].map(LibraryGrouping.isDraft) ?? true
    }

    /// The Results screen's suggestion: the last result that passes.
    public func suggestedResult(_ v: LibraryVersion) -> Int? { v.summary?.lastIndex { $0.accepted } }

    /// The result a card shows: the one he picked, else one marked Print this, else the suggested one.
    public func shownResult(_ v: LibraryVersion) -> Int {
        if let p = v.pickedResult { return p }
        if let printed = v.marks.first(where: \.printThis)?.result { return printed }
        return suggestedResult(v) ?? 0
    }

    /// The card's title: his name, else the naming rule ("Carriage Arms · v6 · Keep Clear on 2 faces · res 128").
    public func title(of v: LibraryVersion, in part: LibraryPart) -> String {
        if let name = v.name { return "\(part.name) · v\(v.number) · \(name)" }
        let res = (snapshots[v.folderID]?.quality ?? .fast).resolution
        return VersionChanges.autoName(part: part.name, number: v.number, changes: v.changes, resolution: res)
    }

    /// The short title a card in its own part shows: "v6 · Keep Clear on 2 faces · res 128".
    public func shortTitle(of v: LibraryVersion, in part: LibraryPart) -> String {
        let full = title(of: v, in: part)
        let prefix = "\(part.name) · "
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
    }

    // MARK: - his marks

    private func edit(_ folder: UUID, _ change: (inout LibraryVersion) -> Void) {
        for p in index.parts.indices {
            guard let i = index.parts[p].versions.firstIndex(where: { $0.folderID == folder }) else { continue }
            change(&index.parts[p].versions[i])
            try? store.saveLibrary(index)
            return
        }
    }

    /// Set a result's stars; the same value again clears them.
    public func setStars(_ value: Double, folder: UUID, result: Int) {
        edit(folder) { v in
            var m = v.mark(for: result)
            m.setStars(m.stars == ResultMark.clampStars(value) ? 0 : value)
            v.setMark(m)
        }
    }

    public func togglePrint(folder: UUID, result: Int) {
        edit(folder) { v in
            var m = v.mark(for: result)
            m.printThis.toggle()
            if m.printThis { m.rejected = false }
            v.setMark(m)
        }
    }

    public func toggleReject(folder: UUID, result: Int) {
        edit(folder) { v in
            var m = v.mark(for: result)
            m.rejected.toggle()
            if m.rejected { m.printThis = false }
            v.setMark(m)
        }
    }

    /// The result a card shows.
    public func pick(folder: UUID, result: Int) { edit(folder) { $0.pickedResult = result } }

    // MARK: - projects, parts, names

    @discardableResult
    public func newProject(name: String) -> UUID {
        let p = LibraryProject(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New project" : name)
        index.projects.append(p)
        try? store.saveLibrary(index)
        return p.id
    }

    /// A part is in one project, or Unfiled (nil).
    public func move(part: UUID, to project: UUID?) {
        for i in index.projects.indices { index.projects[i].partIDs.removeAll { $0 == part } }
        if let project, let i = index.projects.firstIndex(where: { $0.id == project }) {
            index.projects[i].partIDs.append(part)
        }
        try? store.saveLibrary(index)
    }

    public func rename(part: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = index.parts.firstIndex(where: { $0.id == part }) else { return }
        index.parts[i].name = n
        try? store.saveLibrary(index)
    }

    public func rename(project: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = index.projects.firstIndex(where: { $0.id == project }) else { return }
        index.projects[i].name = n
        try? store.saveLibrary(index)
    }

    /// His own name for a version; blank means the automatic one again.
    public func rename(version folder: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        edit(folder) { $0.name = n.isEmpty ? nil : n }
    }

    /// Remove a project folder from the Library (its parts become Unfiled; no part is deleted).
    public func removeProject(_ id: UUID) {
        index.projects.removeAll { $0.id == id }
        try? store.saveLibrary(index)
    }

    // MARK: - results, numbers, pictures

    /// Read each optimized version's results once in the background: its numbers go into the index,
    /// its pictures into LibraryCache/. One version at a time, oldest first.
    public func loadSummaries(_ done: @escaping () -> Void = {}) {
        guard !loadingSummaries else { done(); return }
        let todo = index.parts.flatMap(\.versions)
            .filter { $0.summary == nil && $0.trimmed != true && snapshots[$0.folderID]?.optimized == true }
            .map(\.folderID)
        guard !todo.isEmpty else { done(); return }
        loadingSummaries = true
        func step(_ rest: ArraySlice<UUID>) {
            guard let folder = rest.first else { loadingSummaries = false; done(); return }
            decode(folder) { [weak self] results in
                guard let self else { return }
                if let results {
                    self.edit(folder) { v in
                        v.summary = results.map {
                            ResultSummary(massGrams: $0.massGrams, worstCaseMargin: $0.margin,
                                          accepted: $0.accepted, achievedVolumeFraction: $0.fraction)
                        }
                    }
                    for r in results { self.storeThumbnail(for: CompareItem(folder: folder, result: r.index), mesh: r.mesh) }
                }
                step(rest.dropFirst())
            }
        }
        step(todo[...])
    }

    /// Every result of a version, with its mesh (decoded off the main thread; the last few are kept).
    public func results(for folder: UUID, _ done: @escaping ([LibraryResult]?) -> Void) {
        if let hit = resultsCache[folder] { done(hit); return }
        decode(folder) { [weak self] results in
            if let self, let results {
                self.resultsCache[folder] = results
                self.resultsOrder.removeAll { $0 == folder }
                self.resultsOrder.append(folder)
                while self.resultsOrder.count > 4 { self.resultsCache[self.resultsOrder.removeFirst()] = nil }
            }
            done(results)
        }
    }

    private func decode(_ folder: UUID, _ done: @escaping ([LibraryResult]?) -> Void) {
        let store = self.store
        Self.queue.async {
            let results: [LibraryResult]? = {
                guard let data = store.loadResultsData(id: folder),
                      let o = try? OutcomeCodec.decode(data) else { return nil }
                return o.variants.enumerated().map { i, v in
                    LibraryResult(index: i,
                                  mesh: ViewerMesh(vertices: v.meshVertices, indices: v.meshIndices, faceIDs: [],
                                                   smoothShaded: true),
                                  massGrams: v.massGrams, margin: v.worstCaseMargin,
                                  fraction: v.achievedVolumeFraction, accepted: v.accepted)
                }
            }()
            DispatchQueue.main.async { done(results) }
        }
    }

    private func thumbnailURL(_ item: CompareItem) -> URL {
        cacheDir.appendingPathComponent("\(item.folder.uuidString)-\(item.result).png")
    }

    private func storeThumbnail(for item: CompareItem, mesh: ViewerMesh) {
        guard let image = MeshThumbnail.cgImage(for: mesh) else { return }
        thumbnails[item] = image
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(thumbnailURL(item) as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// The pictures already rendered, read back in the background.
    private func loadThumbnailsFromCache() {
        let items = index.parts.flatMap(\.versions).flatMap { v in
            (v.summary ?? []).indices.map { CompareItem(folder: v.folderID, result: $0) }
        }.filter { thumbnails[$0] == nil }
        guard !items.isEmpty else { return }
        let urls = items.map(thumbnailURL)
        Self.queue.async {
            var found: [(CompareItem, CGImage)] = []
            for (item, url) in zip(items, urls) {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
                found.append((item, img))
            }
            DispatchQueue.main.async { [weak self] in
                for (item, img) in found { self?.thumbnails[item] = img }
            }
        }
    }

    // MARK: - Storage

    /// Bytes of a version's results (the results file and the run's two files).
    public func resultsBytes(_ folder: UUID) -> Int64 {
        let fm = FileManager.default
        return [store.resultsURL(id: folder), store.runJobURL(id: folder), store.runDesignURL(id: folder)]
            .compactMap { (try? fm.attributesOfItem(atPath: $0.path))?[.size] as? NSNumber }
            .reduce(0) { $0 + $1.int64Value }
    }

    /// Whether a version keeps all its results: one is rated ★4+ or marked Print this, or it is one of
    /// its part's newest 2 versions with results.
    public func keepsAllResults(_ folder: UUID) -> Bool {
        guard let v = version(folder) else { return true }
        if let his = v.keepAll { return his }
        if v.marks.contains(where: { $0.stars >= 4 || $0.printThis }) { return true }
        guard let part = index.part(containing: folder) else { return true }
        let newest = part.versions.filter { !isDraft($0) }.sorted { $0.number > $1.number }.prefix(2)
        return newest.contains { $0.folderID == folder }
    }

    /// His Storage switch for one version (nil = the rule again).
    public func setKeepAll(_ on: Bool?, folder: UUID) { edit(folder) { $0.keepAll = on } }

    /// The versions Trim would take: optimized, more than one result, not kept by the rule or by him.
    public var trimmable: [LibraryVersion] {
        index.parts.flatMap(\.versions).filter { v in
            v.trimmed != true && !isDraft(v) && (v.summary?.count ?? 0) > 1 && !keepsAllResults(v.folderID)
        }
    }

    /// Keep only the result he picked (his tap on Storage, never by itself).
    public func trim(folder: UUID) throws {
        guard let v = version(folder), let data = store.loadResultsData(id: folder),
              var root = try PropertyListSerialization.propertyList(from: data, options: 0, format: nil) as? [String: Any],
              let variants = root["variants"] as? [Any] else { throw CocoaError(.fileReadCorruptFile) }
        let picked = shownResult(v)
        guard variants.indices.contains(picked), variants.count > 1 else { return }
        let decodedPick = try OutcomeCodec.decode(data).variants[picked]
        root["variants"] = [variants[picked]]
        root["acceptedCount"] = decodedPick.accepted ? 1 : 0
        let trimmed = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        guard try OutcomeCodec.decode(trimmed).variants.count == 1 else { throw CocoaError(.fileWriteUnknown) }
        try trimmed.write(to: store.resultsURL(id: folder), options: .atomic)
        // the design holds every result's field; one result no longer matches it. The job stays.
        if let art = store.loadRelatticeArtifacts(id: folder) {
            try store.saveRelatticeArtifacts(jobJSON: art.jobJSON, designBin: Data(), id: folder)
        }
        let keptMark = v.mark(for: picked)
        let keptSummary = [ResultSummary(massGrams: decodedPick.massGrams, worstCaseMargin: decodedPick.worstCaseMargin,
                                         accepted: decodedPick.accepted, achievedVolumeFraction: decodedPick.achievedVolumeFraction)]
        edit(folder) { v in
            v.marks = []
            v.setMark(ResultMark(result: 0, stars: keptMark.stars, printThis: keptMark.printThis, rejected: keptMark.rejected))
            v.pickedResult = 0
            v.summary = keptSummary
            v.trimmed = true
        }
        let old = thumbnails[CompareItem(folder: folder, result: picked)]
        for k in thumbnails.keys where k.folder == folder { thumbnails[k] = nil }
        if let old { thumbnails[CompareItem(folder: folder, result: 0)] = old }
        let fm = FileManager.default
        let from = thumbnailURL(CompareItem(folder: folder, result: picked)), to = thumbnailURL(CompareItem(folder: folder, result: 0))
        if picked != 0 { try? fm.removeItem(at: to); try? fm.moveItem(at: from, to: to) }
        for r in variants.indices where r != 0 { try? fm.removeItem(at: thumbnailURL(CompareItem(folder: folder, result: r))) }
        resultsCache[folder] = nil
    }
}
