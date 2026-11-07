// ResultsPanels — ★ THE RESULTS REDESIGN (his mockup, approved 2026-10-27: https://claude.ai/artifact/UUdUdncK25JgZ2xVZT5Ehw).
//
// The model is the screen, as on Topology and Lattice; everything else floats and folds:
//   * bottom-left, a Versions panel (like Selections) — each version one line, the recommended one marked, an impossible one
//     greyed with its reason — and Compare at its foot;
//   * right, under the view cube: "Scenario" + its menu, the view buttons (Stress / Solid / X-ray / Load paths), the Checks
//     panel (one line + one sub-line each, never overlapping), then "Details", which opens UPWARD and scrolls;
//   * Compare: full screen, two (or, with three or more versions, all three) side by side; Details expands in place.
// Smooth and the moving load-path animation are gone (his notes 2026-10-27).
//
// The words and the version/compare rules are pure values here, asserted headlessly; the views follow them.

import Foundation
import SwiftUI
import simd
import TopOptDesign
import TopOptKit

// MARK: - the versions

/// One line in the Versions panel.
public struct ResultsVersionRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let recommended: Bool
    /// The tab it selects; nil = a version core could not make (greyed, never selectable).
    public let tabIndex: Int?
    /// The certified margin shown on the line and in Compare (a strengthen version's verified one, else the tab's).
    public let margin: Double?
    public let massLabel: String
    public let headline: String
    /// ★ R-b: what its one line says after the name — "87 g · 1.5×" (with "· in 2 pieces" when it prints in pieces).
    public var value: String = ""
}

public enum ResultsVersions {
    static func x(_ m: Double) -> String { String(format: m >= 10 ? "%.0f×" : "%.1f×", m) }

    /// The lines: a strengthen run's versions in core's order (an unreachable one greyed with its reason; a merged one,
    /// the same design as the version before, not repeated), else one line per tab.
    public static func rows(tabs: [ResultVariantVM], blocks: RunReportBlocks?,
                            requestedVF: (ResultVariantVM) -> Double?) -> [ResultsVersionRow] {
        var out: [ResultsVersionRow] = []
        var used = Set<Int>()
        if let b = blocks, let s = b.strengthen {
            let cards = StrengthenText.cards(b)
            for (i, v) in s.versions.enumerated() {
                let card = cards.indices.contains(i) ? cards[i] : nil
                let title = card?.title.replacingOccurrences(of: ": ", with: " · ") ?? ResultMark.letter(v.version - 1)
                if v.status == "unreachable" {
                    let why: String
                    if let cap = s.cap, i == s.versions.count - 1, cap.atAnchorFace || cap.atLoadFace {
                        why = cap.atAnchorFace ? "limited at an anchor" : "limited at the load"
                    } else {
                        why = card?.lines.first.map { $0.prefix(1).lowercased() + $0.dropFirst() } ?? "unreachable in this design space"
                    }
                    out.append(ResultsVersionRow(id: "v\(v.version)", title: title, subtitle: "Not possible — " + why,
                                                 recommended: false, tabIndex: nil, margin: nil, massLabel: "", headline: ""))
                    continue
                }
                let own = StrengthenText.lineVersion(of: v, in: s)
                guard let tab = tabs.first(where: { !$0.isLatticed && !used.contains($0.index)
                    && requestedVF($0).map { abs($0 - own.volumeFraction) < 1e-6 } == true }) else { continue }
                used.insert(tab.index)
                // a strengthen version is weighed against the part as drawn ("79% of the original"), never as savings
                let ofOriginal = v.massFractionOfOriginal > 0
                    ? String(format: "%.0f%% of the original", v.massFractionOfOriginal * 100) : tab.headlineLabel
                out.append(row(tab, title: title, margin: v.verifiedMargin > 0 ? v.verifiedMargin : tab.worstCaseMargin,
                               headline: ofOriginal,
                               pieces: StrengthenText.piecesFlag(volumeFraction: own.volumeFraction, in: b)?.pieces))
            }
        }
        var k = out.count
        for tab in tabs where !used.contains(tab.index) {
            k += 1
            let title = ResultMark.letter(k - 1) + " · " + tab.headlineLabel   // ★ B2 (U4): a result is its letter + (tab.isLatticed ? " · latticed" : "")
            out.append(row(tab, title: title, margin: tab.worstCaseMargin))
        }
        return out
    }

    /// ★ B5 (his Q1): each result's word as its line above says it, without the letter ("Just safe", "+10 %", "−30%"), from the
    /// outcome alone (the Library's tiles), one per variant. A strengthen run's versions meet their results as `rows` meets
    /// them; the rest read their headline. A strengthen run saved before its report was kept (11-04) says nothing, never a
    /// savings figure its line never meant.
    public static func words(_ o: OptimizeOutcome) -> [String?] {
        var out = [String?](repeating: nil, count: o.variants.count)
        var used = Set<Int>()
        if let s = o.reportJSON.flatMap(RunReportBlocks.decode(reportJSON:))?.strengthen {
            for v in s.versions where v.status != "unreachable" {
                let own = StrengthenText.lineVersion(of: v, in: s)
                guard let i = o.variants.indices.first(where: { !used.contains($0)
                    && abs(o.variants[$0].requestedVolumeFraction - own.volumeFraction) < 1e-6 }) else { continue }
                used.insert(i)
                out[i] = word(StrengthenText.title(v, in: s))
            }
        } else if o.growthLadder && !o.variants.contains(where: { $0.addedMaterial != nil }) {
            return out
        }
        for i in o.variants.indices where !used.contains(i) { out[i] = ResultsModel.headline(o.variants[i]) }
        return out
    }

    /// "b · +10 %" → "+10 %".
    private static func word(_ title: String) -> String {
        title.range(of: " · ").map { String(title[$0.upperBound...]) } ?? title
    }

