// SmoothingPageTests.swift — task 2026-08-02-smoothing-page, the app bars.
//
//  AE1  FROZEN MEANS FROZEN (app side). The brush REFUSES a frozen triangle and
//       never writes a non-zero weight at a frozen vertex. The memcmp half of
//       AE1 lives in core (`core/tests/validation/test_smooth_brush.cpp`) on the
//       real variant; these are the two app-side layers that keep a frozen
//       vertex from ever being asked for.
//  AE2  THE RECEIPT IS THE PRODUCT. Before AND after are produced by the
//       certification runner — the before is MEASURED, never the run's
//       remembered margin.
//  AE3  THE RETAINED JOB IS USED. The load case is parsed from the retained job
//       document, and the test fails if the project's current editable state is
//       substituted.
//  AE5  H1 IS A STATE, NOT A CRASH. A non-convergent re-certification reports
//       legibly and keeps the previous receipt visibly STALE.
//  AE6  ONE SELECTION MODEL — the same assertion shape as PR 274's M1.
//  AE7  LAYOUT PARITY — one chrome geometry, read by all three pages.
//  AE8  SMOOTH-THEN-LATTICE, and not the reverse.
//  AE9  NON-DESTRUCTIVE — discarding returns the original variant bit-identically.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class SmoothingPageTests: XCTestCase {

    // MARK: - fixtures

    /// A tiny two-triangle strip: 4 vertices, triangles (0,1,2) and (1,3,2).
    private let indices: [Int32] = [0, 1, 2, 1, 3, 2]
    private let vertices: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0]

    /// Vertex 3 is frozen — it belongs to triangle 1 only, so triangle 0 stays
    /// fully paintable and triangle 1 is partly frozen.
    private func mask(frozen: [Bool]) -> SmoothFreezeMask {
        SmoothFreezeMask(frozen: frozen, toleranceMM: 0.75)
    }

    private func brush(frozen: [Bool] = [false, false, false, true])
        -> SmoothBrushModel {
        SmoothBrushModel(indices: indices, vertexCount: 4, freeze: mask(frozen: frozen))
    }

    /// The retained job document a run kept beside its variant (PR 274).
    private func retainedJob(anchor: Int = 3, loadFace: Int = 7,
                             force: [Double] = [0, 0, -500],
                             material: String = "PLA",
                             resolution: Int = 64) -> Data {
        let job: [String: Any] = [
            "model": "bracket.stl",
            "material": material,
            "mode": "minimize_plastic",
            "resolution": resolution,
            "loads": [
                "anchor_face_ids": [anchor],
                "groups": [["face_ids": [loadFace], "force": force]],
                "build_dir": [0.0, 0.0, -1.0],
                "infill_percent": 35,
                "clearances": [
                    ["kind": "bolt",
                     "geometry": ["axis_point": [1.0, 2.0, 3.0],
                                  "axis_dir": [0.0, 0.0, 1.0],
                                  "radius_mm": 2.5, "half_length_mm": 6.0]],
                ],
                "face_protections": [11],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: job)
    }

    private func certification(subject: SmoothCertification.Subject,
                               margin: Double, accepted: Bool,
                               minFeature: Int = 0, nonConvergent: Bool = false,
                               path: String = "/tmp/x.stl") -> SmoothCertification {
        SmoothCertification(subject: subject, TopOptKit.MeshCertification(
            accepted: accepted, nonConvergent: nonConvergent,
            marginWorstCase: margin, marginInPlane: margin + 1,
            marginInterlayer: margin, marginEffective: margin * 0.2,
            marginRequired: 1.5, maxStressMPa: 14.459,
            minFeatureViolations: minFeature, voxelMassGrams: 40,
            meshMassGrams: 41, spacingMM: 1.25, meshVolumeFraction: 0.31,
            voxelVolumeFraction: 0.33, meshPath: path))
    }

    private func context(latticed: Bool = false, job: Data? = nil,
                         reportedMargin: Double = 9.99) -> SmoothVariantContext {
        SmoothPageEntry.context(
            runName: "Bracket", variantIndex: 1, requestedVolumeFraction: 0.6,
            massGrams: 41.2, reportedMargin: reportedMargin, accepted: true,
            pageMesh: SmoothPageMesh(path: "/tmp/variant_1.stl",
                                     vertices: vertices, indices: indices),
            latticed: latticed,
            retainedJob: job ?? retainedJob(), modelPath: "/tmp/bracket.stl")
    }

    // MARK: - AE1 (app side) · the brush cannot reach a frozen vertex

    func testBrushRefusesATriangleWhoseEveryVertexIsFrozen() {
        // Triangle 0 = (0,1,2), triangle 1 = (1,3,2). Freeze 1, 2, 3 → triangle 1
        // is entirely frozen; triangle 0 still has vertex 0 free.
        var b = brush(frozen: [false, true, true, true])
        XCTAssertTrue(b.paintable(triangle: 0))
        XCTAssertFalse(b.paintable(triangle: 1),
                       "a triangle with no movable vertex must not be paintable")

        let id = b.addRegion(strength: 1.0)
        let edit = b.paint(.add, triangles: [0, 1])
        XCTAssertEqual(edit.changes.map(\.triangle), [0],
                       "the fully-frozen triangle is REFUSED, not painted-then-ignored")
        XCTAssertEqual(b.triangleCount(id), 1)
    }

    func testFrozenVerticesNeverReceiveAWeightEvenWhenPaintedOver() {
        var b = brush(frozen: [false, false, false, true])
        b.addRegion(strength: 0.8)
        b.paint(.add, triangles: [0, 1])   // triangle 1 touches the frozen vertex 3
        let w = b.vertexWeights()
        XCTAssertEqual(w.count, 4)
        XCTAssertEqual(w[3], 0,
                       "AE1: a frozen vertex gets weight 0 whatever the strokes say")
        XCTAssertEqual(w[0], 0.8, accuracy: 1e-12)
        XCTAssertEqual(w[1], 0.8, accuracy: 1e-12)
        XCTAssertEqual(w[2], 0.8, accuracy: 1e-12)

        // And it is REPORTED, not silently absorbed.
        let s = b.summaries().first!
        XCTAssertEqual(s.frozenTouched, 1,
                       "the brush stopping at a frozen surface is surfaced")
    }

    func testBrushIsInertUntilCoreHasAnsweredWhatIsFrozen() {
        var b = SmoothBrushModel(indices: indices, vertexCount: 4, freeze: .unavailable)
        XCTAssertFalse(b.canPaint)
        XCTAssertNotNil(b.unusableReason)
        b.addRegion(strength: 1)
        XCTAssertTrue(b.paint(.add, triangles: [0, 1]).isEmpty,
                      "the brush must not paint into the unknown")
        XCTAssertEqual(b.vertexWeights(), [0, 0, 0, 0])

        // A mask that describes a DIFFERENT mesh is refused too, loudly.
        var wrong = SmoothBrushModel(indices: indices, vertexCount: 4,
                                     freeze: mask(frozen: [false, false]))
        XCTAssertFalse(wrong.canPaint)
        XCTAssertTrue(wrong.unusableReason?.contains("different mesh") == true)
        wrong.addRegion()
        XCTAssertTrue(wrong.paint(.add, triangles: [0]).isEmpty)
    }

    // MARK: - LOCAL strength (task item 3)

    func testStrengthIsPerRegionAndTheStrongestRegionWins() {
        var b = brush(frozen: [false, false, false, false])
        let soft = b.addRegion(strength: 0.20)
        b.paint(.add, triangles: [0], into: soft)
        let hard = b.addRegion(strength: 0.90)
        b.paint(.add, triangles: [1], into: hard)

        let w = b.vertexWeights()
        XCTAssertEqual(w[0], 0.20, accuracy: 1e-12, "vertex only in the soft region")
        XCTAssertEqual(w[3], 0.90, accuracy: 1e-12, "vertex only in the hard region")
        // Vertices 1 and 2 are shared by both triangles → the STRONGEST wins,
        // deterministically, and never exceeds either region's stated strength.
        XCTAssertEqual(w[1], 0.90, accuracy: 1e-12)
        XCTAssertEqual(w[2], 0.90, accuracy: 1e-12)
        XCTAssertEqual(b.maxStrength, 0.90, accuracy: 1e-12)

        // The page sends `maxStrength` and the NORMALIZED weights, so core's
        // `strength * w[v]` reproduces each region's own number exactly.
        let n = b.normalizedWeights()
        XCTAssertEqual(b.maxStrength * n[0], 0.20, accuracy: 1e-12)
        XCTAssertEqual(b.maxStrength * n[3], 0.90, accuracy: 1e-12)
    }

    func testStrengthIsReversibleWithoutRepainting() {
        var b = brush(frozen: [false, false, false, false])
        let id = b.addRegion(strength: 0.5)
        b.paint(.add, triangles: [0, 1])
        let painted = b.assignments
        b.setStrength(id, 0.1)
        XCTAssertEqual(b.assignments, painted, "a strength change repaints nothing")
        XCTAssertEqual(b.vertexWeights()[0], 0.1, accuracy: 1e-12)
        b.setStrength(id, 0)
        XCTAssertFalse(b.hasEffect, "strength 0 makes the region inert but keeps it listed")
        XCTAssertEqual(b.regions.count, 1)
    }

    func testBrushStrokesAreExactlyInvertible() {
        var b = brush(frozen: [false, false, false, false])
        b.addRegion(strength: 0.5)
        let before = b.assignments
        let edit = b.paint(.add, triangles: [0, 1])
        XCTAssertNotEqual(b.assignments, before)
        b.undo(edit)
        XCTAssertEqual(b.assignments, before, "undo restores the exact prior state")
        b.redo(edit)
        XCTAssertEqual(b.assignments.count, 2)
    }

    // MARK: - the brush is VISIBLE, and so is what it cannot touch

    func testFrozenVerticesAreTintedBeforeAnythingIsPainted() {
        let b = brush(frozen: [false, false, false, true])
        let tints = b.vertexTints()
        XCTAssertEqual(tints.count, 4)
        XCTAssertEqual(tints[3].w, 0.34, accuracy: 1e-6,
                       "a frozen vertex is tinted with NOTHING painted — the user "
                       + "sees what the brush will refuse before trying it")
        XCTAssertEqual(tints[0], .zero, "an unpainted free vertex is clear")
    }

    func testPaintedRegionsTintByTheirOwnStrengthAndFrozenStillWins() {
        var b = brush(frozen: [false, false, false, true])
        let soft = b.addRegion(strength: 0.0)
        b.paint(.add, triangles: [0], into: soft)
        var tints = b.vertexTints()
        XCTAssertGreaterThan(tints[0].w, 0,
                             "a strength-0 region is still visibly painted — "
                             + "'I brushed here and turned it off' is a visible state")

        b.setStrength(soft, 1.0)
        let strong = b.vertexTints()
        XCTAssertGreaterThan(strong[0].w, tints[0].w,
                             "opacity rises with the region's strength")

        // Triangle 1 touches the frozen vertex 3; the frozen tint wins there.
        b.paint(.add, triangles: [1], into: soft)
        tints = b.vertexTints()
        XCTAssertEqual(tints[3].w, 0.34, accuracy: 1e-6,
                       "frozen wins over a stroke that touched it")
    }

    func testTheBrushIsInvisibleUntilTheFreezeMaskIsKnown() {
        var b = SmoothBrushModel(indices: indices, vertexCount: 4, freeze: .unavailable)
        b.addRegion(strength: 1)
        XCTAssertEqual(b.vertexTints(), [.zero, .zero, .zero, .zero],
                       "with no mask there is nothing honest to draw")
    }

    // MARK: - AE3 · the RETAINED job is used, not the project's current state

    func testLoadCaseIsReadFromTheRetainedJobDocument() throws {
        let lc = try SmoothRecertLoadCase.fromRetainedJob(retainedJob())
        XCTAssertEqual(lc.material, "PLA")
        XCTAssertEqual(lc.resolution, 64)
        XCTAssertEqual(lc.anchorFaceIDs, [3])
        XCTAssertEqual(lc.loadGroups.count, 1)
        XCTAssertEqual(lc.loadGroups[0].faceIDs, [7])
        XCTAssertEqual(lc.loadGroups[0].force, SIMD3(0, 0, -500))
        XCTAssertEqual(lc.buildDirection, SIMD3(0, 0, -1))
        XCTAssertEqual(lc.infillPercent, 35)
        XCTAssertEqual(lc.freeze.count, 1, "the run's keep-clear bore is a freeze region")
        XCTAssertEqual(lc.freeze[0].radiusMM, 2.5)
        XCTAssertEqual(lc.protectedFaceIDs, [11])
        XCTAssertEqual(lc.structurallyFrozenFaceIDs, [3, 7, 11])
    }

    /// THE AE3 BAR ITSELF. The project's current editable state is moved to a
    /// DIFFERENT load case; the re-certification must still resolve the retained
    /// one. This test fails the moment anything substitutes the live state.
    func testSubstitutingTheProjectsCurrentStateWouldFail() throws {
        let retained = retainedJob(anchor: 3, loadFace: 7, force: [0, 0, -500],
                                   material: "PLA", resolution: 64)
        // What the user has NOW: a different anchor, a different face, ten times
        // the force, a different material and a different resolution.
        let current = retainedJob(anchor: 11, loadFace: 13, force: [0, 0, -5000],
                                  material: "PETG", resolution: 128)

        let ctx = context(job: retained)
        let resolved = try XCTUnwrap(ctx.loadCase)
        let live = try SmoothRecertLoadCase.fromRetainedJob(current)

        XCTAssertNotEqual(resolved, live,
                          "the fixture must actually differ, or this bar proves nothing")
        XCTAssertEqual(resolved.anchorFaceIDs, [3])
        XCTAssertEqual(resolved.loadGroups[0].faceIDs, [7])
        XCTAssertEqual(resolved.loadGroups[0].force, SIMD3(0, 0, -500))
        XCTAssertEqual(resolved.material, "PLA")
        XCTAssertEqual(resolved.resolution, 64)

        // Structural half: there is nowhere for the live state to enter. The
        // context builder takes no ProjectModel / ForceModel / SelectionModel, and
        // the page's own wiring reads the retained artifacts.
        // Comments are stripped first: this asserts what the CODE can reach, not
        // what the prose mentions (the file's own doc comment names these types to
        // explain why they are absent).
        let code = try codeOnly(sourceURL("SmoothingVariantSession.swift"))
        for banned in ["ProjectModel", "ForceModel", "SelectionModel"] {
            XCTAssertFalse(code.contains(banned),
                           "the load-case resolver must not be able to reach \(banned)")
        }
        let ws = try String(contentsOf: sourceURL("WorkspacePlaceholder.swift"),
                            encoding: .utf8)
        let body = try declarationBody(ws, "private func openSmoothingPage")
        XCTAssertTrue(body.contains("relatticeArtifacts?.jobJSON"),
                      "the page's load case comes from the RETAINED job document")
        XCTAssertFalse(body.contains("project.loadCase()"),
                       "the page must not rebuild the load case from current state")
    }

    func testASelfWeightRunIsRefusedWithItsOwnReason() {
        let selfWeight = try! JSONSerialization.data(withJSONObject: [
            "model": "b.stl", "material": "PLA", "resolution": 64,
            "fixture_faces": [1], "margin_stop": 1.5,
        ] as [String: Any])
        let ctx = context(job: selfWeight)
        XCTAssertEqual(ctx.unavailable, .selfWeightRun)
        XCTAssertNil(ctx.loadCase)
        XCTAssertTrue(ctx.unavailable!.reason.contains("self-weight"))
    }

    func testARunThatKeptNoJobIsRefusedRatherThanFallingBack() {
        XCTAssertEqual(
            SmoothPageEntry.availability(hasGeometry: true, latticed: false,
                                         retainedJob: nil,
                                         modelPath: "/tmp/b.stl"),
            .noRetainedJob)
    }

    // MARK: - AE2 · both columns MEASURED, neither remembered

    /// A runner that records what it was asked for and answers with DISTINCT
    /// numbers per subject — so a "before" copied from the run's remembered
    /// margin (9.99 in this fixture) cannot pass.
    private final class RecordingRunner: @unchecked Sendable {
        var requests: [SmoothingPageModel.CertifyRequest] = []
        var beforeMargin = 2.7814
        var afterMargin = 1.2100
        var afterAccepted = false
        var nonConvergentOn: SmoothCertification.Subject?
        var throwOn: SmoothCertification.Subject?
        var beforeMinFeature = 961
        var afterMinFeature = 639

        func run(_ r: SmoothingPageModel.CertifyRequest) throws
            -> SmoothingPageModel.CertifyOutcome {
            requests.append(r)
            if throwOn == r.subject { throw TopOptError(message: "refused") }
            let nc = nonConvergentOn == r.subject
            let before = r.subject == .originalVariant
            let cert = SmoothCertification(
                subject: r.subject,
                TopOptKit.MeshCertification(
                    accepted: before ? true : afterAccepted, nonConvergent: nc,
                    marginWorstCase: before ? beforeMargin : afterMargin,
                    marginInPlane: (before ? beforeMargin : afterMargin) + 1,
                    marginInterlayer: before ? beforeMargin : afterMargin,
                    marginEffective: (before ? beforeMargin : afterMargin) * 0.207,
                    marginRequired: 1.5, maxStressMPa: before ? 14.459 : 33.2,
                    minFeatureViolations: before ? beforeMinFeature : afterMinFeature,
                    voxelMassGrams: before ? 41.2 : 39.8,
                    meshMassGrams: before ? 41.9 : 40.4, spacingMM: 1.25,
                    meshVolumeFraction: 0.31, voxelVolumeFraction: 0.33,
                    meshPath: before ? r.inputMeshPath : r.outputMeshPath))
            return SmoothingPageModel.CertifyOutcome(
                certification: cert,
                smoothing: before ? nil : SmoothingApplied(
                    maxStrength: r.strength, pairsRequested: 20, pairsApplied: 20,
                    totalVertices: 4344, frozenVertices: 228, brushedVertices: 3000,
                    unbrushedVertices: 1116, volumeDriftFraction: 0.004,
                    volumeDriftBound: 0.0056, minFeatureLimited: false,
                    regionLines: ["Region A 0.60 (2 tri)"]),
                meshVertices: before ? [] : [9, 9, 9, 8, 8, 8, 7, 7, 7, 6, 6, 6],
                meshIndices: before ? [] : self.smoothedIndices)
        }
        let smoothedIndices: [Int32] = [0, 1, 2, 1, 3, 2]
    }

    private func page(_ runner: RecordingRunner,
                      ctx: SmoothVariantContext? = nil) -> SmoothingPageModel {
        SmoothingPageModel(context: ctx ?? context(),
                           variantMeshPath: "/tmp/variant_1.stl",
                           smoothedMeshPath: "/tmp/variant_1_smoothed.stl",
                           runner: { try runner.run($0) })
    }

    private func brushed(strength: Double = 0.6) -> SmoothBrushModel {
        var b = brush(frozen: [false, false, false, false])
        b.addRegion(strength: strength)
        b.paint(.add, triangles: [0, 1])
        return b
    }

    func testBothColumnsComeFromTheCertificationEngine() async throws {
        let runner = RecordingRunner()
        // The run REMEMBERS 9.99 for this variant. If the before column were the
        // remembered number, it would read 9.99 rather than the measured 2.7814.
        let p = page(runner, ctx: context(reportedMargin: 9.99))
        await p.recertify(brush: brushed())

        XCTAssertEqual(runner.requests.count, 2,
                       "AE2: the engine ran TWICE — once per column")
        XCTAssertEqual(runner.requests.map(\.subject),
                       [.originalVariant, .smoothedVariant])
        XCTAssertEqual(p.certifyCallCount, 2)

        let r = try XCTUnwrap(p.receipt)
        XCTAssertEqual(r.before.marginWorstCase, 2.7814, accuracy: 1e-9)
        XCTAssertNotEqual(r.before.marginWorstCase, p.context.reportedMargin,
                          "AE2: the before column is MEASURED, not remembered")
        XCTAssertEqual(r.after.marginWorstCase, 1.21, accuracy: 1e-9)
        XCTAssertEqual(r.before.subject, .originalVariant)
        XCTAssertEqual(r.after.subject, .smoothedVariant)
        XCTAssertNotEqual(r.before.meshPath, r.after.meshPath,
                          "the two readings describe two different meshes")

        // The baseline request carries NO brush: it certifies the variant exactly
        // as the run made it, so the two readings differ by the brush and nothing else.
        XCTAssertTrue(runner.requests[0].weights.isEmpty)
        XCTAssertEqual(runner.requests[0].strength, 0)
        XCTAssertEqual(runner.requests[0].inputMeshPath,
                       runner.requests[1].inputMeshPath,
                       "both columns start from the same variant mesh")
        XCTAssertEqual(runner.requests[1].strength, 0.6, accuracy: 1e-12)
        XCTAssertFalse(runner.requests[1].weights.isEmpty)

        // And the load case that went to BOTH is the retained one.
        XCTAssertEqual(runner.requests[0].loadCase, runner.requests[1].loadCase)
        XCTAssertEqual(runner.requests[0].loadCase.anchorFaceIDs, [3])
    }

    func testTheReceiptShowsEveryRowTheTaskNames() async throws {
        let runner = RecordingRunner()
        let p = page(runner)
        await p.recertify(brush: brushed())
        let labels = try XCTUnwrap(p.receipt).rows.map(\.label)
        for expected in ["Worst-case margin", "In-plane", "Interlayer",
                         "Effective (at the gate)", "Min-feature violations",
                         "Mass (voxel)", "Mass (mesh)", "Verdict"] {
            XCTAssertTrue(labels.contains(expected), "missing receipt row: \(expected)")
        }
    }

    /// H2 — smoothing may IMPROVE printability. Nothing in the receipt presumes a
    /// cost: the same code path reports a fall as an improvement.
    func testMinFeatureIsReportedBothWays() async throws {
        let falling = RecordingRunner()
        falling.beforeMinFeature = 961
        falling.afterMinFeature = 639          // PR 200's own measurement
        let a = page(falling)
        await a.recertify(brush: brushed())
        let ra = try XCTUnwrap(a.receipt)
        let rowA = try XCTUnwrap(ra.rows.first { $0.label == "Min-feature violations" })
        XCTAssertEqual(rowA.better, true, "H2: fewer violations reads as BETTER")
        XCTAssertEqual(rowA.worse, false)
        XCTAssertTrue(ra.minFeatureLine.contains("FELL"))

        let rising = RecordingRunner()
        rising.beforeMinFeature = 4
        rising.afterMinFeature = 12
        let b = page(rising)
        await b.recertify(brush: brushed())
        let rb = try XCTUnwrap(b.receipt)
        let rowB = try XCTUnwrap(rb.rows.first { $0.label == "Min-feature violations" })
        XCTAssertEqual(rowB.worse, true)
        XCTAssertTrue(rb.minFeatureLine.contains("ROSE"))
    }

    /// H3 — the certified object is the RE-VOXELIZATION, and the receipt says so
    /// with a number rather than leaving it to be assumed.
    func testTheReceiptStatesTheAnalyzedVsPrintedGap() async throws {
        let p = page(RecordingRunner())
        await p.recertify(brush: brushed())
        let r = try XCTUnwrap(p.receipt)
        XCTAssertTrue(r.quantizationLine.contains("RE-VOXELIZATION"))
        XCTAssertEqual(r.after.meshVolumeFraction, 0.31, accuracy: 1e-9)
        XCTAssertEqual(r.after.voxelVolumeFraction, 0.33, accuracy: 1e-9)
        XCTAssertNotEqual(r.after.meshVolumeFraction, r.after.voxelVolumeFraction,
                          "the gap is a measured number, not an assumption")
        XCTAssertGreaterThan(abs(r.after.quantizationGapPercent), 0)
    }

    func testAVerdictDropIsNamedAsSuch() async throws {
        let runner = RecordingRunner()
        runner.afterAccepted = false
        runner.afterMargin = 1.21
        let p = page(runner)
        await p.recertify(brush: brushed())
        let r = try XCTUnwrap(p.receipt)
        XCTAssertEqual(r.verdictChange, .dropped)
        XCTAssertTrue(r.headline.contains("dropped"))

        let held = RecordingRunner()
        held.afterAccepted = true
        held.afterMargin = 2.60
        let q = page(held)
        await q.recertify(brush: brushed())
        XCTAssertEqual(try XCTUnwrap(q.receipt).verdictChange, .heldAccepted)
    }

    // MARK: - AE5 · H1 is a STATE, and the old numbers are marked STALE

    func testNonConvergenceIsLegibleAndTheOldReceiptIsMarkedStale() async throws {
        let runner = RecordingRunner()
        let p = page(runner)

        // A good certification first — this is what must survive, MARKED.
        await p.recertify(brush: brushed(strength: 0.25))
        let good = try XCTUnwrap(p.receipt)
        XCTAssertFalse(good.stale)

        // Now the known H1 case: PR 200 measured variant_030 @ 0.50 failing the
        // production multigrid-CG, deterministically.
        runner.nonConvergentOn = .smoothedVariant
        await p.recertify(brush: brushed(strength: 0.50))

        XCTAssertNil(p.receipt,
                     "AE5: there is NO current receipt — a stale number must not "
                     + "be served as the current verdict")
        let f = try XCTUnwrap(p.failure)
        XCTAssertEqual(f.kind, .didNotConverge)
        XCTAssertEqual(f.maxStrength, 0.50, accuracy: 1e-12)
        XCTAssertTrue(f.detail.contains("did not reach tolerance"))
        XCTAssertTrue(f.detail.contains("not a verdict"))
        XCTAssertTrue(f.suggestion.contains("Lower the strength"))

        let stale = try XCTUnwrap(p.staleReceipt)
        XCTAssertTrue(stale.stale, "AE5: the previous certification is MARKED stale")
        XCTAssertEqual(stale.after.marginWorstCase, good.after.marginWorstCase,
                       "the stale numbers ARE the previous ones, unaltered")
        XCTAssertTrue(p.statusLine.contains("out of date"))
    }

    /// A baseline that will not certify is a DIFFERENT failure from a smoothing
    /// that will not certify — smoothing is not the cause and a lower strength
    /// cannot help, so the page must not suggest one.
    func testAnUncertifiableBaselineIsNamedAsItsOwnFailure() async throws {
        let runner = RecordingRunner()
        runner.nonConvergentOn = .originalVariant
        let p = page(runner)
        await p.recertify(brush: brushed())
        XCTAssertNil(p.receipt)
        let f = try XCTUnwrap(p.failure)
        XCTAssertEqual(f.kind, .baselineDidNotConverge)
        XCTAssertTrue(f.title.contains("this variant at all"))
        XCTAssertTrue(f.detail.contains("Smoothing is not the cause"))
        XCTAssertFalse(f.suggestion.contains("Lower the strength"),
                       "a lower strength cannot fix a baseline that will not certify")
        XCTAssertEqual(runner.requests.count, 1,
                       "the smoothed pass is not attempted with no baseline to "
                       + "compare it against")
    }

    func testAHardFailureIsAlsoAStateAndNeverACrash() async throws {
        let runner = RecordingRunner()
        runner.throwOn = .smoothedVariant
        let p = page(runner)
        await p.recertify(brush: brushed())
        XCTAssertNil(p.receipt)
        let f = try XCTUnwrap(p.failure)
        XCTAssertEqual(f.kind, .refused("refused"))
        XCTAssertNil(p.staleReceipt?.stale == true ? nil : p.staleReceipt,
                     "with no prior good receipt there is nothing to mark")
    }

    func testANonConvergentSmoothingIsNeverKeepable() async throws {
        let runner = RecordingRunner()
        runner.nonConvergentOn = .smoothedVariant
        let p = page(runner)
        await p.recertify(brush: brushed())
        XCTAssertFalse(p.keep(regionLines: []),
                       "a smoothing with no trustworthy verdict cannot be kept")
        XCTAssertNil(p.kept)
    }

    // MARK: - AE9 · discarding returns the ORIGINAL, bit-identically

    func testDiscardReturnsTheOriginalVariantBitIdentically() async throws {
        let p = page(RecordingRunner())
        let originalV = Data(bytes: vertices, count: vertices.count * 4)
        let originalI = Data(bytes: indices, count: indices.count * 4)

        await p.recertify(brush: brushed())
        XCTAssertTrue(p.keep(regionLines: ["Region A 0.60 (2 tri)"]))
        XCTAssertNotNil(p.kept)
        let smoothed = p.currentGeometry
        XCTAssertTrue(smoothed.smoothed)
        XCTAssertNotEqual(Data(bytes: smoothed.vertices,
                               count: smoothed.vertices.count * 4), originalV,
                          "the fixture must actually change the geometry")

        p.discard()
        XCTAssertNil(p.kept)
        let back = p.currentGeometry
        XCTAssertFalse(back.smoothed)
        XCTAssertEqual(Data(bytes: back.vertices, count: back.vertices.count * 4),
                       originalV, "AE9: the original vertices come back BIT-IDENTICALLY")
        XCTAssertEqual(Data(bytes: back.indices, count: back.indices.count * 4),
                       originalI, "AE9: the original indices come back BIT-IDENTICALLY")

        // And the context — the immutable original — was never touched.
        XCTAssertEqual(Data(bytes: p.context.meshVertices,
                            count: p.context.meshVertices.count * 4), originalV)
    }

    func testNothingSmoothedMeansTheStageShowsTheOriginal() {
        let p = page(RecordingRunner())
        let g = p.currentGeometry
        XCTAssertFalse(g.smoothed)
        XCTAssertEqual(g.vertices, vertices)
    }

    // MARK: - AE8 · smooth-then-lattice, and NOT the reverse

    func testASmoothedVariantGoesToTheLatticePageOnItsSmoothedGeometry() async throws {
        let p = page(RecordingRunner())
        await p.recertify(brush: brushed())
        XCTAssertTrue(p.keep(regionLines: []))
        let kept = try XCTUnwrap(p.kept)

        let handoff = SmoothPageEntry.latticeGeometry(
            original: (vertices, indices), kept: kept)
        XCTAssertTrue(handoff.smoothed)
        XCTAssertEqual(handoff.vertices, kept.meshVertices,
                       "AE8: the lattice is generated on the SMOOTHED geometry")
        XCTAssertNotEqual(handoff.vertices, vertices)

        // The variant carries that geometry onward with nothing else disturbed.
        let v = OptimizeVariant(
            requestedVolumeFraction: 0.6, achievedVolumeFraction: 0.58,
            massGrams: 41.2, supportVolumeVoxels: 12, meshTriangleCount: 2,
            worstCaseMargin: 2.78, accepted: true, v3Passes: true,
            meshVertices: vertices, meshIndices: indices,
            vonMisesField: [1, 2, 3, 4])
        let moved = v.withGeometry(vertices: kept.meshVertices,
                                   indices: kept.meshIndices)
        XCTAssertEqual(moved.meshVertices, kept.meshVertices)
        XCTAssertEqual(moved.requestedVolumeFraction, 0.6)
        XCTAssertEqual(moved.vonMisesField, [1, 2, 3, 4],
                       "the variant's own field travels unchanged")
        XCTAssertEqual(moved.worstCaseMargin, 2.78,
                       "the RUN's margin is not silently restated as the smoothed one")

        // Without a kept smoothing the handoff is the ORIGINAL, honestly labelled.
        let none = SmoothPageEntry.latticeGeometry(original: (vertices, indices),
                                                   kept: nil)
        XCTAssertFalse(none.smoothed)
        XCTAssertEqual(none.vertices, vertices)
    }

    func testALatticedRunIsNotOfferedSmoothing() {
        let ctx = context(latticed: true)
        XCTAssertEqual(ctx.unavailable, .alreadyLatticed)
        XCTAssertNil(ctx.loadCase)
        XCTAssertTrue(ctx.unavailable!.reason.contains("round the struts"))

        let actions = SmoothPageActions.compute(
            brush: brushed(), working: false, hasReceipt: false, hasKept: false,
            unavailable: ctx.unavailable)
        XCTAssertFalse(actions.recertify.enabled,
                       "AE8 reverse: smoothing a latticed export is NOT offered")
        XCTAssertTrue(actions.recertify.sub.contains("round the struts"))
    }

    func testSendToLatticeIsGatedOnAKeptSmoothing() async throws {
        let p = page(RecordingRunner())
        var a = SmoothPageActions.compute(brush: brushed(), working: false,
                                          hasReceipt: false, hasKept: false,
                                          unavailable: nil)
        XCTAssertFalse(a.sendToLattice.enabled)

        await p.recertify(brush: brushed())
        a = SmoothPageActions.compute(brush: brushed(), working: false,
                                      hasReceipt: p.receipt != nil, hasKept: false,
                                      unavailable: nil)
        XCTAssertFalse(a.sendToLattice.enabled,
                       "a certification alone is not enough — the user must KEEP it")
        XCTAssertTrue(p.keep(regionLines: []))
        a = SmoothPageActions.compute(brush: brushed(), working: false,
                                      hasReceipt: true, hasKept: true,
                                      unavailable: nil)
        XCTAssertTrue(a.sendToLattice.enabled)
        XCTAssertTrue(a.sendToLattice.sub.contains("SMOOTHED"))
    }

    // MARK: - AE6 · ONE selection model (PR 274's M1 shape)

    func testTheSmoothingPageHasNoSecondSelectionSystem() throws {
        let src = try String(contentsOf: sourceURL("SmoothingPage.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("SelectionModel("),
                       "SmoothingPage must not build a second selection model")
        XCTAssertFalse(src.contains("var selectionsPanel"),
                       "SmoothingPage must not define its own selections panel")
        let ws = try String(contentsOf: sourceURL("WorkspacePlaceholder.swift"),
                            encoding: .utf8)
        XCTAssertEqual(ws.components(separatedBy: "var selectionsPanel").count - 1, 1,
                       "still exactly ONE selections panel definition in the app")

        // ROUND 2 (bar L1) REVERSED THE AFFORDANCE, NOT THE PRINCIPLE.
        //
        // This used to assert `smoothingPageModel?.libraryOpen == true` — that the
        // page MOUNTED the shared panel. AE6's claim was "one selection model,
        // never a second UX", and mounting the editor satisfied that reading. But
        // the brush's freeze mask is computed FROM those selections, so editing an
        // anchor or a keep-clear volume mid-stroke leaves every stroke on screen
        // measured against a mask that no longer describes the part.
        //
        // So the page now shows a READ-ONLY readout of the same one model. AE6 is
        // strictly more asserted than before: the page mounts no panel at all, and
        // the three structural checks above and below are unchanged.
        XCTAssertFalse(ws.contains("smoothingPageModel?.libraryOpen"),
                       "the smoothing page must not mount the selections EDITOR — "
                       + "protected regions are indicated, not editable (L1)")
        XCTAssertFalse(try codeOnly(sourceURL("SmoothingPage.swift"))
                        .contains("onOpenLibrary"),
                       "and it has no route to open one")

        // Structural half: the page model holds no group or face collection — the
        // brush's own state is triangles and strengths, which is not a selection.
        let model = page(RecordingRunner())
        for child in Mirror(reflecting: model).children {
            let t = String(describing: type(of: child.value))
            XCTAssertFalse(t.contains("SelectionGroup"),
                           "SmoothingPageModel must not hold a group list (\(child.label ?? "?"))")
            XCTAssertFalse(t.contains("SelectionModel"),
                           "SmoothingPageModel must not hold a second SelectionModel")
        }
    }

    // MARK: - AE7 · layout parity across all three pages

    func testChromeGeometryIsOneSharedConstantSet() {
        // Every named lattice-page seam resolves to the shared token…
        XCTAssertEqual(LatticeChromeLayout.gap, PageChrome.gap)
        XCTAssertEqual(LatticeChromeLayout.edge, PageChrome.edge)
        XCTAssertEqual(LatticeChromeLayout.clusterHeight, PageChrome.actionButton)
        XCTAssertEqual(LatticeChromeLayout.panelBottomClearance,
                       PageChrome.panelBottomClearance)
        for g in LatticeChromeLayout.allGaps {
            XCTAssertEqual(g, PageChrome.gap)
        }
        // …and the gizmo's size constant IS the view's own, so the shared
        // placement can never drift from the thing being placed.
        XCTAssertEqual(PageChrome.gizmoSize, OrientationGizmoView.standardSize)
        XCTAssertEqual(PageChrome.gizmoClearance,
                       PageChrome.gizmoSize + PageChrome.gizmoInset * 2)
    }

    func testAllThreePagesReadTheSharedChromeTokens() throws {
        let smoothing = try String(contentsOf: sourceURL("SmoothingPage.swift"),
                                   encoding: .utf8)
        for token in ["PageChrome.gap", "PageChrome.edge", "PageChrome.topInset",
                      "PageChrome.circleButton", "PageChrome.barHeight",
                      "PageChrome.actionButton", "PageChrome.panelWidth",
                      "PageChrome.gizmoClearance"] {
            XCTAssertTrue(smoothing.contains(token),
                          "SmoothingPage must size its chrome from \(token)")
        }
        // No page may hardcode the numbers the tokens name.
        XCTAssertFalse(smoothing.contains("frame(height: 64)"),
                       "the action-button height comes from PageChrome, not a literal")
        XCTAssertFalse(smoothing.contains("width: 52, height: 52"),
                       "the circle-button size comes from PageChrome, not a literal")
        XCTAssertFalse(smoothing.contains("frame(width: 348)"),
                       "the panel width comes from PageChrome, not a literal")

        // The lattice page still routes through its named seams, which now resolve
        // to the shared tokens (its own M4 test still pins the naming).
        let lattice = try String(contentsOf: sourceURL("LatticePageModel.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(lattice.contains("PageChrome.gap"),
                      "LatticeChromeLayout derives from the shared token set")

        // ── L2: THE GIZMO IS TOP RIGHT ON EVERY PAGE ────────────────────────
        //
        // Round 1's version of this asserted the literal
        // `showSmoothingPage, viewerMesh != nil { orientationGizmo }`, which was
        // satisfied while the gizmo was HIDDEN on the lattice page — so it pinned
        // two pages out of three and called that invariance. This asserts the
        // structure instead: one definition, one placement, and that placement
        // conditioned on NOTHING but having a mesh to orient.
        let ws = try String(contentsOf: sourceURL("WorkspacePlaceholder.swift"),
                            encoding: .utf8)
        let wsCode = try codeOnly(sourceURL("WorkspacePlaceholder.swift"))
        XCTAssertEqual(ws.components(separatedBy: "private var orientationGizmo").count - 1, 1,
                       "exactly ONE gizmo view definition exists for every page to use")
        let placements = wsCode.components(separatedBy: "{ orientationGizmo }").count - 1
        XCTAssertEqual(placements, 1,
                       "exactly ONE gizmo PLACEMENT — a second site is how a page "
                       + "gets its own corner")
        XCTAssertTrue(wsCode.contains("if viewerMesh != nil { orientationGizmo }"),
                      "the gizmo is placed on having a MESH and nothing else — not "
                      + "gated on which page is up")
        for pageFlag in ["showLatticePage", "showSmoothingPage"] {
            XCTAssertFalse(
                wsCode.contains("\(pageFlag), viewerMesh != nil { orientationGizmo }"),
                "the gizmo placement must not mention \(pageFlag) — L2 is that its "
                + "position is IDENTICAL across the TO, lattice and smoothing pages")
        }

        // And both pages keep their own top-right chrome clear of it, so "same
        // corner" does not mean "on top of the page's own controls" (bar L5).
        XCTAssertTrue(smoothing.contains("PageChrome.gizmoClearance"),
                      "the smoothing page insets its top-right column past the gizmo")
        let latticePage = try String(contentsOf: sourceURL("LatticePage.swift"),
                                     encoding: .utf8)
        XCTAssertTrue(latticePage.contains("PageChrome.gizmoClearance"),
                      "the lattice page insets its top-right column past the gizmo")
    }

    // MARK: - the action row reports WHY, never a mute disabled button

    func testEveryDisabledActionStatesItsReason() {
        let empty = SmoothBrushModel(indices: indices, vertexCount: 4,
                                     freeze: mask(frozen: [false, false, false, false]))
        let a = SmoothPageActions.compute(brush: empty, working: false,
                                          hasReceipt: false, hasKept: false,
                                          unavailable: nil)
        XCTAssertFalse(a.recertify.enabled)
        XCTAssertTrue(a.recertify.sub.contains("brush an area"))
        for action in [a.recertify, a.keep, a.discard, a.sendToLattice] {
            XCTAssertFalse(action.sub.isEmpty, "\(action.label) gives no reason")
        }

        let working = SmoothPageActions.compute(brush: brushed(), working: true,
                                                hasReceipt: true, hasKept: true,
                                                unavailable: nil)
        XCTAssertFalse(working.recertify.enabled)
        XCTAssertTrue(working.recertify.sub.contains("running"))
    }

    // MARK: - helpers

    /// A source file with its `//` comment text removed, so a structural assertion
    /// reads what the compiler reads rather than what the prose says.
    private func codeOnly(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<r.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// The WHOLE body of a `private func name(`/`private var name` declaration —
    /// from its own line to the next top-level `    private ` at the same
    /// indentation.
    ///
    /// Round 2 replaced a `.prefix(2600)` window with this. A byte window silently
    /// STOPS ASSERTING when the function grows past it, which is exactly what
    /// happened to `openSmoothingPage`: adding the page-mesh import pushed the
    /// retained-job line out of the window, and the test failed for the right
    /// reason but the wrong cause. Reading the real body means the assertion
    /// covers the function however long it gets.
    func declarationBody(_ source: String, _ declaration: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: declaration),
                                  "no declaration '\(declaration)' in the source")
        let rest = source[start.upperBound...]
        // The next sibling declaration at the same (4-space) indentation.
        var end = rest.endIndex
        for marker in ["\n    private ", "\n    public ", "\n    @ViewBuilder ",
                       "\n    func ", "\n    var "] {
            if let r = rest.range(of: marker), r.lowerBound < end { end = r.lowerBound }
        }
        return String(source[start.lowerBound...]
            .prefix(source.distance(from: start.lowerBound, to: start.upperBound)
                    + rest.distance(from: rest.startIndex, to: end)))
    }

    private func sourceURL(_ name: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()   // TopOptFlowsTests
        url.deleteLastPathComponent()   // Tests
        url.deleteLastPathComponent()   // TopOptKit
        return url.appendingPathComponent("Sources/TopOptFlows/\(name)")
    }
}
