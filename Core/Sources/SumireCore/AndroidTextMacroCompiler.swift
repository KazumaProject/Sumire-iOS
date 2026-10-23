import Foundation

/// Limits mirrored from the pinned Android `TextMacroCompiler` reference.
public enum AndroidTextMacroLimits {
    public static let name = 80
    public static let reading = 64
    public static let body = 10_000
    public static let token = 128
    public static let expanded = 100_000
}

public enum AndroidTextMacroContextRequirement: Hashable {
    case selection
    case clipboard
}

/// Values are supplied by an explicit caller. The compiler never reads UIKit,
/// an input proxy, or the system clipboard itself.
public struct AndroidTextMacroContext {
    public let selection: String?
    public let clipboard: String?
    public let locale: Locale
    public let timeZone: TimeZone
    public let timestamp: Date

    public init(
        selection: String? = nil,
        clipboard: String? = nil,
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        timestamp: Date = Date()
    ) {
        self.selection = selection
        self.clipboard = clipboard
        self.locale = locale
        self.timeZone = timeZone
        self.timestamp = timestamp
    }
}

public struct AndroidExpandedTextMacro: Equatable {
    public let text: String
    /// UTF-16 offset, matching Android/Kotlin `String.length` and InputConnection.
    public let cursorOffset: Int

    public init(text: String, cursorOffset: Int) {
        self.text = text
        self.cursorOffset = cursorOffset
    }

    /// Delta from the end of the inserted text to the requested cursor position.
    /// UIKit's text-document proxy is called with the same UTF-16 convention used
    /// by the Android implementation and by the other proxy adjustments here.
    public func cursorAdjustmentUTF16() throws -> Int {
        guard cursorOffset >= 0, cursorOffset <= text.utf16.count else {
            throw AndroidTextMacroSyntaxError("Cursor offset is outside the expanded text", position: cursorOffset)
        }
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: cursorOffset)
        guard utf16Index.samePosition(in: text.unicodeScalars) != nil else {
            throw AndroidTextMacroSyntaxError("Cursor offset splits a Unicode scalar", position: cursorOffset)
        }
        return cursorOffset - text.utf16.count
    }
}

public struct AndroidTextMacroSyntaxError: Error, Equatable, LocalizedError {
    public let message: String
    /// UTF-16 source offset, matching the Android implementation.
    public let position: Int

    public init(_ message: String, position: Int) {
        self.message = message
        self.position = position
    }

    public var errorDescription: String? { message }
}

public enum AndroidTextMacroPart: Equatable {
    case literal(String)
    case variable(name: String, argument: String?)
    case cursor
}

public struct CompiledAndroidTextMacro {
    public let parts: [AndroidTextMacroPart]
    public let requirements: Set<AndroidTextMacroContextRequirement>

    public func expand(context: AndroidTextMacroContext) throws -> AndroidExpandedTextMacro {
        var output = ""
        var outputUTF16Length = 0
        var cursorOffset: Int?

        func append(_ value: String) throws {
            let valueLength = value.utf16.count
            guard valueLength <= AndroidTextMacroLimits.expanded - outputUTF16Length else {
                throw AndroidTextMacroSyntaxError(
                    "Expanded macro exceeds \(AndroidTextMacroLimits.expanded) UTF-16 characters",
                    position: AndroidTextMacroLimits.expanded
                )
            }
            output += value
            outputUTF16Length += valueLength
        }

        for part in parts {
            switch part {
            case let .literal(value):
                try append(value)
            case .cursor:
                cursorOffset = outputUTF16Length
            case let .variable(name, argument):
                try append(expandVariable(name, argument: argument, context: context))
            }
        }

        return AndroidExpandedTextMacro(
            text: output,
            cursorOffset: cursorOffset ?? outputUTF16Length
        )
    }

    private func expandVariable(
        _ name: String,
        argument: String?,
        context: AndroidTextMacroContext
    ) throws -> String {
        switch name {
        case "date":
            return try formatDate(context.timestamp, pattern: argument, date: true, context: context)
        case "time":
            return try formatDate(context.timestamp, pattern: argument, date: false, context: context)
        case "selection":
            guard let value = context.selection, !value.isEmpty else {
                throw AndroidTextMacroSyntaxError("Selected text is unavailable", position: 0)
            }
            return value
        case "clipboard":
            guard let value = context.clipboard, !value.isEmpty else {
                throw AndroidTextMacroSyntaxError("Text clipboard is unavailable", position: 0)
            }
            return value
        case "newline":
            return "\n"
        default:
            // The compiler only creates variables from its fixed catalog.
            throw AndroidTextMacroSyntaxError("Unsupported macro variable: \(name)", position: 0)
        }
    }

