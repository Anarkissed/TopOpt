import Foundation
import SwiftUI
import TopOptDesign
import TopOptKit

/// ★ LOAD SCENARIOS (his order, 2026-10-26; the shared job key is fixed by the overnight release, 03:45 his time).
///
/// "Each scenario is checked on its own. Loads in different scenarios never act together; loads in the same scenario act
/// together." Scenario 1 holds every load that existed before scenarios did. Anchors are SHARED by default; an anchor made
/// while another scenario is open belongs to that scenario only ("Add Anchor"). A shared anchor can be switched OFF in one
/// scenario (addendum 03:32: "held by one plate" scenarios); it draws dimmed there, never hidden, and a scenario always
/// keeps at least one anchor on.
///
/// Stored on `ForceModel.scenarios` — nil means ONE scenario, and the project and its job are byte-identical to before.
public struct LoadScenario: Equatable, Sendable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    /// Anchors switched off in THIS scenario only.
    public var anchorsOff: Set<UUID> = []

    public init(id: UUID = UUID(), name: String, anchorsOff: Set<UUID> = []) {
        self.id = id; self.name = name; self.anchorsOff = anchorsOff
    }
}

public struct LoadScenarioSet: Equatable, Sendable, Codable {
    /// Scenario 1 first; never fewer than two (one scenario is `nil`).
    public var scenarios: [LoadScenario]
    /// The scenario a group belongs to. A LOAD absent here is Scenario 1's; an ANCHOR absent here is shared.
    public var owner: [UUID: UUID] = [:]
    public var activeID: UUID
}

public enum LoadScenarioRule {
    /// The (i) beside "+ Add a load scenario" — his sentence, verbatim, then (his yes 2026-10-28, with TO-core's weighting)
    /// how much each scenario shapes the design.
    public static let info = "Each scenario is checked on its own. Loads in different scenarios never act together; loads in the same scenario act together. Each scenario shapes the part in proportion to its load: a light one adds only a light connection."
    /// The inline refusal when the last anchor on would be switched off.
    public static let lastAnchorRefusal = "A scenario needs at least one anchor on."
    /// ★ OPTIMIZE'S PRE-FLIGHT (362's ruling 2026-10-26 06:54): the same words core refuses with, before anything is sent.
    public static func noAnchorLine(_ name: String) -> String { "Scenario “\(name)” has no anchor switched on" }
    public static func noLoadLine(_ name: String) -> String { "Scenario “\(name)” has no load" }
    /// The iPad's own solver reads one load case: a 2-scenario run there would check Scenario 1 alone, silently.
    public static let onDeviceLine = "Load scenarios run on the Mac worker only"
    /// The one-tap fix under a scenario left with every anchor off (an anchor group was deleted).
    public static let switchAnchorsOnLabel = "Switch its anchors on"

    /// Why Optimize may not send this request, or nil. Only a 2+ scenario request is ever refused here. Scenarios WITH
    /// "Redesign to strengthen" are sent (his order, ruling 2026-10-26 12:46: "It needs to work together!"). Bolt
    /// bearings: the app never sends `anchor_model`, so core's bearing refusal cannot arise from the app.
    public static func refusal(for request: RunRequest, workerSelected: Bool) -> String? {
        guard request.scenarios.count >= 2 else { return nil }
        if let s = request.scenarios.first(where: { $0.anchorFaceIDs.isEmpty }) { return noAnchorLine(s.name) }
        if let s = request.scenarios.first(where: { $0.loadGroups.isEmpty }) { return noLoadLine(s.name) }
        if !workerSelected { return onDeviceLine }
        return nil
    }
    public static func defaultName(_ index: Int) -> String { "Scenario \(index + 1)" }
}

extension ForceModel {
    /// The scenarios, Scenario 1 first. One implicit "Scenario 1" when none were added.
    public var scenarioList: [LoadScenario] {
        scenarios?.scenarios ?? [LoadScenario(id: Self.implicitScenarioID, name: LoadScenarioRule.defaultName(0))]
    }
    /// The id the implicit Scenario 1 answers to before any scenario was added.
    public static let implicitScenarioID = UUID(uuidString: "00000000-0000-0000-0000-00000000005C")!

    public var hasScenarios: Bool { (scenarios?.scenarios.count ?? 0) >= 2 }
    public var activeScenarioID: UUID { scenarios?.activeID ?? Self.implicitScenarioID }
    public var activeScenario: LoadScenario { scenarioList.first { $0.id == activeScenarioID } ?? scenarioList[0] }

