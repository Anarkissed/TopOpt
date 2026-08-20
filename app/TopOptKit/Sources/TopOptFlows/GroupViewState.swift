// GroupViewState.swift — ★ HIDE AND LOCK, PER GROUP (maintainer, 2026-08-18).
//
// ★ HIS WORDS: "Please place two icons on the right side of the Group
// rectangles: One is to view or hide all the primitives/colours of that group:
// eye or crossed eye with a tap. The other is a lock and unlock. This will make
// it so no changes can be made to this group. One tap to lock, another to
// unlock."
//
// ★★ THEY ARE DIFFERENT KINDS OF THING, AND THE DIFFERENCE MATTERS.
//
//   HIDDEN is about the PICTURE. It suppresses the group's tints and its
//   primitives on screen and changes nothing about the run. A hidden group is
//   still anchored, still loaded, still latticed — it is just not drawn. So it
//   is deliberately NOT persisted: it is a way of getting something out of your
//   eyeline for a minute, and a project that reopened with half its selections
//   invisible would be a project that looks broken.
//
//   LOCKED is about the STATE. It refuses edits. That IS a property of the
//   project — "I am done with this group, stop letting me nudge it" — so it
//   persists, and every mutation path has to honour it or the padlock is a
//   picture of a lock rather than a lock.
//
// ★ A LOCK THAT DOES NOT LOCK IS THE WORST CONTROL ON THE PAGE. `canEdit` is the
// one question every call site asks; `GroupViewStateTests` enumerates the paths
// that must ask it.

import Foundation

public struct GroupViewState: Equatable, Sendable, Codable {

    /// Groups whose tints and primitives are suppressed on screen. Session
    /// scope — see the header: hiding is about the picture, not the project.
    public var hidden: Set<UUID>
    /// Groups that refuse edits. Persisted.
    public var locked: Set<UUID>

    public init(hidden: Set<UUID> = [], locked: Set<UUID> = []) {
        self.hidden = hidden
        self.locked = locked
    }

    // ── hidden ──────────────────────────────────────────────────────────────

    public func isHidden(_ id: UUID) -> Bool { hidden.contains(id) }

    public mutating func toggleHidden(_ id: UUID) {
        if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) }
    }

    /// The SF Symbol for the eye control, in its current state.
    public static func eyeSymbol(hidden: Bool) -> String {
        hidden ? "eye.slash" : "eye"
    }

    // ── locked ──────────────────────────────────────────────────────────────

    public func isLocked(_ id: UUID) -> Bool { locked.contains(id) }

    public mutating func toggleLocked(_ id: UUID) {
        if locked.contains(id) { locked.remove(id) } else { locked.insert(id) }
    }

    public static func lockSymbol(locked: Bool) -> String {
        locked ? "lock.fill" : "lock.open"
    }

    /// ★ THE ONE QUESTION EVERY MUTATION PATH ASKS. Named for what it decides,
    /// not for the flag it reads, so a call site cannot half-answer it.
    public func canEdit(_ id: UUID) -> Bool { !locked.contains(id) }

    // ── the two are independent ─────────────────────────────────────────────

    /// ★ HIDING DOES NOT LOCK, AND LOCKING DOES NOT HIDE. Tying them would make
    /// one control do two jobs and leave the user no way to say the common
    /// thing — "keep this out of my way but leave it editable", or "I can see
    /// it, I just don't want to change it".
    public func isHiddenAndLocked(_ id: UUID) -> Bool {
        isHidden(id) && isLocked(id)
    }

    /// Forget a group entirely — called when one is deleted, so a re-used UUID
    /// (or a stale entry) cannot resurrect someone else's state.
    public mutating func forget(_ id: UUID) {
        hidden.remove(id)
        locked.remove(id)
    }
}
