// LatticeMacMake — ★ his 11-22: "Can you make the Mac send the lattice over to the iPad after it's done? Would it be faster
// that way? Because I'd like a 'print accurate' version available. But it doesn't matter where it's made"
//
// HIS DECISIONS (question cards, 11-22 ~23:30 and ~23:50 EST):
//   1. "Yes, but only when the user presses the "Lattice print accurate" button (or named something similar to indicate that
//      there would be another step in between). Please add a nice modal saying it's generating with some animation attached"
//   2. Mac unreachable: a centred pop-up "with the option to "try again", cancel, or make it on the iPad".
//   3. "Check right after": the Mac sends the lattice as soon as its file is saved and checks its strength straight away in
//      the same run; Approved waits only for what is left.
//   4. The ⌃ "Print-accurate preview" switch stays (it makes the iPad lay the exact lattice on every refresh: a different thing).
//
// So: with a Draft on screen the Lattice button reads "Make print-accurate" · "Made on your Mac". Its press sends the print
// file's job from the Draft's own groups (no iPad exact lay) and shows this modal: a growing-vines animation, the Mac's step in
// plain words, the time. The moment the Mac has saved the file the iPad fetches it and draws it in place of the Draft
// (`LatticeLayoutPreview.showFile`); the modal closes and the button reads "Checking its strength" until the run lands
// (Approved, or today's Results when it does not pass). The state lives here, never as @State on the workspace.
//
// ★ notes25 (his iPad notes 11-23, Img 1): "When making a print-accurate version there are *two* pop-ups, one behind the other.
// There should only be one. When the animated pop-up finishes, the one in the background continues. There should only be a
// single pop-up that contains everything - including a "Run in the Background" and "Cancel" button." The one behind was the
// run's own progress card (RunScreen's), up for the whole of the Mac's run, which went on to check the strength after this
// card closed. Now THIS card is the chain's one pop-up from his press until the run ends: the vines, the step (the Mac's
// laying, strengthening, the file, then the check), one clock, and "Run in the Background" · "Cancel". The run's own card and
// its top-lane pill stay away while it carries the run (`covers`, read by RunScreen). "Run in the Background" hides it; the
// Lattice button keeps its ring and words, and its tap brings the same card back. Cancel stops the whole chain.
// ★ notes25 (his Img 4: "With "Print-accurate Preview" selected, and the "exact" laid down, it still says "Make print
// accurate" ... The button should just say "Lattice""): with the print-accurate lattice already on screen (the iPad's exact,
// current; or the Mac's file) the press is the same Mac run, its card and button saying the print file, never
// "print-accurate" again (`fileOnly`; `LatticeMacStep`).
import Foundation
import Combine
import SwiftUI
import TopOptDesign
import TopOptKit
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

/// The words (five at most each on the button and the card's lines).
enum LatticeMacMakeCopy {
    static let button = "Make print-accurate"
    static let buttonLine = "Made on your Mac"
    static let making = "Making print-accurate"
    static let checking = "Checking its strength"
    static let title = "Making it print-accurate"
    static let cancel = "Cancel"
    /// ★ notes25 (his words, Img 1).
    static let background = "Run in the Background"
    /// ★ notes25: the card's title when the lattice on screen is print-accurate already (the print file is all that is made).
    static let fileTitle = "Making the print file"
    static let noMacTitle = "Your Mac isn’t answering"
    static let noMacText = "The print-accurate lattice is made on your Mac. Check that it is on and TopOpt is running "
        + "there, then try again. Or make it here on the iPad: it takes longer."
    static let tryAgain = "Try again"
    static let onIPad = "Make it on the iPad"
    static let opening = "Opening your part"
    static let measuring = "Measuring your part"   // ★ notes25
    /// ★ notes25: the print check's try, as text (never a fraction of the tries it may take).
    static func printCheckTry(_ n: Int) -> String { "Checking it prints \u{00B7} try \(n)" }
    static let laying = "Laying the lattice"
    static let printCheck = "Checking it prints"
    static let makingFile = "Making the file"
    static let saving = "Saving the file"
    static let sending = "Sending it to your iPad"
    static let drawing = "Drawing it"
    static let waiting = "Waiting for your Mac"
    /// ★ notes29: made on this iPad, it waits for a Flexible solve to leave core first (one solve at a time in the app).
    static let waitingForFlexible = RunCardWords.waitingForFlexible
    static func strengthening(_ round: Int) -> String { round > 0 ? "Strengthening, round \(round)" : "Strengthening it" }

