import Foundation
import Testing
@testable import MilesCore

@Suite("MilesCore module")
struct ModuleTests {
    @Test func identity() {
        #expect(MilesCore.name == "MilesCore")
    }

    /// ADR 0013: the core package does not depend on SwiftUI or AppKit.
    @Test func importsNoUIFrameworks() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MilesCore")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let forbidden = try Regex(#"(?m)^\s*(@\w+\s+)*import\s+(SwiftUI|AppKit|Cocoa|UIKit)\b"#)
        var checked = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.firstMatch(of: forbidden) == nil, "\(url.lastPathComponent) imports a UI framework")
            checked += 1
        }
        #expect(checked > 0)
    }
}
