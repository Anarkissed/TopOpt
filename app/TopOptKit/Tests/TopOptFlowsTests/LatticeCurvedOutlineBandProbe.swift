import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ WHAT IS THE SMOOTH GREY STRIP ALONG THE SIDES OF A LATTICED WALL?
///
/// ★ THE CONFOUND CONTROL, STATED FIRST (handoff §6 — five pixel measurements of
/// this same band came back meaningless). **This probe counts no pixels at all.**
/// It is arithmetic on the mesh and on the baked region field: the part is a
/// channel, so any frame-based count is polluted by the far wall, by the shell's
/// AO, and by the ground plane. None of those exist here. The only inputs are
/// triangles, their own normals, and `scene.regionSDF` — the very texture the
/// shader samples.
///
/// The question the strip poses has exactly three answers and they need three
/// different fixes:
///
///   1. It is a REAL, UNDECLARED CAD FACE (a rim/land between his two big faces).
///      Then it is solid in the run and correct on screen — not a defect.
///   2. It is his DECLARED face, and `shell_is_latticed` says "not latticed" there,
///      so the shell draws over lattice that is really present.
///   3. It is his declared face, the shell IS cut, and the march draws nothing.
///
/// `whatIsUnderTheBand` separates all three by replaying the shader's own rule on
/// the CPU, per triangle, against the same field.
final class LatticeCurvedOutlineBandProbe: XCTestCase {

    typealias P = LatticeQuiltBakeProbe

    // MARK: - the shader's rule, replayed exactly

    /// Trilinear sample of a baked grid — `filter::linear, address::clamp_to_edge`,
    /// which is the sampler `shell_is_latticed` declares.
    static func sampleLinear(_ g: LatticeVoxelGrid, _ p: SIMD3<Double>) -> Double {
        let f = SIMD3<Double>(
            (p.x - Double(g.origin.x)) / Double(g.spacing.x),
            (p.y - Double(g.origin.y)) / Double(g.spacing.y),
            (p.z - Double(g.origin.z)) / Double(g.spacing.z))
        func lerpAxis(_ v: Double, _ n: Int) -> (Int, Int, Double) {
            let c = Swift.min(Swift.max(v, 0), Double(n - 1))
            let i0 = Int(c.rounded(.down)), i1 = Swift.min(i0 + 1, n - 1)
            return (i0, i1, c - Double(i0))
        }
        let (x0, x1, tx) = lerpAxis(f.x, g.nx)
        let (y0, y1, ty) = lerpAxis(f.y, g.ny)
        let (z0, z1, tz) = lerpAxis(f.z, g.nz)
        func at(_ x: Int, _ y: Int, _ z: Int) -> Double {
            Double(g.values[x + g.nx * (y + g.ny * z)])
        }
        func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        let c00 = mix(at(x0, y0, z0), at(x1, y0, z0), tx)
        let c10 = mix(at(x0, y1, z0), at(x1, y1, z0), tx)
        let c01 = mix(at(x0, y0, z1), at(x1, y0, z1), tx)
        let c11 = mix(at(x0, y1, z1), at(x1, y1, z1), tx)
        return mix(mix(c00, c10, ty), mix(c01, c11, ty), tz)
    }

    /// `shell_is_latticed`, FACE branch, line for line — including the eye test, the
    /// two-cap normal gate, the nudge and the linear region sample.
    /// Returns (latticed, whyNot) so a refusal can be attributed.
    static func shellIsLatticed(p: SIMD3<Double>, n: SIMD3<Double>,
                                decls: [SIMD3<Double>], grid: LatticeVoxelGrid,
                                nudge: Double, gateCos: Double,
                                eye: SIMD3<Double>) -> (Bool, String) {
        let sn = simd_normalize(n)
        var worst = "no-decl"
        for inward in decls {
            let toEye = eye - p
            if simd_dot(sn, toEye) <= 0 { worst = "faces-away"; continue }
            var capSign = 0.0
            if simd_dot(sn, -inward) >= gateCos { capSign = 1 }
            else if simd_dot(sn, inward) >= gateCos { capSign = -1 }
            else { worst = "normal-gate"; continue }
            let q = p + inward * (nudge * capSign)
            let f = SIMD3<Double>(
                (q.x - Double(grid.origin.x)) / Double(grid.spacing.x),
                (q.y - Double(grid.origin.y)) / Double(grid.spacing.y),
                (q.z - Double(grid.origin.z)) / Double(grid.spacing.z))
            if f.x < -0.5 || f.y < -0.5 || f.z < -0.5
                || f.x > Double(grid.nx) - 0.5 || f.y > Double(grid.ny) - 0.5
                || f.z > Double(grid.nz) - 0.5 { worst = "off-grid"; continue }
            if sampleLinear(grid, q) <= 0 { return (true, "open") }
            worst = "region-sample"
        }
        return (false, worst)
    }

    // MARK: - 1. WHAT SURFACES ARE THERE, AND WHICH ONE IS THE STRIP

    /// An inventory of every B-rep face that carries area next to his two declared
    /// ones, with its kind, its area, and how its own normal sits against each
    /// declared normal. If the strip is answer (1) it shows up here as a real face
    /// with real area whose normal is ~90 deg off both declarations.
    func testWhatSurfacesSurroundHisTwoDeclaredFaces() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let i = try P.inputs(P.His(), faces: LatticeRefusedCellProbe.hisFaces)
        let declNormals = i.scene.regions.filter { $0.role == .include }
            .map { LatticeRegionMask.unit($0.normal) }
        print("declared inward normals: \(declNormals.map { fmt3($0) })")

        // Per-face area and normal spread, straight off the triangles.
        var area: [Int32: Double] = [:]
        var nsum: [Int32: SIMD3<Double>] = [:]
        var tris: [Int32: Int] = [:]
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            defer { t += 3 }
            guard tri < mesh.faceIDs.count else { continue }
            let fid = mesh.faceIDs[tri]
            let (a, b, c) = corners(mesh, t)
            let cr = simd_cross(b - a, c - a)
            let ar = 0.5 * simd_length(cr)
            guard ar > 1e-12 else { continue }
            area[fid, default: 0] += ar
            nsum[fid, default: .zero] += simd_normalize(cr) * ar
            tris[fid, default: 0] += 1
        }
        // Only faces with meaningful area, sorted big first.
        let ranked = area.sorted { $0.value > $1.value }
        print(" face   area mm2   tris     kind   unit normal              deg off decl")
        for (fid, ar) in ranked.prefix(28) {
            let nn = simd_normalize(nsum[fid] ?? SIMD3(0, 0, 1))
            let kind = mesh.faceGeometry(fid).map { g -> String in
                switch g.kind {
                case .plane: return "plane"
                case .cylinder: return "cyl"
                case .other: return "other"
                }
            } ?? "-"
            let offs = declNormals.map { d -> String in
                let dd = abs(simd_dot(nn, d))
                return String(format: "%.0f", acos(Swift.min(1, dd)) * 180 / .pi)
            }.joined(separator: "/")
            print(String(format: "%5d %10.1f %6d %8@   %-24@ %@",
                         Int(fid), ar, tris[fid] ?? 0, kind as NSString,
                         fmt3(nn) as NSString, offs as NSString))
        }
    }

    // MARK: - 2. WHAT IS UNDER THE BAND — the three answers, separated

    /// For every triangle of the part, replay the shell's rule and ask the region
    /// field the march's own question. Reported PER FACE so the strip can be named.
    ///
    /// ★ THE ATTRIBUTION THAT MATTERS: triangles whose own centre is ANALYTICALLY
    /// inside a declared region (so the run will lattice there) but for which
    /// `shell_is_latticed` is FALSE. That is answer (2) — the shell standing over
    /// real lattice — and it is counted with no reference to a rendered frame.
    func testWhatIsUnderTheBand() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let i = try P.inputs(P.His(), faces: LatticeRefusedCellProbe.hisFaces)
        guard let rg = i.scene.regionSDF else { throw XCTSkip("no region field") }
        let inc = i.scene.regions.filter { $0.role == .include }
        let decls = inc.map { LatticeRegionMask.unit($0.normal) }
        let nudge = Double(max(rg.spacing.x, max(rg.spacing.y, rg.spacing.z)))
        let gate = cos(30.0 * .pi / 180)
        print(String(format: "region grid %dx%dx%d @ %.3f mm   nudge=%.3f mm  gate=cos30",
                     rg.nx, rg.ny, rg.nz, Double(rg.spacing.x), nudge))

        // ★ THE EYE. Its only role in the rule is `dot(sn, toEye) > 0` — front-facing.
        // Evaluating a surface from behind is meaningless, so each triangle is asked
        // from a viewpoint far along its OWN normal: that isolates the normal gate and
        // the region sample, which are the two terms actually in question, and makes
        // the answer camera-independent. (A camera-dependent count is one of the five
        // confounds; this removes the camera from the measurement entirely.)
        struct Row { var tris = 0; var inRegion = 0; var open = 0
                     var why: [String: Int] = [:]; var areaBlind = 0.0 }
        var rows: [Int32: Row] = [:]
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            defer { t += 3 }
            guard tri < mesh.faceIDs.count else { continue }
            let fid = mesh.faceIDs[tri]
            let (a, b, c) = corners(mesh, t)
            let cr = simd_cross(b - a, c - a)
            let ar = 0.5 * simd_length(cr)
            guard ar > 1e-12 else { continue }
            let n = simd_normalize(cr)
            let p = (a + b + c) / 3
            var r = rows[fid] ?? Row()
            r.tris += 1
            // Analytically inside a declared region? That is the run's own answer.
            let inside = inc.contains { LatticeRegionMask.contains(p, region: $0) }
            if inside { r.inRegion += 1 }
            let (ok, why) = Self.shellIsLatticed(
                p: p, n: n, decls: decls, grid: rg, nudge: nudge,
                gateCos: gate, eye: p + n * 1e4)
            if ok { r.open += 1 } else {
                r.why[why, default: 0] += 1
                if inside { r.areaBlind += ar }   // ← answer (2), in mm2
            }
            rows[fid] = r
        }
        print(" face   tris  inRegion   open  blind mm2   why not")
        var totalBlind = 0.0
        for (fid, r) in rows.sorted(by: { $0.value.inRegion > $1.value.inRegion })
        where r.inRegion > 0 || r.open > 0 {
            totalBlind += r.areaBlind
            let why = r.why.sorted { $0.value > $1.value }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            print(String(format: "%5d %6d %9d %6d %10.1f   %@",
                         Int(fid), r.tris, r.inRegion, r.open, r.areaBlind,
                         why as NSString))
        }
        print(String(format: "TOTAL shell-over-real-lattice area = %.1f mm2", totalBlind))
    }

    // MARK: - helpers

    private func corners(_ m: ViewerMesh, _ t: Int)
        -> (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) {
        func v(_ i: UInt32) -> SIMD3<Double> {
            let b = Int(i) * 3
            return SIMD3<Double>(Double(m.positions[b]), Double(m.positions[b + 1]),
                                 Double(m.positions[b + 2]))
        }
        return (v(m.indices[t]), v(m.indices[t + 1]), v(m.indices[t + 2]))
    }
    private func fmt3(_ v: SIMD3<Double>) -> String {
        String(format: "(%+.3f %+.3f %+.3f)", v.x, v.y, v.z)
    }
}

