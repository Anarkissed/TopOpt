// FlexibleLatticeRenderer — the Flexible lattice PREVIEW: a Metal sphere-tracer of
// `FlexibleLatticeField.lattice(at:)` (task 2026-09-29-flexible-screens), with the squish
// played on a loop.
//
// ★ BUILT ON THE OCTET PREVIEW'S TECHNIQUE (LatticeSDFMetal): the lattice is a field, so a
// fragment shader marches it PER PIXEL and there are no lattice triangles on the device.
// Cost is per pixel, not per cell, so a fine gyroid costs what a coarse one does. The MTKView
// is paused and redraws on demand; only the squish loop runs continuous frames.
//
// ★ A TRANSPARENT LAYER OVER THE PART, ON PURPOSE. The octet preview moved INTO
// MeshRenderer's passes (task 2026-08-18-unified-shading) because a composited layer cannot
// be occluded by the part and "looks pasted on". Here the part is drawn at 30 % opacity
// while the lattice is shown (FlexibleStagePage.dentBodyAlpha), so the walls are MEANT to
// read through it, and this file may not touch MetalMeshView. The layer clears to
// (0,0,0,0), writes premultiplied alpha 1 on a wall, and never takes a touch — the orbit
// gestures reach the mesh view below. Folding it into the unified pass is the follow-up
// if the maintainer wants the walls occluded.
//
// ★ THE RAY. The caller's `CameraProjection.viewProjection` maps MODEL mm to clip (the
// settle rotation already composed in). It is inverted on the CPU in DOUBLE and the near
// (z = 0) and far (z = 1) planes are unprojected there, into an affine basis per plane; the
// shader interpolates both per pixel. Inverting in Float was the octet preview's bars A1/A2
// (1–4 px of swim): the far plane sits at 10 000 mm, where w cancels to ~1e-4 in Float.
//
// ★ THE SQUISH (02-squish-model §6 — the ramp FlexibleOverlay.displacements draws): a rest
// point at t along the load inside column c moves by s·d·(exit − t)/(exit − entry) along
// +load. The shader INVERTS it per sample (`flx_pullback`); `FlexibleSquishField` below is
// the Swift copy the tests hold it to. s = 0 skips the whole path, so it draws the rest
// lattice bit for bit.

#if canImport(MetalKit)
import MetalKit
import SwiftUI
import QuartzCore
import simd
import TopOptKit

// MARK: - the squish inputs

/// One loaded face's stack, as the squish animation needs it: core's frame (FlexStackInfo)
/// and one depth per column cell.
public struct FlexibleSquishFace: Equatable, Sendable {
    public let centroid: SIMD3<Float>
    public let xAxis: SIMD3<Float>
    public let yAxis: SIMD3<Float>
    /// Unit, INTO the part.
    public let load: SIMD3<Float>
    public let uMin: Float, vMin: Float, pitchMM: Float
    public let nu: Int, nv: Int
    /// `nu·nv` cells, cell (iu, iv) at `iv·nu + iu` (core's `column_at` order):
    /// x = depth mm at full scale, y = entryT, z = exitT, w = 1 if a column exists there.
    public let cells: [SIMD4<Float>]
    /// The largest depth of a column that moves (0 = no column of this face moves).
    public let maxDepthMM: Float
    /// Whether any column of this face moves at all (a positive depth over a real span).
    public var moves: Bool { maxDepthMM > 0 }
    /// The stack's extent along the load: min entryT … max exitT over its columns.
    public let tMin: Float, tMax: Float

    public init(centroid: SIMD3<Float>, xAxis: SIMD3<Float>, yAxis: SIMD3<Float>, load: SIMD3<Float>,
                uMin: Float, vMin: Float, pitchMM: Float, nu: Int, nv: Int, cells: [SIMD4<Float>]) {
        self.centroid = centroid; self.xAxis = xAxis; self.yAxis = yAxis; self.load = load
        self.uMin = uMin; self.vMin = vMin; self.pitchMM = pitchMM
        self.nu = Swift.max(0, nu); self.nv = Swift.max(0, nv)
        var c = cells
        if c.count != self.nu * self.nv {   // a short table reads as "no column" past its end
            c = Array(c.prefix(self.nu * self.nv))
            c += [SIMD4<Float>](repeating: .zero, count: self.nu * self.nv - c.count)
        }
        self.cells = c
        var lo = Float.infinity, hi = -Float.infinity, deepest: Float = 0
        for x in c where x.w >= 0.5 {
            lo = Swift.min(lo, x.y); hi = Swift.max(hi, x.z)
            if x.x > 0, x.z - x.y > 1e-6 { deepest = Swift.max(deepest, x.x) }
        }
        self.maxDepthMM = pitchMM > 0 ? deepest : 0
        self.tMin = lo.isFinite ? lo : 0
        self.tMax = hi.isFinite ? hi : 0
    }

