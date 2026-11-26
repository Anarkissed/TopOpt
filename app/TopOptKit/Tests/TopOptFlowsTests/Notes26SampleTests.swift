// Notes26SampleTests — ★ his iPad notes 2026-11-23 evening (notes26): "We still don't have skin in the sample yet?", "do the
// same to the regular lattices so it's live changes rather than a block that sometimes changes", then "I meant that the sample
// was live rather than a saved asset ... (with a few seconds of buffering as needed - but obviously the less the better)". He
// saw today's 5 × 5 × 5 stand-in block beside Organic's live sample: "Yes to the live sample".
//   S1 a strut type's sample is laid live from the open group's settings — finish (Skin), band, grade, cell, type — in the bare
//      sample body, drawn inside the see-through body; it rebuilds after a change within the sample's beat; an unchanged group
//      shows its kept sample at once; the "Not in the sample yet" line is gone (nothing at the bottom-centre).
//   S2 Organic's "Depth variation" says ONE line (his yes): its five-word caption.
// His two iPad sizes: 13″ landscape and 11″ portrait.
import XCTest
import SwiftUI
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private let sizes: [(String, CGSize)] = [("13L", AppBuildHost.landscape13), ("11P", CGSize(width: 820, height: 1180))]

/// The page's settings for a Structural (or Aesthetic) octet part with `finish`, graded by stress and shape (the default),
/// Grade 30 → 15 %.
private func octet(_ finish: LatticeBoundaryTreatment, grading: LatticeGradingMode = .full, aesthetic: Bool = false) -> LatticeSettings {
    var l = LatticeSettings(enabled: true)
    l.flexible = nil
    l.chooseLatticeType(aesthetic ? .aesthetic : .structural)
    l.topologyID = "octet"
    l.boundary = finish
    l.gradingMode = grading
    l.maxRelativeDensity = 0.3; l.minRelativeDensity = 0.15
    return l
}

/// Skin bars (core's flag 2), and how many of them lie on a face of the body's box (both ends within 0.6 mm of it).
private func skinBars(_ m: LatticeSampleLay.Made) -> (all: Int, onFace: Int) {
    var all = 0, onFace = 0
    for i in 0..<(m.bars.count / 7) where i < m.flags.count && LatticeLayoutColours.isSkin(m.flags[i]) {
        all += 1
        let a = SIMD3(m.bars[7 * i], m.bars[7 * i + 1], m.bars[7 * i + 2])
        let b = SIMD3(m.bars[7 * i + 3], m.bars[7 * i + 4], m.bars[7 * i + 5])
        for ax in 0..<3 where (abs(a[ax] - m.body.lo[ax]) < 0.6 && abs(b[ax] - m.body.lo[ax]) < 0.6)
            || (abs(a[ax] - m.body.hi[ax]) < 0.6 && abs(b[ax] - m.body.hi[ax]) < 0.6) {
            onFace += 1; break
        }
    }
    return (all, onFace)
}

// MARK: - S1, the lay

final class Notes26SampleLayTests: XCTestCase {

