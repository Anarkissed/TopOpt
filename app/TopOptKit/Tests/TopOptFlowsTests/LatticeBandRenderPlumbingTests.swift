import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ THE BAND REDESIGN'S RENDERER HALF (2026-09-26): the four appended uniforms, the fine
/// rim texture, the march's rim term, the rim normal and the shell's band rule. Everything
/// here is synthetic — a 40 mm box, one declared face, a hand-made band field — so it runs
/// wherever Metal does. The CPU half (`LatticeBandFields`) is tested on its own. The shared
/// fixtures, and the legacy byte-for-byte golden, are in `LatticeBandLegacyGoldenTests.swift`.
final class LatticeBandRenderPlumbingTests: LatticeBandTestCase {

    // MARK: - the hand-made band

    /// The box's exact signed distance (< 0 inside 0…40³).
    static func boxSDF(_ p: SIMD3<Float>) -> Float {
        let q = simd_abs(p - SIMD3<Float>(repeating: 20)) - SIMD3<Float>(repeating: 20)
        return simd_length(simd_max(q, .zero)) + min(max(q.x, max(q.y, q.z)), 0)
    }

    /// ★ A HAND-MADE BAND: a flat rim slab across the whole box, `2·half` thick about z = z0.
    ///   B_r = |z − z0| − half     (< 0 inside skin ∪ rim)
    ///   K_s = (z0 + half − skin) − z   (the top `skin` mm of the slab is skin: K_s < 0 there)
    ///   dMat = q = the box's own SDF
    /// Fine grid: half the SDF voxel, padded 3.5 texels of air on every side (the contract's
    /// layout). `bandRimCoarse` is B_r on the scene's region grid.
    static func slabBand(for scene: LatticeSDFScene, z0: Float, half: Float = 1.5,
                         skin: Float = 1.0, spacing: Float? = nil) -> (LatticeBandFine, LatticeVoxelGrid) {
        let sp = scene.partSDF.spacing
        let hf = spacing ?? 0.5 * max(sp.x, max(sp.y, sp.z))
        let bmin = scene.bounds.min, bmax = scene.bounds.max
        let origin = bmin - SIMD3<Float>(repeating: 3.5 * hf)
        let ext = bmax - bmin
        let dims = SIMD3<Int32>(Int32((ext.x / hf).rounded(.up)) + 8, Int32((ext.y / hf).rounded(.up)) + 8,
                                Int32((ext.z / hf).rounded(.up)) + 8)
        func channels(_ p: SIMD3<Float>) -> SIMD4<Float> {
            let br = abs(p.z - z0) - half
            let ks = (z0 + half - skin) - p.z
            let dm = boxSDF(p)
            return simd_clamp(SIMD4(br, ks, dm, dm), SIMD4(repeating: -30), SIMD4(repeating: 30))
        }
        var tex = [Float16](repeating: 0, count: 4 * Int(dims.x) * Int(dims.y) * Int(dims.z))
        for k in 0..<Int(dims.z) { for j in 0..<Int(dims.y) { for i in 0..<Int(dims.x) {
            let p = origin + SIMD3<Float>(Float(i), Float(j), Float(k)) * hf
            let c = channels(p)
            let b = 4 * ((k * Int(dims.y) + j) * Int(dims.x) + i)
            tex[b] = Float16(c.x); tex[b + 1] = Float16(c.y); tex[b + 2] = Float16(c.z); tex[b + 3] = Float16(c.w)
        } } }
        let fine = LatticeBandFine(origin: origin, spacing: hf, dims: dims, texels: tex)
        var coarse = scene.regionSDF!
        for k in 0..<coarse.nz { for j in 0..<coarse.ny { for i in 0..<coarse.nx {
            let p = coarse.origin + SIMD3<Float>(Float(i), Float(j), Float(k)) * coarse.spacing
            coarse.values[(k * coarse.ny + j) * coarse.nx + i] = abs(p.z - z0) - half
        } } }
        return (fine, coarse)
    }

    static func bandScene(z0: Float = 20, veil: Bool = false) -> LatticeSDFScene {
        var s = cachedOrganicScene
        let (fine, coarse) = slabBand(for: s, z0: z0)
        s.bandFine = fine
        s.bandRimCoarse = coarse
        s.bandOptions.veil = veil
        return s
    }