    /// The displacement (mm along +load, at s = 1, before the 0.95 clamp) of the rest point
    /// at `t0` in this cell — 02 §6's ramp; 0 outside the column or where none exists.
    static func displacement(_ c: SIMD4<Float>?, _ t0: Float) -> Float {
        guard let c, c.w >= 0.5, c.x > 0, c.z - c.y > 1e-6, t0 >= c.y, t0 <= c.z else { return 0 }
        return c.x * (c.z - t0) / (c.z - c.y)
    }

    /// Per cell: the largest difference between its displacement and any 4-neighbour's, over
    /// all t (mm at s = 1) — how far the deformed field can JUMP across that cell's walls.
    /// Both ramps are piecewise linear in t with steps at the entries, so the maximum sits at
    /// a breakpoint, taken from both sides. A cell off the grid or with no column moves 0.
    func columnJumps() -> [Float] {
        func at(_ iu: Int, _ iv: Int) -> SIMD4<Float>? {
            guard iu >= 0, iv >= 0, iu < nu, iv < nv else { return nil }
            let c = cells[iv * nu + iu]
            return c.w >= 0.5 ? c : nil
        }
        var out = [Float](repeating: 0, count: cells.count)
        for iv in 0..<nv {
            for iu in 0..<nu {
                let c = at(iu, iv)
                var j: Float = 0
                for (du, dv) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let n = at(iu + du, iv + dv)
                    let bs = [c?.y, c?.z, n?.y, n?.z].compactMap { $0 }
                    for b in bs {
                        let e = Swift.max(1e-4, abs(b) * 1e-5)
                        for t in [b - e, b, b + e] {
                            j = Swift.max(j, abs(Self.displacement(c, t) - Self.displacement(n, t)))
                        }
                    }
                }
                out[iv * nu + iu] = j
            }
        }
        return out
    }

    /// From core's stack and one depth per COLUMN, in core's column order (the same array
    /// FlexibleOverlay.displacements takes: `FlexColumnDesign.buildableDepthMM` or
    /// `targetDepthMM`, the caller picks). nil or ≤ 0 = that column does not move.
    public init(stack st: FlexStackInfo, depthsMM: [Double?]) {
        var cells = [SIMD4<Float>](repeating: .zero, count: Swift.max(0, st.nu * st.nv))
        for k in cells.indices {
            let col = k < st.cell.count ? st.cell[k] : -1
            guard col >= 0, col < st.columns.count else { continue }
            let c = st.columns[col]
            let d = col < depthsMM.count ? (depthsMM[col] ?? 0) : 0
            cells[k] = SIMD4(Float(Swift.max(d, 0)), Float(c.entryT), Float(c.exitT), 1)
        }
        self.init(centroid: SIMD3<Float>(st.centroid), xAxis: SIMD3<Float>(st.xAxis),
                  yAxis: SIMD3<Float>(st.yAxis), load: SIMD3<Float>(st.load),
                  uMin: Float(st.uMin), vMin: Float(st.vMin), pitchMM: Float(st.pitchMM),
                  nu: st.nu, nv: st.nv, cells: cells)
    }

    /// Core's `column_at` + the cell's row, or nil off the grid / where no column exists.
    func cell(u: Float, v: Float) -> SIMD4<Float>? {
        let iu = Int((u / pitchMM).rounded(.down)), iv = Int((v / pitchMM).rounded(.down))
        guard iu >= 0, iv >= 0, iu < nu, iv < nv else { return nil }
        let c = cells[iv * nu + iu]
        return c.w >= 0.5 ? c : nil
    }
}

/// How the squish plays: a fixed amount, or the maintainer's loop (rest → full → rest).
public enum FlexibleSquishMotion: Equatable, Sendable {
    /// A fixed s in [0, 1].
    case still(Float)
    /// s = ½ − ½·cos(2π·t / period), forever — eased at both ends, starting from rest.
    case loop(periodSeconds: Double)

    public func amount(atSeconds t: Double) -> Float {
        switch self {
        case .still(let s): return Swift.min(Swift.max(s, 0), 1)
        case .loop(let period):
            guard period > 0, t.isFinite else { return 0 }
            return Float(0.5 - 0.5 * cos(2 * Double.pi * t / period))
        }
    }

    public var isAnimated: Bool { if case .loop = self { return true } else { return false } }
}

/// The Swift copy of the shader's squish (`flx_pullback` / `flx_deformed`), so the tests
/// can hold the GPU to it. `squish` here is the EFFECTIVE s (amount × exaggeration).
public enum FlexibleSquishField {
    /// The largest share of a column's span the face may travel (the inverse divides by 1 − a).
    public static let maxRatio: Float = 0.95

