// OrganicVinePass — the new engine's Organic vines drawn as he approved them on 11-19 ("The organic looks great now!"), fast
// enough for his stand on the iPad (Grown at his settings: about 150,000 struts):
//   * BODIES: each OrganicVineShape piece a real tube (10 sides) between two rings that neighbouring pieces share exactly
//     (no crack, no twist), its normal smooth around and along: ordinary triangles, so the depth test rejects hidden ones
//     before they are shaded (the ray-cast bars' impostors could not, which is what lagged past ~37k bars);
//   * ROUND ENDS: every run end a sphere of its radius (an analytic impostor; a few per vine);
//   * JOINTS: where vines meet, the vines there blended by a polynomial smooth-min (a short march inside the joint's sphere).
// All three write the prepass G-buffer the bars write (eye z, normal, albedo, depth), so the deferred shading, the solid view's
// cut walls and the body treat the vines as they treat bars. Built once per lay (`upload`), drawn every frame (`encode`).
import Foundation
import Metal
import simd

let organicVineShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VineFrame {
    float4x4 clipFromModel;
    float4x4 modelFromClip;
    float4x4 eyeFromModel;
    float4x4 eyeNormalBasis;
    float4   albedo;
    float4   blend;        // x = the joints' smooth-min k (mm)
};
struct VineGBuf {
    float  eyeZ    [[color(0)]];
    float4 enormal [[color(1)]];
    float4 albedo  [[color(2)]];
};
struct VineGBufDepth {
    float  eyeZ    [[color(0)]];
    float4 enormal [[color(1)]];
    float4 albedo  [[color(2)]];
    float  depth   [[depth(greater)]];   // an impostor's surface is never in front of its box: early depth test kept
};

// ── the bodies: a 10-sided tube per piece; (a, ra), (b, rb), (ta, -), (tb, -), (va, -), (vb, -) ──
constant int kSides = 16;
// the ring's corners sit a little outside the true radius, its facets' middles a little inside: on average, the true round
// surface (the joints' exact surface meets the tube without a step, so the outline draws no seam)
constant float kRingScale = 2.0 / (1.0 + 0.98078528);   // 2 / (1 + cos(pi / 16))
struct TubeVOut {
    float4 pos [[position]];
    float  ez;
    float3 en;
};
vertex TubeVOut tube_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device float4* P [[buffer(0)]], constant VineFrame& F [[buffer(1)]]) {
    const device float4* q = P + 6 * iid;
    const int ring[6] = { 0, 1, 0, 0, 1, 1 };
    const int step[6] = { 0, 0, 1, 1, 0, 1 };
    // the side: 6 x kSides vertices; then a flat end disc at a (3 x kSides) and at b (3 x kSides), drawn only where the
    // file closes the tube flat (q[2].w / q[3].w = 1: into the solid, or cut by the part's surface)
    int side = 6 * kSides;
    bool disc = int(vid) >= side;
    int r, k;
    float ang;
    if (!disc) {
        int quad = int(vid) / 6, corner = int(vid) % 6;
        r = ring[corner];
        ang = float(quad + step[corner]) * (6.283185307 / float(kSides));
        k = 1;
    } else {
        int d = int(vid) - side;
        r = d / (3 * kSides);
        int tri = (d % (3 * kSides)) / 3, corner = d % 3;
        ang = float(tri + (corner == 2 ? 1 : 0)) * (6.283185307 / float(kSides));
        bool on = (r == 0 ? q[2].w : q[3].w) > 0.5;
        k = (!on || corner == 0) ? 0 : 1;   // corner 0 the centre; an end not closed: every corner at the centre (no area)
    }
    // ★ his rule 11-19, "The drawing follows the print file. Always.": the file's tube rule. Each ring is the bar's own
    // circle pushed along the bar onto its end's plane (q[2] / q[3]: the bar itself = a square end, the bisector of two
    // bars = a mitre), so two bars' rings at a mitre are one ring (OrganicVineShape.tubeRingPoint is the same arithmetic)
    float3 c = r == 0 ? q[0].xyz : q[1].xyz;
    float rad = r == 0 ? q[0].w : q[1].w;
    float3 bar = q[1].xyz - q[0].xyz;
    float3 t = length(bar) > 1e-9 ? normalize(bar) : float3(0, 0, 1);
    float3 n = r == 0 ? q[2].xyz : q[3].xyz;
    float3 v = r == 0 ? q[4].xyz : q[5].xyz;
    v = normalize(v - dot(v, t) * t);
    float3 w = cross(t, v);
    float3 radial = cos(ang) * v + sin(ang) * w;
    float3 off = radial * (rad * kRingScale) * float(k);
    float dn = dot(t, n);
    float3 p = c + off + t * (abs(dn) > 1e-3 ? -dot(off, n) / dn : 0.0);
    TubeVOut o;
    o.pos = F.clipFromModel * float4(p, 1.0);
    o.ez = -(F.eyeFromModel * float4(p, 1.0)).z;
    o.en = (F.eyeNormalBasis * float4(disc ? (r == 0 ? -t : t) : radial, 0.0)).xyz;
    return o;
}
fragment VineGBuf tube_gbuffer(TubeVOut in [[stage_in]], constant VineFrame& F [[buffer(1)]]) {
    float3 n = normalize(in.en);
    if (n.z < 0.0) { n = -n; }
    VineGBuf o;
    o.eyeZ = in.ez;
    o.enormal = float4(n, 0.0);
    o.albedo = float4(F.albedo.rgb, 1.0);
    return o;
}

