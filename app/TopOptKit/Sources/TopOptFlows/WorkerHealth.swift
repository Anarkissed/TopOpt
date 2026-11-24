// WorkerHealth.swift — ★ notes25 (D9, his 11-23 screenshot: "Runs on ⚠ Nadim's Mac mini" while his Mac was fine).
//
// The ⚠ came only from the fingerprint the Mac advertises over Bonjour, which the worker app writes ONCE, when it starts.
// A release that swaps only the Mac's engine leaves that advertisement stale, so the iPad warned while the Mac's live
// `/health` (what every run checks before it sends anything) said the engines matched. The ⚠ now follows the live `/health`:
// asked once the chosen Mac is resolved, again when the app comes back to the front, and again whenever a run's own pre-job
// `/health` answers (the runners post it here). The Bonjour value is only a first hint until `/health` has answered.

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum WorkerHealth {
    /// A `/health` answered: userInfo "host" (String), "port" (Int), "fingerprint" (String).
    static let answered = Notification.Name("topopt.workerHealth.answered")

    /// The app came back to the front.
    @MainActor static var cameToFront: Notification.Name? {
        #if canImport(UIKit)
        return UIApplication.willEnterForegroundNotification
        #elseif canImport(AppKit)
        return NSApplication.didBecomeActiveNotification
        #else
        return nil
        #endif
    }

    /// What a `/health` said, for every Compute location model to hear (a run's own pre-job check calls this).
    static func heard(host: String, port: Int, fingerprint: String) {
        NotificationCenter.default.post(name: answered, object: nil,
                                        userInfo: ["host": host, "port": port, "fingerprint": fingerprint])
    }

    /// Tests only: stands in for the network (the Mac's `/health` fingerprint, or nil: it did not answer).
    nonisolated(unsafe) static var standIn: ((RemoteRunnerConfig) async -> String?)?

    /// The Mac's `/health` fingerprint, or nil when it did not answer (in the control timeout: never a hang).
    static func fingerprint(_ config: RemoteRunnerConfig) async -> String? {
        if let standIn { return await standIn(config) }
        var request = URLRequest(url: config.baseURL.appendingPathComponent("health"))
        request.timeoutInterval = config.controlTimeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return obj["fingerprint"] as? String
    }

    /// A model's notification observers, removed when it goes.
    final class Observers {
        private var tokens: [NSObjectProtocol] = []
        func add(_ t: NSObjectProtocol) { tokens.append(t) }
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}
