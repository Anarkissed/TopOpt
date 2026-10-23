// FlexibleStageModel — the Flexible stage's state and its recompute pipeline (task
// 2026-09-29-flexible-screens, A1).
//
// ★ WHO COMPUTES WHAT. Every number shown comes from core through FlexibleKit (M9). This
// model only decides WHEN to ask and caches the answers:
//   * the scene (part, grid, lattice mask, face regions) opens once per placement;
//   * a face's stack is built once per (face, frame rotation) and cached in core AND here;
//   * a dragged curve point re-runs ONLY the squish map (≈1 ms) at once, then the design
//     (≈0.1 s) off the main thread, coalesced so a fast drag never queues designs;
//   * Auto, the density field, conflicts and stamp checks follow the design.
//
// ★ SETTINGS LIVE IN THE PROJECT (`project.lattice.flexible`), so they are saved with it
// and undone by the same snapshot history as every other stage (S5).

import Combine
import Foundation
import simd
import TopOptKit

/// The bridge calls, serialised off the main thread. One scene at a time.
actor FlexibleWorker {
    private(set) var scene: FlexibleScene?
    private(set) var sceneKey: String?
    /// ★ ROUND 7, RULING 6 (FlexibleCoreDoor): every scene this worker opens goes through its door.
    nonisolated let door = FlexibleCoreDoor()
    /// ★ RULING 6: let go of core's scene for want of a face-prism (`hold`) — every ask is refused in his words until a
    /// scene opens again.
    private(set) var held = false

    func open(jobJSON: String, jobDir: String, key: String, facePrism: Bool) throws -> FlexibleScene.Info {
        if sceneKey != key || scene == nil {
            scene = nil
            scene = try door.open(jobJSON: jobJSON, jobDir: jobDir, facePrism: facePrism)
            sceneKey = key
            held = false
        }
        return try scene!.info()
    }
    /// ★ RULING 6: no face-prism — core's scene is let go; nothing can be asked on it any more.
    func hold() { scene = nil; sceneKey = nil; held = true }
    func withScene<T>(_ body: (FlexibleScene) throws -> T) throws -> T {
        guard let s = scene else {
            if held { throw FlexibleCoreDoor.Refusal.noFacePrism }
            throw TopOptError(message: "The part is still opening.")
        }
        door.noteAsk()
        return try body(s)
    }
    /// ★ BATCH G: the scene itself, fetched in one quick hop — the squish sims run OFF this actor
    /// (it serialises the design calls and must never wait seconds on a solve).
    func sceneRef() -> FlexibleScene? {
        if scene != nil { door.noteAsk() }
        return scene
    }
    /// ★ ROUND 6 ITEM 2: a scene already opened on the regions the stage is about to hold (the strips' [Done]: core
    /// was asked about the strips on it before the cut was committed) — the next `open` with its key reuses it.
    func install(_ s: FlexibleScene, key: String) { scene = s; sceneKey = key; held = false }
}

/// One control point of one face's X or Y curve (the × on the model, round 3 item 8).
public struct FlexCurvePoint: Equatable, Sendable {
    public let region: Int
    public let axis: String      // "x" | "y"
    public let index: Int
}

public struct FlexFaceKey: Hashable, Sendable {
    public let region: Int
    public let rotation: Int
}

/// Where a face's drawings go in 3D — every point from core's frame (from_uv / to_uv).
public struct FlexFaceGeometry {
    /// from_uv at every column centre, column order.
    public let centres: [SIMD3<Double>]
    /// The X edge (v = 0) and the Y edge (u = 0), on the face — both curves are drawn at
    /// once (round 3: "X and Y always combined"; the centre→edge line went with its mode).
    public let baselineX: FlexibleCurveBaseline
    public let baselineY: FlexibleCurveBaseline
    /// The frame's corner (u = 0, v = 0) on the face: where the X / Y arrows start.
    public let corner: SIMD3<Double>
    /// to_uv + t of every flat vertex of the part (the dent's ramp).
    public let partUVT: [Double]

    static func compute(scene: FlexibleScene, key k: FlexFaceKey, stack st: FlexStackInfo,
                        partFlat: [Float]) throws -> FlexFaceGeometry {
        let centres = try scene.fromUV(face: k.region, rotation: k.rotation,
                                       st.columns.map { SIMD2($0.uMM, $0.vMM) })
        // the entry along the load of the column nearest (u, v): the edge hugs the face
        // (★ AP1: the same lookup, shared with FlexiblePressReframe — FlexStackInfo.entryT(nearU:v:))
        func entry(_ u: Double, _ v: Double) -> Double { st.entryT(nearU: u, v: v) }
        let n = 30
        func line(_ uv: (Double) -> (Double, Double)) throws -> [SIMD3<Double>] {
            let pts = (0...n).map { uv(Double($0) / Double(n)) }
            let w = try scene.fromUV(face: k.region, rotation: k.rotation, pts.map { SIMD2($0.0, $0.1) })
            return zip(w, pts).map { $0 + st.load * entry($1.0, $1.1) }
        }
        let amp = max(5, min(40, 0.25 * max(st.uExtentMM, st.vExtentMM)))
        let up = -st.load
        let bx = FlexibleCurveBaseline(points: try line { (st.uExtentMM * $0, 0) }, up: up, amplitudeMM: amp)
        let by = FlexibleCurveBaseline(points: try line { (0, st.vExtentMM * $0) }, up: up, amplitudeMM: amp)
        let corner = try line { _ in (0, 0) }.first ?? .zero
        var xyz = [Double](); xyz.reserveCapacity(partFlat.count)
        for f in partFlat { xyz.append(Double(f)) }
        let uvt = try scene.toUVT(face: k.region, rotation: k.rotation, xyz)
        return FlexFaceGeometry(centres: centres, baselineX: bx, baselineY: by,
                                corner: corner, partUVT: uvt)
    }
}

extension FlexStackInfo {
    /// The column at (iu, iv), or −1 (Stack::column_at).
    public func column(_ iu: Int, _ iv: Int) -> Int {
        guard iu >= 0, iv >= 0, iu < nu, iv < nv else { return -1 }
        return cell[iv * nu + iu]
    }

    /// Core's entry (along the load) of the column nearest (u, v) — the ring search FlexFaceGeometry
    /// has always used; 0 when the stack has no column.
    public func entryT(nearU u: Double, v: Double) -> Double {
        guard nu > 0, nv > 0, pitchMM > 0 else { return 0 }
        let iu = Swift.min(nu - 1, Swift.max(0, Int(u / pitchMM))), iv = Swift.min(nv - 1, Swift.max(0, Int(v / pitchMM)))
        var best: (Int, Int)? = nil
        for r in 0..<Swift.max(nu, nv) {
            for dv in -r...r { for du in -r...r where abs(du) == r || abs(dv) == r {
                let c = column(iu + du, iv + dv)
                if c >= 0, best == nil || du * du + dv * dv < best!.1 { best = (c, du * du + dv * dv) }
            } }
            if best != nil { break }
        }
        return best.map { columns[$0.0].entryT } ?? 0
    }
}

@MainActor
public final class FlexibleStageModel: ObservableObject {

    /// ★ ROUND 3 (item 5): Face | Stamps | More (Filament / Squish / Auto / Physics folded in).
    /// ★ ROUND 4 (D1, his answer 3): Face | More — a face's ONE stamp is its Shape (Stamp), on
    /// the Face tab; the Stamps tab and its check stamps are gone.
    public enum Tab: String, CaseIterable, Identifiable {
        case face = "Face", more = "More"
        public var id: String { rawValue }
    }
    public enum SceneState: Equatable {
        case idle, opening, ready, failed(String)
    }

    // inputs
    public let project: ProjectModel
    public let materialsPath: String?
    public let library: FlexibleStampLibrary?
    let persist: () -> Void
    private let worker = FlexibleWorker()
    /// The bridge worker, for tests that read core through the same open scene.
    var workerForTests: FlexibleWorker { worker }
    /// ★ BATCH G: the worker the squish sims fetch the scene from (one hop; they run off it).
    var squishWorker: FlexibleWorker { worker }
    /// ★ ANGLED PRESSES (AP1): the worker FlexiblePressReframe reads core's frames through.
    var frameWorker: FlexibleWorker { worker }
    /// ★ ANGLED PRESSES (AP2): FlexibleMeet and core's answers about it, per mesh and per open scene (+Meet).
    let meetCache = FlexibleMeetCache()

