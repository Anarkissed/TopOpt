// FlexibleCoreRun — the big bottom Lattice button's run under Flexible (task
// 2026-09-29-flexible-screens, round 4 batch C2; maintainer, his answer 2: "historically, the
// large bottom buttons are for exports and starting the actual core process. So when Lattice
// Ready shows, tapping it should send to Core and the export path").
//
// ★ THE OTHER SECTIONS' SHAPE, CORE'S FLEXIBLE RUNNER. Structural / Aesthetic: Lattice →
// `requestLatticeRun` → `RunModel.start` → `latticeBridgeRunner` writes the job beside the part
// and calls `run_lattice_job` (core's `lattice_variant_job`), output in a temp folder → the
// results screen and its exports. A job with a `flexible` block is REFUSED on that path: the
// bridge takes only lattice_part / lattice_variant, and core's run_job / analyze_job /
// lattice_variant_job / preflight_job each call `refuse_flexible_job` ("… runs with
// `topopt-cli flexible`"). Core C1 runs it through ONE entry point, `run_flexible_job`
// (core/src/flexible/run.cpp — the `topopt-cli flexible` subcommand), in the always-built
// library the iPad links. So Ready sends the SAME document the Settings page encodes
// (FlexibleStageModel.runJobJSON — the round-trip-tested encoder) to that runner through the
// app's bridge (`flexible_run_job`), the part's folder as its job dir, its output in a temp
// folder (the lattice path's rule), off the main thread; the Export step opens at once and shows
// core's answer. RunModel / RunRequest / requestLatticeRun are untouched: the other sections run
// exactly as before.
//
// ★ WHAT CORE CANNOT RUN IS SAID, NEVER SENT (D2): several squeeze groups, a pinch — the
// encoder throws, the Export step says it in one line ("Not sent: …"), core's reason behind (i).
// ★ C2 VERIFICATION — AND IT IS KNOWN BEFORE THE TAP (FlexibleCoreHold): the pill is a preview,
// not the green Ready, and the step offers what core CAN run (1–3 buttons: each end of a pinch
// resting, each group alone — in the job only — or the filament with squish data). A
// calibrate-first filament is no longer sent to be refused: core refuses it from the very
// catalogue entry the app reads (its code and sentence are behind the (i)).
// ★ A STAGE REFUSAL IS CORE'S ANSWER (a calibrate-first filament, two loaded faces on one
// stack): "Core refused it: …" in one line, core's whole sentence behind (i).
// ★ EXPORTS WAIT ON CORE: core's Flexible runner writes receipts, heat maps and CSVs — no mesh
// (its C2 / C3 exporter is not built) — so each Export card says so in ONE line.
// ★ ON THIS DEVICE ONLY: the LAN worker runs `run` jobs (run_job), which refuse this block.

import Foundation
import TopOptKit

/// Core's answer to one run, as the Export step shows it.
public struct FlexibleCoreRunReport: Equatable, Sendable {
    /// Core's stage refusal (code + sentence), or nil when it designed the lattice.
    public let refusal: FlexRefusal?
    /// ★ C2 VERIFICATION: what was sent when it was not the whole job ("Face 5 resting",
    /// "Group 1 only") — nil for the job Settings describes.
    public var scope: String? = nil
    /// The loaded faces core designed (its receipt's `faces`).
    public let faces: Int
    /// What core's recommender chose (nil on a refusal).
    public let topology: String?
    public let tempC: Double?
    /// Where core wrote its receipt, heat maps and CSVs, and what it wrote.
    public let outDir: String
    public let files: [String]
    public let seconds: Double

    /// The Export step's one line about core.
    public var line: String {
        if let r = refusal { return Self.refusalLine(r) }
        var parts = ["Core designed it"]
        if let s = scope { parts.append(s) }
        if let t = topology { parts.append(t.prefix(1).uppercased() + t.dropFirst()) }
        if let c = tempC { parts.append(String(format: "%.0f \u{00B0}C", c)) }
        parts.append(faces == 1 ? "1 face" : "\(faces) faces")
        return parts.joined(separator: " \u{00B7} ")
    }

