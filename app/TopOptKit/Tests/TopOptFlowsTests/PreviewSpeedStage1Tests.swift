// PreviewSpeedStage1Tests — ★ his picks 2026-11-21 on the preview-speed research ("It's embarrassing how slow it is"):
// "Show something at once ... Let's do this one. Absolutely." (the last lattice dimmed with a ring and a count-down on the
// Lattice button; a marked Draft first, then the exact lattice replaces it) and "Remember finished results ... absolutely"
// (going back to settings already laid shows that lattice at once). Stage 1 is the app's alone: the engine is unchanged.
// ★ His ask the same night: "make it work like the other tools - with an option to have 'print accurate rendering'. Let this
// override my rule that the drawing follows the print file": Print-accurate preview off (the default) shows the quick Draft
// alone; the exact lattice is made with the print file.
import XCTest
import Combine
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class PreviewSpeedStage1Tests: XCTestCase {

    private var accurateBefore = false
    override func setUp() { super.setUp(); accurateBefore = AppSettings.shared.latticePrintAccurate }

    override func tearDown() {
        AppSettings.shared.latticePrintAccurate = accurateBefore
        LatticeLayoutPreview.controlNoDraftFirst = false
        LatticeLayoutPreview.controlForget = false
        super.tearDown()
    }

    /// The button's words: five at most with the time, the time counted down, the ring never closed before the end.
    func testTheButtonSaysWhatIsLayingInFiveWords() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let draft = LatticeLayoutPreview.LayProgress(quality: .draft, started: t0, expectedS: 40, draftShown: false)
        let exact = LatticeLayoutPreview.LayProgress(quality: .exact, started: t0, expectedS: 200, draftShown: true)
        let alone = LatticeLayoutPreview.LayProgress(quality: .exact, started: t0, expectedS: nil, draftShown: false)
        let pd = LatticePreviewMode.buttonProgress(draft), pe = LatticePreviewMode.buttonProgress(exact)
        let pa = LatticePreviewMode.buttonProgress(alone)
        XCTAssertEqual(pd.line(at: t0.addingTimeInterval(28)), "Laying Draft \u{00B7} 12 s")
        XCTAssertEqual(pe.line(at: t0.addingTimeInterval(20)), "Draft \u{00B7} checking print \u{00B7} 3 min", "★ the Draft is marked")
        XCTAssertEqual(pa.line(at: t0), "Laying the lattice", "nothing says how long: no time, a spinner")
        XCTAssertNil(pa.fraction(at: t0))
        XCTAssertEqual(pe.line(at: t0.addingTimeInterval(250)), "Draft \u{00B7} checking print \u{00B7} finishing", "past the guess")
        XCTAssertEqual(pd.fraction(at: t0.addingTimeInterval(20)) ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(pd.fraction(at: t0.addingTimeInterval(400)), 0.95, "★ never full before it lands")
        for p in [pd, pe, pa] {
            for dt in [0.0, 5, 100, 1000] {
                let words = p.line(at: t0.addingTimeInterval(dt)).split(separator: " ").filter { $0 != "\u{00B7}" }
                XCTAssertLessThanOrEqual(words.count, 5, "★ five words at most: \(p.line(at: t0.addingTimeInterval(dt)))")
            }
        }
    }

    /// ★ The switch: its words in the ⌃ menu, and off by default (the quick Draft, as the other tools' stand-ins).
    func testPrintAccuratePreviewIsASwitchOffByDefault() throws {
        XCTAssertEqual(LatticePreviewMode.printAccurate, "Print-accurate preview")
        let d = try XCTUnwrap(UserDefaults(suiteName: "PreviewSpeedStage1Tests-\(UUID().uuidString)"))
        XCTAssertFalse(AppSettings(defaults: d).latticePrintAccurate, "★ off by default: the quick Draft")
        let a = AppSettings(defaults: d)
        a.latticePrintAccurate = true
        XCTAssertTrue(AppSettings(defaults: d).latticePrintAccurate, "kept")
    }

    /// ★ Print-accurate preview OFF: the Draft alone is the preview (no print check while editing); the print file asks the
    /// exact lattice, laid after the Draft on screen with no second Draft. RED CONTROL: switched on, a Draft is not current.
    func testTheQuickDraftStandsInUntilThePrintFileAsks() async throws {
        AppSettings.shared.latticePrintAccurate = false
        let p = try organicProject()
        let st = try stress(p, key: 43)
        let preview = LatticeLayoutPreview()
        var seen: [LatticeLayoutPreview.LayProgress] = []
        let sub = preview.$layProgress.sink { if let v = $0 { seen.append(v) } }
        defer { sub.cancel() }
        let t0 = Date()
        preview.update(project: p, on: true, stress: st)
        XCTAssertEqual(preview.layProgress?.quality, .draft)
        XCTAssertFalse(preview.layingExact)
        try await settle(preview, "the quick Draft")
        print("STAGE1: quick Draft \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        XCTAssertEqual(preview.organicQuality, .draft, "★ the quick Draft is the preview")
        XCTAssertFalse(seen.contains { $0.quality == .exact }, "★ no print check while editing")
        XCTAssertTrue(preview.isCurrent(project: p, stress: st), "the Draft is current: no Refresh Lattice")
        do { _ = try await preview.organicFileInputs(project: p, stress: st); XCTFail("a Draft is not the print file") }
        catch let w as LatticeLayoutPreview.OrganicFileWait { XCTAssertEqual(w, .notLaid, "★ the print file asks the exact lattice") }
        seen = []
        let t1 = Date()
        preview.update(project: p, on: true, stress: st, exact: true)
        XCTAssertEqual(preview.layProgress?.quality, .exact, "★ straight to the exact lattice")
        XCTAssertEqual(preview.layProgress?.draftShown, true, "the Draft on screen stays, not dimmed")
        XCTAssertTrue(preview.layingExact)
        try await settle(preview, "the exact lattice for the file")
        print("STAGE1: exact after the Draft \(String(format: "%.1f", Date().timeIntervalSince(t1))) s")
        XCTAssertEqual(preview.organicQuality, .exact)
        XCTAssertFalse(seen.contains { $0.quality == .draft }, "★ no second Draft")
        _ = try await preview.organicFileInputs(project: p, stress: st)
        AppSettings.shared.latticePrintAccurate = true
        XCTAssertTrue(preview.isCurrent(project: p, stress: st), "the exact lattice serves Print-accurate preview too")
        var look = p.lattice.organicLook!; look.lookPercent = 8; p.lattice.organicLook = look
        AppSettings.shared.latticePrintAccurate = false
        preview.update(project: p, on: true, stress: st)
        try await settle(preview, "the quick Draft at 8")
        AppSettings.shared.latticePrintAccurate = true
        XCTAssertFalse(preview.isCurrent(project: p, stress: st), "RED CONTROL: Print-accurate asks more than a Draft")
        XCTAssertFalse(preview.showRemembered(project: p, solid: false, stress: st), "a remembered Draft never stands for it")
        preview.clear()
    }

    /// The last lattice is dimmed while the new one lays, until this lay's own Draft is on screen; the renderer drains its colour.
    func testTheLastLatticeIsDimmedUntilTheDraftLands() {
        let t0 = Date()
        XCTAssertFalse(LatticeLayoutPreview.dims(nil), "nothing laying: as it is")
        XCTAssertTrue(LatticeLayoutPreview.dims(.init(quality: .draft, started: t0, expectedS: nil, draftShown: false)), "★ dimmed")
        XCTAssertFalse(LatticeLayoutPreview.dims(.init(quality: .exact, started: t0, expectedS: nil, draftShown: true)),
                       "★ the Draft on screen is the new lattice: not dimmed (the button marks it)")
        XCTAssertTrue(LatticeLayoutPreview.dims(.init(quality: .exact, started: t0, expectedS: nil, draftShown: false)))
        #if canImport(MetalKit)
        let c = SIMD3<Float>(0.85, 0.45, 0.2)
        let d = LatticeLayoutBarsPass.dimmedRGB(c)
        func lum(_ v: SIMD3<Float>) -> Float { simd_dot(v, SIMD3(0.299, 0.587, 0.114)) }
        func spread(_ v: SIMD3<Float>) -> Float { v.max() - v.min() }
        XCTAssertLessThan(lum(d), lum(c), "★ darker")
        XCTAssertLessThan(spread(d), 0.4 * spread(c), "★ greyer")
        XCTAssertGreaterThan(lum(d), 0.15, "never black: he keeps his bearings")
        #endif
        var a = LatticeLayoutBarsInputs(token: 3, bars: [])
        let b = a
        a.dimmed = true
        XCTAssertNotEqual(a, b, "★ dimming reaches the renderer (the view compares its inputs)")
    }

    // MARK: the preview itself, on a real part (the engine lays)

    private func organicProject() throws -> ProjectModel {
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.lattice.algorithm = "organic"
        p.lattice.wholePart = true
        var look = LatticeOrganicLook(); look.mode = .traced; look.lookPercent = 5   // open: a quick lay
        p.lattice.organicLook = look
        XCTAssertNotNil(p.importedFile, "premise: the part has its model file")
        return p
    }

    /// A stress pulling along x everywhere over the part's box (the vines run along it).
    private func stress(_ p: ProjectModel, key: Int) throws -> LatticeLayoutPreview.Stress {
        let b = try XCTUnwrap(LatticeLayoutPreview.box(p.importedMesh?.vertices ?? []))
        let h = 2.0
        let lo = SIMD3<Double>(b.lo) - 2, size = SIMD3<Double>(b.hi - b.lo) + 4
        let n = SIMD3<Int>(Int((size.x / h).rounded(.up)) + 1, Int((size.y / h).rounded(.up)) + 1, Int((size.z / h).rounded(.up)) + 1)
        let count = n.x * n.y * n.z
        var t = [Double](repeating: 0, count: 6 * count)
        for i in 0..<count { t[6 * i] = 10 }
        let f = LatticeDemandField(vonMises: [Float](repeating: 10, count: count), stressTensor: t, nx: n.x, ny: n.y, nz: n.z,
                                   origin: lo, spacingMM: h, provenance: .solidSim(date: Date(), resolution: 64))
        return .init(key: key, field: f, referenceMPa: 20)
    }

    private func settle(_ preview: LatticeLayoutPreview, _ what: String) async throws {
        let end = Date().addingTimeInterval(600)
        while preview.laying, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(preview.laying, "\(what): laid within 10 min")
    }

    /// ★ Draft first, then the exact lattice; the preview stays "laying" until the exact one (the print file waits for it).
    /// Going back to settings already laid shows that lattice at once, with no lay; Click to refresh shows it too. The print
    /// file's inputs from a remembered lattice are that lattice's. RED CONTROLS: no Draft first; nothing remembered.
    func testDraftFirstThenExactAndSettingsAlreadyLaidShowAtOnce() async throws {
        AppSettings.shared.latticePrintAccurate = true   // ★ Print-accurate preview on
        let p = try organicProject()
        let st = try stress(p, key: 41)
        let preview = LatticeLayoutPreview()
        var seen: [LatticeLayoutPreview.LayProgress] = []
        let sub = preview.$layProgress.sink { if let v = $0 { seen.append(v) } }
        defer { sub.cancel() }

        let lays0 = LatticeLayoutPreview.laysStarted
        let t0 = Date()
        preview.update(project: p, on: true, stress: st)
        XCTAssertTrue(preview.laying)
        XCTAssertEqual(preview.layProgress?.quality, .draft, "★ every Organic lay starts with its Draft")
        try await settle(preview, "first lay")
        print("STAGE1: first lay (Draft then Exact) \(String(format: "%.1f", Date().timeIntervalSince(t0))) s, struts \(preview.organicNumbers?.segments ?? -1)")
        XCTAssertEqual(preview.organicQuality, .exact, "★ the exact lattice replaces the Draft")
        XCTAssertNil(preview.layProgress)
        XCTAssertTrue(seen.contains { $0.quality == .draft && !$0.draftShown })
        XCTAssertTrue(seen.contains { $0.quality == .exact && $0.draftShown }, "★ the exact lattice was made with the Draft on screen")
        XCTAssertEqual(LatticeLayoutPreview.laysStarted, lays0 + 1, "one lay: the Draft and its exact lattice")
        let first = try XCTUnwrap(preview.bars?.token)
        let firstInputs = try await preview.organicFileInputs(project: p, stress: st)

        // another Look: laid (and its count-down now knows how long this part takes)
        var look = p.lattice.organicLook!; look.lookPercent = 10; p.lattice.organicLook = look
        preview.update(project: p, on: true, stress: st)
        XCTAssertNotNil(preview.layProgress?.expectedS, "★ the count-down knows this part's time")
        try await settle(preview, "second lay")
        XCTAssertEqual(preview.organicQuality, .exact)
        let second = try XCTUnwrap(preview.bars?.token)
        XCTAssertNotEqual(first, second)

        // back to Look 5: shown at once, no lay
        let shown0 = LatticeLayoutPreview.remembersShown, lays1 = LatticeLayoutPreview.laysStarted
        look.lookPercent = 5; p.lattice.organicLook = look
        preview.update(project: p, on: true, stress: st)
        XCTAssertFalse(preview.laying, "★ settings already laid: nothing to wait for")
        XCTAssertNil(preview.layProgress)
        XCTAssertEqual(preview.bars?.token, first, "★ the lattice made for these settings")
        XCTAssertEqual(preview.organicQuality, .exact)
        XCTAssertEqual(LatticeLayoutPreview.laysStarted, lays1, "★ no lay")
        XCTAssertEqual(LatticeLayoutPreview.remembersShown, shown0 + 1)
        XCTAssertTrue(preview.isCurrent(project: p, stress: st), "the page reads it as current (no Refresh Lattice)")
        let again = try await preview.organicFileInputs(project: p, stress: st)
        XCTAssertEqual(again.groups.count, firstInputs.groups.count)
        XCTAssertEqual(again.tensor, firstInputs.tensor, "★ the print file follows the stress that lattice was laid on")

        // Click to refresh: the page asks for a remembered lattice on a change
        look.lookPercent = 10; p.lattice.organicLook = look
        XCTAssertTrue(preview.showRemembered(project: p, solid: false, stress: st), "★ shown at once under Click to refresh")
        XCTAssertEqual(preview.bars?.token, second)
        look.lookPercent = 12; p.lattice.organicLook = look
        XCTAssertFalse(preview.showRemembered(project: p, solid: false, stress: st), "never laid: Refresh Lattice")
        XCTAssertEqual(preview.bars?.token, second, "nothing changed on screen")

        // RED CONTROL: nothing remembered
        LatticeLayoutPreview.controlForget = true
        look.lookPercent = 5; p.lattice.organicLook = look
        XCTAssertFalse(preview.showRemembered(project: p, solid: false, stress: st), "RED CONTROL: forgetting, it lays again")
        LatticeLayoutPreview.controlForget = false

        // RED CONTROL: no Draft first
        LatticeLayoutPreview.controlNoDraftFirst = true
        look.lookPercent = 15; p.lattice.organicLook = look
        preview.update(project: p, on: true, stress: st)
        XCTAssertEqual(preview.layProgress?.quality, .exact, "RED CONTROL: straight to the exact lattice")
        try await settle(preview, "no-draft lay")
        preview.clear()
    }
}
