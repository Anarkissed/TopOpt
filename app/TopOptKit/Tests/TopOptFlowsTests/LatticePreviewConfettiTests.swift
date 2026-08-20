// LatticePreviewConfettiTests — ★ WHY THE PREVIEW DREW SPECKS INSTEAD OF STRUTS
// (task 2026-08-18-lattice-preview-confetti).
//
// The maintainer turned the lattice preview on, on his own part, with every
// declaration healthy — 304.3 g in green, two lattice faces at 11.0 and 10.6 mm —
// and got scattered single-pixel confetti and a grey unlatticed part.
//
// ★ §2's QUESTION IS THE ONE THAT DECIDES EVERYTHING: is there lattice geometry to
// draw, or is the preview failing to draw geometry it has? These tests measure both
// numbers on his own configuration, at the two places they are decided:
//
//   `testWhatThePreviewIsHandedOnHisPart`
//       THE BAKE. Active lattice cells, segments, occupied voxels, cell size. If this
//       is ~zero the bug is upstream (§3). It is not zero — it is enormous.
//
//   `testTheStrutPreviewSurvivesTheSharedDepthBuffer`
//       THE FRAME. How many of those cells reach a pixel. Measured in the LATTICE'S
//       OWN G-BUFFER MASK (`latticeMaskDump`), which is where the shared depth test
//       PR 340 introduced actually resolves shell-vs-strut. A march that hits on
//       every pixel and wins on none reads zero here.
//
//   `testWorkspaceInputsHideTheBodyForTheStrutPreview`
//       THE ROOT CAUSE, isolated. The workspace has asked for `bodyAlpha: 0` on this
//       stage since the preview shipped (2026-07-29, `WorkspacePlaceholder` 720).
//       `Coordinator.apply` only ever handed a body alpha to the renderer INSIDE the
//       load-flow block — `if let flow = inputs.loadFlowVertices` — and the lattice
//       stage has no load flow. So the request was dropped on every frame.
//
// ★ WHY NO TEST CAUGHT IT. Every existing test that hides the body calls
// `renderer.setBodyAlpha(0)` by hand (`UnifiedShadingTests` 84/181/270,
// `UnifiedShadingEvidenceGen` 119/126/229/232, `LatticeSDFAlignmentTests` 274).
// They all pin what the RENDERER does with a hidden body. Not one of them went
// through the path that decides whether the renderer is ever told to hide it.
//
// ★ AND IT WAS INVISIBLE UNTIL PR 340. Before it, the lattice lived in its own
// transparent, DEPTH-LESS `MTKView` composited over the mesh view — it drew over an
// opaque body whether or not the body was hidden, so a dropped `bodyAlpha` cost
// nothing anyone could see. PR 340 put both objects in ONE depth buffer. The opaque
// shell then won that test at essentially every pixel, and what survived was the
// handful of pixels where a marched strut landed nearer than the wall: the confetti.

import XCTest
import Foundation
import Metal
import MetalKit
import simd
import TopOptKit
@testable import TopOptFlows
@testable import TopOptDesign

final class LatticePreviewConfettiTests: XCTestCase {

    // MARK: - his configuration (R3)

    /// ★ HIS PART, through the same importer the app uses. Not a fixture cube.
    static func hisMesh() throws -> ViewerMesh {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/M2_verticalStand.step").path
        guard FileManager.default.fileExists(atPath: fixture) else {
            throw XCTSkip("fixture absent")
        }
        let im = try TopOptKit.importMesh(path: fixture)
        return ViewerMesh(vertices: im.vertices, indices: im.indices,
                          faceIDs: im.faceIDs, faceGeometry: im.faceGeometry)
    }

