// FlexibleConfirmInPlace — every Flexible delete asks first, IN PLACE (task 2026-09-29-flexible-screens, round 7 · U21 batch D;
// his notes of 2026-10-21, Img13: "I accidentally deleted a face (which I shouldn't be able to do with a single click - why isn't
// there a confirmation button that is required? And if there is, is the "cancel" button where the delete button was and the OK
// button somewhere else so it requires a move to confirm?"; the reviewer's ruling E(2) of 18:09: "A face deleting with one tap
// gets the SAME confirm as a group").
//
// ★ THE RULE (one for every delete): the tapped control's place turns into [Keep] (or [Cancel]) — its CENTRE exactly where the
// tapped control's centre was and (fix round 2) at least as wide as the control, so a second tap anywhere on the same spot only
// cancels; the question and the red button sit to its LEFT, the red button's trailing edge at least `gap` (24 pt) left of Keep's
// leading edge — so at least 24 pt clear of the control he tapped — and confirming needs a move. A tap elsewhere
// (another face, a row, the part) or a tab change drops the ask (`dropInPlaceAsks`). Applied to: the face row's take-out (⊖),
// an edge / corner press's trash, a group's trash (it asked in the panel's top line before), Reset all, the fix pop-up's
// [Remove Face N] / a kept-out press's [Remove] (two taps with a move: his words beat the one-tap-fix rule for deletes) — and,
// fix round 1, the same Remove fixes in the edges card's warning row and the Lattice page's callout / card Core row
// (`FlexibleFixAsk`) — and on
// the Lattice page the Selections trash, the chip's trash and "Delete Flexible lattice" (there [Cancel] takes the control's
// place and the question with [Delete] goes on the lines under it — a list row has no room on the left).
// ★ UNDO (UNDO-GHOST) and the take-out's own undo step live in FlexibleStageModel (railReturn, removeFace); ONE undo step for
// a delete that re-opens the scene (a Lattice-page trash — F12 — and Reset all) is `sealAfterReopen` below.

import SwiftUI
import TopOptDesign

/// Keep's centre on the tapped control's centre: the overlay aligns this guide of its content with the control's.
extension HorizontalAlignment {
    private enum FlexKeepCentre: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[HorizontalAlignment.center] }
    }
    static let flexKeepCentre = HorizontalAlignment(FlexKeepCentre.self)
}

enum FlexibleConfirmCopy {
    static let keep = "Keep"
    static let cancel = "Cancel"
    /// ★ U21 FIX ROUND 1 (the check: his l-bracket's "Face 6 · lattice" made the line overflow the card onto the Group tab):
    /// the face's own name only — a lattice-section suffix (" · lattice A") is dropped from the question (the face stays
    /// selected and pulsing on the part, so which one is never in doubt).
    static func takeOutAsk(_ name: String) -> String {
        if FlexibleStageModel.controlTakeOutFullName { return "Take \(name) out?" }
        let short = name.components(separatedBy: " \u{00B7} ").first ?? name
        return "Take \(short) out?"
    }
    static let takeOut = "Take out"
    static func removeAsk(_ name: String) -> String { "Remove \(name)?" }
    static let remove = "Remove"
}

enum FlexibleConfirmLayout {
    /// The clear space between the red button's trailing edge and Keep's leading edge.
    static let gap: CGFloat = 24
    /// Keep's width (its height is a finger's 44 pt) — wide enough for "Cancel".
    static let keepWidth: CGFloat = 64
}

/// The ask on a delete control: while `asking`, the control is hidden and [Keep] sits centred on it, the question and the red
/// button to its left. Frames: "<key>Keep" and "<key>Confirm" (the hosted test measures them; `keepKey` / `confirmKey` keep
/// older names).
struct FlexibleConfirmInPlace: ViewModifier {
    let asking: Bool
    let question: String?
    let destructive: String
    var keep: String = FlexibleConfirmCopy.keep
    let confirmKey: String
    let keepKey: String
    var questionID: String? = nil
    /// ★ U21 FIX ROUND 1 (the check: "[Remove] left of the pop-up's own edge when Remove is the first fix"): the FIRST button of
    /// a left-aligned fix row has nothing to its left, so its red button goes to the RIGHT of [Keep] (the same ≥ 24 pt move; the
    /// row's other fixes step back while it asks).
    var redOnTrailing: Bool = false
    let confirm: () -> Void
    let cancel: () -> Void

