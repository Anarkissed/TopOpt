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

    /// ★ `regions` CLIPS THE PREVIEW TO WHAT IS ACTUALLY SET TO LATTICE
    /// (maintainer, 2026-08-17: "Can you confirm that the preview will only show
    /// what is *actually* set to lattice"). It was NOT: occupancy came from the
    /// whole part mesh and no region reached this path at all, so the struts
    /// filled the entire interior regardless of the declarations. Empty ⇒ no
    /// clipping, which is what the settings page's sample block needs.
    public init(mesh: ViewerMesh, field: StressField?, latticeID: String,
                maxDim: Int = 128, regions: [LatticeRegionSpec] = [],
                // ★ The band and gamma the raymarcher grades with, so a stated
                // per-region density can be inverted into the demand value that
                // comes back out as exactly that density (maintainer,
                // 2026-08-17). Defaults leave every existing call unchanged.
                rhoMin: Double = 0, rhoMax: Double = 1, gamma: Double = 1) {
        self.preview = LatticeSDFPreview(latticeID: latticeID)
        self.occupancy = LatticeRegionMask.clipped(
            LatticePreviewOccupancy.occupancy(
                positions: mesh.positions, indices: mesh.indices,
                bounds: mesh.bounds, maxDim: maxDim),
            to: regions)
        self.partSDF = LatticePreviewOccupancy.signedDistance(
            positions: mesh.positions, indices: mesh.indices, like: occupancy)
        // ★ A STATED PER-REGION DENSITY OUTRANKS THE STRESS FIELD. It is the
        // user's own number for that region; grading it by stress instead would
        // draw struts at a density they did not ask for and the run will not
        // build. With nothing stated this falls through to exactly what it was.
        self.demand = LatticeRegionMask.densityDemand(
            like: occupancy, regions: regions,
            rhoMin: rhoMin, rhoMax: rhoMax, gamma: gamma)
            ?? LatticePreviewOccupancy.demand(like: occupancy, field: field)
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

@MainActor
final class LatticeSDFRenderer: NSObject, MTKViewDelegate {
    static var lastInitError: String?
    static let maxDPR: CGFloat = 2.0

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
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

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { Self.lastInitError = "queue nil"; return nil }
        self.queue = queue
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
        guard let cellTex, let sdfTex, let segBuffer, segCount > 0,
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var u = makeUniforms(aspect: aspect)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<LSDFUniforms>.stride, index: 0)
        enc.setFragmentBuffer(segBuffer, offset: 0, index: 1)
        enc.setFragmentTexture(cellTex, index: 0)
        enc.setFragmentTexture(sdfTex, index: 1)
        enc.setFragmentTexture(tintTex ?? dummyTintTex, index: 2)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
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

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct LSDFUniforms {
        float4 rayX, rayY, rayDir;   // model-space ray basis (see the Swift struct)
        float4 eye, bboxMin, bboxMax, gridOrigin, gridSpacing, gridDims;
        float4 sdfOrigin, sdfSpacing, sdfDims;   // part signed-distance grid
        float4 latticeOrigin;   // xyz origin, w cell mm
        float4 gradeParams;     // rhoMin, rhoMax, gamma, K
        float4 shadeParams;     // uniformRho, hasDemand, radiusFloorNorm, maxSteps
        float4 stepParams;      // stepScale, trimErosion(mm), hasTint, segCount
        float4 lightDir, sparseColor, denseColor;
    };
    struct VOut { float4 pos [[position]]; float2 uv; };

    vertex VOut lsdf_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = p * 2.0 - 1.0; return o;
    }

    // Capsule / segment distance (iq).
    static inline float sdCap(float3 p, float3 a, float3 b, float r) {
        float3 pa = p - a, ba = b - a;
        float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        return length(pa - ba * h) - r;
    }

    // Ray vs AABB → (tNear, tFar); tFar<tNear ⇒ miss.
    static float2 hitBox(float3 ro, float3 rd, float3 lo, float3 hi) {
        float3 inv = 1.0 / rd;
        float3 t0 = (lo - ro) * inv, t1 = (hi - ro) * inv;
        float3 a = min(t0, t1), b = max(t0, t1);
        return float2(max(max(a.x, a.y), a.z), min(min(b.x, b.y), b.z));
    }

    fragment float4 lsdf_fragment(VOut in [[stage_in]],
                                  constant LSDFUniforms& U [[buffer(0)]],
                                  const device float4* segs [[buffer(1)]],
                                  texture3d<float> cellTex [[texture(0)]],
                                  texture3d<float> sdfTex [[texture(1)]],
                                  texture3d<float> tintTex [[texture(2)]],
                                  sampler samp [[sampler(0)]]) {
        // MODEL-space ray — the exact geometric inverse of the ONE shared transform
        // (P·V·settle), built from the CPU-exact camera basis: no matrix inversion,
        // no far-plane w cancellation (which used to warp rays by pixels). The march
        // runs in the mesh's own frame, where every baked grid lives, and lands on
        // screen exactly where the body pass puts the same point.
        float3 ro = U.eye.xyz;
        float3 rd = normalize(U.rayDir.xyz + U.rayX.xyz * in.uv.x + U.rayY.xyz * in.uv.y);

        float cell = U.latticeOrigin.w;
        float3 lorigin = U.latticeOrigin.xyz;
        float3 bmin = U.bboxMin.xyz, bmax = U.bboxMax.xyz;
        // Everything is trimmed flush at the part surface, so a small pad suffices.
        float3 pad = float3(0.15 * cell);
        float2 tb = hitBox(ro, rd, bmin - pad, bmax + pad);
        if (tb.y < max(tb.x, 0.0)) return float4(0.0);

        int segCount = int(U.stepParams.w);
        float rhoMin = U.gradeParams.x, rhoMax = U.gradeParams.y, gamma = U.gradeParams.z, K = U.gradeParams.w;
        float uniformRho = U.shadeParams.x;
        bool hasDemand = U.shadeParams.y > 0.5;
        float radiusFloor = U.shadeParams.z;
        int maxSteps = int(U.shadeParams.w);
        // The field is a TRUE distance (min of exact capsule SDFs, radii constant per
        // owning cell), so near-full sphere-trace steps are safe — no Lipschitz-broken
        // squash like the gizmo's ribbons.
        float stepScale = U.stepParams.x;
        float delta = U.stepParams.y;      // trim erosion (mm)
        float eps = max(0.05, 0.015 * cell);
        float3 ncells = U.gridDims.xyz;

        // WHOLE-CELL emission (the worker's canonical-midpoint rule, and the fix for
        // the ragged boundary): a strut renders IFF its OWNING cell is active in the
        // baked per-cell field. Per marched cell we prefetch the 3×3×3 neighbourhood
        // once into registers — value < 0 ⇒ inactive; ≥ 0 ⇒ active with demand d —
        // and precompute each neighbour's graded strut radius. Consecutive steps in
        // the same cell reuse the cache.
        float3 cachedBase = float3(1e9);
        float rnCache[27];
        float rhoCache[27];
        bool anyActive = false;

        float t = max(tb.x, 0.0);
        float tEnd = tb.y;
        float3 hitPos = ro; float hitRho = uniformRho; bool hit = false;
        // Previous sample along the ray, for the secant hit refinement (A2): the raw
        // sphere-trace accepts a hit anywhere in {F < eps}, an eps-thick shell whose
        // depth along the ray varies with view direction — the surface visibly
        // "breathes" as the camera orbits. One secant step to the F = 0 root makes
        // the rendered surface the true iso-surface from every angle, at zero extra
        // field evaluations. This is the actual fix for the eps-side of the jitter
        // bar — the constant itself is untouched.
        float tPrev = t; float FPrev = 1e9;

        // Part signed distance (mm, negative inside): trilinear sample of the exact
        // narrow-band SDF. Distance-to-a-plane is affine, so the part's flat faces
        // interpolate EXACTLY → the trimmed edge is straight (round-3 feedback).
        float3 sdfDims = U.sdfDims.xyz;
        float3 bc = (bmin + bmax) * 0.5, be = (bmax - bmin) * 0.5;

        for (int i = 0; i < maxSteps; i++) {
            if (t > tEnd) break;
            float3 p = ro + rd * t;
            float3 c = (p - lorigin) / cell;
            float3 baseCell = round(c);
            float3 q = c - baseCell;

            // Flush trim field: part SDF eroded by `delta` (kills the crease-bulge
            // slivers — see stepParams.y) ∨ the exact part bbox (the bbox term stops
            // the clamp-to-edge sampler extruding faces that touch the bounds).
            float3 stc = ((p - U.sdfOrigin.xyz) / U.sdfSpacing.xyz + 0.5) / sdfDims;
            float dPart = sdfTex.sample(samp, stc).r + delta;
            float3 qb = abs(p - bc) - be;
            float dBox = length(max(qb, 0.0)) + min(max(qb.x, max(qb.y, qb.z)), 0.0);
            float dClip = max(dPart, dBox);

            if (any(baseCell != cachedBase)) {
                cachedBase = baseCell;
                anyActive = false;
                for (int oz = -1; oz <= 1; oz++) {
                    for (int oy = -1; oy <= 1; oy++) {
                        for (int ox = -1; ox <= 1; ox++) {
                            int idx = (ox + 1) * 9 + (oy + 1) * 3 + (oz + 1);
                            float3 cc = baseCell + float3(ox, oy, oz);
                            float v = -1.0;
                            if (all(cc >= -0.5) && all(cc < ncells - 0.5)) {
                                v = cellTex.read(uint3(cc), 0).r;
                            }
                            if (v >= 0.0) {
                                anyActive = true;
                                float rho = hasDemand
                                    ? (rhoMin + (rhoMax - rhoMin) * pow(clamp(v, 0.0, 1.0), gamma))
                                    : uniformRho;
                                rhoCache[idx] = rho;
                                rnCache[idx] = clamp(max(radiusFloor, sqrt(max(rho, 0.0) / K)), 0.0, 0.49);
                            } else {
                                rnCache[idx] = -1.0;
                                rhoCache[idx] = 0.0;
                            }
                        }
                    }
                }
            }

            float dn = 1e9;
            float rhoNear = uniformRho;
            if (anyActive) {
                for (int s = 0; s < segCount; s++) {
                    float4 a = segs[2 * s];
                    int oi = int(a.w + 0.5);
                    float rn = rnCache[oi];
                    if (rn < 0.0) continue;
                    float d = sdCap(q, a.xyz, segs[2 * s + 1].xyz, rn);
                    if (d < dn) { dn = d; rhoNear = rhoCache[oi]; }
                }
            }
            // CSG intersection: struts ∩ part. max() of 1-Lipschitz SDFs is a valid
            // SDF, so full sphere-trace steps stay safe; struts are cut flush at the
            // part surface, like a machined section — the straight edge.
            float F = max(dn * cell, dClip);
            if (F < eps) {
                // Secant refinement to the F = 0 root (see tPrev above): F is locally
                // near-linear along the ray, so one step lands within O(eps²) of the
                // true surface — view-independent, no crawl during orbit.
                float tHit = t;
                if (FPrev < 1e8 && FPrev > F) {
                    float dt = t - tPrev;
                    tHit = clamp(t + F * dt / (FPrev - F), t - dt, t + dt);
                }
                hit = true; hitPos = ro + rd * tHit; hitRho = rhoNear; break;
            }
            FPrev = F; tPrev = t;

            // Advance. Near the surface: sphere-trace F (capped at 0.7·cell so the
            // 3×3×3 strut neighbourhood is never skipped past). Far from the part:
            // the whole render lies in {dClip ≤ eps}, so dClip is a valid distance
            // bound independent of the neighbourhood — leap by it.
            float step = anyActive ? clamp(F * stepScale, 0.05 * cell, 0.7 * cell)
                                   : 0.7 * cell;
            step = max(step, dClip - 3.0 * eps);
            t += step;
        }
        if (!hit) return float4(0.0);

        // Normal = gradient of the TRIMMED field (unmasked lattice ∨ part SDF ∨ bbox)
        // at the hit: strut surfaces get strut normals, flush-cut faces get the part
        // surface's normal — flat facets, matching a section cut.
        float rnH = max(radiusFloor, sqrt(max(hitRho, 0.0) / K));
        rnH = min(rnH, 0.49);
        float h = 0.002 * cell;
        float3 ex = float3(h, 0, 0), ey = float3(0, h, 0), ez = float3(0, 0, h);
        float3 base = hitPos;
        float dpx, dnx, dpy, dny, dpz, dnz;
        {
            float3 pts[6] = { base+ex, base-ex, base+ey, base-ey, base+ez, base-ez };
            float d6[6];
            for (int k = 0; k < 6; k++) {
                float3 c = (pts[k] - lorigin) / cell;
                float3 q = c - round(c);
                float dmin = 1e9;
                for (int s = 0; s < segCount; s++) dmin = min(dmin, sdCap(q, segs[2*s].xyz, segs[2*s+1].xyz, rnH));
                float3 stc = ((pts[k] - U.sdfOrigin.xyz) / U.sdfSpacing.xyz + 0.5) / sdfDims;
                float dP = sdfTex.sample(samp, stc).r + delta;
                float3 qb = abs(pts[k] - bc) - be;
                float dB = length(max(qb, 0.0)) + min(max(qb.x, max(qb.y, qb.z)), 0.0);
                d6[k] = max(dmin * cell, max(dP, dB));
            }
            dpx=d6[0]; dnx=d6[1]; dpy=d6[2]; dny=d6[3]; dpz=d6[4]; dnz=d6[5];
        }
        float3 n = normalize(float3(dpx - dnx, dpy - dny, dpz - dnz) + 1e-6);

        // Shade: matte lambert + a soft fill + rim, coloured by density on the SAME
        // indigo ramp the proxy uses (bar consistency). Sparse struts → pale violet,
        // dense → deep indigo, so a graded lattice reads as light→dark through the part.
        float3 vdir = normalize(U.eye.xyz - hitPos);
        float3 key = normalize(U.lightDir.xyz);
        float3 fill = normalize(float3(-0.5, 0.2, 0.7));
        float ndlK = clamp(dot(n, key), 0.0, 1.0);
        float ndlF = clamp(dot(n, fill), 0.0, 1.0);
        float amb = 0.30;
        float frac = clamp((hitRho - rhoMin) / max(1e-4, rhoMax - rhoMin), 0.0, 1.0);
        float3 baseC = mix(U.sparseColor.xyz, U.denseColor.xyz, frac);
        // Face-role tint (A4): where the body would have been tinted (anchor / load /
        // keep-clear / protect), the marked face's surface voxels carry that colour in
        // the tint volume — baked from the mesh view's own tint dictionary. The
        // trilinear alpha fades off-face; ×2.2 saturates ON the face so the flush-cut
        // section reads as solidly marked as the body did.
        if (U.stepParams.z > 0.5) {
            float3 ttc = ((hitPos - U.sdfOrigin.xyz) / U.sdfSpacing.xyz + 0.5) / sdfDims;
            float4 ft = tintTex.sample(samp, ttc);
            baseC = mix(baseC, ft.rgb, clamp(ft.a * 2.2, 0.0, 1.0));
        }
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

// MARK: - SwiftUI host (transparent MTKView riding the SHARED workspace camera)

/// The live strut-preview layer. Sibling of `TransformGizmoMetalView`: a transparent,
/// non-interactive, `isPaused` MTKView that redraws ONLY when the shared orbit camera
/// (or the scene/params) changes — nothing per frame (P2). The fragment shader is
/// fill-bound, so the drawable is CAPPED at `maxRenderPixels` on its long side and
/// upscaled by the compositor — the documented interactivity trade (bar P3).
struct LatticeSDFPreviewView {
    @ObservedObject var camera: OrbitCameraModel
    var scene: LatticeSDFScene
    var params: LatticeProxyParams
    /// A monotonically increasing token the workspace bumps when `scene` is rebuilt,
    /// so the coordinator re-uploads exactly once per bake (never per frame).
    var sceneToken: Int
    /// THE model transform of the scene — the gravity settle rotation about the mesh
    /// centre, the SAME values the workspace hands `MetalMeshView`. One transform,
    /// one camera, both layers (the 2026-07-30 alignment fix). Identity = un-settled.
    var modelRotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    var modelCenter: SIMD3<Float> = .zero
    /// The mesh view's face-role tint dictionary (anchor / load / keep-clear /
    /// protect), verbatim — baked onto the lattice so the marked faces read on the
    /// preview now that the body is not drawn (bars A3/A4). Re-baked only on change.
    var faceTints: [FaceID: SIMD4<Float>] = [:]

    /// Internal raymarch resolution cap (long side, pixels). ~1024 keeps the busy
    /// scene inside the 60 Hz budget on the measured M2 Pro profile.
    static let maxRenderPixels: CGFloat = 1152

    @MainActor
    final class Coordinator: NSObject {
        var renderer: LatticeSDFRenderer?
        var sceneToken: Int = -1
        /// The tint dictionary last baked, so the volume re-bakes only when the
        /// selection actually changes — never on a camera tick (P2).
        var appliedTints: [FaceID: SIMD4<Float>]? = nil
        /// The drawable size last SET (macOS): MTKView may round what it stores, so
        /// compare against what we asked for — re-setting the drawable every SwiftUI
        /// update (every orbit tick) forces CAMetalLayer churn mid-orbit.
        var lastDrawableTarget: CGSize = .zero
        private var cancellable: AnyCancellable?

        func bind(_ camera: OrbitCameraModel, to view: MTKView) {
            renderer?.camera = camera.camera
            cancellable = camera.$camera.sink { [weak self, weak view] cam in
                MainActor.assumeIsolated {
                    guard let self, let view else { return }
                    self.renderer?.camera = cam
                    if view.isPaused {
                        #if os(iOS)
                        view.setNeedsDisplay()
                        #elseif os(macOS)
                        view.needsDisplay = true
                        #endif
                    }
                }
            }
        }
    }

    @MainActor func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    fileprivate func configure(_ view: MTKView, _ coordinator: Coordinator) {
        let device = MTLCreateSystemDefaultDevice()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        #if os(iOS)
        view.isOpaque = false
        view.layer.isOpaque = false
        view.isUserInteractionEnabled = false     // gestures belong to the mesh view below
        #elseif os(macOS)
        view.layer?.isOpaque = false
        #endif
        if let device, let renderer = LatticeSDFRenderer(device: device) {
            coordinator.renderer = renderer
            view.delegate = renderer
        }
        coordinator.bind(camera, to: view)
        apply(view, coordinator)
    }

    @MainActor
    fileprivate func apply(_ view: MTKView, _ coordinator: Coordinator) {
        guard let renderer = coordinator.renderer else { return }
        if coordinator.sceneToken != sceneToken {
            coordinator.sceneToken = sceneToken
            renderer.setScene(scene)
            coordinator.appliedTints = nil     // new grid/mesh → tints must re-bake
        }
        renderer.params = params
        renderer.camera = camera.camera
        // The ONE model transform, straight from the workspace (same values the mesh
        // view gets). Cheap uniforms — no bake.
        renderer.modelRotation = modelRotation
        renderer.modelCenter = modelCenter
        // Face-role tints: bake ONLY when the selection actually changed (P2).
        if coordinator.appliedTints != faceTints {
            coordinator.appliedTints = faceTints
            renderer.setFaceTints(faceTints)
        }
        // Cap the drawable so the per-pixel march stays inside the frame budget —
        // but only TOUCH the drawable when the target actually changes: re-setting
        // it every SwiftUI update (every orbit tick re-evaluates the workspace body)
        // forces CAMetalLayer churn mid-orbit, which reads as frame-to-frame jitter.
        let side = max(view.bounds.width, view.bounds.height)
        if side > 0 {
            // Project at the true viewport ratio, not the rounded drawable's (A1).
            renderer.viewportAspect = Float(view.bounds.width / max(1, view.bounds.height))
            #if os(iOS)
            let capScale = min(view.contentScaleFactor, Self.maxRenderPixels / side)
            if abs(view.contentScaleFactor - capScale) > 0.001 {
                view.contentScaleFactor = capScale
            }
            #elseif os(macOS)
            let scale = min(view.window?.backingScaleFactor ?? 2,
                            Self.maxRenderPixels / side)
            let target = CGSize(width: view.bounds.width * scale,
                                height: view.bounds.height * scale)
            if coordinator.lastDrawableTarget != target {
                coordinator.lastDrawableTarget = target
                view.drawableSize = target
            }
            #endif
        }
        // Static layer — no display link; redraw on demand (camera sink + this apply).
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = 60
        #if os(iOS)
        view.setNeedsDisplay()
        #elseif os(macOS)
        view.needsDisplay = true
        #endif
    }
}

#if os(iOS)
extension LatticeSDFPreviewView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(); configure(view, context.coordinator); return view
    }
    func updateUIView(_ view: MTKView, context: Context) { apply(view, context.coordinator) }
}
#elseif os(macOS)
extension LatticeSDFPreviewView: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(); configure(view, context.coordinator); return view
    }
    func updateNSView(_ view: MTKView, context: Context) { apply(view, context.coordinator) }
}
#endif

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