    private func formatDate(
        _ date: Date,
        pattern: String?,
        date isDate: Bool,
        context: AndroidTextMacroContext
    ) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.timeZone = context.timeZone

        guard let pattern else {
            if isDate {
                formatter.dateStyle = .short
                formatter.timeStyle = .none
            } else {
                formatter.dateStyle = .none
                formatter.timeStyle = .short
            }
            return formatter.string(from: date)
        }

        // The token grammar and Java-specific `u`/`S` fields are kept compatible
        // with Android. Localized short styles and ICU/CLDR data are provided by
        // the current Apple OS, so their punctuation/names can differ by OS version.
        let converted = try Self.foundationPattern(fromJavaPattern: pattern, locale: context.locale, timeZone: context.timeZone, date: date)
        formatter.dateFormat = converted
        return formatter.string(from: date)
    }

    /// Foundation uses Unicode date pattern letters. These Java fields have
    /// different meanings and are rendered as localized literals before the
    /// remaining shared fields are passed to DateFormatter.
    fileprivate static func foundationPattern(
        fromJavaPattern pattern: String,
        locale: Locale,
        timeZone: TimeZone,
        date: Date
    ) throws -> String {
        let units = Array(pattern.utf16)
        var output: [UInt16] = []
        var index = 0
        var quoted = false
        let supported: Set<UInt16> = Set("GyYMLwWDdFEuaHkKhmsSzZX".utf16)

        while index < units.count {
            let unit = units[index]
            if unit == 0x27 { // apostrophe
                if index + 1 < units.count, units[index + 1] == 0x27 {
                    output.append(contentsOf: [0x27, 0x27])
                    index += 2
                } else {
                    quoted.toggle()
                    output.append(unit)
                    index += 1
                }
                continue
            }

            if !quoted, isASCIILetter(unit) {
                var end = index + 1
                while end < units.count, units[end] == unit { end += 1 }
                guard supported.contains(unit) else {
                    let letter = String(decoding: [unit], as: UTF16.self)
                    throw AndroidTextMacroSyntaxError("Invalid date/time pattern character: \(letter)", position: 0)
                }

                let width = end - index
                // java.text.SimpleDateFormat only permits one to three `X`
                // characters for ISO-8601 time-zone fields.
                guard unit != 0x58 || width <= 3 else {
                    throw AndroidTextMacroSyntaxError("Invalid ISO 8601 time-zone pattern width", position: 0)
                }
                if unit == 0x75 { // Java `u`: ISO day number, Monday = 1.
                    let weekday = isoWeekday(for: date, timeZone: timeZone)
                    output.append(contentsOf: quotedLiteral(localizedNumber(weekday, minimumDigits: width, locale: locale)).utf16)
                } else if unit == 0x53 { // Java `S`: integer milliseconds, not a fraction.
                    let milliseconds = Calendar(identifier: .gregorian)
                        .withTimeZone(timeZone)
                        .dateComponents([.nanosecond], from: date)
                        .nanosecond! / 1_000_000
                    output.append(contentsOf: quotedLiteral(localizedNumber(milliseconds, minimumDigits: width, locale: locale)).utf16)
                } else {
                    // Java's SimpleDateFormat has fewer text widths than
                    // Unicode/ICU. Without normalization, Java `EEEEE`,
                    // `MMMMM`, and `ZZZZZ` would become narrow weekday/month
                    // or ISO-zone fields in Foundation instead of Java's full
                    // weekday/month and RFC-822 zone forms.
                    let foundationWidth: Int
                    switch unit {
                    case 0x45: // E: Java abbreviated (<4) or full (>=4)
                        foundationWidth = width >= 4 ? 4 : 3
                    case 0x47: // G: Java era designator has no narrow form
                        foundationWidth = 3
                    case 0x4C, 0x4D: // L/M: Java has no narrow month form
                        foundationWidth = width >= 4 ? 4 : width
                    case 0x5A: // Z: Java always emits the RFC-822 offset
                        foundationWidth = 3
                    case 0x61: // a: Java uses the locale's AM/PM strings
                        foundationWidth = 3
                    case 0x7A: // z: Java abbreviated (<4) or full (>=4)
                        foundationWidth = width >= 4 ? 4 : 3
                    default:
                        foundationWidth = width
                    }
                    output.append(contentsOf: repeatElement(unit, count: foundationWidth))
                }
                index = end
                continue
            }

            // Append UTF-16 units intact so non-BMP literal text is not split
            // into invalid surrogate halves.
            output.append(unit)
            index += 1
        }

        guard !quoted else {
            throw AndroidTextMacroSyntaxError("Unterminated quote in date/time pattern", position: 0)
        }
        return String(decoding: output, as: UTF16.self)
    }

    private static func isASCIILetter(_ unit: UInt16) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    private static func quotedLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func localizedNumber(_ value: Int, minimumDigits: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumIntegerDigits = minimumDigits
        formatter.maximumIntegerDigits = max(minimumDigits, 3)
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func isoWeekday(for date: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let weekday = calendar.component(.weekday, from: date) // Sunday = 1
        return weekday == 1 ? 7 : weekday - 1
    }
}

