// FlexibleSettingsRail — the Settings modal's FOLDER TABS on its left side (task
// 2026-09-29-flexible-screens, round 5 batch S8; his img 3: "The groups should be separate folders
// and not listed together. This will make it easier to organize. The folder tabs should be on the
// *left* side of the modal so enough groups can fit.").
//
// ★ THE RAIL, top to bottom: [Model] — the whole part's filament, feel, finish (and the More rows
// under them); one tab PER SQUEEZE GROUP — its colour, "Group N", its face count; [Rests] — the
// resting faces; [+] — a new group. It scrolls, so any number of groups fits.
// ★ BESIDE IT, the open tab: a group's name and colour (four swatches — S1), its ONE squeeze force
// in a number box with its unit (S3 / S4), a group that will squish less than drawn in one warning
// line, then ITS faces — one row each; a tap opens that face's values in place (the round-4 card,
// FlexibleFaceRows). A face tapped on the MODEL opens its own group's tab (the rail follows the
// selection); the face selected is the group the page's squish plays (S2).
// ★ ONE LINE PER SETTING; the (i) explains. Nothing here can block Exit.

import SwiftUI
import TopOptDesign
import TopOptKit

/// One folder tab on the rail.
public enum FlexibleRailTab: Hashable, Sendable {
    /// The whole part: filament, feel, finish, and the More rows.
    case model
    /// A squeeze group, by its STORED number.
    case group(Int)
    /// The resting faces.
    case rests
    /// A new group (pick the face that starts it).
    case newGroup
}

// MARK: - the model's side (the rail follows the selection; the selection follows the rail)

extension FlexibleStageModel {

    /// The tab a face lives on: its group's (pressed), Rests (resting); a face not set yet stays on
    /// the group or Rests tab open (its card offers [Press it] / [It rests here] there).
    public func railTab(for region: Int?) -> FlexibleRailTab {
        guard let r = region else { return validRail }
        if let f = settings.face(r) {
            if f.isLoaded, let g = squeezeGroup(of: r) { return .group(g.id) }
            if !f.isLoaded { return .rests }
        }
        switch rail {
        case .group(let id) where squeezeGroups.contains(where: { $0.id == id }): return rail
        case .rests: return rail
        default: return .group(squeezeGroups.first?.id ?? FlexibleSqueezeGroups.first)
        }
    }

    /// The open tab, or — its group gone (its last face deleted, the group removed) — the first group's.
    var validRail: FlexibleRailTab {
        if case .group(let id) = rail, railGroup(id) == nil { return .group(squeezeGroups.first?.id ?? FlexibleSqueezeGroups.first) }
        if rail == .rests, !settings.faces.contains(where: { !$0.isLoaded }) { return .group(squeezeGroups.first?.id ?? FlexibleSqueezeGroups.first) }
        return rail
    }

    /// ★ After every edit: the rail follows the selected face to the group it is in NOW (a move, a new
    /// group, a merge, [Pressed] on a resting face) — the tab open, the face selected and the group
    /// that plays can never disagree. The [Model] and [+] tabs stay put.
    func syncRail() {
        if rail == .model || rail == .newGroup { return }
        let t = railTab(for: selectedRegion)
        if t != rail { rail = t }
    }

    /// The group the tab `.group(id)` shows — nil when that group is gone (the rail falls back).
    public func railGroup(_ id: Int) -> FlexibleSqueezeGroup? { squeezeGroups.first { $0.id == id } }

    /// ★ S2: the group the Settings page's squish plays — the selected pressed face's; else the group
    /// whose tab is open; else the first.
    public var playingGroup: FlexibleSqueezeGroup? {
        if let r = selectedRegion, let g = squeezeGroup(of: r) { return g }
        if case .group(let id) = rail, let g = railGroup(id) { return g }
        return squeezeGroups.first
    }

    func selectionChanged() {
        guard let r = selectedRegion else { return }
        let t = railTab(for: r)
        if t != rail { rail = t }
    }

