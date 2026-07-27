// TransformGizmoMetal.swift — the Metal render of the 3D liquid-glass TRANSFORM gizmo
// (redesign 2026-07-26, take 2). Sibling of `OrientationGizmoMetal`: it raymarches an SDF in
// a small virtual camera and floats the result on a transparent MTKView, reusing the SAME
// blue-frost material (body / fresnel rim / reflection / see-through back march / premultiplied
// blend) so the transform gizmo looks like it came from the same set as the orientation cube.
//
// The geometry is `TransformGizmo.Constants` (the ONE source; `TransformGizmo.pick` reads the
// same numbers on the CPU). The full manipulator: a hub sphere (free move), three axis arms
// (shaft + conical arrowhead — axis move), three flat SQUARE plates (plane move) and three
// quarter-arc RIBBONS (rotate about the ⟂ axis), all welded into one object. `activeId` glows
// the grabbed handle (0 = hub/free, 1…3 = arms X/Y/Z, 4…6 = squares XY/YZ/ZX,
// 7…9 = ribbons XY/YZ/ZX).
//
// Unlike the orientation cube this gizmo does NOT idle-float or wobble — it is ATTACHED to a
// primitive, so it holds still and only redraws when the view orientation changes (orbit) or
// the active handle changes. That keeps it bit-cheap and rock-steady under the finger.

#if canImport(MetalKit)
import MetalKit
import SwiftUI
import Combine
import QuartzCore
import simd

// MARK: - Per-frame uniforms (layout MUST match the MSL struct)

struct TGUniforms {
    var rotInv: simd_float3x3   // view→object (R_gizmoᵀ)
    var activeId: Float
    var _pad: SIMD3<Float> = .zero
}

final class TransformGizmoRenderer: NSObject, MTKViewDelegate {
    static let primarySteps = 190
    static let maxDPR: CGFloat = 2.0
    static var lastInitError: String?

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    /// object→view rotation (camera.viewRotation · settle). Written on the main thread.
    var rotation: simd_float3x3 = matrix_identity_float3x3
    /// Which handle to glow, or -1.
    var activeId: Float = -1

