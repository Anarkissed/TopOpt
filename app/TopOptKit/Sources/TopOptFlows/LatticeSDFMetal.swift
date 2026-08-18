// LatticeSDFMetal.swift — the RAYMARCHED lattice preview (handoff
// 2026-07-29-lattice-preview). It shows the maintainer the ACTUAL struts he is about
// to print, with ZERO lattice triangles on the device, using the exact technique the
// transform gizmo proved on this hardware (PR 205): a strut lattice is an analytic
// distance field, so a fragment shader sphere-traces it PER PIXEL. The cost is
// per-pixel, not per-triangle, so it does NOT grow as (1/cell)³ the way a real
// lattice mesh does (368 k tris → 2.9 M → PR-184's 2.8 GB over the iOS ceiling).
//
// The field is the periodic union of the lattice's struts (`LatticeSDFPreview`,
// derived from the worker's own cell table), tiled by folding the world point into
// one cell. It is masked to the part in two composed stages:
//   • WHOLE-CELL emission (round 2) — the worker's canonical-midpoint ownership: a
//     strut exists iff its OWNING cell overlaps the part (`cellField`), so no cell
//     is ever lost to a knife-edge test;
//   • a FLUSH TRIM (round 3) — CSG-intersecting the strut field with the part's
//     exact narrow-band signed-distance field, so struts are cut flush at the
//     surface like a machined section. Flat faces interpolate exactly through the
//     trilinear SDF, so the part's straight edges render STRAIGHT at every cell
//     size — and the boundary is what production's owed lattice∪wall union yields.
// Strut radius is GRADED per owning cell by the demand baked into the same field,
// so a graded lattice (the feature) is shown directly.
//
// P2 (no per-frame regeneration): there is no geometry to regenerate. The per-cell
// texture is baked once on a data or cell-size change; orbiting only re-runs the
// fragment shader with a new camera matrix. The MTKView is `isPaused` +
// redraw-on-demand, exactly like the gizmo. `draw()` asserts no bake happens inside
// a frame.

#if canImport(MetalKit)
import MetalKit
import SwiftUI
import Combine
import simd
import TopOptDesign
import TopOptKit

// MARK: - Uniforms (layout MUST match the MSL struct)

struct LSDFUniforms {
    // Per-pixel ray basis in MODEL space, computed exactly on the CPU (no matrix
    // inversion anywhere in the ray path): rd = normalize(rayDir + rayX·u + rayY·v).
    // Unprojecting clip corners through inv(P·V·model) — the previous scheme — hits
    // catastrophic cancellation in w at the far plane (terms of ~1 summing to ~1e-4
    // in Float), which warped rays by 1–4 px and swam during orbit (bars A1/A2).
    var rayX: SIMD4<Float>                    // camera right · tan(fovY/2)·aspect (model space)
    var rayY: SIMD4<Float>                    // camera up · tan(fovY/2) (model space)
    var rayDir: SIMD4<Float>                  // camera forward (unit, model space)
    var eye: SIMD4<Float>                     // xyz camera position in MODEL space
    var bboxMin: SIMD4<Float>                 // part AABB (ray clip)
    var bboxMax: SIMD4<Float>
    var gridOrigin: SIMD4<Float>              // per-CELL field: cell-(0,0,0) centre (== part min)
    var gridSpacing: SIMD4<Float>             // per-CELL field: cellMM per axis
    var gridDims: SIMD4<Float>                // per-CELL field dims (ncx, ncy, ncz)
    var sdfOrigin: SIMD4<Float>               // part-SDF grid voxel-(0,0,0) centre
    var sdfSpacing: SIMD4<Float>              // part-SDF grid spacing (mm per axis)
    var sdfDims: SIMD4<Float>                 // part-SDF grid dims
    var latticeOrigin: SIMD4<Float>           // xyz cell origin; w = cell size (mm)
    var gradeParams: SIMD4<Float>             // rhoMin, rhoMax, gamma, K
    var shadeParams: SIMD4<Float>             // uniformRho, hasDemand, radiusFloorNorm, maxSteps
    var stepParams: SIMD4<Float>              // stepScale, trimErosion(mm), hasTint, segCount
    var lightDir: SIMD4<Float>                // xyz key light (model space — world light un-settled)
    var sparseColor: SIMD4<Float>            // rgb (sparse end of the indigo ramp)
    var denseColor: SIMD4<Float>             // rgb (dense end)
    // ── UNIFIED PASS ONLY (task 2026-08-18-unified-shading). The clip and eye
    // transforms the BODY is drawn with, so a marched hit can be written into the
    // SHARED depth buffer and the SHARED G-buffer of `MeshRenderer`'s own passes.
    // Identity for the standalone preview renderer, which never reads them — its
    // fragment function has no depth output and no G-buffer to write.
    var clipFromModel: simd_float4x4 = matrix_identity_float4x4
    var eyeFromModel: simd_float4x4 = matrix_identity_float4x4
    var eyeNormalBasis: simd_float4x4 = matrix_identity_float4x4
}

