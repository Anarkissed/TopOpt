// LatticeLayoutSheetPass — ★ SHEETS (gyroid, Schwarz-D) on the new lattice engine (notes28 sheets SPEC rev 3, section 5;
// builder C): the sheet a laid sheet region carries, drawn on the iPad as a G-BUFFER WRITER beside the bars
// (LatticeLayoutBarsPass owns it, as it owns Organic's vines and the print file's mesh), so #354's shade, AO and creases
// light it exactly as they light the struts.
//
// ★ WHAT IT DRAWS: core's own field (lattice_layout.hpp, SHEETS; LatticeSheetField is its Swift copy): per region its frame,
// anchor and cell (a small uniform array) and its TRUE wall at the cell centres (one small 3D texture per region, one texel per
// cell, linear filter, clamp to edge: core's trilinear blend, so the wall never steps), turned into the field parameter by the
// type's own law (core's table, `LatticeSheetLaw`, a buffer). It sphere-traces |f| / |∇f| − t / 2, CLIPPED to the lattice
// space by the engine's map (`LatticeLayoutSolidGrid`, fetched for a sheet in X-ray too): the sheet is drawn only where the map
// says open lattice, and where the part's surface cuts it open the wall ends flat there with the face's own normal (the bars'
// flat cap). Two or more regions: each voxel of the map names its region (`regionIndex`, from the laid cells), each region its
// own field. A Solid wall seam is the engine's own membrane: the map reads it solid, so it is not opened, and the cut walls
// pass (the bars pass's `encodeWalls`) draws it.
// ★ "THE DRAWING FOLLOWS THE PRINT FILE. ALWAYS." The print file is contoured from this very field (its mesh lies within
// 0.02 mm of it), so no Mac mesh is needed for Print-accurate preview: ON the map's stepped cut is kept, OFF it is smoothed
// (`LatticeLayoutPreview.cutSmoothWanted`, as for the struts).
// ★ REUSED FROM THE FLEXIBLE PASS (its march, its G-buffer write), COPIED INTO THIS SOURCE, never `flx_field` (a ladder of
// blended gyroids with the squish and Flexible's density grids): the step is factor × |F|, never past a cap in cells (the
// gyroid's 0.1: |f|/|∇f| over-reads between the sheets) nor a map voxel (a cut is never stepped over), the bisection, then one
// false-position step; the same three attachments under the same 1152 px cap.
// ★ P7: everything that grows with the part is a texture or a buffer; the per-frame uniform is a fixed-size struct.

#if canImport(MetalKit)
import MetalKit
import simd
import TopOptKit

/// What the page hands the bars pass for a sheet layout (LatticeLayoutBarsInputs.sheets).
public struct LatticeSheetDrawing: Equatable, @unchecked Sendable {
    public var token: Int
    public var fields: [LatticeSheetField]
    public var seams: [LatticeSheetSeam]
    /// The engine's map — fetched for a sheet in X-ray too; nil until it lands (nothing is drawn without it: the sheet is
    /// clipped to the lattice space by it).
    public var map: LatticeLayoutSolidGrid?
    /// Per voxel of `map`, the index of the field whose region holds it (255: none) — two or more fields only (`regionIndex`).
    public var regions: [UInt8]?
    /// Per field, one colour per wall texel (the field's cells, x fastest): the wall-thickness key, or the stress. Empty: one
    /// colour.
    public var colours: [[SIMD4<Float>]] = []
    public var colourKey = 0
    /// The march's box (model mm): the laid sheet cells' cubes; nil = the map's box.
    public var boxLo: SIMD3<Float>?
    public var boxHi: SIMD3<Float>?
    public init(token: Int, fields: [LatticeSheetField], seams: [LatticeSheetSeam] = [], map: LatticeLayoutSolidGrid? = nil) {
        self.token = token; self.fields = fields; self.seams = seams; self.map = map
    }
    public static func == (a: Self, b: Self) -> Bool {
        a.token == b.token && a.map?.token == b.map?.token && a.map?.smooth == b.map?.smooth && a.colourKey == b.colourKey
            && (a.regions == nil) == (b.regions == nil)
    }
    /// What the pass uploads the map for (a new map, or the same lay's map drawn the other way).
    var mapKey: [Int] { [token, map?.token ?? -1, map?.smooth == true ? 1 : 0, regions == nil ? 0 : 1] }

    /// The most fields the pass draws (the uniform's array; a part with more sheet regions draws the first eight).
    public static let maxFields = 8

