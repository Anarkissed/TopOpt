// OrganicVinePass — the new engine's Organic vines drawn as he approved them on 11-19 ("The organic looks great now!"), fast
// enough for his stand on the iPad (Grown at his settings: about 150,000 struts):
//   * BODIES: each OrganicVineShape piece a real tube (10 sides) between two rings that neighbouring pieces share exactly
//     (no crack, no twist), its normal smooth around and along: ordinary triangles, so the depth test rejects hidden ones
//     before they are shaded (the ray-cast bars' impostors could not, which is what lagged past ~37k bars);
//   * ROUND ENDS: every run end a sphere of its radius (an analytic impostor; a few per vine);
//   * JOINTS: where vines meet, the vines there blended by a polynomial smooth-min (a short march inside the joint's sphere);
//   * BRIDGES (11-20): a run flatter than 30 degrees in the print file's own section, the D (flat level underside, round top)
//     or the square bar;
//   * THE FLAT CUT (11-20): pieces and round ends that reach the part's surface are cut there, the cut face drawn in the
//     vine's colour (their own two pipelines; the rest keep the fast ones).
// All of them write the prepass G-buffer the bars write (eye z, normal, albedo, depth), so the deferred shading, the solid view's
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
    float4   blend;        // x = the joints' smooth-min k (mm); y = 1: the flat cut's face drawn (0: the tests' red control)
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
// ── a bridge's section (core weave_tubes.cpp sweep_section; OrganicVineShape.sectionPoint / sectionFrame are the same) ──
constant float kPi = 3.14159265358979;
static void sec_frame(float3 t, float3 fallback, thread float3& side, thread float3& up) {
    float3 sd = float3(-t.y, t.x, 0.0);
    if (length(sd) < 1e-6) { sd = fallback; }
    sd = normalize(sd);
    float3 u = cross(t, sd);
    if (u.z < 0.0) { u = -u; sd = -sd; }
    side = sd;
    up = u;
}
// outline point j at half width r: the D (1) two bottom corners then its round top in kSides - 3 facets; the square (2)
static float2 sec_point(int sec, int j, float r) {
    j = j % kSides;
    if (sec == 1) {
        if (j == 0) { return float2(-r, -r); }
        if (j == 1) { return float2(r, -r); }
        float a = kPi * float(j - 2) / float(kSides - 3);
        return float2(r * cos(a), r * sin(a));
    }
    int per = kSides / 4, sd = j / per;
    float f = float(j % per) / float(per);
    if (sd == 0) { return float2(-r + 2.0 * r * f, -r); }
    if (sd == 1) { return float2(r, -r + 2.0 * r * f); }
    if (sd == 2) { return float2(r - 2.0 * r * f, r); }
    return float2(-r, r - 2.0 * r * f);
}
// the outward normal on facet `quad` (from point quad to quad + 1) at point j: flat faces flat, the D's round top smooth
static float2 sec_normal(int sec, int quad, int j) {
    j = j % kSides;
    if (sec == 1) {
        if (quad == 0) { return float2(0.0, -1.0); }
        if (quad == 1) { return float2(1.0, 0.0); }
        if (quad == kSides - 1) { return float2(-1.0, 0.0); }
        float a = kPi * float(j - 2) / float(kSides - 3);
        return float2(cos(a), sin(a));
    }
    int sd = quad / (kSides / 4);
    return sd == 0 ? float2(0.0, -1.0) : sd == 1 ? float2(1.0, 0.0) : sd == 2 ? float2(0.0, 1.0) : float2(-1.0, 0.0);
}
struct TubePt { float3 p; float3 n; };   // a vertex in the model's space: where, and the outward normal
// One piece (q: (a, ra) (b, rb) (ta, flat a) (tb, flat b) (va, section) (vb, -)): the side, 6 x kSides vertices; then a
// flat end disc at a (3 x kSides) and at b (3 x kSides), drawn only where the file closes the tube flat (q[2].w / q[3].w
// = 1: into the solid, cut by the part's surface, or any end of a bridge).
static TubePt tube_point(uint vid, const device float4* q) {
    const int ring[6] = { 0, 1, 0, 0, 1, 1 };
    const int step[6] = { 0, 0, 1, 1, 0, 1 };
    int side = 6 * kSides;
    bool disc = int(vid) >= side;
    int r, k, j, quad = 0;
    if (!disc) {
        quad = int(vid) / 6;
        int corner = int(vid) % 6;
        r = ring[corner];
        j = quad + step[corner];
        k = 1;
    } else {
        int d = int(vid) - side;
        r = d / (3 * kSides);
        int tri = (d % (3 * kSides)) / 3, corner = d % 3;
        j = tri + (corner == 2 ? 1 : 0);
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
    int sec = int(q[4].w + 0.5);
    float dn = dot(t, n);
    TubePt o;
    if (sec == 0) {
        float3 w = cross(t, v);
        float ang = float(j) * (6.283185307 / float(kSides));
        float3 radial = cos(ang) * v + sin(ang) * w;
        float3 off = radial * (rad * kRingScale) * float(k);
        o.p = c + off + t * (abs(dn) > 1e-3 ? -dot(off, n) / dn : 0.0);
        o.n = disc ? (r == 0 ? -t : t) : radial;
        return o;
    }
    // ★ a bridge (packed version 2's section): the file's D or square bar, its side level, its flat side down; at a mitre
    // the mean of this bar's section and the neighbour's (the neighbour's direction: the plane's mirror of this one)
    float3 sd, up;
    sec_frame(t, v, sd, up);
    float2 xy = sec_point(sec, j, rad) * float(k);
    float3 off = sd * xy.x + up * xy.y;
    o.p = c + off + t * (abs(dn) > 1e-3 ? -dot(off, n) / dn : 0.0);
    float3 t2 = 2.0 * dn * n - t;
    if (dot(t2, t) < 0.99999 && length(t2) > 0.5) {
        t2 = normalize(t2);
        float3 sd2, up2;
        sec_frame(t2, v, sd2, up2);
        float3 off2 = sd2 * xy.x + up2 * xy.y;
        float dn2 = dot(t2, n);
        o.p = 0.5 * (o.p + c + off2 + t2 * (abs(dn2) > 1e-3 ? -dot(off2, n) / dn2 : 0.0));
    }
    float2 nn = sec_normal(sec, quad, j);
    o.n = disc ? (r == 0 ? -t : t) : sd * nn.x + up * nn.y;
    return o;
}
vertex TubeVOut tube_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device float4* P [[buffer(0)]], constant VineFrame& F [[buffer(1)]]) {
    TubePt t = tube_point(vid, P + 6 * iid);
    TubeVOut o;
    o.pos = F.clipFromModel * float4(t.p, 1.0);
    o.ez = -(F.eyeFromModel * float4(t.p, 1.0)).z;
    o.en = (F.eyeNormalBasis * float4(t.n, 0.0)).xyz;
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
    float w = abs(S.w);   // a dome's radius comes negative (OS1 B)
    float3 p = S.xyz + float3((c & 1) ? w : -w, (c & 2) ? w : -w, (c & 4) ? w : -w);
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

// ── ★ THE FLAT CUT (his 11-20 skin note: "the cutting along the plane ... gives it its unique feel"): the print file trims
// every tube to the part, so a piece that reaches the part's surface carries that surface where it lies: every facet plane
// of the part's mesh within its reach (OrganicVineShape.Cut; 7 float4 a piece: the six above, then (first, count, union)
// into the plane list). Convex there, the part is inside them all; concave, inside any: the part's own faceted surface, so
// overlapping pieces are cut alike. Its fragments outside are dropped; where the ray enters the part INSIDE the tube (seen
// through the opening, on the tube's far side) the surface itself is drawn there, in the vine's colour, with its own
// depth: the cut face. ──
struct VineGBufCut {
    float  eyeZ    [[color(0)]];
    float4 enormal [[color(1)]];
    float4 albedo  [[color(2)]];
    float  depth   [[depth(less)]];   // the cut face lies in front of the far side it is drawn for
};
struct TubeCutVOut {
    float4 pos [[position]];
    float4 cpos;
    float3 mp;
    float3 mn;
    uint   iid [[flat]];
};
// outside the part a cut's planes bound (OrganicVineShape.Cut.outside is the same): outside any (convex), all (concave)
static bool cut_outside(float3 p, const device float4* pl, int n, bool un) {
    for (int i = 0; i < n && i < 16; ++i) {
        bool o = dot(pl[i].xyz, p) + pl[i].w > 1e-4;
        if (un && !o) { return false; }
        if (!un && o) { return true; }
    }
    return un;
}
// where the ray enters the part the planes bound (t, and the plane's normal there), or 1e20: never, or the eye already
// inside (then no cut face shows on this ray). Convex: the last plane it enters, if before the first it leaves; concave:
// the first it enters.
static float cut_entry(float3 ro, float3 rd, const device float4* pl, int n, bool un, thread float3& nrm) {
    float tIn = un ? 1e20 : -1e20, tOut = 1e20;
    bool entered = false;
    for (int i = 0; i < n && i < 16; ++i) {
        float d0 = dot(pl[i].xyz, ro) + pl[i].w, dn = dot(pl[i].xyz, rd);
        if (un) {
            if (d0 <= 0.0) { return 1e20; }
            if (dn < -1e-9) { float t = -d0 / dn; if (t < tIn) { tIn = t; nrm = pl[i].xyz; entered = true; } }
        } else {
            if (abs(dn) < 1e-9) { if (d0 > 0.0) { return 1e20; } continue; }
            float t = -d0 / dn;
            if (dn < 0.0) { if (t > tIn) { tIn = t; nrm = pl[i].xyz; entered = true; } }
            else { tOut = min(tOut, t); }
        }
    }
    if (!entered || tIn < 0.0 || (!un && tIn > tOut)) { return 1e20; }
    return tIn;
}
// x inside piece q's own shape: within its section, between its end planes where the tube is closed flat; past an open
// end (a round end, or a joint with the next piece of the run) up to one radius on (what lies there is the next piece or
// the ball: a ray seen through one piece's cut may leave by its neighbour's far side)
static bool vine_in_piece(float3 x, const device float4* q) {
    float3 a = q[0].xyz, ab = q[1].xyz - a;
    float L = length(ab);
    if (L < 1e-6) { return false; }
    float3 t = ab / L;
    float along = dot(x - a, t);
    if (q[2].w > 0.5 ? dot(x - a, q[2].xyz) < -2e-3 : along < -q[0].w) { return false; }
    if (q[3].w > 0.5 ? dot(x - q[1].xyz, q[3].xyz) > 2e-3 : along > L + q[1].w) { return false; }
    float r = mix(q[0].w, q[1].w, clamp(along / L, 0.0, 1.0)) + 2e-3;
    float3 d = (x - a) - t * along;
    int sec = int(q[4].w + 0.5);
    if (sec == 0) { return length(d) <= r * kRingScale; }
    float3 sd, up;
    sec_frame(t, normalize(q[4].xyz), sd, up);
    float X = dot(d, sd), Y = dot(d, up);
    if (sec == 1) { return Y <= 0.0 ? (abs(X) <= r && Y >= -r) : (X * X + Y * Y <= r * r); }
    return abs(X) <= r && abs(Y) <= r;
}
static VineGBufCut vine_cut_out(float3 p, float3 n, float depth, constant VineFrame& F) {
    float3 eyeP = (F.eyeFromModel * float4(p, 1.0)).xyz;
    float3 eyeN = normalize((F.eyeNormalBasis * float4(n, 0.0)).xyz);
    if (eyeN.z < 0.0) { eyeN = -eyeN; }
    VineGBufCut o;
    o.eyeZ = -eyeP.z;
    o.enormal = float4(eyeN, 0.0);
    o.albedo = float4(F.albedo.rgb, 1.0);
    o.depth = depth;
    return o;
}
vertex TubeCutVOut tube_cut_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   const device float4* P [[buffer(0)]], constant VineFrame& F [[buffer(1)]]) {
    TubePt t = tube_point(vid, P + 7 * iid);
    TubeCutVOut o;
    o.pos = F.clipFromModel * float4(t.p, 1.0);
    o.cpos = o.pos;
    o.mp = t.p;
    o.mn = t.n;
    o.iid = iid;
    return o;
}
fragment VineGBufCut tube_cut_gbuffer(TubeCutVOut in [[stage_in]], const device float4* P [[buffer(0)]],
                                      constant VineFrame& F [[buffer(1)]], const device float4* planes [[buffer(2)]]) {
    const device float4* q = P + 7 * in.iid;
    const device float4* pl = planes + int(q[6].x + 0.5);
    int n = int(q[6].y + 0.5);
    bool un = q[6].z > 0.5;
    if (cut_outside(in.mp, pl, n, un)) { discard_fragment(); }
    float3 ro, rd;
    vine_ray(in.cpos, F, ro, rd);
    if (dot(in.mn, rd) <= 0.0) { return vine_cut_out(in.mp, in.mn, in.pos.z, F); }   // the near side, inside the part
    // the far side: only as the cut face, where the ray enters the part inside the tube before this point
    if (F.blend.y < 0.5) { discard_fragment(); }
    float tp = dot(in.mp - ro, rd);
    float3 bn = float3(0.0);
    float tf = cut_entry(ro, rd, pl, n, un, bn);
    if (tf > tp + 1e-4) { discard_fragment(); }
    float3 f = ro + rd * tf;
    if (!vine_in_piece(f, q)) { discard_fragment(); }
    float4 clip = F.clipFromModel * float4(f, 1.0);
    return vine_cut_out(f, bn, min(clip.z / clip.w, in.pos.z), F);
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
    bool dome = S.w < 0.0;   // OS1 B: a bridge's puck top, its upper half only (its wall below is a piece)
    S.w = abs(S.w);
    float3 ro, rd;
    vine_ray(in.cpos, F, ro, rd);
    float3 oc = ro - S.xyz;
    float b = dot(rd, oc), h = b * b - (dot(oc, oc) - S.w * S.w);
    if (h < 0.0) { discard_fragment(); }
    float t = -b - sqrt(h);
    if (t < 0.0) { discard_fragment(); }
    float3 p = ro + rd * t;
    if (dome && p.z < S.z) { discard_fragment(); }
    return vine_out(p, normalize(p - S.xyz), F);
}
// ★ the flat cut on a round end (2 float4 per end: (xyz, r), then (first, count, union) into the plane list): the sphere
// inside the part, and the cut face where the ray enters the part inside it
vertex BoxVOut cap_cut_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              const device float4* caps [[buffer(0)]], constant VineFrame& F [[buffer(1)]]) {
    BoxVOut o;
    o.pos = box_corner(vid, caps[2 * iid], F);
    o.cpos = o.pos;
    o.iid = iid;
    return o;
}
fragment VineGBufDepth cap_cut_gbuffer(BoxVOut in [[stage_in]], const device float4* caps [[buffer(0)]],
                                       constant VineFrame& F [[buffer(1)]], const device float4* planes [[buffer(2)]]) {
    float4 S = caps[2 * in.iid], m = caps[2 * in.iid + 1];
    bool dome = S.w < 0.0;   // OS1 B: a puck top, its upper half only
    S.w = abs(S.w);
    const device float4* pl = planes + int(m.x + 0.5);
    int n = int(m.y + 0.5);
    bool un = m.z > 0.5;
    float3 ro, rd;
    vine_ray(in.cpos, F, ro, rd);
    float3 oc = ro - S.xyz;
    float b = dot(rd, oc), h = b * b - (dot(oc, oc) - S.w * S.w);
    if (h < 0.0) { discard_fragment(); }
    float sh = sqrt(h), t0 = -b - sh, t1 = -b + sh;
    if (t1 < 0.0) { discard_fragment(); }
    float3 p = ro + rd * t0;
    if (t0 >= 0.0 && !cut_outside(p, pl, n, un)) {
        if (dome && p.z < S.z) { discard_fragment(); }
        return vine_out(p, normalize(p - S.xyz), F);
    }
    if (F.blend.y < 0.5) { discard_fragment(); }
    float3 bn = float3(0.0);
    float tf = cut_entry(ro, rd, pl, n, un, bn);
    if (tf < max(t0, 0.0) || tf > t1 || (dome && (ro + rd * tf).z < S.z)) { discard_fragment(); }
    return vine_out(ro + rd * tf, bn, F);
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
    /// The flat cut's face (the tests' red control turns it off: the cut tubes are then hollow).
    nonisolated(unsafe) static var drawCutFace = true
    let device: MTLDevice
    let tubePipeline: MTLRenderPipelineState
    let capPipeline: MTLRenderPipelineState
    let jointPipeline: MTLRenderPipelineState
    /// ★ The flat cut: the pieces and round ends that reach the part's surface, cut there (their own buffers).
    let tubeCutPipeline: MTLRenderPipelineState
    let capCutPipeline: MTLRenderPipelineState
    private(set) var pieceBuffer: MTLBuffer?
    private(set) var capBuffer: MTLBuffer?
    private(set) var cutPieceBuffer: MTLBuffer?
    private(set) var cutCapBuffer: MTLBuffer?
    private(set) var cutPlaneBuffer: MTLBuffer?
    private(set) var vineOfBuffer: MTLBuffer?
    private(set) var jointBuffer: MTLBuffer?
    private(set) var listBuffer: MTLBuffer?
    private(set) var pieceCount = 0
    private(set) var capCount = 0
    private(set) var cutPieceCount = 0
    private(set) var cutCapCount = 0
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
        tubeCutPipeline = try pipe("tube_cut_vertex", "tube_cut_gbuffer")
        capCutPipeline = try pipe("cap_cut_vertex", "cap_cut_gbuffer")
    }

    /// Six float4 per piece: (a, ra) (b, rb) (ta, flat a) (tb, flat b) (va, section) (vb); ta / tb = the normal of the plane
    /// each end's ring lies on; flat = 1 where the file closes that end with a flat disc; section the file's (0 round, 1 the
    /// D, 2 the square bar). `cut` true: seven, the seventh (first, count, union) into `planes`, where the piece's cut planes
    /// are appended.
    static func pack(_ s: OrganicVineShape, cut: Bool? = nil, planes: inout [SIMD4<Float>]) -> [SIMD4<Float>] {
        var out = [SIMD4<Float>]()
        out.reserveCapacity((cut == true ? 7 : 6) * s.pieces.count)
        for q in s.pieces where cut == nil || q.isCut == cut {
            out.append(SIMD4(q.a, q.ra)); out.append(SIMD4(q.b, q.rb))
            out.append(SIMD4(q.ta, q.flatA ? 1 : 0)); out.append(SIMD4(q.tb, q.flatB ? 1 : 0))
            out.append(SIMD4(q.va, Float(q.section))); out.append(SIMD4(q.vb, 0))
            if cut == true, let c = q.cut { out.append(Self.meta(c, &planes)) }
        }
        return out
    }
    static func pack(_ s: OrganicVineShape) -> [SIMD4<Float>] {
        var none: [SIMD4<Float>] = []
        return pack(s, cut: nil, planes: &none)
    }
    /// A cut's planes appended to `planes` (at most OrganicVineShape.maxCutPlanes), and its (first, count, union, 0).
    static func meta(_ c: OrganicVineShape.Cut, _ planes: inout [SIMD4<Float>]) -> SIMD4<Float> {
        let first = planes.count
        planes += c.planes.prefix(OrganicVineShape.maxCutPlanes)
        return SIMD4(Float(first), Float(planes.count - first), c.union ? 1 : 0, 0)
    }

    /// The round ends as the GPU reads them: a bridge's puck top (OS1 B, `capDomes`) carries its radius negative, and the
    /// shader draws its upper half only.
    static func signedCaps(_ s: OrganicVineShape) -> [SIMD4<Float>] {
        s.caps.enumerated().map { k, c in k < s.capDomes.count && s.capDomes[k] ? SIMD4(c.x, c.y, c.z, -c.w) : c }
    }

    func upload(_ s: OrganicVineShape) {
        // the cut pieces and ends draw by their own pipelines (a joint's list indexes the one buffer: none cut with joints)
        let split = s.joints.isEmpty && s.pieces.contains(where: \.isCut)
        var planes: [SIMD4<Float>] = []
        let packed = Self.pack(s, cut: split ? false : nil, planes: &planes)
        let cutPacked = split ? Self.pack(s, cut: true, planes: &planes) : []
        let signed = Self.signedCaps(s)
        var caps = signed, cutCaps: [SIMD4<Float>] = []
        if s.joints.isEmpty, s.capCuts.count == s.caps.count, !s.caps.isEmpty {
            caps = []
            for (k, c) in signed.enumerated() {
                if let cut = s.capCuts[k] { cutCaps += [c, Self.meta(cut, &planes)] } else { caps.append(c) }
            }
        }
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
        pieceBuffer = buf(packed); capBuffer = buf(caps); vineOfBuffer = buf(vineOf); jointBuffer = buf(joints); listBuffer = buf(list)
        cutPieceBuffer = buf(cutPacked); cutCapBuffer = buf(cutCaps); cutPlaneBuffer = buf(planes)
        pieceCount = pieceBuffer == nil ? 0 : packed.count / 6
        capCount = capBuffer == nil ? 0 : caps.count
        cutPieceCount = cutPieceBuffer == nil || cutPlaneBuffer == nil ? 0 : cutPacked.count / 7
        cutCapCount = cutCapBuffer == nil || cutPlaneBuffer == nil ? 0 : cutCaps.count / 2
        jointCount = pieceBuffer == nil ? 0 : joints.count
        blendMM = s.params.blendMM
    }

    var isDrawable: Bool { pieceCount + cutPieceCount > 0 }

    /// `turning`: a camera gesture is down (his picks 11-16, lighter while turning): the joints' blends wait for the frame at rest.
    func encode(_ enc: MTLRenderCommandEncoder, depthState: MTLDepthStencilState, clipFromModel: simd_float4x4,
                eyeFromModel: simd_float4x4, eyeNormalBasis: simd_float4x4, albedo: SIMD4<Float>, turning: Bool = false) -> Bool {
        guard isDrawable, enc.device === device else { return false }
        var f = Frame(clipFromModel: clipFromModel, modelFromClip: clipFromModel.inverse, eyeFromModel: eyeFromModel,
                      eyeNormalBasis: eyeNormalBasis, albedo: albedo, blend: SIMD4(blendMM, Self.drawCutFace ? 1 : 0, 0, 0))
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        enc.setVertexBytes(&f, length: MemoryLayout<Frame>.stride, index: 1)
        enc.setFragmentBytes(&f, length: MemoryLayout<Frame>.stride, index: 1)
        if Self.drawTubes, pieceCount > 0, let pieceBuffer {
            enc.setRenderPipelineState(tubePipeline)
            enc.setVertexBuffer(pieceBuffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 12 * Self.sides, instanceCount: pieceCount)
        }
        if Self.drawTubes, cutPieceCount > 0, let cutPieceBuffer {   // ★ the flat cut
            enc.setRenderPipelineState(tubeCutPipeline)
            enc.setVertexBuffer(cutPieceBuffer, offset: 0, index: 0)
            enc.setFragmentBuffer(cutPieceBuffer, offset: 0, index: 0)
            enc.setFragmentBuffer(cutPlaneBuffer, offset: 0, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 12 * Self.sides, instanceCount: cutPieceCount)
        }
        if Self.drawCaps, capCount > 0, let capBuffer {
            enc.setRenderPipelineState(capPipeline)
            enc.setVertexBuffer(capBuffer, offset: 0, index: 0)
            enc.setFragmentBuffer(capBuffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: capCount)
        }
        if Self.drawCaps, cutCapCount > 0, let cutCapBuffer {   // ★ the flat cut on round ends
            enc.setRenderPipelineState(capCutPipeline)
            enc.setVertexBuffer(cutCapBuffer, offset: 0, index: 0)
            enc.setFragmentBuffer(cutCapBuffer, offset: 0, index: 0)
            enc.setFragmentBuffer(cutPlaneBuffer, offset: 0, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: cutCapCount)
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