/// The immutable per-part scene the preview needs. Baking depends ONLY on the mesh
/// (occupancy) and the field (demand) — never on the interactive params — so it is
/// built once on a data change (bar P2 / V3).
public struct LatticeSDFScene {
    public var preview: LatticeSDFPreview
    public var occupancy: LatticeVoxelGrid
    /// Truncated signed distance of the part (mm, negative inside) — the flush
    /// boundary trim (round 3). Exact near the surface, so flat faces render straight.
    public var partSDF: LatticeVoxelGrid
    public var demand: LatticeVoxelGrid?
    public var bounds: MeshBounds
    /// The part mesh the scene was baked from (COW — shares storage with the viewer's
    /// copy). Kept so face-role tints can be re-baked onto the lattice whenever the
    /// selection changes WITHOUT rebuilding the whole scene (bar A4).
    public var mesh: ViewerMesh

    public init(mesh: ViewerMesh, field: StressField?, latticeID: String, maxDim: Int = 128) {
        self.preview = LatticeSDFPreview(latticeID: latticeID)
        self.occupancy = LatticePreviewOccupancy.occupancy(
            positions: mesh.positions, indices: mesh.indices, bounds: mesh.bounds, maxDim: maxDim)
        self.partSDF = LatticePreviewOccupancy.signedDistance(
            positions: mesh.positions, indices: mesh.indices, like: occupancy)
        self.demand = LatticePreviewOccupancy.demand(like: occupancy, field: field)
        self.bounds = mesh.bounds
        self.mesh = mesh
    }
}

public extension LatticeSDFScene {
    /// The demand field the strut preview grades by AFTER a run (follow-up shipped
    /// with the maintainer's direct permission — see the handoff): the von Mises
    /// field of the NEWEST accepted variant carrying one, on the run's own grid.
    /// The savings ladder streams variants lighter-first-to-lightest-last, so the
    /// last accepted is the ladder's recommendation tier. Returns nil pre-run, for
    /// a cancelled run, or when no accepted variant carries a field (a remote run
    /// whose fields.bin fetch failed) — the preview then stays uniform and honest,
    /// exactly like the density proxy's no-field case.
    static func demandField(from outcome: OptimizeOutcome?) -> StressField? {
        guard let o = outcome else { return nil }
        for v in o.variants.reversed() where v.accepted && !v.vonMisesField.isEmpty {
            let f = StressField(nx: o.gridNx, ny: o.gridNy, nz: o.gridNz,
                                origin: SIMD3<Float>(o.gridOrigin), spacing: Float(o.spacing),
                                values: v.vonMisesField)
            if !f.isEmpty { return f }
        }
        return nil
    }
}