    /// ★ Two or more sheet regions: which field holds each voxel of `map` — from the laid cells (each cell's cube, in its frame:
    /// a voxel whose centre is inside it is its region's), then one voxel grown into the open voxels no cube holds (the map
    /// marks the air beside an opening open too). 255: none. `frames`: 12 per frame; per cell its region, frame, low corner
    /// (3) and size.
    public static func regionIndex(fields: [LatticeSheetField], map g: LatticeLayoutSolidGrid, frames: [Float],
                                   cellRegion: [Int32], cellFrame: [Int32], cellLo: [Float], cellSize: [Float]) -> [UInt8] {
        let nx = Int(g.dims.x), ny = Int(g.dims.y), nz = Int(g.dims.z), n = nx * ny * nz
        guard n > 0 else { return [] }
        var out = [UInt8](repeating: 255, count: n)
        var fieldOf: [Int32: UInt8] = [:]
        for (i, f) in fields.prefix(maxFields).enumerated() where fieldOf[f.region] == nil { fieldOf[f.region] = UInt8(i) }
        let cells = Swift.min(cellRegion.count, cellFrame.count, cellSize.count, cellLo.count / 3)
        for c in 0..<cells {
            guard let idx = fieldOf[cellRegion[c]] else { continue }
            let k = 12 * Int(cellFrame[c])
            guard k >= 0, k + 11 < frames.count else { continue }
            let o = SIMD3(frames[k], frames[k + 1], frames[k + 2])
            let a0 = SIMD3(frames[k + 3], frames[k + 4], frames[k + 5]), a1 = SIMD3(frames[k + 6], frames[k + 7], frames[k + 8])
            let a2 = SIMD3(frames[k + 9], frames[k + 10], frames[k + 11])
            let lo = SIMD3(cellLo[3 * c], cellLo[3 * c + 1], cellLo[3 * c + 2]), s = cellSize[c]
            var bl = SIMD3<Float>(repeating: .greatestFiniteMagnitude), bh = -bl
            for corner in 0..<8 {
                let q = lo + SIMD3(corner & 1 != 0 ? s : 0, corner & 2 != 0 ? s : 0, corner & 4 != 0 ? s : 0)
                let p = o + q.x * a0 + q.y * a1 + q.z * a2
                bl = simd_min(bl, p); bh = simd_max(bh, p)
            }
            let i0 = simd_max(SIMD3<Int32>(((bl - g.origin) / g.voxel).rounded(.down)), .zero)
            let i1 = simd_min(SIMD3<Int32>(((bh - g.origin) / g.voxel).rounded(.up)), g.dims &- 1)
            if i0.x > i1.x || i0.y > i1.y || i0.z > i1.z { continue }
            for kz in i0.z...i1.z { for jy in i0.y...i1.y { for ix in i0.x...i1.x {
                let p = g.origin + SIMD3(Float(ix), Float(jy), Float(kz)) * g.voxel
                let d = p - o
                let q = SIMD3(simd_dot(d, a0), simd_dot(d, a1), simd_dot(d, a2)) - lo
                guard q.x >= 0, q.y >= 0, q.z >= 0, q.x < s, q.y < s, q.z < s else { continue }
                out[(Int(kz) * ny + Int(jy)) * nx + Int(ix)] = idx
            } } }
        }
        // one voxel grown into the open voxels no cube holds (the six neighbours, the first named)
        guard g.rg.count == 2 * n else { return out }
        let before = out
        for v in 0..<n where before[v] == 255 && g.rg[2 * v] > 0 {
            let x = v % nx, y = (v / nx) % ny, z = v / (nx * ny)
            for (dx, dy, dz) in [(-1, 0, 0), (1, 0, 0), (0, -1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1)] {
                let a = x + dx, b = y + dy, c = z + dz
                guard a >= 0, b >= 0, c >= 0, a < nx, b < ny, c < nz else { continue }
                let w = (c * ny + b) * nx + a
                if before[w] != 255 { out[v] = before[w]; break }
            }
        }
        return out
    }

    /// The march's box from the laid sheet cells (their cubes, model mm), one map voxel over. nil when there are none.
    public static func box(frames: [Float], cellFrame: [Int32], cellLo: [Float], cellSize: [Float], pad: Float)
        -> (lo: SIMD3<Float>, hi: SIMD3<Float>)? {
        var bl = SIMD3<Float>(repeating: .greatestFiniteMagnitude), bh = -bl
        let cells = Swift.min(cellFrame.count, cellSize.count, cellLo.count / 3)
        var any = false
        for c in 0..<cells {
            let k = 12 * Int(cellFrame[c])
            guard k >= 0, k + 11 < frames.count else { continue }
            let o = SIMD3(frames[k], frames[k + 1], frames[k + 2])
            let a0 = SIMD3(frames[k + 3], frames[k + 4], frames[k + 5]), a1 = SIMD3(frames[k + 6], frames[k + 7], frames[k + 8])
            let a2 = SIMD3(frames[k + 9], frames[k + 10], frames[k + 11])
            let lo = SIMD3(cellLo[3 * c], cellLo[3 * c + 1], cellLo[3 * c + 2]), s = cellSize[c]
            for corner in 0..<8 {
                let q = lo + SIMD3(corner & 1 != 0 ? s : 0, corner & 2 != 0 ? s : 0, corner & 4 != 0 ? s : 0)
                let p = o + q.x * a0 + q.y * a1 + q.z * a2
                bl = simd_min(bl, p); bh = simd_max(bh, p)
                any = true
            }
        }
        return any ? (bl - pad, bh + pad) : nil
    }
}

