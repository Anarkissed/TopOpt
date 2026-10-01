// FlexibleSquishPlayer — the squish, on a timeline you can play and drag (task
// 2026-09-29-flexible-screens, round 3 batch B; maintainer, verbatim: "Please add a play
// button and/or timeline to drag that moves the squish in and out").
//
// ★ ONE NUMBER. `FlexibleSquishLoop.amount` (0 = rest, 1 = the full design load) is the
// squish; the renderer's flexScale = k × amount moves the dent's vertices AND the lattice's
// walls (FlexibleLatticePass reads the same float), so the two can never drift apart.
//   * play / pause loops rest → full → rest on the Results screen's 2.4 s cosine ease
//     (FlexAnimation), and resumes FROM WHERE IT IS (the phase on the rising half whose
//     ease is the current amount);
//   * dragging the timeline PAUSES and sets the amount directly;
//   * reduced motion: no auto-play (a tap on play still plays — it is his action).
// ★ THE MAIN PAGE'S LOOP RUNS IN THE RENDERER (MeshRenderer+FlexibleLattice.stepFlexibleLoop):
// the loop is a reference the renderer reads every frame, so nothing publishes at 30 fps into
// WorkspacePlaceholder's body; only play / pause / a drag publish (to this control).
// ★ THE LOOK IS THE RESULTS SCREEN'S MORPH PLAYER (ResultsScreen.mediaPlayer): a white 34 pt
// play/pause circle, a Slider tinted DS accent, in a DS.Surface.bar capsule, bottom-centre.
// The ends read "Rest" and the full load ("10 kg"). It never covers a button or a legend:
// its frame is computed (FlexibleLegendPlacement.player) against the page's keep-outs.

import Foundation
import QuartzCore
import SwiftUI
import TopOptDesign
#if canImport(MetalKit)
import MetalKit
#endif

public final class FlexibleSquishLoop: ObservableObject {
    /// The Results screen's flex period (FlexAnimation).
    public static let periodS = 2.4

    @Published public private(set) var playing = false
    /// The amount (0…1) held while paused.
    @Published public private(set) var held: Double = 1
    /// k — the page's ONE exaggeration (FlexibleShownValues). Not published: the renderer reads
    /// it every frame; a change while paused asks for one redraw.
    public var exaggeration: Double = 1 {
        didSet { if oldValue != exaggeration { wake() } }
    }
    /// The clock (tests pin it).
    public var clock: () -> CFTimeInterval = { CACurrentMediaTime() }

    private var anchorTime: CFTimeInterval = 0
    private var anchorPhase: Double = 0

    // ★ BATCH G: "Play all" plays the squeeze groups ONE AFTER ANOTHER — each whole period of the
    // loop (rest → full → rest) is one group's sim; the renderer reads these (never published).
    /// How many sims the loop plays in turn (≥ 1).
    public var sequenceCount = 1
    /// The cycle held while paused (so pause / scrub / play keep the group on screen).
    public private(set) var heldCycle = 0
    /// The sequence entry the renderer shows now (set by the renderer's swap).
    public var shownIndex = 0
    /// ★ BATCH G VERIFICATION: the sim the renderer shows now — PUBLISHED on a change only (once per
    /// "Play all" turn, to this control alone), so the picker says which group plays.
    @Published public private(set) var playingSimID: String?
    func notePlaying(_ id: String?) { if playingSimID != id { playingSimID = id } }

    public init() {}

    /// Whole periods since the anchor (the cycle holds while paused).
    public func cycle(at now: CFTimeInterval) -> Int {
        guard playing else { return heldCycle }
        return Int((anchorPhase + (now - anchorTime) / Self.periodS).rounded(.down))
    }
    /// The sequence entry this cycle plays: cycle mod sequenceCount.
    public func simIndex(at now: CFTimeInterval) -> Int {
        let n = Swift.max(1, sequenceCount)
        return ((cycle(at: now) % n) + n) % n
    }

