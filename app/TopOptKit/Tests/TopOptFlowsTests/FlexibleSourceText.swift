// FlexibleSourceText — source-scanning helper for the Flexible track's call-site pins (task
// 2026-09-29-flexible-screens; memory: "value-type tests miss call sites").
import Foundation

/// Source text with `//` comments stripped (an assertion is about what the code can reach).
enum FlexibleSource {
    static func url(_ name: String, module: String = "TopOptFlows") -> URL {
        var u = URL(fileURLWithPath: #filePath)
        u.deleteLastPathComponent(); u.deleteLastPathComponent(); u.deleteLastPathComponent()
        return u.appendingPathComponent("Sources/\(module)/\(name)")
    }
    static func text(_ name: String, module: String = "TopOptFlows") throws -> String {
        try String(contentsOf: url(name, module: module), encoding: .utf8)
    }
    static func code(_ name: String, module: String = "TopOptFlows") throws -> String {
        try text(name, module: module).split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            return String(line[line.startIndex..<r.lowerBound])
        }.joined(separator: "\n")
    }
}
