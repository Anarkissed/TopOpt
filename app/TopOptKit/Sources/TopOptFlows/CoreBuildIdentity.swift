// CoreBuildIdentity.swift — ★ THE LINKED CORE'S IDENTITY, STATED TO CORE ONCE (maintainer,
// 2026-10-02, at the #358 sync: "#358 found that bridge.cpp:1913 runs lattice_variant_job
// IN-PROCESS, so the app's relattice receipts still stamp fingerprint 'unknown'. Call
// topopt::set_build_identity(CoreFingerprint.value, <the linked core's build time>) once at
// bridge start-up, before the first bridge run.")
//
// Core stamps every receipt's `fingerprint` / `build_time` from what the EXECUTABLE stated; the
// CLI states its own in main(). In the app the executable is the app, and the identity it links
// is `CoreFingerprint` (written by app/scripts/build_core.sh with the core it built). Stated
// here, once per process (a Swift `static let` runs its initialiser exactly once), from the two
// places a bridge run can start: `AppModel.init` (the app's start-up) and `RunModel.bridgeRunner`
// (the one on-device run entry, for a RunModel used without an AppModel).
//
// Set-once in core: the same identity again is a no-op; a DIFFERENT one throws. Nothing here
// can state a different one, so a refusal means something else in the process stated first —
// it is logged and kept, never retried with another value.

import Foundation
import TopOptKit

public enum CoreBuildIdentity {

    /// nil once core holds this app's identity; else core's refusal, verbatim.
    public static let refusal: String? = {
        do {
            try TopOptKit.stateCoreBuildIdentity(fingerprint: CoreFingerprint.value,
                                                 buildTime: CoreFingerprint.buildTime)
            return nil
        } catch {
            let why = (error as? TopOptError)?.message ?? "\(error)"
            NSLog("DIAG core build identity NOT stated: \(why)")
            return why
        }
    }()

    /// States the identity on the first call; every later call reads the same outcome.
    @discardableResult
    public static func state() -> String? { refusal }

    /// The identity this app expects core to hold (what an in-app receipt must name).
    public static var expected: (fingerprint: String, buildTime: String) {
        (CoreFingerprint.value, CoreFingerprint.buildTime)
    }
}
