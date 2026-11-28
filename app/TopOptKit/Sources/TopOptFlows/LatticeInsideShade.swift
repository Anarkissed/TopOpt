// LatticeInsideShade — ★ his words 2026-11-23, after release 16 (b): "Make sure that looking INTO the part actually looks shaded
// and as if you're looking INTO A PART." In the solid view the part is opened by the engine's map (ShellClip mode 2) and what is
// inside — the vines, the growing vines, the cut walls, the part's own faces seen through the opening — was lit as if it stood in
// the open: as bright at the bottom of the opening as at its lip, no wall casting any shadow on it. One full-screen pass, right
// after the lattice's own shade, over every surface the G-buffer holds that lies INSIDE the part (a voxel off it toward the eye
// is still in the part: its outside faces and vines standing proud are not touched), multiplies it by how much light reaches
// it there, read from that very map (open lattice, inside the part):
//   * DEPTH: how far the point lies inside the part along the line he looks down (marched toward the eye while inside) —
//     darker the deeper he looks (half way to `deepFloor` at `depthMM`);
//   * SHADOW: how much solid part stands between the point and the key light (marched toward the light: the walls around
//     the opening shade the lattice under them) — `shadowFloor` behind a wall.
// The same for the landed lattice and the growth, as both live in the one G-buffer. Off: X-ray (no map), or no lattice drawn.
#if canImport(MetalKit)
import MetalKit
import simd

let latticeInsideShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct InsideFrame {
    float4x4 modelFromEye;   // eye space -> the part's own space (the map's)
    float4x4 eyeFromClip;    // the projection's inverse (with the picture's lift)
    float4   target;         // the colour target's width, height; the G-buffer's width, height
    float4   origin;         // the map's voxel (0,0,0) centre (model mm); w: its voxel (mm)
    float4   dims;           // its voxel counts; w: the far sentinel of the G-buffer's eye depth
    float4   light;          // xyz: toward the key light, in the part's space
    float4   shade;          // x: depth half way (mm); y: the deep floor; z: the shadow floor; w: the march's step (1; 2 turning)
};

struct InsideOut { float4 pos [[position]]; };

vertex InsideOut inside_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    InsideOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

static float2 inside_map(texture3d<float, access::sample> map, float3 p, constant InsideFrame& F) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_zero);
    float3 g = (p - F.origin.xyz) / F.origin.w;
    if (any(g < float3(-0.5)) || any(g > F.dims.xyz - float3(0.5))) { return float2(-1.0, -1.0); }   // outside the map: air
    return map.sample(s, (g + 0.5) / F.dims.xyz).rg;
}

