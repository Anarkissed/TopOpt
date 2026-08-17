// MetalMeshView.swift — the Metal draw for the workspace stage (M7.4 viewer +
// M7.5 face selection).
//
// Renders a ViewerMesh with neutral-clay analytic shading on the design's dark
// stage, driven by an OrbitCamera the gestures mutate (drag → orbit, pinch /
// magnify → zoom). M7.5 adds:
//   * an id-buffer render pass — face ids drawn to an offscreen R32Uint target,
//     read back at the tapped pixel to resolve which B-rep face was tapped
//     (`renderFaceIDOffscreen` / `pickFaceID`); and
//   * a selection highlight — grouped faces tinted with their group colour, the
//     active group brightest — via a per-vertex tint buffer rebuilt from the
//     SelectionModel.
//
// The heavy *logic* the tests cover (groups, the CPU pick reference in FacePicker,
// the loop walk in FaceTopology) lives in the pure files; this file is the GPU +
// gesture glue, which needs a device + display and so is maintainer device QA. It
// compiles on the iPad shipping slice, the macOS test slice, and a plain-SwiftUI
// fallback where MetalKit is unavailable.

import SwiftUI
import TopOptDesign
import simd
import Combine
#if canImport(os)
import os
#endif

#if canImport(MetalKit)
import MetalKit
import QuartzCore

/// Signpost log for the VIEWER's own frames (handoff 134, item 3). The results
/// screen already stamps `ResultsFrame` (SwiftUI body evaluations) and the gizmo
/// stamps `GizmoFrame`, but the part viewer — by far the largest draw — had no
/// track, so a device capture could not say how much of a frame was IT. Each
/// `draw(in:)` is one interval carrying the frame's measured draw-call and vertex
/// counts, which is what makes "GPU frame time at rest vs during orbit" a number
/// the maintainer can read off a trace instead of estimate. Zero cost when
/// Instruments is not recording.
let viewerFrameSignpost = OSLog(subsystem: "com.topopt.results", category: "ViewerFrame")

// ---------------------------------------------------------------------------
// GPU uniforms — must match the `Uniforms` layout in the shaders below.
private struct ViewerUniforms {
    var mvp: simd_float4x4
    var normalMatrix: simd_float4x4  // view rotation (upper-left 3×3), padded
    /// M7.viz.3 flex: `.x` = displacement scale (exaggeration·amplitude) added to
    /// each rest vertex before the MVP. Appended AFTER mvp/normalMatrix so the id
    /// pass (which reads only that prefix) is unaffected.
    var flex: SIMD4<Float> = .zero
    // ── render-quality (task 2026-08-15-render-quality) ───────────────────────
    // Appended AFTER `flex`, again so every shader that reads only the earlier
    // prefix (`id_vertex` reads `mvp`; `depth_vertex` reads mvp/modelView/flex) is
    // byte-unaffected. §2: the light is fixed in the WORLD, so the fragment needs a
    // WORLD normal and a WORLD position — the existing `normalMatrix` is view·model,
    // which is exactly what made the old shading a headlight.
    /// Model rotation only (upper-left 3×3 of `model`), padded — world-space normals.
    var worldNormalMatrix: simd_float4x4 = matrix_identity_float4x4
    /// The model matrix — world position, for the view vector and the rim/fresnel.
    var model: simd_float4x4 = matrix_identity_float4x4
    /// view·model — eye-space depth, for the §3d depth fade (and the G-buffer).
    var modelView: simd_float4x4 = matrix_identity_float4x4
    /// Camera world position (`.w` unused).
    var eye: SIMD4<Float> = .zero
}

/// The body fragment's render-quality parameters (buffer 2) — must match
/// `ShadeParams` in `viewerShaderSource`. Every strength is a plain 0…1 multiplier
/// and 0 means OFF, so the BEFORE capture is the same shader with zeros rather than
/// a second code path that could drift from the shipping one.
private struct ShadeParams {
    /// x = AO strength, y = edge strength, z = 1/aoTexWidth, w = 1/aoTexHeight.
    var ao: SIMD4<Float> = .zero
    /// x = depth-fade strength, y = fade-start eye-Z, z = fade-end eye-Z,
    /// w = world-lighting flag (0 = the old view-locked headlight, 1 = §2's rig).
    var fade: SIMD4<Float> = .zero
    /// §4: x = STATE-tint desaturation, 0 = the tint exactly as authored. Applied in
    /// the shader, after the protect-crosshatch colour test, so the desaturation
    /// cannot break the exact-RGB protocol that test depends on.
    var tint: SIMD4<Float> = .zero
}

/// The SSAO + edge pass uniforms (§1, §3a) — must match `AOUniforms` in
/// `aoShaderSource`.
private struct AOUniforms {
    /// x = tan(fovX/2), y = tan(fovY/2), z = texture width, w = texture height.
    var proj: SIMD4<Float>
    /// x = radius (world mm), y = intensity, z = depth bias (world mm), w = sample count.
    var params: SIMD4<Float>
    /// x = edge depth threshold (relative to eye-Z), y = edge normal threshold,
    /// z = the far sentinel that marks "no part here", w = unused.
    var edge: SIMD4<Float>
}

// The load-path ribbon uniforms — must match `LPUniforms` in `loadPathShaderSource`.
// `params` = (aspect = w/h, halfWidth in NDC-y, flow phase 0..1, unused).
private struct LoadPathUniforms {
    var mvp: simd_float4x4
    var params: SIMD4<Float>
}

// The CAD-stage backdrop uniforms — byte-identical to `StageUniforms` in `stageShaderSource`.
// Only reconstructed when the camera or mesh changes (the on-demand redraw), never per idle
// frame, so the stage is static (item 9 / the 108 rule).
private struct StageUniforms {
    var invVP: simd_float4x4     // inverse(projection · view)
    var eye: SIMD3<Float>        // camera world position
    var floorY: Float
    var centerXZ: SIMD2<Float>   // floor-plane centre (fade origin)
    var spacing: Float           // minor grid spacing
    var fadeRadius: Float
    /// §3c contact shadow: the world-XZ rectangle the footprint texture covers —
    /// (originX, originZ, sizeX, sizeZ). A zero size means no shadow, and the neutral
    /// 1×1 texture is bound instead — the term is then an exact identity.
    var shadowRect: SIMD4<Float> = .zero
    /// §3c: shadow strength; 0 = off.
    var shadowStrength: Float = 0
    var _pad: SIMD3<Float> = .zero   // 16-byte tail alignment
}

// The depth-prepass uniforms — must match `DUniforms` in `depthPrepassShaderSource`.
// `modelView` = view·model (eye-space transform); `flex.x` = the displacement scale (so the
// captured depth tracks the visible, flexed part).
/// The §3c footprint pass uniforms — must match `ShUniforms` in `shadowShaderSource`.
private struct ShadowUniforms {
    var model: simd_float4x4
    var rect: SIMD4<Float>
    var flex: SIMD4<Float>
}

private struct DepthPrepassUniforms {
    var mvp: simd_float4x4
    var modelView: simd_float4x4
    var flex: SIMD4<Float> = .zero
    /// Appended for the G-buffer's normal attachment (render quality §1/§3a): the
    /// view·model rotation, i.e. the SAME eye-space normal the body shader has always
    /// used — so AO and the body are lit off one definition of "which way is out".
    var normalMatrix: simd_float4x4 = matrix_identity_float4x4
}

// The contact-pass uniforms — must match `CUniforms` in `contactShaderSource`.
// `params` = (contact-line feather, occlusion band, unused, unused) in eye-space/world mm.
private struct ContactUniforms {
    var mvp: simd_float4x4
    var modelView: simd_float4x4
    var params: SIMD4<Float>
}

// The neutral-clay shader (M7.4) + a selection tint (M7.5), compiled at runtime so
// the SwiftPM target needs no .metal resource bundling (identical on iOS/macOS).
private let viewerShaderSource = """
#include <metal_stdlib>
using namespace metal;

\(unifiedMaterialSource)

// ★ MERGED, NOT PICKED (2026-08-16). `render-quality` added world-space shading
// fields to `VOut` and a `ShadeParams`; this task added the cut's per-fragment
// half-space test, which needs `mpos`/`member` and its own uniforms. Both sides
// grew the SAME structs, so the resolution is their union — taking either side
// whole would have silently dropped a feature that still has its Swift half.
struct VIn  { float3 position [[attribute(0)]]; float3 normal [[attribute(1)]];
              float4 tint [[attribute(2)]]; float4 flags [[attribute(3)]]; };
struct VOut { float4 position [[position]]; float3 vnormal; float4 tint; float mheight;
              // §6 — the cut's half-space test, per fragment.
              float3 mpos; float member;
              // render-quality — world-space shading + eye depth.
              float3 wnormal; float3 wpos; float eyeZ; float3 eyeWS [[flat]]; };
// ★ §6 — THE CUT, TESTED PER FRAGMENT.
//
// A cut is a HALF-SPACE, so which side a point is on is a question about the
// POINT — and the only place every point exists is the fragment stage. Decided
// per vertex, the boundary can only fall on vertices and the GPU smears between
// them; decided per TRIANGLE, it can only fall on triangle edges, and on a coarse
// tessellation of a curved face that reads as shattered glass ("look at the face,
// it looks like a glass piece broken apart"). Neither is where the plane is.
//
// `plane` is (normal.xyz, -dot(normal, point)) in MODEL space, so the test is one
// dot product. `member` marks the fragments this applies to — the faces belonging
// to the selected region — and is written per vertex because face membership IS a
// per-face fact, not a per-point one.
struct CutUniforms {
    float4 plane;
    float4 colSelected;
    float4 colSibling;
    float  enabled;
    // ★ PICK GROUPS — up to 4 PIECES, each an intersection of up to 4 half-spaces,
    // laid out consecutively in `pickPlanes` with `pickCounts` giving each one's
    // length. A fragment is "picked" when it satisfies EVERY plane of ANY group.
    //
    // ★ WHY THIS EXISTS. A piece of a cut face resolves to the whole FACE, so
    // lighting a picked piece by its member faces lit its siblings too: one tap
    // appeared to select two pieces, and a second tap could not be seen to
    // register at all. A piece is defined by its half-spaces, so only a
    // half-space test can draw exactly it.
    float4 pickPlanes[16];
    int4   pickCounts;
    int    pickGroups;
};
struct Uniforms { float4x4 mvp; float4x4 normalMatrix; float4 flex;
                  float4x4 worldNormalMatrix; float4x4 model; float4x4 modelView; float4 eye; };
// `ShadeParams` and the material itself now live in `unifiedMaterialSource`,
// prepended above — see UnifiedShading.swift for why (§1d: the lattice must respond
// to light IDENTICALLY, and the only way to be sure is one definition).


// buffer(3) carries the per-vertex FEA displacement (mm); `flex.x` scales it
// (exaggeration·amplitude). At scale 0 the buffer contributes nothing, so the
// static workspace draw is byte-identical — this is the M7.viz.3 flex animation,
// a pure vertex displacement of the already-solved solution (no re-simulation).
vertex VOut viewer_vertex(VIn in [[stage_in]], constant Uniforms& u [[buffer(1)]],
                          constant packed_float3* disp [[buffer(3)]], uint vid [[vertex_id]]) {
    VOut o;
    float3 p = in.position + u.flex.x * float3(disp[vid]);
    o.position = u.mvp * float4(p, 1.0);
    o.vnormal  = (u.normalMatrix * float4(in.normal, 0.0)).xyz;
    o.tint = in.tint;
    o.mheight = in.position.y;   // model-space height (rest), for the M7.8 reveal scrub
    o.mpos = in.position;        // §6: rest model position, for the cut's half-space test
    o.member = in.flags.x;       // §6: 1 on faces of the selected region
    // §2 / §3d: the WORLD normal + WORLD position (so the light can stay put while the
    // camera orbits) and the EYE depth (so the far side of a dense lattice can recede).
    o.wnormal = (u.worldNormalMatrix * float4(in.normal, 0.0)).xyz;
    o.wpos    = (u.model * float4(p, 1.0)).xyz;
    o.eyeZ    = -(u.modelView * float4(p, 1.0)).z;   // eye looks down −Z → positive into the screen
    o.eyeWS   = u.eye.xyz;                           // flat: one value for the whole draw
    return o;
}

// `reveal` = (fraction 0..1, minY, maxY, enabled). When enabled, fragments above
// the reveal height (normalized model Y) are discarded — the results morph scrub
// (M7.8). Default (…, 0) shows everything, so edit-mode is unaffected.
// `bodyAlpha` (buffer 1) is the body opacity for the load-flow x-ray/stress body
// modes (handoff 070): the output is PREMULTIPLIED (rgb·a, a), so the opaque draw
// (a == 1, blending off) is byte-identical to before while a translucent pipeline
// (a < 1, premultiplied "over" blending) shows the flow through the walls.
fragment float4 viewer_fragment(VOut in [[stage_in]], constant float4& reveal [[buffer(0)]],
                                constant float& bodyAlpha [[buffer(1)]],
                                constant ShadeParams& sp [[buffer(2)]],
                                // ★ MOVED TO 3 BY THE MERGE. `render-quality` took
                                // buffer(2) for `ShadeParams`; the cut's uniforms had
                                // it first but the shading is the one with a texture
                                // binding beside it, so this is the cheaper move. The
                                // Swift `setFragmentBytes` index moves with it.
                                constant CutUniforms& cut [[buffer(3)]],
                                texture2d<float, access::sample> aoTex [[texture(0)]]) {
    if (reveal.w > 0.5) {
        float t = (in.mheight - reveal.y) / max(reveal.z - reveal.y, 1e-4);
        if (t > reveal.x) discard_fragment();
    }
    float3 N = normalize(in.vnormal);

    // ── §1 AMBIENT OCCLUSION + §3a EDGES ────────────────────────────────────────
    // ONE bilinear fetch of the RG texture the SSAO pass wrote: R = openness
    // (1 = fully open, 0 = fully occluded), G = the screen-space silhouette/crease
    // edge. Both strengths are zero in the BEFORE capture, which makes this whole
    // block an identity.
    constexpr sampler aoSmp(filter::linear, address::clamp_to_edge);
    float2 aoUV = in.position.xy * float2(sp.ao.z, sp.ao.w);
    float2 aoEdge = aoTex.sample(aoSmp, aoUV).rg;
    float openness = mix(1.0, aoEdge.r, clamp(sp.ao.x, 0.0, 1.0));
    // AO belongs on the AMBIENT term (that is what it models — how much of the sky
    // a point can see). A fraction of it also rides the direct terms, which is not
    // physical but is what makes a lattice's interior read as depth rather than noise.
    float ambientAO = openness;
    float directAO  = mix(1.0, openness, 0.45);

    // ── §2 LIGHTING ─────────────────────────────────────────────────────────────
    // fade.w == 0 → the ORIGINAL view-locked headlight AND the original tint
    //   composite, kept verbatim: with the two strengths at zero this branch is
    //   BYTE-IDENTICAL to the shipped shader, so the BEFORE capture is the shipped
    //   picture rather than a reconstruction of it.
    // fade.w == 1 → a WORLD-space key/fill/rim over a hemisphere ambient. World, not
    //   eye: orbit the camera and the highlight stays on the same face of the part,
    //   which is the defect §2(c) names.
    float3 clay = float3(0.78, 0.77, 0.75);
    // ★ §6 — THE CUT, EXACTLY, AND IT IS DECIDED BEFORE THE SHADING.
    //
    // The merge with `render-quality` put a whole new lighting model here, and the
    // cut is not a lighting question — it decides WHICH TINT this fragment carries.
    // So it is resolved once, into `tint`, and both shading branches read that
    // instead of `in.tint`. Written any other way the cut would have to be applied
    // twice and could drift between the two.
    //
    // On the selected region's faces the side is decided HERE, per fragment, from
    // the fragment's own model position: the boundary is then the plane itself, at
    // any tessellation, and a triangle the plane crosses is split by it rather than
    // being forced whole to one side.
    float4 tint = in.tint;
    if (cut.enabled > 0.5 && in.member > 0.5) {
        float d = dot(cut.plane.xyz, in.mpos) + cut.plane.w;
        tint = (d >= 0.0) ? cut.colSelected : cut.colSibling;
    }
    // ★ THE PICKED PIECES (union tool). Inside EVERY plane of ANY group.
    if (cut.pickGroups > 0 && in.member > 0.5) {
        int base = 0;
        bool anyIn = false;
        for (int g = 0; g < 4; ++g) {
            if (g >= cut.pickGroups) break;
            int n = (g == 0) ? cut.pickCounts.x
                  : (g == 1) ? cut.pickCounts.y
                  : (g == 2) ? cut.pickCounts.z : cut.pickCounts.w;
            bool allIn = true;
            for (int k = 0; k < 4; ++k) {
                if (k >= n) break;
                float4 pl = cut.pickPlanes[base + k];
                if (dot(pl.xyz, in.mpos) + pl.w < 0.0) { allIn = false; break; }
            }
            if (n > 0 && allIn) { anyIn = true; break; }
            base += n;
        }
        tint = anyIn ? cut.colSelected : cut.colSibling;
    }
    float3 color;
    if (sp.fade.w > 0.5) {
        // ★ THE ONE MATERIAL, CALLED — not a copy of it. `to_material` is the rig
        // that used to be written out here, moved verbatim into
        // `unifiedMaterialSource` so the lattice's deferred shade calls the SAME
        // function with the SAME constants (§1d). The normal flip toward the viewer,
        // the hemisphere ambient, the key, the fill and the Fresnel rim are all in
        // there, unchanged, with the notes that explain their values.
        float3 Nw = normalize(in.wnormal);
        float3 V  = normalize(in.eyeWS - in.wpos);
        TOMaterial mat = to_material(Nw, V, ambientAO, directAO);
        float3 shade = mat.shade;
        float3 rim = mat.rim;
        // Region/selection tint tints the ALBEDO, not the finished pixel. That one
        // move is what §4 rests on: a tinted region now carries the SAME occlusion,
        // key, fill and rim as bare clay, so it reads as a shaded solid instead of a
        // flat colour laid over the part. tint.a == 0 → albedo is clay → unchanged.
        //
        // ★ §4 — AND THAT IS WHY THE SATURATION CAN COME DOWN. "The purple fucking
        // colour should never happen again (same with the green)": those colours were
        // as loud as they were because flat shading left HUE as the only channel that
        // could say "this region is different". With occlusion and a real key/fill/rim
        // the region already reads as a shaded solid, so the hue only has to IDENTIFY
        // it, not carry it. `sp.tint.x` is how much saturation is removed; the result is
        // also lifted back toward clay's brightness so a deep indigo becomes a muted
        // slate rather than a dark stain on an otherwise light material.
        float3 tintRGB = tint.rgb;
        if (sp.tint.x > 0.001) {
            const float3 LUMA = float3(0.2126, 0.7152, 0.0722);
            float tl = dot(tintRGB, LUMA);
            tintRGB = mix(float3(tl), tintRGB, clamp(1.0 - sp.tint.x, 0.0, 1.0));
            float cl = dot(clay, LUMA);
            tintRGB *= mix(1.0, cl / max(tl, 1e-3), clamp(sp.tint.y, 0.0, 1.0));
            tintRGB = clamp(tintRGB, 0.0, 1.0);
        }
        float3 albedo = mix(clay, tintRGB, clamp(tint.a, 0.0, 1.0));
        color = albedo * shade + rim;
    } else {
        // ORIGINAL (before): soft half-Lambert key + hemisphere fill in EYE space.
        float3 key  = normalize(float3(0.30, 0.60, 0.72));
        // NB: avoid the name `half` — a reserved 16-bit-float type in MSL that makes
        // makeLibrary fail (silently blanking the whole stage).
        float  keyWrap = clamp(dot(N, key) * 0.5 + 0.5, 0.0, 1.0);
        float  fill = clamp(dot(N, float3(-0.45, -0.25, 0.40)) * 0.5 + 0.5, 0.0, 1.0);
        float  lighting = 0.60 + 0.42 * keyWrap + 0.12 * fill;
        color = clay * lighting * (ambientAO * 0.55 + directAO * 0.45);
        float  fres = pow(1.0 - clamp(N.z, 0.0, 1.0), 4.0) * 0.10;
        color += float3(0.10, 0.12, 0.16) * fres;
        if (tint.a > 0.001) {
            color = mix(color, tint.rgb * (0.55 + 0.45 * lighting), tint.a);
        }
    }
    // §3a's crease/silhouette line and §3d's depth fade — the shared tail (see
    // `to_edge_fade` in UnifiedShading.swift), so the lattice's far side recedes on the
    // same curve toward the same backdrop colour and its creases are drawn at the same
    // strength. Two surfaces that fade differently read as two objects at any distance.
    color = to_edge_fade(color, aoEdge.g, sp.ao.y, in.eyeZ, sp.fade);
    // Handoff 124 — Face protection crosshatch. A protected face carries the UNIQUE
    // mint-teal PROTECT_RGB (WorkspacePlaceholder.protectFaceRGB); recognise it by
    // colour and lay a screen-space DIAGONAL CROSSHATCH over it — a "preserved" mark,
    // deliberately unlike the red clearance VOLUMES that read "forbidden". Two line
    // families (±45°) in screen pixels; `fwidth` keeps the strokes ~1px at any zoom.
    const float3 PROTECT_RGB = float3(0.18, 0.88, 0.78);
    if (in.tint.a > 0.001 && all(abs(in.tint.rgb - PROTECT_RGB) < 0.04)) {
        float2 px = in.position.xy;
        float period = 9.0;               // hatch spacing in pixels
        float d1 = fract((px.x + px.y) / period) - 0.5;   // "/" family
        float d2 = fract((px.x - px.y) / period) - 0.5;   // "\" family
        float w1 = fwidth(d1), w2 = fwidth(d2);
        // Coverage of a ~1.3px stroke centred on each line (antialiased by fwidth).
        float line1 = 1.0 - smoothstep(0.0, max(w1, 1e-4) * 1.3, abs(d1));
        float line2 = 1.0 - smoothstep(0.0, max(w2, 1e-4) * 1.3, abs(d2));
        float hatch = clamp(line1 + line2, 0.0, 1.0);
        // Darken the strokes toward a deep teal so the weave reads on the lit clay.
        color = mix(color, float3(0.02, 0.32, 0.28), hatch * 0.85);
    }
    float3 rgb = clamp(color, 0.0, 1.0);
    return float4(rgb * bodyAlpha, bodyAlpha);   // premultiplied (a==1 → unchanged)
}
"""

// The id-buffer pass: draw each face's id into an R32Uint target (flat-interpolated
// so every fragment of a triangle carries its exact face id), read back at the tap.
private let idShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct IDIn  { float3 position [[attribute(0)]]; uint faceid [[attribute(1)]]; };
struct IDOut { float4 position [[position]]; uint faceid [[flat]]; };
struct Uniforms { float4x4 mvp; float4x4 normalMatrix; };

vertex IDOut id_vertex(IDIn in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
    IDOut o;
    o.position = u.mvp * float4(in.position, 1.0);
    o.faceid = in.faceid;
    return o;
}

fragment uint id_fragment(IDOut in [[stage_in]]) { return in.faceid; }
"""

// The ground pass (M7.6 D2): the settle ground grid + soft contact shadow, drawn
// on the world floor plane the part rests on after gravity is set. Per-vertex
// colour+alpha (grid fades with distance; the shadow disc fades to its rim), so it
// needs alpha blending; MVP is the plain camera view·projection (the ground is
// world-space — the *part* rotates onto it, not the reverse).
private let groundShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct GIn  { float3 position [[attribute(0)]]; float4 color [[attribute(1)]]; };
struct GOut { float4 position [[position]]; float4 color; };
struct GUniforms { float4x4 mvp; };

vertex GOut ground_vertex(GIn in [[stage_in]], constant GUniforms& u [[buffer(1)]]) {
    GOut o;
    o.position = u.mvp * float4(in.position, 1.0);
    o.color = in.color;
    return o;
}

fragment float4 ground_fragment(GOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);   // premultiplied
}

// ★ WIDE LINES, MEASURED IN SCREEN SPACE (§6b).
//
// Metal rasterises a `.line` primitive at exactly ONE PIXEL. On a retina iPad
// that is a hairline: the maintainer could not see the wireframe however dark it
// was drawn, because there was almost nothing of it to see. Line width is not a
// pipeline setting in Metal — the only way to get a thick line is to stop drawing
// lines and draw QUADS instead.
//
// Each segment arrives as SIX vertices (two triangles) carrying the same two
// endpoints; `side` says which corner this vertex is. Both ends are projected to
// clip space FIRST, the perpendicular is taken in NDC, and the corner is offset by
// a width expressed in NDC — so the thickness is defined in SCREEN space and does
// not change as the part is zoomed. That is the property asked for: "the lines
// look like the thickness doesn't change".
//
// `u.width.x` is the half-width in NDC-y units; `.y` corrects for aspect so a
// vertical line is as thick as a horizontal one.
struct WIn  { float3 a [[attribute(0)]]; float3 b [[attribute(1)]];
              float4 color [[attribute(2)]]; float2 side [[attribute(3)]]; };
struct WOut { float4 position [[position]]; float4 color; };
struct WUniforms { float4x4 mvp; float4 width; };

vertex WOut wideline_vertex(WIn in [[stage_in]], constant WUniforms& u [[buffer(1)]]) {
    WOut o;
    float4 ca = u.mvp * float4(in.a, 1.0);
    float4 cb = u.mvp * float4(in.b, 1.0);
    // Guard the degenerate cases rather than dividing by zero behind the camera.
    float wa = max(abs(ca.w), 1e-5), wb = max(abs(cb.w), 1e-5);
    float2 na = ca.xy / wa, nb = cb.xy / wb;
    float2 dir = nb - na;
    // Aspect-correct the direction so the perpendicular is right on screen, not
    // in NDC — otherwise a vertical line comes out thinner than a horizontal one.
    dir.x *= u.width.y;
    float len = max(length(dir), 1e-6);
    float2 perp = float2(-dir.y, dir.x) / len;
    perp.x /= u.width.y;

    // side.x: 0 = the a end, 1 = the b end. side.y: -1 / +1 across the line.
    float4 clip = (in.side.x < 0.5) ? ca : cb;
    float w = (in.side.x < 0.5) ? wa : wb;
    clip.xy += perp * in.side.y * u.width.x * w;
    o.position = clip;
    o.color = in.color;
    return o;
}

fragment float4 wideline_fragment(WOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);   // premultiplied
}
"""

// The DEPTH PREPASS (device round 3, items 7+8, parts b+c): render ONLY the opaque part into an
// R32Float target holding each nearest surface's EYE-SPACE depth (positive, increasing into the
// screen). The translucent contact pass (below) reads it to know how far the part surface is at
// each pixel — you cannot sample the depth attachment you are currently rendering into, so the
// part's depth is captured here in its own pass first. Clears to a large sentinel where no part
// covers the pixel (→ the contact read finds "nothing behind" and shades the volume normally).
// Reuses the mesh's position+flex buffers so the captured depth matches the visible part EXACTLY
// (same mvp, same flex displacement). Runs only on a redraw when a translucent volume is present
// (gated in `encode`) — STATIC, no idle-time cost (the 108 rule).
//
// ★ RENDER QUALITY (task 2026-08-15-render-quality): this pass is now also the app's
// G-BUFFER. It gained a SECOND colour attachment — the eye-space NORMAL — because
// SSAO (§1) and the crease/silhouette edge (§3a) both need a normal per pixel, and
// re-rasterising the part a third time to get one would double the geometry cost of
// the feature. Attachment 0 is UNCHANGED (same format, same eye-Z, same sentinel),
// so the contact pass below reads exactly the bytes it always did. It now also runs
// whenever AO/edges are on, not only when a translucent volume is present.
private let depthPrepassShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct DIn  { float3 position [[attribute(0)]]; float3 normal [[attribute(1)]]; };
struct DOut { float4 position [[position]]; float eyeZ; float3 enormal; };
struct DUniforms { float4x4 mvp; float4x4 modelView; float4 flex; float4x4 normalMatrix; };
struct GBuf { float  eyeZ    [[color(0)]];      // R32Float — unchanged, the contact pass reads this
              float4 enormal [[color(1)]];      // RGBA16Float — eye-space normal (xyz), w unused
              // ★ ATTACHMENT 2 (task 2026-08-18-unified-shading): the LATTICE's albedo,
              // alpha as its mask. The shell writes ZERO here, which is how the unified
              // deferred shade knows a pixel belongs to the rasterised body and not to
              // the marched lattice — a mask in a channel that already had to exist,
              // rather than a fourth pass to compute one.
              float4 albedo  [[color(2)]]; };

vertex DOut depth_vertex(DIn in [[stage_in]], constant DUniforms& u [[buffer(1)]],
                         constant packed_float3* disp [[buffer(3)]], uint vid [[vertex_id]]) {
    float3 p = in.position + u.flex.x * float3(disp[vid]);   // match viewer_vertex's flex
    DOut o;
    o.position = u.mvp * float4(p, 1.0);
    o.eyeZ = -(u.modelView * float4(p, 1.0)).z;   // eye looks down −Z → positive into the screen
    o.enormal = (u.normalMatrix * float4(in.normal, 0.0)).xyz;
    return o;
}

fragment GBuf depth_fragment(DOut in [[stage_in]]) {
    GBuf o;
    o.eyeZ = in.eyeZ;
    // Face the normal toward the eye. The mesh draws with cullMode .none, so a
    // back-facing triangle's raw normal points away and the AO hemisphere would be
    // built on the wrong side of the surface — every sample behind the wall, every
    // pixel reported fully occluded. Eye space makes the test one sign check.
    float3 n = normalize(in.enormal);
    if (n.z < 0.0) { n = -n; }
    o.enormal = float4(n, 0.0);
    o.albedo = float4(0.0);      // "this pixel is the shell, not the lattice"
    return o;
}
"""

// ★ §3c CONTACT SHADOW — the part's own FOOTPRINT, not an ellipse.
// One orthographic pass straight down onto the stage floor's XZ rectangle, writing
// 1.0 wherever the part covers it. It is re-rendered only when the mesh, the settle
// rotation or the floor rectangle changes — never on a camera move and never on an
// idle frame (the 108 rule), because a drop shadow from directly above does not
// depend on where the camera is. The softness comes from the target's low resolution
// plus a 3×3 tap in `stage_fragment`; there is no blur pass.
private let shadowShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct ShIn  { float3 position [[attribute(0)]]; };
struct ShOut { float4 position [[position]]; };
// `rect` = (originX, originZ, sizeX, sizeZ) — the same world-XZ rectangle
// `stage_fragment` maps its floor hit into, so the two cannot disagree.
struct ShUniforms { float4x4 model; float4 rect; float4 flex; };

vertex ShOut shadow_vertex(ShIn in [[stage_in]], constant ShUniforms& u [[buffer(1)]],
                           constant packed_float3* disp [[buffer(3)]], uint vid [[vertex_id]]) {
    float3 p = in.position + u.flex.x * float3(disp[vid]);   // match viewer_vertex's flex
    float3 w = (u.model * float4(p, 1.0)).xyz;
    float2 uv = (w.xz - u.rect.xy) / max(u.rect.zw, float2(1e-6));
    ShOut o;
    // uv.y = 0 must land on texture ROW 0, which is NDC y = +1.
    o.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    return o;
}

fragment float shadow_fragment(ShOut in [[stage_in]]) { return 1.0; }
"""

// ★ §1 SCREEN-SPACE AMBIENT OCCLUSION + §3a EDGES, in ONE full-screen pass over the
// G-buffer above. Both outputs are per-pixel screen-space quantities derived from the
// same two texture reads, so computing them together costs one pass instead of two:
//
//   R = OPENNESS in [0,1]. 1 = the point sees the whole hemisphere, 0 = fully closed
//       in. Classic hemisphere-sampled SSAO: reconstruct the eye-space position from
//       (pixel, eye-Z), throw `N` samples into the hemisphere around the eye-space
//       normal, and count how many land BEHIND the depth buffer. On a lattice that is
//       the answer everywhere — which is the point: this is the term that turns "flat
//       grey struts with nothing between them" into structure.
//
//   G = EDGE in [0,1]. A depth-and-normal discontinuity: a large relative jump in
//       eye-Z (a silhouette, incl. against the empty background sentinel) or a sharp
//       normal turn (a crease). Deliberately narrow and applied at only 70% darkening
//       by the body shader — §3a says subtle, not a cartoon outline.
//
// The per-pixel kernel rotation is INTERLEAVED GRADIENT NOISE, not a random texture:
// one fract() instead of a texture fetch and a bind, and its 3×3 spatial period is
// exactly what the blur below is sized to remove.
private let aoShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct AOUniforms { float4 proj; float4 params; float4 edge; };
struct AOOut { float4 pos [[position]]; };

vertex AOOut ao_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));   // (0,0)(2,0)(0,2)
    AOOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// Eye-space position of the pixel at fragment coord `px` holding eye depth `z`.
// (Fragment coords run y-DOWN and match texture rows exactly, which is why every
// read here is an integer `read()` and there is not a single uv flip in this file.)
static float3 eyeFromPixel(float2 px, float z, float4 proj) {
    float2 uv  = (px + 0.5) / float2(proj.z, proj.w);
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    return float3(ndc.x * proj.x * z, ndc.y * proj.y * z, -z);
}

// The inverse: where an eye-space point lands, in fragment coords.
static float2 pixelFromEye(float3 e, float4 proj) {
    float z = max(-e.z, 1e-6);
    float2 ndc = float2(e.x / (proj.x * z), e.y / (proj.y * z));
    return float2((ndc.x * 0.5 + 0.5) * proj.z, (0.5 - ndc.y * 0.5) * proj.w);
}

