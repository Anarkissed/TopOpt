// NotificationLane.swift — B2 (U16, design-system §4.34; his Phase 3 note P2: "Notifications of actions should NEVER cover
// up any menu items such as the Undo/Redo buttons. They should stay in the centre of the screen, but become two lines to
// ensure it does not cover or come too close to a required action/button").
//
// The status pill (top) and the toasts (bottom) stay centred on the screen. Their width is at most twice the distance from
// the centre to the nearest control on their row, less 16 pt on each side. Words that don't fit go to two lines: line 1 what
// happened, line 2 the grey detail (cut short with … only if it must be); never three. With no room on that row at all, the
// notification steps to the next free row (below the top rows, or above the corner and any timeline).
//
// The rule is pure (`NotificationLane.place`); `LaneNotice` draws one notification at the place the page's control frames
// (ChromeKeepOutKey) leave for it.

import SwiftUI
import TopOptDesign

enum NotificationLane {
    enum Edge { case top, bottom }

    /// Kept clear of the nearest control on each side.
    static let sideClearance: CGFloat = 16
    /// Narrower than this, a notification doesn't fit on the row: it steps to the next free one.
    static let minWidth: CGFloat = 200
    /// The widest it ever is.
    static let maxWidth: CGFloat = 560
    /// A two-line notification's height (line 1 + line 2 + padding).
    static let twoLineHeight: CGFloat = 52
    /// Gap from a row of controls when it steps past them.
    static let stepGap: CGFloat = 8
    /// RED CONTROL (NotificationLaneTests): the old places — the toast 96 pt off the bottom, the status at the top, any width.
    @MainActor static var controlOldPlace = false

    struct Place: Equatable {
        var top: CGFloat
        var width: CGFloat
        /// Where it is centred: the screen's centre, or — when no row has room there — the middle of its row's widest gap.
        var cx: CGFloat? = nil
    }

    /// The width the row [top, top + height] leaves round the centre `cx`: twice the distance to the nearest control that
    /// shares the row, less `sideClearance` each side (capped at `maxWidth`).
    static func width(top: CGFloat, height: CGFloat, cx: CGFloat, viewport: CGSize, controls: [CGRect]) -> CGFloat {
        var half = Swift.min(cx, viewport.width - cx)
        for c in controls where c.maxY > top + 0.5 && c.minY < top + height - 0.5 {
            if c.minX <= cx && c.maxX >= cx { return 0 }            // a control on the centre line: no room on this row
            half = Swift.min(half, c.maxX < cx ? cx - c.maxX : c.minX - cx)
        }
        return Swift.min(maxWidth, Swift.max(0, 2 * (half - sideClearance)))
    }

    /// Where a notification goes: its preferred row if `minWidth` fits there, else the next free row — down from the top
    /// rows, up from the bottom ones — past the controls in the way.
    static func place(edge: Edge, preferred: CGFloat, height: CGFloat = twoLineHeight, viewport: CGSize,
                      controls: [CGRect]) -> Place {
        let cx = viewport.width / 2
        var top = edge == .top ? preferred : preferred - height
        for _ in 0..<12 {
            let w = width(top: top, height: height, cx: cx, viewport: viewport, controls: controls)
            if w >= minWidth { return Place(top: top, width: w) }
            let inRow = controls.filter { $0.maxY > top + 0.5 && $0.minY < top + height - 0.5 }
            guard !inRow.isEmpty else { return Place(top: top, width: w) }
            top = edge == .top ? (inRow.map(\.maxY).max() ?? top) + stepGap
                               : (inRow.map(\.minY).min() ?? top) - stepGap - height
            if top < 0 || top + height > viewport.height { break }
        }
        // no row has room at the centre (11″ portrait with both panels open): never over a control — the middle of the
        // preferred row's widest gap
        let row = edge == .top ? preferred : preferred - height
        let g = widestGap(top: row, height: height, viewport: viewport, controls: controls)
        return Place(top: row, width: Swift.min(maxWidth, Swift.max(0, g.width - 2 * sideClearance)), cx: g.midX)
    }

    /// The row's widest stretch with no control in it.
    static func widestGap(top: CGFloat, height: CGFloat, viewport: CGSize, controls: [CGRect]) -> CGRect {
        let spans = controls.filter { $0.maxY > top + 0.5 && $0.minY < top + height - 0.5 }
            .map { ($0.minX, $0.maxX) }.sorted { $0.0 < $1.0 }
        var best = CGRect.zero, x: CGFloat = 0
        for (a, b) in spans + [(viewport.width, viewport.width)] {
            if a - x > best.width { best = CGRect(x: x, y: top, width: a - x, height: height) }
            x = Swift.max(x, b)
        }
        return best
    }

    /// A one-string notification as its two lines: what happened, then the detail (split at " — ", " · " or ". ").
    static func lines(_ text: String) -> (main: String, detail: String?) {
        for sep in [" — ", " · ", ". "] {
            if let r = text.range(of: sep) {
                let main = String(text[..<r.lowerBound]), rest = String(text[r.upperBound...])
                if !main.isEmpty, !rest.isEmpty { return (main, rest) }
            }
        }
        return (text, nil)
    }
}

/// One notification in the lane: centred, at most two lines, as wide as its row allows.
struct LaneNotice: View {
    let text: String
    let place: NotificationLane.Place
    /// Its published frame ("lane-<key>") and accessibility id.
    let key: String

