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
    /// ★ ROUND 4 (D1): READ BY NOTHING — the model-wide Finish (`FlexibleStageSettings.finish`)
    /// replaced the per-face "Solid skin" row; kept so every saved project still decodes.
    public var skinOn: Bool
    /// Design mode: the one stamp the face is designed under (nil ⇒ weight spread evenly).
    public var designStamp: FlexibleStampPlacement?
    /// ★ ROUND 3 (item 1.2): the main-page Load group this face's weight comes from. nil ⇒
    /// the weight is the user's own (typed here), never overwritten by a re-sync. OPTIONAL
    /// so every project saved before it still decodes (synthesized Codable).
    public var weightFrom: UUID?
    /// ★ ROUND 3 (item 6b): the squish shape — nil (or "curves") ⇒ the X and Y curves,
    /// always combined; "stamp" ⇒ squish by stamp. OPTIONAL for old projects.
    /// ★ ROUND 4 (D1, his "either/or"): the shape decides EVERYTHING the face sends — Curves
    /// sends the drawn curves and never a stamp (a stamp kept from before is stored, not
    /// used); Stamp sends flat curves and its ONE stamp (`designStamp`) at the face's weight.
    public var shape: String?
    /// ★ ROUND 4 (D2, his img 3 / img 4 and answer 1): the SQUEEZE GROUP this pressed face is in
    /// (FlexibleSqueezeGroups) — nil ⇒ group 1, so every pressed face starts in one group. Faces
    /// of one group are squeezed AT THE SAME TIME with one force (a pinch across a stack is two
    /// segments); separate groups are separate squeezes. OPTIONAL so old projects decode.
    public var squeezeGroup: Int?

    public init(faceRegionID: Int, role: String = "loaded", rotationDeg: Int = 0,
                weightKg: Double = 10, deepestMM: Double = 3, mode: String = "both",
                curveX: FlexCurve = FlexibleFaceSettings.defaultCurve,
                curveY: FlexCurve = FlexibleFaceSettings.defaultCurve,
                curveCentreEdge: FlexCurve = FlexCurve(x: [0, 1], y: [0.3, 1]),
                skinOn: Bool = true, designStamp: FlexibleStampPlacement? = nil,
                weightFrom: UUID? = nil, shape: String? = nil, squeezeGroup: Int? = nil) {
        self.faceRegionID = faceRegionID; self.role = role; self.rotationDeg = rotationDeg
        self.weightKg = weightKg; self.deepestMM = deepestMM; self.mode = mode
        self.curveX = curveX; self.curveY = curveY; self.curveCentreEdge = curveCentreEdge
        self.skinOn = skinOn; self.designStamp = designStamp
        self.weightFrom = weightFrom; self.shape = shape; self.squeezeGroup = squeezeGroup
    }

    /// A gentle dome: soft in the middle, firmer at both ends. A starting drawing, not a
    /// recommendation — the user moves every point.
    public static let defaultCurve = FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3])

    public var weightN: Double { FlexibleUnits.newtons(kg: weightKg) }
    public var isLoaded: Bool { role == "loaded" }

    /// ★ ROUND 4 (D1): Shape [Curves | Stamp] is an either/or.
    public var isStampShape: Bool { shape == "stamp" }

    /// The ONE stamp this face is designed under — only while its shape is Stamp, and always
    /// at the face's own weight ("the face weight equals the stamp weight": one number, which
    /// a main-page group may own). nil under Curves, even when a stamp is stored.
    public var activeStamp: FlexibleStampPlacement? {
        guard isStampShape, var p = designStamp else { return nil }
        p.weightKg = weightKg
        return p
    }

    /// The squish map core reads (02 §12). ★ ROUND 4 (D1): under Stamp the curves are FLAT
    /// (the stamp sinks the deepest squish wherever it presses — core brief #10); the drawn
    /// curves stay stored for a switch back to Curves.
    public var map: FlexMap {
        if isStampShape {
            return FlexMap(mode: "both", x: .flat, y: .flat, centreEdge: curveCentreEdge, deepestMM: deepestMM)
        }
        return FlexMap(mode: mode, x: curveX, y: curveY, centreEdge: curveCentreEdge, deepestMM: deepestMM)
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
    /// ★ ROUND 4 (D1, his answer 4): the WHOLE model's finish — "none" | "rim" | "skin" |
    /// "covered" (FlexibleFinish). nil ⇒ Covered, today's default. It replaces the per-face
    /// "Solid skin" row. OPTIONAL so old projects decode.
    public var finish: String?
    /// ★ ROUND 5 (S1, his img 1: "The different groups should have different coloured faces on the
    /// model body, assigned in the settings modal"): each squeeze group's colour, keyed by its
    /// STORED group number ("1", "2" …) → a FlexibleGroupColour id. A group with no entry takes its
    /// number's default. DISPLAY ONLY: never part of the lattice's key (`designInputs`).
    /// OPTIONAL so old projects decode.
    public var groupColours: [String: String]?
    /// ★ ROUND 5 (S4, img 2: "Allow for a change of weight input: kg/lb/newtons/etc."): the unit
    /// every weight box shows — "kg" | "lb" | "N" | "kN" (FlexibleWeightUnit); nil ⇒ kg. Storage
    /// stays kgf everywhere (ForceModel's D5). DISPLAY ONLY. OPTIONAL so old projects decode.
    public var weightUnit: String?
    /// ★ ROUND 5 (S6, img 3: "All faces should be deletable"): faces he DELETED from the Flexible
    /// setup that a main-page Load / Anchor group still holds — the re-sync (`adopt`) skips them,
    /// so a deleted face stays deleted. The main-page group itself is untouched. Pressing the face
    /// again takes it off this list. OPTIONAL so old projects decode.
    public var removedRegions: [Int]?
    /// ★ ANGLED PRESSES (task 2026-10-07, AP1; FlexiblePress): tilted face presses, edges and corners.
    /// nil — never [] — when there are none (`setPresses`), so a project without presses encodes
    /// byte-identical. OPTIONAL so old projects decode.
    public var presses: [FlexiblePress]?
    /// ★ ROUND 7 (batch S, his img3 words of 2026-10-14: "their names should be editable by tapping "group 1" or whatever
    /// the default name is"): each squeeze group's NAME, keyed by its STORED group number ("1", "2" …); a group with no
    /// entry reads "Group N". DISPLAY ONLY, like `groupColours`: never part of the lattice's key (`designInputs`);
    /// carried to its new number when groups renumber (FlexibleSqueezeGroups.normalise). Settings page only — never the
    /// main page's Selections (the two lists stay separate). OPTIONAL, omitted when nil: old projects encode
    /// byte-identical.
    public var groupNames: [String: String]?
    /// ★ ROUND 7 (batch M2 — the reviewer's ruling 3 on the 2026-10-14 outbox: "FLEXIBLE-ONLY sectors carried in the job,
    /// NOT Surface-stage sectors … If I2 already writes Surface sectors, move them to Flexible-only and say what moved"):
    /// the Flexible sector store — each Flexible-only sector's NUMBER by its stable role key (FlexibleSectors: a lattice
    /// section, an edge strip, a rest); its wire id is FlexibleSectors.base + the number. The geometry is never stored: it
    /// is derived from the face-prisms and the strips every time. nil ⇒ none registered (with strips whose members carry a
    /// Surface root, I2's form — FlexibleSectorMigration reads it through). OPTIONAL, omitted when nil: old projects decode
    /// and encode byte-identical. LABELS ONLY: never part of the lattice's key (`designInputs`).
    public var sectors: FlexibleSectorStore?
    /// ★ ROUND 7 · U21 batch I (his answers of 2026-10-21 ~15:35 / ~15:45: "you can select any wall of the lattice and select any
    /// wall of the solid/non-latriced areas and link them together … you should be able to do this multiple times per lattice
    /// object"): which lattice walls are linked to the solid they touch (the Attach tool). DISPLAY SIM ONLY: never part of the
    /// lattice's key (`designInputs`), never in a job (CORE LIST item 10). nil — never [] — when there are none, so a project
    /// without links encodes byte-identical. OPTIONAL so old projects decode. No geometry is stored: the walls are re-derived.
    public var links: [FlexibleLatticeLink]?
    // ★ ROUND 7 (his ruling 2026-10-18): R7-D2's lattice-only set is WITHDRAWN — a lattice face is always protected from
    // Topology, so no main-page group carries a lattice role without Protect. No build ever wrote the key (nil was never
    // encoded); a project.json that carried it would still open (the key is ignored) — FlexibleLatticeIsProtectedTests.
    /// ★ ROUND 7 · U21 (batch A, his Img7 of 2026-10-21: "I don't think there should be any automatic squish/rest selections
    /// whatsoever. Please remove them from *new* models coming in."): whether the scene's open reads the main page's Load /
    /// Anchor groups in as pressed / resting faces. nil ⇒ saved before 10-21 (his pad, his bracket): the read-in stays, so
    /// they keep what they have. false ⇒ a new setup (`newSetup`, both doors: New TopOpt's Flexible tab and the mode modal's
    /// Flexible): nothing is read in; a face he presses himself still takes its Load group's weight and re-syncs it. OPTIONAL,
    /// omitted when nil (old projects encode byte-identical); never part of the lattice's key (`designInputs`).
    public var readsMainPageGroups: Bool?
    /// ★ ROUND 7 · MANUAL, part M1 (his orders of 2026-10-22 ~02:30: "implement the manual add-on. Remove any of the auto processes
    /// and make it as simple to understand as possible"; his picks: "SCOPE = whole part (lattice type, cell size, density % / walls in
    /// beads) + optional per-group override"): the lattice HE sets. nil ⇒ Auto, never touched (every save before it decodes, and
    /// Auto's job bytes and lattice key are unchanged). `on == false` ⇒ Auto, his values kept for later. Only the APP reads it: the
    /// lattice on screen, the sims and the views (CORE LIST item 11 — a Flexible job carries no fixed lattice). In the lattice's key
    /// (`designInputs`) only while on. OPTIONAL, omitted when nil.
    public var manual: FlexibleManualSettings?
    /// ★ ROUND 7 · NOZZLE GRADE (his words of 2026-10-23 ~03:05, verbatim: "temperature also needs a grade... also, what's the
    /// difference between "temperature" and "nozzle" shouldn't they be the same???" then "Temperature needs a grade **option**"):
    /// the nozzle temperature graded up the BUILD HEIGHT (a nozzle only changes temperature between layers). DISPLAY SIM ONLY, in
    /// Auto and Manual: never part of the lattice's key (`designInputs`), never in a job (CORE LIST: per-layer nozzle temperature
    /// in the job/export) — Auto's job bytes are unchanged. OPTIONAL, omitted when nil (old projects encode byte-identical).
    public var nozzleGrade: FlexibleNozzleGrade?

    /// ★ ROUND 7 · U21 (batch A): a brand-new Flexible setup — nothing read in from the Topology page (his Img7).
    public static func newSetup(materialID: String? = nil) -> FlexibleStageSettings {
        var s = FlexibleStageSettings(materialID: materialID)
        s.readsMainPageGroups = false
        return s
    }

    public init(materialID: String? = nil, nozzleTempC: Double? = nil, topology: String = "auto",
                feel: String = "springy", beadsPerWall: Int = 1,
                faces: [FlexibleFaceSettings] = [], checkStamps: [FlexibleCheckStamp] = [],
                curveConvention: Int? = FlexibleSettingsMigration.currentCurveConvention,
                finish: String? = nil) {
        self.materialID = materialID; self.nozzleTempC = nozzleTempC; self.topology = topology
        self.feel = feel; self.beadsPerWall = beadsPerWall; self.faces = faces
        self.checkStamps = checkStamps; self.curveConvention = curveConvention
        self.finish = finish
    }

    /// ★ ROUND 5: the settings WITHOUT the display-only choices (group colours, the weight unit) —
    /// what the designs and the lattice are built from. A colour or a unit changes the page, never
    /// the lattice: the lattice's key and the pipeline's comparison read this.
    public var designInputs: FlexibleStageSettings {
        var c = self
        c.groupColours = nil
        c.groupNames = nil   // ★ ROUND 7 (S): a name is display only
        c.sectors = nil      // ★ ROUND 7 (M2): numbers are labels; the geometry reaches the lattice through the scene key
        c.weightUnit = nil
        c.readsMainPageGroups = nil   // ★ U21 (batch A): how the open reads the main page, not an input of the lattice
        c.manual = c.manual?.on == true || Self.controlManualOffInDesignInputs ? c.manual : nil   // ★ MANUAL (M1): Auto keys as before
        c.nozzleGrade = nil   // ★ NOZZLE GRADE: the display sim's per-layer temperature — never the lattice's key, never a job
        c.links = Self.controlLinksInDesignInputs ? c.links : nil   // ★ U21 (batch I): a link tells the sim what holds the lattice — never the lattice's key
        // ★ R7-E2 (AP9): an edge or corner press (a flat prism) is built into the lattice now — core builds its stack, designs it,
        // grades the lattice along its arrow — so its every edit re-keys the lattice. A press that is never sent (AP1's tilted
        // face press: no flat prism) still cannot change it, and a project without presses keys as before (nil either way).
        let flat = (c.presses ?? []).filter { $0.strip != nil }
        // ★ R7-E2 PARKED (FlexibleBackend.sendsPresses off): E1's rule — no press reaches the lattice's key
        c.presses = flat.isEmpty || Self.controlStripPresses || !FlexibleBackend.sendsPresses ? nil : flat
        return c
    }

    /// ★ RED CONTROL only (FlexibleR7E2Tests — FlexibleStageModel.controlStripPresses): E1's rule, the presses out of the lattice's key.
    nonisolated(unsafe) static var controlStripPresses = false
    /// ★ RED CONTROL only (FlexibleI2AttachTests): the links left in the lattice's key (a link would rebuild the lattice).
    nonisolated(unsafe) static var controlLinksInDesignInputs = false
    /// ★ RED CONTROL only (FlexibleM1ManualTests): his manual values kept in the lattice's key while Auto is on.
    nonisolated(unsafe) static var controlManualOffInDesignInputs = false

    /// ★ MANUAL (M1): Manual is on.
    public var isManual: Bool { manual?.on == true }

    /// The model-wide finish (nil or an unknown value ⇒ Covered).
    public var finishMode: FlexibleFinish { finish.flatMap(FlexibleFinish.init(rawValue:)) ?? .covered }

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

    /// ★ ROUND 5 (S6): is this face deleted from the Flexible setup (a main-page group still holds it)?
    public func isRemoved(_ region: Int) -> Bool { removedRegions?.contains(region) ?? false }

}

