// FlexibleStageModel+FacePrisms — ★ ONLY A FACE-PRISM MAKES LATTICE (task 2026-09-29-flexible-screens, round 7 batch M1,
// item 1a; his img1 words, 2026-10-14: "the lattice should *only* ever exist within the face-prisms that have been set …
// when no face-prism has been set, the entire object becomes a lattice. That needs to be the opposite behaviour. ONLY the
// face-prism creates the lattice structure in any area." — and the reviewer's ruling 4: "the app enforces it until core has
// a job flag. The Flexible job builder must NEVER send a job with no include region").
//
// ★ THE ROOT CAUSE. The Flexible stage sends the main page's lattice regions as they are (`project.latticeJobRegions()`,
// the scene job and the run job). With NO include region — nothing set to Lattice in Selections, or lattice mode off —
// core applies the lattice stage's own rule, "no include region = the whole part" (core job_block.hpp; run.cpp), so the
// mask, every stack's `lattice_mm`, the density field, the walls and the run job covered the WHOLE part. The app already
// had the question (`LatticeJobIncludeGate.hasIncludeWall`, #354's stage refuses with it); the Flexible stage never asked.
// ★ THE FIX, ALL APP-SIDE (core's precedence stays — the lattice stage shares it):
//   * `facePrismsSet` — the opened scene's regions hold an include wall (read with the scene's key, never twice);
//   * the stacks are kept WITHOUT lattice when it is false (FlexStackInfo.withoutLattice): the readiness says "No lattice
//     under <face>" with its one-tap [Lattice under it], the Settings depth row says so, nothing can be squished;
//   * the build refuses (and an old lattice is cleared): the main page shows the plain model and its pill says
//     "Set a face to Lattice in Selections first";
//   * the SEND gate (FlexibleCoreRun's two sends) refuses `.noFacePrism` — never the pure encoder (runJobJSON), whose bytes
//     the goldens pin. `facePrismsNow` is asked fresh there (an edit on another stage may not have re-opened the scene).

import Foundation
import TopOptKit

extension FlexibleStageModel {

    /// The opened scene's regions hold a face-prism: something is set to Lattice (an include wall). False ⇒ NO lattice on the
    /// Flexible stage (ruling 4). RED CONTROL `controlWholePartWithoutPrism`: the whole part, as core's rule has it.
    public var facePrismsSet: Bool { controlWholePartWithoutPrism || openedFacePrisms }

    /// The project's regions hold a face-prism NOW (asked fresh — the send gate: an edit on another stage may not have
    /// re-opened the scene yet).
    public var facePrismsNow: Bool {
        controlWholePartWithoutPrism || LatticeJobIncludeGate.hasIncludeWall(project.latticeJobRegions().regions)
    }
}