// MARK: - 3. WHERE THE CURVED STRIPS SIT RELATIVE TO THE DECLARED OUTLINE

/// ★★★ THE STRIP, LOCATED. Faces 1 / 25 / 22 are `other`-kind (freeform) surfaces
/// whose own normals sit 4-8 deg off the declared wall normal — well inside the
/// 30 deg gate — and they are NOT declared. This asks, per face and with no pixels:
/// where does each one land in the declared face's OWN in-plane frame, and does the
/// bake paint lattice underneath it?
extension LatticeCurvedOutlineBandProbe {

    func testWhereTheCurvedStripsSitAndWhetherLatticeIsUnderThem() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        // ★ SINGLE-CELL MEMBERS **OFF** — his project.json says so, and it is the
        // state the pinned DIAG histogram was read at.
        var hh = P.His(); hh.boundaryFinishWritten = false
        let i = try P.inputs(hh, faces: LatticeRefusedCellProbe.hisFaces)
        guard let rg = i.scene.regionSDF else { throw XCTSkip("no region field") }
        guard let cf = P.bake(i) else { throw XCTSkip("no bake") }
        let inc = i.scene.regions.filter { $0.role == .include }
        let occ = i.scene.occupancy
        let S0 = i.cells.filter { $0 > 0 }.min() ?? 1

        // The base-cell lookup the march does: `bi = round((p - origin)/S0)`.
        // ★ THE CELL FIELD IS ON ITS OWN BASE-CELL GRID, not the occupancy grid —
        // `cf.field` carries that grid, so index it directly rather than converting.
        func paintedAt(_ p: SIMD3<Double>) -> Bool {
            let f = cf.field
            let vx = Int((((p.x - Double(f.origin.x)) / Double(f.spacing.x))).rounded())
            let vy = Int((((p.y - Double(f.origin.y)) / Double(f.spacing.y))).rounded())
            let vz = Int((((p.z - Double(f.origin.z)) / Double(f.spacing.z))).rounded())
            guard vx >= 0, vy >= 0, vz >= 0, vx < f.nx, vy < f.ny, vz < f.nz
            else { return false }
            let idx = vx + f.nx * (vy + f.ny * vz)
            guard idx < cf.steppedCellMM.count else { return false }
            return cf.steppedCellMM[idx] > 0
        }

        print("occ grid \(occ.nx)x\(occ.ny)x\(occ.nz) @ \(occ.spacing.x)  baseCell S0=\(S0)")
        for want in [Int32(1), 25, 22, 2, 15, 16] {
            var inPlane: [Double] = []       // signed dist to nearest declared OUTLINE
            var analytic: [Double] = []      // LatticeRegionMask.signedDistance
            var sampled: [Double] = []       // the field the shader reads
            var paintedIn = 0, n = 0
            var t = 0
            while t + 2 < mesh.indices.count {
                let tri = t / 3
                defer { t += 3 }
                guard tri < mesh.faceIDs.count, mesh.faceIDs[tri] == want else { continue }
                let (a, b, c) = corners2(mesh, t)
                let cr = simd_cross(b - a, c - a)
                guard simd_length(cr) > 1e-12 else { continue }
                let nrm = simd_normalize(cr)
                let p = (a + b + c) / 3
                // ★ ONE MILLIMETRE INSIDE THE MATERIAL — the march's first sample is
                // behind the surface, not on it, and a point exactly ON a zero
                // crossing is a coin flip in a sampled field.
                let q = p - nrm * 1.0
                n += 1
                analytic.append(LatticeRegionMask.signedDistance(q, regions: inc))
                sampled.append(Self.sampleLinear(rg, q))
                // In-plane distance to each declared outline, best (most inside).
                var best = 1e9
                for r in inc {
                    let nn = LatticeRegionMask.unit(r.normal)
                    let d = q - r.origin
                    let (u, v) = LatticeRegionMask.basis(nn)
                    let uv = SIMD2<Double>(simd_dot(d, u), simd_dot(d, v))
                    best = Swift.min(best,
                        LatticeFaceOutline.signedDistance(uv, loops: r.outlineLoops))
                }
                inPlane.append(best)
                if paintedAt(q) { paintedIn += 1 }
            }
            guard n > 0 else { continue }
            func q(_ a: [Double], _ f: Double) -> Double {
                let s = a.sorted(); return s[Swift.min(s.count - 1,
                    Swift.max(0, Int(f * Double(s.count - 1))))]
            }
            print(String(format:
                "face %3d  n=%4d  painted=%4d (%3.0f%%)  inPlane[min %+7.2f p50 %+7.2f max %+7.2f]  analytic[p50 %+7.2f]  sampled[p50 %+7.2f]  sampled>0: %3.0f%%",
                Int(want), n, paintedIn, 100.0 * Double(paintedIn) / Double(n),
                q(inPlane, 0), q(inPlane, 0.5), q(inPlane, 1.0),
                q(analytic, 0.5), q(sampled, 0.5),
                100.0 * Double(sampled.filter { $0 > 0 }.count) / Double(n)))
        }
    }

    private func corners2(_ m: ViewerMesh, _ t: Int)
        -> (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) {
        func v(_ i: UInt32) -> SIMD3<Double> {
            let b = Int(i) * 3
            return SIMD3<Double>(Double(m.positions[b]), Double(m.positions[b + 1]),
                                 Double(m.positions[b + 2]))
        }
        return (v(m.indices[t]), v(m.indices[t + 1]), v(m.indices[t + 2]))
    }
}

// MARK: - 4. THE LAYOUT — where each big face actually is

extension LatticeCurvedOutlineBandProbe {

    func testTheLayoutOfHisWalls() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var hh = P.His(); hh.boundaryFinishWritten = false
        let i = try P.inputs(hh, faces: LatticeRefusedCellProbe.hisFaces)
        let inc = i.scene.regions.filter { $0.role == .include }
        for (k, r) in inc.enumerated() {
            print(String(format:
                "region %d  faceID=%@  origin=(%.2f %.2f %.2f) inward=(%+.3f %+.3f %+.3f) depth=%.2f loops=%d",
                k, String(describing: r.faceID) as NSString,
                r.origin.x, r.origin.y, r.origin.z,
                LatticeRegionMask.unit(r.normal).x, LatticeRegionMask.unit(r.normal).y,
                LatticeRegionMask.unit(r.normal).z, r.depthMM, r.outlineLoops.count))
        }
        var lo: [Int32: SIMD3<Double>] = [:], hi: [Int32: SIMD3<Double>] = [:]
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            defer { t += 3 }
            guard tri < mesh.faceIDs.count else { continue }
            let fid = mesh.faceIDs[tri]
            for c in cornerList(mesh, t) {
                lo[fid] = lo[fid].map { simd_min($0, c) } ?? c
                hi[fid] = hi[fid].map { simd_max($0, c) } ?? c
            }
        }
        print(" face      x range          y range          z range")
        for f in [Int32(15), 2, 16, 1, 25, 22, 18, 23] {
            guard let a = lo[f], let b = hi[f] else { continue }
            print(String(format: "%5d  [%7.2f %7.2f]  [%7.2f %7.2f]  [%7.2f %7.2f]",
                         Int(f), a.x, b.x, a.y, b.y, a.z, b.z))
        }
        let bb = mesh.bounds
        print("mesh bounds min=(\(bb.min.x) \(bb.min.y) \(bb.min.z)) max=(\(bb.max.x) \(bb.max.y) \(bb.max.z))")
    }

    private func cornerList(_ m: ViewerMesh, _ t: Int) -> [SIMD3<Double>] {
        func v(_ i: UInt32) -> SIMD3<Double> {
            let b = Int(i) * 3
            return SIMD3<Double>(Double(m.positions[b]), Double(m.positions[b + 1]),
                                 Double(m.positions[b + 2]))
        }
        return [v(m.indices[t]), v(m.indices[t + 1]), v(m.indices[t + 2])]
    }
}

// MARK: - 5. A LINE THROUGH EACH WALL — where does the paint stop?

extension LatticeCurvedOutlineBandProbe {

    func testWalkTheThicknessOfBothWalls() throws {
        var hh = P.His(); hh.boundaryFinishWritten = false
        let i = try P.inputs(hh, faces: LatticeRefusedCellProbe.hisFaces)
        guard let cf = P.bake(i), let rg = i.scene.regionSDF else { throw XCTSkip("no bake") }
        let occ = i.scene.occupancy
        let inc = i.scene.regions.filter { $0.role == .include }
        print("cellField grid \(cf.field.nx)x\(cf.field.ny)x\(cf.field.nz) "
              + "origin=(\(cf.field.origin.x) \(cf.field.origin.y) \(cf.field.origin.z)) "
              + "spacing=\(cf.field.spacing.x)")
        func occAt(_ p: SIMD3<Double>) -> Float {
            let vx = Int((((p.x - Double(occ.origin.x)) / Double(occ.spacing.x))).rounded())
            let vy = Int((((p.y - Double(occ.origin.y)) / Double(occ.spacing.y))).rounded())
            let vz = Int((((p.z - Double(occ.origin.z)) / Double(occ.spacing.z))).rounded())
            guard vx >= 0, vy >= 0, vz >= 0, vx < occ.nx, vy < occ.ny, vz < occ.nz
            else { return -9 }
            return occ.values[vx + occ.nx * (vy + occ.ny * vz)]
        }
        func cellAt(_ p: SIMD3<Double>) -> Float {
            let f = cf.field
            let vx = Int((((p.x - Double(f.origin.x)) / Double(f.spacing.x))).rounded())
            let vy = Int((((p.y - Double(f.origin.y)) / Double(f.spacing.y))).rounded())
            let vz = Int((((p.z - Double(f.origin.z)) / Double(f.spacing.z))).rounded())
            guard vx >= 0, vy >= 0, vz >= 0, vx < f.nx, vy < f.ny, vz < f.nz
            else { return -9 }
            let idx = vx + f.nx * (vy + f.ny * vz)
            return idx < cf.steppedCellMM.count ? cf.steppedCellMM[idx] : -9
        }
        // Three columns well inside the walls in x/z.
        for (x, z) in [(100.0, 100.0), (60.0, 60.0), (150.0, 150.0)] {
            print("--- column x=\(x) z=\(z) :  y   occ  regionSDF  sampled  cellMM  owned")
            var y = 6.0
            while y > -52.0 {
                let p = SIMD3<Double>(x, y, z)
                let o = occAt(p)
                let an = LatticeRegionMask.signedDistance(p, regions: inc)
                let sa = Self.sampleLinear(rg, p)
                let cm = cellAt(p)
                let owned = inc.contains { LatticeRegionMask.contains(p, region: $0) }
                if o > 0.5 || abs(an) < 14 {
                    print(String(format: "   %7.2f  %4.1f  %+8.2f  %+8.2f  %6.2f  %@",
                                 y, o, an, sa, cm, owned ? "Y" : "."))
                }
                y -= 1.719
            }
        }
    }
}