    /// ★ notes25 (A5, his 11-23 evening: the cell lattice's print file stopped on the Mac after ~7 min): a stop never just
    /// vanishes — a centred pop-up says what is wrong and what to do.
    static let failedTitle = "The print file couldn\u{2019}t be made"
    static func failedText(_ engine: String?, onMac: Bool) -> String {
        let w = engine?.lowercased() ?? ""
        if w.contains("bridge") || w.contains("span") {
            return "Part of the lattice would bridge farther than your printer can span. Try smaller cells, or another "
                + "lattice type, then press Lattice again."
        }
        if onMac, macStopped(engine) {
            return "Your Mac stopped answering. Check that it is on and TopOpt is running there, then press Lattice again."
        }
        return (onMac ? "Your Mac couldn\u{2019}t finish it." : "This iPad couldn\u{2019}t finish it.")
            + " Press Lattice again; if it keeps happening, tell us."
    }

    /// The Mac's own line ("organic-strengthen: round 2: checking its strength", "lattice-file: saving the file") in plain
    /// words; nil for a line that is not a step.
    static func stage(_ line: String) -> String? {
        let l = line.lowercased()
        guard let colon = l.firstIndex(of: ":") else { return nil }
        let tool = l[..<colon], rest = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if tool == "organic-strengthen" {
            if rest.hasPrefix("opening") { return opening }
            if rest.hasPrefix("laying") { return laying }
            if rest.hasPrefix("checking the lattice prints") { return printCheck }
            if rest.hasPrefix("round") {
                let n = Int(rest.dropFirst(5).drop { $0 == " " }.prefix { $0.isNumber }) ?? 0
                return strengthening(n + 1)
            }
            return nil
        }
        guard tool == "lattice-file" else { return nil }
        if rest.hasPrefix("opening") { return opening }
        if rest.hasPrefix("measuring") { return measuring }   // ★ notes25
        if rest.hasPrefix("checking it prints") {   // ★ notes25: "checking it prints: try 3 of at most 10" → its try, as words
            let n = rest.range(of: "try ").map { Int(rest[$0.upperBound...].prefix { $0.isNumber }) ?? 0 } ?? 0
            return n > 0 ? printCheckTry(n) : printCheck
        }
        if rest.hasPrefix("laying") { return laying }
        if rest.hasPrefix("making the file") { return makingFile }
        if rest.hasPrefix("saving the file") { return saving }
        if rest.hasPrefix("checking its strength") { return checking }
        return nil
    }

    /// The run stopped because the Mac stopped answering (the worker's own words, LatticeFileRun.Worker).
    static func macStopped(_ why: String?) -> Bool {
        guard let w = why?.lowercased() else { return false }
        return w.contains("did not answer") || w.contains("lost the job on the mac")
    }

