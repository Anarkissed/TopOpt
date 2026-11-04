// DesignParts.swift — design-system §4's SHARED PARTS (approved design 2026-11-02; his ruling 11-04 "Look per screen": "all
// of these small fixes should be PART of the new design. Why are we building it in the old design space?").
//
// Every screen is rebuilt from these, so the panels, rows, chips, the corner and its run button, the folder tabs and the
// legend look and behave the same everywhere. Sizes and colours are the mockup's (mockup.html: .panel, .ph, .pb, .pf, .more,
// .ovl, .row, .sw, .srow, .fixc, .tagc, .chipm, .gbtn, .run, .corner, .ftabs, .legend) through the DS tokens; nothing here is
// drawn from a screen's own numbers.
//
//   §4.3  DSPanel          348 pt, radius 22, header (chevron + name + count, nothing else), sections, pinned footer, the
//                          "N more ⌄" cue, folded to a one-line pill; DSPanelSection = a section's overline.
//   §4.4  DSRow            [disclosure] [mark] Name ··· value [actions] — folder 44, group 48, face 48 (indented), include 48;
//                          selected / hidden / pending / locked / disabled / refused / "also in" states. DSRowEye, DSRowTrash,
//                          DSSwitch are its actions. (The Setting row is SettingRow, B2.)
//   §4.5  DSChip           role, fix (outlined accent; refused = danger), tag (quiet), value (a number box in a chip).
//   §4.6  DSRunButton      64 pt, accent + glow, two lines; same settings / finding / running / blocked / disabled.
//         DSSplitButton    the 64 pt ⌃ square beside it, a menu of the other run choices.
//         DSGlassButton    48 pt secondary ("Settings ⌄", "Compare", "Add part").
//   §4.17 DSFolderTabs     the 62 pt column of tabs on a wide panel's left edge (Part + each group and zone, "+ New").
//   §4.18 DSCorner         [Settings ⌄] [Run] [⌃], 12 pt apart, 24 pt from the edges; what it opens sits just above its top.
//   §4.22 DSLegend         one card per data view: title, "Tap to read", the ramp with its two ends, an optional selector.
//
// Every part publishes its frame (ChromeKeepOutKey) under the `key` it is given, so the hosted tests and the keep-outs find it.

import SwiftUI
import TopOptDesign

// MARK: - the parts' numbers (the mockup's)

public enum DSParts {
    /// §4.3: every left panel.
    public static let panelWidth: CGFloat = 348
    /// U14: the wide panel (Lattice settings, Squish, Print plan).
    public static let widePanelWidth: CGFloat = 440
    public static let panelRadius: CGFloat = DS.Radius.panel   // 22
    public static let headerHeight: CGFloat = 48
    public static let moreHeight: CGFloat = 28
    /// §4.4 / U3: the two row heights.
    public static let rowHeight: CGFloat = 48
    public static let shortRowHeight: CGFloat = 44
    public static let faceIndent: CGFloat = 34
    /// §4.6.
    public static let runHeight: CGFloat = 64
    public static let runMinWidth: CGFloat = 250
    public static let glassHeight: CGFloat = 48
    /// §4.18.
    public static let cornerGap: CGFloat = 12
    public static let cornerEdge: CGFloat = 24
    /// §4.17.
    public static let tabsWidth: CGFloat = 62
    /// §4.22.
    public static let legendWidth: CGFloat = 250
    /// Every control's hit area (U, Touch).
    public static let target: CGFloat = 44

    /// The coordinate space a panel's body names, so its rows can say where they sit (panels never nest).
    static let bodySpace = "DSPanelBody"
    static let strokeSub = DS.Color.strokeSubtle
    static let moreFill = DS.Color.accent.opacity(0.06)

    static func publish(_ key: String) -> some View {
        GeometryReader { g in Color.clear.preference(key: ChromeKeepOutKey.self, value: [key: g.frame(in: .global)]) }
            .allowsHitTesting(false)
    }
}

extension View {
    @ViewBuilder fileprivate func partsShadow(_ shadow: DS.Shadow?) -> some View {
        if let shadow { self.dsShadow(shadow) } else { self }
    }
}

// MARK: - §4.3 Panel

/// The panel's measures (its content's height, its footer's, its scroll view's), as preferences: they follow every layout, so
/// rows that grow or go while the panel is up re-size it (#362, 11-04: an `.onChange` inside the scroll content missed later
/// growth — a stale body height, a false "1 more", and the hidden row took the footer's taps).
struct DSPanelMeasureKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { $1 } }
}

