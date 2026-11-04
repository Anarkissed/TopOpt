// LibraryCompare.swift — Compare's steps (approved Library mockup 2026-10-25, DATA-MODEL.md "Compare").
//
// Two big linked 3D views of two results. He taps Better under one; a › appears on the other side; ›
// brings in the next result he has not seen AND clears Better, so every pair is an active choice (his
// decision 2). The one he picked stays, so stepping visits every result once. Rejected results are
// skipped while that switch is on (decision 1). One optimization's results compare side by side
// (three-up), with one Best.
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
    /// Every result in the order it is offered: best rated first, then the newest version, then a, b, c.
    public let queue: [CompareItem]
    public private(set) var left: CompareItem?
    public private(set) var right: CompareItem?
    /// The side he tapped Better under; nil until he chooses.
    public private(set) var kept: CompareSide?
    /// Every result that has been on screen, in order.
    public private(set) var seen: [CompareItem] = []

    /// Opens on the two best.
    public init(part: LibraryPart, skipRejected: Bool) {
        queue = Self.queue(part, skipRejected: skipRejected)
        left = queue.first
        right = queue.dropFirst().first
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

    /// Results not yet shown.
    public var remaining: Int { queue.filter { !seen.contains($0) }.count }

    /// Better under a side; again on the same side undoes it.
    public mutating func pick(_ side: CompareSide) { kept = kept == side ? nil : side }

    /// The › shows on the side he did not pick, while there is a result left to bring in.
    public func showsNext(on side: CompareSide) -> Bool {
        guard let kept else { return false }
        return kept != side && remaining > 0
    }

    /// Bring the next result he has not seen into the side he did not pick, and clear Better.
    /// False when he has not picked, or every result has been seen.
    public mutating func next() -> Bool {
        guard let kept, let nx = queue.first(where: { !seen.contains($0) }) else { return false }
        if kept == .left { right = nx } else { left = nx }
        seen.append(nx)
        self.kept = nil
        return true
    }

    /// He chose a result for a side from its menu: a new pair, so a new choice.
    public mutating func set(_ side: CompareSide, to item: CompareItem) {
        if side == .left { left = item } else { right = item }
        if !seen.contains(item) { seen.append(item) }
        kept = nil
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
