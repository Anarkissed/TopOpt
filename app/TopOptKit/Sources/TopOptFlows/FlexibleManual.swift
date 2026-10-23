// FlexibleManual — round 7, MANUAL: the lattice HE sets (task 2026-09-29-flexible-screens).
//
// His orders of 2026-10-22 ~02:30 (verbatim): "implement the manual add-on. Remove any of the auto processes and make it as simple
// to understand as possible. The views become what the app assumes based on your values, so cards should say that when a view is
// selected. Stay with the design philosophy of the new UI. Just because it's manual doesn't mean we want it to look like shit."
// ★ P1 (his notes of 2026-10-23 ~00:00: "Each lattice should have the same set of settings as the entire model, otherwise, what is
// the point? … If we are saying this is going to be a manual implementation of the lattice, then we should GIVE them a manual
// implementation of the lattice, not a whole section for 3 options!"; his decisions ~00:35): the SAME full set for the whole part
// and for each group — Type; Walls in WHOLE beads (1–3); a linked trio Density % ⇄ Cell size ⇄ Cells across; a Grade (on density or
// on cell, from → to, along the depth / across the face / his curve; Default or Stepped); a facts line; and (part only) Temperature.
//
// ★ APP SIDE ONLY. Core's Flexible job has no key for a fixed lattice, so the job is byte-for-byte Auto's in both modes and Manual's
// lattice lives here: the field on screen (preview, Save & Exit's build) and the sims read it (CORE LIST items 11, 13).
// ★ ONE RELATION, core's: cell = beads · unit / ρ with unit = flexible_cell_size_mm(type, ρ = 1, 1 bead, bead width) (gyroid
// 3.0915 · bead, honeycomb 2 · bead). P1: the walls are HIS whole-bead choice and the density is FREE — the CELL follows. Editing the
// cell (or the cells across) moves the density at his beads. A fractional bead cannot happen (M1's warning is gone).

import Foundation
import simd
import TopOptKit

/// ★ P1: a lattice's grade — what it moves (density or cell; the other follows at his walls), where it ends, and along what.
public struct FlexibleManualGrade: Codable, Equatable, Hashable, Sendable {
    public var on: Bool
    /// "density" | "cell"
    public var by: String
    /// The density at the grade's END; its start ("From") is the lattice's own density.
    public var toDensity: Double
    /// "depth" (from the pressed face through the lattice) | "across" (from the face's middle to its rim) | "curve" (from where his
    /// curve is flat to where it is deepest)
    public var along: String
    public init(on: Bool = false, by: String = "density", toDensity: Double, along: String = "depth") {
        self.on = on; self.by = by; self.toDensity = toDensity; self.along = along
    }
}

/// One lattice he sets: its type, walls (whole beads), density (core's density, 0…1; with a grade on, its start), grade and style.
/// The cell follows (FlexibleManualMath.cellMM).
public struct FlexibleManualLattice: Codable, Equatable, Hashable, Sendable {
    /// "gyroid" | "honeycomb" (no Auto in Manual)
    public var topology: String
    /// Walls in whole beads, 1…3.
    public var beads: Int
    public var density: Double
    public var grade: FlexibleManualGrade
    /// Grade style: false Default (smooth), true Stepped.
    public var stepped: Bool
    /// ★ An OLD (M1) save only: the cell M1 stored; the model maps it to a density at 1 bead (FlexibleManualSettings.resolved).
    public var legacyCellMM: Double?

    public init(topology: String, beads: Int = 1, density: Double, grade: FlexibleManualGrade? = nil, stepped: Bool = false) {
        self.topology = topology; self.beads = min(max(beads, 1), 3); self.density = density
        self.grade = grade ?? FlexibleManualGrade(toDensity: density); self.stepped = stepped; self.legacyCellMM = nil
    }

    enum K: String, CodingKey { case topology, beads, density, grade, stepped, cellMM }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        topology = try c.decode(String.self, forKey: .topology)
        density = try c.decode(Double.self, forKey: .density)
        if let b = try c.decodeIfPresent(Int.self, forKey: .beads) {
            beads = min(max(b, 1), 3)
            grade = try c.decodeIfPresent(FlexibleManualGrade.self, forKey: .grade) ?? FlexibleManualGrade(toDensity: density)
            stepped = try c.decodeIfPresent(Bool.self, forKey: .stepped) ?? false
            legacyCellMM = nil
        } else {
            // ★ an M1 save {topology, cellMM, density}: kept as it was until the model maps it (its next edit writes the new form)
            beads = 1
            grade = FlexibleManualGrade(toDensity: density)
            stepped = false
            legacyCellMM = try c.decodeIfPresent(Double.self, forKey: .cellMM) ?? 0
        }
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(topology, forKey: .topology)
        if let old = legacyCellMM {   // an unmapped M1 save writes back exactly as it was read
            try c.encode(old, forKey: .cellMM)
            try c.encode(density, forKey: .density)
            return
        }
        try c.encode(beads, forKey: .beads)
        try c.encode(density, forKey: .density)
        try c.encode(grade, forKey: .grade)
        try c.encode(stepped, forKey: .stepped)
    }
}

