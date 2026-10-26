import Foundation

/// Column preference for user-dictionary text exports supported by Android.
public enum PersonalDictionaryTextFormat: Equatable {
    case automatic
    case googleJapaneseInput
    case microsoftIME
}

public extension PersonalImportPreview {
    private static var maximumLineBytes: Int { 256 * 1024 }
    private static var maximumColumns: Int { 256 }

    /// Decodes UTF-8/UTF-16 text (with BOM detection) and parses the pinned
    /// Android Google Japanese Input / Microsoft IME CSV and TSV import format.
    static func parseText(_ data: Data, format: PersonalDictionaryTextFormat = .automatic) throws -> Self {
        guard data.count <= 32 * 1024 * 1024 else { throw PersonalDataError("テキスト辞書が大きすぎます") }
        return parseText(try decodeText(data), format: format)
    }

    /// Parses one record per line. Quoted CSV fields may contain commas but,
    /// like Android's importer, a quoted field cannot continue across lines.
    static func parseText(_ text: String, format: PersonalDictionaryTextFormat = .automatic) -> Self {
        var entries: [PersonalWord] = []
        var positions: [String: Int] = [:]
        var errors: [String] = []
        var rejected = 0
        var duplicates = 0
        var lineNumber = 0

        func process(_ rawLine: String, lineNumber: Int) {
            guard rawLine.utf8.count <= maximumLineBytes else {
                reject(lineNumber, "1行が大きすぎます", rejected: &rejected, errors: &errors)
                return
            }

            let lineText = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lineText.isEmpty, !lineText.hasPrefix("#"), !lineText.hasPrefix("//"), !lineText.hasPrefix(";") else { return }
            guard !(lineText.localizedCaseInsensitiveContains("Microsoft IME") && !lineText.contains("\t")) else { return }

            guard let columns = columns(in: lineText), columns.count >= 2 else {
                reject(lineNumber, "CSVまたはTSVの読み・表記を確認してください", rejected: &rejected, errors: &errors)
                return
            }
            if looksLikeHeader(columns) { return }

            guard let parsed = chooseReadingAndWord(columns, format: format) else {
                reject(lineNumber, "かなの読みと表記を判定できません", rejected: &rejected, errors: &errors)
                return
            }
            guard !parsed.reading.isEmpty, !parsed.word.isEmpty, isHiraganaWithSymbols(parsed.reading) else {
                reject(lineNumber, "読みにはひらがなまたは対応する記号を指定してください", rejected: &rejected, errors: &errors)
                return
            }

            let key = "\(parsed.reading.utf8.count):" + parsed.reading + parsed.word
            guard positions[key] == nil else {
                duplicates += 1
                return
            }
            let entry = PersonalWord(word: parsed.word, reading: parsed.reading,
                                     posIndex: resolvePosIndex(parsed.posHint), posScore: 5000)
            do {
                try entry.validate()
            } catch {
                reject(lineNumber, error.localizedDescription, rejected: &rejected, errors: &errors)
                return
            }
            positions[key] = entries.count
            entries.append(entry)
        }

        // Scan only the supported prefix. String.enumerateLines cannot be stopped from
        // its callback, so a newline-dense file could otherwise process millions of lines.
        let scalars = text.unicodeScalars
        var lineStart = scalars.startIndex
        while lineStart < scalars.endIndex, lineNumber < 100_000 {
            var lineEnd = lineStart
            while lineEnd < scalars.endIndex, scalars[lineEnd] != "\n", scalars[lineEnd] != "\r" {
                lineEnd = scalars.index(after: lineEnd)
            }
            lineNumber += 1
            process(String(text[lineStart..<lineEnd]), lineNumber: lineNumber)

            guard lineEnd < scalars.endIndex else {
                lineStart = scalars.endIndex
                break
            }
            let delimiter = scalars[lineEnd]
            lineStart = scalars.index(after: lineEnd)
            if delimiter == "\r", lineStart < scalars.endIndex, scalars[lineStart] == "\n" {
                lineStart = scalars.index(after: lineStart)
            }
        }
        let wasTruncated = lineStart < scalars.endIndex

        return Self(entries: entries, rejected: rejected, errors: errors, duplicates: duplicates,
                    duplicatePolicy: .keepFirst, isTextImport: true, wasTruncated: wasTruncated)
    }

    /// Uses the same broad Japanese/English POS hints and indices as the Android parser.
    static func resolvePosIndex(_ hint: String?) -> Int {
        guard let hint, !hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        let normalized = hint.lowercased(with: Locale(identifier: "en_US_POSIX"))
        return posPatterns.first { pattern in
            pattern.keywords.contains { normalized.contains($0.lowercased(with: Locale(identifier: "en_US_POSIX"))) }
        }?.index ?? 0
    }

    private struct ParsedColumns {
        let reading: String
        let word: String
        let posHint: String?
    }

    private struct POSPattern {
        let index: Int
        let keywords: [String]
    }

    private static let posPatterns: [POSPattern] = [
        .init(index: 4, keywords: ["助動詞", "auxiliary"]),
        .init(index: 3, keywords: ["副詞", "adverb"]),
        .init(index: 5, keywords: ["助詞", "particle"]),
        .init(index: 2, keywords: ["形容詞", "形容動詞", "adjective"]),
        .init(index: 1, keywords: ["動詞", "verb"]),
        .init(index: 6, keywords: ["感動詞", "interjection"]),
        .init(index: 7, keywords: ["接続詞", "conjunction"]),
        .init(index: 8, keywords: ["接頭詞", "接頭語", "prefix"]),
        .init(index: 9, keywords: ["記号", "顔文字", "symbol", "emoticon"]),
        .init(index: 10, keywords: ["連体詞", "adnominal"]),
        .init(index: 11, keywords: ["その他", "接尾", "other", "suffix"]),
        .init(index: 0, keywords: ["名詞", "固有名詞", "人名", "姓", "名", "地名", "地域", "組織", "短縮よみ", "サジェストのみ", "noun", "proper", "person", "place", "name", "organization"])
    ]

