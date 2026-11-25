// AppModel+Results.swift — ★ his iPad notes 2026-11-23 (img 4, 5, 6; RESULTS_REPORT §1-§4): his v7's print file was made on
// the Mac while TopOpt was in the background, and never saved. What the app does now:
//
//   1. A finished run's result is saved into the run's OWN version folder the moment the run ends, whatever screen is open,
//      inside background time that ends when the file has landed; the whole of a run on the Mac holds background time too.
//      A re-run on a version that already had results saves its new result as well.
//   2. The Lattice button's jobs are recorded (LatticeJobResume.swift); when the app starts or comes back, one the app did
//      not live to save is followed again on the Mac and saved to its version.
//   3. A completion notification carries its version; its tap opens that version straight on its Results (a print file's in
//      the Lattice stage) — nothing on the way (`openResult`).
import Foundation
import Combine
import TopOptKit

extension AppModel {

    // MARK: 1 — the result saved as the run ends

    /// A run began (or was re-attached): the whole of a run on the Mac holds background time.
    func runStarted(_ pm: ProjectModel) {
        guard pm.run.isRemote, runTime[pm.id] == nil else { return }
        runTime[pm.id] = backgroundTime.begin("app.topopt.remote-run")
    }

    /// A run ended. Its own result (never one an empty run gave back) is saved into its version's folder; the run's background
    /// time ends only after the save's own has begun. A print file's job record ends once its result is saved (or it had none
    /// to save: a file that failed its checks).
    func runFinished(_ pm: ProjectModel) {
        let held = runTime.removeValue(forKey: pm.id)
        defer { if let held { backgroundTime.end(held) } }
        let own = pm.run.outcome != nil && !pm.run.restoredPreviousResults
        guard own else { return }
        let printFile = pm.run.lastJobMode == LatticeFileButton.jobMode
        if pm.hasResults {
            saveRunResult(pm) { [weak self] in if printFile { self?.endLatticeRecords(of: pm.id) } }
        } else if printFile {
            endLatticeRecords(of: pm.id)
        }
    }

    /// Save `pm`'s result into its own version folder: its settings (what the result ran with) marked optimized, then the
    /// result, written off the main thread inside background time; `landed` once the file is on disk.
    func saveRunResult(_ pm: ProjectModel, landed: @escaping () -> Void = {}) {
        guard var snapshot = pm.snapshot(savedAt: now()), let outcome = pm.run.outcome else { landed(); return }
        snapshot.optimized = true
        do {
            try store.save(snapshot, modelSource: pm.modelSourceURL)
        } catch {
            AppPopups.shared.show(KeepResultCopy.notSavedTitle, KeepResultCopy.notSavedText, log: "\(error)")
            landed()
            return
        }
        resultRanWith[pm.id] = snapshot
        if let i = recentProjects.firstIndex(where: { $0.id == pm.id }), !recentProjects[i].optimized {
            recentProjects[i].optimized = true
        }
        library.resultsSaved(folder: pm.id, snapshot: snapshot)   // its card reads its own result, never greyed
        writeResults(outcome, other: pm.run.otherOutcome, id: pm.id) { [weak self] in   // ★ notes25: the other stage's beside it
            landed()
            guard let self else { return }
            // the Library's numbers and picture for it — only with the app in front (its mesh is big)
            if self.sceneActive, self.screen == .home { self.library.loadSummaries() }
        }
        // the run's retention pair beside it, as `persist` writes it
        if let art = pm.relatticeArtifacts {
            let s = store, id = pm.id
            Self.resultsQueue.async { try? s.saveRelatticeArtifacts(jobJSON: art.jobJSON, designBin: art.designBin, id: id) }
        } else {
            store.clearRelatticeArtifacts(id: pm.id)
        }
    }

