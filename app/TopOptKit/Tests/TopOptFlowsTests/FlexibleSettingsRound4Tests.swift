// FlexibleSettingsRound4Tests — batch D1, "the Settings page, round 4" (task
// 2026-09-29-flexible-screens; his notes after testing batches A + B on the simulator).
//
// Each test pins one of his round-4 notes, on HIS project where the note came from it, and
// carries a positive control that is RED on the rule it replaces:
//   * the face LIST (img 1): his faces as big obviously-tappable rows; a tap selects THAT
//     region (a sector too) and the rows below edit it — RED: a tap routed through the part's
//     face selects the whole split face, not top B;
//   * the panel only as tall as its content (img 1) — RED: a ScrollView in a max-height frame
//     takes every point it is offered;
//   * minimize the panel and the legend (img 1);
//   * Shape [Curves | Stamp] a true either/or (img 1, img 4, answer 3): Stamp is live, shows
//     the face's ONE stamp inline, the curves go at once; the Stamps tab and check stamps go;
//     no stamp handle under the panel (img 6's black circles) — RED: his project's two check
//     stamps drew two handles;
//   * the depth prism and chip in the lattice stage's face-prism purple (img 2, his explicit
//     request) — and batch C's "never violet" main-page hook reverted;
//   * the model-wide Finish None / Rim / Skin / Covered (img 5, answer 4): settings, the job,
//     the lattice field — RED controls on each finish's opposite;
//   * NO lattice on the Settings page (img 6): X-ray + the bent map only;
//   * Auto and Physics open inline behind a caret (img 7) — RED: an (i) popover leaves the
//     row's height unchanged.
import XCTest
import SwiftUI
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleSettingsRound4Tests: XCTestCase {

    // MARK: - the face list (img 1: "list the different faces … make it obvious that it's selectable")

    @MainActor
    func testTheFaceListListsHisFacesAndATapSelectsThatFace() async throws {
        let his = try FlexibleHisProject.restore()
        defer { his.cleanup() }
        let m = try await FlexibleHisProject.openedModel(his.project, test: self)
        let rows = FlexibleFaceList.rows(model: m)
        print("FLEX-LIST his faces: " + rows.map { "\($0.line)\($0.selected ? " ✓" : "")" }.joined(separator: " | "))
        // every face set on the main page (and here) is listed: pressed first, then resting
        XCTAssertEqual(Set(rows.map(\.region)), Set(m.settings.faces.map(\.faceRegionID)))
        let firstRest = rows.firstIndex { !$0.pressed } ?? rows.count
        XCTAssertTrue(rows[firstRest...].allSatisfy { !$0.pressed }, "pressed faces first")
        XCTAssertTrue(rows.contains { $0.region == FlexibleHisProject.topB && $0.line.hasPrefix("Top B · Pressed") })
        for r in rows {
            XCTAssertLessThanOrEqual(r.line.count, FlexibleRowCopy.maxChars, "one line: \(r.line)")
            XCTAssertFalse(r.line.contains("\n"))
        }
        XCTAssertGreaterThanOrEqual(FlexibleFaceList.rowHeight, 48, "a big, obviously tappable row")
        // a tap on top B's row selects top B — the rows below (weight, shape, depth) are ITS
        m.select(FlexibleHisProject.topB)
        XCTAssertEqual(m.selectedRegion, FlexibleHisProject.topB)
        XCTAssertEqual(FlexibleFaceList.rows(model: m).filter(\.selected).map(\.region), [FlexibleHisProject.topB])
        let b = try XCTUnwrap(m.settings.face(FlexibleHisProject.topB))
        let selectedRow = try XCTUnwrap(FlexibleFaceList.rows(model: m).first { $0.selected })
        XCTAssertTrue(selectedRow.line.hasSuffix(FlexibleRowCopy.kgText(b.weightKg)), "the row says the value the rows below edit")
        // ★ RED CONTROL: a tap through the PART's face (no point) selects the whole split face
        m.tapFace(1)
        XCTAssertNotEqual(m.selectedRegion, FlexibleHisProject.topB, "control: the part's face is not the sector")
        // source pins: the panel mounts the list; the D2 group rows have their marked place
        let panel = try FlexibleSource.code("FlexibleFacePanel.swift")
        XCTAssertTrue(panel.contains("FlexibleFaceList(model: model)"))
        let list = try FlexibleSource.text("FlexibleFaceList.swift")
        XCTAssertTrue(list.contains("SQUEEZE GROUPS (batch D2)"), "the place for D2's group rows is marked")
        XCTAssertTrue(list.contains("model.select(row.region)"))
        XCTAssertTrue(list.contains(".accessibilityAddTraits(row.selected ? [.isButton, .isSelected] : .isButton)"))
    }

    // MARK: - the panel only as tall as it needs to be; minimize (img 1)

    #if canImport(AppKit)
    @MainActor
    static func height<V: View>(_ v: V, proposed: CGSize) -> CGFloat {
        NSHostingController(rootView: v.environment(\.colorScheme, .dark)).sizeThatFits(in: proposed).height
    }

    @MainActor
    func testThePanelIsOnlyAsTallAsItsContent() throws {
        let offered = CGSize(width: 400, height: 900)
        func scroll(_ h: CGFloat) -> some View { ScrollView { Color.red.frame(height: h) } }
        let short = Self.height(FlexibleHugHeight { scroll(300) }, proposed: offered)
        let long = Self.height(FlexibleHugHeight { scroll(2000) }, proposed: offered)
        print("FLEX-PANEL hug: 300 pt content → \(short) · 2000 pt content → \(long) (offered \(offered.height))")
        XCTAssertEqual(short, 300, accuracy: 1, "as tall as the content")
        XCTAssertEqual(long, 900, accuracy: 1, "never taller than offered: it scrolls")
        // ★ RED CONTROL: round 3's panel — a ScrollView in a max-height frame takes it all
        let old = Self.height(scroll(300).frame(maxHeight: 900), proposed: offered)
        XCTAssertEqual(old, 900, accuracy: 1, "control: the old panel took every point it was offered")
        // the page puts its panel through it
        let panel = try FlexibleSource.code("FlexibleSettingsPanel.swift")
        XCTAssertTrue(panel.contains("FlexibleHugHeight {"))
        let page = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertTrue(page.contains("FlexibleSettingsPanel(model: model, padTarget: $padTarget, minimized: $panelMinimized)"))
        XCTAssertFalse(page.contains("ScrollView(.vertical"), "the page no longer builds a greedy scroll of its own")
    }

    @MainActor
    func testThePanelAndTheLegendMinimize() async throws {
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        let probe = try FlexibleHisProject.padProject(s)
        let top = FlexibleHisProject.topFace(try XCTUnwrap(probe.viewerMesh))
        s.setFace(FlexibleFaceSettings(faceRegionID: top))
        let m = try await FlexibleHisProject.openedModel(try FlexibleHisProject.padProject(s), test: self)
        m.selectedRegion = top
        let offered = CGSize(width: 400, height: 900)
        let open = Self.height(FlexibleSettingsPanel(model: m, padTarget: .constant(nil), minimized: .constant(false)), proposed: offered)
        let mini = Self.height(FlexibleSettingsPanel(model: m, padTarget: .constant(nil), minimized: .constant(true)), proposed: offered)
        print("FLEX-PANEL pad: open \(open) pt · minimized \(mini) pt (offered \(offered.height))")
        XCTAssertLessThan(open, offered.height - 100, "the pad's panel hugs its rows")
        XCTAssertGreaterThan(open, 250, "control: the open panel carries its rows")
        XCTAssertLessThanOrEqual(mini, 80, "minimized: the header alone")
        // the legend's minimized form is a narrow bar (the lattice legend's idiom)
        let bar = NSHostingController(rootView: FlexibleLegendBar(fraction: nil)).sizeThatFits(in: offered)
        XCTAssertLessThan(bar.width, 80)
        let page = try FlexibleSource.code("FlexibleStagePage.swift")
        let panelSrc = try FlexibleSource.code("FlexibleSettingsPanel.swift")
        XCTAssertTrue(panelSrc.contains(".accessibilityIdentifier(\"flexible-panel-minimize\")"))
        XCTAssertTrue(page.contains(".accessibilityIdentifier(\"flexible-legend-minimize\")"))
        XCTAssertTrue(page.contains("if legendMinimized {"))
    }
    #endif

    // MARK: - Shape [Curves | Stamp]: a true either/or (img 1, img 4, answer 3)

    /// A pad with its top pressed (10 kg), opened.
    @MainActor
    func padModel() async throws -> (FlexibleStageModel, Int) {
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        let probe = try FlexibleHisProject.padProject(s)
        let top = FlexibleHisProject.topFace(try XCTUnwrap(probe.viewerMesh))
        s.setFace(FlexibleFaceSettings(faceRegionID: top, weightKg: 10, deepestMM: 3))
        let m = try await FlexibleHisProject.openedModel(try FlexibleHisProject.padProject(s), test: self)
        m.selectedRegion = top
        return (m, top)
    }

    @MainActor
    func testShapeIsATrueEitherOr() async throws {
        let (m, top) = try await padModel()
        let curves = try XCTUnwrap(m.settings.face(top))
        XCTAssertEqual(FlexibleStageOverlays.curveAxes(curves), ["x", "y"], "Curves: both curves on the part")
        // Stamp: one stamp lands on the face at once, at the face's weight; the curves go
        m.setShape(top, "stamp")
        let stamp = try XCTUnwrap(m.settings.face(top))
        XCTAssertTrue(stamp.isStampShape)
        let p = try XCTUnwrap(stamp.activeStamp, "Stamp shows the face's ONE stamp")
        XCTAssertEqual(p.weightKg, stamp.weightKg, "the stamp weighs what the face does")
        XCTAssertEqual(FlexibleStageOverlays.curveAxes(stamp), [], "the curves vanish at once")
        XCTAssertEqual(stamp.map.x, .flat)
        XCTAssertEqual(stamp.map.y, .flat)
        // back to Curves: the stamp is kept (a switch back restores it) but never used
        m.setShape(top, "curves")
        let back = try XCTUnwrap(m.settings.face(top))
        XCTAssertNil(back.activeStamp, "Curves never sends a stamp")
        XCTAssertNotNil(back.designStamp, "…kept for a switch back")
        XCTAssertEqual(back.map.x, curves.curveX)
        // the Stamp chip is live; the Stamps tab and check stamps are gone
        let panel = try FlexibleSource.code("FlexibleFacePanel.swift")
        XCTAssertFalse(panel.contains("disabled: [\"stamp\"]"), "Stamp can be pressed")
        XCTAssertTrue(panel.contains("model.setShape(r, v)"))
        XCTAssertTrue(panel.contains("if f.isStampShape { FlexibleFaceStampRows(model: model, region: r, padTarget: $padTarget) }"))
        XCTAssertEqual(FlexibleStageModel.Tab.allCases.map(\.rawValue), ["Face", "More"])
        let root = FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows")
        let flexible = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("Flexible") && $0.hasSuffix(".swift") }
            .map { try FlexibleSource.code($0) }.joined()
        for gone in ["FlexibleStampsPane", "\"flexible-stamp-mode\"", "Check (any stamps)", "Design (one stamp)",
                     "struct FlexibleStampHandles", "tab == .stamps"] {
            XCTAssertFalse(flexible.contains(gone), "removed: \(gone)")
        }
    }

    @MainActor
    func testNoStampHandleIsDrawnUnderThePanel() throws {
        // his project: two check stamps (thumb on face 3, four fingers on face 5), no Stamp face
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf:
            FlexibleHisProject.dir.appendingPathComponent("project.json")))
        let raw = try XCTUnwrap(snap.lattice?.flexible)
        let migrated = FlexibleSettingsMigration.migrated(raw)
        XCTAssertEqual(migrated.checkStamps.count, 0, "check stamps are gone")
        XCTAssertEqual(FlexibleFaceStampHandle.placements(migrated, selected: 3).count, 0, "no Stamp face: no handle")
        // ★ RED CONTROL: round 3's handles (every design stamp + every check stamp) drew two
        let old = raw.faces.compactMap(\.designStamp).count + raw.checkStamps.count
        XCTAssertEqual(old, 2, "control: his two check stamps were two handles (img 6's circles)")
        // one Stamp face: one handle — only the SELECTED face's
        var one = migrated
        var f = try XCTUnwrap(one.face(3))
        f.shape = "stamp"
        f.designStamp = raw.checkStamps[0].stamp
        one.setFace(f)
        XCTAssertEqual(FlexibleFaceStampHandle.placements(one, selected: 3).count, 1)
        XCTAssertEqual(FlexibleFaceStampHandle.placements(one, selected: 5).count, 0, "another face selected: none")
        // the handle keeps out of the panel (and the legend), as the depth chip does
        let panel = CGRect(x: 24, y: 700, width: 400, height: 500)
        let vp = CGSize(width: 1032, height: 1376)
        XCTAssertFalse(FlexibleDepthChipLayout.shows(CGPoint(x: 200, y: 740), dragging: false, keepOut: [panel], viewport: vp))
        XCTAssertTrue(FlexibleDepthChipLayout.shows(CGPoint(x: 700, y: 740), dragging: false, keepOut: [panel], viewport: vp))
        let src = try FlexibleSource.code("FlexibleFaceStamp.swift")
        XCTAssertTrue(src.contains("FlexibleDepthChipLayout.shows(q, dragging: dragging != nil, keepOut: keepOut, viewport: vp)"))
        XCTAssertTrue(src.contains("FillStyle(eoFill: true)"), "the outline is clipped out of the keep-outs")
        let page = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertTrue(page.contains("FlexibleFaceStampHandle(model: model, projection: proj.projection, keepOut: keepOut)"))
    }

    /// The Stamp shape's job: flat curves + its one stamp, at the face's weight. Read back
    /// by CORE's parser. RED CONTROL: the same face under Curves sends its curves and no stamp.
    func testTheStampShapeWritesFlatCurvesAndItsStamp() throws {
        let lib = try FlexibleStampLibrary.load(path: FlexibleStageTests.stampsPath)
        let palm = FlexibleStamps.place(try XCTUnwrap(lib.shape("palm")), uExtentMM: 100, vExtentMM: 100, weightKg: 3)
        let drawn = FlexCurve(x: [0, 0.4, 1], y: [0.2, 1, 0.3])
        func settings(_ shape: String?) -> FlexibleStageSettings {
            var s = FlexibleStageSettings(materialID: "varioshore_tpu", nozzleTempC: 220)
            s.setFace(FlexibleFaceSettings(faceRegionID: 1, weightKg: 12, deepestMM: 4, curveX: drawn, curveY: drawn,
                                           designStamp: palm, shape: shape))
            return s
        }
        let face = try XCTUnwrap(settings("stamp").face(1))
        let st = try XCTUnwrap(face.activeStamp)
        let g = try XCTUnwrap(FlexibleStamps.grid(st, library: lib, uExtentMM: 100, vExtentMM: 100, pitchMM: 2) { _, _ in true })
        let b = try FlexibleCore.parseJobBlock(try FlexibleJob.runJobJSON(FlexibleStageTests.inputs(settings("stamp"), stamps: [st.id: g])))
        let loaded = try XCTUnwrap(b.faces.first { $0.role == "loaded" })
        XCTAssertEqual(loaded.map.x, .flat)
        XCTAssertEqual(loaded.map.y, .flat)
        let ds = try XCTUnwrap(loaded.designStamp, "the one stamp is sent")
        XCTAssertEqual(ds.forceN, 12 * FlexibleUnits.standardGravity, accuracy: 1e-6, "at the face's weight, not the stamp's old 3 kg")
        XCTAssertEqual(loaded.weightN, ds.forceN, accuracy: 1e-6)
        // ★ RED CONTROL: under Curves the drawn curves go, and the stored stamp does not
        let c = try FlexibleCore.parseJobBlock(try FlexibleJob.runJobJSON(FlexibleStageTests.inputs(settings(nil), stamps: [st.id: g])))
        let cl = try XCTUnwrap(c.faces.first { $0.role == "loaded" })
        XCTAssertEqual(cl.map.x, drawn, "control: Curves sends the drawing")
        XCTAssertNil(cl.designStamp, "control: …and never the stored stamp")
    }

    /// A Stamp face's map is the stamp SINKING where it sits (not the whole face), and the
    /// depth prism stands on the stamp's footprint. RED CONTROL: under Curves every column dents.
    @MainActor
    func testTheStampSinksWhereItSitsAndThePrismStandsOnItsFootprint() async throws {
        let (m, top) = try await padModel()
        let key = try XCTUnwrap(m.key(top))
        let st = try XCTUnwrap(m.stacks[key])
        func dented() -> Int {
            let v = FlexibleShownValues(model: m).values[key] ?? []
            return v.filter { if case .depth(let d) = $0 { return d > 1e-6 } else { return false } }.count
        }
        try await FlexibleHisProject.waitFor(30, "the drawn map") { m.liveS[key] != nil }
        let curvesDented = dented()
        m.setShape(top, "stamp")
        try await FlexibleHisProject.waitFor(30, "the stamp's grid") { m.stampFootprint(top) != nil }
        let foot = try XCTUnwrap(m.stampFootprint(top))
        let under = foot.filter { $0 > 0.5 }.count
        let stampDented = dented()
        let shown = FlexibleShownValues(model: m)
        print("FLEX-STAMP pad top: \(st.columns.count) columns · curves dent \(curvesDented) · the stamp dents \(stampDented) (\(under) under it) · deepest shown \(shown.maxDepth) mm")
        XCTAssertGreaterThan(stampDented, 0)
        XCTAssertLessThan(stampDented, st.columns.count / 2, "the stamp sinks where it sits, not the whole face")
        XCTAssertEqual(shown.maxDepth, 3, accuracy: 1e-6, "…by the deepest squish")
        XCTAssertEqual(shown.label, "What you drew")
        XCTAssertGreaterThan(curvesDented, st.columns.count / 2, "control: under Curves the whole face dents")
        // the prism stands on the footprint
        let cols = try XCTUnwrap(m.prismColumns(top))
        XCTAssertEqual(cols.count, under)
        let g = try XCTUnwrap(m.geometry[key])
        let prism = try XCTUnwrap(FlexibleDepthPrism.shell(stack: st, centres: g.centres, depthMM: 3, k: 2, columns: cols))
        let whole = try XCTUnwrap(FlexibleDepthPrism.shell(stack: st, centres: g.centres, depthMM: 3, k: 2))
        let pitch2 = st.pitchMM * st.pitchMM
        XCTAssertEqual(FlexibleDepthPrismTests.area(prism), Double(under) * pitch2, accuracy: pitch2 * 1e-3)
        XCTAssertGreaterThan(FlexibleDepthPrismTests.area(whole), FlexibleDepthPrismTests.area(prism) * 2,
                             "control: the whole face's prism")
    }

    /// Migration (read-through): check stamps go; a face designed under a stamp before round 4
    /// keeps it as its Stamp shape; the finish reads Covered. His project.json decodes.
    @MainActor
    func testTheMigrationDropsCheckStampsAndKeepsADesignStampAsTheShape() throws {
        let data = try Data(contentsOf: FlexibleHisProject.dir.appendingPathComponent("project.json"))
        let raw = try XCTUnwrap(try JSONDecoder().decode(ProjectSnapshot.self, from: data).lattice?.flexible)
        XCTAssertNil(raw.finish, "saved before round 4")
        var s = FlexibleSettingsMigration.migrated(raw)
        XCTAssertEqual(s.checkStamps, [])
        XCTAssertEqual(s.finishMode, .covered)
        XCTAssertEqual(s.finish, "covered", "materialised on the next write")
        // a face designed under ONE stamp before round 4 ("Design (one stamp)") keeps it as its shape
        var f = try XCTUnwrap(s.face(3))
        f.designStamp = raw.checkStamps[0].stamp
        f.shape = nil
        s.setFace(f)
        s.finish = nil
        let again = FlexibleSettingsMigration.migrated(s)
        XCTAssertEqual(again.face(3)?.shape, "stamp")
        XCTAssertEqual(again.face(5)?.shape, nil, "a face without a stamp stays Curves")
        // idempotent
        XCTAssertEqual(FlexibleSettingsMigration.migrated(again), again)
        // ★ RED CONTROL: the same field made NON-optional does not decode his project
        struct Strict: Decodable { let finish: String }
        let flex = try XCTUnwrap(((try JSONSerialization.jsonObject(with: data)) as? [String: Any])
            .flatMap { $0["lattice"] as? [String: Any] }?["flexible"])
        XCTAssertThrowsError(try JSONDecoder().decode(Strict.self, from: JSONSerialization.data(withJSONObject: flex)),
                             "control: a required finish would not decode his project")
    }

    // MARK: - the model-wide Finish (img 5, answer 4)

    func testTheFinishReachesTheJob() throws {
        var s = FlexibleStageTests.settings()
        for (finish, skin) in [(FlexibleFinish.covered, true), (.none, false), (.rim, false), (.skin, false)] {
            s.finish = finish.rawValue
            let b = try FlexibleCore.parseJobBlock(try FlexibleJob.runJobJSON(FlexibleStageTests.inputs(s)))
            XCTAssertTrue(b.faces.allSatisfy { $0.skinOn == skin }, "\(finish): every face's skin_on is \(skin)")
        }
        // ★ RED CONTROL: the per-face switch no longer decides — his face 1 had its skin off
        s.finish = FlexibleFinish.covered.rawValue
        XCTAssertEqual(s.face(FlexibleJob.regionID(face: 1))?.skinOn, false, "control: the old per-face switch said off")
        XCTAssertTrue(try FlexibleCore.parseJobBlock(try FlexibleJob.runJobJSON(FlexibleStageTests.inputs(s)))
            .faces.first { $0.role == "loaded" }!.skinOn, "…and Covered covers it")
        XCTAssertEqual(FlexibleStageSettings().finishMode, .covered, "a new project: Covered, today's default")
    }

    /// The pad's lattice field under each finish. isMaterial: a wall, or the part's body where
    /// the lattice may not be (FlexibleLatticeFieldTests).
    func testTheFinishShapesTheLatticeField() throws {
        func inputs(_ f: FlexibleFinish) throws -> FlexibleLatticeInputs { try Self.padInputs(finish: f) }
        let covered = try inputs(.covered), none = try inputs(.none), rim = try inputs(.rim), skin = try inputs(.skin)
        let mat = FlexibleLatticeFieldTests.isMaterial
        // just under the top face, across its middle
        func gaps(_ f: FlexibleLatticeInputs, z: Float = 19.75) -> Int {
            (0..<400).filter { i in !mat(SIMD3<Float>(20 + Float(i % 20) * 3.1, 20 + Float(i / 20) * 3.1, z), f) }.count
        }
        // along the top edge x = 0 (0.4 mm inside both faces), and down a vertical edge
        func edgeSolid(_ f: FlexibleLatticeInputs) -> Int {
            (0..<60).filter { i in mat(SIMD3<Float>(0.4, 10 + Float(i) * 1.33, 19.6), f) }.count
        }
        let g = (covered: gaps(covered), none: gaps(none), rim: gaps(rim), skin: gaps(skin))
        let e = (covered: edgeSolid(covered), none: edgeSolid(none), rim: edgeSolid(rim), skin: edgeSolid(skin))
        print("FLEX-FINISH gaps under the top (of 400): covered \(g.covered) · none \(g.none) · rim \(g.rim) · skin \(g.skin) | solid along the top edge (of 60): covered \(e.covered) · none \(e.none) · rim \(e.rim) · skin \(e.skin)")
        XCTAssertEqual(g.covered, 0, "Covered: a solid skin everywhere")
        XCTAssertGreaterThan(g.none, 100, "None: the lattice runs to the surface")
        XCTAssertGreaterThan(g.rim, 100, "Rim: the faces are open…")
        XCTAssertEqual(e.rim, 60, "…inside a solid band along every edge")
        XCTAssertLessThan(e.none, 60, "control: with no finish the edge is latticed")
        XCTAssertGreaterThan(g.skin, 0, "Skin: holes through the skin…")
        XCTAssertLessThan(g.skin, g.none / 2, "…a PERFORATED skin, not an open face")
        // a hole centre is open under Skin, closed under Covered (RED control on the same point)
        let hole = FlexibleFinish.holeCentreNear(SIMD2<Float>(50, 50))
        let p = SIMD3<Float>(hole.x, hole.y, 19.7)
        XCTAssertLessThan(FlexibleLatticeField.dSkin(p, skin), 0, "no skin in a hole")
        XCTAssertGreaterThan(FlexibleLatticeField.dSkin(p, covered), 0, "control: Covered has skin there")
        // the model builds with the settings' finish; the panel has the Finish row, not Solid skin
        let model = try FlexibleSource.code("FlexibleStageModel.swift")
        XCTAssertTrue(model.contains("let finish = settings.finishMode"))
        XCTAssertTrue(model.contains("skinOffFaces: [], finish: finish)"))
        let panel = try FlexibleSource.code("FlexibleFacePanel.swift")
        XCTAssertTrue(panel.contains("\"flexible-row-finish\""))
        XCTAssertFalse(panel.contains("flexible-row-skin"), "the per-face Solid skin row is gone")
        XCTAssertFalse(panel.contains("f.skinOn"))
    }

    static func padInputs(finish: FlexibleFinish) throws -> FlexibleLatticeInputs {
        let scene = try FlexibleScene(jobJSON: try FlexibleLatticeFieldTests.padJob(), jobDir: FlexibleLatticeFieldTests.padDir.path)
        let build = FlexBuildParams(topology: "gyroid", beadsPerWall: 1, beadWidthMM: 0.42)
        let map = FlexMap(mode: "both", x: FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]),
                          y: FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]), centreEdge: .flat, deepestMM: 2)
        _ = try scene.design(materialsPath: FlexibleStageTests.materialsPath, materialID: "varioshore_tpu",
                             tempC: 220, face: 101, rotation: 0, map: map, weightN: 294.3, stamp: nil, build: build)
        let field = try scene.densityField(faces: [101], rotations: [0], build: build)
        let m = try TopOptKit.importMesh(path: FlexibleStageTests.padSTL)
        let part = ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs, pseudoFaces: true)
        return try FlexibleLatticeBuilder.inputs(field: field, part: part, topology: "gyroid", beadsPerWall: 1,
                                                 beadWidthMM: 0.42, buildDir: SIMD3(0, 0, 1), skinOffFaces: [],
                                                 finish: finish)
    }

    #if canImport(AppKit)
    @MainActor
    func testTheFinishRowFitsThePanel() {
        let content: CGFloat = 400 - 2 * DS.Space.ml
        let w = FlexibleRowCopyTests.width(FlexRow(FlexibleRowCopy.finish, info: "") {
            FlexChips(options: FlexibleRowCopy.finishOptions, selection: "covered", equalWidths: false) { _ in }.fixedSize()
        })
        print("FLEX-FINISH row \(Int(w)) pt of \(Int(content))")
        XCTAssertLessThanOrEqual(w, content)
        XCTAssertEqual(FlexibleRowCopy.finishOptions.map(\.label), ["None", "Rim", "Skin", "Covered"])
    }
    #endif

    // MARK: - no lattice on the Settings page (img 6)

    @MainActor
    func testTheSettingsPageDrawsNoLattice() throws {
        let page = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertTrue(page.contains("flexibleLattice: nil)"), "the Settings page hands the renderer no lattice")
        XCTAssertFalse(page.contains("FlexibleLatticePreview.inputs("), "…never builds one")
        XCTAssertFalse(page.contains("FlexibleLatticePreview.drawn("), "…and never reads the map from one")
        XCTAssertFalse(page.contains("rendererLoops"), "the page's own ticker steps his drawing")
        // with a lattice on the main page, the Settings page's map is still HIS drawing
        let p = try FlexibleSquishTests.pad()
        let face = FlexibleFaceSettings(faceRegionID: 101, weightKg: 30, deepestMM: 3)
        let inp = FlexibleShownValues.Inputs(loadedFaces: [face], stacks: [p.key: p.stack], designs: [p.key: p.design],
                                             liveS: [:], checks: [:], checkStamps: [], checkStampShown: nil, showBuildable: false)
        XCTAssertEqual(FlexibleShownValues(inp, drawnLattice: nil).label, "What you drew")
        // ★ RED CONTROL: a lattice drawn on the page took the map over (img 6's legend)
        let depths = FlexibleSquishFace.buildableDepths(stack: p.stack, design: p.design)
        let g = FlexibleSquishTests.generated(faces: [FlexibleSquishFace(stack: p.stack, depthsMM: depths)], keys: [p.key],
                                              depths: [p.key: depths], noLattice: [p.key: p.design.columns.map { $0.status == "no_lattice" }],
                                              extentMM: 100)
        XCTAssertEqual(FlexibleShownValues(inp, drawnLattice: g).label, "What the lattice was built from",
                       "control: a drawn lattice owns the map")
    }

    // MARK: - the depth prism and chip in the lattice stage's face-prism purple (img 2)

    @MainActor
    func testTheDepthPrismAndChipAreTheLatticeStagesFacePrismPurple() async throws {
        // the lattice stage's own face-prism colour, read from #354's source (one colour)
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        let line = try XCTUnwrap(ws.components(separatedBy: "\n").first { $0.contains("case .include: return SIMD3<Float>(") })
        let args = try XCTUnwrap(line.components(separatedBy: "SIMD3<Float>(").last)
        let nums = args.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .compactMap(Double.init).filter { $0 != 255 }
        XCTAssertEqual(nums.count, 3, line)
        let lattice = SIMD3<Float>(Float(nums[0] / 255), Float(nums[1] / 255), Float(nums[2] / 255))
        XCTAssertEqual(FlexibleStageStyle.facePrismTint, lattice, "the Settings prism IS the lattice stage's face prism")
        XCTAssertEqual(FlexibleStageStyle.facePrismKnob, LatticeDensityProxy.densityColor(fraction: 0.6), "the chip: the depth knob's glass")
        // the page's prism is drawn in it
        let (m, top) = try await padModel()
        m.selectedRegion = top
        m.frozenExaggeration = 2
        let item = try XCTUnwrap(FlexibleDepthPrism.renderItems(model: m, k: 2).first)
        m.frozenExaggeration = nil
        XCTAssertEqual(item.tint, lattice)
        let chips = try FlexibleSource.code("FlexibleDepthChips.swift")
        XCTAssertTrue(chips.contains("LiquidGlass.Tint.frost(FlexibleStageStyle.facePrismKnob"))
        // ★ RED CONTROL: batch A's on-part white is not the purple
        let white = FlexibleStageStyle.onPartToken
        XCTAssertNotEqual(SIMD3<Float>(Float(white.r), Float(white.g), Float(white.b)), lattice, "control")
        // ★ AND ONE PURPLE FOR EVERY FACE PRISM: batch C's never-violet hook on the main page is reverted
        XCTAssertFalse(ws.contains("FlexibleMainTints.depthPlane"), "the main page's depth prism keeps the lattice purple")
        XCTAssertFalse(ws.contains("FlexibleMainTints.knob("), "…and so do its knobs")
        XCTAssertTrue(ws.contains("LatticeDensityProxy.densityColor(fraction: 0.6),"), "#354's knob line is its own again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: FlexibleSource.url("FlexibleDepthAccent.swift").path))
    }

    // MARK: - Auto and Physics open inline behind a caret (img 7)

    #if canImport(AppKit)
    @MainActor
    func testAutoAndPhysicsAreDisclosureCarets() throws {
        let offered = CGSize(width: 368, height: 2000)
        let detail = Color.red.frame(height: 200)
        let closed = Self.height(FlexDisclosureRow("Physics · 1-bead walls", id: "t") { detail }, proposed: offered)
        let open = Self.height(FlexDisclosureRow("Physics · 1-bead walls", id: "t", initiallyOpen: true) { detail }, proposed: offered)
        print("FLEX-CARET closed \(closed) pt · open \(open) pt")
        XCTAssertLessThan(closed, 60, "closed: the title line")
        XCTAssertGreaterThan(open, closed + 150, "a tap opens the details BELOW the title")
        // ★ RED CONTROL: round 3's row kept the details in an (i) popover — the row never grew
        let old = Self.height(FlexRow("Physics · 1-bead walls", info: "…") { EmptyView() } extra: { detail }, proposed: offered)
        XCTAssertEqual(old, closed, accuracy: 12, "control: the (i) row stays one line")
        let more = try FlexibleSource.code("FlexibleFacePanel.swift")
        XCTAssertTrue(more.contains("FlexDisclosureRow(auto.text, id: \"flexible-row-auto\", warning: auto.warning)"))
        XCTAssertTrue(more.contains("FlexDisclosureRow(FlexibleRowCopy.physics, id: \"flexible-row-physics\")"))
        let row = try FlexibleSource.code("FlexibleDisclosure.swift")
        XCTAssertTrue(row.contains("Image(systemName: \"chevron.down\")"), "a caret that says it opens down")
        XCTAssertTrue(row.contains(".rotationEffect(.degrees(open ? 180 : 0))"))
    }
    #endif
}