    func railChanged() {
        let t: Tab = rail == .model ? .more : .face
        if tab != t { tab = t }
        switch rail {
        case .group(let id):
            // the group's tab: its face is the one selected (its curves on the part, its squish)
            guard let g = railGroup(id) else { return }
            if let r = selectedRegion, g.regions.contains(r) || settings.face(r) == nil { return }
            if let first = g.regions.first { select(first) }
        case .rests:
            if let r = selectedRegion, settings.face(r)?.isLoaded == false || settings.face(r) == nil { return }
            if let first = settings.faces.first(where: { !$0.isLoaded }) { select(first.faceRegionID) }
        case .model, .newGroup:
            break
        }
    }

    func tabChanged() {
        if tab == .more, rail != .model { rail = .model }
        if tab == .face, rail == .model { rail = railTab(for: selectedRegion).orGroup(self) }
    }

    /// The faces a new group can start from: pressed faces whose group holds a face outside their
    /// hand (the rule of + New — a main-page Load group's faces move together).
    public var newGroupCandidates: [Int] {
        settings.loadedFaces.map(\.faceRegionID).filter { r in
            let hand = Set(hand(of: r))
            return squeezeGroup(of: r)?.regions.contains { !hand.contains($0) } == true
        }
    }

    /// ★ S VERIFICATION: the [+ New] tab's rows — ONE per hand (a main-page Load group's faces move
    /// together: "Top A + Top B → Group 3"; two rows had each moved both).
    public var newGroupHands: [[Int]] {
        let cands = newGroupCandidates, inList = Set(cands)
        var seen = Set<Int>(), out: [[Int]] = []
        for r in cands where !seen.contains(r) {
            let h = hand(of: r).filter { inList.contains($0) }
            let one = h.contains(r) ? h : [r]
            one.forEach { seen.insert($0) }
            out.append(one)
        }
        return out
    }

    /// [+] → a face: a NEW group from it (and its hand); its tab opens.
    public func startGroup(with region: Int) {
        guard newGroup(with: region) != nil else { return }
        if let g = squeezeGroup(of: region) { rail = .group(g.id) }
        selectedRegion = region
    }

    /// [Press it] on a group's tab: the face joins THAT group (a main-page face comes with its hand).
    @discardableResult
    public func press(_ region: Int, kg: Double? = nil, into groupID: Int?) -> Bool {
        guard press(region, kg: kg) else { return false }
        if let id = groupID, railGroup(id) != nil, squeezeGroup(of: region)?.id != id { moveToGroup(region, id) }
        return true
    }

    /// ★ S3: the selected curve point's squish (mm) typed or scrubbed — its stored y = mm ÷ deepest,
    /// through core's own check (a refused curve is not applied).
    public func setCurvePoint(_ p: FlexCurvePoint, mm: Double) {
        guard let f = settings.face(p.region), f.deepestMM > 0 else { return }
        var c = p.axis == "y" ? f.curveY : f.curveX
        guard p.index >= 0, p.index < c.y.count else { return }
        c.y[p.index] = max(0, min(1, mm / f.deepestMM))
        guard FlexibleCore.penCurveError(x: c.x, y: c.y).isEmpty else { return }
        edit({ s in
            guard var g = s.face(p.region) else { return }
            if p.axis == "y" { g.curveY = c } else { g.curveX = c }
            s.setFace(g)
        }, recompute: false)
        curveChanged(region: p.region)
        save()
    }
}

private extension FlexibleRailTab {
    @MainActor func orGroup(_ m: FlexibleStageModel) -> FlexibleRailTab {
        self == .model ? .group(m.squeezeGroups.first?.id ?? FlexibleSqueezeGroups.first) : self
    }
}

// MARK: - the rail

struct FlexibleSettingsRailView: View {
    @ObservedObject var model: FlexibleStageModel

