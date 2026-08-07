// LatticeMeshBudget — can this device hold that latticed mesh?
// (task 2026-08-07-lattice-variants-on-screen, bar R3.)
//
// ═══════════════════════════════════════════════════════════════════════════
// THE MEASUREMENT THIS ENCODES — AND WHY THERE IS A GATE AT ALL
// ═══════════════════════════════════════════════════════════════════════════
//
// The four latticed meshes on the maintainer's own run are 740 MB, 1.06 GB,
// 1.42 GB and 1.95 GB — 5.17 GB for the set. The task asked what ONE of them
// costs before any plumbing was designed. Measured on an M2 Pro (16 GB), release
// build, against the app's own fetch and its own STL decoder
// (`LatticeMeshTransferProfileTests`, raw output in
// evidence/2026-08-07-lattice-variants-on-screen/):
//
//   rung 0.52, 1.42 GB on disk, 28 401 196 triangles
//     in-memory GET (today's `fetchMesh` shape)   2.13 s, footprint 4.30 GB
//     + MeshExport.parseBinarySTL                 3.44 s, PEAK 6.07 GB
//     streamed to disk + mapped decode            1.69 s + 9.65 s, PEAK 3.21 GB
//     + ViewerMesh (what the viewer draws)       13.07 s, PEAK 6.15 GB
//
// Three things follow, and each one is a decision this file exists to make.
//
// (1) THE IN-MEMORY GET IS THE DOMINANT COST, NOT THE GEOMETRY. `URLSession`'s
//     accumulating `dataTask` held 4.30 GB for a 1.42 GB body — 3.0× the payload.
//     Streaming the same bytes to a file with `downloadTask` held 1.45 GB. So the
//     transfer that today's `fetchMesh` performs is, by itself, more expensive
//     than the object it is transferring.
//
// (2) DISPLAY COSTS ROUGHLY 4.3× THE FILE. The decoded soup is 9 floats + 3
//     indices per triangle (0.96× the STL's own bytes), and `ViewerMesh` then adds
//     smooth normals AND the unshared flat-shaded render buffer on top. 6.15 GB
//     for a 1.42 GB rung, and 13 s of build time, on a machine with 16 GB.
//
// (3) NO iPad CAN DO (2), AND SOME CANNOT DO ANY OF IT. iPadOS gives a foreground
//     app a fraction of physical RAM before jetsam, and the app asks the OS for
//     that number directly (`os_proc_available_memory`) rather than guessing from
//     a model name. The gate below compares the two.
//
// *** WHAT THIS GATE MUST NEVER DO IS STAY SILENT. *** The whole cost of the
// original defect was a silent substitution: the solid shown as though it were
// everything. A refusal here therefore carries the numbers — what the object is,
// what it would cost, what this device has — and the caller is required to put
// them on screen. `Verdict.refusalReason` is that sentence.

import Foundation
#if canImport(os)
import os
#endif

public enum LatticeMeshBudget {

    #if canImport(os)
    private static let log = Logger(subsystem: "app.topopt", category: "lattice-budget")
    #endif

    /// Record what this device said, and what was decided from it. The `available`
    /// figure on an iPad is `os_proc_available_memory()` — the real jetsam headroom
    /// for this process, which is not knowable from a Mac and not simulated
    /// faithfully by the Simulator (the Simulator has the host's memory, so a
    /// transfer that would be refused on hardware sails through there). Logging it
    /// is what lets a device QA pass report the hardware's own answer.
    public static func logDecision(meshName: String, fileBytes: Int,
                                   available: Int, fits: Bool) {
        #if canImport(os)
        log.info("""
            lattice mesh budget: \(meshName, privacy: .public) \
            \(byteLabel(fileBytes), privacy: .public) → needs \
            \(byteLabel(displayFootprintBytes(fileBytes: fileBytes)), privacy: .public), \
            device has \(byteLabel(available), privacy: .public) → \
            \(fits ? "FITS" : "REFUSED", privacy: .public)
            """)
        #endif
    }

    /// What the app would hold if it decoded a latticed STL of `fileBytes` for
    /// DISPLAY: the mapped file's resident share, the decoded soup, and the
    /// `ViewerMesh` built from it.
    ///
    /// Derived from the layout, then RAISED to clear every measurement — because a
    /// gate that under-predicts is a gate that lets a crash through, and the two
    /// runs below disagree by enough that a fitted constant would be a fiction.
    ///
    /// The layout: a binary STL is 84 + 50 bytes per triangle. The decoded soup is
    /// 9 position floats + 3 Int32 indices = 48 B/tri. The `ViewerMesh` built from
    /// it holds positions (36 B/tri), smooth normals (36), UInt32 indices (12), and
    /// the unshared flat render buffer's positions and normals again (36 + 36) —
    /// 156 B/tri. With the source file's own mapped pages still resident that is
    /// (50 + 48 + 156)/50 = 5.08× the file.
    ///
    /// Measured, release build, M2 Pro (`LatticeMeshTransferProfileTests` and the
    /// R1 evidence run):
    ///   rung 0.52, 1.42 GB → 6.15 GB peak                    = 4.33×
    ///   rung 0.26, 740 MB  → +3.82 GB over baseline, in situ = 5.17×
    /// The two differ because how much of the mapped file stays resident is the
    /// kernel's decision, not the app's. 6.0 clears the layout bound, both
    /// measurements, and leaves room for the fact that neither is a guarantee.
    public static let measuredRatio: Double = 6.0

