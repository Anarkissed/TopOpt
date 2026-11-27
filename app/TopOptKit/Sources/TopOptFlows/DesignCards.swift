// DesignCards.swift — design-system §4.7's CARDS (approved design 2026-11-02; the reviewer's ruling 11-04 02:56Z adds Card to
// the shared parts). Sizes and colours are the mockup's (mockup.html: .card, .card .pic, .card .meta, .card.ring, .card.add,
// .vstrip, .vcard, .tcard) through the DS tokens.
//
//   DSPartCard     a part in a project folder: its picture (the chosen result, else the original model — note 10), its name and
//                  line, a version strip; the accent ring + "v7b" tag once a result is chosen (note 11); a running version's
//                  spinning chip over an unchanged picture; "Rejected" as a tag.
//   DSAddTile      the dashed "+ Add part" tile (the empty state).
//   DSVersionCard  a version in a part folder: its header (name, changes line), its content (the 10-25 card's results) — a
//                  branch sits 48 pt in.
//   DSResultRow    a result in the Results panel: "a · Just safe · 87 g · 1.5×" and Pick this (Picked ✓ once chosen).
//   DSTypeCard     a lattice type: its picture, name, a 3–5 word line, an (i); one ready type = a label card (no selection).
//
// Frames: each card publishes "<key>"; its parts "<key>-…".

import SwiftUI
import TopOptDesign

public enum DSCards {
    public static let radius: CGFloat = 24
    public static let pictureHeight: CGFloat = 200
    public static let addMinHeight: CGFloat = 270
    public static let versionRadius: CGFloat = 20
    public static let branchIndent: CGFloat = 48
    static let fill = DS.Color.textPrimary.opacity(0.045)
    static let pictureGradient = RadialGradient(colors: [RGBA(hex: 0x121A2A).color, RGBA(hex: 0x08090C).color],
                                                center: UnitPoint(x: 0.5, y: 0.6), startRadius: 0, endRadius: 260)
}

/// One version chip in a part card's strip ("v7", the chosen one in accent; `printed`: a result marked Print this).
public struct DSVersionChip: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let on: Bool
    public let draft: Bool
    public let printed: Bool
    public init(id: String, title: String, on: Bool = false, draft: Bool = false, printed: Bool = false) {
        self.id = id; self.title = title; self.on = on; self.draft = draft; self.printed = printed
    }
}

/// A part card. `chosenTag` (e.g. "v7b") rings it in accent; `running` shows a spinning chip over the unchanged picture.
public struct DSPartCard<Picture: View>: View {
    let key: String
    let name: String
    let line: String
    let chosenTag: String?
    let running: String?
    let rejected: Bool
    let versions: [DSVersionChip]
    let picture: Picture
    let open: () -> Void

    public init(key: String, name: String, line: String, chosenTag: String? = nil, running: String? = nil,
                rejected: Bool = false, versions: [DSVersionChip] = [], open: @escaping () -> Void,
                @ViewBuilder picture: () -> Picture) {
        self.key = key; self.name = name; self.line = line; self.chosenTag = chosenTag; self.running = running
        self.rejected = rejected; self.versions = versions; self.open = open; self.picture = picture()
    }

    public var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    DSCards.pictureGradient
                    picture.frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 6) {
                        if let chosenTag { DSChip(.accentTag(chosenTag), key: key + "-chosen") }
                        if rejected { DSChip(.tag("Rejected"), key: key + "-rejected") }
                        Spacer(minLength: 0)
                        if let running {
                            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(running) }
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.accent.color)
                                .padding(.horizontal, 8).frame(height: 26)
                                .background(Capsule().fill(DS.Color.accent.opacity(0.14).color))
                                .background(DSParts.publish(key + "-running"))
                        }
                    }
                    .padding(12)
                }
                .frame(height: DSCards.pictureHeight)
                .clipped()
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).font(.system(size: 14.5, weight: .bold)).foregroundStyle(DS.Color.textPrimary.color).lineLimit(1)
                    Text(line).font(.system(size: 12)).foregroundStyle(DS.Color.textTertiary.color).lineLimit(1)
                    if !versions.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(versions) { v in
                                HStack(spacing: 2) {
                                    Text(v.title)
                                    if v.printed { Image(systemName: "printer").foregroundStyle(DS.Color.okGreen.color).accessibilityLabel("Print this") }
                                }
                                .font(.system(size: 11))
                                    // mockup .vstrip: grey, the chosen one in accent ("v8 draft" says draft in words)
                                    .foregroundStyle((v.on ? DS.Color.accent : DS.Color.textSecondary).color)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill((v.on ? DS.Color.accent.opacity(0.15) : DS.Color.fillSubtle).color))
                            }
                        }
                        .background(DSParts.publish(key + "-versions"))
                    }
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: DSCards.radius, style: .continuous).fill(DSCards.fill.color))
            .overlay(RoundedRectangle(cornerRadius: DSCards.radius, style: .continuous)
                .strokeBorder(chosenTag == nil ? DS.Color.strokePanel.color : DS.Color.accent.color,
                              lineWidth: chosenTag == nil ? 1 : 2))
            .clipShape(RoundedRectangle(cornerRadius: DSCards.radius, style: .continuous))
            .shadow(color: chosenTag == nil ? .clear : DS.Color.accent.opacity(0.35).color, radius: 12)
            .contentShape(RoundedRectangle(cornerRadius: DSCards.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(DSParts.publish(key))
        .accessibilityIdentifier(key)
    }
}