    /// A version's print file jobs are done with: their records (and any kept inputs) go.
    func endLatticeRecords(of id: UUID) {
        for j in RemoteJobStore.loadAll(defaults: remoteJobDefaults) where j.isLatticeJob && j.projectID == id {
            RemoteJobStore.remove(jobID: j.jobID, defaults: remoteJobDefaults)
            LatticeJobInputs.remove(jobID: j.jobID, root: latticeJobInputsRoot)
        }
    }

    // MARK: the app in front or not

    /// The scene came to the front or left it (RootView). Coming back: a Lattice job the app did not live to save is followed
    /// again, and the Library reads any result saved while it was away.
    public func sceneChanged(active: Bool) {
        guard sceneActive != active else { return }
        sceneActive = active
        guard active else { return }
        LatticeMacMake.shared.cameBack()   // ★ notes25 (A6): a chain under way follows the Mac's steps again at once
        resumeLatticeJobs()
        if screen == .home { library.loadSummaries() }
    }

    // MARK: 2 — a recorded Lattice job followed again

    /// ★ his notes 11-23 (RESULTS_REPORT §2): every recorded Lattice job not followed in this process now is followed again on
    /// the Mac in its version's own run (a finished one is fetched at once), without opening anything; its result is then
    /// saved like any run's (`runFinished`). A version that is gone ends its records.
    public func resumeLatticeJobs() {
        let jobs = RemoteJobStore.loadAll(defaults: remoteJobDefaults).filter(\.isLatticeJob)
        guard !jobs.isEmpty else { return }
        if materialsByName.isEmpty { loadMaterials() }   // the result's weight needs the density
        // one per version: its print file's job before its strengthening's, the newest first
        var byVersion: [UUID: PersistedRemoteJob] = [:]
        for j in jobs {
            guard let id = j.projectID else { RemoteJobStore.remove(jobID: j.jobID, defaults: remoteJobDefaults); continue }
            if let have = byVersion[id] {
                let fileFirst = (j.kind == LatticeJobKind.file.rawValue) != (have.kind == LatticeJobKind.file.rawValue)
                if fileFirst ? j.kind == LatticeJobKind.file.rawValue : (j.submittedAt ?? .distantPast) > (have.submittedAt ?? .distantPast) {
                    byVersion[id] = j
                }
            } else {
                byVersion[id] = j
            }
        }
        for (id, job) in byVersion {
            if runningIDs.contains(id) || projectsById[id]?.run.phase == .running { continue }   // followed here already
            guard let recent = recentProjects.first(where: { $0.id == id }) else {
                if !unreadableProjects.contains(where: { $0.id == id }) { endLatticeRecords(of: id) }   // the version is gone
                continue
            }
            guard let pm = liveProject(recent) else { continue }
            follow(job, in: pm)
        }
    }

    /// A version's live model, restored from its folder when it is not open this launch.
    func liveProject(_ recent: RecentProject) -> ProjectModel? {
        if let pm = projectsById[recent.id] { return pm }
        guard let pm = restoreFromDisk(recent) else { return nil }
        projectsById[recent.id] = pm
        return pm
    }

    /// Follow `job` in `pm`'s own run (remote, re-attached), so it lands through the same path as any run.
    func follow(_ job: PersistedRemoteJob, in pm: ProjectModel) {
        let config = RemoteRunnerConfig(host: job.host, port: job.port, expectedFingerprint: job.fingerprint)
        observeRun(pm)
        let before = pm.run.runner
        pm.run.runner = LatticeFileButton.reattachRunner(config: config, job: job, modelPath: pm.importedFile?.path,
                                                         densityGCm3: densityGCm3(for: pm.material), defaults: remoteJobDefaults,
                                                         inputsRoot: latticeJobInputsRoot)
        let request = RunRequest(modelPath: pm.importedFile?.path ?? "", material: pm.material,
                                 materialsPath: materialsPath ?? "", rulesPath: rulesPath ?? "",
                                 resolution: pm.quality.resolution, projectName: job.projectName ?? pm.name, projectID: pm.id)
            .withJobMode(LatticeFileButton.jobMode)
        pm.run.start(request, remote: true, workerName: job.host, reattached: true)
        pm.run.runner = before   // the runner is the run's own for this start only (`start` takes it as it begins)
        if let began = job.submittedAt { pm.run.anchorElapsed(to: began) }
    }

