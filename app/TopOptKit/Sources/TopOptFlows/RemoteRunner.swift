// RemoteRunner — run the optimizer on a LAN desktop and drive it from the iPad
// (handoff 093, LAN compute offload / STEP 2). It sits BESIDE `RunModel.bridge
// Runner` (the on-device default) and satisfies the SAME `RunModel.Runner`
// contract, so the existing progress readout (PR 107) and streamed-variant path
// (PR 109) work against it unchanged: remote runs surface the exact same
// `progress`/`onVariant` callbacks a local run does.
//
// Local stays the default. Remote is opt-in: construct a `RunModel` with
// `runner: RunModel.remoteRunner(RemoteRunnerConfig(host:port:expectedFingerprint:))`.
// A typed IP/host is enough for v1; mDNS/Bonjour discovery is a later nicety and
// is cross-platform (Avahi on Linux), so nothing here assumes Apple-only.
//
// The remote server is `tools/topopt-worker`, which wraps `topopt-cli`. Because
// STEP 0 made the CLI produce the SAME part the app produces, a remote run
// returns what a local run would have — PROVIDED the worker's core matches the
// app's (see the version-skew guard below).
//
// STATUS (handoff 097 — LAN offload Tier 2): this file is now COMPILED and
// exercised on the iOS simulator against the real worker on localhost. It is not
// covered by the Linux CI host (no Xcode); its verification standard is
// `xcodebuild` on the package + the simulator end-to-end in handoff 097.
//
// Honest limitations (see docs/handoffs/097 + 093-lan-offload.md STEP 3):
//   * The worker delivers each variant's MESH + the scalar report (volume
//     fraction, margins, orientation, stresses, settings). It does NOT deliver the
//     per-voxel vonMises / displacement / stressTensor fields, the playback
//     keyframes, or the mass — the CLI writes meshes + report.json, not those
//     arrays. So remote variants render with their margins/settings, but the
//     stress overlay, flex animation, mass readout and playback are UNAVAILABLE.
//     The outcome is flagged `computedRemotely` so the results screen shows those
//     as "computed on Mac — n/a in this build" rather than a plausible 0 g / blank
//     overlay (a wrong-but-plausible readout is a reject-class bug here). Full
//     result serialisation over the wire is the tracked follow-up.
//
// 097 review-carry fixes applied here (were open on the 093 draft):
//   (1) `smooth_factor` is sent so remote meshes match the local tricubic
//       smoothing (bridge.cpp kSmoothExportFactor = 2); without it the CLI would
//       export the raw v3 iso-surface and remote parts would differ from local.
//   (2) a failed mesh fetch FAILS THE RUN with a clear message — never a silent
//       empty part on screen (an empty part that looks like a real result is the
//       worst failure mode).
//   (3) the authoritative streamed mesh basenames drive final assembly, so meshes
//       are never re-derived from a guessed filename (the report's volume_fraction
//       is the ACHIEVED fraction, but files are named by the REQUESTED fraction —
//       reconstructing the name silently fetched the wrong / no file).

import Foundation
import TopOptKit
#if canImport(os)
import os
#endif

/// Where the LAN worker lives, and which core it MUST be running.
public struct RemoteRunnerConfig: Sendable {
    public let host: String
    public let port: Int
    /// The core build fingerprint (git commit) THIS app was built against. The
    /// worker's `/health` fingerprint must equal it or the run is refused — two
    /// cores that differ silently produce different parts (STEP 3d). Wire this to
    /// the same build id the CLI reports (`topopt-cli --version`).
    public let expectedFingerprint: String
    /// Overall wall-clock ceiling for a remote run (a Fine+box run is minutes).
    public let timeout: TimeInterval

    public init(host: String, port: Int = 8757,
                expectedFingerprint: String, timeout: TimeInterval = 28800) {
        self.host = host
        self.port = port
        self.expectedFingerprint = expectedFingerprint
        self.timeout = timeout
    }

    var baseURL: URL { URL(string: "http://\(host):\(port)")! }
}

/// A remote-run failure, mapped to a message the run flow surfaces like any other.
public struct RemoteRunError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

public extension RunModel {

    /// Build a `Runner` that offloads the run to a LAN worker. Drop-in beside
    /// `bridgeRunner`; the run flow cannot tell the difference beyond where the
    /// compute happens.
    static func remoteRunner(_ config: RemoteRunnerConfig) -> Runner {
        return { request, progress, onVariant in
            try RemoteRun(config: config, request: request,
                          progress: progress, onVariant: onVariant).run()
        }
    }
}

