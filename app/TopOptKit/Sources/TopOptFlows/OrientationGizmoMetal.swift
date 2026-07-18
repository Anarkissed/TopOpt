// OrientationGizmoMetal.swift — the Metal render of the liquid-glass gizmo (support file
// for the orientation-gizmo-redesign task; ports the WebGL fragment shader in
// docs/design/gizmo_redesign.html to MSL).
//
// The mock draws the gizmo by raymarching an SDF "liquid glass" cube in a fragment shader,
// with the geometry constants interpolated into the GLSL source from one `CFG` object. This
// file does the SAME thing in Metal: it builds the MSL fragment shader by interpolating the
// shared `GizmoConstants` (the ONE source, defined in OrientationGizmo.swift), compiles it
// with `device.makeLibrary(source:)` — the house convention (MetalMeshView compiles all its
// shaders from inline strings, so the SwiftPM target needs no `.metal` resource bundling) —
// and renders a full-screen pass into a transparent MTKView that floats over the frosted
// housing drawn behind it in SwiftUI.
//
// The picture and the picking read the same numbers: `OrientationGizmo.pick` sphere-traces
// the identical SDF on the CPU. Change a constant once, both move.
//
// PERF BUDGET (named ceilings; see handoff 105 for the reasoning and the estimate):
//   * primary march capped at `primarySteps` (80), back-face march at `backSteps` (40);
//   * device pixel ratio capped at `maxDPR` (1.5) and the drawable clamped to the gizmo's
//     own small point size — the shader never runs at the FEA viewport's resolution;
//   * the material is SELF-CONTAINED (the mock's dark-glass model): it does NOT sample the
//     live FEA scene behind it, so the cost is fixed regardless of what the viewer shows.
//     This matches the mock, which likewise fakes "what lies behind" in-shader.

#if canImport(MetalKit)
import MetalKit
import SwiftUI
import Combine
import QuartzCore
import simd
import os

/// Signpost log for the results-screen frame audit (handoff — results honesty +
/// perf). Emit an interval around each gizmo raymarch so Instruments' os_signpost
/// track shows how often the gizmo actually draws — near-continuous is the bug this
/// idle fix targets; near-silent when parked is the fix working. Subsystem/category
/// match the results-screen ticker signposts so both land in one lane.
let gizmoSignpost = OSLog(subsystem: "com.topopt.results", category: "GizmoFrame")

// MARK: - Per-frame uniforms (layout MUST match `GizmoUniforms` in the MSL below)

/// The per-frame uniform block. Field order + types are byte-identical to the MSL struct:
/// `simd_float3x3` and MSL `float3x3` are both 48 bytes (three 16-byte-aligned columns), and
/// `simd_float3` and MSL `float3` are both 16 bytes — so this uploads straight into buffer 0.
struct GizmoUniforms {
    var rotInv: simd_float3x3   // world→object (Rᵀ · idle-wobble); the mock's uRotInv
    var offset: simd_float3     // idle float in view space; the mock's uOffset
    var time: Float
    var hoverId: Float
    var hoverAmt: Float
    // Pad to a 16-byte boundary so the CPU/GPU strides agree.
    var _pad: SIMD3<Float> = .zero
}

// MARK: - Renderer

/// Renders the liquid-glass SDF into an MTKView every frame. Reads the live orientation from
/// a provider closure (wired to the shared `OrbitCameraModel`), plus the decorative idle
/// float + hover state the view feeds it.
final class GizmoRenderer: NSObject, MTKViewDelegate {
    /// Raymarch step ceilings (the perf budget lever). Primary is the mock's 80; the back
    /// march — a subtle refraction glint — is trimmed 48→40, imperceptible on device.
    static let primarySteps = 80
    static let backSteps = 40
    static let maxDPR: CGFloat = 1.5

    static var lastInitError: String?

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    /// The current object→view rotation (the camera's `viewRotation()`). A plain, non-isolated
    /// mirror the Coordinator writes from the main actor (via the camera's Combine publisher) and
    /// `draw(in:)` reads on the main thread — the same pattern MeshRenderer uses for its camera.
    var rotation: simd_float3x3 = matrix_identity_float3x3
    /// Which SDF cell (the mock's `globalId`) to glow, or -1 for none. Set by the view.
    var hoverId: Float = -1
    /// Freeze the decorative idle float — set while the user is interacting so taps land
    /// exactly where the glass is drawn (picking uses the settled pose).
    var freezePose = false
    /// Honour Reduce Motion: hold the pose completely still.
    var reduceMotion = false

