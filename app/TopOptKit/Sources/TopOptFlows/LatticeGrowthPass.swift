// LatticeGrowthPass — ★ his 11-22 ("Could the user literally *watch* the lattice grow from nothing?"): the Organic lay's vines
// as they are laid (LatticeGrowth), drawn by the 3D view while the lay runs.
//
// ★ his notes 2026-11-23 (img 49): "It is showing all the lattices as if it was projected on top of the 3d model. It looks bad.
// It needs to be in 3D. There needs to be depth. I would prefer having the walls removed and seeing the actual 3d models of the
// lattices grow - but only the ones that are visible to me, not the ones behind it. … my preference is to literally have it
// looking exactly like the final result: no walls in the way; only seeing what's visible; shadow/highlights, etc." The pieces
// were line quads drawn over the frame (depth always, no shading). Now:
//   * each piece is a real tube at its strut's width (LatticeGrowth.radiusByRegion): 8 sides, smooth normals, a cone over each
//     end a radius long that closes a vine's bends and rounds its ends. INSTANCED from one 18-vertex, 32-triangle index list:
//     ordinary opaque triangles, so the iPad's hidden-surface removal shades each pixel once and the depth test rejects what
//     is hidden before it is shaded (impostors that write their own depth lose both — what lagged the ray-cast bars past
//     ~37k); about a fifth of the landed vines' triangles a piece (OrganicVinePass: 16 sides, discs, round ends, joints);
//   * written into the prepass G-buffer the landed vines write (eye z, normal, albedo, depth), so the deferred lattice shade
//     lights them exactly as it lights the landed lattice (the same light, highlights, ambient occlusion and creases), and
//     depth-tested against the part as the frame shows it and against each other: only what he can see shows;
//   * the part as the landed lattice draws it (MeshRenderer, `growthXraysBody`): opened by the map on screen when it is this
//     lay's (the very shell clip and cut walls the landed preview opens it with); when no map exists yet — the first lay of
//     these settings: the engine makes the map from the finished lay, under the session lock the lay holds — the part is
//     drawn in X-ray and the vines grow inside it (his fallback), until the landed lattice's own map opens it;
//   * the newest pieces a little brighter (cooling over about two polls); ★ item 3: from the engine's phase 2 on, a soft band
//     of lighter purple rises through the grown vines from the floor, a print layer at a time, and starts again, until the
//     lattice lands;
//   * landing: the tubes sink into the finished lattice (their radius to nothing over LatticeGrowth.fadeS) — no pop;
//   * ONE append-only buffer: each poll's new pieces are copied in after the last (grown by doubling, the old part copied
//     once per doubling), never the whole set again; past `drawMost` pieces the older ones are thinned (every k-th), the
//     newest `tipsKept` never.
#if canImport(MetalKit)
import MetalKit
import QuartzCore
import simd

let latticeGrowthShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct GrowFrame {
    float4x4 clipFromModel;
    float4x4 eyeFromModel;
    float4x4 eyeNormalBasis;
    float4   colour;      // rgb: the lattice's purple; a: the tubes' size (1; toward 0 as they sink into the landed lattice)
    float4   tip;         // rgb: the growing tips' colour; a: the clock (the newest poll's number)
    float4   cue;         // x: the stride through the pieces; y: the first piece
    float4   worldY;      // the model's world-height row: world y = dot(worldY.xyz, p) + worldY.w
    float4   band;        // x: the band's front (world y); y: its trail below (mm); z: its strength (0 none); w: its edge (mm)
    float4   bandColour;  // rgb: the band's lighter purple
};

struct GrowVOut {
    float4 pos [[position]];
    float  ez;
    float3 en;
    float  wy;
    float  glow [[flat]];
};
struct GrowGBuf {
    float  eyeZ    [[color(0)]];
    float4 enormal [[color(1)]];
    float4 albedo  [[color(2)]];
};

constant int kSides = 8;
// the ring's corners a little outside the true radius, its facets' middles a little inside: on average the true round tube
constant float kRingScale = 2.0 / (1.0 + 0.92387953);   // 2 / (1 + cos(pi / 8))