    /// ★ HIS LATTICE SETTINGS, from the screen he photographed: octet, Cell size
    /// AUTO, Density SIM (= `.auto` — the mode's own title is "Auto"; the lattice
    /// page labels the on-device solid sim as its source), Finish SKIN, and the two
    /// declared faces at 11.0 mm and 10.6 mm.
    static func hisSettings() -> LatticeSettings {
        var s = LatticeSettings()
        s.enabled = true
        s.cellSizeMode = .auto
        // ★ `.sim` IS THE MODE FORMERLY SPELLED `.auto` — renamed on the
        // lattice-stage-repair branch because it is the ONLY mode that emits a
        // `grading` block, and core's grading law is a map from an FEA's von
        // Mises field. Same mode, same behaviour, and a stored "auto" still
        // decodes to it (`LatticeDensityModeRenameTests`). This is a merge
        // leftover, not a change of fixture.
        s.densityMode = .sim
        s.boundary = .fullSkin
        return s
    }

    /// ★ AND THE DEMAND FIELD IS SYNTHETIC, SAID PLAINLY. He has run the FEA; his
    /// run's captured `fields.bin` is a 256-byte stub, so there are no real von Mises
    /// scalars for this part in the repo. The field grades strut RADII and nothing
    /// else — it cannot move a depth test — so the numbers below do not depend on it,
    /// and the no-field case is measured too (`fieldless` below).
    static func gradedField(_ bounds: MeshBounds) -> StressField {
        let ext = bounds.max - bounds.min
        let n = 40
        let sp = simd_length(ext) / Float(n)
        var vals = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            vals[(k * n + j) * n + i] = Float(j) / Float(n - 1)
        } } }
        return StressField(nx: n, ny: n, nz: n, origin: bounds.min, spacing: sp, values: vals)
    }

    /// The scene the workspace's `buildStrutScene()` builds, with the same arguments.
    static func hisScene(_ mesh: ViewerMesh, field: StressField?) -> LatticeSDFScene {
        LatticeSDFScene(mesh: mesh, field: field, latticeID: hisSettings().topologyID)
    }

    static func hisParams() -> LatticeProxyParams {
        hisSettings().proxyParams(limits: TopOptKit.latticeLimits(topology: hisSettings().topologyID))
    }

    // MARK: - §2: THE NUMBER, BEFORE ANY FIX

    /// ★ IS THERE LATTICE GEOMETRY TO DRAW? Reported as counts, on his own part, at
    /// his own settings. §2(d): nothing downstream of this may be theorised without it.
    func testWhatThePreviewIsHandedOnHisPart() throws {
        let mesh = try Self.hisMesh()
        let params = Self.hisParams()
        let field = Self.gradedField(mesh.bounds)
        let scene = Self.hisScene(mesh, field: field)
        let fieldless = Self.hisScene(mesh, field: nil)

        let cells = LatticePreviewOccupancy.cellField(
            occupancy: scene.occupancy, demand: scene.demand, cellMM: params.cellMM)
        let activeCells = cells.values.filter { $0 >= 0 }.count
        let occupied = scene.occupancy.values.filter { $0 > 0.5 }.count
        let cellsNoField = LatticePreviewOccupancy.cellField(
            occupancy: fieldless.occupancy, demand: nil, cellMM: params.cellMM)
        let activeNoField = cellsNoField.values.filter { $0 >= 0 }.count

        // The strut radii the preview actually renders, in MILLIMETRES (§4a).
        let preview = scene.preview
        let rLo = Double(preview.normalizedRadius(relativeDensity: params.minRelativeDensity))
            * params.cellMM
        let rHi = Double(preview.normalizedRadius(relativeDensity: params.maxRelativeDensity))
            * params.cellMM
        let ext = mesh.bounds.max - mesh.bounds.min

        print("""

        ================================================================================
        §2 — WHAT THE LATTICE PREVIEW IS HANDED, ON HIS OWN CONFIGURATION
        part          Fixtures/M2_verticalStand.step (STEP, app importer)
                      \(mesh.triangleCount) triangles · bounds \(f2(ext.x)) × \(f2(ext.y)) × \(f2(ext.z)) mm
        lattice       \(preview.lattice.id) · cell mode AUTO · density AUTO · finish SKIN
        cell size     \(f2(params.cellMM)) mm  (the value the PREVIEW folds at)
        density band  \(f3(params.minRelativeDensity)) … \(f3(params.maxRelativeDensity))
        strut radius  \(f2(rLo)) … \(f2(rHi)) mm

        SEGMENTS in the tiled soup .................. \(preview.segments.count)
        OCCUPIED VOXELS (part interior, \(scene.occupancy.nx)×\(scene.occupancy.ny)×\(scene.occupancy.nz)) ... \(occupied)
        ACTIVE LATTICE CELLS (graded) .............. \(activeCells) of \(cells.count)
        ACTIVE LATTICE CELLS (no field) ............ \(activeNoField) of \(cellsNoField.count)
        ================================================================================
        """)

        // ★ §2(b)/(c): this is the fork. The bake is not empty — not close to empty —
        // so the bug is NOT upstream, and §3 does not apply.
        XCTAssertGreaterThan(preview.segments.count, 0,
                             "§2: the segment soup the shader tiles must not be empty")
        XCTAssertGreaterThan(occupied, 1000,
                             "§2: his part must solid-voxelise to a real interior")
        XCTAssertGreaterThan(activeCells, 100,
                             "§2: the preview must be handed a large number of ACTIVE "
                             + "lattice cells — if this were ~zero the bug would be "
                             + "upstream (§3) and every later step here would be wrong")
        // The no-field bake must be just as full: a missing demand field grades the
        // radii, it does not switch cells off (the silent-fallback failure mode §3c
        // warns about would show up here).
        XCTAssertEqual(activeCells, activeNoField,
                       "§3(c): a missing demand field must not silently empty the preview")
    }

    // MARK: - §4 + the root cause: the PRODUCTION path

    /// ★ THE WORKSPACE ASKS FOR A HIDDEN BODY AND THE RENDERER MUST GET IT.
    ///
    /// `WorkspacePlaceholder` 720 has passed `bodyAlpha: 0` whenever the strut layer
    /// is up since the preview shipped. This drives the very same input struct through
    /// the very same `Coordinator.apply` the SwiftUI update calls, with NO load flow —
    /// which is every lattice-stage frame there has ever been.
    @MainActor
    func testWorkspaceInputsHideTheBodyForTheStrutPreview() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let mesh = try Self.hisMesh()
        guard let renderer = MeshRenderer(device: device, sampleCount: 1) else {
            throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
        }
        renderer.setMesh(mesh)

        let coord = MetalMeshView.Coordinator()
        coord.renderer = renderer
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 256, height: 256), device: device)

        var inputs = Self.baseInputs()
        inputs.mesh = mesh
        // The lattice stage, exactly as the workspace builds it: the layer installed,
        // the body hidden beside it (bar A3), and NO load flow anywhere.
        inputs.bodyAlpha = 0
        inputs.latticeLayer = LatticeLayerInputs(scene: Self.hisScene(mesh, field: nil),
                                                 params: Self.hisParams(),
                                                 sceneToken: 1,
                                                 faceTints: [:])
        XCTAssertNil(inputs.loadFlowVertices,
                     "the lattice stage has no load flow — that is the whole point")
        coord.apply(inputs, to: view)

        XCTAssertEqual(renderer.bodyAlpha, 0, accuracy: 1e-6,
                       "THE ROOT CAUSE: the workspace asked for a hidden body on the "
                       + "lattice stage and `apply` never handed it over, because the "
                       + "only `setBodyAlpha` call site sat inside the load-flow "
                       + "block. With PR 340's shared depth buffer the opaque shell "
                       + "then occludes the whole lattice.")

        // And the reverse: turning the layer off must restore an opaque body, with no
        // load flow involved on that side either.
        var off = inputs
        off.bodyAlpha = 1
        off.latticeLayer = nil
        coord.apply(off, to: view)
        XCTAssertEqual(renderer.bodyAlpha, 1, accuracy: 1e-6,
                       "leaving the lattice stage must bring the body back")
    }

    /// ★ AND THE PIXELS — BOTH ARMS, IN ONE RUN, ON ONE RENDERER.
    ///
    /// Arm A is the PRODUCTION path: the workspace's own `MeshViewInputs` through the
    /// coordinator's own `apply`. Arm B is the same frame with the body hidden the way
    /// every existing test hides it — `setBodyAlpha(0)` called by hand, which is what
    /// bar A3 has always intended and what the picture is supposed to be.
    ///
    /// The two must be THE SAME FRAME. That they are not is the defect, and the shape
    /// of the difference is the maintainer's confetti: the lattice does not merely
    /// lose pixels, it loses the COHERENT ones and keeps a scatter of isolated
    /// z-fighting specks along the walls it is trimmed flush against.
    @MainActor
    func testTheStrutPreviewSurvivesTheSharedDepthBuffer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let mesh = try Self.hisMesh()
        guard let renderer = MeshRenderer(device: device, sampleCount: 4) else {
            throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
        }
        try XCTSkipUnless(renderer.latticePipelinesDidBuild,
                          "the unified lattice MSL must compile or this measures nothing")
        renderer.setMesh(mesh)
        renderer.camera.setOrientation(azimuth: 0.7, elevation: 0.4)

        let coord = MetalMeshView.Coordinator()
        coord.renderer = renderer
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 512, height: 512), device: device)

        var inputs = Self.baseInputs()
        inputs.mesh = mesh
        inputs.bodyAlpha = 0
        inputs.latticeLayer = LatticeLayerInputs(scene: Self.hisScene(mesh, field: nil),
                                                 params: Self.hisParams(),
                                                 sceneToken: 1,
                                                 faceTints: [:])
        // ARM A — through `apply`, exactly as a SwiftUI update does it.
        coord.apply(inputs, to: view)
        let appliedAlpha = renderer.bodyAlpha
        let production = try XCTUnwrap(renderer.latticeMaskDump(size: 512),
                                       "the lattice must be in the G-buffer at all")

        // ARM B — the same renderer, told directly. Nothing else moves.
        renderer.setBodyAlpha(0)
        let intended = try XCTUnwrap(renderer.latticeMaskDump(size: 512))

        print("""

        ================================================================================
        §4 — HOW MUCH OF THAT LATTICE REACHES A PIXEL
        GPU                     \(device.name)   ★ macOS, headless — NOT his iPad.
        G-buffer                \(production.width)×\(production.height)
        body alpha the workspace asked for   0
        body alpha `apply` delivered         \(appliedAlpha)

                                    lattice pixels won      isolated (confetti)
          A  through `apply`        \(production.covered)  (\(pct(production.coveredFraction)))   \(pct(production.isolatedFraction))
          B  body hidden directly   \(intended.covered)  (\(pct(intended.coveredFraction)))   \(pct(intended.isolatedFraction))
        ================================================================================
        """)

        XCTAssertEqual(production.covered, intended.covered,
                       "§4: the frame the PRODUCTION path draws must be the frame the "
                       + "lattice stage is supposed to draw. It is not: `apply` never "
                       + "delivered `bodyAlpha`, so the opaque shell stays in the "
                       + "shared depth buffer and wins nearly every pixel the lattice "
                       + "should own.")
        XCTAssertLessThan(production.isolatedFraction, 2 * intended.isolatedFraction,
                          "§4/R5: what survives must be STRUTS, not a scatter of "
                          + "isolated z-fighting specks along the flush-trimmed walls "
                          + "— which is exactly what the maintainer photographed.")
    }

    // MARK: - §5(b): A PREVIEW WITH NOTHING TO DRAW SAYS SO

    /// ★ THE SECOND DEFECT, AND IT IS INDEPENDENT OF THE FIRST. The overlay was
    /// `if showStrutPreview, let scene = strutScene` — a preview that is ON and has
    /// no scene rendered NO TEXT AT ALL. Turn it on before a mesh exists, or during
    /// the second the bake takes, and the toggle says "on", the viewport does not
    /// change, and nothing anywhere says why.
    func testAPreviewWithNothingToDrawSaysSo() throws {
        // Off: no banner. The user has not asked for one.
        XCTAssertNil(LatticePreviewBanner.make(previewOn: false, hasModel: true, scene: nil))

        // On, no model.
        let noModel = try XCTUnwrap(
            LatticePreviewBanner.make(previewOn: true, hasModel: false, scene: nil))
        XCTAssertTrue(noModel.isEmpty)

        // On, model, bake not landed.
        let baking = try XCTUnwrap(
            LatticePreviewBanner.make(previewOn: true, hasModel: true, scene: nil))
        XCTAssertTrue(baking.isEmpty)

        // On, model, scene baked but the part has no interior to fill.
        let hollow = LatticePreviewSummaryValues(
            interiorVoxelCount: 0,
            previewLabel: LatticeSDFPreview(latticeID: "octet").previewLabel)
        let empty = try XCTUnwrap(
            LatticePreviewBanner.make(previewOn: true, hasModel: true, scene: hollow))
        XCTAssertTrue(empty.isEmpty)

        // And the shipping case is UNCHANGED — the honesty label, byte for byte.
        let full = LatticePreviewSummaryValues(
            interiorVoxelCount: 1,
            previewLabel: LatticeSDFPreview(latticeID: "octet").previewLabel)
        let drawing = try XCTUnwrap(
            LatticePreviewBanner.make(previewOn: true, hasModel: true, scene: full))
        XCTAssertFalse(drawing.isEmpty)
        XCTAssertEqual(drawing.text,
                       "LATTICE PREVIEW — live strut geometry, not the exported mesh",
                       "bar P1's label must not have moved")

        // ★ EVERY EMPTY STATE HAS A REASON, IN PLAIN WORDS, UNDER 25 (§5c).
        let empties = [noModel, baking, empty]
        for b in empties {
            let words = b.text.split(whereSeparator: { $0 == " " }).count
            XCTAssertLessThanOrEqual(words, 25, "§5(c): \"\(b.text)\" is \(words) words")
            for jargon in ["SDF", "occupancy", "voxel", "march", "raymarch", "G-buffer",
                           "shader", "depth buffer", "alpha"] {
                XCTAssertFalse(b.text.lowercased().contains(jargon.lowercased()),
                               "§5(c): no jargon — \"\(b.text)\" contains \"\(jargon)\"")
            }
            XCTAssertFalse(b.text.isEmpty, "an empty preview must not be silent")
        }

        print("""

        ================================================================================
        §5(b) — WHAT A PREVIEW WITH NOTHING TO DRAW NOW SAYS  (3 strings)
          no model open    \(noModel.text)
          bake pending     \(baking.text)
          nothing to fill  \(empty.text)
        and unchanged when it IS drawing:
                           \(drawing.text)
        ================================================================================
        """)
    }

    /// And the scene really does count its own interior — the number the banner
    /// keys on is not a placeholder.
    func testTheSceneCountsItsOwnInterior() throws {
        let mesh = try Self.hisMesh()
        let scene = Self.hisScene(mesh, field: nil)
        XCTAssertGreaterThan(scene.interiorVoxelCount, 1000,
                             "his part has an interior; the banner must not call it empty")
        XCTAssertEqual(scene.interiorVoxelCount,
                       scene.occupancy.values.filter { $0 > 0.5 }.count,
                       "the stored count must be the grid's own count")
    }

    // MARK: - helpers

    /// The mesh view's inputs with everything this task does not exercise left at the
    /// workspace's own defaults — the four fields with no default in the struct.
    static func baseInputs() -> MeshViewInputs {
        MeshViewInputs(settleRotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
                       settleAnimated: false, showGround: true, faceToolActive: false)
    }

    private func f2(_ v: Double) -> String { String(format: "%.2f", v) }
    private func f2(_ v: Float) -> String { String(format: "%.2f", v) }
    private func f3(_ v: Double) -> String { String(format: "%.3f", v) }
    private func pct(_ v: Double) -> String { String(format: "%.2f%%", v * 100) }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: ★★ THE PREVIEW MASKED TO HIS DECLARED REGIONS
