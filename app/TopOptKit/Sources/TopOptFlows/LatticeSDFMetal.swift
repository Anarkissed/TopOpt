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
    /// Grid-indexed, 6 per voxel, in core's Voigt order. Must match `dims`.
    public let tensor: [Double]
    public let dims: (Int, Int, Int)
    public let originMM: SIMD3<Double>
    public let spacingMM: Double
    /// The printer's bead. 0 is core's UNSET refusal — printability is user input.
    public let minExtrudableWidthMM: Double
    /// Model-space build direction, for the overhang cone (disarmed by default).
    public let buildDirection: SIMD3<Double>
    /// The separation window the demand is mapped onto — organic's cell size is an
    /// OUTPUT read off the achieved spacing, so this is the control that drives it.
    public let separationMinMM: Double
    public let separationMaxMM: Double
    public let rhoMin: Double
    public let rhoMax: Double

    public init(tensor: [Double], dims: (Int, Int, Int), originMM: SIMD3<Double>,
                spacingMM: Double, minExtrudableWidthMM: Double,
                buildDirection: SIMD3<Double>,
                separationMinMM: Double, separationMaxMM: Double,
                rhoMin: Double, rhoMax: Double) {
        self.tensor = tensor; self.dims = dims; self.originMM = originMM
        self.spacingMM = spacingMM; self.minExtrudableWidthMM = minExtrudableWidthMM
        self.buildDirection = buildDirection
        self.separationMinMM = separationMinMM; self.separationMaxMM = separationMaxMM
        self.rhoMin = rhoMin; self.rhoMax = rhoMax
    }
}

/// The immutable per-part scene the preview needs. Baking depends ONLY on the mesh
/// (occupancy) and the field (demand) — never on the interactive params — so it is
/// built once on a data change (bar P2 / V3).
public struct LatticeSDFScene {
    public var preview: LatticeSDFPreview
    public var occupancy: LatticeVoxelGrid
    /// Truncated signed distance of the part (mm, negative inside) — the flush
    /// boundary trim (round 3). Exact near the surface, so flat faces render straight.
    public var partSDF: LatticeVoxelGrid
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
    /// The finish's own thickness (mm) — `LatticeBoundaryTreatment.faceSkinMM`. Stored
    /// because the DRESSING BAND must be a physical width, not a fraction of whatever
    /// cell happens to be local. See `rimParams`.
    public let skinMM: Double

    /// ★★★ ORGANIC: the traced struts as a distance field (mm, negative inside), on the
    /// DECLARED REGION's own bbox rather than the part's — which is what makes it
    /// viable, because the voxel is then a fraction of the design grid's and a 1-3 mm
    /// strut is several voxels across instead of sub-voxel. nil on every other
    /// algorithm. Clamped at `organicBandMM`, an UNDER-estimate and therefore safe to
    /// sphere-trace against.
    public let organicField: LatticeVoxelGrid?
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