    /// 0 → 1 → 0 over one period (FlexAnimation's cosine ease).
    public static func ease(_ phase: Double) -> Double { 0.5 - 0.5 * cos(2 * .pi * phase) }
    /// The phase on the RISING half whose ease is `a` (so play resumes from where it is).
    public static func risingPhase(_ a: Double) -> Double {
        acos(1 - 2 * min(1, max(0, a))) / (2 * .pi)
    }

    public func phase(at now: CFTimeInterval) -> Double {
        guard playing else { return Self.risingPhase(held) }
        let p = anchorPhase + (now - anchorTime) / Self.periodS
        return p - p.rounded(.down)
    }

    /// The squish amount now: 0 = rest, 1 = the full design load.
    public func amount(at now: CFTimeInterval) -> Double {
        playing ? Self.ease(phase(at: now)) : held
    }
    public var amount: Double { amount(at: clock()) }

    /// The renderer's flexScale for this frame: k × amount.
    public func scale(at now: CFTimeInterval) -> Float { Float(exaggeration * amount(at: now)) }

    public func play() {
        guard !playing else { return }
        // ★ BATCH G: resume IN the held cycle (the group paused on keeps playing)
        anchorPhase = Double(heldCycle) + Self.risingPhase(held)
        anchorTime = clock()
        playing = true
        wake()
    }

    public func pause() {
        guard playing else { return }
        let now = clock()
        heldCycle = cycle(at: now)
        held = amount(at: now)
        playing = false
        wake()
    }

    /// ★ BATCH G: start the sequence over from REST (a new lattice's sims, a pick while playing):
    /// its first sim, rising from 0 — so a swap never lands mid-squeeze.
    public func restartFromRest(reduceMotion: Bool) {
        heldCycle = 0
        if playing { playing = false }
        held = 0
        if reading { resumeAfterReading = !reduceMotion; wake(); return }
        if reduceMotion { hold(1) } else { play() }
    }

    public func toggle() { playing ? pause() : play() }

    /// A drag on the timeline: pauses and sets the amount directly.
    public func scrub(to a: Double) {
        let v = min(1, max(0, a.isFinite ? a : 0))
        if playing { heldCycle = cycle(at: clock()); playing = false }
        if held != v { held = v }
        wake()
    }

    /// Hold still at `a` (nothing to loop: his live drawing, held at full).
    public func hold(_ a: Double = 1) {
        if playing { heldCycle = cycle(at: clock()); playing = false }
        if held != a { held = a }
        wake()
    }

    /// A fresh lattice: it plays — unless reduced motion, which holds the full squish.
    public func autoPlay(reduceMotion: Bool) {
        if reading { resumeAfterReading = !reduceMotion; hold(1); return }   // it plays when the reading ends
        if reduceMotion { hold(1) } else { play() }
    }

    /// ★ BATCH C VERIFICATION: a legend is READING (drilled in). A reading is pinned where the
    /// map is drawn at the moment of the tap; a playing loop then moved the map out from under
    /// the arrow half the time. While a legend reads, a playing loop holds still at the full
    /// squish; when it stops reading, the loop plays again. A loop he had paused stays put.
    public private(set) var reading = false
    private var resumeAfterReading = false
    public func holdWhileReading(_ on: Bool) {
        guard on != reading else { return }
        reading = on
        if on {
            if playing { resumeAfterReading = true; hold(1) }
        } else if resumeAfterReading {
            resumeAfterReading = false
            play()
        }
    }

    // MARK: the renderer's side (MeshRenderer+FlexibleLattice)

    /// True while the renderer runs continuous frames for this loop.
    var renderingContinuously = false

    #if canImport(MetalKit)
    /// The view whose renderer draws this loop (attached on every drawn frame).
    weak var view: MTKView?
    func attach(_ v: MTKView) { if view !== v { view = v } }
    #endif

