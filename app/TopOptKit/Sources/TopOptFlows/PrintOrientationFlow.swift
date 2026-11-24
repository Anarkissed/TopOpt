// PrintOrientationFlow — ★ notes27 P6 + P7 (builder H; his print orientation 11-23, SPEC 2d).
//
// His flow, in his words (11-23 ~17:10): Results offers "Print orientation recommendation"; the same as now → pop-up "best
// orientation"; else → "a new orientation may have stronger results"; OK → Results ANIMATES to the new orientation, with a
// Cancel button top-left BELOW the "Structural" menu (returns the old position); then a "Check strength" button bottom-right
// with a "Manual orientation" option next to it. Manual → he selects a face to be on the print bed. Check strength → pop-up
// with a processing animation → modal with the breakdown of the new orientation's benefits vs the previous; buttons Keep
// orientation / Cancel; Keep → Results with the new orientation and all the new data; Cancel → the old Results.
//
// ★ notes28 (his iPad notes on release 18): "'Cancel' cuts below the 'Structural' menu row... Let's put it to the left of 'Manual
// orientation'" — Cancel is in the bottom row now; Manual orientation draws Bambu Studio's patches (PrintOrientationPatches)
// and stays open after a pick; Check strength stands the result's own lattice (PrintCheckInputs) and says every stop plainly.
//
// The state lives here (never as @State on the workspace). A candidate shown is a VIEW: nothing about the project changes until
// "Keep orientation" (a question is not a decision); Keep sets the face, which makes the next version holding the new result
// (his 11-23 version rule). "Check strength" re-runs the right chain on the Mac (P7, PrintCheckJobs): an Organic lattice its
// strengthening and print file standing on the face, a cell lattice its print file, a topology result core's re-check.
import Foundation
import Combine
import SwiftUI
import simd
import TopOptKit

/// One way the part could stand.
public struct PrintPick: Equatable, Sendable {
    public var up: SIMD3<Double>
    public var onEdge: Bool
    /// The engine's recommendation (else his own pick).
    public var recommended: Bool
    public init(up: SIMD3<Double>, onEdge: Bool, recommended: Bool) { self.up = up; self.onEdge = onEdge; self.recommended = recommended }
}

/// What the workspace gives the flow: the result's kind, how to run its check on the Mac, and how to keep it.
public struct PrintOrientationHost {
    public var kind: PrintCheckKind
    /// Whether a Mac is there to run the check on.
    public var macReady: () -> Bool
    /// The check along `up` for the shown result (`variant`: the topology result's selected one; its STL). Runs the Mac's jobs;
    /// `isCancelled` is polled; `stage` says the Mac's step in plain words.
    public var check: (_ up: SIMD3<Double>, _ variant: PrintCheckVariant, _ isCancelled: @escaping @Sendable () -> Bool,
                       _ stage: @escaping @Sendable (String) -> Void) async throws -> PrintCheckResult
    /// "Keep orientation": the face set (the next version), its result the check's.
    public var keep: (_ up: SIMD3<Double>, _ outcome: OptimizeOutcome) -> Void
    public init(kind: PrintCheckKind, macReady: @escaping () -> Bool,
                check: @escaping (SIMD3<Double>, PrintCheckVariant, @escaping @Sendable () -> Bool, @escaping @Sendable (String) -> Void) async throws -> PrintCheckResult,
                keep: @escaping (SIMD3<Double>, OptimizeOutcome) -> Void) {
        self.kind = kind; self.macReady = macReady; self.check = check; self.keep = keep
    }
}

@MainActor
public final class PrintOrientationFlow: ObservableObject {
    public static let shared = PrintOrientationFlow()

    public enum Phase: Equatable, Sendable { case placed, asked, proposed, manual, checking, compare }
    /// The centred pop-up (spec 2d `asked`).
    public struct Ask: Equatable, Sendable {
        public var title: String
        public var caption: String
        /// The estimate's numbers, behind its (i).
        public var info: [String]
        /// A new orientation is proposed (OK / Not now); else Best orientation (OK).
        public var change: Bool
    }

