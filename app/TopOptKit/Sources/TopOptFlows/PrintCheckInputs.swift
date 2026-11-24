// PrintCheckInputs — ★ notes28 (his iPad notes on release 18, img 82: "The strength couldn't be checked · notLaid Nothing
// changed. Press Check strength to try again." — "What happened? How should it work? Why did it fail?").
//
// WHY IT FAILED. "Check strength" on an Organic result asked the iPad's lattice PREVIEW for the groups and the stress to send
// (organicMacInputsWhenReady). The preview lays only in Lattice Setup with its views up; on Results it is not laid, and its
// refresh lays nothing there, so the second ask threw `OrganicFileWait.notLaid` at once — and the pop-up printed the Swift
// case's name.
//
// HOW IT WORKS NOW. The check stands the lattice OF THE RESULT being checked:
//   (a) when the print file is made, the Organic inputs that made it — its job (the groups and every setting), the stress it
//       followed and its strength job — are kept with that result in its version's folder (`OrganicResultInputs`, written
//       beside results.plist), and the re-check sends those, standing the new way (`print_frame`);
//   (b) a result with none kept (every one made before this) has the exact lattice of its saved settings laid on this iPad
//       first — on Results too — the checking pop-up saying so, as long as it takes (Cancel stops it), never failing at once
//       (`PrintCheckLay`).
import CryptoKit
import Foundation
import TopOptKit
import simd

// MARK: - (a) the inputs that made a print file, kept with its result

public enum OrganicResultInputs {
    public typealias Kept = LatticeJobInputs.Kept

    /// The folder beside the version's results that holds them.
    public static let folderName = "organic_inputs"
    static let jobName = "job.json"
    /// Which result they made (its report's identity).
    static let keyName = "result.key"
    /// The newest made in this process and not yet written (a stress file is big: a few at most).
    public static let mostRemembered = 3

    /// A result's identity: its report, byte for byte (SHA-256). The report is saved and read back as the same bytes.
    public static func key(_ report: Data?) -> String? {
        guard let d = report, !d.isEmpty else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var made: [(key: String, kept: Kept)] = []

    /// The print file's run made a result from these inputs (the runner, off the main thread).
    public static func remember(_ k: Kept, report: Data?) {
        guard let key = key(report) else { return }
        lock.lock(); defer { lock.unlock() }
        made.removeAll { $0.key == key }
        made.insert((key, k), at: 0)
        if made.count > mostRemembered { made.removeLast(made.count - mostRemembered) }
    }

    /// The inputs this process made `report`'s result from, if it did.
    public static func remembered(report: Data?) -> Kept? {
        lock.lock(); let none = made.isEmpty; lock.unlock()
        guard !none, let key = key(report) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return made.first { $0.key == key }?.kept
    }

    /// Written beside the result in its version's folder (the folder replaced whole: never one result's job beside another's
    /// stress); the key last, so a half-written folder is never read as whole.
    public static func write(_ k: Kept, report: Data?, to dir: URL) throws {
        guard let key = key(report) else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try k.json.write(to: dir.appendingPathComponent(jobName), options: .atomic)
        if let s = k.strengthJob { try s.write(to: dir.appendingPathComponent(LatticeFileJob.strengthJobName), options: .atomic) }
        if let t = k.tensor { try t.write(to: dir.appendingPathComponent(LatticeFileJob.tensorName), options: .atomic) }
        try Data(key.utf8).write(to: dir.appendingPathComponent(keyName), options: .atomic)
    }

    /// Read back: nil unless they made exactly `report`'s result.
    public static func read(from dir: URL, report: Data?) -> Kept? {
        guard let key = key(report), let saved = try? Data(contentsOf: dir.appendingPathComponent(keyName)),
              String(decoding: saved, as: UTF8.self) == key,
              let json = try? Data(contentsOf: dir.appendingPathComponent(jobName)) else { return nil }
        return Kept(json: json, strengthJob: try? Data(contentsOf: dir.appendingPathComponent(LatticeFileJob.strengthJobName)),
                    tensor: try? Data(contentsOf: dir.appendingPathComponent(LatticeFileJob.tensorName)))
    }

    /// The result's own inputs: made in this process, else kept in its version's folder; nil when it has none.
    public static func of(report: Data?, dir: URL?) -> Kept? {
        remembered(report: report) ?? dir.flatMap { read(from: $0, report: report) }
    }

    /// A result's write (AppModel.writeResults, on its queue): the inputs that made either of the version's results, beside it.
    /// Nothing made here: the folder is left as it is (it names the result it belongs to).
    static func keep(reports: [Data?], dir: URL) {
        for r in reports { if let k = remembered(report: r) { try? write(k, report: r, to: dir); return } }
    }

    /// The kept job standing along `up`: its print frame set, the model this version's own copy (the same part, its name),
    /// every other key as the file was made. nil when it cannot be read or carries no stress (an Organic job always does).
    public static func standing(_ k: Kept, up: SIMD3<Double>, modelPath: String) -> LatticeFileJob.ForPart? {
        guard k.tensor != nil, var o = (try? JSONSerialization.jsonObject(with: k.json)) as? [String: Any] else { return nil }
        o["print_frame"] = ["up": [up.x, up.y, up.z]]
        o["model"] = (modelPath as NSString).lastPathComponent
        if k.strengthJob == nil { o.removeValue(forKey: "strength_job") }
        guard let json = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return nil }
        return LatticeFileJob.ForPart(json: json, modelPath: modelPath, demand: nil, tensor: k.tensor)
    }
}