/// ★ NOT `@MainActor` (task 2026-08-18-unified-shading). It was, and `MeshRenderer` —
/// which is not, because `MTKViewDelegate` callbacks are not — could not touch it to
/// draw the lattice inside its own passes. It is the same class it was, driven from the
/// same main thread by the same callers; `MeshRenderer` next door has carried exactly
/// this shape (an NSObject MTKViewDelegate holding Metal objects) since M7.
final class LatticeSDFRenderer: NSObject, MTKViewDelegate {
    static var lastInitError: String?
    static let maxDPR: CGFloat = 2.0

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    /// The standalone transparent-layer pipeline. Nil when this instance exists only
    /// to OWN AND BAKE the lattice's volumes for `MeshRenderer`'s unified pass
    /// (`init(device:buildPipeline:)`) — that pass has its own pipelines, and
    /// compiling this one there would pay for a shader nobody in that path runs.
    private let pipeline: MTLRenderPipelineState?
    private let sampler: MTLSamplerState

    // Scene resources (rebuilt only on a data/param change — never per frame).
    // `cellTex` is the per-LATTICE-CELL activation+demand field (cellField): the
    // shader shows a strut iff its OWNING cell is active — the worker's whole-cell
    // emission — so the boundary is complete cells, never razor-cut struts.
    private var cellTex: MTLTexture?
    private var cellGrid: LatticeVoxelGrid?
    private var sdfTex: MTLTexture?
    // Face-role tints on the LATTICE (bar A4): an rgba8 volume on the part-SDF grid,
    // baked from the SAME [FaceID: color] dictionary the mesh view tints the body
    // with — one source of truth, no second colour table. nil = no marked faces
    // (a 1×1×1 zero dummy is bound so the pipeline layout never changes).
    private var tintTex: MTLTexture?
    private lazy var dummyTintTex: MTLTexture? = makeDummyTintTexture()
    private var segBuffer: MTLBuffer?
    private var segCount: Int = 0
    private(set) var scene: LatticeSDFScene?

    // Interactive state. A cell-size change moves the lattice cells, so the per-cell
    // field rebakes ONCE on assignment (main thread, milliseconds) — still nothing
    // per frame; orbiting only changes the camera uniform.
    var camera = OrbitCamera()
    var params = LatticeProxyParams() {
        didSet {
            if params.cellMM != oldValue.cellMM, scene != nil { rebakeCellField() }
        }
    }

    // THE ONE MODEL TRANSFORM (2026-07-30 alignment fix). The mesh view draws the
    // body with mvp = P · V · T(centre) · R_settle · T(−centre) — the gravity settle
    // rotation about the model centre (MeshRenderer.makeUniforms/modelMatrix). The
    // lattice pass previously used P · V alone, so a settled part rendered its
    // lattice in the UN-settled frame: offset on some parts, floating clear on
    // others. These two fields carry the SAME (rotation, centre) the workspace hands
    // the mesh view, and `modelViewProjection` composes the identical matrix — one
    // transform, one camera, both derived from the shared workspace source.
    var modelRotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    var modelCenter = SIMD3<Float>.zero
    /// The viewport aspect (SwiftUI points) the SHARED scene is projected at. The
    /// lattice drawable is resolution-capped, so its own pixel dimensions round to
    /// integers a hair off the true viewport ratio; using the viewport's ratio keeps
    /// the lattice projection identical to the body's instead of scaled by ~1e-3.
    /// nil (offscreen tests) falls back to the drawable ratio.
    var viewportAspect: Float?

    /// Bumps every time a texture/segment buffer is (re)built.
    /// `LatticeSDFAlignmentTests.testNoBakeAcrossDrawsOrShadeParamChanges` asserts it
    /// does NOT change across encoded frames or shade-only param changes (Release
    /// builds strip `assert`, so the draw()-side assert alone proves nothing) — the
    /// P2 invariant that no bake happens per frame.
    private(set) var bakeGeneration: Int = 0

