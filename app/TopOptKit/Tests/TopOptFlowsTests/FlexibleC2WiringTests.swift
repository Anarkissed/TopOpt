// FlexibleC2WiringTests — C2 WIRING W1 (B9, 2026-11-08). #361's C2 core (B0–B2c, kPressApiVersion 8; claude/flexible-squish-maths
// 5de78975) is merged into B9 at 02571c07, and the app's run job states what that core now reads (the C2 plan's "#362 after" of
// B1a and B1b): `no_include_region: "no_lattice"` and each edge or corner press's `flat_prism.apex_mm`. The goldens
// (FlexibleAngledGoldenTests) prove every OTHER byte unchanged by writing with `FlexibleJob.sendsC2W1` off; this file proves the job
// as sent = that job + exactly these keys, through core's own parser and core's own runner, and core's four new refusal codes in
// plain words. Each RED CONTROL runs inside its test.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleC2WiringTests: XCTestCase {
    typealias F = FlexibleFlatPrismFixtures

    override func setUp() {
        super.setUp()
        FlexibleBackend.sendsPresses = true
    }

    override func tearDown() {
        FlexibleJob.sendsC2W1 = true
        FlexibleBackend.sendsPresses = true
        super.tearDown()
    }

    static func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
    static func block(_ json: String) throws -> [String: Any] { try XCTUnwrap(try object(json)["flexible"] as? [String: Any]) }
    static func faces(_ json: String) throws -> [[String: Any]] { try XCTUnwrap(try block(json)["faces"] as? [[String: Any]]) }
    static func encode(_ o: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self)
    }

    /// `on` with exactly W1's keys taken out (no_include_region; flat_prism on the entries `pressAt`), as a value to compare.
    static func withoutW1(_ on: String, pressAt: [Int] = []) throws -> NSDictionary {
        var b = try block(on)
        b.removeValue(forKey: "no_include_region")
        var fs = try faces(on)
        for k in pressAt { fs[k].removeValue(forKey: "flat_prism") }
        b["faces"] = fs
        var o = try object(on)
        o["flexible"] = b
        return NSDictionary(dictionary: o)
    }

    // MARK: - no_include_region

    /// The run job says no include region means NO lattice (core's C2 B1a item 7; the app's own `.noFacePrism` rule, now core's
    /// too). The job as sent = the pre-wiring job + exactly that key; core's parser takes it; the scene job (which reads no faces)
    /// does not carry it. RED CONTROL: an unknown value is refused by core's parser, so core does read the key.
    func testTheRunJobSaysNoIncludeRegionMeansNoLattice() throws {
        let i = FlexibleStageTests.inputs(FlexibleStageTests.settings())
        let on = try FlexibleJob.runJobJSON(i)
        let off = try FlexibleAngledGoldens.preC2 { try FlexibleJob.runJobJSON(i) }
        XCTAssertEqual(try Self.block(on)["no_include_region"] as? String, "no_lattice")
        XCTAssertNil(try Self.block(off)["no_include_region"], "the pre-wiring job")
        XCTAssertTrue(try Self.withoutW1(on).isEqual(to: try Self.object(off)), "★ the job as sent = the pre-wiring job + exactly no_include_region")
        XCTAssertNoThrow(try FlexibleCore.parseJobBlock(on), "★ core's own parser takes it")
        let scene = try FlexibleJob.sceneJobJSON(i, fallbackMaterial: "varioshore_tpu")
        XCTAssertNil(try Self.block(scene)["no_include_region"], "the scene job reads no faces: unchanged")
        // ★ RED CONTROL
        let bad = on.replacingOccurrences(of: "\"no_lattice\"", with: "\"nope\"")
        XCTAssertNotEqual(bad, on)
        XCTAssertThrowsError(try FlexibleCore.parseJobBlock(bad), "★ RED CONTROL: core reads the key — an unknown value is refused")
        print("FLEX-C2W1 no_include_region: sent, parsed; RED 'nope' refused")
    }

    // MARK: - flat_prism

    /// An edge or corner press's entry carries `flat_prism.apex_mm` (its apex, beside its press_direction; h = its
    /// deepest_squish_mm); with no apex none is written; the job = the pre-wiring job + exactly the two keys; core's parser takes it.
    /// RED CONTROL: a two-number apex is refused by core's parser, so core does read flat_prism.
    func testAPressEntryCarriesItsFlatPrism() throws {
        var i = FlexibleStageTests.inputs(FlexibleStageTests.settings())
        let map = FlexMap(mode: "centre_edge", x: .flat, y: .flat, centreEdge: FlexCurve(x: [0, 1], y: [0, 1]), deepestMM: 3)
        let d = simd_normalize(SIMD3<Double>(-1, 0, -1))
        i.presses = [FlexibleJob.PressEntry(id: UUID(), regions: [2, 3], direction: d, weightN: 49.03325, map: map,
                                            apex: SIMD3(100, 50, 20))]
        let on = try FlexibleJob.runJobJSON(i)
        let fs = try Self.faces(on)
        let press = try XCTUnwrap(fs.last)
        XCTAssertNotNil(press["face_region_ids"], "the press entry is last")
        let fp = try XCTUnwrap(press["flat_prism"] as? [String: Any], "★ flat_prism on the press")
        XCTAssertEqual(fp["apex_mm"] as? [Double], [100, 50, 20], "★ its apex")
        XCTAssertEqual(press["deepest_squish_mm"] as? Double, 3, "h = deepest_squish_mm")
        XCTAssertTrue(fs.dropLast().allSatisfy { $0["flat_prism"] == nil }, "a face entry has none")
        let off = try FlexibleAngledGoldens.preC2 { try FlexibleJob.runJobJSON(i) }
        XCTAssertTrue(try Self.withoutW1(on, pressAt: [fs.count - 1]).isEqual(to: try Self.object(off)),
                      "★ the job as sent = the pre-wiring job + exactly no_include_region and flat_prism")
        XCTAssertNoThrow(try FlexibleCore.parseJobBlock(on), "★ core's own parser takes it")
        // no apex (a press with no strip) → no flat_prism
        i.presses = [FlexibleJob.PressEntry(id: UUID(), regions: [2, 3], direction: d, weightN: 49.03325, map: map)]
        XCTAssertNil(try Self.faces(try FlexibleJob.runJobJSON(i)).last?["flat_prism"])
        // ★ RED CONTROL: core reads flat_prism (a two-number apex is refused)
        var o = try Self.object(on)
        var b = try Self.block(on)
        var bad = fs
        bad[bad.count - 1]["flat_prism"] = ["apex_mm": [100.0, 50.0]]
        b["faces"] = bad
        o["flexible"] = b
        XCTAssertThrowsError(try FlexibleCore.parseJobBlock(try Self.encode(o)), "★ RED CONTROL: a two-number apex is refused")
        print("FLEX-C2W1 flat_prism: sent \(fp), parsed; RED [100, 50] refused")
    }

    /// ★ ON HIS PAD (A1_0003 + the Top's face-prism; Groups 2–5 resting so the edges group is sent alone): Edge 16's entry carries the
    /// apex of FlexibleFlatPrism.cut(of:) to the bit and h = that cut's depth, and core's own RUN takes the job (no refusal). Measured
    /// beside it: core's press stack with and without the prism (columns, the deepest column entry past the apex, the longest lattice
    /// run). RED CONTROL: core's stack from the pre-wiring job keeps a column the prism drops, or (said) none on this pad.
    func testEdge16IsSentWithItsFlatPrismAndCoreRunsIt() async throws {
        let (r, m) = try await F.hisPad(self)
        for f in [2, 3, 4, 5] { m.rest(f) }
        try await FlexibleSquishFixture.settle(m, "his pad, 2-5 resting")
        let press = try await F.commit(m, try await F.edge16(m).c, kg: 5)
        try await FlexibleHisProject.waitFor(180, "Edge 16: core's verdict") {
            guard let v = m.pressSupport[press.id] else { return false }
            if v.inJob { return true }
            switch v.reason { case .designing?, .notStacked("")?, nil: return false; default: return true }
        }
        await m.waitForIdle()
        XCTAssertEqual(m.pressSupport[press.id]?.inJob, true, "★ Edge 16 is in the job on core v8: \(m.pressSupport[press.id]?.line ?? "")")
        let p = try XCTUnwrap(m.press(press.id))
        let cut = try XCTUnwrap(FlexibleFlatPrism.cut(of: p))
        // the edges group's own send when a hold offers one (as FlexibleR7E2Tests sends it), else the whole job
        let g = try XCTUnwrap(m.squeezeGroup(ofPress: press.id))
        let resting = Set(m.coreHold?.fixes.first { $0.scope == "Group \(g.number) only" }?.resting ?? [])
        let apexT = try XCTUnwrap(m.pressRegistrations[press.id]).apexT   // core's t of the apex (its press frame)
        let on = try m.runJobJSON(resting: resting)
        let entry = try XCTUnwrap(try Self.faces(on).first { $0["face_region_ids"] != nil || $0["press_direction"] != nil })
        let apex = try XCTUnwrap((entry["flat_prism"] as? [String: Any])?["apex_mm"] as? [Double])
        XCTAssertEqual(apex.map(\.bitPattern), [cut.apex.x, cut.apex.y, cut.apex.z].map(\.bitPattern), "★ the cut's apex, to the bit")
        XCTAssertEqual(entry["deepest_squish_mm"] as? Double, cut.depthMM, "★ h = the cut's depth")
        XCTAssertNoThrow(try FlexibleCore.parseJobBlock(on))
        let dir = (try XCTUnwrap(r.project.importedFile).path as NSString).deletingLastPathComponent
        func run(_ job: String) throws -> FlexRunInfo {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("flex-c2w1-\(UUID().uuidString)").path
            defer { try? FileManager.default.removeItem(atPath: out) }
            return try FlexibleCore.runJob(jobJSON: job, jobDir: dir, outDir: out, materialsPath: FlexibleHisProject.materialsPath,
                                           fingerprint: CoreFingerprint.value)
        }
        let withPrism = try run(on)
        XCTAssertNil(withPrism.refusal, "★ core's own runner takes the job: \(withPrism.refusal.map { "\($0.code): \($0.reason)" } ?? "")")
        let off = try FlexibleAngledGoldens.preC2 { try m.runJobJSON(resting: resting) }
        let without = try run(off)
        func measure(_ i: FlexRunInfo) -> String {
            guard let st = i.stacks.last else { return "no stack" }
            let past = st.columns.map { $0.entryT - apexT }.max() ?? 0
            let longest = st.columns.map(\.latticeMM).max() ?? 0
            return "columns \(st.columns.count) · deepest entry past A \(String(format: "%.3f", past)) mm (h \(String(format: "%.3f", cut.depthMM))) · longest run \(String(format: "%.2f", longest)) mm"
        }
        print("FLEX-C2W1 his pad Edge 16 WITH flat_prism: \(measure(withPrism))")
        print("FLEX-C2W1 his pad Edge 16 RED (pre-wiring job): \(measure(without)) · refusal \(without.refusal?.code ?? "-")")
        if let a = withPrism.stacks.last, let b = without.stacks.last {
            XCTAssertLessThanOrEqual(a.columns.count, b.columns.count, "★ the prism only drops columns")
            XCTAssertTrue(a.columns.allSatisfy { $0.entryT - apexT <= cut.depthMM + 1e-9 }, "★ every column enters at or before the plane")
        }
    }

    // MARK: - refusals in plain words

    /// Core's four new codes (C2 B1a, B1b, B2b) read as one short line each, never core's raw sentence; combination_not_reachable
    /// says it is the solver's finding, not a proof. RED CONTROL: an unknown code still falls back to core's first sentence.
    func testCoreC2RefusalsInPlainWords() {
        let want: [String: String] = [
            "no_lattice_region": "Core refused it: no face is set to Lattice",
            "press_stack_failed": "Core refused it: an edge or corner press can\u{2019}t be stacked",
            "no_lattice_under_press": "Core refused it: a press has no lattice under its cut",
            "combination_not_reachable": "Core refused it: its solver found no lattice for every group (not proven impossible)",
        ]
        for (code, line) in want {
            let got = FlexibleCoreRunReport.refusalLine(FlexRefusal(code: code, reason: "core's long sentence. More."))
            XCTAssertEqual(got, line, code)
        }
        // ★ RED CONTROL
        XCTAssertEqual(FlexibleCoreRunReport.refusalLine(FlexRefusal(code: "c2_unknown", reason: "core's long sentence. More.")),
                       "Core refused it: core's long sentence")
    }
}
