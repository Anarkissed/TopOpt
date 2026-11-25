// LatticeLayoutBarsPass — the NEW ENGINE's preview (the lattice rebuild, stage E; his blitz of 2026-11-12, the reviewer's go
// 20:21Z): the bars core's lattice_layout lays (LatticeLayoutSession.Result.bars, 7 floats each: a, b, width) drawn as
// round capsules, ray-cast in their own boxes (the organic impostors' way, `organicCapsuleShaderSource`) into #354's G-buffer,
// so #354's lattice shade, AO and creases light them exactly as they light the old lattice. Behind the switch "New engine
// (test)", default OFF: with it off this pass does not exist and every frame is byte-for-byte today's.
//
// ★ P7 (the rebuild's rule from his 11-11 crash): the bars, a list that grows with the part, are ONE MTLBuffer bound with
// setVertexBuffer / setFragmentBuffer — never setFragmentBytes (his v2 stand is 37,233 bars, ~1.2 MB). The per-frame uniform
// is a fixed 256-byte struct.
// ★ THE CLIP (notes26 C6, his 11-23: the regular lattice "looks like it's ON TOP of the face of the part, not *in* it"). Core's
// bars END on the part's surface (lattice_layout.hpp) and its skin bars lie ON it (bars.cpp), but a bar was drawn with round caps
// half a strut past each end (and a square bar R past both), so every cut strut bulged half a strut out of the face — while the
// print file cuts them flush (solid_mesh.cpp). With the engine's map of the part on the GPU (the solid view's), each bar is now
// clipped to the part: nothing of it draws outside; where it meets the face it ends in a flat cap flush with the surface (the
// face's own normal); a skin bar keeps its inner half. "The drawing follows the print file." The X-ray view has no map: as
// before. The ray comes from the inverse clip matrix, so Orthographic and Perspective are both right.
// ★ THE GHOST: the bars are inside the part, so the page draws the body see-through while this pass is on, and the body
// follows the Flexible pass's two rules (MeshRenderer+FlexibleLattice): out of the G-buffer, drawn after the shade.
// ★ PREVIEW IS THE SPEC, not yet: the print file squares the undersides of flat bridges and adds posts; this first cut draws
// every bar round, and the page says so in one plain line (LatticeLayoutPreview.roundBarsLine).

#if canImport(MetalKit)
import MetalKit
import simd
import Accelerate

/// What the page hands the renderer: the bars, keyed by a token (a new token uploads; the same token never re-uploads).
public struct LatticeLayoutBarsInputs: Equatable {
    public var token: Int
    /// 7 per bar: a xyz, b xyz, width mm — the part's own coordinates (the viewer mesh's).
    public var bars: [Float]
    public var hidden: Bool
    /// ★ THE SOLID VIEW (his ask 11-13): the engine's map of the part; nil = X-ray (the see-through body).
    public var solid: LatticeLayoutSolidGrid?
    /// One per bar, core's bar_flags (bit 16: a flat bridge, drawn SQUARE with a level underside, as the print writes it).
    public var flags: [UInt8]
    /// ★ Install 3: one colour per bar, the old preview's key (LatticeLayoutColours); empty = the one interior colour.
    public var colours: [SIMD4<Float>] = []
    /// Which colouring `colours` is (a new key uploads them; the bars stay).
    public var colourKey: Int = 0
    /// ★ Organic cut 1: the bars from this index on are drawn by the light pass (plain tubes: Grown's net skin); .max = none.
    public var lightFrom: Int = .max
    /// ★ His 11-19 note and verdict ("The organic looks great now!"): Organic's vines as OrganicVineShape draws them (smooth
    /// round tubes, round ends, blended joints). When set, the pass draws these instead of the bars (the bars stay for the
    /// key, the card and picking).
    public var vines: OrganicVineShape?
    /// ★ His pick 11-21 (the preview-speed research, "Let's do this one. Absolutely."): the lattice on screen is the LAST one,
    /// dimmed while the new one lays (its Draft, then the exact lattice, replaces it).
    public var dimmed = false
    /// ★ his 11-22 (the print-accurate lattice made on the Mac): the print file's own lattice; when set it draws instead of the
    /// vines and the bars (they stay for the key, the card and picking), in the same colour and light.
    public var fileMesh: LatticeFileMesh?
    public init(token: Int, bars: [Float], hidden: Bool = false, solid: LatticeLayoutSolidGrid? = nil, flags: [UInt8] = [],
                colours: [SIMD4<Float>] = [], colourKey: Int = 0) {
        self.token = token; self.bars = bars; self.hidden = hidden; self.solid = solid; self.flags = flags
        self.colours = colours; self.colourKey = colourKey
    }
    public static func == (a: Self, b: Self) -> Bool {
        a.token == b.token && a.hidden == b.hidden && a.solid?.token == b.solid?.token && a.colourKey == b.colourKey
            && a.dimmed == b.dimmed && a.solid?.smooth == b.solid?.smooth   // ★ notes28: the same map drawn the other way
    }
}

