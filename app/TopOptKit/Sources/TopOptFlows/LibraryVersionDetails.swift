// LibraryVersionDetails.swift — ★ his iPad notes 2026-11-22 (img 1), his "yes" to decision 4:
//
//   "Tapping the 3 dots should allow you to open the "details" of it OR holding on the modal, having a menu come up and
//   pressing "details" should show the full details of the model."
//
// A version's full page (route `.details`), from its card's ⋯ › Details or a long press on the card: its picture, every
// result's numbers (weight, the share of the part as drawn, the strength margin and its verdict — print time is not known
// anywhere in the app: DECISIONS 2026-07-11 left it out), its stars and flags (Picked ×, Print ×, Rejected ×,
// In consideration ×, each taken off with a tap as on the card), where it came from (from v1, uploaded, edited) and every
// setting it was run with. It reuses the Library's own pieces (LibraryPicture, LibraryNumbers, LibraryStars,
// LibraryFlagChip). His help-text rule: every heading and label is at most 5 words. A picture's tap opens the version on
// its results, as on the card.
//
// Frames: "library-details-v<n>" (the page), "-back", "-open", "-picture", "-results", "-from", "-settings"; each result
// "library-details-v<n><letter>" (and "-picture", "-stars", "-picked", "-print", "-rejected", "-considering").

import SwiftUI
import TopOptDesign
import TopOptKit

/// What a version's Details page says, in plain words (never a face number: a group is his name for it or its face count).
enum LibraryVersionFacts {
    /// Where it came from: "From v1" / "First run" (a draft: "Edited from v1" / "Not run yet"), the model it brought
    /// ("Uploaded: bracket.stl"), then what changed from the version it came from.
    static func origin(_ v: LibraryVersion, snapshot s: ProjectSnapshot?, draft: Bool) -> [String] {
        var out: [String] = []
        if let p = v.parentNumber { out.append(draft ? "Edited from v\(p)" : "From v\(p)") } else { out.append(draft ? "Not run yet" : "First run") }
        if let m = s?.newModel { out.append("Uploaded: \(m.fileName)") }
        let changes = v.changes.map(\.text).filter { !$0.hasPrefix("New model:") }   // the upload is said above
        out += changes
        if changes.isEmpty, v.parentNumber != nil { out.append("Same settings") }
        return out
    }

    /// Every setting the version was run with, one (label, value) each.
    static func settings(_ s: ProjectSnapshot) -> [(String, String)] {
        var rows: [(String, String)] = []
        rows.append(("Goal", (s.minimizePlastic ?? true) ? "Minimize plastic" : "Strengthen"))
        let stage = LibraryStyle.stage(s).0
        let mode = s.lattice?.flexible == nil && s.lattice?.enabled == true ? s.lattice?.stageMode?.title : nil
        rows.append(("Type", mode.map { "\(stage) · \($0)" } ?? stage))
        rows.append(("Material", "\(s.material) · \(s.process.rawValue.uppercased())"))
        rows.append(("Resolution", "\((s.quality ?? .fast).resolution)"))
        let f = s.force
        for g in s.selection.groups {
            let name = label(g)
            switch f.kind(for: g.id) {
            case .anchor: rows.append(("Anchor", name))
            case let .load(direction, kg): rows.append(("Load", "\(name) · \(num(f.unit.fromKg(kg))) \(f.unit.label) · \(direction.title)"))
            default: break
            }
            if f.keepClearIsOn(g.id, autoDefault: false) { rows.append(("Keep clear", name)) }
            if f.isProtected(g.id) { rows.append(("Protect", name)) }
        }
        if s.selection.groups.contains(where: { f.isProtected($0.id) }) {
            rows.append(("Protect depth", "\(num(f.faceProtectDepthMM)) mm"))
        }
        if !(s.designBox ?? DesignBoxModel()).primitives.isEmpty { rows.append(("Allow growth", "On")) }
        if !(s.faceRegions ?? FaceRegionModel()).isEmpty { rows.append(("Faces", "Edited")) }
        let p = s.printParams ?? .fdmDefault
        rows.append(("Layer height", "\(num(p.layerHeightMM)) mm"))
        rows.append(("Walls", "\(p.wallLoops)"))
        rows.append(("Top · bottom", "\(p.topLayers) · \(p.bottomLayers) layers"))
        rows.append(("Infill", "\(p.infillPercent) % \(p.infillPattern)"))
        rows.append(("CAD faces", (s.projectCADFaces ?? true) ? "On" : "Off"))
        rows.append(("Saved", s.savedAt.formatted(date: .abbreviated, time: .shortened)))
        return rows
    }