/// A row's place inside its panel, so the panel can count what is below its fold.
struct DSPanelRowsKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// A left panel. Its header holds the chevron, the name and the count — nothing else (U2); a tap folds it to a one-line pill.
/// Its body scrolls under a pinned footer; rows below the fold are announced by "N more ⌄", which scrolls to them.
/// Frames: "<key>" (the panel), "<key>Header", "<key>More-<n>", "<key>Footer".
public struct DSPanel<Content: View, Footer: View>: View {
    let key: String
    let title: String
    let count: Int?
    let viewOnly: Bool
    let width: CGFloat
    let maxHeight: CGFloat?
    /// The empty state's one line ("Tap a face to start"), shown when `isEmpty`.
    let empty: String?
    let isEmpty: Bool
    @Binding var open: Bool
    let content: Content
    let footer: Footer

    @State private var rows: [String: CGRect] = [:]
    @State private var viewport: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    /// The body's height: its rows', never past the panel's max (less the header, the footer and the cue).
    private var bodyHeight: CGFloat? {
        guard contentHeight > 0 else { return nil }
        guard let maxHeight else { return contentHeight }
        let room = maxHeight - DSParts.headerHeight - footerHeight
        return contentHeight <= room ? contentHeight : max(DSParts.rowHeight, room - DSParts.moreHeight)
    }

    public init(key: String, title: String, count: Int? = nil, viewOnly: Bool = false, width: CGFloat = DSParts.panelWidth,
                maxHeight: CGFloat? = nil, empty: String? = nil, isEmpty: Bool = false, open: Binding<Bool>,
                @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.key = key; self.title = title; self.count = count; self.viewOnly = viewOnly; self.width = width
        self.maxHeight = maxHeight; self.empty = empty; self.isEmpty = isEmpty; self._open = open
        self.content = content(); self.footer = footer()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if open {
                ScrollViewReader { reader in
                    VStack(spacing: 0) {
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 0) {
                                if isEmpty, let empty {
                                    Text(empty).dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textSecondary.color)
                                        .frame(maxWidth: .infinity, minHeight: DSParts.rowHeight)
                                        .background(DSParts.publish(key + "Empty"))
                                }
                                content
                            }
                            .frame(width: width)   // a row never pushes past its panel
                            .background(GeometryReader { g in
                                Color.clear.preference(key: DSPanelMeasureKey.self, value: ["content": g.size.height])
                            })
                        }
                        .frame(height: bodyHeight)   // as tall as its rows, never past the panel's max
                        .coordinateSpace(name: DSParts.bodySpace)
                        .onPreferenceChange(DSPanelRowsKey.self) { rows = $0 }
                        .background(GeometryReader { g in
                            Color.clear.preference(key: DSPanelMeasureKey.self, value: ["viewport": g.size.height])
                        })
                        .clipped()                        // what scrolls out of the body is neither drawn nor tapped
                        .contentShape(Rectangle())
                        .overlay(alignment: .top) { Rectangle().fill(DSParts.strokeSub.color).frame(height: 1) }
                        let shown = bodyHeight ?? .infinity   // the body's own height: what it laid out, never a stale measure
                        let below = rows.filter { $0.value.minY > shown - 4 }.sorted { $0.value.minY < $1.value.minY }
                        if !below.isEmpty {
                            // a tap brings the next page into view: the first row below the fold at the top
                            Button { withAnimation(DS.Motion.sheetIn) { reader.scrollTo(below[0].key, anchor: .top) } } label: {
                                HStack(spacing: 4) {
                                    Text("\(below.count) more")
                                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                                }
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.accent.color)
                                .frame(maxWidth: .infinity).frame(height: DSParts.moreHeight)
                                .background(DSParts.moreFill.color)
                                .overlay(alignment: .top) { Rectangle().fill(DSParts.strokeSub.color).frame(height: 1) }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(DSParts.publish("\(key)More-\(below.count)"))
                            .accessibilityIdentifier("\(key)-more")
                        }
                    }
                }
                if Footer.self != EmptyView.self {
                    VStack(alignment: .leading, spacing: 6) { footer }
                        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) { Rectangle().fill(DSParts.strokeSub.color).frame(height: 1) }
                        .background(GeometryReader { g in
                            Color.clear.preference(key: DSPanelMeasureKey.self, value: ["footer": g.size.height])
                        })
                        .background(DSParts.publish(key + "Footer"))
                }
            }
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)   // the panel is as tall as what it holds (the body caps itself)
        .onPreferenceChange(DSPanelMeasureKey.self) { m in
            if let c = m["content"], abs(c - contentHeight) > 0.5 { contentHeight = c }
            if let v = m["viewport"], abs(v - viewport) > 0.5 { viewport = v }
            if let f = m["footer"], abs(f - footerHeight) > 0.5 { footerHeight = f }
        }
        .transformPreference(DSPanelMeasureKey.self) { $0 = [:] }   // (never an enclosing panel's)
        .background(RoundedRectangle(cornerRadius: open ? DSParts.panelRadius : DSParts.headerHeight / 2, style: .continuous)
            .fill(DS.Surface.panel.color))
        .overlay(RoundedRectangle(cornerRadius: open ? DSParts.panelRadius : DSParts.headerHeight / 2, style: .continuous)
            .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: open ? DSParts.panelRadius : DSParts.headerHeight / 2, style: .continuous))
        .dsShadow(DS.Shadow.panel)
        .background(DSParts.publish(key))
    }

    /// Chevron + name + count, nothing else (U2). "view only" in tertiary when the panel is locked (Cut).
    private var header: some View {
        Button { withAnimation(DS.Motion.sheetIn) { open.toggle() } } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .rotationEffect(.degrees(open ? 0 : -90))
                    .frame(width: 18)
                Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if viewOnly {
                    Text("view only").font(.system(size: 12)).foregroundStyle(DS.Color.textTertiary.color)
                }
                if let count {
                    Text("\(count)").font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: DSParts.headerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(DSParts.publish(key + "Header"))
        .accessibilityLabel(open ? "Fold \(title)" : "\(title), \(count ?? 0). Open")
        .accessibilityIdentifier("\(key)-header")
    }
}

