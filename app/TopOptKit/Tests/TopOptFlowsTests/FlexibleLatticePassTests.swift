// FlexibleLatticePassTests — the Flexible lattice as a THIRD G-BUFFER WRITER inside
// MeshRenderer (task 2026-09-29-flexible-screens, in-pass round; maintainer: "look at the
// way App does the lattice preview and build upon that … your preview will be the source
// of truth"). The pass's own contracts, each with a control that goes RED:
//   T1  the library compiles with a THROWING try and the pipeline declares all three
//       G-buffer colour formats (a pipeline writes only its declared attachments);
//   T2  the uniform and frame structs match the MSL BY NAME (they are matched by byte
//       offset, so a swap on one side would draw nonsense silently);
//   T3  the ray is the octet's camera basis (no matrix inversion);
//   T4  the GPU field and squish equal the Swift reference (ported from the retired
//       FlexibleLatticeRendererTests / CoverageTests), on the grids AS THE GPU SEES THEM —
//       within 5 µm (`parityMM`): Stage B samples the (SDF, skin) volume as hardware-
//       filtered halves (8-bit filter weights); ρ stays exact;
//   T10 (the eye-depth half) the G-buffer's eye-Z is the hit's −(modelView·hit).z;
//   T13 MeshRenderer uploads once per token.
// GPU-gated: skips only when no Metal device exists; a shader that fails to compile on a
// device that exists is a FAILURE (the throwing try rethrows the compiler log).
#if canImport(Metal) && canImport(MetalKit)
import XCTest
import Metal
import simd
@testable import TopOptFlows

final class FlexibleLatticePassTests: XCTestCase {

    typealias Fx = FlexibleLatticeFixtures
    /// ★ STAGE B (the Release frame missed 16 ms): the (SDF, skin) volume is sampled as
    /// hardware-filtered HALVES, so the stated parity is 5 µm — it was 2 µm with every
    /// fetch an exact trilinear of 32-bit reads. The reference holds the half-rounded grids.
    static let parityMM: Float = 5e-3
    /// T11's depth half: the share of pixels (covered by both marches) allowed to land on a
    /// different wall than the fine march — measured, see testMarchDepthMatchesAFineReference.
    static let depthBar: Double = 0.01

    // MARK: T1 — pipeline and compile guard

    func testPipelineDeclaresTheGBufferAttachments() throws {
        let device = try Fx.device()
        // ★ THROWING: a dead library is a red test, never a skip or a silent nil
        let lib = try device.makeLibrary(source: FlexibleLatticeShader.gbufferSource, options: nil)
        for name in ["flx_vertex", "flx_gbuffer", "flx_field_probe", "flx_squish_probe",
                     "flx_uniform_echo", "flx_frame_echo"] {
            XCTAssertNotNil(lib.makeFunction(name: name), "\(name) missing from the MSL")
        }
        let pass = try FlexibleLatticePass(device: device)
        XCTAssertTrue(pass.gbufferPipelineDidBuild)
        // the test kernels are built on first use, THROWING too
        for name in ["flx_field_probe", "flx_squish_probe", "flx_uniform_echo", "flx_frame_echo"] {
            XCTAssertEqual(try pass.computePipeline(name).label, name)
        }
        XCTAssertThrowsError(try pass.computePipeline("flx_no_such_kernel"), "control: a missing kernel must throw")
        let d = pass.gbufferDescriptor
        XCTAssertEqual(FlexibleLatticePass.descriptorProblems(d), [])
        XCTAssertEqual(d.colorAttachments[0].pixelFormat, MeshRenderer.sceneDepthFormat)
        XCTAssertEqual(d.colorAttachments[1].pixelFormat, MeshRenderer.gbufferNormalFormat)
        XCTAssertEqual(d.colorAttachments[2].pixelFormat, MeshRenderer.gbufferAlbedoFormat)
        XCTAssertEqual(d.depthAttachmentPixelFormat, MeshRenderer.depthFormat)
        XCTAssertEqual(d.rasterSampleCount, 1)
        // one fragment depth write, declared conservative in the direction the triangle allows
        let src = FlexibleLatticeShader.gbufferSource
        XCTAssertEqual(src.components(separatedBy: "[[depth(").count - 1, 1)
        XCTAssertTrue(src.contains("[[depth(greater)]]"))
        // its own library: never interpolated into #354's unified source
        XCTAssertFalse(MeshRenderer.latticeShaderSourceForTesting.contains("flx_"))
        // ★ RED CONTROL: the same check on a descriptor missing attachment 2 must fail
        let bad = try XCTUnwrap(d.copy() as? MTLRenderPipelineDescriptor)
        bad.colorAttachments[2].pixelFormat = .invalid
        XCTAssertFalse(FlexibleLatticePass.descriptorProblems(bad).isEmpty,
                       "control: a pipeline that drops the albedo attachment must be caught")
    }

    // MARK: T2 — uniform layouts by name

