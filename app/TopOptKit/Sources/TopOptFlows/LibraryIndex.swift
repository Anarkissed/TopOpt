// LibraryIndex.swift — the Library: Project → Part → Version (the approved Library mockup, 2026-10-25,
// reviewer-inbox/2026-10-25-library-mockup/DATA-MODEL.md).
//
// ★ HIS WORDS: "Right now, I am creating copies of the project, updating each a little bit, and
// comparing the results... it's just messy."
//
// The index FILES the project folders he already has. It never moves, copies or deletes one:
// a VERSION IS A PROJECT FOLDER (today's `ProjectSnapshot` + its results, unchanged), and the index
// only says which part it belongs to, its number, the version it came from, and his marks. Deleting
// library.json (Ungroup) puts the Library back exactly as it was.
//
// What is NOT stored here, because the folder already says it: whether a version is a draft (its
// snapshot has no results), its settings, and its results. One source of truth each.

import Foundation

/// The whole Library, written to `<projects root>/library.json`.
public struct LibraryIndex: Codable, Equatable, Sendable {
    /// Bump when the shape changes incompatibly; a newer file is never force-decoded.
    public static let currentSchema = 1

    public var schemaVersion: Int
    /// The project folders, in Library order.
    public var projects: [LibraryProject]
    /// Every part. A part in no project's `partIDs` is Unfiled.
    public var parts: [LibraryPart]

    public init(schemaVersion: Int = LibraryIndex.currentSchema,
                projects: [LibraryProject] = [], parts: [LibraryPart] = []) {
        self.schemaVersion = schemaVersion
        self.projects = projects
        self.parts = parts
    }

    /// Every project folder the index files, once each.
    public var folderIDs: [UUID] { parts.flatMap { $0.versions.map(\.folderID) } }

    /// The part a project folder is a version of.
    public func part(containing folderID: UUID) -> LibraryPart? {
        parts.first { $0.versions.contains { $0.folderID == folderID } }
    }

    /// The parts no project holds.
    public var unfiledParts: [LibraryPart] {
        let filed = Set(projects.flatMap(\.partIDs))
        return parts.filter { !filed.contains($0.id) }
    }
}

/// A folder on the Library ("Squish Mechanism"). It holds parts.
public struct LibraryProject: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var partIDs: [UUID]

    public init(id: UUID = UUID(), name: String, partIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.partIDs = partIDs
    }
}

/// One model file ("Carriage Arms"). Same bytes = same part.
public struct LibraryPart: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    /// SHA-256 of the model file's bytes, lowercase hex. nil when the model file was missing when
    /// the part was made: such a folder is a part of its own, never merged by name.
    public var modelHash: String?
    /// In number order.
    public var versions: [LibraryVersion]

    public init(id: UUID = UUID(), name: String, modelHash: String?, versions: [LibraryVersion] = []) {
        self.id = id
        self.name = name
        self.modelHash = modelHash
        self.versions = versions
    }

    /// The number the next version gets.
    public var nextNumber: Int { (versions.map(\.number).max() ?? 0) + 1 }

    public func version(number: Int) -> LibraryVersion? { versions.first { $0.number == number } }
    public func version(folderID: UUID) -> LibraryVersion? { versions.first { $0.folderID == folderID } }
}

/// One Optimize: a project folder, plus what the Library knows about it.
public struct LibraryVersion: Codable, Equatable, Sendable {
    /// The project folder this version is (`ProjectSnapshot.id`).
    public let folderID: UUID
    public var number: Int
    /// The version it came from; nil for a first version.
    public var parentNumber: Int?
    /// His own name; nil means the automatic one (`VersionChanges.autoName`). His decision 9
    /// (2026-10-25): grouped copies DROP their old "copy N" names.
    public var name: String?
    /// What changed from the parent, worked out when the version was made.
    public var changes: [VersionChange]
    /// His marks, one entry per result that has any.
    public var marks: [ResultMark]
    /// The result he picked (an index into the run's variants: 0 = a). nil = the suggested one.
    public var pickedResult: Int?
    /// A few numbers per result, so a card never decodes the 20 MB results file. nil until known.
    public var summary: [ResultSummary]?