    static func row(_ tab: ResultVariantVM, title: String, margin: Double, headline: String? = nil,
                    pieces: Int? = nil) -> ResultsVersionRow {
        let verdict = tab.latticeAccepted == false ? "not certified" : x(margin) + " ✓"
        let piecesLine = pieces.map { " · in \($0) pieces" } ?? ""
        return ResultsVersionRow(id: "t\(tab.index)", title: title,
                                 subtitle: (tab.isRecommended ? "Recommended · " : "") + tab.massLabel + " · " + verdict + piecesLine,
                                 recommended: tab.isRecommended, tabIndex: tab.index, margin: margin,
                                 massLabel: tab.massLabel, headline: headline ?? tab.headlineLabel,
                                 value: tab.massLabel + " · " + (tab.latticeAccepted == false ? "not certified" : x(margin)) + piecesLine)
    }
}

// MARK: - the checks

public struct ResultsCheck: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case ok, info, warn }
    public let kind: Kind
    public let title: String
    public let detail: String
    public var id: String { title }
    /// ★ B4 (note 14, "every row can be tapped"): the places it lights on the model (model mm), the one line its open row
    /// shows, and the Details tab its link opens.
    public var places: [SIMD3<Double>] = []
    public var more: String? = nil
    public var tab: ResultsDetailsTab? = nil
}

public enum ResultsChecks {
    /// One line + one sub-line each, in his order: strength, scenarios, layers, how to print, thin spots.
    public static func checks(tab: ResultVariantVM?, margin: Double?, required: Double, safetyMargin: Double?,
                              scenarios: [ScenarioResult], thinJoints: Int, bridged: Bool,
                              pieces: StrengthenText.PiecesFlag? = nil, finish: FinishReport? = nil,
                              weakest: SIMD3<Double>? = nil) -> [ResultsCheck] {
        guard let tab else { return [] }
        var out: [ResultsCheck] = []
        if let m = margin, m > 0 {
            let built = safetyMargin.map { " · built for \(Int(($0 * 100).rounded()))%" } ?? ""
            out.append(m >= required
                ? ResultsCheck(kind: .ok, title: "Strong enough", detail: ResultsVersions.x(m) + " your load" + built,
                               places: weakest.map { [$0] } ?? [], more: weakest == nil ? nil : "The weakest point is lit on the part",
                               tab: .strength)
                : ResultsCheck(kind: .warn, title: "Not strong enough", detail: ResultsVersions.x(m) + " your load" + built,
                               places: weakest.map { [$0] } ?? [], more: weakest == nil ? nil : "The weakest point is lit on the part",
                               tab: .strength))
        }
        if scenarios.count >= 2 {
            let unheld = scenarios.filter(\.unheld)
            if let u = unheld.first {
                out.append(ResultsCheck(kind: .warn, title: "A scenario isn’t held", detail: "\(u.name)’s load has no path to its anchors",
                                        tab: .scenarios))
            } else if let g = scenarios.first(where: \.governs) {
                out.append(ResultsCheck(kind: .ok, title: "Every scenario holds", detail: "Worst case: " + g.name,
                                        places: g.peakMM.map { [$0] } ?? [], more: g.peakMM == nil ? nil : "Its worst point is lit on the part",
                                        tab: .scenarios))
            }
        }
        switch tab.layerShear {
        case .unknown: break
        case .low: out.append(ResultsCheck(kind: .ok, title: "Layers won’t split", detail: "Layer shear " + tab.layerShear.label.lowercased(),
                                           tab: .printing))
        default: out.append(ResultsCheck(kind: .warn, title: "Layers may split", detail: "Layer shear " + tab.layerShear.label.lowercased(),
                                         tab: .printing))
        }
        out.append(ResultsCheck(kind: .info, title: tab.tiltDegrees == 0 ? "Print it upright" : "Print it tilted \(tab.tiltDegrees)°",
                                detail: tab.supportCm3 > 0 ? "About " + String(format: "%.1f", tab.supportCm3) + " cm³ of support"
                                                           : "No support needed", tab: .printing))
        // ★ B4 (note 14, ledger 15 (c)): with E1's finishing the thin-spot row says what core did — "Thin spots fixed · 6", or
        // where it could not, "2 thin spots left" and why there; a result from before E1 keeps today's row
        if let f = finish {
            out += finishChecks(f)
        } else if tab.minFeatureViolations > 0 {
            out.append(ResultsCheck(kind: .warn, title: "Some thin spots", detail: "May print thinner than drawn", tab: .printing))
        }
        if thinJoints > 0 {
            out.append(ResultsCheck(kind: .warn, title: "Thin joints", detail: "\(thinJoints) held by an edge or corner only", tab: .printing))
        }
        // ★ his ruling 2026-10-28: a version in pieces is accepted WITH A FLAG — never "joined into one part"
        if let p = pieces {
            out.append(ResultsCheck(kind: .warn, title: p.title, detail: p.lines.joined(separator: " ")))
        } else if bridged {
            out.append(ResultsCheck(kind: .info, title: "Joined by a bridge", detail: "Two pieces were joined into one part"))
        }
        return out
    }

    /// ★ B4: E1's thin spots, its safe-finish fallback and a verdict that finishing changed — each in plain words.
    public static func finishChecks(_ f: FinishReport) -> [ResultsCheck] {
        var out: [ResultsCheck] = []
        let mm = { (v: Double) in String(format: "%.1f mm", v) }
        if !f.left.isEmpty {
            let n = f.left.count
            let why = f.left.compactMap(\.reason).first { !$0.isEmpty } ?? "Core could not thicken it here"
            out.append(ResultsCheck(kind: .warn, title: "\(n) thin spot\(n == 1 ? "" : "s") left",
                                    detail: why, places: f.left.map(\.centreMM),
                                    more: "Thinnest " + mm(f.left.map(\.beforeMM).min() ?? 0) + " · at least " + mm(f.minThicknessMM) + " prints"
                                        + (f.fixed.isEmpty ? "" : " · \(f.fixed.count) fixed"),
                                    tab: .printing))
        } else if !f.fixed.isEmpty {
            out.append(ResultsCheck(kind: .ok, title: "Thin spots fixed \u{00B7} \(f.fixed.count)",
                                    detail: "Thickened to at least " + mm(f.minThicknessMM), places: f.fixed.map(\.centreMM),
                                    more: "Material was only added, never taken away", tab: .printing))
        }
        if f.fallback {
            out.append(ResultsCheck(kind: .info, title: "Finished the safe way", detail: f.fallbackReason.isEmpty
                                        ? "The slim finish would have thinned a member" : f.fallbackReason, tab: .printing))
        }
        if f.verdictChanged, !f.verdictReason.isEmpty {
            out.append(ResultsCheck(kind: .warn, title: "Finishing changed a check", detail: f.verdictReason, tab: .strength))
        }
        return out
    }
}

