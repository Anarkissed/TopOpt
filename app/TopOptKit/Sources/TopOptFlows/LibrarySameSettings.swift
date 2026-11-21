// LibrarySameSettings.swift — B5 (ledger note 3; the reviewer's (a), 11-04 02:44Z: a cached per-version check).
//
// His words (note 3): "after running an optimization, running it again doesn't work". The design: after a run lands, a
// change makes a draft and Optimize is live again; "If nothing changed, Optimize stays grey with one line under it: 'Same
// settings as v6'." The workspace knew what it ran with only in the session that ran it. A Library version reopened later
// now learns it once, on open: its saved run_job.json (the job its run sent) against the job this setup would send.

import Foundation

enum LibrarySameSettings {
    /// Whether two job documents ask for the same run: equal once read, key order aside, and the model's file name set
    /// aside (a reopened version names its store copy, "model.stl"). One that can't be read is never the same.
    static func sameJob(_ a: Data, _ b: Data) -> Bool {
        guard var x = (try? JSONSerialization.jsonObject(with: a)) as? [String: Any],
              var y = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any] else { return false }
        x["model"] = nil; y["model"] = nil
        return NSDictionary(dictionary: x).isEqual(to: y)
    }

    /// The request this version ran with, when the setup open now is it: Topology's Optimize first, then the run that
    /// carries the lattice. nil when it has no saved job (an on-device run keeps none) or the setup has changed.
    @MainActor static func ranWith(savedJob: Data?, request: (Bool) -> RunRequest?) -> RunRequest? {
        guard let savedJob else { return nil }
        for lattice in [false, true] {
            guard let r = request(lattice), let job = try? RemoteRun.buildJobJSON(r) else { continue }
            if sameJob(job, savedJob) { return r }
        }
        return nil
    }
}
