// LatticeLayoutPreview+Sheets — ★ SHEETS on the new engine's preview (notes28 sheets SPEC rev 3, section 5; builder C): a sheet
// lay's fields handed to the bars pass's sheet pass (LatticeLayoutSheetPass), the engine's map with each voxel's region, the
// tap-to-read card on a wall, and the print file's seam that fell back to the solid wall said in the centred pop-up.
import Foundation
import simd
import TopOptKit

extension LatticeLayoutPreview {

    /// The sheet pass's inputs for a lay: its fields and seams; the last lay's map (and regions) stay until this lay's lands.
    static func sheetDrawing(_ r: LatticeLayoutSession.Result, token: Int, lastMap: LatticeSheetDrawing?) -> LatticeSheetDrawing {
        var d = LatticeSheetDrawing(token: token, fields: r.sheets, seams: r.sheetSeams, map: lastMap?.map)
        d.regions = lastMap?.regions.flatMap { r.sheets.count > 1 ? $0 : nil }
        let cellSize = stride(from: 0, to: r.cellInfo.count, by: 5).map { r.cellInfo[$0] }
        if let b = LatticeSheetDrawing.box(frames: r.frames, cellFrame: r.cellFrame, cellLo: r.cellLo, cellSize: cellSize, pad: 1) {
            d.boxLo = b.lo; d.boxHi = b.hi
        }
        return d
    }

    /// Which field holds each voxel of the map (two or more sheet regions), worked out off the main thread.
    static func sheetRegions(_ fields: [LatticeSheetField], map: LatticeLayoutSolidGrid,
                             laid: LatticeLayoutColours.Laid) async -> [UInt8] {
        let frames = laid.frames, region = laid.cellRegion, frame = laid.cellFrame, lo = laid.cellLo
        let size = stride(from: 0, to: laid.cellInfo.count, by: 5).map { laid.cellInfo[$0] }
        return await Task.detached(priority: .userInitiated) {
            LatticeSheetDrawing.regionIndex(fields: fields, map: map, frames: frames, cellRegion: region, cellFrame: frame,
                                            cellLo: lo, cellSize: size)
        }.value
    }

    /// ★ The tap-to-read card on a sheet: the wall at the tap (its region's field, read where the layout laid it), its cell,
    /// how solid it is there — the numbers its colour was made from.
    static func readSheet(_ laid: LatticeLayoutColours.Laid, at p: SIMD3<Float>,
                          lookup: LatticeLayoutColours.CellLookup?) -> Reading? {
        guard let first = laid.sheets.first else { return nil }
        var field = first
        if laid.sheets.count > 1, let c = lookup?.cell(at: p), c < laid.cellRegion.count,
           let f = laid.sheets.first(where: { $0.region == laid.cellRegion[c] }) {
            field = f
        }
        let wall = field.wallAt(SIMD3<Double>(p))
        return Reading(cellMM: field.cellMM, widthMM: wall,
                       density: LatticeLayoutColours.sheetDensity(field.kind, wallMM: wall, cellMM: field.cellMM),
                       klass: .interior)
    }
}

extension LatticeSheets {
    /// A print file's seams (lattice_file.json's "sheet_seams", top level or in its `layout`): the two regions (the job's ids;
    /// 0 the whole part), the seam asked, whether a blend fell back to the solid wall, and core's line (the log only: it may
    /// name regions by number).
    struct FileSeam: Equatable, Sendable {
        var regions: [Int]
        var seam: String
        var fellBack: Bool
        var why: String
    }
    nonisolated static func fileSeams(report: Data?) -> [FileSeam] {
        guard let d = report, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [] }
        let list = (o["sheet_seams"] ?? (o["layout"] as? [String: Any])?["sheet_seams"]) as? [[String: Any]] ?? []
        return list.map { e in
            FileSeam(regions: (e["regions"] as? [Int]) ?? [], seam: e["seam"] as? String ?? "",
                     fellBack: e["fell_back"] as? Bool ?? false, why: e["why"] as? String ?? "")
        }
    }
    /// The pop-up's text: each seam that fell back, its two regions named his way (`name`: his group's name, or "The part" —
    /// never a number), and that a solid wall joins them. nil: none fell back.
    nonisolated static func fellBackText(_ seams: [FileSeam], name: (Int) -> String) -> String? {
        let fell = seams.filter(\.fellBack)
        guard !fell.isEmpty else { return nil }
        return fell.map { s in
            let names = s.regions.map(name)
            let who = names.count == 2 ? "\(names[0]) and \(names[1])" : (names.first ?? "Two lattices")
            // ★ notes30 M1 (his rule: positive words on screen): what was made, and why
            return "\(who): a solid wall joins them there, where a blend would print too thin."
        }.joined(separator: "\n")
    }
    /// Raises the centred pop-up for a landed print file whose blend fell back to the solid wall. True: it said something.
    /// ★ builder E: every landed print file also tells the preview which seams it made solid walls (none: it clears them), so
    /// the preview draws the wall the file printed.
    @MainActor @discardableResult
    static func sayFellBack(report: Data?, in p: ProjectModel) -> Bool {
        let seams = fileSeams(report: report)
        if report != nil { LatticeSheetsFellBack.shared.set(seams.filter(\.fellBack).map(\.regions), for: p.id) }
        guard let text = fellBackText(seams, name: { LatticeCannotLattice.regionName($0, in: p) }) else { return false }
        AppPopups.shared.show(fellBackTitle, text, log: seams.filter(\.fellBack).map(\.why).joined(separator: " | "))
        return true
    }
}
