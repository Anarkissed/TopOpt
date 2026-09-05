import Foundation
import simd

/// ★ SYNTHETIC STRESSES FOR UNLOADED WALLS (maintainer, 2026-09-05; Aesthetic only).
///
/// A wall the load never reaches has NO field to trace: its principal directions
/// are rounding noise and the tracer faithfully follows garbage (measured on the
/// M2 stand's back wall: median von Mises 0.000422 MPa, 1.8 % of the peak). The
/// substitute is a synthetic LOAD, not a swirl: rank-one contributions
/// `w / (r² + s²) · (r̂ ⊗ r̂)` from a few focal points, alternating pull/push,
/// summed as a TENSOR so opposing foci form a saddle between them — the saddle
/// IS the sweeping curve. Blended by stress magnitude with a smoothstep, so a
/// wall that carries real load keeps it and a dead one goes fully synthetic.
///
/// PREVIEW-SIDE on this core. The job carries `organic_synthetic_stresses`,
/// `organic_synthetic_foci` and a per-region `synthetic_foci` only when core's
/// grading schema accepts the keys (this build's does not — reported to the core
/// agent); until then the run traces the real field. Offer, never substitute.
public enum OrganicSyntheticStress {

    /// One wall's verdict: how much real stress it carries, whether that counts
    /// as dead, and what was injected.
    public struct WallReport: Equatable, Sendable {
        public let key: String?
        public let faceID: Int?
        public let voxels: Int
        public let medianVM: Double
        public let peakVM: Double
        public let dead: Bool
        public let foci: Int
        public let injected: Int
        public var medianFraction: Double { peakVM > 0 ? medianVM / peakVM : 0 }
        public var statusText: String {
            if voxels == 0 { return "no voxels" }
            return dead
                ? String(format: "unloaded · %.1f%% of peak", 100 * medianFraction)
                : String(format: "loaded · %.0f%% of peak", 100 * medianFraction)
        }
    }

    public struct Result: Sendable {
        public let tensor: [Double]
        public let walls: [WallReport]
        public var injectedVoxels: Int { walls.reduce(0) { $0 + $1.injected } }
        public var deadWalls: Int { walls.filter(\.dead).count }
    }

    /// Below this fraction of the field's peak a wall's median von Mises is noise
    /// (2 % on the 2026-09-03 census; 5 % here because his M2 back wall measured
    /// 3 % of the stage solve's peak and is the wall he calls unloaded).
    public static let deadFraction = 0.05
    public static let fociRange = 1...5

    public static func clampFoci(_ n: Int) -> Int {
        Swift.min(Swift.max(n, fociRange.lowerBound), fociRange.upperBound)
    }

