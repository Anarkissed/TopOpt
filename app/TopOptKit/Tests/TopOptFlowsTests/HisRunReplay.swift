// HisRunReplay — the maintainer's own run, replayed through the app's REAL remote
// runner, as a helper any test file can drive (task 2026-08-08-lattice-variant-
// margin-tolerance, S2/S3).
//
// Worker job ca62f91cba4b422d (M2_verticalStand.step, resolution 128, four rungs,
// all accepted, all latticed). Its `report.json`, its four
// `variant_XXX_lattice.report.json` certification receipts, its `fields.bin`
// scalars and the exact `VARIANT`/`LATTICE` checkpoint lines its CLI printed are
// captured verbatim under evidence/2026-08-07-lattice-variants-on-screen/run_his/
// and served here over a real HTTP socket by `StubWorker`.
//
// WHY A SHARED HELPER NOW. PR 311 built this replay inside one XCTestCase's
// private methods. Two more task areas need the same run — the recommendation
// rule (S2) and the "the lattices really are in the app" gate (S3) — and a second
// hand-rolled copy of the fixture is how two tests come to disagree about what
// his run contains. One builder, one set of captured bytes.
//
// TWO THINGS ARE NOT VERBATIM, and they are the same two PR 311 named: the solid
// meshes are stand-in cubes (their geometry is not what any of this is about and
// his are 14–17 MB each), and the four latticed meshes are represented by their
// real BYTE COUNTS via HEAD rather than their 5.17 GB of bytes.

import Foundation
import XCTest
import TopOptKit
@testable import TopOptFlows

enum HisRunReplay {

    static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()

    static let runDir = repoRoot.appendingPathComponent(
        "evidence/2026-08-07-lattice-variants-on-screen/run_his")

    /// The real sizes of his four latticed meshes on the worker's disk.
    static let latticedMeshBytes: [String: Int] = [
        "variant_068_lattice.stl": 1_954_879_484,
        "variant_052_lattice.stl": 1_420_059_884,
        "variant_038_lattice.stl": 1_058_859_084,
        "variant_026_lattice.stl": 740_360_884,
    ]

    /// His four rungs in ladder order, with both of each rung's masses.
    ///
    ///   rung   solid (g)   latticed (g)
    ///   0.68     543.73        215.16
    ///   0.52     473.32        239.93
    ///   0.38     412.47        244.78
    ///   0.26     360.30        246.38
    static let rungs: [Double] = [0.68, 0.52, 0.38, 0.26]

    // MARK: - the fixture

