// FlexibleCoreJobMemo — what the Lattice button's Send would do NOW (task 2026-09-29-flexible-screens, round 7, the review of
// batch R7-D1).
//
// The review (2026-10-17): "The Lattice button cannot re-send after a core failure or after an edit that changes only the job,
// so it keeps showing a stale answer … FlexibleLatticeButton.state treats core's last answer as current when coreRun.sentFor
// == lattice.generation … It does not check whether the job itself is unchanged." So FlexibleMainStage.answerIsCurrent asks
// what Send would do now — the job it would send (FlexibleStageModel.runJobJSON, the round-trip-tested encoder), or the "Not
// sent" it would say — decided as FlexibleCoreRun.send decides it: no face-prism first (ruling 4), then core's hold, then the
// encoder. The split asks on every pass and encoding is not free, so the answer is MEMOISED by everything the job reads that
// no lattice re-key covers: the settings in full (the presses, the names and colours too — a change re-encodes once and the
// JSON decides), the stamps' grids, the lattice's generation (the scene: grid, regions, bead, build directions re-key it).

import Foundation
import TopOptKit

@MainActor
final class FlexibleCoreJobMemo {
    struct Key: Equatable {
        let settings: FlexibleStageSettings
        let stamps: [UUID: FlexStamp]
        let generation: Int?
        let resting: [Int]
    }
    enum Now: Equatable { case job(String), notSent(String) }

    /// The last two answers (the main job's and one hold send's).
    private var entries: [(key: Key, now: Now, fixes: [FlexibleCoreFix])] = []
    /// How many times the job was worked out (tests: the memo holds).
    private(set) var computed = 0

    func now(_ m: FlexibleStageModel, resting: Set<Int>) -> (now: Now, holdFixes: [FlexibleCoreFix]) {
        let key = Key(settings: m.settings, stamps: m.stampGrids, generation: m.lattice?.generation, resting: resting.sorted())
        if let hit = entries.first(where: { $0.key == key }) { return (hit.now, hit.fixes) }
        computed += 1
        let hold = m.coreHold
        let now: Now
        if FlexibleCoreRun.noFacePrismFirst(m) {
            now = .notSent(FlexibleCoreRun.notSentLine(.noFacePrism))
        } else if resting.isEmpty, let h = hold {
            now = .notSent(h.line)
        } else {
            do { now = .job(try m.runJobJSON(resting: resting)) }
            catch let e as FlexibleJob.EncodeError { now = .notSent(FlexibleCoreRun.notSentLine(e)) }
            catch { now = .notSent("Not sent") }
        }
        entries = Array(([(key: key, now: now, fixes: hold?.fixes ?? [])] + entries).prefix(2))
        return (now, hold?.fixes ?? [])
    }
}