// MARK: - the details (behind the button: everything the engineers need)

public enum ResultsDetailsTab: String, CaseIterable, Sendable {
    case strength = "Strength", scenarios = "Scenarios", printing = "Printing", run = "Run"
}

public struct ResultsDetailRow: Equatable, Sendable, Identifiable {
    public let label: String
    public let value: String
    public var id: String { label + "·" + value }
}

extension ResultsModel {
    /// The rows of one Details tab for the selected version. Every line the old screen stacked over the model lives here.
    /// `for` another tab than the selected one (Compare's table): the lines that only the selected version carries
    /// (mesh vs grid, the latticed object's mesh) are left out.
    public func detailRows(_ t: ResultsDetailsTab, for tabIndex: Int? = nil, version: ResultsVersionRow?) -> [ResultsDetailRow] {
        var r: [ResultsDetailRow] = []
        func add(_ l: String, _ v: String?) { if let v, !v.isEmpty { r.append(ResultsDetailRow(label: l, value: v)) } }
        let tab = tabIndex.flatMap { i in tabs.first { $0.index == i } } ?? selected
        let isSelected = tab?.index == selected?.index
        let s = reportBlocks?.strengthen
        switch t {
        case .strength:
            if let m = version?.margin {
                let need = reportBlocks?.safetyMargin ?? s?.marginRequired
                add("Verified margin", ResultsVersions.x(m) + (need.map { " (needs " + ResultsVersions.x($0) + ")" } ?? ""))
            }
            add("Version", version?.title)
            if let tab { add("Plastic", tab.massLabel + " · " + (version?.headline ?? tab.headlineLabel)) }
            if isSelected { add("Mesh vs grid", selectedMassComparison.flatMap { $0.divergesBeyond1Percent || $0.meshIsEstimate ? $0.summary : nil }) }
            add("Stress scale", stressLegend.caption)
            if let tab, tab.maxStressMPa > 0 { add("Peak stress", String(format: "%.1f MPa", tab.maxStressMPa)) }
            if isSelected, let fp = failurePrediction { add("Breaks at about", fp.headline + (fp.subtitle.isEmpty ? "" : " · " + fp.subtitle)) }
            add("Added material", tab?.addedMaterialLine)
            if s == nil { add("Recommended", recommendationLine.map { $0.hasPrefix("Recommended: ") ? String($0.dropFirst(13)) : $0 }
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }) }   // a strengthen run marks it on the version's own line
            if let b = reportBlocks {
                add("Strongest possible", StrengthenText.capLine(b).map { $0 + (s.map { " (" + ResultsVersions.x($0.ceilingMargin) + " ceiling)" } ?? "") })
                for l in StrengthenText.rejectionLines(b) { add("Note", l) }
                if let tab, let p = piecesFlag(tab) { add("Pieces", ([p.title] + p.lines).joined(separator: " · ")) }
                else if let tab, isBridged(tab) { add("Split joined", "Two pieces were joined by a bridge") }
            }
            add("Built for", reportBlocks?.safetyMargin.map(SafetyMargin.builtForLine))
        case .scenarios:
            let sc = scenarios(for: tab)
            if sc.count < 2 { add("Scenarios", "One load scenario") }
            for x in sc {
                var v = x.margin.map { ResultsVersions.x($0) } ?? "—"
                if x.governs { v += " · worst case" }
                if x.unheld { v = "no path to its anchors" }
                if let p = x.peakMPa { v += String(format: " · peak %.1f MPa", p) }
                add(x.name, v)
            }
        case .printing:
            if let tab {
                add("Orientation", tab.orientationSummary)
                add("Support", tab.supportLabel)
                add("Layer shear", tab.layerShear.label)
                if tab.minFeatureViolations > 0 { add("Thin spots", tab.minFeatureWarning.isEmpty ? "\(tab.minFeatureViolations) regions" : tab.minFeatureWarning) }
            }
            add("Surface", surfaceResolutionNote)
        case .run:
            add("Ladder", ladderModeLine)
            add("Solved on", solvingMachine.label)
            add("Took", runDurationLabel)
            add("This device", remoteComputeNote)
            for n in clearanceNotes { add("Keep clear", n) }
            for n in faceProtectionNotes { add("Protect", n) }
            for n in latticeNotes { add("Lattice", n) }
            if isSelected {
                add("Latticed mass", latticeMassProvenanceLine)
                add("Latticed mesh", latticeGeometrySummary)
            }
        }
        return r
    }
}

// MARK: - the views (Stress / Solid / X-ray / Load paths)

public enum ResultsViewMode: String, CaseIterable, Sendable {
    /// ★ B4 (ledger note 13, his words: "there shouldn't be a view button for the default view. Default should happen when no
    /// views are selected"): no Solid — the plain part is what shows with no view lit.
    case stress = "Stress", xray = "X-ray", loadPaths = "Load paths"
    /// ★ his iPad 2026-10-27: the old page's MOVING views are back — the part bending under its load, and the push
    /// toward the load that breaks it.
    case bend = "Bend", breakIt = "Break"

    /// ★ his note 2026-10-27: icons, like the rest of the app (the word is the accessibility label).
    var symbol: String {
        switch self {
        case .stress: return ""            // the colour wheel, drawn
        case .xray: return "cube.transparent"
        case .loadPaths: return "point.topleft.down.to.point.bottomright.curvepath"
        case .bend: return "arrow.down.to.line"
        case .breakIt: return "bolt.fill"
        }
    }

    /// The views that MOVE: each plays on its own, pauses, and scrubs by hand.
    var moves: Bool { self == .loadPaths || self == .bend || self == .breakIt }

    /// The views this run can show, in order — one it cannot is hidden, never greyed (his note 2026-10-27).
    /// ★ B2 (round 1, design-system §4.2): the X-ray pair first, then today's views in today's order.
    static func shown(hasStress: Bool, hasDisplacement: Bool, canBreak: Bool) -> [ResultsViewMode] {
        [.xray] + (hasStress ? [.stress] : [])
            + (hasStress ? [.loadPaths] : []) + (hasDisplacement ? [.bend] : []) + (canBreak ? [.breakIt] : [])   // ★ 10-28: the light flow reads the stress
    }
}