// ── impostor helpers ──
struct BoxVOut {
    float4 pos [[position]];
    float4 cpos;
    uint   iid [[flat]];
};
static float4 box_corner(uint vid, float4 S, constant VineFrame& F) {
    const int idx[36] = { 0,1,2, 2,1,3, 4,6,5, 5,6,7, 0,4,1, 1,4,5,
                          2,3,6, 6,3,7, 0,2,4, 4,2,6, 1,5,3, 3,5,7 };
    int c = idx[vid % 36];
    float3 p = S.xyz + float3((c & 1) ? S.w : -S.w, (c & 2) ? S.w : -S.w, (c & 4) ? S.w : -S.w);
    return F.clipFromModel * float4(p, 1.0);
}
static void vine_ray(float4 cpos, constant VineFrame& F, thread float3& ro, thread float3& rd) {
    float2 ndc = cpos.xy / cpos.w;
    float4 n0 = F.modelFromClip * float4(ndc, 0.0, 1.0);
    float4 n1 = F.modelFromClip * float4(ndc, 1.0, 1.0);
    ro = n0.xyz / n0.w;
    rd = normalize(n1.xyz / n1.w - ro);
}
static VineGBufDepth vine_out(float3 p, float3 n, constant VineFrame& F) {
    float4 clip = F.clipFromModel * float4(p, 1.0);
    float3 eyeP = (F.eyeFromModel * float4(p, 1.0)).xyz;
    float3 eyeN = normalize((F.eyeNormalBasis * float4(n, 0.0)).xyz);
    if (eyeN.z < 0.0) { eyeN = -eyeN; }
    VineGBufDepth o;
    o.eyeZ = -eyeP.z;
    o.enormal = float4(eyeN, 0.0);
    o.albedo = float4(F.albedo.rgb, 1.0);
    o.depth = clip.z / clip.w;
    return o;
}

// ── the round ends: a sphere per run end (xyz, r) ──
vertex BoxVOut cap_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device float4* caps [[buffer(0)]], constant VineFrame& F [[buffer(1)]]) {
    BoxVOut o;
    o.pos = box_corner(vid, caps[iid], F);
    o.cpos = o.pos;
    o.iid = iid;
    return o;
}
fragment VineGBufDepth cap_gbuffer(BoxVOut in [[stage_in]], const device float4* caps [[buffer(0)]],
                                   constant VineFrame& F [[buffer(1)]]) {
    float4 S = caps[in.iid];
    float3 ro, rd;
    vine_ray(in.cpos, F, ro, rd);
    float3 oc = ro - S.xyz;
    float b = dot(rd, oc), h = b * b - (dot(oc, oc) - S.w * S.w);
    if (h < 0.0) { discard_fragment(); }
    float t = -b - sqrt(h);
    if (t < 0.0) { discard_fragment(); }
    float3 p = ro + rd * t;
    return vine_out(p, normalize(p - S.xyz), F);
}

