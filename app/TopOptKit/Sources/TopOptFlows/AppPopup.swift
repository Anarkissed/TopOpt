// AppPopup — ★ his iPad notes 11-20: "All errors should be nice looking Pop-ups at the centre of the screen in clear basic
// english. It should never be in small text and in technical language." and "If I input a number that's wrong, the error
// should be FRONT AND CENTRE, not at the bottom and written unclearly."
//
// One centred card over everything (the root view mounts it), a title, one or two plain sentences, OK. Anything technical (an
// engine's own words, a type, a function name) goes to the log only, never on the card. A shared holder, so any page — a
// sheet, the sample, the workspace — can raise it without another @State on the workspace view (whose size the iPad's main
// stack pays for, 11-20).
import SwiftUI
import TopOptDesign

public struct AppPopup: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var text: String
    /// An (i)'s explanation, not an error: its own icon and colour.
    public var info = false
    public init(title: String, text: String, info: Bool = false) { id = UUID(); self.title = title; self.text = text; self.info = info }
}

@MainActor public final class AppPopups: ObservableObject {
    public static let shared = AppPopups()
    @Published public var current: AppPopup? {
        didSet {
            if current == nil { action = nil; second = nil; third = nil; dismissTitle = nil; dismissShown = true; extra = nil; stacked = false }
        }
    }
    /// ★ notes30 depth: a choice pop-up (`choose`) — its actions stacked, the first on top, its dismiss word last — even with
    /// one action (LatticeReview's depth rule: Protect skin and Not now only).
    public private(set) var stacked = false
    /// ★ notes29 (his 11-25, the one (i)): content an (i) shows under its words (a Flexible row's core detail); cleared with it.
    public private(set) var extra: AnyView?
    /// ★ notes25: a third action (the print file's refusal, Auto adjusted: "Lattice again", "Change settings", "Show me").
    public private(set) var third: (title: String, run: () -> Void)?
    /// ★ notes25: whether the dismiss button is drawn beside the actions (a tap outside the card still closes it).
    public private(set) var dismissShown = true
    /// The pop-up's one action beside OK (e.g. "Try again"); cleared with it.
    public private(set) var action: (title: String, run: () -> Void)?
    /// ★ his 11-22 (no Mac: "try again", cancel, or make it on the iPad): a second action, and the dismiss button's own word.
    public private(set) var second: (title: String, run: () -> Void)?
    public private(set) var dismissTitle: String?
    /// What each raise said, while a test records (FlexibleSaid.recording).
    public static var recorded: [AppPopup] = []

    /// Raise one; `log` (technical) goes to the log only.
    public func show(_ title: String, _ text: String, log: String? = nil, action: (title: String, run: () -> Void)? = nil) {
        if let log { NSLog("TopOpt popup (%@): %@", title, log) }
        let p = AppPopup(title: title, text: text)
        if FlexibleSaid.recording { Self.recorded.append(p) }
        current = p
        self.action = action
        second = nil; third = nil; dismissTitle = nil; dismissShown = true   // ★ notes25: never another pop-up's buttons
        extra = nil
        stacked = false
    }

    /// ★ his 11-22: a pop-up with two actions and a dismiss word ("Try again", "Make it on the iPad", "Cancel").
    /// ★ notes25: `third` — a third action below the second; `dismiss` nil — no dismiss button among them.
    /// ★ notes30 depth: `second` nil — one action and the dismiss word, stacked the same way.
    public func choose(_ title: String, _ text: String, log: String? = nil, first: (title: String, run: () -> Void),
                       second: (title: String, run: () -> Void)?, third: (title: String, run: () -> Void)? = nil,
                       dismiss: String?) {
        show(title, text, log: log, action: first)
        stacked = true
        self.second = second
        self.third = third
        dismissTitle = dismiss
        dismissShown = dismiss != nil
    }

