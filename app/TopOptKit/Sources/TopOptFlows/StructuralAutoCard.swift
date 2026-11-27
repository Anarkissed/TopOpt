// StructuralAutoCard — ★ notes30 STRUCTURAL AUTO, what he sees while it works and after.
//
// His words (11-26, via 362): "Two checks is fine. But in this case - no animation. We just need a pop-up with a progress bar
// and details saying exactly what's happening in each step, with an (i) if it requires more than 5 words." Then: "Actually -
// once it's done, give the short animation."
//
// So, from his Lattice press to the print file: ONE centred card (the chain's one pop-up, LatticeMacMakeModal draws it in place
// of its animation card): its title, a progress bar that moves ONLY when a step really ends (no fake progress: the share of
// steps done), and a line per step — at most five words, each with the app's one (i) holding the longer sentence — the done
// ones ticked, the one under way marked. No timelapse, no hexagons, no sweeping light. "Run in the Background" and "Cancel" as
// on every print-file card. When it lands the card goes and the finished lattice plays the short build (the timelapse he liked,
// LatticeBuildTimelapse, through the preview's own entry point), with Live preview and Skip all animations keeping their rules.
//
// Also here: the Lattice page's row (Structural, Auto: "Strengthened to 150 %" with an (i), its tap the Safety margin's own menu)
// and Results' "Strengthened by Auto" row with its (i). (His rework, 11-27: the steps are the checks and the thickening of the struts the first check shows are short.)
import SwiftUI
import TopOptDesign

/// The words (five at most on screen; the rest in the (i)).
public enum StructuralAutoCopy {
    public static func percent(_ margin: Double) -> String { "\(Int((margin * 100).rounded())) %" }
    /// The card's title.
    public static let title = "Making the print file"
    public static func checking(_ n: Int, of total: Int) -> String { "Checking strength (\(n) of \(total))" }
    public static let thickening = "Thickening short struts"
    public static let saving = "Saving the print file"
    public static func checkingInfo(_ n: Int, of total: Int, margin: Double) -> String {
        n == 1
            ? "Your Mac makes the print file and runs the full strength check on it, the same check every print file gets. "
                + "If every strut holds \(times(margin)) your load, that file is the one."
            : "Your Mac checks the thickened lattice with the same full strength check. The lighter version that holds "
                + "your target is the one kept."
    }
    public static func thickeningInfo(_ margin: Double) -> String {
        "The first check shows which struts fall short of \(times(margin)) your load. Only those get thicker, each just as far "
            + "as the strength measured for this lattice type says it needs; every other strut stays exactly as it was."
    }
    public static func savingInfo(_ margin: Double) -> String {
        "The lighter version that holds \(times(margin)) your load becomes this version's print file."
    }
    /// The first check passed: said on the steps it made unneeded.
    public static let firstPassed = "First check passed"
    public static func firstPassedInfo(_ margin: Double) -> String {
        "The lattice already holds \(times(margin)) your load everywhere, so no strut needs thickening. Your print file is "
            + "made from it."
    }
    static func times(_ m: Double) -> String {
        let r = (m * 100).rounded() / 100
        return (r == r.rounded() ? String(format: "%.0f", r) : r * 10 == (r * 10).rounded() ? String(format: "%.1f", r)
                                                                                            : String(format: "%.2f", r)) + "\u{00D7}"
    }

    // The Lattice page's row
    public static func strengthenedTo(_ margin: Double) -> String { "Strengthened to \(percent(margin))" }
    public static func strengthenedToInfo(_ margin: Double) -> String {
        "Auto lays the lattice and your Mac checks its strength. If any strut falls short of \(times(margin)) your load, only "
            + "those struts get thicker and your Mac checks again. Tap to change the Safety margin."
    }
    public static let customMenu = "Custom"

