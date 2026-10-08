// LatticeSDFMetal.swift — the RAYMARCHED lattice preview (handoff
// 2026-07-29-lattice-preview). It shows the maintainer the ACTUAL struts he is about
// to print, with ZERO lattice triangles on the device, using the exact technique the
// transform gizmo proved on this hardware (PR 205): a strut lattice is an analytic
// distance field, so a fragment shader sphere-traces it PER PIXEL. The cost is
// per-pixel, not per-triangle, so it does NOT grow as (1/cell)³ the way a real
// lattice mesh does (368 k tris → 2.9 M → PR-184's 2.8 GB over the iOS ceiling).
//
// The field is the periodic union of the lattice's struts (`LatticeSDFPreview`,
// derived from the worker's own cell table), tiled by folding the world point into
// one cell. It is masked to the part in two composed stages:
//   • WHOLE-CELL emission (round 2) — the worker's canonical-midpoint ownership: a
//     strut exists iff its OWNING cell overlaps the part (`cellField`), so no cell
//     is ever lost to a knife-edge test;
//   • a FLUSH TRIM (round 3) — CSG-intersecting the strut field with the part's
//     exact narrow-band signed-distance field, so struts are cut flush at the
//     surface like a machined section. Flat faces interpolate exactly through the
//     trilinear SDF, so the part's straight edges render STRAIGHT at every cell
//     size — and the boundary is what production's owed lattice∪wall union yields.
// Strut radius is GRADED per owning cell by the demand baked into the same field,
// so a graded lattice (the feature) is shown directly.
//
// P2 (no per-frame regeneration): there is no geometry to regenerate. The per-cell
// texture is baked once on a data or cell-size change; orbiting only re-runs the
// fragment shader with a new camera matrix. The MTKView is `isPaused` +
// redraw-on-demand, exactly like the gizmo. `draw()` asserts no bake happens inside
// a frame.

#if canImport(MetalKit)
import MetalKit
import SwiftUI
import Combine
import simd
import TopOptDesign
import TopOptKit

// MARK: - Uniforms (layout MUST match the MSL struct)

struct LSDFUniforms {
    // Per-pixel ray basis in MODEL space, computed exactly on the CPU (no matrix
    // inversion anywhere in the ray path): rd = normalize(rayDir + rayX·u + rayY·v).
    // Unprojecting clip corners through inv(P·V·model) — the previous scheme — hits
    // catastrophic cancellation in w at the far plane (terms of ~1 summing to ~1e-4
    // in Float), which warped rays by 1–4 px and swam during orbit (bars A1/A2).
    var rayX: SIMD4<Float>                    // camera right · tan(fovY/2)·aspect (model space)
    var rayY: SIMD4<Float>                    // camera up · tan(fovY/2) (model space)
    var rayDir: SIMD4<Float>                  // camera forward (unit, model space)
    var eye: SIMD4<Float>                     // xyz camera position in MODEL space
    var bboxMin: SIMD4<Float>                 // part AABB (ray clip)
    var bboxMax: SIMD4<Float>
    var gridOrigin: SIMD4<Float>              // per-CELL field: cell-(0,0,0) centre (== part min)
    var gridSpacing: SIMD4<Float>             // per-CELL field: cellMM per axis
    var gridDims: SIMD4<Float>                // per-CELL field dims (ncx, ncy, ncz)
    var sdfOrigin: SIMD4<Float>               // part-SDF grid voxel-(0,0,0) centre
    var sdfSpacing: SIMD4<Float>              // part-SDF grid spacing (mm per axis)
    var sdfDims: SIMD4<Float>                 // part-SDF grid dims
    var latticeOrigin: SIMD4<Float>           // xyz cell origin; w = cell size (mm)
    var gradeParams: SIMD4<Float>             // rhoMin, rhoMax, gamma, K
    var shadeParams: SIMD4<Float>             // uniformRho, hasDemand, radiusFloorNorm, maxSteps
    var stepParams: SIMD4<Float>              // stepScale, trimErosion(mm), hasTint, segCount
    var lightDir: SIMD4<Float>                // xyz key light (model space — world light un-settled)
    var sparseColor: SIMD4<Float>            // rgb (sparse end of the indigo ramp)
    var denseColor: SIMD4<Float>             // rgb (dense end)
    /// x = stress overlay on (>0.5), y = dressing level. Appended AFTER every field
    /// the shipping shaders read, so their byte layout is untouched.
    var overlayParams: SIMD4<Float> = .zero
    /// ★★ THE STRUCTURE HUES — and their POSITION here is load-bearing. This struct
    /// is matched to its MSL twin by BYTE OFFSET, so these sit immediately after
    /// `overlayParams` on BOTH sides. The last field added to one side alone made
    /// the shader read `lightDir` as the overlay flags; `LatticeFinishRendersTests`
    /// is what caught it, by asserting pixels move.
    var rimColor: SIMD4<Float> = .zero        // boundary work: rim / diagrid / skin
    /// ★★ CORE'S MEASURED STRUT LAW, SAMPLED — 32 normalised radii across the band,
    /// as 8 float4s. MUST stay immediately after `rimColor` and in this order: the
    /// MSL twin declares `float4 strutCurve[8]` in the same slot, and these match by
    /// BYTE OFFSET. All zero means "no core law", and the shader falls back to the
    /// analytic form.
    var strutCurve0: SIMD4<Float> = .zero
    var strutCurve1: SIMD4<Float> = .zero
    var strutCurve2: SIMD4<Float> = .zero
    var strutCurve3: SIMD4<Float> = .zero
    var strutCurve4: SIMD4<Float> = .zero
    var strutCurve5: SIMD4<Float> = .zero
    var strutCurve6: SIMD4<Float> = .zero
    var strutCurve7: SIMD4<Float> = .zero
    // ── UNIFIED PASS ONLY (task 2026-08-18-unified-shading). The clip and eye
    // transforms the BODY is drawn with, so a marched hit can be written into the
    // SHARED depth buffer and the SHARED G-buffer of `MeshRenderer`'s own passes.
    // Identity for the standalone preview renderer, which never reads them — its
    // fragment function has no depth output and no G-buffer to write.
    var clipFromModel: simd_float4x4 = matrix_identity_float4x4
    var eyeFromModel: simd_float4x4 = matrix_identity_float4x4
    var eyeNormalBasis: simd_float4x4 = matrix_identity_float4x4
    /// ★★★ THE BUILD DIRECTION IN MODEL SPACE (unit, w unused) — APPENDED LAST, and
    /// the MSL twin declares `float4 buildDir` in the same final slot. Zero means "not
    /// stated", and the printed-layer banding is then skipped rather than drawn along a
    /// guessed axis. See the MSL note for why +Y was wrong.
    var buildDir: SIMD4<Float> = .zero
    /// ★★★ ORGANIC — the traced-strut field's grid. APPENDED LAST, in this order, and
    /// the MSL twin declares the same three in the same final slots.
    /// origin.w = enabled; spacing.w = the band the field is clamped at.
    var organicOrigin: SIMD4<Float> = .zero
    var organicSpacing: SIMD4<Float> = SIMD4(1, 1, 1, 0)
    var organicDims: SIMD4<Float> = SIMD4(1, 1, 1, 0)
    /// ★★★ DIAGNOSIS ONLY — APPENDED LAST, and the MSL twin declares it in the same
    /// final slot (these match by BYTE OFFSET, never by name).
    ///
    /// x = 0 shades normally, which is every shipping frame. x = 1 paints each hit by
    /// the LEVEL of the cell it is standing in, so "which cells is this patch made of"
    /// is a question the picture answers instead of one an argument answers. Four
    /// rounds of this task were spent inferring the level from the texture; the
    /// handoff of 2026-08-22 named this instrument twice before it was built.
    var debugParams: SIMD4<Float> = .zero
    /// ★★★ THE SOLID RIM THAT MAKES THE LATTICE FIT THE FACE EXACTLY.
    ///
    /// ★★★ x = THE DRESSING BAND, IN MILLIMETRES — how wide the rim/skin work is.
    ///
    /// ★ IT USED TO BE `0.12 * cellHere`, A FRACTION OF THE LOCAL CELL, and that is the
    /// skin asymmetry he photographed (2026-08-23: one wall with skin, one without, "the
    /// same fucking setting but just turned around"). His two walls derive DIFFERENT
    /// cells, so a 12 mm wall got a 1.44 mm band and a 6 mm wall got 0.72 mm — half the
    /// skin, from one bake, with nothing in the settings differing. It was never
    /// present-or-absent; it was twice as wide on one side. And now that the shape fit
    /// grades the cell WITHIN a face, the same band would breathe across a single wall.
    ///
    /// A finish is a physical thickness — `faceSkinMM`, off the wall ring — so the band
    /// is that, floored at two extrusions so it is drawable. y/z/w unused.
    ///
    /// ★ WHY IT HAS TO EXIST. A cell sliced by the outline leaves a sliver, and where
    /// that sliver is thinner than half a cell no strut material lands in it — the
    /// lattice stops short of the outline and the wall reads bare there. Grading finer
    /// closes some of it, but not all: at a 0.4 mm bead nothing below ~2.3 mm prints at
    /// ANY density, so the last fraction of a cell can never be latticed. His rule for
    /// that case is explicit — "get to the point where the lattice is as small as is
    /// printable and fill the rest with solid material".
    ///
    /// ★ APPENDED AT THE END, and both sides move together — `LSDFUniforms` matches
    /// Swift to MSL by BYTE OFFSET, so an inserted field silently reinterprets every
    /// field after it.
    var rimParams: SIMD4<Float> = .zero
    /// ★★★ ORGANIC THICKNESS, APPENDED LAST (2026-09-04): x = a LIVE strut radius in
    /// mm (0 ⇒ the baked thickness, read from the surface channel), y = the centreline
    /// channel's reach, z = the surface channel's band (the outside values), w = the
    /// WETTED JOIN's fillet as a multiple of the strut radius (0 = off). The MSL twin
    /// declares the same slot.
    var organicRadius: SIMD4<Float> = .zero
    /// xy = the STATED density span for the colour ramp, z = 1 when set. Appended
    /// LAST on both sides — see the MSL struct's note.
    var colourSpan: SIMD4<Float> = .zero
    /// xyz = the grade's tint, w = 1 when the shape grade is on above 0 mm. Appended
    /// LAST on both sides.
    var gradeColor: SIMD4<Float> = .zero
    /// ★★★ THE BAND (2026-09-26 redesign; see `LatticeBandTypes`) — FOUR float4s APPENDED
    /// LAST, in this order, on BOTH sides (the MSL twin in `latticeFieldSource`). These match
    /// by BYTE OFFSET; `LatticeBandRenderPlumbingTests.testUniformLayoutRoundTrips` reads
    /// them back through a kernel compiled from the shipping MSL.
    ///   bandOrigin  xyz = the fine rim grid's texel-(0,0,0) centre, w = 1 ⇒ the band is drawn
    ///   bandSpacing x = the fine grid's spacing (mm), w = the capsules' extra embed (mm)
    ///   bandDims    xyz = the fine grid's texel counts
    ///   bandParams  x = veil (1 ⇒ the skin drawn grey over the rim), y = smooth rim normals
    ///               (0 until `rimNormTex` has a producer), z = 1 ⇒ the region texture's `.a`
    ///               is B_r (a band scene; set even when the band is not drawn), w reserved
    /// All zero ⇒ the legacy band path, byte for byte (a scene with no band).
    var bandOrigin: SIMD4<Float> = .zero
    var bandSpacing: SIMD4<Float> = .zero
    var bandDims: SIMD4<Float> = .zero
    var bandParams: SIMD4<Float> = .zero
}

/// ★ A pre-baked organic field — the two channels a cached variant (a beam-lattice
/// 3MF) bakes to through `TopOptKit.organicSpansField`, plus what the banner says.
public struct OrganicBakedFields: Sendable {
    public let distance: LatticeVoxelGrid
    public let surface: LatticeVoxelGrid
    public let reachMM: Double
    public let summary: String
    public let spanCount: Int
    public let lengthMM: Double
    /// ★ The capsules the fields were baked from (2026-09-06) — what the impostor pass
    /// draws. Empty on a caller that only has fields.
    public let capsules: [OrganicCapsule]
    public init(distance: LatticeVoxelGrid, surface: LatticeVoxelGrid, reachMM: Double,
                summary: String, spanCount: Int, lengthMM: Double,
                capsules: [OrganicCapsule] = []) {
        self.distance = distance; self.surface = surface; self.reachMM = reachMM
        self.summary = summary; self.spanCount = spanCount; self.lengthMM = lengthMM
        self.capsules = capsules
    }
}

/// ★★★ ONE ORGANIC STRUT AS THE GPU DRAWS IT (maintainer, 2026-09-06: "switch the
/// previews to GPU capsule impostors"): a sphere-swept segment in model millimetres.
/// The run's emitted spans, the 3MF variants and the span file all reduce to this.
public struct OrganicCapsule: Sendable, Equatable {
    public var a: SIMD3<Float>
    public var b: SIMD3<Float>
    public var r: Float
    public init(a: SIMD3<Float>, b: SIMD3<Float>, r: Float) { self.a = a; self.b = b; self.r = r }
    public init(_ s: (a: SIMD3<Double>, b: SIMD3<Double>, r: Double)) {
        self.init(a: SIMD3<Float>(s.a), b: SIMD3<Float>(s.b), r: Float(s.r))
    }
}

/// ★★★ WHAT THE ORGANIC TRACER NEEDS, bundled so the scene's init does not grow four
/// more arguments for one algorithm.
///
/// ★ THE TENSOR IS THE GATE, and it is the reason organic was called unrenderable for
/// so long. `trace_organic_lattice` eigen-decomposes the per-voxel Cauchy stress —
/// 6 components, Voigt, TRUE shear, MPa — and the preview only ever held the von Mises
/// SCALAR. It turned out the tensor already crosses the bridge for the load-flow
/// overlay (`OptimizeVariant.stressTensorField`), so nothing had to be solved or
/// exported; it only had to be handed over.
public struct LatticeOrganicInput: Sendable {
    /// Grid-indexed, 6 per voxel, in core's Voigt order. Must match `dims`. The solve's
    /// REAL field, handed to core untouched — core synthesises the dead walls itself,
    /// exactly as the run does (ruling C, 2026-09-29). `var` only for resampling.
    public var tensor: [Double]
    public var dims: (Int, Int, Int)
    public var originMM: SIMD3<Double>
    public var spacingMM: Double
    /// The printer's bead. 0 is core's UNSET refusal — printability is user input.
    public let minExtrudableWidthMM: Double
    /// Model-space build direction, for the overhang cone (disarmed by default).
    public let buildDirection: SIMD3<Double>
    /// The separation window the demand is mapped onto — organic's cell size is an
    /// OUTPUT read off the achieved spacing, so this is the control that drives it.
    public var separationMinMM: Double
    public var separationMaxMM: Double
    public let rhoMin: Double
    public let rhoMax: Double


    /// ★ The user's other organic picks (2026-09-03): an explicit strut diameter
    /// (0 ⇒ core derives it from the band), GROWN with its layer height (false ⇒
    /// traced), and the overhang limit (trace-only; 0 leaves it to core).
    public var strutDiameterMM: Double = 0
    public var grow: Bool = false
    public var layerHeightMM: Double = 0
    /// ★★★ THE TRANSFER TIES — the cross-members that connect the grown pillars
    /// (core `OrganicParams::transfer_ties`, job key `organic_transfer_ties`, and the
    /// swirl that scales how far they wander). Core's own struct default is FALSE and
    /// the run overrides it from the job, so a preview that did not set it drew pillars
    /// with NOTHING across them while the run built the ties — his 2026-09-07 walk:
    /// "There are no horizontal struts whatsoever … half the algorithm isn't running".
    /// Ties are a GROWN-path pass (organic_lattice.cpp: `transfer_ties && !grown`),
    /// so they change nothing on the traced picture.
    public var transferTies: Bool = true
    public var tieSwirl: Double = 1.0
    /// ★★★ PREVIEW-ONLY DEPTH STAGGER (2026-09-08). Deforms core's traced spans so
    /// successive depth layers interleave — a TEST for a proposed tracer change, never
    /// what the run builds. 0 = off; otherwise the cell the stagger is scaled to.
    /// See `OrganicDepthStagger`.
    public var depthStaggerCellMM: Double = 0
    public var overhangAngleDeg: Double = 0
    /// ★ SHAPE FIT (maintainer, 2026-09-03: "otherwise they would look like a cube"):
    /// core's `organic_shape_fit` shrinks the separation toward the walls so the
    /// lattice fits the outline; `shapeFitOnly` drops the stress grading. Mirrored in
    /// `OrganicShapeFit` (core's rule is inline in the CLI; see that file).
    public var shapeFit: Bool = false
    public var shapeFitOnly: Bool = false
    /// ★ The window the JOB carries (`ProjectModel.organicJobWindowMM`) — core's shape fit floors
    /// at its low end when there is one; nil = none (Auto), where it floors at half the spacing.
    public var jobWindowMM: (lo: Double, hi: Double)? = nil
    /// ★ Is a shell written for curve ends to land on? run_job: `outer_finish !=
    /// "skin"`. A BARE lattice (the sample; a part without Covered) has none, so ends
    /// that leave the region are not anchors and the trim cuts them back — the run's
    /// own rule, mirrored so the sample does not draw a crisper face than the run.
    public var anchorAtBoundary: Bool = true
    /// ★ false ⇒ the preview bakes the traced/grown curves, not the emission's
    /// repaired spans (arches, legs, merges). The file always has the repairs; the
    /// banner says which one is shown (maintainer, 2026-09-05).
    public var showRepairs: Bool = true
    /// ★ CORE'S SYNTHETIC STRESS ON UNLOADED WALLS (2026-09-06): per-voxel region id
    /// (0 = none, else the 1-based include region) and the per-region config the job
    /// carries; the bridge calls `synthesize_focal_stress` — the run's own function.
    public var regionIDs: [Int32] = []
    /// ★ THE SEEDING BOOST (2026-09-21), ×1 = core's own tracer. See `LatticeWallThickness`.
    public var seedBoost: Double = 1
    /// The walls offered to core's synthesis. The dead test takes no numbers from here:
    /// the bridge makes the run's own call (0.02 and `kOrganicSyntheticDeadFloorMPa`).
    public var syntheticRegions: [TopOptKit.OrganicSyntheticRegionSpec] = []
    /// ★ THE SOLID RIM (maintainer, 2026-09-06: "Fit to shape means grade to solid at
    /// the edges. Always. And always on the *sides* … creating a solid outline"). The
    /// run's `organic_solid_rim_band` (run_job.cpp) finds the candidates within this
    /// many mm of the region's non-lattice SIDE neighbours (never along the normal),
    /// KEEPS them as tracer candidates and turns them solid only after the trace
    /// (ruling G), so the struts run through the band into the wall. The preview takes
    /// the same number — the job's `organic_solid_rim_mm`, −1 ⇒ the window's low end —
    /// counts the band, keeps it a candidate and draws it solid on top. 0 ⇒ no rim.
    public var solidRimMM: Double = 0
    /// ★ THE GRADE-TO-SHAPE BAND ON THE ORGANIC PATH (his 2026-09-18: "There should be
    /// some kind of gradient - like the thickness of the struts getting thicker and the
    /// cells getting smaller … include the gradient amount in Organic"). Within this
    /// many mm of a face outline the spacing shrinks linearly to the printable floor,
    /// and the per-voxel bead follows the spacing (core's law), so the struts thicken
    /// as the cells close up. 0 ⇒ no grade.
    public var shapeBandMM: Double = 0
    /// The grade's strength across the band (−1…+1) — `LatticeSettings.shapeFitGradeStrength`.
    public var shapeBandStrength: Double = 0

    public init(tensor: [Double], dims: (Int, Int, Int), originMM: SIMD3<Double>,
                spacingMM: Double, minExtrudableWidthMM: Double,
                buildDirection: SIMD3<Double>,
                separationMinMM: Double, separationMaxMM: Double,
                rhoMin: Double, rhoMax: Double,
                strutDiameterMM: Double = 0, grow: Bool = false,
                layerHeightMM: Double = 0, overhangAngleDeg: Double = 0,
                transferTies: Bool = true, tieSwirl: Double = 1.0,
                shapeFit: Bool = false, shapeFitOnly: Bool = false,
                anchorAtBoundary: Bool = true, showRepairs: Bool = true) {
        self.tensor = tensor; self.dims = dims; self.originMM = originMM
        self.spacingMM = spacingMM; self.minExtrudableWidthMM = minExtrudableWidthMM
        self.buildDirection = buildDirection
        self.separationMinMM = separationMinMM; self.separationMaxMM = separationMaxMM
        self.rhoMin = rhoMin; self.rhoMax = rhoMax
        self.strutDiameterMM = strutDiameterMM; self.grow = grow
        self.layerHeightMM = layerHeightMM; self.overhangAngleDeg = overhangAngleDeg
        self.transferTies = transferTies; self.tieSwirl = tieSwirl
        self.shapeFit = shapeFit; self.shapeFitOnly = shapeFitOnly
        self.anchorAtBoundary = anchorAtBoundary
        self.showRepairs = showRepairs
    }
}

/// The immutable per-part scene the preview needs. Baking depends ONLY on the mesh
/// (occupancy) and the field (demand) — never on the interactive params — so it is
/// built once on a data change (bar P2 / V3).
public struct LatticeSDFScene {
    /// ★ The demand the struts are DRAWN at — `demand` held under the aesthetic ceiling
    /// (see the init). Planners read `demand`; the cell texture's activation reads this.
    public let drawnDemand: LatticeVoxelGrid?
    /// The density band `drawnDemand` was capped against (the init's `rhoMin`/`rhoMax`).
    public let drawnBand: (lo: Double, hi: Double)
    /// ★ Per region (index-aligned to `regions`; 0 for a non-include), the 90th-percentile
    /// density its lattice is drawn at — `drawnBand.lo + (hi − lo)·drawnDemand^γ` over the
    /// region's own voxels. The per-region cell rule reads it: where a tenth of the wall is drawn
    /// at the octet's non-quilt ceiling (his 2026-09-28 "make the cells smaller"), the wall takes
    /// one more cell across. (The median read 0.143 on his face 2 while every wall voxel he
    /// tapped read 0.19–0.20 — the load sits in part of the wall, and that part is the quilt.)
    public var regionDrawnDensityP90: [Double] = []
    /// The octet's aesthetic density ceiling this scene drew against, and whether Allow quilt
    /// lifted it — what the cell rule compares the medians with.
    public var drawnCeilingRho: Double = 1
    public let allowQuilt: Bool
    /// The demand (0…1, in the shader's `rho = lo + (hi − lo)·demand^gamma` law) at which
    /// the drawn density reaches `ceilingRho`. 1 when the ceiling is at or above the band's
    /// top (nothing to cap); 0 when the ceiling is at or below the floor.
    public static func aestheticDemandCap(rhoMin: Double, rhoMax: Double, gamma: Double,
                                          ceilingRho: Double) -> Double {
        guard rhoMax > rhoMin, ceilingRho < rhoMax else { return 1 }
        guard ceilingRho > rhoMin else { return 0 }
        let t = (ceilingRho - rhoMin) / (rhoMax - rhoMin)
        return gamma > 0 ? pow(t, 1.0 / gamma) : t
    }
    /// nil when the topology id has no strut table (item a): the march draws no segments.
    public var preview: LatticeSDFPreview?
    public var occupancy: LatticeVoxelGrid
    /// Truncated signed distance of the part (mm, negative inside) — the flush
    /// boundary trim (round 3). Exact near the surface, so flat faces render straight.
    public var partSDF: LatticeVoxelGrid
    /// ★ The same distances signed by the WHOLE part's occupancy (negative wherever the
    /// part has material, slab or no slab) — what a measurer reads. `partSDF` stays the
    /// latticed volume for the march.
    public var partMaterialSDF: LatticeVoxelGrid
    public var demand: LatticeVoxelGrid?
    /// ★ THE MEASURED STRESS, NORMALISED — the FEA field the stage ran, kept apart
    /// from `demand` because a stated per-region density may overwrite `demand` and
    /// must never be mistaken for a load reading. nil ⇒ no solve to read.
    public var stressDemand: LatticeVoxelGrid?
    /// True iff a measured field reached this scene. Sub-floor retention requires it.
    public var demandIsMeasuredStress: Bool = false
    /// ★ CORE'S LOCAL MEMBER THICKNESS (mm) per occupancy voxel, and core's N*.
    /// Empty / 0 when core had no answer, which disables the floor rather than
    /// guessing at one. See `LatticeMemberFloorTests` for why the preview needs it:
    /// the run leaves a member too thin to hold N* cells SOLID, and the preview used
    /// to draw lattice there regardless.
    public var memberThicknessMM: [Double] = []
    public var minCellsPerMember: Double = 0
    /// ★★★ THE MODE HE CHOSE ON ENTERING THE STAGE, and it is not decoration: it picks
    /// the denominator core grades by AND the floor below. See `LatticeStageMode`.
    public var stageMode: LatticeStageMode = .structural
    /// ★★ THE ALGORITHM THE RUN WILL USE, in core's own name. "" is "not stated",
    /// which core resolves to doubled — the one the marcher can actually draw.
    public var algorithm: String = ""
    /// ★★ CORE'S AESTHETIC FLOOR PER OCCUPANCY VOXEL — empty on the structural path,
    /// which is every existing caller. Non-empty only when the mode is aesthetic AND a
    /// measured field and a positive allowable both reached the bake, because the floor
    /// is a function of the voxel's utilisation and there is no utilisation without
    /// both. Absence of measurement is not permission to relax: with no field the array
    /// stays empty and every voxel falls back to `minCellsPerMember`, the accuracy
    /// floor.
    public var cellsPerMemberFloorPerVoxel: [Double] = []
    public var bounds: MeshBounds
    /// The part mesh the scene was baked from (COW — shares storage with the viewer's
    /// copy). Kept so face-role tints can be re-baked onto the lattice whenever the
    /// selection changes WITHOUT rebuilding the whole scene (bar A4).
    public var mesh: ViewerMesh
    /// ★ §5(b): voxels of the part's own interior. Zero means the solid voxelisation
    /// found nothing to fill, and the overlay says so instead of showing a label over
    /// an empty viewport.
    public let interiorVoxelCount: Int
    /// ★ THE DECLARATIONS THIS SCENE WAS MASKED BY — kept so the SHELL can be cut
    /// by the same list, from the same bake. Re-reading the project at draw time
    /// would let the hole and the struts drift apart for a frame; reading them off
    /// the scene means they are the same list by construction.
    public let regions: [LatticeRegionSpec]
    /// ★★ THE DECLARED REGIONS AS A DISTANCE FIELD (mm, negative inside), on the
    /// occupancy's own grid. This is what makes "only the face's area" true for a
    /// face of ANY shape: the region is no longer a rectangle the shader can
    /// evaluate in closed form, it is the face's real outline extruded to depth,
    /// so it is baked once here and sampled by everything that needs it.
    ///
    /// ★ ONE FIELD, TWO READERS. The march intersects it (struts stop at the
    /// region) and the shell's fragment discards inside it (the hole). Sampling
    /// the SAME texture is what stops the hole and the struts describing
    /// different volumes — a distance field interpolates, so the boundary is
    /// smooth between voxels rather than stepped, exactly as `partSDF` already
    /// relies on for the part's own flat faces.
    ///
    /// EMPTY (`nil`) when no include region is declared: the clip is then inert,
    /// which is the settings page's sample block.
    public let regionSDF: LatticeVoxelGrid?
    /// In-plane distance in from the nearest face outline, per voxel (mm; < 0
    /// outside, 1e3 where no face region holds the voxel). The `g` channel of the
    /// region texture; the shader's solid outline reads it.
    public let outlineSDF: LatticeVoxelGrid?
    /// The region prism's own signed distance, WITHOUT the part or skin terms —
    /// the solid outline is clipped by this (its lateral wall IS the face outline),
    /// never by the voxel-eroded part clip that swallowed it.
    public let prismSDF: LatticeVoxelGrid?
    /// The finish's own thickness (mm) — `LatticeBoundaryTreatment.faceSkinMM`. Stored
    /// because the DRESSING BAND must be a physical width, not a fraction of whatever
    /// cell happens to be local. See `rimParams`.
    public let skinMM: Double
    /// ★ THE WHOLE PART'S OCCUPANCY, UNCLIPPED (2026-09-18): `occupancy` and `partSDF`
    /// are the LATTICED volume — the solid clipped to the regions — so beyond a
    /// region's cap they read "outside" even inside solid material. The cap wall has to
    /// ask the part itself whether material continues, and this is the part itself.
    public let solidOccupancy: LatticeVoxelGrid
    /// ★ under every UNSELECTED face (2026-09-23): the model's thin SKIN, then the RIM the
    /// lattice thickens into ("the rim is below the solid"), both in mm
    public var unselectedSkinMM: Double = 0
    public var unselectedRimMM: Double = 0
    /// + beyond the skin's inner face, − inside the skin, 1e3 where no unselected face is
    /// near — the lattice layer draws the rim where this is ≥ 0 and the region is solid
    public var skinInSDF: LatticeVoxelGrid? = nil
    /// ★★★ THE BAND (2026-09-26 redesign; nil ⇒ the legacy band path). See `LatticeBandTypes`.
    /// `bandFine` is the rim's own padded half-voxel grid; `bandRimCoarse` is B_r on the SDF
    /// grid (the region texture's `.a` in band mode — the shell's rule reads it);
    /// `bandOptions` are the switches the scene was built with.
    public var bandFine: LatticeBandFine? = nil
    public var bandRimCoarse: LatticeVoxelGrid? = nil
    public var bandOptions = LatticeBandOptions()
    /// ★ Every choice the band made that the user may override (chips in lattice-only view);
    /// empty on the legacy path. See `LatticeBandDecision`.
    public var bandDecisions: [LatticeBandDecision] = []
    /// The band's rim and solid-backed side rim (mm); 0 on the legacy path.
    public var bandRimMM: Double = 0
    public var bandSideRimMM: Double = 0
    /// ★ The part's material inside every declared prism, IGNORING the slabs — the grid
    /// the measurers read (`LatticeRegionMask.clippedWholePrism`). `occupancy` is the
    /// slab-clipped set where lattice may go.
    public let prismOccupancy: LatticeVoxelGrid
    /// The organic solid rim's width (mm) when the algorithm is organic and a rim is
    /// on — the outline ribbon's width on that path. 0 otherwise.
    public let organicSolidRimMM: Double
    /// Organic's own "Fit to shape" (the spacing tightens toward the boundary) — the
    /// grade-to-shape tint's switch on the organic path.
    public let organicShapeFit: Bool

    /// ★★★ ORGANIC: the traced struts as a distance field (mm, negative inside), on the
    /// DECLARED REGION's own bbox rather than the part's — which is what makes it
    /// viable, because the voxel is then a fraction of the design grid's and a 1-3 mm
    /// strut is several voxels across instead of sub-voxel. nil on every other
    /// algorithm. Clamped at `organicBandMM`, an UNDER-estimate and therefore safe to
    /// sphere-trace against.
    /// ★ How far past the thickest baked strut the centreline field stays exact — the
    /// live Thicker radius may grow to 90 % of (this + the baked radius) before a rebake
    /// is needed. 1 mm ⇒ live widths up to ≈ 2.2 mm on a 0.42 mm bead.
    public static let organicBakeHeadroomMM = 1.0
    public let organicField: LatticeVoxelGrid?
    /// ★ The SURFACE distance per organic voxel (2026-09-04, topology/thickness split).
    /// `organicField` is now the CENTRELINE distance; at the baked thickness the march
    /// reads this channel, and under the live radius the Thicker slider sets it reads
    /// centreline − radius — so thickness never re-bakes.
    public let organicSurfaceField: LatticeVoxelGrid?
    /// ★ The emitted spans the trace path baked (nil on the cached and run-spans
    /// paths) — what the variant cache stores as a beam-lattice 3MF.
    public let organicEmittedSpans: [(a: SIMD3<Double>, b: SIMD3<Double>, r: Double)]?
    /// ★★★ THE CAPSULES THE IMPOSTOR PASS DRAWS (2026-09-06) — every organic source
    /// (pre-baked variant, span file, cached 3MF, live trace) fills this; the field is
    /// still baked for the probes, but when the host's capsule pipeline exists the
    /// march leaves organic alone and these are drawn instead. Empty ⇒ not organic.
    public let organicCapsules: [OrganicCapsule]
    /// ★ WHY organic was NOT drawn, when it was asked for and `organicField` is nil —
    /// the banner prints it (maintainer, 2026-09-05: a silent ladder under an organic
    /// name looked like "not implemented"). nil when organic was drawn or not asked.
    public let organicNotDrawnReason: String?
    /// ★ Wall-clock seconds of the three bridge phases (trace, core emission, stamp)
    /// for a preview that was traced here; nil for a cached or run-supplied one.
    public let organicPhaseSeconds: (trace: Double, emit: Double, bake: Double)?
    /// ★ Core's synthetic-stress report for this bake (nil when no wall asked).
    public let organicSyntheticReport: TopOptKit.OrganicSyntheticReport?
    /// ★ WHAT THE FIELD WAS BAKED FROM when it came from a span file: (count, total
    /// length mm) — the numbers to hold against the run's receipt (§10). nil when the
    /// field was traced at preview time or there is no organic field.
    public let organicSpanSource: (count: Int, lengthMM: Double)?
    /// ★★★ THE §10 VERDICT — nil when the indexed spans match the run's receipt (or
    /// there was nothing to check); otherwise a sentence naming the mismatch. A preview
    /// that draws a different object from the one certified is the failure this whole
    /// chain exists to prevent, so the label carries it in capitals.
    public let organicReceiptMismatch: String?
    /// The run's own contiguity receipt, one line, judged by nobody (addendum
    /// 2026-09-03): length survival · pieces (largest %) · joins refused.
    public let organicReceiptSummary: String?
    public let organicBandMM: Double
    /// What the trace reported, for the banner: curves, connectors and the separation it
    /// actually ACHIEVED (organic's cell size is an output, not an input).
    public let organicSummary: String

    /// ★★ THE STRESS COLOURS, AS A VOLUME (maintainer, 2026-08-18: "Allow the
    /// stress map to *overlay* on the lattice if it is turned on simultaneously. I
    /// want to be able to see the stress map and compare the changes in the
    /// lattices themselves").
    ///
    /// ★ AN OVERLAY, NOT A REPLACEMENT. With both views up the struts keep their
    /// geometry and take the stress plot's colour, so the two can be read against
    /// each other — which is the whole request. Baked from the SAME demand field
    /// the radii are graded from and through `LatticeStressTint.colour`, the same
    /// ramp the shell's plot and the legend use, so a strut and the wall behind it
    /// report the same stress in the same colour.
    ///
    /// nil when there is no field — the preview then keeps the density ramp.
    public let stressRGB: [UInt8]?
    /// ★ The part's OWN interior, before the region mask — so "no inside at all"
    /// and "the regions matched nothing" stay distinguishable.
    public let partInteriorVoxelCount: Int
    /// ★ Faces the emission could not turn into a region (no usable B-rep
    /// geometry). Non-zero means the preview draws LESS than the user marked.
    public let skippedFaces: Int
    /// ★ RULING (g): face regions (by name) the emission could not use — a cut sector.
    public let skippedRegionNames: [String]