// MARK: - (b) none kept: the result's exact lattice laid on this iPad first

@MainActor
public enum PrintCheckLay {
    /// The iPad's lattice preview, as the check drives it (the workspace's own; a test's stand-in).
    public struct Preview {
        /// The groups and the stress of the lattice laid now (`LatticeLayoutPreview.organicMacInputs`).
        public var inputs: () async throws -> (groups: [LatticeLayoutSession.OrganicGroup], tensor: Data)
        /// The stress the lattice follows, there (the version's own check read back, else run, waited for).
        public var stressReady: () async throws -> Void
        /// Lay the exact lattice of the result's settings — on Results too (the preview's own refresh lays nothing there).
        public var lay: () -> Void
        /// Still laying (or opening the part behind a lattice read back).
        public var busy: () -> Bool
        /// The preview's own line when the lay could not be made (nil: none).
        public var problem: () -> String?
        /// The lay let go — on Cancel, and once its inputs are taken (Results draws none: the iPad's memory back).
        public var stop: () -> Void
        public init(inputs: @escaping () async throws -> (groups: [LatticeLayoutSession.OrganicGroup], tensor: Data),
                    stressReady: @escaping () async throws -> Void, lay: @escaping () -> Void, busy: @escaping () -> Bool,
                    problem: @escaping () -> String?, stop: @escaping () -> Void) {
            self.inputs = inputs; self.stressReady = stressReady; self.lay = lay; self.busy = busy; self.problem = problem
            self.stop = stop
        }
    }

    /// RED CONTROL (tests): as before notes28 — the iPad lays nothing on Results, so a result with nothing laid fails at once.
    public static var controlNoLayOnResults = false
    public static var pollNanoseconds: UInt64 = 300_000_000
    /// Lays that ended with nothing to send and no reason given, before it says it could not.
    public static let laysWithNothing = 3

    /// The groups and the stress to send: those laid now, else the lattice laid here first, waited for as long as it takes.
    public static func organic(_ p: Preview, isCancelled: @escaping @Sendable () -> Bool,
                               said: @escaping @Sendable (String) -> Void) async throws
        -> (groups: [LatticeLayoutSession.OrganicGroup], tensor: Data) {
        do { return try await p.inputs() } catch is LatticeLayoutPreview.OrganicFileWait {}
        if controlNoLayOnResults { return try await p.inputs() }
        var nothing = 0
        do {
            while true {
                if isCancelled() { throw CancellationError() }
                try await p.stressReady()
                said(PrintOrientationWords.layingFirst)
                p.lay()
                try await Task.sleep(nanoseconds: pollNanoseconds)
                while p.busy() {
                    if isCancelled() { throw CancellationError() }
                    try await Task.sleep(nanoseconds: pollNanoseconds)
                }
                do {
                    let taken = try await p.inputs()
                    p.stop()   // the groups and the stress are taken: the lay laid here for the check lets go
                    return taken
                } catch let w as LatticeLayoutPreview.OrganicFileWait {
                    if w == .laying { continue }   // a newer lay began: wait for it
                    // laid nothing (or what it follows moved under it): the preview's own reason, else lay again
                    if w == .notLaid, let why = p.problem(), why != LatticeLayoutPreview.organicNeedsStressLine {
                        throw LatticeFileRun.Failure(why)
                    }
                    nothing += 1
                    if nothing >= laysWithNothing { throw LatticeFileRun.Failure(PrintOrientationWords.couldNotLayText) }
                }
            }
        } catch {
            p.stop()   // Cancel stops the lay; a lay that could not be made lets go too
            throw error
        }
    }
}
