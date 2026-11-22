// Notes23TimingLogTests — his ask 2026-11-22 (afternoon notes on release 13): "Set up a process that prints the time it took and
// what changes occurred for each generation (sample/draft/print) and print it so it can be accessible by you after some
// testing." GenerationTimingLog: one JSON line per generation in Documents/TopOptTiming/generations.jsonl (here a temporary
// folder), with what went in and `changed` (what moved since the last line of its kind); the newest 2,000 kept; written off
// the main thread. A lay's start and end write exactly one line, with the engine's own stage times.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes23TimingLogTests: XCTestCase {

    private var dir: URL!
    private var sharedDirBefore: URL!
    private var accurateBefore = false

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("timing-\(UUID().uuidString)", isDirectory: true)
        sharedDirBefore = GenerationTimingLog.shared.directory
        accurateBefore = AppSettings.shared.latticePrintAccurate
    }
    override func tearDown() {
        GenerationTimingLog.shared.directory = sharedDirBefore
        AppSettings.shared.latticePrintAccurate = accurateBefore
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func inputs(look percent: Double, file: String = "2040 Extrusion Stand.step") -> GenerationTimingLog.Inputs {
        var i = GenerationTimingLog.Inputs()
        i.part = .init(file: file, faces: 42, triangles: 12_000)
        var look = LatticeOrganicLook(); look.mode = .grown; look.lookPercent = percent
        var l = LatticeSettings(enabled: true); l.algorithm = "organic"; l.organicLook = look
        i.lattice = l
        i.organic = ["Front face": look]
        i.printParams = .fdmDefault
        i.values["quality"] = .text("draft")
        return i
    }

    /// ★ One line holds what he asked for: the kind, when, how long, how it ended, the struts, where it ran, the device, the
    /// memory and heat, the core, the part's file NAME, every setting that went in, and the engine's stage times.
    func testALineHoldsEverythingHeAskedFor() throws {
        let log = GenerationTimingLog(); log.directory = dir
        let p = log.begin(.draft, inputs: inputs(look: 30), started: Date(timeIntervalSinceNow: -2))
        log.end(p, .done, struts: 80_489, stages: ["layMS": 1500, "vinesMS": 300])
        log.end(p, .failed, reason: "a second end")   // the first end wins
        log.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("generations.jsonl").path))
        let r = log.records()
        XCTAssertEqual(r.count, 1, "★ one line per generation")
        let rec = try XCTUnwrap(r.first)
        XCTAssertEqual(rec["kind"] as? String, "draft")
        XCTAssertEqual(rec["outcome"] as? String, "done")
        XCTAssertEqual(rec["struts"] as? Int, 80_489)
        XCTAssertGreaterThanOrEqual(rec["seconds"] as? Double ?? 0, 2)
        XCTAssertNotNil(ISO8601DateFormatter.withFraction.date(from: rec["start"] as? String ?? ""), "★ the start, ISO")
        XCTAssertEqual(rec["ranOn"] as? String, GenerationTimingLog.thisDevice)
        let device = try XCTUnwrap(rec["device"] as? [String: Any])
        XCTAssertFalse((device["model"] as? String ?? "").isEmpty)
        XCTAssertNotNil(device["system"] as? String)
        XCTAssertGreaterThan(device["memoryMB"] as? Int ?? 0, 0)
        XCTAssertEqual(rec["core"] as? String, CoreFingerprint.value, "★ the core build")
        XCTAssertNotNil((rec["thermal"] as? [String: Any])?["start"])
        XCTAssertGreaterThan((rec["memory"] as? [String: Any])?["peakResidentMB"] as? Double ?? 0, 0, "★ the app's peak memory")
        let ins = try XCTUnwrap(rec["inputs"] as? [String: Any])
        XCTAssertEqual((ins["part"] as? [String: Any])?["file"] as? String, "2040 Extrusion Stand.step", "★ its name, not its path")
        XCTAssertEqual((ins["part"] as? [String: Any])?["faces"] as? Int, 42)
        let organic = try XCTUnwrap((ins["organic"] as? [String: Any])?["Front face"] as? [String: Any], "★ each group's settings")
        XCTAssertEqual(organic["mode"] as? String, "grown")
        XCTAssertEqual(organic["lookPercent"] as? Double, 30)
        XCTAssertEqual((ins["lattice"] as? [String: Any])?["algorithm"] as? String, "organic", "★ the whole lattice settings")
        XCTAssertNotNil(ins["printParams"])
        XCTAssertEqual((rec["stages"] as? [String: Any])?["layMS"] as? Double, 1500, "★ the engine's stage times as they came")
        XCTAssertEqual(rec["firstOfKind"] as? Bool, true)
        XCTAssertEqual((rec["changed"] as? [String: Any])?.count, 0)
    }

    /// ★ `changed`: the keys that differ from the last line of the SAME kind, old → new — also after the app starts again (read
    /// back from the file). RED CONTROL: a line of another kind between them is not what it is compared with.
    func testChangedSaysWhatMovedSinceTheLastOfItsKind() throws {
        let log = GenerationTimingLog(); log.directory = dir
        log.end(log.begin(.draft, inputs: inputs(look: 30)), .done, struts: 10)
        log.end(log.begin(.sample, inputs: inputs(look: 99)), .done)
        log.end(log.begin(.draft, inputs: inputs(look: 8)), .done, struts: 12)
        log.flush()
        var r = log.records()
        XCTAssertEqual(r.count, 3)
        let changed = try XCTUnwrap(r[2]["changed"] as? [String: String])
        XCTAssertEqual(changed["organic.Front face.lookPercent"], "30 \u{2192} 8", "★ old → new: \(changed)")
        XCTAssertEqual(changed["lattice.organicLook.lookPercent"], "30 \u{2192} 8")
        XCTAssertNil(changed["values.quality"], "unchanged keys are not listed")
        XCTAssertFalse(changed.values.contains { $0.hasPrefix("99") }, "RED CONTROL: never against another kind's line")
        XCTAssertEqual(r[1]["firstOfKind"] as? Bool, true, "the first sample")
        // the app started again: the next draft is compared with the last draft on file
        let again = GenerationTimingLog(); again.directory = dir
        again.end(again.begin(.draft, inputs: inputs(look: 8, file: "Stand v2.step")), .cancelled, reason: "a newer change")
        again.flush()
        r = again.records()
        let moved = try XCTUnwrap(r.last?["changed"] as? [String: String])
        XCTAssertEqual(moved, ["part.file": "2040 Extrusion Stand.step \u{2192} Stand v2.step"], "★ read back from the file")
        XCTAssertEqual(r.last?["outcome"] as? String, "cancelled")
        XCTAssertEqual(r.last?["reason"] as? String, "a newer change")
    }

    /// ★ The file keeps the newest lines (2,000 in the app; ten here).
    func testTheFileKeepsTheNewestLines() throws {
        XCTAssertEqual(GenerationTimingLog.keepLinesDefault, 2000)
        let log = GenerationTimingLog(); log.directory = dir; log.keepLines = 10
        for n in 0..<25 {
            var i = GenerationTimingLog.Inputs(); i.values["n"] = .number(Double(n))
            log.end(log.begin(.sample, inputs: i), .done)
        }
        log.flush()
        let r = log.records()
        XCTAssertEqual(r.count, 10, "★ capped")
        XCTAssertEqual(((r.first?["inputs"] as? [String: Any])?["values"] as? [String: Any])?["n"] as? Double, 15, "the oldest dropped")
        XCTAssertEqual(((r.last?["inputs"] as? [String: Any])?["values"] as? [String: Any])?["n"] as? Double, 24, "the newest kept")
    }

    /// ★ Never written on the main thread; the iPad's file is in the app's Documents, where `devicectl` copies it from.
    func testWrittenOffTheMainThreadIntoDocuments() throws {
        let src = try FlexibleSource.code("GenerationTimingLog.swift")
        let end = try XCTUnwrap(src.range(of: "public func end(_ p: Pending"))
        XCTAssertTrue(String(src[end.upperBound...].prefix(600)).contains("queue.async"), "★ appended on the log's own queue")
        XCTAssertTrue(src.contains("for: .documentDirectory"), "★ Documents/TopOptTiming on the iPad")
        XCTAssertEqual(GenerationTimingLog.folderName, "TopOptTiming")
        XCTAssertEqual(GenerationTimingLog.fileName, "generations.jsonl")
    }

    // MARK: the lays

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
    private func settle(_ preview: LatticeLayoutPreview) async throws {
        let end = Date().addingTimeInterval(600)
        while preview.laying, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(preview.laying)
    }

    /// ★ A lay's start and end write ONE line: the Draft (Print-accurate preview off), with the engine's own stage times; the
    /// print file's exact lay, one more; a lattice shown again from memory, a "restored" line with no lay time.
    func testALayStartAndEndWritesOneLine() async throws {
        GenerationTimingLog.shared.directory = dir
        AppSettings.shared.latticePrintAccurate = false
        let p = try organicProject()
        let st = try stress(p, key: 71)
        let preview = LatticeLayoutPreview()
        preview.update(project: p, on: true, stress: st)
        try await settle(preview)
        GenerationTimingLog.shared.flush()
        var r = GenerationTimingLog.shared.records()
        XCTAssertEqual(r.count, 1, "★ one lay, one line: \(r.map { $0["kind"] ?? "?" })")
        let draft = try XCTUnwrap(r.first)
        XCTAssertEqual(draft["kind"] as? String, "draft")
        XCTAssertEqual(draft["outcome"] as? String, "done")
        XCTAssertEqual(draft["struts"] as? Int, preview.organicNumbers?.segments, "★ the struts on screen")
        let stages = try XCTUnwrap(draft["stages"] as? [String: Double])
        for k in ["layMS", "traceMS", "readMS", "barsMS", "strands", "vinesMS", "measureMS", "layWallMS"] {
            XCTAssertNotNil(stages[k], "★ the stage \(k): \(stages)")
        }
        XCTAssertEqual(stages["layMS"] ?? -1, preview.organicNumbers?.ms ?? -2, accuracy: 0.01, "★ the engine's own lay time")
        let ins = try XCTUnwrap(draft["inputs"] as? [String: Any])
        XCTAssertEqual((ins["part"] as? [String: Any])?["file"] as? String, p.importedFile?.name)
        XCTAssertNotNil((ins["organic"] as? [String: Any])?["Whole part"], "★ the Organic settings as laid")

        preview.update(project: p, on: true, stress: st, exact: true)   // the print file asks the exact lattice
        try await settle(preview)
        GenerationTimingLog.shared.flush()
        r = GenerationTimingLog.shared.records()
        XCTAssertEqual(r.count, 2, "★ the exact lay: one more line")
        XCTAssertEqual(r.last?["kind"] as? String, "exact")
        XCTAssertEqual(r.last?["outcome"] as? String, "done")
        XCTAssertEqual((r.last?["changed"] as? [String: String])?.isEmpty, true, "the same settings: nothing moved")

        var look = p.lattice.organicLook!; look.lookPercent = 8; p.lattice.organicLook = look
        preview.update(project: p, on: true, stress: st)
        try await settle(preview)
        look.lookPercent = 5; p.lattice.organicLook = look
        preview.update(project: p, on: true, stress: st)   // made before: shown from memory
        XCTAssertFalse(preview.laying)
        GenerationTimingLog.shared.flush()
        r = GenerationTimingLog.shared.records()
        XCTAssertEqual(r.map { $0["kind"] as? String ?? "?" }, ["draft", "exact", "draft", "restored"])
        XCTAssertEqual((r[2]["changed"] as? [String: String])?["organic.Whole part.lookPercent"], "5 \u{2192} 8", "★ what moved")
        XCTAssertEqual((r[3]["stages"] as? [String: Double])?["layMS"], 0, "★ no lay")
        preview.clear()
    }
}

private extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
}