    init?(device: MTLDevice, constants c: TransformGizmo.Constants = .standard) {
        guard let queue = device.makeCommandQueue() else {
            Self.lastInitError = "makeCommandQueue nil"; return nil
        }
        self.queue = queue
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource(c), options: nil)
        } catch {
            Self.lastInitError = "makeLibrary: \(error)"; return nil
        }
        guard let vfn = library.makeFunction(name: "tg_vertex"),
              let ffn = library.makeFunction(name: "tg_fragment") else {
            Self.lastInitError = "makeFunction nil"; return nil
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
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
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var u = TGUniforms(rotInv: rotation.transpose, activeId: activeId)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<TGUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<TGUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: - Shader (constants injected from the single source)

    static func shaderSource(_ c: TransformGizmo.Constants) -> String {
        func f(_ v: Float) -> String {
            var s = String(format: "%.7g", v)
            if !s.contains(".") && !s.contains("e") { s += ".0" }
            return s
        }
        return """
        #include <metal_stdlib>
        using namespace metal;

        struct TGUniforms { float3x3 uRotInv; float uActive; };
        struct VOut { float4 pos [[position]]; float2 uv; };

        vertex VOut tg_vertex(uint vid [[vertex_id]]) {
            float2 p = float2(float((vid << 1) & 2), float(vid & 2));
            VOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = p * 2.0 - 1.0; return o;
        }

        constant float HUBR   = \(f(c.hubR));
        constant float ARMR   = \(f(c.armR));
        constant float SHEND  = \(f(c.shaftEnd));
        constant float TIP    = \(f(c.tip));
        constant float HEADR  = \(f(c.headR));
        constant float PLIN   = \(f(c.plateInner));
        constant float PLOUT  = \(f(c.plateOuter));
        constant float PLTH   = \(f(c.plateHalfThick));
        constant float ARCR   = \(f(c.arcR));
        constant float ARCT   = \(f(c.arcTube));
        constant float WELD   = \(f(c.weld));
        constant float FOVc   = \(f(c.fov));
        constant float CAMZc  = \(f(c.camZ));

        static inline float sminf(float a, float b, float k){
            float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
            return mix(b, a, h) - k * h * (1.0 - h);
        }
        static inline float sdSphere(float3 p, float r){ return length(p) - r; }
        static inline float sdCap(float3 p, float3 a, float3 b, float r){
            float3 pa = p - a, ba = b - a;
            float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
            return length(pa - ba * h) - r;
        }
        // iq CAPPED cone (segment a[ra] → b[rb]): a real cone with a FLAT circular base at a
        // and a sharp point at b (rb≈0) — a regular arrowhead, not a bulbous round cone.
        static float sdCone(float3 p, float3 a, float3 b, float ra, float rb){
            float rba = rb - ra;
            float baba = dot(b - a, b - a);
            float papa = dot(p - a, p - a);
            float paba = dot(p - a, b - a) / baba;
            float x = sqrt(max(papa - paba * paba * baba, 0.0));
            float cax = max(0.0, x - ((paba < 0.5) ? ra : rb));
            float cay = abs(paba - 0.5) - 0.5;
            float k = rba * rba + baba;
            float f = clamp((rba * (x - ra) + paba * baba) / k, 0.0, 1.0);
            float cbx = x - ra - f * rba;
            float cby = paba - f;
            float s = (cbx < 0.0 && cay < 0.0) ? -1.0 : 1.0;
            return s * sqrt(min(cax * cax + cay * cay * baba, cbx * cbx + cby * cby * baba));
        }
        static inline float sdBox(float3 p, float3 b){
            float3 q = abs(p) - b;
            return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
        }
        // Flat SQUARE plate = the two-axis (plane) translate handle (plane pl: 0=XY,1=YZ,2=ZX).
        // A thin slab spanning the [PLIN,PLOUT] square in the +,+ quadrant of its plane, thin
        // along the plane normal — a real box SDF (Lipschitz-1), so no candy-stripe artifact and
        // it reads as a flat plate, clearly distinct from the round axis rods (and NOT an arc,
        // which would read as rotation).
        static float sdPlate(float3 p, int pl){
            float mid = 0.5 * (PLIN + PLOUT);
            float hs = 0.5 * (PLOUT - PLIN);        // half-side (NB: `half` is an MSL type)
            float3 cen, b;
            if (pl == 0)      { cen = float3(mid, mid, 0.0); b = float3(hs, hs, PLTH); }
            else if (pl == 1) { cen = float3(0.0, mid, mid); b = float3(PLTH, hs, hs); }
            else              { cen = float3(mid, 0.0, mid); b = float3(hs, PLTH, hs); }
            return sdBox(p - cen, b);
        }
        // Quarter-arc RIBBON (rotate handle) welded between two adjacent arms (plane pl:
        // 0=XY,1=YZ,2=ZX), as a FLATTENED ribbon: in-plane radial width, squashed out-of-plane
        // so it reads as a thin curved PLATE, distinct from the round rods and the flat squares.
        static float sdArc(float3 p, int pl){
            float2 cc; float zz;
            if (pl == 0) { cc = p.xy; zz = p.z; }
            else if (pl == 1) { cc = p.yz; zz = p.x; }
            else { cc = float2(p.z, p.x); zz = p.y; }
            float rad = length(cc) - ARCR;
            const float SQUASH = 3.0;                  // out-of-plane flatten → curved plate
            float2 q = float2(rad, zz * SQUASH);
            // Divide by SQUASH so the scaled field stays a CONSERVATIVE distance (≤ the true
            // distance). Scaling an SDF's input breaks its Lipschitz bound, so a plain
            // `length(q)-ARCT` overshoots the thin ribbon under sphere-tracing and aliases into
            // the candy-stripe/spiral artifact; the division removes it.
            float d = (length(q) - ARCT) / SQUASH;
            d = max(d, -cc.x);
            d = max(d, -cc.y);
            return d;
        }

        // Per-part distances: [0]=hub, [1..3]=arms X/Y/Z, [4..6]=plates XY/YZ/ZX,
        // [7..9]=ribbons XY/YZ/ZX (rotation).
        static void parts(float3 p, thread float (&dp)[10]){
            dp[0] = sdSphere(p, HUBR);
            float3 ex = float3(1,0,0), ey = float3(0,1,0), ez = float3(0,0,1);
            dp[1] = min(sdCap(p, ex*HUBR*0.4, ex*SHEND, ARMR), sdCone(p, ex*SHEND, ex*TIP, HEADR, 0.012));
            dp[2] = min(sdCap(p, ey*HUBR*0.4, ey*SHEND, ARMR), sdCone(p, ey*SHEND, ey*TIP, HEADR, 0.012));
            dp[3] = min(sdCap(p, ez*HUBR*0.4, ez*SHEND, ARMR), sdCone(p, ez*SHEND, ez*TIP, HEADR, 0.012));
            dp[4] = sdPlate(p, 0);
            dp[5] = sdPlate(p, 1);
            dp[6] = sdPlate(p, 2);
            dp[7] = sdArc(p, 0);
            dp[8] = sdArc(p, 1);
            dp[9] = sdArc(p, 2);
        }
        static float mapF(float3 p){
            float dp[10]; parts(p, dp);
            float d = dp[0];
            for (int i = 1; i < 10; i++) d = sminf(d, dp[i], WELD);
            return d;
        }
        static int nearestPart(float3 p){
            float dp[10]; parts(p, dp);
            float m = dp[0]; int mi = 0;
            for (int i = 1; i < 10; i++) if (dp[i] < m) { m = dp[i]; mi = i; }
            return mi;
        }
        static float3 calcNormal(float3 p){
            const float2 e = float2(0.0025, -0.0025);
            return normalize(
                e.xyy*mapF(p+e.xyy) + e.yyx*mapF(p+e.yyx) +
                e.yxy*mapF(p+e.yxy) + e.xxx*mapF(p+e.xxx));
        }

        fragment float4 tg_fragment(VOut in [[stage_in]], constant TGUniforms& U [[buffer(0)]]){
            float tf = tan(FOVc * 0.5 * 3.14159265 / 180.0);
            float3 roW = float3(0.0, 0.0, CAMZc);
            float3 rdW = normalize(float3(in.uv * tf, -1.0));
            float3 ro = U.uRotInv * roW;
            float3 rd = normalize(U.uRotInv * rdW);

            // Bounding-sphere reject (r ≈ 1.25 fits the whole gizmo).
            float3 closest = ro + rd * dot(-ro, rd);
            if (dot(closest, closest) > 1.3 * 1.3) { return float4(0.0); }

            float t = CAMZc - 2.0;
            float d; float3 pos = ro; bool hit = false;
            for (int i = 0; i < \(primarySteps); i++){
                pos = ro + rd * t;
                d = mapF(pos);
                if (d < 0.0012) { hit = true; break; }
                t += d * 0.5;                  // conservative step — slender tubes are easy to skip
                if (t > CAMZc + 2.0) break;
            }
            if (!hit) { return float4(0.0); }

            float3 n = calcNormal(pos);
            float3 nW = n * U.uRotInv;
            float3 vW = -rdW;
            float ndv = clamp(dot(nW, vW), 0.0, 1.0);
            float fres = pow(1.0 - ndv, 2.6);

            // The SAME liquid-glass material as the corner Position cube (deep frosted body, cool
            // inner haze + soft core glow, a bright fresnel rim, a top reflection band and crisp
            // speculars) — MORE OPAQUE than the cube so it reads as a control. Axis colour by
            // part: X = red, Y = green, Z = blue; the plane SQUARE and the rotation RIBBON share
            // their plane's axis colour (YZ → red, ZX → green, XY → blue), so two of the squares
            // and two of the ribbons are tinted like the arrows and the rest stay blue.
            int pid = nearestPart(pos);
            bool isRed   = (pid == 1 || pid == 5 || pid == 8);   // X arm · YZ square · YZ ribbon
            bool isGreen = (pid == 2 || pid == 6 || pid == 9);   // Y arm · ZX square · ZX ribbon
            float3 bodyC, hazeC, rimC;
            if (isRed) {
                bodyC = float3(0.150, 0.048, 0.052);
                hazeC = float3(0.86, 0.44, 0.42);
                rimC  = float3(1.00, 0.70, 0.68);
            } else if (isGreen) {
                bodyC = float3(0.050, 0.135, 0.062);
                hazeC = float3(0.46, 0.86, 0.50);
                rimC  = float3(0.70, 1.00, 0.74);
            } else {                   // Z arm · XY square · XY ribbon · hub → the cube's blue
                bodyC = float3(0.038, 0.065, 0.135);
                hazeC = float3(0.34, 0.52, 0.86);
                rimC  = float3(0.60, 0.78, 1.00);
            }

            float coreNear = length(ro - rd * dot(ro, rd));
            float core = smoothstep(0.50, 0.05, coreNear) * 0.20;
            float haze = 0.14 * ndv + core;
            float3 col = mix(bodyC, hazeC, haze);
            col += rimC * fres * 0.9;                                     // fresnel rim
            float3 refl = reflect(rdW, nW);
            float band = smoothstep(0.55, 0.92, refl.y) * pow(clamp(refl.y, 0.0, 1.0), 2.0);
            col += rimC * band * 0.42;                                    // top reflection
            float3 l1 = normalize(float3(0.35, 0.9, 0.6));
            float3 l2 = normalize(float3(-0.6, -0.35, 0.7));
            float s1 = pow(max(dot(reflect(-l1, nW), vW), 0.0), 90.0);
            float s2 = pow(max(dot(reflect(-l2, nW), vW), 0.0), 160.0) * 0.6;
            col += float3(1.0) * (s1 + s2);                              // crisp glints

            // Glow the grabbed handle brighter/whiter.
            float hov = (abs(float(pid) - U.uActive) < 0.5) ? 1.0 : 0.0;
            col = mix(col, float3(1.0), hov * 0.28);

            // Opacity — firmer than the cube (round-3 ask). A solid frosted body so the gizmo
            // reads as a control you reach for, still firming further at the rim + speculars and
            // letting a little of the scene through.
            float a = 0.46 + fres * 0.42 + haze * 0.30 + (s1 + s2) * 0.5 + band * 0.26 + hov * 0.14;
            a = clamp(a, 0.0, 0.97);
            return float4(col * a, a);
        }
        """
    }
}