    /// Play → continuous frames; a pause, a drag or a new k → one redraw.
    private func wake() {
        #if canImport(MetalKit)
        guard let v = view else { return }
        if playing {
            v.isPaused = false
            v.enableSetNeedsDisplay = false
        } else {
            #if os(iOS)
            v.setNeedsDisplay()
            #elseif os(macOS)
            v.needsDisplay = true
            #endif
        }
        #endif
    }

    /// The timeline's end label: the full design load ("10 kg", "10 kg each"), else "Full load".
    /// ★ BATCH B REVIEW: a SHAPE-ONLY lattice ("no squish predicted") ends "As drawn" — a weight
    /// there read as "at 10 kg it squishes this much", the very prediction its label disowns.
    public static let asDrawn = "As drawn"
    public static func fullLabel(weightsKg: [Double], shapeOnly: Bool = false) -> String {
        if shapeOnly { return asDrawn }
        let w = weightsKg.filter { $0 > 0 }
        guard let first = w.first else { return "Full load" }
        if w.count == 1 { return FlexibleRowCopy.kgText(first) }
        if w.allSatisfy({ abs($0 - first) < 0.05 }) { return FlexibleRowCopy.kgText(first) + " each" }
        return "Full load"
    }
}

/// The control: [▶︎] Rest ——●—— 10 kg, in the Results player's capsule.
/// ★ ROUND 4 (D2): with two or more squeeze groups, a GROUP PICKER — "[● Group 1 ▾]": each
/// group's squeeze (only its faces squish), or "All at once" — and a group that squishes less
/// than it was designed for says so in one line.
/// ★ D2 REVIEW: the picker and that line sit in ONE ROW ABOVE the capsule. Inside the capsule the
/// picker took ~81 pt, and at 11" portrait (the capsule placed at 294 pt) it left the timeline he
/// asked to drag about 32 pt. The capsule now keeps its own width for the timeline (≥ 120 pt at
/// every iPad size — FlexibleSqueezeGroupsReviewUITests), and the picker, outside the capsule's
/// 30 Hz TimelineView, is not redrawn under an open menu.
struct FlexibleSquishPlayer: View {
    @ObservedObject var loop: FlexibleSquishLoop
    let fullLabel: String
    /// The capsule's width (FlexibleLegendPlacement.player); the slider takes what is left.
    var width: CGFloat = FlexibleLegendPlacement.playerSize.width
    /// ★ BATCH G VERIFICATION: "Play all" plays its groups' own sims in turn — the picker and the
    /// note follow the PLAYING group ("● All · Group 2", that group's own line): `playAllLive` while
    /// the renderer plays them, `noteFor` the line for the sim playing (nil: `note`).
    var playAllLive = false
    var noteFor: ((String?) -> String?)?
    /// The squeezes to pick from (none, or one: no picker), the one shown, and the pick.
    var sims: [FlexibleSim] = []
    var shown: FlexibleSim?
    var onPick: (String) -> Void = { _ in }
    /// "Group 2 squishes 1.2 of 3.0 mm · firmer wins" — beside the picker, above the capsule.
    var note: String?

    /// The group "Play all" plays now (nil: not playing its sims).
    var playingGroup: FlexibleSim? {
        guard playAllLive, shown?.kind == .playAll, let id = loop.playingSimID else { return nil }
        return sims.first { $0.id == id && $0.kind != .playAll }
    }
    /// The picker's label: the pick, or under a live "Play all" "All · Group 2".
    var pickerLabel: String {
        if let g = playingGroup { return FlexibleRowCopy.playAllPlaying(g.short) }
        return shown?.short ?? FlexibleRowCopy.simAllShort
    }
    /// The line beside the picker (the playing group's own under a live "Play all").
    var shownNote: String? { noteFor.map { $0(playingGroup?.id) } ?? note }

