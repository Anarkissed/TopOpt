// LatticeSheets — ★ SHEETS (gyroid, Schwarz-D) on the new lattice engine (notes28 sheets SPEC rev 3, section 5; builder C):
// what the Lattice page says and sends for a sheet type, in one place, pure (the page reads it; the tests drive it: hosted
// tests have no SwiftUI accessibility tree).
//   · the dial's row reads "Wall thickness" (a sheet has walls, not struts); its caption "Thinnest is two lines"; its (i) what
//     a wall is, how solid it is at this cell, how Auto picks;
//   · Auto sends core's `auto_by_cell` (SPEC 1.3: two lines up to 9.8 / 12.2 mm cells, then 0.444 of the open look);
//   · By stress shows Grade to and Grade from as for struts, as wall thicknesses;
//   · "Where regions meet: Blend / Solid wall" (his yes 11-25), shown when two sheet regions touch; Blend by default in
//     Aesthetic, Solid wall in Structural (a blend gets no strength credit); a blend that cannot print becomes the solid wall,
//     and a centred pop-up says so (never a note at the bottom-centre);
//   · greyed for a sheet, each with a caption of at most five words and an (i): Finish Skin, Grade to shape, Doubled /
//     Stepped, Cell size by stress.
// HIS RULES: a caption at most five words; detail in an (i); errors as centred plain-English pop-ups; never a face number.
import Foundation
import TopOptKit

public enum LatticeSheets {

    /// `id` is a sheet type the engine lays (core's family "sheet", through the bridge).
    public static func isSheet(_ id: String) -> Bool { LatticeLayoutSession.isSheet(id) }
    /// RED CONTROL (tests): a sheet treated as a strut type (the rows read struts, nothing greyed).
    nonisolated(unsafe) public static var controlTreatAsStrut = false
    static func sheet(_ id: String) -> Bool { !controlTreatAsStrut && isSheet(id) }

    // MARK: the dial

    /// The dial's row: "Wall thickness" for a sheet, the strut word otherwise.
    public static let wallRowTitle = "Wall thickness"
    public static func dialTitle(_ id: String, strut: String) -> String { sheet(id) ? wallRowTitle : strut }
    /// Under the row (his rule: at most five words).
    public static let thinnestCaption = "Thinnest is two lines"
    /// Grade to and Grade from, for a sheet: wall thicknesses (the struts' "density").
    public static let gradeUnitWord = "wall"
    public static func gradeUnit(_ id: String) -> String { sheet(id) ? gradeUnitWord : "density" }
    /// Manual's two ends in mm under By stress (the struts' "Strut width"), for a sheet.
    public static let rangeTitle = "Wall thickness range"
    public static let rangeInfo = "The thinnest wall, where the stress is nothing, and the thickest, at the target stress, in mm. "
        + "Auto takes them from Grade to and Grade from. The wall changes smoothly from cell to cell, never in a step. "
        + "Tap Set, then drag or tap a number to type it."

    /// Auto's wall for a sheet cell (core's sheet_auto_wall_mm, SPEC 1.3): the larger of two lines and 0.444 of the open look
    /// × the cell. Shown in the (i); the engine lays it (`auto_by_cell`).
    public static func autoWallMM(_ id: String, cellMM: Double, lineWidthMM lineMM: Double) -> Double {
        let f = LatticeLayoutSession.typeFacts(id)
        guard f.isSheet else { return 0 }
        return Swift.max(2 * lineMM, (0.44 / 0.99) * f.openLook * cellMM)
    }
    /// How solid a sheet is at a wall in a cell, per cent (core's own law). 0 when core has none.
    public static func percentSolid(_ id: String, wallMM: Double, cellMM: Double) -> Int {
        guard let k = LatticeSheetField.Kind(id: id) else { return 0 }
        return Int((100 * LatticeLayoutColours.sheetDensity(k, wallMM: wallMM, cellMM: cellMM)).rounded())
    }

    /// The (i): what a wall is, how solid it is at this cell, how Auto picks.
    public static func wallInfo(_ id: String, cellMM: Double, lineWidthMM lineMM: Double) -> String {
        let name = LatticeType.displayName(forID: id)
        let wall = autoWallMM(id, cellMM: cellMM, lineWidthMM: lineMM)
        func mm(_ v: Double) -> String { String(format: "%.2f", v) }
        var s = "\(name) is one continuous curved wall, not struts. Its thickness is the wall's, measured straight through it. "
            + "The thinnest wall prints as two lines side by side (\(mm(2 * lineMM)) mm)."
        if cellMM > 0, wall > 0 {
            s += " At a \(mm(cellMM)) mm cell, Auto's wall is \(mm(wall)) mm: about "
                + "\(percentSolid(id, wallMM: wall, cellMM: cellMM)) % solid."
        }
        s += " Auto keeps small cells at the thinnest wall, so they stay open; in larger cells the wall grows with the cell, "
            + "so the lattice keeps one look."
        return s
    }

    /// Auto sends core's `auto_by_cell` for a sheet (SPEC 1.3); a hand-set dial does not (R10 as it is).
    public static func autoByCell(_ l: LatticeSettings, pageManual: Bool) -> Bool { !pageManual && sheet(l.topologyID) }