    public struct Pull: Equatable, Sendable {
        /// The rest point the lattice is evaluated at.
        public var p0: SIMD3<Float>
        /// The column's contraction along the load (a rest distance × scale is a safe step).
        public var scale: Float
        /// > 0: the point is in the gap a pressed face left, this far (mm) above it. −1 otherwise.
        public var air: Float
    }

    /// Deformed → rest, faces in order (each sees the point the previous one pulled back).
    public static func pullback(_ p: SIMD3<Float>, faces: [FlexibleSquishFace], squish s: Float) -> Pull {
        var r = Pull(p0: p, scale: 1, air: -1)
        guard s > 0 else { return r }
        for face in faces.prefix(FlexibleLatticeShader.maxFaces) where face.moves {
            let d = r.p0 - face.centroid
            let t = simd_dot(d, face.load)
            guard t >= face.tMin, t <= face.tMax else { continue }
            let u = simd_dot(d, face.xAxis) - face.uMin, v = simd_dot(d, face.yAxis) - face.vMin
            guard let c = face.cell(u: u, v: v) else { continue }
            let span = c.z - c.y
            guard c.x > 0, span > 1e-6, t >= c.y, t <= c.z else { continue }
            let a = Swift.min(s * c.x / span, maxRatio)
            let front = c.y + a * span
            if t < front { r.air = Swift.max(r.air, front - t); continue }
            let t0 = (t - a * c.z) / (1 - a)
            r.p0 += face.load * (t0 - t)
            r.scale *= (1 - a)
        }
        return r
    }

    /// Rest → deformed (the forward ramp), faces applied in REVERSE so `pullback` undoes it.
    public static func forward(_ p0: SIMD3<Float>, faces: [FlexibleSquishFace], squish s: Float) -> SIMD3<Float> {
        guard s > 0 else { return p0 }
        var p = p0
        for face in faces.prefix(FlexibleLatticeShader.maxFaces).reversed() where face.moves {
            let d = p - face.centroid
            let t0 = simd_dot(d, face.load)
            let u = simd_dot(d, face.xAxis) - face.uMin, v = simd_dot(d, face.yAxis) - face.vMin
            guard let c = face.cell(u: u, v: v) else { continue }
            let span = c.z - c.y
            guard c.x > 0, span > 1e-6, t0 >= c.y, t0 <= c.z else { continue }
            let a = Swift.min(s * c.x / span, maxRatio)
            p += face.load * (a * (c.z - t0))
        }
        return p
    }

    /// The lattice at a DEFORMED point (what the preview draws while squishing).
    public static func lattice(at p: SIMD3<Float>, _ f: FlexibleLatticeInputs,
                               faces: [FlexibleSquishFace], squish s: Float) -> Float {
        let pb = pullback(p, faces: faces, squish: s)
        return pb.air > 0 ? pb.air : FlexibleLatticeField.lattice(at: pb.p0, f)
    }
}

// MARK: - the renderer

public final class FlexibleLatticeRenderer: NSObject, MTKViewDelegate {