    /// "2:14" (and "1:02:05" past an hour).
    static func clock(_ s: TimeInterval) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// ★ notes25 (his Img 4): what the Lattice button is with an Organic lattice on screen — "Make print-accurate" (the Mac makes it
/// print-accurate, then checks it) only while what is drawn is the quick stand-in; with the print-accurate lattice already on
/// screen (the ⌃ "Print-accurate preview" on and the iPad's exact laid for exactly these settings, or the Mac's own file) it is
/// "Lattice", whose press goes straight to the Mac's run for the print file and its check.
enum LatticeMacStep {
    /// The iPad's exact lattice is laid, current, with the ⌃ switch on.
    static func exactOnScreen(printAccurate: Bool, quality: LatticeLayoutSession.Organic.Quality?, current: Bool,
                              laying: Bool) -> Bool {
        printAccurate && quality == .exact && current && !laying
    }
    /// The button reads "Make print-accurate" (its old rule, less an exact or a file already on screen).
    static func makesPrintAccurate(ready: Bool, organic: Bool, laid: Bool, laying: Bool, showsFile: Bool,
                                   exactOnScreen: Bool) -> Bool {
        ready && organic && laid && !laying && !showsFile && !exactOnScreen
    }
}

@MainActor
public final class LatticeMacMake: ObservableObject {
    public static let shared = LatticeMacMake()

    /// ★ notes25: the chain is going — from his press until its run ends (or it stops).
    @Published public private(set) var going = false { didSet { stayAwake() } }
    /// ★ notes25: he sent the card to the background ("Run in the Background"); the Lattice button brings it back.
    @Published public private(set) var inBackground = false
    /// ★ notes25: the chain's run has ended (the card goes at once; the workspace then ends the chain, `ended`).
    @Published private(set) var runOver = false { didSet { stayAwake() } }

