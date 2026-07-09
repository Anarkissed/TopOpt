// MetalMeshView.swift — the M7.4 Metal draw for the workspace stage.
//
// Renders a ViewerMesh with matcap-style analytic shading on the design's dark
// stage, driven by an OrbitCamera the gestures mutate (drag → orbit, pinch /
// magnify → zoom, matching the design hint "Drag to orbit · pinch or scroll to
// zoom"). No selection yet — that is M7.5.
//
// The heavy lifting the tests cover (normals, framing, matrices) lives in
// ViewerMesh.swift / OrbitCamera.swift; this file is the GPU + gesture glue, which
// needs a device and a display and so is maintainer device QA. It is written to
// compile on both the iPad shipping slice and the macOS test slice (MetalKit is
// cross-platform), with a plain-SwiftUI fallback where MetalKit is unavailable so
// the workspace always builds.

import SwiftUI
import TopOptDesign

#if canImport(MetalKit)
import MetalKit
import simd

// ---------------------------------------------------------------------------
// GPU uniforms — must match the `Uniforms` layout in the shader below.
private struct ViewerUniforms {
    var mvp: simd_float4x4
    var normalMatrix: simd_float4x4  // view rotation (upper-left 3×3), padded
}

// The matcap-style shader, compiled at runtime from source so the SwiftPM target
// needs no .metal resource bundling (identical on iOS and macOS).
private let viewerShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VIn  { float3 position [[attribute(0)]]; float3 normal [[attribute(1)]]; };
struct VOut { float4 position [[position]]; float3 vnormal; };
struct Uniforms { float4x4 mvp; float4x4 normalMatrix; };

vertex VOut viewer_vertex(VIn in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
    VOut o;
    o.position = u.mvp * float4(in.position, 1.0);
    o.vnormal  = (u.normalMatrix * float4(in.normal, 0.0)).xyz;
    return o;
}