    /// A refusal in ONE short line (core's whole sentence goes behind the (i)): the stage's known
    /// codes in plain words, else core's first sentence.
    public static func refusalLine(_ r: FlexRefusal) -> String {
        let short: [String: String] = [
            "calibrate_first": "no squish data for this filament yet",
            "one_profile_per_stack": "two pressed faces share one stack",
            "temperature_not_tested": "that nozzle temperature was never tested",
            "topology_no_data": "no data for that lattice type",
            "honeycomb_side_stack": "honeycomb can\u{2019}t run sideways",
            "no_data": "nothing here has squish data",
        ]
        if let s = short[r.code] { return "Core refused it: " + s }
        let first = r.reason.components(separatedBy: ". ").first ?? r.reason
        return "Core refused it: " + first
    }

    /// Read core's answer: the refusal from the result, the choices from its receipt.
    public static func of(_ r: FlexRunInfo, outDir: String, seconds: Double, scope: String? = nil) -> FlexibleCoreRunReport {
        let receipt = (try? JSONSerialization.jsonObject(with: Data(r.receiptJSON.utf8))) as? [String: Any] ?? [:]
        let faces = (receipt["faces"] as? [Any])?.count ?? 0
        var rep = FlexibleCoreRunReport(refusal: r.refusal, faces: faces,
                                        topology: r.refusal == nil ? receipt["topology"] as? String : nil,
                                        tempC: r.refusal == nil ? (receipt["nozzle_temp_c"] as? NSNumber)?.doubleValue : nil,
                                        outDir: outDir, files: r.files, seconds: seconds)
        rep.scope = scope
        return rep
    }
}

