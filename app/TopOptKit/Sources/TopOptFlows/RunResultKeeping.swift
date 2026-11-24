// RunResultKeeping.swift — ★ his iPad notes 2026-11-23 (img 4, 5, 6), on his v7 (Structural, Organic): he pressed Lattice, the
// Mac made the print file (strengthening, the file and its strength check, 880 s) while TopOpt sat in the background behind
// Sidecar, a notification came, and its tap opened the Library: v7's card greyed, v7 opening on Topology with no Results, the
// Lattice stage with none either. The result was never saved: the app was gone right after the run finished.
//
// His words: "Please find out what the hell is going on?" "Tapping the notification should bring you RIGHT to the result
// screen. Nothing else." "The result should be accessible from the Versions page just by tapping onto the version." "If going
// to edit it, the "results" screen should be in the Lattice Stage." "The result should NOT be greyed out on the version screen."
//
// This file holds the pieces the fix shares: where a finished run's result is (`RunResultRoute`, carried by its notification),
// the background time the app holds while a run is on the Mac and while its result is written (`BackgroundTime`), the
// notification's tap (`RunNotificationRouter`), and what tells a print file's result from a Topology one (`LatticeSavedResult`).
import Foundation
import Combine
import TopOptKit
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: where a run's result is

/// The version a finished run's result was saved to, and whether it opens in the Lattice stage (a Lattice run's) or on
/// Topology. Carried in the completion notification's userInfo.
public struct RunResultRoute: Equatable, Sendable {
    public var projectID: UUID
    public var lattice: Bool

    public init(projectID: UUID, lattice: Bool) {
        self.projectID = projectID
        self.lattice = lattice
    }

    /// The run's own: its version, and its mode (the Lattice button's print file, or the old lattice run). nil without a version.
    public init?(_ request: RunRequest) {
        guard let id = request.projectID else { return nil }
        self.init(projectID: id, lattice: Self.isLatticeMode(request.jobMode))
    }

    static func isLatticeMode(_ mode: String) -> Bool { mode == LatticeFileButton.jobMode || mode == "lattice_part" }

    static let versionKey = "topopt.version"
    static let stageKey = "topopt.opens"

    public var userInfo: [String: String] {
        [Self.versionKey: projectID.uuidString, Self.stageKey: lattice ? "lattice" : "topology"]
    }

    /// The route a notification carries; nil for one that carries none (an older build's, or not a run's).
    public init?(userInfo: [AnyHashable: Any]) {
        guard let s = userInfo[Self.versionKey] as? String, let id = UUID(uuidString: s) else { return nil }
        self.init(projectID: id, lattice: (userInfo[Self.stageKey] as? String) == "lattice")
    }
}

// MARK: background time

/// Time the app asks iOS for so a job is not cut short when it leaves the screen: the whole of a run on the Mac, and a finished
/// run's result until its file has landed. Tokens, so each piece ends only its own. Injected for tests (a spy).
@MainActor
public protocol BackgroundTime: AnyObject {
    func begin(_ name: String) -> Int
    func end(_ token: Int)
}

/// The system's (`beginBackgroundTask`); iOS ending the time early ends that token. Off the iPad, nothing to ask.
@MainActor
public final class SystemBackgroundTime: BackgroundTime {
    private var next = 1
    #if canImport(UIKit)
    private var tasks: [Int: UIBackgroundTaskIdentifier] = [:]
    #endif

    public init() {}

    public func begin(_ name: String) -> Int {
        let token = next
        next += 1
        #if canImport(UIKit)
        if LocalRunNotifier.hasAppBundle {
            tasks[token] = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                MainActor.assumeIsolated { self?.end(token) }   // iOS reclaiming the time: released cleanly
            }
        }
        #endif
        return token
    }

    public func end(_ token: Int) {
        #if canImport(UIKit)
        guard let t = tasks.removeValue(forKey: token), t != .invalid else { return }
        UIApplication.shared.endBackgroundTask(t)
        #endif
    }
}

// MARK: the notification's tap

/// ★ his notes 11-23 ("Tapping the notification should bring you RIGHT to the result screen. Nothing else."): the app's
/// notification centre delegate, set up as the app starts (TopOptApp). A tap hands its route to the app (`pending`, which
/// RootView passes to `AppModel.openResult`); a run's notification is shown in the foreground too.
public final class RunNotificationRouter: NSObject {
    public static let shared = RunNotificationRouter()

