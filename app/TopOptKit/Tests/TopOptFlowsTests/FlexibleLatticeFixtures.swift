// FlexibleLatticeFixtures — the synthetic scenes the Flexible lattice tests share (task
// 2026-09-29-flexible-screens, in-pass round). Ported from the retired
// FlexibleLatticeRendererTests / FlexibleLatticeRendererCoverageTests, plus the BOX MESH
// the in-pass tests need now that the lattice is drawn inside MeshRenderer's frame.
#if canImport(Metal) && canImport(MetalKit)
import XCTest
import Metal
import simd
@testable import TopOptFlows

enum FlexibleLatticeFixtures {

    /// The synthetic 40 × 40 × 20 mm box: an exact box SDF, the whole box latticed, ρ
    /// linear 0.15 → 0.35 along X, no skin anywhere (skinDist large).
    static func boxInputs(_ topology: FlexibleLatticeInputs.Topology) -> FlexibleLatticeInputs {
        let lo = SIMD3<Float>(0, 0, 0), hi = SIMD3<Float>(40, 40, 20)
        let centre = (lo + hi) * 0.5, half = (hi - lo) * 0.5
        // the part's SDF: 0.5 mm voxels over the box padded 3 mm
        let sp: Float = 0.5
        let c0 = lo - SIMD3<Float>(repeating: 3)
        let n = SIMD3<Int>(Int(((hi.x - lo.x + 6) / sp).rounded()) + 1,
                           Int(((hi.y - lo.y + 6) / sp).rounded()) + 1,
                           Int(((hi.z - lo.z + 6) / sp).rounded()) + 1)
        var sdf = [Float](repeating: 0, count: n.x * n.y * n.z)
        for k in 0..<n.z { for j in 0..<n.y { for i in 0..<n.x {
            let p = c0 + SIMD3<Float>(Float(i), Float(j), Float(k)) * sp
            let q = abs(p - centre) - half
            let outside = simd_length(simd_max(q, .zero))
            let inside = Swift.min(Swift.max(q.x, Swift.max(q.y, q.z)), 0)
            sdf[(k * n.y + j) * n.x + i] = outside + inside
        } } }
        // the density grid (core's): 2 mm voxels, one voxel of margin
        let rs: Float = 2
        let r0 = lo - SIMD3<Float>(repeating: 1)
        let rn = SIMD3<Int>(22, 22, 12)
        var rho = [Float](repeating: 0, count: rn.x * rn.y * rn.z)
        for k in 0..<rn.z { for j in 0..<rn.y { for i in 0..<rn.x {
            let x = r0.x + Float(i) * rs
            rho[(k * rn.y + j) * rn.x + i] = 0.15 + 0.2 * Swift.min(Swift.max(x / 40, 0), 1)
        } } }
        let t: Float = 0.8
        func grid(_ v: [Float]) -> FlexGrid { FlexGrid(nx: rn.x, ny: rn.y, nz: rn.z, c0: r0, spacing: rs, values: v) }
        return FlexibleLatticeInputs(
            topology: topology, wallMM: t, lMinMM: 3.0915 * t / 0.9, lMaxMM: 3.0915 * t / 0.05,
            honeycombCellMM: 2 * t / 0.25, buildDir: SIMD3(0, 0, 1), skinMM: FlexibleLatticeField.defaultSkinMM,
            rho: grid(rho), mask: grid([Float](repeating: 1, count: rho.count)),
            partSDF: FlexGrid(nx: n.x, ny: n.y, nz: n.z, c0: c0, spacing: sp, values: sdf),
            skinDist: grid([Float](repeating: 100, count: rho.count)),
            boundsMin: lo, boundsMax: hi)
    }

