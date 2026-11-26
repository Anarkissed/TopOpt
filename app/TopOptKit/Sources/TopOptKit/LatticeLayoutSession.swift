// LatticeLayoutSession — the lattice rebuild's stage E entry, Swift side (362; LatticeLayoutBridge.hpp). One session per part
// while its Lattice page is open: `open` reads and measures the model once (STEP, STL or 3MF — the faces the app sees),
// `lay` lays the lattice for a set of settings (core keeps what a change does not touch, rule P2), `whereAt` says what is at a
// batch of points for the LAST layout (the drawer's lattice / rim / solid, the blue glow's reasons).
//
// ★ Every call runs on the session's OWN worker thread, a 16 MB stack, never main (his 10-28 iPad crash: the iPad's main-thread
// stack is small, and macOS tests cannot see it). ★ Latest wins: a `lay` asked while an older one waits or runs makes the
// older come back as CancellationError (the waiting one never starts; the running one is told through core's bridge, and its
// result dropped) — a slider moved ten times lays the tenth. A cancelled Task cancels its own layout the same way.
import Foundation
import simd
import TopOptBridge

public final class LatticeLayoutSession: @unchecked Sendable {

    /// Why a place is solid, or that it is lattice (core's lattice_layout::Why, and D14's no cell fits).
    public enum Why: UInt8, Sendable, CaseIterable {
        case lattice = 0, outside, notAsked, noLattice, protectSkin, wallTooThin, rim, cover, noCellFits
        public var isSolid: Bool { self != .lattice && self != .outside }
    }

    /// How a bar's end finishes (core's Bar::End).
    public enum End: UInt8, Sendable { case node = 0, solid, surface, loose, joined }

    /// One half-space of an Edit faces cut (core's FaceCut, rule D22): a point p is kept when (p - point) . normal >= 0, or
    /// > 0 when `strict`.
    public struct Cut: Sendable, Equatable, Codable {
        public var point: SIMD3<Double>
        public var normal: SIMD3<Double>
        public var strict: Bool
        public init(point: SIMD3<Double>, normal: SIMD3<Double>, strict: Bool = false) {
            self.point = point; self.normal = normal; self.strict = strict
        }
    }

    /// A piece of the model's faces as Edit faces cut it (core's FacePiece): its faces' surface where every cut holds.
    public struct Piece: Sendable, Equatable {
        public var faces: [Int32]
        public var cuts: [Cut]
        public init(faces: [Int32], cuts: [Cut]) { self.faces = faces; self.cuts = cuts }
    }

    /// An area's own cells and struts (core's AreaOwn, C23 / R19): nil = the part's. `algorithm` is core's id.
    public struct AreaOwn: Sendable, Equatable {
        public var algorithm: String?
        public var cellMM: Double?, cellMaxMM: Double?, cellMinMM: Double?
        public var minCellsAcross: Int32?
        public var gradeToShape: Bool?
        public var bandMM: Double?, bandCellMM: Double?
        public var cellsByStress: Bool?
        public var byStress: Bool?
        public var dial: Double?, dialLight: Double?, dialHeavy: Double?
        public var widthMM: Double?, widthLightMM: Double?, widthHeavyMM: Double?
        public var strength: Double?, response: Double?, referenceMPa: Double?, maxStep: Double?
        public init() {}
        public var any: Bool { self != AreaOwn() }
        /// The bridge's 20 numbers (LatticeLayoutBridge.hpp's order), NaN where not stated.
        var wire: [Double] {
            func d(_ v: Double?) -> Double { v ?? .nan }
            func b(_ v: Bool?) -> Double { v.map { $0 ? 1 : 0 } ?? .nan }
            let alg: Double = algorithm.map { $0 == "uniform" ? 0 : $0 == "stepped" ? 2 : 1 } ?? .nan
            return [alg, d(cellMM), d(cellMaxMM), d(cellMinMM), minCellsAcross.map(Double.init) ?? .nan, b(gradeToShape),
                    d(bandMM), d(bandCellMM), b(cellsByStress), b(byStress), d(dial), d(dialLight), d(dialHeavy), d(widthMM),
                    d(widthLightMM), d(widthHeavyMM), d(strength), d(response), d(referenceMPa), d(maxStep)]
        }
    }

    /// An area's own Finish (core's S13): nil = the part's. Rim / cover: 0 none, < 0 two line widths, > 0 that width.
    public struct RegionFinish: Sendable, Equatable {
        public var rimMM: Double?, coverMM: Double?
        public var skin: Bool?
        public var skinWidthMM: Double?, skinReachCells: Double?
        /// ★ Cut 2 (OJ8): the skin's density (1 to 6) and sink (0 to 1).
        public var skinDensity: Int?, skinSink: Double?
        public init() {}
        public var any: Bool { self != RegionFinish() }
        var wire: [Double] {
            [rimMM ?? .nan, coverMM ?? .nan, skin.map { $0 ? 1 : 0 } ?? .nan, skinWidthMM ?? .nan, skinReachCells ?? .nan,
             skinDensity.map(Double.init) ?? .nan, skinSink ?? .nan]
        }
    }

