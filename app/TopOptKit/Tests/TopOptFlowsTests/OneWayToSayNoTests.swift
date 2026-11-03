// OneWayToSayNoTests — B2, U6 and U7 (approved design 2026-11-02, design-system §1 and §6: "U6: no .alert or card is
// presented from a run or engine error path; refusals render as a Line plus a Fix chip"; "U7: every confirm is a
// ConfirmInPlace inside its panel's bounds").
//
// A source scan of every `.alert(` and `.confirmationDialog(` in the app. Each one left today is listed with the batch whose
// screen replaces it (the way ViewCornerParityHostedTests marks Results' Outlines "B4"): a new one fails here, and so does a
// listed one that is still there after its batch is marked done in `doneBatches`.
#if canImport(AppKit)
import XCTest

final class OneWayToSayNoTests: XCTestCase {
    /// The batches already built (their listed alerts must be gone).
    static let doneBatches: Set<String> = ["B1", "B2"]

    /// file → each alert / dialog title still there, and the batch that replaces it.
    static let later: [String: [(String, String)]] = [
        "LatticeSetupWizard.swift": [("Grading needs a stress simulation", "B7"),   // U6: a refusal → a line + fix chip
                                     ("organicNotice?.title", "B7")],                // U6: the organic notices → lines
        "ResultsScreen.swift": [("Couldn’t save video", "B4"), ("Couldn’t export STL", "B4")],   // U6: error paths → a line
        "WorkspacePlaceholder.swift": [("Rename project", "B5"),                     // the name sheet (§4.11)
                                       ("RerunCard.title", "B3"),                    // U7: the Optimize as v7 sheet / confirm
                                       ("LatticeRerunChoice.title", "B6"),           // U7: the Lattice run's re-run ask
                                       ("Certification found", "B7"),                // the spacing choice → a row in the page
                                       ("Add a primitive", "B3")],                   // + Allow growth here's choice → a menu
        "LibraryViews.swift": [("Ungroup the Library?", "B5"), ("New project", "B5"), ("Rename project", "B5"),
                               ("Rename part", "B5"), ("deleting.map", "B5"), ("Name this version", "B5"), ("deleting.map", "B5")],
        "HomeView.swift": [("Rename project", "B5"), ("confirmationDialog(", "B5")],
    ]

    func testNoNewAlertOrDialog() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var found: [String: [String]] = [:]
        for f in files {
            let lines = try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n")
            for (i, l) in lines.enumerated() {
                let code = l.components(separatedBy: "// ").first ?? l
                guard code.contains(".alert(") || code.contains(".confirmationDialog(") else { continue }
                // the title is on this line or the next
                found[f.lastPathComponent, default: []].append(code + (i + 1 < lines.count ? " " + lines[i + 1] : ""))
            }
        }
        var unlisted: [String] = [], overdue: [String] = []
        for (file, hits) in found {
            var listed = Self.later[file] ?? []
            for h in hits {
                if let k = listed.firstIndex(where: { h.contains($0.0) }) {
                    if Self.doneBatches.contains(listed[k].1) { overdue.append("\(file): \(listed[k].0) (\(listed[k].1))") }
                    listed.remove(at: k)
                } else {
                    unlisted.append("\(file): \(h.trimmingCharacters(in: .whitespaces).prefix(90))")
                }
            }
        }
        XCTAssertEqual(unlisted, [], "★ U6 / U7 — a new alert or dialog: say no with a line + fix chip, confirm in place")
        XCTAssertEqual(overdue, [], "★ its batch is built: this one should be gone")
    }
}
#endif
