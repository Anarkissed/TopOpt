import Foundation
import simd

// ★★★ THE LATTICE'S THICKNESS THROUGH THE WALL (his 2026-09-20/21: "I want the sim to
// decide the thickness of the lattice wall itself. Currently it should be ALL THE WAY
// THROUGH. It would mean adding a new variable to the existing infrastructure"), built
// to his design `docs/design/lattice-page/Lattice Wall Thickness.dc.html` (2026-09-21).
//
// A face region is a prism: the face outline extruded `depthMM` into the part. Until
// now the lattice filled the whole prism. This is a SLAB inside that prism, and the
// design says it in two questions:
//
//   1. "Depth defined by sim?"  ON  ⇒ the solve decides how deep the lattice goes
//                               OFF ⇒ the user sets, per wall, the ALLOWED range in mm
//                                     (start – end, from the outer surface in), "how
//                                     much of the wall's thickness COULD be used"
//   2. "Density through the wall" (only when the range is the user's): what WILL be used
//        sim           HIS RULE, agreed 2026-09-21: at each face point the slab is the
//                      allowed range × that point's normalised stress (the column's peak
//                      von Mises over the part's 95th percentile), never under one cell
//        autoSingle    one thickness for the wall, the same rule at the wall's own p95
//        manualSingle  one share of the allowed range, typed (%)
//        manualGrade   the profile he DRAWS per wall: a start curve and an end curve
//                      across the wall's width, in the viewer's grading tool
//
// PREVIEW FIRST (his rule, 2026-09-20): the slab is applied where the app builds the
// preview — the one region distance every reader clips against, the organic candidates,
// the octree's cells, the cap walls drawn where the slab starts and ends — and NOTHING
// reaches core's job until it is agreed to work. The job's region still carries the
// declared depth. Untouched projects encode byte-identically.

public enum LatticeWallDensityMode: String, Codable, CaseIterable, Sendable {
    case sim, autoSingle, manualSingle, manualGrade

    public var title: String {
        switch self {
        case .sim: return "Graded by sim"
        case .autoSingle: return "Auto single depth"
        case .manualSingle: return "Manual single depth"
        case .manualGrade: return "Manual grade"
        }
    }
    public var brief: String {
        switch self {
        case .sim: return "FEA decides the depth where it is loaded"
        case .autoSingle: return "One depth chosen for the part"
        case .manualSingle: return "One share of the allowed depth"
        case .manualGrade: return "Draw the depth per wall, in steps"
        }
    }
    public var readsTheSolve: Bool { self == .sim || self == .autoSingle }
}

/// ★ THE DRAWN DEPTH OF ONE WALL. Two forms (his 2026-09-21 22:40): CELL-BASED lattices
/// draw STEPS — `starts[i]`/`ends[i]` are the band's shares of the wall's thickness in
/// column `i` of equal columns along the wall, the start in the outer half (≤ 0.5) and
/// the end in the inner half (≥ 0.5) — and ORGANIC draws CURVES (`curves`, the design's
/// Bézier lines, the same 50 % rule). The lattice lives between start and end.
public struct LatticeWallProfile: Codable, Hashable, Sendable {
    public var starts: [Double]
    public var ends: [Double]
    /// organic only: the drawn curves; when set they are the profile
    public var curves: LatticeWallCurves? = nil
    public init(starts: [Double] = [], ends: [Double], curves: LatticeWallCurves? = nil) {
        let n = Swift.max(1, ends.count)
        // ★ NO 50 % CLAMP OF THE WHOLE WALL (his R9, 2026-09-23: the halves are halves
        // of the ALLOWED range, which the editor already keeps; a start held under half
        // the wall could never reach an allowed range that begins deeper). Shares are
        // held to 0…1 and a start never passes its end.
        var en = ends.isEmpty ? [1] : ends.map { Swift.min(1, Swift.max(0, $0)) }
        var st = starts.map { Swift.min(1, Swift.max(0, $0)) }
        if st.count != n { st = [Double](repeating: 0, count: n) }
        for i in 0..<n where i < st.count && i < en.count && st[i] > en[i] { en[i] = st[i] }
        self.ends = en
        self.starts = st
        self.curves = curves
    }
    public init(curves: LatticeWallCurves) { self.starts = [0]; self.ends = [1]; self.curves = curves }
    /// One start and one end across the whole wall.
    public static func flat(start a: Double = 0, end b: Double, columns: Int = 1) -> LatticeWallProfile {
        LatticeWallProfile(starts: [Double](repeating: a, count: Swift.max(1, columns)),
                           ends: [Double](repeating: b, count: Swift.max(1, columns)))
    }
    public var columns: Int { ends.count }
    public var isCurves: Bool { curves != nil }
    /// The same steps on `n` columns: each new column takes the old column under its centre.
    public func resampled(columns n: Int) -> LatticeWallProfile {
        let n = Swift.max(1, n)
        guard n != ends.count else { return self }
        return LatticeWallProfile(starts: (0..<n).map { start(at: (Double($0) + 0.5) / Double(n)) },
                                  ends: (0..<n).map { end(at: (Double($0) + 0.5) / Double(n)) }, curves: curves)
    }
    private func column(_ x: Double) -> Int {
        Swift.min(ends.count - 1, Swift.max(0, Int((x * Double(ends.count)).rounded(.down))))
    }
    public func start(at x: Double) -> Double { curves?.y(at: x, side: .start) ?? starts[column(x)] }
    public func end(at x: Double) -> Double { curves?.y(at: x, side: .end) ?? ends[column(x)] }
    public typealias Side = LatticeWallCurves.Side
    public func y(at x: Double, side: Side) -> Double { side == .start ? start(at: x) : end(at: x) }