fragment float4 ao_fragment(AOOut in [[stage_in]], constant AOUniforms& u [[buffer(0)]],
                            texture2d<float, access::read> depthTex [[texture(0)]],
                            texture2d<float, access::read> normalTex [[texture(1)]]) {
    int W = int(u.proj.z), H = int(u.proj.w);
    int2 px = int2(in.pos.xy);
    float z = depthTex.read(uint2(px)).x;
    // Background: no part at this pixel. Fully open, no edge — and NO sample loop,
    // so the cost of this pass scales with how much of the screen the part covers.
    if (z >= u.edge.z) { return float4(1.0, 0.0, 0.0, 1.0); }

    float3 N = normalize(normalTex.read(uint2(px)).xyz);
    float3 P = eyeFromPixel(float2(px), z, u.proj);

    // ── R: ambient occlusion ────────────────────────────────────────────────────
    float radius = u.params.x, intensity = u.params.y;
    // The bias grows with depth: at 1 px the depth buffer's own quantisation grows
    // with z too, and a constant bias that is right up close self-occludes far away.
    float bias = max(u.params.z, z * 0.0015);
    int   nSamples = int(u.params.w);
    float ign = fract(52.9829189 * fract(dot(float2(px), float2(0.06711056, 0.00583715))));
    float ang0 = ign * 6.2831853;
    // A tangent frame around N — the hemisphere the samples are thrown into.
    float3 up = (abs(N.z) < 0.9) ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 T1 = normalize(cross(up, N));
    float3 T2 = cross(N, T1);
    float occ = 0.0;
    for (int i = 0; i < nSamples; ++i) {
        float t = (float(i) + 0.5) / float(nSamples);
        float r = sqrt(t);                       // cosine-weighted over the disc
        float a = ang0 + float(i) * 2.3999632;   // golden angle — an even spiral at any N
        float3 dir = T1 * (cos(a) * r) + T2 * (sin(a) * r) + N * sqrt(max(0.0, 1.0 - r * r));
        // Vary the sample DISTANCE as well as the direction, so one kernel resolves
        // both the tight crevice between two struts and the open bay beside them.
        float3 S = P + dir * (radius * (0.30 + 0.70 * t));
        float2 sp = pixelFromEye(S, u.proj);
        if (sp.x < 0.0 || sp.y < 0.0 || sp.x >= float(W) || sp.y >= float(H)) { continue; }
        float sceneZ = depthTex.read(uint2(sp)).x;
        if (sceneZ >= u.edge.z) { continue; }    // sample fell on empty background
        // Occluded when the surface at that pixel is NEARER than the sample point.
        if (sceneZ < -S.z - bias) {
            // Range check: an occluder far outside the radius (a foreground object,
            // not a neighbouring strut) must not cast AO through empty space.
            occ += clamp(radius / max(abs(z - sceneZ), 1e-5), 0.0, 1.0);
        }
    }
    float openness = clamp(1.0 - (occ / float(nSamples)) * intensity, 0.0, 1.0);

    // ── G: silhouette + crease edge ─────────────────────────────────────────────
    // Four-neighbour depth and normal differences. The depth threshold is RELATIVE
    // to eye-Z, so one setting holds from a 20 mm cell to a 200 mm bracket and does
    // not thicken as the camera pulls back.
    float dMax = 0.0, nMin = 1.0;
    for (int k = 0; k < 4; ++k) {
        int2 o = (k == 0) ? int2(1, 0) : (k == 1) ? int2(-1, 0) : (k == 2) ? int2(0, 1) : int2(0, -1);
        int2 q = clamp(px + o, int2(0), int2(W - 1, H - 1));
        float qz = depthTex.read(uint2(q)).x;
        // A neighbour on the background is a SILHOUETTE: the strongest edge there is.
        if (qz >= u.edge.z) { dMax = max(dMax, z * 4.0); continue; }
        dMax = max(dMax, abs(qz - z));
        nMin = min(nMin, dot(N, normalize(normalTex.read(uint2(q)).xyz)));
    }
    float depthEdge  = smoothstep(z * u.edge.x, z * u.edge.x * 3.0, dMax);
    float normalEdge = smoothstep(u.edge.y, u.edge.y * 0.35, nMin);   // nMin FALLS as the crease sharpens
    float edge = clamp(max(depthEdge, normalEdge), 0.0, 1.0);

    return float4(openness, edge, 0.0, 1.0);
}

// The AO blur. Raw SSAO is noisy by construction — `nSamples` directions cannot
// resolve a hemisphere — and the interleaved-gradient rotation puts that noise on a
// 3×3 screen period, so a 4×4 box average removes essentially all of it. It is
// DEPTH-AWARE: a neighbour more than a few percent of eye-Z away is a different
// surface and is dropped, which is what stops AO bleeding across a silhouette. The
// EDGE channel is passed through UNTOUCHED — blurring it is how a crisp crease line
// becomes a grey smear.
fragment float4 aoblur_fragment(AOOut in [[stage_in]], constant AOUniforms& u [[buffer(0)]],
                                texture2d<float, access::read> aoTex [[texture(0)]],
                                texture2d<float, access::read> depthTex [[texture(1)]]) {
    int W = int(u.proj.z), H = int(u.proj.w);
    int2 px = int2(in.pos.xy);
    float2 c = aoTex.read(uint2(px)).rg;
    float z = depthTex.read(uint2(px)).x;
    if (z >= u.edge.z) { return float4(c.r, c.g, 0.0, 1.0); }
    float sum = 0.0, wsum = 0.0;
    for (int dy = -2; dy <= 1; ++dy) {
        for (int dx = -2; dx <= 1; ++dx) {
            int2 q = clamp(px + int2(dx, dy), int2(0), int2(W - 1, H - 1));
            float qz = depthTex.read(uint2(q)).x;
            if (qz >= u.edge.z) { continue; }
            if (abs(qz - z) > z * 0.03) { continue; }
            sum += aoTex.read(uint2(q)).r;
            wsum += 1.0;
        }
    }
    float ao = (wsum > 0.0) ? (sum / wsum) : c.r;
    return float4(ao, c.g, 0.0, 1.0);
}
"""

// The CONTACT pass (device round 3, items 7+8, parts b+c): ONE shader variant shared by BOTH the
// design-box glass and the keep-clear clearance FACE draws (the two consumers). It replaces
// `ground_fragment` for those faces, adding (b) a bright additive CONTACT LINE where the
// translucent surface meets the part and (c) an interior contact-occlusion darkening just inside
// it. Both are driven by |fragmentEyeDepth − sceneEyeDepth| read from the depth-prepass texture.
// Away from the part (large depth gap) it is BYTE-IDENTICAL to `ground_fragment`, so only the
// contact region changes.
//
// HONESTY (bake this into the doc too): this is a screen-space depth-proximity effect, not a true
// analytic intersection curve. Known failure mode: at grazing angles the depth gradient is
// shallow, so `d` stays small across many pixels and the contact line thickens. That's expected
// and acceptable for the contact read.
private let contactShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct CIn  { float3 position [[attribute(0)]]; float4 color [[attribute(1)]]; };
struct COut { float4 position [[position]]; float4 color; float eyeZ; };
// params: (x = contact-line feather in PIXELS, y = occlusion falloff in PIXELS,
//          zw = G-BUFFER TEXELS PER COLOUR PIXEL — 1,1 unless the G-buffer is
//          resolution-capped, which it is whenever a lattice is in the frame
//          (`MeshRenderer.latticeGBufferMaxPixels`). Reading a capped texture with
//          full-resolution fragment coordinates would sample the wrong texel and run
//          off the edge, and this pass has always read by integer coordinate.)
struct CUniforms { float4x4 mvp; float4x4 modelView; float4 params; };

vertex COut contact_vertex(CIn in [[stage_in]], constant CUniforms& u [[buffer(1)]]) {
    COut o;
    float4 p = float4(in.position, 1.0);
    o.position = u.mvp * p;
    o.color = in.color;
    o.eyeZ = -(u.modelView * p).z;   // same eye-space depth convention as the prepass
    return o;
}

fragment float4 contact_fragment(COut in [[stage_in]], constant CUniforms& u [[buffer(1)]],
                                 texture2d<float, access::read> sceneDepth [[texture(0)]]) {
    float featherPx = max(u.params.x, 1e-3);
    float occPx     = max(u.params.y, 1e-3);
    // The opaque part's eye-space depth at THIS pixel (a large sentinel where no part covers it).
    float2 gscale = max(u.params.zw, float2(1e-6));
    uint2 gpx = uint2(clamp(in.position.xy * gscale, float2(0.0),
                            float2(sceneDepth.get_width() - 1, sceneDepth.get_height() - 1)));
    float sceneEyeZ = sceneDepth.read(gpx).x;
    float d = abs(sceneEyeZ - in.eyeZ);
    // Convert the eye-space gap to a SCREEN-space one: dividing by how fast eye-Z changes per pixel
    // (fwidth) gives the contact's width in pixels, so the feather is a consistent ~1–2 px at any
    // model scale or resolution. This is what makes the grazing-angle thickening in the honesty
    // caveat emerge for free: at a grazing angle eye-Z changes fast per pixel (large fwidth), so
    // `dPix` stays small across many pixels and the line thickens.
    float dPix = d / max(fwidth(in.eyeZ), 1e-6);
    // ground_fragment's premultiplied output — the untouched look away from the part.
    float3 groundRGB = in.color.rgb * in.color.a;
    // (c) interior contact-occlusion: darken the volume right at the contact (dPix≈0), fading back
    // to the full look away from the part surface.
    float occ = mix(0.42, 1.0, saturate(dPix / occPx));
    float3 baseRGB = groundRGB * occ;
    // (b) bright additive contact LINE where the translucent surface meets the part (dPix≈0),
    // tinted toward the volume's own hue so a red clearance glows red-hot and the blue box cool.
    float line = smoothstep(featherPx, 0.0, dPix);
    float3 hue = normalize(in.color.rgb + 1e-4);
    float3 lineCol = mix(float3(1.0), hue, 0.35) * line * 0.9;
    return float4(baseRGB + lineCol, in.color.a);   // premultiplied; == ground_fragment far from contact
}
"""

// The load-path overlay pass (M7.viz.4): the principal-stress-direction glyphs drawn
// as THICK, ANIMATED ribbons rather than 1px lines. Two things the plain GL-line draw
// could not do:
//   • Thickness — Metal `.line` primitives are always one pixel, so the hedgehog read
//     as a faint scribble. Each segment is expanded in the VERTEX shader into a
//     screen-space-width ribbon (billboarded quad), so the lines stay a legible,
//     constant pixel width from any camera angle.
//   • Flow — a `flow` phase (advanced by the results ticker) scrolls a bright dash
//     along each segment's length (u = 0 at one end → 1 at the other), so force reads
//     as visibly TRAVELLING through the structure rather than sitting static.
// Each ribbon vertex carries both segment endpoints (to derive the screen-space
// perpendicular), a side (±1) and an end flag (0/1 → the dash coordinate `u`), plus
// the glyph's shared-scale colour. Blended premultiplied like the ground pass.
private let loadPathShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct LPIn {
    float3 segStart [[attribute(0)]];
    float3 segEnd   [[attribute(1)]];
    float2 sideEnd  [[attribute(2)]];   // x = side (±1), y = end flag (0 = start, 1 = end)
    float4 color    [[attribute(3)]];
};
struct LPOut { float4 position [[position]]; float4 color; float u; };
// params: (aspect = w/h, halfWidth in NDC-y, flow phase 0..1, unused).
struct LPUniforms { float4x4 mvp; float4 params; };

vertex LPOut loadpath_vertex(LPIn in [[stage_in]], constant LPUniforms& u [[buffer(1)]]) {
    float4 c0 = u.mvp * float4(in.segStart, 1.0);
    float4 c1 = u.mvp * float4(in.segEnd, 1.0);
    float endFlag = in.sideEnd.y;
    float4 clip = (endFlag < 0.5) ? c0 : c1;
    // Screen-space (NDC) segment direction, aspect-corrected so width is uniform px.
    float asp = max(u.params.x, 1e-4);
    float2 s0 = c0.xy / max(c0.w, 1e-4);
    float2 s1 = c1.xy / max(c1.w, 1e-4);
    float2 dir = (s1 - s0); dir.x *= asp;
    float len = max(length(dir), 1e-5);
    dir /= len;
    float2 perp = float2(-dir.y, dir.x);
    perp.x /= asp;                         // undo the aspect stretch on the x offset
    float hw = u.params.y;
    clip.xy += perp * in.sideEnd.x * hw * clip.w;   // offset in clip space (× w)
    LPOut o;
    o.position = clip;
    o.color = in.color;
    o.u = endFlag;                         // interpolates 0→1 along the ribbon length
    return o;
}

fragment float4 loadpath_fragment(LPOut in [[stage_in]], constant LPUniforms& u [[buffer(1)]]) {
    // A single bright dash travels from u = 0 → 1 as the flow phase advances, over a
    // dim steady base so the whole path stays visible between pulses.
    float d = fract(in.u - u.params.z);
    float pulse = smoothstep(0.0, 0.22, d) * (1.0 - smoothstep(0.22, 0.62, d));
    float bright = 0.6 + 1.2 * pulse;
    float alpha = clamp(in.color.a * (0.5 + 0.6 * pulse), 0.0, 1.0);
    float3 col = clamp(in.color.rgb * bright, 0.0, 1.0);
    return float4(col * alpha, alpha);     // premultiplied
}
"""

// The CAD STAGE backdrop (design-overhaul round 2, item 9): replaces the flat black clear with
// a proper shaded room in the app's own liquid-glass language — a deep charcoal-blue radial
// gradient, a mathematically-correct infinite floor grid (blue-tinted, major/minor hierarchy,
// fading with distance), and a soft horizon glow. It is a FULL-SCREEN pass (no vertex buffer,
// the gl_VertexID triangle trick) drawn FIRST, depth-ALWAYS + no depth-write, so the part / box
// / grid drawn after it occlude it with correct depth. The floor grid is reconstructed per-pixel
// by intersecting each view ray with the world floor plane, so it tracks the camera EXACTLY
// from one uniform (`invVP`/`eye`/`floorY`) refreshed only when the camera changes — STATIC,
// zero continuous cost (the 108 rule): the view is on-demand, so this shader runs only on a
// redraw, never on an idle timer.
private let stageShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct StageUniforms {
    float4x4 invVP;     // inverse(projection · view), world reconstruction from clip
    float3   eye;       // camera world position
    float    floorY;    // world y of the stage floor plane
    float2   centerXZ;  // floor plane centre (x,z) — the fade origin
    float    spacing;   // minor grid spacing (world units)
    float    fadeRadius;// world distance at which the grid fully fades out
    float4   shadowRect;     // §3c — (originX, originZ, sizeX, sizeZ) in world XZ
    float    shadowStrength; // §3c — 0 = off
};

struct SOut { float4 pos [[position]]; float2 uv; };

vertex SOut stage_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));   // (0,0)(2,0)(0,2)
    SOut o;
    o.pos = float4(p * 2.0 - 1.0, 1.0, 1.0);   // z = far; depth-always + no-write anyway
    o.uv  = p * 2.0 - 1.0;
    return o;
}

static float gridMask(float2 coord) {
    float2 d = fwidth(coord);
    float2 g = abs(fract(coord - 0.5) - 0.5) / max(d, float2(1e-5));
    return 1.0 - min(min(g.x, g.y), 1.0);
}

fragment float4 stage_fragment(SOut in [[stage_in]], constant StageUniforms& U [[buffer(0)]],
                               texture2d<float, access::sample> shadowTex [[texture(0)]]) {
    float2 ndc = in.uv;

    // Backdrop: a deep charcoal-blue vertical gradient (darker up top, a touch lighter toward
    // the floor) with a soft radial vignette — tuned to the liquid-glass chrome.
    float v = ndc.y * 0.5 + 0.5;                       // 0 bottom → 1 top
    float3 top   = float3(0.020, 0.028, 0.052);
    float3 low   = float3(0.045, 0.060, 0.090);
    float3 col   = mix(low, top, smoothstep(0.0, 1.0, v));
    float vign   = 1.0 - 0.35 * dot(ndc, ndc);
    col *= clamp(vign, 0.6, 1.0);

    // View ray for this pixel (world space).
    float4 nh = U.invVP * float4(ndc, 0.0, 1.0);
    float4 fh = U.invVP * float4(ndc, 1.0, 1.0);
    float3 np = nh.xyz / nh.w;
    float3 fp = fh.xyz / fh.w;
    float3 rd = normalize(fp - np);
    float3 ro = U.eye;

    // Soft horizon glow: rays grazing the floor plane (|rd.y| small) get a faint blue lift.
    float horizon = 1.0 - smoothstep(0.0, 0.14, abs(rd.y));
    col += float3(0.10, 0.16, 0.28) * horizon * 0.5;

    // Infinite floor grid: intersect the ray with y = floorY.
    if (abs(rd.y) > 1e-5) {
        float t = (U.floorY - ro.y) / rd.y;
        if (t > 0.0) {
            float3 hit = ro + rd * t;
            float2 xz = hit.xz;
            float minor = gridMask(xz / U.spacing);
            float major = gridMask(xz / (U.spacing * 5.0));
            // Fade with distance from the floor centre, and with grazing angle (kills moiré
            // near the horizon), so far lines dissolve into the gradient.
            float dist  = length(xz - U.centerXZ);
            float fade  = 1.0 - smoothstep(U.fadeRadius * 0.35, U.fadeRadius, dist);
            float graze = smoothstep(0.02, 0.22, abs(rd.y));
            float3 gridCol = float3(0.34, 0.52, 0.80);
            float a = (minor * 0.16 + major * 0.34) * fade * graze;
            col = mix(col, gridCol, clamp(a, 0.0, 1.0));

            // ★ §3c CONTACT SHADOW. Right now the part FLOATS. `shadowTex` is the
            // part's own footprint — the silhouette it casts straight down, rendered
            // orthographically from above into a small R8 target — so this is the real
            // outline of a bracket or a lattice block, not an ellipse standing in for
            // one. Nine taps spread over one texel of the (deliberately low-resolution)
            // footprint give the soft edge; the resolution IS the blur kernel, which is
            // why there is no separate blur pass.
            //
            // HONESTY, and it is in the doc too: this is a DROP shadow from directly
            // above, not a shadow map from the key light, and its softness does not grow
            // with height above the floor — a part held 100 mm up casts the same edge as
            // one resting on it. For grounding the part, which is what §3c asks for, that
            // is the whole of what is needed; for a light-accurate shadow it is not.
            if (U.shadowStrength > 0.001 && U.shadowRect.z > 0.0 && U.shadowRect.w > 0.0) {
                float2 suv = (xz - U.shadowRect.xy) / U.shadowRect.zw;
                if (all(suv > 0.0) && all(suv < 1.0)) {
                    constexpr sampler shSmp(filter::linear, address::clamp_to_edge);
                    float2 texel = 1.0 / float2(shadowTex.get_width(), shadowTex.get_height());
                    float occ = 0.0;
                    for (int dy = -1; dy <= 1; ++dy) {
                        for (int dx = -1; dx <= 1; ++dx) {
                            occ += shadowTex.sample(shSmp, suv + float2(dx, dy) * texel).r;
                        }
                    }
                    occ /= 9.0;
                    // Fade the shadow out toward the edge of its own rectangle so the
                    // footprint's border can never read as a hard square on the floor.
                    float2 e = min(suv, 1.0 - suv);
                    float border = smoothstep(0.0, 0.06, min(e.x, e.y));
                    col *= 1.0 - clamp(occ * U.shadowStrength * border * graze, 0.0, 0.85);
                }
            }
        }
    }

    return float4(col, 1.0);   // opaque backdrop (replaces the flat clear)
}
"""

/// The sentinel face id written to the id target's background (no face under the
/// pixel). Face ids are non-negative, so `UInt32.max` never collides.
private let idBackground: UInt32 = .max

/// A lightweight signature so the representable re-uploads/re-frames only when a
/// genuinely different mesh arrives (ViewerMesh is a big value type).
///
/// This USED to be `(vertexCount, triangleCount, bounds)`, and that is the bug
/// task 2026-08-04-smoothing-viewer-and-ui was opened on: a smoothed mesh has the
/// same counts and — unless the brush happened to reach the part's outermost
/// corner — the same bounding box, so the upload was skipped and the viewer went
/// on drawing the unsmoothed shape. `ViewerMesh.signature` reads the mesh's own
/// contents and is computed once at construction, so this stays a scalar compare.
private func meshSignature(_ mesh: ViewerMesh) -> ViewerMeshSignature {
    mesh.signature
}

