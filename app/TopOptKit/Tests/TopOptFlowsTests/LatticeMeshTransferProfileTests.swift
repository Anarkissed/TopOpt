// LatticeMeshTransferProfileTests — WHAT IT COSTS TO BRING ONE LATTICED VARIANT
// TO THE DEVICE (task 2026-08-07-lattice-variants-on-screen, bar R3).
//
// The optimize path produces a latticed mesh per accepted rung, and the four on
// the maintainer's own run are 740 MB / 1.06 GB / 1.42 GB / 1.95 GB — ~5.17 GB
// for the set. Before any of the plumbing was designed, the question the task
// asks first had to be answered with a number: what does ONE of them cost to
// transfer and to decode?
//
// This is a MEASUREMENT, not an assertion of behaviour, so it is gated on
// TOPOPT_LATTICE_TRANSFER_PROFILE=1 plus a path to a real latticed STL. A plain
// `swift test` skips it — there is no 1.4 GB fixture in the repository and there
// never will be. The captured run is in
// evidence/2026-08-07-lattice-variants-on-screen/.
//
// It measures the SAME two steps the app would perform:
//   1. HTTP GET of `/jobs/{id}/files/{name}` into memory (URLSession, the shape
//      `RemoteRun.syncGET` uses), served from a loopback HTTP server.
//   2. `MeshExport.parseBinarySTL` — the app's real STL decoder, byte for byte
//      the one `fetchMesh` calls.
// Loopback is FASTER than the maintainer's Wi-Fi LAN, so the transfer number
// here is a floor, not an estimate of his experience. The MEMORY number is not:
// the resident footprint of holding the bytes plus the decoded soup is the same
// on any transport, and it is the number that decides whether an iPad can do
// this at all.

import XCTest
@testable import TopOptFlows