    /// A zone in place of a region's faces (core's Zone, D21), in the part's own coordinates, mm. A box: three unit axes at
    /// right angles and three half sizes. A cylinder: its unit axis is `axes[2]`, its radius `half.x`, its half length `half.z`.
    public struct Zone: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case box, cylinder }
        public var kind: Kind
        public var centre: SIMD3<Double>
        public var axes: [SIMD3<Double>]
        public var half: SIMD3<Double>
        public init(kind: Kind, centre: SIMD3<Double>, axes: [SIMD3<Double>], half: SIMD3<Double>) {
            self.kind = kind; self.centre = centre; self.axes = axes; self.half = half
        }
        var wire: [Double] {
            let a = axes + Array(repeating: SIMD3<Double>(0, 0, 0), count: max(0, 3 - axes.count))
            return [kind == .box ? 1 : 2, centre.x, centre.y, centre.z] + a.prefix(3).flatMap { [$0.x, $0.y, $0.z] }
                + [half.x, half.y, half.z]
        }
    }

    public struct Region: Sendable, Equatable {
        public var id: Int32            // > 0
        public var noLattice: Bool
        public var faces: [Int32]       // the model's own face numbers (the app's FaceIDs)
        public var depthMM: Double
        public var expandMM: Double
        /// ★ his ask 11-14 (D22): the cut pieces this region is, in place of whole faces; empty = `faces` as they are.
        public var pieces: [Piece] = []
        /// Install 2: the area's own cells and struts, its own Finish, and a zone in place of faces.
        public var own = AreaOwn()
        public var finish = RegionFinish()
        public var zone: Zone?
        /// ★ Organic cut 1: the Organic weave fills this region, not cells (core's RegionAsk::weave).
        public var weave = false
        public init(id: Int32, noLattice: Bool = false, faces: [Int32], depthMM: Double, expandMM: Double = 0,
                    pieces: [Piece] = []) {
            self.id = id; self.noLattice = noLattice; self.faces = faces; self.depthMM = depthMM; self.expandMM = expandMM
            self.pieces = pieces
        }
    }

    public struct Protect: Sendable, Equatable {
        public var id: Int32
        public var faces: [Int32]
        public var depthMM: Double      // 0 = two line widths
        /// ★ his ask 11-14 (D22): the cut pieces under this skin, in place of whole faces; empty = `faces` as they are.
        public var pieces: [Piece] = []
        /// ★ D23 (his 11-17 "add a chip to ask what it should be"): this skin is a chip's answer "Solid" — its place stays
        /// listed (now solid) so the chip can be answered again; false: his own Protect skin.
        public var chip = false
        public init(id: Int32, faces: [Int32], depthMM: Double = 0, pieces: [Piece] = [], chip: Bool = false) {
            self.id = id; self.faces = faces; self.depthMM = depthMM; self.pieces = pieces; self.chip = chip
        }
    }

    /// ★ D23: a face (or edge-joined faces) a region's prism runs into that no rule decides — where a chip asks what it should
    /// be. `now`: what the engine makes there (lattice, or solid under a chip's answer).
    public struct Place: Sendable, Equatable {
        public var region: Int32
        public var faces: [Int32]      // raw face ids, the seeds first
        public var point: SIMD3<Float>
        public var normal: SIMD3<Float>
        public var areaMM2: Double
        public var solidNow: Bool
        public init(region: Int32, faces: [Int32], point: SIMD3<Float>, normal: SIMD3<Float>, areaMM2: Double, solidNow: Bool) {
            self.region = region; self.faces = faces; self.point = point; self.normal = normal; self.areaMM2 = areaMM2
            self.solidNow = solidNow
        }
    }

    /// Core's settings, one for one (LatticeLayoutBridge.hpp says what each does).
    public struct Settings: Sendable, Equatable {
        public var allLattice = false
        public var beadMM = 0.45
        public var minStrutLines = 2.0   // ★ two lines (the reviewer's ruling 11-12: one line does not print on his 0.4 mm nozzle)
        public var minWallMM = 0.0
        public var rimMM = 0.0
        public var coverMM = 0.0
        public var regions: [Region] = []
        public var protect: [Protect] = []
        public var topology = "octet"
        public var algorithm = "default_grade"
        public var cellMM = 0.0
        public var cellMaxMM = 8.0
        public var cellMinMM = 0.0
        public var minCellsAcross: Int32 = 1
        public var gradeToShape = false
        public var bandMM = 0.0
        public var bandCellMM = 0.0
        public var perRegion = false
        public var dial = 0.45
        public var regionDials: [(region: Int32, dial: Double)] = []
        public var strutWidthMM = 0.0
        public var allowQuilt = false
        public var strength = 0.0
        public var bars = true
        public var joinLoose = true
        public var skin = false
        public var skinWidthMM = 0.0
        public var skinReachCells = 1.2
        public var dropLoose = true
        public var smallCellsInThinWalls = false   // his per-part choice (11-13)
        public var oneGrid = false                 // "Let walls cut cells" (11-14; Aesthetic only, the app's to enforce)
        // Install 2: By stress (the session's stress result, `setDemand`), cell size by stress, the stress grade, the size step
        public var byStress = false
        public var dialLight = 0.01               // "Grade to"
        public var dialHeavy = 1.0                // "Grade from"
        public var widthLightMM = 0.0, widthHeavyMM = 0.0
        public var cellsByStress = false
        public var referenceMPa = 0.0             // 0 = the part's own (the percentile)
        public var percentile = 0.95
        public var response = 1.0
        public var maxStep = 0.0                  // his switch "Never skip a cell size": 2 on Default Grade
        /// ★ K7, K8 (Auto only): the cells fitted to the faces the grid is square to — the base cell searched for the fewest
        /// slivers there, and a sliver left taken in by the row beside it (core's cell_search and stretch_edges, both)
        public var cellSearch = false
        public var bedFloorMM = 0.0               // ★ Organic: K1's flat floor under the weave (sheet H1); 0 none
        /// ★ SHEETS (notes28 sheets SPEC 1.5): "Where regions meet" for two sheet regions that touch: "blend" | "solid_wall"
        /// (the page sends Blend in Aesthetic, Solid wall in Structural; read for a sheet type only).
        public var sheetSeam = "solid_wall"
        /// ★ SHEETS (SPEC 1.3): Auto's wall by the cell (core's StrutSpec::auto_by_cell; the page's Auto for a sheet).
        public var autoByCell = false
        /// ★ SHEETS, builder E (SPEC 1.5): seams laid as the solid wall whatever `sheetSeam` asks, two region ids each (core's
        /// Settings::sheet_walls): the seams the last print file fell back on, so the preview draws the wall it printed.
        public var sheetWalls: [Int32] = []
        public init() {}
        public static func == (a: Settings, b: Settings) -> Bool {
            a.allLattice == b.allLattice && a.beadMM == b.beadMM && a.minStrutLines == b.minStrutLines && a.minWallMM == b.minWallMM
                && a.rimMM == b.rimMM && a.coverMM == b.coverMM && a.regions == b.regions && a.protect == b.protect
                && a.topology == b.topology && a.algorithm == b.algorithm && a.cellMM == b.cellMM && a.cellMaxMM == b.cellMaxMM
                && a.cellMinMM == b.cellMinMM && a.minCellsAcross == b.minCellsAcross && a.gradeToShape == b.gradeToShape
                && a.bandMM == b.bandMM && a.bandCellMM == b.bandCellMM && a.perRegion == b.perRegion && a.dial == b.dial
                && a.regionDials.map(\.region) == b.regionDials.map(\.region) && a.regionDials.map(\.dial) == b.regionDials.map(\.dial)
                && a.strutWidthMM == b.strutWidthMM && a.allowQuilt == b.allowQuilt && a.strength == b.strength && a.bars == b.bars
                && a.joinLoose == b.joinLoose && a.skin == b.skin && a.skinWidthMM == b.skinWidthMM
                && a.skinReachCells == b.skinReachCells && a.dropLoose == b.dropLoose
                && a.smallCellsInThinWalls == b.smallCellsInThinWalls && a.oneGrid == b.oneGrid
                && a.byStress == b.byStress && a.dialLight == b.dialLight && a.dialHeavy == b.dialHeavy
                && a.widthLightMM == b.widthLightMM && a.widthHeavyMM == b.widthHeavyMM && a.cellsByStress == b.cellsByStress
                && a.referenceMPa == b.referenceMPa && a.percentile == b.percentile && a.response == b.response
                && a.maxStep == b.maxStep && a.bedFloorMM == b.bedFloorMM && a.cellSearch == b.cellSearch
                && a.sheetSeam == b.sheetSeam && a.autoByCell == b.autoByCell && a.sheetWalls == b.sheetWalls
        }
    }

    /// One layout, as flat arrays the drawer reads straight into its buffers (a list that grows with the part goes in a GPU
    /// BUFFER, never inline — his 11-11 crash; the rebuild's rule).
    public struct Result: Sendable {
        public var bars: [Float] = []          // 7 per bar: a xyz, b xyz, width mm
        public var barEnds: [UInt8] = []       // 2 per bar: End
        public var barFlags: [UInt8] = []      // 1 per bar: 1 a piece of a cut strut, 2 a skin bar
        public var barRegion: [Int32] = []
        public var barCell: [Float] = []       // ★ Install 3: 1 per bar: its cell's size, mm (core's Bar::cell)
        public var frames: [Float] = []        // 12 per frame: origin, then three unit axes
        public var solidCubes: [Float] = []    // 4 per solid piece: low corner (frame mm) and size
        public var cellInfo: [Float] = []      // 5 per laid cell: size, own, band, finest, cut (LatticeLayoutBridge.hpp)
        // ★ Install 3: per laid cell, aligned with cellInfo — its region (0 = the whole part), its wall (-1 = none), its frame
        // and its cube's low corner (3 per cell, frame mm)
        public var cellRegion: [Int32] = []
        public var cellWall: [Int32] = []
        public var cellFrame: [Int32] = []
        public var cellLo: [Float] = []
        public var cellWallMM: [Float] = []    // 1 per cell: its wall's width, mm; 0 = the space no wall holds
        public var solidFrame: [Int32] = []
        public var solidRegion: [Int32] = []
        public var solidWhy: [UInt8] = []      // a Why per solid piece
        public var steppedEdges: [Float] = []  // 4 per edge: at xyz, ends
        public var steppedRegion: [Int32] = []
        public var emptyRegions: [Int32] = []
        public var cells = 0, solidPieces = 0, atOneLine = 0, atWidest = 0, stubs = 0, joined = 0, dropped = 0, pieces = 0, adrift = 0
        public var floorCellMM = 0.0, minStrutMM = 0.0, openLook = 0.0, touch = 0.0
        /// The rebuild's rules (a), (b) of 11-12, nil until core measures them.
        public var bedContactMM2: Double?
        public var midairStarts: Int?
        public var readAgain = false
        // Install 2: By stress and the cells (LatticeLayoutBridge.hpp)
        public var noStress = false
        public var referenceMPa = 0.0, highestMPa = 0.0
        public var atLight = 0, atHeavy = 0
        public var cellsByStress = false, cellsNoStress = false
        public var stressReferenceMPa = 0.0, stepHeldAt = 0.0
        public var thinSolid = 0
        public var msRead = 0.0, msCells = 0.0, msBars = 0.0, msBridge = 0.0
        /// ★ SHEETS (the contract's Outcome::sheets, sheet_seams): one field per laid sheet region and the pairs that touch;
        /// empty for a strut type (then `bars` is the lattice), and `bars` is empty for a sheet.
        public var sheets: [LatticeSheetField] = []
        public var sheetSeams: [LatticeSheetSeam] = []
        public var barCount: Int { bars.count / 7 }
        /// Something was laid: bars, or a sheet.
        public var laidAnything: Bool { barCount > 0 || !sheets.isEmpty }
    }

    public struct OpenInfo: Sendable {
        public let faces: Int
        public let openEdges: Int
        public let msOpen: Double
        /// ★ notes29: opened standing the way it prints (`open(path:printUp:)`).
        public var framed = false
    }

    public let id: Int64
    public let info: OpenInfo
    /// ★ notes29 (P8, his print orientation): the up the part was opened standing along (the print file's `print_frame`), in
    /// the part's own coordinates; nil: as placed. Every call still takes and gives the part's own coordinates.
    public let printUp: SIMD3<Double>?
    let worker: LatticeLayoutWorker
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var closed = false

    /// The worker's stack: 16 MB (the iPad's main thread has 1 MB; core recurses in its measure).
    public static let workerStackSize = 16 << 20

    private init(id: Int64, info: OpenInfo, printUp: SIMD3<Double>? = nil, worker: LatticeLayoutWorker) {
        self.id = id; self.info = info; self.printUp = printUp; self.worker = worker
    }

    deinit { close() }

    /// Opens the imported model at `path` (STEP, STL or 3MF) on a new worker thread.
    /// What core's `run_file_job` said: made, or refused with its word and plain line.
    public struct FileJobOutcome: Sendable, Equatable {
        public var ok: Bool
        public var exitCode: Int
        public var code: String
        public var why: String
        public var msTotal: Double
        /// Not ok: core's technical message behind `why` (for the log, never on screen).
        public var detail: String = ""
    }

    /// ★ THE PRINT FILE ON THE iPAD (his 11-17): the same `lattice_file` job the Mac's worker runs, through core's own
    /// `run_file_job`, on a thread with the layout's stack (laying needs it; a GCD thread's 512 KB does not hold it).
    /// Blocking: call it off the main thread. `outDir` must exist; it receives the STL and lattice_file.json.
    public static func runFileJob(jobPath: String, outDir: String, materialsPath: String, rulesPath: String) throws -> FileJobOutcome {
        var outcome: Swift.Result<FileJobOutcome, Error> = .failure(CancellationError())
        let done = DispatchSemaphore(value: 0)
        let t = Thread {
            var err = topoptbridge.BridgeError()
            let r = topoptbridge.lattice_file_job(std.string(jobPath), std.string(outDir), std.string(materialsPath),
                                                  std.string(rulesPath), &err)
            outcome = err.ok ? .success(FileJobOutcome(ok: r.ok, exitCode: Int(r.exit_code), code: String(r.code),
                                                       why: String(r.why), msTotal: r.ms_total, detail: String(r.detail)))
                             : .failure(TopOptError(message: String(err.message)))
            done.signal()
        }
        t.stackSize = workerStackSize
        t.name = "TopOpt lattice file"
        t.qualityOfService = QualityOfService.userInitiated
        t.start()
        done.wait()
        return try outcome.get()
    }

    /// ★ notes29 (P8, his print orientation: after Keep, the Organic preview still grew along the part's +Z): `printUp` given,
    /// the part is opened standing the way its print file stands (core's print frame: up IS +Z there; LatticeLayoutBridge.hpp,
    /// lattice_layout_open_framed) — the lattice is laid as the print file lays it and every place comes back in the part's own
    /// coordinates. nil: as before, not a byte moved.
    public static func open(path: String, linearDeflection: Double = 0, printUp: SIMD3<Double>? = nil) async throws
        -> LatticeLayoutSession {
        let worker = LatticeLayoutWorker(stackSize: workerStackSize)
        let raw: topoptbridge.LatticeLayoutOpenInfo = try await worker.run {
            var err = topoptbridge.BridgeError()
            let r: topoptbridge.LatticeLayoutOpenInfo
            if let up = printUp {
                r = topoptbridge.lattice_layout_open_framed(std.string(path), linearDeflection, up.x, up.y, up.z, &err)
            } else {
                r = topoptbridge.lattice_layout_open(std.string(path), linearDeflection, &err)
            }
            if !err.ok { throw TopOptError(message: String(err.message)) }
            return r
        }
        var info = OpenInfo(faces: Int(raw.faces), openEdges: Int(raw.open_edges), msOpen: raw.ms_open)
        info.framed = raw.framed
        return LatticeLayoutSession(id: raw.session, info: info, printUp: printUp, worker: worker)
    }

    /// A new lay's generation; the one running now comes back cancelled (latest wins). (`lay`, and Organic's `layOrganic`.)
    func beginLay() -> UInt64 {
        let mine: UInt64 = lock.withLock {
            generation &+= 1
            return generation
        }
        topoptbridge.lattice_layout_cancel(id)
        return mine
    }

    /// Lays the lattice. Latest wins: an older `lay` still waiting or running throws CancellationError.
    public func lay(_ settings: Settings) async throws -> Result {
        let mine: UInt64 = lock.withLock {
            generation &+= 1
            return generation
        }
        topoptbridge.lattice_layout_cancel(id)          // the one running now comes back cancelled
        let raw = convert(settings)
        let sid = id
        return try await withTaskCancellationHandler {
            try await worker.run { [weak self] () throws -> Result in
                guard let self, self.isCurrent(mine) else { throw CancellationError() }   // superseded before it started
                Self.lastLayBegan = Date()   // ★ notes30 Q1 (a test's reading)
                var err = topoptbridge.BridgeError()
                let r = topoptbridge.lattice_layout(sid, raw, &err)
                if !err.ok { throw TopOptError(message: String(err.message)) }
                if r.cancelled || !self.isCurrent(mine) { throw CancellationError() }
                return Self.convert(r)
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    /// ★ D23: the chips' places of the last layout, asked with the SAME settings it was laid with (other settings: none). A
    /// separate call (it costs about as much as a layout).
    /// ★ notes30 Q1 (S-2, his yes 11-26: on a big flat part it took 3.1 s on this session's one worker, and a setting changed
    /// right then waited behind it): it gives way at once. A newer `lay` (or Organic lay), or the asking task cancelled (the
    /// page's next setting), makes it — running or still waiting — throw CancellationError within one triangle's work
    /// (core's find_places reads the bridge's places stop); the page asks again for the lattice that lands next.
    public func places(_ settings: Settings) async throws -> (places: [Place], ms: Double) {
        let sid = id
        let raw = convert(settings)
        let ticket = topoptbridge.lattice_layout_places_ticket(sid)   // ★ notes30 Q1: a cancel after this wins
        let giveWay = !Self.controlPlacesHoldTheWorker
        Self.placesAsked += 1
        return try await withTaskCancellationHandler {
            try await worker.run {
                var err = topoptbridge.BridgeError()
                let r = topoptbridge.lattice_layout_places(sid, raw, ticket, giveWay, &err)
                if !err.ok { throw TopOptError(message: String(err.message)) }
                if r.cancelled { throw CancellationError() }   // ★ notes30 Q1: given way (none, never part of a list)
                let counts = Array(r.face_counts), faces = Array(r.faces), pt = Array(r.point), nm = Array(r.normal)
                let area = Array(r.area_mm2), solid = Array(r.solid_now), region = Array(r.region)
                var out: [Place] = []
                var k = 0
                for i in 0..<region.count {
                    let n = Int(counts[i])
                    out.append(Place(region: region[i], faces: Array(faces[k..<k + n]),
                                     point: SIMD3(pt[3 * i], pt[3 * i + 1], pt[3 * i + 2]),
                                     normal: SIMD3(nm[3 * i], nm[3 * i + 1], nm[3 * i + 2]),
                                     areaMM2: area[i], solidNow: solid[i] != 0))
                    k += n
                }
                return (out, r.ms)
            }
        } onCancel: {
            topoptbridge.lattice_layout_places_cancel(sid)   // ★ notes30 Q1: the page's next setting — never `cancel()`'s stop
        }
    }
    /// RED CONTROL (tests): the places search no newer lay stops (before notes30 Q1: the next lay waited for it).
    nonisolated(unsafe) public static var controlPlacesHoldTheWorker = false
    /// Places searches asked, app-wide (a test's count: one is running).
    nonisolated(unsafe) public static private(set) var placesAsked = 0
    /// When the last `lay` began on its worker, app-wide (a test's reading: a lay asked during the search starts at once).
    nonisolated(unsafe) public static private(set) var lastLayBegan = Date.distantPast
    /// RED CONTROL (tests): a map a newer lay stopped comes back empty, read as "no lattice asked" (before notes30 Q2).
    nonisolated(unsafe) public static var controlStoppedMapReadsEmpty = false

    /// What is at each point for the last layout (empty before the first).
    public func whereAt(_ points: [SIMD3<Float>]) async throws -> [(why: Why, region: Int32)] {
        let sid = id
        var pts = topoptbridge.LatticeLayoutPoints()
        for p in points { pts.xyz.push_back(p.x); pts.xyz.push_back(p.y); pts.xyz.push_back(p.z) }
        let input = pts
        return try await worker.run {
            var err = topoptbridge.BridgeError()
            let r = topoptbridge.lattice_layout_where(sid, input, &err)
            if !err.ok { throw TopOptError(message: String(err.message)) }
            return zip(Array(r.why), Array(r.id)).map { (Why(rawValue: $0.0) ?? .outside, $0.1) }
        }
    }

    /// THE SOLID VIEW's map for the last layout (LatticeLayoutBridge.hpp, lattice_layout_grid): 2 signed bytes per voxel (open,
    /// inside), x fastest; voxel (0,0,0)'s centre at `origin`. Empty before the first layout.
    /// ★ SHEETS (builder B; the bridge's region and seam channels, empty for every other type), one entry per voxel in `rg`'s
    /// order: `sheetField` the index of the field (Result.sheets' order) whose cell holds the voxel (255 none; an outside voxel
    /// the map opens takes its open neighbour's), `sheetSeam` the blend seam (Result.sheetSeams' order) of that field nearest
    /// across (255 none), `sheetSeamMM` its signed distance across, mm, + toward the seam's b side (core's sheet_seam_mm).
    public func grid(origin: SIMD3<Float>, voxel: Float, dims: SIMD3<Int32>) async throws
        -> (rg: [Int8], ms: Double, asked: Int, unheld: Int, nocell: [Int], sheetField: [UInt8], sheetSeam: [UInt8],
            sheetSeamMM: [Float]) {
        let sid = id
        return try await worker.run {
            var err = topoptbridge.BridgeError()
            let r = topoptbridge.lattice_layout_grid(sid, origin.x, origin.y, origin.z, voxel, dims.x, dims.y, dims.z, &err)
            if !err.ok { throw TopOptError(message: String(err.message)) }
            // ★ notes30 Q2: a newer lay stopped it — said as such; read empty, it was "no lattice asked" (the nozzle check
            // then answered "would not lattice much more" of a part nothing had checked)
            if r.cancelled, !Self.controlStoppedMapReadsEmpty { throw CancellationError() }
            return (Array(r.rg), r.ms, Int(r.asked), Int(r.unheld), Array(r.nocell).map { Int($0) },
                    Array(r.sheet_field), Array(r.sheet_seam), Array(r.sheet_seam_mm))
        }
    }

    /// ★ his 11-23 ("start an animation by removing the walls ... and THEN starting the growing animation"): the same map for
    /// `s` BEFORE its lay, when every lattice region is Organic (a woven region is open whatever is laid in it); the session's
    /// domain for `s` is made now and the lay keeps it. nil when a region needs the laid cells (a cube lattice): the map then
    /// comes after the lay, as before. LatticeLayoutBridge.hpp, lattice_layout_grid_ahead.
    public func gridAhead(_ s: Settings, origin: SIMD3<Float>, voxel: Float, dims: SIMD3<Int32>) async throws
        -> (rg: [Int8], ms: Double)? {
        let sid = id
        let input = convert(s)
        return try await worker.run {
            var err = topoptbridge.BridgeError()
            let r = topoptbridge.lattice_layout_grid_ahead(sid, input, origin.x, origin.y, origin.z, voxel, dims.x, dims.y,
                                                           dims.z, &err)
            if !err.ok { throw TopOptError(message: String(err.message)) }
            return r.supported ? (Array(r.grid.rg), r.grid.ms) : nil
        }
    }

    /// The stress result a layout grades by (core's DemandField): von Mises MPa, x fastest, on a grid whose LOW CORNER is
    /// `origin`. Kept by the session until set again (one pointer between lays: core keeps the part's own reference by
    /// it), so set it once per field, never per lay. nil clears it (no stress yet).
    public func setDemand(mpa: [Float]?, nx: Int, ny: Int, nz: Int, origin: SIMD3<Double>, spacingMM: Double) async throws {
        let sid = id
        try await worker.run {
            var d = topoptbridge.LatticeLayoutDemand()
            if let mpa {
                d.mpa.reserve(mpa.count)
                for v in mpa { d.mpa.push_back(v) }
                d.origin_x = origin.x; d.origin_y = origin.y; d.origin_z = origin.z; d.spacing = spacingMM
                d.nx = Int32(nx); d.ny = Int32(ny); d.nz = Int32(nz)
            }
            var err = topoptbridge.BridgeError()
            topoptbridge.lattice_layout_set_demand(sid, d, &err)
            if !err.ok { throw TopOptError(message: String(err.message)) }
        }
    }

    /// ★ WATCH IT GROW (his 11-22: "Could the user literally *watch* the lattice grow from nothing?"): what the session's
    /// Organic lay has laid so far (core's GrowthTap, LatticeLayoutBridge.hpp's lattice_layout_growth_read).
    public struct Growth: Sendable, Equatable {
        /// Which lay (core counts them; a new lay starts again at 0). 0: none yet.
        public var lay: UInt64
        /// 0 none yet, 1 growing, 2 pruning, 3 re-seeding the bare places, 4 reaching the walls, 5 finishing.
        public var phase: Int
        /// The index to read from next time.
        public var next: Int
        /// 6 per piece: a xyz, b xyz (the part's own coordinates).
        public var xyz: [Float]
        public var region: [Int32]
        public var count: Int { region.count }
        public init(lay: UInt64, phase: Int, next: Int, xyz: [Float], region: [Int32]) {
            self.lay = lay; self.phase = phase; self.next = next; self.xyz = xyz; self.region = region
        }
    }

    /// The pieces laid from `from` on (at most `most`; 0 all), the phase and the lay's number. SYNCHRONOUS and callable from
    /// ANY thread while a lay runs: it never goes through the session's worker (the lay occupies it) and never waits on the lay.
    public func growthRead(from: Int, most: Int = 0) throws -> Growth {
        var err = topoptbridge.BridgeError()
        let r = topoptbridge.lattice_layout_growth_read(id, Int64(Swift.max(0, from)), Int64(Swift.max(0, most)), &err)
        if !err.ok { throw TopOptError(message: String(err.message)) }
        // one copy each, straight from the vectors' storage (a poll can carry tens of thousands of pieces)
        let xyzVec = r.xyz, regionVec = r.region
        let xyz: [Float] = withExtendedLifetime(xyzVec) {
            let n = Int(xyzVec.size())
            guard n > 0, let p = xyzVec.__dataUnsafe() else { return [] }
            return Array(UnsafeBufferPointer(start: p, count: n))
        }
        let region: [Int32] = withExtendedLifetime(regionVec) {
            let n = Int(regionVec.size())
            guard n > 0, let p = regionVec.__dataUnsafe() else { return [] }
            return Array(UnsafeBufferPointer(start: p, count: n))
        }
        return Growth(lay: r.lay, phase: Int(r.phase), next: Int(r.next), xyz: xyz, region: region)
    }

    /// Every layout running or waiting comes back cancelled.
    public func cancel() {
        lock.withLock { generation &+= 1 }
        topoptbridge.lattice_layout_cancel(id)
    }

    public func close() {
        let first: Bool = lock.withLock {
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        topoptbridge.lattice_layout_close(id)
        worker.stop()
    }

    func isCurrent(_ gen: UInt64) -> Bool { lock.withLock { gen == generation && !closed } }

    // MARK: conversion

    func convert(_ s: Settings) -> topoptbridge.LatticeLayoutSettings {
        var o = topoptbridge.LatticeLayoutSettings()
        o.all_lattice = s.allLattice
        o.bead_mm = s.beadMM
        o.min_strut_lines = s.minStrutLines
        o.min_wall_mm = s.minWallMM
        o.rim_mm = s.rimMM
        o.cover_mm = s.coverMM
        o.bed_floor_mm = s.bedFloorMM
        for r in s.regions {
            o.region_ids.push_back(r.id)
            o.region_no_lattice.push_back(r.noLattice ? 1 : 0)
            o.region_depth_mm.push_back(r.depthMM)
            o.region_expand_mm.push_back(r.expandMM)
            o.region_face_counts.push_back(Int32(r.faces.count))
            for f in r.faces { o.region_faces.push_back(f) }
        }
        for p in s.protect {
            o.protect_ids.push_back(p.id)
            o.protect_depth_mm.push_back(p.depthMM)
            o.protect_face_counts.push_back(Int32(p.faces.count))
            for f in p.faces { o.protect_faces.push_back(f) }
        }
        if s.protect.contains(where: \.chip) { for p in s.protect { o.protect_chip.push_back(p.chip ? 1 : 0) } }   // D23
        if s.regions.contains(where: \.weave) { for r in s.regions { o.region_weave.push_back(r.weave ? 1 : 0) } }   // Organic
        // D22: the cut pieces, the regions' first and then the skins' (the counts sent only when some piece exists)
        if s.regions.contains(where: { !$0.pieces.isEmpty }) || s.protect.contains(where: { !$0.pieces.isEmpty }) {
            for r in s.regions { o.region_piece_counts.push_back(Int32(r.pieces.count)) }
            for p in s.protect { o.protect_piece_counts.push_back(Int32(p.pieces.count)) }
            for piece in s.regions.flatMap(\.pieces) + s.protect.flatMap(\.pieces) {
                o.piece_face_counts.push_back(Int32(piece.faces.count))
                for f in piece.faces { o.piece_faces.push_back(f) }
                o.piece_cut_counts.push_back(Int32(piece.cuts.count))
                for c in piece.cuts {
                    for v in [c.point.x, c.point.y, c.point.z, c.normal.x, c.normal.y, c.normal.z, c.strict ? 1 : 0] {
                        o.piece_cuts.push_back(v)
                    }
                }
            }
        }
        // Install 2: an area's own settings, its Finish, zones (each list only when some region states one)
        if s.regions.contains(where: { $0.own.any }) { for r in s.regions { for v in r.own.wire { o.region_own.push_back(v) } } }
        if s.regions.contains(where: { $0.finish.any }) { for r in s.regions { for v in r.finish.wire { o.region_finish.push_back(v) } } }
        if s.regions.contains(where: { $0.zone != nil }) {
            for r in s.regions { for v in r.zone?.wire ?? Array(repeating: 0, count: 16) { o.region_zone.push_back(v) } }
        }
        o.by_stress = s.byStress
        o.dial_light = s.dialLight
        o.dial_heavy = s.dialHeavy
        o.width_light_mm = s.widthLightMM
        o.width_heavy_mm = s.widthHeavyMM
        o.cells_by_stress = s.cellsByStress
        o.reference_mpa = s.referenceMPa
        o.percentile = s.percentile
        o.response = s.response
        o.max_step = s.maxStep
        o.cell_search = s.cellSearch      // K7
        o.stretch_edges = s.cellSearch    // K8
        o.topology = std.string(s.topology)
        o.algorithm = std.string(s.algorithm)
        o.cell_mm = s.cellMM
        o.cell_max_mm = s.cellMaxMM
        o.cell_min_mm = s.cellMinMM
        o.min_cells_across = s.minCellsAcross
        o.grade_to_shape = s.gradeToShape
        o.band_mm = s.bandMM
        o.band_cell_mm = s.bandCellMM
        o.per_region = s.perRegion
        o.dial = s.dial
        for d in s.regionDials { o.dial_region.push_back(d.region); o.dial_value.push_back(d.dial) }
        o.strut_width_mm = s.strutWidthMM
        o.allow_quilt = s.allowQuilt
        o.strength = s.strength
        o.bars = s.bars
        o.join_loose = s.joinLoose
        o.skin = s.skin
        o.skin_width_mm = s.skinWidthMM
        o.skin_reach_cells = s.skinReachCells
        o.drop_loose = s.dropLoose
        o.small_cells_in_thin_walls = s.smallCellsInThinWalls
        o.one_grid = s.oneGrid
        o.sheet_seam = std.string(s.sheetSeam)   // ★ SHEETS
        o.auto_by_cell = s.autoByCell
        for v in s.sheetWalls { o.sheet_walls.push_back(v) }   // ★ E
        return o
    }

    static func convert(_ r: topoptbridge.LatticeLayoutResult) -> Result {
        var o = Result()
        o.bars = Array(r.bars)
        o.barEnds = Array(r.bar_ends)
        o.barFlags = Array(r.bar_flags)
        o.barRegion = Array(r.bar_region)
        o.barCell = Array(r.bar_cell)   // ★ Install 3
        o.frames = Array(r.frames)
        o.solidCubes = Array(r.solid_cubes)
        o.cellInfo = Array(r.cell_info)
        o.cellRegion = Array(r.cell_region); o.cellWall = Array(r.cell_wall)   // ★ Install 3
        o.cellFrame = Array(r.cell_frame); o.cellLo = Array(r.cell_lo); o.cellWallMM = Array(r.cell_wall_mm)
        o.solidFrame = Array(r.solid_frame)
        o.solidRegion = Array(r.solid_region)
        o.solidWhy = Array(r.solid_why)
        o.steppedEdges = Array(r.stepped_edges)
        o.steppedRegion = Array(r.stepped_region)
        o.emptyRegions = Array(r.empty_regions)
        o.cells = Int(r.cells); o.solidPieces = Int(r.solid_pieces); o.atOneLine = Int(r.at_one_line); o.atWidest = Int(r.at_widest)
        o.stubs = Int(r.stubs); o.joined = Int(r.joined); o.dropped = Int(r.dropped); o.pieces = Int(r.pieces); o.adrift = Int(r.adrift)
        o.floorCellMM = r.floor_cell_mm; o.minStrutMM = r.min_strut_mm; o.openLook = r.open_look; o.touch = r.touch
        o.bedContactMM2 = r.bed_contact_mm2 >= 0 ? r.bed_contact_mm2 : nil
        o.midairStarts = r.midair_starts >= 0 ? Int(r.midair_starts) : nil
        o.readAgain = r.read_again
        o.noStress = r.no_stress
        o.referenceMPa = r.reference_mpa; o.highestMPa = r.highest_mpa
        o.atLight = Int(r.at_light); o.atHeavy = Int(r.at_heavy)
        o.cellsByStress = r.cells_by_stress; o.cellsNoStress = r.cells_no_stress
        o.stressReferenceMPa = r.stress_reference_mpa; o.stepHeldAt = r.step_held_at
        o.thinSolid = Int(r.thin_solid)
        o.msRead = r.ms_read; o.msCells = r.ms_cells; o.msBars = r.ms_bars; o.msBridge = r.ms_bridge
        // ★ SHEETS: the contract's flat form, one field after another
        let (fields, seams) = LatticeSheetField.unflatten(
            region: Array(r.sheet_region), frame: Array(r.sheet_frame), kind: Array(r.sheet_kind), axes: Array(r.sheet_axes),
            anchor: Array(r.sheet_anchor), cellMM: Array(r.sheet_cell_mm), n: Array(r.sheet_n), lo: Array(r.sheet_lo),
            wallCount: Array(r.sheet_wall_count), wallMM: Array(r.sheet_wall_mm), wallRange: Array(r.sheet_wall_range),
            seamAB: Array(r.sheet_seam_ab), seamBandMM: Array(r.sheet_seam_band_mm), seamRaiseMM: Array(r.sheet_seam_raise_mm),
            seamSolid: Array(r.sheet_seam_solid), seamFellBack: Array(r.sheet_seam_fell_back),
            seamWhy: Array(r.sheet_seam_why).map { String($0) })
        o.sheets = fields
        o.sheetSeams = seams
        return o
    }

    /// Tests only: the worker thread (its stack size and that it is not main).
    var workerThreadForTests: Thread? { worker.thread }
    /// Tests only: holds the worker until the returned semaphore is signalled (latest-wins, made deterministic).
    func holdWorkerForTests() async -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        let worker = self.worker
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            Task { try? await worker.run { started.resume(); gate.wait() } }
        }
        return gate
    }
}

extension LatticeLayoutSession {

    /// ★ notes28 (his 11-24: all nine strut types on the new engine): what the engine knows of a strut type, asked without a
    /// part (LatticeLayoutBridge.hpp, `lattice_layout_type_facts`). `lays`: the engine lays it; else `why` is core's own
    /// words. `openLook` and `touch`: the type's two widths over its cell (core's lattice_width_bounds). The canonical cell
    /// exactly as the engine lays it: node coordinates are integers in units of cell / `s`.
    public struct TypeFacts: Sendable, Equatable {
        public var lays: Bool
        public var why: String
        public var openLook: Double, touch: Double
        public var s: Int
        /// (a, b) per strut, in units of cell / s.
        public var struts: [(SIMD3<Int32>, SIMD3<Int32>)]
        public var nodes: [SIMD3<Int32>]
        /// Core's two Structural verdicts (builder D's types.cpp), each nil or ONE plain line: Structural can never take
        /// the type (the tetragonal three); its measured strength law credits none of the engine's struts yet.
        public var structuralRefusal: String?
        public var structuralNote: String?
        /// ★ SHEETS (notes28 sheets SPEC 5): "strut" or "sheet" (core's lattice_family); a sheet's Structural floor in cells
        /// across a member (10 gyroid, 9 Schwarz-D until builder D's tables), its floor cell at two lines (mm), and Auto's
        /// largest cell (core's auto_cell_cap_mm; +infinity when none). 0 for a type the engine does not lay.
        public var family = "strut"
        public var structuralFloorCells = 0.0
        public var floorCellMM = 0.0
        public var autoCellCapMM = 0.0
        /// A sheet type the engine lays (gyroid, Schwarz-D).
        public var isSheet: Bool { lays && family == "sheet" }
        public static func == (a: TypeFacts, b: TypeFacts) -> Bool {
            a.lays == b.lays && a.why == b.why && a.openLook == b.openLook && a.touch == b.touch && a.s == b.s
                && a.structuralRefusal == b.structuralRefusal && a.structuralNote == b.structuralNote
                && a.struts.map { [$0.0, $0.1] } == b.struts.map { [$0.0, $0.1] } && a.nodes == b.nodes
                && a.family == b.family && a.structuralFloorCells == b.structuralFloorCells && a.floorCellMM == b.floorCellMM
                && a.autoCellCapMM == b.autoCellCapMM
        }
    }

    private final class FactsCache: @unchecked Sendable {
        let lock = NSLock()
        var facts: [String: TypeFacts] = [:]
    }
    private static let factsCache = FactsCache()

    /// The engine's facts for `topology` (cached: core's table never changes while the app runs). Never throws.
    public static func typeFacts(_ topology: String) -> TypeFacts {
        if let hit = factsCache.lock.withLock({ factsCache.facts[topology] }) { return hit }
        let r = topoptbridge.lattice_layout_type_facts(std.string(topology))
        let st = Array(r.struts), nd = Array(r.nodes)
        var struts: [(SIMD3<Int32>, SIMD3<Int32>)] = []
        for i in stride(from: 0, to: st.count - 5, by: 6) {
            struts.append((SIMD3(st[i], st[i + 1], st[i + 2]), SIMD3(st[i + 3], st[i + 4], st[i + 5])))
        }
        var nodes: [SIMD3<Int32>] = []
        for i in stride(from: 0, to: nd.count - 2, by: 3) { nodes.append(SIMD3(nd[i], nd[i + 1], nd[i + 2])) }
        let refusal = String(r.structural_refusal), note = String(r.structural_note)
        var f = TypeFacts(lays: r.lays, why: String(r.why), openLook: r.open_look, touch: r.touch, s: Int(r.s),
                          struts: struts, nodes: nodes, structuralRefusal: refusal.isEmpty ? nil : refusal,
                          structuralNote: note.isEmpty ? nil : note)
        f.family = String(r.family)   // ★ SHEETS
        f.structuralFloorCells = r.structural_floor_cells
        f.floorCellMM = r.floor_cell_mm
        f.autoCellCapMM = r.auto_cell_cap_mm
        factsCache.lock.withLock { factsCache.facts[topology] = f }
        return f
    }

    /// The engine lays `topology` (a strut type with its canonical cell and its two width limits in core, or a sheet).
    public static func lays(_ topology: String) -> Bool { typeFacts(topology).lays }
    /// ★ SHEETS: `topology` is a sheet type the engine lays (gyroid, Schwarz-D).
    public static func isSheet(_ topology: String) -> Bool { typeFacts(topology).isSheet }

    /// ★ SHEETS: sheet_cells.bin as core reads it (read_sheet_cells_file, its refusals): per cell its region, frame, cube,
    /// wall, cells across, margin (NaN: not judged) and flags. nil, with core's line in `why`, when refused.
    public static func sheetCells(path: String, why: inout String) -> LatticeSheetCells? {
        let r = topoptbridge.lattice_sheet_cells_read(std.string(path))
        guard r.ok else { why = String(r.why); return nil }
        return LatticeSheetCells(frames: Array(r.frames), region: Array(r.region), frame: Array(r.frame), lo: Array(r.lo),
                                 sizeMM: Array(r.size_mm), wallMM: Array(r.wall_mm), cellsAcross: Array(r.cells_across),
                                 margin: Array(r.margin), flags: Array(r.flags))
    }

    /// ★ SHEETS (tests): core's own field at points (sheet_distance_at, or sheet_wall_at with `wall`), for one field.
    public static func sheetProbe(_ f: LatticeSheetField, points: [SIMD3<Float>], wall: Bool = false) throws -> [Double] {
        var p = topoptbridge.LatticeLayoutSheetProbe()
        p.kind = f.kind.rawValue
        for v in f.axesFlat { p.axes.push_back(v) }
        for v in [f.anchor.x, f.anchor.y, f.anchor.z] { p.anchor.push_back(Float(v)) }
        p.cell_mm = Float(f.cellMM)
        for v in [f.n.x, f.n.y, f.n.z] { p.n.push_back(v) }
        for v in [f.lo.x, f.lo.y, f.lo.z] { p.lo.push_back(Float(v)) }
        for v in f.wallMM { p.wall_mm.push_back(v) }
        for q in points { p.xyz.push_back(q.x); p.xyz.push_back(q.y); p.xyz.push_back(q.z) }
        p.wall = wall
        var err = topoptbridge.BridgeError()
        let r = topoptbridge.lattice_layout_sheet_probe(p, &err)
        if !err.ok { throw TopOptError(message: String(err.message)) }
        return Array(r)
    }
}

/// One thread with its own stack, running jobs in order. Never main.
final class LatticeLayoutWorker: @unchecked Sendable {
    private let cond = NSCondition()
    private var jobs: [() -> Void] = []
    private var stopping = false
    private(set) var thread: Thread?

    init(stackSize: Int) {
        let t = Thread { [self] in self.loop() }   // the thread keeps its worker until stop() lets the loop end
        t.stackSize = stackSize
        t.name = "TopOpt lattice layout"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    private func loop() {
        while true {
            cond.lock()
            while jobs.isEmpty && !stopping { cond.wait() }
            if jobs.isEmpty && stopping { cond.unlock(); return }
            let job = jobs.removeFirst()
            cond.unlock()
            job()
        }
    }

    func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            cond.lock()
            if stopping {
                cond.unlock()
                c.resume(throwing: CancellationError())
                return
            }
            jobs.append { c.resume(with: Result { try body() }) }
            cond.signal()
            cond.unlock()
        }
    }

    /// Lets the jobs already asked finish, then ends the thread.
    func stop() {
        cond.lock()
        stopping = true
        cond.signal()
        cond.unlock()
    }
}
