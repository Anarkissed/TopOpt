// FlexibleLatticePass — the Flexible lattice as a THIRD G-BUFFER WRITER inside
// MeshRenderer (task 2026-09-29-flexible-screens, in-pass round).
//
// ★ BUILT ON THE APP'S LATTICE PREVIEW, NOT BESIDE IT (maintainer, 2026-09-29: "look at
// the way App does the lattice preview and build upon that"; "a fast preview via an SDF —
// like the preview in the other two sections of the lattice stage"). Structural and
// Aesthetic march the octet into MeshRenderer's G-buffer in the depth prepass and #354's
// `lsdf_shade` lights it inside the main pass. This pass does the same with the Flexible
// field: `flx_gbuffer` writes eye-Z, the eye normal and an albedo + mask into the SAME
// attachments, against the SAME depth buffer, at the SAME 1152 px cap — so the walls take
// the shell's material, occlusion, creases and depth fade, and every overlay drawn after
// them is occluded by them. There is no second MTKView and no compositing.
//
// ★ BAKE-ONLY, LIKE THE OCTET'S LAYER. It never draws itself: MeshRenderer owns it
// (`flexibleLattice`) and calls `encodeGBuffer` from its prepass. Uploads happen once per
// TOKEN (`MeshRenderer.applyFlexibleLattice`, in the view's apply), never in encode.
//
// ★ ONE NUMBER FOR THE SQUISH. `squish` is MeshRenderer's `flexScale` — the float the
// dent's vertices are scaled by — passed by value from the prepass. The dent and the
// walls cannot drift out of phase.
//
// ★ THE RAY IS THE OCTET'S CAMERA BASIS (LatticeSDFMetal.makeUniforms): model-space eye,
// right/up/forward folded with the frustum half-tangents, no matrix inversion anywhere.
// The hits are written with MeshRenderer's own P·V·M, V·M and normal basis, so lsdf_shade's
// depth curve agrees with them.

#if canImport(MetalKit)
import MetalKit
import simd
import TopOptDesign

final class FlexibleLatticePass {
    /// The dense end of the wall ramp: the Flexible accent (DS accentGreen), never purple.
    static let denseWall = DS.Color.accentGreen


    enum Failure: Error, CustomStringConvertible {
        case library(String), function(String), pipeline(String)
        var description: String {
            switch self {
            case .library(let s): return "FlexibleLatticeShader failed to compile: \(s)"
            case .function(let s): return "FlexibleLatticeShader has no function \(s)"
            case .pipeline(let s): return "Flexible lattice pipeline failed: \(s)"
            }
        }
    }

    /// Matched to MSL `FlxFace` BY BYTE OFFSET (all float4, same order).
    struct FaceUniforms: Equatable {
        var centroid: SIMD4<Float>   // w = the largest depth (0 = the face does not move)
        var xAxis: SIMD4<Float>      // w = uMin
        var yAxis: SIMD4<Float>      // w = vMin
        var load: SIMD4<Float>       // w = pitch
        var extent: SIMD4<Float>     // nu, nv, tMin, tMax
        static let zero = FaceUniforms(centroid: .zero, xAxis: .zero, yAxis: .zero, load: .zero, extent: .zero)
    }

    /// Matched to MSL `FlxUniforms` BY BYTE OFFSET — `flx_uniform_echo` and
    /// `testUniformAndFrameLayoutsMatchTheMSL` hold the two together.
    struct Uniforms {
        var boxMin = SIMD4<Float>.zero, boxMax = SIMD4<Float>.zero
        var shape = SIMD4<Float>.zero, shape2 = SIMD4<Float>.zero, buildDir = SIMD4<Float>.zero
        var rmO = SIMD4<Float>.zero, rmN = SIMD4<Float>.zero
        var dsO = SIMD4<Float>.zero, dsN = SIMD4<Float>.zero
        var squish = SIMD4<Float>.zero
        var march = SIMD4<Float>.zero
        var faces: (FaceUniforms, FaceUniforms, FaceUniforms, FaceUniforms) = (.zero, .zero, .zero, .zero)
        /// ★ BATCH G: the FE field's block (feO / feN / feK — FlexibleLatticeShader's comments).
        var feO = SIMD4<Float>.zero, feN = SIMD4<Float>(1, 1, 1, 1), feK = SIMD4<Float>.zero
        var tail = SIMD4<Float>(1, 2, 3, 4)
    }

    /// Matched to MSL `FlxFrame` BY BYTE OFFSET — `flx_frame_echo` holds it.
    struct Frame {
        var eye = SIMD4<Float>.zero, rayX = SIMD4<Float>.zero, rayY = SIMD4<Float>.zero, rayDir = SIMD4<Float>.zero
        var clipFromModel = matrix_identity_float4x4
        var eyeFromModel = matrix_identity_float4x4
        var eyeNormalBasis = matrix_identity_float4x4
        var sparse = SIMD4<Float>.zero, dense = SIMD4<Float>.zero, rhoSpan = SIMD4<Float>.zero
        var tail = SIMD4<Float>(5, 6, 7, 8)
    }

