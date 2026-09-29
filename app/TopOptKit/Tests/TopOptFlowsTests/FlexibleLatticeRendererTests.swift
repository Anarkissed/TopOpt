// FlexibleLatticeRendererTests — the Flexible lattice's Metal raymarcher against its Swift
// reference (task 2026-09-29-flexible-screens: the preview is the SOURCE OF TRUTH until
// core's C2 exists, so the GPU copy of `FlexibleLatticeField.lattice` has to agree with the
// Swift one, point for point).
//
// ★ EVERY CHECK HERE HAS A CONTROL THAT GOES RED. A probe that returned zeros, or a render
// that returned the same bytes whatever it was given, would pass an equality test against
// itself; so each comparison is paired with one that must DIFFER (gyroid vs honeycomb, the
// reference of the wrong topology, s = 1 vs s = 0).
//
// GPU-gated: skips when no Metal device exists (headless CI). On a machine WITH a device a
// shader that fails to compile is a FAILURE, not a skip — `FlexibleLatticeRenderer.init`
// throws the compiler log and the test rethrows it.

#if canImport(Metal) && canImport(MetalKit)
import XCTest
import Metal
import simd
import CoreGraphics
import ImageIO
@testable import TopOptFlows

final class FlexibleLatticeRendererTests: XCTestCase {

    // MARK: fixtures

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

