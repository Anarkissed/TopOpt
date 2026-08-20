// LatticeLegendColourTests — ★ THE KEY IS ABOUT THE COLOURS
// (maintainer, 2026-08-19, in order: "there is no explanation of it! There are a
// bunch of different lattice colours! What do they mean??" → "But there are
// different colours - green, purple, blue. These mean different things." → "This
// isn't usable for anyone on a touch screen." → "change the entire legend. the
// lightness isn't the most important part. The important part is the difference in
// colours … One colour. One explanation. Make it large enough to read.")
//
// ★★ WHAT A STRUT'S COLOUR ACTUALLY IS, and why the first two attempts were wrong:
//
//     baseC = mix(sparseColor, denseColor, density)     <- lightness
//     baseC = mix(baseC, groupColour, ft.a * 2.2)       <- HUE  (`derivedTint`)
//
// The hue says WHICH GROUP owns the face; lightness is a detail inside one hue. The
// first key showed only the ramp — and rendered it black, because `DS.RGBA` already
// divides by 255 and the bar divided again. The second explained the hue in 8-point
// prose. This one leads with the colours, one sentence each, at readable sizes.

import XCTest
@testable import TopOptFlows
@testable import TopOptDesign

final class LatticeLegendColourTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// ★ THE CONTRACT, IN THE UNITS THE TYPE DOCUMENTS. `RGBA` says 0-1, so a
    /// consumer that scales by 255 again renders black — which is exactly what the
    /// first legend did.
    func testTheDensityRampIsAlreadyNormalisedZeroToOne() {
        let sparse = LatticeDensityProxy.densityColor(fraction: 0)
        let dense = LatticeDensityProxy.densityColor(fraction: 1)
        for (name, c) in [("sparse", sparse), ("dense", dense)] {
            for (ch, v) in [("r", c.r), ("g", c.g), ("b", c.b)] {
                XCTAssertLessThanOrEqual(v, 1,
                    "★ \(name).\(ch) = \(v) — `RGBA` stores 0-1; a component above 1 "
                    + "means the 0-255 values were passed through unscaled.")
            }
        }
        XCTAssertGreaterThan(sparse.r, 0.85,
                             "★ the SPARSE end is near-white — got \(sparse.r); near 0 "
                             + "is the double-divide that rendered the bar black.")
    }

    /// ★ AND NOTHING IN THE PANEL MAY RE-SCALE A COLOUR. Group colours arrive as
    /// `DS.RGBA` (already 0-1) and are handed to `RGBAColor` unchanged.
    func testTheLegendPanelNeverDividesAColourAgain() throws {
        let panel = try source("LatticeLegendPanel.swift")
        XCTAssertFalse(panel.contains("/ 255"),
                       "★ the panel must not divide a colour by 255 — every colour it "
                       + "receives is already 0-1, and dividing again renders black.")
        XCTAssertFalse(panel.contains(".r / 255"), "no scaled component reaches a Color")
    }

    /// ★★ ONE COLOUR = ONE EXPLANATION, and the three must actually DIFFER
    /// (maintainer: "the copy is terrible. It needs to actually EXPLAIN what the
    /// differences are"). Now that hue means STRUCTURE, this is a plain unit test on
    /// the table rather than a scan of a view body.
    func testEachStructureColourHasItsOwnExplanation() {
        let all = LatticeStructureClass.allCases
        XCTAssertEqual(all.count, 3, "rim, interior, load")
        XCTAssertEqual(Set(all.map(\.title)).count, 3, "distinct titles")
        XCTAssertEqual(Set(all.map(\.detail)).count, 3,
                       "★ each colour needs its OWN sentence, not one caption reused")
        XCTAssertEqual(Set(all.map(\.id)).count, 3, "distinct ids, so drilling in works")
        for c in all {
            XCTAssertGreaterThan(c.detail.count, 40,
                                 "★ \(c.title)'s sentence must EXPLAIN the difference, "
                                 + "not label the row — got \"\(c.detail)\"")
        }
        // The three hues must be visibly different, or the key explains a
        // distinction the eye cannot make.
        for (a, b) in [(LatticeStructureClass.rim, LatticeStructureClass.interior),
                       (.interior, .load), (.rim, .load)] {
            let d = abs(a.colour.r - b.colour.r) + abs(a.colour.g - b.colour.g)
                  + abs(a.colour.b - b.colour.b)
            XCTAssertGreaterThan(d, 0.35,
                                 "★ \(a.title) and \(b.title) must be tellable apart — "
                                 + "channel distance \(d)")
        }
    }

    /// ★ AND THE PART MUST BE PAINTED FROM THE SAME TABLE THE KEY READS. A second
    /// copy of the palette for the legend is how a key ends up describing a picture
    /// the renderer stopped drawing.
    func testTheMarchIsFedTheSamePaletteTheKeyShows() throws {
        let sdf = try source("LatticeSDFMetal.swift")
        for field in ["rimColor", "loadColor", "denseColor"] {
            XCTAssertTrue(sdf.contains(field),
                          "the uniform must carry \(field) to the shader")
        }
        XCTAssertTrue(sdf.contains("LatticeStructureColour.rim"),
                      "★ the rim hue must come from the shared table")
        XCTAssertTrue(sdf.contains("LatticeStructureColour.load"),
                      "★ …and so must the load hue")
        XCTAssertTrue(sdf.contains("LatticeStructureColour.loadCut"),
                      "★ …and the cut that decides which cells are load-carrying")
    }

    /// ★ THE STRUT'S HUE IS NO LONGER THE GROUP TINT. That was the whole confusion
    /// ("I thought they were tinted for different *types* of lattice structures"),
    /// so the shader must not mix the face-role tint into a strut any more.
    func testStrutsAreNotPaintedWithTheGroupTint() throws {
        let sh = try source("UnifiedShading.swift")
        guard let r = sh.range(of: "static float3 lsdf_albedo") else {
            return XCTFail("the lattice albedo must exist")
        }
        let body = String(sh[r.lowerBound...].prefix(3000))
        XCTAssertFalse(body.contains("ft.a * 2.2"),
                       "★ the group tint must no longer be mixed into a strut — hue "
                       + "belongs to the lattice's structure now")
        XCTAssertTrue(body.contains("U.rimColor") && body.contains("U.loadColor"),
                      "★ …and the three structure hues must be what it picks between")
    }

    /// ★ THE TWO LEVELS, and the way back out.
    func testTheModeKnowsWhenItIsDrilledIn() {
        XCTAssertFalse(LatticeLegendMode.groups.drilledIn)
        XCTAssertNil(LatticeLegendMode.groups.groupID)
        let id = UUID()
        XCTAssertTrue(LatticeLegendMode.colour(id).drilledIn)
        XCTAssertEqual(LatticeLegendMode.colour(id).groupID, id)
    }

    /// ★ A TAP READS INSTEAD OF SELECTING, AND A DOUBLE TAP COMES BACK OUT. Both are
    /// behaviours he asked for by name, and both are easy to drop in a refactor.
    func testTappingWhileDrilledInReadsTheLatticeAndDoubleTapExits() throws {
        let ws = try source("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("if latticeLegendMode.drilledIn { return true }"),
                      "★ a tap while drilled in must be CONSUMED by the face path — "
                      + "the READING comes from `onLatticeProbe`, and returning false "
                      + "here would let the same tap regroup a face while he reads it")
        XCTAssertTrue(ws.contains("onLatticeProbeExit: latticeLegendMode.drilledIn"),
                      "★ a double tap must come back out to the colour list — and it "
                      + "hangs off `onLatticeProbeExit`, not `onPickDouble`, because "
                      + "leaving the key must not require a face under the finger")
    }

    /// ★★ THE READING IS ANCHORED IN 3D, NOT ON SCREEN (maintainer: "I would like
    /// the arrow to follow the position in 3D space if moved"). A stored `CGPoint`
    /// froze the callout where the finger had been; the probe must carry the MODEL
    /// point and the view must re-project it.
    func testTheProbeIsAnchoredInModelSpace() throws {
        let probe = LatticeLegendProbe(groupID: nil, density: 0.5, mm: 1.0,
                                       worldPoint: SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(probe.worldPoint, SIMD3<Float>(1, 2, 3))
        let ws = try source("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("projection?.project(p.worldPoint)"),
                      "★ the callout must RE-PROJECT the point every render, or it "
                      + "stops pointing at the strut the moment the part orbits")

        // ★★ AND EACH SPACE MUST BE USED FOR THE RIGHT JOB. `modelView = view · model`
        // where `model` is the settle rotation, so the two differ. Sampling the baked
        // grids needs MODEL space; `CameraProjection.project` takes WORLD. Crossing
        // them put the callout far from the finger AND read the density in the wrong
        // place, which pinned every reading to the floor of the band.
        let mv = try source("MetalMeshView.swift")
        XCTAssertTrue(mv.contains("simd_inverse(modelViewMatrix()) * eye"),
                      "★ the MODEL point must undo view·model — it samples the grids")
        XCTAssertTrue(mv.contains("simd_inverse(camera.viewMatrix()) * eye"),
                      "★ the WORLD point must undo the view ALONE — it is projected")
        XCTAssertTrue(ws.contains("setLatticeProbe(at: model, world: world)"),
                      "★ …and the caller must keep them apart")
    }

    /// ★★ AND THE TAP MUST BE ANSWERED BY THE MARCH, NOT THE FACE PICKER
    /// (maintainer: "I attempted to touch the green 'Load bearing' area. But it
    /// didn't work. The tap isn't registering well enough"). The face picker reports
    /// the wall BEHIND a strut, and reports nothing at all where the id pass says
    /// background — which is exactly where struts stand proud of the surface.
    func testTheTapReadsTheStrutFromTheGBuffer() throws {
        let mv = try source("MetalMeshView.swift")
        XCTAssertTrue(mv.contains("func latticeProbe(atNormalizedPoint"),
                      "★ the renderer must answer a tap from the march's own G-buffer")
        XCTAssertTrue(mv.contains("guard rgba[n * 4 + 3] >= 128 else { continue }"),
                      "★ …keyed on the strut mask, so a tap off the lattice is a miss")
        // ★★ AND IT MUST SEARCH A TOUCH-SIZED WINDOW, not one texel. Struts are thin;
        // between them the ray reaches the shell, so a single-pixel test misses most
        // of the time even with the finger squarely on the lattice — which is what
        // "the tap isn't registering well enough" was.
        XCTAssertTrue(mv.contains("var bestI = -1, bestD = Int.max"),
                      "★ the probe must take the NEAREST strut texel in a window "
                      + "around the tap, or a fingertip is asked to hit one pixel")
        let ws = try source("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("onLatticeProbe: latticeLegendMode.drilledIn"),
                      "★ …and it is armed only while the key is drilled in")
        // ★★ AND IT MUST NOT EAT THE DOUBLE TAP. `pickDouble` resolves the second
        // tap through the SAME `pick(...)`, passing a `deliver` closure; a probe that
        // fires there returns before `onPickDouble` and silently removes the only
        // gesture that leaves the drilled-in key.
        XCTAssertTrue(mv.contains("if deliver == nil, let probe = onLatticeProbe {"),
                      "★ the probe must claim SINGLE taps only — `deliver == nil` is "
                      + "what distinguishes them from the double-tap path")
    }

    /// ★ AND THE PART MUST BE UNOBSTRUCTED WHILE HE READS IT ("hide any primitives
    /// and handles when someone taps into the legend").
    func testDrillingInHidesThePrimitivesAndHandles() throws {
        let ws = try source("WorkspacePlaceholder.swift")
        // ★ THE ARROWS COUNT AS HANDLES (maintainer, 2026-08-19: "the primitives and
        // handles are not hidden when we touch into the legend!"). The first cut
        // gated only the three gizmo overlays; the load/anchor markers, the depth
        // handles, the region gizmo and the keep-out volumes were all still drawn
        // over the struts he was trying to read.
        for gate in ["designGizmoOverlay", "primitiveGizmoOverlay", "clearanceHandlesOverlay",
                     "arrowsOverlay", "latticeDepthHandlesOverlay", "latticeRegionGizmoOverlay"] {
            guard let r = ws.range(of: gate) else { return XCTFail("\(gate) must exist") }
            let around = String(ws[..<r.lowerBound].suffix(400))
            XCTAssertTrue(around.contains("!latticeLegendMode.drilledIn"),
                          "★ \(gate) must be hidden while the key is drilled in")
        }
    }

    /// ★★ THE STRESS SCALE IS ONLY OFFERED WHEN THE PLOT IS ACTUALLY ON THE STRUTS
    /// (maintainer: "add the stress map only when the stress map is selected along
    /// with the lattice view"). The overlay is armed by `stressViewOn && field != nil`
    /// on the lattice layer; the key must be gated on the SAME condition, or it draws
    /// a scale for colours the renderer is not painting.
    func testTheStressScaleIsGatedOnTheOverlayBeingArmed() throws {
        let ws = try source("WorkspacePlaceholder.swift")
        guard let r = ws.range(of: "func latticeLegendStress()") else {
            return XCTFail("the key must be able to carry the stress scale")
        }
        let body = String(ws[r.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("guard stressViewOn, let f = latticeStressField"),
                      "★ gated on the same condition that arms the overlay")
        XCTAssertTrue(body.contains("LatticeStressTint.legendTicks")
                      && body.contains("LatticeStressTint.legendColours"),
                      "★ …and built from the SAME table the plot is painted from, so "
                      + "the key and the part cannot disagree about a colour")
    }

    /// ★ AND ONLY ONE KEY IS ON THAT EDGE. Two colour bars side by side was the thing
    /// the original legend rule existed to prevent; now the lattice key carries the
    /// stress scale, so the standalone plot legend must stand down instead.
    func testOnlyOneLegendOccupiesTheEdge() throws {
        let ws = try source("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("!(showStrutPreview && strutScene != nil) {\n                    stressLegend"),
                      "★ the standalone stress legend must stand down while the "
                      + "lattice key is up and carrying the scale itself")
    }

    /// ★ AND WHEN STRESS OWNS THE STRUTS, THE KEY MUST NOT STILL CLAIM THEY MEAN
    /// STRUCTURE. `lsdf_albedo` returns the stress colour BEFORE it ever reaches the
    /// structure hue, so listing rim/interior/load then would describe colours that
    /// are not on screen.
    /// ★★ THE TWO KEYS WORK TOGETHER, NOT IN TURN (maintainer, 2026-08-19: "include
    /// the stress map legend WITH the lattice legend -- working together. I want to be
    /// able to click on any place and find both the lattice type and stress level.
    /// Simultaneously. So two arrows on two hue levels").
    func testBothScalesShareThePanelAndBothCarryAnArrow() throws {
        let panel = try source("LatticeLegendPanel.swift")
        XCTAssertFalse(panel.contains("if let stress { stressScale(stress) } else { groupList }"),
                       "★ the stress scale must NOT replace the structure rows")
        XCTAssertTrue(panel.contains("func stressArrow("),
                      "★ the stress bar needs its OWN arrow at the tapped value")
        XCTAssertTrue(panel.contains("private var probeArrow"),
                      "★ …beside the density one, so one tap marks both scales")
        XCTAssertTrue(panel.contains("public let stressMPa: Double?"),
                      "★ and the reading must carry both numbers from one tap")
    }

    /// ★ AND THE TWO NUMBERS MUST DESCRIBE ONE STRUT. The stress is sampled at the
    /// SAME model-space point the density was, not at the screen point or the world
    /// point — otherwise the panel reports two different places with confidence.
    func testBothReadingsComeFromTheSamePoint() throws {
        let ws = try source("WorkspacePlaceholder.swift")
        guard let r = ws.range(of: "var mpa: Double?") else {
            return XCTFail("the probe must read a stress value")
        }
        let body = String(ws[r.lowerBound...].prefix(1400))
        XCTAssertTrue(body.contains("(point - o)"),
                      "★ the stress must be sampled at the MODEL point the density "
                      + "used — `point`, not `world`")
        XCTAssertTrue(body.contains("stressMPa: mpa"),
                      "★ …and travel with the same reading")
    }

    /// ★★ AND THE RECOGNIZER MUST ACTUALLY BE MOUNTED FOR IT. The double-tap gesture
    /// is enabled by a single gate; asking only about `onPickDouble` disabled it
    /// outright on a page that wants the exit but no face double-tap — the handler was
    /// correct and simply never ran.
    func testTheDoubleTapRecognizerMountsForTheKeyExitToo() throws {
        let mv = try source("MetalMeshView.swift")
        XCTAssertTrue(mv.contains("let wantsDouble = inputs.onPickDouble != nil || inputs.onLatticeProbeExit != nil"),
                      "★ the gesture must mount when EITHER reason to want a double "
                      + "tap is present, or the exit is dead on arrival")
    }

    /// ★ A double tap must leave the key from ANYWHERE, including empty space
    /// ("I would prefer the double tap work *anywhere*"). The face-resolving path
    /// drops a miss on the floor, so the exit cannot live there.
    func testTheDoubleTapExitDoesNotNeedAFaceUnderIt() throws {
        let mv = try source("MetalMeshView.swift")
        guard let r = mv.range(of: "private func pickDouble(") else {
            return XCTFail("the double-tap resolve must exist")
        }
        let body = String(mv[r.lowerBound...].prefix(1200))
        let exitAt = body.range(of: "onLatticeProbeExit")
        let guardAt = body.range(of: "guard let view = g.view as? MTKView")
        XCTAssertNotNil(exitAt, "★ the drilled-in exit must be handled here")
        if let e = exitAt, let g = guardAt {
            XCTAssertTrue(e.lowerBound < g.lowerBound,
                          "★ …and BEFORE anything that needs geometry under the tap, "
                          + "or a double tap on air still does nothing")
        }
    }
}
