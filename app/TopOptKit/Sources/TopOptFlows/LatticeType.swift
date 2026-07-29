// LatticeType.swift — the strut-lattice family, on device, as pure value-type
// data. This is the Swift mirror of the worker-side segment-table generator
// (`evidence/2026-07-27-strut-lattice-family/strut_lattice_gen.cpp`, handoff
// 2026-07-27-strut-lattice-family): the SAME canonical-cell ownership rule and the
// SAME per-cell segment lists, so a cell the app previews is the cell the worker
// would generate. Nothing here meshes or generates a full block — that stays
// worker-side (the whole point of the viewer proxy). This file exists so the app
// can, for ONE small sample patch and for the density→radius grading, reproduce the
// worker's geometry faithfully and headlessly (no GPU, no core, the /app/ standard).
//
// FAITHFULNESS is pinned two ways, both in LatticeTypeTests:
//   • the canonical strut count per cell matches the committed reference table
//     (`reference_region.csv`: sc 3, bcc 8, bccz 9, fcc 12, fccz 13, octet 24,
//     diamond 16 struts/cell);
//   • the total canonical strut length per cell matches `density.txt` to 4 digits
//     (sc 3.0000·L, bcc 6.9282·L, octet 16.9706·L, …), which is what fixes the K in
//     ρ ≈ K·(r/L)² — the grading law the proxy shades by.
//
// SCOPE: seven strut lattices spanning the family's stiffness/density range
// (K = 8.49 sc … 48.0 octet). The worker's three Voronoi/auxetic cells (kelvin,
// rhombic, reentrant) are intentionally NOT ported — they need polyhedron-edge and
// waist-node builders the sample patch does not require to be representative, and
// the table is trivially extensible if a later task wants them on device.

import Foundation
import simd

/// One strut lattice, defined exactly as the worker defines it: an integer
/// denominator `S` (node coordinates are integers in units of `L/S`, so the cell is
/// exact) plus the canonical per-cell strut list — every strut of the infinite
/// tiling whose midpoint lies in the half-open cell box `[0,S)³`, i.e. exactly one
/// copy per cell. `K` is the relative-density coefficient in ρ ≈ K·(r/L)² (the
/// low-density n-gon-strut limit measured in `density.txt`), which inverts to the
/// grading map r(ρ) = L·√(ρ/K).
public struct LatticeType: Equatable, Sendable, Identifiable, Hashable {

    /// An integer strut endpoint, in units of `L/S`.
    public struct Node: Equatable, Sendable, Hashable {
        public var x: Int, y: Int, z: Int
        public init(_ x: Int, _ y: Int, _ z: Int) { self.x = x; self.y = y; self.z = z }
    }
    /// A canonical strut (unordered endpoint pair, in `L/S` units).
    public struct Strut: Equatable, Sendable, Hashable {
        public var a: Node, b: Node
        public init(_ a: Node, _ b: Node) { self.a = a; self.b = b }
    }

    public let id: String            // stable name ("octet", "bcc", …)
    public let displayName: String
    public let blurb: String
    public let denominator: Int      // S
    public let struts: [Strut]       // canonical, one copy per cell
    public let nodes: [Node]         // canonical cell nodes (for the node blobs)
    public let densityCoefficient: Double  // K in ρ ≈ K·(r/L)²

    // MARK: relative-density ↔ strut-radius grading (the map the proxy shades by)

    /// The strut radius (mm) that gives relative density `rho` at cell size `cellMM`,
    /// inverting ρ ≈ K·(r/L)²: r = L·√(ρ/K). This is the exact worker grading law in
    /// the low-density limit (density.txt: mesh matches analytic to ≤1.5e-15). `rho`
    /// is clamped to [0, 1]; K > 0 for every table entry.
    public func strutRadiusMM(relativeDensity rho: Double, cellMM: Double) -> Double {
        let r = max(0, min(1, rho))
        return cellMM * (r / densityCoefficient).squareRoot()
    }

    /// The relative density a given strut radius produces at this cell size — the
    /// forward map ρ = K·(r/L)², for reporting a patch's true density back.
    public func relativeDensity(strutRadiusMM radius: Double, cellMM: Double) -> Double {
        guard cellMM > 0 else { return 0 }
        let rl = radius / cellMM
        return densityCoefficient * rl * rl
    }

    /// Total canonical strut length per cell, in mm, at cell size `cellMM`. Equals
    /// `(Σ |b−a| in L/S units)/S · cellMM`; the density.txt faithfulness test checks
    /// the dimensionless multiple `total/cellMM` against the committed constants.
    public func canonicalStrutLengthMM(cellMM: Double) -> Double {
        let unit = cellMM / Double(denominator)
        var total = 0.0
        for s in struts {
            let dx = Double(s.a.x - s.b.x), dy = Double(s.a.y - s.b.y), dz = Double(s.a.z - s.b.z)
            total += (dx * dx + dy * dy + dz * dz).squareRoot()
        }
        return total * unit
    }
}

public extension LatticeType {

    /// The seven ported lattices, densest last. `octet` is the maintainer's default
    /// (the print-tested cell, PR-201).
    static let family: [LatticeType] = [sc, bcc, bccz, fcc, fccz, diamond, octet]

    /// Look up a lattice by its stable id; falls back to `octet`.
    static func named(_ id: String) -> LatticeType {
        family.first { $0.id == id } ?? octet
    }

    static let sc = build("sc", "Simple cubic", 8.4853,
        "3 orthogonal edges/cell — 2 horizontal bridges, 1 vertical column",
        S: 2, basis: [Node(0, 0, 0)]) { a, b, S in d2(a, b) == S * S }

