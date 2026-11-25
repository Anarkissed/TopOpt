// PrintResolution — ★ his decision 2026-11-25, asked about the sheet types' large print files (an 8 mm gyroid through his whole
// stand is about 9–10 M triangles, about 110 MB as a 3MF): "Offer print resolutions when exporting. Full detail vs medium vs
// coarse. All with information about their file size estimates and resolution."
//
// HOW IT WORKS. core makes a print file at one of three levels (the job's "print_resolution"; lattice_layout_file.hpp, PRINT
// RESOLUTION): Full detail (the file as before), Medium (surface within 0.05 mm) and Coarse (within 0.1 mm). Only how finely the
// surface is written changes: the lattice, its widths, the print check and the strength check are the same at every level.
// Every print file's report carries the three levels (`print_resolution`): each one's resolution line and its size estimated
// from the layout before the file was made, and how long the Mac takes to make it (from this job's own times).
//
// Results' Export (the file's own format) and the ⌃'s "Export as STL" open ONE centred card for a print file: the three levels,
// each with its resolution line, its file size (the made file's own size; the others estimated, scaled by how the made one's
// estimate came out) and, for a level not made yet, how long the Mac takes. The level already made exports at once (as before);
// another is made on the Mac (the same chain as the print file's, no strength check: the lattice is the same) under the
// hexagons' card, then handed to the share sheet. No Mac: a centred pop-up (Try again · Make it on the iPad · Cancel); any stop
// is a centred pop-up in plain words. The state lives here (the shared flow), never as @State on the workspace or on Results.
import Foundation
import SwiftUI
import TopOptDesign
import TopOptKit
import simd

// MARK: - the words

/// The words (five at most under a row; the rest behind the (i)).
public enum PrintResolutionCopy {
    public static let title = "Print resolution"
    /// The level already made: no wait.
    public static let made = "Already made"
    public static let cancel = "Cancel"
    public static let infoTitle = "Print resolution"
    public static let info = "Full detail is the file as the lattice was made. Medium and Coarse write the SAME lattice — "
        + "the same cells, the same strut and wall widths, the same print and strength checks — with a coarser surface: "
        + "within 0.05 mm or 0.1 mm of the true shape instead of 0.02 mm. Struts get fewer flat sides and sheets fewer "
        + "triangles, so the file is smaller and quicker to slice; no strut or wall prints thinner than two lines at any level. "
        + "Sizes of the levels not made yet are estimates from the lattice (usually within a fifth), and another level is made "
        + "on your Mac."
    public static let makingTitle = "Making the print file"
    public static let waiting = "Waiting for your Mac"
    public static let makingFile = "Making the file"
    public static let onThisIPad = "Making it on this iPad"
    public static let failedTitle = "The file couldn\u{2019}t be made"
    public static let failedText = "Your Mac couldn\u{2019}t make this resolution. Try again; if it keeps happening, export Full "
        + "detail instead."
    public static let noMacTitle = "Your Mac isn\u{2019}t answering"
    public static let noMacText = "Another resolution is made on your Mac. Check that it is on and TopOpt is running there, then "
        + "try again. Or make it here on the iPad: it takes longer."
    public static let tryAgain = "Try again"
    public static let onIPad = "Make it on the iPad"
    public static let changedTitle = "This print file is out of date"
    public static let changedText = "The lattice settings changed since this print file was made, so another resolution would "
        + "be a different lattice. Make the print file again, then export."

    /// "7.7 MB", "About 3.1 MB" (estimated).
    public static func size(_ bytes: Int, estimated: Bool) -> String {
        let mb = Double(bytes) / 1_000_000
        let n = mb >= 100 ? String(format: "%.0f MB", mb) : mb >= 1 ? String(format: "%.1f MB", mb)
            : String(format: "%.0f KB", Swift.max(1, Double(bytes) / 1000))
        return estimated ? "About " + n : n
    }
    /// "About 2 min on Mac", "Under a minute on Mac" (five words at most).
    public static func macTime(_ seconds: Double) -> String {
        if seconds < 60 { return "Under a minute on Mac" }
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "About \(m) min on Mac" }
        return String(format: "About %.1f h on Mac", seconds / 3600)
    }
}

// MARK: - what the report says