    static let width: CGFloat = 72
    static func tabID(_ t: FlexibleRailTab) -> String {
        switch t {
        case .model: return "flexible-rail-model"
        case .group(let id): return "flexible-rail-group-\(id)"
        case .rests: return "flexible-rail-rests"
        case .newGroup: return "flexible-rail-new"
        }
    }

    /// The rail's tabs, in order (a value: the tests read the page's own list).
    struct Tab: Identifiable, Equatable {
        let tab: FlexibleRailTab
        let title: String
        let detail: String?
        var id: String { FlexibleSettingsRailView.tabID(tab) }
    }

    @MainActor
    static func tabs(model: FlexibleStageModel) -> [Tab] {
        var out = [Tab(tab: .model, title: FlexibleRowCopy.railModel, detail: nil)]
        for g in model.squeezeGroups {
            out.append(Tab(tab: .group(g.id), title: FlexibleRowCopy.groupName(g.number),
                           detail: FlexibleRowCopy.faceCount(g.regions.count)))
        }
        let rests = model.settings.faces.filter { !$0.isLoaded }.count
        if rests > 0 { out.append(Tab(tab: .rests, title: FlexibleRowCopy.railRests, detail: FlexibleRowCopy.faceCount(rests))) }
        if !model.settings.loadedFaces.isEmpty { out.append(Tab(tab: .newGroup, title: FlexibleRowCopy.railNew, detail: nil)) }
        return out
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(Self.tabs(model: model)) { t in tab(t) }
            }
            .padding(.vertical, 2)
        }
        .frame(width: Self.width)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["rail": g.frame(in: .global)])
        }.allowsHitTesting(false))
    }

    private func tab(_ t: Tab) -> some View {
        let on = model.rail == t.tab
        return Button { withAnimation(.easeInOut(duration: 0.15)) { model.rail = t.tab } } label: {
            VStack(spacing: 3) {
                icon(t.tab)
                Text(t.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle((on ? DS.Color.textPrimary : DS.Color.textSecondary).color)
                    .lineLimit(1).minimumScaleFactor(0.8)
                if let d = t.detail {
                    Text(d).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DS.Color.textTertiary.color)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .frame(width: Self.width - 4)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((on ? DS.Color.fillSelected : DS.Color.fillSubtle).color))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent(t.tab).color.opacity(on ? 1 : 0.35), lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: [t.id: g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityLabel([t.title, t.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(t.id)
    }

    private func accent(_ t: FlexibleRailTab) -> RGBA {
        switch t {
        case .group(let id): return model.railGroup(id).map { model.groupColour($0) } ?? DS.Color.strokeStrong
        case .rests: return DS.Color.accentCyan
        default: return DS.Color.strokeStrong
        }
    }

    @ViewBuilder private func icon(_ t: FlexibleRailTab) -> some View {
        switch t {
        case .model:
            Image(systemName: "cube").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
        case .group(let id):
            // ★ C5: a colour another group also wears (past the eighth group) — the tab's dot carries
            // the number, the same disc as on the group's faces
            if let g = model.railGroup(id), let n = FlexibleGroupNumbers.railNumber(g, in: model.settings) {
                FlexibleGroupNumberDisc(colour: model.groupColour(g), number: n, size: FlexibleGroupNumbers.railSize)
                    .accessibilityIdentifier("flexible-rail-number-\(n)")
            } else {
                Circle().fill((model.railGroup(id).map { model.groupColour($0) } ?? DS.Color.accentGreen).color)
                    .frame(width: 14, height: 14)
            }
        case .rests:
            Circle().fill(DS.Color.accentCyan.color).frame(width: 14, height: 14)
        case .newGroup:
            Image(systemName: "plus").font(.system(size: 14, weight: .bold)).foregroundStyle(DS.Color.accent.color)
        }
    }
}

// MARK: - the open tab

struct FlexibleRailContent: View {
    @ObservedObject var model: FlexibleStageModel
    @Binding var padTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            switch model.rail {
            case .model:
                FlexibleModelTab(model: model)
            case .group(let id):
                if let g = model.railGroup(id) {
                    FlexibleGroupTab(model: model, group: g, padTarget: $padTarget)
                } else {
                    FlexibleNoGroupTab(model: model, padTarget: $padTarget)
                }
            case .rests:
                FlexibleRestsTab(model: model, padTarget: $padTarget)
            case .newGroup:
                FlexibleNewGroupTab(model: model)
            }
        }
        .onAppear {
            if model.selectedRegion == nil { model.selectedRegion = model.settings.loadedFaces.first?.faceRegionID }
        }
    }
}

/// [Model]: the whole part — filament, feel, finish — then the More rows (nozzle, lattice, Auto,
/// physics), every one with a working default.
struct FlexibleModelTab: View {
    @ObservedObject var model: FlexibleStageModel
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            FlexibleModelRows(model: model)
            Divider().overlay(DS.Color.strokeSubtle.color).padding(.vertical, DS.Space.xs)
            FlexSectionTitle(text: FlexibleRowCopy.moreTitle)
            FlexibleMorePanel(model: model)
        }
    }
}