// ---------------------------------------------------------------------------
// The MTKView delegate: owns the pipelines, the mesh buffers and the camera.
final class MeshRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let idPipeline: MTLRenderPipelineState?

    private var vertexBuffer: MTLBuffer?
    private var tintBuffer: MTLBuffer?
    private var idVertexBuffer: MTLBuffer?
    /// M7.viz.3 flex: per-flat-vertex displacement (packed float3, mm). Always bound
    /// at buffer(3) — zero-filled on `setMesh`, so the static draw adds nothing.
    private var flexBuffer: MTLBuffer?
    /// The current displacement scale (exaggeration·amplitude); 0 = rest.
    private var flexScale: Float = 0
    /// M7.viz.4 load-path: line segments (pos+rgba, stride 7) tracing the dominant
    /// principal-stress direction. Kept as the FALLBACK draw (1px lines) for when the
    /// thick-ribbon pipeline is unavailable. Empty = off.
    private var loadPathBuffer: MTLBuffer?
    private var loadPathVertexCount = 0
    /// ★ §6(b) — THE SURFACE STAGE'S B-REP WIREFRAME. A stride-7 (pos + rgba)
    /// line list built by `SurfaceWireframe.edges(of:)` and drawn on the ground
    /// pipeline, like every other line layer here. Empty on every other stage.
    private var wireframeBuffer: MTLBuffer?
    private var wideLinePipeline: MTLRenderPipelineState?
    private var wideWireBuffer: MTLBuffer?
    private var wideWireVertexCount = 0
    private var ribbonBuffer: MTLBuffer?
    private var ribbonVertexCount = 0
    /// §6 — the per-vertex tint that overrides the per-face one while it is set.
    private var vertexTintOverride: [Float]?
    /// §6 — draw the line set through the solid (x-ray) rather than depth-tested.
    var xrayLines = false
    private var cutUniforms = CutUniformsSwift(plane: .zero, colSelected: .zero,
                                               colSibling: .zero, enabled: 0)
    private var wireframeVertexCount = 0
    /// M7.viz.4 load-path: the expanded THICK-RIBBON geometry (stride-12: segStart xyz,
    /// segEnd xyz, side, endFlag, rgba — 6 verts per glyph). Drawn by `loadPathPipeline`
    /// when it built; billboarded to a constant screen width in the vertex shader.
    private var loadPathRibbonBuffer: MTLBuffer?
    private var loadPathRibbonVertexCount = 0
    /// M7.viz.4 load-path: the flow-animation phase in [0, 1) — scrolls the bright dash
    /// along each ribbon. 0 = static (reduced-motion holds it here).
    private var loadPathFlow: Float = 0
    /// Load-path FLOW (handoff 070): the comet-arrow tube geometry (pos+rgba, stride 7),
    /// rebuilt each animation frame from the model's `CometFrame`s and drawn ADDITIVE so
    /// the arrows glow through the x-ray body. Empty = off.
    private var loadFlowBuffer: MTLBuffer?
    private var loadFlowVertexCount = 0
    /// Load-path FLOW: the faint full-path guide lines (pos+rgba, stride 7, `.line`).
    private var flowGuideBuffer: MTLBuffer?
    private var flowGuideVertexCount = 0
    /// Body opacity for the load-flow body modes: 1 opaque (solid, default), < 1 draws
    /// the mesh translucent so the flow shows through the walls (x-ray / stress).
    private var bodyAlpha: Float = 1
    private var vertexDrawCount = 0
    /// M7.8 reveal scrub params (fraction, minY, maxY, enabled); default shows all.
    private var revealParams = SIMD4<Float>(1, 0, 1, 0)
    /// Per-flat-vertex face ids (a triangle's id repeated 3×), for the tint buffer.
    private var flatFaceIDs: [UInt32] = []
    private var aspect: Float = 1

    /// The mesh currently uploaded (kept for the CPU-pick fallback).
    private(set) var mesh: ViewerMesh?

    /// The camera the gestures drive. Mutated on the main thread; the draw reads it.
    var camera = OrbitCamera()

    // MARK: settle (M7.6 D2) — a rotation about the model centre so gravity points
    // at world −Y, optionally animated. Rotation about the centre keeps the camera
    // target (the centre) fixed, so framing is unaffected.
    private let groundPipeline: MTLRenderPipelineState?
    private let groundDepthState: MTLDepthStencilState
    /// Depth state for the load-path overlay: test ALWAYS (never occluded), write
    /// nothing. The glyphs sit at voxel centres INSIDE the solid part, so a normal
    /// depth test (`.less` against the opaque mesh) hides every one of them behind the
    /// front surface — the "Load path shows nothing" bug. Drawing them depth-always
    /// overlays the load-path trajectories on top of the part (an x-ray hedgehog),
    /// which is exactly the intent: see how force travels through the structure.
    private let lineOverlayDepthState: MTLDepthStencilState
    /// The thick-ribbon load-path pipeline (M7.viz.4). Optional: if it fails to build,
    /// the load path degrades to the 1px `groundPipeline` line draw.
    private let loadPathPipeline: MTLRenderPipelineState?
    /// Load-path FLOW (handoff 070): an ADDITIVE-blended pipeline (reuses the ground
    /// pos+rgba shaders) for the glowing comet tubes + guide lines. Optional.
    private let cometPipeline: MTLRenderPipelineState?
    /// Load-path FLOW: a translucent copy of the main viewer pipeline (premultiplied
    /// "over" blending) for the semi-transparent x-ray/stress body. Optional — a nil
    /// falls back to the opaque draw (no see-through, but everything still renders).
    private let translucentBodyPipeline: MTLRenderPipelineState?
    /// Depth state for the translucent body: test `.less` but DO NOT write depth, so
    /// back walls show through the front (the x-ray read).
    private let translucentBodyDepthState: MTLDepthStencilState
    /// The CAD-stage backdrop pipeline (item 9): a full-screen gradient + infinite floor grid,
    /// drawn FIRST with `lineOverlayDepthState` (depth-always, no write) so everything occludes
    /// it. Optional — a nil just falls back to the flat clear colour.
    private let stagePipeline: MTLRenderPipelineState?
    /// Whether the CAD-stage backdrop pipeline built (its MSL compiled). A test asserts this is
    /// true on a real GPU so a shader typo fails loudly instead of silently disabling the stage.
    var stagePipelineDidBuild: Bool { stagePipeline != nil }
    /// The DEPTH PREPASS pipeline (items 7+8, parts b+c): writes the opaque part's eye-space depth
    /// into an R32Float texture the contact pass reads. Optional — a nil disables the contact
    /// treatment (the faces fall back to the plain `groundPipeline` draw, part-a depth-bias only).
    private let depthPrepassPipeline: MTLRenderPipelineState?
    /// The CONTACT pipeline (items 7+8, parts b+c): the one shader variant BOTH the design-box and
    /// clearance face draws use to add the contact line + interior occlusion. Optional (same fallback).
    private let contactPipeline: MTLRenderPipelineState?
    /// True on a real GPU when both round-3 contact pipelines built — a test pins this so a shader
    /// typo (built with `try?`) fails loudly instead of silently reverting to the plain draw.
    var contactPipelinesDidBuild: Bool { depthPrepassPipeline != nil && contactPipeline != nil }
    /// The exact contact/prepass MSL the app ships, exposed so a headless test can compile it and
    /// fail loudly on a typo.
    static var depthPrepassShaderSourceForTesting: String { depthPrepassShaderSource }
    static var contactShaderSourceForTesting: String { contactShaderSource }
    /// The exact main viewer MSL the app ships (incl. the handoff-124 Face-protection
    /// crosshatch in `viewer_fragment`), exposed so a headless test compiles it and
    /// fails loudly on a typo — the pipeline is otherwise built with `try?` and a
    /// malformed shader silently blanks the whole stage.
    static var viewerShaderSourceForTesting: String { viewerShaderSource }
    /// Reused offscreen textures for the depth prepass (colour = eye-Z, plus its own z-buffer),
    /// re-created only when the drawable size changes — so a steady camera reuses them.
    private var sceneDepthColorTex: MTLTexture?
    private var sceneDepthZTex: MTLTexture?

    // ── RENDER QUALITY (task 2026-08-15-render-quality) ───────────────────────────
    /// The G-buffer's eye-space NORMAL attachment (§1/§3a), sized with the depth pair.
    private var sceneNormalTex: MTLTexture?
    /// The SSAO+edge target (RG: openness, edge) and the blur's destination. Two
    /// textures, ping-ponged: a fragment shader may not read the attachment it writes.
    private var aoRawTex: MTLTexture?
    private var aoBlurTex: MTLTexture?
    /// A 1×1 "fully open, no edge" texture. The body fragment DECLARES the AO texture,
    /// so something must always be bound — Metal drops the draw otherwise (the same
    /// missing-binding trap `loadpath_fragment` and `contact_fragment` document). This
    /// is what it gets when AO is off, and it makes that path an exact identity.
    private var aoNeutralTex: MTLTexture?
    /// The SSAO pass (§1) and its depth-aware blur. Optional: a nil disables AO and
    /// edges and the body falls back to the neutral texture — everything still renders.
    private let aoPipeline: MTLRenderPipelineState?
    private let aoBlurPipeline: MTLRenderPipelineState?
    /// True on a real GPU when both AO pipelines built. A test pins this so a shader
    /// typo fails loudly instead of silently reverting to the flat-grey look.
    var aoPipelinesDidBuild: Bool { aoPipeline != nil && aoBlurPipeline != nil }

    // ── UNIFIED SHADING (task 2026-08-18-unified-shading) ─────────────────────────
    /// The lattice's G-buffer write and its deferred shade. Optional for the same
    /// reason every other pipeline here is: a nil means no lattice in the frame, not a
    /// broken frame.
    private let latticeGBufferPipeline: MTLRenderPipelineState?
    private let latticeShadePipeline: MTLRenderPipelineState?
    /// True on a real GPU when both unified lattice pipelines built. Pinned by a test
    /// — a typo in that MSL would silently take the lattice out of the frame entirely,
    /// and "the preview stopped appearing" is a worse failure than a red build.
    var latticePipelinesDidBuild: Bool {
        latticeGBufferPipeline != nil && latticeShadePipeline != nil
    }
    /// The exact unified-lattice MSL the app ships, exposed so a headless test
    /// compiles it (the pipelines above are built with `try?`).
    static var latticeShaderSourceForTesting: String { unifiedLatticeShaderSource }

    /// The lattice layer drawn INSIDE this renderer's passes: a bake-only
    /// `LatticeSDFRenderer` that owns the per-cell field, the part SDF, the tint volume
    /// and the segment soup. Nil = no lattice in the frame, and then every pass below is
    /// byte-for-byte what it was before this task.
    private var latticeLayer: LatticeSDFRenderer?
    /// The scene token last uploaded, so a bake happens once per scene change and never
    /// per frame (the preview's bar P2, carried over unchanged).
    private var latticeSceneToken: Int = -1
    private var latticeAppliedTints: [FaceID: SIMD4<Float>]? = nil
    /// The G-buffer's third attachment (the lattice albedo + mask), sized with the pair.
    private var gbufferAlbedoTex: MTLTexture?

    /// ★ THE G-BUFFER IS RESOLUTION-CAPPED WHEN A LATTICE IS IN IT, AND THAT IS THE
    /// WHOLE COST STORY OF THIS TASK.
    ///
    /// The raymarch is FILL-BOUND — `LatticeSDFProfileTests` measures 12.5 ms for one
    /// 1024² frame of his bracket on an M2 Pro — so marching at an iPad's full drawable
    /// (~5.6 Mpx) would cost tens of milliseconds and no amount of pass unification
    /// would pay for it. The standalone preview handled this by capping its own drawable
    /// at 1152 px on the long side and letting the compositor upscale (its bar P3), and
    /// the unified pass inherits exactly that trade: the G-buffer — hence the march, the
    /// AO and the edge detector — is capped at the SAME 1152, and the deferred shade
    /// reads it with a nearest tap. So the march costs what it costs today, while the
    /// LIGHTING, the occlusion, the creases and the depth fade are the shell's own.
    ///
    /// It applies ONLY when a lattice layer is present. Without one the G-buffer is the
    /// full colour target, exactly as `render-quality` shipped it.
    static let latticeGBufferMaxPixels = 1152
    /// The GPU this renderer is on. Exposed so a skipped frame-budget assertion can
    /// NAME the device it declined to hold — a skip that does not say which machine it
    /// let off is indistinguishable from a budget nobody checks.
    var deviceName: String { device.name }
    /// True on a real GPU when the §3c footprint pipeline built — same reason.
    var shadowPipelineDidBuild: Bool { shadowPipeline != nil }
    /// The exact §3c footprint MSL the app ships.
    static var shadowShaderSourceForTesting: String { shadowShaderSource }
    /// The exact SSAO MSL the app ships, exposed so a headless test compiles it.
    static var aoShaderSourceForTesting: String { aoShaderSource }

    /// How much of the render-quality work runs. Every member defaults ON in
    /// production; the evidence generator turns them off ONE AT A TIME to capture a
    /// before/after pair per item through the SHIPPING shader (§ R1) rather than a
    /// second copy of it.
    struct Quality: OptionSet, Sendable {
        let rawValue: Int
        /// §1 — screen-space ambient occlusion.
        static let ambientOcclusion = Quality(rawValue: 1 << 0)
        /// §2 — the world-space key/fill/rim rig (off ⇒ the original headlight).
        static let worldLighting    = Quality(rawValue: 1 << 1)
        /// §3a — screen-space silhouette + crease lines.
        static let edges            = Quality(rawValue: 1 << 2)
        /// §3c — the soft contact shadow under the part on the stage floor.
        static let contactShadow    = Quality(rawValue: 1 << 3)
        /// §3d — the far side of dense geometry recedes.
        static let depthFade        = Quality(rawValue: 1 << 4)
        static let none: Quality = []
        static let all: Quality = [.ambientOcclusion, .worldLighting, .edges,
                                   .contactShadow, .depthFade]
    }
    /// Production is `.all`. Set to `.none` for the "before" capture.
    var quality: Quality = .all

    /// SSAO sample count. §1(b) asks for the cost at a LOW and a HIGH setting rather
    /// than one picked silently, so both are named here and both are measured in the
    /// evidence. `high` is production.
    enum AOQuality: Int, Sendable { case low = 8, high = 16 }
    var aoQuality: AOQuality = .high

    /// ★ SSAO RADIUS — SWEPT ON HIS OWN CONTENT (§1a, R3), AND THE SWEEP REFUTED THE
    /// REASON I CHANGED THE RULE.
    ///
    /// The hypothesis was that a fraction of the LARGEST bounding-box side mis-scales an
    /// elongated part: his bracket's largest side is the 200 mm arm while the geometry
    /// that can occlude itself is an order of magnitude smaller, so AO reached only 15%
    /// of its pixels. `testAORadiusSweepOnHisContent` swept the radius across all three
    /// of his parts and the story did not hold up. What governs coverage is the ABSOLUTE
    /// radius, and both rules land in the same place on his parts:
    ///
    ///     radius (mm)   lattice   bracket   TO result      ← % of the PART's pixels
    ///        0.6 / 1.2 / 1.6       51.3%      3.7%    5.7%    whose shading AO moves
    ///        1.3 / 2.4 / 3.1       64.3%      4.7%    8.8%
    ///        3.8 / 7.2 / 9.4       54.5%     10.1%   20.6%
    ///        5.3 / 10.0 / 13.0     49.2%     13.6%   25.4%
    ///        7.4 / 14.0 / 18.2     41.1%     17.6%   28.7%
    ///
    /// ★ AND HIS BRACKET'S LOW NUMBER IS NOT A TUNING FAILURE — IT IS THE PART. A
    /// flat plate seen face-on has almost nothing to occlude itself with; AO darkens
    /// where geometry crowds itself, and on that bracket most of the visible area is
    /// open plate. No radius fixes that, and the sweep shows it: coverage climbs
    /// monotonically to 17.6% at a 14 mm radius and never approaches the lattice's.
    /// The two cases §1 actually names — the lattice and the TO result — are at 49%
    /// and 25% at the shipped setting, and those are the pictures that change.
    ///
    /// The rule stays a fraction of the SMALLEST bounding-box side, not because the
    /// sweep preferred it (it did not distinguish them) but because it degrades more
    /// gracefully on a part his three do not cover: a long thin rod, where a fraction of
    /// the 500 mm length would throw the kernel a hundred times past every feature.
    static let aoRadiusFraction: Float = 0.50
    /// A per-renderer override in world mm, for that sweep. Nil in production — the
    /// rule above decides.
    var aoRadiusOverrideMM: Float?
    /// SSAO strength on the ambient term. Above ~1.5 the crevices crush to black.
    static let aoIntensity: Float = 1.15
    /// How much of the AO reaches the body — the body shader's `sp.ao.x`.
    static let aoStrength: Float = 0.90
    /// Edge darkening (§3a). Subtle: the line multiplies the pixel by 0.30 at full
    /// strength, and this scales that.
    static let edgeStrength: Float = 0.55
    /// Edge thresholds: depth jump RELATIVE to eye-Z, and the normal dot below which a
    /// crease starts to read (cos 35° ≈ 0.82).
    static let edgeDepthThreshold: Float = 0.0035
    static let edgeNormalThreshold: Float = 0.82
    /// §3d depth fade. Capped WELL below opaque on purpose — at the far plane the
    /// material is still 55% itself, so this can never hide a region the user needs.
    static let depthFadeStrength: Float = 0.45
    /// Where the fade starts, as a fraction of the part's eye-space depth span. The
    /// near HALF of the part is untouched; only the far half recedes.
    static let depthFadeStart: Float = 0.45

    /// MSAA sample count for the on-screen and offscreen colour passes (§3b). 4× is
    /// the Apple-GPU sweet spot (tile-memory resolve, no extra bandwidth off-chip).
    /// An INIT parameter, not a static, because the pipelines bake it — so the
    /// evidence generator builds one renderer at 1× and one at 4× and captures both.
    let sampleCount: Int
    /// The MSAA colour target (nil at 1×), re-created on a size change.
    private var msaaColorTex: MTLTexture?

    /// §3c: the part's floor footprint and the pipeline that draws it. Optional — a
    /// nil just means no contact shadow; the stage still draws.
    private let shadowPipeline: MTLRenderPipelineState?
    private var shadowTex: MTLTexture?
    /// A 1×1 zero texture — bound to the stage draw whenever there is no shadow, for
    /// the same missing-binding reason `aoNeutralTex` exists.
    private var shadowNeutralTex: MTLTexture?
    /// What the cached footprint was rendered FOR. The shadow is re-rendered only when
    /// this changes — a camera orbit does not move a drop shadow, so it must not
    /// re-render one (the 108 rule).
    private var shadowKey: ShadowKey?
    private struct ShadowKey: Equatable {
        let mesh: ViewerMeshSignature?
        let rotation: SIMD4<Float>
        let rect: SIMD4<Float>
        let flex: Float
    }
    /// The world-XZ rectangle the footprint covers, and its strength. Nil until a
    /// footprint has been rendered this frame.
    private var shadowRect: SIMD4<Float> = .zero
    /// The footprint target's resolution. Low ON PURPOSE: the texel size IS the blur
    /// radius of the 3×3 tap in `stage_fragment`, so a bigger target would give a
    /// HARDER shadow, not a better one.
    static let shadowResolution = 192
    /// §3c strength — how dark the floor goes directly under the part.
    static let contactShadowStrength: Float = 0.55

    // ── §4 REGION STATE COLOURS ───────────────────────────────────────────────────
    /// How much saturation comes off a STATE tint on its way to being geometry, and
    /// how far the result is lifted back toward clay's brightness. Tuned on the
    /// all-states capture in evidence/2026-08-15-render-quality (R7), AFTER §1 and §2
    /// landed — which is the order §4 demands, because how little saturation still
    /// reads is a question you cannot answer under flat shading.
    /// §4: the two VOLUME colours, named here rather than written as literals at the
    /// call site — so the all-states capture (R7) shows the shipping colours and cannot
    /// drift from them. They are NOT desaturated with the state tints, and the reason
    /// is in the capture's own printout: these are unlit translucent glass, drawn
    /// through `ground_fragment`/`contact_fragment`, so §4's premise ("with real
    /// shading, less saturation still reads") is simply not true of them. Keep-out red
    /// is additionally the app's one "forbidden" signal.
    static let designBoxColor = SIMD4<Float>(0.30, 0.78, 0.55, 0.85)
    static let keepOutColor = SIMD4<Float>(0.95, 0.42, 0.38, 0.9)
    static let stateTintDesaturation: Float = 0.50
    static let stateTintBrightnessLift: Float = 0.55
    /// ★ WHY THIS IS IN THE RENDERER AND NOT IN THE COLOUR TOKENS. §4(c): geometry
    /// tints only — no button, no chip, no legend swatch. `LatticeDensityProxy
    /// .densityColor`, `DS.Color.groupPalette` and `ForceModel.anchorColor` are all
    /// read by SwiftUI chips and legends as well as by the mesh, so editing any of them
    /// would change controls this task must not touch. Desaturating HERE — at the one
    /// point in the app where a colour becomes a triangle's albedo — reaches every
    /// state tint and reaches nothing else.
    ///
    /// ★ AND WHY IT IS SCOPED TO *STATE* TINTS. A continuous DATA ramp (the stress
    /// heatmap, the density field) encodes a measured value in its hue and is read
    /// against a printed legend. Desaturating that would not make it subtler, it would
    /// make it WRONG — and the legend beside it would no longer be the scale on the
    /// part. `tintsAreState` is set by whichever setter last filled the tint buffer, so
    /// the distinction is made where it is actually known.
    private var tintsAreState = false
    /// Whether the contact treatment (parts b+c) runs. Always true in production; a test flips it
    /// off to capture the BEFORE (plain depth-biased faces) against the AFTER for the same geometry.
    var contactShadingEnabled = true
    /// The exact stage MSL the app ships — exposed so a headless test can compile it and fail
    /// loudly on a typo (the pipeline is otherwise built with `try?`, i.e. nil-on-failure).
    static var stageShaderSourceForTesting: String { stageShaderSource }
    private var modelCenter = SIMD3<Float>.zero
    /// The model transform the pick must undo to reach model space — the SAME
    /// centre and rotation `modelMatrix()` draws with, so a ray cannot disagree
    /// with the geometry it is aimed at.
    var pickModelFrame: (centre: SIMD3<Float>, rotation: simd_quatf) {
        (modelCenter, modelRotation)
    }
    /// The currently-displayed model rotation (animates toward `settleTo`).
    private var modelRotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    private var settleFrom = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    private var settleTo = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    private var settleStart: CFTimeInterval = 0
    private var settleDuration: CFTimeInterval = 0
    /// True while the settle animation is running (drives continuous redraw).
    private(set) var isSettling = false
    /// How many times a settle has been STARTED. `isSettling` cannot answer the
    /// question a mesh swap raises, because the animation is advanced by `draw` —
    /// so a headless test that never draws sees it stuck true and learns nothing.
    /// This counts the restarts instead, which is the claim: a brush stroke must
    /// not re-run the settle (task 2026-08-08, S1a).
    private(set) var settleBeginCount = 0

    // Detent face-highlight PULSE (device round 3, item 2): a brief gold flash of the part face a
    // design-box drag just snapped to — the in-viewer replacement for the old "Snapped to face"
    // toast. Reuses the per-face tint buffer (no new pass): the pulsed face's tint animates a
    // sin-envelope alpha up then back down over `pulseDuration`, layered over the last-applied
    // highlight tints. Like the settle, it drives continuous redraw only WHILE active, then returns
    // to on-demand — a bounded, user-triggered animation, not an idle loop (the 108 rule).
    private var pulseFaceID: FaceID?
    private var pulseStart: CFTimeInterval = 0
    private let pulseDuration: CFTimeInterval = 0.42
    /// The last highlight tints applied (so a pulse can layer over them without the SwiftUI side
    /// re-pushing every frame).
    private var lastFaceTint: [FaceID: SIMD4<Float>] = [:]
    private var lastActiveFaces: Set<FaceID> = []
    /// True while a detent pulse is animating (drives continuous redraw, like `isSettling`).
    private(set) var isPulsing = false

    /// Whether to draw the ground grid + contact shadow (set once gravity is set).
    var showGround = false
    private var groundLineBuffer: MTLBuffer?
    private var groundLineCount = 0
    private var groundShadowBuffer: MTLBuffer?
    private var groundShadowCount = 0

    // M7.dom-app design-box gizmo: translucent box faces + bright edges for the
    // design box (grow room) and any keep-out boxes, in MODEL space so they settle
    // with the part. Reuses the alpha-blended `groundPipeline` (position + rgba,
    // stride 7) under the MESH's mvp. Empty until `setDesignBoxes` uploads geometry.
    private var designBoxFaceBuffer: MTLBuffer?
    private var designBoxFaceCount = 0
    private var designBoxLineBuffer: MTLBuffer?
    private var designBoxLineCount = 0

    // Keep-clear v2 (Part 3): the TRUE clearance volumes — swept cylinders (bolt) and
    // bounded slabs (face) — as translucent red faces + bright edges, in MODEL space so
    // they settle with the part. Same alpha-blended `groundPipeline` (position + rgba,
    // stride 7) under the MESH's mvp as the design box. A degenerate (no-op) region
    // draws edges only (hollow) — the picture must not promise what the run won't do.
    private var clearanceXrayBuffer: MTLBuffer?
    private var clearanceXrayCount = 0
    private var clearanceFaceBuffer: MTLBuffer?
    private var clearanceFaceCount = 0
    private var clearanceLineBuffer: MTLBuffer?
    private var clearanceLineCount = 0

    static let colorFormat: MTLPixelFormat = .bgra8Unorm
    static let depthFormat: MTLPixelFormat = .depth32Float
    static let idFormat: MTLPixelFormat = .r32Uint
    /// The depth-prepass colour target (items 7+8, parts b+c): one float per pixel = the opaque
    /// part's eye-space depth, read by the contact fragment.
    static let sceneDepthFormat: MTLPixelFormat = .r32Float
    /// The G-buffer's second attachment: the eye-space normal (render quality §1/§3a).
    static let gbufferNormalFormat: MTLPixelFormat = .rgba16Float
    /// The G-buffer's THIRD attachment (unified shading): the lattice's albedo, with
    /// alpha as the "this pixel is lattice" mask. 8 bits per channel — it is an albedo
    /// that will be multiplied by a shade, not a value anything measures.
    static let gbufferAlbedoFormat: MTLPixelFormat = .rgba8Unorm
    /// The SSAO+edge target: R = openness, G = edge. 8 bits each is plenty for a term
    /// that is blurred and then multiplied into a shade — and it is a quarter of the
    /// bandwidth of a float target read once per body fragment.
    static let aoFormat: MTLPixelFormat = .rg8Unorm
    /// The §3c footprint target: one coverage byte per floor texel.
    static let shadowFormat: MTLPixelFormat = .r8Unorm
    /// The eye-space depth written where NO part covers a pixel — large enough that the contact
    /// read sees "nothing behind" (no line, full brightness) for a volume floating in free space.
    static let sceneDepthFar: Float = 1e30
    /// Depth-bias (polygon offset) for the translucent design-box + clearance FACE passes, so they
    /// don't z-fight (shimmer) with the part surface where the volumes graze/coincide with it
    /// (device round 3, items 7+8, part a — the shimmer). Pulls the translucent fragments a hair
    /// toward the camera so a near-tie resolves cleanly in their favour instead of flickering
    /// per-pixel. Static render state applied only to those draws — no per-frame CPU work (108).
    static let translucentDepthBias: Float = -3.0
    static let translucentDepthSlopeBias: Float = -1.5
    /// Half-width of a load-path ribbon in NDC-y units (the vertex shader billboards to
    /// this constant screen thickness). ~0.006 ≈ a few pixels — legible without hiding
    /// the part underneath.
    static let loadPathHalfWidth: Float = 0.006

    static var lastInitError: String?

    /// - Parameter sampleCount: MSAA samples for the colour passes (§3b). 4 in
    ///   production; the evidence generator passes 1 to capture the aliased "before".
    init?(device: MTLDevice, sampleCount: Int = 4) {
        let msaa = max(1, sampleCount)
        // A device that cannot do the asked-for sample count silently falls back to
        // 1× rather than failing to build — the picture is then aliased, not absent.
        let raster = device.supportsTextureSampleCount(msaa) ? msaa : 1
        guard let queue = device.makeCommandQueue() else {
            Self.lastInitError = "makeCommandQueue nil"; return nil
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: viewerShaderSource, options: nil)
        } catch {
            Self.lastInitError = "makeLibrary: \(error)"; return nil
        }
        guard let vfn = library.makeFunction(name: "viewer_vertex"),
              let ffn = library.makeFunction(name: "viewer_fragment") else {
            Self.lastInitError = "makeFunction nil"; return nil
        }

        // Main pipeline vertex layout: position+normal in buffer 0 (stride 24),
        // selection tint in buffer 2 (stride 16).
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3          // position
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3          // normal
        vd.attributes[1].offset = MemoryLayout<Float>.stride * 3
        vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float4          // selection tint (rgba)
        vd.attributes[2].offset = 0
        vd.attributes[2].bufferIndex = 2
        // ★ §6 — the per-vertex FLAGS ride in the same buffer: .x marks a face of
        // the selected region, the fragments the cut's half-space test applies to.
        vd.attributes[3].format = .float4
        vd.attributes[3].offset = MemoryLayout<Float>.stride * 4
        vd.attributes[3].bufferIndex = 2
        vd.layouts[0].stride = MemoryLayout<Float>.stride * 6
        vd.layouts[2].stride = MemoryLayout<Float>.stride * 8

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = Self.colorFormat
        pd.depthAttachmentPixelFormat = Self.depthFormat
        pd.rasterSampleCount = raster            // §3b MSAA

        let dsd = MTLDepthStencilDescriptor()
        dsd.depthCompareFunction = .less
        dsd.isDepthWriteEnabled = true

        let pipe: MTLRenderPipelineState
        do {
            pipe = try device.makeRenderPipelineState(descriptor: pd)
        } catch {
            Self.lastInitError = "makeRenderPipelineState: \(error)"; return nil
        }
        guard let depth = device.makeDepthStencilState(descriptor: dsd) else {
            Self.lastInitError = "makeDepthStencilState nil"; return nil
        }

        // Id pass pipeline (optional: if it fails, picking falls back to the CPU).
        var idPipe: MTLRenderPipelineState? = nil
        if let idLib = try? device.makeLibrary(source: idShaderSource, options: nil),
           let ivf = idLib.makeFunction(name: "id_vertex"),
           let iff = idLib.makeFunction(name: "id_fragment") {
            let ivd = MTLVertexDescriptor()
            ivd.attributes[0].format = .float3     // position
            ivd.attributes[0].offset = 0
            ivd.attributes[0].bufferIndex = 0
            ivd.attributes[1].format = .uint       // face id
            ivd.attributes[1].offset = MemoryLayout<Float>.stride * 3
            ivd.attributes[1].bufferIndex = 0
            ivd.layouts[0].stride = MemoryLayout<UInt32>.stride * 4
            let ipd = MTLRenderPipelineDescriptor()
            ipd.vertexFunction = ivf
            ipd.fragmentFunction = iff
            ipd.vertexDescriptor = ivd
            ipd.colorAttachments[0].pixelFormat = Self.idFormat
            ipd.depthAttachmentPixelFormat = Self.depthFormat
            idPipe = try? device.makeRenderPipelineState(descriptor: ipd)
        }

        // Ground pass pipeline (optional: if it fails, the settle still works, just
        // without the grid/shadow). Alpha-blended, position + rgba per vertex.
        var groundPipe: MTLRenderPipelineState? = nil
        if let gLib = try? device.makeLibrary(source: groundShaderSource, options: nil),
           let gvf = gLib.makeFunction(name: "ground_vertex"),
           let gff = gLib.makeFunction(name: "ground_fragment") {
            let gvd = MTLVertexDescriptor()
            gvd.attributes[0].format = .float3     // position
            gvd.attributes[0].offset = 0
            gvd.attributes[0].bufferIndex = 0
            gvd.attributes[1].format = .float4     // rgba
            gvd.attributes[1].offset = MemoryLayout<Float>.stride * 3
            gvd.attributes[1].bufferIndex = 0
            gvd.layouts[0].stride = MemoryLayout<Float>.stride * 7
            let gpd = MTLRenderPipelineDescriptor()
            gpd.vertexFunction = gvf
            gpd.fragmentFunction = gff
            gpd.vertexDescriptor = gvd
            gpd.colorAttachments[0].pixelFormat = Self.colorFormat
            gpd.colorAttachments[0].isBlendingEnabled = true          // premultiplied alpha
            gpd.colorAttachments[0].rgbBlendOperation = .add
            gpd.colorAttachments[0].alphaBlendOperation = .add
            gpd.colorAttachments[0].sourceRGBBlendFactor = .one
            gpd.colorAttachments[0].sourceAlphaBlendFactor = .one
            gpd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            gpd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            gpd.depthAttachmentPixelFormat = Self.depthFormat
            gpd.rasterSampleCount = raster       // §3b MSAA
            groundPipe = try? device.makeRenderPipelineState(descriptor: gpd)

            // ★ THE WIDE-LINE PIPELINE (§6b). Same library, same blending as the ground
            // lines; the difference is entirely in the vertex stage, which expands each
            // segment into a screen-space quad.
            if let wvf = gLib.makeFunction(name: "wideline_vertex"),
               let wff = gLib.makeFunction(name: "wideline_fragment") {
                let wd = MTLRenderPipelineDescriptor()
                wd.vertexFunction = wvf
                wd.fragmentFunction = wff
                wd.colorAttachments[0].pixelFormat = Self.colorFormat
                wd.colorAttachments[0].isBlendingEnabled = true
                wd.colorAttachments[0].rgbBlendOperation = .add
                wd.colorAttachments[0].alphaBlendOperation = .add
                wd.colorAttachments[0].sourceRGBBlendFactor = .one
                wd.colorAttachments[0].sourceAlphaBlendFactor = .one
                wd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                wd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                wd.depthAttachmentPixelFormat = Self.depthFormat

                let wvd = MTLVertexDescriptor()
                wvd.attributes[0].format = .float3            // a
                wvd.attributes[0].offset = 0
                wvd.attributes[0].bufferIndex = 0
                wvd.attributes[1].format = .float3            // b
                wvd.attributes[1].offset = MemoryLayout<Float>.stride * 3
                wvd.attributes[1].bufferIndex = 0
                wvd.attributes[2].format = .float4            // rgba
                wvd.attributes[2].offset = MemoryLayout<Float>.stride * 6
                wvd.attributes[2].bufferIndex = 0
                wvd.attributes[3].format = .float2            // side
                wvd.attributes[3].offset = MemoryLayout<Float>.stride * 10
                wvd.attributes[3].bufferIndex = 0
                wvd.layouts[0].stride = MemoryLayout<Float>.stride * 12
                wd.vertexDescriptor = wvd
                wideLinePipeline = try? device.makeRenderPipelineState(descriptor: wd)
            }
        }

        // CAD-stage backdrop pipeline (item 9, optional: nil → the flat clear colour). No vertex
        // buffer (the gl_VertexID full-screen triangle); opaque (it REPLACES the clear), no
        // depth involvement (drawn first, `lineOverlayDepthState`).
        var stagePipe: MTLRenderPipelineState? = nil
        if let sLib = try? device.makeLibrary(source: stageShaderSource, options: nil),
           let svf = sLib.makeFunction(name: "stage_vertex"),
           let sff = sLib.makeFunction(name: "stage_fragment") {
            let spd = MTLRenderPipelineDescriptor()
            spd.vertexFunction = svf
            spd.fragmentFunction = sff
            spd.colorAttachments[0].pixelFormat = Self.colorFormat
            spd.depthAttachmentPixelFormat = Self.depthFormat
            spd.rasterSampleCount = raster       // §3b MSAA
            stagePipe = try? device.makeRenderPipelineState(descriptor: spd)
        }
        // Depth-prepass pipeline (items 7+8, parts b+c): the opaque part → eye-space depth in an
        // R32Float target, so the contact pass can read the part's depth per pixel. Vertex layout:
        // just the position (attribute 0) from the mesh's stride-24 pos+normal buffer, plus the
        // flex displacement at buffer 3 (so the captured depth matches the visible flexed part).
        var depthPrepassPipe: MTLRenderPipelineState? = nil
        if let dLib = try? device.makeLibrary(source: depthPrepassShaderSource, options: nil),
           let dvf = dLib.makeFunction(name: "depth_vertex"),
           let dff = dLib.makeFunction(name: "depth_fragment") {
            let dvd = MTLVertexDescriptor()
            dvd.attributes[0].format = .float3     // position
            dvd.attributes[0].offset = 0
            dvd.attributes[0].bufferIndex = 0
            dvd.attributes[1].format = .float3     // normal — the G-buffer's second output
            dvd.attributes[1].offset = MemoryLayout<Float>.stride * 3
            dvd.attributes[1].bufferIndex = 0
            dvd.layouts[0].stride = MemoryLayout<Float>.stride * 6   // pos+normal
            let dpd = MTLRenderPipelineDescriptor()
            dpd.vertexFunction = dvf
            dpd.fragmentFunction = dff
            dpd.vertexDescriptor = dvd
            dpd.colorAttachments[0].pixelFormat = Self.sceneDepthFormat        // R32Float eye-Z
            dpd.colorAttachments[1].pixelFormat = Self.gbufferNormalFormat     // eye-space normal
            dpd.depthAttachmentPixelFormat = Self.depthFormat
            // The G-buffer is 1× on purpose: AO and the edge are low-frequency screen
            // terms, and multisampling their INPUT would cost 4× the depth/normal
            // bandwidth to change nothing a 4×4 blur does not already smooth over.
            depthPrepassPipe = try? device.makeRenderPipelineState(descriptor: dpd)
        }
        // §3c footprint pipeline: position only, one R8 colour attachment, no depth
        // (any coverage counts — the shadow does not care which surface was nearest).
        var shadowPipe: MTLRenderPipelineState? = nil
        if let shLib = try? device.makeLibrary(source: shadowShaderSource, options: nil),
           let shvf = shLib.makeFunction(name: "shadow_vertex"),
           let shff = shLib.makeFunction(name: "shadow_fragment") {
            let svd = MTLVertexDescriptor()
            svd.attributes[0].format = .float3     // position
            svd.attributes[0].offset = 0
            svd.attributes[0].bufferIndex = 0
            svd.layouts[0].stride = MemoryLayout<Float>.stride * 6   // pos+normal (normal unused)
            let sspd = MTLRenderPipelineDescriptor()
            sspd.vertexFunction = shvf
            sspd.fragmentFunction = shff
            sspd.vertexDescriptor = svd
            sspd.colorAttachments[0].pixelFormat = Self.shadowFormat
            shadowPipe = try? device.makeRenderPipelineState(descriptor: sspd)
        }
        // SSAO + edge pipelines (§1, §3a). Two full-screen passes over the G-buffer,
        // no vertex buffer (the vertex_id triangle trick), no depth attachment, no
        // blending — they WRITE the AO texture the body shader then reads.
        var aoPipe: MTLRenderPipelineState? = nil
        var aoBlurPipe: MTLRenderPipelineState? = nil
        if let aLib = try? device.makeLibrary(source: aoShaderSource, options: nil),
           let avf = aLib.makeFunction(name: "ao_vertex"),
           let aff = aLib.makeFunction(name: "ao_fragment"),
           let abf = aLib.makeFunction(name: "aoblur_fragment") {
            let apd = MTLRenderPipelineDescriptor()
            apd.vertexFunction = avf
            apd.fragmentFunction = aff
            apd.colorAttachments[0].pixelFormat = Self.aoFormat
            aoPipe = try? device.makeRenderPipelineState(descriptor: apd)
            let bpd = MTLRenderPipelineDescriptor()
            bpd.vertexFunction = avf
            bpd.fragmentFunction = abf
            bpd.colorAttachments[0].pixelFormat = Self.aoFormat
            aoBlurPipe = try? device.makeRenderPipelineState(descriptor: bpd)
        }
        // Contact pipeline (items 7+8, parts b+c): the ONE variant both the design-box and
        // clearance FACE draws use. Same vertex layout + premultiplied "over" blend as the ground
        // pipeline (so it's byte-identical away from the part), plus the scene-depth texture read.
        var contactPipe: MTLRenderPipelineState? = nil
        if let cLib = try? device.makeLibrary(source: contactShaderSource, options: nil),
           let cvf = cLib.makeFunction(name: "contact_vertex"),
           let cff = cLib.makeFunction(name: "contact_fragment") {
            let cvd = MTLVertexDescriptor()
            cvd.attributes[0].format = .float3     // position
            cvd.attributes[0].offset = 0
            cvd.attributes[0].bufferIndex = 0
            cvd.attributes[1].format = .float4     // rgba (premultiplied)
            cvd.attributes[1].offset = MemoryLayout<Float>.stride * 3
            cvd.attributes[1].bufferIndex = 0
            cvd.layouts[0].stride = MemoryLayout<Float>.stride * 7
            let cpd = MTLRenderPipelineDescriptor()
            cpd.vertexFunction = cvf
            cpd.fragmentFunction = cff
            cpd.vertexDescriptor = cvd
            cpd.colorAttachments[0].pixelFormat = Self.colorFormat
            cpd.colorAttachments[0].isBlendingEnabled = true          // premultiplied alpha (as ground)
            cpd.colorAttachments[0].rgbBlendOperation = .add
            cpd.colorAttachments[0].alphaBlendOperation = .add
            cpd.colorAttachments[0].sourceRGBBlendFactor = .one
            cpd.colorAttachments[0].sourceAlphaBlendFactor = .one
            cpd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            cpd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            cpd.depthAttachmentPixelFormat = Self.depthFormat
            cpd.rasterSampleCount = raster       // §3b MSAA
            contactPipe = try? device.makeRenderPipelineState(descriptor: cpd)
        }
        // Load-path ribbon pipeline (optional: falls back to the ground line pipeline).
        // Vertex layout (stride 48): segStart(12) + segEnd(12) + side/endFlag(8) + rgba(16).
        var lpPipe: MTLRenderPipelineState? = nil
        if let lpLib = try? device.makeLibrary(source: loadPathShaderSource, options: nil),
           let lpvf = lpLib.makeFunction(name: "loadpath_vertex"),
           let lpff = lpLib.makeFunction(name: "loadpath_fragment") {
            let lvd = MTLVertexDescriptor()
            lvd.attributes[0].format = .float3            // segStart
            lvd.attributes[0].offset = 0
            lvd.attributes[0].bufferIndex = 0
            lvd.attributes[1].format = .float3            // segEnd
            lvd.attributes[1].offset = MemoryLayout<Float>.stride * 3
            lvd.attributes[1].bufferIndex = 0
            lvd.attributes[2].format = .float2            // side, end flag
            lvd.attributes[2].offset = MemoryLayout<Float>.stride * 6
            lvd.attributes[2].bufferIndex = 0
            lvd.attributes[3].format = .float4            // rgba
            lvd.attributes[3].offset = MemoryLayout<Float>.stride * 8
            lvd.attributes[3].bufferIndex = 0
            lvd.layouts[0].stride = MemoryLayout<Float>.stride * 12
            let lpd = MTLRenderPipelineDescriptor()
            lpd.vertexFunction = lpvf
            lpd.fragmentFunction = lpff
            lpd.vertexDescriptor = lvd
            lpd.colorAttachments[0].pixelFormat = Self.colorFormat
            lpd.colorAttachments[0].isBlendingEnabled = true          // premultiplied alpha
            lpd.colorAttachments[0].rgbBlendOperation = .add
            lpd.colorAttachments[0].alphaBlendOperation = .add
            lpd.colorAttachments[0].sourceRGBBlendFactor = .one
            lpd.colorAttachments[0].sourceAlphaBlendFactor = .one
            lpd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            lpd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            lpd.depthAttachmentPixelFormat = Self.depthFormat
            lpd.rasterSampleCount = raster       // §3b MSAA
            lpPipe = try? device.makeRenderPipelineState(descriptor: lpd)
        }

        // Load-path FLOW comet pipeline (handoff 070): reuses the ground pos+rgba
        // shaders but blends ADDITIVE (src one / dst one), so the premultiplied comet
        // tubes accumulate into a glow that reads through the translucent x-ray body.
        var cometPipe: MTLRenderPipelineState? = nil
        if let cLib = try? device.makeLibrary(source: groundShaderSource, options: nil),
           let cvf = cLib.makeFunction(name: "ground_vertex"),
           let cff = cLib.makeFunction(name: "ground_fragment") {
            let cvd = MTLVertexDescriptor()
            cvd.attributes[0].format = .float3     // position
            cvd.attributes[0].offset = 0
            cvd.attributes[0].bufferIndex = 0
            cvd.attributes[1].format = .float4     // rgba (premultiplied)
            cvd.attributes[1].offset = MemoryLayout<Float>.stride * 3
            cvd.attributes[1].bufferIndex = 0
            cvd.layouts[0].stride = MemoryLayout<Float>.stride * 7
            let cpd = MTLRenderPipelineDescriptor()
            cpd.vertexFunction = cvf
            cpd.fragmentFunction = cff
            cpd.vertexDescriptor = cvd
            cpd.colorAttachments[0].pixelFormat = Self.colorFormat
            cpd.colorAttachments[0].isBlendingEnabled = true          // ADDITIVE glow
            cpd.colorAttachments[0].rgbBlendOperation = .add
            cpd.colorAttachments[0].alphaBlendOperation = .add
            cpd.colorAttachments[0].sourceRGBBlendFactor = .one
            cpd.colorAttachments[0].sourceAlphaBlendFactor = .one
            cpd.colorAttachments[0].destinationRGBBlendFactor = .one
            cpd.colorAttachments[0].destinationAlphaBlendFactor = .one
            cpd.depthAttachmentPixelFormat = Self.depthFormat
            cpd.rasterSampleCount = raster       // §3b MSAA
            cometPipe = try? device.makeRenderPipelineState(descriptor: cpd)
        }

        // Load-path FLOW translucent body pipeline (handoff 070): the SAME viewer
        // shaders + vertex layout, but premultiplied "over" blending so the x-ray/stress
        // body draws see-through (the fragment already premultiplies by `bodyAlpha`).
        var translucentPipe: MTLRenderPipelineState? = nil
        do {
            let tpd = MTLRenderPipelineDescriptor()
            tpd.vertexFunction = vfn
            tpd.fragmentFunction = ffn
            tpd.vertexDescriptor = vd
            tpd.colorAttachments[0].pixelFormat = Self.colorFormat
            tpd.colorAttachments[0].isBlendingEnabled = true
            tpd.colorAttachments[0].rgbBlendOperation = .add
            tpd.colorAttachments[0].alphaBlendOperation = .add
            tpd.colorAttachments[0].sourceRGBBlendFactor = .one       // premultiplied
            tpd.colorAttachments[0].sourceAlphaBlendFactor = .one
            tpd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            tpd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            tpd.depthAttachmentPixelFormat = Self.depthFormat
            tpd.rasterSampleCount = raster       // §3b MSAA
            translucentPipe = try? device.makeRenderPipelineState(descriptor: tpd)
        }

        // ★ THE UNIFIED LATTICE PIPELINES (task 2026-08-18-unified-shading). Two
        // fragment functions over ONE library, both from `unifiedLatticeShaderSource`:
        //
        //   `lsdf_gbuffer` writes the marched hit into the SHELL'S OWN G-buffer — same
        //       three attachments, same depth attachment, so AO and the edge detector
        //       see one surface set instead of two (§1 i + iii). Depth is written from
        //       the fragment, which is unavoidable for a raymarch, and DECLARED
        //       `greater` (§2b) rather than left for the compiler to assume the worst.
        //
        //   `lsdf_shade` is the deferred shade in the MAIN colour pass: no march, the
        //       shell's `to_material`, the shell's AO texture, the shell's depth fade,
        //       and a depth write into the SHARED depth buffer so interpenetration
        //       resolves per pixel (§1 ii).
        //
        // Both optional. A nil leaves the frame exactly as it is without a lattice —
        // never a black rectangle over the part, the failure mode that matters here.
        var latGPipe: MTLRenderPipelineState? = nil
        var latShadePipe: MTLRenderPipelineState? = nil
        if let lLib = try? device.makeLibrary(source: unifiedLatticeShaderSource, options: nil),
           let lvf = lLib.makeFunction(name: "lsdf_vertex"),
           let lgf = lLib.makeFunction(name: "lsdf_gbuffer"),
           let lsf = lLib.makeFunction(name: "lsdf_shade") {
            let gpd = MTLRenderPipelineDescriptor()
            gpd.vertexFunction = lvf
            gpd.fragmentFunction = lgf
            gpd.colorAttachments[0].pixelFormat = Self.sceneDepthFormat
            gpd.colorAttachments[1].pixelFormat = Self.gbufferNormalFormat
            gpd.colorAttachments[2].pixelFormat = Self.gbufferAlbedoFormat
            gpd.depthAttachmentPixelFormat = Self.depthFormat
            latGPipe = try? device.makeRenderPipelineState(descriptor: gpd)

            let spd2 = MTLRenderPipelineDescriptor()
            spd2.vertexFunction = lvf
            spd2.fragmentFunction = lsf
            spd2.colorAttachments[0].pixelFormat = Self.colorFormat
            spd2.depthAttachmentPixelFormat = Self.depthFormat
            spd2.rasterSampleCount = raster      // §3b — it lands in the multisampled pass
            latShadePipe = try? device.makeRenderPipelineState(descriptor: spd2)
        }

        // Translucent body depth: test against the part but write nothing, so back
        // walls show through the front — the x-ray read.
        let tdsd = MTLDepthStencilDescriptor()
        tdsd.depthCompareFunction = .less
        tdsd.isDepthWriteEnabled = false

        // Ground depth: test against the part (so it is occluded) but do not write
        // depth (the translucent ground must not block anything behind it).
        let gdsd = MTLDepthStencilDescriptor()
        gdsd.depthCompareFunction = .less
        gdsd.isDepthWriteEnabled = false

        // Load-path overlay: always passes the depth test (draws over the part), never
        // writes depth (so it never occludes anything else).
        let odsd = MTLDepthStencilDescriptor()
        odsd.depthCompareFunction = .always
        odsd.isDepthWriteEnabled = false

        self.device = device
        self.queue = queue
        self.pipeline = pipe
        self.depthState = depth
        self.idPipeline = idPipe
        self.groundPipeline = groundPipe
        self.stagePipeline = stagePipe
        self.depthPrepassPipeline = depthPrepassPipe
        self.contactPipeline = contactPipe
        self.groundDepthState = device.makeDepthStencilState(descriptor: gdsd) ?? depth
        self.lineOverlayDepthState = device.makeDepthStencilState(descriptor: odsd) ?? depth
        self.loadPathPipeline = lpPipe
        self.cometPipeline = cometPipe
        self.translucentBodyPipeline = translucentPipe
        self.translucentBodyDepthState = device.makeDepthStencilState(descriptor: tdsd) ?? depth
        self.aoPipeline = aoPipe
        self.aoBlurPipeline = aoBlurPipe
        self.shadowPipeline = shadowPipe
        self.latticeGBufferPipeline = latGPipe
        self.latticeShadePipeline = latShadePipe
        self.sampleCount = raster
        super.init()
    }

    /// What `applyMesh` did — reported so the caller can tell "a new object
    /// arrived and was framed" from "the object on screen moved".
    enum MeshApplyOutcome: Equatable {
        /// A genuinely different mesh: uploaded through `setMesh`, which REFRAMES
        /// the camera and resets the settle.
        case reframed
        /// The same surface with its vertices moved: positions re-uploaded, and
        /// the camera, the settle and the ground left exactly as the user had
        /// them.
        case positionsUpdatedInPlace
    }

    /// THE ONE ENTRY POINT FOR PUTTING A MESH ON SCREEN
    /// (task 2026-08-08-smoothing-that-works-and-is-usable, S1a).
    ///
    /// WHAT WENT WRONG. Every mesh swap went through `setMesh`, and `setMesh`
    /// ends with `camera.frame(mesh.bounds)` — it re-anchors the look-at target,
    /// re-fits the distance and re-derives the zoom limits. That is right for a
    /// new part and wrong for a brush stroke: on the smoothing page the stroke's
    /// preview is the SAME SURFACE with some vertices moved, so every time the
    /// maintainer lifted the brush his zoom and his pan were thrown away and the
    /// view jumped back to the framed default. (Azimuth and elevation survived,
    /// because the coordinator mirrors them onto the renderer before the swap —
    /// which is why the symptom reads as "the zoom/position went back to the
    /// origin point" rather than "the view spun".) The coordinator then handed
    /// the reframed camera back to the shared `OrbitCameraModel`, so the reset
    /// was persisted, not merely drawn once. MEASURED, on the fixture in
    /// `SmoothingStrokeCameraTests`: distance 0.9108709 -> 2.6155658 and the
    /// target snapped from his pan back onto the model centre, on every stroke.
    ///
    /// WHY THIS ROUTE AND NOT "PRESERVE THE CAMERA ACROSS THE SWAP". Saving the
    /// camera around a `setMesh` call would restore those numbers and still be a
    /// full re-upload: the settle rotation is reset to identity and re-animated
    /// (0.8 s), the ground is rebuilt, the model centre jumps, and the tint
    /// buffer is zeroed and rebuilt. The maintainer did not report only a camera
    /// jump — he reported the page resetting — and those are the rest of it. A
    /// stroke should touch the vertex positions and NOTHING else, so this takes
    /// the in-place route and the camera falls out of it rather than being
    /// restored by hand. It also cannot be forgotten: a caller who does not know
    /// about the camera still gets the right behaviour.
    ///
    /// The decision is `ViewerMeshSignature.isSameSurface` — same counts, same
    /// connectivity — which a stroke, a smoothing pass and an Original/Smoothed
    /// swap all satisfy and a different part, a streamed variant or a re-meshing
    /// all fail.
    @discardableResult
    func applyMesh(_ mesh: ViewerMesh) -> MeshApplyOutcome {
        if let current = self.mesh, !mesh.isEmpty, !current.isEmpty,
           current.signature.isSameSurface(as: mesh.signature),
           mesh.flat.vertexCount == vertexDrawCount {
            updateVertexPositions(mesh)
            return .positionsUpdatedInPlace
        }
        setMesh(mesh)
        return .reframed
    }

    /// Re-upload the positions of a mesh whose connectivity is unchanged. The
    /// camera, the settle, the model centre, the ground and the tint buffer are
    /// deliberately untouched — see `applyMesh`.
    ///
    /// The id buffer IS rebuilt, because it carries the positions the pick pass
    /// rasterizes: leaving it stale would make the brush hit-test the shape from
    /// before the stroke.
    private func updateVertexPositions(_ mesh: ViewerMesh) {
        self.mesh = mesh
        let interleaved = mesh.flat.interleaved()
        vertexBuffer = interleaved.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
        buildIDBuffer()
    }

    /// Upload the mesh's flat-shaded (unshared-vertex) buffers — the interleaved
    /// position+normal buffer, the per-vertex face-id buffer (for the id pass) and a
    /// zeroed tint buffer — and frame it.
    ///
    /// THIS REFRAMES THE CAMERA AND RESETS THE SETTLE. Prefer `applyMesh`, which
    /// routes a moved-but-identical surface away from here — see its comment.
    func setMesh(_ mesh: ViewerMesh) {
        self.mesh = mesh
        loadPathBuffer = nil; loadPathVertexCount = 0   // new variant → drop stale glyphs
        loadPathRibbonBuffer = nil; loadPathRibbonVertexCount = 0
        loadFlowBuffer = nil; loadFlowVertexCount = 0   // …and stale comet-flow geometry
        flowGuideBuffer = nil; flowGuideVertexCount = 0
        guard !mesh.isEmpty else {
            vertexBuffer = nil; tintBuffer = nil; idVertexBuffer = nil; flexBuffer = nil
            vertexDrawCount = 0; flatFaceIDs = []; flexScale = 0
            return
        }
        let interleaved = mesh.flat.interleaved()
        vertexBuffer = interleaved.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
        vertexDrawCount = mesh.flat.vertexCount

        // A fresh mesh starts un-flexed: a zero displacement buffer (always bound at
        // buffer(3)) + scale 0, so the static draw is unchanged until flex is set.
        flexScale = 0
        let zeros = [Float](repeating: 0, count: vertexDrawCount * 3)
        flexBuffer = zeros.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }

        // Flat face ids: a triangle's id repeated for each of its three vertices.
        flatFaceIDs = mesh.faceIDs.flatMap { id -> [UInt32] in
            let u = UInt32(bitPattern: id)
            return [u, u, u]
        }
        buildIDBuffer()
        buildTintBuffer(faceTint: [:], activeFaces: [])
        camera.frame(mesh.bounds)

        // A fresh part starts un-settled (gravity is set afterward).
        modelCenter = mesh.bounds.center
        let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        modelRotation = identity; settleFrom = identity; settleTo = identity
        isSettling = false
        buildGround()
    }

    // MARK: settle + ground (M7.6 D2)

    /// Begin (or snap) the settle to `rotation`. `duration <= 0` snaps immediately
    /// (reduced-motion). Rebuilds the ground for the new resting pose.
    func beginSettle(to rotation: simd_quatf, duration: CFTimeInterval) {
        settleBeginCount += 1
        settleFrom = modelRotation
        settleTo = rotation
        settleDuration = Swift.max(0, duration)
        settleStart = CACurrentMediaTime()
        if settleDuration <= 0 {
            modelRotation = rotation
            isSettling = false
        } else {
            isSettling = true
        }
        buildGround()
    }

    /// Advance the settle animation to the current time; returns true while still
    /// animating. A gentle ease-out with slight overshoot (proto `easeSettle`).
    @discardableResult
    private func stepSettle() -> Bool {
        guard isSettling, settleDuration > 0 else { return false }
        let raw = Float((CACurrentMediaTime() - settleStart) / settleDuration)
        let t = Swift.min(1, Swift.max(0, raw))
        let c: Float = 1.70158 * 0.6
        let e = t - 1
        let eased = 1 + ((c + 1) * e + c) * e * e     // cubic ease-out w/ overshoot
        modelRotation = simd_slerp(settleFrom, settleTo, eased)
        if t >= 1 {
            modelRotation = settleTo
            isSettling = false
            return false
        }
        return true
    }

    /// The model matrix: rotate about the model centre (keeps the centre fixed).
    private func modelMatrix() -> simd_float4x4 {
        let r = simd_float4x4(modelRotation)
        return Self.translation(modelCenter) * r * Self.translation(-modelCenter)
    }

    private static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t, 1)
        return m
    }

    /// Rebuild the ground grid + contact shadow for the settled bounding box (the
    /// mesh bbox transformed by `settleTo`), on the world floor plane at its min-Y.
    private func buildGround() {
        groundLineBuffer = nil; groundLineCount = 0
        groundShadowBuffer = nil; groundShadowCount = 0
        guard let mesh, !mesh.isEmpty else { return }
        // Settled AABB from the 8 bbox corners under the target rotation.
        let mn = mesh.bounds.min, mx = mesh.bounds.max
        let rot = simd_float4x4(settleTo)
        let model = Self.translation(modelCenter) * rot * Self.translation(-modelCenter)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for xi in [mn.x, mx.x] { for yi in [mn.y, mx.y] { for zi in [mn.z, mx.z] {
            let w = model * SIMD4<Float>(xi, yi, zi, 1)
            let p = SIMD3<Float>(w.x, w.y, w.z)
            lo = simd_min(lo, p); hi = simd_max(hi, p)
        }}}
        let fy = lo.y - 0.001
        let cx = (lo.x + hi.x) * 0.5, cz = (lo.z + hi.z) * 0.5
        let extent = Swift.max(hi.x - lo.x, hi.z - lo.z)
        guard extent > 1e-5 else { return }
        let radius = extent * 1.6
        let step = extent / 6

        // Grid lines (each: 2 vertices of pos+rgba, stride 7). Fade with distance.
        var lines: [Float] = []
        let base = SIMD3<Float>(0.63, 0.71, 0.86)
        func push(_ p: SIMD3<Float>, _ a: Float) {
            lines.append(p.x); lines.append(p.y); lines.append(p.z)
            lines.append(base.x); lines.append(base.y); lines.append(base.z); lines.append(a)
        }
        var k = -radius
        while k <= radius + 1e-4 {
            let a = (1 - abs(k) / radius) * 0.12
            push(SIMD3<Float>(cx + k, fy, cz - radius), a); push(SIMD3<Float>(cx + k, fy, cz + radius), a)
            push(SIMD3<Float>(cx - radius, fy, cz + k), a); push(SIMD3<Float>(cx + radius, fy, cz + k), a)
            k += step
        }
        groundLineCount = lines.count / 7
        if groundLineCount > 0 {
            groundLineBuffer = lines.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
            }
        }

        // Contact shadow: a triangle fan (expanded to a triangle list) on the floor,
        // dark at the centre fading to transparent at the rim.
        let sRadius = extent * 0.62
        let segs = 40
        var shadow: [Float] = []
        let dark = SIMD3<Float>(0, 0, 0)
        func vtx(_ x: Float, _ z: Float, _ a: Float) {
            shadow.append(x); shadow.append(fy); shadow.append(z)
            shadow.append(dark.x); shadow.append(dark.y); shadow.append(dark.z); shadow.append(a)
        }
        for i in 0..<segs {
            let a0 = Float(i) / Float(segs) * 2 * .pi
            let a1 = Float(i + 1) / Float(segs) * 2 * .pi
            vtx(cx, cz, 0.5)                                            // centre (dark)
            vtx(cx + cos(a0) * sRadius, cz + sin(a0) * sRadius, 0)      // rim (clear)
            vtx(cx + cos(a1) * sRadius, cz + sin(a1) * sRadius, 0)
        }
        groundShadowCount = shadow.count / 7
        if groundShadowCount > 0 {
            groundShadowBuffer = shadow.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
            }
        }
    }

    /// M7.dom-app: upload the design-box gizmo geometry. `design` is the grow-room
    /// box (nil hides the gizmo); `keepOuts` are the excluded regions. Each is drawn
    /// as translucent faces + bright edges in its colour, in MODEL space (so it
    /// settles with the part). Called on the main thread; the draw reads the buffers.
    func setDesignBoxes(design: DesignBoxBounds?, designColor: SIMD4<Float>,
                        keepOuts: [DesignBoxBounds], keepOutColor: SIMD4<Float>) {
        designBoxFaceBuffer = nil; designBoxFaceCount = 0
        designBoxLineBuffer = nil; designBoxLineCount = 0
        guard design != nil || !keepOuts.isEmpty else { return }

        var faces: [Float] = []
        var lines: [Float] = []
        func push(_ dst: inout [Float], _ p: SIMD3<Float>, _ c: SIMD4<Float>) {
            dst.append(p.x); dst.append(p.y); dst.append(p.z)
            dst.append(c.x); dst.append(c.y); dst.append(c.z); dst.append(c.w)
        }
        // Append one box: 6 quad faces (2 triangles each) at `faceAlpha`, and 12
        // edges at full colour. Premultiplied alpha (the ground pipeline blends
        // source .one / dest oneMinusSourceAlpha), so scale rgb by alpha.
        func appendBox(_ b: DesignBoxBounds, _ color: SIMD4<Float>, faceAlpha: Float) {
            let lo = b.min, hi = b.max
            let c = [SIMD3<Float>(lo.x, lo.y, lo.z), SIMD3<Float>(hi.x, lo.y, lo.z),
                     SIMD3<Float>(hi.x, hi.y, lo.z), SIMD3<Float>(lo.x, hi.y, lo.z),
                     SIMD3<Float>(lo.x, lo.y, hi.z), SIMD3<Float>(hi.x, lo.y, hi.z),
                     SIMD3<Float>(hi.x, hi.y, hi.z), SIMD3<Float>(lo.x, hi.y, hi.z)]
            let fcol = SIMD4<Float>(color.x * faceAlpha, color.y * faceAlpha,
                                    color.z * faceAlpha, faceAlpha)  // premultiplied
            let quads = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4],
                         [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3]]
            for q in quads {
                push(&faces, c[q[0]], fcol); push(&faces, c[q[1]], fcol); push(&faces, c[q[2]], fcol)
                push(&faces, c[q[0]], fcol); push(&faces, c[q[2]], fcol); push(&faces, c[q[3]], fcol)
            }
            let ea = min(1, color.w)
            let ecol = SIMD4<Float>(color.x * ea, color.y * ea, color.z * ea, ea)
            let edges = [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6],
                         [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]]
            for e in edges { push(&lines, c[e[0]], ecol); push(&lines, c[e[1]], ecol) }
        }

        // The design box as a GLASS VOLUME (design-overhaul round 2, item 10): a barely-there
        // cool-white/blue face tint so it reads as a volume the part PASSES THROUGH — the part
        // stays visible through the tint, and the box stays visible through the part where it
        // extends past it — plus a bright doubled "refractive wobble" edge that stands in for the
        // fresnel-edge reflection. Depth-correct translucency (the box pass is depth-TESTED so
        // the part occludes the box's far faces, but writes NO depth so it never hides the part),
        // NOT a flat outline. The `faceAlpha` is deliberately tiny; the edge carries the read.
        func appendGlassBox(_ b: DesignBoxBounds) {
            let ctr = b.center
            let glass = SIMD3<Float>(0.72, 0.82, 1.0)                 // bright cool-white edge glass
            // A frosted BLUE tint for the faces (design-overhaul round 2, item 10 revision): the
            // maintainer wants to READ that the box has passed through the part, so the faces are
            // a clear frosty blue with a small amount of frosting — not the near-invisible 0.055.
            let faceTint = SIMD3<Float>(0.40, 0.58, 1.0)            // frosty blue
            let edges = [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6],
                         [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]]
            let quads = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4],
                         [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3]]
            func corners(_ box: DesignBoxBounds) -> [SIMD3<Float>] {
                let lo = box.min, hi = box.max
                return [SIMD3<Float>(lo.x, lo.y, lo.z), SIMD3<Float>(hi.x, lo.y, lo.z),
                        SIMD3<Float>(hi.x, hi.y, lo.z), SIMD3<Float>(lo.x, hi.y, lo.z),
                        SIMD3<Float>(lo.x, lo.y, hi.z), SIMD3<Float>(hi.x, lo.y, hi.z),
                        SIMD3<Float>(hi.x, hi.y, hi.z), SIMD3<Float>(lo.x, hi.y, hi.z)]
            }
            func wire(_ box: DesignBoxBounds, alpha: Float) {
                let c = corners(box)
                let col = SIMD4<Float>(glass.x * alpha, glass.y * alpha, glass.z * alpha, alpha)
                for e in edges { push(&lines, c[e[0]], col); push(&lines, c[e[1]], col) }
            }
            // Frosted-blue translucent faces → the "volume passing THROUGH the part" read
            // (premultiplied, so scale rgb). Enough alpha to tint the part visibly, still
            // see-through. Depth-tested / no depth-write, so the part occludes the box's far
            // faces and the box tints the part where it overhangs it.
            let c = corners(b)
            let faceAlpha: Float = 0.22
            let fcol = SIMD4<Float>(faceTint.x * faceAlpha, faceTint.y * faceAlpha, faceTint.z * faceAlpha, faceAlpha)
            for q in quads {
                push(&faces, c[q[0]], fcol); push(&faces, c[q[1]], fcol); push(&faces, c[q[2]], fcol)
                push(&faces, c[q[0]], fcol); push(&faces, c[q[2]], fcol); push(&faces, c[q[3]], fcol)
            }
            wire(b, alpha: 0.92)                                      // bright outer glass edge
            // Inner wireframe, corners pulled ~4% toward the centre → the refractive "wobble".
            let inset = SIMD3<Float>(repeating: 0.04)
            let innerLo = ctr + (b.min - ctr) * (1 - inset)
            let innerHi = ctr + (b.max - ctr) * (1 - inset)
            wire(DesignBoxBounds(min: innerLo, max: innerHi), alpha: 0.34)
        }

        // The DESIGN box (grow room) reads as a translucent GLASS VOLUME, not a solid: a barely-
        // there cool-white tint the part shows through, bounded by the bright doubled "refractive
        // wobble" edge (see `appendGlassBox`). Keep-outs stay tinted-solid: they are forbidden
        // volume and keep the red colour language.
        if let d = design { appendGlassBox(d) }
        for k in keepOuts { appendBox(k, keepOutColor, faceAlpha: 0.16) }

        designBoxFaceCount = faces.count / 7
        if designBoxFaceCount > 0 {
            designBoxFaceBuffer = faces.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
            }
        }
        designBoxLineCount = lines.count / 7
        if designBoxLineCount > 0 {
            designBoxLineBuffer = lines.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
            }
        }
    }

    /// Tessellate the keep-clear v2 clearance volumes (Part 3) into translucent red
    /// faces + bright edges, in MODEL space (settles with the part under uniforms.mvp).
    /// A `.cylinder` becomes a capped tube of radius = bore + margin over [tLo, tHi];
    /// a `.slab` becomes the outline rectangle extruded by depth; a `.degenerate`
    /// region draws NOTHING filled — an honest hollow. Selected volumes brighten.
    func setClearanceVolumes(_ items: [ClearanceRenderItem]) {
        clearanceFaceBuffer = nil; clearanceFaceCount = 0
        clearanceLineBuffer = nil; clearanceLineCount = 0
        clearanceXrayBuffer = nil; clearanceXrayCount = 0
        guard !items.isEmpty else { return }

        // Base clearance red (matches the SwiftUI affix/label tint). ~50% fill (task),
        // brighter when the group is selected; edges near-opaque so the shape reads.
        // An item may override the colour (round-2: lattice-role region volumes).
        let baseRGB = SIMD3<Float>(0.95, 0.38, 0.36)
        var faces: [Float] = []
        var lines: [Float] = []
        // Round-2 L21 (the "invisible primitives" root cause): a fresh primitive
        // spawns at the model CENTRE, and this pass is depth-tested — a volume
        // buried inside the opaque body was fully occluded, so it rendered as
        // NOTHING. The x-ray buffer re-draws the edges depth-ALWAYS at low alpha,
        // so a buried primitive still reads as a ghost wireframe wherever it is.
        var xray: [Float] = []
        func push(_ dst: inout [Float], _ p: SIMD3<Float>, _ c: SIMD4<Float>) {
            dst.append(p.x); dst.append(p.y); dst.append(p.z)
            dst.append(c.x); dst.append(c.y); dst.append(c.z); dst.append(c.w)
        }
        // Premultiplied alpha (ground pipeline blends src .one / dst 1−srcA).
        func premul(_ rgb: SIMD3<Float>, _ a: Float) -> SIMD4<Float> {
            SIMD4<Float>(rgb.x * a, rgb.y * a, rgb.z * a, a)
        }
        func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ col: SIMD4<Float>) {
            push(&faces, a, col); push(&faces, b, col); push(&faces, c, col)
        }
        var xcol = SIMD4<Float>()
        func seg(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ col: SIMD4<Float>) {
            push(&lines, a, col); push(&lines, b, col)
            push(&xray, a, xcol); push(&xray, b, xcol)
        }

        let ring = 28  // circle tessellation
        for item in items {
            let selected = item.selected
            let rgb = item.tint ?? baseRGB
            let faceAlpha: Float = selected ? 0.60 : 0.42
            let edgeAlpha: Float = selected ? 0.98 : 0.80
            let fcol = premul(rgb, faceAlpha)
            let ecol = premul(rgb, edgeAlpha)
            xcol = premul(rgb, edgeAlpha * 0.35)
            switch item.volume.shape {
            case let .cylinder(axisPoint, axisDir, radius, tLo, tHi):
                let dir = simd_length(axisDir) > 1e-6 ? simd_normalize(axisDir) : SIMD3<Float>(0, 0, 1)
                let (u, v) = planeBasis(normal: dir)
                let c0 = axisPoint + dir * tLo
                let c1 = axisPoint + dir * tHi
                func rim(_ centre: SIMD3<Float>, _ k: Int) -> SIMD3<Float> {
                    let a = Float(k) * (2 * .pi / Float(ring))
                    return centre + (u * cos(a) + v * sin(a)) * radius
                }
                for k in 0..<ring {
                    let a0 = rim(c0, k), a1 = rim(c0, k + 1)
                    let b0 = rim(c1, k), b1 = rim(c1, k + 1)
                    tri(a0, a1, b1, fcol); tri(a0, b1, b0, fcol)     // side wall
                    tri(c0, a1, a0, fcol)                            // lo cap fan
                    tri(c1, b0, b1, fcol)                            // hi cap fan
                    seg(a0, a1, ecol); seg(b0, b1, ecol)            // rim rings
                    if k % 7 == 0 { seg(a0, b0, ecol) }             // a few axial edges
                }
            case let .slab(centre, normal, uAxis, vAxis, halfU, halfV, depthMM):
                let n = simd_length(normal) > 1e-6 ? simd_normalize(normal) : SIMD3<Float>(0, 0, 1)
                let du = uAxis * halfU, dv = vAxis * halfV, dn = n * depthMM
                // 8 corners: inner rectangle (on the face) + outer (extruded by depth).
                let inner = [centre - du - dv, centre + du - dv, centre + du + dv, centre - du + dv]
                let outer = inner.map { $0 + dn }
                let all = inner + outer
                let quads = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4],
                             [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3]]
                for q in quads {
                    tri(all[q[0]], all[q[1]], all[q[2]], fcol)
                    tri(all[q[0]], all[q[2]], all[q[3]], fcol)
                }
                let edges = [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6],
                             [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]]
                for e in edges { seg(all[e[0]], all[e[1]], ecol) }
            case let .shell(s):
                // ★ §2(a)/§2(b) — THE OFFSET SHELL: the selected surface, the same
                // surface pushed inward, and the skirt joining their boundary. One
                // draw for a plane, a bore or a fillet — the geometry already made
                // the distinction unnecessary (`FaceOffsetShell`).
                var k = 0
                while k + 2 < s.indices.count {
                    let i0 = Int(s.indices[k]), i1 = Int(s.indices[k + 1])
                    let i2 = Int(s.indices[k + 2])
                    tri(s.base[i0], s.base[i1], s.base[i2], fcol)          // the face
                    tri(s.offset[i2], s.offset[i1], s.offset[i0], fcol)    // its offset
                    k += 3
                }
                // The SKIRT rides the boundary — the edges used by exactly one
                // triangle. Interior edges are shared and must not be walled, or
                // the shell fills with sheets.
                var use: [UInt64: Int] = [:]
                var edge: [UInt64: (UInt32, UInt32)] = [:]
                k = 0
                while k + 2 < s.indices.count {
                    let t3 = [s.indices[k], s.indices[k + 1], s.indices[k + 2]]
                    for e in 0..<3 {
                        let a = t3[e], b = t3[(e + 1) % 3]
                        let key = a < b ? (UInt64(a) << 32 | UInt64(b))
                                        : (UInt64(b) << 32 | UInt64(a))
                        use[key, default: 0] += 1
                        edge[key] = (a, b)
                    }
                    k += 3
                }
                for (key, n) in use where n == 1 {
                    guard let (a, b) = edge[key] else { continue }
                    let ia = Int(a), ib = Int(b)
                    tri(s.base[ia], s.base[ib], s.offset[ib], fcol)
                    tri(s.base[ia], s.offset[ib], s.offset[ia], fcol)
                    seg(s.base[ia], s.base[ib], ecol)
                    seg(s.offset[ia], s.offset[ib], ecol)
                    seg(s.base[ia], s.offset[ia], ecol)
                }
            case .degenerate:
                // Hollow honesty: a small dashed cross-ring at the face-derived point is
                // meaningless without geometry, so a degenerate volume simply draws
                // nothing here — the SwiftUI row already carries the "no effect" wording.
                break
            }
        }

        clearanceFaceCount = faces.count / 7
        if clearanceFaceCount > 0 {
            clearanceFaceBuffer = faces.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
            }
        }
        clearanceLineCount = lines.count / 7
        if clearanceLineCount > 0 {
            clearanceLineBuffer = lines.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
            }
        }
        clearanceXrayCount = xray.count / 7
        if clearanceXrayCount > 0 {
            clearanceXrayBuffer = xray.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
            }
        }
    }

    /// Rebuild the per-vertex tint buffer from the selection: each grouped face's
    /// vertices carry that group's colour; the active group is tinted more strongly.
    /// ★ §6 — A PER-VERTEX TINT, OVERRIDING THE PER-FACE ONE.
    ///
    /// A cut does not create a face (LAYER 1 is never re-partitioned), so both
    /// halves of a cut face carry the SAME face id and a `[FaceID: colour]` map
    /// cannot draw them differently. The tint buffer was ALREADY per-vertex —
    /// `buildTintBuffer` writes one RGBA per vertex and only *chooses* by face —
    /// so the halves need no shader and no new pipeline, just the choice made
    /// per vertex instead. `SurfaceTint` makes it; this uploads it.
    ///
    /// Empty clears the override and the per-face path resumes unchanged.
    func setVertexTints(_ rgba: [Float]) {
        guard vertexDrawCount > 0, rgba.count == vertexDrawCount * 8 else {
            vertexTintOverride = nil
            buildTintBuffer(faceTint: lastFaceTint, activeFaces: lastActiveFaces,
                            pulse: currentPulse())
            return
        }
        vertexTintOverride = rgba
        // ★ HANDS OFF THESE ONES (merge with `render-quality`, 2026-08-16).
        //
        // `tintsAreState` turns on §4's desaturation, which exists to tame the loud
        // GROUP PALETTE under the new world lighting. The Surface stage's tints are
        // not from that palette: `SurfaceTint` picks one blue in three exact depths
        // (0.06 / 0.25 / 0.72) chosen so "grouped", "sibling" and "selected" are
        // told apart at a glance, and the group hue it blends in is already muted at
        // source. Desaturating them would lift all three toward clay and collapse
        // the very distinction they encode.
        //
        // This setter bypasses `buildTintBuffer`, so without saying so it would
        // inherit whatever the last page set — which is a state nobody chose.
        tintsAreState = false
        tintBuffer = rgba.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
    }

    /// ★ §6 — THE CUT PLANE THE FRAGMENT STAGE TESTS. `plane` is
    /// (normal.xyz, -dot(normal, point)) in MODEL space. Disabled draws exactly as
    /// before, so every other page is untouched.
    func setCutPlane(_ plane: SIMD4<Float>, selected: SIMD4<Float>,
                     sibling: SIMD4<Float>, enabled: Bool,
                     pickGroups: [[SIMD4<Float>]] = []) {
        var u = CutUniformsSwift(plane: plane, colSelected: selected,
                                 colSibling: sibling, enabled: enabled ? 1 : 0)
        // Flatten the picked pieces' half-space chains, bounded at 4 groups of 4.
        var flat: [SIMD4<Float>] = []
        var counts = SIMD4<Int32>.zero
        let groups = Array(pickGroups.prefix(4))
        for (i, g) in groups.enumerated() {
            let planes = Array(g.prefix(4))
            counts[i] = Int32(planes.count)
            flat += planes
        }
        withUnsafeMutableBytes(of: &u.pickPlanes) { raw in
            let dst = raw.bindMemory(to: SIMD4<Float>.self)
            for (i, pl) in flat.prefix(16).enumerated() { dst[i] = pl }
        }
        u.pickCounts = counts
        u.pickGroups = Int32(groups.count)
        cutUniforms = u
    }

    func setHighlights(faceTint: [FaceID: SIMD4<Float>], activeFaces: Set<FaceID>) {
        lastFaceTint = faceTint       // remembered so a detent pulse can layer over them (item 2)
        lastActiveFaces = activeFaces
        tintsAreState = true          // §4: these are ROLES (selection, anchor, protect, lattice)
        buildTintBuffer(faceTint: faceTint, activeFaces: activeFaces, pulse: currentPulse())
    }

    /// Start a brief highlight pulse of `faceID` (device round 3, item 2), the in-viewer feedback
    /// when a design-box face snaps to that part face. Re-triggering (a fresh snap) restarts the
    /// envelope. The caller (`apply`) flips the view to continuous redraw; the pulse ends itself.
    func beginDetentPulse(faceID: FaceID) {
        pulseFaceID = faceID
        pulseStart = CACurrentMediaTime()
        isPulsing = true
        buildTintBuffer(faceTint: lastFaceTint, activeFaces: lastActiveFaces, pulse: currentPulse())
    }

    /// The pulse override for the tint buffer at the current time: the pulsed face id + a gold rgba
    /// whose alpha follows a sin envelope (0 → peak → 0) over `pulseDuration`. Nil when no pulse is
    /// active. Ends the pulse (clears `isPulsing`) once the envelope completes.
    private func currentPulse() -> (face: FaceID, color: SIMD4<Float>)? {
        guard let f = pulseFaceID else { return nil }
        let t = Float((CACurrentMediaTime() - pulseStart) / pulseDuration)
        if t >= 1 || t < 0 { pulseFaceID = nil; isPulsing = false; return nil }
        let env = sin(Float.pi * t)                       // 0 → 1 → 0 across the pulse
        let gold = SIMD4<Float>(1.0, 0.82, 0.35, 0.9 * env)
        return (f, gold)
    }

    /// Advance the detent pulse: re-upload the tint buffer for the current envelope value. Returns
    /// true while the pulse is still animating (so `draw` keeps requesting frames).
    @discardableResult
    func stepPulse() -> Bool {
        guard isPulsing else { return false }
        let pulse = currentPulse()                        // may clear `isPulsing` when it completes
        buildTintBuffer(faceTint: lastFaceTint, activeFaces: lastActiveFaces, pulse: pulse)
        return isPulsing
    }

    /// M7.8 stress overlay: upload per-flat-vertex colors (alpha 1) directly as the
    /// tint buffer, so the fragment shader mixes them over the clay. `colors` must
    /// have one entry per flat vertex (`vertexDrawCount`); a mismatch is ignored.
    func setStressTints(_ colors: [SIMD4<Float>]) {
        guard vertexDrawCount > 0, colors.count == vertexDrawCount else { return }
        tintsAreState = false         // §4: a DATA ramp — its hue is the datum, hands off
        // ★ STRIDE 8, AND THE INDEXING WAS WRONG — A BUG THIS MERGE EXPOSED.
        //
        // §6 widened the tint buffer to EIGHT floats per vertex (rgba + the flags
        // that carry `member`), and widened the allocation here to match — but left
        // the loop writing at `v * 4`. So every colour after the first landed in the
        // previous vertex's FLAGS slot: the stress/lattice ramp was scrambled, and
        // the flags channel filled with colour data, which is what drives the cut's
        // per-fragment test. The Surface stage never showed it because it uses
        // `setVertexTints` (already 8-wide); the lattice proxy and the smoothing
        // brush go through here.
        //
        // It surfaced because `render-quality` touched the same line for its own
        // reason and the conflict put the two numbers side by side.
        var tints = [Float](repeating: 0, count: vertexDrawCount * 8)
        for v in 0..<vertexDrawCount {
            let c = colors[v]
            tints[v * 8] = c.x; tints[v * 8 + 1] = c.y
            tints[v * 8 + 2] = c.z; tints[v * 8 + 3] = c.w
            // flags stay zero: a data ramp is on no region's face.
        }
        tintBuffer = tints.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
    }

    /// M7.viz.3 flex: upload the per-flat-vertex displacement vectors (flattened xyz,
    /// mm) that the vertex shader scales by `flexScale`. `disp` must have one xyz per
    /// flat vertex (`vertexDrawCount * 3`); a mismatch is ignored (keeps the zeros).
    func setFlexDisplacements(_ disp: [Float]) {
        guard vertexDrawCount > 0, disp.count == vertexDrawCount * 3 else { return }
        flexBuffer = disp.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
    }

    /// M7.viz.3 flex: the current displacement scale (exaggeration·amplitude); 0 rests.
    func setFlexScale(_ s: Float) { flexScale = s }

    /// M7.viz.4 load-path: upload the line segments (flattened `[x,y,z,r,g,b,a]` per
    /// vertex, two vertices per glyph) to draw over the variant. A malformed buffer
    /// (not a multiple of the stride-7 layout) is ignored. Empty clears the overlay.
    /// Builds BOTH the thick-ribbon geometry (the primary draw) and keeps the raw line
    /// buffer as the fallback for when the ribbon pipeline is unavailable.
    /// ★ §6(b) — upload the B-rep edge set. `verts` is the raw xyz line list from
    /// `SurfaceWireframe.edges(of:)`; the colour is applied here so the geometry
    /// stays a pure function of the mesh. Empty clears the layer.
    /// ★ TWO COLOURS IN ONE BUFFER. The colour is packed PER VERTEX, so the
    /// vertices past `accentFrom` can carry a different one at no cost: the B-rep
    /// wireframe stays a quiet structural blue while the pattern preview — the
    /// thing being decided right now — is drawn in a colour that reads instantly
    /// against it. Washed out, a preview cannot answer "what will it look like".
    /// ★ §6/§7 — THE CUT/PATTERN RIBBONS: triangles, not lines, so they are wide
    /// enough to see, drawn depth-ALWAYS so the surface they lie on cannot swallow
    /// them. This is the layer that answers "I want to see the pattern much easier".
    func setCutRibbon(_ verts: [Float], rgba: SIMD4<Float>) {
        guard !verts.isEmpty, verts.count % 3 == 0 else {
            ribbonBuffer = nil; ribbonVertexCount = 0; return
        }
        var packed: [Float] = []
        packed.reserveCapacity(verts.count / 3 * 7)
        var i = 0
        while i + 2 < verts.count {
            packed.append(verts[i]); packed.append(verts[i + 1]); packed.append(verts[i + 2])
            packed.append(rgba.x * rgba.w); packed.append(rgba.y * rgba.w)
            packed.append(rgba.z * rgba.w); packed.append(rgba.w)
            i += 3
        }
        ribbonVertexCount = packed.count / 7
        ribbonBuffer = packed.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
    }

    func setWireframe(_ verts: [Float], rgba: SIMD4<Float>,
                      accentFrom: Int = .max, accent: SIMD4<Float> = .zero) {
        guard !verts.isEmpty, verts.count % 3 == 0 else {
            wireframeBuffer = nil; wireframeVertexCount = 0
            wideWireBuffer = nil; wideWireVertexCount = 0; return
        }
        var packed: [Float] = []
        packed.reserveCapacity(verts.count / 3 * 7)
        var i = 0
        while i + 2 < verts.count {
            packed.append(verts[i]); packed.append(verts[i + 1]); packed.append(verts[i + 2])
            let c = i >= accentFrom ? accent : rgba
            // Premultiplied — the ground pipeline blends src .one / dst 1−srcA.
            packed.append(c.x * c.w)
            packed.append(c.y * c.w)
            packed.append(c.z * c.w)
            packed.append(c.w)
            i += 3
        }
        wireframeVertexCount = packed.count / 7
        wireframeBuffer = packed.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }

        // ★ AND THE SAME SEGMENTS AS QUADS. Six vertices per segment, each carrying
        // BOTH endpoints plus which corner it is — the vertex stage needs both ends
        // to know which way is across the line on screen.
        var quads: [Float] = []
        quads.reserveCapacity(verts.count / 6 * 6 * 12)
        var j = 0
        while j + 5 < verts.count {
            let ax = verts[j], ay = verts[j + 1], az = verts[j + 2]
            let bx = verts[j + 3], by = verts[j + 4], bz = verts[j + 5]
            let c = j >= accentFrom ? accent : rgba
            // side.x: 0 = a end, 1 = b end. side.y: which side of the line.
            let corners: [(Float, Float)] = [(0, -1), (0, 1), (1, -1),
                                             (0, 1), (1, 1), (1, -1)]
            for (endFlag, sideFlag) in corners {
                quads += [ax, ay, az, bx, by, bz,
                          c.x * c.w, c.y * c.w, c.z * c.w, c.w,
                          endFlag, sideFlag]
            }
            j += 6
        }
        wideWireVertexCount = quads.count / 12
        wideWireBuffer = quads.isEmpty ? nil : quads.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
    }

    func setLoadPath(_ verts: [Float]) {
        guard !verts.isEmpty, verts.count % 7 == 0, verts.count % 14 == 0 else {
            clearLoadPath(); return
        }
        loadPathVertexCount = verts.count / 7
        loadPathBuffer = verts.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
        buildLoadPathRibbon(from: verts)
    }

    /// Expand each stride-7 segment pair (p0, p1) into a 6-vertex ribbon (two triangles)
    /// in the stride-12 layout the ribbon pipeline consumes: both endpoints on every
    /// vertex (so the shader can billboard to a screen-space width), a side (±1) and an
    /// end flag (0/1), plus the glyph's colour. Uses the first vertex's colour for the
    /// whole ribbon (the two endpoints of a glyph share it).
    private func buildLoadPathRibbon(from verts: [Float]) {
        let glyphCount = verts.count / 14
        var out = [Float](); out.reserveCapacity(glyphCount * 6 * 12)
        func push(_ sx: Float, _ sy: Float, _ sz: Float, _ ex: Float, _ ey: Float, _ ez: Float,
                  _ side: Float, _ end: Float, _ r: Float, _ g: Float, _ b: Float, _ a: Float) {
            out.append(sx); out.append(sy); out.append(sz)
            out.append(ex); out.append(ey); out.append(ez)
            out.append(side); out.append(end)
            out.append(r); out.append(g); out.append(b); out.append(a)
        }
        for gi in 0..<glyphCount {
            let b = gi * 14
            let sx = verts[b], sy = verts[b + 1], sz = verts[b + 2]
            let r = verts[b + 3], g = verts[b + 4], bl = verts[b + 5], a = verts[b + 6]
            let ex = verts[b + 7], ey = verts[b + 8], ez = verts[b + 9]
            // Two triangles: (start-, start+, end-) and (end-, start+, end+).
            push(sx, sy, sz, ex, ey, ez, -1, 0, r, g, bl, a)
            push(sx, sy, sz, ex, ey, ez,  1, 0, r, g, bl, a)
            push(sx, sy, sz, ex, ey, ez, -1, 1, r, g, bl, a)
            push(sx, sy, sz, ex, ey, ez, -1, 1, r, g, bl, a)
            push(sx, sy, sz, ex, ey, ez,  1, 0, r, g, bl, a)
            push(sx, sy, sz, ex, ey, ez,  1, 1, r, g, bl, a)
        }
        loadPathRibbonVertexCount = out.count / 12
        loadPathRibbonBuffer = out.isEmpty ? nil : out.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
    }

    /// M7.viz.4 load-path: the current flow-animation phase (scrolls the traveling dash).
    func setLoadPathFlow(_ phase: Float) { loadPathFlow = phase }

    /// Load-path FLOW (handoff 070): upload the comet-arrow tube geometry (pos+rgba,
    /// stride 7) for THIS frame. Rebuilt each animation tick from the model's comet
    /// frames, so this is called ~30×/s while the overlay animates. Empty clears it.
    func setLoadFlow(_ verts: [Float]) {
        guard !verts.isEmpty, verts.count % 7 == 0 else {
            loadFlowBuffer = nil; loadFlowVertexCount = 0; return
        }
        loadFlowVertexCount = verts.count / 7
        loadFlowBuffer = verts.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
    }

    /// Load-path FLOW: upload the faint full-path guide lines (pos+rgba, stride 7,
    /// drawn `.line`). Uploaded once per selection (the routes don't move). Empty clears.
    func setFlowGuides(_ verts: [Float]) {
        guard !verts.isEmpty, verts.count % 7 == 0, verts.count % 14 == 0 else {
            flowGuideBuffer = nil; flowGuideVertexCount = 0; return
        }
        flowGuideVertexCount = verts.count / 7
        flowGuideBuffer = verts.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
    }

    /// Load-path FLOW: the body opacity (1 opaque; < 1 draws the mesh translucent so
    /// the flow shows through — the x-ray / stress body modes).
    func setBodyAlpha(_ a: Float) { bodyAlpha = min(1, max(0, a)) }

    /// Load-path FLOW: drop the comet geometry + guides (overlay off / stale variant).
    func clearLoadFlow() {
        loadFlowBuffer = nil; loadFlowVertexCount = 0
        flowGuideBuffer = nil; flowGuideVertexCount = 0
        bodyAlpha = 1
    }

    /// M7.viz.4 load-path: drop the overlay (toggled off / variant without a field).
    func clearLoadPath() {
        loadPathBuffer = nil; loadPathVertexCount = 0
        loadPathRibbonBuffer = nil; loadPathRibbonVertexCount = 0
    }

    /// M7.viz.3 flex: drop back to rest — re-zero the displacement buffer (so a stale
    /// variant's vectors can't leak) and clear the scale.
    func resetFlex() {
        flexScale = 0
        guard vertexDrawCount > 0 else { flexBuffer = nil; return }
        let zeros = [Float](repeating: 0, count: vertexDrawCount * 3)
        flexBuffer = zeros.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
    }

    /// M7.8 morph scrub: reveal fragments up to `fraction` of the mesh's model-Y
    /// extent (1 = fully formed). Enabled only while scrubbing (< 1).
    func setReveal(_ fraction: Float) {
        let f = min(1, max(0, fraction))
        let minY = mesh?.bounds.min.y ?? 0
        let maxY = mesh?.bounds.max.y ?? 1
        revealParams = SIMD4<Float>(f, minY, maxY, f < 0.999 ? 1 : 0)
    }

    private func buildIDBuffer() {
        guard vertexDrawCount > 0, let mesh, mesh.flat.positions.count == vertexDrawCount * 3 else {
            idVertexBuffer = nil; return
        }
        // Per vertex: 3 float positions (bit-cast) + 1 uint face id → stride 16.
        var packed = [UInt32](repeating: 0, count: vertexDrawCount * 4)
        for v in 0..<vertexDrawCount {
            packed[v * 4] = mesh.flat.positions[v * 3].bitPattern
            packed[v * 4 + 1] = mesh.flat.positions[v * 3 + 1].bitPattern
            packed[v * 4 + 2] = mesh.flat.positions[v * 3 + 2].bitPattern
            packed[v * 4 + 3] = v < flatFaceIDs.count ? flatFaceIDs[v] : idBackground
        }
        idVertexBuffer = packed.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
    }

    /// Paint mode (handoff 2026-07-25): replace the per-triangle face ids the id-pass PICK and the
    /// highlight TINT read with `perTriangle` (native ids + painted overrides), so a painted region
    /// behaves as ONE face — the live paint highlight, and picking a painted triangle returns its
    /// painted id. `perTriangle` must match `mesh.faceIDs` in length; empty / mismatched is ignored
    /// (native ids stand). Passing the native `mesh.faceIDs` back restores them (paint erased away).
    func setEffectiveFaceIDs(_ perTriangle: [Int32]) {
        guard let mesh, !perTriangle.isEmpty, perTriangle.count == mesh.faceIDs.count else { return }
        flatFaceIDs = perTriangle.flatMap { id -> [UInt32] in
            let u = UInt32(bitPattern: id); return [u, u, u]
        }
        buildIDBuffer()
        buildTintBuffer(faceTint: lastFaceTint, activeFaces: lastActiveFaces, pulse: currentPulse())
    }

    private func buildTintBuffer(faceTint: [FaceID: SIMD4<Float>], activeFaces: Set<FaceID>,
                                 pulse: (face: FaceID, color: SIMD4<Float>)? = nil) {
        guard vertexDrawCount > 0 else { tintBuffer = nil; return }
        // ★ THE OVERRIDE WINS. Otherwise any selection change downstream would
        // rebuild from the face map and silently erase the two halves.
        if let v = vertexTintOverride, v.count == vertexDrawCount * 8 {
            tintBuffer = v.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
            }
            return
        }
        var tints = [Float](repeating: 0, count: vertexDrawCount * 8)
        for v in 0..<vertexDrawCount {
            let fid = v < flatFaceIDs.count ? FaceID(bitPattern: flatFaceIDs[v]) : -1
            // The detent PULSE overrides its face's tint with the gold envelope colour, bypassing
            // the selection alpha-clamp so the flash can outshine a highlight (item 2).
            if let pulse, fid == pulse.face {
                let c = pulse.color
                tints[v * 8] = c.x; tints[v * 8 + 1] = c.y
                tints[v * 8 + 2] = c.z; tints[v * 8 + 3] = c.w
                continue
            }
            guard var c = faceTint[fid] else { continue }
            c.w = activeFaces.contains(fid) ? 0.75 : 0.45   // active group brighter
            tints[v * 8] = c.x; tints[v * 8 + 1] = c.y
            tints[v * 8 + 2] = c.z; tints[v * 8 + 3] = c.w
        }
        tintBuffer = tints.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspect = size.height > 0 ? Float(size.width / size.height) : 1
    }

    func draw(in view: MTKView) {
        let wasAnimating = isSettling || isPulsing
        if isSettling { stepSettle() }
        if isPulsing { stepPulse() }   // advance the detent flash (item 2), re-uploading its tint
        guard let cmd = queue.makeCommandBuffer() else { return }
        // One signpost interval per drawn frame (handoff 134). The view is on-demand —
        // paused at rest, one frame per camera change while orbiting — so the DENSITY
        // of these intervals is itself the "at rest vs during orbit" measurement, and
        // each interval's span is that frame's cost.
        let spid = OSSignpostID(log: viewerFrameSignpost, object: self)
        os_signpost(.begin, log: viewerFrameSignpost, name: "viewer_frame", signpostID: spid)
        if let rpd = view.currentRenderPassDescriptor {
            encode(into: rpd, aspect: aspect, into: cmd, drawStage: true)
        }
        os_signpost(.end, log: viewerFrameSignpost, name: "viewer_frame", signpostID: spid,
                    "draws=%d verts=%d", lastFrameDrawCalls, lastFrameVertices)
        if let drawable = view.currentDrawable { cmd.present(drawable) }
        cmd.commit()
        // The settle/pulse finished this frame → return to on-demand drawing (battery).
        if wasAnimating && !isSettling && !isPulsing {
            view.isPaused = true
            view.enableSetNeedsDisplay = true
        }
    }

    // ── frame cost instrumentation (handoff 134, item 3) ──────────────────────
    // Every draw in a frame goes through `countedDraw`, so the per-frame draw-call
    // count and vertex total are MEASURED rather than hand-counted from the encode
    // path (which branches on a dozen pieces of viewer state). Two Ints and an
    // increment per draw — nothing here changes what is drawn or in what order.

    /// Draw calls encoded in the most recently completed frame (all passes).
    private(set) var lastFrameDrawCalls = 0
    /// Vertices submitted in the most recently completed frame (all passes).
    private(set) var lastFrameVertices = 0
    /// Whether the AO pass ran in the most recently ENCODED frame. See `aoBufferDump`.
    private(set) var lastFrameHadAO = false
    private var frameDrawCalls = 0
    private var frameVertices = 0

    private func countedDraw(_ enc: MTLRenderCommandEncoder, _ type: MTLPrimitiveType,
                             _ count: Int) {
        frameDrawCalls += 1
        frameVertices += count
        enc.drawPrimitives(type: type, vertexStart: 0, vertexCount: count)
    }

    /// Encode the shaded mesh draw into an arbitrary render pass. Shared by the on-screen
    /// `draw(in:)` and the headless `renderOffscreen`. `drawStage` gates the CAD-stage backdrop
    /// (item 9): ON for the live viewer, OFF for offscreen output (thumbnails / exported video
    /// keep their own clear colour) — so the backdrop is a live-viewer treatment only.
    private func encode(into rpd: MTLRenderPassDescriptor, aspect: Float, into cmd: MTLCommandBuffer,
                        drawStage: Bool) {
        frameDrawCalls = 0
        frameVertices = 0
        defer { lastFrameDrawCalls = frameDrawCalls; lastFrameVertices = frameVertices }
        guard vertexDrawCount > 0, let vbuf = vertexBuffer, let tbuf = tintBuffer,
              let fbuf = flexBuffer else { return }
        var uniforms = makeUniforms(aspect: aspect)

        // DEPTH PREPASS (items 7+8, parts b+c): when a translucent volume is present, capture the
        // opaque part's eye-space depth into a texture FIRST (its own render pass — you cannot read
        // the depth attachment you are rendering into), so the contact pass below can add a contact
        // line + interior occlusion where the volume meets the part. Gated on there being a volume
        // AND both contact pipelines having built, so it costs NOTHING otherwise, and — like every
        // other pass here — runs only on a redraw, never on an idle frame (the 108 rule).
        //
        // ★ RENDER QUALITY (§1/§3a): the same pass is now ALSO the G-buffer SSAO and the
        // edge detector read, so it runs whenever either of those is on as well. One
        // rasterisation of the part serves the contact read, the occlusion and the
        // edges — the alternative was three.
        var sceneDepthTex: MTLTexture? = nil
        var aoTex: MTLTexture? = nil
        var gbuffer: (depth: MTLTexture, normal: MTLTexture, albedo: MTLTexture)? = nil
        var haveAO = false
        let wantsContact = contactShadingEnabled && (designBoxFaceCount > 0 || clearanceFaceCount > 0)
            && contactPipeline != nil
        // ★ AND WHENEVER A LATTICE IS IN THE FRAME (unified shading). The lattice's
        // pixels are PRODUCED by the prepass now — it is not an optional quality
        // treatment for them, it is where they come from.
        let wantsLattice = latticeInFrame && latticeGBufferPipeline != nil
            && latticeShadePipeline != nil
        let wantsAO = !quality.isDisjoint(with: [.ambientOcclusion, .edges]) && aoPipeline != nil
        // The G-buffer is single-sampled, so it is sized from the RESOLVE target when
        // the colour pass is multisampled (§3b) — `resolveTexture` is the 1× surface.
        let colorTex = rpd.colorAttachments[0].resolveTexture ?? rpd.colorAttachments[0].texture
        // The main colour target's size — what `ShadeParams.ao.zw` is expressed in, so
        // the G-buffer is free to be smaller (see `latticeGBufferMaxPixels`).
        var mainSize: (w: Int, h: Int) = (colorTex?.width ?? 1, colorTex?.height ?? 1)
        gbufferScale = SIMD2<Float>(1, 1)
        if wantsContact || wantsAO || wantsLattice, let ctex = colorTex {
            let g = gbufferSize(width: ctex.width, height: ctex.height)
            mainSize = (ctex.width, ctex.height)
            gbufferScale = SIMD2<Float>(Float(g.w) / Float(Swift.max(ctex.width, 1)),
                                        Float(g.h) / Float(Swift.max(ctex.height, 1)))
            gbuffer = encodeDepthPrepass(width: g.w, height: g.h,
                                         uniforms: uniforms, aspect: aspect, into: cmd)
            sceneDepthTex = gbuffer?.depth
            if wantsAO, let gb = gbuffer {
                aoTex = encodeAO(gbuffer: gb, aspect: aspect, into: cmd)
                haveAO = aoTex != nil
            }
        }
        // ★ WHETHER THE AO PASS ACTUALLY RAN THIS FRAME. `aoBlurTex` outlives a frame,
        // so a reader that just grabs it can be handed the PREVIOUS frame's occlusion
        // and never know — which is exactly how a §3(b) "before" capture comes back
        // showing the "after"'s buffer. `aoBufferDump` refuses when this is false.
        lastFrameHadAO = haveAO
        var shade = makeShadeParams(mainSize: haveAO ? mainSize : nil)

        // ★ §3c: the footprint, in its OWN pass before the main one (a render pass
        // cannot sample the texture another encoder in the same pass is writing). The
        // stage uniform is built here too, so the rectangle the footprint is rendered
        // into is literally the same value the stage fragment maps its floor hit with.
        let stageUniforms = makeStageUniforms(aspect: aspect)
        var shadowFootprint: MTLTexture? = nil
        if drawStage, quality.contains(.contactShadow) {
            shadowFootprint = contactShadowTexture(floorRect: stageUniforms.shadowRect, into: cmd)
        }

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        // CAD-STAGE backdrop (item 9): the shaded room, drawn FIRST — depth-always + no write
        // (`lineOverlayDepthState`), so the part / box / grid drawn after occlude it. Its uniform
        // is rebuilt only here, on a redraw (camera/mesh change), never on an idle frame.
        if drawStage, let spipe = stagePipeline {
            var su = stageUniforms
            if shadowFootprint != nil { su.shadowStrength = Self.contactShadowStrength }
            enc.setRenderPipelineState(spipe)
            enc.setDepthStencilState(lineOverlayDepthState)
            enc.setVertexBytes(&su, length: MemoryLayout<StageUniforms>.stride, index: 0)
            enc.setFragmentBytes(&su, length: MemoryLayout<StageUniforms>.stride, index: 0)
            enc.setFragmentTexture(shadowFootprint ?? neutralShadowTexture(), index: 0)
            countedDraw(enc, .triangle, 3)
        }

        // Load-flow body modes (handoff 070): a body alpha < 1 draws the mesh through
        // the translucent pipeline (premultiplied "over", no depth write) so the comet
        // arrows show through the walls; alpha 1 is the unchanged opaque draw.
        let translucent = bodyAlpha < 0.999
        var bodyAlphaVal = bodyAlpha
        enc.setRenderPipelineState(translucent ? (translucentBodyPipeline ?? pipeline) : pipeline)
        enc.setDepthStencilState(translucent ? translucentBodyDepthState : depthState)
        enc.setCullMode(.none)  // show both sides regardless of winding
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBuffer(tbuf, offset: 0, index: 2)
        enc.setVertexBuffer(fbuf, offset: 0, index: 3)   // M7.viz.3 flex displacement
        enc.setVertexBytes(&uniforms, length: MemoryLayout<ViewerUniforms>.stride, index: 1)
        enc.setFragmentBytes(&revealParams, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.setFragmentBytes(&bodyAlphaVal, length: MemoryLayout<Float>.stride, index: 1)
        // Render quality: the AO/edge texture and the strengths that scale it.
        // `viewer_fragment` DECLARES both, so both must be bound on every path —
        // Metal drops the draw on a missing binding, the trap `contact_fragment` and
        // `loadpath_fragment` each document above. With no AO this is the neutral
        // 1×1 and zero strengths, i.e. an exact identity.
        enc.setFragmentBytes(&shade, length: MemoryLayout<ShadeParams>.stride, index: 2)
        enc.setFragmentTexture(aoTex ?? neutralAOTexture(), index: 0)
        // ★ §6 — the cut's half-space, tested per fragment. INDEX 3: the shading
        // above took 2 in the merge, and the same rule applies — the shader declares
        // it, so it is bound on every path.
        var cu = cutUniforms
        enc.setFragmentBytes(&cu, length: MemoryLayout<CutUniformsSwift>.stride, index: 3)
        countedDraw(enc, .triangle, vertexDrawCount)

        // ★ THE LATTICE, IN THIS PASS, IMMEDIATELY AFTER THE SHELL (task
        // 2026-08-18-unified-shading). A DEFERRED shade of what the prepass marched:
        // one full-screen triangle, no second march, the shell's `to_material`, the
        // shell's AO/edge texture and the shell's depth fade — and a fragment depth
        // write into the SHARED depth buffer, so every overlay drawn below (the ground
        // grid, the design box, the clearance volumes, the wireframe) is occluded by
        // the struts exactly as it is by the body. Under the old arrangement the
        // lattice was a separate transparent MTKView with no depth attachment at all,
        // composited OVER this frame: it could not be occluded by anything, could not
        // receive this frame's occlusion, and was lit by its own key light. That is
        // what "pasted on" was.
        if wantsLattice, let lpipe = latticeShadePipeline, let gb = gbuffer {
            var lu = LatShadeUniforms()
            let proj = camera.projectionMatrix(aspect: aspect)
            // The depth curve, read straight off the matrix the frame is drawn with:
            // ndcDepth = −P[2][2] + P[3][2]/eyeZ. Deriving it here rather than
            // re-deriving near/far means it cannot drift from the projection.
            lu.depth = SIMD4<Float>(-proj.columns.2.z, proj.columns.3.z,
                                    Float(mainSize.w), Float(mainSize.h))
            lu.proj = SIMD4<Float>(1 / Swift.max(proj.columns.0.x, 1e-6),
                                   1 / Swift.max(proj.columns.1.y, 1e-6),
                                   Float(gb.depth.width), Float(gb.depth.height))
            // World from eye, rotation only: the material's light directions are
            // WORLD-space constants, and the eye-space normal in the G-buffer has to
            // arrive in their frame or the highlight follows the camera — the exact
            // defect `render-quality` §2 fixed for the shell.
            let v = camera.viewMatrix()
            lu.worldFromEyeRot = simd_float4x4(columns: (
                SIMD4<Float>(v.columns.0.x, v.columns.1.x, v.columns.2.x, 0),
                SIMD4<Float>(v.columns.0.y, v.columns.1.y, v.columns.2.y, 0),
                SIMD4<Float>(v.columns.0.z, v.columns.1.z, v.columns.2.z, 0),
                SIMD4<Float>(0, 0, 0, 1)))
            lu.misc = SIMD4<Float>(Self.sceneDepthFar,
                                   quality.contains(.edges) ? Self.edgeStrength : 0, 0, 0)
            enc.setRenderPipelineState(lpipe)
            enc.setDepthStencilState(depthState)     // .less, write on — the shared buffer
            enc.setFragmentBytes(&lu, length: MemoryLayout<LatShadeUniforms>.stride, index: 0)
            enc.setFragmentBytes(&shade, length: MemoryLayout<ShadeParams>.stride, index: 2)
            enc.setFragmentTexture(aoTex ?? neutralAOTexture(), index: 0)
            enc.setFragmentTexture(gb.depth, index: 1)
            enc.setFragmentTexture(gb.normal, index: 2)
            enc.setFragmentTexture(gb.albedo, index: 3)
            countedDraw(enc, .triangle, 3)
        }

        // Ground grid + contact shadow (M7.6 D2), drawn after the opaque mesh so it
        // blends, depth-tested so the part occludes it, depth-write off.
        if showGround, let gpipe = groundPipeline {
            var gmvp = groundMVP(aspect: aspect)
            enc.setRenderPipelineState(gpipe)
            enc.setDepthStencilState(groundDepthState)
            enc.setVertexBytes(&gmvp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            if let sbuf = groundShadowBuffer, groundShadowCount > 0 {
                enc.setVertexBuffer(sbuf, offset: 0, index: 0)
                countedDraw(enc, .triangle, groundShadowCount)
            }
            if let lbuf = groundLineBuffer, groundLineCount > 0 {
                enc.setVertexBuffer(lbuf, offset: 0, index: 0)
                countedDraw(enc, .line, groundLineCount)
            }
        }

        // M7.dom-app design-box gizmo: translucent box faces + bright edges, drawn under the
        // MESH's mvp (uniforms.mvp) so they lock to the part and settle with it. Depth-tested
        // (groundDepthState: the part occludes the box's far faces; no depth write so the box
        // never hides the part). The faces carry the contact treatment (parts b+c) when the
        // prepass ran; the edges stay crisp. See `encodeVolume`.
        encodeVolume(enc: enc, mvp: uniforms.mvp,
                     faceBuffer: designBoxFaceBuffer, faceCount: designBoxFaceCount,
                     lineBuffer: designBoxLineBuffer, lineCount: designBoxLineCount,
                     sceneDepthTex: wantsContact ? sceneDepthTex : nil)

        // Keep-clear v2 (Part 3): the clearance volumes — the SAME MODEL-space depth-tested pass
        // and the SAME contact variant as the design box (one shader, both consumers).
        encodeVolume(enc: enc, mvp: uniforms.mvp,
                     faceBuffer: clearanceFaceBuffer, faceCount: clearanceFaceCount,
                     lineBuffer: clearanceLineBuffer, lineCount: clearanceLineCount,
                     sceneDepthTex: wantsContact ? sceneDepthTex : nil)
        // Round-2 L21: the x-ray edge pass — depth-ALWAYS, low alpha — so a primitive
        // buried inside the opaque body (fresh primitives spawn at the model centre)
        // still reads as a ghost wireframe instead of rendering as nothing.
        if clearanceXrayCount > 0, let xbuf = clearanceXrayBuffer, let gpipe = groundPipeline {
            var m = uniforms.mvp
            enc.setRenderPipelineState(gpipe)
            enc.setDepthStencilState(lineOverlayDepthState)
            enc.setVertexBuffer(xbuf, offset: 0, index: 0)
            enc.setVertexBytes(&m, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            countedDraw(enc, .line, clearanceXrayCount)
        }

        // Load-path overlay (M7.viz.4): principal-stress-direction glyphs drawn under
        // the MESH's model·view·proj (uniforms.mvp) so they lock to the part (the ground
        // pass uses a world MVP). Drawn depth-ALWAYS (lineOverlayDepthState): the glyphs
        // sit at voxel centres inside the solid part, so a normal depth test hides them
        // behind the surface (nothing shows). Overlaying them on top is the intent —
        // trace the load path through the structure.
        //
        // PRIMARY: thick, animated ribbons (billboarded to a constant screen width, with
        // a bright dash flowing along each segment). FALLBACK: the 1px line pipeline when
        // the ribbon pipeline failed to build.
        if loadPathRibbonVertexCount > 0, let lpipe = loadPathPipeline, let rbuf = loadPathRibbonBuffer {
            var lpu = LoadPathUniforms(mvp: uniforms.mvp,
                                       params: SIMD4<Float>(aspect, Self.loadPathHalfWidth, loadPathFlow, 0))
            enc.setRenderPipelineState(lpipe)
            enc.setDepthStencilState(lineOverlayDepthState)   // depth-always: never hidden inside the part
            enc.setVertexBuffer(rbuf, offset: 0, index: 0)
            enc.setVertexBytes(&lpu, length: MemoryLayout<LoadPathUniforms>.stride, index: 1)
            // `loadpath_fragment` ALSO declares `LPUniforms u [[buffer(1)]]` (it reads the
            // flow phase for the traveling dash), so the fragment index-1 buffer must be
            // bound too — without this Metal aborts: "missing Buffer binding at index 1".
            enc.setFragmentBytes(&lpu, length: MemoryLayout<LoadPathUniforms>.stride, index: 1)
            countedDraw(enc, .triangle, loadPathRibbonVertexCount)
        } else if loadPathVertexCount > 0, let lpipe = groundPipeline, let lbuf = loadPathBuffer {
            var mvp = uniforms.mvp
            enc.setRenderPipelineState(lpipe)
            enc.setDepthStencilState(lineOverlayDepthState)
            enc.setVertexBuffer(lbuf, offset: 0, index: 0)
            enc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            countedDraw(enc, .line, loadPathVertexCount)
        }

        // ★ §6(b) — THE B-REP WIREFRAME, DEPTH-ALWAYS.
        //
        // ★ IT WAS DEPTH-TESTED AND THEREFORE INVISIBLE. A B-rep edge lies exactly
        // ON the two faces that meet at it, so at equal depth it z-fights the body
        // and loses almost every fragment: the maintainer turned the switch on and
        // reported "there is no difference in the view of the model with it on" —
        // and he was right, the pass was running and drawing nothing you could see.
        // Depth-ALWAYS is what every other line overlay here uses (the load path,
        // the flow guides, the clearance x-ray) for exactly this reason.
        if wideWireVertexCount > 0, let wpipe = wideLinePipeline, let wbuf = wideWireBuffer {
            // ★ WIDTH IN SCREEN SPACE, WITH A FALLOFF PAST THE FRAMING DISTANCE.
            //
            // The half-width is in NDC, so it is the same apparent thickness at any
            // zoom — which is the point. Beyond the distance the viewer frames the
            // part at, it tapers: a part zoomed far out would otherwise become a mat
            // of lines with no shape left in it.
            struct WU { var mvp: simd_float4x4; var width: SIMD4<Float> }
            let radius = max(mesh?.bounds.radius ?? 1, 1e-3)
            let framing = radius * 2.6          // roughly how the viewer frames a part
            let zoomOut = max(camera.distance / framing, 1)
            let halfWidth = 0.0022 / min(zoomOut * zoomOut, 6)
            var wu = WU(mvp: uniforms.mvp,
                        width: SIMD4<Float>(halfWidth, max(aspect, 1e-3), 0, 0))
            enc.setRenderPipelineState(wpipe)
            if xrayLines {
                enc.setDepthStencilState(lineOverlayDepthState)
            } else {
                enc.setDepthStencilState(depthState)
                enc.setDepthBias(-2.0, slopeScale: -1.5, clamp: 0)
            }
            enc.setVertexBuffer(wbuf, offset: 0, index: 0)
            enc.setVertexBytes(&wu, length: MemoryLayout<WU>.stride, index: 1)
            countedDraw(enc, .triangle, wideWireVertexCount)
            if !xrayLines { enc.setDepthBias(0, slopeScale: 0, clamp: 0) }
        } else if wireframeVertexCount > 0, let wpipe = groundPipeline,
                  let wbuf = wireframeBuffer {
            var mvp = uniforms.mvp
            enc.setRenderPipelineState(wpipe)
            // ★ TWO DIFFERENT VIEWS, AND THEY WERE ONE (maintainer: "the wireframe
            // is mixed with an x-ray view … xray view should be selectable").
            //
            //   WIREFRAME  depth-TESTED, with a depth BIAS. A B-rep edge lies
            //              exactly ON the faces that meet at it, so at equal depth
            //              it z-fights the body and loses — which is why this was
            //              depth-always in the first place. The bias nudges the
            //              lines toward the camera by a fraction of a depth unit:
            //              they win against the surface they lie on and are still
            //              HIDDEN by geometry genuinely in front. That is a
            //              wireframe.
            //   X-RAY      depth-ALWAYS: every edge shows through the solid. That
            //              is a different question and now a different switch.
            if xrayLines {
                enc.setDepthStencilState(lineOverlayDepthState)
            } else {
                enc.setDepthStencilState(depthState)
                enc.setDepthBias(-2.0, slopeScale: -1.5, clamp: 0)
            }
            enc.setVertexBuffer(wbuf, offset: 0, index: 0)
            enc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            countedDraw(enc, .line, wireframeVertexCount)
            // Restore: every later pass expects no bias.
            if !xrayLines { enc.setDepthBias(0, slopeScale: 0, clamp: 0) }
        }

        // ★ THE CUT / PATTERN RIBBONS, ON TOP OF EVERYTHING. Depth-ALWAYS: a
        // preview exists to be looked at, and one hidden behind the face it
        // describes answers no question.
        if ribbonVertexCount > 0, let rpipe = groundPipeline, let rbuf = ribbonBuffer {
            var mvp = uniforms.mvp
            enc.setRenderPipelineState(rpipe)
            enc.setDepthStencilState(lineOverlayDepthState)
            enc.setVertexBuffer(rbuf, offset: 0, index: 0)
            enc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            countedDraw(enc, .triangle, ribbonVertexCount)
        }

        // Load-path FLOW (handoff 070): the faint guide routes then the glowing comet
        // arrows, both under the MESH's mvp (locked to the part) and depth-ALWAYS (so
        // they read through/inside the translucent body — the same overlay treatment as
        // the ribbon draw). Additive `cometPipeline` makes the tubes glow.
        if let cpipe = cometPipeline {
            var mvp = uniforms.mvp
            enc.setRenderPipelineState(cpipe)
            enc.setDepthStencilState(lineOverlayDepthState)
            enc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            if let gbuf = flowGuideBuffer, flowGuideVertexCount > 0 {
                enc.setVertexBuffer(gbuf, offset: 0, index: 0)
                countedDraw(enc, .line, flowGuideVertexCount)
            }
            if let fbuf = loadFlowBuffer, loadFlowVertexCount > 0 {
                enc.setVertexBuffer(fbuf, offset: 0, index: 0)
                countedDraw(enc, .triangle, loadFlowVertexCount)
            }
        }
        enc.endEncoding()
    }

    private func makeUniforms(aspect: Float) -> ViewerUniforms {
        // Apply the settle rotation to the model, so the mesh (and the id pass)
        // transform with the part as it rotates onto the ground.
        let model = modelMatrix()
        let view = camera.viewMatrix()
        let mvp = camera.projectionMatrix(aspect: aspect) * view * model
        let vm = view * model                                   // normals: rotation of view·model
        let normal4 = simd_float4x4(columns: (
            SIMD4<Float>(vm.columns.0.x, vm.columns.0.y, vm.columns.0.z, 0),
            SIMD4<Float>(vm.columns.1.x, vm.columns.1.y, vm.columns.1.z, 0),
            SIMD4<Float>(vm.columns.2.x, vm.columns.2.y, vm.columns.2.z, 0),
            SIMD4<Float>(0, 0, 0, 1)))
        // Render quality §2: the WORLD normal basis — the model's rotation alone, with
        // the view left out. That single omission is the headlight fix: the light
        // directions in `viewer_fragment` are constants, so which space the normal
        // arrives in decides whether they are nailed to the camera or to the world.
        let worldNormal4 = simd_float4x4(columns: (
            SIMD4<Float>(model.columns.0.x, model.columns.0.y, model.columns.0.z, 0),
            SIMD4<Float>(model.columns.1.x, model.columns.1.y, model.columns.1.z, 0),
            SIMD4<Float>(model.columns.2.x, model.columns.2.y, model.columns.2.z, 0),
            SIMD4<Float>(0, 0, 0, 1)))
        let e = camera.eye
        return ViewerUniforms(mvp: mvp, normalMatrix: normal4,
                              flex: SIMD4<Float>(flexScale, 0, 0, 0),
                              worldNormalMatrix: worldNormal4,
                              model: model,
                              modelView: vm,
                              eye: SIMD4<Float>(e.x, e.y, e.z, 1))
    }

    /// The ground's MVP: plain camera view·projection (world-space floor).
    private func groundMVP(aspect: Float) -> simd_float4x4 {
        camera.projectionMatrix(aspect: aspect) * camera.viewMatrix()
    }

    /// The eye-space transform (view·model) for the settled part — used by the depth prepass and
    /// the contact pass to compute a fragment's eye-space depth (aspect-independent: aspect only
    /// enters the projection, not the view·model).
    private func modelViewMatrix() -> simd_float4x4 {
        camera.viewMatrix() * modelMatrix()
    }

    /// The contact-line feather + interior-occlusion falloff, in SCREEN PIXELS (the contact shader
    /// divides the eye-space gap by `fwidth` to work in pixel space). Scale-/resolution-independent:
    /// a crisp ~1.5 px line with a ~7 px occlusion falloff just inside it.
    static let contactFeatherPixels: Float = 1.5
    static let contactOcclusionPixels: Float = 7.0

    /// Fetch (re-creating on a size change) the depth-prepass colour + depth textures. `.private`
    /// (GPU-only): the prepass writes them and the contact pass reads them within one command
    /// buffer, so they never touch the CPU. Nil if the device can't allocate them.
    private func sceneDepthTextures(width: Int, height: Int)
        -> (color: MTLTexture, depth: MTLTexture, normal: MTLTexture, albedo: MTLTexture)? {
        if let c = sceneDepthColorTex, let z = sceneDepthZTex, let n = sceneNormalTex,
           let a = gbufferAlbedoTex, c.width == width, c.height == height {
            return (c, z, n, a)
        }
        let cd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.sceneDepthFormat, width: width, height: height, mipmapped: false)
        cd.usage = [.renderTarget, .shaderRead]
        cd.storageMode = .private
        let zd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.depthFormat, width: width, height: height, mipmapped: false)
        zd.usage = [.renderTarget]
        zd.storageMode = .private
        let nd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.gbufferNormalFormat, width: width, height: height, mipmapped: false)
        nd.usage = [.renderTarget, .shaderRead]
        nd.storageMode = .private
        let ad = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.gbufferAlbedoFormat, width: width, height: height, mipmapped: false)
        ad.usage = [.renderTarget, .shaderRead]
        ad.storageMode = .private
        guard let c = device.makeTexture(descriptor: cd), let z = device.makeTexture(descriptor: zd),
              let n = device.makeTexture(descriptor: nd), let a = device.makeTexture(descriptor: ad) else {
            return nil
        }
        sceneDepthColorTex = c; sceneDepthZTex = z; sceneNormalTex = n; gbufferAlbedoTex = a
        return (c, z, n, a)
    }

    // MARK: - the unified lattice layer (task 2026-08-18-unified-shading)

    /// True when there is a baked lattice layer to draw. Everything the unified path
    /// adds is gated on this, so a frame without a lattice is byte-for-byte the frame
    /// `render-quality` shipped.
    private var latticeInFrame: Bool { latticeLayer?.isReady == true }

    /// THE ONE ENTRY POINT for putting the lattice in this renderer's passes. The
    /// workspace hands the scene it already builds for the preview, plus the token it
    /// already bumps per bake — so the bake still happens once per data change and never
    /// per frame (bar P2). Passing nil removes the layer.
    ///
    /// ★ THE LAYER IS BAKE-ONLY. It never draws itself; `encodeDepthPrepass` and
    /// `encode` draw it, into THIS renderer's G-buffer and THIS renderer's colour +
    /// depth attachments. That sentence is the entire task.
    func setLatticeScene(_ scene: LatticeSDFScene?, token: Int) {
        guard let scene else {
            if latticeLayer != nil { latticeLayer = nil; latticeSceneToken = -1
                                     latticeAppliedTints = nil }
            return
        }
        if latticeLayer == nil {
            latticeLayer = LatticeSDFRenderer(device: device, buildPipeline: false)
            latticeSceneToken = -1
            latticeAppliedTints = nil
        }
        guard let layer = latticeLayer else { return }
        if latticeSceneToken != token {
            latticeSceneToken = token
            layer.setScene(scene)
            latticeAppliedTints = nil       // new grid/mesh → tints must re-bake
        }
    }

    /// The lattice's interactive params (cell size, density span, grading). A cell-size
    /// change rebakes the per-cell field ONCE inside the layer; everything else is a
    /// uniform.
    var latticeParams: LatticeProxyParams {
        get { latticeLayer?.params ?? LatticeProxyParams() }
        set { latticeLayer?.params = newValue }
    }

    /// Face-role tints on the lattice (the preview's bar A4), baked from the SAME
    /// dictionary the body is tinted with. Re-baked only when the selection changes.
    func setLatticeFaceTints(_ tints: [FaceID: SIMD4<Float>]) {
        guard let layer = latticeLayer else { return }
        if latticeAppliedTints != tints {
            latticeAppliedTints = tints
            layer.setFaceTints(tints)
        }
    }

    /// The G-buffer's size for a colour target of `width`×`height`. Identical to the
    /// colour target unless a lattice is in the frame, in which case the long side is
    /// capped — see `latticeGBufferMaxPixels` for why (the march is fill-bound).
    private func gbufferSize(width: Int, height: Int) -> (w: Int, h: Int) {
        guard latticeInFrame else { return (width, height) }
        let long = Swift.max(width, height)
        guard long > Self.latticeGBufferMaxPixels else { return (width, height) }
        let s = Double(Self.latticeGBufferMaxPixels) / Double(long)
        return (Swift.max(1, Int((Double(width) * s).rounded())),
                Swift.max(1, Int((Double(height) * s).rounded())))
    }

    /// G-buffer texels per colour pixel for the frame being encoded — 1 unless the cap
    /// above bit. Read by the contact pass (which samples the G-buffer by integer
    /// coordinate) and by the lattice's deferred shade.
    private var gbufferScale = SIMD2<Float>(1, 1)

    /// The uniform block the deferred lattice shade reads. Mirrors `LatShadeUniforms`
    /// in `unifiedLatticeShaderSource` — layout must match.
    private struct LatShadeUniforms {
        var worldFromEyeRot = matrix_identity_float4x4
        var proj = SIMD4<Float>(1, 1, 1, 1)     // tanX, tanY, gbufW, gbufH
        var depth = SIMD4<Float>(1, 0, 1, 1)    // A, B (ndc = A + B/eyeZ), mainW, mainH
        var misc = SIMD4<Float>.zero            // farSentinel, edgeStrength, 0, 0
    }

    /// The SSAO pair (raw + blurred), sized with the G-buffer. Two, because a
    /// fragment shader cannot read the attachment it is writing.
    private func aoTextures(width: Int, height: Int) -> (raw: MTLTexture, blur: MTLTexture)? {
        if let a = aoRawTex, let b = aoBlurTex, a.width == width, a.height == height { return (a, b) }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.aoFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let a = device.makeTexture(descriptor: d),
              let b = device.makeTexture(descriptor: d) else { return nil }
        aoRawTex = a; aoBlurTex = b
        return (a, b)
    }

    /// ★ §3c: render (or reuse) the part's floor footprint. Returns the texture and
    /// fills `shadowRect`. Everything about this is CACHED on `ShadowKey`: orbit the
    /// camera a thousand times and this pass runs zero times, because a shadow cast
    /// straight down does not depend on where the camera is.
    private func contactShadowTexture(floorRect: SIMD4<Float>, into cmd: MTLCommandBuffer) -> MTLTexture? {
        guard let spipe = shadowPipeline, vertexDrawCount > 0,
              let vbuf = vertexBuffer, let fbuf = flexBuffer,
              floorRect.z > 0, floorRect.w > 0 else { return nil }
        let key = ShadowKey(mesh: mesh.map(meshSignature),
                            rotation: SIMD4<Float>(modelRotation.vector),
                            rect: floorRect, flex: flexScale)
        shadowRect = floorRect
        if key == shadowKey, let t = shadowTex { return t }
        if shadowTex == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Self.shadowFormat, width: Self.shadowResolution,
                height: Self.shadowResolution, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            shadowTex = device.makeTexture(descriptor: d)
        }
        guard let tex = shadowTex else { return nil }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        guard let e = cmd.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        var u = ShadowUniforms(model: modelMatrix(), rect: floorRect,
                               flex: SIMD4<Float>(flexScale, 0, 0, 0))
        e.setRenderPipelineState(spipe)
        e.setCullMode(.none)
        e.setVertexBuffer(vbuf, offset: 0, index: 0)
        e.setVertexBuffer(fbuf, offset: 0, index: 3)
        e.setVertexBytes(&u, length: MemoryLayout<ShadowUniforms>.stride, index: 1)
        countedDraw(e, .triangle, vertexDrawCount)
        e.endEncoding()
        shadowKey = key
        return tex
    }

    /// The 1×1 zero texture bound to the stage draw when there is no shadow.
    private func neutralShadowTexture() -> MTLTexture? {
        if let t = shadowNeutralTex { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.shadowFormat, width: 1, height: 1, mipmapped: false)
        d.usage = [.shaderRead]
        #if os(macOS)
        d.storageMode = .managed
        #else
        d.storageMode = .shared
        #endif
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        var px: [UInt8] = [0]
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 1)
        shadowNeutralTex = t
        return t
    }

    /// The 1×1 "fully open, no edge" texture bound whenever AO is off — see
    /// `aoNeutralTex`. Built once, on first use.
    private func neutralAOTexture() -> MTLTexture? {
        if let t = aoNeutralTex { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.aoFormat, width: 1, height: 1, mipmapped: false)
        d.usage = [.shaderRead]
        #if os(macOS)
        d.storageMode = .managed
        #else
        d.storageMode = .shared
        #endif
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        var px: [UInt8] = [255, 0]   // R = openness 1.0, G = edge 0.0
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 2)
        aoNeutralTex = t
        return t
    }

    /// The MSAA colour target for a `size`×`size` offscreen pass (§3b). Nil at 1×.
    private func msaaTexture(width: Int, height: Int) -> MTLTexture? {
        guard sampleCount > 1 else { return nil }
        if let t = msaaColorTex, t.width == width, t.height == height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.colorFormat, width: width, height: height, mipmapped: false)
        d.textureType = .type2DMultisample
        d.sampleCount = sampleCount
        d.usage = [.renderTarget]
        d.storageMode = .private
        msaaColorTex = device.makeTexture(descriptor: d)
        return msaaColorTex
    }

    /// The part's eye-space depth span (near, far) over its transformed bounding box —
    /// what the §3d fade is expressed in, so "the far half recedes" means the far half
    /// of THIS part rather than a fixed distance in millimetres.
    private func partEyeDepthRange() -> (near: Float, far: Float)? {
        guard let mesh, !mesh.isEmpty else { return nil }
        let mv = modelViewMatrix()
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        let mn = mesh.bounds.min, mx = mesh.bounds.max
        for xi in [mn.x, mx.x] { for yi in [mn.y, mx.y] { for zi in [mn.z, mx.z] {
            let e = mv * SIMD4<Float>(xi, yi, zi, 1)
            lo = Swift.min(lo, -e.z); hi = Swift.max(hi, -e.z)
        }}}
        return hi > lo ? (lo, hi) : nil
    }

    /// The part's SMALLEST bounding-box side (world mm) — the length the SSAO radius is
    /// a fraction of. See `aoRadiusFraction` for why the smallest and not the largest.
    private func partExtent() -> Float {
        guard let mesh, !mesh.isEmpty else { return 1 }
        let d = mesh.bounds.max - mesh.bounds.min
        return Swift.max(Swift.min(Swift.min(d.x, d.y), d.z), 1e-3)
    }

    /// The body fragment's render-quality block for this frame. `aoSize` is the AO
    /// texture's size (zero when there is none — the neutral 1×1 is bound instead and
    /// both strengths go to zero, which makes the shader an identity).
    /// - Parameter mainSize: the MAIN COLOUR TARGET's size (nil when there is no AO
    ///   texture — the neutral 1×1 is bound instead). ★ NOT the AO texture's size: the
    ///   fragment scales its own `[[position]]` by these to get a normalized uv, and the
    ///   AO texture may now be smaller than the colour target (`latticeGBufferMaxPixels`).
    ///   Sizing them from the AO texture put every uv past 1.
    private func makeShadeParams(mainSize: (w: Int, h: Int)?) -> ShadeParams {
        var sp = ShadeParams()
        if let s = mainSize, s.w > 0, s.h > 0 {
            sp.ao = SIMD4<Float>(quality.contains(.ambientOcclusion) ? Self.aoStrength : 0,
                                 quality.contains(.edges) ? Self.edgeStrength : 0,
                                 1 / Float(s.w), 1 / Float(s.h))
        }
        if quality.contains(.depthFade), let r = partEyeDepthRange() {
            let start = r.near + (r.far - r.near) * Self.depthFadeStart
            sp.fade = SIMD4<Float>(Self.depthFadeStrength, start, r.far, 0)
        }
        sp.fade.w = quality.contains(.worldLighting) ? 1 : 0
        // §4 rides on §2: under the old flat headlight, desaturating a state tint would
        // just make it hard to see, because hue was all it had. It is applied only when
        // the shading that replaces it is actually on.
        if quality.contains(.worldLighting), tintsAreState {
            sp.tint = SIMD4<Float>(Self.stateTintDesaturation, Self.stateTintBrightnessLift, 0, 0)
        }
        return sp
    }

    /// Run the depth prepass (items 7+8, parts b+c): render the opaque part's eye-space depth into
    /// `color` (its own z-buffer `depth`) so the contact pass can read the part surface per pixel.
    /// Called only when a translucent volume is present (gated by the caller). Returns the colour
    /// texture on success, nil if the prepass could not be encoded (→ the caller keeps the plain draw).
    /// ★ AND IT IS NOW THE UNION (task 2026-08-18-unified-shading §1i). Two surfaces
    /// can land in this one G-buffer, depth-tested against each other:
    ///
    ///   • the SHELL, rasterised — but only when it is actually VISIBLE. `bodyAlpha`
    ///     goes to 0 on the lattice stage (the workspace's bar A3: while the strut
    ///     layer is up there is ONE visible object), and an invisible wall in the
    ///     G-buffer would occlude the struts behind it in AO — the interior would go
    ///     dark for a surface nobody can see. The G-buffer must hold what the frame
    ///     SHOWS. A partially-translucent body (the load-flow x-ray, alpha ≈ 0.35) is
    ///     still visible and still goes in, so that path is untouched.
    ///
    ///   • the LATTICE, sphere-traced, writing its own fragment depth.
    ///
    /// Returns nil when NEITHER is present — the caller then binds the neutral 1×1 AO
    /// texture and the frame is the un-occluded one, never a broken one.
    private func encodeDepthPrepass(width: Int, height: Int, uniforms: ViewerUniforms,
                                    aspect: Float, into cmd: MTLCommandBuffer)
        -> (depth: MTLTexture, normal: MTLTexture, albedo: MTLTexture)? {
        let shellVisible = bodyAlpha > 0.004
        let lattice = latticeInFrame ? latticeLayer : nil
        guard let dpipe = depthPrepassPipeline, vertexDrawCount > 0,
              let vbuf = vertexBuffer, let fbuf = flexBuffer,
              shellVisible || lattice != nil,
              let tex = sceneDepthTextures(width: width, height: height) else { return nil }
        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].texture = tex.color
        pd.colorAttachments[0].loadAction = .clear
        pd.colorAttachments[0].clearColor = MTLClearColor(red: Double(Self.sceneDepthFar), green: 0, blue: 0, alpha: 0)
        pd.colorAttachments[0].storeAction = .store
        // The G-buffer's normal attachment (render quality §1/§3a). Cleared to zero —
        // a zero-length normal only ever appears where eye-Z is the far sentinel, and
        // the AO pass returns before it reads one.
        pd.colorAttachments[1].texture = tex.normal
        pd.colorAttachments[1].loadAction = .clear
        pd.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pd.colorAttachments[1].storeAction = .store
        // The lattice albedo + mask. Cleared to zero alpha = "no lattice anywhere",
        // which is what the deferred shade needs when the layer is absent.
        pd.colorAttachments[2].texture = tex.albedo
        pd.colorAttachments[2].loadAction = .clear
        pd.colorAttachments[2].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pd.colorAttachments[2].storeAction = .store
        pd.depthAttachment.texture = tex.depth
        pd.depthAttachment.loadAction = .clear
        pd.depthAttachment.clearDepth = 1.0
        pd.depthAttachment.storeAction = .dontCare
        guard let penc = cmd.makeRenderCommandEncoder(descriptor: pd) else { return nil }
        if shellVisible {
            var du = DepthPrepassUniforms(mvp: uniforms.mvp, modelView: modelViewMatrix(),
                                          flex: SIMD4<Float>(flexScale, 0, 0, 0),
                                          normalMatrix: uniforms.normalMatrix)
            penc.setRenderPipelineState(dpipe)
            penc.setDepthStencilState(depthState)   // .less, write on — nearest part surface wins
            penc.setCullMode(.none)                  // match the main mesh draw
            penc.setVertexBuffer(vbuf, offset: 0, index: 0)
            penc.setVertexBuffer(fbuf, offset: 0, index: 3)
            penc.setVertexBytes(&du, length: MemoryLayout<DepthPrepassUniforms>.stride, index: 1)
            countedDraw(penc, .triangle, vertexDrawCount)
        }
        if let lattice, let lpipe = latticeGBufferPipeline {
            // The lattice marches in the SAME encoder, against the SAME depth
            // attachment: where the shell is nearer, the depth test throws the strut
            // away, and where a strut is nearer it replaces the wall. That per-pixel
            // resolution is §1(ii), and it is what makes a strut entering a wall
            // DISAPPEAR into it instead of stopping at a clean silhouette against it.
            lattice.camera = camera
            lattice.modelRotation = modelRotation
            lattice.modelCenter = modelCenter
            var lu = lattice.makeUnifiedUniforms(aspect: aspect,
                                                 clipFromModel: uniforms.mvp,
                                                 eyeFromModel: uniforms.modelView,
                                                 eyeNormalBasis: uniforms.normalMatrix)
            penc.setRenderPipelineState(lpipe)
            penc.setDepthStencilState(depthState)   // .less, write on
            penc.setCullMode(.none)
            lattice.bindFragment(penc, &lu)
            countedDraw(penc, .triangle, 3)
        }
        penc.endEncoding()
        return (tex.color, tex.normal, tex.albedo)
    }

    /// ★ §1 + §3a: the SSAO and edge passes. Two full-screen draws over the G-buffer
    /// (AO+edge, then a depth-aware blur of the AO channel only) producing the RG
    /// texture the body fragment multiplies into its ambient term. Returns nil when
    /// the pipelines are unavailable — the body then binds the neutral 1×1 and the
    /// picture is the un-occluded one, never a broken one.
    private func encodeAO(gbuffer: (depth: MTLTexture, normal: MTLTexture, albedo: MTLTexture),
                          aspect: Float,
                          into cmd: MTLCommandBuffer) -> MTLTexture? {
        guard let apipe = aoPipeline, let bpipe = aoBlurPipeline,
              let ao = aoTextures(width: gbuffer.depth.width, height: gbuffer.depth.height) else { return nil }
        let w = Float(gbuffer.depth.width), h = Float(gbuffer.depth.height)
        // tan(fov/2) per axis straight off the projection the frame is being drawn
        // with — P[1][1] = 1/tan(fovY/2), P[0][0] = that over the aspect — so the AO
        // pass cannot drift from the camera the way a second copy of the fov would.
        let proj = camera.projectionMatrix(aspect: aspect)
        let tanY = 1 / Swift.max(proj.columns.1.y, 1e-6)
        let tanX = 1 / Swift.max(proj.columns.0.x, 1e-6)
        let radius = aoRadiusOverrideMM ?? (partExtent() * Self.aoRadiusFraction)
        var u = AOUniforms(
            proj: SIMD4<Float>(tanX, tanY, w, h),
            params: SIMD4<Float>(radius, Self.aoIntensity, radius * 0.02, Float(aoQuality.rawValue)),
            edge: SIMD4<Float>(Self.edgeDepthThreshold, Self.edgeNormalThreshold, Self.sceneDepthFar, 0))

        func fullScreen(_ pipe: MTLRenderPipelineState, into target: MTLTexture,
                        tex0: MTLTexture, tex1: MTLTexture) {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = target
            rp.colorAttachments[0].loadAction = .dontCare   // every pixel is written
            rp.colorAttachments[0].storeAction = .store
            guard let e = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
            e.setRenderPipelineState(pipe)
            e.setFragmentBytes(&u, length: MemoryLayout<AOUniforms>.stride, index: 0)
            e.setFragmentTexture(tex0, index: 0)
            e.setFragmentTexture(tex1, index: 1)
            countedDraw(e, .triangle, 3)
            e.endEncoding()
        }
        fullScreen(apipe, into: ao.raw, tex0: gbuffer.depth, tex1: gbuffer.normal)
        fullScreen(bpipe, into: ao.blur, tex0: ao.raw, tex1: gbuffer.depth)
        return ao.blur
    }

    /// Draw one translucent MODEL-space volume (the design box OR a clearance region) — its faces
    /// then its bright edges — under `mvp`. The FACES go through the shared CONTACT variant (items
    /// 7+8, parts b+c) when the prepass produced a `sceneDepthTex`, adding the contact line +
    /// interior occlusion where the volume meets the part; otherwise they fall back to the plain
    /// `groundPipeline` draw (part-a depth-bias only). The edges always use `groundPipeline`. This
    /// is the ONE place both consumers share the contact shader.
    private func encodeVolume(enc: MTLRenderCommandEncoder, mvp: simd_float4x4,
                              faceBuffer: MTLBuffer?, faceCount: Int,
                              lineBuffer: MTLBuffer?, lineCount: Int, sceneDepthTex: MTLTexture?) {
        guard faceCount > 0 || lineCount > 0 else { return }
        enc.setDepthStencilState(groundDepthState)
        if faceCount > 0, let fbuf = faceBuffer {
            // Depth-bias the FACES (items 7+8, part a) so the glass stops z-fighting where it
            // passes through the part; reset before the crisp edge lines.
            enc.setDepthBias(Self.translucentDepthBias, slopeScale: Self.translucentDepthSlopeBias, clamp: 0)
            if let cpipe = contactPipeline, let sceneTex = sceneDepthTex {
                var cu = ContactUniforms(mvp: mvp, modelView: modelViewMatrix(),
                                         params: SIMD4<Float>(Self.contactFeatherPixels,
                                                              Self.contactOcclusionPixels,
                                                              gbufferScale.x, gbufferScale.y))
                enc.setRenderPipelineState(cpipe)
                enc.setVertexBytes(&cu, length: MemoryLayout<ContactUniforms>.stride, index: 1)
                // `contact_fragment` ALSO declares `CUniforms u [[buffer(1)]]` (it reads the pixel
                // feather + occlusion band), so the FRAGMENT index-1 buffer must be bound too —
                // without this Metal drops the draw ("missing Buffer binding at index 1"), the same
                // trap `loadpath_fragment` documents.
                enc.setFragmentBytes(&cu, length: MemoryLayout<ContactUniforms>.stride, index: 1)
                enc.setFragmentTexture(sceneTex, index: 0)
            } else if let gpipe = groundPipeline {
                var m = mvp
                enc.setRenderPipelineState(gpipe)
                enc.setVertexBytes(&m, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            }
            enc.setVertexBuffer(fbuf, offset: 0, index: 0)
            countedDraw(enc, .triangle, faceCount)
            enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        }
        if lineCount > 0, let lbuf = lineBuffer, let gpipe = groundPipeline {
            var m = mvp
            enc.setRenderPipelineState(gpipe)
            enc.setVertexBytes(&m, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            enc.setVertexBuffer(lbuf, offset: 0, index: 0)
            countedDraw(enc, .line, lineCount)
        }
    }

    /// Build the CAD-stage backdrop uniform (item 9): the inverse world→clip transform for the
    /// per-pixel ray reconstruction, the camera eye, and the floor plane + grid extent derived
    /// from the SETTLED part bounds (so the grid sits just under the part and scales with it).
    /// Falls back to a camera-relative box when no mesh is loaded. Pure of any per-frame timer —
    /// it reads only the current camera + mesh, so it changes only on a redraw.
    private func makeStageUniforms(aspect: Float) -> StageUniforms {
        let inv = groundMVP(aspect: aspect).inverse
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        if let mesh, !mesh.isEmpty {
            let m = modelMatrix()
            let mn = mesh.bounds.min, mx = mesh.bounds.max
            for xi in [mn.x, mx.x] { for yi in [mn.y, mx.y] { for zi in [mn.z, mx.z] {
                let w = m * SIMD4<Float>(xi, yi, zi, 1)
                lo = simd_min(lo, SIMD3<Float>(w.x, w.y, w.z))
                hi = simd_max(hi, SIMD3<Float>(w.x, w.y, w.z))
            }}}
        } else {
            let r = Swift.max(camera.distance * 0.2, 0.5)
            lo = camera.target - SIMD3<Float>(r, r, r)
            hi = camera.target + SIMD3<Float>(r, r, r)
        }
        let extent = Swift.max(hi.x - lo.x, hi.z - lo.z, 1e-3)
        // §3c: the footprint's world-XZ rectangle — the part's own XZ span with a 12%
        // margin, so the 3×3 soft tap has somewhere to fall off INTO rather than
        // clipping at the part's silhouette.
        let mx = extent * 0.12
        let rect = SIMD4<Float>(lo.x - mx, lo.z - mx,
                                Swift.max(hi.x - lo.x + 2 * mx, 1e-3),
                                Swift.max(hi.z - lo.z + 2 * mx, 1e-3))
        return StageUniforms(invVP: inv,
                             eye: camera.eye,
                             floorY: lo.y - extent * 0.02,
                             centerXZ: SIMD2<Float>((lo.x + hi.x) * 0.5, (lo.z + hi.z) * 0.5),
                             spacing: extent / 6,
                             fadeRadius: extent * 6,
                             shadowRect: rect,
                             shadowStrength: 0)   // filled in by `encode` once the footprint exists
    }

    /// Render the current mesh + camera to an offscreen BGRA texture and return the
    /// raw pixel bytes (B,G,R,A per pixel). Used by headless tests to verify the
    /// pipeline rasterizes the mesh — no MTKView/display needed. Nil if nothing to draw.
    /// GPU time (seconds) for ONE encoded frame at `size`×`size`, measured by Metal
    /// itself (`gpuEndTime - gpuStartTime`) with NO pixel readback — handoff 134's
    /// item-3 probe. `renderOffscreen` is not a frame-time proxy: it copies a
    /// megabyte of texture back to the CPU, which dwarfs the draw. Instrumentation
    /// only; nothing in the app calls it.
    func measureFrameGPUSeconds(size: Int, stage: Bool) -> Double? {
        guard vertexDrawCount > 0 else { return nil }
        let cdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.colorFormat, width: size, height: size, mipmapped: false)
        cdesc.usage = [.renderTarget]
        cdesc.storageMode = .private
        let ddesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.depthFormat, width: size, height: size, mipmapped: false)
        ddesc.usage = [.renderTarget]
        ddesc.storageMode = .private
        if sampleCount > 1 { ddesc.textureType = .type2DMultisample; ddesc.sampleCount = sampleCount }
        guard let color = device.makeTexture(descriptor: cdesc),
              let depth = device.makeTexture(descriptor: ddesc),
              let cmd = queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        // §3b: measure the SHIPPING frame — multisampled and resolved, exactly as the
        // on-screen path draws it. Timing a 1× pass and reporting it as the cost of a
        // 4× one would understate the very item being priced.
        if let msaa = msaaTexture(width: size, height: size) {
            rpd.colorAttachments[0].texture = msaa
            rpd.colorAttachments[0].resolveTexture = color
            rpd.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            rpd.colorAttachments[0].texture = color
            rpd.colorAttachments[0].storeAction = .store
        }
        rpd.colorAttachments[0].loadAction = .clear
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare
        encode(into: rpd, aspect: 1, into: cmd, drawStage: stage)
        cmd.commit()
        cmd.waitUntilCompleted()
        let dt = cmd.gpuEndTime - cmd.gpuStartTime
        return dt > 0 ? dt : nil
    }

    func renderOffscreen(size: Int, clear: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1),
                         stage: Bool = false) -> [UInt8]? {
        guard vertexDrawCount > 0 else { return nil }
        let cdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.colorFormat, width: size, height: size, mipmapped: false)
        cdesc.usage = [.renderTarget, .shaderRead]
        cdesc.storageMode = .shared
        let ddesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.depthFormat, width: size, height: size, mipmapped: false)
        ddesc.usage = [.renderTarget]
        ddesc.storageMode = .private
        if sampleCount > 1 { ddesc.textureType = .type2DMultisample; ddesc.sampleCount = sampleCount }
        guard let color = device.makeTexture(descriptor: cdesc),
              let depth = device.makeTexture(descriptor: ddesc),
              let cmd = queue.makeCommandBuffer() else { return nil }

        let rpd = MTLRenderPassDescriptor()
        // §3b: the captured evidence goes through the SAME multisample+resolve the
        // screen does, so a before/after pair is a pair of shipping frames.
        if let msaa = msaaTexture(width: size, height: size) {
            rpd.colorAttachments[0].texture = msaa
            rpd.colorAttachments[0].resolveTexture = color
            rpd.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            rpd.colorAttachments[0].texture = color
            rpd.colorAttachments[0].storeAction = .store
        }
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = clear
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare

        encode(into: rpd, aspect: 1, into: cmd, drawStage: stage)
        cmd.commit()
        cmd.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        color.getBytes(&pixels, bytesPerRow: size * 4,
                       from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        return pixels
    }

    /// Render the face-id pass to an offscreen R32Uint target and return the id per
    /// pixel (row-major, `idBackground` where no face is under the pixel). Nil if the
    /// id pipeline is unavailable or there is nothing to draw. This is the on-device
    /// mechanism the M7.5 tap uses (`pickFaceID`); the CPU `FacePicker` mirrors it.
    /// ★ THE AO BUFFER, READ BACK (task 2026-08-18-unified-shading §3b).
    ///
    /// "Show the AO buffer itself in the evidence, before and after — that buffer is
    /// where the junction darkening either exists or does not, and a screenshot of the
    /// final frame can hide its absence." So it is readable, and a test asserts on it.
    ///
    /// Encodes one full offscreen frame (which is what fills the AO texture — this does
    /// NOT run a special-case pass, or it would be evidence about a different shader)
    /// and blits the result into a CPU-visible staging texture. `openness` is the R
    /// channel the body's ambient term is multiplied by, `edge` the G channel the
    /// crease line is drawn from. Nil when AO is off or the pipelines are unavailable.
    ///
    /// Instrumentation only; nothing in the app calls it.
    struct AOBufferDump {
        var width: Int
        var height: Int
        /// Row-major, y-down — the same convention the AO pass writes in.
        var pixels: [(openness: Float, edge: Float)]
    }

    func aoBufferDump(size: Int) -> AOBufferDump? {
        guard vertexDrawCount > 0, aoPipeline != nil,
              !quality.isDisjoint(with: [.ambientOcclusion, .edges]) else { return nil }
        let cdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.colorFormat, width: size, height: size, mipmapped: false)
        cdesc.usage = [.renderTarget]
        cdesc.storageMode = .private
        let ddesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.depthFormat, width: size, height: size, mipmapped: false)
        ddesc.usage = [.renderTarget]
        ddesc.storageMode = .private
        if sampleCount > 1 { ddesc.textureType = .type2DMultisample; ddesc.sampleCount = sampleCount }
        guard let color = device.makeTexture(descriptor: cdesc),
              let depth = device.makeTexture(descriptor: ddesc),
              let cmd = queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        if let msaa = msaaTexture(width: size, height: size) {
            rpd.colorAttachments[0].texture = msaa
            rpd.colorAttachments[0].resolveTexture = color
            rpd.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            rpd.colorAttachments[0].texture = color
            rpd.colorAttachments[0].storeAction = .store
        }
        rpd.colorAttachments[0].loadAction = .clear
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare
        encode(into: rpd, aspect: 1, into: cmd, drawStage: false)
        // ★ REFUSE A STALE BUFFER. `aoBlurTex` survives between frames, so if this
        // frame's AO pass did not run (no visible surface in the G-buffer, or the
        // pipelines unavailable) the texture still holds whatever the LAST frame left
        // there. Returning that would be a "before" capture showing the "after".
        guard lastFrameHadAO, let ao = aoBlurTex else { cmd.commit(); return nil }
        let sdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.aoFormat, width: ao.width, height: ao.height, mipmapped: false)
        sdesc.usage = [.shaderRead]
        #if os(macOS)
        sdesc.storageMode = .managed
        #else
        sdesc.storageMode = .shared
        #endif
        guard let staging = device.makeTexture(descriptor: sdesc),
              let blit = cmd.makeBlitCommandEncoder() else { cmd.commit(); return nil }
        blit.copy(from: ao, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: ao.width, height: ao.height, depth: 1),
                  to: staging, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        #if os(macOS)
        blit.synchronize(resource: staging)
        #endif
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        var raw = [UInt8](repeating: 0, count: ao.width * ao.height * 2)
        staging.getBytes(&raw, bytesPerRow: ao.width * 2,
                         from: MTLRegionMake2D(0, 0, ao.width, ao.height), mipmapLevel: 0)
        var px = [(openness: Float, edge: Float)]()
        px.reserveCapacity(ao.width * ao.height)
        for i in stride(from: 0, to: raw.count, by: 2) {
            px.append((Float(raw[i]) / 255, Float(raw[i + 1]) / 255))
        }
        return AOBufferDump(width: ao.width, height: ao.height, pixels: px)
    }

    func renderFaceIDOffscreen(width: Int, height: Int) -> [UInt32]? {
        guard vertexDrawCount > 0, let idPipeline, let idbuf = idVertexBuffer,
              width > 0, height > 0 else { return nil }
        let cdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.idFormat, width: width, height: height, mipmapped: false)
        cdesc.usage = [.renderTarget, .shaderRead]
        cdesc.storageMode = .shared
        let ddesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.depthFormat, width: width, height: height, mipmapped: false)
        ddesc.usage = [.renderTarget]
        ddesc.storageMode = .private
        guard let color = device.makeTexture(descriptor: cdesc),
              let depth = device.makeTexture(descriptor: ddesc),
              let cmd = queue.makeCommandBuffer() else { return nil }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(idBackground), green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        var uniforms = makeUniforms(aspect: Float(width) / Float(height))
        enc.setRenderPipelineState(idPipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        enc.setVertexBuffer(idbuf, offset: 0, index: 0)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<ViewerUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexDrawCount)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        var ids = [UInt32](repeating: 0, count: width * height)
        color.getBytes(&ids, bytesPerRow: width * 4,
                       from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return ids
    }

    /// ★ WHAT THE ID PASS ACTUALLY ANSWERED — THREE OUTCOMES, NOT TWO.
    ///
    /// `pickFaceID` returns `FaceID?`, which collapses two completely different
    /// answers into one `nil`: "the id pass ran and there is NOTHING under this
    /// pixel", and "the id pass could not run at all". The tap handler treated
    /// both the same way — fall through to the CPU `FacePicker` — and that is the
    /// whole of the bug the maintainer reported as "when tapping just off to the
    /// side of the model, on the floor, faces are randomly selected".
    ///
    /// ★ AND WHY THE FALLBACK ANSWERS AT ALL ON A TAP THAT HIT NOTHING. The CPU
    /// picker casts a WORLD-space ray at MODEL-space vertices. Once gravity is set
    /// the part is drawn through a settle rotation, so the geometry the ray meets
    /// is the part in its ORIGINAL pose — sitting somewhere else on screen
    /// entirely. A tap on empty floor to the lower right of the drawn part passes
    /// straight through the un-rotated part, and the picker dutifully names the
    /// face it crossed. It is not random: it is the same wrong face every time
    /// from the same place, which is exactly what was described ("with union it
    /// will select the large right side, with the selection tool the very front
    /// face").
    ///
    /// Naming the third case is what lets the caller do the only correct thing:
    /// on `.background`, MISS — never ask a second opinion of a question that has
    /// already been answered.
    enum FaceIDPass: Equatable {
        case face(FaceID)
        /// The pass ran; that pixel is empty space.
        case background
        /// The pass could not run (no pipeline / nothing to draw).
        case unavailable
    }

    /// Resolve the face id at a normalized tap point (x,y ∈ [0,1], y down) via the
    /// id pass, keeping "empty space" and "no pass" apart.
    func pickFacePass(atNormalizedPoint p: CGPoint, width: Int, height: Int) -> FaceIDPass {
        guard let ids = renderFaceIDOffscreen(width: width, height: height)
        else { return .unavailable }
        let px = Swift.min(Swift.max(Int(p.x * CGFloat(width)), 0), width - 1)
        let py = Swift.min(Swift.max(Int(p.y * CGFloat(height)), 0), height - 1)
        let raw = ids[py * width + px]
        return raw == idBackground ? .background : .face(FaceID(bitPattern: raw))
    }

    /// Resolve the face id at a normalized tap point (x,y ∈ [0,1], y down) via the
    /// id pass. Returns nil on a miss / when the id pass is unavailable — the caller
    /// then falls back to the CPU `FacePicker`.
    func pickFaceID(atNormalizedPoint p: CGPoint, width: Int, height: Int) -> FaceID? {
        if case .face(let f) = pickFacePass(atNormalizedPoint: p, width: width,
                                            height: height) { return f }
        return nil
    }
}