    /// Wall-clock start, so `time` is seconds since the renderer came up (like the mock's
    /// THREE.Clock). Set on first draw.
    private var startTime: CFTimeInterval = 0
    private var hoverAmt: Float = 0

    init?(device: MTLDevice, constants: GizmoConstants = .standard) {
        guard let queue = device.makeCommandQueue() else {
            Self.lastInitError = "makeCommandQueue nil"; return nil
        }
        self.queue = queue
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource(constants), options: nil)
        } catch {
            Self.lastInitError = "makeLibrary: \(error)"; return nil
        }
        guard let vfn = library.makeFunction(name: "gizmo_vertex"),
              let ffn = library.makeFunction(name: "gizmo_fragment") else {
            Self.lastInitError = "makeFunction nil"; return nil
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        // Premultiplied-alpha over-compositing so the glass floats on the transparent MTKView
        // above the SwiftUI housing. (The mock uses straight alpha in WebGL; the fragment
        // shader here multiplies colour by alpha so this blend is correct.)
        pd.colorAttachments[0].isBlendingEnabled = true
        pd.colorAttachments[0].rgbBlendOperation = .add
        pd.colorAttachments[0].alphaBlendOperation = .add
        pd.colorAttachments[0].sourceRGBBlendFactor = .one
        pd.colorAttachments[0].sourceAlphaBlendFactor = .one
        pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: pd)
        } catch {
            Self.lastInitError = "makeRenderPipelineState: \(error)"; return nil
        }
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let spid = OSSignpostID(log: gizmoSignpost)
        os_signpost(.begin, log: gizmoSignpost, name: "gizmo_draw", signpostID: spid)
        defer { os_signpost(.end, log: gizmoSignpost, name: "gizmo_draw", signpostID: spid) }
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let now = CACurrentMediaTime()
        if startTime == 0 { startTime = now }
        let time = reduceMotion ? 0 : Float(now - startTime)

        // Decorative idle float: incommensurate frequencies so it drifts, never oscillates
        // (verbatim from the mock's loop). Frozen while interacting / Reduce Motion so the
        // picture and the pick agree.
        var offset = simd_float3.zero
        var wobble = matrix_identity_float3x3
        if !reduceMotion && !freezePose {
            let hx = sinf(time * 0.70) * 0.05
            let hy = sinf(time * 1.13 + 1.0) * 0.045
            let hz = (sinf(time * 0.90 + 2.0) * 0.5 + 0.5) * 0.30   // 0 → 0.30 toward viewer
            let wobX = sinf(time * 0.60) * 0.022
            let wobZ = sinf(time * 0.83 + 1.3) * 0.016
            offset = simd_float3(hx, hy, hz)
            wobble = simd_float3x3(simd_quatf(angle: wobX, axis: simd_float3(1, 0, 0)))
                   * simd_float3x3(simd_quatf(angle: wobZ, axis: simd_float3(0, 0, 1)))
        }
        // Ease the hover glow toward its target (the mock's per-frame lerp).
        hoverAmt += ((hoverId >= 0 ? 1 : 0) - hoverAmt) * 0.16

        // uRotInv = (wobble · R)ᵀ = Rᵀ · wobbleᵀ, world→object, exactly the mock's
        // poseQ.conjugate() as a matrix.
        let R = rotation
        let poseRot = wobble * R
        var u = GizmoUniforms(rotInv: poseRot.transpose,
                              offset: offset,
                              time: time, hoverId: hoverId, hoverAmt: hoverAmt)

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<GizmoUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<GizmoUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)   // full-screen triangle
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: - Shader source (constants interpolated from the single source, mock-style)

    /// Build the MSL fragment shader, injecting the shared `GizmoConstants` so the drawn glass
    /// uses the exact numbers the CPU picker uses. This is the direct analogue of the mock's
    /// GLSL template with its `${CFG.X}` holes.
    static func shaderSource(_ c: GizmoConstants) -> String {
        func f(_ v: Float) -> String {
            // Emit a plain decimal literal (MSL reads it as float in a float context).
            var s = String(format: "%.7g", v)
            if !s.contains(".") && !s.contains("e") { s += ".0" }
            return s
        }
        let clR0 = c.clR.x, clR1 = c.clR.y, clR2 = c.clR.z
        return """
        #include <metal_stdlib>
        using namespace metal;

        struct GizmoUniforms {
            float3x3 uRotInv;
            float3   uOffset;
            float    uTime;
            float    uHoverId;
            float    uHoverAmt;
        };

        struct VOut { float4 pos [[position]]; float2 uv; };

        // Full-screen triangle; uv spans clip [-1,1] like the mock's 2×2 plane `position.xy`.
        vertex VOut gizmo_vertex(uint vid [[vertex_id]]) {
            float2 p = float2(float((vid << 1) & 2), float(vid & 2));   // (0,0) (2,0) (0,2)
            VOut o;
            o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
            o.uv  = p * 2.0 - 1.0;
            return o;
        }

        constant float KC        = \(f(c.kCell));
        constant float KL        = \(f(c.kLobe));
        constant float CENTER_R  = \(f(c.centerR));
        constant float FACE_C    = \(f(c.faceC));
        constant float FACE_N    = \(f(c.faceN));
        constant float FACE_T    = \(f(c.faceT));
        constant float FSH_C     = \(f(c.fshC));
        constant float FSH_D     = \(f(c.fshD));
        constant float FSH_R1    = \(f(c.fshR1));
        constant float FSH_R2    = \(f(c.fshR2));
        constant float EM_C      = \(f(c.emC));
        constant float EM_R      = \(f(c.emR));
        constant float EM_L      = \(f(c.emL));
        constant float EF_IN     = \(f(c.efIn));
        constant float EF_R      = \(f(c.efR));
        constant float EF_L      = \(f(c.efL));
        constant float CN_C      = \(f(c.cnC));
        constant float CN_R      = \(f(c.cnR));
        constant float CL_IN     = \(f(c.clIn));
        constant float CL_R0     = \(f(clR0));
        constant float CL_R1     = \(f(clR1));
        constant float CL_R2     = \(f(clR2));
        constant float GROOVE    = \(f(c.groove));
        constant float GROOVE_W  = \(f(c.grooveW));
        constant float FOVc      = \(f(c.fov));
        constant float CAMZc     = \(f(c.camZ));

        static inline float sminf(float a, float b, float k){
            float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
            return mix(b, a, h) - k * h * (1.0 - h);
        }
        static inline float sdEll(float3 p, float3 cc, float3 r){
            float3 q = (p - cc) / r;
            float k0 = length(q);
            float k1 = length(q / r);
            return k0 * (k0 - 1.0) / max(k1, 1e-4);
        }
        static void cellDists(float3 p, thread float (&dc)[8]){
            float3 q = abs(p);
            dc[0] = length(p) - CENTER_R;
            float fx = sdEll(q, float3(FACE_C,0.,0.), float3(FACE_N,FACE_T,FACE_T));
            fx = sminf(fx, sdEll(q, float3(FSH_C,FSH_D,FSH_D), float3(FSH_R1,FSH_R2,FSH_R2)), KL);
            float fy = sdEll(q, float3(0.,FACE_C,0.), float3(FACE_T,FACE_N,FACE_T));
            fy = sminf(fy, sdEll(q, float3(FSH_D,FSH_C,FSH_D), float3(FSH_R2,FSH_R1,FSH_R2)), KL);
            float fz = sdEll(q, float3(0.,0.,FACE_C), float3(FACE_T,FACE_T,FACE_N));
            fz = sminf(fz, sdEll(q, float3(FSH_D,FSH_D,FSH_C), float3(FSH_R2,FSH_R2,FSH_R1)), KL);
            dc[1] = fx; dc[2] = fy; dc[3] = fz;
            float exy = sdEll(q, float3(EM_C,EM_C,0.), float3(EM_R,EM_R,EM_L));
            exy = sminf(exy, sdEll(q, float3(EF_IN,1.0,0.), float3(EF_R,EF_R,EF_L)), KL);
            exy = sminf(exy, sdEll(q, float3(1.0,EF_IN,0.), float3(EF_R,EF_R,EF_L)), KL);
            float eyz = sdEll(q, float3(0.,EM_C,EM_C), float3(EM_L,EM_R,EM_R));
            eyz = sminf(eyz, sdEll(q, float3(0.,EF_IN,1.0), float3(EF_L,EF_R,EF_R)), KL);
            eyz = sminf(eyz, sdEll(q, float3(0.,1.0,EF_IN), float3(EF_L,EF_R,EF_R)), KL);
            float ezx = sdEll(q, float3(EM_C,0.,EM_C), float3(EM_R,EM_L,EM_R));
            ezx = sminf(ezx, sdEll(q, float3(EF_IN,0.,1.0), float3(EF_R,EF_L,EF_R)), KL);
            ezx = sminf(ezx, sdEll(q, float3(1.0,0.,EF_IN), float3(EF_R,EF_L,EF_R)), KL);
            dc[4] = exy; dc[5] = eyz; dc[6] = ezx;
            float co = length(q - float3(CN_C)) - CN_R;
            co = sminf(co, sdEll(q, float3(CL_IN,1.0,1.0), float3(CL_R0*1.5,CL_R0,CL_R0)), KL);
            co = sminf(co, sdEll(q, float3(1.0,CL_IN,1.0), float3(CL_R1,CL_R1*1.5,CL_R1)), KL);
            co = sminf(co, sdEll(q, float3(1.0,1.0,CL_IN), float3(CL_R2,CL_R2,CL_R2*1.5)), KL);
            dc[7] = co;
        }
        static float mapF(float3 p){
            float dc[8]; cellDists(p, dc);
            float d = dc[0], m1 = dc[0], m2 = 1e9;
            for (int i = 1; i < 8; i++){
                d = sminf(d, dc[i], KC);
                if (dc[i] < m1) { m2 = m1; m1 = dc[i]; }
                else if (dc[i] < m2) { m2 = dc[i]; }
            }
            d += GROOVE * (1.0 - smoothstep(0.0, GROOVE_W, m2 - m1));
            return d;
        }
        static float3 calcNormal(float3 p){
            const float2 e = float2(0.004, -0.004);
            return normalize(
                e.xyy*mapF(p+e.xyy) + e.yyx*mapF(p+e.yyx) +
                e.yxy*mapF(p+e.yxy) + e.xxx*mapF(p+e.xxx));
        }
        static float3 hue2rgb(float h){
            float3 p = abs(fract(h + float3(0.0, .333, .667)) * 6.0 - 3.0);
            return clamp(p - 1.0, 0.0, 1.0);
        }
        // The mock's globalId: cell index + hit-position sign bits → a stable 0…26 id, so the
        // CPU (which sets uHoverId) and the shader agree on which cell to light.
        static float globalId(int fi, float3 p){
            float bx = p.x > 0.0 ? 0.0 : 1.0;
            float by = p.y > 0.0 ? 0.0 : 1.0;
            float bz = p.z > 0.0 ? 0.0 : 1.0;
            if (fi == 0) return 0.0;
            if (fi == 1) return 1.0 + bx;
            if (fi == 2) return 3.0 + by;
            if (fi == 3) return 5.0 + bz;
            if (fi == 4) return 7.0  + bx*2.0 + by;
            if (fi == 5) return 11.0 + by*2.0 + bz;
            if (fi == 6) return 15.0 + bz*2.0 + bx;
            return 19.0 + bx*4.0 + by*2.0 + bz;
        }

        fragment float4 gizmo_fragment(VOut in [[stage_in]],
                                       constant GizmoUniforms& U [[buffer(0)]]){
            float tf = tan(FOVc * 0.5 * 3.14159265 / 180.0);
            float3 roW = float3(0.0, 0.0, CAMZc);
            float3 rdW = normalize(float3(in.uv * tf, -1.0));

            float3 ro = U.uRotInv * (roW - U.uOffset);
            float3 rd = normalize(U.uRotInv * rdW);

            // Bounding-sphere reject (perf): the whole SDF fits within r≈1.8 of the origin, so a
            // ray whose closest approach to the origin is beyond that can't hit — skip the march
            // entirely. Identical picture, far cheaper on the empty margin around the glass.
            float3 closest = ro + rd * dot(-ro, rd);
            if (dot(closest, closest) > 2.0 * 2.0) { return float4(0.0); }

            float t = CAMZc - 3.0;
            float d; float3 pos = ro;
            bool hit = false;
            for (int i = 0; i < \(primarySteps); i++){
                pos = ro + rd * t;
                d = mapF(pos);
                if (d < 0.0025) { hit = true; break; }
                t += d * 0.7;
                if (t > CAMZc + 3.0) break;
            }
            if (!hit) { return float4(0.0); }

            float3 n = calcNormal(pos);
            float3 nW = n * U.uRotInv;
            float3 vW = -rdW;
            float ndv = clamp(dot(nW, vW), 0.0, 1.0);
            float fres = pow(1.0 - ndv, 2.6);

            float dc[8]; cellDists(pos, dc);
            float d1 = 1e9, d2 = 1e9; int i1 = 0;
            for (int i = 0; i < 8; i++){
                if (dc[i] < d1) { d2 = d1; d1 = dc[i]; i1 = i; }
                else if (dc[i] < d2) { d2 = dc[i]; }
            }
            float border = 1.0 - smoothstep(0.010, 0.10, d2);

            float3 base = float3(0.045, 0.06, 0.095);
            float coreNear = length(ro - rd * dot(ro, rd));
            float core = smoothstep(0.85, 0.15, coreNear) * 0.20;
            float haze = 0.13 * ndv + core;
            float3 col = mix(base, float3(0.42, 0.47, 0.60), haze);

            float h = ndv * 1.1 + pos.x * 0.06 + U.uTime * 0.012;
            float3 rimCol = mix(float3(0.72, 0.80, 1.0), hue2rgb(fract(h)), 0.30);
            col += rimCol * fres * 0.85;

            col = mix(col, float3(0.015, 0.025, 0.05), border * 0.62);

            float3 refl = reflect(rdW, nW);
            float band = smoothstep(0.55, 0.92, refl.y) * pow(clamp(refl.y, 0.0, 1.0), 2.0);
            col += hue2rgb(fract(refl.x * 0.30 + 0.58)) * band * 0.55;

            float3 l1 = normalize(float3(0.35, 0.9, 0.6));
            float3 l2 = normalize(float3(-0.6, -0.35, 0.7));
            float s1 = pow(max(dot(reflect(-l1, nW), vW), 0.0), 90.0);
            float s2 = pow(max(dot(reflect(-l2, nW), vW), 0.0), 160.0) * 0.6;
            col += float3(1.0) * (s1 + s2);

            float tb = CAMZc + 3.0;
            bool hitB = false; float3 posB = ro;
            for (int i = 0; i < \(backSteps); i++){
                posB = ro + rd * tb;
                float db = mapF(posB);
                if (db < 0.004) { hitB = true; break; }
                tb -= db * 0.7;
                if (tb < t + 0.05) break;
            }
            if (hitB && tb > t + 0.08) {
                float3 nB = calcNormal(posB) * U.uRotInv;
                float glint = pow(1.0 - abs(dot(nB, rdW)), 3.0);
                col += float3(0.45, 0.55, 0.82) * glint * 0.30 * (1.0 - haze * 2.5);
            }

            float id = globalId(i1, pos);
            float hov = (abs(id - U.uHoverId) < 0.5) ? U.uHoverAmt : 0.0;
            col += float3(0.40, 0.58, 1.0) * hov * 0.32;

            float a = 0.44 + fres*0.42 + haze*0.5 + border*0.24 + (s1+s2)*0.5 + band*0.3 + hov*0.12;
            a = clamp(a, 0.0, 0.97);
            return float4(col * a, a);   // premultiplied for the transparent overlay
        }
        """
    }
}