    private enum CodingKeys: String, CodingKey { case starts, ends, curves, start, end, curveStart, curveEnd }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let ends = (try? c.decodeIfPresent([Double].self, forKey: .ends)) ?? []
        let starts = (try? c.decodeIfPresent([Double].self, forKey: .starts)) ?? []
        var curves = try? c.decodeIfPresent(LatticeWallCurves.self, forKey: .curves)
        // a drawing written as curves before this form existed decodes AS curves
        if curves == nil, c.contains(.start) || c.contains(.end) {
            curves = try? LatticeWallCurves(from: decoder)
        }
        self.init(starts: starts, ends: ends.isEmpty ? [1] : ends, curves: curves)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ends, forKey: .ends)
        if starts.contains(where: { $0 > 0 }) { try c.encode(starts, forKey: .starts) }
        if let curves { try c.encode(curves, forKey: .curves) }
    }
}

/// One point of a drawn profile, in the wall's normalised box: x across the wall's width
/// (0…1), y through its thickness (0 = outer surface, 1 = inner). `smooth` false is a
/// corner; `tx/ty` an explicit tangent (Catmull-Rom otherwise), as in the design.
public struct LatticeWallCurvesPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var smooth: Bool = true
    public var tx: Double? = nil
    public var ty: Double? = nil
    public init(x: Double, y: Double, smooth: Bool = true, tx: Double? = nil, ty: Double? = nil) {
        self.x = x; self.y = y; self.smooth = smooth; self.tx = tx; self.ty = ty
    }
    private enum CodingKeys: String, CodingKey { case x, y, smooth, tx, ty }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x); y = try c.decode(Double.self, forKey: .y)
        smooth = try c.decodeIfPresent(Bool.self, forKey: .smooth) ?? true
        tx = try c.decodeIfPresent(Double.self, forKey: .tx); ty = try c.decodeIfPresent(Double.self, forKey: .ty)
    }
}

/// The drawn profile of one wall: the START curve (kept in the outer half, y ≤ 0.5) and
/// the END curve (the inner half, y ≥ 0.5) — the lattice lives between them.
public struct LatticeWallCurves: Codable, Hashable, Sendable {
    public var start: [LatticeWallCurvesPoint]
    public var end: [LatticeWallCurvesPoint]
    public var curveStart: Bool = true
    public var curveEnd: Bool = true

    public init(start: [LatticeWallCurvesPoint], end: [LatticeWallCurvesPoint],
                curveStart: Bool = true, curveEnd: Bool = true) {
        self.start = start; self.end = end; self.curveStart = curveStart; self.curveEnd = curveEnd
    }
    /// Two straight lines at the allowed range's shares.
    public static func flat(start a: Double, end b: Double) -> LatticeWallCurves {
        LatticeWallCurves(start: [.init(x: 0, y: min(a, b)), .init(x: 1, y: min(a, b))],
                           end: [.init(x: 0, y: max(a, b)), .init(x: 1, y: max(a, b))])
    }

    // ── the design's geometry, ported verbatim (`tangent`, `pathD`) ──────────────
    static func tangent(_ pts: [LatticeWallCurvesPoint], _ i: Int) -> SIMD2<Double> {
        let p = pts[i]
        if let tx = p.tx, let ty = p.ty { return SIMD2(tx, ty) }
        let a = i > 0 ? pts[i - 1] : p, b = i + 1 < pts.count ? pts[i + 1] : p
        return SIMD2((b.x - a.x) / 6, (b.y - a.y) / 6)
    }

    /// The curve as a polyline in the normalised box, 24 samples per smooth segment,
    /// flattened along the mid-plane where it would cross (`side` start ⇒ y ≤ 0.5).
    public static func polyline(_ pts: [LatticeWallCurvesPoint], curved: Bool,
                                side: Side?) -> [SIMD2<Double>] {
        guard pts.count >= 2 else { return pts.map { SIMD2($0.x, $0.y) } }
        // ★ NO MID-PLANE CLAMP AT HALF THE WALL (his R9, 2026-09-23: the halves are the
        // ALLOWED range's; the editor holds each curve on its side of that range's
        // middle, and the wall builder swaps a crossing). `side` is kept for the callers.
        func clampY(_ y: Double) -> Double { _ = side; return min(1, max(0, y)) }
        var out = [SIMD2(pts[0].x, clampY(pts[0].y))]
        for i in 0..<(pts.count - 1) {
            let p0 = SIMD2(pts[i].x, pts[i].y), p1 = SIMD2(pts[i + 1].x, pts[i + 1].y)
            if !curved || !pts[i].smooth || !pts[i + 1].smooth {
                out.append(SIMD2(p1.x, clampY(p1.y))); continue
            }
            let t1 = tangent(pts, i), t2 = tangent(pts, i + 1)
            let c1 = p0 + t1, c2 = p1 - t2
            let n = 24
            for k in 1...n {
                let u = Double(k) / Double(n), v = 1 - u
                let q = v*v*v*p0 + 3*v*v*u*c1 + 3*v*u*u*c2 + u*u*u*p1
                out.append(SIMD2(q.x, clampY(q.y)))
            }
        }
        return out
    }