// MARK: - 6. THE BAND, IN MILLIMETRES, AS A FUNCTION OF OUTLINE CURVATURE

/// ★★★ HIS SYMPTOM, MEASURED DIRECTLY. "Holes along the sides of the latticed
/// walls, concentrated where the face outline is CURVED."
///
/// ★ THE CONFOUND CONTROL. This is not a pixel count and not a frame comparison,
/// so none of the five confounds of handoff §6 apply: there is no far wall to show
/// through (the walk stays on ONE declared face, at its own depth), no shell AO, no
/// camera, and no ground plane. The measurement is: stand on a point of the face's
/// own outline, walk INWARD in the face's plane, and record the distance at which
/// the bake first has a painted cell whose clip would let a strut be drawn. That
/// distance IS the band, in millimetres. Curvature is computed from the same
/// outline polyline, so the two numbers come from one object and cannot drift.
extension LatticeCurvedOutlineBandProbe {

    func testBandWidthAlongTheOutlineVersusCurvature() throws {
        var hh = P.His(); hh.boundaryFinishWritten = false
        let i = try P.inputs(hh, faces: LatticeRefusedCellProbe.hisFaces)
        guard let cf = P.bake(i), let rg = i.scene.regionSDF else { throw XCTSkip("no bake") }
        let occ = i.scene.occupancy
        let inc = i.scene.regions.filter { $0.role == .include }

        func cellAt(_ p: SIMD3<Double>) -> Float {
            let f = cf.field
            let vx = Int((((p.x - Double(f.origin.x)) / Double(f.spacing.x))).rounded())
            let vy = Int((((p.y - Double(f.origin.y)) / Double(f.spacing.y))).rounded())
            let vz = Int((((p.z - Double(f.origin.z)) / Double(f.spacing.z))).rounded())
            guard vx >= 0, vy >= 0, vz >= 0, vx < f.nx, vy < f.ny, vz < f.nz else { return -9 }
            let idx = vx + f.nx * (vy + f.ny * vz)
            return idx < cf.steppedCellMM.count ? cf.steppedCellMM[idx] : -9
        }
        func occAt(_ p: SIMD3<Double>) -> Float {
            let vx = Int((((p.x - Double(occ.origin.x)) / Double(occ.spacing.x))).rounded())
            let vy = Int((((p.y - Double(occ.origin.y)) / Double(occ.spacing.y))).rounded())
            let vz = Int((((p.z - Double(occ.origin.z)) / Double(occ.spacing.z))).rounded())
            guard vx >= 0, vy >= 0, vz >= 0, vx < occ.nx, vy < occ.ny, vz < occ.nz else { return -9 }
            return occ.values[vx + occ.nx * (vy + occ.ny * vz)]
        }

        for (ri, r) in inc.enumerated() {
            guard let loop = r.outlineLoops.first, loop.count > 8 else { continue }
            let n = LatticeRegionMask.unit(r.normal)
            let (u, v) = LatticeRegionMask.basis(n)
            // ★ ONE MILLIMETRE BELOW THE DECLARED FACE — inside the material, and
            // clear of the zero crossing that makes a sampled field a coin flip.
            let depth = 1.0
            var rows: [(curv: Double, band: Double)] = []
            let m = loop.count
            for k in 0..<m {
                let a = loop[(k + m - 1) % m], b = loop[k], c = loop[(k + 1) % m]
                let e0 = b - a, e1 = c - b
                let l0 = simd_length(e0), l1 = simd_length(e1)
                guard l0 > 1e-6, l1 > 1e-6 else { continue }
                // Discrete curvature: turning angle per unit arc length (1/mm).
                let cosT = Swift.max(-1, Swift.min(1, simd_dot(e0 / l0, e1 / l1)))
                let curv = acos(cosT) / (0.5 * (l0 + l1))
                // Inward in-plane direction: toward the interior, found from the
                // outline's own signed distance (which is negative inside).
                let tangent = simd_normalize(e0 / l0 + e1 / l1)
                var inward2 = SIMD2<Double>(-tangent.y, tangent.x)
                if LatticeFaceOutline.signedDistance(b + inward2 * 0.5, loops: r.outlineLoops)
                    > LatticeFaceOutline.signedDistance(b - inward2 * 0.5, loops: r.outlineLoops) {
                    inward2 = -inward2
                }
                // Walk inward until the bake would actually draw something.
                var band = Double.nan
                var t = 0.0
                while t <= 20.0 {
                    let uv = b + inward2 * t
                    let p = r.origin + u * uv.x + v * uv.y + n * depth
                    if occAt(p) > 0.5, cellAt(p) > 0,
                       Self.sampleLinear(rg, p) <= 0 { band = t; break }
                    t += 0.25
                }
                if band.isNaN { band = 20.0 }
                rows.append((curv, band))
            }
            guard !rows.isEmpty else { continue }
            // Bin by curvature. A straight run has curv ~ 0; a fillet is large.
            let bins: [(String, ClosedRange<Double>)] = [
                ("straight  curv<0.002", 0.0...0.002),
                ("gentle    0.002-0.02", 0.002...0.02),
                ("curved    0.02-0.1  ", 0.02...0.1),
                ("tight     >0.1      ", 0.1...1e9),
            ]
            print("=== region \(ri)  face \(String(describing: r.faceID))  "
                  + "outline pts=\(rows.count) ===")
            print("  curvature bin          n    band mm: p50    p90     max")
            for (lab, rng) in bins {
                let sel = rows.filter { rng.contains($0.curv) }.map(\.band).sorted()
                guard !sel.isEmpty else { continue }
                func q(_ f: Double) -> Double {
                    sel[Swift.min(sel.count - 1, Swift.max(0, Int(f * Double(sel.count - 1))))]
                }
                print(String(format: "  %@ %4d            %6.2f %6.2f  %6.2f",
                             lab as NSString, sel.count, q(0.5), q(0.9), q(1.0)))
            }
        }
    }
}

// MARK: - 7. THE WALL, FACE-ON — a map in the face's own (u,v) millimetres

/// ★★★ NAMING THE GREY BANDS. Every previous attempt to attribute the band worked
/// from a rendered frame, at a camera, through a channel — the five confounds of
/// handoff §6. This does not render the scene at all. It rasterises the DECLARED
/// FACE'S OWN PLANE, one pixel per half-millimetre of (u,v), and paints each pixel
/// by what the bake and the region say there. The result is the wall as it would
/// look face-on, with every pixel's colour a fact rather than a shade:
///
///   black    outside the face's outline entirely
///   grey     inside the outline, but no MATERIAL at this depth
///   red      material, but the region does not own it   (prism too shallow/short)
///   orange   owned, but the bake painted NO cell        (the occupancy/centre gate)
///   yellow   painted, but the sampled region clips it   (bake vs march disagree)
///   green    painted AND clip open — the march will draw struts here
extension LatticeCurvedOutlineBandProbe {

    func testDrawTheWallFaceOn() throws {
        var hh = P.His(); hh.boundaryFinishWritten = false
        let i = try P.inputs(hh, faces: LatticeRefusedCellProbe.hisFaces)
        guard let cf = P.bake(i), let rg = i.scene.regionSDF else { throw XCTSkip("no bake") }
        let occ = i.scene.occupancy
        let inc = i.scene.regions.filter { $0.role == .include }
        let out = ProcessInfo.processInfo.environment["QUILT_OUT"]
            ?? NSTemporaryDirectory() + "quilt"

        func cellAt(_ p: SIMD3<Double>) -> Float {
            let f = cf.field
            let vx = Int((((p.x - Double(f.origin.x)) / Double(f.spacing.x))).rounded())
            let vy = Int((((p.y - Double(f.origin.y)) / Double(f.spacing.y))).rounded())
            let vz = Int((((p.z - Double(f.origin.z)) / Double(f.spacing.z))).rounded())
            guard vx >= 0, vy >= 0, vz >= 0, vx < f.nx, vy < f.ny, vz < f.nz else { return -9 }
            let idx = vx + f.nx * (vy + f.ny * vz)
            return idx < cf.steppedCellMM.count ? cf.steppedCellMM[idx] : -9
        }
        func occAt(_ p: SIMD3<Double>) -> Float {
            let vx = Int((((p.x - Double(occ.origin.x)) / Double(occ.spacing.x))).rounded())
            let vy = Int((((p.y - Double(occ.origin.y)) / Double(occ.spacing.y))).rounded())
            let vz = Int((((p.z - Double(occ.origin.z)) / Double(occ.spacing.z))).rounded())
            guard vx >= 0, vy >= 0, vz >= 0, vx < occ.nx, vy < occ.ny, vz < occ.nz else { return -9 }
            return occ.values[vx + occ.nx * (vy + occ.ny * vz)]
        }

        let size = 512
        for (ri, r) in inc.enumerated() {
            guard !r.outlineLoops.isEmpty else { continue }
            let n = LatticeRegionMask.unit(r.normal)
            let (u, v) = LatticeRegionMask.basis(n)
            // Extent of the outline in (u,v), padded, mapped to `size` pixels.
            var lo = SIMD2<Double>(1e9, 1e9), hi = SIMD2<Double>(-1e9, -1e9)
            for lp in r.outlineLoops { for q in lp { lo = simd_min(lo, q); hi = simd_max(hi, q) } }
            lo -= SIMD2(6, 6); hi += SIMD2(6, 6)
            let span = Swift.max(hi.x - lo.x, hi.y - lo.y)
            var px = [UInt8](repeating: 0, count: size * size * 4)
            var tally: [String: Int] = [:]
            // ★ ONE MILLIMETRE BELOW THE FACE — inside the material, clear of the
            // zero crossing. The same depth the band walk used, so the two agree.
            let depth = 1.0
            for py in 0..<size {
                for pxi in 0..<size {
                    let uu = lo.x + span * (Double(pxi) + 0.5) / Double(size)
                    let vv = lo.y + span * (Double(size - 1 - py) + 0.5) / Double(size)
                    let p = r.origin + u * uu + v * vv + n * depth
                    let d = LatticeFaceOutline.signedDistance(SIMD2(uu, vv),
                                                              loops: r.outlineLoops)
                    var c: (UInt8, UInt8, UInt8) = (0, 0, 0)
                    var key = "outside"
                    if d <= 0 {
                        if occAt(p) <= 0.5 { c = (70, 70, 78); key = "no-material" }
                        else if !inc.contains(where: { LatticeRegionMask.contains(p, region: $0) }) {
                            c = (220, 40, 40); key = "not-owned"
                        } else if cellAt(p) <= 0 { c = (240, 150, 30); key = "unpainted" }
                        else if Self.sampleLinear(rg, p) > 0 { c = (240, 230, 40); key = "clipped" }
                        else { c = (40, 190, 90); key = "drawn" }
                    }
                    tally[key, default: 0] += 1
                    let o = 4 * (py * size + pxi)
                    px[o] = c.0; px[o + 1] = c.1; px[o + 2] = c.2; px[o + 3] = 255
                }
            }
            let inside = tally.filter { $0.key != "outside" }.values.reduce(0, +)
            let name = "faceon_region\(ri)_face\(r.faceID.map(String.init) ?? "?").png"
            LatticeQuiltFrameProbe.writePNG(px, size: size, to: out + "/" + name)
            print("=== region \(ri) face \(String(describing: r.faceID))  "
                  + "span=\(String(format: "%.1f", span)) mm  -> \(name)")
            for k in ["drawn", "clipped", "unpainted", "not-owned", "no-material"] {
                guard let cnt = tally[k] else { continue }
                print(String(format: "    %-12@ %7d  %5.1f%% of the outline",
                             k as NSString, cnt, 100.0 * Double(cnt) / Double(Swift.max(1, inside))))
            }
        }
        print("maps -> \(out)")
    }
}