    @Published public private(set) var phase: Phase = .placed
    /// The way shown while the flow is open (nil: as the result prints).
    @Published public private(set) var shown: PrintPick?
    /// The part animates to the way shown, and back (only while the flow moves it: a version switch snaps).
    @Published public private(set) var animating = false
    @Published public private(set) var ask: Ask?
    @Published public private(set) var stage = LatticeMacMakeCopy.waiting
    @Published public private(set) var started: Date?
    @Published public private(set) var result: PrintCheckResult?
    @Published public private(set) var hull: PrintHull?
    /// ★ notes28 (his img 81, Bambu Studio's Lay on face): what Manual orientation draws to tap — each hull face a flat patch,
    /// each edge rest its own small bevel face (made with the hull).
    public private(set) var patches: PrintPatches?
    /// ★ notes28: the patch under his finger (or the pointer), drawn brighter.
    @Published public private(set) var under: PrintPatches.Target?
    /// ★ notes28: the part turning to the patch he picked (Manual stays open; its patches come back in the new pose).
    @Published public private(set) var turning = false
    private var turnTask: Task<Void, Never>?
    public private(set) var kind: PrintCheckKind = .topology
    private var ranking: PrintOrientationRanking?
    private var cancelFlag = CancelFlag()
    private var task: Task<Void, Never>?
    private var hullTask: Task<Void, Never>?
    private var backTask: Task<Void, Never>?