    /// ★ `regions` CLIPS THE PREVIEW TO WHAT IS ACTUALLY SET TO LATTICE
    /// (maintainer, 2026-08-17: "Can you confirm that the preview will only show
    /// what is *actually* set to lattice"). It was NOT: occupancy came from the
    /// whole part mesh and no region reached this path at all, so the struts
    /// filled the entire interior regardless of the declarations. Empty ⇒ no
    /// clipping, which is what the settings page's sample block needs.
    public init(mesh: ViewerMesh, field: StressField?, latticeID: String,
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
                skippedFaces: Int = 0) {
        self.preview = LatticeSDFPreview(latticeID: latticeID)
        // ★★ THE PART'S INTERIOR AND THE LATTICED INTERIOR ARE TWO DIFFERENT
        // NUMBERS, and the banner needs both to tell the truth.
        //
        // ★ "No inside to fill" and "your regions matched nothing" are different
        // findings with different fixes — one is a broken import, the other is a
        // depth set too shallow. Counting only the MASKED grid would report the
        // first for both, which is a confident wrong answer.
        let solid = LatticePreviewOccupancy.occupancy(
            positions: mesh.positions, indices: mesh.indices,
            bounds: mesh.bounds, maxDim: maxDim)
        var solidInside = 0
        for v in solid.values where v > 0.5 { solidInside += 1 }
        self.partInteriorVoxelCount = solidInside
        self.skippedFaces = skippedFaces
        self.skinMM = skinMM
        self.regions = regions
        self.occupancy = LatticeRegionMask.clipped(
            solid, to: regions, whenEmpty: whenEmpty)
        self.partSDF = LatticePreviewOccupancy.signedDistance(
            positions: mesh.positions, indices: mesh.indices, like: occupancy)


        // ★ Baked from the SAME list the occupancy was masked by, on the same
        // grid, in the same pass — so no third description of "the region" can
        // exist to drift from the other two.
        if regions.contains(where: { $0.role == .include }) {
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
            let partSDFValues = self.partSDF.values
            var f = solid
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
                        let region = LatticeRegionMask.signedDistance(p, regions: regions)
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
                        f.values[i] = skinMM > 0
                            ? Float(Swift.max(region, Double(partSDFValues[i]) + skinMM))
                            : Float(region)
                        i += 1
                    }
                }
            }
            self.regionSDF = f
        } else {
            self.regionSDF = nil
        }
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
        var graded = relative
        if minimizePlastic, stageMode == .aesthetic, allowableMPa > 0,
           let rel = relative,
           let absolute = LatticePreviewOccupancy.demand(
               like: occupancy, field: field, intent: 0, allowableMPa: allowableMPa),
           absolute.values.count == rel.values.count {
            var capped = rel
            for i in 0..<capped.values.count {
                capped.values[i] = Swift.min(rel.values[i], absolute.values[i])
            }
            graded = capped
        }
        self.demand = statedDemand ?? graded

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
        var organicOut: LatticeVoxelGrid?
        var organicBand = 0.0
        var organicSaid = ""
        if let o = organic, o.minExtrudableWidthMM > 0,
           o.tensor.count == 6 * o.dims.0 * o.dims.1 * o.dims.2 {
            let occ = self.occupancy
            // The candidate set and the separation, both on the TENSOR's grid — that is
            // the grid core traces on, and resampling the declaration onto it is what
            // keeps "where he marked" and "where it traced" the same set.
            let (tnx, tny, tnz) = o.dims
            var cand = [Bool](repeating: false, count: tnx * tny * tnz)
            var sep = [Double](repeating: 0, count: tnx * tny * tnz)
            let lo = Swift.min(o.separationMinMM, o.separationMaxMM)
            let hi = Swift.max(o.separationMinMM, o.separationMaxMM)
            var n = 0
            for k in 0..<tnz { for j in 0..<tny { for i in 0..<tnx {
                let p = SIMD3<Float>(
                    Float(o.originMM.x + Double(i) * o.spacingMM),
                    Float(o.originMM.y + Double(j) * o.spacingMM),
                    Float(o.originMM.z + Double(k) * o.spacingMM))
                let g = (p - occ.origin) / occ.spacing
                let a = Int(g.x.rounded()), b = Int(g.y.rounded()), c = Int(g.z.rounded())
                guard a >= 0, b >= 0, c >= 0, a < occ.nx, b < occ.ny, c < occ.nz else { continue }
                let oi = (c * occ.ny + b) * occ.nx + a
                guard occ.values[oi] > 0.5 else { continue }
                let d = self.demand.map { Double($0.values[oi]) } ?? 0
                let idx = (k * tny + j) * tnx + i
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
                sep[idx] = hi - (hi - lo) * Swift.min(Swift.max(d, 0), 1)
                n += 1
            } } }
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
                var fs = Swift.max(0.35, Double(longest) / 384.0)
                while (Double(ext.x) / fs + 2) * (Double(ext.y) / fs + 2)
                        * (Double(ext.z) / fs + 2) > 12_000_000 { fs *= 1.25 }
                let fnx = Swift.max(2, Int(Double(ext.x) / fs) + 2)
                let fny = Swift.max(2, Int(Double(ext.y) / fs) + 2)
                let fnz = Swift.max(2, Int(Double(ext.z) / fs) + 2)
                let band = Swift.max(2.0, hi)
                if let t = TopOptKit.organicTrace(
                    nx: tnx, ny: tny, nz: tnz, spacingMM: o.spacingMM,
                    origin: o.originMM, candidate: cand, stressTensor: o.tensor,
                    separationMM: sep, minExtrudableWidthMM: o.minExtrudableWidthMM,
                    buildDirection: o.buildDirection,
                    fieldDims: (fnx, fny, fnz),
                    fieldOrigin: SIMD3<Double>(mn), fieldSpacingMM: fs,
                    bandMM: band, rhoMin: o.rhoMin, rhoMax: o.rhoMax),
                   t.field.count == fnx * fny * fnz {
                    organicOut = LatticeVoxelGrid(
                        nx: fnx, ny: fny, nz: fnz, origin: mn,
                        spacing: SIMD3<Float>(repeating: Float(fs)), values: t.field)
                    organicBand = Double(t.bandMM)
                    organicSaid = "\(t.curveCount) curves, \(t.connectorCount) connectors, "
                        + String(format: "%.2f–%.2f mm spacing",
                                 t.spacingUsedMinMM, t.spacingUsedMaxMM)
                }
            }
        }
        self.organicField = organicOut
        self.organicBandMM = organicBand
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
        self.stressDemand = LatticePreviewOccupancy.demand(like: occupancy,
                                                           field: stressField ?? field)
        self.demandIsMeasuredStress = self.stressDemand != nil

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
        if let d = self.stressDemand ?? self.demand {
            // RGBA8, matching `makeTintTexture` — the same upload path the
            // face-role tints already use, so there is one volume format here.
            var rgb = [UInt8](repeating: 0, count: d.values.count * 4)
            for i in 0..<d.values.count {
                let c = LatticeStressTint.colour(fraction: Double(d.values[i]))
                rgb[i * 4] = UInt8(max(0, min(255, c.x * 255)))
                rgb[i * 4 + 1] = UInt8(max(0, min(255, c.y * 255)))
                rgb[i * 4 + 2] = UInt8(max(0, min(255, c.z * 255)))
                rgb[i * 4 + 3] = 255
            }
            self.stressRGB = rgb
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
    }
}