    /// ★ notes25 (A6, his Organic run 11-23: 10 minutes lost between the strengthening and the print file — the iPad drives
    /// that chain step by step, and it had locked while he watched the Mac): the iPad stays awake while the chain goes (his
    /// press to the result, a failure or a cancel), and only while the workspace is up.
    @Published public private(set) var keepsAwake = false
    private var workspaceUp = true
    private func stayAwake() {
        let on = going && !runOver && workspaceUp
        guard on != keepsAwake else { return }
        keepsAwake = on
        Self.idleTimer(disabled: on)
    }
    /// THE ONE PLACE the iPad's sleep is held off (the Mac's test host has no idle timer).
    static func idleTimer(disabled: Bool) {
        #if canImport(UIKit) && os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
    /// The workspace appeared (true) or left (false): the iPad sleeps again once it has left.
    func workspace(up: Bool) { workspaceUp = up; stayAwake() }
    /// ★ notes25 (A6): the app came back to the front mid-chain: the Mac's steps are followed again at once (the event stream
    /// broke while the app was away; the run's own polling goes on by itself every 2 s).
    func cameBack() { if going, !runOver, let u = jobURL { follow(u) } }
    private var jobURL: URL?
    /// The card is up: the chain going, not in the background. ★ notes25: ONE card for the whole chain (was: until the file).
    public var shown: Bool { going && !inBackground && !runOver }
    /// The Mac's step, in plain words.
    @Published public private(set) var stage = LatticeMacMakeCopy.waiting
    @Published public private(set) var started: Date?
    /// The print file's lattice is drawn and the Mac still checks its strength (the button and the card say so).
    @Published public private(set) var checking = false
    /// ★ notes25 (A3): the lattice on screen was print-accurate already at his press: the card and the button say the print file.
    @Published public private(set) var fileOnly = false
    /// ★ notes27 (G1, his notes on release 17: "The animation for regular lattices should *show* a regular lattice, and not an
    /// organic one"): the job's lattice kind, which picks the card's animation (Organic's vines, a cell lattice's hexagons).
    public enum Kind: Equatable, Sendable { case organic, cells }
    @Published public private(set) var kind: Kind = .organic
    private(set) var projectID: UUID?
    /// The run he asked for (Try again sends it again).
    var request: RunRequest?
    /// ★ notes25: the run this card carries (its own card stays away while this one is the chain's: `covers`).
    private weak var run: RunModel?
    private var runWatch: AnyCancellable?
    /// ★ notes29: the run waits for a Flexible solve on this iPad (the card's step says so, then its own again).
    private var waitWatch: AnyCancellable?
    private var runSeen = false
    private var path: String?
    private var cancelAction: (() -> Void)?
    private var events: Task<Void, Never>?
    /// How long the file took to arrive last time, per part (s): the card's "about" next time.
    private var lastSeconds: [String: Double] = [:]

    public init() {}

    func isMaking(_ id: UUID) -> Bool { projectID == id && going }
    var expectedS: Double? { path.flatMap { lastSeconds[$0] } }
    /// ★ notes25: the card's title (the print file alone when the lattice on screen is print-accurate already).
    var title: String { fileOnly ? LatticeMacMakeCopy.fileTitle : LatticeMacMakeCopy.title }

    /// ★ notes25: this card carries `run` (RunScreen draws neither its progress card nor its pill for it).
    public func covers(_ run: RunModel) -> Bool { going && self.run === run }

    /// His press: the modal up, the run to be sent. ★ notes25: `run` — the project's run the chain goes on (watched, so the card
    /// goes the moment it ends); `fileOnly` — the print-accurate lattice is on screen already (A3).
    /// ★ notes25 (A5): `onMac` false — made on this iPad (a cell lattice with no Mac): its first step is the file, never "Waiting
    /// for your Mac".
    /// ★ notes27 (G1): `kind` — the job's lattice kind (the card's animation).
    func begin(project id: UUID, path: String?, run: RunModel? = nil, fileOnly: Bool = false, kind: Kind = .organic,
               onMac: Bool = true, cancel: @escaping () -> Void, now: Date = Date()) {
        events?.cancel(); events = nil
        projectID = id; self.path = path; cancelAction = cancel
        started = now; stage = onMac ? LatticeMacMakeCopy.waiting : LatticeMacMakeCopy.makingFile; checking = false
        self.fileOnly = fileOnly
        self.kind = kind
        inBackground = false; runOver = false; runSeen = false
        LatticeFileSpot.shared.clear()   // ★ notes25: a new press: the last refusal's spot goes
        SettingToChange.shared.ask = nil   // ... and the field it asked to change
        self.run = run
        runWatch = run?.$phase.sink { [weak self] ph in   // (the new phase, as it is set)
            MainActor.assumeIsolated {
                guard let self, self.going else { return }
                if ph == .running { self.runSeen = true } else if self.runSeen { self.runOver = true }
            }
        }
        let own = stage
        waitWatch = run?.$waitingForFlexible.removeDuplicates().sink { [weak self] w in
            MainActor.assumeIsolated {
                guard let self, self.going else { return }
                if w { self.stage = LatticeMacMakeCopy.waitingForFlexible }
                else if self.stage == LatticeMacMakeCopy.waitingForFlexible { self.stage = own }
            }
        }
        going = true
    }

    /// A job was sent to the Mac: its steps are read from the worker's event stream.
    nonisolated func job(_ url: URL) {
        Task { @MainActor in self.follow(url) }
    }

    private func follow(_ url: URL) {
        jobURL = url
        events?.cancel()
        events = Task { [weak self] in
            let events = url.appendingPathComponent("events")
            guard let (bytes, _) = try? await URLSession.shared.bytes(from: events) else { return }
            do {
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    guard line.hasPrefix("data:"),
                          let o = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8))) as? [String: Any],
                          o["type"] as? String == "log", let said = o["line"] as? String,
                          let words = LatticeMacMakeCopy.stage(said) else { continue }
                    await MainActor.run { self?.said(words) }
                }
            } catch { return }
        }
    }

    /// The Mac's step said (★ notes25: kept while the card is in the background too, so it comes back saying where it is).
    func said(_ words: String) {
        guard going else { return }
        stage = checking && words != LatticeMacMakeCopy.checking ? stage : words
    }

    /// The file arrived from the Mac: drawing it.
    func fileArrived() { if going { stage = LatticeMacMakeCopy.drawing } }

    /// The file is drawn. ★ notes25: the card STAYS (one card for the whole chain); `checkFollows` (a Structural part): it and
    /// the button say "Checking its strength" until the run lands.
    func drawn(checkFollows: Bool, now: Date = Date()) {
        guard going else { return }
        if let s = started, let path { lastSeconds[path] = now.timeIntervalSince(s) }
        checking = checkFollows
        if checkFollows { stage = LatticeMacMakeCopy.checking }
    }

    /// ★ notes25: "Run in the Background" — the card goes; the run goes on, the Lattice button showing it.
    func sendToBackground() { if going { inBackground = true } }

    /// ★ notes25: the Lattice button's tap while the chain goes — the same card back.
    func reopen() { if going, !runOver { inBackground = false } }

    /// The run ended (landed, failed or cancelled): everything goes back.
    func ended() {
        events?.cancel(); events = nil; jobURL = nil
        runWatch?.cancel(); runWatch = nil; waitWatch?.cancel(); waitWatch = nil; run = nil
        going = false; inBackground = false; runOver = false; runSeen = false
        checking = false; fileOnly = false; cancelAction = nil; projectID = nil; request = nil   // (`kind` stays: each press sets it)
    }

    /// His Cancel on the card.
    func cancel() {
        let c = cancelAction
        ended()
        c?()
    }

    /// Tests only.
    func reset() {
        ended(); workspaceUp = true; stayAwake(); lastSeconds = [:]; started = nil; stage = LatticeMacMakeCopy.waiting; kind = .organic
    }
}