    /// ★ RED CONTROL (hosted): the old placement — the question, [Delete] then [Keep] at the row's trailing end, Keep NOT on the
    /// tapped spot.
    @MainActor static var controlOldPlacement = false
    /// ★ RED CONTROL (hosted, U21 fix round 1): the red button always on the left — a first fix's [Remove] leaves its row.
    @MainActor static var controlRedAlwaysLeading = false
    /// ★ RED CONTROL (hosted, U21 fix round 2): [Keep] always 64 pt wide — on a wide fix button ([Remove Face 5], 128–143 pt)
    /// the red [Remove] then sits 9–16 pt over the button he tapped (the gap was measured from Keep, not from the button).
    @MainActor static var controlGapFromKeepOnly = false

    /// The tapped control's own width (measured while it shows).
    @State private var controlWidth: CGFloat = 0

    /// ★ U21 FIX ROUND 2 (the check: his Img13 "the OK button somewhere else so it requires a move to confirm"): [Keep] covers
    /// the WHOLE tapped control — never narrower than it — so the red button's ≥ 24 pt gap is measured from the control's own
    /// edge; a second tap anywhere on the button he tapped only keeps.
    @MainActor var keepFrameWidth: CGFloat {
        Self.controlGapFromKeepOnly ? FlexibleConfirmLayout.keepWidth : max(FlexibleConfirmLayout.keepWidth, controlWidth.rounded(.up))
    }

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in Color.clear.preference(key: FlexibleConfirmControlWidthKey.self, value: g.size.width) })
            .onPreferenceChange(FlexibleConfirmControlWidthKey.self) { controlWidth = $0 }
            .transformPreference(FlexibleConfirmControlWidthKey.self) { $0 = 0 }   // (never an enclosing ask's)
            .opacity(asking ? 0 : 1)
            .allowsHitTesting(!asking)
            .overlay(alignment: Alignment(horizontal: .flexKeepCentre, vertical: .center)) {
                if asking { line.fixedSize() }
            }
    }

    @ViewBuilder private var line: some View {
        let red = Button(action: confirm) {
            Text(destructive).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(DS.Color.danger.color))
                .frame(minWidth: FlexibleTargets.least, minHeight: FlexibleTargets.least)   // (44 pt; R's red control: F's 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Self.publish(confirmKey))
        .accessibilityIdentifier("flexible-confirm-\(confirmKey)")
        let keepButton = Button(action: cancel) {
            Text(keep).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(1).fixedSize()
                .frame(width: keepFrameWidth - 8, height: 32)
                .background(Capsule().fill(DS.Color.chipSolid.color))
                .frame(width: keepFrameWidth, height: FlexibleTargets.side(32))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Self.publish(keepKey))
        .accessibilityIdentifier("flexible-keep-\(keepKey)")
        HStack(spacing: 0) {
            if let q = question {
                Text(q).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(1).fixedSize()
                    .padding(.trailing, DS.Space.s)
                    .background(Self.publish(confirmKey + "Question"))
                    .accessibilityIdentifier(questionID ?? "flexible-confirm-question")
            }
            if redOnTrailing, !Self.controlRedAlwaysLeading, !Self.controlOldPlacement {
                keepButton.alignmentGuide(.flexKeepCentre) { $0[HorizontalAlignment.center] }
                Color.clear.frame(width: FlexibleConfirmLayout.gap, height: 1)
                red
            } else if Self.controlOldPlacement {
                // (the red control: Keep last, past the red button, its centre off the tapped spot)
                red
                Color.clear.frame(width: DS.Space.s, height: 1)
                keepButton
                Color.clear.frame(width: FlexibleConfirmLayout.keepWidth, height: 1)
                    .alignmentGuide(.flexKeepCentre) { $0[HorizontalAlignment.center] }
            } else {
                red
                Color.clear.frame(width: FlexibleConfirmLayout.gap, height: 1)
                keepButton.alignmentGuide(.flexKeepCentre) { $0[HorizontalAlignment.center] }
            }
        }
        // (no backdrop: the caller hides what the line would cover — the row's name, its chips — while it asks)
        .accessibilityElement(children: .contain)
    }

    static func publish(_ key: String) -> some View {
        GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: [key: g.frame(in: .global)]) }
            .allowsHitTesting(false)
    }
}