fragment float4 inside_fragment(InsideOut in [[stage_in]], constant InsideFrame& F [[buffer(0)]],
                                texture2d<float, access::read> gDepth [[texture(1)]],
                                texture2d<float, access::read> gNormal [[texture(2)]],
                                texture2d<float, access::read> gAlbedo [[texture(3)]],
                                texture3d<float, access::sample> map [[texture(6)]]) {
    float2 scale = float2(F.target.z / max(F.target.x, 1.0), F.target.w / max(F.target.y, 1.0));
    uint2 g = uint2(clamp(in.pos.xy * scale, float2(0.0), float2(F.target.z - 1.0, F.target.w - 1.0)));
    // every surface the G-buffer holds: the lattice's, the cut walls, and the part's own faces seen through the opening (its
    // outside faces read no depth and no solid toward the light: untouched)
    float eyeZ = gDepth.read(g).x;
    if (eyeZ >= F.dims.w) { discard_fragment(); }   // the background
    float2 uv = (in.pos.xy + 0.5) / F.target.xy;
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    float4 rd = F.eyeFromClip * float4(ndc, 0.0, 1.0);
    float3 dir = rd.xyz / rd.w;
    float3 Pe = dir * (eyeZ / max(-dir.z, 1e-6));
    float3 P = (F.modelFromEye * float4(Pe, 1.0)).xyz;
    float3 eyeM = (F.modelFromEye * float4(0.0, 0.0, 0.0, 1.0)).xyz;
    float3 N = normalize((F.modelFromEye * float4(gNormal.read(g).xyz, 0.0)).xyz);   // toward the eye (the G-buffer's)
    float vox = F.origin.w;
    float stepK = max(F.shade.w, 1.0);   // 2 while he turns the view (half the samples)
    P += N * vox;   // a voxel off the surface: its own wall is not in the way
    // how deep inside the part, along the line he looks down
    // (where the march leaves the part is found between its last two samples, from the map's own values: no voxel bands)
    float3 toEye = normalize(eyeM - P);
    float deep = 0.0;
    float gPrev = inside_map(map, P, F).g;
    // only what lies inside the part (seen through its opening): its outside faces, and vines standing proud of it, stay as lit
    if (gPrev <= 0.1) { discard_fragment(); }
    {
        float st = vox * stepK;
        int n = int(48.0 / stepK);
        deep = float(n) * st;
        for (int i = 1; i <= n; ++i) {
            float s = float(i) * st;
            float g1 = inside_map(map, P + toEye * s, F).g;
            if (g1 <= 0.0) { deep = s - st + st * gPrev / max(gPrev - g1, 1e-4); break; }
            gPrev = g1;
        }
    }
    // how much solid part stands between it and the key light (the map's open value read as a soft share of solid)
    float solid = 0.0;
    float3 L = normalize(F.light.xyz);
    // (steps under a voxel, the map's open value read as a soft share of solid: no bands where a wall's edge crosses a step)
    float ls = 0.75 * vox * stepK;
    for (int i = 1; i <= int(56.0 / stepK); ++i) {
        float s = float(i) * ls;
        float2 v = inside_map(map, P + L * s, F);
        if (v.g <= -0.25) { break; }                                          // out of the part: the light is reached
        solid += ls * smoothstep(0.5, -0.5, v.r) * smoothstep(-0.5, 0.5, v.g);   // inside and not open
    }
    float d = mix(1.0, F.shade.y, 1.0 - exp2(-deep / max(F.shade.x, 1e-3)));
    float sh = mix(1.0, F.shade.z, 1.0 - exp(-solid / max(2.0 * vox, 1e-3)));
    float k = d * sh;
    return float4(k, k, k, 1.0);   // multiplied into the frame
}
"""

/// The pass: built once, drawn in the colour pass right after the lattice's shade.
final class LatticeInsideShade {
    nonisolated(unsafe) static var lastInitError: String?
    /// RED CONTROL (tests): off — the inside lit as if it stood in the open (as before 11-23).
    nonisolated(unsafe) static var controlOff = false
    /// Half way to the deep floor this far inside the part (mm); the deepest it gets; behind a wall.
    static let depthMM: Float = 9
    static let deepFloor: Float = 0.34
    static let shadowFloor: Float = 0.55
    /// The key light toward (world), as the shared material has it (UnifiedShading `to_material`).
    static let keyDir = simd_normalize(SIMD3<Float>(-0.38, 0.82, 0.42))

    let pipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState

    init(device: MTLDevice, sampleCount: Int) throws {
        let lib = try device.makeLibrary(source: latticeInsideShaderSource, options: nil)
        guard let vf = lib.makeFunction(name: "inside_vertex"), let ff = lib.makeFunction(name: "inside_fragment") else {
            throw NSError(domain: "LatticeInsideShade", code: 1, userInfo: [NSLocalizedDescriptionKey: "inside functions missing"])
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vf
        d.fragmentFunction = ff
        d.colorAttachments[0].pixelFormat = MeshRenderer.colorFormat
        d.colorAttachments[0].isBlendingEnabled = true   // the frame × the light that reaches inside
        d.colorAttachments[0].rgbBlendOperation = .add
        d.colorAttachments[0].alphaBlendOperation = .add
        d.colorAttachments[0].sourceRGBBlendFactor = .zero
        d.colorAttachments[0].destinationRGBBlendFactor = .sourceColor
        d.colorAttachments[0].sourceAlphaBlendFactor = .zero
        d.colorAttachments[0].destinationAlphaBlendFactor = .one
        d.depthAttachmentPixelFormat = MeshRenderer.depthFormat
        d.rasterSampleCount = sampleCount   // the 4× MSAA colour pass (MSAAPipelineSampleCountTests' rule)
        pipeline = try device.makeRenderPipelineState(descriptor: d)
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .always
        ds.isDepthWriteEnabled = false
        guard let st = device.makeDepthStencilState(descriptor: ds) else {
            throw NSError(domain: "LatticeInsideShade", code: 2, userInfo: [NSLocalizedDescriptionKey: "no depth state"])
        }
        depthState = st
    }

    struct Frame {
        var modelFromEye: simd_float4x4
        var eyeFromClip: simd_float4x4
        var target: SIMD4<Float>
        var origin: SIMD4<Float>
        var dims: SIMD4<Float>
        var light: SIMD4<Float>
        var shade: SIMD4<Float>
    }

    /// Multiplies the inside's light into the frame. `map`: the solid view's map the part is opened with.
    func encode(_ enc: MTLRenderCommandEncoder, gbuffer gb: (depth: MTLTexture, normal: MTLTexture, albedo: MTLTexture),
                map: (texture: MTLTexture, origin: SIMD3<Float>, voxel: Float, dims: SIMD3<Int32>), target: (w: Int, h: Int),
                modelView: simd_float4x4, projection: simd_float4x4, model: simd_float4x4, far: Float, coarse: Bool = false) {
        let rot = simd_float3x3(SIMD3(model.columns.0.x, model.columns.0.y, model.columns.0.z),
                                SIMD3(model.columns.1.x, model.columns.1.y, model.columns.1.z),
                                SIMD3(model.columns.2.x, model.columns.2.y, model.columns.2.z))
        let lightModel = simd_normalize(rot.transpose * Self.keyDir)   // the world's key light, in the part's space
        var f = Frame(modelFromEye: modelView.inverse, eyeFromClip: projection.inverse,
                      target: SIMD4(Float(target.w), Float(target.h), Float(gb.depth.width), Float(gb.depth.height)),
                      origin: SIMD4(map.origin, map.voxel),
                      dims: SIMD4(Float(map.dims.x), Float(map.dims.y), Float(map.dims.z), far),
                      light: SIMD4(lightModel, 0), shade: SIMD4(Self.depthMM, Self.deepFloor, Self.shadowFloor, coarse ? 2 : 1))
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setFragmentBytes(&f, length: MemoryLayout<Frame>.stride, index: 0)
        enc.setFragmentTexture(gb.depth, index: 1)
        enc.setFragmentTexture(gb.normal, index: 2)
        enc.setFragmentTexture(gb.albedo, index: 3)
        enc.setFragmentTexture(map.texture, index: 6)   // (4 is the body's clip, bound for the passes after)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

extension MeshRenderer {
    /// ★ notes24 (b): the map the part is opened with this frame (the growth's own while its walls open, else the landed
    /// lattice's), for the inside's light. nil: none (X-ray, or nothing opened).
    var insideMap: (texture: MTLTexture, origin: SIMD3<Float>, voxel: Float, dims: SIMD3<Int32>)? {
        guard bodyAlpha >= 0.999, !growthXraysBody else { return nil }
        if growthFrame.ownMap, let p = growthFrame.mapPass, let g = p.grid, let t = p.gridTexture {
            return (t, g.origin, g.voxel, g.dims)
        }
        guard layoutBarsInFrame, let b = drawnLayoutBars, b.shellClip != nil, let g = b.grid, let t = b.gridTexture else { return nil }   // ★ notes30: or the scaffold's rough cut-open
        return (t, g.origin, g.voxel, g.dims)
    }

    /// The inside's light into the colour pass, right after the lattice's shade. True when drawn.
    @discardableResult
    func encodeInsideShade(_ enc: MTLRenderCommandEncoder, gbuffer gb: (depth: MTLTexture, normal: MTLTexture, albedo: MTLTexture),
                           target: (w: Int, h: Int), modelView: simd_float4x4, projection: simd_float4x4,
                           model: simd_float4x4, far: Float) -> Bool {
        guard !LatticeInsideShade.controlOff, let map = insideMap else { return false }
        if insideShade == nil, LatticeInsideShade.lastInitError == nil {
            do { insideShade = try LatticeInsideShade(device: enc.device, sampleCount: sampleCount) } catch {
                LatticeInsideShade.lastInitError = "\(error)"   // the frame draws without it; a test reads this
                NSLog("DIAG inside shade: %@", "\(error)")
            }
        }
        guard let pass = insideShade else { return false }
        pass.encode(enc, gbuffer: gb, map: map, target: target, modelView: modelView, projection: projection, model: model,
                    far: far, coarse: turning)   // ★ his pick 11-16 (D): lighter while he turns it
        return true
    }
}
#endif