// ---------------------------------------------------------------------------
// SwiftUI wrapper around MTKView, cross-platform (UIKit on iOS, AppKit on macOS).

/// The inputs the workspace hands the viewer each SwiftUI update. Bundled so the
/// two platform representables (and the Coordinator) share one signature.
/// ★ THE IDENTITY OF A PER-VERTEX TINT — AND WHY IT HASHES THE WHOLE ARRAY.
///
/// This was `(count, first 16 floats)`, to avoid comparing ~37,000 floats on every
/// body evaluation. It was WRONG, and wrong in the way that is hardest to see: a
/// cut changes the colour of vertices in the MIDDLE of the buffer and changes the
/// count not at all, so the key compared EQUAL and the renderer never re-uploaded.
/// The commit had already happened — regions were split, the model was correct —
/// and the screen simply never changed. From the outside that is indistinguishable
/// from a cut that does nothing, which is exactly how it was reported: "I press the
/// checkbox, and the face stays exactly the way it is."
///
/// A hash over the whole buffer cannot be fooled that way. It is O(n) once per body
/// evaluation on a few tens of thousands of floats — microseconds — against a
/// re-upload it was trying to avoid that costs about the same.
/// The Swift mirror of the shader's `CutUniforms`. Field order and padding must
/// match the MSL declaration exactly — SIMD4 is 16-byte aligned on both sides, and
/// the trailing float is padded to 16 by `stride`.
struct CutUniformsSwift {
    var plane: SIMD4<Float>
    var colSelected: SIMD4<Float>
    var colSibling: SIMD4<Float>
    var enabled: Float
    /// 16 planes: up to 4 pieces of up to 4 half-spaces each, consecutive.
    var pickPlanes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero,
           .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    var pickCounts: SIMD4<Int32> = .zero
    var pickGroups: Int32 = 0
}

