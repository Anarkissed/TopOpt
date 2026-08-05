// SmoothingPageRound2Tests — handoff 2026-08-03-smoothing-page-round2.
//
// Round 1 shipped a page that REFUSED TO PAINT on the maintainer's device and
// drew itself over a live TO workspace. These are the bars for both:
//
//   S1/S2  the page has ONE mesh, and it is core's own import of the page's one
//          input file — not the run's streamed buffer.
//   S3     the guard that caught the mismatch STAYS, and is now sharper: it
//          refuses on a different COUNT and on a different FILE.
//   S4     PR 279's AE1 at its original strength, on the mesh actually painted.
//   L1/L6  layout parity asserted by what is HIDDEN, not only by what is placed.
//   L2     the position gizmo is one placement, on every page.
//   L4     every brush tool is on the page, not borrowed from the TO chrome.
//   L5     no two panels occupy the same region, in either orientation.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class SmoothingPageRound2Tests: XCTestCase {

    // MARK: - fixtures

    /// A four-vertex, two-triangle mesh — the same shape the round-1 suite uses.
    private let verts: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0]
    private let tris: [Int32] = [0, 1, 2, 1, 3, 2]

    private func pageMesh(path: String = "/tmp/variant_1.stl") -> SmoothPageMesh {
        SmoothPageMesh(path: path, vertices: verts, indices: tris)
    }

    private func mask(_ frozen: [Bool], path: String = "/tmp/variant_1.stl")
        -> SmoothFreezeMask {
        SmoothFreezeMask(frozen: frozen, toleranceMM: 1.2, meshPath: path)
    }

    private func sourceURL(_ name: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()   // TopOptFlowsTests
        url.deleteLastPathComponent()   // Tests
        url.deleteLastPathComponent()   // TopOptKit
        return url.appendingPathComponent("Sources/TopOptFlows/\(name)")
    }

    /// Source with `//` comments stripped, so an assertion is about what the code
    /// can REACH, not about what the prose mentions.
    private func codeOnly(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<r.lowerBound])
            }
            .joined(separator: "\n")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // S2 — ONE MESH, BY CONSTRUCTION
    // ═══════════════════════════════════════════════════════════════════════

    /// The page mesh is built by IMPORTING A PATH. There is no production route
    /// from an in-memory buffer, which is what stops a second mesh existing.
    func testThePageMeshIsBuiltByImportingItsOwnFile() throws {
        var asked: [String] = []
        let m = try SmoothPageMesh.imported(from: "/tmp/variant_7.stl") { path in
            asked.append(path)
            return (self.verts, self.tris)
        }
        XCTAssertEqual(asked, ["/tmp/variant_7.stl"],
                       "the importer is asked for exactly the page's own file")
        XCTAssertEqual(m.path, "/tmp/variant_7.stl")
        XCTAssertEqual(m.vertexCount, 4)
        XCTAssertEqual(m.triangleCount, 2)
    }

    /// BAR S2's "by construction": the freeze-mask request's `meshPath` comes from
    /// the page mesh, and the caller has no parameter through which to name a
    /// different file. Asserted twice — behaviourally, and by reading the source
    /// for the private initialiser that makes it structural rather than habitual.
    func testTheFreezeMaskRequestCanOnlyNameThePageMeshOwnFile() throws {
        let m = pageMesh(path: "/tmp/variant_3.stl")
        let lc = SmoothRecertLoadCase(
            material: "PLA", resolution: 64, anchorFaceIDs: [3],
            loadGroups: [.init(faceIDs: [7], force: SIMD3(0, -500, 0))],
            buildDirection: SIMD3(0, 0, 1), infillPercent: 35,
            freeze: [], protectedFaceIDs: [])
        let req = m.freezeMaskRequest(modelPath: "/tmp/bracket.stl", loadCase: lc)
        XCTAssertEqual(req.meshPath, m.path,
                       "the request masks the PAGE MESH, whatever the caller wanted")
        XCTAssertEqual(req.modelPath, "/tmp/bracket.stl")
        XCTAssertEqual(req.loadCase.resolution, 64)

        let src = try codeOnly(sourceURL("SmoothPageMesh.swift"))
        XCTAssertTrue(src.contains("fileprivate init(meshPath:"),
                      "SmoothFreezeMaskRequest's initialiser must be private to "
                      + "SmoothPageMesh.swift — a public one would let any caller "
                      + "name a different mesh, which is the defect this fixes")
        XCTAssertTrue(src.contains("SmoothFreezeMaskRequest(meshPath: path,"),
                      "the only construction fills meshPath in from self.path")
    }

    /// The brush is built BY the page mesh, so its indices, its vertex count and
    /// its stated file all come from one place.
    func testTheBrushIsBuiltByThePageMeshAndCarriesItsPath() {
        let m = pageMesh()
        let b = m.brush(freeze: mask([false, false, false, false]))
        XCTAssertEqual(b.indices, tris)
        XCTAssertEqual(b.vertexCount, 4)
        XCTAssertEqual(b.meshPath, m.path)
        XCTAssertTrue(b.canPaint, "the normal path paints")
    }

    /// S2 AT THE CALL SITE. `openSmoothingPage` must stop using the run's own
    /// buffer once the file is written: the stage, the brush and the context all
    /// take the imported mesh. This reads the whole function, not a byte window.
    func testTheSmoothingPageNeverUsesTheRunsOwnBufferAfterTheExport() throws {
        let ws = try codeOnly(sourceURL("WorkspacePlaceholder.swift"))
        let opener = try XCTUnwrap(ws.range(of: "private func openSmoothingPage"))
        let rest = ws[opener.upperBound...]
        let end = rest.range(of: "\n    private func closeSmoothingPage")?.lowerBound
            ?? rest.endIndex
        let body = String(rest[rest.startIndex..<end])

        // It imports the file it just wrote.
        XCTAssertTrue(body.contains("SmoothPageMesh.imported(from: inPath)"),
                      "the page mesh is core's own import of the page's input file")
        XCTAssertTrue(body.contains("TopOptKit.importMesh(path: path)"),
                      "and that import goes through core, not an app-side reader")

        // The exception is the export itself — writing the file is the ONE place
        // the run's buffer is legitimately read. Everything after it must not.
        let exportEnd = try XCTUnwrap(body.range(of: "to: inPath)")).upperBound
        let after = String(body[exportEnd...])
        for banned in ["v.meshVertices", "v.meshIndices"] {
            XCTAssertFalse(after.contains(banned),
                           "after the export, nothing may read \(banned) — that "
                           + "buffer is the SECOND mesh, and on a LAN run it is a "
                           + "triangle soup with 6x core's vertex count")
        }
        XCTAssertTrue(after.contains("pageMesh.brush()"),
                      "the brush is built by the page mesh")
        XCTAssertTrue(after.contains("vertices: pageMesh.vertices"),
                      "the STAGE draws the page mesh, so what is on screen is what "
                      + "the brush indexes and what core masks")
        XCTAssertTrue(after.contains("ctx.freezeMaskRequest"),
                      "the mask request comes from the context's page mesh")

        // And NO remap: bar S2 forbids reconciling two meshes.
        for banned in ["remap", "nearestVertex", "matchVertices", "resample"] {
            XCTAssertFalse(after.lowercased().contains(banned.lowercased()),
                           "a '\(banned)' step would be the guess the guard exists "
                           + "to refuse — the fix is one mesh, not two reconciled")
        }
    }

    /// A mesh core cannot read is its own NAMED refusal, checked before every
    /// other verdict — those would all be about a mesh that was never read.
    func testAnUnreadableVariantMeshIsItsOwnNamedRefusal() {
        let ctx = SmoothPageEntry.context(
            runName: "Bracket", variantIndex: 0, requestedVolumeFraction: 0.6,
            massGrams: 40, reportedMargin: 2.0, accepted: true,
            pageMesh: SmoothPageMesh(path: "/tmp/x.stl", vertices: [], indices: []),
            latticed: false, retainedJob: nil, modelPath: "/tmp/b.stl",
            meshUnreadable: "cannot import '/tmp/x.stl': non-manifold edges")
        XCTAssertEqual(ctx.unavailable,
                       .meshUnreadable("cannot import '/tmp/x.stl': non-manifold edges"))
        XCTAssertNil(ctx.loadCase, "no load case is resolved for a mesh we never read")
        XCTAssertFalse(ctx.canSmooth)
        let reason = try! XCTUnwrap(ctx.unavailable).reason
        XCTAssertTrue(reason.contains("non-manifold edges"),
                      "core's own words reach the user: \(reason)")

        // It OUTRANKS the other reasons rather than being masked by them: this
        // context would otherwise have been refused as `.noRetainedJob`.
        XCTAssertNotEqual(ctx.unavailable, .noRetainedJob)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // S3 — THE GUARD STAYS
    // ═══════════════════════════════════════════════════════════════════════

    /// THE DEVICE'S OWN FAILURE, reproduced at its measured ratio. A LAN variant's
    /// buffer is a triangle soup (3 x triangles); core's is the welded mesh. Feed
    /// the brush one and the mask the other and it must still refuse.
    func testMismatchedMeshesStillRefuseToPaint() {
        // 240 soup vertices = 80 triangles; core welds those to ~40.
        let soupTris: [Int32] = (0..<240).map { Int32($0) }
        var b = SmoothBrushModel(indices: soupTris, vertexCount: 240,
                                 freeze: mask([Bool](repeating: false, count: 40)),
                                 meshPath: "/tmp/v.stl")
        XCTAssertFalse(b.canPaint, "a 240-vertex brush must not use a 40-vertex mask")
        let why = try! XCTUnwrap(b.unusableReason)
        XCTAssertTrue(why.contains("40 vertices vs 240"),
                      "the refusal names BOTH counts: \(why)")
        XCTAssertTrue(why.contains("refusing to paint rather than guess"),
                      "and says it is refusing rather than guessing: \(why)")

        // Refusing is not cosmetic: nothing paints, and no weight is produced.
        b.addRegion(strength: 1.0)
        let edit = b.paint(.add, triangles: [0, 1, 2])
        XCTAssertTrue(edit.isEmpty, "no stroke takes while the meshes disagree")
        XCTAssertEqual(b.vertexWeights(), [Double](repeating: 0, count: 240),
                       "and the weight vector is all zero, so a stray call to the "
                       + "smoother would be a no-op rather than a wrong answer")
        XCTAssertTrue(b.vertexTints().allSatisfy { $0 == .zero },
                      "and nothing is tinted, so the stage does not imply a mask")
    }

    /// THE SHARPER HALF (round 2): matching counts are NOT the same vertices. The
    /// probe measured the on-device path agreeing with core on count AND order,
    /// so a count-only guard would pass a same-size mesh from a different variant
    /// and paint the wrong vertices in silence — worse than refusing.
    func testMatchingCountsFromADifferentFileStillRefuse() {
        let b = SmoothBrushModel(indices: tris, vertexCount: 4,
                                 freeze: mask([false, true, false, true],
                                              path: "/tmp/variant_2.stl"),
                                 meshPath: "/tmp/variant_1.stl")
        XCTAssertEqual(b.freeze.vertexCount, b.vertexCount,
                       "precondition: the counts DO match, so only the path can catch it")
        XCTAssertFalse(b.canPaint)
        let why = try! XCTUnwrap(b.unusableReason)
        XCTAssertTrue(why.contains("variant_2.stl") && why.contains("variant_1.stl"),
                      "the refusal names both files: \(why)")
        XCTAssertTrue(why.contains("matching counts are not the same vertices"),
                      "and says why a count was not enough: \(why)")
    }

    /// THE NORMAL PATH NO LONGER TRIPS IT. Both sides built from one page mesh.
    func testTheNormalPathNoLongerTripsTheGuard() {
        let m = pageMesh()
        let lc = SmoothRecertLoadCase(
            material: "PLA", resolution: 64, anchorFaceIDs: [3],
            loadGroups: [.init(faceIDs: [7], force: SIMD3(0, -500, 0))],
            buildDirection: SIMD3(0, 0, 1), infillPercent: 35,
            freeze: [], protectedFaceIDs: [])
        let req = m.freezeMaskRequest(modelPath: "/tmp/b.stl", loadCase: lc)
        // Core answers for the file the request named — one entry per vertex.
        let b = m.brush(freeze: SmoothFreezeMask(
            frozen: [false, true, false, false], toleranceMM: 1.2,
            meshPath: req.meshPath))
        XCTAssertNil(b.unusableReason, "the shipped path must be usable")
        XCTAssertTrue(b.canPaint)
        XCTAssertTrue(b.paintable(triangle: 0))
    }

    /// THE GUARD HAS THREE LAYERS, and the last is in C++ where the weights are
    /// actually consumed. Round 2 did not add it — PR 279 did — but the app-side
    /// fix must not become a reason to let it rot, because it is the only one
    /// that sees the vector core will really apply.
    func testTheBridgeAlsoRefusesAWeightVectorOfTheWrongLength() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let bridge = try String(
            contentsOf: url.appendingPathComponent("Sources/TopOptBridge/bridge.cpp"),
            encoding: .utf8)
        XCTAssertTrue(
            bridge.contains("brush.weight.size() != input.vertices.size()"),
            "the bridge compares the weight vector against the mesh it imported")
        XCTAssertTrue(
            bridge.contains("refusing rather than weighting the wrong vertices"),
            "and refuses by name rather than truncating or padding")
    }

    /// An unavailable mask is still the "not yet" state, not a mismatch — the two
    /// read differently because the advice differs.
    func testAnUnresolvedMaskIsStillItsOwnState() {
        let b = pageMesh().brush()
        XCTAssertFalse(b.canPaint)
        let why = try! XCTUnwrap(b.unusableReason)
        XCTAssertTrue(why.contains("Working out which surfaces are protected"),
                      "not-yet is not the same message as mismatch: \(why)")
    }

    /// An empty path on either side means "not stated" and must not fail the
    /// check — otherwise every headless test and every pre-round-2 caller would
    /// be refused for having said nothing.
    func testAnUnstatedPathDoesNotFailTheCheck() {
        let noPathOnBrush = SmoothBrushModel(
            indices: tris, vertexCount: 4,
            freeze: mask([false, false, false, false], path: "/tmp/a.stl"))
        XCTAssertTrue(noPathOnBrush.canPaint)
        let noPathOnMask = SmoothBrushModel(
            indices: tris, vertexCount: 4,
            freeze: SmoothFreezeMask(frozen: [false, false, false, false],
                                     toleranceMM: 1),
            meshPath: "/tmp/a.stl")
        XCTAssertTrue(noPathOnMask.canPaint)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // S4 — PR 279's AE1 AT ITS ORIGINAL STRENGTH, ON THE MESH ACTUALLY PAINTED
    // ═══════════════════════════════════════════════════════════════════════

    /// A frozen vertex gets weight EXACTLY +0.0 at every brush strength, on a
    /// page mesh built the production way, with every triangle painted.
    ///
    /// The comparison is on the BIT PATTERN, not `== 0`: core takes the same
    /// verbatim-copy branch for a zero-weight vertex as for a frozen one, and on
    /// a −0.0 coordinate `−0.0 + 0.0 = +0.0` flips a sign bit — which memcmp
    /// catches and `==` does not. PR 279 found that; this keeps it found.
    func testFrozenVerticesTakeExactlyZeroWeightAtEveryStrength() throws {
        let m = try SmoothPageMesh.imported(from: "/tmp/variant_1.stl") { _ in
            (self.verts, self.tris)
        }
        let frozen = [false, true, true, false]
        for strength in [0.10, 0.25, 0.50, 0.75, 1.00] {
            var b = m.brush(freeze: mask(frozen))
            b.addRegion(strength: strength)
            // Paint EVERY triangle, frozen corners included — layer 2 must hold
            // whatever the assignments say.
            b.paint(.add, triangles: [0, 1])
            let w = b.vertexWeights()
            XCTAssertEqual(w.count, m.vertexCount)
            for v in 0..<frozen.count where frozen[v] {
                XCTAssertEqual(w[v].bitPattern, (0.0 as Double).bitPattern,
                               "vertex \(v) is frozen; at strength \(strength) its "
                               + "weight must be +0.0 to the bit")
            }
            // And the unfrozen ones did get the strength, so this is not passing
            // by painting nothing.
            XCTAssertEqual(w[0], strength, accuracy: 1e-12)
        }
    }

    /// Layer 1 on the page mesh: a triangle whose every corner is frozen is
    /// REFUSED, so the surface reads as untouchable rather than silently ignored.
    func testATriangleWithNoMovableCornerIsRefusedOnThePageMesh() {
        // Triangle 1 = (1, 3, 2). Freeze 1, 2, 3.
        var b = pageMesh().brush(freeze: mask([false, true, true, true]))
        XCTAssertTrue(b.paintable(triangle: 0))
        XCTAssertFalse(b.paintable(triangle: 1))
        b.addRegion(strength: 1.0)
        let edit = b.paint(.add, triangles: [0, 1])
        XCTAssertEqual(edit.changes.map(\.triangle), [0],
                       "only the triangle with a movable corner takes the stroke")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // L1 / L6 — LAYOUT PARITY, ASSERTED BY WHAT IS HIDDEN
    // ═══════════════════════════════════════════════════════════════════════

    /// Every workspace chrome element the maintainer named as "still visible and
    /// interactive underneath" must be inside a `!fullScreenPageUp` scope.
    ///
    /// ROUND 1's AE7 PASSED WHILE THE PAGE WAS AN OVERLAY, because it only
    /// asserted what the page POSITIONS. This asserts what the workspace HIDES,
    /// by scanning `body` for each chrome placement and checking the brace scope
    /// it sits in — so a fourth page cannot inherit the same defect by forgetting
    /// to add itself to a condition.
    func testWhileAPageIsUpTheWorkspaceDrawsNoChromeOfItsOwn() throws {
        let ws = try codeOnly(sourceURL("WorkspacePlaceholder.swift"))
        let body = try bodyOf(ws)

        XCTAssertTrue(
            ws.contains("private var fullScreenPageUp: Bool { showLatticePage || showSmoothingPage }"),
            "ONE predicate names the state, so a page cannot be half-hidden")

        // The maintainer's own list, verbatim from the handoff.
        let mustBeHidden = [
            "chrome",                     // title / material / undo / redo
            "bottomBar",                  // hint + compute + print params + Optimize
            "bottomRightControls",        // Paint, Fast·64³, Minimize plastic, Design Box
            "selectionsPanel",            // the Selections list with Group A/B
            "latticeEntryButtonOverlay",  // the Lattice chip
            "latticePreviewOverlay",
            "loadOverlays",
            "seeResultsChip",
            "designGizmoOverlay",         // the design-box wireframe handles
            "primitiveGizmoOverlay",      // the red clearance primitives' gizmo
            "clearanceHandlesOverlay",
            "arrowsOverlay",
            "gravityBanner",
            "gravityDirectionOverlay",
            "gravityBaseGizmoOverlay",
        ]
        for element in mustBeHidden {
            XCTAssertTrue(isGuarded(element, in: body),
                          "\(element) is still drawn while a full-screen page is "
                          + "up — that is the overlay defect, not a page")
        }

        // The pattern that let round 1 slip through is gone: per-page gates meant
        // a third page had to remember to add itself to eight conditions.
        XCTAssertFalse(body.contains("!showLatticePage"),
                       "no per-page gate survives — every one is fullScreenPageUp, "
                       + "so a FOURTH page is hidden correctly by default")

        // The clearance VOLUMES are not drawn either: L1 allows protected regions
        // to be indicated, and the brush's frozen tint does that on the surface
        // itself, which is strictly better than a red box floating near it.
        XCTAssertTrue(body.contains("force.phase == .edit && !fullScreenPageUp)"),
                      "the red clearance volumes are not drawn over a page")
    }

    /// L5, structurally: two full-screen pages can never both be up, so their
    /// chrome cannot overlap in the first place. This is also what lets a
    /// `showLatticePage` gate be read as "and therefore not the smoothing page".
    func testTheTwoFullScreenPagesAreMutuallyExclusive() throws {
        let ws = try codeOnly(sourceURL("WorkspacePlaceholder.swift"))
        // The WHOLE function, not a byte window — a window stops asserting the
        // moment the function grows past it.
        func opener(_ name: String) throws -> String {
            let r = try XCTUnwrap(ws.range(of: "private func \(name)"))
            let rest = ws[r.upperBound...]
            let end = rest.range(of: "\n    private ")?.lowerBound ?? rest.endIndex
            return String(rest[rest.startIndex..<end])
        }
        XCTAssertTrue(try opener("openLatticePage").contains("showSmoothingPage = false"),
                      "opening the lattice page closes the smoothing page")
        XCTAssertTrue(try opener("openSmoothingPage").contains("showLatticePage = false"),
                      "opening the smoothing page closes the lattice page")
    }

    /// The page's own brush must not depend on the chrome that is now hidden.
    func testTheSmoothingPageOwnsItsBrushGestureRatherThanBorrowingIt() throws {
        let ws = try codeOnly(sourceURL("WorkspacePlaceholder.swift"))
        // TASK 2026-08-05, BAR D1: this used to pin the expression
        // `showSmoothingPage ? smoothTools.paints : paintActive` — and that
        // expression WAS the defect. `paints` answered "does a FINGER paint?",
        // so checking "Pencil only" disarmed the whole gesture and the pencil
        // stopped painting too. The fact this test exists to protect is
        // unchanged (the page's own tools arm the gesture, never the hidden TO
        // toggle); what it pins is now the value that cannot be misread.
        XCTAssertTrue(
            ws.contains("showSmoothingPage ? .smoothingPage(smoothTools)"),
            "the page's own tools arm the gesture — the TO page's Paint toggle is "
            + "hidden, so depending on it would leave the brush dead")
        XCTAssertFalse(ws.contains("smoothTools.paints "),
                       "and no site reads a finger-only property as the master gate")
        // Anchor on `handleBrush` itself — `if showSmoothingPage {` appears in
        // several routers, and the first one is not this branch.
        let fn = try XCTUnwrap(ws.range(of: "private func handleBrush"))
        let after = ws[fn.upperBound...]
        let opener = try XCTUnwrap(after.range(of: "if showSmoothingPage {"))
        // 1200, not round 2's 900: the branch grew a stroke boundary and a
        // contact-kind gate (task 2026-08-04, U1/U2). The window still stops
        // INSIDE this branch — the `banned` check below is what proves it, since
        // both of those names appear a little further down in the TO page's own
        // branch and would fail this test loudly if the window overran.
        let branch = String(after[opener.lowerBound...].prefix(1200))
        XCTAssertTrue(branch.contains("smoothTools.radiusPoints"),
                      "the disc size comes from the page's tools")
        // Round 3 (bar U1) routes the whole mode through `SmoothBrushModel.brush`
        // rather than mapping erase to a bool at the call site, so the assertion
        // is now on the mode itself — same fact, one fewer translation.
        XCTAssertTrue(branch.contains("smoothTools.mode"),
                      "the paint/erase mode comes from the page's tools")
        XCTAssertTrue(branch.contains("brushGesture.admits(input)"),
                      "and so does whether this contact paints at all (bar U2) — "
                      + "through the SAME gate the recognizer routes on (bar D1), "
                      + "so the page and the viewer cannot disagree")
        for borrowed in ["brushRadiusPoints", "paintErasing"] {
            XCTAssertFalse(branch.contains(borrowed),
                           "the smoothing branch still reads \(borrowed) from the "
                           + "TO paint drawer, which the page no longer shows")
        }
    }

    /// L1's "not editable": the page must not mount the selections EDITOR. AE6 is
    /// unweakened — there is still exactly one `selectionsPanel` in the app.
    func testTheSmoothingPageShowsProtectedRegionsWithoutOfferingToEditThem() throws {
        let ws = try codeOnly(sourceURL("WorkspacePlaceholder.swift"))
        let body = try bodyOf(ws)
        XCTAssertFalse(body.contains("showSmoothingPage, smoothingPageModel?.libraryOpen"),
                       "editing anchors or keep-clear volumes mid-stroke would move "
                       + "the ground the freeze mask was computed on")
        let page = try codeOnly(sourceURL("SmoothingPage.swift"))
        XCTAssertFalse(page.contains("onOpenLibrary"),
                       "the page has no route to the selections editor")
        // ROUND 3 (bar U6) DELETED THE READOUT, NOT THE INDICATION. Round 2's own
        // reasoning for this assertion was that "the strongest indication is not
        // this text: it is the FROZEN TINT the brush paints onto the actual
        // vertices, visible before a stroke is tried" — so the panel row was
        // always the weaker half, and it is the half the maintainer counted as
        // text. The tint is unchanged and is what this now asserts, plus the one
        // dismissible sentence that replaced the paragraph.
        XCTAssertFalse(page.contains("PROTECTED — THE BRUSH CANNOT TOUCH THESE"),
                       "the standing readout is gone (bar U6)")
        let brushSrc = try codeOnly(sourceURL("SmoothBrush.swift"))
        XCTAssertTrue(brushSrc.contains("for v in 0..<out.count where freeze.frozen[v] { out[v] = frozenTint }"),
                      "protected vertices are still TINTED — the indication round "
                      + "2 called the strongest one is untouched")
        XCTAssertTrue(page.contains("SmoothingPageModel.entryNotice"),
                      "and the fact is stated once, dismissibly, on entry")
        // AE6, unchanged.
        let all = try String(contentsOf: sourceURL("WorkspacePlaceholder.swift"),
                             encoding: .utf8)
        XCTAssertEqual(all.components(separatedBy: "private var selectionsPanel").count - 1, 1,
                       "still exactly ONE selections panel in the app")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // L4 — ALL BRUSH TOOLS ON THE PAGE, SHARED TOKENS
    // ═══════════════════════════════════════════════════════════════════════

    func testBrushToolsAreAValueWithTheRulesTheGestureObeys() {
        var t = SmoothBrushTools()
        XCTAssertEqual(t.mode, .paint)
        XCTAssertTrue(t.fingerPaints); XCTAssertFalse(t.erases)

        t.mode = .erase
        XCTAssertTrue(t.fingerPaints, "erasing is still a painting drag")
        XCTAssertTrue(t.erases)

        // ROUND 3 (task 2026-08-04, bar U2) MOVED THIS ASSERTION, and did not
        // drop it. Round 2's invariant was "the page always has a way to orbit
        // with one finger, or the brush owns a gesture the user cannot get back",
        // and `.orbit` was the mode that provided it.
        //
        // TASK 2026-08-05 (bar D2) AMENDS IT AGAIN, and again does not drop it.
        // Round 3 read the maintainer's note as an either/or and deleted Orbit;
        // he has since stated the rule precisely, and it is a conditional. The
        // invariant — a one-finger drag ALWAYS has some way to turn the part
        // around — now holds through two paths, and both are asserted here.
        //
        // PATH 1: `pencilOnly` ON. The finger falls through to the camera.
        t.mode = .paint
        t.pencilOnly = true
        XCTAssertFalse(t.fingerPaints,
                       "pencilOnly releases the one-finger drag — without it the "
                       + "page would have no single-finger orbit at all")
        XCTAssertFalse(t.paints(from: .finger))
        XCTAssertTrue(t.fingerOrbits)
        XCTAssertTrue(t.paints(from: .pencil),
                      "and the pencil still paints — the toggle withholds the "
                      + "FINGER, never the pencil")
        XCTAssertTrue(t.armed,
                      "AND THE BRUSH IS STILL ARMED. This is the D1 defect as an "
                      + "assertion: 'a finger does not paint' must never be read "
                      + "as 'the brush is off', or the pencil dies with it")

        // PATH 2: `pencilOnly` OFF, Orbit mode. The mode releases the drag.
        t.setPencilOnly(false)
        XCTAssertTrue(t.paints(from: .finger), "round 2's behaviour, unchanged")
        XCTAssertTrue(t.paints(from: .pencil))
        XCTAssertFalse(t.fingerOrbits)
        t.mode = .orbit
        XCTAssertTrue(t.fingerOrbits,
                      "with the finger claimed by the brush, Orbit is the only "
                      + "way to turn the part around — bar D2")
        XCTAssertFalse(t.armed, "a parked brush claims no drag at all")
        XCTAssertFalse(t.paints(from: .pencil),
                       "including the pencil's: Orbit is the brush being put "
                       + "down, not a contact-kind filter")

        // The size clamps at both ends, and the bounds are the TO drawer's own.
        t = SmoothBrushTools(radiusPoints: 999)
        XCTAssertEqual(t.radiusPoints, SmoothBrushTools.maxRadius)
        XCTAssertFalse(t.canGrow)
        t = SmoothBrushTools(radiusPoints: 0)
        XCTAssertEqual(t.radiusPoints, SmoothBrushTools.minRadius)
        XCTAssertFalse(t.canShrink)
        t.grow()
        XCTAssertEqual(t.radiusPoints,
                       SmoothBrushTools.minRadius + SmoothBrushTools.radiusStep)
        t.shrink()
        XCTAssertEqual(t.radiusPoints, SmoothBrushTools.minRadius)
    }

    /// Every tool is on the page, in one section, using the shared tokens — the
    /// PR 260 L1 spacing token included.
    func testEveryBrushToolIsOnThePagePanelAndUsesTheSharedTokens() throws {
        let page = try codeOnly(sourceURL("SmoothingPage.swift"))
        XCTAssertTrue(page.contains("private var toolsSection"),
                      "the brush's tools are a section of the page's own panel")
        // TASK 2026-08-05, BAR D2: the modes on offer are CONDITIONAL now — Orbit
        // only while "Pencil only" is off, because that is the only state in
        // which the brush claims the finger. "None is unreachable" is unchanged
        // and is asserted on the value that decides it
        // (`SmoothingRound4Tests.testOrbitIsOfferedOnlyWhilePencilOnlyIsOff`);
        // what the page must do is render whatever that value offers, rather
        // than a list of its own.
        XCTAssertTrue(page.contains("ForEach(tools.availableModes)"),
                      "every mode the tools offer is drawn, so none is unreachable")
        XCTAssertTrue(page.contains("tools.grow()") && page.contains("tools.shrink()"),
                      "the disc size is adjustable on the page")
        XCTAssertTrue(page.contains("brush.clearStrokes()"),
                      "and the strokes can be cleared without leaving the page")

        // The shared tokens, as PR 260's L1 established and AE7 pinned.
        XCTAssertTrue(page.contains("frame(height: PageChrome.compactButton)"),
                      "the mode tabs use the shared compact-control height")
        XCTAssertTrue(page.contains("HStack(spacing: PageChrome.gap)"),
                      "the tools row uses the ONE spacing token")
        XCTAssertEqual(PageChrome.gap, LatticeChromeLayout.gap,
                       "one spacing token across the pages")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // L2 / L5 — THE GIZMO'S CORNER, AND NO OVERLAP IN EITHER ORIENTATION
    // ═══════════════════════════════════════════════════════════════════════

    /// Every page's top-right chrome clears the gizmo, in both orientations, by a
    /// margin computed from the shared tokens rather than eyeballed.
    func testNoPageChromeLandsUnderThePositionGizmo() {
        // The gizmo's own rect, from PageChrome (top-right, inset on both edges).
        let gizmoLeftInsetFromRight = PageChrome.gizmoInset + PageChrome.gizmoSize
        // A page's top-right column stops this far from the right edge.
        let chromeInsetFromRight = PageChrome.edge + PageChrome.gizmoClearance
        XCTAssertGreaterThan(chromeInsetFromRight, gizmoLeftInsetFromRight,
                             "a page's top-right chrome must stop clear of the gizmo")
        // And the clearance token is genuinely derived from the gizmo, not a
        // number that happens to be big enough today.
        XCTAssertEqual(PageChrome.gizmoClearance,
                       PageChrome.gizmoSize + PageChrome.gizmoInset * 2)
        XCTAssertEqual(PageChrome.gizmoSize, OrientationGizmoView.standardSize)

        for canvas in [CGSize(width: 1194, height: 834),   // landscape
                       CGSize(width: 834, height: 1194)] { // portrait
            let gizmo = CGRect(x: canvas.width - PageChrome.gizmoInset - PageChrome.gizmoSize,
                               y: PageChrome.gizmoInset,
                               width: PageChrome.gizmoSize, height: PageChrome.gizmoSize)
            // The page's top-right column occupies everything left of its inset.
            let topRight = CGRect(x: 0, y: PageChrome.topInset,
                                  width: canvas.width - chromeInsetFromRight,
                                  height: PageChrome.barHeight)
            XCTAssertFalse(gizmo.intersects(topRight),
                           "gizmo overlaps the top-right column at \(canvas)")
            // The bottom-right action cluster is nowhere near the top corner.
            let cluster = CGRect(x: 0, y: canvas.height - PageChrome.edge - PageChrome.actionButton,
                                 width: canvas.width - PageChrome.edge,
                                 height: PageChrome.actionButton)
            XCTAssertFalse(gizmo.intersects(cluster),
                           "gizmo overlaps the action cluster at \(canvas)")
            // And in PORTRAIT the panel sits above the cluster, not on it.
            let panel = CGRect(x: 0,
                               y: canvas.height - PageChrome.panelBottomClearance - 200,
                               width: canvas.width, height: 200)
            XCTAssertFalse(panel.intersects(cluster),
                           "the portrait panel overlaps the action cluster at \(canvas)")
        }
    }

    /// L3: the simulation button is BOTTOM RIGHT on the lattice page too — which
    /// is what freed the top-right corner for the gizmo (L2).
    func testTheLatticePagesSimulationButtonIsInTheBottomRightCluster() throws {
        let lattice = try codeOnly(sourceURL("LatticePage.swift"))
        let opener = try XCTUnwrap(lattice.range(of: "private var bottomRightCluster"))
        let cluster = String(lattice[opener.lowerBound...].prefix(700))
        XCTAssertTrue(cluster.contains("runSimButton"),
                      "RUN SIM belongs with the page's other actions, bottom right")
        XCTAssertTrue(cluster.contains("alignment: .bottomTrailing"))

        let topRight = try XCTUnwrap(lattice.range(of: "private var topRightColumn"))
        let top = String(lattice[topRight.lowerBound...].prefix(800))
        XCTAssertFalse(top.contains("sim.run(ctx)"),
                       "the top-right corner no longer holds a control at all — it "
                       + "belongs to the gizmo on every page")
        XCTAssertTrue(top.contains("PageChrome.gizmoClearance"),
                      "and what is left there (the gate's reason) clears the gizmo")
    }

    // MARK: - helpers

    /// `WorkspacePlaceholder.body`, from `public var body` to the next top-level
    /// declaration. The end marker is a CODE line, not a doc comment — this is
    /// read from comment-stripped source, where a comment marker would never be
    /// found and the "body" would silently become the whole file.
    private func bodyOf(_ source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "public var body: some View {"))
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    private var seeResultsChip"),
                                "the body's end marker moved").lowerBound
        return String(rest[rest.startIndex..<end])
    }

    /// Is every placement of `element` unreachable while the SMOOTHING page is up?
    ///
    /// A condition makes it unreachable if it says `!fullScreenPageUp`,
    /// `!showSmoothingPage`, or `showLatticePage` — the last because the two pages
    /// are mutually exclusive by construction (`openLatticePage` clears
    /// `showSmoothingPage` and vice versa, asserted separately), so a placement
    /// gated on the lattice page being up is the lattice page's own chrome.
    ///
    /// The scan walks braces from the top of `body`, remembering at which depth a
    /// guard opened. Multi-line `if` conditions are joined first — an unjoined
    /// scan would miss `if viewOriginal, !fullScreenPageUp, let outcome = …,`
    /// whose brace lands on the following line, and silently report a guarded
    /// element as unguarded.
    private func isGuarded(_ element: String, in body: String) -> Bool {
        var depth = 0
        var guardDepths: [Int] = []
        var found = false
        for line in joinedConditions(body) {
            let opensGuard = ["!fullScreenPageUp", "!showSmoothingPage",
                              "showLatticePage"].contains { line.contains($0) }
            let opens = line.filter { $0 == "{" }.count
            let closes = line.filter { $0 == "}" }.count

            // A single-line guard: `if !fullScreenPageUp { element }`.
            if opensGuard, mentions(element, in: line) { found = true; continue }

            if mentions(element, in: line) {
                found = true
                if guardDepths.isEmpty { return false }
            }
            if opensGuard, opens > closes { guardDepths.append(depth) }
            depth += opens - closes
            while let last = guardDepths.last, depth <= last { guardDepths.removeLast() }
        }
        return found
    }

    /// `body`'s lines with multi-line `if` conditions folded onto one line, so a
    /// condition and the brace it opens are always seen together.
    private func joinedConditions(_ body: String) -> [String] {
        var out: [String] = []
        var pending: String?
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if var p = pending {
                p += " " + line.trimmingCharacters(in: .whitespaces)
                if line.contains("{") { out.append(p); pending = nil } else { pending = p }
                continue
            }
            let t = line.trimmingCharacters(in: .whitespaces)
            if (t.hasPrefix("if ") || t.hasPrefix("} else if ")), !line.contains("{") {
                pending = line
            } else {
                out.append(line)
            }
        }
        if let p = pending { out.append(p) }
        return out
    }

    /// Whether `line` places `element` — a whole-word match, so `chrome` does not
    /// match `latticeChrome` or `page.chrome`, and `bottomBar` does not match
    /// `bottomBarHeight`. A TRAILING `.` is allowed, because a placement is
    /// normally `arrowsOverlay.ignoresSafeArea()`.
    private func mentions(_ element: String, in line: String) -> Bool {
        guard let r = line.range(of: element) else { return false }
        let before = r.lowerBound == line.startIndex
            ? " " : String(line[line.index(before: r.lowerBound)])
        let after = r.upperBound == line.endIndex
            ? " " : String(line[r.upperBound])
        let wordish = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        func isWord(_ s: String) -> Bool {
            s.unicodeScalars.allSatisfy { wordish.contains($0) }
        }
        return !isWord(before) && before != "." && !isWord(after)
    }
}