private struct FlexibleConfirmControlWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The Lattice page's variant: [Cancel] takes the tapped control's place (centred on it); the question and [Delete] are drawn by
/// the caller on the lines under it (`FlexibleDeleteConfirm`).
struct FlexibleCancelInPlace: ViewModifier {
    let asking: Bool
    let keepKey: String
    let cancel: () -> Void

    func body(content: Content) -> some View {
        let asking = self.asking && !FlexibleConfirmInPlace.controlOldPlacement   // (the red control: the trash stays, no Cancel on it)
        content
            .opacity(asking ? 0 : 1)
            .allowsHitTesting(!asking)
            .overlay {
                if asking {
                    Button(action: cancel) {
                        Text(FlexibleConfirmCopy.cancel).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.Color.textPrimary.color)
                            .lineLimit(1).fixedSize()
                            .frame(width: FlexibleConfirmLayout.keepWidth - 8, height: 32)
                            .background(Capsule().fill(DS.Color.chipSolid.color))
                            .frame(width: FlexibleConfirmLayout.keepWidth, height: FlexibleTargets.minimum)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .background(FlexibleConfirmInPlace.publish(keepKey))
                    .accessibilityIdentifier("flexible-delete-cancel")
                }
            }
    }
}

// MARK: - the asks (one at a time)

extension FlexibleStageModel {
    /// ★ RED CONTROL: today's one-tap deletes (the face's ⊖, a press's trash, the pop-up's Remove fixes go at once).
    @MainActor static var controlRemoveAtOnce = false
    /// ★ RED CONTROL (U21 fix round 1): the take-out question with the whole section name ("Take Face 6 · lattice out?").
    nonisolated(unsafe) static var controlTakeOutFullName = false

    /// Every in-place ask goes (a tap elsewhere, a tab change, another ask).
    func dropInPlaceAsks() {
        if faceRemoveAsk != nil { faceRemoveAsk = nil }
        if pressRemoveAsk != nil { pressRemoveAsk = nil }
        if resetAsk { resetAsk = false }
        if fixRemoveAsk != nil { fixRemoveAsk = nil }
    }

    /// The face row's ⊖: "Take Face 6 out? [Take out] [Keep]".
    public func askRemoveFace(_ region: Int) {
        if Self.controlRemoveAtOnce { removeFace(region); return }
        dropInPlaceAsks(); groupDeleteAsk = nil
        faceRemoveAsk = region
    }
    public func confirmRemoveFace() {
        guard let r = faceRemoveAsk else { return }
        faceRemoveAsk = nil
        guard settings.face(r) != nil else { return }
        removeFace(r)
    }
    public func keepFace() { faceRemoveAsk = nil }

    /// An edge / corner press's trash: "Remove Edge 12? [Remove] [Keep]".
    public func askRemovePress(_ id: UUID) {
        if Self.controlRemoveAtOnce { removePress(id); return }
        dropInPlaceAsks(); groupDeleteAsk = nil
        pressRemoveAsk = id
    }
    public func confirmRemovePress() {
        guard let id = pressRemoveAsk else { return }
        pressRemoveAsk = nil   // (before the strip removal's task: the ask never outlives its press)
        guard settings.press(id) != nil else { return }
        removePress(id)
    }
    public func keepPress() { pressRemoveAsk = nil }

    /// [Reset all]: "Reset every setting here? [Reset] [Cancel]".
    public func askResetAll() {
        dropInPlaceAsks(); groupDeleteAsk = nil
        resetAsk = true
    }
    public func confirmResetAll() {
        guard resetAsk else { return }
        resetAsk = false
        resetAll()
    }
    public func keepAll() { resetAsk = false }

    /// A Remove fix (`FlexibleFixAsk.key`: where it is shown + the fix's id): the button turns into [Keep], [Remove] beside it.
    func askFixRemove(_ id: String) {
        dropInPlaceAsks(); groupDeleteAsk = nil
        fixRemoveAsk = id
    }
}

// MARK: - ★ U21 FIX ROUND 1: every Remove FIX asks, wherever it is shown

