// LatticeWizardModel.swift — the pure half of the LATTICE SETTINGS page
// (task 2026-08-12-lattice-page-redesign §2).
//
// ★ THE LAW THIS PAGE IS BUILT UNDER: "NO MORE EXHAUSTING MASSIVE PIECES OF TEXT.
// SHOW THE CHANGES BEING MADE ON SCREEN so the user actually UNDERSTANDS the
// settings." Every explanation on this page is a MOVE, not a sentence. This file
// holds the moves as data — what changes, what it animates from and to, and how
// long — so the cinematics are testable and the view stays a renderer.
//
// THE ORDER IS THE TEACHING (§2):
//
//   STAGE A — ONE CELL, ALONE. Pick the TYPE → the cell MORPHS into it. Set the
//             SIZE → it resizes live. Set the THICKNESS → the struts thicken
//             live. No explanatory text: the cell IS the explanation.
//   STAGE B — THE CELL BECOMES A LATTICE. That one cell moves into the sample
//             part and EXPANDS OUTWARD to tile it. Animated, never cut to.
//   STAGE C — the cinematic explanations: the stress field WIPES DOWN the part
//             and the camera DIVES into the denser lattice; Auto cell size JUMPS
//             to the sample; the four boundary finishes are shown ON THE PART.
//
// THE LEFT MODAL IS PERSISTENT: every selection lives there and can be changed at
// any time, and any change updates the sample. The wizard is the ORDER, never a
// gate — `jump(to:)` exists precisely so a user who knows what they want is never
// walked through it.

import Foundation
import simd

/// Which stage the page is showing.
public enum LatticeWizardStage: Int, Equatable, Sendable, CaseIterable {
    /// One cell, large, centred, rotatable.
    case cell = 0
    /// The cell has tiled the sample part.
    case lattice = 1

    /// ★ Three words at most (R3).
    public var title: String {
        self == .cell ? "One cell" : "In the part"
    }
}

/// One cinematic. The view plays it; this says what it IS.
public enum LatticeWizardCinematic: String, Equatable, Sendable {
    /// Type changed: the struts morph from the old family into the new one.
    case morph
    /// The single cell flies into the part and tiles outward.
    case tile
    /// The stress field wipes down the part, then the camera dives into the
    /// densest lattice — "density follows stress", shown.
    case stressWipeAndDive
    /// Auto cell size: jump straight to the sample at the derived cell.
    case jumpToSample
    /// Boundary finish: the same part, the four finishes, switchable.
    case boundarySwap

    /// Seconds. Long enough to read as a move, short enough not to be a wait.
    public var duration: Double {
        switch self {
        case .morph: return 0.45
        case .tile: return 1.1
        case .stressWipeAndDive: return 2.2
        case .jumpToSample: return 0.5
        case .boundarySwap: return 0.35
        }
    }
}

/// The page's own state — the user's selections plus where the cinematics are.
/// A value type: the view owns one, the tests drive one.
public struct LatticeWizardModel: Equatable, Sendable {

    public var stage: LatticeWizardStage = .cell
    /// The cinematic currently playing, and a token that changes on every replay
    /// so the view restarts an animation even when the same one is re-requested.
    public private(set) var playing: LatticeWizardCinematic?
    public private(set) var playToken: Int = 0

    // ── the selections (Stage A) ────────────────────────────────────────────
    public var topologyID: String
    public var cellMM: Double
    /// "Thickness" as the user sets it: the relative density the struts are sized
    /// from. One number the whole page reads — the strut radius is derived, never
    /// stored twice.
    public var relativeDensity: Double

    // ── the selections (Stage B) ────────────────────────────────────────────
    public var densityMode: LatticeDensityMode
    public var cellSizeMode: LatticeCellSizeMode
    public var boundary: LatticeBoundaryTreatment

    /// The top-centre disclaimer (§3b) — one line, an X, dismissible, and it
    /// stays dismissed for the session.
    public var showDisclaimer: Bool = true

    public init(topologyID: String = LatticeType.octet.id,
                cellMM: Double = 6,
                relativeDensity: Double = 0.35,
                densityMode: LatticeDensityMode = .auto,
                cellSizeMode: LatticeCellSizeMode = .auto,
                boundary: LatticeBoundaryTreatment = .fullSkin) {
        self.topologyID = topologyID
        self.cellMM = cellMM
        self.relativeDensity = relativeDensity
        self.densityMode = densityMode
        self.cellSizeMode = cellSizeMode
        self.boundary = boundary
    }