// ---------------------------------------------------------------------------
// One remote run. Synchronous (the Runner contract is `throws -> OptimizeOutcome`
// and RunModel calls it on a background queue), so it blocks on URLSession with a
// semaphore rather than adopting async/await.

final class RemoteRun: NSObject, URLSessionDataDelegate {
    private let config: RemoteRunnerConfig
    private let request: RunRequest
    private let progress: (Int, Int, Int) -> Bool
    private let onVariant: (OptimizeOutcome) -> Void

    private var jobID: String?
    private var buffer = Data()
    private var streamDone = false
    private var streamError: String?
    private let doneSignal = DispatchSemaphore(value: 0)
    private var cancelled = false

    /// The AUTHORITATIVE per-variant record built from the VARIANT stream events,
    /// in ladder order: each carries the mesh basename the worker actually wrote
    /// (not a reconstructed guess) and the geometry already fetched for the live
    /// streamed-variant screen. `assembleFinalOutcome` reuses these — joining the
    /// scalar report by order — so a variant's mesh is never re-derived from the
    /// report's ACHIEVED volume_fraction (files are named by the REQUESTED one).
    private struct StreamedVariant {
        let requestedVF: Double
        let achievedVF: Double        // optimizer-achieved (continuous) — report join key
        let printedFraction: Double   // printed/count basis — the savings basis (104)
        let margin: Double
        let accepted: Bool
        let meshName: String
        let vertices: [Float]
        let indices: [Int32]
    }
    /// Guards `streamed` — appended on the URLSession delegate queue, read back on
    /// the run thread after `doneSignal`. (The semaphore already establishes the
    /// happens-before; the lock keeps the read/write pair explicit and safe.)
    private let streamedLock = NSLock()
    private var streamed: [StreamedVariant] = []

    #if canImport(os)
    private static let log = Logger(subsystem: "app.topopt", category: "remote")
    #endif

    init(config: RemoteRunnerConfig, request: RunRequest,
         progress: @escaping (Int, Int, Int) -> Bool,
         onVariant: @escaping (OptimizeOutcome) -> Void) {
        self.config = config
        self.request = request
        self.progress = progress
        self.onVariant = onVariant
    }

    // MARK: run

    func run() throws -> OptimizeOutcome {
        // 1) VERSION-SKEW GUARD (STEP 3d). Refuse a worker whose core differs from
        //    ours BEFORE running — a silent core mismatch is a different product.
        let health = try getJSON(config.baseURL.appendingPathComponent("health"))
        let fp = (health["fingerprint"] as? String) ?? "unknown"
        guard fp == config.expectedFingerprint else {
            throw RemoteRunError(
                "worker core mismatch: worker \(fp), app \(config.expectedFingerprint). " +
                "Refusing to run — a different core produces a different part. " +
                "Rebuild the worker's topopt-cli from the same commit.")
        }

        // 2) SUBMIT: POST the STEP/STL + a job.json built from the request.
        let jobJSON = try buildJobJSON()
        let modelData = try Data(contentsOf: URL(fileURLWithPath: request.modelPath))
        let modelName = (request.modelPath as NSString).lastPathComponent
        jobID = try postJob(model: modelData, modelName: modelName, jobJSON: jobJSON)

        // 3) STREAM events. `openEvents` drives the callbacks; we block until a
        //    terminal event (done/error/cancelled) or the timeout.
        openEvents()
        let waited = doneSignal.wait(timeout: .now() + config.timeout)
        if waited == .timedOut {
            cancelRemote()
            throw RemoteRunError("remote run timed out after \(Int(config.timeout))s")
        }
        if let e = streamError { throw RemoteRunError(e) }
        if cancelled {
            // Match the local cancel outcome: a cancelled run yields no accepted set.
            return OptimizeOutcome(variants: [], stoppedOnMargin: false,
                                   cancelled: true, acceptedCount: 0,
                                   computedRemotely: true)
        }

        // 4) ASSEMBLE the final outcome from report.json + the exported meshes.
        return try assembleFinalOutcome()
    }

    // MARK: request -> job.json

