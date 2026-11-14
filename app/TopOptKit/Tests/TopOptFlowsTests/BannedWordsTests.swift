// BannedWordsTests — B2, U4 (approved design 2026-11-02, design-system §3 and §6: "no screen string in a banned list").
//
// One word per thing. Every string literal the app can put on the screen (TopOptFlows' sources, minus logs, diagnostics,
// identifiers and comments) is checked against the words the vocabulary table rules out. (The offscreen window's
// accessibility tree carries only a few menu values, so the strings are read where they are written.)
// ★ B10: the whole §3 "Never" column on the kept pages and (#362) the Flexible pages (testNoKeptPageSaysASection3NeverWord); the lattice
// pages' hits are listed, not fixed (the reviewer's scope ruling 2026-11-11 03:50Z).
#if canImport(AppKit)
import XCTest
@testable import TopOptFlows

final class BannedWordsTests: XCTestCase {

    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/TopOptFlows")

    /// A banned word, the word that replaces it, and the batch whose screens dropped it. Each batch adds the words its rebuilt
    /// screens drop; B10's sweep holds the whole §3 list.
    struct Banned { let pattern: String; let use: String; let batch: String }
    static let banned: [Banned] = [
        Banned(pattern: #"\b[Dd]esign primitives\b"#, use: "Allow growth here", batch: "B2"),
        Banned(pattern: #"\bVersion (\d|\\\()"#, use: "a · Just safe, b · +10 %, c · +20 %", batch: "B2"),
        Banned(pattern: #"^Wireframe$"#, use: "Outlines", batch: "B2"),   // the view's one name (§4.2)
    ]

    /// Lines that never reach the screen: logs, diagnostics, identifiers, assertions.
    static let offScreen = try! NSRegularExpression(pattern:
        #"NSLog|print\(|diag\(|DIAG|signpost|emitEvent|os_log|Logger|accessibilityIdentifier|fatalError|assert|precondition"#)
    static let literal = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)

    /// The line without its trailing comment (a `//` outside a string literal).
    static func code(_ line: String) -> String {
        var inString = false, escaped = false, prev: Character = " "
        for (i, c) in zip(line.indices, line) {
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "/", prev == "/" {
                return String(line[..<line.index(before: i)])
            }
            prev = c
        }
        return line
    }

    /// The banned words in `lines` ("file:line: the string · the word to use").
    static func scan(_ lines: [String], file: String) -> [String] {
        var out: [String] = []
        for (n, full) in lines.enumerated() {
            let line = code(full)
            let t = line.trimmingCharacters(in: .whitespaces)
            let whole = NSRange(line.startIndex..., in: line)
            guard !t.hasPrefix("//"), offScreen.firstMatch(in: line, range: whole) == nil else { continue }
            for m in literal.matches(in: line, range: whole) {
                guard let r = Range(m.range(at: 1), in: line) else { continue }
                let s = String(line[r])
                for b in banned where s.range(of: b.pattern, options: .regularExpression) != nil {
                    out.append("\(file):\(n + 1): \"\(s)\" · use \(b.use) (\(b.batch))")
                }
            }
        }
        return out
    }

    func testTheScannerCatchesABannedWord() {
        // ★ RED CONTROL: a planted screen string is caught; the same words in a log line are not
        XCTAssertEqual(Self.scan(["        Text(\"Version 2 · +10%\")"], file: "x").count, 1)
        XCTAssertEqual(Self.scan(["        viewModeButton(\"cube\", label: \"Design primitives\", on: x)"], file: "x").count, 1)
        XCTAssertEqual(Self.scan(["        NSLog(\"Version 2 done\")", "        // \"Design primitives\"",
                                  "        x(\"Outlines\")   // never \"Wireframe\""], file: "x"), [])
        XCTAssertEqual(Self.scan(["        Link(\"https://a.b\", label: \"Wireframe\")"], file: "x").count, 1, "a // inside a string is not a comment")
    }

    // MARK: ★ B10 — the whole §3 "Never" column (the reviewer's scope ruling 2026-11-11 03:50Z: fix the kept pages, list the
    // lattice pages). Matched on the string with each `\(…)` read as "#", so a variable's name ("\(rung)") is not a word on
    // the screen. "Forces" stays (the mockup's own view name); "Region" stays (the mockup's Cut tool); "Off" is listed with
    // the lattice pages (their rows' third word, B6).

    static let section3: [Banned] = [
        Banned(pattern: #"\b[Pp]rimitives?\b"#, use: "Allow growth here (Topology) · Lattice zones (Lattice) · Box │ Cylinder", batch: "B10"),
        Banned(pattern: #"\b[Dd]esign box\b"#, use: "Allow growth here", batch: "B10"),
        Banned(pattern: #"\b[Vv]ariants?\b|\b[Rr]ungs?\b"#, use: "result (a · Just safe, b · +10 %, c · +20 %) or version", batch: "B10"),
        Banned(pattern: #"\b[Ll]oad cases?\b"#, use: "load scenario", batch: "B10"),
        Banned(pattern: #"\bUnion of\b|\b[Rr]egion (\d|#)|^Regions$|\bFace (\d|#)"#, use: "plain face names (Faces from Cut)", batch: "B10"),
        Banned(pattern: #"\b[Ff]rozen\b|\b[Cc]learances?\b|\b[Ff]ixtures?\b"#, use: "Protect · Keep clear · Anchor", batch: "B10"),
        Banned(pattern: #"^(Solid|Include|Exclude)$"#, use: "Lattice · No lattice", batch: "B10"),
        Banned(pattern: #"\b[Ff]actor of safety\b"#, use: "Safety margin", batch: "B10"),
    ]

    /// The lattice pages' files: listed, never fixed here (the lattice pages wait for the rebuild). ★ B10 (#362): the Flexible
    /// pages are held to the rule — every Flexible row, chip, card and line names a face by its plain name.
    static let listedFilePrefixes = ["Lattice", "Organic", "Relattice", "FrozenRegionLattice", "FaceRegionSheet"]
    /// The lattice pages' strings inside the shared files (listed, never fixed here), by file: the string starts with one.
    static let listed: [String: [String]] = [
        "WorkspacePlaceholder.swift": ["this run has no variant here", "This variant can’t be latticed.", "Can’t lattice this variant",
                                       "Latticing a variant runs on a Mac worker", "Can’t re-lattice: the load case changed",
                                       "This job must certify under the load case", "Solid", "Regions"],
        "ResultsModel.swift": ["Region #: # cell", "This latticed variant", "the selected variant is not a latticed one"],
        "VariantEntry.swift": ["lattice certification does not support a design box", "The organic lattice can't be used with a design box",
                               "design box added is kept solid", "counts solid. Use Default Grade"],
        // the stored region names ("Face 12", "Union of 3") and the lattice refs' names: read only by the lattice and Flexible
        // rows (latticeRegionName / latticeSelectableName / latticeRowName); and faceName's number while no mesh is loaded
        // (its plain name needs the mesh: FaceNames)
        "ProjectModel.swift": ["Region #", "Primitive", "Union of #", "Face #", "Clearance"],   // (+ the Lattice page's clearance group)
    ]
    /// A word the §3 row rules out for ONE thing, used here for another: by file, the whole string, with why.
    static let otherMeaning: [String: Set<String>] = [
        // the Load paths drawer's Body: X-ray │ Stress │ Solid (an opaque body) — §3's "Never: … Solid" is a lattice face role
        "LoadFlow.swift": ["Solid"],
    ]
    /// Never on the screen: a data key, a file name, an identifier. By file, the whole string.
    static let notScreen: [String: Set<String>] = [
        "ClearanceSidecar.swift": [".clearances.json"], "ProjectStore.swift": [".clearances.json"],
        "LibraryModel.swift": ["variants"], "RedesignToStrengthen.swift": ["variants"],
        "RemoteRunner.swift": ["variant", "variants", "rung", "rungs", "clearances"],
        "WorkspacePlaceholder.swift": ["topology-primitive-undo", "topology-primitive", "topology-primitive-field-#"],
        // ★ B10 (#362), the Flexible pages: a face's STORED name keeps its number as data, as the Cut stage stores its own
        // (FlexibleSectors.dataName; every row reads it through FlexibleRowCopy.plainFaces → the plain name); core's sentence
        // searched for its ids (never drawn: FlexibleRegions.renamed draws it); a pure function's default namer, read only by
        // its tests (the page passes displayName); the I2 read-through's Report, printed by the handoff, never drawn.
        "FlexibleSectors.swift": ["Face #"],
        "FlexiblePressAim.swift": ["face region #"],
        "FlexibleReadiness.swift": ["Face #"],
        "FlexibleSectorMigration.swift": [##"Surface region # \"#\" removed (an I2 cut, given back)"##, "kept on Surface: region # — #"],
    ]
    // (A Keep clear group's own shapes were asked of the reviewer and answered 11-11 08:04Z, (3)(a): "+ Add" opens
    // Box │ Cylinder, the labels name the kind, "shapes" for several — so "primitive" is held to the rule like every word.)

    /// `s` with each interpolation read as "#".
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: #"\\\((?:[^()]|\([^()]*\))*\)"#, with: "#", options: .regularExpression)
    }

    /// The §3 words in `lines` that are on a kept page's screen ("file:line: the string · the word to use").
    static func scanSection3(_ lines: [String], file: String) -> [String] {
        if listedFilePrefixes.contains(where: { file.hasPrefix($0) }) { return [] }
        var out: [String] = []
        for (n, full) in lines.enumerated() {
            let line = code(full)
            let t = line.trimmingCharacters(in: .whitespaces)
            let whole = NSRange(line.startIndex..., in: line)
            guard !t.hasPrefix("//"), offScreen.firstMatch(in: line, range: whole) == nil else { continue }
            for m in literal.matches(in: line, range: whole) {
                guard let r = Range(m.range(at: 1), in: line) else { continue }
                let s = plain(String(line[r]))
                if notScreen[file]?.contains(s) == true || otherMeaning[file]?.contains(s) == true { continue }
                if (listed[file] ?? []).contains(where: { s.hasPrefix($0) }) { continue }
                for b in section3 where s.range(of: b.pattern, options: .regularExpression) != nil {
                    out.append("\(file):\(n + 1): \"\(s)\" · use \(b.use)")
                    break
                }
            }
        }
        return out
    }

    func testTheSection3ScannerCatchesAKeptPagesWord() {
        // ★ RED CONTROL: a kept page's planted words are caught; a variable's name, a listed lattice file and a key are not
        XCTAssertEqual(Self.scanSection3(["        Text(\"Optimizing more variants…\")"], file: "ResultsScreen.swift").count, 1)
        XCTAssertEqual(Self.scanSection3(["        model.toast = \"Draw a design box first\""], file: "X.swift").count, 1)
        XCTAssertEqual(Self.scanSection3(["        Text(\"Union of \\(n)\")"], file: "X.swift").count, 1)
        XCTAssertEqual(Self.scanSection3(["        return \"\\(proj)-\\(mat)-\\(rung)\""], file: "X.swift"), [], "a variable's name")
        XCTAssertEqual(Self.scanSection3(["        Text(\"Regions\")"], file: "LatticePage.swift"), [], "a lattice page: listed")
        XCTAssertEqual(Self.scanSection3(["        let v = root[\"variants\"]"], file: "LibraryModel.swift"), [], "a data key")
    }

    /// ★ B10 (the reviewer's ruling 11-11 08:04Z (3)(a)): a Keep clear group's own shapes are named by their kind — "+ Add"
    /// opens Box │ Cylinder (Allow growth here's words), the labels name the kind ("Copy box", "box 2 centre"), "shapes"
    /// for several. RED before: "+ primitive", "Copy primitive", "primitive 2 centre".
    func testAKeepClearGroupsShapesAreABoxOrACylinder() throws {
        XCTAssertEqual(ManualPrimitive.Kind.face.title, "Box"); XCTAssertEqual(ManualPrimitive.Kind.bolt.title, "Cylinder")
        XCTAssertEqual(ManualPrimitive.Kind.face.word, "box"); XCTAssertEqual(ManualPrimitive.Kind.bolt.word, "cylinder")
        let ws = try String(contentsOf: Self.sources.appendingPathComponent("WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertTrue(ws.contains(#"Label("Add", systemImage: "plus")"#), "★ \"+ Add\", never \"+ primitive\"")
        let box = ws.range(of: "Button(ManualPrimitive.Kind.face.title)"), cyl = ws.range(of: "Button(ManualPrimitive.Kind.bolt.title)")
        XCTAssertNotNil(box, "★ + Add offers Box"); XCTAssertNotNil(cyl, "★ and Cylinder")
        if let box, let cyl { XCTAssertLessThan(box.lowerBound, cyl.lowerBound, "Box │ Cylinder, in that order") }
        XCTAssertTrue(ws.contains(#""Copy \(mp.kind.word)""#), "★ Copy names the kind")
        XCTAssertTrue(ws.contains(#""Select the \(mp.kind.word) to move it""#))
        XCTAssertTrue(ws.contains(#""Convert to a movable \(grab.word)""#), "★ the kind it becomes")
        XCTAssertTrue(ws.contains(#""Show this group's shapes and colour""#), "★ \"shapes\" for several")
        let pm = try String(contentsOf: Self.sources.appendingPathComponent("ProjectModel.swift"), encoding: .utf8)
        XCTAssertTrue(pm.contains(#"label: "\(other.kind.word) \(i) centre""#), "★ \"box 2 centre\", never \"primitive 2 centre\"")
    }

    func testNoKeptPageSaysASection3NeverWord() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var hits: [String] = []
        for f in files {
            hits += Self.scanSection3(try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n"), file: f.lastPathComponent)
        }
        XCTAssertTrue(hits.isEmpty, "★ U4 (§3): a kept page says a word the design rules out:\n" + hits.joined(separator: "\n"))
    }

    func testNoScreenStringUsesABannedWord() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThan(files.count, 100, "the app's sources are where they should be")
        var hits: [String] = []
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            hits += Self.scan(text.components(separatedBy: "\n"), file: f.lastPathComponent)
        }
        XCTAssertTrue(hits.isEmpty, "★ banned words on the screen:\n" + hits.joined(separator: "\n"))
    }
}
#endif
