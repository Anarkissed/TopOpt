// LatticeFileExport — the EXPORT button (his go 2026-11-13): the print file, made on the Mac from the SAME layout the new engine's
// preview draws (contract: docs/design/lattice-rebuild/04-layout-file-job.md). The app sends the model (with its painted-faces
// sidecar, as every job does) and a `lattice_file` job whose `layout` is the preview's own settings under the bridge's names; the
// worker runs `topopt-cli lattice-file`; the app fetches `lattice.stl` and `lattice_file.json` and offers the file to save or share.
// Shown only with "New engine (test)" on, on Lattice Setup, above the preview's lines.
import Foundation
import SwiftUI
import TopOptKit
import TopOptDesign

// MARK: the job

public enum LatticeFileJob {
    public static let outputName = "lattice.stl"
    public static let reportName = "lattice_file.json"

    /// Every field of the preview's settings, by its Swift name → its key in the job's `layout` (the bridge's names). The test
    /// holds this table to `Settings` itself, so a setting added later can never be left out of the file silently.
    public static let fieldKeys: [String: String] = [
        "allLattice": "all_lattice", "beadMM": "bead_mm", "minStrutLines": "min_strut_lines", "minWallMM": "min_wall_mm",
        "rimMM": "rim_mm", "coverMM": "cover_mm", "regions": "region_*", "protect": "protect_*", "topology": "topology",
        "algorithm": "algorithm", "cellMM": "cell_mm", "cellMaxMM": "cell_max_mm", "cellMinMM": "cell_min_mm",
        "minCellsAcross": "min_cells_across", "gradeToShape": "grade_to_shape", "bandMM": "band_mm", "bandCellMM": "band_cell_mm",
        "perRegion": "per_region", "dial": "dial", "regionDials": "dial_region/dial_value", "strutWidthMM": "strut_width_mm",
        "allowQuilt": "allow_quilt", "strength": "strength", "bars": "bars", "joinLoose": "join_loose", "skin": "skin",
        "skinWidthMM": "skin_width_mm", "skinReachCells": "skin_reach_cells", "dropLoose": "drop_loose",
        "smallCellsInThinWalls": "small_cells_in_thin_walls", "oneGrid": "one_grid",
        "byStress": "by_stress", "dialLight": "dial_light", "dialHeavy": "dial_heavy", "widthLightMM": "width_light_mm",
        "widthHeavyMM": "width_heavy_mm", "cellsByStress": "cells_by_stress", "referenceMPa": "reference_mpa",
        "percentile": "percentile", "response": "response", "maxStep": "max_step",
        "bedFloorMM": "organic_bed_floor_mm",   // the flat floor (Organic only; written only when on)
    ]

    /// The stress result's name beside the job (core's top-level "demand"; the demand file format of 04-layout-file-job.md).
    public static let demandName = "demand.bin"

    /// ★ Install 3, the strength check (LatticeReview's shape, 11-17): beside the job, the run job a Lattice run writes today
    /// (`lattice_part`: loads, supports, material, safety margin, build direction, voxel size), named by the job's
    /// `strength_job`. Absent = no check and no block (rule V2); Aesthetic never sends it (U9); Organic never reaches here.
    public static let strengthJobName = "strength_job.json"
    /// ★ Whether the core the app and the Mac run reads `strength_job`: ON since LatticeReview's Install 3 core
    /// (claude/install3-engine @ 61ac4291) is merged and vendored — the app and the Mac's worker go out together (a core that
    /// does not know the key refuses the whole job, so the worker must be this core's: the fingerprint check stops any other).
    public static let strengthWired = true
    /// Whether a part's print file carries the strength check: Structural only (U9), on a core that reads it.
    public static func checksStrength(_ l: LatticeSettings, wired: Bool = strengthWired) -> Bool {
        // ★ Organic cut 2 (OS2): the check now judges an Organic lattice too (a frame of beams); Aesthetic never (U9)
        wired && (l.stageMode ?? .structural) == .structural
    }

