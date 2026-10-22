// FlexibleFaceChip — the chip AT THE FACE on the main Flexible page (task 2026-09-29-flexible-screens, round 7, batch R7-D2:
// his mockup pick 2, B1 "on the face", with his three changes, 2026-10-14). The on-model layer (H32) places it, draws its
// leader and moves it when he drags it (FlexibleFaceChipLayout).
//
//   N — a NEW face (or faces): "Face 4 · new" ✕; when a group was picked earlier this session, his change (c): a FILLED
//       button "Add to Group C as lattice" (the DS accent, white semibold label, the group's swatch, 48 tall — it reads and
//       looks like a button, never an outlined title row: his image 2) with the depth it will take under it; then
//       "Or start a new group:" and five 64 × 56 buttons [▦ Lattice] [Anchor] [Load] [Protect] [Keep clear].
//       (★ HIS RULING 2026-10-18: [▦ Lattice] makes the group Lattice with Protect underneath — Topology never touches a
//       lattice — and the group reads "Lattice", the shield beside it; R7-D2's greyed button and its route line are gone.
//       The join is offered only for a group that already has a lattice face — the review of R7-D2.)
//   M — a face of a group: swatch, the name (tap to rename), the role capsule (a Load shows its weight, set on the Squish
//       page), the trash (it CONFIRMS — his answer), ✕; then "Face 3", its (i) (his change b), and the segment
//       [▦ Lattice | ■ Solid | ⬚ Off]. No grams (his answer: hidden until core reports the real per-face lattice weight).
//   G — the whole group: "All N" and the segment (nothing lit and "mixed" when the faces disagree).
//   B — Keep clear blocks lattice: one line and [▦ Lattice instead].
//   L — locked on Topology: one line and [Unlock].
// His change (a): the whole chip outside its buttons is a drag handle (the grip on top says so) — the layer moves it.

import SwiftUI
import TopOptDesign