    /// ★ The sample's lay receives the page's finish and band: Skin on lays skin bars across the cube's faces; Stress + shape
    /// sends the band (grade to shape, its width and strength) to the lay. RED CONTROLS: Finish None lays no skin bar; Grade by
    /// stress alone sends no band.
    @MainActor
    func testTheSampleLaysTheFinishAndTheBand() async throws {
        let skinPlan = LatticeSampleLay.page(octet(.fullSkin), lineWidthMM: 0.45, wallRingMM: 0.9)
        XCTAssertTrue(skinPlan.settings.skin, "★ Finish Skin reaches the sample's lay")
        XCTAssertTrue(skinPlan.band, "★ the band reaches it (Stress + shape)")
        let sent = skinPlan.settings(box: (SIMD3(0, 0, 0), SIMD3(40, 40, 40)))
        XCTAssertTrue(sent.gradeToShape && sent.skin && sent.allLattice, "★ laid: Skin, the band, the whole sample latticed")
        XCTAssertEqual(sent.bandMM, octet(.fullSkin).shapeFitBandMM, "★ the band's width is the page's")
        XCTAssertEqual(sent.minCellsAcross, 1, "the sample's walls are a stand-in (his walls' rule is his part's)")
        XCTAssertTrue(skinPlan.madeUpStress, "graded by stress: the sample's made-up stress")
        let skin = try await LatticeSampleLay.lay(skinPlan, cube: true)
        let s = skinBars(skin)
        XCTAssertGreaterThan(s.all, 50, "★ Skin on: skin bars")
        XCTAssertGreaterThan(Double(s.onFace), 0.95 * Double(s.all), "★ on the cube's faces (\(s.onFace) of \(s.all))")
        let caption = LatticeSampleLay.caption(skin, typeName: "Octet truss", cube: true, finish: skinPlan.finishWord, band: skinPlan.band)
        XCTAssertTrue(caption.hasPrefix("40 mm cube · Octet truss · cells "), caption)
        XCTAssertTrue(caption.contains(" · Skin · shape band · built by the engine"), "★ the line says what is drawn: \(caption)")
        // RED CONTROL: Finish None — no skin bar
        let nonePlan = LatticeSampleLay.page(octet(.none), lineWidthMM: 0.45, wallRingMM: 0.9)
        XCTAssertFalse(nonePlan.settings.skin)
        let none = try await LatticeSampleLay.lay(nonePlan, cube: true)
        XCTAssertGreaterThan(none.struts, 100, "premise: a lattice")
        XCTAssertEqual(skinBars(none).all, 0, "RED CONTROL: Finish None lays no skin bar")
        XCTAssertFalse(LatticeSampleLay.caption(none, typeName: "Octet truss", cube: true, finish: nonePlan.finishWord,
                                                band: nonePlan.band).contains("Skin"))
        // RED CONTROL: Grade by stress alone — no band sent
        let noBand = LatticeSampleLay.page(octet(.none, grading: .stressOnly), lineWidthMM: 0.45, wallRingMM: 0.9)
        XCTAssertFalse(noBand.band)
        XCTAssertFalse(noBand.settings(box: (SIMD3(0, 0, 0), SIMD3(40, 40, 40))).gradeToShape, "RED CONTROL: no band")
    }

    /// ★ The grade: where his part grades by stress, the sample grades by its made-up stress (rising along it), so its struts
    /// run from heavier to lighter and the line says both ends, from → to. RED CONTROL: "Grade the lattice" off — one density.
    @MainActor
    func testTheGradeIsInTheSample() async throws {
        var l = octet(.fullSkin, aesthetic: true)
        l.algorithm = "stepped"
        let plan = LatticeSampleLay.page(l, lineWidthMM: 0.45, wallRingMM: 0.9)
        XCTAssertTrue(plan.madeUpStress)
        let graded = try await LatticeSampleLay.lay(plan, cube: true)
        XCTAssertGreaterThan(graded.rhoHi, graded.rhoLo + 0.01, "★ graded: \(graded.rhoLo) → \(graded.rhoHi)")
        let caption = LatticeSampleLay.caption(graded, typeName: "Octet truss", cube: true, finish: plan.finishWord, band: plan.band)
        // ★ notes29: the Density percent the page speaks (100 % = the type's own quilt), never over 100 (it said the law's
        // density, "density 107 → 10 %" on his BCC + Z)
        XCTAssertGreaterThan(graded.pctHi, graded.pctLo, "★ graded: \(graded.pctLo) → \(graded.pctHi) %")
        XCTAssertTrue(caption.contains("density \(Int(graded.pctHi.rounded())) → \(Int(graded.pctLo.rounded())) %"),
                      "★ from → to, as the page says it: \(caption)")
        l.gradingMode = LatticeGradingMode.none
        let flatPlan = LatticeSampleLay.page(l, lineWidthMM: 0.45, wallRingMM: 0.9)
        XCTAssertFalse(flatPlan.madeUpStress)
        let flat = try await LatticeSampleLay.lay(flatPlan, cube: true)
        XCTAssertEqual(flat.rhoLo, flat.rhoHi, accuracy: 1e-6, "RED CONTROL: not graded, one density")
        XCTAssertNotEqual(LatticeSampleLay.caption(flat, typeName: "Octet truss", cube: true, finish: nil, band: false)
                            .contains("→"), true, "RED CONTROL: one density said")
    }