    private static func reject(_ line: Int, _ message: String, rejected: inout Int, errors: inout [String]) {
        rejected += 1
        if errors.count < 100 { errors.append("\(line)行目: \(message)") }
    }

    private static func columns(in line: String) -> [String]? {
        let isTSV = line.contains("\t")
        let separator: Character = isTSV ? "\t" : ","
        guard line.contains(separator) else { return nil }

        var rawColumns: [String] = []
        var field = ""
        var quoted = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            if !isTSV, character == "\"", quoted, next < line.endIndex, line[next] == "\"" {
                field.append("\"")
                index = line.index(after: next)
                continue
            }
            if !isTSV, character == "\"" {
                quoted.toggle()
            } else if character == separator, isTSV || !quoted {
                guard rawColumns.count < maximumColumns - 1 else { return nil }
                rawColumns.append(field)
                field = ""
            } else {
                field.append(character)
            }
            index = next
        }
        rawColumns.append(field)
        return rawColumns.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }

    private static func looksLikeHeader(_ columns: [String]) -> Bool {
        let values = columns.prefix(4).map { $0.lowercased(with: Locale(identifier: "en_US_POSIX")) }
        let hasReading = values.contains { ["よみ", "読み", "yomi", "reading"].contains($0) }
        let hasWord = values.contains { ["単語", "語句", "word", "phrase"].contains($0) }
        let hasPOS = values.contains { ["品詞", "part of speech", "pos"].contains($0) }
        return hasReading && hasWord && hasPOS
    }

    private static func chooseReadingAndWord(_ columns: [String], format: PersonalDictionaryTextFormat) -> ParsedColumns? {
        let preferredPairs: [(Int, Int)] = switch format {
        case .googleJapaneseInput: [(0, 1), (1, 0)]
        case .microsoftIME: [(1, 0), (0, 1)]
        case .automatic: []
        }
        for (readingIndex, wordIndex) in preferredPairs {
            if let parsed = buildParsedColumns(columns, readingIndex: readingIndex, wordIndex: wordIndex),
               isHiraganaWithSymbols(parsed.reading) {
                return parsed
            }
        }

        guard let readingIndex = columns.firstIndex(where: { isHiraganaWithSymbols(normalizeYomi($0)) }),
              let wordIndex = columns.indices.first(where: { $0 != readingIndex && !columns[$0].isEmpty }) else { return nil }
        return buildParsedColumns(columns, readingIndex: readingIndex, wordIndex: wordIndex)
    }

    private static func buildParsedColumns(_ columns: [String], readingIndex: Int, wordIndex: Int) -> ParsedColumns? {
        guard let rawReading = columns[safe: readingIndex], let word = columns[safe: wordIndex],
              !rawReading.isEmpty, !word.isEmpty else { return nil }
        let posHint = columns.indices.first(where: { index in
            index != readingIndex && index != wordIndex && looksLikePOSHint(columns[index])
        }).map { columns[$0] } ?? columns[safe: 2].flatMap { 2 != readingIndex && 2 != wordIndex ? $0 : nil }
        return ParsedColumns(reading: normalizeYomi(rawReading), word: word, posHint: posHint)
    }

    private static func looksLikePOSHint(_ value: String) -> Bool {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let normalized = value.lowercased(with: Locale(identifier: "en_US_POSIX"))
        return posPatterns.contains { pattern in
            pattern.keywords.contains { normalized.contains($0.lowercased(with: Locale(identifier: "en_US_POSIX"))) }
        }
    }

    private static func normalizeYomi(_ value: String) -> String {
        var normalized = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if (0x30A1...0x30F6).contains(scalar.value), let hiragana = UnicodeScalar(scalar.value - 0x60) {
                normalized.append(hiragana)
            } else {
                normalized.append(scalar)
            }
        }
        return String(normalized).lowercased(with: Locale(identifier: "ja_JP"))
    }

    private static func isHiraganaWithSymbols(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            (0x3041...0x3096).contains(scalar.value) ||
            ["ー", "-", "？", "?", "！", "!", "。", "、"].contains(String(scalar))
        }
    }

    private static func decodeText(_ data: Data) throws -> String {
        func startsWith(_ bytes: [UInt8]) -> Bool { data.starts(with: bytes) }
        var encoding: String.Encoding = .utf8
        var payload = data
        if startsWith([0xEF, 0xBB, 0xBF]) {
            payload = data.dropFirst(3)
        } else if startsWith([0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
            payload = data.dropFirst(2)
        } else if startsWith([0xFE, 0xFF]) {
            encoding = .utf16BigEndian
            payload = data.dropFirst(2)
        } else if data.count > 0, Double(data.filter { $0 == 0 }.count) > Double(data.count) / 10 {
            encoding = .utf16LittleEndian
        }

        if let text = String(data: payload, encoding: encoding) { return text }
        if encoding != .utf8, let text = String(data: payload, encoding: .utf8) { return text }
        if let text = String(data: payload, encoding: .shiftJIS) { return text }
        throw PersonalDataError("テキスト辞書をUTF-8、UTF-16、またはShift-JISとして読み取れません")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