    /// The scenario a group belongs to; nil = every scenario (a shared anchor, and any group that is not a load or an
    /// anchor: keep-clear, lattice, a pick with no role yet).
    public func scenarioID(of group: UUID) -> UUID? {
        let k = kind(for: group)
        guard k.isLoad || k.isAnchor else { return nil }
        if let o = scenarios?.owner[group] { return o }
        return k.isLoad ? scenarioList[0].id : nil
    }

    /// Whether a group belongs to `scenario` (a shared anchor belongs to all of them).
    public func group(_ group: UUID, isIn scenario: UUID) -> Bool {
        guard let s = scenarioID(of: group) else { return true }
        return s == scenario
    }

    /// The open scenario shows only its own loads and anchors (shared anchors included, dimmed when off).
    public func showsInActiveScenario(_ group: UUID) -> Bool { self.group(group, isIn: activeScenarioID) }

    /// Whether an anchor holds in `scenario` (shared anchors can be switched off per scenario).
    public func anchorIsOn(_ group: UUID, in scenario: UUID) -> Bool {
        guard self.group(group, isIn: scenario) else { return false }
        return !(scenarioList.first { $0.id == scenario }?.anchorsOff.contains(group) ?? false)
    }

    /// The anchors of `scenario` that are ON, in `order` (the selection's group order).
    public func anchorsOn(in scenario: UUID, order: [UUID]) -> [UUID] {
        order.filter { kind(for: $0).isAnchor && anchorIsOn($0, in: scenario) }
    }

    /// Add a scenario ("Scenario N") and open it. The first add makes Scenario 1 real, holding every existing load.
    @discardableResult
    public mutating func addScenario() -> UUID {
        var set = scenarios ?? LoadScenarioSet(scenarios: [LoadScenario(name: LoadScenarioRule.defaultName(0))],
                                               activeID: UUID())
        let s = LoadScenario(name: LoadScenarioRule.defaultName(set.scenarios.count))
        set.scenarios.append(s)
        set.activeID = s.id
        scenarios = set
        return s.id
    }

    /// Rename a scenario; a blank name is ignored.
    public mutating func renameScenario(_ id: UUID, to name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, var set = scenarios, let i = set.scenarios.firstIndex(where: { $0.id == id }) else { return }
        set.scenarios[i].name = t
        scenarios = set
    }

    public mutating func openScenario(_ id: UUID) {
        guard var set = scenarios, set.scenarios.contains(where: { $0.id == id }) else { return }
        set.activeID = id
        scenarios = set
    }

    /// Remove a scenario (never Scenario 1): its loads and its own anchors move to Scenario 1 (nothing is deleted).
    /// Down to one scenario, the set goes away and the project is exactly a one-scenario project again.
    public mutating func removeScenario(_ id: UUID) {
        guard var set = scenarios, let i = set.scenarios.firstIndex(where: { $0.id == id }), i > 0 else { return }
        set.scenarios.remove(at: i)
        let first = set.scenarios[0].id
        set.owner = set.owner.mapValues { $0 == id ? first : $0 }
        if set.activeID == id { set.activeID = set.scenarios[0].id }
        scenarios = set.scenarios.count >= 2 ? set : nil
    }

    /// Switch an anchor on or off in one scenario. Returns the refusal line when it is the scenario's last anchor on.
    @discardableResult
    public mutating func setAnchor(_ group: UUID, on: Bool, in scenario: UUID, order: [UUID]) -> String? {
        guard var set = scenarios, let i = set.scenarios.firstIndex(where: { $0.id == scenario }) else { return nil }
        if on {
            set.scenarios[i].anchorsOff.remove(group)
        } else {
            guard anchorsOn(in: scenario, order: order).filter({ $0 != group }).count >= 1 else {
                return LoadScenarioRule.lastAnchorRefusal
            }
            set.scenarios[i].anchorsOff.insert(group)
        }
        scenarios = set
        return nil
    }

    /// Switch every anchor of a scenario back on (the one-tap fix when none is left on).
    public mutating func switchAllAnchorsOn(in scenario: UUID) {
        guard var set = scenarios, let i = set.scenarios.firstIndex(where: { $0.id == scenario }) else { return }
        set.scenarios[i].anchorsOff = []
        scenarios = set
    }

    /// From `makeAnchor` / `makeLoad`, BEFORE the role is written: a group that becomes a load or an anchor while a later
    /// scenario is open belongs to that scenario ("Add Anchor" in Scenario 2 holds in Scenario 2 only). A load or anchor keeps
    /// what it already is; in Scenario 1 nothing is recorded (a load there is Scenario 1's, an anchor is shared).
    mutating func claimForOpenScenario(_ group: UUID) {
        let k = kind(for: group)
        guard var set = scenarios, set.owner[group] == nil, !k.isLoad, !k.isAnchor,
              set.activeID != set.scenarios[0].id else { return }
        set.owner[group] = set.activeID
        scenarios = set
    }

