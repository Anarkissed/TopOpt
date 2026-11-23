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
import Foundation
import SwiftUI
import TopOptDesign

/// The words (five at most each on the button and the card's lines).
enum LatticeMacMakeCopy {
    static let button = "Make print-accurate"
    static let buttonLine = "Made on your Mac"
    static let making = "Making print-accurate"
    static let checking = "Checking its strength"
    static let title = "Making it print-accurate"
    static let cancel = "Cancel"
    static let noMacTitle = "Your Mac isn’t answering"
    static let noMacText = "The print-accurate lattice is made on your Mac. Check that it is on and TopOpt is running "
        + "there, then try again. Or make it here on the iPad: it takes longer."
    static let tryAgain = "Try again"
    static let onIPad = "Make it on the iPad"
    static let opening = "Opening your part"
    static let laying = "Laying the lattice"
    static let printCheck = "Checking it prints"
    static let makingFile = "Making the file"
    static let saving = "Saving the file"
    static let sending = "Sending it to your iPad"
    static let drawing = "Drawing it"
    static let waiting = "Waiting for your Mac"
    static func strengthening(_ round: Int) -> String { round > 0 ? "Strengthening, round \(round)" : "Strengthening it" }

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
        if rest.hasPrefix("opening") || rest.hasPrefix("measuring") { return opening }
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

@MainActor
public final class LatticeMacMake: ObservableObject {
    public static let shared = LatticeMacMake()

    /// The modal is up (from his press until the file is drawn, or the run stops).
    @Published public private(set) var shown = false
    /// The Mac's step, in plain words.
    @Published public private(set) var stage = LatticeMacMakeCopy.waiting
    @Published public private(set) var started: Date?
    /// The print file's lattice is drawn and the Mac still checks its strength (the button says so).
    @Published public private(set) var checking = false
    private(set) var projectID: UUID?
    /// The run he asked for (Try again sends it again).
    var request: RunRequest?
    private var path: String?
    private var cancelAction: (() -> Void)?
    private var events: Task<Void, Never>?
    /// How long the file took to arrive last time, per part (s): the card's "about" next time.
    private var lastSeconds: [String: Double] = [:]

    public init() {}

    func isMaking(_ id: UUID) -> Bool { projectID == id && (shown || checking) }
    var expectedS: Double? { path.flatMap { lastSeconds[$0] } }

    /// His press: the modal up, the run to be sent.
    func begin(project id: UUID, path: String?, cancel: @escaping () -> Void, now: Date = Date()) {
        events?.cancel(); events = nil
        projectID = id; self.path = path; cancelAction = cancel
        started = now; stage = LatticeMacMakeCopy.waiting; checking = false; shown = true
    }

    /// A job was sent to the Mac: its steps are read from the worker's event stream.
    nonisolated func job(_ url: URL) {
        Task { @MainActor in self.follow(url) }
    }

    private func follow(_ url: URL) {
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

    private func said(_ words: String) {
        guard shown else { return }
        stage = words
    }

    /// The file arrived from the Mac: drawing it.
    func fileArrived() { if shown { stage = LatticeMacMakeCopy.drawing } }

    /// The file is drawn: the modal closes; `checkFollows` (a Structural part) keeps the button on "Checking its strength".
    func drawn(checkFollows: Bool, now: Date = Date()) {
        guard shown else { return }
        if let s = started, let path { lastSeconds[path] = now.timeIntervalSince(s) }
        shown = false
        checking = checkFollows
        if !checkFollows { events?.cancel(); events = nil }
    }

    /// The run ended (landed, failed or cancelled): everything goes back.
    func ended() {
        events?.cancel(); events = nil
        shown = false; checking = false; cancelAction = nil; projectID = nil; request = nil
    }

    /// His Cancel on the card.
    func cancel() {
        let c = cancelAction
        ended()
        c?()
    }

    /// Tests only.
    func reset() { ended(); lastSeconds = [:]; started = nil; stage = LatticeMacMakeCopy.waiting }
}

/// The card while the Mac makes the print-accurate lattice: centred over everything, the vines growing, the step, the time.
struct LatticeMacMakeModal: View {
    @ObservedObject var make = LatticeMacMake.shared

    var body: some View {
        if make.shown {
            ZStack {
                Rectangle().fill(Color.black.opacity(0.35)).ignoresSafeArea()
                GlassPanel {
                    VStack(spacing: DS.Space.m) {
                        LatticeMacMakeVines()
                            .frame(width: 220, height: 150)
                            .accessibilityHidden(true)
                        Text(LatticeMacMakeCopy.title).dsStyle(DS.TypeScale.title).foregroundStyle(DS.Color.textPrimary.color)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("mac-make-title")
                        Text(make.stage).dsStyle(DS.TypeScale.body).foregroundStyle(DS.Color.textSecondary.color)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("mac-make-stage")
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(timeLine(ctx.date)).dsStyle(DS.TypeScale.body).monospacedDigit()
                                .foregroundStyle(DS.Color.textSecondary.color)
                                .accessibilityIdentifier("mac-make-time")
                        }
                        PillButton(LatticeMacMakeCopy.cancel, style: .secondary) { make.cancel() }
                            .accessibilityIdentifier("mac-make-cancel")
                    }
                    .padding(DS.Space.xl2)
                    .frame(maxWidth: 420)
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

/// The card's animation: vines growing from the floor, branching as they climb, in the lattice's purple; the newest tips
/// brightest; they fade and grow again, for as long as the card is up.
struct LatticeMacMakeVines: View {
    private static let purple = LatticeStructureColour.interior

    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { g, size in
                let t = ctx.date.timeIntervalSinceReferenceDate
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
