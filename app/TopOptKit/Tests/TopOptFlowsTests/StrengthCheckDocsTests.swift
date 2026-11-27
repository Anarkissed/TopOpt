// StrengthCheckDocsTests — ★ HIS ASK OF 11-17 (Install 3): the strength check, all of it, Simple and Full maths, from Settings on
// the home screen, with the values we chose open to change.
//   * the app shows the repo's own files: the bundled simple.md, maths.md and variables.json are byte-equal to
//     docs/strength-check (RED CONTROL: two different files differ);
//   * every value is listed with a control kind, every editable number has a range, every value's section is a heading in
//     both texts, every {{key}} in the texts is a value (RED CONTROL: an unknown key is left as written);
//   * the values he changes: out of range refused in one line; the default clears the change; the layer factor per material;
//     kept across launches; a bad stored value dropped; the strength job carries only the changed ones as `strength_settings`
//     (RED CONTROL: nothing changed, the job's bytes unchanged);
//   * the page draws both texts offline: every equation drawn by KaTeX, none it could not draw, every section reachable by
//     its heading (the "How it's worked out" tap);
//   * Settings on the home screen has the row, 44 pt, inside the window.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import WebKit
@testable import TopOptFlows

@MainActor
final class StrengthCheckDocsTests: XCTestCase {

    func testTheBundledFilesAreTheReposOwn() throws {
        let repo = FlexibleHisProject.repoRoot.appendingPathComponent("docs/strength-check")
        for name in ["simple.md", "maths.md", "variables.json"] {
            let bundled = try XCTUnwrap(StrengthCheckDocs.file(name), "\(name) is bundled")
            XCTAssertEqual(bundled, try Data(contentsOf: repo.appendingPathComponent(name)),
                           "★ \(name): the app shows the repo's own file (copy docs/strength-check into StrengthCheckWeb)")
        }
        XCTAssertNotEqual(StrengthCheckDocs.file("simple.md"), StrengthCheckDocs.file("maths.md"), "RED CONTROL: two files differ")
        for lib in ["page.html", "katex.min.js", "katex.min.css", "marked.min.js", "LICENSE-katex", "LICENSE-marked.md",
                    "fonts/KaTeX_Main-Regular.woff2"] {
            XCTAssertNotNil(StrengthCheckDocs.file(lib), "★ offline: \(lib) is bundled")
        }
    }