    /// The box with the lattice region cut at x = 30 and a real skin: skinDist = distance
    /// to the box surface on the density grid (ported from the coverage tests).
    static func regionAndSkinBox(_ topo: FlexibleLatticeInputs.Topology, skinMM: Float = 2) -> FlexibleLatticeInputs {
        var f = boxInputs(topo)
        let g = f.mask
        var mask = g.values, skin = g.values
        let lo = SIMD3<Float>(0, 0, 0), hi = SIMD3<Float>(40, 40, 20)
        let centre = (lo + hi) * 0.5, half = (hi - lo) * 0.5
        for k in 0..<g.nz { for j in 0..<g.ny { for i in 0..<g.nx {
            let p = g.c0 + SIMD3<Float>(Float(i), Float(j), Float(k)) * g.spacing
            let q = abs(p - centre) - half
            let d = simd_length(simd_max(q, .zero)) + Swift.min(Swift.max(q.x, Swift.max(q.y, q.z)), 0)
            let n = (k * g.ny + j) * g.nx + i
            mask[n] = p.x > 30 ? 0 : 1
            skin[n] = abs(d)
        } } }
        f.mask.values = mask
        f.skinDist.values = skin
        f.skinMM = skinMM
        return f
    }

    /// The box with a real skin only (the whole box latticed): the walls stop `skinMM`
    /// under every face, so the box mesh's top face is strictly in front of them.
    static func skinnedBox(_ topo: FlexibleLatticeInputs.Topology, skinMM: Float = 1.5) -> FlexibleLatticeInputs {
        var f = regionAndSkinBox(topo, skinMM: skinMM)
        f.mask.values = [Float](repeating: 1, count: f.mask.values.count)
        return f
    }