extension DSPanel where Footer == EmptyView {
    public init(key: String, title: String, count: Int? = nil, viewOnly: Bool = false, width: CGFloat = DSParts.panelWidth,
                maxHeight: CGFloat? = nil, empty: String? = nil, isEmpty: Bool = false, open: Binding<Bool>,
                @ViewBuilder content: () -> Content) {
        self.init(key: key, title: title, count: count, viewOnly: viewOnly, width: width, maxHeight: maxHeight, empty: empty,
                  isEmpty: isEmpty, open: open, content: content, footer: { EmptyView() })
    }
}

/// A panel section's overline: "FACES 3", "LATTICE ZONES 1", with an optional accent action at its right ("+ Add zone").
public struct DSPanelSection: View {
    let title: String
    let count: Int?
    let action: (title: String, run: () -> Void)?
    let key: String
    public init(_ title: String, count: Int? = nil, key: String, action: (title: String, run: () -> Void)? = nil) {
        self.title = title; self.count = count; self.key = key; self.action = action
    }
    public var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(0.8)
                .foregroundStyle(DS.Color.textTertiary.color)
            if let count { Text("\(count)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(DS.Color.textTertiary.color) }
            Spacer(minLength: 0)
            if let action {
                Button(action: action.run) {
                    Text(action.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.accent.color)
                        .frame(minHeight: DSParts.target).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(DSParts.publish(key + "Action"))
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, action == nil ? 4 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSParts.publish(key))
    }
}

// MARK: - §4.4 Row

/// What sits before the name: a group's colour square, or a folder glyph.
public enum DSRowMark: Equatable {
    case colour(RGBA)
    case folder
}

/// The one line under a row: a pending row's "Give it a role first", a refused row's reason (with its fix chip).
public struct DSRowLine {
    public enum Tone: Equatable { case info, warning, danger }
    public let text: String
    public let tone: Tone
    public let fix: (title: String, run: () -> Void)?
    public init(_ text: String, tone: Tone = .info, fix: (title: String, run: () -> Void)? = nil) {
        self.text = text; self.tone = tone; self.fix = fix
    }
}

/// One row, one grammar: `[disclosure] [mark] Name [role] ··· value [actions]`.
/// Frames: "<key>" (the row), "<key>-line", "<key>-tag". A tap on the row runs `tap`; its actions are their own buttons.
public struct DSRow<Actions: View>: View {
    public enum Kind: Equatable {
        /// A scenario folder (44 pt).
        case folder
        /// A group (48 pt).
        case group
        /// One face inside an open group (48 pt, indented — note 28).
        case face
        /// A Topology group or folder on Lattice / Flexible, its trailing action an include switch (48 pt — note 23b).
        case include
        var height: CGFloat { self == .folder ? DSParts.shortRowHeight : DSParts.rowHeight }
    }

    let kind: Kind
    let key: String
    let mark: DSRowMark?
    let name: String
    let role: (glyph: String, colour: RGBA)?
    let value: String?
    /// nil: no disclosure; true / false: open / closed.
    let disclosure: Bool?
    var selected = false
    var hidden = false
    var disabled = false
    var locked = false
    /// "also in Group 3" (note 22).
    var tag: String?
    var line: DSRowLine?
    let tap: (() -> Void)?
    let actions: Actions

    public init(_ kind: Kind, key: String, mark: DSRowMark? = nil, name: String, role: (glyph: String, colour: RGBA)? = nil,
                value: String? = nil, disclosure: Bool? = nil, selected: Bool = false, hidden: Bool = false,
                disabled: Bool = false, locked: Bool = false, tag: String? = nil, line: DSRowLine? = nil,
                tap: (() -> Void)? = nil, @ViewBuilder actions: () -> Actions) {
        self.kind = kind; self.key = key; self.mark = mark; self.name = name; self.role = role; self.value = value
        self.disclosure = disclosure; self.selected = selected; self.hidden = hidden; self.disabled = disabled
        self.locked = locked; self.tag = tag; self.line = line; self.tap = tap; self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if kind == .face { Color.clear.frame(width: DSParts.faceIndent - 12 - 8) }
                if let disclosure {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DS.Color.textTertiary.color)
                        .rotationEffect(.degrees(disclosure ? 90 : 0))
                        .frame(width: 16)
                        .allowsHitTesting(false)
                }
                Group {
                    if let mark { markView(mark) }
                    Text(name).font(.system(size: 14, weight: .medium)).foregroundStyle(DS.Color.textPrimary.color)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(minWidth: 36, alignment: .leading)   // the mockup's rule: the tag and the value stay whole,
                                                                    // the name shortens ("Left …  also in Group A  12 mm")
                    if let role {
                        Image(systemName: role.glyph).font(.system(size: 12, weight: .semibold)).foregroundStyle(role.colour.color)
                    }
                    if let tag { DSChip(.tag(tag), key: key + "-tag").layoutPriority(1) }   // before the name, after the value
                    Spacer(minLength: 8)
                    if let value {
                        Text(value).font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color).lineLimit(1)
                            .fixedSize()
                    }
                    if locked {
                        Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(DS.Color.textTertiary.color)
                            .frame(width: 28)
                            .accessibilityLabel("Locked")
                    }
                }
                .allowsHitTesting(false)
                HStack(spacing: 2) { actions }
            }
            .padding(.leading, 12).padding(.trailing, 10)
            .frame(minHeight: kind.height)
            .opacity(hidden || disabled ? 0.55 : 1)
            if let line { lineView(line) }
        }
        .background {
            if selected {
                ZStack(alignment: .leading) {
                    Rectangle().fill(DS.Color.fillSelected.color)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(DS.Color.accent.color, lineWidth: 1.5).padding(4)
                    RoundedRectangle(cornerRadius: 2).fill(DS.Color.accent.color).frame(width: 3).padding(.vertical, 6)
                }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(DSParts.strokeSub.color).frame(height: 1) }   // R2.3: each row its line
        .background {
            // the row's tap: a plain Button behind its words (a synthesised click never reaches onTapGesture on the Mac host)
            if let tap {
                Button { if !disabled { tap() } } label: { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(key)
        .id(key)
        .background(GeometryReader { g in
            Color.clear
                .preference(key: ChromeKeepOutKey.self, value: [key: g.frame(in: .global)])
                .preference(key: DSPanelRowsKey.self, value: [key: g.frame(in: .named(DSParts.bodySpace))])
        })
    }

    @ViewBuilder private func markView(_ m: DSRowMark) -> some View {
        switch m {
        case .colour(let c):
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(c.color).frame(width: 14, height: 14)
        case .folder:
            Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(DS.Color.textSecondary.color).frame(width: 16)
        }
    }

    private func lineView(_ l: DSRowLine) -> some View {
        HStack(spacing: 8) {
            if l.tone == .danger { Circle().fill(DS.Color.danger.color).frame(width: 6, height: 6) }
            Text(l.text).font(.system(size: 12.5))
                .foregroundStyle((l.tone == .danger ? DS.Color.danger : l.tone == .warning ? DS.Color.warning
                                  : DS.Color.textSecondary).color)
                .lineLimit(1)
            if let fix = l.fix { DSChip(.fix(fix.title), key: key + "-fix", action: fix.run) }
            Spacer(minLength: 0)
        }
        .padding(.leading, kind == .face ? DSParts.faceIndent : 34).padding(.trailing, 10).padding(.bottom, 8)
        .background(DSParts.publish(key + "-line"))
    }
}

extension DSRow where Actions == EmptyView {
    public init(_ kind: Kind, key: String, mark: DSRowMark? = nil, name: String, role: (glyph: String, colour: RGBA)? = nil,
                value: String? = nil, disclosure: Bool? = nil, selected: Bool = false, hidden: Bool = false,
                disabled: Bool = false, locked: Bool = false, tag: String? = nil, line: DSRowLine? = nil,
                tap: (() -> Void)? = nil) {
        self.init(kind, key: key, mark: mark, name: name, role: role, value: value, disclosure: disclosure, selected: selected,
                  hidden: hidden, disabled: disabled, locked: locked, tag: tag, line: line, tap: tap, actions: { EmptyView() })
    }
}

/// A row's eye: struck while hidden (it still counts in the run).
public struct DSRowEye: View {
    let hidden: Bool
    let key: String
    let toggle: () -> Void
    public init(hidden: Bool, key: String, toggle: @escaping () -> Void) { self.hidden = hidden; self.key = key; self.toggle = toggle }
    public var body: some View {
        Button(action: toggle) {
            Image(systemName: hidden ? "eye.slash" : "eye").font(.system(size: 14))
                .foregroundStyle((hidden ? DS.Color.textTertiary : DS.Color.textSecondary).color)
                .frame(width: DSParts.target, height: DSParts.target).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(DSParts.publish(key))
        .accessibilityLabel(hidden ? "Show" : "Hide from view")
        .accessibilityIdentifier(key)
    }
}

/// A row's trash (its ask is the caller's ConfirmInPlace).
public struct DSRowTrash: View {
    let key: String
    let action: () -> Void
    public init(key: String, action: @escaping () -> Void) { self.key = key; self.action = action }
    public var body: some View {
        Button(action: action) {
            Image(systemName: "trash").font(.system(size: 14)).foregroundStyle(DS.Color.textSecondary.color)
                .frame(width: DSParts.target, height: DSParts.target).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(DSParts.publish(key))
        .accessibilityLabel("Delete")
        .accessibilityIdentifier(key)
    }
}

/// The include switch (an include row's trailing action, note 23b) and every switch in a row: 51 × 31, green when on.
public struct DSSwitch: View {
    let isOn: Bool
    let key: String
    var small = false
    var enabled = true
    let toggle: () -> Void
    public init(isOn: Bool, key: String, small: Bool = false, enabled: Bool = true, toggle: @escaping () -> Void) {
        self.isOn = isOn; self.key = key; self.small = small; self.enabled = enabled; self.toggle = toggle
    }
    public var body: some View {
        let w: CGFloat = small ? 42 : 51, h: CGFloat = small ? 26 : 31, knob: CGFloat = small ? 22 : 27
        Button(action: toggle) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? DS.Color.okGreen.color : Color.white.opacity(0.16)).frame(width: w, height: h)
                Circle().fill(Color.white).frame(width: knob, height: knob).padding(2)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            }
            .frame(minWidth: DSParts.target, minHeight: DSParts.target).contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .background(DSParts.publish(key))
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityIdentifier(key)
    }
}

/// A setting row's value (the mockup's `.vd`): a 34 pt box, radius 12, an optional glyph, the value, an optional ⌄ or ›. It is
/// the label of the row's menu or button, so it never takes a tap itself.
public struct DSValueBox: View {
    public enum Trail: Equatable { case none, menu, more }
    let text: String
    let systemImage: String?
    let trail: Trail
    var editing = false
    public init(_ text: String, systemImage: String? = nil, trail: Trail = .none, editing: Bool = false) {
        self.text = text; self.systemImage = systemImage; self.trail = trail; self.editing = editing
    }
    public var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 13, weight: .medium)) }
            Text(text).font(.system(size: 13, weight: .medium)).lineLimit(1).fixedSize()
            switch trail {
            case .none: EmptyView()
            case .menu:
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Color.textSecondary.color)
            case .more:
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Color.textSecondary.color)
            }
        }
        .foregroundStyle(DS.Color.textPrimary.color)
        .padding(.horizontal, 10).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Color.fillSubtle.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder((editing ? DS.Color.accent : DS.Color.strokePanel).color, lineWidth: 1))
        .frame(minHeight: DSParts.target)
        .contentShape(Rectangle())
    }
}

