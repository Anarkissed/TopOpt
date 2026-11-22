// GenerationTimingLog — ★ his ask 2026-11-22 (afternoon notes on release 13): "Set up a process that prints the time it took and
// what changes occurred for each generation (sample/draft/print) and print it so it can be accessible by you after some testing."
//
// One JSON line per finished, failed or cancelled generation (the Lattice settings' sample, the Organic Draft and exact lays,
// a regular lattice's lay, a remembered preview shown again, the print file's job, the stress check), appended to the app's
// Documents folder: Documents/TopOptTiming/generations.jsonl (the last 2,000 lines kept). 362 copies it off his iPad with
//   xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier com.nadim.topopt \
//     --source Documents/TopOptTiming/generations.jsonl --destination generations.jsonl
// Each line: what ran (kind), when it began, how long it took (wall), how it ended (and why), its strut count, where it ran,
// the device (model, system, memory), the memory free before and after and the app's footprint and peak, the thermal state,
// the core build, the part (file name, faces, triangles), every setting that went in (the lattice settings, each group's
// Organic settings as laid, the print parameters, a few flags), the engine's own per-stage times as they come, and `changed`:
// the settings that differ from the previous line of the same kind (old → new).
// Nothing blocking runs on the main thread: a record is built from values, encoded and appended on the log's own queue.
import Foundation
import Darwin
#if os(iOS)
import os
#endif

public final class GenerationTimingLog: @unchecked Sendable {
    public static let shared = GenerationTimingLog()

    public enum Kind: String, Sendable, CaseIterable {
        case sample, draft, exact, restored, printFile, stressCheck
    }
    public enum Outcome: String, Sendable { case done, failed, cancelled }

    public static let folderName = "TopOptTiming"
    public static let fileName = "generations.jsonl"
    public static let keepLinesDefault = 2000

    /// Where it ran.
    public static var thisDevice: String {
        #if os(iOS)
        return "this iPad"
        #else
        return "this Mac"
        #endif
    }
    public static let aMac = "a Mac"

    /// A named value that went in (a flag, a number, a word).
    public enum Value: Sendable, Equatable {
        case text(String), number(Double), flag(Bool)
        var json: Any {
            switch self {
            case .text(let s): return s
            case .number(let d): return d.isFinite ? d : String(describing: d)
            case .flag(let b): return b
            }
        }
    }

    /// The part a generation was made on: its file's name (never its path), faces and triangles.
    public struct Part: Sendable, Equatable {
        public var file: String
        public var faces: Int?
        public var triangles: Int?
        public init(file: String, faces: Int? = nil, triangles: Int? = nil) {
            self.file = file; self.faces = faces; self.triangles = triangles
        }
    }

    /// Everything that went in, as values (encoded on the log's queue, never on the main thread).
    public struct Inputs: Sendable {
        public var part: Part?
        public var lattice: LatticeSettings?
        /// Each group's Organic settings as they were laid (Auto / Manual resolved), by the group's name.
        public var organic: [String: LatticeOrganicLook] = [:]
        public var printParams: PrintParams?
        public var values: [String: Value] = [:]
        public init() {}
    }