/// A group's tab: its name, colour, force, miss — then its faces (the selected one open in place).
struct FlexibleGroupTab: View {
    @ObservedObject var model: FlexibleStageModel
    let group: FlexibleSqueezeGroup
    @Binding var padTarget: String?

    var body: some View {
        let row = FlexibleSqueezeGroupRows.rows(model: model).first { $0.id == group.id }
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            FlexibleGroupTabHeader(model: model, group: group, row: row, padTarget: $padTarget)
            Divider().overlay(DS.Color.strokeSubtle.color).padding(.vertical, DS.Space.xxs)
            FlexibleFaceList(model: model, padTarget: $padTarget, only: group.regions, joinGroup: group.id)
        }
    }
}

/// The group's own rows: "Group 2" [× (i)], "Squeeze" [10 kg ▾], "Colour" ● ● ● ●, its miss.
struct FlexibleGroupTabHeader: View {
    @ObservedObject var model: FlexibleStageModel
    let group: FlexibleSqueezeGroup
    let row: FlexibleSqueezeGroupRows.Row?
    @Binding var padTarget: String?

    var body: some View {
        let unit = model.weightUnit
        let kg = row?.kg ?? 0
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(spacing: DS.Space.s) {
                Circle().fill(model.groupColour(group).color).frame(width: 12, height: 12)
                Text(FlexibleRowCopy.groupName(group.number))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(1)
                    // the name's own frame (the hosted test measures it against the words)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["groupLine-\(group.number)": g.frame(in: .global)])
                    }.allowsHitTesting(false))
                    .accessibilityIdentifier("flexible-group-\(group.number)-line")
                Spacer(minLength: DS.Space.xs)
                if row?.removable == true {
                    Button { model.removeGroup(group.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.Color.textTertiary.color)
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["groupRemove-\(group.number)": g.frame(in: .global)])
                    }.allowsHitTesting(false))
                    .accessibilityLabel("Remove \(FlexibleRowCopy.groupName(group.number))")
                    .accessibilityIdentifier("flexible-group-remove-\(group.number)")
                }
                FlexInfoButton(title: FlexibleRowCopy.groupName(group.number), text: FlexibleRowCopy.Info.groups,
                               id: "flexible-group-\(group.number)-info")
            }
            .frame(minHeight: 36)
            FlexRow(FlexibleRowCopy.squeezeRow, info: FlexibleRowCopy.Info.squeeze,
                    id: "flexible-row-squeeze") {
                FlexNumberBox(key: "group-\(group.id)",
                              title: FlexibleRowCopy.groupName(group.number) + " · squeeze",
                              spec: FlexibleNumberSpecs.weight(kg: kg, unit: unit),
                              padTarget: $padTarget, units: FlexibleWeightUnit.allCases,
                              onUnit: { model.setWeightUnit($0) }, onNote: { model.toast = $0 }) { v in
                    model.setGroupForce(group.id, kg: unit.toKg(v))
                }
            }
            FlexRow(FlexibleRowCopy.colourRow, info: FlexibleRowCopy.Info.colour, id: "flexible-row-colour") {
                FlexibleColourSwatches(model: model, group: group)
            }
            if let miss = row?.miss { FlexWarningLine(text: miss, id: "flexible-group-\(group.number)-miss") }
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["groupRow-\(group.number)": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-group-\(group.number)")
    }
}