    // MARK: - K0: the uniform layout

    /// ★ K0. `LSDFUniforms` is matched Swift ↔ MSL by BYTE OFFSET. A kernel compiled from the
    /// SHIPPING `latticeFieldSource` reports `sizeof(LSDFUniforms)` and the offsets of the four
    /// band fields, and copies them back out: the sizes and offsets must equal Swift's, and
    /// the values must round-trip exactly. CONTROL: the same kernel over the shipping struct's
    /// own text with `bandParams` deleted must report a different size — or this test cannot
    /// see the trap. (All three shipping libraries must also compile: a failed `try?` build
    /// would otherwise only ever show as a skipped render test.)
    @MainActor
    func testUniformLayoutRoundTrips() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("no Metal")
        }
        // every shipping library that carries the field compiles
        for (name, src) in [("unified", unifiedLatticeShaderSource),
                            ("capsule", organicCapsuleShaderSource),
                            ("standalone", LatticeSDFRenderer.shaderSource)] {
            do { _ = try device.makeLibrary(source: src, options: nil) }
            catch { XCTFail("\(name) library does not compile: \(error)") }
        }

        func kernelSource(_ field: String) -> String {
            """
            #include <metal_stdlib>
            using namespace metal;
            \(field)
            kernel void band_layout(constant LSDFUniforms& U [[buffer(0)]],
                                    device float4* out [[buffer(1)]],
                                    device uint* sz [[buffer(2)]],
                                    uint tid [[thread_position_in_grid]]) {
                if (tid != 0) { return; }
                sz[0] = uint(sizeof(LSDFUniforms));
                #ifndef BAND_SIZE_ONLY
                constant char* b = (constant char*)&U;
                sz[1] = uint((constant char*)&U.gradeColor - b);
                sz[2] = uint((constant char*)&U.bandOrigin - b);
                sz[3] = uint((constant char*)&U.bandSpacing - b);
                sz[4] = uint((constant char*)&U.bandDims - b);
                sz[5] = uint((constant char*)&U.bandParams - b);
                out[0] = U.gradeColor; out[1] = U.bandOrigin; out[2] = U.bandSpacing;
                out[3] = U.bandDims; out[4] = U.bandParams; out[5] = U.debugParams;
                #endif
            }
            """
        }
        func run(_ src: String, sizeOnly: Bool, _ u: inout LSDFUniforms) throws -> ([SIMD4<Float>], [UInt32]) {
            let opts = MTLCompileOptions()
            if sizeOnly { opts.preprocessorMacros = ["BAND_SIZE_ONLY": NSNumber(value: 1)] }
            let lib = try device.makeLibrary(source: src, options: opts)
            let fn = try XCTUnwrap(lib.makeFunction(name: "band_layout"))
            let pso = try device.makeComputePipelineState(function: fn)
            let out = try XCTUnwrap(device.makeBuffer(length: 6 * 16, options: .storageModeShared))
            let sz = try XCTUnwrap(device.makeBuffer(length: 6 * 4, options: .storageModeShared))
            let cmd = try XCTUnwrap(queue.makeCommandBuffer())
            let enc = try XCTUnwrap(cmd.makeComputeCommandEncoder())
            enc.setComputePipelineState(pso)
            enc.setBytes(&u, length: MemoryLayout<LSDFUniforms>.stride, index: 0)
            enc.setBuffer(out, offset: 0, index: 1)
            enc.setBuffer(sz, offset: 0, index: 2)
            enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
            let o = Array(UnsafeBufferPointer(start: out.contents().bindMemory(to: SIMD4<Float>.self, capacity: 6), count: 6))
            let s = Array(UnsafeBufferPointer(start: sz.contents().bindMemory(to: UInt32.self, capacity: 6), count: 6))
            return (o, s)
        }

        let r = try XCTUnwrap(LatticeSDFRenderer(device: device, buildPipeline: false))
        var u = r.makeUniforms(aspect: 1)
        XCTAssertEqual(u.bandOrigin, .zero, "no scene ⇒ no band")
        XCTAssertEqual(u.bandParams, .zero)
        u.gradeColor = SIMD4(0.25, 0.5, 0.75, 10)
        u.bandOrigin = SIMD4(-12.5, 3.25, 101.0625, 1)
        u.bandSpacing = SIMD4(0.8594, 0.8594, 0.8594, 0.4297)
        u.bandDims = SIMD4(262, 69, 241, 0)
        u.bandParams = SIMD4(1, 0, 1, 7)
        u.debugParams = SIMD4(0, 0, 2, 0)
        let (vals, sizes) = try run(kernelSource(latticeFieldSource), sizeOnly: false, &u)
        print("BANDPLUMB K0 MSL sizeof \(sizes[0]) Swift stride \(MemoryLayout<LSDFUniforms>.stride) · offsets MSL \(sizes[1...5].map { $0 })")
        XCTAssertEqual(Int(sizes[0]), MemoryLayout<LSDFUniforms>.stride, "sizeof(LSDFUniforms) ≠ the Swift stride")
        XCTAssertEqual(Int(sizes[1]), MemoryLayout<LSDFUniforms>.offset(of: \LSDFUniforms.gradeColor))
        XCTAssertEqual(Int(sizes[2]), MemoryLayout<LSDFUniforms>.offset(of: \LSDFUniforms.bandOrigin))
        XCTAssertEqual(Int(sizes[3]), MemoryLayout<LSDFUniforms>.offset(of: \LSDFUniforms.bandSpacing))
        XCTAssertEqual(Int(sizes[4]), MemoryLayout<LSDFUniforms>.offset(of: \LSDFUniforms.bandDims))
        XCTAssertEqual(Int(sizes[5]), MemoryLayout<LSDFUniforms>.offset(of: \LSDFUniforms.bandParams))
        XCTAssertEqual(vals[0], u.gradeColor)
        XCTAssertEqual(vals[1], u.bandOrigin)
        XCTAssertEqual(vals[2], u.bandSpacing)
        XCTAssertEqual(vals[3], u.bandDims)
        XCTAssertEqual(vals[4], u.bandParams)
        XCTAssertEqual(vals[5], u.debugParams)

        // ★ CONTROL: one appended field dropped on the MSL side must be SEEN as a mismatch.
        // The shipping struct's own text (the helpers below it read `bandParams`, so the
        // whole source would not compile without it), with that one line removed.
        let line = "    float4 bandParams;   // x = veil, y = smooth rim normals, z = region .a is B_r, w reserved\n"
        let src = latticeFieldSource
        let start = try XCTUnwrap(src.range(of: "struct LSDFUniforms {"), "the struct moved")
        let end = try XCTUnwrap(src.range(of: "};", range: start.upperBound..<src.endIndex))
        let structText = String(src[start.lowerBound..<end.upperBound])
        XCTAssertTrue(structText.contains(line), "the control's anchor moved — update it")
        let (_, whole) = try run(kernelSource(structText), sizeOnly: true, &u)
        let (_, bsz) = try run(kernelSource(structText.replacingOccurrences(of: line, with: "")), sizeOnly: true, &u)
        print("BANDPLUMB K0 control: MSL sizeof, struct alone \(whole[0]) · without bandParams \(bsz[0])")
        XCTAssertEqual(Int(whole[0]), MemoryLayout<LSDFUniforms>.stride, "the extracted struct is the shipping one")
        XCTAssertNotEqual(Int(bsz[0]), MemoryLayout<LSDFUniforms>.stride, "the control did not go red")
    }

    // MARK: - K12: the GPU sampler equals the CPU twin

    /// ★ K12. A kernel samples the REAL rim texture (the renderer's packer, via
    /// `bandRimTexture`) through the SHIPPING `band_uvw` with the renderer's OWN uniforms, at
    /// 2,000 seeded points spread over the grid and a texel beyond it, and compares every
    /// channel with `LatticeBandFine.sample`: p100 ≤ 0.01 mm, p50 ≤ 0.002 mm. Run at the box's
    /// own fine texel (0.31 mm) and at his stand's (0.8594 mm). CONTROL: the CPU mapping
    /// shifted +0.5 texel on every axis must fail the bar tenfold at both, and by ≥ 0.2 mm at
    /// his texel (the plan's number, derived there).
    @MainActor
    func testTheGPUSamplerMatchesTheCPUTwin() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("no Metal")
        }
        let boxScene = Self.bandScene()
        var hisScene = Self.cachedOrganicScene
        let (hisFine, hisCoarse) = Self.slabBand(for: hisScene, z0: 20, spacing: 0.8594)
        hisScene.bandFine = hisFine; hisScene.bandRimCoarse = hisCoarse
        for (label, scene) in [("box texel", boxScene), ("his texel", hisScene)] {
            let (err, errShift) = try Self.k12(scene, label: label, device: device, queue: queue)
            let fine = try XCTUnwrap(scene.bandFine)
            XCTAssertLessThanOrEqual(err.max() ?? 1, 0.01, "\(label): the GPU read disagrees with the CPU twin (p100)")
            XCTAssertLessThanOrEqual(err.sorted()[err.count / 2], 0.002, "\(label): …(p50)")
            XCTAssertGreaterThanOrEqual(errShift.max() ?? 0, 0.1, "\(label): the control did not go red — K12 is powerless")
            if fine.spacing > 0.8 {
                XCTAssertGreaterThanOrEqual(errShift.max() ?? 0, 0.2, "\(label): the control did not reach 0.2 mm")
            }
        }
    }

    @MainActor
    static func k12(_ scene: LatticeSDFScene, label: String, device: MTLDevice,
                    queue: MTLCommandQueue) throws -> (err: [Float], shifted: [Float]) {
        let fine = try XCTUnwrap(scene.bandFine)
        let r = try XCTUnwrap(LatticeSDFRenderer(device: device, buildPipeline: false))
        r.drawOrganicCapsules = true
        r.setScene(scene)
        XCTAssertTrue(r.capsulesReplaceField)
        let u0 = r.makeUniforms(aspect: 1)
        XCTAssertEqual(u0.bandOrigin, SIMD4(fine.origin, 1), "the band's origin/enable")
        XCTAssertEqual(u0.bandSpacing.x, fine.spacing)
        XCTAssertEqual(u0.bandDims, SIMD4(Float(fine.dims.x), Float(fine.dims.y), Float(fine.dims.z), 0))
        let voxel = max(scene.partSDF.spacing.x, max(scene.partSDF.spacing.y, scene.partSDF.spacing.z))
        XCTAssertEqual(u0.bandSpacing.w, 0.25 * voxel, accuracy: 1e-6, "e_x = a quarter SDF voxel")
        XCTAssertEqual(u0.bandParams.x, 0, "veil off by default")
        XCTAssertEqual(u0.bandParams.z, 1, "the region's .a carries B_r")
        let tex = try XCTUnwrap(r.bandRimTexture)
        XCTAssertEqual(tex.pixelFormat, .rgba16Float)
        XCTAssertEqual([tex.width, tex.height, tex.depth], [Int(fine.dims.x), Int(fine.dims.y), Int(fine.dims.z)])

        // ★ capsules OFF: the band is not drawn, but the legacy rim must know `.a` is B_r
        r.drawOrganicCapsules = false
        let uOff = r.makeUniforms(aspect: 1)
        XCTAssertEqual(uOff.bandOrigin.w, 0, "no capsules ⇒ the band is not drawn")
        XCTAssertEqual(uOff.bandParams.z, 1, "…and the legacy rim is told the region's .a is B_r")

        let src = """
        #include <metal_stdlib>
        using namespace metal;
        \(latticeFieldSource)
        kernel void band_sample(constant LSDFUniforms& U [[buffer(0)]],
                                const device float4* pts [[buffer(1)]],
                                device float4* out [[buffer(2)]],
                                constant uint& count [[buffer(3)]],
                                texture3d<float> rimTex [[texture(0)]],
                                sampler samp [[sampler(0)]],
                                uint tid [[thread_position_in_grid]]) {
            if (tid >= count) { return; }
            out[tid] = rimTex.sample(samp, band_uvw(U, pts[tid].xyz));
        }
        """
        let lib = try device.makeLibrary(source: src, options: nil)
        let pso = try device.makeComputePipelineState(function: try XCTUnwrap(lib.makeFunction(name: "band_sample")))
        // the renderer's sampler: linear min/mag, clamp-to-edge, no mips (`LatticeSDFRenderer.init`)
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge; sd.rAddressMode = .clampToEdge
        let samp = try XCTUnwrap(device.makeSamplerState(descriptor: sd))

        var rng: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Float { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Float(rng >> 40) / Float(1 << 24) }
        let n = 2000
        let lo = fine.origin - SIMD3<Float>(repeating: fine.spacing)
        let span = SIMD3<Float>(fine.dims &+ 1) * fine.spacing
        var pts = [SIMD4<Float>]()
        for _ in 0..<n { pts.append(SIMD4(lo + SIMD3(rnd(), rnd(), rnd()) * span, 0)) }
        var count = UInt32(n)
        var u = u0
        let pbuf = try XCTUnwrap(device.makeBuffer(bytes: pts, length: 16 * n, options: .storageModeShared))
        let obuf = try XCTUnwrap(device.makeBuffer(length: 16 * n, options: .storageModeShared))
        let cmd = try XCTUnwrap(queue.makeCommandBuffer())
        let enc = try XCTUnwrap(cmd.makeComputeCommandEncoder())
        enc.setComputePipelineState(pso)
        enc.setBytes(&u, length: MemoryLayout<LSDFUniforms>.stride, index: 0)
        enc.setBuffer(pbuf, offset: 0, index: 1)
        enc.setBuffer(obuf, offset: 0, index: 2)
        enc.setBytes(&count, length: 4, index: 3)
        enc.setTexture(tex, index: 0)
        enc.setSamplerState(samp, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: (n + 63) / 64, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
        let gpu = UnsafeBufferPointer(start: obuf.contents().bindMemory(to: SIMD4<Float>.self, capacity: n), count: n)

        var err: [Float] = [], errNear: [Float] = [], errShift: [Float] = []
        let shift = SIMD3<Float>(repeating: 0.5 * fine.spacing)
        for i in 0..<n {
            let p = SIMD3<Float>(pts[i].x, pts[i].y, pts[i].z)
            let c = fine.sample(p), cs = fine.sample(p + shift)
            for ch in 0..<4 {
                let e = abs(gpu[i][ch] - c[ch])
                err.append(e)
                if abs(c[ch]) <= 8 { errNear.append(e) }     // where every rim surface lies (reported only)
                errShift.append(abs(gpu[i][ch] - cs[ch]))
            }
        }
        func dist(_ a: [Float]) -> String {
            let s = a.sorted()
            func q(_ f: Double) -> Float { s[min(s.count - 1, Int(f * Double(s.count - 1)))] }
            return String(format: "n %d min %.5f p05 %.5f p50 %.5f p95 %.5f max %.5f", s.count, q(0), q(0.05), q(0.5), q(0.95), q(1))
        }
        print("BANDPLUMB K12 [\(label) \(fine.spacing) mm] |GPU−CPU| all channels: \(dist(err))")
        print("BANDPLUMB K12 [\(label)] |GPU−CPU| where |value| ≤ 8 mm: \(dist(errNear))")
        print("BANDPLUMB K12 [\(label)] control (+0.5 texel): \(dist(errShift))")
        return (err, errShift)
    }

    // MARK: - the band, rendered end to end

    /// ★ The slab rim is drawn by the march off the fine grid, in the rim colour, where the
    /// field puts it (it MOVES with z0), with the veil drawing grey skin over it, and with the
    /// rim normal's control changing only the shading. The legacy scene draws no rim here.
    @MainActor
    func testTheBandRimIsDrawnFromTheFineGrid() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let legacy = try Self.frames(Self.cachedOrganicScene, device: device, tag: "legacy", body: false)
        let band = try Self.frames(Self.bandScene(z0: 20), device: device, tag: "band20", body: false)
        let low = try Self.frames(Self.bandScene(z0: 12), device: device, tag: "band12", body: false)
        let high = try Self.frames(Self.bandScene(z0: 28), device: device, tag: "band28", body: false)
        let veil = try Self.frames(Self.bandScene(z0: 20, veil: true), device: device, tag: "veil20", body: false)
        for f in legacy + band + low + high + veil { Self.log(f, "e2e") }
        for i in 0..<Self.views.count {
            XCTAssertEqual(legacy[i].rimPx, 0, "\(legacy[i].name): the box's legacy scene draws no rim")
            XCTAssertGreaterThan(band[i].rimPx, 1500, "\(band[i].name): the band rim is not drawn")
            XCTAssertNotEqual(band[i].hash, legacy[i].hash, "\(band[i].name): the band changed nothing")
            XCTAssertLessThanOrEqual(band[i].greyPx, 20, "\(band[i].name): skin grey without the veil")
            XCTAssertGreaterThan(veil[i].greyPx, 500, "\(veil[i].name): the veil draws no skin")
        }
        // ★ THE RIM FOLLOWS THE FIELD: moving the slab from z0 = 12 to 28 must move the rim's
        // pixels the way the frame's own transform moves the slab's centre (the model's z is
        // not the screen's up — the viewer draws in the stage frame).
        func screen(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD2<Double> {
            let c = m * SIMD4<Float>(p, 1)
            return SIMD2(Double((c.x / c.w + 1) * 0.5 * 400), Double((1 - c.y / c.w) * 0.5 * 400))
        }
        for i in 0..<Self.views.count {
            let m = try XCTUnwrap(band[i].mvp)
            let want = screen(m, SIMD3(20, 20, 28)) - screen(m, SIMD3(20, 20, 12))
            let got = high[i].rimCentroid - low[i].rimCentroid
            let cosA = simd_dot(want, got) / max(simd_length(want) * simd_length(got), 1e-9)
            print(String(format: "BANDPLUMB e2e %@ rim centroid z0 12→28 moved (%.1f, %.1f) px; the slab's centre projects (%.1f, %.1f) px; cos %.3f",
                         Self.views[i].0, got.x, got.y, want.x, want.y, cosA))
            XCTAssertGreaterThan(simd_length(want), 20, "\(Self.views[i].0): the check needs a visible move")
            XCTAssertGreaterThan(cosA, 0.8, "\(Self.views[i].0): the rim does not move with the field")
            XCTAssertGreaterThan(simd_length(got), 0.4 * simd_length(want), "\(Self.views[i].0): the rim barely moved")
        }

        // ★ THE NORMAL CONTROL (debugParams.z = 1 ⇒ the legacy `lsdf_normal`): same albedo,
        // different shading
        let r = try Self.renderer(Self.bandScene(z0: 20), device: device)
        r.camera.setOrientation(azimuth: 0.6, elevation: 0.35)
        r.setBodyAlpha(0)
        let clear = MTLClearColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
        let prod = try XCTUnwrap(r.renderOffscreen(size: 400, clear: clear))
        let prodMask = try XCTUnwrap(r.latticeMaskDump(size: 400))
        r.latticeLayerForTests?.bandNormalControl = 1
        let ctrl = try XCTUnwrap(r.renderOffscreen(size: 400, clear: clear))
        let ctrlMask = try XCTUnwrap(r.latticeMaskDump(size: 400))
        var moved = 0
        for i in 0..<min(prod.count, ctrl.count) where prod[i] != ctrl[i] { moved += 1 }
        print("BANDPLUMB normal control: \(moved) bytes differ between the band normal and lsdf_normal")
        XCTAssertEqual(prodMask.rgb, ctrlMask.rgb, "the normal control must not change the albedo")
        XCTAssertGreaterThan(moved, 1000, "the rim normal is not the one the frame is shaded with")
    }

    /// ★ The shell's band margin: armed at half the region voxel when the scene has a band,
    /// zero (the legacy declared-face rule) when it does not.
    @MainActor
    func testTheShellArmsTheBandRuleOnlyWithABand() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let legacy = try Self.renderer(Self.cachedOrganicScene, device: device)
        XCTAssertEqual(legacy.shellClipForTests.gate.w, 0, "no band ⇒ the band rule is off")
        let band = try Self.renderer(Self.bandScene(), device: device)
        let g = try XCTUnwrap(Self.cachedOrganicScene.regionSDF)
        let voxel = max(g.spacing.x, max(g.spacing.y, g.spacing.z))
        XCTAssertEqual(band.shellClipForTests.gate.w, 0.5 * voxel, accuracy: 1e-6)
        XCTAssertEqual(band.shellClipForTests.spacing.w, voxel, accuracy: 1e-6, "the nudge stays one voxel")
    }
}
