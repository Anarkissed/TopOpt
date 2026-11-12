// LatticeLayoutBarsPass — the NEW ENGINE's preview (the lattice rebuild, stage E; his blitz of 2026-11-12, the reviewer's go
// 20:21Z): the bars core's lattice_layout lays (LatticeLayoutSession.Result.bars, 7 floats each: a, b, width) drawn as
// round capsules, ray-cast in their own boxes (the organic impostors' way, `organicCapsuleShaderSource`) into #354's G-buffer,
// so #354's lattice shade, AO and creases light them exactly as they light the old lattice. Behind the switch "New engine
// (test)", default OFF: with it off this pass does not exist and every frame is byte-for-byte today's.
//
// ★ P7 (the rebuild's rule from his 11-11 crash): the bars, a list that grows with the part, are ONE MTLBuffer bound with
// setVertexBuffer / setFragmentBuffer — never setFragmentBytes (his v2 stand is 37,233 bars, ~1.2 MB). The per-frame uniform
// is a fixed 256-byte struct.
// ★ NO CLIP: core's bars are already cut to the part (the old impostors clip against the old engine's part and region
// fields; these have none). The ray comes from the inverse clip matrix, so Orthographic and Perspective are both right.
// ★ THE GHOST: the bars are inside the part, so the page draws the body see-through while this pass is on, and the body
// follows the Flexible pass's two rules (MeshRenderer+FlexibleLattice): out of the G-buffer, drawn after the shade.
// ★ PREVIEW IS THE SPEC, not yet: the print file squares the undersides of flat bridges and adds posts; this first cut draws
// every bar round, and the page says so in one plain line (LatticeLayoutPreview.roundBarsLine).

#if canImport(MetalKit)
import MetalKit
import simd

/// What the page hands the renderer: the bars, keyed by a token (a new token uploads; the same token never re-uploads).
public struct LatticeLayoutBarsInputs: Equatable {
    public var token: Int
    /// 7 per bar: a xyz, b xyz, width mm — the part's own coordinates (the viewer mesh's).
    public var bars: [Float]
    public var hidden: Bool
    public init(token: Int, bars: [Float], hidden: Bool = false) { self.token = token; self.bars = bars; self.hidden = hidden }
    public static func == (a: Self, b: Self) -> Bool { a.token == b.token && a.hidden == b.hidden }
}

let latticeLayoutBarsShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct BarFrame {
    float4x4 clipFromModel;
    float4x4 modelFromClip;
    float4x4 eyeFromModel;
    float4x4 eyeNormalBasis;
    float4   albedo;
};

struct BarVOut {
    float4 pos [[position]];
    float4 cpos;                 // the clip position again, for this fragment's own ray
    uint   iid [[flat]];
};

// The box around bar `iid`: its ends pushed out by R along the axis, ±R across.
vertex BarVOut bar_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device float4* bars [[buffer(0)]],
                          constant BarFrame& F [[buffer(1)]]) {
    float4 A = bars[2 * iid], B = bars[2 * iid + 1];
    float R = max(A.w, 1e-4);
    float3 ax = B.xyz - A.xyz;
    float len = length(ax);
    float3 u = len > 1e-6 ? ax / len : float3(0.0, 0.0, 1.0);
    float3 hlp = abs(u.x) < 0.9 ? float3(1.0, 0.0, 0.0) : float3(0.0, 1.0, 0.0);
    float3 v = normalize(cross(u, hlp));
    float3 w = cross(u, v);
    const int idx[36] = { 0,1,2, 2,1,3, 4,6,5, 5,6,7, 0,4,1, 1,4,5,
                          2,3,6, 6,3,7, 0,2,4, 4,2,6, 1,5,3, 3,5,7 };
    int c = idx[vid % 36];
    float3 e = (c & 1) ? (B.xyz + u * R) : (A.xyz - u * R);
    float3 p = e + ((c & 2) ? v * R : -v * R) + ((c & 4) ? w * R : -w * R);
    BarVOut o;
    o.pos = F.clipFromModel * float4(p, 1.0);
    o.cpos = o.pos;
    o.iid = iid;
    return o;
}

static float bar_sphere(float3 ro, float3 rd, float3 c, float r) {
    float3 oc = ro - c;
    float b = dot(rd, oc);
    float cc = dot(oc, oc) - r * r;
    float h = b * b - cc;
    if (h < 0.0) { return -1.0; }
    return -b - sqrt(h);
}

