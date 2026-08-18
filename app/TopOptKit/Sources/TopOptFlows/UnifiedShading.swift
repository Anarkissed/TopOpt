// UnifiedShading.swift — ★ THE SHARED MSL (task 2026-08-18-unified-shading).
//
// ★ THE MAINTAINER'S COMPLAINT WAS "the lattice looks pasted ON the model, not
// like a PART of it", and the diagnosis is not speed: the shell and the lattice
// were being lit, occluded, depth-tested and edge-detected as TWO SEPARATE
// OBJECTS, in two separate MTKViews, with two separate lighting models. This file
// is where the "two" becomes "one":
//
//   `unifiedMaterialSource` — THE ONE MATERIAL. The world-space key/fill/rim rig
//       over a two-colour hemisphere ambient that `render-quality` §2 tuned on his
//       bracket, lifted OUT of `viewer_fragment` verbatim so the lattice can call
//       the same function instead of carrying a second, drifting copy of it. Not
//       one line of the rig is new — §1(d) is "identical material response", and
//       the only way to be sure of that is for there to be exactly one definition.
//
//   `latticeFieldSource` — THE ONE LATTICE FIELD. The sphere-traced strut ∩ part
//       field, its uniforms, its march and its gradient, lifted out of
//       `LatticeSDFRenderer.shaderSource` for the same reason: the standalone
//       preview renderer (still the BEFORE capture, still under its own tests) and
//       the unified pass now march THE SAME field. If they did not, a before/after
//       pair in this task's evidence would be comparing two geometries.
//
// Both are plain Swift string constants concatenated into the shader sources at
// `makeLibrary` time, which is how every shader in this target is built (no .metal
// resource bundling, identical on iOS and macOS).

import Foundation

// MARK: - the ONE material