struct FlexibleFaceChip: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var project: ProjectModel
    @ObservedObject var ui: FlexibleFaceChipState
    let scope: FlexibleFaceScope
    let cardsChanged: () -> Void
    /// ★ U21 batch I (I2): no clear spot for the card with its Attach row (the mini in portrait) — [🔗] sits on the title line
    /// instead (one 44 pt icon with the link count), so the card keeps chip M's height.
    var attachCompact = false

    static let protectTint = RGBA(hex: 0x2EE0C7)
    static let segmentWidth: CGFloat = 80

    /// A Load group's weight, read-only — set on the Squish page. ★ the review of R7-D2: in the FLEXIBLE stage's unit (his
    /// lb — the player's "11 lb each" and the Squish page's boxes), not Topology's kg; a Load the chip made this session whose
    /// weight is still the one it was made with reads "weight: Squish page" (the mockup's words — his answer: the weight is
    /// set later on the Squish page), not the force's 2.5 kg default.
    @MainActor
    static func loadWeight(_ p: ProjectModel, _ g: UUID, ui: FlexibleFaceChipState?) -> String? {
        guard let kg = p.force.kind(for: g).weightKg else { return nil }
        if let made = ui?.unweighed[g], abs(made - kg) < 1e-9 { return FlexibleSelectionsCopy.weightUnset }
        return FlexibleWeightUnit(stored: p.lattice.flexible?.weightUnit).text(kg: kg)
    }

    /// The chip's kind (its placement height).
    @MainActor
    static func kind(_ scope: FlexibleFaceScope, project p: ProjectModel, lastGroup: UUID?,
                     main: FlexibleMainStage? = nil, attachCompact: Bool = false) -> FlexibleFaceChipLayout.Kind {
        switch scope {
        case .pending: return .new(join: FlexibleFaceCommits.canJoin(lastGroup, p))
        case let .face(g, _), let .group(g):
            if FlexibleFaceCommits.isLocked(g, p) { return .locked }
            if FlexibleFaceCommits.blockedByKeepClear(g, p) { return .blocked }
            if case .group = scope { return .group }
            // ★ U21 batch I (I2): the step card, or chip M with its Attach rows
            if let m = main, case let .face(_, ref) = scope {
                if m.attach.active, m.attach.lattice == ref.key, !FlexibleAttach.controlAttachUsesMemberSize {
                    let n = m.attach.wall != nil ? 1 : (m.attachWalls(p, key: ref.key)?.walls.count ?? 1)
                    return .attach(chipLines: n > 4 ? 2 : 1, say: m.attach.say != nil)
                }
                if !m.attach.active, !attachCompact {
                    let rows = m.attachRow(p, group: g, ref: ref).rows
                    if rows > 0 { return .memberAttach(rows: rows) }
                }
            }
            return .member
        case .none: return .member
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Capsule().fill(DS.Color.textTertiary.color).frame(width: 36, height: 4)
                .frame(maxWidth: .infinity).padding(.top, -4)
                .accessibilityHidden(true)
            switch scope {
            case let .pending(faces): newFace(faces)
            case let .face(g, ref):
                // ★ U21 batch I (I2): the card turns into the Attach step card in place (same spot)
                if main.attach.active, main.attach.lattice == ref.key { FlexibleAttachStepCard(main: main, project: project) }
                else { member(g, ref: ref) }
            case let .group(g): member(g, ref: nil)
            case .none: EmptyView()
            }
        }
        .padding(FlexibleFaceChipLayout.padding)
        .frame(width: FlexibleFaceChipLayout.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: FlexibleFaceChipLayout.radius, style: .continuous)
            .fill(DS.Color.chipSolid.color.opacity(0.94))
            .overlay(RoundedRectangle(cornerRadius: FlexibleFaceChipLayout.radius, style: .continuous)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-face-chip")
    }

    // MARK: N — a new face

    @ViewBuilder private func newFace(_ faces: [FlexibleFreeFace]) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(FlexibleFacePick.pendingTitle(faces, project: project))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color).lineLimit(1)
                .accessibilityIdentifier("flexible-chip-title")
            Spacer(minLength: DS.Space.xs)
            closeButton
        }
        .frame(minHeight: 32)
        if let gid = main.facePick.lastGroup, FlexibleFaceCommits.canJoin(gid, project), let g = FlexibleFaceCommits.group(gid, project) {
            let v = FlexibleFaceCommits.joinValues(gid, project, session: main.facePick)
            FlexibleJoinButton(group: g, note: FlexibleSelectionsCopy.joinNote(depthMM: v.depth, like: v.like, also: FlexibleFaceCommits.joinAlso(gid, project))) {
                main.commitJoin(project: project, cardsChanged: cardsChanged)
            }
            Text(FlexibleSelectionsCopy.orNew).font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Color.textTertiary.color)
        }
        HStack(spacing: DS.Space.s) {
            ForEach(FlexibleNewFaceKind.allCases, id: \.self) { k in
                FlexibleNewFaceButton(kind: k) {
                    main.commitNew(k, project: project, cardsChanged: cardsChanged)
                }
            }
        }
    }

    // MARK: M / G — a face of a group, or the whole group

    @ViewBuilder private func member(_ gid: UUID, ref: LatticeSelectableRef?) -> some View {
        if let g = FlexibleFaceCommits.group(gid, project) {
            if ui.roleOpen == gid { roleLine(g) } else { titleLine(g, ref: ref) }
            if ui.deleteAsk == gid, ui.deleteAskInChip {
                // ★ U21: one line in the face line's place — the chip keeps its size, so [Cancel] stays where its trash was
                FlexibleDeleteConfirm(name: g.name, delete: { main.confirmDelete(project: project, cardsChanged: cardsChanged) },
                                      oneLine: !FlexibleConfirmInPlace.controlOldPlacement)
                    .frame(minHeight: 44)
            } else if ui.keepClearAsk == gid {
                askLine(FlexibleSelectionsCopy.keepClearAsk, yes: FlexibleSelectionsCopy.keepClear, id: "flexible-chip-keepclear-ask") {
                    ui.keepClearAsk = nil
                    FlexibleFaceCommits.confirmKeepClear(group: gid, project: project)
                    cardsChanged()
                }
            } else if FlexibleFaceCommits.isLocked(gid, project) {
                actionLine(FlexibleSelectionsCopy.locked, button: FlexibleSelectionsCopy.unlock, symbol: "lock.open", id: "flexible-chip-unlock") {
                    project.groupView.toggleLocked(gid)
                }
            } else if FlexibleFaceCommits.blockedByKeepClear(gid, project) {
                actionLine(FlexibleSelectionsCopy.keepClearBlocks, button: FlexibleSelectionsCopy.latticeInstead,
                           symbol: "square.grid.3x3.fill", id: "flexible-chip-lattice-instead") {
                    FlexibleFaceCommits.latticeInstead(group: gid, project: project)
                    cardsChanged()
                }
            } else if ui.roleOpen == gid, ui.protectLockSaid == gid {
                // ★ R7-E1 (his answer 2026-10-18 ~15:50): why [Protect] stays on — one line, where the face line was
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "lock.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(Self.protectTint.color)
                    Text(FlexibleSelectionsCopy.protectLocked).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .background(publish("chipProtectLocked"))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("flexible-chip-protect-locked")
            } else if let ref {
                faceLine(g, ref)
                if !attachCompact { FlexibleAttachRows(main: main, project: project, group: g.id, ref: ref) }   // ★ U21 batch I (I2)
            } else {
                allLine(g)
            }
        }
    }

    private func titleLine(_ g: SelectionGroup, ref: LatticeSelectableRef? = nil) -> some View {
        HStack(spacing: DS.Space.s) {
            RoundedRectangle(cornerRadius: 3).fill(g.color.color).frame(width: 14, height: 14)
            if ui.renaming == g.id {
                TextField("Group name", text: $ui.renameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    .frame(maxWidth: 150)
                    .onSubmit {
                        FlexibleFaceCommits.rename(g.id, to: ui.renameDraft, project: project)
                        ui.renaming = nil
                    }
                    .accessibilityIdentifier("flexible-chip-rename")
            } else {
                Button {
                    ui.renameDraft = g.name
                    ui.renaming = g.id
                } label: {
                    Text(g.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                        .lineLimit(1).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rename \(g.name)")
                .accessibilityIdentifier("flexible-chip-name")
            }
            roleCapsule(g)
            Spacer(minLength: DS.Space.xs)
            if attachCompact, let ref { FlexibleAttachIconButton(main: main, project: project, group: g.id, ref: ref) }   // ★ I2
            if !FlexibleFaceCommits.isLocked(g.id, project) {
                Button { main.askDelete(g.id, inChip: true) } label: {
                    Image(systemName: "trash").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DS.Color.textSecondary.color)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // ★ U21 (DEL-CONFIRM, his Img13): [Cancel] takes the trash's place; the question and [Delete] go under it
                .modifier(FlexibleCancelInPlace(asking: ui.deleteAsk == g.id && ui.deleteAskInChip, keepKey: "deleteCancel",
                                                cancel: { ui.deleteAsk = nil }))
                .background(publish("chipTrash"))
                .accessibilityLabel("Delete \(g.name), here and in Topology")
                .accessibilityIdentifier("flexible-chip-trash")
            }
            closeButton
        }
        .frame(minHeight: 44)
    }

    /// What the role capsule reads for a group: its word, its glyph, its tint, and a shield beside it (★ his ruling 2026-10-18:
    /// a protected group with a Lattice face reads "Lattice" — the shield says Topology never touches it).
    struct RoleReading: Equatable {
        let word: String
        let symbol: String
        let tint: RGBA
        let shield: Bool
    }

    @MainActor
    static func roleReading(_ project: ProjectModel, _ g: UUID, ui: FlexibleFaceChipState?) -> RoleReading {
        let k = project.force.kind(for: g)
        if k.isLoad {
            // ★ the review of R7-D2: an unset weight reads as the list does — "↓ weight: Squish page" (with "Load" in front it was
            // cut to "Load weight: Squish p…")
            let w = loadWeight(project, g, ui: ui)
            return RoleReading(word: w == FlexibleSelectionsCopy.weightUnset ? (w ?? "Load") : "Load" + (w.map { " " + $0 } ?? ""),
                               symbol: "arrow.down", tint: DS.Color.accent, shield: false)
        } else if k.isAnchor { return RoleReading(word: "Anchor", symbol: "lock.fill", tint: DS.Color.okGreen, shield: false)
        } else if project.force.keepClearAffix(for: g) == .on { return RoleReading(word: "Keep clear", symbol: "nosign", tint: DS.Color.clearance, shield: false)
        } else if FlexibleFaceCommits.readsLattice(g, project) {
            return RoleReading(word: FlexibleSelectionsCopy.kindWord(.lattice), symbol: "square.grid.3x3.fill", tint: FlexibleStageStyle.facePrismToken, shield: true)
        } else if project.force.isProtected(g) { return RoleReading(word: "Protect", symbol: "shield.lefthalf.filled", tint: protectTint, shield: false)
        }
        return RoleReading(word: FlexibleSelectionsCopy.setRole, symbol: "plus", tint: DS.Color.textSecondary, shield: false)
    }

    private func roleCapsule(_ g: SelectionGroup) -> some View {
        let k = project.force.kind(for: g.id)
        let reading = Self.roleReading(project, g.id, ui: ui)
        let word = reading.word, symbol = reading.symbol, tint = reading.tint
        return Button {
            ui.info = nil
            ui.roleOpen = ui.roleOpen == g.id ? nil : g.id
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(tint.color)
                Text(word).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color).lineLimit(1)
                if reading.shield {
                    Image(systemName: "shield.lefthalf.filled").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Self.protectTint.color)
                }
            }
            .padding(.horizontal, DS.Space.s).frame(height: 28)
            .background(Capsule().fill(tint.opacity(0.18).color))
            .frame(height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(publish("chipRole"))
        .accessibilityLabel(k.isLoad ? "\(word), \(FlexibleSelectionsCopy.weightOnSquish). Tap to change the role"
                            : reading.shield ? "\(word), protected from Topology. Tap to change the role" : "\(word). Tap to change the role")
        .accessibilityIdentifier("flexible-chip-role")
    }

    /// The role line (the capsule opened): Anchor and Load exclusive, Protect and Keep clear toggle. ★ R7-E1 (his answer
    /// 2026-10-18 ~15:50): on a Lattice group [Protect] wears a lock and a tap on it says "Protect stays on while a face is
    /// Lattice" (on the line under it) — nothing is written.
    private func roleLine(_ g: SelectionGroup) -> some View {
        let k = project.force.kind(for: g.id)
        let lit: [FlexibleGroupRoleButton: Bool] = [.anchor: k.isAnchor, .load: k.isLoad, .protect: project.force.isProtected(g.id),
                                                    .keepClear: project.force.keepClearAffix(for: g.id) == .on]
        let locked = FlexibleFaceCommits.protectLocked(g.id, project)
        return HStack(spacing: DS.Space.s) {
            ForEach(FlexibleGroupRoleButton.allCases, id: \.self) { b in
                let kind = FlexibleNewFaceKind(rawValue: b.rawValue) ?? .anchor
                FlexibleNewFaceButton(kind: kind, lit: lit[b] ?? false, locked: b == .protect && locked) {
                    let wasLoad = project.force.kind(for: g.id).isLoad, hadWeight = project.force.kind(for: g.id).weightKg != nil
                    switch FlexibleFaceCommits.setRole(b, group: g.id, project: project) {
                    case .asksFirst: ui.roleOpen = nil; ui.keepClearAsk = g.id
                    case .done:
                        ui.roleOpen = nil
                        // a Load made here with no weight of its own yet: "weight: Squish page" until it is set there
                        if b == .load, !wasLoad, !hadWeight, let kg = project.force.kind(for: g.id).weightKg { ui.unweighed[g.id] = kg }
                        cardsChanged()
                    case .refused: ui.roleOpen = nil
                    case .locked: ui.protectLockSaid = g.id   // ★ R7-E1: the line under the role line says why
                    }
                }
                .background(publish("chipRole-\(b.rawValue)"))
                .accessibilityLabel(b == .protect && locked ? "Protect, locked on while a face is Lattice" : FlexibleSelectionsCopy.kindWord(kind))
            }
            Spacer(minLength: 0)
            closeButton
        }
    }

    private func faceLine(_ g: SelectionGroup, _ ref: LatticeSelectableRef) -> some View {
        let role = project.latticeSelectableRole(ref, in: g.id)
        return HStack(spacing: DS.Space.s) {
            Text(project.latticeSelectableName(ref)).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1)
            if role != nil { FlexibleInfoButton(main: main, key: "c-" + ref.key, group: g.id, ref: ref) }
            Spacer(minLength: 0)
            segment(current: role.map(LatticeSelectableRole.init) ?? .off, mixed: false) { r in
                FlexibleFaceCommits.setState(r, ref: ref, group: g.id, project: project)
                cardsChanged()
            }
        }
        .frame(minHeight: 44)
    }

    private func allLine(_ g: SelectionGroup) -> some View {
        let roles = Set(project.latticeSelectableRefs(g).map { project.latticeSelectableRole($0, in: g.id).map(LatticeSelectableRole.init) ?? .off })
        let one = roles.count == 1 ? roles.first : nil
        return HStack(spacing: DS.Space.s) {
            Text(FlexibleSelectionsCopy.allFaces(project.latticeSelectableRefs(g).count)).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color)
            if one == nil {
                Text(FlexibleSelectionsCopy.mixed).font(.system(size: 12)).foregroundStyle(DS.Color.textTertiary.color)
                    .accessibilityIdentifier("flexible-chip-mixed")
            }
            Spacer(minLength: 0)
            segment(current: one, mixed: one == nil) { r in
                FlexibleFaceCommits.setAll(r, group: g.id, project: project)
                cardsChanged()
            }
        }
        .frame(minHeight: 44)
    }

    /// [▦ Lattice | ■ Solid | ⬚ Off]: 3 × 80, 36 tall, in a 44 pt target.
    private func segment(current: LatticeSelectableRole?, mixed: Bool, set: @escaping (LatticeSelectableRole) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach([LatticeSelectableRole.include, .exclude, .off], id: \.self) { r in
                let on = !mixed && current == r
                Button { set(r) } label: {
                    HStack(spacing: 4) {
                        FlexibleStateGlyph(role: r.regionRole)
                        Text(r == .include ? "Lattice" : r == .exclude ? "Solid" : "Off")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle((on ? DS.Color.textPrimary : DS.Color.textSecondary).color)
                    }
                    .frame(width: Self.segmentWidth, height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? DS.Color.fillSelected.color : Color.clear))
                    .frame(height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel((r == .include ? "Lattice" : r == .exclude ? "Solid" : "Off") + (on ? ", selected" : ""))
                .accessibilityIdentifier("flexible-chip-seg-\(r.rawValue)")
                .background(publish("chipSeg-\(r.rawValue)"))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(DS.Color.fillSubtle.color))
    }

    private func actionLine(_ text: String, button: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(text).font(.system(size: 13.5, weight: .medium)).foregroundStyle(DS.Color.warning.color).lineLimit(1)
            Spacer(minLength: DS.Space.xs)
            Button(action: action) {
                HStack(spacing: 4) {
                    Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                    Text(button).font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(DS.Color.textPrimary.color)
                .padding(.horizontal, DS.Space.m).frame(height: 36)
                .background(Capsule().fill(DS.Color.fillSelected.color)
                    .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
                .frame(height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
        }
    }

    private func askLine(_ text: String, yes: String, id: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(text).font(.system(size: 13.5, weight: .medium)).foregroundStyle(DS.Color.textPrimary.color).lineLimit(1)
            Spacer(minLength: DS.Space.xs)
            Button { ui.keepClearAsk = nil } label: {
                Text(FlexibleSelectionsCopy.cancel).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
                    .padding(.horizontal, DS.Space.s).frame(height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: action) {
                Text(yes).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, DS.Space.m).frame(height: 36)
                    .background(Capsule().fill(DS.Color.clearance.color))
                    .frame(height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
        }
    }

    private var closeButton: some View {
        Button { main.missTap() } label: {
            Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                .foregroundStyle(DS.Color.textSecondary.color)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -6).padding(.trailing, -8)
        .accessibilityLabel("Close. Nothing is created")
        .accessibilityIdentifier("flexible-chip-close")
    }

    private func publish(_ key: String) -> some View {
        GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: [key: g.frame(in: .global)]) }
            .allowsHitTesting(false)
    }
}

/// His change (c): "Add to Group C as lattice" — a FILLED button (the DS accent, white semibold label, the group's swatch
/// with a white ring, 48 tall, radius 14, the accent glow, 85 % when pressed, the button trait), the depth it takes under it.
struct FlexibleJoinButton: View {
    let group: SelectionGroup
    let note: String
    let action: () -> Void
    static let height: CGFloat = 48
    static let fill = DS.Color.accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "plus.circle.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                // ★ the review of R7-D2: a blue group's swatch vanished on the blue fill — a dark ring inside the white one
                Circle().fill(group.color.color).frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.45), lineWidth: 3))
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(FlexibleSelectionsCopy.joinLabel(group.name))
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        .accessibilityIdentifier("flexible-chip-join-label")
                    Text(note).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.white.opacity(0.82)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.m)
            .frame(maxWidth: .infinity, minHeight: Self.height)
        }
        .buttonStyle(FlexibleJoinButtonStyle())
        .background(GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["chipJoin": g.frame(in: .global)]) }
            .allowsHitTesting(false))
        .accessibilityLabel(FlexibleSelectionsCopy.joinLabel(group.name))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("flexible-chip-join")
    }
}

