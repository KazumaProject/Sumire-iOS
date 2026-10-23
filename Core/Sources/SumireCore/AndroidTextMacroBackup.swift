import CoreFoundation
import Foundation

public struct AndroidTextMacroImportPreview: Equatable {
    public let entries: [PersonalTextMacro]
    public let added: Int
    public let overwritten: Int
}

/// Reads and writes the version-one JSON format used by Android's
/// `TextMacroRepository`. Import is staged and does not mutate a library.
public enum AndroidTextMacroBackup {
    public static let version = 1
    public static let maximumBytes = 32 * 1024 * 1024
    private static let maximumEntries = 100_000

    private struct Export: Encodable {
        struct Entry: Encodable {
            let name: String
            let reading: String?
            let body: String
            let enabled: Bool

            private enum CodingKeys: String, CodingKey {
                case name, reading, body, enabled
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(name, forKey: .name)
                // Android's import requires this key even for a null reading.
                try container.encode(reading, forKey: .reading)
                try container.encode(body, forKey: .body)
                try container.encode(enabled, forKey: .enabled)
            }
        }

        let version: Int
        let macros: [Entry]
    }

    public static func encode(_ macros: [PersonalTextMacro]) throws -> Data {
        guard macros.count <= maximumEntries else {
            throw PersonalDataError("定型マクロは\(maximumEntries)件以下で書き出してください")
        }
        var names = Set<[UInt8]>()
        let entries = try macros.map { macro -> Export.Entry in
            try macro.validate()
            guard names.insert(AndroidTextMacroNameComparison.sqliteNoCaseKey(macro.name)).inserted else {
                throw PersonalDataError("同じ名前の定型マクロが重複しています")
            }
            return Export.Entry(
                name: macro.name,
                reading: macro.reading,
                body: macro.body,
                enabled: macro.enabled
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Export(version: version, macros: entries))
        guard data.count <= maximumBytes else { throw PersonalDataError("定型マクロのバックアップが大きすぎます") }
        return data
    }

    /// Applies a validated Android import preview by Android's case-insensitive,
    /// otherwise exact name matching. Existing local IDs remain stable.
    public static func merge(
        _ preview: AndroidTextMacroImportPreview,
        into existing: [PersonalTextMacro]
    ) throws -> [PersonalTextMacro] {
        var merged = existing
        var positions: [[UInt8]: Int] = [:]
        for (index, macro) in existing.enumerated() {
            let key = AndroidTextMacroNameComparison.sqliteNoCaseKey(macro.name)
            guard positions[key] == nil else {
                throw PersonalDataError("同じ名前の定型マクロが重複しています")
            }
            positions[key] = index
        }
        for incoming in preview.entries {
            let key = AndroidTextMacroNameComparison.sqliteNoCaseKey(incoming.name)
            if let index = positions[key] {
                var replacement = incoming
                replacement.id = merged[index].id
                merged[index] = replacement
            } else {
                positions[key] = merged.count
                merged.append(incoming)
            }
        }
        return merged
    }

    public static func decode(
        _ data: Data,
        existing: [PersonalTextMacro] = []
    ) throws -> AndroidTextMacroImportPreview {
        guard data.count <= maximumBytes else { throw PersonalDataError("定型マクロのバックアップが大きすぎます") }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == Set(["version", "macros"]),
              let version = root["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.intValue == Self.version,
              let rows = root["macros"] as? [Any], rows.count <= maximumEntries else {
            throw PersonalDataError("Android形式の定型マクロバックアップを読み込めません")
        }

        var entries: [PersonalTextMacro] = []
        var names = Set<[UInt16]>()
        entries.reserveCapacity(rows.count)
        for (index, value) in rows.enumerated() {
            guard let row = value as? [String: Any],
                  Set(row.keys) == Set(["name", "reading", "body", "enabled"]),
                  let name = row["name"] as? String,
                  let body = row["body"] as? String,
                  let enabledValue = row["enabled"] as? NSNumber,
                  CFGetTypeID(enabledValue) == CFBooleanGetTypeID() else {
                throw PersonalDataError("定型マクロの\(index + 1)件目の形式が不正です")
            }

            let reading: String?
            switch row["reading"] {
            case nil, is NSNull:
                reading = nil
            case let value as String:
                reading = value
            default:
                throw PersonalDataError("定型マクロの\(index + 1)件目の読みが不正です")
            }

            let rawEntry = PersonalTextMacro(
                name: name,
                reading: reading,
                body: body,
                enabled: enabledValue.boolValue
            )
            do {
                try rawEntry.validate()
            } catch {
                throw PersonalDataError("定型マクロの\(index + 1)件目: \(error.localizedDescription)")
            }
            // Android validates the original reading first, then maps only a
            // blank reading to null. It otherwise preserves imported text verbatim.
            let entry = PersonalTextMacro(
                id: rawEntry.id,
                name: rawEntry.name,
                reading: reading?.takeIfAndroidNonblank,
                body: rawEntry.body,
                enabled: rawEntry.enabled
            )
            guard names.insert(AndroidTextMacroNameComparison.androidRootLowercaseKey(entry.name)).inserted else {
                throw PersonalDataError("バックアップに同じ名前の定型マクロが重複しています")
            }
            entries.append(entry)
        }

        // Android's confirmation counts use Locale.ROOT lowercase, while its
        // apply step later looks rows up with SQLite NOCASE. Preserve that
        // distinction so the staged preview reports the same counts.
        let existingNames = Set(existing.map { AndroidTextMacroNameComparison.androidRootLowercaseKey($0.name) })
        let overwritten = entries.filter {
            existingNames.contains(AndroidTextMacroNameComparison.androidRootLowercaseKey($0.name))
        }.count
        return AndroidTextMacroImportPreview(
            entries: entries,
            added: entries.count - overwritten,
            overwritten: overwritten
        )
    }
}

private extension String {
    var takeIfAndroidNonblank: String? {
        unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) } ? self : nil
    }
}
