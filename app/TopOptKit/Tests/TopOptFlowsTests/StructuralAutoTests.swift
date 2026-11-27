// StructuralAutoTests — ★ notes30 STRUCTURAL AUTO (his 11-24 vision; his 11-26 D1, D3; his rework 11-27, "go for #2": start
// from today's Auto, thicken only the struts the Mac's first check shows are short), the model side. One RED control per rule.
//   1. THE THICKENING: only the cell whose struts are short by the check's own law gets thicker, each just as far as its law
//      says (today's ramp then lays it), never past the quilt-off limit (held there, counted); no stress anywhere lowered.
//      RED: sizing every cell to its law (the first try) lowers the stress of a cell that was strong enough (thins it).
//   2. THE KEEP RULE: the lightest passing file, else the stronger; why a spot stays short; the record in the result.
//      RED: the old "none passing: the last" keeps the weaker file.
//   3. THE STEPS: the bar moves only at a step's real end; a first check that passes says so in one ticked line.
//   4. THE WORDS: every caption at most five words, positive; the (i)s hold the rest.
//   5. D1 and WHO: a new part starts at 150 % (175 % under Custom); only Structural Auto on a strut type with a law; the
//      preview reads today's stress until a press keeps a thickened file for exactly these inputs. RED: Manual.
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
        StructuralAuto.controlOff = false
        StructuralAutoStore.shared.reset()
    }

    static func core(_ rel: String) -> String {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("core").appendingPathComponent(rel).path
    }

    static let pa12 = StructuralAuto.Inputs(topology: "octet", yieldMPa: 38, zKnockdown: 0.75, up: SIMD3(0, 0, 1), margin: 1.5)

    /// Today's Structural Auto lay's settings: By stress on printed yield / margin, the thinnest strut to the open look.
    static func settings() -> LatticeLayoutSession.Settings {
        var s = LatticeLayoutSession.Settings()
        s.byStress = true
        s.referenceMPa = 38 * 0.75 / 1.5
        return s
    }

    /// A 1 mm grid of `nx` x 8 x 8 voxels at the origin: a uniform pull along x on the stage (its shape), its stress `base`
    /// everywhere (what today's ramp lays the laid strut from); cells of 8 mm side by side along x, each with `strutMM`.
    static func grid(nx: Int, base: Float = 0) -> (stage: LatticeDemandField, n: Int) {
        let n = nx * 8 * 8
        var t = [Double](repeating: 0, count: 6 * n)
        for e in 0..<n { t[6 * e] = 1 }
        return (LatticeDemandField(vonMises: Array(repeating: base, count: n), stressTensor: t, nx: nx, ny: 8, nz: 8, origin: .zero,
                                   spacingMM: 1, provenance: .solidSim(date: Date(), resolution: 64)), n)
    }
    /// Today's ramp for `settings()` on 8 mm cells, and the stage stress at which it lays `strutMM`.
    static func todaysRamp(strutMM: Double) throws -> (ramp: StructuralAuto.Ramp, base: Float) {
        let probe = try XCTUnwrap(TopOptKit.latticeStrutSizeField(topology: "octet", tensor: [1, 0, 0, 0, 0, 0], buildUp: pa12.up,
                                                                  yieldMPa: 38, zKnockdown: 0.75, target: pa12.target))
        let ramp = try XCTUnwrap(StructuralAuto.ramp(settings(), partRefMM: 8, touch: probe.touch, openLook: probe.openLook))
        return (ramp, Float(try XCTUnwrap(ramp.stress(forRatio: strutMM / 8))))
    }
    static func layout(cells: Int, strutMM: Float, voxels n: Int) -> StructuralAuto.Layout {
        var l = LatticeLayoutColours.Laid()
        l.frames = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]
        for c in 0..<cells {
            l.cellInfo += [8, 8, 1, 1, 0]
            l.cellLo += [Float(8 * c), 0, 0]
            l.cellFrame.append(0)
            l.cellStrut.append(strutMM)
        }
        return StructuralAuto.Layout(laid: l, lattice: Array(repeating: true, count: n))
    }
    /// The check's von Mises: `left` MPa in the first cell, `right` in the second.
    static func check(nx: Int, left: Float, right: Float) -> StructuralAuto.CheckField {
        var vm = [Float](repeating: 0, count: nx * 64)
        for k in 0..<8 { for j in 0..<8 { for i in 0..<nx { vm[i + nx * (j + 8 * k)] = i < 8 ? left : right } } }
        return StructuralAuto.CheckField(vonMises: vm, nx: nx, ny: 8, nz: 8, origin: .zero, spacingMM: 1)
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

    func testOnlyTheShortCellIsThickenedJustAsFarAsItsLawSays() throws {
        // three printed lines on 8 mm cells, laid by today's ramp from the stage's stress
        let strut: Float = 1.35
        let now = Double(strut) / 8
        let (ramp, base) = try Self.todaysRamp(strutMM: Double(strut))
        let (stage, n) = Self.grid(nx: 16, base: base)
        // a right-hand stress 3 % short at the laid strut (the law is linear in the stress: margin(v) = margin(1) / v)
        let right = Self.margin(now, 1) / (Self.pa12.target * 0.97)
        XCTAssertLessThan(Self.margin(now, right), Self.pa12.target, "premise: short at the laid strut")
        XCTAssertGreaterThanOrEqual(Self.margin(ramp.rHeavy * 0.95, right), Self.pa12.target, "premise: held inside the open lattice")
        let lay = Self.layout(cells: 2, strutMM: strut, voxels: n)
        let s = Self.settings()
        let t = try XCTUnwrap(StructuralAuto.thicken(check: Self.check(nx: 16, left: 0.05, right: Float(right)), stage: stage,
                                                     layout: lay, settings: s, Self.pa12))
        XCTAssertEqual(t.shortCells, 1, "★ only the right cell is short")
        XCTAssertEqual(t.thickenedCells, 1)
        XCTAssertEqual(t.cappedCells, 0)
        let need = try XCTUnwrap(TopOptKit.latticeStrutSizeField(topology: "octet", tensor: [right, 0, 0, 0, 0, 0], buildUp: Self.pa12.up,
                                                                 yieldMPa: 38, zKnockdown: 0.75, target: Self.pa12.target))
        let r1 = Self.laidRatio(t.field, cell: 1, ramp: ramp)
        XCTAssertGreaterThanOrEqual(r1, Double(need.ratio[0]) - 1e-9, "★ today's ramp now lays the strut the law asks")
        XCTAssertLessThan(r1, Double(need.ratio[0]) + 1e-4, "★ just as far: no thicker than it asks")
        XCTAssertGreaterThanOrEqual(Self.margin(r1, right), Self.pa12.target * (1 - 1e-6), "★ the law holds the target there")
        XCTAssertEqual(Self.laidRatio(t.field, cell: 0, ramp: ramp), Self.laidRatio(stage, cell: 0, ramp: ramp),
                       "★ the strong cell exactly as it was")
        XCTAssertTrue(zip(t.field.vonMises, stage.vonMises).allSatisfy { $0 >= $1 }, "★ add-only: no stress anywhere lowered")
        XCTAssertGreaterThan(t.weakestPredicted, t.weakestNow, "the law's prediction for check 2")
        // past the open lattice: held at the quilt-off limit and counted (the pop-up names the fix)
        let big = try XCTUnwrap(StructuralAuto.thicken(check: Self.check(nx: 16, left: 0.05, right: 400), stage: stage, layout: lay,
                                                       settings: s, Self.pa12))
        XCTAssertEqual(big.cappedCells, 1, "★ never past the quilt-off limit")
        let cap = Swift.min(StructuralAuto.quiltOffRatio(touch: need.touch, cellMM: 8, lineMM: 0.45), ramp.rHeavy)
        XCTAssertEqual(Self.laidRatio(big.field, cell: 1, ramp: ramp), cap, accuracy: 1e-4, "★ held at the limit")
        // a check that holds everywhere: nothing thickened
        let fine = try XCTUnwrap(StructuralAuto.thicken(check: Self.check(nx: 16, left: 0.05, right: 0.05), stage: stage, layout: lay,
                                                        settings: s, Self.pa12))
        XCTAssertEqual(fine.thickenedCells, 0)
        XCTAssertEqual(fine.field.vonMises, stage.vonMises, "★ nothing short: the stress unchanged")
        // RED CONTROL: the first try — every cell sized to its own law — lowers the strong cell's stress (thins it)
        let leftNeed = try XCTUnwrap(TopOptKit.latticeStrutSizeField(topology: "octet", tensor: [0.05, 0, 0, 0, 0, 0],
                                                                     buildUp: Self.pa12.up, yieldMPa: 38, zKnockdown: 0.75,
                                                                     target: Self.pa12.target))
        XCTAssertLessThan(Double(leftNeed.ratio[0]), now, "RED CONTROL: sizing every cell to its law thins the strong one")
        let sizedLeft = ramp.stress(forRatio: Double(leftNeed.ratio[0])) ?? 0
        XCTAssertLessThan(sizedLeft, Double(base), "RED CONTROL: … its stress lowered")
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
                        StructuralAutoCopy.shortTitle(.solid, margin: 2)]
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

    func testD1AndWhoIsStrengthened() throws {
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
        XCTAssertTrue(StructuralAuto.applies(p), "★ Structural, Auto, octet")
        for (name, q) in [("Aesthetic", Self.project(stage: .aesthetic)), ("Manual", Self.project(manual: true)),
                          ("Organic", Self.project(algorithm: "organic")), ("Gyroid", Self.project(stage: .aesthetic, topology: "gyroid"))] {
            XCTAssertFalse(StructuralAuto.applies(q), "\(name): never strengthened")
        }
        // the preview reads today's stress until a press keeps a thickened file for exactly these inputs
        let m = AppModel(materialsPath: Self.core("src/materials/materials.json"),
                         store: ProjectStore(rootDir: FileManager.default.temporaryDirectory
                            .appendingPathComponent("sa-\(UUID().uuidString)")))
        m.loadMaterials()
        let (stage, _) = Self.grid(nx: 8)
        let base = LatticeLayoutPreview.Stress(key: 7, field: stage, referenceMPa: 19)
        XCTAssertEqual(StructuralAuto.stress(p, base: base, model: m), base, "★ today's stress, unchanged")
        let bk = try XCTUnwrap(StructuralAuto.baseKey(p, base: base, model: m))
        StructuralAutoStore.shared.keep(p.id, .init(baseKey: bk, field: stage, key: 99))
        XCTAssertEqual(StructuralAuto.stress(p, base: base, model: m).key, 99, "★ the drawing follows the file kept")
        p.force.safetyMargin = 2
        XCTAssertEqual(StructuralAuto.stress(p, base: base, model: m), base, "★ a new margin: today's again until pressed")
        p.force.safetyMargin = 1.5
        // RED CONTROL: Manual is his own — the kept round never reaches it
        p.latticePageManual = true
        XCTAssertEqual(StructuralAuto.stress(p, base: base, model: m), base, "RED CONTROL: Manual reads the base")
    }

    // MARK: 6 — the chain on a stub Mac

    /// fields.bin v1 (core/include/topopt/fields.hpp) of one block on an nx × 8 × 8 grid at the origin, 1 mm voxels.
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
        let (_, base) = try Self.todaysRamp(strutMM: 1.35)
        let (stage, n) = Self.grid(nx: 16, base: base)
        try Self.fieldsBin(Self.check(nx: 16, left: 0.05, right: 400)).write(to: files.appendingPathComponent("fields.bin"))
        let strength = LatticeFileButtonTests.strength(verdict, accepted: true, margin: verdict == "pass" ? 1.7 : 1.2,
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
        let lay = Self.layout(cells: 2, strutMM: 1.35, voxels: n)
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
        XCTAssertEqual(rec.thickenedCells, 1, "★ only the short cell")
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
