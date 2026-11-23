// LatticeFileMeshPass — ★ his 11-22 ("Can you make the Mac send the lattice over to the iPad after it's done? ... I'd like a
// 'print accurate' version available"): the print file's own lattice, as the Mac made it, drawn in place of the Draft's vines.
//
// The file's weave shells (every triangle after the solid's, `LatticeFileMesh`) go into the same G-buffer the vines write,
// in the same colour, so the deferred light shades them exactly as it shades the Draft (his 11-19 rule: "The drawing follows
// the print file. Always."). The part itself is drawn as for the Draft: the app's own body, opened over the lattice.
import Foundation
import simd

/// The print file's lattice, ready to draw: 6 floats a vertex (position, normal), the shells' triangles.
public final class LatticeFileMesh: @unchecked Sendable, Equatable {
    public let token: Int
    public let vertices: [Float]
    public let indices: [UInt32]
    public var triangleCount: Int { indices.count / 3 }
    public static func == (a: LatticeFileMesh, b: LatticeFileMesh) -> Bool { a === b }

    init(token: Int, vertices: [Float], indices: [UInt32]) { self.token = token; self.vertices = vertices; self.indices = indices }

    public struct Unreadable: Error, CustomStringConvertible { public let description: String }

    /// The shells of core's 3MF: triangles from `baseTriangles` on (the solid's come first), their vertices packed apart with
    /// area-weighted normals (each shell is closed and shares its own vertices, so its tubes shade round). Blocking: call it
    /// off the main thread.
    public static func make(threeMF: Data, baseTriangles: Int, token: Int) throws -> LatticeFileMesh {
        let m = try CoreThreeMF.mesh(threeMF)
        return try make(vertices: m.vertices, indices: m.indices, baseTriangles: baseTriangles, token: token)
    }

    static func make(vertices v: [Float], indices t: [Int32], baseTriangles: Int, token: Int) throws -> LatticeFileMesh {
        let total = t.count / 3
        guard baseTriangles >= 0, baseTriangles < total else {
            throw Unreadable(description: "the file has \(total) triangles and \(baseTriangles) of them are the solid")
        }
        let nv = v.count / 3
        var remap = [Int32](repeating: -1, count: nv)
        var out = [Float]()
        var idx = [UInt32]()
        idx.reserveCapacity((total - baseTriangles) * 3)
        out.reserveCapacity((total - baseTriangles) * 3)   // about half a vertex a triangle on closed tubes, x6 floats
        var used = 0
        for k in (baseTriangles * 3)..<(total * 3) {
            let i = Int(t[k])
            guard i >= 0, i < nv else { throw Unreadable(description: "a triangle names vertex \(i) of \(nv)") }
            if remap[i] < 0 {
                remap[i] = Int32(used); used += 1
                out.append(v[3 * i]); out.append(v[3 * i + 1]); out.append(v[3 * i + 2])
                out.append(0); out.append(0); out.append(0)
            }
            idx.append(UInt32(remap[i]))
        }
        // area-weighted normals (the cross product's length is twice the area)
        out.withUnsafeMutableBufferPointer { o in
            var k = 0
            while k < idx.count {
                let a = Int(idx[k]) * 6, b = Int(idx[k + 1]) * 6, c = Int(idx[k + 2]) * 6
                let pa = SIMD3(o[a], o[a + 1], o[a + 2]), pb = SIMD3(o[b], o[b + 1], o[b + 2]), pc = SIMD3(o[c], o[c + 1], o[c + 2])
                let n = simd_cross(pb - pa, pc - pa)
                for j in [a, b, c] { o[j + 3] += n.x; o[j + 4] += n.y; o[j + 5] += n.z }
                k += 3
            }
            var j = 0
            while j < o.count {
                let n = SIMD3(o[j + 3], o[j + 4], o[j + 5])
                let l = simd_length(n)
                if l > 1e-20 { o[j + 3] = n.x / l; o[j + 4] = n.y / l; o[j + 5] = n.z / l }
                j += 6
            }
        }
        return LatticeFileMesh(token: token, vertices: out, indices: idx)
    }
}

#if canImport(MetalKit)
import MetalKit

let latticeFileMeshShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct FileFrame {
    float4x4 clipFromModel;
    float4x4 eyeFromModel;
    float4x4 eyeNormalBasis;
    float4   albedo;
};

struct FileVIn { packed_float3 p; packed_float3 n; };

struct FileVOut {
    float4 pos [[position]];
    float3 eyeP;
    float3 eyeN;
};

