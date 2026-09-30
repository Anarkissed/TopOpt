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

    public init() {}

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
        anchorPhase = Self.risingPhase(held)
        anchorTime = clock()
        playing = true
        wake()
    }

    public func pause() {
        guard playing else { return }
        held = amount(at: clock())
        playing = false
        wake()
    }

    public func toggle() { playing ? pause() : play() }

    /// A drag on the timeline: pauses and sets the amount directly.
    public func scrub(to a: Double) {
        let v = min(1, max(0, a.isFinite ? a : 0))
        if playing { playing = false }
        if held != v { held = v }
        wake()
    }

    /// Hold still at `a` (nothing to loop: his live drawing, held at full).
    public func hold(_ a: Double = 1) {
        if playing { playing = false }
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
/// ★ ROUND 4 (D2): with two or more squeeze groups, a GROUP PICKER leads the capsule —
/// "[Group 1 ▾]": each group's squeeze (only its faces squish), or "All at once" — and a group
/// that squishes less than it was designed for says so in one line above the capsule.
struct FlexibleSquishPlayer: View {
    @ObservedObject var loop: FlexibleSquishLoop
    let fullLabel: String
    /// The capsule's width (FlexibleLegendPlacement.player); the slider takes what is left.
    var width: CGFloat = FlexibleLegendPlacement.playerSize.width
    /// The squeezes to pick from (none, or one: no picker), the one shown, and the pick.
    var sims: [FlexibleSim] = []
    var shown: FlexibleSim?
    var onPick: (String) -> Void = { _ in }
    /// "Group 2 squishes 1.2 of 3.0 mm · firmer wins" — above the capsule.
    var note: String?

    /// The player's size: wider with the picker, taller with the note.
    static func size(picker: Bool, note: Bool) -> CGSize {
        let s = FlexibleLegendPlacement.playerSize
        return CGSize(width: s.width + (picker ? pickerWidth : 0), height: s.height + (note ? noteHeight : 0))
    }
    static let pickerWidth: CGFloat = 104
    static let noteHeight: CGFloat = 22

    var body: some View {
        VStack(spacing: 4) {
            if let note {
                Text(note)
                    .dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, DS.Space.m).padding(.vertical, 2)
                    .background(Capsule().fill(DS.Surface.bar.color))
                    .frame(height: Self.noteHeight - 4)
                    .accessibilityIdentifier("flexible-squish-note")
            }
            capsule
        }
        .accessibilityIdentifier("flexible-squish-player")
    }

    private var picker: some View {
        Menu {
            ForEach(sims) { sim in
                Button { onPick(sim.id) } label: {
                    if sim.id == shown?.id { Label(sim.title, systemImage: "checkmark") } else { Text(sim.title) }
                }
                .accessibilityIdentifier("flexible-squish-sim-\(sim.id)")
            }
        } label: {
            HStack(spacing: 4) {
                Text(shown?.short ?? FlexibleRowCopy.simAllShort)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(1).fixedSize()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.Color.textSecondary.color)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Capsule().fill(DS.Color.fillSelected.color))
        }
        .accessibilityLabel("Which squeeze plays")
        .accessibilityIdentifier("flexible-squish-picker")
    }

    private var capsule: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !loop.playing)) { _ in
            HStack(spacing: DS.Space.sm) {
                if sims.count > 1 { picker }
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