//
// ★ THE FINDING THIS FILE'S §3a RECORDED AND DELIBERATELY DID NOT FIX: the
// raymarched preview lattices the ENTIRE interior and ignores every face
// declaration, so it shows MORE lattice than the job would build. On his part
// that was 1,689 active cells of 6,032 — the whole solid, not two ~11 mm skins.
//
// ★ THE NUMBER IS THE WHOLE POINT (bar 5). A mask that silently lights
// everything, or silently lights nothing, is the failure mode — and only the
// count catches either.

@MainActor
final class LatticePreviewRegionMaskTests: XCTestCase {

    /// His two declared faces, at the depths on his screen.
    private static let hisFaceDepths: [(face: FaceID, depthMM: Double)] =
        [(15, 11.0), (2, 10.6)]

    /// ★ THE EMISSION THE JOB ITSELF USES — `LatticeRegionEmission.regions`, the
    /// same call `ProjectModel.latticeJobRegions()` makes, resolving faces the
    /// same way. Deliberately NOT a hand-built slab: re-deriving the geometry in
    /// the test would let the test agree with itself while disagreeing with the
    /// run, which is the exact class of defect this project keeps finding.
    private static func hisRegions(_ mesh: ViewerMesh)
        -> LatticeRegionEmission.Result {
        let gid = UUID()
        let group = SelectionGroup(id: gid, name: "A", colorIndex: 0,
                                   faces: hisFaceDepths.map(\.face))
        let resolve: (FaceID) -> LatticeRegionEmission.ResolvedFace? = { f in
            guard let geo = mesh.faceGeometry(f) else { return nil }
            if geo.isCylinder {
                guard let span = mesh.faceAxialSpan(
                    f, axisPoint: SIMD3<Float>(geo.axisPoint),
                    axisDir: SIMD3<Float>(geo.axisDir)) else { return nil }
                return .cylinder(axisPoint: geo.axisPoint, axisDir: geo.axisDir,
                                 radiusMM: geo.cylinderRadiusMM,
                                 spanLoMM: Double(span.lo), spanHiMM: Double(span.hi))
            }
            if geo.isPlane {
                guard let o = mesh.facePlaneOutline(
                    f, planeNormal: SIMD3<Float>(geo.planeNormal),
                    planeOrigin: SIMD3<Float>(geo.planeOrigin)) else { return nil }
                return .plane(center: SIMD3<Double>(o.center), normal: geo.planeNormal,
                              halfUMM: Double(o.halfU), halfWMM: Double(o.halfV))
            }
            return nil
        }
        var depths: [String: Double] = [:]
        for d in hisFaceDepths {
            depths[LatticeSelectableRef.face(group: gid, face: d.face).key] = d.depthMM
        }
        return LatticeRegionEmission.regions(
            groups: [group], roles: [gid: .include],
            primitives: { _ in [] }, includePrimitives: [],
            faceDepthMM: 4.0,
            selectableDepthMM: depths,
            resolve: resolve)
    }

