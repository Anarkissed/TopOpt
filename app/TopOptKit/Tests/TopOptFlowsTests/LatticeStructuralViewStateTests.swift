import XCTest
import Foundation
@testable import TopOptFlows

/// ★★ HIS 2026-10-01 REPORT: "in Structural, the face-prism isn't showing up whatsoever … I am
/// also not able to go to 'Lattice Only' view." Neither is gated on the stage mode. Both were
/// VIEW STATE that outlived the preview it belongs to, and the only route from Aesthetic to
/// Structural — the mode sheet's delete — turns the preview off without clearing either:
/// - the key's drill-in (`latticeLegendMode == .colour`, his screenshot 2) hides the prisms,
///   depth knobs and gizmos by design, but stayed set with the key gone, so the prism never came
///   back and the exit hint was on the key that was gone;
/// - a leftover `latticeOnly` made the 3 s hold a silent no-op;
/// - lattice only dropped the part while a bake or the stage's FEA hid the lattice: an empty
///   stage until the lattice came back;
/// - a finger kept down past 1.5 s after the hold let go into a tap that undid it;
/// - and a minimized key, or pencil-only input, left the drill-in with no visible or finger exit.
@MainActor
final class LatticeStructuralViewStateTests: XCTestCase {

    private static var sources: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("Sources/TopOptFlows")
    }
    private func src(_ f: String) throws -> String {
        try String(contentsOf: Self.sources.appendingPathComponent(f), encoding: .utf8)
    }
    private func member(_ text: String, _ decl: String) throws -> String {
        let r = try XCTUnwrap(text.range(of: decl), "missing \(decl)")
        let rest = text[r.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n"), "unterminated \(decl)")
        return String(rest[..<end.upperBound])
    }

    // MARK: lattice only — the rule

    /// The part goes only while a lattice is ON SCREEN: not during the bake, not while the
    /// stage's FEA hides the layer, not when there is nothing to lattice. Then it stays opaque.
    func testLatticeOnlyHidesThePartOnlyWhileALatticeIsDrawn() {
        func showing(_ viewOn: Bool, drawn: Bool, sim: Bool, nothing: Bool) -> Bool {
            LatticePreviewBodyAlpha.latticeOnlyShowing(viewOn: viewOn, layerDrawn: drawn,
                                                       simRunning: sim, nothingToDraw: nothing)
        }
        XCTAssertTrue(showing(true, drawn: true, sim: false, nothing: false), "the lattice is up: lattice only shows")
        XCTAssertFalse(showing(true, drawn: true, sim: true, nothing: false),
                       "★ the stage's FEA hides the layer: the part must stay")
        XCTAssertFalse(showing(true, drawn: false, sim: false, nothing: false), "★ the bake is in flight: the part stays")
        XCTAssertFalse(showing(true, drawn: true, sim: false, nothing: true), "nothing to lattice: the part stays")
        XCTAssertFalse(showing(false, drawn: true, sim: false, nothing: false), "lattice only off")
        XCTAssertEqual(LatticePreviewBodyAlpha.latticeOnly(showing: true), 0)
        XCTAssertEqual(LatticePreviewBodyAlpha.latticeOnly(showing: false), 1, "★ never an empty stage")
    }

    /// The workspace asks that rule, and the band chips read the same value as the body —
    /// so the chips never float over a part that is still drawn.
    func testTheBodyAndTheChipsReadOneValue() throws {
        let ws = try src("WorkspacePlaceholder.swift")
        XCTAssertTrue(try member(ws, "private var latticePreviewBodyAlpha: Float")
            .contains("if latticeOnlyViewOn { return LatticePreviewBodyAlpha.latticeOnly(showing: latticeOnlyShowing) }"))
        let showing = try member(ws, "private var latticeOnlyShowing: Bool")
        for input in ["viewOn: latticeOnlyViewOn", "layerDrawn: latticeLayerIsDrawn",
                      "simRunning: latticeSimIsRunning", "nothingToDraw: latticePreviewHasNothingToDraw"] {
            XCTAssertTrue(showing.contains(input), input)
        }
        XCTAssertFalse(ws.contains("if latticeOnly, showStrutPreview { return 0 }"), "★ the unconditional drop is gone")
        XCTAssertTrue(try member(ws, "private var bandChipsAvailable: Bool").contains("latticeOnlyShowing"))
    }

    // MARK: lattice only — the hold and the tap

    /// Both read the VIEW, not the flag; the hold arms the preview exactly as the tap does.
    func testTheHoldAndTheTapReadTheViewAndArmThePreviewOneWay() throws {
        let ws = try src("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("guard !latticeOnlyViewOn else { return }"), "★ a leftover flag cannot make the hold a no-op")
        XCTAssertFalse(ws.contains("guard !latticeOnly else { return }"))
        XCTAssertTrue(ws.contains("if !showStrutPreview { armLatticePreview() }"), "★ the hold arms the preview as the tap does")
        XCTAssertTrue(ws.contains("if latticeOnlyViewOn {\n                        latticeOnly = false"), "the tap reads the view")
        let arm = try member(ws, "private func armLatticePreview()")
        for step in ["showStrutPreview = true", "if !project.lattice.enabled {", "showLatticeWizard = true",
                     "openLatticeSettingsIfUnconfigured()", "startStressSolveIfNeeded()", "buildStrutScene()"] {
            XCTAssertTrue(arm.contains(step), "★ the one arming path: \(step)")
        }
        XCTAssertEqual(ws.components(separatedBy: "startStressSolveIfNeeded()\n        refreshLatticeStressPeak()").count - 1, 1,
                       "the tap's old copy is gone — one path")
        XCTAssertTrue(ws.contains("tint: latticeOnlyViewOn ? DS.Color.warning : nil"))
    }

    // MARK: the preview going off ends both views

    /// Every path that turns the preview off — the cube, the mode sheet's delete, lattice mode
    /// off, the page's switch — ends lattice only and the key's drill-in.
    func testThePreviewGoingOffEndsLatticeOnlyAndTheDrillIn() throws {
        let ws = try src("WorkspacePlaceholder.swift")
        let r = try XCTUnwrap(ws.range(of: ".onChange(of: showStrutPreview) { on in"))
        let reset = String(ws[r.lowerBound...].prefix(260))
        for line in ["guard !on else { return }", "latticeOnly = false",
                     "latticeLegendMode = .groups", "latticeLegendProbe = nil"] {
            XCTAssertTrue(reset.contains(line), "★ \(line)")
        }
        // the mode sheet's delete (Aesthetic → Structural) is one of those paths
        XCTAssertTrue(try member(ws, "private func deleteLatticeForMode()").contains("showStrutPreview = false"))
    }

    // MARK: the key's drill-in

    /// The drill-in counts only while the key is on screen; every hide reads that one value.
    func testTheDrillInCountsOnlyWhileTheKeyIsOnScreen() throws {
        let ws = try src("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("private var latticeLegendMounted: Bool { showStrutPreview && strutScene != nil }"))
        XCTAssertTrue(try member(ws, "private var legendDrilledIn: Bool")
            .contains("latticeLegendMounted && !latticeLegendMinimized && latticeLegendMode.drilledIn"),
                      "★ on screen AND not minimized — a minimized key has no exit hint")
        XCTAssertEqual(ws.components(separatedBy: "latticeLegendMode.drilledIn").count - 1, 1,
                       "★ every read goes through `legendDrilledIn` (the one raw read is its definition)")
        XCTAssertTrue(ws.contains("if latticeLegendMounted {\n                    latticeDensityLegend"),
                      "the key is mounted on the same expression")
        // the prism itself: the clearance volumes hide only while the key is drilled in AND on screen
        let r = try XCTUnwrap(ws.range(of: "clearanceVolumes:\n"))
        XCTAssertTrue(String(ws[r.lowerBound...].prefix(260)).contains("!legendDrilledIn"))
    }

    // MARK: the release of a hold

    /// The release's tap is swallowed by the PRESS the hold fired during, not by a 1.5 s clock a
    /// finger kept down could outlive; a later press is never swallowed; without press tracking
    /// the old clock remains; and the press rule is bounded.
    func testTheReleaseOfAHoldIsSwallowedByItsPressNotByAClock() throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let fired = t0.addingTimeInterval(3)                        // the hold fires at 3 s
        func swallow(began: Date?, at s: TimeInterval) -> Bool {
            ViewModeHold.swallowsTap(holdFiredAt: fired, pressBeganAt: began, now: t0.addingTimeInterval(s))
        }
        XCTAssertTrue(swallow(began: t0, at: 3.4), "the usual release")
        XCTAssertTrue(swallow(began: t0, at: 6.0), "★ held 3 s past the hold: still the same press — swallowed")
        XCTAssertFalse(swallow(began: t0.addingTimeInterval(7), at: 7.1), "★ a NEW press is a real tap")
        XCTAssertFalse(swallow(began: t0, at: 3 + ViewModeHold.pressWindowS + 1), "bounded")
        XCTAssertTrue(swallow(began: nil, at: 4.0), "no press tracked: the old clock")
        XCTAssertFalse(swallow(began: nil, at: 5.0))
        XCTAssertFalse(ViewModeHold.swallowsTap(holdFiredAt: .distantPast, pressBeganAt: t0, now: t0),
                       "no hold yet: nothing is swallowed")
        let ws = try src("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("if ViewModeHold.swallowsTap(holdFiredAt: viewModeHoldFiredAt,"))
        XCTAssertFalse(ws.contains("if Date().timeIntervalSince(viewModeHoldFiredAt) < 1.5 { return }"), "the clock alone is gone")
        XCTAssertTrue(ws.contains(".updating($viewModePressDown) { _, down, _ in down = true }"), "the press is tracked")
        XCTAssertTrue(ws.contains("if down { viewModePressBeganAt = Date() }"), "…and stamped")
    }

    /// Leaving the key is not an edit: a finger double-tap always exits, pencil-only or not.
    func testAFingerDoubleTapAlwaysLeavesTheKey() throws {
        let mm = try src("MetalMeshView.swift")
        let r = try XCTUnwrap(mm.range(of: "@objc func handleDoubleTap(_ g: UITapGestureRecognizer) {"))
        let body = String(mm[r.lowerBound...].prefix(500))
        let exit = try XCTUnwrap(body.range(of: "if let onLatticeProbeExit { onLatticeProbeExit(); return }"))
        let gate = try XCTUnwrap(body.range(of: "guard inputDiscipline.admits(.finger, .edit) else { return }"))
        XCTAssertLessThan(exit.lowerBound, gate.lowerBound, "★ the exit is answered before the pencil-only gate")
    }

    // MARK: no stage-mode gate on either

    /// The prism and lattice only carry over to Structural by construction: neither the depth
    /// planes nor the volume pass nor the hold reads the stage mode.
    func testNeitherThePrismNorLatticeOnlyReadsTheStageMode() throws {
        let pm = try src("ProjectModel.swift")
        XCTAssertFalse(try member(pm, "public func latticeDepthPlanes()").contains("stageMode"))
        let ws = try src("WorkspacePlaceholder.swift")
        for decl in ["private var stageVolumeItems", "private var latticeDepthPlaneItems",
                     "private var latticeOnlyShowing: Bool", "private func armLatticePreview()",
                     "private var legendDrilledIn: Bool"] {
            XCTAssertFalse(try member(ws, decl).contains("stageMode"), decl)
        }
        XCTAssertFalse(try src("MetalMeshView.swift").contains("stageMode"))
    }
}

/// ★ HIS PROJECT, STRUCTURAL vs AESTHETIC (opt-in; reads a COPY of his store, never the live one):
///
///     TOPOPT_PROJECT_ROOT=<copy of …/TopOpt/Projects> \
///     TOPOPT_PROJECT_ID=3418E167-8524-4831-A809-827B6B0742D0 \
///     swift test --filter LatticeStructuralPrismProbe
///
/// Opens the project as the app does and builds the purple depth planes in BOTH modes: the
/// geometry must be identical and non-empty — the prism's data does not depend on the mode.
@MainActor
final class LatticeStructuralPrismProbe: XCTestCase {
    func testThePrismIsTheSameInBothModes() throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["TOPOPT_PROJECT_ROOT"], let idStr = env["TOPOPT_PROJECT_ID"],
              let id = UUID(uuidString: idStr) else { throw XCTSkip("set TOPOPT_PROJECT_ROOT and TOPOPT_PROJECT_ID") }
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        let store = ProjectStore(rootDir: URL(fileURLWithPath: root))
        let m = AppModel(materialsPath: repo.appendingPathComponent("core/src/materials/materials.json").path,
                         rulesPath: repo.appendingPathComponent("core/src/settings/rules.json").path, store: store)
        m.loadMaterials()
        let recent = try XCTUnwrap(m.recentProjects.first { $0.id == id }, "no project \(idStr)")
        m.open(recent)
        let p = try XCTUnwrap(m.project)
        func planes(_ mode: LatticeStageMode) -> [String] {
            p.lattice.stageMode = mode
            return p.latticeDepthPlanes().map {
                String(format: "%@ face %d %@ depth %.3f", $0.ref.key, $0.faceKey, "\($0.role)", $0.depthMM)
            }
        }
        let saved = p.lattice.stageMode
        let structural = planes(.structural), aesthetic = planes(.aesthetic)
        p.lattice.stageMode = saved
        print("PRISM-PROBE \(p.name) saved mode \(saved.map { "\($0)" } ?? "nil") algorithm \(p.lattice.algorithm)")
        for l in structural { print("PRISM-PROBE structural  \(l)") }
        for l in aesthetic { print("PRISM-PROBE aesthetic   \(l)") }
        XCTAssertFalse(structural.isEmpty, "★ Structural builds the prism")
        XCTAssertEqual(structural, aesthetic, "★ the same prism in both modes")
    }
}
