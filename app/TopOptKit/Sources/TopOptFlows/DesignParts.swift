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
    /// §4.4: a selected row's highlight — its outline's corner radius and its inset from the row's edges.
    public static let rowHighlightRadius: CGFloat = 10
    public static let rowHighlightInset: CGFloat = 4
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
    static var moreFill: RGBA { DS.Color.accent.opacity(0.06) }   // ★ B5 (Q12): the accent is live, so read it as it draws

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
    /// Folded, the pill is only as wide as its header (Results on a small iPad, his note 2026-10-27).
    var foldedPill = false
    /// The count in words, in a colour, instead of a number (Results' Checks: "2 to look at" / "All good").
    var countLabel: (text: String, tint: RGBA)? = nil
    /// ★ notes27 F3: its corner radius while open (nil: §4.3's 22 pt) — Results' list is concentric with its rows' highlight.
    var openRadius: CGFloat? = nil
    /// The empty state's one line ("Tap a face to start"), shown when `isEmpty`.
    let empty: String?
    let isEmpty: Bool
    @Binding var open: Bool
    let content: Content
    let footer: Footer

    @State private var rows: [String: CGRect] = [:]
    /// ★ his 11-22 (img 44): folded where Topology and Selections are minimised together — the Selections pill's size and colour.
    @Environment(\.minimisedPillWidth) private var pairedPillWidth
    /// ★ his 11-22 (img 45): opened from the corner (the Settings drawer) — the ⌃ menu's colour, no blur behind it.
    @Environment(\.cornerDrawerLook) private var drawerLook
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
                maxHeight: CGFloat? = nil, empty: String? = nil, isEmpty: Bool = false, foldedPill: Bool = false, open: Binding<Bool>,
                @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.key = key; self.title = title; self.count = count; self.viewOnly = viewOnly; self.width = width
        self.maxHeight = maxHeight; self.empty = empty; self.isEmpty = isEmpty; self.foldedPill = foldedPill; self._open = open
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
                        // U10 "nothing hidden below a fold": a row cut by the fold counts too (T3: Settings' Material showed its
                        // top 18 pt and no cue)
                        let below = rows.filter { $0.value.maxY > shown + 4 }.sorted { $0.value.minY < $1.value.minY }
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
        .frame(width: pill ?? (!open && foldedPill ? nil : width))
        .fixedSize(horizontal: !open && foldedPill && pill == nil, vertical: true)   // the panel is as tall as what it holds (the body caps itself)
        .onPreferenceChange(DSPanelMeasureKey.self) { m in
            if let c = m["content"], abs(c - contentHeight) > 0.5 { contentHeight = c }
            if let v = m["viewport"], abs(v - viewport) > 0.5 { viewport = v }
            if let f = m["footer"], abs(f - footerHeight) > 0.5 { footerHeight = f }
        }
        .transformPreference(DSPanelMeasureKey.self) { $0 = [:] }   // (never an enclosing panel's)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill((drawerLook ? DS.Surface.menu : DS.Surface.panel).color))
        // the mockup's .panel blurs what is behind it (backdrop-filter 36 px): a chip on the model never reads through
        // ★ his 11-22 (img 44): the pill beside the Selections pill wears its colour — the glass with no blur behind it
        .background(pill == nil && !drawerLook ? AnyShapeStyle(Material.ultraThinMaterial) : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .dsShadow(DS.Shadow.panel)
        .background(DSParts.publish(key))
    }

    /// ★ his 11-22 (img 44): folded beside the minimised Selections pill — that pill's width, height and colour.
    private var pill: CGFloat? { open ? nil : pairedPillWidth }
    private var headerH: CGFloat { pill == nil ? DSParts.headerHeight : MinimisedPills.height }
    private var radius: CGFloat { open ? (openRadius ?? DSParts.panelRadius) : headerH / 2 }

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
                if let countLabel {
                    Text(countLabel.text).font(.system(size: 13, weight: .medium)).foregroundStyle(countLabel.tint.color)
                        .lineLimit(1).fixedSize()
                } else if let count {
                    Text("\(count)").font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: headerH)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(DSParts.publish(key + "Header"))
        .accessibilityLabel(open ? "Fold \(title)" : "\(title), \(count ?? 0). Open")
        .accessibilityIdentifier("\(key)-header")
    }
}

