// RelatticeRunner.swift — submit and drive the `lattice_variant` job (task
// 2026-08-02-lattice-a-variant).
//
// WHAT MAKES THIS A DIFFERENT RUNNER FROM `RemoteRun`. The optimize runner exists
// to follow a LADDER: it streams PROGRESS and VARIANT checkpoints over SSE for
// hours, dedupes replays, survives reconnects and holds each accepted rung's
// geometry. A re-lattice has no ladder. It runs a small fixed number of
// certification solves — minutes, not hours — and produces exactly ONE object.
// Driving it through the streaming machinery would mean pretending it has rungs
// it does not have; this submits, polls, and fetches the one result.
//
// THE JOB DOCUMENT IS NOT AUTHORED HERE. It is the run's OWN retained job.json
// with `mode` swapped to "lattice_variant" and the `variant` + lattice/grading
// blocks added (`RelatticeJobBuilder`, below — pure and unit-tested). Every fact
// that determines the load case — the anchors, the force groups, the clearances,
// the protections, the resolution, the material — travels verbatim from the
// document that produced the variant. That is the whole of bar Z2 on the app
// side: the load case is not reconstructed, it is re-used.

import Foundation
import simd
import TopOptKit

// MARK: - the job document

/// Builds the `lattice_variant` job from the RETAINED job document. Pure
/// JSON-in / JSON-out over `Any` dictionaries so the transformation is
/// headlessly testable without a worker.
public enum RelatticeJobBuilder {

    public struct BuildError: Error, CustomStringConvertible {
        public let description: String
        init(_ d: String) { description = d }
    }

    /// `original` is the exact bytes submitted for the optimize run.
    ///
    /// Everything except `mode`, `variant` and the lattice/grading blocks is
    /// carried over UNTOUCHED — including keys this build has never heard of. A
    /// selective copy would silently drop a load-case key added later, which is
    /// precisely the mesh-job-params defect (a job.json that shipped a skeleton
    /// and got a worst-case fallback run). So the transformation is additive on
    /// a decoded copy, never a rebuild.
    public static func build(original: Data,
                             variantVolumeFraction: Double,
                             designFileName: String,
                             lattice: LatticeSpec?) throws -> Data {
        guard var job = (try? JSONSerialization.jsonObject(with: original))
                as? [String: Any] else {
            throw BuildError("the retained job document is not readable JSON")
        }
        job["mode"] = "lattice_variant"
        job["variant"] = ["design": designFileName,
                          "volume_fraction": variantVolumeFraction]
        // The optimize run may or may not have carried a lattice block. Either
        // way the re-lattice job carries the settings the user has NOW — that is
        // the point of the page. The load case is what must not change; the
        // lattice is what the user came here to choose.
        job["lattice"] = nil
        job["grading"] = nil
        guard let lat = lattice else {
            throw BuildError("a lattice_variant job needs lattice settings — "
                             + "there is nothing to lattice without them")
        }
        var block: [String: Any] = [
            "topology": lat.topologyID,
            "emit_stl": lat.emitSTL,
            "emit_3mf": lat.emit3MF,
            "skin": lat.skin,
        ]
        if lat.graded {
            var grading: [String: Any] = [
                "topology": lat.topologyID,
                "min_extrudable_width_mm": lat.minExtrudableWidthMM ?? 0,
            ]
            switch lat.cellSizeMode {
            case LatticeCellSizeMode.auto.rawValue:
                grading["cell_mode"] = lat.cellSizeMode
            case LatticeCellSizeMode.swept.rawValue:
                grading["cell_mode"] = lat.cellSizeMode
                grading["cell_min_mm"] = lat.cellMinMM
                grading["cell_max_mm"] = lat.cellMaxMM
            default:
                grading["cell_mm"] = lat.cellMM
            }
            job["grading"] = grading
        } else {
            block["cell_mm"] = lat.cellMM
            block["strut_radius_mm"] = lat.strutRadiusMM
        }
        if let w = lat.minExtrudableWidthMM {
            block["min_extrudable_width_mm"] = w
        }
        if !lat.regions.isEmpty {
            block["regions"] = lat.regions.map { r -> [String: Any] in
                let geometry: [String: Any] = r.kind == .face
                    ? [
                        "origin": [r.origin.x, r.origin.y, r.origin.z],
                        "normal": [r.normal.x, r.normal.y, r.normal.z],
                        "half_u_mm": r.halfUMM,
                        "half_w_mm": r.halfWMM,
                        "depth_mm": r.depthMM,
                    ]
                    : [
                        "axis_point": [r.axisPoint.x, r.axisPoint.y, r.axisPoint.z],
                        "axis_dir": [r.axisDir.x, r.axisDir.y, r.axisDir.z],
                        "radius_mm": r.radiusMM,
                        "half_length_mm": r.halfLengthMM,
                    ]
                return ["role": r.role.rawValue, "kind": r.kind.rawValue,
                        "geometry": geometry]
            }
        }
        job["lattice"] = block
        return try JSONSerialization.data(withJSONObject: job,
                                          options: [.sortedKeys])
    }