struct FlexibleJoinButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(FlexibleJoinButton.fill.color))
            .dsShadow(DS.Shadow.accentGlow)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// One of chip N's five buttons (and the role line's four): an 18 pt glyph over an 11.5 pt bold word, 64 × 56.
struct FlexibleNewFaceButton: View {
    let kind: FlexibleNewFaceKind
    var lit: Bool = false
    /// ★ R7-E1: Protect locked on (a Lattice group) — a small lock in its corner.
    var locked: Bool = false
    let action: () -> Void
    static let size = CGSize(width: 64, height: 56)

    static func style(_ k: FlexibleNewFaceKind) -> (symbol: String, tint: RGBA, fill: Double) {
        switch k {
        case .lattice: return ("square.grid.3x3.fill", FlexibleStageStyle.facePrismToken, 0)
        case .anchor: return ("lock.fill", DS.Color.okGreen, 0.20)
        case .load: return ("arrow.down", DS.Color.accent, 0.18)
        case .protect: return ("shield.lefthalf.filled", FlexibleFaceChip.protectTint, 0.16)
        case .keepClear: return ("nosign", DS.Color.clearance, 0.16)
        }
    }

    var body: some View {
        let s = Self.style(kind)
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: s.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(s.tint.color)
                Text(FlexibleSelectionsCopy.kindWord(kind)).font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(s.fill > 0 ? s.tint.opacity(s.fill).color : DS.Color.fillSubtle.color)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder((lit ? s.tint : RGBA(0, 0, 0, 0)).color, lineWidth: 2)))
            .overlay(alignment: .topTrailing) {
                if locked {
                    // ★ R7-E1: Protect locked on while a face of the group is Lattice
                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(s.tint.color)
                        .padding(5)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["chipRole-\(kind.rawValue)-lock": g.frame(in: .global)])
                        }.allowsHitTesting(false))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["chipNew-\(kind.rawValue)": g.frame(in: .global)]) }
            .allowsHitTesting(false))
        .accessibilityLabel(FlexibleSelectionsCopy.kindWord(kind))
        .accessibilityIdentifier("flexible-chip-new-\(kind.rawValue)")
    }
}
