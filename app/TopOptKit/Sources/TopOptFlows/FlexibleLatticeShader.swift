// FlexibleLatticeShader — the MSL of the Flexible lattice preview (task
// 2026-09-29-flexible-screens, in-pass round). The field's SECOND copy (see
// FlexibleLatticeField.swift): `flx_field` here is a line-for-line port of
// `FlexibleLatticeField.lattice(at:)`, and FlexibleLatticePassTests samples both at the
// same points and fails if they disagree by more than 2 µm.
//
// ★ A THIRD G-BUFFER WRITER, NOT A LAYER. The maintainer: "look at the way App does the
// lattice preview and build upon that". So this is drawn the way Structural and Aesthetic
// are: `flx_gbuffer` writes MeshRenderer's G-buffer (eye-Z, eye normal, albedo + mask) in
// the depth prepass, and #354's own `lsdf_shade` lights it — the same material, AO,
// creases and depth fade, capped at the same 1152 px. Its OWN library (`gbufferSource`),
// never interpolated into `unifiedLatticeShaderSource`.
//
// ★ A CHANGE TO THE FIELD IS MADE IN BOTH COPIES (Swift reference, this MSL). The app is
// the source of truth for this geometry until core's Flexible lattice exists.
//
// Layout of what lives here:
//   * FlxUniforms / FlxFace / FlxFrame — matched to `FlexibleLatticePass.Uniforms` /
//     `.FaceUniforms` / `.Frame` BY BYTE OFFSET (all float4 / float4x4, same order).
//     `flx_uniform_echo` / `flx_frame_echo` read every field back BY NAME, so a field
//     added or reordered on one side fails a test instead of drawing nonsense.
//   * flx_sample2 — FlexGrid.sample on a PACKED two-channel volume: one integer `read()`
//     per corner returns both channels (ρ + mask, or part SDF + skin distance). The same
//     clamp of u to [0, n−1] and i0 ≤ n−2 clamp. NOT the hardware filter: its weights are
//     8-bit fixed point (1/256 of a voxel), ~2 µm on a 0.5 mm grid.
//   * flx_wall / flx_field — gyroid and honeycomb walls, dRegion, dPart, dSkin.
//   * flx_pullback / flx_deformed — the SQUISH (02 §6), inverted.
//   * flx_march, flx_vertex, flx_gbuffer — the full-screen sphere trace into the G-buffer.
//   * flx_field_probe / flx_squish_probe / flx_uniform_echo / flx_frame_echo — test kernels.

enum FlexibleLatticeShader {
    /// Textures 0, 1 are the packed volumes; the four per-face column tables occupy 2…5
    /// (an `array<texture2d<float>, 4>`).
    static let columnSlot = 2
    static let maxFaces = FlexibleSquishField.maxFaces