    private static func activeCells(_ scene: LatticeSDFScene,
                                    cellMM: Double) -> Int {
        LatticePreviewOccupancy.cellField(occupancy: scene.occupancy,
                                          demand: scene.demand, cellMM: cellMM)
            .values.filter { $0 >= 0 }.count
    }

    /// ★★ THE FINDING, AS A NUMBER, BEFORE AND AFTER — on his own part, at his
    /// own settings, through the job's own emission.
    func testTheMaskCutsThePreviewToHisDeclaredRegions() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let params = LatticePreviewConfettiTests.hisParams()
        let field = LatticePreviewConfettiTests.gradedField(mesh.bounds)
        let emission = Self.hisRegions(mesh)

        let before = LatticeSDFScene(mesh: mesh, field: field,
                                     latticeID: params.latticeID)
        let after = LatticeSDFScene(mesh: mesh, field: field,
                                    latticeID: params.latticeID,
                                    regions: emission.regions,
                                    whenEmpty: .latticeNothing,
                                    skippedFaces: emission.skippedFaces)

        let cellsBefore = Self.activeCells(before, cellMM: params.cellMM)
        let cellsAfter = Self.activeCells(after, cellMM: params.cellMM)
        let voxBefore = before.interiorVoxelCount
        let voxAfter = after.interiorVoxelCount

