// FlexibleAutoFloor — round 7 · AUTO AT THE FLOOR, and THE FACE'S ACTIVE SHAPE (task 2026-09-29-flexible-screens).
//
// ★ WHY (told to him 2026-10-23 ~00:30): Auto DOES grade by design, but on his projects every column clamps to the softest
// tested lattice (14.3 %, the softest measured row) — his loads are far too light for the depths he asks (his l-bracket at
// 10 lb / 7 mm: 4549 of 4560 columns too firm, core builds 0.64 mm at most). His decisions of ~00:35 (verbatim pick): "SAY IT +
// SHAPE-ONLY GRADE: one plain line ('Every column at the softest tested lattice (14 %)' + the reachable depth range at this
// weight) AND fall back to grading the drawn lattice by the curve's shape (like a no-data filament, D-R3-12), clearly marked as
// not designed from data." His words of ~02:45: "Just to confirm, the grading follows the curve OR stamp, not just the curves,
// right? If I set a custom stamp, I'd want the grading based on that" — the shape is the face's ACTIVE one: his curves on
// Curves, his stamp on Stamp (Manual's grade "along Shape" reads the same values, FlexibleManual).
//
// ★ APP SIDE ONLY. Core's job is untouched (its bytes, the 16 stage-job hashes): the fallback re-grades only the DRAWN field of a
// face core left at the floor, inside the tested densities, cells following the density at Auto's 1-bead walls. The views
// (Bend, Play, Heat, X-ray, the legend, a tap) read that drawn field; the line on the card says it is not from data.

import Foundation
import simd
import TopOptKit

/// A pressed face core designs at the softest tested lattice on (nearly) every column.
public struct FlexibleAutoFloor: Equatable, Sendable {
    /// Latticed columns that carry pressure.
    public let pressed: Int
    /// Of them, at the softest tested density (core's too_firm, or a buildable density at the floor).
    public let atFloor: Int
    /// The softest tested density (0…1).
    public let floorDensity: Double
    /// Core's own nearest depths over the pressed columns (mm): the shallowest and the deepest Auto can build at this weight.
    public let reachMinMM: Double, reachMaxMM: Double
    /// The face's squeeze (kg) and its words.
    public let weightKg: Double
    public let lines: [String]

    /// "≥ 95 %" of the pressed columns (the ruling's "every, or nearly every").
    public static let share = 0.95
}

public extension FlexibleRowCopy {
    /// ★ His words: "Every column at the softest tested lattice (14 %)" (the nearly-every case: "Nearly every column at softest
    /// tested (14 %)").
    static func autoFloor(densityPercent p: Int, all: Bool) -> String {
        all ? "Every column at the softest tested lattice (\(p) %)" : "Nearly every column at softest tested (\(p) %)"
    }
    /// "Auto reaches 0.05–0.64 mm at 10 lb" (core's nearest depths, his weight unit).
    static func autoReaches(minMM: Double, maxMM: Double, weight: String) -> String {
        fit(String(format: "Auto reaches %.2f–%.2f mm at ", minMM, maxMM) + weight)
    }
    /// The card's marked line: "Lattice shaped by your curve · not from data" / "… by your stamp · not from data".
    static func autoShaped(stamp: Bool) -> String { "Lattice shaped by your \(stamp ? "stamp" : "curve") \u{00B7} not from data" }
}

extension FlexibleStageModel {
    /// ★ RED CONTROL only (FlexibleAutoFloorShapeTests): today's Auto — no truth line (only "needs more weight or less depth").
    nonisolated(unsafe) static var controlNoAutoFloorLine = false
    /// ★ RED CONTROL only: today's drawn field at the floor — core's flat 14.3 %.
    nonisolated(unsafe) static var controlNoShapeFallback = false
    /// ★ RED CONTROL only: today's Manual "Along Curve" — the drawn curves only (a stamp ignored; a press falls back to Depth).
    nonisolated(unsafe) static var controlGradeAlongCurvesOnly = false

    /// The tested densities of Auto's lattice at Auto's temperature (core's curve set), nil without data.
    public func autoDataRange() -> ClosedRange<Double>? {
        guard let path = materialsPath, let id = settings.materialID, let t = designTempC, material?.noPrediction == nil else { return nil }
        let top = designTopology == "honeycomb" ? "honeycomb" : "gyroid"
        let set = try? FlexibleCore.curveSet(path: path, materialID: id, tempC: t, topology: top)
        return set.flatMap { $0.refusal == nil && $0.densityMax > $0.densityMin ? $0.densityMin...$0.densityMax : nil }
    }