/// The engine's map for the solid view (LatticeLayoutSession.grid): 2 signed bytes per voxel (open, inside), x fastest;
/// voxel (0,0,0)'s centre at `origin`, model mm.
public struct LatticeLayoutSolidGrid: Equatable {
    public var token: Int
    public var origin: SIMD3<Float>
    public var voxel: Float
    public var dims: SIMD3<Int32>
    public var rg: [Int8]
    /// ★ his 11-19 note ("They have VERY hard edges and stair-step. It should be a single straight or curved line"): the map
    /// softened (`smoothed`), read with linear filtering so the cut follows a smooth line between voxels (Organic).
    public var smooth = false
    public init(token: Int, origin: SIMD3<Float>, voxel: Float, dims: SIMD3<Int32>, rg: [Int8], smooth: Bool = false) {
        self.token = token; self.origin = origin; self.voxel = voxel; self.dims = dims; self.rg = rg; self.smooth = smooth
    }
    /// Both channels blurred by [1 4 6 4 1] / 16 along each axis (about one voxel): the zero crossing of the result is a
    /// smooth surface through the stair-steps of the engine's yes/no voxels, so straight cuts read straight and curved cuts
    /// curved.
    public static func smoothed(_ rg: [Int8], dims: SIMD3<Int32>) -> [Int8] {
        let nx = Int(dims.x), ny = Int(dims.y), nz = Int(dims.z), n = nx * ny * nz
        guard n > 0, rg.count == 2 * n else { return rg }
        var a = [Float](repeating: 0, count: 2 * n), b = a
        for i in 0..<(2 * n) { a[i] = Float(rg[i]) }
        let w: [Float] = [1, 4, 6, 4, 1].map { $0 / 16 }
        for (axis, len) in [(0, nx), (1, ny), (2, nz)] {
            let st = axis == 0 ? 1 : (axis == 1 ? nx : nx * ny)
            for idx in 0..<n {
                let c: Int
                switch axis { case 0: c = idx % nx; case 1: c = (idx / nx) % ny; default: c = idx / (nx * ny) }
                for ch in 0..<2 {
                    var s: Float = 0
                    for k in -2...2 {
                        let cc = Swift.min(Swift.max(c + k, 0), len - 1)
                        s += w[k + 2] * a[2 * (idx + (cc - c) * st) + ch]
                    }
                    b[2 * idx + ch] = s
                }
            }
            swap(&a, &b)
        }
        return a.map { Int8(Swift.max(-127, Swift.min(127, $0.rounded()))) }
    }

    /// ★ notes28 (his iPad notes on release 18, img 77: "there is still stair stepping on the cut lines of the original part's
    /// wall ... It's on every wall"). The regular lattice's cut, with Print-accurate preview OFF: the OPEN channel read as a
    /// signed field whose zero is the cut, smoothed so a cut along a slope reads as one straight line (a curve as a curve), not
    /// the map's voxel steps. Each voxel's yes/no is averaged over its neighbours by the binomial [1 6 15 20 15 6 1] / 64 along
    /// each axis (about 1.2 voxels), counting ONLY the voxels where the map knows the answer — inside the part, and the layer of
    /// air right beside it (the engine marks that layer open beside open lattice, so the surface's cut is read there); the air
    /// past it says nothing about the cut, so it never pulls the line inward (`smoothed` above, Organic's, does: about 0.2 mm on
    /// a 0.7 mm map). Measured on a 30° cut across a face (Notes28LatticeViewTests): the line's wobble from 0.23 mm (the steps)
    /// to under 0.1 mm, its place on the true line kept. The inside channel is the engine's own.
    /// ★ HIS RULE ("The drawing follows the print file. Always."; amended 11-21: with Print-accurate preview ON). The print file
    /// cuts the wall along a slope in 0.25 mm steps itself (read_open_space's columns): ON, the drawing keeps the map's own steps
    /// (`LatticeLayoutPreview.cutSmoothWanted`); a straight cut in the file is an engine change.
    public static let cutTaps: [Float] = [1, 6, 15, 20, 15, 6, 1]
    public static func cutSmoothed(_ rg: [Int8], dims: SIMD3<Int32>) -> [Int8] {
        let nx = Int(dims.x), ny = Int(dims.y), nz = Int(dims.z), n = nx * ny * nz
        guard n > 0, rg.count == 2 * n else { return rg }
        // Accelerate throughout (vDSP): a 1M-voxel map in a fraction of a second, debug builds too.
        let N = vDSP_Length(n)
        let open = UnsafeMutablePointer<Float>.allocate(capacity: n), inside = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let known = UnsafeMutablePointer<Float>.allocate(capacity: n), num = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { open.deallocate(); inside.deallocate(); known.deallocate(); num.deallocate() }
        rg.withUnsafeBufferPointer { m in
            m.baseAddress!.withMemoryRebound(to: Int8.self, capacity: 2 * n) { b in
                vDSP_vflt8(b, 2, open, 1, N)
                vDSP_vflt8(b + 1, 2, inside, 1, N)
            }
        }
        var zero: Float = 0, one: Float = 1, scale: Float = 1 / 127
        vDSP_vthrsc(inside, 1, &zero, &one, inside, 1, N)   // ±1 (≥ 0 → +1)
        vDSP_vthr(inside, 1, &zero, inside, 1, N)            // 1 inside the part, 0 outside
        // the voxels where the map knows the answer: inside, or air beside the part (its six neighbours; the map has a voxel of
        // air all round, so a shift that wraps a row or a plane only ever meets air)
        known.update(from: inside, count: n)
        for shift in [1, nx, nx * ny] where shift < n {
            let m = vDSP_Length(n - shift)
            vDSP_vmax(known, 1, inside + shift, 1, known, 1, m)          // the neighbour after
            vDSP_vmax(known + shift, 1, inside, 1, known + shift, 1, m)  // and the one before
        }
        vDSP_vsmul(open, 1, &scale, open, 1, N)    // −1 … 1
        vDSP_vmul(open, 1, known, 1, num, 1, N)    // the known answers; `known` is how much of them
        // blurred alike along each axis: their ratio is the field
        for (axis, len, st) in [(0, nx, 1), (1, ny, nx), (2, nz, nx * ny)] {
            Self.blurAxis(num, nx: nx, ny: ny, nz: nz, axis: axis, len: len, stride: st)
            Self.blurAxis(known, nx: nx, ny: ny, nz: nz, axis: axis, len: len, stride: st)
        }
        // (num − ε) / (known + ε): where nothing is known (far air) −1, as the engine's own map says there
        var eps: Float = 1e-6, negEps: Float = -1e-6, lo: Float = -1, hi: Float = 1, s127: Float = 127
        vDSP_vsadd(num, 1, &negEps, num, 1, N)
        vDSP_vsadd(known, 1, &eps, known, 1, N)
        vDSP_vdiv(known, 1, num, 1, open, 1, N)    // open = num / known
        vDSP_vclip(open, 1, &lo, &hi, open, 1, N)
        vDSP_vsmul(open, 1, &s127, open, 1, N)
        var out = rg
        out.withUnsafeMutableBufferPointer { o in
            o.baseAddress!.withMemoryRebound(to: Int8.self, capacity: 2 * n) { b in
                vDSP_vfixr8(open, 1, b, 2, N)   // the open channel; the inside channel stays the engine's
            }
        }
        return out
    }