        print("""

        ================================================================================
        THE PREVIEW, MASKED TO HIS DECLARED REGIONS
        part            Fixtures/M2_verticalStand.step
        declared        Face 15 @ 11.0 mm · Face 2 @ 10.6 mm  (role: lattice)
        regions emitted \(emission.regions.count)   skipped faces \(emission.skippedFaces)
        cell size       \(params.cellMM) mm
        --------------------------------------------------------------------------------
                              interior voxels     active lattice cells
        BEFORE (no mask)      \(voxBefore)                \(cellsBefore)
        AFTER  (masked)       \(voxAfter)                \(cellsAfter)
        --------------------------------------------------------------------------------
        part interior (unmasked, both)  \(after.partInteriorVoxelCount)
        ================================================================================

        """)

        // ★ THE EMISSION PRODUCED SOMETHING. If it did not, every number below is
        // vacuous and the test would "pass" while measuring nothing.
        XCTAssertFalse(emission.regions.isEmpty,
                       "★ his two faces must emit regions, or this test is vacuous")

        // ★ THE MASK CUT IT DOWN — the finding.
        XCTAssertLessThan(cellsAfter, cellsBefore,
                          "★ the preview must show LESS than the whole solid")
        XCTAssertLessThan(voxAfter, voxBefore)