// MARK: - SwiftUI host (transparent MTKView floating over the housing)

/// Embeds the liquid-glass `GizmoRenderer` in a transparent MTKView. The composition around
/// it (housing, buttons, labels, toast, gestures) lives in `OrientationGizmoView`; this is
/// just the Metal surface. Continuous while animated; on Reduce Motion it renders on demand
/// (only when the shared camera publishes) and holds the pose still.
struct GizmoMetalView {
    @ObservedObject var camera: OrbitCameraModel
    /// The SDF cell to glow (the mock's `globalId`), or -1.
    var hoverId: Float
    /// True while a drag/tap is in flight, so the idle float freezes for accurate picking.
    var interacting: Bool
    var reduceMotion: Bool

    @MainActor
    final class Coordinator: NSObject {
        var renderer: GizmoRenderer?
        private var cancellable: AnyCancellable?

        /// Mirror the shared camera's rotation onto the renderer, and — when static (Reduce
        /// Motion, so the view draws on demand) — request a redraw. `$camera` only ever mutates
        /// on the main actor (the model is @MainActor), so delivery is already on main.
        func bind(_ camera: OrbitCameraModel, to view: MTKView) {
            renderer?.rotation = camera.viewRotation
            cancellable = camera.$camera.sink { [weak self, weak view] cam in
                MainActor.assumeIsolated {
                    guard let self, let view else { return }
                    self.renderer?.rotation = cam.viewRotation()
                    if view.isPaused {
                        #if os(iOS)
                        view.setNeedsDisplay()
                        #elseif os(macOS)
                        view.needsDisplay = true
                        #endif
                    }
                }
            }
        }
    }