let latticeLayoutSheetShaderSource = """
#include <metal_stdlib>
using namespace metal;

// One laid sheet field (LatticeLayoutSheetPass.FieldU, byte for byte).
struct SheetFieldU {
    float4 origin;   // the frame's origin; w = kind (0 gyroid, 1 schwarz_d)
    float4 ax0;      // the frame's three unit axes
    float4 ax1;
    float4 ax2;
    float4 anchor;   // a cell corner (frame mm): phase 0 there; w = the cell (the period), mm
    float4 lo;       // the wall grid's first centre (frame mm); w = 1: graded (read the wall texture), 0: one wall
    float4 n;        // the wall grid's counts; w = the one wall (mm) when not graded
    float4 colour;   // rgb: the one colour; w = 1: one colour per cell (the colour texture)
};

struct SheetFrame {
    float4x4 clipFromModel;
    float4x4 modelFromClip;
    float4x4 eyeFromModel;
    float4x4 eyeNormalBasis;
    float4   mapOrigin;    // the engine's map: voxel (0,0,0)'s centre
    float4   mapSpacing;   // its voxel
    float4   mapDims;      // its counts; w = 1: the region texture names each voxel's field
    float4   boxLo;        // the march's box (model mm)
    float4   boxHi;
    float4   march;        // x = step factor, y = step cap in cells, z = min step (mm), w = max steps
    float4   counts;       // x = fields, y = the law's steps, z = the law's max share (wall / cell), w = 1: dimmed
    SheetFieldU fields[8];
};

// ── the field (core's sheets.cpp; LatticeSheetField is the Swift copy this is held to) ──

// The parameter (mm) for a TRUE wall in a cell: core's lattice_sheet_wall_param_mm, read from its table (LatticeSheetLaw).
static float sheet_param(float wall, float cell, int kind, const device float* law, constant SheetFrame& F) {
    if (!(wall > 0.0f) || !(cell > 0.0f)) { return 0.0f; }
    int steps = int(F.counts.y);
    float share = F.counts.z;
    const device float* t = law + kind * (steps + 1);
    float u = wall / cell;
    float x = u / share * float(steps);
    if (x >= float(steps)) { return t[steps] / share * u * cell; }
    int i = int(floor(x));
    float f = x - float(i);
    return (t[i] + f * (t[i + 1] - t[i])) * cell;
}

// The TRUE wall at frame point q: trilinear between the cell centres, clamped (core's sheet_wall_at_local) — the texture's
// linear filter, clamp to edge.
static float sheet_wall(constant SheetFieldU& S, float3 q, texture3d<float> W) {
    if (S.lo.w < 0.5f) { return S.n.w; }
    constexpr sampler sl(coord::normalized, filter::linear, address::clamp_to_edge);
    float3 uvw = ((q - S.lo.xyz) / S.anchor.w + 0.5f) / S.n.xyz;
    return W.sample(sl, uvw).r;
}

// f and its gradient (per mm) at x mm from the anchor, period L (core's tpms_eval), the phase taken modulo one period first.
static float sheet_eval(int kind, float3 x, float L, thread float3& g) {
    const float TAU = 6.28318530717958647692f;
    float a = TAU / L;
    float3 u = x / L;
    float3 ph = TAU * (u - floor(u));
    float3 s = sin(ph), c = cos(ph);
    if (kind == 0) {
        g = a * float3(c.x * c.y - s.z * s.x, -s.x * s.y + c.y * c.z, -s.y * s.z + c.z * c.x);
        return s.x * c.y + s.y * c.z + s.z * c.x;
    }
    g = a * float3(c.x * s.y * s.z + c.x * c.y * c.z - s.x * s.y * c.z - s.x * c.y * s.z,
                   s.x * c.y * s.z - s.x * s.y * c.z + c.x * c.y * c.z - c.x * s.y * s.z,
                   s.x * s.y * c.z - s.x * c.y * s.z - c.x * s.y * s.z + c.x * c.y * c.z);
    return s.x * s.y * s.z + s.x * c.y * c.z + c.x * s.y * c.z + c.x * c.y * s.z;
}

static float3 sheet_local(constant SheetFieldU& S, float3 p) {
    float3 r = p - S.origin.xyz;
    return float3(dot(r, S.ax0.xyz), dot(r, S.ax1.xyz), dot(r, S.ax2.xyz));
}

// THE FIELD (mm, negative inside the wall): core's sheet_distance_at.
static float sheet_distance(constant SheetFieldU& S, float3 p, texture3d<float> W, const device float* law,
                            constant SheetFrame& F) {
    float L = S.anchor.w;
    float3 q = sheet_local(S, p);
    float t = sheet_param(sheet_wall(S, q, W), L, int(S.origin.w + 0.5f), law, F);
    float3 g;
    float f = sheet_eval(int(S.origin.w + 0.5f), q - S.anchor.xyz, L, g);
    float gl = length(g);
    if (!(gl > 1e-6f)) { return L; }
    return abs(f) / gl - 0.5f * t;
}

// The signed distance to the mid-surface (f / |∇f|): the blend's F_i (core's sheet_mid_distance_at).
static float sheet_mid(constant SheetFieldU& S, float3 p) {
    float L = S.anchor.w;
    float3 g;
    float f = sheet_eval(int(S.origin.w + 0.5f), sheet_local(S, p) - S.anchor.xyz, L, g);
    float gl = length(g);
    if (!(gl > 1e-6f)) { return L; }
    return f / gl;
}

// THE BLENDED FIELD across a seam (core's sheet_blend_distance_at; the contract's form, E refines core's): smoothstep across
// the band, the two mid-surface distances mixed, the wall half the mixed parameter (+ the band's raise).
static float sheet_blend(constant SheetFieldU& A, constant SheetFieldU& B, texture3d<float> WA, texture3d<float> WB,
                         const device float* law, constant SheetFrame& F, float seamMM, float bandMM, float raiseMM,
                         float3 p) {
    float s;
    if (!(bandMM > 0.0f)) { s = seamMM >= 0.0f ? 1.0f : 0.0f; }
    else { float x = clamp((seamMM + 0.5f * bandMM) / bandMM, 0.0f, 1.0f); s = x * x * (3.0f - 2.0f * x); }
    float fa = s < 1.0f ? sheet_mid(A, p) : 0.0f;
    float fb = s > 0.0f ? sheet_mid(B, p) : 0.0f;
    float ta = s < 1.0f ? sheet_param(sheet_wall(A, sheet_local(A, p), WA), A.anchor.w, int(A.origin.w + 0.5f), law, F) : 0.0f;
    float tb = s > 0.0f ? sheet_param(sheet_wall(B, sheet_local(B, p), WB), B.anchor.w, int(B.origin.w + 0.5f), law, F) : 0.0f;
    float Fm = (1.0f - s) * fa + s * fb;
    return abs(Fm) - 0.5f * ((1.0f - s) * ta + s * tb + raiseMM);
}

// ── the map: the lattice space, and which field holds each voxel ──
static float3 sheet_map_uvw(float3 p, constant SheetFrame& F) {
    return ((p - F.mapOrigin.xyz) / F.mapSpacing.xyz + 0.5f) / F.mapDims.xyz;
}
static float sheet_open(float3 p, constant SheetFrame& F, texture3d<float> map) {
    constexpr sampler sl(coord::normalized, filter::linear, address::clamp_to_edge);
    float3 uvw = sheet_map_uvw(p, F);
    if (any(uvw < 0.0f) || any(uvw > 1.0f)) { return -1.0f; }
    return map.sample(sl, uvw).r;
}
static int sheet_field_at(float3 p, constant SheetFrame& F, texture3d<uint, access::read> region) {
    if (F.mapDims.w < 0.5f) { return 0; }
    int3 i = int3(floor((p - F.mapOrigin.xyz) / F.mapSpacing.xyz + 0.5f));
    int3 d = int3(F.mapDims.xyz);
    if (any(i < 0) || any(i >= d)) { return -1; }
    uint v = region.read(uint3(i)).r;
    return v >= uint(F.counts.x) ? -1 : int(v);
}

// The field at p where p is open lattice of a field (`fi` its index), else +big (nothing of a sheet here).
static float sheet_here(float3 p, int fi, constant SheetFrame& F, array<texture3d<float>, 8> walls, const device float* law) {
    if (fi < 0) { return 1e9f; }
    return sheet_distance(F.fields[fi], p, walls[fi], law, F);
}

struct SheetVOut {
    float4 pos [[position]];
    float2 ndc;
};

// one full-screen triangle at NDC z = 0 (the Flexible pass's `flx_vertex`): one fragment per pixel, its own ray
vertex SheetVOut sheet_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    SheetVOut o;
    o.pos = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    o.ndc = p * 2.0f - 1.0f;
    return o;
}

struct SheetGBuf {
    float  eyeZ    [[color(0)]];
    float4 enormal [[color(1)]];
    float4 albedo  [[color(2)]];
    float  depth   [[depth(any)]];
};

fragment SheetGBuf sheet_gbuffer(SheetVOut in [[stage_in]],
                                 constant SheetFrame& F [[buffer(1)]],
                                 const device float* law [[buffer(2)]],
                                 texture3d<float, access::sample> map [[texture(0)]],
                                 texture3d<uint, access::read> region [[texture(1)]],
                                 array<texture3d<float>, 8> walls [[texture(2)]],
                                 array<texture3d<float>, 8> cols [[texture(10)]]) {
    // this fragment's ray, from the inverse clip matrix (Orthographic and Perspective alike, the bars' way)
    float4 n0 = F.modelFromClip * float4(in.ndc, 0.0f, 1.0f);
    float4 n1 = F.modelFromClip * float4(in.ndc, 1.0f, 1.0f);
    float3 ro = n0.xyz / n0.w;
    float3 rd = normalize(n1.xyz / n1.w - ro);
    float3 safe = select(rd, copysign(float3(1e-7f), rd), abs(rd) < 1e-7f);
    float3 ta = (F.boxLo.xyz - ro) / safe, tb = (F.boxHi.xyz - ro) / safe;
    float t0 = max(max(max(min(ta.x, tb.x), min(ta.y, tb.y)), min(ta.z, tb.z)), 0.0f);
    float t1 = min(min(max(ta.x, tb.x), max(ta.y, tb.y)), max(ta.z, tb.z));
    if (!(t0 < t1)) { discard_fragment(); }
    float vox = min(F.mapSpacing.x, min(F.mapSpacing.y, F.mapSpacing.z));
    float mapStep = 0.5f * vox;
    int maxSteps = int(F.march.w);
    // ── the march: past air and solid at half a voxel (the map alone); in open lattice by the field (the Flexible pass's
    //    step: factor × |F| within [min step, cap × cell], never more than a voxel so no cut is stepped over) ──
    float t = t0, tPrev = t0;
    bool hit = false;
    for (int i = 0; i < maxSteps; ++i) {
        float3 p = ro + rd * t;
        float step = mapStep;
        if (sheet_open(p, F, map) > 0.0f) {
            int fi = sheet_field_at(p, F, region);
            float d = sheet_here(p, fi, F, walls, law);
            if (d < 0.0f) { hit = true; break; }
            if (fi >= 0) {
                step = clamp(F.march.x * d, F.march.z, min(F.march.y * F.fields[fi].anchor.w, vox));
            }
        }
        tPrev = t;
        t += step;
        if (t > t1) { break; }
    }
    if (!hit) { discard_fragment(); }
    // the bisection on "open lattice and inside the wall", then one false-position step on the field
    float a = tPrev, b = t;
    if (b > a) {
        for (int k = 0; k < 7; ++k) {
            float m = 0.5f * (a + b);
            float3 pm = ro + rd * m;
            bool inside = sheet_open(pm, F, map) > 0.0f && sheet_here(pm, sheet_field_at(pm, F, region), F, walls, law) < 0.0f;
            if (inside) { b = m; } else { a = m; }
        }
    }
    float3 p = ro + rd * b;
    int fi = max(sheet_field_at(p, F, region), 0);
    constant SheetFieldU& S = F.fields[fi];
    float d = sheet_here(p, fi, F, walls, law);
    float3 n;
    if (d < -0.01f) {
        // entered through the part's surface while inside the wall: the cut face, flush, the face's own normal (the bars' cap)
        float e = 0.5f * vox;
        float3 g = float3(sheet_open(p + float3(e, 0, 0), F, map) - sheet_open(p - float3(e, 0, 0), F, map),
                          sheet_open(p + float3(0, e, 0), F, map) - sheet_open(p - float3(0, e, 0), F, map),
                          sheet_open(p + float3(0, 0, e), F, map) - sheet_open(p - float3(0, 0, e), F, map));
        n = length(g) > 1e-5f ? -normalize(g) : -rd;
    } else {
        const float e = 0.05f;
        float3 g = float3(sheet_here(p + float3(e, 0, 0), fi, F, walls, law) - sheet_here(p - float3(e, 0, 0), fi, F, walls, law),
                          sheet_here(p + float3(0, e, 0), fi, F, walls, law) - sheet_here(p - float3(0, e, 0), fi, F, walls, law),
                          sheet_here(p + float3(0, 0, e), fi, F, walls, law) - sheet_here(p - float3(0, 0, e), fi, F, walls, law));
        n = length_squared(g) > 1e-20f ? normalize(g) : -rd;
    }
    float3 eyeN = normalize((F.eyeNormalBasis * float4(n, 0.0f)).xyz);
    if (eyeN.z < 0.0f) { eyeN = -eyeN; }
    float3 albedo = S.colour.rgb;
    if (S.colour.w > 0.5f) {
        constexpr sampler sl(coord::normalized, filter::linear, address::clamp_to_edge);
        float3 uvw = ((sheet_local(S, p) - S.lo.xyz) / S.anchor.w + 0.5f) / S.n.xyz;
        albedo = cols[fi].sample(sl, uvw).rgb;
        if (F.counts.w > 0.5f) {   // dimmed: drained toward grey and darkened (LatticeLayoutBarsPass.dimmedRGB)
            float grey = dot(albedo, float3(0.299f, 0.587f, 0.114f));
            albedo = mix(albedo, float3(grey), 0.7f) * 0.6f + 0.12f;
        }
    }
    float4 clip = F.clipFromModel * float4(p, 1.0f);
    SheetGBuf o;
    o.eyeZ = -(F.eyeFromModel * float4(p, 1.0f)).z;
    o.enormal = float4(eyeN, 0.0f);
    o.albedo = float4(albedo, 1.0f);
    o.depth = clamp(clip.z / max(clip.w, 1e-6f), 0.0f, 1.0f);
    return o;
}

// ── test kernels: the field (pts.w = the field's index) and the blend of fields 0 and 1 (pts.w = the seam distance) ──
kernel void sheet_field_probe(const device float4* pts [[buffer(0)]], device float* out [[buffer(1)]],
                              constant SheetFrame& F [[buffer(2)]], const device float* law [[buffer(3)]],
                              constant uint& count [[buffer(4)]],
                              array<texture3d<float>, 8> walls [[texture(2)]], uint id [[thread_position_in_grid]]) {
    if (id >= count) { return; }
    int fi = int(pts[id].w + 0.5f);
    out[id] = sheet_distance(F.fields[fi], pts[id].xyz, walls[fi], law, F);
}
kernel void sheet_blend_probe(const device float4* pts [[buffer(0)]], device float* out [[buffer(1)]],
                              constant SheetFrame& F [[buffer(2)]], const device float* law [[buffer(3)]],
                              constant uint& count [[buffer(4)]], constant float4& seam [[buffer(5)]],
                              array<texture3d<float>, 8> walls [[texture(2)]], uint id [[thread_position_in_grid]]) {
    if (id >= count) { return; }
    out[id] = sheet_blend(F.fields[0], F.fields[1], walls[0], walls[1], law, F, pts[id].w, seam.x, seam.y, pts[id].xyz);
}
"""

