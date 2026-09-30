// FlexibleProbe — what a tap reads on the Flexible pages (task 2026-09-29-flexible-screens,
// round 3 batch C, item 1.4; maintainer: "each data view has its own legend … tapping a
// legend switches it to 'Tap the part to read'; any tap on the part then pins a callout at
// that spot with the exact value and unit, and a double tap exits").
//
// ★ THREE KINDS, THREE STABLE IDS. Each legend drills in through the main page's own
// `latticeLegendMode = .colour(id)` (#354's key), so its gates — the face tap consumed, the
// primitives hidden, the double tap out — come for free. The ids are fixed literals, never an
// octet class's (FlexibleMainViewsTests pins both).
//
// ★ EVERY READING IS TAKEN AT THE REST POINT OF WHAT HE TAPPED.
//   * DENT: the CPU picker hits the UNDENTED mesh, but he sees the dent drawn ×k. The ray is
//     rebuilt from the tap's rest point and the view, cast against the map quads AS DRAWN
//     (rest + scale × dent), and the column whose drawn quad it meets is read — the same
//     number its colour came from (FlexibleShownValues). Reading the rest surface under the
//     ray instead is a neighbour column at an oblique view (the test's red control).
//   * STRESS: the field of the SOLID part at the rest point (LatticeStressTint.sample); a
//     surface point half a voxel outside the voxel-centre grid reads its nearest voxel.
//   * LATTICE: the wall the G-buffer probe found, PULLED BACK through the squish
//     (FlexibleSquishField.pullback) — ρ and the cell there, not at the drawn point.
// Nothing here computes a squish, a stress or a density: each is read from the array the
// picture was drawn from.

import Foundation
import simd
import TopOptDesign
import TopOptKit

/// A data view on the main Flexible page with its own legend (X-ray has none — his answer).
public enum FlexibleReadKind: String, CaseIterable, Identifiable, Sendable {
    case dent, stress, lattice

    /// ★ STABLE, and never an octet class's id (the octet key's drill-in would read it).
    public var id: UUID {
        switch self {
        case .dent: return Self.dentID
        case .stress: return Self.stressID
        case .lattice: return Self.latticeID
        }
    }
    static let dentID = UUID(uuidString: "F1E71B1E-0001-4D3E-8A55-0000000000D1")!
    static let stressID = UUID(uuidString: "F1E71B1E-0002-4D3E-8A55-0000000000D2")!
    static let latticeID = UUID(uuidString: "F1E71B1E-0003-4D3E-8A55-0000000000D3")!

    /// The kind a drilled-in key is reading, or nil (the groups list, or an octet class).
    public init?(mode: LatticeLegendMode) {
        guard let id = mode.groupID, let k = Self.allCases.first(where: { $0.id == id }) else { return nil }
        self = k
    }
    public var mode: LatticeLegendMode { .colour(id) }

    /// ★ BATCH C VERIFICATION: the dent legend's line while the map shows HIS drawing (no
    /// lattice drawn, or a shape-only one that predicts no squish) — FlexibleMainStage.legendTitle.
    public static let drawnTitle = "What you drew · mm"
    /// The dent legend's line for the lattice the map is drawn from (nil: his live drawing).
    public static func dentTitle(drawn: FlexibleGeneratedLattice?) -> String {
        guard let g = drawn, !g.shapeOnly else { return drawnTitle }
        return FlexibleReadKind.dent.title
    }