    /// The stress result as core reads it (04-layout-file-job.md, the demand file): "TODEMAND", int32 version 1, int32 nx ny
    /// nz, float64 origin xyz (the grid's LOW CORNER), float64 spacing, then nx*ny*nz float32 von Mises MPa, x fastest;
    /// little-endian.
    public static func demandFile(_ f: LatticeDemandField) -> Data {
        var d = Data("TODEMAND".utf8)
        func i32(_ v: Int) { var x = Int32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func f64(_ v: Double) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 8)) }
        i32(1); i32(f.nx); i32(f.ny); i32(f.nz)
        f64(f.origin.x); f64(f.origin.y); f64(f.origin.z); f64(f.spacingMM)
        d.reserveCapacity(d.count + 4 * f.vonMises.count)
        for v in f.vonMises { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        return d
    }

    /// Whether the job needs the stress result: By stress or cell size by stress, for the part or for any area.
    public static func needsStress(_ s: LatticeLayoutSession.Settings) -> Bool {
        s.byStress || s.cellsByStress || s.regions.contains { $0.own.byStress == true || $0.own.cellsByStress == true }
    }

    /// One part's job, as Export and the Lattice button send it: the preview's own settings, the stress result when the
    /// settings grade by stress, and the strength check's run job when given.
    public struct ForPart {
        public var json: Data
        public var modelPath: String
        public var demand: Data?
        /// ★ Organic cut 2: the stress the weave follows (core's TOTENSOR file), sent beside the job as its `tensor`.
        public var tensor: Data? = nil
    }

    /// ★ Organic cut 2: the stress file's name beside the job (core's top-level `tensor`).
    public static let tensorName = "tensor.bin"
    /// ★ Organic cut 2 (handover OF4: the file is separate closed tubes): what the slicer must be told.
    public static let supportsOffLine = "Slice it with supports off"

    /// ★ Organic cut 2 (organic-cut2-handover.md, f): an Organic part's job — the preview's own settings and the SAME groups the
    /// preview laid (so the file is the lattice drawn), the stress it followed, and the strength check's run job when given
    /// (Structural). The file is a 3MF of separate closed tubes.
    @MainActor
    public static func forOrganic(_ p: ProjectModel, groups: [LatticeLayoutSession.OrganicGroup], tensor: Data,
                                  referenceMPa: Double, strengthJob: Data?) -> Result<ForPart, NoJob> {
        guard let path = p.importedFile?.path else { return .failure(NoJob(line: LatticeLayoutPreview.noPartLine)) }
        guard !groups.isEmpty else { return .failure(NoJob(line: LatticeFileExport.organicNoLayLine)) }
        let settings = LatticeLayoutPreview.settings(p, referenceMPa: referenceMPa)
        guard let json = try? build(settings, modelName: (path as NSString).lastPathComponent,
                                    strengthJob: strengthJob == nil ? nil : strengthJobName, organic: groups,
                                    tensor: tensorName) else {
            return .failure(NoJob(line: "The job could not be written"))
        }
        return .success(ForPart(json: json, modelPath: path, demand: nil, tensor: tensor))
    }

    /// ★ Organic cut 2: one Organic ask under the lattice file job's keys (core's file_job.cpp `organic_from`; the
    /// preview's `raw` sends the same fields to the session). The flat floor rides the layout's own `organic_bed_floor_mm`.
    public static func organicKeys(_ o: LatticeLayoutSession.Organic) -> [String: Any] {
        var d: [String: Any] = [
            "organic_mode": o.mode == .grown ? "grown" : "traced",
            "organic_width_mm": o.widthMM, "organic_width_heavy_mm": o.widthHeavyMM,
            "organic_follow_stress": o.followStress, "organic_shape_fit": o.shapeFit, "organic_member_cap": o.memberCap,
            "organic_shape_reach": o.shapeReach, "organic_walls_out": o.wallsOut, "organic_ties": o.ties,
            "organic_tie_swirl": o.tieSwirl, "organic_foot_gap": o.footGap, "organic_stress_goal": o.stressGoal,
            "organic_void_ratio": o.voidRatio, "organic_reseed_rounds": Int(o.reseedRounds),
            "organic_wall_connect": o.wallConnect, "organic_wall_gap": o.wallGap, "organic_wall_gap_heavy": o.wallGapHeavy,
            "organic_wall_cross": Int(o.wallCross), "organic_cross_gap": o.crossGap, "organic_cross_gap_heavy": o.crossGapHeavy,
            "organic_cross_climb_max_deg": o.crossClimbMaxDeg, "organic_top_run": o.topRun, "organic_root_run": o.rootRun,
            "organic_run_max": Int(o.runMax), "organic_run_gap": o.runGap, "organic_run_follow": o.runFollow,
            "organic_run_pull": o.runPull, "organic_run_seek": o.runSeek, "organic_run_min": o.runMin,
            "organic_root_gap": o.rootGap, "organic_auto": o.autoByStress, "organic_prune": o.prune,
            "organic_hold_parts": o.holdParts, "organic_part_reach_mm": o.partReachMM,
            "organic_part_support_mm": o.partSupportMM, "organic_part_to_floor": o.partToFloor,
            "organic_link_width": o.linkWidth, "organic_unbraced_max": o.unbracedMax, "organic_tie_level": o.tieLevel,
            "organic_tie_gap": o.tieGap, "organic_tie_gap_heavy": o.tieGapHeavy,
            // cut 2 (handover a)
            "organic_gap_lines": o.gapLines, "organic_face_relief_mm": o.faceReliefMM,
            "organic_relief_exclude_faces": o.reliefExcludeFaces.map { Int($0) }, "organic_strand_keep": o.strandKeep,
            "organic_wall_bare_mm": o.wallBareMM, "organic_wall_reach": o.wallReach, "organic_sweep": o.sweep ? 1 : 0,
        ]
        // the spacing: one size, or the range (core refuses both together)
        if o.spacingMM > 0 {
            d["organic_spacing_mm"] = o.spacingMM
        } else {
            d["organic_spacing_min_mm"] = o.spacingMinMM
            d["organic_spacing_max_mm"] = o.spacingMaxMM
            d["organic_spacing_exponent"] = o.spacingExponent
        }
        return d
    }
    /// Why a part's job cannot be written, in its one line.
    public struct NoJob: Error, Equatable { public let line: String }

    @MainActor
    public static func forPart(_ p: ProjectModel, stress: LatticeLayoutPreview.Stress, strengthJob: Data?) -> Result<ForPart, NoJob> {
        guard let path = p.importedFile?.path else { return .failure(NoJob(line: LatticeLayoutPreview.noPartLine)) }
        let settings = LatticeLayoutPreview.settings(p, referenceMPa: stress.referenceMPa)
        let needs = needsStress(settings)
        var demand: Data?
        if needs {
            guard let f = stress.field else { return .failure(NoJob(line: LatticeFileExport.noStressLine)) }
            demand = demandFile(f)
        }
        guard let json = try? build(settings, modelName: (path as NSString).lastPathComponent, demand: needs ? demandName : nil,
                                    strengthJob: strengthJob == nil ? nil : strengthJobName) else {
            return .failure(NoJob(line: "The job could not be written"))
        }
        return .success(ForPart(json: json, modelPath: path, demand: demand))
    }

    /// The job document, keys sorted (the same settings give the same bytes).
    public static func build(_ s: LatticeLayoutSession.Settings, modelName: String, linearDeflection: Double = 0,
                             demand: String? = nil, strengthJob: String? = nil,
                             organic: [LatticeLayoutSession.OrganicGroup]? = nil, tensor: String? = nil) throws -> Data {
        var layout: [String: Any] = [
            "all_lattice": s.allLattice, "bead_mm": s.beadMM, "min_strut_lines": s.minStrutLines, "min_wall_mm": s.minWallMM,
            "rim_mm": s.rimMM, "cover_mm": s.coverMM,
            "region_ids": s.regions.map { Int($0.id) }, "region_no_lattice": s.regions.map { $0.noLattice ? 1 : 0 },
            "region_depth_mm": s.regions.map(\.depthMM), "region_expand_mm": s.regions.map(\.expandMM),
            "region_face_counts": s.regions.map { $0.faces.count }, "region_faces": s.regions.flatMap { $0.faces.map { Int($0) } },
            "protect_ids": s.protect.map { Int($0.id) }, "protect_depth_mm": s.protect.map(\.depthMM),
            "protect_face_counts": s.protect.map { $0.faces.count }, "protect_faces": s.protect.flatMap { $0.faces.map { Int($0) } },
            "topology": s.topology, "algorithm": s.algorithm, "cell_mm": s.cellMM, "cell_max_mm": s.cellMaxMM,
            "cell_min_mm": s.cellMinMM, "min_cells_across": Int(s.minCellsAcross), "grade_to_shape": s.gradeToShape,
            "band_mm": s.bandMM, "band_cell_mm": s.bandCellMM, "per_region": s.perRegion, "dial": s.dial,
            "dial_region": s.regionDials.map { Int($0.region) }, "dial_value": s.regionDials.map(\.dial),
            "strut_width_mm": s.strutWidthMM, "allow_quilt": s.allowQuilt, "strength": s.strength,
            "small_cells_in_thin_walls": s.smallCellsInThinWalls, "one_grid": s.oneGrid,
            "bars": true,   // a file needs its struts (the job refuses false)
            "join_loose": s.joinLoose, "skin": s.skin, "skin_width_mm": s.skinWidthMM, "skin_reach_cells": s.skinReachCells,
            "drop_loose": s.dropLoose,
        ]
        // ★ his ask 11-14 (D22): the cut pieces, as the preview lays them; the lists only when some piece exists, so a job with
        // none is the bytes it was
        func pieces(_ ps: [LatticeLayoutSession.Piece]) -> Any {
            ps.isEmpty ? NSNull() : ps.map { pc -> [String: Any] in
                ["faces": pc.faces.map { Int($0) },
                 "cuts": pc.cuts.map { c -> [String: Any] in
                     ["point": [c.point.x, c.point.y, c.point.z], "normal": [c.normal.x, c.normal.y, c.normal.z], "strict": c.strict]
                 }]
            }
        }
        if s.regions.contains(where: { !$0.pieces.isEmpty }) { layout["region_pieces"] = s.regions.map { pieces($0.pieces) } }
        if s.protect.contains(where: { !$0.pieces.isEmpty }) { layout["protect_pieces"] = s.protect.map { pieces($0.pieces) } }
        // ★ D23: a chip's answer "Solid" (only when some skin is one, so a job with none is the bytes it was)
        if s.protect.contains(where: \.chip) { layout["protect_chip"] = s.protect.map { $0.chip ? 1 : 0 } }
        // Install 2: the stress keys, cell size by stress and the size step (core's defaults are the job's bytes as before
        // only by value: the keys are always written, as every other layout key is)
        layout["by_stress"] = s.byStress
        layout["dial_light"] = s.dialLight
        layout["dial_heavy"] = s.dialHeavy
        layout["width_light_mm"] = s.widthLightMM
        layout["width_heavy_mm"] = s.widthHeavyMM
        layout["cells_by_stress"] = s.cellsByStress
        layout["reference_mpa"] = s.referenceMPa
        layout["percentile"] = s.percentile
        layout["response"] = s.response
        layout["max_step"] = s.maxStep
        // the flat floor (K1): Organic's ask; written only when on, so every other job is the bytes it was
        if s.bedFloorMM > 0 { layout["organic_bed_floor_mm"] = s.bedFloorMM }
        if s.byStress { layout["per_region"] = false }   // core refuses By stress with Per region
        // an area's own settings (C23), its Finish (S13), zones (D21): one entry per region, null where it states nothing
        func own(_ o: LatticeLayoutSession.AreaOwn) -> Any {
            guard o.any else { return NSNull() }
            var d: [String: Any] = [:]
            if let v = o.algorithm { d["algorithm"] = v }
            if let v = o.cellMM { d["cell_mm"] = v }
            if let v = o.cellMaxMM { d["cell_max_mm"] = v }
            if let v = o.cellMinMM { d["cell_min_mm"] = v }
            if let v = o.minCellsAcross { d["min_cells_across"] = Int(v) }
            if let v = o.gradeToShape { d["grade_to_shape"] = v }
            if let v = o.bandMM { d["band_mm"] = v }
            if let v = o.bandCellMM { d["band_cell_mm"] = v }
            if let v = o.cellsByStress { d["cells_by_stress"] = v }
            if let v = o.byStress { d["by_stress"] = v }
            if let v = o.dial { d["dial"] = v }
            if let v = o.dialLight { d["dial_light"] = v }
            if let v = o.dialHeavy { d["dial_heavy"] = v }
            if let v = o.widthMM { d["strut_width_mm"] = v }
            if let v = o.widthLightMM { d["width_light_mm"] = v }
            if let v = o.widthHeavyMM { d["width_heavy_mm"] = v }
            if let v = o.strength { d["strength"] = v }
            if let v = o.response { d["response"] = v }
            if let v = o.referenceMPa { d["reference_mpa"] = v }
            if let v = o.maxStep { d["max_step"] = v }
            return d
        }
        func finish(_ f: LatticeLayoutSession.RegionFinish) -> Any {
            guard f.any else { return NSNull() }
            var d: [String: Any] = [:]
            if let v = f.rimMM { d["rim_mm"] = v }
            if let v = f.coverMM { d["cover_mm"] = v }
            if let v = f.skin { d["skin"] = v }
            if let v = f.skinWidthMM { d["skin_width_mm"] = v }
            if let v = f.skinReachCells { d["skin_reach_cells"] = v }
            if let v = f.skinDensity { d["skin_density"] = v }   // ★ cut 2 (OJ8)
            if let v = f.skinSink { d["skin_sink"] = v }
            return d
        }
        func zone(_ z: LatticeLayoutSession.Zone?) -> Any {
            guard let z else { return NSNull() }
            let v3 = { (v: SIMD3<Double>) -> [Double] in [v.x, v.y, v.z] }
            switch z.kind {
            case .box: return ["kind": "box", "centre": v3(z.centre), "axes": z.axes.map(v3), "half_mm": v3(z.half)]
            case .cylinder: return ["kind": "cylinder", "centre": v3(z.centre), "axis": v3(z.axes.count > 2 ? z.axes[2] : .zero),
                                    "radius_mm": z.half.x, "half_length_mm": z.half.z]
            }
        }
        if s.regions.contains(where: { $0.own.any }) { layout["region_own"] = s.regions.map { own($0.own) } }
        if s.regions.contains(where: { $0.finish.any }) { layout["region_finish"] = s.regions.map { finish($0.finish) } }
        if s.regions.contains(where: { $0.zone != nil }) { layout["region_zones"] = s.regions.map { zone($0.zone) } }
        // ★ Organic cut 2 (handover a, f): the woven areas, the first group's settings over the layout, every group's own in
        // organic_groups when there are several (core lays each group by its own); the stress beside the job; a 3MF
        var top: [String: Any] = [:]
        if let organic, let first = organic.first {
            layout["region_weave"] = s.regions.map(\.weave)
            for (k, v) in organicKeys(first.ask) { layout[k] = v }
            // the weave's stress reference is the ASK's (the preview lays with it: 0 = the percentile of the weave's own
            // stress); the layout's own reference is the cell lattice's and would lay a different lattice
            layout["reference_mpa"] = first.ask.referenceMPa
            layout["percentile"] = first.ask.percentile
            if organic.count > 1 {
                layout["organic_groups"] = organic.map { g -> [String: Any] in
                    var d = organicKeys(g.ask)
                    d["regions"] = g.regions.map { Int($0) }
                    return d
                }
            }
            if let tensor { top["tensor"] = tensor }
            top["file_format"] = "3mf"
        }
        var job: [String: Any] = ["mode": "lattice_file", "model": modelName, "output": outputName,
                                  "linear_deflection": linearDeflection, "threads": 0, "layout": layout]
        for (k, v) in top { job[k] = v }
        if let demand { job["demand"] = demand }
        if let strengthJob { job["strength_job"] = strengthJob }   // ★ Install 3
        return try JSONSerialization.data(withJSONObject: job, options: [.sortedKeys])
    }
}

