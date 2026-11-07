// NumberPadHost.swift — B2 (U15, design-system §4.33; his Phase 3 note P1: "All numerical input places should open a
// numerical input keyboard when tapped, unless a keyboard is connected to the ipad").
//
// What `.numberPad(...)` attaches to a number (`NumberPadField`):
//   • the app's pad (NumberPad: the setting's name and range, §4.33's keys) in a popover beside the number — below it, above
//     when there is no room (the system's own placement; on the iPad a tap anywhere else closes it);
//   • Done, or a tap anywhere else, keeps the number; outside its range the nearest allowed value is kept and the page says
//     so ("Kept 40 (1 to 40 mm)", through `numberPadNote`);
//   • with a hardware keyboard connected (iPadOS reports it: `GCKeyboard.coalesced`, watched through
//     `GCKeyboardDidConnect` / `GCKeyboardDidDisconnect`) no pad opens: the number takes typing in place, Return keeps it,
//     Esc cancels.
// (An in-page pad was tried first: on the Mac a SwiftUI layer over the 3D view only wins clicks where SwiftUI last handled
// an event, so a pad opened from a menu could not be clicked. The popover is its own presentation everywhere.)

import SwiftUI
import TopOptDesign
#if canImport(GameController)
import GameController
#endif

/// Whether a hardware keyboard is connected. Tests set `override` (the Mac they run on always has one).
@MainActor
public final class HardwareKeyboard: ObservableObject {
    public static let shared = HardwareKeyboard()
    @Published public private(set) var connected = false
    /// Tests only: forces the answer (nil = what the system reports).
    public static var override: Bool? { didSet { shared.refresh() } }
    private var observers: [NSObjectProtocol] = []

    private init() {
        #if canImport(GameController) && os(iOS)
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        #endif
        refresh()
    }

    func refresh() {
        let now: Bool
        if let o = Self.override {
            now = o
        } else {
            #if canImport(GameController) && os(iOS)
            now = GCKeyboard.coalesced != nil
            #else
            now = false   // the Mac test host: the pad, unless a test says otherwise
            #endif
        }
        if now != connected { connected = now }
    }
}

/// Where the open pad's keys are, in its own window (the hosted tests click them; the popover is not in the page's window).
@MainActor
enum NumberPadProbe {
    static var frames: [String: CGRect] = [:]
    /// RED CONTROL (NumberPadHostedTests): the old pad — no range, no keyboard path, the old keys.
    static var controlOldPad = false
}

private struct NumberPadNoteKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}
extension EnvironmentValues {
    /// Where a page says what a number pad kept ("Kept 40 (1 to 40 mm)"): its toast.
    var numberPadNote: ((String) -> Void)? {
        get { self[NumberPadNoteKey.self] }
        set { self[NumberPadNoteKey.self] = newValue }
    }
}

extension View {
    /// Where the numbers inside say what a pad kept.
    func numberPadNote(_ note: @escaping (String) -> Void) -> some View {
        environment(\.numberPadNote, note)
    }
}

/// What `.numberPad(...)` attaches to a number.
struct NumberPadField: ViewModifier {
    @Binding var presented: Bool
    let config: NumberPad.Config
    let seed: Double?
    let onValue: (Double?) -> Void

    @Environment(\.numberPadNote) private var note
    @ObservedObject private var keyboard = HardwareKeyboard.shared
    /// What has been typed since it opened (nil = nothing yet).
    @State private var typed: Double?? = nil

    func body(content: Content) -> some View {
        if keyboard.connected, !NumberPadProbe.controlOldPad {
            content.overlay {
                if presented {
                    HardwareNumberEntry(config: config, seed: seed,
                                        keep: { v in typed = .some(v); if let v { onValue(v) }; presented = false },
                                        cancel: { typed = nil; presented = false })
                }
            }
            .onChange(of: presented) { open in if !open { closed() } }
        } else {
            content
                .popover(isPresented: $presented, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                    NumberPad(config: NumberPadProbe.controlOldPad ? NumberPad.Config(title: config.title, unit: config.unit,
                                                                                       allowsDecimal: config.allowsDecimal)
                                                                   : config,
                              seed: seed,
                              onValue: { v in typed = .some(v); onValue(v) },
                              onDone: { presented = false })
                        .presentationCompactAdaptationPopover()
                }
                .onChange(of: presented) { open in if open { typed = nil } else { closed() } }
        }
    }

    /// Done, a tap elsewhere or Return: outside the range, the nearest allowed value, and the page says so.
    private func closed() {
        defer { typed = nil }
        guard config.clampsOnClose, !NumberPadProbe.controlOldPad, case .some(.some(let v)) = typed,
              let r = config.range, !r.contains(v) else { return }
        onValue(r.clamp(v))
        note?(r.keptNote(r.clamp(v), unit: config.unit))
    }
}

private extension View {
    @ViewBuilder func presentationCompactAdaptationPopover() -> some View {
        if #available(iOS 16.4, macOS 13.3, *) {
            presentationCompactAdaptation(.popover)
        } else {
            self
        }
    }
}

/// With a keyboard connected: the number takes typing in place. Return keeps it, Esc cancels.
private struct HardwareNumberEntry: View {
    let config: NumberPad.Config
    let seed: Double?
    let keep: (Double?) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.plain)
            .padding(.horizontal, 6)
            .frame(minWidth: 60, maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(DS.Surface.dialog.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                    .strokeBorder(DS.Color.accent.color, lineWidth: 1.5)))
            .focused($focused)
            .onSubmit { keep(Self.parse(text)) }
            .onExitCommandCompat { cancel() }
            .onAppear {
                text = NumberPadEntry.seedString(seed, allowsDecimal: config.allowsDecimal)
                focused = true
            }
            .background(NumberPad.published("numberPad-typing"))
            .accessibilityLabel(config.header)
            .accessibilityIdentifier("numberPad-typing")
    }

    static func parse(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "%", with: ""))
    }
}

private extension View {
    /// Esc: macOS's exit command; on the iPad a hardware Esc (iOS 17's key press).
    @ViewBuilder func onExitCommandCompat(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        if #available(iOS 17.0, *) {
            onKeyPress(.escape) { action(); return .handled }
        } else {
            self
        }
        #endif
    }
}