    /// ★ An area's tab: its own Finish is the sample's (Skin on Back Wall over a part on None), through the part's own rule
    /// (`areaOwn`). RED CONTROL: the Part tab of the same page has none.
    @MainActor
    func testAnAreasOwnFinishIsItsSamples() async throws {
        let gid = UUID()
        var own = LatticeAreaGrading()
        own.outerFinish = "none"; own.skin = "diagrid"   // the zone's Skin (LatticeAreaGrading.ZoneFinish.skin.words)
        let plan = LatticeSampleLay.page(octet(.covered), area: gid, own: own, lineWidthMM: 0.45, wallRingMM: 0.9)
        XCTAssertEqual(plan.area?.finish.skin, true, "★ the area's own Skin")
        XCTAssertEqual(plan.finishWord, "Skin")
        let made = try await LatticeSampleLay.lay(plan, cube: true)
        XCTAssertGreaterThan(skinBars(made).onFace, 50, "★ the area's Skin on the sample's faces")
        let part = LatticeSampleLay.page(octet(.covered), lineWidthMM: 0.45, wallRingMM: 0.9)
        XCTAssertEqual(part.finishWord, "Covered", "control: the Part tab is the part's Covered")
        XCTAssertNotEqual(plan, part, "★ a group's sample is its own")
    }

    /// The sample part (In a part) is laid the same way, in core's sample part body.
    @MainActor
    func testInAPartIsTheSamplePartLaidTheSameWay() async throws {
        let plan = LatticeSampleLay.page(octet(.fullSkin), lineWidthMM: 0.45, wallRingMM: 0.9)
        let part = try await LatticeSampleLay.lay(plan, cube: false)
        XCTAssertGreaterThan(skinBars(part).all, 50, "★ Skin in the sample part too")
        let caption = LatticeSampleLay.caption(part, typeName: "Octet truss", cube: false, finish: plan.finishWord, band: plan.band)
        XCTAssertTrue(caption.hasPrefix("Sample part · 45 × 40 × 35 mm · Octet truss · "), caption)
    }
}

#if canImport(AppKit) && canImport(MetalKit)

// MARK: - S1, the view (hosted)

@MainActor
final class Notes26SampleHostedTests: XCTestCase {
    final class Switch: ObservableObject {
        @Published var inputs: LatticeSampleView.Inputs
        @Published var key: LatticeSampleKeep.Key?
        init(_ i: LatticeSampleView.Inputs, _ k: LatticeSampleKeep.Key?) { inputs = i; key = k }
    }
    struct Page: View {
        @ObservedObject var s: Switch
        var body: some View { LatticeSampleView(inputs: s.inputs).kept(s.key) }
    }
    final class Probe { var all: [String: CGRect] = [:] }

    override nonisolated func setUp() { super.setUp(); FlexibleSaid.recording = true }
    override nonisolated func tearDown() { FlexibleSaid.recording = false; super.tearDown() }

    private func inputs(_ finish: LatticeBoundaryTreatment, cell: Double = 8) -> LatticeSampleView.Inputs {
        var l = octet(finish)
        l.cellSizeMode = .fixed; l.cellMM = cell
        var i = LatticeSampleView.Inputs(shape: .cells, topology: "octet", typeName: "Octet truss", cellMM: cell, beadMM: 0.45,
                                         rhoLo: 0.15, rhoHi: 0.3)
        i.lay = LatticeSampleLay.page(l, lineWidthMM: 0.45, wallRingMM: 0.9)
        return i
    }