    public enum Failure: Error, CustomStringConvertible {
        case library(String), function(String), pipeline(String), queue
        public var description: String {
            switch self {
            case .library(let s): return "FlexibleLatticeShader failed to compile: \(s)"
            case .function(let s): return "FlexibleLatticeShader has no function \(s)"
            case .pipeline(let s): return "Flexible lattice pipeline failed: \(s)"
            case .queue: return "Flexible lattice: no command queue"
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
    /// `testUniformLayoutMatchesTheMSLStructFieldByField` hold the two together.
    struct Uniforms {
        var nearO = SIMD4<Float>.zero, nearX = SIMD4<Float>.zero, nearY = SIMD4<Float>.zero
        var farO = SIMD4<Float>.zero, farX = SIMD4<Float>.zero, farY = SIMD4<Float>.zero
        var viewport = SIMD4<Float>.zero
        var boxMin = SIMD4<Float>.zero, boxMax = SIMD4<Float>.zero
        var shape = SIMD4<Float>.zero, shape2 = SIMD4<Float>.zero, buildDir = SIMD4<Float>.zero
        var rhoO = SIMD4<Float>.zero, rhoN = SIMD4<Float>.zero
        var maskO = SIMD4<Float>.zero, maskN = SIMD4<Float>.zero
        var sdfO = SIMD4<Float>.zero, sdfN = SIMD4<Float>.zero
        var skinO = SIMD4<Float>.zero, skinN = SIMD4<Float>.zero
        var keyLight = SIMD4<Float>.zero, fillLight = SIMD4<Float>.zero
        var albedo = SIMD4<Float>.zero
        var squish = SIMD4<Float>.zero
        var march = SIMD4<Float>.zero
        var faces: (FaceUniforms, FaceUniforms, FaceUniforms, FaceUniforms) = (.zero, .zero, .zero, .zero)
        var tail = SIMD4<Float>(1, 2, 3, 4)
    }

    public static let colorFormat: MTLPixelFormat = .bgra8Unorm
    /// The march's step budget (the spec's ≤ 400).
    public static let maxSteps: Float = 400
    /// The AABB pad (mm) the march is clipped to.
    public static let boxPadMM: Float = 1
    /// Neutral warm clay (not a DS token: a material, like MetalMeshView's `clay`).
    static let albedo = SIMD4<Float>(0.82, 0.80, 0.76, 0.30)   // w = ambient
    /// The body's original eye-space key and fill (MetalMeshView's headlight rig), so the
    /// walls are lit from where the part is.
    static let keyEye = SIMD3<Float>(0.30, 0.60, 0.72), keyStrength: Float = 0.62
    static let fillEye = SIMD3<Float>(-0.45, -0.25, 0.40), fillStrength: Float = 0.22

    public let device: MTLDevice
    let queue: MTLCommandQueue
    let renderPipeline: MTLRenderPipelineState
    let probePipeline: MTLComputePipelineState
    let squishProbePipeline: MTLComputePipelineState
    let echoPipeline: MTLComputePipelineState

    public private(set) var inputs: FlexibleLatticeInputs?
    public private(set) var squishFaces: [FlexibleSquishFace] = []
    /// Model mm → clip (the settle rotation composed in by the caller).
    public var projection: CameraProjection?
    public var motion: FlexibleSquishMotion = .still(0) {
        didSet { if motion != oldValue { motionEpoch = CACurrentMediaTime() } }
    }
    /// The overlay's exaggeration (FlexibleShownValues.exaggeration); s × this is drawn.
    public var exaggeration: Float = 1
    // ── the march's constants: the shipping values, and knobs for DIAGNOSIS ONLY (the tests'
    // fine reference march and their red controls turn them; nothing in the app does) ──
    /// Step = factor·|F|, never below `minStepMM`, never past `stepCapCells` cells.
    var stepFactor: Float = 0.6, minStepMM: Float = 0.02
    var stepBudget: Float = FlexibleLatticeRenderer.maxSteps
    /// nil = the topology's own cap (`stepCap(for:)`).
    var stepCapOverride: Float?
    var stepCapCells: Float {
        get { stepCapOverride ?? Self.stepCap(for: inputs?.topology ?? .gyroid) }
        set { stepCapOverride = newValue }
    }
    /// The march's lower-bound early-out (`flx_field_march`).
    var earlyOut = true
    /// Control only: march as if neighbouring columns never jumped (tears a varied press).
    var ignoresColumnWalls = false
    /// Paint a ray that ran out of steps red instead of transparent (a miss and a give-up
    /// otherwise look identical).
    var paintsExhaustedRays = false

    /// The longest step, in cells. ★ THE GYROID'S IS 0.1, NOT THE 0.25 FIRST WRITTEN: its
    /// |g|/|∇| over-reads between the sheets (the gradient floor is 0.05·k), and a quarter
    /// cell — 4 mm at L = 16.5 — jumped whole 0.8 mm walls at grazing angles. Measured on the
    /// 40 × 40 × 20 box at 768², against a march at 0.02 cells: 2 203 px of coverage wrong
    /// at 0.25, 95 at 0.1 (0.05 did no better: the rest is silhouette jitter). The
    /// honeycomb's wall is 1-Lipschitz (a hex norm of an orthonormal projection), so it keeps
    /// the quarter cell.
    static func stepCap(for topology: FlexibleLatticeInputs.Topology) -> Float {
        topology == .gyroid ? 0.1 : 0.25
    }

    /// When the current motion began (the loop starts from rest here).
    private(set) var motionEpoch = CACurrentMediaTime()
    private var rhoTex: MTLTexture?, maskTex: MTLTexture?, sdfTex: MTLTexture?, skinTex: MTLTexture?
    private var columnTex: [MTLTexture] = []
    private let emptyColumns: MTLTexture

    public init(device: MTLDevice) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else { throw Failure.queue }
        queue = q
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: FlexibleLatticeShader.source, options: nil) }
        catch { throw Failure.library("\(error)") }
        func fn(_ name: String) throws -> MTLFunction {
            guard let f = lib.makeFunction(name: name) else { throw Failure.function(name) }
            return f
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.label = "flx_render"
        pd.vertexFunction = try fn("flx_vertex")
        pd.fragmentFunction = try fn("flx_fragment")
        pd.colorAttachments[0].pixelFormat = Self.colorFormat
        do { renderPipeline = try device.makeRenderPipelineState(descriptor: pd) }
        catch { throw Failure.pipeline("render: \(error)") }
        func compute(_ name: String) throws -> MTLComputePipelineState {
            let cd = MTLComputePipelineDescriptor()
            cd.label = name
            cd.computeFunction = try fn(name)
            do { return try device.makeComputePipelineState(descriptor: cd, options: [], reflection: nil) }
            catch { throw Failure.pipeline("\(name): \(error)") }
        }
        probePipeline = try compute("flx_field_probe")
        squishProbePipeline = try compute("flx_squish_probe")
        echoPipeline = try compute("flx_uniform_echo")
        // a 1×1 "no column" table for the face slots nobody uses
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
        d.usage = [.shaderRead]; d.storageMode = .shared
        guard let e = device.makeTexture(descriptor: d) else { throw Failure.pipeline("column placeholder") }
        var zero = SIMD4<Float>.zero
        e.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 16)
        emptyColumns = e
        super.init()
    }

