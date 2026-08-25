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
///
/// ★ THE ORDER IS §5d's, UNCHANGED FROM PR 328's BUILD: one cell alone → the cell
/// flies into the sample and tiles it → density and boundary finish, with the
/// stress-field wipe on Auto. PR 328 had the first two; `finish` is the third,
/// which existed as a set of controls with no stage of its own.
/// ★ TWO VIEWS, NOT THREE STAGES (maintainer, 2026-08-14).
///
/// ★ HIS INSTRUCTION: *"Combine the two modals together… Also make it so you can
/// go back and forth. These are now 'views'. One cell or a lattice. Do not
/// include the 'Finish' section."*
///
/// The page was a three-stage WIZARD you advanced through with Next, and its
/// stage list was mirrored by a floating card that duplicated every control. It
/// is now TWO VIEWS you switch between freely, and the switch lives at the bottom
/// of the one modal:
///
///     ONE CELL      what a single cell IS      — Type, Thickness
///     IN THE PART   what it does to the part   — Cell size (+ its number, if it
///                                                has one), Density, Finish
///
/// ★ `finish` IS NOT A VIEW. Density and Finish are things you do to the lattice
/// IN THE PART, so they live in that view; there is no third tab for them.
public enum LatticeWizardStage: Int, Equatable, Sendable, CaseIterable {
    /// One cell, large, centred, rotatable.
    case cell = 0
    /// The cell has tiled the sample part — and everything that happens to it
    /// there: its size, its density, its boundary finish.
    case lattice = 1

    /// ★ Three words at most (R7).
    public var title: String {
        switch self {
        case .cell: return "One cell"
        case .lattice: return "In the part"
        }
    }

    /// The settings this stage is ABOUT — derived by filtering
    /// `LatticeWizardSetting`, so the wizard's stage list and the side modal's
    /// sub-titles are ONE table read two ways and can never disagree (§5c).
    public var settings: [LatticeWizardSetting] {
        LatticeWizardSetting.allCases.filter { $0.stage == self }
    }

    public var next: LatticeWizardStage? {
        LatticeWizardStage(rawValue: rawValue + 1)
    }
}

/// ★ ONE SETTING. The wizard asks for it centre stage; the side modal offers it
/// under its stage's sub-title (§5c). The `stage` property is the whole coupling:
/// changing a setting in the modal moves the wizard to `stage`, and the wizard at
/// `stage` asks for exactly the settings that map back to it.
public enum LatticeWizardSetting: String, Equatable, Sendable, CaseIterable {
    case type, size, thickness
    case cellSize
    case density, finish

    /// ★ Two words at most (R7).
    public var title: String {
        switch self {
        case .type: return "Type"
        case .size: return "Size"
        case .thickness: return "Thickness"
        case .cellSize: return "Cell size"
        case .density: return "Density"
        case .finish: return "Finish"
        }
    }

    /// The view whose VISUAL OUTPUT shows this setting doing something.
    ///
    /// ★ `size` MOVED OUT OF "ONE CELL" (maintainer, 2026-08-14): *"do not include
    /// 'Size' twice. Remove size from the 'one cell' view. Put it below the 'cell
    /// size' area in the 'part' view. Auto needs no cell size, fixed needs one,
    /// and swept needs a range. All of these are in the part view."*
    ///
    /// It was asked TWICE — once as "Size" under ONE CELL and again as the swept
    /// window under Cell size — which is the duplication he is removing. There is
    /// now one place a cell dimension is entered, and `cellSizeMode` decides
    /// whether it is nothing, one number, or two.
    public var stage: LatticeWizardStage {
        switch self {
        case .type, .thickness: return .cell
        case .size, .cellSize, .density, .finish: return .lattice
        }
    }