/// The shared shading vocabulary: `ShadeParams` (the render-quality block) and the
/// key/fill/rim + hemisphere-ambient material, plus the edge/depth-fade tail. Both
/// `viewer_fragment` (the shell) and the unified lattice shade call these.
///
/// ★ EVERY CONSTANT HERE IS `render-quality` §2's, UNCHANGED. It was tuned on his
/// bracket (see the note that travelled with it), and this task's job is to make the
/// lattice obey it — not to retune it. Extracting it is therefore a refactor with no
/// pixel consequence for the shell, which is what makes the shell's own before/after
/// in `evidence/2026-08-15-render-quality` still true.
let unifiedMaterialSource = """
// Render-quality parameters (task 2026-08-15-render-quality). Every strength is a
// 0…1 multiplier and ZERO IS OFF — the before/after captures run this one shader
// with zeros rather than a second, drifting copy of it.
//
// ★ ao.z/ao.w ARE 1/MAIN-TARGET-WIDTH AND -HEIGHT, NOT 1/AO-TEXTURE. They scale a
// fragment coordinate in the COLOUR pass into a normalized uv, so the AO texture is
// free to be smaller than the colour target (which it is whenever a lattice layer is
// present — see `MeshRenderer.gbufferCap`). Sizing them from the AO texture instead
// put uv past 1 and clamped the whole part to one edge texel.
struct ShadeParams { float4 ao; float4 fade; float4 tint; };

/// The two halves of one shade: the diffuse response (ambient + key + fill, already
/// occluded) and the additive rim. Kept apart because the rim is NOT multiplied by
/// albedo — a grazing highlight is light off the surface, not the surface's colour.
struct TOMaterial { float3 shade; float3 rim; };

/// ★ THE ONE BRDF. `Nw` and `V` must be in the SAME space as the light constants
/// below, i.e. WORLD. The shell hands them straight from its vertex stage; the
/// lattice rotates them out of eye space with the inverse view rotation. Everything
/// after that is identical for both, which is the whole of §1(d).
static TOMaterial to_material(float3 Nw, float3 V, float ambientAO, float directAO) {
    // The viewer draws with cullMode .none over meshes of mixed winding, so a
    // face pointing away from the eye is a BACK face, not an unlit one: flip it
    // toward the viewer rather than letting it go black.
    if (dot(Nw, V) < 0.0) { Nw = -Nw; }
    // Hemisphere ambient (a two-colour analytic IBL): cool sky above, warm floor
    // bounce below. This is §2(a)'s "small studio HDR" reduced to its two dominant
    // spherical-harmonic terms — the part of an HDR that actually shapes a matte
    // CAD surface — at one dot product instead of a cubemap fetch.
    // ★ TUNED ON HIS BRACKET, NOT ON A SPHERE (§2d). The first values here were
    // ambient 0.150→0.400 with a 0.42 fill, and on a sphere they were fine. On his
    // bracket, from a camera looking at the side the key does NOT reach, the body
    // came back at roughly 40% grey — legible, but darker than the flat headlight it
    // replaced, and a user orbiting a part WILL find that side. A fixed world light
    // means one side is always the shadow side; the fix is a stronger ambient floor
    // and a stronger fill, not a light that follows the camera back.
    float  up = Nw.y * 0.5 + 0.5;
    float3 ambient = mix(float3(0.225, 0.212, 0.205), float3(0.470, 0.500, 0.550), up);
    // KEY: high, front-left, in WORLD space.
    float3 keyDir = normalize(float3(-0.38, 0.82, 0.42));
    float  keyN   = clamp((dot(Nw, keyDir) + 0.18) / 1.18, 0.0, 1.0);   // wrapped a little
    float3 keyTerm = float3(0.92, 0.90, 0.86) * keyN * 0.72;
    // FILL: low, right, cool and weak — it opens the shadow side without flattening.
    float3 fillDir = normalize(float3(0.72, 0.10, 0.55));
    float  fillN   = clamp(dot(Nw, fillDir) * 0.5 + 0.5, 0.0, 1.0);
    float3 fillTerm = float3(0.30, 0.35, 0.44) * fillN * 0.55;
    // RIM: a narrow grazing edge from behind — what separates one strut from the
    // strut behind it. Fresnel-weighted, so it lives only on silhouettes.
    float3 rimDir = normalize(float3(0.30, 0.30, -0.90));
    float  fres = pow(1.0 - clamp(dot(Nw, V), 0.0, 1.0), 3.5);
    TOMaterial m;
    m.shade = ambient * ambientAO + (keyTerm + fillTerm) * directAO;
    m.rim = float3(0.38, 0.44, 0.56) * fres
          * clamp(dot(Nw, rimDir) * 0.5 + 0.5, 0.0, 1.0) * 0.55 * directAO;
    return m;
}

/// §3a's crease/silhouette line and §3d's depth fade — the tail every shaded surface
/// in the frame ends with. Shared for the same reason as the BRDF: a lattice whose
/// far side did not recede, or whose creases were not drawn, would read as a
/// different substance from the shell no matter how well its diffuse term matched.
static float3 to_edge_fade(float3 color, float edge, float edgeStrength,
                           float eyeZ, float4 fade) {
    // §3a: the dark crease/silhouette line, laid on last so it survives the tint.
    color *= mix(1.0, 0.30, clamp(edge * edgeStrength, 0.0, 1.0));
    // §3d DEPTH FADE: on a dense lattice the far side reads THROUGH the near side and
    // the whole part becomes one texture. Recede the far material toward the stage's
    // own backdrop colour so the two separate. Strength is capped by the caller
    // (`Self.depthFadeStrength`) well below opaque — this is a depth CUE, never fog:
    // at full fade the material is still 55% itself, so no region is ever hidden.
    if (fade.x > 0.001) {
        float t = clamp((eyeZ - fade.y) / max(fade.z - fade.y, 1e-4), 0.0, 1.0);
        color = mix(color, float3(0.055, 0.070, 0.110), t * clamp(fade.x, 0.0, 1.0));
    }
    return color;
}
"""