/// ★ His iPad 2026-10-27: "Ensure that everything can pause and slide through manually." One clock per moving view, a
/// position in 0…1 the slider shows and sets.
public enum ResultsMotion {
    /// Seconds for one bend: rest → full deflection → rest.
    public static let bendSeconds: Double = 2.5
    /// Break: the load climbs from today's to the one that breaks it, then holds there a moment before the next push.
    public static let breakRampSeconds: Double = 4
    public static let breakHoldSeconds: Double = 1.2

    /// Where a playing Break stands after `t` seconds (0 = today's load, 1 = the breaking load).
    public static func breakPosition(time t: Double) -> Double {
        let cycle = breakRampSeconds + breakHoldSeconds
        let u = t.truncatingRemainder(dividingBy: cycle)
        return min(1, max(0, (u < 0 ? u + cycle : u) / breakRampSeconds))
    }

    /// The push factor for a Break position: 1× (today's load) … the failure multiple.
    public static func pushFactor(position: Double, multiplier: Double) -> Double {
        1 + min(1, max(0, position)) * (max(1, multiplier) - 1)
    }

    /// A Break position back from a push factor.
    public static func breakPosition(pushFactor: Double, multiplier: Double) -> Double {
        multiplier > 1 ? min(1, max(0, (pushFactor - 1) / (multiplier - 1))) : 0
    }
}

// MARK: - Compare

/// Compare's rules (his note 2026-10-27). Two versions: "Use this" returns to Results on it. Three or more: a layout switch —
/// ONE PAIR AT A TIME (the pick stays, the other's place takes the next version, no highlight, choose again; the last pick
/// returns) or ALL AT ONCE (one "Use this" returns).
public struct ResultsCompareSession: Equatable, Sendable {
    public enum Layout: Equatable, Sendable { case pair, all }
    public let candidates: [Int]
    public private(set) var layout: Layout = .pair
    public private(set) var shown: [Int]
    private var queue: [Int]
    /// Set when a pick ends Compare: Results opens on this tab.
    public private(set) var chosen: Int?

    public init(candidates: [Int]) {
        self.candidates = candidates
        shown = Array(candidates.prefix(2))
        queue = Array(candidates.dropFirst(2))
    }

    public var offersLayouts: Bool { candidates.count >= 3 }

    public mutating func setLayout(_ l: Layout) {
        guard offersLayouts, l != layout else { return }
        layout = l
        if l == .all { shown = candidates; queue = [] }
        else { shown = Array(candidates.prefix(2)); queue = Array(candidates.dropFirst(2)) }
    }

    public mutating func use(_ tab: Int) {
        guard shown.contains(tab) else { return }
        if layout == .all || queue.isEmpty { chosen = tab; return }
        if let i = shown.firstIndex(where: { $0 != tab }) { shown[i] = queue.removeFirst() }
    }

    /// The version in panel `slot` swapped for another (the panel's own menu).
    public mutating func show(_ tab: Int, in slot: Int) {
        guard shown.indices.contains(slot), candidates.contains(tab) else { return }
        if let other = shown.firstIndex(of: tab) { shown.swapAt(other, slot); return }
        queue.removeAll { $0 == tab }
        queue.insert(shown[slot], at: 0)
        shown[slot] = tab
    }
}

// MARK: - shared chrome (the app's floating glass)

enum ResultsChrome {
    static let fill = DS.Surface.bar
    static let radius: CGFloat = 20
    static let columnWidth: CGFloat = 330

    static func publish(_ key: String) -> some View {
        GeometryReader { g in Color.clear.preference(key: ChromeKeepOutKey.self, value: [key: g.frame(in: .global)]) }
            .allowsHitTesting(false)
    }
}