// Ray vs sphere-swept segment (the organic impostors' cap_intersect): t ≥ 0, or −1.
static float bar_intersect(float3 ro, float3 rd, float3 pa, float3 pb, float r) {
    float3 ba = pb - pa;
    float3 oa = ro - pa;
    float baba = dot(ba, ba), bard = dot(ba, rd), baoa = dot(ba, oa);
    float rdoa = dot(rd, oa), oaoa = dot(oa, oa);
    float a = baba - bard * bard;
    float b = baba * rdoa - baoa * bard;
    float c = baba * oaoa - baoa * baoa - r * r * baba;
    float h = b * b - a * c;
    float t = -1.0;
    if (a > 1e-7 * max(baba, 1e-9)) {
        if (h < 0.0) { return -1.0; }
        t = (-b - sqrt(h)) / a;
        float y = baoa + t * bard;
        if (y > 0.0 && y < baba) { return t >= 0.0 ? t : -1.0; }
        t = bar_sphere(ro, rd, (y <= 0.0) ? pa : pb, r);
    } else {
        float ta = bar_sphere(ro, rd, pa, r), tb = bar_sphere(ro, rd, pb, r);
        t = (ta < 0.0) ? tb : ((tb < 0.0) ? ta : min(ta, tb));
    }
    return t >= 0.0 ? t : -1.0;
}

static float3 bar_normal(float3 p, float3 pa, float3 pb) {
    float3 ba = pb - pa;
    float h = clamp(dot(p - pa, ba) / max(dot(ba, ba), 1e-9), 0.0, 1.0);
    return normalize(p - pa - h * ba);
}

struct BarGBuf {
    float  eyeZ    [[color(0)]];
    float4 enormal [[color(1)]];
    float4 albedo  [[color(2)]];
    float  depth   [[depth(any)]];
};