/// The run and the Export step it opens (observed only by the pill and the Export mount — never
/// by the workspace's body).
@MainActor
public final class FlexibleCoreRun: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle
        case sending
        case ran(FlexibleCoreRunReport)
        /// The encoder refused: what core cannot run yet (one line, and the whole reason).
        case notSent(line: String, why: String)
        /// Core threw on the input (its words).
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle
    /// The Export step is up.
    @Published public private(set) var shown = false
    /// ★ C2 VERIFICATION: why the job Settings describes is not sent as it stands, and what can
    /// be sent instead (the step's 1–3 buttons) — read on each tap of the pill.
    @Published public private(set) var hold: FlexibleCoreHold?
    /// The document the phase answers (the same job is not sent twice).
    public private(set) var sentJob: String?
    /// The step's button that sent it (nil: the job Settings describes).
    public private(set) var sentFix: FlexibleCoreFix?
    /// ★ C2 VERIFICATION: a button of the step was tapped (the main stage acts on it — the model
    /// and the stage's navigation are its).
    public var onFix: ((FlexibleCoreFix) -> Void)?
    /// The last run's temp folder (deleted when the next job is sent — they were never cleaned).
    private var lastOut: String?
    /// How many times core was called (tests).
    var runs = 0
    /// Core's Flexible runner (tests may stand in for it).
    var runner: @Sendable (_ jobJSON: String, _ jobDir: String, _ outDir: String, _ materialsPath: String) throws -> FlexRunInfo = { json, dir, out, materials in
        try FlexibleCore.runJob(jobJSON: json, jobDir: dir, outDir: out, materialsPath: materials,
                                fingerprint: CoreFingerprint.value)
    }

    public init() {}

    public var isSending: Bool { phase == .sending }

    public static let sendingLine = "Sending to core\u{2026}"
    /// ★ Each Export card's ONE line while core has no Flexible exporter.
    public static let exportsWait = "Waits on core\u{2019}s Flexible exporter"

    /// What core cannot run yet, in one line (the encoder's whole sentence goes behind (i)).
    public nonisolated static func notSentLine(_ e: FlexibleJob.EncodeError) -> String {
        switch e {
        case .noFilament: return "Not sent: pick a filament first"
        case .noLoadedFace: return "Not sent: press a face first"
        case .noPart: return "Not sent: the part\u{2019}s file is missing"
        case .missingStampGrid: return "Not sent: a stamp is not on its face yet"
        case .squeezeGroups: return "Not sent: core runs one squeeze group at a time"
        case .pinch: return "Not sent: core can\u{2019}t press both ends yet"
        }
    }

    /// Ready's tap: open the Export step and send the job Settings describes — unless core's
    /// answer to this very job is already in hand, or a run is in flight. ★ C2 VERIFICATION: a job
    /// core cannot take as it stands (FlexibleCoreHold) is not sent: the step says why and offers
    /// what core can run; an answer the step already has for one of its own buttons stands.
    public func send(_ m: FlexibleStageModel) {
        shown = true
        guard !isSending else { return }
        hold = m.coreHold
        if let h = hold {
            if let f = sentFix, h.fixes.contains(f), case .ran = phase,
               (try? m.runJobJSON(resting: Set(f.resting))) == sentJob { return }
            sentJob = nil; sentFix = nil
            phase = .notSent(line: h.line, why: h.why)
            return
        }
        let job: String
        do {
            job = try m.runJobJSON()
        } catch let e as FlexibleJob.EncodeError {
            sentJob = nil; sentFix = nil
            phase = .notSent(line: Self.notSentLine(e), why: e.description)
            return
        } catch {
            sentJob = nil; sentFix = nil
            phase = .notSent(line: "Not sent", why: "\(error)")
            return
        }
        if job == sentJob, sentFix == nil, case .ran = phase { return }   // the same job: its answer stands
        start(job, model: m, fix: nil)
    }

    /// ★ C2 VERIFICATION: one of the step's buttons that SENDS — the job with those faces resting
    /// (in the job only). A filament button is the stage's (it changes his settings).
    public func send(_ m: FlexibleStageModel, fix: FlexibleCoreFix) {
        guard case .send = fix, !isSending else { return }
        shown = true
        let job: String
        do {
            job = try m.runJobJSON(resting: Set(fix.resting))
        } catch let e as FlexibleJob.EncodeError {
            phase = .notSent(line: Self.notSentLine(e), why: e.description)
            return
        } catch {
            phase = .notSent(line: "Not sent", why: "\(error)")
            return
        }
        if job == sentJob, case .ran = phase { return }
        start(job, model: m, fix: fix)
    }

    private func start(_ job: String, model m: FlexibleStageModel, fix: FlexibleCoreFix?) {
        guard let materials = m.materialsPath, let file = m.project.importedFile else {
            sentJob = nil; sentFix = nil
            phase = .failed("The filament catalogue or the part is missing")
            return
        }
        let dir = (file.path as NSString).deletingLastPathComponent
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("flexible-\(UUID().uuidString)", isDirectory: true).path
        if let old = lastOut { try? FileManager.default.removeItem(atPath: old) }
        lastOut = out
        sentJob = job
        sentFix = fix
        phase = .sending
        runs += 1
        let runner = self.runner
        let scope = fix?.scope
        let t0 = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Phase
            do {
                let r = try runner(job, dir, out, materials)
                result = .ran(FlexibleCoreRunReport.of(r, outDir: out, seconds: Date().timeIntervalSince(t0), scope: scope))
            } catch {
                result = .failed("\(error)")
            }
            await self?.land(result, for: job)
        }
    }

    /// Core's answer, on the main actor (★ C2 VERIFICATION: a method — the captured `self` was
    /// read inside MainActor.run, a Swift 6 error).
    private func land(_ result: Phase, for job: String) {
        guard sentJob == job else { return }
        phase = result
    }

    /// The Export step's close (the run, if any, carries on and its answer stays).
    public func close() { shown = false }

    /// The Export step's one line about core.
    public var line: String {
        switch phase {
        case .idle: return ""
        case .sending: return Self.sendingLine
        case .ran(let r): return r.line
        case .notSent(let line, _): return line
        case .failed: return "Core couldn\u{2019}t run it"
        }
    }

    /// Behind the (i): core's whole sentence, or where its receipt and heat maps are.
    public var info: String? {
        switch phase {
        case .idle, .sending: return nil
        case .ran(let r):
            if let f = r.refusal { return "\(f.reason) (\(f.code))" }
            // ★ C2 VERIFICATION: no temp path (useless on an iPad)
            return "Core wrote its receipt, heat maps and CSVs (\(r.files.count) files). It designs the density, not the printable file yet."
        case .notSent(_, let why): return why
        case .failed(let why): return why
        }
    }
}

extension FlexibleMainStatus {
    /// What a tap on the big bottom button does (his answer 2).
    public enum Tap: Equatable, Sendable { case send, openSettings, wait }

    public static let sending = "Sending to core\u{2026}"

    public var tap: Tap {
        switch tone {
        // ★ C2 VERIFICATION: a preview core can't take as it stands opens the Export step on why
        case .ready, .preview: return .send
        case .fix, .idle: return .openSettings
        case .building: return .wait
        }
    }

    /// While core runs the job: the pill says so; a tap shows the run (still `.send`).
    public func whileSending(_ on: Bool) -> FlexibleMainStatus {
        guard on, tone == .ready || tone == .preview else { return self }
        return FlexibleMainStatus(line: Self.sending, tone: tone, fix: nil)
    }
}