/// The check found two more one-tap deletes after batch D: the Lattice page's blocker callout and the Lattice card's Core row
/// ([Remove Face N] on a "can't be squished here" refusal, a kept-out press's [Remove Edge N]) and the edges card's warning row
/// ([Remove Edge 16] of a shared surface). Every place that shows a fix routes its tap through here, so a Remove asks in place
/// the same way everywhere (his Img13 note; ruling E(2)).
enum FlexibleFixAsk {
    /// The ask's key: the place the button is shown ("popup", "callout", "card", "pressFix") and the fix's id — one ask at a time.
    static func key(_ scope: String, _ id: String) -> String { "\(scope):\(id)" }

    /// The modifier for a fix button that may delete: [Keep] on the button, the red [Remove] a move away (to the right for the
    /// row's first button). Frames "<scope>RemoveKeep" / "<scope>RemoveConfirm".
    @MainActor
    static func confirm(model: FlexibleStageModel, scope: String, id: String, first: Bool, apply: @escaping () -> Void) -> FlexibleConfirmInPlace {
        let k = key(scope, id)
        return FlexibleConfirmInPlace(asking: model.fixRemoveAsk == k, question: nil, destructive: FlexibleConfirmCopy.remove,
                                      confirmKey: scope + "RemoveConfirm", keepKey: scope + "RemoveKeep", redOnTrailing: first,
                                      confirm: { model.fixRemoveAsk = nil; apply() },
                                      cancel: { if model.fixRemoveAsk == k { model.fixRemoveAsk = nil } })
    }

    /// While one of `scope`'s Remove fixes asks, the row's OTHER buttons step back (the red button may sit on their place).
    @MainActor
    static func stepsBack(model: FlexibleStageModel, scope: String, id: String) -> Bool {
        guard let a = model.fixRemoveAsk, a.hasPrefix(scope + ":") else { return false }
        return a != key(scope, id)
    }

    /// The row went away: its ask goes with it (never another place's).
    @MainActor
    static func drop(model: FlexibleStageModel, scope: String) {
        if let a = model.fixRemoveAsk, a.hasPrefix(scope + ":") { model.fixRemoveAsk = nil }
    }
}

extension FlexibleStageModel {
    /// ★ U21 FIX ROUND 1: an edges card warning row's fix ([Shallower] [Face 3 rests] [Remove Edge 16]) — Remove asks first, the
    /// others apply at once (each one undo step, as before).
    func tapPressFix(_ f: FlexiblePressFix, scope: String = "pressFix") {
        if case .remove = f, !Self.controlRemoveAtOnce {
            askFixRemove(FlexibleFixAsk.key(scope, f.id))
            return
        }
        applyPressFixNow(f)
    }

    func applyPressFixNow(_ f: FlexiblePressFix) {
        Task { @MainActor in if let why = await self.applyPressFix(f) { self.toast = why } }
    }
}

// MARK: - ONE undo step for a delete that re-opens the scene (★ U21: F12, Reset all)

extension FlexibleStageModel {
    /// ★ RED CONTROL: today's Reset all — sealed at once; the re-opened scene's write after it is its own undo step (one Undo
    /// then took that write and left the reset in place).
    @MainActor static var controlResetSealsAtOnce = false

    /// Has the scene the project describes now opened (or failed, or nothing to open)?
    var reopenLanded: Bool {
        switch sceneState {
        case .opening: return false
        case .ready: return openedKey == currentSceneKey
        case .idle, .failed: return true
        }
    }

    /// Keep the current undo step OPEN until the scene re-opens and the stage's own write after it (M2's carry onto the new
    /// lattice sections, the main page's loads, the section numbers) has landed IN it, then seal: one toolbar Undo restores the
    /// delete with no hidden step (the reviewer's ruling E(2)). The project folds a change into one step 400 ms after the last
    /// change; it is re-announced every 150 ms meanwhile (≤ `maximum` s) so the delete is not sealed alone first. An action that
    /// seals its own step (another delete, an Undo) still seals at once.
    func sealAfterReopen(maximum: Double = 5) {
        let project = self.project
        let start = Date()
        stepHold?.cancel()
        saveTask?.cancel()   // (the edit's save, 0.8 s on, would seal the step before the re-open's write)
        stepHold = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, Date().timeIntervalSince(start) < maximum, !self.reopenLanded else { break }
                self.saveTask?.cancel()
                project.objectWillChange.send()
            }
            if let self { self.save() } else { project.sealUndoStep() }   // sealed, and on disk
        }
    }
}