    /// Map the RunRequest to the CLI job schema (handoff 093). STEP parts use the
    /// "loads" block with RAW face ids (the id form the app's selection produces,
    /// which the CLI now accepts). STL parts use the self-weight + no-fixture path
    /// — represented here as an empty loads block so the CLI's min-x clamp
    /// fallback applies (mirrors bridgeRunner's STL branch).
    /// Export smoothing the CLI must apply so a remote mesh matches what the app's
    /// local bridge produces. MUST equal the bridge's `kSmoothExportFactor`
    /// (bridge.cpp) — the local path re-extracts every variant's iso-surface at 2×
    /// (tricubic Catmull-Rom) before handing it to the app, so a worker exporting
    /// at the CLI's default of 1 (raw v3 mesh) would return a visibly different,
    /// coarser part. Kept as a documented mirror (Swift can't read the C++
    /// constexpr); if the bridge factor changes, change this with it.
    static let smoothExportFactor = 2

    private func buildJobJSON() throws -> Data {
        var job: [String: Any] = [
            "model": (request.modelPath as NSString).lastPathComponent,
            "material": request.material,
            "mode": "minimize_plastic",
            "resolution": request.resolution,
            "output": ["report": "report.json", "mesh_format": "stl",
                       "mesh_prefix": "variant",
                       // 097 fix (1): match the local bridge's export smoothing.
                       "smooth_factor": Self.smoothExportFactor],
        ]
        if let box = request.designBox {
            job["design_box"] = ["min": [box.min.x, box.min.y, box.min.z],
                                 "max": [box.max.x, box.max.y, box.max.z]]
            if !request.keepOutBoxes.isEmpty {
                job["keep_outs"] = request.keepOutBoxes.map {
                    ["min": [$0.min.x, $0.min.y, $0.min.z],
                     "max": [$0.max.x, $0.max.y, $0.max.z]]
                }
            }
        }
        if request.isStepModel {
            var loads: [String: Any] = [
                "minimize_plastic": request.minimizePlastic,
                "build_dir": [request.buildDirection.x, request.buildDirection.y,
                              request.buildDirection.z],
            ]
            if !request.anchorFaceIDs.isEmpty {
                loads["anchor_face_ids"] = request.anchorFaceIDs
            }
            if !request.loadGroups.isEmpty {
                loads["groups"] = request.loadGroups.map { g -> [String: Any] in
                    ["face_ids": g.faceIDs,
                     "force": [g.force.x, g.force.y, g.force.z]]
                }
            }
            if request.infillPercent >= 0 {
                loads["infill_percent"] = request.infillPercent
            }
            // Handoff 100 — forward "Keep clear" clearances so a Mac worker running
            // topopt-cli honours protected holes IDENTICALLY to the local bridge
            // (both feed the same build_production_loadcase). A distance left at 0 is
            // omitted so the CLI fills the same geometry-derived suggestion.
            if !request.clearances.isEmpty {
                loads["clearances"] = request.clearances.map { c -> [String: Any] in
                    var entry: [String: Any] = [
                        "face_id": c.faceID,
                        "kind": c.kind == .face ? "face" : "bolt",
                    ]
                    if c.concentricMarginMM > 0 { entry["concentric_margin_mm"] = c.concentricMarginMM }
                    if c.axialClearanceMM > 0 { entry["axial_clearance_mm"] = c.axialClearanceMM }
                    if c.slabDepthMM > 0 { entry["slab_depth_mm"] = c.slabDepthMM }
                    return entry
                }
            }
            job["loads"] = loads
        } else {
            // STL: no faces. Empty loads => the CLI clamps the min-x boundary and
            // runs self-weight, matching bridgeRunner's STL path.
            job["loads"] = ["build_dir": [0, 0, 1]]
        }
        return try JSONSerialization.data(withJSONObject: job)
    }

    // MARK: HTTP

    private lazy var eventSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = config.timeout
        cfg.timeoutIntervalForResource = config.timeout
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private func getJSON(_ url: URL) throws -> [String: Any] {
        let (data, resp) = try syncGET(url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw RemoteRunError("unexpected response from \(url.path)") }
        return obj
    }

    private func syncGET(_ url: URL) throws -> (Data, URLResponse) {
        var out: (Data, URLResponse)?
        var err: Error?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { d, r, e in
            if let d = d, let r = r { out = (d, r) } else { err = e }
            sem.signal()
        }.resume()
        sem.wait()
        if let out = out { return out }
        throw RemoteRunError("request failed: \(url.path): \(err?.localizedDescription ?? "no response")")
    }

