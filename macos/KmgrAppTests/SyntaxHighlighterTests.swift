import AppKit
import Foundation
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Syntax highlighting")
struct SyntaxHighlighterTests {
    @Test("common Kubernetes YAML scalars receive lightweight token kinds")
    func commonTokens() {
        let yaml = #"""
            ---
            apiVersion: v1
            metadata:
              name: "api"
              enabled: true
              replicas: 3
              ratio: 1.5e2
              missing: null
              image: registry/app:v2
              literal: value#suffix # retained comment
              ports: [80, 443]
              - containerPort: 8080
            """# as NSString

        let tokens = YAMLSyntaxLexer.tokens(
            in: yaml,
            range: NSRange(location: 0, length: yaml.length)
        )

        #expect(texts(for: .key, in: tokens, source: yaml) == [
            "apiVersion", "metadata", "name", "enabled", "replicas", "ratio",
            "missing", "image", "literal", "ports", "containerPort",
        ])
        #expect(texts(for: .number, in: tokens, source: yaml) == [
            "3", "1.5e2", "80", "443", "8080",
        ])
        #expect(texts(for: .keyword, in: tokens, source: yaml) == ["true", "null"])
        #expect(texts(for: .comment, in: tokens, source: yaml) == ["# retained comment"])
        #expect(texts(for: .string, in: tokens, source: yaml).contains("v1"))
        #expect(texts(for: .string, in: tokens, source: yaml).contains("\"api\""))
        #expect(texts(for: .string, in: tokens, source: yaml).contains("registry/app:v2"))
        #expect(texts(for: .string, in: tokens, source: yaml).contains("value#suffix"))
    }

    @Test("JSON objects and arrays receive nested lightweight token kinds")
    func commonJSONTokens() {
        let json = #"""
            [
              {"name": "api", "replicas": 3, "enabled": true,
               "ratio": -1.5e+2, "escaped": "a\"b",
               "nested": [{"value": null}]},
              {"name": "worker"}
            ]
            """# as NSString

        let tokens = JSONSyntaxLexer.tokens(
            in: json,
            range: NSRange(location: 0, length: json.length)
        )

        #expect(texts(for: .key, in: tokens, source: json) == [
            "\"name\"", "\"replicas\"", "\"enabled\"", "\"ratio\"",
            "\"escaped\"", "\"nested\"", "\"value\"", "\"name\"",
        ])
        #expect(texts(for: .string, in: tokens, source: json) == [
            "\"api\"", "\"a\\\"b\"", "\"worker\"",
        ])
        #expect(texts(for: .number, in: tokens, source: json) == ["3", "-1.5e+2"])
        #expect(texts(for: .keyword, in: tokens, source: json) == ["true", "null"])
    }

    @Test("Data syntax mode uses YAML keys and JSON object or array boundaries")
    func dataSyntaxModes() {
        #expect(DataSyntaxHighlightingModeDetector.mode(
            forKey: "settings.YAML",
            isTextValue: true,
            source: "plain text" as NSString
        ) == .yaml)
        #expect(DataSyntaxHighlightingModeDetector.mode(
            forKey: "settings",
            isTextValue: true,
            source: "  {\"enabled\": true}  " as NSString
        ) == .json)
        #expect(DataSyntaxHighlightingModeDetector.mode(
            forKey: "settings",
            isTextValue: true,
            source: "\n[ {\"name\": \"api\"} ]\n" as NSString
        ) == .json)
        #expect(DataSyntaxHighlightingModeDetector.mode(
            forKey: "settings",
            isTextValue: true,
            source: "not structured" as NSString
        ) == .none)
        #expect(DataSyntaxHighlightingModeDetector.mode(
            forKey: "settings",
            isTextValue: true,
            source: "{\"enabled\": true" as NSString,
            retaining: .json
        ) == .json)
        #expect(DataSyntaxHighlightingModeDetector.mode(
            forKey: "settings",
            isTextValue: true,
            source: "ordinary replacement" as NSString,
            retaining: .json
        ) == .none)
        #expect(DataSyntaxHighlightingModeDetector.mode(
            forKey: "settings.yaml",
            isTextValue: false,
            source: "kind: Deployment" as NSString
        ) == .none)
    }

    @Test("JSON temporary colors are presentation-only and clear when disabled")
    func jsonTemporaryAttributes() throws {
        let json = "{\"name\": \"api\", \"replicas\": 3, \"enabled\": true}"
        let scrollView = NSTextView.scrollablePlainDocumentContentTextView()
        let textView = try #require(scrollView.documentView as? NSTextView)
        textView.string = json
        let highlighter = SyntaxHighlighter(
            textView: textView,
            scrollView: scrollView,
            mode: .json
        )

        _ = highlighter.highlight(
            characterRange: NSRange(location: 0, length: (json as NSString).length)
        )
        let keyLocation = (json as NSString).range(of: "\"name\"").location
        let stringLocation = (json as NSString).range(of: "\"api\"").location
        let numberLocation = (json as NSString).range(of: "3").location
        let keywordLocation = (json as NSString).range(of: "true").location

        #expect(textView.string == json)
        #expect(temporaryColor(in: textView, at: keyLocation) == .systemPurple)
        #expect(temporaryColor(in: textView, at: stringLocation) == .systemRed)
        #expect(temporaryColor(in: textView, at: numberLocation) == .systemBlue)
        #expect(temporaryColor(in: textView, at: keywordLocation) == .systemOrange)

        highlighter.setMode(.none)
        #expect(temporaryColor(in: textView, at: keyLocation) == nil)
    }

    @Test("large JSON values retain bounded per-refresh lexer work")
    func largeJSONDocumentBound() throws {
        let jsonString = "[" + String(
            repeating: "{\"value\":1},",
            count: 180_000
        ) + "{}]"
        let json = jsonString as NSString
        let scrollView = NSTextView.scrollablePlainDocumentContentTextView()
        let textView = try #require(scrollView.documentView as? NSTextView)
        textView.string = jsonString
        let highlighter = SyntaxHighlighter(
            textView: textView,
            scrollView: scrollView,
            mode: .json
        )
        let visibleRange = NSRange(location: json.length / 2, length: 256)

        let clock = ContinuousClock()
        let start = clock.now
        let highlightRange = highlighter.highlight(characterRange: visibleRange)
        let duration = start.duration(to: clock.now)

        #expect(json.length > 2 * 1_024 * 1_024)
        #expect(highlightRange.length <= SyntaxHighlighter.maximumHighlightLength)
        #expect(highlightRange.length < json.length / 100)
        let environment = ProcessInfo.processInfo.environment
        if environment["KMGR_PERF_DIAGNOSTICS"] == "1"
            || environment["KMGR_PERF_BUDGETS"] == "1"
        {
            print(
                "kmgr JSON diagnostic: scanned \(highlightRange.length) of "
                    + "\(json.length) UTF-16 code units in \(duration)"
            )
        }
        if environment["KMGR_PERF_BUDGETS"] == "1" {
            #expect(
                duration <= .milliseconds(16),
                "A bounded JSON lexer pass exceeded one 60 Hz display frame."
            )
        }
    }

    @Test("temporary colors do not enter YAML storage")
    func temporaryAttributes() throws {
        let scrollView = NSTextView.scrollablePlainDocumentContentTextView()
        let textView = try #require(scrollView.documentView as? NSTextView)
        let yaml = "kind: Deployment\nreplicas: 3\nready: true\n"
        textView.string = yaml
        let keyLocation = (yaml as NSString).range(of: "kind").location
        let storedColorBefore = textView.textStorage?.attribute(
            .foregroundColor,
            at: keyLocation,
            effectiveRange: nil
        ) as? NSColor
        let highlighter = SyntaxHighlighter(textView: textView, scrollView: scrollView)

        let highlighted = highlighter.highlight(
            characterRange: NSRange(location: 0, length: (yaml as NSString).length)
        )
        let valueLocation = (yaml as NSString).range(of: "Deployment").location
        let storedColorAfter = textView.textStorage?.attribute(
            .foregroundColor,
            at: keyLocation,
            effectiveRange: nil
        ) as? NSColor

        #expect(highlighted.length == (yaml as NSString).length)
        #expect(textView.string == yaml)
        #expect(storedColorBefore?.isEqual(storedColorAfter) == true)
        #expect(textView.layoutManager?.temporaryAttribute(
            .foregroundColor,
            atCharacterIndex: keyLocation,
            effectiveRange: nil
        ) != nil)
        #expect(textView.layoutManager?.temporaryAttribute(
            .foregroundColor,
            atCharacterIndex: valueLocation,
            effectiveRange: nil
        ) != nil)
    }

    @Test("two MiB documents retain bounded per-refresh lexer work")
    func largeDocumentBound() throws {
        let row = "field: value\n"
        let byteTarget = 2 * 1_024 * 1_024
        let yamlString = String(repeating: row, count: byteTarget / row.utf8.count + 1)
        let yaml = yamlString as NSString
        let visibleRange = NSRange(location: yaml.length / 2, length: yaml.length / 2)
        let scrollView = NSTextView.scrollablePlainDocumentContentTextView()
        let textView = try #require(scrollView.documentView as? NSTextView)
        textView.string = yamlString
        let highlighter = SyntaxHighlighter(textView: textView, scrollView: scrollView)
        let initialRange = highlighter.highlight(characterRange: visibleRange)
        textView.textStorage?.replaceCharacters(
            in: NSRange(location: initialRange.location + 7, length: 1),
            with: "V"
        )
        let clock = ContinuousClock()
        let start = clock.now
        let highlightRange = highlighter.highlight(characterRange: visibleRange)
        let duration = start.duration(to: clock.now)

        #expect(yaml.length >= byteTarget)
        #expect(highlightRange.length <= SyntaxHighlighter.maximumHighlightLength)
        #expect(highlightRange.length < yaml.length / 100)
        #expect(textView.layoutManager?.temporaryAttribute(
            .foregroundColor,
            atCharacterIndex: highlightRange.location,
            effectiveRange: nil
        ) != nil)

        let environment = ProcessInfo.processInfo.environment
        if environment["KMGR_PERF_DIAGNOSTICS"] == "1"
            || environment["KMGR_PERF_BUDGETS"] == "1"
        {
            print(
                "kmgr YAML diagnostic: scanned \(highlightRange.length) of "
                    + "\(yaml.length) UTF-16 code units in \(duration)"
            )
        }
        if environment["KMGR_PERF_BUDGETS"] == "1" {
            #expect(
                duration <= .milliseconds(16),
                "A bounded YAML lexer pass exceeded one 60 Hz display frame."
            )
        }
    }

    private func texts(
        for kind: SyntaxTokenKind,
        in tokens: [SyntaxToken],
        source: NSString
    ) -> [String] {
        tokens.filter { $0.kind == kind }.map { source.substring(with: $0.range) }
    }

    private func temporaryColor(in textView: NSTextView, at location: Int) -> NSColor? {
        textView.layoutManager?.temporaryAttribute(
            .foregroundColor,
            atCharacterIndex: location,
            effectiveRange: nil
        ) as? NSColor
    }
}
}