// MARK: - 8. AREA-WEIGHTED: WHERE DOES THE SHELL COVER REAL LATTICE?

/// ★★★ THE MEASUREMENT THE HANDOFF ASKS FOR, WITH ITS CONFOUND CONTROL STATED.
///
/// ★ THE CONTROL. This is an A/B on ONE variable — the shell's normal gate — and it
/// is evaluated as ARITHMETIC, not as pixels. Nothing else moves: same mesh, same
/// bake, same region field, no camera, no far wall, no AO, no ground plane. The
/// five confounds of handoff §6 are all properties of a rendered frame and none of
/// them exists here. Each surface sample is asked from a viewpoint along its OWN
/// normal, so "which cap faces the eye" is answered the same way for every sample
/// and cannot smuggle a camera back in.
///
/// ★ AREA-WEIGHTED, because the side faces are coarsely tessellated — face 23 is
/// 9,632 mm² in 45 triangles, so a per-centroid test samples it 45 times and misses
/// the 11 mm-deep band that matters entirely. Each triangle is sampled on a
/// barycentric lattice and every sample carries its share of the area.
///
/// The quantity: **mm² of visible part surface where the shipping 30 deg gate keeps
/// the shell closed, and there IS painted, unclipped lattice one millimetre behind
/// it.** That is "the material is there and something in front of it is dark",
/// stated as a number and attributed to a named face.
extension LatticeCurvedOutlineBandProbe {

    func testAreaWhereTheShellCoversRealLattice() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var hh = P.His(); hh.boundaryFinishWritten = false
        let i = try P.inputs(hh, faces: LatticeRefusedCellProbe.hisFaces)
        guard let cf = P.bake(i), let rg = i.scene.regionSDF else { throw XCTSkip("no bake") }
        let occ = i.scene.occupancy
        let inc = i.scene.regions.filter { $0.role == .include }
        let decls = inc.map { LatticeRegionMask.unit($0.normal) }
        let nudge = Double(max(rg.spacing.x, max(rg.spacing.y, rg.spacing.z)))

        func cellAt(_ p: SIMD3<Double>) -> Float {
            let f = cf.field
            let vx = Int((((p.x - Double(f.origin.x)) / Double(f.spacing.x))).rounded())
            let vy = Int((((p.y - Double(f.origin.y)) / Double(f.spacing.y))).rounded())
            let vz = Int((((p.z - Double(f.origin.z)) / Double(f.spacing.z))).rounded())
            guard vx >= 0, vy >= 0, vz >= 0, vx < f.nx, vy < f.ny, vz < f.nz else { return -9 }
            let idx = vx + f.nx * (vy + f.ny * vz)
            return idx < cf.steppedCellMM.count ? cf.steppedCellMM[idx] : -9
        }
        func occAt(_ p: SIMD3<Double>) -> Float {
            let vx = Int((((p.x - Double(occ.origin.x)) / Double(occ.spacing.x))).rounded())
            let vy = Int((((p.y - Double(occ.origin.y)) / Double(occ.spacing.y))).rounded())
            let vz = Int((((p.z - Double(occ.origin.z)) / Double(occ.spacing.z))).rounded())
            guard vx >= 0, vy >= 0, vz >= 0, vx < occ.nx, vy < occ.ny, vz < occ.nz else { return -9 }
            return occ.values[vx + occ.nx * (vy + occ.ny * vz)]
        }
        /// Is there lattice the march would actually draw, one mm behind this surface?
        func latticeBehind(_ p: SIMD3<Double>, _ n: SIMD3<Double>) -> Bool {
            let q = p - n * 1.0
            return occAt(q) > 0.5 && cellAt(q) > 0 && Self.sampleLinear(rg, q) <= 0
        }

        struct Row { var area = 0.0; var behind = 0.0
                     var closed30 = 0.0; var open89 = 0.0; var hidden = 0.0 }
        var rows: [Int32: Row] = [:]
        var why: [Int32: [String: Int]] = [:]
        let K = 6      // barycentric samples per edge -> 21 samples per triangle
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            defer { t += 3 }
            guard tri < mesh.faceIDs.count else { continue }
            let fid = mesh.faceIDs[tri]
            let (a, b, c) = corners3(mesh, t)
            let cr = simd_cross(b - a, c - a)
            let ar = 0.5 * simd_length(cr)
            guard ar > 1e-12 else { continue }
            let nrm = simd_normalize(cr)
            // ★ INTERIOR SAMPLES ONLY, AND EQUAL-AREA. A barycentric lattice that
            // includes the edges puts 18 of its 28 points ON the triangle boundary,
            // which on a 61-triangle face over 17,000 mm2 biases every count toward
            // the outline — where the lattice is clipped. Each sample is the centre
            // of one of the K^2 congruent sub-triangles, so all carry equal area and
            // none sits on an edge.
            var pts: [SIMD3<Double>] = []
            for ii in 0..<K { for jj in 0..<(K - ii) {
                let l0 = (Double(ii) + 1.0 / 3.0) / Double(K)
                let l1 = (Double(jj) + 1.0 / 3.0) / Double(K)
                pts.append(a * (1 - l0 - l1) + b * l0 + c * l1)
                if jj < K - ii - 1 {
                    let m0 = (Double(ii) + 2.0 / 3.0) / Double(K)
                    let m1 = (Double(jj) + 2.0 / 3.0) / Double(K)
                    pts.append(a * (1 - m0 - m1) + b * m0 + c * m1)
                }
            } }
            let w = ar / Double(pts.count)
            var r = rows[fid] ?? Row()
            for p in pts {
                r.area += w
                let q = p - nrm * 1.0
                if occAt(q) <= 0.5 { why[fid, default: [:]]["no-material", default: 0] += 1 }
                else if cellAt(q) <= 0 { why[fid, default: [:]]["unpainted", default: 0] += 1 }
                else if Self.sampleLinear(rg, q) > 0 { why[fid, default: [:]]["clipped", default: 0] += 1 }
                else { why[fid, default: [:]]["drawn", default: 0] += 1 }
                let behind = latticeBehind(p, nrm)
                if behind { r.behind += w }
                let (o30, _) = Self.shellIsLatticed(p: p, n: nrm, decls: decls, grid: rg,
                                                    nudge: nudge, gateCos: cos(30 * .pi / 180),
                                                    eye: p + nrm * 1e4)
                let (o89, _) = Self.shellIsLatticed(p: p, n: nrm, decls: decls, grid: rg,
                                                    nudge: nudge, gateCos: cos(89 * .pi / 180),
                                                    eye: p + nrm * 1e4)
                if !o30 { r.closed30 += w }
                if o89 { r.open89 += w }
                // ★ THE HEADLINE: shut by the shipping gate, and lattice really behind it.
                if !o30 && behind { r.hidden += w }
            }
            rows[fid] = r
        }
        print(" face    area mm2   latticeBehind   closed@30   open@89   HIDDEN mm2  (% of face)")
        var total = 0.0, totalArea = 0.0
        for (fid, r) in rows.sorted(by: { $0.value.area > $1.value.area })
        where r.area > 500 {
            total += r.hidden; totalArea += r.area
            print(String(format: "%5d  %9.1f   %9.1f     %9.1f %9.1f   %9.1f   %5.1f%%",
                         Int(fid), r.area, r.behind, r.closed30, r.open89, r.hidden,
                         100.0 * r.hidden / Swift.max(1e-9, r.area)))
        }
        for f in [Int32(15), 2, 16, 23, 18] {
            guard let w = why[f] else { continue }
            let tot = w.values.reduce(0, +)
            print("  face \(f) behind-the-surface: "
                  + w.sorted { $0.value > $1.value }
                     .map { "\($0.key)=\(String(format: "%.1f%%", 100.0 * Double($0.value) / Double(tot)))" }
                     .joined(separator: "  "))
        }
        let grand = rows.values.reduce(0.0) { $0 + $1.hidden }
        let grandArea = rows.values.reduce(0.0) { $0 + $1.area }
        print(String(format:
            "TOTAL over the whole part: %.1f mm2 of surface hides real lattice, of %.1f mm2 (%.1f%%)",
            grand, grandArea, 100.0 * grand / grandArea))
    }

    private func corners3(_ m: ViewerMesh, _ t: Int)
        -> (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) {
        func v(_ i: UInt32) -> SIMD3<Double> {
            let b = Int(i) * 3
            return SIMD3<Double>(Double(m.positions[b]), Double(m.positions[b + 1]),
                                 Double(m.positions[b + 2]))
        }
        return (v(m.indices[t]), v(m.indices[t + 1]), v(m.indices[t + 2]))
    }
}

// MARK: - 9. DUMP THE MESH so the bands can be NAMED by ray-cast

/// ★ SEARCHING, NOT JUDGING. Handoff §0.1 reserves verdicts for the simulator; this
/// writes the geometry out so a face-ID ray-cast can say WHICH SURFACE each pale
/// band in his screenshot is. That is an identification, not an opinion about how
/// the preview looks.
extension LatticeCurvedOutlineBandProbe {

    func testDumpHisMeshForRaycast() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let out = (ProcessInfo.processInfo.environment["QUILT_OUT"]
                   ?? NSTemporaryDirectory() + "quilt")
        try? FileManager.default.createDirectory(atPath: out,
                                                 withIntermediateDirectories: true)
        var d = Data()
        var counts = [Int32(mesh.positions.count / 3), Int32(mesh.indices.count / 3)]
        d.append(Data(bytes: &counts, count: 8))
        var pos = mesh.positions
        d.append(Data(bytes: &pos, count: pos.count * 4))
        var idx = mesh.indices.map { Int32($0) }
        d.append(Data(bytes: &idx, count: idx.count * 4))
        var fids = mesh.faceIDs
        // Pad with -1 if the tessellator gave fewer ids than triangles.
        while fids.count < mesh.indices.count / 3 { fids.append(-1) }
        d.append(Data(bytes: &fids, count: fids.count * 4))
        try d.write(to: URL(fileURLWithPath: out + "/hismesh.bin"))
        print("verts=\(mesh.positions.count / 3) tris=\(mesh.indices.count / 3) "
              + "faceIDs=\(mesh.faceIDs.count) -> \(out)/hismesh.bin")
    }
}

// MARK: - 10. THE RIM, IN MILLIMETRES — material outside the declared outline