    /// - Parameter buildPipeline: `false` builds a BAKE-ONLY instance — the volumes,
    ///   the segment soup, the uniforms and nothing that draws. That is what
    ///   `MeshRenderer` holds for the unified pass (task 2026-08-18-unified-shading):
    ///   it owns its own colour and G-buffer pipelines, so compiling the standalone
    ///   transparent-layer one beside them would be a shader nobody there runs.
    init?(device: MTLDevice, buildPipeline: Bool = true) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { Self.lastInitError = "queue nil"; return nil }
        self.queue = queue
        if buildPipeline {
            let lib: MTLLibrary
            do { lib = try device.makeLibrary(source: Self.shaderSource, options: nil) }
            catch { Self.lastInitError = "makeLibrary: \(error)"; return nil }
            guard let vfn = lib.makeFunction(name: "lsdf_vertex"),
                  let ffn = lib.makeFunction(name: "lsdf_fragment") else {
                Self.lastInitError = "makeFunction nil"; return nil
            }
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = vfn
            pd.fragmentFunction = ffn
            pd.colorAttachments[0].pixelFormat = .bgra8Unorm
            pd.colorAttachments[0].isBlendingEnabled = true
            pd.colorAttachments[0].rgbBlendOperation = .add
            pd.colorAttachments[0].alphaBlendOperation = .add
            pd.colorAttachments[0].sourceRGBBlendFactor = .one
            pd.colorAttachments[0].sourceAlphaBlendFactor = .one
            pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do { pipeline = try device.makeRenderPipelineState(descriptor: pd) }
            catch { Self.lastInitError = "pipeline: \(error)"; return nil }
        } else {
            pipeline = nil
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge; sd.rAddressMode = .clampToEdge
        guard let smp = device.makeSamplerState(descriptor: sd) else { Self.lastInitError = "sampler nil"; return nil }
        self.sampler = smp
        super.init()
    }

    // MARK: scene upload (the only place textures/segments change — bar P2)

    func setScene(_ scene: LatticeSDFScene) {
        self.scene = scene
        // ONE camera: this renderer's `camera` is purely a mirror of the shared
        // OrbitCameraModel (bound by the coordinator). It must NOT re-frame itself
        // here — the mesh view frames the shared model when a mesh lands, and that
        // framed camera is what both passes draw with. (Offscreen tests frame their
        // local camera explicitly.)
        uploadSegments(scene.preview.segments)
        sdfTex = makeVolumeTexture(scene.partSDF)
        tintTex = nil          // stale mesh/grid — the host re-applies tints after setScene
        rebakeCellField()
    }

    /// Bake (or clear) the face-role tint volume from the mesh view's OWN tint
    /// dictionary (bar A4 — one source of truth for the colours). Called by the host
    /// only when the tints or the scene actually change — never per frame (P2).
    func setFaceTints(_ tints: [FaceID: SIMD4<Float>]) {
        guard let scene else { return }
        if tints.isEmpty {
            if tintTex != nil { tintTex = nil; bakeGeneration &+= 1 }
            return
        }
        guard let rgba = LatticeFaceTintVolume.bake(mesh: scene.mesh, tints: tints,
                                                    like: scene.partSDF) else {
            if tintTex != nil { tintTex = nil; bakeGeneration &+= 1 }
            return
        }
        tintTex = makeTintTexture(rgba, like: scene.partSDF)
        bakeGeneration &+= 1
    }

    /// Bake the per-cell activation+demand texture for the CURRENT cell size. Called
    /// from `setScene` and from a cell-size param change — never from `draw`.
    private func rebakeCellField() {
        guard let scene else { return }
        let grid = LatticePreviewOccupancy.cellField(
            occupancy: scene.occupancy, demand: scene.demand, cellMM: params.cellMM)
        cellGrid = grid
        cellTex = makeVolumeTexture(grid)
        bakeGeneration &+= 1
    }

