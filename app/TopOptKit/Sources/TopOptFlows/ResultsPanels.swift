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
                let title = card?.title.replacingOccurrences(of: ": ", with: " · ") ?? "Version \(v.version)"
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
                               headline: ofOriginal))
            }
        }
        var k = out.count
        for tab in tabs where !used.contains(tab.index) {
            k += 1
            let title = "Version \(k) · " + tab.headlineLabel + (tab.isLatticed ? " · latticed" : "")
            out.append(row(tab, title: title, margin: tab.worstCaseMargin))
        }
        return out
    }

    static func row(_ tab: ResultVariantVM, title: String, margin: Double, headline: String? = nil) -> ResultsVersionRow {
        let verdict = tab.latticeAccepted == false ? "not certified" : x(margin) + " ✓"
        return ResultsVersionRow(id: "t\(tab.index)", title: title,
                                 subtitle: (tab.isRecommended ? "Recommended · " : "") + tab.massLabel + " · " + verdict,
                                 recommended: tab.isRecommended, tabIndex: tab.index, margin: margin,
                                 massLabel: tab.massLabel, headline: headline ?? tab.headlineLabel)
    }
}

// MARK: - the checks

public struct ResultsCheck: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case ok, info, warn }
    public let kind: Kind
    public let title: String
    public let detail: String
    public var id: String { title }
}