    /// ★ `regions` CLIPS THE PREVIEW TO WHAT IS ACTUALLY SET TO LATTICE
    /// (maintainer, 2026-08-17: "Can you confirm that the preview will only show
    /// what is *actually* set to lattice"). It was NOT: occupancy came from the
    /// whole part mesh and no region reached this path at all, so the struts
    /// filled the entire interior regardless of the declarations. Empty ⇒ no
    /// clipping, which is what the settings page's sample block needs.
    public init(mesh: ViewerMesh, field: StressField?, latticeID: String,
                // ★★★ THE RUN'S EMITTED SPANS (2026-09-02). When present and the
                // algorithm is organic, the organic field is BAKED from them — the
                // post-prune object the run certified — instead of traced at preview
                // time. nil keeps every existing call site and picture unchanged.
                organicSpans: OrganicSpanIndex? = nil,
                // ★ THE RUN'S OWN RECEIPT for those spans. When both are here the scene
                // computes the §10 cross-check itself — count and total length of what
                // it indexed against what the run says it emitted — and carries the
                // verdict in `organicReceiptMismatch` for the preview label to shout.
                organicReceipt: OrganicRunReceipt? = nil,
                // ★★ THE MEASURED FIELD, SEPARATELY FROM THE GRADING ONE (maintainer,
                // 2026-08-20: "the FEA we run to get the stress map needs to be enough
                // to say 'This is an unloaded wall'"). `field` may be withheld by the
                // density mode; this one is present whenever a solve exists, because
                // "is this wall loaded" is not a question the density mode gets to
                // answer. Defaults to `field` so every existing call is unchanged.
                stressField: StressField? = nil,
                // ★★ WHETHER A PER-REGION DENSITY MAY OUTRANK THE FIELD, and it must
                // NOT in Sim mode (maintainer, 2026-08-20: "That 17% and 25% was
                // automatically input, I never typed it").
                //
                // ★ THE OVERRIDE WAS WRITTEN FOR A NUMBER THE USER STATED — "it is
                // the user's own number for that region". But nothing distinguishes a
                // density HE typed from one the app DERIVED and wrote back onto the
                // region, and on his part the derived 17% and 25% were silently
                // replacing the sim field for the whole preview. In Sim mode the
                // solve governs; the stated-density path is for the modes where he
                // actually states one.
                statedDensityGoverns: Bool = true,
                /// ★ Allow quilt (octet): stated per-region densities may pass the
                /// aesthetic ceiling. Simulated/automatic densities never do.
                allowQuilt: Bool = false,
                // ★★★ STRUCTURAL OR AESTHETIC (maintainer, 2026-08-21). Defaults to
                // structural so every pre-existing call — and every test — keeps the
                // certified floor it was written against.
                // ★ THE FOURTH REPORT OF THE CHAMFER used to be answered here, by a
                // `keepWallMM` that eroded the region away from every surface but the
                // declared face. It is GONE — see the bake below for why it was the
                // wrong instrument and where the rule actually lives now.
                stageMode: LatticeStageMode = .structural,
                // ★ Core's `LatticeAlgorithm` name. Defaults to "" so every existing
                // call — and every test — still describes a doubled ladder, which is
                // the picture the marcher draws.
                algorithm: String = "",
                // ★ The material's allowable (MPa), needed ONLY to turn the measured
                // field into a utilisation for the aesthetic floor. 0 means "not
                // supplied", and then the aesthetic floor is not computed at all rather
                // than computed from a guess.
                allowableMPa: Double = 0,
                // ★★★ "MINIMIZE PLASTIC", AND UNTIL NOW IT REACHED NOTHING HERE
                // (maintainer, 2026-08-22: "the struts are huge, but they SHOULDN'T be
                // - I have minimize_plastic=on"). He was right: the flag went to the
                // OPTIMIZER's objective and to the cell-plan helper, and had no path to
                // the lattice's density at all. See `demand` below for what it now does
                // and why it is not `utilisationTarget`.
                minimizePlastic: Bool = false,
                // ★★ WHETHER A BOUNDARY FINISH IS WRITTEN. Core's aesthetic floor may
                // reach ONE cell only with one — a one-cell-wide member severs struts
                // and the finish is what re-ties them. Defaults false, which is core's
                // floor of 2, so an untouched caller is unchanged.
                boundaryFinishWritten: Bool = false,
                // ★★★ ORGANIC's inputs. nil ⇒ not an organic job and nothing is traced,
                // which is every other caller.
                organic: LatticeOrganicInput? = nil,
                // ★ SAMPLE-ONLY bake voxel (maintainer, 2026-09-03): the wizard's
                // organic sample bakes at ≤ r_min/2 so bead-width struts read as beams,
                // not ribbons. nil keeps the part preview's own rule (the maintainer
                // wants the part preview realistic by another route, not this floor).
                organicBakeVoxelMM: Double? = nil,
                // ★ A PRE-BAKED organic field (2026-09-04): a cached variant's spans,
                // baked through the bridge into the two channels. When present the scene
                // neither traces nor emits — the topology is the file's; only thickness
                // is live.
                organicBaked: OrganicBakedFields? = nil,
                // ★ A cached topology DOCUMENT (a beam-lattice 3MF) with a source label:
                // baked on the trace path's own grid instead of tracing (2026-09-04).
                organicCached: (doc: OrganicBeamLattice3MF.Document, sourceLabel: String)? = nil,
                maxDim: Int = 128, regions: [LatticeRegionSpec] = [],
                // ★ The band and gamma the raymarcher grades with, so a stated
                // per-region density can be inverted into the demand value that
                // comes back out as exactly that density (maintainer,
                // 2026-08-17). Defaults leave every existing call unchanged.
                rhoMin: Double = 0, rhoMax: Double = 1, gamma: Double = 1,
                // ★ WHAT AN EMPTY REGION LIST MEANS HERE — see
                // `LatticeRegionMask.EmptyRegionPolicy`. The default is the
                // sample block's answer, so every pre-existing call is
                // unchanged; the STAGE passes `.latticeNothing`.
                whenEmpty: LatticeRegionMask.EmptyRegionPolicy = .latticeEverything,
                // ★ FACES THE EMISSION COULD NOT USE (bar 4 of the preview-regions
                // task). Once the preview masks to regions, a skipped face means it
                // draws LESS than the user marked — and doing that silently is the
                // failure this parameter exists to prevent.
                // ★★ THE SOLID SKIN THE FINISH SETTING ASKS FOR (maintainer,
                // 2026-08-19: "why you can't make the *shell* thickness of all 3d
                // models thicker than the single pixel it seems to be? Thats why
                // the lattice is peeking through - the walls of shell are
                // impossibly thin").
                //
                // ★ HE WAS RIGHT, AND THE WALL IS NOT THIN — IT IS GONE. Measured
                // on his own part: the plate under face 15 is 9.75 mm thick and he
                // declared an 11.0 mm slab. The region is DEEPER THAN THE WALL, so
                // the lattice runs clean through and out the far side, leaving no
                // solid material anywhere in that plate. What remains is the
                // mesh's zero-thickness surface — exactly the "single pixel" he
                // described. Struts then sit coincident with that surface on BOTH
                // sides, which is where the speckle and the see-through come from.
                //
                // ★ AND HIS FINISH IS ALREADY "SKIN". `LatticeBoundaryTreatment`
                // has said `fullSkin` the whole time; the preview simply never
                // read it (`boundary` reached neither `LatticeProxyParams` nor any
                // shader). So the honest fix is not to fake thicker geometry — it
                // is to draw the skin he already asked for, at the wall thickness
                // his print parameters actually produce.
                //
                // 0 ⇒ no skin, which is `none`/`rim` and every pre-existing call.
                skinMM: Double = 0,
                skippedFaces: Int = 0,
                skippedRegionNames: [String] = [],
                // ★ one cell, in mm — the slab's floor (see `LatticeWallThickness`)
                wallThicknessFloorMM: Double = 0,
                // ★ per wall (selectable key), the depths its cells can be packed to (D1)
                wallDepthSteps: [String: [Double]] = [:],
                // ★ the wall-depth sim rule's OWN field (review #31): the grading's `field`
                // is nil under "No grade"/"Grade to fit", which silently turned "By sim"
                // into the whole range. nil ⇒ `field`.
                wallStressField: StressField? = nil,
                // ★ the user's per-face / per-cap band choices ([key: solid]; see
                // `LatticeBandDecision`) — empty ⇒ every choice is the rules' default
                bandOverrides: [String: Bool] = [:],
                // ★★ THE OCTET TAKES THE CONTINUOUS BAND TOO (his 2026-09-28: the octet's blue rims
                // "a lot wrong … which also does not have the chips"). Opt-in, so fixtures that build
                // an octet scene keep the legacy block; the app passes it for every octet algorithm.
                // `bandGradeMM` is the octet's grade band (his shape-fit band; 0 ⇒ 10 mm).
                octetBand: Bool = false,
                bandGradeMM: Double = 0,
                // ★ the PRINTER'S bead (mm), for the skin under unselected faces; 0 ⇒ the
                // organic settings' bead, else 0.45
                beadMM: Double = 0) {
        self.preview = LatticeSDFPreview(latticeID: latticeID)
        // ★★ THE SLAB, BUILT FIRST (2026-09-21): every reader below — the region field,
        // the organic candidates, the octree, the cap wall — reads `regions`, so the
        // thickness maps are attached before any of them run. `field` is the solve's
        // von Mises, the sim rule's input.
        let regions = LatticeWallThicknessBuilder.attach(
            regions, field: wallStressField ?? field,
            floorMM: wallThicknessFloorMM > 0 ? wallThicknessFloorMM
                : Double((mesh.bounds.max - mesh.bounds.min).max()) / Double(max(1, maxDim)),
            depthStepsFor: { r in r.selectableKey.flatMap { wallDepthSteps[$0] } })
        if regions.contains(where: { $0.thicknessMap != nil }) {
            NSLog("DIAG wall thickness: %@", regions.enumerated().compactMap { i, r -> String? in
                guard let m = r.thicknessMap, let spec = r.thickness else { return nil }
                let q = m.summary
                let mode = spec.depthBySim ? "depthBySim" : spec.density.rawValue
                return String(format: "r%d %@ start %.2f mm · thickness p05 %.2f p50 %.2f p95 %.2f of %.2f mm (floor %.2f)",
                              i, mode, m.startMM, q.p05, q.p50, q.p95, r.depthMM, wallThicknessFloorMM)
            }.joined(separator: " | "))
        }
        // ★★ THE PART'S INTERIOR AND THE LATTICED INTERIOR ARE TWO DIFFERENT
        // NUMBERS, and the banner needs both to tell the truth.
        //
        // ★ THE SOLID RIM, IN-PLANE (2026-09-06): an organic scene erodes each include
        // face region by the rim before anything is baked from it — the hole in the
        // shell, the occupancy the tracer is handed, the region field the march and the
        // capsules clip against. Depth is untouched (the run's rule: never along the
        // normal). Manual primitives and bolts carry no outline and are left alone.
        // ★★★ THE EROSION IS A DRAWING DECISION, NOT A MEMBERSHIP ONE (2026-09-08).
        // It used to replace `regions` outright, so the OCCUPANCY was clipped by the
        // eroded shape too — and the candidate loop asks the occupancy whether there is
        // material at a voxel. That quietly took the band's outermost ring out of the
        // candidate set even after the explicit deletion was removed, which is the same
        // gap by another route (measured: 3149 capsules without a rim, 2353 with).
        // `regions` stays whole; `wallRegions` is the eroded copy, and only the region
        // FIELD — the thing the shell and the march clip against — reads it.
        // ★★★ NO IN-PLANE EROSION ANY MORE (2026-09-23): the organic rim used to be an
        // erosion of every region's outline by `solidRimMM`, blind to what lay beyond the
        // outline — air past a grown edge, another prism at a seam, the part's solid. The
        // rim is now one rule for every algorithm, applied per voxel in the loop below:
        // skin then rim under every unselected face the lattice runs alongside, and rim
        // along the outline wherever the part's solid backs it. Nothing is eroded.
        let wallRegions: [LatticeRegionSpec] = regions
        // ★ "No inside to fill" and "your regions matched nothing" are different
        // findings with different fixes — one is a broken import, the other is a
        // depth set too shallow. Counting only the MASKED grid would report the
        // first for both, which is a confident wrong answer.
        // ★★★ A CLOCK ON THE SCENE ITSELF (his walk, 2026-09-07: "took ~30 seconds for
        // the first image"). The bridge's own phase clock accounted for 0.7 s of a 9.5 s
        // sample bake — every other second is Swift-side scene work, and until this
        // there was no number saying which part. Four spans: the mesh's occupancy and
        // signed distance, the region field, the organic trace, and everything else.
        let sceneT0 = Date()
        var tOccupancy = 0.0, tRegionField = 0.0, tOrganic = 0.0
        var outlineForOrganic: LatticeVoxelGrid? = nil     // the in-plane outline distance, for the band grade
        let solid = LatticePreviewOccupancy.occupancy(
            positions: mesh.positions, indices: mesh.indices,
            bounds: mesh.bounds, maxDim: maxDim)
        var solidInside = 0
        for v in solid.values where v > 0.5 { solidInside += 1 }
        self.partInteriorVoxelCount = solidInside
        self.skippedFaces = skippedFaces
        self.skippedRegionNames = skippedRegionNames
        self.skinMM = skinMM
        self.solidOccupancy = solid
        self.organicSolidRimMM = (algorithm == "organic" && (organic?.solidRimMM ?? 0) > 0) ? organic!.solidRimMM : 0
        self.organicShapeFit = algorithm == "organic" && (organic?.shapeFit ?? false)
        self.regions = regions
        self.occupancy = LatticeRegionMask.clipped(
            solid, to: regions, whenEmpty: whenEmpty)
        self.prismOccupancy = regions.contains(where: { $0.thicknessMap != nil })
            ? LatticeRegionMask.clippedWholePrism(solid, to: regions, whenEmpty: whenEmpty)
            : occupancy
        // ★★★ THE BAND, REBUILT (2026-09-26): organic with a declared face region takes the
        // continuous, geometrically signed band (`LatticeBandFields`); every other path, and
        // `LATTICE_BAND_OFF=1`, keeps the legacy block below byte for byte.
        let bandOpts = LatticeBandOptions.fromEnvironment()
        let isOrganicScene = algorithm == "organic"
        let bandActive = (isOrganicScene || octetBand) && !bandOpts.off
            && regions.contains(where: { $0.role == .include && $0.kind == .face && $0.isValid })
        let bandRes: LatticeBandFields.Result? = bandActive ? {
            let voxelHere = Double(Swift.max(solid.spacing.x, Swift.max(solid.spacing.y, solid.spacing.z)))
            let skin = LatticeSDFRenderer.outlineBeamMM(lineWidthMM: beadMM > 0 ? beadMM : (organic?.minExtrudableWidthMM ?? 0.45), voxelMM: voxelHere)
            let organicRim = (organic?.solidRimMM ?? 0) > 0 ? organic!.solidRimMM : 0
            // ★ the octet keeps its legacy rim (skin 1.21 + rim 1.21 on his stand) and its
            // solid-backed outline rim (`outlineRim` = the skin); organic its solid rim
            let rim = isOrganicScene ? Swift.max(skin, organicRim) : skin
            let sideRim = isOrganicScene ? organicRim : skin
            let selectedRaw = Set(regions.compactMap { r -> Int? in
                guard r.role == .include, r.kind == .face else { return nil }
                return r.rawFaceID.map { Int($0) } ?? r.faceID
            })
            let band = isOrganicScene ? ((organic?.shapeBandMM ?? 0) > 0 ? organic!.shapeBandMM : 10)
                : (bandGradeMM > 0 ? bandGradeMM : 10)
            return LatticeBandFields.build(mesh: mesh, regions: regions, selectedRaw: selectedRaw, solid: solid,
                                           params: .init(skinMM: skin, rimMM: rim, sideRimMM: sideRim,
                                                         gradeBandMM: band, finishSkinMM: skinMM, options: bandOpts,
                                                         overrides: bandOverrides))
        }() : nil
        // ★ the octet keeps the legacy part fields: the per-region cells (and so the run's
        // stepped cells) are measured on `partMaterialSDF`, and the band's rim reads its own
        // material distance from the fine grid anyway
        let latticedSDF = (isOrganicScene ? bandRes?.latticedC : nil) ?? LatticePreviewOccupancy.signedDistance(
            positions: mesh.positions, indices: mesh.indices, like: occupancy)
        self.partSDF = latticedSDF
        // ★★★ THE PART'S MATERIAL, SIGNED BY THE WHOLE SOLID (2026-09-23): `partSDF` takes
        // its sign from the slab-clipped occupancy — it is the LATTICED volume, which the
        // march wants — so every measurer that asked it "is the part here" read a slab
        // edge as the end of the material (his 10.31 mm wall walk). Same distances, the
        // part's own sign.
        self.partMaterialSDF = (isOrganicScene ? bandRes?.materialC : nil) ?? {
            var m = latticedSDF
            for i in m.values.indices {
                let d = abs(m.values[i])
                m.values[i] = solid.values[i] > 0.5 ? -d : d
            }
            return m
        }()
        tOccupancy = Date().timeIntervalSince(sceneT0)


        // ★ Baked from the SAME list the occupancy was masked by, on the same
        // grid, in the same pass — so no third description of "the region" can
        // exist to drift from the other two.
        if let band = bandRes {
            // ★★★ THE BAND'S FIELDS, published under the old names with their old meanings:
            // regionSDF = carved (solid ≥ 0), outlineSDF = the grade distance past the rim's
            // inner face, prismSDF = the pocket, skinInSDF = ≥ 0 beyond the skin's inner face.
            self.regionSDF = band.carvedC
            self.outlineSDF = band.gradeC
            outlineForOrganic = band.gradeC
            self.prismSDF = band.qC
            self.skinInSDF = band.skinC
            self.bandFine = band.fine
            self.bandRimCoarse = band.rimC
            self.bandOptions = bandOpts
            self.bandDecisions = band.decisions
            self.bandRimMM = band.rimMM
            self.bandSideRimMM = band.sideRimMM
            let voxelHere = Double(Swift.max(solid.spacing.x, Swift.max(solid.spacing.y, solid.spacing.z)))
            self.unselectedSkinMM = LatticeSDFRenderer.outlineBeamMM(lineWidthMM: beadMM > 0 ? beadMM : (organic?.minExtrudableWidthMM ?? 0.45), voxelMM: voxelHere)
            self.unselectedRimMM = Swift.max(self.unselectedSkinMM, self.organicSolidRimMM)
            NSLog("%@", band.diag)
        } else if LatticeJobIncludeGate.hasIncludeWall(regions) {
            // ★★★ THE REGION IS THE FACE — NOT THE FACE PLUS A MARGIN (maintainer,
            // 2026-08-21: the primitive is "ONLY AS BIG AS THE FACE … Never bigger.
            // Never smaller.").
            //
            // ★ TWO MARGINS USED TO BE ADDED HERE AND BOTH ARE GONE.
            //
            //   1. A 1.5-VOXEL PAD ON THE SLAB'S FRONT FACE. A face region starts ON
            //      the face, so the field's zero crossing was coincident with the
            //      shell's own triangles and a SAMPLED field cannot say which side a
            //      fragment is on — a per-pixel coin flip, which is the speckle. The
            //      pad broke the coincidence by making the region 1.5 voxels (2.6 mm
            //      on his part) BIGGER than the face he declared. But the coincidence
            //      is a SAMPLING problem, not a geometry one: the shell now steps one
            //      voxel along the face normal before it samples (`shellClipMSL`),
            //      which resolves the same ambiguity without moving the region.
            //
            //   2. `keepWallMM`, WHICH ERODED THE REGION AWAY FROM EVERY OTHER
            //      SURFACE. It was aimed at the chamfer he keeps reporting, and it is
            //      the wrong instrument twice over: it makes the region SMALLER than
            //      the face, and it never worked — armed at his own wall it reclaimed
            //      6,149 voxels and he still saw the chamfer eaten, because the
            //      chamfer was never being eaten by the REGION. It was being eaten by
            //      the SHELL, which discarded any fragment inside the prism no matter
            //      which way it faced. That is fixed where it lives, in the fragment.
            //
            // What remains is the region itself, and the finish's skin.
            let partMaterialValues = self.partMaterialSDF.values      // ★ the finish skin pulls back from the part's SURFACE, never a slab edge
            // ★★★ UNSELECTED FACES KEEP THEIR SKIN (his 2026-09-23 00:58, image 1: "since
            // faces are selectable, they should be excluded from the lattices unless they
            // have been selected … the curved face should be consistently thick"; on the
            // rim: "the solid holding the lattice to the solid model … never visible from
            // the outside … always in the shape of the model"). Under every CAD face that
            // is NOT a selected face the part keeps a solid skin one rim thick, so no
            // prism ever opens the model through a face nobody chose. That skin IS the
            // rim, in the model's own shape — the outline beam mesh is retired.
            let selectedRaw = Set(wallRegions.compactMap { r -> Int? in
                guard r.role == .include, r.kind == .face else { return nil }
                return r.rawFaceID.map { Int($0) } ?? r.faceID
            })
            // ★★★ HIS ADDENDUM (2026-09-23 02:44): "the opposite side of the face selected, if
            // the face-prism passes through it, gets latticed through — one face-prism,
            // crossing through the face, is enough". So an unselected face is skinned only
            // where the lattice runs ALONGSIDE it (the top of the leg, the base's bottom, the
            // inner curve looking up); a face the prism passes THROUGH (its normal within
            // 60° of the prism's — the flange's inner face, the channel floor, the cavity
            // wall 3 mm behind face 23 that painted his "patch") is OPEN. A face no prism
            // reaches gets nothing either — the lattice never meets it.
            let includeFaceRegions = wallRegions.filter { $0.role == .include && $0.kind == .face && $0.isValid }
            // ★★★ 30°, NOT 60° (his 2026-09-23 15:00, image 3: the 45° chamfer was
            // "CONSISTENTLY removed — it is another face", alongside the prism, and it keeps
            // its skin). Passed THROUGH = the face's normal within ~30° of the prism's
            // direction AND the prism reaching the face; a 45° chamfer is alongside.
            let acrossCos = cos(30.0 * Double.pi / 180)
            var unselIdx: [UInt32] = []
            unselIdx.reserveCapacity(mesh.indices.count)
            var acrossTris = 0, besideTris = 0
            var besideTri = [Bool](repeating: false, count: mesh.indices.count / 3)
            var acrossTri = [Bool](repeating: false, count: mesh.indices.count / 3)
            var t = 0
            while t + 2 < mesh.indices.count {
                let tri = t / 3
                let fid = tri < mesh.faceIDs.count ? Int(mesh.faceIDs[tri]) : -1
                // a triangle with no face id (STL, a synthetic block) cannot be told from a
                // selected face and gets no skin; only a KNOWN, unselected face does
                if fid >= 0, !selectedRaw.contains(fid) {
                    let i0 = Int(mesh.indices[t]) * 3, i1 = Int(mesh.indices[t + 1]) * 3, i2 = Int(mesh.indices[t + 2]) * 3
                    let p0 = SIMD3<Double>(Double(mesh.positions[i0]), Double(mesh.positions[i0 + 1]), Double(mesh.positions[i0 + 2]))
                    let p1 = SIMD3<Double>(Double(mesh.positions[i1]), Double(mesh.positions[i1 + 1]), Double(mesh.positions[i1 + 2]))
                    let p2 = SIMD3<Double>(Double(mesh.positions[i2]), Double(mesh.positions[i2 + 1]), Double(mesh.positions[i2 + 2]))
                    let cr = simd_cross(p1 - p0, p2 - p0)
                    let area2 = simd_length(cr)
                    if area2 > 1e-12 {
                        let nOut = cr / area2                                // the mesh's outward normal
                        // ★★★ ONLY "PASSED THROUGH" IS DECIDED PER TRIANGLE; every other
                        // unselected triangle enters the field and the POCKET decides per
                        // voxel (his images 1 and 2, 2026-09-23 15:00: the leg's top and the
                        // base's end had solid but no skin, rim or grade — their big triangles'
                        // centroids sat outside every prism, so they were "unreached" while the
                        // pocket ran right under them). Probes: the centroid and the three
                        // corners, each 1.5 mm into the part.
                        var across = false
                        let probes = [(p0 + p1 + p2) / 3, p0, p1, p2,
                                      0.5 * (p0 + p1), 0.5 * (p1 + p2), 0.5 * (p2 + p0)].map { $0 - nOut * 1.5 }
                        // a point of the prism's own plan, projected onto this triangle: for a
                        // triangle LARGER than the prism (one big face triangle, a manual slab
                        // on a wide face) none of its own points fall inside the prism, but the
                        // prism's centre or an outline corner falls inside the triangle
                        func insideTriangle(_ q: SIMD3<Double>) -> Bool {
                            let v0 = p1 - p0, v1 = p2 - p0, v2 = q - p0
                            let d00 = simd_dot(v0, v0), d01 = simd_dot(v0, v1), d11 = simd_dot(v1, v1)
                            let d20 = simd_dot(v2, v0), d21 = simd_dot(v2, v1)
                            let den = d00 * d11 - d01 * d01
                            guard abs(den) > 1e-18 else { return false }
                            let v = (d11 * d20 - d01 * d21) / den, w = (d00 * d21 - d01 * d20) / den
                            return v >= -1e-6 && w >= -1e-6 && v + w <= 1 + 1e-6
                        }
                        search: for r in includeFaceRegions
                            where abs(simd_dot(nOut, LatticeRegionMask.unit(r.normal))) > acrossCos {
                            for pr in probes where LatticeRegionMask.containsWholePrism(pr, region: r) {
                                across = true
                                break search
                            }
                            let nr = LatticeRegionMask.unit(r.normal)
                            let (ru, rv) = LatticeRegionMask.basis(nr)
                            var plan: [SIMD3<Double>] = [r.origin]
                            if r.outlineLoops.isEmpty {
                                for sx in [-1.0, 1.0] { for sy in [-1.0, 1.0] {
                                    plan.append(r.origin + ru * (sx * r.halfUMM) + rv * (sy * r.halfWMM))
                                } }
                            } else {
                                for loop in r.outlineLoops { for q in loop { plan.append(r.origin + ru * q.x + rv * q.y) } }
                            }
                            for pt in plan {
                                let q = pt - nOut * simd_dot(pt - p0, nOut)      // onto the triangle's plane
                                guard insideTriangle(q) else { continue }
                                if LatticeRegionMask.containsWholePrism(q - nOut * 1.5, region: r) {
                                    across = true
                                    break search
                                }
                            }
                        }
                        if across { acrossTris += 1; acrossTri[tri] = true }
                        else { besideTris += 1; besideTri[tri] = true; unselIdx += [mesh.indices[t], mesh.indices[t + 1], mesh.indices[t + 2]] }
                    }
                }
                t += 3
            }
            // ★★ SKIN, THEN RIM (his 2026-09-23 02:30: "THE RIM IS BELOW THE SOLID! It's the
            // transition from lattice to solid and connects the skin"). Under an unselected
            // face: the model's own thin SKIN (two beads), then the RIM — the solid band the
            // lattice thickens into (the organic rim, one base cell; the octet's outline
            // band) — then the grade, then lattice. Both are solid in the region field; the
            // band grades from the rim's inner edge; the lattice layer draws the RIM itself.
            let voxelHere = Double(Swift.max(solid.spacing.x, Swift.max(solid.spacing.y, solid.spacing.z)))
            let unselSkin = LatticeSDFRenderer.outlineBeamMM(lineWidthMM: beadMM > 0 ? beadMM : (organic?.minExtrudableWidthMM ?? 0.45), voxelMM: voxelHere)
            let unselRim = Swift.max(unselSkin, self.organicSolidRimMM)
            // ★ the rim along the SOLID-BACKED OUTLINE is his organic rim setting when the
            // algorithm is organic (0 = no rim: the lattice reaches its own outline —
            // `OrganicRegionFillProbe` pins it), and the octet's outline band otherwise
            let outlineRim = algorithm == "organic" ? self.organicSolidRimMM : unselSkin
            let bandReach = Swift.max(organic?.shapeBandMM ?? 0, 12.0)
            // ★ the outline's backing probe reads the part's own occupancy (nearest voxel)
            let solidAtGrid: (SIMD3<Double>) -> Bool = { pt in
                let g = (SIMD3<Float>(pt) - solid.origin) / solid.spacing
                let a = Int(g.x.rounded()), b = Int(g.y.rounded()), c = Int(g.z.rounded())
                guard a >= 0, b >= 0, c >= 0, a < solid.nx, b < solid.ny, c < solid.nz else { return false }
                return solid.values[(c * solid.ny + b) * solid.nx + a] > 0.5
            }
            let slabMargin = 2.0 * voxelHere
            let outlineReach = unselRim + bandReach + 2.0 * voxelHere
            var outlineRimVoxels = 0
            // (probe switch: `LATTICE_NO_AIR_BAND=1` leaves the air side of an unselected face alone)
            let airSideBand = ProcessInfo.processInfo.environment["LATTICE_NO_AIR_BAND"] != "1"
            // ★ the distance field must reach past skin + rim + the grade band: its far value
            // clamps everything beyond, and a 3-voxel clamp (5.2 mm) put EVERY voxel deeper
            // than that "1.8 mm from the rim" — green on every face (his images 1, 2, 4).
            let bandVoxels = Swift.max(3, Int(((unselSkin + unselRim + bandReach + 2.0) / voxelHere).rounded(.up)))
            let unselSDF: [Float]? = unselIdx.isEmpty ? nil
                : LatticePreviewOccupancy.signedDistance(positions: mesh.positions, indices: unselIdx, like: solid, bandVoxels: bandVoxels).values
            // ★★★ AND THE SAME DISTANCE, STOPPED AT EVERY EDGE WHERE THE FACE MEETS AN OPEN ONE
            // (his 2026-09-26 image 2: the channel floor's band wrapped round its edge into both
            // walls — a ledge "dug into" the lattice the length of the base). The mesh is edge-
            // matched by position across faces (every edge twice, measured on his stand), so the
            // triangle across each edge is known: an edge whose other side is NOT an alongside
            // triangle (a selected face, a passed-through one) clips the band to the face's own
            // footprint; an edge shared by two alongside triangles lets it round the corner.
            // Everything INSIDE the part reads this one; the air side keeps the Euclidean
            // distance (the mirrored band that keeps the chamfer's skin, 2026-09-24).
            // (probe switch: `LATTICE_WRAPPED_BAND=1` restores the Euclidean band inside the part)
            let unselClipped: [Float]? = unselIdx.isEmpty || ProcessInfo.processInfo.environment["LATTICE_WRAPPED_BAND"] == "1" ? nil : {
                struct EdgeKey: Hashable { let a: SIMD3<Int32>; let b: SIMD3<Int32> }
                func q(_ i: UInt32) -> SIMD3<Int32> {
                    let b = Int(i) * 3
                    return SIMD3(Int32((mesh.positions[b] * 1000).rounded()), Int32((mesh.positions[b + 1] * 1000).rounded()),
                                 Int32((mesh.positions[b + 2] * 1000).rounded()))
                }
                func key(_ i: UInt32, _ j: UInt32) -> EdgeKey {
                    let a = q(i), b = q(j)
                    return (a.x, a.y, a.z) < (b.x, b.y, b.z) ? EdgeKey(a: a, b: b) : EdgeKey(a: b, b: a)
                }
                // ★★ ONLY A PASSED-THROUGH NEIGHBOUR STOPS THE BAND (his 2026-09-26 01:47:
                // "the vertical rim … still broken apart"). Clipped at a SELECTED face too, the
                // leg's chamfers kept a 2.8 mm diagonal sliver of band — 1.6 voxels, drawn
                // ragged. At a selected face's mouth the rim is the mouth's outline and rounds
                // the corner; only where the prism passes THROUGH the neighbour (the walls'
                // inner faces beside the channel floor) is the pocket behind it lattice.
                var acrossEdges = Set<EdgeKey>()
                var tt = 0
                while tt + 2 < mesh.indices.count {
                    if acrossTri[tt / 3] {
                        for k in 0..<3 { acrossEdges.insert(key(mesh.indices[tt + k], mesh.indices[tt + (k + 1) % 3])) }
                    }
                    tt += 3
                }
                var clip = [Bool](repeating: false, count: unselIdx.count)
                var u = 0
                while u + 2 < unselIdx.count {
                    for k in 0..<3 { clip[u + k] = acrossEdges.contains(key(unselIdx[u + k], unselIdx[u + (k + 1) % 3])) }
                    u += 3
                }
                return LatticePreviewOccupancy.signedDistanceClippedAtEdges(
                    positions: mesh.positions, indices: unselIdx, clipEdges: clip, like: solid,
                    bandVoxels: bandVoxels, tolMM: Float(0.5 * voxelHere)).values
            }()
            let unselFar = Double(bandVoxels) * Double(Swift.min(solid.spacing.x, Swift.min(solid.spacing.y, solid.spacing.z)))
            self.unselectedSkinMM = unselSkin
            self.unselectedRimMM = unselRim
            var skinIn = solid                          // + beyond the skin's inner face, − inside the skin, 1e3 = no unselected face near
            for n in skinIn.values.indices { skinIn.values[n] = 1e3 }
            var skinVoxels = 0, rimVoxels = 0
            var f = solid
            var o = solid
            var q = solid
            var i = 0
            for k in 0..<solid.nz {
                for j in 0..<solid.ny {
                    for x in 0..<solid.nx {
                        let p = SIMD3<Double>(
                            Double(solid.origin.x) + Double(x) * Double(solid.spacing.x),
                            Double(solid.origin.y) + Double(j) * Double(solid.spacing.y),
                            Double(solid.origin.z) + Double(k) * Double(solid.spacing.z))
                        // ★ REGION ∩ {deeper than the skin}. `max` of two SDFs is
                        // the intersection, so ONE field still carries the whole
                        // rule and BOTH readers get the skin for free: the march
                        // stops `skinMM` short of the surface, and the shell —
                        // which discards where this field is negative — SURVIVES
                        // in that band. That surviving band IS the solid wall.
                        // ★ the ERODED list: the band the shell keeps and draws solid
                        // ★★★ THE WHOLE PRISM, NOT THE SLAB (his 23:17): this field opens
                        // the shell and carves the body — the pocket. The slab decides
                        // only where lattice is PLACED (candidates, cells), never where
                        // material is kept; a thin or absent slab is air, not a wall.
                        let region = LatticeRegionMask.signedDistanceWholePrism(p, regions: wallRegions)
                        q.values[i] = Float(Swift.max(-1e3, Swift.min(1e3, region)))
                        // ★ TWO VOXELS PAST THE CAPS, or the trilinear sample in the
                        // first voxel under the face blends with 1e3 and the outline's
                        // solid skin is missing in the very layer seen face-on.
                        // ★★★ THE OUTLINE COUNTS ONLY WHERE THE PART'S SOLID BACKS IT (his
                        // rules, 2026-09-23: green only where there is skin or rim, never
                        // facing air; the rim outlines the whole lattice except at seams). A
                        // prism side that runs out into air — a grown outline past the leg's
                        // top, the mouth's edge — is nothing; a prism side inside the part's
                        // material is where the lattice meets the solid: the RIM, then the
                        // grade. Backing is measured (a probe one voxel past the outline),
                        // never assumed. The band grades from the rim's inner edge.
                        var toSolidOutline = 1e3
                        if region < 3.0 {
                            toSolidOutline = LatticeRegionMask.solidBackedOutlineDistance(
                                p, regions: wallRegions, slabMarginMM: slabMargin,
                                stepMM: Swift.max(1.0, voxelHere), solidAt: solidAtGrid)
                            if toSolidOutline > outlineReach { toSolidOutline = 1e3 }
                        }
                        o.values[i] = Float(Swift.min(1e3, toSolidOutline - outlineRim))
                        // ★ AND ONLY WHEN THERE IS A SKIN — the finish's own number, 0
                        // for every finish but `covered`.
                        //
                        // ★★ IT PULLS THE ZERO CROSSING BACK FROM **EVERY** SURFACE,
                        // INCLUDING THE DECLARED FACE. The shell's nudge is one voxel,
                        // so a skin thicker than a voxel moves the region out of the
                        // shell's reach at the mouth and the declared wall reads solid
                        // again. That is inert today (his finish is `none` ⇒ 0) and it
                        // is NOT fixed by widening the nudge, which would only trade one
                        // arbitrary margin for another. The honest fix is a second
                        // reader — the march wants the skin, the shell does not — and
                        // that is a change to make when a finish is actually armed, not
                        // speculatively against a term that is currently zero.
                        // ★★★ ONE FIELD, AND THE SPLIT I TRIED HERE WAS WRONG.
                        //
                        // I separated this into a skin-free field for the SHELL and a
                        // skinned one for the MARCH, on the theory that the skin pushed
                        // the declared face outside the region as the shell sees it and
                        // left a wall solid. `LatticeFaceOutlineTests
                        // .testTheSkinLeavesASolidWallAtTheSurface` refuted it, and the
                        // refutation is the design: the shell discards where this field
                        // is NEGATIVE, so it is the POSITIVE skin band that makes the
                        // shell survive — and that surviving band IS the solid skin. Take
                        // the skin out of the shell's copy and the finish stops being
                        // drawn at all.
                        //
                        // Both readers want the skin. The asymmetry he photographed (one
                        // wall with skin, one without, same bake) is real and still
                        // unexplained — it is not this.
                        var carved = skinMM > 0
                            ? Swift.max(region, Double(partMaterialValues[i]) + skinMM)
                            : region
                        // ★ the RIM along the solid-backed outline: lattice thickens into the
                        // solid it meets (rim width, no skin — there is no surface here)
                        if toSolidOutline < 1e3, outlineRim > 0 {
                            if region < 0, toSolidOutline < outlineRim { outlineRimVoxels += 1 }
                            carved = Swift.max(carved, outlineRim - toSolidOutline)
                        }
                        var skinHere = toSolidOutline          // + beyond the skin's inner face
                        // ★ INSIDE THE PART ONLY: outside it the signed distance is positive and
                        // `skin − (−d)` would read solid, moving the selected face's zero
                        // crossing inward (`LatticeFaceOutlineTests.testTheSkinLeavesASolid
                        // WallAtTheSurface` caught it).
                        // ★ inside the part the band is the CLIPPED distance (no wrap round an
                        // edge into an open face); outside it the Euclidean one (see above)
                        let uInside = unselClipped.map { $0[i] < 0 } ?? false
                        if let u = uInside ? unselClipped : unselSDF, abs(Double(u[i])) < unselFar - 1e-3 {
                            let toUnsel = -Double(u[i])                    // + inside the part, − outside
                            // ★ CONTINUOUS ACROSS THE SURFACE (− outside the part): the sampled
                            // texture at the face must never blend a distance with the 1e3
                            // sentinel, or the first voxel under every face loses its rim
                            skinHere = Swift.min(skinHere, toUnsel - unselSkin)
                            // ★★★ AND THE AIR JUST OUTSIDE THE FACE IS NOT THE POCKET (his 2026-09-24
                            // 15:41, image 4: the chamfer between face 15 and face 23 with no skin).
                            // Where two prisms overlap, face 23's EXPANDED prism reaches through
                            // the chamfer into the air outside it, so the air voxel there read −2
                            // (inside a prism) while the voxel under the chamfer read +4 (skin +
                            // rim). The shell samples the field AT the surface — the blend of the
                            // two — and read "open" on 39 of 180 chamfer samples. The band is
                            // written on the air side too: a prism does not open a face the
                            // lattice runs alongside. Only the region field; the march and the
                            // capsules never reach the air (the part clips them first).
                            if u[i] >= 0, airSideBand {
                                // mirrored: solid within skin + rim of the face on the air side,
                                // nothing beyond (the mouth of an open face stays open)
                                carved = Swift.max(carved, unselSkin + unselRim - abs(toUnsel))
                            }
                            if u[i] < 0 {
                                // inside the part, within skin + rim of an unselected face ⇒ solid;
                                // beyond the clamp the field says nothing and nothing is applied
                                if region < 0 {
                                    if toUnsel < unselSkin { skinVoxels += 1 } else if toUnsel < unselSkin + unselRim { rimVoxels += 1 }
                                }
                                carved = Swift.max(carved, unselSkin + unselRim - toUnsel)
                                // ★ and the band grades from the RIM's inner edge, as from any outline
                                if region < 3.0 {
                                    o.values[i] = Float(Swift.min(Double(o.values[i]), toUnsel - unselSkin - unselRim))
                                }
                            }
                        }
                        // ★★ NEVER A RIM IN THE AIR (R4: "never sticks out of the model"; his
                        // 2026-09-25 16:58: rim fragments floating left of the leg). Outside the
                        // part the skin field is negative whatever else is near — the rim gate
                        // (prism < 0, region ≥ 0, skinIn ≥ 0) can then never pass in air, even
                        // where no unselected face is within reach and only an outline was.
                        if solid.values[i] <= 0.5 {
                            skinHere = Swift.min(skinHere, -Swift.max(Double(partMaterialValues[i]), 1e-3))
                        }
                        skinIn.values[i] = Float(Swift.min(1e3, skinHere))
                        f.values[i] = Float(carved)
                        i += 1
                    }
                }
            }
            self.regionSDF = f
            self.outlineSDF = o
            outlineForOrganic = o
            self.prismSDF = q
            self.skinInSDF = skinIn
            NSLog("DIAG unselected faces: skin %.2f mm + rim %.2f mm under every unselected face the lattice does not pass through (selected raw faces %@; triangles alongside %d, passed through %d; field reach %.1f mm) · pocket voxels turned solid: skin %d, rim %d, outline rim (solid-backed) %d",
                  unselSkin, unselRim, selectedRaw.sorted().map(String.init).joined(separator: ","), besideTris, acrossTris, unselFar, skinVoxels, rimVoxels, outlineRimVoxels)
        } else {
            self.regionSDF = nil
            self.outlineSDF = nil
            self.prismSDF = nil
        }
        tRegionField = Date().timeIntervalSince(sceneT0) - tOccupancy
        // ★ A STATED PER-REGION DENSITY OUTRANKS THE STRESS FIELD. It is the
        // user's own number for that region; grading it by stress instead would
        // draw struts at a density they did not ask for and the run will not
        // build. With nothing stated this falls through to exactly what it was.
        let statedDemand = statedDensityGoverns
            ? LatticeRegionMask.densityDemand(
                like: occupancy, regions: regions,
                rhoMin: rhoMin, rhoMax: rhoMax, gamma: gamma)
            : nil
        // ★★★ THE DENOMINATOR IS THE MODE'S — and it was hard-wired to AESTHETIC.
        //
        // `LatticeStageMode` leads with "THE DENOMINATOR (above) — so the same part
        // grades differently", and that promise was written down and not implemented:
        // `demand(...)` defaults `intent` to 1 and BOTH call sites took the default, so
        // every part was graded aesthetically whichever mode was chosen. Structural was
        // dividing by a percentile of the part's own field instead of by the material's
        // allowable, which is the one thing that distinguishes the two modes.
        //
        // ★ AND STRUCTURAL NEEDS AN ALLOWABLE TO MEAN ANYTHING. Core returns a demand
        // of ZERO for every voxel when the reference is not positive
        // (`grading_demand_fraction`), so asking for the structural denominator with no
        // yield strength would silently flatten the whole lattice to the band floor.
        // With no allowable the relative reference is kept, and that is stated rather
        // than hidden.
        let intentForGrading = (stageMode == .structural && allowableMPa > 0) ? 0 : 1
        let relative = LatticePreviewOccupancy.demand(
            like: occupancy, field: field, intent: intentForGrading,
            allowableMPa: allowableMPa)
        // ★★★ MINIMIZE PLASTIC — THE ABSOLUTE ANCHOR UNDER A RELATIVE MAP.
        //
        // ★ WHY NOT `utilisationTarget`. That is core's parameter for exactly this
        // shape of question, and it is the WRONG one twice over: core applies it only
        // when the intent is Structural (`grading.hpp:153`), so it is inert in the mode
        // he is using; and it divides, so a LOWER target makes the lattice DENSER — it
        // is a conservatism dial already sitting at its least-material setting. Wiring
        // the checkbox to it would have been a no-op in Aesthetic and a regression
        // everywhere the box is off.
        //
        // ★ WHAT ACTUALLY SPENDS THE PLASTIC IS THE MISSING ANCHOR. An aesthetic demand
        // is `stress / (a high percentile of the part's own stress)`. That is a pure
        // SHAPE: whatever is working hardest reads ~1.0 and takes the top of the band,
        // whether the part is at yield or at three percent of it. A relative map with
        // nothing absolute under it cannot tell those two apart — which is precisely
        // "it automatically assumes it requires massive struts … when in fact it's a
        // relative stress map".
        //
        // So with the box ticked the relative demand is CAPPED by the true utilisation:
        // the pattern still follows the field, and no voxel is drawn denser than the
        // load actually justifies. It can only ever remove material, never add it, so
        // it cannot make the picture overstate strength. Unticked, nothing changes.
        // ★★★ MINIMIZE PLASTIC HAS NO BEARING ON THE LATTICE (his ruling, 2026-09-12:
        // "minimize_plastic on/off should not have any bearing on the lattice
        // whatsoever … ONLY affects the optimization of the model"). The utilisation cap
        // that used to ride on that chip is GONE; the aesthetic ceiling below is the
        // lattice's one density cap, identical under either ladder. `minimizePlastic`
        // stays in the signature only so call sites need not change; it is not read.
        _ = minimizePlastic
        let graded = relative
        // ★★★ THE AESTHETIC CEILING ON EVERY AUTOMATIC DENSITY (his ruling, 2026-09-12).
        // The shader draws rho = lo + (hi − lo)·demand^gamma with `hi` at the certifiable
        // top (0.90), and core's strut law is flat past 0.60 — so the top two thirds of
        // the simulated range drew the same 0.38·L strut, a sheet with holes (his 63 %
        // front wall). The relative or utilisation-capped map is clamped here to the
        // demand that lands on `LatticeType.aestheticDensityCeiling` (strut = 0.20 of
        // the cell, windows half open). A STATED per-face density is not clamped: that
        // is the one manual way past the ceiling. Nothing about grade-to-shape moves.
        let ceilingRho = LatticeType.named(latticeID)?.aestheticDensityCeiling() ?? 1   // no law: no cap (item a)
        let demandCap = Self.aestheticDemandCap(rhoMin: rhoMin, rhoMax: rhoMax, gamma: gamma,
                                                ceilingRho: ceilingRho)
        func cap(_ grid: LatticeVoxelGrid?) -> (LatticeVoxelGrid?, Int) {
            guard var g = grid, demandCap < 1 else { return (grid, 0) }
            var n = 0
            for i in 0..<g.values.count where g.values[i] > Float(demandCap) {
                g.values[i] = Float(demandCap); n += 1
            }
            return (g, n)
        }
        // ★ THE SIMULATED MAP IS RESCALED INTO [floor, ceiling], NOT CLIPPED: multiplying
        // the demand by the cap puts demand 1 exactly on the ceiling and keeps the whole
        // contrast of the field (with the shader's gamma law this is exact:
        // lo + (hi−lo)·(d·cap)^γ = lo + (ceiling−lo)·d^γ). A clip would flatten every
        // voxel above 22 % of the reference stress to one density.
        func scale(_ grid: LatticeVoxelGrid?) -> (LatticeVoxelGrid?, Int) {
            guard var g = grid, demandCap < 1 else { return (grid, 0) }
            for i in 0..<g.values.count { g.values[i] *= Float(demandCap) }
            return (g, g.values.count)
        }
        let (cappedGraded, cappedGradedCount) = scale(graded)
        // ★ A STATED density is a NUMBER the user typed: it is held AT the ceiling (clipped),
        // never rescaled — and Allow quilt is the one manual way past it.
        let (cappedStated, cappedStatedCount) = allowQuilt ? (statedDemand, 0) : cap(statedDemand)
        if graded != nil || statedDemand != nil {
            NSLog(String(format: "DIAG densityCeiling rho=%.3f (strut/cell %.2f, octet=%@) band=[%.3f, %.3f] gamma=%.2f demandCap=%.3f cappedGraded=%d cappedStated=%d allowQuilt=%@",
                         ceilingRho, LatticeType.aestheticStrutRatioCeiling,
                         LatticeType.named(latticeID)?.hasAestheticCeiling == true ? "yes" : "no",
                         rhoMin, rhoMax, gamma, demandCap, cappedGradedCount, cappedStatedCount,
                         allowQuilt ? "yes" : "no"))
        }
        // ★ TWO MAPS. `demand` is the RAW map every planner reads (the dyadic ladder's cell
        // plan, retention, the stress overlay) — grade-to-shape and the cell ladder are
        // untouched by the ceiling (his ruling: "leave the grade to shape alone").
        // `drawnDemand` is what the texture's activation is baked from — the density the
        // struts are DRAWN at — and that is where the ceiling lives.
        self.demand = statedDemand ?? graded
        self.drawnDemand = cappedStated ?? cappedGraded
        self.drawnBand = (rhoMin, rhoMax)
        self.allowQuilt = allowQuilt
        self.drawnCeilingRho = ceilingRho
        // ★ each region's median drawn density (see `regionDrawnDensityP50`)
        if let dd = self.drawnDemand {
            let g = Swift.max(0.05, gamma)
            var per = [[Double]](repeating: [], count: regions.count)
            let po = self.prismOccupancy
            for k in 0..<po.nz { for j in 0..<po.ny { for i in 0..<po.nx where po.values[(k * po.ny + j) * po.nx + i] > 0.5 {
                let p = SIMD3<Double>(po.origin + SIMD3<Float>(Float(i), Float(j), Float(k)) * po.spacing)
                guard let r = regions.firstIndex(where: { $0.role == .include && LatticeRegionMask.containsWholePrism(p, region: $0) }) else { continue }
                let d = Swift.max(0, Swift.min(1, dd.sampleLinear(p)))
                per[r].append(rhoMin + (rhoMax - rhoMin) * pow(d, g))
            } } }
            self.regionDrawnDensityP90 = per.map { v in v.isEmpty ? 0 : v.sorted()[Swift.min(v.count - 1, 9 * v.count / 10)] }
            NSLog("DIAG regionDrawnDensity ceiling %.3f allowQuilt %@ · %@", ceilingRho, allowQuilt ? "yes" : "no",
                  per.enumerated().map { i, v in
                      let s = v.sorted()
                      return s.isEmpty ? "r\(i) –" : String(format: "r%d p10 %.3f p50 %.3f p90 %.3f (n %d)", i,
                          s[s.count / 10], s[s.count / 2], s[Swift.min(s.count - 1, 9 * s.count / 10)], s.count)
                  }.joined(separator: " | "))
        }

        // ── ★★★ ORGANIC: TRACE, THEN BAKE THE CAPSULES TO A FIELD ───────────────────
        //
        // ★ THE SEPARATION IS THE INPUT THE WHOLE METHOD TURNS ON. Organic has no cell:
        // cell size is DERIVED from the achieved spacing. So the user's cell window is
        // read as a SPACING window and the demand is mapped onto it — tight where the
        // part is working, open where it is not. That is core's own posture
        // (`organic_lattice.hpp`: "the window is now the SPACING control").
        //
        // ★ AND THE FIELD IS BAKED OVER THE DECLARED REGION, not the part. On his part
        // the design grid is 1.7-3.4 mm and organic's struts are 1-3 mm across — at the
        // part's resolution they would be sub-voxel and the preview would be mush. The
        // region's own bbox is a fraction of the part, so the same budget buys a voxel
        // several times finer.
        var organicMismatch: String? = nil
        var organicSpanReceipt: (count: Int, lengthMM: Double)? = nil
        var organicOut: LatticeVoxelGrid?
        var organicSurfaceOut: LatticeVoxelGrid?
        var organicEmittedOut: [(a: SIMD3<Double>, b: SIMD3<Double>, r: Double)]? = nil
        var organicWhyNot: String? = nil
        var organicSyntheticOut: TopOptKit.OrganicSyntheticReport? = nil
        var organicPhaseOut: (trace: Double, emit: Double, bake: Double)? = nil
        var organicCapsOut: [OrganicCapsule] = []
        /// ★ The field the tracer saw, synthesis included — what the stress map paints.
        var organicSynthFieldOut: StressField? = nil
        var organicBand = 0.0
        var organicSaid = ""
        // ★★★ SPANS FIRST. A span file is the run's own emitted geometry; a trace is a
        // preview-time estimate of it. When the spans are here the estimate is not
        // asked for. Grid: the index's own bounds (the capsules, plus their reach), at
        // the same spacing rule the trace uses — longest extent / 384, capped at 12 M
        // voxels — so the picture's resolution does not change with the source.
        if organicOut == nil, algorithm == "organic", let baked = organicBaked {
            organicOut = baked.distance
            organicSurfaceOut = baked.surface
            organicBand = baked.reachMM
            organicSaid = baked.summary
            organicSpanReceipt = (baked.spanCount, baked.lengthMM)
            organicCapsOut = baked.capsules
        }
        if organicOut == nil, algorithm == "organic", let sp = organicSpans {
            let mn = sp.indexOrigin
            let ext = SIMD3<Float>(sp.indexDims) * sp.cellMM
            let longest = Swift.max(ext.x, Swift.max(ext.y, ext.z))
            var fs = organicBakeVoxelMM ?? Swift.max(0.35, Double(longest) / 384.0)
            while (Double(ext.x) / fs + 2) * (Double(ext.y) / fs + 2)
                    * (Double(ext.z) / fs + 2) > 12_000_000 { fs *= 1.25 }
            let fnx = Swift.max(2, Int(Double(ext.x) / fs) + 2)
            let fny = Swift.max(2, Int(Double(ext.y) / fs) + 2)
            let fnz = Swift.max(2, Int(Double(ext.z) / fs) + 2)
            let band = Self.organicBakeHeadroomMM
            // ★ the same two-channel bake the trace path uses, through the bridge
            let spanList = sp.segments.map { (a: SIMD3<Double>($0.a), b: SIMD3<Double>($0.b), r: Double($0.r)) }
            if let baked = TopOptKit.organicSpansField(spans: spanList, fieldDims: (fnx, fny, fnz),
                                                      fieldOrigin: SIMD3<Double>(mn), fieldSpacingMM: fs,
                                                      bandMM: band) {
                organicOut = LatticeVoxelGrid(nx: fnx, ny: fny, nz: fnz, origin: mn,
                                              spacing: SIMD3<Float>(repeating: Float(fs)), values: baked.field)
                organicSurfaceOut = LatticeVoxelGrid(nx: fnx, ny: fny, nz: fnz, origin: mn,
                                                    spacing: SIMD3<Float>(repeating: Float(fs)), values: baked.surfaceField)
                organicBand = baked.reachMM
            }
            organicCapsOut = sp.segments.map { OrganicCapsule(a: $0.a, b: $0.b, r: $0.r) }
            organicSaid = "\(sp.count) struts, "
                + String(format: "%.0f mm — the run's emitted spans", sp.totalLengthMM)
            organicSpanReceipt = (sp.count, sp.totalLengthMM)
            organicMismatch = organicReceipt?.mismatch(againstIndexedCount: sp.count,
                                                       totalLengthMM: sp.totalLengthMM)
        }
        if organicOut == nil, algorithm == "organic", organicCached == nil, organicBaked == nil, organicSpans == nil {
            if organic == nil { organicWhyNot = "no stress tensor reached the tracer (the stage's solve has not produced one, or it failed)" }
            else if let o = organic, !(o.minExtrudableWidthMM > 0) { organicWhyNot = "no extrudable width stated in Print Parameters" }
            else if let o = organic, o.tensor.count != 6 * o.dims.0 * o.dims.1 * o.dims.2 { organicWhyNot = "the solve's field carries no stress tensor (\(o.tensor.count) of \(6 * o.dims.0 * o.dims.1 * o.dims.2) values)" }
        }
        if organicOut == nil, let o = organic, o.minExtrudableWidthMM > 0,
           o.tensor.count == 6 * o.dims.0 * o.dims.1 * o.dims.2 {
            let occ = self.occupancy
            // The candidate set and the separation, both on the TENSOR's grid — that is
            // the grid core traces on, and resampling the declaration onto it is what
            // keeps "where he marked" and "where it traced" the same set.
            let (tnx, tny, tnz) = o.dims
            let exactRegions = o.regionIDs.count == tnx * tny * tnz
            let sdfForSolid = self.partMaterialSDF      // ★ the part's material, not the slab
            func partSolidAt(_ q: SIMD3<Float>) -> Bool {
                let gg = (q - sdfForSolid.origin) / sdfForSolid.spacing
                let a2 = Int(gg.x.rounded()), b2 = Int(gg.y.rounded()), c2 = Int(gg.z.rounded())
                guard a2 >= 0, b2 >= 0, c2 >= 0,
                      a2 < sdfForSolid.nx, b2 < sdfForSolid.ny, c2 < sdfForSolid.nz else { return false }
                return sdfForSolid.values[(c2 * sdfForSolid.ny + b2) * sdfForSolid.nx + a2] < 0
            }
            var cand = [Bool](repeating: false, count: tnx * tny * tnz)
            var sep = [Double](repeating: 0, count: tnx * tny * tnz)
            let lo = Swift.min(o.separationMinMM, o.separationMaxMM)
            let hi = Swift.max(o.separationMinMM, o.separationMaxMM)
            var n = 0
            for k in 0..<tnz { for j in 0..<tny { for i in 0..<tnx {
                // ★★★ CORE'S VOXEL CENTRE (2026-09-07). This read `origin + i·h`, the
                // CORNER, while core defines voxel i's position as
                // `origin + (i + 0.5)·h` (`VoxelGrid::voxel_center`). So the mask handed
                // to the tracer was half a voxel out of step with what core believes it
                // describes — material lost along one boundary of every region and
                // claimed along the opposite one — and the region tags built for the
                // synthesis, which DID use core's convention, disagreed with it.
                let p = SIMD3<Float>(
                    Float(o.originMM.x + (Double(i) + 0.5) * o.spacingMM),
                    Float(o.originMM.y + (Double(j) + 0.5) * o.spacingMM),
                    Float(o.originMM.z + (Double(k) + 0.5) * o.spacingMM))
                let g = (p - occ.origin) / occ.spacing
                let a = Int(g.x.rounded()), b = Int(g.y.rounded()), c = Int(g.z.rounded())
                guard a >= 0, b >= 0, c >= 0, a < occ.nx, b < occ.ny, c < occ.nz else { continue }
                let oi = (c * occ.ny + b) * occ.nx + a
                let idx = (k * tny + j) * tnx + i
                // ★★★ THE REGION IS ASKED EXACTLY, NOT RESAMPLED (2026-09-07). Rounding
                // this voxel's centre onto the occupancy grid dropped it whenever the
                // centre landed just outside — up to half a voxel lost at every boundary
                // of every face, which the run does not lose. `o.regionIDs` is the
                // region membership computed on THIS grid; the occupancy is then only
                // asked whether there is material here at all.
                if exactRegions {
                    guard o.regionIDs[idx] >= 1, occ.values[oi] > 0.5 || partSolidAt(p) else { continue }
                } else {
                    guard occ.values[oi] > 0.5 else { continue }
                }
                cand[idx] = true
                // Dense where it works hardest: demand 1 ⇒ the tight end.
                // ★★ THE REQUESTED SEPARATION ONLY — CORE RAISES IT.
                //
                // ★ A CLAMP HERE WOULD BE A RE-DERIVATION. `trace_organic_lattice`
                // already applies BOTH floors per voxel and COUNTS each raise on the
                // receipt (`spacing_raised_for_print_voxels`,
                // `spacing_raised_for_resolution_voxels`): the printable floor
                // `d ≥ t·√(3π)/2` at that voxel's own bead, and the RESOLUTION floor
                // `resolution_floor_voxels · h`, which is the one that actually binds on
                // a real part (1.705 mm against a 0.645 mm printability floor on his).
                // Applying either here would put a second copy of core's law in the app
                // — the mistake that left the octet strut law 1.4-1.7x adrift.
                n += 1
            } } }
            // ★★★ THE LATTICE RUNS INTO THE RIM — IT IS NOT CUT BACK FROM IT (his walk,
            // 2026-09-08, looking at the front face's bottom edge: "The struts are not
            // continuing INTO the solid rim. Currently you are cutting out WHOLE cells.
            // don't do that. Continue the lattice passed the edge INTO the solid and
            // union the two. This will get rid of the empty space between the lattice
            // and the rim. This will also provide the struts for the filleting … can't
            // exactly make that work if the lattice stops without TOUCHING the rim").
            //
            // ★ WHAT THIS USED TO DO, AND WHY IT LEFT A GAP. It deleted the band's
            // voxels from the candidate set before tracing — core's old rim pass (which
            // cleared the mask; since replaced by `organic_solid_rim_band`), mirrored. So the tracer never entered the band,
            // every curve was cut back to the eroded boundary, and the trim then took
            // another bite off each end. The rim was drawn starting where the region
            // ended, and between the two sat a strip of nothing: whole cells removed, as
            // he says, and no strut anywhere near the wall it was supposed to join.
            //
            // ★ THE BAND STAYS A CANDIDATE NOW. The tracer runs through it and out into
            // the solid; the band is still DRAWN as solid on top, so the two are unioned
            // by the depth buffer — the struts disappear into the wall instead of
            // stopping in front of it, which is the only arrangement in which a fillet
            // has two surfaces to blend. The count is kept for the banner because "how
            // wide is the rim" is still a question worth answering.
            //
            // ★ AND THE RUN FOLLOWS. Core keeps the band as tracer candidates and turns it
            // solid AFTER the trace (ruling G, `organic_solid_rim_band`, run_job.cpp), so
            // its struts also run into the wall; the wetted join is applied too, on the
            // latticed set, but only in the dual-contoured file (core #358).
            var solidRimVoxels = 0
            // ★ NO DECLARED FACE ⇒ NO OUTLINE, so the block's EDGES take the band
            // instead — the sample cube's twelve bars, never its faces (his rule,
            // 2026-09-07: "NEVER OBSTRUCT THE VIEW OF THE LATTICE").
            if n > 0, o.solidRimMM > 0, !exactRegions {
                solidRimVoxels = OrganicSolidRim.edgeVoxels(
                    candidate: cand, nx: tnx, ny: tny, nz: tnz,
                    voxelMM: o.spacingMM, rimMM: o.solidRimMM).count
            }
            if n > 0, o.solidRimMM > 0, exactRegions {
                // ★ ONLY WHERE THE RIM CAN READ IT (2026-09-07). `OrganicSolidRim`
                // asks `solid` about the SIX NEIGHBOURS of a candidate and nothing else,
                // so sampling the part's distance field at every voxel of the grid did
                // 262,144 lookups to answer a few thousand questions. On a Debug build
                // that is seconds of a bake he is waiting on.
                var isSolid = [Bool](repeating: false, count: tnx * tny * tnz)
                let rdi = [1, -1, 0, 0, 0, 0], rdj = [0, 0, 1, -1, 0, 0], rdk = [0, 0, 0, 0, 1, -1]
                var asked = [Bool](repeating: false, count: tnx * tny * tnz)
                for k in 0..<tnz { for j in 0..<tny { for i in 0..<tnx {
                    guard cand[(k * tny + j) * tnx + i] else { continue }
                    for d in 0..<6 {
                        let i2 = i + rdi[d], j2 = j + rdj[d], k2 = k + rdk[d]
                        guard i2 >= 0, j2 >= 0, k2 >= 0, i2 < tnx, j2 < tny, k2 < tnz else { continue }
                        let e2 = (k2 * tny + j2) * tnx + i2
                        guard !asked[e2] else { continue }
                        asked[e2] = true
                        isSolid[e2] = partSolidAt(SIMD3<Float>(
                            Float(o.originMM.x + (Double(i2) + 0.5) * o.spacingMM),
                            Float(o.originMM.y + (Double(j2) + 0.5) * o.spacingMM),
                            Float(o.originMM.z + (Double(k2) + 0.5) * o.spacingMM)))
                    }
                } } }
                let normals = regions.filter { $0.role == .include && $0.isValid }.map { $0.normal }
                let rim = OrganicSolidRim.voxels(
                    candidate: cand, solid: isSolid, regionID: o.regionIDs, normals: normals,
                    nx: tnx, ny: tny, nz: tnz, voxelMM: o.spacingMM, rimMM: o.solidRimMM)
                // ★ COUNTED, NOT DELETED — see the note above. The band stays a
                // candidate so the curves run through it into the solid.
                solidRimVoxels = rim.count
            }
            // ★★★ ARE THE CURVE ENDS ANCHORED AT THE REGION BOUNDARY? (his walk,
            // 2026-09-07: "There are still empty spaces at the bottom and the top".)
            //
            // ★ THE PREVIEW ASKED THE WRONG HALF OF THE QUESTION. It passed
            // `anchorAtBoundary = (boundary == .covered)` — the SHELL rule alone. Core
            // (run_job.cpp, `op.anchor_at_region_boundary`) is
            // `shell_is_written || boundary_solid_fraction > 0.5`: a region cut into
            // SOLID MATERIAL anchors on that material whether or not a shell is drawn.
            // With anchors off, every curve end that leaves the region is a dangling end
            // and the trim cuts it back to its last connector — all the way round, top,
            // bottom and sides. That is the bare band, and the run does not have it: his
            // face prisms are cut into a solid wall, so core anchors.
            //
            // ★ MIRRORED EXACTLY, QUIRK INCLUDED. Core sets `edge` only when a
            // non-lattice neighbour is SOLID, so `backed == on_boundary` and the
            // fraction can only be 0 or 1 — "does the region touch solid anywhere".
            // Reproducing core's arithmetic rather than the sentence in its comment is
            // the only way the picture and the run can agree; the quirk is core's to
            // decide about, and it is named in the handoff rather than silently
            // "corrected" here.
            // ★★ THE SEEDING BOOST (his 2026-09-21: "modify the algorithm being used by the
            // beams to create the preview"). Core's tracer offers the next seed one
            // separation off an accepted curve (seed_ratio 1.0), refuses a curve within
            // half a separation of another (test_ratio 0.5) and culls curves shorter than
            // one separation (min_length_ratio 1.0). At boost b the seed and length ratios
            // fall by b — seeds offered closer, short curves near the rim kept — and the
            // test ratio falls by b but never below the printable floor over the smallest
            // separation, so two curves can never be laid closer than the printer can.
            let seedRatios: (seed: Double, test: Double, minLength: Double) = {
                let b = Swift.max(1, o.seedBoost)
                guard b > 1 + 1e-9 else { return (0, 0, 0) }
                let floorMM = OrganicSizeCheck.floor(beadMM: o.minExtrudableWidthMM, voxelMM: o.spacingMM).mm
                let sepMin = Swift.max(1e-6, Swift.min(o.separationMinMM, o.separationMaxMM))
                let test = Swift.max(0.5 / b, floorMM / sepMin)
                return (1.0 / b, Swift.min(0.5, test), 1.0 / b)
            }()
            if seedRatios.seed > 0 {
                NSLog("DIAG organic seeding boost ×%.2f: seed_ratio %.2f test_ratio %.2f min_length_ratio %.2f",
                      o.seedBoost, seedRatios.seed, seedRatios.test, seedRatios.minLength)
            }
            var anchorAtBoundary = o.anchorAtBoundary
            if n > 0, !anchorAtBoundary {
                let sdf = self.partMaterialSDF
                var onBoundary = 0, backed = 0
                let di = [1, -1, 0, 0, 0, 0], dj = [0, 0, 1, -1, 0, 0], dk = [0, 0, 0, 0, 1, -1]
                for k in 0..<tnz { for j in 0..<tny { for i in 0..<tnx {
                    guard cand[(k * tny + j) * tnx + i] else { continue }
                    var edge = false
                    for d in 0..<6 {
                        let i2 = i + di[d], j2 = j + dj[d], k2 = k + dk[d]
                        guard i2 >= 0, j2 >= 0, k2 >= 0, i2 < tnx, j2 < tny, k2 < tnz else { continue }
                        if cand[(k2 * tny + j2) * tnx + i2] { continue }
                        // Is that neighbour SOLID part material? (core: density > iso)
                        let q = SIMD3<Float>(
                            Float(o.originMM.x + (Double(i2) + 0.5) * o.spacingMM),
                            Float(o.originMM.y + (Double(j2) + 0.5) * o.spacingMM),
                            Float(o.originMM.z + (Double(k2) + 0.5) * o.spacingMM))
                        let gg = (q - sdf.origin) / sdf.spacing
                        let a2 = Int(gg.x.rounded()), b2 = Int(gg.y.rounded()), c2 = Int(gg.z.rounded())
                        guard a2 >= 0, b2 >= 0, c2 >= 0, a2 < sdf.nx, b2 < sdf.ny, c2 < sdf.nz else { continue }
                        if sdf.values[(c2 * sdf.ny + b2) * sdf.nx + a2] < 0 { edge = true }
                    }
                    if edge { onBoundary += 1; backed += 1 }
                } } }
                let frac = onBoundary > 0 ? Double(backed) / Double(onBoundary) : 0
                if frac > 0.5 { anchorAtBoundary = true }
                NSLog("DIAG organic anchors: boundary voxels %d backed %d frac %.2f → anchorAtBoundary=%@",
                      onBoundary, backed, frac, anchorAtBoundary ? "yes" : "no")
            }
            // ★★★ THE SEPARATION IS GRADED FROM THE TRACER'S OWN STRESS (his walk,
            // 2026-09-07: "This was what Auto cell-grading looks like. It's awful").
            //
            // ★ IT USED TO READ `demand`, AND UNDER AUTO THERE IS NO DEMAND. The bake
            // hands a stress field to the scene only when the DENSITY mode is Sim; on
            // Auto it asks for the optimise run's field, which is nil before a run. So
            // `demand` was nil, `d` fell back to 0, and 0 means the WIDEST spacing —
            // every voxel got the coarsest end of the window, uniformly, over the whole
            // part. That is not a grade at all, and "Auto cell-grade" is the control
            // that promises one. A stated per-region density did no better: one number
            // per region is still one separation per region.
            //
            // ★ THE FIELD IS RIGHT HERE. Organic is traced from the full Cauchy tensor,
            // so `o.tensor` is guaranteed present on THIS grid — no resampling, no
            // second provenance, nothing to be nil. Its von Mises, normalised over the
            // candidate set between the 5th and 95th percentile (robust to the one hot
            // voxel at an anchor), is the demand: 1 where the part works hardest ⇒ the
            // tight end of the window, 0 where it idles ⇒ the open end.
            //
            // ★ A SINGLE SIZE IS STILL A SINGLE SIZE. lo == hi ⇒ uniform, which is what
            // Manual with one number means.
            // ★★ CORE DECIDES WHICH WALLS ARE DEAD (maintainer, 2026-09-29, ruling C: "Stop
            // zeroing dead walls in the app, pass core the same tensor the run uses, and
            // take the dead regions from core's report (fully_synthetic > 0). Preview = run
            // by construction"). The app used to zero a wall it judged dead by its own p99
            // (floor index, over every tagged voxel) before core saw it, so on a wall at
            // the threshold the preview and the run could disagree. Now core is asked
            // first — the run's own call, on the untouched tensor, these candidates and
            // these ids — because a dead wall is graded at the window's middle BEFORE the
            // trace. The trace's candidates are these same voxels: `sep > 0` on every one
            // once graded, since the window's low end is > 0.
            var deadRegionIDs = Set<Int>()
            if n > 0, let rep = LatticeSDFScene.coreDeadWallVerdict(candidate: cand, input: o) {
                organicSyntheticOut = rep
                deadRegionIDs = rep.deadRegionIDs
                // `fully_synthetic > 0` is the ruling's test; core's own flag is
                // `whole_region`. They part only on a wall whose focal field is zero at
                // every voxel — said aloud rather than assumed.
                for r in rep.regions where (r.fullySynthetic > 0) != r.wholeRegion {
                    NSLog("DIAG synthetic: region %d whole_region %d but fully_synthetic %d of %d",
                          r.regionID, r.wholeRegion ? 1 : 0, r.fullySynthetic, r.voxels)
                }
            }
            var gradedNote = ""
            if n > 0 {
                if hi - lo < 1e-9 {
                    for e in 0..<cand.count where cand[e] { sep[e] = lo }
                    gradedNote = String(format: " · uniform %.2f mm", lo)
                } else {
                    var vm = [Double](repeating: 0, count: cand.count)
                    var sorted: [Double] = []
                    sorted.reserveCapacity(n)
                    let exactIDs = o.regionIDs.count == cand.count
                    func isDead(_ e: Int) -> Bool {
                        exactIDs && !deadRegionIDs.isEmpty && deadRegionIDs.contains(Int(o.regionIDs[e]))
                    }
                    var deadVoxels = 0
                    for e in 0..<cand.count where cand[e] {
                        let v = OrganicSyntheticStress.vonMises(o.tensor, at: e)
                        vm[e] = v
                        if isDead(e) { deadVoxels += 1 } else { sorted.append(v) }
                    }
                    sorted.sort()
                    let p05 = sorted.isEmpty ? 0 : sorted[Int(0.05 * Double(sorted.count - 1))]
                    let p95 = sorted.isEmpty ? 0 : sorted[Int(0.95 * Double(sorted.count - 1))]
                    let span = Swift.max(p95 - p05, 1e-12)
                    for e in 0..<cand.count where cand[e] {
                        if isDead(e) { sep[e] = 0.5 * (lo + hi); continue }
                        let t = Swift.min(Swift.max((vm[e] - p05) / span, 0), 1)
                        sep[e] = hi - (hi - lo) * t
                    }
                    gradedNote = String(format: " · graded %.2f–%.2f mm by stress (p05 %.4g, p95 %.4g MPa)",
                                        lo, hi, p05, p95)
                    if deadVoxels > 0 {
                        gradedNote += String(format: " · %d dead-wall voxels at the window's middle %.2f mm", deadVoxels, 0.5 * (lo + hi))
                    }
                }
            }
            // ★ SHAPE FIT (maintainer, 2026-09-03): the separation shrinks toward the
            // walls so the lattice fits the outline — core's rule, mirrored in
            // `OrganicShapeFit` because it lives inline in the CLI. Applied to the same
            // `sep` the tracer is handed, exactly where the run applies it (before the
            // trace), so the sample and the part preview follow the outline as the run
            // will. `shapeFitOnly` replaces the stress-driven window by the depth ramp.
            var fitNote = ""
            if n > 0, o.shapeFit {
                // ★ NO WINDOW HERE (2026-09-04): under Auto the job states none, so in
                // the run `have_window` is false and the cap's floor is
                // `kOrganicShapeFitMinCellRatio × spacing` (run_job.cpp). ★ A MANUAL PICK
                // NOW DOES carry one (ruling 5, 2026-10-03: a swept window, lo == hi for
                // one size), and there core floors the cap at `cell_min_mm` — for one
                // size that makes the run's shape fit inert. The preview still passes
                // none; that difference is reported (round-3 handoff), not decided here.
                // ★★★ CORE'S SHAPE FIT HAS TWO TERMS AND THE PREVIEW ONLY HAD ONE
                // (his walk, 2026-09-07: "There should be a Grade to Shape that is
                // always on"). Core caps the spacing at `min(member_width / n★,
                // 2 · dist · voxel)`; this file's own note said the member term "needs
                // the run's per-voxel member width, which the preview does not have".
                // It does have it: `lattice_member_thickness_mm` is the same core
                // function the octet path already calls through the bridge, and it takes
                // exactly the candidate mask and the grid this loop just built.
                //
                // Without it the only cap was `2 · dist · voxel`, which at a 1.6 mm
                // voxel first drops below a 5.5 mm separation at ONE voxel from the
                // edge — so shape fit shrank a single outermost ring and left the rest
                // of the wall untouched. That is why it looked switched off.
                let member = TopOptKit.latticeMemberThicknessMM(
                    nx: tnx, ny: tny, nz: tnz,
                    spacing: SIMD3<Float>(repeating: Float(o.spacingMM)),
                    solid: cand)
                let fit = OrganicShapeFit.apply(spacing: sep, candidate: cand,
                                                nx: tnx, ny: tny, nz: tnz,
                                                voxelMM: o.spacingMM,
                                                window: o.jobWindowMM, only: false,
                                                memberMM: member.count == cand.count ? member : [],
                                                cellsAcrossMember: OrganicShapeFit.cellsAcrossMember)
                sep = fit.spacing
                fitNote = String(format: " · shape-fit: %d voxels shrunk (min ratio %.2f, depth %d, member %@)",
                                 fit.shrunk, fit.minRatio, fit.depthVoxels,
                                 member.count == cand.count ? "yes" : "UNAVAILABLE")
            }
            // ★★ THE BAND GRADE (2026-09-18): within `shapeBandMM` of a face outline the
            // spacing runs linearly from what it is down to the printable floor at the
            // outline — smaller cells — and the bead field below follows the spacing, so
            // the struts thicken too. The outline distance is the scene's own in-plane
            // field, sampled at the voxel's centre.
            if o.shapeBandMM > 0, let og = outlineForOrganic {
                let floorMM = OrganicSizeCheck.floor(beadMM: o.minExtrudableWidthMM, voxelMM: o.spacingMM).mm
                var graded = 0
                for e in 0..<cand.count where cand[e] {
                    let i = e % tnx, j = (e / tnx) % tny, k = e / (tnx * tny)
                    let p = SIMD3<Float>(Float(o.originMM.x + (Double(i) + 0.5) * o.spacingMM),
                                         Float(o.originMM.y + (Double(j) + 0.5) * o.spacingMM),
                                         Float(o.originMM.z + (Double(k) + 0.5) * o.spacingMM))
                    let d: Double
                    if bandRes != nil {
                        // ★ the band's grade is continuous and signed (negative through the rim), so
                        // a trilinear read reaches the floor exactly at the rim's inner face — no
                        // nearest-voxel beat between the trace grid and the preview grid
                        d = og.sampleLinear(SIMD3<Double>(p))
                    } else {
                        let gi = (p - og.origin) / og.spacing
                        let a = Int(gi.x.rounded()), b = Int(gi.y.rounded()), c = Int(gi.z.rounded())
                        guard a >= 0, b >= 0, c >= 0, a < og.nx, b < og.ny, c < og.nz else { continue }
                        d = Double(og.values[(c * og.ny + b) * og.nx + a])
                        guard d < 999 else { continue }
                    }
                    let t = Swift.min(Swift.max(d / o.shapeBandMM, 0), 1)
                    let target = Swift.min(sep[e], floorMM)
                    // ★ the AMOUNT of shrink, scaled by the strength (2026-09-18); never
                    // below the floor, so +1 reaches the floor sooner and holds it
                    let amount = LatticeSettings.gradeAmount(strength: o.shapeBandStrength)
                    let s2 = Swift.max(target, sep[e] - (sep[e] - target) * (1 - t) * amount)
                    if s2 < sep[e] - 1e-9 { sep[e] = s2; graded += 1 }
                }
                fitNote += String(format: " · shape band %.1f mm: %d voxels graded toward the %.2f mm floor",
                                  o.shapeBandMM, graded, floorMM)
            }
            // ── ★★★ THE PER-VOXEL BEAD, THE WAY THE RUN BUILDS IT ────────────────
            //
            // run_job.cpp, in the same loop that writes the separation:
            //     bead[e] = organic_strut_diameter_for(d, rho);
            //     if (!(bead[e] > min_extrudable_width_mm)) bead[e] = min_extrudable_width_mm;
            // and then `op.strut_diameter_field = &bead`. The preview handed core the
            // SCALAR only, so every curve in the picture was one thickness while the
            // file's vary with the local cell — the last of the run's organic
            // parameters the preview did not carry. A stated strut width is a fixed
            // bead in the run too (`bead[e] = t_fixed`), so it keeps the scalar.
            var beadMM: [Double] = []
            if n > 0, o.strutDiameterMM <= 0, hi - lo > 1e-9 {
                let rhoLo = o.rhoMin, rhoHi = Swift.max(o.rhoMax, o.rhoMin)
                // ★ CORE'S FUNCTION, TABULATED (2026-09-07). Both the separation and the
                // density are straight lines in the same parameter, so the bead is a
                // function of that one number — and calling across the bridge once per
                // voxel was 262,144 C++ calls per bake. The table is core's own function
                // evaluated at 1024 points of the window; a bead quantised to a
                // thousandth of the window is orders below anything a printer resolves,
                // and no law is re-derived here.
                let steps = 1024
                var table = [Double](repeating: 0, count: steps + 1)
                for k in 0...steps {
                    let f = Double(k) / Double(steps)
                    let d = hi - (hi - lo) * f
                    let rho = rhoLo + (rhoHi - rhoLo) * f
                    let b = TopOptKit.organicStrutDiameterMM(spacingMM: d, relativeDensity: rho)
                    table[k] = b > o.minExtrudableWidthMM ? b : o.minExtrudableWidthMM
                }
                beadMM = [Double](repeating: 0, count: cand.count)
                let span = hi - lo
                for e in 0..<cand.count where cand[e] && sep[e] > 0 {
                    let f = Swift.min(Swift.max((hi - sep[e]) / span, 0), 1)
                    beadMM[e] = table[Int((f * Double(steps)).rounded())]
                }
            }
            if n == 0 { organicWhyNot = "no candidate voxel: the declared region is empty on the solve's grid" }
            if n > 0 {
                // The field's own grid: the declared region's bbox, padded, at a voxel a
                // few times finer than the design grid — capped so a big part cannot
                // allocate an unbounded volume.
                var mn = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                var mx = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                for kk in 0..<occ.nz { for jj in 0..<occ.ny { for ii in 0..<occ.nx {
                    guard occ.values[(kk * occ.ny + jj) * occ.nx + ii] > 0.5 else { continue }
                    let p = occ.origin + SIMD3<Float>(Float(ii), Float(jj), Float(kk)) * occ.spacing
                    mn = simd_min(mn, p); mx = simd_max(mx, p)
                } } }
                let pad = Float(hi)
                mn -= pad; mx += pad
                let ext = mx - mn
                let longest = Swift.max(ext.x, Swift.max(ext.y, ext.z))
                // ~0.5 mm where the budget allows, never more than 12 M cells.
                var fs = organicBakeVoxelMM ?? Swift.max(0.35, Double(longest) / 384.0)
                while (Double(ext.x) / fs + 2) * (Double(ext.y) / fs + 2)
                        * (Double(ext.z) / fs + 2) > 12_000_000 { fs *= 1.25 }
                let fnx = Swift.max(2, Int(Double(ext.x) / fs) + 2)
                let fny = Swift.max(2, Int(Double(ext.y) / fs) + 2)
                let fnz = Swift.max(2, Int(Double(ext.z) / fs) + 2)
                // ★ THE BAKE REACH IS THICKNESS HEADROOM, NOT THE WINDOW (2026-09-04).
                // The field is the CENTRELINE distance now, clamped at reach = band +
                // the largest baked radius; the march only needs the true distance out
                // to the thickest strut the Thicker slider can ask for live. With the
                // 6 mm window as the band, 26,773 spans took 154 s to bake on a Mac (cost
                // ∝ reach²); at 1 mm of headroom the same bake is seconds.
                let band = Self.organicBakeHeadroomMM
                organicWhyNot = "core refused the trace (no curves), or the bake failed"
                // ★ A CACHED TOPOLOGY FIRST (2026-09-04): the same grid the trace would
                // use, the document's spans baked through the bridge — no trace, no
                // emission. The banner says where it came from.
                if let cached = organicCached,
                   let b = TopOptKit.organicSpansField(spans: cached.doc.spans, fieldDims: (fnx, fny, fnz),
                                                      fieldOrigin: SIMD3<Double>(mn), fieldSpacingMM: fs,
                                                      bandMM: band) {
                    let sp = SIMD3<Float>(repeating: Float(fs))
                    organicOut = LatticeVoxelGrid(nx: fnx, ny: fny, nz: fnz, origin: SIMD3<Float>(mn), spacing: sp, values: b.field)
                    organicSurfaceOut = LatticeVoxelGrid(nx: fnx, ny: fny, nz: fnz, origin: SIMD3<Float>(mn), spacing: sp, values: b.surfaceField)
                    organicBand = b.reachMM
                    organicWhyNot = nil
                    organicCapsOut = cached.doc.spans.map { OrganicCapsule($0) }
                    let census = cached.doc.metadata["census"] ?? ""
                    organicSaid = "\(b.spanCount) struts, " + String(format: "%.0f mm — %@ (3MF beam lattice)", cached.doc.totalLengthMM, cached.sourceLabel)
                        + (census.isEmpty ? "" : " · " + census)
                    organicSpanReceipt = (b.spanCount, cached.doc.totalLengthMM)
                } else if let t = TopOptKit.organicTrace(
                    nx: tnx, ny: tny, nz: tnz, spacingMM: o.spacingMM,
                    origin: o.originMM, candidate: cand, stressTensor: o.tensor,
                    separationMM: sep, minExtrudableWidthMM: o.minExtrudableWidthMM,
                    buildDirection: o.buildDirection,
                    fieldDims: (fnx, fny, fnz),
                    fieldOrigin: SIMD3<Double>(mn), fieldSpacingMM: fs,
                    bandMM: band, overhangAngleDeg: o.overhangAngleDeg,
                    rhoMin: o.rhoMin, rhoMax: o.rhoMax,
                    strutDiameterMM: o.strutDiameterMM, grow: o.grow,
                    layerHeightMM: o.layerHeightMM, anchorAtBoundary: anchorAtBoundary,
                    // ★ the ties, at last — see `LatticeOrganicInput.transferTies`
                    transferTies: o.transferTies, tieSwirl: o.tieSwirl, beadMM: beadMM,
                    showRepairs: o.showRepairs,
                    regionIDs: o.regionIDs, syntheticRegions: o.syntheticRegions,
                    seedRatio: seedRatios.seed, testRatio: seedRatios.test, minLengthRatio: seedRatios.minLength),
                   t.field.count == fnx * fny * fnz {
                    organicEmittedOut = t.spans
                    organicCapsOut = t.spans.map { OrganicCapsule($0) }
                    // ★★ WHAT FLOATS (his 2026-09-21 22:40: "SO MANY random small beams
                    // floating around the top, connecting with literally nothing"). Without
                    // repairs the bridge emits the curves' segments first, then the
                    // connectors (bridge.cpp, emit_repairs == 0). Every span end is hashed;
                    // an end with no other end within a quarter-millimetre is FREE. Spans
                    // with both ends free connect to nothing — counted by kind and length.
                    if !o.showRepairs, !t.spans.isEmpty {
                        let cell = 0.25
                        var ends: [SIMD3<Int>: Int] = [:]
                        func key(_ p: SIMD3<Double>) -> SIMD3<Int> { SIMD3<Int>(Int((p.x / cell).rounded(.down)), Int((p.y / cell).rounded(.down)), Int((p.z / cell).rounded(.down))) }
                        for sp in t.spans { ends[key(sp.a), default: 0] += 1; ends[key(sp.b), default: 0] += 1 }
                        func free(_ p: SIMD3<Double>) -> Bool {
                            let k = key(p)
                            var n = 0
                            for dz in -1...1 { for dy in -1...1 { for dx in -1...1 { n += ends[k &+ SIMD3(dx, dy, dz)] ?? 0 } } }
                            return n <= 1   // only itself
                        }
                        let connectorsFrom = max(0, t.spans.count - t.connectorCount)
                        var floating = [0, 0], oneFree = [0, 0], lens: [[Double]] = [[], []], floatLens: [[Double]] = [[], []]
                        for (i, sp) in t.spans.enumerated() {
                            let kind = i >= connectorsFrom ? 1 : 0
                            let L = simd_length(sp.b - sp.a)
                            lens[kind].append(L)
                            let fa = free(sp.a), fb = free(sp.b)
                            if fa && fb { floating[kind] += 1; floatLens[kind].append(L) } else if fa || fb { oneFree[kind] += 1 }
                        }
                        func q(_ v: [Double], _ f: Double) -> Double { v.isEmpty ? .nan : v.sorted()[min(v.count - 1, Int(Double(v.count - 1) * f))] }
                        NSLog("DIAG organic span census: curve segments %d (len p50 %.2f p95 %.2f mm, both ends free %d [len p50 %.2f], one end free %d) · connectors %d (len p50 %.2f p95 %.2f mm, both ends free %d [len p50 %.2f], one end free %d) · end hash cell %.2f mm",
                              lens[0].count, q(lens[0], 0.5), q(lens[0], 0.95), floating[0], q(floatLens[0], 0.5), oneFree[0],
                              lens[1].count, q(lens[1], 0.5), q(lens[1], 0.95), floating[1], q(floatLens[1], 0.5), oneFree[1], cell)
                    }
                    // ★ The verdict shown is the pre-trace one (it also stands on the cached
                    // path and when a trace fails). The trace made the same call on the same
                    // voxels; if its dead set ever differs, that is a bug to see, not hide.
                    if let ts = t.synthetic, organicSyntheticOut != nil, ts.deadRegionIDs != deadRegionIDs {
                        NSLog("DIAG synthetic: the trace's dead walls %@ differ from the pre-trace verdict %@",
                              ts.deadRegionIDs.sorted().description, deadRegionIDs.sorted().description)
                    }
                    if organicSyntheticOut == nil { organicSyntheticOut = t.synthetic }
                    organicPhaseOut = (t.traceSeconds, t.emitSeconds, t.bakeSeconds)
                    // ★ the tracer's own census, for his "not enough seeds" question (2026-09-21)
                    NSLog("DIAG organic trace census: curves %d connectors %d spans %d · %@%@ · %@ · band:%@",
                          t.curveCount, t.connectorCount, t.spanCount, t.stops.summary,
                          t.growth.map { g in String(format: " · grown: seeds %d curves %d steps %d blocked %d branches %d joins %d",
                                                     g.seeds, g.curves, g.steps, g.blocked, g.branches, g.joins) } ?? "",
                          t.census.summary, fitNote)
                    // ★★ THE FILL, MEASURED WHERE HE LOOKS (his 2026-09-21 19:08, "100% density of
                    // the full depth … still not working"). Every emitted span is rasterised into
                    // the trace grid; then, per include region, the share of CANDIDATE voxels that
                    // hold a strut — by in-plane distance from the face outline (with the spacing
                    // the tracer was asked there, after the band grade) and by depth decile into
                    // the wall. A number per band and per decile, before anyone says why.
                    do {
                        let caps = organicCapsOut
                        if !caps.isEmpty, o.regionIDs.count == cand.count {
                            var occ = [Bool](repeating: false, count: cand.count)
                            let h = o.spacingMM
                            func mark(_ p: SIMD3<Float>) {
                                let i = Int(((Double(p.x) - o.originMM.x) / h).rounded(.down))
                                let j = Int(((Double(p.y) - o.originMM.y) / h).rounded(.down))
                                let k = Int(((Double(p.z) - o.originMM.z) / h).rounded(.down))
                                guard i >= 0, j >= 0, k >= 0, i < tnx, j < tny, k < tnz else { return }
                                occ[(k * tny + j) * tnx + i] = true
                            }
                            for c in caps {
                                let d = c.b - c.a
                                let n = Swift.max(1, Int((Double(simd_length(d)) / (0.5 * h)).rounded(.up)))
                                for st in 0...n { mark(c.a + d * (Float(st) / Float(n))) }
                            }
                            let includes = regions.filter { $0.role == .include }
                            let edges: [Double] = [1, 2, 3, 4, 6, 1e9]
                            let labels = ["0–1", "1–2", "2–3", "3–4", "4–6", "6+"]
                            var lines: [String] = []
                            for (ri, r) in includes.enumerated() {
                                let id = Int32(ri + 1)
                                var binCand = [Int](repeating: 0, count: edges.count), binOcc = binCand
                                var binSep = [[Double]](repeating: [], count: edges.count)
                                var decCand = [Int](repeating: 0, count: 10), decOcc = decCand
                                let nrm = LatticeRegionMask.unit(r.normal)
                                var total = 0, totalOcc = 0
                                for e in 0..<cand.count where cand[e] && o.regionIDs[e] == id {
                                    total += 1; if occ[e] { totalOcc += 1 }
                                    let i = e % tnx, j = (e / tnx) % tny, k = e / (tnx * tny)
                                    let p = SIMD3<Double>(o.originMM.x + (Double(i) + 0.5) * h,
                                                          o.originMM.y + (Double(j) + 0.5) * h,
                                                          o.originMM.z + (Double(k) + 0.5) * h)
                                    if let og = outlineForOrganic {
                                        let gi = (SIMD3<Float>(p) - og.origin) / og.spacing
                                        let a = Int(gi.x.rounded()), b = Int(gi.y.rounded()), c = Int(gi.z.rounded())
                                        if a >= 0, b >= 0, c >= 0, a < og.nx, b < og.ny, c < og.nz {
                                            let d = Double(og.values[(c * og.ny + b) * og.nx + a])
                                            if d < 999 {
                                                let bi = edges.firstIndex { d < $0 } ?? edges.count - 1
                                                binCand[bi] += 1; if occ[e] { binOcc[bi] += 1 }
                                                binSep[bi].append(sep[e])
                                            }
                                        }
                                    }
                                    if r.depthMM > 0 {
                                        let into = simd_dot(p - r.origin, nrm) / r.depthMM
                                        let di = Swift.min(9, Swift.max(0, Int(into * 10)))
                                        decCand[di] += 1; if occ[e] { decOcc[di] += 1 }
                                    }
                                }
                                func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : String(format: "%.0f%%", 100 * Double(a) / Double(b)) }
                                func p50(_ v: [Double]) -> String { v.isEmpty ? "–" : String(format: "%.2f", v.sorted()[v.count / 2]) }
                                let bins = labels.indices.map {
                                    "\(labels[$0]) \(pct(binOcc[$0], binCand[$0])) of \(binCand[$0]) sep \(p50(binSep[$0]))"
                                }.joined(separator: ", ")
                                let decs = (0..<10).map { pct(decOcc[$0], decCand[$0]) }.joined(separator: " ")
                                lines.append(String(format: "r%d %@ depth %.2f mm · candidates %d occupied %@ · by outline mm: %@ · by depth decile: %@",
                                                    ri, r.selectableKey ?? "", r.depthMM, total, pct(totalOcc, total), bins, decs))
                            }
                            NSLog("DIAG organic fill (strut-occupied share of candidate voxels, voxel %.2f mm): %@", h, lines.joined(separator: " | "))
                        }
                    }
                    if t.syntheticVonMises.count == tnx * tny * tnz {
                        organicSynthFieldOut = StressField(
                            nx: tnx, ny: tny, nz: tnz,
                            origin: SIMD3<Float>(o.originMM), spacing: Float(o.spacingMM),
                            values: t.syntheticVonMises.map { Float($0) })
                    }
                    organicWhyNot = nil
                    organicSurfaceOut = LatticeVoxelGrid(
                        nx: fnx, ny: fny, nz: fnz, origin: SIMD3<Float>(mn),
                        spacing: SIMD3<Float>(repeating: Float(fs)), values: t.surfaceField)
                    organicOut = LatticeVoxelGrid(
                        nx: fnx, ny: fny, nz: fnz, origin: mn,
                        spacing: SIMD3<Float>(repeating: Float(fs)), values: t.field)
                    organicBand = Double(t.bandMM)
                    // ★ the counters ride the census (reviewer, 2026-09-04)
                    var counters: String = t.growth.map { " · " + $0.summary } ?? ""
                    counters += " · " + t.stops.summary
                    counters += " · " + t.census.summary
                    counters += " · " + t.phaseSummary
                    if !o.showRepairs { counters += " · ★ REPAIRS HIDDEN: the traced curves are shown; the file has the arches, legs and merges above" }
                    if seedRatios.seed > 0 { counters += String(format: " · seeding ×%.1f", o.seedBoost) }
                    var said = "\(t.curveCount) curves, \(t.connectorCount) connectors, "
                    said += String(format: "%.2f–%.2f mm spacing", t.spacingUsedMinMM, t.spacingUsedMaxMM)
                    said += gradedNote + fitNote
                    if solidRimVoxels > 0 { said += String(format: " · solid rim %.2f mm (%d voxels)", o.solidRimMM, solidRimVoxels) }
                    organicSaid = said + counters
                }
            }
        }
        tOrganic = Date().timeIntervalSince(sceneT0) - tOccupancy - tRegionField
        self.organicField = organicOut
        self.organicSurfaceField = organicSurfaceOut
        self.organicEmittedSpans = organicEmittedOut
        self.organicNotDrawnReason = (algorithm == "organic" && organicOut == nil) ? (organicWhyNot ?? "no stress tensor reached the tracer (the stage's solve has not produced one)") : nil
        self.organicSyntheticReport = organicSyntheticOut
        self.organicPhaseSeconds = organicPhaseOut
        // ★★★ THE DEPTH-STAGGER EXPERIMENT, APPLIED ONCE, AFTER EVERY PATH (his walk,
        // 2026-09-08: "the depth variation was ON for images 2 and 3. And OFF for 4 and
        // 5. Yet there is no difference").
        //
        // ★ IT WAS APPLIED INSIDE THE TRACE BRANCH ONLY. Four paths produce these
        // capsules — a pre-baked field, the run's own emitted spans, a cached 3MF
        // variant, and a fresh trace — and the part preview he was looking at does not
        // take the fourth. The toggle moved nothing because the deformation was sitting
        // in the one branch his picture never went through. It belongs here, where every
        // path has already put its geometry in one place.
        if let o = organic, o.depthStaggerCellMM > 0, !organicCapsOut.isEmpty {
            let staggered = OrganicDepthStagger.apply(
                spans: organicCapsOut.map {
                    (a: SIMD3<Double>($0.a), b: SIMD3<Double>($0.b), r: Double($0.r))
                },
                regions: regions, cellMM: o.depthStaggerCellMM,
                // ★ the sample cube declares no face; the build direction is its depth
                fallbackAxis: o.buildDirection)
            organicCapsOut = staggered.map { OrganicCapsule($0) }
            organicEmittedOut = staggered
        }
        self.organicCapsules = organicCapsOut
        self.organicSpanSource = organicSpanReceipt
        self.organicReceiptMismatch = organicMismatch
        let receiptLines = [organicReceipt?.certificateLine, organicReceipt?.contiguityLine,
                            organicReceipt?.spacingLine, organicReceipt?.repairsLine]
            .compactMap { $0 }
        self.organicReceiptSummary = receiptLines.isEmpty ? nil : receiptLines.joined(separator: " · ")
        self.organicBandMM = organicBand
        // ★ THE EXPERIMENT NAMES ITSELF WHEREVER THE LATTICE IS DESCRIBED.
        if let o = organic, o.depthStaggerCellMM > 0, !organicSaid.isEmpty {
            organicSaid += " · ★ DEPTH-STAGGER TEST: the drawn layers are offset after "
                + "tracing; the run builds the un-staggered weave"
        }
        self.organicSummary = organicSaid