// ── the joints: inside each joint's sphere, its vines blended (plain union within a vine, smooth-min across vines) ──
struct VineJoint { float4 sphere; uint first; uint count; uint pad0; uint pad1; };

static float vine_sd_round_cone(float3 p, float3 a, float3 b, float r1, float r2) {
    float3 ba = b - a; float l2 = dot(ba, ba);
    if (l2 < 1e-10) { return length(p - a) - max(r1, r2); }
    float rr = r1 - r2; float a2 = l2 - rr * rr;
    if (a2 <= 1e-9) { return min(length(p - a) - r1, length(p - b) - r2); }
    float il2 = 1.0 / l2; float3 pa = p - a; float y = dot(pa, ba); float z = y - l2;
    float3 xv = pa * l2 - ba * y; float x2 = dot(xv, xv); float y2 = y * y * l2; float z2 = z * z * l2;
    float k = sign(rr) * rr * rr * x2;
    if (sign(z) * a2 * z2 > k) { return sqrt(x2 + z2) * il2 - r2; }
    if (sign(y) * a2 * y2 < k) { return sqrt(x2 + y2) * il2 - r1; }
    return (sqrt(x2 * a2 * il2) + y * rr) * il2 - r1;
}
// Ray vs round cone (sphere-swept cone, pa radius ra to pb radius rb): the nearest t >= 0, or 1e20.
static float joint_round_cone_hit(float3 ro, float3 rd, float3 pa, float3 pb, float ra, float rb) {
    float3 ba = pb - pa, oa = ro - pa, ob = ro - pb;
    float rr = ra - rb;
    float m0 = dot(ba, ba), m1 = dot(ba, oa), m2 = dot(ba, rd), m3 = dot(rd, oa), m5 = dot(oa, oa);
    float m6 = dot(ob, rd), m7 = dot(ob, ob);
    float d2 = m0 - rr * rr;
    float best = 1e20;
    if (d2 > 1e-9) {
        float k2 = d2 - m2 * m2;
        float k1 = d2 * m3 - m1 * m2 + m2 * rr * ra;
        float k0 = d2 * m5 - m1 * m1 + m1 * rr * ra * 2.0 - m0 * ra * ra;
        float h = k1 * k1 - k0 * k2;
        if (h >= 0.0 && abs(k2) > 1e-9) {
            float t = (-sqrt(h) - k1) / k2;
            float y = m1 - ra * rr + t * m2;
            if (y > 0.0 && y < d2) { best = t; }
        }
    }
    float h1 = m3 * m3 - m5 + ra * ra;
    if (h1 > 0.0) { best = min(best, -m3 - sqrt(h1)); }
    float h2 = m6 * m6 - m7 + rb * rb;
    if (h2 > 0.0) { best = min(best, -m6 - sqrt(h2)); }
    return best;
}
static float joint_smin(float a, float b, float k) {
    if (k <= 0.0) { return min(a, b); }
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}
static float joint_sd(float3 p, VineJoint J, const device float4* P, const device uint* list,
                      const device uint* vineOf, float k) {
    float total = 1e3, vineD = 1e3;
    uint cur = 0xffffffffu;
    for (uint i = 0; i < J.count; ++i) {
        uint pi = list[J.first + i];
        uint v = vineOf[pi];
        if (v != cur) { if (cur != 0xffffffffu) { total = joint_smin(total, vineD, k); } cur = v; vineD = 1e3; }
        const device float4* q = P + 6 * pi;
        vineD = min(vineD, vine_sd_round_cone(p, q[0].xyz, q[1].xyz, q[0].w, q[1].w));
    }
    if (cur != 0xffffffffu) { total = joint_smin(total, vineD, k); }
    return total;
}
// a square facing the camera at the sphere's front, a little larger than its outline (perspective widens it)
vertex BoxVOut joint_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device VineJoint* joints [[buffer(0)]], constant VineFrame& F [[buffer(1)]]) {
    float4 S = joints[iid].sphere;
    float4 cc = F.clipFromModel * float4(S.xyz, 1.0);
    float2 ndc = cc.xy / cc.w;
    float4 n0 = F.modelFromClip * float4(ndc, 0.0, 1.0);
    float3 toward = normalize(n0.xyz / n0.w - S.xyz);     // from the centre toward the eye (either camera)
    float3 hlp = abs(toward.z) < 0.9 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 u = normalize(cross(hlp, toward)), v = cross(toward, u);
    const float2 corner[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(-1, 1), float2(1, -1), float2(1, 1) };
    float2 c = corner[vid % 6];
    // the sphere's outline at its front plane, whatever the distance (the eye may be close), with a margin
    float3 eye = n0.xyz / n0.w;
    float D = max(length(S.xyz - eye), 1.0001 * S.w);
    float halfSize = S.w * D / sqrt(max(D * D - S.w * S.w, 1e-6)) * 1.15;
    float3 p = S.xyz + toward * S.w + (u * c.x + v * c.y) * halfSize;
    BoxVOut o;
    o.pos = F.clipFromModel * float4(p, 1.0);
    o.cpos = o.pos;
    o.iid = iid;
    return o;
}
fragment VineGBufDepth joint_gbuffer(BoxVOut in [[stage_in]], const device VineJoint* joints [[buffer(0)]],
                                     constant VineFrame& F [[buffer(1)]], const device float4* P [[buffer(2)]],
                                     const device uint* list [[buffer(3)]], const device uint* vineOf [[buffer(4)]]) {
    VineJoint J = joints[in.iid];
    float3 ro, rd;
    vine_ray(in.cpos, F, ro, rd);
    float3 oc = ro - J.sphere.xyz;
    float b = dot(rd, oc), h = b * b - (dot(oc, oc) - J.sphere.w * J.sphere.w);
    if (h < 0.0) { discard_fragment(); }
    float sh = sqrt(h);
    float t0 = max(-b - sh, 0.0), t1 = -b + sh;
    float k = F.blend.x;
    // the blended surface lies at most k/4 outside the plain union: where the ray first meets the cones grown by k/4 is
    // where it can begin; a ray meeting none inside the sphere passes the joint by
    float grow = 0.25 * k + 0.002;
    float tIn = 1e20;
    // and blending happens only within k of two vines: count the vines this ray passes within k of, inside the sphere
    uint near = 0, cur = 0xffffffffu;
    bool curNear = false;
    for (uint i = 0; i < J.count; ++i) {
        uint pi = list[J.first + i];
        uint vv = vineOf[pi];
        if (vv != cur) { if (curNear) { near += 1; } cur = vv; curNear = false; }
        const device float4* q = P + 6 * pi;
        tIn = min(tIn, joint_round_cone_hit(ro, rd, q[0].xyz, q[1].xyz, q[0].w + grow, q[1].w + grow));
        if (!curNear && joint_round_cone_hit(ro, rd, q[0].xyz, q[1].xyz, q[0].w + k, q[1].w + k) < t1) { curNear = true; }
    }
    if (curNear) { near += 1; }
    if (tIn > t1 || near < 2) { discard_fragment(); }
    float t = max(t0, tIn);
    bool hit = false;
    float3 p = ro;
    for (int s = 0; s < 24 && t < t1; ++s) {
        p = ro + rd * t;
        float d = joint_sd(p, J, P, list, vineOf, k);
        if (d < 0.0008) { hit = true; break; }
        t += max(d, 0.0006);
    }
    if (!hit) { discard_fragment(); }
    // only the fillet: where the plain union is still more than a hair away, the blend made this surface; elsewhere the
    // tubes and ends draw it (their facets and this exact surface would otherwise tie, pixel by pixel)
    {
        float plain = 1e3;
        for (uint i = 0; i < J.count; ++i) {
            const device float4* q = P + 6 * list[J.first + i];
            plain = min(plain, vine_sd_round_cone(p, q[0].xyz, q[1].xyz, q[0].w, q[1].w));
        }
        if (plain < 0.05 * k + 0.004) { discard_fragment(); }
    }
    // the normal by four taps (a tetrahedron)
    const float e = 0.002;
    const float3 k0 = float3(1, -1, -1), k1 = float3(-1, -1, 1), k2 = float3(-1, 1, -1), k3 = float3(1, 1, 1);
    float3 g = k0 * joint_sd(p + k0 * e, J, P, list, vineOf, k) + k1 * joint_sd(p + k1 * e, J, P, list, vineOf, k)
             + k2 * joint_sd(p + k2 * e, J, P, list, vineOf, k) + k3 * joint_sd(p + k3 * e, J, P, list, vineOf, k);
    return vine_out(p, length(g) > 1e-9 ? normalize(g) : -rd, F);
}
"""

/// The vines' GPU side: three pipelines into the prepass G-buffer (MeshRenderer's formats); pieces, caps and joints in buffers.
final class OrganicVinePass {
    static let sides = 16
    /// Why the pass could not be made (its shaders), or nil: the bars draw instead.
    nonisolated(unsafe) static var lastInitError: String?
    /// Timing switches (the frame-time probe turns passes off one at a time).
    nonisolated(unsafe) static var drawTubes = true, drawCaps = true, drawJoints = true
    let device: MTLDevice
    let tubePipeline: MTLRenderPipelineState
    let capPipeline: MTLRenderPipelineState
    let jointPipeline: MTLRenderPipelineState
    private(set) var pieceBuffer: MTLBuffer?
    private(set) var capBuffer: MTLBuffer?
    private(set) var vineOfBuffer: MTLBuffer?
    private(set) var jointBuffer: MTLBuffer?
    private(set) var listBuffer: MTLBuffer?
    private(set) var pieceCount = 0
    private(set) var capCount = 0
    private(set) var jointCount = 0
    private(set) var blendMM: Float = 0

    struct GPUJoint { var sphere: SIMD4<Float>; var first: UInt32; var count: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }
    struct Frame {
        var clipFromModel: simd_float4x4
        var modelFromClip: simd_float4x4
        var eyeFromModel: simd_float4x4
        var eyeNormalBasis: simd_float4x4
        var albedo: SIMD4<Float>
        var blend: SIMD4<Float>
    }

    init(device: MTLDevice) throws {
        self.device = device
        let lib = try device.makeLibrary(source: organicVineShaderSource, options: nil)
        func pipe(_ v: String, _ f: String) throws -> MTLRenderPipelineState {
            guard let vf = lib.makeFunction(name: v), let ff = lib.makeFunction(name: f) else {
                throw NSError(domain: "OrganicVinePass", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(v) / \(f) missing"])
            }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vf
            d.fragmentFunction = ff
            d.colorAttachments[0].pixelFormat = MeshRenderer.sceneDepthFormat
            d.colorAttachments[1].pixelFormat = MeshRenderer.gbufferNormalFormat
            d.colorAttachments[2].pixelFormat = MeshRenderer.gbufferAlbedoFormat
            d.depthAttachmentPixelFormat = MeshRenderer.depthFormat
            return try device.makeRenderPipelineState(descriptor: d)
        }
        tubePipeline = try pipe("tube_vertex", "tube_gbuffer")
        capPipeline = try pipe("cap_vertex", "cap_gbuffer")
        jointPipeline = try pipe("joint_vertex", "joint_gbuffer")
    }

    /// Six float4 per piece: (a, ra) (b, rb) (ta, flat a) (tb, flat b) (va) (vb); ta / tb = the normal of the plane each end's
    /// ring lies on; flat = 1 where the file closes that end with a flat disc.
    static func pack(_ s: OrganicVineShape) -> [SIMD4<Float>] {
        var out = [SIMD4<Float>]()
        out.reserveCapacity(6 * s.pieces.count)
        for q in s.pieces {
            out.append(SIMD4(q.a, q.ra)); out.append(SIMD4(q.b, q.rb))
            out.append(SIMD4(q.ta, q.flatA ? 1 : 0)); out.append(SIMD4(q.tb, q.flatB ? 1 : 0))
            out.append(SIMD4(q.va, 0)); out.append(SIMD4(q.vb, 0))
        }
        return out
    }

    func upload(_ s: OrganicVineShape) {
        let packed = Self.pack(s)
        let vineOf = s.pieces.map { UInt32(bitPattern: $0.vine) }
        var joints = [GPUJoint](), list = [UInt32]()
        for j in s.joints {
            let sorted = j.pieces.sorted { (s.pieces[Int($0)].vine, $0) < (s.pieces[Int($1)].vine, $1) }
            joints.append(GPUJoint(sphere: SIMD4(j.centre, j.radius), first: UInt32(list.count), count: UInt32(sorted.count)))
            list += sorted.map { UInt32(bitPattern: $0) }
        }
        func buf<T>(_ a: [T]) -> MTLBuffer? {
            a.isEmpty ? nil : device.makeBuffer(bytes: a, length: MemoryLayout<T>.stride * a.count, options: .storageModeShared)
        }
        pieceBuffer = buf(packed); capBuffer = buf(s.caps); vineOfBuffer = buf(vineOf); jointBuffer = buf(joints); listBuffer = buf(list)
        pieceCount = pieceBuffer == nil ? 0 : s.pieces.count
        capCount = capBuffer == nil ? 0 : s.caps.count
        jointCount = pieceBuffer == nil ? 0 : joints.count
        blendMM = s.params.blendMM
    }

    var isDrawable: Bool { pieceCount > 0 }

    /// `turning`: a camera gesture is down (his picks 11-16, lighter while turning): the joints' blends wait for the frame at rest.
    func encode(_ enc: MTLRenderCommandEncoder, depthState: MTLDepthStencilState, clipFromModel: simd_float4x4,
                eyeFromModel: simd_float4x4, eyeNormalBasis: simd_float4x4, albedo: SIMD4<Float>, turning: Bool = false) -> Bool {
        guard isDrawable, let pieceBuffer, enc.device === device else { return false }
        var f = Frame(clipFromModel: clipFromModel, modelFromClip: clipFromModel.inverse, eyeFromModel: eyeFromModel,
                      eyeNormalBasis: eyeNormalBasis, albedo: albedo, blend: SIMD4(blendMM, 0, 0, 0))
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        enc.setRenderPipelineState(tubePipeline)
        enc.setVertexBuffer(pieceBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&f, length: MemoryLayout<Frame>.stride, index: 1)
        enc.setFragmentBytes(&f, length: MemoryLayout<Frame>.stride, index: 1)
        if Self.drawTubes { enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 12 * Self.sides, instanceCount: pieceCount) }
        if Self.drawCaps, capCount > 0, let capBuffer {
            enc.setRenderPipelineState(capPipeline)
            enc.setVertexBuffer(capBuffer, offset: 0, index: 0)
            enc.setFragmentBuffer(capBuffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: capCount)
        }
        if Self.drawJoints, !turning, jointCount > 0, let jointBuffer, let listBuffer, let vineOfBuffer {
            enc.setRenderPipelineState(jointPipeline)
            enc.setVertexBuffer(jointBuffer, offset: 0, index: 0)
            enc.setFragmentBuffer(jointBuffer, offset: 0, index: 0)
            enc.setFragmentBuffer(pieceBuffer, offset: 0, index: 2)
            enc.setFragmentBuffer(listBuffer, offset: 0, index: 3)
            enc.setFragmentBuffer(vineOfBuffer, offset: 0, index: 4)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: jointCount)
        }
        return true
    }
}