    func testEveryValueAndSectionIsThere() throws {
        let vs = StrengthCheckDocs.variables
        // cut 2 (the engine's 11-20 docs): Organic's frame of beams, its strengthening and the solid's weak areas join
        XCTAssertEqual(vs.count, 92, "every value the check uses")
        XCTAssertEqual(Set(vs.map(\.key)).count, vs.count, "one row per key")
        let editable = vs.filter(\.editable)
        XCTAssertEqual(editable.count, 53, "the values we chose with nothing behind them")
        XCTAssertTrue(editable.allSatisfy { $0.source == .chosen }, "only chosen values are editable")
        for v in editable {
            switch v.kind {
            case .number: XCTAssertTrue(v.min != nil && v.max != nil, "\(v.key): a range")
            case .choice: XCTAssertGreaterThan(v.choices.count, 1, "\(v.key): choices")
            case .bool: if case .bool = v.defaultValue {} else { XCTFail("\(v.key): a switch's default") }
            }
            XCTAssertNil(StrengthSettings.refusal(v.defaultValue, for: v), "\(v.key): its default is allowed")
        }
        for version in StrengthCheckDocs.Version.allCases {
            let text = StrengthCheckDocs.text(version)
            let heads = Set(text.split(separator: "\n").filter { $0.hasPrefix("## ") }.map { $0.dropFirst(3).trimmingCharacters(in: .whitespaces) })
            for s in Set(vs.map(\.section)) { XCTAssertTrue(heads.contains(s), "★ \(version): a heading for \(s)") }
            let filled = StrengthCheckDocs.filled(text, settings: StrengthSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!))
            XCTAssertFalse(filled.contains("{{"), "★ \(version): every {{key}} is a value")
        }
        XCTAssertEqual(StrengthCheckDocs.filled("a {{no_such_key}} b"), "a {{no_such_key}} b", "RED CONTROL: an unknown key stays")
        // the unit once: written by the text after the value, else added
        let st = StrengthSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertEqual(StrengthCheckDocs.filled("{{part_box_tol_mm}} mm", settings: st), "[0.1](topopt-value:part_box_tol_mm) mm")
        XCTAssertEqual(StrengthCheckDocs.filled("now {{part_box_tol_mm}}.", settings: st), "now [0.1 mm](topopt-value:part_box_tol_mm).")
        XCTAssertEqual(StrengthCheckDocs.filled("{{z_knockdown}}", settings: st), "[0.55 share of full strength (PLA)](topopt-value:z_knockdown)",
                       "a value per material: the shown material's")
        XCTAssertFalse(StrengthCheckDocs.filled(StrengthCheckDocs.text(.maths), settings: st).contains("0.2104999"),
                       "★ no table as raw computer text")
        XCTAssertEqual(StrengthCheckDocs.table("{\"bcc\": [0.21049999999999999, 0.59287999999999996]}"), "bcc 0.2105 to 0.5929")
        XCTAssertEqual(StrengthCheckDocs.sections.count, Set(vs.map(\.section)).count)
        XCTAssertEqual(StrengthCheckDocs.number(1e-9), "10⁻⁹")
        XCTAssertEqual(StrengthCheckDocs.number(2e-5), "2 × 10⁻⁵")
        XCTAssertEqual(StrengthCheckDocs.number(0.55), "0.55")
        XCTAssertEqual(StrengthCheckDocs.number(200000), "200000")
    }

    func testTheValuesHeChangesRideTheStrengthJob() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let s = StrengthSettings(defaults: defaults)
        let job = try JSONSerialization.data(withJSONObject: ["mode": "lattice_part", "model": "p.step"], options: [.sortedKeys])
        XCTAssertEqual(s.addTo(strengthJob: job), job, "RED CONTROL: nothing changed, the same bytes")
        XCTAssertNil(s.jobBlock)

        let infill = try XCTUnwrap(StrengthCheckDocs.variable("infill_exponent"))
        XCTAssertEqual(s.set(.number(9), for: infill), "At most 3", "★ out of range: one line, nothing kept")
        XCTAssertNil(s.changed["infill_exponent"])
        XCTAssertNil(s.set(.number(2), for: infill))
        XCTAssertEqual(s.current(infill), .number(2))
        let conn = try XCTUnwrap(StrengthCheckDocs.variable("load_path_connectivity"))
        XCTAssertNotNil(s.set(.number(7), for: conn), "not one of the choices")
        XCTAssertNil(s.set(.number(18), for: conn))
        // cut 2 made the walls count at full strength by default (width_aware_knockdown 0 -> 1): turning it OFF is the change
        let walls = try XCTUnwrap(StrengthCheckDocs.variable("width_aware_knockdown"))
        XCTAssertEqual(walls.defaultValue, .bool(true), "★ the engine's cut 2 default: on")
        XCTAssertNil(s.set(.bool(false), for: walls))
        let z = try XCTUnwrap(StrengthCheckDocs.variable("z_knockdown"))
        XCTAssertNil(s.set(material: "PLA", 0.6, for: z))
        XCTAssertEqual(s.set(material: "PETG", 1.4, for: z), "At most 1")
        let fixed = try XCTUnwrap(StrengthCheckDocs.variable("safety_margin"))
        XCTAssertNotNil(s.set(.number(2), for: fixed), "a value not ours to change is refused")

        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: s.addTo(strengthJob: job)) as? [String: Any])
        let block = try XCTUnwrap(sent["strength_settings"] as? [String: Any], "★ the job carries the changed values")
        XCTAssertEqual(Set(block.keys), ["infill_exponent", "load_path_connectivity", "width_aware_knockdown", "z_knockdown"])
        XCTAssertEqual(block["infill_exponent"] as? Double, 2)
        XCTAssertEqual(block["width_aware_knockdown"] as? Bool, false)
        let zs = try XCTUnwrap(block["z_knockdown"] as? [String: Double])
        XCTAssertEqual(zs["PLA"], 0.6)
        XCTAssertEqual(zs["PETG"], 0.7, "the other materials keep their default in the one object")
        XCTAssertEqual(zs.count, 12)
        XCTAssertEqual(sent["mode"] as? String, "lattice_part", "the rest of the job as it was")

        let again = StrengthSettings(defaults: defaults)
        XCTAssertEqual(again.changed, s.changed, "★ kept across launches")
        XCTAssertNil(s.set(.number(1.5), for: infill), "the default")
        XCTAssertNil(s.changed["infill_exponent"], "★ the default clears the change")
        s.resetAll()
        XCTAssertNil(s.jobBlock)

        defaults.set(try JSONSerialization.data(withJSONObject: ["infill_exponent": 99, "nope": 1, "safety_margin": 3]),
                     forKey: StrengthSettings.defaultsKey)
        XCTAssertTrue(StrengthSettings(defaults: defaults).changed.isEmpty, "a bad or foreign stored value is dropped")
    }

    /// The page draws a text: KaTeX's count of equations and of the ones it could not draw.
    private func draw(_ md: String, section: String? = nil) throws -> (equations: Int, errors: Int, web: WKWebView) {
        let c = StrengthWebCoordinator()
        c.markdown = md
        c.section = section
        var got: (Int, Int)?
        c.rendered = { got = ($0, $1) }
        let web = StrengthWebCoordinator.make(c)
        web.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let w = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = web
        let end = Date().addingTimeInterval(30)
        while got == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        let r = try XCTUnwrap(got, "the page rendered")
        return (r.0, r.1, web)
    }

    func testThePageDrawsBothTextsOfflineEveryEquationAndEverySection() throws {
        let s = StrengthSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let maths = try draw(StrengthCheckDocs.filled(StrengthCheckDocs.text(.maths), settings: s))
        print("STRENGTH-PAGE maths: \(maths.equations) equations, \(maths.errors) not drawn")
        XCTAssertGreaterThan(maths.equations, 50, "★ the full maths is drawn as maths")
        XCTAssertEqual(maths.errors, 0, "★ every equation KaTeX can draw")
        let simple = try draw(StrengthCheckDocs.filled(StrengthCheckDocs.text(.simple), settings: s))
        XCTAssertEqual(simple.errors, 0)
        // every section a row's "How it's worked out" opens, found by its heading
        for sec in StrengthCheckDocs.sections {
            var found: Bool?
            let js = "go(\(String(data: try JSONEncoder().encode(sec), encoding: .utf8)!))"
            maths.web.evaluateJavaScript(js) { r, _ in found = r as? Bool }
            let end = Date().addingTimeInterval(5)
            while found == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertEqual(found, true, "★ \(sec) is reachable")
        }
        var missing: Bool?
        maths.web.evaluateJavaScript("go(\"No such section\")") { r, _ in missing = r as? Bool }
        let end = Date().addingTimeInterval(5)
        while missing == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(missing, false, "RED CONTROL: a heading that is not there is not found")
        // RED CONTROL: a broken equation is counted
        let broken = try draw("$\\frac{1}{$ and $$\\notacommand{x}$$")
        XCTAssertGreaterThan(broken.errors, 0, "RED CONTROL: KaTeX's own error is seen")
    }

    /// OPT-IN (APP_BUILD_SHOT_DIR): the pictures to look at before he does — both texts as drawn (the web view's own snapshot,
    /// at an iPad's page width) and the Values list with one value changed.
    func testPicturesOfThePage() throws {
        guard let dir = ProcessInfo.processInfo.environment["APP_BUILD_SHOT_DIR"] else { throw XCTSkip("opt-in: APP_BUILD_SHOT_DIR") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let s = StrengthSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        for (v, name) in [(StrengthCheckDocs.Version.simple, "strength-simple.png"), (.maths, "strength-maths.png"),
                          (.maths, "strength-maths-solid-margin.png")] {
            let d = try draw(StrengthCheckDocs.filled(StrengthCheckDocs.text(v), settings: s),
                             section: name.hasSuffix("margin.png") ? "The solid's margin" : nil)
            d.web.frame = CGRect(x: 0, y: 0, width: 900, height: 1200)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            var image: NSImage?
            d.web.takeSnapshot(with: nil) { i, _ in image = i }
            let end = Date().addingTimeInterval(10)
            while image == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            let img = try XCTUnwrap(image)
            let rep = try XCTUnwrap(img.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        let infill = try XCTUnwrap(StrengthCheckDocs.variable("infill_exponent"))
        s.set(.number(2), for: infill)
        var focus: String? = nil
        let h = AppBuildHost(StrengthValuesList(settings: s, focus: Binding(get: { focus }, set: { focus = $0 }), howWorkedOut: { _ in })
                                .padding(30).background(Color(white: 0.11)),
                             size: AppBuildHost.landscape13, test: self)
        h.pump(1)
        try h.picture("strength-values.png")
    }

    func testSettingsOnTheHomeScreenHasTheRow() throws {
        let h = AppBuildHost(AppSettingsView(settings: AppSettings.shared, projection: ViewProjection.shared,
                                             compute: ComputeLocationModel(), storage: {}, done: {}),
                             size: AppBuildHost.landscape13, test: self)
        h.pump(1)
        let row = try h.onScreen("appSettingsStrength", "★ Settings' Strength check row")
        XCTAssertGreaterThanOrEqual(row.height, 44)
    }
}
#endif