    public init() {}

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        func cancel() { lock.lock(); on = true; lock.unlock() }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return on }
    }

    /// The flow is open (the part may be shown another way; the corner offers the check).
    public var open: Bool { phase != .placed }
    /// The corner's "Check strength" + "Manual orientation" stand in Export's place.
    public var ownsCorner: Bool { phase == .proposed || phase == .manual }

    /// The turn the part is drawn with while the flow shows another way (nil: the result's own).
    public func shownUp() -> SIMD3<Float>? {
        guard open, let s = shown else { return nil }
        return SIMD3<Float>(Float(s.up.x), Float(s.up.y), Float(s.up.z))
    }

    // MARK: his taps

    /// "Print orientation" (the ⌃ drawer, or the Checks row's link): the pop-up from the engine's ranking; a result with no
    /// ranking (a topology result: core ranks a print file's faces) goes straight to Manual orientation.
    public func start(kind: PrintCheckKind, ranking: PrintOrientationRanking?, mesh: (vertices: [Float], indices: [Int32])?) {
        reset()
        self.kind = kind
        self.ranking = ranking
        makeHull(mesh)
        guard let r = ranking else { phase = .manual; animating = true; return }
        if r.mayBeStronger, let rec = r.recommendation {
            ask = Ask(title: PrintOrientationWords.newTitle, caption: r.why.first ?? "", info: PrintOrientationWords.estimateLines(r, rec),
                      change: true)
        } else {
            ask = Ask(title: PrintOrientationWords.bestTitle, caption: PrintOrientationWords.bestCaption,
                      info: PrintOrientationWords.estimateLines(r, r.asPlaced), change: false)
        }
        phase = .asked
    }

    /// OK on the pop-up: a new orientation animates in (proposed); the best one closes.
    public func okay() {
        guard phase == .asked, let a = ask else { return }
        ask = nil
        guard a.change, let rec = ranking?.recommendation else { phase = .placed; return }
        animating = true
        shown = PrintPick(up: rec.up, onEdge: rec.rests == .edge, recommended: true)
        phase = .proposed
    }

    /// "Not now": nothing changes.
    public func notNow() { ask = nil; phase = .placed }

    /// Cancel (top-left): the part animates back; nothing changed.
    public func cancel() {
        cancelFlag.cancel()
        task?.cancel(); task = nil
        ask = nil; result = nil
        let wasShown = shown != nil
        shown = nil
        under = nil; turning = false; turnTask?.cancel(); turnTask = nil   // ★ notes28
        phase = .placed
        LatticeMacMake.idleTimer(disabled: false)
        if wasShown { settleBack() } else { animating = false }
    }

    /// "Manual orientation": his faces and edges to tap.
    public func manual() {
        guard phase == .proposed || phase == .manual else { return }
        animating = true
        phase = .manual
    }

    /// A tap on a face or an edge: the part animates to it, or, where it would tip, a centred pop-up says so.
    public func pick(face f: PrintHull.Face) {
        guard phase == .manual else { return }
        guard hull?.stands(on: f) ?? true else {
            AppPopups.shared.show(PrintOrientationWords.wouldTipTitle, PrintOrientationWords.wouldTipText)
            return
        }
        choose(PrintPick(up: f.up, onEdge: false, recommended: false))
    }
    public func pick(edge e: PrintHull.Edge) {
        guard phase == .manual else { return }
        // core's stand rule for that edge, where its ranking has it (an edge it cannot hold even with supports would tip)
        if let c = ranking?.candidates.first(where: { $0.rests == .edge && simd_dot(simd_normalize($0.up), e.up) > 0.9998 }), !c.stands {
            AppPopups.shared.show(PrintOrientationWords.wouldTipTitle, PrintOrientationWords.wouldTipText)
            return
        }
        choose(PrintPick(up: e.up, onEdge: true, recommended: false))
    }
    /// ★ notes28 (as Bambu Studio's Lay on face): the part turns to it and Manual stays open — its patches come back once the
    /// part has turned, the picked one outlined; Check strength (or another patch) from there.
    func choose(_ p: PrintPick) {
        animating = true
        shown = p
        under = nil
        if phase == .manual { settleTurn() } else { phase = .proposed }
    }

    /// ★ notes28: a patch under his finger (nil: lifted), or the pointer over it.
    public func press(_ t: PrintPatches.Target?) { if under != t { under = t } }
    public func hover(_ t: PrintPatches.Target, _ on: Bool) {
        if on { press(t) } else if under == t { under = nil }
    }

    /// The patches hide while the part turns (the viewer's 0.8 s), then show in its new pose.
    private func settleTurn() {
        turning = true
        turnTask?.cancel()
        turnTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.turnNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.turning = false
        }
    }
    static var turnNanoseconds: UInt64 = 900_000_000

    /// "Check strength": the processing pop-up while the Mac re-runs the chain standing this way; then the benefits modal.
    public func check(host: PrintOrientationHost, variant: PrintCheckVariant) {
        guard let pick = shown, phase == .proposed || phase == .manual else { return }
        guard host.macReady() else {
            AppPopups.shared.show(PrintOrientationWords.noMacTitle, PrintOrientationWords.noMacText,
                                  action: (title: PrintOrientationWords.tryAgain, run: { [weak self] in self?.check(host: host, variant: variant) }))
            return
        }
        let flag = CancelFlag()
        cancelFlag = flag
        phase = .checking
        started = Date()
        stage = LatticeMacMakeCopy.waiting
        LatticeMacMake.idleTimer(disabled: true)   // the iPad stays awake while its Mac works (the chain goes on either way)
        task = Task { [weak self] in
            do {
                let r = try await host.check(pick.up, variant, { flag.cancelled }) { words in
                    Task { @MainActor [weak self] in if self?.phase == .checking { self?.stage = words } }
                }
                guard let self, !flag.cancelled else { return }
                LatticeMacMake.idleTimer(disabled: false)
                self.result = r
                self.phase = .compare
            } catch {
                guard let self, !flag.cancelled else { return }
                LatticeMacMake.idleTimer(disabled: false)
                self.phase = .proposed
                AppPopups.shared.show(PrintOrientationWords.failedTitle, PrintOrientationWords.failedText(Self.plain(error)),
                                      log: "\(error)")
            }
        }
    }

    /// Cancel on the processing pop-up: the Mac's jobs stopped (the runs delete them), back to the way proposed.
    public func stopCheck() {
        cancelFlag.cancel()
        task?.cancel(); task = nil
        LatticeMacMake.idleTimer(disabled: false)
        phase = .proposed
    }

    /// "Keep orientation": the face set — the next version, holding the new result. The part stays as shown.
    public func keep(host: PrintOrientationHost) {
        guard phase == .compare, let r = result else { return }
        host.keep(r.up, r.outcome)
        result = nil; ask = nil; shown = nil
        phase = .placed
        animating = false
    }

    /// "Cancel" on the benefits modal: the check's outputs dropped, the part animates back, nothing changed.
    public func discard() { cancel() }

    /// A new result on screen (another version, the screen gone): everything back, at once.
    public func reset() {
        cancelFlag.cancel()
        task?.cancel(); task = nil
        hullTask?.cancel(); hullTask = nil
        backTask?.cancel(); backTask = nil
        if phase == .checking { LatticeMacMake.idleTimer(disabled: false) }
        phase = .placed; shown = nil; ask = nil; result = nil; hull = nil; animating = false; ranking = nil
        patches = nil; under = nil; turning = false; turnTask?.cancel(); turnTask = nil   // ★ notes28
    }

    // MARK: the rest

    private func settleBack() {
        backTask?.cancel()
        backTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled, self.phase == .placed else { return }
            self.animating = false
        }
    }

    private func makeHull(_ mesh: (vertices: [Float], indices: [Int32])?) {
        guard let m = mesh, !m.vertices.isEmpty else { return }
        hullTask = Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) { () -> (PrintHull?, PrintPatches?) in
                let h = PrintHull.of(vertices: m.vertices, indices: m.indices)
                return (h, h.map(PrintPatches.of))   // ★ notes28: its patches to tap, made with it
            }.value
            guard let self, !Task.isCancelled else { return }
            self.patches = made.1
            self.hull = made.0
        }
    }

    /// ★ notes28 (his img 82 showed "notLaid"): every error in plain words, never a Swift name (`PrintOrientationWords.plain`).
    static func plain(_ e: Error) -> String { PrintOrientationWords.plain(e) }

    /// Tests only: a result as if a check had landed.
    func land(_ r: PrintCheckResult) { result = r; phase = .compare }
}