/// The card while the Mac makes the print-accurate lattice: centred over everything, the vines growing, the step, the time.
/// ★ notes25: the chain's ONE card, from his press to the run's end — "Run in the Background" and "Cancel".
struct LatticeMacMakeModal: View {
    @ObservedObject var make = LatticeMacMake.shared

    var body: some View {
        if make.shown {
            ZStack {
                Rectangle().fill(Color.black.opacity(0.35)).ignoresSafeArea()
                GlassPanel {
                    VStack(spacing: DS.Space.m) {
                        LatticeMacMakeAnimation(kind: make.kind)   // ★ notes27 (G1): by the job's lattice kind
                        Text(make.title).dsStyle(DS.TypeScale.title).foregroundStyle(DS.Color.textPrimary.color)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("mac-make-title")
                        Text(make.stage).dsStyle(DS.TypeScale.body).foregroundStyle(DS.Color.textSecondary.color)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("mac-make-stage")
                        // ★ notes25: no real fraction to show — a moving bar with the time, never a made-up share
                        LatticeMacMakeBar().frame(width: 220, height: 4).accessibilityHidden(true)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(timeLine(ctx.date)).dsStyle(DS.TypeScale.body).monospacedDigit()
                                .foregroundStyle(DS.Color.textSecondary.color)
                                .accessibilityIdentifier("mac-make-time")
                        }
                        // ★ notes25 (his Img 1): "Run in the Background" and "Cancel", side by side
                        HStack(spacing: DS.Space.m) {
                            PillButton(LatticeMacMakeCopy.background, style: .secondary) { make.sendToBackground() }
                                .fixedSize()
                                .background(CornerPairStyle.publish("macMakeBackground"))
                                .accessibilityIdentifier("mac-make-background")
                            PillButton(LatticeMacMakeCopy.cancel, style: .secondary) { make.cancel() }
                                .fixedSize()
                                .background(CornerPairStyle.publish("macMakeCancel"))
                                .accessibilityIdentifier("mac-make-cancel")
                        }
                        .padding(.top, DS.Space.xs)
                    }
                    .padding(DS.Space.xl2)
                    .frame(maxWidth: 480)
                }
                .padding(DS.Space.xl)
                .background(CornerPairStyle.publish("macMakeModal"))
            }
            .transition(.opacity)
            .zIndex(90)
        }
    }

    private func timeLine(_ now: Date) -> String {
        let gone = make.started.map { now.timeIntervalSince($0) } ?? 0
        guard let e = make.expectedS, e > gone else { return LatticeMacMakeCopy.clock(gone) }
        return LatticeMacMakeCopy.clock(gone) + " of about " + LatticeMacMakeCopy.clock(e)
    }
}

