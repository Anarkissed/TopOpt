// FlexibleKit+Aim — core's number behind the side label's (i) text (task 2026-10-07, angled presses, batch AP3;
// final spec §6 "Side verdict = core's": "flexible_side_stack_deg() is bridged for the (i) text only").
//
// ★ ONE SOURCE: CORE. The side VERDICT of a press direction is core's FaceFrame.side for that stated direction
// (`FlexibleScene.regionFrame(_:face:direction:)`, face_frame_cut with press_direction); this constant is only
// the number the sentence quotes. Nothing in the app compares an angle with it.
import Foundation
import TopOptBridge

extension FlexibleScene {
    /// Core's kSideStackDeg (15°): a stack is "side" when its load is MORE than this from build Z.
    public static var sideStackDeg: Double { topoptbridge.flexible_side_stack_deg() }
}