final class LatticeMeshTransferProfileTests: XCTestCase {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["TOPOPT_LATTICE_TRANSFER_PROFILE"] == "1"
    }
    private var stlPath: String? {
        ProcessInfo.processInfo.environment["TOPOPT_LATTICE_STL"]
    }

    /// Resident footprint of this process, in bytes, from the Mach task info the
    /// OS itself reports (`phys_footprint` — the same quantity iOS jetsam kills
    /// on, not the looser `resident_size`).
    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func gb(_ b: UInt64) -> String { String(format: "%.2f GB", Double(b) / 1e9) }
    private func gb(_ b: Int) -> String { String(format: "%.2f GB", Double(b) / 1e9) }

    func testOneLatticedVariantTransferAndDecodeCost() throws {
        try XCTSkipUnless(enabled, "set TOPOPT_LATTICE_TRANSFER_PROFILE=1 and "
                          + "TOPOPT_LATTICE_STL=<path to a real latticed STL>")
        let path = try XCTUnwrap(stlPath, "TOPOPT_LATTICE_STL must name a latticed STL")
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let fileBytes = (attrs[.size] as? Int) ?? 0
        XCTAssertGreaterThan(fileBytes, 0, "the named latticed STL is empty")

        let server = try LoopbackFileServer(path: path)
        defer { server.stop() }

        let baseline = Self.footprintBytes()
        print("== lattice mesh transfer profile ==")
        print("  file: \(path)")
        print("  size: \(fileBytes) bytes (\(gb(fileBytes)))")
        print("  baseline footprint: \(gb(baseline))")

        // ── 1. TRANSFER ────────────────────────────────────────────────────
        let t0 = Date()
        let url = URL(string: "http://127.0.0.1:\(server.port)/jobs/j/files/mesh.stl")!
        var body: Data?
        var err: Error?
        let sem = DispatchSemaphore(value: 0)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 600
        URLSession(configuration: cfg).dataTask(with: url) { d, _, e in
            body = d; err = e; sem.signal()
        }.resume()
        sem.wait()
        let transferSeconds = Date().timeIntervalSince(t0)
        if let err { XCTFail("transfer failed: \(err)") }
        let data = try XCTUnwrap(body)
        XCTAssertEqual(data.count, fileBytes, "the whole file must arrive")
        let afterTransfer = Self.footprintBytes()
        print(String(format: "  transfer: %.2f s over loopback (%.1f MB/s)",
                     transferSeconds, Double(fileBytes) / 1e6 / transferSeconds))
        print("  footprint after transfer: \(gb(afterTransfer)) "
              + "(+\(gb(afterTransfer &- baseline)))")

        // ── 2. DECODE (the app's own parser) ───────────────────────────────
        let t1 = Date()
        let mesh = MeshExport.parseBinarySTL(data)
        let decodeSeconds = Date().timeIntervalSince(t1)
        let peak = Self.footprintBytes()
        print(String(format: "  decode: %.2f s", decodeSeconds))
        print("  triangles: \(mesh.indices.count / 3)")
        print("  vertices floats: \(mesh.vertices.count) "
              + "(\(gb(mesh.vertices.count * 4)))")
        print("  indices: \(mesh.indices.count) (\(gb(mesh.indices.count * 4)))")
        print("  PEAK footprint (bytes + soup held together): \(gb(peak)) "
              + "(+\(gb(peak &- baseline)))")
        print(String(format: "  TOTAL wall: %.2f s", transferSeconds + decodeSeconds))
        XCTAssertGreaterThan(mesh.indices.count, 0, "the decoded mesh must be usable")
    }

    /// THE SAME TRANSFER, STREAMED TO DISK. `URLSession.downloadTask` writes the
    /// body to a file as it arrives instead of accumulating it in an in-memory
    /// `Data`, and the decoder then reads a MEMORY-MAPPED file, whose pages the
    /// kernel can evict under pressure. The measurement above says the in-memory
    /// shape is what costs — this one says how much of that cost is avoidable, and
    /// therefore what is reachable on an iPad and what is not.
    func testStreamedToDiskTransferAndMappedDecodeCost() throws {
        try XCTSkipUnless(enabled, "set TOPOPT_LATTICE_TRANSFER_PROFILE=1 and "
                          + "TOPOPT_LATTICE_STL=<path to a real latticed STL>")
        let path = try XCTUnwrap(stlPath, "TOPOPT_LATTICE_STL must name a latticed STL")
        let fileBytes = (try FileManager.default.attributesOfItem(atPath: path)[.size]
                         as? Int) ?? 0

        let server = try LoopbackFileServer(path: path)
        defer { server.stop() }
        let baseline = Self.footprintBytes()
        print("== lattice mesh transfer profile — STREAMED TO DISK ==")
        print("  size: \(fileBytes) bytes (\(gb(fileBytes)))")
        print("  baseline footprint: \(gb(baseline))")

        // ── 1. TRANSFER, to a file ─────────────────────────────────────────
        let t0 = Date()
        let url = URL(string: "http://127.0.0.1:\(server.port)/jobs/j/files/mesh.stl")!
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lattice-profile-\(UUID().uuidString).stl")
        var landed: URL?
        var err: Error?
        let sem = DispatchSemaphore(value: 0)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 600
        URLSession(configuration: cfg).downloadTask(with: url) { tmp, _, e in
            err = e
            if let tmp {
                try? FileManager.default.moveItem(at: tmp, to: dest)
                landed = dest
            }
            sem.signal()
        }.resume()
        sem.wait()
        let transferSeconds = Date().timeIntervalSince(t0)
        if let err { XCTFail("download failed: \(err)") }
        let file = try XCTUnwrap(landed)
        defer { try? FileManager.default.removeItem(at: file) }
        let onDisk = (try FileManager.default.attributesOfItem(atPath: file.path)[.size]
                      as? Int) ?? 0
        XCTAssertEqual(onDisk, fileBytes, "the whole file must land on disk")
        let afterTransfer = Self.footprintBytes()
        print(String(format: "  transfer to disk: %.2f s over loopback (%.1f MB/s)",
                     transferSeconds, Double(fileBytes) / 1e6 / transferSeconds))
        print("  footprint after transfer: \(gb(afterTransfer)) "
              + "(+\(gb(afterTransfer &- baseline)))")

        // ── 2. DECODE from a MAPPED file ───────────────────────────────────
        let t1 = Date()
        let mapped = try Data(contentsOf: file, options: [.mappedIfSafe])
        let mesh = MeshExport.parseBinarySTL(mapped)
        let decodeSeconds = Date().timeIntervalSince(t1)
        let peak = Self.footprintBytes()
        print(String(format: "  mapped decode: %.2f s", decodeSeconds))
        print("  triangles: \(mesh.indices.count / 3)")
        print("  PEAK footprint (mapped bytes + soup): \(gb(peak)) "
              + "(+\(gb(peak &- baseline)))")
        print(String(format: "  TOTAL wall: %.2f s", transferSeconds + decodeSeconds))
        XCTAssertGreaterThan(mesh.indices.count, 0, "the decoded mesh must be usable")
    }

    /// AND WHAT IT COSTS TO *SHOW* IT. Holding the decoded soup is not the end of
    /// the bill: `ResultsModel.selectedMesh` builds a `ViewerMesh`, which keeps
    /// positions, smooth normals, unsigned indices AND the unshared flat-shaded
    /// render buffer — several more copies of the same geometry — and that is what
    /// the Metal viewer draws. Measured rather than derived, because this is the
    /// number that decides whether "select the latticed variant and look at it" is
    /// a thing the app can do at all.
    func testViewerMeshBuildCostForOneLatticedVariant() throws {
        try XCTSkipUnless(enabled, "set TOPOPT_LATTICE_TRANSFER_PROFILE=1 and "
                          + "TOPOPT_LATTICE_STL=<path to a real latticed STL>")
        let path = try XCTUnwrap(stlPath, "TOPOPT_LATTICE_STL must name a latticed STL")
        let baseline = Self.footprintBytes()
        let mapped = try Data(contentsOf: URL(fileURLWithPath: path),
                              options: [.mappedIfSafe])
        let mesh = MeshExport.parseBinarySTL(mapped)
        let afterDecode = Self.footprintBytes()
        print("== lattice viewer-mesh build cost ==")
        print("  triangles: \(mesh.indices.count / 3)")
        print("  footprint after decode: \(gb(afterDecode)) "
              + "(+\(gb(afterDecode &- baseline)))")
        let t0 = Date()
        let viewer = ViewerMesh(vertices: mesh.vertices, indices: mesh.indices,
                                faceIDs: [], smoothShaded: true)
        let seconds = Date().timeIntervalSince(t0)
        let peak = Self.footprintBytes()
        print(String(format: "  ViewerMesh build: %.2f s", seconds))
        print("  viewer triangles: \(viewer.triangleCount)")
        print("  PEAK footprint (soup + ViewerMesh): \(gb(peak)) "
              + "(+\(gb(peak &- baseline)))")
        XCTAssertGreaterThan(viewer.triangleCount, 0, "the viewer mesh must be usable")
    }
}