    public enum Side: String, Codable, Sendable { case start, end }

    /// y of a side's curve at x (0…1): the polyline's first crossing of x, its ends
    /// held beyond the range.
    public func y(at x: Double, side: Side) -> Double {
        let pts = side == .start ? start : end
        let curved = side == .start ? curveStart : curveEnd
        let poly = LatticeWallCurves.polyline(pts, curved: curved, side: side)
        guard let first = poly.first, let last = poly.last else { return side == .start ? 0 : 1 }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        for i in 0..<(poly.count - 1) {
            let a = poly[i], b = poly[i + 1]
            if (a.x <= x && x <= b.x) || (b.x <= x && x <= a.x) {
                let d = b.x - a.x
                let t = abs(d) < 1e-12 ? 0 : (x - a.x) / d
                return a.y + (b.y - a.y) * t
            }
        }
        return last.y
    }
}


/// ★ THE DEPTHS A WALL CAN ACTUALLY BE LATTICED TO (his 2026-09-21: "the cell sizes would
/// never *not* equal a divisible of the whole wall"). On an octet wall the cell is fitted
/// to or derived from the wall, and the packer lays the wall's own cell fractions from the
/// face inward, largest first. So the depths worth offering are the ones that packing
/// reaches EXACTLY — no remainder left solid, no cell cut — and every depth the user can
/// pick (the fields, the editor's rows) is snapped to them. Organic is continuous: no
/// steps, nothing snapped.
public enum LatticeWallDepthSteps {
    /// What largest-first packing lays from the face for an ask of `askMM`: the sum of the
    /// menu sizes it fits, in order, never more than the ask.
    public static func laid(_ askMM: Double, menu: [Double]) -> Double {
        var remaining = Swift.max(0, askMM), laid = 0.0
        for size in menu.sorted(by: >) where size > 0 {
            while size <= remaining + 1e-9 { remaining -= size; laid += size }
        }
        return laid
    }
    /// Every depth up to `upToMM` that packing reaches exactly, ascending (0 included).
    public static func reachable(menu: [Double], upToMM: Double) -> [Double] {
        guard upToMM > 0, !menu.isEmpty else { return [] }
        var out: [Double] = [0]
        var d = 0.0
        while d <= upToMM + 1e-9 {
            let l = laid(d, menu: menu)
            if l <= upToMM + 1e-9, abs(l - (out.last ?? -1)) > 1e-6 { out.append(l) }
            d += 0.05
        }
        return out
    }
    /// Per wall (selectable key), the reachable depths — ONE rule for the wizard's editor
    /// and the preview's bake, so what is drawn is what is laid. The base cell is the
    /// user's stated cell for that face, else the wall itself (Stepped derives the base
    /// from the wall; Fit sizes the cell to it). Organic: none — continuous.
    public static func forWalls(_ lattice: LatticeSettings, regions: [LatticeRegionSpec],
                                beadMM: Double) -> [String: [Double]] {
        guard lattice.algorithm != "organic" else { return [:] }
        // ★★ Q3(i) (2026-10-05): core's floor at the job's cap, the preview's own (one source).
        // No core number for the type ⇒ no steps (continuous), never a made-up floor.
        guard let floorMM = beadMM > 0
                ? LatticeSettings.tileFloorMM(topologyID: lattice.topologyID, beadMM: beadMM,
                                              allowQuilt: lattice.allowQuilt)
                : 0 else { return [:] }
        let structural = (lattice.stageMode ?? .structural) == .structural
        var out: [String: [Double]] = [:]
        for r in regions where r.role == .include && r.kind == .face && r.depthMM > 0 {
            guard let key = r.selectableKey else { continue }
            let stated = lattice.selectableCellMM[key] ?? 0
            let base = stated > 0 ? stated : r.depthMM
            let menu = LatticePreviewOccupancy.steppedSizeMenu(base: base, floorMM: floorMM, lineWidthMM: beadMM,
                                                         latticeID: lattice.topologyID, printsOpenBound: !structural)
            out[key] = reachable(menu: menu, upToMM: r.depthMM)
        }
        return out
    }
    /// The column pitch the editor draws on for a wall: its base cell (see `forWalls`).
    public static func columnMM(_ lattice: LatticeSettings, region r: LatticeRegionSpec) -> Double {
        guard lattice.algorithm != "organic" else { return 5 }
        let stated = r.selectableKey.flatMap { lattice.selectableCellMM[$0] } ?? 0
        return stated > 0 ? stated : max(1, r.depthMM)
    }
    /// The largest reachable depth at or under `mm` (the ask is never exceeded); a positive
    /// ask that fits nothing takes the smallest positive step, so a wall asked to have
    /// lattice is never silently left solid.
    public static func snap(_ mm: Double, steps: [Double]) -> Double {
        guard !steps.isEmpty else { return mm }
        let under = steps.filter { $0 <= mm + 1e-6 }.max() ?? 0
        if under > 0 || mm <= 1e-9 { return under }
        return steps.filter { $0 > 0 }.min() ?? mm
    }
}

