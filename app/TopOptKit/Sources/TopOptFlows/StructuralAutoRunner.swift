// StructuralAutoRunner — ★ notes30 STRUCTURAL AUTO on the Mac: the Lattice press's chain of print-file jobs (StructuralAuto.swift
// says what each round is). Each job is today's `lattice_file` job with its strength check, unchanged; between them the app
// sizes the struts again from the first check's own lattice stress. At most `StructuralAuto.checksPerPress` checks (his D3: two),
// one when the first lands within 5 % (the shortcut); the LIGHTEST file that passes is kept (none passing: the last), its
// round remembered so the drawing follows it, and the result's report carries the record (`structural_auto`) Results reads.
// Resume: each job is recorded for the version while it is on the Mac (LatticeJobRecorder); the round before it is ended once
// it has been read, so an app that is gone comes back to the job still running.
import Foundation
import TopOptKit

extension LatticeFileButton {
    /// What the chain sizes from: round 0 (sent with the first job), the stage's own stress (its tensor gives the stress's
    /// shape for round 1), the inputs, round 0's identity (the drawing's), and the cells' measures for D2's estimate.
    public struct StructuralAutoAsk: Sendable {
        public var round0: StructuralAuto.Sized
        public var stage: LatticeDemandField
        public var inputs: StructuralAuto.Inputs
        public var baseKey: Int
        public var largestCellMM: Double
        public var lineMM: Double
        public init(round0: StructuralAuto.Sized, stage: LatticeDemandField, inputs: StructuralAuto.Inputs, baseKey: Int,
                    largestCellMM: Double, lineMM: Double) {
            self.round0 = round0; self.stage = stage; self.inputs = inputs; self.baseKey = baseKey
            self.largestCellMM = largestCellMM; self.lineMM = lineMM
        }
    }

    /// How long the chain waits for the preview's lattice map (round 1's lattice voxels) before going on without it.
    static let latticeMapWaitSeconds: TimeInterval = 60