    /// One generation under way. Ending it twice writes it once (the first end wins).
    public final class Pending: @unchecked Sendable {
        public let kind: Kind
        public let started: Date
        let ranOn: String
        let inputs: Inputs
        let availableBeforeMB: Double?
        let thermalBefore: ProcessInfo.ThermalState
        private let lock = NSLock()
        private var over = false
        init(kind: Kind, started: Date, ranOn: String, inputs: Inputs) {
            self.kind = kind; self.started = started; self.ranOn = ranOn; self.inputs = inputs
            availableBeforeMB = GenerationTimingLog.availableMB()
            thermalBefore = ProcessInfo.processInfo.thermalState
        }
        /// True once: the caller writes (or drops) it.
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if over { return false }; over = true; return true }
        public var isOver: Bool { lock.lock(); defer { lock.unlock() }; return over }
    }

    private let queue = DispatchQueue(label: "generation-timing-log", qos: .utility)
    private let lock = NSLock()
    private var dirOverride: URL?
    private var keepOverride: Int?
    // the queue's own
    private var lineCount: Int?
    private var lastByKind: [String: [String: String]] = [:]
    private var lookedUp: Set<String> = []

    public init() {}

    /// The folder (tests set their own; the app: Documents/TopOptTiming on the iPad, a temporary folder on the Mac test host).
    public var directory: URL {
        get {
            lock.lock(); defer { lock.unlock() }
            return dirOverride ?? Self.defaultDirectory
        }
        set {
            queue.sync {
                lock.lock(); dirOverride = newValue; lock.unlock()
                lineCount = nil; lastByKind = [:]; lookedUp = []
            }
        }
    }
    /// How many lines are kept (the newest).
    public var keepLines: Int {
        get { lock.lock(); defer { lock.unlock() }; return keepOverride ?? Self.keepLinesDefault }
        set { lock.lock(); keepOverride = newValue; lock.unlock() }
    }
    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    static var defaultDirectory: URL {
        #if os(iOS)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent(folderName, isDirectory: true)
        #else
        return FileManager.default.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
        #endif
    }

    // MARK: the calls

    /// A generation begins now (its memory and thermal state are read here, cheaply).
    public func begin(_ kind: Kind, inputs: Inputs, ranOn: String = GenerationTimingLog.thisDevice,
                      started: Date = Date()) -> Pending {
        Pending(kind: kind, started: started, ranOn: ranOn, inputs: inputs)
    }

    /// It ended: one line, written on the log's queue. `stages`: the engine's own times (ms) and counts, as they come.
    public func end(_ p: Pending, _ outcome: Outcome, reason: String? = nil, struts: Int? = nil,
                    stages: [String: Double] = [:], extra: [String: Value] = [:], ended: Date = Date()) {
        guard p.claim() else { return }
        let after = Self.availableMB(), thermal = ProcessInfo.processInfo.thermalState, mem = Self.residentMB()
        queue.async { [self] in
            write(p, outcome, reason: reason, struts: struts, stages: stages, extra: extra, ended: ended,
                  availableAfterMB: after, thermalAfter: thermal, resident: mem)
        }
    }

    /// It never really began (skipped before it started): nothing is written.
    public func discard(_ p: Pending) { _ = p.claim() }

    // MARK: the print file's run (the Lattice button's job: begun as it is sent, ended as the run lands)

    private var fileRun: Pending?
    /// The print file's job was sent (`ranOn`: a Mac, or this iPad).
    public func printFileRunBegins(_ inputs: Inputs, ranOn: String) {
        let p = begin(.printFile, inputs: inputs, ranOn: ranOn)
        lock.lock(); let old = fileRun; fileRun = p; lock.unlock()
        if let old { end(old, .cancelled, reason: "a newer print file was asked for") }
    }
    /// The run moved: one that is no longer running ends the print file's line (nothing when none was going).
    @MainActor
    public func printFileRunMoved(_ phase: RunPhase, outcome: OptimizeOutcome?, failure: String?) {
        guard phase != .running else { return }
        lock.lock(); let p = fileRun; fileRun = nil; lock.unlock()
        guard let p else { return }
        switch phase {
        case .succeeded:
            let v = outcome?.variants.first
            var extra: [String: Value] = [:]
            if let v {
                extra["accepted"] = .flag(v.accepted)
                extra["strengthPasses"] = .flag(v.v3Passes)
                extra["massGrams"] = .number(v.massGrams)
            }
            end(p, .done, stages: v.map { ["fileTriangles": Double($0.meshTriangleCount)] } ?? [:], extra: extra)
        case .failed:
            end(p, .failed, reason: failure ?? "the run failed")
        default:
            end(p, .cancelled, reason: phase == .cancelled ? "cancelled" : "the run ended without a result")
        }
    }

    /// Waits for every line asked for so far to be written (tests).
    public func flush() { queue.sync {} }

    /// The lines on file, oldest first (tests; 362 reads the file itself).
    public func records() -> [[String: Any]] {
        queue.sync {
            guard let d = try? Data(contentsOf: fileURL) else { return [] }
            return String(decoding: d, as: UTF8.self).split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
        }
    }

    // MARK: the queue's work

    private func write(_ p: Pending, _ outcome: Outcome, reason: String?, struts: Int?, stages: [String: Double],
                       extra: [String: Value], ended: Date, availableAfterMB: Double?, thermalAfter: ProcessInfo.ThermalState,
                       resident: (footprint: Double, peak: Double)?) {
        var r: [String: Any] = [
            "kind": p.kind.rawValue,
            "start": Self.iso(p.started),
            "seconds": Self.round(ended.timeIntervalSince(p.started), 3),
            "outcome": outcome.rawValue,
            "ranOn": p.ranOn,
            "device": Self.device,
            "app": Self.app,
            "core": CoreFingerprint.value,
            "coreBuilt": CoreFingerprint.buildTime,
            "thermal": ["start": Self.word(p.thermalBefore), "end": Self.word(thermalAfter)],
        ]
        var memory: [String: Any] = [:]
        if let b = p.availableBeforeMB { memory["availableBeforeMB"] = Self.round(b, 1) }
        if let a = availableAfterMB { memory["availableAfterMB"] = Self.round(a, 1) }
        if let m = resident {
            memory["footprintMB"] = Self.round(m.footprint, 1)
            memory["peakResidentMB"] = Self.round(m.peak, 1)   // the app's peak since it started
        }
        r["memory"] = memory
        if let reason { r["reason"] = reason }
        if let struts { r["struts"] = struts }
        if !stages.isEmpty { r["stages"] = stages.mapValues { Self.round($0, 3) } }
        if !extra.isEmpty { r["extra"] = extra.mapValues(\.json) }
        let inputs = Self.json(p.inputs)
        r["inputs"] = inputs
        let flat = Self.flatten(inputs)
        let kind = p.kind.rawValue
        if !lookedUp.contains(kind) {   // the previous line of this kind from an earlier run of the app
            lookedUp.insert(kind)
            if lastByKind[kind] == nil, let prev = lastOnFile(kind: kind) { lastByKind[kind] = prev }
        }
        if let prev = lastByKind[kind] {
            r["changed"] = Self.diff(prev, flat)
        } else {
            r["changed"] = [String: String]()
            r["firstOfKind"] = true
        }
        lastByKind[kind] = flat
        guard let data = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]) else { return }
        append(data)
    }

    private func append(_ line: Data) {
        let fm = FileManager.default
        let dir = directory, url = fileURL
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if lineCount == nil {
                lineCount = (try? Data(contentsOf: url)).map { d in d.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } } ?? 0
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            _ = try h.seekToEnd()
            try h.write(contentsOf: line + Data([0x0A]))
            lineCount! += 1
            let keep = keepLines
            if lineCount! > keep { try trim(url, keep: keep) }
        } catch {
            NSLog("TopOpt timing log: %@", "\(error)")   // the log only; never the page
        }
    }

    /// Keeps the newest `keep` lines.
    private func trim(_ url: URL, keep: Int) throws {
        let d = try Data(contentsOf: url)
        let lines = d.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard lines.count > keep else { lineCount = lines.count; return }
        var out = Data()
        for l in lines.suffix(keep) { out.append(contentsOf: l); out.append(0x0A) }
        try out.write(to: url, options: .atomic)
        lineCount = keep
    }

    /// The flattened inputs of the newest line of `kind` already on file (nil: none).
    private func lastOnFile(kind: String) -> [String: String]? {
        guard let d = try? Data(contentsOf: fileURL) else { return nil }
        let needle = Data("\"kind\":\"\(kind)\"".utf8)
        for l in d.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() where Data(l).range(of: needle) != nil {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(l))) as? [String: Any], o["kind"] as? String == kind else {
                continue
            }
            return Self.flatten(o["inputs"] as? [String: Any] ?? [:])
        }
        return nil
    }

    // MARK: the record's parts

    static func json(_ i: Inputs) -> [String: Any] {
        var o: [String: Any] = [:]
        if let p = i.part {
            var part: [String: Any] = ["file": p.file]
            if let f = p.faces { part["faces"] = f }
            if let t = p.triangles { part["triangles"] = t }
            o["part"] = part
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        func obj<T: Encodable>(_ v: T) -> Any? {
            (try? enc.encode(v)).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        }
        if let l = i.lattice { o["lattice"] = obj(l) }
        if !i.organic.isEmpty { o["organic"] = i.organic.compactMapValues { obj($0) } }
        if let pp = i.printParams { o["printParams"] = obj(pp) }
        if !i.values.isEmpty { o["values"] = i.values.mapValues(\.json) }
        return o
    }

    /// "a.b.c" → the leaf's JSON (an array is one leaf).
    static func flatten(_ o: [String: Any], prefix: String = "") -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in o {
            let key = prefix.isEmpty ? k : prefix + "." + k
            if let d = v as? [String: Any] {
                out.merge(flatten(d, prefix: key)) { $1 }
            } else {
                out[key] = leaf(v)
            }
        }
        return out
    }
    static func leaf(_ v: Any) -> String {
        if let s = v as? String { return s }
        guard let d = try? JSONSerialization.data(withJSONObject: [v], options: [.sortedKeys, .fragmentsAllowed]) else {
            return "\(v)"
        }
        return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
    }

    /// The keys whose values differ, "old → new" ("—": not there).
    static func diff(_ old: [String: String], _ new: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for k in Set(old.keys).union(new.keys) where old[k] != new[k] {
            out[k] = "\(old[k] ?? "\u{2014}") \u{2192} \(new[k] ?? "\u{2014}")"
        }
        return out
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
    static func round(_ v: Double, _ places: Int) -> Double {
        guard v.isFinite else { return 0 }
        let m = pow(10, Double(places))
        return (v * m).rounded() / m
    }
    static func word(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// The device: its model ("iPad16,6"), system and memory.
    static let device: [String: Any] = {
        var u = utsname()
        uname(&u)
        var model = withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { model = sim + " (simulator)" }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let system = "iPadOS"
        #else
        let system = "macOS"
        #endif
        return ["model": model, "system": "\(system) \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                "memoryMB": Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
                "cores": ProcessInfo.processInfo.activeProcessorCount]
    }()
    static let app: [String: Any] = {
        let info = Bundle.main.infoDictionary ?? [:]
        return ["version": info["CFBundleShortVersionString"] as? String ?? "?", "build": info["CFBundleVersion"] as? String ?? "?"]
    }()

    /// What this app may still use (iOS: os_proc_available_memory), MB; nil where the system does not say (a Mac).
    static func availableMB() -> Double? {
        #if os(iOS)
        let b = os_proc_available_memory()
        return b > 0 ? Double(b) / 1_048_576 : nil
        #else
        return nil
        #endif
    }
    /// The app's footprint now and its peak resident size since it started (task_info), MB.
    static func residentMB() -> (footprint: Double, peak: Double)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.resident_size_peak) / 1_048_576)
    }
}