/// The sheet fields, uploaded once per token, drawn into the G-buffer (LatticeLayoutBarsPass draws it in place of bars).
final class LatticeLayoutSheetPass {
    static var lastInitError: String?
    /// The march (the Flexible pass's numbers): step = factor × |F|, at least `minStepMM`, at most `stepCapCells` of the cell
    /// (the gyroid's |f|/|∇f| over-reads between the sheets: Flexible's measured 0.1) and at most a map voxel.
    static var stepFactor: Float = 0.6
    static var stepCapCells: Float = 0.1
    static var minStepMM: Float = 0.02
    static var maxSteps: Float = 1500
    /// The law's table, as read by the shader (LatticeSheetLaw): steps and the widest wall over the cell.
    static let lawSteps = LatticeSheetLaw.steps
    static let lawMaxShare = LatticeSheetLaw.maxShare

    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    private let library: MTLLibrary
    private var computeCache: [String: MTLComputePipelineState] = [:]
    private lazy var queue: MTLCommandQueue? = device.makeCommandQueue()

    private(set) var token = -1
    private(set) var mapKey: [Int] = []
    private(set) var colourKey = -1
    private(set) var drawing: LatticeSheetDrawing?
    private var mapTexture: MTLTexture?
    private var regionTexture: MTLTexture?
    private var wallTextures: [MTLTexture] = []
    private var colourTextures: [MTLTexture?] = []
    private var lawBuffer: MTLBuffer?
    private var map: (origin: SIMD3<Float>, voxel: Float, dims: SIMD3<Int32>)?
    private var box: (lo: SIMD3<Float>, hi: SIMD3<Float>)?
    var isDrawable: Bool { mapTexture != nil && !wallTextures.isEmpty && lawBuffer != nil && map != nil }