    static let bcc = build("bcc", "Body-centred cubic", 19.5959,
        "8 body diagonals, all at 54.7° — pure truss, no bridges, no columns",
        S: 2, basis: bccBasis(2)) { a, b, _ in d2(a, b) == 3 }

    static let bccz = build("bccz", "BCC + Z", 22.4243,
        "BCC plus the vertical columns it lacks",
        S: 2, basis: bccBasis(2)) { a, b, S in d2(a, b) == 3 || verticalEdge(a, b, S) }

    static let fcc = build("fcc", "Face-centred cubic", 24.0000,
        "corner↔face-centre legs only",
        S: 2, basis: fccBasis(2)) { a, b, S in d2(a, b) == 2 && (isCorner(a, S) != isCorner(b, S)) }

    static let fccz = build("fccz", "FCC + Z", 26.8284,
        "FCC legs plus vertical columns",
        S: 2, basis: fccBasis(2)) { a, b, S in
            (d2(a, b) == 2 && (isCorner(a, S) != isCorner(b, S))) || verticalEdge(a, b, S) }

    static let diamond = build("diamond", "Diamond", 19.5959,
        "4-valent open network, every strut at 54.7°",
        S: 4, basis: diamondBasis(4)) { a, b, _ in d2(a, b) == 3 }

    static let octet = build("octet", "Octet truss", 48.0000,
        "all 12 FCC nearest-neighbour bonds — legs + octahedral braces (print-tested)",
        S: 2, basis: fccBasis(2)) { a, b, _ in d2(a, b) == 2 }

    // MARK: canonical-cell construction (the worker's algorithm, ported exactly)

    /// Build a lattice by folding the nearest-neighbour bonds of a node basis into
    /// one canonical cell — the worker's `canonical_from_pairs`: lay the basis over
    /// a 3×3×3 super-block of cells, form every bonded pair, and keep the ones whose
    /// MIDPOINT lies in `[0,S)³` (deduped). Deterministic traversal → identical
    /// output every call (the S2 byte-determinism the worker guarantees).
    private static func build(_ id: String, _ name: String, _ K: Double, _ blurb: String,
                              S: Int, basis: [Node],
                              bond: (Node, Node, Int) -> Bool) -> LatticeType {
        var pts: [Node] = []
        for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
            for n in basis { pts.append(Node(n.x + dx * S, n.y + dy * S, n.z + dz * S)) }
        } } }
        var seen = Set<Strut>()
        var struts: [Strut] = []
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                guard bond(pts[i], pts[j], S) else { continue }
                guard midpointInCell(pts[i], pts[j], S) else { continue }
                let c = canonical(pts[i], pts[j])
                if seen.insert(c).inserted { struts.append(c) }
            }
        }
        struts.sort(by: strutOrder)   // stable order, basis-independent
        let nodes = basis.filter { $0.x >= 0 && $0.x < S && $0.y >= 0 && $0.y < S && $0.z >= 0 && $0.z < S }
        return LatticeType(id: id, displayName: name, blurb: blurb, denominator: S,
                           struts: struts, nodes: nodes, densityCoefficient: K)
    }

    // integer geometry helpers (mirror the C++ harness)
    private static func d2(_ a: Node, _ b: Node) -> Int {
        let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
        return dx * dx + dy * dy + dz * dz
    }
    private static func isCorner(_ p: Node, _ S: Int) -> Bool {
        p.x % S == 0 && p.y % S == 0 && p.z % S == 0
    }
    private static func verticalEdge(_ a: Node, _ b: Node, _ S: Int) -> Bool {
        isCorner(a, S) && isCorner(b, S) && a.x == b.x && a.y == b.y && abs(a.z - b.z) == S
    }
    /// Midpoint in `[0,S)³` ⇔ each summed coordinate lies in `[0,2S)` (integers).
    private static func midpointInCell(_ a: Node, _ b: Node, _ S: Int) -> Bool {
        func ok(_ p: Int, _ q: Int) -> Bool { let m = p + q; return m >= 0 && m < 2 * S }
        return ok(a.x, b.x) && ok(a.y, b.y) && ok(a.z, b.z)
    }
    private static func canonical(_ a: Node, _ b: Node) -> Strut {
        nodeLess(b, a) ? Strut(b, a) : Strut(a, b)
    }
    private static func nodeLess(_ a: Node, _ b: Node) -> Bool {
        if a.x != b.x { return a.x < b.x }
        if a.y != b.y { return a.y < b.y }
        return a.z < b.z
    }
    private static func strutOrder(_ s: Strut, _ t: Strut) -> Bool {
        if !(s.a == t.a) { return nodeLess(s.a, t.a) }
        return nodeLess(s.b, t.b)
    }

    private static func bccBasis(_ S: Int) -> [Node] { [Node(0, 0, 0), Node(S / 2, S / 2, S / 2)] }
    private static func fccBasis(_ S: Int) -> [Node] {
        let h = S / 2
        return [Node(0, 0, 0), Node(h, h, 0), Node(h, 0, h), Node(0, h, h)]
    }
    private static func diamondBasis(_ S: Int) -> [Node] {
        let q = S / 4, h = S / 2
        return [Node(0, 0, 0), Node(h, h, 0), Node(h, 0, h), Node(0, h, h),
                Node(q, q, q), Node(q, 3 * q, 3 * q), Node(3 * q, q, 3 * q), Node(3 * q, 3 * q, q)]
    }
}