/// ★★★ THE BAND HE IS POINTING AT, MEASURED. The identification (probe 8) is that
/// the pale bands are the part's own surface OUTSIDE the declared face's outline:
/// every undeclared face has 0.0 mm2 of lattice candidate behind it. This measures
/// how wide that band is, in millimetres, in the declared face's own plane.
///
/// ★ THE CONFOUND CONTROL. `partSDF` is the distance to the PART, baked from the
/// mesh and never clipped to a region — so "is there material here" is answered by
/// the geometry alone, with no reference to the regions, the bake, the shell or any
/// frame. Walking OUTWARD from the outline in the face's own plane keeps the
/// measurement in-plane, so the far wall (27 mm away in the normal direction)
/// cannot enter it. That is the confound that spoiled every previous attempt.
extension LatticeCurvedOutlineBandProbe {

    func testHowWideIsTheRimOutsideHisDeclaredOutline() throws {
        var hh = P.His(); hh.boundaryFinishWritten = false
        let i = try P.inputs(hh, faces: LatticeRefusedCellProbe.hisFaces)
        let inc = i.scene.regions.filter { $0.role == .include }
        let psdf = i.scene.partSDF
        func partAt(_ p: SIMD3<Double>) -> Double { Self.sampleLinear(psdf, p) }

        for (ri, r) in inc.enumerated() {
            guard let loop = r.outlineLoops.first, loop.count > 8 else { continue }
            let n = LatticeRegionMask.unit(r.normal)
            let (u, v) = LatticeRegionMask.basis(n)
            let m = loop.count
            var rows: [(curv: Double, rim: Double)] = []
            for k in 0..<m {
                let a = loop[(k + m - 1) % m], b = loop[k], c = loop[(k + 1) % m]
                let e0 = b - a, e1 = c - b
                let l0 = simd_length(e0), l1 = simd_length(e1)
                guard l0 > 1e-6, l1 > 1e-6 else { continue }
                let cosT = Swift.max(-1, Swift.min(1, simd_dot(e0 / l0, e1 / l1)))
                let curv = acos(cosT) / (0.5 * (l0 + l1))
                let tangent = simd_normalize(e0 / l0 + e1 / l1)
                var outward = SIMD2<Double>(-tangent.y, tangent.x)
                if LatticeFaceOutline.signedDistance(b + outward * 0.5, loops: r.outlineLoops)
                    < LatticeFaceOutline.signedDistance(b - outward * 0.5, loops: r.outlineLoops) {
                    outward = -outward
                }
                // Walk OUT of the face, one millimetre below its plane, until the
                // part itself ends. That length is the un-declared rim.
                var rim = 0.0, t = 0.0
                while t <= 30.0 {
                    let uv = b + outward * t
                    let p = r.origin + u * uv.x + v * uv.y + n * 1.0
                    if partAt(p) > 0 { break }
                    rim = t; t += 0.25
                }
                rows.append((curv, rim))
            }
            let bins: [(String, ClosedRange<Double>)] = [
                ("straight  curv<0.002", 0.0...0.002),
                ("gentle    0.002-0.02", 0.002...0.02),
                ("curved    0.02-0.1  ", 0.02...0.1),
                ("tight     >0.1      ", 0.1...1e9),
            ]
            print("=== region \(ri) face \(String(describing: r.faceID))  pts=\(rows.count) ===")
            print("  curvature bin           n   rim mm OUTSIDE the outline: p50   p90    max")
            for (lab, rng) in bins {
                let sel = rows.filter { rng.contains($0.curv) }.map(\.rim).sorted()
                guard !sel.isEmpty else { continue }
                func q(_ f: Double) -> Double {
                    sel[Swift.min(sel.count - 1, Swift.max(0, Int(f * Double(sel.count - 1))))]
                }
                print(String(format: "  %@ %4d                          %6.2f %6.2f %6.2f",
                             lab as NSString, sel.count, q(0.5), q(0.9), q(1.0)))
            }
            let all = rows.map(\.rim).sorted()
            print(String(format: "  ALL pts p50=%.2f mm  mean=%.2f mm",
                         all[all.count / 2], all.reduce(0, +) / Double(all.count)))
        }
    }
}

// MARK: - 11. WHAT DENSITY IS THE GRADED BAND ACTUALLY DRAWN AT?

/// ★★★ THE BAND AT THE OUTLINE IS NOT EMPTY — IT IS TOO FULL.
///
/// Zoomed on the device, the band between the last full cell and the chamfer is a
/// flat blue field carrying small dark motifs. Those motifs are not struts with the
/// gaps between them; they are the PERIODIC HOLES OF A MERGED SHEET — the same
/// regime handoff fix #1 identified, where an octet near ~48% stops reading as a
/// truss and reads as perforated solid.
///
/// The mechanism this checks: grade-to-shape steps the cell DOWN toward the outline,
/// and a smaller cell cannot be printed thin — `printabilityDensityFloor` is the
/// density at which one bead of `lineWidthMM` fills a strut, and it RISES as the
/// cell shrinks. So the finest rungs of the ladder are forced to a high density
/// exactly where the grade was supposed to be thinning the material out.
///
/// ★ CONFOUND CONTROL: no pixels, no camera, no frame. Cell size and demand are read
/// out of the same baked field the shader samples; the density law and the
/// printability floor are core's own functions, called directly.
extension LatticeCurvedOutlineBandProbe {

    func testTheDensityTheGradedBandIsDrawnAt() throws {
        var hh = P.His(); hh.boundaryFinishWritten = false
        let i = try P.inputs(hh, faces: LatticeRefusedCellProbe.hisFaces)
        guard let cf = P.bake(i) else { throw XCTSkip("no bake") }
        let lat = LatticeType.named("octet")
        let lw = hh.lineWidthMM, lo = hh.rhoMin, hi = hh.rhoMax
        let S0 = i.cells.filter { $0 > 0 }.min() ?? 1

        print(String(format: "line width %.2f mm   density band %.0f%%..%.0f%%   base cell %.2f mm",
                     lw, lo * 100, hi * 100, S0))
        print("  cell mm   n    count   printFloor   strut@floor   strut@5%   merge?")
        var byCell: [String: Int] = [:]
        for v in cf.steppedCellMM where v > 0 {
            byCell[String(format: "%.2f", v), default: 0] += 1
        }
        // ★ THE MERGE THRESHOLD, MEASURED not assumed: the density at which the
        // octet's strut diameter reaches the spacing between neighbouring struts, so
        // the truss closes into a sheet. Found by bisection on core's own law.
        func mergeDensity(_ cell: Double) -> Double {
            var a = 0.0, b = 1.0
            for _ in 0..<40 {
                let m = 0.5 * (a + b)
                let d = TopOptKit.latticeStrutDiameterMM(topology: "octet",
                                                         relativeDensity: m, cellMM: cell)
                // octet struts run corner->face-centre; nearest parallel pair is
                // cell/2 apart in the canonical unit cell.
                if d < cell / 2 { a = m } else { b = m }
            }
            return 0.5 * (a + b)
        }
        for (k, n) in byCell.sorted(by: { (Double($0.key) ?? 0) > (Double($1.key) ?? 0) }) {
            let cell = Double(k) ?? 0
            let floor = lat.printabilityDensityFloor(lineWidthMM: lw, cellMM: cell)
            let dFloor = TopOptKit.latticeStrutDiameterMM(topology: "octet",
                                                          relativeDensity: floor, cellMM: cell)
            let d5 = TopOptKit.latticeStrutDiameterMM(topology: "octet",
                                                      relativeDensity: 0.05, cellMM: cell)
            let merge = mergeDensity(cell)
            print(String(format: "  %7.2f  %3.1f  %6d   %8.1f%%    %8.3f mm  %7.3f mm   merge@%.0f%%  %@",
                         cell, S0 / cell, n, floor * 100, dFloor, d5, merge * 100,
                         (floor >= merge ? "*** FLOOR IS ABOVE MERGE ***" : "") as NSString))
        }
    }
}

// MARK: - 12. THE LADDER FLOOR, PINNED

/// ★★★ A GUARD FOR HIS RULING OF 2026-08-28: *"Once you hit the printability floor go
/// solid."*
///
/// ★ WHY THIS TEST HAD TO BE WRITTEN. Changing the ladder floor from the density
/// band's CEILING to its FLOOR removed subdivision from 1,518 of 3,369 painted cells
/// — 45% of the wall — and turned exactly ONE guard in the whole suite red
/// (`LatticeQuiltBakeProbe.testTheHeadlessBakeMatchesTheApp`, which pins his part's
/// histogram and nothing else). A rule that big with that little holding it down can
/// be reverted by accident. This pins the rule itself, on arithmetic, independent of
/// his part: no rung may require a density the part is not drawn at.
extension LatticeCurvedOutlineBandProbe {

    /// The ladder floor, as the product computes it.
    private func floor(finest: Double, lineWidthMM: Double, binds: Double) -> Double {
        let lat = LatticeType.named("octet")
        var s = finest
        while s > 0 {
            let half = s / 2
            if lat.printabilityDensityFloor(lineWidthMM: lineWidthMM,
                                            cellMM: half) > binds + 1e-9 { break }
            s = half
        }
        return s
    }

    func testNoRungSurvivesThatTheDensityBandCannotPrint() throws {
        let lat = LatticeType.named("octet")
        let lw = 0.45
        // His part's region cells, and two others so the rule is pinned as a rule and
        // not as one part's arithmetic.
        for finest in [5.156120181083679, 6.0, 12.0, 3.0] {
            for lo in [0.05, 0.20, 0.45] {
                let f = floor(finest: finest, lineWidthMM: lw, binds: lo)
                let need = lat.printabilityDensityFloor(lineWidthMM: lw, cellMM: f)
                // ★ THE LADDER NEVER GOES COARSER THAN THE REGION'S OWN CELL.
                XCTAssertLessThanOrEqual(f, finest + 1e-9)
                // ★★★ THE INVARIANT, AND IT IS ABOUT WHAT THE LADDER **ADDS**.
                //
                // ★ MY FIRST VERSION OF THIS ASSERTION WAS WRONG AND THE TEST CAUGHT
                // IT. I asserted that the surviving floor always prints at the
                // sparsest density — which fails at finest = 3.0 mm, lo = 5%: the
                // loop only ever tests the NEXT halving, so it returns the STARTING
                // cell untested, and 3.0 mm already needs 13.1%. That is not this
                // rule's business — the region's own cell is set by the cells-per-
                // member derivation upstream — so the contract is conditional: every
                // rung the ladder actually TAKES must be printable at `lo`.
                //
                // ★ AND THE UNCONDITIONAL CASE IS A REAL LEAD, NOT AN EXCUSE. When
                // the region cell itself needs more than `lo`, the whole wall is
                // drawn at the printability floor with NO grading involved — which is
                // the one thing his 2026-08-28 report says and this change cannot
                // explain: *the holes survive Grade off.* On his part the region
                // cells are 5.16 / 6.00 mm and need 0.0%, so it does not bite there;
                // on a thinner wall it would. See `testAThinWallIsAboveTheBandBefore
                // AnyGradingAtAll`.
                if f < finest - 1e-9 {
                    XCTAssertLessThanOrEqual(need, lo + 1e-9,
                        "★ the ladder STEPPED DOWN to \(f) mm, which needs \(need) "
                        + "density — above the sparsest the part is drawn at (\(lo)). "
                        + "The grade would be making the material DENSER as it thins, "
                        + "which is the perforated band of 2026-08-28")
                }
                // And it is the FINEST such rung — one more halving must fail.
                if f > 1e-6, f < finest - 1e-9 || lat.printabilityDensityFloor(
                    lineWidthMM: lw, cellMM: finest) <= lo + 1e-9 {
                    let next = lat.printabilityDensityFloor(lineWidthMM: lw, cellMM: f / 2)
                    XCTAssertGreaterThan(next, lo + 1e-9,
                        "★ the ladder stopped early: \(f / 2) mm would still print at "
                        + "\(lo), so a rung the grade could have used was refused")
                }
            }
        }
    }

