// FlexibleManual — round 7, MANUAL part M1: the lattice HE sets (task 2026-09-29-flexible-screens).
//
// His orders of 2026-10-22 ~02:30 (verbatim): "implement the manual add-on. Remove any of the auto processes and make it as simple
// to understand as possible. The views become what the app assumes based on your values, so cards should say that when a view is
// selected. Stay with the design philosophy of the new UI. Just because it's manual doesn't mean we want it to look like shit."
// His picks the same night: a toggle that says Manual or Auto at the VERY TOP of the Squish modal, default Auto, Manual's fields
// behind it (never "Expert"); density as BOTH % and wall thickness in beads; SCOPE = the whole part (lattice type, cell size,
// density % / walls in beads) + an optional per-group override; Auto's lattice pick and its "can't meet your curve" checks go.
//
// ★ APP SIDE ONLY. Core's Flexible job has no key for a fixed lattice (its block: topology, feel, beads_per_wall, faces —
// FlexibleJob.runJobJSON), so the job is byte-for-byte Auto's in both modes and Manual's lattice lives here: the field on screen
// (preview, Save & Exit's build, TAP TO READ, the (i)) and the sims read it (CORE LIST item 11).
// ★ ONE RELATION, core's: cell = unit · beads / ρ with unit = flexible_cell_size_mm(type, ρ = 1, 1 bead, bead width) (gyroid
// 3.0915 · bead, honeycomb 2 · bead) — so walls (beads) = cell · ρ / unit, and ρ = beads · unit / cell. Editing any of the
// three moves exactly one other: the cell or the density moves the walls; the walls move the density; the type keeps the cell
// and the walls (its density follows).

import Foundation
import TopOptKit

/// One lattice he sets: its type, cell and density (core's density, 0…1). Walls follow from them (FlexibleManualMath).
public struct FlexibleManualLattice: Codable, Equatable, Hashable, Sendable {
    /// "gyroid" | "honeycomb" (no Auto in Manual)
    public var topology: String
    public var cellMM: Double
    public var density: Double
    public init(topology: String, cellMM: Double, density: Double) {
        self.topology = topology; self.cellMM = cellMM; self.density = density
    }
}

/// ★ MANUAL (M1): what the Squish page's Manual saves (FlexibleStageSettings.manual).
public struct FlexibleManualSettings: Codable, Equatable, Hashable, Sendable {
    /// Manual is on (false: Auto, these values kept for later).
    public var on: Bool
    /// The whole part's lattice.
    public var part: FlexibleManualLattice
    /// A group's own lattice, keyed by its STORED group number ("1", "2" …, as groupNames); nil — never [:] — when none.
    public var groups: [String: FlexibleManualLattice]?

    public init(on: Bool, part: FlexibleManualLattice, groups: [String: FlexibleManualLattice]? = nil) {
        self.on = on; self.part = part; self.groups = groups
    }

    /// The lattice of the group stored as `groupID` (its own, else the part's); nil: the part's.
    public func lattice(group groupID: Int?) -> FlexibleManualLattice {
        guard let g = groupID, let own = groups?[String(g)] else { return part }
        return own
    }
    public func hasOwn(group groupID: Int) -> Bool { groups?[String(groupID)] != nil }

    /// Each group's own lattice to its new number (FlexibleSqueezeGroups.normalise); a group gone drops it.
    static func remap(_ g: [String: FlexibleManualLattice]?, rank: [Int: Int]) -> [String: FlexibleManualLattice]? {
        guard let g, !g.isEmpty else { return nil }
        var out: [String: FlexibleManualLattice] = [:]
        for (k, v) in g { if let old = Int(k), let n = rank[old] { out[String(n)] = v } }
        return out.isEmpty ? nil : out
    }
}

/// ★ MANUAL (M1): the one relation between type, cell, density and walls (core's `cell_size_mm`, through the bridge).
public enum FlexibleManualMath {
    /// The densities the lattice field draws (FlexibleLatticeField: ρ clamped to 0.05…0.9).
    public static let densityRange: ClosedRange<Double> = 0.05...0.9
    public static let cellRange: ClosedRange<Double> = 2...60
    /// Walls this close to a whole bead read as whole.
    public static let wholeTolerance = 0.05