    // Results' row
    public static let strengthenedByAuto = "Strengthened by Auto"
    public static func strengthenedValue(_ r: StructuralAuto.Record) -> String {
        if r.rounds.count == 1 { return firstPassed }
        let a = Int((r.addedShare * 100).rounded())
        return a > 0 ? "\(a) % more plastic" : "\(r.rounds.count) checks"
    }
    public static func strengthenedInfo(_ r: StructuralAuto.Record) -> String {
        if r.rounds.count == 1 { return firstPassedInfo(r.margin) }
        var t = "Your Mac's first check found struts short of \(percent(r.margin)) of your load. Auto thickened "
            + "\(r.thickenedCells) \(r.thickenedCells == 1 ? "cell" : "cells") there, each just as far as it needed, and your "
            + "Mac checked again. "
        if r.keptRound > 0 {
            t += "The thickened lattice was kept: it uses \(Int((r.addedShare * 100).rounded())) % more plastic than the first. "
        } else {
            t += "The first lattice was kept: it was the lighter one that holds, or the stronger one. "
        }
        if r.cappedCells > 0 {
            t += "\(r.cappedCells) \(r.cappedCells == 1 ? "cell needed" : "cells needed") more than the densest open lattice; "
                + "they are as thick as that allows."
        }
        return t
    }

    // The pop-up when a spot stays short: one per cause, naming the fix that reaches the target.
    public static func shortTitle(_ cause: StructuralAuto.Short, margin: Double) -> String {
        switch cause {
        case .stiffWalls: return "Thicker walls reach \(percent(margin))"
        case .denseLattice: return "Solid here reaches \(percent(margin))"
        case .solid: return "More infill reaches \(percent(margin))"
        }
    }
    public static func shortText(_ cause: StructuralAuto.Short, margin: Double) -> String {
        switch cause {
        case .stiffWalls:
            return "Here the walls carry most of the load, so thicker struts beside them add plastic and little strength. "
                + "Thicker walls, or more infill in them, reach \(percent(margin)). Results shows where."
        case .denseLattice:
            return "A few places need more than even the densest open lattice holds. A Protect skin or a solid area there "
                + "reaches \(percent(margin)). Results shows where."
        case .solid:
            return "The lattice holds; the solid parts need more. More infill, or thicker walls, reach \(percent(margin)). "
                + "Results shows the fix."
        }
    }
}

/// The card's steps: their words and (i), which are done, the one under way. The bar is the share of steps done — it moves
/// only when a step really ends.
public struct StructuralAutoSteps: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case check(Int), thicken, passed, saving }
        public var kind: Kind
        public var words: String
        public var info: String
        public var done = false
    }
    public var items: [Item]
    public var current: Int
    public let margin: Double

    /// The steps of one press (his rework, 11-27): the checks with a thickening of the short struts between each, then the file.
    public init(margin: Double, checks: Int = StructuralAuto.checksPerPress) {
        self.margin = margin
        var it: [Item] = []
        for n in 1...Swift.max(1, checks) {
            if n > 1 { it.append(Item(kind: .thicken, words: StructuralAutoCopy.thickening, info: StructuralAutoCopy.thickeningInfo(margin))) }
            it.append(Item(kind: .check(n), words: StructuralAutoCopy.checking(n, of: checks),
                           info: StructuralAutoCopy.checkingInfo(n, of: checks, margin: margin)))
        }
        it.append(Item(kind: .saving, words: StructuralAutoCopy.saving, info: StructuralAutoCopy.savingInfo(margin)))
        items = it
        current = 0
    }

    /// The share of steps done (0 → 1).
    public var fraction: Double { items.isEmpty ? 0 : Double(items.filter(\.done).count) / Double(items.count) }

    /// What the runner says.
    public enum Event: Equatable, Sendable {
        case began(Item.Kind)
        /// The chain stops before its last check: the steps not taken go. `passed`: check 1 passed (nothing to thicken), said
        /// in one ticked line.
        case shortcut(passed: Bool)
        case finished
    }
    public mutating func apply(_ e: Event) {
        switch e {
        case .began(let k):
            guard let i = items.firstIndex(where: { $0.kind == k }) else { return }
            for j in 0..<i { items[j].done = true }
            current = i
        case .shortcut(let passed):
            // the steps not taken go (those after the check under way, up to the file); the shortcut says why in one line
            let at = items.indices.contains(current) ? current : 0
            var it = items.enumerated().filter { i, item in i <= at || item.kind == .saving }.map(\.element)
            if passed, let s = it.firstIndex(where: { $0.kind == .saving }) {
                it.insert(Item(kind: .passed, words: StructuralAutoCopy.firstPassed, info: StructuralAutoCopy.firstPassedInfo(margin),
                               done: true), at: s)
            }
            for j in it.indices where it[j].kind != .saving { it[j].done = true }
            items = it
            current = it.firstIndex(where: { $0.kind == .saving }) ?? it.count - 1
        case .finished:
            for j in items.indices { items[j].done = true }
            current = items.count
        }
    }
}

