// LatticeDensityProxy.swift — the honest stand-in for a lattice the device cannot
// render (handoff 2026-07-28-lattice-viewer-proxy). A latticed variant is
// ~316k triangles at an 8 mm octet cell and grows as (1/cell)³ — the whole part at
// a printable cell is ~2.8 GB of GPU buffers, over the iOS per-app ceiling BEFORE a
// frame is drawn (PR-184 / handoff 2026-07-26-lattice-phase0). So the device never
// holds the lattice mesh. Instead it shades the part surface it ALREADY draws by the
// lattice's local RELATIVE DENSITY, so the user reads WHERE the lattice is dense and
// WHERE it is sparse without any lattice geometry existing on the device.
//
// WHY DENSITY-ON-THE-SURFACE (the justification the task asks for):
//   • The two things a user must read are WHERE the lattice is and HOW DENSE it is
//     there. A graded lattice IS a scalar relative-density field ρ(x) over the part
//     interior; painting that field on the surface conveys exactly those two things.
//   • It reuses the viewer's existing per-vertex colour channel (`setStressTints`),
//     so shading costs ZERO extra triangles and ZERO new GPU buffers — the marginal
//     cost over the part already shown is nil. Nothing else clears the memory bar.
//   • It needs no lattice mesh, so it works when the real (worker-generated) mesh is
//     not on the device at all (requirement 4) — the density field is derived
//     locally from the design.
//   • Its inputs are local (lattice type, cell size, density bounds + the on-device
//     demand field), so it re-shades instantly when the user changes a lattice
//     parameter, with no round trip to the worker (requirement V3).
// A small TRUE-geometry sample patch (LatticeSamplePatch) rides alongside as the
// "this is what the cells look like" reference, so the density colours are anchored
// to real geometry — but it is a handful of cells, not the part.
//
// HONESTY (requirement 1): this file computes colours and a legend fraction only. It
// is the caller's contract to label the view as a PROXY (LatticeProxyLegend does).
// The colours deliberately use a distinct INDIGO "amount of material" ramp — not the
// stress heatmap's blue→red rainbow — so a lattice preview is never mistaken for a
// stress result or for the exported geometry.
//
// Pure value-type math on plain arrays: unit-tested headlessly (the /app/ standard),
// no GPU, no core, no solver — none of which this touches.

import Foundation
import simd
import TopOptDesign

/// The lattice-grading parameters a user sets locally. Changing any of these
/// re-shades the proxy on device with no worker round trip (V3).
public struct LatticeProxyParams: Equatable, Sendable, Codable {
    /// Which lattice (sets K → the density↔radius map, and the sample-patch cell).
    public var latticeID: String
    /// Cell size (mm) — the sample patch and the "cells across the member" readout;
    /// does NOT change the surface shading (ρ is dimensionless relative density).
    public var cellMM: Double
    /// Relative density where demand is lowest (the sparsest the lattice grades to).
    public var minRelativeDensity: Double
    /// Relative density where demand is highest (the densest it grades to).
    public var maxRelativeDensity: Double
    /// Demand→density curve exponent: ρ = ρmin + (ρmax−ρmin)·demandᵞ. 1 = linear.
    public var gamma: Double
    /// The relative density used everywhere when there is NO demand field (an
    /// ungraded / uniform-infill preview). Keeps the proxy honest when no result
    /// exists on device yet (V4).
    public var uniformRelativeDensity: Double

    public init(latticeID: String = LatticeType.octet.id, cellMM: Double = 8,
                minRelativeDensity: Double = 0.08, maxRelativeDensity: Double = 0.55,
                gamma: Double = 1, uniformRelativeDensity: Double = 0.2) {
        self.latticeID = latticeID
        self.cellMM = cellMM
        self.minRelativeDensity = minRelativeDensity
        self.maxRelativeDensity = maxRelativeDensity
        self.gamma = gamma
        self.uniformRelativeDensity = uniformRelativeDensity
    }

    /// The resolved lattice (never nil — unknown ids fall back to octet).
    public var lattice: LatticeType { LatticeType.named(latticeID) }

    /// ρmax clamped to be ≥ ρmin, so the legend range is always non-degenerate.
    public var densitySpan: (lo: Double, hi: Double) {
        let lo = max(0, min(1, minRelativeDensity))
        let hi = max(lo, min(1, maxRelativeDensity))
        return (lo, hi)
    }
}

public enum LatticeDensityProxy {

    // MARK: grading — demand field → relative density → colour

    /// Map a normalized demand fraction (0…1, e.g. von Mises / its peak) to a
    /// relative density through the grading curve. Clamped so a caller can pass a
    /// raw ratio.
    public static func relativeDensity(demandFraction d: Double, params: LatticeProxyParams) -> Double {
        let (lo, hi) = params.densitySpan
        let g = max(0.05, params.gamma)
        let shaped = pow(max(0, min(1, d)), g)
        return lo + (hi - lo) * shaped
    }