// MARK: - the ONE lattice field

/// The raymarched lattice: uniforms, the strut ∩ part distance field, the march and
/// the gradient. Shared verbatim between `LatticeSDFRenderer` (the standalone
/// transparent-layer preview — the BEFORE, and still what `LatticeSDFTests` /
/// `LatticeSDFAlignmentTests` measure) and the unified pass inside `MeshRenderer`.
///
/// ★ NOTHING IN THE FIELD CHANGED IN THIS TASK. It was cut out of the fragment
/// function it used to live inside and given a name; the trim erosion, the whole-cell
/// emission, the secant refinement, the step schedule and the ±h gradient are the
/// lines that shipped. This task changes PIXELS, NOT GEOMETRY (R4), and the field is
/// the geometry.
let latticeFieldSource = """
struct LSDFUniforms {
    float4 rayX, rayY, rayDir;   // model-space ray basis (see the Swift struct)
    float4 eye, bboxMin, bboxMax, gridOrigin, gridSpacing, gridDims;
    float4 sdfOrigin, sdfSpacing, sdfDims;   // part signed-distance grid
    float4 latticeOrigin;   // xyz origin, w cell mm
    float4 gradeParams;     // rhoMin, rhoMax, gamma, K
    float4 shadeParams;     // uniformRho, hasDemand, radiusFloorNorm, maxSteps
    float4 stepParams;      // stepScale, trimErosion(mm), hasTint, segCount
    float4 lightDir, sparseColor, denseColor;
    // ── UNIFIED PASS ONLY (zero-filled for the standalone preview, which never
    // reads them). The clip and eye transforms the BODY is drawn with, so a marched
    // hit can be written into the SHARED depth buffer and the SHARED G-buffer in
    // exactly the frame the rasterised shell lives in.
    float4x4 clipFromModel;   // P · V · model — the body's own mvp
    float4x4 eyeFromModel;    // V · model
    float4x4 eyeNormalBasis;  // rotation of V · model, for the G-buffer normal
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

// MODEL-space ray for a pixel — the exact geometric inverse of the ONE shared
// transform (P·V·settle), built from the CPU-exact camera basis: no matrix
// inversion, no far-plane w cancellation (which used to warp rays by pixels).
static inline float3 lsdf_ray(constant LSDFUniforms& U, float2 uv) {
    return normalize(U.rayDir.xyz + U.rayX.xyz * uv.x + U.rayY.xyz * uv.y);
}

struct LSDFHit { bool hit; float3 pos; float rho; };

/// Sphere-trace the strut ∩ part field. The march runs in the mesh's own frame,
/// where every baked grid lives, and lands on screen exactly where the body pass
/// puts the same point.
static LSDFHit lsdf_march(constant LSDFUniforms& U,
                          const device float4* segs,
                          texture3d<float> cellTex,
                          texture3d<float> sdfTex,
                          sampler samp,
                          float3 ro, float3 rd) {
    LSDFHit out; out.hit = false; out.pos = ro; out.rho = U.shadeParams.x;

    float cell = U.latticeOrigin.w;
    float3 lorigin = U.latticeOrigin.xyz;
    float3 bmin = U.bboxMin.xyz, bmax = U.bboxMax.xyz;
    // Everything is trimmed flush at the part surface, so a small pad suffices.
    float3 pad = float3(0.15 * cell);
    float2 tb = hitBox(ro, rd, bmin - pad, bmax + pad);
    if (tb.y < max(tb.x, 0.0)) return out;

    int segCount = int(U.stepParams.w);
    float rhoMin = U.gradeParams.x, rhoMax = U.gradeParams.y;
    float gamma = U.gradeParams.z, K = U.gradeParams.w;
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
    // Previous sample along the ray, for the secant hit refinement (A2): the raw
    // sphere-trace accepts a hit anywhere in {F < eps}, an eps-thick shell whose
    // depth along the ray varies with view direction — the surface visibly
    // "breathes" as the camera orbits. One secant step to the F = 0 root makes
    // the rendered surface the true iso-surface from every angle, at zero extra
    // field evaluations.
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
            out.hit = true; out.pos = ro + rd * tHit; out.rho = rhoNear;
            return out;
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
    return out;
}

/// Gradient of the TRIMMED field (unmasked lattice ∨ part SDF ∨ bbox) at a hit:
/// strut surfaces get strut normals, flush-cut faces get the part surface's normal —
/// flat facets, matching a section cut. ★ THAT FLUSH-CUT FACET IS THE "SHELL WALL"
/// A STRUT MEETS in the lattice view, and the concave seam between the two is
/// exactly where §3's contact term has to appear.
static float3 lsdf_normal(constant LSDFUniforms& U,
                          const device float4* segs,
                          texture3d<float> sdfTex,
                          sampler samp,
                          float3 hitPos, float hitRho) {
    float cell = U.latticeOrigin.w;
    float3 lorigin = U.latticeOrigin.xyz;
    float3 bmin = U.bboxMin.xyz, bmax = U.bboxMax.xyz;
    float3 bc = (bmin + bmax) * 0.5, be = (bmax - bmin) * 0.5;
    float3 sdfDims = U.sdfDims.xyz;
    int segCount = int(U.stepParams.w);
    float radiusFloor = U.shadeParams.z;
    float K = U.gradeParams.w;
    float delta = U.stepParams.y;

    float rnH = max(radiusFloor, sqrt(max(hitRho, 0.0) / K));
    rnH = min(rnH, 0.49);
    float h = 0.002 * cell;
    float3 ex = float3(h, 0, 0), ey = float3(0, h, 0), ez = float3(0, 0, h);
    float3 base = hitPos;
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
    return normalize(float3(d6[0] - d6[1], d6[2] - d6[3], d6[4] - d6[5]) + 1e-6);
}

/// The lattice's ALBEDO at a hit: the indigo density ramp, plus the face-role tint
/// volume where a marked face's surface voxels carry one.
///
/// ★ ALBEDO, NOT A FINISHED PIXEL. Under the unified material this colour is what
/// the key, fill, rim and occlusion act ON — the same move `render-quality` §4 made
/// for the shell's region tints, and the reason a graded lattice can now read as a
/// shaded solid rather than as a flat colour laid over one.
static float3 lsdf_albedo(constant LSDFUniforms& U,
                          texture3d<float> tintTex,
                          sampler samp,
                          float3 hitPos, float hitRho) {
    float rhoMin = U.gradeParams.x, rhoMax = U.gradeParams.y;
    float frac = clamp((hitRho - rhoMin) / max(1e-4, rhoMax - rhoMin), 0.0, 1.0);
    float3 baseC = mix(U.sparseColor.xyz, U.denseColor.xyz, frac);
    // Face-role tint (A4): where the body would have been tinted (anchor / load /
    // keep-clear / protect), the marked face's surface voxels carry that colour in
    // the tint volume — baked from the mesh view's own tint dictionary. The
    // trilinear alpha fades off-face; ×2.2 saturates ON the face so the flush-cut
    // section reads as solidly marked as the body did.
    if (U.stepParams.z > 0.5) {
        float3 ttc = ((hitPos - U.sdfOrigin.xyz) / U.sdfSpacing.xyz + 0.5) / U.sdfDims.xyz;
        float4 ft = tintTex.sample(samp, ttc);
        baseC = mix(baseC, ft.rgb, clamp(ft.a * 2.2, 0.0, 1.0));
    }
    return baseC;
}
"""

