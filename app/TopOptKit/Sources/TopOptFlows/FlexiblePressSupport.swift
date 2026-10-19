// FlexiblePressSupport — whether an edge/corner press goes into core's job (task 2026-09-29-flexible-screens, round 7 batch R7-E2).
// The reviewer's ruling (2026-10-07, angled presses — binding): "Never write a job core refuses. Angled presses go into the job only
// once core's schema accepts them (probe-gated, as you already do)." — and (2026-10-10 19:10): "The app must NOT offer a send core
// will refuse (check with core before offering; say why in plain words)." A build_press_stack failure inside a RUN is a thrown
// JobError (core run.cpp), not a coded refusal, so every condition is checked BEFORE a press is written:
//   1. core's schema takes a loaded entry with face_region_ids + press_direction (a WHOLE-JOB probe through core's own parse_job,
//      with its control: the same entry with a single face_region_id must parse — memoised, injectable);
//   2. the bridge builds a press's stack (stack_of hands a synthetic id to build_press_stack — source-pinned by the tests);
//   3. core's press API is the one this app was written against (kPressApiVersion == 2);
//   4. core stacked THIS press on the open scene (FlexiblePressRegistration — a refusal is its own line);
//   5. no region would be in two entries (core's job_block: "a region is in one press");
//   6. no two LOADED entries share surface (core's A3 "shared_footprint" — said in plain words, with 1–3 fixes);
//   7. core designed it (its design on the press's stack is in, not refused);
//   8. no other press of its squeeze group pushes the same material along the same axis (core's one_profile_per_stack).
// A press that fails any of them stays OUT of the job and its card says why in one line (≤ 44); "Set up · core support pending"
// is said only while core's side (1–3) cannot take presses at all.

import Foundation
import TopOptKit

/// Two entries sharing surface (core's A3), in his words: "Edge 16 and Face 3 share 85 mm²".
public struct FlexibleSharedFootprint: Equatable, Sendable {
    /// The press kept out of the job.
    public let press: UUID
    public let pressName: String
    /// The other entry: a face (region), or another press.
    public let otherRegion: Int
    public let otherPress: UUID?
    public let otherName: String
    public let mm2: Double
    public init(press: UUID, pressName: String, otherRegion: Int, otherPress: UUID?, otherName: String, mm2: Double) {
        self.press = press; self.pressName = pressName; self.otherRegion = otherRegion; self.otherPress = otherPress
        self.otherName = otherName; self.mm2 = mm2
    }
    /// The one line.
    public var line: String { FlexibleRowCopy.sharedFootprint(pressName, otherName, mm2: mm2) }
}

/// A fix for a press kept out of the job (each one undo step).
public enum FlexiblePressFix: Hashable, Sendable {
    /// [Shallower]: the press's flat prism at this depth (it then shares no surface).
    case shallower(UUID, depthMM: Double)
    /// [Remove Edge 16]: the press goes (its strips back to their faces).
    case remove(UUID, label: String)
    /// [Face 3 rests]: the other entry rests (it presses nothing, so it shares nothing).
    case rest(Int, name: String)

    public var title: String {
        switch self {
        case .shallower: return "Shallower"
        case .remove(_, let label): return FlexibleRowCopy.fit("Remove \(label)", 24)
        case .rest(_, let name): return FlexibleRowCopy.fit("\(name) rests", 24)
        }
    }
    public var id: String {
        switch self {
        case .shallower(let p, _): return "shallower-\(p.uuidString)"
        case .remove(let p, _): return "remove-\(p.uuidString)"
        case .rest(let r, _): return "rest-\(r)"
        }
    }
}

public enum FlexiblePressSupport {

    /// The press API this app was written against (core's kPressApiVersion at #361 099dcaed).
    public static let expectedAPI = 2

    /// Why a press is not in the job (nil: it is).
    public enum Reason: Equatable, Sendable {
        /// Core's side cannot take presses (its schema, the bridge or its press API): "Set up · core support pending".
        case coreSupport
        /// ★ R7-E2 PARKED: the app does not send presses until the back-end phase (FlexibleBackend.sendsPresses off).
        case backendLater
        /// Core would not stack it on the open scene (its refusal, in plain words).
        case notStacked(String)
        /// A region would be in two entries.
        case twoEntries(String)
        /// Two loaded entries share surface.
        case shared(FlexibleSharedFootprint)
        /// Core is designing it (or has not been asked yet: its stack is being read).
        case designing
        /// Core would not design it (its words, plain).
        case designRefused(String)
        /// Another press of its group pushes the same material along the same axis.
        case conflict(String)
    }

    public struct Verdict: Equatable, Sendable {
        public let inJob: Bool
        public let reason: Reason?
        /// The card's one line (≤ 44) when it is not in the job.
        public var line: String? {
            guard let r = reason else { return nil }
            switch r {
            case .coreSupport: return FlexibleRowCopy.pressNotSent
            case .backendLater: return FlexibleRowCopy.pressShapeOnly
            case .notStacked(let s), .twoEntries(let s), .designRefused(let s), .conflict(let s): return s
            case .shared(let f): return f.line
            case .designing: return FlexibleRowCopy.pressDesigning
            }
        }
        public static let sent = Verdict(inJob: true, reason: nil)
    }

