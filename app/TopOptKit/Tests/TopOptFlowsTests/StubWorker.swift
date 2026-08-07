// StubWorker — an in-process HTTP worker the app's REAL RemoteRun can be driven
// against under a plain `swift test` (task 2026-08-07-lattice-variants-on-screen).
//
// WHY THIS EXISTS RATHER THAN THE PYTHON HARNESS. `tools/topopt-worker/e2e/` puts
// up the real worker wrapping a stub CLI, but every test that uses it is GATED on
// TOPOPT_E2E=1 and skips in CI. The claim this task has to pin — "the optimize
// path fetches the lattice REPORT and never the lattice MESH" — is a claim about
// WHICH REQUESTS GO OVER THE WIRE, and a claim about the wire needs a wire. So
// this serves the same routes the worker serves, from a directory of real run
// artifacts, and RECORDS every path the client asked for.
//
// It is deliberately minimal and deliberately honest: it does not emulate the
// worker's queue, its heartbeat, or its DELETE semantics — those are the Python
// harness's job and are covered there. It emulates exactly the four routes an
// optimize run reads (`/health`, `POST /jobs`, `/jobs/{id}`, `/jobs/{id}/events`,
// `/jobs/{id}/files/{name}`) so that what a test asserts about the request log is
// what a real worker would have seen.

import Foundation

final class StubWorker {
    /// Every request the client made, in order, as "METHOD /path".
    private(set) var requestLog: [String] = []
    private let logLock = NSLock()

    let port: UInt16
    /// Directory whose files `/jobs/{id}/files/{name}` serves.
    private let filesDir: URL
    /// The SSE event stream, already-encoded JSON objects, replayed from index 0 on
    /// every connect exactly as the worker does.
    private let events: [String]
    private let fingerprint: String
    let jobID = "stubjob"

    private let fd: Int32
    private var running = true
    private let queue = DispatchQueue(label: "stub-worker", attributes: .concurrent)

    /// Sizes to report for a HEAD on a named file, INSTEAD of what is on disk.
    ///
    /// This is how the maintainer's real 740 MB – 1.95 GB latticed meshes take part
    /// in a test that runs in CI: the app's transfer decision reads
    /// `Content-Length`, so a stub that answers with his real byte counts exercises
    /// the real decision without carrying 5.17 GB in the repository. It is not a
    /// convenience — a fixture that reported a few kilobytes would let the budget
    /// through every time and prove nothing.
    private let sizeOverrides: [String: Int]