// MARK: - SwiftUI host (transparent MTKView floating at the primitive)

struct TransformGizmoMetalView {
    @ObservedObject var camera: OrbitCameraModel
    /// The model→world settle rotation as a matrix (identity if the part isn't settled).
    var settle: simd_float3x3
    /// The glowing handle id, or -1.
    var activeId: Float

    @MainActor
    final class Coordinator: NSObject {
        var renderer: TransformGizmoRenderer?
        var settle: simd_float3x3 = matrix_identity_float3x3
        private var cancellable: AnyCancellable?

        func bind(_ camera: OrbitCameraModel, to view: MTKView) {
            renderer?.rotation = camera.viewRotation * settle
            cancellable = camera.$camera.sink { [weak self, weak view] cam in
                MainActor.assumeIsolated {
                    guard let self, let view else { return }
                    self.renderer?.rotation = cam.viewRotation() * self.settle
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

    @MainActor func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    fileprivate func configure(_ view: MTKView, _ coordinator: Coordinator) {
        let device = MTLCreateSystemDefaultDevice()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        #if os(iOS)
        view.isOpaque = false
        view.layer.isOpaque = false
        view.isUserInteractionEnabled = false     // gestures live on the SwiftUI overlay
        view.contentScaleFactor = min(view.contentScaleFactor, TransformGizmoRenderer.maxDPR)
        #elseif os(macOS)
        view.layer?.isOpaque = false
        #endif
        coordinator.settle = settle
        if let device, let renderer = TransformGizmoRenderer(device: device) {
            coordinator.renderer = renderer
            view.delegate = renderer
        }
        coordinator.bind(camera, to: view)
        apply(view, coordinator)
    }

    @MainActor
    fileprivate func apply(_ view: MTKView, _ coordinator: Coordinator) {
        coordinator.settle = settle
        coordinator.renderer?.rotation = camera.viewRotation * settle
        coordinator.renderer?.activeId = activeId
        // Static object — no display link; redraw on demand (orbit sink + this apply).
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = 60
        #if os(iOS)
        view.setNeedsDisplay()
        #elseif os(macOS)
        view.needsDisplay = true
        #endif
    }
}

#if os(iOS)
extension TransformGizmoMetalView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(); configure(view, context.coordinator); return view
    }
    func updateUIView(_ view: MTKView, context: Context) { apply(view, context.coordinator) }
}
#elseif os(macOS)
extension TransformGizmoMetalView: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(); configure(view, context.coordinator); return view
    }
    func updateNSView(_ view: MTKView, context: Context) { apply(view, context.coordinator) }
}
#endif
#endif
