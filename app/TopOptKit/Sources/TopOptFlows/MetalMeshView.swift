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

#if canImport(MetalKit)
import MetalKit
import simd

// ---------------------------------------------------------------------------
// GPU uniforms — must match the `Uniforms` layout in the shaders below.
private struct ViewerUniforms {
    var mvp: simd_float4x4
    var normalMatrix: simd_float4x4  // view rotation (upper-left 3×3), padded
}

// The neutral-clay shader (M7.4) + a selection tint (M7.5), compiled at runtime so
// the SwiftPM target needs no .metal resource bundling (identical on iOS/macOS).
private let viewerShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VIn  { float3 position [[attribute(0)]]; float3 normal [[attribute(1)]]; float4 tint [[attribute(2)]]; };
struct VOut { float4 position [[position]]; float3 vnormal; float4 tint; };
struct Uniforms { float4x4 mvp; float4x4 normalMatrix; };

vertex VOut viewer_vertex(VIn in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
    VOut o;
    o.position = u.mvp * float4(in.position, 1.0);
    o.vnormal  = (u.normalMatrix * float4(in.normal, 0.0)).xyz;
    o.tint = in.tint;
    return o;
}

fragment float4 viewer_fragment(VOut in [[stage_in]]) {
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
    return float4(clamp(color, 0.0, 1.0), 1.0);
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
    private var vertexDrawCount = 0
    /// Per-flat-vertex face ids (a triangle's id repeated 3×), for the tint buffer.
    private var flatFaceIDs: [UInt32] = []
    private var aspect: Float = 1

    /// The mesh currently uploaded (kept for the CPU-pick fallback).
    private(set) var mesh: ViewerMesh?

    /// The camera the gestures drive. Mutated on the main thread; the draw reads it.
    var camera = OrbitCamera()

    static let colorFormat: MTLPixelFormat = .bgra8Unorm
    static let depthFormat: MTLPixelFormat = .depth32Float
    static let idFormat: MTLPixelFormat = .r32Uint

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

        self.device = device
        self.queue = queue
        self.pipeline = pipe
        self.depthState = depth
        self.idPipeline = idPipe
        super.init()
    }

    /// Upload the mesh's flat-shaded (unshared-vertex) buffers — the interleaved
    /// position+normal buffer, the per-vertex face-id buffer (for the id pass) and a
    /// zeroed tint buffer — and frame it.
    func setMesh(_ mesh: ViewerMesh) {
        self.mesh = mesh
        guard !mesh.isEmpty else {
            vertexBuffer = nil; tintBuffer = nil; idVertexBuffer = nil
            vertexDrawCount = 0; flatFaceIDs = []
            return
        }
        let interleaved = mesh.flat.interleaved()
        vertexBuffer = interleaved.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
        vertexDrawCount = mesh.flat.vertexCount

        // Flat face ids: a triangle's id repeated for each of its three vertices.
        flatFaceIDs = mesh.faceIDs.flatMap { id -> [UInt32] in
            let u = UInt32(bitPattern: id)
            return [u, u, u]
        }
        buildIDBuffer()
        buildTintBuffer(faceTint: [:], activeFaces: [])
        camera.frame(mesh.bounds)
    }

    /// Rebuild the per-vertex tint buffer from the selection: each grouped face's
    /// vertices carry that group's colour; the active group is tinted more strongly.
    func setHighlights(faceTint: [FaceID: SIMD4<Float>], activeFaces: Set<FaceID>) {
        buildTintBuffer(faceTint: faceTint, activeFaces: activeFaces)
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
        guard let cmd = queue.makeCommandBuffer() else { return }
        if let rpd = view.currentRenderPassDescriptor {
            encode(into: rpd, aspect: aspect, into: cmd)
        }
        if let drawable = view.currentDrawable { cmd.present(drawable) }
        cmd.commit()
    }

    /// Encode the shaded mesh draw into an arbitrary render pass. Shared by the
    /// on-screen `draw(in:)` and the headless `renderOffscreen`.
    private func encode(into rpd: MTLRenderPassDescriptor, aspect: Float, into cmd: MTLCommandBuffer) {
        guard vertexDrawCount > 0, let vbuf = vertexBuffer, let tbuf = tintBuffer,
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var uniforms = makeUniforms(aspect: aspect)
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)  // show both sides regardless of winding
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBuffer(tbuf, offset: 0, index: 2)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<ViewerUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexDrawCount)
        enc.endEncoding()
    }

    private func makeUniforms(aspect: Float) -> ViewerUniforms {
        let mvp = camera.projectionMatrix(aspect: aspect) * camera.viewMatrix()
        let n = camera.normalMatrix()
        let normal4 = simd_float4x4(columns: (
            SIMD4<Float>(n.columns.0, 0),
            SIMD4<Float>(n.columns.1, 0),
            SIMD4<Float>(n.columns.2, 0),
            SIMD4<Float>(0, 0, 0, 1)))
        return ViewerUniforms(mvp: mvp, normalMatrix: normal4)
    }

    /// Render the current mesh + camera to an offscreen BGRA texture and return the
    /// raw pixel bytes (B,G,R,A per pixel). Used by headless tests to verify the
    /// pipeline rasterizes the mesh — no MTKView/display needed. Nil if nothing to draw.
    func renderOffscreen(size: Int, clear: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)) -> [UInt8]? {
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

        encode(into: rpd, aspect: 1, into: cmd)
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
#if os(iOS)
public struct MetalMeshView: UIViewRepresentable {
    private let mesh: ViewerMesh?
    private let selection: SelectionModel?
    private let faceToolActive: Bool
    private let onPickFace: ((FaceID) -> Void)?

    public init(mesh: ViewerMesh?, selection: SelectionModel? = nil,
                faceToolActive: Bool = false, onPickFace: ((FaceID) -> Void)? = nil) {
        self.mesh = mesh
        self.selection = selection
        self.faceToolActive = faceToolActive
        self.onPickFace = onPickFace
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
        context.coordinator.apply(mesh: mesh, selection: selection,
                                  faceToolActive: faceToolActive, onPickFace: onPickFace, to: view)
    }
}
#elseif os(macOS)
public struct MetalMeshView: NSViewRepresentable {
    private let mesh: ViewerMesh?
    private let selection: SelectionModel?
    private let faceToolActive: Bool
    private let onPickFace: ((FaceID) -> Void)?

    public init(mesh: ViewerMesh?, selection: SelectionModel? = nil,
                faceToolActive: Bool = false, onPickFace: ((FaceID) -> Void)? = nil) {
        self.mesh = mesh
        self.selection = selection
        self.faceToolActive = faceToolActive
        self.onPickFace = onPickFace
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
        context.coordinator.apply(mesh: mesh, selection: selection,
                                  faceToolActive: faceToolActive, onPickFace: onPickFace, to: view)
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
        private var appliedSelection: SelectionModel?
        private var faceToolActive = false
        private var onPickFace: ((FaceID) -> Void)?

        /// Upload a new mesh (and frame it) and/or refresh the selection highlight
        /// only when they actually change; keep the tap seam current.
        func apply(mesh: ViewerMesh?, selection: SelectionModel?,
                   faceToolActive: Bool, onPickFace: ((FaceID) -> Void)?, to view: MTKView) {
            guard let renderer else { return }
            self.faceToolActive = faceToolActive
            self.onPickFace = onPickFace

            let sig = mesh.map(meshSignature)
            var dirty = false
            if sig != appliedSignature {
                appliedSignature = sig
                if let mesh { renderer.setMesh(mesh) }
                appliedSelection = nil   // force a highlight rebuild for the new mesh
                dirty = true
            }
            if selection != appliedSelection {
                appliedSelection = selection
                applyHighlights(selection)
                dirty = true
            }
            if dirty { redraw(view) }
        }

        private func applyHighlights(_ selection: SelectionModel?) {
            guard let renderer else { return }
            guard let selection else {
                renderer.setHighlights(faceTint: [:], activeFaces: [])
                return
            }
            var tint: [FaceID: SIMD4<Float>] = [:]
            for g in selection.groups {
                let c = g.color
                let v = SIMD4<Float>(Float(c.r), Float(c.g), Float(c.b), 1)
                for f in g.faces { tint[f] = v }
            }
            let active = Set(selection.activeGroup?.faces ?? [])
            renderer.setHighlights(faceTint: tint, activeFaces: active)
        }

        private func redraw(_ view: MTKView) {
            #if os(iOS)
            view.setNeedsDisplay()
            #elseif os(macOS)
            view.needsDisplay = true
            #endif
        }

        /// Resolve a tap at `location` (view coordinates, origin top-left) to a face
        /// id — id pass first, CPU `FacePicker` as fallback — and report it.
        private func pick(at location: CGPoint, in view: MTKView) {
            guard faceToolActive, let renderer, let onPickFace else { return }
            let size = view.bounds.size
            guard size.width > 0, size.height > 0 else { return }
            let normalized = CGPoint(x: location.x / size.width, y: location.y / size.height)
            let w = Int(view.drawableSize.width), h = Int(view.drawableSize.height)
            let faceID = renderer.pickFaceID(atNormalizedPoint: normalized, width: w, height: h)
                ?? renderer.mesh.flatMap {
                    FacePicker.pick(mesh: $0, camera: renderer.camera,
                                    aspect: Float(size.width / size.height), point: normalized)
                }
            if let faceID { onPickFace(faceID) }
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

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view = g.view as? MTKView else { return }
            pick(at: g.location(in: view), in: view)
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
    private let mesh: ViewerMesh?
    private let selection: SelectionModel?
    private let faceToolActive: Bool
    private let onPickFace: ((FaceID) -> Void)?
    public init(mesh: ViewerMesh?, selection: SelectionModel? = nil,
                faceToolActive: Bool = false, onPickFace: ((FaceID) -> Void)? = nil) {
        self.mesh = mesh
        self.selection = selection
        self.faceToolActive = faceToolActive
        self.onPickFace = onPickFace
    }
    public var body: some View { DS.Color.background.color }
}
#endif
