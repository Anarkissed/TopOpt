// StructuralAutoRunner — ★ notes30 STRUCTURAL AUTO on the Mac (his rework, 11-27: "go for #2" — start from today's Auto and
// thicken only the struts the Mac's first check shows are short, the add-only loop he approved for Organic). Check 1 is today's
// print-file job with its strength check, unchanged. It passes: done. Short: the app thickens only the short cells
// (StructuralAuto.thicken) and the Mac makes and checks the file again. The lightest file that passes is kept, else the
// stronger; the thickened stress is remembered so the drawing follows the file kept, and the result's report carries the record
// (`structural_auto`) Results reads. Resume: each job is recorded for the version while it is on the Mac (LatticeJobRecorder);
// the round not kept is ended once read.
import Foundation
import TopOptKit

extension LatticeFileButton {
    /// What the chain reads: the stage's own stress (the demand today's lay grades by; its tensor gives the stress's shape for
    /// the thickening), the inputs, the press's identity (what a kept round is for) and the lay's own settings (its ramp).
    public struct StructuralAutoAsk: Sendable {
        public var stage: LatticeDemandField
        public var inputs: StructuralAuto.Inputs
        public var baseKey: Int
        public var settings: LatticeLayoutSession.Settings
        public init(stage: LatticeDemandField, inputs: StructuralAuto.Inputs, baseKey: Int, settings: LatticeLayoutSession.Settings) {
            self.stage = stage; self.inputs = inputs; self.baseKey = baseKey; self.settings = settings
        }
    }

    /// How long the chain waits for the preview's layout (the thickening's cells) before going on without it.
    static let layoutWaitSeconds: TimeInterval = 120

    /// The Lattice press on Structural Auto. `layout`: the layout the first file was made from (the preview's own), with the
    /// check grid's lattice voxels (nil: not known — nothing is thickened; check 1's file stands). `onStep`: the card's steps.
    public static func structuralAutoRunner(config: RemoteRunnerConfig, job: LatticeFileJob.ForPart, ask: StructuralAutoAsk,
                                            projectName: String, strengthJob: Data?, densityGCm3: Double,
                                            defaults: UserDefaults = .standard, inputsRoot: URL = LatticeJobInputs.defaultRoot,
                                            store: StructuralAutoStore = .shared,
                                            layout: @escaping @Sendable (StructuralAuto.CheckField) async -> StructuralAuto.Layout? = { _ in nil },
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
            var fields: [LatticeDemandField?] = [nil]   // the stress each round's file was laid from (nil: today's, the base)
            var thick: StructuralAuto.Thickened?
            var demand = job.demand
            for check in 1...total {
                onStep(.began(.check(check)))
                let made: LatticeFileRun.Made
                do {
                    made = try LatticeFileRun.drive(config: config, modelPath: job.modelPath, jobJSON: job.json,
                                                    projectName: projectName, demand: demand, strengthJob: strengthJob,
                                                    tensor: job.tensor, record: record,
                                                    isCancelled: { !keepGoing.call(check - 1, total, 0) }, onJob: onJob)
                } catch let f as LatticeFileRun.Failure where !f.transient && !mades.isEmpty {
                    break   // a later round the Mac could not make (its print check, say): the file already made stands
                }
                mades.append(made)
                rounds.append(round(of: made))
                _ = keepGoing.call(check, total, 0)
                guard check < total else { break }
                // ★ add-only: a check that passes ends it (nothing is ever thinned)
                if rounds[check - 1].passed { onStep(.shortcut(passed: true)); break }
                // thicken only the short struts, from this check's own lattice stress on the layout the file was made from
                guard let c = StructuralAuto.CheckField.of(made.fields),
                      let lay = wait(seconds: layoutWaitSeconds, { await layout(c) }),
                      let t = StructuralAuto.thicken(check: c, stage: ask.stage, layout: lay, settings: ask.settings, ask.inputs),
                      t.thickenedCells > 0 else {
                    onStep(.shortcut(passed: false))
                    break
                }
                thick = t
                onStep(.began(.thicken))
                demand = LatticeFileJob.demandFile(t.field)
                fields.append(t.field)
            }
            guard !mades.isEmpty else { throw LatticeFileRun.Failure("The print file could not be made") }
            let k = StructuralAuto.kept(rounds)
            for (i, m) in mades.enumerated() where i != k { if let id = m.jobID { record.ended(id) } }
            onStep(.began(.saving))
            // ★ the drawing follows the print file: the thickened round, when it is the one kept (today's lay is on screen)
            if let id = request.projectID {
                if k > 0, let f = fields[k], let t = thick { store.keep(id, .init(baseKey: ask.baseKey, field: f, key: t.key)) }
                else { store.keep(id, nil) }
            }
            let rec = StructuralAuto.Record(margin: ask.inputs.margin, rounds: rounds, keptRound: k,
                                            thickenedCells: thick?.thickenedCells ?? 0, cappedCells: thick?.cappedCells ?? 0,
                                            predicted: thick?.weakestPredicted ?? 0,
                                            short: StructuralAuto.short(rounds: rounds, predicted: thick?.weakestPredicted ?? 0,
                                                                        cappedCells: thick?.cappedCells ?? 0))
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