    // MARK: "Where regions meet" (SPEC 1.5, his yes 11-25)

    public static let seamTitle = "Where regions meet"
    public static let seamCaption = "How two lattices join"
    public static let seamChoices = ["Blend", "Solid wall"]
    /// core's words for the two choices (the job's "sheet_seam")
    public static let blend = "blend", solidWall = "solid_wall"
    /// The stage's default: Blend in Aesthetic, Solid wall in Structural (a blend gets no strength credit).
    public static func seamDefault(structural: Bool) -> String { structural ? solidWall : blend }
    /// What the part sends: his pick, else the stage's default.
    public static func seam(_ l: LatticeSettings) -> String {
        if let s = l.sheetSeam, s == blend || s == solidWall { return s }
        return seamDefault(structural: (l.stageMode ?? .structural) == .structural)
    }
    public static func seamIndex(_ l: LatticeSettings) -> Int { seam(l) == blend ? 0 : 1 }
    /// The row shows when the part has two or more sheet regions that touch (the laid seams).
    public static func seamRowShown(_ id: String, seams: [LatticeSheetSeam]) -> Bool { sheet(id) && !seams.isEmpty }
    public static func seamInfo(structural: Bool) -> String {
        "Blend grades one lattice into the other over about a cell; that band gets no strength credit. Solid wall is a wall "
            + "two lines thick between them, checked as solid. A blend that can't print becomes a solid wall, and the app "
            + "says so. Where a sheet meets struts or Organic, it is always a solid wall."
            + (structural ? " In Structural a blend reads weaker than the solid wall, so Solid wall is the default here."
                          : "")
    }

    /// The pop-up when a print file's blend fell back to the solid wall (`sayFellBack`).
    public static let fellBackTitle = "A blend became a solid wall"

    // MARK: greyed for a sheet

    public enum Greyed: String, CaseIterable, Sendable {
        case finishSkin, gradeToShape, doubledStepped, cellSizeByStress
        /// Under the greyed control (his rule: at most five words).
        public var caption: String {
            switch self {
            case .finishSkin: return "Not for sheet types"
            case .gradeToShape, .doubledStepped, .cellSizeByStress: return "One cell size per region"
            }
        }
        /// Its (i).
        public var info: String {
            switch self {
            case .finishSkin:
                return "Skin weaves bars over the surface to join the cut ends of struts. A sheet has no strut ends: its wall "
                    + "runs into the solid and joins it there. Rim and Covered work as they do for struts."
            case .gradeToShape:
                return "A sheet is one continuous wall, so its cells can't shrink toward an outline: a change of cell size "
                    + "would leave the walls unjoined. Each region keeps one cell size; the walls are cut by the part's faces."
            case .doubledStepped:
                return "Doubled and Stepped change the cell size across a region. A sheet keeps one cell size per region, "
                    + "so its walls stay joined everywhere."
            case .cellSizeByStress:
                return "A sheet keeps one cell size per region, so its walls stay joined. By stress still thickens the walls "
                    + "where the stress is high."
            }
        }
    }
    /// The controls greyed for `id` (empty for a strut type).
    public static func greyed(_ id: String) -> [Greyed] { sheet(id) ? Greyed.allCases : [] }
}

/// ★ SHEETS, builder E (SPEC 1.5, "a fallen-back seam draws as the solid wall"): per part, the seams its last print file
/// made solid walls (two region ids each, the job's ids), set when a print file lands (LatticeSheets.sayFellBack: a file that
/// blended every seam clears it). The preview lays them as the solid wall (core's Settings::sheet_walls), so the drawing
/// follows the print file. A shared holder, read off the main thread too: no page needs a new @State.
public final class LatticeSheetsFellBack: @unchecked Sendable {
    public static let shared = LatticeSheetsFellBack()
    private let lock = NSLock()
    private var walls: [UUID: [Int32]] = [:]
    public func set(_ pairs: [[Int]], for project: UUID) {
        let flat = pairs.filter { $0.count == 2 }.flatMap { $0.map(Int32.init) }
        lock.withLock { walls[project] = flat.isEmpty ? nil : flat }
    }
    /// Two region ids per seam, flat (empty: none).
    public func walls(for project: UUID) -> [Int32] { lock.withLock { walls[project] ?? [] } }
}

/// ★ SHEETS: the sheet seams the last lay laid on the part the page shows (the preview sets it), so the Lattice page knows
/// when two sheet regions touch ("Where regions meet" shows only then). A shared holder, so no page needs a new @State.
@MainActor public final class LatticeSheetsLaid: ObservableObject {
    public static let shared = LatticeSheetsLaid()
    @Published public private(set) var seams: [LatticeSheetSeam] = []
    @Published public private(set) var path: String?
    public func set(_ seams: [LatticeSheetSeam], path: String?) {
        if self.seams != seams { self.seams = seams }
        if self.path != path { self.path = path }
    }
    /// The seams laid on the part at `path` (none for another part).
    public func seams(for path: String?) -> [LatticeSheetSeam] { path != nil && path == self.path ? seams : [] }
}