// MARK: - §4.5 Chip

/// A chip. A chip on the model never covers a panel (its caller moves it outside or fades it — the 10-28 rule).
/// Frame: "<key>"; an actionable chip's hit area is 44 pt.
public struct DSChip: View {
    public enum Kind: Equatable {
        /// glyph + role name in the role colour ("Anchor", "51 kg").
        case role(glyph: String, name: String, colour: RGBA)
        /// the one-tap fix beside a refusal, outlined in accent.
        case fix(String)
        /// small and quiet ("Not print-tested", "also in Group 3", "Draft", "v7b").
        case tag(String)
        /// a tag in the accent ("v7b" on a chosen card).
        case accentTag(String)
    }
    public enum State: Equatable { case normal, selected, disabled, refused }

    let kind: Kind
    var state: State = .normal
    let key: String
    let action: (() -> Void)?

    public init(_ kind: Kind, state: State = .normal, key: String, action: (() -> Void)? = nil) {
        self.kind = kind; self.state = state; self.key = key; self.action = action
    }

    public var body: some View {
        Group {
            if let action {
                Button(action: action) { face.frame(minWidth: DSParts.target, minHeight: DSParts.target).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .disabled(state == .disabled)
            } else {
                face
            }
        }
        .background(DSParts.publish(key))
        .accessibilityIdentifier(key)
    }

    @ViewBuilder private var face: some View {
        switch kind {
        case let .role(glyph, name, colour):
            HStack(spacing: 6) {
                Image(systemName: glyph).font(.system(size: 12, weight: .semibold))
                Text(name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .foregroundStyle((state == .selected ? RGBA(255, 255, 255, 1) : colour).color)
            .padding(.horizontal, 10).frame(height: 30)
            .background(Capsule().fill((state == .selected ? colour : DS.Color.chipSolid).color))
            .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: state == .selected ? 0 : 1))
            .opacity(state == .disabled ? 0.45 : 1)
        case .fix(let title):
            Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).fixedSize()
                .foregroundStyle((state == .refused ? DS.Color.danger : DS.Color.accent).color)
                .padding(.horizontal, 12).frame(height: 30)
                .background(Capsule().fill(DS.Color.chipSolid.color))
                .overlay(Capsule().strokeBorder((state == .refused ? DS.Color.danger : DS.Color.accent).opacity(0.55).color,
                                                lineWidth: 1))
                .opacity(state == .disabled ? 0.45 : 1)
        case .tag(let title), .accentTag(let title):
            let accent: Bool = { if case .accentTag = kind { return true } else { return false } }()
            Text(title).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle((accent ? DS.Color.accent : DS.Color.textSecondary).color)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(DS.Color.fillSubtle.color))
                .overlay(Capsule().strokeBorder((accent ? DS.Color.accent.opacity(0.4) : DS.Color.strokePanel).color, lineWidth: 1))
        }
    }
}