/// ★ MANUAL: what the Squish page's Manual saves (FlexibleStageSettings.manual).
public struct FlexibleManualSettings: Codable, Equatable, Hashable, Sendable {
    /// Manual is on (false: Auto, these values kept for later).
    public var on: Bool
    /// The whole part's lattice.
    public var part: FlexibleManualLattice
    /// A group's own lattice, keyed by its STORED group number ("1", "2" …, as groupNames); nil — never [:] — when none.
    public var groups: [String: FlexibleManualLattice]?
    /// ★ P1: the part-wide nozzle temperature in Manual (no Auto; never the job's — Auto's own setting is untouched). nil: an M1
    /// save — the model reads Auto's temperature until he picks one.
    public var tempC: Double?

    public init(on: Bool, part: FlexibleManualLattice, groups: [String: FlexibleManualLattice]? = nil, tempC: Double? = nil) {
        self.on = on; self.part = part; self.groups = groups; self.tempC = tempC
    }

    /// The lattice of the group stored as `groupID` (its own, else the part's); nil: the part's.
    public func lattice(group groupID: Int?) -> FlexibleManualLattice {
        guard let g = groupID, let own = groups?[String(g)] else { return part }
        return own
    }
    public func hasOwn(group groupID: Int) -> Bool { groups?[String(groupID)] != nil }

    /// ★ P1, OLD SAVES MAP (nothing jumps): an M1 part keeps its CELL at 1 bead (density = unit / cell); an M1 group was DRAWN at the
    /// part's type and walls with its own density (cell = unit · w_part / ρ_g), so it keeps that drawn cell at 1 bead too
    /// (density = ρ_g / w_part). New values pass unchanged.
    public func resolved(beadWidthMM bw: Double) -> FlexibleManualSettings {
        var out = self
        let old = part
        if let c = old.legacyCellMM {
            let u = FlexibleManualMath.unitCellMM(old.topology, beadWidthMM: bw)
            out.part = FlexibleManualLattice(topology: old.topology, beads: 1,
                                             density: FlexibleManualMath.clampDensity(c > 0 && u > 0 ? u / c : old.density))
        }
        if let gs = groups {
            var m: [String: FlexibleManualLattice] = [:]
            for (k, g) in gs {
                guard g.legacyCellMM != nil else { m[k] = g; continue }
                let u = FlexibleManualMath.unitCellMM(old.topology, beadWidthMM: bw)
                let wPart = old.legacyCellMM.map { u > 0 ? $0 * old.density / u : 1 } ?? Double(old.beads)
                m[k] = FlexibleManualLattice(topology: out.part.topology, beads: 1,
                                             density: FlexibleManualMath.clampDensity(g.density / Swift.max(wPart, 1e-6)))
            }
            out.groups = m
        }
        return out
    }

    /// Each group's own lattice to its new number (FlexibleSqueezeGroups.normalise); a group gone drops it.
    static func remap(_ g: [String: FlexibleManualLattice]?, rank: [Int: Int]) -> [String: FlexibleManualLattice]? {
        guard let g, !g.isEmpty else { return nil }
        var out: [String: FlexibleManualLattice] = [:]
        for (k, v) in g { if let old = Int(k), let n = rank[old] { out[String(n)] = v } }
        return out.isEmpty ? nil : out
    }
}

/// ★ MANUAL: the one relation between type, walls, density and cell (core's `cell_size_mm`, through the bridge).
public enum FlexibleManualMath {
    /// The densities he may set (and the lattice field draws: FlexibleLatticeField clamps ρ to 0.05…0.9).
    public static let densityRange: ClosedRange<Double> = 0.05...0.9
    /// What the preview draws well (a cell outside it is said in the facts line, never blocked).
    public static let cellRange: ClosedRange<Double> = 2...60
    public static let beadsRange: ClosedRange<Int> = 1...3

    public static func clampDensity(_ r: Double) -> Double {
        r.isFinite ? min(max(r, densityRange.lowerBound), densityRange.upperBound) : 0.2
    }

