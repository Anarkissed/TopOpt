// StructuralAutoTests — ★ notes30 SA1 STRUCTURAL AUTO (his 11-24 vision; his 11-26 D1, D3; his rework 11-27, "go for #2": start
// from today's Auto, thicken only the struts the Mac's first check shows are short; his cube fix and his switch, 11-27), the
// model side. One RED control per rule.
//   1. THE THICKENING, ANCHORED TO THE CHECK'S OWN NUMBER (his cube fix): the app's reading of each cell is anchored to the
//      check's own weakest strut margin; a cell under the target gets thicker, just as far as its law says (today's ramp
//      then lays it), never past the heaviest strut today's lay makes (held there, counted); every other cell exactly as it
//      was; no stress anywhere lowered. RED: today's reading (not anchored) reads his cube's 1.49x strut at 1.60x and
//      thickens nothing.
//   2. THE KEEP RULE: the lightest passing file, else the stronger; why a spot stays short; the record in the result.
//      RED: the old "none passing: the last" keeps the weaker file.
//   3. THE STEPS: the bar moves only at a step's real end; a first check that passes says so in one ticked line.
//   4. THE WORDS: every caption at most five words, positive; the (i)s hold the rest.
//   5. D1, WHO and HIS SWITCH: a new part starts at 150 % (175 % under Custom); only Structural Auto on a strut type with a
//      law; Settings' "Structural Auto" on by default, and on and off differ only by the thickening (the lay, the job's
//      settings and the stress the same). RED: off — the press thickens nothing.
//   6. THE CHAIN on a stub Mac: a check that falls short is thickened and checked again (two jobs); one that passes stops at
//      one (one job: nothing added).
#if canImport(AppKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class StructuralAutoTests: XCTestCase {
    override func tearDown() {
        StructuralAutoSwitch.isOn = true
        StructuralAutoStore.shared.reset()
    }

    static func core(_ rel: String) -> String {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("core").appendingPathComponent(rel).path
    }

    static let pa12 = StructuralAuto.Inputs(topology: "octet", yieldMPa: 38, zKnockdown: 0.75, up: SIMD3(0, 0, 1), margin: 1.5)
    static let strut: Float = 1.35   // three printed lines on 8 mm cells

    /// Today's Structural Auto lay's settings: By stress on printed yield / margin, the thinnest strut to the open look.
    static func settings() -> LatticeLayoutSession.Settings {
        var s = LatticeLayoutSession.Settings()
        s.byStress = true
        s.referenceMPa = 38 * 0.75 / 1.5
        return s
    }

    /// A 1 mm grid of `nx` x 8 x 8 voxels at the origin: a uniform pull along x on the stage (its shape), its stress `base`
    /// everywhere (what today's ramp lays the laid strut from).
    static func grid(nx: Int, base: Float = 0) -> LatticeDemandField {
        let n = nx * 8 * 8
        var t = [Double](repeating: 0, count: 6 * n)
        for e in 0..<n { t[6 * e] = 1 }
        return LatticeDemandField(vonMises: Array(repeating: base, count: n), stressTensor: t, nx: nx, ny: 8, nz: 8, origin: .zero,
                                  spacingMM: 1, provenance: .solidSim(date: Date(), resolution: 64))
    }
    /// Today's ramp for `settings()` on 8 mm cells, and the stage stress at which it lays `strutMM`.
    static func todaysRamp(strutMM: Double = Double(StructuralAutoTests.strut)) throws -> (ramp: StructuralAuto.Ramp, base: Float) {
        let probe = try XCTUnwrap(TopOptKit.latticeStrutSizeField(topology: "octet", tensor: [1, 0, 0, 0, 0, 0], buildUp: pa12.up,
                                                                  yieldMPa: 38, zKnockdown: 0.75, target: pa12.target))
        let ramp = try XCTUnwrap(StructuralAuto.ramp(settings(), partRefMM: 8, touch: probe.touch, openLook: probe.openLook))
        return (ramp, Float(try XCTUnwrap(ramp.stress(forRatio: strutMM / 8))))
    }
    /// One fill strut along x through each 8 mm cell's middle (cells side by side along x).
    static func bars(cells: Int, width: Float = StructuralAutoTests.strut) -> [Float] {
        (0..<cells).flatMap { c -> [Float] in [Float(8 * c + 2), 4, 4, Float(8 * c + 6), 4, 4, width] }
    }
    /// The preview's lay: `cells` cells of 8 mm, each with its fill strut, every check voxel lattice.
    static func layout(cells: Int) -> StructuralAuto.Layout {
        StructuralAuto.Layout(laid: laid(cells: cells), lattice: Array(repeating: true, count: 8 * cells * 64))
    }
    /// The check: its composite von Mises, `left` MPa in the first cell and `right` in the second; its own weakest strut.
    static func check(left: Float, right: Float, strutMargin: Double?) -> StructuralAuto.CheckField {
        var vm = [Float](repeating: 0, count: 16 * 64)
        for k in 0..<8 { for j in 0..<8 { for i in 0..<16 { vm[i + 16 * (j + 8 * k)] = i < 8 ? left : right } } }
        return StructuralAuto.CheckField(vonMises: vm, nx: 16, ny: 8, nz: 8, origin: .zero, spacingMM: 1, strutMargin: strutMargin)
    }
    static func laid(cells: Int) -> LatticeLayoutColours.Laid {
        var l = LatticeLayoutColours.Laid()
        l.frames = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]
        for c in 0..<cells {
            l.cellInfo += [8, 8, 1, 1, 0]
            l.cellLo += [Float(8 * c), 0, 0]
            l.cellFrame.append(0)
        }
        l.bars = bars(cells: cells)
        l.barFlags = Array(repeating: 0, count: cells)
        l.barCell = Array(repeating: 8, count: cells)
        return l
    }
    static func margin(_ ratio: Double, _ vm: Double, _ i: StructuralAuto.Inputs = pa12) -> Double {
        let rho = TopOptKit.latticeRelativeDensity(topology: i.topology, strutRadiusMM: ratio * 4, cellMM: 8)
        return TopOptKit.latticeStrutLawMargin(topology: i.topology, rho: rho, vonMisesMPa: vm, pressureMPa: vm / 3, buildUp: i.up,
                                               yieldMPa: i.yieldMPa, zKnockdown: i.zKnockdown)
    }
    /// The highest stage stress over a cell's box (core's R16 read), and the strut / cell today's ramp lays for it.
    static func laidRatio(_ f: LatticeDemandField, cell c: Int, ramp: StructuralAuto.Ramp) -> Double {
        var d: Float = 0
        for k in 0..<8 { for j in 0..<8 { for i in (8 * c)..<(8 * c + 8) { d = Swift.max(d, f.vonMises[i + f.nx * (j + 8 * k)]) } } }
        return ramp.ratio(stress: Double(d))
    }

    // MARK: 1

    func testTheShortCellIsThickenedByTheChecksOwnNumberJustAsFarAsItsLawSays() throws {
        let now = Double(Self.strut) / 8
        let (ramp, base) = try Self.todaysRamp()
        let stage = Self.grid(nx: 16, base: base)
        let lay = Self.layout(cells: 2)
        let s = Self.settings()
        // his cube at 150 %: the app's reading of its weakest strut 1.60x, the check's own 1.49x
        let right = Float(Self.margin(now, 1) / 1.6)
        let t = try XCTUnwrap(StructuralAuto.thicken(check: Self.check(left: 0.05, right: right, strutMargin: 1.49), stage: stage,
                                                     layout: lay, settings: s, Self.pa12))
        XCTAssertEqual(t.anchor, 1.49 / 1.6, accuracy: 1e-3, "★ anchored to the check's own number")
        XCTAssertEqual(t.shortCells, 1, "★ the right cell, short by the check's number")
        XCTAssertEqual(t.thickenedCells, 1)
        XCTAssertEqual(t.cappedCells, 0)
        XCTAssertEqual(t.weakestNow, 1.49, accuracy: 1e-3, "★ the check's own number")
        // the law's own rise from the laid strut to the one today's ramp now lays there (linear in the stress: any size will do)
        let r1 = Self.laidRatio(t.field, cell: 1, ramp: ramp)
        let rise = Self.margin(r1, 10) / Self.margin(now, 10)
        XCTAssertGreaterThanOrEqual(1.49 * rise, Self.pa12.target * (1 - 1e-3), "★ thick enough: the law holds the target there")
        XCTAssertLessThan(1.49 * rise, Self.pa12.target * 1.02, "★ just as far: no thicker than it asks")
        XCTAssertEqual(Self.laidRatio(t.field, cell: 0, ramp: ramp), now, accuracy: 1e-6, "★ the strong cell exactly as it was")
        XCTAssertTrue(zip(t.field.vonMises, stage.vonMises).allSatisfy { $0 >= $1 }, "★ add-only: no stress anywhere lowered")
        // RED CONTROL: today's reading (not anchored: the block's number unknown) reads 1.60x and finds nothing short
        let today = try XCTUnwrap(StructuralAuto.thicken(check: Self.check(left: 0.05, right: right, strutMargin: nil), stage: stage,
                                                         layout: lay, settings: s, Self.pa12))
        XCTAssertEqual(today.shortCells, 0, "RED CONTROL: today's reading thickens nothing on his cube")
        // far short: held at the heaviest strut today's lay makes, and counted (the pop-up names the fix)
        let big = try XCTUnwrap(StructuralAuto.thicken(check: Self.check(left: 0.05, right: right, strutMargin: 0.2), stage: stage,
                                                       layout: lay, settings: s, Self.pa12))
        XCTAssertEqual(big.cappedCells, 1, "★ never past the heaviest strut")
        XCTAssertEqual(Self.laidRatio(big.field, cell: 1, ramp: ramp), ramp.rHeavy, accuracy: 1e-4, "★ held there")
        // every strut holds by the check's number: nothing thickened
        let fine = try XCTUnwrap(StructuralAuto.thicken(check: Self.check(left: 0.05, right: right, strutMargin: 2.5), stage: stage,
                                                        layout: lay, settings: s, Self.pa12))
        XCTAssertEqual(fine.thickenedCells, 0)
        XCTAssertEqual(fine.field.vonMises, stage.vonMises, "★ nothing short: the stress unchanged")
    }

    // MARK: 2

    func testTheKeepRuleAndWhyASpotStaysShort() {
        typealias A = StructuralAuto
        XCTAssertEqual(A.checksPerPress, 2, "★ D3: two checks per press")
        XCTAssertEqual(A.thickenAbove, 1.05, "★ his rework: short under the target x 1.05")
        let r = { (p: Bool, mm3: Double, m: Double) in A.Round(passed: p, plasticMM3: mm3, margin: m) }
        XCTAssertEqual(A.kept([r(true, 100, 1.9), r(true, 120, 2.1)]), 0, "★ the lightest that passes")
        XCTAssertEqual(A.kept([r(false, 100, 1.3), r(true, 120, 1.6)]), 1, "★ the thickened one, when only it passes")
        XCTAssertEqual(A.kept([r(true, 100, 1.6)]), 0)
        let neither = [r(false, 100, 1.4), r(false, 130, 1.2)]
        XCTAssertEqual(A.kept(neither), 0, "★ neither passes: the stronger")
        XCTAssertNotEqual(A.kept(neither), neither.count - 1, "RED CONTROL: the old rule kept the last (the weaker)")
        XCTAssertEqual(A.short(rounds: [r(false, 100, 1.2), r(false, 120, 1.25)], predicted: 1.6, cappedCells: 0), .stiffWalls,
                       "★ rose by less than a third of the law's prediction: the walls")
        XCTAssertEqual(A.short(rounds: [r(false, 100, 1.2), r(false, 120, 1.4)], predicted: 1.6, cappedCells: 3), .denseLattice)
        XCTAssertEqual(A.short(rounds: [r(false, 100, 1.2)], predicted: 0, cappedCells: 0), .solid)
        XCTAssertNil(A.short(rounds: [r(false, 100, 1.2), r(true, 120, 1.6)], predicted: 1.6, cappedCells: 0), "holds: no pop-up")
        let rec = A.Record(margin: 1.75, rounds: [r(false, 100, 1.3), r(true, 110, 1.8)], keptRound: 1, thickenedCells: 6,
                           cappedCells: 0, predicted: 1.9)
        XCTAssertEqual(rec.addedShare, 0.1, accuracy: 1e-9, "★ the plastic the thickening added")
        XCTAssertEqual(A.Record.decode(rec.json), rec)
        let report = A.withRecord(Data(#"{"ok": true}"#.utf8), rec)
        XCTAssertEqual(A.Record.of(report: report), rec, "★ in the result's report")
        XCTAssertEqual(RunReportBlocks.decode(reportJSON: report)?.structuralAuto, rec, "★ Results reads it")
    }

    // MARK: 3

    func testTheBarMovesOnlyWhenAStepEnds() {
        var s = StructuralAutoSteps(margin: 1.5)
        XCTAssertEqual(s.items.map(\.words), ["Checking strength (1 of 2)", "Thickening short struts", "Checking strength (2 of 2)",
                                              "Saving the print file"])
        XCTAssertEqual(s.fraction, 0)
        s.apply(.began(.check(1)))
        XCTAssertEqual(s.fraction, 0, "★ a step beginning moves nothing (no fake progress)")
        s.apply(.began(.thicken))
        XCTAssertEqual(s.fraction, 0.25, accuracy: 1e-9, "★ check 1 ended")
        s.apply(.began(.check(2)))
        s.apply(.began(.saving))
        XCTAssertEqual(s.fraction, 0.75, accuracy: 1e-9)
        s.apply(.finished)
        XCTAssertEqual(s.fraction, 1)
        // check 1 passes: the steps not taken go, one ticked line says why
        var c = StructuralAutoSteps(margin: 1.75)
        c.apply(.began(.check(1)))
        c.apply(.shortcut(passed: true))
        XCTAssertEqual(c.items.map(\.words), ["Checking strength (1 of 2)", "First check passed", "Saving the print file"])
        XCTAssertEqual(c.items.map(\.done), [true, true, false])
        // RED CONTROL: a stop for another reason (nothing to thicken from) says nothing of a pass
        var d = StructuralAutoSteps(margin: 1.5)
        d.apply(.began(.check(1)))
        d.apply(.shortcut(passed: false))
        XCTAssertFalse(d.items.contains { $0.words == StructuralAutoCopy.firstPassed }, "RED CONTROL: no pass said")
        XCTAssertFalse(d.items.contains { $0.kind == .check(2) }, "★ never a check that will not come")
    }

    // MARK: 4

    func testEveryCaptionIsFiveWordsAtMostAndPositive() {
        let captions = [StructuralAutoCopy.title, StructuralAutoCopy.checking(1, of: 2), StructuralAutoCopy.checking(2, of: 2),
                        StructuralAutoCopy.thickening, StructuralAutoCopy.saving, StructuralAutoCopy.firstPassed,
                        StructuralAutoCopy.strengthenedTo(1.5), StructuralAutoCopy.strengthenedTo(2), StructuralAutoCopy.strengthenedByAuto,
                        StructuralAutoCopy.shortTitle(.stiffWalls, margin: 1.5), StructuralAutoCopy.shortTitle(.denseLattice, margin: 1.5),
                        StructuralAutoCopy.shortTitle(.solid, margin: 2), StructuralAutoSettingsRow.title,
                        StructuralAutoSettingsRow.caption]
        let negative = try! NSRegularExpression(pattern: #"(?i)\b(don['’]t|can['’]t|cannot|not|never|won['’]t|fail\w*|unable|isn['’]t)\b"#)
        for c in captions {
            let words = c.split(separator: " ").filter { $0 != "%" }.count
            XCTAssertLessThanOrEqual(words, 5, "★ '\(c)': five words at most")
            XCTAssertNil(negative.firstMatch(in: c, range: NSRange(c.startIndex..., in: c)), "★ '\(c)': positive words")
        }
        // each step's (i) holds a sentence of its own
        for i in StructuralAutoSteps(margin: 1.5).items { XCTAssertGreaterThan(i.info.split(separator: " ").count, 5, i.words) }
    }

    // MARK: 5

    static func project(stage: LatticeStageMode = .structural, manual: Bool = false, algorithm: String? = nil,
                        topology: String = "octet") -> ProjectModel {
        let p = ProjectModel(id: UUID(), name: "P", material: "PA12", process: .fdm, importedFile: nil, importedMesh: nil)
        var l = LatticeSettings(enabled: true, topologyID: topology)
        l.chooseLatticeType(stage)
        if let algorithm { l.algorithm = algorithm }
        p.lattice = l
        p.latticePageManual = manual
        return p
    }

    func testD1WhoAndHisSwitch() throws {
        XCTAssertEqual(SafetyMargin.defaultValue, 1.5, "★ D1: 150 %")
        let d = UserDefaults(suiteName: "sa-\(UUID().uuidString)")!
        var f = ForceModel()
        AppSettings(defaults: d).apply(to: &f)
        XCTAssertEqual(f.safetyMarginValue, 1.5, "★ a new part starts at 150 %")
        XCTAssertFalse(SafetyMargin.presets.contains { $0.value == 1.75 }, "175 % stays under Custom (his D1)")
        XCTAssertTrue(LatticeSetupWizard.structuralAutoCustomMargins.contains(1.75), "★ … where the row's Custom offers it")
        var low = Self.pa12
        low.margin = 1.2
        XCTAssertEqual(low.target, 1.5 * 1.05, accuracy: 1e-12, "never under 150 %")
        // who: Structural Auto on a strut type with a law, graded By stress; nothing else
        let p = Self.project()
        XCTAssertTrue(StructuralAuto.thickens(p), "★ Structural, Auto, octet, his switch on")
        for (name, q) in [("Aesthetic", Self.project(stage: .aesthetic)), ("Manual", Self.project(manual: true)),
                          ("Organic", Self.project(algorithm: "organic")), ("Gyroid", Self.project(stage: .aesthetic, topology: "gyroid"))] {
            XCTAssertFalse(StructuralAuto.thickens(q), "\(name): never thickened")
        }
        // HIS SWITCH: on for a new install; on and off differ only by the thickening — the lay, its settings and its stress the same
        XCTAssertTrue(StructuralAutoSwitch(defaults: UserDefaults(suiteName: "sa-\(UUID().uuidString)")!).on, "★ on by default")
        let m = AppModel(materialsPath: Self.core("src/materials/materials.json"),
                         store: ProjectStore(rootDir: FileManager.default.temporaryDirectory
                            .appendingPathComponent("sa-\(UUID().uuidString)")))
        m.loadMaterials()
        let stage = Self.grid(nx: 8)
        let base = LatticeLayoutPreview.Stress(key: 7, field: stage, referenceMPa: 19)
        let onSettings = LatticeLayoutPreview.settings(p, referenceMPa: 19), onStress = StructuralAuto.stress(p, base: base, model: m)
        StructuralAutoSwitch.isOn = false
        XCTAssertFalse(StructuralAuto.thickens(p), "RED CONTROL: off — the press thickens nothing (today's one check)")
        XCTAssertEqual(LatticeLayoutPreview.settings(p, referenceMPa: 19), onSettings, "★ off: the same lay")
        XCTAssertEqual(StructuralAuto.stress(p, base: base, model: m), onStress, "★ off: the same stress")
        XCTAssertEqual(onStress, base, "★ today's stress until a press keeps a thickened file")
        StructuralAutoSwitch.isOn = true
        // the drawing follows the file a press kept, for exactly these inputs
        let bk = try XCTUnwrap(StructuralAuto.baseKey(p, base: base, model: m))
        StructuralAutoStore.shared.keep(p.id, .init(baseKey: bk, field: stage, key: 99))
        XCTAssertTrue(StructuralAutoStore.shared.has(p.id))
        XCTAssertEqual(StructuralAuto.stress(p, base: base, model: m).key, 99, "★ the drawing follows the file kept")
        p.force.safetyMargin = 2
        XCTAssertEqual(StructuralAuto.stress(p, base: base, model: m), base, "★ a new margin: today's again until pressed")
        p.force.safetyMargin = 1.5
        p.latticePageManual = true
        XCTAssertEqual(StructuralAuto.stress(p, base: base, model: m), base, "★ Manual is his own: the base")
    }

    // MARK: 6 — the chain on a stub Mac

    /// fields.bin v1 (core/include/topopt/fields.hpp) of one block on the check's grid at the origin, 1 mm voxels.
    static func fieldsBin(_ c: StructuralAuto.CheckField) -> Data {
        var d = Data([1, 0, 0, 0])
        func i32(_ v: Int32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func i64(_ v: Int64) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 8)) }
        func f64(_ v: Double) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 8)) }
        func f32(_ v: Float) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        i32(Int32(c.nx)); i32(Int32(c.ny)); i32(Int32(c.nz)); f64(0); f64(0); f64(0); f64(1); f64(1); i32(1); i32(0)
        f64(0.25); f64(41); i32(0); i32(0); i64(Int64(c.vonMises.count)); i64(0); i64(0)
        for v in c.vonMises { f32(v) }
        return d
    }

    final class Said: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [StructuralAutoSteps.Event] = []
        func add(_ e: StructuralAutoSteps.Event) { lock.lock(); events.append(e); lock.unlock() }
        var all: [StructuralAutoSteps.Event] { lock.lock(); defer { lock.unlock() }; return events }
    }

    private func runChain(verdict: String) throws -> (o: OptimizeOutcome, posts: Int, said: [StructuralAutoSteps.Event]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sa-chain-\(UUID().uuidString)")
        let files = dir.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let (_, base) = try Self.todaysRamp()
        let stage = Self.grid(nx: 16, base: base)
        let right = Float(Self.margin(Double(Self.strut) / 8, 1) / 1.6)
        try Self.fieldsBin(Self.check(left: 0.05, right: right, strutMargin: nil)).write(to: files.appendingPathComponent("fields.bin"))
        let own = verdict == "pass" ? 1.7 : 1.2   // the check's own weakest strut
        let strength = LatticeFileButtonTests.strength(verdict, accepted: true, margin: own, strut: ["margin_worst_case": own],
                                                       strutsPass: verdict == "pass")
        try LatticeFileButtonTests.report(strength).write(to: files.appendingPathComponent(LatticeFileJob.reportName))
        try LatticeFileButtonTests.stl().write(to: files.appendingPathComponent(LatticeFileJob.outputName))
        let model = dir.appendingPathComponent("p.step")
        try Data("ISO-10303-21;".utf8).write(to: model)
        let w = try StubWorker(filesDir: files, events: [], fingerprint: CoreFingerprint.value)
        defer { w.stop() }
        let config = RemoteRunnerConfig(host: "127.0.0.1", port: Int(w.port), expectedFingerprint: CoreFingerprint.value)
        let job = LatticeFileJob.ForPart(json: Data(#"{"mode": "lattice_file", "model": "p.step", "demand": "demand.bin"}"#.utf8),
                                         modelPath: model.path, demand: LatticeFileJob.demandFile(stage))
        let ask = LatticeFileButton.StructuralAutoAsk(stage: stage, inputs: Self.pa12, baseKey: 42, settings: Self.settings())
        let lay = Self.layout(cells: 2)
        let said = Said()
        let defaults = UserDefaults(suiteName: "sa-chain-\(UUID().uuidString)")!
        let inputs = FileManager.default.temporaryDirectory.appendingPathComponent("sa-inputs-\(UUID().uuidString)")
        let run = LatticeFileButton.structuralAutoRunner(config: config, job: job, ask: ask, projectName: "P",
                                                         strengthJob: Data(#"{"mode": "lattice_part"}"#.utf8), densityGCm3: 1.01,
                                                         defaults: defaults, inputsRoot: inputs, store: StructuralAutoStore(),
                                                         layout: { _ in lay }, onStep: { said.add($0) })
        let req = RunRequest(modelPath: model.path, material: "PA12", materialsPath: "", rulesPath: "", resolution: 64,
                             projectName: "P", projectID: UUID())
        let o = try run(req, { _, _, _ in true }, { _ in })
        return (o, w.posts().count, said.all)
    }

    func testAShortCheckIsThickenedAndCheckedAgainAndAPassStopsAtOne() throws {
        let short = try runChain(verdict: "fail")
        XCTAssertEqual(short.posts, 2, "★ two jobs: check 1, then check 2 of the thickened struts")
        let rec = try XCTUnwrap(StructuralAuto.Record.of(report: short.o.reportJSON), "★ the record rides with the result")
        XCTAssertEqual(rec.rounds.count, 2)
        XCTAssertEqual(rec.thickenedCells, 1, "★ only the cell short by the check's own number")
        XCTAssertEqual(short.said, [.began(.check(1)), .began(.thicken), .began(.check(2)), .began(.saving), .finished],
                       "★ the card's steps, each as it really begins")
        let pass = try runChain(verdict: "pass")
        XCTAssertEqual(pass.posts, 1, "★ add-only: a first check that passes ends it")
        XCTAssertEqual(StructuralAuto.Record.of(report: pass.o.reportJSON)?.rounds.count, 1)
        XCTAssertEqual(pass.said, [.began(.check(1)), .shortcut(passed: true), .began(.saving), .finished])
        XCTAssertTrue(pass.o.variants.first?.accepted ?? false)
    }
}
#endif
