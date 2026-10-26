// LibraryViews.swift — the Library screens (approved Library mockup 2026-10-25, screens 1-3, 9, 10):
// Library home → Project folder → Part folder with version cards; the first-launch sheet; Storage.
//
// ★ HIS RULE FOR EVERY SCREEN (10-25): "Limit the wording and technical data as much as possible; but
// keep it accessible for engineers who want it." Cards show weight, strength and stars; the rest sits
// behind Details (Quick look, Compare).
//
// ★ TODAY'S HOME STAYS where the Library can't take over: before he taps Group, and when library.json
// can't be read. #362's hooks on it (H46, H51) therefore keep working there, and their behaviour carries
// over here (reviewer ruling 2026-10-25 22:36 (2)):
//   H46 → a part card's line is `FlexibleHomeCard.meta(recent)` first, today's text otherwise;
//   H51 → a version's ⋯ "New draft from vN" is `model.duplicateProject(id:)` (H52), unchanged.

import SwiftUI
import TopOptDesign
import TopOptKit

// MARK: - routing

enum LibraryRoute: Equatable { case home, project(UUID), unfiled, part(UUID), storage }

/// What Compare opens on.
struct LibraryCompareRequest: Equatable, Identifiable {
    enum Scope: Equatable { case all, version(UUID) }
    let part: UUID
    var scope: Scope
    var id: String { "\(part)-\(scope)" }
}

public struct LibraryRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryModel
    @State private var route: LibraryRoute = .home
    @State private var grouping = false
    @State private var quickLook: UUID?
    @State private var compare: LibraryCompareRequest?

    public init(model: AppModel) {
        self.model = model
        self.library = model.library
    }

    public var body: some View {
        ZStack {
            switch library.mode {
            case .library:
                screen
            case .flat:
                HomeView(model: model)
                    .overlay(alignment: .bottom) {
                        LibraryBanner(icon: "square.stack.3d.up", text: "Sort your copies into parts and versions",
                                      button: "Review") { grouping = true }
                    }
            case let .unreadable(why):
                HomeView(model: model)
                    .overlay(alignment: .bottom) {
                        LibraryBanner(icon: "exclamationmark.triangle", text: "The Library can’t be read (\(why)). Your projects are listed as before.",
                                      button: nil) {}
                    }
            }
            if grouping {
                FirstLaunchGroupingView(library: library, close: { grouping = false })
                    .transition(.opacity).zIndex(2)
            }
            if let folder = quickLook, library.mode == .library {
                LibraryQuickLookView(model: model, library: library, folder: folder,
                                     close: { quickLook = nil },
                                     compare: { req in quickLook = nil; compare = req })
                    .transition(.opacity).zIndex(3)
            }
            if let req = compare, library.mode == .library {
                LibraryCompareView(library: library, request: req, close: { compare = nil })
                    .transition(.opacity).zIndex(4)
            }
        }
        .background(DS.Color.background.color.ignoresSafeArea())
        .foregroundStyle(DS.Color.textPrimary.color)
        .onAppear {
            library.refresh()
            library.loadSummaries()
        }
    }

    @ViewBuilder private var screen: some View {
        switch route {
        case .home:
            LibraryHomeView(model: model, library: library, go: { route = $0 }, quickLook: { quickLook = $0 },
                            ungroup: { route = .home; library.ungroup() })
        case let .project(id):
            if let p = library.project(id) {
                ProjectFolderView(model: model, library: library, project: p, parts: library.parts(in: p),
                                  back: { route = .home }, open: { route = .part($0) })
            } else { LibraryHomeView(model: model, library: library, go: { route = $0 }, quickLook: { quickLook = $0 },
                                     ungroup: { library.ungroup() }) }
        case .unfiled:
            ProjectFolderView(model: model, library: library, project: nil, parts: library.index.unfiledParts,
                              back: { route = .home }, open: { route = .part($0) })
        case let .part(id):
            if let part = library.part(id) {
                PartFolderView(model: model, library: library, part: part,
                               back: { route = library.projectOf(part: id).map { .project($0.id) } ?? .unfiled },
                               quickLook: { quickLook = $0 }, compare: { compare = $0 })
            } else { LibraryHomeView(model: model, library: library, go: { route = $0 }, quickLook: { quickLook = $0 },
                                     ungroup: { library.ungroup() }) }
        case .storage:
            LibraryStorageView(library: library, back: { route = .home })
        }
    }
}

// MARK: - small shared pieces

/// The slim note over today's Home (before Group, or when the index can't be read).
struct LibraryBanner: View {
    let icon: String
    let text: String
    let button: String?
    let action: () -> Void
    var body: some View {
        HStack(spacing: DS.Space.ml) {
            Image(systemName: icon).foregroundStyle(DS.Color.accentCyan.color)
            Text(text).dsStyle(DS.TypeScale.bodyStrong).lineLimit(2)
            if let button {
                Button(button, action: action)
                    .buttonStyle(.plain).font(DS.TypeScale.bodyStrong.font).foregroundStyle(.white)
                    .padding(.horizontal, DS.Space.l).frame(height: 36)
                    .background(Capsule().fill(DS.Color.accent.color))
                    .accessibilityIdentifier("library-banner-\(button.lowercased())")
            }
        }
        .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.sm)
        .liquidGlassCapsule()
        .padding(.bottom, DS.Space.xl4)
    }
}

/// The back pill ("‹ Squish Mechanism").
struct LibraryBackPill: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                Text(title).dsStyle(DS.TypeScale.bodyStrong).lineLimit(1)
            }
            .padding(.leading, DS.Space.m).padding(.trailing, DS.Space.l).frame(height: 44)
            .liquidGlassCapsule()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library-back")
    }
}

/// Five stars; tap the left half of a star for a half. The same value again clears it.
struct LibraryStars: View {
    let value: Double
    var size: CGFloat = 18
    let set: ((Double) -> Void)?
    var body: some View {
        let row = HStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { _ in Image(systemName: "star").font(.system(size: size * 0.82, weight: .semibold)).frame(width: size, height: size) }
        }
        ZStack(alignment: .leading) {
            row.foregroundStyle(DS.Color.textPrimary.opacity(0.32).color)
            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { _ in Image(systemName: "star.fill").font(.system(size: size * 0.82, weight: .semibold)).frame(width: size, height: size) }
            }
            .foregroundStyle(LibraryStyle.star)
            .mask(alignment: .leading) { Rectangle().frame(width: size * 5 * value / 5) }
        }
        .frame(width: size * 5, height: size)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onEnded { g in
            guard let set else { return }
            set(max(0.5, min(5, (g.location.x / size * 2).rounded(.up) / 2)))
        })
        .allowsHitTesting(set != nil)
        .accessibilityElement()
        .accessibilityLabel("\(value.formatted()) of 5 stars")
        .accessibilityAdjustableAction { dir in
            guard let set else { return }
            set(dir == .increment ? min(5, value + 0.5) : max(0.5, value - 0.5))
        }
    }
}