    /// ★ AND THE REGRESSION ITSELF, NAMED. Against the band's CEILING his part reached
    /// 1.29 mm, whose floor is 52.1% — above the 47.5% at which fix #1 measured an
    /// octet merging into a sheet with periodic holes. Against the band's FLOOR it
    /// stops at his region cell. This pins the difference so the ceiling test cannot
    /// come back without someone reading why it went.
    func testTheCeilingTestIsWhatReachedTheMergedBand() throws {
        let lat = LatticeType.named("octet")
        let lw = 0.45, finest = 5.156120181083679
        let atCeiling = floor(finest: finest, lineWidthMM: lw, binds: 0.90)
        let atFloor = floor(finest: finest, lineWidthMM: lw, binds: 0.05)
        XCTAssertEqual(atCeiling, 1.2890300452709198, accuracy: 1e-9)
        XCTAssertEqual(atFloor, finest, accuracy: 1e-9)
        let needCeiling = lat.printabilityDensityFloor(lineWidthMM: lw, cellMM: atCeiling)
        XCTAssertGreaterThan(needCeiling, 0.475,
            "★ the 1.29 mm rung the ceiling test allowed needs \(needCeiling) density; "
            + "if this ever drops below 0.475 the merge argument for this change is "
            + "gone and the ruling should be revisited, not the test relaxed")
        XCTAssertEqual(lat.printabilityDensityFloor(lineWidthMM: lw, cellMM: atFloor), 0,
                       accuracy: 1e-6)
    }
}

// MARK: - 13. THE LEAD THIS CHANGE DOES **NOT** EXPLAIN

extension LatticeCurvedOutlineBandProbe {

    /// ★★★ HIS ONE REPORT THAT SURVIVES THIS FIX: *the holes survive Grade off.*
    ///
    /// Grade off means `n = 1` everywhere — no ladder, no rungs, nothing for the
    /// 2026-08-28 change to act on. So if a band still reads as holes with grading
    /// off, the density it is drawn at cannot be coming from the ladder. This pins the
    /// only other way that happens: **the REGION'S OWN CELL already needs more density
    /// than the part is drawn at**, so the whole wall sits at the printability floor
    /// before any grading is considered.
    ///
    /// It does not bite on his `M2 verticalStand` (region cells 5.16 / 6.00 mm, floor
    /// 0.0% against a 5% band), which is why the fix worked there. It bites as soon as
    /// the wall is thin enough to derive a small cell.
    func testAThinWallIsAboveTheBandBeforeAnyGradingAtAll() throws {
        let lat = LatticeType.named("octet")
        let lw = 0.45, lo = 0.05
        // His part: the region cell is free — nothing forced.
        for cell in [5.156120181083679, 6.0] {
            XCTAssertEqual(lat.printabilityDensityFloor(lineWidthMM: lw, cellMM: cell), 0,
                           accuracy: 1e-6,
                           "★ his region cells must cost nothing, or the fix of "
                           + "2026-08-28 was measuring the wrong thing")
        }
        // A thinner wall's cell is forced above the band with no grading in sight.
        let thin = 3.0
        let need = lat.printabilityDensityFloor(lineWidthMM: lw, cellMM: thin)
        XCTAssertGreaterThan(need, lo,
            "★ if this stops being true the 'holes survive Grade off' lead is dead "
            + "and should be struck from the handoff rather than left standing")
        print(String(format:
            "LEAD  a %.2f mm region cell is forced to %.1f%% before any grading; "
            + "the band's floor is %.0f%% — %.1fx",
            thin, need * 100, lo * 100, need / lo))
    }
}

// MARK: - 14. IS THE SOLID TERMINUS A RING, OR A DOTTED LINE?

/// ★★★ HIS 2026-08-28 SCREENSHOT: deep-purple, cell-sized lumps scattered along both
/// curved outlines. Solid draws at the deep end of its class (fix #16), so those are
/// solid cells — and the complaint is that they are SCATTERED. His rule is that the
/// grade ends in *"a solid [that] connects the sides"*: a ring, not a dotted line.
///
/// ★ CONFOUND CONTROL: no pixels and no camera. `cf.level` IS the outline channel the
/// shader reads on the stepped path, and `0` there means the bake decided SOLID. This
/// rasterises that decision in the declared face's own (u,v) plane, so "ring or dots"
/// is answered by the bake's own output rather than by looking at a render.
extension LatticeCurvedOutlineBandProbe {

    func testTheSolidTerminusIsARingNotADottedLine() throws {
        var hh = P.His(); hh.boundaryFinishWritten = false
        let i = try P.inputs(hh, faces: LatticeRefusedCellProbe.hisFaces)
        guard let cf = P.bake(i) else { throw XCTSkip("no bake") }
        let inc = i.scene.regions.filter { $0.role == .include }
        let out = ProcessInfo.processInfo.environment["QUILT_OUT"]
            ?? NSTemporaryDirectory() + "quilt"

        /// (painted, solid) at a model point, straight off the baked cell field.
        func cellAt(_ p: SIMD3<Double>) -> (Bool, Bool) {
            let f = cf.field
            let vx = Int((((p.x - Double(f.origin.x)) / Double(f.spacing.x))).rounded())
            let vy = Int((((p.y - Double(f.origin.y)) / Double(f.spacing.y))).rounded())
            let vz = Int((((p.z - Double(f.origin.z)) / Double(f.spacing.z))).rounded())
            guard vx >= 0, vy >= 0, vz >= 0, vx < f.nx, vy < f.ny, vz < f.nz
            else { return (false, false) }
            let idx = vx + f.nx * (vy + f.ny * vz)
            guard idx < cf.steppedCellMM.count, idx < cf.level.count else { return (false, false) }
            let painted = cf.steppedCellMM[idx] > 0
            return (painted, painted && cf.level[idx] == 0)
        }

        let size = 512
        for (ri, r) in inc.enumerated() {
            guard let loop = r.outlineLoops.first, loop.count > 8 else { continue }
            let n = LatticeRegionMask.unit(r.normal)
            let (u, v) = LatticeRegionMask.basis(n)
            var lo = SIMD2<Double>(1e9, 1e9), hi = SIMD2<Double>(-1e9, -1e9)
            for lp in r.outlineLoops { for q in lp { lo = simd_min(lo, q); hi = simd_max(hi, q) } }
            lo -= SIMD2(6, 6); hi += SIMD2(6, 6)
            let span = Swift.max(hi.x - lo.x, hi.y - lo.y)
            var px = [UInt8](repeating: 0, count: size * size * 4)
            for py in 0..<size { for pxi in 0..<size {
                let uu = lo.x + span * (Double(pxi) + 0.5) / Double(size)
                let vv = lo.y + span * (Double(size - 1 - py) + 0.5) / Double(size)
                let p = r.origin + u * uu + v * vv + n * 1.0
                let d = LatticeFaceOutline.signedDistance(SIMD2(uu, vv), loops: r.outlineLoops)
                var c: (UInt8, UInt8, UInt8) = (0, 0, 0)
                if d <= 0 {
                    let (painted, solid) = cellAt(p)
                    c = solid ? (230, 40, 40) : (painted ? (40, 170, 90) : (60, 60, 66))
                }
                let o = 4 * (py * size + pxi)
                px[o] = c.0; px[o + 1] = c.1; px[o + 2] = c.2; px[o + 3] = 255
            } }
            LatticeQuiltFrameProbe.writePNG(px, size: size,
                to: out + "/solid_region\(ri)_face\(r.faceID.map(String.init) ?? "?").png")

            // ★ THE NUMBER: walk the outline and ask, at each vertex, whether the cell
            // just inside it is solid. A RING answers yes everywhere; a dotted line
            // answers yes for a fraction, and that fraction IS the defect.
            var yes = 0, total = 0
            let m = loop.count
            for k in 0..<m {
                let a = loop[(k + m - 1) % m], b = loop[k], c2 = loop[(k + 1) % m]
                let e0 = b - a, e1 = c2 - b
                guard simd_length(e0) > 1e-6, simd_length(e1) > 1e-6 else { continue }
                let t = simd_normalize(e0 / simd_length(e0) + e1 / simd_length(e1))
                var inward = SIMD2<Double>(-t.y, t.x)
                if LatticeFaceOutline.signedDistance(b + inward * 0.5, loops: r.outlineLoops)
                    > LatticeFaceOutline.signedDistance(b - inward * 0.5, loops: r.outlineLoops) {
                    inward = -inward
                }
                // ★ A TENTH OF A MILLIMETRE INSIDE — as close to the outline as the
                // question allows. At 1.0 mm the cell CONTAINING that point can have
                // its own centre up to half a cell further in, so even a perfect ring
                // scores only ~80% and the metric flatters nothing. Sampling at the
                // outline asks about the cell the outline actually cuts.
                let uv = b + inward * 0.1
                let p = r.origin + u * uv.x + v * uv.y + n * 1.0
                let (painted, solid) = cellAt(p)
                guard painted else { continue }
                total += 1
                if solid { yes += 1 }
            }
            let share = total > 0 ? 100.0 * Double(yes) / Double(total) : 0
            print(String(format:
                "region %d face %@  outline pts with a PAINTED cell just inside: %d   "
                + "of which SOLID: %d  (%.0f%%)  <- 100%% is a ring, less is a dotted line",
                ri, String(describing: r.faceID) as NSString, total, yes, share))
            // ★★★ AND IT IS PINNED. `gradedToSolid` went 126 -> 875 on this change and
            // NOT ONE test in the 784-test suite went red — the same gap that let the
            // ladder floor ship unpinned. A print-only probe pins nothing, so this is
            // an assertion: the terminus must be a RING.
            //
            // ★ 80%, NOT 100%, AND WHY. The metric samples the cell containing a point
            // 0.1 mm inside each outline vertex; where the drawn cell is 6.00 mm that
            // cell's own centre can still sit just past the half-cell test, so a
            // perfect ring scores in the high 80s/90s rather than 100. Measured at the
            // shipping rule: face 2 = 96%, face 15 = 84%. The floor is set below the
            // weaker of the two with room for tessellation noise, and it is FAR above
            // the 25% / 32% the centre test produced — which is the regression this
            // guards. If this goes red, the terminus has gone back to a dotted line;
            // re-pin it UP if the rule genuinely improved, never down.
            XCTAssertGreaterThan(share, 75.0,
                "★ the solid terminus is a DOTTED LINE again on face "
                + "\(String(describing: r.faceID)): only \(yes) of \(total) outline "
                + "points have a solid cell just inside. His rule is that the grade "
                + "ends in 'a solid [that] connects the sides' — a ring. The centre "
                + "test scored 25% / 32% here; anything in that range means the exact "
                + "outline distance or the cuts-the-outline gate has been lost.")
        }
        print("maps -> \(out)")
    }
}