// MARK: the inputs of a part's generation

extension GenerationTimingLog.Inputs {
    /// A part's lattice as the page has it now: the part, the whole lattice settings, each group's Organic settings (Auto /
    /// Manual resolved), the print parameters, and the preview's switches.
    @MainActor
    public static func of(_ p: ProjectModel) -> Self {
        var i = Self()
        if let f = p.importedFile { i.part = .init(file: f.name, faces: f.faceCount, triangles: f.triangleCount) }
        i.lattice = p.lattice
        i.printParams = p.printParams
        let organic = LatticeLayoutPreview.organic(p.lattice)
        if organic {
            let groups: [(UUID?, String)] = p.lattice.wholePart || p.latticeAreaGroups.isEmpty
                ? [(nil, "Whole part")] : p.latticeAreaGroups.map { (Optional($0.id), $0.name) }
            for (g, name) in groups {
                var n = name, k = 2
                while i.organic[n] != nil { n = "\(name) (\(k))"; k += 1 }
                i.organic[n] = p.lattice.organicLook(group: g).effective(pageManual: p.latticePageManual)
            }
        }
        i.values["latticeType"] = .text(organic ? LatticeLayoutPreview.organicButtonType(p)
                                                : LatticeType.displayName(forID: p.lattice.topologyID))
        i.values["stageMode"] = .text((p.lattice.stageMode ?? .structural).rawValue)
        i.values["pageManual"] = .flag(p.latticePageManual)
        i.values["printAccuratePreview"] = .flag(AppSettings.shared.latticePrintAccurate)
        i.values["livePreview"] = .flag(AppSettings.shared.latticeLivePreview)
        return i
    }
}
