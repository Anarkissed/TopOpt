// PrintOrientationJobs — ★ notes27 P7 (builder H; his print orientation 11-23, SPEC 2d "What Check strength re-runs").
//
// "Check strength" along a chosen up re-runs the right chain on the Mac, standing the part that way, and lands its result as the
// new orientation's data (Keep makes it the next version's):
//   an Organic lattice  the strengthening, then the print file (the Mac chains it itself: then = file), with `print_frame`;
//   a cell lattice      the print file with `print_frame`;
//   a topology result   core's analyze job with `orientation_recheck` (one solve with the layers across the new up, the part
//                       standing each way, painted) on the result's own run job and its mesh.
// The lattice jobs go through the same chain/follow code as the Lattice button (LatticeFileButton's runners: strengthen with
// then = file, followChained, fileMade), so the iPad sleeping never stalls them; they are never recorded for the version (a
// check is not the version's run until he keeps it), and Cancel deletes the Mac's jobs as a run's cancel does.
import Foundation
import TopOptKit
import simd

/// Which chain "Check strength" runs, and how long it takes on his stand.
public enum PrintCheckKind: Equatable, Sendable {
    case organic, cells, topology
    public var about: String { self == .topology ? PrintOrientationWords.aboutOneMinute : PrintOrientationWords.aboutTenMinutes }
    var animation: LatticeMacMake.Kind { self == .organic ? .organic : .cells }
}

/// One column of the benefits modal: what a check measured standing one way.
public struct PrintMeasured: Equatable, Sendable {
    public var strength: Double?
    public var layerStrength: Double?
    public var supportMM3: Double?
    public var paintedPlaces: Int?
    public var heightMM: Double?
    public var layers: Int?
    public var bedMM2: Double?
    public var tookS: Double?
    /// ★ notes30 (362's review): the words in the strength numbers' place when the check refused to judge the load (a load on
    /// bare vines: no valid margin); nil: the numbers show.
    public var strengthWords: String? = nil
    public init(strength: Double? = nil, layerStrength: Double? = nil, supportMM3: Double? = nil, paintedPlaces: Int? = nil,
                heightMM: Double? = nil, layers: Int? = nil, bedMM2: Double? = nil, tookS: Double? = nil) {
        self.strength = strength; self.layerStrength = layerStrength; self.supportMM3 = supportMM3; self.paintedPlaces = paintedPlaces
        self.heightMM = heightMM; self.layers = layers; self.bedMM2 = bedMM2; self.tookS = tookS
    }
}

/// One row of the benefits modal: ≤ 5-word label, both numbers; coloured only when it is worse past the gate or better.
public struct PrintBenefitRow: Equatable, Sendable, Identifiable {
    public enum Tone: Equatable, Sendable { case plain, better, worse }
    public let label: String
    public let old: String
    public let new: String
    public let tone: Tone
    public var id: String { label }

    public static func rows(before b: PrintMeasured, after a: PrintMeasured, required: Double) -> [PrintBenefitRow] {
        let dash = "\u{2014}"
        func x(_ v: Double?) -> String { v.map(StrengthWords.x) ?? dash }
        func gate(_ o: Double?, _ n: Double?) -> Tone {
            guard let n else { return .plain }
            if n < required { return .worse }
            if let o, n > o * 1.005 { return .better }
            return .plain
        }
        func supports(_ m: PrintMeasured) -> String {
            guard let v = m.supportMM3 else { return dash }
            let cm3 = v / 1000
            let s = cm3 < 0.05 ? "None" : String(format: "%.1f cm\u{00B3}", cm3)
            return s + (m.paintedPlaces.map { $0 > 0 ? " \u{00B7} " + LatticeFileFacts.count($0, "place") : "" } ?? "")
        }
        func height(_ m: PrintMeasured) -> String {
            guard let h = m.heightMM else { return dash }
            return String(format: "%.0f mm", h) + (m.layers.map { " \u{00B7} " + LatticeFileFacts.number($0) + " layers" } ?? "")
        }
        func bed(_ m: PrintMeasured) -> String { m.bedMM2.map { LatticeFileFacts.number(Int($0.rounded())) + " mm\u{00B2}" } ?? dash }
        func took(_ m: PrintMeasured) -> String { m.tookS.map(LatticeFileFacts.duration) ?? dash }
        func less(_ o: Double?, _ n: Double?) -> Tone { (o != nil && n != nil && n! < o! * 0.995) ? .better : .plain }
        func more(_ o: Double?, _ n: Double?) -> Tone { (o != nil && n != nil && n! > o! * 1.005) ? .better : .plain }
        return [
            // ★ notes30: a column whose check refused the load (bare vines) says so in both strength rows, never a number
            PrintBenefitRow(label: "Strength", old: b.strengthWords ?? x(b.strength), new: a.strengthWords ?? x(a.strength),
                            tone: b.strengthWords == nil && a.strengthWords == nil ? gate(b.strength, a.strength) : .plain),
            PrintBenefitRow(label: "Layer strength", old: b.strengthWords ?? x(b.layerStrength),
                            new: a.strengthWords ?? x(a.layerStrength),
                            tone: b.strengthWords == nil && a.strengthWords == nil ? gate(b.layerStrength, a.layerStrength) : .plain),
            PrintBenefitRow(label: "Supports", old: supports(b), new: supports(a), tone: less(b.supportMM3, a.supportMM3)),
            PrintBenefitRow(label: "Print height", old: height(b), new: height(a), tone: less(b.heightMM, a.heightMM)),
            PrintBenefitRow(label: "Bed contact", old: bed(b), new: bed(a), tone: more(b.bedMM2, a.bedMM2)),
            PrintBenefitRow(label: "Check took", old: took(b), new: took(a), tone: .plain),
        ]
    }