    /// The cell of a 1-bead wall at ρ = 1 (core's relation): gyroid 3.0915 · bead, honeycomb 2 · bead.
    public static func unitCellMM(_ topology: String, beadWidthMM bw: Double) -> Double {
        (try? FlexibleCore.cellSizeMM(topology: topology, density: 1, beadsPerWall: 1, beadWidthMM: bw)) ?? 0
    }
    /// His walls, in beads (a fraction allowed): cell · ρ / unit.
    public static func walls(_ l: FlexibleManualLattice, beadWidthMM bw: Double) -> Double {
        let u = unitCellMM(l.topology, beadWidthMM: bw)
        return u > 0 ? l.cellMM * l.density / u : 0
    }
    /// The density of `beads` walls at `cellMM`: beads · unit / cell (clamped to what the field draws).
    public static func density(walls beads: Double, cellMM: Double, topology: String, beadWidthMM bw: Double) -> Double {
        let u = unitCellMM(topology, beadWidthMM: bw)
        guard cellMM > 0 else { return densityRange.lowerBound }
        return min(max(beads * u / cellMM, densityRange.lowerBound), densityRange.upperBound)
    }
    /// The walls in mm (what the field draws: beads × the bead width).
    public static func wallMM(_ l: FlexibleManualLattice, beadWidthMM bw: Double) -> Double { walls(l, beadWidthMM: bw) * bw }

    /// A 1-bead lattice near density `rho`: the cell on 0.5 mm, the density exact for 1 bead (no warning on a fresh Manual).
    public static func oneBead(topology: String, density rho: Double, beadWidthMM bw: Double) -> FlexibleManualLattice {
        let u = unitCellMM(topology, beadWidthMM: bw)
        let r = min(max(rho.isFinite ? rho : 0.2, densityRange.lowerBound), densityRange.upperBound)
        var cell = max(0.5, ((u / r) / 0.5).rounded() * 0.5)
        cell = min(max(cell, u / densityRange.upperBound), u / densityRange.lowerBound)
        return FlexibleManualLattice(topology: topology, cellMM: cell, density: u > 0 ? u / cell : r)
    }

    /// Whether `beads` is a printable whole number of beads (≥ 1).
    public static func isWhole(_ beads: Double) -> Bool {
        beads >= 1 - wholeTolerance && abs(beads - beads.rounded()) < wholeTolerance
    }
    /// The nearest whole bead (at least 1).
    public static func nearestWhole(_ beads: Double) -> Int { max(1, Int(beads.rounded())) }

    /// The one-tap fix: walls to the nearest whole bead, the cell kept — or, where that density is past what the field draws,
    /// the density at its bound and the cell moved to keep the whole bead.
    public static func fixed(_ l: FlexibleManualLattice, beadWidthMM bw: Double) -> FlexibleManualLattice {
        let u = unitCellMM(l.topology, beadWidthMM: bw)
        guard u > 0 else { return l }
        let n = Double(nearestWhole(walls(l, beadWidthMM: bw)))
        var out = l
        let want = n * u / l.cellMM
        if densityRange.contains(want) { out.density = want; return out }
        out.density = min(max(want, densityRange.lowerBound), densityRange.upperBound)
        out.cellMM = n * u / out.density
        return out
    }

    // MARK: the edits (each moves exactly one other value)

    public static func withType(_ l: FlexibleManualLattice, _ topology: String, beadWidthMM bw: Double) -> FlexibleManualLattice {
        guard topology != l.topology else { return l }
        let beads = walls(l, beadWidthMM: bw)
        var out = l
        out.topology = topology
        out.density = density(walls: beads, cellMM: l.cellMM, topology: topology, beadWidthMM: bw)
        return out
    }
    public static func withCell(_ l: FlexibleManualLattice, _ mm: Double) -> FlexibleManualLattice {
        var out = l
        out.cellMM = min(max(mm, cellRange.lowerBound), cellRange.upperBound)
        return out
    }
    public static func withDensity(_ l: FlexibleManualLattice, _ rho: Double) -> FlexibleManualLattice {
        var out = l
        out.density = min(max(rho, densityRange.lowerBound), densityRange.upperBound)
        return out
    }
    public static func withWalls(_ l: FlexibleManualLattice, _ beads: Double, beadWidthMM bw: Double) -> FlexibleManualLattice {
        var out = l
        out.density = density(walls: beads, cellMM: l.cellMM, topology: l.topology, beadWidthMM: bw)
        return out
    }
}

