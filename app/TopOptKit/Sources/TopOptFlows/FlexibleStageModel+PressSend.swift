// FlexibleStageModel+PressSend — the edge/corner press SENT to core (task 2026-09-29-flexible-screens, round 7 batch R7-E2). The
// reviewer's ruling (angled presses, 2026-10-07 item 6): "Under an angled press, the preview lattice is graded by that press's own
// design along the arrow, and blended into the neighbouring faces' lattices by core's conflict rule … the preview shows what will
// be built." His 2026-10-18 answers: do not ask #361 yet — ship the twist with its honest line.
//
// ★ THE PRESS IS A DESIGN TARGET through its synthetic key (FlexibleSquishTarget): `target(r)` — r ≥ 0 a face's settings, r ≤ −1000
// the press's (faceRegionID = r); `setTarget` routes a press through setPress (its regions[0] restored); `key(r)` takes both. The
// design pipeline designs every registered press on CORE's press stack (scheduleDesigns), with the map FlexiblePressShape builds
// from core's frame.
// ★ WHAT IS SENT (`pressSupport`, `sentPresses`): FlexiblePressSupport's gate per press. In the job (`pressJobEntries`) after the
// face entries; in the lattice (generateLattice) as core's field over the press key; on the card its one line (`pressWarning`).

import Foundation
import simd
import TopOptKit

extension FlexibleStageModel {

    /// Core's synthetic press ids start here and go down (the bridge's kSyntheticPressMax).
    nonisolated static let syntheticPressMax = -1000

    /// ★ RED CONTROL only (FlexibleR7E2Tests): E1's rule — presses stripped from the lattice's key and never built into it.
    @MainActor static var controlStripPresses = false
    /// ★ RED CONTROL only: the hold before E2 — a sent press's group not counted (Ready with both groups, one dropped).
    @MainActor static var controlHoldIgnoresPresses = false

    // MARK: - FlexibleSquishTarget

    /// The press registered on the open scene under synthetic key `r`.
    public func pressID(forKey r: Int) -> UUID? {
        nil   // ★ R7-E2 STUB
    }

    /// ★ THE TARGET a key names: r ≥ 0 a face's settings; r ≤ −1000 the press's settings with faceRegionID = r.
    public func target(_ r: Int) -> FlexibleFaceSettings? {
        settings.face(r)   // ★ R7-E2 STUB
    }

    /// Store a target's settings: a face's as before; a press's through setPress, its regions[0] restored.
    public func setTarget(_ f: FlexibleFaceSettings) {
        edit { $0.setFace(f) }   // ★ R7-E2 STUB
    }

    /// The press's design key (its synthetic key, rotation 0) on the open scene.
    public func pressDesignKey(_ id: UUID) -> FlexFaceKey? {
        nil   // ★ R7-E2 STUB
    }

    /// Core's design of the press (on its press stack).
    public func pressDesign(_ id: UUID) -> FlexFaceDesignInfo? { pressDesignKey(id).flatMap { designs[$0] } }

    /// What FlexiblePressShape needs of the press beyond core's stack.
    public func pressShape(_ id: UUID) -> FlexiblePressShape.Press? {
        nil   // ★ R7-E2 STUB
    }

    /// ★ The map core is sent for the press (the design's and the job's — one function).
    public func pressMap(_ id: UUID) -> FlexMap? {
        nil   // ★ R7-E2 STUB
    }

    /// ★ How far core's profile is off the flat prism (percent of h), from the design's S (core's squish_fraction) and δ_k.
    public func pressOffPercent(_ id: UUID) -> Double? {
        nil   // ★ R7-E2 STUB
    }

    // MARK: - the gate

    /// ★ Every strip press's verdict (FlexiblePressSupport).
    public var pressSupport: [UUID: FlexiblePressSupport.Verdict] {
        var out: [UUID: FlexiblePressSupport.Verdict] = [:]
        for p in settings.presses ?? [] where p.strip != nil { out[p.id] = FlexiblePressSupport.Verdict(inJob: false, reason: .coreSupport) }
        return out   // ★ R7-E2 STUB
    }

    /// ★ THE CARD'S ONE WARNING LINE past core's refusal and a lattice stop: not in the job (its reason, and its 1–3 fixes) ›
    /// twisted more than 2 % off › core's side label. nil: nothing to say.
    public func pressWarning(_ id: UUID) -> (line: String, fixes: [FlexiblePressFix])? {
        (FlexibleRowCopy.pressNotSent, [])   // ★ R7-E2 STUB
    }

    /// A fix of a press kept out of the job — ONE undo step. nil when done; else one line why not.
    @discardableResult
    public func applyPressFix(_ fix: FlexiblePressFix) async -> String? {
        nil   // ★ R7-E2 STUB
    }

    /// ★ A region id as core names it, in his words: a press's first piece → the press ("Edge 16"), a face's piece → its face's
    /// name ("Face 3"), a face → "Face 3".
    public func coreRegionName(_ id: Int) -> String {
        displayName(id)   // ★ R7-E2 STUB
    }

    /// ★ The job's press entries: every press in the job but those with a region in `excluding` (a send that leaves a group out).
    func pressJobEntries(excluding: Set<Int>) -> [FlexibleJob.PressEntry] {
        []   // ★ R7-E2 STUB
    }
}