    /// The cell of a 1-bead wall at ρ = 1 (core's relation): gyroid 3.0915 · bead, honeycomb 2 · bead.
    public static func unitCellMM(_ topology: String, beadWidthMM bw: Double) -> Double {
        (try? FlexibleCore.cellSizeMM(topology: topology, density: 1, beadsPerWall: 1, beadWidthMM: bw)) ?? 0
    }
    /// ★ P1: the cell at `density` with `beads` walls: beads · unit / ρ.
    public static func cellMM(density rho: Double, beads: Int, topology: String, beadWidthMM bw: Double) -> Double {
        Double(beads) * unitCellMM(topology, beadWidthMM: bw) / Swift.max(rho, 1e-6)
    }
    public static func cellMM(_ l: FlexibleManualLattice, beadWidthMM bw: Double) -> Double {
        cellMM(density: l.density, beads: l.beads, topology: l.topology, beadWidthMM: bw)
    }
    /// ★ P1: the density whose cell is `cellMM` at `beads` walls: beads · unit / cell (clamped to what can be set).
    public static func density(cellMM: Double, beads: Int, topology: String, beadWidthMM bw: Double) -> Double {
        guard cellMM > 0 else { return densityRange.lowerBound }
        return clampDensity(Double(beads) * unitCellMM(topology, beadWidthMM: bw) / cellMM)
    }
    /// The walls in mm (what the field draws: beads × the bead width).
    public static func wallMM(_ l: FlexibleManualLattice, beadWidthMM bw: Double) -> Double { Double(l.beads) * bw }
    /// Cells across a lattice `depthMM` deep.
    public static func cellsAcross(_ l: FlexibleManualLattice, depthMM: Double, beadWidthMM bw: Double) -> Double {
        let c = cellMM(l, beadWidthMM: bw)
        return c > 0 ? depthMM / c : 0
    }

    /// ★ RED CONTROL only (FlexibleManualP1Tests): M1's tie — a density edit keeps the CELL and the walls follow, fractional.
    public static func m1Walls(cellMM: Double, density: Double, topology: String, beadWidthMM bw: Double) -> Double {
        let u = unitCellMM(topology, beadWidthMM: bw)
        return u > 0 ? cellMM * density / u : 0
    }

    /// A 1-bead lattice at density `rho` (Manual's seed: Auto's type and mean density).
    public static func oneBead(topology: String, density rho: Double) -> FlexibleManualLattice {
        FlexibleManualLattice(topology: topology, beads: 1, density: clampDensity(rho))
    }

    // MARK: the edits (his walls stay whole; the density is free; the cell follows)

    /// The type: the density and the walls kept, the cell follows.
    public static func withType(_ l: FlexibleManualLattice, _ topology: String) -> FlexibleManualLattice {
        var out = l; out.topology = topology == "honeycomb" ? "honeycomb" : "gyroid"; return out
    }
    /// The walls (whole beads, 1…3): the density kept, the cell follows.
    public static func withBeads(_ l: FlexibleManualLattice, _ beads: Int) -> FlexibleManualLattice {
        var out = l; out.beads = min(max(beads, beadsRange.lowerBound), beadsRange.upperBound); return out
    }
    public static func withDensity(_ l: FlexibleManualLattice, _ rho: Double) -> FlexibleManualLattice {
        var out = l; out.density = clampDensity(rho); return out
    }
    /// The cell: the density moves at his walls.
    public static func withCell(_ l: FlexibleManualLattice, _ mm: Double, beadWidthMM bw: Double) -> FlexibleManualLattice {
        var out = l; out.density = density(cellMM: mm, beads: l.beads, topology: l.topology, beadWidthMM: bw); return out
    }
    /// Cells across a lattice `depthMM` deep: cell = depth / n, the density moves at his walls.
    public static func withCellsAcross(_ l: FlexibleManualLattice, _ n: Double, depthMM: Double, beadWidthMM bw: Double) -> FlexibleManualLattice {
        guard n > 0, depthMM > 0 else { return l }
        return withCell(l, depthMM / n, beadWidthMM: bw)
    }

    // MARK: the grade

    /// The grade's end in its own terms: a density (0…1) or a cell (mm).
    public static func gradeValue(_ l: FlexibleManualLattice, end: Bool, beadWidthMM bw: Double) -> Double {
        let rho = end ? l.grade.toDensity : l.density
        return l.grade.by == "cell" ? cellMM(density: rho, beads: l.beads, topology: l.topology, beadWidthMM: bw) : rho
    }
    /// Set the grade's From (`end` false: the lattice's own density) or To, in the grade's own terms.
    public static func withGradeValue(_ l: FlexibleManualLattice, end: Bool, _ v: Double, beadWidthMM bw: Double) -> FlexibleManualLattice {
        let rho = l.grade.by == "cell" ? density(cellMM: v, beads: l.beads, topology: l.topology, beadWidthMM: bw) : clampDensity(v)
        var out = l
        if end { out.grade.toDensity = rho } else { out.density = rho }
        return out
    }