extension View {
    func resultsPanel() -> some View {
        self.background(RoundedRectangle(cornerRadius: ResultsChrome.radius).fill(ResultsChrome.fill.color)
            .overlay(RoundedRectangle(cornerRadius: ResultsChrome.radius).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            .clipShape(RoundedRectangle(cornerRadius: ResultsChrome.radius))
            .dsShadow(DS.Shadow.panel)
    }
}

/// A panel's folding header: chevron, title, a trailing word.
struct ResultsPanelHeader: View {
    let title: String
    let trailing: String
    var trailingTint: Color = DS.Color.textTertiary.color
    @Binding var open: Bool
    let id: String
    var pill = false

    var body: some View {
        Button { withAnimation(DS.Motion.sheetIn) { open.toggle() } } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DS.Color.textTertiary.color)
                Text(title).dsStyle(DS.TypeScale.bodyStrong).fontWeight(.bold).foregroundStyle(DS.Color.textPrimary.color)
                if pill { Spacer().frame(width: DS.Space.xs) } else { Spacer(minLength: DS.Space.s) }
                Text(trailing).font(.system(size: 13, weight: .semibold)).foregroundStyle(trailingTint).lineLimit(1)
            }
            .padding(.horizontal, DS.Space.l).frame(height: 50).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// Bottom-left: the version's results, one line each (a · Just safe, b · +10 %, c · +20 %); Compare at the foot.
/// ★ B4 (app-map §3.5, Q1, ledger 11): its header is the version's ("v7 results" — one Optimize is a version, its three are
/// results), and the selected line offers **Pick this**, the chosen result (the Library's ring and "v7b" tag).
struct ResultsVersionsPanel: View {
    let rows: [ResultsVersionRow]
    let selectedTab: Int
    @Binding var open: Bool
    /// Folded AND short of room (his note 2026-10-27): a small pill instead of the full-width bar.
    var pill = false
    let pick: (Int) -> Void
    /// ★ B4: the version's name ("v7"); nil off the Library.
    var version: String? = nil
    /// ★ B4: the tab he picked (nil: none yet), and Pick this — nil off the Library (there is no ring to set).
    var pickedTab: Int? = nil
    var choose: ((Int) -> Void)? = nil

    static func title(_ version: String?) -> String { version.map { "\($0) results" } ?? "Results" }
    static let pickLabel = "Pick this"
    static let pickedLabel = "Picked"

    /// ★ LOOK PER SCREEN (R-b, mockup #topo-results): §4.3's panel; each result one §4.4 line — its name, "87 g · 1.5×", and
    /// Pick this (every line not picked) or Picked; the selected line in the accent edge; one core could not make greyed with
    /// its reason. Folded and short of room, a pill (his note 2026-10-27).
    var body: some View {
        DSPanel(key: "resultsVersions", title: Self.title(version), count: rows.count, foldedPill: pill, open: $open) {
            ForEach(rows) { r in line(r) }
        }
    }

    @ViewBuilder private func line(_ r: ResultsVersionRow) -> some View {
        let on = r.tabIndex == selectedTab
        DSRow(.group, key: "resultsVersion-\(r.id)", name: r.title, value: r.tabIndex == nil ? nil : r.value,
              selected: on, disabled: r.tabIndex == nil, tag: r.recommended ? "Recommended" : nil,
              line: r.tabIndex == nil ? DSRowLine(r.subtitle) : nil,
              tap: r.tabIndex.map { t in { pick(t) } }) {
            pickChip(r, on: on)
        }
    }

    /// ★ B4 + the reviewer's chosen answer (11-04 02:44Z): Pick this on every line not picked (it sets the part's chosen
    /// result); the picked line reads Picked. Off the Library (no ring to set) neither.
    @ViewBuilder private func pickChip(_ r: ResultsVersionRow, on: Bool) -> some View {
        if let choose, let t = r.tabIndex {
            if pickedTab == t {
                DSChip(.accentTag(Self.pickedLabel), key: "resultsPicked-\(r.id)")
            } else {
                DSChip(.accentTag(Self.pickLabel), key: on ? "resultsPickThis" : "resultsPickThis-\(r.id)") { choose(t) }
            }
        }
    }
}

struct ResultsCheckLine: View {
    let c: ResultsCheck
    /// ★ B4 (note 14): open — its places lit, its one line and Details › under it; nil taps: today's still line.
    var open = false
    var tap: (() -> Void)? = nil
    var details: (() -> Void)? = nil
    var body: some View {
        if let tap {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: tap) { line.contentShape(Rectangle()) }.buttonStyle(.plain)
                if open {
                    HStack(spacing: DS.Space.s) {
                        if let more = c.more {
                            Text(more).font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: DS.Space.s)
                        if let details, c.tab != nil {
                            Button(action: details) {
                                Text("Details \u{203A}").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.accent.color)
                                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(ResultsChrome.publish("resultsCheckDetails-" + c.title))
                        }
                    }
                    .padding(.leading, DS.Space.l + 26 + DS.Space.m).padding(.trailing, DS.Space.m)
                    .background(ResultsChrome.publish("resultsCheckMore-" + c.title))
                }
            }
        } else {
            line
        }
    }

    private var line: some View {
        HStack(spacing: DS.Space.m) {
            let (sym, tint): (String, Color) = {
                switch c.kind {
                case .ok: return ("checkmark", DS.Color.okGreen.color)
                case .info: return ("arrow.up", DS.Color.accent.color)
                case .warn: return ("exclamationmark", DS.Color.warning.color)
                }
            }()
            Image(systemName: sym).font(.system(size: 11, weight: .heavy)).foregroundStyle(tint)
                .frame(width: 26, height: 26).background(Circle().fill(tint.opacity(0.18)))
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                Text(c.detail).font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.Space.sm).padding(.horizontal, DS.Space.l)
        .accessibilityElement(children: .combine)
        .background(ResultsChrome.publish("resultsCheck-" + c.title))
    }
}

/// The right column under the view buttons: the Checks panel and, under it, "Details" — which opens UPWARD over the column
/// (the checks fold away) and scrolls inside.
struct ResultsChecksAndDetails: View {
    let checks: [ResultsCheck]
    @Binding var checksOpen: Bool
    /// ★ B4 (note 14): the open check (its places light on the model).
    @Binding var openCheck: String?
    @Binding var detailsOpen: Bool
    @Binding var tab: ResultsDetailsTab
    let versionTitle: String
    let rows: (ResultsDetailsTab) -> [ResultsDetailRow]
    /// Folded AND short of room: the Checks header and Details become pills at the right.
    var pill = false

    /// ★ LOOK PER SCREEN (R-c, mockup #topo-results): §4.3's panel, 300 pt as the mockup draws it; its header says how many
    /// to look at, in the warning colour ("All good" in green).
    var body: some View {
        let warns = checks.filter { $0.kind == .warn }.count
        var panel = DSPanel(key: "resultsChecks", title: "Checks", width: Self.width, foldedPill: pill, open: $checksOpen) {
            ForEach(checks) { c in
                // ★ B4 (note 14): a tap opens it — its places light on the part — and a second tap closes it
                ResultsCheckLine(c: c, open: openCheck == c.id,
                                 tap: { withAnimation(DS.Motion.sheetIn) { openCheck = openCheck == c.id ? nil : c.id } },
                                 details: c.tab.map { t in { tab = t; withAnimation(DS.Motion.sheetIn) { detailsOpen = true } } })
                    .overlay(alignment: .bottom) { Rectangle().fill(DS.Color.strokeSubtle.color).frame(height: 1) }
                    .dsPanelRow("resultsCheckRow-" + c.id)
            }
        }
        panel.countLabel = (warns == 0 ? "All good" : "\(warns) to look at", warns == 0 ? DS.Color.okGreen : DS.Color.warning)
        return panel
            // open, under the view buttons; ★ his note 2026-10-27: folded, it drops out of the middle of the screen, down by
            // Export (R-a: just above the corner)
            .frame(maxHeight: .infinity, alignment: checksOpen ? .top : .bottom)
    }

    /// The mockup's Checks panel width.
    static let width: CGFloat = 300
}

/// ★ LOOK PER SCREEN (R-a, mockup #topo-results-details): Details as the drawer from the bottom — the page's width; "Details ·
/// v7b", its tabs and Close on one line; then its rows in columns, each its label and value. It never takes more than 40 % of
/// the page (its rows scroll).
struct ResultsDetailsDrawer: View {
    @Binding var tab: ResultsDetailsTab
    let versionTitle: String
    let rows: (ResultsDetailsTab) -> [ResultsDetailRow]
    let close: () -> Void