// MARK: - §4.6 Buttons

/// The corner's big button: 64 pt, accent + glow, two lines. One per screen (Optimize / Lattice / Export).
/// Frame: "<key>"; a blocked button's fix chip: "<key>Fix".
public struct DSRunButton: View {
    public enum State: Equatable {
        case ready
        /// grey, "Same settings as v6".
        case sameSettings(String)
        /// ring + "Finding Nadim's Mac mini…".
        case finding(String)
        /// ring + the time; a tap views it.
        case running(String)
        /// grey + ≤ 5 words, the fix chip beside it (U6).
        case blocked(words: String, fix: String)
        /// grey with the reason line.
        case disabled(String)
        /// grey, but a tap still goes somewhere (where the fix is: the type picker, the walls to mark).
        case grey(String)
    }
    let title: String
    let subtitle: String
    let state: State
    let key: String
    let action: () -> Void
    let fix: (() -> Void)?

    public init(_ title: String, subtitle: String, state: State = .ready, key: String, action: @escaping () -> Void,
                fix: (() -> Void)? = nil) {
        self.title = title; self.subtitle = subtitle; self.state = state; self.key = key; self.action = action; self.fix = fix
    }

    private var grey: Bool {
        switch state { case .sameSettings, .blocked, .disabled, .grey: return true; default: return false }
    }
    private var busy: Bool {
        switch state { case .finding, .running: return true; default: return false }
    }
    private var line2: String {
        switch state {
        case .ready: return subtitle
        case .sameSettings(let s), .finding(let s), .running(let s), .disabled(let s), .grey(let s): return s
        case .blocked(let w, _): return w
        }
    }

