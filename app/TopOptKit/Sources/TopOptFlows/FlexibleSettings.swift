// FlexibleSettings — what the user chose in the Flexible stage, saved with the project
// (task 2026-09-29-flexible-screens, A1; docs/design/flexibles/01-product-spec.md).
//
// ★ THESE ARE INPUTS ONLY. Nothing here is a squish number: every depth, density, frame
// and curve value is recomputed by core from these inputs (M9). So the file can never
// hold a stale prediction, and undo restores the drawing, not an answer.
//
// ★ FLEXIBLE IS ITS OWN CHOICE, BESIDE LatticeStageMode (M10). It is NOT a case of that
// enum: LatticeStageMode is core's GradingIntent for the octet / organic lattice, with
// ~44 switch sites; Flexible has no grading intent at all. The project records it as
// `LatticeSettings.flexible != nil` with `stageMode == nil`, so "Delete and choose
// again" (which resets LatticeSettings) removes it exactly as it removes the others.

import Foundation
import TopOptKit

/// g for kg → N (task: "weight in kg (converted to N at 9.80665 m/s²)").
public enum FlexibleUnits {
    public static let standardGravity = 9.80665
    public static func newtons(kg: Double) -> Double { kg * standardGravity }
}

/// Where a stamp's shape comes from (M14).
public enum FlexibleStampSource: Codable, Equatable, Hashable, Sendable {
    /// A built-in from data/stamps.json, by id.
    case library(String)
    /// An imported SVG outline or image, already turned into a normalised pressure mask
    /// (row-major, `side × side`, values 0…1, darker = harder). The APP rasterises (M14);
    /// the mask is the user's shape, not a prediction.
    case imported(name: String, side: Int, mask: [Double], aspect: Double)
}

/// One stamp placed on a face (M14): shape, real size, rotation, position, weight,
/// soft or rigid. Rasterised to core's StampGrid when used (FlexibleStamps).
public struct FlexibleStampPlacement: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var source: FlexibleStampSource
    /// The stamp's size along its own width / length (mm). For `whole_face` ignored.
    public var widthMM: Double
    public var lengthMM: Double
    public var rotationDeg: Double
    /// Centre on the face, in the face frame's (u, v) mm.
    public var centreU: Double
    public var centreV: Double
    public var weightKg: Double
    public var rigid: Bool

    public init(id: UUID = UUID(), source: FlexibleStampSource, widthMM: Double, lengthMM: Double,
                rotationDeg: Double = 0, centreU: Double, centreV: Double, weightKg: Double, rigid: Bool) {
        self.id = id; self.source = source; self.widthMM = widthMM; self.lengthMM = lengthMM
        self.rotationDeg = rotationDeg; self.centreU = centreU; self.centreV = centreV
        self.weightKg = weightKg; self.rigid = rigid
    }
}

/// One face the user marked (M11–M15).
public struct FlexibleFaceSettings: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: Int { faceRegionID }
    /// The face region core reads (`loads.face_regions` id, see FlexibleJob.regionID).
    public var faceRegionID: Int
    /// "loaded" | "resting"
    public var role: String
    /// ★ ROUND 3 (item 5): always 0 — the frame rotation is removed (a saved 90 reads as 0).
    public var rotationDeg: Int
    public var weightKg: Double
    public var deepestMM: Double
    /// ★ ROUND 3 (item 5, his answer "X and Y always combined"): always "both" — a saved
    /// "either" / "centre_edge" reads as "both", its curveX / curveY kept.
    public var mode: String
    public var curveX: FlexCurve
    public var curveY: FlexCurve
    public var curveCentreEdge: FlexCurve
    /// M15: the face keeps its solid skin (off lets edges and side walls squish).
    public var skinOn: Bool
    /// Design mode: the one stamp the face is designed under (nil ⇒ weight spread evenly).
    public var designStamp: FlexibleStampPlacement?
    /// ★ ROUND 3 (item 1.2): the main-page Load group this face's weight comes from. nil ⇒
    /// the weight is the user's own (typed here), never overwritten by a re-sync. OPTIONAL
    /// so every project saved before it still decodes (synthesized Codable).
    public var weightFrom: UUID?
    /// ★ ROUND 3 (item 6b): the squish shape — nil (or "curves") ⇒ the X and Y curves,
    /// always combined; "stamp" ⇒ squish by stamp (batch D). OPTIONAL for old projects.
    public var shape: String?

    public init(faceRegionID: Int, role: String = "loaded", rotationDeg: Int = 0,
                weightKg: Double = 10, deepestMM: Double = 3, mode: String = "both",
                curveX: FlexCurve = FlexibleFaceSettings.defaultCurve,
                curveY: FlexCurve = FlexibleFaceSettings.defaultCurve,
                curveCentreEdge: FlexCurve = FlexCurve(x: [0, 1], y: [0.3, 1]),
                skinOn: Bool = true, designStamp: FlexibleStampPlacement? = nil,
                weightFrom: UUID? = nil, shape: String? = nil) {
        self.faceRegionID = faceRegionID; self.role = role; self.rotationDeg = rotationDeg
        self.weightKg = weightKg; self.deepestMM = deepestMM; self.mode = mode
        self.curveX = curveX; self.curveY = curveY; self.curveCentreEdge = curveCentreEdge
        self.skinOn = skinOn; self.designStamp = designStamp
        self.weightFrom = weightFrom; self.shape = shape
    }

    /// A gentle dome: soft in the middle, firmer at both ends. A starting drawing, not a
    /// recommendation — the user moves every point.
    public static let defaultCurve = FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3])

    public var weightN: Double { FlexibleUnits.newtons(kg: weightKg) }
    public var isLoaded: Bool { role == "loaded" }

    /// The squish map core reads (02 §12).
    public var map: FlexMap {
        FlexMap(mode: mode, x: curveX, y: curveY, centreEdge: curveCentreEdge, deepestMM: deepestMM)
    }
}