    /// From `sync(groups:)`: deleted groups drop out of every scenario.
    mutating func syncScenarios(live: Set<UUID>) {
        guard var set = scenarios else { return }
        set.owner = set.owner.filter { live.contains($0.key) }
        for i in set.scenarios.indices { set.scenarios[i].anchorsOff.formIntersection(live) }
        scenarios = set
    }
}

/// ★ HIS iPad 2026-10-26 14:13: "All pieces including primitives in all other scenarios should be hidden when in a
/// scenario. I don't want to see anything." What one group draws in the open scenario — its colour, its keep-out volumes,
/// their knobs and chips: everything, a switched-off anchor FAINT (its colour and its keep-outs), or nothing at all.
public enum ScenarioDraw: Equatable, Sendable {
    case shown, dimmed, hidden
}

extension ForceModel {
    /// `applies`: scenarios rule this screen (Topology). Off it, or with one scenario, everything is shown.
    public func scenarioDraw(_ group: UUID, applies: Bool) -> ScenarioDraw {
        guard applies, hasScenarios else { return .shown }
        guard showsInActiveScenario(group) else { return .hidden }
        return kind(for: group).isAnchor && !anchorIsOn(group, in: activeScenarioID) ? .dimmed : .shown
    }
}

/// One scenario on the wire (job.json `loads.scenarios[]`, the overnight release's shared key).
public struct LoadScenarioWire: Equatable, Sendable {
    public let name: String
    public let anchorFaceIDs: [Int]
    public let loadGroups: [TopOptKit.LoadGroupSpec]
    public init(name: String, anchorFaceIDs: [Int], loadGroups: [TopOptKit.LoadGroupSpec]) {
        self.name = name; self.anchorFaceIDs = anchorFaceIDs; self.loadGroups = loadGroups
    }
}

/// One scenario's result (report.json `scenarios[]`).
public struct ScenarioResult: Equatable, Sendable {
    public let name: String
    public let margin: Double?
    public let governs: Bool
    public let unheld: Bool
    /// ★ Results redesign: the scenario's own worst point (report `peak_mpa`, `peak_mm`) — marked on the model when he
    /// picks the scenario. nil on an older report.
    public var peakMPa: Double? = nil
    public var peakMM: SIMD3<Double>? = nil

    public static func parse(_ report: [String: Any]) -> [ScenarioResult] {
        (report["scenarios"] as? [[String: Any]] ?? []).map(one)
    }

    /// One `scenarios[]` entry (the run's, or a strengthen version's).
    static func one(_ o: [String: Any]) -> ScenarioResult {
        let p = (o["peak_mm"] as? [NSNumber])?.map(\.doubleValue)
        return ScenarioResult(name: o["name"] as? String ?? "",
                              margin: (o["margin"] as? NSNumber)?.doubleValue,
                              governs: o["governs"] as? Bool ?? false,
                              unheld: o["unheld"] as? Bool ?? false,
                              peakMPa: (o["peak_mpa"] as? NSNumber)?.doubleValue,
                              peakMM: p.flatMap { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil })
    }

    /// "Worst case: <name> · N×" for the governing scenario, or nil (fewer than two scenarios, or none governs).
    public static func governingLine(_ results: [ScenarioResult]) -> String? {
        guard results.count >= 2, let g = results.first(where: { $0.governs }) else { return nil }
        return g.margin.map { "Worst case: \(g.name) · \(String(format: "%.2f", $0))×" } ?? "Worst case: \(g.name)"
    }

    /// The results lines: the governing scenario named with its margin, then one plain line per unheld scenario.
    public static func lines(_ results: [ScenarioResult]) -> [String] {
        guard results.count >= 2 else { return [] }
        var out: [String] = governingLine(results).map { [$0] } ?? []
        for r in results where r.unheld { out.append("\(r.name)'s load has no path to its anchors") }
        return out
    }
}

/// The results' scenario lines: the governing scenario named with its margin, and one plain line per unheld scenario (no card).
struct ScenarioResultLines: View {
    let results: [ScenarioResult]

    @ViewBuilder var body: some View {
        let lines = ScenarioResult.lines(results)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                ForEach(lines, id: \.self) { l in
                    Text(l).dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
                        .foregroundStyle((l.hasPrefix("Worst case") ? DS.Color.textPrimary : DS.Color.warning).color)
                }
            }
            .background(GeometryReader { geo in
                Color.clear.preference(key: ChromeKeepOutKey.self, value: ["scenarioResults": geo.frame(in: .global)])
            }.allowsHitTesting(false))
            .accessibilityIdentifier("scenario-results")
        }
    }
}