    public var body: some View {
        HStack(spacing: DSParts.cornerGap) {
            if case let .blocked(_, fixTitle) = state, let fix {
                DSChip(.fix(fixTitle), key: key + "Fix", action: fix)
            }
            Button(action: action) {
                HStack(spacing: 10) {
                    if busy { ProgressView().controlSize(.small).tint(.white) }
                    VStack(spacing: 1) {
                        Text(title).font(.system(size: 16, weight: .bold)).lineLimit(1).fixedSize()
                        // never cut (the mockup's `.run small`: nowrap; min-width 250): the button grows to the line
                        Text(line2).font(.system(size: 11.5)).lineLimit(1).fixedSize()
                            .foregroundStyle(grey ? DS.Color.textTertiary.color : Color.white.opacity(0.85))
                            .background(DSParts.publish("\(key)-line2"))
                    }
                }
                .foregroundStyle(grey ? DS.Color.textDisabled.color : Color.white)
                .padding(.horizontal, 22)
                .frame(minWidth: DSParts.runMinWidth, minHeight: DSParts.runHeight)
                .fixedSize()   // its own size, max(250, the lines + 44), whatever the parent offers
                .background(Capsule().fill((grey ? DS.Color.fillDisabled : busy ? DS.Color.accent.opacity(0.25) : DS.Color.accent).color))
                .overlay(Capsule().strokeBorder(DS.Color.accent.opacity(busy ? 0.6 : 0).color, lineWidth: 1))
                .partsShadow(grey || busy ? nil : DS.Shadow.accentGlow)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled({ if case .disabled = state { return true }; return false }())
            .background(DSParts.publish(key))
            .accessibilityIdentifier(key)
        }
    }
}

/// The ⌃ beside the run button: a 64 pt square opening the other run choices — a menu, or a plain button (#362: Flexible's ⌃
/// opens the lattice card panel).
public struct DSSplitButton<Items: View>: View {
    let key: String
    let items: Items
    var action: (() -> Void)?
    public init(key: String, @ViewBuilder items: () -> Items) { self.key = key; self.items = items() }
    /// True when it opens a menu (its items); false for the plain button.
    public var isMenu: Bool { action == nil }
    public var body: some View {
        Group {
            if let action {
                Button(action: action) { face }.buttonStyle(.plain)
            } else {
                Menu { items } label: { face }
                    .menuIndicator(.hidden)
                    .menuStyle(.button).buttonStyle(.plain)
            }
        }
        .fixedSize()
        .background(DSParts.publish(key))
        .accessibilityLabel("More ways to run")
        .accessibilityIdentifier(key)
    }
    private var face: some View {
        Image(systemName: "chevron.up").font(.system(size: 18, weight: .bold)).foregroundStyle(DS.Color.textPrimary.color)
            .frame(width: DSParts.runHeight, height: DSParts.runHeight)
            .background(RoundedRectangle(cornerRadius: DSParts.runHeight / 2, style: .continuous).fill(DS.Surface.bar.color))
            .overlay(RoundedRectangle(cornerRadius: DSParts.runHeight / 2, style: .continuous)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

extension DSSplitButton where Items == EmptyView {
    /// The ⌃ as a plain button: the same 64 pt square, `action` on a tap, no menu. Disfavoured: a trailing closure of menu
    /// items (Buttons also type-check as a `() -> Void`) stays the menu; one that cannot build Views takes this.
    @_disfavoredOverload
    public init(key: String, action: @escaping () -> Void) { self.key = key; self.items = EmptyView(); self.action = action }
}

/// The secondary button: 48 pt glass, label + optional glyph ("Settings ⌄", "Compare", "Add part"), and an optional tertiary
/// detail after the label (the mockup's "Settings  Fast · +Z · −Z ⌄"; frame "<key>-detail").
public struct DSGlassButton: View {
    let title: String
    let detail: String?
    let systemImage: String?
    let chevron: Bool
    var selected = false
    let key: String
    let action: () -> Void
    public init(_ title: String, detail: String? = nil, systemImage: String? = nil, chevron: Bool = false, selected: Bool = false,
                key: String, action: @escaping () -> Void) {
        self.title = title; self.detail = detail; self.systemImage = systemImage; self.chevron = chevron; self.selected = selected
        self.key = key; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 15, weight: .semibold)) }
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).fixedSize()
                if let detail {
                    Text(detail).font(.system(size: 15, weight: .medium)).foregroundStyle(DS.Color.textTertiary.color)
                        .lineLimit(1).fixedSize()
                        .background(DSParts.publish("\(key)-detail"))
                }
                if chevron {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                        // (the mockup keeps ⌄ while what it opens is up)
                }
            }
            .foregroundStyle(DS.Color.textPrimary.color)
            .padding(.horizontal, 16).frame(height: DSParts.glassHeight)
            .background(Capsule().fill((selected ? DS.Color.fillSelected : DS.Surface.bar).color))
            .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(DSParts.publish(key))
        .accessibilityIdentifier(key)
    }
}

