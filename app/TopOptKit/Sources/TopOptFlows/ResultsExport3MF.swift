// ResultsExport3MF.swift — ★ his iPad notes on release 18 (2026-11-24, img 85/86): Checks and Details said "Print file ready ·
// 3MF · 40.0 MB" while the button read "Export v8.1a (.stl) · One finished shape". "There should be an *option* for an stl (via
// the '^' menu) but... it should at least default to exporting 3mf."
//
// WHY IT WAS AN STL. Results' Export was built (the EXPORT task) before the app could write a 3MF ("STL today; .3mf is planned:
// lib3mf isn't in the app build yet"), so its one action wrote the shown result's mesh as a binary STL — every result, a print
// file's too. And a print file's own 3MF (the Lattice button's, made on the Mac, with its painted supports and print settings)
// was never kept: the run read it into the mesh Results draws (`LatticeFileButton.outcome`) and dropped the file, so there was
// no 3MF left to hand out even when the Checks named one.
//
// NOW. Export writes a 3MF by default:
//   * a print file's result: the print file itself, kept with its version from now on (`PrintFileKeep`, below) — its painted
//     supports and print settings with it — when the kept file is that result's (its name and size are the report's);
//   * otherwise the shown result's shape as a 3MF (`PartsThreeMF`, the app's own writer, no third library);
//   * a worker-streamed latticed variant still exports the worker's STL (it is never decoded on the iPad).
// The ⌃ offers "Export as STL", its (i) saying an STL carries no painted supports or print settings.
import Foundation
import TopOptKit

/// The words.
public enum ResultsExportCopy {
    public static let stlItem = "Export as STL"
    /// The STL row's grey line (five words at most).
    public static let stlLine = "No supports or print settings"
    public static let stlInfoTitle = "STL"
    public static let stlInfo = "An STL is the shape alone. It carries no painted supports and no print settings, so your "
        + "slicer starts from its own. The 3MF keeps both."
    public static let printFileLine = "The print file"
    public static let fileFailed = "Couldn\u{2019}t export the file"
}

extension ResultsModel {
    /// "{project}-{material}-{NN}pct.3mf" — the STL's name, as a 3MF.
    public var exportThreeMFFilename: String { exportStem(for: selected) + ".3mf" }

    /// The shown result's shape as a 3MF (one named object), or nil when there is nothing to write here (no mesh, or a
    /// worker-streamed latticed variant, whose file is the worker's STL).
    public func exportThreeMFData() -> Data? {
        guard selectedLattice == nil, canExport, let tab = selected, let v = variant(for: tab) else { return nil }
        let name = exportStem(for: tab)
        return PartsThreeMF.write([PartsThreeMF.Object(name: name, vertices: v.meshVertices, indices: v.meshIndices)],
                                  title: projectName.isEmpty ? name : projectName)
    }

    /// ★ his 11-25: the print file's three resolutions, as its report gives them (nil: not a print file, or none given).
    public var printResolutions: PrintResolutionFacts? { reportBlocks?.printFile?.resolutions }

    /// The print file this result was made as: its name and size, as its report gives them (nil: not a print file's).
    public var printFileIdentity: PrintFileKeep.Identity? {
        guard let f = reportBlocks?.printFile, f.fileBytes > 0 else { return nil }
        return PrintFileKeep.Identity(name: f.fileName, bytes: f.fileBytes)
    }
}

/// ★ notes28 (4c): a print file kept with its version (`<folder>/print_file/<its name>`), so Export hands out the 3MF the Checks
/// name. The Lattice run's reading of the Mac's file puts it aside (`stash`); the version's result being saved puts it in the
/// version's folder (`keep`); Results finds it by the shown result's report (`file`).
public enum PrintFileKeep {
    /// A print file's name and size, as its report gives them.
    public struct Identity: Equatable, Sendable {
        public let name: String
        public let bytes: Int
        public init(name: String, bytes: Int) { self.name = name; self.bytes = bytes }
    }