// One piece (a, birth) (b, radius): vertices 0-7 the ring at a, 8-15 the ring at b, 16 and 17 the cones' tips a radius past
// each end, along the piece; the normals radial on the rings, along the piece at the tips (smooth: the cone reads round).
vertex GrowVOut grow_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device float4* P [[buffer(0)]], constant GrowFrame& F [[buffer(1)]]) {
    uint i = uint(F.cue.y + 0.5) + uint(float(iid) * max(F.cue.x, 1.0));
    float4 A = P[2 * i], B = P[2 * i + 1];
    float r = max(B.w, 0.0) * F.colour.a;
    float3 ab = B.xyz - A.xyz;
    float L = length(ab);
    float3 t = L > 1e-6 ? ab / L : float3(0.0, 0.0, 1.0);
    float3 hl = abs(t.z) < 0.9 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 u = normalize(cross(t, hl)), v = cross(t, u);
    float3 p, n;
    if (vid >= uint(2 * kSides)) {
        bool atB = vid > uint(2 * kSides);
        p = atB ? B.xyz + t * r : A.xyz - t * r;
        n = atB ? t : -t;
    } else {
        bool atB = vid >= uint(kSides);
        float ang = float(vid % uint(kSides)) * (6.283185307 / float(kSides));
        float3 radial = cos(ang) * u + sin(ang) * v;
        p = (atB ? B.xyz : A.xyz) + radial * (r * kRingScale);
        n = radial;
    }
    GrowVOut o;
    o.pos = F.clipFromModel * float4(p, 1.0);
    o.ez = -(F.eyeFromModel * float4(p, 1.0)).z;
    o.en = (F.eyeNormalBasis * float4(n, 0.0)).xyz;
    o.wy = dot(F.worldY.xyz, p) + F.worldY.w;
    o.glow = exp(-max(F.tip.a - A.w, 0.0) / 1.2);   // the newest 1, a poll older about 0.4
    return o;
}