extension View {
    /// A row that is not a DSRow (a setting row) inside a DSPanel: its frame published under `key`, its place counted by the
    /// panel's "N more ⌄" cue, and the cue's scroll target.
    public func dsPanelRow(_ key: String) -> some View {
        id(key).background(GeometryReader { g in
            Color.clear
                .preference(key: ChromeKeepOutKey.self, value: [key: g.frame(in: .global)])
                .preference(key: DSPanelRowsKey.self, value: [key: g.frame(in: .named(DSParts.bodySpace))])
        })
    }
}

extension DSPanel where Footer == EmptyView {
    public init(key: String, title: String, count: Int? = nil, viewOnly: Bool = false, width: CGFloat = DSParts.panelWidth,
                maxHeight: CGFloat? = nil, empty: String? = nil, isEmpty: Bool = false, foldedPill: Bool = false, open: Binding<Bool>,
                @ViewBuilder content: () -> Content) {
        self.init(key: key, title: title, count: count, viewOnly: viewOnly, width: width, maxHeight: maxHeight, empty: empty,
                  isEmpty: isEmpty, foldedPill: foldedPill, open: open, content: content, footer: { EmptyView() })
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
    /// ★ his 11-22: a hold on the name renames it (nil: not renamable).
    let rename: ((String) -> Void)?
    let actions: Actions
    /// ★ his 11-22: the value column's width under a Selections panel (its handle); nil: the value whole, as before.
    @Environment(\.dsRowValueWidth) private var valueWidth
    /// ★ notes25 B3: the line under the row wraps to fit its words (Results' list); false: one line, as everywhere else.
    @Environment(\.dsRowLineWraps) private var lineWraps

    public init(_ kind: Kind, key: String, mark: DSRowMark? = nil, name: String, role: (glyph: String, colour: RGBA)? = nil,
                value: String? = nil, disclosure: Bool? = nil, selected: Bool = false, hidden: Bool = false,
                disabled: Bool = false, locked: Bool = false, tag: String? = nil, line: DSRowLine? = nil,
                tap: (() -> Void)? = nil, rename: ((String) -> Void)? = nil, @ViewBuilder actions: () -> Actions) {
        self.kind = kind; self.key = key; self.mark = mark; self.name = name; self.role = role; self.value = value
        self.disclosure = disclosure; self.selected = selected; self.hidden = hidden; self.disabled = disabled
        self.locked = locked; self.tag = tag; self.line = line; self.tap = tap; self.rename = rename; self.actions = actions()
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
                        if let w = valueWidth {   // ★ his 11-22: the column the panel's handle sets (the name takes the rest)
                            Text(value).font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color).lineLimit(1)
                                .truncationMode(.tail).frame(width: w, alignment: .trailing)
                        } else {
                            Text(value).font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color).lineLimit(1)
                                .fixedSize()
                        }
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
                    RoundedRectangle(cornerRadius: DSParts.rowHighlightRadius, style: .continuous)
                        .strokeBorder(DS.Color.accent.color, lineWidth: 1.5).padding(DSParts.rowHighlightInset)
                    RoundedRectangle(cornerRadius: 2).fill(DS.Color.accent.color).frame(width: 3).padding(.vertical, 6)
                }
                // ★ B6 N3: the highlight is drawn over the row's tap button (the next background) — a filled shape takes a
                // click, so without this a picked row could not be tapped again to close it
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(DSParts.strokeSub.color).frame(height: 1).allowsHitTesting(false) }   // R2.3: each row its line
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
        .modifier(RenameOnHold(name: name, key: key, rename: rename))   // ★ his 11-22: hold the name to rename it
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
                .lineLimit(lineWraps ? nil : 1)
                .fixedSize(horizontal: false, vertical: lineWraps)
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
                tap: (() -> Void)? = nil, rename: ((String) -> Void)? = nil) {
        self.init(kind, key: key, mark: mark, name: name, role: role, value: value, disclosure: disclosure, selected: selected,
                  hidden: hidden, disabled: disabled, locked: locked, tag: tag, line: line, tap: tap, rename: rename,
                  actions: { EmptyView() })
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
        .eyeSweep(key, hidden: hidden, toggle: toggle)   // ★ his iPad 11-07 (3b): press an eye and drag (EyeSweep)
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
    let progress: Progress?
    let action: () -> Void
    let fix: (() -> Void)?
    /// ★ notes30 (11-27): an (i) beside the button (where a blocked button's fix chip sits), for a line that needs its detail.
    let info: String?
    let infoTitle: String

    /// ★ His pick 11-21 (the preview-speed research): something the button waits on, said ON the button (never a line at the
    /// bottom): a ring that fills toward `expected` seconds (never quite closed before it ends; a spinner when nothing says
    /// how long) and its words with the time left. The button's title and tap stay its own.
    public struct Progress: Equatable {
        public var started: Date
        public var expected: TimeInterval?
        public var words: String
        public init(started: Date, expected: TimeInterval?, words: String) {
            self.started = started; self.expected = expected; self.words = words
        }
        /// How full the ring is at `now` (0 to 0.95); nil: a spinner.
        public func fraction(at now: Date) -> Double? {
            guard let e = expected, e > 0 else { return nil }
            return Swift.min(0.95, Swift.max(0, now.timeIntervalSince(started) / e))
        }
        /// The line at `now`: the words, then the time left ("12 s", "3 min", "finishing").
        public func line(at now: Date) -> String {
            guard let e = expected, e > 0 else { return words }
            return words + " \u{00B7} " + Self.left(e - now.timeIntervalSince(started))
        }
        public static func left(_ s: Double) -> String {
            s <= 1 ? "finishing" : s < 60 ? "\(Int(s.rounded(.up))) s" : "\(Int((s / 60).rounded(.up))) min"
        }
    }

    public init(_ title: String, subtitle: String, state: State = .ready, key: String, progress: Progress? = nil,
                info: String? = nil, infoTitle: String = "About this",
                action: @escaping () -> Void, fix: (() -> Void)? = nil) {
        self.title = title; self.subtitle = subtitle; self.state = state; self.key = key; self.progress = progress
        self.action = action; self.fix = fix; self.info = info; self.infoTitle = infoTitle
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
            if let info { InfoTip(key: key + "Info", text: info, label: infoTitle) }   // its own 44 pt target
            Button(action: action) {
                Group {
                    if let progress {   // ★ his pick 11-21: the ring and the count-down, once a second (this view only)
                        TimelineView(.periodic(from: progress.started, by: 1)) { ctx in
                            lines(ring: progress.fraction(at: ctx.date), spinner: progress.fraction(at: ctx.date) == nil,
                                  line: progress.line(at: ctx.date))
                        }
                    } else {
                        lines(ring: nil, spinner: busy, line: line2)
                    }
                }
                .foregroundStyle(grey ? DS.Color.textDisabled.color : Color.white)
                .fixedSize()   // its own size, max(250, the lines + 44), whatever the parent offers (DSRunLabelLayout)
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

    /// ★ his iPad notes 11-22 (img 44, img 47: "Laying Draft", "Draft · checking print"): "Please ensure that the text is always
    /// centred and the progress icon is to the left of the text, perfectly between the text and the left side of the button."
    /// The two lines sit in the button's centre with or without the ring (DSRunLabelLayout); the ring (or the small spinner)
    /// is centred in the gap between the capsule's left end and the wider line, and never widens the button.
    private func lines(ring: Double?, spinner: Bool, line: String) -> some View {
        DSRunLabelLayout(padding: Self.textInset, minWidth: DSParts.runMinWidth, minHeight: DSParts.runHeight) {
            VStack(spacing: 1) {
                Text(title).font(.system(size: 16, weight: .bold)).lineLimit(1).fixedSize()
                    .background(DSParts.publish("\(key)-title"))
                // never cut (the mockup's `.run small`: nowrap; min-width 250): the button grows to the line
                Text(line).font(.system(size: 11.5)).lineLimit(1).fixedSize()
                    .foregroundStyle(grey ? DS.Color.textTertiary.color : Color.white.opacity(0.85))
                    .background(DSParts.publish("\(key)-line2"))
            }
            .background(DSParts.publish("\(key)-text"))
            if let ring {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.3), lineWidth: 2.5)
                    Circle().trim(from: 0, to: ring).stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 18, height: 18)
                .background(DSParts.publish("\(key)-ring"))
            } else if spinner {
                ProgressView().controlSize(.small).tint(.white)
                    .background(DSParts.publish("\(key)-spinner"))
            }
        }
    }
    /// The lines' clearance from each end of the capsule (the mockup's padding 0 22).
    static let textInset: CGFloat = 22
    /// RED CONTROL (RunButtonCentredHostedTests): the ring in a row before the lines, the pair centred (before his 11-22 note).
    nonisolated(unsafe) public static var controlRingPushesText = false
}