    /// What one press's verdict is read from.
    public struct Facts: Equatable, Sendable {
        public var schema: Bool
        public var bridge: Bool
        public var api: Int
        /// Core stacked it on the open scene (nil); else core's plain refusal ("" while not asked yet).
        public var stacked: String?
        public var twoEntries: String?
        public var shared: FlexibleSharedFootprint?
        /// Core's design: designed (true), refused (its words), or still pending (nil, no words).
        public var designed: Bool
        public var designRefusal: String?
        public var conflict: String?
        /// ★ R7-E2 PARKED: the app sends presses (FlexibleBackend.sendsPresses).
        public var backend: Bool
        public init(schema: Bool, bridge: Bool, api: Int, stacked: String?, twoEntries: String?, shared: FlexibleSharedFootprint?,
                    designed: Bool, designRefusal: String?, conflict: String?, backend: Bool = true) {
            self.schema = schema; self.bridge = bridge; self.api = api; self.stacked = stacked; self.twoEntries = twoEntries
            self.shared = shared; self.designed = designed; self.designRefusal = designRefusal; self.conflict = conflict
            self.backend = backend
        }
    }

    /// ★ THE GATE, as one pure function of the facts (every condition false keeps the press out, with its line).
    public static func verdict(_ f: Facts) -> Verdict {
        func out(_ r: Reason) -> Verdict { Verdict(inJob: false, reason: r) }
        guard f.backend else { return out(.backendLater) }   // ★ R7-E2 PARKED: the shape only until the back-end phase
        guard f.schema, f.bridge, f.api == expectedAPI else { return out(.coreSupport) }
        if let s = f.stacked { return out(s.isEmpty ? .designing : .notStacked(s)) }   // "" — its stack is being read
        if let t = f.twoEntries { return out(.twoEntries(t)) }
        if let sh = f.shared { return out(.shared(sh)) }
        if let r = f.designRefusal { return out(.designRefused(r)) }
        guard f.designed else { return out(.designing) }
        if let c = f.conflict { return out(.conflict(c)) }
        return .sent
    }

    // MARK: - core's side (1–3), read once

    /// ★ 2: the bridge's stack_of hands a synthetic id (≤ −1000) to core's build_press_stack — pinned by the tests' source check.
    nonisolated(unsafe) static var bridgeBuildsPress = true
    /// ★ 3: core's press API version (a test stands a 1 in for it: the RED CONTROL closes the gate).
    nonisolated(unsafe) static var apiVersion: () -> Int = { FlexibleScene.pressApiVersion }
    /// ★ 1: the schema probe (memoised; a test may stand in for it).
    nonisolated(unsafe) static var schemaProbe: () -> Bool = { probeSchema() }
    nonisolated(unsafe) private static var schemaMemo: Bool?

    /// Core's schema takes a face_region_ids + press_direction entry (asked once per process).
    public static func schemaTakesPresses() -> Bool {
        if let m = schemaMemo { return m }
        let v = schemaProbe()
        schemaMemo = v
        return v
    }
    /// ★ THE PROBE: a whole job through core's own parse_job (TopOptKit.jobSchemaError) — 2 declared faces, one loaded entry. Its
    /// CONTROL, the same entry naming one face_region_id (today's face entry), must parse, or the probe says nothing (false); then
    /// the entry with face_region_ids [0, 1] + press_direction must parse too.
    static func probeSchema() -> Bool {
        let i = FlexibleJob.Inputs(modelPath: "part.stl", resolution: 48, beadWidthMM: 0.42, faceCount: 2,
                                   settings: FlexibleStageSettings(materialID: "varioshore_tpu"))
        func parses(_ entry: [String: Any]) -> Bool {
            var block = FlexibleJob.header(i, material: "varioshore_tpu")
            block["faces"] = [entry]
            guard let doc = try? FlexibleJob.document(i, material: "varioshore_tpu", block: block) else { return false }
            return TopOptKit.jobSchemaError(Data(doc.utf8)) == nil
        }
        guard let control = try? FlexibleJob.faceEntry(FlexibleFaceSettings(faceRegionID: 0), finish: .covered, stamps: [:]),
              parses(control) else { return false }
        var press = control
        press["face_region_id"] = nil
        press["face_region_ids"] = [0, 1]
        press["press_direction"] = [0.0, 0.0, -1.0]
        return parses(press)
    }

    /// Tests only: forget the memo (a stand-in probe is asked again).
    static func resetSchemaMemo() { schemaMemo = nil }

    /// Core's side (1–3) takes presses.
    public static var coreTakesPresses: Bool {
        schemaTakesPresses() && bridgeBuildsPress && apiVersion() == expectedAPI
    }
}