    /// The Lattice press on Structural Auto. `lattice`: the check grid's lattice voxels from the preview's own layout (nil: not
    /// known — the check's stress is read everywhere). `onStep`: the card's steps. `store`: where the kept round is remembered.
    public static func structuralAutoRunner(config: RemoteRunnerConfig, job: LatticeFileJob.ForPart, ask: StructuralAutoAsk,
                                            projectName: String, strengthJob: Data?, densityGCm3: Double,
                                            defaults: UserDefaults = .standard, inputsRoot: URL = LatticeJobInputs.defaultRoot,
                                            store: StructuralAutoStore = .shared,
                                            lattice: @escaping @Sendable (StructuralAuto.CheckField) async -> [Bool]? = { _ in nil },
                                            onStep: @escaping @Sendable (StructuralAutoSteps.Event) -> Void = { _ in },
                                            onJob: @escaping @Sendable (URL) -> Void = { _ in }) -> RunModel.Runner {
        { request, progress, _ in
            let keepGoing = Progress(progress)
            let total = StructuralAuto.checksPerPress
            _ = keepGoing.call(0, total, 0)
            let record = LatticeJobRecorder(projectID: request.projectID, projectName: projectName, organic: false,
                                            defaults: defaults, inputsRoot: inputsRoot)
            var mades: [LatticeFileRun.Made] = []
            var rounds: [StructuralAuto.Round] = []
            var sizedOf: [StructuralAuto.Sized] = []
            var demand = job.demand
            var sizedNow = ask.round0
            for check in 1...total {
                onStep(.began(.check(check)))
                let made: LatticeFileRun.Made
                do {
                    made = try LatticeFileRun.drive(config: config, modelPath: job.modelPath, jobJSON: job.json,
                                                    projectName: projectName, demand: demand, strengthJob: strengthJob,
                                                    tensor: job.tensor, record: record,
                                                    isCancelled: { !keepGoing.call(check - 1, total, 0) }, onJob: onJob)
                } catch let f as LatticeFileRun.Failure where !f.transient && !mades.isEmpty {
                    // a later round the Mac could not make (its print check, say): the file already made stands
                    break
                }
                mades.append(made)
                sizedOf.append(sizedNow)
                rounds.append(round(of: made))
                _ = keepGoing.call(check, total, 0)
                // what comes next: round 1 sized from this check's own lattice stress, or the stop
                var resized: StructuralAuto.Resized?
                if check < total, let c = StructuralAuto.CheckField.of(made.fields) {
                    let mask = wait(seconds: latticeMapWaitSeconds) { await lattice(c) }
                    resized = StructuralAuto.resize(check: c, stage: ask.stage, round0: ask.round0, ask.inputs, lattice: mask,
                                                    largestCellMM: ask.largestCellMM, lineMM: ask.lineMM)
                }
                let next = StructuralAuto.next(afterCheck: check, passed: rounds[check - 1].passed, saving: resized?.saving,
                                               checks: total)
                guard next == .anotherCheck, let r = resized else {
                    // the steps not taken go: the shortcut says so in one ticked line; any other stop just drops them
                    if check < total {
                        let close = rounds[check - 1].passed && (resized?.saving ?? 1) < StructuralAuto.shortcutSaving
                        onStep(.shortcut(close: close))
                    }
                    break
                }
                onStep(.began(.fineTune))
                demand = LatticeFileJob.demandFile(r.sized.field)
                sizedNow = r.sized
            }
            guard !mades.isEmpty else { throw LatticeFileRun.Failure("The print file could not be made") }
            let k = StructuralAuto.kept(rounds)
            // the rounds not kept are over for the app (their files were read; nothing to follow again)
            for (i, m) in mades.enumerated() where i != k { if let id = m.jobID { record.ended(id) } }
            onStep(.began(.saving))
            // ★ the drawing follows the print file: the round kept (round 0 is the one on screen already)
            if let id = request.projectID { store.keep(id, baseKey: ask.baseKey, k == 0 ? nil : sizedOf[k]) }
            let required = mades[k].report.strength?.safetyMargin ?? ask.inputs.margin
            let rec = StructuralAuto.Record(margin: ask.inputs.margin, rounds: rounds, keptRound: k,
                                            shortPlaces: sizedOf[k].shortVoxels, quilted: quilted(mades[k].reportJSON),
                                            short: StructuralAuto.short(rounds: Array(rounds.prefix(k + 1)), required: required,
                                                                        shortPlaces: sizedOf[k].shortVoxels))
            var kept = mades[k]
            kept.reportJSON = StructuralAuto.withRecord(kept.reportJSON, rec)
            let m = kept
            let o = try record.reading(m) { try outcome(m, densityGCm3: densityGCm3) }
            onStep(.finished)
            return o
        }
    }

    /// One check, as the keep rule reads it: the check's verdict (the solid AND the struts keep the margin), the file's
    /// plastic, and the app's one "how strong" number (the smaller of the two margins).
    static func round(of m: LatticeFileRun.Made) -> StructuralAuto.Round {
        let s = m.report.strength
        let o = (try? JSONSerialization.jsonObject(with: m.reportJSON)) as? [String: Any]
        let governing = o.flatMap(LatticeStrengthAnswer.decode(report:))?.governing ?? s?.marginWorstCase ?? 0
        return StructuralAuto.Round(passed: s?.verdict == .pass, plasticMM3: m.report.plasticMM3, margin: governing)
    }

    /// The cells D2 laid past the quilt-off limit, as the file's report says (its layout block; 0 when not said).
    static func quilted(_ report: Data) -> Int {
        guard let o = (try? JSONSerialization.jsonObject(with: report)) as? [String: Any],
              let l = o["layout"] as? [String: Any] else { return 0 }
        return (l["quilted_where_short"] as? NSNumber)?.intValue ?? 0
    }

    /// An async answer awaited from the runner's own (blocking) thread, at most `seconds` (nil past it).
    static func wait<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async -> T?) -> T? {
        let box = WaitBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await body()
            done.signal()
        }
        return done.wait(timeout: .now() + seconds) == .success ? box.value : nil
    }
    final class WaitBox<T>: @unchecked Sendable { var value: T? }
}