/// The smallest HTTP server that can answer one GET with a file body. Serves the
/// bytes with `Content-Length` and no chunking, which is what the worker's
/// `/files/{name}` route does, so the client side of the measurement is the same
/// work it would be against a real worker.
final class LoopbackFileServer {
    let port: UInt16
    private let fd: Int32
    private var running = true
    private let queue = DispatchQueue(label: "loopback-file-server")

    init(path: String) throws {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0

        let listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw NSError(domain: "loopback", code: 1) }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                    // let the kernel pick a free port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listenFD, 4) == 0 else {
            close(listenFD); throw NSError(domain: "loopback", code: 2)
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
                // Drain the request line + headers.
                var scratch = [UInt8](repeating: 0, count: 8192)
                _ = read(client, &scratch, scratch.count)
                let head = "HTTP/1.1 200 OK\r\nContent-Length: \(size)\r\n"
                    + "Content-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
                _ = head.withCString { write(client, $0, strlen($0)) }
                // Stream the file in 4 MB slabs so the SERVER's own footprint does
                // not contaminate the client-side measurement this test is for.
                try? handle.seek(toOffset: 0)
                var sent = 0
                while sent < size {
                    guard let slab = try? handle.read(upToCount: 4 << 20), !slab.isEmpty
                    else { break }
                    slab.withUnsafeBytes { raw in
                        var off = 0
                        while off < raw.count {
                            let n = write(client, raw.baseAddress!.advanced(by: off),
                                          raw.count - off)
                            if n <= 0 { off = raw.count } else { off += n }
                        }
                    }
                    sent += slab.count
                }
                close(client)
            }
        }
    }

    func stop() {
        running = false
        close(fd)
    }
}