    init(device: MTLDevice) throws {
        self.device = device
        library = try device.makeLibrary(source: latticeLayoutSheetShaderSource, options: nil)
        guard let vf = library.makeFunction(name: "sheet_vertex"), let ff = library.makeFunction(name: "sheet_gbuffer") else {
            throw NSError(domain: "LatticeLayoutSheetPass", code: 1, userInfo: [NSLocalizedDescriptionKey: "sheet functions missing"])
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

    // MARK: upload (once per token; the map and the colours on their own keys)

    func upload(_ s: LatticeSheetDrawing) {
        drawing = s
        if token != s.token {
            token = s.token
            uploadFields(s)
        }
        if mapKey != s.mapKey { uploadMap(s) }
        if colourKey != s.colourKey || colourTextures.count != wallTextures.count { uploadColours(s) }
    }

    private func uploadFields(_ s: LatticeSheetDrawing) {
        wallTextures = s.fields.prefix(LatticeSheetDrawing.maxFields).compactMap { f in
            let n = f.graded ? f.n : SIMD3<Int32>(1, 1, 1)
            let values = f.graded ? f.wallMM : [f.wallMM.first ?? 0]
            return Self.texture3D(device, .r16Float, dims: n, bytes: values.map { FlexibleLatticePass.halfBits($0) })
        }
        if lawBuffer == nil {
            let table = (LatticeSheetLaw.table(.gyroid) + LatticeSheetLaw.table(.schwarzD)).map(Float.init)
            lawBuffer = table.count == 2 * (Self.lawSteps + 1)
                ? device.makeBuffer(bytes: table, length: 4 * table.count, options: .storageModeShared) : nil
        }
        colourTextures = []
    }

    private func uploadMap(_ s: LatticeSheetDrawing) {
        mapKey = s.mapKey
        guard let g = s.map, g.isWhole else { mapTexture = nil; map = nil; regionTexture = nil; return }
        mapTexture = Self.texture3D(device, .rg8Snorm, dims: g.dims, bytes: g.rg)
        map = (g.origin, g.voxel, g.dims)
        let n = Int(g.dims.x) * Int(g.dims.y) * Int(g.dims.z)
        if let r = s.regions, r.count == n, s.fields.count > 1 {
            regionTexture = Self.texture3D(device, .r8Uint, dims: g.dims, bytes: r)
        } else {
            regionTexture = nil
        }
        let lo = g.origin - 0.5 * g.voxel, hi = lo + SIMD3<Float>(g.dims) * g.voxel
        if let bl = s.boxLo, let bh = s.boxHi { box = (simd_max(bl, lo), simd_min(bh, hi)) } else { box = (lo, hi) }
    }

    private func uploadColours(_ s: LatticeSheetDrawing) {
        colourKey = s.colourKey
        colourTextures = s.fields.prefix(LatticeSheetDrawing.maxFields).enumerated().map { i, f in
            guard i < s.colours.count else { return nil }
            let n = f.graded ? f.n : SIMD3<Int32>(1, 1, 1)
            let c = s.colours[i]
            guard c.count == Int(n.x) * Int(n.y) * Int(n.z) else { return nil }
            let rgba: [UInt8] = c.flatMap { v in
                [v.x, v.y, v.z, 1].map { UInt8(Swift.max(0, Swift.min(255, ($0 * 255).rounded()))) }
            }
            return Self.texture3D(device, .rgba8Unorm, dims: n, bytes: rgba)
        }
    }

    static func texture3D<T>(_ device: MTLDevice, _ format: MTLPixelFormat, dims: SIMD3<Int32>, bytes: [T]) -> MTLTexture? {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = format
        d.width = Int(dims.x); d.height = Int(dims.y); d.depth = Int(dims.z)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        let per = MemoryLayout<T>.stride * (bytes.count / Swift.max(1, d.width * d.height * d.depth))
        guard per > 0, bytes.count == d.width * d.height * d.depth * (per / MemoryLayout<T>.stride),
              let t = device.makeTexture(descriptor: d) else { return nil }
        bytes.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake3D(0, 0, 0, d.width, d.height, d.depth), mipmapLevel: 0, slice: 0,
                      withBytes: raw.baseAddress!, bytesPerRow: per * d.width, bytesPerImage: per * d.width * d.height)
        }
        return t
    }