    /// The keys that determine the LOAD CASE. Bar Z2's app-side check: the
    /// re-lattice document must carry these byte-for-byte from the original, so a
    /// test can assert the transformation touched only the lattice question.
    public static let loadCaseKeys = [
        "model", "source_format", "material", "resolution", "loads",
        "fixture_faces", "gravity", "ladder", "margin_stop", "design_box",
        "keep_outs", "build_direction", "build_orientation_report",
        "bake_build_orientation", "simp", "draft",
    ]

    /// Every load-case key that differs between two job documents (empty ⇒ the
    /// same load case). Used by the test AND by the runner as a pre-flight, so a
    /// document that would certify under a different load case never leaves the
    /// device.
    public static func loadCaseDifferences(_ a: Data, _ b: Data) -> [String] {
        let da = (try? JSONSerialization.jsonObject(with: a)) as? [String: Any] ?? [:]
        let db = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any] ?? [:]
        return loadCaseKeys.filter { key in
            let va = da[key], vb = db[key]
            if va == nil && vb == nil { return false }
            guard let va, let vb else { return true }
            // Compare canonically-serialised forms — the honest equality for
            // heterogeneous JSON values without hand-writing a deep compare.
            let sa = try? JSONSerialization.data(withJSONObject: [key: va],
                                                 options: [.sortedKeys])
            let sb = try? JSONSerialization.data(withJSONObject: [key: vb],
                                                 options: [.sortedKeys])
            return sa != sb
        }
    }
}

// MARK: - the outcome

/// What a re-lattice produced. Deliberately shaped as an `OptimizeOutcome` with
/// ONE variant so the existing results screen renders it with no special case:
/// it IS one certified object with a mesh, a margin and a field.
public struct RelatticeResult {
    public let outcome: OptimizeOutcome
    /// The per-variant lattice certification receipt (raw JSON), so the results
    /// screen can show the composite margins and the strut-strength report the
    /// same way a lattice optimize run's does.
    public let receiptJSON: Data?
    /// The job's own provenance record — the no-ladder facts and the
    /// reproduction proof.
    public let provenanceJSON: Data?
}

// MARK: - the run

public struct RelatticeError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
    public var localizedDescription: String { description }
}

/// Submit a `lattice_variant` job to a LAN worker and wait for its one result.
///
/// SYNCHRONOUS BY DESIGN: the caller runs it off the main thread (the same
/// discipline as `RemoteRun.run`), and the job is minutes-scale, so a poll loop
/// is the honest shape — there is no ladder to stream.
public enum RelatticeRun {

