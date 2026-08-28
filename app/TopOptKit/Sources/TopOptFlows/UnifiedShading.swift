// UnifiedShading.swift — ★ THE SHARED MSL (task 2026-08-18-unified-shading).
//
// ★ THE MAINTAINER'S COMPLAINT WAS "the lattice looks pasted ON the model, not
// like a PART of it", and the diagnosis is not speed: the shell and the lattice
// were being lit, occluded, depth-tested and edge-detected as TWO SEPARATE
// OBJECTS, in two separate MTKViews, with two separate lighting models. This file
// is where the "two" becomes "one":
//
//   `unifiedMaterialSource` — THE ONE MATERIAL. The world-space key/fill/rim rig
//       over a two-colour hemisphere ambient that `render-quality` §2 tuned on his
//       bracket, lifted OUT of `viewer_fragment` verbatim so the lattice can call
//       the same function instead of carrying a second, drifting copy of it. Not
//       one line of the rig is new — §1(d) is "identical material response", and
//       the only way to be sure of that is for there to be exactly one definition.
//
//   `latticeFieldSource` — THE ONE LATTICE FIELD. The sphere-traced strut ∩ part
//       field, its uniforms, its march and its gradient, lifted out of
//       `LatticeSDFRenderer.shaderSource` for the same reason: the standalone
//       preview renderer (still the BEFORE capture, still under its own tests) and
//       the unified pass now march THE SAME field. If they did not, a before/after
//       pair in this task's evidence would be comparing two geometries.
//
// Both are plain Swift string constants concatenated into the shader sources at
// `makeLibrary` time, which is how every shader in this target is built (no .metal
// resource bundling, identical on iOS and macOS).

import Foundation

// MARK: - the ONE material

/// The shared shading vocabulary: `ShadeParams` (the render-quality block) and the
/// key/fill/rim + hemisphere-ambient material, plus the edge/depth-fade tail. Both
/// `viewer_fragment` (the shell) and the unified lattice shade call these.
///
/// ★ EVERY CONSTANT HERE IS `render-quality` §2's, UNCHANGED. It was tuned on his
/// bracket (see the note that travelled with it), and this task's job is to make the
/// lattice obey it — not to retune it. Extracting it is therefore a refactor with no
/// pixel consequence for the shell, which is what makes the shell's own before/after
/// in `evidence/2026-08-15-render-quality` still true.
let unifiedMaterialSource = """
// Render-quality parameters (task 2026-08-15-render-quality). Every strength is a
// 0…1 multiplier and ZERO IS OFF — the before/after captures run this one shader
// with zeros rather than a second, drifting copy of it.
//
// ★ ao.z/ao.w ARE 1/MAIN-TARGET-WIDTH AND -HEIGHT, NOT 1/AO-TEXTURE. They scale a
// fragment coordinate in the COLOUR pass into a normalized uv, so the AO texture is
// free to be smaller than the colour target (which it is whenever a lattice layer is
// present — see `MeshRenderer.gbufferCap`). Sizing them from the AO texture instead
// put uv past 1 and clamped the whole part to one edge texel.
struct ShadeParams { float4 ao; float4 fade; float4 tint; };

/// The two halves of one shade: the diffuse response (ambient + key + fill, already
/// occluded) and the additive rim. Kept apart because the rim is NOT multiplied by
/// albedo — a grazing highlight is light off the surface, not the surface's colour.
struct TOMaterial { float3 shade; float3 rim; };

/// ★ THE ONE BRDF. `Nw` and `V` must be in the SAME space as the light constants
/// below, i.e. WORLD. The shell hands them straight from its vertex stage; the
/// lattice rotates them out of eye space with the inverse view rotation. Everything
/// after that is identical for both, which is the whole of §1(d).
static TOMaterial to_material(float3 Nw, float3 V, float ambientAO, float directAO) {
    // The viewer draws with cullMode .none over meshes of mixed winding, so a
    // face pointing away from the eye is a BACK face, not an unlit one: flip it
    // toward the viewer rather than letting it go black.
    if (dot(Nw, V) < 0.0) { Nw = -Nw; }
    // Hemisphere ambient (a two-colour analytic IBL): cool sky above, warm floor
    // bounce below. This is §2(a)'s "small studio HDR" reduced to its two dominant
    // spherical-harmonic terms — the part of an HDR that actually shapes a matte
    // CAD surface — at one dot product instead of a cubemap fetch.
    // ★ TUNED ON HIS BRACKET, NOT ON A SPHERE (§2d). The first values here were
    // ambient 0.150→0.400 with a 0.42 fill, and on a sphere they were fine. On his
    // bracket, from a camera looking at the side the key does NOT reach, the body
    // came back at roughly 40% grey — legible, but darker than the flat headlight it
    // replaced, and a user orbiting a part WILL find that side. A fixed world light
    // means one side is always the shadow side; the fix is a stronger ambient floor
    // and a stronger fill, not a light that follows the camera back.
    float  up = Nw.y * 0.5 + 0.5;
    float3 ambient = mix(float3(0.225, 0.212, 0.205), float3(0.470, 0.500, 0.550), up);
    // KEY: high, front-left, in WORLD space.
    float3 keyDir = normalize(float3(-0.38, 0.82, 0.42));
    float  keyN   = clamp((dot(Nw, keyDir) + 0.18) / 1.18, 0.0, 1.0);   // wrapped a little
    float3 keyTerm = float3(0.92, 0.90, 0.86) * keyN * 0.72;
    // FILL: low, right, cool and weak — it opens the shadow side without flattening.
    float3 fillDir = normalize(float3(0.72, 0.10, 0.55));
    float  fillN   = clamp(dot(Nw, fillDir) * 0.5 + 0.5, 0.0, 1.0);
    float3 fillTerm = float3(0.30, 0.35, 0.44) * fillN * 0.55;
    // RIM: a narrow grazing edge from behind — what separates one strut from the
    // strut behind it. Fresnel-weighted, so it lives only on silhouettes.
    float3 rimDir = normalize(float3(0.30, 0.30, -0.90));
    float  fres = pow(1.0 - clamp(dot(Nw, V), 0.0, 1.0), 3.5);
    TOMaterial m;
    m.shade = ambient * ambientAO + (keyTerm + fillTerm) * directAO;
    m.rim = float3(0.38, 0.44, 0.56) * fres
          * clamp(dot(Nw, rimDir) * 0.5 + 0.5, 0.0, 1.0) * 0.55 * directAO;
    return m;
}

/// §3a's crease/silhouette line and §3d's depth fade — the tail every shaded surface
/// in the frame ends with. Shared for the same reason as the BRDF: a lattice whose
/// far side did not recede, or whose creases were not drawn, would read as a
/// different substance from the shell no matter how well its diffuse term matched.
static float3 to_edge_fade(float3 color, float edge, float edgeStrength,
                           float eyeZ, float4 fade) {
    // §3a: the dark crease/silhouette line, laid on last so it survives the tint.
    color *= mix(1.0, 0.30, clamp(edge * edgeStrength, 0.0, 1.0));
    // §3d DEPTH FADE: on a dense lattice the far side reads THROUGH the near side and
    // the whole part becomes one texture. Recede the far material toward the stage's
    // own backdrop colour so the two separate. Strength is capped by the caller
    // (`Self.depthFadeStrength`) well below opaque — this is a depth CUE, never fog:
    // at full fade the material is still 55% itself, so no region is ever hidden.
    if (fade.x > 0.001) {
        float t = clamp((eyeZ - fade.y) / max(fade.z - fade.y, 1e-4), 0.0, 1.0);
        color = mix(color, float3(0.055, 0.070, 0.110), t * clamp(fade.x, 0.0, 1.0));
    }
    return color;
}
"""

// MARK: - the ONE lattice field