    /// The last init failure (MeshRenderer does not retry a library that failed to compile).
    static var lastInitError: String?
    /// The march's step budget.
    static let maxSteps: Float = 400
    /// The pad (mm) the lattice region's box is clipped to around the part's AABB.
    static let boxPadMM: Float = 1

    /// The longest step, in cells (of the FINEST ladder rung in play). ★ THE GYROID'S IS 0.1,
    /// NOT THE 0.25 FIRST WRITTEN: its |g|/|∇| over-reads between the sheets (the gradient
    /// floor is 0.05·k), and a quarter cell jumps whole walls at grazing angles (on the
    /// ladder: 0.5 % of the covered pixels against a march at 0.02 cells, over T11's 0.3 %
    /// bar; 0.1 gives 0.05 %). The honeycomb's wall is 1-Lipschitz, so it keeps the quarter
    /// cell. T11 holds both, in the pass.
    static func stepCap(for topology: FlexibleLatticeInputs.Topology) -> Float {
        topology == .gyroid ? 0.1 : 0.25
    }

    let device: MTLDevice
    let gbufferDescriptor: MTLRenderPipelineDescriptor
    let gbufferPipeline: MTLRenderPipelineState
    /// The library the G-buffer pipeline came from; the TEST kernels' compute pipelines are
    /// built from it on first use (`computePipeline`) — the app never asks for them, so
    /// making a pass costs one compile and one render pipeline.
    private let library: MTLLibrary
    private var computeCache: [String: MTLComputePipelineState] = [:]
    /// True once the G-buffer pipeline built (the init THROWS otherwise, with the log).
    var gbufferPipelineDidBuild: Bool { gbufferPipeline.label == "flx_gbuffer" }

    // ── what was uploaded (once per token) ──
    private(set) var token = -1
    /// ★ ROUND 4 (D2): the squish faces' token (the player's pick re-uploads them alone).
    private(set) var facesToken = -1
    private(set) var faceUploadCount = 0
    /// Hidden while a new lattice builds: the volumes stay, only the march is skipped.
    var hidden = false
    /// ★ BATCH B: the MAIN page's squish loop (FlexibleSquishLoop), stepped by the renderer
    /// every frame (MeshRenderer.stepFlexibleLoop). nil ⇒ the view's own flexScale.
    var loop: FlexibleSquishLoop?
    private(set) var uploadCount = 0
    /// The grids AS THE GPU SEES THEM (a mismatched pair resampled onto one grid) — what
    /// every parity test compares against.
    private(set) var referenceInputs: FlexibleLatticeInputs?
    private(set) var faces: [FlexibleSquishFace] = []
    /// The lattice region's AABB (voxel centres with mask ≥ ½, ± one mask voxel, within the
    /// part's AABB + 1 mm). Empty (min > max) when nothing is latticed.
    private(set) var regionMin = SIMD3<Float>(repeating: 1e30)
    private(set) var regionMax = SIMD3<Float>(repeating: -1e30)
    /// The in-mask ρ span the colour ramp runs over.
    private(set) var rhoSpan = SIMD2<Float>(0, 1)
    private var base: Uniforms?
    private var maxDepthMM: Float = 0
    private var rmTex: MTLTexture?, dsTex: MTLTexture?
    private var columnTex: [MTLTexture] = []
    private let emptyColumns: MTLTexture

    // ── ★ BATCH G: the squeeze groups' FE fields (FlexibleFEField), one 3D texture each ──
    /// The fields AS THE GPU READS THEM (u rounded through a half) — the parity tests' reference.
    private(set) var feFields: [FlexibleFEField] = []
    /// Per field: the mesh displacements (the ghost and the heat plane) the renderer swaps in with it.
    private(set) var feMesh: [[Float]] = []
    /// The sequence the loop plays (indices into `feFields`); empty ⇒ the column squish.
    var feSequence: [Int] = []
    /// The field bound now (−1: none — the column squish), and the loop cycle it was bound in.
    var feShown = -1
    var feCycle: Int?
    private(set) var feToken = -1
    private(set) var feUploadCount = 0
    private var feTex: [MTLTexture] = []
    private let emptyFE: MTLTexture
    /// FE mode this frame: a field is bound.
    var feActive: Bool { feShown >= 0 && feShown < feTex.count && feShown < feFields.count }
    /// Test control only: the fixed-point iterations (1 = the red control).
    var controlFEIterations: Int?
    /// The field whose mesh displacements the renderer last swapped in WITH it (tests read it).
    var feMeshShown = -1
    /// ★ BATCH G VERIFICATION: "Play all"'s per-group tints (the page's reference), and the sim whose
    /// tints the renderer last swapped in (tests read it).
    var feTints: FlexibleFETints?
    var feTintsShown: String?
    /// Test controls: swap mid-cycle; let the mesh lag the field by one frame.
    var controlSwapAnywhere = false
    var controlSwapMeshNextFrame = false
    var controlPendingMesh: Int?
    private lazy var queue: MTLCommandQueue? = device.makeCommandQueue()

    /// Drawn this frame: uploaded and not hidden.
    var isDrawable: Bool { !hidden && rmTex != nil && dsTex != nil && base != nil }