    /// The player's size: the capsule, and — with the picker or a note — the row above it.
    static func size(picker: Bool, note: Bool) -> CGSize {
        let s = FlexibleLegendPlacement.playerSize
        return CGSize(width: s.width, height: s.height + (picker || note ? topRowHeight + rowGap : 0))
    }
    static let topRowHeight: CGFloat = 30
    static let rowGap: CGFloat = 4
    /// The shortest timeline the capsule keeps (pt).
    static let minTimeline: CGFloat = 120

    /// Test control only: D2's layout — the picker INSIDE the capsule (to prove the hosted
    /// measurement sees the squeezed timeline).
    @MainActor static var controlInlinePicker = false

    var body: some View {
        let inline = Self.controlInlinePicker
        let note = shownNote
        VStack(alignment: .leading, spacing: Self.rowGap) {
            if (sims.count > 1 && !inline) || note != nil {
                HStack(spacing: DS.Space.s) {
                    if sims.count > 1 && !inline { picker }
                    if let note {
                        Text(note)
                            .dsStyle(DS.TypeScale.footnote)
                            .foregroundStyle(DS.Color.textSecondary.color)
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .padding(.horizontal, DS.Space.m).frame(height: Self.topRowHeight - 6)
                            .background(Capsule().fill(DS.Surface.bar.color))
                            .accessibilityIdentifier("flexible-squish-note")
                    }
                }
                .frame(height: Self.topRowHeight)
                .frame(maxWidth: width, alignment: .leading)
            }
            capsule(inlinePicker: inline && sims.count > 1)
        }
        .frame(width: width)
        .accessibilityIdentifier("flexible-squish-player")
    }

    /// "[● Group 1 ▾]" — the shown squeeze's colour and name; the menu lists every squeeze.
    private var picker: some View {
        Menu {
            ForEach(sims) { sim in
                Button { onPick(sim.id) } label: {
                    if sim.id == shown?.id { Label(sim.title, systemImage: "checkmark") } else { Text(sim.title) }
                }
                .accessibilityIdentifier("flexible-squish-sim-\(sim.id)")
            }
        } label: {
            HStack(spacing: 5) {
                if case .group(let n)? = (playingGroup ?? shown)?.kind {
                    Circle().fill(FlexibleSqueezeGroups.colour(number: n).color).frame(width: 8, height: 8)
                }
                Text(pickerLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(1).fixedSize()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.Color.textSecondary.color)
            }
            .padding(.horizontal, 10).frame(height: Self.topRowHeight)
            .background(Capsule().fill(DS.Surface.bar.color)
                .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        }
        .fixedSize()
        .accessibilityLabel("Which squeeze plays")
        .accessibilityIdentifier("flexible-squish-picker")
    }

    private func capsule(inlinePicker: Bool) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !loop.playing)) { _ in
            HStack(spacing: DS.Space.sm) {
                if inlinePicker { picker }
                Button { loop.toggle() } label: {
                    Image(systemName: loop.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DS.Color.background.color)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.white))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loop.playing ? "Pause the squish" : "Play the squish")
                .accessibilityIdentifier("flexible-squish-play")
                Text("Rest")
                    .dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(1).fixedSize()
                Slider(value: Binding(get: { loop.amount }, set: { loop.scrub(to: $0) }), in: 0...1)
                    .tint(DS.Color.accent.color)
                    // its frame reaches the page (the hosted test measures the timeline)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["playerTimeline": g.frame(in: .global)])
                    }.allowsHitTesting(false))
                    .accessibilityLabel("Squish")
                    .accessibilityIdentifier("flexible-squish-timeline")
                Text(fullLabel)
                    .dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .monospacedDigit()
                    .lineLimit(1).fixedSize()
            }
            .padding(.vertical, DS.Space.xs)
            .padding(.horizontal, DS.Space.m)
            .frame(width: width, height: FlexibleLegendPlacement.playerSize.height)
            .background(Capsule().fill(DS.Surface.bar.color)
                .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            .dsShadow(.panel)
        }
    }
}