    public static func displayFootprintBytes(fileBytes: Int) -> Int {
        guard fileBytes > 0 else { return 0 }
        return Int((Double(fileBytes) * measuredRatio).rounded())
    }

    /// What the app would hold merely to WRITE the mesh out — nothing beyond the
    /// streaming buffer, because an export never decodes. This is why export stays
    /// reachable on a device that cannot display the same object.
    public static let exportFootprintBytes = 8 << 20   // one download buffer

    /// The bytes this process may still allocate before the OS kills it. On iOS /
    /// iPadOS that is `os_proc_available_memory()`, which is the jetsam headroom
    /// the system itself will enforce — not a guess from the device model. On
    /// macOS there is no such per-process limit, so the honest answer is the
    /// machine's physical memory less what this process already holds.
    public static func availableBytes() -> Int {
        #if os(iOS)
        return os_proc_available_memory()
        #else
        let physical = Int(ProcessInfo.processInfo.physicalMemory)
        return Swift.max(0, physical - Int(footprintBytes()))
        #endif
    }

    /// This process's current resident footprint — the same `phys_footprint` the
    /// run's per-rung memory signpost stamps (`RemoteRun.memoryCheckpoint`).
    public static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    /// Headroom kept back so a decode that JUST fits does not leave the app with
    /// nothing to render, animate or export with. 25 % of the requirement, floored
    /// at 256 MB.
    static func reserveBytes(for requirement: Int) -> Int {
        Swift.max(256 << 20, requirement / 4)
    }

    public enum Verdict: Equatable, Sendable {
        /// The mesh can be brought over and displayed on this device.
        case fits
        /// It cannot, and this is the sentence saying so — with the numbers.
        case refused(String)

        public var fits: Bool { if case .fits = self { return true }; return false }
        public var refusalReason: String? {
            if case .refused(let r) = self { return r }
            return nil
        }
    }

    /// Whether this device can DISPLAY a latticed mesh of `fileBytes`.
    ///
    /// `available` is injectable so the decision is testable without a device of
    /// any particular size — the production callers pass `availableBytes()`.
    public static func displayVerdict(fileBytes: Int, available: Int,
                                      meshName: String = "") -> Verdict {
        guard fileBytes > 0 else {
            return .refused(
                "The worker did not report how large this latticed mesh is, so "
                + "there is no way to know whether it fits on this device before "
                + "trying. Not starting a transfer that could take the app down "
                + "mid-way — the lattice is on the worker and can be exported.")
        }
        let need = displayFootprintBytes(fileBytes: fileBytes)
        let reserve = reserveBytes(for: need)
        guard available >= need + reserve else {
            return .refused(
                "This latticed mesh exists on the worker (\(byteLabel(fileBytes))"
                + (meshName.isEmpty ? "" : ", \(meshName)")
                + ") but it cannot be shown on this device: decoding it for display "
                + "needs about \(byteLabel(need)) of memory and this device has "
                + "\(byteLabel(available)) left before the system would stop the app. "
                + "Its mass, margin and verdict below are the real ones, read from "
                + "the certification receipt — and Export still writes the full "
                + "latticed file, which streams to disk and never has to be decoded.")
        }
        return .fits
    }

    /// Whether this device can EXPORT a latticed mesh of `fileBytes` — a question
    /// about DISK, not memory, because the transfer streams. Refuses only when the
    /// volume genuinely cannot hold the file.
    public static func exportVerdict(fileBytes: Int, freeDiskBytes: Int) -> Verdict {
        guard fileBytes > 0 else {
            return .refused(
                "The worker did not report how large this latticed mesh is, so the "
                + "export cannot be checked against the free space on this device "
                + "first. Try again, or export from the worker's own folder.")
        }
        guard freeDiskBytes >= fileBytes + (256 << 20) else {
            return .refused(
                "This latticed mesh is \(byteLabel(fileBytes)) and this device has "
                + "\(byteLabel(freeDiskBytes)) free. Free up space and try again — "
                + "the file is on the worker and is not going anywhere.")
        }
        return .fits
    }

    /// Free space on the volume the app writes to. 0 when it cannot be determined,
    /// which `exportVerdict` reads as "refuse and say so".
    public static func freeDiskBytes(
        at url: URL = URL(fileURLWithPath: NSTemporaryDirectory())) -> Int {
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let bytes = values?.volumeAvailableCapacityForImportantUsage {
            return Int(bytes)
        }
        return 0
    }

    /// "1.42 GB" / "740 MB" / "12 KB" — the unit a person reads, never raw bytes.
    public static func byteLabel(_ bytes: Int) -> String {
        let b = Double(bytes)
        if b >= 1e9 { return String(format: "%.2f GB", b / 1e9) }
        if b >= 1e6 { return String(format: "%.0f MB", b / 1e6) }
        if b >= 1e3 { return String(format: "%.0f KB", b / 1e3) }
        return "\(bytes) bytes"
    }
}