struct VertexTintKey: Equatable {
    let count: Int
    let hash: Int

    init(_ rgba: [Float]) {
        count = rgba.count
        var h = Hasher()
        for f in rgba { h.combine(f) }
        hash = h.finalize()
    }
}

struct MeshViewInputs {
    var mesh: ViewerMesh?
    /// The shared orbit-camera source of truth (STEP 1). When present the viewer reads
    /// its orientation/zoom from this model and routes gestures back into it, so a
    /// sibling orientation gizmo drives — and mirrors — the exact same state. nil keeps
    /// the legacy self-owned camera (offscreen thumbnails, previews).
    var camera: OrbitCameraModel?
    var selection: SelectionModel?
    /// Per-face tint (rgba) — role-aware (anchor green); overrides the palette.
    var faceTints: [FaceID: SIMD4<Float>]?
    /// §6 — a per-VERTEX tint that overrides `faceTints` (the two halves of a cut
    /// face share a face id, so a per-face map cannot separate them).
    var vertexTints: [Float]?
    /// §6 — extra model-space line segments drawn with the wireframe: the traces
    /// of every committed cut, and the grid a pattern would make. Flat list,
    /// x,y,z per vertex, two vertices per segment.
    var extraLines: [Float]?
    /// §6/§7 — the same traces widened into surface ribbons, so they can be seen.
    ///
    /// ★ NO LONGER USED, AND WHY. `SurfaceCutLines.ribbon` widens each segment in
    /// the plane of ONE face normal, which is correct on a flat face and degenerate
    /// on a curved one: where the segment runs parallel to that normal the
    /// perpendicular collapses and the ribbon disappears. That is the two or three
    /// stray gold ticks on the maintainer's curved face where a whole line should
    /// have been. The wide-line pipeline expands every segment in SCREEN space
    /// instead, which has no such degenerate direction — so the traces ride the
    /// wireframe and this layer is redundant. Kept as an input so the smoothing and
    /// lattice pages, which pass nothing, are untouched.
    var cutRibbon: [Float]?
    /// §6 — face sets a union has combined; the B-rep edges INSIDE one of these are
    /// no longer boundaries and are not drawn.
    var weldedFaces: [Set<FaceID>] = []
    /// §7 — lines for something NOT YET COMMITTED (the pattern grid being aimed).
    /// Drawn in the accent colour, because a boundary that exists and one that is
    /// being decided must not look alike. `extraLines` is the committed set and is
    /// drawn as structure, in the same grey as the B-rep edges it has joined.
    var previewLines: [Float] = []
    /// §6 — the cut plane the fragment stage tests, model space, as
    /// (normal.xyz, -dot(normal, point)). Nil draws exactly as before.
    var cutPlane: SIMD4<Float>?
    /// §6 — the picked pieces, each as its own chain of half-spaces, so the
    /// fragment stage can light the PIECE rather than its whole face.
    var pickChains: [[SIMD4<Float>]] = []
    /// §6 — X-RAY: the line set draws through the solid. Separate from
    /// `showWireframe`, which decides whether there are lines at all.
    var xray: Bool = false
    /// The settle rotation to display (gravity → world −Y); identity = un-settled.
    var settleRotation: simd_quatf
    /// Animate the settle (false = snap, for reduced-motion).
    var settleAnimated: Bool
    /// Draw the ground grid + contact shadow (gravity set, edit phase).
    var showGround: Bool
    var faceToolActive: Bool
    var onPickFace: ((FaceID) -> Void)?
    /// §6 — the same pick, WITH the 3D point, offered FIRST and able to consume
    /// the tap. Returning true means "handled"; the face-id callback is then not
    /// called. A divided face needs the point to know WHICH PIECE was tapped, so the
    /// point-aware handler has to get first refusal — otherwise the face-id route
    /// has already acted on the whole face by the time the point arrives.
    var onPickPoint: ((FaceID, SIMD3<Float>?) -> Bool)?
    /// Tap that hit no face (drop the pending group, M7.6).
    var onMiss: (() -> Void)?
    /// Published each time the camera changes, so overlays can project 3D points.
    var onProjection: ((CameraProjection) -> Void)?
    /// Round-6 item 4: a two-finger DOUBLE-tap on the viewport undoes; a two-finger TRIPLE-tap
    /// redoes. nil disables the gesture (previews / thumbnails). iOS only — a Mac trackpad
    /// two-finger tap is not a `UITapGestureRecognizer` event, so the header buttons stand in there.
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    /// M7.8 results stress overlay: per-flat-vertex colors (one per `mesh.flat`
    /// vertex). When set, they replace the face-highlight tints. nil = no overlay.
    var stressTints: [SIMD4<Float>]?
    /// M7.viz coupling: the load multiple the `stressTints` were computed at (the flex
    /// amplitude / failure push). It changes each animation frame, so the coordinator
    /// re-uploads the (already-multiplied) tints whenever it moves — that is what makes
    /// the heatmap recolor WITH the motion instead of freezing at the first frame.
    var stressMultiplier: Float = 1
    /// M7.8 results morph scrub in [0, 1] (1 = fully formed; < 1 reveals partially).
    var reveal: Float = 1
    /// M7.viz.3 flex: per-flat-vertex displacement (flattened xyz, mm), aligned with
    /// `mesh.flat`. Uploaded on mesh change; nil = no flex geometry.
    var flexDisplacements: [Float]? = nil
    /// M7.viz.3 flex: the per-frame displacement scale (exaggeration·amplitude); 0 rests.
    var flexScale: Float = 0
    /// M7.viz.4 load-path: line segments (pos+rgba, stride 7) tracing the dominant
    /// principal-stress direction over the variant. nil = overlay off.
    var loadPathSegments: [Float]? = nil
    /// ★ §6(b) — THE SURFACE STAGE'S B-REP WIREFRAME. `true` builds the edge set
    /// from the mesh's own face partition (`SurfaceWireframe`) and draws it; the
    /// geometry is derived here rather than passed in, so a caller cannot hand the
    /// renderer a wireframe that disagrees with the mesh it is drawing over.
    var showWireframe: Bool = false
    /// M7.viz.4 load-path: the flow-animation phase in [0, 1). Advanced by the results
    /// ticker; scrolls the traveling dash along the ribbons. Changing it re-draws (a
    /// cheap per-frame uniform), which is what animates the flow. 0 = static.
    var loadPathFlow: Float = 0
    /// M7.dom-app design-box gizmo: the grow-room box (nil hides it) + keep-out boxes,
    /// in model space. Rendered as translucent volumes with bright edges.
    var designBox: DesignBoxBounds? = nil
    var keepOutBoxes: [DesignBoxBounds] = []
    /// Keep-clear v2 (Part 3): the true clearance volumes to draw (swept cylinders +
    /// bounded slabs), tagged selected. Empty hides them; Equatable so the coordinator
    /// only re-tessellates on change.
    var clearanceVolumes: [ClearanceRenderItem] = []
    /// Load-path FLOW (handoff 070): the comet-arrow tube geometry (pos+rgba, stride 7)
    /// for THIS frame, rebuilt each tick from the model's comet frames. nil = flow off.
    var loadFlowVertices: [Float]? = nil
    /// Load-path FLOW: a per-frame key (the flow clock) so the coordinator re-uploads the
    /// comet buffer every animation tick (the geometry changes each frame, unlike a
    /// cheap uniform).
    var loadFlowKey: Double = 0
    /// Load-path FLOW: the faint full-path guide lines (pos+rgba, stride 7). Uploaded
    /// when they change (per selection), not per frame.
    var loadFlowGuides: [Float]? = nil
    /// Load-path FLOW: body opacity (1 opaque; < 1 = translucent x-ray/stress body).
    var bodyAlpha: Float = 1
    /// Detent face-highlight PULSE (device round 3, item 2): the part face a design-box drag just
    /// snapped to + a monotonic token. The coordinator fires a fresh viewer flash whenever the
    /// token advances (so re-snapping the SAME face re-pulses). nil = no pulse pending.
    var detentPulse: DetentPulse? = nil
    /// Paint mode (handoff 2026-07-25): when true, a ONE-finger drag paints instead of orbiting
    /// (two fingers still orbit the camera). Gated so tap-select and orbit are untouched when off.
    var paintActive: Bool = false
    /// Paint mode: the per-triangle EFFECTIVE face ids (native ids with painted overrides applied),
    /// so the id-pass PICK and the highlight TINT treat a painted region as one face — the live
    /// paint highlight. nil = use the mesh's native ids (no paint).
    var paintFaceIDs: [Int32]? = nil
    /// Paint mode: a brush sample at `centerPoint` (view points, top-left, y-down) with its phase.
    /// The workspace resolves the covered triangles (`BrushHitTest`) and applies the stroke; on
    /// `.ended` it persists the sidecar. nil disables painting.
    var onBrush: ((CGPoint, BrushPhase, BrushInput) -> Void)? = nil
    /// The brush has been given to the PENCIL (bar U2): a finger drag orbits
    /// instead of painting. The pencil is unaffected.
    var brushRequiresPencil: Bool = false
    /// An ARMED brush REFUSED this contact (task 2026-08-05, bar D1b): reported
    /// once at the start of the drag so the page can say why, at the moment the
    /// user tries it, instead of leaving disabled buttons downstream to imply it.
    var onBrushRefused: ((BrushInput) -> Void)? = nil
    /// ★ THE RAYMARCHED LATTICE, AS AN INPUT TO THIS VIEW rather than as a sibling
    /// view (task 2026-08-18-unified-shading). nil = no lattice, and then this view is
    /// byte-for-byte what it was.
    var latticeLayer: LatticeLayerInputs? = nil
}