    /// The legend's one line (his words).
    public var title: String {
        switch self {
        case .dent: return "Squish · mm"
        case .stress: return "Stress in the solid part · MPa"
        case .lattice: return "Lattice · density"
        }
    }
    public var unit: String {
        switch self {
        case .dent: return "mm"
        case .stress: return "MPa"
        case .lattice: return "%"
        }
    }
    /// The minimised legend's word.
    public var short: String {
        switch self {
        case .dent: return "Squish"
        case .stress: return "Stress"
        case .lattice: return "Lattice"
        }
    }
    /// Behind the (i): ONE sentence (batch C verification: each was two).
    public var info: String {
        switch self {
        case .dent: return "What you drew, drawn deeper so it reads — tap here, then the part, for the true mm there."
        case .stress: return "Where the main page's loads go in the SOLID part, not the TPU lattice — tap here, then the part, for MPa there."
        case .lattice: return "How dense the walls are (denser is firmer) — tap here, then a wall, for its density and cell."
        }
    }
    /// What a tap that finds nothing to read says.
    public var nothingHere: String {
        switch self {
        case .dent: return "no squish here"
        case .stress: return "outside the solve"
        case .lattice: return "no wall here"
        }
    }

    /// The legend's ramp: the dent's own DS ramp (never purple), Stress's rainbow, the walls'
    /// pale → green (FlexibleLatticePass's own colours).
    @MainActor
    public func rampColour(_ f: Double) -> RGBA {
        switch self {
        case .dent: return FlexibleColours.depthColour(fraction: f)
        case .stress:
            let c = LatticeStressTint.colour(fraction: f)
            return RGBA(Double(c.x) * 255, Double(c.y) * 255, Double(c.z) * 255)
        case .lattice: return FlexibleProbe.latticeColour(fraction: f)
        }
    }

    /// The names of the ids in `ids` that an EARLIER entry already took (empty: all unique).
    public static func duplicateIDs(_ ids: [(name: String, id: UUID)]) -> [String] {
        var seen = Set<UUID>(), out: [String] = []
        for (name, id) in ids { if !seen.insert(id).inserted { out.append(name) } }
        return out
    }
}

/// One reading, pinned at a MODEL point (re-projected every render, so it rides an orbit).
public struct FlexibleReading: Equatable, Sendable {
    public var kind: FlexibleReadKind
    /// "2.43", "0.84", "22%" — or "—" when there is nothing to read there.
    public var value: String
    public var unit: String
    /// Where the value sits on its legend's ramp (0…1), nil for "nothing here".
    public var fraction: Double?
    public var anchor: SIMD3<Float>

    public init(kind: FlexibleReadKind, value: String, unit: String, fraction: Double?, anchor: SIMD3<Float>) {
        self.kind = kind; self.value = value; self.unit = unit; self.fraction = fraction; self.anchor = anchor
    }
    /// The callout's one line.
    public var text: String { "\(value) \(unit)" }
    public var isEmpty: Bool { fraction == nil }
}

public enum FlexibleProbe {

    // MARK: the dent

    public struct DentHit: Equatable, Sendable {
        public let key: FlexFaceKey
        public let column: Int
        /// Where the ray meets the drawn quad (model space).
        public let point: SIMD3<Float>
        /// The ray parameter (distance from the origin, `dir` unit).
        public let t: Float
        /// The same point of the quad at REST (its barycentric place on the undented triangle) —
        /// where the quad's colour was sampled.
        public var rest: SIMD3<Float> = .zero
    }

