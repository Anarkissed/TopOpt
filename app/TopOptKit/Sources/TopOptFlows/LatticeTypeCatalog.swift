// LatticeTypeCatalog.swift — ★★ LATTICE TYPES ROUND 1, U1 + U2 (TASK 2026-09-28-lattice-types-app;
// docs/design/lattice-types/03-app-spec.md §2).
//
// THE OFFERED SET COMES FROM CORE. A type may be picked only when core can BUILD it
// (`lattice_gen_topology_names`), CERTIFY it (`lattice_certifiable_topology_names`) — M6: Aesthetic
// still certifies — and its JOB PARSER accepts the id (`TopOptKit.jobSchemaAcceptsTopology`), so a
// type core lights up is offered only with a job that will run. Today that is the octet alone.
//
// EVERY OTHER TYPE STAYS VISIBLE AND GREYED, WITH CORE'S REASON (03 §2; M1: BCCZ, FCCZ and
// Re-entrant included). Core publishes no reason string yet (core brief 2026-09-28, item a), so the
// reason is worded from core's own facts — which of the three it lacks — and changes nothing else.
//
// ORDER (03 §2, M4): Octet first, then the round's struts, then the sheets, then the types this
// round does not offer. NAMES: Q5's defaults (`LatticeType.displayName(forID:)`).
//
// One definition for both pickers: the Lattice stage's Type chips and the variant page's topology
// pane. Neither writes a topology the catalog does not offer, so no job can carry one.

import Foundation
import TopOptKit

public struct LatticeTypeEntry: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    /// Core can build, certify and run it: it may be picked.
    public let offered: Bool
    /// Why it may not be picked (nil when offered) — worded from core's facts.
    public let reason: String?
}

public enum LatticeTypeCatalog {

    /// The picker's order (03 §2). Ids are core's (`lattice_topology_name`), plus the two sheet
    /// ids the round adds ("gyroid", "schwarz_d" — `lattice_print_tests.json`; core has no enum
    /// value for them yet, core brief item b).
    public static let order: [String] = [
        "octet",                                                  // M4: first, and the default
        "sc", "bcc", "fcc", "diamond", "kelvin", "rhombic",       // the round's struts
        "gyroid", "schwarz_d",                                    // the round's sheets
        "bccz", "fccz", "reentrant",                              // M1: visible, greyed, last
    ]

    /// The reasons, worded from core's facts until core publishes its own (brief item a).
    public static let notBuilt = "Core can’t build this type yet."
    public static let notCertified = "Core can’t certify this type yet."
    public static let notBuiltOrCertified = "Core can’t build or certify this type yet."
    public static let jobRefused = "Core’s run doesn’t accept this type yet."

    /// The entries from core's three facts, given explicitly (the pure form the tests drive).
    public static func entries(generatable: [String], certifiable: [String],
                               jobAccepts: (String) -> Bool) -> [LatticeTypeEntry] {
        let gen = Set(generatable), cert = Set(certifiable)
        // a type core adds that this list does not know yet still shows (after the round's)
        let extra = (generatable + certifiable).filter { !order.contains($0) }
        var seen = Set<String>()
        return (order + extra).filter { seen.insert($0).inserted }.map { id in
            let reason: String?
            switch (gen.contains(id), cert.contains(id)) {
            case (true, true): reason = jobAccepts(id) ? nil : jobRefused
            case (true, false): reason = notCertified
            case (false, true): reason = notBuilt
            case (false, false): reason = notBuiltOrCertified
            }
            return LatticeTypeEntry(id: id, displayName: LatticeType.displayName(forID: id),
                                    offered: reason == nil, reason: reason)
        }
    }

    /// The entries read live from the linked core (the production path).
    public static func entriesFromCore() -> [LatticeTypeEntry] {
        entries(generatable: TopOptKit.latticeGeneratableTopologies,
                certifiable: TopOptKit.latticeCertifiableTopologies,
                jobAccepts: TopOptKit.jobSchemaAcceptsTopology)
    }

    /// The ids that may be picked today.
    public static var offeredIDs: Set<String> {
        Set(entriesFromCore().filter(\.offered).map(\.id))
    }

    /// A greyed type's line — its name and core's reason. The one sentence for the condition,
    /// wherever it shows (the picker's tap, the Lattice and Optimize buttons, the stage's line).
    public static func reasonLine(_ e: LatticeTypeEntry) -> String {
        "\(e.displayName): \(e.reason ?? "")"
    }

    /// ★ REVIEW 2026-10-01: a type saved BEFORE the catalog still rides a project — the variant
    /// page's old pane wrote any certifiable id unguarded. Its run carries NO lattice block
    /// (`LatticeSettings.runSpec` is nil for a type core can't build), so Optimize ran the part
    /// with no lattice and said nothing. Every start asks this first and says why. Never
    /// migrated: the pick stays his, and runs by itself once core makes the type live.
    /// nil when the type may run; an id core does not know at all is neither built nor certified.
    public static func selectionRefusal(_ id: String, in entries: [LatticeTypeEntry]) -> String? {
        guard let e = entries.first(where: { $0.id == id }) else {
            return "\(LatticeType.displayName(forID: id)): \(notBuiltOrCertified)"
        }
        return e.offered ? nil : reasonLine(e)
    }
    public static func selectionRefusal(_ id: String) -> String? {
        selectionRefusal(id, in: entriesFromCore())
    }
}
