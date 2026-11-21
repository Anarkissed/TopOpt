// LibraryChosenExport.swift — B5 (ledger note 11, Q10, plan.md §B5, mockup #lib-project-export): Export chosen versions.
//
// His words (note 11): "We should then be able to export from the Project page only the chosen versions of any part selected
// and/or all parts in the project." Q10: "Allow for one stl per part or a 3mf for all parts - make a note that the original
// version will be exported for any part without a chosen version." His answers (11-04): "Choose parts…" ticks parts in the
// sheet's own list; a part whose chosen result has a lattice sends its chosen SOLID result, its line saying so.
//
// The project page's Export opens this sheet (§4.11: one choice per row, the list of what goes out, Cancel │ Export). Export
// writes the files off the main thread into a fresh folder and hands them to the share sheet: the chosen result's solid from
// its results file, else the part's original model through the app's own importer (a STEP too).

import SwiftUI
import TopOptDesign

public enum ChosenExportFormat: Hashable { case stlPerPart, oneThreeMF }

/// What one part sends: its chosen result, else its original model.
public struct ChosenExportLine: Equatable, Identifiable {
    public let partID: UUID
    public let name: String
    /// The chosen result ("v7b"); nil: nothing picked, the original model goes out.
    public let tag: String?
    /// Where its file comes from: the chosen version (its results), else the part's newest version (its model).
    public let folder: UUID
    /// The chosen result's index (0 = a); nil for the original.
    public let result: Int?
    /// The chosen version has a lattice: its solid result goes out (his answer, 11-04).
    public let latticed: Bool
    public var id: UUID { partID }

    /// Its line in the list (mockup #lib-project-export; Q10's note).
    public var what: String {
        guard let tag else { return "no version picked · the original goes out" }
        return latticed ? tag + " · picked · the solid result; its lattice exports from its Lattice page" : tag + " · picked"
    }

    /// "Carriage Arms · v7b", "Top motor mount · original": the STL's name, and the 3MF object's.
    public var objectName: String { name + " · " + (tag ?? "original") }
}

enum ChosenExport {
    /// The file line while Choose parts… has nothing ticked (Export waits for a tick).
    static let noneTicked = "Tick the parts to send"
    /// The file line in a project with no parts.
    static let noParts = "This project has no parts yet"