// MARK: - 15. IS THE DARK BAND MATERIAL DEEPER THAN THE PRISM?

/// ★★★ HIS 2026-08-28 MARK-UP: a dark grey empty strip just inside the chamfer along
/// the CURVED left edge, with fine lattice cells right beside it.
///
/// The bake's in-plane coverage is now a continuous ring (probe 14: 96% / 84%), so
/// the strip is not a gap in the outline's own plane. The other axis is DEPTH: his
/// prism is 11 mm (face 15) and 12 mm (face 2), and the wall is only a ~10 mm skin
/// where face 16 backs it — which it does NOT near the outer edges. This measures the
/// material's actual thickness along the face normal at points just inside the
/// outline, against the prism that is supposed to lattice it.
///
/// ★ CONFOUND CONTROL: `partSDF` is the distance to the PART, baked from the mesh and
/// never clipped to a region, so "how thick is the wall here" is answered by geometry
/// alone — no bake, no shell, no camera, no far wall.
extension LatticeCurvedOutlineBandProbe {

    func testHowDeepTheMaterialIsWhereHeMarkedTheDarkBand() throws {
        var hh = P.His(); hh.boundaryFinishWritten = false
        let i = try P.inputs(hh, faces: LatticeRefusedCellProbe.hisFaces)
        let inc = i.scene.regions.filter { $0.role == .include }
        let psdf = i.scene.partSDF
        func inside(_ p: SIMD3<Double>) -> Bool { Self.sampleLinear(psdf, p) <= 0 }

        for (ri, r) in inc.enumerated() {
            guard let loop = r.outlineLoops.first, loop.count > 8 else { continue }
            let n = LatticeRegionMask.unit(r.normal)      // points INTO the part
            let (u, v) = LatticeRegionMask.basis(n)
            var deeper = 0, total = 0
            var depths: [Double] = []
            let m = loop.count
            for k in 0..<m {
                let b = loop[k]
                // ★ STEP 2 mm INSIDE THE OUTLINE FIRST. An outline vertex sits exactly
                // ON the boundary, where the part test is a coin flip — walking the
                // normal from there measures nothing, which is what the first version
                // of this probe did (it printed no rows at all).
                let a0 = loop[(k + m - 1) % m], c0 = loop[(k + 1) % m]
                let e0 = b - a0, e1 = c0 - b
                guard simd_length(e0) > 1e-6, simd_length(e1) > 1e-6 else { continue }
                let tg = simd_normalize(e0 / simd_length(e0) + e1 / simd_length(e1))
                var inward2 = SIMD2<Double>(-tg.y, tg.x)
                if LatticeFaceOutline.signedDistance(b + inward2 * 0.5, loops: r.outlineLoops)
                    > LatticeFaceOutline.signedDistance(b - inward2 * 0.5, loops: r.outlineLoops) {
                    inward2 = -inward2
                }
                let uvIn = b + inward2 * 2.0
                var best = 0.0
                var t = 0.0
                while t <= 60.0 {
                    let p = r.origin + u * uvIn.x + v * uvIn.y + n * t
                    if !inside(p) { break }
                    best = t; t += 0.25
                }
                guard best > 0.5 else { continue }
                total += 1
                depths.append(best)
                if best > r.depthMM + 0.5 { deeper += 1 }
            }
            guard total > 0 else { continue }
            let s = depths.sorted()
            func q(_ f: Double) -> Double { s[Swift.min(s.count - 1, Int(f * Double(s.count - 1)))] }
            print(String(format:
                "region %d face %@  prism depth %.1f mm | material depth at the outline: "
                + "p10 %.1f  p50 %.1f  p90 %.1f  max %.1f mm | DEEPER than the prism at "
                + "%d of %d outline points (%.0f%%)",
                ri, String(describing: r.faceID) as NSString, r.depthMM,
                q(0.1), q(0.5), q(0.9), q(1.0), deeper, total,
                100.0 * Double(deeper) / Double(total)))
        }
    }
}

// MARK: - 16. THE PERMUTATION SWEEP

/// ★★★ EVERY SETTING PERMUTATION THE BAKE CAN EXPRESS, CLASSIFIED — his standing bar
/// is "no holes and no quilt across EVERY setting permutation", and until now only
/// one permutation had been checked.
///
/// ★ CONFOUND CONTROL: no pixels, no camera, no far wall. Each permutation is baked
/// and then its DECLARED FACES are classified in their own (u,v) plane at 1 mm depth,
/// which is the same measurement `testDrawTheWallFaceOn` makes and the same one that
/// showed 92-96% drawn on his shipping settings. "Empty" here means a specific,
/// checkable thing: a point inside the outline with material behind it where the bake
/// painted NO cell (`unpainted`) or the march's own clip would cut it (`clipped`).
///
/// ★ WHAT THIS CANNOT SEE. The march's strut geometry — a painted, unclipped cell can
/// still draw no strut (that was fix #10). So a clean row here is necessary, not
/// sufficient, and the rows that look worst are the ones to take to the simulator.
extension LatticeCurvedOutlineBandProbe {

    struct SweepRow {
        var label = ""
        var painted = 0
        var sizes = ""
        var drawn = 0.0, clipped = 0.0, unpainted = 0.0, notOwned = 0.0, noMat = 0.0
        var ring = 0.0
        var solidPct = 0.0
        var solidCells = 0
    }

    /// Classify one bake over both declared faces, area-weighted by (u,v) pixels.
    static func classify(_ i: Inputs2, _ cf: LatticeCellField, depth: Double = 1.0) -> SweepRow {
        var r = SweepRow()
        let inc = i.scene.regions.filter { $0.role == .include }
        guard let rg = i.scene.regionSDF else { return r }
        let occ = i.scene.occupancy
        func cell(_ p: SIMD3<Double>) -> (painted: Bool, solid: Bool) {
            let f = cf.field
            let vx = Int((((p.x - Double(f.origin.x)) / Double(f.spacing.x))).rounded())
            let vy = Int((((p.y - Double(f.origin.y)) / Double(f.spacing.y))).rounded())
            let vz = Int((((p.z - Double(f.origin.z)) / Double(f.spacing.z))).rounded())
            guard vx >= 0, vy >= 0, vz >= 0, vx < f.nx, vy < f.ny, vz < f.nz else { return (false, false) }
            let k = vx + f.nx * (vy + f.ny * vz)
            guard k < cf.steppedCellMM.count, k < cf.level.count else { return (false, false) }
            let pa = cf.steppedCellMM[k] > 0
            return (pa, pa && cf.level[k] == 0)
        }
        func occAt(_ p: SIMD3<Double>) -> Float {
            let vx = Int((((p.x - Double(occ.origin.x)) / Double(occ.spacing.x))).rounded())
            let vy = Int((((p.y - Double(occ.origin.y)) / Double(occ.spacing.y))).rounded())
            let vz = Int((((p.z - Double(occ.origin.z)) / Double(occ.spacing.z))).rounded())
            guard vx >= 0, vy >= 0, vz >= 0, vx < occ.nx, vy < occ.ny, vz < occ.nz else { return -9 }
            return occ.values[vx + occ.nx * (vy + occ.ny * vz)]
        }
        var tally: [String: Int] = [:]
        var ringYes = 0, ringTot = 0
        let size = 260
        for reg in inc {
            guard !reg.outlineLoops.isEmpty else { continue }
            let n = LatticeRegionMask.unit(reg.normal)
            let (u, v) = LatticeRegionMask.basis(n)
            var lo = SIMD2<Double>(1e9, 1e9), hi = SIMD2<Double>(-1e9, -1e9)
            for lp in reg.outlineLoops { for q in lp { lo = simd_min(lo, q); hi = simd_max(hi, q) } }
            lo -= SIMD2(4, 4); hi += SIMD2(4, 4)
            let span = Swift.max(hi.x - lo.x, hi.y - lo.y)
            for py in 0..<size { for px in 0..<size {
                let uu = lo.x + span * (Double(px) + 0.5) / Double(size)
                let vv = lo.y + span * (Double(size - 1 - py) + 0.5) / Double(size)
                guard LatticeFaceOutline.signedDistance(SIMD2(uu, vv),
                                                        loops: reg.outlineLoops) <= 0 else { continue }
                let p = reg.origin + u * uu + v * vv + n * depth
                if occAt(p) <= 0.5 { tally["noMat", default: 0] += 1; continue }
                if !inc.contains(where: { LatticeRegionMask.contains(p, region: $0) }) {
                    tally["notOwned", default: 0] += 1; continue
                }
                let c = cell(p)
                // ★★★ SOLID IS TESTED BEFORE CLIPPED, and getting that order wrong is
                // what made this metric report a 2.7% "hole" at single-cell ON that
                // does not exist. The solid ring is material the run DELIVERS; its
                // cells sit at the outline where the region field is naturally >= 0,
                // so testing `sampleLinear > 0` first counted every solid cell as a
                // clipped one. The face-on map, which checks solid first, showed 112
                // red pixels on face 2 (0.17%) against the 2.7% this printed.
                if !c.painted { tally["unpainted", default: 0] += 1 }
                else if c.solid { tally["solid", default: 0] += 1 }
                else if Self.sampleLinear(rg, p) > 0 { tally["clipped", default: 0] += 1 }
                else { tally["drawn", default: 0] += 1 }
            } }
            // ring continuity, 0.1 mm inside each outline vertex
            let loop = reg.outlineLoops[0]; let m = loop.count
            for k in 0..<m {
                let a = loop[(k + m - 1) % m], b = loop[k], c2 = loop[(k + 1) % m]
                let e0 = b - a, e1 = c2 - b
                guard simd_length(e0) > 1e-6, simd_length(e1) > 1e-6 else { continue }
                let tg = simd_normalize(e0 / simd_length(e0) + e1 / simd_length(e1))
                var iw = SIMD2<Double>(-tg.y, tg.x)
                if LatticeFaceOutline.signedDistance(b + iw * 0.5, loops: reg.outlineLoops)
                    > LatticeFaceOutline.signedDistance(b - iw * 0.5, loops: reg.outlineLoops) { iw = -iw }
                let p = reg.origin + u * (b + iw * 0.1).x + v * (b + iw * 0.1).y + n * depth
                let c = cell(p)
                guard c.painted else { continue }
                ringTot += 1; if c.solid { ringYes += 1 }
            }
        }
        let tot = Swift.max(1, tally.values.reduce(0, +))
        func pc(_ k: String) -> Double { 100.0 * Double(tally[k] ?? 0) / Double(tot) }
        r.drawn = pc("drawn"); r.clipped = pc("clipped"); r.unpainted = pc("unpainted")
        r.notOwned = pc("notOwned"); r.noMat = pc("noMat"); r.solidPct = pc("solid")
        r.ring = ringTot > 0 ? 100.0 * Double(ringYes) / Double(ringTot) : 0
        r.painted = cf.steppedCellMM.filter { $0 > 0 }.count
        r.solidCells = cf.level.enumerated().filter {
            $0.offset < cf.steppedCellMM.count && cf.steppedCellMM[$0.offset] > 0 && $0.element == 0
        }.count
        var h: [String: Int] = [:]
        for v2 in cf.steppedCellMM where v2 > 0 { h[String(format: "%.2f", v2), default: 0] += 1 }
        r.sizes = h.keys.sorted { (Double($0) ?? 0) < (Double($1) ?? 0) }
            .map { "\($0)=\(h[$0]!)" }.joined(separator: " ")
        return r
    }