/// The card itself (centred by LatticeMacMakeModal, over everything): no animation of any kind.
struct StructuralAutoCard: View {
    let steps: StructuralAutoSteps
    let background: () -> Void
    let cancel: () -> Void
    static let width: CGFloat = 420
    /// RED CONTROL (tests): the print file's animated card instead (as before notes30).
    nonisolated(unsafe) static var controlAnimated = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(StructuralAutoCopy.title).dsStyle(DS.TypeScale.title).foregroundStyle(DS.Color.textPrimary.color)
                .saidWhole(StructuralAutoCopy.title)
                .accessibilityIdentifier("structural-auto-title")
            // the bar: the share of steps done, moved only by a step's real end
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Color.textTertiary.color.opacity(0.35))
                Capsule().fill(DS.Color.accent.color)
                    .frame(width: Swift.max(6, (Self.width - 2 * DS.Space.xl) * steps.fraction))
            }
            .frame(height: 6)
            .accessibilityElement()
            .accessibilityLabel("Making the print file")
            .accessibilityValue("\(Int((steps.fraction * 100).rounded())) percent")
            .background(CornerPairStyle.publish("structuralAutoBar"))
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(steps.items.enumerated()), id: \.offset) { i, item in
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: item.done ? "checkmark.circle.fill" : i == steps.current ? "circle.dotted" : "circle")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle((item.done ? DS.Color.accent : i == steps.current ? DS.Color.textPrimary
                                              : DS.Color.textTertiary).color)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text(item.words).dsStyle(DS.TypeScale.body)
                            .foregroundStyle((i == steps.current || item.done ? DS.Color.textPrimary : DS.Color.textSecondary).color)
                            .fontWeight(i == steps.current ? .semibold : .regular)
                            .lineLimit(1)
                            .saidWhole(item.words)
                        Spacer(minLength: 0)
                        AppInfoButton(title: item.words, text: item.info, id: "structural-auto-info-\(i)")
                    }
                    .frame(minHeight: AppInfoButton.target)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(item.done ? "done" : i == steps.current ? "under way" : "to come")
                }
            }
            HStack(spacing: DS.Space.m) {
                PillButton(LatticeMacMakeCopy.background, style: .secondary) { background() }
                    .fixedSize()
                    .background(CornerPairStyle.publish("macMakeBackground"))
                    .accessibilityIdentifier("mac-make-background")
                PillButton(LatticeMacMakeCopy.cancel, style: .secondary) { cancel() }
                    .fixedSize()
                    .background(CornerPairStyle.publish("macMakeCancel"))
                    .accessibilityIdentifier("mac-make-cancel")
            }
            .padding(.top, DS.Space.xs)
        }
        .padding(DS.Space.xl)
        .frame(width: Self.width, alignment: .leading)
        .background(CornerPairStyle.publish("structuralAutoCard"))
    }
}