    /// ★ AUTO TRUTH LINE: the face core leaves at the softest tested lattice on ≥ 95 % of its pressed columns, with the depths
    /// it can reach (core's own nearest depths) — nil in Manual, for a no-data filament, or when Auto designs a range.
    public func autoFloor(region r: Int) -> FlexibleAutoFloor? {
        if Self.controlNoAutoFloorLine || isManual || material?.noPrediction != nil { return nil }
        guard !noFacePrismKnown, let f = settings.face(r), f.isLoaded, hasOwnLattice(r), let k = key(r), let d = designs[k],
              d.refusal == nil, let range = autoDataRange() else { return nil }
        let pressed = d.columns.filter { $0.status != "no_lattice" && $0.pressureMPa > 0 }
        guard !pressed.isEmpty else { return nil }
        let atFloor = pressed.filter { $0.status == "too_firm" || $0.buildableDensity <= range.lowerBound + 1e-4 }.count
        guard Double(atFloor) >= FlexibleAutoFloor.share * Double(pressed.count) else { return nil }
        let depths = pressed.compactMap { c -> Double? in
            if let n = c.nearestDepthMM, n.isFinite { return n }
            return c.buildableDepthMM.isFinite ? c.buildableDepthMM : nil
        }
        guard let lo = depths.min(), let hi = depths.max() else { return nil }
        let kg = squeezeGroup(of: r).flatMap { groupForce($0)?.upperBound } ?? f.weightKg
        let p = Int((range.lowerBound * 100).rounded())
        let lines = [FlexibleRowCopy.autoFloor(densityPercent: p, all: atFloor == pressed.count),
                     FlexibleRowCopy.autoReaches(minMM: lo, maxMM: hi, weight: FlexibleRowCopy.weightText(kg, weightUnit))]
        return FlexibleAutoFloor(pressed: pressed.count, atFloor: atFloor, floorDensity: range.lowerBound, reachMinMM: lo,
                                 reachMaxMM: hi, weightKg: kg, lines: lines)
    }

    /// The Auto row's lines: the floor face with the most pressed columns (empty: Auto designs a range somewhere, or Manual).
    public func autoFloorLines() -> [String] {
        let floors = settings.loadedFaces.compactMap { autoFloor(region: $0.faceRegionID) }
        return floors.max { $0.pressed < $1.pressed }?.lines ?? []
    }

    /// ★ The card's marked line while the drawn lattice is shaped by the face (nil: core's design is drawn).
    public func autoShapeLine(region r: Int) -> String? {
        guard !Self.controlNoShapeFallback, autoFloor(region: r) != nil, shapeValues(region: r) != nil,
              let f = settings.face(r) else { return nil }
        return FlexibleRowCopy.autoShaped(stamp: f.isStampShape)
    }

    /// ★ THE FACE'S ACTIVE SHAPE per column of its stack, 0 (no press) … 1 (the deepest / firmest press): his drawn curves (core's
    /// squish fraction of the map) on Curves; on Stamp his stamp's footprint (its laid grid, the one the press and core's
    /// check_stamps read, smoothed as the depth prism stands on it) over its peak. nil: no stack, no map, no stamp grid yet.
    public func shapeValues(region r: Int) -> [Double]? {
        guard let f = settings.face(r), let k = key(r) else { return nil }
        guard f.isStampShape else { return liveS[k] }
        guard let foot = stampFootprint(r), let peak = foot.max(), peak > 1e-12 else { return nil }
        return foot.map { Swift.min(1, Swift.max(0, $0 / peak)) }
    }

