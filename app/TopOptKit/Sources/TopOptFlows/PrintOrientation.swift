// PrintOrientation — B4 (approved design 2026-11-02, ledger note 12, Q9, plan.md §B4, design-system §4.8 / §4.13, mockup
// #topo-results-orient and #topo-results-print).
//
// His words: "The results page should note that the way it is placed is the way they recommend printing. But also; there
// should be a way to go back to the way it was set before." Results' bottom-centre line: "Shown as we'd print it" (i) ·
// **Show as you placed it** (view only). While his placement shows, **Print it this way** grows the line into an inline
// confirm — "Print it the way you placed it?", one line per change (support, layers, strength — core's E1 (f) re-check), then
// **Keep ours · Print it this way**. Picked, the line reads "Printing as you placed it".
//
// The line, its states and its words. Which re-check feeds "ours" and "yours" is the reviewer's to rule (asked 11-04 01:25Z:
// the app's runs certify the part as he placed it, bake off); until then nothing passes a source and Results draws no line.

import SwiftUI
import TopOptDesign

/// Core's E1 (f) re-check of a version's file printed along `buildDir` (analysis.json "orientation_recheck", core
/// 35764048bba3): one analysis solve with the layer knockdown along the new Z, the overhang that would need support, and
/// the same file's overhang along the job's own direction (`baseline…`).
public struct OrientationRecheck: Equatable, Sendable {
    public let buildDir: SIMD3<Double>
    public let margin: Double
    public let interlayerMargin: Double
    public let marginRequired: Double
    public let accepted: Bool
    public let overhangAreaMM2: Double
    public let supportVolumeMM3: Double
    /// Core's own sentence ("Printed this way the layers would split: 1.12× (needs 1.50×)").
    public let reason: String
    public let baselineBuildDir: SIMD3<Double>
    public let baselineOverhangAreaMM2: Double

    /// The block from analysis.json; nil when the analysis carries none (any other analyze job) or a key is missing.
    public static func decode(analysis: [String: Any]) -> OrientationRecheck? {
        guard let o = analysis["orientation_recheck"] as? [String: Any],
              let dir = vec(o["build_dir"]),
              let margin = o["margin"] as? Double, let inter = o["interlayer_margin"] as? Double,
              let required = o["margin_required"] as? Double, let accepted = o["accepted"] as? Bool,
              let area = o["overhang_area_mm2"] as? Double, let volume = o["support_volume_mm3"] as? Double,
              let base = o["baseline"] as? [String: Any], let baseDir = vec(base["build_dir"]),
              let baseArea = base["overhang_area_mm2"] as? Double else { return nil }
        return OrientationRecheck(buildDir: dir, margin: margin, interlayerMargin: inter, marginRequired: required,
                                  accepted: accepted, overhangAreaMM2: area, supportVolumeMM3: volume,
                                  reason: o["reason"] as? String ?? "", baselineBuildDir: baseDir,
                                  baselineOverhangAreaMM2: baseArea)
    }

    private static func vec(_ v: Any?) -> SIMD3<Double>? {
        guard let a = v as? [Double], a.count == 3 else { return nil }
        return SIMD3(a[0], a[1], a[2])
    }
}

/// One way of printing a version, as the confirm compares two of them.
public struct PrintFacts: Equatable, Sendable {
    public var margin: Double
    public var interlayerMargin: Double
    public var marginRequired: Double
    public var overhangAreaMM2: Double
    public init(margin: Double, interlayerMargin: Double, marginRequired: Double, overhangAreaMM2: Double) {
        self.margin = margin; self.interlayerMargin = interlayerMargin; self.marginRequired = marginRequired
        self.overhangAreaMM2 = overhangAreaMM2
    }
}

/// One line of the confirm: ≤ 12 words, coloured by what it asks of him.
public struct PrintChange: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case info, warning, danger }
    public let text: String
    public let tone: Tone
}