fragment BarGBuf bar_gbuffer(BarVOut in [[stage_in]],
                             const device float4* bars [[buffer(0)]],
                             constant BarFrame& F [[buffer(1)]]) {
    float4 A = bars[2 * in.iid], B = bars[2 * in.iid + 1];
    float R = max(A.w, 1e-4);
    // this fragment's ray, from the inverse clip matrix: right for Orthographic and Perspective alike
    float2 ndc = in.cpos.xy / in.cpos.w;
    float4 n0 = F.modelFromClip * float4(ndc, 0.0, 1.0);
    float4 n1 = F.modelFromClip * float4(ndc, 1.0, 1.0);
    float3 ro = n0.xyz / n0.w;
    float3 rd = normalize(n1.xyz / n1.w - ro);
    float t = bar_intersect(ro, rd, A.xyz, B.xyz, R);
    if (t < 0.0) { discard_fragment(); }
    float3 p = ro + rd * t;
    float3 n = bar_normal(p, A.xyz, B.xyz);
    float4 clip = F.clipFromModel * float4(p, 1.0);
    float3 eyeP = (F.eyeFromModel * float4(p, 1.0)).xyz;
    float3 eyeN = normalize((F.eyeNormalBasis * float4(n, 0.0)).xyz);
    if (eyeN.z < 0.0) { eyeN = -eyeN; }
    BarGBuf o;
    o.eyeZ = -eyeP.z;
    o.enormal = float4(eyeN, 0.0);
    o.albedo = float4(F.albedo.rgb, 1.0);
    o.depth = clip.z / clip.w;
    return o;
}
"""

/// The bars, uploaded once per token, drawn into the G-buffer.
final class LatticeLayoutBarsPass {
    static var lastInitError: String?
    /// The strut colour: the old preview's interior strut (LatticeStructureColour), so the two engines read alike.
    static let colour = LatticeStructureColour.interior

    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    private(set) var buffer: MTLBuffer?
    private(set) var count = 0
    private(set) var token = -1
    var hidden = false
    var isDrawable: Bool { !hidden && count > 0 && buffer != nil }

    init(device: MTLDevice) throws {
        self.device = device
        let lib = try device.makeLibrary(source: latticeLayoutBarsShaderSource, options: nil)
        guard let vf = lib.makeFunction(name: "bar_vertex"), let ff = lib.makeFunction(name: "bar_gbuffer") else {
            throw NSError(domain: "LatticeLayoutBarsPass", code: 1, userInfo: [NSLocalizedDescriptionKey: "bar functions missing"])
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vf
        d.fragmentFunction = ff
        d.colorAttachments[0].pixelFormat = MeshRenderer.sceneDepthFormat
        d.colorAttachments[1].pixelFormat = MeshRenderer.gbufferNormalFormat
        d.colorAttachments[2].pixelFormat = MeshRenderer.gbufferAlbedoFormat
        d.depthAttachmentPixelFormat = MeshRenderer.depthFormat
        pipeline = try device.makeRenderPipelineState(descriptor: d)
    }

    /// The bars into ONE buffer (P7), packed (a.xyz, r)(b.xyz, 0).
    func upload(_ inputs: LatticeLayoutBarsInputs) {
        token = inputs.token
        hidden = inputs.hidden
        let packed = Self.pack(inputs.bars)
        count = packed.count / 2
        buffer = packed.isEmpty ? nil : device.makeBuffer(bytes: packed, length: MemoryLayout<SIMD4<Float>>.stride * packed.count,
                                                          options: .storageModeShared)
    }

    /// 7 floats per bar → two float4 per bar (radius = width / 2). Tests read it.
    static func pack(_ bars: [Float]) -> [SIMD4<Float>] {
        let n = bars.count / 7
        var out = [SIMD4<Float>]()
        out.reserveCapacity(2 * n)
        for i in 0..<n {
            let k = 7 * i
            out.append(SIMD4(bars[k], bars[k + 1], bars[k + 2], 0.5 * bars[k + 6]))
            out.append(SIMD4(bars[k + 3], bars[k + 4], bars[k + 5], 0))
        }
        return out
    }

    struct Frame {
        var clipFromModel: simd_float4x4
        var modelFromClip: simd_float4x4
        var eyeFromModel: simd_float4x4
        var eyeNormalBasis: simd_float4x4
        var albedo: SIMD4<Float>
    }

    /// Bars into the prepass's G-buffer (its encoder, attachments and .less + write depth state).
    func encodeGBuffer(_ enc: MTLRenderCommandEncoder, depthState: MTLDepthStencilState,
                       clipFromModel: simd_float4x4, eyeFromModel: simd_float4x4, eyeNormalBasis: simd_float4x4) -> Bool {
        guard isDrawable, let buffer, enc.device === device else { return false }
        let c = Self.colour
        var f = Frame(clipFromModel: clipFromModel, modelFromClip: clipFromModel.inverse, eyeFromModel: eyeFromModel,
                      eyeNormalBasis: eyeNormalBasis, albedo: SIMD4(Float(c.r), Float(c.g), Float(c.b), 1))
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&f, length: MemoryLayout<Frame>.stride, index: 1)       // fixed size, never a growing list
        enc.setFragmentBuffer(buffer, offset: 0, index: 0)
        enc.setFragmentBytes(&f, length: MemoryLayout<Frame>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: count)
        return true
    }
}

extension MeshRenderer {
    /// The new engine's bars draw this frame: present, uploaded, not hidden — and #354's lattice shade built (it lights them).
    var layoutBarsInFrame: Bool { layoutBars?.isDrawable == true && latticePipelinesDidBuild }

    /// THE ONE ENTRY POINT for the new engine's bars (called from the view's apply). Uploads once per token; nil tears the
    /// pass down. Returns true when the frame must be redrawn.
    @discardableResult
    func applyLayoutBars(_ inputs: LatticeLayoutBarsInputs?, device: MTLDevice?) -> Bool {
        guard let inputs else {
            guard layoutBars != nil else { return false }
            layoutBars = nil
            return true
        }
        if layoutBars == nil {
            guard let device, LatticeLayoutBarsPass.lastInitError == nil else { return false }
            do { layoutBars = try LatticeLayoutBarsPass(device: device) } catch {
                LatticeLayoutBarsPass.lastInitError = "\(error)"
                NSLog("DIAG layout bars: %@", "\(error)")
                return false
            }
        }
        guard let pass = layoutBars else { return false }
        if pass.token != inputs.token { pass.upload(inputs); return true }
        if pass.hidden != inputs.hidden { pass.hidden = inputs.hidden; return true }
        return false
    }
}
#endif