/// A check-mode stamp (M14): pressed on the designed lattice, never re-designs it.
public struct FlexibleCheckStamp: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID { stamp.id }
    public var faceRegionID: Int
    public var stamp: FlexibleStampPlacement
    public init(faceRegionID: Int, stamp: FlexibleStampPlacement) {
        self.faceRegionID = faceRegionID; self.stamp = stamp
    }
}

/// Everything the Flexible stage saves (S5).
public struct FlexibleStageSettings: Codable, Equatable, Hashable, Sendable {
    /// flexible_materials.json id; nil until picked.
    public var materialID: String?
    /// A TESTED temperature (R10); nil ⇒ Auto weighs every tested temperature.
    public var nozzleTempC: Double?
    /// auto | gyroid | honeycomb (M5: Auto by default)
    public var topology: String
    /// springy | damped (R5)
    public var feel: String
    /// Walls in whole beads. ★ ROUND 3 (item 2.1): always 1 — a saved 2 reads as 1
    /// (FlexibleSettingsMigration); 2-bead walls come after coupon tests (Core brief).
    public var beadsPerWall: Int
    public var faces: [FlexibleFaceSettings]
    public var checkStamps: [FlexibleCheckStamp]
    /// ★ ROUND 3 (item 1.3): which way the curve editor read the stored y when these curves
    /// were drawn. nil ⇒ saved before round 3 ("up = softer"): FlexibleSettingsMigration
    /// flips every DRAWN curve once so its picture survives the new reading ("closer to the
    /// face = squishier"). OPTIONAL so old projects decode.
    public var curveConvention: Int?

    public init(materialID: String? = nil, nozzleTempC: Double? = nil, topology: String = "auto",
                feel: String = "springy", beadsPerWall: Int = 1,
                faces: [FlexibleFaceSettings] = [], checkStamps: [FlexibleCheckStamp] = [],
                curveConvention: Int? = FlexibleSettingsMigration.currentCurveConvention) {
        self.materialID = materialID; self.nozzleTempC = nozzleTempC; self.topology = topology
        self.feel = feel; self.beadsPerWall = beadsPerWall; self.faces = faces
        self.checkStamps = checkStamps; self.curveConvention = curveConvention
    }

    public var loadedFaces: [FlexibleFaceSettings] { faces.filter(\.isLoaded) }

    public func face(_ region: Int) -> FlexibleFaceSettings? {
        faces.first { $0.faceRegionID == region }
    }

    /// Replace or add a face's settings.
    public mutating func setFace(_ f: FlexibleFaceSettings) {
        if let i = faces.firstIndex(where: { $0.faceRegionID == f.faceRegionID }) { faces[i] = f }
        else { faces.append(f) }
    }

    public mutating func removeFace(_ region: Int) {
        faces.removeAll { $0.faceRegionID == region }
        checkStamps.removeAll { $0.faceRegionID == region }
    }
}