/// ★ MANUAL (M1): every line Manual adds (one line each, ≤ 44 characters — FlexibleRowCopy.maxChars).
public enum FlexibleManualCopy {
    public static let manual = "Manual"
    public static let auto = "Auto"
    public static let modeOptions: [(id: String, label: String)] = [("manual", manual), ("auto", auto)]
    public static let title = "Lattice · you set it"
    public static let lattice = "Lattice"
    public static let typeOptions: [(id: String, label: String)] = [("gyroid", "Gyroid"), ("honeycomb", "Honeycomb")]
    public static let cell = "Cell size"
    public static let density = "Density"
    public static let walls = "Walls"
    public static let wallsUnit = "beads"
    /// The Walls box's unit for the shown value: "bead" at exactly 1, else "beads".
    public static func wallsUnitFor(_ shown: Double) -> String { shown == 1 ? "bead" : wallsUnit }
    public static let sameAsPart = "Lattice · same as the part"
    public static let ownLattice = "Lattice · its own"
    public static let setOwn = "Set its own"
    public static let useParts = "Use the part's"

    /// The bead warning (nil: whole beads, ≥ 1).
    public static func wallsWarning(_ beads: Double) -> String? {
        guard !FlexibleManualMath.isWhole(beads) else { return nil }
        if beads < 1 - FlexibleManualMath.wholeTolerance { return FlexibleRowCopy.fit("Walls under 1 bead · too thin to print") }
        return FlexibleRowCopy.fit(String(format: "Walls %.1f beads · not a whole bead", beads))
    }
    /// The one-tap fix's title.
    public static func fixTitle(_ beads: Double) -> String {
        let n = FlexibleManualMath.nearestWhole(beads)
        return n == 1 ? "Make it 1 bead" : "Make it \(n) beads"
    }

    /// ★ "The views become what the app assumes based on your values, so cards should say that when a view is selected": the
    /// one line for the views on (Bend, Play, X-ray's bend prism, Heat — the first of them), nil in Auto or with none on.
    public static func viewLine(views: FlexibleStageViews, manual: Bool, weight: String?) -> String? {
        guard manual else { return nil }
        let at = weight.map { " at \($0)" } ?? ""
        if views.contains(.bend) { return FlexibleRowCopy.fit("Bend · what your lattice does" + at) }
        if views.contains(.play) { return FlexibleRowCopy.fit("Play · what your lattice does" + at) }
        if views.contains(.xray) { return FlexibleRowCopy.fit("X-ray · bend estimated from your lattice") }
        if !views.contains(.heatOff) { return FlexibleRowCopy.fit("Heat · estimated from your lattice") }
        return nil
    }

    public enum Info {
        public static let mode = "Auto designs the lattice from your curves. Manual: you set the lattice — type, cell size and density (or walls in beads) — and the views show what the app expects that lattice to do under your squeeze. Your values are kept when you switch back."
        public static let lattice = "Gyroid: springy, bounces back. Honeycomb: firmer, soaks up the push."
        public static let cell = "The size of one repeat of the lattice."
        public static let density = "How much of the lattice is solid. More is firmer. Density, cell size and walls go together: change one and the walls (or the density) follow."
        public static let walls = "Wall thickness in printed beads. A wall prints in whole beads; set the walls and the density follows."
        public static let group = "This group can have its own lattice. Otherwise it uses the part's."
    }
}

/// ★ MANUAL (M1): the lattice field from his values — every lattice voxel of core's field takes the density of the group that
/// owns it (its own lattice, else the part's); the mask and the owners are core's. Pure (FlexibleM1ManualTests).
public enum FlexibleManualField {
    /// `ownerGroups`: a voxel owner (a face or press region, as core names it) → its stored group number.
    public static func field(_ f: FlexDensityField, manual: FlexibleManualSettings, ownerGroups: [Int: Int]) -> FlexDensityField {
        var d = f.density
        let partRho = Float(manual.part.density)
        var byOwner: [Int: Float] = [:]
        for (o, g) in ownerGroups where manual.hasOwn(group: g) { byOwner[o] = Float(manual.lattice(group: g).density) }
        for v in d.indices where d[v] >= 0 {
            let o = v < f.owner.count ? f.owner[v] : -1
            d[v] = byOwner[o] ?? partRho
        }
        return FlexDensityField(nx: f.nx, ny: f.ny, nz: f.nz, spacing: f.spacing, origin: f.origin, density: d, owner: f.owner)
    }
}