/// What changes printed his way: support, layers, strength — always three lines, one each.
public enum PrintChanges {
    public static func lines(ours: PrintFacts, yours: PrintFacts) -> [PrintChange] {
        let x = { (v: Double) in String(format: "%.2f\u{00D7}", v) }
        let cm2 = (yours.overhangAreaMM2 - ours.overhangAreaMM2) / 100
        let n = Int(abs(cm2).rounded())
        let support = n == 0 ? PrintChange(text: "About the same support", tone: .info)
            : cm2 > 0 ? PrintChange(text: "About \(n) cm\u{00B2} more to support", tone: .warning)
            : PrintChange(text: "About \(n) cm\u{00B2} less to support", tone: .info)
        let layers = yours.interlayerMargin < yours.marginRequired
            ? PrintChange(text: "Layers may split", tone: .warning)
            : PrintChange(text: "Layers won\u{2019}t split", tone: .info)
        let strength = yours.margin < yours.marginRequired
            ? PrintChange(text: "Not strong enough: \(x(yours.margin)) (needs \(x(yours.marginRequired)))", tone: .danger)
            : x(yours.margin) < x(ours.margin) ? PrintChange(text: "Strong enough drops to \(x(yours.margin))", tone: .info)
            : PrintChange(text: "Strong enough: \(x(yours.margin))", tone: .info)
        return [support, layers, strength]
    }
}

/// The line's four states (mockup: ours · shown as placed · the confirm · printing yours).
public enum PrintOrientationPhase: Equatable, Sendable {
    case ours, placed, confirm, yours

    /// What a tap leads to. `yours` is the only state that changes how it prints.
    public func after(_ t: PrintOrientationTap) -> PrintOrientationPhase {
        switch (self, t) {
        case (.ours, .showPlaced): return .placed
        case (.placed, .showOurs), (.yours, .showOurs): return .ours
        case (.placed, .printThisWay): return .confirm
        case (.confirm, .keepOurs): return .placed
        case (.confirm, .confirmPrint): return .yours
        default: return self
        }
    }
}

public enum PrintOrientationTap: String, Equatable, Sendable {
    case showPlaced, showOurs, printThisWay, keepOurs, confirmPrint
}

enum PrintOrientationCopy {
    static let why = "We turned it so it needs the least support and its layers carry the load."
    static let ask = "Print it the way you placed it?"
    static let checking = "Checking it printed your way\u{2026}"

    static func says(_ p: PrintOrientationPhase) -> String {
        switch p {
        case .ours, .confirm: return "Shown as we\u{2019}d print it"
        case .placed: return "Shown as you placed it"
        case .yours: return "Printing as you placed it"
        }
    }

    static func title(_ t: PrintOrientationTap) -> String {
        switch t {
        case .showPlaced: return "Show as you placed it"
        case .showOurs: return "Show as we\u{2019}d print it"
        case .printThisWay, .confirmPrint: return "Print it this way"
        case .keepOurs: return "Keep ours"
        }
    }

    /// The line's chips in each state.
    static func chips(_ p: PrintOrientationPhase) -> [PrintOrientationTap] {
        switch p {
        case .ours: return [.showPlaced]
        case .placed: return [.showOurs, .printThisWay]
        case .yours: return [.showOurs]
        case .confirm: return []
        }
    }
}

enum PrintOrientationLayout {
    /// The line's bottom edge above the screen's (mockup: bottom 104, clear of the timeline).
    static let bottom: CGFloat = 104
    /// The confirm's width (mockup 440).
    static let confirmWidth: CGFloat = 440
    /// The confirm's corners: the panel radius of the mockup's grown pill.
    static let confirmRadius: CGFloat = 22

    /// The line's own frames, and the markers on the part: not controls it keeps clear of.
    static func ignored(_ key: String) -> Bool {
        key.hasPrefix("resultsOrient") || key == "info-resultsOrient" || key.hasPrefix("resultsCheckMarker")
    }

    /// Where the line's bottom edge goes: `bottom` off the screen's, centred — or, with a control in its way (13″ portrait:
    /// the versions panel), stepped up past it, the toast's rule (§4.34: never over a control).
    static func bottomY(size: CGSize, viewport: CGSize, controls: [CGRect]) -> CGFloat {
        var y = viewport.height - bottom
        for _ in 0..<12 {
            let r = CGRect(x: (viewport.width - size.width) / 2, y: y - size.height, width: size.width, height: size.height)
                .insetBy(dx: -NotificationLane.stepGap, dy: 0)
            let hit = controls.filter { $0.intersects(r) }
            guard let top = hit.map(\.minY).min() else { return y }
            y = top - NotificationLane.stepGap
            if y - size.height < 0 { break }
        }
        return viewport.height - bottom
    }
}

