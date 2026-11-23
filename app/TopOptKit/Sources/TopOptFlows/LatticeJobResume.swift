// LatticeJobResume.swift — ★ his iPad notes 2026-11-23 (his v7's print file lost, RESULTS_REPORT §2): the Lattice button's jobs
// on the Mac — Organic's strengthening and the print file — were never recorded, so when the app was gone before it saved the
// result nothing pointed back to the Mac's job (his is still there). Now each is recorded as the Optimize run's is
// (RemoteJobStore, `kind`), from its submit until its result is saved in its version's folder; when the app starts or comes
// back, a recorded job is followed again on the Mac (a finished one fetched straight away: lattice_file.json, the file,
// fields.bin), read with `LatticeFileButton.outcome` and saved to its version. A strengthening keeps the file job's own inputs
// beside its record (`LatticeJobInputs`), so its file can still be made if the app is gone when it ends.
import Foundation
import TopOptKit

/// Which Lattice button job a record is.
public enum LatticeJobKind: String, Sendable {
    case file = "lattice_file"
    case strengthen = "lattice_strengthen"
}

/// How a Lattice run records its jobs for its version: saved at submit, ended when the job fails, is cancelled or cannot be read
/// (never when the Mac only could not be reached). A finished file job's record stays until its result is saved (AppModel).
public struct LatticeJobRecorder {
    public var projectID: UUID?
    public var projectName: String
    public var organic: Bool
    public var defaults: UserDefaults
    public var inputsRoot: URL

    public init(projectID: UUID?, projectName: String, organic: Bool, defaults: UserDefaults = .standard,
                inputsRoot: URL = LatticeJobInputs.defaultRoot) {
        self.projectID = projectID
        self.projectName = projectName
        self.organic = organic
        self.defaults = defaults
        self.inputsRoot = inputsRoot
    }

    /// The job is on the Mac: recorded for its version (nothing to record for a run with no version).
    func saved(_ kind: LatticeJobKind, jobID: String, config: RemoteRunnerConfig, strengthenJobID: String? = nil) {
        guard let projectID else { return }
        let prior = RemoteJobStore.loadAll(defaults: defaults).first { $0.jobID == jobID }?.submittedAt
        RemoteJobStore.save(PersistedRemoteJob(host: config.host, port: config.port, fingerprint: config.expectedFingerprint,
                                               jobID: jobID, submittedAt: prior ?? Date(), projectID: projectID,
                                               projectName: projectName, kind: kind.rawValue, organic: organic,
                                               strengthenJobID: strengthenJobID),
                            defaults: defaults)
    }

    /// The job is over for the app: its record and any inputs kept beside it go.
    func ended(_ jobID: String) {
        RemoteJobStore.remove(jobID: jobID, defaults: defaults)
        LatticeJobInputs.remove(jobID: jobID, root: inputsRoot)
    }

    /// A strengthening's file-job inputs, kept beside its record.
    func keepInputs(jobID: String, json: Data, strengthJob: Data?, tensor: Data?) {
        guard projectID != nil else { return }
        LatticeJobInputs.save(.init(json: json, strengthJob: strengthJob, tensor: tensor), jobID: jobID, root: inputsRoot)
    }

    /// What the Mac made, read as the result; a file that cannot be read ends its job's record (it never will be).
    func reading<T>(_ made: LatticeFileRun.Made, _ body: () throws -> T) rethrows -> T {
        do { return try body() } catch {
            if let id = made.jobID { ended(id) }
            throw error
        }
    }
}

/// The print file's job inputs, kept on this iPad beside a strengthening's record (one folder per job).
public enum LatticeJobInputs {
    public struct Kept: Equatable {
        public var json: Data
        public var strengthJob: Data?
        public var tensor: Data?
    }