    func testUniformAndFrameLayoutsMatchTheMSL() throws {
        let pass = try FlexibleLatticePass(device: try Fx.device())
        var k: Float = 1
        func v() -> SIMD4<Float> { defer { k += 4 }; return SIMD4(k, k + 1, k + 2, k + 3) }
        func face() -> FlexibleLatticePass.FaceUniforms {
            FlexibleLatticePass.FaceUniforms(centroid: v(), xAxis: v(), yAxis: v(), load: v(), extent: v())
        }
        var u = FlexibleLatticePass.Uniforms()
        u.boxMin = v(); u.boxMax = v(); u.shape = v(); u.shape2 = v(); u.buildDir = v()
        u.rmO = v(); u.rmN = v(); u.dsO = v(); u.dsN = v(); u.squish = v(); u.march = v()
        u.faces = (face(), face(), face(), face())
        // ★ RE-PINNED (round 5 batch G): the FE field's block (feO / feN / feK) before the tail
        u.feO = v(); u.feN = v(); u.feK = v()
        u.tail = v()
        var expected = [u.boxMin, u.boxMax, u.shape, u.shape2, u.buildDir, u.rmO, u.rmN, u.dsO, u.dsN,
                        u.squish, u.march]
        for f in [u.faces.0, u.faces.1, u.faces.2, u.faces.3] { expected += [f.centroid, f.xAxis, f.yAxis, f.load, f.extent] }
        expected += [u.feO, u.feN, u.feK]
        expected.append(u.tail)
        XCTAssertEqual(MemoryLayout<FlexibleLatticePass.Uniforms>.stride, expected.count * 16)
        XCTAssertEqual(try XCTUnwrap(pass.echo(u, frame: false, count: expected.count)), expected)

        func m() -> simd_float4x4 { simd_float4x4(columns: (v(), v(), v(), v())) }
        var f = FlexibleLatticePass.Frame()
        f.eye = v(); f.rayX = v(); f.rayY = v(); f.rayDir = v()
        f.clipFromModel = m(); f.eyeFromModel = m(); f.eyeNormalBasis = m()
        f.sparse = v(); f.dense = v(); f.rhoSpan = v(); f.tail = v()
        func cols(_ x: simd_float4x4) -> [SIMD4<Float>] { [x.columns.0, x.columns.1, x.columns.2, x.columns.3] }
        let fExpected = [f.eye, f.rayX, f.rayY, f.rayDir] + cols(f.clipFromModel) + cols(f.eyeFromModel)
            + cols(f.eyeNormalBasis) + [f.sparse, f.dense, f.rhoSpan, f.tail]
        XCTAssertEqual(MemoryLayout<FlexibleLatticePass.Frame>.stride, fExpected.count * 16)
        XCTAssertEqual(try XCTUnwrap(pass.echo(f, frame: true, count: fExpected.count)), fExpected)

        // ★ RED CONTROL: a Swift struct with two float4 fields swapped, filled BY NAME, does
        // not echo back by name — the echo can see a reorder on one side.
        struct Swapped {
            var boxMax = SIMD4<Float>.zero, boxMin = SIMD4<Float>.zero       // ← swapped
            var shape = SIMD4<Float>.zero, shape2 = SIMD4<Float>.zero, buildDir = SIMD4<Float>.zero
            var rmO = SIMD4<Float>.zero, rmN = SIMD4<Float>.zero, dsO = SIMD4<Float>.zero, dsN = SIMD4<Float>.zero
            var squish = SIMD4<Float>.zero, march = SIMD4<Float>.zero
            var faces: (FlexibleLatticePass.FaceUniforms, FlexibleLatticePass.FaceUniforms,
                        FlexibleLatticePass.FaceUniforms, FlexibleLatticePass.FaceUniforms) = (.zero, .zero, .zero, .zero)
            var feO = SIMD4<Float>.zero, feN = SIMD4<Float>.zero, feK = SIMD4<Float>.zero
            var tail = SIMD4<Float>.zero
        }
        var s = Swapped()
        s.boxMin = u.boxMin; s.boxMax = u.boxMax; s.shape = u.shape; s.shape2 = u.shape2; s.buildDir = u.buildDir
        s.rmO = u.rmO; s.rmN = u.rmN; s.dsO = u.dsO; s.dsN = u.dsN; s.squish = u.squish; s.march = u.march
        s.faces = u.faces; s.feO = u.feO; s.feN = u.feN; s.feK = u.feK; s.tail = u.tail
        XCTAssertEqual(MemoryLayout<Swapped>.stride, MemoryLayout<FlexibleLatticePass.Uniforms>.stride)
        let swappedEcho = try XCTUnwrap(pass.echo(s, frame: false, count: expected.count))
        XCTAssertNotEqual(swappedEcho, expected, "control: a swapped field must fail the by-name echo")
    }

    // MARK: T3 — the ray is the octet's camera basis