enum LibraryStyle {
    static let star = Color(.sRGB, red: 1, green: 0.84, blue: 0.04, opacity: 1)
    static let cardFill = DS.Color.textPrimary.opacity(0.045).color
    static let cardStroke = DS.Color.textPrimary.opacity(0.09).color

    /// "120 g" / "89.0 g".
    static func grams(_ g: Double) -> String { g < 100 ? String(format: "%.1f g", g) : String(format: "%.0f g", g) }
    /// The Results screen's basis: the printed fraction of the part as drawn.
    static func percent(_ f: Double) -> String { "\(Int((f * 100).rounded())) %" }
    /// "6.5×".
    static func margin(_ m: Double) -> String { String(format: "%.1f×", m) }

    /// Topology / Lattice / Flexible, from the version's own settings.
    static func stage(_ s: ProjectSnapshot?) -> (String, RGBA) {
        if s?.lattice?.flexible != nil { return ("Flexible", DS.Color.okGreen) }
        if s?.lattice?.enabled == true { return ("Lattice", RGBA(hex: 0x7C6FD6)) }
        return ("Topology", DS.Color.accent)
    }
}

/// A card's surface: the app's recent-card look (HomeView), shared by every Library card.
struct LibraryCardSurface: ViewModifier {
    var dashed = false
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(dashed ? DS.Color.accentCyan.opacity(0.04).color : LibraryStyle.cardFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(dashed ? DS.Color.accentCyan.opacity(0.45).color : LibraryStyle.cardStroke,
                                  style: StrokeStyle(lineWidth: dashed ? 1.5 : 1, dash: dashed ? [7, 6] : []))
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }
}

/// A result's picture: its rendered mesh, or a quiet placeholder until it is ready.
struct LibraryPicture: View {
    let image: CGImage?
    var dim = false
    var body: some View {
        ZStack {
            Rectangle().fill(RadialGradient(colors: [Color(.sRGB, red: 0.39, green: 0.51, blue: 0.75, opacity: 0.16), .clear],
                                            center: .center, startRadius: 4, endRadius: 220))
            Rectangle().fill(Color(.sRGB, red: 0.043, green: 0.051, blue: 0.071, opacity: 1)).opacity(0.6)
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .padding(DS.Space.s).opacity(dim ? 0.32 : 1)
            } else {
                Image(systemName: "cube.transparent").font(.system(size: 34, weight: .light))
                    .foregroundStyle(DS.Color.textPrimary.opacity(0.22).color)
            }
        }
        .clipped()
    }
}

struct LibraryStageChip: View {
    let snapshot: ProjectSnapshot?
    var body: some View {
        let (word, tint) = LibraryStyle.stage(snapshot)
        HStack(spacing: DS.Space.xs) {
            Circle().fill(tint.color).frame(width: 8, height: 8)
            Text(word).dsStyle(DS.TypeScale.footnote).fontWeight(.semibold)
        }
        .foregroundStyle(DS.Color.textSecondary.color)
        .padding(.horizontal, DS.Space.sm).frame(height: 26)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1))
    }
}

/// "120 g  103 %  |  6.5× ✓" — the two numbers a card shows.
struct LibraryNumbers: View {
    let summary: ResultSummary?
    let rejected: Bool
    var big = false
    var body: some View {
        HStack(spacing: DS.Space.s) {
            if let s = summary {
                Text(LibraryStyle.grams(s.massGrams)).font(.system(size: big ? 26 : 17, weight: .bold)).monospacedDigit()
                Text(LibraryStyle.percent(s.achievedVolumeFraction)).dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textTertiary.color)
                Rectangle().fill(DS.Color.strokeStrong.color).frame(width: 1, height: big ? 26 : 18).padding(.horizontal, DS.Space.xxs)
                Text(LibraryStyle.margin(s.worstCaseMargin)).font(.system(size: big ? 26 : 17, weight: .bold)).monospacedDigit()
                Image(systemName: s.accepted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle((s.accepted ? DS.Color.okGreen : DS.Color.danger).color)
                    .font(.system(size: big ? 20 : 15))
                    .accessibilityLabel(s.accepted ? "Strong enough" : "Not strong enough")
            } else {
                Text("Reading the result…").dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textTertiary.color)
            }
            if rejected {
                Text("Rejected").dsStyle(DS.TypeScale.footnote).fontWeight(.semibold)
                    .foregroundStyle(DS.Color.danger.color)
                    .padding(.horizontal, DS.Space.s).padding(.vertical, 3)
                    .background(Capsule().fill(DS.Color.danger.opacity(0.14).color))
            }
        }
        .lineLimit(1)
    }
}