    /// Seed from a project's stored settings, so opening the page shows what the
    /// project already has rather than the page's own defaults.
    public init(settings s: LatticeSettings) {
        self.init(topologyID: s.topologyID, cellMM: s.cellMM,
                  relativeDensity: max(0.05, s.maxRelativeDensity),
                  densityMode: s.densityMode, cellSizeMode: s.cellSizeMode,
                  boundary: s.boundary)
    }

    /// Write the selections back. Only the fields this page owns move.
    public func applied(to s: LatticeSettings) -> LatticeSettings {
        var out = s
        out.topologyID = topologyID
        out.cellMM = cellMM
        out.maxRelativeDensity = relativeDensity
        out.densityMode = densityMode
        out.cellSizeMode = cellSizeMode
        out.boundary = boundary
        out.enabled = true
        return out
    }

    public var lattice: LatticeType { LatticeType.named(topologyID) }

    // MARK: the moves

    /// Play a cinematic. Always bumps the token, so re-requesting the same one
    /// restarts it (the "tap the lit chip again" case).
    public mutating func play(_ c: LatticeWizardCinematic) {
        playing = c
        playToken += 1
    }

    public mutating func finishedPlaying() { playing = nil }

    /// Setting the TYPE morphs the cell (§2 Stage A). Never a swap.
    public mutating func setTopology(_ id: String) {
        guard id != topologyID else { return }
        topologyID = id
        play(.morph)
    }

    /// ★ THE STAGE-A → STAGE-B TRANSITION. Once type, size and thickness are set,
    /// the cell moves into the sample and expands to tile it. Animated (§2 B).
    public mutating func enterLattice() {
        guard stage != .lattice else { return }
        stage = .lattice
        play(.tile)
    }

    /// The user who knows what they want: jump anywhere, any time (§2, the
    /// persistent modal). No cinematic — a jump is not a lesson.
    public mutating func jump(to s: LatticeWizardStage) {
        stage = s
        playing = nil
    }

    /// Auto DENSITY plays the stress explanation; uniform does not (there is
    /// nothing to explain about a flat field).
    public mutating func setDensityMode(_ m: LatticeDensityMode) {
        densityMode = m
        if stage != .lattice { stage = .lattice }
        play(m == .auto ? .stressWipeAndDive : .tile)
    }

    /// Auto CELL SIZE jumps straight to the sample and shows how it looks (§2 C).
    public mutating func setCellSizeMode(_ m: LatticeCellSizeMode) {
        cellSizeMode = m
        if m == .auto {
            stage = .lattice
            play(.jumpToSample)
        }
    }

    /// The four boundary finishes are SHOWN on the part, switchable (§2 C).
    public mutating func setBoundary(_ b: LatticeBoundaryTreatment) {
        guard b != boundary else { return }
        boundary = b
        if stage != .lattice { stage = .lattice }
        play(.boundarySwap)
    }

    // MARK: what the centre stage should render

    /// How many cells across the sample at the current cell size — the number the
    /// tile animation counts up to. Bounded so a tiny cell cannot ask for a mesh
    /// the device will not draw in time (§3c: the sample is tessellated small).
    public var cellsAcross: Int {
        let n = Int((LatticeWizardSample.lengthMM / max(0.5, cellMM)).rounded())
        return min(Self.maxCellsAcross, max(1, n))
    }

    /// The tessellation ceiling. Chosen so the worst case stays a few thousand
    /// triangles — the reason the preview is fast is that the sample is SMALL and
    /// tessellated at screen resolution, not anything about a file format.
    public static let maxCellsAcross = 5

    /// The mesh the centre stage shows right now: one cell in Stage A, the tiled
    /// block in Stage B. `progress` in [0, 1] drives the tile expansion.
    public func stageMesh(progress: Double = 1) -> ViewerMesh {
        let cells = stage == .cell
            ? 1
            : max(1, Int((Double(cellsAcross) * max(0, min(1, progress))).rounded()))
        return LatticeSamplePatch.mesh(lattice: lattice, cellMM: cellMM,
                                       cells: cells,
                                       relativeDensity: relativeDensity)
    }

    /// The triangle count the current stage will draw — the latency budget, known
    /// before the mesh is built.
    public var stageTriangleCount: Int {
        LatticeSamplePatch.triangleCount(lattice: lattice,
                                         cells: stage == .cell ? 1 : cellsAcross)
    }
}