    /// The binomial along one axis of `a` (x fastest, then y, then z), line by line, the ends held (the voxel at the edge
    /// repeats). A line that is one value throughout is left as it is (the blur of a constant is that constant): most lines
    /// of a map are all air or all solid.
    private static func blurAxis(_ a: UnsafeMutablePointer<Float>, nx: Int, ny: Int, nz: Int, axis: Int, len: Int, stride st: Int) {
        let h = cutTaps.count / 2
        let sum = cutTaps.reduce(0, +)
        let w = cutTaps.map { $0 / sum }
        let pad = UnsafeMutablePointer<Float>.allocate(capacity: len + 2 * h), line = UnsafeMutablePointer<Float>.allocate(capacity: len)
        defer { pad.deallocate(); line.deallocate() }
        let lines = axis == 0 ? ny * nz : (axis == 1 ? nx * nz : nx * ny)
        var zero: Float = 0
        for l in 0..<lines {
            let base: Int
            switch axis {
            case 0: base = l * nx                          // (y, z)
            case 1: base = (l / nx) * nx * ny + l % nx     // (x, z)
            default: base = l                              // (x, y)
            }
            let src = a + base
            var mn: Float = 0, mx: Float = 0
            vDSP_minv(src, st, &mn, vDSP_Length(len))
            vDSP_maxv(src, st, &mx, vDSP_Length(len))
            if mn == mx { continue }
            vDSP_vsadd(src, st, &zero, pad + h, 1, vDSP_Length(len))   // the line, gathered (a strided copy)
            for j in 0..<h { pad[j] = pad[h]; pad[h + len + j] = pad[h + len - 1] }
            vDSP_conv(pad, 1, w, 1, line, 1, vDSP_Length(len), vDSP_Length(2 * h + 1))
            vDSP_vsadd(line, 1, &zero, src, st, vDSP_Length(len))   // and put back
        }
    }
    public static func == (a: Self, b: Self) -> Bool { a.token == b.token }
    public var isWhole: Bool { dims.x > 0 && dims.y > 0 && dims.z > 0 && rg.count == 2 * Int(dims.x) * Int(dims.y) * Int(dims.z) }
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
    float4   mapOrigin;    // ★ notes26 C6: the engine's map — voxel (0,0,0)'s centre
    float4   mapSpacing;   //   its voxel size
    float4   mapDims;      //   its voxel counts; w = 1: clip the bars to the part
};

// ★ notes26 C6: is `p` inside the part (the map's inside channel, read linear — the way Organic's softened map is), never
// outside the map's own box (beyond it nothing is the part)
static float3 bar_map_uvw(float3 p, constant BarFrame& F) {
    return ((p - F.mapOrigin.xyz) / F.mapSpacing.xyz + 0.5) / F.mapDims.xyz;
}
static float bar_map_inside(float3 p, constant BarFrame& F, texture3d<float, access::sample> map) {
    constexpr sampler sl(coord::normalized, filter::linear, address::clamp_to_edge);
    float3 uvw = bar_map_uvw(p, F);
    if (any(uvw < 0.0) || any(uvw > 1.0)) { return -1.0; }
    return map.sample(sl, uvw).g;
}

struct BarVOut {
    float4 pos [[position]];
    float4 cpos;                 // the clip position again, for this fragment's own ray
    uint   iid [[flat]];
};

// ★ A FLAT BRIDGE (core's bar_flags bit 16, `bar_is_bridge`) is written SQUARE: its width across and tall, centred on its
// line, its underside level (up is the print direction, +z). Its box's sides are the square's.
static bool bar_square(float4 B) { return (uint(B.w + 0.5) & 16u) != 0u; }
static void bar_axes(float3 u, bool square, thread float3& v, thread float3& w) {
    float3 side = cross(u, float3(0.0, 0.0, 1.0));
    if (square && length(side) > 1e-4) { v = normalize(side); w = cross(v, u); return; }
    float3 hlp = abs(u.x) < 0.9 ? float3(1.0, 0.0, 0.0) : float3(0.0, 1.0, 0.0);
    v = normalize(cross(u, hlp));
    w = cross(u, v);
}