    var body: some View {
        let l = NotificationLane.lines(text)
        VStack(spacing: 1) {
            Text(l.main)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(l.detail == nil ? 2 : 1).truncationMode(.tail)
            if let d = l.detail {
                Text(d)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 8).padding(.horizontal, DS.Space.l)
        .frame(maxWidth: place.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Capsule().fill(.ultraThinMaterial).overlay(Capsule().fill(DS.Surface.toast.color)))
        .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1))
        .clipShape(Capsule())
        .compositingGroup()
        .dsShadow(.toast)
        .background(NumberPad.published("lane-\(key)"))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lane-\(key)")
    }
}

/// The page's controls, as the lane reads them: every published control frame except the lane's own and the number pad.
@MainActor
final class LaneControls: ObservableObject {
    @Published private(set) var frames: [CGRect] = []

    func update(_ all: [String: CGRect]) {
        // a notification's own buttons (Open, ×) are inside its lane frame: they are not in its way
        let lanes = all.filter { $0.key.hasPrefix("lane-") }.map { $0.value.insetBy(dx: -1, dy: -1) }
        let f = all.filter { k, r in !Self.ignored(k) && !lanes.contains { $0.contains(r) } }.map(\.value)
            .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        if f != frames { frames = f }
    }

    /// Frames that are not controls a notification must keep clear of.
    static func ignored(_ key: String) -> Bool {
        key.hasPrefix("lane-") || key.hasPrefix("numberPad")
    }
}

/// The app's toast (design-system §4.12, §4.34): bottom centre, 96 pt off the bottom edge or above the first free row, never
/// over a control, two lines at most; it goes after `DS.Motion.toastDwell`.
struct LaneToast: ViewModifier {
    @Binding var message: String?
    @StateObject private var controls = LaneControls()

    /// The design's toast line: 96 pt off the bottom edge.
    static let bottomInset: CGFloat = 96

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(ChromeKeepOutKey.self) { controls.update($0) }
            .overlay {
                GeometryReader { g in
                    if let message {
                        let space = g.frame(in: .global)
                        let local = controls.frames.map { $0.offsetBy(dx: -space.minX, dy: -space.minY) }
                        let p = NotificationLane.controlOldPlace
                            ? NotificationLane.Place(top: g.size.height - Self.bottomInset - NotificationLane.twoLineHeight, width: 10_000)
                            : NotificationLane.place(edge: .bottom, preferred: g.size.height - Self.bottomInset,
                                                     viewport: g.size, controls: local)
                        let cx = p.cx ?? g.size.width / 2, span = 2 * Swift.min(cx, g.size.width - cx)
                        LaneNotice(text: message, place: p, key: "toast")
                            .frame(width: span, height: NotificationLane.twoLineHeight, alignment: .bottom)
                            .padding(.leading, cx - span / 2)
                            .frame(width: g.size.width, alignment: .leading)
                            .padding(.top, p.top)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .task(id: message) {
                                try? await Task.sleep(nanoseconds: UInt64(DS.Motion.toastDwell * 1_000_000_000))
                                if self.message == message { self.message = nil }
                            }
                    }
                }
                .allowsHitTesting(false)
            }
            .animation(DS.Motion.toastIn, value: message)
    }
}

extension View {
    /// Show `message` as the app's toast in the notification lane; it clears the binding after the design's dwell.
    func laneToast(_ message: Binding<String?>) -> some View {
        modifier(LaneToast(message: message))
    }

    /// A page's top lane reads its controls here (`LaneSlot`).
    func laneControls(_ controls: LaneControls) -> some View {
        onPreferenceChange(ChromeKeepOutKey.self) { controls.update($0) }
            .environment(\.laneControls, controls)
    }
}

private struct LaneControlsKey: EnvironmentKey {
    static let defaultValue: LaneControls? = nil
}
extension EnvironmentValues {
    var laneControls: LaneControls? {
        get { self[LaneControlsKey.self] }
        set { self[LaneControlsKey.self] = newValue }
    }
}

/// A status notification at the top of the page (§4.8, §4.34): centred, `content` given the width its row allows (it wraps
/// to two lines inside it), on the first free row from `preferred` down. Its frame is published as "lane-<key>".
struct LaneSlot<Content: View>: View {
    let key: String
    var preferred: CGFloat = DS.Space.xl3
    @ViewBuilder let content: (CGFloat) -> Content
    @Environment(\.laneControls) private var controls

    var body: some View {
        if let controls {
            LaneSlotBody(controls: controls, key: key, preferred: preferred, content: content)
        } else {
            // no lane above (a preview): today's place, the width of the 13″ landscape lane
            VStack { content(NotificationLane.minWidth + 40).padding(.top, preferred); Spacer() }.frame(maxWidth: .infinity)
        }
    }
}

private struct LaneSlotBody<Content: View>: View {
    @ObservedObject var controls: LaneControls
    let key: String
    let preferred: CGFloat
    let content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { g in
            let space = g.frame(in: .global)
            let local = controls.frames.map { $0.offsetBy(dx: -space.minX, dy: -space.minY) }
            let p = NotificationLane.controlOldPlace
                ? NotificationLane.Place(top: preferred, width: 10_000)
                : NotificationLane.place(edge: .top, preferred: preferred, viewport: g.size, controls: local)
            let cx = p.cx ?? g.size.width / 2, span = 2 * Swift.min(cx, g.size.width - cx)
            content(p.width)
                .frame(maxWidth: p.width)
                .fixedSize(horizontal: false, vertical: true)
                .background(NumberPad.published("lane-\(key)"))
                .frame(width: span, alignment: .top)
                .padding(.leading, cx - span / 2)
                .frame(width: g.size.width, alignment: .topLeading)
                .padding(.top, p.top)
        }
    }
}