    /// ★ `size` is not a row of its own any more — it is rendered by `cellSize`
    /// as that mode's own field(s), directly beneath the mode segment. Listing it
    /// separately would put the number back in two places.
    public var isRenderedByCellSize: Bool { self == .size }
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
    /// ★ §9(a) — THE SWEEP WINDOW'S TWO ENDS.
    ///
    /// ★ THIS IS THE DEFECT, AND IT IS AN ABSENCE. `LatticeSettings` has carried
    /// `cellMinMM`/`cellMaxMM` since the cell-size-sweep task, and `runSpec`
    /// emits them as `cell_min_mm` / `cell_max_mm` — but this model never read
    /// them, so the wizard's "Swept" segment had nothing to show and nothing to
    /// write. His 2:42 AM screenshot ("Swept" selected, no range fields at all)
    /// is exactly that: the mode could not express a range even in principle,
    /// and `applied(to:)` handed the project back whatever it already had.
    public var cellMinMM: Double
    public var cellMaxMM: Double
    /// How far in from a face's outline the shape-fit grade keeps stepping down, in
    /// cells. See `LatticeSettings.shapeFitBandMM`.
    public var shapeFitBandMM: Double
    /// The hand-set strut thickness (mm), or nil for derived — see
    /// `LatticeSettings.manualStrutThicknessMM`.
    public var manualStrutThicknessMM: Double?
    public var boundary: LatticeBoundaryTreatment

    /// ★★ THE SIM PERMISSION (maintainer, 2026-08-17) — "a dark glass on/off
    /// check with a 'Simulate Stresses' at the top of the 'Lattice Settings'
    /// modal (above the 'type')".
    ///
    /// It is the page's copy of `LatticeSettings.simulateStresses`, and it moves
    /// through `setSimulateStresses` so the per-axis migration rule is the SAME
    /// one the stored settings enforce — not a second, similar rule written in
    /// the view.
    public var simulateStresses: Bool = true

    /// The top-centre disclaimer (§3b) — one line, an X, dismissible, and it
    /// stays dismissed for the session.
    public var showDisclaimer: Bool = true

    public init(topologyID: String = LatticeType.octet.id,
                cellMM: Double = 6,
                relativeDensity: Double = 0.35,
                densityMode: LatticeDensityMode = .sim,
                cellSizeMode: LatticeCellSizeMode = .auto,
                cellMinMM: Double = LatticeSettings.defaultCellMinMM,
                shapeFitBandMM: Double = LatticeSettings.defaultShapeFitBandCells,
                cellMaxMM: Double = LatticeSettings.defaultCellMaxMM,
                // ★ DEFAULT NONE (maintainer, 2026-08-14): "it should
                // default to 'none'". A bare lattice is what the page
                // should open on; a dressing is something you add.
                boundary: LatticeBoundaryTreatment = .none,
                manualStrutThicknessMM: Double? = nil,
                simulateStresses: Bool = true,
                retainSubfloor: Bool = false) {
        self.topologyID = topologyID
        self.cellMM = cellMM
        self.relativeDensity = relativeDensity
        self.densityMode = densityMode
        self.cellSizeMode = cellSizeMode
        self.cellMinMM = cellMinMM
        self.shapeFitBandMM = shapeFitBandMM
        self.cellMaxMM = cellMaxMM
        self.boundary = boundary
        self.manualStrutThicknessMM = manualStrutThicknessMM
        self.simulateStresses = simulateStresses
        self.retainSubfloor = retainSubfloor
    }

    /// ★★ KEEP THE LATTICE WHERE THE PART IS TOO THIN TO CERTIFY IT.
    ///
    /// The switch existed, on the results page, behind a completed run — so the
    /// setting that decides whether half a part is lattice or solid could not be
    /// reached from the page where the lattice is set up. It is a lattice SETTING and
    /// it belongs with the others.
    public var retainSubfloor: Bool = false

