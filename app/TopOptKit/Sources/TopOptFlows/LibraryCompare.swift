// LibraryCompare.swift — Compare's steps (approved Library mockup 2026-10-25, DATA-MODEL.md "Compare"; ★ his iPad notes
// 11-05, ledger L3, his "Yes, as written").
//
// Two big linked 3D views of two results. ★ L3 (replacing the 10-25 "Better, then ›" step): Better under one side is the
// choice — the other side is Rejected (the view marks it as he goes) and the next result comes in on its side; the winner
// stays. Tie sets both aside and the next two come in. Once every result has been seen, the set-aside ones come back
// against the winner so far; a second Tie ends Compare with the ones still undecided In consideration. The last one left is
// the part's chosen result. Rejected results are skipped while that switch is on (decision 1). One optimization's results
// compare side by side (three-up), with one Best — unchanged.
//
// Pure value types: the view only draws them.

import Foundation

/// One result of one version: a project folder and the result's index (0 = a).
public struct CompareItem: Hashable, Sendable {
    public let folder: UUID
    public let result: Int
    public init(folder: UUID, result: Int) { self.folder = folder; self.result = result }
}

public enum CompareSide: Sendable { case left, right }

public struct CompareSession: Equatable {
    /// How a Compare ends: one result left (the part's chosen), or a second Tie (these stay In consideration).
    public enum End: Equatable {
        case chosen(CompareItem)
        case undecided([CompareItem])
    }

    /// Every result in the order it is offered: best rated first, then the newest version, then a, b, c.
    public let queue: [CompareItem]
    public private(set) var left: CompareItem?
    public private(set) var right: CompareItem?
    /// Every result that has been on screen, in order.
    public private(set) var seen: [CompareItem] = []
    /// Not on screen yet, in the queue's order.
    public private(set) var waiting: [CompareItem]
    /// Set aside by Tie, in order; they come back once `waiting` is empty.
    public private(set) var setAside: [CompareItem] = []
    /// True once the set-aside ones are back: a Tie now ends Compare.
    public private(set) var secondLook = false
    /// Every result Better rejected in this Compare, in order.
    public private(set) var rejected: [CompareItem] = []
    public private(set) var end: End?

    /// Opens on the two best.
    public init(part: LibraryPart, skipRejected: Bool) {
        queue = Self.queue(part, skipRejected: skipRejected)
        left = queue.first
        right = queue.dropFirst().first
        waiting = Array(queue.dropFirst(2))
        seen = [left, right].compactMap { $0 }
    }

    /// The results Compare offers: every result of every version that has results, without drafts.
    public static func queue(_ part: LibraryPart, skipRejected: Bool) -> [CompareItem] {
        var rows: [(item: CompareItem, stars: Double, number: VersionNumber)] = []
        for v in part.versions {
            guard let summary = v.summary else { continue }
            for r in summary.indices {
                let mark = v.mark(for: r)
                if skipRejected, mark.rejected { continue }
                rows.append((CompareItem(folder: v.folderID, result: r), mark.stars, v.number))
            }
        }
        return rows.sorted {
            if $0.stars != $1.stars { return $0.stars > $1.stars }
            if $0.number != $1.number { return $0.number > $1.number }
            return $0.item.result < $1.item.result
        }.map(\.item)
    }

    /// Results still to come on screen (the set-aside ones included).
    public var remaining: Int { waiting.count + setAside.count }

    /// Tie needs two on screen.
    public var canTie: Bool { end == nil && left != nil && right != nil }

    /// Better under a side: the other side's result is rejected (returned, for the view to mark) and the next result comes in
    /// on its side; the winner stays. With nothing left, the winner is the part's chosen and Compare ends.
    @discardableResult public mutating func better(_ side: CompareSide) -> CompareItem? {
        guard end == nil, let winner = side == .left ? left : right else { return nil }
        let loser = side == .left ? right : left
        if let loser { rejected.append(loser) }
        let next = takeNext()
        if side == .left { right = next } else { left = next }
        if let next, !seen.contains(next) { seen.append(next) }
        if next == nil { end = .chosen(winner) }
        return loser
    }

    /// Tie: both are set aside and the next two come in. In the second look (the set-aside ones back), Tie ends Compare: the
    /// two on screen and every one still waiting stay In consideration.
    public mutating func tie() {
        guard canTie, let l = left, let r = right else { return }
        if secondLook { end = .undecided([l, r] + setAside + waiting); return }
        setAside += [l, r]
        left = takeNext()
        right = takeNext()
        for i in [left, right].compactMap({ $0 }) where !seen.contains(i) { seen.append(i) }
    }

    /// The next result for a free side: one not yet seen, else one set aside (the second look starts).
    private mutating func takeNext() -> CompareItem? {
        if !waiting.isEmpty { return waiting.removeFirst() }
        if !setAside.isEmpty { secondLook = true; return setAside.removeFirst() }
        return nil
    }

    /// He chose a result for a side from its menu: it comes onto that side, and the one it replaces waits its turn again.
    public mutating func set(_ side: CompareSide, to item: CompareItem) {
        guard end == nil else { return }
        let old = side == .left ? left : right
        guard old != item, item != (side == .left ? right : left) else { return }
        waiting.removeAll { $0 == item }
        setAside.removeAll { $0 == item }
        if let old { waiting.insert(old, at: 0) }
        if side == .left { left = item } else { right = item }
        if !seen.contains(item) { seen.append(item) }
    }

    /// One optimization's results, side by side (rejected ones included: he is looking at that run).
    public static func threeUp(_ v: LibraryVersion) -> ThreeUpSession {
        ThreeUpSession(items: (v.summary ?? []).indices.map { CompareItem(folder: v.folderID, result: $0) })
    }
}

/// One optimization's results, side by side, with one Best.
public struct ThreeUpSession: Equatable {
    public var items: [CompareItem]
    public var best: CompareItem?
    public init(items: [CompareItem], best: CompareItem? = nil) { self.items = items; self.best = best }
    public mutating func toggleBest(_ item: CompareItem) { best = best == item ? nil : item }
}