    // MARK: the uniform (SheetFrame, byte for byte)

    struct FieldU {
        var origin = SIMD4<Float>(0, 0, 0, 0)
        var ax0 = SIMD4<Float>(1, 0, 0, 0)
        var ax1 = SIMD4<Float>(0, 1, 0, 0)
        var ax2 = SIMD4<Float>(0, 0, 1, 0)
        var anchor = SIMD4<Float>(0, 0, 0, 1)
        var lo = SIMD4<Float>(0, 0, 0, 0)
        var n = SIMD4<Float>(1, 1, 1, 0)
        var colour = SIMD4<Float>(1, 1, 1, 0)
    }
    struct Frame {
        var clipFromModel = matrix_identity_float4x4
        var modelFromClip = matrix_identity_float4x4
        var eyeFromModel = matrix_identity_float4x4
        var eyeNormalBasis = matrix_identity_float4x4
        var mapOrigin = SIMD4<Float>(0, 0, 0, 0)
        var mapSpacing = SIMD4<Float>(1, 1, 1, 0)
        var mapDims = SIMD4<Float>(1, 1, 1, 0)
        var boxLo = SIMD4<Float>(0, 0, 0, 0)
        var boxHi = SIMD4<Float>(0, 0, 0, 0)
        var march = SIMD4<Float>(0.6, 0.1, 0.02, 1500)
        var counts = SIMD4<Float>(0, 0, 0, 0)
        var fields: (FieldU, FieldU, FieldU, FieldU, FieldU, FieldU, FieldU, FieldU) =
            (FieldU(), FieldU(), FieldU(), FieldU(), FieldU(), FieldU(), FieldU(), FieldU())
    }