/// ★ ROUND 7 · U21 batch I: one link of a lattice wall to the solid it touches (the Attach tool). `lattice` is the face-prism's
/// selectable key ("f:<group>:<face>"); `wall` a FlexibleLatticeWalls key ("side:f1", "side:f1.2", "side:e3", "hole:f9",
/// "floor"); `target` "wall" | "under" | "skin:f7".
public struct FlexibleLatticeLink: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var lattice: String
    public var wall: String
    public var target: String
    public init(id: UUID = UUID(), lattice: String, wall: String, target: String) {
        self.id = id; self.lattice = lattice; self.wall = wall; self.target = target
    }
}

/// ★ ROUND 7 (M2): the Flexible-only sectors' numbers (FlexibleSectors) — `ids` maps a sector's stable ROLE key to its
/// number; numbers are never reused, so no stale design, stack or setting can attach to a recycled id.
public struct FlexibleSectorStore: Codable, Equatable, Hashable, Sendable {
    /// 1 = Flexible-only sectors (the version marker: a project with this store is never I2's Surface form).
    public static let currentVersion = 1
    public var version: Int
    public var ids: [String: Int]
    public init(version: Int = FlexibleSectorStore.currentVersion, ids: [String: Int] = [:]) {
        self.version = version; self.ids = ids
    }
}