/// What `lattice_file.json` says, in the few numbers the app shows.
public struct LatticeFileReport: Equatable, Sendable {
    public var ok: Bool
    public var why: String
    public var bars: Int
    public var plasticMM3: Double
    public var partMM3: Double
    public var clean: Bool
    public var posts: Int
    /// ★ Install 3: the strength check's result, when it ran (Structural).
    public var strength: LatticeFileStrength? = nil
    /// ★ Organic cut 2 (OF5): the file written (its bare name: lattice.3mf for an Organic part), and the slicer's word on
    /// supports ("off" for separate tubes), as lattice_file.json gives them.
    public var file: String? = nil
    public var slicerSupports: String? = nil

    public static func parse(_ d: Data) -> LatticeFileReport? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        let l = o["layout"] as? [String: Any] ?? [:], m = o["mesh"] as? [String: Any] ?? [:]
        let p = o["print_check"] as? [String: Any] ?? [:]
        let file = (o["file"] as? String).flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent }
        return LatticeFileReport(ok: o["ok"] as? Bool ?? false, why: o["why"] as? String ?? "", bars: l["bars"] as? Int ?? 0,
                                 plasticMM3: m["mm3"] as? Double ?? 0, partMM3: m["part_mm3"] as? Double ?? 0,
                                 clean: p["clean"] as? Bool ?? false, posts: (p["posts"] as? [Any])?.count ?? 0,
                                 strength: (o["strength"] as? [String: Any]).map(LatticeFileStrength.init(block:)),
                                 file: file, slicerSupports: o["slicer_supports"] as? String)
    }

    /// The file's name: the one the report gives (a 3MF for Organic), else the job's own output.
    public var fileName: String { file ?? LatticeFileJob.outputName }
    public var isThreeMF: Bool { fileName.lowercased().hasSuffix(".3mf") }

    /// One plain line: what was made.
    public var line: String {
        let share = partMM3 > 0 ? String(format: " · %.0f%% of the solid part", 100 * plasticMM3 / partMM3) : ""
        let supports = slicerSupports == "off" ? " · " + LatticeFileJob.supportsOffLine.lowercased() : ""
        return "Print file ready · \(bars) bars\(share)\(clean ? " · layer check clean" : "")\(supports)"
    }
}