    /// Pump until `n` builds since `b0` and the caption says the sample is built (≤ 90 s).
    private func built(_ h: AppBuildHost, _ b0: Int, _ n: Int, _ what: String) {
        let end = Date().addingTimeInterval(90)
        while Date() < end, LatticeSampleBuilder.shared.builds - b0 < n
                || !(LatticeSampleView.recordedCaptions.last ?? "").hasSuffix("built by the engine") { h.pump(0.05) }
        XCTAssertEqual(LatticeSampleBuilder.shared.builds - b0, n, "\(what): builds")
    }

    /// ★ A setting changed rebuilds the sample within its beat and a short lay: Skin turned on is in the sample in well under
    /// "a few seconds" (his "the less the better"). A burst of changes inside the beat builds once, the newest.
    func testASettingChangeRebuildsWithinTheBeat() throws {
        for (name, size) in sizes {
            LatticeSampleKeep.shared.forget()
            LatticeSampleView.recordedCaptions = []; LatticeSampleView.recordedLaid = []
            let s = Switch(inputs(.none), nil)
            let b0 = LatticeSampleBuilder.shared.builds
            let h = AppBuildHost(Page(s: s), size: size, test: self)
            built(h, b0, 1, "\(name): the first sample")
            XCTAssertFalse((LatticeSampleView.recordedCaptions.last ?? "").contains("Skin"), "\(name): premise: no Skin")
            let t0 = Date()
            s.inputs = inputs(.fullSkin)
            built(h, b0, 2, "★ \(name): Skin on rebuilds")
            let took = Date().timeIntervalSince(t0)
            print("NOTES26 SAMPLE \(name): Skin on → in the sample in \(String(format: "%.2f", took)) s")
            XCTAssertLessThan(took, 3, "★ \(name): within a few seconds at most (\(took) s)")
            XCTAssertTrue((LatticeSampleView.recordedCaptions.last ?? "").contains(" · Skin · "), "★ \(name): the line says Skin")
            XCTAssertGreaterThan(skinBars(try XCTUnwrap(LatticeSampleView.recordedLaid.last)).onFace, 50, "★ \(name): its bars")
            // a burst inside the beat (a drag): one build, the newest
            s.inputs = inputs(.fullSkin, cell: 7); h.pump(0.02)
            s.inputs = inputs(.fullSkin, cell: 6.5); h.pump(0.02)
            s.inputs = inputs(.fullSkin, cell: 6)
            built(h, b0, 3, "★ \(name): a burst builds once")
            XCTAssertTrue((LatticeSampleView.recordedCaptions.last ?? "").contains(" 6 mm"),
                          "★ \(name): the newest: \(LatticeSampleView.recordedCaptions.last ?? "")")
        }
    }

    /// ★ D7's rule holds for the laid sample: back on a group whose settings are unchanged, its kept sample shows at once, no
    /// build. RED CONTROL: a change on that group builds.
    func testAnUnchangedGroupSwitchDoesNotRebuild() throws {
        for (name, size) in sizes {
            LatticeSampleKeep.shared.forget()
            LatticeSampleView.recordedCaptions = []; LatticeSampleView.recordedKept = 0
            let project = UUID()
            let part = LatticeSampleKeep.Key(project: project, group: "part"), wall = LatticeSampleKeep.Key(project: project, group: "area-0")
            let s = Switch(inputs(.fullSkin), part)
            let b0 = LatticeSampleBuilder.shared.builds
            let h = AppBuildHost(Page(s: s), size: size, test: self)
            built(h, b0, 1, "\(name): Part's sample")
            let partCaption = try XCTUnwrap(LatticeSampleView.recordedCaptions.last)
            s.inputs = inputs(.none, cell: 6); s.key = wall
            built(h, b0, 2, "\(name): Back Wall's sample")
            s.inputs = inputs(.fullSkin); s.key = part
            h.pump(1.5)
            XCTAssertEqual(LatticeSampleBuilder.shared.builds - b0, 2, "★ \(name): no build for an unchanged group")
            XCTAssertEqual(LatticeSampleView.recordedKept, 1, "★ \(name): its kept sample, at once")
            XCTAssertEqual(LatticeSampleView.recordedCaptions.last, partCaption, "★ \(name): as it was built (its Skin)")
            s.inputs = inputs(.none)
            built(h, b0, 3, "RED CONTROL \(name): a change on Part builds")
            LatticeSampleKeep.shared.forget()
        }
    }

