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
    /// The M7.params print parameters (user override of the M5.1 recommended slicer
    /// settings). OPTIONAL so snapshots written before this field still decode —
    /// nil is treated as `PrintParams.fdmDefault`.
    public var printParams: PrintParams?
    /// The M7.dom-app design-domain (design box + keep-outs). OPTIONAL so snapshots
    /// written before this field still decode — nil is treated as the default-off
    /// `DesignBoxModel()` (no box → no design-domain expansion on the run).
    public var designBox: DesignBoxModel?
    /// The lattice-mode settings (handoff 2026-07-29-lattice-mode-ui). OPTIONAL so
    /// snapshots written before this field still decode — nil (also written whenever
    /// lattice mode is OFF) is treated as the default-off `LatticeSettings()`, so a
    /// non-lattice project's project.json is byte-identical to a pre-lattice one.
    public var lattice: LatticeSettings?

    public init(schemaVersion: Int = ProjectSnapshot.currentSchema, id: UUID, name: String,
                material: String, process: ProcessKind, modelFileName: String,
                originalFileName: String, savedAt: Date,
                selection: SelectionModel, force: ForceModel,
                minimizePlastic: Bool? = nil, quality: RunQuality? = nil,
                optimized: Bool? = nil, printParams: PrintParams? = nil,
                designBox: DesignBoxModel? = nil, lattice: LatticeSettings? = nil) {
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
        self.printParams = printParams
        self.designBox = designBox
        self.lattice = lattice
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

    /// Whether a results blob EXISTS for this project — asked without reading it
    /// (the blob carries every variant's mesh and fields, so a presence question
    /// must not cost a decode). `AppModel.persist` uses it so the snapshot's
    /// `optimized` flag can never be downgraded below what is actually on disk:
    /// the flag is the only thing that decides whether the blob is ever read back,
    /// and a false written over a live results file orphans it forever (task
    /// 2026-08-03-variant-entry-gating-and-retention, bar AJ1).
    public func hasPersistedResults(id: UUID) -> Bool {
        fm.fileExists(atPath: resultsURL(id: id).path)
    }

    // MARK: the re-lattice artifacts (task 2026-08-02-lattice-a-variant)

    /// The EXACT job document that produced the persisted results.
    public func runJobURL(id: UUID) -> URL {
        projectDir(id).appendingPathComponent("run_job.json")
    }
    /// That run's `design.bin` — each variant's own density field.
    public func runDesignURL(id: UUID) -> URL {
        projectDir(id).appendingPathComponent("run_design.bin")
    }

    /// Persist the two artifacts a re-lattice needs, BESIDE the results they
    /// describe. Kept as their own files rather than folded into the results
    /// blob: `design.bin` is a core-format container the CLI reads back verbatim,
    /// and re-encoding it through a DTO would be a second representation of the
    /// same bytes — one more place for the design that gets certified and the
    /// design that was stored to drift apart.
    public func saveRelatticeArtifacts(jobJSON: Data, designBin: Data,
                                       id: UUID) throws {
        try fm.createDirectory(at: projectDir(id), withIntermediateDirectories: true)
        try jobJSON.write(to: runJobURL(id: id), options: .atomic)
        // A DESIGN-LESS PAIR IS A REAL STATE (task
        // 2026-08-03-variant-postprocessing-fix): a run killed mid-ladder, or one
        // whose worker served no container, still kept the LOAD CASE, and smoothing
        // needs only that. The stale design of a DIFFERENT run must not survive
        // beside it, so an empty half REMOVES the file rather than writing zero
        // bytes — the reader would then have to distinguish "empty" from "old".
        if designBin.isEmpty {
            try? fm.removeItem(at: runDesignURL(id: id))
        } else {
            try designBin.write(to: runDesignURL(id: id), options: .atomic)
        }
    }

    /// Read them back. Returns nil unless the JOB survives — a design without the
    /// job that produced it cannot be certified under the right load case, and half
    /// an answer there would become a run certified under a re-authored load case,
    /// which is the whole failure this pair exists to prevent.
    ///
    /// A missing DESIGN is not half an answer, it is a different (and common) state:
    /// the load case is here, the density fields are not. The pair carries an empty
    /// `designBin` and the two entry gates diverge — smoothing enabled, latticing
    /// disabled with its own reason.
    public func loadRelatticeArtifacts(id: UUID) -> RelatticeArtifacts? {
        guard let job = try? Data(contentsOf: runJobURL(id: id)), !job.isEmpty
        else { return nil }
        let design = (try? Data(contentsOf: runDesignURL(id: id))) ?? Data()
        return RelatticeArtifacts(jobJSON: job, designBin: design)
    }

    /// Drop them — called when a project's results are replaced by a run that
    /// produced no design container, so a stale design can never be latticed
    /// against a newer run's results.
    public func clearRelatticeArtifacts(id: UUID) {
        try? fm.removeItem(at: runJobURL(id: id))
        try? fm.removeItem(at: runDesignURL(id: id))
    }

    /// The sidecar files that travel WITH a model file (as `<path><suffix>`), and
    /// that the store must therefore carry alongside its model copy: the core
    /// face-overrides sidecar (`.faces` — the painted pseudo-faces the selection
    /// groups reference; without it a reopened re-import has no painted id space
    /// and RUN SIM/Optimize throw "face_id out of range") and the app clearance
    /// sidecar (`.clearances.json` — deletions + manual primitives).
    static let sidecarSuffixes = [".faces", ".clearances.json"]

    /// Save a snapshot. If `modelSource` is given and the copy isn't already in the
    /// project folder, copy it in (once — the imported model is immutable). Its
    /// SIDECARS are re-synced on EVERY save — unlike the model they are mutable
    /// (each paint stroke rewrites `.faces`), and the reopened re-import resolves
    /// selections against the store copy, so a stale/missing sidecar here silently
    /// invalidates the persisted groups' face ids. Throws on a filesystem error so
    /// the caller can surface it.
    public func save(_ snapshot: ProjectSnapshot, modelSource: URL? = nil) throws {
        let dir = projectDir(snapshot.id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let modelSource {
            let dest = dir.appendingPathComponent(snapshot.modelFileName)
            if !fm.fileExists(atPath: dest.path) {
                try fm.copyItem(at: modelSource, to: dest)
            }
            try syncSidecars(from: modelSource, to: dest)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotURL(snapshot.id), options: .atomic)
    }

    /// Mirror each sidecar of `src` next to `dest`: copy it when the source has
    /// one, delete a leftover when it doesn't (a cleared paint overlay DELETES
    /// its sidecar, and the store copy must say the same thing). A reopened
    /// project's model source IS the store copy — nothing to sync then.
    private func syncSidecars(from src: URL, to dest: URL) throws {
        guard src.path != dest.path else { return }
        for suffix in Self.sidecarSuffixes {
            let s = src.path + suffix
            let d = dest.path + suffix
            if fm.fileExists(atPath: s) {
                if fm.fileExists(atPath: d) { try fm.removeItem(atPath: d) }
                try fm.copyItem(atPath: s, toPath: d)
            } else if fm.fileExists(atPath: d) {
                try fm.removeItem(atPath: d)
            }
        }
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
