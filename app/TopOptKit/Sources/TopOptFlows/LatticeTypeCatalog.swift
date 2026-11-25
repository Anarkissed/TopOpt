// LatticeTypeCatalog.swift — ★★ LATTICE TYPES ROUND 1, U1 + U2 (TASK 2026-09-28-lattice-types-app;
// docs/design/lattice-types/03-app-spec.md §2).
//
// THE OFFERED SET COMES FROM CORE. A type may be picked only when core can BUILD it
// (`lattice_gen_topology_names`), CERTIFY it (`lattice_certifiable_topology_names`) — M6: Aesthetic
// still certifies — and its JOB PARSER accepts the id (`TopOptKit.jobSchemaAcceptsTopology`), so a
// type core lights up is offered only with a job that will run. Today that is the octet alone.
// ★★ notes28 (2026-11-24): the Lattice stage's picker reads the NEW engine's facts instead (`layoutEntries`: what the engine
// lays, for Structural or Aesthetic), and the type gate is open for all ten strut types; `entries` stays the OLD run's.
//
// EVERY OTHER TYPE STAYS VISIBLE AND GREYED, WITH CORE'S REASON (03 §2; M1: BCCZ, FCCZ and
// Re-entrant included). ★ Since the #358 sync the verdict AND the words are core's
// (`lattice_type_readiness` + `lattice_type_readiness_plain`, brief item a, maintainer round 2:
// "bring in lattice_type_readiness_plain() for the picker words"). The app adds one line core has
// no state for: built and certified, but core's job parser refuses the id (`jobRefused`).
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
    /// ★ notes28: what its card says under its name when it can't be picked, at most five words (his rule); its (i) is
    /// `reason`. nil: the catalog's general word (`LatticeTypeCatalog.caption`).
    public var caption: String? = nil
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

    /// The one reason core has no state for: it can build and certify the type, but its job
    /// parser refuses the id, so a run would be refused.
    public static let jobRefused = "Core’s run doesn’t accept this type yet."

    /// ★★ THE TYPE GATE (reviewer, 2026-11-04 21:40Z, release (2): "only types with their B7.n app batch show"). K1 makes
    /// eight types live in core; the app offers a type only once its own batch (its card, finish and pictures on the
    /// Lattice page, B7.n) has shipped. A type core runs and the app does not yet is greyed with `appBatchPending`. Add an
    /// id here in the batch that ships its page.
    /// ★★ notes28 (the maintainer's decision 2026-11-24): ALL the strut types, on the new engine — the seven Structural and
    /// Aesthetic ones and the three Aesthetic-only ones (core's `structuralRefusal`). Each card's picture is the engine's own sample of
    /// the type (`LatticeTypePicture`), and each has its own strut law (`LatticeType.named`).
    /// ★★ SHEETS (notes28 sheets SPEC 5, builder C): gyroid and Schwarz-D join, ON THE NEW ENGINE ONLY — never the old run
    /// (`batchShipped`): a sheet is offered where the engine lays and makes the part's lattice.
    public static let appBatches: Set<String> = ["octet", "sc", "bcc", "fcc", "diamond", "kelvin", "rhombic",
                                                 "bccz", "fccz", "reentrant", "gyroid", "schwarz_d"]
    /// ★★ SHEETS: the types the OLD run may carry (its spec, Optimize's lattice, an STL part's stage): the strut types only.
    public static let oldRunBatches: Set<String> = appBatches.subtracting(sheetIDs)
    /// The sheet ids (core's family "sheet"; ids, so the gate needs no bridge call).
    public static let sheetIDs: Set<String> = ["gyroid", "schwarz_d"]

    /// ★★ notes28 — STRUCTURAL, CORE'S OWN TWO VERDICTS (builder D's types.cpp, merged f82ac0b8; 362 11-24: "mirror both
    /// through the bridge instead of re-deriving them in Swift"), read through `LatticeLayoutSession.typeFacts`:
    ///   · `structuralRefusal` — Structural can never take the type (the tetragonal three, BCC + Z, FCC + Z and Re-entrant:
    ///     their tensors need a tetragonal certification not built). A fixed rule, core's; its card says `aestheticOnlyCaption`.
    ///   · `structuralNote` — the type's measured strength law credits none of the struts the engine lays (today SC and
    ///     BCC: their laws start past the open look). Until builder F's re-measured laws land, Structural does not offer it
    ///     (his ruling via 362: "showing 'Strength measured only for denser struts' while it does not"); it opens by itself.
    /// Each is nil or core's ONE plain line, which is the card's (i).
    public static func structuralRefusal(_ id: String) -> String? { LatticeLayoutSession.typeFacts(id).structuralRefusal }
    public static func structuralNote(_ id: String) -> String? { LatticeLayoutSession.typeFacts(id).structuralNote }
    /// His rule: a caption under a setting is at most five words.
    public static let aestheticOnlyCaption = "Aesthetic only"
    public static let strengthUnmeasuredCaption = "Strength measured for denser struts"

    /// ★ notes28 (362's ruling 2026-11-24, his rule "NOT PRINT-TESTED"): every strut type he has not marked print-tested
    /// (`AppSettings.latticePrintTested`; octet and BCC + Z start tested) wears this tag on its card, with an (i) saying how
    /// it goes.
    public static let notPrintTestedCaption = "Not print-tested"
    public static func notPrintTestedInfo(_ name: String) -> String {
        "\(name) hasn’t been print-tested yet. Print its sample coupon; when it prints well, mark it tested here and this "
            + "tag goes, on every project."
    }
    /// The tag shows on `id`'s card (a type he has not marked tested; ★ SHEETS: the sheets too, neither starts tested).
    public static func showsNotPrintTested(_ id: String, tested: Set<String>) -> Bool {
        appBatches.contains(id) && !tested.contains(id)
    }

    /// A strut type the new engine does not lay yet (core has no cell or no width limits for it): its caption and (i).
    public static let engineWaitsCaption = "Not in the engine yet"
    public static func engineWaitsInfo(_ name: String) -> String {
        "The lattice engine can’t lay \(name) yet: it has no cell for it. It arrives in an update."
    }
    /// A test's stand-in for `appBatches` (B7's two-type card test); nil in the app.
    nonisolated(unsafe) public static var appBatchesForTests: Set<String>? = nil
    /// ★ notes28: the one question every gate asks (the pickers, the old run's spec, Optimize's lattice): has `id`'s batch
    /// shipped? (The test stand-in first, so a test can close the gate again.)
    /// ★★ SHEETS: this is the OLD run's question (its spec, Optimize's lattice, an STL part's stage) — a sheet never ships there.
    public static func batchShipped(_ id: String) -> Bool {
        (appBatchesForTests ?? appBatches).contains(id) && (controlSheetsOnOldRun || !sheetIDs.contains(id))
    }
    /// ★★ SHEETS: has `id`'s batch shipped on the NEW engine (the Lattice stage on a STEP part)?
    public static func newEngineShipped(_ id: String) -> Bool { (appBatchesForTests ?? appBatches).contains(id) }
    /// RED CONTROL (tests): the sheets offered on the old run too (one gate for both, as before).
    nonisolated(unsafe) public static var controlSheetsOnOldRun = false
    /// The line for a type core runs whose app batch has not shipped.
    public static let appBatchPending = "Ready in the engine; its settings come in a later update."

    /// Core's words for a type it does not offer. A type on the round's list that core has no id
    /// for yet (the sheets, brief item b) is told core's "neither" line: core's own "Not a lattice
    /// type" would tell the user a planned type is not a lattice.
    static func coreReason(_ id: String, generatable: [String], certifiable: [String]) -> String? {
        switch TopOptKit.latticeTypeReadiness(id, generatable: generatable, certifiable: certifiable) {
        case .live: return nil
        case .unknownId where order.contains(id): return TopOptKit.latticeTypeReadinessPlain(.notEither)
        case let r: return TopOptKit.latticeTypeReadinessPlain(r)
        }
    }

    /// The entries from core's three facts, given explicitly (the pure form the tests drive).
    public static func entries(generatable: [String], certifiable: [String],
                               jobAccepts: (String) -> Bool,
                               appReady: (String) -> Bool = { _ in true }) -> [LatticeTypeEntry] {
        // a type core adds that this list does not know yet still shows (after the round's)
        let extra = (generatable + certifiable).filter { !order.contains($0) }
        var seen = Set<String>()
        return (order + extra).filter { seen.insert($0).inserted }.map { id in
            let reason = coreReason(id, generatable: generatable, certifiable: certifiable)
                ?? (jobAccepts(id) ? nil : jobRefused)
                ?? (appReady(id) ? nil : appBatchPending)   // ★ the type gate, after every core fact
            return LatticeTypeEntry(id: id, displayName: LatticeType.displayName(forID: id),
                                    offered: reason == nil, reason: reason)
        }
    }

    /// The entries read live from the linked core (the production path), behind the type gate.
    public static func entriesFromCore() -> [LatticeTypeEntry] {
        entries(generatable: TopOptKit.latticeGeneratableTopologies,
                certifiable: TopOptKit.latticeCertifiableTopologies,
                jobAccepts: TopOptKit.jobSchemaAcceptsTopology,
                appReady: batchShipped)
    }

    /// The ids that may be picked today.
    public static var offeredIDs: Set<String> {
        Set(entriesFromCore().filter(\.offered).map(\.id))
    }

    // MARK: - ★★ notes28: THE NEW ENGINE'S PICKER (the Lattice stage on a STEP part)

    /// The Lattice stage's catalog: what the NEW engine lays, for the part's stage. The old run's facts (`entries`: core's
    /// lattice_gen and its job parser) say what the OLD run can carry; the new engine asks its own two questions instead:
    ///   · a strut type is offered when the engine lays it (`engineLays`: core has its canonical cell and its two width
    ///     limits) and its batch has shipped (`appReady`);
    ///   · Structural also needs the strength check, so it takes only a type core certifies (`certifiable`), never one core
    ///     refuses for Structural (`structuralRefusal`: the tetragonal three, a fixed rule), and none whose measured strength
    ///     law credits none of the engine's struts yet (`structuralNote`) — each in core's own line, its card's caption the
    ///     catalog's five words;
    ///   · ★★ SHEETS: a sheet type is offered as a strut type is (the engine lays it: core's family "sheet").
    /// The pure form the tests drive; `layoutEntriesFromCore(structural:)` reads core.
    public static func layoutEntries(structural: Bool, certifiable: [String], engineLays: (String) -> Bool,
                                     structuralRefusal: (String) -> String? = { _ in nil },
                                     structuralNote: (String) -> String? = { _ in nil },
                                     appReady: (String) -> Bool = { appBatches.contains($0) }) -> [LatticeTypeEntry] {
        order.map { id in
            let name = LatticeType.displayName(forID: id)
            var reason: String?, caption: String?
            if !appReady(id) { reason = appBatchPending }
            else if !engineLays(id) { reason = engineWaitsInfo(name); caption = engineWaitsCaption }
            else if structural, let r = structuralRefusal(id) { reason = r; caption = aestheticOnlyCaption }
            else if structural, !certifiable.contains(id) { reason = TopOptKit.latticeTypeReadinessPlain(.notEither) }
            else if structural, let n = structuralNote(id) { reason = n; caption = strengthUnmeasuredCaption }
            var e = LatticeTypeEntry(id: id, displayName: name, offered: reason == nil, reason: reason)
            e.caption = caption
            return e
        }
    }

    /// The Lattice stage's catalog read live from the linked core (the engine's own facts, behind the type gate).
    public static func layoutEntriesFromCore(structural: Bool) -> [LatticeTypeEntry] {
        layoutEntries(structural: structural, certifiable: TopOptKit.latticeCertifiableTopologies,
                      engineLays: LatticeLayoutSession.lays, structuralRefusal: structuralRefusal,
                      structuralNote: structuralNote, appReady: newEngineShipped)   // ★★ SHEETS: the new engine's gate
    }

    /// What a card that cannot be picked shows UNDER its name, at most five words (his rule); its (i) holds the reason.
    /// nil: it can be picked.
    public static func caption(_ e: LatticeTypeEntry) -> String? {
        guard e.reason != nil else { return nil }
        return e.caption ?? "Not offered yet"
    }

    /// A greyed entry's one sentence: its reason, led by its name unless the reason names it already (the Aesthetic-only
    /// and engine lines do). nil: it can be picked.
    public static func line(_ e: LatticeTypeEntry) -> String? {
        guard !e.offered, let r = e.reason else { return nil }
        return r.contains(e.displayName) ? r : reasonLine(e)
    }

    /// Why the saved type cannot run on the Lattice stage for this stage (nil: it can) — the picker's own sentence, as
    /// `selectionRefusal` is the old run's.
    public static func layoutRefusal(_ id: String, structural: Bool) -> String? {
        stageRefusal(id, structural: structural, newEngine: true)
    }

    /// ★ notes28: the Lattice stage's catalog for a part: the new engine's (`layoutEntriesFromCore`) where it lays and makes
    /// the part's lattice (a STEP part), and where the OLD run still makes it (an STL part: `LatticeFileButton.takes`) a type
    /// must be one the old run can carry too — its words when it can't.
    public static func stageEntries(structural: Bool, newEngine: Bool) -> [LatticeTypeEntry] {
        let layout = layoutEntriesFromCore(structural: structural)
        guard !newEngine else { return layout }
        let old = entriesFromCore()
        return layout.map { e in e.offered ? (old.first { $0.id == e.id } ?? e) : e }
    }

    /// Why the saved type cannot run on this stage (nil: it can): the picker's own sentence.
    public static func stageRefusal(_ id: String, structural: Bool, newEngine: Bool) -> String? {
        let entries = stageEntries(structural: structural, newEngine: newEngine)
        guard let e = entries.first(where: { $0.id == id }) else { return selectionRefusal(id) }
        return line(e)
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
    /// nil when the type may run; an id the picker does not list gets core's words for it.
    public static func selectionRefusal(_ id: String, in entries: [LatticeTypeEntry]) -> String? {
        guard let e = entries.first(where: { $0.id == id }) else {
            let why = coreReason(id, generatable: TopOptKit.latticeGeneratableTopologies,
                                 certifiable: TopOptKit.latticeCertifiableTopologies)
                ?? TopOptKit.latticeTypeReadinessPlain(.unknownId)
            return "\(LatticeType.displayName(forID: id)): \(why)"
        }
        return e.offered ? nil : reasonLine(e)
    }
    public static func selectionRefusal(_ id: String) -> String? {
        selectionRefusal(id, in: entriesFromCore())
    }
}