/// ★ Install 3: `lattice_file.json`'s `strength` block (LatticeReview's shape, 11-17: the old check fed from the new layout, the
/// old receipt's names without their prefix), the few numbers the app shows, and its one line.
public struct LatticeFileStrength: Equatable, Sendable {
    public var accepted: Bool
    public var marginWorstCase: Double
    public var safetyMargin: Double
    public var notCertified: Bool
    public var notCertifiedReason: String
    public var massGrams: Double
    public var maxEffectiveVonMisesMPa: Double
    public var marginInPlane: Double
    public var marginInterlayer: Double
    /// The check's own solve, beside the report (the stress and deflection views), or nil.
    public var fields: String?
    /// ★ Each load scenario's own views, beside the report, or nil (one scenario).
    public var scenarioFields: String?
    public var maxInterlayerTensionMPa: Double
    /// The build direction the check judged the layers along, or nil.
    public var buildDirection: SIMD3<Double>?
    /// Why it gated as it did (core's own object), when not accepted.
    public var diagnosis: GateDiagnosis?

    /// ★ HIS RULING 11-17 ("Yes, but only in the structural lattice stage"): the struts must pass too. Three states, the file
    /// made in all three: pass = the solid and the struts keep the safety margin; solid only = the solid does, the struts do
    /// not; fail = the solid does not (`accepted` keeps the old gate's meaning).
    public enum Verdict: String, Sendable { case pass, solidOnly = "solid_only", fail }
    /// The `verdict` core sent, or nil (a core from before the ruling).
    public var verdictSent: Verdict?
    /// The three states; a core from before the ruling: the old gate's word alone.
    public var verdict: Verdict { verdictSent ?? (accepted ? .pass : .fail) }
    /// The type has a strut rule and its struts keep the safety margin (`struts_pass`).
    public var strutsPass: Bool
    /// The struts' own worst-case margin (`strut.margin_worst_case`), or nil.
    public var strutMargin: Double?
    /// This lattice type has no strut rule (`strut.uncertified`; its `strut.margin_*` are null).
    public var strutNoRule: Bool

    /// ★ Why a "fail" failed (LatticeReview 11-17): a load on OPEN lattice (cut cells, cells that lost a left-out bar) has no
    /// load path whatever the solid's margin — the old open-finish rule.
    public enum FailReason: String, Sendable { case loadOnOpenLattice = "load_on_open_lattice", noLoadPath = "no_load_path",
                                                    solidMargin = "solid_margin" }
    public var failReason: FailReason?
    /// The load landing on cells that get no credit, and the whole load (N), where countable.
    public var loadOnNoCreditN: Double?
    public var loadTotalN: Double?

    public init(block b: [String: Any]) {
        func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
        accepted = b["accepted"] as? Bool ?? false
        marginWorstCase = num(b["margin_worst_case"])
        safetyMargin = num(b["safety_margin"])
        notCertified = b["not_certified"] as? Bool ?? false
        notCertifiedReason = b["not_certified_reason"] as? String ?? ""
        massGrams = num(b["mass_grams"])
        maxEffectiveVonMisesMPa = num(b["max_effective_von_mises_mpa"])
        marginInPlane = num(b["margin_in_plane"])
        marginInterlayer = num(b["margin_interlayer"])
        fields = b["fields"] as? String
        scenarioFields = b["scenario_fields"] as? String
        maxInterlayerTensionMPa = num(b["max_interlayer_tension_mpa"])
        buildDirection = (b["build_direction"] as? [NSNumber]).flatMap {
            $0.count == 3 ? SIMD3($0[0].doubleValue, $0[1].doubleValue, $0[2].doubleValue) : nil
        }
        diagnosis = (b["diagnosis"] as? [String: Any]).flatMap(GateDiagnosis.decode)
        let strut = b["strut"] as? [String: Any] ?? [:]
        strutMargin = (strut["margin_worst_case"] as? NSNumber)?.doubleValue
        strutNoRule = strut["uncertified"] as? Bool ?? false
        strutsPass = b["struts_pass"] as? Bool ?? false
        verdictSent = (b["verdict"] as? String).flatMap(Verdict.init(rawValue:))
        failReason = (b["fail_reason"] as? String).flatMap(FailReason.init(rawValue:))
        loadOnNoCreditN = (b["load_on_no_credit_n"] as? NSNumber)?.doubleValue
        loadTotalN = (b["load_total_n"] as? NSNumber)?.doubleValue
    }

    /// The one-tap fix for a load on open lattice (his words to come; the tap keeps the loaded face solid).
    public static let protectLoadedFace = "Protect the loaded face to keep it solid, then Lattice again"

    /// Why the solid fails, in plain words, when it is not the margin itself; nil for "solid_margin" or a core without it.
    public var noPathLine: String? {
        switch failReason {
        case .loadOnOpenLattice?:
            var share = ""
            if let on = loadOnNoCreditN, let all = loadTotalN, all > 0, on > 0 {
                share = String(format: " (%.0f%% of it)", Swift.min(100, 100 * on / all))
            }
            return "The load lands on open lattice\(share), so nothing carries it to the anchors. " + Self.protectLoadedFace + "."
        case .noLoadPath?: return "Nothing carries the load to the anchors."
        case .solidMargin?, nil: return nil
        }
    }