    /// A lattice result's numbers, from its own report (all measured on its file): the governing margin, the solid's layer
    /// margin, the painted supports (and the stand supports of an edge), the height, layers and bed of the way it stands (its
    /// ranking's own first candidate), the time its jobs took.
    public static func measured(latticeReport o: [String: Any]) -> PrintMeasured {
        var m = PrintMeasured()
        // ★ notes30: a load on bare vines is no verdict — its words, no number, until the loaded face is covered
        m.strengthWords = OrganicBareVines.marginWords(report: o)
        m.strength = m.strengthWords == nil ? LatticeStrengthAnswer.decode(report: o)?.governing : nil
        let facts = LatticeFileFacts.decode(o)
        m.layerStrength = m.strengthWords == nil ? facts?.solidLayers : nil
        if let p = o["painted"] as? [String: Any] {
            let stand = p["stand"] as? [String: Any]
            m.supportMM3 = ((p["est_volume_mm3"] as? NSNumber)?.doubleValue ?? 0) + ((stand?["est_volume_mm3"] as? NSNumber)?.doubleValue ?? 0)
            m.paintedPlaces = (p["places_painted"] as? NSNumber)?.intValue
        } else if o["slicer_supports"] as? String == "off" {
            m.supportMM3 = 0
        }
        if let c = PrintOrientationRanking.decode(o["print_orientation"])?.asPlaced {
            m.heightMM = c.heightMM; m.layers = c.layers; m.bedMM2 = c.bedMM2
        } else if let f = facts {
            m.layers = f.layers > 0 ? f.layers : nil
            m.bedMM2 = f.firstLayerMM2 > 0 ? f.firstLayerMM2 : nil
        }
        let t = (facts?.fileSeconds ?? 0) + (facts?.strengthening?.seconds ?? 0)
        m.tookS = t > 0 ? t : nil
        return m
    }

    /// A topology result standing `s` (core's re-check), with the strength numbers given.
    public static func measured(standing s: PrintStanding?, strength: Double?, layers: Double?, tookS: Double?) -> PrintMeasured {
        PrintMeasured(strength: strength, layerStrength: layers, supportMM3: s?.supportMM3, paintedPlaces: nil,
                      heightMM: s?.heightMM, layers: s?.layers, bedMM2: s?.bedMM2, tookS: tookS)
    }
}

/// What the check found: the new orientation's whole result (Keep makes it the next version's) and both columns.
public struct PrintCheckResult {
    public var up: SIMD3<Double>
    public var outcome: OptimizeOutcome
    public var before: PrintMeasured
    public var after: PrintMeasured
    public var required: Double
    public var rows: [PrintBenefitRow] { PrintBenefitRow.rows(before: before, after: after, required: required) }
    public init(up: SIMD3<Double>, outcome: OptimizeOutcome, before: PrintMeasured, after: PrintMeasured, required: Double) {
        self.up = up; self.outcome = outcome; self.before = before; self.after = after; self.required = required
    }
}