    /// The field, the squish and the march — everything but the entry points.
    static let fieldSource = """
    // ── uniforms (all float4; order is the contract with FlexibleLatticePass.Uniforms) ──
    struct FlxFace {
        float4 centroid;   // xyz frame centroid; w = the largest depth (0 = this face does not move)
        float4 xAxis;      // xyz; w = uMin
        float4 yAxis;      // xyz; w = vMin
        float4 load;       // xyz unit, INTO the part; w = column pitch (mm)
        float4 extent;     // x = nu, y = nv, z = min entryT, w = max exitT (the stack's t range)
    };

    struct FlxUniforms {
        float4 boxMin, boxMax;        // the lattice region's AABB (dilated per frame by s·maxDepth)
        float4 shape;                 // x = topology (0 gyroid, 1 honeycomb), y = t, z = Lmin, w = Lmax
        float4 shape2;                // x = honeycomb d, y = skinMM, z = max steps, w = reserved
        float4 buildDir;              // xyz
        float4 rmO, rmN;              // (ρ, mask) grid: xyz = voxel-(0,0,0) centre, w = spacing; dims xyz
        float4 dsO, dsN;              // (part SDF, skin distance) grid
        float4 squish;                // x = s (MeshRenderer.flexScale), y = face count, z = 1: column walls ignored
        float4 march;                 // x = step factor, y = step cap in cells, z = min step mm, w = 1: early-out
        FlxFace faces[4];
        float4 tail;                  // layout sentinel (echoed)
    };

    // per frame: the camera, the renderer's own matrices, the colour ramp
    struct FlxFrame {
        float4 eye, rayX, rayY, rayDir;   // MODEL space (the octet's camera basis, no inversion)
        float4x4 clipFromModel;           // MeshRenderer's P·V·M (uniforms.mvp)
        float4x4 eyeFromModel;            // V·M (uniforms.modelView)
        float4x4 eyeNormalBasis;          // rotation of V·M (uniforms.normalMatrix)
        float4 sparse, dense;             // LatticeStructureColour.pale / .interior
        float4 rhoSpan;                   // x = lo, y = hi (the in-mask ρ span)
        float4 tail;
    };

    // ── FlexGrid.sample on a packed 2-channel volume, exactly ─────────────────────────────
    static inline float2 flx_at(texture3d<float> T, int i, int j, int k) {
        return T.read(uint3(uint(i), uint(j), uint(k))).rg;
    }

    static float2 flx_sample2(texture3d<float> T, float4 O, float4 N, float3 p) {
        float3 u = (p - O.xyz) / O.w;
        int nx = int(N.x), ny = int(N.y), nz = int(N.z);
        float ux = min(max(u.x, 0.0f), float(nx - 1));
        float uy = min(max(u.y, 0.0f), float(ny - 1));
        float uz = min(max(u.z, 0.0f), float(nz - 1));
        int i0 = min(int(ux), max(0, nx - 2)), j0 = min(int(uy), max(0, ny - 2));
        int k0 = min(int(uz), max(0, nz - 2));
        int i1 = min(i0 + 1, nx - 1), j1 = min(j0 + 1, ny - 1), k1 = min(k0 + 1, nz - 1);
        float fx = ux - float(i0), fy = uy - float(j0), fz = uz - float(k0);
        float2 c00 = flx_at(T, i0, j0, k0) * (1 - fx) + flx_at(T, i1, j0, k0) * fx;
        float2 c10 = flx_at(T, i0, j1, k0) * (1 - fx) + flx_at(T, i1, j1, k0) * fx;
        float2 c01 = flx_at(T, i0, j0, k1) * (1 - fx) + flx_at(T, i1, j0, k1) * fx;
        float2 c11 = flx_at(T, i0, j1, k1) * (1 - fx) + flx_at(T, i1, j1, k1) * fx;
        float2 c0v = c00 * (1 - fy) + c10 * fy, c1v = c01 * (1 - fy) + c11 * fy;
        return c0v * (1 - fz) + c1v * fz;
    }

    // mod(x, y) = x − y·floor(x/y) (the spec's, NOT C's fmod: it never goes negative)
    static inline float flx_fmod(float x, float y) { return x - y * floor(x / y); }

    // ── FlexibleLatticeField.wall; `rhoRaw` is the sampled ρ, `Lcur` the local cell ─────
    static float flx_wall(constant FlxUniforms& U, float rhoRaw, float3 p, thread float& Lcur) {
        float t = U.shape.y;
        if (U.shape.x < 0.5f) {
            float rho = min(max(rhoRaw, 0.05f), 0.9f);
            float L = min(max(3.0915f * t / rho, U.shape.z), U.shape.w);
            Lcur = L;
            float k = 2 * M_PI_F / L;
            float3 q = p * k;
            // ★ PRECISE trig: the fast variants are only 2^-13 absolute inside [−π, π] and
            // worse beyond it, and q runs to ~100 rad across a part — |g|/|∇| near the
            // gradient floor turns that into tens of µm.
            float3 c;
            float3 s = precise::sincos(q, c);
            float g = s.x * c.y + s.y * c.z + s.z * c.x;
            float3 grad = k * float3(c.x * c.y - s.z * s.x, c.y * c.z - s.x * s.y, c.z * c.x - s.y * s.z);
            return abs(g) / max(length(grad), 0.05f * k) - 0.5f * t;
        }
        float3 b = normalize(U.buildDir.xyz);
        float3 ref = abs(b.x) < 0.9f ? float3(1, 0, 0) : float3(0, 1, 0);
        float3 e1 = normalize(cross(b, ref)), e2 = cross(b, e1);
        float2 v = float2(dot(p, e1), dot(p, e2));
        float d = U.shape2.x;
        Lcur = d;
        float2 r = float2(d, 1.7320508f * d), h = r * 0.5f;
        float2 A = float2(flx_fmod(v.x, r.x), flx_fmod(v.y, r.y)) - h;
        float2 B = float2(flx_fmod(v.x - h.x, r.x), flx_fmod(v.y - h.y, r.y)) - h;
        float2 q = length_squared(A) < length_squared(B) ? A : B;
        float n = max(abs(q.x), max(abs(0.5f * q.x + 0.8660254f * q.y), abs(-0.5f * q.x + 0.8660254f * q.y)));
        return abs(0.5f * d - n) - 0.5f * t;
    }

    // ── FlexibleLatticeField.lattice: F = max(wall, dRegion, dPart, dSkin) ──────────────
    static float flx_field(constant FlxUniforms& U, texture3d<float> rmT, texture3d<float> dsT,
                           float3 p, thread float& Lcur) {
        float2 rm = flx_sample2(rmT, U.rmO, U.rmN, p);
        float2 ds = flx_sample2(dsT, U.dsO, U.dsN, p);
        float wall = flx_wall(U, rm.x, p, Lcur);
        float dRegion = (0.5f - rm.y) * 2 * U.rmO.w;
        float dPart = ds.x;
        float dSkin = U.shape2.y - ds.y;
        return max(max(wall, dRegion), max(dPart, dSkin));
    }

    // ── the march's view of F: the SAME value, or a cheaper LOWER bound far from the walls ─
    // ★ dPart and dSkin come from ONE fetch of the packed (SDF, skin) volume, and each is
    // ≤ F; where one is clearly positive it is a safe step on its own and the (ρ, mask)
    // fetch and the gyroid's trig are skipped. dRegion is not a distance, but it never
    // exceeds one mask voxel, the step the full max takes there too. Near the walls the
    // full expression runs in flx_field's order, so a hit is flx_field's zero.
    static float flx_field_march(constant FlxUniforms& U, texture3d<float> rmT, texture3d<float> dsT,
                                 float3 p, thread float& Lcur) {
        const float far = 0.25f;
        float2 ds = flx_sample2(dsT, U.dsO, U.dsN, p);
        float dPart = ds.x;
        if (dPart > far) { Lcur = 1e30f; return dPart; }
        float dSkin = U.shape2.y - ds.y;
        if (dSkin > far) { Lcur = 1e30f; return max(dPart, dSkin); }
        float2 rm = flx_sample2(rmT, U.rmO, U.rmN, p);
        float dRegion = (0.5f - rm.y) * 2 * U.rmO.w;
        if (dRegion > far) { Lcur = 1e30f; return max(dRegion, max(dPart, dSkin)); }
        float wall = flx_wall(U, rm.x, p, Lcur);
        return max(max(wall, dRegion), max(dPart, dSkin));
    }

    // ── THE SQUISH, INVERTED (02 §6) ─────────────────────────────────────────────────────
    // Forward: a rest point at t0 ∈ [entry, exit] of its column moves along +load by
    // a·(exit − t0), a = s·d / (exit − entry) — the face the full s·d, the far end nothing.
    // Inverse at a deformed point: t0 = (t − a·exit)/(1 − a); t < entry + a·span is the gap
    // the face left (air). The rest→deformed map contracts the column by (1 − a) along the
    // load, so a rest-space distance times (1 − a) is still a safe step (`scale`).
    // ★ THE COLUMN WALLS. Neighbouring columns move by different amounts, so the deformed
    // field JUMPS across a column wall, and a step sized in one column can land inside the
    // other's shifted wall. The column table's alpha carries, per cell, the largest such
    // jump at s = 1 (`FlexibleSquishFace.columnJumps`): past the wall the surface can be at
    // most s·jump closer than F says. So a step may cross a wall only by that margin, and
    // where neighbours move alike (every interior column of a uniform press) the walls cost
    // nothing. Off the footprint the face's largest depth is the bound.
    struct FlxStep { float L; float scale; float lateral; float jump; };
    struct FlxPull { float3 p0; float scale; float lateral; float jump; float air; };

    static FlxPull flx_pullback(constant FlxUniforms& U, array<texture2d<float>, 4> cols, float3 p) {
        FlxPull r;
        r.p0 = p; r.scale = 1; r.lateral = 1e30f; r.jump = 0; r.air = -1;
        float s = U.squish.x;
        int nf = int(U.squish.y);
        if (!(s > 0.0f)) return r;              // s = 0: the rest lattice, untouched
        for (int f = 0; f < 4; ++f) {
            if (f >= nf) break;
            FlxFace F = U.faces[f];
            if (!(F.centroid.w > 0.0f)) continue;   // no column of this face moves
            float3 d = r.p0 - F.centroid.xyz;
            float t = dot(d, F.load.xyz);
            if (t < F.extent.z || t > F.extent.w) continue;   // material moves only inside [tMin, tMax]
            float pitch = F.load.w;
            float u = dot(d, F.xAxis.xyz) - F.xAxis.w;
            float v = dot(d, F.yAxis.xyz) - F.yAxis.w;
            int iu = int(floor(u / pitch)), iv = int(floor(v / pitch));
            if (iu < 0 || iv < 0 || iu >= int(F.extent.x) || iv >= int(F.extent.y)) {
                float W = F.extent.x * pitch, H = F.extent.y * pitch;
                float lat = length(max(max(float2(-u, -v), float2(u - W, v - H)), 0.0f));
                r.lateral = min(r.lateral, lat); r.jump = max(r.jump, s * F.centroid.w);
                continue;
            }
            // r depth, g entryT, b exitT, a = 1 + jump where a column exists, −jump where not
            float4 c = cols[f].read(uint2(uint(iu), uint(iv)));
            float jump = s * (c.a > 0.5f ? c.a - 1.0f : -c.a);
            if (jump > 1e-4f && U.squish.z < 0.5f) {   // squish.z = 1: diagnosis, walls ignored
                float fu = u - pitch * float(iu), fv = v - pitch * float(iv);
                r.lateral = min(r.lateral, min(min(fu, pitch - fu), min(fv, pitch - fv)));
                r.jump = max(r.jump, jump);
            }
            float span = c.b - c.g;
            if (c.a < 0.5f || !(c.r > 0.0f) || !(span > 1e-6f)) continue;
            if (t < c.g || t > c.b) continue;
            float a = min(s * c.r / span, 0.95f);
            float front = c.g + a * span;           // where the face now is
            if (t < front) { r.air = max(r.air, front - t); continue; }
            float t0 = (t - a * c.b) / (1 - a);
            r.p0 += F.load.xyz * (t0 - t);
            r.scale *= (1 - a);
        }
        return r;
    }

    static float flx_deformed(constant FlxUniforms& U, texture3d<float> rmT, texture3d<float> dsT,
                              array<texture2d<float>, 4> cols, float3 p, thread FlxStep& st, bool march = false) {
        FlxPull pb = flx_pullback(U, cols, p);
        st.scale = pb.scale; st.lateral = pb.lateral; st.jump = pb.jump;
        if (pb.air > 0) { st.L = 1e30f; return pb.air; }
        return march ? flx_field_march(U, rmT, dsT, pb.p0, st.L)
                     : flx_field(U, rmT, dsT, pb.p0, st.L);
    }

    // ── the march ────────────────────────────────────────────────────────────────────────
    // status: 0 = left the box (a true miss), 1 = hit, 2 = ran out of steps
    struct FlxHit { int status; float3 p; };

    static FlxHit flx_march(constant FlxUniforms& U, texture3d<float> rmT, texture3d<float> dsT,
                            array<texture2d<float>, 4> cols, float3 ro, float3 rd) {
        FlxHit h; h.status = 0; h.p = float3(0);
        float3 rdSafe = select(rd, copysign(float3(1e-8f), rd), abs(rd) < 1e-8f);
        float3 inv = 1.0f / rdSafe;
        float3 ta = (U.boxMin.xyz - ro) * inv, tb = (U.boxMax.xyz - ro) * inv;
        float3 tmin = min(ta, tb), tmax = max(ta, tb);
        float tn = max(max(tmin.x, tmin.y), max(tmin.z, 0.0f));
        float tf = min(min(tmax.x, tmax.y), tmax.z);
        if (!(tn < tf)) return h;                 // the lattice region's box: one test per ray outside it
        bool early = U.march.w > 0.5f;
        float t = tn;
        FlxStep st;
        float f = flx_deformed(U, rmT, dsT, cols, ro + rd * t, st, early);
        if (f < 0) { h.status = 1; h.p = ro + rd * t; return h; }
        int maxSteps = int(U.shape2.z);
        for (int i = 0; i < maxSteps; ++i) {
            // ★ step = factor·|F|, never past the topology's cap in cells (see
            // FlexibleLatticePass.stepCap: the gyroid's |g|/|∇| over-reads between the
            // sheets), times the column's contraction; across a column wall only by the jump.
            float step = clamp(U.march.x * abs(f), U.march.z, U.march.y * st.L) * st.scale;
            step = max(min(step, st.lateral + 0.05f), step - st.jump);
            float t2 = t + step;
            if (t2 > tf) return h;
            FlxStep st2;
            float f2 = flx_deformed(U, rmT, dsT, cols, ro + rd * t2, st2, early);
            if (f2 < 0) {
                float a = t, b = t2, fa = f, fb = f2;
                for (int k = 0; k < 4; ++k) {
                    float m = 0.5f * (a + b);
                    FlxStep sm;
                    float fm = flx_deformed(U, rmT, dsT, cols, ro + rd * m, sm);
                    if (fm < 0) { b = m; fb = fm; } else { a = m; fa = fm; }
                }
                // ★ then ONE false-position step on the bracket the halvings left (free: both
                // ends are already evaluated), so the normal is taken ON the wall.
                float w = fa / max(fa - fb, 1e-12f);
                h.status = 1; h.p = ro + rd * mix(a, b, clamp(w, 0.0f, 1.0f));
                return h;
            }
            t = t2; f = f2; st = st2;
        }
        h.status = 2;
        return h;
    }
    """