/// The raymarched lattice: uniforms, the strut ∩ part distance field, the march and
/// the gradient. Shared verbatim between `LatticeSDFRenderer` (the standalone
/// transparent-layer preview — the BEFORE, and still what `LatticeSDFTests` /
/// `LatticeSDFAlignmentTests` measure) and the unified pass inside `MeshRenderer`.
///
/// ★ NOTHING IN THE FIELD CHANGED IN THIS TASK. It was cut out of the fragment
/// function it used to live inside and given a name; the trim erosion, the whole-cell
/// emission, the secant refinement, the step schedule and the ±h gradient are the
/// lines that shipped. This task changes PIXELS, NOT GEOMETRY (R4), and the field is
/// the geometry.
let latticeFieldSource = """
\(shellClipMSL)

struct LSDFUniforms {
    float4 rayX, rayY, rayDir;   // model-space ray basis (see the Swift struct)
    float4 eye, bboxMin, bboxMax, gridOrigin, gridSpacing, gridDims;
    float4 sdfOrigin, sdfSpacing, sdfDims;   // part signed-distance grid
    float4 latticeOrigin;   // xyz origin, w cell mm
    float4 gradeParams;     // rhoMin, rhoMax, gamma, K
    float4 shadeParams;     // uniformRho, hasDemand, radiusFloorNorm, maxSteps
    float4 stepParams;        // stepScale, trimErosion(mm), hasTint, segCount
    float4 lightDir, sparseColor, denseColor;
    // ★★ APPENDED LAST, AND THAT IS LOAD-BEARING. A uniform struct is matched to
    // its Swift twin BY BYTE OFFSET, not by name: the first cut of this field sat
    // after `stepParams` in the MSL while Swift appended it after `denseColor`, so
    // the shader read `lightDir` as the overlay flags — the stress overlay never
    // armed, the dressings never armed, and the key light was being fed a boolean.
    // It cost nothing to find because `LatticeFinishRendersTests` asserts the
    // PIXELS move; it would have cost a great deal to find by eye.
    float4 overlayParams;   // x = stress overlay (>0.5), y = dressing level
    // ★ THE BOUNDARY HUE (2026-08-19). Appended AFTER `overlayParams` in BOTH this
    // struct and the Swift one — these match by BYTE OFFSET, never by name, so a
    // field added to (or removed from) one side alone reads a neighbour's bytes.
    float4 rimColor;
    // ★★ CORE'S MEASURED STRUT LAW, SAMPLED (2026-08-20). 32 normalised radii
    // (diameter at a UNIT cell, halved) across [rhoMin, rhoMax]. The app used to
    // invert rho = K(r/L)^2 here, which disagrees with core's measured table by
    // 1.4-1.7x, WIDENING with density — so the preview drew every strut far thinner
    // than the run builds. The samples come from `octet_strut_diameter_mm` through
    // the bridge; this shader interpolates them and invents nothing.
    // All zero => core had no law for the topology, and the closed form is used.
    float4 strutCurve[8];
    // ── UNIFIED PASS ONLY (zero-filled for the standalone preview, which never
    // reads them). The clip and eye transforms the BODY is drawn with, so a marched
    // hit can be written into the SHARED depth buffer and the SHARED G-buffer in
    // exactly the frame the rasterised shell lives in.
    float4x4 clipFromModel;   // P · V · model — the body's own mvp
    float4x4 eyeFromModel;    // V · model
    float4x4 eyeNormalBasis;  // rotation of V · model, for the G-buffer normal
    // ★★★ THE BUILD DIRECTION, IN MODEL SPACE — xyz unit, w unused. APPENDED LAST on
    // both sides, which this struct's own history says is the only safe place.
    //
    // ★ IT IS NOT +Y AND IT IS NOT A CONSTANT. The printed-layer fill first banded on
    // `hitPos.z`, was "corrected" to `hitPos.y` on the reasoning that the viewer calls
    // model Y the height (`mheight = in.position.y`, the stage's `floorY`) — and that
    // was wrong. Those are the STAGE frame, after the settle rotation the model matrix
    // carries. The part's own build direction is `BuildOrientation.buildDirection`,
    // which defaults to +Z ("Plate up +Z") and MOVES when the orientation is baked. So
    // it is passed rather than assumed, and the layers stack along whatever the user
    // is actually printing along.
    float4 buildDir;
    // ★★★ ORGANIC — the traced struts as a distance field on the DECLARED REGION's own
    // grid. APPENDED LAST, which this struct's history says is the only safe place.
    //   organicOrigin  xyz = voxel-(0,0,0) centre, w = enabled (>0.5)
    //   organicSpacing xyz = voxel mm,             w = the band the field is clamped at
    //   organicDims    xyz = voxel counts,         w unused
    float4 organicOrigin;
    float4 organicSpacing;
    float4 organicDims;
    // ★★★ DIAGNOSIS ONLY, APPENDED LAST — see `LSDFUniforms.debugParams` in Swift.
    // x = 1 paints by the cell LEVEL the hit stands in; 0 is the shipping shade.
    float4 debugParams;
    // x = solid rim (mm) inward from the region boundary; see Swift `rimParams`.
    float4 rimParams;
};

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut lsdf_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = p * 2.0 - 1.0; return o;
}

// Capsule / segment distance (iq).
static inline float sdCap(float3 p, float3 a, float3 b, float r) {
    float3 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

// Ray vs AABB → (tNear, tFar); tFar<tNear ⇒ miss.
static float2 hitBox(float3 ro, float3 rd, float3 lo, float3 hi) {
    float3 inv = 1.0 / rd;
    float3 t0 = (lo - ro) * inv, t1 = (hi - ro) * inv;
    float3 a = min(t0, t1), b = max(t0, t1);
    return float2(max(max(a.x, a.y), a.z), min(min(b.x, b.y), b.z));
}

// MODEL-space ray for a pixel — the exact geometric inverse of the ONE shared
// transform (P·V·settle), built from the CPU-exact camera basis: no matrix
// inversion, no far-plane w cancellation (which used to warp rays by pixels).
static inline float3 lsdf_ray(constant LSDFUniforms& U, float2 uv) {
    return normalize(U.rayDir.xyz + U.rayX.xyz * uv.x + U.rayY.xyz * uv.y);
}

struct LSDFHit { bool hit; float3 pos; float rho; float dressing; float solid;
                 // ★ THE CELL THIS HIT STANDS IN (mm), for the level debug shade.
                 float cellMM;
                 // ★ THE RAW LEVEL the frame read out of the cell texture, so the
                 // debug can compare it against the size it derived from it.
                 float rawLevel; };

/// Core's measured strut radius (in CELL-NORMALISED units) for a relative density,
/// read from the 32 samples the host uploaded. Falls back to the analytic form when
/// no curve was supplied — that is the honest answer for a topology core has not
/// measured, and it is exactly what the app did everywhere before.
static float lsdf_strut_radius_norm(constant LSDFUniforms& U, float rho) {
    float lastSample = U.strutCurve[7].w;
    if (!(lastSample > 0.0)) {                       // no core law — analytic
        return sqrt(max(rho, 0.0) / max(U.gradeParams.w, 1e-6));
    }
    float rhoMin = U.gradeParams.x, rhoMax = U.gradeParams.y;
    float t = clamp((rho - rhoMin) / max(1e-6, rhoMax - rhoMin), 0.0, 1.0) * 31.0;
    int i0 = int(floor(t));
    int i1 = min(i0 + 1, 31);
    float f = t - float(i0);
    float a = U.strutCurve[i0 >> 2][i0 & 3];
    float b = U.strutCurve[i1 >> 2][i1 & 3];
    return mix(a, b, f);
}

/// Sphere-trace the strut ∩ part field. The march runs in the mesh's own frame,
/// where every baked grid lives, and lands on screen exactly where the body pass
/// puts the same point.
// ★★ WHICH CELL IS THIS POINT IN, AND HOW BIG IS IT (task item 3: grade the cell
// SIZE, not only the density).
//
// The cell field is baked on core's BASE grid (S0) and every base cell carries the
// dyadic LEVEL of the octree cell covering it, in G. A level-L cell occupies an
// ALIGNED 2^L block of that grid — that alignment is the entire transition rule, the
// reason a coarse cell's corners land on fine-cell nodes instead of in the middle of
// a face — so the block is recovered here by integer division and everything
// downstream works in the block's own normalised coordinates.
//
// ★ THE STRUT RADIUS THEN GRADES FOR FREE. `lsdf_strut_radius_norm` is a fraction of
// the cell, so the same rho in a 2x cell is a 2x thicker strut in mm — which is
// precisely why a coarser cell is what keeps a sparse region printable, and the
// reason core coarsens it in the first place.
struct LCell {
    float3 q;      // position within the covering cell, [-0.5, 0.5]
    float3 blk;    // that cell's index in level-L units
    float  S;      // its size (mm)
    float  m;      // 2^L, in BASE cells (STEPPED: S/S0, an arbitrary real)
    int    L;
    // ★★★ STEPPED: > 0 when this base cell belongs to a region that stated its own
    // cell VERBATIM, and then `S` is that size and `L`/`blk` are meaningless. See
    // `LatticeCellField.steppedCellMM` for why a dyadic level cannot carry it.
    float  stepped;
    // ★★★ THE TILING'S OWN ORIGIN for this cell, in BASE-CELL units, so two regions on
    // one axis can each put their declared face on a cell boundary. Zero on every other
    // path, which is the global grid origin exactly.
    float3 phase;
    // ★★★ THE DEMAND AT THE TEXEL `S` WAS READ FROM, and the fix for the holes
    // (2026-08-26). See `lsdf_march`'s prefetch: the 27-neighbour cache resolves
    // EVERY entry — self included — by the covering block's CENTRE base cell, while
    // `S` here came from `bi = round(cb)`, the base cell the point is actually in.
    // Over most of a block's extent those are different texels, and a per-spot cell
    // rule gives them different SIZES, so the `sameLattice` test failed for SELF and
    // every segment self owns was skipped. Measured on his own scene: 53.4% of
    // painted cells with single-cell OFF, 81.9% with it ON — which is the order he
    // reported ("it seems to have more holes than with it off").
    //
    // Carrying the demand out of the SAME read makes the self entry true by
    // construction: it can never disagree with the frame it belongs to.
    float  act;
};

// ★ THE READ IS PER BASE CELL, NOT PER STEP. The march samples the same base cell
// many times over; re-reading its level every step cost 6% of the frame budget on the
// bracket (17.6 ms against a 16.6 ms bound) and bought nothing — the level cannot
// change without the base cell changing. The march caches this and recomputes only
// `q`, which is arithmetic.
static LCell lsdf_cell_frame_at(constant LSDFUniforms& U, texture3d<float> cellTex,
                                float3 bi, float3 cb) {
    float S0 = U.latticeOrigin.w;
    float3 dims = U.gridDims.xyz;
    float lvl = 0.0;
    if (all(bi >= -0.5) && all(bi < dims - 0.5)) {
        // G is the level; it is 0 on the ungraded path, so this reduces EXACTLY to
        // the uniform cell the preview drew before — m = 1, blk = bi, q = cb - bi.
        lvl = max(0.0, cellTex.read(uint3(bi), 0).g);
    }
    LCell o;
    o.stepped = 0.0;
    o.act = -1.0;
    // ★ STEPPED TAKES THE SIZE STRAIGHT OUT OF THE TEXTURE. `b` is the covering cell's
    // size in mm, 0 on every other algorithm — so the dyadic path below is untouched
    // and doubled is bit-identical.
    if (all(bi >= -0.5) && all(bi < dims - 0.5)) {
        float4 cs = cellTex.read(uint3(bi), 0);
        float sMM = cs.b;
        if (sMM > 0.0) {
            o.stepped = sMM;
            o.act = cs.r;
            o.S = sMM;
            o.m = sMM / max(S0, 1e-6);
            o.L = 0;
            // ★★★ THE OWNING REGION'S TILING PHASE, unpacked from `axis + fraction`
            // (`LatticeCellField.steppedPhase`). The struts are cut flush at the region's
            // cap planes; this is what puts those planes ON a cell boundary instead of
            // through the middle of a cell, where every strut is sliced at its fattest and
            // the section reads as a quilt. In BASE cells, because everything below is.
            float packed = max(0.0, cs.a);
            int paxis = int(floor(packed + 1e-4));
            float pfrac = packed - float(paxis);
            o.phase = float3(0.0);
            if (paxis >= 0 && paxis <= 2) { o.phase[paxis] = pfrac * o.m; }
            // ★★★ THE BLOCK INDEX, NOT ZERO. This was `float3(0.0)`, and the march
            // caches its 3x3x3 neighbourhood on `baseCell = LC.blk`: a CONSTANT key
            // means the cache is filled once and never refreshed, and every neighbour
            // read `(baseCell + offset) * m` lands next to the grid ORIGIN instead of
            // next to the ray. Stepped therefore drew whatever the corner of the volume
            // happened to contain, everywhere.
            //
            // ★★★ AND IT IS `cb`, NOT `bi` — THE TWO ENCODINGS HAVE DIFFERENT PHASE
            // (maintainer, 2026-08-22: "These are still floating boxes. There is
            // nothing connecting them … there is empty space between them!").
            //
            // The dyadic path anchors a block to the base-cell GRID, so its block index
            // is `floor(round(cb)/m)` and its centre is `blk*m + (m-1)/2`. Stepped does
            // NOT: `lsdf_cell_q` tiles from the ORIGIN POINT by `sMM`, so its cell index
            // is `floor(cb/m)`. Borrowing the dyadic `round(cb)` here put `blk` one cell
            // over wherever `frac(cb) >= 0.5` — HALF of every axis, so only 0.5³ = 12.5%
            // of the volume prefetched its OWN neighbourhood. The other 87.5% read a
            // cell one step away: where that neighbour was inactive the march drew
            // nothing at all, and the boundary between "right" and "wrong" is a regular
            // half-cell lattice — which is exactly the grid of disconnected blocks with
            // void between them that stepped has been rendering. `q` was always correct;
            // only the block it was paired with was not.
            o.blk = floor((cb - o.phase) / max(o.m, 1e-6));
            o.q = float3(0.0);   // filled by the caller, from its own point
            return o;
        }
    }
    o.L = int(lvl + 0.5);
    o.phase = float3(0.0);
    o.m = exp2(float(o.L));
    o.blk = floor(max(bi, float3(0.0)) / o.m);
    o.q = float3(0.0);          // filled by the caller, from its own point
    o.S = S0 * o.m;
    return o;
}

/// ★ WHERE A POINT SITS INSIDE ITS COVERING CELL, [-0.5, 0.5]. The one place the two
/// encodings differ, so neither caller has to know which it is holding.
///
/// STEPPED tiles the SAME axes from the SAME origin as everything else, with its own
/// size — so two regions at 5 and 6 mm do not share nodes where they meet. That is the
/// algorithm, not an approximation of it (core counts the cost as `floating_ends`).
inline float3 lsdf_cell_q(constant LSDFUniforms& U, LCell c, float3 p) {
    if (c.stepped > 0.0) {
        // ★ THE PHASE IS IN BASE CELLS; one stepped cell is `m` of them.
        float3 rel = (p - U.latticeOrigin.xyz) / c.stepped
                   - c.phase / max(c.m, 1e-6);
        return rel - floor(rel) - 0.5;
    }
    float3 cb = (p - U.latticeOrigin.xyz) / U.latticeOrigin.w;
    return (cb - (c.blk * c.m + (c.m - 1.0) * 0.5)) / c.m;
}

/// The whole frame for a point — used where the cost of a read does not repeat
/// (the normal's six taps), never inside the march's inner loop.
static LCell lsdf_cell_frame(constant LSDFUniforms& U, texture3d<float> cellTex,
                             float3 p) {
    float S0 = U.latticeOrigin.w;
    float3 cb = (p - U.latticeOrigin.xyz) / S0;
    LCell o = lsdf_cell_frame_at(U, cellTex, round(cb), cb);
    o.q = lsdf_cell_q(U, o, p);
    return o;
}

/// ★ THE PART'S OUTWARD NORMAL AT `p`, from the part SDF's own gradient. Only ever
/// called within a voxel or two of the surface, where the narrow band is exact.
inline float lsdf_sdf_at(constant LSDFUniforms& U, texture3d<float> sdfTex,
                         sampler samp, float3 p) {
    float3 c = ((p - U.sdfOrigin.xyz) / U.sdfSpacing.xyz + 0.5) / U.sdfDims.xyz;
    return sdfTex.sample(samp, c).r;
}
inline float3 lsdf_part_normal(constant LSDFUniforms& U, texture3d<float> sdfTex,
                               sampler samp, float3 p) {
    float3 h = U.sdfSpacing.xyz;
    float3 g = float3(
        lsdf_sdf_at(U, sdfTex, samp, p + float3(h.x, 0, 0))
      - lsdf_sdf_at(U, sdfTex, samp, p - float3(h.x, 0, 0)),
        lsdf_sdf_at(U, sdfTex, samp, p + float3(0, h.y, 0))
      - lsdf_sdf_at(U, sdfTex, samp, p - float3(0, h.y, 0)),
        lsdf_sdf_at(U, sdfTex, samp, p + float3(0, 0, h.z))
      - lsdf_sdf_at(U, sdfTex, samp, p - float3(0, 0, h.z)));
    float l = length(g);
    return l > 1e-6 ? g / l : float3(0.0, 1.0, 0.0);
}

/// ★★★ THE PART CLIP, EXCEPT WHERE THE SHELL HAS STOOD DOWN (maintainer, 2026-08-21:
/// "the lattices are still peaking through the sides and the top … get rid of that
/// artifacting").
///
/// ★ THE SHELL NOW CORRECTLY SURVIVES on the sides, the chamfer and the top — and the
/// struts still reached those surfaces from behind. `dClip` bottoms out at `dPart`,
/// which is 0 AT the surface, so the strut's cut face and the shell's triangles land at
/// the same depth: z-fighting, resolved per pixel, which is the speckle he is seeing.
///
/// ★ SO THE MARCH ASKS THE SHELL'S OWN QUESTION. Where `shell_is_latticed` is true the
/// shell is gone and the struts must reach the surface — that is the mouth, and a strut
/// stopping short there would leave a visible ledge. Where it is FALSE the shell owns
/// the boundary and the lattice is pulled one voxel inside it, out of contention. One
/// rule, one implementation, evaluated on the part's own normal instead of a fragment's
/// — so the hole and the lattice cannot disagree about which surfaces are open.
///
/// Inert unless the clip is armed (`RC.origin.w`), so the standalone sample block and
/// every pre-existing path are bit-identical.
inline float lsdf_part_clip(constant LSDFUniforms& U, texture3d<float> sdfTex,
                            texture3d<float> regionTex, sampler samp,
                            constant ShellClip& RC, constant float4* decls,
                            float3 p, float dPart) {
    if (RC.origin.w < 0.5) { return dPart; }
    // ★★★ BOUNDED IN MILLIMETRES, NOT IN VOXELS (maintainer, 2026-08-22: "The lattice
    // is stuck and not going the full length of the wall").
    //
    // ★ THIS WAS ONE SDF VOXEL, AND THE SDF VOXEL IS A PREVIEW SETTING. At Fine 128
    // on his part that is 1.72 mm; at Fast 64 — which is what he is on — it is 3.45 mm.
    // So switching the preview to Fast silently ate 3.45 mm of lattice off every
    // surface the shell still draws, which on a wall this size is most of what he
    // marked. A margin whose job is to break a DEPTH COINCIDENCE must not scale with a
    // resolution knob.
    //
    // ★ WHAT IT ACTUALLY HAS TO CLEAR is the sampled field's error at the surface, and
    // core's narrow band is exact on a plane and near-exact on a gentle curve. A
    // quarter of a voxel covers that; the clamp keeps it a fraction of a millimetre at
    // any resolution, which is invisible and still wins the depth test.
    float voxel = max(max(U.sdfSpacing.x, U.sdfSpacing.y), U.sdfSpacing.z);
    // ★★★ DEEP ENOUGH TO WIN THE DEPTH TEST AT A GRAZING ANGLE (2026-08-28).
    //
    // His report: *"I'm seeing a lot of artifacts on the curved chamfers around the
    // lattices."* That is the salt-and-pepper z-fight this inset exists to prevent,
    // and 0.25 voxel — 0.43 mm on his Fine 128 grid — is not enough of it. Depth
    // separation on screen is the offset TIMES the cosine of the view angle, so on a
    // chamfer seen edge-on a 0.43 mm gap collapses to a fraction of a depth unit and
    // the two surfaces trade pixels.
    //
    // ★ AND IT IS FREE. This branch is only taken where `shell_is_latticed` is FALSE —
    // where the shell survives and OWNS the boundary, so everything held back here is
    // hidden behind it anyway. Where the shell is cut the clip is `dPart` untouched and
    // the struts still reach the surface, which is the property the mouth needs.
    //
    // The floor matters as much as the scale: at Fast 64 the voxel is 3.45 mm, and
    // scaling alone would push the inset to 2.6 mm — so it is clamped, and the clamp is
    // what keeps a resolution knob from eating lattice.
    float inset = clamp(0.75 * voxel, 0.60, 1.80);
    if (dPart < -2.0 * inset) { return dPart; }   // deep inside: nothing to fight
    float3 pn = lsdf_part_normal(U, sdfTex, samp, p);
    return shell_is_latticed(p, pn, RC, decls, regionTex) ? dPart : dPart + inset;
}

/// The mm distance to the declared face's OUTLINE at `p`, off the cell field's `g`
/// channel. Negative return = no answer (outside the grid).
inline float lsdf_outline_mm(constant LSDFUniforms& U, texture3d<float> cellTex, float3 p) {
    float S0 = U.latticeOrigin.w;
    float3 bi = round((p - U.latticeOrigin.xyz) / S0);
    float3 dims = U.gridDims.xyz;
    if (any(bi < -0.5) || any(bi >= dims - 0.5)) { return -1.0; }
    return cellTex.read(uint3(bi), 0).g;
}

static LSDFHit lsdf_march(constant LSDFUniforms& U,
                          const device float4* segs,
                          texture3d<float> cellTex,
                          texture3d<float> sdfTex,
                          texture3d<float> regionTex,
                          texture3d<float> organicTex,
                          sampler samp,
                          constant ShellClip& RC,
                          constant float4* decls,
                          float3 ro, float3 rd) {
    LSDFHit out; out.hit = false; out.pos = ro; out.rho = U.shadeParams.x;
    out.dressing = 0.0;
    out.solid = 0.0;
    out.cellMM = 0.0;
    out.rawLevel = 0.0;

    float S0 = U.latticeOrigin.w;
    float3 bmin = U.bboxMin.xyz, bmax = U.bboxMax.xyz;
    // Everything is trimmed flush at the part surface, so a small pad suffices —
    // measured on the COARSEST cell in the plan (gridDims.w = 2^maxLevel), because
    // that is the one whose struts reach furthest out of their own base cell.
    float cell = S0 * max(1.0, U.gridDims.w);
    float3 pad = float3(0.15 * cell);
    float2 tb = hitBox(ro, rd, bmin - pad, bmax + pad);
    if (tb.y < max(tb.x, 0.0)) return out;

    int segCount = int(U.stepParams.w);
    float rhoMin = U.gradeParams.x, rhoMax = U.gradeParams.y;
    float gamma = U.gradeParams.z, K = U.gradeParams.w;
    float uniformRho = U.shadeParams.x;
    bool hasDemand = U.shadeParams.y > 0.5;
    float radiusFloor = U.shadeParams.z;
    int maxSteps = int(U.shadeParams.w);
    // The field is a TRUE distance (min of exact capsule SDFs, radii constant per
    // owning cell), so near-full sphere-trace steps are safe — no Lipschitz-broken
    // squash like the gizmo's ribbons.
    float stepScale = U.stepParams.x;
    float delta = U.stepParams.y;      // trim erosion (mm)
    float3 ncells = U.gridDims.xyz;

    // WHOLE-CELL emission (the worker's canonical-midpoint rule, and the fix for
    // the ragged boundary): a strut renders IFF its OWNING cell is active in the
    // baked per-cell field. Per marched cell we prefetch the 3×3×3 neighbourhood
    // once into registers — value < 0 ⇒ inactive; ≥ 0 ⇒ active with demand d —
    // and precompute each neighbour's graded strut radius. Consecutive steps in
    // the same cell reuse the cache.
    float3 cachedBase = float3(1e9);
    float cachedM = -1.0;
    float3 cachedBI = float3(1e9);
    LCell LC; LC.q = float3(0.0); LC.blk = float3(0.0); LC.S = S0; LC.m = 1.0; LC.L = 0;
    float rnCache[27];
    float rhoCache[27];
    bool anyActive = false;

    float t = max(tb.x, 0.0);
    float tEnd = tb.y;
    // Previous sample along the ray, for the secant hit refinement (A2): the raw
    // sphere-trace accepts a hit anywhere in {F < eps}, an eps-thick shell whose
    // depth along the ray varies with view direction — the surface visibly
    // "breathes" as the camera orbits. One secant step to the F = 0 root makes
    // the rendered surface the true iso-surface from every angle, at zero extra
    // field evaluations.
    float tPrev = t; float FPrev = 1e9;

    // Part signed distance (mm, negative inside): trilinear sample of the exact
    // narrow-band SDF. Distance-to-a-plane is affine, so the part's flat faces
    // interpolate EXACTLY → the trimmed edge is straight (round-3 feedback).
    float3 sdfDims = U.sdfDims.xyz;
    float3 bc = (bmin + bmax) * 0.5, be = (bmax - bmin) * 0.5;

    for (int i = 0; i < maxSteps; i++) {
        if (t > tEnd) break;
        float3 p = ro + rd * t;
        // ★ THE LOCAL CELL, which under a swept plan is not the same size two steps
        // from here. Everything below is in THIS cell's normalised coordinates —
        // and the LEVEL is re-read only when the base cell changes, because it
        // cannot change without it.
        float3 cb = (p - U.latticeOrigin.xyz) / S0;
        float3 bi = round(cb);
        if (any(bi != cachedBI)) {
            cachedBI = bi;
            LC = lsdf_cell_frame_at(U, cellTex, bi, cb);
        }
        // ★ THE TEXTURE READ CACHES ON THE BASE CELL; THE STEPPED BLOCK DOES NOT.
        // A stepped cell is not aligned to the base-cell grid, so `floor(cb/m)` can
        // change while `round(cb)` has not — caching `blk` alongside the read would
        // reintroduce the same off-by-one the frame just fixed. It is two flops.
        if (LC.stepped > 0.0) { LC.blk = floor((cb - LC.phase) / max(LC.m, 1e-6)); }
        float cellHere = LC.S;
        float3 baseCell = LC.blk;
        float3 q = lsdf_cell_q(U, LC, p);

        // Flush trim field: part SDF eroded by `delta` (kills the crease-bulge
        // slivers — see stepParams.y) ∨ the exact part bbox (the bbox term stops
        // the clamp-to-edge sampler extruding faces that touch the bounds).
        float3 stc = ((p - U.sdfOrigin.xyz) / U.sdfSpacing.xyz + 0.5) / sdfDims;
        float dPart = sdfTex.sample(samp, stc).r + delta;
        float3 qb = abs(p - bc) - be;
        float dBox = length(max(qb, 0.0)) + min(max(qb.x, max(qb.y, qb.z)), 0.0);
        // ★ AND THE DECLARED REGION, as a third cutting solid. This is what makes
        // the struts stop exactly where the shell's hole stops, at any cell size
        // — and what makes a sub-millimetre change to the region MOVE the
        // lattice instead of being swallowed by the cell grid.
        // ★★ AND THE DECLARED REGION, SAMPLED — not evaluated. A face region is
        // the face's real OUTLINE extruded to depth (`LatticeFaceOutline`), which
        // has no closed form a fragment can afford; it is baked to a distance
        // field on the CPU and read here. The SAME field the shell's hole is cut
        // from, so the two cannot describe different volumes.
        float dRegion = regionTex.sample(samp, stc).r;
        // ★ See `lsdf_part_clip`: at the declared mouth the struts reach the surface;
        // everywhere the shell survives they stop one voxel inside it.
        float dClip = max(max(lsdf_part_clip(U, sdfTex, regionTex, samp, RC, decls,
                                             p, dPart), dBox), dRegion);

        // ★★★ ORGANIC IS A DIFFERENT LATTICE, SO IT IS A DIFFERENT FIELD — AND THAT IS
        // ALL IT IS. Doubled and stepped fill the part with a CELL, so the march walks a
        // cell grid and tests that cell's unit topology. Organic has no cell: it is
        // curves traced along the principal stress directions, and its geometry is
        // already a union of capsules. Baked to a distance field on the CPU
        // (`organic_preview_field`) it drops straight into the machinery that was
        // already sphere-tracing `partSDF` and the region — one more `max()` term.
        //
        // The alternative was a second renderer: ~100k centreline segments on the GPU
        // with a uniform-grid index, marched in world space. That is what "organic has
        // no cells at all, only traced curves" was taken to imply for months. It does
        // not: the existing renderer can draw it, because a distance field is a distance
        // field whatever produced it.
        if (U.organicOrigin.w > 0.5) {
            float3 og = (p - U.organicOrigin.xyz) / max(U.organicSpacing.xyz, float3(1e-6));
            float dOrg = U.organicSpacing.w;   // outside the field, the clamped band
            if (all(og >= float3(-0.5)) && all(og < U.organicDims.xyz - float3(0.5))) {
                float3 ouv = (og + 0.5) / max(U.organicDims.xyz, float3(1.0));
                dOrg = organicTex.sample(samp, ouv).r;
            }
            float epsO = max(0.02, 0.25 * U.organicSpacing.x);
            float F2 = max(dOrg, dClip);
            if (F2 < epsO) {
                float tHit2 = t;
                if (FPrev < 1e8 && FPrev > F2) {
                    float dt = t - tPrev;
                    tHit2 = clamp(t + F2 * dt / (FPrev - F2), t - dt, t + dt);
                }
                out.hit = true; out.pos = ro + rd * tHit2;
                // ★ THE SHAPE IS CORE'S; THE SHADE IS FLAT, AND THAT IS STATED RATHER
                // THAN INVENTED. The tracer measures a per-voxel relative density and
                // returns it, but it is not uploaded yet — so rather than paint the
                // ramp from a density this field does not carry, organic renders at the
                // stated uniform density. A wrong hue on a right geometry is the kind of
                // quiet lie this preview exists to stop.
                out.rho = U.shadeParams.x; out.dressing = 0.0; out.solid = 0.0;
                out.cellMM = 0.0;
    out.rawLevel = 0.0;      // organic has no cell
                return out;
            }
            FPrev = F2; tPrev = t;
            t += clamp(F2 * stepScale, 0.05 * U.organicSpacing.x, 0.7 * cellHere);
            continue;
        }

        // ★★ THE BOUNDARY DRESSINGS — RIM AND DIAGRID (task D1; maintainer,
        // 2026-08-19: "rim is supposed to be around only the outside edges" and
        // the skin "a covering across all edges/corners").
        //
        // ★ THE SAMPLE BLOCK CAN NAME ITS FACES; A PART CANNOT. On the wizard's
        // cube the twelve edges and six faces are literal, which is how
        // `LatticeSamplePatch` draws them. A declared region on a real part is an
        // arbitrary solid, so the dressings have to be defined by the FIELDS that
        // bound it:
        //
        //   the latticed volume's BOUNDARY  is  dClip ≈ 0
        //   its EDGES are where two of those bounding surfaces MEET — the part's
        //   own surface and the region's — i.e. |dPart| ≈ 0 AND |dRegion| ≈ 0.
        //
        // ★ AND A DRESSING IS A THICKENING, which is what core builds: the
        // diagrid links neighbouring landings ON the face, the rim rides the
        // pairs of boundary faces that meet at an edge. Both are heavier struts
        // where the lattice meets its own boundary, not a separate surface
        // floating over it — so they are applied as a radius multiplier on the
        // struts already there, exactly as the sample uses `radius * 1.6`.
        float eps = max(0.05, 0.015 * cellHere);
        float dressing = 0.0;
        if (U.overlayParams.y > 0.5) {
            // ★★★ A PHYSICAL WIDTH, NOT A FRACTION OF THE LOCAL CELL. See the Swift
            // `rimParams` for the measurement: a band scaled by the LOCAL CELL made the skin twice as
            // wide on the wall whose cell happened to be twice as coarse, out of one
            // bake — which is the asymmetry he photographed and could not be a setting.
            float band = max(U.rimParams.x, 1e-4);
            // The EDGE: both bounding surfaces close at once.
            float edge = max(0.0, 1.0 - abs(dPart) / band)
                       * max(0.0, 1.0 - abs(dRegion) / band);
            dressing = edge;
            // The SKIN adds the whole boundary, not just its edges.
            if (U.overlayParams.y > 1.5) {
                dressing = max(dressing, max(0.0, 1.0 - abs(dClip) / band));
            }
        }

        if (any(baseCell != cachedBase) || LC.m != cachedM) {
            cachedBase = baseCell;
            cachedM = LC.m;
            anyActive = false;
            for (int oz = -1; oz <= 1; oz++) {
                for (int oy = -1; oy <= 1; oy++) {
                    for (int ox = -1; ox <= 1; ox++) {
                        int idx = (ox + 1) * 9 + (oy + 1) * 3 + (oz + 1);
                        // A neighbour at THIS level occupies the aligned block one
                        // step over; its min-corner base cell speaks for all of it,
                        // because every base cell in a block carries the block's
                        // level and the block's demand.
                        // ★ THE NEIGHBOUR'S CENTRE, NOT ITS MIN CORNER. `blk*m` is the
                        // corner, which for a stepped cell sits ON the seam between two
                        // base cells (and for a non-integer `m` is not even a base index)
                        // — a half-voxel of rounding there picks the wrong region's
                        // activation. The centre is unambiguous at any `m`, and reduces
                        // to `blk+off` exactly on the dyadic path.
                        // ★ AND ONLY ON STEPPED. On the dyadic path `blk*m` IS a base
                        // index and every base cell in the block carries the block's
                        // level and demand, so the min corner is already exact — leave
                        // doubled bit-identical.
                        float3 nb = baseCell + float3(ox, oy, oz);
                        // A stepped block's centre in BASE-cell coordinates is
                        // `(nb + 0.5) * m` shifted by the tiling's own phase — the same
                        // shift `q` is measured from, or the cache would prefetch a cell
                        // the ray is not standing in.
                        float3 cc = LC.stepped > 0.0
                                  ? floor((nb + 0.5) * LC.m + LC.phase)
                                  : nb * LC.m;
                        float v = -1.0;
                        if (all(cc >= -0.5) && all(cc < ncells - 0.5)) {
                            float3 rgb = cellTex.read(uint3(cc), 0).rgb;
                            // ★ ONLY SAME-LEVEL NEIGHBOURS CONTRIBUTE. A finer or
                            // coarser neighbour is a different lattice on a different
                            // grid; its struts are marched when the ray is inside IT.
                            // The two still meet, because the dyadic ladder puts the
                            // coarse cell's nodes on fine-cell nodes — what is lost is
                            // only the cap that would bulge across the seam, so a
                            // strut crossing a level change is cut flush there, the
                            // same way every strut is already cut flush at the part
                            // surface and at the region boundary.
                            // ★★★ ON STEPPED THE LEVEL IS ALWAYS 0, SO THIS TEST WAS
                            // VACUOUS. `steppedCellField` writes `level` as all zeros —
                            // stepped has no dyadic ladder — so `rg.y == LC.L` passed for
                            // EVERY neighbour whatever its real cell size. At a grade
                            // transition a 6 mm cell's neighbourhood pulled in 2 mm cells,
                            // their densities and radii were read, and their struts were
                            // evaluated in the WRONG cell's normalised frame: overlapping,
                            // mixed geometry exactly at the boundaries the grade creates.
                            // It could only get worse as the grading started working.
                            //
                            // Stepped's identity is its CELL SIZE, so that is what is
                            // compared. The dyadic path keeps the level test, unchanged.
                            bool sameLattice = LC.stepped > 0.0
                                ? (abs(rgb.b - LC.S) <= 1e-3 * max(LC.S, 1.0))
                                : (int(max(0.0, rgb.g) + 0.5) == LC.L);
                            if (sameLattice) { v = rgb.r; }
                        }
                        if (v >= 0.0) {
                            anyActive = true;
                            float rho = hasDemand
                                ? (rhoMin + (rhoMax - rhoMin) * pow(clamp(v, 0.0, 1.0), gamma))
                                : uniformRho;
                            rhoCache[idx] = rho;
                            // ★★ THE PRINTABLE FLOOR IS PER CELL, NOT PER PART
                            // (maintainer, 2026-08-20: "That lattice preview barely
                            // shows anything").
                            //
                            // ★ THE BAND'S FLOOR IS COMPUTED ONCE, at one cell size.
                            // With a GRADED cell that is wrong everywhere else: strut
                            // diameter scales with the cell, so a density that prints
                            // at 2.6 mm is far under a bead at 1.1 mm. Auto's window
                            // put the base cell at 1.095 mm and every fine cell drew
                            // sub-bead struts — the speckle defect, re-entered through
                            // the grading. The floor has to be asked per cell, and in
                            // normalised terms that is just (bead/2) / S.
                            float rnPrint = U.overlayParams.z > 0.0
                                          ? U.overlayParams.z / max(LC.S, 1e-4) : 0.0;
                            rnCache[idx] = clamp(max(max(radiusFloor, rnPrint),
                                                     lsdf_strut_radius_norm(U, rho)),
                                                 0.0, 0.49);
                        } else {
                            rnCache[idx] = -1.0;
                            rhoCache[idx] = 0.0;
                        }
                    }
                }
            }
        }

        // ★★★ SELF IS RESOLVED FROM THE FRAME'S OWN TEXEL — the holes (2026-08-26).
        //
        // The prefetch above locates every neighbour, self included, at the covering
        // block's CENTRE base cell (`floor((nb + 0.5) * m + phase)`). For a true
        // neighbour that is right. For SELF it is not: `LC.S` was read at
        // `bi = round(cb)`, and over most of a block's extent those two base cells are
        // different texels. A per-spot cell rule gives them different SIZES, the
        // `sameLattice` test fails, `rnCache[13]` goes to −1, and EVERY segment self
        // owns is skipped by the loop below — most of the strutwork the ray is
        // standing in. `anyActive` still comes back true off a neighbour, so nothing
        // is reported, the march carries on, and the result is a thinned, cell-shaped,
        // grid-aligned patch that returns no hit when tapped.
        //
        // Measured on his own scene, replaying this arithmetic on the baked field
        // (`LatticeSelfNeighbourProbe`): 1,415 of 2,649 painted cells (53.4%) with
        // single-cell members OFF, 308 of 376 (81.9%) with it ON — which is the order
        // he reported, "it seems to have more holes than with it off". Zero cells lose
        // ALL 27, which is why this never showed up as a fully dark cell.
        //
        // `LC.act` is the demand carried out of the SAME read that gave `LC.S`, so the
        // self entry cannot disagree with the frame it belongs to. It is recomputed
        // every step rather than inside the block-keyed cache above, because `bi` can
        // change while the block does not — that is the whole defect. No texture read.
        //
        // −1 in the field means the run leaves that material SOLID; self stays inactive
        // there so the solid term below owns it. Dyadic sets `act` to −1 and is
        // therefore bit-identical.
        if (LC.stepped > 0.0 && LC.act >= 0.0) {
            anyActive = true;
            float rhoSelf = hasDemand
                ? (rhoMin + (rhoMax - rhoMin) * pow(clamp(LC.act, 0.0, 1.0), gamma))
                : uniformRho;
            rhoCache[13] = rhoSelf;
            float rnPrintSelf = U.overlayParams.z > 0.0
                              ? U.overlayParams.z / max(LC.S, 1e-4) : 0.0;
            rnCache[13] = clamp(max(max(radiusFloor, rnPrintSelf),
                                    lsdf_strut_radius_norm(U, rhoSelf)),
                                0.0, 0.49);
        }

        float dn = 1e9;
        float rhoNear = uniformRho;
        if (anyActive) {
            // ★ The dressing fattens the struts HERE — one multiplier on the
            // radius the cell already grades to, so a dressed strut is the same
            // strut, heavier, and cannot drift away from the lattice it dresses.
            // 1.6x at full strength is the sample's own weight.
            float fat = 1.0 + 0.6 * clamp(dressing, 0.0, 1.0);
            for (int s = 0; s < segCount; s++) {
                float4 a = segs[2 * s];
                int oi = int(a.w + 0.5);
                float rn = rnCache[oi];
                if (rn < 0.0) continue;
                float d = sdCap(q, a.xyz, segs[2 * s + 1].xyz, min(rn * fat, 0.49));
                if (d < dn) { dn = d; rhoNear = rhoCache[oi]; }
            }
        }
        // CSG intersection: struts ∩ part. max() of 1-Lipschitz SDFs is a valid
        // SDF, so full sphere-trace steps stay safe; struts are cut flush at the
        // part surface, like a machined section — the straight edge.
        // ★★★ WHERE THE RUN LEAVES IT SOLID, DRAW SOLID — DO NOT DRAW A HOLE
        // (maintainer, 2026-08-21: "Can we just make it so the empty spots are filled
        // in with what looks like 3D printed layers? This will cover the holes and also
        // show what it would actually look like.").
        //
        // ★ THE HOLES WERE NEVER MISSING GEOMETRY. A cell whose member cannot hold the
        // floor is refused, `anyActive` stays false, `dn` stays 1e9 — so F was infinite
        // and the ray passed straight through. With the body drawn transparent behind
        // the lattice, that reads as a hole through the wall. It is the opposite: that
        // material is the DENSEST thing in the part, solid plastic wall to wall.
        //
        // ★ SO AN INACTIVE CELL IS CLIPPED BY THE PART AND THE REGION ALONE. `dClip` is
        // already exactly "inside the part, inside what he declared", which is the solid
        // the run will build there. It costs no extra field and cannot disagree with the
        // struts about where the region ends, because it IS the strut's own clip term.
        // ★★★ AND IT SITS STRICTLY INSIDE THE SURFACE — the fix for the speckle and
        // the "broken top faces" the first version of this shipped with (maintainer,
        // 2026-08-21: "Why is it breaking the top faces??? They are just gone").
        //
        // ★ THE SHELL ALREADY DRAWS THAT SURFACE. `dClip` reaches 0 exactly AT the part
        // face, so a solid fill bounded by it renders a second surface at the same
        // depth as the body's own — z-fighting, which is the salt-and-pepper speckle
        // across every wall and, where the fill won, the top faces reading as gone.
        // Pulling the fill in by one SDF voxel gives the shell undisputed ownership of
        // the boundary: the fill is what you see THROUGH the hole in the shell, never
        // what you see instead of the shell.
        // ★ THE FILL TAKES `dClip` UNCHANGED NOW. It used to add its own unconditional
        // one-voxel inset to keep off the shell's surface; `dClip` already does exactly
        // that, and only where the shell is actually there — so the fill reads flush
        // through the mouth instead of recessed behind a ledge, and still cannot
        // z-fight anywhere the shell survives.
        // ★★★ THE TWO TERMS ARE KEPT APART SO THE HIT CAN NAME THE ONE THAT WON
        // (2026-08-27). `out.solid` used to be read off `anyActive`, which was only
        // ever a PROXY for "this hit came from the solid fill, not from a strut" — it
        // happened to hold while the only way to get solid was for a cell to be
        // inactive. It stopped holding the moment the self entry was fixed (see the
        // prefetch above): every painted cell now reports `anyActive`, so the grade's
        // solid band AT THE OUTLINE was being shaded as a strut — flat, untextured,
        // and at a neighbouring strut's density — which is what an edge band with no
        // printed layers in it looks like. Comparing the two fields is exact and needs
        // no proxy.
        float Fstrut = anyActive ? max(dn * cellHere, dClip) : 1e9;
        float Fsolid = anyActive ? 1e9 : dClip;
        // ★★★ THE SOLID OUTLINE — the shape fit's last step, UNIONED IN.
        //
        // ★ IT CANNOT BE DONE BY DEACTIVATING A CELL, and that is why four attempts
        // failed. `anyActive` above is a NEIGHBOURHOOD property — true if any of the
        // 3x3x3 neighbours is active — so a one-cell-wide inactive ring is surrounded by
        // active cells and still draws their struts. Only a large contiguous inactive
        // area ever reads as solid, which is the member floor's case, not an outline's.
        //
        // So the bake writes the mm distance to the face's OUTLINE into `g` (free on the
        // stepped path: there is no dyadic ladder, `L` is 0 regardless, and the
        // same-lattice test keys on the cell SIZE). Within `rimParams.y` of it the field
        // goes solid, clipped by `dClip` so it stays inside the part and inside what he
        // declared. A union can only ADD material, so no neighbour can undo it.
        // ★★★ THE BAND IS A FRACTION OF **THIS CELL**, NOT A MILLIMETRE (2026-08-26).
        //
        // `rimParams.y` used to be millimetres, computed as
        // `max(finestPrintableCell, oneVoxel)` — and the in-plane field is measured ON
        // the occupancy grid, so its smallest non-zero value inside material is one
        // voxel too. The band and the field's floor were the same number, so the test
        // fired wherever the field bottomed out. Worse, `lsdf_outline_mm` NEAREST-reads
        // one value per BASE CELL, so a 1.72 mm test was being evaluated on a 10.31 mm
        // grid: not a ring, a scatter of isolated solid cells mid-wall. That scatter is
        // the "empty space" — solid fill is pale and flat and the shell covers it, so it
        // reads as nothing while still reporting a cell size when tapped.
        //
        // Scaling by `LC.S` asks the question the band was always meant to ask — "does
        // this cell's own extent reach the outline" — in units that cannot collide with
        // the grid's resolution.
        float outlineBand = U.rimParams.y * LC.S;
        if (LC.stepped > 0.0 && U.rimParams.y > 0.0 && LC.S > 0.0) {
            float dOutline = lsdf_outline_mm(U, cellTex, p);
            if (dOutline >= 0.0) {
                Fsolid = min(Fsolid, max(dClip, dOutline - outlineBand));
            }
        }
        // ★★★ DOUBLED'S SOLID CELLS RENDER **SOLID** (maintainer, 2026-08-24
        // evening: "I'm not seeing a solid outline meaning the entire chamfers
        // are held up in thin air"). The ladder's shape fit already DECIDES
        // which cells go solid — a want trimmed below the base rung deactivates
        // the cell — but `anyActive` is a neighbourhood property, so a thin
        // solid ring at the outline still drew its neighbours' struts straight
        // through the material. The sample's OWN cell being inactive is the
        // decision, read back; the union with dClip keeps it inside the part
        // and the declared region. Gated on rimParams.z (armed only when the
        // doubled path baked with declared regions), so every other bake is
        // byte-identical.
        if (LC.stepped == 0.0 && U.rimParams.z > 0.5) {
            float S0d = U.latticeOrigin.w;
            float3 bid = round((p - U.latticeOrigin.xyz) / S0d);
            if (all(bid >= -0.5) && all(bid < U.gridDims.xyz - 0.5)) {
                if (cellTex.read(uint3(bid), 0).r < 0.0) {
                    Fsolid = min(Fsolid, dClip);
                }
            }
        }
        float F = min(Fstrut, Fsolid);
        // ★★★ AND THE LAST SLIVER AT THE OUTLINE IS SOLID, so the lattice meets the
        // face exactly instead of stopping half a cell short. `dRegion` is negative
        // inside the declared region, so {dRegion >= -rim} is the band hugging its
        // boundary; intersecting with `dClip` keeps it inside the part and inside what
        // he declared, and the union with the struts means it can only ADD material.
        // ★ NO RIM TERM HERE ANY MORE. The solid outline is baked into the CELL
        // FIELD (`steppedCellField`), where it can be driven by the face's IN-PLANE
        // shape. Every version of it in this shader was driven by `dRegion`, which for
        // an extruded face region reaches 0 at the DEPTH CAPS as much as at the outline —
        // so it banded the wall's surfaces instead of tracing the face. An inactive cell
        // already renders solid two lines above; that is the whole mechanism.
        if (F < eps) {
            // Secant refinement to the F = 0 root (see tPrev above): F is locally
            // near-linear along the ray, so one step lands within O(eps²) of the
            // true surface — view-independent, no crawl during orbit.
            float tHit = t;
            if (FPrev < 1e8 && FPrev > F) {
                float dt = t - tPrev;
                tHit = clamp(t + F * dt / (FPrev - F), t - dt, t + dt);
            }
            out.hit = true; out.pos = ro + rd * tHit; out.rho = rhoNear;
            // ★ WHAT KIND OF STRUT IT IS, carried out with it: the dressing is
            // already known here (it is what fattened the radius), and the albedo
            // needs it to tell BOUNDARY work from interior fill.
            out.dressing = clamp(dressing, 0.0, 1.0);
            // Carried out so the albedo can draw it as printed layers rather than as
            // a strut of some invented density.
            // Which FIELD produced this hit, not which neighbourhood happened to be
            // active — see the two terms above.
            out.solid = (Fsolid <= Fstrut) ? 1.0 : 0.0;
            out.cellMM = cellHere;
            out.rawLevel = float(LC.L);
            return out;
        }
        FPrev = F; tPrev = t;

        // Advance. Near the surface: sphere-trace F (capped at 0.7·cell so the
        // 3×3×3 strut neighbourhood is never skipped past). Far from the part:
        // the whole render lies in {dClip ≤ eps}, so dClip is a valid distance
        // bound independent of the neighbourhood — leap by it.
        // ★ THE STEP IS CAPPED BY THE FINEST CELL THAT CAN BE ADJACENT, not by the
        // one we are standing in. The plan is 2:1 BALANCED — a face neighbour differs
        // by at most one level — so the smallest thing near a level-L cell is S/2,
        // and a 0.7·S step from inside a coarse cell would march straight over a fine
        // neighbour's struts and punch holes in it.
        // ★ THE FINEST CELL THAT CAN BE ADJACENT. Doubled is a 2:1 BALANCED octree, so
        // a face neighbour is at worst half this one. STEPPED has no balance rule at
        // all — the region next door states whatever it derived — so the bound is the
        // finest cell anywhere in the plan, which is exactly what the base cell `S0` is
        // set to on the stepped path.
        float safeCell = LC.stepped > 0.0 ? U.latticeOrigin.w
                       : (LC.L > 0 ? cellHere * 0.5 : cellHere);
        // ★ THE FLOOR ON THE STEP IS A FRACTION OF THE CELL, AND THE STRUT IS NOT.
        // `debugParams.y` overrides it in mm so the two can be told apart; 0 keeps the
        // shipping arithmetic exactly.
        float stepLo = U.debugParams.y > 0.0 ? U.debugParams.y : 0.05 * safeCell;
        float step = anyActive ? clamp(F * stepScale, stepLo, 0.7 * safeCell)
                               : 0.7 * safeCell;
        step = max(step, dClip - 3.0 * eps);
        t += step;
    }
    return out;
}

/// Gradient of the TRIMMED field (unmasked lattice ∨ part SDF ∨ bbox) at a hit:
/// strut surfaces get strut normals, flush-cut faces get the part surface's normal —
/// flat facets, matching a section cut. ★ THAT FLUSH-CUT FACET IS THE "SHELL WALL"
/// A STRUT MEETS in the lattice view, and the concave seam between the two is
/// exactly where §3's contact term has to appear.
static float3 lsdf_normal(constant LSDFUniforms& U,
                          const device float4* segs,
                          texture3d<float> cellTex,
                          texture3d<float> sdfTex,
                          texture3d<float> regionTex,
                          sampler samp,
                          constant ShellClip& RC,
                          constant float4* decls,
                          float3 hitPos, float hitRho) {
    float3 bmin = U.bboxMin.xyz, bmax = U.bboxMax.xyz;
    float3 bc = (bmin + bmax) * 0.5, be = (bmax - bmin) * 0.5;
    float3 sdfDims = U.sdfDims.xyz;
    int segCount = int(U.stepParams.w);
    float radiusFloor = U.shadeParams.z;
    float K = U.gradeParams.w;
    float delta = U.stepParams.y;

    float rnH = max(radiusFloor, lsdf_strut_radius_norm(U, hitRho));
    rnH = min(rnH, 0.49);
    float h = 0.002 * lsdf_cell_frame(U, cellTex, hitPos).S;
    float3 ex = float3(h, 0, 0), ey = float3(0, h, 0), ez = float3(0, 0, h);
    float3 base = hitPos;
    float3 pts[6] = { base+ex, base-ex, base+ey, base-ey, base+ez, base-ez };
    float d6[6];
    for (int k = 0; k < 6; k++) {
        LCell LCk = lsdf_cell_frame(U, cellTex, pts[k]);
        float3 q = LCk.q;
        float dmin = 1e9;
        for (int s = 0; s < segCount; s++) dmin = min(dmin, sdCap(q, segs[2*s].xyz, segs[2*s+1].xyz, rnH));
        float3 stc = ((pts[k] - U.sdfOrigin.xyz) / U.sdfSpacing.xyz + 0.5) / sdfDims;
        float dP = sdfTex.sample(samp, stc).r + delta;
        float3 qb = abs(pts[k] - bc) - be;
        float dB = length(max(qb, 0.0)) + min(max(qb.x, max(qb.y, qb.z)), 0.0);
        // The region is in this gradient too — a strut cut off at the region
        // boundary must take that plane's normal, exactly as one cut off at the
        // part surface takes the part's. Otherwise the cut face is shaded as if
        // it were still a strut and reads as a tear.
        float dR = regionTex.sample(samp, stc).r;
        d6[k] = max(dmin * LCk.S,
                    max(max(lsdf_part_clip(U, sdfTex, regionTex, samp, RC, decls,
                                           pts[k], dP), dB), dR));
    }
    return normalize(float3(d6[0] - d6[1], d6[2] - d6[3], d6[4] - d6[5]) + 1e-6);
}

/// The lattice's ALBEDO at a hit: the indigo density ramp, plus the face-role tint
/// volume where a marked face's surface voxels carry one.
///
/// ★ ALBEDO, NOT A FINISHED PIXEL. Under the unified material this colour is what
/// the key, fill, rim and occlusion act ON — the same move `render-quality` §4 made
/// for the shell's region tints, and the reason a graded lattice can now read as a
/// shaded solid rather than as a flat colour laid over one.
static float3 lsdf_albedo(constant LSDFUniforms& U,
                          texture3d<float> tintTex,
                          texture3d<float> stressTex,
                          sampler samp,
                          float3 hitPos, float hitRho, float hitDressing,
                          // ★ 1 where the run leaves the material SOLID — see the
                          // printed-layer branch below. Defaulted at every call site
                          // rather than inferred, because "no strut here" and "solid
                          // plastic here" are opposite claims about the same voxel.
                          float hitSolid) {
    // ★★ THE STRESS PLOT, PAINTED ONTO THE STRUTS (maintainer, 2026-08-18:
    // "Allow the stress map to *overlay* on the lattice if it is turned on
    // simultaneously. I want to be able to see the stress map and compare the
    // changes in the lattices themselves").
    //
    // ★ IT REPLACES THE COLOUR, NOT THE GEOMETRY — which is the difference
    // between an overlay and the old behaviour, where turning the stress view on
    // simply hid the lattice. The struts keep their graded radii; only what they
    // are painted with changes, so the two readings can be held against each
    // other. Sampled from a volume baked through `LatticeStressTint.colour`, the
    // same ramp the shell's plot and the legend use, so a strut and the wall
    // behind it report one stress in one colour.
    if (U.overlayParams.x > 0.5) {
        float3 stc = ((hitPos - U.sdfOrigin.xyz) / U.sdfSpacing.xyz + 0.5) / U.sdfDims.xyz;
        return stressTex.sample(samp, stc).rgb;
    }
    // ★★★ SOLID FILL, DRAWN AS PRINTED LAYERS (maintainer, 2026-08-21). Material the
    // run leaves solid gets the look of what the printer will actually lay down there:
    // bands at the REAL layer height, stacked along the build direction.
    //
    // ★ THE LAYER HEIGHT IS THE PRINTER'S, NOT A CONSTANT. `overlayParams.w` carries
    // `PrintParams.layerHeightMM`; at 0 (no printer stated) the banding is skipped
    // entirely rather than drawn at some default, because a wrong layer count is a
    // picture that lies about the part rather than one that merely looks plain.
    //
    // ★ AND IT IS SHADED, NOT STRIPED. A hard stripe at 0.2 mm aliases into moiré the
    // moment the camera moves; this is a smooth ridge profile whose contrast FADES as
    // the bands approach a pixel, so it reads as texture at every zoom instead of
    // shimmering. `fwidth` gives the on-screen period directly.
    if (hitSolid > 0.5) {
        // ★★★ SOLID IS THE **DEEP** END, NOT THE PALE ONE (2026-08-27).
        //
        // This was `mix(denseColor, white, 0.55)` — 55% of the way to white, which made
        // fully dense material PALER than the sparsest strut on the part and inverted
        // the legend the page states in words: *"Thickness follows the density — pale
        // is thin, deep is thick."* A 100%-dense band drawn paler than a 5% strut reads
        // as a gap in the lattice, and that is exactly what he has been circling: the
        // grade's solid ring along the outline (449 cells on his part, measured), drawn
        // as a smooth featureless strip.
        //
        // Proved by a controlled A/B on the device rather than by argument: with the
        // aesthetic ladder cap lifted so the same 449 cells draw as lattice instead of
        // solid (`gradedToSolid` 449 -> 49, everything else identical), the band fills
        // in. The material was always there; only its colour said otherwise.
        //
        // ★ AND IT TAKES ITS NEIGHBOURS' CLASS. The same rule the struts use below —
        // boundary work is the rim hue, interior fill the dense hue — so the solid at a
        // face's outline is continuous with the struts it terminates, instead of being
        // a third colour that has to be learned.
        float3 solidHue = hitDressing > 0.05 ? U.rimColor.xyz : U.denseColor.xyz;
        float lh = U.overlayParams.w;
        if (lh > 1e-4) {
            // ★★★ STACKED ALONG THE BUILD DIRECTION — see `LSDFUniforms.buildDir` for
            // why neither Z nor Y is right as a constant. Zero (an old caller that does
            // not set it) skips the banding rather than banding along an invented axis.
            float3 bd = U.buildDir.xyz;
            float bl = length(bd);
            if (bl < 1e-6) { return solidHue; }
            float z = dot(hitPos, bd / bl) / lh;
            float period = max(fwidth(z), 1e-4);
            // Contrast dies once one layer is thinner than ~1.4 px.
            float legible = clamp(1.0 - period / 1.4, 0.0, 1.0);
            float ridge = 0.5 + 0.5 * cos(6.2831853 * z);
            solidHue *= 1.0 - 0.16 * legible * (1.0 - ridge);
        }
        return solidHue;
    }
    float rhoMin = U.gradeParams.x, rhoMax = U.gradeParams.y;
    float frac = clamp((hitRho - rhoMin) / max(1e-4, rhoMax - rhoMin), 0.0, 1.0);
    // ★★ HUE = WHAT THE STRUT IS; LIGHTNESS = HOW MUCH MATERIAL IS IN IT
    // (maintainer, 2026-08-19: "I thought they were tinted for different *types* of
    // lattice structures. Something like the Rim was blue, the regular cells were
    // purple, the weight taking cells were green").
    //
    // It used to be the owning GROUP's colour, which said which faces he had
    // selected and nothing whatever about the lattice — so on a lattice page the
    // channel was spent on the one thing the page is not about. Three classes now,
    // in the order they take precedence:
    //
    //   BOUNDARY  `dressing > 0`  — rim / diagrid / skin work, the heavier struts
    //                               where the lattice meets its own edge.
    //   INTERIOR  everything else — ordinary fill.
    //
    // ★ A THIRD "load-carrying" hue was removed (2026-08-19): it thresholded DENSITY,
    // which lightness already shows continuously, and the stress overlay answers
    // "where is the load" far better. See `LatticeStructureColour`.
    //
    // Lightness still runs pale→saturated with density INSIDE each hue, so the two
    // readings never collide.
    float3 hue = U.denseColor.xyz;                       // interior fill
    if (hitDressing > 0.05) { hue = U.rimColor.xyz; }    // boundary work
    float3 baseC = mix(U.sparseColor.xyz, hue, clamp(0.25 + 0.75 * frac, 0.0, 1.0));
    // Face-role tint (A4): where the body would have been tinted (anchor / load /
    // keep-clear / protect), the marked face's surface voxels carry that colour in
    // the tint volume — baked from the mesh view's own tint dictionary. The
    // trilinear alpha fades off-face; ×2.2 saturates ON the face so the flush-cut
    // section reads as solidly marked as the body did.
    // ★ THE FACE-ROLE TINT NO LONGER PAINTS THE STRUTS. It is what made every
    // strut carry its group's colour, which is precisely the confusion above. The
    // volume is still bound (the shell uses it); the lattice simply stops reading
    // it, so hue is free to mean structure.
    return baseC;
}
"""