        // ★★ AND WHETHER THAT DEMAND IS A MEASUREMENT (task 2026-08-20). `demand` has
        // TWO sources and they are not interchangeable: an FEA field, or a per-region
        // density the user STATED, inverted back into demand so the shader draws the
        // density they asked for. Sub-floor retention may only ever key on the first.
        // Core's rule is that an unmeasured region is not an unloaded one, and a
        // stated 17% is not a stress reading — arming retention off it would decide
        // "this wall carries nothing" from a number that never described load at all.
        // ★★ AND THE MEASURED FIELD IS KEPT SEPARATELY, ALWAYS (maintainer,
        // 2026-08-20: "I don't understand why we can't have the FEA that is already
        // run to hold the values required to say 'this is an unloaded wall' … We are
        // working on the Lattice *STAGE* meaning everything has to work in here").
        //
        // ★ HE IS RIGHT, AND `demand` WAS THE WRONG PLACE TO ASK. `demand` answers
        // "what density do I draw here", and a stated per-region density is allowed
        // to outrank the field for that — it is the user's own number. But "is this
        // wall loaded" is a different question and only the solve can answer it, so
        // it must not be routed through a value the user can overwrite. The stage
        // already ran the FEA; keeping it here is what makes the stage sufficient on
        // its own, with no variant and no results page.
        // ★★★ THE MAP PAINTS WHAT THE TRACER SAW (2026-09-07). When a wall asked for
        // synthetic stress, core replaced that wall's field before tracing; painting the
        // SOLVE's field instead left the synthetic load invisible in the only view that
        // shows where the part is working, and he reasonably read that as "it is not
        // happening". Falls back to the solve's field when no wall asked.
        let tDemandT0 = Date()
        self.stressDemand = LatticePreviewOccupancy.demand(
            like: occupancy, field: organicSynthFieldOut ?? stressField ?? field)
        self.demandIsMeasuredStress = self.stressDemand != nil
        // ★★★ EACH DECLARED FACE IS NORMALISED ON ITS OWN RANGE (his instruction,
        // 2026-09-08: "The front is relative - I'd like the back to be relative as well.
        // I want to be able to easily point to the actual foci!").
        //
        // ★ BOTH FACES WERE ALREADY IN THE SAME MODE. The map is one normalisation taken
        // across the WHOLE part, so a wall carrying 0.004 MPa beside one carrying 0.03
        // collapses into the bottom of a shared scale — every voxel on it the same
        // colour, and the synthetic foci, which are the whole reason the wall has a
        // field at all, unpointable. Giving each region its own p05…p95 makes the foci
        // legible on every wall.
        //
        // ★ AND IT CHANGES WHAT THE COLOUR MEANS, so it is said out loud: two walls can
        // no longer be compared by hue. The (i) beside "Synthetic stresses on unloaded
        // walls" carries that sentence.
        //
        // Region membership comes from the ids already computed on the TRACER's grid —
        // nearest-neighbour into it, one lookup per occupancy voxel. Re-deriving it here
        // would be a second point-in-polygon sweep over millions of voxels, which is the
        // 124-second bake this file already paid for once.
        if let o = organic, o.regionIDs.count == o.dims.0 * o.dims.1 * o.dims.2,
           var d = self.stressDemand {
            let (tnx, tny, tnz) = o.dims
            var idOf = [Int32](repeating: 0, count: d.values.count)
            var i = 0
            for k in 0..<d.nz {
                for j in 0..<d.ny {
                    for ii in 0..<d.nx {
                        let p = d.origin + SIMD3<Float>(Float(ii), Float(j), Float(k)) * d.spacing
                        let g = (SIMD3<Double>(p) - o.originMM) / o.spacingMM
                        let a = Int(g.x.rounded()), b = Int(g.y.rounded()), c = Int(g.z.rounded())
                        if a >= 0, b >= 0, c >= 0, a < tnx, b < tny, c < tnz {
                            idOf[i] = o.regionIDs[(c * tny + b) * tnx + a]
                        }
                        i += 1
                    }
                }
            }
            // The percentiles from a stride: a 128³ grid is 2.1 M values and the ends of
            // the ramp do not move between neighbours.
            var samples: [Int32: [Float]] = [:]
            let stride = Swift.max(1, d.values.count / 200_000)
            var s2 = 0
            while s2 < d.values.count {
                let id = idOf[s2]
                if id >= 1 { samples[id, default: []].append(d.values[s2]) }
                s2 += stride
            }
            var loHi: [Int32: (Float, Float)] = [:]
            for (id, var v) in samples where v.count >= 8 {
                v.sort()
                let lo = v[Int(0.05 * Double(v.count - 1))]
                let hi = v[Int(0.95 * Double(v.count - 1))]
                // ★★★ A FLAT FIELD IS NOT STRETCHED (his walk, 2026-09-08: "the synthetic
                // stress doesn't really show the foci as easily as expected … Why is it
                // so jumbled up? Shouldn't the red be ONLY in the center of the foci?").
                //
                // ★ CORE USED TO NORMALISE EVERY SYNTHETIC VOXEL TO THE SAME MAGNITUDE
                // (`target / tvm` per voxel), so a synthesised wall's von Mises map was flat
                // by construction. Core now applies ONE factor per region ("NORMALISE THE
                // REGION ONCE, NOT EACH VOXEL", organic_lattice.cpp), so the falloff
                // survives and the field peaks at the foci.
                //
                // Stretching p05…p95 of a flat field across the full ramp is stretching
                // ROUNDING NOISE, which is the speckle he was looking at. So a region is
                // still only renormalised when it has a real spread to show.
                if hi > lo, Double(hi - lo) > 0.05 * Double(abs(hi)) { loHi[id] = (lo, hi) }
            }
            if !loHi.isEmpty {
                for e in 0..<d.values.count {
                    guard let r = loHi[idOf[e]] else { continue }
                    d.values[e] = Swift.min(Swift.max((d.values[e] - r.0) / (r.1 - r.0), 0), 1)
                }
                self.stressDemand = d
            }
        }
        let tDemand = Date().timeIntervalSince(tDemandT0)