    /// The route a tap asked for, until the app takes it.
    @Published public private(set) var pending: RunResultRoute?
    /// The app screen a tap goes to: the one that attached last (RootView, on appear). One in the field; never every listener
    /// (a screen still alive from before would take a tap meant for another app's version).
    private weak var app: AppModel?

    /// RootView's model, as its screen appears: a tap goes to it (one already waiting, at once).
    @MainActor public func attach(_ model: AppModel) {
        app = model
        if pending != nil { deliver() }
    }

    private func deliver() {
        // (on the next turn: `pending` is set by then)
        Task { @MainActor [weak self] in
            guard let self, let app = self.app else { return }
            app.openTappedResult(self)
        }
    }

    /// Set as the notification centre's delegate (once, as the app starts — a tap that launched the app arrives through it).
    public static func install() {
        #if canImport(UserNotifications)
        if LocalRunNotifier.hasAppBundle { UNUserNotificationCenter.current().delegate = shared }
        #endif
    }

    /// A tap on a notification carrying `userInfo` (the delegate's, and the tests').
    public func tapped(userInfo: [AnyHashable: Any]) {
        guard let r = RunResultRoute(userInfo: userInfo) else { return }
        let post = { self.pending = r; self.deliver() }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    /// The app took the route.
    public func take() -> RunResultRoute? {
        defer { pending = nil }
        return pending
    }
}

#if canImport(UserNotifications)
extension RunNotificationRouter: UNUserNotificationCenterDelegate {
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // the run's banner while the app is in front too
        completionHandler([.banner, .list, .sound])
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            tapped(userInfo: response.notification.request.content.userInfo)
        }
        completionHandler()
    }
}
#endif

// MARK: a print file's result

/// What tells the Lattice button's print file result (lattice_file.json's report rides it: "layout", "mesh", "print_check")
/// from a Topology one, and whether that saved result is Approved.
public enum LatticeSavedResult {
    /// The outcome is a print file's (its report is lattice_file.json's).
    public static func isPrintFile(_ o: OptimizeOutcome?) -> Bool {
        guard let d = o?.reportJSON, let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return false }
        return j["layout"] is [String: Any] && j["mesh"] is [String: Any] && j["print_check"] is [String: Any]
    }

    /// A result opens in the Lattice stage when it is a print file's.
    public static func opensInLattice(_ o: OptimizeOutcome?) -> Bool { isPrintFile(o) }

    /// ★ his notes 11-23 (item 5): the Lattice button's "Approved", worked out from the SAVED result: the version's result is
    /// a print file that passes its checks (`LatticePrintFlow.passes`), and the settings it ran with (`ranWith`, saved with
    /// it) are the version's settings now. Survives a relaunch, unlike the button's memory.
    @MainActor
    public static func approved(_ p: ProjectModel, ranWith: ProjectSnapshot?) -> Bool {
        guard p.run.phase != .running, let o = p.run.outcome(lattice: true), let ranWith,   // ★ notes25: wherever it is kept
              LatticePrintFlow.passes(o, organic: LatticeLayoutPreview.organic(p.lattice), infillNow: p.printParams.infillPercent),
              let now = p.snapshot(savedAt: ranWith.savedAt) else { return false }
        return LibrarySettings.same(ranWith, now)
    }
}

/// ★ his notes 11-23: the Results screen is on screen now (it stays when the app leaves the front; a new one never mounts
/// while the app is not in front — its mesh is the biggest thing the app draws). Plain, not observed: only read as a body runs.
public final class ResultsMounted {
    public var mounted = false
    public init() {}
}

/// ★ notes25 (his iPad notes 11-23, Img 4: "The "Results" page is hidden in the ^ menu. It is meant to be next to the
/// "Setting" tab at the very top, as it is in Topology"; his follow-up: "when adding the Results tab to lattice, remove it from
/// the ^ menu"): the Lattice stage's third tab, Setup │ Lattice │ Results, opening the version's print file result. (The ⌃'s
/// "Results" row of 11-23 is gone.)
enum LatticeResultsTab {
    /// Topology's own word for its tab.
    static let title = TopologyPage.results.title
    /// Hidden — not greyed — while the version has no lattice result: Topology's rule for its Results tab (B8), mirrored.
    static func hidden(hasResult: Bool) -> Set<StageCapsule.Page> { hasResult ? [] : [.tertiary] }
}
