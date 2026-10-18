import Foundation
import CryptoKit

/// Portable snapshot of the personal dictionaries. Validation precedes any store mutation.
public enum PersonalBackup {
    public static let maximumBytes = 128 * 1024 * 1024
    public struct Contents: Codable, Equatable {
        public var lexicon: PersonalLexicon
        public var settings: KeyboardSettingsSnapshot?
        public var learning: [LearningStore.Entry]?
        public init(lexicon: PersonalLexicon, settings: KeyboardSettingsSnapshot? = nil, learning: [LearningStore.Entry]? = nil) {
            self.lexicon = lexicon; self.settings = settings; self.learning = learning
        }
        public func validate() throws {
            try lexicon.validate()
            try settings?.validate()
            if let learning { try LearningStore.validateSnapshot(learning) }
        }
    }
    private struct Envelope: Codable {
        let format: String
        let version: Int
        let sha256: String
        let payload: Data
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func encode(_ lexicon: PersonalLexicon) throws -> Data {
        try lexicon.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(lexicon)
        guard payload.count <= 32 * 1024 * 1024 else { throw PersonalDataError("バックアップが大きすぎます") }
        let data = try encoder.encode(Envelope(format: "sumire-personal-backup", version: 1,
                                             sha256: digest(payload), payload: payload))
        guard data.count <= maximumBytes else { throw PersonalDataError("バックアップが大きすぎます") }
        return data
    }
    public static func encode(_ contents: Contents) throws -> Data {
        try contents.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(contents)
        let version = contents.learning == nil ? 2 : 3
        guard payload.count <= (version == 3 ? 88 : 56) * 1024 * 1024 else { throw PersonalDataError("バックアップが大きすぎます") }
        let data = try encoder.encode(Envelope(format: "sumire-personal-backup", version: version,
                                             sha256: digest(payload), payload: payload))
        guard data.count <= maximumBytes else { throw PersonalDataError("バックアップが大きすぎます") }
        return data
    }
    public static func decode(_ data: Data) throws -> PersonalLexicon {
        try decodeContents(data).lexicon
    }
    public static func decodeContents(_ data: Data) throws -> Contents {
        guard data.count <= maximumBytes else { throw PersonalDataError("バックアップが大きすぎます") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.format == "sumire-personal-backup", (1...3).contains(envelope.version) else {
            throw PersonalDataError("未対応のバックアップ形式です")
        }
        guard envelope.payload.count <= (envelope.version == 1 ? 32 : envelope.version == 2 ? 56 : 88) * 1024 * 1024, digest(envelope.payload) == envelope.sha256 else {
            throw PersonalDataError("バックアップが破損しています")
        }
        let contents = envelope.version == 1
            ? Contents(lexicon: try JSONDecoder().decode(PersonalLexicon.self, from: envelope.payload))
            : try JSONDecoder().decode(Contents.self, from: envelope.payload)
        guard envelope.version == 3 || contents.learning == nil else {
            throw PersonalDataError("バックアップの学習データと形式が一致しません")
        }
        try contents.validate()
        return contents
    }
    public static func read(_ url: URL) throws -> PersonalLexicon {
        try readContents(url).lexicon
    }
    public static func readContents(_ url: URL) throws -> Contents {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65536, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw PersonalDataError("バックアップが大きすぎます") }
        }
        return try decodeContents(data)
    }
}
