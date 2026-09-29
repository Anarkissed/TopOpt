// FlexibleLatticeShader — the MSL of the Flexible lattice preview (task
// 2026-09-29-flexible-screens). The SECOND of the field's three copies (see
// FlexibleLatticeField.swift): `flx_field` here is a line-for-line port of
// `FlexibleLatticeField.lattice(at:)`, and `FlexibleLatticeRendererTests` samples both at
// the same points and fails if they disagree by more than 2 µm.
//
// ★ A CHANGE TO THE FIELD IS MADE IN ALL THREE COPIES (Swift reference, this MSL, the C++
// exporter). The app is the source of truth for this geometry until core's C2 exists
// (maintainer, 2026-09-29), so a drift here is a drift in what he is shown vs what he prints.
//
// Layout of what lives here:
//   * FlxUniforms / FlxFace — matched to `FlexibleLatticeRenderer.Uniforms` BY BYTE OFFSET
//     (all float4, same order). `flx_uniform_echo` reads every field back BY NAME so a test
//     catches a field added or reordered on one side only.
//   * flx_sample  — FlexGrid.sample: trilinear by integer `read()`, the same clamp of u to
//     [0, n−1] and the same i0 ≤ n−2 clamp. NOT the hardware filter: its weights are 8-bit
//     fixed point (1/256 of a voxel), which on a 0.5 mm SDF grid is already ~2 µm.
//   * flx_wall / flx_field — the gyroid and honeycomb walls, dRegion, dPart, dSkin.
//   * flx_pullback / flx_deformed — the SQUISH (02-squish-model §6, the ramp
//     FlexibleOverlay.displacements draws), inverted so the march can evaluate the rest field.
//   * flx_march + flx_vertex/flx_fragment — the full-screen sphere trace.
//   * flx_field_probe / flx_squish_probe / flx_uniform_echo — compute kernels for the tests.

#if canImport(Metal)
enum FlexibleLatticeShader {
    /// Textures 0…3 are ρ, mask, part SDF, skin distance; the four per-face column tables
    /// occupy 4…7 (an `array<texture2d<float>, 4>`).
    static let columnSlot = 4
    static let maxFaces = 4

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // ── uniforms (all float4; order is the contract with FlexibleLatticeRenderer.Uniforms) ──
    struct FlxFace {
        float4 centroid;   // xyz frame centroid; w = the largest depth (0 = this face does not move)
        float4 xAxis;      // xyz; w = uMin
        float4 yAxis;      // xyz; w = vMin
        float4 load;       // xyz unit, INTO the part; w = column pitch (mm)
        float4 extent;     // x = nu, y = nv, z = min entryT, w = max exitT (the stack's t range)
    };

    struct FlxUniforms {
        float4 nearO, nearX, nearY;   // model point on the near plane at NDC (0,0), and per unit NDC x / y
        float4 farO, farX, farY;      // the same on the far plane
        float4 viewport;              // xy = target size in pixels
        float4 boxMin, boxMax;        // the part's AABB padded 1 mm (the march never leaves it)
        float4 shape;                 // x = topology (0 gyroid, 1 honeycomb), y = t, z = Lmin, w = Lmax
        float4 shape2;                // x = honeycomb d, y = skinMM, z = max steps, w = diagnosis
        float4 buildDir;              // xyz
        float4 rhoO, rhoN;            // grid: xyz = voxel-(0,0,0) centre, w = spacing; dims xyz
        float4 maskO, maskN;
        float4 sdfO, sdfN;
        float4 skinO, skinN;
        float4 keyLight, fillLight;   // xyz model-space unit direction, w = strength
        float4 albedo;                // rgb clay, w = ambient
        float4 squish;                // x = s · exaggeration, y = face count, z = 1: column walls ignored (diagnosis)
        float4 march;                 // x = step factor 0.6, y = step cap in cells, z = min step 0.02 mm,
                                      // w = 1: the march's early-out on (FlexibleLatticeRenderer.stepCap)
        FlxFace faces[4];
        float4 tail;                  // layout sentinel (echoed by flx_uniform_echo)
    };

    // ── FlexGrid.sample, exactly ────────────────────────────────────────────────────────
    static inline float flx_at(texture3d<float> T, int i, int j, int k) {
        return T.read(uint3(uint(i), uint(j), uint(k))).r;
    }