/// A print file's report's `print_resolution` block (core's file_result_json), with the made file it belongs to.
public struct PrintResolutionFacts: Equatable, Sendable {
    public struct Level: Equatable, Sendable {
        public var id: String        // "full" | "medium" | "coarse"
        public var name: String      // "Full detail"
        public var words: String     // "surface within 0.05 mm"
        public var triangles: Int
        public var stlBytes: Int
        public var threeMFBytes: Int
        public var seconds: Double?  // how long the Mac takes to make it (nil: not known)
    }
    /// The level the file was made at.
    public var made: String
    public var levels: [Level]
    /// The made file: its format ("3mf" | "stl"), bytes and triangles.
    public var madeFormat: String
    public var madeBytes: Int
    public var madeTriangles: Int
    /// The lattice it was made of (a remade level must be the same lattice): cells and struts.
    public var cells: Int
    public var bars: Int
    /// The up the file stands on (its print frame), nil: as placed.
    public var up: SIMD3<Double>?

    public static func decode(_ r: [String: Any]) -> PrintResolutionFacts? {
        guard let b = r["print_resolution"] as? [String: Any], let made = b["level"] as? String,
              let list = b["levels"] as? [[String: Any]], list.count == 3 else { return nil }
        func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
        let levels = list.compactMap { l -> Level? in
            guard let id = l["level"] as? String else { return nil }
            return Level(id: id, name: l["name"] as? String ?? id.capitalized, words: l["words"] as? String ?? "",
                         triangles: int(l["triangles"]), stlBytes: int(l["stl_bytes"]), threeMFBytes: int(l["threemf_bytes"]),
                         seconds: (l["ms"] as? NSNumber).map { $0.doubleValue / 1000 })
        }
        guard levels.count == 3, levels.contains(where: { $0.id == made }) else { return nil }
        let file = (r["file"] as? String) ?? ""
        let layout = r["layout"] as? [String: Any] ?? [:], mesh = r["mesh"] as? [String: Any] ?? [:]
        return PrintResolutionFacts(made: made, levels: levels,
                                    madeFormat: file.lowercased().hasSuffix(".3mf") ? "3mf" : "stl",
                                    madeBytes: int(r["file_bytes"]), madeTriangles: int(mesh["triangles"]),
                                    cells: int(layout["cells"]), bars: int(layout["bars"]),
                                    up: PrintFrameTurn.decode(r["print_frame"])?.up)
    }

    public var madeLevel: Level? { levels.first { $0.id == made } }

    /// A level's file size in `format`: the made file's own (exact: the bytes it has, or a binary STL of its triangles) for the
    /// made level; the others the estimate, scaled by how the made level's own estimate came out (the same part and lattice:
    /// what the model missed there it misses here too).
    public func bytes(_ l: Level, format: String) -> (bytes: Int, estimated: Bool) {
        let stl = format == "stl"
        if l.id == made {
            if format == madeFormat, madeBytes > 0 { return (madeBytes, false) }
            if stl, madeTriangles > 0 { return (84 + 50 * madeTriangles, false) }
        }
        let est = Double(stl ? l.stlBytes : l.threeMFBytes)
        guard let m = madeLevel else { return (Int(est), true) }
        var scale = 1.0
        if !stl, madeFormat == "3mf", madeBytes > 0, m.threeMFBytes > 0 {
            scale = Double(madeBytes) / Double(m.threeMFBytes)
        } else if madeTriangles > 0, m.triangles > 0 {
            scale = Double(madeTriangles) / Double(m.triangles)
        }
        if !scale.isFinite || scale <= 0 { scale = 1 }
        return (Int((est * scale).rounded()), true)
    }

    /// Whether a remade file's report is of the same lattice as this one's (its cells and struts).
    public func sameLattice(_ r: [String: Any]) -> Bool {
        let layout = r["layout"] as? [String: Any] ?? [:]
        return (layout["cells"] as? NSNumber)?.intValue == cells && (layout["bars"] as? NSNumber)?.intValue == bars
    }
}

// MARK: - the job

public enum PrintResolutionJob {
    /// The result's print file job made again at `level` in `format`: its print_resolution and file_format set, standing on the
    /// made file's own up (`up`; none: as placed), and no strength job (the lattice is the same: its check is the result's).
    public static func retarget(_ json: Data, level: String, format: String, up: SIMD3<Double>?) -> Data? {
        guard var o = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        o["print_resolution"] = level
        o["file_format"] = format
        o.removeValue(forKey: "strength_job")
        if let u = up { o["print_frame"] = ["up": [u.x, u.y, u.z]] } else { o.removeValue(forKey: "print_frame") }
        return try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }
}