    var body: some View {
        GeometryReader { g in
            let cols = max(1, min(4, Int(g.size.width / 320)))
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        Text("Details \u{00B7} " + versionTitle).font(.system(size: 17, weight: .bold))
                            .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1).fixedSize()
                        SegmentedGlass(ResultsDetailsTab.allCases.map { .init($0, $0.rawValue) }, selection: $tab, small: true)
                        Spacer(minLength: 8)
                        Button(action: close) {
                            Text("Close").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                                .padding(.horizontal, 20).frame(height: 44)
                                .background(Capsule().fill(DS.Color.fillSubtle.color))
                                .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .background(ResultsChrome.publish("resultsDetailsClose"))
                        .accessibilityIdentifier("results-details-close")
                    }
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .top), count: cols),
                                  alignment: .leading, spacing: 0) {
                            ForEach(rows(tab)) { r in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(r.label).font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
                                    Spacer(minLength: 8)
                                    Text(r.value).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                                        .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.vertical, 10)
                                .overlay(alignment: .bottom) { Rectangle().fill(DS.Color.strokeSubtle.color).frame(height: 1) }
                            }
                        }
                    }
                    .frame(maxHeight: Swift.max(120, g.size.height * 0.4 - 110))
                    .fixedSize(horizontal: false, vertical: true)
                    .background(ResultsChrome.publish("resultsDetailsRows"))
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 24)
                .frame(width: g.size.width, alignment: .leading)
                // the top corners round; the bottom runs off the page
                .background(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous).fill(DS.Surface.sheet.color)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous)
                        .strokeBorder(DS.Color.strokeSheet.color, lineWidth: 1))
                    .padding(.bottom, -DS.Radius.sheet))
                .background(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous).fill(.ultraThinMaterial)
                    .padding(.bottom, -DS.Radius.sheet))
                .dsShadow(DS.Shadow.sheet)
                .background(ResultsChrome.publish("resultsDetailsPanel"))
            }
        }
    }
}

/// "Scenario" (outside) and its menu: the worst case, then each scenario with its margin.
struct ResultsScenarioPicker: View {
    let scenarios: [ScenarioResult]
    @Binding var pick: String?

    var body: some View {
        // ★ LOOK PER SCREEN (R-c, mockup #topo-results): one glass chip — "Scenario:" and the one shown, ⌄
        Menu {
            Button(worstLabel) { pick = nil }
            ForEach(scenarios, id: \.name) { s in
                Button(s.name + (s.margin.map { "  ·  " + ResultsVersions.x($0) } ?? "")) { pick = s.name }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Scenario:").font(.system(size: 12.5)).foregroundStyle(DS.Color.textSecondary.color)
                Text(pick ?? worstLabel).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Color.textTertiary.color)
            }
            .padding(.horizontal, 14).frame(height: 36)
            .background(Capsule().fill(DS.Surface.bar.color)
                .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            .frame(minHeight: DSParts.target).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("results-scenario")
        .background(ResultsChrome.publish("resultsScenario"))
    }

    private var worstLabel: String {
        "Worst case" + (scenarios.first(where: \.governs).map { " (" + $0.name + ")" } ?? "")
    }
}

/// The view buttons — ICONS, 44 pt each, like the rest of the app (his note 2026-10-27). Every view is always there; one the
/// run cannot show is greyed and says why. An optional Full screen button ends the row.
struct ResultsViewModePicker: View {
    var modes: [ResultsViewMode] = ResultsViewMode.allCases
    var available: Set<ResultsViewMode> = Set(ResultsViewMode.allCases)
    /// ★ His iPad 2026-10-28: the buttons are LAYERS + one MOTION — several can be lit at once. `isOn` says which are,
    /// `tap` toggles one (the caller holds the rules).
    let isOn: (ResultsViewMode) -> Bool
    let tap: (ResultsViewMode) -> Void
    var fullScreen: Binding<Bool>? = nil

    /// One view at a time (Compare): a plain binding.
    init(modes: [ResultsViewMode] = ResultsViewMode.allCases, available: Set<ResultsViewMode> = Set(ResultsViewMode.allCases),
         mode: Binding<ResultsViewMode>, fullScreen: Binding<Bool>? = nil) {
        self.modes = modes; self.available = available; self.fullScreen = fullScreen
        self.isOn = { $0 == mode.wrappedValue }; self.tap = { mode.wrappedValue = $0 }
    }
    init(modes: [ResultsViewMode], available: Set<ResultsViewMode> = Set(ResultsViewMode.allCases),
         isOn: @escaping (ResultsViewMode) -> Bool, tap: @escaping (ResultsViewMode) -> Void, fullScreen: Binding<Bool>? = nil) {
        self.modes = modes; self.available = available; self.isOn = isOn; self.tap = tap; self.fullScreen = fullScreen
    }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ForEach(modes, id: \.self) { m in
                let ok = available.contains(m)
                Button { tap(m) } label: { icon(m).frame(width: 44, height: 44).background(chip(on: isOn(m))) }
                    .buttonStyle(.plain)
                    .disabled(!ok)
                    .opacity(ok ? 1 : 0.35)
                    .accessibilityLabel(ok ? m.rawValue : m.rawValue + " — not in this run")
                    .accessibilityAddTraits(isOn(m) ? .isSelected : [])
                    .accessibilityIdentifier("results-view-\(m.rawValue)")
                    .background(ResultsChrome.publish("resultsView-\(m.rawValue)"))
            }
            if let fullScreen {
                let on = fullScreen.wrappedValue
                Button { withAnimation(DS.Motion.sheetIn) { fullScreen.wrappedValue.toggle() } } label: {
                    Image(systemName: on ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                        .frame(width: 44, height: 44).background(chip(on: on))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(on ? "Exit full screen" : "Full screen")
                .accessibilityIdentifier("results-fullscreen")
                .background(ResultsChrome.publish("resultsFullScreen"))
            }
        }
        .background(ResultsChrome.publish("resultsViewModes"))
    }

