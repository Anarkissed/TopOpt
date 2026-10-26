// LibraryCompareView.swift — Quick look (screen 5) and Compare (screen 4), as he redesigned it
// (approved Library mockup 2026-10-25; his decisions 1-2 and the Details fix):
//
// - The models are the point: two big 3D views (three for one optimization's results).
// - LINKED by default: the views share ONE OrbitCameraModel, so turning one turns the other (both
//   MetalMeshViews subscribe to its `$camera`). ⚙ → Link views off gives each its own camera, copied
//   from the shared one so nothing jumps; on again adopts the left view's.
// - Better under one; a › on the other brings the next result and clears Better (CompareSession).
// - Details (bottom) holds the engineers' numbers. ★ HIS FIX: opening it moves the 3D views UP and
//   makes them smaller — the panel never covers a model (a VStack, not an overlay).
// - Nothing opens a project here: everything is read from each version's saved results.

import SwiftUI
import TopOptDesign
import TopOptKit

// MARK: - one 3D result

/// A result's 3D view, or its picture while the results file is being read.
struct LibraryResultView: View {
    let mesh: ViewerMesh?
    let picture: CGImage?
    let camera: OrbitCameraModel
    var body: some View {
        ZStack {
            LibraryPicture(image: mesh == nil ? picture : nil)
            if let mesh {
                MetalMeshView(mesh: mesh, camera: camera)
            } else if picture == nil {
                ProgressView().controlSize(.regular)
            }
        }
    }
}

/// The decoded results of the versions on screen.
@MainActor
final class LibraryResultsLoader: ObservableObject {
    @Published private(set) var byFolder: [UUID: [LibraryResult]] = [:]
    func need(_ folder: UUID, from library: LibraryModel) {
        guard byFolder[folder] == nil else { return }
        library.results(for: folder) { [weak self] r in if let r { self?.byFolder[folder] = r } }
    }
    func mesh(_ item: CompareItem) -> ViewerMesh? { byFolder[item.folder]?[safe: item.result]?.mesh }
}

// MARK: - 5 · Quick look

