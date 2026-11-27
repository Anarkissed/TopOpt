// PrintResolutionTests — ★ his 11-25 ("Offer print resolutions when exporting. Full detail vs medium vs coarse. All with
// information about their file size estimates and resolution."): the report's three levels read; each level's size (the
// made file's own, the others' estimate scaled by how the made one's came out); the job made again at a level; the flow's
// pick (the made level at once, another on the Mac, then shared; no Mac, a stop, a changed lattice: centred pop-ups).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

/// A print file's report as core writes it (file_result_json): made at `made`, as `file`.
func printResolutionReport(made: String = "full", file: String = "lattice.stl", bytes: Int = 7_688_384,
                           triangles: Int = 153_766, cells: Int = 32, bars: Int = 0, up: [Double]? = nil) -> [String: Any] {
    var r: [String: Any] = [
        "ok": true, "file": file, "file_bytes": bytes,
        "layout": ["cells": cells, "bars": bars], "mesh": ["triangles": triangles], "print_check": ["clean": true],
        "print_resolution": ["level": made, "levels": [
            ["level": "full", "name": "Full detail", "words": "surface within 0.02 mm", "surface_mm": 0.02, "triangles": 150_000,
             "stl_bytes": 7_500_084, "threemf_bytes": 1_800_000, "ms": 61_000],
            ["level": "medium", "name": "Medium", "words": "surface within 0.05 mm", "surface_mm": 0.05, "triangles": 60_000,
             "stl_bytes": 3_000_084, "threemf_bytes": 720_000, "ms": 31_000],
            ["level": "coarse", "name": "Coarse", "words": "surface within 0.1 mm", "surface_mm": 0.1, "triangles": 30_000,
             "stl_bytes": 1_500_084, "threemf_bytes": 360_000, "ms": 24_000],
        ]],
    ]
    if let up {
        r["print_frame"] = ["up": up, "rotation_row_major": [0, 0, -1, 0, 1, 0, 1, 0, 0], "translation_mm": [0, 0, 0]]
    }
    return r
}

@MainActor
final class PrintResolutionTests: XCTestCase {
    override func tearDown() {
        PrintResolutionFlow.shared.reset()
        PrintResolutionFlow.controlNoChoice = false
        AppPopups.shared.current = nil
        super.tearDown()
    }

    private func words(_ s: String) -> Int { s.split(separator: " ").count }

    func testTheReportsLevelsAreRead() throws {
        let f = try XCTUnwrap(PrintResolutionFacts.decode(printResolutionReport()))
        XCTAssertEqual(f.made, "full")
        XCTAssertEqual(f.levels.map(\.id), ["full", "medium", "coarse"])
        XCTAssertEqual(f.levels.map(\.name), ["Full detail", "Medium", "Coarse"])
        XCTAssertEqual(f.levels[1].words, "surface within 0.05 mm")
        XCTAssertEqual(f.levels[1].seconds ?? 0, 31, accuracy: 1e-9)
        XCTAssertEqual(f.madeFormat, "stl")
        XCTAssertEqual(f.cells, 32)
        XCTAssertNil(f.up)
        // the print file's facts carry them (Results reads them there); an Organic file's report has none
        XCTAssertEqual(LatticeFileFacts.decode(printResolutionReport())?.resolutions, f)
        var organic = printResolutionReport()
        organic.removeValue(forKey: "print_resolution")
        XCTAssertNil(LatticeFileFacts.decode(organic)?.resolutions, "RED CONTROL: no block, no levels")
        XCTAssertNotNil(LatticeFileFacts.decode(organic), "the facts themselves still read")
        // the up it stands on
        let stood = try XCTUnwrap(PrintResolutionFacts.decode(printResolutionReport(up: [1, 0, 0])))
        XCTAssertEqual(stood.up, SIMD3(1, 0, 0))
    }

