// RunProvenance.swift — WHICH MACHINE SOLVED THIS RUN (task
// 2026-08-03-variant-entry-gating-and-retention, bar AJ5).
//
// THE DEFECT THIS FILE EXISTS FOR. A finished run showed nothing about where it
// ran. When the maintainer tried to smooth a variant, the refusal told him to
// "re-run it on a Mac worker" — advice that is either the fix or an insult
// depending on a fact the app knew and never displayed. Worse, the same sentence
// is the honest advice for an on-device run AND the wrong advice for a worker run
// that simply predates design retention; without the machine on screen the user
// cannot tell which of those they are looking at.
//
// So the machine is resolved ONCE, here, from two recorded facts — the outcome's
// `computedRemotely` flag and the worker name the app DISPATCHED to — and is
// shown on the run summary and on every variant. Nothing is inferred: a run whose
// worker name was never recorded says exactly that rather than naming a worker
// that may not be the one.
//
// Pure value type, so the whole surface is headlessly testable (the /app/
// verification standard).

import Foundation
import TopOptKit

/// The machine a run was solved on.
public enum SolvingMachine: Equatable, Sendable {
    /// The bridge ran it in this process, on this iPad/Mac.
    case thisDevice
    /// A LAN worker, by the Bonjour name the user picked it under.
    case worker(name: String)
    /// A LAN worker whose name this result does not carry — a run re-attached
    /// after a relaunch, or a result persisted before the name was recorded. The
    /// UI says "a Mac worker" and not a guessed name.
    case unnamedWorker

    /// What the RUN FLOW recorded at dispatch: `remote` is whether the run was
    /// offloaded, `workerName` the worker it was offloaded to (nil when the app
    /// could not name it — e.g. a cold-launch re-attach).
    public static func dispatched(remote: Bool, workerName: String?) -> SolvingMachine {
        guard remote else { return .thisDevice }
        guard let n = workerName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !n.isEmpty else { return .unnamedWorker }
        return .worker(name: n)
    }

    /// What a FINISHED outcome says about itself. The two facts are read together
    /// on purpose: `solvedBy` alone cannot distinguish "solved here" from "solved
    /// on a worker we could not name".
    public static func resolve(computedRemotely: Bool, solvedBy: String?) -> SolvingMachine {
        dispatched(remote: computedRemotely, workerName: solvedBy)
    }

    /// Convenience over an outcome.
    public static func of(_ outcome: OptimizeOutcome) -> SolvingMachine {
        resolve(computedRemotely: outcome.computedRemotely, solvedBy: outcome.solvedBy)
    }

    /// The name to STORE on the outcome (nil for a local run — the
    /// `computedRemotely` flag already says it, and writing a device name here
    /// would make the two fields able to disagree).
    public var recordedName: String? {
        if case .worker(let n) = self { return n }
        return nil
    }

    /// True only for a run this device solved through the bridge.
    public var isThisDevice: Bool { self == .thisDevice }

    /// The compact chip label: "This device" / "Mac mini" / "A Mac worker".
    public var shortLabel: String {
        switch self {
        case .thisDevice: return "This device"
        case .worker(let n): return n
        case .unnamedWorker: return "A Mac worker"
        }
    }

    /// The full sentence used on the run summary and in refusal copy: "Solved on
    /// this device" / "Solved on Mac worker “Mac mini”" / "Solved on a Mac worker
    /// (name not recorded)".
    public var label: String {
        switch self {
        case .thisDevice: return "Solved on this device"
        case .worker(let n): return "Solved on Mac worker “\(n)”"
        case .unnamedWorker: return "Solved on a Mac worker (name not recorded)"
        }
    }

    /// The SF Symbol the chip carries, so device vs worker is distinguishable at a
    /// glance and not only by reading.
    public var symbol: String {
        isThisDevice ? "ipad" : "desktopcomputer"
    }
}