// MARK: - the flow

/// What the workspace gives the flow: whether a Mac is there, and how to make another level of the shown result's print file.
public struct PrintResolutionHost {
    public var macReady: () -> Bool
    /// The file at `level` in `format` ("3mf" | "stl"), standing on `up`, on the Mac (`onMac`) or this iPad: its bytes and its
    /// report. `isCancelled` is polled; `stage` says the step in plain words.
    public var make: (_ level: String, _ format: String, _ up: SIMD3<Double>?, _ onMac: Bool,
                      _ isCancelled: @escaping @Sendable () -> Bool, _ stage: @escaping @Sendable (String) -> Void)
        async throws -> (file: Data, report: [String: Any])
    public init(macReady: @escaping () -> Bool,
                make: @escaping (String, String, SIMD3<Double>?, Bool, @escaping @Sendable () -> Bool,
                                 @escaping @Sendable (String) -> Void) async throws -> (file: Data, report: [String: Any])) {
        self.macReady = macReady; self.make = make
    }
}

@MainActor
public final class PrintResolutionFlow: ObservableObject {
    public static let shared = PrintResolutionFlow()

    /// RED CONTROL (tests): as before his 11-25 — Export hands out the file made, with no choice.
    public static var controlNoChoice = false

    /// The card's contents while it is up.
    public struct Ask: Equatable {
        public var facts: PrintResolutionFacts
        /// "3mf" | "stl": the format the export writes (Export: the made file's own; ⌃ Export as STL: "stl").
        public var format: String
        /// The file's name without its extension ("Stand-PA12-37pct").
        public var stem: String
    }
    @Published public private(set) var ask: Ask?
    /// The level being made, while its card is up.
    public struct Making: Equatable {
        public var level: PrintResolutionFacts.Level
        public var started: Date
        public var stage: String
        public var expected: Double?
    }
    @Published public private(set) var making: Making?
    /// The file to hand to the share sheet.
    @Published public var share: URL?

    /// The workspace's (set as the page opens).
    public var host: PrintResolutionHost?
    private var exportMade: (() -> Void)?
    private var cancelFlag = CancelFlag()
    private var task: Task<Void, Never>?
    /// Files made this session, by result, level and format.
    private var made: [String: URL] = [:]