/// ★ S1: the colours, the group's own ringed; a tap picks (a colour another group wears swaps).
/// ★ C5: EIGHT (his "Add more colour tokens") on the same one line — 26 pt each (the 20 pt dot and
/// its ring), 3 pt apart; the hosted test measures the row inside the tab at every iPad size.
struct FlexibleColourSwatches: View {
    @ObservedObject var model: FlexibleStageModel
    let group: FlexibleSqueezeGroup
    static let swatch = CGSize(width: 26, height: 32)
    static let spacing: CGFloat = 3
    var body: some View {
        let mine = FlexibleSqueezeGroups.colourChoice(of: group, in: model.settings)
        HStack(spacing: Self.spacing) {
            ForEach(FlexibleGroupColour.allCases) { c in
                Button { model.setGroupColour(group.id, c) } label: {
                    Circle().fill(c.rgba.color).frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(DS.Color.textPrimary.color, lineWidth: c == mine ? 2 : 0).padding(-3))
                        .frame(width: Self.swatch.width, height: Self.swatch.height).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(c.name)
                .accessibilityAddTraits(c == mine ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("flexible-colour-\(group.number)-\(c.rawValue)")
            }
        }
        // the row's drawn frame (the hosted test: eight swatches, one line, inside the tab)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["colourSwatches-\(group.number)": g.frame(in: .global)])
        }.allowsHitTesting(false))
    }
}

/// A group tab whose group is gone (its last face was deleted): the list of every face set.
struct FlexibleNoGroupTab: View {
    @ObservedObject var model: FlexibleStageModel
    @Binding var padTarget: String?
    var body: some View {
        FlexibleFaceList(model: model, padTarget: $padTarget, only: nil, joinGroup: nil)
    }
}

/// [Rests]: the resting faces (a tap opens one; its card turns it back to Pressed or deletes it).
struct FlexibleRestsTab: View {
    @ObservedObject var model: FlexibleStageModel
    @Binding var padTarget: String?
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                Circle().fill(DS.Color.accentCyan.color).frame(width: 12, height: 12)
                Text(FlexibleRowCopy.railRests).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                Spacer()
                FlexInfoButton(title: FlexibleRowCopy.railRests, text: FlexibleRowCopy.Info.face, id: "flexible-rests-info")
            }
            .frame(minHeight: 36)
            FlexibleFaceList(model: model, padTarget: $padTarget,
                             only: model.settings.faces.filter { !$0.isLoaded }.map(\.faceRegionID), joinGroup: nil)
        }
    }
}