    @MainActor
    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    fileprivate func configure(_ view: MTKView, _ coordinator: Coordinator) {
        let device = MTLCreateSystemDefaultDevice()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)   // transparent
        #if os(iOS)
        view.isOpaque = false
        view.layer.isOpaque = false
        view.isUserInteractionEnabled = false      // gestures live on the SwiftUI overlay
        view.contentScaleFactor = min(view.contentScaleFactor, GizmoRenderer.maxDPR)
        #elseif os(macOS)
        view.layer?.isOpaque = false
        #endif
        if let device, let renderer = GizmoRenderer(device: device) {
            coordinator.renderer = renderer
            view.delegate = renderer
        }
        coordinator.bind(camera, to: view)
        apply(view, coordinator)
    }

    @MainActor
    fileprivate func apply(_ view: MTKView, _ coordinator: Coordinator) {
        coordinator.renderer?.hoverId = hoverId
        coordinator.renderer?.freezePose = interacting
        coordinator.renderer?.reduceMotion = reduceMotion
        // IDLE WHEN NOTHING MOVES (perf). The SDF raymarch is not cheap; a free-running
        // 60 fps display link that redraws it forever — even sitting untouched on the
        // results screen — burns the GPU for a decorative idle-float and is a prime
        // suspect for the results screen's frame collapse. So run the link CONTINUOUSLY
        // only while the user is actively dragging the glass; otherwise PAUSE it and
        // redraw on demand. Every pose change that matters still paints exactly once:
        //   • a viewer/gizmo drag publishes each orbit delta,
        //   • an animated snap/home eases via the camera's own display link (per-frame
        //     `@Published camera`),
        //   • hover/reduce-motion changes come through `apply` (the explicit redraw below),
        // all caught by the camera sink in `bind` (which requests a redraw while paused).
        // Trade-off (disclosed): the decorative idle wobble no longer plays while idle —
        // which is precisely "idle when the orientation is unchanged". Reduce Motion keeps
        // its existing on-demand, perfectly-still behaviour (it was never continuous).
        let continuous = interacting && !reduceMotion
        view.isPaused = !continuous
        view.enableSetNeedsDisplay = !continuous
        view.preferredFramesPerSecond = 60
        if !continuous {
            #if os(iOS)
            view.setNeedsDisplay()
            #elseif os(macOS)
            view.needsDisplay = true
            #endif
        }
    }
}

#if os(iOS)
extension GizmoMetalView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        configure(view, context.coordinator)
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) { apply(view, context.coordinator) }
}
#elseif os(macOS)
extension GizmoMetalView: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        configure(view, context.coordinator)
        return view
    }
    func updateNSView(_ view: MTKView, context: Context) { apply(view, context.coordinator) }
}
#endif
#endif