vertex FileVOut file_vertex(uint vid [[vertex_id]], const device FileVIn* v [[buffer(0)]], constant FileFrame& F [[buffer(1)]]) {
    FileVIn a = v[vid];
    FileVOut o;
    float4 p = float4(float3(a.p), 1.0);
    o.pos = F.clipFromModel * p;
    o.eyeP = (F.eyeFromModel * p).xyz;
    o.eyeN = (F.eyeNormalBasis * float4(float3(a.n), 0.0)).xyz;
    return o;
}

struct FileGBuf {
    float  eyeZ    [[color(0)]];
    float4 enormal [[color(1)]];
    float4 albedo  [[color(2)]];
};

fragment FileGBuf file_gbuffer(FileVOut in [[stage_in]], constant FileFrame& F [[buffer(1)]]) {
    // a cut face's sharp rim keeps its own face's normal: where the smooth one leans far from the face, the face's wins
    float3 face = normalize(cross(dfdx(in.eyeP), dfdy(in.eyeP)));
    float3 n = length(in.eyeN) > 1e-6 ? normalize(in.eyeN) : face;
    if (dot(n, face) < 0.0) { face = -face; }
    if (dot(n, face) < 0.5) { n = face; }
    if (n.z < 0.0) { n = -n; }
    FileGBuf o;
    o.eyeZ = -in.eyeP.z;
    o.enormal = float4(n, 0.0);
    o.albedo = float4(F.albedo.rgb, 1.0);
    return o;
}
"""

/// The print file's lattice in the G-buffer (one draw, indexed).
final class LatticeFileMeshPass {
    nonisolated(unsafe) static var lastInitError: String?
    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    private(set) var vertexBuffer: MTLBuffer?
    private(set) var indexBuffer: MTLBuffer?
    private(set) var indexCount = 0
    private(set) var token = -1
    var isDrawable: Bool { indexCount > 0 && vertexBuffer != nil && indexBuffer != nil }

    struct Frame { var clipFromModel: simd_float4x4; var eyeFromModel: simd_float4x4; var eyeNormalBasis: simd_float4x4
                   var albedo: SIMD4<Float> }

    init(device: MTLDevice) throws {
        self.device = device
        let lib = try device.makeLibrary(source: latticeFileMeshShaderSource, options: nil)
        guard let vf = lib.makeFunction(name: "file_vertex"), let ff = lib.makeFunction(name: "file_gbuffer") else {
            throw NSError(domain: "LatticeFileMeshPass", code: 1, userInfo: [NSLocalizedDescriptionKey: "file functions missing"])
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vf
        d.fragmentFunction = ff
        d.colorAttachments[0].pixelFormat = MeshRenderer.sceneDepthFormat
        d.colorAttachments[1].pixelFormat = MeshRenderer.gbufferNormalFormat
        d.colorAttachments[2].pixelFormat = MeshRenderer.gbufferAlbedoFormat
        d.depthAttachmentPixelFormat = MeshRenderer.depthFormat
        pipeline = try device.makeRenderPipelineState(descriptor: d)
    }

    func upload(_ m: LatticeFileMesh) {
        token = m.token
        guard !m.indices.isEmpty, !m.vertices.isEmpty else { vertexBuffer = nil; indexBuffer = nil; indexCount = 0; return }
        vertexBuffer = device.makeBuffer(bytes: m.vertices, length: MemoryLayout<Float>.stride * m.vertices.count,
                                         options: .storageModeShared)
        indexBuffer = device.makeBuffer(bytes: m.indices, length: MemoryLayout<UInt32>.stride * m.indices.count,
                                        options: .storageModeShared)
        indexCount = m.indices.count
    }

    func encode(_ enc: MTLRenderCommandEncoder, depthState: MTLDepthStencilState, clipFromModel: simd_float4x4,
                eyeFromModel: simd_float4x4, eyeNormalBasis: simd_float4x4, albedo: SIMD4<Float>) -> Bool {
        guard isDrawable, let vertexBuffer, let indexBuffer, enc.device === device else { return false }
        var f = Frame(clipFromModel: clipFromModel, eyeFromModel: eyeFromModel, eyeNormalBasis: eyeNormalBasis, albedo: albedo)
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&f, length: MemoryLayout<Frame>.stride, index: 1)
        enc.setFragmentBytes(&f, length: MemoryLayout<Frame>.stride, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: indexBuffer,
                                  indexBufferOffset: 0)
        return true
    }
}
#endif