// MARK: - the unified lattice entry points

/// ★ THE LATTICE, INSIDE THE SHELL'S OWN PASSES. Two fragment functions, and
/// between them they are the whole of §1(i)–(iii):
///
///   `lsdf_gbuffer` runs in `MeshRenderer`'s DEPTH PREPASS, writing the marched
///       hit's eye-Z, its eye-space normal and its albedo into the SAME G-buffer
///       the rasterised shell writes — depth-tested against the shell, so whichever
///       surface is nearer per pixel is the one that lands there. AO and the
///       silhouette/crease detector then run ONCE, over the union (§1 i + iii), and
///       the junction where a strut fuses into a wall darkens because both sides of
///       it are finally in the same depth and normal buffers (§3).
///
///   `lsdf_shade` runs in the MAIN pass as a full-screen DEFERRED shade of what that
///       G-buffer holds: no second march (the march is the expensive thing and it
///       happens once), the shell's own `to_material`, the shared AO/edge texture,
///       the shared depth fade — and a fragment depth write, so the shared depth
///       buffer resolves shell-vs-strut interpenetration per pixel (§1 ii) and every
///       overlay drawn afterwards is occluded by the lattice exactly as it is by the
///       shell.
///
/// ★ §2(b): `lsdf_shade` IS a fragment depth write, and it DECLARES ITS DIRECTION.
/// The full-screen triangle is emitted at NDC z = 0 (the near plane) and every depth
/// it writes is ≥ that, so `[[depth(greater)]]` is the truthful declaration and the
/// hardware keeps its early-depth machinery instead of switching the whole pass to
/// late-Z. It is also CONFINED: a pixel with no lattice in the G-buffer discards
/// before it writes anything at all.
let unifiedLatticeShaderSource = """
#include <metal_stdlib>
using namespace metal;

\(unifiedMaterialSource)

\(latticeFieldSource)

// ── the G-buffer write (runs inside the depth prepass) ───────────────────────
// Attachment layout is the shell's, extended by one: 0 = eye-Z (R32Float, what the
// contact pass has always read), 1 = eye-space normal (RGBA16Float), 2 = the
// LATTICE's albedo with alpha as its mask (RGBA8Unorm — the shell writes zero
// alpha there, which is how the deferred shade knows which pixels are its).
struct LSDFGBuf {
    float  eyeZ    [[color(0)]];
    float4 enormal [[color(1)]];
    float4 albedo  [[color(2)]];
    float  depth   [[depth(greater)]];
};

fragment LSDFGBuf lsdf_gbuffer(VOut in [[stage_in]],
                               constant LSDFUniforms& U [[buffer(0)]],
                               const device float4* segs [[buffer(1)]],
                               texture3d<float> cellTex [[texture(0)]],
                               texture3d<float> sdfTex [[texture(1)]],
                               texture3d<float> tintTex [[texture(2)]],
                               sampler samp [[sampler(0)]]) {
    float3 ro = U.eye.xyz;
    float3 rd = lsdf_ray(U, in.uv);
    LSDFHit h = lsdf_march(U, segs, cellTex, sdfTex, samp, ro, rd);
    if (!h.hit) { discard_fragment(); }

    float3 n = lsdf_normal(U, segs, sdfTex, samp, h.pos, h.rho);
    float4 clip = U.clipFromModel * float4(h.pos, 1.0);
    float3 eyeP = (U.eyeFromModel * float4(h.pos, 1.0)).xyz;
    float3 eyeN = normalize((U.eyeNormalBasis * float4(n, 0.0)).xyz);
    // Face the normal toward the eye — the same one-sign-check `depth_fragment`
    // does, and for the same reason: the AO hemisphere must be built on the side of
    // the surface the camera is on, or every sample lands behind the wall and every
    // pixel reports fully occluded.
    if (eyeN.z < 0.0) { eyeN = -eyeN; }

    LSDFGBuf o;
    o.eyeZ = -eyeP.z;                     // eye looks down −Z → positive into the screen
    o.enormal = float4(eyeN, 0.0);
    o.albedo = float4(lsdf_albedo(U, tintTex, samp, h.pos, h.rho), 1.0);
    o.depth = clip.z / max(clip.w, 1e-6);
    return o;
}

// ── the deferred shade (runs inside the MAIN pass) ───────────────────────────
// `proj`  = (tan(fovX/2), tan(fovY/2), gbufferW, gbufferH)
// `depth` = (A, B, mainW, mainH) with ndcDepth = A + B/eyeZ — read straight off the
//           projection matrix the frame is drawn with, so this cannot drift from it.
// `misc`  = (farSentinel, edgeStrength, 0, 0)
struct LatShadeUniforms {
    float4x4 worldFromEyeRot;
    float4 proj;
    float4 depth;
    float4 misc;
};
struct LatShadeOut { float4 color [[color(0)]]; float depth [[depth(greater)]]; };

fragment LatShadeOut lsdf_shade(VOut in [[stage_in]],
                                constant LatShadeUniforms& L [[buffer(0)]],
                                constant ShadeParams& sp [[buffer(2)]],
                                texture2d<float, access::read> gDepth [[texture(1)]],
                                texture2d<float, access::read> gNormal [[texture(2)]],
                                texture2d<float, access::read> gAlbedo [[texture(3)]],
                                texture2d<float, access::sample> aoTex [[texture(0)]]) {
    // The G-buffer may be SMALLER than the colour target (the march is fill-bound,
    // so it is resolution-capped — see `MeshRenderer.gbufferCap`). Map with a
    // nearest read, never a filtered one: bilinear across a strut silhouette mixes
    // a surface normal with the background and haloes the edge.
    float2 scale = float2(L.proj.z / max(L.depth.z, 1.0), L.proj.w / max(L.depth.w, 1.0));
    uint2 g = uint2(clamp(in.pos.xy * scale, float2(0.0),
                          float2(L.proj.z - 1.0, L.proj.w - 1.0)));
    float4 alb = gAlbedo.read(g);
    if (alb.a < 0.5) { discard_fragment(); }
    float eyeZ = gDepth.read(g).x;
    if (eyeZ >= L.misc.x) { discard_fragment(); }

    // Eye-space position and view direction, then both rotated into WORLD space —
    // the space `to_material`'s light constants live in. The eye is the origin in
    // eye space, so the view direction is just −normalize(P): no world position and
    // no matrix inverse needed anywhere in this shader.
    float2 uv  = (in.pos.xy + 0.5) / float2(L.depth.z, L.depth.w);
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    float3 P   = float3(ndc.x * L.proj.x * eyeZ, ndc.y * L.proj.y * eyeZ, -eyeZ);
    float3 Nw  = normalize((L.worldFromEyeRot * float4(gNormal.read(g).xyz, 0.0)).xyz);
    float3 V   = normalize((L.worldFromEyeRot * float4(-normalize(P), 0.0)).xyz);

    // ONE bilinear fetch of the RG texture the SSAO pass wrote — the SAME texture,
    // the same uv convention and the same two strengths the shell's fragment uses.
    constexpr sampler aoSmp(filter::linear, address::clamp_to_edge);
    float2 aoUV = in.pos.xy * float2(sp.ao.z, sp.ao.w);
    float2 aoEdge = aoTex.sample(aoSmp, aoUV).rg;
    float openness = mix(1.0, aoEdge.r, clamp(sp.ao.x, 0.0, 1.0));
    float ambientAO = openness;
    float directAO  = mix(1.0, openness, 0.45);

    TOMaterial m = to_material(Nw, V, ambientAO, directAO);
    float3 color = alb.rgb * m.shade + m.rim;
    color = to_edge_fade(color, aoEdge.g, L.misc.y, eyeZ, sp.fade);

    LatShadeOut o;
    o.color = float4(clamp(color, 0.0, 1.0), 1.0);
    o.depth = clamp(L.depth.x + L.depth.y / max(eyeZ, 1e-6), 0.0, 1.0);
    return o;
}
"""
