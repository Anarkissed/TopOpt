// FlexibleMainGroupSelector — round 7 batch R7-E3: the squeeze-group SELECTOR on the main Lattice page, on its legend card
// (task 2026-09-29-flexible-screens). His notes of 2026-10-19 (binding; the later one refines the earlier):
//   ~13:10 "please provide a selector for which group plays through the bending just like previously. I want to be able to cycle
//          through each and/or review a single one. Each of the views should have a selector next to the legend as well."
//   his answer: "GROUP SELECTOR next to the legend for Play and EVERY view: "All (one after another)" then each group by name; the
//          3-second hold on Heat stays as a shortcut for all at once."
//   ~14:40 "the playing of the different squishes should happen on the *Lattice* page - along with the different group selector on
//          the legend. … The Lattice page requires the squish group selector - as there is no other way to select/choose which view."
// ★ ONE MENU on the card (44 pt), first in it: "All (one after another)" then each group by HIS name (an edges group too — R7-E3's
// interim sim). The pick is the main page's one squeeze (`FlexibleMainStage.pick`): Play, Heat, Bend, X-ray, Stress and Prisms all
// follow it. Shown with two or more groups while Play or any view is on. Under it, while an edges group's interim sim is what
// shows, the one chip line "Lattice not tuned for this press yet" (the reviewer's interim-sim condition).

import SwiftUI
import TopOptDesign
import TopOptKit

extension FlexibleMainStage {
    /// ★ RED CONTROL only: no selector (the main page before his 2026-10-19 notes).
    @MainActor static var controlNoGroupSelector = false

    /// One entry of the selector.
    public struct GroupChoice: Equatable {
        public let id: String
        public let title: String
        /// The group's number (nil: "All").
        public let number: Int?
    }

    /// The selector's entries: "All (one after another)" then each group by its name; [] with fewer than two groups.
    public var groupChoices: [GroupChoice] {
        guard !Self.controlNoGroupSelector, let m = model else { return [] }
        let groups = sims.compactMap { s -> GroupChoice? in
            guard case .group(let n) = s.kind else { return nil }
            return GroupChoice(id: s.id, title: m.groupName(number: n), number: n)
        }
        guard groups.count > 1 else { return [] }
        return [GroupChoice(id: FlexibleSim.allID, title: FlexibleRowCopy.selectorAll, number: nil)] + groups
    }

    /// The selector shows: two or more groups, with Play or any view on.
    public var groupSelectorShown: Bool {
        guard !groupChoices.isEmpty else { return false }
        return playOn || !legendKinds.isEmpty || legendPrismsRow || xrayOn
    }

    /// The entry picked now (the main page's one squeeze; "All" while every group plays in turn).
    public var groupChoiceID: String? { selectedSim ?? groupChoices.first?.id }

    /// The chip line under the selector: an edges group's interim sim is what shows (picked, or "All" playing its turn).
    public var notTunedChip: String? {
        guard let m = model else { return nil }
        if let id = groupChoiceID, id != FlexibleSim.allID { return m.notTunedLine(simID: id) }
        return m.notTunedLine(simID: loop.playingSimID)
    }

    /// The legend card's rows the selector takes (the 44 pt menu: two view rows; the chip: one).
    var selectorRows: Int { groupSelectorShown ? 2 + (notTunedChip == nil ? 0 : 1) : 0 }
}

/// The menu itself, first on the legend card.
struct FlexibleMainGroupSelector: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var loop: FlexibleSquishLoop

    var body: some View {
        let choices = main.groupChoices
        let picked = choices.first { $0.id == main.groupChoiceID } ?? choices.first
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                ForEach(choices, id: \.id) { c in
                    Button { main.pick(c.id) } label: {
                        if c.id == picked?.id { Label(c.title, systemImage: "checkmark") } else { Text(c.title) }
                    }
                    .accessibilityIdentifier("flexible-group-choice-\(c.id)")
                }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(dot(picked).color).frame(width: 10, height: 10)
                    Text(picked?.title ?? "").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.Color.accent.color)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Capsule().fill(DS.Surface.panel.color.opacity(0.6))
                    .overlay(Capsule().strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
                .contentShape(Rectangle())
            }
            // found by looking (E3_03): the platform's pop-up chrome drew a second chevron round the label — the label alone
            .menuIndicator(.hidden)
            .fixedPopUpChrome()
            .accessibilityLabel("Squeeze group: \(picked?.title ?? "")")
            .accessibilityIdentifier("flexible-group-selector")
            if let chip = main.notTunedChip {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(DS.Color.warning.color)
                    Text(chip).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("flexible-not-tuned-chip")
            }
        }
    }

    private func dot(_ c: FlexibleMainStage.GroupChoice?) -> RGBA {
        guard let n = c?.number, let m = main.model else { return DS.Color.accent }
        return m.groupColour(number: n)
    }
}

private extension View {
    /// The menu draws its own label (iOS does); the Mac's offscreen render (the evidence) would add a pop-up button round it.
    @ViewBuilder func fixedPopUpChrome() -> some View {
        #if os(macOS)
        self.menuStyle(.button).buttonStyle(.plain)
        #else
        self
        #endif
    }
}