    /// The legend fraction (0…1) a relative density maps to on the colour ramp:
    /// (ρ − ρmin)/(ρmax − ρmin). So the ramp's ends are exactly ρmin and ρmax and a
    /// user can read a colour back to a density.
    public static func legendFraction(relativeDensity rho: Double, params: LatticeProxyParams) -> Double {
        let (lo, hi) = params.densitySpan
        guard hi > lo else { return 0 }
        return max(0, min(1, (rho - lo) / (hi - lo)))
    }

    /// Per-flat-vertex colours for the viewer's `setStressTints` channel — the SAME
    /// layout the stress overlay uses (one RGBA per `mesh.flat` vertex, soup order,
    /// alpha 1), so the density proxy slots into the existing pipeline with no new
    /// GPU buffer. `demand` is the on-device von Mises field (graded shading); pass
    /// nil for a uniform (ungraded) preview, which paints every vertex the single
    /// colour of `uniformRelativeDensity` — still honest, just flat.
    ///
    /// `selectionTints` (round-2 L5): per-face SELECTION colours that must draw
    /// ABOVE the density overlay. The stress-tint channel REPLACES face highlights
    /// in the renderer, so before this parameter the purple proxy painted straight
    /// over the TO page's selection groups; now every vertex of a selected face
    /// keeps its group colour, whatever the density beneath.
    /// `effectiveFaceIDs` (optional): the per-triangle face ids the highlight
    /// pass uses — pass the paint-overridden ids so painted pseudo-faces keep
    /// their selection colour too; nil → the mesh's native ids.
    public static func tints(for mesh: ViewerMesh, demand: StressField?,
                             params: LatticeProxyParams,
                             selectionTints: [FaceID: SIMD4<Float>] = [:],
                             effectiveFaceIDs: [Int32]? = nil) -> [SIMD4<Float>] {
        let positions = mesh.flat.positions
        let count = mesh.flat.vertexCount
        var out: [SIMD4<Float>]

        // Uniform preview: no field, or an empty/flat field → one colour everywhere.
        let peak = demand?.peak()?.valueMPa ?? 0
        if let field = demand, !field.isEmpty, peak > 0 {
            out = []
            out.reserveCapacity(count)
            let inv = 1.0 / Double(peak)
            for v in 0..<count {
                let p = SIMD3<Float>(positions[v * 3], positions[v * 3 + 1], positions[v * 3 + 2])
                let d = Double(field.value(at: p)) * inv       // demand fraction 0…1
                let rho = relativeDensity(demandFraction: d, params: params)
                let c = densityColor(fraction: legendFraction(relativeDensity: rho, params: params))
                out.append(SIMD4<Float>(Float(c.r), Float(c.g), Float(c.b), 1))
            }
        } else {
            let frac = legendFraction(relativeDensity: params.uniformRelativeDensity, params: params)
            let c = densityColor(fraction: frac)
            let rgba = SIMD4<Float>(Float(c.r), Float(c.g), Float(c.b), 1)
            out = [SIMD4<Float>](repeating: rgba, count: count)
        }

        // Selections draw ABOVE the overlay (L5): the flat soup is unshared, so
        // vertex v belongs to triangle v/3, whose face id keys the override.
        let ids = effectiveFaceIDs ?? mesh.faceIDs
        if !selectionTints.isEmpty, !ids.isEmpty {
            for v in 0..<count {
                let tri = v / 3
                guard tri < ids.count, let c = selectionTints[ids[tri]] else { continue }
                out[v] = c
            }
        }
        return out
    }