// The box around bar `iid`: its ends pushed out by R along the axis, ±R across.
vertex BarVOut bar_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device float4* bars [[buffer(0)]],
                          constant BarFrame& F [[buffer(1)]]) {
    float4 A = bars[2 * iid], B = bars[2 * iid + 1];
    float R = max(A.w, 1e-4);
    float3 ax = B.xyz - A.xyz;
    float len = length(ax);
    float3 u = len > 1e-6 ? ax / len : float3(0.0, 0.0, 1.0);
    float3 v, w;
    bar_axes(u, bar_square(B), v, w);
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
                             constant BarFrame& F [[buffer(1)]],
                             const device float4* colours [[buffer(2)]],
                             texture3d<float, access::sample> map [[texture(0)]]) {
    float4 A = bars[2 * in.iid], B = bars[2 * in.iid + 1];
    float R = max(A.w, 1e-4);
    // this fragment's ray, from the inverse clip matrix: right for Orthographic and Perspective alike
    float2 ndc = in.cpos.xy / in.cpos.w;
    float4 n0 = F.modelFromClip * float4(ndc, 0.0, 1.0);
    float4 n1 = F.modelFromClip * float4(ndc, 1.0, 1.0);
    float3 ro = n0.xyz / n0.w;
    float3 rd = normalize(n1.xyz / n1.w - ro);
    float t;
    float tExit;   // ★ notes26 C6: where the ray leaves the bar
    float3 n;
    if (bar_square(B)) {
        float3 ax = B.xyz - A.xyz;
        float len = length(ax);
        float3 u = len > 1e-6 ? ax / len : float3(0.0, 0.0, 1.0);
        float3 v, w;
        bar_axes(u, true, v, w);
        float3 o = ro - A.xyz;
        float3 lo3 = float3(dot(o, u), dot(o, v), dot(o, w));
        float3 ld = float3(dot(rd, u), dot(rd, v), dot(rd, w));
        float3 sd = float3(abs(ld.x) < 1e-7 ? 1e-7 : ld.x, abs(ld.y) < 1e-7 ? 1e-7 : ld.y, abs(ld.z) < 1e-7 ? 1e-7 : ld.z);
        float3 ta = (float3(-R, -R, -R) - lo3) / sd, tb = (float3(len + R, R, R) - lo3) / sd;
        float3 tn = min(ta, tb), tf = max(ta, tb);
        float tN = max(max(tn.x, tn.y), tn.z), tF = min(min(tf.x, tf.y), tf.z);
        if (tF < max(tN, 0.0)) { discard_fragment(); }
        t = tN >= 0.0 ? tN : tF;
        tExit = tF;
        float3 ln = (tN == tn.x) ? float3(-sign(ld.x), 0.0, 0.0) : ((tN == tn.y) ? float3(0.0, -sign(ld.y), 0.0) : float3(0.0, 0.0, -sign(ld.z)));
        n = normalize(ln.x * u + ln.y * v + ln.z * w);
    } else {
        t = bar_intersect(ro, rd, A.xyz, B.xyz, R);
        if (t < 0.0) { discard_fragment(); }
        n = bar_normal(ro + rd * t, A.xyz, B.xyz);
        // the far side: the same test from a point past the bar, looking back
        float far = t + 2.0 * (length(B.xyz - A.xyz) + 2.0 * R);
        float back = bar_intersect(ro + rd * far, -rd, A.xyz, B.xyz, R);
        tExit = back >= 0.0 ? far - back : t;
    }
    // ★ notes26 C6: clipped to the part. A hit outside it: walk the bar's chord to where the ray enters the part — there the bar
    // ends FLAT, flush with the face (the face's own normal); none: nothing of this bar is here.
    if (F.mapDims.w > 0.5 && bar_map_inside(ro + rd * t, F, map) <= 0.0) {
        const int STEPS = 40;
        float dt = max(tExit - t, 0.0) / float(STEPS);
        float hit = -1.0;
        for (int i = 1; i <= STEPS; ++i) {
            float sx = t + dt * float(i);
            if (bar_map_inside(ro + rd * sx, F, map) > 0.0) { hit = sx; break; }
        }
        if (hit < 0.0) { discard_fragment(); }
        float a = hit - dt, b = hit;
        for (int k = 0; k < 8; ++k) {
            float m = 0.5 * (a + b);
            if (bar_map_inside(ro + rd * m, F, map) > 0.0) { b = m; } else { a = m; }
        }
        t = b;
        float3 q = ro + rd * t;
        float e = 0.5 * min(F.mapSpacing.x, min(F.mapSpacing.y, F.mapSpacing.z));
        float3 g = float3(bar_map_inside(q + float3(e, 0, 0), F, map) - bar_map_inside(q - float3(e, 0, 0), F, map),
                          bar_map_inside(q + float3(0, e, 0), F, map) - bar_map_inside(q - float3(0, e, 0), F, map),
                          bar_map_inside(q + float3(0, 0, e), F, map) - bar_map_inside(q - float3(0, 0, e), F, map));
        n = length(g) > 1e-5 ? -normalize(g) : -rd;   // out of the part: the face's own normal
    }
    float3 p = ro + rd * t;
    float4 clip = F.clipFromModel * float4(p, 1.0);
    float3 eyeP = (F.eyeFromModel * float4(p, 1.0)).xyz;
    float3 eyeN = normalize((F.eyeNormalBasis * float4(n, 0.0)).xyz);
    if (eyeN.z < 0.0) { eyeN = -eyeN; }
    BarGBuf o;
    o.eyeZ = -eyeP.z;
    o.enormal = float4(eyeN, 0.0);
    // ★ Install 3: albedo.w < 0 = one colour per bar (the old key's, LatticeLayoutColours)
    o.albedo = float4(F.albedo.w < 0.0 ? colours[in.iid].rgb : F.albedo.rgb, 1.0);
    o.depth = clip.z / clip.w;
    return o;
}

