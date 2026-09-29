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
        u.tail = v()
        var expected = [u.boxMin, u.boxMax, u.shape, u.shape2, u.buildDir, u.rmO, u.rmN, u.dsO, u.dsN,
                        u.squish, u.march]
        for f in [u.faces.0, u.faces.1, u.faces.2, u.faces.3] { expected += [f.centroid, f.xAxis, f.yAxis, f.load, f.extent] }
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
            var tail = SIMD4<Float>.zero
        }
        var s = Swapped()
        s.boxMin = u.boxMin; s.boxMax = u.boxMax; s.shape = u.shape; s.shape2 = u.shape2; s.buildDir = u.buildDir
        s.rmO = u.rmO; s.rmN = u.rmN; s.dsO = u.dsO; s.dsN = u.dsN; s.squish = u.squish; s.march = u.march
        s.faces = u.faces; s.tail = u.tail
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

    // MARK: T10 (eye depth) — the G-buffer's eye-Z is the hit's

    /// Renders the pass alone into a G-buffer of the renderer's formats, with the matrices
    /// MeshRenderer.makeUniforms composes (P·V·M, V·M, the rotation of V·M), and reads back
    /// eye-Z and the albedo mask.
    struct GBufferRead { var eyeZ: [Float]; var alpha: [UInt8]; var size: Int }

    func renderGBuffer(_ pass: FlexibleLatticePass, device: MTLDevice, camera cam: OrbitCamera,
                       settle: simd_quatf, centre: SIMD3<Float>, size: Int) throws -> GBufferRead {
        let model = ViewerModelFrame.matrix(centre: centre, rotation: settle)
        let mv = cam.viewMatrix() * model
        let mvp = cam.projectionMatrix(aspect: 1) * mv
        let nb = simd_float4x4(columns: (SIMD4(mv.columns.0.x, mv.columns.0.y, mv.columns.0.z, 0),
                                         SIMD4(mv.columns.1.x, mv.columns.1.y, mv.columns.1.z, 0),
                                         SIMD4(mv.columns.2.x, mv.columns.2.y, mv.columns.2.z, 0), SIMD4(0, 0, 0, 1)))
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
        XCTAssertTrue(pass.encodeGBuffer(enc, depthState: ds, camera: cam, modelRotation: settle, modelCenter: centre,
                                         aspect: 1, clipFromModel: mvp, eyeFromModel: mv, eyeNormalBasis: nb, squish: 0))
        enc.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        var eyeZ = [Float](repeating: 0, count: size * size)
        z.getBytes(&eyeZ, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        a.getBytes(&rgba, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        return GBufferRead(eyeZ: eyeZ, alpha: stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }, size: size)
    }

    func testGBufferEyeZIsTheHitsEyeDepth() throws {
        let device = try Fx.device()
        let pass = try FlexibleLatticePass(device: device)
        pass.upload(Fx.layer(Fx.boxInputs(.honeycomb), token: 1))
        let f = try XCTUnwrap(pass.referenceInputs)
        var cam = OrbitCamera()
        cam.frame(MeshBounds(min: SIMD3(0, 0, 0), max: SIMD3(40, 40, 20), isEmpty: false))
        cam.setOrientation(azimuth: 0.65, elevation: 0.5)
        let settle = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let centre = SIMD3<Float>(20, 20, 10)
        let size = 256
        let g = try renderGBuffer(pass, device: device, camera: cam, settle: settle, centre: centre, size: size)
        let mv = cam.viewMatrix() * ViewerModelFrame.matrix(centre: centre, rotation: settle)
        let basis = FlexibleLatticePass.rayBasis(camera: cam, modelRotation: settle, modelCenter: centre, aspect: 1)
        var checked = 0, worst: Float = 0, worstNoSettle: Float = .infinity
        var sNoSettle: [Float] = []
        // interior pixels of walls (all four neighbours covered), a sparse lattice of them
        for py in stride(from: 8, to: size - 8, by: 7) { for px in stride(from: 8, to: size - 8, by: 7) {
            let i = py * size + px
            guard g.alpha[i] >= 128, g.alpha[i - 1] >= 128, g.alpha[i + 1] >= 128,
                  g.alpha[i - size] >= 128, g.alpha[i + size] >= 128 else { continue }
            let uv = SIMD2<Float>((Float(px) + 0.5) / Float(size) * 2 - 1, 1 - (Float(py) + 0.5) / Float(size) * 2)
            let rd = simd_normalize(basis.rayDir + basis.rayX * uv.x + basis.rayY * uv.y)
            // the reference: sphere-trace the Swift field to its first zero, then bisect
            var t: Float = 0, prev: Float = 0, hit: SIMD3<Float>?
            for _ in 0..<20000 {
                let v = FlexibleLatticeField.lattice(at: basis.eye + rd * t, f)
                if v < 0 {
                    var lo = prev, hi = t
                    for _ in 0..<30 { let m = 0.5 * (lo + hi); if FlexibleLatticeField.lattice(at: basis.eye + rd * m, f) < 0 { hi = m } else { lo = m } }
                    hit = basis.eye + rd * hi
                    break
                }
                prev = t
                t += max(0.4 * v, 0.004)
                if t > 1e4 { break }
            }
            guard let h = hit else { continue }
            let want = -(mv * SIMD4(h, 1)).z
            worst = max(worst, abs(g.eyeZ[i] - want))
            // ★ RED CONTROL: the view alone, without the settled model frame, is the wrong depth
            let noSettle = -(cam.viewMatrix() * SIMD4(h, 1)).z
            sNoSettle.append(abs(g.eyeZ[i] - noSettle))
            checked += 1
        } }
        worstNoSettle = sNoSettle.sorted()[sNoSettle.count / 2]   // the TYPICAL miss (median)
        print("FLEX-EYEZ \(checked) wall pixels: max |gbuffer eyeZ − (−(V·M·hit).z)| = \(worst) mm; control without the settle: median miss \(worstNoSettle) mm")
        XCTAssertGreaterThan(checked, 30)
        XCTAssertLessThanOrEqual(worst, 0.02)
        XCTAssertGreaterThan(worstNoSettle, 0.5, "control: the model frame must matter")
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