    private static func x(_ m: Double) -> String { String(format: "%.1f×", m) }

    /// The check's not-certified words, or a plain fallback when it gives none.
    public static func notCertifiedLine(_ reason: String) -> String {
        "The check could not certify it: " + (reason.isEmpty ? "it could not judge this part" : Self.reason(reason))
    }

    /// Core's reason without its own "Not certified:" lead (the line already says so), first letter as written after.
    static func reason(_ r: String) -> String {
        guard !r.isEmpty else { return "the check could not judge it" }
        let lead = "not certified:"
        guard r.lowercased().hasPrefix(lead) else { return r }
        let rest = r.dropFirst(lead.count).trimmingCharacters(in: .whitespaces)
        return rest.prefix(1).lowercased() + rest.dropFirst()
    }

    /// One plain line: whether the latticed part is strong enough for his loads at his safety margin.
    public var line: String {
        if notCertified { return "Strength not checked: " + Self.reason(notCertifiedReason) }
        let mass = massGrams > 0 ? String(format: " · %.0f g", massGrams) : ""
        let margin = Self.x(marginWorstCase)
        switch verdict {
        case .pass: return "Strong enough · margin \(margin)\(mass)"
        case .solidOnly: return "Solid strong enough · margin \(margin) · struts: " + (strutsLine ?? Self.strutsNot).lowercased()
        case .fail:
            switch failReason {
            case .loadOnOpenLattice?: return "Not strong enough · the load lands on open lattice"
            case .noLoadPath?: return "Not strong enough · nothing carries the load"
            case .solidMargin?, nil: return "Not strong enough · margin \(margin), needs \(Self.x(safetyMargin))"
            }
        }
    }

    static let strutsNot = "Do not keep the margin"

    /// The struts in one line (Results' Strength tab, "Struts"), or nil when the check says nothing about them.
    public var strutsLine: String? {
        if strutNoRule { return "This lattice type has no strut rule" }
        guard let m = strutMargin else { return nil }
        return strutsPass ? "Keep the margin · \(Self.x(m))" : "\(Self.strutsNot) · \(Self.x(m)), needs \(Self.x(safetyMargin))"
    }
}

// MARK: the run on the Mac