struct LibraryQuickLookView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryModel
    @State var folder: UUID
    let close: () -> Void
    let compare: (LibraryCompareRequest) -> Void
    @StateObject private var loader = LibraryResultsLoader()
    @StateObject private var camera = OrbitCameraModel()
    @State private var shown: Int?
    @State private var details = false

    var body: some View {
        let part = library.index.part(containing: folder)
        let v = library.version(folder)
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture(perform: close)
            if let part, let v {
                let r = shown ?? library.shownResult(v)
                let item = CompareItem(folder: folder, result: r)
                let mark = v.mark(for: r)
                let steps = part.versions.filter { !library.isDraft($0) }.sorted { $0.number < $1.number }
                let i = steps.firstIndex { $0.folderID == folder }
                HStack(alignment: .top, spacing: DS.Space.xl3) {
                    ZStack(alignment: .topLeading) {
                        LibraryResultView(mesh: loader.mesh(item), picture: library.thumbnails[item], camera: camera)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        LibraryStageChip(snapshot: library.snapshots[folder]).padding(DS.Space.m)
                        if let n = v.summary?.count, n > 1 {
                            LibraryResultSwitcher(count: n, shown: r, suggested: library.suggestedResult(v),
                                                  rejected: Set(v.marks.filter(\.rejected).map(\.result))) { shown = $0 }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(DS.Space.m)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        HStack(spacing: DS.Space.s) {
                            Text("v\(v.number)\(ResultMark.letter(r)) · \(v.name ?? library.shortTitle(of: v, in: part).replacingOccurrences(of: "v\(v.number) · ", with: ""))")
                                .dsStyle(DS.TypeScale.title).lineLimit(2)
                            Spacer()
                            circle("chevron.left", disabled: i == nil || i == 0) { if let i, i > 0 { step(to: steps[i - 1]) } }
                            circle("chevron.right", disabled: i == nil || i == steps.count - 1) { if let i, i < steps.count - 1 { step(to: steps[i + 1]) } }
                            circle("xmark", disabled: false, action: close)
                        }
                        LibraryNumbers(summary: v.summary?[safe: r], rejected: mark.rejected, big: true)
                        HStack {
                            LibraryStars(value: mark.stars, size: 30) { library.setStars($0, folder: folder, result: r) }
                            Spacer()
                            Button { library.togglePrint(folder: folder, result: r) } label: {
                                Label("Print this", systemImage: "printer").font(DS.TypeScale.subhead.font).fontWeight(.semibold)
                                    .foregroundStyle(mark.printThis ? .white : DS.Color.okGreen.color)
                                    .padding(.horizontal, DS.Space.ml).frame(height: 36)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(mark.printThis ? DS.Color.okGreen.color : DS.Color.fillSubtle.color))
                            }
                            .buttonStyle(.plain)
                            Button { library.toggleReject(folder: folder, result: r) } label: {
                                Label("Reject", systemImage: "xmark.circle").font(DS.TypeScale.subhead.font).fontWeight(.semibold)
                                    .foregroundStyle(mark.rejected ? .white : DS.Color.danger.color)
                                    .padding(.horizontal, DS.Space.ml).frame(height: 36)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(mark.rejected ? DS.Color.danger.color : DS.Color.fillSubtle.color))
                            }
                            .buttonStyle(.plain)
                        }
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            Text(v.parentNumber.map { "Changed from v\($0)" } ?? "First run").dsStyle(DS.TypeScale.overlineSmall)
                                .foregroundStyle(DS.Color.textTertiary.color)
                            if v.changes.isEmpty {
                                Text(v.parentNumber == nil ? "The part as set up" : "Same settings").dsStyle(DS.TypeScale.callout)
                            }
                            ForEach(Array(v.changes.enumerated()), id: \.offset) { _, c in Text(c.text).dsStyle(DS.TypeScale.callout) }
                        }
                        .padding(DS.Space.ml).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.3)))
                        DisclosureGroup(isExpanded: $details) {
                            LibraryDetailsTable(library: library, items: [item]).padding(.top, DS.Space.s)
                        } label: {
                            Text("Details").dsStyle(DS.TypeScale.overlineSmall).foregroundStyle(DS.Color.textTertiary.color)
                        }
                        .padding(DS.Space.ml)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.3)))
                        Spacer(minLength: 0)
                        HStack {
                            Spacer()
                            if (v.summary?.count ?? 0) > 1 {
                                pill("Compare \((0..<(v.summary?.count ?? 0)).map(ResultMark.letter).joined(separator: " "))", primary: false) {
                                    compare(LibraryCompareRequest(part: part.id, scope: .version(folder)))
                                }
                            }
                            pill("Open", primary: true) {
                                if let recent = model.recentProjects.first(where: { $0.id == folder }) { close(); model.open(recent) }
                            }
                        }
                    }
                    .frame(width: 440)
                }
                .padding(DS.Space.xl2)
                .frame(maxWidth: 1240, maxHeight: 920)
                .background(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous).fill(DS.Surface.sheet.color))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous).strokeBorder(DS.Color.strokeSheet.color, lineWidth: 1))
                .padding(DS.Space.xl4)
                .onAppear { loader.need(folder, from: library) }
                .onChange(of: folder) { loader.need($0, from: library) }
            }
        }
        .accessibilityIdentifier("library-quick-look")
    }

    private func step(to v: LibraryVersion) { folder = v.folderID; shown = nil }

    private func circle(_ icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44).liquidGlass(in: Circle())
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.35 : 1)
    }

    private func pill(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).dsStyle(DS.TypeScale.bodyStrong).foregroundStyle(primary ? .white : DS.Color.textPrimary.color)
                .padding(.horizontal, DS.Space.l).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 14).fill(primary ? DS.Color.accent.color : DS.Color.fillSubtle.color))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - the engineers' numbers

