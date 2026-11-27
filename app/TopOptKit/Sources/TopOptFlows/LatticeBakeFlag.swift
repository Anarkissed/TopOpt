import Foundation

/// ★ ONE BOOL, SET ON MAIN AND READ OFF IT (2026-09-07). The strut bake runs its
/// stages on a background queue and must be able to stop when a newer bake has taken
/// over — but a bake thread must never `DispatchQueue.main.sync` to ask (a deadlock
/// against a main thread waiting on this work, and an off-actor read of SwiftUI state
/// besides). The completion, which already runs on main and already compares the
/// generation, sets this instead; the stage loop reads it under the same lock.
public final class LatticeBakeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}