/// One wall's own ask: the allowed range in mm from the outer surface (end nil = the
/// declared depth) and, for `manualGrade`, the profile drawn for it.
public struct LatticeFaceWallThickness: Codable, Hashable, Sendable {
    /// where the lattice may START, in mm from the surface (his 2026-09-21 22:40: "the
    /// user may have set the face for the lattice, but wanted the lattice to start
    /// further INSIDE") — 0 = at the surface
    public var startMM: Double = 0
    /// how deep the lattice may go (nil = the declared depth)
    public var endMM: Double? = nil
    /// the drawn profile, for `manualGrade`
    public var profile: LatticeWallProfile? = nil
    public init(startMM: Double = 0, endMM: Double? = nil, profile: LatticeWallProfile? = nil) {
        self.startMM = startMM; self.endMM = endMM; self.profile = profile
    }
    public var isFull: Bool { startMM <= 0 && endMM == nil && profile == nil }

    // ★★ ROUND 3 RULING (c) (maintainer, 2026-10-01): a wall saved between 604736ae and bc3cf67f
    // has no `startMM` — that build wrote only {endMM, profile}, and bc3cf67f brought the start
    // back as a stored field. Synthesized decoding ignores the `= 0` default and threw keyNotFound,
    // so his project 102117B9 vanished from the list. Absent ⇒ 0: where every wall started then,
    // and where the field's own range starts. DECODING ONLY — `encode(to:)` stays synthesized,
    // so every saved file re-encodes byte for byte as before.
    private enum CodingKeys: String, CodingKey { case startMM, endMM, profile }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startMM = try c.decodeIfPresent(Double.self, forKey: .startMM) ?? 0
        endMM = try c.decodeIfPresent(Double.self, forKey: .endMM)
        profile = try c.decodeIfPresent(LatticeWallProfile.self, forKey: .profile)
    }
}

/// What the user asked for — the request, not the answer. The default is the whole
/// prism, exactly as before the variable existed.
public struct LatticeWallThickness: Hashable, Sendable, Codable {
    /// ★ ON by default (his 2026-09-21, image 2: "the default it should be set at").
    public var depthBySim: Bool = true
    /// ★ "Graded by sim" first (his 2026-09-21, image 2); manual single at 100 % is the
    /// whole prism.
    public var density: LatticeWallDensityMode = .sim
    /// manualSingle: the share of the allowed range that is latticed, in percent.
    public var pct: Double = 100
    /// per wall, by the region's selectable key ("f:<group>:<face>")
    public var faces: [String: LatticeFaceWallThickness] = [:]
    /// ★ THE SEEDING BOOST (his 2026-09-21), ×1 = core's tracer as it is, up to ×3:
    /// seeds offered closer, short curves kept, curves allowed closer down to the
    /// printable floor. Preview only, like everything here.
    public var seedBoost: Double = 1

    public init() {}

    private enum CodingKeys: String, CodingKey { case depthBySim, density, pct, faces, seedBoost }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        depthBySim = try c.decodeIfPresent(Bool.self, forKey: .depthBySim) ?? true
        density = try c.decodeIfPresent(LatticeWallDensityMode.self, forKey: .density) ?? .sim
        pct = try c.decodeIfPresent(Double.self, forKey: .pct) ?? 100
        faces = try c.decodeIfPresent([String: LatticeFaceWallThickness].self, forKey: .faces) ?? [:]
        seedBoost = try c.decodeIfPresent(Double.self, forKey: .seedBoost) ?? 1
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(depthBySim, forKey: .depthBySim)
        try c.encode(density, forKey: .density)
        try c.encode(pct, forKey: .pct)
        if !faces.isEmpty { try c.encode(faces, forKey: .faces) }
        if seedBoost != 1 { try c.encode(seedBoost, forKey: .seedBoost) }
    }
    public init(depthBySim: Bool, density: LatticeWallDensityMode = .sim, pct: Double = 100,
                faces: [String: LatticeFaceWallThickness] = [:]) {
        self.depthBySim = depthBySim; self.density = density; self.pct = pct; self.faces = faces
    }
    /// The default every project starts from: the solve decides the depth.
    public static let standard = LatticeWallThickness()
    /// The whole prism, as before the variable existed.
    public static let through = LatticeWallThickness(depthBySim: false, density: .manualSingle, pct: 100)

    /// Nothing to apply: the prism is the slab.
    public var isThrough: Bool {
        !depthBySim && density == .manualSingle && pct >= 100 && faces.values.allSatisfy { $0.isFull }
    }
    public func face(_ key: String?) -> LatticeFaceWallThickness { faces[key ?? ""] ?? LatticeFaceWallThickness() }
}

/// The answer for one face: rasters over the face's (u, v) plane holding where the slab
/// STARTS and ENDS, in mm from the outer surface along the normal.
public struct LatticeWallThicknessMap: Equatable, Sendable {
    public let origin: SIMD2<Double>
    public let h: Double
    public let nu: Int, nv: Int
    public var starts: [Float]
    public var ends: [Float]