public enum LatticeFileRun {
    public static let pollSeconds: TimeInterval = 2
    public static let ceilingSeconds: TimeInterval = 3600

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ d: String) { description = d }
    }

    /// What the Mac made: the file, its report, the strength check's views beside it (fields.bin, scenario_fields.bin; only
    /// when the report names them) and the worker's own record of how long it took.
    public struct Made {
        /// The file's bytes: an STL, or (Organic, `report.isThreeMF`) core's 3MF.
        public var stl: Data
        public var report: LatticeFileReport
        /// The report's whole JSON (the Results screen reads its `strength` block).
        public var reportJSON: Data
        public var fields: Data?
        public var scenarioFields: Data?
        public var timing: RunTiming?
    }

    /// Submit, poll, fetch: blocking, so call it off the main thread. The worker's core must be the app's (a different core lays
    /// a different lattice than the preview drew).
    public static func drive(config: RemoteRunnerConfig, modelPath: String, jobJSON: Data, projectName: String,
                             demand: Data? = nil, strengthJob: Data? = nil, tensor: Data? = nil,
                             isCancelled: @escaping @Sendable () -> Bool = { false },
                             onState: @escaping @Sendable (_ state: String, _ position: Int?) -> Void = { _, _ in })
        throws -> Made {
        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = config.controlTimeout
            return c
        }())
        func send(_ req: URLRequest) throws -> (Data, Int) {
            var out: (Data, URLResponse)?
            var err: Error?
            let sem = DispatchSemaphore(value: 0)
            session.dataTask(with: req) { d, r, e in
                if let d, let r { out = (d, r) } else { err = e }
                sem.signal()
            }.resume()
            sem.wait()
            guard let out else { throw Failure("The Mac did not answer (\(err?.localizedDescription ?? "no response"))") }
            return (out.0, (out.1 as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let base = config.baseURL
        let (hd, hc) = try send(URLRequest(url: base.appendingPathComponent("health")))
        guard hc == 200, let h = (try? JSONSerialization.jsonObject(with: hd)) as? [String: Any] else {
            throw Failure("The Mac's worker did not answer")
        }
        let fp = (h["fingerprint"] as? String) ?? "unknown"
        guard fp == config.expectedFingerprint else { throw Failure("The Mac runs a different engine: update it first") }

        let model = try Data(contentsOf: URL(fileURLWithPath: modelPath))
        let boundary = "topopt-\(UUID().uuidString)"
        var body = Data()
        var parts = RemoteRun.uploadParts(modelPath: modelPath, model: model, jobJSON: jobJSON, projectName: projectName)
        // ★ Install 2: the stress result beside the job (the worker saves the "demand" part as demand.bin)
        if let demand {
            parts.append(RemoteRun.UploadPart(name: "demand", filename: LatticeFileJob.demandName,
                                              contentType: "application/octet-stream", data: demand))
        }
        // ★ Install 3: the run job the strength check reads (the worker saves the "strength_job" part as strength_job.json)
        if let strengthJob {
            parts.append(RemoteRun.UploadPart(name: "strength_job", filename: LatticeFileJob.strengthJobName,
                                              contentType: "application/json", data: strengthJob))
        }
        // ★ Organic cut 2: the stress the weave follows (the worker saves the "tensor" part as tensor.bin)
        if let tensor {
            parts.append(RemoteRun.UploadPart(name: "tensor", filename: LatticeFileJob.tensorName,
                                              contentType: "application/octet-stream", data: tensor))
        }
        for p in parts {
            var head = "Content-Disposition: form-data; name=\"\(p.name)\""
            if let f = p.filename { head += "; filename=\"\(f)\"" }
            if let t = p.contentType { head += "\r\nContent-Type: \(t)" }
            body.append(Data("--\(boundary)\r\n\(head)\r\n\r\n".utf8))
            body.append(p.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        var post = URLRequest(url: base.appendingPathComponent("jobs"))
        post.httpMethod = "POST"
        post.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        post.httpBody = body
        let (pd, pc) = try send(post)
        guard pc == 202, let posted = (try? JSONSerialization.jsonObject(with: pd)) as? [String: Any],
              let jobID = posted["job_id"] as? String else {
            throw Failure("The Mac refused the job: \(String(data: pd, encoding: .utf8)?.prefix(120) ?? "")")
        }

        let jobURL = base.appendingPathComponent("jobs").appendingPathComponent(jobID)
        let deadline = Date().addingTimeInterval(ceilingSeconds)
        var state = "queued"
        var record: [String: Any] = [:]
        while Date() < deadline {
            if isCancelled() {
                var del = URLRequest(url: jobURL)
                del.httpMethod = "DELETE"
                _ = try? send(del)
                throw Failure("Cancelled")
            }
            let (d, code) = try send(URLRequest(url: jobURL))
            guard code == 200, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                throw Failure("Lost the job on the Mac")
            }
            state = (o["state"] as? String) ?? "unknown"
            record = o
            onState(state, o["position"] as? Int)   // queued (and how many ahead) or running
            if state == "done" { break }
            if state == "failed" || state == "error" || state == "cancelled" {
                // the CLI's last line carries the same plain why as lattice_file.json (the contract)
                let why = ((o["message"] as? String) ?? "").split(separator: "\n").last.map(String.init) ?? ""
                throw Failure(why.isEmpty ? "The file could not be made" : why)
            }
            Thread.sleep(forTimeInterval: pollSeconds)
        }
        guard state == "done" else { throw Failure("The file was not made within \(Int(ceilingSeconds / 60)) minutes") }
        func file(_ name: String) -> Data? {
            guard let (d, c) = try? send(URLRequest(url: jobURL.appendingPathComponent("files").appendingPathComponent(name))),
                  c == 200, !d.isEmpty else { return nil }
            return d
        }
        guard let rd = file(LatticeFileJob.reportName), let report = LatticeFileReport.parse(rd) else {
            throw Failure("The Mac made the file but its report could not be read")
        }
        guard report.ok else { throw Failure(report.why.isEmpty ? "The file could not be made" : report.why) }
        // the file by the name the report gives (Organic: lattice.3mf), else the job's own output
        guard let stl = file(report.fileName) else { throw Failure("The Mac made the file but it could not be fetched") }
        // ★ Install 3: the strength check's views, by the names its block gives (bare names beside the report); enrichment —
        // a missing one leaves the views gated, never the result
        func named(_ n: String?) -> Data? { n.flatMap { $0.contains("/") || $0.contains("..") ? nil : file($0) } }
        return Made(stl: stl, report: report, reportJSON: rd, fields: named(report.strength?.fields),
                    scenarioFields: named(report.strength?.scenarioFields),
                    timing: RunTiming.fromWorker(createdAt: record["created_at"] as? Double, startedAt: record["started_at"] as? Double,
                                                 finishedAt: record["finished_at"] as? Double))
    }
}

// MARK: the Lattice button on the new engine

/// ★ HIS YES 11-17 ("Should the main Lattice button make the new engine's file and run the strength check?" → "1. Yes."): for
/// a regular lattice on a part with its STEP file, the Lattice button sends the print file's job (with the strength check on
/// Structural), made on the Mac, and its result is the Results screen's one result: the file's mesh, the check's numbers and
/// views. Variants, Organic and STL parts keep the old run (his word via LatticeReview).
public enum LatticeFileButton {
    /// The same switch as the strength check: a core that reads `strength_job` (off until LatticeReview's core is merged; a
    /// Structural lattice must not lose its check by moving).
    public static var wired: Bool { testWired ?? LatticeFileJob.strengthWired }
    /// Tests only: the switch as a test sets it. The app never sets it.
    nonisolated(unsafe) public static var testWired: Bool?
    /// Grading by stress with no stress result yet: the press runs the stress check first, then lattices.
    public static let stressFirstLine = "Checking the stresses first, then latticing"
    /// The run's mode on the new engine (the request the run carries says which engine made it).
    public static let jobMode = "lattice_file"

    /// Whether this part's Lattice goes to the new engine: a regular lattice, or (★ Organic cut 2, his 11-18 "Export as its own
    /// install") an Organic one, on a STEP part, the switch on.
    public static func takes(_ l: LatticeSettings, modelPath: String?, wired: Bool = wired) -> Bool {
        guard wired, let p = modelPath?.lowercased(), p.hasSuffix(".step") || p.hasSuffix(".stp") else { return false }
        return true
    }

    /// The Results screen's one result from what the Mac made. Structural: the strength check's verdict, margins, mass, views
    /// (`accepted` is the old gate's: a "fail" lands as the not-strong-enough card, the file kept); its `strength` block rides as
    /// the outcome's report, so the Strength tab says what the struts did. Aesthetic: never checked (U9) — nothing to refuse,
    /// no margin claimed, the weight from the file's own volume.
    public static func outcome(_ m: LatticeFileRun.Made, densityGCm3: Double) throws -> OptimizeOutcome {
        // ★ Organic cut 2: core's 3MF read back by its own small reader; an STL as before
        let mesh: (vertices: [Float], indices: [Int32])
        if m.report.isThreeMF {
            do { mesh = try CoreThreeMF.mesh(m.stl) } catch { throw LatticeFileRun.Failure("\(error)") }
        } else {
            let s = MeshExport.parseBinarySTL(m.stl)
            mesh = (s.vertices, s.indices)
        }
        guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty else {
            throw LatticeFileRun.Failure("The Mac made the file but it could not be read")
        }
        let s = m.report.strength
        let fields = m.fields.flatMap(RemoteFieldsContainer.parse)
        let block = fields?.variants.first
        let fraction = m.report.partMM3 > 0 ? m.report.plasticMM3 / m.report.partMM3 : 0
        let accepted = s?.accepted ?? true
        let grams = s.flatMap { $0.massGrams > 0 ? $0.massGrams : nil } ?? m.report.plasticMM3 / 1000 * densityGCm3
        // ★ a fail with no load path (a load on open lattice): the not-strong-enough card says so INSTEAD of a margin sentence
        // (its load-path wording), with core's reason in plain words and the fix; a margin fail keeps core's own diagnosis
        var diagnosis = s?.diagnosis
        func said(_ binding: GateDiagnosis.Term, _ why: String, _ s: LatticeFileStrength) -> GateDiagnosis {
            let d = s.diagnosis
            return GateDiagnosis(binding: binding, bindingValue: d?.bindingValue ?? 0, requiredValue: s.safetyMargin,
                                 ratio: d?.ratio ?? 0, marginWorstCaseRaw: s.marginWorstCase, marginInPlaneRaw: s.marginInPlane,
                                 marginInterlayerRaw: s.marginInterlayer, marginEffective: s.marginWorstCase,
                                 knockdownFactor: d?.knockdownFactor ?? 1, infillPercent: d?.infillPercent ?? 100,
                                 minFeatureViolations: 0, inheritsUnsourcedZKnockdown: false, provenance: d?.provenance ?? "",
                                 noSettingFixesThis: true, noFixReason: why, headroomMinInfillPercent: nil, recommendations: [])
        }
        if let s, !accepted, let why = s.noPathLine {
            diagnosis = said(.loadPath, why, s)
        } else if let s, !accepted, s.failReason == nil, s.notCertified, s.diagnosis == nil {
            // ★ LatticeReview 11-17 18:34Z: a fail none of the three reasons covers (anchors held only by sliding; no solid
            // carries load) has no fail_reason — the check's own not-certified words, in one plain line
            diagnosis = said(.none, LatticeFileStrength.notCertifiedLine(s.notCertifiedReason), s)
        }
        var v = OptimizeVariant(
            requestedVolumeFraction: fraction, achievedVolumeFraction: fraction,
            massGrams: grams, supportVolumeVoxels: block?.supportVolumeVoxels ?? 0,
            meshTriangleCount: mesh.indices.count / 3,
            worstCaseMargin: s?.marginWorstCase ?? 0, accepted: accepted, v3Passes: accepted,
            orientation: s?.buildDirection ?? SIMD3(0, 0, 1),
            maxStressMPa: s?.maxEffectiveVonMisesMPa ?? 0, maxInterlayerTensionMPa: s?.maxInterlayerTensionMPa ?? 0,
            inPlaneMargin: s?.marginInPlane ?? 0, interlayerMargin: s?.marginInterlayer ?? 0,
            meshVertices: mesh.vertices, meshIndices: mesh.indices,
            vonMisesField: block?.vonMises ?? [], displacementField: block?.displacement ?? [],
            stressTensorField: block?.stressTensor ?? [], diagnosis: diagnosis)
        if let sf = m.scenarioFields.flatMap(RemoteScenarioFields.parse),
           sf.gridNx == fields?.gridNx, sf.gridNy == fields?.gridNy, sf.gridNz == fields?.gridNz {
            v.scenarioFields = sf.blocks.first?.sets ?? []
        }
        return OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false, acceptedCount: accepted ? 1 : 0,
                               voxelVolumeMM3: fields?.voxelVolumeMM3 ?? 0,
                               gridNx: fields?.gridNx ?? 0, gridNy: fields?.gridNy ?? 0, gridNz: fields?.gridNz ?? 0,
                               gridOrigin: fields?.gridOrigin ?? .zero, spacing: fields?.spacing ?? 0,
                               computedRemotely: true, timing: m.timing, reportJSON: m.reportJSON)
    }

    private final class Progress: @unchecked Sendable {
        let call: (Int, Int, Int) -> Bool
        init(_ c: @escaping (Int, Int, Int) -> Bool) { call = c }
    }

    /// The run the Lattice button starts: the job sent, polled and fetched on the Mac (a tap on the running card's cancel
    /// deletes the Mac's job), then `outcome`.
    public static func runner(config: RemoteRunnerConfig, job: LatticeFileJob.ForPart, projectName: String,
                              strengthJob: Data?, densityGCm3: Double) -> RunModel.Runner {
        { _, progress, _ in
            let keepGoing = Progress(progress)
            _ = keepGoing.call(0, 1, 0)
            let made = try LatticeFileRun.drive(config: config, modelPath: job.modelPath, jobJSON: job.json, projectName: projectName,
                                                demand: job.demand, strengthJob: strengthJob, tensor: job.tensor,
                                                isCancelled: { !keepGoing.call(0, 1, 0) })
            return try outcome(made, densityGCm3: densityGCm3)
        }
    }

    /// ★ THE iPAD ONLY OPTION (his 11-17: "Not everyone will have a mac, definitely include an iPad only option"): with Runs on
    /// set to this iPad, the same job runs here, through core's own `run_file_job` (`LatticeLayoutSession.runFileJob`), then
    /// `outcome`. One coarse tick, as the old on-device Lattice: no fake progress.
    public static func deviceRunner(job: LatticeFileJob.ForPart, strengthJob: Data?, materialsPath: String, rulesPath: String,
                                    densityGCm3: Double) -> RunModel.Runner {
        { _, progress, _ in
            _ = progress(0, 1, 0)
            let made = try runHere(job: job, strengthJob: strengthJob, materialsPath: materialsPath, rulesPath: rulesPath)
            return try outcome(made, densityGCm3: densityGCm3)
        }
    }

    /// The job made on this device. Its files go beside the model (its `model`, `demand` and `strength_job` are names resolved
    /// there) under names of their own, so nothing of the project's is ever overwritten, and all of them are removed after; the
    /// file and its report land in a temporary folder. Timing is the run's own (RunModel stamps a local run).
    static func runHere(job: LatticeFileJob.ForPart, strengthJob: Data?, materialsPath: String, rulesPath: String) throws
        -> LatticeFileRun.Made {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: job.modelPath).deletingLastPathComponent()
        let tag = UUID().uuidString
        let outDir = fm.temporaryDirectory.appendingPathComponent("lattice-file-\(tag)", isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        var written: [URL] = []
        defer {
            for u in written { try? fm.removeItem(at: u) }
            try? fm.removeItem(at: outDir)
        }
        guard var doc = (try? JSONSerialization.jsonObject(with: job.json)) as? [String: Any] else {
            throw LatticeFileRun.Failure("The job could not be written")
        }
        func beside(_ name: String, _ data: Data) throws {
            let u = dir.appendingPathComponent(name)
            try data.write(to: u, options: .withoutOverwriting)
            written.append(u)
        }
        if let d = job.demand {
            let name = "lattice_file_demand-\(tag).bin"
            try beside(name, d)
            doc["demand"] = name
        }
        if let s = strengthJob {
            let name = "lattice_file_strength_job-\(tag).json"
            try beside(name, s)
            doc["strength_job"] = name
        }
        if let t = job.tensor {   // ★ Organic cut 2 (the app makes Organic on a Mac; the tests make it here)
            let name = "lattice_file_tensor-\(tag).bin"
            try beside(name, t)
            doc["tensor"] = name
        }
        let jobName = "lattice_file_job-\(tag).json"
        try beside(jobName, try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]))
        let r = try LatticeLayoutSession.runFileJob(jobPath: dir.appendingPathComponent(jobName).path, outDir: outDir.path,
                                                    materialsPath: materialsPath, rulesPath: rulesPath)
        func file(_ name: String) -> Data? {
            guard !name.contains("/"), !name.contains(".."), let d = try? Data(contentsOf: outDir.appendingPathComponent(name)),
                  !d.isEmpty else { return nil }
            return d
        }
        let said = r.why.isEmpty ? "The file could not be made" : r.why
        if !r.ok { NSLog("DIAG lattice file on this device: %@ (%@): %@", r.code, said, r.detail) }   // the why behind the line
        guard let rd = file(LatticeFileJob.reportName), let report = LatticeFileReport.parse(rd) else {
            throw LatticeFileRun.Failure(said)
        }
        guard report.ok else { throw LatticeFileRun.Failure(report.why.isEmpty ? said : report.why) }
        guard let stl = file(report.fileName) else { throw LatticeFileRun.Failure("The file was made but could not be read") }
        return LatticeFileRun.Made(stl: stl, report: report, reportJSON: rd, fields: report.strength?.fields.flatMap(file),
                                   scenarioFields: report.strength?.scenarioFields.flatMap(file), timing: nil)
    }
}

