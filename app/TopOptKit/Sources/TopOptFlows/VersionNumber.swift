// VersionNumber.swift — v7, v4.1, v4.1.1 (his decision 11, 2026-10-25 20:12): "if you decide to run an
// optimization for an older version - let's say most recent is v7 and I want to run v4 again - it should
// come out with 'v4.1' not 'v8' so that it's clear what it was."
//
// A number is a path: [7] is on the main line, [4, 1] is the first branch from v4, [4, 1, 1] that
// branch's own child. Ordered as a tree (v4, v4.1, v4.1.1, v4.2, v5), so a branch sorts right after the
// version it came from. On disk a main-line number is the plain integer a file written before branches
// held ("number": 3), and a branch is its dotted text ("number": "4.1").

import Foundation

public struct VersionNumber: Hashable, Comparable, Sendable, CustomStringConvertible, ExpressibleByIntegerLiteral {
    /// Each part 1 or more.
    public let path: [Int]

    public init(_ main: Int) { path = [max(1, main)] }
    public init(integerLiteral value: Int) { self.init(value) }
    init(path: [Int]) { self.path = path }

    /// "4.1.1"; nil for anything else ("4..1", "0", "v4").
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ ($0 ?? 0) >= 1 }) else { return nil }
        path = parts.map { $0! }
    }

    public var description: String { path.map(String.init).joined(separator: ".") }
    /// The main-line number it belongs to (4 for v4.1.1).
    public var main: Int { path[0] }
    public var isMainLine: Bool { path.count == 1 }
    /// The version it branched from (v4 for v4.1); nil on the main line.
    public var parent: VersionNumber? { isMainLine ? nil : VersionNumber(path: Array(path.dropLast())) }
    public func child(_ k: Int) -> VersionNumber { VersionNumber(path: path + [k]) }

    /// Tree order: a parent before its branches, a branch before the next main-line version.
    public static func < (a: VersionNumber, b: VersionNumber) -> Bool { a.path.lexicographicallyPrecedes(b.path) }

    /// The Part folder's Newest order: newest main line first, each with its branches right under it.
    public static func newestFirst(_ a: VersionNumber, _ b: VersionNumber) -> Bool {
        a.main != b.main ? a.main > b.main : a < b
    }
}

extension VersionNumber: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { self.init(n); return }
        let text = try c.decode(String.self)
        guard let v = VersionNumber(text) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "“\(text)” is not a version number")
        }
        self = v
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if isMainLine { try c.encode(main) } else { try c.encode(description) }
    }
}

extension LibraryPart {
    /// The number a version made FROM `parent` gets. From the newest main-line version (or none) the main
    /// line continues; from any other version it branches one level under it. Never a number given before.
    public func nextNumber(from parent: VersionNumber?) -> VersionNumber {
        let mainNow = versions.map(\.number).filter(\.isMainLine).map(\.main).max() ?? 0
        guard let parent, !(parent.isMainLine && parent.main >= mainNow) else {
            return VersionNumber(max(lastNumber ?? 0, mainNow) + 1)
        }
        let children = versions.map(\.number).filter { $0.parent == parent }.compactMap(\.path.last).max() ?? 0
        return parent.child(max(children, lastChild?[parent.description] ?? 0) + 1)
    }

    /// Drop a version whose folder is gone, remembering its number so it is never given again.
    public mutating func forget(_ v: LibraryVersion) {
        versions.removeAll { $0.folderID == v.folderID }
        if let parent = v.number.parent, let k = v.number.path.last {
            var marks = lastChild ?? [:]
            marks[parent.description] = max(marks[parent.description] ?? 0, k)
            lastChild = marks
        } else {
            let highest = max(lastNumber ?? 0, v.number.main)
            if highest > (versions.map(\.number).filter(\.isMainLine).map(\.main).max() ?? 0) { lastNumber = highest }
        }
    }

    /// The newest main-line version: where a version with no stated parent continues from.
    var newestMainLine: LibraryVersion? { versions.filter(\.number.isMainLine).max { $0.number < $1.number } }
}