/// a b c — which result a card or a quick look shows. A dot marks the suggested one.
struct LibraryResultSwitcher: View {
    let count: Int
    let shown: Int
    let suggested: Int?
    let rejected: Set<Int>
    let pick: (Int) -> Void
    var body: some View {
        HStack(spacing: DS.Space.xxs) {
            ForEach(0..<count, id: \.self) { r in
                Button { pick(r) } label: {
                    Text(ResultMark.letter(r)).font(.system(size: 13, weight: .bold))
                        .strikethrough(rejected.contains(r))
                        .foregroundStyle(r == shown ? DS.Color.textPrimary.color : DS.Color.textSecondary.color)
                        .frame(width: 32, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(r == shown ? DS.Color.fillSelected.color : .clear))
                        .overlay(alignment: .topTrailing) {
                            if r == suggested { Circle().fill(DS.Color.accentCyan.color).frame(width: 5, height: 5).padding(3) }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Result \(ResultMark.letter(r))\(r == suggested ? ", suggested" : "")")
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.black.opacity(0.62)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1))
    }
}

// MARK: - 1 · Library home

struct LibraryHomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryModel
    let go: (LibraryRoute) -> Void
    let quickLook: (UUID) -> Void
    let ungroup: () -> Void
    @State private var confirmUngroup = false
    @State private var newProjectName: String?

    private let columns = [GridItem(.adaptive(minimum: 290), spacing: DS.Space.xl3)]

    /// The newest draft anywhere: what Continue opens.
    private var continueDraft: (part: LibraryPart, v: LibraryVersion)? {
        library.index.parts.flatMap { p in p.versions.filter(library.isDraft).map { (p, $0) } }
            .max { (library.snapshots[$0.1.folderID]?.savedAt ?? .distantPast) < (library.snapshots[$1.1.folderID]?.savedAt ?? .distantPast) }
            .map { (part: $0.0, v: $0.1) }
    }

    /// The four newest versions with results, anywhere.
    private var latest: [(part: LibraryPart, v: LibraryVersion)] {
        library.index.parts.flatMap { p in p.versions.filter { !library.isDraft($0) }.map { (part: p, v: $0) } }
            .sorted { (library.snapshots[$0.v.folderID]?.savedAt ?? .distantPast) > (library.snapshots[$1.v.folderID]?.savedAt ?? .distantPast) }
            .prefix(4).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let c = continueDraft { continueRow(c.part, c.v).padding(.top, DS.Space.xl3) }
                HStack {
                    Text("Projects").dsStyle(DS.TypeScale.headline)
                    Spacer()
                    Button { newProjectName = "" } label: {
                        Label("New project", systemImage: "folder.badge.plus").font(DS.TypeScale.subhead.font).fontWeight(.semibold)
                            .padding(.horizontal, DS.Space.ml).frame(height: 36)
                            .background(Capsule().fill(DS.Color.fillSubtle.color))
                            .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1))
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("library-new-project")
                }
                .padding(.top, DS.Space.xl5).padding(.bottom, DS.Space.ml)
                LazyVGrid(columns: columns, spacing: DS.Space.xl3) {
                    LibraryNewTile(title: "New TopOpt", detail: "Import STEP or STL") {
                        library.importTargetProject = nil
                        model.newTopOpt()
                    }
                    ForEach(library.index.projects) { p in
                        LibraryFolderCard(library: library, title: p.name, parts: library.parts(in: p),
                                          running: !model.runningIDs.isDisjoint(with: library.parts(in: p).flatMap { $0.versions.map(\.folderID) }),
                                          unfiled: false) { go(.project(p.id)) }
                            .contextMenu {
                                Button { library.removeProject(p.id) } label: { Label("Remove folder (parts become Unfiled)", systemImage: "folder.badge.minus") }
                            }
                    }
                    if !library.index.unfiledParts.isEmpty {
                        LibraryFolderCard(library: library, title: "Unfiled", parts: library.index.unfiledParts,
                                          running: false, unfiled: true) { go(.unfiled) }
                    }
                    // ★ round 3 ruling (c): never dropped silently — the "Can't open" cards stay
                    ForEach(model.unreadableProjects) { UnreadableProjectCard(entry: $0) }
                }
                if !latest.isEmpty {
                    Text("Latest results").dsStyle(DS.TypeScale.headline).padding(.top, DS.Space.xl5 + 8).padding(.bottom, DS.Space.ml)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: DS.Space.l)], spacing: DS.Space.l) {
                        ForEach(latest, id: \.v.folderID) { item in latestCard(item.part, item.v) }
                    }
                }
            }
            .padding(.horizontal, DS.Space.page)
            .padding(.top, 34)
            .padding(.bottom, 60)
        }
        .confirmationDialog("Ungroup the Library?", isPresented: $confirmUngroup, titleVisibility: .visible) {
            Button("Ungroup", role: .destructive, action: ungroup)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your projects go back to one list, exactly as before. Folders, version names and stars are removed.")
        }
        .alert("New project", isPresented: Binding(get: { newProjectName != nil }, set: { if !$0 { newProjectName = nil } })) {
            TextField("Name", text: Binding(get: { newProjectName ?? "" }, set: { newProjectName = $0 }))
            Button("Create") { if let n = newProjectName { library.newProject(name: n) }; newProjectName = nil }
            Button("Cancel", role: .cancel) { newProjectName = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: DS.Space.ml) {
                Image(systemName: "hexagon").font(.system(size: 22, weight: .regular))
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("TopOpt").dsStyle(DS.TypeScale.titleXL)
                    Text("Topology optimization for 3D printing").dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textTertiary.color)
                }
            }
            Spacer()
            Button { go(.storage) } label: {
                Label("Storage", systemImage: "internaldrive").font(DS.TypeScale.subhead.font).fontWeight(.semibold)
                    .padding(.horizontal, DS.Space.ml).frame(height: 36)
                    .background(Capsule().fill(DS.Color.fillSubtle.color))
                    .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1))
            }
            .buttonStyle(.plain).accessibilityIdentifier("library-storage")
            Menu {
                Button(role: .destructive) { confirmUngroup = true } label: { Label("Ungroup…", systemImage: "rectangle.stack.badge.minus") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(DS.Color.fillSubtle.color))
                    .overlay(Circle().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1))
            }
            .accessibilityIdentifier("library-more")
        }
    }

    private func continueRow(_ part: LibraryPart, _ v: LibraryVersion) -> some View {
        Button { openFolder(v.folderID) } label: {
            HStack(spacing: DS.Space.ml) {
                LibraryPicture(image: parentPicture(part, v)).frame(width: 72, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue · \(part.name) v\(v.number) draft").dsStyle(DS.TypeScale.bodyStrong)
                    Text(v.changes.isEmpty ? "Not optimized yet" : "\(v.changes.count) change\(v.changes.count == 1 ? "" : "s") since v\(v.parentNumber ?? v.number)")
                        .dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textTertiary.color)
                }
                Spacer()
                Text("Open").dsStyle(DS.TypeScale.bodyStrong).foregroundStyle(.white)
                    .padding(.horizontal, DS.Space.l).frame(height: 36)
                    .background(Capsule().fill(DS.Color.accent.color))
            }
            .padding(.horizontal, DS.Space.m).frame(height: 68)
            .liquidGlass(cornerRadius: 22)
        }
        .buttonStyle(.plain).accessibilityIdentifier("library-continue")
    }

    private func parentPicture(_ part: LibraryPart, _ v: LibraryVersion) -> CGImage? {
        guard let parent = v.parentNumber.flatMap(part.version(number:)) else { return nil }
        return library.thumbnails[CompareItem(folder: parent.folderID, result: library.shownResult(parent))]
    }

    private func latestCard(_ part: LibraryPart, _ v: LibraryVersion) -> some View {
        let r = library.shownResult(v)
        return Button { quickLook(v.folderID) } label: {
            HStack(spacing: DS.Space.m) {
                LibraryPicture(image: library.thumbnails[CompareItem(folder: v.folderID, result: r)])
                    .frame(width: 132, height: 100).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(part.name) · v\(v.number)\(ResultMark.letter(r))").dsStyle(DS.TypeScale.bodyStrong).lineLimit(1)
                    if let s = v.summary?[safe: r] {
                        HStack(spacing: DS.Space.xs) {
                            Text(LibraryStyle.grams(s.massGrams)).monospacedDigit()
                            Text(LibraryStyle.margin(s.worstCaseMargin)).monospacedDigit()
                            Image(systemName: s.accepted ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle((s.accepted ? DS.Color.okGreen : DS.Color.danger).color)
                        }
                        .font(.system(size: 13.5, weight: .semibold))
                    }
                    LibraryStars(value: v.mark(for: r).stars, size: 14, set: nil)
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Space.sm)
            .modifier(LibraryCardSurface())
        }
        .buttonStyle(.plain)
    }

    private func openFolder(_ folder: UUID) {
        if let recent = model.recentProjects.first(where: { $0.id == folder }) { model.open(recent) }
    }
}