    /// The top face (z = 20) loaded straight down: 20 × 20 columns of 2 mm, each running
    /// the full 20 mm height, pressed `depth` mm at full scale.
    static func topFace(depth: Float) -> FlexibleSquishFace {
        let nu = 20, nv = 20
        var cells: [SIMD4<Float>] = []
        for _ in 0..<(nu * nv) { cells.append(SIMD4(depth, 0, 20, 1)) }
        return FlexibleSquishFace(centroid: SIMD3(20, 20, 20), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0),
                                  load: SIMD3(0, 0, -1), uMin: -20, vMin: -20, pitchMM: 2,
                                  nu: nu, nv: nv, cells: cells)
    }

    /// The same face pressed as a checkerboard, 0.5 / 4 mm (the column walls' worst case).
    static func checkerFace() -> FlexibleSquishFace {
        var cells: [SIMD4<Float>] = []
        for iv in 0..<20 { for iu in 0..<20 { cells.append(SIMD4((iu + iv) % 2 == 0 ? 0.5 : 4, 0, 20, 1)) } }
        return FlexibleSquishFace(centroid: SIMD3(20, 20, 20), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0),
                                  load: SIMD3(0, 0, -1), uMin: -20, vMin: -20, pitchMM: 2,
                                  nu: 20, nv: 20, cells: cells)
    }

    /// Deterministic points spread over the box padded 1 mm (an LCG, so a failure reproduces).
    static func probePoints(_ count: Int, seed: UInt64 = 0x9E3779B97F4A7C15) -> [SIMD3<Float>] {
        var s: UInt64 = seed
        func next() -> Float {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Float(s >> 40) / Float(1 << 24)
        }
        return (0..<count).map { _ in SIMD3(-1 + 42 * next(), -1 + 42 * next(), -1 + 22 * next()) }
    }

    /// The layer inputs the page would hand MeshRenderer.
    static func layer(_ f: FlexibleLatticeInputs, faces: [FlexibleSquishFace] = [], token: Int,
                      hidden: Bool = false) -> FlexibleLatticeLayerInputs {
        FlexibleLatticeLayerInputs(lattice: f, faces: faces, token: token, hidden: hidden)
    }

    // MARK: the box MESH (the in-pass tests draw the lattice inside MeshRenderer's frame)

    /// The TOP face's triangle range in `boxMesh`'s flat order: it is built LAST, as the
    /// page's dented map is (FlexibleOverlayMesh appends its column quads after the part),
    /// so the opaque map is the last thing the body draw lays down.
    struct BoxMesh {
        let mesh: ViewerMesh
        /// Flat vertices of the top face: `topStart ..< flatCount`.
        let topStart: Int
        var flatCount: Int { mesh.flat.vertexCount }
    }

    /// The 40 × 40 × 20 box, inflated by `pad` mm on every side (so the lattice's walls,
    /// which reach the box's own faces, are strictly INSIDE the shell and a depth test
    /// between the two is never a tie), each face an n × n grid, the top face last.
    /// `omit`: face ids left out (an open box — T7b removes the far side).
    static func boxMesh(pad: Float = 0.25, subdiv: Int = 4, omit: Set<Int32> = []) -> BoxMesh {
        let lo = SIMD3<Float>(-pad, -pad, -pad), hi = SIMD3<Float>(40 + pad, 40 + pad, 20 + pad)
        let X = SIMD3<Float>(hi.x - lo.x, 0, 0), Y = SIMD3<Float>(0, hi.y - lo.y, 0), Z = SIMD3<Float>(0, 0, hi.z - lo.z)
        var pos: [Float] = [], idx: [Int32] = [], fid: [Int32] = []
        let n = max(1, subdiv)
        func face(_ o: SIMD3<Float>, _ u: SIMD3<Float>, _ v: SIMD3<Float>, id: Int32) {
            guard !omit.contains(id) else { return }
            let base = Int32(pos.count / 3)
            for j in 0...n { for i in 0...n {
                let p = o + u * (Float(i) / Float(n)) + v * (Float(j) / Float(n))
                pos += [p.x, p.y, p.z]
            } }
            let row = Int32(n + 1)
            for j in 0..<Int32(n) { for i in 0..<Int32(n) {
                let a = base + j * row + i
                idx += [a, a + 1, a + row + 1, a, a + row + 1, a + row]
                fid += [id, id]
            } }
        }
        // the windings LatticeWizardSample.box uses (the shipping sample's cube)
        face(lo, X, Y, id: 0)                 // bottom
        face(lo, Y, Z, id: 2)                 // x = lo
        face(lo + X, Z, Y, id: 3)             // x = hi
        face(lo, Z, X, id: 4)                 // y = lo
        face(lo + Y, X, Z, id: 5)             // y = hi
        let trisBeforeTop = idx.count / 3
        face(lo + Z, Y, X, id: 1)             // top, LAST
        let mesh = ViewerMesh(vertices: pos, indices: idx, faceIDs: fid)
        return BoxMesh(mesh: mesh, topStart: trisBeforeTop * 3)
    }

    /// The page's X-ray tints on the box: every vertex a ghost (flags.z) in `ghost`, and
    /// the top face — when `dent` is set — the opaque map (flags.y) in that colour.
    static func xrayTints(_ box: BoxMesh, ghost: SIMD4<Float>?, dent: SIMD4<Float>?) -> [Float] {
        var out = [Float](repeating: 0, count: box.flatCount * 8)
        if let dent {
            for v in box.topStart..<box.flatCount {
                out[v * 8] = dent.x; out[v * 8 + 1] = dent.y; out[v * 8 + 2] = dent.z; out[v * 8 + 3] = dent.w
                out[v * 8 + 5] = 1
            }
        }
        if let ghost { FlexibleOverlayMesh.markGhost(&out, colour: ghost) }
        return out
    }

    /// A renderer showing the box mesh, camera oblique from above (the page's framing).
    @MainActor
    static func renderer(device: MTLDevice, sampleCount: Int = 1, box: BoxMesh = boxMesh(),
                         azimuth: Float = 0.65, elevation: Float = 0.6) throws -> MeshRenderer {
        guard let r = MeshRenderer(device: device, sampleCount: sampleCount) else {
            throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
        }
        // ★ the pass shades through #354's lsdf_shade: a dead octet library is RED, not a skip
        XCTAssertTrue(r.latticePipelinesDidBuild, "the unified lattice pipelines did not build")
        r.setMesh(box.mesh)
        r.camera.setOrientation(azimuth: azimuth, elevation: elevation)
        return r
    }

    static func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device (headless) — the Flexible pass is device QA here")
        }
        return d
    }

    /// Pixels (BGRA8 frames) that differ in any channel, restricted to `where`.
    static func differing(_ a: [UInt8], _ b: [UInt8], where keep: (Int) -> Bool = { _ in true }) -> (differ: Int, of: Int) {
        precondition(a.count == b.count)
        var n = 0, total = 0
        for p in 0..<(a.count / 4) where keep(p) {
            total += 1
            let i = p * 4
            if a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] || a[i + 3] != b[i + 3] { n += 1 }
        }
        return (n, total)
    }

    static func mismatch(_ a: [Bool], _ b: [Bool]) -> Int {
        precondition(a.count == b.count)
        var n = 0
        for i in a.indices where a[i] != b[i] { n += 1 }
        return n
    }
}
#endif
