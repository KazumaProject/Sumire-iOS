import Foundation

/// Input state owns the reading, independently of asynchronous conversion and layout.
public struct CompositionState {
    public enum Phase: Equatable { case idle, editing, selecting, committed }
    public private(set) var reading = ""
    public private(set) var cursor = 0 // Extended grapheme clusters from the start.
    public var characterBeforeCursor: Character? { reading.prefix(cursor).last }
    public var cursorUTF16: Int { reading.prefix(cursor).utf16.count }
    public private(set) var generation: UInt64 = 0
    public private(set) var phase: Phase = .idle
    public init() {}
    public mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        let boundary = reading.index(reading.startIndex, offsetBy: cursor)
        let prefix = String(reading[..<boundary]) + text
        reading = prefix + reading[boundary...]
        cursor = min(prefix.count, reading.count)
        generation += 1
        phase = .editing
    }
    @discardableResult public mutating func replaceLast(_ text: String) -> Bool {
        guard cursor > 0 else { return false }
        let end = reading.index(reading.startIndex, offsetBy: cursor)
        let start = reading.index(before: end)
        let prefix = String(reading[..<start]) + text
        reading = prefix + reading[end...]
        cursor = min(prefix.count, reading.count)
        generation += 1
        phase = reading.isEmpty ? .idle : .editing
        return true
    }
    public mutating func appendRomaji(_ text: String, using converter: RomajiConverter) {
        guard !text.isEmpty else { return }
        let boundary = reading.index(reading.startIndex, offsetBy: cursor)
        let prefix = converter.convert(String(reading[..<boundary]) + text)
        reading = prefix + reading[boundary...]
        cursor = min(prefix.count, reading.count)
        generation += 1
        phase = .editing
    }
    @discardableResult public mutating func flushRomaji(using converter: RomajiConverter) -> Bool {
        let boundary = reading.index(reading.startIndex, offsetBy: cursor)
        let prefix = converter.flush(String(reading[..<boundary]))
        let flushed = prefix + reading[boundary...]
        guard flushed != reading else { return false }
        reading = flushed
        cursor = min(prefix.count, reading.count)
        generation += 1
        phase = .editing
        return true
    }
    @discardableResult public mutating func deleteBackward() -> Bool {
        guard !reading.isEmpty else { return false }
        guard cursor > 0 else { return true } // Do not delete committed host text at the composing start.
        let end = reading.index(reading.startIndex, offsetBy: cursor)
        let start = reading.index(before: end)
        reading.removeSubrange(start..<end)
        cursor -= 1
        generation += 1
        phase = reading.isEmpty ? .idle : .editing
        return true
    }
    /// Cursor keys edit inside marked text; they do not commit the composition.
    @discardableResult public mutating func moveCursor(by offset: Int) -> Bool {
        guard !reading.isEmpty else { return false }
        let next = min(reading.count, max(0, cursor + offset))
        if next != cursor {
            cursor = next
            generation += 1
            phase = .editing
        }
        return true
    }
    /// Adopt a host caret only at an extended grapheme boundary. Rejected
    /// UIKit UTF-16 offsets leave the cursor and generation unchanged.
    @discardableResult public mutating func moveCursor(toUTF16 offset: Int) -> Bool {
        guard !reading.isEmpty, offset >= 0, offset <= reading.utf16.count else { return false }
        let unitIndex = reading.utf16.index(reading.utf16.startIndex, offsetBy: offset)
        guard let index = String.Index(unitIndex, within: reading),
              index == reading.endIndex || reading.indices.contains(index) else { return false }
        return moveCursor(by: reading.distance(from: reading.startIndex, to: index) - cursor)
    }
    @discardableResult public mutating func synchronizeCursor(markedText: String, selection: NSRange) -> Bool {
        guard markedText.utf16.elementsEqual(reading.utf16), selection.length == 0 else { return false }
        return moveCursor(toUTF16: selection.location)
    }
    public mutating func optionsChanged() {
        guard !reading.isEmpty else { return }
        generation += 1
        phase = .editing
    }
    public mutating func select() {
        guard !reading.isEmpty else { return }
        phase = .selecting
    }
    public func accepts(_ resultGeneration: UInt64) -> Bool {
        !reading.isEmpty && generation == resultGeneration
    }
    /// The caller supplies the selected surface only after checking its generation.
    public mutating func commit(_ surface: String? = nil) -> String? {
        guard !reading.isEmpty else { return nil }
        let text = surface ?? reading
        reading = ""
        cursor = 0
        generation += 1
        phase = .committed
        return text
    }
    /// Consume a candidate's UTF-16 reading prefix, retaining the unconverted
    /// suffix. Only Character boundaries are valid; rejected ranges do not mutate
    /// the input or invalidate an outstanding conversion result.
    public mutating func commitPrefix(_ surface: String, readingUTF16Length: Int) -> String? {
        guard readingUTF16Length > 0 else { return nil }
        var consumed = 0
        var boundary = reading.startIndex
        while boundary < reading.endIndex && consumed < readingUTF16Length {
            consumed += reading[boundary].utf16.count
            boundary = reading.index(after: boundary)
        }
        guard consumed == readingUTF16Length else { return nil }
        let consumedCharacters = reading[..<boundary].count
        reading = String(reading[boundary...])
        cursor = min(reading.count, max(0, cursor - consumedCharacters))
        generation += 1
        phase = reading.isEmpty ? .committed : .editing
        return surface
    }

    public mutating func invalidate() {
        reading = ""
        cursor = 0
        generation += 1
        phase = .idle
    }
}