        // ★★ AFTER `demand` IS ASSIGNED, and that is the whole of a bug this very
        // nearly shipped. `demand` is a `var` with an implicit nil, so baking the
        // colours ABOVE its assignment read nil every time: `stressRGB` was always
        // nil, the overlay texture was never built, and the flag that gates it
        // (`stressTex != nil`) was never set — the stress overlay would have been
        // a setting that travels the whole way and draws nothing, which is the
        // exact defect this branch has now hit three times.
        //
        // ★★★ FROM THE **MEASURED** FIELD, NOT THE GRADING DEMAND (maintainer,
        // 2026-08-24 evening: "The lattice view doesn't have the actual stress
        // values *overlayed*... The lattice is blue but does not compare to the
        // look when the lattice is off").
        //
        // ★ IT WAS PAINTED FROM `demand` — the DENSITY input, which minimize
        // plastic caps by the true utilisation. On a part loaded to 0.1% of its
        // allowable that cap is ~0 everywhere, so every strut took the ramp's
        // bottom colour while the solid view (painted from the measured field,
        // percentile-normalised) showed the load paths. Two views of one part
        // disagreeing about one field. `stressDemand` is the measured field on
        // this same grid, normalised to its own percentile — its declaration
        // says it: "it answers 'where is this part working hardest', which is
        // the right question for the colour ramp". The grading keeps reading
        // `demand`; only the PAINT reads the measurement.
        var tTint = 0.0
        let tTintT0 = Date()
        if let d = self.stressDemand ?? self.demand {
            // RGBA8, matching `makeTintTexture` — the same upload path the
            // face-role tints already use, so there is one volume format here.
            // ★★★ THE RAMP IS A LOOKUP, NOT A FUNCTION CALL PER VOXEL (measured
            // 2026-09-07: 4.46 s of a 9.1 s sample bake, on a 128³ grid — 2.1 million
            // calls into `LatticeStressTint.colour` in a Debug build, for a texture with
            // 256 distinguishable values in it). The table is that same function,
            // sampled 256 times; the colours are identical to within a byte because a
            // byte is what they become.
            var lut = [UInt8](repeating: 0, count: 256 * 3)
            for k in 0..<256 {
                let c = LatticeStressTint.colour(fraction: Double(k) / 255.0)
                lut[k * 3] = UInt8(max(0, min(255, c.x * 255)))
                lut[k * 3 + 1] = UInt8(max(0, min(255, c.y * 255)))
                lut[k * 3 + 2] = UInt8(max(0, min(255, c.z * 255)))
            }
            var rgb = [UInt8](repeating: 0, count: d.values.count * 4)
            rgb.withUnsafeMutableBufferPointer { out in
                lut.withUnsafeBufferPointer { t in
                    d.values.withUnsafeBufferPointer { v in
                        for i in 0..<v.count {
                            let k = Int(max(0, min(255, v[i] * 255)).rounded())
                            out[i * 4] = t[k * 3]
                            out[i * 4 + 1] = t[k * 3 + 1]
                            out[i * 4 + 2] = t[k * 3 + 2]
                            out[i * 4 + 3] = 255
                        }
                    }
                }
            }
            self.stressRGB = rgb
            tTint = Date().timeIntervalSince(tTintT0)
        } else {
            self.stressRGB = nil
        }
        // ★★ CORE'S MEMBER FLOOR, MEASURED ONCE PER SCENE. `cap` is chosen from the
        // question being asked rather than copied: the floor only needs to know
        // whether a member is at least N* cells across, so a radius sweep past that
        // is wasted — anything beyond reads core's +inf "thicker than measured"
        // sentinel, which clears the floor anyway.
        let lim = TopOptKit.latticeLimits(topology: latticeID)
        // ★★★ THE FLOOR IN FORCE IS THE MODE'S, AND THIS IS THE ROOT OF THE 2.20 mm
        // CELL (maintainer, 2026-08-22: "The legend is still saying it's 2.2mm cells").
        //
        // ★ THIS LINE TOOK CORE'S ACCURACY FLOOR UNCONDITIONALLY, and it is the
        // DIVISOR every planner path uses: the auto window's ceiling is
        // `widest / minCellsPerMember`, the per-local-member cell is
        // `width / minCellsPerMember`, and the refusal is "is this member N* cells
        // across". So the aesthetic relaxation was being applied in ONE place — the
        // per-voxel array below — while five others kept dividing by 5. Fixing the
        // per-region derivation moved the number in the derivation and nowhere else,
        // which is why his card still read 2.20.
        //
        // ★ SO THE MODE DECIDES IT HERE, ONCE, and every divisor downstream is the
        // mode's by construction rather than by being individually remembered.
        // Structural is unchanged: its floor IS the accuracy floor.
        self.minCellsPerMember = lim.certifiable
            ? stageMode.cellsPerMemberFloor(topology: latticeID, utilisation: .nan,
                                            boundaryFinishWritten: boundaryFinishWritten)
            : 0
        if self.minCellsPerMember > 0 {
            // ★★★ MEASURED ON THE **PART**, NOT ON THE DECLARATION (maintainer,
            // 2026-08-22: "Find every reason why the two walls aren't *entirely* being
            // latticed").
            //
            // ★ THIS READ `occupancy`, WHICH IS `self.occupancy` — THE REGION-CLIPPED
            // GRID. So the "member thickness" was an EDT over the declared SLAB rather
            // than over the wall, and that is wrong in two directions at once:
            //
            //   • in DEPTH it measures the region's depth, not the wall. Declare 8 mm
            //     into an 11 mm wall and every voxel reports 8 mm of member.
            //   • IN PLANE it tapers to ZERO at the region's own boundary, because the
            //     clipped set simply ends there. The cells-per-member floor then refuses
            //     a full cell's worth of border around EVERY declared region — the
            //     lattice can never reach the edge of what he marked, at any setting.
            //
            // A member is a property of the PART. Core's own law reads the part's width
            // (`local_member_thickness_mm` over the design density), and the declaration
            // says WHERE to lattice, never how thick the material is. Measuring it on
            // the mask made the floor a function of the user's own depth control, which
            // is why a deeper region made MORE of the wall refuse rather than less.
            //
            // ★ AND IT POISONED EVERY WIDTH-DERIVED NUMBER DOWNSTREAM — the per-region
            // cell (`widthMM`), the Auto ceiling and ladder base (`boundsMM`,
            // `ladderBaseCellMM`) and the per-voxel floor all consume this array.
            let partSolid = solid.values.map { $0 > 0.5 }
            self.memberThicknessMM = TopOptKit.latticeMemberThicknessMM(
                nx: solid.nx, ny: solid.ny, nz: solid.nz,
                spacing: solid.spacing, solid: partSolid, capRadiusVoxels: 16)
        }

