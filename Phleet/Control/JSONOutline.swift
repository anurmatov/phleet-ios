import Foundation

/// One value of a JSON document, for an outline.
///
/// Scalars keep their exact source text. A number is never converted — `1.10` stays `1.10` and
/// an integer too large for a `Double` keeps every digit — and an object keeps its members in
/// their stored order, duplicates included, which `JSONSerialization` would not.
struct JSONNode: Identifiable, Equatable, Sendable {

    enum Kind: Equatable, Sendable {
        case object
        case array
        case string
        case number
        /// `true`, `false` or `null`.
        case literal
    }

    /// Position in document order. Stable for one reading.
    let id: Int
    /// The member name, unescaped. `nil` for an array element and for the document itself.
    let key: String?
    /// The position in the array this element belongs to.
    let index: Int?
    let kind: Kind
    /// A scalar's source text exactly as stored: a string keeps its quotes and escapes. Empty for
    /// an object or array.
    let literal: String
    /// What a scalar reads as. A string's text with its escapes resolved, so a value full of
    /// `\n` reads as lines; for a number or literal, its source text.
    let value: String
    /// An object's members or an array's elements, in order.
    let children: [JSONNode]

    var isContainer: Bool {
        kind == .object || kind == .array
    }
}

/// A valid JSON document, laid out for reading.
struct JSONOutline: Equatable, Sendable {
    /// `nil` when the document has more entries than an outline is built for. It is still valid
    /// JSON and still has its pretty text.
    let root: JSONNode?
    /// The same document indented, with every scalar exactly as stored. Only whitespace between
    /// tokens differs from the original.
    let pretty: String
}

/// What reading a text as JSON found.
enum JSONReading: Equatable, Sendable {
    case outline(JSONOutline)
    /// Not valid JSON, or not all of one value: a truncated document is this, never a partial
    /// object.
    case invalid
    /// Nested more deeply than this reader follows. Neither called valid nor invalid.
    case tooDeep

    /// The most nesting followed. Deeper documents are left as text rather than risk the stack.
    static let maximumDepth = 200

    /// The most entries an outline is built for.
    static let maximumNodes = 100_000

    /// Reads strict RFC 8259 JSON: one value, optional whitespace around it, nothing else.
    static func read(_ text: String) -> JSONReading {
        var parser = JSONParser(bytes: Array(text.utf8))
        do {
            parser.skipWhitespace()
            let root = try parser.value(key: nil, index: nil, depth: 0, indent: 0)
            parser.skipWhitespace()
            guard parser.isAtEnd else { return .invalid }
            return .outline(
                JSONOutline(root: parser.nodeCount > maximumNodes ? nil : root, pretty: parser.pretty)
            )
        } catch JSONParser.Failure.tooDeep {
            return .tooDeep
        } catch {
            return .invalid
        }
    }
}

/// A recursive-descent reader over UTF-8 bytes that builds the outline and the pretty text in one
/// pass. Every token boundary it slices at is an ASCII byte, so every slice is whole UTF-8.
private struct JSONParser {

    enum Failure: Error {
        case invalid
        case tooDeep
    }

    let bytes: [UInt8]
    var position = 0
    var nodeCount = 0
    var pretty = ""

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { position == bytes.count }

    private var current: UInt8? { position < bytes.count ? bytes[position] : nil }

    mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            position += 1
        }
    }

    /// Only the first `maximumNodes` entries are kept; past that the outline is dropped anyway,
    /// so the rest are validated and printed without being held.
    private var keepsNodes: Bool { nodeCount <= JSONReading.maximumNodes }

    mutating func value(
        key: String?,
        index: Int?,
        depth: Int,
        indent: Int
    ) throws -> JSONNode {
        guard depth <= JSONReading.maximumDepth else { throw Failure.tooDeep }
        let id = nodeCount
        nodeCount += 1

        switch current {
        case UInt8(ascii: "{"):
            return try object(id: id, key: key, index: index, depth: depth, indent: indent)
        case UInt8(ascii: "["):
            return try array(id: id, key: key, index: index, depth: depth, indent: indent)
        case UInt8(ascii: "\""):
            let (literal, decoded) = try string()
            pretty += literal
            return node(id, key, index, .string, literal, decoded)
        case UInt8(ascii: "t"):
            return try word("true", id, key, index)
        case UInt8(ascii: "f"):
            return try word("false", id, key, index)
        case UInt8(ascii: "n"):
            return try word("null", id, key, index)
        case let byte? where byte == UInt8(ascii: "-") || (0x30...0x39).contains(byte):
            let literal = try number()
            pretty += literal
            return node(id, key, index, .number, literal, literal)
        default:
            throw Failure.invalid
        }
    }

    private func node(
        _ id: Int,
        _ key: String?,
        _ index: Int?,
        _ kind: JSONNode.Kind,
        _ literal: String,
        _ value: String,
        _ children: [JSONNode] = []
    ) -> JSONNode {
        JSONNode(id: id, key: key, index: index, kind: kind, literal: literal, value: value,
                 children: children)
    }

    private mutating func object(
        id: Int,
        key: String?,
        index: Int?,
        depth: Int,
        indent: Int
    ) throws -> JSONNode {
        position += 1
        skipWhitespace()
        var members: [JSONNode] = []
        if current == UInt8(ascii: "}") {
            position += 1
            pretty += "{}"
            return node(id, key, index, .object, "", "", members)
        }
        pretty += "{\n"
        while true {
            skipWhitespace()
            guard current == UInt8(ascii: "\"") else { throw Failure.invalid }
            let (nameLiteral, name) = try string()
            skipWhitespace()
            guard current == UInt8(ascii: ":") else { throw Failure.invalid }
            position += 1
            skipWhitespace()
            pretty += Self.spaces(indent + 1) + nameLiteral + ": "
            let member = try value(
                key: name,
                index: nil,
                depth: depth + 1,
                indent: indent + 1
            )
            if keepsNodes { members.append(member) }
            skipWhitespace()
            if current == UInt8(ascii: ",") {
                position += 1
                pretty += ",\n"
                continue
            }
            guard current == UInt8(ascii: "}") else { throw Failure.invalid }
            position += 1
            pretty += "\n" + Self.spaces(indent) + "}"
            return node(id, key, index, .object, "", "", members)
        }
    }

    private mutating func array(
        id: Int,
        key: String?,
        index: Int?,
        depth: Int,
        indent: Int
    ) throws -> JSONNode {
        position += 1
        skipWhitespace()
        var elements: [JSONNode] = []
        if current == UInt8(ascii: "]") {
            position += 1
            pretty += "[]"
            return node(id, key, index, .array, "", "", elements)
        }
        pretty += "[\n"
        var elementIndex = 0
        while true {
            skipWhitespace()
            pretty += Self.spaces(indent + 1)
            let element = try value(
                key: nil,
                index: elementIndex,
                depth: depth + 1,
                indent: indent + 1
            )
            if keepsNodes { elements.append(element) }
            elementIndex += 1
            skipWhitespace()
            if current == UInt8(ascii: ",") {
                position += 1
                pretty += ",\n"
                continue
            }
            guard current == UInt8(ascii: "]") else { throw Failure.invalid }
            position += 1
            pretty += "\n" + Self.spaces(indent) + "]"
            return node(id, key, index, .array, "", "", elements)
        }
    }

    private mutating func word(
        _ word: String,
        _ id: Int,
        _ key: String?,
        _ index: Int?
    ) throws -> JSONNode {
        let expected = Array(word.utf8)
        guard position + expected.count <= bytes.count,
              Array(bytes[position..<position + expected.count]) == expected
        else { throw Failure.invalid }
        position += expected.count
        pretty += word
        return node(id, key, index, .literal, word, word)
    }

    /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`, returned as written.
    private mutating func number() throws -> String {
        let start = position
        if current == UInt8(ascii: "-") { position += 1 }
        if current == UInt8(ascii: "0") {
            position += 1
        } else {
            guard digits() > 0 else { throw Failure.invalid }
        }
        if current == UInt8(ascii: ".") {
            position += 1
            guard digits() > 0 else { throw Failure.invalid }
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            position += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { position += 1 }
            guard digits() > 0 else { throw Failure.invalid }
        }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    private mutating func digits() -> Int {
        let start = position
        while let byte = current, (0x30...0x39).contains(byte) { position += 1 }
        return position - start
    }

    /// A string token: its exact source text, quotes included, and the text it stands for.
    ///
    /// An escaped lone surrogate is valid JSON and cannot be a Swift character; it reads as
    /// U+FFFD. The literal, and so the raw and pretty text, keep it as written.
    private mutating func string() throws -> (literal: String, decoded: String) {
        let start = position
        position += 1
        var decoded: [UInt8] = []
        while true {
            guard let byte = current else { throw Failure.invalid }
            switch byte {
            case UInt8(ascii: "\""):
                position += 1
                return (
                    String(decoding: bytes[start..<position], as: UTF8.self),
                    String(decoding: decoded, as: UTF8.self)
                )
            case UInt8(ascii: "\\"):
                position += 1
                try escape(into: &decoded)
            case 0x00..<0x20:
                // A raw control character must be escaped inside a JSON string.
                throw Failure.invalid
            default:
                decoded.append(byte)
                position += 1
            }
        }
    }

    private mutating func escape(into decoded: inout [UInt8]) throws {
        guard let byte = current else { throw Failure.invalid }
        position += 1
        switch byte {
        case UInt8(ascii: "\""): decoded.append(0x22)
        case UInt8(ascii: "\\"): decoded.append(0x5C)
        case UInt8(ascii: "/"): decoded.append(0x2F)
        case UInt8(ascii: "b"): decoded.append(0x08)
        case UInt8(ascii: "f"): decoded.append(0x0C)
        case UInt8(ascii: "n"): decoded.append(0x0A)
        case UInt8(ascii: "r"): decoded.append(0x0D)
        case UInt8(ascii: "t"): decoded.append(0x09)
        case UInt8(ascii: "u"):
            let unit = try hexUnit()
            var scalar = Unicode.Scalar(unit)
            if (0xD800...0xDBFF).contains(unit),
               position + 1 < bytes.count,
               bytes[position] == UInt8(ascii: "\\"),
               bytes[position + 1] == UInt8(ascii: "u") {
                let resume = position
                position += 2
                let low = try hexUnit()
                if (0xDC00...0xDFFF).contains(low) {
                    let combined = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                    scalar = Unicode.Scalar(combined)
                } else {
                    // Not a pair: the second escape is read again on its own.
                    position = resume
                }
            }
            let replacement: Unicode.Scalar = "\u{FFFD}"
            decoded.append(contentsOf: Array(String(Character(scalar ?? replacement)).utf8))
        default:
            throw Failure.invalid
        }
    }

    private mutating func hexUnit() throws -> UInt16 {
        guard position + 4 <= bytes.count else { throw Failure.invalid }
        var unit: UInt16 = 0
        for byte in bytes[position..<position + 4] {
            let digit: UInt8
            switch byte {
            case 0x30...0x39: digit = byte - 0x30
            case 0x41...0x46: digit = byte - 0x41 + 10
            case 0x61...0x66: digit = byte - 0x61 + 10
            default: throw Failure.invalid
            }
            unit = unit << 4 | UInt16(digit)
        }
        position += 4
        return unit
    }

    private static func spaces(_ level: Int) -> String {
        String(repeating: "  ", count: level)
    }
}