/// ★ his 11-22: the run button's label — its first subview (the two lines) in the centre, sized max(`minWidth`, lines +
/// 2 × `padding`) by `minHeight`; any other subview (the ring, the spinner) centred halfway between the left end and the lines.
/// The ring never counts toward the size, so the button keeps its width when the ring comes or goes.
struct DSRunLabelLayout: Layout {
    let padding: CGFloat
    let minWidth: CGFloat
    let minHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return CGSize(width: minWidth, height: minHeight) }
        let t = text.sizeThatFits(.unspecified)
        return CGSize(width: Swift.max(minWidth, t.width + 2 * padding), height: Swift.max(minHeight, t.height))
    }

    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let text = subviews.first else { return }
        let t = text.sizeThatFits(.unspecified)
        let gap = (b.width - t.width) / 2   // from the capsule's left end to the lines
        let old = DSRunButton.controlRingPushesText && subviews.count > 1
        let ringSizes = subviews.dropFirst().map { $0.sizeThatFits(.unspecified) }
        let shift = old ? ((ringSizes.first?.width ?? 0) + 10) / 2 : 0   // (the old HStack: ring + 10 pt + lines, centred)
        text.place(at: CGPoint(x: b.midX + shift, y: b.midY), anchor: .center, proposal: ProposedViewSize(t))
        for (ring, s) in zip(subviews.dropFirst(), ringSizes) {
            let x = old ? b.midX + shift - t.width / 2 - 10 - s.width / 2 : b.minX + gap / 2
            ring.place(at: CGPoint(x: x, y: b.midY), anchor: .center, proposal: ProposedViewSize(s))
        }
    }
}