    public static var defaultRoot: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("LatticeJobInputs", isDirectory: true)
    }

    static func folder(_ jobID: String, _ root: URL) -> URL? {
        guard !jobID.isEmpty, !jobID.contains("/"), !jobID.contains("..") else { return nil }
        return root.appendingPathComponent(jobID, isDirectory: true)
    }

    static func save(_ k: Kept, jobID: String, root: URL) {
        guard let dir = folder(jobID, root) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? k.json.write(to: dir.appendingPathComponent("job.json"), options: .atomic)
        if let s = k.strengthJob { try? s.write(to: dir.appendingPathComponent(LatticeFileJob.strengthJobName), options: .atomic) }
        if let t = k.tensor { try? t.write(to: dir.appendingPathComponent(LatticeFileJob.tensorName), options: .atomic) }
    }

    public static func load(jobID: String, root: URL) -> Kept? {
        guard let dir = folder(jobID, root), let json = try? Data(contentsOf: dir.appendingPathComponent("job.json")) else { return nil }
        return Kept(json: json, strengthJob: try? Data(contentsOf: dir.appendingPathComponent(LatticeFileJob.strengthJobName)),
                    tensor: try? Data(contentsOf: dir.appendingPathComponent(LatticeFileJob.tensorName)))
    }

    static func remove(jobID: String, root: URL) {
        guard let dir = folder(jobID, root) else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}

extension LatticeFileButton {
    /// ★ his notes 11-23: a recorded Lattice job followed again on the Mac — still running: followed to its end; finished:
    /// fetched at once — and read as the result exactly as the live run reads it. A strengthening goes on to make its file from
    /// the inputs kept beside it (the model is the version's own). Blocking, as every runner.
    public static func reattachRunner(config: RemoteRunnerConfig, job: PersistedRemoteJob, modelPath: String?,
                                      densityGCm3: Double, defaults: UserDefaults = .standard,
                                      inputsRoot: URL = LatticeJobInputs.defaultRoot) -> RunModel.Runner {
        { request, progress, _ in
            let keepGoing = Progress(progress)
            let organic = job.organic ?? false
            let name = job.projectName ?? request.projectName
            let record = LatticeJobRecorder(projectID: job.projectID ?? request.projectID, projectName: name, organic: organic,
                                            defaults: defaults, inputsRoot: inputsRoot)
            if LatticeJobKind(rawValue: job.kind ?? "") == .strengthen {
                _ = keepGoing.call(0, 2, 0)
                let s = try LatticeFileRun.followStrengthen(config: config, jobID: job.jobID, record: record,
                                                            isCancelled: { !keepGoing.call(0, 2, 0) })
                _ = keepGoing.call(1, 2, 0)
                guard let kept = LatticeJobInputs.load(jobID: job.jobID, root: inputsRoot), let modelPath else {
                    record.ended(job.jobID)
                    throw LatticeFileRun.Failure(LatticeJobResumeCopy.cantFinish)
                }
                return try fileFromStrengthening(config: config, modelPath: modelPath, jobJSON: kept.json, projectName: name,
                                                 strengthJob: kept.strengthJob, tensor: kept.tensor, strengthened: s,
                                                 record: record, densityGCm3: densityGCm3,
                                                 isCancelled: { !keepGoing.call(1, 2, 0) })
            }
            _ = keepGoing.call(0, 1, 0)
            var made = try LatticeFileRun.follow(config: config, jobID: job.jobID, record: record,
                                                 isCancelled: { !keepGoing.call(0, 1, 0) })
            // the strengthening this file replays: its summary rides the result, as the live run's does
            if organic, let sid = job.strengthenJobID,
               let sd = LatticeFileRun.Worker(config).file(config.baseURL.appendingPathComponent("jobs").appendingPathComponent(sid),
                                                           "strengthen.json"),
               let s = LatticeFileRun.Strengthened.parse(sd)?.summary {
                made.reportJSON = withStrengthen(made.reportJSON, s)
            }
            let m = made
            return try record.reading(m) { try outcome(m, densityGCm3: densityGCm3, organic: organic) }
        }
    }
}

/// The words a resumed Lattice job can say (plain, with the fix).
enum LatticeJobResumeCopy {
    static let cantFinish = "The strengthened lattice’s print file couldn’t be made after the app closed. Press Lattice again."
}