    public init() {}

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        func cancel() { lock.lock(); on = true; lock.unlock() }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return on }
    }

    /// Whether Export offers the levels for this result: a print file whose report gives them, its own file kept here.
    public static func offers(_ facts: PrintResolutionFacts?, kept: Bool) -> Bool {
        !controlNoChoice && kept && facts != nil
    }

    /// Export (or ⌃ Export as STL) on a print file: the card. `exportMade` exports the level already made, as before.
    public func open(_ facts: PrintResolutionFacts, format: String, stem: String, exportMade: @escaping () -> Void) {
        guard making == nil else { return }
        ask = Ask(facts: facts, format: format, stem: stem)
        self.exportMade = exportMade
    }

    /// His Cancel (or a tap outside): the card goes; nothing is made.
    public func close() { ask = nil; exportMade = nil }

    /// His pick: the level already made exports at once; another is made (on the Mac when there is one), then exported.
    public func pick(_ id: String) {
        guard let a = ask, let level = a.facts.levels.first(where: { $0.id == id }) else { return }
        let export = exportMade
        close()
        if id == a.facts.made {
            export?()
            return
        }
        let key = cacheKey(a, id)
        if let url = made[key], FileManager.default.fileExists(atPath: url.path) { share = url; return }
        guard let host else {
            AppPopups.shared.show(PrintResolutionCopy.failedTitle, PrintResolutionCopy.failedText, log: "no print resolution host")
            return
        }
        if host.macReady() {
            run(a, level, onMac: true)
        } else {
            AppPopups.shared.choose(PrintResolutionCopy.noMacTitle, PrintResolutionCopy.noMacText,
                                    first: (PrintResolutionCopy.tryAgain, { [weak self] in self?.retry(a, level) }),
                                    second: (PrintResolutionCopy.onIPad, { [weak self] in self?.run(a, level, onMac: false) }),
                                    dismiss: PrintResolutionCopy.cancel)
        }
    }

    private func retry(_ a: Ask, _ level: PrintResolutionFacts.Level) {
        ask = a
        exportMade = nil
        pick(level.id)
    }

    private func cacheKey(_ a: Ask, _ id: String) -> String {
        "\(a.stem)|\(a.facts.madeBytes)|\(a.facts.madeTriangles)|\(id)|\(a.format)"
    }

    /// The level made (on the Mac, or here), checked to be the same lattice, written beside the others and shared.
    private func run(_ a: Ask, _ level: PrintResolutionFacts.Level, onMac: Bool) {
        guard let host else { return }
        cancelFlag = CancelFlag()
        let flag = cancelFlag
        making = Making(level: level, started: Date(), stage: onMac ? PrintResolutionCopy.waiting : PrintResolutionCopy.onThisIPad,
                        expected: onMac ? level.seconds : nil)
        task = Task { [weak self] in
            do {
                let out = try await host.make(level.id, a.format, a.facts.up, onMac, { flag.cancelled }, { words in
                    Task { @MainActor in self?.said(words) }
                })
                guard let self, !flag.cancelled else { return }
                guard a.facts.sameLattice(out.report) else {
                    self.making = nil
                    AppPopups.shared.show(PrintResolutionCopy.changedTitle, PrintResolutionCopy.changedText,
                                          log: "remade lattice differs: \(String(describing: out.report["layout"]))")
                    return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(a.stem + "-" + level.id + "." + a.format)
                try out.file.write(to: url, options: .atomic)
                self.made[self.cacheKey(a, level.id)] = url
                self.making = nil
                self.share = url
            } catch {
                guard let self, !flag.cancelled else { return }
                self.making = nil
                if error is CancellationError { return }
                let why = (error as? LatticeFileRun.Failure)?.description ?? "\(error)"
                if (error as? LatticeFileRun.Failure)?.transient == true || LatticeMacMakeCopy.macStopped(why) {
                    AppPopups.shared.choose(PrintResolutionCopy.noMacTitle, PrintResolutionCopy.noMacText,
                                            first: (PrintResolutionCopy.tryAgain, { [weak self] in self?.retry(a, level) }),
                                            second: (PrintResolutionCopy.onIPad, { [weak self] in self?.run(a, level, onMac: false) }),
                                            dismiss: PrintResolutionCopy.cancel)
                } else {
                    AppPopups.shared.show(PrintResolutionCopy.failedTitle, PrintResolutionCopy.failedText, log: why,
                                          action: (PrintResolutionCopy.tryAgain, { [weak self] in self?.retry(a, level) }))
                }
            }
        }
    }

    func said(_ words: String) { if making != nil { making?.stage = words } }

    /// His Cancel on the making card: the Mac's job is let go (the run polls the flag and deletes it).
    public func cancelMaking() {
        cancelFlag.cancel()
        task?.cancel()
        task = nil
        making = nil
    }

    /// Tests only.
    public func reset() {
        cancelMaking()
        close()
        share = nil
        made = [:]
        host = nil
    }
}

// MARK: - the cards

/// The chooser and the making card, centred over Results; and the share sheet for a level made here.
struct PrintResolutionLayer: View {
    @ObservedObject var flow = PrintResolutionFlow.shared

    var body: some View {
        ZStack {
            if let a = flow.ask { chooser(a) }
            if let m = flow.making { makingCard(m) }
        }
        .sheet(isPresented: Binding(get: { flow.share != nil }, set: { if !$0 { flow.share = nil } })) {
            if let u = flow.share { ShareSheet(items: [u]) }
        }
    }