    // ── the march's constants: the shipping values, and knobs for DIAGNOSIS ONLY (the tests'
    // fine reference march and their red controls turn them; nothing in the app does) ──
    var stepFactor: Float = 0.6, minStepMM: Float = 0.02
    var stepBudget: Float = FlexibleLatticePass.maxSteps
    /// nil = the topology's own cap (`stepCap(for:)`).
    var stepCapOverride: Float?
    var stepCapCells: Float { stepCapOverride ?? Self.stepCap(for: referenceInputs?.topology ?? .gyroid) }
    /// The march's lower-bound early-out (`flx_field_march`).
    var earlyOut = true
    /// Control only: march as if neighbouring columns never jumped (tears a varied press).
    var ignoresColumnWalls = false

    // ── TEST CONTROLS: each restores one wrong behaviour so a test can prove it sees it.
    // All off in the app. ──
    /// Put the see-through body back into the G-buffer (#354's `bodyAlpha > 0.004` rule).
    var controlKeepGhostInGBuffer = false
    /// Draw the body in #354's place (before the opaque shade) instead of after it.
    var controlDrawGhostFirst = false
    /// Bind the lattice-only AO texture to the re-issued body instead of the neutral one.
    var controlKeepAOForGhost = false
    /// Replace the squish MeshRenderer passes (its flexScale) with this value.
    var controlSquishOverride: Float?
    /// Offset the model centre on the PASS side only (the ray's frame).
    var controlModelCenterOffset = SIMD3<Float>.zero
    /// Probe only: bind the (ρ, mask) volume into the (SDF, skin) slot.
    var controlSwapVolumes = false

    /// The frame uniform the last `encodeGBuffer` bound (tests read it back).
    private(set) var lastFrame: Frame?

