// LatticeGrowthPass — ★ his 11-22 ("Could the user literally *watch* the lattice grow from nothing?"): the Organic lay's vines
// as they are laid (LatticeGrowth), drawn in the 3D view's own colour pass while the lay runs.
//
//   * line quads of a constant SCREEN width (thin at any zoom), each piece run half a width past its ends so a vine's joints
//     close; the lattice's own purple (the interior strut's), the farther dimmer, the newest pieces (the growing tips) wider
//     and brighter, cooling over about two polls;
//   * drawn over the part as the preview draws it (depth always, no depth written: the vines are inside the part, and a
//     growth hidden by the body would show nothing), premultiplied over, faded out when the finished lattice lands;
//   * ONE append-only buffer: each poll's new pieces are copied in after the last (grown by doubling, the old part copied
//     once per doubling), never the whole set again; past `drawMost` pieces the older ones are thinned (every k-th), the
//     newest `tipsKept` never (smooth on his iPad with 500k+ pieces).
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
    float4   colour;   // rgb: the lattice's purple; a: the fade (1, toward 0 once the lattice landed)
    float4   tip;      // rgb: the growing tips' colour; a: the clock (the newest poll's number)
    float4   view;     // the target's width and height (px), the line's half width and the tips' (px)
    float4   cue;      // the part's nearest and farthest eye depth; the stride through the pieces; the first piece
};

struct GrowVOut {
    float4 pos [[position]];
    float4 colour;     // premultiplied
};

vertex GrowVOut grow_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device float4* P [[buffer(0)]],
                            constant GrowFrame& F [[buffer(1)]]) {
    uint i = uint(F.cue.w + 0.5) + uint(float(iid) * max(F.cue.z, 1.0));
    float4 A = P[2 * i], B = P[2 * i + 1];
    float glow = exp(-max(F.tip.a - A.w, 0.0) / 1.2);           // the newest 1, a poll older about 0.4
    float4 ca = F.clipFromModel * float4(A.xyz, 1.0);
    float4 cb = F.clipFromModel * float4(B.xyz, 1.0);
    float wa = max(ca.w, 1e-4), wb = max(cb.w, 1e-4);
    float2 half_ = 0.5 * F.view.xy;
    float2 sa = ca.xy / wa * half_, sb = cb.xy / wb * half_;     // pixels from the centre
    float2 d = sb - sa;
    float len = length(d);
    d = len > 1e-4 ? d / len : float2(1.0, 0.0);
    float2 n = float2(-d.y, d.x);
    float hw = mix(F.view.z, F.view.w, glow);
    const int2 corner[6] = { int2(0, -1), int2(1, -1), int2(0, 1), int2(0, 1), int2(1, -1), int2(1, 1) };
    int2 c = corner[vid % 6];
    bool atB = c.x == 1;
    float2 s = (atB ? sb + d * hw : sa - d * hw) + n * (float(c.y) * hw);
    float w = atB ? wb : wa;
    float z = atB ? cb.z : ca.z;
    GrowVOut o;
    o.pos = float4(s / half_ * w, z, w);
    float ez = -(F.eyeFromModel * float4(atB ? B.xyz : A.xyz, 1.0)).z;
    float far01 = clamp((ez - F.cue.x) / max(F.cue.y - F.cue.x, 1e-3), 0.0, 1.0);
    float3 rgb = mix(F.colour.rgb * mix(1.0, 0.55, far01), F.tip.rgb, glow);
    float a = F.colour.a * mix(0.85, 1.0, glow);
    o.colour = float4(rgb * a, a);
    return o;
}