    public init(folderID: UUID, number: Int, parentNumber: Int? = nil, name: String? = nil,
                changes: [VersionChange] = [], marks: [ResultMark] = [], pickedResult: Int? = nil,
                summary: [ResultSummary]? = nil) {
        self.folderID = folderID
        self.number = number
        self.parentNumber = parentNumber
        self.name = name
        self.changes = changes
        self.marks = marks
        self.pickedResult = pickedResult
        self.summary = summary
    }

    /// The marks on one result (an empty mark when it has none).
    public func mark(for result: Int) -> ResultMark {
        marks.first { $0.result == result } ?? ResultMark(result: result)
    }

    /// Replace one result's marks; an empty mark is not kept.
    public mutating func setMark(_ mark: ResultMark) {
        marks.removeAll { $0.result == mark.result }
        if !mark.isEmpty { marks.append(mark); marks.sort { $0.result < $1.result } }
    }
}

/// His marks on one result. His decision 1 (2026-10-25): stars in half steps, Print this, Rejected;
/// no Favourite.
public struct ResultMark: Codable, Equatable, Sendable {
    /// The result's index in the run's variants (0 = a, 1 = b, 2 = c).
    public let result: Int
    /// 0…5 in steps of 0.5; 0 = not rated.
    public private(set) var stars: Double
    public var printThis: Bool
    public var rejected: Bool

    public init(result: Int, stars: Double = 0, printThis: Bool = false, rejected: Bool = false) {
        self.result = result
        self.stars = ResultMark.clampStars(stars)
        self.printThis = printThis
        self.rejected = rejected
    }

    public mutating func setStars(_ value: Double) { stars = ResultMark.clampStars(value) }

    /// Round to the nearest half star, inside 0…5.
    public static func clampStars(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(5, max(0, (value * 2).rounded() / 2))
    }

    public var isEmpty: Bool { stars == 0 && !printThis && !rejected }
    /// The result's letter on screen: a, b, c, … (past z: its number).
    public static func letter(_ index: Int) -> String {
        (0..<26).contains(index) ? String(UnicodeScalar(UInt8(97 + index))) : "\(index + 1)"
    }
}

/// The numbers a card shows for one result, copied from its run's variant.
public struct ResultSummary: Codable, Equatable, Sendable {
    public var massGrams: Double
    public var worstCaseMargin: Double
    public var accepted: Bool
    public var achievedVolumeFraction: Double

    public init(massGrams: Double, worstCaseMargin: Double, accepted: Bool, achievedVolumeFraction: Double) {
        self.massGrams = massGrams
        self.worstCaseMargin = worstCaseMargin
        self.accepted = accepted
        self.achievedVolumeFraction = achievedVolumeFraction
    }
}

// MARK: - on disk

extension ProjectStore {
    /// `<projects root>/library.json`. `loadAll` lists only UUID-named folders, so this file is never
    /// mistaken for a project.
    public var libraryURL: URL { rootDir.appendingPathComponent("library.json") }

    /// The index, or nil when there is none (never grouped, or Ungrouped) or it cannot be read.
    /// Reading never writes; an unreadable or newer file is left exactly where it is.
    public func loadLibrary() -> LibraryIndex? {
        guard let data = try? Data(contentsOf: libraryURL) else { return nil }
        struct Peek: Decodable { let schemaVersion: Int? }
        if let v = (try? JSONDecoder().decode(Peek.self, from: data))?.schemaVersion,
           v > LibraryIndex.currentSchema { return nil }
        return try? JSONDecoder().decode(LibraryIndex.self, from: data)
    }

    public func saveLibrary(_ index: LibraryIndex) throws {
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(index).write(to: libraryURL, options: .atomic)
    }

    /// Ungroup: remove the index. Every project folder is untouched, so the Library is back exactly
    /// as it was before grouping.
    public func ungroupLibrary() {
        try? FileManager.default.removeItem(at: libraryURL)
    }

    /// The fingerprint of a project's model file (SHA-256 of its bytes), or nil when it is missing.
    public func modelHash(of snapshot: ProjectSnapshot) -> String? {
        LibraryGrouping.sha256(fileAt: URL(fileURLWithPath: modelPath(id: snapshot.id,
                                                                     fileName: snapshot.modelFileName)))
    }
}