    /// ★ HOW AUTO VARIES THE CELL — the secondary question that appears only when the
    /// cell size is Auto. Only `defaultGrade` is wired; see `LatticeCellTransition`.
    public var cellTransition: LatticeCellTransition = .defaultGrade
    /// ★ THE GRADING OPTIONS (2026-08-25) — see `LatticeGradingMode`.
    public var gradingMode: LatticeGradingMode = .full
    public var gradeStepStyle: LatticeGradeStepStyle = .stepped
    /// ★ "Allow single-cell members" — see `LatticeSettings.singleCellMembers`. Setting
    /// it TRUE also writes the finish, because core's one-cell floor requires one.
    public var singleCellMembers: Bool = false {
        didSet {
            if singleCellMembers, boundary == .none || boundary == .rim {
                boundary = .fullSkin
            }
        }
    }

    /// ★ THE PERMISSION'S SETTER, AND IT DELEGATES. The migration rule (density
    /// `.sim ⇒ .uniform`, cell `.swept ⇒ .fixed`) lives in `LatticeSettings`
    /// and is applied by borrowing it, so the wizard cannot drift into a second
    /// version of the same rule — the failure this page has already had with two
    /// depth resolvers and two strut laws.
    public mutating func setSimulateStresses(_ on: Bool) {
        var probe = LatticeSettings(enabled: true)
        probe.densityMode = densityMode
        probe.cellSizeMode = cellSizeMode
        probe.setSimulateStresses(on)
        simulateStresses = probe.simulateStresses
        densityMode = probe.densityMode
        cellSizeMode = probe.cellSizeMode
    }

    /// ★ WHETHER THE SAVE SHOULD KICK OFF AN FEA. Same question, same answer as
    /// the stored settings — asked through them rather than re-derived.
    public var needsStressSolve: Bool {
        var probe = LatticeSettings(enabled: true)
        probe.densityMode = densityMode
        probe.cellSizeMode = cellSizeMode
        probe.simulateStresses = simulateStresses
        return probe.needsStressSolve
    }

    /// Seed from a project's stored settings, so opening the page shows what the
    /// project already has rather than the page's own defaults.
    public init(settings s: LatticeSettings) {
        self.init(topologyID: s.topologyID, cellMM: s.cellMM,
                  relativeDensity: max(0.05, s.maxRelativeDensity),
                  densityMode: s.densityMode, cellSizeMode: s.cellSizeMode,
                  cellMinMM: s.cellMinMM,
                  shapeFitBandMM: s.shapeFitBandMM,
                  cellMaxMM: s.cellMaxMM,
                  boundary: s.boundary,
                  manualStrutThicknessMM: s.manualStrutThicknessMM,
                  simulateStresses: s.simulateStresses,
                  retainSubfloor: s.retainSubfloorInUnloadedRegions)
        self.cellTransition = s.cellTransition
        self.singleCellMembers = s.singleCellMembers
        self.gradingMode = s.gradingMode
        self.gradeStepStyle = s.gradeStepStyle
    }