    typealias Inputs2 = LatticeQuiltBakeProbe.Inputs

    /// ★ IS THE "EMPTY" AT SINGLE-CELL ON A HOLE, OR IS IT THE SKIN?
    ///
    /// single-cell ON also auto-sets the SKIN finish (his own vocabulary table), and
    /// the region field is `max(region, partSDF + skinMM)` — so the clip legitimately
    /// cuts everything within `skinMM` of the surface. Sampling at 1 mm with a 0.9 mm
    /// skin sits right on that edge, and would report the skin as a hole. A hole does
    /// not care how deep you look; a skin disappears as soon as you look past it.
    func testIsTheSingleCellEmptinessTheSkinOrAHole() throws {
        for (label, single, skin, dyadic) in [
            ("single OFF · Stepped   (skin 0.0)", false, 0.0, false),
            ("single ON  · Stepped   (skin 0.9)", true,  0.9, false),
            ("single ON  · DYADIC    (skin 0.9)", true,  0.9, true),
            ("single OFF · COVERED   (skin 1.8)", false, 1.8, false),
        ] {
            var h = LatticeQuiltBakeProbe.His()
            h.boundaryFinishWritten = single
            h.skinMM = skin
            h.dyadicSteps = dyadic
            guard let i = try? LatticeQuiltBakeProbe.inputs(h, faces: LatticeRefusedCellProbe.hisFaces),
                  let cf = LatticeQuiltBakeProbe.bake(i) else { continue }
            var line = "  \(label): clipped at depth"
            for d in [1.0, 1.5, 2.0, 3.0, 4.0] {
                let r = Self.classify(i, cf, depth: d)
                line += String(format: "  %.1fmm=%.1f%%", d, r.clipped)
            }
            print(line)
        }
        print("  ★ a SKIN falls away with depth; a HOLE does not.")

        // ★ AND WHERE IS IT? Draw the single-cell-ON face at 3 mm — past the 0.9 mm
        // skin, so anything still red is a hole and not the finish.
        var h = LatticeQuiltBakeProbe.His()
        h.boundaryFinishWritten = true; h.skinMM = 0.9
        guard let i = try? LatticeQuiltBakeProbe.inputs(h, faces: LatticeRefusedCellProbe.hisFaces),
              let cf = LatticeQuiltBakeProbe.bake(i), let rg = i.scene.regionSDF else { return }
        let out = ProcessInfo.processInfo.environment["QUILT_OUT"] ?? NSTemporaryDirectory() + "quilt"
        let inc = i.scene.regions.filter { $0.role == .include }
        let occ = i.scene.occupancy
        let size = 512
        for (ri, reg) in inc.enumerated() {
            guard !reg.outlineLoops.isEmpty else { continue }
            let n = LatticeRegionMask.unit(reg.normal)
            let (u, v) = LatticeRegionMask.basis(n)
            var lo = SIMD2<Double>(1e9, 1e9), hi = SIMD2<Double>(-1e9, -1e9)
            for lp in reg.outlineLoops { for q in lp { lo = simd_min(lo, q); hi = simd_max(hi, q) } }
            lo -= SIMD2(4, 4); hi += SIMD2(4, 4)
            let span = Swift.max(hi.x - lo.x, hi.y - lo.y)
            var px = [UInt8](repeating: 0, count: size * size * 4)
            for py in 0..<size { for pxi in 0..<size {
                let uu = lo.x + span * (Double(pxi) + 0.5) / Double(size)
                let vv = lo.y + span * (Double(size - 1 - py) + 0.5) / Double(size)
                var c: (UInt8, UInt8, UInt8) = (0, 0, 0)
                if LatticeFaceOutline.signedDistance(SIMD2(uu, vv), loops: reg.outlineLoops) <= 0 {
                    let p = reg.origin + u * uu + v * vv + n * 3.0
                    let vx = Int((((p.x - Double(occ.origin.x)) / Double(occ.spacing.x))).rounded())
                    let vy = Int((((p.y - Double(occ.origin.y)) / Double(occ.spacing.y))).rounded())
                    let vz = Int((((p.z - Double(occ.origin.z)) / Double(occ.spacing.z))).rounded())
                    let ok = vx >= 0 && vy >= 0 && vz >= 0 && vx < occ.nx && vy < occ.ny && vz < occ.nz
                    let o = ok ? occ.values[vx + occ.nx * (vy + occ.ny * vz)] : -9
                    if o <= 0.5 { c = (60, 60, 66) }
                    else {
                        let f = cf.field
                        let bx = Int((((p.x - Double(f.origin.x)) / Double(f.spacing.x))).rounded())
                        let by = Int((((p.y - Double(f.origin.y)) / Double(f.spacing.y))).rounded())
                        let bz = Int((((p.z - Double(f.origin.z)) / Double(f.spacing.z))).rounded())
                        let ok2 = bx >= 0 && by >= 0 && bz >= 0 && bx < f.nx && by < f.ny && bz < f.nz
                        let k = ok2 ? bx + f.nx * (by + f.ny * bz) : -1
                        let painted = k >= 0 && k < cf.steppedCellMM.count && cf.steppedCellMM[k] > 0
                        let solid = painted && k < cf.level.count && cf.level[k] == 0
                        if !painted { c = (240, 150, 30) }
                        else if solid { c = (150, 60, 200) }
                        else if Self.sampleLinear(rg, p) > 0 { c = (230, 40, 40) }
                        else { c = (40, 170, 90) }
                    }
                }
                let o2 = 4 * (py * size + pxi)
                px[o2] = c.0; px[o2 + 1] = c.1; px[o2 + 2] = c.2; px[o2 + 3] = 255
            } }
            LatticeQuiltFrameProbe.writePNG(px, size: size,
                to: out + "/singleON_face\(reg.faceID.map(String.init) ?? "?")_d3.png")
            _ = ri
        }
        print("  maps -> \(out)  (red = CLIPPED at 3 mm = the hole)")
    }

    func testSweepEverySettingPermutation() throws {
        var rows: [SweepRow] = []
        // (label, singleCell, shapeFit, dyadic, skinMM, rhoLo, rhoHi)
        let perms: [(String, Bool, Bool, Bool, Double, Double, Double)] = [
            ("single OFF · Stepped · grade on  · None",    false, true,  false, 0.0, 0.05, 0.90),
            ("single ON  · Stepped · grade on  · Skin",    true,  true,  false, 0.9, 0.05, 0.90),
            ("single OFF · Stepped · GRADE OFF · None",    false, false, false, 0.0, 0.05, 0.90),
            ("single ON  · Stepped · GRADE OFF · Skin",    true,  false, false, 0.9, 0.05, 0.90),
            ("single OFF · DYADIC  · grade on  · None",    false, true,  true,  0.0, 0.05, 0.90),
            ("single ON  · DYADIC  · grade on  · Skin",    true,  true,  true,  0.9, 0.05, 0.90),
            ("single OFF · Stepped · grade on  · Covered", false, true,  false, 1.8, 0.05, 0.90),
            ("single OFF · Stepped · grade on  · UNIFORM", false, true,  false, 0.0, 0.20, 0.20),
            ("single OFF · Stepped · grade on  · dense",   false, true,  false, 0.0, 0.30, 0.90),
        ]
        for (label, single, fit, dyadic, skin, lo, hi) in perms {
            var h = LatticeQuiltBakeProbe.His()
            h.boundaryFinishWritten = single
            h.shapeFit = fit
            h.dyadicSteps = dyadic
            h.skinMM = skin
            h.rhoMin = lo; h.rhoMax = hi
            guard let i = try? LatticeQuiltBakeProbe.inputs(h, faces: LatticeRefusedCellProbe.hisFaces),
                  let cf = LatticeQuiltBakeProbe.bake(i) else {
                print("SKIP \(label)"); continue
            }
            var r = Self.classify(i, cf)
            r.label = label
            rows.append(r)
        }
        print("")
        print("PERMUTATION SWEEP — % of the declared faces at 1 mm depth")
        print(String(repeating: "-", count: 118))
        print("  setting                                    drawn  SOLID  clipped unpaint notOwn  ring  painted")
        for r in rows {
            print(String(format: "  %-42@ %5.1f%% %5.1f%% %6.1f%% %6.1f%% %6.1f%% %5.0f%% %7d",
                         r.label as NSString, r.drawn, r.solidPct, r.clipped, r.unpainted,
                         r.notOwned, r.ring, r.painted))
        }
        print("")
        for r in rows { print("  \(r.label)\n      sizes: \(r.sizes)") }

        // ★★★ AND EVERY ROW IS PINNED. Two behaviour changes in a row (the ladder
        // floor, then the solid ring) moved thousands of cells and turned NOTHING red
        // in a ~790-test suite. His bar is "no holes across EVERY setting permutation",
        // so the sweep asserts rather than prints.
        //
        // ★ COVERED IS EXEMPT FROM THE CLIPPED BOUND, AND ONLY THAT ONE. Its finish is
        // a 1.8 mm solid skin and this samples at 1 mm, so it legitimately reads as
        // clipped there — `testIsTheSingleCellEmptinessTheSkinOrAHole` shows it
        // collapsing 83.0% -> 0.3% between 1.5 and 2.0 mm, which is the skin's own
        // depth. Its ring and unpainted bounds still apply.
        for r in rows {
            XCTAssertEqual(r.unpainted, 0.0, accuracy: 0.05,
                "★ \(r.label): the bake left OWNED material with no cell — a hole the "
                + "march cannot fill. This must stay exactly zero.")
            XCTAssertEqual(r.notOwned, 0.0, accuracy: 0.05,
                "★ \(r.label): material inside the outline that no region owns.")
            XCTAssertGreaterThan(r.ring, 75.0,
                "★ \(r.label): the solid terminus is a DOTTED LINE (\(r.ring)%). "
                + "Default Grade + single-cell ON scored 57% before the ring was sized "
                + "by the BASE cell instead of the drawn sub-cell; if this is red again "
                + "that granularity has been lost.")
            if !r.label.contains("Covered") {
                XCTAssertLessThan(r.clipped, 0.5,
                    "★ \(r.label): \(r.clipped)% of the declared face is painted but "
                    + "clipped away — empty space on screen. Every permutation measured "
                    + "0.1% once the ring was sized by the base cell; Default Grade with "
                    + "single-cell ON was 2.3% before that.")
            }
        }
    }
}