    @ViewBuilder private func icon(_ m: ResultsViewMode) -> some View {
        if m == .stress {
            Circle().fill(AngularGradient(colors: [RGBA(28, 60, 170).color, RGBA(0, 170, 220).color, RGBA(60, 190, 110).color,
                                                   RGBA(250, 220, 60).color, RGBA(255, 70, 50).color, RGBA(28, 60, 170).color],
                                          center: .center))
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: m.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
        }
    }

    private func chip(on: Bool) -> some View {
        Capsule().fill(on ? DS.Color.accent.opacity(0.28).color : ResultsChrome.fill.color)
            .overlay(Capsule().strokeBorder(on ? DS.Color.accent.opacity(0.7).color : DS.Color.strokeStrong.color, lineWidth: 1.5))
    }
}


/// ★ The Scenario menu and the views (his iPad 2026-10-27: "Ensure that the scenario selector changes the views"). A run whose
/// core sends each scenario's own fields (scenario_fields.bin) shows the picked scenario's views; a run without them (an
/// older core) shows the worst case's, and a pick of another scenario says so plainly.
enum ResultsScenarioViews {
    static func note(pick: String?, scenarios: [ScenarioResult], ownFields: Bool = false) -> String? {
        guard !ownFields, let p = pick, let g = scenarios.first(where: \.governs), p != g.name else { return nil }
        return "The views show \(g.name), the worst case — this run sent its fields only."
    }
}

/// ★ His iPad 2026-10-28: "The Stress/Solid/X-ray views should be add-on views … Stress and xray can combine … Otherwise,
/// solid is the usual grey." One MOTION at a time (Load paths / Bend / Break, or none) under LAYERS: the colouring (Stress
/// or Solid grey) and X-ray (see-through, with either). Bend and Break turn Stress on; Load paths turns X-ray on, and Stress
/// can be added (the light then takes the stress colours).
public struct ResultsLayers: Equatable, Sendable {
    public var motion: ResultsViewMode? = nil
    /// ★ B4 (note 13): Results opens with no view lit — the plain part.
    public var stress = false
    public var xray = false
    public init(stress: Bool = false) { self.stress = stress }

    public func isOn(_ m: ResultsViewMode) -> Bool {
        switch m {
        case .stress: return stress
        case .xray: return xray
        case .loadPaths, .bend, .breakIt: return motion == m
        }
    }
    /// A tap: a lit view goes off (back to the plain part, note 13); Stress colours; X-ray toggles; a motion starts (or stops
    /// when tapped again).
    public mutating func tap(_ m: ResultsViewMode, hasStress: Bool) {
        switch m {
        case .stress: stress = hasStress && !stress
        case .xray: xray.toggle()
        case .loadPaths, .bend, .breakIt:
            motion = motion == m ? nil : m
            // ★ his iPad 2026-10-28: Bend and Break turn Stress on; Load paths turns X-ray on (Stress can be added)
            if motion == .bend || motion == .breakIt { stress = hasStress }
            if motion == .loadPaths { xray = true }
        }
    }
}

/// ★ His iPad 2026-10-27 ("Ensure that everything can pause and slide through manually"): a moving view's Play / Pause and
/// its slider, under the view buttons. Dragging the slider pauses the view where the finger leaves it.
struct ResultsMotionBar: View {
    let title: String
    let readout: String
    /// Break has reached the load that breaks it: the readout turns red.
    let alarm: Bool
    @Binding var playing: Bool
    let position: Double
    let scrub: (Double) -> Void
    /// ★ 10-28: Bend / Break's Exaggeration slider ("to make it bend more visually"); nil hides it.
    var exaggeration: Binding<Double>? = nil