    /// An (i): the setting's name and its explanation, in the same centred card. ★ notes29 (his 11-25): no OK — a big bold
    /// "Tap anywhere to continue", and any tap anywhere closes it; `action` (e.g. "Mark as tested") is offered above that line,
    /// `extra` drawn under the words.
    public func help(_ title: String, _ text: String, action: (title: String, run: () -> Void)? = nil, extra: AnyView? = nil) {
        let p = AppPopup(title: title, text: text, info: true)
        if FlexibleSaid.recording { Self.recorded.append(p) }
        current = p
        self.action = action
        second = nil; third = nil; dismissTitle = nil; dismissShown = false; stacked = false
        self.extra = extra
    }

    /// A wrong number, said front and centre: the setting, what is allowed, and what he typed.
    public func wrongNumber(_ setting: String, _ why: String) {
        show("\(setting.replacingOccurrences(of: " (0 = off)", with: "")): that number won’t work", why)
    }
}

struct AppPopupLayer: View {
    @ObservedObject var popups = AppPopups.shared

    var body: some View {
        if let p = popups.current {
            GeometryReader { g in
                ZStack {
                    // The dim backdrop: a tap on it closes the pop-up (an error's too, as before). ★ notes29: a Button, so the
                    // tap is the same on the iPad and in the hosted tests (a test's click never reaches an onTapGesture)
                    Button { popups.current = nil } label: {
                        Rectangle().fill(Color.black.opacity(0.35))
                            .frame(width: g.size.width, height: g.size.height)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .ignoresSafeArea()
                    .accessibilityLabel(p.info ? AppInfoCard.tapAnywhere : "Close")
                    .background(CornerPairStyle.publish("appPopupBackdrop"))
                    if p.info { infoCard(p, room: g.size) } else { errorCard(p) }
                }
                .frame(width: g.size.width, height: g.size.height)
            }
            .transition(.opacity)
            .zIndex(100)
        }
    }

    /// ★ notes29 (his 11-25): an (i)'s explanation — his liked Organic card, front and centre, as wide as its words need (it
    /// grows wider before it grows taller, and scrolls only if it outgrows the screen), with no OK: a big bold "Tap anywhere to
    /// continue", and any tap anywhere (the card too: the card is one button) closes it. An action it offers (e.g. "Mark as
    /// tested") is its own button, laid over the card in the slot the card keeps for it.
    private func infoCard(_ p: AppPopup, room: CGSize) -> some View {
        let width = AppInfoCard.width(for: p.text, title: p.title, room: room.width)
        let action = popups.action
        let content = VStack(spacing: DS.Space.m) {
            Image(systemName: AppInfoGlyph.litSymbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(DS.Color.accent.color)
            Text(p.title).dsStyle(DS.TypeScale.title).foregroundStyle(DS.Color.textPrimary.color)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("app-popup-title")
            Text(p.text).dsStyle(DS.TypeScale.body).foregroundStyle(DS.Color.textSecondary.color)
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CornerPairStyle.publish("appPopupText"))
                .accessibilityIdentifier("app-popup-text")
            if let extra = popups.extra {
                extra.frame(maxWidth: .infinity, alignment: .leading)
            }
            if action != nil {   // the action's slot (its button is laid over it, above the card's own tap)
                Color.clear.frame(height: 44)
                    .anchorPreference(key: AppInfoActionSlot.self, value: .bounds) { $0 }
            }
            Text(AppInfoCard.tapAnywhere)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .multilineTextAlignment(.center)
                .padding(.top, DS.Space.xs)
                .accessibilityIdentifier("app-popup-tap-anywhere")
        }
        .padding(DS.Space.xl2)
        .frame(width: width)
        return Button { popups.current = nil } label: {
            GlassPanel {
                ViewThatFits(in: .vertical) {
                    content
                    ScrollView(.vertical, showsIndicators: true) { content }
                        .frame(maxHeight: max(200, room.height - 2 * AppInfoCard.margin))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(AppInfoCard.tapAnywhere)
        .accessibilityIdentifier("app-popup-card")
        .overlayPreferenceValue(AppInfoActionSlot.self) { slot in
            GeometryReader { g in
                if let slot, let a = action {
                    let r = g[slot]
                    PillButton(a.title) { let run = a.run; popups.current = nil; run() }
                        .background(CornerPairStyle.publish("appPopupAction"))
                        .accessibilityIdentifier("app-popup-action")
                        .frame(width: r.width)
                        .position(x: r.midX, y: r.midY)
                }
            }
        }
        .background(CornerPairStyle.publish("appPopup"))
    }


    /// An error (his 11-20 rule): its title, its plain words and its own buttons (OK, Try again, …) — unchanged.
    private func errorCard(_ p: AppPopup) -> some View {
        GlassPanel {
            VStack(spacing: DS.Space.m) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(DS.Color.warning.color)
                Text(p.title).dsStyle(DS.TypeScale.title).foregroundStyle(DS.Color.textPrimary.color)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("app-popup-title")
                Text(p.text).dsStyle(DS.TypeScale.body).foregroundStyle(DS.Color.textSecondary.color)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("app-popup-text")
                HStack(spacing: DS.Space.s) {
                    if popups.stacked, let a = popups.action {   // ★ his 11-22: the choices and a dismiss, stacked
                        VStack(spacing: DS.Space.s) {
                            // ★ notes30: each choice publishes its frame (a hosted test taps it, and holds it to 44 pt)
                            PillButton(a.title) { let run = a.run; popups.current = nil; run() }
                                .background(CornerPairStyle.publish("appPopupChoice1"))
                                .accessibilityIdentifier("app-popup-action")
                            if let b = popups.second {   // ★ notes30 depth: a choice pop-up may offer one action only
                                PillButton(b.title, style: .secondary) { let run = b.run; popups.current = nil; run() }
                                    .background(CornerPairStyle.publish("appPopupChoice2"))
                                    .accessibilityIdentifier("app-popup-second")
                            }
                            if let c = popups.third {   // ★ notes25
                                PillButton(c.title, style: .secondary) { let run = c.run; popups.current = nil; run() }
                                    .accessibilityIdentifier("app-popup-third")
                            }
                            if popups.dismissShown {
                                PillButton(popups.dismissTitle ?? "OK", style: .secondary) { popups.current = nil }
                                    .background(CornerPairStyle.publish("appPopupDismiss"))
                                    .accessibilityIdentifier("app-popup-ok")
                            }
                        }
                    } else if let a = popups.action {
                        PillButton("OK", style: .secondary) { popups.current = nil }
                            .accessibilityIdentifier("app-popup-ok")
                        PillButton(a.title) { let run = a.run; popups.current = nil; run() }
                            .accessibilityIdentifier("app-popup-action")
                    } else {
                        PillButton("OK") { popups.current = nil }
                            .accessibilityIdentifier("app-popup-ok")
                    }
                }
            }
            .padding(DS.Space.xl2)
            .frame(maxWidth: 440)
        }
        .padding(DS.Space.xl)
        .background(CornerPairStyle.publish("appPopup"))
    }
}


/// ★ his 11-20: "there should always be an (i) next to settings": the setting's (i), opening its explanation in the centred card.
/// ★ notes29 (his 11-25): the one (i), `AppInfoButton`.
struct OrganicInfoButton: View {
    let label: String
    var body: some View {
        if let e = OrganicSettingsHelp.entry(label) {
            AppInfoButton(title: label.replacingOccurrences(of: " (0 = off)", with: ""), text: e.info,
                          label: "About \(label)", id: "organic-info-" + label)
        }
    }
}

/// ★ his 11-20: "a couple words under each setting": its grey line.
struct OrganicGreyLine: View {
    let label: String
    var body: some View {
        if let e = OrganicSettingsHelp.entry(label) {
            let _ = LatticeCaptions.record(e.grey)   // ★ notes29: held to five words (LatticeCaptionsNotes29Tests)
            Text(e.grey).font(.system(size: 11.5)).foregroundStyle(DS.Color.textTertiary.color)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("organic-grey-" + label)
        }
    }
}

/// ★ his 11-20: the glossary behind one short link, opening as a card; never shown open.
struct OrganicGlossaryLink: View {
    var body: some View {
        Button { AppPopups.shared.help(OrganicSettingsHelp.glossaryTitle, OrganicSettingsHelp.glossary) } label: {
            Text(OrganicSettingsHelp.glossaryLink).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Color.accent.color)
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("organic-glossary")
    }
}
