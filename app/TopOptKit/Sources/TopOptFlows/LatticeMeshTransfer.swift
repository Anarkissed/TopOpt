// LatticeMeshTransfer — bringing ONE latticed mesh over, on demand
// (task 2026-08-07-lattice-variants-on-screen, S1).
//
// ═══════════════════════════════════════════════════════════════════════════
// WHY ON DEMAND, AND WHY STREAMED TO DISK
// ═══════════════════════════════════════════════════════════════════════════
//
// The task's S1(a) asks for the same code path the re-lattice runner uses, and
// S1(b) says the transfer SIZE is the obstacle. Both are answered here, and the
// second one changes the answer to the first.
//
// `RelatticeRun` fetches its one latticed mesh with a synchronous in-memory GET
// and hands the bytes to `MeshExport.parseBinarySTL` — correct for a re-lattice,
// which produces exactly one object the user explicitly asked for and waited
// minutes on. Reusing that shape for a four-rung optimize run would mean 5.17 GB
// of eager transfer on the maintainer's own run, and — measured — 4.30 GB of
// resident memory for a single 1.42 GB body, because an accumulating `dataTask`
// holds about 3× its payload (see `LatticeMeshBudget`). So the SHAPE is reused
// (fetch `variant_<tag>_lattice.stl` from `/jobs/{id}/files/{name}`, the identical
// route and the identical filename convention, derived by the same `%03d` rule)
// while the MECHANISM is a `downloadTask` that streams to a file. That is the
// honest reading of "reuse its code path": the same protocol, not the same
// allocation strategy, because the allocation strategy is precisely the thing the
// measurement disqualified.
//
// Nothing is fetched until a latticed variant is SELECTED, and the mesh is never
// fetched at all for the numbers — mass, margin, verdict and triangle count all
// come off the receipt (a few kB), which IS fetched eagerly for every rung.

import Foundation

/// Where a latticed mesh comes from. A protocol so the results screen can be
/// driven in a test without a worker, and so the maintainer's real run can be
/// replayed through the same code the app runs.
public protocol LatticeMeshTransferring: AnyObject {
    /// The mesh's size on the worker, in bytes, WITHOUT transferring it. 0 when it
    /// cannot be determined — which every caller must treat as "unknown", never as
    /// "small".
    func meshBytes(named name: String) -> Int

    /// Stream the mesh to a local file. Calls `progress` with (received, total) on
    /// an arbitrary queue and `completion` exactly once with the landed file URL or
    /// an error. Never decodes, never holds the body in memory.
    func downloadMesh(named name: String,
                      progress: @escaping (Int64, Int64) -> Void,
                      completion: @escaping (Result<URL, Error>) -> Void)
}

public struct LatticeMeshTransferError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
    public var localizedDescription: String { description }
}

/// The production transfer: the worker's `/jobs/{id}/files/{name}` route, the same
/// one the solid meshes, `fields.bin`, `design.bin` and every receipt come from.
public final class RemoteLatticeMeshTransfer: LatticeMeshTransferring {
    private let baseURL: URL
    private let jobID: String
    private let controlTimeout: TimeInterval
    private let session: URLSession

    public init(config: RemoteRunnerConfig, jobID: String) {
        self.baseURL = config.baseURL
        self.jobID = jobID
        self.controlTimeout = config.controlTimeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = config.controlTimeout
        // A multi-gigabyte transfer over a home LAN is minutes, not seconds. The
        // per-request idle timeout above still fails a DEAD link fast; this bound
        // only stops a transfer that is genuinely making progress from being cut.
        cfg.timeoutIntervalForResource = 6 * 60 * 60
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    private func url(_ name: String) -> URL {
        baseURL.appendingPathComponent("jobs").appendingPathComponent(jobID)
            .appendingPathComponent("files").appendingPathComponent(name)
    }

    /// A HEAD request. The worker answers `/files/{name}` from a static-file route,
    /// so the `Content-Length` on a HEAD is the file's real size and costs nothing.
    /// A worker that refuses HEAD leaves this 0, and the budget then refuses to
    /// promise anything — the safe direction.
    public func meshBytes(named name: String) -> Int {
        var req = URLRequest(url: url(name))
        req.httpMethod = "HEAD"
        req.timeoutInterval = controlTimeout
        var bytes = 0
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { _, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200,
               http.expectedContentLength > 0 {
                bytes = Int(http.expectedContentLength)
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + controlTimeout + 2)
        return bytes
    }

    public func downloadMesh(named name: String,
                             progress: @escaping (Int64, Int64) -> Void,
                             completion: @escaping (Result<URL, Error>) -> Void) {
        let target = url(name)
        let observerBox = ProgressBox(progress)
        let task = session.downloadTask(with: target) { tmp, resp, err in
            observerBox.stop()
            if let err {
                completion(.failure(LatticeMeshTransferError(
                    "the latticed mesh could not be brought over from the worker: "
                    + err.localizedDescription)))
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let tmp else {
                completion(.failure(LatticeMeshTransferError(
                    "the worker did not serve \"\(name)\" (HTTP \(code)). The "
                    + "lattice was produced — its receipt is on this screen — but "
                    + "its geometry could not be transferred.")))
                return
            }
            // URLSession deletes the temp file as soon as this handler returns, so
            // the bytes are moved somewhere the caller owns before anything else.
            let dest = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("topopt-lattice-\(UUID().uuidString)-\(name)")
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
            } catch {
                completion(.failure(LatticeMeshTransferError(
                    "the latticed mesh arrived but could not be written to this "
                    + "device: \(error.localizedDescription)")))
                return
            }
            completion(.success(dest))
        }
        observerBox.attach(to: task)
        task.resume()
    }

    /// Holds the KVO observation for a task's progress and tears it down exactly
    /// once. A separate object because the completion handler and the observation
    /// have different lifetimes and both must be safe on an arbitrary queue.
    private final class ProgressBox {
        private let report: (Int64, Int64) -> Void
        private var observation: NSKeyValueObservation?
        private let lock = NSLock()

        init(_ report: @escaping (Int64, Int64) -> Void) { self.report = report }

        func attach(to task: URLSessionDownloadTask) {
            let obs = task.observe(\.countOfBytesReceived, options: [.new]) {
                [report] t, _ in
                report(t.countOfBytesReceived, t.countOfBytesExpectedToReceive)
            }
            lock.lock(); observation = obs; lock.unlock()
        }

        func stop() {
            lock.lock(); observation?.invalidate(); observation = nil; lock.unlock()
        }
    }
}