/// The dashed "New TopOpt" / "Add part" tile (today's NewTopOptTile look).
struct LibraryNewTile: View {
    let title: String
    let detail: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Space.ml) {
                ZStack {
                    Circle().fill(DS.Color.accent.color).frame(width: 56, height: 56)
                        .dsShadow(DS.Shadow(color: DS.Color.accent.opacity(0.35), radius: 28, y: 8))
                    Image(systemName: "plus").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                }
                Text(title).dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                if let detail { Text(detail).dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textQuaternary.color) }
            }
            .frame(maxWidth: .infinity).frame(minHeight: 300)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Color.textPrimary.opacity(0.03).color)
                    .overlay { RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .strokeBorder(DS.Color.textPrimary.opacity(0.18).color, style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library-new-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}

/// A project folder on the Library home: up to three of its parts' pictures.
struct LibraryFolderCard: View {
    @ObservedObject var library: LibraryModel
    let title: String
    let parts: [LibraryPart]
    let running: Bool
    let unfiled: Bool
    let open: () -> Void
    var body: some View {
        let pics = parts.prefix(3).map { library.partPicture($0) }
        let versions = parts.reduce(0) { $0 + $1.versions.count }
        let toPrint = parts.flatMap(\.versions).filter { $0.marks.contains(where: \.printThis) }.count
        Button(action: open) {
            VStack(spacing: 0) {
                Group {
                    if pics.count >= 3 {
                        HStack(spacing: 2) {
                            LibraryPicture(image: pics[0]).frame(maxWidth: .infinity)
                            VStack(spacing: 2) { LibraryPicture(image: pics[1]); LibraryPicture(image: pics[2]) }.frame(maxWidth: .infinity)
                        }
                    } else if pics.count == 2 {
                        HStack(spacing: 2) { LibraryPicture(image: pics[0]); LibraryPicture(image: pics[1]) }
                    } else {
                        LibraryPicture(image: pics.first ?? nil)
                    }
                }
                .frame(height: 230).frame(maxWidth: .infinity)
                HStack(spacing: DS.Space.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(title, systemImage: unfiled ? "square.stack" : "folder").font(DS.TypeScale.bodyStrong.font).lineLimit(1)
                        Text("\(parts.count) part\(parts.count == 1 ? "" : "s") · \(versions) version\(versions == 1 ? "" : "s")")
                            .dsStyle(DS.TypeScale.caption2).foregroundStyle(DS.Color.textTertiary.color)
                    }
                    Spacer(minLength: DS.Space.s)
                    if running {
                        HStack(spacing: DS.Space.xs) { ProgressView().controlSize(.mini); Text("Running") }
                            .font(DS.TypeScale.footnote.font).fontWeight(.semibold).foregroundStyle(DS.Color.accent.color)
                            .padding(.vertical, 5).padding(.horizontal, DS.Space.sm)
                            .background(Capsule().fill(DS.Color.accent.opacity(0.14).color))
                    } else if toPrint > 0 {
                        Label("\(toPrint)", systemImage: "printer").font(DS.TypeScale.footnote.font).fontWeight(.semibold)
                            .foregroundStyle(DS.Color.okGreen.color)
                            .padding(.vertical, 5).padding(.horizontal, DS.Space.sm)
                            .background(Capsule().fill(DS.Color.okGreen.opacity(0.14).color))
                    }
                }
                .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.ml)
                .overlay(alignment: .top) { Rectangle().fill(DS.Color.strokeSubtle.color).frame(height: 1) }
            }
            .modifier(LibraryCardSurface())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library-folder-\(title)")
    }
}

extension LibraryModel {
    /// A part's picture: its Print-this result, else the shown result of its newest version with results.
    func partPicture(_ part: LibraryPart) -> CGImage? {
        let done = part.versions.filter { !isDraft($0) }.sorted { $0.number > $1.number }
        if let v = done.first(where: { $0.marks.contains(where: \.printThis) }),
           let r = v.marks.first(where: \.printThis)?.result {
            return thumbnails[CompareItem(folder: v.folderID, result: r)]
        }
        return done.first.flatMap { thumbnails[CompareItem(folder: $0.folderID, result: shownResult($0))] }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - 2 · Project folder

struct ProjectFolderView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryModel
    let project: LibraryProject?
    let parts: [LibraryPart]
    let back: () -> Void
    let open: (UUID) -> Void
    @State private var renaming: String?
    @State private var renamingPart: (id: UUID, name: String)?
    @State private var deleting: LibraryPart?

    private let columns = [GridItem(.adaptive(minimum: 360), spacing: DS.Space.xl3)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DS.Space.ml) {
                    LibraryBackPill(title: "Library", action: back)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project?.name ?? "Unfiled").dsStyle(DS.TypeScale.titleXL)
                            .onTapGesture { if let project { renaming = project.name } }
                        Text("\(parts.count) part\(parts.count == 1 ? "" : "s")").dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textTertiary.color)
                    }
                    Spacer()
                    if let project {
                        Button { addPart(project.id) } label: {
                            Label("Add part", systemImage: "plus").font(DS.TypeScale.bodyStrong.font).foregroundStyle(.white)
                                .padding(.horizontal, DS.Space.l).frame(height: 44)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Color.accent.color))
                                .dsShadow(.accentGlow)
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("library-add-part")
                    }
                }
                LazyVGrid(columns: columns, spacing: DS.Space.xl3) {
                    ForEach(parts) { part in
                        LibraryPartCard(model: model, library: library, part: part) { open(part.id) }
                            .contextMenu {
                                Button { renamingPart = (part.id, part.name) } label: { Label("Rename", systemImage: "pencil") }
                                Menu {
                                    ForEach(library.index.projects) { p in Button(p.name) { library.move(part: part.id, to: p.id) } }
                                    Button("Unfiled") { library.move(part: part.id, to: nil) }
                                } label: { Label("Move to", systemImage: "folder") }
                                Button(role: .destructive) { deleting = part } label: { Label("Delete part…", systemImage: "trash") }
                            }
                    }
                    if let project { LibraryNewTile(title: "Add part", detail: nil) { addPart(project.id) } }
                }
                .padding(.top, DS.Space.xl3)
            }
            .padding(.horizontal, DS.Space.page).padding(.top, 34).padding(.bottom, 60)
        }
        .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: Binding(get: { renaming ?? "" }, set: { renaming = $0 }))
            Button("Rename") { if let p = project, let n = renaming { library.rename(project: p.id, to: n) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Rename part", isPresented: Binding(get: { renamingPart != nil }, set: { if !$0 { renamingPart = nil } })) {
            TextField("Name", text: Binding(get: { renamingPart?.name ?? "" }, set: { renamingPart?.name = $0 }))
            Button("Rename") { if let r = renamingPart { library.rename(part: r.id, to: r.name) }; renamingPart = nil }
            Button("Cancel", role: .cancel) { renamingPart = nil }
        }
        .confirmationDialog(deleting.map { "Delete “\($0.name)” and its \($0.versions.count) versions?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let part = deleting { for v in part.versions { model.deleteProject(id: v.folderID) } }
                deleting = nil
                library.refresh()
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("This permanently removes every version and its results. This can’t be undone.")
        }
    }

    private func addPart(_ project: UUID) {
        library.importTargetProject = project
        model.newTopOpt()
    }
}