public enum AndroidTextMacroCompiler {
    private enum Variable: Equatable {
        case date, time, selection, clipboard, cursor, newline

        var name: String {
            switch self {
            case .date: "date"
            case .time: "time"
            case .selection: "selection"
            case .clipboard: "clipboard"
            case .cursor: "cursor"
            case .newline: "newline"
            }
        }

        var acceptsPattern: Bool { self == .date || self == .time }

        var requirement: AndroidTextMacroContextRequirement? {
            switch self {
            case .selection: .selection
            case .clipboard: .clipboard
            default: nil
            }
        }

        static func named(_ name: String) -> Variable? {
            switch name {
            case "date": .date
            case "time": .time
            case "selection": .selection
            case "clipboard": .clipboard
            case "cursor": .cursor
            case "newline": .newline
            default: nil
            }
        }
    }

    public static func compile(_ body: String) throws -> CompiledAndroidTextMacro {
        let units = Array(body.utf16)
        guard units.count <= AndroidTextMacroLimits.body else {
            throw AndroidTextMacroSyntaxError(
                "Body exceeds \(AndroidTextMacroLimits.body) UTF-16 characters",
                position: AndroidTextMacroLimits.body
            )
        }

        var parts: [AndroidTextMacroPart] = []
        var literal: [UInt16] = []
        var requirements: Set<AndroidTextMacroContextRequirement> = []
        var cursorCount = 0
        var index = 0

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            parts.append(.literal(String(decoding: literal, as: UTF16.self)))
            literal.removeAll(keepingCapacity: true)
        }