extension LatticeSDFScene: LatticeSDFPreviewSummary {
    public var previewLabel: String { preview.previewLabel }

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
    private var cellGrid: LatticeVoxelGrid?
    private var sdfTex: MTLTexture?
    /// The region field's texture, or a neutral 1×1×1 "everywhere inside" volume
    /// when nothing is declared — bound ALWAYS, because the shader declares it and
    /// Metal drops a draw whose declared texture is unbound.
    private var regionTex: MTLTexture?
    /// The stress-plot colours, for the overlay — see `LatticeSDFScene.stressRGB`.
    private var stressTex: MTLTexture?
    /// ★ Whether the host wants the stress plot ON the struts this frame. Off ⇒ the
    /// density ramp, which is every frame the stress view is not up.
    var stressOverlay = false
    /// ★ The boundary dressing the Finish setting asks for — see
    /// `LatticeBoundaryTreatment.previewDressingLevel`.
    var dressingLevel: Float = 0
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
        uploadSegments(scene.preview.segments)
        sdfTex = makeVolumeTexture(scene.partSDF)
        regionTex = scene.regionSDF.flatMap { makeVolumeTexture($0) }
        organicTex = scene.organicField.flatMap { makeVolumeTexture($0) }
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
    private func steppedFinestPrintableCellMM(finest: Double) -> Double {
        guard finest > 0 else { return 0 }
        var s = finest
        while s > 0 {
            let half = s / 2
            if lineWidthMM > 0 {
                // ★★★ AGAINST THE **SPARSEST** DENSITY, NOT THE BAND'S CEILING — and
                // getting this wrong is what drew his back wall at a 0.16 mm strut.
                //
                // The strut is thinnest where the density is LOWEST, so that is where
                // printability binds. Testing `densitySpan.hi` asks "could SOME density
                // in the band print at this cell", which is true far below the cell the
                // part is actually drawn at (his was drawn at 5%). The cell then kept
                // halving to 1.80 mm and the strut came out under a third of a bead.
                // ★★★ AGAINST THE BAND'S CEILING, because the bake now RAISES the
                // density to whatever each graded cell needs (his ruling, 2026-08-23).
                // The limit is therefore the finest cell the band can reach at all, not
                // the finest cell the CURRENT density happens to print — that reading
                // pinned the floor at his region cell (4.33 mm, nCap = 1) and made the
                // whole feature arithmetically impossible at 5%.
                let rhoStar = params.lattice.printabilityDensityFloor(
                    lineWidthMM: lineWidthMM, cellMM: half)
                if rhoStar > params.densitySpan.hi + 1e-9 { break }
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
    private var solidOutlineBandMM: Double {
        guard !steppedCellMM.isEmpty else { return 0 }
        let stated = steppedCellMM.filter { $0 > 0 }
        guard let finest = stated.min(), finest > 0 else { return 0 }
        let voxel = scene.map {
            Double(Swift.max($0.occupancy.spacing.x,
                             Swift.max($0.occupancy.spacing.y, $0.occupancy.spacing.z)))
        } ?? 0
        return Swift.max(steppedFinestPrintableCellMM(finest: finest), voxel)
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
        let occ = scene.occupancy
        let mm = scene.memberThicknessMM
        guard mm.count == occ.values.count else { return nil }
        var seed = [Bool](repeating: false, count: occ.values.count)
        for i in 0..<seed.count where occ.values[i] <= 0.5 && mm[i] > 0 {
            seed[i] = true
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
        if scene.algorithm == "stepped",
           steppedCellMM.isEmpty || steppedCellMM.count != scene.regions.count,
           scene.regions.contains(where: { $0.role == .include }) {
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
        // ★ ONE CANDIDATE MAP AND ONE IN-PLANE FIELD PER BAKE. The candidate array
        // was built THREE times per bake (fit field, rim field, diagnostics) and
        // the in-plane distance BFS ran twice — the diagnostics block re-ran the
        // whole multi-source sweep just to print two numbers. On his 128-grid
        // part that is real seconds of "quite some time to load" for nothing.
        let candidate = scene.occupancy.values.map { $0 > 0.5 }
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
            if let finest = stated.min(), finest > 0 {
                baked = LatticePreviewOccupancy.steppedCellField(
                    occupancy: scene.occupancy, demand: scene.demand,
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
                                region: r, occupancy: scene.occupancy,
                                partSDF: scene.partSDF)
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
                    cellIsUserStated: steppedCellStated)
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
            NSLog("DIAG rim dressing=\(dressingBandMM) outlineBand=\(solidOutlineBandMM) lineWidth=\(lineWidthMM) "
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
               scene.regions.contains(where: { $0.role == .include }) {
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
            let rhoStar = params.lattice.printabilityDensityFloor(
                lineWidthMM: lineWidthMM, cellMM: params.cellMM)
            if rhoStar > params.densitySpan.hi + 1e-9 { cellUnprintable = true }
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
            demand: scene.stressDemand, partSDF: scene.partSDF,
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
            occupancy: occ, demand: scene.demand, plan: plan)
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
        // ★ FOUR CHANNELS SINCE STEPPED: r = demand, g = dyadic level, b = the stepped
        // cell's size in mm (0 = not stepped), a unused. The shader reads `.b` only
        // when it is positive, so the doubled path is byte-identical.
        d.pixelFormat = .rgba16Float
        d.width = grid.nx; d.height = grid.ny; d.depth = grid.nz
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        let hasStepped = f.steppedCellMM.count == grid.values.count
        var halfs = [UInt16](repeating: 0, count: grid.values.count * 4)
        for n in 0..<grid.values.count {
            halfs[4 * n] = float32to16(grid.values[n])
            halfs[4 * n + 1] = float32to16(f.level[n])
            halfs[4 * n + 2] = hasStepped ? float32to16(f.steppedCellMM[n]) : 0
            // ★ a = the owning region's tiling phase, `axis + fraction` — see
            // `LatticeCellField.steppedPhase`. 0 is "no shift", the old behaviour.
            halfs[4 * n + 3] = f.steppedPhase.count == grid.values.count
                             ? float32to16(f.steppedPhase[n]) : 0
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
        let (lo, hi) = params.densitySpan
        let K = Float(max(1e-3, params.lattice.densityCoefficient))
        let hasDemand: Float = scene?.demand != nil ? 1 : 0
        let sdfSp = scene?.partSDF.spacing ?? SIMD3<Float>(repeating: 1)
        let minSDFSpacing = min(sdfSp.x, min(sdfSp.y, sdfSp.z))
        // Indigo-FAMILY endpoints (same "amount of material" story as the proxy, bar P1),
        // but both lifted off black so a lit 3-D strut reads clearly against the dark
        // stage: sparse = bright periwinkle, dense = vivid violet. Distinct from the
        // stress blue→red rainbow.
        let sparse = RGBA(158, 176, 236)
        let dense = RGBA(96, 52, 176)
        let curve = strutCurveUniforms
        return LSDFUniforms(
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
            shadeParams: SIMD4(Float(params.uniformRelativeDensity), hasDemand, 0.03,
                               Float(debugMaxSteps)),
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
                guard let g = scene?.organicField, organicTex != nil else { return .zero }
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
            rimParams: SIMD4(Float(dressingBandMM), Float(solidOutlineBandMM),
                             doubledSolidCellsArmed ? 1 : 0, 0))
    }

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
        let lo = params.densitySpan.lo, hi = params.densitySpan.hi
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
    func bakedCellMMAt(_ p: SIMD3<Float>) -> Double {
        guard let f = cellField else { return 0 }
        let g = f.field
        guard g.nx > 0, g.ny > 0, g.nz > 0,
              g.spacing.x > 0, g.spacing.y > 0, g.spacing.z > 0 else { return 0 }
        let r = (p - g.origin) / g.spacing
        let i = Int(r.x.rounded()), j = Int(r.y.rounded()), k = Int(r.z.rounded())
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
    func bakedActivationAt(_ p: SIMD3<Float>) -> Float {
        guard let f = cellField else { return -1 }
        let g = f.field
        guard g.nx > 0, g.ny > 0, g.nz > 0,
              g.spacing.x > 0, g.spacing.y > 0, g.spacing.z > 0 else { return -1 }
        let r = (p - g.origin) / g.spacing
        let i = Int(r.x.rounded()), j = Int(r.y.rounded()), k = Int(r.z.rounded())
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
    /// A 1×1×1 volume reading +1e9 — "no strut anywhere", so a bound-but-unread
    /// texture cannot draw geometry. Metal requires the binding to exist.
    private var neutralOrganicTex: MTLTexture?
    private func neutralOrganic() -> MTLTexture? {
        if let t = neutralOrganicTex { return t }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .r32Float
        d.width = 1; d.height = 1; d.depth = 1
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        var v: Float = 1e9
        t.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1), mipmapLevel: 0, slice: 0,
                  withBytes: &v, bytesPerRow: 4, bytesPerImage: 4)
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
        d.pixelFormat = .rgba16Float
        d.width = 1; d.height = 1; d.depth = 1
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        var halfs: [UInt16] = [float32to16(0), float32to16(-1), 0, 0]
        halfs.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1), mipmapLevel: 0, slice: 0,
                      withBytes: raw.baseAddress!, bytesPerRow: 8, bytesPerImage: 8)
        }
        neutralCellTex = t
        return t
    }

    /// A 1×1×1 volume reading −1e9: inside everywhere, so an unclipped march is
    /// an exact identity rather than a special case in the shader.
    private func neutralRegion() -> MTLTexture? {
        if let t = neutralRegionTex { return t }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .r32Float
        d.width = 1; d.height = 1; d.depth = 1
        d.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        var v: Float = -1e9
        t.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1), mipmapLevel: 0, slice: 0,
                  withBytes: &v, bytesPerRow: 4, bytesPerImage: 4)
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
                                  sampler samp [[sampler(0)]],
                                  constant ShellClip& RC [[buffer(4)]],
                                  // ★ See `lsdf_gbuffer`: the same declaration list,
                                  // the same buffer index, bound by the same binder.
                                  constant float4* shellDecls [[buffer(5)]]) {
        float3 ro = U.eye.xyz;
        float3 rd = lsdf_ray(U, in.uv);
        LSDFHit h = lsdf_march(U, segs, cellTex, sdfTex, regionTex, organicTex, samp, RC,
                               shellDecls, ro, rd);
        if (!h.hit) return float4(0.0);
        float3 hitPos = h.pos; float hitRho = h.rho;
        float3 n = lsdf_normal(U, segs, cellTex, sdfTex, regionTex, samp, RC, shellDecls,
                               hitPos, hitRho);

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
                                   h.solid);
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