    func testEachLevelsSize() throws {
        let f = try XCTUnwrap(PrintResolutionFacts.decode(printResolutionReport()))
        // the made level: its own file, exactly
        XCTAssertEqual(f.bytes(f.levels[0], format: "stl").bytes, 7_688_384)
        XCTAssertFalse(f.bytes(f.levels[0], format: "stl").estimated)
        // ... and as an STL of its triangles, exactly, when the made file is a 3MF
        let mf = try XCTUnwrap(PrintResolutionFacts.decode(printResolutionReport(file: "lattice.3mf", bytes: 1_900_000)))
        XCTAssertEqual(mf.bytes(mf.levels[0], format: "stl").bytes, 84 + 50 * 153_766)
        XCTAssertFalse(mf.bytes(mf.levels[0], format: "stl").estimated)
        // another level: the estimate scaled by how the made one's came out (153,766 made against 150,000 estimated)
        let m = f.bytes(f.levels[1], format: "stl")
        XCTAssertTrue(m.estimated)
        XCTAssertEqual(Double(m.bytes), 3_000_084 * 153_766.0 / 150_000.0, accuracy: 1)
        XCTAssertNotEqual(m.bytes, f.levels[1].stlBytes, "RED CONTROL: not the raw estimate")
        // a 3MF's, by the made 3MF's own bytes over its estimate
        let c = mf.bytes(mf.levels[2], format: "3mf")
        XCTAssertEqual(Double(c.bytes), 360_000 * 1_900_000.0 / 1_800_000.0, accuracy: 1)
    }

    func testTheWordsAreShort() {
        for s in [PrintResolutionCopy.made, PrintResolutionCopy.size(7_688_384, estimated: true), PrintResolutionCopy.macTime(30),
                  PrintResolutionCopy.macTime(150), PrintResolutionCopy.macTime(5400), PrintResolutionCopy.title,
                  "surface within 0.02 mm", "surface within 0.05 mm", "surface within 0.1 mm"] {
            XCTAssertLessThanOrEqual(words(s), 5, "★ his rule, five words: \"\(s)\"")
        }
        XCTAssertEqual(PrintResolutionCopy.size(7_688_384, estimated: false), "7.7 MB")
        XCTAssertEqual(PrintResolutionCopy.size(110_000_000, estimated: true), "About 110 MB")
        XCTAssertEqual(PrintResolutionCopy.macTime(150), "About 3 min on Mac")
        XCTAssertEqual(PrintResolutionCopy.macTime(20), "Under a minute on Mac")
    }

    func testTheJobMadeAgainAtALevel() throws {
        let job = try JSONSerialization.data(withJSONObject: [
            "mode": "lattice_file", "model": "model.stl", "output": "lattice.stl", "strength_job": "strength_job.json",
            "print_frame": ["up": [0, 0, 1]], "layout": ["topology": "gyroid"]], options: [.sortedKeys])
        let out = try XCTUnwrap(PrintResolutionJob.retarget(job, level: "medium", format: "3mf", up: nil))
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        XCTAssertEqual(o["print_resolution"] as? String, "medium")
        XCTAssertEqual(o["file_format"] as? String, "3mf")
        XCTAssertNil(o["strength_job"], "★ no strength check: the lattice is the same")
        XCTAssertNil(o["print_frame"], "★ standing as the made file stood (as placed)")
        XCTAssertEqual((o["layout"] as? [String: Any])?["topology"] as? String, "gyroid", "every other key as it was")
        let stood = try XCTUnwrap(PrintResolutionJob.retarget(job, level: "coarse", format: "stl", up: SIMD3(1, 0, 0)))
        let s = try XCTUnwrap(try JSONSerialization.jsonObject(with: stood) as? [String: Any])
        XCTAssertEqual((s["print_frame"] as? [String: Any])?["up"] as? [Double], [1, 0, 0])
    }

    func testOffered() throws {
        let f = PrintResolutionFacts.decode(printResolutionReport())
        XCTAssertTrue(PrintResolutionFlow.offers(f, kept: true))
        XCTAssertFalse(PrintResolutionFlow.offers(nil, kept: true), "no levels (Organic, older): Export as before")
        XCTAssertFalse(PrintResolutionFlow.offers(f, kept: false), "the file not kept here: Export as before")
        PrintResolutionFlow.controlNoChoice = true
        XCTAssertFalse(PrintResolutionFlow.offers(f, kept: true), "RED CONTROL: before his 11-25, no choice")
    }

    /// A host whose Mac makes the file (or fails as told).
    final class Stub {
        var calls: [(level: String, format: String, up: SIMD3<Double>?, onMac: Bool)] = []
        var mac = true
        var fail: Error?
        var report = printResolutionReport(made: "medium")
        func host() -> PrintResolutionHost {
            PrintResolutionHost(macReady: { [unowned self] in mac }, make: { [unowned self] level, format, up, onMac, _, said in
                calls.append((level, format, up, onMac))
                said(PrintResolutionCopy.makingFile)
                if let fail { throw fail }
                return (Data("solid \(level)".utf8), report)
            })
        }
    }