    // MARK: inputs (the only place textures change)

    /// Upload the four grids. nil (or a grid Metal cannot hold) draws nothing.
    public func setInputs(_ f: FlexibleLatticeInputs?) {
        inputs = f
        guard let f else { rhoTex = nil; maskTex = nil; sdfTex = nil; skinTex = nil; return }
        rhoTex = makeVolume(f.rho); maskTex = makeVolume(f.mask)
        sdfTex = makeVolume(f.partSDF); skinTex = makeVolume(f.skinDist)
    }

    /// Up to four loaded faces (the rest are ignored — the shader has four slots).
    public func setSquishFaces(_ faces: [FlexibleSquishFace]) {
        squishFaces = Array(faces.prefix(FlexibleLatticeShader.maxFaces))
        columnTex = squishFaces.map { makeColumns($0) ?? emptyColumns }
    }

    private var ready: Bool { rhoTex != nil && maskTex != nil && sdfTex != nil && skinTex != nil }

    private func makeVolume(_ g: FlexGrid) -> MTLTexture? {
        guard g.nx > 0, g.ny > 0, g.nz > 0, g.values.count == g.nx * g.ny * g.nz, g.spacing > 0 else { return nil }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        // ★ r32Float, not r16Float: a half has 11 bits, and a half-float cell once HALVED the
        // octet preview's cell (2026-08-26). The field is compared with Swift to 2 µm.
        d.pixelFormat = .r32Float
        d.width = g.nx; d.height = g.ny; d.depth = g.nz
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        g.values.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake3D(0, 0, 0, g.nx, g.ny, g.nz), mipmapLevel: 0, slice: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: g.nx * 4, bytesPerImage: g.nx * g.ny * 4)
        }
        return tex
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

    /// The near/far planes' affine bases in model space: a pixel at NDC (x, y) sees the ray
    /// from `nearO + x·nearX + y·nearY` to `farO + x·farX + y·farY`. Inverted in DOUBLE (see
    /// the ★ RAY note at the top). nil for a singular or non-finite transform.
    static func rayBasis(_ vp: simd_float4x4)
        -> (nearO: SIMD3<Float>, nearX: SIMD3<Float>, nearY: SIMD3<Float>,
            farO: SIMD3<Float>, farX: SIMD3<Float>, farY: SIMD3<Float>)? {
        let m = simd_double4x4(columns: (SIMD4<Double>(vp.columns.0), SIMD4<Double>(vp.columns.1),
                                         SIMD4<Double>(vp.columns.2), SIMD4<Double>(vp.columns.3)))
        let det = m.determinant
        guard det.isFinite, abs(det) > 1e-300 else { return nil }
        let inv = m.inverse
        func un(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Double>? {
            let h = inv * SIMD4<Double>(x, y, z, 1)
            guard h.w.isFinite, abs(h.w) > 1e-300 else { return nil }
            let p = SIMD3<Double>(h.x, h.y, h.z) / h.w
            return p.x.isFinite && p.y.isFinite && p.z.isFinite ? p : nil
        }
        guard let n0 = un(0, 0, 0), let nx = un(1, 0, 0), let ny = un(0, 1, 0),
              let f0 = un(0, 0, 1), let fx = un(1, 0, 1), let fy = un(0, 1, 1) else { return nil }
        return (SIMD3<Float>(n0), SIMD3<Float>(nx - n0), SIMD3<Float>(ny - n0),
                SIMD3<Float>(f0), SIMD3<Float>(fx - f0), SIMD3<Float>(fy - f0))
    }

    /// Everything but the camera (what the probes need).
    func baseUniforms(squish s: Float) -> Uniforms? {
        guard let f = inputs else { return nil }
        var u = Uniforms()
        let pad = SIMD3<Float>(repeating: Self.boxPadMM)
        u.boxMin = SIMD4(f.boundsMin - pad, 0)
        u.boxMax = SIMD4(f.boundsMax + pad, 0)
        u.shape = SIMD4(f.topology == .gyroid ? 0 : 1, f.wallMM, f.lMinMM, f.lMaxMM)
        u.shape2 = SIMD4(f.honeycombCellMM, f.skinMM, stepBudget, paintsExhaustedRays ? 1 : 0)
        u.buildDir = SIMD4(f.buildDir, 0)
        func grid(_ g: FlexGrid) -> (SIMD4<Float>, SIMD4<Float>) {
            (SIMD4(g.c0, g.spacing), SIMD4(Float(g.nx), Float(g.ny), Float(g.nz), 0))
        }
        (u.rhoO, u.rhoN) = grid(f.rho)
        (u.maskO, u.maskN) = grid(f.mask)
        (u.sdfO, u.sdfN) = grid(f.partSDF)
        (u.skinO, u.skinN) = grid(f.skinDist)
        u.albedo = Self.albedo
        u.march = SIMD4(stepFactor, stepCapCells, minStepMM, earlyOut ? 1 : 0)
        let eff = Swift.max(0, s * exaggeration)
        u.squish = SIMD4(eff.isFinite ? eff : 0, Float(squishFaces.count), ignoresColumnWalls ? 1 : 0, 0)
        var fu = [FaceUniforms](repeating: .zero, count: FlexibleLatticeShader.maxFaces)
        for (i, face) in squishFaces.enumerated() {
            fu[i] = FaceUniforms(centroid: SIMD4(face.centroid, face.maxDepthMM),
                                 xAxis: SIMD4(face.xAxis, face.uMin), yAxis: SIMD4(face.yAxis, face.vMin),
                                 load: SIMD4(face.load, face.pitchMM),
                                 extent: SIMD4(Float(face.nu), Float(face.nv), face.tMin, face.tMax))
        }
        u.faces = (fu[0], fu[1], fu[2], fu[3])
        return u
    }

    func uniforms(projection: CameraProjection, width: Int, height: Int, squish s: Float) -> Uniforms? {
        guard var u = baseUniforms(squish: s), let b = Self.rayBasis(projection.viewProjection) else { return nil }
        u.nearO = SIMD4(b.nearO, 0); u.nearX = SIMD4(b.nearX, 0); u.nearY = SIMD4(b.nearY, 0)
        u.farO = SIMD4(b.farO, 0); u.farX = SIMD4(b.farX, 0); u.farY = SIMD4(b.farY, 0)
        u.viewport = SIMD4(Float(width), Float(height), 0, 0)
        // the lights ride with the camera: eye-space key/fill taken into model space
        let fwd = b.farO - b.nearO
        guard simd_length(fwd) > 0, simd_length(b.nearX) > 0, simd_length(b.nearY) > 0 else { return nil }
        let right = simd_normalize(b.nearX), up = simd_normalize(b.nearY), back = -simd_normalize(fwd)
        func eye(_ e: SIMD3<Float>) -> SIMD3<Float> { simd_normalize(e.x * right + e.y * up + e.z * back) }
        u.keyLight = SIMD4(eye(Self.keyEye), Self.keyStrength)
        u.fillLight = SIMD4(eye(Self.fillEye), Self.fillStrength)
        return u
    }

    /// The s drawn right now: the still amount, or the loop's phase.
    public func currentSquish(now: Double = CACurrentMediaTime()) -> Float {
        motion.amount(atSeconds: now - motionEpoch)
    }

    // MARK: encoding

    private func bindColumns(_ set: ([MTLTexture?], Range<Int>) -> Void) {
        var cols: [MTLTexture?] = columnTex
        while cols.count < FlexibleLatticeShader.maxFaces { cols.append(emptyColumns) }
        set(cols, FlexibleLatticeShader.columnSlot..<(FlexibleLatticeShader.columnSlot + FlexibleLatticeShader.maxFaces))
    }

    private func encode(into rpd: MTLRenderPassDescriptor, cmd: MTLCommandBuffer, width: Int, height: Int,
                        projection: CameraProjection?, squish s: Float) {
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        defer { enc.endEncoding() }
        // nothing to draw ⇒ the cleared, transparent frame (the part shows through untouched)
        guard ready, width > 0, height > 0, let projection,
              var u = uniforms(projection: projection, width: width, height: height, squish: s) else { return }
        enc.setRenderPipelineState(renderPipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTextures([rhoTex, maskTex, sdfTex, skinTex], range: 0..<4)
        bindColumns { enc.setFragmentTextures($0, range: $1) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    // MARK: MTKViewDelegate (live)

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }
        encode(into: rpd, cmd: cmd, width: Int(view.drawableSize.width), height: Int(view.drawableSize.height),
               projection: projection, squish: currentSquish())
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: offscreen (tests, evidence)

    /// Render into a `.shared` texture and return RGBA8 bytes, top row first (the same
    /// premultiplied frame the view composites). `squish` nil = the current motion's s.
    public func renderOffscreen(width: Int, height: Int, projection: CameraProjection, squish: Float? = nil) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.colorFormat, width: width, height: height,
                                                          mipmapped: false)
        cd.usage = [.renderTarget, .shaderRead]; cd.storageMode = .shared
        guard let color = device.makeTexture(descriptor: cd), let cmd = queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        encode(into: rpd, cmd: cmd, width: width, height: height, projection: projection,
               squish: squish ?? currentSquish())
        cmd.commit(); cmd.waitUntilCompleted()
        guard cmd.status == .completed else { return nil }
        var px = [UInt8](repeating: 0, count: width * height * 4)
        color.getBytes(&px, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        for i in stride(from: 0, to: px.count, by: 4) { px.swapAt(i, i + 2) }   // BGRA → RGBA
        return px
    }

    /// Pixels a wall was drawn on (alpha > 0) in an RGBA8 frame.
    public static func coveredPixelCount(rgba: [UInt8]) -> Int {
        var n = 0
        for i in stride(from: 3, to: rgba.count, by: 4) where rgba[i] > 0 { n += 1 }
        return n
    }

    /// The GPU time of one frame at this size (a private target, nothing read back).
    public func measureFrameGPUSeconds(width: Int, height: Int, projection: CameraProjection, squish: Float? = nil) -> Double? {
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.colorFormat, width: width, height: height,
                                                          mipmapped: false)
        cd.usage = [.renderTarget]; cd.storageMode = .private
        guard let color = device.makeTexture(descriptor: cd), let cmd = queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        encode(into: rpd, cmd: cmd, width: width, height: height, projection: projection,
               squish: squish ?? currentSquish())
        cmd.commit(); cmd.waitUntilCompleted()
        let dt = cmd.gpuEndTime - cmd.gpuStartTime
        return cmd.status == .completed && dt > 0 ? dt : nil
    }

    // MARK: probes (tests)

    /// `flx_field` (undeformed) at each point — compare with `FlexibleLatticeField.lattice`.
    public func probe(_ points: [SIMD3<Float>]) -> [Float]? {
        runProbe(probePipeline, points, squish: 0, columns: false)
    }

    /// `flx_deformed` at each (deformed) point — compare with `FlexibleSquishField.lattice`.
    public func probeSquished(_ points: [SIMD3<Float>], squish s: Float) -> [Float]? {
        runProbe(squishProbePipeline, points, squish: s, columns: true)
    }

    private func runProbe(_ pipe: MTLComputePipelineState, _ points: [SIMD3<Float>], squish s: Float,
                          columns: Bool) -> [Float]? {
        guard ready, !points.isEmpty, var u = baseUniforms(squish: s) else { return nil }
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
        enc.setTextures([rhoTex, maskTex, sdfTex, skinTex], range: 0..<4)
        if columns { bindColumns { enc.setTextures($0, range: $1) } }
        let w = Swift.max(1, Swift.min(64, pipe.maxTotalThreadsPerThreadgroup))
        enc.dispatchThreadgroups(MTLSize(width: (points.count + w - 1) / w, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        guard cmd.status == .completed else { return nil }
        let p = outBuf.contents().bindMemory(to: Float.self, capacity: points.count)
        return Array(UnsafeBufferPointer(start: p, count: points.count))
    }

    /// Every uniform field as the GPU reads it, BY NAME (see `flx_uniform_echo`).
    func echoUniforms(_ uniforms: Uniforms, count: Int) -> [SIMD4<Float>]? {
        var u = uniforms
        guard let out = device.makeBuffer(length: count * 16, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(echoPipeline)
        enc.setBuffer(out, offset: 0, index: 1)
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        guard cmd.status == .completed else { return nil }
        let p = out.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        return Array(UnsafeBufferPointer(start: p, count: count))
    }
}

// MARK: - the SwiftUI layer

/// The Flexible lattice, drawn over a TRANSPARENT background so it layers on top of
/// `MetalMeshView` (which draws the part at 30 % while the lattice shows). Takes no touches.
public struct FlexibleLatticeView: View {
    public var inputs: FlexibleLatticeInputs?
    /// Model mm → clip, as FlexibleStagePage publishes it (settle composed in).
    public var projection: CameraProjection?
    public var squishFaces: [FlexibleSquishFace]
    public var motion: FlexibleSquishMotion
    public var exaggeration: Float

    public init(inputs: FlexibleLatticeInputs?, projection: CameraProjection?,
                squishFaces: [FlexibleSquishFace] = [], motion: FlexibleSquishMotion = .still(0),
                exaggeration: Float = 1) {
        self.inputs = inputs; self.projection = projection; self.squishFaces = squishFaces
        self.motion = motion; self.exaggeration = exaggeration
    }

    public var body: some View {
        FlexibleLatticeLayer(config: self)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The MTKView under the layer: never opaque, never hit, and its drawable capped.
final class FlexibleLatticeMTKView: MTKView {
    /// ★ The march is fill-bound, so the drawable is capped on its long side — the same
    /// 1152 px the octet preview settled on (MeshRenderer.latticeGBufferMaxPixels); the
    /// layer scales it to the view.
    static let maxDrawablePixels: CGFloat = 1152

    static func scale(bounds: CGSize, native: CGFloat) -> CGFloat {
        let long = Swift.max(bounds.width, bounds.height)
        guard long > 0, native > 0 else { return Swift.max(native, 1) }
        return Swift.min(native, maxDrawablePixels / long)
    }

    #if os(iOS)
    override func layoutSubviews() {
        let s = Self.scale(bounds: bounds.size, native: traitCollection.displayScale)
        if abs(contentScaleFactor - s) > 1e-3 { contentScaleFactor = s }
        super.layoutSubviews()
    }
    #elseif os(macOS)
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        fitDrawable()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        fitDrawable()
    }
    private func fitDrawable() {
        let s = Self.scale(bounds: bounds.size, native: window?.backingScaleFactor ?? 2)
        let want = CGSize(width: (bounds.width * s).rounded(), height: (bounds.height * s).rounded())
        if want.width > 0, want.height > 0, want != drawableSize { drawableSize = want }
    }
    #endif
}

@MainActor
final class FlexibleLatticeCoordinator {
    private(set) var renderer: FlexibleLatticeRenderer?

    func makeView() -> FlexibleLatticeMTKView {
        let device = MTLCreateSystemDefaultDevice()
        let v = FlexibleLatticeMTKView(frame: .zero, device: device)
        v.colorPixelFormat = FlexibleLatticeRenderer.colorFormat
        v.depthStencilPixelFormat = .invalid
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        v.isPaused = true                 // draw on demand; only the squish loop runs frames
        v.enableSetNeedsDisplay = true
        #if os(iOS)
        v.isOpaque = false
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        #elseif os(macOS)
        v.autoResizeDrawable = false      // FlexibleLatticeMTKView sizes it (capped)
        v.wantsLayer = true
        v.layer?.isOpaque = false
        #endif
        (v.layer as? CAMetalLayer)?.isOpaque = false
        if let device {
            do { renderer = try FlexibleLatticeRenderer(device: device) }
            catch { NSLog("DIAG flexible lattice: %@", "\(error)") }
        }
        v.delegate = renderer
        return v
    }

    func apply(_ c: FlexibleLatticeView, to v: FlexibleLatticeMTKView) {
        guard let r = renderer else { return }
        var dirty = false
        if r.inputs != c.inputs { r.setInputs(c.inputs); dirty = true }
        if r.squishFaces != Array(c.squishFaces.prefix(FlexibleLatticeShader.maxFaces)) {
            r.setSquishFaces(c.squishFaces); dirty = true
        }
        if r.projection != c.projection { r.projection = c.projection; dirty = true }
        if r.exaggeration != c.exaggeration { r.exaggeration = c.exaggeration; dirty = true }
        if r.motion != c.motion { r.motion = c.motion; dirty = true }
        // ★ continuous frames ONLY while there is a squish to play; everything else redraws
        // on change (battery — the same posture as MetalMeshView).
        let animate = c.motion.isAnimated && c.inputs != nil && !c.squishFaces.isEmpty && c.projection != nil
        if animate == v.isPaused {
            v.isPaused = !animate
            v.enableSetNeedsDisplay = !animate
        }
        if dirty && !animate {
            #if os(iOS)
            v.setNeedsDisplay()
            #elseif os(macOS)
            v.needsDisplay = true
            #endif
        }
    }
}

#if os(iOS)
struct FlexibleLatticeLayer: UIViewRepresentable {
    let config: FlexibleLatticeView
    func makeCoordinator() -> FlexibleLatticeCoordinator { FlexibleLatticeCoordinator() }
    func makeUIView(context: Context) -> FlexibleLatticeMTKView { context.coordinator.makeView() }
    func updateUIView(_ view: FlexibleLatticeMTKView, context: Context) { context.coordinator.apply(config, to: view) }
}
#elseif os(macOS)
struct FlexibleLatticeLayer: NSViewRepresentable {
    let config: FlexibleLatticeView
    func makeCoordinator() -> FlexibleLatticeCoordinator { FlexibleLatticeCoordinator() }
    func makeNSView(context: Context) -> FlexibleLatticeMTKView { context.coordinator.makeView() }
    func updateNSView(_ view: FlexibleLatticeMTKView, context: Context) { context.coordinator.apply(config, to: view) }
}
#endif
#endif