    /// The density at `s` (0 the grade's start, 1 its end) — the lattice's own density with the grade off. By cell: the CELL moves
    /// evenly and the density follows; Stepped: `steps` flat bands, the first at From, the last at To.
    public static func density(_ l: FlexibleManualLattice, at s: Double, steps: Int, beadWidthMM bw: Double) -> Double {
        guard l.grade.on else { return l.density }
        var x = min(max(s.isFinite ? s : 0, 0), 1)
        if l.stepped {
            let n = Double(Swift.max(steps, 2))
            x = min((x * n).rounded(.down), n - 1) / (n - 1)
        }
        if l.grade.by == "cell" {
            let a = cellMM(density: l.density, beads: l.beads, topology: l.topology, beadWidthMM: bw)
            let b = cellMM(density: l.grade.toDensity, beads: l.beads, topology: l.topology, beadWidthMM: bw)
            return density(cellMM: a + (b - a) * x, beads: l.beads, topology: l.topology, beadWidthMM: bw)
        }
        return clampDensity(l.density + (l.grade.toDensity - l.density) * x)
    }
    /// Every density the lattice holds (its own; with a grade on, From … To).
    public static func densitySpan(_ l: FlexibleManualLattice) -> ClosedRange<Double> {
        guard l.grade.on else { return l.density...l.density }
        return min(l.density, l.grade.toDensity)...max(l.density, l.grade.toDensity)
    }
    /// Stepped's band count: the whole cells through `depthMM` (2…8).
    public static func steps(_ l: FlexibleManualLattice, depthMM: Double, beadWidthMM bw: Double) -> Int {
        min(8, Swift.max(2, Int(cellsAcross(l, depthMM: depthMM, beadWidthMM: bw).rounded())))
    }
}

/// ★ MANUAL: every line Manual adds (one line each, ≤ 44 characters — FlexibleRowCopy.maxChars).
public enum FlexibleManualCopy {
    public static let manual = "Manual"
    public static let auto = "Auto"
    public static let modeOptions: [(id: String, label: String)] = [("manual", manual), ("auto", auto)]
    public static let title = "Lattice · you set it"
    public static let lattice = "Type"
    public static let typeOptions: [(id: String, label: String)] = [("gyroid", "Gyroid"), ("honeycomb", "Honeycomb")]
    public static let cell = "Cell size"
    public static let density = "Density"
    public static let cellsAcross = "Cells across"
    public static let walls = "Walls"
    public static let wallsOptions: [(id: String, label: String)] = [("1", "1 bead"), ("2", "2 beads"), ("3", "3 beads")]
    /// The walls' unit for a count: "bead" at exactly 1, else "beads".
    public static func wallsUnitFor(_ shown: Double) -> String { shown == 1 ? "bead" : "beads" }
    public static let grade = "Grade"
    public static let gradeOptions: [(id: String, label: String)] = [("off", "Off"), ("on", "On")]
    public static let gradeBy = "Grade by"
    public static let gradeByOptions: [(id: String, label: String)] = [("density", "Density"), ("cell", "Cell")]
    public static let from = "From"
    public static let to = "To"
    public static let along = "Along"
    public static let alongOptions: [(id: String, label: String)] = [("depth", "Depth"), ("across", "Across"), ("curve", "Curve")]
    public static let style = "Style"
    public static let styleOptions: [(id: String, label: String)] = [("default", "Default"), ("stepped", "Stepped")]
    public static let temperature = "Temperature"
    public static let sameAsPart = "Lattice · same as the part"
    public static let ownLattice = "Lattice · its own"
    public static let setOwn = "Set its own"
    public static let useParts = "Use the part's"

    /// ★ P1, THE FACTS LINE (his 10-17 rule: at least 2 cells through the depth): "2.6 cells across · walls 0.45 mm".
    public static func cellsLine(_ n: Double?, wallMM: Double) -> String {
        let w = String(format: "walls %.2f mm", wallMM)
        guard let n else { return FlexibleRowCopy.fit("Cells across · no prism yet · " + w) }
        return FlexibleRowCopy.fit(String(format: "%.1f cells across the depth · ", n) + w)
    }
    public static let underTwoCells = "Under 2 cells across the depth"
    public static let cellOutsideDrawn = "Cell past what the preview draws (2–60 mm)"
    /// "Data covers 14–36 %" / "Estimate past tested data (14–36 %)".
    public static func dataLine(min lo: Double, max hi: Double, past: Bool) -> String {
        let span = String(format: "%.0f–%.0f %%", lo * 100, hi * 100)
        return past ? "Estimate past tested data (\(span))" : "Data covers \(span)"
    }

    /// ★ "The views become what the app assumes based on your values, so cards should say that when a view is selected": the
    /// one line for the views on (Bend, Play, X-ray's bend prism, Heat — the first of them), nil in Auto or with none on.
    /// ★ MANUAL (M2): `mm` — the playing group's deepest estimate once its sim landed ("Bend · estimate ≈ 1.4 mm at 5 lb").
    public static func viewLine(views: FlexibleStageViews, manual: Bool, weight: String?, mm: Double? = nil) -> String? {
        guard manual else { return nil }
        let at = weight.map { " at \($0)" } ?? ""
        let what = mm.map { String(format: "estimate \u{2248} %.1f mm", $0) } ?? "what your lattice does"
        if views.contains(.bend) { return FlexibleRowCopy.fit("Bend · " + what + at) }
        if views.contains(.play) { return FlexibleRowCopy.fit("Play · " + what + at) }
        if views.contains(.xray) { return FlexibleRowCopy.fit("X-ray · bend estimated from your lattice") }
        if !views.contains(.heatOff) { return FlexibleRowCopy.fit("Heat · estimated from your lattice") }
        return nil
    }