/// A part card: its picture, name, the H46 line, and a strip of its versions.
struct LibraryPartCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryModel
    let part: LibraryPart
    let open: () -> Void
    var body: some View {
        let newest = part.versions.max { $0.number < $1.number }
        let recent = newest.flatMap { n in model.recentProjects.first { $0.id == n.folderID } }
        let running = part.versions.first { model.runningIDs.contains($0.folderID) }
        Button(action: open) {
            VStack(spacing: 0) {
                LibraryPicture(image: library.partPicture(part)).frame(height: 230).frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(part.name).dsStyle(DS.TypeScale.bodyStrong).lineLimit(1)
                            // #362 H46's behaviour, carried over: a Flexible part names its filament
                            Text(recent.flatMap { FlexibleHomeCard.meta($0) } ?? (recent?.materialName ?? ""))
                                .dsStyle(DS.TypeScale.caption2).foregroundStyle(DS.Color.textTertiary.color).lineLimit(1)
                        }
                        Spacer()
                        if let running {
                            HStack(spacing: DS.Space.xs) { ProgressView().controlSize(.mini); Text("v\(running.number)") }
                                .font(DS.TypeScale.footnote.font).fontWeight(.semibold).foregroundStyle(DS.Color.accent.color)
                                .padding(.vertical, 5).padding(.horizontal, DS.Space.sm)
                                .background(Capsule().fill(DS.Color.accent.opacity(0.14).color))
                        }
                    }
                    HStack(spacing: DS.Space.xxs) {
                        ForEach(part.versions.suffix(8), id: \.folderID) { v in
                            HStack(spacing: 2) {
                                Text("v\(v.number)")
                                if v.marks.contains(where: \.printThis) { Image(systemName: "printer").foregroundStyle(DS.Color.okGreen.color) }
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(library.isDraft(v) ? DS.Color.accentCyan.color : DS.Color.textSecondary.color)
                            .padding(.horizontal, 6).frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 7).fill(DS.Color.fillSubtle.color))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(DS.Color.strokeSubtle.color,
                                                                                    style: StrokeStyle(lineWidth: 1, dash: library.isDraft(v) ? [3, 2] : [])))
                        }
                    }
                }
                .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.ml)
                .overlay(alignment: .top) { Rectangle().fill(DS.Color.strokeSubtle.color).frame(height: 1) }
            }
            .modifier(LibraryCardSurface())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library-part-\(part.name)")
    }
}

// MARK: - 3 · Part folder

enum LibraryFilter: String, CaseIterable { case all, top, print, strong }
enum LibrarySort: String, CaseIterable {
    case newest = "Newest", oldest = "Oldest", rated = "Best rated", lightest = "Lightest", strongest = "Strongest"
}