    init(title: String, readout: String, alarm: Bool, playing: Binding<Bool>, position: Double,
         scrub: @escaping (Double) -> Void, exaggeration: Binding<Double>? = nil) {
        self.title = title; self.readout = readout; self.alarm = alarm; self._playing = playing
        self.exaggeration = exaggeration; self.position = position; self.scrub = scrub
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                Button { playing.toggle() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(DS.Color.textPrimary.color)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(DS.Color.accent.opacity(0.28).color)
                            .overlay(Circle().strokeBorder(DS.Color.accent.opacity(0.7).color, lineWidth: 1.5)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playing ? "Pause \(title)" : "Play \(title)")
                .accessibilityIdentifier("results-motion-play")
                .background(ResultsChrome.publish("resultsMotionPlay"))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    Text(readout).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle((alarm ? DS.Color.danger : DS.Color.textSecondary).color)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Slider(value: Binding(get: { position }, set: { playing = false; scrub($0) }), in: 0...1)
                .tint(DS.Color.accent.color)
                .accessibilityLabel("\(title) position")
                .accessibilityIdentifier("results-motion-slider")
                .background(ResultsChrome.publish("resultsMotionSlider"))
            if let ex = exaggeration {
                HStack(spacing: DS.Space.s) {
                    Text("Exaggeration").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
                    Slider(value: ex, in: Double(FlexAnimation.minExaggeration)...Double(FlexAnimation.maxExaggeration))
                        .tint(DS.Color.accent.color)
                        .accessibilityLabel("Bend exaggeration")
                        .accessibilityIdentifier("results-exaggeration-slider")
                        .background(ResultsChrome.publish("resultsExaggeration"))
                    Text("\(Int(ex.wrappedValue))×").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(DS.Color.textPrimary.color).frame(width: 40, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .frame(width: ResultsChrome.columnWidth)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).fill(ResultsChrome.fill.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .background(ResultsChrome.publish("resultsMotionBar"))
    }
}

/// ★ THE TAP-TO-EXPLORE STRESS KEY (his note 2026-10-27: "make the legend tappable … any area you tap on the model shows the
/// associated value from the Legend — check the Lattice stage"). The Lattice stage's own chrome and reading box
/// (LatticeLegendChrome, LatticeLegendReading): a vertical scale, hot end up, an arrow on the bar at the tapped value, and the
/// value in the accent squircle beside it. Minimised it is one line; tapping that line opens it again.
struct ResultsStressExplore: View {
    /// One tapped value: which version it is (Compare names each; Results leaves it nil) and its stress.
    struct Reading: Equatable { let label: String?; let value: Double? }
    /// The top of the scale (MPa) — the SAME number the model's colours are divided by (`stressScaleMaxMPa`).
    let peakMPa: Double
    /// What the scale is keyed to ("PA12_CF · scaled to 21 MPa yield at 50% gyroid").
    let caption: String
    /// ★ 10-28: what the colours show right now while the part moves ("at 63% of your load · bend shown 60× exaggerated").
    var note: String? = nil
    /// The stress where he tapped — one per version shown (Compare), empty before a tap.
    let readings: [Reading]
    @Binding var minimized: Bool

    init(peakMPa: Double, caption: String, note: String? = nil, reading: Double?, minimized: Binding<Bool>) {
        self.init(peakMPa: peakMPa, caption: caption, note: note,
                  readings: reading.map { [Reading(label: nil, value: $0)] } ?? [], minimized: minimized)
    }
    init(peakMPa: Double, caption: String, note: String? = nil, readings: [Reading], minimized: Binding<Bool>) {
        self.peakMPa = peakMPa; self.caption = caption; self.note = note; self.readings = readings; self._minimized = minimized
    }
    private var reading: Double? { readings.count == 1 ? readings[0].value : nil }

    static let barH: CGFloat = 150
    /// ★ his note 2026-10-27: no empty space on the right — the box hugs the scale, and widens only for a reading.
    static let width: CGFloat = 196
    static let widthWithReading: CGFloat = 292

    var body: some View {
        Group {
            if minimized {
                Button { minimized = false } label: {
                    HStack(spacing: DS.Space.s) {
                        LinearGradient(colors: Self.ramp, startPoint: .leading, endPoint: .trailing)
                            .frame(width: 44, height: 6).clipShape(Capsule())
                        Text(reading.map { String(format: "%.2f MPa", $0) } ?? "Stress key")
                            .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            .foregroundStyle((reading == nil ? DS.Color.textSecondary : DS.Color.accent).color)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DS.Color.accent.color)
                    }
                    .padding(.horizontal, DS.Space.l).frame(height: 40)
                    .background(Capsule().fill(ResultsChrome.fill.color).overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open the stress key")
            } else {
                LatticeLegendChrome(width: readings.isEmpty ? Self.width : Self.widthWithReading, minimized: $minimized,
                                    info: "Tap any spot on the part to read its stress there. Double-tap anywhere to come back.") {
                    HStack(alignment: .center, spacing: DS.Space.s) {
                        VStack(alignment: .trailing, spacing: 0) {
                            ForEach(Array(ticks.enumerated()), id: \.offset) { i, t in
                                Text(t).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(DS.Color.textSecondary.color)
                                if i < ticks.count - 1 { Spacer(minLength: 0) }
                            }
                        }
                        .frame(width: 40, height: Self.barH + 14)
                        LinearGradient(colors: Self.ramp.reversed(), startPoint: .top, endPoint: .bottom)
                            .frame(width: 22, height: Self.barH)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay(alignment: .top) { arrows }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MPa").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
                            Text("von Mises").font(.system(size: 10)).foregroundStyle(DS.Color.textTertiary.color)
                        }
                        .frame(width: 58, alignment: .leading)
                        if readings.count == 1, let r = readings[0].value {
                            LatticeLegendReading(value: String(format: "%.2f", r), unit: "MPa", caption: "where you tapped")
                                .frame(width: 88)
                        } else if readings.count > 1 {
                            // ★ Compare: every version's value at the same spot
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(readings.enumerated()), id: \.offset) { _, r in
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(r.label ?? "").font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(DS.Color.textSecondary.color).lineLimit(1)
                                        Text(r.value.map { String(format: "%.2f MPa", $0) } ?? "no material")
                                            .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                                            .foregroundStyle((r.value == nil ? DS.Color.textTertiary : DS.Color.accent).color)
                                    }
                                }
                            }
                            .frame(width: 88, alignment: .leading)
                            .accessibilityIdentifier("results-stress-readings")
                        }
                    }
                    if let note {
                        Text(note).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, DS.Space.s)
                            .accessibilityIdentifier("results-stress-key-note")
                    }
                    Text(caption).font(.system(size: 11)).foregroundStyle(DS.Color.textTertiary.color)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, DS.Space.s)
                }
            }
        }
        .background(ResultsChrome.publish("resultsStressKey"))
        .accessibilityIdentifier("results-stress-key")
    }

    static var ramp: [Color] { (0...4).map { ResultsModel.stressColor(fraction: Double($0) / 4).color } }

    private var ticks: [String] {
        (0..<5).map { String(format: peakMPa >= 10 ? "%.0f" : "%.1f", peakMPa * (1 - Double($0) / 4)) }
    }

    /// An arrow at each reading's place on the bar (hot end up), like the Lattice key's.
    @ViewBuilder private var arrows: some View {
        ZStack(alignment: .top) {
            ForEach(Array(readings.enumerated()), id: \.offset) { _, rd in
                if let r = rd.value, peakMPa > 0 {
                    let t = 1 - min(1, max(0, r / peakMPa))
                    HStack(spacing: 0) {
                        Rectangle().fill(DS.Color.accent.color).frame(width: 22, height: 2)
                        Image(systemName: "arrowtriangle.left.fill").font(.system(size: 16)).foregroundStyle(DS.Color.accent.color)
                            .shadow(color: .black.opacity(0.8), radius: 1)
                    }
                    .offset(x: 11, y: CGFloat(t) * Self.barH - 8)
                }
            }
        }
    }
}

/// ★ B4: the Library numbers a version's results over ALL its variants (LibraryVersion.summary); Results' tabs count the
/// ACCEPTED ones. Pick this crosses between the two.
public enum ResultsPick {
    /// The accepted-variant index of the Library's result `r`, or nil.
    public static func accepted(_ r: Int?, in outcome: OptimizeOutcome) -> Int? {
        guard let r, outcome.variants.indices.contains(r), outcome.variants[r].accepted else { return nil }
        return outcome.variants[..<r].filter(\.accepted).count
    }
    /// The Library's result index of accepted variant `a`, or nil.
    public static func all(_ a: Int, in outcome: OptimizeOutcome) -> Int? {
        let idx = outcome.variants.indices.filter { outcome.variants[$0].accepted }
        return idx.indices.contains(a) ? idx[a] : nil
    }
}
