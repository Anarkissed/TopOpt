// FlexiblePressDegreesBox — the arrow's degrees box (task 2026-10-07, angled presses, batch AP3; final spec §6 "Controls":
// "a FlexNumberBox such as '12°': degrees off the selected target"). His rule: numbers are boxes — a TAP opens the
// keypad, a VERTICAL DRAG scrubs (FlexNumberBox), one commit per keypad close or release, so one undo step.
//
// ★ ITS RULE IS FlexiblePressAim.Box: it measures FROM the selected target (the press's snap kind when that target is
// offered, else the first offered — the halfway of an edge or a corner, a tilt's straighten), scrubs along the great
// circle from the target through the arrow (toward the first member's core normal, or core's frame X for a tilt, when
// the arrow sits on it), shows 0 … its limit (1° short of edge-on), and a commit keeps the target's kind. 0 is the
// target bit for bit. The press card (AP4/AP5, and round 6 item 2's edges groups) places it on the Aim row beside the
// target chips; nothing here computes a direction of its own.
import SwiftUI

struct FlexiblePressDegreesBox: View {
    let box: FlexiblePressAim.Box
    /// The page's one keypad slot.
    @Binding var padTarget: String?
    /// One commit: what the press card hands to `FlexibleStageModel.aimPress`.
    let onRelease: (FlexiblePressAim.Release) -> Void
    var onNote: ((String) -> Void)? = nil

    /// The keypad slot and accessibility id ("flexible-number-press-degrees").
    static let key = "press-degrees"

    var body: some View {
        FlexNumberBox(key: Self.key, title: "Degrees off " + box.target.label, spec: box.spec,
                      padTarget: $padTarget, onNote: onNote) { v in
            onRelease(box.release(v))
        }
    }
}
