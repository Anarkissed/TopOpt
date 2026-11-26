// StructuralAutoTests — ★ notes30 STRUCTURAL AUTO (his 11-24 vision; his 11-26 D1-D3), the model side. Each test has a RED
// control that restores today and must fail the same assertion.
//   1. THE LAW TURNED ROUND, through the bridge: every loaded voxel's density holds the target by the law the check judges by
//      (core's strut_law_margin_at), the lightest that does; a pure-pressure voxel (von Mises 0) is still sized (the
//      two-invariant law); octet never under its 0.10 floor. RED: today's ramp (printed yield / margin) misses it.
//   2. WHAT AUTO SENDS: Structural Auto sends the sized field as strut / cell (demand_is_ratio), reference 1, response 1, cell
//      size by stress off, D2's quilt where short; Aesthetic Auto, Manual, Organic and a sheet are byte for byte what they were
//      (the "never widen" guard). RED: Structural Auto through the old branch (controlRamp).
//   3. THE JOB: the keys written only when on (every other job the bytes it was).
//   4. THE STOP RULES: the one-check shortcut, the last check, keep the lightest passing, why a spot stays short.
//   5. THE STEPS: the bar moves only at a step's real end; the shortcut drops the steps not taken and says so in one line.
//   6. THE WORDS: every caption at most five words, positive; the (i)s hold the rest.
//   7. D1: a new part starts at 150 %; 175 % is under Custom, not a preset.
//   8. THE CHAIN on a stub Mac: a check that fails is fine-tuned and checked again (two jobs, round 1's own field sent); one
//      that passes close enough stops at one; the result carries the record and the kept round is remembered.
#if canImport(AppKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class StructuralAutoTests: XCTestCase {
    override func tearDown() {
        StructuralAuto.controlRamp = false
        StructuralAuto.quiltWhereShortWired = true
        StructuralAutoStore.shared.reset()
    }

    static func core(_ rel: String) -> String {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("core").appendingPathComponent(rel).path
    }

    /// A grid of states: tension along x of rising size, a shear, and a pure pressure (von Mises 0), plus an unloaded voxel.
    static func field(n: Int = 40) -> LatticeDemandField {
        var t: [Double] = []
        for i in 0..<n {
            let a = 0.08 * Double(i)
            t += i % 3 == 0 ? [a, 0, 0, 0, 0, 0] : i % 3 == 1 ? [0.3 * a, -0.2 * a, 0, 0.5 * a, 0, 0] : [a, a, a, 0, 0, 0]
        }
        t += [0, 0, 0, 0, 0, 0]
        let count = t.count / 6
        return LatticeDemandField(vonMises: Array(repeating: 1, count: count), stressTensor: t, nx: count, ny: 1, nz: 1,
                                  origin: .zero, spacingMM: 1, provenance: .solidSim(date: Date(), resolution: 64))
    }

    static let pa12 = StructuralAuto.Inputs(topology: "octet", yieldMPa: 38, zKnockdown: 0.75, up: SIMD3(0, 0, 1), margin: 1.5)

    // MARK: 1

    func testEveryLoadedVoxelHoldsItsTargetByTheChecksOwnLaw() throws {
        let f = Self.field()
        let inputs = Self.pa12
        let s = try XCTUnwrap(StructuralAuto.size(f, inputs), "★ the law turned round, through the bridge")
        XCTAssertGreaterThanOrEqual(Double(s.rho.min() ?? 0), 0.10 - 1e-6, "★ octet never under its 0.10 floor (the bulk-only row)")
        var held = 0, rampHeld = 0, loaded = 0
        for e in 0..<(f.stressTensor.count / 6) {
            let t = Array(f.stressTensor[(6 * e)..<(6 * e + 6)])
            let p = (t[0] + t[1] + t[2]) / 3
            let vm = t.withUnsafeBufferPointer { StructuralAuto.vonMises($0, at: 0) }
            guard vm > 0 || p != 0 else { continue }
            loaded += 1
            if s.short[e] != 0 { continue }
            let m = TopOptKit.latticeStrutLawMargin(topology: "octet", rho: Double(s.rho[e]), vonMisesMPa: vm, pressureMPa: p,
                                                    buildUp: inputs.up, yieldMPa: inputs.yieldMPa, zKnockdown: inputs.zKnockdown)
            if m >= inputs.target * (1 - 1e-6) { held += 1 }
            // RED CONTROL: today's Structural Auto ramp (reference = printed yield / margin, the thinnest strut at no stress, the
            // open look at the reference, read on the largest 8 mm cell) as a density
            let reference = inputs.yieldMPa * inputs.zKnockdown / inputs.margin
            let ratio = 0.9 / 8 + Swift.min(1, vm / reference) * (kOpenLook - 0.9 / 8)
            let rho = Swift.max(0.10, TopOptKit.latticeRelativeDensity(topology: "octet", strutRadiusMM: ratio * 4, cellMM: 8))
            let mr = TopOptKit.latticeStrutLawMargin(topology: "octet", rho: rho, vonMisesMPa: vm, pressureMPa: p, buildUp: inputs.up,
                                                     yieldMPa: inputs.yieldMPa, zKnockdown: inputs.zKnockdown)
            if mr >= inputs.target * (1 - 1e-6) { rampHeld += 1 }
        }
        print("STRUCTURAL-AUTO law: \(held) of \(loaded - s.shortVoxels) sized voxels hold \(inputs.target)x; the ramp held \(rampHeld)")
        XCTAssertEqual(held, loaded - s.shortVoxels, "★ every sized voxel holds the target by the check's own law")
        XCTAssertLessThan(rampHeld, held, "RED CONTROL: today's ramp misses the target on loaded voxels")
        // the pure-pressure voxel (von Mises 0, every third from index 2) is sized above the floor where it is loaded
        let pressure = 2 + 3 * 10
        XCTAssertGreaterThan(s.rho[pressure], s.rho[s.rho.count - 1], "★ pure pressure still sizes the struts (two invariants)")
        XCTAssertEqual(s.field.vonMises.count, s.rho.count, "the field holds each voxel's strut / cell")
        XCTAssertGreaterThanOrEqual(Double(s.field.vonMises.min() ?? 0), s.ratioFloor - 1e-6)
    }
    static let kOpenLook = 0.7592 / 4

    func testAHigherMarginNeverLighter() throws {
        let f = Self.field()
        var last: [Float]?
        for m in [1.5, 1.75, 2.0] {
            var i = Self.pa12
            i.margin = m
            let s = try XCTUnwrap(StructuralAuto.size(f, i))
            if let l = last { for e in s.rho.indices { XCTAssertGreaterThanOrEqual(s.rho[e], l[e] - 1e-6, "★ \(m): never lighter") } }
            last = s.rho
        }
    }

    // MARK: 2

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

    func testStructuralAutoSendsTheSizedFieldAndNothingElseChanges() {
        let p = Self.project()
        XCTAssertTrue(StructuralAuto.applies(p), "premise: Structural, Auto, octet, By stress")
        let s = LatticeLayoutPreview.settings(p, referenceMPa: 19)
        XCTAssertTrue(s.byStress && s.demandIsRatio, "★ the field is strut / cell")
        XCTAssertEqual(s.referenceMPa, 1, "★ reference 1 (core reads a field only with one)")
        XCTAssertEqual(s.response, 1)
        XCTAssertFalse(s.cellsByStress, "★ a ratio is not a stress: cell size by stress goes")
        XCTAssertTrue(s.quiltWhereShort, "★ D2")
        XCTAssertFalse(s.allowQuilt, "his K3: no quilt on Auto, but where D2 asks")
        StructuralAuto.quiltWhereShortWired = false
        XCTAssertFalse(LatticeLayoutPreview.settings(p, referenceMPa: 19).quiltWhereShort, "D2 is one switch")
        StructuralAuto.quiltWhereShortWired = true
        // RED CONTROL: Structural Auto through the old branch — the ramp on printed yield / margin
        StructuralAuto.controlRamp = true
        let old = LatticeLayoutPreview.settings(p, referenceMPa: 19)
        StructuralAuto.controlRamp = false
        XCTAssertFalse(old.demandIsRatio, "RED CONTROL: today's ramp")
        XCTAssertEqual(old.referenceMPa, 19, "RED CONTROL: the printed yield over the margin")
        XCTAssertNotEqual(old, s, "RED CONTROL: Structural Auto changed")
        // ★ never widen: everything else is today's, byte for byte (the same with the old branch as with the new)
        let others: [(String, ProjectModel)] = [
            ("Aesthetic Auto", Self.project(stage: .aesthetic)),
            ("Structural Manual", Self.project(manual: true)),
            ("Organic", Self.project(algorithm: "organic")),
            ("Gyroid", Self.project(stage: .aesthetic, topology: "gyroid")),
            ("BCC + Z", Self.project(stage: .aesthetic, topology: "bccz")),
        ]
        for (name, q) in others {
            XCTAssertFalse(StructuralAuto.applies(q), "\(name): never sized")
            let now = LatticeLayoutPreview.settings(q, referenceMPa: 19)
            StructuralAuto.controlRamp = true
            let before = LatticeLayoutPreview.settings(q, referenceMPa: 19)
            StructuralAuto.controlRamp = false
            XCTAssertEqual(now, before, "★ \(name): byte for byte as before")
            XCTAssertFalse(now.demandIsRatio || now.quiltWhereShort, "\(name): neither key")
        }
    }

    func testTheStressTheEngineReadsIsTheSizedField() throws {
        let p = Self.project()
        let m = AppModel(materialsPath: Self.core("src/materials/materials.json"),
                         store: ProjectStore(rootDir: FileManager.default.temporaryDirectory
                            .appendingPathComponent("sa-\(UUID().uuidString)")))
        m.loadMaterials()
        let f = Self.field()
        let base = LatticeLayoutPreview.Stress(key: 7, field: f, referenceMPa: 19)
        let s = StructuralAuto.stress(p, base: base, model: m)
        XCTAssertEqual(s.referenceMPa, 1)
        let sized = try XCTUnwrap(s.field)
        XCTAssertNotEqual(sized.vonMises, f.vonMises, "★ the sized strut / cell, never the stress itself")
        XCTAssertNotEqual(s.key, base.key)
        XCTAssertEqual(StructuralAuto.stress(p, base: base, model: m).key, s.key, "the same inputs: the same key")
        XCTAssertEqual(StructuralAutoStore.shared.sizings, 1, "sized once per inputs (never per frame)")
        // a field with no tensor (a run's own): no field, so the press runs the stage's stress check first
        let bare = LatticeDemandField(vonMises: f.vonMises, nx: f.nx, ny: 1, nz: 1, origin: .zero, spacingMM: 1,
                                      provenance: f.provenance)
        XCTAssertNil(StructuralAuto.stress(p, base: .init(key: 8, field: bare, referenceMPa: 19), model: m).field)
        // the kept round is what the drawing reads (the drawing follows the print file)
        let bk = try XCTUnwrap(StructuralAuto.baseKey(p, base: base, model: m))
        var kept = try XCTUnwrap(StructuralAuto.size(f, try XCTUnwrap(StructuralAuto.inputs(p, model: m)), round: 1))
        kept.key = 99
        StructuralAutoStore.shared.keep(p.id, baseKey: bk, kept)
        XCTAssertEqual(StructuralAuto.stress(p, base: base, model: m).key, 99, "★ the kept round")
        // RED CONTROL: Manual reads the base untouched
        p.latticePageManual = true
        XCTAssertEqual(StructuralAuto.stress(p, base: base, model: m), base, "RED CONTROL: Manual is his own")
    }

    // MARK: 3

    func testTheJobCarriesTheKeysOnlyWhenOn() throws {
        var s = LatticeLayoutSession.Settings()
        let plain = try LatticeFileJob.build(s, modelName: "p.step")
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        let l = try XCTUnwrap(o["layout"] as? [String: Any])
        XCTAssertNil(l["demand_is_ratio"], "every other job: the bytes it was")
        XCTAssertNil(l["quilt_where_short"])
        s.demandIsRatio = true
        s.quiltWhereShort = true
        let sized = try XCTUnwrap(try JSONSerialization.jsonObject(with: try LatticeFileJob.build(s, modelName: "p.step"))
                                    as? [String: Any])
        let sl = try XCTUnwrap(sized["layout"] as? [String: Any])
        XCTAssertEqual(sl["demand_is_ratio"] as? Bool, true, "★ the field is strut / cell")
        XCTAssertEqual(sl["quilt_where_short"] as? Bool, true, "★ D2")
        XCTAssertEqual(LatticeFileJob.fieldKeys["demandIsRatio"], "demand_is_ratio")
        XCTAssertEqual(LatticeFileJob.fieldKeys["quiltWhereShort"], "quilt_where_short")
    }

    // MARK: 4

    func testTheStopRules() {
        typealias A = StructuralAuto
        XCTAssertEqual(A.checksPerPress, 2, "★ D3: two checks per press")
        XCTAssertEqual(A.next(afterCheck: 1, passed: true, saving: 0.02), .stop, "★ the one-check shortcut: within 5 %")
        XCTAssertEqual(A.next(afterCheck: 1, passed: true, saving: 0.12), .anotherCheck, "passing, but round 1 saves 12 %")
        XCTAssertEqual(A.next(afterCheck: 1, passed: false, saving: -0.3), .anotherCheck, "short: fine-tune and check again")
        XCTAssertEqual(A.next(afterCheck: 1, passed: false, saving: nil), .stop, "nothing to fine-tune from")
        XCTAssertEqual(A.next(afterCheck: 2, passed: false, saving: 0.2), .stop, "★ the last check allowed")
        XCTAssertEqual(A.next(afterCheck: 2, passed: false, saving: 0.2, checks: 3), .anotherCheck, "the constant decides")
        // RED CONTROL: the shortcut's share at 0 — a passing check 1 never stops at one
        XCTAssertNotEqual(A.next(afterCheck: 1, passed: true, saving: 0.06), .stop, "RED CONTROL: 6 % is worth a second check")
        let r = { (p: Bool, mm3: Double, m: Double) in A.Round(passed: p, plasticMM3: mm3, margin: m) }
        XCTAssertEqual(A.kept([r(true, 100, 1.9), r(true, 80, 1.55)]), 1, "★ the lightest that passes")
        XCTAssertEqual(A.kept([r(true, 100, 1.9), r(false, 80, 1.3)]), 0, "★ a lighter fail is never kept")
        XCTAssertEqual(A.kept([r(false, 100, 1.2), r(false, 110, 1.4)]), 1, "none passing: the last")
        XCTAssertEqual(A.kept([r(true, 100, 1.6)]), 0)
        XCTAssertEqual(A.short(rounds: [r(false, 100, 1.2), r(false, 120, 1.25)], required: 1.5, shortPlaces: 0), .stiffWalls,
                       "★ the margin rose by less than a third of the aim: the walls")
        XCTAssertEqual(A.short(rounds: [r(false, 100, 1.2), r(false, 120, 1.4)], required: 1.5, shortPlaces: 3), .denseLattice)
        XCTAssertEqual(A.short(rounds: [r(false, 100, 1.2)], required: 1.5, shortPlaces: 0), .solid)
        XCTAssertNil(A.short(rounds: [r(false, 100, 1.2), r(true, 120, 1.6)], required: 1.5, shortPlaces: 0), "holds: no pop-up")
        // the record rides with the result and comes back
        let rec = A.Record(margin: 1.75, rounds: [r(false, 100, 1.3), r(true, 90, 1.8)], keptRound: 1, shortPlaces: 0, quilted: 4)
        let back = A.Record.decode(rec.json)
        XCTAssertEqual(back, rec)
        XCTAssertEqual(rec.savedShare, 0.1, accuracy: 1e-9)
        let report = A.withRecord(Data(#"{"ok": true}"#.utf8), rec)
        XCTAssertEqual(A.Record.of(report: report), rec, "★ in the result's report")
        XCTAssertEqual(RunReportBlocks.decode(reportJSON: report)?.structuralAuto, rec, "★ Results reads it")
    }

    // MARK: 5

    func testTheBarMovesOnlyWhenAStepEnds() {
        var s = StructuralAutoSteps(margin: 1.5)
        XCTAssertEqual(s.items.map(\.words), ["Sizing struts for 150 %", "Checking strength (1 of 2)", "Fine-tuning the struts",
                                              "Checking strength (2 of 2)", "Saving the print file"])
        XCTAssertEqual(s.fraction, 0.2, accuracy: 1e-9, "the sizing is done before the press (on this iPad)")
        let before = s.fraction
        s.apply(.began(.check(1)))
        XCTAssertEqual(s.fraction, before, "★ a step beginning moves nothing (no fake progress)")
        s.apply(.began(.fineTune))
        XCTAssertEqual(s.fraction, 0.4, accuracy: 1e-9, "★ check 1 ended")
        s.apply(.began(.check(2)))
        s.apply(.began(.saving))
        XCTAssertEqual(s.fraction, 0.8, accuracy: 1e-9)
        s.apply(.finished)
        XCTAssertEqual(s.fraction, 1)
        // the shortcut: the steps not taken go, one ticked line says why
        var c = StructuralAutoSteps(margin: 1.75)
        c.apply(.began(.check(1)))
        c.apply(.shortcut(close: true))
        XCTAssertEqual(c.items.map(\.words), ["Sizing struts for 175 %", "Checking strength (1 of 2)", "First check was close enough",
                                              "Saving the print file"])
        XCTAssertEqual(c.items.map(\.done), [true, true, true, false])
        // RED CONTROL: without the shortcut line the skipped steps would read as still to come
        var d = StructuralAutoSteps(margin: 1.5)
        d.apply(.began(.check(1)))
        d.apply(.shortcut(close: false))
        XCTAssertFalse(d.items.contains { $0.words == StructuralAutoCopy.shortcutDone }, "a stop for another reason says nothing")
        XCTAssertFalse(d.items.contains { $0.kind == .check(2) }, "★ never a check that will not come")
    }

    // MARK: 6

    func testEveryCaptionIsFiveWordsAtMostAndPositive() {
        let captions = [StructuralAutoCopy.title, StructuralAutoCopy.sizing(1.5), StructuralAutoCopy.sizing(1.75),
                        StructuralAutoCopy.checking(1, of: 2), StructuralAutoCopy.checking(2, of: 2), StructuralAutoCopy.fineTuning,
                        StructuralAutoCopy.saving, StructuralAutoCopy.shortcutDone, StructuralAutoCopy.sizedFor(1.5),
                        StructuralAutoCopy.sizedFor(2), StructuralAutoCopy.sizedByAuto, StructuralAutoCopy.quiltedLine,
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

    // MARK: 7

    func testANewPartStartsAt150AndCustomHolds175() {
        XCTAssertEqual(SafetyMargin.defaultValue, 1.5, "★ D1: 150 %")
        let d = UserDefaults(suiteName: "sa-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: d)
        XCTAssertEqual(settings.safetyMargin, 1.5, "★ a new install: 150 % for every new part")
        var f = ForceModel()
        settings.apply(to: &f)
        XCTAssertEqual(f.safetyMarginValue, 1.5, "★ a new part starts at 150 %")
        XCTAssertFalse(SafetyMargin.presets.contains { $0.value == 1.75 }, "175 % stays under Custom (his D1)")
        XCTAssertTrue(LatticeSetupWizard.structuralAutoCustomMargins.contains(1.75), "★ … where the row's Custom offers it")
        XCTAssertEqual(try? SafetyMargin.parseCustom("175").get(), 1.75)
        XCTAssertEqual(StructuralAuto.target(margin: 1.5), 1.5 * StructuralAuto.cushion, accuracy: 1e-12)
        XCTAssertEqual(StructuralAuto.target(margin: 1.2), 1.5 * StructuralAuto.cushion, accuracy: 1e-12, "never under 150 %")
    }

    // MARK: 8 — the chain on a stub Mac

    /// fields.bin v1 (core/include/topopt/fields.hpp) of one block on an nx × 1 × 1 grid at the origin, 1 mm voxels.
    static func fieldsBin(_ vm: [Float]) -> Data {
        var d = Data([1, 0, 0, 0])
        func i32(_ v: Int32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func i64(_ v: Int64) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 8)) }
        func f64(_ v: Double) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 8)) }
        func f32(_ v: Float) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        i32(Int32(vm.count)); i32(1); i32(1); f64(0); f64(0); f64(0); f64(1); f64(1); i32(1); i32(0)
        f64(0.25); f64(41); i32(0); i32(0); i64(Int64(vm.count)); i64(0); i64(0)
        for v in vm { f32(v) }
        return d
    }

    /// The stub Mac's files for one verdict, the check's lattice stress exactly the stage's (round 1 sizes as round 0 did).
    func chain(verdict: String) throws -> (files: URL, model: URL, stage: LatticeDemandField) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sa-chain-\(UUID().uuidString)")
        let files = dir.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let stage = Self.field()
        let vm: [Float] = (0..<stage.nx).map { e in
            Float(stage.stressTensor.withUnsafeBufferPointer { StructuralAuto.vonMises($0, at: 6 * e) })
        }
        try Self.fieldsBin(vm).write(to: files.appendingPathComponent("fields.bin"))
        let strength = LatticeFileButtonTests.strength(verdict, accepted: true, margin: verdict == "pass" ? 1.7 : 1.2,
                                                       strutsPass: verdict == "pass")
        try LatticeFileButtonTests.report(strength).write(to: files.appendingPathComponent(LatticeFileJob.reportName))
        try LatticeFileButtonTests.stl().write(to: files.appendingPathComponent(LatticeFileJob.outputName))
        let model = dir.appendingPathComponent("p.step")
        try Data("ISO-10303-21;".utf8).write(to: model)
        return (files, model, stage)
    }

    final class Said: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [StructuralAutoSteps.Event] = []
        func add(_ e: StructuralAutoSteps.Event) { lock.lock(); events.append(e); lock.unlock() }
        var all: [StructuralAutoSteps.Event] { lock.lock(); defer { lock.unlock() }; return events }
    }

    private func runChain(verdict: String) throws -> (o: OptimizeOutcome, posts: Int, said: [StructuralAutoSteps.Event], id: UUID,
                                                      store: StructuralAutoStore) {
        let c = try chain(verdict: verdict)
        let w = try StubWorker(filesDir: c.files, events: [], fingerprint: CoreFingerprint.value)
        defer { w.stop() }
        let config = RemoteRunnerConfig(host: "127.0.0.1", port: Int(w.port), expectedFingerprint: CoreFingerprint.value)
        let round0 = try XCTUnwrap(StructuralAuto.size(c.stage, Self.pa12))
        let job = LatticeFileJob.ForPart(json: Data(#"{"mode": "lattice_file", "model": "p.step", "demand": "demand.bin"}"#.utf8),
                                         modelPath: c.model.path, demand: LatticeFileJob.demandFile(round0.field))
        let ask = LatticeFileButton.StructuralAutoAsk(round0: round0, stage: c.stage, inputs: Self.pa12, baseKey: 42,
                                                      largestCellMM: 8, lineMM: 0.45)
        let said = Said(), store = StructuralAutoStore(), id = UUID()
        let defaults = UserDefaults(suiteName: "sa-chain-\(UUID().uuidString)")!
        let inputs = FileManager.default.temporaryDirectory.appendingPathComponent("sa-inputs-\(UUID().uuidString)")
        let run = LatticeFileButton.structuralAutoRunner(config: config, job: job, ask: ask, projectName: "P",
                                                         strengthJob: Data(#"{"mode": "lattice_part"}"#.utf8), densityGCm3: 1.01,
                                                         defaults: defaults, inputsRoot: inputs, store: store,
                                                         onStep: { said.add($0) })
        let req = RunRequest(modelPath: c.model.path, material: "PA12", materialsPath: "", rulesPath: "", resolution: 64,
                             projectName: "P", projectID: id)
        let o = try run(req, { _, _, _ in true }, { _ in })
        return (o, w.posts().count, said.all, id, store)
    }

    func testACheckThatFallsShortIsFineTunedAndCheckedAgain() throws {
        let r = try runChain(verdict: "fail")
        XCTAssertEqual(r.posts, 2, "★ two jobs: check 1, then check 2 of the fine-tuned struts")
        let rec = try XCTUnwrap(StructuralAuto.Record.of(report: r.o.reportJSON), "★ the record rides with the result")
        XCTAssertEqual(rec.rounds.count, 2)
        XCTAssertEqual(rec.keptRound, 1, "none passing: the last")
        XCTAssertNotNil(r.store.kept(r.id, baseKey: 42), "★ the drawing follows the round kept")
        XCTAssertEqual(r.said, [.began(.check(1)), .began(.fineTune), .began(.check(2)), .began(.saving), .finished],
                       "★ the card's steps, each as it really begins")
    }

    func testACheckCloseEnoughStopsAtOne() throws {
        let r = try runChain(verdict: "pass")
        XCTAssertEqual(r.posts, 1, "★ the one-check shortcut: round 1 would save under 5 %")
        let rec = try XCTUnwrap(StructuralAuto.Record.of(report: r.o.reportJSON))
        XCTAssertEqual(rec.rounds.count, 1)
        XCTAssertEqual(rec.keptRound, 0)
        XCTAssertNil(r.store.kept(r.id, baseKey: 42), "round 0 is the one on screen already")
        XCTAssertEqual(r.said, [.began(.check(1)), .shortcut(close: true), .began(.saving), .finished])
        XCTAssertTrue(r.o.variants.first?.accepted ?? false)
    }
}
#endif