// MARK: - the unified lattice entry points

/// ★ THE LATTICE, INSIDE THE SHELL'S OWN PASSES. Two fragment functions, and
/// between them they are the whole of §1(i)–(iii):
///
///   `lsdf_gbuffer` runs in `MeshRenderer`'s DEPTH PREPASS, writing the marched
///       hit's eye-Z, its eye-space normal and its albedo into the SAME G-buffer
///       the rasterised shell writes — depth-tested against the shell, so whichever
///       surface is nearer per pixel is the one that lands there. AO and the
///       silhouette/crease detector then run ONCE, over the union (§1 i + iii), and
///       the junction where a strut fuses into a wall darkens because both sides of
///       it are finally in the same depth and normal buffers (§3).
///
///   `lsdf_shade` runs in the MAIN pass as a full-screen DEFERRED shade of what that
///       G-buffer holds: no second march (the march is the expensive thing and it
///       happens once), the shell's own `to_material`, the shared AO/edge texture,
///       the shared depth fade — and a fragment depth write, so the shared depth
///       buffer resolves shell-vs-strut interpenetration per pixel (§1 ii) and every
///       overlay drawn afterwards is occluded by the lattice exactly as it is by the
///       shell.
///
/// ★ §2(b): `lsdf_shade` IS a fragment depth write, and it DECLARES ITS DIRECTION.
/// The full-screen triangle is emitted at NDC z = 0 (the near plane) and every depth
/// it writes is ≥ that, so `[[depth(greater)]]` is the truthful declaration and the
/// hardware keeps its early-depth machinery instead of switching the whole pass to
/// late-Z. It is also CONFINED: a pixel with no lattice in the G-buffer discards
/// before it writes anything at all.
let unifiedLatticeShaderSource = """
#include <metal_stdlib>
using namespace metal;

\(unifiedMaterialSource)

\(latticeFieldSource)

// ── the G-buffer write (runs inside the depth prepass) ───────────────────────
// Attachment layout is the shell's, extended by one: 0 = eye-Z (R32Float, what the
// contact pass has always read), 1 = eye-space normal (RGBA16Float), 2 = the
// LATTICE's albedo with alpha as its mask (RGBA8Unorm — the shell writes zero
// alpha there, which is how the deferred shade knows which pixels are its).
struct LSDFGBuf {
    float  eyeZ    [[color(0)]];
    float4 enormal [[color(1)]];
    float4 albedo  [[color(2)]];
    float  depth   [[depth(greater)]];
};

fragment LSDFGBuf lsdf_gbuffer(VOut in [[stage_in]],
                               constant LSDFUniforms& U [[buffer(0)]],
                               const device float4* segs [[buffer(1)]],
                               texture3d<float> cellTex [[texture(0)]],
                               texture3d<float> sdfTex [[texture(1)]],
                               texture3d<float> tintTex [[texture(2)]],
                               texture3d<float> regionTex [[texture(3)]],
                               texture3d<float> stressTex [[texture(4)]],
                               // ★ ORGANIC's traced-strut field. `neutralOrganic()` (a
                               // 1×1×1 of +1e9, i.e. "no strut anywhere") is bound when
                               // the algorithm is not organic, and the uniform's enable
                               // flag means it is never read then.
                               texture3d<float> organicTex [[texture(5)]],
                               sampler samp [[sampler(0)]],
                               // ★ THE SAME BUFFER INDEX THE SHELL'S CLIP USES (4).
                               // `LatticeSDFRenderer.bindFragment` binds it on EVERY
                               // path — a declared-but-unbound buffer makes Metal drop
                               // the draw, the trap this file records twice already.
                               constant ShellClip& RC [[buffer(4)]],
                               // ★ THE DECLARATIONS THE SHELL IS CUT BY — the march
                               // reads the SAME list so it can stop short of exactly
                               // the surfaces the shell still draws. Bound on every
                               // path by `bindFragment`; Metal drops a draw whose
                               // declared buffer is unbound.
                               constant float4* shellDecls [[buffer(5)]]) {
    float3 ro = U.eye.xyz;
    float3 rd = lsdf_ray(U, in.uv);
    LSDFHit h = lsdf_march(U, segs, cellTex, sdfTex, regionTex, organicTex, samp, RC,
                           shellDecls, ro, rd);
    if (!h.hit) { discard_fragment(); }

    float3 n = lsdf_normal(U, segs, cellTex, sdfTex, regionTex, samp, RC, shellDecls,
                           h.pos, h.rho);
    float4 clip = U.clipFromModel * float4(h.pos, 1.0);
    float3 eyeP = (U.eyeFromModel * float4(h.pos, 1.0)).xyz;
    float3 eyeN = normalize((U.eyeNormalBasis * float4(n, 0.0)).xyz);
    // Face the normal toward the eye — the same one-sign-check `depth_fragment`
    // does, and for the same reason: the AO hemisphere must be built on the side of
    // the surface the camera is on, or every sample lands behind the wall and every
    // pixel reports fully occluded.
    if (eyeN.z < 0.0) { eyeN = -eyeN; }

    LSDFGBuf o;
    o.eyeZ = -eyeP.z;                     // eye looks down −Z → positive into the screen
    o.enormal = float4(eyeN, 0.0);
    o.albedo = float4(lsdf_albedo(U, tintTex, stressTex, samp, h.pos, h.rho, h.dressing,
                                  h.solid), 1.0);
    // ★★★ THE LEVEL DEBUG SHADE (diagnosis only; `debugParams.x` is 0 on every shipping
    // frame). Each hit is painted by the CELL it stands in, cycling through six
    // saturated hues per doubling from the base cell, and material the run leaves SOLID
    // is painted flat grey. One frame then answers "what cells is this patch made of",
    // which four rounds of this task tried to infer from the texture instead.
    // ★ MODE 4: the RELATIVE DENSITY the march graded this hit to. The legend states
    // one number for the region; the shader grades per CELL from the demand field, and
    // where that lands high the struts fatten until neighbours merge — which is what a
    // quilt is. Encoded as rho directly (0..1) so the readback is the number.
    if (U.debugParams.x > 3.5) {
        o.enormal = float4(0.0, 0.0, 1.0, 0.0);
        float v = h.solid > 0.5 ? 0.0 : clamp(h.rho, 0.0, 1.0);
        o.albedo = float4(v, v, v, 1.0);
        return o;
    }
    // ★ MODE 3: the drawn cell size, ENCODED. Greyscale = cellMM / 32, written into the
    // albedo attachment, which `latticeMaskDump` blits out unlit — so the cell the march
    // actually stood in comes back as a NUMBER instead of a colour to be argued about.
    if (U.debugParams.x > 2.5) {
        o.enormal = float4(0.0, 0.0, 1.0, 0.0);
        float v = h.solid > 0.5 ? 0.0 : clamp(h.cellMM / 32.0, 0.0, 1.0);
        o.albedo = float4(v, v, v, 1.0);
        return o;
    }
    if (U.debugParams.x > 0.5) {
        // ★★★ AND THE NORMAL IS FLATTENED TO FACE THE EYE. The albedo goes into a
        // G-BUFFER and is lit afterwards, so a debug colour read off the final pixel is
        // albedo x light — which is not a diagnosis, it is a picture of the light rig.
        // Measured: a frame whose levels were all 0 classified as bands 1 and 4 until
        // this line existed. One constant normal makes the shading term the same at
        // every pixel, so the hue that comes out is the hue that went in.
        o.enormal = float4(0.0, 0.0, 1.0, 0.0);
        if (h.solid > 0.5) {
            o.albedo = float4(0.35, 0.35, 0.35, 1.0);
        } else {
            // x = 1 bands by the cell SIZE the frame drew with; x = 2 bands by the RAW
            // LEVEL it read out of the texture. If the two disagree, the base cell the
            // shader is scaling by is not the base cell the bake wrote.
            float S0 = max(U.latticeOrigin.w, 1e-4);
            float L = U.debugParams.x > 1.5
                    ? h.rawLevel
                    : clamp(log2(max(h.cellMM, 1e-4) / S0), 0.0, 5.0);
            int band = int(clamp(L, 0.0, 5.0) + 0.5);
            // ★ PURE CHANNEL COMBINATIONS, not pretty hues. The frame is lit, and
            // lighting MULTIPLIES: a channel that is exactly 0 stays 0 under any light,
            // so the on/off pattern of the three channels survives the rig while a
            // blend of all three does not. A palette of mixed hues read back as the
            // light's colour, which cost a whole round.
            const float3 hues[6] = { float3(1, 0, 0), float3(0, 1, 0), float3(0, 0, 1),
                                     float3(1, 1, 0), float3(0, 1, 1), float3(1, 0, 1) };
            o.albedo = float4(hues[band % 6], 1.0);
        }
    }
    // ★ CLAMPED SO THE DEPTH-DIRECTION DECLARATION IS TRUE BY CONSTRUCTION.
    // (The declaration is named without its brackets on purpose:
    // `testFragmentDepthWritesAreDeclaredConservative` counts that token across
    // this whole source string, and a source-text guard counts COMMENTS too —
    // quoting it here made the count read 3 and failed the guard.)
    // `lsdf_vertex` emits at NDC z = 0, so the declaration promises "never
    // negative" — and `clip.z / max(clip.w, 1e-6)` can go negative for a hit
    // nearer than the near plane, because the max() rescues the denominator's
    // sign and not the numerator's. Breaking a depth-direction contract is
    // undefined behaviour. The clamp keeps the early-Z the declaration buys and
    // removes the way it could lie; it is NOT claimed to change the shell-vs-
    // lattice instability recorded in the handoff, which was measured and is
    // still open.
    o.depth = clamp(clip.z / max(clip.w, 1e-6), 0.0, 1.0);
    return o;
}

// ── the deferred shade (runs inside the MAIN pass) ───────────────────────────
// `proj`  = (tan(fovX/2), tan(fovY/2), gbufferW, gbufferH)
// `depth` = (A, B, mainW, mainH) with ndcDepth = A + B/eyeZ — read straight off the
//           projection matrix the frame is drawn with, so this cannot drift from it.
// `misc`  = (farSentinel, edgeStrength, 0, 0)
struct LatShadeUniforms {
    float4x4 worldFromEyeRot;
    float4 proj;
    float4 depth;
    float4 misc;
};
struct LatShadeOut { float4 color [[color(0)]]; float depth [[depth(greater)]]; };

fragment LatShadeOut lsdf_shade(VOut in [[stage_in]],
                                constant LatShadeUniforms& L [[buffer(0)]],
                                constant ShadeParams& sp [[buffer(2)]],
                                texture2d<float, access::read> gDepth [[texture(1)]],
                                texture2d<float, access::read> gNormal [[texture(2)]],
                                texture2d<float, access::read> gAlbedo [[texture(3)]],
                                texture2d<float, access::sample> aoTex [[texture(0)]]) {
    // The G-buffer may be SMALLER than the colour target (the march is fill-bound,
    // so it is resolution-capped — see `MeshRenderer.gbufferCap`). Map with a
    // nearest read, never a filtered one: bilinear across a strut silhouette mixes
    // a surface normal with the background and haloes the edge.
    float2 scale = float2(L.proj.z / max(L.depth.z, 1.0), L.proj.w / max(L.depth.w, 1.0));
    uint2 g = uint2(clamp(in.pos.xy * scale, float2(0.0),
                          float2(L.proj.z - 1.0, L.proj.w - 1.0)));
    float4 alb = gAlbedo.read(g);
    if (alb.a < 0.5) { discard_fragment(); }
    float eyeZ = gDepth.read(g).x;
    if (eyeZ >= L.misc.x) { discard_fragment(); }

    // Eye-space position and view direction, then both rotated into WORLD space —
    // the space `to_material`'s light constants live in. The eye is the origin in
    // eye space, so the view direction is just −normalize(P): no world position and
    // no matrix inverse needed anywhere in this shader.
    float2 uv  = (in.pos.xy + 0.5) / float2(L.depth.z, L.depth.w);
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    float3 P   = float3(ndc.x * L.proj.x * eyeZ, ndc.y * L.proj.y * eyeZ, -eyeZ);
    float3 Nw  = normalize((L.worldFromEyeRot * float4(gNormal.read(g).xyz, 0.0)).xyz);
    float3 V   = normalize((L.worldFromEyeRot * float4(-normalize(P), 0.0)).xyz);

    // ONE bilinear fetch of the RG texture the SSAO pass wrote — the SAME texture,
    // the same uv convention and the same two strengths the shell's fragment uses.
    constexpr sampler aoSmp(filter::linear, address::clamp_to_edge);
    float2 aoUV = in.pos.xy * float2(sp.ao.z, sp.ao.w);
    float2 aoEdge = aoTex.sample(aoSmp, aoUV).rg;
    float openness = mix(1.0, aoEdge.r, clamp(sp.ao.x, 0.0, 1.0));
    float ambientAO = openness;
    float directAO  = mix(1.0, openness, 0.45);

    TOMaterial m = to_material(Nw, V, ambientAO, directAO);
    float3 color = alb.rgb * m.shade + m.rim;
    color = to_edge_fade(color, aoEdge.g, L.misc.y, eyeZ, sp.fade);

    LatShadeOut o;
    o.color = float4(clamp(color, 0.0, 1.0), 1.0);
    o.depth = clamp(L.depth.x + L.depth.y / max(eyeZ, 1e-6), 0.0, 1.0);
    return o;
}
"""