    static float flx_sample(texture3d<float> T, float4 O, float4 N, float3 p) {
        float3 u = (p - O.xyz) / O.w;
        int nx = int(N.x), ny = int(N.y), nz = int(N.z);
        float ux = min(max(u.x, 0.0f), float(nx - 1));
        float uy = min(max(u.y, 0.0f), float(ny - 1));
        float uz = min(max(u.z, 0.0f), float(nz - 1));
        int i0 = min(int(ux), max(0, nx - 2)), j0 = min(int(uy), max(0, ny - 2));
        int k0 = min(int(uz), max(0, nz - 2));
        int i1 = min(i0 + 1, nx - 1), j1 = min(j0 + 1, ny - 1), k1 = min(k0 + 1, nz - 1);
        float fx = ux - float(i0), fy = uy - float(j0), fz = uz - float(k0);
        float c00 = flx_at(T, i0, j0, k0) * (1 - fx) + flx_at(T, i1, j0, k0) * fx;
        float c10 = flx_at(T, i0, j1, k0) * (1 - fx) + flx_at(T, i1, j1, k0) * fx;
        float c01 = flx_at(T, i0, j0, k1) * (1 - fx) + flx_at(T, i1, j0, k1) * fx;
        float c11 = flx_at(T, i0, j1, k1) * (1 - fx) + flx_at(T, i1, j1, k1) * fx;
        float c0v = c00 * (1 - fy) + c10 * fy, c1v = c01 * (1 - fy) + c11 * fy;
        return c0v * (1 - fz) + c1v * fz;
    }

    // mod(x, y) = x − y·floor(x/y) (the spec's, NOT C's fmod: it never goes negative)
    static inline float flx_fmod(float x, float y) { return x - y * floor(x / y); }