    static var stashRoot: URL { FileManager.default.temporaryDirectory.appendingPathComponent("PrintFileKeep", isDirectory: true) }
    static func stashURL(_ id: UUID, _ name: String) -> URL {
        stashRoot.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(safe(name))
    }
    static func safe(_ name: String) -> String {
        let n = (name as NSString).lastPathComponent
        return n.isEmpty || n.hasPrefix(".") ? "print_file" : n
    }

    /// The folder's kept print file place.
    public static func folder(_ id: UUID, store: ProjectStore) -> URL {
        store.rootDir.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("print_file", isDirectory: true)
    }

    /// A Lattice run read the Mac's file for `projectID`: put it aside until the version's result is saved.
    public static func stash(_ data: Data, name: String, projectID: UUID) {
        guard !data.isEmpty else { return }
        let url = stashURL(projectID, name)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The version's result was saved: the file put aside for it goes into its folder, when it is one of these results'
    /// (its name and size are a result's report's). Only into a version that is still there.
    public static func keep(projectID: UUID, outcomes: [OptimizeOutcome?], store: ProjectStore) {
        let dir = stashRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path), let name = names.first else { return }
        let src = dir.appendingPathComponent(name)
        let size = ((try? FileManager.default.attributesOfItem(atPath: src.path))?[.size] as? NSNumber)?.intValue ?? -1
        let ids = outcomes.compactMap { $0.flatMap(identity(of:)) }
        guard store.holdsProject(id: projectID), ids.contains(Identity(name: name, bytes: size)) else { return }
        let to = folder(projectID, store: store)
        try? FileManager.default.removeItem(at: to)
        do {
            try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: src, to: to.appendingPathComponent(name))
            try? FileManager.default.removeItem(at: dir)
        } catch {
            NSLog("TopOpt print file not kept: %@", "\(error)")
        }
    }

    /// The print file a result's report names (nil: not a print file's).
    public static func identity(of o: OptimizeOutcome) -> Identity? {
        guard let d = o.reportJSON, let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let f = LatticeFileFacts.decode(j), f.fileBytes > 0 else { return nil }
        return Identity(name: f.fileName, bytes: f.fileBytes)
    }

    /// The kept print file of `folder` that IS this result's (its name and size), else nil.
    public static func file(_ id: Identity?, folder: UUID, store: ProjectStore) -> URL? {
        guard let id else { return nil }
        let url = self.folder(folder, store: store).appendingPathComponent(safe(id.name))
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue
        return size == id.bytes ? url : nil
    }

    /// The version whose Results are on screen (the open workspace's), for Results' Export. Set by the workspace as it opens.
    @MainActor public static var open: (() -> (folder: UUID, store: ProjectStore)?)?

    /// Whether the open version keeps this result's print file (asked as Results draws: the answer is kept per file and folder).
    @MainActor static func openFile(exists id: Identity?) -> Bool {
        guard let id, let o = open?() else { return false }
        if let c = existsCache, c.id == id, c.folder == o.folder, Date().timeIntervalSince(c.at) < 2 { return c.yes }
        let yes = file(id, folder: o.folder, store: o.store) != nil
        existsCache = (id, o.folder, yes, Date())
        return yes
    }
    @MainActor private static var existsCache: (id: Identity, folder: UUID, yes: Bool, at: Date)?

    /// The open version's kept print file for this result, copied to a temporary file named for the result ("…-37pct.3mf").
    @MainActor static func openFile(_ id: Identity?, named stem: String) -> URL? {
        guard let id, let o = open?(), let kept = file(id, folder: o.folder, store: o.store) else { return nil }
        let ext = (id.name as NSString).pathExtension.isEmpty ? "3mf" : (id.name as NSString).pathExtension
        let to = FileManager.default.temporaryDirectory.appendingPathComponent(stem + "." + ext)
        try? FileManager.default.removeItem(at: to)
        do { try FileManager.default.copyItem(at: kept, to: to); return to } catch { return nil }
    }
}