        // ★★★ THE AESTHETIC FLOOR, ONE VOXEL AT A TIME (maintainer, 2026-08-21: "If
        // aesthetic is selected then the floor number of cells can go down to 2").
        //
        // ★ THE UTILISATION IS CORE'S, NOT A RATIO OF THE FIELD'S OWN PEAK.
        // `stressDemand` above is normalised to the field's PERCENTILE — it answers
        // "where is this part working hardest", which is the right question for the
        // colour ramp and the wrong one here. The floor asks "what fraction of the
        // ALLOWABLE does this member carry", a physical quantity, so it is taken from
        // core's STRUCTURAL demand fraction (intent 0, demand / allowable). Reading the
        // aesthetic fraction here would have put the relaxed floor wherever the part is
        // quiet RELATIVE TO ITSELF, including on a part that is uniformly at yield.
        //
        // ★ AND IT IS NOT COMPUTED WITHOUT A MEASUREMENT. No field or no allowable
        // leaves the array empty, and every voxel then takes the accuracy floor.
        self.stageMode = stageMode
        self.algorithm = algorithm
        // ★★★ AESTHETIC: THE FLOOR IS FLAT, AND IT DOES NOT WAIT FOR A SOLVE
        // (maintainer, 2026-08-21: "The rule is we lattice *WHEREVER* it is asked of
        // us"). This used to be gated on a measured field AND a positive allowable and
        // then priced PER VOXEL from that voxel's utilisation — so the same wall
        // latticed or went solid depending on whether the FEA had landed yet, and the
        // parts of it doing real work went solid even after it had. Core's hard floor
        // is a constant, so this is now one call and one value.
        if stageMode == .aesthetic, self.minCellsPerMember > 0 {
            let f = LatticeStageMode.aesthetic.cellsPerMemberFloor(
                topology: latticeID, utilisation: .nan,
                boundaryFinishWritten: boundaryFinishWritten)
            if f > 0 {
                var floors = [Double](repeating: 0, count: occupancy.values.count)
                for i in 0..<occupancy.values.count where occupancy.values[i] > 0.5 {
                    floors[i] = f
                }
                self.cellsPerMemberFloorPerVoxel = floors
            }
        }
        self.bounds = mesh.bounds
        self.mesh = mesh
        // Counted here, where the grid is already in hand, so the banner never has to
        // walk it (§5b — the check runs on every SwiftUI body pass).
        var inside = 0
        for v in occupancy.values where v > 0.5 { inside += 1 }
        self.interiorVoxelCount = inside
        if algorithm == "organic" {
            let total = Date().timeIntervalSince(sceneT0)
            NSLog("DIAG scene phases: occupancy+partSDF %.2f s · region field %.2f s · organic %.2f s · demand \(String(format: "%.2f", tDemand)) s · tint \(String(format: "%.2f", tTint)) s · rest %.2f s · total %.2f s (grid %dx%dx%d)",
                  tOccupancy, tRegionField, tOrganic,
                  total - tOccupancy - tRegionField - tOrganic, total,
                  occupancy.nx, occupancy.ny, occupancy.nz)
        }
    }
}

extension LatticeSDFScene {
    /// ★★ THE PREVIEW'S DEAD-WALL VERDICT IS CORE'S (maintainer, 2026-09-29, ruling C).
    /// The run's own call (`synthesize_as_the_run` in the bridge: 0.02 and core's
    /// `kOrganicSyntheticDeadFloorMPa`) on the input's UNTOUCHED tensor, its per-voxel
    /// region ids and these candidates; the dead walls are `deadRegionIDs` of the
    /// report (`fully_synthetic > 0`). nil when no wall is offered or the ids do not fit.
    static func coreDeadWallVerdict(candidate: [Bool], input o: LatticeOrganicInput)
        -> TopOptKit.OrganicSyntheticReport? {
        guard !o.syntheticRegions.isEmpty, o.regionIDs.count == candidate.count else { return nil }
        return TopOptKit.organicSyntheticReport(
            nx: o.dims.0, ny: o.dims.1, nz: o.dims.2, spacingMM: o.spacingMM, origin: o.originMM,
            candidate: candidate, stressTensor: o.tensor, regionIDs: o.regionIDs,
            syntheticRegions: o.syntheticRegions)
    }
}

extension LatticeSDFScene: LatticeSDFPreviewSummary {
    public var previewLabel: String {
        preview?.previewLabel ?? "LATTICE PREVIEW — nothing to draw: no strut law for this type"
    }

    /// ★ ruling (g): whether an include region was emitted — the list the clip used.
    public var hasIncludeRegion: Bool { LatticeJobIncludeGate.hasIncludeWall(regions) }

    /// ★ WHAT THE BANNER SAYS THE RUN WILL BUILD. Empty when the job states nothing,
    /// because then the job IS doubled and there is nothing to caveat.
    public var algorithmName: String { algorithm }

    /// ★★ WHETHER THE PICTURE IS THAT ALGORITHM.
    ///
    /// ★ DOUBLED AND STEPPED BOTH ARE, NOW. The old rule was "only doubled", because
    /// the cell texture encoded a base cell plus an integer DYADIC level and stepped's
    /// cells are arbitrary reals. That was a fact about the ENCODING: the texture now
    /// carries a real cell SIZE per base cell, and the frame is built with the
    /// power-of-two assumption removed, so stepped is drawn as itself — including its
    /// unshared nodes at a region boundary, which is the algorithm and not a defect.
    ///
    /// ★★★ AND ORGANIC IS NOW ASKED, NOT ASSUMED (2026-08-22). This returned a
    /// CONSTANT `false` for organic, on the reasoning that "the march does not yet read
    /// that field" — which stopped being true when `lsdf_march` grew its
    /// `U.organicOrigin.w > 0.5` branch and `organicTex` was bound at fragment texture
    /// 5. The banner therefore said "shown as the doubled ladder; the run builds the
    /// organic lattice" on EVERY organic frame, whether or not organic had been traced.
    ///
    /// ★ THAT CONSTANT COST A WHOLE ROUND. The handoff of 2026-08-22 reads the banner as
    /// evidence that `organicForBake` returned nil — "imgs 3 and 4 still show the banner
    /// … i.e. `organicForBake` returned nil" — and sent the next agent hunting for a
    /// gate on that path. A flag that cannot change is not evidence of anything, and a
    /// caveat that is always on is the same defect as a caveat that is never on.
    ///
    /// So it asks the only question that decides the picture: is there an organic field
    /// to march? `organicField` is nil exactly when the trace did not happen or core
    /// declined, and non-nil exactly when the march draws core's own curves.
    ///
    /// ★ A CAVEAT THIS STILL CANNOT SEE: stepped is only DRAWN when a region actually
    /// derived a cell. When none did, the renderer falls back to the ladder and reports
    /// it as `LatticeSDFRenderer.steppedDrawn == false`; this scene-level flag has no
    /// way to know, because the decision is taken in the bake and the banner is built
    /// from the scene. On his part that fallback was silent for four rounds (see
    /// `LatticeMeasuredRegionWidth.widthMM`); the cause is fixed, the blind spot is not.
    public var algorithmDrawnFaithfully: Bool {
        switch algorithm {
        case "", "doubled", "stepped": return true
        case "organic": return organicField != nil
        default: return false
        }
    }
}

public extension LatticeSDFScene {
    /// The demand field the strut preview grades by AFTER a run (follow-up shipped
    /// with the maintainer's direct permission — see the handoff): the von Mises
    /// field of the NEWEST accepted variant carrying one, on the run's own grid.
    /// The savings ladder streams variants lighter-first-to-lightest-last, so the
    /// last accepted is the ladder's recommendation tier. Returns nil pre-run, for
    /// a cancelled run, or when no accepted variant carries a field (a remote run
    /// whose fields.bin fetch failed) — the preview then stays uniform and honest,
    /// exactly like the density proxy's no-field case.
    static func demandField(from outcome: OptimizeOutcome?) -> StressField? {
        guard let o = outcome else { return nil }
        for v in o.variants.reversed() where v.accepted && !v.vonMisesField.isEmpty {
            let f = StressField(nx: o.gridNx, ny: o.gridNy, nz: o.gridNz,
                                origin: SIMD3<Float>(o.gridOrigin), spacing: Float(o.spacing),
                                values: v.vonMisesField)
            if !f.isEmpty { return f }
        }
        return nil
    }
}

/// ★ NOT `@MainActor` (task 2026-08-18-unified-shading). It was, and `MeshRenderer` —
/// which is not, because `MTKViewDelegate` callbacks are not — could not touch it to
/// draw the lattice inside its own passes. It is the same class it was, driven from the
/// same main thread by the same callers; `MeshRenderer` next door has carried exactly
/// this shape (an NSObject MTKViewDelegate holding Metal objects) since M7.
final class LatticeSDFRenderer: NSObject, MTKViewDelegate {
    static var lastInitError: String?
    static let maxDPR: CGFloat = 2.0

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    /// The standalone transparent-layer pipeline. Nil when this instance exists only
    /// to OWN AND BAKE the lattice's volumes for `MeshRenderer`'s unified pass
    /// (`init(device:buildPipeline:)`) — that pass has its own pipelines, and
    /// compiling this one there would pay for a shader nobody in that path runs.
    private let pipeline: MTLRenderPipelineState?
    private let sampler: MTLSamplerState

    // Scene resources (rebuilt only on a data/param change — never per frame).
    // `cellTex` is the per-LATTICE-CELL activation+demand field (cellField): the
    // shader shows a strut iff its OWNING cell is active — the worker's whole-cell
    // emission — so the boundary is complete cells, never razor-cut struts.
    private var cellTex: MTLTexture?

    /// ★★ THE SHELL NEEDS TO SEE THIS TOO (maintainer, 2026-08-18: "The full body
    /// covered the lattice preview").
    ///
    /// ★ ONE SOURCE OF TRUTH, NOT TWO. The shell must stand down exactly where
    /// the raymarcher draws struts — and "exactly where" is this texture, the
    /// per-cell activation the march itself folds against. Re-deriving the region
    /// test in the shell shader would be a second answer to the same question,
    /// free to drift by a voxel and impossible to notice.
    var shellClipCellTexture: MTLTexture? { cellTex }
    /// The cell field's grid, so a model-space point can be turned into a texture
    /// coordinate by the shell exactly as the march does it.
    var shellClipGrid: (origin: SIMD3<Float>, spacing: SIMD3<Float>,
                        dims: SIMD3<Float>)? {
        guard let g = cellGrid else { return nil }
        return (g.origin, g.spacing,
                SIMD3(Float(g.nx), Float(g.ny), Float(g.nz)))
    }
    /// ★ THE SWEPT WINDOW THE USER ASKED FOR, or nil for a Fixed/Auto job — one
    /// cell everywhere. Set by the host from the project's own lattice settings, so
    /// the preview grades exactly when the RUN would grade and never otherwise.
    var cellSweep: LatticeCellSweep? {
        didSet { if cellSweep != oldValue, scene != nil { rebakeCellField() } }
    }
    /// ★★ FIT: the cell each declared region has to fit into, `W / N*`, one entry per
    /// region in the scene's own order (maintainer, 2026-08-20: "I set the cell size
    /// to Fit and it still looks like shit" — it did nothing, because only the SWEPT
    /// planner was wired). Fit chooses the cell so exactly N* fit across the member,
    /// so the cells-per-member floor is satisfied BY CONSTRUCTION and nothing is
    /// culled — which is why core is content to refuse Fit alongside retention.
    /// Empty ⇒ not a Fit job.
    var fitCellMM: [Double] = [] {
        didSet { if fitCellMM != oldValue, scene != nil { rebakeCellField() } }
    }
    /// ★★★ STEPPED: each declared region's own cell (mm), VERBATIM from core's
    /// `lattice_region_derivation` — one entry per region in the scene's order, 0 for a
    /// region with no cell. Empty ⇒ not a stepped job, and the ladder is drawn.
    ///
    /// ★ THE APP DOES NOT DERIVE THIS. Core's definition of stepped is "`Fit` without
    /// the dyadic snap", and Fit's cell already comes from that one core call — so
    /// stepped is the same number with the snap removed, not a second law.
    var steppedCellMM: [Double] = [] {
        didSet { if steppedCellMM != oldValue, scene != nil { rebakeCellField() } }
    }
    /// ★ THE GRADING OPTIONS (2026-08-25) — see `steppedCellField`. Defaults are
    /// every existing bake's behaviour.
    var steppedShapeFit: Bool = true {
        didSet { if steppedShapeFit != oldValue, scene != nil { rebakeCellField() } }
    }
    var steppedDyadicSteps: Bool = false {
        didSet { if steppedDyadicSteps != oldValue, scene != nil { rebakeCellField() } }
    }
    /// Per region, TRUE where the stepped cell is the USER'S OWN number.
    var steppedCellStated: [Bool] = [] {
        didSet { if steppedCellStated != oldValue, scene != nil { rebakeCellField() } }
    }
    /// ★ Whether the last bake actually laid down the STEPPED field. False when stepped
    /// was asked for but no region derived a cell — the ladder is drawn then, and the
    /// banner must keep saying so rather than claiming a picture it is not showing.
    private(set) var steppedDrawn = false
    /// ★ THE PLAN THE BAKE PLACED, published after every rebake (2026-09-18: "Send
    /// the cell list to core"): the octree's cells with the scene's regions, so the
    /// host can map region index → the job's include order and carry the list into
    /// `lattice.stepped_cells`. Empty when the bake was not the octree.
    var onSteppedCellsBaked: (([LatticeSteppedCell], [LatticeRegionSpec]) -> Void)?
    /// ★ SUB-FLOOR RETENTION, as the job carries it. Armed ⇒ the cells-per-member
    /// floor stands down where the declared set MEASURES as unloaded, exactly as
    /// `retain_subfloor_in_unloaded_regions` does in the run.
    var subfloorRetention: LatticeSubfloorRetention? {
        didSet { if subfloorRetention != oldValue, scene != nil { rebakeCellField() } }
    }
    /// ★ THE PRINTER'S BEAD (mm), for the second half of the printability law:
    /// the band floor rises to meet it (`proxyParams`), and a cell that cannot
    /// print at ANY certifiable density is left SOLID — core's
    /// `fallback_strut_unprintable`. 0 ⇒ no printer stated, and nothing is refused
    /// on a nozzle nobody named.
    var lineWidthMM: Double = 0 {
        didSet { if lineWidthMM != oldValue, scene != nil { rebakeCellField() } }
    }
    /// ★★ THE PRINTER'S LAYER HEIGHT (mm) — what the SOLID fill is banded at, so the
    /// material the run leaves solid is drawn as the layers that will actually be laid
    /// down there. 0 means no printer has been stated, and then no banding is drawn
    /// rather than a default one: a wrong layer count is a picture that lies about the
    /// part. No rebake — it changes only the SHADING, not which cells exist.
    var layerHeightMM: Double = 0
    /// ★ The part's build direction in MODEL space — `BuildOrientation.buildDirection`,
    /// which is +Z by default and moves when the orientation is baked. Drives the
    /// printed-layer banding, and (once organic is armed) the tracer's overhang cone.
    var buildDirection: SIMD3<Double> = SIMD3(0, 0, 1)
    /// ★★ WHY THE PREVIEW DREW NOTHING, WHEN IT DREW NOTHING (maintainer,
    /// 2026-08-20: "instead of showing an empty fucking wall we should have a way to
    /// recognize that it will happen and create a pop-up").
    ///
    /// ★ AN EMPTY REGION IS A RESULT, NOT AN ABSENCE. Measured on his part, a swept
    /// 2–4 mm window returns ZERO cells: at 2 mm his density's strut falls under the
    /// bead so core must coarsen it, and 4 mm needs a 20 mm member he does not have.
    /// Caught between "too fine to print" and "too coarse to certify", every cell
    /// falls back to solid — which is core behaving correctly and the preview showing
    /// a blank wall as though it had failed. The two causes have OPPOSITE remedies
    /// (a coarser cell, a thicker member), so naming which one is the whole value.
    private(set) var emptyReason: String?

    /// True when the last bake drew NOTHING because no certifiable density prints
    /// at this cell — so the viewport can say why it is empty.
    private(set) var cellUnprintable = false

    /// Whether the last bake actually retained anything — so the UI can say "kept,
    /// out of regime" rather than leaving the user to infer it from the picture.
    private(set) var subfloorRetained = false

    /// The last bake — kept so a caller can ask whether the cells on screen came
    /// from core's plan or from the uniform fallback.
    private(set) var cellField: LatticeCellField?
    /// ★ THE OUTLINE RIBBON — the solid outline as GEOMETRY (`LatticeOutlineRibbon`),
    /// rebuilt with every bake that hands out a band; `MetalMeshView` draws it in the
    /// depth prepass in the rim colour. `outlineRibbonVersion` bumps on every rebuild.
    private(set) var outlineRibbon: LatticeOutlineRibbon.Mesh?
    /// ★ GLOBALLY UNIQUE — a per-layer counter restarted at 0 whenever the layer was
    /// rebuilt on a settings change, matched the view's remembered value, and the
    /// view kept drawing the LAST layer's beam (his 15 and 5 mm grades wearing the
    /// 25 mm beam, 2026-09-16 19:21).
    private(set) var outlineRibbonVersion = 0
    /// ★ THE SOLID BEYOND EACH FACE PRISM'S FAR CAP (2026-09-18), built once per scene;
    /// drawn body-coloured by the depth prepass where the part continues past the cap.
    private(set) var regionCap: LatticeOutlineRibbon.Mesh?
    private(set) var regionCapVersion = 0
    private static var regionCapSerial = 0
    var solidOccupancyTexture: MTLTexture? { solidTex }
    var solidOccupancyGrid: LatticeVoxelGrid? { scene?.solidOccupancy }
    private var solidTex: MTLTexture?
    private static var outlineRibbonSerial = 0
    private var cellGrid: LatticeVoxelGrid?
    private var sdfTex: MTLTexture?
    /// The region field's texture, or a neutral 1×1×1 "everywhere inside" volume
    /// when nothing is declared — bound ALWAYS, because the shader declares it and
    /// Metal drops a draw whose declared texture is unbound.
    private var regionTex: MTLTexture?
    /// ★★★ THE BAND's fine rim grid (2026-09-26 redesign): `LatticeBandFine`'s texels as an
    /// rgba16Float volume, x fastest (r = B_r, g = K_s, b = dMat, a = q). nil ⇒ the scene has
    /// no band, and the neutral 1×1×1 of air is bound at index 6 instead.
    private var rimTex: MTLTexture?
    /// True when `regionTex.a` holds the band's B_r (`bandRimCoarse`) instead of the legacy
    /// skin field — see `fillBandUniforms`.
    private var regionTexCarriesBandRim = false
    private var neutralRimTex: MTLTexture?
    /// ★ The smooth rim normals' stand-in (index 7): no producer yet, so always neutral.
    private var neutralRimNormTex: MTLTexture?
    /// The stress-plot colours, for the overlay — see `LatticeSDFScene.stressRGB`.
    private var stressTex: MTLTexture?
    /// ★ Whether the host wants the stress plot ON the struts this frame. Off ⇒ the
    /// density ramp, which is every frame the stress view is not up.
    var stressOverlay = false
    /// ★ The boundary dressing the Finish setting asks for — see
    /// `LatticeBoundaryTreatment.previewDressingLevel`.
    var dressingLevel: Float = 0
    /// ★ The live strut radius (mm) the Thicker slider sets — a uniform, never a bake.
    var organicRadiusMM: Float = 0
    private var neutralRegionTex: MTLTexture?
    // Face-role tints on the LATTICE (bar A4): an rgba8 volume on the part-SDF grid,
    // baked from the SAME [FaceID: color] dictionary the mesh view tints the body
    // with — one source of truth, no second colour table. nil = no marked faces
    // (a 1×1×1 zero dummy is bound so the pipeline layout never changes).
    private var tintTex: MTLTexture?
    private lazy var dummyTintTex: MTLTexture? = makeDummyTintTexture()
    private var segBuffer: MTLBuffer?
    private var segCount: Int = 0
    private(set) var scene: LatticeSDFScene?

    // Interactive state. A cell-size change moves the lattice cells, so the per-cell
    // field rebakes ONCE on assignment (main thread, milliseconds) — still nothing
    // per frame; orbiting only changes the camera uniform.
    var camera = OrbitCamera()
    var params = LatticeProxyParams() {
        didSet {
            if params.cellMM != oldValue.cellMM, scene != nil { rebakeCellField() }
        }
    }

    // THE ONE MODEL TRANSFORM (2026-07-30 alignment fix). The mesh view draws the
    // body with mvp = P · V · T(centre) · R_settle · T(−centre) — the gravity settle
    // rotation about the model centre (MeshRenderer.makeUniforms/modelMatrix). The
    // lattice pass previously used P · V alone, so a settled part rendered its
    // lattice in the UN-settled frame: offset on some parts, floating clear on
    // others. These two fields carry the SAME (rotation, centre) the workspace hands
    // the mesh view, and `modelViewProjection` composes the identical matrix — one
    // transform, one camera, both derived from the shared workspace source.
    var modelRotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    var modelCenter = SIMD3<Float>.zero
    /// The viewport aspect (SwiftUI points) the SHARED scene is projected at. The
    /// lattice drawable is resolution-capped, so its own pixel dimensions round to
    /// integers a hair off the true viewport ratio; using the viewport's ratio keeps
    /// the lattice projection identical to the body's instead of scaled by ~1e-3.
    /// nil (offscreen tests) falls back to the drawable ratio.
    var viewportAspect: Float?

    /// Bumps every time a texture/segment buffer is (re)built.
    /// `LatticeSDFAlignmentTests.testNoBakeAcrossDrawsOrShadeParamChanges` asserts it
    /// does NOT change across encoded frames or shade-only param changes (Release
    /// builds strip `assert`, so the draw()-side assert alone proves nothing) — the
    /// P2 invariant that no bake happens per frame.
    private(set) var bakeGeneration: Int = 0