    public enum Info {
        public static let mode = "Auto designs the lattice from your curves. Manual: you set the lattice — type, walls, density or cell size, and a grade — and the views show what the app expects that lattice to do under your squeeze. Your values are kept when you switch back."
        public static let lattice = "Gyroid: springy, bounces back. Honeycomb: firmer, soaks up the push."
        public static let walls = "Wall thickness in printed beads — always whole beads. Change it and the density stays; the cell size follows."
        public static let density = "How much of the lattice is solid. More is firmer. Set any density: the cell size follows at your walls."
        public static let cell = "The size of one repeat of the lattice. Set it and the density follows at your walls."
        public static let cellsAcross = "How many cells fit through this lattice's depth (its face-prisms). Set it and the cell size and density follow. Under 2 is too few to squish evenly."
        public static let grade = "Off: one density everywhere. On: the lattice changes from your value above (From) to To — by density (the cell follows) or by cell size (the density follows)."
        public static let along = "Depth: from the pressed face through the lattice. Across: from the face's middle to its rim. Curve: from where your curve is flat to where it is deepest."
        public static let style = "Default changes smoothly. Stepped changes in flat bands, one per cell through the depth."
        public static let temperature = "The nozzle temperature the squish estimate uses (its tested curves). Manual has no Auto."
        public static let facts = "What your values make: cells through the depth (at least 2), the wall in mm, and the densities the tested data covers — past them the estimate is extended from the data's own trend."
        public static let group = "This group can have its own lattice — the same settings as the part. Otherwise it uses the part's."
    }
}

/// ★ MANUAL: the lattice field from his values — every lattice voxel of core's field takes the density, walls and type of the group
/// that owns it (its own lattice, else the part's), with his grade laid along its stack; the mask and the owners are core's. Pure.
public enum FlexibleManualField {
    /// What a voxel owner's stack gives the grade: its stack (and cuts), and his drawn curve per column (0 flat … 1 deepest; nil:
    /// none — a press — then Curve reads as Depth).
    public struct Owner: Sendable {
        public let stack: FlexStackInfo
        public let cuts: [RegionCut]
        public let curve: [Double]?
        public init(stack: FlexStackInfo, cuts: [RegionCut] = [], curve: [Double]? = nil) {
            self.stack = stack; self.cuts = cuts; self.curve = curve
        }
    }

    public struct Built: Sendable {
        public let field: FlexDensityField
        /// Per voxel: the wall in mm (0 off the lattice).
        public let wallMM: [Float]
        /// Per voxel: 0 gyroid, 1 honeycomb.
        public let type: [Float]
    }

    /// `ownerGroups`: a voxel owner (a face or press region, as core names it) → its stored group number.
    public static func build(_ f: FlexDensityField, manual m: FlexibleManualSettings, ownerGroups: [Int: Int],
                             owners: [Int: Owner] = [:], beadWidthMM bw: Double) -> Built {
        var d = f.density
        var wall = [Float](repeating: 0, count: d.count), type = [Float](repeating: 0, count: d.count)
        struct Geo { let centre: SIMD2<Double>; let rMax: Double; let steps: Int; let depth: Double }
        var geo: [Int: Geo] = [:]
        func lattice(_ o: Int) -> FlexibleManualLattice { m.lattice(group: ownerGroups[o]) }
        func geometry(_ o: Int, _ ow: Owner, _ l: FlexibleManualLattice) -> Geo {
            if let g = geo[o] { return g }
            let cols = ow.stack.columns.filter { $0.latticeMM > 0 }
            var c = SIMD2<Double>.zero
            for col in cols { c += SIMD2(col.uMM, col.vMM) }
            c /= Double(Swift.max(cols.count, 1))
            let r = cols.map { simd_length(SIMD2($0.uMM, $0.vMM) - c) }.max() ?? 0
            let depth = cols.isEmpty ? 0 : cols.map(\.latticeMM).reduce(0, +) / Double(cols.count)
            let g = Geo(centre: c, rMax: r, steps: FlexibleManualMath.steps(l, depthMM: depth, beadWidthMM: bw), depth: depth)
            geo[o] = g
            return g
        }
        for v in d.indices where d[v] >= 0 {
            let o = v < f.owner.count ? f.owner[v] : -1
            let l = lattice(o)
            var rho = l.density
            if l.grade.on, let ow = owners[o] {
                let i = v % f.nx, j = (v / f.nx) % f.ny, k = v / (f.nx * f.ny)
                let p = f.origin + SIMD3<Double>(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * f.spacing
                let g = geometry(o, ow, l)
                var s = 0.0
                if let hit = FlexibleStackMembership.hit(p, ow.stack, cuts: ow.cuts) {
                    let col = ow.stack.columns[hit.col]
                    let along = l.grade.along == "curve" && ow.curve == nil ? "depth" : l.grade.along
                    switch along {
                    case "across": s = g.rMax > 1e-9 ? simd_length(SIMD2(col.uMM, col.vMM) - g.centre) / g.rMax : 0
                    case "curve": s = hit.col < (ow.curve?.count ?? 0) ? ow.curve![hit.col] : 0
                    default: s = hit.depth / Swift.max(col.latticeMM > 0 ? col.latticeMM : col.exitT - col.entryT, 1e-9)
                    }
                }
                rho = FlexibleManualMath.density(l, at: s, steps: g.steps, beadWidthMM: bw)
            }
            d[v] = Float(rho)
            wall[v] = Float(FlexibleManualMath.wallMM(l, beadWidthMM: bw))
            type[v] = l.topology == "honeycomb" ? 1 : 0
        }
        return Built(field: FlexDensityField(nx: f.nx, ny: f.ny, nz: f.nz, spacing: f.spacing, origin: f.origin, density: d, owner: f.owner),
                     wallMM: wall, type: type)
    }

    /// The densities only (FlexibleM1ManualTests' M1 entry point, kept).
    public static func field(_ f: FlexDensityField, manual: FlexibleManualSettings, ownerGroups: [Int: Int]) -> FlexDensityField {
        build(f, manual: manual, ownerGroups: ownerGroups, beadWidthMM: 0.45).field
    }
}

extension FlexibleStageModel {
    /// ★ MANUAL (M1): Manual is on.
    public var isManual: Bool { settings.isManual }
    var manualBeadWidthMM: Double { project.printParams.strutLineWidthMM }