    /// ★ An edge's or a corner's ACTIVE SHAPE per column of its press stack, 0…1: its drawn push or its stamp (the samples Play
    /// pushes, FlexiblePressPush), each column reading the sample nearest its footprint point across the arrow. nil: no stack.
    public func pressShapeValues(_ id: UUID) -> [Double]? {
        guard let p = press(id), let st = pressStack(id), let c = flatCut(id) else { return nil }
        let s = FlexiblePressPush.samples(p, c)
        guard s.count > 0, st.pitchMM > 0 else { return nil }
        let load = simd_normalize(st.load)
        var out = [Double](repeating: 0, count: st.columns.count)
        for (i, col) in st.columns.enumerated() {
            let at = st.centroid + st.xAxis * (st.uMin + (Double(col.iu) + 0.5) * st.pitchMM)
                + st.yAxis * (st.vMin + (Double(col.iv) + 0.5) * st.pitchMM) + load * col.entryT
            var best = Double.infinity, w = 0.0
            for j in 0..<s.count {
                let q = SIMD3(s.xyz[3 * j], s.xyz[3 * j + 1], s.xyz[3 * j + 2]) - at
                let across = q - load * simd_dot(q, load)
                let d2 = simd_length_squared(across)
                if d2 < best { best = d2; w = s.weight[j] }
            }
            out[i] = w
        }
        guard let peak = out.max(), peak > 1e-12 else { return nil }
        return out.map { $0 / peak }
    }
}

/// ★ THE SHAPE-ONLY FALLBACK on a designed field: every voxel a floor face owns takes the density of its column's shape value
/// inside the tested band (FlexibleGeometryOnlyLattice.density: 0 → the firmest tested, 1 → the softest), the column read on
/// the face's own (u, v) grid — a voxel past the latticed columns reads the nearest one (a flood over the grid). Every other
/// voxel keeps core's density. Pure.
public enum FlexibleAutoShapeField {
    public struct Face: Sendable {
        public let region: Int
        public let stack: FlexStackInfo
        public let s: [Double]
        public init(region: Int, stack: FlexStackInfo, s: [Double]) { self.region = region; self.stack = stack; self.s = s }
    }

    /// The face's shape on its full (iu, iv) grid, each cell without a column filled from its nearest neighbour.
    static func grid(_ f: Face) -> [Double]? {
        let st = f.stack
        guard st.nu > 0, st.nv > 0, st.cell.count == st.nu * st.nv else { return nil }
        var g = [Double](repeating: .nan, count: st.nu * st.nv)
        var frontier: [Int] = []
        for (n, c) in st.cell.enumerated() where c >= 0 && c < f.s.count && st.columns[c].latticeMM > 0 {
            g[n] = Swift.min(1, Swift.max(0, f.s[c].isFinite ? f.s[c] : 0)); frontier.append(n)
        }
        guard !frontier.isEmpty else { return nil }
        while !frontier.isEmpty {
            var next: [Int] = []
            for n in frontier {
                let iu = n % st.nu, iv = n / st.nu
                for (du, dv) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let a = iu + du, b = iv + dv
                    guard a >= 0, b >= 0, a < st.nu, b < st.nv else { continue }
                    let m = b * st.nu + a
                    if g[m].isNaN { g[m] = g[n]; next.append(m) }
                }
            }
            frontier = next
        }
        return g
    }

    public static func apply(_ field: FlexDensityField, faces: [Face], band: ClosedRange<Double>) -> FlexDensityField {
        var grids: [Int: (Face, [Double])] = [:]
        for f in faces { if let g = grid(f) { grids[f.region] = (f, g) } }
        guard !grids.isEmpty else { return field }
        var d = field.density
        for v in d.indices where d[v] >= 0 {
            guard v < field.owner.count, let (f, g) = grids[field.owner[v]] else { continue }
            let st = f.stack
            let i = v % field.nx, j = (v / field.nx) % field.ny, k = v / (field.nx * field.ny)
            let p = field.origin + SIMD3<Double>(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * field.spacing
            let q = p - st.centroid
            let iu = Swift.min(Swift.max(Int(((simd_dot(q, st.xAxis) - st.uMin) / st.pitchMM).rounded(.down)), 0), st.nu - 1)
            let iv = Swift.min(Swift.max(Int(((simd_dot(q, st.yAxis) - st.vMin) / st.pitchMM).rounded(.down)), 0), st.nv - 1)
            d[v] = Float(FlexibleGeometryOnlyLattice.density(s: g[iv * st.nu + iu], band: band))
        }
        return FlexDensityField(nx: field.nx, ny: field.ny, nz: field.nz, spacing: field.spacing, origin: field.origin,
                                density: d, owner: field.owner)
    }
}