/// [+]: pick the face that starts the new group.
struct FlexibleNewGroupTab: View {
    @ObservedObject var model: FlexibleStageModel
    var body: some View {
        let next = model.squeezeGroups.count + 1
        let candidates = model.newGroupHands
        VStack(alignment: .leading, spacing: 6) {
            Text(FlexibleRowCopy.newGroupTitle(next))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                .frame(minHeight: 36)
            Text(candidates.isEmpty ? FlexibleRowCopy.newGroupNone : FlexibleRowCopy.newGroupPick)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Color.textSecondary.color)
                .lineLimit(1).minimumScaleFactor(0.85)
                .accessibilityIdentifier("flexible-new-group-line")
            ForEach(candidates, id: \.self) { hand in
                let r = hand[0]
                Button { model.startGroup(with: r) } label: {
                    HStack(spacing: DS.Space.s) {
                        Circle().fill((model.squeezeGroup(of: r).map { model.groupColour($0) } ?? DS.Color.accentGreen).color)
                            .frame(width: 10, height: 10)
                        Text(FlexibleRowCopy.newGroupRow(names: hand.map { model.faceName($0) }, number: next))
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(DS.Color.textPrimary.color)
                            .lineLimit(1).minimumScaleFactor(0.85)
                        Spacer(minLength: DS.Space.xs)
                        Image(systemName: "plus.circle.fill").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DS.Color.accent.color)
                    }
                    .padding(.horizontal, DS.Space.m)
                    .frame(minHeight: FlexibleFaceList.rowHeight)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Color.fillSubtle.color))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flexible-new-group-\(r)")
            }
        }
    }
}

/// ★ S3: each number field's rules in one place (the tests read them).
enum FlexibleNumberSpecs {
    /// A weight (a group's force), in the page's unit: the main page's own limits (ForceModel —
    /// 0.1 … 500 kgf: its `setWeight` clamps to them, so a Load group can hold nothing else).
    /// ★ S VERIFICATION: a weight under 1 (in the unit shown) keeps two decimals ("0.05 kg", not
    /// "0.1"), and a typed value outside the limits is clamped and SAID (FlexNumberSpec.typedNote).
    static func weight(kg: Double, unit: FlexibleWeightUnit) -> FlexNumberSpec {
        let v = unit.fromKg(kg)
        return FlexNumberSpec(value: v, unit: unit.label, step: unit.step,
                              range: unit.fromKg(ForceModel.minWeightKg)...unit.fromKg(ForceModel.maxWeightKg),
                              decimals: v > 0 && v < 1 ? max(unit.decimals, 2) : unit.decimals)
    }
    /// The deepest squish: 0.5 mm steps (the depth chip's snap), up to the lattice's depth.
    static func deepest(mm: Double, latticeMM: Double?) -> FlexNumberSpec {
        let hi = max(0.5, latticeMM ?? 100)
        return FlexNumberSpec(value: mm, unit: "mm", step: 0.5, range: 0.1...hi, decimals: 1)
    }
    /// A stamp's width: whole mm steps, up to the face's longer side. ★ S VERIFICATION: a stored
    /// 65.5 mm shows "65.5" (it read "66"); the drag still steps whole mm.
    static func stampWidth(mm: Double, faceMM: Double?) -> FlexNumberSpec {
        FlexNumberSpec(value: mm, unit: "mm", step: 1, range: 1...max(1, faceMM ?? 500), decimals: wholeOrTenth(mm))
    }
    /// ★ S VERIFICATION: the stamp's LENGTH, its own box (the line had said "Width · 20 mm long"
    /// beside the width's box) — typing it scales the width by the stamp's own proportions.
    static func stampLength(mm: Double, faceMM: Double?) -> FlexNumberSpec {
        FlexNumberSpec(value: mm, unit: "mm", step: 1, range: 1...max(1, faceMM ?? 500), decimals: wholeOrTenth(mm))
    }
    /// 0 decimals for a whole number, 1 for a tenth.
    static func wholeOrTenth(_ v: Double) -> Int { abs(v - v.rounded()) < 0.05 ? 0 : 1 }
    /// A stamp's turn: 15° steps, round the circle.
    static func stampTurn(deg: Double) -> FlexNumberSpec {
        FlexNumberSpec(value: deg, unit: "°", step: 15, range: 0...360, decimals: 0, wraps: true)
    }
    /// A curve point's squish (mm), 0 … the face's deepest squish.
    static func curvePoint(mm: Double, deepestMM: Double) -> FlexNumberSpec {
        FlexNumberSpec(value: mm, unit: "mm", step: 0.1, range: 0...max(0.1, deepestMM), decimals: 1)
    }
}