    /// ★ RED CONTROL only (FlexibleM1ManualTests): the lattice built from core's design in Manual (his values ignored).
    nonisolated(unsafe) static var controlManualLatticeOff = false
    /// ★ RED CONTROL only (FlexibleManualP1Tests): M1's one lattice per part — the part's type and walls drawn everywhere (a group's
    /// own type / walls on its card, not on the part: today's mismatch).
    nonisolated(unsafe) static var controlOneLatticePerPart = false
    /// ★ RED CONTROL only (FlexibleManualP1Tests): M1's tie — a density edit keeps the cell, the walls follow (fractional beads).
    nonisolated(unsafe) static var controlM1Tie = false
    @MainActor static var controlHeldCell: [String: Double] = [:]

    /// The toggle. Switching on starts from what Auto last designed (its type, the lattice's mean density, 1 bead, Auto's
    /// temperature) so nothing jumps; his values kept from before win. Off keeps them for later.
    public func setManual(_ on: Bool) {
        guard on != isManual else { return }
        let seed = settings.manual == nil && on ? manualSeed() : nil
        let temp = designTempC
        actionSerial += 1
        edit { s in
            if let seed { s.manual = FlexibleManualSettings(on: true, part: seed, tempC: temp) } else { s.manual?.on = on }
        }
    }

    /// What Auto last designed, as one uniform lattice: Auto's type, the built lattice's mean density, 1-bead walls.
    func manualSeed() -> FlexibleManualLattice {
        let top = designTopology == "honeycomb" ? "honeycomb" : "gyroid"
        var rho = 0.2
        if let i = lattice?.inputs {
            var sum = 0.0, n = 0
            for (v, m) in zip(i.rho.values, i.mask.values) where m > 0.5 { sum += Double(v); n += 1 }
            if n > 0 { rho = sum / Double(n) }
        }
        return FlexibleManualMath.oneBead(topology: top, density: rho)
    }

    /// ★ P1: Manual's values with an old (M1) save mapped (FlexibleManualSettings.resolved); nil in Auto.
    public var manualSettings: FlexibleManualSettings? {
        guard let m = settings.manual, m.on else { return nil }
        return m.resolved(beadWidthMM: manualBeadWidthMM)
    }

    /// The lattice shown on a Manual row: the group's own (or the part's) — the SAME numbers the field draws; nil in Auto.
    public func manualLattice(group groupID: Int?) -> FlexibleManualLattice? { manualSettings?.lattice(group: groupID) }