fragment float4 grow_fragment(GrowVOut in [[stage_in]]) { return in.colour; }
"""

/// The growing vines, uploaded as they come, drawn into the colour pass.
final class LatticeGrowthPass {
    nonisolated(unsafe) static var lastInitError: String?
    /// Frames that drew growth (tests: it was on screen).
    nonisolated(unsafe) static var framesDrawn = 0
    /// At most this many pieces a frame: past it the older ones are thinned, the newest `tipsKept` never.
    static let drawMost = 600_000
    static let tipsKept = 60_000
    /// The lattice's own purple (the interior strut's, as the bars draw it) and the growing tips' (brighter, toward white).
    static let colour: SIMD3<Float> = {
        let c = LatticeStructureColour.interior
        return SIMD3(Float(c.r), Float(c.g), Float(c.b))
    }()
    static let tipColour = SIMD3<Float>(0.90, 0.85, 1.0)

    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    private(set) var buffer: MTLBuffer?
    /// Pieces in `buffer`.
    private(set) var uploaded = 0
    /// The growth's epoch the buffer holds.
    private(set) var epoch = -1
    /// Buffers made (tests: one per doubling, never one per poll).
    private(set) var buffersMade = 0
    /// Pieces drawn in the last frame encoded.
    var lastDrawn = 0

    init(device: MTLDevice, sampleCount: Int) throws {
        self.device = device
        let lib = try device.makeLibrary(source: latticeGrowthShaderSource, options: nil)
        guard let vf = lib.makeFunction(name: "grow_vertex"), let ff = lib.makeFunction(name: "grow_fragment") else {
            throw NSError(domain: "LatticeGrowthPass", code: 1, userInfo: [NSLocalizedDescriptionKey: "growth functions missing"])
        }
        let gd = MTLRenderPipelineDescriptor()
        gd.vertexFunction = vf
        gd.fragmentFunction = ff
        gd.colorAttachments[0].pixelFormat = MeshRenderer.colorFormat
        gd.colorAttachments[0].isBlendingEnabled = true            // premultiplied over
        gd.colorAttachments[0].rgbBlendOperation = .add
        gd.colorAttachments[0].alphaBlendOperation = .add
        gd.colorAttachments[0].sourceRGBBlendFactor = .one
        gd.colorAttachments[0].sourceAlphaBlendFactor = .one
        gd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        gd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        gd.depthAttachmentPixelFormat = MeshRenderer.depthFormat
        gd.rasterSampleCount = sampleCount   // the 4× MSAA colour pass (MSAAPipelineSampleCountTests' rule: the iPad aborts else)
        pipeline = try device.makeRenderPipelineState(descriptor: gd)
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .always
        ds.isDepthWriteEnabled = false
        guard let st = device.makeDepthStencilState(descriptor: ds) else {
            throw NSError(domain: "LatticeGrowthPass", code: 2, userInfo: [NSLocalizedDescriptionKey: "no depth state"])
        }
        depthState = st
    }

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

    struct Frame {
        var clipFromModel: simd_float4x4
        var eyeFromModel: simd_float4x4
        var colour: SIMD4<Float>
        var tip: SIMD4<Float>
        var view: SIMD4<Float>
        var cue: SIMD4<Float>
    }

    /// The line's half width (px) on a target whose short side is `short` px: about 0.09 % of it (2 pt on his 13″ iPad),
    /// never under 1 px; the tips 1.8 times it.
    static func halfWidth(short: Float) -> Float { Swift.min(Swift.max(short * 0.0009, 1), 3) }

    /// The growth into the colour pass. Returns the pieces drawn (0: nothing to draw, or faded out).
    @discardableResult
    func encode(_ enc: MTLRenderCommandEncoder, growth g: LatticeGrowth, clipFromModel: simd_float4x4,
                eyeFromModel: simd_float4x4, target: SIMD2<Float>, centre: SIMD3<Float>, radius: Float,
                now: CFTimeInterval = CACurrentMediaTime()) -> Int {
        sync(g)
        lastDrawn = 0
        let fade = g.alpha(at: now)
        guard uploaded > 0, fade > 0, let buffer, enc.device === device else { return 0 }
        let ez = -(eyeFromModel * SIMD4(centre, 1)).z
        let hw = Self.halfWidth(short: Swift.min(target.x, target.y))
        var f = Frame(clipFromModel: clipFromModel, eyeFromModel: eyeFromModel, colour: SIMD4(Self.colour, fade),
                      tip: SIMD4(Self.tipColour, g.clock), view: SIMD4(target.x, target.y, hw, 1.8 * hw),
                      cue: SIMD4(ez - radius, ez + radius, 1, 0))
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        let p = Self.plan(uploaded)
        if p.oldCount > 0 {   // the older pieces, thinned
            f.cue.z = p.oldStride; f.cue.w = 0
            enc.setVertexBytes(&f, length: MemoryLayout<Frame>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: p.oldCount)
        }
        f.cue.z = 1; f.cue.w = Float(p.tipsFrom)
        enc.setVertexBytes(&f, length: MemoryLayout<Frame>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: uploaded - p.tipsFrom)
        lastDrawn = p.oldCount + uploaded - p.tipsFrom
        Self.framesDrawn += 1
        return lastDrawn
    }
}

extension MeshRenderer {
    /// ★ his 11-22: the growing vines over the frame (the last thing the colour pass draws). Nothing when no growth is attached.
    func encodeGrowth(_ enc: MTLRenderCommandEncoder, clipFromModel: simd_float4x4, eyeFromModel: simd_float4x4,
                      target: (w: Int, h: Int)) {
        guard let g = growth else { growthPass?.lastDrawn = 0; return }
        if growthPass == nil {
            guard g.count > 0, LatticeGrowthPass.lastInitError == nil else { return }
            do { growthPass = try LatticeGrowthPass(device: enc.device, sampleCount: sampleCount) } catch {
                LatticeGrowthPass.lastInitError = "\(error)"   // the frame draws without it; a test reads this
                NSLog("DIAG lattice growth: %@", "\(error)")
                return
            }
        }
        let b = mesh?.bounds
        growthPass?.encode(enc, growth: g, clipFromModel: clipFromModel, eyeFromModel: eyeFromModel,
                           target: SIMD2(Float(Swift.max(target.w, 1)), Float(Swift.max(target.h, 1))),
                           centre: b?.center ?? .zero, radius: Swift.max(b?.radius ?? 1, 1e-3))
    }

    /// The growth this view draws (the Lattice page's preview's), or none. Returns true when the frame must be redrawn.
    @discardableResult
    func applyGrowth(_ g: LatticeGrowth?) -> Bool {
        guard growth !== g else { return false }
        growth = g
        if g == nil { growthPass = nil }
        return true
    }
}
#endif