extension FlexibleStageModel {
    /// ★ MANUAL (M1): Manual is on.
    public var isManual: Bool { settings.isManual }
    var manualBeadWidthMM: Double { project.printParams.strutLineWidthMM }

    /// ★ RED CONTROL only (FlexibleM1ManualTests): the lattice built from core's design in Manual (his values ignored).
    nonisolated(unsafe) static var controlManualLatticeOff = false

    /// The toggle. Switching on starts from what Auto last designed (its type, the lattice's mean density, 1 bead) — or sensible
    /// defaults with nothing designed — so nothing jumps; his values kept from before win. Off keeps them for later.
    public func setManual(_ on: Bool) {
        guard on != isManual else { return }
        let seed = settings.manual == nil && on ? manualSeed() : nil
        actionSerial += 1
        edit { s in
            if let seed { s.manual = FlexibleManualSettings(on: true, part: seed) } else { s.manual?.on = on }
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
        return FlexibleManualMath.oneBead(topology: top, density: rho, beadWidthMM: manualBeadWidthMM)
    }

    /// The lattice shown on a Manual row: the group's own (or the part's), nil in Auto.
    public func manualLattice(group groupID: Int?) -> FlexibleManualLattice? {
        guard let m = settings.manual, m.on else { return nil }
        return m.lattice(group: groupID)
    }

    /// Change the part's lattice (`group` nil) or a group's own.
    public func editManual(group groupID: Int?, _ change: (FlexibleManualLattice) -> FlexibleManualLattice) {
        guard let m = settings.manual, m.on else { return }
        let next = change(m.lattice(group: groupID))
        actionSerial += 1
        edit { s in
            if let g = groupID, s.manual?.hasOwn(group: g) == true { s.manual?.groups?[String(g)] = next }
            else if groupID == nil { s.manual?.part = next }
        }
    }
    public func setManualType(_ t: String, group: Int?) {
        let bw = manualBeadWidthMM
        editManual(group: group) { FlexibleManualMath.withType($0, t, beadWidthMM: bw) }
    }
    public func setManualCell(_ mm: Double, group: Int?) { editManual(group: group) { FlexibleManualMath.withCell($0, mm) } }
    public func setManualDensity(_ rho: Double, group: Int?) { editManual(group: group) { FlexibleManualMath.withDensity($0, rho) } }
    public func setManualWalls(_ beads: Double, group: Int?) {
        let bw = manualBeadWidthMM
        editManual(group: group) { FlexibleManualMath.withWalls($0, beads, beadWidthMM: bw) }
    }
    /// The bead warning's one-tap fix.
    public func fixManualWalls(group: Int?) {
        let bw = manualBeadWidthMM
        editManual(group: group) { FlexibleManualMath.fixed($0, beadWidthMM: bw) }
    }
    /// The walls (beads) of the lattice on a row.
    public func manualWalls(group: Int?) -> Double? {
        manualLattice(group: group).map { FlexibleManualMath.walls($0, beadWidthMM: manualBeadWidthMM) }
    }

    /// [Set its own] (a copy of the part's) / [Use the part's] (the group's own dropped).
    public func setGroupOwnLattice(_ groupID: Int, own: Bool) {
        guard let m = settings.manual, m.on, own != m.hasOwn(group: groupID) else { return }
        actionSerial += 1
        edit { s in
            var g = s.manual?.groups ?? [:]
            if own { g[String(groupID)] = m.part } else { g[String(groupID)] = nil }
            s.manual?.groups = g.isEmpty ? nil : g
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

    /// ★ The card's view line in Manual (the playing group's squeeze in the page's unit).
    public var manualViewLine: String? {
        guard isManual else { return nil }
        let kg = playingGroup.flatMap { groupForce($0)?.upperBound }
        return FlexibleManualCopy.viewLine(views: views, manual: true,
                                           weight: kg.map { FlexibleRowCopy.weightText($0, weightUnit) })
    }
}
