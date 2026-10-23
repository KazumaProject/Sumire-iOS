import Foundation

public enum AndroidTextMacroEditorBlock: Equatable {
    case text(String)
    case token(name: String, argument: String? = nil)

    public var source: String {
        switch self {
        case let .text(value):
            value.replacingOccurrences(of: "{", with: "{{")
                .replacingOccurrences(of: "}", with: "}}")
        case let .token(name, argument):
            "{\(name)\(argument.map { ":\($0)" } ?? "")}"
        }
    }
}

public enum AndroidTextMacroEditorDocumentError: Error, Equatable {
    case indexOutOfRange(Int)
}

/// Visual editor representation. Parsing and serialization use the same
/// compiler catalog so unknown or malformed tokens cannot be silently lost.
public struct AndroidTextMacroEditorDocument: Equatable {
    public let blocks: [AndroidTextMacroEditorBlock]

    public init(blocks: [AndroidTextMacroEditorBlock]) {
        self.blocks = blocks
    }

    public func moved(from: Int, to: Int) -> Self {
        guard blocks.indices.contains(from), blocks.indices.contains(to), from != to else { return self }
        var changed = blocks
        let block = changed.remove(at: from)
        changed.insert(block, at: to)
        return Self(blocks: changed)
    }

    public func replacing(at index: Int, with block: AndroidTextMacroEditorBlock) throws -> Self {
        guard blocks.indices.contains(index) else {
            throw AndroidTextMacroEditorDocumentError.indexOutOfRange(index)
        }
        var changed = blocks
        changed[index] = block
        return Self(blocks: changed)
    }

    public func removing(at index: Int) throws -> Self {
        guard blocks.indices.contains(index) else {
            throw AndroidTextMacroEditorDocumentError.indexOutOfRange(index)
        }
        var changed = blocks
        changed.remove(at: index)
        return Self(blocks: changed)
    }

    public func adding(_ block: AndroidTextMacroEditorBlock, at index: Int? = nil) -> Self {
        var changed = blocks
        let insertionIndex = (index ?? changed.count).clamped(to: 0...changed.count)
        changed.insert(block, at: insertionIndex)
        return Self(blocks: changed)
    }

    public func toSource() -> String {
        blocks.map(\.source).joined()
    }

    public static func parse(_ source: String) throws -> Self {
        let compiled = try AndroidTextMacroCompiler.compile(source)
        let blocks = compiled.parts.map { part -> AndroidTextMacroEditorBlock in
            switch part {
            case let .literal(value): .text(value)
            case let .variable(name, argument): .token(name: name, argument: argument)
            case .cursor: .token(name: "cursor")
            }
        }
        return Self(blocks: blocks)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