    // ── FlexibleLatticeField.wall; `Lcur` is the local cell the march clamps its step to ──
    static float flx_wall(constant FlxUniforms& U, texture3d<float> rhoT, float3 p, thread float& Lcur) {
        float t = U.shape.y;
        if (U.shape.x < 0.5f) {
            float rho = min(max(flx_sample(rhoT, U.rhoO, U.rhoN, p), 0.05f), 0.9f);
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
    static float flx_field(constant FlxUniforms& U, texture3d<float> rhoT, texture3d<float> maskT,
                           texture3d<float> sdfT, texture3d<float> skinT, float3 p, thread float& Lcur) {
        float wall = flx_wall(U, rhoT, p, Lcur);
        float dRegion = (0.5f - flx_sample(maskT, U.maskO, U.maskN, p)) * 2 * U.maskO.w;
        float dPart = flx_sample(sdfT, U.sdfO, U.sdfN, p);
        float dSkin = U.shape2.y - flx_sample(skinT, U.skinO, U.skinN, p);
        return max(max(wall, dRegion), max(dPart, dSkin));
    }

    // ── the march's view of F: the SAME value, or a cheaper LOWER bound far from the walls ─
    // ★ dPart, dSkin and dRegion are each ≤ F (F is their max with the wall). The first two
    // are distances, so where one is already clearly positive it is a safe step on its own
    // and the gyroid (six trig calls and a fourth trilinear) is skipped: the empty corners of
    // a part's AABB and its skinned shell cost one or two lookups a step. dRegion is not a
    // distance, but it never exceeds one mask voxel, the step the full max takes there too.
    // Near the walls the full expression runs in flx_field's order, so a hit is flx_field's
    // zero; hits, normals and the probes call flx_field itself.
    static float flx_field_march(constant FlxUniforms& U, texture3d<float> rhoT, texture3d<float> maskT,
                                 texture3d<float> sdfT, texture3d<float> skinT, float3 p, thread float& Lcur) {
        const float far = 0.25f;
        float dPart = flx_sample(sdfT, U.sdfO, U.sdfN, p);
        if (dPart > far) { Lcur = 1e30f; return dPart; }
        float dSkin = U.shape2.y - flx_sample(skinT, U.skinO, U.skinN, p);
        if (dSkin > far) { Lcur = 1e30f; return max(dPart, dSkin); }
        float dRegion = (0.5f - flx_sample(maskT, U.maskO, U.maskN, p)) * 2 * U.maskO.w;
        if (dRegion > far) { Lcur = 1e30f; return max(dRegion, max(dPart, dSkin)); }
        float wall = flx_wall(U, rhoT, p, Lcur);
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
    // where neighbours move alike (jump 0: every interior column of a uniform press) the
    // walls cost nothing. Off the footprint the face's largest depth is the bound.
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

    static float flx_deformed(constant FlxUniforms& U, texture3d<float> rhoT, texture3d<float> maskT,
                              texture3d<float> sdfT, texture3d<float> skinT, array<texture2d<float>, 4> cols,
                              float3 p, thread FlxStep& st, bool march = false) {
        FlxPull pb = flx_pullback(U, cols, p);
        st.scale = pb.scale; st.lateral = pb.lateral; st.jump = pb.jump;
        if (pb.air > 0) { st.L = 1e30f; return pb.air; }
        return march ? flx_field_march(U, rhoT, maskT, sdfT, skinT, pb.p0, st.L)
                     : flx_field(U, rhoT, maskT, sdfT, skinT, pb.p0, st.L);
    }

    // ── the march ────────────────────────────────────────────────────────────────────────
    // status: 0 = left the box (a true miss), 1 = hit, 2 = ran out of steps (diagnosis)
    struct FlxHit { int status; float3 p; };

    static FlxHit flx_march(constant FlxUniforms& U, texture3d<float> rhoT, texture3d<float> maskT,
                            texture3d<float> sdfT, texture3d<float> skinT, array<texture2d<float>, 4> cols,
                            float3 ro, float3 rd) {
        FlxHit h; h.status = 0; h.p = float3(0);
        float3 rdSafe = select(rd, copysign(float3(1e-8f), rd), abs(rd) < 1e-8f);
        float3 inv = 1.0f / rdSafe;
        float3 ta = (U.boxMin.xyz - ro) * inv, tb = (U.boxMax.xyz - ro) * inv;
        float3 tmin = min(ta, tb), tmax = max(ta, tb);
        float tn = max(max(tmin.x, tmin.y), max(tmin.z, 0.0f));
        float tf = min(min(tmax.x, tmax.y), tmax.z);
        if (!(tn < tf)) return h;
        bool early = U.march.w > 0.5f;
        float t = tn;
        FlxStep st;
        float f = flx_deformed(U, rhoT, maskT, sdfT, skinT, cols, ro + rd * t, st, early);
        if (f < 0) { h.status = 1; h.p = ro + rd * t; return h; }
        int maxSteps = int(U.shape2.z);
        for (int i = 0; i < maxSteps; ++i) {
            // ★ step = factor·|F|, never past the topology's cap in cells (see
            // FlexibleLatticeRenderer.stepCap: the gyroid's |g|/|∇| over-reads between the
            // sheets), times the column's contraction; across a column wall only by the jump.
            float step = clamp(U.march.x * abs(f), U.march.z, U.march.y * st.L) * st.scale;
            step = max(min(step, st.lateral + 0.05f), step - st.jump);
            float t2 = t + step;
            if (t2 > tf) return h;
            FlxStep st2;
            float f2 = flx_deformed(U, rhoT, maskT, sdfT, skinT, cols, ro + rd * t2, st2, early);
            if (f2 < 0) {
                float a = t, b = t2, fa = f, fb = f2;
                for (int k = 0; k < 4; ++k) {
                    float m = 0.5f * (a + b);
                    FlxStep sm;
                    float fm = flx_deformed(U, rhoT, maskT, sdfT, skinT, cols, ro + rd * m, sm);
                    if (fm < 0) { b = m; fb = fm; } else { a = m; fa = fm; }
                }
                // ★ then ONE false-position step on the bracket the halvings left (free: both
                // ends are already evaluated), so the normal is taken ON the wall rather than
                // up to a sixteenth of a step off it.
                float w = fa / max(fa - fb, 1e-12f);
                h.status = 1; h.p = ro + rd * mix(a, b, clamp(w, 0.0f, 1.0f));
                return h;
            }
            t = t2; f = f2; st = st2;
        }
        h.status = 2;
        return h;
    }

    struct FlxVOut { float4 pos [[position]]; };

    // one full-screen triangle
    vertex FlxVOut flx_vertex(uint vid [[vertex_id]]) {
        float2 xy = float2(float((vid << 1) & 2), float(vid & 2));
        FlxVOut o;
        o.pos = float4(xy * 2.0f - 1.0f, 0.0f, 1.0f);
        return o;
    }

    fragment float4 flx_fragment(FlxVOut in [[stage_in]],
                                 constant FlxUniforms& U [[buffer(0)]],
                                 texture3d<float> rhoT [[texture(0)]],
                                 texture3d<float> maskT [[texture(1)]],
                                 texture3d<float> sdfT [[texture(2)]],
                                 texture3d<float> skinT [[texture(3)]],
                                 array<texture2d<float>, 4> cols [[texture(4)]]) {
        float2 ndc = float2(in.pos.x / U.viewport.x * 2.0f - 1.0f, 1.0f - in.pos.y / U.viewport.y * 2.0f);
        float3 pn = U.nearO.xyz + ndc.x * U.nearX.xyz + ndc.y * U.nearY.xyz;
        float3 pf = U.farO.xyz + ndc.x * U.farX.xyz + ndc.y * U.farY.xyz;
        float3 rd = normalize(pf - pn);
        FlxHit h = flx_march(U, rhoT, maskT, sdfT, skinT, cols, pn, rd);
        // diagnosis only (shape2.w = 1): a ray that ran out of steps is painted red
        if (h.status == 2 && U.shape2.w > 0.5f) return float4(0.9f, 0.1f, 0.1f, 1.0f);
        if (h.status != 1) return float4(0.0f);
        // normal: central differences of the (deformed) field, 0.05 mm
        const float e = 0.05f;
        FlxStep st;
        float3 g = float3(
            flx_deformed(U, rhoT, maskT, sdfT, skinT, cols, h.p + float3(e, 0, 0), st)
          - flx_deformed(U, rhoT, maskT, sdfT, skinT, cols, h.p - float3(e, 0, 0), st),
            flx_deformed(U, rhoT, maskT, sdfT, skinT, cols, h.p + float3(0, e, 0), st)
          - flx_deformed(U, rhoT, maskT, sdfT, skinT, cols, h.p - float3(0, e, 0), st),
            flx_deformed(U, rhoT, maskT, sdfT, skinT, cols, h.p + float3(0, 0, e), st)
          - flx_deformed(U, rhoT, maskT, sdfT, skinT, cols, h.p - float3(0, 0, e), st));
        float3 n = length_squared(g) > 1e-20f ? normalize(g) : -rd;
        if (dot(n, rd) > 0) n = -n;               // always shade the side the eye sees
        float key = max(dot(n, U.keyLight.xyz), 0.0f) * U.keyLight.w;
        float fill = max(dot(n, U.fillLight.xyz), 0.0f) * U.fillLight.w;
        float3 col = clamp(U.albedo.rgb * (U.albedo.w + key + fill), 0.0f, 1.0f);
        return float4(col, 1.0f);                 // premultiplied: alpha 1 on a wall, 0 elsewhere
    }

    // ── test kernels ─────────────────────────────────────────────────────────────────────
    kernel void flx_field_probe(const device float4* pts [[buffer(0)]],
                                device float* out [[buffer(1)]],
                                constant FlxUniforms& U [[buffer(2)]],
                                constant uint& count [[buffer(3)]],
                                texture3d<float> rhoT [[texture(0)]],
                                texture3d<float> maskT [[texture(1)]],
                                texture3d<float> sdfT [[texture(2)]],
                                texture3d<float> skinT [[texture(3)]],
                                uint id [[thread_position_in_grid]]) {
        if (id >= count) return;
        float L;
        out[id] = flx_field(U, rhoT, maskT, sdfT, skinT, pts[id].xyz, L);
    }

    kernel void flx_squish_probe(const device float4* pts [[buffer(0)]],
                                 device float* out [[buffer(1)]],
                                 constant FlxUniforms& U [[buffer(2)]],
                                 constant uint& count [[buffer(3)]],
                                 texture3d<float> rhoT [[texture(0)]],
                                 texture3d<float> maskT [[texture(1)]],
                                 texture3d<float> sdfT [[texture(2)]],
                                 texture3d<float> skinT [[texture(3)]],
                                 array<texture2d<float>, 4> cols [[texture(4)]],
                                 uint id [[thread_position_in_grid]]) {
        if (id >= count) return;
        FlxStep st;
        out[id] = flx_deformed(U, rhoT, maskT, sdfT, skinT, cols, pts[id].xyz, st);
    }

    // every field BY NAME, in declaration order (see the note at the top)
    kernel void flx_uniform_echo(constant FlxUniforms& U [[buffer(2)]],
                                 device float4* out [[buffer(1)]],
                                 uint id [[thread_position_in_grid]]) {
        if (id != 0) return;
        int k = 0;
        out[k++] = U.nearO; out[k++] = U.nearX; out[k++] = U.nearY;
        out[k++] = U.farO; out[k++] = U.farX; out[k++] = U.farY;
        out[k++] = U.viewport; out[k++] = U.boxMin; out[k++] = U.boxMax;
        out[k++] = U.shape; out[k++] = U.shape2; out[k++] = U.buildDir;
        out[k++] = U.rhoO; out[k++] = U.rhoN; out[k++] = U.maskO; out[k++] = U.maskN;
        out[k++] = U.sdfO; out[k++] = U.sdfN; out[k++] = U.skinO; out[k++] = U.skinN;
        out[k++] = U.keyLight; out[k++] = U.fillLight; out[k++] = U.albedo; out[k++] = U.squish;
        out[k++] = U.march;
        for (int f = 0; f < 4; ++f) {
            out[k++] = U.faces[f].centroid; out[k++] = U.faces[f].xAxis; out[k++] = U.faces[f].yAxis;
            out[k++] = U.faces[f].load; out[k++] = U.faces[f].extent;
        }
        out[k++] = U.tail;
    }
    """
}
#endif