    /// Von Mises from a Voigt tensor [xx, yy, zz, xy, yz, zx] (true shear).
    @inline(__always)
    static func vonMises(_ t: [Double], _ b: Int) -> Double {
        let xx = t[b], yy = t[b + 1], zz = t[b + 2]
        let xy = t[b + 3], yz = t[b + 4], zx = t[b + 5]
        let d = 0.5 * ((xx - yy) * (xx - yy) + (yy - zz) * (yy - zz) + (zz - xx) * (zz - xx))
        return (d + 3 * (xy * xy + yz * yz + zx * zx)).squareRoot()
    }

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        guard e1 > e0 else { return x >= e1 ? 1 : 0 }
        let t = Swift.min(Swift.max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Inject synthetic tensors into `tensor` (Voigt, 6 per voxel, grid-ordered
    /// x fastest) inside every INCLUDE region whose median von Mises is below
    /// `deadFraction` of the field's peak. A LOADED wall is never injected, whatever
    /// count it states (his rule, 2026-09-05: "it should never be able to add foci
    /// to loaded walls"). Voxel centres are `originMM + (index + 0.5) · spacing`.
    public static func inject(tensor: [Double], dims: (Int, Int, Int),
                              originMM: SIMD3<Double>, spacingMM: Double,
                              regions: [LatticeRegionSpec], defaultFoci: Int) -> Result {
        let (nx, ny, nz) = dims
        let n = nx * ny * nz
        guard n > 0, tensor.count == 6 * n, spacingMM > 0 else {
            return Result(tensor: tensor, walls: [])
        }
        var vm = [Double](repeating: 0, count: n)
        var peak = 0.0
        for i in 0..<n {
            let v = vonMises(tensor, 6 * i)
            vm[i] = v
            if v > peak { peak = v }
        }
        var out = tensor
        var walls: [WallReport] = []
        let target = peak > 0 ? 0.5 * peak : 1.0

        for region in regions where region.role == .include && region.isValid {
            // ── membership ──
            var members: [Int] = []
            members.reserveCapacity(4096)
            var centres: [SIMD3<Double>] = []
            centres.reserveCapacity(4096)
            for k in 0..<nz {
                for j in 0..<ny {
                    for i in 0..<nx {
                        let p = originMM + (SIMD3<Double>(Double(i), Double(j), Double(k)) + 0.5) * spacingMM
                        if LatticeRegionMask.contains(p, region: region) {
                            members.append((k * ny + j) * nx + i)
                            centres.append(p)
                        }
                    }
                }
            }
            let foci = clampFoci(region.syntheticFoci ?? defaultFoci)
            guard !members.isEmpty else {
                walls.append(WallReport(key: region.selectableKey, faceID: region.faceID, voxels: 0,
                                        medianVM: 0, peakVM: peak, dead: false, foci: foci, injected: 0))
                continue
            }
            let sorted = members.map { vm[$0] }.sorted()
            let median = sorted[sorted.count / 2]
            let dead = peak <= 0 || median < deadFraction * peak
            guard dead else {
                walls.append(WallReport(key: region.selectableKey, faceID: region.faceID,
                                        voxels: members.count, medianVM: median, peakVM: peak,
                                        dead: false, foci: foci, injected: 0))
                continue
            }

            // ── foci on the 80 % ellipse of the wall's two in-plane extents, at
            // mid-depth (core's recipe, brief 2026-09-05); one focus = the centre ──
            let axis: SIMD3<Double>
            switch region.kind {
            case .face: axis = simd_normalize(region.normal)
            case .bolt: axis = simd_normalize(region.axisDir)
            }
            let (u, v) = LatticeRegionMask.basis(axis)
            var uMin = Double.infinity, uMax = -Double.infinity
            var vMin = Double.infinity, vMax = -Double.infinity
            var sSum = 0.0
            var uSum = 0.0, vSum = 0.0
            for p in centres {
                let cu = simd_dot(p, u), cv = simd_dot(p, v)
                uMin = Swift.min(uMin, cu); uMax = Swift.max(uMax, cu)
                vMin = Swift.min(vMin, cv); vMax = Swift.max(vMax, cv)
                sSum += simd_dot(p, axis); uSum += cu; vSum += cv
            }
            let count = Double(centres.count)
            let sMid = sSum / count
            let uExt = uMax - uMin, vExt = vMax - vMin
            let longExt = Swift.max(uExt, vExt)
            let uMid = uSum / count, vMid = vSum / count
            var focalPoints: [SIMD3<Double>] = []
            for f in 0..<foci {
                let theta = foci == 1 ? 0 : 2 * Double.pi * Double(f) / Double(foci)
                let cu = foci == 1 ? uMid : uMid + 0.4 * uExt * cos(theta)
                let cv = foci == 1 ? vMid : vMid + 0.4 * vExt * sin(theta)
                focalPoints.append(u * cu + v * cv + axis * sMid)
            }
            // Softening: a quarter of the largest extent (core's default), never
            // under one voxel.
            let soft = Swift.max(spacingMM, 0.25 * longExt)
            let soft2 = soft * soft

            // ── the tensor sum, then one scale for the wall ──
            var synth = [Double](repeating: 0, count: 6 * members.count)
            var maxNorm = 0.0
            for (m, p) in centres.enumerated() {
                var xx = 0.0, yy = 0.0, zz = 0.0, xy = 0.0, yz = 0.0, zx = 0.0
                for (f, fp) in focalPoints.enumerated() {
                    let r = p - fp
                    let r2 = simd_length_squared(r)
                    guard r2 > 1e-12 else { continue }
                    let w = (f % 2 == 0 ? 1.0 : -1.0) / (r2 + soft2)
                    let rh = r / r2.squareRoot()
                    xx += w * rh.x * rh.x; yy += w * rh.y * rh.y; zz += w * rh.z * rh.z
                    xy += w * rh.x * rh.y; yz += w * rh.y * rh.z; zx += w * rh.z * rh.x
                }
                let b = 6 * m
                synth[b] = xx; synth[b + 1] = yy; synth[b + 2] = zz
                synth[b + 3] = xy; synth[b + 4] = yz; synth[b + 5] = zx
                let norm = (xx * xx + yy * yy + zz * zz + 2 * (xy * xy + yz * yz + zx * zx)).squareRoot()
                if norm > maxNorm { maxNorm = norm }
            }
            let scale = maxNorm > 0 ? target / maxNorm : 0
            var injected = 0
            for (m, idx) in members.enumerated() {
                let frac = peak > 0 ? vm[idx] / peak : 0
                // The synthetic field fades out wherever real stress appears.
                let w = 1 - smoothstep(deadFraction, 3 * deadFraction, frac)
                guard w > 0 else { continue }
                let b = 6 * idx, sb = 6 * m
                for c in 0..<6 {
                    out[b + c] = (1 - w) * tensor[b + c] + w * scale * synth[sb + c]
                }
                if w > 0.5 { injected += 1 }
            }
            walls.append(WallReport(key: region.selectableKey, faceID: region.faceID,
                                    voxels: members.count, medianVM: median, peakVM: peak,
                                    dead: true, foci: foci, injected: injected))
        }
        return Result(tensor: out, walls: walls)
    }
}
