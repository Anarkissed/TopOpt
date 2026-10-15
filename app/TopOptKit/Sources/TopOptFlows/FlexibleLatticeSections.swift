// FlexibleLatticeSections — the part of a face inside a face-prism (task 2026-09-29-flexible-screens, round 7 batch M2;
// his img3 words of 2026-10-14: "only the places with face-prisms get latticed. In this example, when I tapped the top, it
// selected the model's top face, rather than one of the lattice's top faces." and "the pressed curves continue right
// through the entire model rather than the lattice section. It must only be the lattice section - regardless of what shape
// it is.").
//
// TESTS-FIRST STUB (M2): the controls and the lines; no section is cut yet.

import Foundation
import simd

public enum FlexibleLatticeSections {
    /// ★ RED CONTROL: no section is ever cut — a face partly inside a face-prism is pressed WHOLE (today's).
    nonisolated(unsafe) static var controlWholeFace = false
    /// ★ RED CONTROL: every face a face-prism meets is cut, even one wholly inside it (its id and bytes move).
    nonisolated(unsafe) static var controlAlwaysCut = false
    /// ★ RED CONTROL: a section's key is its GEOMETRY (depth and outline), so a depth change re-keys it.
    nonisolated(unsafe) static var controlFingerprintIDs = false
}