    /// The density colour ramp: a single-hue INDIGO "amount of material" scale from
    /// a pale sparse end to a deep saturated dense end. Deliberately NOT the stress
    /// heatmap's blue→cyan→green→yellow→red rainbow, so a lattice-density preview is
    /// never read as a stress field. Sparse (0) = pale cool grey; dense (1) = deep
    /// indigo. Monotonic in luminance so it also reads correctly in greyscale.
    public static func densityColor(fraction: Double) -> RGBA {
        // pale → mid violet → deep indigo (0–255 components).
        let stops: [(Double, Double, Double)] = [
            (233, 236, 245),   // 0.00  near-white cool grey (very sparse)
            (183, 189, 230),   // 0.25
            (124, 111, 214),   // 0.50  violet
            (74, 52, 158),     // 0.75
            (32, 20, 92),      // 1.00  deep indigo (dense)
        ]
        let x = min(1, max(0, fraction)) * Double(stops.count - 1)
        let i = min(stops.count - 2, Int(x))
        let t = x - Double(i)
        let a = stops[i], b = stops[i + 1]
        return RGBA(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    // MARK: cost model — proxy vs. the real lattice mesh (requirement 3 / bar V1)

    /// The GPU buffer bytes a triangle-soup mesh of `tris` triangles costs in the
    /// viewer, using the SAME per-triangle model PR-184 measured the 2.8 GB figure
    /// with: the results pipeline uploads an unshared soup with position+normal
    /// (6 floats), stress tint (4) and flex displacement (3) per vertex = 13 floats
    /// × 3 vertices × 4 bytes = 156 bytes/triangle (handoff 134's viewer profile:
    /// 36 628 tris → 5 580 KB → 156.0 B/tri exactly). Kept identical so proxy and
    /// real are compared on one ruler.
    public static let gpuBytesPerTriangle = 156

    /// GPU bytes for a mesh of `tris` triangles at the pipeline's 156 B/tri.
    public static func gpuBytes(triangles tris: Int) -> Int { tris * gpuBytesPerTriangle }

    /// A committed measured reference point for a lattice's triangle cost: the
    /// worker's streaming generator over PR-201's 7³ ≈ 200 cm³ reference region at an
    /// 8 mm cell (`evidence/2026-07-27-strut-lattice-family/reference_region.csv`).
    /// The real lattice fills a solid VOLUME, so triangles scale with the cell
    /// count = volume / cell³; this anchors that scaling to a real measurement rather
    /// than a from-scratch derivation, so at (8 mm, 200 cm³) it reproduces the
    /// committed number exactly.
    public struct RealReference: Equatable, Sendable {
        public let latticeID: String
        public let referenceTriangles: Int   // committed 8 mm / 200 cm³ tris
        public let referenceCellMM: Double   // 8
        public let referenceVolumeMM3: Double // 7³ cells × 8³ = 200704 mm³
    }

    /// The committed reference triangle counts (reference_region.csv, streaming rows,
    /// 8 mm over 7³ cells). Region volume = (7·8)³ = 175616 mm³ of lattice bounding
    /// box; PR-201 calls it "7³ ≈ 200 cm³". We use the exact box volume so the
    /// per-cell count is exact.
    public static let realReferences: [String: RealReference] = {
        let vol = pow(7.0 * 8.0, 3)   // 175616 mm³
        let tris: [(String, Int)] = [
            ("sc", 53248), ("bcc", 104908), ("bccz", 119244), ("fcc", 184288),
            ("fccz", 198624), ("diamond", 236816), ("octet", 316000),
        ]
        var out: [String: RealReference] = [:]
        for (id, t) in tris {
            out[id] = RealReference(latticeID: id, referenceTriangles: t,
                                    referenceCellMM: 8, referenceVolumeMM3: vol)
        }
        return out
    }()

    /// Projected triangle count of the REAL lattice mesh for `lattice`, filling a
    /// solid region of `volumeMM3` at cell size `cellMM`. Scales the committed 8 mm
    /// reference by (volume / ref volume) · (refCell / cell)³ — cells grow as the
    /// volume and as (1/cell)³. Exact at (8 mm, ref volume); leading-order elsewhere
    /// (the finite-block boundary correction is a few percent and shrinks with more
    /// cells — stated in the handoff, not hidden).
    public static func realTriangles(latticeID: String, cellMM: Double, volumeMM3: Double) -> Int {
        guard let ref = realReferences[latticeID] ?? realReferences["octet"], cellMM > 0 else { return 0 }
        let cellRatioCubed = pow(ref.referenceCellMM / cellMM, 3)
        let volumeRatio = volumeMM3 / ref.referenceVolumeMM3
        return Int((Double(ref.referenceTriangles) * volumeRatio * cellRatioCubed).rounded())
    }

    /// The comparison the bar asks for: real-lattice vs proxy triangles and GPU bytes
    /// for a part of `volumeMM3` at `cellMM`, given the proxy's fixed sample-patch
    /// triangle count (from LatticeSamplePatch — cell-size-independent). The proxy's
    /// SHADING adds zero triangles (it recolours the part already drawn), so the
    /// proxy's whole triangle cost is the sample patch.
    public struct CostComparison: Equatable, Sendable {
        public let cellMM: Double
        public let realTriangles: Int
        public let realGPUBytes: Int
        public let proxyTriangles: Int       // sample patch only (shading adds 0)
        public let proxyGPUBytes: Int
        public var triangleRatio: Double { proxyTriangles > 0 ? Double(realTriangles) / Double(proxyTriangles) : .infinity }
        public var gpuRatio: Double { proxyGPUBytes > 0 ? Double(realGPUBytes) / Double(proxyGPUBytes) : .infinity }
    }

    public static func cost(latticeID: String, cellMM: Double, volumeMM3: Double,
                            proxyPatchTriangles: Int) -> CostComparison {
        let rt = realTriangles(latticeID: latticeID, cellMM: cellMM, volumeMM3: volumeMM3)
        return CostComparison(
            cellMM: cellMM,
            realTriangles: rt, realGPUBytes: gpuBytes(triangles: rt),
            proxyTriangles: proxyPatchTriangles, proxyGPUBytes: gpuBytes(triangles: proxyPatchTriangles))
    }

    // MARK: member-scale readout (the printability signal, local & instant)

    /// How many cells span a member of thickness `memberMM` at the current cell size
    /// — the scale-separation number from the lattice studies (handoff
    /// 2026-07-26-lattice-phase0: ~2–3 cells/member is the floor for the knockdown to
    /// hold). Recomputes instantly on a cell-size change (V3); no mesh needed.
    public static func cellsAcrossMember(memberMM: Double, cellMM: Double) -> Double {
        cellMM > 0 ? memberMM / cellMM : 0
    }
}