    /// The pass's library: the field, the G-buffer entry points and the test kernels.
    /// Built with a THROWING `try` (FlexibleLatticePass.init) — a `try?` would hide a dead
    /// library behind an empty frame.
    static let gbufferSource = """
    #include <metal_stdlib>
    using namespace metal;

    \(fieldSource)

    struct FlxVOut { float4 pos [[position]]; float2 uv; };

    // one full-screen triangle at NDC z = 0, uv = NDC — exactly `lsdf_vertex`, so the ray
    // does not depend on the (capped) G-buffer size
    vertex FlxVOut flx_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        FlxVOut o;
        o.pos = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
        o.uv = p * 2.0f - 1.0f;
        return o;
    }

    // ── the G-buffer write (inside MeshRenderer's depth prepass) ─────────────────────────
    // MeshRenderer's attachment layout: 0 = eye-Z (R32Float), 1 = eye-space normal
    // (RGBA16Float), 2 = albedo with alpha as the "this pixel is lattice" mask (RGBA8Unorm).
    // #354's `lsdf_shade` lights what lands here. The declared depth direction is true by
    // construction: the triangle sits at NDC z = 0 and the written depth is clamped ≥ 0.
    struct FlxGBuf {
        float  eyeZ    [[color(0)]];
        float4 enormal [[color(1)]];
        float4 albedo  [[color(2)]];
        float  depth   [[depth(greater)]];
    };

    fragment FlxGBuf flx_gbuffer(FlxVOut in [[stage_in]],
                                 constant FlxUniforms& U [[buffer(0)]],
                                 constant FlxFrame& F [[buffer(1)]],
                                 texture3d<float> rmT [[texture(0)]],
                                 texture3d<float> dsT [[texture(1)]],
                                 array<texture2d<float>, 4> cols [[texture(2)]]) {
        float3 ro = F.eye.xyz;
        float3 rd = normalize(F.rayDir.xyz + F.rayX.xyz * in.uv.x + F.rayY.xyz * in.uv.y);
        FlxHit h = flx_march(U, rmT, dsT, cols, ro, rd);
        if (h.status != 1) { discard_fragment(); }
        // the normal: central differences of the (deformed) field, 0.05 mm
        const float e = 0.05f;
        FlxStep st;
        float3 g = float3(
            flx_deformed(U, rmT, dsT, cols, h.p + float3(e, 0, 0), st)
          - flx_deformed(U, rmT, dsT, cols, h.p - float3(e, 0, 0), st),
            flx_deformed(U, rmT, dsT, cols, h.p + float3(0, e, 0), st)
          - flx_deformed(U, rmT, dsT, cols, h.p - float3(0, e, 0), st),
            flx_deformed(U, rmT, dsT, cols, h.p + float3(0, 0, e), st)
          - flx_deformed(U, rmT, dsT, cols, h.p - float3(0, 0, e), st));
        float3 n = length_squared(g) > 1e-20f ? normalize(g) : -rd;
        float3 eyeN = normalize((F.eyeNormalBasis * float4(n, 0.0f)).xyz);
        // face the normal toward the eye (the AO hemisphere is built on the eye's side)
        if (eyeN.z < 0.0f) { eyeN = -eyeN; }
        // the colour: the octet's lightness-by-density ramp, at the REST point's ρ
        float3 p0 = flx_pullback(U, cols, h.p).p0;
        float rho = flx_sample2(rmT, U.rmO, U.rmN, p0).x;
        float span = F.rhoSpan.y - F.rhoSpan.x;
        float frac = span > 1e-4f ? clamp((rho - F.rhoSpan.x) / span, 0.0f, 1.0f) : 0.0f;
        FlxGBuf o;
        o.eyeZ = -(F.eyeFromModel * float4(h.p, 1.0f)).z;   // eye looks down −Z → positive into the screen
        o.enormal = float4(eyeN, 0.0f);
        o.albedo = float4(mix(F.sparse.rgb, F.dense.rgb, clamp(0.25f + 0.75f * frac, 0.0f, 1.0f)), 1.0f);
        float4 clip = F.clipFromModel * float4(h.p, 1.0f);
        o.depth = clamp(clip.z / max(clip.w, 1e-6f), 0.0f, 1.0f);
        return o;
    }

    // ── test kernels ─────────────────────────────────────────────────────────────────────
    kernel void flx_field_probe(const device float4* pts [[buffer(0)]],
                                device float* out [[buffer(1)]],
                                constant FlxUniforms& U [[buffer(2)]],
                                constant uint& count [[buffer(3)]],
                                texture3d<float> rmT [[texture(0)]],
                                texture3d<float> dsT [[texture(1)]],
                                uint id [[thread_position_in_grid]]) {
        if (id >= count) return;
        float L;
        out[id] = flx_field(U, rmT, dsT, pts[id].xyz, L);
    }

    kernel void flx_squish_probe(const device float4* pts [[buffer(0)]],
                                 device float* out [[buffer(1)]],
                                 constant FlxUniforms& U [[buffer(2)]],
                                 constant uint& count [[buffer(3)]],
                                 texture3d<float> rmT [[texture(0)]],
                                 texture3d<float> dsT [[texture(1)]],
                                 array<texture2d<float>, 4> cols [[texture(2)]],
                                 uint id [[thread_position_in_grid]]) {
        if (id >= count) return;
        FlxStep st;
        out[id] = flx_deformed(U, rmT, dsT, cols, pts[id].xyz, st);
    }

    // every field BY NAME, in declaration order
    kernel void flx_uniform_echo(constant FlxUniforms& U [[buffer(2)]],
                                 device float4* out [[buffer(1)]],
                                 uint id [[thread_position_in_grid]]) {
        if (id != 0) return;
        int k = 0;
        out[k++] = U.boxMin; out[k++] = U.boxMax; out[k++] = U.shape; out[k++] = U.shape2;
        out[k++] = U.buildDir; out[k++] = U.rmO; out[k++] = U.rmN; out[k++] = U.dsO; out[k++] = U.dsN;
        out[k++] = U.squish; out[k++] = U.march;
        for (int f = 0; f < 4; ++f) {
            out[k++] = U.faces[f].centroid; out[k++] = U.faces[f].xAxis; out[k++] = U.faces[f].yAxis;
            out[k++] = U.faces[f].load; out[k++] = U.faces[f].extent;
        }
        out[k++] = U.tail;
    }

    kernel void flx_frame_echo(constant FlxFrame& F [[buffer(2)]],
                               device float4* out [[buffer(1)]],
                               uint id [[thread_position_in_grid]]) {
        if (id != 0) return;
        int k = 0;
        out[k++] = F.eye; out[k++] = F.rayX; out[k++] = F.rayY; out[k++] = F.rayDir;
        for (int c = 0; c < 4; ++c) { out[k++] = F.clipFromModel[c]; }
        for (int c = 0; c < 4; ++c) { out[k++] = F.eyeFromModel[c]; }
        for (int c = 0; c < 4; ++c) { out[k++] = F.eyeNormalBasis[c]; }
        out[k++] = F.sparse; out[k++] = F.dense; out[k++] = F.rhoSpan; out[k++] = F.tail;
    }
    """
}