    // MARK: 3 — the notification's tap opens the result

    /// ★ his notes 11-23 ("Tapping the notification should bring you RIGHT to the result screen. Nothing else."): open the
    /// route's version on its Results — a print file's in the Lattice stage, a Topology result on Topology. The screen is
    /// covered (`openingResult`) until its result is read, so nothing else shows on the way; a version still running opens on
    /// its stage, a version that is gone says so.
    public func openResult(_ route: RunResultRoute, waitSeconds: TimeInterval = 30) {
        guard let recent = recentProjects.first(where: { $0.id == route.projectID }) else {
            AppPopups.shared.show(KeepResultCopy.goneTitle, KeepResultCopy.goneText)
            return
        }
        if screen == .workspace, let p = project, p.id != route.projectID { persistCurrentProject() }
        guard let pm = liveProject(recent) else { open(recent); return }
        openingResult = route
        observeRun(pm)
        whenResultIn(pm, waitSeconds: waitSeconds) { [weak self] in self?.land(recent, pm, route) }
    }

    /// Call `done` once `pm` holds a result (a reopened version reads its result in the background), it is running, or the
    /// wait is over.
    func whenResultIn(_ pm: ProjectModel, waitSeconds: TimeInterval, _ done: @escaping () -> Void) {
        // (nothing on disk to read: no wait behind the cover)
        if pm.hasResults || pm.run.phase == .running || !store.hasPersistedResults(id: pm.id) { done(); return }
        var finished = false
        var watch: AnyCancellable?
        let finish = {
            guard !finished else { return }
            finished = true
            watch?.cancel()
            done()
        }
        watch = pm.run.$outcome.receive(on: DispatchQueue.main).sink { _ in if pm.hasResults { finish() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + waitSeconds) { finish() }
    }

    /// The version opened on its Results (the workspace takes it as it appears, or at once when it is the one open).
    func land(_ recent: RecentProject, _ pm: ProjectModel, _ route: RunResultRoute) {
        defer { openingResult = nil }
        if pm.hasResults, pm.run.phase != .running, let o = pm.run.outcome {
            let shown = library.version(pm.id).map { library.shownResult($0) }
            let r = shown.flatMap { s in o.variants.indices.contains(s) && o.variants[s].accepted ? s : nil }
                ?? o.variants.firstIndex(where: \.accepted) ?? 0
            LibraryOpen.exportOnOpen(pm.id, result: r)
        } else if route.lattice {
            LatticeStageOpen.request(pm.id)   // still running, or no result: its own stage
        }
        open(recent)
    }

    /// The tap's route, taken from the router (RootView), opened.
    public func openTappedResult(_ router: RunNotificationRouter = .shared) {
        guard let r = router.take() else { return }
        openResult(r)
    }

    // MARK: 5 — Approved from the saved result

    /// ★ his notes 11-23 (item 5): the Lattice button reads Approved for this version from its SAVED print file (passing its
    /// checks, made from today's settings), so it survives a relaunch (`LatticeSavedResult.approved`).
    public func latticeResultApproved(_ pm: ProjectModel) -> Bool {
        guard pm.hasResults else { return false }
        return LatticeSavedResult.approved(pm, ranWith: resultRanWith[pm.id])
    }
}

/// The words of the result's keeping (plain, each with its fix).
enum KeepResultCopy {
    static let notSavedTitle = "The result couldn’t be saved"
    static let notSavedText = "It is still on screen. Free some space on this iPad, then open the version again to save it."
    static let goneTitle = "That result isn’t here any more"
    static let goneText = "Its version was deleted. Open the part from the Library to see its other versions."
}