/// ★ notes25: the card's moving bar — a short light sweeping along a track, for as long as the work goes (it says it is
/// going, never how far: the Mac gives no true share of its steps).
struct LatticeMacMakeBar: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { g, size in
                let t = AppSettings.animationClock(ctx.date)   // ★ notes29: held still with Skip all animations
                let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
                g.fill(track, with: .color(DS.Color.textPrimary.opacity(0.12).color))
                let w = size.width * 0.3
                let x = (t.truncatingRemainder(dividingBy: 1.6) / 1.6) * (size.width + w) - w
                let lit = CGRect(x: x, y: 0, width: w, height: size.height).intersection(CGRect(origin: .zero, size: size))
                if !lit.isNull, lit.width > 0 {
                    g.fill(Path(roundedRect: lit, cornerRadius: size.height / 2), with: .color(DS.Color.accent.color))
                }
            }
        }
    }
}

/// ★ notes27 (G1): the card's animation, by the job's lattice kind — Organic keeps its vines; a cell lattice shows hexagonal
/// cells put one after another. The same size and place on the card, each publishing its own frame (the hosted tests').
struct LatticeMacMakeAnimation: View {
    let kind: LatticeMacMake.Kind
    static let size = CGSize(width: 220, height: 150)

    var body: some View {
        Group {
            switch kind {
            case .organic:
                LatticeMacMakeVines().frame(width: Self.size.width, height: Self.size.height)
                    .background(CornerPairStyle.publish("macMakeVines"))
            case .cells:
                LatticeMacMakeCells().frame(width: Self.size.width, height: Self.size.height)
                    .background(CornerPairStyle.publish("macMakeCells"))
            }
        }
        .accessibilityHidden(true)
    }
}