    /// Change the part's lattice (`group` nil) or a group's own (an old save is written in the new form on its first edit).
    public func editManual(group groupID: Int?, _ change: (FlexibleManualLattice) -> FlexibleManualLattice) {
        guard let m = manualSettings else { return }
        let next = change(m.lattice(group: groupID))
        actionSerial += 1
        edit { s in
            s.manual = m.resolvedKeeping(on: s.manual?.on ?? true)
            if let g = groupID, m.hasOwn(group: g) { s.manual?.groups?[String(g)] = next }
            else if groupID == nil { s.manual?.part = next }
        }
    }
    private func manualKey(_ g: Int?) -> String { g.map { "g\($0)" } ?? "part" }
    public func setManualType(_ t: String, group: Int?) { editManual(group: group) { FlexibleManualMath.withType($0, t) } }
    public func setManualBeads(_ n: Int, group: Int?) { editManual(group: group) { FlexibleManualMath.withBeads($0, n) } }
    public func setManualDensity(_ rho: Double, group: Int?) {
        if Self.controlM1Tie, Self.controlHeldCell[manualKey(group)] == nil, let c = manualCellMM(group: group) { Self.controlHeldCell[manualKey(group)] = c }
        editManual(group: group) { FlexibleManualMath.withDensity($0, rho) }
    }
    public func setManualCell(_ mm: Double, group: Int?) {
        let bw = manualBeadWidthMM
        Self.controlHeldCell[manualKey(group)] = nil
        editManual(group: group) { FlexibleManualMath.withCell($0, mm, beadWidthMM: bw) }
    }
    public func setManualCellsAcross(_ n: Double, group: Int?) {
        guard let d = manualDepthMM(group: group) else { return }
        let bw = manualBeadWidthMM
        editManual(group: group) { FlexibleManualMath.withCellsAcross($0, n, depthMM: d, beadWidthMM: bw) }
    }
    public func setManualGrade(on: Bool, group: Int?) {
        editManual(group: group) { l in
            var o = l; o.grade.on = on
            if on, abs(o.grade.toDensity - o.density) < 1e-9 { o.grade.toDensity = FlexibleManualMath.clampDensity(o.density * 1.5) }
            return o
        }
    }
    public func setManualGradeBy(_ by: String, group: Int?) { editManual(group: group) { var o = $0; o.grade.by = by == "cell" ? "cell" : "density"; return o } }
    public func setManualGradeAlong(_ a: String, group: Int?) { editManual(group: group) { var o = $0; o.grade.along = a; return o } }
    public func setManualGradeValue(end: Bool, _ v: Double, group: Int?) {
        let bw = manualBeadWidthMM
        editManual(group: group) { FlexibleManualMath.withGradeValue($0, end: end, v, beadWidthMM: bw) }
    }
    public func setManualStepped(_ on: Bool, group: Int?) { editManual(group: group) { var o = $0; o.stepped = on; return o } }

    /// ★ P1: the part-wide temperature in Manual (Auto's own setting untouched).
    public func setManualTemp(_ t: Double) {
        guard let m = manualSettings else { return }
        actionSerial += 1
        edit { s in s.manual = m.resolvedKeeping(on: true); s.manual?.tempC = t }
    }
    /// The temperature Manual's estimate uses: his, else Auto's.
    public var manualTempC: Double? { manualSettings?.tempC ?? designTempC }

    /// The walls on a row, in beads (whole — P1). RED CONTROL `controlM1Tie`: M1's tie (the held cell × ρ / unit).
    public func manualWalls(group: Int?) -> Double? {
        guard let l = manualLattice(group: group) else { return nil }
        if Self.controlM1Tie, let c = Self.controlHeldCell[manualKey(group)] {
            return FlexibleManualMath.m1Walls(cellMM: c, density: l.density, topology: l.topology, beadWidthMM: manualBeadWidthMM)
        }
        return Double(l.beads)
    }
    public func manualCellMM(group: Int?) -> Double? {
        manualLattice(group: group).map { FlexibleManualMath.cellMM($0, beadWidthMM: manualBeadWidthMM) }
    }

    /// ★ P1: the depth of the lattice a row sets — the mean latticed depth of its face-prisms (core's columns): a group's own
    /// faces and presses; the part's: every pressed face and press of the groups without their own (all of them if none). nil: no
    /// stack yet.
    public func manualDepthMM(group: Int?) -> Double? {
        let gs = squeezeGroups
        let mine: [FlexibleSqueezeGroup]
        if let g = group { mine = gs.filter { $0.id == g } } else {
            let m = settings.manual
            let shared = gs.filter { !(m?.hasOwn(group: $0.id) ?? false) }
            mine = shared.isEmpty ? gs : shared
        }
        var d: [Double] = []
        for g in mine {
            for r in g.regions { if let st = stack(r) { d += st.columns.map(\.latticeMM).filter { $0 > 0 } } }
            for p in g.presses {
                if let st = pressStack(p) { d += (st.latticeRunMM.isEmpty ? st.columns.map(\.latticeMM) : st.latticeRunMM).filter { $0 > 0 } }
            }
        }
        return d.isEmpty ? nil : d.reduce(0, +) / Double(d.count)
    }
    public func manualCellsAcross(group: Int?) -> Double? {
        guard let l = manualLattice(group: group), let d = manualDepthMM(group: group) else { return nil }
        return FlexibleManualMath.cellsAcross(l, depthMM: d, beadWidthMM: manualBeadWidthMM)
    }

    /// The tested densities of `topology` at Manual's temperature (the curve set's rows), nil without data.
    public func manualDataRange(topology: String) -> ClosedRange<Double>? {
        guard let path = materialsPath, let id = settings.materialID, let t = manualTempC, material?.noPrediction == nil else { return nil }
        let k = "\(path)|\(id)|\(t)|\(topology)"
        if let c = Self.dataRangeCache[k] { return c }
        let set = try? FlexibleCore.curveSet(path: path, materialID: id, tempC: t, topology: topology)
        let r = set.flatMap { $0.refusal == nil && $0.densityMax > $0.densityMin ? $0.densityMin...$0.densityMax : nil }
        Self.dataRangeCache[k] = r
        return r
    }
    @MainActor private static var dataRangeCache: [String: ClosedRange<Double>?] = [:]