/// ★ THE LATTICE AS A LAYER OF THE MESH VIEW, NOT A VIEW BESIDE IT.
///
/// It used to be `LatticeSDFPreviewView` — a second, transparent, depth-less MTKView
/// stacked over the mesh view in the workspace's ZStack. That stacking IS the
/// "pasted on" the maintainer reported: a separate view cannot share a depth buffer,
/// a normal buffer, an occlusion pass or a light rig with the view underneath it, so
/// the struts could never be occluded by the part, never receive the frame's ambient
/// occlusion or contact darkening, and were lit by their own key. Handing the same
/// four values to the mesh view instead puts the march inside its passes.
///
/// The fields are exactly what that view took, so the workspace's call site is a
/// re-spelling rather than a re-design: the scene, the interactive params, the bake
/// token and the face-role tints.
public struct LatticeLayerInputs: Equatable {
    public var scene: LatticeSDFScene
    public var params: LatticeProxyParams
    /// A monotonically increasing token the workspace bumps when `scene` is rebuilt,
    /// so the volumes are baked exactly once per bake and never per frame (bar P2).
    public var sceneToken: Int
    /// The mesh view's own face-role tint dictionary, verbatim — one source of truth
    /// for the colours (bar A4).
    public var faceTints: [FaceID: SIMD4<Float>]