    static func fieldU(_ f: LatticeSheetField, colour: SIMD3<Float>, perCell: Bool) -> FieldU {
        var u = FieldU()
        func v(_ a: SIMD3<Double>, _ w: Float) -> SIMD4<Float> { SIMD4(Float(a.x), Float(a.y), Float(a.z), w) }
        u.origin = v(f.origin, Float(f.kind.rawValue))
        u.ax0 = v(f.ax[0], 0); u.ax1 = v(f.ax[1], 0); u.ax2 = v(f.ax[2], 0)
        u.anchor = v(f.anchor, Float(f.cellMM))
        u.lo = v(f.lo, f.graded ? 1 : 0)
        u.n = f.graded ? SIMD4(Float(f.n.x), Float(f.n.y), Float(f.n.z), 0) : SIMD4(1, 1, 1, f.wallMM.first ?? 0)
        u.colour = SIMD4(colour, perCell ? 1 : 0)
        return u
    }

    func frame(clipFromModel: simd_float4x4, eyeFromModel: simd_float4x4, eyeNormalBasis: simd_float4x4,
               albedo: SIMD3<Float>, dimmed: Bool) -> Frame? {
        guard let s = drawing, let g = map, let box else { return nil }
        var f = Frame()
        f.clipFromModel = clipFromModel
        f.modelFromClip = clipFromModel.inverse
        f.eyeFromModel = eyeFromModel
        f.eyeNormalBasis = eyeNormalBasis
        f.mapOrigin = SIMD4(g.origin, 0)
        f.mapSpacing = SIMD4(g.voxel, g.voxel, g.voxel, 0)
        f.mapDims = SIMD4(Float(g.dims.x), Float(g.dims.y), Float(g.dims.z), regionTexture != nil ? 1 : 0)
        f.boxLo = SIMD4(box.lo, 0)
        f.boxHi = SIMD4(box.hi, 0)
        f.march = SIMD4(Self.stepFactor, Self.stepCapCells, Self.minStepMM, Self.maxSteps)
        let count = Swift.min(s.fields.count, wallTextures.count, LatticeSheetDrawing.maxFields)
        f.counts = SIMD4(Float(count), Float(Self.lawSteps), Float(Self.lawMaxShare), dimmed ? 1 : 0)
        let colour = dimmed ? LatticeLayoutBarsPass.dimmedRGB(albedo) : albedo
        var us = [FieldU](repeating: FieldU(), count: LatticeSheetDrawing.maxFields)
        for i in 0..<count {
            us[i] = Self.fieldU(s.fields[i], colour: colour, perCell: i < colourTextures.count && colourTextures[i] != nil)
        }
        f.fields = (us[0], us[1], us[2], us[3], us[4], us[5], us[6], us[7])
        return f
    }

