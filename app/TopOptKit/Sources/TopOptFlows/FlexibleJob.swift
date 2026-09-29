// FlexibleJob — the app's writer for core's `flexible` job block (F11; task
// 2026-09-29-flexible-screens S5). The schema is core's (job_block.hpp); the round-trip
// test reads every document written here back through core's own `parse_job`.
//
// Two documents come out of one encoder:
//   * the RUN job: exactly what the user set (loaded + resting faces, stamps), refused
//     here with core's words when a loaded face is missing a required value;
//   * the SCENE job: the same part, grid, placement and face regions, used only to open
//     a FlexibleScene before any face is loaded. Core's block needs one loaded face to
//     parse, and the scene reads none of the faces, so a scene job states the first
//     declared face as loaded with a unit map. It is never saved or run.

import Foundation
import TopOptKit

public enum FlexibleJob {

    /// Face region id for B-rep / pseudo face `face` (one declared region per face, so a
    /// tapped face and the stack's linked other end are both named by core). The id IS the
    /// face id, so core's own sentences ("face 12: …") name the face the app shows.
    public static let regionBase = 0
    public static func regionID(face: Int) -> Int { regionBase + face }
    public static func face(regionID: Int) -> Int { regionID - regionBase }

    public struct Inputs {
        public var modelPath: String
        public var resolution: Int
        /// The bead the other stages send as `min_extrudable_width_mm` (PrintParams.strutLineWidthMM).
        public var beadWidthMM: Double
        public var faceCount: Int
        public var settings: FlexibleStageSettings
        /// The placement: the lattice stage's own include/exclude regions (M10), as
        /// `LatticeRegionSpec.wireDictionary` values. Empty ⇒ the whole part.
        public var regions: [[String: Any]]
        /// Rasterised stamps by placement id (FlexibleStamps), for the run job.
        public var stampGrids: [UUID: FlexStamp]

        public init(modelPath: String, resolution: Int, beadWidthMM: Double, faceCount: Int,
                    settings: FlexibleStageSettings, regions: [[String: Any]] = [],
                    stampGrids: [UUID: FlexStamp] = [:]) {
            self.modelPath = modelPath; self.resolution = resolution; self.beadWidthMM = beadWidthMM
            self.faceCount = faceCount; self.settings = settings; self.regions = regions
            self.stampGrids = stampGrids
        }
    }

    public enum EncodeError: Error, Equatable, CustomStringConvertible {
        case noFilament
        case noLoadedFace
        case missingStampGrid(UUID)
        public var description: String {
            switch self {
            case .noFilament: return "Pick a filament first."
            case .noLoadedFace: return "Mark at least one face as carrying weight."
            case .missingStampGrid: return "A stamp has not been laid on its face yet."
            }
        }
    }

    // MARK: documents

    public static func runJobJSON(_ i: Inputs) throws -> String {
        guard let material = i.settings.materialID else { throw EncodeError.noFilament }
        guard !i.settings.loadedFaces.isEmpty else { throw EncodeError.noLoadedFace }
        var faces: [[String: Any]] = []
        for f in i.settings.faces { faces.append(try faceEntry(f, stamps: i.stampGrids)) }
        var block = header(i, material: material)
        block["faces"] = faces
        let checks = try i.settings.checkStamps.map { c -> [String: Any] in
            guard let g = i.stampGrids[c.stamp.id] else { throw EncodeError.missingStampGrid(c.stamp.id) }
            var e = stampEntry(g)
            e["face_region_id"] = c.faceRegionID
            return e
        }
        if !checks.isEmpty { block["check_stamps"] = checks }
        return try document(i, material: material, block: block)
    }

    /// The scene-opening document (see the file comment). `material` falls back to any
    /// catalogue id: the scene never reads it.
    public static func sceneJobJSON(_ i: Inputs, fallbackMaterial: String) throws -> String {
        let material = i.settings.materialID ?? fallbackMaterial
        var block = header(i, material: material)
        let first = i.settings.loadedFaces.first?.faceRegionID ?? regionID(face: 0)
        block["faces"] = [[
            "face_region_id": first, "role": "loaded", "skin_on": true, "weight_n": 1.0,
            "deepest_squish_mm": 1.0, "mode": "centre_edge", "curve_centre_edge": [[0.0, 1.0], [1.0, 1.0]],
        ] as [String: Any]]
        return try document(i, material: material, block: block)
    }

    // MARK: pieces

    static func header(_ i: Inputs, material: String) -> [String: Any] {
        var b: [String: Any] = [
            "material_id": material,
            "nozzle_temp_c": i.settings.nozzleTempC.map { $0 as Any } ?? "auto",
            "topology": i.settings.topology,
            "feel": i.settings.feel,
            "beads_per_wall": i.settings.beadsPerWall,
            "min_extrudable_width_mm": i.beadWidthMM,
        ]
        if !i.regions.isEmpty { b["regions"] = i.regions }
        return b
    }

    static func faceEntry(_ f: FlexibleFaceSettings, stamps: [UUID: FlexStamp]) throws -> [String: Any] {
        var e: [String: Any] = ["face_region_id": f.faceRegionID, "role": f.role, "skin_on": f.skinOn]
        guard f.isLoaded else { return e }
        if f.rotationDeg != 0 { e["frame_rotation_deg"] = f.rotationDeg }
        e["weight_n"] = f.weightN
        e["deepest_squish_mm"] = f.deepestMM
        e["mode"] = f.mode
        if f.mode == "centre_edge" {
            e["curve_centre_edge"] = pairs(f.curveCentreEdge)
        } else {
            e["curve_x"] = pairs(f.curveX)
            e["curve_y"] = pairs(f.curveY)
        }
        if let s = f.designStamp {
            guard let g = stamps[s.id] else { throw EncodeError.missingStampGrid(s.id) }
            e["design_stamp"] = stampEntry(g)
        }
        return e
    }

    static func pairs(_ c: FlexCurve) -> [[Double]] { zip(c.x, c.y).map { [$0, $1] } }

    static func stampEntry(_ g: FlexStamp) -> [String: Any] {
        ["name": g.name, "mode": g.rigid ? "rigid" : "soft", "force_n": g.forceN,
         "origin_mm": [g.originU, g.originV], "cell_mm": g.cellMM, "nu": g.nu, "nv": g.nv,
         "values_mpa": g.valuesMPa]
    }

    static func document(_ i: Inputs, material: String, block: [String: Any]) throws -> String {
        let regions: [[String: Any]] = (0..<max(0, i.faceCount)).map { f in
            ["id": regionID(face: f), "name": "face \(f)", "add": [f]]
        }
        let job: [String: Any] = [
            "model": i.modelPath,
            "material": material,
            // core's schema still requires these; the Flexible runner does not read them
            // (C1 problem #9)
            "mode": "analyze",
            "resolution": i.resolution,
            "output": ["report": "report.json", "mesh_format": "stl", "mesh_prefix": "unused"],
            "loads": ["face_regions": regions],
            "flexible": block,
        ]
        let data = try JSONSerialization.data(withJSONObject: job, options: [.sortedKeys, .prettyPrinted])
        return String(decoding: data, as: UTF8.self)
    }
}