    /// ★ IN THE REAL PAGE, both of his sizes: the A1 pad on Skin — the page's sample is laid with his Skin (its lay carries it,
    /// its bars are on the cube's faces, its line says so), and nothing but that line is at the sample's foot (the "Not in the
    /// sample yet" line is gone). In a part is laid the same way.
    func testThePagesSampleCarriesHisSkinAndNothingSitsAtTheFoot() throws {
        for (name, size) in sizes {
            LatticeSampleKeep.shared.forget()
            LatticeSampleView.recordedAsks = []; LatticeSampleView.recordedCaptions = []; LatticeSampleView.recordedLaid = []
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: true)
            let p = r.project
            p.lattice.flexible = nil
            p.lattice.clearLatticeType()
            p.lattice.chooseLatticeType(.structural)
            p.lattice.boundary = .fullSkin
            if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
            let pr = Probe()
            let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p).onPreferenceChange(LatticeProbeKey.self) { pr.all = $0 },
                                 size: size, test: self)
            h.pump(3)
            func seen(_ id: String) -> CGRect? { (pr.all[id] ?? h.frames.all[id]).flatMap { $0.width > 1 ? $0 : nil } }
            try h.pickFromMenu("capsuleMenu", "Structural", what: "\(name): the stage menu")
            try h.tap("capsuleSetup", "\(name): Setup, the settings", settle: 1.5)
            if seen("lattice-sample-cells") == nil, let cells = seen("wizard-stage-\(LatticeWizardStage.cell.rawValue)") {
                h.click(CGPoint(x: cells.midX, y: cells.midY), settle: 1)
            }
            let end = Date().addingTimeInterval(120)
            while Date() < end, !LatticeSampleView.recordedCaptions.contains(where: { $0.hasSuffix("built by the engine") }) { h.pump(0.5) }
            h.pump(0.5)
            let ask = try XCTUnwrap(LatticeSampleView.recordedAsks.last?.lay, "★ \(name): the page's sample is laid from its settings")
            XCTAssertTrue(ask.settings.skin, "★ \(name): his Skin reaches the sample's lay")
            let laid = try XCTUnwrap(LatticeSampleView.recordedLaid.last, "\(name): laid")
            XCTAssertGreaterThan(skinBars(laid).onFace, 50, "★ \(name): Skin's bars on the sample's faces")
            let caption = LatticeSampleView.recordedCaptions.last ?? ""
            XCTAssertTrue(caption.hasPrefix("40 mm cube · Octet truss") && caption.contains(" · Skin"), "★ \(name): \(caption)")
            XCTAssertNil(seen("lattice-sample-not-shown"), "★ \(name): no \"Not in the sample yet\" line")
            XCTAssertNil(h.frames.all["info-lattice-sample-not-drawn"], "\(name): Skin is drawn: no (i)")
            let line = try XCTUnwrap(seen("lattice-sample-caption"), "\(name): the sample's line")
            XCTAssertLessThan(line.width, size.width - 2 * DS.Space.l, "\(name): a line on the sample, never across the screen")
            // In a part: the sample part, laid the same way
            if let part = seen("wizard-stage-\(LatticeWizardStage.lattice.rawValue)") { h.click(CGPoint(x: part.midX, y: part.midY), settle: 1) }
            let end2 = Date().addingTimeInterval(120)
            while Date() < end2, !(LatticeSampleView.recordedCaptions.last ?? "").hasPrefix("Sample part") { h.pump(0.5) }
            h.pump(0.5)
            XCTAssertNotNil(seen("lattice-sample-part"), "\(name): In a part")
            XCTAssertTrue((LatticeSampleView.recordedCaptions.last ?? "").hasPrefix("Sample part · 45 × 40 × 35 mm · Octet truss"),
                          "★ \(name): In a part is the sample part, laid: \(LatticeSampleView.recordedCaptions.last ?? "")")
            XCTAssertGreaterThan(skinBars(try XCTUnwrap(LatticeSampleView.recordedLaid.last)).all, 50, "★ \(name): with his Skin")
            XCTAssertNil(seen("lattice-sample-not-shown"))
        }
    }

    /// ★ What the see-through sample truly can't draw (Rim's solid) is said in an (i) beside the Cells │ In a part switch, its
    /// own 44 pt target, up with the switch — never a line at the sample's foot.
    func testRimsSolidIsSaidInAnInfoBesideTheSwitch() throws {
        XCTAssertNotNil(LatticeSampleLay.notDrawn(LatticeSampleLay.page(octet(.rim), lineWidthMM: 0.45, wallRingMM: 0.9)))
        XCTAssertNotNil(LatticeSampleLay.notDrawn(LatticeSampleLay.page(octet(.covered), lineWidthMM: 0.45, wallRingMM: 0.9)))
        XCTAssertNil(LatticeSampleLay.notDrawn(LatticeSampleLay.page(octet(.fullSkin), lineWidthMM: 0.45, wallRingMM: 0.9)),
                     "control: Skin is drawn")
        XCTAssertNil(LatticeSampleLay.notDrawn(LatticeSampleLay.page(octet(.none), lineWidthMM: 0.45, wallRingMM: 0.9)))
        for (name, size) in sizes {
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: true)
            let p = r.project
            p.lattice.flexible = nil
            p.lattice.clearLatticeType()
            p.lattice.chooseLatticeType(.structural)
            p.lattice.boundary = .rim
            if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
            let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
            h.pump(3)
            try h.pickFromMenu("capsuleMenu", "Structural", what: "\(name): the stage menu")
            try h.tap("capsuleSetup", "\(name): Setup, the settings", settle: 1.5)
            let info = try h.probe("info-lattice-sample-not-drawn", "★ \(name): the sample's (i)")
            let sw = try XCTUnwrap(h.frames.all["latticeViewSwitch"], "\(name): the switch")
            XCTAssertEqual(info.midY, sw.midY, accuracy: 6, "★ \(name): beside the switch")
            XCTAssertGreaterThan(info.minX, sw.maxX - 0.5, "★ \(name): after it, never over it")
            // (notes29: the equal type cards, his 11-25, bring the Structural panel to its portrait cap of 62 % of the height;
            // the switch row then sits just under it, at most ~79.5 % on the 11″ — still well above the foot)
            XCTAssertLessThan(info.maxY, size.height * 0.8, "★ \(name): up with the switch, never at the foot")
            XCTAssertLessThan(info.maxX, size.width, "\(name): on screen")
        }
    }
}
#endif

// MARK: - S2

final class Notes26DepthLineTests: XCTestCase {
    /// ★ his yes (11-23): Depth variation said "Up to 1 mm out." twice with it on (its grey caption, and "Up to 1 mm out at
    /// open faces" under it). ONE line now, as Extra spacing's (D6): the caption, five words (his rule); the open faces are in
    /// its (i). RED CONTROL: the second line is not in the controls' source at all.
    func testDepthVariationSaysOneLine() throws {
        let src = try FlexibleSource.code("LatticeOrganicControls.swift")
        XCTAssertFalse(src.contains("Up to 1 mm out"), "★ no second line in the controls")
        XCTAssertFalse(src.contains("Cut flush at every face"))
        XCTAssertTrue(src.contains("row(\"Depth variation\") {"), "the setting is still there, with its caption")
        let help = try XCTUnwrap(OrganicSettingsHelp.entry("Depth variation"))
        XCTAssertEqual(help.grey, "Up to 1 mm out.", "★ the one line")
        XCTAssertLessThanOrEqual(help.grey.split(separator: " ").count, 5, "his five-word rule")
        XCTAssertTrue(help.info.contains("open face"), "the open faces, in its (i)")
    }
}