    private func makeVolumeTexture(_ grid: LatticeVoxelGrid) -> MTLTexture? {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .r16Float
        d.width = grid.nx; d.height = grid.ny; d.depth = grid.nz
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        // Convert Float → Float16 (r16Float) contiguously, x fastest.
        var halfs = [UInt16](repeating: 0, count: grid.values.count)
        for (n, v) in grid.values.enumerated() { halfs[n] = float32to16(v) }
        halfs.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake3D(0, 0, 0, grid.nx, grid.ny, grid.nz),
                        mipmapLevel: 0, slice: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: grid.nx * 2,
                        bytesPerImage: grid.nx * grid.ny * 2)
        }
        return tex
    }

    private func makeTintTexture(_ rgba: [UInt8], like grid: LatticeVoxelGrid) -> MTLTexture? {
        guard rgba.count == grid.count * 4 else { return nil }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba8Unorm
        d.width = grid.nx; d.height = grid.ny; d.depth = grid.nz
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        rgba.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake3D(0, 0, 0, grid.nx, grid.ny, grid.nz),
                        mipmapLevel: 0, slice: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: grid.nx * 4,
                        bytesPerImage: grid.nx * grid.ny * 4)
        }
        return tex
    }

    /// A 1×1×1 transparent tint volume bound when no faces are marked, so the
    /// fragment argument table is identical with and without tints.
    private func makeDummyTintTexture() -> MTLTexture? {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba8Unorm
        d.width = 1; d.height = 1; d.depth = 1
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        var zero: [UInt8] = [0, 0, 0, 0]
        tex.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1), mipmapLevel: 0, slice: 0,
                    withBytes: &zero, bytesPerRow: 4, bytesPerImage: 4)
        return tex
    }

    private func uploadSegments(_ segs: [LatticeSegment]) {
        segCount = segs.count
        guard segCount > 0 else { segBuffer = nil; return }
        var packed = [SIMD4<Float>]()
        packed.reserveCapacity(segCount * 2)
        // a.w carries the packed owner-cell index (0…26); b.w is spare.
        for s in segs { packed.append(SIMD4(s.a, Float(s.ownerIndex))); packed.append(SIMD4(s.b, 0)) }
        segBuffer = device.makeBuffer(bytes: packed,
                                      length: MemoryLayout<SIMD4<Float>>.stride * packed.count,
                                      options: .storageModeShared)
    }

    // MARK: uniforms

    /// The model matrix the BODY is drawn with: the settle rotation about the model
    /// centre — the exact composition `MeshRenderer.modelMatrix()` uses (T·R·T⁻¹),
    /// built from the same (rotation, centre) the workspace hands both views.
    private func modelMatrix() -> simd_float4x4 {
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(modelCenter, 1)
        var tInv = matrix_identity_float4x4
        tInv.columns.3 = SIMD4<Float>(-modelCenter, 1)
        return t * simd_float4x4(modelRotation) * tInv
    }

    /// The SINGLE clip transform this pass consumes: P · V · model — the same
    /// composition the mesh pipeline draws the body with. Internal (not private) so
    /// the alignment tests measure the transform the shader actually receives (A1/A2).
    func modelViewProjection(aspect: Float) -> simd_float4x4 {
        camera.projectionMatrix(aspect: aspect) * camera.viewMatrix() * modelMatrix()
    }

    func makeUniforms(aspect: Float) -> LSDFUniforms {
        // The march runs directly in MODEL (mesh) space — where every baked grid
        // lives. The per-pixel ray is the EXACT geometric inverse of P·V·model,
        // built from the camera basis with no matrix inversion (see LSDFUniforms):
        // world-space look-at basis, un-settled into model space, with the frustum
        // half-tangents folded into the right/up vectors. Eye and light are rotated
        // into the same frame.
        let invR = modelRotation.inverse
        let eyeModel = modelCenter + invR.act(camera.eye - modelCenter)
        let lightModel = invR.act(simd_normalize(SIMD3<Float>(0.4, 0.85, 0.55)))
        // lookAt basis (exactly OrbitCamera.lookAt's x/y/z rows): z points from the
        // target toward the eye, the camera looks along −z.
        let zW = simd_normalize(camera.eye - camera.target)
        let xW = simd_normalize(simd_cross(camera.up, zW))
        let yW = simd_cross(zW, xW)
        let tanHalf = tan(camera.fovY * 0.5)
        let rayX = invR.act(xW) * tanHalf * aspect
        let rayY = invR.act(yW) * tanHalf
        let rayDir = invR.act(-zW)
        let bmin = scene?.bounds.min ?? .zero
        let bmax = scene?.bounds.max ?? .zero
        // Cell origin = part min corner, so cells tile from a stable anchor.
        let cell = Float(max(0.1, params.cellMM))
        let (lo, hi) = params.densitySpan
        let K = Float(max(1e-3, params.lattice.densityCoefficient))
        let hasDemand: Float = scene?.demand != nil ? 1 : 0
        let sdfSp = scene?.partSDF.spacing ?? SIMD3<Float>(repeating: 1)
        let minSDFSpacing = min(sdfSp.x, min(sdfSp.y, sdfSp.z))
        // Indigo-FAMILY endpoints (same "amount of material" story as the proxy, bar P1),
        // but both lifted off black so a lit 3-D strut reads clearly against the dark
        // stage: sparse = bright periwinkle, dense = vivid violet. Distinct from the
        // stress blue→red rainbow.
        let sparse = RGBA(158, 176, 236)
        let dense = RGBA(96, 52, 176)
        return LSDFUniforms(
            rayX: SIMD4(rayX, 0),
            rayY: SIMD4(rayY, 0),
            rayDir: SIMD4(rayDir, 0),
            eye: SIMD4(eyeModel, 1),
            bboxMin: SIMD4(bmin, 0),
            bboxMax: SIMD4(bmax, 0),
            gridOrigin: SIMD4(cellGrid?.origin ?? .zero, 0),
            gridSpacing: SIMD4(cellGrid?.spacing ?? SIMD3(repeating: 1), 0),
            gridDims: SIMD4(Float(cellGrid?.nx ?? 1), Float(cellGrid?.ny ?? 1), Float(cellGrid?.nz ?? 1), 0),
            sdfOrigin: SIMD4(scene?.partSDF.origin ?? .zero, 0),
            sdfSpacing: SIMD4(scene?.partSDF.spacing ?? SIMD3(repeating: 1), 0),
            sdfDims: SIMD4(Float(scene?.partSDF.nx ?? 1), Float(scene?.partSDF.ny ?? 1), Float(scene?.partSDF.nz ?? 1), 0),
            latticeOrigin: SIMD4(bmin.x, bmin.y, bmin.z, cell),
            gradeParams: SIMD4(Float(lo), Float(hi), Float(max(0.05, params.gamma)), K),
            shadeParams: SIMD4(Float(params.uniformRelativeDensity), hasDemand, 0.03, 512),
            // stepParams.y = the trim's inward EROSION (mm). Near creases the trilinear
            // SDF underestimates true distance (min-of-planes is concave), so its zero
            // surface bulges outward in a lumpy per-voxel pattern — strut slivers
            // survive just outside the part and read as floating bits / rogue stubs
            // (round-4 feedback). Eroding by ~0.35 voxel dominates that error: flat
            // faces stay straight (a uniform offset), and nothing renders unless it is
            // genuinely interior.
            // stepParams.z = whether a face-tint volume is bound (A4).
            stepParams: SIMD4(0.95, 0.35 * minSDFSpacing, tintTex != nil ? 1 : 0, Float(segCount)),
            lightDir: SIMD4(lightModel, 0),
            sparseColor: SIMD4(Float(sparse.r), Float(sparse.g), Float(sparse.b), 1),
            denseColor: SIMD4(Float(dense.r), Float(dense.g), Float(dense.b), 1))
    }

    private func encode(into rpd: MTLRenderPassDescriptor, aspect: Float, cmd: MTLCommandBuffer) {
        guard let pipeline, isReady,
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var u = makeUniforms(aspect: aspect)
        enc.setRenderPipelineState(pipeline)
        bindFragment(enc, &u)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    // MARK: - the UNIFIED pass (task 2026-08-18-unified-shading)

    /// True once a scene is baked and there is something to march. `MeshRenderer` asks
    /// this before it adds the lattice to its own passes — an unbaked layer must leave
    /// the frame byte-identical, never draw a black rectangle over it.
    var isReady: Bool {
        cellTex != nil && sdfTex != nil && segBuffer != nil && segCount > 0
    }

    /// Bind the baked volumes + the segment soup + the sampler at the shared shader's
    /// fragment argument indices. ONE definition, used by the standalone pass, the
    /// unified G-buffer write and (for the uniform) the deferred shade — a second copy
    /// of an argument table is exactly how a "missing Buffer binding" abort gets in.
    func bindFragment(_ enc: MTLRenderCommandEncoder, _ u: inout LSDFUniforms) {
        enc.setFragmentBytes(&u, length: MemoryLayout<LSDFUniforms>.stride, index: 0)
        enc.setFragmentBuffer(segBuffer, offset: 0, index: 1)
        enc.setFragmentTexture(cellTex, index: 0)
        enc.setFragmentTexture(sdfTex, index: 1)
        enc.setFragmentTexture(tintTex ?? dummyTintTex, index: 2)
        enc.setFragmentSamplerState(sampler, index: 0)
    }

    /// The uniforms for the unified G-buffer write: everything `makeUniforms` builds,
    /// plus the three transforms that put a marched MODEL-space hit into the body's own
    /// clip and eye frames. The caller passes the matrices IT is drawing the shell with
    /// — that is what makes the two surfaces land in the same depth buffer at the same
    /// place, rather than two views that merely agree to several decimal places.
    func makeUnifiedUniforms(aspect: Float, clipFromModel: simd_float4x4,
                             eyeFromModel: simd_float4x4,
                             eyeNormalBasis: simd_float4x4) -> LSDFUniforms {
        var u = makeUniforms(aspect: aspect)
        u.clipFromModel = clipFromModel
        u.eyeFromModel = eyeFromModel
        u.eyeNormalBasis = eyeNormalBasis
        return u
    }

    // MARK: live draw

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }
        // Project at the shared VIEWPORT ratio, not the capped drawable's integer-
        // rounded ratio, so the lattice and the body scale identically (bar A1).
        let aspect = viewportAspect
            ?? Float(view.drawableSize.width / max(1, view.drawableSize.height))
        let before = bakeGeneration
        encode(into: rpd, aspect: aspect, cmd: cmd)
        assert(bakeGeneration == before, "P2 violated: a bake happened inside draw()")
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: offscreen (evidence) + measurement (profile), mirroring MeshRenderer

    func renderOffscreen(size: Int, clear: MTLClearColor) -> [UInt8]? {
        guard cellTex != nil, segCount > 0 else { return nil }
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        cd.usage = [.renderTarget, .shaderRead]; cd.storageMode = .shared
        guard let color = device.makeTexture(descriptor: cd), let cmd = queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = clear
        rpd.colorAttachments[0].storeAction = .store
        encode(into: rpd, aspect: 1, cmd: cmd)
        cmd.commit(); cmd.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: size * size * 4)
        color.getBytes(&px, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        return px
    }

    func measureFrameGPUSeconds(size: Int) -> Double? {
        guard cellTex != nil, segCount > 0 else { return nil }
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        cd.usage = [.renderTarget]; cd.storageMode = .private
        guard let color = device.makeTexture(descriptor: cd), let cmd = queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        encode(into: rpd, aspect: 1, cmd: cmd)
        cmd.commit(); cmd.waitUntilCompleted()
        let dt = cmd.gpuEndTime - cmd.gpuStartTime
        return dt > 0 ? dt : nil
    }

    // MARK: shader

    /// ★ THE STANDALONE PREVIEW SHADER — NOW BUILT ON THE SHARED FIELD.
    ///
    /// The field, the march, the gradient and the albedo moved to
    /// `latticeFieldSource` (UnifiedShading.swift) so that this renderer and the
    /// unified pass inside `MeshRenderer` march THE SAME geometry. Only the entry
    /// point and the OLD shading model are left here, and they are left VERBATIM on
    /// purpose: this is the "pasted-on" picture the task's before/after pair is
    /// measured against, and a before that had drifted would make the pair
    /// uninterpretable.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    \(latticeFieldSource)

    fragment float4 lsdf_fragment(VOut in [[stage_in]],
                                  constant LSDFUniforms& U [[buffer(0)]],
                                  const device float4* segs [[buffer(1)]],
                                  texture3d<float> cellTex [[texture(0)]],
                                  texture3d<float> sdfTex [[texture(1)]],
                                  texture3d<float> tintTex [[texture(2)]],
                                  sampler samp [[sampler(0)]]) {
        float3 ro = U.eye.xyz;
        float3 rd = lsdf_ray(U, in.uv);
        LSDFHit h = lsdf_march(U, segs, cellTex, sdfTex, samp, ro, rd);
        if (!h.hit) return float4(0.0);
        float3 hitPos = h.pos; float hitRho = h.rho;
        float3 n = lsdf_normal(U, segs, sdfTex, samp, hitPos, hitRho);

        // ★ THE OLD, SEPARATE LIGHTING MODEL — and §1(d)'s whole point. A model-space
        // key at a different direction and a different strength from the body's, a
        // FLAT 0.30 ambient where the body has a two-colour hemisphere, a specular
        // lobe the body does not have at all, and a gamma lift + 1.08 exposure the
        // body does not apply. Two substances, and the eye reads two objects.
        float3 vdir = normalize(U.eye.xyz - hitPos);
        float3 key = normalize(U.lightDir.xyz);
        float3 fill = normalize(float3(-0.5, 0.2, 0.7));
        float ndlK = clamp(dot(n, key), 0.0, 1.0);
        float ndlF = clamp(dot(n, fill), 0.0, 1.0);
        float amb = 0.30;
        float3 baseC = lsdf_albedo(U, tintTex, samp, hitPos, hitRho);
        float3 lit = baseC * (amb + 0.85 * ndlK + 0.30 * ndlF);
        float rim = pow(1.0 - clamp(dot(n, vdir), 0.0, 1.0), 2.5);
        lit += rim * 0.55 * mix(float3(0.72, 0.78, 0.98), float3(1.0), 0.35);
        float spec = pow(max(dot(reflect(-key, n), vdir), 0.0), 48.0);
        lit += spec * 0.55;
        // Gentle lift so the deep-indigo dense end stays legible, not muddy black.
        float3 col = pow(clamp(lit, 0.0, 1.0), float3(0.85)) * 1.08;
        return float4(clamp(col, 0.0, 1.0), 1.0);
    }
    """
}
// ★ THE SWIFTUI HOST IS GONE, AND ITS ABSENCE IS THE TASK
// (task 2026-08-18-unified-shading).
//
// `LatticeSDFPreviewView` used to live here: a second, transparent, `isPaused` MTKView
// that the workspace stacked OVER the mesh view, with `isOpaque = false`, alpha
// blending, and — the thing that mattered — NO DEPTH ATTACHMENT ANYWHERE. That made the
// struts a separate image composited on top of the frame. They could not be occluded by
// the part, could not receive the frame's ambient occlusion, contact darkening or
// crease lines, and were lit by their own key light with their own ambient, their own
// specular lobe and their own exposure. The maintainer's "it looks pasted ON the model,
// not like a PART of it" was a literal description of the architecture.
//
// The workspace now hands this scene to `MetalMeshView` as `latticeLayer:`, and
// `MeshRenderer` marches it inside its OWN depth prepass and its OWN colour pass — see
// `MeshRenderer.setLatticeScene` and `unifiedLatticeShaderSource`. This renderer stays
// as the BAKER of the volumes (via `init(device:buildPipeline:)`) and as the standalone
// BEFORE capture for the evidence; nothing in the app draws through it any more.
//
// The view's own resolution cap (1152 px on the long side, its bar P3) did not
// disappear with it: the march is still fill-bound, so the same number is now
// `MeshRenderer.latticeGBufferMaxPixels` and caps the G-buffer the march writes into.

// Minimal IEEE-754 float32 → float16 for r16Float upload (no Accelerate dependency).
private func float32to16(_ f: Float) -> UInt16 {
    let x = f.bitPattern
    let sign = UInt16((x >> 16) & 0x8000)
    var mant = x & 0x007fffff
    let exp = Int((x >> 23) & 0xff) - 127 + 15
    if exp <= 0 {
        if exp < -10 { return sign }
        mant |= 0x00800000
        let shift = 14 - exp
        let m = mant >> UInt32(shift)
        return sign | UInt16(m)
    } else if exp >= 0x1f {
        return sign | 0x7c00
    }
    return sign | UInt16(exp << 10) | UInt16(mant >> 13)
}
#endif