    /// An oblique camera framing the box (the orbit camera the stage uses).
    static func obliqueProjection(size: Int) -> CameraProjection {
        var cam = OrbitCamera()
        cam.frame(MeshBounds(min: SIMD3(0, 0, 0), max: SIMD3(40, 40, 20), isEmpty: false))
        cam.setOrientation(azimuth: 0.65, elevation: 0.6)
        return CameraProjection(camera: cam, viewportSize: CGSize(width: size, height: size))
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

    /// Deterministic points spread over the box padded 1 mm (an LCG, so a failure reproduces).
    static func probePoints(_ count: Int) -> [SIMD3<Float>] {
        var s: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Float {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Float(s >> 40) / Float(1 << 24)
        }
        return (0..<count).map { _ in SIMD3(-1 + 42 * next(), -1 + 42 * next(), -1 + 22 * next()) }
    }

    func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device (headless) — the Flexible raymarcher is device QA here")
        }
        return d
    }

    func covered(_ px: [UInt8]) -> Int { FlexibleLatticeRenderer.coveredPixelCount(rgba: px) }

    func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
        precondition(a.count == b.count)
        var n = 0
        for i in stride(from: 0, to: a.count, by: 4)
        where a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] || a[i + 3] != b[i + 3] { n += 1 }
        return n
    }

    // MARK: (a) the MSL compiles; both pipelines build

    func testShaderCompilesAndBothPipelinesBuild() throws {
        let device = try device()
        // ★ a throw here is a FAILURE: the source is broken on a device that exists.
        let r = try FlexibleLatticeRenderer(device: device)
        let lib = try device.makeLibrary(source: FlexibleLatticeShader.source, options: nil)
        for name in ["flx_vertex", "flx_fragment", "flx_field_probe", "flx_squish_probe", "flx_uniform_echo"] {
            XCTAssertNotNil(lib.makeFunction(name: name), "\(name) missing from the MSL")
        }
        XCTAssertEqual(r.renderPipeline.label, "flx_render")
        XCTAssertEqual(r.probePipeline.label, "flx_field_probe")
    }

    /// ★ The uniform struct matches its MSL twin by BYTE OFFSET, never by name — so the GPU
    /// echoes every field BY NAME and each is compared with the Swift field of that name.
    /// A field added or reordered on one side alone fails here instead of drawing nonsense.
    func testUniformLayoutMatchesTheMSLStructFieldByField() throws {
        let r = try FlexibleLatticeRenderer(device: try device())
        var u = FlexibleLatticeRenderer.Uniforms()
        var k: Float = 1
        func v() -> SIMD4<Float> { defer { k += 4 }; return SIMD4(k, k + 1, k + 2, k + 3) }
        u.nearO = v(); u.nearX = v(); u.nearY = v(); u.farO = v(); u.farX = v(); u.farY = v()
        u.viewport = v(); u.boxMin = v(); u.boxMax = v(); u.shape = v(); u.shape2 = v(); u.buildDir = v()
        u.rhoO = v(); u.rhoN = v(); u.maskO = v(); u.maskN = v(); u.sdfO = v(); u.sdfN = v()
        u.skinO = v(); u.skinN = v(); u.keyLight = v(); u.fillLight = v(); u.albedo = v(); u.squish = v()
        u.march = v()
        func face() -> FlexibleLatticeRenderer.FaceUniforms {
            FlexibleLatticeRenderer.FaceUniforms(centroid: v(), xAxis: v(), yAxis: v(), load: v(), extent: v())
        }
        u.faces = (face(), face(), face(), face())
        u.tail = v()
        let expected: [SIMD4<Float>] = {
            var e = [u.nearO, u.nearX, u.nearY, u.farO, u.farX, u.farY, u.viewport, u.boxMin, u.boxMax,
                     u.shape, u.shape2, u.buildDir, u.rhoO, u.rhoN, u.maskO, u.maskN, u.sdfO, u.sdfN,
                     u.skinO, u.skinN, u.keyLight, u.fillLight, u.albedo, u.squish, u.march]
            for f in [u.faces.0, u.faces.1, u.faces.2, u.faces.3] {
                e += [f.centroid, f.xAxis, f.yAxis, f.load, f.extent]
            }
            e.append(u.tail)
            return e
        }()
        XCTAssertEqual(MemoryLayout<FlexibleLatticeRenderer.Uniforms>.stride, expected.count * 16)
        let echoed = try XCTUnwrap(r.echoUniforms(u, count: expected.count))
        XCTAssertEqual(echoed, expected)
    }

    // MARK: (b) GPU field == Swift reference

    func testGPUProbeMatchesTheSwiftReferenceForBothTopologies() throws {
        let r = try FlexibleLatticeRenderer(device: try device())
        let pts = Self.probePoints(256)
        for topo in [FlexibleLatticeInputs.Topology.gyroid, .honeycomb] {
            let f = Self.boxInputs(topo)
            r.setInputs(f)
            let gpu = try XCTUnwrap(r.probe(pts))
            XCTAssertEqual(gpu.count, pts.count)
            var worst: Float = 0, inside = 0, outside = 0
            for (i, p) in pts.enumerated() {
                let ref = FlexibleLatticeField.lattice(at: p, f)
                worst = Swift.max(worst, abs(gpu[i] - ref))
                if ref < 0 { inside += 1 } else { outside += 1 }
            }
            print("FLEX-PROBE \(topo): max |gpu − swift| = \(worst) mm over \(pts.count) points (\(inside) in a wall, \(outside) not)")
            XCTAssertLessThanOrEqual(worst, 2e-3, "\(topo): the GPU field drifted from FlexibleLatticeField.lattice")
            // the points sample BOTH sides of the walls, or the agreement proves little
            XCTAssertGreaterThan(inside, 5, "\(topo): no probe point landed in a wall")
            XCTAssertGreaterThan(outside, 5)
            // ★ POSITIVE CONTROL: the other topology's reference must NOT match this probe.
            var other = f
            other.topology = topo == .gyroid ? .honeycomb : .gyroid
            let miss = pts.indices.map { abs(gpu[$0] - FlexibleLatticeField.lattice(at: pts[$0], other)) }.max() ?? 0
            XCTAssertGreaterThan(miss, 0.1, "\(topo): the probe cannot tell the two topologies apart")
        }
    }

    /// The squish's inversion: the GPU deformed field == the Swift pull-back, away from the
    /// column walls (where the two may legitimately pick neighbouring columns).
    func testSquishProbeMatchesTheSwiftPullback() throws {
        let r = try FlexibleLatticeRenderer(device: try device())
        let f = Self.boxInputs(.gyroid)
        let face = Self.topFace(depth: 3)
        r.setInputs(f)
        r.setSquishFaces([face])
        let pts = Self.probePoints(400).filter { p in
            let u = p.x - 0, v = p.y - 0
            let fu = u / 2 - (u / 2).rounded(.down), fv = v / 2 - (v / 2).rounded(.down)
            return Swift.min(fu, 1 - fu) > 0.01 && Swift.min(fv, 1 - fv) > 0.01
        }
        let s: Float = 0.8
        let gpu = try XCTUnwrap(r.probeSquished(pts, squish: s))
        var worst: Float = 0, moved = 0, air = 0
        for (i, p) in pts.enumerated() {
            let ref = FlexibleSquishField.lattice(at: p, f, faces: [face], squish: s)
            worst = Swift.max(worst, abs(gpu[i] - ref))
            if abs(ref - FlexibleLatticeField.lattice(at: p, f)) > 1e-3 { moved += 1 }
            if FlexibleSquishField.pullback(p, faces: [face], squish: s).air > 0 { air += 1 }
        }
        print("FLEX-SQUISH-PROBE max |gpu − swift| = \(worst) mm over \(pts.count) points (\(moved) moved, \(air) in the pressed-in gap)")
        XCTAssertLessThanOrEqual(worst, 2e-3)
        XCTAssertGreaterThan(moved, 20, "the squish moved nothing the probe could see")
        XCTAssertGreaterThan(air, 0, "no probe point landed in the gap the face left")
    }

    /// The pull-back is the exact inverse of 02 §6's ramp (the same one FlexibleOverlay
    /// draws): push a rest point forward, pull it back, get the rest point.
    func testPullbackInvertsTheRamp() {
        let face = Self.topFace(depth: 3)
        for s: Float in [0.25, 0.5, 1] {
            for z: Float in [0.5, 4, 10, 17, 19.9] {
                let rest = SIMD3<Float>(13.3, 27.1, z)
                let moved = FlexibleSquishField.forward(rest, faces: [face], squish: s)
                // the face moves the full depth, the far end not at all (t = 20 − z)
                let expect = s * 3 * (20 - (20 - z)) / 20
                XCTAssertEqual(rest.z - moved.z, expect, accuracy: 1e-4, "s \(s) z \(z)")
                let back = FlexibleSquishField.pullback(moved, faces: [face], squish: s)
                XCTAssertLessThan(back.air, 0)
                XCTAssertEqual(back.p0.z, rest.z, accuracy: 1e-4, "s \(s) z \(z)")
                XCTAssertEqual(back.p0.x, rest.x); XCTAssertEqual(back.p0.y, rest.y)
            }
            // above the pressed face is air: the face moved in by s·d
            let gap = FlexibleSquishField.pullback(SIMD3(13.3, 27.1, 20 - 0.5 * s * 3), faces: [face], squish: s)
            XCTAssertGreaterThan(gap.air, 0)
        }
        // s = 0 is the rest lattice, bit for bit
        let p = SIMD3<Float>(3.7, 8.1, 12.2)
        let z = FlexibleSquishField.pullback(p, faces: [face], squish: 0)
        XCTAssertEqual(z.p0, p); XCTAssertEqual(z.scale, 1); XCTAssertLessThan(z.air, 0)
    }

    // MARK: (c) the render covers the box and the topologies differ

    func testOffscreenRenderCoversTheBoxAndTheTopologiesDiffer() throws {
        let r = try FlexibleLatticeRenderer(device: try device())
        let size = 512
        let proj = Self.obliqueProjection(size: size)
        r.setInputs(Self.boxInputs(.gyroid))
        let gyroid = try XCTUnwrap(r.renderOffscreen(width: size, height: size, projection: proj))
        r.setInputs(Self.boxInputs(.honeycomb))
        let honey = try XCTUnwrap(r.renderOffscreen(width: size, height: size, projection: proj))
        let total = size * size
        let cg = covered(gyroid), ch = covered(honey), d = differing(gyroid, honey)
        print("FLEX-RENDER covered gyroid \(cg)/\(total) (\(100 * cg / total) %), honeycomb \(ch)/\(total) (\(100 * ch / total) %), differing \(d)")
        XCTAssertGreaterThan(Double(cg), 0.02 * Double(total))
        XCTAssertGreaterThan(Double(ch), 0.02 * Double(total))
        XCTAssertGreaterThan(Double(d), 0.02 * Double(total), "gyroid and honeycomb drew the same picture")
        // ★ the background stays transparent: the corners see no part
        XCTAssertEqual(gyroid[3], 0, "top-left corner is not transparent")
        XCTAssertEqual(gyroid[(total - 1) * 4 + 3], 0, "bottom-right corner is not transparent")
        // and nothing is drawn with no inputs at all
        r.setInputs(nil)
        let empty = try XCTUnwrap(r.renderOffscreen(width: size, height: size, projection: proj))
        XCTAssertEqual(covered(empty), 0)
    }

    // MARK: (d) the squish moves the picture; s = 0 is the rest lattice exactly

    func testSquishMovesTheRenderAndZeroSquishIsTheRestLattice() throws {
        let r = try FlexibleLatticeRenderer(device: try device())
        let size = 512
        let proj = Self.obliqueProjection(size: size)
        r.setInputs(Self.boxInputs(.gyroid))
        r.setSquishFaces([])
        let rest = try XCTUnwrap(r.renderOffscreen(width: size, height: size, projection: proj, squish: 0))
        r.setSquishFaces([Self.topFace(depth: 3)])
        let zero = try XCTUnwrap(r.renderOffscreen(width: size, height: size, projection: proj, squish: 0))
        let full = try XCTUnwrap(r.renderOffscreen(width: size, height: size, projection: proj, squish: 1))
        let dz = differing(rest, zero), df = differing(rest, full)
        print("FLEX-SQUISH render: s=0 vs no faces differ at \(dz) px; s=1 vs rest differ at \(df) px of \(size * size)")
        XCTAssertEqual(dz, 0, "s = 0 must draw the undeformed lattice exactly")
        XCTAssertGreaterThan(Double(df), 0.01 * Double(size * size), "s = 1 did not move the lattice")
        // ★ and the render is a function of s alone: the same s twice is the same picture
        // (a march that read stale state would differ here)
        let again = try XCTUnwrap(r.renderOffscreen(width: size, height: size, projection: proj, squish: 1))
        XCTAssertEqual(differing(full, again), 0)
    }

    // MARK: the SwiftUI layer's call path (not just the renderer's value types)

    /// Through the coordinator the view actually uses: the MTKView is transparent, takes no
    /// touch, redraws on demand — and runs frames ONLY while a squish loop has something to
    /// play. Inputs, faces and camera reach the renderer it drives.
    @MainActor
    func testLayerRunsFramesOnlyWhileTheSquishLoops() throws {
        _ = try device()
        let co = FlexibleLatticeCoordinator()
        let v = co.makeView()
        let r = try XCTUnwrap(co.renderer, "the layer built no renderer on a device that exists")
        XCTAssertTrue(v.delegate === r)
        XCTAssertEqual(v.clearColor.alpha, 0)
        XCTAssertFalse(v.isOpaque)
        #if os(macOS)
        XCTAssertNil(v.hitTest(NSPoint(x: 1, y: 1)), "the lattice layer swallowed a click meant for the part")
        #endif
        XCTAssertTrue(v.isPaused)

        let box = Self.boxInputs(.gyroid), proj = Self.obliqueProjection(size: 256)
        co.apply(FlexibleLatticeView(inputs: box, projection: proj), to: v)
        XCTAssertEqual(r.inputs, box); XCTAssertEqual(r.projection, proj)
        XCTAssertTrue(v.isPaused, "a still lattice must not run frames")

        // a loop with nothing to squish stays paused
        co.apply(FlexibleLatticeView(inputs: box, projection: proj, motion: .loop(periodSeconds: 2)), to: v)
        XCTAssertTrue(v.isPaused)

        let face = Self.topFace(depth: 3)
        co.apply(FlexibleLatticeView(inputs: box, projection: proj, squishFaces: [face],
                                     motion: .loop(periodSeconds: 2), exaggeration: 2), to: v)
        XCTAssertFalse(v.isPaused, "the squish loop is not running")
        XCTAssertFalse(v.enableSetNeedsDisplay)
        XCTAssertEqual(r.squishFaces, [face]); XCTAssertEqual(r.exaggeration, 2)
        // the loop starts from rest and reaches full squish half a period later
        XCTAssertEqual(r.currentSquish(now: r.motionEpoch), 0, accuracy: 1e-6)
        XCTAssertEqual(r.currentSquish(now: r.motionEpoch + 1), 1, accuracy: 1e-6)
        XCTAssertEqual(r.currentSquish(now: r.motionEpoch + 2), 0, accuracy: 1e-6)

        co.apply(FlexibleLatticeView(inputs: box, projection: proj, squishFaces: [face], motion: .still(0.5)), to: v)
        XCTAssertTrue(v.isPaused, "stopping the loop left frames running")
        XCTAssertTrue(v.enableSetNeedsDisplay)
        XCTAssertEqual(r.currentSquish(), 0.5)
    }

    // MARK: the march draws the field's zero set, not an approximation of it

    /// Coverage pixels where `px` and `ref` disagree (one drew a wall, the other did not).
    func coverageMismatch(_ px: [UInt8], _ ref: [UInt8]) -> Int {
        var n = 0
        for i in stride(from: 3, to: px.count, by: 4) where (px[i] > 0) != (ref[i] > 0) { n += 1 }
        return n
    }

    /// A march at a fiftieth of a cell (0.2·|F|, 0.005 mm floor, 30 000 steps) is the
    /// picture of the field; the shipping march must agree with it to 0.3 % of the covered
    /// pixels (what is left is silhouette jitter). ★ Both controls must go RED: the spec's
    /// first quarter-cell gyroid step jumps walls (1.2 % measured), and without the column-wall
    /// bound a checkerboard press tears (2.5 %) — a comparison that could not see those could
    /// not see anything.
    func testMarchMatchesAFineReferenceMarch() throws {
        let r = try FlexibleLatticeRenderer(device: try device())
        let size = 768
        let proj = Self.obliqueProjection(size: size)
        var cells: [SIMD4<Float>] = []
        for iv in 0..<20 { for iu in 0..<20 { cells.append(SIMD4((iu + iv) % 2 == 0 ? 0.5 : 4, 0, 20, 1)) } }
        let checker = FlexibleSquishFace(centroid: SIMD3(20, 20, 20), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0),
                                         load: SIMD3(0, 0, -1), uMin: -20, vMin: -20, pitchMM: 2,
                                         nu: 20, nv: 20, cells: cells)
        func reference(_ s: Float) throws -> [UInt8] {
            r.stepFactor = 0.2; r.stepCapOverride = 0.02; r.minStepMM = 0.005; r.stepBudget = 30000
            defer { r.stepFactor = 0.6; r.stepCapOverride = nil; r.minStepMM = 0.02; r.stepBudget = FlexibleLatticeRenderer.maxSteps }
            return try XCTUnwrap(r.renderOffscreen(width: size, height: size, projection: proj, squish: s))
        }
        for (topo, faces) in [(FlexibleLatticeInputs.Topology.gyroid, [FlexibleSquishFace]()), (.gyroid, [checker]),
                              (.honeycomb, []), (.honeycomb, [checker])] {
            r.setInputs(Self.boxInputs(topo))
            r.setSquishFaces(faces)
            let s: Float = faces.isEmpty ? 0 : 1
            let ref = try reference(s)
            let nCovered = Double(covered(ref))
            let shipped = coverageMismatch(try XCTUnwrap(r.renderOffscreen(width: size, height: size, projection: proj, squish: s)), ref)
            let label = "\(topo) \(faces.isEmpty ? "rest" : "checkerboard press")"
            print("FLEX-MARCH \(label): \(shipped) px disagree with the fine march (of \(Int(nCovered)) covered)")
            XCTAssertLessThan(Double(shipped), 0.003 * nCovered, "\(label): the march misses walls the field has")
            // ★ the controls
            if topo == .gyroid && faces.isEmpty {
                r.stepCapOverride = 0.25
                let quarter = coverageMismatch(try XCTUnwrap(r.renderOffscreen(width: size, height: size, projection: proj, squish: s)), ref)
                r.stepCapOverride = nil
                print("FLEX-MARCH control, gyroid at a quarter-cell cap: \(quarter) px")
                XCTAssertGreaterThan(Double(quarter), 0.01 * nCovered, "control: the comparison cannot see a jumped wall")
            }
            if !faces.isEmpty {
                r.ignoresColumnWalls = true
                let torn = coverageMismatch(try XCTUnwrap(r.renderOffscreen(width: size, height: size, projection: proj, squish: s)), ref)
                r.ignoresColumnWalls = false
                print("FLEX-MARCH control, \(label) without the column-wall bound: \(torn) px")
                XCTAssertGreaterThan(Double(torn), 0.01 * nCovered, "control: the comparison cannot see a torn column wall")
            }
        }
    }

    // MARK: performance (reported; the target is < 30 ms at 1024² on an M-series GPU)

    func testFrameTimeAt1024() throws {
        let r = try FlexibleLatticeRenderer(device: try device())
        let size = 1024
        let proj = Self.obliqueProjection(size: size)
        var report: [String] = []
        for topo in [FlexibleLatticeInputs.Topology.gyroid, .honeycomb] {
            r.setInputs(Self.boxInputs(topo))
            for (label, s) in [("rest", Float(0)), ("squished", Float(1))] {
                r.setSquishFaces(s > 0 ? [Self.topFace(depth: 3)] : [])
                _ = r.measureFrameGPUSeconds(width: size, height: size, projection: proj, squish: s)   // warm-up
                var ms: [Double] = []
                for _ in 0..<5 {
                    if let t = r.measureFrameGPUSeconds(width: size, height: size, projection: proj, squish: s) {
                        ms.append(t * 1000)
                    }
                }
                ms.sort()
                guard !ms.isEmpty else { throw XCTSkip("GPU timestamps unavailable on \(r.device.name)") }
                report.append(String(format: "%@ %@ median %.2f ms (min %.2f, max %.2f)",
                                     "\(topo)", label, ms[ms.count / 2], ms[0], ms[ms.count - 1]))
                // a hang guard, not the budget: the budget is reported below
                XCTAssertLessThan(ms[ms.count / 2], 250, "\(topo) \(label): the march is pathologically slow")
            }
        }
        print("FLEX-PERF 1024×1024 on \(r.device.name): " + report.joined(separator: "; "))
    }

    // MARK: evidence (opt-in: TOPOPT_FLEX_LATTICE_DIR=<dir>)

    /// The actual fragment-shader output as PNGs, composited over the stage's dark backdrop
    /// so a transparent frame is readable in any viewer. Numbers can pass while the picture
    /// is wrong; this is the picture.
    func testWriteEvidencePNGs() throws {
        guard let dir = ProcessInfo.processInfo.environment["TOPOPT_FLEX_LATTICE_DIR"] else {
            throw XCTSkip("set TOPOPT_FLEX_LATTICE_DIR to write the Flexible lattice evidence PNGs")
        }
        let r = try FlexibleLatticeRenderer(device: try device())
        let size = 768
        let proj = Self.obliqueProjection(size: size)
        func write(_ name: String, _ px: [UInt8]) throws {
            var out = [UInt8](repeating: 255, count: px.count)
            let bg: [Float] = [0.11, 0.12, 0.14]
            for i in stride(from: 0, to: px.count, by: 4) {
                let a = Float(px[i + 3]) / 255
                for c in 0..<3 { out[i + c] = UInt8(Swift.min(255, Float(px[i + c]) + bg[c] * 255 * (1 - a))) }
            }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(out) as CFData))
            let img = try XCTUnwrap(CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                                            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                            provider: provider, decode: nil, shouldInterpolate: false,
                                            intent: .defaultIntent))
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, img, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest), name)
            print("FLEX-EVIDENCE wrote \(url.path)")
        }
        for topo in [FlexibleLatticeInputs.Topology.gyroid, .honeycomb] {
            r.setInputs(Self.boxInputs(topo))
            r.setSquishFaces([])
            try write("flex_\(topo)_rest", try XCTUnwrap(r.renderOffscreen(width: size, height: size, projection: proj, squish: 0)))
            r.paintsExhaustedRays = true
            try write("flex_\(topo)_rest_exhausted_red", try XCTUnwrap(r.renderOffscreen(width: size, height: size, projection: proj, squish: 0)))
            r.paintsExhaustedRays = false
            r.setSquishFaces([Self.topFace(depth: 3)])
            r.exaggeration = 2
            try write("flex_\(topo)_squished_x2", try XCTUnwrap(r.renderOffscreen(width: size, height: size, projection: proj, squish: 1)))
            r.exaggeration = 1
        }
    }
}
#endif