    /// A 1×1×1 texture of each kind, bound where there is none (the shader declares every slot).
    private lazy var neutral: (map: MTLTexture?, region: MTLTexture?, wall: MTLTexture?, colour: MTLTexture?) = (
        Self.texture3D(device, .rg8Snorm, dims: SIMD3(1, 1, 1), bytes: [Int8(-127), Int8(-127)]),
        Self.texture3D(device, .r8Uint, dims: SIMD3(1, 1, 1), bytes: [UInt8(255)]),
        Self.texture3D(device, .r16Float, dims: SIMD3(1, 1, 1), bytes: [UInt16(0)]),
        Self.texture3D(device, .rgba8Unorm, dims: SIMD3(1, 1, 1), bytes: [UInt8(255), 255, 255, 255]))

    private func bindTextures(_ set: (MTLTexture?, Int) -> Void) {
        set(mapTexture ?? neutral.map, 0)
        set(regionTexture ?? neutral.region, 1)
        for i in 0..<LatticeSheetDrawing.maxFields {
            set(i < wallTextures.count ? wallTextures[i] : neutral.wall, 2 + i)
            set((i < colourTextures.count ? colourTextures[i] : nil) ?? neutral.colour, 10 + i)
        }
    }

    // MARK: encoding (the bars pass's prepass: its encoder, attachments and .less + write depth state)

    @discardableResult
    func encode(_ enc: MTLRenderCommandEncoder, depthState: MTLDepthStencilState, clipFromModel: simd_float4x4,
                eyeFromModel: simd_float4x4, eyeNormalBasis: simd_float4x4, albedo: SIMD3<Float>, dimmed: Bool) -> Bool {
        guard isDrawable, enc.device === device, let lawBuffer,
              var f = frame(clipFromModel: clipFromModel, eyeFromModel: eyeFromModel, eyeNormalBasis: eyeNormalBasis,
                            albedo: albedo, dimmed: dimmed) else { return false }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        enc.setFragmentBytes(&f, length: MemoryLayout<Frame>.stride, index: 1)
        enc.setFragmentBuffer(lawBuffer, offset: 0, index: 2)
        bindTextures { t, i in enc.setFragmentTexture(t, index: i) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        return true
    }

    // MARK: probes (tests): the shader's own field at points

    private func computePipeline(_ name: String) throws -> MTLComputePipelineState {
        if let p = computeCache[name] { return p }
        guard let fn = library.makeFunction(name: name) else {
            throw NSError(domain: "LatticeLayoutSheetPass", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(name) missing"])
        }
        let p = try device.makeComputePipelineState(function: fn)
        computeCache[name] = p
        return p
    }

    /// The shader's `sheet_distance` of field `field[i]` at `points[i]` (the uploaded fields; no map needed).
    func probe(_ points: [SIMD3<Float>], field: [Int]) -> [Float]? {
        run("sheet_field_probe", points.enumerated().map { SIMD4($0.element, Float($0.offset < field.count ? field[$0.offset] : 0)) },
            seam: nil)
    }

    /// The shader's `sheet_blend` of fields 0 and 1 at `points` with the seam distances `seamMM`, the band and the raise.
    func probeBlend(_ points: [SIMD3<Float>], seamMM: [Float], bandMM: Float, raiseMM: Float) -> [Float]? {
        run("sheet_blend_probe", points.enumerated().map { SIMD4($0.element, $0.offset < seamMM.count ? seamMM[$0.offset] : 0) },
            seam: SIMD4(bandMM, raiseMM, 0, 0))
    }

    private func run(_ name: String, _ pts: [SIMD4<Float>], seam: SIMD4<Float>?) -> [Float]? {
        guard !pts.isEmpty, let pipe = try? computePipeline(name), let queue, let lawBuffer, !wallTextures.isEmpty else { return nil }
        // a frame for the fields alone (no map, no camera)
        var f = Frame()
        let count = Swift.min(drawing?.fields.count ?? 0, wallTextures.count, LatticeSheetDrawing.maxFields)
        f.counts = SIMD4(Float(count), Float(Self.lawSteps), Float(Self.lawMaxShare), 0)
        var us = [FieldU](repeating: FieldU(), count: LatticeSheetDrawing.maxFields)
        for i in 0..<count { us[i] = Self.fieldU(drawing!.fields[i], colour: .one, perCell: false) }
        f.fields = (us[0], us[1], us[2], us[3], us[4], us[5], us[6], us[7])
        var n = UInt32(pts.count)
        var sm = seam ?? .zero
        guard let inBuf = device.makeBuffer(bytes: pts, length: pts.count * 16, options: .storageModeShared),
              let outBuf = device.makeBuffer(length: pts.count * 4, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(pipe)
        enc.setBuffer(inBuf, offset: 0, index: 0)
        enc.setBuffer(outBuf, offset: 0, index: 1)
        enc.setBytes(&f, length: MemoryLayout<Frame>.stride, index: 2)
        enc.setBuffer(lawBuffer, offset: 0, index: 3)
        enc.setBytes(&n, length: 4, index: 4)
        enc.setBytes(&sm, length: 16, index: 5)
        for i in 0..<LatticeSheetDrawing.maxFields { enc.setTexture(i < wallTextures.count ? wallTextures[i] : neutral.wall, index: 2 + i) }
        let w = pipe.threadExecutionWidth
        enc.dispatchThreads(MTLSize(width: pts.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let p = outBuf.contents().bindMemory(to: Float.self, capacity: pts.count)
        return Array(UnsafeBufferPointer(start: p, count: pts.count))
    }
}
#endif