public enum ResultsChecks {
    /// One line + one sub-line each, in his order: strength, scenarios, layers, how to print, thin spots.
    public static func checks(tab: ResultVariantVM?, margin: Double?, required: Double, safetyMargin: Double?,
                              scenarios: [ScenarioResult], thinJoints: Int, bridged: Bool) -> [ResultsCheck] {
        guard let tab else { return [] }
        var out: [ResultsCheck] = []
        if let m = margin, m > 0 {
            let built = safetyMargin.map { " · built for \(Int(($0 * 100).rounded()))%" } ?? ""
            out.append(m >= required
                ? ResultsCheck(kind: .ok, title: "Strong enough", detail: ResultsVersions.x(m) + " your load" + built)
                : ResultsCheck(kind: .warn, title: "Not strong enough", detail: ResultsVersions.x(m) + " your load" + built))
        }
        if scenarios.count >= 2 {
            let unheld = scenarios.filter(\.unheld)
            if let u = unheld.first {
                out.append(ResultsCheck(kind: .warn, title: "A scenario isn’t held", detail: "\(u.name)’s load has no path to its anchors"))
            } else if let g = scenarios.first(where: \.governs) {
                out.append(ResultsCheck(kind: .ok, title: "Every scenario holds", detail: "Worst case: " + g.name))
            }
        }
        switch tab.layerShear {
        case .unknown: break
        case .low: out.append(ResultsCheck(kind: .ok, title: "Layers won’t split", detail: "Layer shear " + tab.layerShear.label.lowercased()))
        default: out.append(ResultsCheck(kind: .warn, title: "Layers may split", detail: "Layer shear " + tab.layerShear.label.lowercased()))
        }
        out.append(ResultsCheck(kind: .info, title: tab.tiltDegrees == 0 ? "Print it upright" : "Print it tilted \(tab.tiltDegrees)°",
                                detail: tab.supportCm3 > 0 ? "About " + String(format: "%.1f", tab.supportCm3) + " cm³ of support"
                                                           : "No support needed"))
        if tab.minFeatureViolations > 0 {
            out.append(ResultsCheck(kind: .warn, title: "Some thin spots", detail: "May print thinner than drawn"))
        }
        if thinJoints > 0 {
            out.append(ResultsCheck(kind: .warn, title: "Thin joints", detail: "\(thinJoints) held by an edge or corner only"))
        }
        if bridged {
            out.append(ResultsCheck(kind: .info, title: "Joined by a bridge", detail: "Two pieces were joined into one part"))
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
                if let tab, isBridged(tab) { add("Split joined", "Two pieces were joined by a bridge") }
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
    case stress = "Stress", solid = "Solid", xray = "X-ray", loadPaths = "Load paths"
    /// ★ his iPad 2026-10-27: the old page's MOVING views are back — the part bending under its load, and the push
    /// toward the load that breaks it.
    case bend = "Bend", breakIt = "Break"

    /// ★ his note 2026-10-27: icons, like the rest of the app (the word is the accessibility label).
    var symbol: String {
        switch self {
        case .stress: return ""            // the colour wheel, drawn
        case .solid: return "cube.fill"
        case .xray: return "cube.transparent"
        case .loadPaths: return "point.topleft.down.to.point.bottomright.curvepath"
        case .bend: return "arrow.down.to.line"
        case .breakIt: return "bolt.fill"
        }
    }

    /// The views that MOVE: each plays on its own, pauses, and scrubs by hand.
    var moves: Bool { self == .loadPaths || self == .bend || self == .breakIt }

    /// The views this run can show, in order — one it cannot is hidden, never greyed (his note 2026-10-27).
    static func shown(hasStress: Bool, hasDisplacement: Bool, canBreak: Bool) -> [ResultsViewMode] {
        (hasStress ? [.stress] : []) + [.solid, .xray]
            + (hasDisplacement ? [.loadPaths, .bend] : []) + (canBreak ? [.breakIt] : [])
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

/// Bottom-left: the versions, one line each; Compare at the foot.
struct ResultsVersionsPanel: View {
    let rows: [ResultsVersionRow]
    let selectedTab: Int
    @Binding var open: Bool
    /// Folded AND short of room (his note 2026-10-27): a small pill instead of the full-width bar.
    var pill = false
    let pick: (Int) -> Void
    let compare: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ResultsPanelHeader(title: "Versions",
                               trailing: open ? "\(rows.count)" : (rows.first { $0.tabIndex == selectedTab }?.title ?? ""),
                               trailingTint: open ? DS.Color.textTertiary.color : DS.Color.accent.color,
                               open: $open, id: "results-versions-header", pill: pill && !open)
            if open {
                ForEach(rows) { r in
                    Divider().overlay(DS.Color.strokeSubtle.color)
                    line(r)
                }
                if let compare {
                    Divider().overlay(DS.Color.strokeSubtle.color)
                    Button(action: compare) {
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "rectangle.split.2x1").font(.system(size: 13, weight: .semibold))
                            Text("Compare").dsStyle(DS.TypeScale.bodyStrong)
                        }
                        .foregroundStyle(DS.Color.textPrimary.color).frame(maxWidth: .infinity).frame(height: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(ResultsChrome.publish("resultsCompare"))
                    .accessibilityIdentifier("results-compare")
                }
            }
        }
        .frame(width: pill && !open ? nil : 340)
        .fixedSize(horizontal: pill && !open, vertical: false)
        .resultsPanel()
        .background(ResultsChrome.publish("resultsVersions"))
    }

    @ViewBuilder private func line(_ r: ResultsVersionRow) -> some View {
        let on = r.tabIndex == selectedTab
        Button { if let t = r.tabIndex { pick(t) } } label: {
            HStack(spacing: DS.Space.m) {
                RoundedRectangle(cornerRadius: 2).fill(on ? DS.Color.accent.color : Color.clear).frame(width: 4, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).font(.system(size: 15, weight: on ? .bold : .semibold))
                        .foregroundStyle((r.tabIndex == nil ? DS.Color.textTertiary : DS.Color.textPrimary).color).lineLimit(1)
                    Text(r.subtitle).font(.system(size: 13))
                        .foregroundStyle((r.tabIndex == nil ? DS.Color.textTertiary : on ? DS.Color.accent : DS.Color.textSecondary).color)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, DS.Space.sm).padding(.horizontal, DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? DS.Color.accent.opacity(0.14).color : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(r.tabIndex == nil)
        .background(ResultsChrome.publish("resultsVersion-\(r.id)"))
        .accessibilityIdentifier("results-version-\(r.id)")
    }
}

struct ResultsCheckLine: View {
    let c: ResultsCheck
    var body: some View {
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
    }
}

/// The right column under the view buttons: the Checks panel and, under it, "Details" — which opens UPWARD over the column
/// (the checks fold away) and scrolls inside.
struct ResultsChecksAndDetails: View {
    let checks: [ResultsCheck]
    @Binding var checksOpen: Bool
    @Binding var detailsOpen: Bool
    @Binding var tab: ResultsDetailsTab
    let versionTitle: String
    let rows: (ResultsDetailsTab) -> [ResultsDetailRow]
    /// Folded AND short of room: the Checks header and Details become pills at the right.
    var pill = false

    var body: some View {
        VStack(spacing: DS.Space.s) {
            if detailsOpen {
                details.transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    let warns = checks.filter { $0.kind == .warn }.count
                    ResultsPanelHeader(title: "Checks", trailing: warns == 0 ? "All good" : "\(warns) to look at",
                                       trailingTint: (warns == 0 ? DS.Color.okGreen : DS.Color.warning).color,
                                       open: $checksOpen, id: "results-checks-header", pill: pill && !checksOpen)
                    if checksOpen {
                        ForEach(checks) { c in
                            Divider().overlay(DS.Color.strokeSubtle.color)
                            ResultsCheckLine(c: c)
                        }
                    }
                }
                .fixedSize(horizontal: pill && !checksOpen, vertical: false)
                .resultsPanel()
                .background(ResultsChrome.publish("resultsChecks"))
                detailsButton.fixedSize(horizontal: pill && !checksOpen, vertical: false)
            }
        }
        .frame(width: pill && !checksOpen && !detailsOpen ? nil : ResultsChrome.columnWidth, alignment: .trailing)
        // ★ his note 2026-10-27: folded, the checks drop out of the middle of the screen, down by Export
        .frame(maxHeight: .infinity, alignment: checksOpen || detailsOpen ? .top : .bottom)
    }

    private var detailsButton: some View {
        Button { withAnimation(DS.Motion.sheetIn) { detailsOpen.toggle() } } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: detailsOpen ? "chevron.down" : "chevron.up").font(.system(size: 12, weight: .bold))
                Text("Details").dsStyle(DS.TypeScale.bodyStrong)
            }
            .foregroundStyle(DS.Color.textPrimary.color).padding(.horizontal, DS.Space.l)
            .frame(maxWidth: .infinity).frame(height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(detailsOpen ? nil : Capsule().fill(ResultsChrome.fill.color)
            .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .background(ResultsChrome.publish("resultsDetailsButton"))
        .accessibilityIdentifier("results-details")
    }

    private var details: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Details · " + versionTitle).dsStyle(DS.TypeScale.bodyStrong).fontWeight(.bold)
                    .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, DS.Space.l).frame(height: 50)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.xs) {
                    ForEach(ResultsDetailsTab.allCases, id: \.self) { t in
                        Button { tab = t } label: {
                            Text(t.rawValue).font(.system(size: 14, weight: t == tab ? .semibold : .regular))
                                .foregroundStyle((t == tab ? DS.Color.textPrimary : DS.Color.textSecondary).color)
                                .padding(.horizontal, DS.Space.m).frame(height: 36)
                                .background(Capsule().fill(t == tab ? DS.Color.fillSubtle.color : Color.clear))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("results-details-tab-\(t.rawValue)")
                    }
                }
                .padding(.horizontal, DS.Space.l)
            }
            Divider().overlay(DS.Color.strokeSubtle.color).padding(.top, DS.Space.xs)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows(tab)) { r in
                        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                            Text(r.label).font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
                                .frame(width: 112, alignment: .leading)
                            Text(r.value).font(.system(size: 13.5)).foregroundStyle(DS.Color.textPrimary.color)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 10)
                        Divider().overlay(DS.Color.strokeSubtle.color)
                    }
                }
                .padding(.horizontal, DS.Space.l)
            }
            .background(ResultsChrome.publish("resultsDetailsRows"))
            Divider().overlay(DS.Color.strokeSubtle.color)
            detailsButton
        }
        .frame(maxHeight: .infinity)
        .resultsPanel()
        .background(ResultsChrome.publish("resultsDetailsPanel"))
    }
}