        while index < units.count {
            let current = units[index]
            let nextIs = { (unit: UInt16) in index + 1 < units.count && units[index + 1] == unit }

            if current == 0x7B, nextIs(0x7B) { // {{ -> {
                literal.append(0x7B)
                index += 2
            } else if current == 0x7D, nextIs(0x7D) { // }} -> }
                literal.append(0x7D)
                index += 2
            } else if current == 0x7D {
                throw AndroidTextMacroSyntaxError("Unexpected closing brace; escape it as }}", position: index)
            } else if current == 0x7B {
                flushLiteral()
                guard let close = units[index...].firstIndex(of: 0x7D) else {
                    throw AndroidTextMacroSyntaxError("Unclosed macro token", position: index)
                }
                let tokenLength = close - index + 1
                guard tokenLength <= AndroidTextMacroLimits.token else {
                    throw AndroidTextMacroSyntaxError(
                        "Token exceeds \(AndroidTextMacroLimits.token) UTF-16 characters",
                        position: index
                    )
                }
                let tokenUnits = Array(units[(index + 1)..<close])
                guard !tokenUnits.isEmpty, !tokenUnits.contains(0x7B) else {
                    throw AndroidTextMacroSyntaxError("Invalid macro token", position: index)
                }
                let token = String(decoding: tokenUnits, as: UTF16.self)
                let colon = token.firstIndex(of: ":")
                let name = colon.map { String(token[..<$0]) } ?? token
                let argument = colon.map { String(token[token.index(after: $0)...]) }
                guard let variable = Variable.named(name) else {
                    throw AndroidTextMacroSyntaxError("Unknown macro token: \(name)", position: index)
                }
                if argument != nil, !variable.acceptsPattern {
                    throw AndroidTextMacroSyntaxError("\(name) does not accept an argument", position: index)
                }
                if argument?.isEmpty == true {
                    throw AndroidTextMacroSyntaxError("Empty date/time pattern", position: index)
                }
                if let argument {
                    do {
                        _ = try CompiledAndroidTextMacro.foundationPattern(
                            fromJavaPattern: argument,
                            locale: Locale(identifier: "en_US_POSIX"),
                            timeZone: TimeZone(secondsFromGMT: 0)!,
                            date: Date(timeIntervalSince1970: 0)
                        )
                    } catch let error as AndroidTextMacroSyntaxError {
                        throw AndroidTextMacroSyntaxError(error.message, position: index)
                    }
                }

                if variable == .cursor {
                    cursorCount += 1
                    guard cursorCount == 1 else {
                        throw AndroidTextMacroSyntaxError("Only one {cursor} is allowed", position: index)
                    }
                    parts.append(.cursor)
                } else {
                    parts.append(.variable(name: variable.name, argument: argument))
                    if let requirement = variable.requirement { requirements.insert(requirement) }
                }
                index = close + 1
            } else {
                literal.append(current)
                index += 1
            }
        }

        flushLiteral()
        return CompiledAndroidTextMacro(parts: parts, requirements: requirements)
    }
}

public enum AndroidTextMacroValidator {
    public static func validateDefinition(name: String, reading: String?, body: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AndroidTextMacroSyntaxError("Name is required", position: 0)
        }
        guard name.utf16.count <= AndroidTextMacroLimits.name else {
            throw AndroidTextMacroSyntaxError("Name exceeds \(AndroidTextMacroLimits.name) characters", position: 0)
        }
        guard (reading?.utf16.count ?? 0) <= AndroidTextMacroLimits.reading else {
            throw AndroidTextMacroSyntaxError("Reading exceeds \(AndroidTextMacroLimits.reading) characters", position: 0)
        }
        _ = try AndroidTextMacroCompiler.compile(body)
    }
}

/// Mirrors Android's exact-reading suggestion query while keeping contextual
/// data behind an explicit iOS consent step. Selection macros use Android's
/// separate selection-action path and therefore never appear in this list.
public enum AndroidTextMacroCandidatePolicy {
    public static let maximumCandidates = 8

    public static func candidates(
        in macros: [PersonalTextMacro],
        reading: String,
        contextAllowed: Bool
    ) -> [PersonalTextMacro] {
        let matching = macros.enumerated().filter { _, macro in
            macro.enabled && macro.reading == reading
        }

        // Android orders by SQLite NOCASE (ASCII-only case folding), then its
        // database ID. The source array is stable in insertion/import order and
        // serves as the corresponding tie-breaker for iOS records.
        let limited = matching.sorted { lhs, rhs in
            let left = asciiNoCaseBytes(lhs.1.name)
            let right = asciiNoCaseBytes(rhs.1.name)
            return left == right ? lhs.0 < rhs.0 : left.lexicographicallyPrecedes(right)
        }
        .prefix(maximumCandidates)

        // Android's DAO applies LIMIT before the IME compiles and filters
        // contextual macros. Keep that order so a hidden macro among the first
        // eight does not cause a later row to be promoted into the candidates.
        return limited.compactMap { _, macro in
            guard let compiled = try? AndroidTextMacroCompiler.compile(macro.body),
                  !compiled.requirements.contains(.selection),
                  compiled.requirements.isEmpty || contextAllowed else { return nil }
            return macro
        }
    }

    private static func asciiNoCaseBytes(_ value: String) -> [UInt8] {
        value.utf8.map { byte in
            (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
        }
    }
}

private extension Calendar {
    func withTimeZone(_ timeZone: TimeZone) -> Calendar {
        var copy = self
        copy.timeZone = timeZone
        return copy
    }
}