    /// Fetch one variant's exported mesh by basename and parse it. THROWS on any
    /// failure (transport error, non-200, or a body that is not a usable STL) —
    /// 097 fix (2): a missing/corrupt mesh must surface as a run failure, never as
    /// a silently-empty part that renders as a plausible-but-wrong blank result.
    private func fetchMesh(named name: String) throws -> ([Float], [Int32]) {
        guard let id = jobID else { throw RemoteRunError("no job id for mesh \(name)") }
        let url = config.baseURL.appendingPathComponent("jobs")
            .appendingPathComponent(id).appendingPathComponent("files")
            .appendingPathComponent(name)
        let (data, resp) = try syncGET(url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw RemoteRunError("could not fetch variant mesh \"\(name)\" from the " +
                "worker (HTTP \(code)). The run produced a result on the Mac but its " +
                "geometry could not be transferred — not showing an empty part.")
        }
        let mesh = parseBinarySTL(data)
        guard !mesh.0.isEmpty, !mesh.1.isEmpty else {
            throw RemoteRunError("variant mesh \"\(name)\" arrived empty or unreadable " +
                "(\(data.count) bytes) — not showing an empty part.")
        }
        return mesh
    }

    private func postJob(model: Data, modelName: String, jobJSON: Data) throws -> String {
        let boundary = "topopt-\(UUID().uuidString)"
        var body = Data()
        func part(_ headers: String, _ payload: Data) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(headers.data(using: .utf8)!)
            body.append("\r\n\r\n".data(using: .utf8)!)
            body.append(payload)
            body.append("\r\n".data(using: .utf8)!)
        }
        part("Content-Disposition: form-data; name=\"step\"; filename=\"\(modelName)\"\r\n" +
             "Content-Type: application/octet-stream", model)
        part("Content-Disposition: form-data; name=\"job\"; filename=\"job.json\"\r\n" +
             "Content-Type: application/json", jobJSON)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: config.baseURL.appendingPathComponent("jobs"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        var out: Data?; var err: Error?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, _, e in out = d; err = e; sem.signal() }.resume()
        sem.wait()
        guard let data = out,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["job_id"] as? String
        else { throw RemoteRunError("submit failed: \(err?.localizedDescription ?? "no job_id")") }
        return id
    }

    private func openEvents() {
        guard let id = jobID else { return }
        let url = config.baseURL.appendingPathComponent("jobs").appendingPathComponent(id).appendingPathComponent("events")
        eventSession.dataTask(with: url).resume()
    }

    private func cancelRemote() {
        guard let id = jobID else { return }
        var req = URLRequest(url: config.baseURL.appendingPathComponent("jobs").appendingPathComponent(id))
        req.httpMethod = "DELETE"
        URLSession.shared.dataTask(with: req).resume()
    }

    // MARK: SSE parsing (URLSessionDataDelegate)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        // SSE frames are separated by a blank line; each `data: ` line is JSON.
        while let range = buffer.range(of: Data("\n\n".utf8)) {
            let frame = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard let text = String(data: frame, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.hasPrefix("data: ") {
                handleEvent(String(line.dropFirst(6)))
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // The stream closed. If we never saw a terminal event, that's a dropped
        // connection mid-run (STEP 3c): report it rather than hanging. A run that
        // actually finished already signalled `doneSignal`.
        if !streamDone {
            streamError = "remote event stream ended unexpectedly" +
                (error.map { ": \($0.localizedDescription)" } ?? "")
            streamDone = true
            doneSignal.signal()
        }
    }

    private func handleEvent(_ json: String) {
        guard let data = json.data(using: .utf8),
              let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = ev["type"] as? String else { return }
        switch type {
        case "progress":
            let rung = ev["rung"] as? Int ?? 0
            let rungs = ev["rungs"] as? Int ?? 0
            let iter = ev["iter"] as? Int ?? 0
            // The keep-going decision drives cancellation exactly like local runs.
            if !progress(rung, rungs, iter) {
                cancelled = true
                cancelRemote()
            }
        case "variant":
            emitStreamedVariant(ev)
        case "done":
            streamDone = true
            doneSignal.signal()
        case "cancelled":
            cancelled = true; streamDone = true; doneSignal.signal()
        case "error":
            streamError = (ev["message"] as? String) ?? "remote run failed"
            streamDone = true; doneSignal.signal()
        default:
            break  // log lines: ignored for the outcome
        }
    }

    // MARK: outcome assembly

    /// Progressive result: a variant finished on the worker (and its mesh is
    /// already written). Fetch the mesh + build a one-variant OptimizeOutcome and
    /// hand it to `onVariant`, so PR 109's streamed-variant screen grows live.
    private func emitStreamedVariant(_ ev: [String: Any]) {
        guard let meshName = ev["mesh"] as? String, !meshName.isEmpty else {
            // A VARIANT event with no mesh is malformed — fail rather than show a
            // bodiless variant (097 fix 2). The CLI always names the exported mesh.
            failStream("worker reported a completed variant without a mesh file")
            return
        }
        let mesh: ([Float], [Int32])
        do {
            mesh = try fetchMesh(named: meshName)
        } catch {
            failStream((error as? RemoteRunError)?.message ?? "\(error)")
            return
        }
        let requestedVF = ev["vf"] as? Double ?? 0
        let achievedVF = ev["achieved"] as? Double ?? 0
        // Handoff 104: the app's savings uses the printed/count basis (`printed`);
        // fall back to `achieved` if a pre-104 worker omitted it.
        let printedVF = ev["printed"] as? Double ?? achievedVF
        let margin = ev["margin"] as? Double ?? 0
        let accepted = (ev["accepted"] as? Bool) ?? true
        streamedLock.lock()
        streamed.append(StreamedVariant(requestedVF: requestedVF, achievedVF: achievedVF,
                                        printedFraction: printedVF,
                                        margin: margin, accepted: accepted,
                                        meshName: meshName,
                                        vertices: mesh.0, indices: mesh.1))
        streamedLock.unlock()
        let v = OptimizeVariant(
            requestedVolumeFraction: requestedVF,
            // achievedVolumeFraction is the app's savings basis (= printed/count);
            // printedFraction names it. (The continuous achievedVF is the report join
            // key, kept in StreamedVariant.)
            achievedVolumeFraction: printedVF,
            printedFraction: printedVF,
            massGrams: 0,                 // not emitted by the CLI (see file header)
            supportVolumeVoxels: 0,       // not emitted by the CLI
            meshTriangleCount: mesh.1.count / 3,
            worstCaseMargin: margin,
            accepted: accepted,
            v3Passes: true,
            meshVertices: mesh.0, meshIndices: mesh.1)
        // `computedRemotely: true` so the live results screen renders mass/stress/
        // flex/playback as n/a from the first streamed variant (097 fix 3).
        onVariant(OptimizeOutcome(variants: [v], stoppedOnMargin: false,
                                  cancelled: false, acceptedCount: 1,
                                  computedRemotely: true))
    }

    /// Abort the run with a diagnostic (used when a streamed mesh can't be fetched).
    /// Best-effort cancels the worker so it stops solving, then wakes `run()`.
    private func failStream(_ message: String) {
        if streamDone { return }
        streamError = message
        streamDone = true
        cancelRemote()
        doneSignal.signal()
    }

    /// Build the authoritative final outcome from report.json + the meshes ALREADY
    /// fetched during streaming. The scalar fields come from the report; the mesh
    /// geometry comes from the recorded streamed variants (097 fix 3 — never
    /// re-derive a filename). The per-voxel fields stay empty and the outcome is
    /// flagged `computedRemotely` (the CLI does not serialise them — see the header).
    private func assembleFinalOutcome() throws -> OptimizeOutcome {
        guard let id = jobID else { throw RemoteRunError("no job id") }
        // A finished run MUST have written its report; a missing/short report is a
        // real failure (`getJSON` throws on non-200), never a silent empty result.
        let base = config.baseURL.appendingPathComponent("jobs")
            .appendingPathComponent(id).appendingPathComponent("files")
        let report = try getJSON(base.appendingPathComponent("report.json"))
        let reportVariants = report["variants"] as? [[String: Any]] ?? []

        streamedLock.lock(); let accepted = streamed; streamedLock.unlock()

        // Join a report variant to a streamed (accepted) one by the OPTIMIZER-ACHIEVED
        // (continuous) volume fraction: the stream carries only accepted variants, the
        // report the whole ladder, so an index join would misalign. The VARIANT event's
        // `achieved` and the report's `volume_fraction` are the same quantity
        // (v.optimization.volume_fraction), so they match to float tolerance. (The
        // savings basis — `printed`/`printed_fraction` — is read separately in
        // makeVariant; it is NOT the join key. Handoff 104.)
        func reportVariant(forAchieved vf: Double) -> [String: Any]? {
            var best: [String: Any]?
            var bestErr = 1e-4      // require a real match, don't grab the nearest
            for rv in reportVariants {
                let rvf = rv["volume_fraction"] as? Double ?? .infinity
                let e = abs(rvf - vf)
                if e < bestErr { bestErr = e; best = rv }
            }
            return best
        }

        if !accepted.isEmpty {
            let variants = accepted.map { makeVariant(streamed: $0,
                                                      report: reportVariant(forAchieved: $0.achievedVF)) }
            return OptimizeOutcome(variants: variants, stoppedOnMargin: false,
                                   cancelled: false, acceptedCount: variants.count,
                                   computedRemotely: true)
        }

        // No accepted variant streamed → an all-rejected run. Build meshless
        // variants from the report so RunModel surfaces the honest "not strong
        // enough" sheet (it reads the terminal rung's worst-case margin).
        let rejected = reportVariants.map { makeVariant(streamed: nil, report: $0) }
        return OptimizeOutcome(variants: rejected, stoppedOnMargin: false,
                               cancelled: false, acceptedCount: 0,
                               computedRemotely: true)
    }

    /// Assemble one final variant from an optional fetched mesh + optional report
    /// scalars. A streamed variant is accepted (and carries its mesh); a report-only
    /// variant is a rejected rung (meshless — the worker exports only accepted ones).
    private func makeVariant(streamed s: StreamedVariant?,
                             report rv: [String: Any]?) -> OptimizeVariant {
        let margin = rv?["margin"] as? [String: Any]
        let orient = rv?["orientation"] as? [String: Any]
        // Savings/count basis (handoff 104): the app's savings is 1 - achievedVolume-
        // Fraction, which must stay the PRINTED/count basis. Prefer the streamed
        // printed fraction, else the report's printed_fraction, falling back to the
        // report's volume_fraction only for a pre-104 report that lacks the field.
        let printedVF = s?.printedFraction
            ?? (rv?["printed_fraction"] as? Double)
            ?? (rv?["volume_fraction"] as? Double ?? 0)
        let worst = (margin?["worst_case"] as? Double) ?? (s?.margin) ?? 0
        return OptimizeVariant(
            requestedVolumeFraction: s?.requestedVF ?? printedVF,
            achievedVolumeFraction: printedVF,
            printedFraction: printedVF,
            massGrams: 0, supportVolumeVoxels: 0,        // not over the wire (header)
            meshTriangleCount: (s?.indices.count ?? 0) / 3,
            worstCaseMargin: worst,
            accepted: s != nil, v3Passes: true,
            minFeatureViolations: rv?["min_feature_violations"] as? Int ?? 0,
            minFeatureWarning: rv?["min_feature_warning"] as? String ?? "",
            orientation: SIMD3(orient?["x"] as? Double ?? 0,
                               orient?["y"] as? Double ?? 0,
                               orient?["z"] as? Double ?? 1),
            maxStressMPa: rv?["max_stress_mpa"] as? Double ?? 0,
            maxInterlayerTensionMPa: rv?["max_interlayer_tension_mpa"] as? Double ?? 0,
            inPlaneMargin: (margin?["in_plane"] as? Double) ?? 0,
            interlayerMargin: (margin?["interlayer"] as? Double) ?? 0,
            meshVertices: s?.vertices ?? [], meshIndices: s?.indices ?? [])
    }

    /// Minimal binary-STL reader → (interleaved xyz floats, triangle-soup indices).
    /// The mesh is unindexed (STL has no shared vertices); fine for display.
    private func parseBinarySTL(_ data: Data) -> ([Float], [Int32]) {
        guard data.count > 84 else { return ([], []) }
        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
        var verts: [Float] = []; var idx: [Int32] = []
        verts.reserveCapacity(Int(count) * 9)
        var off = 84
        for _ in 0..<Int(count) {
            guard off + 50 <= data.count else { break }
            // skip the 12-byte normal; read 3 vertices (9 floats)
            for v in 0..<3 {
                let base = off + 12 + v * 12
                for c in 0..<3 {
                    let f = data.withUnsafeBytes {
                        $0.loadUnaligned(fromByteOffset: base + c * 4, as: Float32.self)
                    }
                    verts.append(f)
                }
            }
            let n = Int32(idx.count)
            idx.append(contentsOf: [n, n + 1, n + 2])
            off += 50
        }
        return (verts, idx)
    }
}