struct LibraryDetailsTable: View {
    @ObservedObject var library: LibraryModel
    let items: [CompareItem]
    var body: some View {
        let rows: [(String, (CompareItem) -> String)] = [
            ("Plastic", { i in summary(i).map { String(format: "%.1f g · %@ of the part as drawn", $0.massGrams, LibraryStyle.percent($0.achievedVolumeFraction)) } ?? "—" }),
            ("Strength margin", { i in summary(i).map { String(format: "%.2f (needs more than 1)", $0.worstCaseMargin) } ?? "—" }),
            ("Verdict", { i in summary(i).map { $0.accepted ? "Strong enough" : "Not strong enough" } ?? "—" }),
            ("Goal", { i in (library.snapshots[i.folder]?.minimizePlastic ?? true) ? "Minimize plastic" : "Strengthen" }),
            ("Resolution", { i in "\((library.snapshots[i.folder]?.quality ?? .fast).resolution)" }),
            ("Material", { i in library.snapshots[i.folder]?.material ?? "—" }),
            ("Saved", { i in library.snapshots[i.folder]?.savedAt.formatted(date: .abbreviated, time: .shortened) ?? "—" }),
            ("Changed", { i in (library.version(i.folder)?.changes.map(\.text).joined(separator: "\n")).flatMap { $0.isEmpty ? nil : $0 } ?? "nothing" }),
        ]
        Grid(alignment: .topLeading, horizontalSpacing: DS.Space.l, verticalSpacing: DS.Space.s) {
            if items.count > 1 {
                GridRow {
                    Text("")
                    ForEach(items, id: \.self) { i in
                        Text(label(i)).dsStyle(DS.TypeScale.caption).fontWeight(.semibold).foregroundStyle(DS.Color.textTertiary.color)
                    }
                }
            }
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textSecondary.color)
                    ForEach(items, id: \.self) { i in Text(row.1(i)).dsStyle(DS.TypeScale.caption).monospacedDigit() }
                }
                Divider().overlay(DS.Color.strokeSubtle.color)
            }
        }
    }
    private func summary(_ i: CompareItem) -> ResultSummary? { library.version(i.folder)?.summary?[safe: i.result] }
    private func label(_ i: CompareItem) -> String { "v\(library.version(i.folder)?.number ?? 0)\(ResultMark.letter(i.result))" }
}

// MARK: - 4 · Compare

struct LibraryCompareView: View {
    @ObservedObject var library: LibraryModel
    @State var request: LibraryCompareRequest
    let close: () -> Void
    @StateObject private var loader = LibraryResultsLoader()
    @StateObject private var shared = OrbitCameraModel()
    @State private var own: [Int: OrbitCameraModel] = [:]
    @State private var session: CompareSession?
    @State private var three: ThreeUpSession?
    @State private var linked = true
    @State private var numbers = true
    @State private var skipRejected = true
    @State private var details = false
    @State private var note: String?

