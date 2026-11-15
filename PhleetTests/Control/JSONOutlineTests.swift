import XCTest
@testable import Phleet

/// Reading a complete value as JSON: strictly, without changing a character of it.
final class JSONOutlineTests: XCTestCase {

    private func outline(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> JSONOutline? {
        guard case .outline(let outline) = JSONReading.read(text) else {
            XCTFail("valid JSON was not read: \(text.prefix(80))", file: file, line: line)
            return nil
        }
        return outline
    }

    /// Everything outside string literals with the whitespace removed: what pretty printing may
    /// change, taken away, must leave the original.
    private func tokens(_ text: String) -> String {
        var out = ""
        var inString = false
        var escaped = false
        for character in text {
            if inString {
                out.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
                out.append(character)
            } else if !" \n\t\r".contains(character) {
                out.append(character)
            }
        }
        return out
    }

    func testObjectsKeepTheirOrderDuplicatesAndExactNumbers() throws {
        let text = #"{"z":1.10,"a":12345678901234567890,"z":-0,"e":1E+400,"list":[true,false,null]}"#
        let root = try XCTUnwrap(outline(text)?.root)
        XCTAssertEqual(root.kind, .object)
        XCTAssertEqual(root.children.map(\.key), ["z", "a", "z", "e", "list"])
        XCTAssertEqual(
            root.children.prefix(4).map(\.value),
            ["1.10", "12345678901234567890", "-0", "1E+400"],
            "a number is shown as written, never through a Double"
        )
        let list = root.children[4]
        XCTAssertEqual(list.kind, .array)
        XCTAssertEqual(list.children.map(\.index), [0, 1, 2])
        XCTAssertEqual(list.children.map(\.value), ["true", "false", "null"])
        XCTAssertEqual(list.children.map(\.kind), [.literal, .literal, .literal])
    }

    func testAStringReadsAsItsTextAndKeepsItsLiteral() throws {
        let text = #"{"note":"line one\nline two 🧭 é é \"q\" \\ \/","kéy":""}"#
        let root = try XCTUnwrap(outline(text)?.root)
        let note = root.children[0]
        XCTAssertEqual(note.kind, .string)
        XCTAssertTrue(
            SyntheticText.scalarsEqual(note.value, "line one\nline two \u{1F9ED} \u{E9} e\u{301} \"q\" \\ /")
        )
        XCTAssertEqual(
            note.literal,
            #""line one\nline two 🧭 é é \"q\" \\ \/""#,
            "the literal is the source text, escapes and all"
        )
        XCTAssertEqual(root.children[1].key, "k\u{E9}y")
        XCTAssertEqual(root.children[1].value, "")
    }

    func testALoneSurrogateReadsAsAReplacementAndStaysInTheLiteral() throws {
        let root = try XCTUnwrap(outline(#""\ud800 and \udc00x""#)?.root)
        XCTAssertEqual(root.value, "\u{FFFD} and \u{FFFD}x")
        XCTAssertEqual(root.literal, #""\ud800 and \udc00x""#)
    }

    func testPrettyTextDiffersFromTheOriginalOnlyInWhitespace() throws {
        let original = #"{"a":[1,{"b":"x y\n  z","c":[]}, {}],"d":"é","e":{"f":null}}"#
        let pretty = try XCTUnwrap(outline(original)?.pretty)
        XCTAssertEqual(
            pretty,
            """
            {
              "a": [
                1,
                {
                  "b": "x y\\n  z",
                  "c": []
                },
                {}
              ],
              "d": "é",
              "e": {
                "f": null
              }
            }
            """
        )
        XCTAssertEqual(tokens(pretty), tokens(original))
    }

    func testTopLevelScalarsAreJSON() {
        for text in [#""a JSON string""#, "42", "-1.5e-3", "true", "null", "  \n\"padded\" \t"] {
            XCTAssertNotNil(outline(text), text)
        }
    }

    func testMalformedOrTruncatedJSONIsNeverAPartialObject() {
        let malformed = [
            "", " ", #"{"a":"#, #"{"a":1"#, #"{"a":1,}"#, "[1,]", #"{"a":1}x"#, #"{"a" 1}"#,
            "{'a':1}", "NaN", "01", "1.", ".5", "-", "+1", "1e", "tru", "nul", #""unterminated"#,
            "\"raw\ncontrol\"", #""bad \x escape""#, #""\u12""#, "[1 2]", #"{"a":1}{"b":2}"#,
            #"{1:2}"#, "\u{FEFF}{}"
        ]
        for text in malformed {
            XCTAssertEqual(JSONReading.read(text), .invalid, "read as JSON: \(text.debugDescription)")
        }
    }

    func testNestingBeyondTheLimitIsNeitherValidNorInvalid() {
        let depth = JSONReading.maximumDepth
        let deepest = String(repeating: "[", count: depth + 1) + String(repeating: "]", count: depth + 1)
        XCTAssertNotNil(outline(deepest), "the deepest nesting followed is read")
        let deeper = String(repeating: "[", count: depth + 2) + String(repeating: "]", count: depth + 2)
        XCTAssertEqual(JSONReading.read(deeper), .tooDeep)
        // Even unclosed: too deep to follow is said before anything about validity.
        XCTAssertEqual(JSONReading.read(String(repeating: "[", count: 100_000)), .tooDeep)
    }

    func testADocumentWithTooManyEntriesKeepsItsPrettyTextButNoOutline() throws {
        let count = JSONReading.maximumNodes + 1
        let text = "[" + Array(repeating: "0", count: count).joined(separator: ",") + "]"
        let read = try XCTUnwrap(outline(text))
        XCTAssertNil(read.root)
        XCTAssertEqual(tokens(read.pretty), text)
    }

    func testALargeUnicodeStringIsReadWhole() throws {
        let original = SyntheticText.unicode(scalars: 100_000)
        let literal = SyntheticText.asciiJSONLiteral(original)
        let root = try XCTUnwrap(outline(literal)?.root)
        XCTAssertEqual(root.kind, .string)
        XCTAssertTrue(SyntheticText.scalarsEqual(root.value, original))
        XCTAssertEqual(root.literal, literal)
    }
}