/// The topology result's variant the check reads: its index and its mesh as an STL.
public struct PrintCheckVariant: Sendable {
    public var index: Int
    public var stl: Data?
    public init(index: Int, stl: Data?) { self.index = index; self.stl = stl }
}

public enum PrintCheckJobs {
    /// The mesh the re-check reads, beside its job (the worker saves the "recheck_mesh" part under this name).
    public static let recheckMeshName = "recheck.stl"
    /// The analyze job's report with the block.
    public static let analysisName = "analysis.json"
    /// A topology re-check's ceiling (one solve; about a minute on his stand).
    public static let recheckCeilingSeconds: TimeInterval = 30 * 60

    // MARK: the lattice (Organic and cells)

    /// The print file's chain standing along `up` (the job already carries `print_frame`): its result, and both columns —
    /// `before` from the result on screen (its own report), `after` from the new one.
    public static func lattice(config: RemoteRunnerConfig, job: LatticeFileJob.ForPart, strengthJob: Data?, organic: Bool,
                               request: RunRequest, projectName: String, densityGCm3: Double, up: SIMD3<Double>,
                               before: [String: Any], required: Double,
                               isCancelled: @escaping @Sendable () -> Bool,
                               stage: @escaping @Sendable (String) -> Void) async throws -> PrintCheckResult {
        // never recorded for the version: a throwaway record (its defaults and inputs folder are removed after)
        let suite = "orient-check-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let inputs = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: inputs)
        }
        let follow = EventFollower(stage: stage)
        let runner: RunModel.Runner = organic
            ? LatticeFileButton.organicRunner(config: config, job: job, projectName: projectName, strengthJob: strengthJob,
                                              densityGCm3: densityGCm3, defaults: defaults, inputsRoot: inputs,
                                              onJob: { _, url in follow.follow(url) })
            : LatticeFileButton.runner(config: config, job: job, projectName: projectName, strengthJob: strengthJob,
                                       densityGCm3: densityGCm3, defaults: defaults, inputsRoot: inputs,
                                       onJob: { url in follow.follow(url) })
        defer { follow.stop() }
        let outcome = try await Task.detached(priority: .userInitiated) {
            try runner(request, { _, _, _ in !isCancelled() }, { _ in })
        }.value
        let after = (outcome.reportJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            .map(PrintBenefitRow.measured(latticeReport:)) ?? PrintMeasured()
        return PrintCheckResult(up: up, outcome: outcome, before: PrintBenefitRow.measured(latticeReport: before), after: after,
                                required: required)
    }

    // MARK: the topology result

    /// core's analyze job for a topology result standing along `up`: the result's own run job (its loads, material, margin),
    /// as an analyze job of the mesh beside it (`recheck.stl`), re-checked along `up`.
    public static func recheckJob(runJob: Data, up: SIMD3<Double>) throws -> Data {
        guard var o = try JSONSerialization.jsonObject(with: runJob) as? [String: Any] else {
            throw LatticeFileRun.Failure("This result's job could not be read")
        }
        o["mode"] = "analyze"
        o["orientation_recheck"] = ["mesh": recheckMeshName, "build_dir": [up.x, up.y, up.z]]
        return try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }

    /// The re-check on the Mac: sent, followed to its end, its analysis read. Blocking.
    static func recheck(config: RemoteRunnerConfig, modelPath: String, job: Data, mesh: Data, projectName: String,
                        isCancelled: @escaping @Sendable () -> Bool, onJob: (URL) -> Void) throws -> (analysis: [String: Any], seconds: Double?) {
        let w = LatticeFileRun.Worker(config)
        try w.checkEngine()
        let model = try Data(contentsOf: URL(fileURLWithPath: modelPath))
        var parts = RemoteRun.uploadParts(modelPath: modelPath, model: model, jobJSON: job, projectName: projectName)
        parts.append(RemoteRun.UploadPart(name: "recheck_mesh", filename: recheckMeshName, contentType: "application/octet-stream",
                                          data: mesh))
        let jobURL = try w.submit(parts)
        onJob(jobURL)
        let state = try w.wait(jobURL, ceiling: recheckCeilingSeconds, failed: "The strength could not be checked",
                               doneFile: analysisName, isCancelled: isCancelled, onState: { _, _ in })
        guard let d = try w.fetch(jobURL, analysisName), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              o["orientation_recheck"] != nil else {
            throw LatticeFileRun.Failure("The Mac checked it but its answer could not be read")
        }
        let t = RunTiming.fromWorker(createdAt: state["created_at"] as? Double, startedAt: state["started_at"] as? Double,
                                     finishedAt: state["finished_at"] as? Double)
        return (o, t.map { $0.queuedSeconds + $0.solveSeconds })
    }