    init(device: MTLDevice) throws {
        self.device = device
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: FlexibleLatticeShader.gbufferSource, options: nil) }
        catch { throw Failure.library("\(error)") }
        func fn(_ name: String) throws -> MTLFunction {
            guard let f = lib.makeFunction(name: name) else { throw Failure.function(name) }
            return f
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.label = "flx_gbuffer"
        pd.vertexFunction = try fn("flx_vertex")
        pd.fragmentFunction = try fn("flx_gbuffer")
        // ★ ALL THREE of MeshRenderer's G-buffer colour formats: a pipeline writes ONLY the
        // attachments it declares, and an undeclared one is left undefined, then stored —
        // the "struts behind the wall" artifact (LatticeGBufferMaskTests).
        pd.colorAttachments[0].pixelFormat = MeshRenderer.sceneDepthFormat
        pd.colorAttachments[1].pixelFormat = MeshRenderer.gbufferNormalFormat
        pd.colorAttachments[2].pixelFormat = MeshRenderer.gbufferAlbedoFormat
        pd.depthAttachmentPixelFormat = MeshRenderer.depthFormat
        pd.rasterSampleCount = 1
        gbufferDescriptor = pd
        do { gbufferPipeline = try device.makeRenderPipelineState(descriptor: pd) }
        catch { throw Failure.pipeline("flx_gbuffer: \(error)") }
        library = lib
        // a 1×1 "no column" table for the face slots nobody uses, bound on every draw
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
        d.usage = [.shaderRead]; d.storageMode = .shared
        guard let e = device.makeTexture(descriptor: d) else { throw Failure.pipeline("column placeholder") }
        var zero = SIMD4<Float>.zero
        e.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 16)
        emptyColumns = e
        // ★ BATCH G: a 1×1×1 zero field for slot 6 when no FE field is bound
        let fd = MTLTextureDescriptor()
        fd.textureType = .type3D; fd.pixelFormat = .rgba16Float
        fd.width = 1; fd.height = 1; fd.depth = 1
        fd.usage = [.shaderRead]; fd.storageMode = .shared
        guard let fe = device.makeTexture(descriptor: fd) else { throw Failure.pipeline("FE placeholder") }
        var zeros = [UInt16](repeating: 0, count: 4)
        fe.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1), mipmapLevel: 0, slice: 0, withBytes: &zeros,
                   bytesPerRow: 8, bytesPerImage: 8)
        emptyFE = fe
    }

    /// A test kernel's compute pipeline, built once on first use (THROWING, with the log).
    func computePipeline(_ name: String) throws -> MTLComputePipelineState {
        if let p = computeCache[name] { return p }
        guard let f = library.makeFunction(name: name) else { throw Failure.function(name) }
        let cd = MTLComputePipelineDescriptor()
        cd.label = name
        cd.computeFunction = f
        let p: MTLComputePipelineState
        do { p = try device.makeComputePipelineState(descriptor: cd, options: [], reflection: nil) }
        catch { throw Failure.pipeline("\(name): \(error)") }
        computeCache[name] = p
        return p
    }

    /// The pipeline descriptor's contract, as a list of what is wrong with it (empty = OK).
    /// T1 runs it on the shipped descriptor AND on a broken copy (its red control).
    static func descriptorProblems(_ d: MTLRenderPipelineDescriptor) -> [String] {
        var out: [String] = []
        let want = [MeshRenderer.sceneDepthFormat, MeshRenderer.gbufferNormalFormat, MeshRenderer.gbufferAlbedoFormat]
        for (i, f) in want.enumerated() where d.colorAttachments[i].pixelFormat != f {
            out.append("colour \(i) is \(d.colorAttachments[i].pixelFormat.rawValue), not \(f.rawValue)")
        }
        if d.colorAttachments[3].pixelFormat != .invalid { out.append("colour 3 is declared") }
        if d.depthAttachmentPixelFormat != MeshRenderer.depthFormat { out.append("depth format") }
        if d.rasterSampleCount != 1 { out.append("sample count \(d.rasterSampleCount)") }
        if d.vertexFunction == nil || d.fragmentFunction == nil { out.append("functions") }
        return out
    }

    // MARK: upload (once per token)

    func upload(_ l: FlexibleLatticeLayerInputs) {
        token = l.token
        facesToken = l.facesToken
        hidden = l.hidden
        uploadCount += 1
        let f = l.lattice
        // (ρ, mask) on ρ's grid and (part SDF, skin) on the SDF's: the builder puts each pair
        // on one grid; a test fixture that does not is resampled here, and the REFERENCE
        // keeps the resampled grid, so parity is exact either way.
        let mask = Self.sameGrid(f.mask, f.rho) ? f.mask : Self.resample(f.mask, like: f.rho)
        let skin = Self.sameGrid(f.skinDist, f.partSDF) ? f.skinDist : Self.resample(f.skinDist, like: f.partSDF)
        // ★ STAGE B: the (SDF, skin) pair is uploaded as HALF floats and hardware-filtered
        // (FlexibleLatticeShader.flx_sample_ds); the reference holds those rounded values
        var ref = f
        ref.mask = mask
        ref.partSDF = Self.halfRounded(f.partSDF)
        ref.skinDist = Self.halfRounded(skin)
        referenceInputs = ref
        rmTex = makeVolume(f.rho, mask)
        dsTex = makeHalfVolume(f.partSDF, skin)
        faces = Array(l.faces.prefix(FlexibleSquishField.maxFaces))
        columnTex = faces.map { makeColumns($0) ?? emptyColumns }
        maxDepthMM = faces.map(\.maxDepthMM).max() ?? 0
        // the lattice region's box and the in-mask ρ span
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        var rLo = Float.infinity, rHi = -Float.infinity
        for k in 0..<mask.nz { for j in 0..<mask.ny { for i in 0..<mask.nx {
            let n = (k * mask.ny + j) * mask.nx + i
            guard mask.values[n] >= 0.5 else { continue }
            let c = mask.c0 + SIMD3<Float>(Float(i), Float(j), Float(k)) * mask.spacing
            lo = simd_min(lo, c); hi = simd_max(hi, c)
            let r = f.rho.values[n]
            rLo = Swift.min(rLo, r); rHi = Swift.max(rHi, r)
        } } }
        if lo.x.isFinite {
            let pad = SIMD3<Float>(repeating: Self.boxPadMM)
            regionMin = simd_max(lo - mask.spacing, f.boundsMin - pad)
            regionMax = simd_min(hi + mask.spacing, f.boundsMax + pad)
        } else {
            regionMin = SIMD3(repeating: 1e30); regionMax = SIMD3(repeating: -1e30)
        }
        rhoSpan = rLo.isFinite ? SIMD2(rLo, rHi) : SIMD2(0, 1)
        base = makeBase(ref)
    }

    /// ★ ROUND 4 (D2): the player picked another squeeze — the SAME lattice (its volumes stay
    /// on the GPU), other faces squishing: only their column tables and the face uniforms are
    /// made again.
    func uploadFaces(_ l: FlexibleLatticeLayerInputs) {
        facesToken = l.facesToken
        faceUploadCount += 1
        faces = Array(l.faces.prefix(FlexibleSquishField.maxFaces))
        columnTex = faces.map { makeColumns($0) ?? emptyColumns }
        maxDepthMM = faces.map(\.maxDepthMM).max() ?? 0
        if let ref = referenceInputs { base = makeBase(ref) }
    }

    /// ★ BATCH G: the squeeze groups' FE fields — one rgba16Float 3D texture each (node dims, xyz =
    /// u, hardware-filtered), and their mesh displacements. Once per `feToken` (the generation and
    /// the set of landed fields); a pick only changes the SEQUENCE. The field on screen stays bound
    /// if it is still there (a group landing in Play all never pops the one playing).
    func uploadFE(_ l: FlexibleLatticeLayerInputs) {
        let shownID = feActive ? feFields[feShown].simID : nil
        feToken = l.feToken
        feUploadCount += 1
        feTex = []
        feFields = []
        for f in l.fe {
            guard let t = makeFieldTexture(f) else { continue }
            feTex.append(t)
            feFields.append(Self.halfRounded(f))
        }
        feMesh = Array(l.feMesh.prefix(feFields.count))
        feShown = shownID.flatMap { id in feFields.firstIndex { $0.simID == id } } ?? -1
        setFESequence(l.feSequence)
    }

    /// The loop's sequence (indices into the fields). The field on screen is kept when it is still
    /// in it; otherwise the next step binds the sequence's own (a pick shows at once).
    func setFESequence(_ seq: [Int]) {
        feSequence = seq.filter { $0 >= 0 && $0 < feFields.count }
        if feShown >= 0, !feSequence.contains(feShown) { feShown = -1 }
        if feSequence.isEmpty { feShown = -1 }
    }

    /// Bind field `i` (the renderer's swap, at rest).
    func bindFE(_ i: Int) { feShown = (i >= 0 && i < feTex.count) ? i : -1 }

    /// A field as one rgba16Float 3D texture: xyz = u (mm at full load), w = 0.
    private func makeFieldTexture(_ f: FlexibleFEField) -> MTLTexture? {
        let n = f.nx * f.ny * f.nz
        guard f.nx > 0, f.ny > 0, f.nz > 0, f.u.count == n else { return nil }
        var packed = [UInt16](repeating: 0, count: 4 * n)
        for i in 0..<n {
            packed[4 * i] = Self.halfBits(f.u[i].x); packed[4 * i + 1] = Self.halfBits(f.u[i].y)
            packed[4 * i + 2] = Self.halfBits(f.u[i].z)
        }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba16Float
        d.width = f.nx; d.height = f.ny; d.depth = f.nz
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        packed.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake3D(0, 0, 0, f.nx, f.ny, f.nz), mipmapLevel: 0, slice: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: f.nx * 8, bytesPerImage: f.nx * f.ny * 8)
        }
        return tex
    }

    /// The field with every u rounded through a half, as the GPU reads it.
    static func halfRounded(_ f: FlexibleFEField) -> FlexibleFEField {
        let u = f.u.map { SIMD3<Float>(halfValue(halfBits($0.x)), halfValue(halfBits($0.y)), halfValue(halfBits($0.z))) }
        var r = FlexibleFEField(simID: f.simID, generation: f.generation, nx: f.nx, ny: f.ny, nz: f.nz,
                                origin: f.origin, spacing: f.spacing, u: u, solved: f.solved, bcMode: f.bcMode)
        r = r.scaled(by: 1)
        return r
    }

    static func sameGrid(_ a: FlexGrid, _ b: FlexGrid) -> Bool {
        a.nx == b.nx && a.ny == b.ny && a.nz == b.nz && a.c0 == b.c0 && a.spacing == b.spacing
    }

    /// `g` sampled (FlexGrid.sample) at every voxel centre of `like`.
    static func resample(_ g: FlexGrid, like t: FlexGrid) -> FlexGrid {
        var v = [Float](repeating: 0, count: t.nx * t.ny * t.nz)
        for k in 0..<t.nz { for j in 0..<t.ny { for i in 0..<t.nx {
            v[(k * t.ny + j) * t.nx + i] = g.sample(t.c0 + SIMD3<Float>(Float(i), Float(j), Float(k)) * t.spacing)
        } } }
        return FlexGrid(nx: t.nx, ny: t.ny, nz: t.nz, c0: t.c0, spacing: t.spacing, values: v)
    }

    /// Two same-grid scalar fields as one rg32Float volume (read by integer `read()`).
    /// ★ 32-bit, not 16: a half has 11 bits, and a half-float cell once HALVED the octet
    /// preview's cell (2026-08-26). The field is compared with Swift to 2 µm.
    private func makeVolume(_ a: FlexGrid, _ b: FlexGrid) -> MTLTexture? {
        let n = a.nx * a.ny * a.nz
        guard a.nx > 0, a.ny > 0, a.nz > 0, a.values.count == n, b.values.count == n, a.spacing > 0 else { return nil }
        var packed = [Float](repeating: 0, count: 2 * n)
        for i in 0..<n { packed[2 * i] = a.values[i]; packed[2 * i + 1] = b.values[i] }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rg32Float
        d.width = a.nx; d.height = a.ny; d.depth = a.nz
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        packed.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake3D(0, 0, 0, a.nx, a.ny, a.nz), mipmapLevel: 0, slice: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: a.nx * 8, bytesPerImage: a.nx * a.ny * 8)
        }
        return tex
    }

    /// The (SDF, skin) pair as one rg16Float volume, sampled with the hardware filter.
    private func makeHalfVolume(_ a: FlexGrid, _ b: FlexGrid) -> MTLTexture? {
        let n = a.nx * a.ny * a.nz
        guard a.nx > 0, a.ny > 0, a.nz > 0, a.values.count == n, b.values.count == n, a.spacing > 0 else { return nil }
        var packed = [UInt16](repeating: 0, count: 2 * n)
        for i in 0..<n { packed[2 * i] = Self.halfBits(a.values[i]); packed[2 * i + 1] = Self.halfBits(b.values[i]) }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rg16Float
        d.width = a.nx; d.height = a.ny; d.depth = a.nz
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        packed.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake3D(0, 0, 0, a.nx, a.ny, a.nz), mipmapLevel: 0, slice: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: a.nx * 4, bytesPerImage: a.nx * a.ny * 4)
        }
        return tex
    }

    /// IEEE half bits of `f`, rounded to nearest even (no `Float16`: it does not exist on
    /// x86_64 macOS). Overflow → ±inf, NaN → quiet NaN.
    static func halfBits(_ f: Float) -> UInt16 {
        let x = f.bitPattern
        let sign = UInt16((x >> 16) & 0x8000)
        let absx = x & 0x7FFF_FFFF
        if absx > 0x7F80_0000 { return sign | 0x7E00 }                 // NaN
        let exp = Int((absx >> 23) & 0xFF) - 127 + 15
        var mant = absx & 0x7F_FFFF
        if exp >= 31 { return sign | 0x7C00 }                           // too big → inf
        if exp <= 0 {                                                   // subnormal half
            if exp < -10 { return sign }
            mant |= 0x80_0000
            let shift = UInt32(14 - exp)
            var h = mant >> shift
            let rem = mant & ((UInt32(1) << shift) - 1), halfway = UInt32(1) << (shift - 1)
            if rem > halfway || (rem == halfway && h & 1 == 1) { h += 1 }
            return sign | UInt16(h)
        }
        var h = (UInt32(exp) << 10) | (mant >> 13)
        let rem = mant & 0x1FFF
        if rem > 0x1000 || (rem == 0x1000 && h & 1 == 1) { h += 1 }       // a carry into the exponent is correct
        return sign | UInt16(truncatingIfNeeded: h)
    }

    /// The float an IEEE half's bits hold.
    static func halfValue(_ h: UInt16) -> Float {
        let sign: Float = h & 0x8000 != 0 ? -1 : 1
        let exp = Int((h >> 10) & 0x1F), mant = Float(h & 0x3FF)
        if exp == 0 { return sign * mant * pow(2, -24) }
        if exp == 31 { return mant == 0 ? sign * .infinity : .nan }
        return sign * (1 + mant / 1024) * pow(2, Float(exp - 15))
    }

    /// A grid with every value rounded through a half, as the GPU reads it.
    static func halfRounded(_ g: FlexGrid) -> FlexGrid {
        var r = g
        r.values = g.values.map { halfValue(halfBits($0)) }
        return r
    }

    private func makeColumns(_ f: FlexibleSquishFace) -> MTLTexture? {
        guard f.nu > 0, f.nv > 0, f.cells.count == f.nu * f.nv else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: f.nu, height: f.nv,
                                                         mipmapped: false)
        d.usage = [.shaderRead]; d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        // alpha carries the wall jump next to "exists": 1 + jump where a column is, −jump
        // where none is (flx_pullback decodes it)
        let jumps = f.columnJumps()
        var payload = f.cells
        for k in payload.indices {
            payload[k].w = payload[k].w >= 0.5 ? 1 + jumps[k] : -jumps[k]
        }
        payload.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, f.nu, f.nv), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: f.nu * 16)
        }
        return tex
    }

    // MARK: uniforms

    private func makeBase(_ f: FlexibleLatticeInputs) -> Uniforms {
        var u = Uniforms()
        u.shape = SIMD4(f.topology == .gyroid ? 0 : 1, f.wallMM, f.lMinMM, f.lMaxMM)
        u.shape2 = SIMD4(f.honeycombCellMM, f.skinMM, Self.maxSteps, 0)
        u.buildDir = SIMD4(f.buildDir, 0)
        (u.rmO, u.rmN) = (SIMD4(f.rho.c0, f.rho.spacing), SIMD4(Float(f.rho.nx), Float(f.rho.ny), Float(f.rho.nz), 0))
        (u.dsO, u.dsN) = (SIMD4(f.partSDF.c0, f.partSDF.spacing),
                          SIMD4(Float(f.partSDF.nx), Float(f.partSDF.ny), Float(f.partSDF.nz), 0))
        var fu = [FaceUniforms](repeating: .zero, count: FlexibleSquishField.maxFaces)
        for (i, face) in faces.enumerated() {
            fu[i] = FaceUniforms(centroid: SIMD4(face.centroid, face.maxDepthMM),
                                 xAxis: SIMD4(face.xAxis, face.uMin), yAxis: SIMD4(face.yAxis, face.vMin),
                                 load: SIMD4(face.load, face.pitchMM),
                                 extent: SIMD4(Float(face.nu), Float(face.nv), face.tMin, face.tMax))
        }
        u.faces = (fu[0], fu[1], fu[2], fu[3])
        return u
    }

    /// The uniforms for one frame: the base, the squish MeshRenderer passes, the march's
    /// knobs, and the region box dilated by how far the squish can move material.
    func frameUniforms(squish s: Float) -> Uniforms? {
        guard var u = base else { return nil }
        let raw = controlSquishOverride ?? s
        let sq = raw.isFinite ? Swift.max(0, raw) : 0
        u.squish = SIMD4(sq, Float(faces.count), ignoresColumnWalls ? 1 : 0, 0)
        u.march = SIMD4(stepFactor, stepCapCells, minStepMM, earlyOut ? 1 : 0)
        u.shape2.z = stepBudget
        var dil = SIMD3<Float>(repeating: sq * maxDepthMM)
        if feActive {
            // ★ BATCH G: the FE field moves everything — no column faces; the box dilates by how
            // far the field can move material; a rest step × (1 − s·gmax) is a safe deformed step
            let f = feFields[feShown]
            u.squish.y = 0
            u.feO = SIMD4(f.origin, f.spacing)
            u.feN = SIMD4(Float(f.nx), Float(f.ny), Float(f.nz), Swift.max(0.2, 1 - sq * Float(f.gmax)))
            u.feK = SIMD4(1, f.maxDisplacement, Float(controlFEIterations ?? FlexibleFE.pullbackIterations), FlexibleFE.pullbackTolMM)
            dil = SIMD3<Float>(repeating: sq * f.maxDisplacement)
        }
        u.boxMin = SIMD4(regionMin - dil, 0)
        u.boxMax = SIMD4(regionMax + dil, 0)
        return u
    }

    /// The octet's camera basis (LatticeSDFMetal.makeUniforms, verbatim): the eye and the
    /// per-pixel ray, in MODEL space, as the exact inverse of P·V·M with M = T(c)·R·T(−c).
    static func rayBasis(camera: OrbitCamera, modelRotation: simd_quatf, modelCenter: SIMD3<Float>, aspect: Float)
        -> (eye: SIMD3<Float>, rayX: SIMD3<Float>, rayY: SIMD3<Float>, rayDir: SIMD3<Float>) {
        let invR = modelRotation.inverse
        let eyeModel = modelCenter + invR.act(camera.eye - modelCenter)
        let zW = simd_normalize(camera.eye - camera.target)
        let xW = simd_normalize(simd_cross(camera.up, zW))
        let yW = simd_cross(zW, xW)
        let tanHalf = tan(camera.fovY * 0.5)
        return (eyeModel, invR.act(xW) * tanHalf * aspect, invR.act(yW) * tanHalf, invR.act(-zW))
    }

    // MARK: encoding (MeshRenderer's depth prepass)

    /// Draw the lattice into the prepass's G-buffer: one full-screen triangle, the pass's
    /// own pipeline, the caller's depth state (.less, write on — the shell's and the
    /// octet's), culling off. Returns false (and draws nothing) when not drawable.
    @discardableResult
    func encodeGBuffer(_ enc: MTLRenderCommandEncoder, depthState: MTLDepthStencilState,
                       camera: OrbitCamera, modelRotation: simd_quatf, modelCenter: SIMD3<Float>, aspect: Float,
                       clipFromModel: simd_float4x4, eyeFromModel: simd_float4x4, eyeNormalBasis: simd_float4x4,
                       squish: Float) -> Bool {
        guard isDrawable, let rm = rmTex, let ds = dsTex, var u = frameUniforms(squish: squish) else { return false }
        // the volumes live on this pass's device; an encoder from another cannot read them
        guard enc.device === device else { return false }
        let b = Self.rayBasis(camera: camera, modelRotation: modelRotation,
                              modelCenter: modelCenter + controlModelCenterOffset, aspect: aspect)
        var f = Frame()
        f.eye = SIMD4(b.eye, 1); f.rayX = SIMD4(b.rayX, 0); f.rayY = SIMD4(b.rayY, 0); f.rayDir = SIMD4(b.rayDir, 0)
        f.clipFromModel = clipFromModel
        f.eyeFromModel = eyeFromModel
        f.eyeNormalBasis = eyeNormalBasis
        // Lightness by density, like the octet's ramp — but NOT its dense end:
        // LatticeStructureColour.interior (0.49, 0.42, 0.86) reads violet, and this track's
        // rule is "never purple". Sparse = the legend's pale; dense = the Flexible section's
        // own accent (FlexibleStageStyle, DS accentGreen), apart from the cyan ghost.
        let pale = LatticeStructureColour.pale, dense = FlexibleLatticePass.denseWall
        f.sparse = SIMD4(Float(pale.r), Float(pale.g), Float(pale.b), 1)
        f.dense = SIMD4(Float(dense.r), Float(dense.g), Float(dense.b), 1)
        f.rhoSpan = SIMD4(rhoSpan.x, rhoSpan.y, 0, 0)
        enc.setRenderPipelineState(gbufferPipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBytes(&f, length: MemoryLayout<Frame>.stride, index: 1)
        enc.setFragmentTexture(rm, index: 0)
        enc.setFragmentTexture(ds, index: 1)
        enc.setFragmentTextures(boundColumns(), range: FlexibleLatticeShader.columnSlot..<(FlexibleLatticeShader.columnSlot + FlexibleLatticeShader.maxFaces))
        enc.setFragmentTexture(boundFE, index: FlexibleLatticeShader.feSlot)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        lastFrame = f
        return true
    }

    /// ★ BATCH G: the FE field bound at slot 6 (the 1×1×1 zero field when none).
    private var boundFE: MTLTexture { feActive ? feTex[feShown] : emptyFE }

    /// Every declared column slot bound: the faces' tables, the 1×1 placeholder elsewhere.
    private func boundColumns() -> [MTLTexture?] {
        var cols: [MTLTexture?] = columnTex
        while cols.count < FlexibleLatticeShader.maxFaces { cols.append(emptyColumns) }
        return cols
    }

    // MARK: probes and echoes (tests)

    /// `flx_field` (undeformed) at each point — compare with `FlexibleLatticeField.lattice`
    /// on `referenceInputs`.
    func probe(_ points: [SIMD3<Float>]) -> [Float]? {
        guard let pipe = try? computePipeline("flx_field_probe") else { return nil }
        return runProbe(pipe, points, squish: 0, columns: false)
    }

    /// `flx_deformed` at each (deformed) point — compare with `FlexibleSquishField.lattice`.
    func probeSquished(_ points: [SIMD3<Float>], squish s: Float) -> [Float]? {
        guard let pipe = try? computePipeline("flx_squish_probe") else { return nil }
        return runProbe(pipe, points, squish: s, columns: true)
    }

    private func runProbe(_ pipe: MTLComputePipelineState, _ points: [SIMD3<Float>], squish s: Float,
                          columns: Bool) -> [Float]? {
        guard let rm = rmTex, let ds = dsTex, !points.isEmpty, var u = frameUniforms(squish: s),
              let queue else { return nil }
        var second = ds
        if controlSwapVolumes { second = rm; (u.dsO, u.dsN) = (u.rmO, u.rmN) }
        let pts = points.map { SIMD4<Float>($0, 0) }
        var n = UInt32(points.count)
        guard let inBuf = device.makeBuffer(bytes: pts, length: pts.count * 16, options: .storageModeShared),
              let outBuf = device.makeBuffer(length: points.count * 4, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(pipe)
        enc.setBuffer(inBuf, offset: 0, index: 0)
        enc.setBuffer(outBuf, offset: 0, index: 1)
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.setBytes(&n, length: 4, index: 3)
        enc.setTexture(rm, index: 0)
        enc.setTexture(second, index: 1)
        if columns {
            enc.setTextures(boundColumns(), range: FlexibleLatticeShader.columnSlot..<(FlexibleLatticeShader.columnSlot + FlexibleLatticeShader.maxFaces))
            enc.setTexture(boundFE, index: FlexibleLatticeShader.feSlot)
        }
        let w = Swift.max(1, Swift.min(64, pipe.maxTotalThreadsPerThreadgroup))
        enc.dispatchThreadgroups(MTLSize(width: (points.count + w - 1) / w, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        guard cmd.status == .completed else { return nil }
        let p = outBuf.contents().bindMemory(to: Float.self, capacity: points.count)
        return Array(UnsafeBufferPointer(start: p, count: points.count))
    }

    /// ★ BATCH G: `flx_pullback` at each deformed point — the rest point (xyz) and the step scale (w).
    func probePullback(_ points: [SIMD3<Float>], squish s: Float) -> [SIMD4<Float>]? {
        guard let pipe = try? computePipeline("flx_pullback_probe"), !points.isEmpty, var u = frameUniforms(squish: s),
              let queue else { return nil }
        let pts = points.map { SIMD4<Float>($0, 0) }
        var n = UInt32(points.count)
        guard let inBuf = device.makeBuffer(bytes: pts, length: pts.count * 16, options: .storageModeShared),
              let outBuf = device.makeBuffer(length: points.count * 16, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(pipe)
        enc.setBuffer(inBuf, offset: 0, index: 0)
        enc.setBuffer(outBuf, offset: 0, index: 1)
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.setBytes(&n, length: 4, index: 3)
        enc.setTextures(boundColumns(), range: FlexibleLatticeShader.columnSlot..<(FlexibleLatticeShader.columnSlot + FlexibleLatticeShader.maxFaces))
        enc.setTexture(boundFE, index: FlexibleLatticeShader.feSlot)
        let w = Swift.max(1, Swift.min(64, pipe.maxTotalThreadsPerThreadgroup))
        enc.dispatchThreadgroups(MTLSize(width: (points.count + w - 1) / w, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        guard cmd.status == .completed else { return nil }
        let p = outBuf.contents().bindMemory(to: SIMD4<Float>.self, capacity: points.count)
        return Array(UnsafeBufferPointer(start: p, count: points.count))
    }

    /// Every field of `value` as the GPU reads it, BY NAME (`flx_uniform_echo` when
    /// `frame` is false, `flx_frame_echo` when true). Generic so a test can hand it a
    /// deliberately mis-ordered struct (the red control).
    func echo<T>(_ value: T, frame: Bool, count: Int) -> [SIMD4<Float>]? {
        var v = value
        guard let pipe = try? computePipeline(frame ? "flx_frame_echo" : "flx_uniform_echo"),
              let queue, let out = device.makeBuffer(length: count * 16, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(pipe)
        enc.setBuffer(out, offset: 0, index: 1)
        withUnsafeBytes(of: &v) { raw in enc.setBytes(raw.baseAddress!, length: raw.count, index: 2) }
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        guard cmd.status == .completed else { return nil }
        let p = out.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        return Array(UnsafeBufferPointer(start: p, count: count))
    }
}
#endif