/// What the line reads for the selected version (the workspace fills it once the source is ruled).
public struct ResultsPrintOrientation {
    /// Whether he picked his own placement for this version (accepted-variant index).
    public var printsYours: (Int) -> Bool
    /// What changes printed his way; nil while core re-checks it.
    public var changes: (Int) -> [PrintChange]?
    /// Asked once the confirm opens: core re-checks the version printed his way.
    public var recheck: (Int) -> Void
    /// His pick: true = print it as he placed it.
    public var choose: (Int, Bool) -> Void
    public init(printsYours: @escaping (Int) -> Bool, changes: @escaping (Int) -> [PrintChange]?,
                recheck: @escaping (Int) -> Void, choose: @escaping (Int, Bool) -> Void) {
        self.printsYours = printsYours; self.changes = changes; self.recheck = recheck; self.choose = choose
    }
}

/// The bottom-centre line, and the confirm it grows into. Frames: "resultsOrient" (the pill, whichever state),
/// "resultsOrientSays", "resultsOrient-<tap>", "resultsOrientChange-<i>", "resultsOrientChecking".
struct PrintOrientationLine: View {
    let phase: PrintOrientationPhase
    let changes: [PrintChange]?
    let tap: (PrintOrientationTap) -> Void

    var body: some View {
        Group {
            if phase == .confirm { confirm } else { line }
        }
        .background(ResultsChrome.publish("resultsOrient"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("results-orient")
    }

    private var line: some View {
        HStack(spacing: DS.Space.s) {
            Text(PrintOrientationCopy.says(phase)).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1).fixedSize()
                .background(ResultsChrome.publish("resultsOrientSays"))
            if phase == .ours { InfoTip(key: "resultsOrient", text: PrintOrientationCopy.why, label: "Why we turned it") }
            ForEach(PrintOrientationCopy.chips(phase), id: \.self) { chip($0) }
        }
        .padding(.leading, DS.Space.l).padding(.trailing, DS.Space.xs)
        .frame(minHeight: 48)
        .background(Capsule().fill(ResultsChrome.fill.color)
            .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
    }

    private func chip(_ t: PrintOrientationTap) -> some View {
        Button { tap(t) } label: {
            Text(PrintOrientationCopy.title(t)).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DS.Color.accent.color).lineLimit(1).fixedSize()
                .padding(.horizontal, DS.Space.m).frame(height: 30)
                .background(Capsule().fill(DS.Color.chipSolid.color)
                    .overlay(Capsule().strokeBorder(DS.Color.accent.color.opacity(0.55), lineWidth: 1)))
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(ResultsChrome.publish("resultsOrient-" + t.rawValue))
        .accessibilityIdentifier("results-orient-" + t.rawValue)
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(PrintOrientationCopy.ask).font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(DS.Color.textPrimary.color)
            if let c = changes {
                ForEach(Array(c.enumerated()), id: \.offset) { i, ch in
                    Text(ch.text).font(.system(size: 12.5)).foregroundStyle(Self.colour(ch.tone).color)
                        .lineLimit(1)
                        .background(ResultsChrome.publish("resultsOrientChange-\(i)"))
                }
            } else {
                Text(PrintOrientationCopy.checking).font(.system(size: 12.5))
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .background(ResultsChrome.publish("resultsOrientChecking"))
            }
            HStack(spacing: DS.Space.s) {
                Spacer(minLength: 0)
                button(.keepOurs, primary: false, enabled: true)
                button(.confirmPrint, primary: true, enabled: changes != nil)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: PrintOrientationLayout.confirmWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: PrintOrientationLayout.confirmRadius, style: .continuous)
            .fill(ResultsChrome.fill.color)
            .overlay(RoundedRectangle(cornerRadius: PrintOrientationLayout.confirmRadius, style: .continuous)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
    }

    /// The confirm's two buttons: 36 pt capsules in 44 pt targets; "Print it this way" waits for core's answer.
    private func button(_ t: PrintOrientationTap, primary: Bool, enabled: Bool) -> some View {
        Button { tap(t) } label: {
            Text(PrintOrientationCopy.title(t)).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primary && enabled ? Color.white
                                 : (primary ? DS.Color.textTertiary : DS.Color.textPrimary).color)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, DS.Space.l).frame(height: 36)
                .background(Capsule().fill((primary ? (enabled ? DS.Color.accent : DS.Color.fillSubtle)
                                                    : DS.Color.fillSubtle).color))
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .background(ResultsChrome.publish("resultsOrient-" + t.rawValue))
        .accessibilityIdentifier("results-orient-" + t.rawValue)
    }

    static func colour(_ t: PrintChange.Tone) -> RGBA {
        switch t {
        case .info: return DS.Color.textSecondary
        case .warning: return DS.Color.warning
        case .danger: return DS.Color.danger
        }
    }
}
