// ProjectStore.swift — cross-launch project persistence (M7.x-persist-b).
//
// persist-a kept the workspace state alive across NAVIGATION (in memory, owned by
// AppModel). persist-b writes it to disk so it survives app relaunch: one folder
// per project under Application Support, holding a Codable snapshot of the working
// state (gravity + selection groups + roles + directions + weights + material) and
// a COPY of the imported model file (the security-scoped picked URL isn't durably
// accessible, so re-opening re-imports from our own copy).
//
// The store is a pure filesystem layer with an injectable root, so it's unit-tested
// against a temp directory; AppModel orchestrates when to save / load.

import Foundation
import TopOptKit

/// The on-disk form of a project (everything needed to rebuild a `ProjectModel`
/// except the mesh, which is re-imported from the copied model file). Schema-
/// versioned so a future format change can migrate rather than silently drop data.
public struct ProjectSnapshot: Codable, Equatable, Sendable {
    /// Bump when the on-disk shape changes incompatibly; `ProjectStore` skips
    /// snapshots it can't read rather than crashing.
    public static let currentSchema = 1

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var material: String
    public var process: ProcessKind
    /// The model file's name WITHIN the project folder (e.g. "model.stl").
    public var modelFileName: String
    /// The original picked file name, for display.
    public var originalFileName: String
    /// Last-saved time, for recents ordering.
    public var savedAt: Date

    /// The persisted workspace state.
    public var selection: SelectionModel
    public var force: ForceModel
    /// The "minimize plastic" toggle. OPTIONAL so pre-existing schema-1 snapshots
    /// (written before this field) still decode — nil is treated as `true`.
    public var minimizePlastic: Bool?
    /// The optimize resolution/quality. OPTIONAL for the same back-compat reason
    /// (nil → Fast).
    public var quality: RunQuality?
    /// Whether the project has optimize results. OPTIONAL for back-compat (nil → false).
    public var optimized: Bool?

    public init(schemaVersion: Int = ProjectSnapshot.currentSchema, id: UUID, name: String,
                material: String, process: ProcessKind, modelFileName: String,
                originalFileName: String, savedAt: Date,
                selection: SelectionModel, force: ForceModel,
                minimizePlastic: Bool? = nil, quality: RunQuality? = nil,
                optimized: Bool? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.material = material
        self.process = process
        self.modelFileName = modelFileName
        self.originalFileName = originalFileName
        self.savedAt = savedAt
        self.selection = selection
        self.force = force
        self.minimizePlastic = minimizePlastic
        self.quality = quality
        self.optimized = optimized
    }
}

/// Reads/writes projects under a root directory (default: Application Support).
public struct ProjectStore {
    public let rootDir: URL
    private let fm = FileManager.default

    /// - Parameter rootDir: base directory. Defaults to
    ///   `<AppSupport>/TopOpt/Projects`; tests pass a temp directory.
    public init(rootDir: URL? = nil) {
        if let rootDir {
            self.rootDir = rootDir
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            self.rootDir = base.appendingPathComponent("TopOpt/Projects", isDirectory: true)
        }
    }

    private func projectDir(_ id: UUID) -> URL {
        rootDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    private func snapshotURL(_ id: UUID) -> URL {
        projectDir(id).appendingPathComponent("project.json")
    }

    /// The path (as a String, for the bridge importer) of a project's copied model.
    public func modelPath(id: UUID, fileName: String) -> String {
        projectDir(id).appendingPathComponent(fileName).path
    }

    /// The persisted optimize results file (persist-c) within a project's folder.
    public func resultsURL(id: UUID) -> URL {
        projectDir(id).appendingPathComponent("results.plist")
    }

    /// Write serialized results (from `OutcomeCodec`) into the project folder.
    /// The folder already exists once the snapshot has been saved.
    public func saveResults(_ data: Data, id: UUID) throws {
        try fm.createDirectory(at: projectDir(id), withIntermediateDirectories: true)
        try data.write(to: resultsURL(id: id), options: .atomic)
    }

    /// Read the raw results blob, or nil if none was persisted / it's unreadable.
    public func loadResultsData(id: UUID) -> Data? {
        try? Data(contentsOf: resultsURL(id: id))
    }

    /// Save a snapshot. If `modelSource` is given and the copy isn't already in the
    /// project folder, copy it in (once — the imported model is immutable). Throws
    /// on a filesystem error so the caller can surface it.
    public func save(_ snapshot: ProjectSnapshot, modelSource: URL? = nil) throws {
        let dir = projectDir(snapshot.id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let modelSource {
            let dest = dir.appendingPathComponent(snapshot.modelFileName)
            if !fm.fileExists(atPath: dest.path) {
                try fm.copyItem(at: modelSource, to: dest)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotURL(snapshot.id), options: .atomic)
    }

    /// Load one snapshot (nil if absent, unreadable, or a newer schema).
    public func snapshot(id: UUID) -> ProjectSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL(id)),
              let snap = try? JSONDecoder().decode(ProjectSnapshot.self, from: data),
              snap.schemaVersion <= ProjectSnapshot.currentSchema else { return nil }
        return snap
    }

    /// All readable snapshots, most-recently-saved first.
    public func loadAllSnapshots() -> [ProjectSnapshot] {
        guard let entries = try? fm.contentsOfDirectory(at: rootDir,
                                                        includingPropertiesForKeys: nil) else { return [] }
        return entries
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { snapshot(id: $0) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    /// Remove a project's folder entirely.
    public func delete(id: UUID) {
        try? fm.removeItem(at: projectDir(id))
    }
}