    /// Write the selections back. Only the fields this page owns move.
    public func applied(to s: LatticeSettings) -> LatticeSettings {
        var out = s
        out.topologyID = topologyID
        out.cellMM = cellMM
        out.maxRelativeDensity = relativeDensity
        out.densityMode = densityMode
        out.cellSizeMode = cellSizeMode
        // ★ §9(a) — and the window goes back with them, so a range typed in the
        // wizard is the range the job carries.
        out.cellMinMM = cellMinMM
        out.shapeFitBandMM = shapeFitBandMM
        out.cellMaxMM = cellMaxMM
        out.boundary = boundary
        out.manualStrutThicknessMM = manualStrutThicknessMM
        out.simulateStresses = simulateStresses
        // ★★ SUB-FLOOR RETENTION, SET HERE (maintainer, 2026-08-20: "If you're
        // saying I need to actually first optimize a part THEN go to a lattice page,
        // you're out of your fucking mind. That's untenable. Add it to the settings
        // of the lattice stage").
        //
        // ★ AND IT CANNOT RIDE ALONGSIDE "fit". Core THROWS on the pair
        // (grading.cpp:66-70) — two mechanisms deciding the same material, two
        // receipts — so the wizard drops it exactly as `LatticeAutoPosture` does
        // rather than letting the page author a job core will refuse.
        // ★ AND ONLY A WIRED TRANSITION REACHES THE JOB. An unavailable one would
        // otherwise ride along as `defaultGrade`'s behaviour under another name.
        out.cellTransition = cellTransition.unavailableReason == nil
            ? cellTransition : .defaultGrade
        // ★ AND THE FINISH IT REQUIRES TRAVELS WITH IT. `singleCellMembers` already
        // wrote `boundary` when it was switched on; carrying both keeps the pair
        // consistent on the wire, so a job can never ask for a one-cell floor without
        // the finish core needs to grant it.
        out.singleCellMembers = singleCellMembers
        if out.singleCellMembers, out.boundary == .none || out.boundary == .rim {
            out.boundary = .fullSkin
        }
        // ★★★ AND THE CHOICE NOW REACHES THE JOB (maintainer, 2026-08-21: "Please
        // connect the Stepped and Organic algos"). `cellTransition` was a control that
        // set a stored value nothing downstream read — the decorative-control defect
        // its own note warned about, in the file that warned about it. It is core's
        // `LatticeAlgorithm`, so it is written as core's own name and `gradingDictionary`
        // decides whether a key appears at all.
        out.algorithm = out.cellTransition.coreAlgorithm
        // ★ The grading options ride with the algorithm choice (2026-08-25).
        out.gradingMode = gradingMode
        out.gradeStepStyle = gradeStepStyle
        out.retainSubfloorInUnloadedRegions =
            (cellSizeMode == .fit) ? false : retainSubfloor
        if !out.retainSubfloorInUnloadedRegions {
            // Core's schema refuses the dependents without the switch.
            out.subfloorPerRegion = false
            out.subfloorStressFraction = nil
        }
        out.enabled = true
        return out
    }