/// The ⌃ beside the run button: a 64 pt square opening the other run choices — a menu, or a plain button (#362: Flexible's ⌃
/// opens the lattice card panel).
public struct DSSplitButton<Items: View>: View {
    let key: String
    let items: Items
    var action: (() -> Void)?
    /// ★ his 11-22 (img 45): the ⌃ that opens its own drawer (CornerMoreDrawer) — lit while the drawer is up.
    var open = false
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
            .rotationEffect(.degrees(open ? 180 : 0))   // ★ 11-22: up, the drawer's ⌃ points down (a tap shuts it)
            .frame(width: DSParts.runHeight, height: DSParts.runHeight)
            .background(RoundedRectangle(cornerRadius: DSParts.runHeight / 2, style: .continuous)
                .fill((open ? DS.Color.fillSelected : DS.Surface.bar).color))
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
    /// ★ his iPad notes 11-22 (img 45): the ⌃ of a corner drawer — `toggle` opens or shuts it (CornerDrawers), `open` lights
    /// it. The drawer is the page's to draw (above the buttons, where Settings opens).
    public init(key: String, open: Bool, toggle: @escaping () -> Void) {
        self.key = key; self.items = EmptyView(); self.action = toggle; self.open = open
    }
}

/// The secondary button: 48 pt glass, label + optional glyph ("Settings ⌄", "Compare", "Add part"), and an optional tertiary
/// detail after the label (the mockup's "Settings  Fast · +Z · −Z ⌄"; frame "<key>-detail"). `accent`: the same button filled
/// in the accent with its glow (the Library's "Open v8 draft", "+ Add part").
public struct DSGlassButton: View {
    let title: String
    let detail: String?
    let systemImage: String?
    let chevron: Bool
    var selected = false
    var accent = false
    let key: String
    let action: () -> Void
    public init(_ title: String, detail: String? = nil, systemImage: String? = nil, chevron: Bool = false, selected: Bool = false,
                accent: Bool = false, key: String, action: @escaping () -> Void) {
        self.title = title; self.detail = detail; self.systemImage = systemImage; self.chevron = chevron; self.selected = selected
        self.accent = accent; self.key = key; self.action = action
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
            .foregroundStyle(accent ? Color.white : DS.Color.textPrimary.color)
            .padding(.horizontal, 16).frame(height: DSParts.glassHeight)
            .background(Capsule().fill((accent ? DS.Color.accent : selected ? DS.Color.fillSelected : DS.Surface.bar).color))
            .overlay(Capsule().strokeBorder(DS.Color.strokePanel.opacity(accent ? 0 : 1).color, lineWidth: 1))
            .partsShadow(accent ? DS.Shadow.accentGlow : nil)
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
    /// ★ his iPad notes 11-23: the column's width (the Lattice page widens it to its names: LatticePageColumns).
    var width: CGFloat = DSParts.tabsWidth
    public init(_ tabs: [Tab], selected: String?, key: String, pick: @escaping (String) -> Void, add: (() -> Void)? = nil,
                width: CGFloat = DSParts.tabsWidth) {
        self.tabs = tabs; self.selected = selected; self.key = key; self.pick = pick; self.add = add; self.width = width
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
        .frame(width: width)
        .background(DSParts.publish("\(key)-column"))   // ★ 11-23: the column (the hosted tests')
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