    /// A name the Files app keeps: a slash or a colon becomes a dash.
    static func fileSafe(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The files Export writes: one STL per part ("Carriage Arms · v7b.stl"; a second of one name gets " (2)"), or one
    /// 3MF named for the project. None for no lines.
    static func fileNames(_ lines: [ChosenExportLine], format: ChosenExportFormat, title: String) -> [String] {
        guard !lines.isEmpty else { return [] }
        if format == .oneThreeMF {
            let t = fileSafe(title)
            return [(t.isEmpty ? "Parts" : t) + ".3mf"]
        }
        var used = Set<String>()
        return lines.map { l in
            let stem = fileSafe(l.objectName)
            var name = stem + ".stl", k = 1
            while used.contains(name.lowercased()) { k += 1; name = "\(stem) (\(k)).stl" }
            used.insert(name.lowercased())
            return name
        }
    }

    /// The line under the list (mockup #lib-project-export): '3 files: “Carriage Arms · v7b.stl”, …' or 'One file:
    /// “Squish Mechanism.3mf” with 3 parts'.
    static func fileLine(_ lines: [ChosenExportLine], format: ChosenExportFormat, title: String) -> String {
        let names = fileNames(lines, format: format, title: title)
        guard let first = names.first else { return noneTicked }
        if format == .oneThreeMF { return "One file: “\(first)” with \(lines.count) part\(lines.count == 1 ? "" : "s")" }
        let shown = names.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
        return "\(names.count) file\(names.count == 1 ? "" : "s"): " + shown + (names.count > 3 ? " and \(names.count - 3) more" : "")
    }

    struct Mesh {
        var vertices: [Float]
        var indices: [Int32]
    }

    /// A part whose mesh could not be read: nothing is written.
    struct Unreadable: Error { let name: String; let original: Bool }

    /// One part's mesh: the chosen result's solid (its results file), else the original model (the app's importer).
    static func mesh(_ line: ChosenExportLine, store: ProjectStore, original: ((String) -> ViewerMesh?)?) -> Mesh? {
        if let r = line.result {
            guard let data = store.loadResultsData(id: line.folder), let o = try? OutcomeCodec.decode(data),
                  o.variants.indices.contains(r) else { return nil }
            let v = o.variants[r]
            return v.meshVertices.isEmpty || v.meshIndices.count < 3 ? nil : Mesh(vertices: v.meshVertices, indices: v.meshIndices)
        }
        guard let snap = store.snapshot(id: line.folder),
              let m = original?(store.modelPath(id: line.folder, fileName: snap.modelFileName)), !m.isEmpty else { return nil }
        return Mesh(vertices: m.positions, indices: m.indices.map { Int32(bitPattern: $0) })
    }

    /// Every part's mesh, then the files into `dir`, in the lines' order. A part that can't be read stops it before any
    /// file is written.
    static func write(_ lines: [ChosenExportLine], format: ChosenExportFormat, title: String, into dir: URL,
                      mesh: (ChosenExportLine) -> Mesh?) throws -> [URL] {
        let meshes = try lines.map { l -> Mesh in
            guard let m = mesh(l) else { throw Unreadable(name: l.name, original: l.result == nil) }
            return m
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = fileNames(lines, format: format, title: title)
        switch format {
        case .stlPerPart:
            return try zip(zip(lines, meshes), names).map { pair, name in
                let url = dir.appendingPathComponent(name)
                try MeshExport.binarySTL(vertices: pair.1.vertices, indices: pair.1.indices,
                                         header: MeshExport.header(detail: pair.0.objectName + " · mm"))
                    .write(to: url, options: .atomic)
                return url
            }
        case .oneThreeMF:
            let url = dir.appendingPathComponent(names[0])
            try PartsThreeMF.write(zip(lines, meshes).map { PartsThreeMF.Object(name: $0.objectName, vertices: $1.vertices,
                                                                                 indices: $1.indices) },
                                   title: title)
                .write(to: url, options: .atomic)
            return [url]
        }
    }

    /// What went wrong, in one line for the toast.
    static func failure(_ error: Error) -> String {
        if let u = error as? Unreadable {
            return "Couldn’t export \(u.name): its \(u.original ? "model" : "picked result") can’t be read"
        }
        return "Couldn’t write the files: \(error.localizedDescription)"
    }
}

extension LibraryModel {
    /// Each part's line, in the project's order: its chosen result (★ his "chosen" answer), else its original model.
    func exportLines(_ parts: [LibraryPart]) -> [ChosenExportLine] {
        parts.compactMap { part in
            if let c = chosen(of: part), let tag = chosenTag(part) {
                let s = snapshots[c.folder]
                return ChosenExportLine(partID: part.id, name: part.name, tag: tag, folder: c.folder, result: c.result,
                                        latticed: s?.lattice?.flexible != nil || s?.lattice?.enabled == true)
            }
            guard let newest = part.versions.max(by: { $0.number < $1.number }) else { return nil }
            return ChosenExportLine(partID: part.id, name: part.name, tag: nil, folder: newest.folderID, result: nil,
                                    latticed: false)
        }
    }
}

/// The sheet's card (mockup #lib-project-export, §4.11); the project page presents it over the scrim. Frames:
/// "libraryExportParts", "libraryExportFormat", "libraryExportLine-<name>", "libraryExportTick-<name>" ("…-on" when ticked),
/// "libraryExportCancel", "libraryExportGo".
struct ChosenExportSheet: View {
    @ObservedObject var library: LibraryModel
    let title: String
    let lines: [ChosenExportLine]
    let close: () -> Void
    let export: ([ChosenExportLine], ChosenExportFormat) -> Void
    @State private var choose = false
    @State private var ticked: Set<UUID> = []   // ★ his answer 1 (11-04): ticks in this list; Choose starts with none
    @State private var format = ChosenExportFormat.stlPerPart

    /// Past this many parts the list scrolls (the sheet stays inside the 11″ screen).
    static let shownRows = 6

    private var sent: [ChosenExportLine] { choose ? lines.filter { ticked.contains($0.partID) } : lines }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Export from \(title)").dsStyle(DS.TypeScale.title)
            Text("The picked result of each part").dsStyle(DS.TypeScale.subhead)
                .foregroundStyle(DS.Color.textTertiary.color).padding(.top, 3)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                row("Parts") {
                    SegmentedGlass([.init(false, "All parts (\(lines.count))"), .init(true, "Choose parts…")],
                                   selection: $choose, small: true)
                        .background(DSParts.publish("libraryExportParts"))
                }
                row("Files") {
                    SegmentedGlass([.init(ChosenExportFormat.stlPerPart, "One STL per part"),
                                    .init(ChosenExportFormat.oneThreeMF, "One 3MF (all parts)")],
                                   selection: $format, small: true)
                        .background(DSParts.publish("libraryExportFormat"))
                }
            }
            .padding(.top, DS.Space.xl2)
            list.padding(.top, DS.Space.l)
            Text(lines.isEmpty ? ChosenExport.noParts : ChosenExport.fileLine(sent, format: format, title: title))
                .dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.m)
            HStack(spacing: DS.Space.m) {   // §4.11: Cancel on the left, the one primary bottom-right
                PillButton("Cancel", style: .secondary) { close() }
                    .background(DSParts.publish("libraryExportCancel"))
                Spacer()
                if library.exporting { ProgressView().controlSize(.small) }   // §4.11 running: the primary's ring
                PillButton("Export", style: .primary, isEnabled: !sent.isEmpty && !library.exporting) { export(sent, format) }
                    .background(DSParts.publish("libraryExportGo"))
            }
            .padding(.top, DS.Space.xl5)
        }
        .padding(DS.Space.xl6)
        .frame(width: 540, alignment: .leading)
        .foregroundStyle(DS.Color.textPrimary.color)
    }

    @ViewBuilder private var list: some View {
        let rows = VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { i, l in
                line(l).overlay(alignment: .top) {
                    if i > 0 { Rectangle().fill(DS.Color.strokeSubtle.color).frame(height: 1) }
                }
            }
        }
        Group {
            if lines.count > Self.shownRows {
                ScrollView { rows }.frame(height: CGFloat(Self.shownRows) * 44)
            } else {
                rows
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.30)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// One part: its name, and what goes out (the original's line in the caution colour, as the mockup). With Choose parts…,
    /// a tick at its start; tapping the line ticks it.
    private func line(_ l: ChosenExportLine) -> some View {
        let on = ticked.contains(l.partID)
        return Button {
            guard choose else { return }
            if on { ticked.remove(l.partID) } else { ticked.insert(l.partID) }
        } label: {
            HStack(spacing: DS.Space.m) {
                if choose {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 20))
                        .foregroundStyle(on ? DS.Color.accent.color : DS.Color.textTertiary.color)
                        .background(DSParts.publish("libraryExportTick-\(l.name)" + (on ? "-on" : "")))
                }
                Text(l.name).dsStyle(DS.TypeScale.body).lineLimit(1)
                Spacer(minLength: DS.Space.m)
                Text(l.what).dsStyle(DS.TypeScale.caption)
                    .foregroundStyle((l.tag == nil ? DS.Color.warning : DS.Color.textSecondary).color)
                    .multilineTextAlignment(.trailing).lineLimit(2)
            }
            .padding(.horizontal, DS.Space.ml).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(DSParts.publish("libraryExportLine-\(l.name)"))
        .accessibilityAddTraits(choose && on ? .isSelected : [])
    }

    /// One row: its label (the mockup's srow), its choice at the trailing end, 44 pt tall at least.
    private func row<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(label).dsStyle(DS.TypeScale.body).lineLimit(1)
            Spacer(minLength: DS.Space.m)
            control()
        }
        .frame(minHeight: 44)
    }
}