    /// ★ §9(b)/§9(d) — A SWEEP THAT CANNOT SWEEP, NAMED BEFORE THE RUN.
    ///
    /// `cell_plan_max_level` (core/src/simp/cell_plan.cpp:43-51) builds a DYADIC
    /// ladder: the levels are `min · 2^L`. A window narrower than 2× therefore
    /// holds exactly ONE level, every block lands on it, and the receipt comes
    /// back `distinct_cells: 1` with `strut_radius_min_mm == strut_radius_max_mm`
    /// — which is precisely what his 2.0–4.0 mm run reported (0.225 / 0.225) and
    /// what read as the mode being broken.
    ///
    /// ★ 2.0–4.0 IS EXACTLY 2×, so it holds TWO levels and is not warned about.
    /// The collapse he saw therefore came from the SECOND half of the rule, not
    /// the window: a block takes level L only when `need_max == L`, and `need` is
    /// derived from the block's thinnest DENSITY. A flat density field gives every
    /// block the same `need`, so every block takes the same level.
    public var sweptWindowWarning: String? {
        guard cellSizeMode == .swept, cellMinMM > 0, cellMaxMM >= cellMinMM
        else { return nil }
        if cellMaxMM < cellMinMM * 2 {
            return String(format: "This window holds one cell size. Widen it to "
                          + "%.1f mm or more to sweep.", cellMinMM * 2)
        }
        return nil
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

    /// ★ GO BACK AND FORTH BETWEEN THE TWO VIEWS (maintainer, 2026-08-14). This
    /// was `advance()` — a one-way Next through three stages. The views are now
    /// switchable in either direction from the segment at the bottom of the modal,
    /// so this exists only for the keyboard/next affordance and wraps.
    public mutating func advance() {
        move(to: stage == .cell ? .lattice : .cell)
    }

    public var hasNext: Bool { stage.next != nil }

    /// ★ THE COUPLING, IN ONE FUNCTION (§5c). A setting changed in the side modal
    /// moves the wizard to that setting's stage so the change is SEEN, and moving
    /// to a stage plays that stage's cinematic. The modal and the wizard are two
    /// views of one state machine, which is bar R5.
    public mutating func touched(_ setting: LatticeWizardSetting) {
        move(to: setting.stage)
    }

    /// Enter a stage and play what that stage is for. Re-entering the stage the
    /// page is already on does NOT replay — a size scrub would otherwise restart
    /// the morph on every frame of the drag.
    public mutating func move(to s: LatticeWizardStage) {
        guard s != stage else { return }
        stage = s
        switch s {
        case .cell: playing = nil; playToken += 1
        case .lattice: play(.tile)
        }
    }

    /// Setting the TYPE morphs the cell (§2 Stage A). Never a swap.
    public mutating func setTopology(_ id: String) {
        guard id != topologyID else { return }
        topologyID = id
        stage = .cell            // §5c: the type's visual output is the lone cell
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
    /// nothing to explain about a flat field). §5c: it also moves the wizard to
    /// the stage whose visual output is the density.
    public mutating func setDensityMode(_ m: LatticeDensityMode) {
        densityMode = m
        // Density is an IN-THE-PART setting now, so showing it means showing the
        // tiled sample — never the lone cell.
        stage = LatticeWizardSetting.density.stage
        play(m == .sim ? .stressWipeAndDive : .tile)
    }

    /// Auto CELL SIZE jumps straight to the sample and shows how it looks (§2 C).
    public mutating func setCellSizeMode(_ m: LatticeCellSizeMode) {
        cellSizeMode = m
        if m == .auto {
            stage = LatticeWizardSetting.cellSize.stage
            play(.jumpToSample)
        }
    }

    /// The boundary finishes are SHOWN on the part, switchable (§2 C).
    public mutating func setBoundary(_ b: LatticeBoundaryTreatment) {
        guard b != boundary else { return }
        boundary = b
        stage = LatticeWizardSetting.finish.stage
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
    /// - Parameter derivedCellMM: the cell CORE'S OWN DERIVATION gives the declared
    ///   member under the CURRENT floor — supplied by the page, which owns the print
    ///   bead and the declared depths this model does not carry. Non-nil ⇒ the sample
    ///   is drawn at that cell, so the single-cell/member toggle (floor 2 → 1) is
    ///   VISIBLE on the sample instead of decorative (his backlog, 2026-08-24: "the
    ///   settings-page sample patch does not change when the single-cell/member
    ///   toggle moves"). nil ⇒ the stored `cellMM`, exactly as before.
    public func stageMesh(progress: Double = 1,
                          derivedCellMM: Double? = nil,
                          // ★ The single-cell floor, for the stepped sample's
                          // coarse half (1 ⇒ one cell fills it). nil ⇒ legacy.
                          steppedCoarsePerHalf: Int? = nil) -> ViewerMesh {
        let cellMM = derivedCellMM ?? self.cellMM
        let cells = stage == .cell
            ? 1
            : max(1, Int((Double(cellsAcross) * max(0, min(1, progress))).rounded()))
        // ★ THE SAMPLE, SAID OUT LOUD — the 2026-08-25 round burned an hour on a
        // sample that never changed while every control claimed it should.
        NSLog("DIAG sampleMesh stage=\(stage) transition=\(cellTransition.rawValue) "
              + "k=\(steppedCoarsePerHalf.map(String.init) ?? "nil") cells=\(cells) "
              + "cellMM=\(String(format: "%.2f", cellMM)) derived=\(derivedCellMM != nil)")
        // ★ §10 — THE FINISH REACHES THE GEOMETRY. This call omitted `boundary`
        // entirely, so None / Rim / Skin all produced the same mesh and the chips
        // were decoration. The lone cell shows no boundary — a single cell has no
        // block to dress — so the finish appears in the IN THE PART view, which is
        // also the view its control now lives in.
        // ★ AND THE GRADE REACHES IT TOO. A single cell has no transition to show, so
        // the cell view stays the one cell; the IN THE PART view is where the three
        // algorithms differ, which is also where the control lives.
        return LatticeSamplePatch.mesh(lattice: lattice, cellMM: cellMM,
                                       cells: cells,
                                       // ★ CLAMPED FOR LEGIBILITY, DISPLAY-ONLY,
                                       // IN-THE-PART ONLY (2026-08-25): his
                                       // aesthetic band stores max = 1.0, and at
                                       // solid density every strut fuses — the
                                       // block sample WAS the quilt ("It looks
                                       // terrible"). The block's job is
                                       // STRUCTURE, so its struts draw at a
                                       // density that never fuses. The ONE CELL
                                       // view keeps the honest thickness (that
                                       // view exists to show it), and the
                                       // model's own value round-trips to
                                       // maxRelativeDensity on Save & Exit and
                                       // must not move.
                                       relativeDensity: stage == .cell
                                           ? relativeDensity
                                           : min(0.35, relativeDensity),
                                       boundary: stage == .cell ? .none : boundary,
                                       transition: stage == .cell
                                           ? .defaultGrade : cellTransition,
                                       steppedCoarsePerHalf: stage == .cell
                                           ? nil : steppedCoarsePerHalf)
    }

    /// The triangle count the current stage will draw — the latency budget, known
    /// before the mesh is built.
    public var stageTriangleCount: Int {
        LatticeSamplePatch.triangleCount(lattice: lattice,
                                         cells: stage == .cell ? 1 : cellsAcross)
    }
}

/// ★ §7 — WHY THE SAMPLE WAS INVISIBLE, AS A TYPE THAT CANNOT DO IT AGAIN.
///
/// THE DEFECT, with the two lines that caused it. `LatticeSetupWizard` passed the
/// renderer
///
///     reveal: Float(model.densityMode == .sim ? wipe : 1)     (line 75)
///     @State private var wipe: Double = 0                      (line 42)
///
/// and `MetalMeshView`'s fragment shader discards every fragment above the reveal
/// height:
///
///     if (t > reveal.x) discard_fragment();                    (line 126)
///
/// §4b of the previous task had already made `densityMode` default to `.auto` on a
/// new project, so the page opened with `reveal = 0` and the shader threw away
/// every pixel of a mesh that had been built, uploaded and counted. That is the
/// maintainer's report exactly: an empty viewport with "1 ms · 544 tris" beside it.
/// Nothing was wrong with the camera, the scale or the frustum — the geometry was
/// on screen and each of its fragments was individually discarded.
///
/// THE SHAPE OF THE FIX. The wipe is a CINEMATIC — a thing that runs and finishes —
/// not a property of a setting. So it is modelled as one: the reveal is 1 unless a
/// wipe is actually running, and `begin`/`end` bracket it. A density mode can no
/// longer hold the page blank, because the density mode is not an input here.
public struct LatticeWizardReveal: Equatable, Sendable {

    /// How far the wipe has come, 0…1. Meaningless unless `wiping`.
    public private(set) var fraction: Double = 0
    /// Whether a wipe is running RIGHT NOW.
    public private(set) var wiping: Bool = false

    public init() {}

    /// ★ WHAT THE RENDERER GETS. 1 — everything drawn — unless a wipe is running.
    public var value: Double { wiping ? fraction : 1 }

    public mutating func begin() {
        wiping = true
        fraction = 0
    }

    public mutating func step(to f: Double) {
        guard wiping else { return }
        fraction = Swift.min(1, Swift.max(0, f))
    }

    /// The wipe landed (or was interrupted by a stage change): the part is whole
    /// again. Every exit from a wipe goes through here, so there is no path that
    /// leaves the page holding a partial reveal.
    public mutating func end() {
        wiping = false
        fraction = 1
    }
}