/// ★ notes27 (G1, his iPad notes 11-23 on release 17: "The animation for regular lattices should *show* a regular lattice, and
/// not an organic one. I picture something like a bunch of hexagons getting put one after another."): a cell lattice's card
/// fills a honeycomb — hexagonal cells, each an outline of struts with a node at every corner, put in place one after another
/// from the floor up (each dropped into its place beside the last), the newest brightest; full, it fades and fills again, for
/// as long as the card is up. The vines' purple, frame and rhythm (it never stops: `TimelineView(.animation)`).
struct LatticeMacMakeCells: View {
    private static let purple = LatticeStructureColour.interior

    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { g, size in Self.draw(g, size: size, t: AppSettings.animationClock(ctx.date)) }   // ★ notes29
        }
    }

    /// One fill and fade (s): it fills for 80 % of it, then fades (as the vines).
    static let cycle = 7.0
    /// The honeycomb: 7 columns of 4 cells (28).
    static let columns = 7, rows = 4
    /// One cell's put (s), from a little above into its place; and how long the newest stays bright once it is down.
    static let drop = 0.45, glow = 0.7
    /// The struts' width and the nodes' radius (pt).
    static let line: CGFloat = 2.6, node: CGFloat = 2.3

    /// The honeycomb laid in `size`, centred (flat-topped cells, the odd columns half a cell lower): the cells' radius (centre
    /// to corner) and their centres in the order they are put — the bottom row first, each row the other way from the last,
    /// so every cell is put beside the one before.
    static func layout(_ size: CGSize) -> (radius: CGFloat, centres: [CGPoint]) {
        let s3 = CGFloat(3).squareRoot(), margin = line + node
        let r = max(1, min((size.width - 2 * margin) / (2 + 1.5 * CGFloat(columns - 1)),
                           (size.height - 2 * margin) / (s3 * (CGFloat(rows) + 0.5))))
        let w = r * (2 + 1.5 * CGFloat(columns - 1)), h = r * s3 * (CGFloat(rows) + 0.5)
        let x0 = (size.width - w) / 2 + r, y0 = (size.height - h) / 2 + r * s3 / 2
        var out: [CGPoint] = []
        for k in 0..<rows {
            let row = rows - 1 - k
            for c in k % 2 == 0 ? Array(0..<columns) : Array((0..<columns).reversed()) {
                out.append(CGPoint(x: x0 + CGFloat(c) * 1.5 * r, y: y0 + CGFloat(row) * s3 * r + (c % 2 == 1 ? s3 * r / 2 : 0)))
            }
        }
        return (r, out)
    }

    /// The moment `t` in its cycle: seconds into it, and the whole's opacity (1 while it fills, then fading to 0).
    static func moment(_ t: TimeInterval) -> (into: Double, fade: Double) {
        let into = t - (t / cycle).rounded(.down) * cycle, phase = into / cycle
        return (into, phase < 0.8 ? 1 : max(0, 1 - (phase - 0.8) / 0.2))
    }

    /// When cell `i` of `n` starts to be put (s into the cycle): evenly through the fill, the last down as the fill ends.
    static func start(_ i: Int, of n: Int) -> Double {
        n <= 1 ? 0 : (cycle * 0.8 - drop) * Double(i) / Double(n - 1)
    }

    /// The cells down in their places at `t` (the tests' measure that the fill moves on and loops).
    static func placed(at t: TimeInterval) -> Int {
        let n = columns * rows, into = moment(t).into
        return (0..<n).filter { into >= start($0, of: n) + drop }.count
    }

    /// One frame at `t`: the cells already down as one honeycomb (one stroke, so a shared strut is drawn once), then each cell
    /// still being put or newly down, on top — dropping in, brightest while new.
    static func draw(_ g: GraphicsContext, size: CGSize, t: TimeInterval) {
        let (r, centres) = layout(size)
        let (into, fade) = moment(t)
        guard fade > 0 else { return }
        let c = purple
        func corners(_ p: CGPoint, _ k: CGFloat) -> [CGPoint] {
            (0..<6).map { i in
                let a = Double(i) * .pi / 3
                return CGPoint(x: p.x + CGFloat(cos(a)) * r * k, y: p.y + CGFloat(sin(a)) * r * k)
            }
        }
        func nodes(_ pts: [CGPoint]) -> Path {
            var n = Path()
            for p in pts { n.addEllipse(in: CGRect(x: p.x - node, y: p.y - node, width: 2 * node, height: 2 * node)) }
            return n
        }
        let strut = StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)
        var down = Path(), downNodes: [CGPoint] = []
        var fresh: [(at: CGPoint, k: CGFloat, ease: Double, bright: Double)] = []
        for (i, p) in centres.enumerated() {
            let since = into - start(i, of: centres.count)
            guard since > 0 else { continue }
            let put = min(1, since / drop), ease = 1 - pow(1 - put, 3)
            let bright = since < drop ? 1 : max(0, 1 - (since - drop) / glow)
            if bright <= 0 {
                let k = corners(p, 1)
                down.addLines(k); down.closeSubpath(); downNodes += k
            } else {
                fresh.append((CGPoint(x: p.x, y: p.y - CGFloat(1 - ease) * r * 0.6), CGFloat(0.6 + 0.4 * ease), ease, bright))
            }
        }
        let settled = Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: fade * 0.75)
        g.stroke(down, with: .color(settled), style: strut)
        g.fill(nodes(downNodes), with: .color(settled))
        for f in fresh {
            let k = corners(f.at, f.k)
            var hex = Path()
            hex.addLines(k); hex.closeSubpath()
            let o = fade * f.ease
            g.fill(hex, with: .color(Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: o * 0.22 * f.bright)))
            let lit = Color(.sRGB, red: c.r + (min(1, c.r + 0.25) - c.r) * f.bright, green: c.g + (min(1, c.g + 0.25) - c.g) * f.bright,
                            blue: c.b + (1 - c.b) * f.bright, opacity: o * (0.75 + 0.25 * f.bright))
            g.stroke(hex, with: .color(lit), style: strut)
            g.fill(nodes(k), with: .color(lit))
        }
    }
}