    /// The first map quad, AS DRAWN (rest + `scale` × dent), that the ray meets — nil when it
    /// meets none. `columns[k]`: face k's column count (its quads start at overlay.flatStart).
    /// `scale` 0 reads the undented quads (the rest surface).
    public static func dentHit(origin: SIMD3<Float>, dir: SIMD3<Float>, overlay: FlexibleOverlayMesh,
                               columns: [FlexFaceKey: Int], dents: [Float]?, scale: Float) -> DentHit? {
        let pos = overlay.mesh.flat.positions
        let n = overlay.mesh.flat.vertexCount
        let d = dents.flatMap { $0.count == n * 3 ? $0 : nil }
        func at(_ v: Int) -> SIMD3<Float> {
            var p = SIMD3<Float>(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2])
            if let d, scale != 0 { p += scale * SIMD3<Float>(d[3 * v], d[3 * v + 1], d[3 * v + 2]) }
            return p
        }
        func rest(_ v: Int) -> SIMD3<Float> { SIMD3<Float>(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2]) }
        var best: DentHit?
        for (key, start) in overlay.flatStart {
            let count = columns[key] ?? 0
            for c in 0..<count {
                let q = start + c * 6
                guard q + 5 < n else { break }
                for tri in [(q, q + 1, q + 2), (q + 3, q + 4, q + 5)] {
                    guard let h = rayTriangleUV(origin, dir, at(tri.0), at(tri.1), at(tri.2)), h.t > 0 else { continue }
                    if best == nil || h.t < best!.t {
                        let r = (1 - h.u - h.v) * rest(tri.0) + h.u * rest(tri.1) + h.v * rest(tri.2)
                        best = DentHit(key: key, column: c, point: origin + dir * h.t, t: h.t, rest: r)
                    }
                }
            }
        }
        return best
    }

    /// The drawn (dented) map under a tap, from the tap's rest `point` along the view `dir`:
    /// where it is drawn and where that point sits at rest. `onlyIfOnMap` (X-ray off): only
    /// when the tap itself landed on the map. The dent probe's cast, for the Stress reading.
    @MainActor
    public static func drawnMapHit(model: FlexibleStageModel, overlay: FlexibleOverlayMesh, dents: [Float]?, scale: Float,
                                   point: SIMD3<Float>, dir: SIMD3<Float>, onlyIfOnMap: Bool) -> (point: SIMD3<Float>, rest: SIMD3<Float>)? {
        guard simd_length_squared(dir) > 1e-12 else { return nil }
        let u = simd_normalize(dir)
        var cols: [FlexFaceKey: Int] = [:]
        for (k, st) in model.stacks { cols[k] = st.columns.count }
        let b = overlay.mesh.bounds
        let origin = point - u * (simd_length(b.max - b.min) * 4 + 100)
        if onlyIfOnMap {
            guard let r = dentHit(origin: origin, dir: u, overlay: overlay, columns: cols, dents: nil, scale: 0),
                  simd_distance(r.point, point) < 0.3 else { return nil }
        }
        guard let h = dentHit(origin: origin, dir: u, overlay: overlay, columns: cols, dents: dents, scale: scale) else { return nil }
        return (h.point, h.rest)
    }

    /// `rayTriangle` with the hit's barycentric (u, v) on (a → b, a → c).
    static func rayTriangleUV(_ o: SIMD3<Float>, _ d: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>,
                              _ c: SIMD3<Float>) -> (t: Float, u: Float, v: Float)? {
        let e1 = b - a, e2 = c - a
        let p = simd_cross(d, e2)
        let det = simd_dot(e1, p)
        guard abs(det) > 1e-12 else { return nil }
        let inv = 1 / det
        let s = o - a
        let u = simd_dot(s, p) * inv
        guard u >= -1e-5, u <= 1 + 1e-5 else { return nil }
        let q = simd_cross(s, e1)
        let v = simd_dot(d, q) * inv
        guard v >= -1e-5, u + v <= 1 + 1e-5 else { return nil }
        return (simd_dot(e2, q) * inv, u, v)
    }

    /// Möller–Trumbore, two-sided (a map quad is seen from either side in X-ray).
    static func rayTriangle(_ o: SIMD3<Float>, _ d: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float? {
        let e1 = b - a, e2 = c - a
        let p = simd_cross(d, e2)
        let det = simd_dot(e1, p)
        guard abs(det) > 1e-12 else { return nil }
        let inv = 1 / det
        let s = o - a
        let u = simd_dot(s, p) * inv
        guard u >= -1e-5, u <= 1 + 1e-5 else { return nil }
        let q = simd_cross(s, e1)
        let v = simd_dot(d, q) * inv
        guard v >= -1e-5, u + v <= 1 + 1e-5 else { return nil }
        return simd_dot(e2, q) * inv
    }

    /// The dent he TAPPED, read: the ray from the tap's rest `point` along the view `dir`, cast
    /// against the drawn map; that column's value from FlexibleShownValues (the colour's own
    /// number). `onlyIfOnMap` (X-ray off, the body opaque): only when the tap itself landed on
    /// the map — a tap on the part's own surface cannot see a map behind it.
    @MainActor
    public static func dentReading(model: FlexibleStageModel, overlay: FlexibleOverlayMesh?, dents: [Float]?, scale: Float,
                                   drawnLattice: FlexibleGeneratedLattice?, point: SIMD3<Float>, dir: SIMD3<Float>,
                                   onlyIfOnMap: Bool = false) -> FlexibleReading? {
        guard let overlay, simd_length_squared(dir) > 1e-12 else { return nil }
        let u = simd_normalize(dir)
        var cols: [FlexFaceKey: Int] = [:]
        for (k, st) in model.stacks { cols[k] = st.columns.count }
        let b = overlay.mesh.bounds
        let reach = simd_length(b.max - b.min) * 4 + 100
        let origin = point - u * reach
        if onlyIfOnMap {
            guard let rest = dentHit(origin: origin, dir: u, overlay: overlay, columns: cols, dents: nil, scale: 0),
                  simd_distance(rest.point, point) < 0.3 else { return nil }
        }
        guard let hit = dentHit(origin: origin, dir: u, overlay: overlay, columns: cols, dents: dents, scale: scale) else { return nil }
        let shown = FlexibleShownValues(model: model, drawnLattice: drawnLattice)
        guard let vals = shown.values[hit.key], hit.column < vals.count else { return nil }
        switch vals[hit.column] {
        case .depth(let mm):
            return FlexibleReading(kind: .dent, value: String(format: "%.2f", mm), unit: "mm",
                                   fraction: shown.maxDepth > 0 ? mm / shown.maxDepth : 0, anchor: hit.point)
        case .noNumber:
            return FlexibleReading(kind: .dent, value: "—", unit: "no number here", fraction: nil, anchor: hit.point)
        case .solid:
            return FlexibleReading(kind: .dent, value: "0", unit: "mm · solid here", fraction: 0, anchor: hit.point)
        }
    }

    // MARK: stress

    /// MPa to THREE significant digits ("0.0462", "1.50", "12.3", "123") — his pad peaks at
    /// 0.046 MPa, where "%.2f" read 0.00 … 0.05 (batch C verification; the octet key reads %.3f).
    public static func mpa(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        let a = abs(v)
        if a == 0 { return "0" }
        let digits = Swift.max(0, 2 - Int(log10(a).rounded(.down)))
        return String(format: "%.\(digits)f", v)
    }

    /// The solid part's von Mises at `p` (MPa): the field's own trilinear sample; a point up to
    /// one voxel outside the voxel-centre grid (the part's own surface) reads the nearest point
    /// of the grid's box. nil further out — no number the solve did not make.
    public static func stress(_ f: LatticeDemandField, at p: SIMD3<Float>) -> Double? {
        let q = SIMD3<Double>(p)
        if let v = LatticeStressTint.sample(f, at: q) { return v }
        guard f.spacingMM > 0, f.nx > 0, f.ny > 0, f.nz > 0 else { return nil }
        let hi = f.origin + SIMD3<Double>(Double(f.nx - 1), Double(f.ny - 1), Double(f.nz - 1)) * f.spacingMM
        let c = simd_min(simd_max(q, f.origin), hi)
        guard simd_distance(c, q) <= f.spacingMM else { return nil }
        return LatticeStressTint.sample(f, at: c)
    }

    // MARK: the lattice

    public struct LatticeRead: Equatable, Sendable {
        public let rho: Double
        /// The cell DRAWN there (`drawnCell`: the ladder's rung, or the blend of two).
        public let cellMM: Double
        /// Inside a blend of two rungs (the reading says "≈").
        public var cellBlended = false
        /// The rest point the wall was drawn from (the squish pulled back).
        public let rest: SIMD3<Float>
    }

    /// The wall at the DRAWN point `p` (what the G-buffer probe returns), read at its rest
    /// point under squish `s` (the renderer's flexScale). nil in the air a pressed face left.
    public static func lattice(_ inputs: FlexibleLatticeInputs, faces: [FlexibleSquishFace], squish s: Float,
                               at p: SIMD3<Float>, fe: FlexibleFEField? = nil) -> LatticeRead? {
        // ★ BATCH G: through the squish sim's field when one moves the walls
        if let fe {
            let p0 = fe.pullback(p, s)
            let rho = Double(inputs.rho.sample(p0))
            let c = drawnCell(rho: rho, inputs)
            return LatticeRead(rho: rho, cellMM: c.mm, cellBlended: c.blended, rest: p0)
        }
        let pb = FlexibleSquishField.pullback(p, faces: faces, squish: s)
        guard pb.air <= 0 else { return nil }
        let rho = Double(inputs.rho.sample(pb.p0))
        let c = drawnCell(rho: rho, inputs)
        return LatticeRead(rho: rho, cellMM: c.mm, cellBlended: c.blended, rest: pb.p0)
    }

    /// ★ BATCH C VERIFICATION: the cell the walls are DRAWN with at ρ. The gyroid is a ladder of
    /// true gyroids (FlexibleLatticeField.rungs, Lmin·2^(j/4)): a pure rung where the blend
    /// weight is 0 or 1, else the blended wavenumber's cell ((1−w)·ka + w·kb) — not the
    /// continuous law 3.0915·t/ρ, which is up to ~4 % off what is drawn (his t = 0.42 mm at
    /// ρ 0.22: the law 5.90 mm, the rung 5.77 mm). The honeycomb: its one d.
    public static func drawnCell(rho: Double, _ f: FlexibleLatticeInputs) -> (mm: Double, blended: Bool) {
        switch f.topology {
        case .honeycomb: return (Double(f.honeycombCellMM), false)
        case .gyroid:
            let L = Float(cellMM(rho: rho, f))
            let r = FlexibleLatticeField.rungs(L: L, lMin: f.lMinMM)
            if r.w <= 0 { return (Double(r.La), false) }
            if r.w >= 1 { return (Double(r.Lb), false) }
            let k = (1 - r.w) * (2 * Float.pi / r.La) + r.w * (2 * Float.pi / r.Lb)
            return (Double(2 * Float.pi / k), true)
        }
    }

    /// The cell the field INTENDS at ρ (FlexibleLatticeField): the gyroid's L = 3.0915·t/ρ in
    /// [Lmin, Lmax] (the ladder then draws `drawnCell`); the honeycomb's one d.
    public static func cellMM(rho: Double, _ f: FlexibleLatticeInputs) -> Double {
        switch f.topology {
        case .honeycomb: return Double(f.honeycombCellMM)
        case .gyroid:
            let r = Swift.min(Swift.max(rho, 0.05), 0.9)
            return Swift.min(Swift.max(3.0915 * Double(f.wallMM) / r, Double(f.lMinMM)), Double(f.lMaxMM))
        }
    }

    /// The span the walls are coloured over — the pass's own (ρ over the lattice mask).
    public static func latticeSpan(_ f: FlexibleLatticeInputs) -> ClosedRange<Double> {
        var lo = Float.infinity, hi = -Float.infinity
        let m = f.mask
        let same = m.nx == f.rho.nx && m.ny == f.rho.ny && m.nz == f.rho.nz
        for n in 0..<m.values.count where m.values[n] >= 0.5 {
            let r = same ? f.rho.values[n] : f.rho.sample(m.c0 + SIMD3<Float>(Float(n % m.nx), Float((n / m.nx) % m.ny), Float(n / (m.nx * m.ny))) * m.spacing)
            lo = Swift.min(lo, r); hi = Swift.max(hi, r)
        }
        return lo.isFinite ? Double(lo)...Double(Swift.max(hi, lo)) : 0...1
    }

    /// The walls' ramp (FlexibleLatticePass): pale → the Flexible accent (DS accentGreen), by
    /// density, with the shader's 0.25 floor. Never purple.
    public static func latticeColour(fraction f: Double) -> RGBA {
        let pale = LatticeStructureColour.pale, dense = FlexibleLatticePass.denseWall
        let t = 0.25 + 0.75 * Swift.min(Swift.max(f.isFinite ? f : 0, 0), 1)
        return RGBA((pale.r + (dense.r - pale.r) * t) * 255, (pale.g + (dense.g - pale.g) * t) * 255,
                    (pale.b + (dense.b - pale.b) * t) * 255)
    }
}

