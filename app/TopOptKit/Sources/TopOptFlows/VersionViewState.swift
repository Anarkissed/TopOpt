// VersionViewState.swift — ★ his iPad notes on release 18 (2026-11-24, img 84): "it automatically opens on the topology stage".
//
// A version opens as he left it: on the stage last open in it (Topology or the lattice stage, and the lattice stage's Cells
// page), with its panels (Selections folded or open, the Topology panel on Lattice Setup, the colour key folded), its view
// buttons (Outlines, X-ray, Forces, Hide keep clears, the Design box, Stress) and its camera (the turn, the zoom, the pan).
//
// A version WITH a result: a tap on its card opens the result (as before, LibraryCardOpen); "Open" (its ⋯, its long press, the
// part's Open button, Continue) opens the version itself on the stage that result belongs to — never on the result, even
// when the result was the last thing he looked at.
//
// The view state is its own small file in the version's folder (`view_state.json`), written as the workspace closes and as
// the stage changes. It is never part of project.json — so it can never make a version, never change "what changed", never
// stop project.json decoding — and a folder without one (every version saved before) opens exactly as before. A file that
// can't be read is ignored the same way.
import Foundation
import simd

/// The camera as he left it: its turn, its zoom and its pan (the part's own frame, as the viewer keeps it).
public struct VersionCameraPose: Codable, Equatable, Sendable {
    public var azimuth: Float
    public var elevation: Float
    public var roll: Float
    public var distance: Float
    public var target: [Float]

    public init(azimuth: Float, elevation: Float, roll: Float, distance: Float, target: SIMD3<Float>) {
        self.azimuth = azimuth; self.elevation = elevation; self.roll = roll; self.distance = distance
        self.target = [target.x, target.y, target.z]
    }

    public init(_ c: OrbitCamera) {
        self.init(azimuth: c.azimuth, elevation: c.elevation, roll: c.roll, distance: c.distance, target: c.target)
    }

    var targetVector: SIMD3<Float>? {
        target.count == 3 && target.allSatisfy(\.isFinite) ? SIMD3(target[0], target[1], target[2]) : nil
    }

    /// `c` turned, zoomed and panned as he left it (its lens, its limits and its home kept).
    public func applied(to c: OrbitCamera) -> OrbitCamera {
        var out = c
        guard azimuth.isFinite, elevation.isFinite, roll.isFinite else { return out }
        out.setOrientation(azimuth: azimuth, elevation: elevation)
        out.setRoll(roll)
        if distance.isFinite, distance > 0 { out.distance = Swift.min(Swift.max(distance, c.minDistance), c.maxDistance) }
        if let t = targetVector { out.target = t }
        return out
    }
}

/// What a version's page showed when he left it. Every field is optional: a field missing (an older file, a newer field)
/// leaves that part of the page as it opens today.
public struct VersionViewState: Codable, Equatable, Sendable {
    /// `WorkspaceStage.rawValue`: "topology" or "lattice".
    public var stage: String?
    /// "setup", "cells" (the lattice stage's Cells page) or "results" (kept for the record; never reopened by itself).
    public var page: String?
    public var selectionsCollapsed: Bool?
    public var latticeTopologyOpen: Bool?
    public var legendMinimized: Bool?
    public var outlines: Bool?
    public var xray: Bool?
    public var forces: Bool?
    public var keepClearsHidden: Bool?
    public var designBox: Bool?
    public var stress: Bool?
    public var camera: VersionCameraPose?

    public init(stage: String? = nil, page: String? = nil, selectionsCollapsed: Bool? = nil, latticeTopologyOpen: Bool? = nil,
                legendMinimized: Bool? = nil, outlines: Bool? = nil, xray: Bool? = nil, forces: Bool? = nil,
                keepClearsHidden: Bool? = nil, designBox: Bool? = nil, stress: Bool? = nil, camera: VersionCameraPose? = nil) {
        self.stage = stage; self.page = page; self.selectionsCollapsed = selectionsCollapsed
        self.latticeTopologyOpen = latticeTopologyOpen; self.legendMinimized = legendMinimized; self.outlines = outlines
        self.xray = xray; self.forces = forces; self.keepClearsHidden = keepClearsHidden; self.designBox = designBox
        self.stress = stress; self.camera = camera
    }

    public static let pageSetup = "setup", pageCells = "cells", pageResults = "results"
}

extension ProjectStore {
    /// `<folder>/view_state.json` — beside project.json, never inside it.
    public func viewStateURL(id: UUID) -> URL {
        rootDir.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("view_state.json")
    }

    /// The version's page as he left it; nil when there is none (every older version) or it can't be read.
    public func loadViewState(id: UUID) -> VersionViewState? {
        guard let d = try? Data(contentsOf: viewStateURL(id: id)) else { return nil }
        return try? JSONDecoder().decode(VersionViewState.self, from: d)
    }

    /// Keep it — only beside a project that is still there (a write never recreates a deleted folder).
    public func saveViewState(_ s: VersionViewState, id: UUID) {
        guard holdsProject(id: id) else { return }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        guard let d = try? e.encode(s) else { return }
        try? d.write(to: viewStateURL(id: id), options: .atomic)
    }
}

/// The open as it is settling: the version's saved view, and whether its result's stage is still to be chosen (its result
/// arrives after the page appears). One at a time — the open workspace's. Never the workspace's @State.
@MainActor
public final class VersionViewOpen {
    public static let shared = VersionViewOpen()
    /// The version whose result's stage is still to be chosen as its result arrives.
    public private(set) var awaitsResultStage: UUID?
    /// That version's saved view (its Cells page is reopened once the stage is its result's).
    public private(set) var saved: VersionViewState?
    /// Tests: the last view state each version wrote and the stage each open settled on.
    public static var lastWritten: [UUID: VersionViewState] = [:]
    public static var settled: [UUID: String] = [:]

    func waitForResult(_ folder: UUID, saved: VersionViewState?) { awaitsResultStage = folder; self.saved = saved }

    /// Its result is in: done waiting (returns the saved view, once).
    func take(_ folder: UUID) -> (Bool, VersionViewState?) {
        guard awaitsResultStage == folder else { return (false, nil) }
        awaitsResultStage = nil
        defer { saved = nil }
        return (true, saved)
    }

    func clear() { awaitsResultStage = nil; saved = nil }

    /// The version just opened (AppModel.open) and when: its page restores once, as it first appears — never again when the
    /// host reappears in the same visit (a full-screen page closing, gravity set).
    private var justOpened: (folder: UUID, at: Date)?
    public func opened(_ folder: UUID) { justOpened = (folder, Date()) }
    /// True once, for the version just opened (within a few seconds of its open).
    func takeOpened(_ folder: UUID) -> Bool {
        guard let o = justOpened, o.folder == folder, Date().timeIntervalSince(o.at) < Self.openWindowS else { return false }
        justOpened = nil
        return true
    }
    static let openWindowS: TimeInterval = 8

    /// RED CONTROL (VersionViewStateTests): every version opens on Topology, with the page as it is made (release 18).
    public static var controlOpensAsBefore = false
}