// MARK: - §4.18 Corner

/// The bottom-right corner: `[Settings ⌄] [Run] [⌃]` (Results: `[Compare] [Export v7b (.stl)] [⌃]`), 12 pt apart, 24 pt from
/// the edges. What it opens (the Settings panel, a fix line) sits just above its top line, right-aligned — never behind it (N4).
/// Frames: "<key>" (the three), "<key>Above" (what it opens).
public struct DSCorner<Leading: View, Run: View, Split: View, Above: View>: View {
    let key: String
    let leading: Leading
    let run: Run
    let split: Split
    let above: Above
    public init(key: String, @ViewBuilder leading: () -> Leading, @ViewBuilder run: () -> Run, @ViewBuilder split: () -> Split,
                @ViewBuilder above: () -> Above) {
        self.key = key; self.leading = leading(); self.run = run(); self.split = split(); self.above = above()
    }
    public var body: some View {
        VStack(alignment: .trailing, spacing: DSParts.cornerGap) {
            above.background(DSParts.publish(key + "Above"))
            HStack(alignment: .bottom, spacing: DSParts.cornerGap) { leading; run; split }
                .background(DSParts.publish(key))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, DSParts.cornerEdge).padding(.bottom, DSParts.cornerEdge)
    }
}

extension DSCorner where Above == EmptyView {
    public init(key: String, @ViewBuilder leading: () -> Leading, @ViewBuilder run: () -> Run, @ViewBuilder split: () -> Split) {
        self.init(key: key, leading: leading, run: run, split: split, above: { EmptyView() })
    }
}

// MARK: - §4.17 Folder tabs