/// The empty state: the dashed "+ Add part" tile.
public struct DSAddTile: View {
    let title: String
    let detail: String?
    let key: String
    let action: () -> Void
    public init(_ title: String, detail: String? = nil, key: String, action: @escaping () -> Void) {
        self.title = title; self.detail = detail; self.key = key; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // the mockup's .plus: a 48 pt accent disc with its glow, 8 pt above the words
                Image(systemName: "plus").font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(DS.Color.accent.color).shadow(color: DS.Color.accent.opacity(0.35).color, radius: 12))
                    .padding(.bottom, 2)
                Text(title).font(.system(size: 14.5, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(DS.Color.textTertiary.color) }
            }
            .foregroundStyle(DS.Color.textSecondary.color)
            .frame(maxWidth: .infinity, minHeight: DSCards.addMinHeight)
            .background(RoundedRectangle(cornerRadius: DSCards.radius, style: .continuous).fill(DSCards.fill.color))   // .card's fill
            .overlay(RoundedRectangle(cornerRadius: DSCards.radius, style: .continuous)
                .strokeBorder(DS.Color.strokePanel.color, style: StrokeStyle(lineWidth: 1, dash: [6, 4])))
            .contentShape(RoundedRectangle(cornerRadius: DSCards.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(DSParts.publish(key))
        .accessibilityIdentifier(key)
    }
}

/// A version card (the approved 10-25 card): its header line and its content; a branch sits 48 pt in.
public struct DSVersionCard<Header: View, Content: View>: View {
    let key: String
    let branch: Bool
    let header: Header
    let content: Content
    public init(key: String, branch: Bool = false, @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.key = key; self.branch = branch; self.header = header(); self.content = content()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) { header }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DSCards.versionRadius, style: .continuous).fill(DSCards.fill.color))
        .overlay(RoundedRectangle(cornerRadius: DSCards.versionRadius, style: .continuous)
            .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
        .background(DSParts.publish(key))   // the card he sees: a branch's frame starts 48 pt in
        .padding(.leading, branch ? DSCards.branchIndent : 0)
    }
}

/// A result in the Results panel: "a · Just safe · 87 g · 1.5×", and on the selected one Pick this (Picked ✓ once chosen).
/// Frames: "<key>", "<key>-pick" / "<key>-picked".
public struct DSResultRow: View {
    let key: String
    let title: String
    let value: String
    let selected: Bool
    let picked: Bool
    let select: () -> Void
    let pick: (() -> Void)?
    public init(key: String, title: String, value: String, selected: Bool, picked: Bool, select: @escaping () -> Void,
                pick: (() -> Void)?) {
        self.key = key; self.title = title; self.value = value; self.selected = selected; self.picked = picked
        self.select = select; self.pick = pick
    }
    public var body: some View {
        DSRow(.group, key: key, name: title, value: value, selected: selected, tap: select) {
            if picked {
                Text("Picked \u{2713}").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Color.accent.color)
                    .frame(minHeight: DSParts.target)
                    .background(DSParts.publish(key + "-picked"))
            } else if selected, let pick {
                DSChip(.fix("Pick this"), key: key + "-pick", action: pick)
            }
        }
    }
}

/// A lattice type: picture, name, a 3–5 word line, an (i). With one ready type it is a label card (`label`: no selection).
public struct DSTypeCard<Picture: View>: View {
    let key: String
    let name: String
    let line: String
    let info: String?
    let selected: Bool
    let label: Bool
    let small: Bool
    let picture: Picture
    let choose: () -> Void
    public init(key: String, name: String, line: String, info: String? = nil, selected: Bool = false, label: Bool = false,
                small: Bool = false, choose: @escaping () -> Void, @ViewBuilder picture: () -> Picture) {
        self.key = key; self.name = name; self.line = line; self.info = info; self.selected = selected; self.label = label
        self.small = small; self.choose = choose; self.picture = picture()
    }
    public var body: some View {
        let body = HStack(spacing: 10) {
            picture
                .frame(width: small ? nil : 52, height: small ? 56 : 52)
                .frame(maxWidth: small ? .infinity : nil)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DSCards.pictureGradient))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 14, weight: .bold)).foregroundStyle(DS.Color.textPrimary.color)
                Text(line).font(.system(size: 12)).foregroundStyle(DS.Color.textTertiary.color).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let info { InfoTip(key: key + "-info", text: info, label: "About \(name)") }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill((selected && !label ? DS.Color.accent.opacity(0.10) : RGBA(0, 0, 0, 0.18)).color))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder((selected && !label ? DS.Color.accent : DS.Color.strokeSubtle).color, lineWidth: 1))
        return Group {
            if label {
                body
            } else {
                Button(action: choose) { body.contentShape(Rectangle()) }.buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .background(DSParts.publish(key))
        .accessibilityIdentifier(key)
    }
}