    public init(origin: SIMD2<Double>, h: Double, nu: Int, nv: Int, starts: [Float], ends: [Float]) {
        self.origin = origin; self.h = h; self.nu = nu; self.nv = nv; self.starts = starts; self.ends = ends
    }
    public static func constant(startMM: Double, endMM: Double) -> LatticeWallThicknessMap {
        LatticeWallThicknessMap(origin: .zero, h: 1, nu: 1, nv: 1, starts: [Float(startMM)], ends: [Float(endMM)])
    }
    public var isConstant: Bool { nu == 1 && nv == 1 }
    public var startMM: Double { Double(starts.min() ?? 0) }

    /// ★ NEAREST, NEVER INTERPOLATED (core note 3, 2026-09-21): the drawing is steps and
    /// "what is drawn is what is laid" only holds if the raster is read piecewise-constant.
    /// A bilinear read here smoothed every staircase into ramps that looked entirely
    /// reasonable. The SDF is trilinear; this is a different instrument.
    private func sample(_ a: [Float], at uv: SIMD2<Double>, fallback: Double) -> Double {
        guard nu > 0, nv > 0, a.count == nu * nv else { return fallback }
        let i = Int(min(max(((uv.x - origin.x) / h).rounded(), 0), Double(nu - 1)))
        let j = Int(min(max(((uv.y - origin.y) / h).rounded(), 0), Double(nv - 1)))
        let s = Double(a[j * nu + i])
        return s.isFinite ? s : fallback
    }
    /// The raster cell holding `uv` (nearest sample), for readers that lay geometry per cell.
    public func cell(at uv: SIMD2<Double>) -> (i: Int, j: Int) {
        (Int(min(max(((uv.x - origin.x) / h).rounded(), 0), Double(max(0, nu - 1)))),
         Int(min(max(((uv.y - origin.y) / h).rounded(), 0), Double(max(0, nv - 1)))))
    }
    /// The slab at `uv`: [start, end] in mm from the outer surface.
    public func range(at uv: SIMD2<Double>, depthMM: Double) -> (start: Double, end: Double) {
        let s = sample(starts, at: uv, fallback: 0), e = sample(ends, at: uv, fallback: depthMM)
        return (min(max(0, s), depthMM), min(max(s, e), depthMM))
    }
    public var summary: (p05: Double, p50: Double, p95: Double) {
        let t = zip(starts, ends).map { Double($1 - $0) }.filter { $0.isFinite }.sorted()
        guard !t.isEmpty else { return (0, 0, 0) }
        func q(_ f: Double) -> Double { t[min(t.count - 1, Int(Double(t.count - 1) * f))] }
        return (q(0.05), q(0.5), q(0.95))
    }
}

public enum LatticeWallThicknessBuilder {