/// ★ ONE TINT ARRAY (decisions: "one owner per surface"). MetalMeshView's `stressTints` and
/// `vertexTints` write the SAME buffer and never blend (the stress buffer is sized to the part
/// mesh and dropped for the overlay mesh), so the main Flexible page composes everything into
/// the 8-wide vertexTints: Heat owns the pressed faces' map quads (opaque), Stress owns the
/// rest of the part (and the map when Heat is off — opaque too), the Flexible face tints then
/// the main page's group colours fill what is left, and X-ray ghosts every vertex that is not
/// opaque. (★ Batch C verification: the stage never asks for Heat AND Stress — they are the two
/// colourings of the map, one at a time; `heat: true` with a stress field stays defined here.)
public enum FlexibleMainTints {
    public static func compose(base: [Float]?, overlay: FlexibleOverlayMesh?, part: ViewerMesh?, heat: Bool,
                               roles: [FaceID: SIMD4<Float>], stress: (field: LatticeDemandField, peak: Double)?,
                               ghost: SIMD4<Float>?) -> [Float]? {
        guard let mesh = overlay?.mesh ?? part else { return nil }
        let n = mesh.flat.vertexCount
        guard n > 0 else { return nil }
        var out = base.flatMap { $0.count == n * 8 ? $0 : nil } ?? [Float](repeating: 0, count: n * 8)
        let partVerts = min(overlay?.partFlatVertices ?? n, n)
        let pos = mesh.flat.positions
        let ids = mesh.faceIDs
        func face(_ t: Int) -> Int {
            if let o = overlay { return t < o.keptFace.count ? o.keptFace[t] : -1 }
            return t < ids.count ? Int(ids[t]) : -1
        }
        func put(_ v: Int, _ c: SIMD4<Float>) {
            out[v * 8] = c.x; out[v * 8 + 1] = c.y; out[v * 8 + 2] = c.z; out[v * 8 + 3] = c.w
        }
        func stressColour(_ v: Int) -> SIMD4<Float>? {
            guard let s = stress, s.peak > 0 else { return nil }
            let p = SIMD3<Float>(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2])
            return LatticeStressTint.colour(fraction: (FlexibleProbe.stress(s.field, at: p) ?? 0) / s.peak)
        }
        for v in 0..<partVerts {
            if let c = stressColour(v) { put(v, c); continue }
            if out[v * 8 + 3] <= 0, let r = roles[FaceID(truncatingIfNeeded: face(v / 3))] { put(v, r) }
        }
        if !heat, stress != nil {
            for v in partVerts..<n {
                guard let c = stressColour(v) else { continue }
                put(v, c)
                // ★ BATCH C VERIFICATION: held OPAQUE, like the heat it replaces — the map reads
                // the same (and hides the same) whichever colouring it carries
                out[v * 8 + 5] = 1
            }
        }
        if let g = ghost { FlexibleOverlayMesh.markGhost(&out, colour: g) }
        return out
    }
}

/// When the main Flexible page starts the solid part's FEA itself (item T). ★ NOT through
/// `startStressSolveIfNeeded`: that is gated on `lattice.enabled && needsStressSolve`, which a
/// fresh Flexible part never passes (and LatticeSimSolveTriggerTests reads its first 900
/// characters, so it is not edited).
public enum FlexibleStressTrigger {
    public static func shouldRun(hasField: Bool, stale: Bool, running: Bool) -> Bool {
        !running && (!hasField || stale)
    }
    /// The octet's own gate — kept here as the tests' red control.
    public static func octetGate(_ s: LatticeSettings) -> Bool { s.enabled && s.needsStressSolve }
}