    private func chooser(_ a: PrintResolutionFlow.Ask) -> some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.35)).ignoresSafeArea()
                .onTapGesture { flow.close() }
            GlassPanel {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    HStack(spacing: DS.Space.xs) {
                        Text(PrintResolutionCopy.title).dsStyle(DS.TypeScale.title)
                            .foregroundStyle(DS.Color.textPrimary.color)
                            .said(PrintResolutionCopy.title)
                        Spacer(minLength: 0)
                        Button { AppPopups.shared.help(PrintResolutionCopy.infoTitle, PrintResolutionCopy.info) } label: {
                            Text("i").font(.system(size: 13, weight: .bold, design: .serif))
                                .foregroundStyle(DS.Color.textTertiary.color)
                                .frame(width: InfoTip.circle, height: InfoTip.circle)
                                .overlay(Circle().strokeBorder(DS.Color.textTertiary.color, lineWidth: 1.2))
                                .frame(width: DSParts.target, height: DSParts.target)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(DSParts.publish("printResolutionInfo"))
                        .accessibilityLabel("About print resolution")
                    }
                    ForEach(a.facts.levels, id: \.id) { l in row(a, l) }
                    HStack {
                        Spacer(minLength: 0)
                        PillButton(PrintResolutionCopy.cancel, style: .secondary) { flow.close() }
                            .fixedSize()
                            .frame(minHeight: DSParts.target)
                            .background(DSParts.publish("printResolutionCancel"))
                    }
                    .padding(.top, DS.Space.xs)
                }
                .padding(DS.Space.xl)
                .frame(width: 420)
            }
            .background(DSParts.publish("printResolutionCard"))
        }
        .transition(.opacity)
        .zIndex(91)
    }

    private func row(_ a: PrintResolutionFlow.Ask, _ l: PrintResolutionFacts.Level) -> some View {
        let size = a.facts.bytes(l, format: a.format)
        let made = l.id == a.facts.made
        let sizeText = PrintResolutionCopy.size(size.bytes, estimated: size.estimated)
        let when = made ? PrintResolutionCopy.made : l.seconds.map(PrintResolutionCopy.macTime) ?? ""
        return Button { flow.pick(l.id) } label: {
            HStack(alignment: .center, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l.name).dsStyle(DS.TypeScale.headline).foregroundStyle(DS.Color.textPrimary.color)
                        .said(l.name)
                    Text(l.words).dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textSecondary.color)
                        .lineLimit(1).saidWhole(l.words)
                }
                Spacer(minLength: DS.Space.s)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(sizeText).dsStyle(DS.TypeScale.bodyStrong).monospacedDigit()
                        .foregroundStyle(DS.Color.textPrimary.color).said(sizeText)
                    if !when.isEmpty {
                        Text(when).dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textSecondary.color)
                            .lineLimit(1).saidWhole(when)
                    }
                }
            }
            .padding(.horizontal, DS.Space.m)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(made ? DS.Color.accent.opacity(0.14).color : DS.Color.textPrimary.opacity(0.06).color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(DSParts.publish("printResolution-" + l.id))
        .accessibilityIdentifier("print-resolution-" + l.id)
    }

    private func makingCard(_ m: PrintResolutionFlow.Making) -> some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.35)).ignoresSafeArea()
            GlassPanel {
                VStack(spacing: DS.Space.m) {
                    LatticeMacMakeAnimation(kind: .cells)
                    Text(PrintResolutionCopy.makingTitle).dsStyle(DS.TypeScale.title)
                        .foregroundStyle(DS.Color.textPrimary.color).said(PrintResolutionCopy.makingTitle)
                    Text(m.level.name + " \u{00B7} " + m.level.words).dsStyle(DS.TypeScale.body)
                        .foregroundStyle(DS.Color.textSecondary.color).said(m.level.name + " \u{00B7} " + m.level.words)
                    Text(m.stage).dsStyle(DS.TypeScale.body).foregroundStyle(DS.Color.textSecondary.color).said(m.stage)
                    LatticeMacMakeBar().frame(width: 220, height: 4).accessibilityHidden(true)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(timeLine(m, ctx.date)).dsStyle(DS.TypeScale.body).monospacedDigit()
                            .foregroundStyle(DS.Color.textSecondary.color)
                    }
                    PillButton(PrintResolutionCopy.cancel, style: .secondary) { flow.cancelMaking() }
                        .fixedSize()
                        .frame(minHeight: DSParts.target)
                        .background(DSParts.publish("printResolutionMakingCancel"))
                }
                .padding(DS.Space.xl2)
                .frame(maxWidth: 480)
            }
            .padding(DS.Space.xl)
            .background(DSParts.publish("printResolutionMaking"))
        }
        .transition(.opacity)
        .zIndex(92)
    }

    private func timeLine(_ m: PrintResolutionFlow.Making, _ now: Date) -> String {
        let gone = now.timeIntervalSince(m.started)
        guard let e = m.expected, e > gone else { return LatticeMacMakeCopy.clock(gone) }
        return LatticeMacMakeCopy.clock(gone) + " of about " + LatticeMacMakeCopy.clock(e)
    }
}