/// The column of tabs on a wide panel's left edge: Part, then one per group and zone in its colour, and "+ New" (Squish).
/// The selected tab merges into the panel. Frames: "<key>-<id>", "<key>-new".
public struct DSFolderTabs: View {
    public struct Tab: Identifiable, Equatable {
        public let id: String
        public let title: String
        public let colour: RGBA?
        /// A number drawn in the square (#362's Squish: past eight groups the palette repeats, so the square says which).
        public let badge: Int?
        public init(id: String, title: String, colour: RGBA? = nil, badge: Int? = nil) {
            self.id = id; self.title = title; self.colour = colour; self.badge = badge
        }
    }
    /// RED CONTROL (#362's FlexibleR7SettingsHostedTests): a title on one line, cut — the test proves it catches a cut name.
    @MainActor public static var controlOneLineTitle = false
    let tabs: [Tab]
    let selected: String?
    let key: String
    let pick: (String) -> Void
    let add: (() -> Void)?
    public init(_ tabs: [Tab], selected: String?, key: String, pick: @escaping (String) -> Void, add: (() -> Void)? = nil) {
        self.tabs = tabs; self.selected = selected; self.key = key; self.pick = pick; self.add = add
    }
    public var body: some View {
        VStack(spacing: 6) {
            ForEach(tabs) { t in
                Button { pick(t.id) } label: {
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill((t.colour ?? DS.Color.textTertiary).color).frame(width: 22, height: 22)
                            .overlay {
                                if let b = t.badge {
                                    Text("\(b)").font(.system(size: 11, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                                }
                            }
                        // ★ a name is drawn whole, never cut (his R7-S rule, #362 11-04 04:59Z): as many lines as it needs
                        Text(t.title).font(.system(size: 10.5)).multilineTextAlignment(.center)
                            .lineLimit(Self.controlOneLineTitle ? 1 : nil)
                            .fixedSize(horizontal: false, vertical: !Self.controlOneLineTitle)
                            .background(DSParts.publish("\(key)-\(t.id)-title"))   // (#362: a whole name is checked by its frame)
                    }
                    .foregroundStyle((t.id == selected ? DS.Color.textPrimary : DS.Color.textSecondary).color)
                    .padding(.vertical, 8).padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, minHeight: DSParts.target)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(t.id == selected ? DS.Color.fillSelected.color : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(DSParts.publish("\(key)-\(t.id)"))
                .accessibilityAddTraits(t.id == selected ? .isSelected : [])
                .accessibilityIdentifier("\(key)-\(t.id)")
            }
            if let add {
                Button(action: add) {
                    VStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                        Text("New").font(.system(size: 10.5))
                    }
                    .foregroundStyle(DS.Color.accent.color)
                    .frame(maxWidth: .infinity, minHeight: DSParts.target).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(DSParts.publish("\(key)-new"))
                .accessibilityIdentifier("\(key)-new")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10).padding(.horizontal, 6)
        .frame(width: DSParts.tabsWidth)
        .overlay(alignment: .trailing) { Rectangle().fill(DSParts.strokeSub.color).frame(width: 1) }
    }
}

// MARK: - §4.22 Legend

/// One card per data view (Stress, Heat), under the view row: its title, "Tap to read" (then "Tap the part to read"), the ramp
/// with its two ends, and (Heat) a selector "1 │ 2 │ All". Frames: "<key>", "<key>Read".
public struct DSLegend<Selector: View>: View {
    let title: String
    let low: String
    let high: String
    let ramp: [Color]
    let reading: Bool
    let key: String
    let toggleReading: (() -> Void)?
    let selector: Selector
    public init(_ title: String, low: String, high: String, ramp: [Color], reading: Bool = false, key: String,
                toggleReading: (() -> Void)? = nil, @ViewBuilder selector: () -> Selector) {
        self.title = title; self.low = low; self.high = high; self.ramp = ramp; self.reading = reading; self.key = key
        self.toggleReading = toggleReading; self.selector = selector()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(DS.Color.textPrimary.color)
                Spacer(minLength: 8)
                if let toggleReading {
                    Button(action: toggleReading) {
                        Text(reading ? "Tap the part to read" : "Tap to read").font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(DS.Color.accent.color)
                            .frame(minHeight: DSParts.target).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(DSParts.publish(key + "Read"))
                    .accessibilityIdentifier(key + "-read")
                }
            }
            HStack(spacing: 8) {
                Text(low)
                Capsule().fill(LinearGradient(colors: ramp, startPoint: .leading, endPoint: .trailing)).frame(height: 6)
                Text(high)
            }
            .font(.system(size: 12)).foregroundStyle(DS.Color.textSecondary.color)
            selector
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(width: DSParts.legendWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DS.Surface.bar.color))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
        .background(DSParts.publish(key))
    }
}

extension DSLegend where Selector == EmptyView {
    public init(_ title: String, low: String, high: String, ramp: [Color], reading: Bool = false, key: String,
                toggleReading: (() -> Void)? = nil) {
        self.init(title, low: low, high: high, ramp: ramp, reading: reading, key: key, toggleReading: toggleReading,
                  selector: { EmptyView() })
    }
}

extension DSLegend {
    /// The stress ramp (the mockup's: blue → cyan → green → yellow → red).
    public static var stressRamp: [Color] {
        [RGBA(hex: 0x2340FF), RGBA(hex: 0x19C3FF), RGBA(hex: 0x33E07A), RGBA(hex: 0xFFE14A), RGBA(hex: 0xFF4B3A)].map(\.color)
    }
}