    /// The part's reference stress for the sim rule: the 95th percentile of von Mises over
    /// every voxel inside any include face prism (the WHOLE prism, before any slab), so a
    /// dead wall reads thin and a loaded one thick — per part, not per wall.
    public static func referenceMPa(field: StressField, regions: [LatticeRegionSpec]) -> Double {
        var vals: [Float] = []
        let faces = regions.filter { $0.role == .include && $0.kind == .face && $0.depthMM > 0 }
        guard !faces.isEmpty, field.values.count == field.nx * field.ny * field.nz else { return 0 }
        for k in 0..<field.nz { for j in 0..<field.ny { for i in 0..<field.nx {
            let p = SIMD3<Double>(field.origin) + SIMD3<Double>(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * Double(field.spacing)
            let v = field.values[(k * field.ny + j) * field.nx + i]
            guard v.isFinite, v > 0 else { continue }
            var inside = false
            for r in faces where LatticeRegionMask.containsWholePrism(p, region: r) { inside = true; break }
            if inside { vals.append(v) }
        } } }
        guard !vals.isEmpty else { return 0 }
        vals.sort()
        return Double(vals[min(vals.count - 1, Int(Double(vals.count - 1) * 0.95))])
    }

    /// The face's own frame: (u, v) basis, the outline's bounds, and which in-plane axis
    /// is the wall's WIDTH (the longer one) — the x of a drawn profile.
    public struct FaceFrame {
        public let bu: SIMD3<Double>, bv: SIMD3<Double>
        public let lo: SIMD2<Double>, hi: SIMD2<Double>
        public let widthAlongU: Bool
        /// ★ A WALL SPLIT INTO FACETS (review 2026-09-22 #27): one drawn profile spans the
        /// whole wall, so every facet reads its x along the SAME world axis — the wall's
        /// chord — from the same end; per-facet frames stretched the whole drawing across
        /// each facet. `origin3` is the region's own origin (uv → world).
        public var shared: (origin3: SIMD3<Double>, axis: SIMD3<Double>, lo: Double, extent: Double)? = nil
        public var widthMM: Double { shared?.extent ?? (widthAlongU ? hi.x - lo.x : hi.y - lo.y) }
        /// 0…1 across the wall's width at `uv`.
        public func x(at uv: SIMD2<Double>) -> Double {
            if let s = shared, s.extent > 1e-9 {
                let p = s.origin3 + bu * uv.x + bv * uv.y
                return min(1, max(0, (simd_dot(p, s.axis) - s.lo) / s.extent))
            }
            let w = widthMM
            guard w > 1e-9 else { return 0 }
            return min(1, max(0, (widthAlongU ? uv.x - lo.x : uv.y - lo.y) / w))
        }
    }
    /// The shared width axis of a wall's facet regions (all under one selectable key): the
    /// longer in-plane extent of their outlines in the plane of the mean normal.
    public static func sharedAxis(_ group: [LatticeRegionSpec]) -> (axis: SIMD3<Double>, lo: Double, extent: Double)? {
        guard group.count > 1 else { return nil }
        var nSum = SIMD3<Double>.zero
        for r in group { nSum += LatticeRegionMask.unit(r.normal) }
        guard simd_length(nSum) > 1e-6 else { return nil }
        let (tu, tv) = LatticeRegionMask.basis(simd_normalize(nSum))
        var lo = SIMD2<Double>(1e9, 1e9), hi = SIMD2<Double>(-1e9, -1e9)
        for r in group {
            let n = LatticeRegionMask.unit(r.normal)
            guard simd_length(n) > 0.5 else { continue }
            let (bu, bv) = LatticeRegionMask.basis(n)
            for loop in r.outlineLoops { for q in loop {
                let p = r.origin + bu * q.x + bv * q.y
                let t = SIMD2<Double>(simd_dot(p, tu), simd_dot(p, tv))
                lo = simd_min(lo, t); hi = simd_max(hi, t)
            } }
        }
        guard hi.x > lo.x || hi.y > lo.y else { return nil }
        return (hi.x - lo.x) >= (hi.y - lo.y) ? (tu, lo.x, hi.x - lo.x) : (tv, lo.y, hi.y - lo.y)
    }
    public static func frame(_ r: LatticeRegionSpec) -> FaceFrame? {
        let n = LatticeRegionMask.unit(r.normal)
        guard simd_length(n) > 0.5 else { return nil }
        let (bu, bv) = LatticeRegionMask.basis(n)
        var lo = SIMD2<Double>(1e9, 1e9), hi = SIMD2<Double>(-1e9, -1e9)
        for loop in r.outlineLoops { for q in loop { lo = simd_min(lo, q); hi = simd_max(hi, q) } }
        if r.outlineLoops.isEmpty { lo = SIMD2(-r.halfUMM, -r.halfWMM); hi = SIMD2(r.halfUMM, r.halfWMM) }
        guard lo.x < hi.x, lo.y < hi.y else { return nil }
        return FaceFrame(bu: bu, bv: bv, lo: lo, hi: hi, widthAlongU: (hi.x - lo.x) >= (hi.y - lo.y))
    }

    /// The map for one face, or nil when the request is the whole prism. `floorMM` is
    /// one cell — the slab is never thinner where there is room.
    public static func build(region r: LatticeRegionSpec, spec: LatticeWallThickness,
                             field: StressField?, referenceMPa: Double,
                             floorMM: Double, depthSteps: [Double]? = nil,
                             sharedAxis: (axis: SIMD3<Double>, lo: Double, extent: Double)? = nil,
                             autoShare: Double? = nil) -> LatticeWallThicknessMap? {
        guard r.role == .include, r.kind == .face, r.depthMM > 0, !spec.isThrough else { return nil }
        let depth = r.depthMM
        let ask = spec.face(r.selectableKey)
        // the allowed range, from the outer surface in
        let a0 = spec.depthBySim ? 0 : min(max(0, ask.startMM), depth * 0.95)
        let a1 = spec.depthBySim ? depth : min(max(a0, ask.endMM ?? depth), depth)
        let room = max(0, a1 - a0)
        let floorT = min(room, max(0, floorMM))
        func frame(_ r: LatticeRegionSpec) -> FaceFrame? {
            guard var fr = Self.frame(r) else { return nil }
            if let s = sharedAxis { fr.shared = (r.origin, s.axis, s.lo, s.extent) }
            return fr
        }
        // ★ every end lands on a depth the wall can be packed to (D1); the ask is never exceeded
        // ★ the floor is ONE CELL OF SLAB — measured from the slab's start `a0`, not from the
        // surface (review #29: a start of 4 with a floor of 2 kept ends at 2, inside the start)
        func finish(_ e: Double) -> Double {
            let v = min(a1, max(a0 + floorT, e))
            guard let steps = depthSteps, !steps.isEmpty else { return v }
            // ★ steps are laid from the slab's START `a0`, not from the face (2026-09-23):
            // a wall whose allowed range begins deeper packs its cells from there
            return min(a1, max(a0, a0 + LatticeWallDepthSteps.snap(v - a0, steps: steps)))
        }
        func endFor(share: Double) -> Double { finish(a0 + min(1, max(0, share)) * room) }

        let mode: LatticeWallDensityMode = spec.depthBySim ? .sim : spec.density
        switch mode {
        case .manualSingle:
            return .constant(startMM: a0, endMM: endFor(share: spec.pct / 100))
        case .manualGrade:
            guard let fr = frame(r), let prof = ask.profile else {
                return .constant(startMM: a0, endMM: a1)
            }
            // ★ the pitch divides a drawn column exactly, so every step edge is a raster edge
            // (curves: the plain pitch — nothing to align)
            let colMM = prof.isCurves ? fr.widthMM : fr.widthMM / Double(max(1, prof.columns))
            let per = max(1, Int((colMM / max(0.5, fr.widthMM / 96)).rounded(.up)))
            let h = max(0.05, colMM / Double(per))
            // samples at CELL CENTRES, so a nearest read's cell edges are the column edges
            let nu = max(1, Int(((fr.hi.x - fr.lo.x) / h).rounded(.up)))
            let nv = max(1, Int(((fr.hi.y - fr.lo.y) / h).rounded(.up)))
            let origin = fr.lo + SIMD2(0.5 * h, 0.5 * h)
            var starts = [Float](repeating: 0, count: nu * nv), ends = [Float](repeating: 0, count: nu * nv)
            for j in 0..<nv { for i in 0..<nu {
                let uv = origin + SIMD2(Double(i), Double(j)) * h
                let x = fr.x(at: uv)
                // the profile is drawn over the WHOLE wall thickness, then held inside the range;
                // steps land on the wall's packable depths, curves stay where they were drawn
                var sv = min(max(prof.start(at: x) * depth, a0), a1)
                var e = min(max(prof.end(at: x) * depth, a0), a1)
                if e < sv { swap(&sv, &e) }
                if let steps = depthSteps, !steps.isEmpty, !prof.isCurves {
                    // ★ the start never snaps below the allowed start (review #30)
                    // ★ relative to the slab's start `a0` (2026-09-23)
                    sv = max(a0, min(a1, a0 + LatticeWallDepthSteps.snap(sv - a0, steps: steps.filter { $0 <= a1 - a0 + 1e-9 } + [0])))
                    e = e <= sv + 1e-9 ? sv : max(sv, min(a1, a0 + LatticeWallDepthSteps.snap(e - a0, steps: steps)))
                }
                if e - sv < floorT, e > sv + 1e-9 { e = min(a1, sv + floorT); sv = max(a0, e - floorT) }
                starts[j * nu + i] = Float(sv); ends[j * nu + i] = Float(e)
            } }
            return LatticeWallThicknessMap(origin: origin, h: h, nu: nu, nv: nv, starts: starts, ends: ends)
        case .sim, .autoSingle:
            guard let fr = frame(r), let field, referenceMPa > 0,
                  field.values.count == field.nx * field.ny * field.nz else {
                return .constant(startMM: a0, endMM: a1)      // no solve to read: the range
            }
            guard let raster = peakRaster(region: r, frame: fr, field: field, referenceMPa: referenceMPa) else {
                return .constant(startMM: a0, endMM: a1)
            }
            let (lo, h, nu, nv, peak) = raster
            if mode == .autoSingle {
                if let share = autoShare { return .constant(startMM: a0, endMM: endFor(share: share)) }
                let s = peak.filter { $0.isFinite }.sorted()
                let p95 = Double(s[min(s.count - 1, Int(Double(s.count - 1) * 0.95))])
                return .constant(startMM: a0, endMM: endFor(share: p95))
            }
            var starts = [Float](repeating: Float(a0), count: nu * nv), ends = [Float](repeating: .nan, count: nu * nv)
            for e in 0..<peak.count where peak[e].isFinite { ends[e] = Float(endFor(share: Double(peak[e]))) }
            for e in 0..<ends.count where ends[e].isNaN { ends[e] = Float(a1); starts[e] = Float(a0) }
            // ★ the raster binned voxels into cells [lo + i·h, lo + (i+1)·h); the map reads
            // NEAREST to its origin + i·h, so the origin is the first cell's CENTRE (review #28)
            return LatticeWallThicknessMap(origin: lo + SIMD2(0.5 * h, 0.5 * h), h: h, nu: nu, nv: nv, starts: starts, ends: ends)
        }
    }

    /// The per-cell peak stress share (0…1 of `referenceMPa`) over a face prism, on a
    /// half-voxel in-plane raster from `lo`; NaN where no voxel landed within three cells.
    static func peakRaster(region r: LatticeRegionSpec, frame fr: FaceFrame, field: StressField,
                           referenceMPa: Double) -> (lo: SIMD2<Double>, h: Double, nu: Int, nv: Int, peak: [Float])? {
        guard referenceMPa > 0, field.values.count == field.nx * field.ny * field.nz else { return nil }
        do {
            let h = max(0.5, Double(field.spacing) * 0.5)
            let lo = fr.lo - SIMD2(h, h), hi = fr.hi + SIMD2(h, h)
            let nu = Int(((hi.x - lo.x) / h).rounded(.up)) + 1
            let nv = Int(((hi.y - lo.y) / h).rounded(.up)) + 1
            var peak = [Float](repeating: .nan, count: nu * nv)
            let (lo3, hi3) = prismBounds(r)
            let g0v = (lo3 - SIMD3<Double>(field.origin)) / Double(field.spacing)
            let g1v = (hi3 - SIMD3<Double>(field.origin)) / Double(field.spacing)
            let g0 = pointwiseMax(SIMD3<Int>(0, 0, 0), SIMD3<Int>(g0v, rounding: .down) &- 1)
            let g1 = pointwiseMin(SIMD3<Int>(field.nx - 1, field.ny - 1, field.nz - 1), SIMD3<Int>(g1v, rounding: .up) &+ 1)
            if g0.x <= g1.x, g0.y <= g1.y, g0.z <= g1.z {
                for k in g0.z...g1.z { for j in g0.y...g1.y { for i in g0.x...g1.x {
                    let p = SIMD3<Double>(field.origin) + SIMD3<Double>(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * Double(field.spacing)
                    guard LatticeRegionMask.containsWholePrism(p, region: r) else { continue }
                    let v = field.values[(k * field.ny + j) * field.nx + i]
                    guard v.isFinite else { continue }
                    let d = p - r.origin
                    let uv = SIMD2<Double>(simd_dot(d, fr.bu), simd_dot(d, fr.bv))
                    let ci = min(nu - 1, max(0, Int((uv.x - lo.x) / h)))
                    let cj = min(nv - 1, max(0, Int((uv.y - lo.y) / h)))
                    let e = cj * nu + ci
                    let s = Float(min(1, Double(max(0, v)) / referenceMPa))
                    if peak[e].isNaN || s > peak[e] { peak[e] = s }
                } } }
            }
            for _ in 0..<3 {                       // cells no voxel landed in take a neighbour's
                var next = peak
                for j in 0..<nv { for i in 0..<nu where peak[j * nu + i].isNaN {
                    var best: Float = .nan
                    for dj in -1...1 { for di in -1...1 {
                        let ii = i + di, jj = j + dj
                        guard ii >= 0, jj >= 0, ii < nu, jj < nv else { continue }
                        let v = peak[jj * nu + ii]
                        if v.isFinite, best.isNaN || v > best { best = v }
                    } }
                    next[j * nu + i] = best
                } }
                peak = next
            }
            guard peak.contains(where: { $0.isFinite }) else { return nil }
            return (lo, h, nu, nv, peak)
        }
    }

    /// The world-space box around a face prism (outline bounds × depth), for a bounded scan.
    static func prismBounds(_ r: LatticeRegionSpec) -> (SIMD3<Double>, SIMD3<Double>) {
        let n = LatticeRegionMask.unit(r.normal)
        let (bu, bv) = LatticeRegionMask.basis(n)
        var lo = SIMD3<Double>(repeating: 1e9), hi = SIMD3<Double>(repeating: -1e9)
        for loop in r.outlineLoops { for q in loop { for s in [0.0, r.depthMM] {
            let p = r.origin + bu * q.x + bv * q.y + n * s
            lo = simd_min(lo, p); hi = simd_max(hi, p)
        } } }
        if r.outlineLoops.isEmpty {
            for su in [-r.halfUMM, r.halfUMM] { for sv in [-r.halfWMM, r.halfWMM] { for s in [0.0, r.depthMM] {
                let p = r.origin + bu * su + bv * sv + n * s
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            } } }
        }
        return (lo, hi)
    }

    /// Attach a map to every include face that asked for one. The preview's own regions
    /// carry the answer; the job's copy never sees it.
    public static func attach(_ regions: [LatticeRegionSpec], field: StressField?,
                              floorMM: Double,
                              depthStepsFor: ((LatticeRegionSpec) -> [Double]?)? = nil) -> [LatticeRegionSpec] {
        guard regions.contains(where: { $0.thickness.map { !$0.isThrough } ?? false }) else { return regions }
        let needsField = regions.contains { r in
            guard let t = r.thickness else { return false }
            return t.depthBySim || t.density.readsTheSolve
        }
        let ref = (needsField && field != nil) ? referenceMPa(field: field!, regions: regions) : 0
        var out = regions
        // ★ PER WALL, NOT PER FACET (review #27): a curved wall is several facet regions
        // under one selectable key; they share the drawn profile's axis and one auto share.
        var groups: [String: [Int]] = [:]
        for (i, r) in regions.enumerated() where r.role == .include && r.kind == .face && r.thickness != nil {
            groups[r.selectableKey ?? "#\(i)", default: []].append(i)
        }
        var axisFor: [Int: (axis: SIMD3<Double>, lo: Double, extent: Double)] = [:]
        var shareFor: [Int: Double] = [:]
        for (_, idx) in groups where idx.count > 1 {
            if let ax = sharedAxis(idx.map { regions[$0] }) { for i in idx { axisFor[i] = ax } }
            guard let spec = regions[idx[0]].thickness, !spec.depthBySim, spec.density == .autoSingle,
                  let field, ref > 0 else { continue }
            var all: [Float] = []
            for i in idx {
                guard let fr = frame(regions[i]),
                      let raster = peakRaster(region: regions[i], frame: fr, field: field, referenceMPa: ref) else { continue }
                all += raster.peak.filter { $0.isFinite }
            }
            guard !all.isEmpty else { continue }
            all.sort()
            let p95 = Double(all[min(all.count - 1, Int(Double(all.count - 1) * 0.95))])
            for i in idx { shareFor[i] = p95 }
        }
        for i in out.indices {
            guard let spec = out[i].thickness else { continue }
            out[i].thicknessMap = build(region: out[i], spec: spec, field: field,
                                        referenceMPa: ref, floorMM: floorMM,
                                        depthSteps: depthStepsFor?(out[i]),
                                        sharedAxis: axisFor[i], autoShare: shareFor[i])
        }
        return out
    }
}
