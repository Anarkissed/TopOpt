import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

/// ★ 362 11-23 (his Organic run: the strengthening ended at 18:23:20 and the print file's job reached the Mac at 18:33:35,
/// because the iPad drove the chain step by step and he had switched apps): the iPad asks the Mac to chain the file itself
/// ("then" = file) and follows the Mac's own file job (`next`). A worker that does not chain gets the old two-job path.
final class MacChainNotes26Tests: XCTestCase {

    private func fixture() throws -> (dir: URL, files: URL, model: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-chain-\(UUID().uuidString)")
        let files = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: files.appendingPathComponent("r2"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        func put(_ name: String, _ d: Data) throws { try d.write(to: files.appendingPathComponent(name)) }
        let summary: [String: Any] = ["ok": true, "code": "done", "why": "", "passing": true,
                                      "strengthened": "r2/strengthened.json", "rounds_fixed": 1,
                                      "rounds": [["round": 0], ["round": 1]]]
        try put("strengthen.json", try JSONSerialization.data(withJSONObject: summary))
        try put("r2/strengthened.json", Data(#"{"version": 2, "additions": "additions.bin"}"#.utf8))
        try put("r2/additions.bin", Data([7, 7, 7, 7]))
        let tet = LatticeOrganicFileTests.model([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                                                [(0, 1, 2), (0, 1, 3), (0, 2, 3), (1, 2, 3)])
        try put("lattice.3mf", LatticeOrganicFileTests.zip([("3D/3dmodel.model", tet, true)]))
        let report = #"{"ok": true, "file": "lattice.3mf", "slicer_supports": "off", "layout": {"bars": 10}, "#
            + #""mesh": {"mm3": 100, "part_mm3": 1000}, "print_check": {"clean": true}, "strength": {"accepted": true, "#
            + #""verdict": "pass", "struts_pass": true, "margin_worst_case": 1.7, "safety_margin": 1.5, "mass_grams": 12, "#
            + #""struts": {"smallest_margin": 1.62}}}"#
        try put(LatticeFileJob.reportName, Data(report.utf8))
        let model = dir.appendingPathComponent("p.step")
        try Data("ISO-10303-21;".utf8).write(to: model)
        return (dir, files, model)
    }

    private func run(_ w: StubWorker, model: URL) throws -> OptimizeOutcome {
        let config = RemoteRunnerConfig(host: "127.0.0.1", port: Int(w.port), expectedFingerprint: CoreFingerprint.value)
        let job = LatticeFileJob.ForPart(json: Data(#"{"mode": "lattice_file"}"#.utf8), modelPath: model.path, demand: nil,
                                         tensor: Data("TOTENSOR".utf8))
        let req = RunRequest(modelPath: model.path, material: "PLA", materialsPath: "", rulesPath: "", resolution: 64,
                             projectName: "chain")
        return try LatticeFileButton.organicRunner(config: config, job: job, projectName: "chain",
                                                   strengthJob: Data(#"{"mode": "lattice_part"}"#.utf8), densityGCm3: 1.24)(
            req, { _, _, _ in true }, { _ in })
    }

    func testTheMacMakesTheFileItselfAndTheIPadFollowsIt() throws {
        let f = try fixture()
        let w = try StubWorker(filesDir: f.files, events: [], fingerprint: CoreFingerprint.value,
                               aliases: ["chainedfile"], next: "chainedfile")
        defer { w.stop() }
        let o = try run(w, model: f.model)
        let posts = w.posts().map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(posts.count, 1, "★ ONE job sent: the strengthening; the Mac makes the file itself")
        XCTAssertTrue(posts[0].contains("name=\"run\"") && posts[0].contains("organic-strengthen"), "the strengthening")
        XCTAssertTrue(posts[0].contains("name=\"then\"") && posts[0].contains("\r\n\r\nfile"), "★ asked to chain: then = file")
        XCTAssertTrue(w.requested(suffix: "/jobs/chainedfile"), "★ the Mac's own file job followed by its id")
        XCTAssertTrue(w.requested(suffix: "/jobs/chainedfile/files/lattice.3mf"), "and its file fetched from it")
        XCTAssertEqual(o.variants.first?.meshIndices.count, 12, "the file read back as the Results mesh")
        XCTAssertEqual(o.variants.first?.accepted, true)
    }

    func testAWorkerThatDoesNotChainGetsTheTwoJobs() throws {
        // RED CONTROL: no `next` on the record (an older worker): the iPad sends the file's job itself, as before
        let f = try fixture()
        let w = try StubWorker(filesDir: f.files, events: [], fingerprint: CoreFingerprint.value)
        defer { w.stop() }
        _ = try run(w, model: f.model)
        let posts = w.posts().map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(posts.count, 2, "RED CONTROL: no next, two jobs: the strengthening, then the file")
        XCTAssertTrue(posts[1].contains("name=\"strengthened\""), "the second sends the last round's lattice")
    }
}