// ── THE SOLID VIEW's CUT WALLS (his ask 11-13) ──
// Where the body's surface is cut open (the shell clip reads the same map, ShellClip mode 2), this walks each pixel's ray
// through the engine's map: past air, into the open lattice, and stops at the first solid behind it — the wall the lattice
// is cut into. A ray that meets the part's surface before any open lattice draws nothing (the body is there).
struct WallFrame {
    float4x4 clipFromModel;
    float4x4 modelFromClip;
    float4x4 eyeFromModel;
    float4x4 eyeNormalBasis;
    float4   albedo;
    float4   origin;    // voxel (0,0,0)'s centre
    float4   spacing;   // voxel size
    float4   dims;      // voxel counts
};

struct WallVOut {
    float4 pos [[position]];
    float4 cpos;
};

vertex WallVOut wall_vertex(uint vid [[vertex_id]], constant WallFrame& F [[buffer(1)]]) {
    const int idx[36] = { 0,1,2, 2,1,3, 4,6,5, 5,6,7, 0,4,1, 1,4,5,
                          2,3,6, 6,3,7, 0,2,4, 4,2,6, 1,5,3, 3,5,7 };
    int c = idx[vid % 36];
    float3 lo = F.origin.xyz - 0.5 * F.spacing.xyz;
    float3 hi = lo + F.dims.xyz * F.spacing.xyz;
    float3 p = float3((c & 1) ? hi.x : lo.x, (c & 2) ? hi.y : lo.y, (c & 4) ? hi.z : lo.z);
    WallVOut o;
    o.pos = F.clipFromModel * float4(p, 1.0);
    o.cpos = o.pos;
    return o;
}

static float3 wall_uvw(float3 p, constant WallFrame& F) {
    return ((p - F.origin.xyz) / F.spacing.xyz + 0.5) / F.dims.xyz;
}

fragment BarGBuf wall_gbuffer(WallVOut in [[stage_in]], constant WallFrame& F [[buffer(1)]],
                              texture3d<float, access::sample> map [[texture(0)]]) {
    float2 ndc = in.cpos.xy / in.cpos.w;
    float4 n0 = F.modelFromClip * float4(ndc, 0.0, 1.0);
    float4 n1 = F.modelFromClip * float4(ndc, 1.0, 1.0);
    float3 ro = n0.xyz / n0.w;
    float3 rd = normalize(n1.xyz / n1.w - ro);
    float3 lo = F.origin.xyz - 0.5 * F.spacing.xyz;
    float3 hi = lo + F.dims.xyz * F.spacing.xyz;
    float3 safe = float3(abs(rd.x) < 1e-7 ? 1e-7 : rd.x, abs(rd.y) < 1e-7 ? 1e-7 : rd.y, abs(rd.z) < 1e-7 ? 1e-7 : rd.z);
    float3 ta = (lo - ro) / safe, tb = (hi - ro) / safe;
    float t0 = max(max(min(ta.x, tb.x), min(ta.y, tb.y)), min(ta.z, tb.z));
    float t1 = min(min(max(ta.x, tb.x), max(ta.y, tb.y)), max(ta.z, tb.z));
    t0 = max(t0, 0.0);
    if (t1 <= t0) { discard_fragment(); }
    constexpr sampler sl(coord::normalized, filter::linear, address::clamp_to_edge);
    float vox = min(F.spacing.x, min(F.spacing.y, F.spacing.z));
    float step = 0.5 * vox;
    int steps = int(min((t1 - t0) / step + 2.0, 6000.0));
    bool inOpen = false;     // the ray has been in open lattice INSIDE the part (not only the open-marked air at an opening)
    float insideRun = 0.0;   // solid met before any open lattice: past a voxel of it, the body is there
    float outRun = 0.0;      // after open lattice: how far outside the part (a hair at the surface is not leaving)
    float t = t0 + 0.5 * step;
    for (int i = 0; i < steps; ++i, t += step) {
        float2 v = map.sample(sl, wall_uvw(ro + rd * t, F)).rg;
        bool open = v.x > 0.0, inside = v.y > 0.0;
        if (open && inside) { inOpen = true; outRun = 0.0; continue; }
        if (!inOpen) {
            // the engine reads a point right on the surface as solid: a voxel of that is not the body; more is
            if (inside && !open) { insideRun += step; if (insideRun > 1.5 * vox) { discard_fragment(); } }
            continue;
        }
        if (!inside) {   // outside again: out through the opening, unless it is only the surface's hair
            outRun += step;
            if (outRun > 1.5 * vox) { discard_fragment(); }
            continue;
        }
        float a = t - step, b = t;              // the wall: where the open field crosses zero
        for (int k = 0; k < 6; ++k) {
            float m = 0.5 * (a + b);
            if (map.sample(sl, wall_uvw(ro + rd * m, F)).x > 0.0) { a = m; } else { b = m; }
        }
        float3 p = ro + rd * b;
        float e = 0.5 * vox;
        float3 g = float3(map.sample(sl, wall_uvw(p + float3(e, 0, 0), F)).x - map.sample(sl, wall_uvw(p - float3(e, 0, 0), F)).x,
                          map.sample(sl, wall_uvw(p + float3(0, e, 0), F)).x - map.sample(sl, wall_uvw(p - float3(0, e, 0), F)).x,
                          map.sample(sl, wall_uvw(p + float3(0, 0, e), F)).x - map.sample(sl, wall_uvw(p - float3(0, 0, e), F)).x);
        float3 n = length(g) > 1e-5 ? normalize(g) : -rd;   // from the solid into the open lattice: the wall's face
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
    discard_fragment();
    BarGBuf none;
    return none;
}

// ── THE LIGHT PASS (Organic cut 1, his 11-18: "There is no question, it will lag") ──
// Grown's net skin (~23,000 short struts on his stand) as plain six-sided tubes drawn as geometry: no ray per pixel and no
// depth written by the fragment, so the GPU's hidden-surface removal keeps them cheap. Each tube runs half a radius past
// its ends, so a strand's joints close. Same G-buffer, so #354's shade, AO and creases light them as they light the rest.
struct LightVOut {
    float4 pos [[position]];
    float3 en;
    float  ez;
    uint   iid [[flat]];
};

vertex LightVOut light_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              const device float4* bars [[buffer(0)]],
                              constant BarFrame& F [[buffer(1)]]) {
    float4 A = bars[2 * iid], B = bars[2 * iid + 1];
    float R = max(A.w, 1e-4);
    float3 ax = B.xyz - A.xyz;
    float len = length(ax);
    float3 u = len > 1e-6 ? ax / len : float3(0.0, 0.0, 1.0);
    float3 v, w;
    bar_axes(u, false, v, w);
    const int corner[6] = { 0, 1, 2, 2, 1, 3 };   // one side's quad: bit 1 = end B, bit 2 = the next edge
    int c = corner[vid % 6];
    float ang = float(int(vid / 6) + ((c & 2) ? 1 : 0)) * 1.0471975512;   // six sides
    float3 radial = cos(ang) * v + sin(ang) * w;
    float3 p = ((c & 1) ? (B.xyz + u * 0.5 * R) : (A.xyz - u * 0.5 * R)) + radial * R;
    LightVOut o;
    o.pos = F.clipFromModel * float4(p, 1.0);
    o.ez = -(F.eyeFromModel * float4(p, 1.0)).z;
    o.en = (F.eyeNormalBasis * float4(radial, 0.0)).xyz;
    o.iid = iid;
    return o;
}