    private func settle(_ flow: PrintResolutionFlow) async {
        for _ in 0..<50 where flow.making != nil { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testPickingALevel() async throws {
        let flow = PrintResolutionFlow.shared
        let stub = Stub()
        flow.host = stub.host()
        let f = try XCTUnwrap(PrintResolutionFacts.decode(printResolutionReport(up: [1, 0, 0])))
        var exported = 0
        // the made level: at once, as before; the Mac is never asked
        flow.open(f, format: "stl", stem: "Stand-PA12-37pct") { exported += 1 }
        XCTAssertNotNil(flow.ask)
        flow.pick("full")
        XCTAssertEqual(exported, 1)
        XCTAssertNil(flow.ask)
        XCTAssertTrue(stub.calls.isEmpty)
        // another: made on the Mac standing as the made file stands, then handed to the share sheet
        flow.open(f, format: "stl", stem: "Stand-PA12-37pct") { exported += 1 }
        flow.pick("medium")
        XCTAssertEqual(flow.making?.level.id, "medium", "★ the making card")
        XCTAssertEqual(flow.making?.expected ?? 0, 31, accuracy: 1e-9, "★ its time, the Mac's estimate")
        await settle(flow)
        XCTAssertNil(flow.making)
        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(stub.calls.first?.level, "medium")
        XCTAssertEqual(stub.calls.first?.format, "stl")
        XCTAssertEqual(stub.calls.first?.up, SIMD3(1, 0, 0))
        XCTAssertEqual(stub.calls.first?.onMac, true)
        let url = try XCTUnwrap(flow.share)
        XCTAssertEqual(url.lastPathComponent, "Stand-PA12-37pct-medium.stl")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "solid medium")
        XCTAssertEqual(exported, 1)
        // the same level again: the file already made this session
        flow.share = nil
        flow.open(f, format: "stl", stem: "Stand-PA12-37pct") {}
        flow.pick("medium")
        XCTAssertEqual(flow.share, url)
        XCTAssertEqual(stub.calls.count, 1, "★ not made twice")
    }

    func testAChangedLatticeNoMacAndAStopArePopUps() async throws {
        let flow = PrintResolutionFlow.shared
        let stub = Stub()
        flow.host = stub.host()
        let f = try XCTUnwrap(PrintResolutionFacts.decode(printResolutionReport()))
        // the settings changed since: another lattice, never handed out
        stub.report = printResolutionReport(made: "coarse", cells: 40)
        flow.open(f, format: "stl", stem: "S") {}
        flow.pick("coarse")
        await settle(flow)
        XCTAssertNil(flow.share, "★ a different lattice is never exported")
        XCTAssertEqual(AppPopups.shared.current?.title, PrintResolutionCopy.changedTitle)
        AppPopups.shared.current = nil
        // no Mac: Try again, Make it on the iPad, Cancel
        stub.report = printResolutionReport(made: "coarse")
        stub.mac = false
        flow.open(f, format: "stl", stem: "S") {}
        flow.pick("coarse")
        XCTAssertEqual(AppPopups.shared.current?.title, PrintResolutionCopy.noMacTitle)
        XCTAssertEqual(AppPopups.shared.second?.title, PrintResolutionCopy.onIPad)
        XCTAssertEqual(AppPopups.shared.dismissTitle, PrintResolutionCopy.cancel)
        AppPopups.shared.second?.run()
        await settle(flow)
        XCTAssertEqual(stub.calls.last?.onMac, false, "★ made on this iPad")
        XCTAssertNotNil(flow.share)
        flow.share = nil
        AppPopups.shared.current = nil
        // the Mac stopped answering mid-way: the no-Mac card; any other stop: the plain one, with Try again
        stub.mac = true
        stub.fail = LatticeFileRun.Failure("The Mac did not answer (timed out)", transient: true)
        flow.open(f, format: "3mf", stem: "S") {}
        flow.pick("medium")
        await settle(flow)
        XCTAssertEqual(AppPopups.shared.current?.title, PrintResolutionCopy.noMacTitle)
        AppPopups.shared.current = nil
        stub.fail = LatticeFileRun.Failure("mesh_failed")
        flow.open(f, format: "3mf", stem: "S") {}
        flow.pick("medium")
        await settle(flow)
        XCTAssertEqual(AppPopups.shared.current?.title, PrintResolutionCopy.failedTitle)
        XCTAssertFalse(AppPopups.shared.current?.text.contains("mesh_failed") ?? true, "★ plain words, never the engine's")
        XCTAssertEqual(AppPopups.shared.action?.title, PrintResolutionCopy.tryAgain)
        XCTAssertNil(flow.share)
    }
}