    var body: some View {
        let part = library.part(request.part)
        VStack(spacing: DS.Space.ml) {
            topBar(part)
            GeometryReader { geo in
                VStack(spacing: DS.Space.ml) {
                    views
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if details {
                        ScrollView {
                            LibraryDetailsTable(library: library, items: shownItems).padding(DS.Space.ml)
                        }
                        // ★ his fix: the panel takes its share of the height and the views shrink above it
                        .frame(height: min(320, geo.size.height * 0.42))
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(DS.Surface.sheet.color))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(DS.Color.strokeSheet.color, lineWidth: 1))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            HStack {
                if let s = session, s.kept != nil || s.seen.count > 2 {
                    Text("\(s.seen.count) of \(s.queue.count) seen").dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textTertiary.color)
                }
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.2)) { details.toggle() } } label: {
                    Label("Details", systemImage: details ? "chevron.down" : "chevron.up").font(DS.TypeScale.bodyStrong.font)
                        .padding(.horizontal, DS.Space.l).frame(height: 44).liquidGlassCapsule()
                }
                .buttonStyle(.plain).accessibilityIdentifier("compare-details")
                Spacer()
            }
        }
        .padding(.horizontal, DS.Space.xl4).padding(.top, DS.Space.xl2).padding(.bottom, DS.Space.xl)
        .background(DS.Color.background.color.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let note { Text(note).dsStyle(DS.TypeScale.bodyStrong).padding(.horizontal, DS.Space.l).frame(height: 44)
                .liquidGlassCapsule().padding(.bottom, 80).onTapGesture { self.note = nil } }
        }
        .onAppear(perform: start)
        .accessibilityIdentifier("library-compare-screen")
    }

    // MARK: pieces

    private var shownItems: [CompareItem] {
        if let three { return three.items }
        return [session?.left, session?.right].compactMap { $0 }
    }

    private func start() {
        guard let part = library.part(request.part) else { return }
        switch request.scope {
        case .all:
            session = CompareSession(part: part, skipRejected: skipRejected); three = nil
        case let .version(folder):
            three = library.version(folder).map(CompareSession.threeUp); session = nil
        }
        for i in shownItems { loader.need(i.folder, from: library) }
    }

    private func camera(_ slot: Int) -> OrbitCameraModel {
        if linked { return shared }
        if let c = own[slot] { return c }
        return shared
    }

    private func setLinked(_ on: Bool) {
        if on {
            if let first = own[0] { shared.adopt(first.camera) }
            own = [:]
        } else {
            own = Dictionary(uniqueKeysWithValues: (0..<3).map { ($0, OrbitCameraModel(camera: shared.camera)) })
        }
        linked = on
    }

    @ViewBuilder private var views: some View {
        if let three {
            HStack(spacing: DS.Space.l) {
                ForEach(Array(three.items.enumerated()), id: \.element) { slot, item in
                    panel(item, slot: slot, kept: three.best == item, pickTitle: "Best", pick: { self.three?.toggleBest(item) },
                          showsNext: false, menu: nil)
                }
            }
        } else if let s = session {
            HStack(spacing: DS.Space.l) {
                if let l = s.left {
                    panel(l, slot: 0, kept: s.kept == .left, pickTitle: "Better", pick: { session?.pick(.left) },
                          showsNext: s.showsNext(on: .left), menu: .left)
                }
                if let r = s.right {
                    panel(r, slot: 1, kept: s.kept == .right, pickTitle: "Better", pick: { session?.pick(.right) },
                          showsNext: s.showsNext(on: .right), menu: .right)
                }
                if s.left == nil {
                    Text("No results to compare yet.").dsStyle(DS.TypeScale.body).foregroundStyle(DS.Color.textTertiary.color)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay {
                if s.left != nil, s.right != nil {
                    Image(systemName: linked ? "link" : "link.badge.plus").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(linked ? DS.Color.accentCyan.color : DS.Color.textTertiary.color)
                        .frame(width: 36, height: 36).liquidGlass(in: Circle())
                        .accessibilityLabel(linked ? "Views turn together" : "Views turn apart")
                }
            }
        }
    }

    private func panel(_ item: CompareItem, slot: Int, kept: Bool, pickTitle: String, pick: @escaping () -> Void,
                       showsNext: Bool, menu side: CompareSide?) -> some View {
        let v = library.version(item.folder)
        let mark = v?.mark(for: item.result) ?? ResultMark(result: item.result)
        return ZStack {
            LibraryResultView(mesh: loader.mesh(item), picture: library.thumbnails[item], camera: camera(slot))
            VStack {
                HStack(spacing: DS.Space.s) {
                    if let side, let s = session {
                        Menu {
                            ForEach(s.queue, id: \.self) { q in
                                Button(itemTitle(q)) { session?.set(side, to: q); loader.need(q.folder, from: library) }
                            }
                        } label: {
                            HStack(spacing: DS.Space.xs) {
                                Text(itemTitle(item)).dsStyle(DS.TypeScale.bodyStrong).lineLimit(1)
                                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                            }
                            .padding(.horizontal, DS.Space.ml).frame(height: 40).liquidGlassCapsule()
                        }
                    } else {
                        Text(itemTitle(item)).dsStyle(DS.TypeScale.bodyStrong).lineLimit(1)
                            .padding(.horizontal, DS.Space.ml).frame(height: 40).liquidGlassCapsule()
                    }
                    Spacer()
                    if mark.printThis {
                        Image(systemName: "printer").foregroundStyle(DS.Color.okGreen.color)
                            .frame(width: 30, height: 30).background(Circle().fill(Color.black.opacity(0.6)))
                    }
                }
                Spacer()
                // three-up panels are narrow: the numbers get their own row above the stars and Best
                let stacked = three != nil
                VStack(alignment: .leading, spacing: DS.Space.s) {
                if stacked, numbers { LibraryNumbers(summary: v?.summary?[safe: item.result], rejected: mark.rejected).padding(.top, DS.Space.s) }
                HStack(spacing: DS.Space.m) {
                    if !stacked, numbers { LibraryNumbers(summary: v?.summary?[safe: item.result], rejected: mark.rejected) }
                    Spacer(minLength: 0)
                    LibraryStars(value: mark.stars, size: 22) { library.setStars($0, folder: item.folder, result: item.result) }
                    Button(action: pick) {
                        Label(pickTitle, systemImage: "checkmark").font(DS.TypeScale.bodyStrong.font)
                            .foregroundStyle(kept ? .white : DS.Color.textPrimary.color)
                            .padding(.horizontal, DS.Space.ml).frame(height: 40)
                            .background(Capsule().fill(kept ? DS.Color.okGreen.color : DS.Color.fillSubtle.color))
                            .overlay(Capsule().strokeBorder(kept ? .clear : DS.Color.strokeStrong.color, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("compare-\(pickTitle.lowercased())-\(slot)")
                }
                .frame(minHeight: stacked ? 48 : 60)
                }
                .padding(.leading, DS.Space.l).padding(.trailing, DS.Space.sm)
                .liquidGlass(cornerRadius: 20)
            }
            .padding(DS.Space.ml)
            if showsNext {
                VStack(spacing: DS.Space.xs) {
                    Button {
                        if session?.next() == true, let s = session {
                            for i in [s.left, s.right].compactMap({ $0 }) { loader.need(i.folder, from: library) }
                        }
                    } label: {
                        Image(systemName: "chevron.right").font(.system(size: 26, weight: .bold))
                            .frame(width: 60, height: 60).liquidGlass(in: Circle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("compare-next")
                    Text("\(session?.remaining ?? 0) more").dsStyle(DS.TypeScale.footnote).fontWeight(.semibold)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Color.black.opacity(0.6)))
                }
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, DS.Space.ml)
            }
        }
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(.sRGB, red: 0.043, green: 0.051, blue: 0.071, opacity: 1)))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(kept ? DS.Color.okGreen.color : DS.Color.strokePanel.color, lineWidth: kept ? 3 : 1))
    }

    private func itemTitle(_ i: CompareItem) -> String {
        guard let v = library.version(i.folder), let part = library.index.part(containing: i.folder) else { return "" }
        return "v\(v.number)\(ResultMark.letter(i.result)) · \(v.name ?? library.shortTitle(of: v, in: part).replacingOccurrences(of: "v\(v.number) · ", with: ""))"
    }

    private func topBar(_ part: LibraryPart?) -> some View {
        HStack(spacing: DS.Space.m) {
            Button(action: close) {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44).liquidGlass(in: Circle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("compare-back")
            if let part {
                Menu {
                    Button("All results") { request.scope = .all; start() }
                    ForEach(part.versions.filter { ($0.summary?.count ?? 0) > 1 }.sorted { $0.number > $1.number }, id: \.folderID) { v in
                        Button("v\(v.number)’s results") { request.scope = .version(v.folderID); start() }
                    }
                } label: {
                    HStack(spacing: DS.Space.xs) {
                        Text(scopeTitle(part)).dsStyle(DS.TypeScale.headline)
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, DS.Space.l).frame(height: 44).liquidGlassCapsule()
                }
                .accessibilityIdentifier("compare-scope")
            }
            Spacer()
            Menu {
                Toggle("Link views", isOn: Binding(get: { linked }, set: { setLinked($0) }))
                Toggle("Show numbers", isOn: $numbers)
                Toggle("Skip rejected", isOn: Binding(get: { skipRejected }, set: { skipRejected = $0; if session != nil { start() } }))
                Button("Reset the view") {
                    if let m = shownItems.compactMap(loader.mesh).first {
                        shared.reframe(m.bounds); for c in own.values { c.reframe(m.bounds) }
                    }
                }
            } label: {
                Image(systemName: "gearshape").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44).liquidGlass(in: Circle())
            }
            .accessibilityIdentifier("compare-settings")
        }
    }

    private func scopeTitle(_ part: LibraryPart) -> String {
        switch request.scope {
        case .all: return "All results (\(session?.queue.count ?? 0))"
        case let .version(f): return "v\(library.version(f)?.number ?? 0)’s results"
        }
    }
}