    /// A directory the stub worker serves: his captured artifacts, plus stand-in
    /// solid meshes.
    ///
    /// - Parameter refusingLatticeOnRungs: rewrite `lattice_accepted` to false in
    ///   the named rungs' receipts. Nothing else changes — the mass, the margin and
    ///   the mesh size stay his — so a test can ask what the ranking does with a
    ///   lattice the composite certification refused without inventing a run.
    ///
    /// - Parameter withLatticedMeshes: also write a small, per-rung-DISTINCT
    ///   stand-in for each `variant_XXX_lattice.stl`. His are 740 MB – 1.95 GB, and
    ///   a test that has to prove EXPORT works needs bytes on the wire, not a size
    ///   header. Distinct per rung so an export that fetched the wrong rung's file
    ///   fails rather than coincidentally matching.
    static func makeFilesDir(refusingLatticeOnRungs refusing: [Double] = [],
                             withLatticedMeshes: Bool = false) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("his-run-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["report.json", "fields.bin"] {
            try FileManager.default.copyItem(at: runDir.appendingPathComponent(name),
                                             to: dir.appendingPathComponent(name))
        }
        let refuseTags = Set(refusing.map(tag(for:)))
        for vf in rungs {
            let t = tag(for: vf)
            let name = "variant_\(t)_lattice.report.json"
            var text = try String(contentsOf: runDir.appendingPathComponent(name),
                                  encoding: .utf8)
            if refuseTags.contains(t) {
                text = text.replacingOccurrences(of: "\"lattice_accepted\": true",
                                                 with: "\"lattice_accepted\": false")
            }
            try text.write(to: dir.appendingPathComponent(name), atomically: true,
                           encoding: .utf8)
            try cubeSTL().write(to: dir.appendingPathComponent("variant_\(t).stl"))
            if withLatticedMeshes {
                try cubeSTL(scale: Float(10 + 10 * vf))
                    .write(to: dir.appendingPathComponent("variant_\(t)_lattice.stl"))
            }
        }
        return dir
    }

    static func tag(for vf: Double) -> String { String(format: "%03d", Int((vf * 100).rounded())) }

    /// His run's stdout, replayed as the SSE events the worker produces from it: a
    /// `VARIANT` line becomes a typed `variant` event, and a `LATTICE` line — which
    /// the worker has no typed event for — falls through its `_line_to_event`
    /// catch-all as `{"type": "log", "line": …}`, verbatim.
    ///
    /// - Parameter refusingLatticeOnRungs: also flip `lattice_accepted=1` to `0` on
    ///   those rungs' checkpoint lines, so the line and the receipt agree.
    static func events(refusingLatticeOnRungs refusing: [Double] = []) throws -> [String] {
        let text = try String(contentsOf: runDir.appendingPathComponent("checkpoint_lines.txt"),
                              encoding: .utf8)
        let refuseTags = Set(refusing.map(tag(for:)))
        var out: [String] = []
        for line in text.split(separator: "\n") {
            var s = String(line)
            if s.hasPrefix("VARIANT ") {
                var kv: [String: String] = [:]
                for tok in s.dropFirst("VARIANT ".count).split(separator: " ") {
                    guard let eq = tok.firstIndex(of: "=") else { continue }
                    kv[String(tok[tok.startIndex..<eq])] = String(tok[tok.index(after: eq)...])
                }
                let mesh = (kv["mesh"]! as NSString).lastPathComponent
                out.append("""
                {"type":"variant","vf":\(kv["vf"]!),"achieved":\(kv["achieved"]!),\
                "printed":\(kv["printed"]!),"margin":\(kv["margin"]!),\
                "accepted":true,"mesh":"\(mesh)"}
                """)
            } else if s.hasPrefix("LATTICE ") {
                if let vf = latticeLineVF(s), refuseTags.contains(tag(for: vf)) {
                    s = s.replacingOccurrences(of: "lattice_accepted=1",
                                               with: "lattice_accepted=0")
                }
                let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                out.append("{\"type\":\"log\",\"line\":\"\(escaped)\"}")
            }
        }
        out.append("{\"type\":\"done\"}")
        return out
    }

    private static func latticeLineVF(_ s: String) -> Double? {
        for tok in s.split(separator: " ") where tok.hasPrefix("vf=") {
            return Double(tok.dropFirst(3))
        }
        return nil
    }

    static func makeRequest() throws -> RunRequest {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("his-run-replay-model.step")
        try Data("ISO-10303-21;\nENDSEC;\n".utf8).write(to: URL(fileURLWithPath: path))
        return RunRequest(modelPath: path, material: "PLA", materialsPath: "",
                          rulesPath: "", resolution: 128, projectName: "M2 vertical stand",
                          anchorFaceIDs: [18], loadGroups: [], minimizePlastic: true)
    }

    // MARK: - driving it

    /// Run his four-rung ladder through the app's real `RemoteRun` against the stub
    /// worker, and hand back the outcome plus every path the client asked for.
    static func run(refusingLatticeOnRungs refusing: [Double] = [],
                    sizeOverrides: [String: Int] = latticedMeshBytes)
        throws -> (outcome: OptimizeOutcome, requests: [String]) {
        let dir = try makeFilesDir(refusingLatticeOnRungs: refusing)
        defer { try? FileManager.default.removeItem(at: dir) }
        let worker = try StubWorker(filesDir: dir,
                                    events: try events(refusingLatticeOnRungs: refusing),
                                    fingerprint: CoreFingerprint.value,
                                    sizeOverrides: sizeOverrides)
        defer { worker.stop() }
        let config = RemoteRunnerConfig(
            host: "127.0.0.1", port: Int(worker.port),
            expectedFingerprint: CoreFingerprint.value,
            inactivityGrace: 3, requestTimeout: 30, controlTimeout: 5)
        let defaults = UserDefaults(suiteName: "his-run-replay-\(UUID().uuidString)")!
        let run = RemoteRun(config: config, request: try makeRequest(),
                            progress: { _, _, _ in true }, onVariant: { _ in },
                            defaults: defaults)
        return (try run.run(), worker.log())
    }

    @MainActor
    static func resultsModel(refusingLatticeOnRungs refusing: [Double] = [])
        throws -> ResultsModel {
        let (outcome, _) = try run(refusingLatticeOnRungs: refusing)
        return ResultsModel(projectName: "M2 vertical stand", outcome: outcome,
                            materialName: "PLA", yieldStrengthMPa: 50,
                            materialDensityGCm3: 1.24)
    }

    /// Like `resultsModel`, but the worker STAYS UP for the duration of `body` and
    /// serves real (small, per-rung distinct) latticed meshes, so a test can drive
    /// an actual transfer or export rather than a size header. `body` also receives
    /// the directory the worker is serving, to compare an export against its source
    /// byte for byte.
    @MainActor
    static func withLiveWorker(
        _ body: (ResultsModel, URL) throws -> Void) throws {
        let dir = try makeFilesDir(withLatticedMeshes: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // No size overrides: the stand-in meshes are really there, so HEAD reports
        // their real size and the transfer budget prices what it would move.
        let worker = try StubWorker(filesDir: dir, events: try events(),
                                    fingerprint: CoreFingerprint.value,
                                    sizeOverrides: [:])
        defer { worker.stop() }
        let config = RemoteRunnerConfig(
            host: "127.0.0.1", port: Int(worker.port),
            expectedFingerprint: CoreFingerprint.value,
            inactivityGrace: 3, requestTimeout: 30, controlTimeout: 5)
        let defaults = UserDefaults(suiteName: "his-run-live-\(UUID().uuidString)")!
        let run = RemoteRun(config: config, request: try makeRequest(),
                            progress: { _, _, _ in true }, onVariant: { _ in },
                            defaults: defaults)
        let outcome = try run.run()
        let model = ResultsModel(projectName: "M2 vertical stand", outcome: outcome,
                                 materialName: "PLA", yieldStrengthMPa: 50,
                                 materialDensityGCm3: 1.24)
        model.latticeMeshTransfer = RemoteLatticeMeshTransfer(config: config,
                                                              jobID: worker.jobID)
        try body(model, dir)
    }

    private static func cubeSTL(scale: Float = 10) -> Data {
        let s: Float = scale
        let v: [(Float, Float, Float)] = [
            (0, 0, 0), (s, 0, 0), (s, s, 0), (0, s, 0),
            (0, 0, s), (s, 0, s), (s, s, s), (0, s, s)]
        let faces = [(0, 3, 2), (0, 2, 1), (4, 5, 6), (4, 6, 7),
                     (0, 1, 5), (0, 5, 4), (2, 3, 7), (2, 7, 6),
                     (1, 2, 6), (1, 6, 5), (0, 4, 7), (0, 7, 3)]
        var d = Data(count: 80)
        var count = UInt32(faces.count).littleEndian
        withUnsafeBytes(of: &count) { d.append(contentsOf: $0) }
        for (a, b, c) in faces {
            for _ in 0..<3 { var z = Float(0); withUnsafeBytes(of: &z) { d.append(contentsOf: $0) } }
            for i in [a, b, c] {
                for comp in [v[i].0, v[i].1, v[i].2] {
                    var f = comp
                    withUnsafeBytes(of: &f) { d.append(contentsOf: $0) }
                }
            }
            var attr = UInt16(0)
            withUnsafeBytes(of: &attr) { d.append(contentsOf: $0) }
        }
        return d
    }
}
