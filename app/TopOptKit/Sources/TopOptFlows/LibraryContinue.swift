// LibraryContinue.swift — ★ his iPad notes 2026-11-23 evening (img 1, img 2): Home's "Continue · 2040 Extrusion Stand v5
// draft" (from Nov 21) while he had worked on newer versions that very day, and the part page's "Open v5 draft" beside v8,
// v7 and v6 (Nov 23). His words: "It should recommend my most recent version that I was working on."
//
// The cause: Continue chose the newest DRAFT only (a version with results never counted), and the part page's button chose
// the draft with the HIGHEST NUMBER (v5 beat the newer v8 because v8 has results). Both now pick the version or draft he last
// opened or changed — its folder's saved time (`LibraryModel.lastChanged`), which every save stamps: leaving a version
// (`AppModel.persistCurrentProject`), an edit going to its draft, a run's result landing, a new draft or copy. On the same
// moment the higher number wins (`LibraryOrder.newestFirst`). Home picks across every part; the part page within its part.
// A version with results opens as the part page's own words say it: "Open v8" (a draft: "Open v5 draft").

import Foundation

enum LibraryContinue {
    /// The version or draft last opened or changed, across `parts`; nil with none.
    static func pick(_ parts: [LibraryPart], changed: (LibraryVersion) -> Date) -> (part: LibraryPart, v: LibraryVersion)? {
        var best: (part: LibraryPart, v: LibraryVersion, at: Date)?
        for p in parts {
            guard let v = pick(in: p, changed: changed) else { continue }
            let at = changed(v)
            if let b = best, b.at > at || (b.at == at && b.v.number > v.number) { continue }
            best = (p, v, at)
        }
        return best.map { (part: $0.part, v: $0.v) }
    }

    /// Within one part: the version or draft last opened or changed.
    static func pick(in part: LibraryPart, changed: (LibraryVersion) -> Date) -> LibraryVersion? {
        LibraryOrder.newestFirst(part.versions, changed: changed).first
    }

    /// Home's row: "Continue · 2040 Extrusion Stand v5 draft", or a version with results "Continue · 2040 Extrusion Stand v8".
    static func title(part: String, number: VersionNumber, draft: Bool) -> String {
        "Continue \u{00B7} \(part) v\(number)" + (draft ? " draft" : "")
    }

    /// The part page's button, in its own words: "Open v5 draft", "Open v8".
    static func openTitle(number: VersionNumber, draft: Bool) -> String {
        "Open v\(number)" + (draft ? " draft" : "")
    }
}