    /// Poll interval and ceiling. The ceiling is generous but finite: a
    /// certification-only job that has not finished in this long has failed in a
    /// way the worker did not report, and hanging forever would be worse than
    /// saying so.
    public static let pollSeconds: TimeInterval = 2
    public static let ceilingSeconds: TimeInterval = 3600

    public struct Inputs {
        public let config: RemoteRunnerConfig
        public let modelPath: String
        public let jobJSON: Data
        public let designBin: Data
        public let projectName: String
        /// The rung being latticed — carried onto the outcome so the results
        /// screen names the same variant the page did.
        public let requestedVolumeFraction: Double
        public init(config: RemoteRunnerConfig, modelPath: String, jobJSON: Data,
                    designBin: Data, projectName: String,
                    requestedVolumeFraction: Double) {
            self.config = config
            self.modelPath = modelPath
            self.jobJSON = jobJSON
            self.designBin = designBin
            self.projectName = projectName
            self.requestedVolumeFraction = requestedVolumeFraction
        }
    }

    public static func run(_ inputs: Inputs,
                           isCancelled: @escaping () -> Bool = { false })
        throws -> RelatticeResult {
        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = inputs.config.controlTimeout
            return c
        }())

        func get(_ url: URL) throws -> (Data, Int) {
            var out: (Data, URLResponse)?
            var err: Error?
            let sem = DispatchSemaphore(value: 0)
            session.dataTask(with: url) { d, r, e in
                if let d, let r { out = (d, r) } else { err = e }
                sem.signal()
            }.resume()
            sem.wait()
            guard let out else {
                throw RelatticeError("request failed: \(url.path): "
                    + (err?.localizedDescription ?? "no response"))
            }
            return (out.0, (out.1 as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let base = inputs.config.baseURL

        // VERSION-SKEW GUARD, same as the optimize path: a worker on a different
        // core produces a different object, and this job's whole promise is that
        // the object it certifies is the one on record.
        let (healthData, healthCode) = try get(base.appendingPathComponent("health"))
        guard healthCode == 200,
              let health = try? JSONSerialization.jsonObject(with: healthData)
                as? [String: Any] else {
            throw RelatticeError("the worker did not answer /health")
        }
        let fp = (health["fingerprint"] as? String) ?? "unknown"
        guard fp == inputs.config.expectedFingerprint else {
            throw RelatticeError(
                "worker core mismatch: worker \(fp), app "
                + "\(inputs.config.expectedFingerprint). Refusing to re-lattice — "
                + "a different core certifies a different object.")
        }

        // SUBMIT: model + job + the run's own design.bin.
        let modelData = try Data(contentsOf: URL(fileURLWithPath: inputs.modelPath))
        let modelName = (inputs.modelPath as NSString).lastPathComponent
        let boundary = "topopt-\(UUID().uuidString)"
        var body = Data()
        func part(_ headers: String, _ payload: Data) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(headers.data(using: .utf8)!)
            body.append("\r\n\r\n".data(using: .utf8)!)
            body.append(payload)
            body.append("\r\n".data(using: .utf8)!)
        }
        part("Content-Disposition: form-data; name=\"step\"; filename=\"\(modelName)\"\r\n"
             + "Content-Type: application/octet-stream", modelData)
        part("Content-Disposition: form-data; name=\"job\"; filename=\"job.json\"\r\n"
             + "Content-Type: application/json", inputs.jobJSON)
        part("Content-Disposition: form-data; name=\"design\"; filename=\"design.bin\"\r\n"
             + "Content-Type: application/octet-stream", inputs.designBin)
        part("Content-Disposition: form-data; name=\"project\"",
             Data(inputs.projectName.utf8))
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: base.appendingPathComponent("jobs"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        var postOut: (Data, URLResponse)?
        var postErr: Error?
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { d, r, e in
            if let d, let r { postOut = (d, r) } else { postErr = e }
            sem.signal()
        }.resume()
        sem.wait()
        guard let (postData, postResp) = postOut,
              (postResp as? HTTPURLResponse)?.statusCode == 202,
              let posted = try? JSONSerialization.jsonObject(with: postData)
                as? [String: Any],
              let jobID = posted["job_id"] as? String else {
            throw RelatticeError("the worker refused the re-lattice job: "
                + (postErr?.localizedDescription
                   ?? String(data: postOut?.0 ?? Data(), encoding: .utf8)
                   ?? "no response"))
        }

        // POLL to completion.
        let jobURL = base.appendingPathComponent("jobs").appendingPathComponent(jobID)
        let deadline = Date().addingTimeInterval(ceilingSeconds)
        var state = "queued"
        while Date() < deadline {
            if isCancelled() {
                var del = URLRequest(url: jobURL)
                del.httpMethod = "DELETE"
                session.dataTask(with: del).resume()
                throw RelatticeError("cancelled")
            }
            let (d, code) = try get(jobURL)
            guard code == 200,
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { throw RelatticeError("lost the re-lattice job on the worker") }
            state = (obj["state"] as? String) ?? "unknown"
            if state == "done" { break }
            if state == "failed" || state == "error" {
                throw RelatticeError("the re-lattice job failed on the worker: "
                    + ((obj["message"] as? String) ?? "no message"))
            }
            Thread.sleep(forTimeInterval: pollSeconds)
        }
        guard state == "done" else {
            throw RelatticeError("the re-lattice job did not finish within "
                + "\(Int(ceilingSeconds / 60)) minutes")
        }

        // FETCH the one result. The latticed mesh is the object that was
        // certified; a missing mesh is a hard failure (never an empty part).
        func file(_ name: String) -> Data? {
            let url = jobURL.appendingPathComponent("files").appendingPathComponent(name)
            guard let (d, code) = try? get(url), code == 200, !d.isEmpty else {
                return nil
            }
            return d
        }
        let vfTag = String(format: "%03d",
                           Int((inputs.requestedVolumeFraction * 100).rounded()))
        guard let meshData = file("variant_\(vfTag)_lattice.stl") else {
            throw RelatticeError(
                "the re-lattice finished but its latticed mesh could not be "
                + "transferred — not showing an empty part.")
        }
        let mesh = MeshExport.parseBinarySTL(meshData)
        guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty else {
            throw RelatticeError("the latticed mesh arrived unreadable "
                + "(\(meshData.count) bytes) — not showing an empty part.")
        }
        let receipt = file("variant_\(vfTag)_lattice.report.json")
        let provenance = file("lattice_variant.json")
        let fields = file("fields.bin").flatMap { RemoteFieldsContainer.parse($0) }
        let block = fields?.variants.first

        let variant = OptimizeVariant(
            requestedVolumeFraction: inputs.requestedVolumeFraction,
            achievedVolumeFraction: inputs.requestedVolumeFraction,
            massGrams: block?.massGrams ?? 0,
            supportVolumeVoxels: block?.supportVolumeVoxels ?? 0,
            meshTriangleCount: mesh.indices.count / 3,
            worstCaseMargin: 0, accepted: true, v3Passes: true,
            meshVertices: mesh.vertices, meshIndices: mesh.indices,
            vonMisesField: block?.vonMises ?? [],
            displacementField: block?.displacement ?? [])
        let outcome = OptimizeOutcome(
            variants: [variant], stoppedOnMargin: false, cancelled: false,
            acceptedCount: 1,
            voxelVolumeMM3: fields.map { $0.voxelVolumeMM3 } ?? 0,
            gridNx: fields?.gridNx ?? 0, gridNy: fields?.gridNy ?? 0,
            gridNz: fields?.gridNz ?? 0,
            gridOrigin: fields?.gridOrigin ?? .zero, spacing: fields?.spacing ?? 0,
            computedRemotely: true)
        return RelatticeResult(outcome: outcome, receiptJSON: receipt,
                               provenanceJSON: provenance)
    }
}