/// "Scenario" (outside) and its menu: the worst case, then each scenario with its margin.
struct ResultsScenarioPicker: View {
    let scenarios: [ScenarioResult]
    @Binding var pick: String?

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Text("Scenario").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
            Menu {
                Button(worstLabel) { pick = nil }
                ForEach(scenarios, id: \.name) { s in
                    Button(s.name + (s.margin.map { "  ·  " + ResultsVersions.x($0) } ?? "")) { pick = s.name }
                }
            } label: {
                HStack(spacing: DS.Space.s) {
                    Text(pick ?? worstLabel).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(DS.Color.textPrimary.color)
                .padding(.horizontal, DS.Space.l).frame(height: 44)
                .background(Capsule().fill(ResultsChrome.fill.color)
                    .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("results-scenario")
        }
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
    @Binding var mode: ResultsViewMode
    var fullScreen: Binding<Bool>? = nil

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ForEach(modes, id: \.self) { m in
                let ok = available.contains(m)
                Button { mode = m } label: { icon(m).frame(width: 44, height: 44).background(chip(on: m == mode)) }
                    .buttonStyle(.plain)
                    .disabled(!ok)
                    .opacity(ok ? 1 : 0.35)
                    .accessibilityLabel(ok ? m.rawValue : m.rawValue + " — not in this run")
                    .accessibilityAddTraits(m == mode ? .isSelected : [])
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


/// ★ The Scenario menu and the views (his iPad 2026-10-27: "Ensure that the scenario selector changes the views"). Core
/// certifies every scenario on each version but sends the stress and displacement fields of the WORST one only — so until it
/// sends each scenario's own, a pick of another scenario says plainly which scenario the views are showing.
enum ResultsScenarioViews {
    static func note(pick: String?, scenarios: [ScenarioResult]) -> String? {
        guard let p = pick, let g = scenarios.first(where: \.governs), p != g.name else { return nil }
        return "The views show \(g.name), the worst case — this run sent its fields only."
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
    /// The top of the scale (MPa) — the SAME number the model's colours are divided by (`stressScaleMaxMPa`).
    let peakMPa: Double
    /// What the scale is keyed to ("PA12_CF · scaled to 21 MPa yield at 50% gyroid").
    let caption: String
    /// The stress where he tapped, or nil before a tap.
    let reading: Double?
    @Binding var minimized: Bool

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
                LatticeLegendChrome(width: reading == nil ? Self.width : Self.widthWithReading, minimized: $minimized,
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
                            .overlay(alignment: .top) { arrow }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MPa").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
                            Text("von Mises").font(.system(size: 10)).foregroundStyle(DS.Color.textTertiary.color)
                        }
                        .frame(width: 58, alignment: .leading)
                        if let r = reading {
                            LatticeLegendReading(value: String(format: "%.2f", r), unit: "MPa", caption: "where you tapped")
                                .frame(width: 88)
                        }
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

    /// The arrow at the reading's place on the bar (hot end up), like the Lattice key's.
    @ViewBuilder private var arrow: some View {
        if let r = reading, peakMPa > 0 {
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