    init(filesDir: URL, events: [String], fingerprint: String,
         sizeOverrides: [String: Int] = [:]) throws {
        self.filesDir = filesDir
        self.events = events
        self.fingerprint = fingerprint
        self.sizeOverrides = sizeOverrides

        let listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw NSError(domain: "stub-worker", code: 1) }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listenFD, 16) == 0 else {
            close(listenFD); throw NSError(domain: "stub-worker", code: 2)
        }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFD, $0, &len)
            }
        }
        port = UInt16(bigEndian: got.sin_port)
        fd = listenFD

        queue.async { [weak self] in
            while self?.running == true {
                let client = accept(listenFD, nil, nil)
                if client < 0 { break }
                self?.queue.async { self?.serve(client) }
            }
        }
    }

    func stop() {
        running = false
        close(fd)
    }

    /// The paths requested so far (a snapshot — the server keeps running).
    func log() -> [String] {
        logLock.lock(); defer { logLock.unlock() }
        return requestLog
    }

    /// Whether any request path ENDS WITH this suffix. The assertion helper the
    /// lattice-mesh bars are written against.
    func requested(suffix: String) -> Bool {
        log().contains { $0.hasSuffix(suffix) }
    }

    // MARK: - one connection

    private func serve(_ client: Int32) {
        defer { close(client) }
        // Read the request head, then DRAIN THE WHOLE BODY before answering.
        //
        // Draining is not tidiness. Writing a response and closing while the client
        // is still sending its multipart `POST /jobs` body makes the kernel answer
        // the remaining segments with RST, and the client then loses the response
        // it had already been sent — surfacing as "submit failed: no job_id" on
        // roughly one run in eight. The body is read and discarded (the stub does
        // not care what was submitted); what matters is that the socket is not
        // torn down under a peer mid-write.
        var scratch = [UInt8](repeating: 0, count: 65536)
        var head = ""
        var headerBytes = 0
        var buffered = [UInt8]()
        while true {
            let n = read(client, &scratch, scratch.count)
            if n <= 0 { break }
            buffered.append(contentsOf: scratch[0..<n])
            if let text = String(bytes: buffered, encoding: .isoLatin1),
               let range = text.range(of: "\r\n\r\n") {
                head = String(text[text.startIndex..<range.lowerBound])
                headerBytes = text.distance(from: text.startIndex, to: range.upperBound)
                break
            }
        }
        guard !head.isEmpty, let requestLine = head.split(separator: "\r\n").first
        else { return }
        let contentLength = head.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1]
                .trimmingCharacters(in: .whitespaces)) } ?? 0
        var bodyRead = buffered.count - headerBytes
        while bodyRead < contentLength {
            let n = read(client, &scratch, scratch.count)
            if n <= 0 { break }
            bodyRead += n
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0]), path = String(parts[1])
        logLock.lock(); requestLog.append("\(method) \(path)"); logLock.unlock()

        func send(_ status: String, _ body: Data,
                  contentType: String = "application/json",
                  declaredLength: Int? = nil) {
            let headers = "HTTP/1.1 \(status)\r\n"
                + "Content-Length: \(declaredLength ?? body.count)\r\n"
                + "Content-Type: \(contentType)\r\nConnection: close\r\n\r\n"
            _ = headers.withCString { write(client, $0, strlen($0)) }
            // A HEAD carries the headers and no body — which is exactly what the
            // app's size probe reads, and the only way this stub can speak for a
            // 1.95 GB file it does not have.
            guard method != "HEAD" else { return }
            body.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let w = write(client, raw.baseAddress!.advanced(by: off),
                                  raw.count - off)
                    if w <= 0 { break } else { off += w }
                }
            }
        }
        func sendJSON(_ status: String, _ obj: [String: Any]) {
            send(status, (try? JSONSerialization.data(withJSONObject: obj)) ?? Data())
        }

        switch true {
        case path == "/health":
            sendJSON("200 OK", ["fingerprint": fingerprint, "state": "idle"])

        case method == "POST" && path == "/jobs":
            sendJSON("202 Accepted", ["job_id": jobID])

        case path == "/jobs/\(jobID)/events":
            // SSE: replay every event, then close. RemoteRun dedupes replays by
            // index and resolves on the terminal event, so one pass is enough.
            let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                + "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
            _ = headers.withCString { write(client, $0, strlen($0)) }
            for ev in events {
                let frame = "data: \(ev)\n\n"
                _ = frame.withCString { write(client, $0, strlen($0)) }
            }

        case path == "/jobs/\(jobID)":
            sendJSON("200 OK", ["state": "done", "status": "done",
                                "created_at": 1_770_000_000.0,
                                "started_at": 1_770_000_001.0,
                                "finished_at": 1_770_000_099.0])

        case path.hasPrefix("/jobs/\(jobID)/files/"):
            let name = String(path.dropFirst("/jobs/\(jobID)/files/".count))
            let url = filesDir.appendingPathComponent(name)
            if let declared = sizeOverrides[name] {
                // A file this stub speaks for but does not hold. Only a HEAD is
                // answerable; a GET would have to produce bytes that do not exist,
                // and 404 is the honest answer rather than a truncated body.
                if method == "HEAD" {
                    send("200 OK", Data(), contentType: "application/octet-stream",
                         declaredLength: declared)
                } else {
                    send("404 Not Found", Data("not held by the stub".utf8),
                         contentType: "text/plain")
                }
            } else if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
                send("200 OK", data, contentType: "application/octet-stream")
            } else {
                send("404 Not Found", Data("missing".utf8), contentType: "text/plain")
            }

        default:
            send("404 Not Found", Data("no route".utf8), contentType: "text/plain")
        }
    }
}
