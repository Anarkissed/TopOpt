// FlexibleCoreDoor — ★ NO REQUEST OF ANY KIND GOES TO CORE FROM THE FLEXIBLE STAGE WITHOUT A FACE-PRISM (task
// 2026-09-29-flexible-screens, round 7, the H39 hotfix; the reviewer's ruling 6 of 2026-10-17 20:25, approved by the
// maintainer: "M1: F10/F15/F16 — NO request of ANY kind (design, preview or run) goes to core from Flexible without a
// face-prism (test)").
//
// ★ WHY. Core's shared rule (the lattice stage's too) is "no include region = the whole part" (core job_block.hpp; run.cpp).
// M1 stopped the RUN with no face-prism (FlexibleCoreRun's `.noFacePrism`) and hid what core said about the whole part, but
// the Flexible stage still OPENED core's scene on the whole part and asked it for every pressed face's stack and design
// (M1 verify, findings 10 / 15 / 16). Every one of those asks is made ON a scene — the stacks, the designs, Auto, the
// conflicts, the stamp checks, the drawn maps, the preview's mask and fields, the squish sims, the frames and the aims — so
// the one door is the scene's opening:
//   * every scene the Flexible stage opens is opened HERE (the worker's `open`, and the strips' [Done] — FlexibleStageModel
//     +EdgePick); with no face-prism the door REFUSES and opens nothing;
//   * with no face-prism the stage does not knock at all (FlexibleStageModel.openScene → `holdWithoutFacePrism`): it is
//     ready on the plain part, core's old scene is let go, and nothing can be asked (the worker has no scene);
//   * the run stays refused by FlexibleCoreRun (M1), before the runner.
// The counters are the test's proof (FlexibleRuling6NoCoreTests): a scene never opened means no design, preview or squish
// reached the bridge.

import Foundation
import TopOptKit

/// The one door to core's Flexible scene (one per worker, so one per stage model).
final class FlexibleCoreDoor: @unchecked Sendable {
    /// Why the door stays shut, in his words (FlexibleRowCopy.noFacePrism — the line the main page and the Squish page show).
    enum Refusal: Error, CustomStringConvertible, Equatable {
        case noFacePrism
        var description: String { FlexibleRowCopy.noFacePrism }
    }

    private let lock = NSLock()
    private var openedCount = 0, refusedCount = 0, askedCount = 0

    /// Scenes opened in core through this door (tests).
    var opened: Int { lock.withLock { openedCount } }
    /// Openings refused for want of a face-prism (tests).
    var refused: Int { lock.withLock { refusedCount } }
    /// Calls made on an open scene (tests): the stacks, designs, fields, sims, frames…
    var asked: Int { lock.withLock { askedCount } }

    /// Open core's scene for `jobJSON` — only when its regions hold a face-prism (`facePrism`: the caller's
    /// `FlexibleStageModel.mayAskCore`, read from the very regions the job carries). Throws `Refusal.noFacePrism` otherwise.
    func open(jobJSON: String, jobDir: String, facePrism: Bool) throws -> FlexibleScene {
        guard facePrism else {
            lock.withLock { refusedCount += 1 }
            throw Refusal.noFacePrism
        }
        lock.withLock { openedCount += 1 }
        return try FlexibleScene(jobJSON: jobJSON, jobDir: jobDir)
    }

    /// One call on an open scene.
    func noteAsk() { lock.withLock { askedCount += 1 } }
}

extension FlexibleStageModel {
    /// Test control only (ruling 6): projects whose stage models ask core even with no face-prism — the fixtures that pin
    /// CORE's own answers on parts that set none (FlexiblePressFixtures' synthetic parts and C1's pad: their projects are
    /// made fresh, with a new id each, so no other test's project is ever in it).
    @MainActor static var controlAskCoreWithoutPrismFor: Set<UUID> = []

    /// ★ RULING 6: core may be asked — the regions hold a face-prism (`facePrism`, read from the regions the job carries), or a
    /// test control stands in for the stage before a ruling (M1's whole part, ruling 6's asks).
    func mayAskCore(facePrism: Bool) -> Bool {
        facePrism || controlWholePartWithoutPrism || controlAskCoreWithoutPrism || Self.controlAskCoreWithoutPrismFor.contains(project.id)
    }
}
