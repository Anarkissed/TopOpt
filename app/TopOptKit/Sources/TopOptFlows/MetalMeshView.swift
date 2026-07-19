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

#if canImport(MetalKit)
import MetalKit
import QuartzCore

// ---------------------------------------------------------------------------
// GPU uniforms — must match the `Uniforms` layout in the shaders below.
private struct ViewerUniforms {
    var mvp: simd_float4x4
    var normalMatrix: simd_float4x4  // view rotation (upper-left 3×3), padded
    /// M7.viz.3 flex: `.x` = displacement scale (exaggeration·amplitude) added to
    /// each rest vertex before the MVP. Appended AFTER mvp/normalMatrix so the id
    /// pass (which reads only that prefix) is unaffected.
    var flex: SIMD4<Float> = .zero
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
    var _pad: Float = 0          // 16-byte tail alignment
}

// The neutral-clay shader (M7.4) + a selection tint (M7.5), compiled at runtime so
// the SwiftPM target needs no .metal resource bundling (identical on iOS/macOS).
private let viewerShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VIn  { float3 position [[attribute(0)]]; float3 normal [[attribute(1)]]; float4 tint [[attribute(2)]]; };
struct VOut { float4 position [[position]]; float3 vnormal; float4 tint; float mheight; };
struct Uniforms { float4x4 mvp; float4x4 normalMatrix; float4 flex; };

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
                                constant float& bodyAlpha [[buffer(1)]]) {
    if (reveal.w > 0.5) {
        float t = (in.mheight - reveal.y) / max(reveal.z - reveal.y, 1e-4);
        if (t > reveal.x) discard_fragment();
    }
    float3 N = normalize(in.vnormal);
    // Neutral-clay: soft half-Lambert key + gentle hemisphere fill over a light
    // base, faint cool fresnel. Front faces have N.z > 0 (eye looks down −Z).
    float3 clay = float3(0.78, 0.77, 0.75);
    float3 key  = normalize(float3(0.30, 0.60, 0.72));
    // NB: avoid the name `half` — a reserved 16-bit-float type in MSL that makes
    // makeLibrary fail (silently blanking the whole stage).
    float  keyWrap = clamp(dot(N, key) * 0.5 + 0.5, 0.0, 1.0);
    float  fill = clamp(dot(N, float3(-0.45, -0.25, 0.40)) * 0.5 + 0.5, 0.0, 1.0);
    float  lighting = 0.60 + 0.42 * keyWrap + 0.12 * fill;
    float3 color = clay * lighting;
    float  fres = pow(1.0 - clamp(N.z, 0.0, 1.0), 4.0) * 0.10;
    color += float3(0.10, 0.12, 0.16) * fres;
    // Selection tint: mix in the group colour (kept lit); tint.a encodes strength
    // (active group stronger). No tint → tint.a == 0 → unchanged.
    if (in.tint.a > 0.001) {
        color = mix(color, in.tint.rgb * (0.55 + 0.45 * lighting), in.tint.a);
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

fragment float4 stage_fragment(SOut in [[stage_in]], constant StageUniforms& U [[buffer(0)]]) {
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
private func meshSignature(_ mesh: ViewerMesh) -> [Float] {
    [Float(mesh.vertexCount), Float(mesh.triangleCount),
     mesh.bounds.min.x, mesh.bounds.min.y, mesh.bounds.min.z,
     mesh.bounds.max.x, mesh.bounds.max.y, mesh.bounds.max.z]
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
    /// The exact stage MSL the app ships — exposed so a headless test can compile it and fail
    /// loudly on a typo (the pipeline is otherwise built with `try?`, i.e. nil-on-failure).
    static var stageShaderSourceForTesting: String { stageShaderSource }
    private var modelCenter = SIMD3<Float>.zero
    /// The currently-displayed model rotation (animates toward `settleTo`).
    private var modelRotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    private var settleFrom = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    private var settleTo = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    private var settleStart: CFTimeInterval = 0
    private var settleDuration: CFTimeInterval = 0
    /// True while the settle animation is running (drives continuous redraw).
    private(set) var isSettling = false
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
    private var clearanceFaceBuffer: MTLBuffer?
    private var clearanceFaceCount = 0
    private var clearanceLineBuffer: MTLBuffer?
    private var clearanceLineCount = 0

    static let colorFormat: MTLPixelFormat = .bgra8Unorm
    static let depthFormat: MTLPixelFormat = .depth32Float
    static let idFormat: MTLPixelFormat = .r32Uint
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

    init?(device: MTLDevice) {
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
        vd.layouts[0].stride = MemoryLayout<Float>.stride * 6
        vd.layouts[2].stride = MemoryLayout<Float>.stride * 4

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = Self.colorFormat
        pd.depthAttachmentPixelFormat = Self.depthFormat

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
            groundPipe = try? device.makeRenderPipelineState(descriptor: gpd)
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
            stagePipe = try? device.makeRenderPipelineState(descriptor: spd)
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
            translucentPipe = try? device.makeRenderPipelineState(descriptor: tpd)
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
        self.groundDepthState = device.makeDepthStencilState(descriptor: gdsd) ?? depth
        self.lineOverlayDepthState = device.makeDepthStencilState(descriptor: odsd) ?? depth
        self.loadPathPipeline = lpPipe
        self.cometPipeline = cometPipe
        self.translucentBodyPipeline = translucentPipe
        self.translucentBodyDepthState = device.makeDepthStencilState(descriptor: tdsd) ?? depth
        super.init()
    }

    /// Upload the mesh's flat-shaded (unshared-vertex) buffers — the interleaved
    /// position+normal buffer, the per-vertex face-id buffer (for the id pass) and a
    /// zeroed tint buffer — and frame it.
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
        guard !items.isEmpty else { return }

        // Base clearance red (matches the SwiftUI affix/label tint). ~50% fill (task),
        // brighter when the group is selected; edges near-opaque so the shape reads.
        let baseRGB = SIMD3<Float>(0.95, 0.38, 0.36)
        var faces: [Float] = []
        var lines: [Float] = []
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
        func seg(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ col: SIMD4<Float>) {
            push(&lines, a, col); push(&lines, b, col)
        }

        let ring = 28  // circle tessellation
        for item in items {
            let selected = item.selected
            let faceAlpha: Float = selected ? 0.60 : 0.42
            let edgeAlpha: Float = selected ? 0.98 : 0.80
            let fcol = premul(baseRGB, faceAlpha)
            let ecol = premul(baseRGB, edgeAlpha)
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
    }

    /// Rebuild the per-vertex tint buffer from the selection: each grouped face's
    /// vertices carry that group's colour; the active group is tinted more strongly.
    func setHighlights(faceTint: [FaceID: SIMD4<Float>], activeFaces: Set<FaceID>) {
        buildTintBuffer(faceTint: faceTint, activeFaces: activeFaces)
    }

    /// M7.8 stress overlay: upload per-flat-vertex colors (alpha 1) directly as the
    /// tint buffer, so the fragment shader mixes them over the clay. `colors` must
    /// have one entry per flat vertex (`vertexDrawCount`); a mismatch is ignored.
    func setStressTints(_ colors: [SIMD4<Float>]) {
        guard vertexDrawCount > 0, colors.count == vertexDrawCount else { return }
        var tints = [Float](repeating: 0, count: vertexDrawCount * 4)
        for v in 0..<vertexDrawCount {
            let c = colors[v]
            tints[v * 4] = c.x; tints[v * 4 + 1] = c.y
            tints[v * 4 + 2] = c.z; tints[v * 4 + 3] = c.w
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

    private func buildTintBuffer(faceTint: [FaceID: SIMD4<Float>], activeFaces: Set<FaceID>) {
        guard vertexDrawCount > 0 else { tintBuffer = nil; return }
        var tints = [Float](repeating: 0, count: vertexDrawCount * 4)
        for v in 0..<vertexDrawCount {
            let fid = v < flatFaceIDs.count ? FaceID(bitPattern: flatFaceIDs[v]) : -1
            guard var c = faceTint[fid] else { continue }
            c.w = activeFaces.contains(fid) ? 0.75 : 0.45   // active group brighter
            tints[v * 4] = c.x; tints[v * 4 + 1] = c.y
            tints[v * 4 + 2] = c.z; tints[v * 4 + 3] = c.w
        }
        tintBuffer = tints.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspect = size.height > 0 ? Float(size.width / size.height) : 1
    }

    func draw(in view: MTKView) {
        let wasSettling = isSettling
        if wasSettling { stepSettle() }
        guard let cmd = queue.makeCommandBuffer() else { return }
        if let rpd = view.currentRenderPassDescriptor {
            encode(into: rpd, aspect: aspect, into: cmd, drawStage: true)
        }
        if let drawable = view.currentDrawable { cmd.present(drawable) }
        cmd.commit()
        // The settle finished this frame → return to on-demand drawing (battery).
        if wasSettling && !isSettling {
            view.isPaused = true
            view.enableSetNeedsDisplay = true
        }
    }

    /// Encode the shaded mesh draw into an arbitrary render pass. Shared by the on-screen
    /// `draw(in:)` and the headless `renderOffscreen`. `drawStage` gates the CAD-stage backdrop
    /// (item 9): ON for the live viewer, OFF for offscreen output (thumbnails / exported video
    /// keep their own clear colour) — so the backdrop is a live-viewer treatment only.
    private func encode(into rpd: MTLRenderPassDescriptor, aspect: Float, into cmd: MTLCommandBuffer,
                        drawStage: Bool) {
        guard vertexDrawCount > 0, let vbuf = vertexBuffer, let tbuf = tintBuffer,
              let fbuf = flexBuffer,
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var uniforms = makeUniforms(aspect: aspect)

        // CAD-STAGE backdrop (item 9): the shaded room, drawn FIRST — depth-always + no write
        // (`lineOverlayDepthState`), so the part / box / grid drawn after occlude it. Its uniform
        // is rebuilt only here, on a redraw (camera/mesh change), never on an idle frame.
        if drawStage, let spipe = stagePipeline {
            var su = makeStageUniforms(aspect: aspect)
            enc.setRenderPipelineState(spipe)
            enc.setDepthStencilState(lineOverlayDepthState)
            enc.setVertexBytes(&su, length: MemoryLayout<StageUniforms>.stride, index: 0)
            enc.setFragmentBytes(&su, length: MemoryLayout<StageUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
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
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexDrawCount)

        // Ground grid + contact shadow (M7.6 D2), drawn after the opaque mesh so it
        // blends, depth-tested so the part occludes it, depth-write off.
        if showGround, let gpipe = groundPipeline {
            var gmvp = groundMVP(aspect: aspect)
            enc.setRenderPipelineState(gpipe)
            enc.setDepthStencilState(groundDepthState)
            enc.setVertexBytes(&gmvp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            if let sbuf = groundShadowBuffer, groundShadowCount > 0 {
                enc.setVertexBuffer(sbuf, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: groundShadowCount)
            }
            if let lbuf = groundLineBuffer, groundLineCount > 0 {
                enc.setVertexBuffer(lbuf, offset: 0, index: 0)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: groundLineCount)
            }
        }

        // M7.dom-app design-box gizmo: translucent box faces + bright edges, drawn
        // under the MESH's mvp (uniforms.mvp) so they lock to the part and settle
        // with it. Blended + depth-tested (groundDepthState: test against the part so
        // the part occludes the box's far faces, but no depth write so the box never
        // hides the part). Faces first, then edges on top.
        if (designBoxFaceCount > 0 || designBoxLineCount > 0), let gpipe = groundPipeline {
            var mvp = uniforms.mvp
            enc.setRenderPipelineState(gpipe)
            enc.setDepthStencilState(groundDepthState)
            enc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            if let fbuf = designBoxFaceBuffer, designBoxFaceCount > 0 {
                // Depth-bias the FACES only (items 7+8, part a) so the box glass stops shimmering
                // where it passes through the part; reset before the crisp edge lines.
                enc.setDepthBias(Self.translucentDepthBias, slopeScale: Self.translucentDepthSlopeBias, clamp: 0)
                enc.setVertexBuffer(fbuf, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: designBoxFaceCount)
                enc.setDepthBias(0, slopeScale: 0, clamp: 0)
            }
            if let lbuf = designBoxLineBuffer, designBoxLineCount > 0 {
                enc.setVertexBuffer(lbuf, offset: 0, index: 0)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: designBoxLineCount)
            }
        }

        // Keep-clear v2 (Part 3): the clearance volumes, same MODEL-space mvp + blended
        // depth-tested pass as the design box (the part occludes far faces, no depth
        // write so the volume never hides the part). Faces first, then bright edges.
        if (clearanceFaceCount > 0 || clearanceLineCount > 0), let gpipe = groundPipeline {
            var mvp = uniforms.mvp
            enc.setRenderPipelineState(gpipe)
            enc.setDepthStencilState(groundDepthState)
            enc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            if let fbuf = clearanceFaceBuffer, clearanceFaceCount > 0 {
                // Same z-fighting fix (items 7+8, part a) for the translucent cylinder/slab faces
                // where they pass through the part; reset before the bright edge lines.
                enc.setDepthBias(Self.translucentDepthBias, slopeScale: Self.translucentDepthSlopeBias, clamp: 0)
                enc.setVertexBuffer(fbuf, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: clearanceFaceCount)
                enc.setDepthBias(0, slopeScale: 0, clamp: 0)
            }
            if let lbuf = clearanceLineBuffer, clearanceLineCount > 0 {
                enc.setVertexBuffer(lbuf, offset: 0, index: 0)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: clearanceLineCount)
            }
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
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: loadPathRibbonVertexCount)
        } else if loadPathVertexCount > 0, let lpipe = groundPipeline, let lbuf = loadPathBuffer {
            var mvp = uniforms.mvp
            enc.setRenderPipelineState(lpipe)
            enc.setDepthStencilState(lineOverlayDepthState)
            enc.setVertexBuffer(lbuf, offset: 0, index: 0)
            enc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: loadPathVertexCount)
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
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: flowGuideVertexCount)
            }
            if let fbuf = loadFlowBuffer, loadFlowVertexCount > 0 {
                enc.setVertexBuffer(fbuf, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: loadFlowVertexCount)
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
        return ViewerUniforms(mvp: mvp, normalMatrix: normal4,
                              flex: SIMD4<Float>(flexScale, 0, 0, 0))
    }

    /// The ground's MVP: plain camera view·projection (world-space floor).
    private func groundMVP(aspect: Float) -> simd_float4x4 {
        camera.projectionMatrix(aspect: aspect) * camera.viewMatrix()
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
        return StageUniforms(invVP: inv,
                             eye: camera.eye,
                             floorY: lo.y - extent * 0.02,
                             centerXZ: SIMD2<Float>((lo.x + hi.x) * 0.5, (lo.z + hi.z) * 0.5),
                             spacing: extent / 6,
                             fadeRadius: extent * 6)
    }

    /// Render the current mesh + camera to an offscreen BGRA texture and return the
    /// raw pixel bytes (B,G,R,A per pixel). Used by headless tests to verify the
    /// pipeline rasterizes the mesh — no MTKView/display needed. Nil if nothing to draw.
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
        guard let color = device.makeTexture(descriptor: cdesc),
              let depth = device.makeTexture(descriptor: ddesc),
              let cmd = queue.makeCommandBuffer() else { return nil }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = clear
        rpd.colorAttachments[0].storeAction = .store
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

    /// Resolve the face id at a normalized tap point (x,y ∈ [0,1], y down) via the
    /// id pass. Returns nil on a miss / when the id pass is unavailable — the caller
    /// then falls back to the CPU `FacePicker`.
    func pickFaceID(atNormalizedPoint p: CGPoint, width: Int, height: Int) -> FaceID? {
        guard let ids = renderFaceIDOffscreen(width: width, height: height) else { return nil }
        let px = Swift.min(Swift.max(Int(p.x * CGFloat(width)), 0), width - 1)
        let py = Swift.min(Swift.max(Int(p.y * CGFloat(height)), 0), height - 1)
        let raw = ids[py * width + px]
        return raw == idBackground ? nil : FaceID(bitPattern: raw)
    }
}

// ---------------------------------------------------------------------------
// SwiftUI wrapper around MTKView, cross-platform (UIKit on iOS, AppKit on macOS).

/// The inputs the workspace hands the viewer each SwiftUI update. Bundled so the
/// two platform representables (and the Coordinator) share one signature.
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
    /// The settle rotation to display (gravity → world −Y); identity = un-settled.
    var settleRotation: simd_quatf
    /// Animate the settle (false = snap, for reduced-motion).
    var settleAnimated: Bool
    /// Draw the ground grid + contact shadow (gravity set, edit phase).
    var showGround: Bool
    var faceToolActive: Bool
    var onPickFace: ((FaceID) -> Void)?
    /// Tap that hit no face (drop the pending group, M7.6).
    var onMiss: (() -> Void)?
    /// Published each time the camera changes, so overlays can project 3D points.
    var onProjection: ((CameraProjection) -> Void)?
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
}

#if os(iOS)
public struct MetalMeshView: UIViewRepresentable {
    let inputs: MeshViewInputs

    public init(mesh: ViewerMesh?, camera: OrbitCameraModel? = nil, selection: SelectionModel? = nil,
                faceTints: [FaceID: SIMD4<Float>]? = nil,
                settleRotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), settleAnimated: Bool = false,
                showGround: Bool = false, faceToolActive: Bool = false,
                onPickFace: ((FaceID) -> Void)? = nil, onMiss: (() -> Void)? = nil,
                onProjection: ((CameraProjection) -> Void)? = nil,
                stressTints: [SIMD4<Float>]? = nil, stressMultiplier: Float = 1, reveal: Float = 1,
                flexDisplacements: [Float]? = nil, flexScale: Float = 0,
                loadPathSegments: [Float]? = nil, loadPathFlow: Float = 0,
                designBox: DesignBoxBounds? = nil, keepOutBoxes: [DesignBoxBounds] = [],
                clearanceVolumes: [ClearanceRenderItem] = [],
                loadFlowVertices: [Float]? = nil, loadFlowKey: Double = 0,
                loadFlowGuides: [Float]? = nil, bodyAlpha: Float = 1) {
        inputs = MeshViewInputs(mesh: mesh, camera: camera, selection: selection, faceTints: faceTints,
            settleRotation: settleRotation, settleAnimated: settleAnimated, showGround: showGround,
            faceToolActive: faceToolActive, onPickFace: onPickFace, onMiss: onMiss,
            onProjection: onProjection, stressTints: stressTints, stressMultiplier: stressMultiplier,
            reveal: reveal, flexDisplacements: flexDisplacements, flexScale: flexScale,
            loadPathSegments: loadPathSegments, loadPathFlow: loadPathFlow,
            designBox: designBox, keepOutBoxes: keepOutBoxes,
            clearanceVolumes: clearanceVolumes,
            loadFlowVertices: loadFlowVertices, loadFlowKey: loadFlowKey,
            loadFlowGuides: loadFlowGuides, bodyAlpha: bodyAlpha)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        configure(view, context: context)
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(tap)
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
                settleRotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), settleAnimated: Bool = false,
                showGround: Bool = false, faceToolActive: Bool = false,
                onPickFace: ((FaceID) -> Void)? = nil, onMiss: (() -> Void)? = nil,
                onProjection: ((CameraProjection) -> Void)? = nil,
                stressTints: [SIMD4<Float>]? = nil, stressMultiplier: Float = 1, reveal: Float = 1,
                flexDisplacements: [Float]? = nil, flexScale: Float = 0,
                loadPathSegments: [Float]? = nil, loadPathFlow: Float = 0,
                designBox: DesignBoxBounds? = nil, keepOutBoxes: [DesignBoxBounds] = [],
                clearanceVolumes: [ClearanceRenderItem] = [],
                loadFlowVertices: [Float]? = nil, loadFlowKey: Double = 0,
                loadFlowGuides: [Float]? = nil, bodyAlpha: Float = 1) {
        inputs = MeshViewInputs(mesh: mesh, camera: camera, selection: selection, faceTints: faceTints,
            settleRotation: settleRotation, settleAnimated: settleAnimated, showGround: showGround,
            faceToolActive: faceToolActive, onPickFace: onPickFace, onMiss: onMiss,
            onProjection: onProjection, stressTints: stressTints, stressMultiplier: stressMultiplier,
            reveal: reveal, flexDisplacements: flexDisplacements, flexScale: flexScale,
            loadPathSegments: loadPathSegments, loadPathFlow: loadPathFlow,
            designBox: designBox, keepOutBoxes: keepOutBoxes,
            clearanceVolumes: clearanceVolumes,
            loadFlowVertices: loadFlowVertices, loadFlowKey: loadFlowKey,
            loadFlowGuides: loadFlowGuides, bodyAlpha: bodyAlpha)
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
        private var appliedSignature: [Float]?
        private var appliedTint: TintKey?
        private var lastSettleVector: SIMD4<Float>?
        /// M7.8: whether a stress overlay is currently uploaded, and the last reveal.
        private var appliedStress = false
        /// M7.viz coupling: the multiplier the uploaded tints were computed at, so a
        /// change (the animating flex/push) forces a re-upload → the heatmap recolors.
        private var appliedStressMultiplier: Float = 1
        private var appliedReveal: Float = 1
        /// M7.viz.3: whether flex displacements are uploaded, and the last scale.
        private var appliedFlex = false
        private var appliedFlexScale: Float = 0
        /// M7.viz.4: whether load-path segments are uploaded, and the last flow phase.
        private var appliedLoadPath = false
        private var appliedLoadPathFlow: Float = 0
        /// Load-path FLOW (handoff 070): whether the comet flow is on, the last comet
        /// key (re-upload each animation tick), guide signature, and body alpha.
        private var appliedFlow = false
        private var appliedFlowKey: Double = -1
        private var appliedGuideSig = -1
        private var appliedBodyAlpha: Float = 1
        /// M7.dom-app: the design box + keep-outs last uploaded, so the gizmo geometry
        /// rebuilds only when the boxes actually change (not every camera tick).
        private var appliedDesignBox: DesignBoxBounds?
        private var appliedKeepOuts: [DesignBoxBounds] = []
        private var appliedDesignBoxSet = false
        private var appliedClearanceVolumes: [ClearanceRenderItem] = []
        private var appliedClearanceSet = false
        private var lastPublished: CameraProjection?
        private var faceToolActive = false
        private var onPickFace: ((FaceID) -> Void)?
        private var onMiss: (() -> Void)?
        private var onProjection: ((CameraProjection) -> Void)?

        /// Upload a new mesh / refresh the highlight / drive the settle / publish the
        /// camera projection — each only when it actually changes.
        func apply(_ inputs: MeshViewInputs, to view: MTKView) {
            guard let renderer else { return }
            boundView = view
            attachCameraModel(inputs.camera, to: view, renderer: renderer)
            faceToolActive = inputs.faceToolActive
            onPickFace = inputs.onPickFace
            onMiss = inputs.onMiss
            onProjection = inputs.onProjection

            var dirty = false
            let sig = inputs.mesh.map(meshSignature)
            if sig != appliedSignature {
                appliedSignature = sig
                if let mesh = inputs.mesh {
                    // With a shared model, mirror its orientation onto the renderer BEFORE
                    // framing (so the fit keeps the user's azimuth/elevation), then hand the
                    // freshly-framed distance/target back to the model — it stays the single
                    // source of truth.
                    if let model = cameraModel {
                        renderer.camera = model.camera
                        renderer.setMesh(mesh)
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
                    } else {
                        renderer.setMesh(mesh)
                    }
                }
                appliedTint = nil            // rebuild highlight for the new mesh
                lastSettleVector = nil       // re-apply settle for the new mesh
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

            if renderer.showGround != inputs.showGround {
                renderer.showGround = inputs.showGround
                dirty = true
            }

            if let stress = inputs.stressTints {
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
                    || flowTintsMoved {
                    appliedStress = true
                    appliedStressMultiplier = inputs.stressMultiplier
                    renderer.setStressTints(stress)
                    dirty = true
                }
            } else {
                if appliedStress { appliedStress = false; appliedStressMultiplier = 1; appliedTint = nil }  // rebuild plain tints
                // Highlight tint (role-aware if provided, else the group palette).
                let tint = inputs.faceTints ?? derivedTint(inputs.selection)
                let active = Set(inputs.selection?.activeGroup?.faces ?? [])
                let key = TintKey(tint: tint, active: active)
                if key != appliedTint {
                    appliedTint = key
                    renderer.setHighlights(faceTint: tint, activeFaces: active)
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
                                        designColor: SIMD4<Float>(0.30, 0.78, 0.55, 0.85),
                                        keepOuts: inputs.keepOutBoxes,
                                        keepOutColor: SIMD4<Float>(0.95, 0.42, 0.38, 0.9))
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
            guard faceToolActive, let renderer else { return }
            let size = view.bounds.size
            guard size.width > 0, size.height > 0 else { return }
            let normalized = CGPoint(x: location.x / size.width, y: location.y / size.height)
            let w = Int(view.drawableSize.width), h = Int(view.drawableSize.height)
            let faceID = renderer.pickFaceID(atNormalizedPoint: normalized, width: w, height: h)
                ?? renderer.mesh.flatMap {
                    FacePicker.pick(mesh: $0, camera: renderer.camera,
                                    aspect: Float(size.width / size.height), point: normalized)
                }
            if let faceID { onPickFace?(faceID) } else { onMiss?() }
        }

        #if os(iOS)
        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view as? MTKView else { return }
            let t = g.translation(in: view)
            if let model = cameraModel {
                model.orbit(dx: Float(t.x), dy: Float(t.y))   // sink redraws + publishes
            } else {
                renderer?.camera.orbit(dx: Float(t.x), dy: Float(t.y))
                redraw(view); publishProjection(from: view)
            }
            g.setTranslation(.zero, in: view)
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
            pick(at: g.location(in: view), in: view)
        }
        #elseif os(macOS)
        @objc func handlePan(_ g: NSPanGestureRecognizer) {
            guard let view = g.view as? MTKView else { return }
            let t = g.translation(in: view)
            if let model = cameraModel {
                model.orbit(dx: Float(t.x), dy: Float(-t.y))   // AppKit y is up
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

#else  // !canImport(MetalKit) — keep the workspace compiling everywhere.
public struct MetalMeshView: View {
    public init(mesh: ViewerMesh?, camera: OrbitCameraModel? = nil, selection: SelectionModel? = nil,
                faceTints: [FaceID: SIMD4<Float>]? = nil,
                settleRotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
                settleAnimated: Bool = false, showGround: Bool = false,
                faceToolActive: Bool = false, onPickFace: ((FaceID) -> Void)? = nil,
                onMiss: (() -> Void)? = nil, onProjection: ((CameraProjection) -> Void)? = nil,
                stressTints: [SIMD4<Float>]? = nil, stressMultiplier: Float = 1, reveal: Float = 1,
                flexDisplacements: [Float]? = nil, flexScale: Float = 0,
                loadPathSegments: [Float]? = nil, loadPathFlow: Float = 0,
                designBox: DesignBoxBounds? = nil, keepOutBoxes: [DesignBoxBounds] = [],
                clearanceVolumes: [ClearanceRenderItem] = [],
                loadFlowVertices: [Float]? = nil, loadFlowKey: Double = 0,
                loadFlowGuides: [Float]? = nil, bodyAlpha: Float = 1) {}
    public var body: some View { DS.Color.background.color }
}
#endif