    func testRayBasisIsTheOctetsCameraBasis() throws {
        let device = try Fx.device()
        let oct = try XCTUnwrap(LatticeSDFRenderer(device: device, buildPipeline: false))
        var cam = OrbitCamera()
        cam.frame(MeshBounds(min: SIMD3(0, 0, 0), max: SIMD3(40, 40, 20), isEmpty: false))
        cam.setOrientation(azimuth: 0.9, elevation: 0.35)
        let settle = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: simd_normalize(SIMD3<Float>(0.3, -1, 0.2)))
        let centre = SIMD3<Float>(23.3, 18.3, 12.1)
        oct.camera = cam; oct.modelRotation = settle; oct.modelCenter = centre
        let aspect: Float = 1.37
        let u = oct.makeUniforms(aspect: aspect)
        func err(_ b: (eye: SIMD3<Float>, rayX: SIMD3<Float>, rayY: SIMD3<Float>, rayDir: SIMD3<Float>)) -> Float {
            let d = [b.eye - SIMD3(u.eye.x, u.eye.y, u.eye.z), b.rayX - SIMD3(u.rayX.x, u.rayX.y, u.rayX.z),
                     b.rayY - SIMD3(u.rayY.x, u.rayY.y, u.rayY.z), b.rayDir - SIMD3(u.rayDir.x, u.rayDir.y, u.rayDir.z)]
            return d.map { simd_reduce_max(simd_abs($0)) }.max() ?? .infinity
        }
        let e = err(FlexibleLatticePass.rayBasis(camera: cam, modelRotation: settle, modelCenter: centre, aspect: aspect))
        let wrong = err(FlexibleLatticePass.rayBasis(camera: cam, modelRotation: settle, modelCenter: centre, aspect: aspect * 1.01))
        print("FLEX-RAY max |flexible − octet| = \(e); control (aspect × 1.01) = \(wrong)")
        XCTAssertLessThanOrEqual(e, 1e-6)
        XCTAssertGreaterThan(wrong, 1e-6, "control: a wrong aspect must exceed the tolerance")
    }

    // MARK: T4 — field and squish parity (ported)

    func testGPUProbeMatchesTheSwiftReferenceForBothTopologies() throws {
        let pass = try FlexibleLatticePass(device: try Fx.device())
        let pts = Fx.probePoints(256)
        for (n, topo) in [FlexibleLatticeInputs.Topology.gyroid, .honeycomb].enumerated() {
            pass.upload(Fx.layer(Fx.boxInputs(topo), token: n + 1))
            let f = try XCTUnwrap(pass.referenceInputs, "the grids as the GPU sees them")
            let gpu = try XCTUnwrap(pass.probe(pts))
            var worst: Float = 0, inside = 0, outside = 0
            for (i, p) in pts.enumerated() {
                let ref = FlexibleLatticeField.lattice(at: p, f)
                worst = max(worst, abs(gpu[i] - ref))
                if ref < 0 { inside += 1 } else { outside += 1 }
            }
            // ★ RED CONTROLS: the other topology's reference, and the two packed volumes
            // bound to each other's slots, must both miss
            var other = f
            other.topology = topo == .gyroid ? .honeycomb : .gyroid
            let missTopo = pts.indices.map { abs(gpu[$0] - FlexibleLatticeField.lattice(at: pts[$0], other)) }.max() ?? 0
            pass.controlSwapVolumes = true
            let swapped = try XCTUnwrap(pass.probe(pts))
            pass.controlSwapVolumes = false
            let missSwap = pts.indices.map { abs(swapped[$0] - FlexibleLatticeField.lattice(at: pts[$0], f)) }.max() ?? 0
            print("FLEX-PROBE \(topo): max |gpu − swift| = \(worst) mm over \(pts.count) points (\(inside) in a wall, \(outside) not); controls: other topology \(missTopo), swapped volumes \(missSwap)")
            XCTAssertLessThanOrEqual(worst, Self.parityMM, "\(topo): the GPU field drifted from FlexibleLatticeField.lattice")
            XCTAssertGreaterThan(inside, 5); XCTAssertGreaterThan(outside, 5)
            XCTAssertGreaterThan(missTopo, 0.1, "control: the probe must tell the topologies apart")
            XCTAssertGreaterThan(missSwap, 0.1, "control: the (ρ, mask) volume in the (SDF, skin) slot must show")
            if topo == .gyroid {
                // ★ THE LADDER IS EXERCISED: points inside a rung-to-rung blend AND on a pure rung
                var blend = 0, pure = 0
                for p in pts {
                    let rho = min(max(f.rho.sample(p), 0.05), 0.9)
                    let w = FlexibleLatticeField.rungs(L: min(max(3.0915 * f.wallMM / rho, f.lMinMM), f.lMaxMM), lMin: f.lMinMM).w
                    if w > 0 && w < 1 { blend += 1 } else { pure += 1 }
                }
                // ★ RED CONTROL: the retired chirped gyroid (q = k(p)·p) is NOT what the GPU draws
                let missChirp = pts.indices.map { i -> Float in
                    let p = pts[i]
                    let chirp = max(max(FlexibleLatticeGradingTests.chirpedWall(p, f), FlexibleLatticeField.dRegion(p, f)),
                                    max(f.partSDF.sample(p), FlexibleLatticeField.dSkin(p, f)))
                    return abs(gpu[i] - chirp)
                }.max() ?? 0
                print("FLEX-PROBE gyroid ladder: \(blend) points in a blend, \(pure) on a pure rung; control (chirped q = k·p) misses by \(missChirp) mm")
                XCTAssertGreaterThan(blend, 20); XCTAssertGreaterThan(pure, 20)
                XCTAssertGreaterThan(missChirp, 0.1, "control: the probe must tell the ladder from the chirp")
            }
        }
    }

    func testSquishProbeMatchesTheSwiftPullback() throws {
        let pass = try FlexibleLatticePass(device: try Fx.device())
        let face = Fx.topFace(depth: 3)
        pass.upload(Fx.layer(Fx.boxInputs(.gyroid), faces: [face], token: 1))
        let f = try XCTUnwrap(pass.referenceInputs)
        // away from the column walls, where the two may legitimately pick neighbouring columns
        let pts = Fx.probePoints(400).filter { p in
            let fu = p.x / 2 - (p.x / 2).rounded(.down), fv = p.y / 2 - (p.y / 2).rounded(.down)
            return min(fu, 1 - fu) > 0.01 && min(fv, 1 - fv) > 0.01
        }
        let s: Float = 0.8
        let gpu = try XCTUnwrap(pass.probeSquished(pts, squish: s))
        var worst: Float = 0, moved = 0, air = 0, missHalf: Float = 0
        for (i, p) in pts.enumerated() {
            let ref = FlexibleSquishField.lattice(at: p, f, faces: [face], squish: s)
            worst = max(worst, abs(gpu[i] - ref))
            if abs(ref - FlexibleLatticeField.lattice(at: p, f)) > 1e-3 { moved += 1 }
            if FlexibleSquishField.pullback(p, faces: [face], squish: s).air > 0 { air += 1 }
            // ★ RED CONTROL: the reference at HALF the squish must disagree — the probe sees s
            missHalf = max(missHalf, abs(gpu[i] - FlexibleSquishField.lattice(at: p, f, faces: [face], squish: s / 2)))
        }
        print("FLEX-SQUISH-PROBE max |gpu − swift| = \(worst) mm over \(pts.count) points (\(moved) moved, \(air) in the gap); control at s/2: \(missHalf)")
        XCTAssertLessThanOrEqual(worst, Self.parityMM)
        XCTAssertGreaterThan(moved, 20, "the squish moved nothing the probe could see")
        XCTAssertGreaterThan(air, 0, "no probe point landed in the gap the face left")
        XCTAssertGreaterThan(missHalf, 0.1, "control: the probe must see the squish amount")

        // ★ PAST THE CLAMP: s = 8 on a 3 mm / 20 mm column asks a = 1.2, so both copies clamp
        // at FlexibleSquishField.maxRatio (the MSL interpolates the same constant). His pad
        // runs at a ≈ 0.44 and the cases above at 0.12 — neither reached the clamp before.
        let sClamp: Float = 8
        XCTAssertGreaterThan(sClamp * 3 / 20, FlexibleSquishField.maxRatio, "the case must reach the clamp")
        let gpuC = try XCTUnwrap(pass.probeSquished(pts, squish: sClamp))
        var worstC: Float = 0, missBelow: Float = 0
        for (i, p) in pts.enumerated() {
            worstC = max(worstC, abs(gpuC[i] - FlexibleSquishField.lattice(at: p, f, faces: [face], squish: sClamp)))
            // ★ RED CONTROL: below the clamp (a = 0.6) the reference is a different field
            missBelow = max(missBelow, abs(gpuC[i] - FlexibleSquishField.lattice(at: p, f, faces: [face], squish: 4)))
        }
        print("FLEX-SQUISH-PROBE past the clamp (s = \(sClamp), a asked 1.2, clamped \(FlexibleSquishField.maxRatio)): max |gpu − swift| = \(worstC) mm; control (s = 4, a = 0.6) misses by \(missBelow)")
        XCTAssertLessThanOrEqual(worstC, Self.parityMM, "the shader's clamp drifted from FlexibleSquishField.maxRatio")
        XCTAssertGreaterThan(missBelow, 0.1, "control: the probe must tell a clamped column from an unclamped one")
    }

    func testRegionAndSkinTermsDecideTheGPUField() throws {
        let pass = try FlexibleLatticePass(device: try Fx.device())
        let pts = Fx.probePoints(3000, seed: 0xC0FFEE)
        var token = 0
        for topo in [FlexibleLatticeInputs.Topology.gyroid, .honeycomb] {
            token += 1
            pass.upload(Fx.layer(Fx.regionAndSkinBox(topo), token: token))
            let f = try XCTUnwrap(pass.referenceInputs)
            let gpu = try XCTUnwrap(pass.probe(pts))
            var worst: Float = 0, byRegion = 0, bySkin = 0
            for (i, p) in pts.enumerated() {
                worst = max(worst, abs(gpu[i] - FlexibleLatticeField.lattice(at: p, f)))
                let w = FlexibleLatticeField.wall(p, f), dr = FlexibleLatticeField.dRegion(p, f)
                let dp = f.partSDF.sample(p), ds = FlexibleLatticeField.dSkin(p, f)
                if dr > max(w, dp, ds) + 1e-3 { byRegion += 1 }
                if ds > max(w, dp, dr) + 1e-3 { bySkin += 1 }
            }
            // ★ CONTROLS: the same probe on inputs WITHOUT each term must disagree
            var noRegion = Fx.regionAndSkinBox(topo); noRegion.mask.values = [Float](repeating: 1, count: noRegion.mask.values.count)
            var noSkin = Fx.regionAndSkinBox(topo); noSkin.skinDist.values = [Float](repeating: 100, count: noSkin.skinDist.values.count)
            token += 1; pass.upload(Fx.layer(noRegion, token: token))
            let gpuNoRegion = try XCTUnwrap(pass.probe(pts))
            token += 1; pass.upload(Fx.layer(noSkin, token: token))
            let gpuNoSkin = try XCTUnwrap(pass.probe(pts))
            let missRegion = pts.indices.map { abs(gpuNoRegion[$0] - FlexibleLatticeField.lattice(at: pts[$0], f)) }.max() ?? 0
            let missSkin = pts.indices.map { abs(gpuNoSkin[$0] - FlexibleLatticeField.lattice(at: pts[$0], f)) }.max() ?? 0
            print("FLEX-TERMS \(topo): max |gpu − swift| \(worst) mm over \(pts.count) points; region decides at \(byRegion), skin at \(bySkin); controls: region dropped \(missRegion) mm, skin dropped \(missSkin) mm")
            XCTAssertLessThanOrEqual(worst, Self.parityMM)
            XCTAssertGreaterThanOrEqual(byRegion, 5); XCTAssertGreaterThanOrEqual(bySkin, 5)
            XCTAssertGreaterThan(missRegion, 0.1, "control: a dropped region term must show")
            XCTAssertGreaterThan(missSkin, 0.1, "control: a dropped skin term must show")
        }
    }

    /// Stage B's half converter against the hardware's own (Float16 exists on arm64): every
    /// value the SDF can hold rounds to the same half, including ties and subnormals.
    func testHalfRoundingMatchesTheHardwareHalf() throws {
        #if arch(arm64)
        var vals: [Float] = [0, -0, 1, -1, 0.1, 0.2, 1e-5, 6.1e-5, 5.96e-8, 3e-8, 2049, 2050, 2051, 65504, 65520, 1e6, -1e6,
                             .infinity, -.infinity, 0.33333334, 12.345678, -7.0078125, 1.0009766, 1.0014648]
        var s: UInt64 = 7
        for _ in 0..<20000 {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            vals.append(Float(bitPattern: UInt32(truncatingIfNeeded: s >> 32)))
        }
        var bad = 0
        for v in vals where !v.isNaN {
            let mine = FlexibleLatticePass.halfBits(v)
            if mine != Float16(v).bitPattern { bad += 1 }
            if FlexibleLatticePass.halfValue(mine) != Float(Float16(v)) { bad += 1 }
        }
        XCTAssertEqual(bad, 0)
        XCTAssertTrue(FlexibleLatticePass.halfValue(FlexibleLatticePass.halfBits(.nan)).isNaN)
        // control: a converter that TRUNCATES must disagree somewhere
        let truncated = vals.filter { !$0.isNaN && abs($0) < 60000 && abs($0) > 1e-4 }.filter { v in
            let t = UInt16((v.bitPattern >> 16) & 0x8000) | UInt16(truncatingIfNeeded: ((Int(v.bitPattern >> 23 & 0xFF) - 112) << 10)) | UInt16(truncatingIfNeeded: (v.bitPattern & 0x7FFFFF) >> 13)
            return t != Float16(v).bitPattern
        }.count
        XCTAssertGreaterThan(truncated, 100, "control: truncation must be distinguishable from rounding")
        #else
        throw XCTSkip("Float16 is not available on this architecture")
        #endif
    }

    // MARK: T10 (eye depth + normal) — the G-buffer holds the hit's eye-Z and eye normal

    /// Renders the pass alone into a G-buffer of the renderer's formats, with the matrices
    /// MeshRenderer.makeUniforms composes (P·V·M, V·M, the rotation of V·M), and reads back
    /// eye-Z, the eye-space normal and the albedo mask.
    struct GBufferRead { var eyeZ: [Float]; var normal: [SIMD3<Float>]; var alpha: [UInt8]; var size: Int }

    struct Frame {
        let cam: OrbitCamera; let settle: simd_quatf; let centre: SIMD3<Float>
        var model: simd_float4x4 { ViewerModelFrame.matrix(centre: centre, rotation: settle) }
        var mv: simd_float4x4 { cam.viewMatrix() * model }
        var mvp: simd_float4x4 { cam.projectionMatrix(aspect: 1) * mv }
        var normalBasis: simd_float4x4 {
            let m = mv
            return simd_float4x4(columns: (SIMD4(m.columns.0.x, m.columns.0.y, m.columns.0.z, 0),
                                           SIMD4(m.columns.1.x, m.columns.1.y, m.columns.1.z, 0),
                                           SIMD4(m.columns.2.x, m.columns.2.y, m.columns.2.z, 0), SIMD4(0, 0, 0, 1)))
        }
        /// The page's framing (settle gravity → down), and a GENERIC one: a tilted settle and
        /// an off-origin centre, so a frame that only works for the page's view fails here.
        static func page(azimuth: Float = 0.65, elevation: Float = 0.5) -> Frame {
            var cam = OrbitCamera()
            cam.frame(MeshBounds(min: SIMD3(0, 0, 0), max: SIMD3(40, 40, 20), isEmpty: false))
            cam.setOrientation(azimuth: azimuth, elevation: elevation)
            return Frame(cam: cam, settle: simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0)),
                         centre: SIMD3(20, 20, 10))
        }
        static func generic() -> Frame {
            var cam = OrbitCamera()
            cam.frame(MeshBounds(min: SIMD3(0, 0, 0), max: SIMD3(40, 40, 20), isEmpty: false))
            cam.setOrientation(azimuth: 1.1, elevation: 0.3)
            return Frame(cam: cam, settle: simd_quatf(from: SIMD3<Float>(0, 0, -1), to: simd_normalize(SIMD3<Float>(0.3, -1, 0.2))),
                         centre: SIMD3(23.3, 18.3, 12.1))
        }
    }

    func renderGBuffer(_ pass: FlexibleLatticePass, device: MTLDevice, frame fr: Frame, size: Int,
                       squish: Float = 0) throws -> GBufferRead {
        func tex(_ f: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: size, height: size, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = f == MeshRenderer.depthFormat ? .private : .shared
            return device.makeTexture(descriptor: d)
        }
        let z = try XCTUnwrap(tex(MeshRenderer.sceneDepthFormat)), n = try XCTUnwrap(tex(MeshRenderer.gbufferNormalFormat))
        let a = try XCTUnwrap(tex(MeshRenderer.gbufferAlbedoFormat)), dep = try XCTUnwrap(tex(MeshRenderer.depthFormat))
        let rpd = MTLRenderPassDescriptor()
        for (i, t) in [z, n, a].enumerated() {
            rpd.colorAttachments[i].texture = t
            rpd.colorAttachments[i].loadAction = .clear
            rpd.colorAttachments[i].storeAction = .store
            rpd.colorAttachments[i].clearColor = i == 0 ? MTLClearColor(red: 1e30, green: 0, blue: 0, alpha: 0)
                                                        : MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
        rpd.depthAttachment.texture = dep
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1
        rpd.depthAttachment.storeAction = .dontCare
        let dsd = MTLDepthStencilDescriptor()
        dsd.depthCompareFunction = .less; dsd.isDepthWriteEnabled = true
        let ds = try XCTUnwrap(device.makeDepthStencilState(descriptor: dsd))
        let q = try XCTUnwrap(device.makeCommandQueue()), cmd = try XCTUnwrap(q.makeCommandBuffer())
        let enc = try XCTUnwrap(cmd.makeRenderCommandEncoder(descriptor: rpd))
        XCTAssertTrue(pass.encodeGBuffer(enc, depthState: ds, camera: fr.cam, modelRotation: fr.settle, modelCenter: fr.centre,
                                         aspect: 1, clipFromModel: fr.mvp, eyeFromModel: fr.mv, eyeNormalBasis: fr.normalBasis,
                                         squish: squish))
        enc.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        var eyeZ = [Float](repeating: 0, count: size * size)
        z.getBytes(&eyeZ, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        var nh = [UInt16](repeating: 0, count: size * size * 4)
        n.getBytes(&nh, bytesPerRow: size * 8, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        let normal = (0..<(size * size)).map { i in
            SIMD3<Float>(FlexibleLatticePass.halfValue(nh[i * 4]), FlexibleLatticePass.halfValue(nh[i * 4 + 1]),
                         FlexibleLatticePass.halfValue(nh[i * 4 + 2]))
        }
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        a.getBytes(&rgba, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        return GBufferRead(eyeZ: eyeZ, normal: normal, alpha: stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }, size: size)
    }

    /// The Swift field's first zero along a ray: sphere-traced, then bisected. ★ Inside the
    /// part the step is capped at 0.05 mm: the gyroid's |g|/|∇g| over-reads between the
    /// sheets (why the shader caps its step at 0.1 cell), so an uncapped CPU trace jumps
    /// walls itself and the comparison would blame the GPU for the reference's miss.
    static func cpuHit(_ f: FlexibleLatticeInputs, eye: SIMD3<Float>, rd: SIMD3<Float>) -> SIMD3<Float>? {
        var t: Float = 0, prev: Float = 0
        for _ in 0..<200_000 {
            let p = eye + rd * t
            let v = FlexibleLatticeField.lattice(at: p, f)
            if v < 0 {
                var lo = prev, hi = t
                for _ in 0..<30 { let m = 0.5 * (lo + hi); if FlexibleLatticeField.lattice(at: eye + rd * m, f) < 0 { hi = m } else { lo = m } }
                return eye + rd * hi
            }
            prev = t
            // outside the part only the part's own SDF is a true distance (the max of the
            // terms is not: an over-reading wall term would step through the part's face)
            let dPart = f.partSDF.sample(p)
            t += dPart > 0.5 ? 0.9 * dPart : min(max(0.4 * v, 0.004), 0.05)
            if t > 1e4 { break }
        }
        return nil
    }

    static func quantile(_ v: [Float], _ q: Double) -> Float {
        let s = v.sorted()
        return s.isEmpty ? .nan : s[min(s.count - 1, Int(q * Double(s.count)))]
    }

    /// ★ The G-buffer's eye-Z and eye NORMAL are the hit's, in the renderer's own frame —
    /// both topologies, at the page's framing AND a generic tilted, off-centre one.
    /// Quantiles, not the max: a few sparse pixels where the march legitimately lands on the
    /// next wall behind a grazing one (T11's depth half counts those) would make a max
    /// depend on the camera. Plus a CPU-only check that the ray basis and P·V·M agree to a
    /// sub-pixel (the hit re-projects onto its own pixel centre).
    func testGBufferEyeZAndNormalAreTheHits() throws {
        let device = try Fx.device()
        let pass = try FlexibleLatticePass(device: device)
        var token = 0
        for topo in [FlexibleLatticeInputs.Topology.gyroid, .honeycomb] {
            token += 1
            pass.upload(Fx.layer(Fx.boxInputs(topo), token: token))
            let f = try XCTUnwrap(pass.referenceInputs)
            for (fname, fr) in [("page", Frame.page()), ("generic", Frame.generic())] {
                let size = 256
                let g = try renderGBuffer(pass, device: device, frame: fr, size: size)
                let basis = FlexibleLatticePass.rayBasis(camera: fr.cam, modelRotation: fr.settle, modelCenter: fr.centre, aspect: 1)
                let wrongBasis = FlexibleLatticePass.rayBasis(camera: fr.cam, modelRotation: fr.settle, modelCenter: fr.centre, aspect: 1.01)
                var dz: [Float] = [], dzNoSettle: [Float] = [], ang: [Float] = [], angModel: [Float] = []
                var reproj: [Float] = [], reprojWrong: [Float] = []
                func eyeN(_ n: SIMD3<Float>, basis nb: simd_float4x4) -> SIMD3<Float> {
                    var e = simd_normalize(SIMD3<Float>((nb * SIMD4(n, 0)).x, (nb * SIMD4(n, 0)).y, (nb * SIMD4(n, 0)).z))
                    if e.z < 0 { e = -e }
                    return e
                }
                func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { acos(Swift.min(1, Swift.max(-1, simd_dot(simd_normalize(a), simd_normalize(b))))) }
                func pixel(_ p: SIMD3<Float>) -> SIMD2<Float> {
                    let c = fr.mvp * SIMD4(p, 1)
                    let ndc = SIMD2(c.x / c.w, c.y / c.w)
                    return SIMD2((ndc.x + 1) * 0.5 * Float(size), (1 - ndc.y) * 0.5 * Float(size))
                }
                for py in stride(from: 8, to: size - 8, by: 5) { for px in stride(from: 8, to: size - 8, by: 5) {
                    let i = py * size + px
                    guard g.alpha[i] >= 128, g.alpha[i - 1] >= 128, g.alpha[i + 1] >= 128,
                          g.alpha[i - size] >= 128, g.alpha[i + size] >= 128 else { continue }
                    let uv = SIMD2<Float>((Float(px) + 0.5) / Float(size) * 2 - 1, 1 - (Float(py) + 0.5) / Float(size) * 2)
                    let rd = simd_normalize(basis.rayDir + basis.rayX * uv.x + basis.rayY * uv.y)
                    guard let h = Self.cpuHit(f, eye: basis.eye, rd: rd) else { continue }
                    dz.append(abs(g.eyeZ[i] - (-(fr.mv * SIMD4(h, 1)).z)))
                    // ★ RED CONTROL (depth): the view alone, without the settled model frame
                    dzNoSettle.append(abs(g.eyeZ[i] - (-(fr.cam.viewMatrix() * SIMD4(h, 1)).z)))
                    // the normal: central differences of the Swift field at the hit (0.05 mm, the shader's)
                    let e: Float = 0.05
                    func F(_ p: SIMD3<Float>) -> Float { FlexibleLatticeField.lattice(at: p, f) }
                    let grad = SIMD3<Float>(F(h + SIMD3(e, 0, 0)) - F(h - SIMD3(e, 0, 0)),
                                            F(h + SIMD3(0, e, 0)) - F(h - SIMD3(0, e, 0)),
                                            F(h + SIMD3(0, 0, e)) - F(h - SIMD3(0, 0, e)))
                    // the normal is compared where the two hit the SAME wall (eye-Z within 0.02 mm)
                    guard simd_length(grad) > 1e-6, dz.last! <= 0.02 else { continue }
                    ang.append(angle(g.normal[i], eyeN(simd_normalize(grad), basis: fr.normalBasis)))
                    // ★ RED CONTROL (normal): the MODEL-space normal, as if the basis were skipped
                    var nm = simd_normalize(grad); if nm.z < 0 { nm = -nm }
                    angModel.append(angle(g.normal[i], nm))
                    // the ray basis and P·V·M agree: the hit lands on its own pixel centre
                    reproj.append(simd_distance(pixel(h), SIMD2(Float(px) + 0.5, Float(py) + 0.5)))
                    let rdW = simd_normalize(wrongBasis.rayDir + wrongBasis.rayX * uv.x + wrongBasis.rayY * uv.y)
                    if let hw = Self.cpuHit(f, eye: wrongBasis.eye, rd: rdW) {
                        reprojWrong.append(simd_distance(pixel(hw), SIMD2(Float(px) + 0.5, Float(py) + 0.5)))
                    }
                } }
                let over = dz.filter { $0 > 0.02 }.count
                print(String(format: "FLEX-GBUF %@ %@: %d wall px; eyeZ |Δ| p50 %.5f p99 %.4f max %.3f mm, %d over 0.02 mm; control (no settle) median %.2f mm; normal angle p50 %.4f p95 %.4f p99 %.3f rad; control (model-space normal) median %.3f rad; hit re-projects p99 %.2e px (control aspect×1.01 median %.2f px)",
                             "\(topo)", fname, dz.count, Self.quantile(dz, 0.5), Self.quantile(dz, 0.99), dz.max() ?? .nan, over,
                             Self.quantile(dzNoSettle, 0.5), Self.quantile(ang, 0.5), Self.quantile(ang, 0.95), Self.quantile(ang, 0.99),
                             Self.quantile(angModel, 0.5), Self.quantile(reproj, 0.99), Self.quantile(reprojWrong, 0.5)))
                XCTAssertGreaterThan(dz.count, 100, "\(topo) \(fname): too few wall pixels to judge")
                XCTAssertLessThanOrEqual(Self.quantile(dz, 0.99), 0.02, "\(topo) \(fname): the G-buffer eye-Z is not the hit's")
                XCTAssertLessThanOrEqual(Double(over), 0.02 * Double(dz.count), "\(topo) \(fname)")
                XCTAssertGreaterThan(Self.quantile(dzNoSettle, 0.5), 0.5, "control: the model frame must matter")
                XCTAssertLessThanOrEqual(Self.quantile(ang, 0.95), 0.05, "\(topo) \(fname): the G-buffer normal is not the field's")
                XCTAssertGreaterThan(Self.quantile(angModel, 0.5), 0.3, "control: a model-space normal must miss")
                XCTAssertLessThanOrEqual(Self.quantile(reproj, 0.99), 0.01, "the ray basis and P·V·M disagree")
                XCTAssertGreaterThan(Self.quantile(reprojWrong, 0.5), 0.1, "control: a wrong aspect must miss the pixel")
            }
        }
    }

    /// T11's DEPTH half (the in-pass T11 compares coverage only, which cannot see a march that
    /// jumps a wall and lands on the next one behind it). The shipped march against a fine,
    /// independent one (`flx_field`, early-outs off) on eye-Z: pixels covered by both whose
    /// depth differs by more than 0.05 mm. Rest and a checkerboard press, both topologies.
    /// ★ The rate is a KNOWN LIMIT of the step cap at grazing angles (sparse, a wall behind);
    /// the bar pins it where it is measured. RED CONTROL: a half-cell cap must exceed it.
    func testMarchDepthMatchesAFineReference() throws {
        let device = try Fx.device()
        let pass = try FlexibleLatticePass(device: device)
        var token = 0
        let size = 384
        for (topo, faces) in [(FlexibleLatticeInputs.Topology.gyroid, [FlexibleSquishFace]()), (.gyroid, [Fx.checkerFace()]),
                              (.honeycomb, []), (.honeycomb, [Fx.checkerFace()])] {
            token += 1
            pass.upload(Fx.layer(Fx.boxInputs(topo), faces: faces, token: token))
            let s: Float = faces.isEmpty ? 0 : 1
            for (fname, fr) in [("page", Frame.page()), ("generic", Frame.generic())] {
                let own = (factor: pass.stepFactor, minStep: pass.minStepMM)   // the pass's own values
                pass.stepFactor = 0.2; pass.stepCapOverride = 0.02; pass.minStepMM = 0.005; pass.stepBudget = 30000
                pass.earlyOut = false
                let ref = try renderGBuffer(pass, device: device, frame: fr, size: size, squish: s)
                pass.stepFactor = own.factor; pass.stepCapOverride = nil; pass.minStepMM = own.minStep; pass.stepBudget = FlexibleLatticePass.maxSteps
                pass.earlyOut = true
                func deeper(_ g: GBufferRead) -> (bad: Int, both: Int) {
                    var bad = 0, both = 0
                    for i in 0..<(size * size) where g.alpha[i] >= 128 && ref.alpha[i] >= 128 {
                        both += 1
                        if abs(g.eyeZ[i] - ref.eyeZ[i]) > 0.05 { bad += 1 }
                    }
                    return (bad, both)
                }
                let shipped = deeper(try renderGBuffer(pass, device: device, frame: fr, size: size, squish: s))
                pass.stepCapOverride = 0.5
                let half = deeper(try renderGBuffer(pass, device: device, frame: fr, size: size, squish: s))
                pass.stepCapOverride = nil
                let label = "\(topo) \(faces.isEmpty ? "rest" : "checkerboard press") \(fname)"
                print(String(format: "FLEX-MARCH-DEPTH %@: %d of %d px covered by both differ by > 0.05 mm (%.3f %%); control (half-cell cap) %d (%.3f %%)",
                             label, shipped.bad, shipped.both, 100 * Double(shipped.bad) / Double(max(1, shipped.both)),
                             half.bad, 100 * Double(half.bad) / Double(max(1, half.both))))
                XCTAssertGreaterThan(shipped.both, 1000)
                XCTAssertLessThanOrEqual(Double(shipped.bad), Self.depthBar * Double(shipped.both), "\(label): the march lands on the wrong wall")
                // (the control where the gyroid's cap is what bounds the step: at rest)
                if topo == .gyroid && faces.isEmpty {
                    XCTAssertGreaterThan(Double(half.bad), Self.depthBar * Double(half.both), "control: \(label): a half-cell cap must exceed the bar")
                }
            }
        }
    }

    // MARK: T13 — one upload per token

    @MainActor
    func testApplyUploadsOncePerToken() throws {
        let device = try Fx.device()
        let r = try Fx.renderer(device: device)
        let gyroid = Fx.boxInputs(.gyroid), honey = Fx.boxInputs(.honeycomb)
        XCTAssertFalse(r.applyFlexibleLattice(nil, device: device), "nil with no pass changes nothing")
        XCTAssertTrue(r.applyFlexibleLattice(Fx.layer(gyroid, token: 1), device: device))
        let pass = try XCTUnwrap(r.flexibleLattice)
        XCTAssertEqual(pass.uploadCount, 1)
        // the same token with DIFFERENT grids: equality is by token, so nothing is uploaded
        XCTAssertFalse(r.applyFlexibleLattice(Fx.layer(honey, token: 1), device: device))
        XCTAssertEqual(pass.uploadCount, 1)
        XCTAssertEqual(pass.referenceInputs?.topology, .gyroid)
        // ★ CONTROL: the NEW token is the one that uploads
        XCTAssertTrue(r.applyFlexibleLattice(Fx.layer(honey, token: 2), device: device))
        XCTAssertEqual(pass.uploadCount, 2)
        XCTAssertEqual(pass.referenceInputs?.topology, .honeycomb)
        XCTAssertTrue(r.flexibleLatticeInFrame)
        // hidden flips redraw without re-uploading
        XCTAssertTrue(r.applyFlexibleLattice(Fx.layer(honey, token: 2, hidden: true), device: device))
        XCTAssertEqual(pass.uploadCount, 2)
        XCTAssertFalse(r.flexibleLatticeInFrame)
        XCTAssertFalse(r.applyFlexibleLattice(Fx.layer(honey, token: 2, hidden: true), device: device))
        // nil tears down
        XCTAssertTrue(r.applyFlexibleLattice(nil, device: device))
        XCTAssertNil(r.flexibleLattice)
        XCTAssertFalse(r.flexibleLatticeInFrame)
    }
}
#endif