// MARK: the button's state

@MainActor
public final class LatticeFileExport: ObservableObject {
    public enum State: Equatable {
        case idle
        case making(since: Date)
        case ready(URL, LatticeFileReport)
        case failed(String)
    }
    @Published public private(set) var state: State = .idle
    /// While making: the Mac's word for the job ("queued" with how many are ahead, or "running").
    @Published public private(set) var onMac: (state: String, ahead: Int?)?
    public static let noMacLine = "Choose a Mac to make the print file"
    public static let checkLine = "Check it in your slicer before printing"
    public static let supportsOffLine = LatticeFileJob.supportsOffLine
    /// ★ Organic cut 2: the file is the lattice the preview laid; none laid yet, nothing to make.
    public static let organicNoLayLine = "Let the Organic preview finish first: the file is the lattice it shows"
    /// ★ His 11-17 ("Preview only for now"): an Organic part is made on a Mac.
    public static let organicNeedsMacLine = "Making an Organic part needs a Mac: choose one in Runs on"
    /// ★ Install 2: By stress with no stress result — one line, and the bar offers the check itself.
    public static let noStressLine = "Grading by stress needs the stress check first"
    @Published public private(set) var needsStressCheck = false

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    private var flag = Flag()
    private var token = 0

    public init() {}

    /// Make the print file for this part, with the preview's own settings, on the chosen Mac.
    /// ★ Organic cut 2: `organic` = the groups the preview's exact lay laid and the stress it followed (none laid: empty).
    public func make(project p: ProjectModel, config: RemoteRunnerConfig?, stress: LatticeLayoutPreview.Stress = .init(),
                     strengthJob: Data? = nil,
                     organic: (groups: [LatticeLayoutSession.OrganicGroup], tensor: Data)? = nil) {
        needsStressCheck = false
        guard let config else { state = .failed(organic == nil ? Self.noMacLine : Self.organicNeedsMacLine); return }
        let job: LatticeFileJob.ForPart
        let built = organic.map {
            LatticeFileJob.forOrganic(p, groups: $0.groups, tensor: $0.tensor, referenceMPa: stress.referenceMPa,
                                      strengthJob: strengthJob)
        } ?? LatticeFileJob.forPart(p, stress: stress, strengthJob: strengthJob)
        switch built {
        case .success(let j): job = j
        case .failure(let why):
            needsStressCheck = why.line == Self.noStressLine
            state = .failed(why.line); return
        }
        let path = job.modelPath, demand = job.demand, tensor = job.tensor
        let name = p.name, f = Flag()
        flag = f
        token &+= 1
        let t = token
        state = .making(since: Date())
        Task.detached {
            let outcome: Result<LatticeFileRun.Made, Error> = Result {
                try LatticeFileRun.drive(config: config, modelPath: path, jobJSON: job.json, projectName: name, demand: demand,
                                         strengthJob: strengthJob, tensor: tensor,
                                         isCancelled: { f.get() },
                                         onState: { st, pos in
                                             Task { @MainActor [weak self] in
                                                 guard let self, self.token == t else { return }
                                                 self.onMac = (st, pos.map { Swift.max(0, $0 - 1) })
                                             }
                                         })
            }
            var saved: Result<URL, Error>?
            if case let .success(r) = outcome {
                let safe = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
                let ext = r.report.isThreeMF ? "3mf" : "stl"   // ★ Organic cut 2: core's 3MF
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.isEmpty ? "Part" : safe) lattice.\(ext)")
                saved = Result { try r.stl.write(to: url, options: .atomic); return url }
            }
            await MainActor.run { [weak self] in
                guard let self, self.token == t else { return }
                switch (outcome, saved) {
                case let (.success(r), .success(url)?): self.state = .ready(url, r.report)
                case let (.failure(e), _): self.state = .failed(FlexibleRowCopy.fit("\(e)", 70))
                default: self.state = .failed("The file could not be saved on this iPad")
                }
            }
        }
    }

    public func cancel() {
        flag.set()
        token &+= 1
        state = .idle
    }

    /// The settings moved: a file made from the old ones no longer matches the preview.
    public func settingsChanged() {
        if case .making = state { return }
        state = .idle
        needsStressCheck = false
    }
}