    public init(scene: LatticeSDFScene, params: LatticeProxyParams,
                sceneToken: Int, faceTints: [FaceID: SIMD4<Float>]) {
        self.scene = scene
        self.params = params
        self.sceneToken = sceneToken
        self.faceTints = faceTints
    }

    /// Equality is by TOKEN and by the cheap interactive values — never by the scene's
    /// voxel grids. Comparing a few megabytes of baked field on every SwiftUI update
    /// (i.e. on every orbit tick) is exactly the per-frame work bar P2 forbids, and the
    /// token exists precisely to answer "is this the same bake".
    public static func == (a: LatticeLayerInputs, b: LatticeLayerInputs) -> Bool {
        a.sceneToken == b.sceneToken && a.params == b.params && a.faceTints == b.faceTints
    }
}

/// The phase of a paint brush sample (handoff 2026-07-25): a stroke runs `.began` → `.moved`* →
/// `.ended`; a single tap in paint mode is a `.began` immediately followed by `.ended`.
public enum BrushPhase: Sendable { case began, moved, ended }

/// WHICH KIND OF CONTACT a brush sample came from (task 2026-08-04, bar U2).
///
/// The smoothing page's "Pencil only" needs to tell a finger from a pencil, and
/// guessing from touch counts cannot: a pencil is always one contact. So the view
/// mounts a SEPARATE pan recognizer per `UITouch.TouchType` — the two allowed-type
/// sets are disjoint, so exactly one of them can claim any given drag — and each
/// reports which one it is. On macOS there is no pencil, so every sample is
/// `.finger` and the smoothing page's toggle simply never withholds anything.
public enum BrushInput: Sendable { case finger, pencil }

/// A pending detent face-highlight pulse (item 2): which part face to flash, and a token that
/// advances on every fresh snap so the coordinator can tell a NEW snap from an unchanged input.
public struct DetentPulse: Equatable, Sendable {
    public var faceID: FaceID
    public var token: Int
    public init(faceID: FaceID, token: Int) {
        self.faceID = faceID
        self.token = token
    }
}

#if os(iOS)
public struct MetalMeshView: UIViewRepresentable {
    let inputs: MeshViewInputs

    public init(mesh: ViewerMesh?, camera: OrbitCameraModel? = nil, selection: SelectionModel? = nil,
                faceTints: [FaceID: SIMD4<Float>]? = nil,
                vertexTints: [Float]? = nil,
                extraLines: [Float]? = nil,
                previewLines: [Float] = [],
                weldedFaces: [Set<FaceID>] = [],
                cutRibbon: [Float]? = nil,
                cutPlane: SIMD4<Float>? = nil,
                pickChains: [[SIMD4<Float>]] = [],
                xray: Bool = false,
                settleRotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), settleAnimated: Bool = false,
                showGround: Bool = false, faceToolActive: Bool = false,
                onPickFace: ((FaceID) -> Void)? = nil,
                onPickPoint: ((FaceID, SIMD3<Float>?) -> Bool)? = nil,
                onMiss: (() -> Void)? = nil,
                onProjection: ((CameraProjection) -> Void)? = nil,
                onUndo: (() -> Void)? = nil, onRedo: (() -> Void)? = nil,
                stressTints: [SIMD4<Float>]? = nil, stressMultiplier: Float = 1, reveal: Float = 1,
                flexDisplacements: [Float]? = nil, flexScale: Float = 0,
                loadPathSegments: [Float]? = nil, loadPathFlow: Float = 0,
                showWireframe: Bool = false,
                designBox: DesignBoxBounds? = nil, keepOutBoxes: [DesignBoxBounds] = [],
                clearanceVolumes: [ClearanceRenderItem] = [],
                loadFlowVertices: [Float]? = nil, loadFlowKey: Double = 0,
                loadFlowGuides: [Float]? = nil, bodyAlpha: Float = 1,
                detentPulse: DetentPulse? = nil,
                paintActive: Bool = false, paintFaceIDs: [Int32]? = nil,
                onBrush: ((CGPoint, BrushPhase, BrushInput) -> Void)? = nil,
                brushRequiresPencil: Bool = false,
                onBrushRefused: ((BrushInput) -> Void)? = nil,
                latticeLayer: LatticeLayerInputs? = nil) {
        inputs = MeshViewInputs(mesh: mesh, camera: camera, selection: selection, faceTints: faceTints,
                                vertexTints: vertexTints, extraLines: extraLines,
                                cutRibbon: cutRibbon,
                                weldedFaces: weldedFaces, previewLines: previewLines, cutPlane: cutPlane, pickChains: pickChains, xray: xray,
            settleRotation: settleRotation, settleAnimated: settleAnimated, showGround: showGround,
            faceToolActive: faceToolActive, onPickFace: onPickFace,
            onPickPoint: onPickPoint, onMiss: onMiss,
            onProjection: onProjection, onUndo: onUndo, onRedo: onRedo,
            stressTints: stressTints, stressMultiplier: stressMultiplier,
            reveal: reveal, flexDisplacements: flexDisplacements, flexScale: flexScale,
            loadPathSegments: loadPathSegments, showWireframe: showWireframe,
            loadPathFlow: loadPathFlow,
            designBox: designBox, keepOutBoxes: keepOutBoxes,
            clearanceVolumes: clearanceVolumes,
            loadFlowVertices: loadFlowVertices, loadFlowKey: loadFlowKey,
            loadFlowGuides: loadFlowGuides, bodyAlpha: bodyAlpha, detentPulse: detentPulse,
            paintActive: paintActive, paintFaceIDs: paintFaceIDs, onBrush: onBrush,
            brushRequiresPencil: brushRequiresPencil,
            onBrushRefused: onBrushRefused,
            latticeLayer: latticeLayer)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        configure(view, context: context)
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        // ONE RECOGNIZER PER CONTACT KIND (bar U2). The allowed-type sets are
        // disjoint and exhaustive over what an iPad can produce, so every drag is
        // claimed by exactly one of these two and each knows what it is.
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                 NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        let pencilPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePencilPan(_:)))
        pencilPan.allowedTouchTypes =
            [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        // Undo/redo taps (round-6 item 4; redo gesture updated for paint mode, handoff 2026-07-25):
        // TWO-finger double-tap = undo, THREE-finger double-tap = redo. Distinct touch counts, so
        // neither can satisfy the other's recognizer — no `require(toFail:)` is needed — and both
        // need ≥ 2 touches so neither collides with the one-finger pick/paint tap.
        let undoTap = UITapGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handleUndoTap(_:)))
        undoTap.numberOfTouchesRequired = 2
        undoTap.numberOfTapsRequired = 2
        let redoTap = UITapGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handleRedoTap(_:)))
        redoTap.numberOfTouchesRequired = 3
        redoTap.numberOfTapsRequired = 2
        // Two-finger pan (item 2) and pinch-zoom must coexist on the same two touches, so let the
        // pan + pinch recognizers fire simultaneously (a two-finger drag pans; any pinch delta on
        // the same gesture still zooms). The tap is left exclusive.
        pan.delegate = context.coordinator
        pinch.delegate = context.coordinator
        undoTap.delegate = context.coordinator
        redoTap.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pencilPan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(undoTap)
        view.addGestureRecognizer(redoTap)
        return view
    }

    public func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.apply(inputs, to: view)
    }
}
#elseif os(macOS)
public struct MetalMeshView: NSViewRepresentable {
    let inputs: MeshViewInputs

    public init(mesh: ViewerMesh?, camera: OrbitCameraModel? = nil, selection: SelectionModel? = nil,
                faceTints: [FaceID: SIMD4<Float>]? = nil,
                vertexTints: [Float]? = nil,
                extraLines: [Float]? = nil,
                previewLines: [Float] = [],
                weldedFaces: [Set<FaceID>] = [],
                cutRibbon: [Float]? = nil,
                cutPlane: SIMD4<Float>? = nil,
                pickChains: [[SIMD4<Float>]] = [],
                xray: Bool = false,
                settleRotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), settleAnimated: Bool = false,
                showGround: Bool = false, faceToolActive: Bool = false,
                onPickFace: ((FaceID) -> Void)? = nil,
                onPickPoint: ((FaceID, SIMD3<Float>?) -> Bool)? = nil,
                onMiss: (() -> Void)? = nil,
                onProjection: ((CameraProjection) -> Void)? = nil,
                onUndo: (() -> Void)? = nil, onRedo: (() -> Void)? = nil,
                stressTints: [SIMD4<Float>]? = nil, stressMultiplier: Float = 1, reveal: Float = 1,
                flexDisplacements: [Float]? = nil, flexScale: Float = 0,
                loadPathSegments: [Float]? = nil, loadPathFlow: Float = 0,
                showWireframe: Bool = false,
                designBox: DesignBoxBounds? = nil, keepOutBoxes: [DesignBoxBounds] = [],
                clearanceVolumes: [ClearanceRenderItem] = [],
                loadFlowVertices: [Float]? = nil, loadFlowKey: Double = 0,
                loadFlowGuides: [Float]? = nil, bodyAlpha: Float = 1,
                detentPulse: DetentPulse? = nil,
                paintActive: Bool = false, paintFaceIDs: [Int32]? = nil,
                onBrush: ((CGPoint, BrushPhase, BrushInput) -> Void)? = nil,
                brushRequiresPencil: Bool = false,
                onBrushRefused: ((BrushInput) -> Void)? = nil,
                latticeLayer: LatticeLayerInputs? = nil) {
        inputs = MeshViewInputs(mesh: mesh, camera: camera, selection: selection, faceTints: faceTints,
                                vertexTints: vertexTints, extraLines: extraLines,
                                cutRibbon: cutRibbon,
                                weldedFaces: weldedFaces, previewLines: previewLines, cutPlane: cutPlane, pickChains: pickChains, xray: xray,
            settleRotation: settleRotation, settleAnimated: settleAnimated, showGround: showGround,
            faceToolActive: faceToolActive, onPickFace: onPickFace,
            onPickPoint: onPickPoint, onMiss: onMiss,
            onProjection: onProjection, onUndo: onUndo, onRedo: onRedo,
            stressTints: stressTints, stressMultiplier: stressMultiplier,
            reveal: reveal, flexDisplacements: flexDisplacements, flexScale: flexScale,
            loadPathSegments: loadPathSegments, showWireframe: showWireframe,
            loadPathFlow: loadPathFlow,
            designBox: designBox, keepOutBoxes: keepOutBoxes,
            clearanceVolumes: clearanceVolumes,
            loadFlowVertices: loadFlowVertices, loadFlowKey: loadFlowKey,
            loadFlowGuides: loadFlowGuides, bodyAlpha: bodyAlpha, detentPulse: detentPulse,
            paintActive: paintActive, paintFaceIDs: paintFaceIDs, onBrush: onBrush,
            brushRequiresPencil: brushRequiresPencil,
            onBrushRefused: onBrushRefused,
            latticeLayer: latticeLayer)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        configure(view, context: context)
        let pan = NSPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        let magnify = NSMagnificationGestureRecognizer(target: context.coordinator,
                                                       action: #selector(Coordinator.handleMagnify(_:)))
        let click = NSClickGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handleClick(_:)))
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(magnify)
        view.addGestureRecognizer(click)
        return view
    }

    public func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.apply(inputs, to: view)
    }
}
#endif

