// FlexibleGroupNames — every squeeze group's NAME, tapped to rename, and its TRASH (task 2026-09-29-flexible-screens,
// round 7 batch S, 4d; his img3 words of 2026-10-14: "All groups should have a trash icon next to them and their names
// should be editable by tapping "group 1" or whatever the default name is.").
//
// ★ THE NAME. "Group 2" until he taps it: then ONE line, a text field (16 characters at most), the keyboard up; Return or
// leaving it keeps what he typed; clearing it (or typing its default back) is "Group 2" again. Stored per group by its
// STORED number (FlexibleStageSettings.groupNames), DISPLAY ONLY like the colour — never the lattice's key — and carried to
// the group's new number when an earlier group goes (FlexibleSqueezeGroups.normalise). The Settings page reads it
// everywhere it names a squeeze group (the rail's tab, the tab's header, the face list's header, a face's group menu, the
// player's picker, the grey "In Group 4" line, a group's miss line); the main page's Selections never do (the two lists stay
// separate, his 2026-10-10 reversal).
// ★ THE TRASH. On EVERY group's header — the only group's too (the × showed only with two or more) — 44 pt, SF "trash".
// It DELETES the group, as the word says (the × merged its faces into another group): its faces leave the Flexible setup
// by removeFace's rule (a face a main-page group holds is remembered as deleted, so the re-sync never brings it back), an
// edges group gives its strips back to their faces (removeStripPresses), then the groups renumber. ONE undo step. The last
// group gone leaves [Model] and [+ New] (and [Rests] while a face rests), as Reset all does.

import SwiftUI
import TopOptDesign
import TopOptKit

extension FlexibleStageModel {

    /// The longest name he can give a group.
    public static let groupNameMax = 16

    /// The name group `g` shows on the Settings page: his, else "Group N".
    public func groupName(_ g: FlexibleSqueezeGroup) -> String {
        settings.groupNames?[String(g.id)] ?? FlexibleRowCopy.groupName(g.number)
    }

    /// The name of the group SHOWN as `number` (the player's sims are numbered).
    public func groupName(number: Int) -> String {
        squeezeGroups.first { $0.number == number }.map { groupName($0) } ?? FlexibleRowCopy.groupName(number)
    }

    /// His name for group `groupID` (stored id): trimmed, 16 characters at most; empty (or its default) clears it.
    /// Display only: the designs are not re-run and the lattice stays current.
    public func setGroupName(_ groupID: Int, _ name: String) {
        guard let g = squeezeGroups.first(where: { $0.id == groupID }) else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.groupNameMax))
        edit({ s in
            var n = s.groupNames ?? [:]
            if trimmed.isEmpty || trimmed == FlexibleRowCopy.groupName(g.number) { n[String(groupID)] = nil } else { n[String(groupID)] = trimmed }
            s.groupNames = n.isEmpty ? nil : n
        }, recompute: false)
    }

    /// ★ 4d: the trash — group `groupID` is DELETED with what it holds (see the file comment). One undo step.
    public func deleteGroup(_ groupID: Int) {
        guard let g = squeezeGroups.first(where: { $0.id == groupID }) else { return }
        // an edges/corners group: its presses go, each strip back to its face (ONE undo step, changeStrips)
        if g.kind == .edges {
            track(Task { @MainActor [weak self] in _ = await self?.removeStripPresses(g.presses) })
            return
        }
        let loads = mainPageLoads
        project.sealUndoStep()   // the edits before it are their own step
        actionSerial += 1
        edit { s in
            for r in g.regions {
                s.removeFace(r)
                if !loads.canRemove(r), !s.isRemoved(r) { s.removedRegions = (s.removedRegions ?? []) + [r] }
            }
            // a tilted face press of the group goes too (AP1's trash rule for its members)
            for id in g.presses {
                guard let p = s.press(id) else { continue }
                s.removePress(id)
                let still = s.pressRegions
                for r in p.regions where !loads.canRemove(r) && s.face(r) == nil && !still.contains(r) && !s.isRemoved(r) {
                    s.removedRegions = (s.removedRegions ?? []) + [r]
                }
            }
            FlexibleSqueezeGroups.normalise(&s)
        }
        for r in g.regions { purgeFaceCaches(r) }
        if let id = selectedPress, settings.press(id) == nil { selectedPress = nil }
        if let r = selectedRegion, settings.face(r) == nil, g.regions.contains(r) { selectedRegion = Self.appearSelection(self) }
        save()   // one undo step
    }
}

