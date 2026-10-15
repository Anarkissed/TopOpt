// FlexibleSectors — the Flexible stage's OWN sectors (task 2026-09-29-flexible-screens, round 7 batch M2; the reviewer's
// ruling 3 on the 2026-10-14 outbox: "Lattice sections under a face-prism on the Squish page: FLEXIBLE-ONLY sectors carried
// in the job, NOT Surface-stage sectors (his Oct 10 reversal kept group types separate; nothing reaches other stages until
// he approves on Flexible). If I2 already writes Surface sectors, move them to Flexible-only and say what moved.").
//
// TESTS-FIRST STUB (M2): the types and the API, with `resolve` returning nothing. The implementation follows the red run.

import Foundation
import simd

/// One Flexible-only sector: a lattice SECTION (the part of a face, or of his own Surface sector, inside a face-prism), an
/// edge/corner STRIP, or a strip's REST.
public struct FlexibleSector: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case section, strip, rest }
    /// Its stable ROLE key (never geometry): "s:<root>:<prism key>#<k>", "p:<press>:<member>", "rest:<parent>:<n>".
    public let key: String
    public let number: Int
    public var wireID: Int { FlexibleSectors.base + number }
    /// The region the job declares (id = FlexibleRegions' sector offset away from the wire id).
    public let region: FaceRegion
    public let kind: Kind
    /// The section key, or the root token, it belongs to (a section: its own key).
    public let chain: String
    /// "f<face>" (a whole face) or "r<FaceRegion id>" (his Surface sector).
    public let rootToken: String
    /// The root as a Flexible region id: the face id, or his Surface sector's wire id.
    public let rootRegion: Int
    /// A strip piece's press and member index.
    public let press: UUID?
    public let member: Int?
    /// The section it lies in (a section: itself; a strip or rest on a whole root: nil).
    public let sectionKey: String?
}

/// Every Flexible-only sector of the part as it is now, and what each root is.
public struct FlexibleSectorSet: Equatable, Sendable {
    public var pieces: [FlexibleSector] = []
    /// Roots partly inside a face-prism (root region id → its section keys).
    public var partialRoots: [Int: [String]] = [:]
    /// Roots wholly inside a face-prism.
    public var wholeRoots: Set<Int> = []
    /// Roots a face-prism meets that cannot be cut into sections yet (D4) → the one line.
    public var notYet: [Int: String] = [:]
    /// Strip picks that cannot be cut → the one line.
    public var refused: [UUID: String] = [:]
    /// A kept strip that was clipped or has no lattice under it → the one line (said once on its card).
    public var notes: [UUID: String] = [:]
    /// Each strip press's regions (Flexible wire ids, member order).
    public var stripRegions: [UUID: [Int]] = [:]

    public init() {}
    public static let empty = FlexibleSectorSet()
    public var isEmpty: Bool { pieces.isEmpty }
    public func piece(_ wireID: Int) -> FlexibleSector? { pieces.first { $0.wireID == wireID } }
    public func piece(key: String) -> FlexibleSector? { pieces.first { $0.key == key } }
}

public enum FlexibleSectors {
    /// Flexible-only sector wire ids start here (his Surface sectors are FlexibleRegions.sectorBase + id, below it).
    public static let base = 2_000_000
    public static func isFlexible(_ id: Int) -> Bool { id >= base }

    /// ★ RED CONTROL (FlexibleSectorStoreTests): I2's route — the strips are ALSO written into `project.faceRegions` (the
    /// Surface stage's regions), so Topology, the Lattice stage and the Stress solve see them.
    @MainActor static var controlSurfaceRoute = false
    /// ★ RED CONTROL (numbers): a new key takes the smallest free number (a number of a key gone this session recycled).
    nonisolated(unsafe) static var controlRecycle = false

    /// The part's Flexible sectors. TESTS-FIRST STUB: nothing.
    static func resolve(mesh: ViewerMesh, faceRegions: FaceRegionModel, includes: [LatticeRegionSpec],
                        strips: [(id: UUID, strip: FlexibleStrip)], newPicks: Set<UUID> = [],
                        numbers: FlexibleSectorNumbers) -> FlexibleSectorSet {
        FlexibleSectorSet()
    }
}

/// ★ THE NUMBERS (M2): a key keeps its number for the session (undo and redo never renumber it); a new key takes one more
/// than every number seen (the store's and this session's), so a number is NEVER reused. Seeded from the store.
public final class FlexibleSectorNumbers {
    public private(set) var byKey: [String: Int] = [:]
    public init(seed: [String: Int] = [:]) { byKey = seed }

    /// Merge a store's numbers (a key already numbered keeps its session number).
    public func seed(_ ids: [String: Int]) { for (k, n) in ids where byKey[k] == nil { byKey[k] = n } }

    /// The number of `key`, made when new.
    public func number(_ key: String) -> Int {
        if let n = byKey[key] { return n }
        let n: Int
        if FlexibleSectors.controlRecycle {
            let used = Set(byKey.values)
            var k = 1
            while used.contains(k) { k += 1 }
            n = k
        } else {
            n = (byKey.values.max() ?? 0) + 1
        }
        byKey[key] = n
        return n
    }

    /// The key a number was given to, or nil.
    public func key(of number: Int) -> String? { byKey.first { $0.value == number }?.key }

    /// ★ CONTROL ONLY: forget keys not in `live` (what a recycling counter would do).
    func forget(except live: Set<String>) { byKey = byKey.filter { live.contains($0.key) } }
}