extension MetalMeshView {
    /// Shared MTKView configuration (device, formats, dark clear color, on-demand
    /// drawing) and renderer wiring for both platforms.
    fileprivate func configure(_ view: MTKView, context: Context) {
        let device = MTLCreateSystemDefaultDevice()
        view.device = device
        view.colorPixelFormat = MeshRenderer.colorFormat
        view.depthStencilPixelFormat = MeshRenderer.depthFormat
        let bg = DS.Color.background
        view.clearColor = MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)
        view.isPaused = true                 // draw on demand (battery)
        view.enableSetNeedsDisplay = true
        if let device, let renderer = MeshRenderer(device: device) {
            // §3b ANTI-ALIASING. `MTKView` owns the multisample texture and the
            // resolve when `sampleCount > 1` — the drawable becomes the resolve
            // target — so the whole feature is this one line plus a matching
            // `rasterSampleCount` on the pipelines. The renderer reports what it
            // actually got: a device that cannot do 4× falls back to 1× in its init.
            view.sampleCount = renderer.sampleCount
            context.coordinator.renderer = renderer
            view.delegate = renderer
        }
    }

    /// A comparable key for the highlight state, so it rebuilds only on change.
    private struct TintKey: Equatable {
        let tint: [FaceID: SIMD4<Float>]
        let active: Set<FaceID>
    }

    @MainActor
    public final class Coordinator: NSObject {
        var renderer: MeshRenderer?
        /// The shared camera source of truth (STEP 1), when the host provides one. The
        /// renderer's own `camera` becomes a mirror kept in sync from this via `sink`.
        private var cameraModel: OrbitCameraModel?
        private var cameraCancellable: AnyCancellable?
        private weak var boundView: MTKView?
        private var appliedSignature: ViewerMeshSignature?
        private var appliedTint: TintKey?
        private var appliedVertexTint: VertexTintKey?
        private var appliedExtraLineCount = -1
        private var appliedCutPlane: SIMD4<Float>??
        private var appliedRibbonCount = -1
        private var appliedPickShape: [Int] = []
        private var lastSettleVector: SIMD4<Float>?
        /// M7.8: whether a stress overlay is currently uploaded, and the last reveal.
        private var appliedStress = false
        /// The tint array actually uploaded, so a CHANGED one re-uploads (D4).
        private var appliedStressTints: [SIMD4<Float>]?
        /// M7.viz coupling: the multiplier the uploaded tints were computed at, so a
        /// change (the animating flex/push) forces a re-upload → the heatmap recolors.
        private var appliedStressMultiplier: Float = 1
        private var appliedReveal: Float = 1
        /// M7.viz.3: whether flex displacements are uploaded, and the last scale.
        private var appliedFlex = false
        private var appliedFlexScale: Float = 0
        /// M7.viz.4: whether load-path segments are uploaded, and the last flow phase.
        private var appliedLoadPath = false
        private var appliedWireframe = false
        private var appliedLoadPathFlow: Float = 0
        /// Load-path FLOW (handoff 070): whether the comet flow is on, the last comet
        /// key (re-upload each animation tick), guide signature, and body alpha.
        private var appliedFlow = false
        private var appliedFlowKey: Double = -1
        private var appliedGuideSig = -1
        /// The detent-pulse token last fired (item 2); a fresh token flashes the matched face.
        private var appliedPulseToken = -1
        private var appliedBodyAlpha: Float = 1
        /// M7.dom-app: the design box + keep-outs last uploaded, so the gizmo geometry
        /// rebuilds only when the boxes actually change (not every camera tick).
        private var appliedDesignBox: DesignBoxBounds?
        private var appliedKeepOuts: [DesignBoxBounds] = []
        private var appliedDesignBoxSet = false
        private var appliedClearanceVolumes: [ClearanceRenderItem] = []
        /// The unified lattice layer's bake token and tint dictionary as last applied,
        /// so a scene bake and a tint bake each happen once per real change — an orbit
        /// tick re-evaluates the workspace body and must not rebake anything (bar P2).
        private var appliedLatticeToken: Int = -1
        private var appliedLatticeTints: [FaceID: SIMD4<Float>]? = nil
        private var appliedClearanceSet = false
        private var lastPublished: CameraProjection?
        private var faceToolActive = false
        private var onPickFace: ((FaceID) -> Void)?
        private var onPickPoint: ((FaceID, SIMD3<Float>?) -> Bool)?
        private var onMiss: (() -> Void)?
        private var onProjection: ((CameraProjection) -> Void)?
        private var onUndo: (() -> Void)?
        private var onRedo: (() -> Void)?
        /// Paint mode (handoff 2026-07-25): when on, a one-finger drag paints; two fingers orbit.
        private var paintActive = false
        private var onBrush: ((CGPoint, BrushPhase, BrushInput) -> Void)?
        private var brushRequiresPencil = false
        private var onBrushRefused: ((BrushInput) -> Void)?

        /// THE ONE ROUTING DECISION (task 2026-08-05, bar D1). Both pan
        /// recognizers ask this value where a drag goes, so "is the brush armed"
        /// and "may this contact paint" cannot be answered differently in two
        /// places — which is exactly what killed the pencil.
        private var gesture: BrushGesture {
            BrushGesture(armed: paintActive, requiresPencil: brushRequiresPencil)
        }
        /// The effective face ids last uploaded (native + painted overrides), so the id/tint buffers
        /// rebuild only when the paint overlay actually changes.
        private var appliedPaintFaceIDs: [Int32]?

        /// Upload a new mesh / refresh the highlight / drive the settle / publish the
        /// camera projection — each only when it actually changes.
        func apply(_ inputs: MeshViewInputs, to view: MTKView) {
            guard let renderer else { return }
            boundView = view
            attachCameraModel(inputs.camera, to: view, renderer: renderer)
            faceToolActive = inputs.faceToolActive
            onPickFace = inputs.onPickFace
            onPickPoint = inputs.onPickPoint
            onMiss = inputs.onMiss
            onProjection = inputs.onProjection
            onUndo = inputs.onUndo
            onRedo = inputs.onRedo
            paintActive = inputs.paintActive
            onBrush = inputs.onBrush
            brushRequiresPencil = inputs.brushRequiresPencil
            onBrushRefused = inputs.onBrushRefused

            var dirty = false
            let sig = inputs.mesh.map(meshSignature)
            if sig != appliedSignature {
                appliedSignature = sig
                if let mesh = inputs.mesh {
                    // With a shared model, mirror its orientation onto the renderer BEFORE
                    // framing (so the fit keeps the user's azimuth/elevation), then hand the
                    // freshly-framed distance/target back to the model — it stays the single
                    // source of truth.
                    if let model = cameraModel { renderer.camera = model.camera }
                    // `applyMesh`, NOT `setMesh` (task 2026-08-08, S1a). A brush
                    // stroke hands back the SAME surface with moved vertices, and
                    // `setMesh` would reframe the camera and restart the settle
                    // for it — the "one stroke resets the whole page" defect.
                    // `applyMesh` routes that case to an in-place position
                    // upload; everything else still lands in `setMesh`.
                    let outcome = renderer.applyMesh(mesh)
                    if outcome == .reframed, let model = cameraModel {
                        // Handing the freshly-framed camera back to the shared model
                        // REPUBLISHES it (`@Published camera` on the @StateObject the
                        // live body observes). `apply` runs inside `updateUIView` — a
                        // SwiftUI view-update pass — so doing that synchronously is
                        // "Publishing changes from within view updates" UB, and it
                        // floods every time the displayed mesh changes (each streamed
                        // variant during a run, and the See-Original view swap). Hop the
                        // write-back to the next runloop so the model updates cleanly
                        // AFTER this render pass; the renderer already holds the framed
                        // camera for the current draw.
                        let framed = renderer.camera
                        DispatchQueue.main.async { [weak model] in model?.adopt(framed) }
                    }
                    // ONLY A REFRAME INVALIDATES THESE. `setMesh` zeroes the tint
                    // buffer and resets the settle to identity, so both have to be
                    // re-applied after it. The in-place path touches neither — and
                    // clearing `lastSettleVector` there would re-run `beginSettle`
                    // with its 0.8 s animation on every stroke, which is the part
                    // of "resets the entire page" that is not the camera.
                    if outcome == .reframed {
                        appliedTint = nil        // rebuild highlight for the new mesh
                        lastSettleVector = nil   // re-apply settle for the new mesh
                    }
                } else {
                    appliedTint = nil
                    lastSettleVector = nil
                }
                dirty = true
            }

            // Settle (M7.6 D2): animate/snap to the gravity rotation on change.
            let sv = inputs.settleRotation.vector
            if sv != lastSettleVector {
                lastSettleVector = sv
                renderer.beginSettle(to: inputs.settleRotation,
                                     duration: inputs.settleAnimated ? 0.8 : 0)
                if renderer.isSettling {     // run continuous frames until it lands
                    view.isPaused = false
                    view.enableSetNeedsDisplay = false
                }
                dirty = true
            }

            // Detent face-highlight PULSE (item 2): a fresh token (a new snap) flashes the matched
            // part face in the viewer, then the pulse runs continuous frames until it fades out —
            // the in-viewer replacement for the old "Snapped to face" toast.
            if let pulse = inputs.detentPulse, pulse.token != appliedPulseToken {
                appliedPulseToken = pulse.token
                renderer.beginDetentPulse(faceID: pulse.faceID)
                view.isPaused = false
                view.enableSetNeedsDisplay = false
                dirty = true
            }

            if renderer.showGround != inputs.showGround {
                renderer.showGround = inputs.showGround
                dirty = true
            }

            // Paint mode (handoff 2026-07-25): override the per-triangle face ids the id-pass PICK
            // and highlight TINT read, so a painted region is one face. A mesh swap rebuilt
            // `flatFaceIDs` from the NATIVE ids, so re-apply the overlay when the mesh changed too;
            // clearing to nil restores the native ids (paint erased away). Runs BEFORE the tint
            // block so the re-tint below reads the updated ids.
            if dirty || inputs.paintFaceIDs != appliedPaintFaceIDs {
                appliedPaintFaceIDs = inputs.paintFaceIDs
                renderer.setEffectiveFaceIDs(inputs.paintFaceIDs ?? inputs.mesh?.faceIDs ?? [])
                appliedTint = nil          // painted ids changed which triangles a face covers → re-tint
                dirty = true
            }

            if let stress = inputs.stressTints {
                // THE TINTS THEMSELVES ARE A TRIGGER (task 2026-08-05, bar D4).
                //
                // The conditions below could all be false while the tint array
                // was completely different: `dirty` is about the MESH, and the
                // brush does not change the mesh; `appliedStress` was already
                // true from the first upload; the multiplier is 1 on this page
                // and never moves; and there is no flow. So every stroke after
                // the first uploaded nothing — the second half of why the brush
                // tint never appeared. Comparing the array is O(n) on a value
                // that is already rebuilt per update, and it is the only signal
                // that cannot be forgotten by a caller.
                let tintsMoved = stress != appliedStressTints
                // M7.8 results stress overlay: per-vertex colors replace face tints.
                // Re-upload on mesh change (dirty), when the overlay turns on, when the
                // coupling multiplier moves (the flex loop / failure push), OR — for the
                // load-path FLOW "Stress" body — when the flow clock advances. In flow
                // mode the tints change because the moving epicenters (arrow HEADS) shift
                // the bloom every tick, NOT because a scalar multiplier moves; without the
                // flow-key trigger the bloom would freeze at the first frame while the
                // arrows travelled on (the moving bloom was computed but never re-uploaded).
                let flowTintsMoved = inputs.loadFlowVertices != nil && inputs.loadFlowKey != appliedFlowKey
                if dirty || !appliedStress || inputs.stressMultiplier != appliedStressMultiplier
                    || flowTintsMoved || tintsMoved {
                    appliedStress = true
                    appliedStressMultiplier = inputs.stressMultiplier
                    appliedStressTints = stress
                    renderer.setStressTints(stress)
                    dirty = true
                }
            } else {
                if appliedStress {
                    appliedStress = false; appliedStressMultiplier = 1
                    appliedStressTints = nil; appliedTint = nil
                }  // rebuild plain tints
                // Highlight tint (role-aware if provided, else the group palette).
                let tint = inputs.faceTints ?? derivedTint(inputs.selection)
                let active = Set(inputs.selection?.activeGroup?.faces ?? [])
                let key = TintKey(tint: tint, active: active)
                if key != appliedTint {
                    appliedTint = key
                    renderer.setHighlights(faceTint: tint, activeFaces: active)
                    dirty = true
                }
                // ★ §6 — THE PER-VERTEX OVERRIDE, APPLIED AFTER the face map so it
                // wins. Keyed by count + head rather than compared whole: it is
                // four floats per vertex, and a full compare on every body
                // evaluation is the "viewer lag = selectedMesh rebuild" mistake in
                // a new place.
                let vkey = inputs.vertexTints.map { VertexTintKey($0) }
                if vkey != appliedVertexTint {
                    appliedVertexTint = vkey
                    renderer.setVertexTints(inputs.vertexTints ?? [])
                    dirty = true
                }
                // ★ §6 — the plane itself is four floats; comparing it is free, so
                // it is compared rather than keyed.
                let rkey = inputs.cutRibbon?.count ?? 0
                if rkey != appliedRibbonCount {
                    appliedRibbonCount = rkey
                    renderer.setCutRibbon(inputs.cutRibbon ?? [],
                                          rgba: SIMD4<Float>(1.0, 0.78, 0.20, 0.95))
                    dirty = true
                }
                let pkey = inputs.pickChains.map(\.count)
                if inputs.cutPlane != appliedCutPlane || pkey != appliedPickShape {
                    appliedCutPlane = inputs.cutPlane
                    appliedPickShape = pkey
                    renderer.setCutPlane(inputs.cutPlane ?? .zero,
                                         selected: SurfaceTint.selected,
                                         sibling: SurfaceTint.sibling,
                                         enabled: inputs.cutPlane != nil,
                                         pickGroups: inputs.pickChains)
                    dirty = true
                }
            }

            // M7.8 morph scrub reveal.
            if inputs.reveal != appliedReveal || dirty {
                appliedReveal = inputs.reveal
                renderer.setReveal(inputs.reveal)
                dirty = true
            }

            // M7.viz.3 flex: upload the per-vertex displacement vectors on mesh change
            // / when they first arrive (they only depend on the mesh + field, not the
            // phase); the scale is a cheap per-frame uniform that drives the loop.
            if let flex = inputs.flexDisplacements {
                if dirty || !appliedFlex {
                    appliedFlex = true
                    renderer.setFlexDisplacements(flex)
                    dirty = true
                }
            } else if appliedFlex {
                appliedFlex = false
                renderer.resetFlex()      // re-zero so a stale variant can't displace
                appliedFlexScale = 0
                dirty = true
            }
            if inputs.flexScale != appliedFlexScale {
                appliedFlexScale = inputs.flexScale
                renderer.setFlexScale(inputs.flexScale)
                dirty = true
            }

            // M7.viz.4 load-path: upload the segment buffer on mesh change / first
            // arrival (a variant selection changes the mesh → dirty → rebuild); clear
            // when the overlay turns off so a stale variant's glyphs can't linger.
            // ★ §6(b) — the wireframe follows the MESH, so it rebuilds whenever the
            // mesh does and clears the moment the stage turns it off.
            if inputs.showWireframe {
                if renderer.xrayLines != inputs.xray { renderer.xrayLines = inputs.xray; dirty = true }
                // ★ HASHED, NOT COUNTED — THE SAME TRAP `VertexTintKey` ALREADY PAID
                // FOR ONCE ON THIS BRANCH.
                //
                // This was `extraLines?.count`. A cut that MOVES a boundary rather
                // than adding one — re-cutting a piece, rotating a pattern, undoing
                // and redoing — changes every coordinate in the buffer and the count
                // not at all, so the key compared equal and the lines on screen were
                // the previous ones. The commit had happened; the screen had not
                // moved. Indistinguishable from a tool that does nothing, which is
                // how it gets reported.
                var h = Hasher()
                h.combine(inputs.extraLines?.count ?? 0)
                for f in inputs.extraLines ?? [] { h.combine(f) }
                h.combine(inputs.previewLines.count)
                for f in inputs.previewLines { h.combine(f) }
                for set in inputs.weldedFaces { h.combine(set.sorted()) }
                let lineKey = h.finalize()
                if dirty || !appliedWireframe || lineKey != appliedExtraLineCount {
                    appliedExtraLineCount = lineKey
                    appliedWireframe = true
                    // ★ THE CUT TRACES RIDE WITH THE WIREFRAME (maintainer: "the
                    // cuts need to be visible in the wireframe view after any cut
                    // is made"). Same buffer, same pass: a cut boundary IS an edge
                    // of the surface once it exists, so it belongs to the same
                    // line set as the B-rep edges rather than to a layer of its own.
                    let base = inputs.mesh.map {
                        SurfaceWireframe.edges(of: $0, welded: inputs.weldedFaces)
                    } ?? []
                    // ★ TWO BANDS: what EXISTS, and what is being DECIDED.
                    // A committed cut is an edge of the surface, so it is drawn in
                    // the same grey as every other edge — it stops being news the
                    // moment it is made. The pattern preview is the only thing on
                    // screen that has not happened yet, and it is the only thing
                    // that wears the accent.
                    let structure = base + (inputs.extraLines ?? [])
                    renderer.setWireframe(
                        structure + inputs.previewLines,
                        // ★ DARK GREY, NOT BLUE. The stage tints faces blue, so a
                        // blue wireframe competes with the very thing it is meant
                        // to sit on top of and reads as part of the fill. A dark
                        // neutral line has nothing to compete with: it lands
                        // legibly on the pale wash, the deep selection blue and the
                        // untinted body alike.
                        rgba: SIMD4<Float>(0.14, 0.15, 0.17, 1.0),
                        accentFrom: structure.count,
                        // Warm white-gold: nothing else on this page is warm, so a
                        // cut trace and a pattern preview cannot be mistaken for
                        // structure.
                        accent: SIMD4<Float>(1.0, 0.86, 0.40, 1.0))
                    dirty = true
                }
            } else if appliedWireframe {
                appliedWireframe = false
                renderer.setWireframe([], rgba: .zero)
                dirty = true
            }

            if let segments = inputs.loadPathSegments {
                if dirty || !appliedLoadPath {
                    appliedLoadPath = true
                    renderer.setLoadPath(segments)
                    dirty = true
                }
                // The flow phase is a cheap per-frame uniform (like flexScale): a change
                // re-draws → the traveling dash advances. This is what animates the flow.
                if inputs.loadPathFlow != appliedLoadPathFlow {
                    appliedLoadPathFlow = inputs.loadPathFlow
                    renderer.setLoadPathFlow(inputs.loadPathFlow)
                    dirty = true
                }
            } else if appliedLoadPath {
                appliedLoadPath = false
                appliedLoadPathFlow = 0
                renderer.clearLoadPath()
                dirty = true
            }

            // Load-path FLOW (handoff 070): the comet geometry is rebuilt every
            // animation tick, so re-upload it whenever the per-frame `loadFlowKey`
            // moves (that is what animates the arrows). Guides + body alpha change only
            // on selection / body-mode change, so re-upload them on their own signals.
            if let flow = inputs.loadFlowVertices {
                // apply() runs once per ticker tick (a `flowClock` change re-evaluates the
                // SwiftUI body), so re-upload the per-frame comet geometry unconditionally
                // here — that is what animates the arrows, and it also covers a paused
                // param change (style/wiggle/isolate/reduced) that alters the same frame.
                renderer.setLoadFlow(flow)
                appliedFlowKey = inputs.loadFlowKey
                let gsig = inputs.loadFlowGuides?.count ?? 0
                if !appliedFlow || gsig != appliedGuideSig {
                    appliedGuideSig = gsig
                    renderer.setFlowGuides(inputs.loadFlowGuides ?? [])
                }
                if !appliedFlow || inputs.bodyAlpha != appliedBodyAlpha {
                    appliedBodyAlpha = inputs.bodyAlpha
                    renderer.setBodyAlpha(inputs.bodyAlpha)
                }
                appliedFlow = true
                dirty = true
            } else if appliedFlow {
                appliedFlow = false
                appliedFlowKey = -1
                appliedGuideSig = -1
                appliedBodyAlpha = 1
                renderer.clearLoadFlow()
                dirty = true
            }

            // M7.dom-app design-box gizmo: rebuild the box geometry only when the box
            // or keep-outs change (or on a mesh change, which resets the buffers).
            if dirty || !appliedDesignBoxSet || inputs.designBox != appliedDesignBox
                || inputs.keepOutBoxes != appliedKeepOuts {
                appliedDesignBoxSet = true
                appliedDesignBox = inputs.designBox
                appliedKeepOuts = inputs.keepOutBoxes
                renderer.setDesignBoxes(design: inputs.designBox,
                                        designColor: MeshRenderer.designBoxColor,
                                        keepOuts: inputs.keepOutBoxes,
                                        keepOutColor: MeshRenderer.keepOutColor)
                dirty = true
            }

            // Keep-clear v2 (Part 3): rebuild the clearance volumes only when they change
            // (a mesh change resets the buffers and forces a rebuild via `dirty`). The
            // affix toggle / numeric edit changes the item set, which re-tessellates live.
            if dirty || !appliedClearanceSet || inputs.clearanceVolumes != appliedClearanceVolumes {
                appliedClearanceSet = true
                appliedClearanceVolumes = inputs.clearanceVolumes
                renderer.setClearanceVolumes(inputs.clearanceVolumes)
                dirty = true
            }

            // ★ THE UNIFIED LATTICE LAYER (task 2026-08-18-unified-shading). The scene's
            // volumes are baked once per TOKEN — never per SwiftUI update, and an orbit
            // tick is a SwiftUI update (bar P2). The params and the tints are cheap and
            // guarded inside the renderer, so this block is three property writes on an
            // ordinary camera change.
            if let lat = inputs.latticeLayer {
                if appliedLatticeToken != lat.sceneToken {
                    appliedLatticeToken = lat.sceneToken
                    renderer.setLatticeScene(lat.scene, token: lat.sceneToken)
                    dirty = true
                }
                if renderer.latticeParams != lat.params {
                    renderer.latticeParams = lat.params
                    dirty = true
                }
                if appliedLatticeTints != lat.faceTints {
                    appliedLatticeTints = lat.faceTints
                    renderer.setLatticeFaceTints(lat.faceTints)
                    dirty = true
                }
            } else if appliedLatticeToken != -1 {
                appliedLatticeTints = nil
                appliedLatticeToken = -1
                renderer.setLatticeScene(nil, token: -1)
                dirty = true
            }

            if dirty { redraw(view) }
            // Publish the camera projection (deduped) on the NEXT runloop, never inline:
            // `onProjection` writes the host view's `@State projection`, and `apply` runs
            // inside `updateUIView` (a SwiftUI view-update pass), so an inline publish is
            // "Modifying state during view update" UB. The async pass also catches the
            // post-layout viewport when the first update ran before layout.
            DispatchQueue.main.async { [weak self] in self?.publishProjection(from: view) }
        }

        private func derivedTint(_ selection: SelectionModel?) -> [FaceID: SIMD4<Float>] {
            guard let selection else { return [:] }
            var tint: [FaceID: SIMD4<Float>] = [:]
            for g in selection.groups {
                let c = g.color
                let v = SIMD4<Float>(Float(c.r), Float(c.g), Float(c.b), 1)
                for f in g.faces { tint[f] = v }
            }
            return tint
        }

        /// Subscribe to the shared camera model (STEP 1): mirror every published camera
        /// onto the renderer and redraw. This is how a drag/snap the GIZMO triggers, or
        /// the eased snap animation, reaches the Metal view without a full SwiftUI pass.
        /// Idempotent — re-attaching the same model is a no-op.
        private func attachCameraModel(_ model: OrbitCameraModel?, to view: MTKView, renderer: MeshRenderer) {
            guard cameraModel !== model else { return }
            cameraModel = model
            cameraCancellable = nil
            guard let model else { return }
            renderer.camera = model.camera
            cameraCancellable = model.$camera.sink { [weak self, weak view, weak renderer] cam in
                // `$camera` is only ever mutated on the main actor (the model is
                // @MainActor), so this delivery is already on main.
                MainActor.assumeIsolated {
                    guard let self, let view, let renderer else { return }
                    renderer.camera = cam
                    self.redraw(view)
                    self.publishProjection(from: view)
                }
            }
        }

        /// Compute + publish the camera→screen projection when it has changed.
        private func publishProjection(from view: MTKView) {
            guard let renderer, let onProjection else { return }
            let size = view.bounds.size
            guard size.width > 0, size.height > 0 else { return }
            let proj = CameraProjection(camera: renderer.camera, viewportSize: size)
            guard proj != lastPublished else { return }
            lastPublished = proj
            onProjection(proj)
        }

        private func redraw(_ view: MTKView) {
            #if os(iOS)
            view.setNeedsDisplay()
            #elseif os(macOS)
            view.needsDisplay = true
            #endif
        }

        /// Resolve a tap at `location` (view coordinates, origin top-left) to a face
        /// id — id pass first, CPU `FacePicker` as fallback. Reports the hit, or
        /// `onMiss` when the tap hit empty space (M7.6: drop the pending group).
        private func pick(at location: CGPoint, in view: MTKView) {
            guard faceToolActive, !paintActive, let renderer else { return }
            let size = view.bounds.size
            guard size.width > 0, size.height > 0 else { return }
            let normalized = CGPoint(x: location.x / size.width, y: location.y / size.height)
            let w = Int(view.drawableSize.width), h = Int(view.drawableSize.height)

            // ★ ONE RAY, IN *MODEL* SPACE, FOR EVERYTHING BELOW.
            //
            // The mesh is drawn through a settle rotation (the part is dropped onto
            // the floor), so the camera's ray is in WORLD space while
            // `mesh.positions` are in MODEL space. Undoing the display transform
            // once, here, is what makes the CPU fallback and the hit point agree
            // with the GPU id pass instead of quietly answering about a part in a
            // pose nothing is drawn in.
            let modelRay: (origin: SIMD3<Float>, dir: SIMD3<Float>) = {
                let (o, d) = FacePicker.ray(camera: renderer.camera,
                                            aspect: Float(size.width / size.height),
                                            point: normalized)
                let frame = renderer.pickModelFrame
                let inv = frame.rotation.inverse
                return (frame.centre + inv.act(o - frame.centre), inv.act(d))
            }()
            let surfaceHit = renderer.mesh.flatMap {
                FacePicker.hit(rayOrigin: modelRay.origin, rayDir: modelRay.dir, mesh: $0)
            }

            // ★ THE PASS DECIDES, AND A BACKGROUND PIXEL IS A MISS — FULL STOP.
            //
            // This used to be `pickFaceID(…) ?? FacePicker.pick(…)`, which asks the
            // CPU picker to second-guess a pass that already said "nothing here".
            // See `FaceIDPass`: that is why a tap on the floor beside the part
            // selected a face.
            let faceID: FaceID?
            switch renderer.pickFacePass(atNormalizedPoint: normalized, width: w, height: h) {
            case .face(let f):
                faceID = f
            case .background:
                faceID = nil                       // ★ answered: empty space.
            case .unavailable:
                // No GPU pass at all — the CPU picker is the only answer available,
                // and it now casts the SAME model-space ray, so a miss is a miss.
                faceID = surfaceHit.flatMap { $0.faceID >= 0 ? $0.faceID : nil }
            }

            // ★ §6 — THE HIT POINT, ALONGSIDE THE FACE. A cut does not create a
            // face, so both halves answer to the same id: the FACE says which
            // surface, and only the POINT says which half.
            if let faceID {
                // ★ THE POINT-AWARE HANDLER GETS FIRST REFUSAL. It is the only one
                // that can tell two pieces of one face apart.
                if onPickPoint?(faceID, surfaceHit?.point) != true { onPickFace?(faceID) }
            } else { onMiss?() }
        }

        #if os(iOS)
        /// THE PENCIL'S OWN PAN (bar U2). Mounted with
        /// `allowedTouchTypes = [.pencil]`, so it is the only recognizer a pencil
        /// drag can drive and the finger pan is the only one a finger can — the
        /// two sets are disjoint, which is what makes "which contact was this?" a
        /// fact rather than an inference from touch counts (a pencil is always
        /// exactly one contact, so counting could never have answered it).
        ///
        /// A pencil ALWAYS paints while the brush is armed, whatever
        /// `brushRequiresPencil` says — that toggle withholds the FINGER, never
        /// the pencil. The gate that decides "armed" is `BrushGesture`, and it is
        /// the same value the finger's recognizer asks (task 2026-08-05, bar D1):
        /// this handler used to read a flag the page computed from a FINGER-only
        /// property, so "Pencil only" disarmed the pencil.
        ///
        /// AND A PENCIL DRAG THE BRUSH DOES NOT WANT DRIVES THE CAMERA. Round 3
        /// mounted this recognizer with `allowedTouchTypes = [.pencil]`, which
        /// makes it the ONLY recognizer a pencil drag can reach — so returning
        /// early left the pencil unable to orbit anywhere in the app while the
        /// brush was off. It falls through to the same camera gestures a finger
        /// does now.
        @objc func handlePencilPan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view as? MTKView else { return }
            guard gesture.route(.pencil, touches: g.numberOfTouches) == .paint else {
                driveCamera(g, in: view, pan: false)
                return
            }
            let loc = g.location(in: view)
            switch g.state {
            case .began: onBrush?(loc, .began, .pencil)
            case .changed: onBrush?(loc, .moved, .pencil)
            default: onBrush?(loc, .ended, .pencil)
            }
        }

        /// Hand a drag to the camera — orbit, or CAD-pan with two fingers.
        private func driveCamera(_ g: UIPanGestureRecognizer, in view: MTKView,
                                 pan: Bool) {
            let t = g.translation(in: view)
            if pan {
                let h = Float(view.bounds.height)
                if let model = cameraModel {
                    model.pan(dx: Float(t.x), dy: Float(t.y), viewportHeight: h)
                } else {
                    renderer?.camera.pan(dx: Float(t.x), dy: Float(t.y), viewportHeight: h)
                    redraw(view); publishProjection(from: view)
                }
            } else if let model = cameraModel {
                model.orbit(dx: Float(t.x), dy: Float(t.y))   // sink redraws + publishes
            } else {
                renderer?.camera.orbit(dx: Float(t.x), dy: Float(t.y))
                redraw(view); publishProjection(from: view)
            }
            g.setTranslation(.zero, in: view)
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view as? MTKView else { return }

            // Paint mode (handoff 2026-07-25): a ONE-finger drag PAINTS (the brush follows the
            // finger); TWO fingers ORBIT so the camera stays drivable mid-paint. Outside paint mode
            // the gestures are unchanged (one finger orbits, two fingers pan).
            //
            // …UNLESS THE BRUSH HAS BEEN GIVEN TO THE PENCIL (task 2026-08-04,
            // bar U2). Then a finger never brushes and this whole branch is
            // skipped, so the drag falls through to the ordinary camera gestures
            // below — one finger orbits. That fall-through IS the guarantee: the
            // page always has a single-finger orbit without a mode to switch.
            // Two fingers → CAD pan; one finger → orbit (item 2). A two-finger drag with little
            // pinch delta reads as a pure pan (the pinch recognizer contributes ~no zoom).
            switch gesture.route(.finger, touches: g.numberOfTouches) {
            case .paint:
                let loc = g.location(in: view)
                switch g.state {
                case .began: onBrush?(loc, .began, .finger)
                case .changed: onBrush?(loc, .moved, .finger)
                default: onBrush?(loc, .ended, .finger)   // ended / cancelled / failed close the stroke
                }
            case .orbit:
                // An ARMED brush that will not take this contact says so ONCE, as
                // the drag starts (bar D1b) — the drag still orbits.
                if g.state == .began, gesture.refuses(.finger) { onBrushRefused?(.finger) }
                driveCamera(g, in: view, pan: false)
            case .pan:
                if g.state == .began, gesture.refuses(.finger) { onBrushRefused?(.finger) }
                driveCamera(g, in: view, pan: true)
            }
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let view = g.view as? MTKView, g.scale > 0 else { return }
            if let model = cameraModel {
                model.zoom(Float(1 / g.scale))
            } else {
                renderer?.camera.zoom(Float(1 / g.scale))  // spread (scale>1) → closer
                redraw(view); publishProjection(from: view)
            }
            g.scale = 1
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view = g.view as? MTKView else { return }
            let loc = g.location(in: view)
            // Paint mode: a single tap paints a dab (a began→ended stroke at one point). Outside
            // paint mode a tap picks a face (tap-select is unchanged).
            //
            // THROUGH THE SAME GATE (task 2026-08-05). This read `paintActive`
            // directly, so with the brush given to the pencil a finger TAP still
            // painted a dab — the one place a finger could mark the part while
            // "Pencil only" was on.
            if gesture.admits(.finger) {
                onBrush?(loc, .began, .finger)
                onBrush?(loc, .ended, .finger)
                return
            }
            if gesture.armed { return }   // a parked brush is not a face picker
            pick(at: loc, in: view)
        }

        // Undo/redo taps: two-finger double-tap → undo, three-finger double-tap → redo (2026-07-25).
        @objc func handleUndoTap(_ g: UITapGestureRecognizer) {
            guard g.state == .ended else { return }
            onUndo?()
        }

        @objc func handleRedoTap(_ g: UITapGestureRecognizer) {
            guard g.state == .ended else { return }
            onRedo?()
        }
        #elseif os(macOS)
        @objc func handlePan(_ g: NSPanGestureRecognizer) {
            guard let view = g.view as? MTKView else { return }
            let t = g.translation(in: view)
            // AppKit y is up → negate to the screen-down convention `pan`/`orbit` take. A two-finger
            // trackpad drag isn't a pan-recognizer event on macOS, so Option-drag pans (item 2); a
            // plain drag orbits.
            if NSEvent.modifierFlags.contains(.option) {
                let h = Float(view.bounds.height)
                if let model = cameraModel {
                    model.pan(dx: Float(t.x), dy: Float(-t.y), viewportHeight: h)
                } else {
                    renderer?.camera.pan(dx: Float(t.x), dy: Float(-t.y), viewportHeight: h)
                    redraw(view); publishProjection(from: view)
                }
            } else if let model = cameraModel {
                model.orbit(dx: Float(t.x), dy: Float(-t.y))
            } else {
                renderer?.camera.orbit(dx: Float(t.x), dy: Float(-t.y))
                redraw(view); publishProjection(from: view)
            }
            g.setTranslation(.zero, in: view)
        }

        @objc func handleMagnify(_ g: NSMagnificationGestureRecognizer) {
            guard let view = g.view as? MTKView else { return }
            if let model = cameraModel {
                model.zoom(Float(1 / (1 + g.magnification)))
            } else {
                renderer?.camera.zoom(Float(1 / (1 + g.magnification)))
                redraw(view); publishProjection(from: view)
            }
            g.magnification = 0
        }

        @objc func handleClick(_ g: NSClickGestureRecognizer) {
            guard let view = g.view as? MTKView else { return }
            // AppKit view coordinates are y-up; the pick expects y-down (top-left).
            var p = g.location(in: view)
            p.y = view.bounds.height - p.y
            pick(at: p, in: view)
        }
        #endif
    }
}

#if os(iOS)
extension MetalMeshView.Coordinator: UIGestureRecognizerDelegate {
    /// Let the pan + pinch recognizers fire on the same two touches (two-finger pan while
    /// pinch-zooming, item 2); keep the tap exclusive. Stateless, so it stays off the main actor.
    public nonisolated func gestureRecognizer(_ g: UIGestureRecognizer,
                                              shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        !(g is UITapGestureRecognizer) && !(other is UITapGestureRecognizer)
    }
}
#endif

#else  // !canImport(MetalKit) — keep the workspace compiling everywhere.
public struct MetalMeshView: View {
    public init(mesh: ViewerMesh?, camera: OrbitCameraModel? = nil, selection: SelectionModel? = nil,
                faceTints: [FaceID: SIMD4<Float>]? = nil,
                vertexTints: [Float]? = nil,
                extraLines: [Float]? = nil,
                previewLines: [Float] = [],
                weldedFaces: [Set<FaceID>] = [],
                cutRibbon: [Float]? = nil,
                cutPlane: SIMD4<Float>? = nil,
                pickChains: [[SIMD4<Float>]] = [],
                xray: Bool = false,
                settleRotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
                settleAnimated: Bool = false, showGround: Bool = false,
                faceToolActive: Bool = false, onPickFace: ((FaceID) -> Void)? = nil,
                onMiss: (() -> Void)? = nil, onProjection: ((CameraProjection) -> Void)? = nil,
                onUndo: (() -> Void)? = nil, onRedo: (() -> Void)? = nil,
                stressTints: [SIMD4<Float>]? = nil, stressMultiplier: Float = 1, reveal: Float = 1,
                flexDisplacements: [Float]? = nil, flexScale: Float = 0,
                loadPathSegments: [Float]? = nil, loadPathFlow: Float = 0,
                showWireframe: Bool = false,
                designBox: DesignBoxBounds? = nil, keepOutBoxes: [DesignBoxBounds] = [],
                clearanceVolumes: [ClearanceRenderItem] = [],
                loadFlowVertices: [Float]? = nil, loadFlowKey: Double = 0,
                loadFlowGuides: [Float]? = nil, bodyAlpha: Float = 1,
                detentPulse: DetentPulse? = nil,
                paintActive: Bool = false, paintFaceIDs: [Int32]? = nil,
                onBrush: ((CGPoint, BrushPhase, BrushInput) -> Void)? = nil,
                brushRequiresPencil: Bool = false,
                onBrushRefused: ((BrushInput) -> Void)? = nil,
                latticeLayer: LatticeLayerInputs? = nil) {}
    public var body: some View { DS.Color.background.color }
}

/// The paint brush phase — the non-Metal stub mirror so call sites compile on every platform.
public enum BrushPhase: Sendable { case began, moved, ended }

/// WHICH KIND OF CONTACT a brush sample came from (task 2026-08-04, bar U2).
///
/// The smoothing page's "Pencil only" needs to tell a finger from a pencil, and
/// guessing from touch counts cannot: a pencil is always one contact. So the view
/// mounts a SEPARATE pan recognizer per `UITouch.TouchType` — the two allowed-type
/// sets are disjoint, so exactly one of them can claim any given drag — and each
/// reports which one it is. On macOS there is no pencil, so every sample is
/// `.finger` and the smoothing page's toggle simply never withholds anything.
public enum BrushInput: Sendable { case finger, pencil }

/// A pending detent face-highlight pulse (item 2) — the non-Metal stub mirror of the MetalKit
/// declaration so call sites compile on every platform.
public struct DetentPulse: Equatable, Sendable {
    public var faceID: FaceID
    public var token: Int
    public init(faceID: FaceID, token: Int) {
        self.faceID = faceID
        self.token = token
    }
}
#endif