extension FlexibleSqueezeGroups {
    /// ★ RED CONTROL: a name is not carried to the group's new number when groups renumber.
    nonisolated(unsafe) static var controlNoNameRemap = false

    /// Carry each group's name to its new number (`rank`: old stored id → new number); a group that no longer exists drops
    /// its name. nil when nothing is left.
    static func remapNames(_ names: [String: String]?, rank: [Int: Int]) -> [String: String]? {
        guard let names, !names.isEmpty else { return names }
        if controlNoNameRemap { return names }
        var out: [String: String] = [:]
        for (k, v) in names {
            guard let old = Int(k), let n = rank[old] else { continue }
            out[String(n)] = v
        }
        return out.isEmpty ? nil : out
    }
}

extension FlexibleSqueezeGroupRows {
    /// ★ RED CONTROL: today's rule — the × only with two or more groups (the only group has none).
    @MainActor static var controlRemovableOnlyWithTwo = false
}

extension FlexibleStageModel {
    /// ★ RED CONTROL (verify of R7-S): a rename (or a colour) publishes nothing — the rail's tab kept "Group N".
    @MainActor static var controlNameEditPublishesNothing = false
}

// MARK: - the name, tapped to rename

/// A group's name on its header: the name (a tap opens ONE line of text, 16 characters at most); Return or leaving the
/// field keeps it; empty is "Group N" again.
struct FlexibleGroupNameField: View {
    /// ★ RED CONTROL (verify of R7-S): today's field — it stays open when the header shows another group, and commits to
    /// whichever group the header shows then.
    @MainActor static var controlCommitsToTheHeadersGroup = false

    @ObservedObject var model: FlexibleStageModel
    let group: FlexibleSqueezeGroup
    var size: CGFloat = 15
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    /// The field had the keyboard once (leaving it then keeps the name; a field that never got focus stays open).
    @State private var hadFocus = false

    var body: some View {
        let name = model.groupName(group)
        Group {
            if editing {
                TextField(FlexibleRowCopy.groupName(group.number), text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: size, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(1)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { commit() }
                    .onChange(of: draft) { v in if v.count > FlexibleStageModel.groupNameMax { draft = String(v.prefix(FlexibleStageModel.groupNameMax)) } }
                    .onChange(of: focused) { f in if f { hadFocus = true } else if hadFocus { commit() } }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Color.fillSubtle.color))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.Color.accent.color, lineWidth: 1))
                    .frame(maxWidth: 190, alignment: .leading)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["groupNameField-\(group.number)": g.frame(in: .global)])
                    }.allowsHitTesting(false))
                    .accessibilityIdentifier("flexible-group-\(group.number)-name-field")
                    .onAppear { focused = true }
            } else {
                Button { draft = model.settings.groupNames?[String(group.id)] ?? ""; hadFocus = false; editing = true } label: {
                    Text(name)
                        .font(.system(size: size, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(name), rename")
                // the name's own frame (the hosted test measures it against the words)
                .background(GeometryReader { g in
                    Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["groupLine-\(group.number)": g.frame(in: .global)])
                }.allowsHitTesting(false))
                .accessibilityIdentifier("flexible-group-\(group.number)-line")
            }
        }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        model.setGroupName(group.id, draft)
    }
}

/// ★ 4d: the trash on a group's header — 44 pt, always there; it deletes the group (one undo step).
struct FlexibleGroupTrashButton: View {
    @ObservedObject var model: FlexibleStageModel
    let groupID: Int
    let number: Int
    let name: String

    var body: some View {
        Button { model.removeGroup(groupID) } label: {
            Image(systemName: "trash").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.Color.textTertiary.color)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["groupRemove-\(number)": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityLabel("Delete \(name)")
        .accessibilityIdentifier("flexible-group-remove-\(number)")
    }
}