struct PartFolderView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryModel
    let part: LibraryPart
    let back: () -> Void
    let quickLook: (UUID) -> Void
    let compare: (LibraryCompareRequest) -> Void
    @State private var filter: LibraryFilter = .all
    @State private var sort: LibrarySort = .newest
    @State private var renaming: (folder: UUID, name: String)?
    @State private var deleting: LibraryVersion?

    private let columns = [GridItem(.adaptive(minimum: 380), spacing: DS.Space.xl2)]

    private func best(_ v: LibraryVersion) -> ResultSummary? { v.summary?[safe: library.shownResult(v)] }

    private var cards: [LibraryVersion] {
        let pending = part.versions.filter { library.isDraft($0) || model.runningIDs.contains($0.folderID) }
        var done = part.versions.filter { !library.isDraft($0) && !model.runningIDs.contains($0.folderID) }
        switch filter {
        case .all: break
        case .top: done = done.filter { $0.marks.contains { $0.stars >= 4 } }
        case .print: done = done.filter { $0.marks.contains(where: \.printThis) }
        case .strong: done = done.filter { $0.summary?.contains(where: \.accepted) == true }
        }
        switch sort {
        case .newest: done.sort { $0.number > $1.number }
        case .oldest: done.sort { $0.number < $1.number }
        case .rated: done.sort { ($0.marks.map(\.stars).max() ?? 0, $0.number) > ($1.marks.map(\.stars).max() ?? 0, $1.number) }
        case .lightest: done.sort { (best($0)?.massGrams ?? .infinity) < (best($1)?.massGrams ?? .infinity) }
        case .strongest: done.sort { (best($0)?.worstCaseMargin ?? -1) > (best($1)?.worstCaseMargin ?? -1) }
        }
        return (filter == .all ? pending.sorted { $0.number > $1.number } : []) + done
    }

    private var openTarget: LibraryVersion? {
        part.versions.filter(library.isDraft).max { $0.number < $1.number } ?? part.versions.max { $0.number < $1.number }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DS.Space.ml) {
                    LibraryBackPill(title: library.projectOf(part: part.id)?.name ?? "Unfiled", action: back)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(part.name).dsStyle(DS.TypeScale.titleXL)
                        let done = part.versions.filter { !library.isDraft($0) }.count, drafts = part.versions.count - done
                        Text("\(library.snapshots[part.versions.first?.folderID ?? UUID()]?.material ?? "") · \(done) version\(done == 1 ? "" : "s")\(drafts > 0 ? " + \(drafts) draft\(drafts == 1 ? "" : "s")" : "")")
                            .dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textTertiary.color)
                    }
                    Spacer()
                    Button { compare(LibraryCompareRequest(part: part.id, scope: .all)) } label: {
                        Label("Compare", systemImage: "rectangle.split.2x1").font(DS.TypeScale.bodyStrong.font)
                            .padding(.horizontal, DS.Space.l).frame(height: 44)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Color.fillSubtle.color))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1))
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("library-compare")
                    if let t = openTarget {
                        Button { openFolder(t.folderID) } label: {
                            Text(library.isDraft(t) ? "Open v\(t.number) draft" : "Open v\(t.number)").dsStyle(DS.TypeScale.bodyStrong).foregroundStyle(.white)
                                .padding(.horizontal, DS.Space.l).frame(height: 44)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Color.accent.color))
                                .dsShadow(.accentGlow)
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("library-open")
                    }
                }
                HStack(spacing: DS.Space.sm) {
                    Spacer()
                    SegmentedGlass([.init(LibraryFilter.all, "All"), .init(.top, "★ 4+"), .init(.print, "Print"), .init(.strong, "Strong enough")],
                                   selection: $filter)
                        .frame(maxWidth: 460)
                    Menu {
                        ForEach(LibrarySort.allCases, id: \.self) { s in
                            Button { sort = s } label: { if s == sort { Label(s.rawValue, systemImage: "checkmark") } else { Text(s.rawValue) } }
                        }
                    } label: {
                        Label(sort.rawValue, systemImage: "arrow.up.arrow.down").font(DS.TypeScale.subhead.font).fontWeight(.semibold)
                            .padding(.horizontal, DS.Space.ml).frame(height: 36)
                            .background(Capsule().fill(DS.Color.fillSubtle.color))
                            .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1))
                    }
                    .accessibilityIdentifier("library-sort")
                }
                .padding(.vertical, DS.Space.ml)
                LazyVGrid(columns: columns, spacing: DS.Space.xl2) {
                    ForEach(cards, id: \.folderID) { v in
                        LibraryVersionCard(model: model, library: library, part: part, version: v,
                                           quickLook: { quickLook(v.folderID) },
                                           compareResults: { compare(LibraryCompareRequest(part: part.id, scope: .version(v.folderID))) },
                                           open: { openFolder(v.folderID) },
                                           rename: { renaming = (v.folderID, v.name ?? "") },
                                           delete: { deleting = v })
                    }
                }
                if cards.isEmpty {
                    Text("Nothing here yet.").dsStyle(DS.TypeScale.body).foregroundStyle(DS.Color.textTertiary.color).padding(.top, DS.Space.xl)
                }
            }
            .padding(.horizontal, DS.Space.page).padding(.top, 34).padding(.bottom, 60)
        }
        .alert("Name this version", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Automatic", text: Binding(get: { renaming?.name ?? "" }, set: { renaming?.name = $0 }))
            Button("Save") { if let r = renaming { library.rename(version: r.folder, to: r.name) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { Text("Leave it empty for the automatic name.") }
        .confirmationDialog(deleting.map { "Delete v\($0.number)?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let v = deleting { model.deleteProject(id: v.folderID) }
                deleting = nil
                library.refresh()
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("This permanently removes this version and its results. This can’t be undone.") }
    }

    private func openFolder(_ folder: UUID) {
        if let recent = model.recentProjects.first(where: { $0.id == folder }) { model.open(recent) }
    }
}

/// One version: its picture, a b c, title, what changed, weight · strength, stars, ⋯.
struct LibraryVersionCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryModel
    let part: LibraryPart
    let version: LibraryVersion
    let quickLook: () -> Void
    let compareResults: () -> Void
    let open: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        let v = version
        let running = model.runningIDs.contains(v.folderID)
        let pending = library.isDraft(v) || running
        let r = library.shownResult(v)
        let mark = v.mark(for: r)
        Button(action: pending ? open : quickLook) {
            VStack(spacing: 0) {
                picture(pending: pending, running: running, r: r, mark: mark)
                info(pending: pending, r: r, mark: mark)
                    .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
            }
            .modifier(LibraryCardSurface(dashed: pending))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library-card-v\(v.number)")
    }

    private func picture(pending: Bool, running: Bool, r: Int, mark: ResultMark) -> some View {
        let v = version
        return ZStack(alignment: .topLeading) {
            LibraryPicture(image: pending ? parentPicture : library.thumbnails[CompareItem(folder: v.folderID, result: r)], dim: pending)
                .frame(height: 208).frame(maxWidth: .infinity)
            LibraryStageChip(snapshot: library.snapshots[v.folderID]).padding(DS.Space.sm)
            if pending {
                pendingBadge(running: running).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if mark.printThis {
                    Image(systemName: "printer").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Color.okGreen.color)
                        .frame(width: 28, height: 28).background(Circle().fill(Color.black.opacity(0.6)))
                        .frame(maxWidth: .infinity, alignment: .trailing).padding(DS.Space.sm)
                        .accessibilityLabel("Print this")
                }
                if let n = v.summary?.count, n > 1 {
                    LibraryResultSwitcher(count: n, shown: r, suggested: library.suggestedResult(v),
                                          rejected: Set(v.marks.filter(\.rejected).map(\.result))) {
                        library.pick(folder: v.folderID, result: $0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(DS.Space.sm)
                }
            }
        }
    }

    private func pendingBadge(running: Bool) -> some View {
        HStack(spacing: DS.Space.xs) {
            if running { ProgressView().controlSize(.mini); Text("Running") }
            else { Image(systemName: "pencil"); Text("Not optimized yet") }
        }
        .font(DS.TypeScale.caption.font.weight(.semibold)).foregroundStyle(DS.Color.accent.color)
        .padding(.horizontal, DS.Space.m).frame(height: 30)
        .background(Capsule().fill(DS.Color.accent.opacity(0.14).color))
    }

    private func info(pending: Bool, r: Int, mark: ResultMark) -> some View {
        let v = version
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(library.shortTitle(of: v, in: part)).dsStyle(DS.TypeScale.bodyStrong).lineLimit(1)
            Text(changeLine(v)).dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textSecondary.color).lineLimit(1)
            if pending {
                ForEach(Array(v.changes.prefix(3).enumerated()), id: \.offset) { _, c in changeRow(c) }
            } else {
                LibraryNumbers(summary: v.summary?[safe: r], rejected: mark.rejected)
            }
            footer(pending: pending, r: r, mark: mark)
        }
    }

    private func changeRow(_ c: VersionChange) -> some View {
        Label(c.text, systemImage: c.kind == .added ? "plus.square.fill" : c.kind == .removed ? "minus.square.fill" : "arrow.right.square.fill")
            .font(DS.TypeScale.caption.font).lineLimit(1)
    }

    private func footer(pending: Bool, r: Int, mark: ResultMark) -> some View {
        let v = version
        let date = library.snapshots[v.folderID].map { $0.savedAt.formatted(.dateTime.month(.abbreviated).day()) } ?? ""
        return HStack(spacing: DS.Space.s) {
            if !pending {
                LibraryStars(value: mark.stars, size: 20) { library.setStars($0, folder: v.folderID, result: r) }
            }
            Spacer()
            Text(date).dsStyle(DS.TypeScale.caption2).foregroundStyle(DS.Color.textTertiary.color)
            Menu { menu(r: r, mark: mark, pending: pending) } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 12).fill(DS.Color.fillSubtle.color))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1))
            }
            .accessibilityIdentifier("library-card-menu-v\(v.number)")
        }
    }

    @ViewBuilder private func menu(r: Int, mark: ResultMark, pending: Bool) -> some View {
        let v = version
        if !pending {
            Button(action: quickLook) { Label("Quick look", systemImage: "eye") }
            if (v.summary?.count ?? 0) > 1 { Button(action: compareResults) { Label("Compare its results", systemImage: "rectangle.split.3x1") } }
            Button { library.togglePrint(folder: v.folderID, result: r) } label: {
                Label(mark.printThis ? "Not for print" : "Print this", systemImage: "printer")
            }
            Button { library.toggleReject(folder: v.folderID, result: r) } label: {
                Label(mark.rejected ? "Not rejected" : "Reject", systemImage: "xmark.circle")
            }
        }
        Button(action: open) { Label("Open v\(v.number)", systemImage: "arrow.up.forward.app") }
        // #362 H51's behaviour, carried over: Duplicate is now "New draft from vN" (H52 unchanged)
        Button {
            _ = model.duplicateProject(id: v.folderID)
            library.refresh()
        } label: { Label("New draft from v\(v.number)", systemImage: "plus.square.on.square") }
        Button(action: rename) { Label("Rename…", systemImage: "pencil") }
        Button(role: .destructive, action: delete) { Label("Delete v\(v.number)…", systemImage: "trash") }
    }

    private var parentPicture: CGImage? {
        guard let p = version.parentNumber.flatMap(part.version(number:)) else { return nil }
        return library.thumbnails[CompareItem(folder: p.folderID, result: library.shownResult(p))]
    }

    private func changeLine(_ v: LibraryVersion) -> String {
        let from = v.parentNumber.map { "from v\($0)" } ?? "first run"
        guard let first = v.changes.first else { return v.parentNumber == nil ? from : "\(from): same settings" }
        return "\(from): \(first.text)\(v.changes.count > 1 ? " +\(v.changes.count - 1)" : "")"
    }
}