// MARK: the button

/// The Export bar above the new engine's lines: Export, then making (with the time and Cancel), then the file (Share) or why not.
struct LatticeFileExportBar: View {
    @ObservedObject var export: LatticeFileExport
    let make: () -> Void
    /// ★ Install 2: the one tap that starts the stage's stress check (By stress with no result yet)
    var runStressCheck: (() -> Void)? = nil
    @State private var sharing = false

    private func chip(_ title: String, key: String, primary: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primary ? Color.white : DS.Color.textPrimary.color)
                .padding(.horizontal, DS.Space.m).frame(height: 32)
                .background(Capsule().fill(primary ? DS.Color.accent.color : DS.Surface.bar.color))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .background(CornerPairStyle.publish(key))
        .accessibilityIdentifier(key)
    }

    private func said(_ text: String, warning: Bool = false, key: String) -> some View {
        Text(text).font(.system(size: 12, weight: warning ? .semibold : .regular))
            .foregroundStyle(warning ? DS.Color.warning.color : DS.Color.textSecondary.color)
            .lineLimit(1).minimumScaleFactor(0.8)
            .background(CornerPairStyle.publish(key))
    }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            switch export.state {
            case .idle:
                chip("Export print file", key: "new-engine-export", primary: true, make)
            case let .making(since):
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    let s = Int(ctx.date.timeIntervalSince(since))
                    if let m = export.onMac, m.state == "queued" {
                        said("Waiting for the Mac" + (m.ahead.map { $0 > 0 ? " · \($0) ahead" : "" } ?? "")
                             + String(format: " · %d:%02d", s / 60, s % 60), key: "new-engine-export-making")
                    } else {
                        said(String(format: "Making the print file on the Mac · %d:%02d", s / 60, s % 60), key: "new-engine-export-making")
                    }
                }
                chip("Cancel", key: "new-engine-export-cancel") { export.cancel() }
            case let .ready(_, r):
                VStack(alignment: .leading, spacing: 0) {
                    said(r.line, key: "new-engine-export-ready")
                    if let st = r.strength {   // ★ Install 3: the strength check, Structural
                        said(st.line, warning: !st.accepted || st.notCertified, key: "new-engine-export-strength")
                    }
                    said(LatticeFileExport.checkLine, key: "new-engine-export-check")
                }
                chip("Share", key: "new-engine-export-share", primary: true) { sharing = true }
                chip("Again", key: "new-engine-export", make)
            case let .failed(line):
                said(line, warning: true, key: "new-engine-export-failed")
                if export.needsStressCheck, let runStressCheck {
                    chip("Run the stress check", key: "new-engine-export-stress", primary: true, runStressCheck)
                } else {
                    chip("Try again", key: "new-engine-export", make)
                }
            }
        }
        .padding(.horizontal, DS.Space.s)
        .background(Capsule().fill(DS.Surface.bar.color.opacity(0.9)))
        .sheet(isPresented: $sharing) {
            if case let .ready(url, _) = export.state { ShareSheet(items: [url]) }
        }
    }
}