    /// His name for a group, or how many faces it has (VersionChanges' rule). Auto names ("Group A") are not his.
    static func label(_ g: SelectionGroup) -> String {
        if g.name.range(of: #"^Group [A-Z]+$"#, options: .regularExpression) == nil,
           !g.name.trimmingCharacters(in: .whitespaces).isEmpty { return g.name }
        let n = g.faces.count + g.regionIDs.count
        return n == 1 ? "1 face" : "\(n) faces"
    }

    /// 51 → "51", 3.5 → "3.5", 0.2 → "0.2", 0.12 → "0.12".
    static func num(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        if abs(r - r.rounded()) < 1e-9 { return String(Int(r.rounded())) }
        return abs(r * 10 - (r * 10).rounded()) < 1e-9 ? String(format: "%.1f", r) : String(format: "%.2f", r)
    }
}

struct LibraryVersionDetailsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryModel
    let folder: UUID
    let back: () -> Void
    @State private var portrait = false

    var body: some View {
        Group {
            if let part = library.index.part(containing: folder), let v = library.version(folder) {
                page(part, v)
            } else {
                Color.clear.onAppear(perform: back)   // its version is gone
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GeometryReader { g in
            Color.clear.onAppear { portrait = g.size.height > g.size.width }
                .onChange(of: g.size) { portrait = $0.height > $0.width }
        })
        .background(DS.Color.background.color.ignoresSafeArea())
    }

    private func key(_ v: LibraryVersion) -> String { "library-details-v\(v.number)" }

    private func page(_ part: LibraryPart, _ v: LibraryVersion) -> some View {
        let pending = library.isDraft(v) || model.runningIDs.contains(v.folderID)
        return ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                header(part, v)
                if portrait {
                    VStack(alignment: .leading, spacing: DS.Space.xl) {
                        picture(part, v, pending: pending)
                        facts(part, v, pending: pending)
                    }
                } else {
                    HStack(alignment: .top, spacing: DS.Space.xl3) {
                        picture(part, v, pending: pending).frame(maxWidth: .infinity)
                        facts(part, v, pending: pending).frame(width: 470)
                    }
                }
            }
            .padding(.horizontal, DS.Space.page).padding(.top, 34).padding(.bottom, 60)
        }
        .background(DSParts.publish(key(v)))
        .accessibilityIdentifier("library-details")
    }

    private func header(_ part: LibraryPart, _ v: LibraryVersion) -> some View {
        HStack(spacing: DS.Space.ml) {
            LibraryBackPill(title: part.name, action: back)
                .layoutPriority(1)
                .background(DSParts.publish(key(v) + "-back"))
            VStack(alignment: .leading, spacing: 2) {
                Text("v\(v.number) details").dsStyle(DS.TypeScale.titleXL).lineLimit(1)
                Text(words(part, v)).dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textTertiary.color).lineLimit(1)
            }
            Spacer(minLength: DS.Space.s)
            DSGlassButton(library.isDraft(v) ? "Open v\(v.number) draft" : "Open v\(v.number)", accent: true, key: key(v) + "-open") {
                LibraryCardOpen.open(model: model, library: library, folder: v.folderID, result: nil)
            }
        }
    }

    /// "Keep Clear on 2 faces · res 128" (his name, else the automatic one), as the card says it after "v7".
    private func words(_ part: LibraryPart, _ v: LibraryVersion) -> String {
        let title = library.shortTitle(of: v, in: part)
        let prefix = "v\(v.number) · "
        return title.hasPrefix(prefix) ? String(title.dropFirst(prefix.count)) : title
    }

    /// The version's picture: the result it shows (a draft: what it came from, dim). A tap opens it on its results.
    private func picture(_ part: LibraryPart, _ v: LibraryVersion, pending: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let image: CGImage? = pending || (v.summary ?? []).isEmpty
            ? draftPicture(part, v) : library.thumbnails[CompareItem(folder: v.folderID, result: library.shownResult(v))]
        return Button { LibraryCardOpen.open(model: model, library: library, folder: v.folderID, result: nil) } label: {
            LibraryPicture(image: image, dim: pending)
                .frame(maxWidth: .infinity).frame(height: portrait ? 380 : 460)
                .clipShape(shape)
                .overlay(shape.strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
                .overlay(alignment: .topLeading) { LibraryStageChip(snapshot: library.snapshots[v.folderID]).padding(DS.Space.m) }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open v\(v.number)")
        .background(DSParts.publish(key(v) + "-picture"))
    }

    private func draftPicture(_ part: LibraryPart, _ v: LibraryVersion) -> CGImage? {
        guard let parent = v.parentNumber.flatMap(part.version(number:)) else { return library.originalPicture(part) }
        return library.thumbnails[CompareItem(folder: parent.folderID, result: library.shownResult(parent))] ?? library.originalPicture(part)
    }

    private func facts(_ part: LibraryPart, _ v: LibraryVersion, pending: Bool) -> some View {
        let snap = library.snapshots[v.folderID]
        return VStack(alignment: .leading, spacing: DS.Space.l) {
            section("Results", key: key(v) + "-results") {
                if model.runningIDs.contains(v.folderID) {
                    Text("Running").dsStyle(DS.TypeScale.callout).foregroundStyle(DS.Color.textSecondary.color)
                } else if pending {
                    Text("Not optimized yet").dsStyle(DS.TypeScale.callout).foregroundStyle(DS.Color.textSecondary.color)
                } else if let n = v.summary?.count, n > 0 {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        ForEach(0..<n, id: \.self) { r in resultRow(part, v, r) }
                    }
                } else {
                    Text("Reading the results…").dsStyle(DS.TypeScale.callout).foregroundStyle(DS.Color.textTertiary.color)
                }
            }
            section("Where it came from", key: key(v) + "-from") {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    ForEach(Array(LibraryVersionFacts.origin(v, snapshot: snap, draft: library.isDraft(v)).enumerated()), id: \.offset) { _, line in
                        Text(line).dsStyle(DS.TypeScale.callout)
                    }
                }
            }
            section("Settings", key: key(v) + "-settings") {
                if let snap {
                    Grid(alignment: .topLeading, horizontalSpacing: DS.Space.l, verticalSpacing: DS.Space.s) {
                        ForEach(Array(LibraryVersionFacts.settings(snap).enumerated()), id: \.offset) { _, row in
                            GridRow {
                                Text(row.0).dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textSecondary.color)
                                Text(row.1).dsStyle(DS.TypeScale.caption).monospacedDigit()
                            }
                        }
                    }
                } else {
                    Text("Can’t be read").dsStyle(DS.TypeScale.callout).foregroundStyle(DS.Color.textTertiary.color)
                }
            }
        }
    }

    /// One result: its small picture (a tap opens it), "v2b · +10 %", its numbers, its stars, its flags (each off with a tap).
    private func resultRow(_ part: LibraryPart, _ v: LibraryVersion, _ r: Int) -> some View {
        let k = key(v) + ResultMark.letter(r)
        let mark = v.mark(for: r)
        let picked = library.chosenResult(folder: v.folderID) == r
        let s = v.summary?[safe: r]
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.m) {
                Button { LibraryCardOpen.open(model: model, library: library, folder: v.folderID, result: r) } label: {
                    LibraryPicture(image: library.thumbnails[CompareItem(folder: v.folderID, result: r)], dim: mark.rejected)
                        .frame(width: 64, height: 64).clipShape(shape)
                        .overlay(shape.strokeBorder((picked ? DS.Color.accent : DS.Color.strokeSubtle).color, lineWidth: picked ? 2 : 1))
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open v\(v.number)\(ResultMark.letter(r))")
                .background(DSParts.publish(k + "-picture"))
                VStack(alignment: .leading, spacing: 4) {
                    Text(LibraryStyle.resultTitle(number: "\(v.number)", result: r, word: s?.word)).dsStyle(DS.TypeScale.bodyStrong)
                        .lineLimit(1)
                    LibraryNumbers(summary: s, rejected: false)
                }
                Spacer(minLength: 0)
                LibraryStars(value: mark.stars, size: 18) { library.setStars($0, folder: v.folderID, result: r) }
                    .background(DSParts.publish(k + "-stars"))
            }
            HStack(spacing: 2) {
                if picked { LibraryFlagChip.picked(key: k + "-picked") { library.unpick(part: part.id) } }
                if mark.printThis {
                    LibraryFlagChip(flag: .printThis, key: k + "-print") { library.removeFlag(.printThis, folder: v.folderID, result: r) }
                }
                if mark.rejected {
                    LibraryFlagChip(flag: .rejected, key: k + "-rejected") { library.removeFlag(.rejected, folder: v.folderID, result: r) }
                }
                if mark.inConsideration {
                    LibraryFlagChip(flag: .considering, key: k + "-considering") { library.removeFlag(.considering, folder: v.folderID, result: r) }
                }
                if !(picked || mark.printThis || mark.rejected || mark.inConsideration) {
                    Text("No flags").dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textTertiary.color)
                        .frame(minHeight: DSParts.target)
                }
            }
        }
        .background(DSParts.publish(k))
    }

    private func section<C: View>(_ title: String, key: String, @ViewBuilder _ content: () -> C) -> some View {
        let shape = RoundedRectangle(cornerRadius: DSCards.versionRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(title).dsStyle(DS.TypeScale.overlineSmall).foregroundStyle(DS.Color.textTertiary.color)
            content()
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(DSCards.fill.color))
        .overlay(shape.strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
        .background(DSParts.publish(key))
    }
}