// MARK: - 9 · First launch

struct FirstLaunchGroupingView: View {
    @ObservedObject var library: LibraryModel
    let close: () -> Void
    @State private var proposal = LibraryIndex()
    @State private var open: UUID?
    @State private var ticked: Set<UUID> = []
    @State private var projectName = ""
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Your projects, sorted into parts").dsStyle(DS.TypeScale.titleXL)
                    Text("Copies with the same model file become versions of one part. Nothing is moved or deleted.")
                        .dsStyle(DS.TypeScale.callout).foregroundStyle(DS.Color.textSecondary.color)
                }
                HStack(alignment: .top, spacing: DS.Space.xl2) {
                    ScrollView {
                        VStack(spacing: DS.Space.sm) { ForEach(proposal.parts) { partRow($0) } }
                    }
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        Text("Put them in a project").dsStyle(DS.TypeScale.bodyStrong)
                        ForEach(proposal.parts) { p in
                            Button { if ticked.contains(p.id) { ticked.remove(p.id) } else { ticked.insert(p.id) } } label: {
                                HStack(spacing: DS.Space.sm) {
                                    Image(systemName: ticked.contains(p.id) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(ticked.contains(p.id) ? DS.Color.accent.color : DS.Color.textTertiary.color)
                                    Text(p.name).dsStyle(DS.TypeScale.callout)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        TextField("Project name", text: $projectName)
                            .textFieldStyle(.plain).padding(.horizontal, DS.Space.ml).frame(height: 44)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.3)))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1))
                        Spacer()
                        Text("Library ⋯ → Ungroup undoes this.").dsStyle(DS.TypeScale.caption2).foregroundStyle(DS.Color.textTertiary.color)
                    }
                    .padding(DS.Space.ml).frame(width: 320)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.3)))
                }
                if let error { Text(error).dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.danger.color) }
                HStack {
                    Spacer()
                    Button("Not now") { library.notNow(); close() }
                        .buttonStyle(.plain).font(DS.TypeScale.bodyStrong.font)
                        .padding(.horizontal, DS.Space.l).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 14).fill(DS.Color.fillSubtle.color))
                    Button("Group") {
                        do {
                            try library.group(projectName: ticked.isEmpty ? nil : projectName, partIDs: Array(ticked))
                            close()
                        } catch { self.error = "Not grouped: \(error.localizedDescription)" }
                    }
                    .buttonStyle(.plain).font(DS.TypeScale.bodyStrong.font).foregroundStyle(.white)
                    .padding(.horizontal, DS.Space.xl).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 14).fill(DS.Color.accent.color))
                    .accessibilityIdentifier("library-group")
                }
            }
            .padding(DS.Space.xl5)
            .frame(maxWidth: 1100, maxHeight: 860)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous).fill(DS.Surface.sheet.color))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous).strokeBorder(DS.Color.strokeSheet.color, lineWidth: 1))
            .padding(DS.Space.xl4)
        }
        .onAppear {
            proposal = library.proposal()
            ticked = Set(proposal.parts.filter { $0.versions.count > 1 }.map(\.id))
            open = proposal.parts.first?.id
        }
    }

    private func partRow(_ p: LibraryPart) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button { open = open == p.id ? nil : p.id } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).dsStyle(DS.TypeScale.bodyStrong)
                        Text("\(p.versions.count) project\(p.versions.count == 1 ? "" : "s") → v1–v\(p.versions.count)")
                            .dsStyle(DS.TypeScale.caption2).foregroundStyle(DS.Color.textTertiary.color)
                    }
                    Spacer()
                    Image(systemName: open == p.id ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(.plain)
            if open == p.id {
                ForEach(p.versions, id: \.folderID) { v in
                    HStack {
                        Text(library.snapshots[v.folderID]?.name ?? "").dsStyle(DS.TypeScale.callout).lineLimit(1)
                        Image(systemName: "arrow.right").foregroundStyle(DS.Color.textTertiary.color)
                        Text("v\(v.number)\(library.snapshots[v.folderID].map(LibraryGrouping.isDraft) == true ? " draft" : "")")
                            .dsStyle(DS.TypeScale.callout).fontWeight(.bold)
                        if let n = v.name { Text("“\(n)”").dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textSecondary.color) }
                        Spacer()
                        Text(library.snapshots[v.folderID]?.savedAt.formatted(.dateTime.month(.abbreviated).day()) ?? "")
                            .dsStyle(DS.TypeScale.caption2).foregroundStyle(DS.Color.textTertiary.color)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(DS.Space.ml)
        .modifier(LibraryCardSurface())
    }
}

// MARK: - 10 · Storage

struct LibraryStorageView: View {
    @ObservedObject var library: LibraryModel
    let back: () -> Void
    @State private var confirming = false
    @State private var error: String?

    private func mb(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1_000_000) }

    var body: some View {
        let rows = library.index.parts.flatMap { p in p.versions.filter { !library.isDraft($0) }.map { (part: p, v: $0) } }
        let sizes = Dictionary(rows.map { ($0.v.folderID, library.resultsBytes($0.v.folderID)) }, uniquingKeysWith: { a, _ in a })
        let total = sizes.values.reduce(0, +)
        let trimmable = library.trimmable
        let frees = trimmable.reduce(Int64(0)) { acc, v in
            let n = Int64(max(1, v.summary?.count ?? 1))
            return acc + (sizes[v.folderID] ?? 0) * (n - 1) / n
        }
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack(spacing: DS.Space.ml) {
                    LibraryBackPill(title: "Library", action: back)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Storage").dsStyle(DS.TypeScale.titleXL)
                        Text("Results take \(mb(total)) on this iPad").dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textTertiary.color)
                    }
                    Spacer()
                }
                HStack(alignment: .top, spacing: DS.Space.xl3) {
                    VStack(spacing: 0) {
                        ForEach(library.index.parts) { p in
                            let vs = p.versions.filter { !library.isDraft($0) }
                            if !vs.isEmpty {
                                HStack { Text(p.name).dsStyle(DS.TypeScale.bodyStrong); Spacer() }
                                    .padding(.vertical, DS.Space.s)
                                ForEach(vs, id: \.folderID) { v in
                                    HStack(spacing: DS.Space.ml) {
                                        Text(library.shortTitle(of: v, in: p)).dsStyle(DS.TypeScale.callout).lineLimit(1)
                                        Spacer()
                                        Text(v.trimmed == true ? "picked only" : "a–\(ResultMark.letter(max(0, (v.summary?.count ?? 1) - 1)))")
                                            .dsStyle(DS.TypeScale.caption)
                                            .foregroundStyle(trimmable.contains { $0.folderID == v.folderID } ? DS.Color.warning.color : DS.Color.textSecondary.color)
                                        Text(mb(sizes[v.folderID] ?? 0)).dsStyle(DS.TypeScale.caption).monospacedDigit().frame(width: 80, alignment: .trailing)
                                        if v.trimmed == true || (v.summary?.count ?? 0) <= 1 {
                                            Color.clear.frame(width: 51, height: 31)
                                        } else {
                                            Toggle("Keep all results of v\(v.number)", isOn: Binding(
                                                get: { library.keepsAllResults(v.folderID) },
                                                set: { library.setKeepAll($0, folder: v.folderID) }))
                                                .labelsHidden().tint(DS.Color.okGreen.color)
                                        }
                                    }
                                    .padding(.vertical, 6).padding(.leading, DS.Space.l)
                                    .overlay(alignment: .top) { Rectangle().fill(DS.Color.strokeSubtle.color).frame(height: 1) }
                                }
                            }
                        }
                    }
                    .padding(DS.Space.ml)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.3)))
                    VStack(alignment: .leading, spacing: DS.Space.ml) {
                        Text("Every version keeps its settings, numbers, stars and picture. Rated ★4+, Print this and the newest 2 keep all their results; older ones can keep just the one you picked.")
                            .dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textSecondary.color)
                        if confirming {
                            Text("Keep only the picked result on \(trimmable.count) version\(trimmable.count == 1 ? "" : "s")?").dsStyle(DS.TypeScale.bodyStrong)
                            Text("Re-run brings the others back.").dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textTertiary.color)
                            HStack {
                                Button("Cancel") { confirming = false }.buttonStyle(.plain)
                                    .padding(.horizontal, DS.Space.ml).frame(height: 36)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(DS.Color.fillSubtle.color))
                                Button("Trim") {
                                    for v in trimmable { do { try library.trim(folder: v.folderID) } catch { self.error = "v\(v.number): \(error.localizedDescription)" } }
                                    confirming = false
                                }
                                .buttonStyle(.plain).foregroundStyle(.white)
                                .padding(.horizontal, DS.Space.ml).frame(height: 36)
                                .background(RoundedRectangle(cornerRadius: 12).fill(DS.Color.danger.color))
                                .accessibilityIdentifier("library-trim-confirm")
                            }
                        } else {
                            Button { confirming = true } label: {
                                Text(trimmable.isEmpty ? "Nothing to trim" : "Trim · free \(mb(frees))").dsStyle(DS.TypeScale.bodyStrong).foregroundStyle(.white)
                                    .frame(maxWidth: .infinity).frame(height: 44)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(DS.Color.accent.color))
                            }
                            .buttonStyle(.plain).disabled(trimmable.isEmpty).opacity(trimmable.isEmpty ? 0.45 : 1)
                            .accessibilityIdentifier("library-trim")
                        }
                        if let error { Text(error).dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.danger.color) }
                    }
                    .padding(DS.Space.ml).frame(width: 360)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.3)))
                }
            }
            .padding(.horizontal, DS.Space.page).padding(.top, 34).padding(.bottom, 60)
        }
    }
}

// MARK: - the import sheet's Project row (one new line in ImportSheet.swift)

struct LibraryImportProjectRow: View {
    @ObservedObject var model: AppModel
    var body: some View {
        LibraryImportProjectMenu(library: model.library)
    }
}

private struct LibraryImportProjectMenu: View {
    @ObservedObject var library: LibraryModel
    var body: some View {
        if library.mode == .library {
            let current = library.importTargetProject.flatMap(library.project)
            Menu {
                ForEach(library.index.projects) { p in Button(p.name) { library.importTargetProject = p.id } }
                Button("No project (Unfiled)") { library.importTargetProject = nil }
            } label: {
                HStack {
                    Text("Project").dsStyle(DS.TypeScale.subhead).foregroundStyle(DS.Color.textSecondary.color)
                    Spacer()
                    Label(current?.name ?? "Unfiled", systemImage: "folder").font(DS.TypeScale.bodyStrong.font)
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, DS.Space.ml).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(DS.Color.fillSubtle.color))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1))
            }
            .accessibilityIdentifier("import-project-row")
        }
    }
}