    /// ★ P1: the group's lattice holds a density outside the tested rows — its estimate is extended past the data.
    public func manualPastData(group: Int?) -> Bool {
        guard let l = manualLattice(group: group), let r = manualDataRange(topology: l.topology) else { return false }
        let s = FlexibleManualMath.densitySpan(l)
        return s.lowerBound < r.lowerBound - 1e-6 || s.upperBound > r.upperBound + 1e-6
    }

    /// ★ P1, THE FACTS LINE: cells through the depth and the wall in mm; then — flagged, never blocking — under 2 cells (his 10-17
    /// rule) and a cell past what the preview draws; a group's squish estimate; the tested data's span (or "estimate past tested
    /// data"). (text, warning) per line.
    public func manualFacts(group: Int?) -> [(text: String, warning: Bool)] {
        guard let l = manualLattice(group: group) else { return [] }
        let bw = manualBeadWidthMM
        let n = manualCellsAcross(group: group)
        var out: [(String, Bool)] = [(FlexibleManualCopy.cellsLine(n, wallMM: FlexibleManualMath.wallMM(l, beadWidthMM: bw)), false)]
        if let n, n < 2 { out.append((FlexibleManualCopy.underTwoCells, true)) }
        let cells = [FlexibleManualMath.densitySpan(l).lowerBound, FlexibleManualMath.densitySpan(l).upperBound]
            .map { FlexibleManualMath.cellMM(density: $0, beads: l.beads, topology: l.topology, beadWidthMM: bw) }
        if cells.contains(where: { !FlexibleManualMath.cellRange.contains($0) }) { out.append((FlexibleManualCopy.cellOutsideDrawn, true)) }
        if let gid = group, let g = squeezeGroups.first(where: { $0.id == gid }), let mm = estimateDeepest(g) {
            let w = groupForce(g).map { FlexibleRowCopy.weightText($0.upperBound, weightUnit) }
            out.append((FlexibleManualCopy.squishes(mm, weight: w), false))
        }
        if let r = manualDataRange(topology: l.topology) {
            let past = manualPastData(group: group)
            out.append((FlexibleManualCopy.dataLine(min: r.lowerBound, max: r.upperBound, past: past), past))
        }
        return out
    }

    /// [Set its own] (a copy of the part's) / [Use the part's] (the group's own dropped).
    public func setGroupOwnLattice(_ groupID: Int, own: Bool) {
        guard let m = manualSettings, own != m.hasOwn(group: groupID) else { return }
        actionSerial += 1
        edit { s in
            var r = m.resolvedKeeping(on: true)
            var g = r.groups ?? [:]
            if own { g[String(groupID)] = m.part } else { g[String(groupID)] = nil }
            r.groups = g.isEmpty ? nil : g
            s.manual = r
        }
    }

    /// Core's voxel owners (a face's region; a press stack's key and its first piece) → their stored group numbers.
    func manualOwnerGroups() -> [Int: Int] {
        var out: [Int: Int] = [:]
        for f in settings.loadedFaces { out[f.faceRegionID] = FlexibleSqueezeGroups.id(f) }
        for p in presses {
            let g = FlexibleSqueezeGroups.id(p)
            if let r = pressRegistrations[p.id] { out[r.key] = g }
            if let first = p.regions.first, out[first] == nil { out[first] = g }
        }
        return out
    }
    /// ★ P1: each voxel owner's stack for the grade (a face: its stack, cuts and drawn curve; a press: its stack).
    func manualGradeOwners() -> [Int: FlexibleManualField.Owner] {
        var out: [Int: FlexibleManualField.Owner] = [:]
        for f in settings.loadedFaces {
            guard let k = key(f.faceRegionID), let st = stacks[k] else { continue }
            out[f.faceRegionID] = .init(stack: st, cuts: regions.cuts(of: f.faceRegionID), curve: liveS[k])
        }
        for p in presses {
            guard let r = pressRegistrations[p.id] else { continue }
            out[r.key] = .init(stack: r.stack)
            if let first = p.regions.first, out[first] == nil { out[first] = .init(stack: r.stack) }
        }
        return out
    }

    /// ★ The card's view line in Manual (the playing group's squeeze in the page's unit).
    public var manualViewLine: String? {
        guard isManual else { return nil }
        let kg = playingGroup.flatMap { groupForce($0)?.upperBound }
        return FlexibleManualCopy.viewLine(views: views, manual: true,
                                           weight: kg.map { FlexibleRowCopy.weightText($0, weightUnit) },
                                           mm: playingGroup.flatMap { estimateDeepest($0) })   // ★ MANUAL (M2)
    }
}

extension FlexibleManualSettings {
    /// These values (already resolved) with `on` as given — what an edit writes (an old save leaves its M1 form on its first edit).
    func resolvedKeeping(on: Bool) -> FlexibleManualSettings { var o = self; o.on = on; return o }
}