// Into the G-buffer as the landed vines write it (OrganicVinePass tube_gbuffer): the lattice shade lights it.
fragment GrowGBuf grow_gbuffer(GrowVOut in [[stage_in]], constant GrowFrame& F [[buffer(1)]]) {
    float3 n = normalize(in.en);
    if (n.z < 0.0) { n = -n; }
    float3 c = mix(F.colour.rgb, F.tip.rgb, 0.6 * in.glow);
    if (F.band.z > 0.0) {   // ★ notes24 item 3: the band of light rising through the grown lattice
        float d = F.band.x - in.wy;   // below its front: the trail fading down; above it: a sharp edge
        float b = d >= 0.0 ? exp(-d / max(F.band.y, 1e-4)) : exp(d / max(F.band.w, 1e-4));
        c = mix(c, F.bandColour.rgb, F.band.z * b);
    }
    GrowGBuf o;
    o.eyeZ = in.ez;
    o.enormal = float4(n, 0.0);
    o.albedo = float4(c, 1.0);
    return o;
}
"""

/// The growing vines, uploaded as they come, drawn as tubes into the prepass G-buffer.
final class LatticeGrowthPass {
    nonisolated(unsafe) static var lastInitError: String?
    /// Frames that drew growth (tests: it was on screen).
    nonisolated(unsafe) static var framesDrawn = 0
    /// At most this many pieces a frame: past it the older ones are thinned, the newest `tipsKept` never.
    static let drawMost = 600_000
    static let tipsKept = 60_000
    /// The tube's sides.
    static let sides = 8
    /// One piece's 32 triangles over its 18 vertices (`grow_vertex`): the side, then the cone over a and the cone over b.
    static let indices: [UInt16] = {
        let s = LatticeGrowthPass.sides
        var out: [UInt16] = []
        for k in 0..<s {
            let k1 = (k + 1) % s
            out += [k, s + k, k1, k1, s + k, s + k1].map { UInt16($0) }
            out += [2 * s, k1, k].map { UInt16($0) }
            out += [2 * s + 1, s + k, s + k1].map { UInt16($0) }
        }
        return out
    }()
    /// The lattice's own purple (the interior strut's, as the landed vines draw it) and the growing tips' (toward white).
    static let colour: SIMD3<Float> = {
        let c = LatticeLayoutBarsPass.colour
        return SIMD3(Float(c.r), Float(c.g), Float(c.b))
    }()
    static let tipColour = SIMD3<Float>(0.90, 0.85, 1.0)
    /// ★ notes24 item 3: the band's lighter purple (subtle: at most `bandMost` of the way to it).
    static let bandColour: SIMD3<Float> = simd_min(colour * 1.45 + 0.12, SIMD3(repeating: 1))
    static let bandMost: Float = 0.5
    /// One sweep of the band from below the floor to past the top (s), in `bandLayers` steps (a print, layer by layer); its
    /// trail below the front and its edge above, as shares of the part's height.
    static let bandPeriodS: Double = 2.8
    static let bandLayers = 40
    static let bandTrail: Float = 0.16
    static let bandEdge: Float = 0.012
    /// RED CONTROL (tests): no X-ray stand-in — with no map to open it, the closed part hides every growing vine.
    nonisolated(unsafe) static var controlNoXrayStandIn = false

    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    let indexBuffer: MTLBuffer
    private(set) var buffer: MTLBuffer?
    /// Pieces in `buffer`.
    private(set) var uploaded = 0
    /// The growth's epoch the buffer holds.
    private(set) var epoch = -1
    /// Buffers made (tests: one per doubling, never one per poll).
    private(set) var buffersMade = 0
    /// Pieces drawn in the last frame encoded.
    var lastDrawn = 0

    init(device: MTLDevice) throws {
        self.device = device
        let lib = try device.makeLibrary(source: latticeGrowthShaderSource, options: nil)
        guard let vf = lib.makeFunction(name: "grow_vertex"), let ff = lib.makeFunction(name: "grow_gbuffer") else {
            throw NSError(domain: "LatticeGrowthPass", code: 1, userInfo: [NSLocalizedDescriptionKey: "growth functions missing"])
        }
        let d = MTLRenderPipelineDescriptor()   // the prepass's attachments (OrganicVinePass's)
        d.vertexFunction = vf
        d.fragmentFunction = ff
        d.colorAttachments[0].pixelFormat = MeshRenderer.sceneDepthFormat
        d.colorAttachments[1].pixelFormat = MeshRenderer.gbufferNormalFormat
        d.colorAttachments[2].pixelFormat = MeshRenderer.gbufferAlbedoFormat
        d.depthAttachmentPixelFormat = MeshRenderer.depthFormat
        pipeline = try device.makeRenderPipelineState(descriptor: d)
        guard let ib = device.makeBuffer(bytes: Self.indices, length: MemoryLayout<UInt16>.stride * Self.indices.count,
                                         options: .storageModeShared) else {
            throw NSError(domain: "LatticeGrowthPass", code: 2, userInfo: [NSLocalizedDescriptionKey: "no index buffer"])
        }
        indexBuffer = ib
    }

    /// Another growth attached: nothing of the last one's is kept (its epochs are its own).
    func forget() { buffer = nil; uploaded = 0; epoch = -1; lastDrawn = 0 }

    /// The growth's new pieces into the buffer, after the ones already there (a new epoch starts it again).
    func sync(_ g: LatticeGrowth) {
        if g.epoch != epoch || g.count < uploaded { epoch = g.epoch; uploaded = 0; buffer = nil }
        let n = g.count
        guard n > uploaded else { return }
        let s4 = MemoryLayout<SIMD4<Float>>.stride
        let need = 2 * n * s4
        if buffer.map({ $0.length < need }) ?? true {
            let cap = Swift.max(need, 2 * (buffer?.length ?? 0), 2 * 4096 * s4)
            guard let nb = device.makeBuffer(length: cap, options: .storageModeShared) else { return }
            if let old = buffer, uploaded > 0 { memcpy(nb.contents(), old.contents(), 2 * uploaded * s4) }
            buffer = nb
            buffersMade += 1
        }
        guard let buffer else { return }
        g.pieces.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(buffer.contents() + 2 * uploaded * s4, base + 2 * uploaded * s4, 2 * (n - uploaded) * s4)
        }
        uploaded = n
    }

    /// What a frame draws of `n` pieces: all, up to `drawMost`; past it `oldCount` of the pieces before `tipsFrom`, evenly
    /// spread (piece ⌊k × oldStride⌋ for k < oldCount), and every one from `tipsFrom` on.
    static func plan(_ n: Int) -> (oldStride: Float, oldCount: Int, tipsFrom: Int) {
        guard n > drawMost else { return (1, 0, 0) }
        let tipsFrom = n - tipsKept, oldCount = drawMost - tipsKept
        return (Float(tipsFrom) / Float(oldCount), oldCount, tipsFrom)
    }

    /// ★ notes24 item 3: the band's front (world height) `t` s after the lay began working, over a lattice from `lo` to `hi`:
    /// from a little below the floor to a little past the top in `bandPeriodS`, a layer (`bandLayers`) at a time, then again.
    static func bandFront(t: Double, lo: Float, hi: Float) -> Float {
        let span = Swift.max(hi - lo, 1e-3)
        let u = Swift.max(t, 0) / bandPeriodS
        let layer = Float(Int(((u - u.rounded(.down)) * Double(bandLayers)).rounded(.down)))
        return lo - 0.1 * span + 1.2 * span * layer / Float(bandLayers)
    }
    /// The band's strength `t` s after it began: in over 0.6 s (no pop as the phase turns), then `bandMost`.
    static func bandStrength(t: Double) -> Float { bandMost * Float(Swift.min(Swift.max(t / 0.6, 0), 1)) }

    struct Frame {
        var clipFromModel: simd_float4x4
        var eyeFromModel: simd_float4x4
        var eyeNormalBasis: simd_float4x4
        var colour: SIMD4<Float>
        var tip: SIMD4<Float>
        var cue: SIMD4<Float>
        var worldY: SIMD4<Float>
        var band: SIMD4<Float>
        var bandColour: SIMD4<Float>
    }

    /// The growth into the prepass's G-buffer (its encoder, attachments and .less + write depth state). `model` places it in
    /// the world (the band rises in world height, over the part's `heights`). Returns the pieces drawn (0: nothing, or sunk).
    @discardableResult
    func encode(_ enc: MTLRenderCommandEncoder, growth g: LatticeGrowth, depthState: MTLDepthStencilState,
                clipFromModel: simd_float4x4, eyeFromModel: simd_float4x4, eyeNormalBasis: simd_float4x4,
                model: simd_float4x4, heights: (lo: Float, hi: Float), now: CFTimeInterval,
                shown: Int? = nil, playhead: Float? = nil, heightRow: SIMD4<Float>? = nil) -> Int {
        sync(g)
        lastDrawn = 0
        let size = g.alpha(at: now)
        // ★ notes24 (his "the recording of the vine growth"): the replay's first `shown` pieces (all: no replay)
        let n = Swift.min(shown ?? uploaded, uploaded)
        guard n > 0, size > 0, let buffer, enc.device === device else { return 0 }
        var band = SIMD4<Float>(0, 1, 0, 1)
        if let since = g.workingSince {
            let t = now - since
            let span = Swift.max(heights.hi - heights.lo, 1e-3)
            band = SIMD4(Self.bandFront(t: t, lo: heights.lo, hi: heights.hi), Self.bandTrail * span, Self.bandStrength(t: t),
                         Swift.max(Self.bandEdge * span, 0.02))
        }
        var f = Frame(clipFromModel: clipFromModel, eyeFromModel: eyeFromModel, eyeNormalBasis: eyeNormalBasis,
                      colour: SIMD4(Self.colour, size), tip: SIMD4(Self.tipColour, playhead ?? g.clock), cue: SIMD4(1, 0, 0, 0),
                      worldY: heightRow ?? SIMD4(model.columns.0.y, model.columns.1.y, model.columns.2.y, model.columns.3.y),
                      band: band, bandColour: SIMD4(Self.bandColour, 1))
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        func draw(_ n: Int) {
            guard n > 0 else { return }
            enc.setVertexBytes(&f, length: MemoryLayout<Frame>.stride, index: 1)
            enc.setFragmentBytes(&f, length: MemoryLayout<Frame>.stride, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: Self.indices.count, indexType: .uint16,
                                      indexBuffer: indexBuffer, indexBufferOffset: 0, instanceCount: n)
        }
        let p = Self.plan(n)
        if p.oldCount > 0 {   // the older pieces, thinned
            f.cue.x = p.oldStride; f.cue.y = 0
            draw(p.oldCount)
        }
        f.cue.x = 1; f.cue.y = Float(p.tipsFrom)
        draw(n - p.tipsFrom)
        lastDrawn = p.oldCount + n - p.tipsFrom
        Self.framesDrawn += 1
        return lastDrawn
    }
}


/// ★ notes24: what the growth does in one frame, decided once a frame (`MeshRenderer.prepareGrowth`).
struct LatticeGrowthFrame {
    /// Pieces are drawn this frame (into the G-buffer): how many (the replay's) and its playhead (the glow's clock).
    var drawn = false
    var shown = 0
    var playhead: Float = 0
    /// A lay is on screen (its walls, its replay, its landing).
    var active = false
    /// The landed lattice waits for the replay's catch-up (at most LatticeGrowthReplay.catchUpEndS).
    var holdsLanded = false
    /// How far the walls have gone (0 → 1): the dissolve with this lay's own map, or the fade to X-ray.
    var walls: Float = 1
    /// The walls open by the growth's own map (made before the lay: his walls-first, 362's gridAhead) — the landed path's
    /// own code (`LatticeLayoutBarsPass`'s map, shell clip and cut walls) on a map the landed lattice does not hold yet.
    var ownMap = false
    var mapPass: LatticeLayoutBarsPass?
}

extension MeshRenderer {
    /// The clock the growth is drawn at (tests set it; else now).
    nonisolated(unsafe) static var growthClockForTesting: CFTimeInterval?
    var growthNow: CFTimeInterval { Self.growthClockForTesting ?? CACurrentMediaTime() }
    /// ★ notes24: the growth draws this frame (into the G-buffer, lit as the lattice).
    var growthInFrame: Bool { growthFrame.drawn }

    /// Once a frame, before anything reads it: the growth's pass built the first time it has pieces (with the frame's
    /// device), the replay's playhead, and how the part opens this frame (`growthFrame`).
    func prepareGrowth(_ device: MTLDevice) {
        growthPass?.lastDrawn = 0
        var f = LatticeGrowthFrame()
        f.mapPass = growthFrame.mapPass   // kept: built once
        defer { growthFrame = f }
        guard let g = growth else { return }
        if growthPass == nil, g.count > 0, LatticeGrowthPass.lastInitError == nil {
            do { growthPass = try LatticeGrowthPass(device: device) } catch {
                LatticeGrowthPass.lastInitError = "\(error)"   // the frame draws without it; a test reads this
                NSLog("DIAG lattice growth: %@", "\(error)")
            }
        }
        let now = growthNow
        f.active = g.layOnScreen
        f.shown = g.shownCount(at: now)
        f.playhead = g.playhead(at: now)
        f.drawn = growthPass != nil && f.shown > 0 && g.alpha(at: now) > 0
        f.holdsLanded = g.holdsLanded(at: now)
        f.walls = g.wallsProgress(at: now)
        if let m = g.aheadMap, g.layOnScreen, bodyAlpha >= 0.999 {   // ★ the walls dissolve with this lay's own map
            if f.mapPass == nil { f.mapPass = try? LatticeLayoutBarsPass(device: device) }
            if let p = f.mapPass, p.gridToken != m.token { p.uploadGrid(m) }
            f.ownMap = f.mapPass?.shellClip != nil
        }
    }

    /// ★ notes24 (img 49), his fallback where opening the part is impossible: the part is drawn in X-ray while a lay is on
    /// screen and no map opens it as this lay's lattice will (the first lay of these settings, before the engine can make the
    /// map ahead), and after it lands until its own map comes — never a closed part over the growth. With the lay's map (on
    /// screen, or made before it) the part is drawn exactly as the landed lattice draws it: solid, opened by that map. Only
    /// the solid view (an opaque body); X-ray is X-ray already.
    var growthXraysBody: Bool {
        guard let g = growth, bodyAlpha >= 0.999, !LatticeGrowthPass.controlNoXrayStandIn else { return false }
        guard growthFrame.active || growthFrame.drawn || g.landedHold else { return false }
        if growthFrame.ownMap { return false }
        let mapShown = layoutBarsInFrame && drawnLayoutBars?.shellClip != nil
        return !(mapShown && (g.sealed || g.mapOpensFaces))
    }

    /// The body's drawn opacity while the X-ray stands in: faded from solid to the Lattice page's X-ray over the walls' part of
    /// the lay (his walls-first), then the X-ray.
    var growthXrayAlpha: Float {
        let ghost = LatticeLayoutPreview.ghostAlpha
        return 1 - (1 - ghost) * Swift.min(Swift.max(growthFrame.walls, 0), 1)
    }

    /// ★ his walls-first: the shell clip and its map while the walls dissolve with the growth's own map — the share of the
    /// latticed surface still standing rides in `eye.w` (`shell_standing` in the body's fragments). nil: not this frame.
    var growthShellClip: (clip: ShellClipUniform, texture: MTLTexture)? {
        guard growthFrame.ownMap, let p = growthFrame.mapPass, var u = p.shellClip, let t = p.gridTexture else { return nil }
        u.eye.w = 1 - Swift.min(Swift.max(growthFrame.walls, 0), 1)
        return (u, t)
    }

    /// The cut walls of the growth's own map into the prepass (the landed lattice's walls, its code). True when drawn.
    func encodeGrowthWalls(_ enc: MTLRenderCommandEncoder, depthState: MTLDepthStencilState, clipFromModel: simd_float4x4,
                           eyeFromModel: simd_float4x4, eyeNormalBasis: simd_float4x4) -> Bool {
        guard growthFrame.ownMap, let p = growthFrame.mapPass else { return false }
        return p.encodeWalls(enc, depthState: depthState, clipFromModel: clipFromModel, eyeFromModel: eyeFromModel,
                             eyeNormalBasis: eyeNormalBasis)
    }

    /// The growth into the prepass's G-buffer, after the landed lattice and its walls (same encoder, attachments and depth
    /// state). Returns the pieces drawn.
    @discardableResult
    func encodeGrowthGBuffer(_ enc: MTLRenderCommandEncoder, depthState: MTLDepthStencilState, clipFromModel: simd_float4x4,
                             eyeFromModel: simd_float4x4, eyeNormalBasis: simd_float4x4, model: simd_float4x4) -> Int {
        guard growthInFrame, let g = growth, let pass = growthPass else { return 0 }
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        // ★ notes29: laid standing on the face he kept, the band rises along the print's up (the part's own mm); else the world's
        let row: SIMD4<Float>? = g.printUp.map { SIMD4(simd_normalize($0), 0) }
        if let b = mesh?.bounds, !b.isEmpty {
            for x in [b.min.x, b.max.x] { for y in [b.min.y, b.max.y] { for z in [b.min.z, b.max.z] {
                let w = row.map { simd_dot($0, SIMD4<Float>(x, y, z, 1)) } ?? (model * SIMD4<Float>(x, y, z, 1)).y
                lo = Swift.min(lo, w); hi = Swift.max(hi, w)
            }}}
        } else { lo = 0; hi = 1 }
        return pass.encode(enc, growth: g, depthState: depthState, clipFromModel: clipFromModel, eyeFromModel: eyeFromModel,
                           eyeNormalBasis: eyeNormalBasis, model: model, heights: (lo, hi), now: growthNow,
                           shown: growthFrame.shown, playhead: growthFrame.playhead, heightRow: row)
    }

    /// The growth this view draws (the Lattice page's preview's), or none. Returns true when the frame must be redrawn.
    @discardableResult
    func applyGrowth(_ g: LatticeGrowth?) -> Bool {
        guard growth !== g else { return false }
        growth = g
        growthPass?.forget()
        if g == nil { growthPass = nil; growthFrame = LatticeGrowthFrame() }
        return true
    }
}
#endif