fragment float4 viewer_fragment(VOut in [[stage_in]]) {
    float3 N = normalize(in.vnormal);
    // View-space analytic studio light: a soft key from upper-right, a cool fill,
    // and a fresnel rim tinted toward the app accent — a matcap look without a
    // matcap texture asset. Front faces have N.z > 0 (eye looks down −Z).
    float3 L    = normalize(float3(0.35, 0.55, 0.75));
    float  key  = clamp(dot(N, L), 0.0, 1.0);
    float  fill = clamp(dot(N, float3(-0.4, -0.2, 0.5)) * 0.5 + 0.5, 0.0, 1.0);
    float3 base = float3(0.60, 0.64, 0.70);
    float3 shade = base * (0.20 + 0.62 * key + 0.20 * fill);
    float  rim  = pow(1.0 - clamp(N.z, 0.0, 1.0), 3.0);
    float3 accent = float3(0.04, 0.52, 1.0);
    float3 color = shade + accent * rim * 0.35;
    return float4(color, 1.0);
}
"""

/// A lightweight signature so the representable re-uploads/re-frames only when a
/// genuinely different mesh arrives (ViewerMesh is a big value type).
private func meshSignature(_ mesh: ViewerMesh) -> [Float] {
    [Float(mesh.vertexCount), Float(mesh.triangleCount),
     mesh.bounds.min.x, mesh.bounds.min.y, mesh.bounds.min.z,
     mesh.bounds.max.x, mesh.bounds.max.y, mesh.bounds.max.z]
}

// ---------------------------------------------------------------------------
// The MTKView delegate: owns the pipeline, the mesh buffers and the camera.
final class MeshRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var indexCount = 0
    private var aspect: Float = 1

    /// The camera the gestures drive. Mutated on the main thread; the draw reads it.
    var camera = OrbitCamera()

    static let colorFormat: MTLPixelFormat = .bgra8Unorm
    static let depthFormat: MTLPixelFormat = .depth32Float

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: viewerShaderSource, options: nil)
        } catch {
            return nil
        }
        guard let vfn = library.makeFunction(name: "viewer_vertex"),
              let ffn = library.makeFunction(name: "viewer_fragment") else { return nil }

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3          // position
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3          // normal
        vd.attributes[1].offset = MemoryLayout<Float>.stride * 3
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<Float>.stride * 6

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = Self.colorFormat
        pd.depthAttachmentPixelFormat = Self.depthFormat

        let dsd = MTLDepthStencilDescriptor()
        dsd.depthCompareFunction = .less
        dsd.isDepthWriteEnabled = true

        guard let pipe = try? device.makeRenderPipelineState(descriptor: pd),
              let depth = device.makeDepthStencilState(descriptor: dsd) else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipe
        self.depthState = depth
        super.init()
    }

    /// Upload a mesh's interleaved vertex/normal + index buffers and frame it.
    func setMesh(_ mesh: ViewerMesh) {
        guard !mesh.isEmpty else {
            vertexBuffer = nil
            indexBuffer = nil
            indexCount = 0
            return
        }
        let interleaved = mesh.interleaved()
        vertexBuffer = interleaved.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
        indexBuffer = mesh.indices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
        indexCount = mesh.indices.count
        camera.frame(mesh.bounds)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspect = size.height > 0 ? Float(size.width / size.height) : 1
    }

    func draw(in view: MTKView) {
        guard indexCount > 0,
              let vbuf = vertexBuffer, let ibuf = indexBuffer,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
            // Nothing to draw (empty stage): still present a cleared frame.
            if let drawable = view.currentDrawable, let cmd = queue.makeCommandBuffer() {
                cmd.present(drawable)
                cmd.commit()
            }
            return
        }

        let mvp = camera.projectionMatrix(aspect: aspect) * camera.viewMatrix()
        let n = camera.normalMatrix()
        let normal4 = simd_float4x4(columns: (
            SIMD4<Float>(n.columns.0, 0),
            SIMD4<Float>(n.columns.1, 0),
            SIMD4<Float>(n.columns.2, 0),
            SIMD4<Float>(0, 0, 0, 1)))
        var uniforms = ViewerUniforms(mvp: mvp, normalMatrix: normal4)

        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)  // v1: show both sides regardless of winding
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<ViewerUniforms>.stride, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                  indexType: .uint32, indexBuffer: ibuf,
                                  indexBufferOffset: 0)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

// ---------------------------------------------------------------------------
// SwiftUI wrapper around MTKView, cross-platform (UIKit on iOS, AppKit on macOS).
#if os(iOS)
public struct MetalMeshView: UIViewRepresentable {
    private let mesh: ViewerMesh?
    public init(mesh: ViewerMesh?) { self.mesh = mesh }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        configure(view, context: context)
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        return view
    }

    public func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.apply(mesh: mesh, to: view)
    }
}
#elseif os(macOS)
public struct MetalMeshView: NSViewRepresentable {
    private let mesh: ViewerMesh?
    public init(mesh: ViewerMesh?) { self.mesh = mesh }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        configure(view, context: context)
        let pan = NSPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        let magnify = NSMagnificationGestureRecognizer(target: context.coordinator,
                                                       action: #selector(Coordinator.handleMagnify(_:)))
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(magnify)
        return view
    }

    public func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.apply(mesh: mesh, to: view)
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

    public final class Coordinator: NSObject {
        var renderer: MeshRenderer?
        private var appliedSignature: [Float]?

        /// Upload a new mesh (and frame it) only when it actually changes.
        func apply(mesh: ViewerMesh?, to view: MTKView) {
            guard let renderer else { return }
            let sig = mesh.map(meshSignature)
            if sig == appliedSignature { return }
            appliedSignature = sig
            if let mesh { renderer.setMesh(mesh) }
            redraw(view)
        }

        private func redraw(_ view: MTKView) {
            #if os(iOS)
            view.setNeedsDisplay()
            #elseif os(macOS)
            view.needsDisplay = true
            #endif
        }

        #if os(iOS)
        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view as? MTKView else { return }
            let t = g.translation(in: view)
            renderer?.camera.orbit(dx: Float(t.x), dy: Float(t.y))
            g.setTranslation(.zero, in: view)
            redraw(view)
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let view = g.view as? MTKView, g.scale > 0 else { return }
            renderer?.camera.zoom(Float(1 / g.scale))  // spread (scale>1) → closer
            g.scale = 1
            redraw(view)
        }
        #elseif os(macOS)
        @objc func handlePan(_ g: NSPanGestureRecognizer) {
            guard let view = g.view as? MTKView else { return }
            let t = g.translation(in: view)
            renderer?.camera.orbit(dx: Float(t.x), dy: Float(-t.y))  // AppKit y is up
            g.setTranslation(.zero, in: view)
            redraw(view)
        }

        @objc func handleMagnify(_ g: NSMagnificationGestureRecognizer) {
            guard let view = g.view as? MTKView else { return }
            renderer?.camera.zoom(Float(1 / (1 + g.magnification)))
            g.magnification = 0
            redraw(view)
        }
        #endif
    }
}

#else  // !canImport(MetalKit) — keep the workspace compiling everywhere.
public struct MetalMeshView: View {
    private let mesh: ViewerMesh?
    public init(mesh: ViewerMesh?) { self.mesh = mesh }
    public var body: some View { DS.Color.background.color }
}
#endif