struct LightGBuf {
    float  eyeZ    [[color(0)]];
    float4 enormal [[color(1)]];
    float4 albedo  [[color(2)]];
};

fragment LightGBuf light_gbuffer(LightVOut in [[stage_in]], constant BarFrame& F [[buffer(1)]],
                                 const device float4* colours [[buffer(2)]]) {
    float3 n = normalize(in.en);
    if (n.z < 0.0) { n = -n; }
    LightGBuf o;
    o.eyeZ = in.ez;
    o.enormal = float4(n, 0.0);
    o.albedo = float4(F.albedo.w < 0.0 ? colours[in.iid].rgb : F.albedo.rgb, 1.0);
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
    let wallsPipeline: MTLRenderPipelineState
    let lightPipeline: MTLRenderPipelineState
    /// ★ THE SOLID VIEW: the engine's map as a 3D texture (rg8Snorm: open, inside), and where it sits.
    private(set) var gridTexture: MTLTexture?
    var gridSmooth = false
    private(set) var grid: (origin: SIMD3<Float>, voxel: Float, dims: SIMD3<Int32>)?
    private(set) var gridToken = -1
    /// The cut walls' colour: the body's own grey, so a cut reads as the same material.
    /// ★ notes24 (b, "as if you're looking INTO A PART"): exactly the body's clay (viewer_fragment's `clay`), no cooler grey.
    static let wallColour = SIMD4<Float>(0.78, 0.77, 0.75, 1)
    /// ★ notes26 C6: the bars clipped to the part where its map is on the GPU (the solid view). RED CONTROL (tests): off — the round
    /// caps bulge half a strut out of the face, as before.
    static var clipToPart = true
    /// The cut walls, on (11-13: they draw — the hollow core's solid core behind its lattice; his v4 stand at 2048 × 1536 on
    /// the Mac: 21 ms a frame without, 25–29 ms with). The tests' red control turns them off.
    static var drawWalls = true
    private(set) var buffer: MTLBuffer?
    /// ★ Install 3: one colour per bar (float4), or nil = the one colour.
    private(set) var colourBuffer: MTLBuffer?
    private(set) var colourKey = -1
    private(set) var count = 0
    private(set) var token = -1
    /// ★ Organic cut 1: the first bar the light pass draws (.max: none).
    private(set) var lightFrom = Int.max
    /// ★ His 11-19: Organic's vines (nil: the bars draw).
    private(set) var vinePass: OrganicVinePass?
    /// ★ his 11-22: the print file's lattice from the Mac (nil: the vines or the bars draw).
    private(set) var filePass: LatticeFileMeshPass?
    var hidden = false
    /// ★ his pick 11-21: the last lattice, dimmed while the new one lays (`dimmedRGB`).
    var dimmed = false
    var isDrawable: Bool { !hidden && count > 0 && buffer != nil }

    /// ★ his pick 11-21: a lattice that is about to be replaced: its colour drained toward grey and darkened, so it reads as
    /// the old one at a glance (never hidden: he keeps his bearings while the new one lays).
    static func dimmedRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let grey = SIMD3<Float>(repeating: simd_dot(c, SIMD3(0.299, 0.587, 0.114)))
        return simd_mix(c, grey, SIMD3(repeating: 0.7)) * 0.6 + 0.12
    }

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
        guard let wv = lib.makeFunction(name: "wall_vertex"), let wf = lib.makeFunction(name: "wall_gbuffer") else {
            throw NSError(domain: "LatticeLayoutBarsPass", code: 2, userInfo: [NSLocalizedDescriptionKey: "wall functions missing"])
        }
        d.vertexFunction = wv
        d.fragmentFunction = wf
        wallsPipeline = try device.makeRenderPipelineState(descriptor: d)
        guard let lv = lib.makeFunction(name: "light_vertex"), let lf = lib.makeFunction(name: "light_gbuffer") else {
            throw NSError(domain: "LatticeLayoutBarsPass", code: 3, userInfo: [NSLocalizedDescriptionKey: "light functions missing"])
        }
        d.vertexFunction = lv
        d.fragmentFunction = lf
        lightPipeline = try device.makeRenderPipelineState(descriptor: d)
    }

    /// The solid view's map into ONE 3D texture (P7: never inline). nil or a broken map: X-ray (no cut, no walls).
    func uploadGrid(_ g: LatticeLayoutSolidGrid?) {
        gridToken = g?.token ?? -1
        guard let g, g.isWhole else { gridTexture = nil; grid = nil; return }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rg8Snorm
        d.width = Int(g.dims.x); d.height = Int(g.dims.y); d.depth = Int(g.dims.z)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { gridTexture = nil; grid = nil; return }
        g.rg.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake3D(0, 0, 0, d.width, d.height, d.depth), mipmapLevel: 0, slice: 0,
                      withBytes: raw.baseAddress!, bytesPerRow: 2 * d.width, bytesPerImage: 2 * d.width * d.height)
        }
        gridTexture = t
        grid = (g.origin, g.voxel, g.dims)
        gridSmooth = g.smooth
    }

    /// The shell clip that cuts the body's surface open where the map says open lattice (ShellClip mode 2: the cell field,
    /// nearest, `.r >= 0` is open). nil: X-ray.
    var shellClip: ShellClipUniform? {
        guard let g = grid, gridTexture != nil else { return nil }
        var u = ShellClipUniform()
        u.grid = SIMD4(g.origin, 1)
        u.spacing = SIMD4(g.voxel, g.voxel, g.voxel, 0)
        u.dims = SIMD4(Float(g.dims.x), Float(g.dims.y), Float(g.dims.z), 0)
        u.gate = SIMD4(gridSmooth ? 3 : -2, 2, 0, 0)   // x = 3: a softened map, read linear (MetalMeshView's mode 2)
        return u
    }

    struct WallFrame {
        var clipFromModel: simd_float4x4
        var modelFromClip: simd_float4x4
        var eyeFromModel: simd_float4x4
        var eyeNormalBasis: simd_float4x4
        var albedo: SIMD4<Float>
        var origin: SIMD4<Float>
        var spacing: SIMD4<Float>
        var dims: SIMD4<Float>
    }

    /// The cut walls into the prepass's G-buffer (after the bars; same encoder, attachments and depth state).
    func encodeWalls(_ enc: MTLRenderCommandEncoder, depthState: MTLDepthStencilState,
                     clipFromModel: simd_float4x4, eyeFromModel: simd_float4x4, eyeNormalBasis: simd_float4x4) -> Bool {
        guard Self.drawWalls, !hidden, let g = grid, let tex = gridTexture, enc.device === device else { return false }
        var f = WallFrame(clipFromModel: clipFromModel, modelFromClip: clipFromModel.inverse, eyeFromModel: eyeFromModel,
                          eyeNormalBasis: eyeNormalBasis, albedo: Self.wallColour, origin: SIMD4(g.origin, 0),
                          spacing: SIMD4(g.voxel, g.voxel, g.voxel, 0),
                          dims: SIMD4(Float(g.dims.x), Float(g.dims.y), Float(g.dims.z), 0))
        enc.setRenderPipelineState(wallsPipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        enc.setVertexBytes(&f, length: MemoryLayout<WallFrame>.stride, index: 1)
        enc.setFragmentBytes(&f, length: MemoryLayout<WallFrame>.stride, index: 1)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36)
        return true
    }

    /// The bars into ONE buffer (P7), packed (a.xyz, r)(b.xyz, 0).
    func upload(_ inputs: LatticeLayoutBarsInputs) {
        token = inputs.token
        hidden = inputs.hidden
        lightFrom = inputs.lightFrom
        if let v = inputs.vines {
            if vinePass == nil {
                do { vinePass = try OrganicVinePass(device: device); OrganicVinePass.lastInitError = nil } catch {
                    OrganicVinePass.lastInitError = "\(error)"   // the bars draw instead; a test reads this
                    NSLog("DIAG organic vines: %@", "\(error)")
                }
            }
            vinePass?.upload(v)
        } else {
            vinePass = nil
        }
        if let m = inputs.fileMesh {   // ★ his 11-22
            if filePass == nil {
                do { filePass = try LatticeFileMeshPass(device: device); LatticeFileMeshPass.lastInitError = nil } catch {
                    LatticeFileMeshPass.lastInitError = "\(error)"
                    NSLog("DIAG print file lattice: %@", "\(error)")
                }
            }
            if filePass?.token != m.token { filePass?.upload(m) }
        } else {
            filePass = nil
        }
        let packed = Self.pack(inputs.bars, flags: inputs.flags)
        count = packed.count / 2
        buffer = packed.isEmpty ? nil : device.makeBuffer(bytes: packed, length: MemoryLayout<SIMD4<Float>>.stride * packed.count,
                                                          options: .storageModeShared)
        uploadColours(inputs)
    }

    /// ★ Install 3: the bars' colours (one per bar), or none (the one colour). A count that is not the bars' is none.
    func uploadColours(_ inputs: LatticeLayoutBarsInputs) {
        colourKey = inputs.colourKey
        colourBuffer = inputs.colours.count == count && count > 0
            ? device.makeBuffer(bytes: inputs.colours, length: MemoryLayout<SIMD4<Float>>.stride * inputs.colours.count,
                                options: .storageModeShared)
            : nil
    }

    /// 7 floats per bar → two float4 per bar (radius = width / 2; the second's w = the bar's flags). Tests read it.
    static func pack(_ bars: [Float], flags: [UInt8] = []) -> [SIMD4<Float>] {
        let n = bars.count / 7
        var out = [SIMD4<Float>]()
        out.reserveCapacity(2 * n)
        for i in 0..<n {
            let k = 7 * i
            out.append(SIMD4(bars[k], bars[k + 1], bars[k + 2], 0.5 * bars[k + 6]))
            out.append(SIMD4(bars[k + 3], bars[k + 4], bars[k + 5], i < flags.count ? Float(flags[i]) : 0))
        }
        return out
    }

    struct Frame {
        var clipFromModel: simd_float4x4
        var modelFromClip: simd_float4x4
        var eyeFromModel: simd_float4x4
        var eyeNormalBasis: simd_float4x4
        var albedo: SIMD4<Float>
        /// ★ notes26 C6: the engine's map (BarFrame's twin); `mapDims.w` 1 = clip the bars to the part.
        var mapOrigin = SIMD4<Float>(0, 0, 0, 0)
        var mapSpacing = SIMD4<Float>(1, 1, 1, 0)
        var mapDims = SIMD4<Float>(1, 1, 1, 0)
    }

    /// ★ notes26 C6: a 1×1×1 map bound when there is none (the shader declares it, so it is bound on every path).
    private lazy var neutralMap: MTLTexture? = {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rg8Snorm
        d.width = 1; d.height = 1; d.depth = 1
        d.usage = [.shaderRead]
        d.storageMode = .shared
        let t = device.makeTexture(descriptor: d)
        var z: [Int8] = [0, 0]
        t?.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1), mipmapLevel: 0, slice: 0, withBytes: &z, bytesPerRow: 2, bytesPerImage: 2)
        return t
    }()

    /// Bars into the prepass's G-buffer (its encoder, attachments and .less + write depth state).
    func encodeGBuffer(_ enc: MTLRenderCommandEncoder, depthState: MTLDepthStencilState,
                       clipFromModel: simd_float4x4, eyeFromModel: simd_float4x4, eyeNormalBasis: simd_float4x4,
                       turning: Bool = false) -> Bool {
        guard isDrawable, let buffer, enc.device === device else { return false }
        let c0 = Self.colour
        let c = dimmed ? Self.dimmedRGB(SIMD3(Float(c0.r), Float(c0.g), Float(c0.b))) : SIMD3(Float(c0.r), Float(c0.g), Float(c0.b))
        if let fp = filePass, fp.isDrawable {   // ★ his 11-22: the print file's own lattice, the vines' colour and light
            return fp.encode(enc, depthState: depthState, clipFromModel: clipFromModel, eyeFromModel: eyeFromModel,
                             eyeNormalBasis: eyeNormalBasis, albedo: SIMD4(c, 1))
        }
        if let vp = vinePass, vp.isDrawable {   // ★ his 11-19: Organic's vines, one colour
            return vp.encode(enc, depthState: depthState, clipFromModel: clipFromModel, eyeFromModel: eyeFromModel,
                             eyeNormalBasis: eyeNormalBasis, albedo: SIMD4(c, 1), turning: turning)
        }
        // dimmed: every bar the one drained colour (the key's colours come back with the new lattice)
        var f = Frame(clipFromModel: clipFromModel, modelFromClip: clipFromModel.inverse, eyeFromModel: eyeFromModel,
                      eyeNormalBasis: eyeNormalBasis, albedo: SIMD4(c, colourBuffer == nil || dimmed ? 1 : -1))
        if Self.clipToPart, let g = grid, gridTexture != nil {   // ★ notes26 C6: the solid view's map clips the bars to the part
            f.mapOrigin = SIMD4(g.origin, 0)
            f.mapSpacing = SIMD4(g.voxel, g.voxel, g.voxel, 0)
            f.mapDims = SIMD4(Float(g.dims.x), Float(g.dims.y), Float(g.dims.z), 1)
        }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&f, length: MemoryLayout<Frame>.stride, index: 1)       // fixed size, never a growing list
        enc.setFragmentBuffer(buffer, offset: 0, index: 0)
        enc.setFragmentBytes(&f, length: MemoryLayout<Frame>.stride, index: 1)
        enc.setFragmentBuffer(colourBuffer ?? buffer, offset: 0, index: 2)   // bound either way (read only when albedo.w < 0)
        enc.setFragmentTexture(gridTexture ?? neutralMap, index: 0)   // ★ notes26 C6: bound either way (read only when clipping)
        let cast = Swift.min(Swift.max(lightFrom, 0), count)
        if cast > 0 { enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: cast) }
        if cast < count {   // ★ Organic cut 1: the light pass, the same buffers from bar `cast` on
            let s4 = MemoryLayout<SIMD4<Float>>.stride
            enc.setRenderPipelineState(lightPipeline)
            enc.setVertexBuffer(buffer, offset: 2 * s4 * cast, index: 0)
            enc.setFragmentBuffer(colourBuffer ?? buffer, offset: colourBuffer == nil ? 0 : s4 * cast, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: count - cast)
        }
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
        var changed = false
        if pass.token != inputs.token { pass.upload(inputs); changed = true }
        else if pass.colourKey != inputs.colourKey { pass.uploadColours(inputs); changed = true }   // ★ Install 3
        if pass.hidden != inputs.hidden { pass.hidden = inputs.hidden; changed = true }
        if pass.dimmed != inputs.dimmed { pass.dimmed = inputs.dimmed; changed = true }   // ★ his pick 11-21
        if pass.gridToken != (inputs.solid?.token ?? -1) || (inputs.solid.map { $0.smooth != pass.gridSmooth } ?? false) {
            pass.uploadGrid(inputs.solid); changed = true   // ★ notes28: or the same lay's map smoothed / stepped (Print-accurate)
        }
        return changed
    }
}
#endif