    /// - Parameter buildPipeline: `false` builds a BAKE-ONLY instance — the volumes,
    ///   the segment soup, the uniforms and nothing that draws. That is what
    ///   `MeshRenderer` holds for the unified pass (task 2026-08-18-unified-shading):
    ///   it owns its own colour and G-buffer pipelines, so compiling the standalone
    ///   transparent-layer one beside them would be a shader nobody there runs.
    init?(device: MTLDevice, buildPipeline: Bool = true) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { Self.lastInitError = "queue nil"; return nil }
        self.queue = queue
        if buildPipeline {
            let lib: MTLLibrary
            do { lib = try device.makeLibrary(source: Self.shaderSource, options: nil) }
            catch { Self.lastInitError = "makeLibrary: \(error)"; return nil }
            guard let vfn = lib.makeFunction(name: "lsdf_vertex"),
                  let ffn = lib.makeFunction(name: "lsdf_fragment") else {
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
            do { pipeline = try device.makeRenderPipelineState(descriptor: pd) }
            catch { Self.lastInitError = "pipeline: \(error)"; return nil }
        } else {
            pipeline = nil
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge; sd.rAddressMode = .clampToEdge
        guard let smp = device.makeSamplerState(descriptor: sd) else { Self.lastInitError = "sampler nil"; return nil }
        self.sampler = smp
        super.init()
    }

    // MARK: scene upload (the only place textures/segments change — bar P2)

    /// ★★★ THE PREVIEW MUST NEVER DRAW A HALF-SWAPPED SCENE (maintainer, 2026-08-23:
    /// "half-way through calculating, the quilt comes up and then eventually changes to
    /// the lattice. Can you make it so the quilt *never* comes up?").
    ///
    /// ★ THAT INTERMEDIATE IS A MISMATCH, NOT A STAGE OF THE BAKE. `setScene` publishes
    /// the new part and region textures IMMEDIATELY, but the cell field behind them takes
    /// the better part of a second to bake — so any frame in between draws the NEW
    /// geometry against the OLD cell sizes. Every cell reads at whatever the previous
    /// bake left there, which is precisely the uniform-cell, mid-cell-cap picture he
    /// calls the quilt.
    ///
    /// A serial pair makes the swap atomic to the renderer: the lattice layer is skipped
    /// entirely until the cell field that belongs to THIS scene has landed, so the frame
    /// shows the plain body instead of a lattice that describes neither scene.
    private var sceneSerial = 0
    private var bakedSerial = -1
    /// True once the cell field matches the scene currently published.
    var latticeFieldIsCurrent: Bool { bakedSerial == sceneSerial }

    func setScene(_ scene: LatticeSDFScene) {
        sceneSerial &+= 1
        self.scene = scene
        // ONE camera: this renderer's `camera` is purely a mirror of the shared
        // OrbitCameraModel (bound by the coordinator). It must NOT re-frame itself
        // here — the mesh view frames the shared model when a mesh lands, and that
        // framed camera is what both passes draw with. (Offscreen tests frame their
        // local camera explicitly.)
        uploadSegments(scene.preview?.segments ?? [])
        // ★ TWO CHANNELS (2026-09-26): r = the LATTICED part (every existing reader), g = the
        // part's own material, signed by the whole solid — the rim's "inside the model" bound
        sdfTex = makeCentrelineTexture(scene.partSDF, surface: scene.partMaterialSDF)
        solidTex = makeVolumeTexture(scene.solidOccupancy)     // the cap wall's "is the part here"
        regionTex = scene.regionSDF.flatMap { r in
            makeRegionTexture(r, outline: scene.outlineSDF, prism: scene.prismSDF, skinIn: scene.skinInSDF,
                              bandRim: scene.bandRimCoarse)
        }
        regionTexCarriesBandRim = regionTex != nil && scene.regionSDF.map { r in
            scene.bandRimCoarse?.values.count == r.values.count } == true
        // ★★★ THE BAND's own rim grid (nil ⇒ the legacy band path; the neutral is bound)
        rimTex = scene.bandFine.flatMap { makeBandTexture($0) }
        // ★★★ NO CAP (his rule R7, 2026-09-23: never a wall, plate, cap or beam inside
        // the pocket). The prism's far end inside material is the part's own solid; the
        // march draws it from the region field, and nothing is built for it.
        regionCap = nil
        Self.regionCapSerial &+= 1
        regionCapVersion = Self.regionCapSerial
        organicTex = scene.organicField.flatMap { d in
            scene.organicSurfaceField.map { makeCentrelineTexture(d, surface: $0) } ?? makeVolumeTexture(d)
        }
        uploadCapsules(scene.organicCapsules)
        stressTex = scene.stressRGB.flatMap { makeTintTexture($0, like: scene.partSDF) }
        tintTex = nil          // stale mesh/grid — the host re-applies tints after setScene
        rebakeCellField()
    }

    /// Bake (or clear) the face-role tint volume from the mesh view's OWN tint
    /// dictionary (bar A4 — one source of truth for the colours). Called by the host
    /// only when the tints or the scene actually change — never per frame (P2).
    func setFaceTints(_ tints: [FaceID: SIMD4<Float>]) {
        guard let scene else { return }
        if tints.isEmpty {
            if tintTex != nil { tintTex = nil; bakeGeneration &+= 1 }
            return
        }
        guard let rgba = LatticeFaceTintVolume.bake(mesh: scene.mesh, tints: tints,
                                                    like: scene.partSDF) else {
            if tintTex != nil { tintTex = nil; bakeGeneration &+= 1 }
            return
        }
        tintTex = makeTintTexture(rgba, like: scene.partSDF)
        bakeGeneration &+= 1
    }

    /// ★★★ HOW FINE STEPPED'S GRADE-TO-FIT MAY GO — a PRINTABILITY answer, and only that.
    ///
    /// It stops at the finest cell whose densest certifiable density still puts one whole
    /// extrusion across a strut, the same test `cellUnprintable` applies to the uniform
    /// cell. Below that the rim would be struts the printer cannot lay.
    ///
    /// ★ IT USED TO ALSO FLOOR AT ONE OCCUPANCY VOXEL, AND THAT KILLED THE FEATURE ON HIS
    /// OWN SETTINGS. At `Fast · 64` his voxel is ~3.4 mm against a 4.33 mm region cell, so
    /// the floor landed at 4.33, `nCap` came out 1, and NO subdivision was possible at any
    /// band width — the grade was dead on screen while a probe on a finer grid showed it
    /// working. The rule I borrowed belongs to core's DYADIC PLANNER, which owns a base
    /// cell only where a design voxel's centre lands in it. Stepped does not plan: the
    /// texel carries a cell SIZE and the shader tiles it analytically
    /// (`floor((cb - phase) / m)`), so a cell finer than a voxel draws exactly right. The
    /// only thing the voxel limits is how sharply the SIZE may vary in space, which is a
    /// smoothness question, not a floor.
    /// ★ INSTRUMENTATION ONLY — restore the pre-2026-08-28 ceiling test, so the two
    /// ladder floors can be compared on the device at one camera from one binary
    /// (handoff §5: judging a render of mine against a memory of his screen is how the
    /// worst regression of this task shipped). Nothing in the product sets it.
    static var floorTestAtCeiling: Bool {
        ProcessInfo.processInfo.environment["TOPOPT_LATTICE_FLOOR_AT_HI"] == "1"
    }

    // ★ THE REAL PRINTABLE FLOOR was four beads of cell (his 2026-09-14: "~1.8 mm"). RETIRED
    // 2026-10-05 (reviewer, Q3(i)): the floor is core's, read through `LatticeSettings.tileFloorMM`.
    /// The octree bake (2026-09-14); false falls back to the per-texel stepped bake.
    static var octreeBake: Bool = true

    private func steppedFinestPrintableCellMM(finest: Double) -> Double {
        guard finest > 0 else { return 0 }
        var s = finest
        while s > 0 {
            let half = s / 2
            if lineWidthMM > 0 {
                // ★★★ THE LADDER STOPS WHERE THE PRINTABILITY FLOOR STARTS TO BIND —
                // his ruling, 2026-08-28: *"Once you hit the printability floor go
                // solid."* This reverses the 2026-08-23 reading below, deliberately,
                // and both are kept here because the reversal is the whole point.
                //
                // ★ WHY THE CEILING TEST HAD TO GO. Measured on his own part
                // (`LatticeCurvedOutlineBandProbe.testTheDensityTheGradedBandIsDrawnAt`),
                // the floor RISES as the cell shrinks — a smaller cell cannot be
                // printed thin, one bead fills more of it:
                //
                //     5.16 mm -> 0.0%   1.72 mm -> 33.5%   1.43 mm -> 44.4%
                //     2.00 mm -> 26.5%  1.50 mm -> 41.0%   1.29 mm -> 52.1%
                //
                // Against `densitySpan.hi` (0.90) every one of those passes, so the
                // ladder ran to 1.29 mm and 369 cells were drawn at 52.1% — past the
                // 47.5% at which fix #1 measured an octet's struts MERGING into a
                // sheet with periodic holes. So the grade, whose job is to thin the
                // material out toward the outline, was making it DENSER, and the band
                // it left reads on screen as the holes he has been reporting.
                //
                // ★ THE SPARSEST DENSITY IS THE RIGHT TEST, for the reason the
                // 2026-08-23 note gives against itself: the strut is thinnest where
                // the density is LOWEST, so that is where printability binds. A rung
                // is permitted only while it can still be drawn at the density the
                // part is actually drawn at; the moment stepping down would force the
                // cell denser than that, the lattice has run out and the rest is
                // SOLID — *"ONLY WHEN NO MORE CAN FIT can you make the rest solid."*
                //
                // ★ THIS DOES **NOT** RESURRECT THE DEAD GRADE the 08-23 note warns
                // about. That reading pinned the floor at the region cell and left
                // `nCap = 1` because it also fed the SHAPE ladder, so nothing could
                // subdivide at all. What replaced the grade then was nothing; what
                // replaces the refused rungs now is solid, which is the behaviour he
                // asked for. `TOPOPT_LATTICE_FLOOR_AT_HI=1` restores the ceiling test
                // so both can be seen on the DEVICE, at one camera, from one binary.
                // ★ no strut law for the id (item a): nothing to stop on — no ladder below `finest`
                guard let law = params.lattice else { break }
                let rhoStar = law.printabilityDensityFloor(
                    lineWidthMM: lineWidthMM, cellMM: half)
                let bindsAt = Self.floorTestAtCeiling
                    ? params.densitySpan.hi : params.densitySpan.lo
                if rhoStar > bindsAt + 1e-9 { break }
            } else if half < 0.2 {
                break                       // no bead stated: a hard sanity stop
            }
            s = half
        }
        return s
    }

    /// ★★★ HOW DEEP THE SOLID RIM RUNS — half the finest cell the grade could reach.
    ///
    /// A cell whose centre sits closer than `S/2` to the outline cannot hold a strut
    /// node, so that is exactly the band the lattice can never fill however finely it
    /// grades. Filling precisely that much and no more keeps the solid to the residual
    /// rather than eating lattice the grade could have drawn.
    ///
    /// 0 for every non-stepped bake, so the doubled and organic paths are untouched.
    /// The dressing band in mm — see `rimParams`. A physical width, never a fraction of
    /// the local cell.
    private var dressingBandMM: Double {
        let skin = scene?.skinMM ?? 0
        return Swift.max(skin, Swift.max(2 * lineWidthMM, 0.2))
    }

    /// ★★★ HOW WIDE THE SOLID OUTLINE IS — the residual the lattice can never fill.
    ///
    /// A cell centred closer than this to the face's outline has no room for a node of
    /// its own size, so nothing can be latticed there and the material stays whole. It
    /// is the FINEST cell the grade can reach, floored at one occupancy voxel: the
    /// in-plane field lives on that grid, so its smallest non-zero value inside material
    /// IS one voxel and a narrower band could never be met.
    ///
    /// 0 on every non-stepped bake, so doubled and organic are untouched.
    /// ★★★ AND IT IS A FRACTION OF THE **LOCAL CELL**, NOT A MILLIMETRE (2026-08-26).
    /// This is the "empty space" he photographed for a week.
    ///
    /// The rule used to be `max(finestPrintableCell, oneVoxel)`. On his part that is
    /// `max(1.289, 1.719) = 1.719 mm` — and the in-plane distance is MEASURED on the
    /// occupancy grid, so its smallest non-zero value inside material is also one
    /// voxel. His own DIAG: `dCentre[min = 1.72]`. **The band and the field's floor
    /// were the same number**, so the test fired exactly where the field bottomed
    /// out, wherever that happened to be.
    ///
    /// ★ AND IT IS SAMPLED ONCE PER CELL. `lsdf_outline_mm` NEAREST-reads one float
    /// per BASE CELL — the distance the bake took at that cell's centre — so a
    /// 1.72 mm test is being evaluated on a 10.31 mm grid. A 6:1 lottery cannot make
    /// a ring; it makes a SCATTER of isolated solid cells in the middle of a wall.
    /// Measured on his own bake: 18 cells solid, and they included 2.58 / 3.00 /
    /// 3.44 / 4.00 mm graded cells nowhere near an outline. Solid renders
    /// `mix(denseColor, white, 0.55)` — pale and flat — and sits strictly inside the
    /// surface so the shell covers it, which is why it reads as EMPTY SPACE that
    /// still reports a cell size when tapped and does not move when he orbits.
    ///
    /// A fraction of the local cell is the resolution-independent form of the rule
    /// this band was always meant to express, and it is the file's own original
    /// justification: *"a cell whose centre sits closer than S/2 to the outline
    /// cannot hold a strut node"*. A third rather than a half keeps it a ring rather
    /// than a wide border. Measured against the same bake:
    ///
    ///     max(finestPrintable, voxel)  18 cells, incl. 2.58/3.00/3.44/4.00  <- scatter
    ///     0.50 · S                     27 cells, all 10.31/12.00
    ///     0.33 · S                     13 cells, all 10.31/12.00            <- this
    ///     0.25 · S                      7 cells, all 10.31/12.00
    ///
    /// Only the per-cell rules catch full-size boundary cells and nothing else.
    static let solidOutlineCellFraction: Double = 1.0 / 3.0

    /// ★ INSTRUMENTATION ONLY — override the fraction for one frame, so a probe can
    /// A/B the rim. `nil` is the shipping rule. Nothing in the app writes this.
    var debugSolidOutlineFraction: Double?

    /// The fraction of the LOCAL cell the march turns solid at the attached outline.
    /// 0 on every non-stepped bake, so doubled and organic are untouched.
    private var solidOutlineFraction: Double {
        if let d = debugSolidOutlineFraction { return d }
        guard !steppedCellMM.isEmpty else { return 0 }
        guard steppedCellMM.contains(where: { $0 > 0 }) else { return 0 }
        return Self.solidOutlineCellFraction
    }

    /// See `rebakeCellField` — TRUE only when the doubled ladder baked with
    /// declared regions, so the march may render its decided-solid cells as solid.
    private var doubledSolidCellsArmed = false

    private var steppedSolidRimMM: Double {
        // ★ NOT GATED ON `steppedDrawn` — that flag is only set at the END of a bake,
        // so reading it here made the rim 0.0 on the very bake that needed it and 0.9
        // only on the next one. `steppedCellMM` non-empty already means stepped.
        guard !steppedCellMM.isEmpty else { return 0 }
        let stated = steppedCellMM.filter { $0 > 0 }
        guard let finest = stated.min(), finest > 0 else { return 0 }
        // ★ AT LEAST TWO EXTRUSIONS WIDE. Half the finest cell is the band the lattice
        // provably cannot reach, but on a fine grade that is a fraction of a millimetre —
        // thinner than the printer can lay as a wall, and invisible. A solid edge that
        // ties the lattice into an attached wall has to be buildable to be worth drawing.
        let residual = 0.5 * steppedFinestPrintableCellMM(finest: finest)
        // Three extrusions: thin enough to stay the residual, thick enough to read as
        // a solid edge rather than an aliasing artefact.
        return Swift.max(residual, 3 * lineWidthMM)
    }

    /// ★ WHERE THE PART IS ATTACHED: the part's own material OUTSIDE the latticed
    /// set, per occupancy voxel — the seed for the attached-only rim (his rule,
    /// 2026-08-24). A voxel of air outside the region seeds nothing, so an outline
    /// edge open to the world grows no solid rim.
    ///
    /// ★★ NOT FROM `partSDF` — that field's SIGN comes from the REGION-CLIPPED
    /// occupancy (`signedDistance(like: occupancy)`), so nothing outside the
    /// declared regions is ever negative and a seed read off it is empty
    /// (measured: 0 of 416,490 empty voxels). `memberThicknessMM` is computed over
    /// the WHOLE-PART solid on the same grid — positive (or +inf, the EDT-cap
    /// sentinel) exactly where the part has material — so it is the honest mask.
    /// nil when the scene carries no thickness field: the caller then seeds the
    /// full outline, which is the pre-rule behaviour, not a guess.
    static func attachedSeed(scene: LatticeSDFScene) -> [Bool]? {
        let occ = scene.prismOccupancy          // ★ material OUTSIDE THE PRISM seeds the rim, never a slab edge
        let mm = scene.memberThicknessMM
        guard mm.count == occ.values.count else { return nil }
        var seed = [Bool](repeating: false, count: occ.values.count)
        for i in 0..<seed.count where occ.values[i] <= 0.5 && mm[i] > 0 {
            seed[i] = true
        }
        // ★ AND THE SKIN + RIM INSIDE THE PRISM (2026-09-23): under an unselected face the
        // lattice runs alongside — and along the solid-backed outline — the region field
        // is solid inside the prism; the grade seeds from that band's inner edge too.
        if let f = scene.regionSDF, let q = scene.prismSDF, f.count == seed.count, q.count == seed.count {
            for i in 0..<seed.count where !seed[i] && q.values[i] < 0 && f.values[i] >= 0 { seed[i] = true }
        }
        return seed
    }

    /// Bake the per-cell activation+demand texture for the CURRENT cell size. Called
    /// from `setScene` and from a cell-size param change — never from `draw`.
    private func rebakeCellField() {
        guard let scene else { return }
        // ★★★ NEVER BAKE THE WRONG ALGORITHM (his standing rule — the quilt "must
        // never come up"). When the scene says STEPPED but the per-region cells
        // have not reached this layer yet (they arrive through a separate property
        // write), the old fallthrough baked the DYADIC LADDER and marked it
        // current — the wrong algorithm on screen for the frames until the cells
        // landed. The host now replays its state onto a fresh layer before the
        // first bake, so this gate should never fire; it stands anyway, because a
        // deferred bake (the layer simply stays hidden — `latticeFieldIsCurrent`
        // false) is strictly better than a wrong picture.
        // ★ STEPPED ONLY. Doubled with no per-region cells falls through to the
        // dyadic ladder below, which IS doubled at a coarser plan — the same
        // algorithm, not a wrong one — so a doubled scene never hides itself
        // (`LatticeThreeAlgorithmsDrawTests` renders one with no cells at all).
        if scene.algorithm == "stepped",
           steppedCellMM.isEmpty || steppedCellMM.count != scene.regions.count,
           LatticeJobIncludeGate.hasIncludeWall(scene.regions) {
            NSLog("DIAG stepped bake DEFERRED — algorithm is stepped but "
                  + "steppedCellMM has \(steppedCellMM.count) entries for "
                  + "\(scene.regions.count) regions; layer stays hidden rather "
                  + "than baking the ladder")
            return
        }
        // ★ DOES THE DECLARED SET QUALIFY FOR RETENTION? Core's own arithmetic, on
        // core's own ceiling — and its guard that no demand field means no retention,
        // because an unmeasured region is not an unloaded one.
        let retains = subfloorQualifiesNow(scene)
        subfloorRetained = retains
        var baked: LatticeCellField?
        var octreeCells: [LatticeSteppedCell] = []
        defer { onSteppedCellsBaked?(octreeCells, scene.regions) }
        // ★ ONE CANDIDATE MAP AND ONE IN-PLANE FIELD PER BAKE. The candidate array
        // was built THREE times per bake (fit field, rim field, diagnostics) and
        // the in-plane distance BFS ran twice — the diagnostics block re-ran the
        // whole multi-source sweep just to print two numbers. On his 128-grid
        // part that is real seconds of "quite some time to load" for nothing.
        // ★ the boundary distance and the widths read the WHOLE prism (review #21): the
        // slab's edges are not boundaries, and a rim at them was the wall he kept seeing
        let candidate = scene.prismOccupancy.values.map { $0 > 0.5 }
        var steppedBoundary: [[Double]?] = []
        // ★★★ STEPPED IS TRIED FIRST, AND THAT ORDER IS THE WHOLE POINT (maintainer,
        // 2026-08-22: "I attempted a Stepped lattice preview and it didn't work").
        //
        // ★ IT WAS GATED ON `baked == nil` AND SAT AFTER THE PLANNER, so on any job
        // with a sweep — which is every Auto and Swept job, i.e. his — the dyadic
        // planner filled `baked` first and stepped never ran at all. Stepped is not a
        // fallback from the ladder, it is the ALTERNATIVE to it: "Fit WITHOUT the
        // dyadic snap". So it is asked first, and the ladder is what happens when no
        // region stated a cell.
        if !steppedCellMM.isEmpty, steppedCellMM.count == scene.regions.count {
            let stated = steppedCellMM.filter { $0 > 0 }
            // ★★ Q3(i) (reviewer, 2026-10-05): the finest tile is core's printable floor at the
            // job's cap (`LatticeSettings.tileFloorMM`), not four beads. nil = core gave no
            // number for this type: nothing is baked on a made-up floor. No bead, no floor (0).
            let tileFloorMM: Double? = lineWidthMM > 0
                ? LatticeSettings.tileFloorMM(topologyID: params.latticeID, beadMM: lineWidthMM,
                                              allowQuilt: scene.allowQuilt)
                : 0
            if tileFloorMM == nil {
                NSLog("DIAG stepped NOT BAKED — no core floor for \(params.latticeID): \(TopOptKit.lastCoreRefusal ?? "-")")
            }
            if let finest = stated.min(), finest > 0, let tileFloorMM {
                baked = LatticePreviewOccupancy.steppedCellField(
                    occupancy: scene.occupancy, demand: scene.drawnDemand ?? scene.demand,
                    regions: scene.regions, cellMM: steppedCellMM,
                    baseCellMM: finest,
                    regionPhase: Self.faceTilingPhase(
                        regions: scene.regions, cellMM: steppedCellMM,
                        fallbackCellMM: finest, origin: scene.occupancy.origin),
                    memberThickness: scene.memberThicknessMM,
                    minCellsPerMember: retains ? 0 : scene.minCellsPerMember,
                    cellsPerMemberFloor: retains ? [] : scene.cellsPerMemberFloorPerVoxel,
                    // ★★★ GRADE TO FIT SHAPE REACHES STEPPED (maintainer, 2026-08-23:
                    // "still not seeing the grade to fit shape" — because stepped wrote
                    // ONE cell per region and there was nothing to vary).
                    // ★ IN-PLANE, PER REGION — the distance to the FACE'S OUTLINE with
                    // the thickness direction dropped (his ruling: the thickness "is
                    // already covered by the floor"). Measured in 3-D it is ~half the
                    // wall thickness everywhere and moves 2.9% of the cells; in-plane it
                    // spans the face.
                    boundaryDistancePerRegion: {
                        steppedBoundary = LatticeBoundaryDistance.inPlanePerRegion(
                            regions: scene.regions,
                            candidate: candidate,
                            nx: scene.occupancy.nx, ny: scene.occupancy.ny,
                            nz: scene.occupancy.nz, spacing: scene.occupancy.spacing)
                        return steppedBoundary
                    }(),
                    // ★ THE WALL PER VOXEL, along each region's own normal (his ruling,
                    // 2026-08-24) — so a cell over a thin sliver divides to what its
                    // own material holds instead of the sliver pinning the whole face.
                    widthPerRegion: scene.regions.map { r in
                        r.kind == .face && r.role == .include
                            ? LatticeMeasuredRegionWidth.wallWidthFieldAlongNormalMM(
                                region: r, occupancy: scene.prismOccupancy,
                                partSDF: scene.partMaterialSDF)
                            : nil
                    },
                    // ★★★ THE RIM ONLY WHERE THE WALL IS ATTACHED (his rule: solid at
                    // chamfers and wall-to-floor junctions, "never on faces open to
                    // the world — those are the finish's job"). The seed is the part's
                    // own material OUTSIDE the latticed set, so an outline edge that
                    // abuts air seeds nothing and grows no rim; the FIT above keeps
                    // the full outline — a cell must fit the shape at open edges too.
                    rimDistancePerRegion: LatticeBoundaryDistance.inPlanePerRegion(
                        regions: scene.regions,
                        candidate: candidate,
                        nx: scene.occupancy.nx, ny: scene.occupancy.ny,
                        nz: scene.occupancy.nz, spacing: scene.occupancy.spacing,
                        seed: Self.attachedSeed(scene: scene)),
                    // The finest cell that still prints a bead-wide strut — the halving
                    // stops here rather than at the edge, so the rim is buildable.
                    finestCellMM: steppedFinestPrintableCellMM(finest: finest),
                    realFloorMM: tileFloorMM,
                    shapeFitBandMM: params.shapeFitBandMM,
                    // ★ THE STRUT MUST STAY ONE BEAD WIDE AS THE CELL SHRINKS, so the
                    // bake needs the printability law and the band it may move inside.
                    lineWidthMM: lineWidthMM,
                    densityLo: params.densitySpan.lo,
                    densityHi: params.densitySpan.hi,
                    densityGamma: params.gamma,
                    latticeID: params.latticeID,
                    shapeFit: steppedShapeFit,
                    dyadicSteps: steppedDyadicSteps,
                    cellIsUserStated: steppedCellStated,
                    bandQuiltCeiling: LatticeType.named(params.latticeID)?.hasAestheticCeiling == true && !scene.allowQuilt
                        ? scene.drawnCeilingRho : 1)
            }
            // ★★★ THE OCTREE BAKE replaces the per-coarse-texel decision (his 2026-09-14
            // rules: fewest cells, largest that fit, smallest only where nothing larger
            // goes, solid for the rest). `octreeBake` false is the revert switch.
            if Self.octreeBake, let finest = stated.min(), finest > 0, let tileFloorMM {
                var st = LatticePreviewOccupancy.OctreeBakeStats()
                // ★ THE SOLID OUTLINE'S WIDTH: two beads at least, and never less than
                // the march's own trim plus half a voxel, so the struts of the cells
                // beyond it (clipped by the trimmed, voxel-sampled part) always end
                // inside the solid rather than a hair short of it.
                let voxelMM = Double(max(scene.occupancy.spacing.x, max(scene.occupancy.spacing.y, scene.occupancy.spacing.z)))
                // Only when the shape grade is on: the outline is the grade's frame.
                let solidBandMM = steppedShapeFit ? Self.outlineBeamMM(lineWidthMM: lineWidthMM, voxelMM: voxelMM) : 0
                if let o = LatticePreviewOccupancy.octreeCellField(
                    occupancy: scene.prismOccupancy, demand: scene.drawnDemand ?? scene.demand,
                    regions: scene.regions, cellMM: steppedCellMM,
                    lineWidthMM: lineWidthMM,
                    realFloorMM: tileFloorMM,
                    shapeFitBandMM: params.shapeFitBandMM,
                    shapeFit: steppedShapeFit,
                    solidBandMM: solidBandMM,
                    densityLo: params.densitySpan.lo, densityHi: params.densitySpan.hi,
                    densityGamma: params.gamma, latticeID: params.latticeID,
                    // ★ Default Grade is core's "doubled": the same bake, halves only.
                    dyadicSteps: steppedDyadicSteps,
                    // ★ Structural: the printability floor alone bounds the menu.
                    finestPrintsOpen: scene.stageMode != .structural,
                    bandAmount: LatticeSettings.gradeAmount(strength: params.shapeFitGradeStrength),
                    // ★ no quilt in the grade band either unless Allow quilt (his 2026-09-28)
                    bandQuiltCeiling: LatticeType.named(params.latticeID)?.hasAestheticCeiling == true && !scene.allowQuilt
                        ? scene.drawnCeilingRho : 1,
                    stats: &st) {
                    baked = o
                    octreeCells = o.steppedCells
                    let kept = st.slotsKept.keys.sorted(by: >)
                        .map { String(format: "%.2f=%d", $0, st.slotsKept[$0]!) }.joined(separator: " ")
                    let why = st.why.keys.sorted().map { "\($0)=\(st.why[$0]!)" }.joined(separator: " ")
                    NSLog("DIAG octree pitch=\(String(format: "%.2f", st.pitchMM)) kept=[\(kept)] edge=\(st.slotsCut) "
                          + "texels=\(st.texelsPainted) band=\(params.shapeFitBandMM) floor=\(tileFloorMM) "
                          + "solidBand=\(String(format: "%.2f", solidBandMM)) anchor=\(String(format: "(%.1f,%.1f,%.1f) in %.1fs", st.anchorShiftMM.x, st.anchorShiftMM.y, st.anchorShiftMM.z, st.anchorSeconds)) drawnHi=\(o.drawnDensityHi) "
                          + "why=[\(why)] noLadder=\(st.noLadderRegions) t=\(String(format: "%.2f", st.seconds))s "
                          + "walk=anchor:\(st.anchorSlotsWalked) place:\(st.placeSlotsWalked) shifts=\(st.anchorBaseVolumes.count) "
                          + "fp=\(st.footprintBounded.keys.sorted().map { "\($0)=\(st.footprintBounded[$0]!)" }.joined(separator: ",")) "
                          + "unb=\(st.footprintUnbounded.keys.sorted().map { "\($0)=\(st.footprintUnbounded[$0]!)" }.joined(separator: ",")) "
                          + "raster=\(String(format: "%.1f", st.rasterSeconds))s place=\(String(format: "%.1f", st.placeSeconds))s")
                }
            }
        }
        // ★ THE BAKE, SAID OUT LOUD. Every "no grading" report so far has been a
        // different link in this chain, and inferring which one from a screenshot has
        // cost several rounds. This prints what the stepped path actually decided.
        if !steppedCellMM.isEmpty {
            let stated = steppedCellMM.filter { $0 > 0 }
            let finest = stated.min() ?? 0
            let floorMM = steppedFinestPrintableCellMM(finest: finest)
            // Why the grading block may be skipped: an EMPTY per-region array (no
            // regions on the scene) or a NIL entry (the face is not axis-aligned, so it
            // has no plane to drop) are different failures with different fixes.
            do {
                let sc = scene
                // ★ THE FIELD THE BAKE ALREADY BUILT — recomputing the whole BFS
                // for a log line was a third of the bake's cost.
                let pr = steppedBoundary.isEmpty
                    ? LatticeBoundaryDistance.inPlanePerRegion(
                        regions: sc.regions,
                        candidate: candidate,
                        nx: sc.occupancy.nx, ny: sc.occupancy.ny,
                        nz: sc.occupancy.nz, spacing: sc.occupancy.spacing)
                    : steppedBoundary
                let nonNil = pr.filter { $0 != nil }.count
                let dmax = pr.compactMap { $0?.max() }.max() ?? 0
                let normals = sc.regions.map {
                    String(format: "(%.2f,%.2f,%.2f)/\($0.role)",
                           $0.normal.x, $0.normal.y, $0.normal.z) }
                NSLog("DIAG stepped fields sceneRegions=\(sc.regions.count) "
                      + "perRegion=\(pr.count) nonNil=\(nonNil) dmax=\(dmax) "
                      + "normals=\(normals)")
            }
            var hist: [Float: Int] = [:]
            for v in baked?.steppedCellMM ?? [] where v > 0 { hist[v, default: 0] += 1 }
            let sizes = hist.keys.sorted()
                .map { String(format: "%.2f=%d", $0, hist[$0]!) }.joined(separator: " ")
            NSLog("DIAG rim dressing=\(dressingBandMM) outlineFrac=\(solidOutlineFraction) lineWidth=\(lineWidthMM) "
                  + "steppedDrawn=\(baked != nil)")
            NSLog("DIAG stepped regions=\(steppedCellMM.count) stated=\(stated) "
                  + "finest=\(finest) printableFloor=\(floorMM) "
                  + "nCap=\(finest > 0 && floorMM > 0 ? Int(finest / floorMM) : 0) "
                  + "bandMM=\(params.shapeFitBandMM) baked=\(baked != nil) sizes=[\(sizes)]")
        } else {
            NSLog("DIAG stepped NOT RUN — steppedCellMM empty "
                  + "(algorithm is not \"stepped\", or no region stated a cell)")
        }
        steppedDrawn = baked != nil
        defer { bakedSerial = sceneSerial }
        // ★ Whether the DOUBLED path's inactive cells should render solid — armed
        // only when the ladder baked against declared regions, so a whole-part
        // lattice (and every stepped/organic bake) is byte-identical. See the
        // march's rimParams.z branch.
        doubledSolidCellsArmed = false
        if baked == nil, let sweep = cellSweep {
            baked = gradedCellField(scene: scene, sweep: sweep, retains: retains)
            if baked != nil,
               LatticeJobIncludeGate.hasIncludeWall(scene.regions) {
                doubledSolidCellsArmed = true
            }
        }
        // ★★ CAN ANYTHING PRINT AT THIS CELL AT ALL? The band floor has already
        // risen to the printability floor, so the usual answer is yes and every
        // strut clears a bead. When even core's DENSEST certifiable density cannot
        // reach one bead at this cell, no density in the band prints and the run
        // leaves the whole thing solid — so the preview draws nothing rather than
        // a lattice that cannot be built. This is the half of the printability law
        // that densifying cannot cover.
        cellUnprintable = false
        if lineWidthMM > 0, params.cellMM > 0 {
            // ★ no strut law for the id (item a): nothing buildable to draw — the empty field,
            // never octet's struts under another type's name
            if let law = params.lattice {
                let rhoStar = law.printabilityDensityFloor(
                    lineWidthMM: lineWidthMM, cellMM: params.cellMM)
                if rhoStar > params.densitySpan.hi + 1e-9 { cellUnprintable = true }
            } else {
                cellUnprintable = true
            }
        }
        if cellUnprintable {
            // ★★ AND IT COSTS NOTHING TO SAY SO. Baking an EMPTY field at the
            // rejected cell still sizes the grid by that cell — at 0.35 mm over his
            // 221 mm part that is 631³ ≈ 251 M cells, and the first version of this
            // guard spent TWENTY MINUTES building a volume whose every entry it had
            // already decided was −1. The whole point is that nothing is drawn, so
            // there is nothing to size: one texel, inactive, and the march's bounds
            // check rejects every sample against it.
            //
            // ★ THIS IS ALSO THE USER-FACING BUG. A fine cell with a coarse nozzle
            // is a setting anyone can type, and before this it hung the app rather
            // than answering "nothing here can be printed".
            let occ = scene.occupancy
            let empty = LatticeVoxelGrid(nx: 1, ny: 1, nz: 1,
                                         origin: occ.origin,
                                         spacing: SIMD3<Float>(repeating: Float(params.cellMM)),
                                         values: [-1])
            cellField = LatticePreviewOccupancy.uniformCellField(empty, cellMM: params.cellMM)
            // ★ AND SAY WHY, ON THIS PATH TOO. This branch returns EARLY, so the
            // diagnosis below never ran and `emptyReason` kept whatever the PREVIOUS
            // bake had said — a 0.35 mm cell reported "members too thin at 8.00 mm",
            // which is the wrong cause, the wrong number and the opposite remedy.
            // A stale explanation is worse than none: it sends him to thicken a wall
            // when the nozzle is the problem.
            emptyReason = diagnoseEmpty(scene: scene, field: cellField!)
            cellGrid = empty
            cellTex = makeCellTexture(cellField!)
            bakeGeneration &+= 1
            return
        }
        if baked == nil {
            // The uniform path — what a Fixed or Auto job actually builds. Retention
            // drops the cells-per-member ceiling and NOTHING else; the printability
            // floor and the density band are untouched, as in core.
            let grid = LatticePreviewOccupancy.cellField(
                occupancy: scene.occupancy, demand: scene.demand, cellMM: params.cellMM,
                memberThickness: scene.memberThicknessMM,
                minCellsPerMember: retains ? 0 : scene.minCellsPerMember,
                cellsPerMemberFloor: retains ? [] : scene.cellsPerMemberFloorPerVoxel)
            baked = LatticePreviewOccupancy.uniformCellField(grid, cellMM: params.cellMM)
        }
        guard let field = baked else { return }
        emptyReason = diagnoseEmpty(scene: scene, field: field)
        cellField = field
        outlineRibbon = Self.buildOutlineRibbon(scene: scene, field: field)
        Self.outlineRibbonSerial &+= 1
        outlineRibbonVersion = Self.outlineRibbonSerial
        cellGrid = field.field
        cellTex = makeCellTexture(field)
        bakeGeneration &+= 1
    }

    /// ★★★ PUT EVERY DECLARED FACE ON A CELL BOUNDARY — ONE PHASE PER REGION.
    ///
    /// ★ THE CUT PLANE'S PHASE INSIDE THE CELL IS WHAT YOU SEE (maintainer, 2026-08-23).
    /// Struts are trimmed flush at a region's two cap planes. A cap on a cell BOUNDARY
    /// leaves open cells — an octet truss you look into. A cap through the MIDDLE of a
    /// cell slices every strut at its fattest and those cross-sections nearly touch: a
    /// surface of X-shaped bosses, the quilt.
    ///
    /// ★ AND ONE GRID ORIGIN CANNOT SERVE TWO FACES. The first cut of this shifted the
    /// whole cell grid, which put ONE face on a boundary and left the other exactly as it
    /// was — measured on his part: face 2 went clean at 0.00/0.00 while face 15 stayed at
    /// 0.44/0.44. His two faces are normal to the same axis, carry different cells (5.50
    /// and 6.00 mm) and their cap planes are 57.41 mm apart, which is a whole number of
    /// neither. There is no single origin that satisfies both, so the phase has to travel
    /// with the region — which is what `LatticeCellField.steppedPhase` carries.
    ///
    /// ★ IT PAIRS WITH THE WHOLE-NUMBER RULE. `latticeRegionCellsMM` makes the cell divide
    /// the declared depth exactly, so a region's two caps share a phase; this puts that
    /// shared phase at zero. Neither is sufficient alone: with only the first, both sides
    /// quilt equally.
    ///
    /// Returns `axis + fraction` per region, 0 for anything with no axis-aligned normal —
    /// a single scalar cannot describe a shift in two directions at once, and pretending
    /// otherwise would move the tiling for no gain.
    static func faceTilingPhase(regions: [LatticeRegionSpec],
                                cellMM: [Double],
                                fallbackCellMM: Double,
                                origin: SIMD3<Float>) -> [Float] {
        var out = [Float](repeating: 0, count: regions.count)
        for (i, r) in regions.enumerated() where r.role == .include && r.kind == .face {
            let cell = (i < cellMM.count && cellMM[i] > 0) ? cellMM[i] : fallbackCellMM
            // ★ ONE RULE, ONE IMPLEMENTATION — the same helper the stepped bake
            // uses per cell, so the encoder and the per-cell rescale cannot
            // drift apart (the 2026-08-25 shrunk-cell quilt was exactly that).
            if let ph = LatticePreviewOccupancy.tilingPhase(region: r, cellMM: cell,
                                                           origin: origin) {
                out[i] = ph
            }
        }
        return out
    }

    /// Nothing drawn, and why. nil when the bake produced cells, or when the region
    /// itself is empty (nothing was asked for, so nothing is missing).
    private func diagnoseEmpty(scene: LatticeSDFScene,
                               field: LatticeCellField) -> String? {
        guard field.field.values.contains(where: { $0 >= 0 }) == false else { return nil }
        let candidates = scene.occupancy.values.contains { $0 > 0.5 }
        guard candidates else { return nil }
        if cellUnprintable {
            return "No lattice here: at \(mm(params.cellMM)) even the densest "
                 + "certifiable lattice has struts thinner than one \(mm(lineWidthMM)) "
                 + "extrusion. Use a coarser cell."
        }
        // Would it have drawn WITHOUT the member floor? Then the members are the
        // reason, and a finer cell (or retention) is the remedy — not a coarser one.
        let unfloored = LatticePreviewOccupancy.cellField(
            occupancy: scene.occupancy, demand: scene.demand, cellMM: field.baseCellMM)
        if unfloored.values.contains(where: { $0 >= 0 }) {
            return "No lattice here: these members are too thin to hold "
                 + "\(Int(scene.minCellsPerMember.rounded())) cells at "
                 + "\(mm(field.baseCellMM)). Use a finer cell, or keep the lattice "
                 + "anyway where the part measures unloaded."
        }
        return "No lattice here: nothing in this region is both printable at one "
             + "\(mm(lineWidthMM)) extrusion and thick enough to certify."
    }

    private func mm(_ v: Double) -> String { String(format: "%.2f mm", v) }

    /// ★★ CORE'S PLAN, ASKED FOR AT THE PREVIEW'S OWN DENSITIES.
    ///
    /// The cell size a swept run picks depends on the DENSITY it grades to — a thin
    /// strut has to be carried by a coarser cell to stay printable — so the plan is
    /// asked with the rho the preview is about to render, voxel for voxel, not with
    /// some other number. Ask it with anything else and the picture stops being the
    /// plan's picture, which is the whole point of reading the plan.
    ///
    /// Returns nil when core has no plan (a non-cubic grid, no member widths, a
    /// refused bound). The caller then draws the uniform cell — and `fromCorePlan`
    /// says which happened, because a uniform picture is what BOTH look like.
    /// Core's union reading: the candidate set's measured peak against the part's,
    /// under core's ceiling. Disarmed, or with no demand field, the answer is no.
    private func subfloorQualifiesNow(_ scene: LatticeSDFScene) -> Bool {
        guard let r = subfloorRetention, r.armed,
              // ★ MEASURED STRESS ONLY — a stated per-region density is not a load
              // reading, and retention is a decision about load.
              scene.demandIsMeasuredStress else { return false }
        let ceiling = r.stressFractionMax
            ?? TopOptKit.latticeSubfloorRetentionStressFraction()
        // ★ THE MEASURED FIELD, never `demand` — see `stressDemand`.
        let peaks = LatticePreviewOccupancy.subfloorPeaks(
            demand: scene.stressDemand, partSDF: scene.partMaterialSDF,
            occupancy: scene.occupancy)
        return LatticePreviewOccupancy.subfloorQualifies(
            regionPeak: peaks.region, partPeak: peaks.part, ceiling: ceiling)
    }

    private func gradedCellField(scene: LatticeSDFScene,
                                 sweep: LatticeCellSweep,
                                 retains: Bool) -> LatticeCellField? {
        guard !scene.memberThicknessMM.isEmpty else { return nil }
        let occ = scene.occupancy
        let n = occ.count
        guard scene.memberThicknessMM.count == n else { return nil }

        let (lo, hi) = params.densitySpan
        let gamma = max(0.05, params.gamma)
        var candidate = [Bool](repeating: false, count: n)
        var rho = [Double](repeating: 0, count: n)
        let dem = scene.demand
        for i in 0..<n where occ.values[i] > 0.5 {
            candidate[i] = true
            if let d = dem, d.count == n {
                let t = Double(max(0, min(1, d.values[i])))
                rho[i] = lo + (hi - lo) * pow(t, gamma)
            } else {
                rho[i] = params.uniformRelativeDensity
            }
        }

        // ★★★ THE LADDER'S BASE CANNOT BE FINER THAN THE GRID IT IS PLANNED ON
        // (maintainer, four rounds: "a regular grid of tiles with void between them",
        // and "the cells should be much larger").
        //
        // ★ CORE OWNS A BASE CELL ONLY WHERE A DESIGN VOXEL'S CENTRE LANDS IN IT.
        // `plan_cell_sizes` scatters the candidate set into the base grid by voxel
        // centre — `++vox[c]` for the cell containing `(i+½)·h` — and then skips every
        // base cell it never touched: `if (vox[c] == 0) continue`. That is exact when
        // S0 >= h, which is what a RUN always hands it (the printability floor is far
        // coarser than the FEA voxel). The preview does not: its grid is the OCCUPANCY
        // grid, whose voxel is a preview SETTING, and `ladderBaseCellMM` halves the
        // dominant cell down to the finest rung that still prints — a number that owes
        // nothing to the grid.
        //
        // ★ SO A BASE FINER THAN THE VOXEL RETURNS A SIEVE, NOT A PLAN. Measured on his
        // part at Fast 64 (voxel 3.465 mm, ladder base 1.625 mm, ratio 0.47): core
        // latticed 8,322 base cells — exactly the number of occupied DESIGN voxels — out
        // of 70,906 that lie in material, i.e. 11.7%, every one of them at level 0 and
        // spaced every other cell on all three axes. That is a regular lattice of
        // ISOLATED 1.625 mm cells with unlatticed material between them, at a period
        // that follows the VOXEL and therefore does not move when the cell does. It is
        // also why the ladder never climbed: with one voxel per base cell there is never
        // a wholly-candidate 2x2x2 block to coarsen into.
        //
        // ★ SO THE BASE CLIMBS THE JOB'S OWN LADDER UNTIL THE GRID CAN HOLD IT, and it
        // is the LADDER it climbs, not the voxel. Substituting the voxel would close the
        // sieve too, but S0 = h makes every rung a multiple of a PREVIEW SETTING, and the
        // preview would then draw cells the run never builds: measured at Fast 64, the
        // voxel base puts 2,770 cells at 3.46 mm where the material's own derivation asks
        // for 6.5 mm — a cell half the size of the one that gets printed. Climbing the
        // ladder keeps every drawn cell a rung the run would lay down.
        //
        // Measured on his part, coverage of the declared material is untouched by the
        // choice (99.7% at Fast, 100% at Balanced), so the ladder rung costs nothing:
        //   Fast 64      base 6.50 mm   L0 1,238 @ 6.50 mm   L1 360 @ 13.00 mm
        //   Balanced 96  base 4.50 mm   L0 3,547 @ 4.50 mm   L1 1,080 @ 9.00 mm
        // against a sieve of 8,322 isolated 1.62 mm cells before it.

        // ★ FIT'S PER-VOXEL WANT: the cell of the region that owns this voxel, by
        // the SAME first-match rule the emission uses, so the picture and the job
        // agree about an overlap instead of averaging it into a third answer.
        // ★★★ AUTO'S PER-LOCAL-MEMBER CELL. Every voxel asks for the coarsest cell its
        // OWN member can hold; core's fit planner rounds each base cell DOWN to a rung.
        // See `LatticeCellSweep.perLocalMember` for why a window cannot express this and
        // for the measurements on his part that killed both window-shaped attempts.
        var desired: [Double] = []
        if sweep.perLocalMember, scene.minCellsPerMember > 0 {
            desired = LatticeMeasuredRegionWidth.desiredCellMM(
                occupancy: occ, memberThicknessMM: scene.memberThicknessMM,
                minCellsPerMember: scene.minCellsPerMember,
                // ★ UNCLAMPED: core's own "every voxel asks" mode. The ladder's base is
                // derived from these wants below, so clamping to it here would be
                // circular — and clamping to the OLD base is what buried the defect.
                baseCellMM: 0,
                capMM: 16 * Double(occ.spacing.x),
                perVoxelFloor: scene.cellsPerMemberFloorPerVoxel)
        }
        // ★★★ AND THE AESTHETIC FLOOR REACHES **SWEPT** TOO (maintainer, 2026-08-21:
        // "Do you have Aesthetic wired up the way it should be? … Why am I not seeing
        // MUCH larger cells on this piece?").
        //
        // ★ IT DID NOT, AND THIS IS THE GAP. `desired` was filled in for AUTO
        // (`perLocalMember`) and for FIT, and left EMPTY for swept — so on swept the
        // whole per-voxel floor was never handed to the planner, and core applied its
        // own cells-per-member law with the ACCURACY floor of 5. His part is on
        // Swept 3-8 mm, which is precisely the mode where the relaxation he chose could
        // not bind. The mode was reaching the uniform bake and nothing else he uses.
        //
        // ★ WHAT IT ASKS FOR IS THE SAME QUESTION AUTO ASKS, bounded by HIS window:
        // the coarsest cell each voxel's own member can hold under the floor that
        // applies to it, clamped to [min, max]. Only in aesthetic mode and only with a
        // measured per-voxel floor — with neither, `desired` stays empty and swept is
        // bit-for-bit the planner it has always been.
        if desired.isEmpty, scene.stageMode == .aesthetic,
           !scene.cellsPerMemberFloorPerVoxel.isEmpty, scene.minCellsPerMember > 0 {
            desired = LatticeMeasuredRegionWidth.desiredCellMM(
                occupancy: occ, memberThicknessMM: scene.memberThicknessMM,
                minCellsPerMember: scene.minCellsPerMember,
                baseCellMM: 0,
                // ★ HIS OWN CEILING. A swept job's window is a statement about what he
                // wants built; the relaxed floor may make a coarser cell ADMISSIBLE but
                // it does not get to overrule the number he typed. This is also why the
                // cells cannot get "MUCH larger" while the window says 8 mm.
                capMM: sweep.maxMM,
                perVoxelFloor: scene.cellsPerMemberFloorPerVoxel)
        }
        if desired.isEmpty, !fitCellMM.isEmpty, fitCellMM.count == scene.regions.count {
            desired = [Double](repeating: 0, count: n)
            for i in 0..<n where candidate[i] {
                let ix = i % occ.nx, iy = (i / occ.nx) % occ.ny, iz = i / (occ.nx * occ.ny)
                let p = SIMD3<Double>(
                    Double(occ.origin.x) + Double(ix) * Double(occ.spacing.x),
                    Double(occ.origin.y) + Double(iy) * Double(occ.spacing.y),
                    Double(occ.origin.z) + Double(iz) * Double(occ.spacing.z))
                for (r, region) in scene.regions.enumerated()
                where region.role == .include && LatticeRegionMask.contains(p, region: region) {
                    desired[i] = fitCellMM[r]
                    break
                }
            }
        }

        // ★★★ GRADE TO FIT **SHAPE** — THE CELL SHRINKS TOWARD THE REGION'S EDGE
        // (maintainer, 2026-08-23: "Lets start with just cell size and see how it looks.
        // Distance to the boundary, getting smaller as it gets closer to the boundary to
        // be able to create the shape of the lattice that perfectly fits the face/prism").
        //
        // ★ IT IS APPLIED HERE, TO `desired`, AND THAT IS WHY IT REACHES EVERY GRADE
        // OPTION — which is what he asked for. Every mode that derives a per-voxel want
        // has already written it by this point (auto/per-local-member, aesthetic-swept,
        // and fit-per-region), and the one mode that does not — plain swept, and fixed —
        // gets `desired` FILLED from the boundary alone, clamped to its own window. A
        // ceiling bolted onto any one of those branches would have graded one mode and
        // quietly left the other three flat.
        //
        // ★ AND IT IS A CEILING, SO IT CANNOT COARSEN ANYTHING. `S ≤ 2d` for a cube of
        // side S centred `d` from the edge; deep material is untouched. See
        // `LatticeBoundaryDistance.cellCeilingMM` for why the 2 is geometry and not a
        // tuning constant.
        // ★★★ AND IT IS APPLIED **AFTER** THE LADDER'S ENDS ARE DERIVED, NOT BEFORE.
        // (maintainer, 2026-08-23, on the first cut of this: "the grade to fit hasn't
        // gone all the way to solid on the edges to make them actually printable".)
        //
        // ★ THE FIRST ORDERING WAS A REGRESSION AND THIS IS WHY. The base rung below is
        // `min(wants)`. Feeding the boundary ceiling in FIRST means every region's edge
        // voxel contributes a want of about one voxel — so the minimum collapses to that,
        // the whole ladder is rebuilt around it, and the ENTIRE part is drawn at the
        // finest rung instead of only the rim. The picture goes uniformly fine, which is
        // the opposite of a gradient, and the edges never reach solid because there is
        // always some finer rung to fall to.
        //
        // ★ SO THE LADDER IS THE MEMBERS' AND THE CEILING IS THE SHAPE'S. Only the
        // per-member wants set the rungs; the boundary then trims each voxel DOWN within
        // that fixed ladder, and anything it trims below the base rung has no rung left
        // to take and goes SOLID — which is the printable edge he asked for.
        // ★ IN-PLANE WHERE A FACE REGION OWNS THE VOXEL, 3-D elsewhere — the same
        // correction the stepped path took (a face region is an extrusion; the 3-D
        // distance reads the wall's half-thickness at the caps, not the outline).
        let boundaryMM = LatticeBoundaryDistance.perVoxelForGrading(
            regions: scene.regions, candidate: candidate,
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing,
            origin: occ.origin)
        // The fill for a mode that derived no want of its own happens BEFORE the ladder
        // is derived — it is that mode's only want, so it has to be there to be seen —
        // and it is clamped to his own window, so it cannot drag the base under the end
        // he typed.
        if desired.isEmpty {
            LatticeBoundaryDistance.applyCeiling(
                to: &desired, distanceMM: boundaryMM, candidate: candidate,
                fallbackWindow: sweep.minMM > 0 && sweep.maxMM >= sweep.minMM
                    ? sweep.minMM...sweep.maxMM : nil)
        }

        // ★★★ GRADE TO FIT: THE LADDER'S ENDS ARE THE WANTS (maintainer, 2026-08-22:
        // "there is a 'grade to fit' in the algorithm … Please use that").
        //
        // ★ CORE ALREADY STATES THIS LAW AND THE APP WAS NOT ASKING IT. `grade_lattice`
        // on the Fit path (`grading.cpp`) builds the plan as
        //
        //     pp.min_cell_size_mm = s_min;   // the FINEST cell any region asked for
        //     pp.max_cell_size_mm = s_max;   // "never finer, so every emitted cell
        //                                    //  still has a printable density"
        //
        // where s_min/s_max are the min and max of the per-voxel `want`. The preview
        // instead handed core `ladderBaseCellMM`, which takes the dominant width's cell
        // and HALVES it while the rung still prints — a printability argument, not a
        // demand one. On his part that put the base at 1.625 mm when the finest cell any
        // voxel actually wants is 3.5 mm: two rungs nobody asked for, and finer than the
        // preview's own 3.465 mm voxel, which is what turned core's plan into a sieve of
        // isolated cells (see `LatticeTileDiagnosisTests`).
        //
        // ★ SO THE WANTS ARE COMPUTED UNCLAMPED FIRST and the ladder is derived FROM
        // them, exactly as core does. `desiredCellMM(baseCellMM: 0)` is core's own "every
        // voxel asks" mode — clamping to a base before the base exists is the circularity
        // that made this wrong.
        let voxelMM = Double(max(occ.spacing.x, max(occ.spacing.y, occ.spacing.z)))
        var baseMM = sweep.minMM
        var topMM = sweep.maxMM
        // ★★★ THE BASE IS THE WANTS' p05, NOT THEIR MINIMUM (2026-08-24 evening:
        // "The size of the cells are tiny - no bigger than 2mm" on a wall whose
        // median member is 20.6 mm). The minimum handed the ladder's base to the
        // single thinnest voxel class — measured on his part: wants min 1.72 mm
        // (one 3.44 mm sliver at floor 2) against p05 5.16 and median 10.31 — and
        // the planner then walks DOWN the ladder, so the sliver's rung became most
        // of the wall. The same sliver-pins-the-face disease the stepped path was
        // cured of this morning, one ladder over. p05 is the same conservative end
        // the width statistic uses; the voxels under it are zeroed by the clamp
        // below and go SOLID — his own rule for material too thin for its rung.
        let wants = desired.filter { $0 > 0 }.sorted()
        if let hi = wants.last, hi > 0 {
            baseMM = wants[Swift.min(wants.count - 1,
                                     Int(0.05 * Double(wants.count - 1)))]
            topMM = Swift.max(hi, baseMM)
        }
        // ★ AND THE GRID IS STILL A FLOOR, because core's rule is stated for a RUN, whose
        // grid is the FEA grid and is always finer than any cell it plans. The preview's
        // grid is a preview SETTING. Core owns a base cell only where a design voxel's
        // centre lands in it (`cell_plan.cpp`), so a base below the voxel returns a sieve
        // whatever produced it. On his part this guard is inert at both preview
        // resolutions — the wants start at 3.5 mm against voxels of 3.465 and 2.298 mm —
        // and it exists so a coarser preview cannot reopen the defect silently.
        if baseMM > 0, voxelMM > 0 {
            while baseMM < voxelMM { baseMM *= 2 }
        }
        topMM = Swift.max(topMM, baseMM)

        // ★ AND THE WANTS ARE CLAMPED TO THE BASE THE LADDER ACTUALLY GOT. Core's fit
        // planner throws when a voxel wants a cell FINER than the base rung — "emitted a
        // cell coarser than the derivation asked for" — and the bridge turns that into no
        // plan at all, taking the whole part's lattice with it. 0 is core's own "not
        // fitted" marker, so those voxels are simply left solid, which is what the run
        // builds there. Inert unless the grid floor above raised the base.
        // ★★★ THE SHAPE'S CEILING, ON THE LADDER THE MEMBERS BUILT. Trims each voxel
        // DOWN toward the region's own edge without ever having touched the rungs.
        LatticeBoundaryDistance.applyCeiling(
            to: &desired, distanceMM: boundaryMM, candidate: candidate)

        if baseMM > 0 {
            for i in 0..<desired.count where desired[i] > 0 && desired[i] < baseMM {
                // ★ NO RUNG LEFT ⇒ SOLID, and that is the point rather than a fallback.
                // A voxel within half a base cell of the edge cannot hold a printable
                // cell, so the material stays whole and the rim comes out as a solid
                // outline instead of a fringe of half-cut struts.
                desired[i] = 0
            }
        }

        guard let plan = TopOptKit.latticeCellSizePlan(
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing,
            origin: occ.origin, candidate: candidate, relativeDensity: rho,
            memberWidthMM: scene.memberThicknessMM,
            minCellMM: baseMM, maxCellMM: topMM,
            minExtrudableWidthMM: sweep.minExtrudableWidthMM,
            capRadiusVoxels: 16, topology: params.latticeID,
            desiredCellMM: desired,
            // ★★★ THE FLOOR CORE KEEPS OR CULLS BY. Without it core required 5 cells
            // across every member however far the mode had relaxed, so an 11 mm wall
            // asking for a 4.4 mm cell needed 22 mm of material and was culled to
            // SOLID — "only lattice in the back of these walls". Retention drops the
            // ceiling entirely, exactly as it does for the app's own floors above.
            cellsPerMemberFloor: retains ? 0 : scene.minCellsPerMember) else { return nil }

        let field = LatticePreviewOccupancy.gradedCellField(
            occupancy: occ, demand: scene.drawnDemand ?? scene.demand, plan: plan)
        guard retains else { return field }
        return LatticePreviewOccupancy.retainSubfloorCells(
            field, plan: plan, demand: scene.demand,
            densityLo: lo, densityHi: hi, gamma: gamma,
            minExtrudableWidthMM: sweep.minExtrudableWidthMM,
            topology: params.latticeID)
    }

    /// The per-cell volume the march reads: R = the octree cell's demand (−1 where
    /// the run leaves it solid), G = that cell's dyadic LEVEL. Two channels because
    /// the shader has to know how big the cell it is standing in is, and a second
    /// texture is a second grid that could disagree with the first.
    private func makeCellTexture(_ f: LatticeCellField) -> MTLTexture? {
        let grid = f.field
        guard f.level.count == grid.values.count else { return nil }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        // ★ FOUR CHANNELS SINCE STEPPED: r = demand, g = dyadic level (the solid
        // depth on the octree path), b = the stepped cell's size in mm (0 = not
        // stepped), a = the cell's ORIGIN, packed. The shader reads `.b` only when it
        // is positive, so the doubled path is byte-identical.
        // ★★ 32-BIT SINCE 2026-09-17 (Stepped's any-step packing): a Stepped cell sits
        // anywhere on its family's grid, so `a` has to carry its origin on ALL THREE
        // axes — three 7-bit fractions of the cell plus the face axis, 23 bits, which
        // a half's 11 cannot hold and a float's 24 can, exactly. Quantised to 1/128 of
        // the cell: 0.05 mm at 12 mm, 0.012 at 3 — the same order as the half the old
        // single fraction lived in. `lsdf_cell_frame_at` unpacks the same way.
        d.pixelFormat = .rgba32Float
        d.width = grid.nx; d.height = grid.ny; d.depth = grid.nz
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        let hasStepped = f.steppedCellMM.count == grid.values.count
        let hasPhase = f.steppedPhase.count == grid.values.count
        let hasOrigin = f.steppedOrigin.count == grid.values.count
        let pitch = Float(f.baseCellMM)
        var vals = [Float](repeating: 0, count: grid.values.count * 4)
        for n in 0..<grid.values.count {
            vals[4 * n] = grid.values[n]
            vals[4 * n + 1] = hasStepped && f.solidDepthMM.count == grid.values.count
                            ? f.solidDepthMM[n] : f.level[n]
            let sMM = hasStepped ? f.steppedCellMM[n] : 0
            vals[4 * n + 2] = sMM
            vals[4 * n + 3] = Self.packCellOrigin(
                sizeMM: sMM, pitchMM: pitch,
                phase: hasPhase ? f.steppedPhase[n] : 0,
                origin: hasOrigin ? f.steppedOrigin[n] : nil)
        }
        vals.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake3D(0, 0, 0, grid.nx, grid.ny, grid.nz),
                        mipmapLevel: 0, slice: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: grid.nx * 16,
                        bytesPerImage: grid.nx * grid.ny * 16)
        }
        return tex
    }

    /// The `a` channel: `axis + 4·(qx + 128·(qy + 128·qz))`, each q the cell's origin
    /// on that axis as a fraction of the cell in 1/128ths (0–127); axis 3 = none. With
    /// no per-cell origin the old `axis + fraction` (one fraction, along the axis) is
    /// re-expressed the same way, so the shader has ONE decoder.
    static func packCellOrigin(sizeMM: Float, pitchMM: Float, phase: Float, origin: SIMD3<Float>?) -> Float {
        guard sizeMM > 0, pitchMM > 0 else { return 0 }
        let m = sizeMM / pitchMM
        let axisF = phase.rounded(.down)
        let axis = (axisF >= 0 && axisF <= 2) ? Int(axisF) : 3
        var q = SIMD3<Int>(repeating: 0)
        if let origin {
            for ax in 0..<3 {
                let frac = Swift.max(0, origin[ax] / m)
                q[ax] = Int((frac * 128).rounded()) % 128
            }
        } else if axis <= 2 {
            let frac = Swift.max(0, phase - axisF)
            q[axis] = Int((frac * 128).rounded()) % 128
        }
        return Float(axis + 4 * (q.x + 128 * (q.y + 128 * q.z)))
    }

    /// ★ The organic field as TWO channels (rg16Float): centreline distance, surface
    /// distance. The march reads `.g` at the baked thickness and `.r − radius` live.
    private func makeCentrelineTexture(_ d: LatticeVoxelGrid, surface r: LatticeVoxelGrid) -> MTLTexture? {
        guard r.values.count == d.values.count else { return makeVolumeTexture(d) }
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rg16Float
        desc.width = d.nx; desc.height = d.ny; desc.depth = d.nz
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var halfs = [UInt16](repeating: 0, count: d.values.count * 2)
        for n in 0..<d.values.count { halfs[2 * n] = float32to16(d.values[n]); halfs[2 * n + 1] = float32to16(r.values[n]) }
        halfs.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake3D(0, 0, 0, d.nx, d.ny, d.nz), mipmapLevel: 0, slice: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: d.nx * 4, bytesPerImage: d.nx * d.ny * 4)
        }
        return tex
    }

    private func makeVolumeTexture(_ grid: LatticeVoxelGrid) -> MTLTexture? {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .r16Float
        d.width = grid.nx; d.height = grid.ny; d.depth = grid.nz
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        // Convert Float → Float16 (r16Float) contiguously, x fastest.
        var halfs = [UInt16](repeating: 0, count: grid.values.count)
        for (n, v) in grid.values.enumerated() { halfs[n] = float32to16(v) }
        halfs.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake3D(0, 0, 0, grid.nx, grid.ny, grid.nz),
                        mipmapLevel: 0, slice: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: grid.nx * 2,
                        bytesPerImage: grid.nx * grid.ny * 2)
        }
        return tex
    }

    /// The region texture: r = region signed distance (the clip), g = in-plane
    /// distance in from the face outline (the solid outline's own measure).
    private func makeRegionTexture(_ grid: LatticeVoxelGrid, outline: LatticeVoxelGrid?, prism: LatticeVoxelGrid?,
                                   skinIn: LatticeVoxelGrid? = nil,
                                   bandRim: LatticeVoxelGrid? = nil) -> MTLTexture? {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba16Float
        d.width = grid.nx; d.height = grid.ny; d.depth = grid.nz
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        let hasOutline = outline?.values.count == grid.values.count
        let hasPrism = prism?.values.count == grid.values.count
        let hasSkinIn = skinIn?.values.count == grid.values.count
        // ★★★ BAND MODE (2026-09-26): `.a` is B_r on the SDF grid — the shell's band rule
        // reads it (`shell_is_latticed`, `gate.w`); the legacy march's skin gate is not run
        let hasBandRim = bandRim?.values.count == grid.values.count
        if bandRim != nil, !hasBandRim {
            NSLog("DIAG band: bandRimCoarse has %d values, the region grid %d — .a keeps the legacy skin field",
                  bandRim!.values.count, grid.values.count)
        }
        var halfs = [UInt16](repeating: 0, count: grid.values.count * 4)
        for (n, v) in grid.values.enumerated() {
            halfs[4 * n] = float32to16(v)
            halfs[4 * n + 1] = float32to16(hasOutline ? outline!.values[n] : 1e3)
            halfs[4 * n + 2] = float32to16(hasPrism ? prism!.values[n] : v)
            // a = distance beyond the skin's inner face (the rim starts at 0); 1e3 = none near
            // — or, in band mode, B_r (< 0 inside skin ∪ rim, 0 on the rim's inner face)
            halfs[4 * n + 3] = float32to16(hasBandRim ? bandRim!.values[n]
                                           : (hasSkinIn ? skinIn!.values[n] : 1e3))
        }
        halfs.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake3D(0, 0, 0, grid.nx, grid.ny, grid.nz),
                        mipmapLevel: 0, slice: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: grid.nx * 8,
                        bytesPerImage: grid.nx * grid.ny * 8)
        }
        return tex
    }
    /// ★★★ THE BAND's fine rim grid as a texture: `LatticeBandFine.texels` (Float16, rgba,
    /// x fastest) uploaded verbatim as rgba16Float — no re-rounding, so the GPU reads the
    /// very halves the CPU twin (`LatticeBandFine.sample`) reads. nil (and a DIAG line) when
    /// the texel count does not match the dims, which then draws the legacy path's air.
    private func makeBandTexture(_ f: LatticeBandFine) -> MTLTexture? {
        let nx = Int(f.dims.x), ny = Int(f.dims.y), nz = Int(f.dims.z)
        guard nx > 0, ny > 0, nz > 0, f.spacing > 0, f.texels.count == 4 * nx * ny * nz else {
            NSLog("DIAG band: fine grid refused — dims (%d, %d, %d) spacing %.4f texels %d",
                  nx, ny, nz, f.spacing, f.texels.count)
            return nil
        }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba16Float
        d.width = nx; d.height = ny; d.depth = nz
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else {
            NSLog("DIAG band: makeTexture failed for (%d, %d, %d)", nx, ny, nz)
            return nil
        }
        f.texels.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake3D(0, 0, 0, nx, ny, nz), mipmapLevel: 0, slice: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: nx * 8, bytesPerImage: nx * ny * 8)
        }
        return tex
    }
    /// The band's rim texture as uploaded — for the sampler check (K12), which must read the
    /// real packer's output, never a copy of it.
    var bandRimTexture: MTLTexture? { rimTex }

    /// 1×1×1 stand-ins, bound whenever the scene has no band so the declared textures 6 and
    /// 7 are never unbound (Metal drops such a draw): the rim grid reads AIR on every channel
    /// (1e3), the smooth normals read zero weight.
    private func neutralRim() -> MTLTexture? {
        if let t = neutralRimTex { return t }
        neutralRimTex = makeNeutral4(SIMD4<Float>(repeating: 1e3))
        return neutralRimTex
    }
    private func neutralRimNorm() -> MTLTexture? {
        if let t = neutralRimNormTex { return t }
        neutralRimNormTex = makeNeutral4(.zero)
        return neutralRimNormTex
    }
    private func makeNeutral4(_ v: SIMD4<Float>) -> MTLTexture? {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba32Float
        d.width = 1; d.height = 1; d.depth = 1
        d.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        var val = v
        t.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1), mipmapLevel: 0, slice: 0,
                  withBytes: &val, bytesPerRow: 16, bytesPerImage: 16)
        return t
    }

    private func makeTintTexture(_ rgba: [UInt8], like grid: LatticeVoxelGrid) -> MTLTexture? {
        guard rgba.count == grid.count * 4 else { return nil }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba8Unorm
        d.width = grid.nx; d.height = grid.ny; d.depth = grid.nz
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        rgba.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake3D(0, 0, 0, grid.nx, grid.ny, grid.nz),
                        mipmapLevel: 0, slice: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: grid.nx * 4,
                        bytesPerImage: grid.nx * grid.ny * 4)
        }
        return tex
    }

    /// A 1×1×1 transparent tint volume bound when no faces are marked, so the
    /// fragment argument table is identical with and without tints.
    private func makeDummyTintTexture() -> MTLTexture? {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba8Unorm
        d.width = 1; d.height = 1; d.depth = 1
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        var zero: [UInt8] = [0, 0, 0, 0]
        tex.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1), mipmapLevel: 0, slice: 0,
                    withBytes: &zero, bytesPerRow: 4, bytesPerImage: 4)
        return tex
    }

    private func uploadSegments(_ segs: [LatticeSegment]) {
        segCount = segs.count
        guard segCount > 0 else { segBuffer = nil; return }
        var packed = [SIMD4<Float>]()
        packed.reserveCapacity(segCount * 2)
        // a.w carries the packed owner-cell index (0…26); b.w is spare.
        for s in segs { packed.append(SIMD4(s.a, Float(s.ownerIndex))); packed.append(SIMD4(s.b, 0)) }
        segBuffer = device.makeBuffer(bytes: packed,
                                      length: MemoryLayout<SIMD4<Float>>.stride * packed.count,
                                      options: .storageModeShared)
    }

    // MARK: uniforms

    /// The model matrix the BODY is drawn with: the settle rotation about the model
    /// centre — the exact composition `MeshRenderer.modelMatrix()` uses (T·R·T⁻¹),
    /// built from the same (rotation, centre) the workspace hands both views.
    private func modelMatrix() -> simd_float4x4 {
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(modelCenter, 1)
        var tInv = matrix_identity_float4x4
        tInv.columns.3 = SIMD4<Float>(-modelCenter, 1)
        return t * simd_float4x4(modelRotation) * tInv
    }

    /// The SINGLE clip transform this pass consumes: P · V · model — the same
    /// composition the mesh pipeline draws the body with. Internal (not private) so
    /// the alignment tests measure the transform the shader actually receives (A1/A2).
    func modelViewProjection(aspect: Float) -> simd_float4x4 {
        camera.projectionMatrix(aspect: aspect) * camera.viewMatrix() * modelMatrix()
    }

    func makeUniforms(aspect: Float) -> LSDFUniforms {
        // The march runs directly in MODEL (mesh) space — where every baked grid
        // lives. The per-pixel ray is the EXACT geometric inverse of P·V·model,
        // built from the camera basis with no matrix inversion (see LSDFUniforms):
        // world-space look-at basis, un-settled into model space, with the frustum
        // half-tangents folded into the right/up vectors. Eye and light are rotated
        // into the same frame.
        let invR = modelRotation.inverse
        let eyeModel = modelCenter + invR.act(camera.eye - modelCenter)
        let lightModel = invR.act(simd_normalize(SIMD3<Float>(0.4, 0.85, 0.55)))
        // lookAt basis (exactly OrbitCamera.lookAt's x/y/z rows): z points from the
        // target toward the eye, the camera looks along −z.
        let zW = simd_normalize(camera.eye - camera.target)
        let xW = simd_normalize(simd_cross(camera.up, zW))
        let yW = simd_cross(zW, xW)
        let tanHalf = tan(camera.fovY * 0.5)
        let rayX = invR.act(xW) * tanHalf * aspect
        let rayY = invR.act(yW) * tanHalf
        let rayDir = invR.act(-zW)
        let bmin = scene?.bounds.min ?? .zero
        let bmax = scene?.bounds.max ?? .zero
        // Cell origin = part min corner, so cells tile from a stable anchor.
        let cell = Float(max(0.1, cellField?.baseCellMM ?? params.cellMM))
        let cellOrigin = cellGrid?.origin ?? bmin
        let (lo, hi) = drawnDensitySpan
        let K = Float(max(1e-3, params.lattice?.densityCoefficient ?? 1))   // no law: no segments to draw
        // ★ THE MARCH READS PER-CELL DENSITY ONLY WHEN THIS IS SET — and it was set
        // only by a stress/demand field. A stepped/octree field carries a density per
        // TEXEL whatever the demand (the grade's quilt, the printability floor), and
        // on a project with no optimisation the flag was 0, so every strut drew at
        // the one uniform density and the quilt the bake had written never reached
        // the screen (his 2026-09-16 19:13: "There should be some quilting here.
        // There isn't."). The flag follows the field.
        let hasDemand: Float = (scene?.demand != nil || cellField?.steppedCellMM.isEmpty == false) ? 1 : 0
        let sdfSp = scene?.partSDF.spacing ?? SIMD3<Float>(repeating: 1)
        let minSDFSpacing = min(sdfSp.x, min(sdfSp.y, sdfSp.z))
        // Indigo-FAMILY endpoints (same "amount of material" story as the proxy, bar P1),
        // but both lifted off black so a lit 3-D strut reads clearly against the dark
        // stage: sparse = bright periwinkle, dense = vivid violet. Distinct from the
        // stress blue→red rainbow.
        let sparse = RGBA(158, 176, 236)
        let dense = RGBA(96, 52, 176)
        let curve = strutCurveUniforms
        var u = LSDFUniforms(
            rayX: SIMD4(rayX, 0),
            rayY: SIMD4(rayY, 0),
            rayDir: SIMD4(rayDir, 0),
            eye: SIMD4(eyeModel, 1),
            bboxMin: SIMD4(bmin, 0),
            bboxMax: SIMD4(bmax, 0),
            gridOrigin: SIMD4(cellGrid?.origin ?? .zero, 0),
            gridSpacing: SIMD4(cellGrid?.spacing ?? SIMD3(repeating: 1), 0),
            // ★ w = 2^maxLevel — the COARSEST cell in the plan, in base cells. The
            // march needs it before it knows which cell it is in, to pad the ray box
            // by the widest a cell can reach.
            gridDims: SIMD4(Float(cellGrid?.nx ?? 1), Float(cellGrid?.ny ?? 1),
                            Float(cellGrid?.nz ?? 1),
                            Float(1 << (cellField?.maxLevel ?? 0))),
            sdfOrigin: SIMD4(scene?.partSDF.origin ?? .zero, 0),
            sdfSpacing: SIMD4(scene?.partSDF.spacing ?? SIMD3(repeating: 1), 0),
            sdfDims: SIMD4(Float(scene?.partSDF.nx ?? 1), Float(scene?.partSDF.ny ?? 1), Float(scene?.partSDF.nz ?? 1), 0),
            // ★ THE MARCH'S CELL ANCHOR IS THE CELL FIELD'S OWN GRID, not the part
            // bbox. On the graded path the grid is CORE's base grid, and a half-cell
            // disagreement between the lattice the shader builds and the texture it
            // reads would shift every octree block — so both come from one place.
            latticeOrigin: SIMD4(cellOrigin.x, cellOrigin.y, cellOrigin.z, cell),
            gradeParams: SIMD4(Float(lo), Float(hi), Float(max(0.05, params.gamma)), K),
            // ★★★ WITH NO DEMAND FIELD THE MARCH DREW THE **MIDPOINT OF THE BAND**,
            // AND THE CALLOUT SAID THE FLOOR. That disagreement is the quilt
            // (2026-08-26).
            //
            // `proxyParams` sets `uniformRelativeDensity = 0.5 * (densityLo +
            // densityHi)` — a sensible "typical" value for the settings page's SAMPLE
            // BLOCK, where there is no part and no field and something has to be
            // shown. On a real part with no solve yet it is a fabrication: his band is
            // 5–90%, so the whole wall marched at **47.5%**, where an octet's struts
            // merge into a continuous sheet with only the cell centres left open.
            // That is precisely the "dense fabric of small shapes" he has been
            // reporting, and it is immune to cell size, resolution, algorithm and
            // grade — because none of them touch it.
            //
            // ★ AND THE TAP CALLOUT SAID 5% THE WHOLE TIME. It reads the BAKED
            // activation, which `cellField` writes as 0 when `demand` is nil, and maps
            // it through `lo + (hi - lo)·v^gamma` — so it reported the band FLOOR while
            // the march drew the MIDPOINT. Every tap anyone took said the struts were
            // hairline; the picture was ten times denser. Two numbers for one strut is
            // how this survived every measurement aimed at it.
            //
            // So with no field the march draws what the bake and the callout both
            // already say: the floor. One number, one place. The sample block is
            // untouched — it has no scene, so `demand` is nil there too, but it also
            // has no declared region, and it is the DECLARED case that must not lie.
            shadeParams: SIMD4(Float(hasDemand > 0.5 || (scene?.regions.isEmpty ?? true)
                                     ? params.uniformRelativeDensity
                                     : params.densitySpan.lo),
                               hasDemand, 0.03,
                               // ★ while the capsules draw organic the march runs SOLID-ONLY
                               // (a negative step count): no strut field, just the rim band
                               // under every unselected face, so the rim shows with the body
                               // hidden (his 2026-09-23 02:23: "Where are ANY of the rims?")
                               Float(capsulesReplaceField ? -debugMaxSteps : debugMaxSteps)),
            // stepParams.y = the trim's inward EROSION (mm). Near creases the trilinear
            // SDF underestimates true distance (min-of-planes is concave), so its zero
            // surface bulges outward in a lumpy per-voxel pattern — strut slivers
            // survive just outside the part and read as floating bits / rogue stubs
            // (round-4 feedback). Eroding by ~0.35 voxel dominates that error: flat
            // faces stay straight (a uniform offset), and nothing renders unless it is
            // genuinely interior.
            // stepParams.z = whether a face-tint volume is bound (A4).
            // ★★★ AND IT IS BOUNDED IN MILLIMETRES. `0.35 * minSDFSpacing` is a
            // fraction of a PREVIEW SETTING: 0.60 mm at Fine 128, but 1.21 mm at Fast
            // 64 on his part — so switching to Fast ate over a millimetre of lattice
            // off every surface INCLUDING the declared face, and left a solid skin he
            // never asked for. The error it exists to dominate is the trilinear SDF's
            // own, which is a fraction of a voxel near a crease and essentially zero on
            // a flat face; a third of a millimetre covers it at any resolution. Same
            // reasoning, and the same clamp, as `lsdf_part_clip`.
            stepParams: SIMD4(0.95,
                              Float(min(max(0.35 * Double(minSDFSpacing), 0.10), 0.35)),
                              tintTex != nil ? 1 : 0, Float(segCount)),
            lightDir: SIMD4(lightModel, 0),
            // ★ `denseColor` is now the INTERIOR hue and `sparseColor` the pale end
            // every hue washes out to, so all three classes share one lightness
            // language. Read from `LatticeStructureColour` — the same constants the
            // legend keys — so the part and its key cannot drift apart.
            sparseColor: SIMD4(Float(LatticeStructureColour.pale.r),
                               Float(LatticeStructureColour.pale.g),
                               Float(LatticeStructureColour.pale.b), 1),
            denseColor: SIMD4(Float(LatticeStructureColour.interior.r),
                              Float(LatticeStructureColour.interior.g),
                              Float(LatticeStructureColour.interior.b), 1),
            // ★ …and whether the stress plot is painted onto the struts this frame.
            // Only when the host asks AND a field was actually baked.
            overlayParams: SIMD4(stressOverlay && stressTex != nil ? 1 : 0,
                                 dressingLevel,
                                 // ★ z = the minimum strut RADIUS in mm (half the
                                 // bead). The march turns it into a per-cell
                                 // normalised floor — the density that prints is a
                                 // function of the cell, and under a graded plan the
                                 // cell is not one number. 0 ⇒ no printer stated.
                                 Float(0.5 * max(0, lineWidthMM)),
                                 // ★ w = THE PRINTER'S LAYER HEIGHT (mm), for the
                                 // solid fill's printed-layer banding. A free slot on
                                 // an EXISTING float4 rather than a new field: this
                                 // struct matches its MSL twin by BYTE OFFSET, and the
                                 // last field appended to one side alone had the shader
                                 // reading `lightDir` as the overlay flags.
                                 // 0 ⇒ no printer stated ⇒ no banding, never a default.
                                 Float(max(0, layerHeightMM))),
            rimColor: SIMD4(Float(LatticeStructureColour.rim.r),
                            Float(LatticeStructureColour.rim.g),
                            Float(LatticeStructureColour.rim.b), 1),
            strutCurve0: curve.0, strutCurve1: curve.1,
            strutCurve2: curve.2, strutCurve3: curve.3,
            strutCurve4: curve.4, strutCurve5: curve.5,
            strutCurve6: curve.6, strutCurve7: curve.7,
            buildDir: {
                let b = simd_normalize(SIMD3<Double>(
                    buildDirection.x.isFinite ? buildDirection.x : 0,
                    buildDirection.y.isFinite ? buildDirection.y : 0,
                    buildDirection.z.isFinite ? buildDirection.z : 1))
                return simd_length(b) > 0.5 ? SIMD4<Float>(SIMD3<Float>(b), 0) : .zero
            }(),
            organicOrigin: {
                // ★ OFF when the capsules draw organic: the march must not draw it too.
                guard let g = scene?.organicField, organicTex != nil, !capsulesReplaceField else { return .zero }
                return SIMD4(g.origin, 1)
            }(),
            organicSpacing: {
                guard let g = scene?.organicField, organicTex != nil else {
                    return SIMD4(1, 1, 1, 0)
                }
                return SIMD4(g.spacing, Float(scene?.organicBandMM ?? 0))
            }(),
            organicDims: {
                guard let g = scene?.organicField, organicTex != nil else {
                    return SIMD4(1, 1, 1, 0)
                }
                return SIMD4(Float(g.nx), Float(g.ny), Float(g.nz), 0)
            }(),
            debugParams: SIMD4(Float(debugShadeMode), Float(debugMinStepMM), 0, 0),
            // ★ .y IS NOW A FRACTION OF THE LOCAL CELL, not millimetres — see
            // `solidOutlineFraction`. The shader multiplies it by `LC.S`.
            // ★ .w IS THE SOLID OUTLINE'S WIDTH in mm (octree bake; 0 otherwise).
            // ★ .z AND .w ARE OFF (2026-09-23, his R7: nothing solid inside the pocket but the
            // rim). .z turned doubled's inactive cells into solid across the pocket; .w drew
            // the octree's outline strip and stripped the finish dressing beside it. The rim
            // is the region field's now (skin + rim under unselected faces, rim along the
            // solid-backed outline) and the lattice layer draws it.
            rimParams: SIMD4(Float(dressingBandMM), Float(solidOutlineFraction), 0, 0),
            organicRadius: {
                let reach = Float(scene?.organicBandMM ?? 0)
                // never past 90 % of the reach: beyond it the clamp would lie
                // ★ the capsules have no reach to respect: the live radius is exact
                let live = organicRadiusMM > 0
                    ? (capsulesReplaceField ? organicRadiusMM : Swift.min(organicRadiusMM, 0.9 * reach)) : 0
                // ★★★ THE WETTED JOIN (his instruction, 2026-09-08: "make the fillet
                // equal to the radius of the strut"). .w is the fillet as a MULTIPLE of
                // the strut's radius, so it scales with the strut and there is no
                // absolute length to be wrong at another size. 1 = one radius; 0 turns
                // the whole thing off and the analytic capsule is drawn exactly as
                // before. Capsules only — the march has no join to wet.
                return SIMD4(live, reach, Float(LatticeSDFScene.organicBakeHeadroomMM),
                             capsulesReplaceField ? 1 : 0)
            }())
        fillBandUniforms(&u)
        return u
    }

    /// ★★★ THE BAND's uniforms (2026-09-26 redesign) — filled ONLY when the scene carries a
    /// fine rim grid AND the capsules draw organic (the march then runs solid-only and draws
    /// nothing but the rim). Otherwise all four stay zero: `bandOrigin.w == 0` is the legacy
    /// band path, byte for byte.
    private func fillBandUniforms(_ u: inout LSDFUniforms) {
        // ★ z = 1 ⇒ the region texture's `.a` is B_r, not the legacy skin field — so the
        // legacy rim block (which reads `.a` as its skin gate) must not run on it. Only a band
        // scene whose capsules are NOT drawn is in that state; it then draws no rim rather
        // than a pocket-filling one.
        if regionTexCarriesBandRim { u.bandParams.z = 1 }
        // ★ the octet draws its struts with the march itself, so its band needs no capsules
        guard let scene, let bf = scene.bandFine, rimTex != nil,
              capsulesReplaceField || scene.algorithm != "organic" else { return }
        let sp = scene.partSDF.spacing
        let voxel = max(sp.x, max(sp.y, sp.z))
        // e_x: the capsules run a quarter voxel further into the rim than the coarse
        // region field says (`cap_clip_field`), so a clipped end never stops short of the
        // fine rim. `LATTICE_BAND_EMBED_EXTRA=<mm>` overrides it (a control: −0.86 must open
        // gaps).
        let embed = Self.bandEmbedExtraOverrideMM ?? 0.25 * voxel
        u.bandOrigin = SIMD4(bf.origin, 1)
        u.bandSpacing = SIMD4(bf.spacing, bf.spacing, bf.spacing, embed)
        u.bandDims = SIMD4(Float(bf.dims.x), Float(bf.dims.y), Float(bf.dims.z), 0)
        u.bandParams.x = scene.bandOptions.veil ? 1 : 0
        u.debugParams.z = Float(bandNormalControl)
    }
    /// `LATTICE_BAND_EMBED_EXTRA=<mm>` — read once per process; nil ⇒ production (0.25 voxel).
    static let bandEmbedExtraOverrideMM: Float? = {
        guard let s = ProcessInfo.processInfo.environment["LATTICE_BAND_EMBED_EXTRA"], let v = Float(s) else { return nil }
        return v
    }()
    /// ★ The rim normal's control (`debugParams.z`, band mode only): 0 = production (the fine
    /// field's normal), 1 = the legacy `lsdf_normal`, 2 = the fine gradient without the smooth
    /// blend. `LATTICE_BAND_NORMAL=1|2` sets it for a whole run.
    var bandNormalControl: Int = Int(ProcessInfo.processInfo.environment["LATTICE_BAND_NORMAL"] ?? "") ?? 0

    /// ★★★ DIAGNOSIS ONLY: paint each hit by the CELL it stands in. Off on every
    /// shipping frame; a probe turns it on to answer "which cells is this patch made
    /// of" from the picture instead of from an argument about the texture.
    var debugLevelShade: Bool {
        get { debugShadeMode > 0 }
        set { debugShadeMode = newValue ? 1 : 0 }
    }
    /// 0 = ship · 1 = band by the drawn CELL SIZE · 2 = band by the RAW LEVEL read.
    var debugShadeMode: Int = 0
    /// ★ THE MARCH'S STEP BUDGET (`shadeParams.w`). 512 is the shipping value; a
    /// probe raises it to ask whether a patch that draws broken is geometry or
    /// simply a ray that ran out of steps before it hit anything.
    var debugMaxSteps: Int = 512
    /// ★ The march's MINIMUM step in mm; 0 keeps the shipping `0.05 * safeCell`.
    var debugMinStepMM: Double = 0

    /// ★★ CORE'S STRUT LAW, SAMPLED ONCE PER BAND (task 2026-08-20). 32 normalised
    /// radii — `octet_strut_diameter_mm(rho, 1) / 2` — across [rhoMin, rhoMax], for
    /// the shader to interpolate. All-zero when core carries no law for the topology,
    /// which the shader reads as "use the analytic form".
    ///
    /// ★ CACHED ON THE BAND AND THE TOPOLOGY, because it is 32 bridge calls and the
    /// uniforms are rebuilt every frame. Nothing here may run per-frame: that mistake
    /// (a full-field scan in a computed property) stalled this page once already.
    private var strutCurveCache: (key: String, rows: [SIMD4<Float>])?

    private var strutCurveUniforms: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        let (lo, hi) = drawnDensitySpan
        let key = "\(params.latticeID)|\(lo)|\(hi)"
        let rows: [SIMD4<Float>]
        if let c = strutCurveCache, c.key == key {
            rows = c.rows
        } else {
            // Diameter at a UNIT cell, halved: the shader works in cell-normalised
            // units and multiplies by the cell at the end.
            let d = TopOptKit.latticeStrutDiameterCurve(topology: params.latticeID,
                                                        lo: lo, hi: hi,
                                                        cellMM: 1.0, count: 32)
            var packed = [SIMD4<Float>](repeating: .zero, count: 8)
            if d.count == 32 {
                for i in 0..<32 { packed[i >> 2][i & 3] = Float(d[i] / 2) }
            }
            rows = packed
            strutCurveCache = (key, packed)
        }
        return (rows[0], rows[1], rows[2], rows[3], rows[4], rows[5], rows[6], rows[7])
    }

    private func encode(into rpd: MTLRenderPassDescriptor, aspect: Float, cmd: MTLCommandBuffer) {
        guard let pipeline, isReady,
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var u = makeUniforms(aspect: aspect)
        enc.setRenderPipelineState(pipeline)
        bindFragment(enc, &u)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    // MARK: - the UNIFIED pass (task 2026-08-18-unified-shading)

    /// True once a scene is baked and there is something to march. `MeshRenderer` asks
    /// this before it adds the lattice to its own passes — an unbaked layer must leave
    /// the frame byte-identical, never draw a black rectangle over it.
    var isReady: Bool {
        cellTex != nil && sdfTex != nil && segBuffer != nil && segCount > 0
    }

    /// Bind the baked volumes + the segment soup + the sampler at the shared shader's
    /// fragment argument indices. ONE definition, used by the standalone pass, the
    /// unified G-buffer write and (for the uniform) the deferred shade — a second copy
    /// of an argument table is exactly how a "missing Buffer binding" abort gets in.
    /// ★ THE REGIONS THE MARCH IS CLIPPED TO — the SAME uniform, with the same
    /// bytes, that the shell's hole is cut from. Default is disabled, which the
    /// shader reads as "clip nothing": the standalone sample block has no regions
    /// by construction and must still draw its cell.
    var shellClip = ShellClipUniform()
    /// ★ THE DECLARATION LIST THAT GOES WITH `shellClip` — three float4s each, the
    /// shader's `SHELL_DECL_STRIDE`. Set together with it by the host, because either
    /// one alone describes nothing. Never empty: Metal drops a draw on an unbound
    /// buffer, so the default is one entry the shader's own enable flag ignores.
    var shellDecls: [SIMD4<Float>] = [SIMD4(0, 0, 1, 0), .zero, .zero]

    /// ★★★ THE CELL THE BAKE ACTUALLY LAID DOWN AT `p` (model mm). 0 when nothing was
    /// baked there, or the point is outside the grid.
    ///
    /// ★ THE READOUT USED TO RE-DERIVE THIS and it was wrong by 3.6x (maintainer,
    /// 2026-08-22: "The legend is still saying it's 2.2mm cells - which I highly doubt
    /// now"). He was right to doubt it: the callout re-ran a width/N* rule and reported
    /// 2.20 mm while the march was drawing his 8.00 mm cell. The give-away was in the
    /// same box — a 2.56 mm strut cannot fit in a 2.20 mm cell, and 2.56 mm is exactly
    /// what 46% density makes at 8.00 mm.
    ///
    /// ★ SO IT READS THE FIELD THE SHADER READS. `cellField` IS the texture the march
    /// samples, so the number on the card and the geometry under the finger cannot
    /// disagree — and it is right for all three algorithms without knowing which one it
    /// is holding, because the field carries the answer either way.
    /// The solid outline beam's width: two beads at least, never less than the
    /// march's trim plus half a voxel (so the struts it clips always end inside it).
    /// One formula, used by the bake and by the tap's attribution.
    static func outlineBeamMM(lineWidthMM: Double, voxelMM: Double) -> Double {
        let trimMM = min(max(0.35 * voxelMM, 0.10), 0.35)
        return max(2 * lineWidthMM, trimMM + 0.5 * voxelMM)
    }

    /// The outline ribbon for a baked field: one beam per include face, `solidBandMM`
    /// wide, as deep as the wall is at each outline vertex (the measured width field;
    /// the region's depth where that has no answer).
    static func buildOutlineRibbon(scene: LatticeSDFScene, field: LatticeCellField) -> LatticeOutlineRibbon.Mesh? {
        // ★ ORGANIC'S RIM IS THE SAME BEAM (his 2026-09-18: "there is no solid rim
        // around the lattice"): the rim used to be only an in-plane erosion of the
        // region, so the body's own shell was the ring — invisible with the body hidden
        // and nothing the lattice layer drew. Now it is a ribbon of the rim's width,
        // exactly as the octet's outline beam is.
        let width = field.solidBandMM > 0 ? field.solidBandMM : scene.organicSolidRimMM
        guard width > 0 else { return nil }
        // ★★★ RETIRED (his 2026-09-23 00:58: rims "should never be visible from the
        // outside, barely visible at all, and always in the shape of the model"). The
        // rim is now the skin under every unselected face, baked into the region field
        // (`LatticeSDFScene.unselectedSkinMM`); a beam swept along the outline stood on
        // the surface, poked past the top and ran through the lattice. The builder stays
        // for its tests; nothing is drawn.
        if scene.unselectedSkinMM > 0 { return nil }
        let occ = scene.prismOccupancy          // ★ the beam's depth is the wall's, whole prism
        var widths: [Int: [Double]] = [:]
        for (i, r) in scene.regions.enumerated() where r.role == .include && r.kind == .face {
            widths[i] = LatticeMeasuredRegionWidth.wallWidthFieldAlongNormalMM(
                region: r, occupancy: occ, partSDF: scene.partMaterialSDF)
        }
        // ★ THE BEAM NEVER LEAVES THE PART (his 2026-09-22 14:55): a grown region's beam
        // moves outward only where the part's own material (the whole solid, not the
        // prism) lies beyond the edge; and the beam starts at the part's surface under
        // the facet plane, never on the plane.
        let solid = scene.solidOccupancy
        func solidAt(_ p: SIMD3<Double>) -> Bool {
            let g = (SIMD3<Float>(p) - solid.origin) / solid.spacing
            let i = Int(g.x.rounded()), j = Int(g.y.rounded()), k = Int(g.z.rounded())
            for dk in -1...1 { for dj in -1...1 { for di in -1...1 {
                let a = i + di, b = j + dj, c = k + dk
                guard a >= 0, b >= 0, c >= 0, a < solid.nx, b < solid.ny, c < solid.nz else { continue }
                if solid.values[(c * solid.ny + b) * solid.nx + a] > 0.5 { return true }
            }}}
            return false
        }
        var census: [Int: (Int, Int, Int)] = [:]
        let mesh = LatticeOutlineRibbon.build(
            regions: scene.regions, widthMM: width,
            attached: { _, p in solidAt(p) },
            surfaceAt: { ri, p in
                let n = LatticeRegionMask.unit(scene.regions[ri].normal)
                var s = 0.0
                while s <= 4.0 { if solidAt(p + n * s) { return s }; s += 0.25 }
                return 0
            },
            census: { ri, a, o, s in
                let c = census[ri] ?? (0, 0, 0); census[ri] = (c.0 + a, c.1 + o, c.2 + s)
            }) { ri, p in
            let r = scene.regions[ri]
            guard let w = widths[ri], w.count == occ.count else { return r.depthMM }
            let g = (SIMD3<Float>(p) - occ.origin) / occ.spacing
            let i = Int(g.x.rounded()), j = Int(g.y.rounded()), k = Int(g.z.rounded())
            var best = 0.0
            for dk in -1...1 { for dj in -1...1 { for di in -1...1 {
                let a = i + di, b = j + dj, c = k + dk
                guard a >= 0, b >= 0, c >= 0, a < occ.nx, b < occ.ny, c < occ.nz else { continue }
                best = max(best, w[(c * occ.ny + b) * occ.nx + a])
            }}}
            return best > 0 ? best : r.depthMM
        }
        NSLog("DIAG outline beam (every outline edge; none on seams): %@ · %d verts",
              census.keys.sorted().map { ri -> String in
                  let c = census[ri]!
                  return "r\(ri) f\(scene.regions[ri].faceID ?? -1): attached \(c.0) open \(c.1) seam \(c.2)"
              }.joined(separator: " | "), mesh.vertexCount)
        return mesh.vertexCount > 0 ? mesh : nil
    }

    func bakedCellMMAt(_ p: SIMD3<Float>) -> Double {
        guard let f = cellField else { return 0 }
        let g = f.field
        guard g.nx > 0, g.ny > 0, g.nz > 0,
              g.spacing.x > 0, g.spacing.y > 0, g.spacing.z > 0 else { return 0 }
        let r = (p - g.origin) / g.spacing
        // Stepped texels span [i, i+1)·pitch (the shader reads `floor`); the dyadic
        // ladder's are centred.
        let stepped = f.steppedCellMM.count == g.values.count
        let i = Int(stepped ? r.x.rounded(.down) : r.x.rounded())
        let j = Int(stepped ? r.y.rounded(.down) : r.y.rounded())
        let k = Int(stepped ? r.z.rounded(.down) : r.z.rounded())
        guard i >= 0, j >= 0, k >= 0, i < g.nx, j < g.ny, k < g.nz else { return 0 }

        /// The cell size recorded at one index — STEPPED carries it outright, the ladder
        /// carries a dyadic level.
        func sizeAt(_ n: Int) -> Double {
            guard n >= 0, n < g.values.count else { return 0 }
            if f.steppedCellMM.count == g.values.count, f.steppedCellMM[n] > 0 {
                return Double(f.steppedCellMM[n])
            }
            guard n < f.level.count else { return f.baseCellMM }
            return f.baseCellMM * pow(2.0, Double(max(0, Int(f.level[n].rounded()))))
        }

        // ★★ THE PROBE LANDS ON A STRUT'S **SURFACE**, WHICH IS NOT ALWAYS INSIDE ITS
        // OWN CELL (maintainer, 2026-08-22: "The legend no longer says the cell size
        // below the strut size").
        //
        // ★ THIS REQUIRED THE CELL AT THE POINT TO BE ACTIVE and returned 0 otherwise —
        // and 0 is what the panel reads as "not known", so the line disappeared. A strut
        // stands proud of the lattice it belongs to: the ray hits its skin, which can sit
        // a fraction of a voxel into the neighbouring cell, and that neighbour is often
        // solid. So the OWNING cell is looked for in the 3×3×3 around the hit, nearest
        // first, and only then does it fall back.
        //
        // ★ AND THE FALLBACK IS THE GRID'S OWN SIZE, NOT ZERO. A cell size is a property
        // of the PLAN, not of whether that particular cell was activated — reporting
        // nothing because the nearest cell happens to be solid tells the user less than
        // the truth, not more.
        for radius in 0...1 {
            for dk in -radius...radius {
                for dj in -radius...radius {
                    for di in -radius...radius where abs(di) == radius || abs(dj) == radius
                                                     || abs(dk) == radius || radius == 0 {
                        let a = i + di, b = j + dj, c = k + dk
                        guard a >= 0, b >= 0, c >= 0, a < g.nx, b < g.ny, c < g.nz else { continue }
                        let n = (c * g.ny + b) * g.nx + a
                        guard n < g.values.count, g.values[n] >= 0 else { continue }
                        let s = sizeAt(n)
                        if s > 0 { return s }
                    }
                }
            }
        }
        return sizeAt((k * g.ny + j) * g.nx + i)
    }

    /// ★★★ THE ACTIVATION THE SHADER READS, AT A POINT — the sibling of
    /// `bakedCellMMAt`, for the DENSITY half of the tap callout (2026-08-24
    /// evening: a tapped 2.00 mm cell read "5% · 0.18 mm" — under half a bead —
    /// while the BAKE had lifted that cell to its printability floor of ~25%. The
    /// callout was re-baking a plain uniform field from raw demand and reading
    /// that: the exact second-estimate drift `bakedCellMMAt`'s own note documents,
    /// one field over). Same owning-cell search as the size, so the two halves of
    /// the callout describe ONE cell. Returns −1 when no active cell owns the
    /// point — the caller falls back rather than inventing a density.
    /// ★ THE SPAN THE CELL TEXTURE IS DRAWN OVER. The stated span, unless the
    /// stepped bake widened it to reach its grade-to-solid quilt row
    /// (`LatticeCellField.drawnDensityHi`) — the uniforms' `gradeParams`, the strut
    /// curve and the callout all read THIS, so a texel means one density everywhere.
    var drawnDensitySpan: (lo: Double, hi: Double) {
        let s = params.densitySpan
        if let f = cellField, f.drawnDensityHi > s.hi + 1e-9 { return (s.lo, f.drawnDensityHi) }
        return s
    }

    /// The relative density the shader draws at `p` (−1 ⇒ unknown): the baked
    /// activation mapped over `drawnDensitySpan` with the shader's own law.
    func bakedDensityAt(_ p: SIMD3<Float>) -> Float {
        let a = bakedActivationAt(p)
        guard a >= 0 else { return -1 }
        let (lo, hi) = drawnDensitySpan
        let g = max(0.05, params.gamma)
        return Float(lo + (hi - lo) * pow(Double(min(max(a, 0), 1)), g))
    }

    func bakedActivationAt(_ p: SIMD3<Float>) -> Float {
        guard let f = cellField else { return -1 }
        let g = f.field
        guard g.nx > 0, g.ny > 0, g.nz > 0,
              g.spacing.x > 0, g.spacing.y > 0, g.spacing.z > 0 else { return -1 }
        let r = (p - g.origin) / g.spacing
        let stepped = f.steppedCellMM.count == g.values.count
        let i = Int(stepped ? r.x.rounded(.down) : r.x.rounded())
        let j = Int(stepped ? r.y.rounded(.down) : r.y.rounded())
        let k = Int(stepped ? r.z.rounded(.down) : r.z.rounded())
        guard i >= 0, j >= 0, k >= 0, i < g.nx, j < g.ny, k < g.nz else { return -1 }
        for radius in 0...1 {
            for dk in -radius...radius {
                for dj in -radius...radius {
                    for di in -radius...radius where abs(di) == radius || abs(dj) == radius
                                                     || abs(dk) == radius || radius == 0 {
                        let a = i + di, b = j + dj, c = k + dk
                        guard a >= 0, b >= 0, c >= 0,
                              a < g.nx, b < g.ny, c < g.nz else { continue }
                        let n = (c * g.ny + b) * g.nx + a
                        guard n < g.values.count, g.values[n] >= 0 else { continue }
                        return g.values[n]
                    }
                }
            }
        }
        return -1
    }

    /// The baked region field, for the SHELL's own fragments — the same texture
    /// this renderer's march samples, so the hole and the struts are one volume.
    var regionTexture: MTLTexture? { regionTex }
    private var organicTex: MTLTexture?
    // ── ★★★ THE CAPSULE IMPOSTORS (2026-09-06) ─────────────────────────────────
    /// The scene's organic capsules, packed (a.xyz, r) (b.xyz, 0) for the vertex and
    /// fragment stages of `organicCapsuleShaderSource`.
    private var capsuleBuffer: MTLBuffer?
    private(set) var capsuleCount = 0
    /// Set by the HOST once its capsule pipeline built. Until then the march draws
    /// the baked field as before, so a device whose MSL failed loses nothing.
    var drawOrganicCapsules = false
    /// True when this frame draws organic as capsules: the march's organic field is
    /// switched off in the uniforms and its step budget is zeroed, so nothing is
    /// drawn twice and no ladder stands in.
    var capsulesReplaceField: Bool { drawOrganicCapsules && capsuleCount > 0 && capsuleBuffer != nil }
    private func uploadCapsules(_ caps: [OrganicCapsule]) {
        capsuleCount = caps.count
        guard capsuleCount > 0 else { capsuleBuffer = nil; return }
        var packed = [SIMD4<Float>]()
        packed.reserveCapacity(capsuleCount * 2)
        for c in caps { packed.append(SIMD4(c.a, c.r)); packed.append(SIMD4(c.b, 0)) }
        capsuleBuffer = device.makeBuffer(bytes: packed,
                                          length: MemoryLayout<SIMD4<Float>>.stride * packed.count,
                                          options: .storageModeShared)
    }
    /// Everything `capsule_vertex` / `capsule_gbuffer` declare: the fragment table is
    /// `bindFragment`'s (so the clip, the region and the tints are the march's), plus
    /// the capsule buffer at fragment buffer 2 and, for the vertex stage, the capsules
    /// at 0 and the uniforms at 1.
    func bindCapsules(_ enc: MTLRenderCommandEncoder, _ u: inout LSDFUniforms) {
        bindFragment(enc, &u)
        enc.setVertexBuffer(capsuleBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<LSDFUniforms>.stride, index: 1)
        enc.setFragmentBuffer(capsuleBuffer, offset: 0, index: 2)
    }
    /// A 1×1×1 volume reading +1e9 — "no strut anywhere", so a bound-but-unread
    /// texture cannot draw geometry. Metal requires the binding to exist.
    private var neutralOrganicTex: MTLTexture?
    private func neutralOrganic() -> MTLTexture? {
        if let t = neutralOrganicTex { return t }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rg32Float
        d.width = 1; d.height = 1; d.depth = 1
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        var v: SIMD2<Float> = SIMD2(1e9, 0)
        t.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1), mipmapLevel: 0, slice: 0,
                  withBytes: &v, bytesPerRow: 8, bytesPerImage: 8)
        neutralOrganicTex = t
        return t
    }
    /// Where that field lives in model space, for the shell's uniform.
    var regionGrid: LatticeVoxelGrid? { scene?.regionSDF }

    /// A 1×1×1 cell field with NO active cell — `r` demand 0, `g` level −1, `b`/`a` 0.
    /// Binding it is how a half-swapped scene draws no lattice at all (see `sceneSerial`).
    private var neutralCellTex: MTLTexture?
    private func neutralCell() -> MTLTexture? {
        if let t = neutralCellTex { return t }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba32Float          // the same format as `makeCellTexture`
        d.width = 1; d.height = 1; d.depth = 1
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        var v: SIMD4<Float> = SIMD4(0, -1, 0, 0)
        t.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1), mipmapLevel: 0, slice: 0,
                  withBytes: &v, bytesPerRow: 16, bytesPerImage: 16)
        neutralCellTex = t
        return t
    }

    /// A 1×1×1 volume reading −1e9: inside everywhere, so an unclipped march is
    /// an exact identity rather than a special case in the shader.
    private func neutralRegion() -> MTLTexture? {
        if let t = neutralRegionTex { return t }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba32Float
        d.width = 1; d.height = 1; d.depth = 1
        d.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        var v: SIMD4<Float> = SIMD4(-1e9, 1e3, -1e9, 0)
        t.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1), mipmapLevel: 0, slice: 0,
                  withBytes: &v, bytesPerRow: 16, bytesPerImage: 16)
        neutralRegionTex = t
        return t
    }

    func bindFragment(_ enc: MTLRenderCommandEncoder, _ u: inout LSDFUniforms) {
        // ★ A STALE CELL FIELD IS NOT DRAWN AT ALL. See `sceneSerial`: between a new
        // scene being published and its cell field landing, the only honest picture is
        // no lattice — a lattice drawn from the previous bake's cell sizes against this
        // scene's geometry is the quilt.
        enc.setFragmentBytes(&u, length: MemoryLayout<LSDFUniforms>.stride, index: 0)
        // ★ BOUND HERE, IN THE ONE BINDER, so the standalone pass and the unified
        // G-buffer write cannot disagree about it — and so neither can OMIT it.
        // `lsdf_fragment` and `lsdf_gbuffer` both DECLARE buffer 4, and Metal drops
        // a draw whose declared buffer is unbound.
        var clip = shellClip
        enc.setFragmentBytes(&clip, length: MemoryLayout<ShellClipUniform>.stride, index: 4)
        var decls = shellDecls.isEmpty ? [SIMD4<Float>(0, 0, 1, 0), .zero, .zero] : shellDecls
        decls.withUnsafeBytes {
            enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 5)
        }
        enc.setFragmentBuffer(segBuffer, offset: 0, index: 1)
        // ★★★ A STALE CELL FIELD IS REPLACED BY AN EMPTY ONE, not merely flagged.
        //
        // ★ THE FIRST ATTEMPT ZEROED `stepParams.w`, WHICH IS THE ORGANIC SEGMENT COUNT
        // — it does not switch the analytic lattice off at all, so the quilt frame kept
        // rendering. The honest lever is the cell field itself: bind a 1x1x1 texture
        // whose level is -1 (inactive everywhere) and the march takes its own
        // already-correct path for "the run leaves this solid", drawing the plain body.
        // No lattice can be drawn from a field that declares no active cell.
        enc.setFragmentTexture(latticeFieldIsCurrent ? cellTex : neutralCell(), index: 0)
        enc.setFragmentTexture(sdfTex, index: 1)
        // ★ index 3 is the REGION field. `neutralRegion()` is a 1×1×1 volume of a
        // large NEGATIVE distance — "inside everywhere" — which is the exact
        // identity for a preview with nothing declared (the sample block), and it
        // means "no regions" clips nothing for the march exactly as it cuts
        // nothing for the shell.
        enc.setFragmentTexture(regionTex ?? neutralRegion(), index: 3)
        // ★ index 4 — the stress overlay. `dummyTintTex` when absent, and the
        // uniform's flag decides whether it is read at all, so a frame with no
        // field is byte-identical to one before the overlay existed.
        enc.setFragmentTexture(stressTex ?? dummyTintTex, index: 4)
        enc.setFragmentTexture(organicTex ?? neutralOrganic(), index: 5)
        enc.setFragmentTexture(tintTex ?? dummyTintTex, index: 2)
        // ★★★ THE BAND (2026-09-26): 6 = the fine rim grid, 7 = its smooth normals. Both
        // DECLARED by `lsdf_gbuffer` and `lsdf_fragment`, so both are bound on EVERY path —
        // the neutral stand-ins when the scene has no band (the uniforms then never read
        // them). The capsule pass declares neither; an extra binding is harmless there.
        enc.setFragmentTexture(rimTex ?? neutralRim(), index: 6)
        enc.setFragmentTexture(neutralRimNorm(), index: 7)
        enc.setFragmentSamplerState(sampler, index: 0)
    }

    /// The uniforms for the unified G-buffer write: everything `makeUniforms` builds,
    /// plus the three transforms that put a marched MODEL-space hit into the body's own
    /// clip and eye frames. The caller passes the matrices IT is drawing the shell with
    /// — that is what makes the two surfaces land in the same depth buffer at the same
    /// place, rather than two views that merely agree to several decimal places.
    func makeUnifiedUniforms(aspect: Float, clipFromModel: simd_float4x4,
                             eyeFromModel: simd_float4x4,
                             eyeNormalBasis: simd_float4x4) -> LSDFUniforms {
        var u = makeUniforms(aspect: aspect)
        u.clipFromModel = clipFromModel
        u.eyeFromModel = eyeFromModel
        u.eyeNormalBasis = eyeNormalBasis
        // The colour ramp reads the STATED span; the grade's raise is drawn over the
        // wider drawn span but must not colour the quilt as the ramp's deep end.
        u.colourSpan = SIMD4(Float(params.densitySpan.lo), Float(params.densitySpan.hi), 1, 1)
        let gc = LatticeStructureColour.grade
        // w = the band in mm (the tint's spatial reach), 0 when the grade is off
        // ★ ORGANIC TOO (his 2026-09-18: "I am not seeing any of the 'grade to shape'
        // green … ensure it is implemented on the actual lattice"): its own Fit to
        // shape is the switch; the reach is the same band the octet uses.
        let gradeOn = (scene?.organicShapeFit ?? false) || steppedShapeFit
        u.gradeColor = SIMD4(Float(gc.r), Float(gc.g), Float(gc.b),
                             gradeOn && params.shapeFitBandMM > 0 ? Float(params.shapeFitBandMM) : 0)
        return u
    }

    // MARK: live draw

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }
        // Project at the shared VIEWPORT ratio, not the capped drawable's integer-
        // rounded ratio, so the lattice and the body scale identically (bar A1).
        let aspect = viewportAspect
            ?? Float(view.drawableSize.width / max(1, view.drawableSize.height))
        let before = bakeGeneration
        encode(into: rpd, aspect: aspect, cmd: cmd)
        assert(bakeGeneration == before, "P2 violated: a bake happened inside draw()")
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: offscreen (evidence) + measurement (profile), mirroring MeshRenderer

    func renderOffscreen(size: Int, clear: MTLClearColor) -> [UInt8]? {
        guard cellTex != nil, segCount > 0 else { return nil }
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        cd.usage = [.renderTarget, .shaderRead]; cd.storageMode = .shared
        guard let color = device.makeTexture(descriptor: cd), let cmd = queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = clear
        rpd.colorAttachments[0].storeAction = .store
        encode(into: rpd, aspect: 1, cmd: cmd)
        cmd.commit(); cmd.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: size * size * 4)
        color.getBytes(&px, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        return px
    }

    func measureFrameGPUSeconds(size: Int) -> Double? {
        guard cellTex != nil, segCount > 0 else { return nil }
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        cd.usage = [.renderTarget]; cd.storageMode = .private
        guard let color = device.makeTexture(descriptor: cd), let cmd = queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        encode(into: rpd, aspect: 1, cmd: cmd)
        cmd.commit(); cmd.waitUntilCompleted()
        let dt = cmd.gpuEndTime - cmd.gpuStartTime
        return dt > 0 ? dt : nil
    }

    // MARK: shader

    /// ★ THE STANDALONE PREVIEW SHADER — NOW BUILT ON THE SHARED FIELD.
    ///
    /// The field, the march, the gradient and the albedo moved to
    /// `latticeFieldSource` (UnifiedShading.swift) so that this renderer and the
    /// unified pass inside `MeshRenderer` march THE SAME geometry. Only the entry
    /// point and the OLD shading model are left here, and they are left VERBATIM on
    /// purpose: this is the "pasted-on" picture the task's before/after pair is
    /// measured against, and a before that had drifted would make the pair
    /// uninterpretable.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    \(latticeFieldSource)

    fragment float4 lsdf_fragment(VOut in [[stage_in]],
                                  constant LSDFUniforms& U [[buffer(0)]],
                                  const device float4* segs [[buffer(1)]],
                                  texture3d<float> cellTex [[texture(0)]],
                                  texture3d<float> sdfTex [[texture(1)]],
                                  texture3d<float> tintTex [[texture(2)]],
                                  texture3d<float> regionTex [[texture(3)]],
                                  texture3d<float> stressTex [[texture(4)]],
                                  texture3d<float> organicTex [[texture(5)]],
                                  // ★ the band's rim grid + smooth normals — see `lsdf_gbuffer`
                                  texture3d<float> rimTex [[texture(6)]],
                                  texture3d<float> rimNormTex [[texture(7)]],
                                  sampler samp [[sampler(0)]],
                                  constant ShellClip& RC [[buffer(4)]],
                                  // ★ See `lsdf_gbuffer`: the same declaration list,
                                  // the same buffer index, bound by the same binder.
                                  constant float4* shellDecls [[buffer(5)]]) {
        float3 ro = U.eye.xyz;
        float3 rd = lsdf_ray(U, in.uv);
        LSDFHit h = lsdf_march(U, segs, cellTex, sdfTex, regionTex, organicTex, rimTex, samp, RC,
                               shellDecls, ro, rd);
        if (!h.hit) return float4(0.0);
        float3 hitPos = h.pos; float hitRho = h.rho;
        // ★ the same normal rule as `lsdf_gbuffer`: a band rim hit takes the rim's own normal
        bool bandRimHit = U.bandOrigin.w > 0.5 && h.solid > 1.5 && h.solid < 2.25;
        float3 n;
        if (bandRimHit && abs(U.debugParams.z - 1.0) > 0.5) {
            n = U.debugParams.z > 1.5 ? band_rim_gradient(U, rimTex, samp, hitPos)
                                      : band_rim_normal(U, rimTex, rimNormTex, samp, hitPos);
        } else {
            n = lsdf_normal(U, segs, cellTex, sdfTex, regionTex, samp, RC, shellDecls,
                            hitPos, hitRho, rimTex, U.bandOrigin.w > 0.5 && h.solid < 0.5);
        }

        // ★ THE OLD, SEPARATE LIGHTING MODEL — and §1(d)'s whole point. A model-space
        // key at a different direction and a different strength from the body's, a
        // FLAT 0.30 ambient where the body has a two-colour hemisphere, a specular
        // lobe the body does not have at all, and a gamma lift + 1.08 exposure the
        // body does not apply. Two substances, and the eye reads two objects.
        float3 vdir = normalize(U.eye.xyz - hitPos);
        float3 key = normalize(U.lightDir.xyz);
        float3 fill = normalize(float3(-0.5, 0.2, 0.7));
        float ndlK = clamp(dot(n, key), 0.0, 1.0);
        float ndlF = clamp(dot(n, fill), 0.0, 1.0);
        float amb = 0.30;
        // ★ THE DRESSING TRAVELS HERE TOO. `lsdf_albedo` classifies a strut as
        // boundary work from it, and this standalone preview shares that function —
        // so a call short of an argument does not merely lose the rim hue, it fails
        // to COMPILE, and a shader built with `try?` then fails silently.
        float3 baseC = lsdf_albedo(U, tintTex, stressTex, samp, hitPos, hitRho, h.dressing,
                                   h.solid, h.grade);
        if (bandRimHit && U.bandParams.x > 0.5 && rimTex.sample(samp, band_uvw(U, hitPos)).g < 0.0) {
            baseC = bandSkinGrey;      // the veil: the skin drawn over the rim
        }
        float3 lit = baseC * (amb + 0.85 * ndlK + 0.30 * ndlF);
        float rim = pow(1.0 - clamp(dot(n, vdir), 0.0, 1.0), 2.5);
        lit += rim * 0.55 * mix(float3(0.72, 0.78, 0.98), float3(1.0), 0.35);
        float spec = pow(max(dot(reflect(-key, n), vdir), 0.0), 48.0);
        lit += spec * 0.55;
        // Gentle lift so the deep-indigo dense end stays legible, not muddy black.
        float3 col = pow(clamp(lit, 0.0, 1.0), float3(0.85)) * 1.08;
        return float4(clamp(col, 0.0, 1.0), 1.0);
    }
    """
}
// ★ THE SWIFTUI HOST IS GONE, AND ITS ABSENCE IS THE TASK
// (task 2026-08-18-unified-shading).
//
// `LatticeSDFPreviewView` used to live here: a second, transparent, `isPaused` MTKView
// that the workspace stacked OVER the mesh view, with `isOpaque = false`, alpha
// blending, and — the thing that mattered — NO DEPTH ATTACHMENT ANYWHERE. That made the
// struts a separate image composited on top of the frame. They could not be occluded by
// the part, could not receive the frame's ambient occlusion, contact darkening or
// crease lines, and were lit by their own key light with their own ambient, their own
// specular lobe and their own exposure. The maintainer's "it looks pasted ON the model,
// not like a PART of it" was a literal description of the architecture.
//
// The workspace now hands this scene to `MetalMeshView` as `latticeLayer:`, and
// `MeshRenderer` marches it inside its OWN depth prepass and its OWN colour pass — see
// `MeshRenderer.setLatticeScene` and `unifiedLatticeShaderSource`. This renderer stays
// as the BAKER of the volumes (via `init(device:buildPipeline:)`) and as the standalone
// BEFORE capture for the evidence; nothing in the app draws through it any more.
//
// The view's own resolution cap (1152 px on the long side, its bar P3) did not
// disappear with it: the march is still fill-bound, so the same number is now
// `MeshRenderer.latticeGBufferMaxPixels` and caps the G-buffer the march writes into.

// Minimal IEEE-754 float32 → float16 for r16Float upload (no Accelerate dependency).
// Internal, not private, so a test can push the tiling phase through the REAL packer
// rather than a copy of it — a probe that re-implements the thing it is checking only
// ever agrees with itself.
func float32to16(_ f: Float) -> UInt16 {
    let x = f.bitPattern
    let sign = UInt16((x >> 16) & 0x8000)
    var mant = x & 0x007fffff
    let exp = Int((x >> 23) & 0xff) - 127 + 15
    if exp <= 0 {
        if exp < -10 { return sign }
        mant |= 0x00800000
        let shift = 14 - exp
        let m = mant >> UInt32(shift)
        return sign | UInt16(m)
    } else if exp >= 0x1f {
        return sign | 0x7c00
    }
    return sign | UInt16(exp << 10) | UInt16(mant >> 13)
}
#endif