    /// A topology result checked standing along `up`: the result on screen (`outcome`, its selected variant `variant`) with
    /// core's re-check spliced into its report — the new orientation's data — and both columns: as placed (the run's own
    /// margins, the file standing as it was) and new (measured along `up`).
    public static func topology(config: RemoteRunnerConfig, modelPath: String, runJob: Data, variantSTL: Data,
                                outcome: OptimizeOutcome, variant: Int, up: SIMD3<Double>, projectName: String,
                                isCancelled: @escaping @Sendable () -> Bool,
                                stage: @escaping @Sendable (String) -> Void) async throws -> PrintCheckResult {
        let job = try recheckJob(runJob: runJob, up: up)
        stage(PrintOrientationWords.checkingTitle)
        let r = try await Task.detached(priority: .userInitiated) {
            try recheck(config: config, modelPath: modelPath, job: job, mesh: variantSTL, projectName: projectName,
                        isCancelled: isCancelled, onJob: { _ in })
        }.value
        guard let rc = PrintRecheck.decode(analysis: r.analysis) else {
            throw LatticeFileRun.Failure("The Mac checked it but its answer could not be read")
        }
        let v = outcome.variants.indices.contains(variant) ? outcome.variants[variant] : outcome.variants.first
        let ran = outcome.timing.map { $0.queuedSeconds + $0.solveSeconds }
        var before = PrintBenefitRow.measured(standing: rc.baseline, strength: v?.worstCaseMargin,
                                              layers: v.map(\.interlayerMargin), tookS: ran)
        if let w = OrganicBareVines.marginWords(reportJSON: outcome.reportJSON) {   // ★ notes30: no valid margin to compare
            before.strengthWords = w; before.strength = nil; before.layerStrength = nil
        }
        let after = PrintBenefitRow.measured(standing: rc.standing, strength: rc.margin, layers: rc.layerMargin, tookS: r.seconds)
        let block = r.analysis["orientation_recheck"] ?? [:]
        return PrintCheckResult(up: up, outcome: withReport(outcome, adding: ["orientation_recheck": block]),
                                before: before, after: after, required: rc.required)
    }

    /// The outcome with keys added to its report (a report-less outcome gets one).
    public static func withReport(_ o: OptimizeOutcome, adding extra: [String: Any]) -> OptimizeOutcome {
        var r = (o.reportJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        for (k, v) in extra { r[k] = v }
        let data = (try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys])) ?? o.reportJSON
        return OptimizeOutcome(variants: o.variants, stoppedOnMargin: o.stoppedOnMargin, cancelled: o.cancelled,
                               acceptedCount: o.acceptedCount, voxelVolumeMM3: o.voxelVolumeMM3, gridNx: o.gridNx, gridNy: o.gridNy,
                               gridNz: o.gridNz, gridOrigin: o.gridOrigin, spacing: o.spacing, computedRemotely: o.computedRemotely,
                               appliedClearances: o.appliedClearances, appliedFaceProtections: o.appliedFaceProtections,
                               timing: o.timing, latticeReport: o.latticeReport, buildOrientationJSON: o.buildOrientationJSON,
                               solvedBy: o.solvedBy, growthLadder: o.growthLadder, reportJSON: data)
    }

    /// The Mac's steps, read from a job's event stream as plain words (the print file's card's own reading).
    final class EventFollower: @unchecked Sendable {
        private let stage: @Sendable (String) -> Void
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        init(stage: @escaping @Sendable (String) -> Void) { self.stage = stage }
        func follow(_ url: URL) {
            let say = stage
            let t = Task.detached {
                guard let (bytes, _) = try? await URLSession.shared.bytes(from: url.appendingPathComponent("events")) else { return }
                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled { return }
                        guard line.hasPrefix("data:"),
                              let o = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8))) as? [String: Any],
                              o["type"] as? String == "log", let said = o["line"] as? String,
                              let words = LatticeMacMakeCopy.stage(said) else { continue }
                        say(words)
                    }
                } catch { return }
            }
            lock.lock(); task?.cancel(); task = t; lock.unlock()
        }
        func stop() { lock.lock(); task?.cancel(); task = nil; lock.unlock() }
    }
}