        // ★★ AND IT DID NOT CUT IT TO NOTHING. "Lights everything" and "lights
        // nothing" are the two failure modes, and only a two-sided bound catches
        // both — a mask that emptied the part would satisfy the assertion above.
        XCTAssertGreaterThan(cellsAfter, 0,
                             "★ a mask that lights NOTHING is the other failure mode")

        // ★ THE PART'S OWN INTERIOR IS UNTOUCHED BY THE MASK, so the banner can
        // still tell "no inside at all" from "the regions matched nothing".
        XCTAssertEqual(after.partInteriorVoxelCount, voxBefore,
                       "★ the unmasked interior is the same part either way")
    }

    /// ★ NO DECLARATIONS ⇒ TODAY'S BEHAVIOUR, EXACTLY. The settings page's sample
    /// block has no regions by construction and must keep lattices everywhere.
    func testAnEmptyRegionListStillLatticesEverythingUnderTheSamplePolicy() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let params = LatticePreviewConfettiTests.hisParams()
        let plain = LatticeSDFScene(mesh: mesh, field: nil,
                                    latticeID: params.latticeID)
        let sample = LatticeSDFScene(mesh: mesh, field: nil,
                                     latticeID: params.latticeID,
                                     regions: [], whenEmpty: .latticeEverything)
        XCTAssertEqual(sample.interiorVoxelCount, plain.interiorVoxelCount,
                       "★ byte-identical to the pre-mask behaviour")
    }

    /// ★ AND ON THE STAGE, NO DECLARATIONS ⇒ NOTHING LATTICED. The user has
    /// marked nothing; the honest picture is a solid part, not a full one.
    func testAnEmptyRegionListLatticesNothingUnderTheStagePolicy() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let params = LatticePreviewConfettiTests.hisParams()
        let stage = LatticeSDFScene(mesh: mesh, field: nil,
                                    latticeID: params.latticeID,
                                    regions: [], whenEmpty: .latticeNothing)
        XCTAssertEqual(stage.interiorVoxelCount, 0)
        XCTAssertGreaterThan(stage.partInteriorVoxelCount, 0,
                             "★ …and the PART still has an interior, which is what "
                             + "lets the banner say why it is empty")
    }
}
