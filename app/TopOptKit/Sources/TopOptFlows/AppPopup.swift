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
    @Published public var current: AppPopup? { didSet { if current == nil { action = nil } } }
    /// The pop-up's one action beside OK (e.g. "Try again"); cleared with it.
    public private(set) var action: (title: String, run: () -> Void)?
    /// What each raise said, while a test records (FlexibleSaid.recording).
    public static var recorded: [AppPopup] = []

    /// Raise one; `log` (technical) goes to the log only.
    public func show(_ title: String, _ text: String, log: String? = nil, action: (title: String, run: () -> Void)? = nil) {
        if let log { NSLog("TopOpt popup (%@): %@", title, log) }
        let p = AppPopup(title: title, text: text)
        if FlexibleSaid.recording { Self.recorded.append(p) }
        current = p
        self.action = action
    }

    /// An (i): the setting's name and its explanation, in the same centred card.
    public func help(_ title: String, _ text: String) {
        let p = AppPopup(title: title, text: text, info: true)
        if FlexibleSaid.recording { Self.recorded.append(p) }
        current = p
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
            ZStack {
                Rectangle().fill(Color.black.opacity(0.35)).ignoresSafeArea()
                    .onTapGesture { popups.current = nil }
                GlassPanel {
                    VStack(spacing: DS.Space.m) {
                        Image(systemName: p.info ? "info.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle((p.info ? DS.Color.accent : DS.Color.warning).color)
                        Text(p.title).dsStyle(DS.TypeScale.title).foregroundStyle(DS.Color.textPrimary.color)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("app-popup-title")
                        Text(p.text).dsStyle(DS.TypeScale.body).foregroundStyle(DS.Color.textSecondary.color)
                            .multilineTextAlignment(p.info ? .leading : .center).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: p.info ? .leading : .center)
                            .accessibilityIdentifier("app-popup-text")
                        HStack(spacing: DS.Space.s) {
                            if let a = popups.action {
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
                    .frame(maxWidth: p.info ? 520 : 440)
                }
                .padding(DS.Space.xl)
                .background(CornerPairStyle.publish("appPopup"))
            }
            .transition(.opacity)
            .zIndex(100)
        }
    }
}


/// ★ his 11-20: "there should always be an (i) next to settings": the setting's (i), opening its explanation in the centred card.
struct OrganicInfoButton: View {
    let label: String
    var body: some View {
        if let e = OrganicSettingsHelp.entry(label) {
            Button { AppPopups.shared.help(label.replacingOccurrences(of: " (0 = off)", with: ""), e.info) } label: {
                Image(systemName: "info.circle").font(.system(size: 13, weight: .regular))
                    .foregroundStyle(DS.Color.textTertiary.color)
                    .frame(width: 28, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About \(label)")
            .accessibilityIdentifier("organic-info-" + label)
        }
    }
}

/// ★ his 11-20: "a couple words under each setting": its grey line.
struct OrganicGreyLine: View {
    let label: String
    var body: some View {
        if let e = OrganicSettingsHelp.entry(label) {
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