/// The card's animation: vines growing from the floor, branching as they climb, in the lattice's purple; the newest tips
/// brightest; they fade and grow again, for as long as the card is up.
struct LatticeMacMakeVines: View {
    private static let purple = LatticeStructureColour.interior

    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { g, size in
                let t = AppSettings.animationClock(ctx.date)   // ★ notes29: held still with Skip all animations
                let cycle = 6.0
                let phase = (t.truncatingRemainder(dividingBy: cycle)) / cycle          // 0 → 1, then again
                let grow = min(1, phase / 0.8)                                            // grows for 80 %, then fades
                let fade = phase < 0.8 ? 1 : 1 - (phase - 0.8) / 0.2
                let round = Int(t / cycle)
                for v in 0..<7 {
                    var rng = Self.Seeded(UInt64(round * 31 + v * 7919 + 17))
                    let x0 = size.width * (0.1 + 0.8 * Double(v) / 6) + rng.next(-8, 8)
                    Self.vine(g, from: CGPoint(x: x0, y: size.height), angle: -.pi / 2 + rng.next(-0.25, 0.25),
                              length: size.height * rng.next(0.22, 0.32), width: 3.2, depth: 0, grow: grow, fade: fade,
                              seed: rng.s)
                }
            }
        }
    }

    /// One vine: a gently bending segment, then two branches (four levels), each drawn as far as `grow` has reached.
    private static func vine(_ g: GraphicsContext, from p: CGPoint, angle: Double, length: Double, width: Double, depth: Int,
                             grow: Double, fade: Double, seed: UInt64) {
        var rng = Seeded(seed)   // each branch its own: deeper branches appearing never move the others
        let start = Double(depth) / 4.6, span = 1 / 4.6
        let reach = min(1, max(0, (grow - start) / span))
        guard reach > 0 else { return }
        let bend = rng.next(-0.35, 0.35)
        let end = CGPoint(x: p.x + cos(angle + bend) * length * reach, y: p.y + sin(angle + bend) * length * reach)
        let mid = CGPoint(x: p.x + cos(angle) * length * reach * 0.5, y: p.y + sin(angle) * length * reach * 0.5)
        var path = Path()
        path.move(to: p)
        path.addQuadCurve(to: end, control: mid)
        let c = purple
        let tip = reach < 1 ? 1.0 : 0.75
        g.stroke(path, with: .color(Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: fade * tip)),
                 style: StrokeStyle(lineWidth: width, lineCap: .round))
        if reach < 1 {
            g.fill(Path(ellipseIn: CGRect(x: end.x - width, y: end.y - width, width: 2 * width, height: 2 * width)),
                   with: .color(Color(.sRGB, red: min(1, c.r + 0.25), green: min(1, c.g + 0.25), blue: 1, opacity: fade)))
            return
        }
        guard depth < 4 else { return }
        for side in [-1.0, 1.0] {
            let turn = rng.next(0.35, 0.7), shrink = rng.next(0.62, 0.8)
            vine(g, from: end, angle: angle + bend + side * turn, length: length * shrink, width: max(1, width * 0.72),
                 depth: depth + 1, grow: grow, fade: fade, seed: seed &* 31 &+ (side < 0 ? 1 : 2))
        }
    }

    /// A small repeatable random (the same vines for a whole cycle).
    struct Seeded {
        var s: UInt64
        init(_ seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 | 1 }
        mutating func next(_ lo: Double, _ hi: Double) -> Double {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return lo + (hi - lo) * Double(s % 1_000_000) / 1_000_000
        }
    }
}