    // what the screens show
    @Published public private(set) var catalogue: [FlexMaterialInfo] = []
    @Published public private(set) var catalogueError: String?
    @Published public private(set) var bands: FlexErrorBandsInfo?
    @Published public private(set) var sceneState: SceneState = .idle
    @Published public private(set) var sceneInfo: FlexibleScene.Info?
    @Published public var tab: Tab = .face { didSet { if oldValue != tab { tabChanged() } } }
    @Published public var selectedRegion: Int? { didSet { if oldValue != selectedRegion { selectionChanged() } } }
    /// ★ ANGLED PRESSES (AP1): the press whose card is open (FlexiblePress id); nil ⇒ none.
    @Published public var selectedPress: UUID?
    /// ★ R7-E1 — THE FLAT PRISM (FlexibleStageModel+FlatPrism): what a handle shows while it moves (never in the settings or in
    /// history), the press a commit is running for (the handles are disabled meanwhile), the last release the lattice stopped (its
    /// line and [Set N mm]), the press the page should turn the camera to ([Done], a press selected).
    @Published public internal(set) var flatPreview: FlexibleFlatPreview?
    @Published public internal(set) var flatCommitting: UUID?
    @Published public internal(set) var lastFlatStop: FlexibleFlatStop?
    @Published public internal(set) var flatCameraRequest: UUID?
    /// ★ R7-E4: [Top] / [45°] beside a flat press's Shape row — the page turns the camera to that curve view.
    @Published public internal(set) var pressViewRequest: FlexiblePressViewRequest?
    /// ★ U2: the curve window's draft (FlexiblePressCurveModal) — nil: the window is closed.
    @Published public internal(set) var curveDraft: FlexiblePressCurveDraft?
    /// ★ R7-E1 — THE SEAM: each strip press as core's open scene holds it (a synthetic key, core's press stack, the apex's t, the
    /// footprint's per-triangle normals), and a press core refused, with its plain line.
    @Published internal(set) var pressRegistrations: [UUID: FlexiblePressRegistration] = [:]
    @Published public internal(set) var pressRefusals: [UUID: String] = [:]
    /// ★ R7-E1: M2's strips read through were said (once per session).
    var legacyStripsSaid = false
    /// ★ R7-E2: the ruling's angled-estimate sentence was popped (once per session, when a side press first goes into the job), or
    /// waits for the toast up now to clear.
    var sideSentenceSaid = false
    var sideSentencePending = false
    /// ★ R7-E2: core's stack conflicts among the faces AND the registered presses (a press stack named by its first region) — the
    /// presses' own (FlexibleSqueezeGroups.pressPinches); the faces' pinches keep reading `conflicts`, unchanged.
    @Published public internal(set) var pressConflicts: [FlexConflictInfo] = []
    /// ★ R7-E2: the gate's verdicts, memoised by what they are read from (the shared-surface pre-check clips triangles).
    var pressSupportMemo: (key: String, value: [UUID: FlexiblePressSupport.Verdict])?
    /// ★ R7-E1 REVIEW: core's exact lattice stop per press, found by a release (the arrow's bits, N, the lattice it was found on) —
    /// the next drag's hard stop (flatDragCap).
    var flatExactStops: [UUID: (bits: [UInt64], mm: Double, lattice: String)] = [:]
    /// ★ ROUND 6 ITEM 2: [+ New] → [Edges/corners] — pick mode (FlexibleEdgePick); nil when not picking. Nothing is
    /// stored in the project until [Done].
    @Published public var edgePick: FlexibleEdgePick?
    /// ★ R7-E1b: the open edges group's own pick state — its pressable edges and corners on the part; a tap ADDS one (FlexibleStageModel+EdgeAdd).
    @Published public var edgeAdd: FlexibleEdgePick?
    /// ★ R7-E3 (his notes of 2026-10-19 ~14:40: "When in a group do *not* highlight other edges/corners. Allow users to tap them to add
    /// OR add a "+" button"): the edges group (stored id) whose [+] is on — only then are its pressable edges and corners lit.
    @Published public var edgeAddingGroup: Int?
    /// ★ ROUND 7 (S, 4h): on [+ New] with nothing pressed, the face a tap chose to start Group 1 while the keypad asks its
    /// weight ("How much weight presses here?"); nil when nothing is asked.
    @Published public var newGroupAsk: Int?
    /// ★ ROUND 5 (S8): the folder tab open on the Settings modal's left rail (FlexibleSettingsRail).
    @Published public var rail: FlexibleRailTab = .group(FlexibleSqueezeGroups.first) { didSet { if oldValue != rail { railChanged() } } }
    /// ★ ROUND 7 (S, 4f): the open tab's members as they were after the last change (FlexibleSettingsOpenGroup) — the tab
    /// stays on them through the next one.
    var railKeep: FlexibleRailKeep?
    /// ★ U21 (UNDO-GHOST, his Img13: "Then I hit undo and now it shows the bend on the model but it is not actually showing the
    /// face in the modal anymore"): the tab and the face (and press) a delete or Reset all moved or cleared, remembered by
    /// `syncRail` — the page's Undo / Redo opens them again once their members are back (`restoreRailAfterHistory`). Survives
    /// the history's scene re-open; only Undo / Redo reads it.
    var railReturn: FlexibleRailKeep?
    var railReturnSelected: Int?
    var railReturnPress: UUID?
    /// ★ U21: the faces and presses just before the page's Undo / Redo (`historyWillRestore`) — a remembered tab opens again only
    /// when this history step brought its members back.
    var historyBefore: (faces: Set<Int>, presses: Set<UUID>)?
    /// ★ U21 (F12): a delete's undo step held open until the re-opened scene's write lands in it (`sealAfterReopen`).
    var stepHold: Task<Void, Never>?
    /// ★ ROUND 7 (S, verify): the last group (or [Rests]) tab he had open — a face no group holds, tapped on [Model], opens
    /// it (its card offers [Press it] there), never Group 1 by default.
    var lastWorkTab: FlexibleRailTab?
    /// ★ ROUND 5 (S9): the page's Exit left with nothing changed — the main page does nothing.
    var exitUnchanged = false
    /// ★ ROUND 5 (S9): a Save & Exit with the main page's Lattice view OFF only stored — the bake
    /// waits for the view (FlexibleMainStage).
    @Published public internal(set) var latticeBuildDeferred = false
    @Published public var showBuildable = false
    @Published public private(set) var stacks: [FlexFaceKey: FlexStackInfo] = [:]
    @Published public private(set) var geometry: [FlexFaceKey: FlexFaceGeometry] = [:]
    @Published public private(set) var liveS: [FlexFaceKey: [Double]] = [:]
    @Published public private(set) var designs: [FlexFaceKey: FlexFaceDesignInfo] = [:]
    @Published public private(set) var conflicts: [FlexConflictInfo] = []
    /// ★ ROUND 4 (D2): the TWO-SEGMENT designs of the faces a pinch presses (FlexiblePinch) —
    /// run with the designs; a face that is not pinched has none (core's own design stands).
    @Published public private(set) var segments: [FlexFaceKey: FlexiblePinch.Segments] = [:]
    /// ★ D2 REVIEW: a pinched face whose two-segment design threw (its words) — it keeps core's
    /// one profile and its card says so; the other faces keep their halves.
    @Published public private(set) var segmentErrors: [FlexFaceKey: String] = [:]
    /// ★ D2 REVIEW: the groups that will squish less than designed once the lattice carries every
    /// group (the firmer wins) — known with the designs, BEFORE Exit (FlexibleGroupEstimate).
    @Published public private(set) var groupMisses: [FlexibleGroupEstimate.Miss] = []
    @Published public private(set) var recommendation: FlexRecommendationInfo?
    @Published public private(set) var recommendationError: String?
    /// ★ R7-E2 (found by the suite, after the lattice became stale at another temperature): Auto's answer is on its way. While
    /// Auto decides the temperature or the family (`autoDecides`), the main page waits for it before it builds — one build, at
    /// the temperature the designs end at, never a first one at Auto's opening guess rebuilt a second later.
    @Published public private(set) var autoInFlight = false
    private var autoGeneration = 0
    /// Auto's answer can move the designs: the temperature or the family is left to Auto.
    public var autoDecides: Bool { settings.nozzleTempC == nil || settings.topology == "auto" }
    @Published public private(set) var checks: [UUID: FlexStampCheckInfo] = [:]
    @Published public private(set) var stampGrids: [UUID: FlexStamp] = [:]
    /// Check mode shows the stamp's dent instead of the design's (M14). ★ SINCE ROUND 4 (D1) NO
    /// UI SETS IT: the check stamps are gone from the page (his answer 3) and the migration
    /// empties the list — the plumbing (this, `checks`, the check branch of FlexibleShownValues
    /// and of the job) is KEPT for D2's load cases / G's case picker, which show a named press.
    @Published public var checkStampShown: UUID?
    /// The curve point showing its × (round 3, item 8); a tap anywhere on the part clears it.
    @Published public var curvePoint: FlexCurvePoint?
    /// ★ ROUND 3 (item 1.1): the page's exaggeration k, FROZEN while the depth chip is dragged
    /// — the dent, the prism and the chip hold one scale while the finger moves.
    @Published public var frozenExaggeration: Double?
    /// ★ ROUND 6 (item 3): the page's views — [Prisms] and [Groups] (FlexibleStageViews). Session DISPLAY
    /// state: never a setting, never the lattice's key, never an action (Exit stays "Exit"); the main page
    /// reads the same model's.
    /// ★ ROUND 7 (F, his answer: "The curve should be viewed as nothing but the curve without any view turned on. Turning
    /// heat map on shows colour."): the page opens with no view on — Heat off (`openingViews`).
    @Published public var views: FlexibleStageViews = FlexibleStageModel.openingViews
    /// ★ ROUND 7 (F, his answer 2: "Group trash should confirm deletion."): the group whose trash asks "Delete Group 2?".
    @Published public var groupDeleteAsk: Int?
    /// ★ U21 (DEL-CONFIRM, his Img13): the face whose ⊖ asks "Take Face 6 out?", the press whose trash asks "Remove Edge 12?",
    /// Reset all's ask, and the fix pop-up's Remove fix asking (its `FlexibleFixPopup.id`) — each in place (FlexibleConfirmInPlace).
    @Published public var faceRemoveAsk: Int?
    @Published public var pressRemoveAsk: UUID?
    @Published public var resetAsk = false
    @Published public var fixRemoveAsk: String?
    /// Test control only (round 6): a view toggle stored in the settings (the red control of the rule above).
    var controlViewsInSettings = false
    @Published public private(set) var lastError: String?
    /// The generated lattice (Generate button) and its build state.
    @Published public private(set) var lattice: FlexibleGeneratedLattice?
    @Published public private(set) var latticeBuilding = false
    @Published public private(set) var latticeError: String?
    /// ★ BATCH G: each squeeze group's squish sim for the CURRENT lattice (by sim id): pending,
    /// its calibrated FE field, or core's words. One publish per landed sim (FlexibleStageModel+Squish).
    @Published public internal(set) var squish: [String: FlexibleSquishState] = [:]
    /// ★ BATCH N: each group's squish solved IN STEPS (FlexibleFERefine), once its quick sim landed:
    /// running (n of 8), its refined field, or kept (the quick one stays — why). Same generation as `squish`.
    @Published public internal(set) var refine: [String: FlexibleRefineState] = [:]
    /// The lattice generation `squish` belongs to.
    public internal(set) var squishGeneration: Int?
    /// What the sims need, built in the lattice's build task (released once the solver has it).
    var feRequest: FlexibleFERequest?
    /// ★ U21 · I3 (his picks of 2026-10-21 ~15:45: "the linked walls HOLD that lattice"): the shown lattice's FE request, KEPT (the
    /// solver releases its own copy) so a link added / removed re-solves the sims with new walls, never the lattice
    /// (FlexibleStageModel+Squish.relinkSims; ~6.5 MB on his l-bracket).
    var simRequest: FlexibleFERequest?
    /// ★ U21 · I3: bumped by every relink; a field (or refine) of another epoch is discarded (the reviewer's E(5): "an answer
    /// counts only for the job on screen").
    public internal(set) var holdEpoch = 0
    /// ★ U21 · I3: the linked walls per sim id the shown sims are solved (or solving) with.
    public internal(set) var shownWalls: [String: [FlexHeldWallInfo]] = [:]
    /// ★ U21 · I3: the emission the links' walls are read from (memoised; links themselves never re-key it).
    var linkRegionsMemo: (key: FlexibleIncludeMemoKey, regions: [LatticeRegionSpec])?
    /// ★ U21 · I3, RED CONTROL only: a link change (or its Undo) does not re-solve the sims.
    var controlNoRelink = false
    /// The generation whose sims were handed to the solver.
    var squishScheduled: Int?
    /// ★ R7-E3: the current lattice's per-voxel arrays with no sim (FlexibleFERequest.base) — kept after the solver drops the request,
    /// so an edges group's interim sim along its arrow can be solved on the CURRENT lattice whenever its presses change (the lattice is
    /// not rebuilt for a press while sending presses is parked). ~8 B per scene voxel.
    var feBase: FlexibleFERequest?
    /// ★ R7-E3: per press sim id ("group-N"), the key of the presses it was scheduled for, and the ids on the solver now.
    var pressSimKeys: [String: Int] = [:]
    /// ★ C1 (his words of 2026-10-20: "finalize the send to core now"): the presses whose CORE design the current lattice carries —
    /// each its press stack and core's depth per column there (as built in the combined field, else core's design): what its edges
    /// group's sim is calibrated to (Play, Bend, Heat), and the chip "Lattice not tuned for this press yet" goes. Set with the lattice.
    var latticeTunedPresses: [UUID: FlexibleFEField.Target] = [:]
    /// ★ X20b, RED CONTROL only: C1's targets — each press AS BUILT in the combined field (his Edge 9 near 0).
    nonisolated(unsafe) static var controlAsBuiltTargets = false
    var pressSimInFlight: Set<String> = []
    /// One solve at a time, off the main thread (FlexibleSquishSolver).
    let squishSolver = FlexibleSquishSolver()
    /// Test only: keep the last FE request (the solver releases it after its last sim).
    var keepFERequest = false
    private(set) var lastFERequest: FlexibleFERequest?
    func keepLastFERequest(_ r: FlexibleFERequest?) { lastFERequest = r }
    /// Test control only: store a sim's result whatever its generation (the red control).
    var controlIgnoreSquishGeneration = false
    /// ★ ROUND 4 (D2): the density field the last lattice was built from (groups combined
    /// firmer-wins, pinches as two segments). ★ D2 REVIEW: kept ONLY when a test asks
    /// (`keepCombinedField`) — at 128³ it is ~24 MB (Float ρ + Int owner) nothing else reads.
    private(set) var lastCombinedField: FlexDensityField?
    /// Test control only: keep the combined field after a build.
    var keepCombinedField = false
    /// ★ ROUND 3 BATCH B (item 9): core's words per face, kept PER KEY — a face core could
    /// not stack (no blind retry: the next scene open clears it) or could not design (one
    /// face's throw no longer leaves every later face "still being designed").
    @Published public private(set) var stackErrors: [FlexFaceKey: String] = [:]
    @Published public private(set) var designErrors: [FlexFaceKey: String] = [:]
    /// ★ ROUND 4 (D2): what each face was designed FROM (its weight, map and stamp) — a refusal or
    /// a throw core gave for the face as it WAS is not said about the face as it IS while the
    /// run for the new one is in flight (typing a weight into the fix pop-up popped "weight must
    /// be > 0" until the new design landed).
    private(set) var designedInputs: [FlexFaceKey: String] = [:]
    nonisolated static func designInputKey(_ f: FlexibleFaceSettings) -> String {
        "\(f.weightKg)|\(f.map.hashValue)|\(f.activeStamp?.hashValue ?? 0)"
    }
    /// ★ U21 batch R (the reviewer's ruling E(5) of 2026-10-21: "a newer drawn map ALWAYS supersedes an in-flight design; the stale
    /// answer is discarded — an answer counts only for the job on screen"): core's designs that answer each pressed face AS IT IS
    /// (its weight, map and stamp — `designedInputs`); a design for the face as it WAS is never shown over a newer drawing (X20b's
    /// check: Face 5 Stamp → Curves kept the stamp's flat dent while the new design stayed in flight). Presses keep theirs.
    /// RED CONTROL `controlStaleDesignShown`: every design, current or not (before).
    var currentDesigns: [FlexFaceKey: FlexFaceDesignInfo] {
        guard !Self.controlStaleDesignShown else { return designs }
        var now: [FlexFaceKey: String] = [:]
        for f in settings.loadedFaces { now[FlexFaceKey(region: f.faceRegionID, rotation: f.rotationDeg)] = Self.designInputKey(f) }
        return designs.filter { k, _ in now[k].map { designedInputs[k] == $0 } ?? true }
    }
    /// ★ RED CONTROL only (U21 batch R): a design shown whatever it was designed for.
    static var controlStaleDesignShown = false
    /// ★ TESTS only (U21 batch R): the design run's answer waits before it lands (X20b's "in flight for more than 4 minutes").
    nonisolated(unsafe) static var holdDesignLandingForTests = false
    /// Bumped by every action of HIS that can create a problem (press, rest, a weight, the
    /// trash, a filament): the fix pop-up opens only on a NEW blocking issue an action caused.
    @Published public internal(set) var actionSerial = 0
    /// A one-line note for an automatic fix ("Nozzle temperature set to Auto — …"). ★ BATCH B
    /// REVIEW: it clears ITSELF after `toastSeconds` — an auto-fix can land while the main page
    /// shows (no Settings page up to clear it), and the page's own clear only heard a change,
    /// so a toast set before it opened stayed under the line for the whole visit.
    @Published public var toast: String? {
        didSet {
            scheduleToastClear(); if toast == nil, toastFix != nil { toastFix = nil }
            // ★ R7-E2: the ruling's sentence waits for the toast before it (never over another line)
            if toast == nil, sideSentencePending { Task { @MainActor [weak self] in self?.sayAngledEstimateOnce() } }
        }
    }
    /// ★ ROUND 7 (M2): the toast's ONE fix (a solid tap's [Go to Lattice]); cleared with the toast.
    @Published public var toastFix: FlexibleToastFix?
    /// ★ U21 BATCH E (his Img11/12/14): the notice a tap on a face (or part of one) with no lattice of its own shows, in the
    /// fix pop-up's place under the top line — the SAME sentence and fixes as a pressed face's ("No lattice under Face 5 · set
    /// a face-prism" [Go to Lattice] [Face 5 rests]). It stays until dismissed or the next tap (never a 3.5 s toast).
    @Published public var noLatticeTap: FlexibleIssue?
    /// ★ U21 BATCH E: bumped by [Go to Lattice]; the page answers it with its leave for the Lattice page.
    @Published public internal(set) var leaveForLatticeAsks = 0
    /// ★ ROUND 7 (M2): the Flexible-only sectors' numbers for this session (FlexibleSectorNumbers), seeded from the store.
    let sectorNumbers = FlexibleSectorNumbers()
    var sectorNumbersSeeded = false
    /// ★ M2: the resolved Flexible sectors and the regions over them, memoised by what they are made from.
    var sectorMemo: (key: FlexibleSectorMemoKey, set: FlexibleSectorSet, regions: FlexibleRegions)?
    /// ★ M2: what the move of I2's strips off the Surface stage did (FlexibleSectorMigration), once it was made.
    @Published public internal(set) var migrationReport: FlexibleSectorMigration.Report?
    /// ★ M2 RED CONTROL: no carry at open — a face pressed whole stays beside its new sections (core refuses).
    var controlNoCarry = false
    /// ★ M2: Selections' include specs, memoised (FlexibleStageModel+Sectors.includeSpecs).
    var includeMemo: (key: FlexibleIncludeMemoKey, specs: [LatticeRegionSpec])?
    /// ★ M2: the read-through of a project I2 saved (FlexibleSectorMigration.move), memoised by what it is made from.
    var migrationMemo: (key: FlexibleSectorMigration.MemoKey, moved: FlexibleSectorMigration.Moved)?
    /// ★ BATCH B REVIEW: a design run (designs AND core's stack conflicts) is scheduled and has
    /// not landed — the pop-up waits for it before it pops a blocker that stands on opening
    /// (a calibrate-first map lands before the conflicts do).
    @Published public private(set) var designsInFlight = false
    var toastSeconds: Double = 3.5
    private var toastTask: Task<Void, Never>?
    private func scheduleToastClear() {
        toastTask?.cancel()
        guard let t = toast else { return }
        let ns = UInt64(max(0, toastSeconds) * 1e9)
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard let self, !Task.isCancelled, self.toast == t else { return }
            self.toast = nil
        }
    }
    /// The issue the page opens its pop-up on when it appears (the main page's pill).
    @Published public var pendingFix: FlexibleIssue?

    private var pendingStacks: Set<FlexFaceKey> = []
    /// Every bridge call in flight (scene, stacks, drawn maps, the lattice) — awaited by
    /// `waitForIdle` so nothing is still inside core when its owner goes away.
    private var inFlight: [UUID: Task<Void, Never>] = [:]

    func track(_ t: Task<Void, Never>) {
        let id = UUID()
        inFlight[id] = t
        Task { @MainActor [weak self] in
            _ = await t.value
            self?.inFlight[id] = nil
        }
    }

    /// Wait until no bridge call is in flight and no design / Auto run is pending (tests; a
    /// page that must not tear down a scene mid-call).
    func waitForIdle() async {
        for _ in 0..<2000 {
            let tasks = Array(inFlight.values) + [designTask, autoTask].compactMap { $0 }
            for t in tasks { _ = await t.value }
            if inFlight.isEmpty { await squishSolver.waitForIdle(); return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private(set) var designGeneration = 0
    /// ★ U21 FIX 1: `liveDesignTarget`'s answer per press for one design run (the legend and the edges sim ask on every refresh).
    var liveDesignTargetCache: [UUID: (gen: Int, target: FlexibleFEField.Target?)] = [:]
    private var designTask: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?
    /// ★ MANUAL (M2): how many design runs (faces, presses, stamp checks) and Auto picks were handed to core — the tests read
    /// them (none while Manual is on). Counting only; nothing reads them to decide.
    public internal(set) var coreDesignRequests = 0
    public internal(set) var coreAutoRequests = 0

    public init(project: ProjectModel, materialsPath: String?, stampsPath: String?,
                persist: @escaping () -> Void) {
        self.project = project
        self.materialsPath = materialsPath
        self.library = stampsPath.flatMap { try? FlexibleStampLibrary.load(path: $0) }
        self.persist = persist
        loadCatalogue()
    }

    // MARK: settings (in the project)

    /// ★ READ THROUGH THE ROUND-3 MIGRATION (FlexibleSettingsMigration): an old project
    /// shows and runs the new way (1 bead, both axes, no frame rotation, curves read "closer
    /// to the face = squishier") and its file changes only with the next edit.
    /// ★ ROUND 7 (M2): and through the move of I2's strips off the Surface stage (FlexibleSectorMigration): a project I2
    /// saved reads in the Flexible form at once; its file changes with the move (at open, or with his next edit).
    public var settings: FlexibleStageSettings {
        get {
            let raw = rawSettings
            return sectorMigration(raw)?.settings ?? raw
        }
        set { project.lattice.flexible = newValue }
    }

    public func edit(_ change: (inout FlexibleStageSettings) -> Void, recompute: Bool = true) {
        // ★ U21 (UNDO-GHOST): the open tab's members are known before the first change (never nil: an edit that empties the
        // tab — his only face taken out — moves it to [+ New], and Undo can bring it back)
        if railKeep == nil, !Self.controlUndoKeepsMovedTab { railKeep = captureRail() }
        var s = settings
        change(&s)
        guard s != settings else { return }
        // ★ ROUND 7 (M2): the Flexible sectors' numbers registered in the store; a project still in I2's form is moved in
        // this same change (one undo step: undo returns I2's bytes, which read through again)
        if !FlexibleSectors.controlSurfaceRoute {
            if let moved = sectorMigration(rawSettings) {
                if migrationReport == nil { migrationReport = moved.report }
                FlexibleSectorMigration.assignRegions(project, moved.restored)
            }
            registerSectors(&s)
        }
        settings = s
        syncRail()   // ★ ROUND 5 (S8): the folder tab follows the selected face's group
        if recompute { recomputeAll() }
        scheduleSave()
    }

    /// Every edit reaches the disk shortly after it is made, not only on Exit: a kill
    /// between edits must not lose the drawing (the lattice stage's own 2026-09-02 rule).
    var saveTask: Task<Void, Never>?   // (★ U21: `sealAfterReopen` cancels it — its seal would split the held step)
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, !Task.isCancelled else { return }
            self.save()
        }
    }

    public func save() {
        project.sealUndoStep()
        persist()
    }

    public var material: FlexMaterialInfo? {
        guard let id = settings.materialID else { return nil }
        return catalogue.first { $0.id == id }
    }

    // MARK: catalogue (S1)

    private func loadCatalogue() {
        guard let path = materialsPath else {
            catalogueError = "The Flexible filament list is not in this build."
            return
        }
        do {
            // the filaments core can predict for first, then the calibrate-first ones
            catalogue = try FlexibleCore.materials(path: path).sorted {
                ($0.noPrediction == nil) != ($1.noPrediction == nil) ? $0.noPrediction == nil
                    : $0.displayName < $1.displayName
            }
            bands = try FlexibleCore.errorBands(path: path)
        } catch {
            catalogueError = "\(error)"
        }
    }

    public func temperatureNote(_ tempC: Double) -> String {
        guard let path = materialsPath, let id = settings.materialID else { return "" }
        return (try? FlexibleCore.temperatureNote(path: path, materialID: id, tempC: tempC)) ?? ""
    }

    public func pickMaterial(_ id: String) {
        actionSerial += 1
        edit { s in
            s.materialID = id
            // a temperature from another filament is not one this one was tested at (R10)
            if let t = s.nozzleTempC, !(catalogue.first { $0.id == id }?.testedTempsC.contains(t) ?? false) {
                s.nozzleTempC = nil
            }
        }
    }

    // MARK: the scene

    struct SceneJob { let json: String; let dir: String }

    /// ★ ROUND 6 ITEM 2: `sectors` — the job over regions not committed yet (the strips' [Done]); nil: the project's.
    func sceneJob(sectors: [[String: Any]]? = nil) throws -> SceneJob? {
        guard let file = project.importedFile else { return nil }
        let faceCount = max(file.faceCount, (project.viewerMesh?.faceIDs.max().map { Int($0) + 1 }) ?? 0)
        var s = settings
        // the scene's one face entry must be a region of THOSE regions (a re-cut drops the old rest's id)
        // ★ ROUND 7 (M2): always — a Flexible piece that is gone (a face-prism moved, a section is whole again) is carried
        // only once the scene is open (planCarry); until then its entry must not ask core for an undeclared region
        let wire = sectors ?? regions.wire
        let declared = Set(wire.compactMap { $0["id"] as? Int })
        s.faces = s.faces.filter { !FlexibleRegions.isSector($0.faceRegionID) || declared.contains($0.faceRegionID) }
        var inputs = FlexibleJob.Inputs(
            modelPath: file.path, resolution: project.quality.resolution,
            beadWidthMM: project.printParams.strutLineWidthMM, faceCount: faceCount,
            settings: s, regions: project.latticeJobRegions().regions.map(\.wireDictionary))
        inputs.sectorRegions = wire
        (inputs.buildDir, inputs.plateDir) = buildDirections
        let json = try FlexibleJob.sceneJobJSON(inputs, fallbackMaterial: catalogue.first?.id ?? "flexible")
        return SceneJob(json: json, dir: (file.path as NSString).deletingLastPathComponent)
    }

    /// The scene's key: everything that changes the part, grid, mask or regions —
    /// NOT the faces, curves or filament (those re-run designs, never the scene).
    /// ★ BATCH B REVIEW: the bead width too — the scene job sends it (min_extrudable_width_mm)
    /// and the shared model now keeps its scene for the whole session.
    /// ★ ROUND 6 ITEM 2: `regionsKey` — the key over sectors not committed yet (the strips' [Done]); nil: the project's.
    func sceneKey(regionsKey: String? = nil) -> String {
        guard let file = project.importedFile else { return "" }
        let emitted = project.latticeJobRegions().regions
        let regions = emitted.map(\.wireDictionary)
        let r = (try? JSONSerialization.data(withJSONObject: regions, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        let (b, p) = buildDirections
        let key = "\(file.path)|\(project.quality.resolution)|\(r)|\(regionsKey ?? self.regions.key)|\(b)|\(p.map { "\($0)" } ?? "-")"
            + "|\(project.printParams.strutLineWidthMM)"
        // ★ ROUND 7, M1 (1a): whether these regions hold a face-prism, from the same list (never asked twice)
        lastKeyFacePrisms = (key, LatticeJobIncludeGate.hasIncludeWall(emitted))
        return key
    }

    /// The scene key the project describes NOW (the main page compares it with the opened one).
    var currentSceneKey: String { sceneKey() }

    /// ★ ROUND 3 (item 1.2): the main run's build directions — `loads.build_dir` = −gravity
    /// (+Z when gravity is unset) and the plate normal only when he declared one.
    var buildDirections: (SIMD3<Double>, SIMD3<Double>?) {
        let lc = project.loadCase()
        return (lc.buildDirection, lc.plateDirection == SIMD3<Double>(0, 0, 0) ? nil : lc.plateDirection)
    }

    // MARK: regions (split sectors, FlexibleRegions.swift)

    /// The declared regions: every face, plus the Surface stage's split sectors, plus ★ ROUND 7 (M2) the Flexible-only
    /// sectors (lattice sections, edge strips, their rests — FlexibleStageModel+Sectors, memoised).
    public var regions: FlexibleRegions { sectorState().regions }
    public func name(_ region: Int) -> String { regions.name(region, mesh: project.viewerMesh) }
    /// Core's sentence with sector ids replaced by the app's names.
    public func text(_ s: String) -> String { regions.renamed(s, mesh: project.viewerMesh) }

    /// The region "no pressed face" offers to press (FlexibleReadiness.suggestedFace), cached
    /// per mesh, build direction and split — a split face offers the sector at its centroid.
    private var suggestedCache: (key: String, region: Int?)?
    func suggestedPressRegion() -> Int? {
        guard let mesh = project.viewerMesh else { return nil }
        let up = buildDirections.0
        let key = "\(mesh.triangleCount)|\(mesh.faceIDs.count)|\(up)|\(regions.key)"
        if let c = suggestedCache, c.key == key { return c.region }
        // ★ M2: the pressable piece under the centroid, else the face's largest lattice piece, else none (solid)
        let regs = regions
        let region = FlexibleReadiness.suggestedFace(mesh: mesh, up: up).flatMap { s -> Int? in
            if let r = regs.pressable(at: s.centroid, face: s.face, mesh: mesh) { return r }
            let tris = FlexibleEdgeStrips.triangles(face: s.face, mesh: mesh)
            return (regs.flexible?.pieces ?? []).filter { $0.kind != .strip && FaceRegionGeometry.members(of: $0.region, in: mesh).contains(FaceID(s.face)) }
                .max { FlexibleEdgeStrips.area(tris, $0.region.cuts) < FlexibleEdgeStrips.area(tris, $1.region.cuts) }?.wireID
        }
        suggestedCache = (key, region)
        return region
    }

    /// The key the ready scene was opened with (the lattice is keyed by it too).
    private(set) var openedKey: String?
    /// ★ ROUND 7, M1 (1a — FlexibleStageModel+FacePrisms): the opened scene's regions hold a face-prism (an include wall),
    /// read from the same emitted list as its key; and the last key's own answer (`sceneKey` keeps it — never computed twice).
    var openedFacePrisms = false
    var lastKeyFacePrisms: (key: String, has: Bool)?
    /// Test control only (M1): the stage as it was before ruling 4 — no include region lattices the WHOLE part (core's rule).
    var controlWholePartWithoutPrism = false
    /// Test control only (ROUND 7, RULING 6 — FlexibleCoreDoor): the stage as it was before ruling 6 — with no face-prism core's
    /// scene is still opened on the whole part and asked for stacks and designs (nothing they say is shown: M1 verify).
    /// The RED CONTROL of FlexibleRuling6NoCoreTests, and the fixtures that pin CORE's own bytes on parts that set no
    /// face-prism (`controlAskCoreWithoutPrismFor`: the synthetic parts, the goldens' C1 pad).
    var controlAskCoreWithoutPrism = false
    /// ★ RULING 6: no face-prism — the stage is ready on the plain part and holds NO core scene (nothing is asked of core).
    private(set) var heldWithoutFacePrism = false
    /// ★ RULING 6: the worker's `hold()` in flight — the next open waits for it, so a late hold never drops a newer scene.
    private var pendingHold: Task<Void, Never>?
    /// The key the last open was ATTEMPTED with (a failed open is retried only on a new one).
    private(set) var openAttemptKey: String?

    public func openScene() {
        guard sceneState != .opening else { return }
        let key = sceneKey()
        let prisms = lastKeyFacePrisms.map { $0.key == key && $0.has } ?? false   // ★ M1: read with the key above
        // ★ ROUND 7, RULING 6 (FlexibleCoreDoor): no face-prism, no request of any kind — the stage does not knock
        guard mayAskCore(facePrism: prisms) else {
            holdWithoutFacePrism(key: key)
            return
        }
        // ★ THE SHARED MODEL (batch B): Settings re-opens over the main page's model — the same
        // part, the same scene: keep its stacks (and the overlay the main page draws) and only
        // re-read the main page's groups
        if sceneState == .ready, openedKey == key, !heldWithoutFacePrism {
            adoptMainPageLoads(recompute: false)
            recomputeAll()
            return
        }
        openAttemptKey = key
        guard let job = try? sceneJob() else {
            sceneState = .failed("This project has no imported part to open.")
            return
        }
        sceneState = .opening
        heldWithoutFacePrism = false
        let worker = self.worker
        let hold = pendingHold   // ★ RULING 6: a hold asked before this open reaches the worker first
        track(Task.detached(priority: .userInitiated) {
            await hold?.value
            do {
                let info = try await worker.open(jobJSON: job.json, jobDir: job.dir, key: key, facePrism: true)   // (mayAskCore, above)
                // ★ ROUND 7 (M2): what of his settings moves onto lattice sections, asked of core on the opened scene
                let carry = await self.planCarry()
                await MainActor.run {
                    self.sceneInfo = info
                    self.stacks = [:]
                    self.geometry = [:]
                    self.pendingStacks = []
                    self.stackErrors = [:]
                    self.designErrors = [:]
                    self.openedKey = key
                    self.openedFacePrisms = prisms   // ★ ROUND 7, M1 (1a): the scene's own answer, with its key
                    self.sceneState = .ready
                    // ★ ROUND 3 (item 1.2): the main page's loads arrive as pressed / resting faces
                    self.adoptMainPageLoads(recompute: false, carry: carry)
                    self.recomputeAll()
                }
            } catch {
                await MainActor.run { self.sceneState = .failed("\(error)") }
            }
        })
    }

    /// ★ RULING 6: wait for a hold in flight to reach the worker (the strips' [Done] installs a scene after it).
    func holdLanded() async { await pendingHold?.value }

    /// ★ ROUND 7, RULING 6 (FlexibleCoreDoor): no face-prism — nothing is asked of core. The stage is READY on the plain
    /// part (every rule keyed on "the opened scene sets no face-prism" holds: the one line, no [Fix], the views unavailable,
    /// the button disabled with its reason, each face's [Lattice under it]); core's old scene is let go, so nothing can be
    /// asked on it; no stack, design, drawn map, Auto or lattice is kept (none of them came from a scene with a face-prism).
    /// Again with the same key: only the main page's groups are re-read.
    private func holdWithoutFacePrism(key: String) {
        openAttemptKey = key
        if sceneState == .ready, heldWithoutFacePrism, openedKey == key {
            adoptMainPageLoads(recompute: false)
            recomputeAll()
            return
        }
        designTask?.cancel()
        autoTask?.cancel()
        if autoInFlight { autoInFlight = false }
        let worker = self.worker
        let hold = Task { await worker.hold() }
        pendingHold = hold
        track(hold)
        sceneInfo = nil
        stacks = [:]
        geometry = [:]
        liveS = [:]
        pendingStacks = []
        stackErrors = [:]
        designErrors = [:]
        recommendation = nil
        openedKey = key
        openedFacePrisms = false
        heldWithoutFacePrism = true
        sceneState = .ready
        if lattice != nil { discardLattice() }
        adoptMainPageLoads(recompute: false)
        recomputeAll()
    }

    // MARK: faces (S2)

    public var loadedKeys: [FlexFaceKey] {
        settings.loadedFaces.map { FlexFaceKey(region: $0.faceRegionID, rotation: $0.rotationDeg) }
    }

    /// Tap on the model: ★ ROUND 3 — it only SELECTS (img 8: tapping around pressed seven
    /// faces at 10 kg each, which made the conflicts and the '7 faces' refusal). Pressing is
    /// explicit: [Press it] / [It rests here] in the panel, or the main page's groups.
    public func tapFace(_ face: Int, point: SIMD3<Double>? = nil) {
        dropInPlaceAsks()   // ★ U21: a tap on the part drops a delete's ask
        // ★ ROUND 6 ITEM 2: in pick mode a tap never selects a face (the page hit-tests the edges and corners first)
        if edgePick != nil { return }
        // a split face resolves to the sector holding the point (the Surface stage's rule)
        // ★ ROUND 7 (M2, his img3 words: "when I tapped the top, it selected the model's top face, rather than one of the
        // lattice's top faces"): with a face-prism set, the tap picks the LATTICE section under it; on the solid part of a
        // face only partly latticed it selects nothing and says so, with one fix ([Go to Lattice]); the open tab stays
        // ★ U21 BATCH E (his Img12/11: "if we are going to say 'you need to lattice this first' then it should do so for every
        // face"; Img14): ONE rule — a tap on any face, or part of a face, with no lattice of its own (a root no face-prism
        // meets, the solid part of a partial root, every face with no face-prism set) presses and selects nothing and shows
        // the ONE notice (`noLatticeTap`); the open tab stays. RED CONTROL `FlexibleRegions.controlPressAnyRoot`: the two rules.
        noLatticeTap = nil
        let regs = regions
        let region: Int
        if !FlexibleRegions.controlPressAnyRoot, let pt = point, let mesh = project.viewerMesh {
            guard let r = regs.pressable(at: pt, face: face, mesh: mesh) else {
                noLatticeTap = noLatticeNotice(root: regs.ownRegion(at: pt, face: face, mesh: mesh))
                return
            }
            region = r
            if let line = regs.flexible?.notYet[r] { toast = line }
        } else if facePrismsSet, let pt = point {
            guard let r = regs.pressable(at: pt, face: face, mesh: project.viewerMesh) else {
                toast = FlexibleRowCopy.solidHere
                toastFix = .goToLattice
                return
            }
            region = r
            if let line = regs.flexible?.notYet[r] { toast = line }
        } else {
            region = regs.region(at: point, face: face, mesh: project.viewerMesh)
        }
        NSLog("DIAG flexible tap face %d → region %d (known %d)", face, region, settings.face(region) != nil ? 1 : 0)
        curvePoint = nil
        // ★ S VERIFICATION: on the [+ New] tab ("Tap the face that starts it") a tap on a face that
        // can start a group STARTS it (with its hand) — it had only selected the face and left the tab
        if rail == .newGroup, newGroupCandidates.contains(region) {
            startGroup(with: region)
            ensureStack(region)
            return
        }
        // ★ ROUND 7 (S, 4h): [+ New] with NOTHING pressed (after Reset all) — the tap starts Group 1 (the keypad asks
        // its weight where no main-page Load group gives one)
        if rail == .newGroup, settings.loadedFaces.isEmpty, presses.isEmpty, !Self.controlRailFollowsSelection {
            startFirstGroup(region, kg: nil)
            ensureStack(region)
            return
        }
        // ★ VERIFY OF R7-S: [+ New] with faces pressed — a face no group holds starts the NEXT group (the keypad asks its
        // weight where no main-page Load group gives one); it had opened Group 1
        if rail == .newGroup, settings.face(region) == nil, !settings.pressRegions.contains(region),
           !Self.controlRailFollowsSelection, !Self.controlNewTabOpensGroupOne {
            startNewGroup(region, kg: nil)
            ensureStack(region)
            return
        }
        selectedRegion = region
        followSelection()   // ★ ROUND 7 (S, 4f b): his tap is a pick — its tab opens
        if tab == .more { tab = .face }
        ensureStack(region)
    }

    /// ★ ROUND 4 (D1): a row of the Settings panel's face LIST was tapped — select that REGION
    /// (a split sector as itself: never resolved through the part's face, which would pick the
    /// whole face), so the rows below edit it and the part shows it selected.
    public func select(_ region: Int) {
        if edgePick != nil { return }   // ★ ROUND 6 ITEM 2: pick mode selects no face
        dropInPlaceAsks()   // ★ U21: a tap elsewhere drops a delete's ask
        noLatticeTap = nil   // ★ U21 batch E: the next tap drops the no-lattice notice
        curvePoint = nil
        selectedRegion = region
        followSelection()   // ★ ROUND 7 (S, 4f b): a row picked is his pick — its tab opens
        if tab == .more { tab = .face }
        ensureStack(region)
    }

    // MARK: the main page's loads (round 3, item 1.2 — FlexibleMainPageLoads)

    /// The main page's groups read as Flexible faces (cached per scene open and write-back).
    @Published public private(set) var mainPageLoads = FlexibleMainPageLoads()
    /// Faces whose OWN weight a group's replaced this session (region → the old kg): the
    /// panel says so in one line ("Was 7 kg · now Top's weight").
    @Published public internal(set) var relinkedWeights: [Int: Double] = [:]

    /// Read the main page's groups, then MATERIALISE them (`FlexibleMainPageLoads.adopt`): a
    /// face a Load group presses is pressed with its share and LINKED (weightFrom = the
    /// group) — one source of truth, also for a face pressed before round 3; an Anchor
    /// group's faces rest; [Rests] chosen on this page survives; a face whose group no longer
    /// holds it keeps its weight as his own. Sealed as one undo step. Called when the scene
    /// opens and after every write-back.
    public func adoptMainPageLoads(recompute: Bool = true) { adoptMainPageLoads(recompute: recompute, carry: nil) }

    /// ★ ROUND 7 (M2): with the open's CARRY (FlexibleStageModel+Sectors.planCarry) applied first, in the same edit and the
    /// same undo step — a face pressed whole is never left beside its new lattice sections.
    func adoptMainPageLoads(recompute: Bool, carry: FlexibleSectionCarry?) {
        guard let loads = deriveMainPageLoads() else { return }
        mainPageLoads = loads
        let before = settings
        var relinked: [Int: Double] = [:]
        var carried = false
        edit({ s in
            if let c = carry, s == c.from {
                s.faces = c.faces
                s.removedRegions = c.removed
                carried = true
            }
            relinked = Self.adopt(loads, into: &s)
        }, recompute: recompute)
        if carried, let t = carry?.toast { toast = t }
        relinkedWeights.merge(relinked) { old, _ in old }
        if settings != before { project.sealUndoStep() }
        // ★ ROUND 7 (S, 4f e): the OPEN group's first face — never Group 1's (`loadedFaces.first`)
        if selectedRegion == nil { selectedRegion = Self.appearSelection(self) }
    }

    func deriveMainPageLoads() -> FlexibleMainPageLoads? {
        guard let mesh = project.viewerMesh else { return nil }
        return FlexibleMainPageLoads.derive(
            groups: project.selection.groups, force: project.force, faceRegions: restoredFaceRegions,
            mesh: mesh, regions: regions, load: { [stacks] r in stacks[FlexFaceKey(region: r, rotation: 0)]?.load })
    }

    /// ★ D2 REVIEW: the main page's loads re-read into the cache ONLY — no edit, no undo step
    /// (the Settings page's undo / redo restored the project; the cache must follow it).
    public func refreshMainPageLoads() {
        if let loads = deriveMainPageLoads(), loads != mainPageLoads { mainPageLoads = loads }
    }

    /// ★ D2 REVIEW: the adopt, then the squeeze groups kept whole — a face the main page rests
    /// holds no group, a face it presses again joins a group that EXISTS (a stale id made a
    /// "Group 2" nobody made), and a main-page hand sits in one group.
    /// ★ RED CONTROL (U21 batch A): today's read-in on a new setup too.
    nonisolated(unsafe) static var controlNewSetupReadsIn = false

    nonisolated static func adopt(_ loads: FlexibleMainPageLoads, into s: inout FlexibleStageSettings) -> [Int: Double] {
        // ★ ROUND 5 (S6): a face he DELETED stays deleted — the re-sync skips it (the main page's
        // group still holds it; that is his to change there)
        // ★ ANGLED PRESSES (AP1): a press member is never re-pressed or re-rested as a face (a face that
        // is ALSO in a press — a clash, spec §8 — keeps its own link until he resolves it: D-AP1-2, pinned
        // by FlexiblePressReviewTests.testAClashFaceKeepsItsLinkThroughTheReSync)
        let removed = Set(s.removedRegions ?? []).union(s.pressRegions.subtracting(s.faces.map(\.faceRegionID)))
        let full = loads
        // ★ U21 (batch A, his Img7): a new setup reads nothing in — only faces he set himself re-sync (FlexibleSettings)
        let ownOnly = s.readsMainPageGroups == false && !controlNewSetupReadsIn
        let loads = removed.isEmpty && !ownOnly ? loads
            : FlexibleMainPageLoads(entries: loads.entries.filter { !removed.contains($0.key) && (!ownOnly || s.face($0.key) != nil) })
        let relinked = loads.adopt(into: &s)
        FlexiblePress.adoptWeights(full, into: &s)   // ★ AP1: linked presses re-sync from their group
        FlexibleSqueezeGroups.uniteHands(&s, loads: loads)
        return relinked
    }

    /// [Press it]: the main page's weight when the face is in a Load group; else `kg` (the
    /// number pad's answer); else — ★ ROUND 4 (D2) — group 1's ONE squeeze force (the face joins
    /// group 1, no pad). false ⇒ a weight must be asked first ("How much weight presses here?").
    @discardableResult
    public func press(_ region: Int, kg: Double? = nil) -> Bool {
        let inherited = mainPageLoads.entry(region).flatMap { $0.role == .pressed ? $0 : nil }
        let joinKg = inherited == nil && kg == nil ? firstGroupForce : nil
        guard inherited != nil || (kg ?? joinKg ?? 0) > 0 else { return false }
        actionSerial += 1
        let root = rootOf, loads = mainPageLoads
        edit { s in
            // ★ ROUND 5 (S6): pressing a deleted face brings it back — as a NEW face
            if s.isRemoved(region) { s.removedRegions?.removeAll { $0 == region }; if s.removedRegions?.isEmpty == true { s.removedRegions = nil } }
            var f = s.face(region) ?? FlexibleFaceSettings(faceRegionID: region)
            f.role = "loaded"
            f.squeezeGroup = nil   // a newly pressed face joins group 1
            if let e = inherited, kg == nil { f.weightKg = e.weightKg; f.weightFrom = e.groupID }
            else if let w = kg ?? joinKg { f.weightKg = w; f.weightFrom = nil }
            s.setFace(f)
            FlexibleSqueezeGroups.normalise(&s)
            // ★ ROUND 7 REVIEW (R, his answer 7 clarified): a lattice part joining its face's other parts in the group —
            // the face's weight is shared equally between them (one hand)
            if f.weightFrom == nil, inherited == nil || kg != nil, let w = kg ?? joinKg {
                let parts = FlexibleSqueezeGroups.hand(of: region, settings: s, loads: loads, root: root)
                if parts.count > 1 { FlexibleSectionShares.spread(w, over: parts, in: &s) }
            }
        }
        relinkedWeights[region] = nil
        selectIfAdmitted(region)   // ★ ROUND 7 (S, 4f): a face that left the open tab is not selected (the tab never shifts)
        ensureStack(region)
        return true
    }

    /// [It rests here] / [Rests]: HIS choice on this page, so it is unlinked (weightFrom nil)
    /// and no re-sync presses it again — not a write-back, not a re-open (`adopt(into:)`).
    public func rest(_ region: Int) {
        actionSerial += 1
        let left = partsLeft(without: region)
        edit { s in
            if s.isRemoved(region) { s.removedRegions?.removeAll { $0 == region }; if s.removedRegions?.isEmpty == true { s.removedRegions = nil } }
            var f = s.face(region) ?? FlexibleFaceSettings(faceRegionID: region, role: "resting")
            f.role = "resting"
            f.weightFrom = nil
            s.setFace(f)
            FlexibleSqueezeGroups.normalise(&s)   // ★ D2: a resting face is in no squeeze group
            if let l = left { FlexibleSectionShares.spread(l.kg, over: l.parts, in: &s) }   // ★ R: the face's force on its other parts
        }
        relinkedWeights[region] = nil
        selectIfAdmitted(region)   // ★ ROUND 7 (S, 4f): the tab stays; the face is selected only where it is shown
    }

    /// A weight typed on the Flexible page. ★ ONE SOURCE OF TRUTH (maintainer): for a face
    /// whose weight comes from a main-page group, it WRITES BACK to the group — the group
    /// takes the weight that gives this face `kg` — and every face of the group re-syncs, so
    /// the area split stays consistent. A face in no group keeps it as its own.
    /// ★ ROUND 4 (D2, his answer 1: ONE force per squeeze group): a pressed face's weight IS its
    /// squeeze group's force — the hand that gives this face `kg` (its main-page group's weight,
    /// or `kg`) becomes the force of every hand in the group (`setGroupForce`).
    public func setWeight(_ region: Int, kg: Double) {
        guard kg > 0 else { return }
        if let g = squeezeGroup(of: region) {
            let f = settings.face(region)
            let hand = f?.weightFrom != nil ? mainPageLoads.groupKg(forRegion: region, kg: kg) : nil
            setGroupForce(g.id, kg: hand ?? kg)
            return
        }
        actionSerial += 1
        if let f = settings.face(region), let g = f.weightFrom,
           let total = mainPageLoads.groupKg(forRegion: region, kg: kg) {
            project.force.setWeight(g, kg: total)
            relinkedWeights[region] = nil
            adoptMainPageLoads()
            return
        }
        relinkedWeights[region] = nil
        edit { s in guard var f = s.face(region) else { return }; f.weightKg = kg; f.weightFrom = nil; s.setFace(f) }
    }

    /// The trash. ★ ROUND 5 (S6, his img 3: "For some reason, top A/B are not deletable. All faces
    /// should be deletable."): EVERY face — a split sector, a face a main-page Load or Anchor group
    /// holds — leaves the Flexible setup. The main page's group is NOT touched (it still presses the
    /// face in the main run — his to change there); a face a group holds is remembered as deleted
    /// (`removedRegions`) so the re-sync never brings it back.
    /// ★ ROUND 5 (S7: "When a face has been deleted, it comes back with the previous values. It
    /// should come back with reset values."): EVERYTHING the face held goes with it — its settings
    /// (curves, stamp, shape, squeeze group, deepest squish, weight and its link), its check
    /// stamps, and every per-face copy of core's answers the page keeps (the drawn map, the design,
    /// its words, the pinch halves, the relinked weight, a curve point's ×). Added again, it is a
    /// NEW face: defaults, and the main page's weight if a group presses it.
    @discardableResult
    public func removeFace(_ region: Int) -> Bool {
        actionSerial += 1
        let held = !mainPageLoads.canRemove(region)
        let left = partsLeft(without: region)
        // ★ U21 (DEL-CONFIRM): the take-out is its OWN undo step — the edits before it sealed, and it saved (sealed) after
        if !Self.controlRemoveFaceNoSeal { project.sealUndoStep() }
        edit { s in
            s.removeFace(region)
            if held, !s.isRemoved(region) { s.removedRegions = (s.removedRegions ?? []) + [region] }
            FlexibleSqueezeGroups.normalise(&s)
            if let l = left { FlexibleSectionShares.spread(l.kg, over: l.parts, in: &s) }   // ★ R: the face's force on its other parts
        }
        purgeFaceCaches(region)
        // ★ ROUND 7 (S, 4f d): the OPEN group's first face, else none — never Group 1's
        if selectedRegion == region { selectedRegion = Self.appearSelection(self) }
        if !Self.controlRemoveFaceNoSeal { save() }
        return true
    }

    /// ★ S7: every per-face copy the model keeps for `region` (any rotation) — never shown again for
    /// a face added back later.
    func purgeFaceCaches(_ region: Int) {
        func drop<V>(_ d: inout [FlexFaceKey: V]) {
            let ks = d.keys.filter { $0.region == region }
            for k in ks { d[k] = nil }
        }
        drop(&liveS); drop(&designs); drop(&designErrors); drop(&segments); drop(&segmentErrors)
        drop(&designedInputs)
        relinkedWeights[region] = nil
        if curvePoint?.region == region { curvePoint = nil }
        checks = checks.filter { id, _ in settings.checkStamps.contains { $0.stamp.id == id } }
    }

    public func key(_ region: Int) -> FlexFaceKey? {
        // ★ R7-E2 (FlexibleSquishTarget): a press's synthetic key names its press stack (rotation 0)
        if region <= Self.syntheticPressMax { return pressID(forKey: region) != nil ? FlexFaceKey(region: region, rotation: 0) : nil }
        return settings.face(region).map { FlexFaceKey(region: region, rotation: $0.rotationDeg) }
    }

    public func stack(_ region: Int) -> FlexStackInfo? { key(region).flatMap { stacks[$0] } }
    public func design(_ region: Int) -> FlexFaceDesignInfo? { key(region).flatMap { designs[$0] } }

    private func ensureStack(_ region: Int) {
        guard region > Self.syntheticPressMax,   // ★ R7-E2: a press's stack comes with its registration (FlexibleStageModel+FlatPrism)
              sceneState == .ready, !heldWithoutFacePrism,   // ★ RULING 6: no face-prism, no stack asked
              let k = key(region), stacks[k] == nil, !pendingStacks.contains(k),
              stackErrors[k] == nil else { return }   // ★ no blind retry of a face core refused to stack
        pendingStacks.insert(k)
        let partFlat = project.viewerMesh?.flat.positions ?? []
        let worker = self.worker
        track(Task.detached(priority: .userInitiated) {
            do {
                let st = try await worker.withScene { try $0.stack(face: k.region, rotation: k.rotation) }
                let g = try await worker.withScene { try FlexFaceGeometry.compute(scene: $0, key: k, stack: st, partFlat: partFlat) }
                await MainActor.run {
                    // ★ ROUND 7, M1 (1a): with no face-prism the stage keeps NO lattice on the stack (core's own rule for no
                    // include region is the whole part — FlexibleStageModel+FacePrisms)
                    self.stacks[k] = self.facePrismsSet ? st : st.withoutLattice(); self.geometry[k] = g
                    self.seedStampIfNeeded(k.region)   // ★ Stamp chosen before the stack landed (D1 verification)
                    self.recomputeAll()
                }
            } catch {
                await MainActor.run {
                    self.lastError = "\(error)"
                    self.stackErrors[k] = "\(error)"
                    self.pendingStacks.remove(k)
                }
            }
        })
    }

    // MARK: the pipeline

    /// The temperature and family the designs are drawn for: the user's pick, else
    /// Auto's, else nothing (no guessed temperature, R10).
    public var designTempC: Double? {
        settings.nozzleTempC ?? recommendation.flatMap { $0.chosen ? $0.tempC : nil }
            ?? material?.testedTempsC.first
    }
    public var designTopology: String {
        settings.topology != "auto" ? settings.topology
            : (recommendation?.chosen == true ? recommendation!.topology : "gyroid")
    }
    public var build: FlexBuildParams {
        FlexBuildParams(topology: designTopology, beadsPerWall: settings.beadsPerWall,
                        beadWidthMM: project.printParams.strutLineWidthMM)
    }

    /// A curve point moved: the squish map now, the design when the drag rests.
    public func curveChanged(region: Int) {
        guard let k = key(region), let f = settings.face(region), stacks[k] != nil else { return }
        let map = f.map
        let worker = self.worker
        track(Task.detached(priority: .userInitiated) {
            if let s = try? await worker.withScene({ try $0.squishFraction(face: k.region, rotation: k.rotation, map: map) }) {
                await MainActor.run { self.liveS[k] = s }
            }
        })
        scheduleDesigns(delayNS: 120_000_000)
    }

    public func recomputeAll() {
        guard sceneState == .ready else { return }
        for k in loadedKeys where stacks[k] == nil { ensureStack(k.region) }
        refreshLiveS(loadedKeys)
        rasteriseStamps()
        scheduleDesigns(delayNS: 0)
        scheduleAuto()
        registerPresses()        // ★ R7-E1: core's press stack for every strip press on the open scene (the seam)
        announceLegacyStrips()   // ★ R7-E1: M2's strips read through — said once
    }

    /// ★ ROUND 3, ITEM 1: every pressed face's DRAWN map, from core's squish_fraction, as
    /// soon as its stack exists and after every recompute (undo, a new weight…). It needs no
    /// filament data, so a calibrate-first filament's map bends too (FlexibleShownValues).
    private func refreshLiveS(_ keys: [FlexFaceKey]) {
        let jobs = keys.compactMap { k -> (FlexFaceKey, FlexMap)? in
            guard stacks[k] != nil, let f = settings.face(k.region) else { return nil }
            return (k, f.map)
        }
        guard !jobs.isEmpty else { return }
        let worker = self.worker
        track(Task.detached(priority: .userInitiated) {
            var out: [FlexFaceKey: [Double]] = [:]
            for (k, map) in jobs {
                if let s = try? await worker.withScene({ try $0.squishFraction(face: k.region, rotation: k.rotation, map: map) }) {
                    out[k] = s
                }
            }
            let o = out
            await MainActor.run { for (k, v) in o { self.liveS[k] = v } }
        })
    }

    /// ★ ONE FACE'S THROW NO LONGER STOPS THE NEXT (round 3 batch B, item 9). The designs ran
    /// in ONE do/catch: a face core threw for (weight 0 — "weight must be > 0") left every
    /// LATER face undesigned, "still being designed" for ever. Each face now has its own
    /// catch, and its words are kept against its key.
    nonisolated static func designEach<K: Hashable, F, D>(_ faces: [F], key: (F) -> K,
                                                           cancelled: () -> Bool = { Task.isCancelled },
                                                           _ body: (F) async throws -> D) async
        -> (designs: [K: D], errors: [K: String], cancelled: Bool) {
        var out: [K: D] = [:], errs: [K: String] = [:]
        for f in faces {
            if cancelled() { return (out, errs, true) }
            do { out[key(f)] = try await body(f) }
            catch { errs[key(f)] = "\(error)" }
        }
        return (out, errs, false)
    }

    func scheduleDesigns(delayNS: UInt64) {
        pipelineSettings = settings
        designGeneration += 1
        let gen = designGeneration
        designTask?.cancel()
        // ★ MANUAL (M2, his picks of 2026-10-22: "Auto's lattice-type pick and the 'can't meet your curve' checks disappear"): in
        // Manual nothing is designed — no face, press or stamp design, no conflict is asked of core. What core said before is
        // kept, unshown (every line that reads it is Auto's and hidden in Manual), so the job and the presses sent stay Auto's
        guard !manualSkipsCore else {
            if !checks.isEmpty { checks = [:] }
            if designsInFlight { designsInFlight = false }
            return
        }
        // ★ ROUND 7, RULING 6: no face-prism — no design, no conflict, no stamp check is asked of core
        guard !heldWithoutFacePrism, let path = materialsPath, let mat = settings.materialID else {
            designs = [:]
            designErrors = [:]
            segments = [:]
            segmentErrors = [:]
            groupMisses = []
            if designsInFlight { designsInFlight = false }
            return
        }
        if !designsInFlight { designsInFlight = true }
        coreDesignRequests += 1   // ★ MANUAL (M2): counted (the tests)
        let faces = settings.loadedFaces.filter { stacks[FlexFaceKey(region: $0.faceRegionID, rotation: $0.rotationDeg)] != nil }
        let temp = designTempC, build = self.build, grids = stampGrids
        let checkStamps = settings.checkStamps
        let worker = self.worker
        // ★ ROUND 4 (D2): what the pinches' two-segment designs read (FlexiblePinch)
        let snapshot = settings, stackSnap = stacks
        let inputKeys = Dictionary(faces.map { (FlexFaceKey(region: $0.faceRegionID, rotation: $0.rotationDeg), Self.designInputKey($0)) },
                                   uniquingKeysWith: { a, _ in a })
        let regions = self.regions
        let cuts = Dictionary(faces.map { ($0.faceRegionID, regions.cuts(of: $0.faceRegionID)) }, uniquingKeysWith: { a, _ in a })
        // ★ R7-E2 (FlexibleSquishTarget): every registered strip press, designed on CORE's press stack through its synthetic key
        // with the map FlexiblePressShape builds from core's frame (the job's map — one function)
        let pressTargets = pressDesignTargets, pressEst = pressEstimates
        designTask = Task.detached(priority: .userInitiated) {
            if delayNS > 0 { try? await Task.sleep(nanoseconds: delayNS) }
            if Task.isCancelled { return }
            var out: [FlexFaceKey: FlexFaceDesignInfo] = [:]
            var faceErrors: [FlexFaceKey: String] = [:]
            var s: [FlexFaceKey: [Double]] = [:]
            var checks: [UUID: FlexStampCheckInfo] = [:]
            var conflicts: [FlexConflictInfo] = []
            var segs: [FlexFaceKey: FlexiblePinch.Segments] = [:]
            var segErrs: [FlexFaceKey: String] = [:]
            var misses: [FlexibleGroupEstimate.Miss] = []
            var err: String?
            let keys = faces.map { FlexFaceKey(region: $0.faceRegionID, rotation: $0.rotationDeg) }
            do {
                conflicts = try await worker.withScene {
                    try $0.conflicts(faces: keys.map(\.region), rotations: keys.map(\.rotation))
                }
            } catch {
                err = "\(error)"
            }
            // ★ R7-E2: core's stack conflicts among the presses (a press stack named by its first region) — the faces' pinches keep
            // reading `conflicts`, unchanged
            var pressConf: [FlexConflictInfo] = []
            if pressTargets.count > 1 {
                pressConf = (try? await worker.withScene {
                    try $0.conflicts(faces: pressTargets.map { $0.key.region }, rotations: pressTargets.map { _ in 0 })
                }) ?? []
            }
            var pressOut: [FlexFaceKey: FlexFaceDesignInfo] = [:]
            var pressErrs: [FlexFaceKey: String] = [:]
            if let temp {
                let r = await Self.designEach(faces, key: { FlexFaceKey(region: $0.faceRegionID, rotation: $0.rotationDeg) }) { f in
                    let k = FlexFaceKey(region: f.faceRegionID, rotation: f.rotationDeg)
                    let stamp = f.activeStamp.flatMap { grids[$0.id] }
                    return try await worker.withScene {
                        try $0.design(materialsPath: path, materialID: mat, tempC: temp, face: k.region,
                                      rotation: k.rotation, map: f.map, weightN: f.weightN,
                                      stamp: stamp, build: build)
                    }
                }
                if r.cancelled { return }
                out = r.designs
                faceErrors = r.errors
                // ★ R7-E2: the presses (each its own catch; their words never stand for a face's)
                if !pressTargets.isEmpty {
                    let pr = await Self.designEach(pressTargets, key: { $0.key }) { t in
                        try await worker.withScene {
                            try $0.design(materialsPath: path, materialID: mat, tempC: temp, face: t.key.region, rotation: 0, map: t.map,
                                          weightN: t.weightN, stamp: nil, build: build)
                        }
                    }
                    if pr.cancelled { return }
                    pressOut = pr.designs
                    pressErrs = pr.errors
                }
                for (k, d) in out { s[k] = d.columns.map(\.s) }
                if err == nil, let first = faceErrors.values.first { err = first }
                for c in checkStamps {
                    guard let f = faces.first(where: { $0.faceRegionID == c.faceRegionID }),
                          let g = grids[c.stamp.id], out[FlexFaceKey(region: f.faceRegionID, rotation: f.rotationDeg)]?.refusal == nil
                    else { continue }
                    do {
                        checks[c.stamp.id] = try await worker.withScene {
                            try $0.checkStamp(materialsPath: path, materialID: mat, tempC: temp,
                                              face: f.faceRegionID, rotation: f.rotationDeg, stamp: g, build: build)
                        }
                    } catch {
                        if err == nil { err = "\(error)" }
                    }
                }
                // ★ ROUND 4 (D2): a PINCH (two faces of one group on one stack) — each face's
                // pinched columns designed over their half, through core's own table
                // ★ D2 REVIEW: each face its own catch (one throw no longer drops every pinch)
                do {
                    let law = try FlexiblePinch.Law.core(materialsPath: path, materialID: mat, tempC: temp, build: build)
                    (segs, segErrs) = Self.pinchSegments(settings: snapshot, conflicts: conflicts, designs: out,
                                                         stacks: stackSnap, cuts: cuts, law: law)
                    // ★ D2 REVIEW: separate groups — which will squish less than designed once the
                    // lattice carries them all (the firmer wins), said BEFORE Exit
                    misses = try Self.groupEstimate(settings: snapshot, designs: out.merging(pressOut) { a, _ in a }, segments: segs,
                                                    stacks: stackSnap, cuts: cuts, law: law, presses: pressEst)   // ★ R7-E2 FIX
                } catch {
                    if err == nil { err = "\(error)" }
                }
            }
            while Self.holdDesignLandingForTests { try? await Task.sleep(nanoseconds: 20_000_000) }   // (no hop unless a test holds it)
            if Task.isCancelled { return }
            let (o, fe, ss, ch, co, er, sg) = (out.merging(pressOut) { a, _ in a }, faceErrors.merging(pressErrs) { a, _ in a }, s, checks, conflicts, err, segs)
            let (se, mi, pc) = (segErrs, misses, pressConf)
            await MainActor.run {
                guard gen == self.designGeneration else { return }
                self.designsInFlight = false
                self.designs = o
                self.designErrors = fe
                if self.pressConflicts != pc { self.pressConflicts = pc }
                for (k, v) in ss { self.liveS[k] = v }
                self.checks = ch
                self.conflicts = co
                self.segments = sg
                self.segmentErrors = se
                if self.groupMisses != mi { self.groupMisses = mi }
                self.designedInputs = inputKeys
                self.lastError = er
                self.applyAutoFixes()
                self.sayAngledEstimateOnce()   // ★ R7-E2: the ruling's sentence, once per session, when a side press is first sent
            }
        }
    }

    /// ★ SILENT AUTO-FIXES (decisions): a refusal with an obvious fix is fixed, with a toast —
    /// temperature_not_tested → Auto; topology_no_data / honeycomb_side_stack → Gyroid.
    func applyAutoFixes() {
        let fixes = readiness.autoFixes
        guard !fixes.isEmpty else { return }
        edit { s in
            for f in fixes {
                switch f.what {
                case .temperatureAuto: s.nozzleTempC = nil
                case .topologyGyroid: s.topology = "gyroid"
                }
            }
        }
        toast = fixes.map(\.toast).joined(separator: " · ")
    }

    // MARK: Auto (S3)

    public func scheduleAuto() {
        autoTask?.cancel()
        autoGeneration += 1
        let gen = autoGeneration
        // ★ MANUAL (M2): no Auto pick is asked in Manual (his type is on [Model]); Auto's last pick is kept, unshown
        guard !manualSkipsCore else {
            if autoInFlight { autoInFlight = false }
            return
        }
        guard let path = materialsPath, let mat = material, !mat.testedTempsC.isEmpty else {
            recommendation = nil
            if autoInFlight { autoInFlight = false }
            return
        }
        let faceRequests = settings.loadedFaces.compactMap { f -> FlexFaceRequest? in
            let k = FlexFaceKey(region: f.faceRegionID, rotation: f.rotationDeg)
            guard stacks[k] != nil else { return nil }
            return FlexFaceRequest(face: f.faceRegionID, rotation: f.rotationDeg, map: f.map,
                                   weightN: f.weightN, stamp: f.activeStamp.flatMap { stampGrids[$0.id] })
        }
        // ★ R7-E2: the registered presses too — Auto picks for the whole lattice, a side press keeps it to gyroid (core's own rule)
        let presses = Self.controlStripPresses ? [] : pressDesignTargets.map {
            FlexFaceRequest(face: $0.key.region, rotation: 0, map: $0.map, weightN: $0.weightN, stamp: nil)
        }
        let faces = faceRequests + presses
        guard !faces.isEmpty else {
            recommendation = nil
            if autoInFlight { autoInFlight = false }
            return
        }
        if !autoInFlight { autoInFlight = true }
        coreAutoRequests += 1   // ★ MANUAL (M2): counted (the tests)
        // Auto weighs every tested temperature and both families; the user's overrides
        // are applied on top (R5), never fed back as if Auto chose them.
        let temps = mat.testedTempsC
        let feel = settings.feel, beads = settings.beadsPerWall
        let width = project.printParams.strutLineWidthMM
        let worker = self.worker
        autoTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            do {
                let r = try await worker.withScene {
                    try $0.recommend(materialsPath: path, materialID: mat.id, temps: temps,
                                     topologies: ["gyroid", "honeycomb"], feel: feel,
                                     beadsPerWall: beads, beadWidthMM: width, faces: faces)
                }
                if Task.isCancelled { return }
                await MainActor.run {
                    let before = self.designTopology, beforeT = self.designTempC
                    self.recommendation = r
                    self.recommendationError = nil
                    if before != self.designTopology || beforeT != self.designTempC {
                        self.scheduleDesigns(delayNS: 0)
                    }
                    if gen == self.autoGeneration, self.autoInFlight { self.autoInFlight = false }
                }
            } catch {
                await MainActor.run {
                    self.recommendationError = "\(error)"
                    if gen == self.autoGeneration, self.autoInFlight { self.autoInFlight = false }
                }
            }
        }
    }

    /// Is `topology` at `temp` a candidate core has data for, for these faces?
    public func candidate(topology: String, tempC: Double) -> FlexCandidate? {
        recommendation?.candidates.first { $0.topology == topology && $0.tempC == tempC }
    }

    // MARK: stamps (S4)

    /// Rasterise every placed stamp onto its face at half the column pitch.
    private func rasteriseStamps() {
        var grids: [UUID: FlexStamp] = [:]
        func lay(_ p: FlexibleStampPlacement, region: Int) {
            guard let st = stack(region) else { return }
            let onFace: (Double, Double) -> Bool = { u, v in
                let iu = Int((u / st.pitchMM).rounded(.down)), iv = Int((v / st.pitchMM).rounded(.down))
                guard iu >= 0, iv >= 0, iu < st.nu, iv < st.nv else { return false }
                return st.cell[iv * st.nu + iu] >= 0
            }
            if let g = FlexibleStamps.grid(p, library: library, uExtentMM: st.uExtentMM,
                                           vExtentMM: st.vExtentMM, pitchMM: st.pitchMM, onFace: onFace) {
                grids[p.id] = g
            }
        }
        // ★ ROUND 4 (D1): only a Stamp-shaped face's ONE stamp, at the face's weight (the
        // migration empties the check stamps; a stamp stored under Curves is not laid)
        for f in settings.faces { if let p = f.activeStamp { lay(p, region: f.faceRegionID) } }
        for c in settings.checkStamps { lay(c.stamp, region: c.faceRegionID) }
        stampGrids = grids
    }

    /// Core's own check that a grid conserves its force (≤ 0.5 %).
    public func stampError(_ id: UUID) -> String {
        guard let g = stampGrids[id] else { return "" }
        return FlexibleCore.stampError(g)
    }

    // MARK: the lattice (FlexibleLatticeGeneration.swift) — built on Save & Exit (batch B)

    /// ★ ROUND 3 BATCH B: FlexibleReadiness decides (the old gate's order was the bug); nil
    /// when nothing blocks.
    public var latticeRefusal: String? { readiness.refusal }
    /// The generated lattice no longer matches the settings (a face or the filament changed)
    /// — ★ BATCH B REVIEW: or the SCENE it was built on (a new grid, a new lattice region, a
    /// new bead on the main page; the shared model keeps its lattice across the session).
    public var latticeIsStale: Bool {
        lattice.map {
            Self.latticeStale(builtKey: $0.settingsKey, builtScene: $0.sceneKey, builtTopology: $0.topology, builtTempC: $0.tempC,
                              key: latticeSettingsKey, scene: openedKey, topology: designTopology, tempC: designTempC ?? 0)
        } ?? false
    }

    /// ★ R7-E2 (found by looking at the lattice's pictures — his pad's lattice designed at 190 °C while Auto went on to choose 220 °C:
    /// the designs moved, the lattice stayed): is a lattice built from (key, scene, family, temperature) stale now? Also when the
    /// family or the temperature its designs were made at is not the one the designs are made at now.
    nonisolated static func latticeStale(builtKey: Int, builtScene: String?, builtTopology: String, builtTempC: Double,
                                         key: Int, scene: String?, topology: String, tempC: Double) -> Bool {
        if builtKey != key || (builtScene != nil && builtScene != scene) { return true }
        if controlStaleIgnoresDesign { return false }   // (RED CONTROL: the rule before)
        return builtTopology != topology || builtTempC != tempC
    }
    /// ★ RED CONTROL only: the rule before (the family and temperature a lattice was designed at never make it stale).
    nonisolated(unsafe) static var controlStaleIgnoresDesign = false

    /// ★ R7-E2: what the lattice is keyed by — the design inputs (presses included now), and which presses are IN THE JOB (a press
    /// whose design lands after a build makes that build stale). With none in the job: exactly designInputs' hash, as before.
    var latticeSettingsKey: Int {
        let base = settings.designInputs.hashValue
        let sent = Self.controlStripPresses ? [] : sentPresses
        guard !sent.isEmpty else { return base }
        var h = Hasher()
        h.combine(base)
        for id in sent.sorted(by: { $0.uuidString < $1.uuidString }) { h.combine(id) }
        return h.finalize()
    }

    /// What a build is keyed by: the settings and the scene. ★ ROUND 5: the settings WITHOUT the
    /// display-only choices (a group's colour, the weight unit) — neither re-builds the lattice.
    private var latticeBuildKey: String { "\(latticeSettingsKey)|\(openedKey ?? "")" }
    /// The key the last build FAILED on.
    private var latticeFailedKey: String?
    /// ★ BATCH B REVIEW: a failed build is LATCHED against what it was built from — the main
    /// page tried again on every change it caused itself (the failure published, the page
    /// rebuilt, it failed …), for ever, behind "Building the lattice…". Core's words while the
    /// settings and the scene are the ones that failed; nil once either changes.
    public var latticeFailure: String? {
        guard let e = latticeError, latticeFailedKey == latticeBuildKey else { return nil }
        return e
    }

    /// His explicit Save & Exit asks for the build again (once per Exit — never a loop).
    public func retryFailedBuild() { latticeFailedKey = nil }

    /// The settings the design pipeline last ran for (every design run is scheduled here).
    private(set) var pipelineSettings: FlexibleStageSettings?
    /// ★ BATCH B REVIEW: the settings moved without the pipeline — an undo / redo on the MAIN
    /// page (its two-finger tap restores `lattice.flexible` behind the model's back).
    var settingsOutranPipeline: Bool { sceneState == .ready && pipelineSettings?.designInputs != settings.designInputs }

    /// Bumped per build — the token the preview uploads once per.
    private var latticeGeneration = 0

    /// The squish faces in the order the pass takes them: the LARGEST first, so its four
    /// slots (`FlexibleSquishField.maxFaces`) squish the four largest (plan item 9: more than
    /// four pressed faces no longer blocks; the walls use every face).
    nonisolated static func squishOrder<K>(_ faces: [(key: K, areaMM2: Double)]) -> [K] {
        faces.enumerated().sorted { a, b in
            a.element.areaMM2 != b.element.areaMM2 ? a.element.areaMM2 > b.element.areaMM2 : a.offset < b.offset
        }.map(\.element.key)
    }

    /// Build the lattice: core's density field from the designs, or — for a calibrate-first
    /// filament — the SHAPE-ONLY field (FlexibleGeometryOnlyLattice) from core's mask and the
    /// drawn map. Refused only by a blocking readiness issue.
    /// ★ ROUND 4 (D2): one field PER SQUEEZE GROUP — core's own for a group core can assemble, the
    /// app's (FlexibleGroupField.assemble: core's rule without its refusal) for a group with a
    /// PINCH, whose pinched faces bring their two-segment designs — and, with two or more groups,
    /// the FIRMER density per voxel; each face then squishes by what its column holds in that
    /// combined field (≈ as built), and a group that misses its design says so.
    public func generateLattice() {
        // ★ ROUND 7, M1 (1a — his img1: "ONLY the face-prism creates the lattice structure in any area"): no face-prism, no
        // lattice — nothing is built, a lattice built before is cleared (it was the whole part's), and it is no failure
        guard facePrismsSet else {
            if lattice != nil { discardLattice() }
            return
        }
        let ready = readiness
        // blocked, or still designing (a face without its design would be left out silently)
        guard ready.isReady, !ready.designing, !latticeBuilding, let part = project.viewerMesh else { return }
        let faces = settings.loadedFaces
        let shapeOnly = material?.noPrediction != nil
        let allKeys = faces.map { FlexFaceKey(region: $0.faceRegionID, rotation: $0.rotationDeg) }
        // ★ ONE ARRAY PER FACE for the walls AND the dent: core's buildable depths (a pinched
        // face: its halves') — or, shape only, the drawing itself (S × deepest) — kept on the
        // lattice so the map drawn beside it is the one it squishes by
        var squish: [FlexFaceKey: FlexibleSquishFace] = [:], built: [FlexFaceKey] = []
        var depths: [FlexFaceKey: [Double?]] = [:], noLattice: [FlexFaceKey: [Bool]] = [:]
        var drawn: [FlexibleGeometryOnlyLattice.Face] = []
        var designed: [FlexFaceKey: FlexiblePinch.Segments] = [:], pressure: [FlexFaceKey: [Double]] = [:]
        var extent = 0.0, shallowest = Double.infinity
        // ★ MANUAL (M2): nothing is designed in Manual — each face's DRAWN map stands in for its column preview (as a shape-only
        // filament's) until his lattice's sim lands; the views then show the sim
        let manualFaces = manualSkipsCore
        for (f, k) in zip(faces, allKeys) {
            guard let st = stacks[k] else { continue }
            let dk: [Double?]
            if shapeOnly || manualFaces {
                guard let sv = liveS[k] else { continue }
                dk = st.columns.indices.map { i in
                    i < sv.count && st.columns[i].latticeMM > 0 ? sv[i] * f.deepestMM : nil
                }
                noLattice[k] = st.columns.map { $0.latticeMM <= 0 }
                drawn.append(.init(stack: st, s: sv))
                let lat = st.columns.map(\.latticeMM).filter { $0 > 0 }
                if !lat.isEmpty { shallowest = min(shallowest, lat.reduce(0, +) / Double(lat.count)) }
            } else {
                guard let d = designs[k] else { continue }
                let sg = segments[k] ?? FlexiblePinch.core(d, stack: st)
                designed[k] = sg
                pressure[k] = d.columns.map(\.pressureMPa)
                dk = sg.buildableDepthMM
                noLattice[k] = st.columns.indices.map { $0 < d.columns.count && d.columns[$0].status == "no_lattice" }
            }
            squish[k] = FlexibleSquishFace(stack: st, depthsMM: dk)
            built.append(k)
            depths[k] = dk
            extent = max(extent, st.uExtentMM, st.vExtentMM)
        }
        // ★ R7-E2 (the ruling's item 6: "the preview lattice is graded by that press's own design along the arrow, and blended into
        // the neighbouring faces' lattices by core's conflict rule"): each press IN THE JOB brings core's design on its press stack,
        // built into its group's field over its synthetic key (core's assemble_density_field) — never a squish slot of the pass (the
        // sim along the arrow is E3's)
        var pressKeysOf: [Int: [FlexFaceKey]] = [:]
        var pressStacks: [FlexFaceKey: FlexStackInfo] = [:]
        var pressCuts: [Int: FlexibleFlatPrism.Cut] = [:]   // ★ R7-E2 FIX: each press grades only its flat prism
        var pressIDOf: [FlexFaceKey: UUID] = [:]   // ★ C1: which press each press key is (its tuned target)
        if !shapeOnly, !Self.controlStripPresses {
            let sentNow = sentPresses
            for p in presses where sentNow.contains(p.id) {
                guard let r = pressRegistrations[p.id] else { continue }
                let k = FlexFaceKey(region: r.key, rotation: 0)
                guard let d = designs[k], d.refusal == nil, d.columns.count == r.stack.columns.count else { continue }
                pressStacks[k] = r.stack
                pressIDOf[k] = p.id
                // core names a voxel's owner by its stack's face_region_id (a press stack: its first piece) — both keys
                if let c = FlexibleFlatPrism.cut(of: p) { pressCuts[r.key] = c; if let first = p.regions.first { pressCuts[first] = c } }
                designed[k] = FlexiblePinch.core(d, stack: r.stack)
                pressure[k] = d.columns.map(\.pressureMPa)
                pressKeysOf[FlexibleSqueezeGroups.id(p), default: []].append(k)
            }
        }
        // ★ D2 REVIEW: the pass's four slots never split a pinch (face 5 stood still while face 3
        // squished with five pressed faces)
        let pinchedWith = pinchedKeys(built)
        let slots = FlexibleSqueezeGroups.squishSlots(Self.squishOrder(built.map { (key: $0, areaMM2: stacks[$0]?.areaMM2 ?? 0) }),
                                                      pinchedWith: pinchedWith)
        let order = slots.order, squishShown = slots.shown
        // ★ ROUND 4 (D2): the squeeze groups over the faces built, and whether each has a pinch
        let builtSet = Set(order)
        let partners = FlexibleSqueezeGroups.partners(pinches)
        let plans: [(number: Int, keys: [FlexFaceKey], pinched: Bool)] = squeezeGroups.compactMap { g in
            let keys = order.filter { g.regions.contains($0.region) } + (pressKeysOf[g.id] ?? [])   // ★ R7-E2: its presses in the job
            return keys.isEmpty ? nil : (g.number, keys, g.regions.contains { partners[$0] != nil })
        }
        let sims = self.sims.compactMap { sim -> FlexibleSim? in
            let keys = sim.keys.filter { builtSet.contains($0) }
            return keys.isEmpty ? nil : FlexibleSim(id: sim.id, kind: sim.kind, title: sim.title, short: sim.short, keys: keys)
        }
        let stackOf = stacks.merging(pressStacks) { a, _ in a }, regions = self.regions   // ★ R7-E2: the presses' stacks too
        // ★ MANUAL (M2): what the Manual field is assembled over and pressed with — every press's stack (its key owns its voxels: a
        // group's own lattice reaches its presses) and a Stamp face's pressure on its stamp's footprint (his weight ÷ the footprint)
        var manualPressStacks: [(key: Int, stack: FlexStackInfo)] = []
        var manualPressure: [FlexFaceKey: [Double]] = [:]
        if manualFaces {
            for p in presses { if let r = pressRegistrations[p.id] { manualPressStacks.append((r.key, r.stack)) } }
            for (f, k) in zip(faces, allKeys) where f.isStampShape {
                guard let st = stacks[k], let foot = stampFootprint(f.faceRegionID), foot.count == st.columns.count else { continue }
                let area = foot.reduce(0, +) * st.pitchMM * st.pitchMM
                if area > 1e-9 { manualPressure[k] = foot.map { f.weightN / area * $0 } }
            }
        }
        let manualPressSnap = manualPressStacks, manualPressureSnap = manualPressure
        let manualCellMM = manualSettings.map { FlexibleManualMath.cellMM($0.part, beadWidthMM: manualBeadWidthMM) } ?? 0
        let cutsOf = Dictionary(order.map { ($0.region, regions.cuts(of: $0.region)) }, uniquingKeysWith: { a, _ in a })
        latticeGeneration += 1
        let generation = latticeGeneration
        let (builtKeys, faceNoLattice, extentMM, drawnFaces) = (order, noLattice, extent, drawn)
        let (designedSnap, pressureSnap, squishSnap, depthsSnap) = (designed, pressure, squish, depths)
        let pressKeysSnap = Array(pressStacks.keys), pressCutsSnap = pressCuts, pressIDSnap = pressIDOf
        let depthForBand = shallowest.isFinite ? shallowest : 0
        let build = self.build, key = latticeSettingsKey, temp = designTempC ?? 0   // ★ R7-E2: presses in the job too
        let lawInputs: (path: String, material: String, temp: Double)? = {
            guard let p = materialsPath, let m = settings.materialID, let t = designTempC else { return nil }
            return (p, m, t)
        }()
        let builtOn = openedKey, buildKey = latticeBuildKey
        let label = shapeOnly ? FlexibleReadiness.shapeOnlyLabel(material?.displayName ?? "This filament") : nil
        // ★ ROUND 4 (D1): the WHOLE model's finish (None / Rim / Skin / Covered) — the per-face
        // "Solid skin" is gone
        let finish = settings.finishMode
        let buildDir = sceneInfo?.buildDir ?? SIMD3(0, 0, 1)
        latticeBuilding = true
        latticeError = nil
        let worker = self.worker
        let failWith = controlFailBuild
        let combine = controlCombine
        // ★ MANUAL (M1, his orders of 2026-10-22 ~02:30): in Manual the lattice is HIS — every lattice voxel at his density (the
        // owning group's own, else the part's), his type, his walls; core's mask and owners kept. nil in Auto (nothing changes)
        let manualSnap = settings.isManual && !Self.controlManualLatticeOff ? manualSettings : nil
        let manualOwners = manualSnap == nil ? [:] : manualOwnerGroups()
        // ★ MANUAL P1: each owner's stack for his grade, and each group's own lattice type for its sim's law
        let manualStacks = manualSnap == nil ? [:] : manualGradeOwners()
        let manualOnePerPart = Self.controlOneLatticePerPart
        var manualSimTypes: [String: String] = [:]
        if let ms = manualSnap { for g in squeezeGroups { manualSimTypes[FlexibleSim.groupID(g.number)] = ms.lattice(group: g.id).topology } }
        let manualSimTypesSnap = manualSimTypes
        // ★ BATCH G: the squish sims' law, rests and (shape only) weights — every group a sim
        let feLaw: FlexSquishLawInfo? = materialsPath.map {
            // ★ MANUAL P1: his temperature (no Auto in Manual), and the law EXTENDED past the tested densities (his decision of
            // 2026-10-23: "estimate past tested data", marked on the card); Auto's law exactly as before
            FlexSquishLawInfo(materialsPath: $0, materialID: settings.materialID ?? "", topology: manualSnap?.part.topology ?? build.topology,
                              tempC: manualSnap == nil ? (designTempC ?? 0) : (manualTempC ?? 0), shapeOnly: shapeOnly,
                              extrapolate: manualSnap != nil)
        }
        let feResting = settings.faces.filter { $0.role == "resting" }.map(\.faceRegionID)
        // ★ U21 · I1 (his answer of 2026-10-21 ~15:35, narrowed 2026-10-22 ~02:50): what holds the part — today's chain with a
        // Rest, else Topology's fixed faces (read here, on the main actor; sim only, never written as Rests) → the far side
        let feHold = FlexibleHold.request(resting: feResting, anchors: topologyAnchors)
        let feWeights = Dictionary(zip(allKeys, faces.map(\.weightN)), uniquingKeysWith: { a, _ in a })
        track(Task.detached(priority: .userInitiated) {
            do {
                if let failWith { throw TopOptError(message: failWith) }
                var field: FlexDensityField
                var shared = 0
                var faceDepths = depthsSnap, squishFaces = squishSnap
                var notes: [String: String] = [:]
                var pressDepths: [FlexFaceKey: [Double?]] = [:]   // ★ C1: each press as built (combined field), else core's design
                if shapeOnly {
                    // ★ core's mask, the drawn map's density inside the printable band (a voxel
                    // under two faces — a pinch, two groups — takes the firmer)
                    let mask = try await worker.withScene { try $0.latticeMask(build: build) }
                    let band = try FlexibleGeometryOnlyLattice.band(topology: build.topology, beadsPerWall: build.beadsPerWall,
                                                                    beadWidthMM: build.beadWidthMM, latticeDepthMM: depthForBand)
                    field = FlexibleGeometryOnlyLattice.field(mask: mask, faces: drawnFaces, band: band)
                } else if manualFaces {
                    // ★ MANUAL (M2): no design — core's mask, each voxel owned by the nearest pressed face's (or press's) stack by
                    // core's rule (FlexibleGroupField.assemble); his densities are laid on below (FlexibleManualField)
                    let mask = try await worker.withScene { try $0.latticeMask(build: build) }
                    func face(_ region: Int, _ st: FlexStackInfo, _ cuts: [RegionCut]) -> FlexibleGroupField.Face {
                        FlexibleGroupField.Face(region: region, stack: st, cuts: cuts, density: st.columns.map { $0.latticeMM > 0 ? 1 : 0 },
                                                cellMM: st.columns.map { _ in manualCellMM })
                    }
                    let fs = builtKeys.compactMap { k in stackOf[k].map { face(k.region, $0, cutsOf[k.region] ?? []) } }
                        + manualPressSnap.map { face($0.key, $0.stack, []) }
                    field = FlexibleGroupField.assemble(mask: mask, faces: fs)
                } else {
                    var fields: [FlexDensityField] = []
                    var mask: FlexDensityField?
                    for plan in plans {
                        if plan.pinched {
                            // ★ a PINCH: core refuses one stack pressed from both ends — the app
                            // assembles it by core's rule, over each face's halves
                            if mask == nil { mask = try await worker.withScene { try $0.latticeMask(build: build) } }
                            let fs = plan.keys.compactMap { k -> FlexibleGroupField.Face? in
                                guard let st = stackOf[k], let sg = designedSnap[k] else { return nil }
                                return FlexibleGroupField.Face(region: k.region, stack: st, cuts: cutsOf[k.region] ?? [],
                                                               density: sg.buildableDensity, cellMM: sg.cellMM)
                            }
                            fields.append(FlexibleGroupField.assemble(mask: mask!, faces: fs))
                        } else {
                            let f = try await worker.withScene {
                                try $0.densityField(faces: plan.keys.map(\.region), rotations: plan.keys.map(\.rotation), build: build)
                            }
                            fields.append(FlexibleGroupField.clipToPresses(f, cuts: pressCutsSnap))   // ★ R7-E2 FIX
                        }
                    }
                    guard !fields.isEmpty else { throw TopOptError(message: "No pressed face has a design yet.") }
                    if fields.count == 1 {
                        field = fields[0]
                    } else {
                        let c = combine(fields)
                        field = c.field
                        shared = c.shared
                        // ★ SEPARATE SQUEEZES: each face squishes by what its column holds in the
                        // COMBINED field (≈), and a group that misses its design says so
                        if let li = lawInputs {
                            let law = try FlexiblePinch.Law.core(materialsPath: li.path, materialID: li.material, tempC: li.temp, build: build)
                            for k in builtKeys {
                                guard let st = stackOf[k], let sg = designedSnap[k], let p = pressureSnap[k] else { continue }
                                let d = try FlexibleGroupField.asBuilt(field, stack: st, segments: sg, pressureMPa: p,
                                                                        strainUnder: law.strainUnder)
                                faceDepths[k] = d
                                squishFaces[k] = FlexibleSquishFace(stack: st, depthsMM: d)
                            }
                            // ★ R7-E2: each press as built too (its group's note), never one of the pass's faces
                            for k in pressKeysSnap {
                                guard let st = stackOf[k], let sg = designedSnap[k], let p = pressureSnap[k] else { continue }
                                pressDepths[k] = try FlexibleGroupField.asBuilt(field, stack: st, segments: sg, pressureMPa: p,
                                                                                strainUnder: law.strainUnder)
                            }
                            for plan in plans {
                                let want = plan.keys.compactMap { designedSnap[$0]?.buildableDepthMM.compactMap { $0 }.max() }.max() ?? 0
                                let got = plan.keys.compactMap { (faceDepths[$0] ?? pressDepths[$0])?.compactMap { $0 }.max() }.max() ?? 0
                                if FlexibleGroupEstimate.misses(designedMM: want, asBuiltMM: got) {
                                    notes[FlexibleSim.groupID(plan.number)] =
                                        FlexibleRowCopy.groupMisses(number: plan.number, asBuiltMM: got, designedMM: want)
                                }
                            }
                        }
                    }
                }
                // ★ MANUAL P1: every lattice voxel at its group's own density (graded as he set it), walls and type — the numbers
                // on its card. RED CONTROL `controlOneLatticePerPart`: M1's one type and one wall for the part
                var manualGrids: FlexibleManualField.Built?
                if let ms = manualSnap {
                    let b = FlexibleManualField.build(field, manual: ms, ownerGroups: manualOwners, owners: manualStacks,
                                                      beadWidthMM: build.beadWidthMM)
                    field = b.field
                    if !manualOnePerPart { manualGrids = b }
                }
                let inputs = try FlexibleLatticeBuilder.inputs(
                    field: field, part: part, topology: manualSnap?.part.topology ?? build.topology, beadsPerWall: build.beadsPerWall,
                    beadWidthMM: build.beadWidthMM,
                    wallMM: manualSnap.map { FlexibleManualMath.wallMM($0.part, beadWidthMM: build.beadWidthMM) },
                    buildDir: buildDir,
                    pressCuts: shapeOnly ? [:] : pressCutsSnap,   // ★ R7-U21 H (EDGE-LOOK): the presses' seams
                    manualWall: manualGrids?.wallMM, manualType: manualGrids?.type,   // ★ MANUAL P1: his walls and types
                    manualPiece: manualGrids?.code,   // ★ MANUAL P2: the pieces, joined cleanly where they meet
                    skinOffFaces: [], finish: finish)
                // ★ BATCH G: what the squish sims need, made HERE — the combined field is not kept
                // (D-R4-19); the solver releases it after the last sim
                var fe: FlexibleFERequest?
                if let law = feLaw {
                    var fs: [FlexFaceKey: FlexibleFERequest.Face] = [:]
                    for k in builtKeys {
                        guard let st = stackOf[k] else { continue }
                        let sg = designedSnap[k]
                        let even = (feWeights[k] ?? 0) / Swift.max(st.footprintAreaMM2, 1e-9)
                        fs[k] = FlexibleFERequest.Face(key: k, stack: st, cuts: cutsOf[k.region] ?? [], depthsMM: faceDepths[k] ?? [],
                                                       heightsMM: sg?.heightMM ?? st.columns.map(\.latticeMM),
                                                       pinched: sg?.pinched ?? [],
                                                       pressureMPa: pressureSnap[k] ?? manualPressureSnap[k]   // ★ MANUAL (M2): his stamp
                                                           ?? [Double](repeating: even, count: st.columns.count))
                    }
                    fe = FlexibleFERequest.build(field: field, inputs: inputs, sims: sims, faces: fs, resting: feResting,
                                                 law: law, generation: generation)
                    fe?.hold = feHold
                    // ★ MANUAL (M1): the views are the app's estimate from HIS lattice — no core design to scale them to
                    if manualSnap != nil { fe = fe?.manualEstimate; fe?.simTopology = manualSimTypesSnap }
                }
                let feBuilt = fe
                // ★ C1: the presses core designed and this lattice carries — their sims calibrate to these depths
                var tuned: [UUID: FlexibleFEField.Target] = [:]
                for k in pressKeysSnap {
                    guard let id = pressIDSnap[k], let st = stackOf[k],
                          // ★ X20b (his answer of 2026-10-20 ~19:10: "Edge Play shows CORE'S FULL DESIGN DEPTH"): core's own design depth,
                          // not the press as built in the combined field (C1's reviewer question 2); RED CONTROL `controlAsBuiltTargets`
                          let d = Self.controlAsBuiltTargets ? (pressDepths[k] ?? designedSnap[k]?.buildableDepthMM)
                                                             : (designedSnap[k]?.buildableDepthMM ?? pressDepths[k]) else { continue }
                    tuned[id] = FlexibleFEField.Target(stack: st, depthsMM: d, pinched: [])
                }
                let tunedSnap = tuned
                let faceList = builtKeys.compactMap { squishFaces[$0] }
                let g = FlexibleGeneratedLattice(inputs: inputs, faces: faceList, keys: builtKeys, columnDepths: faceDepths,
                                                 columnNoLattice: faceNoLattice, extentMM: extentMM, generation: generation,
                                                 topology: build.topology, tempC: temp, settingsKey: key,
                                                 squishedKeys: Array(builtKeys.prefix(squishShown)),
                                                 shapeOnlyLabel: label, sceneKey: builtOn,
                                                 sims: sims, simNotes: notes, sharedVoxels: shared, pinchedWith: pinchedWith)
                let combined = field
                let keep = await MainActor.run { self.keepCombinedField }
                let kept = keep ? combined : nil
                await MainActor.run {
                    self.lattice = g; self.lastCombinedField = kept; self.latticeBuilding = false
                    self.latticeTunedPresses = Self.controlNoTune || manualSnap != nil ? [:] : tunedSnap   // ★ C1 (★ MANUAL: none)
                    self.latticeLanded(feBuilt)   // ★ BATCH G: a new lattice — its own squish sims
                }
            } catch {
                await MainActor.run {
                    self.latticeFailedKey = buildKey
                    self.latticeError = "\(error)"
                    self.latticeBuilding = false
                }
            }
        })
    }

    /// Test control only: how separate squeezes are combined (the rule: the firmer wins).
    var controlCombine: @Sendable ([FlexDensityField]) -> (field: FlexDensityField, shared: Int) = { FlexibleGroupField.firmer($0) }

    public func discardLattice() { lattice = nil; latticeTunedPresses = [:]; latticeLanded(nil) }
    /// ★ RED CONTROL only (C1): the lattice carries no press's design for its sim (the interim sim, uncalibrated, and the chip).
    nonisolated(unsafe) static var controlNoTune = false

    /// Test control only: the next builds throw this (a builder or core refusal on the build).
    var controlFailBuild: String?

    // MARK: the run job (S5)

    /// The run job. ★ C2 VERIFICATION: `resting` — pressed faces that REST in this job only (the
    /// Export step's [Send with Face 5 resting] / [Send Group 1 only]: what core can run of a
    /// pinch or of several squeeze groups); his settings are untouched. A part with no file is
    /// its own error (C2 told him "press a face first").
    public func runJobJSON(resting: Set<Int> = []) throws -> String {
        guard let file = project.importedFile else { throw FlexibleJob.EncodeError.noPart }
        var s = settings
        if !resting.isEmpty {
            for r in resting {
                guard var f = s.face(r), f.isLoaded else { continue }
                f.role = "resting"
                s.setFace(f)
            }
            FlexibleSqueezeGroups.normalise(&s)
        }
        let pinches = FlexibleSqueezeGroups.pinches(conflicts, s)
        // ★ R7-E2: the presses IN THE JOB, but those a send leaves out (one of their regions among `resting` — a press is never a
        // resting entry); written after the face entries
        let pressEntries = Self.controlStripPresses ? [] : pressJobEntries(excluding: resting)
        // ★ ROUND 4 (D2): what core cannot run yet (core brief) is said, never sent to be refused
        if FlexibleSqueezeGroups.groups(s, sent: Set(pressEntries.map(\.id))).count > 1 { throw FlexibleJob.EncodeError.squeezeGroups }
        if !pinches.isEmpty { throw FlexibleJob.EncodeError.pinch }
        let faceCount = max(file.faceCount, (project.viewerMesh?.faceIDs.max().map { Int($0) + 1 }) ?? 0)
        var inputs = FlexibleJob.Inputs(
            modelPath: file.path, resolution: project.quality.resolution,
            beadWidthMM: project.printParams.strutLineWidthMM, faceCount: faceCount,
            settings: s, regions: project.latticeJobRegions().regions.map(\.wireDictionary),
            stampGrids: stampGrids)
        // ★ ROUND 7 (M2): the run job declares his Surface sectors and the Flexible sectors its entries USE (a lattice
        // section pressed, a strip's rest); a section nothing presses is the scene's (taps, stacks), never a run's
        let used = Set(s.faces.map(\.faceRegionID) + (s.presses ?? []).flatMap(\.regions))
        inputs.sectorRegions = regions.wire.filter { e in
            guard let id = e["id"] as? Int, FlexibleSectors.isFlexible(id) else { return true }
            return used.contains(id)
        }
        (inputs.buildDir, inputs.plateDir) = buildDirections
        inputs.pinches = pinches.map { [$0.a, $0.b] }
        inputs.presses = pressEntries
        return try FlexibleJob.runJobJSON(inputs)
    }
}
