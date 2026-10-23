import Foundation
import SwiftUI
import SumireCore

enum PersonalBackupImport {
    case sumire(PersonalBackup.Contents)
    case androidSettings(AndroidPreferenceBackup)
}

final class PersonalLibrary: ObservableObject {
    @Published private(set) var lexicon = PersonalLexicon()
    @Published private(set) var notice: String?
    @Published private(set) var writable = false
    private static let backupQueue = DispatchQueue(label: "sumire.backup", qos: .userInitiated)
    private var backupInProgress = false
    private let store = PersonalDataLocation.store(allowShared: true)
    private var backupRestorer: PersonalBackupRestorer {
        PersonalBackupRestorer(lexiconStore: store, defaults: KeyboardSettings.appDefaults,
                              learningURL: PersonalDataLocation.learningURL(allowShared: true),
                              journalURL: store.directory.deletingLastPathComponent().appendingPathComponent("pending-restore.json"))
    }
    init() {
        do {
            try backupRestorer.recover()
            let loaded = try store.load()
            lexicon = loaded.lexicon
            writable = true
            if loaded.recovered { notice = "現在のデータに問題があるため、直前の正常な世代を読み込みました" }
        } catch { notice = error.localizedDescription }
    }
    func apply(_ next: PersonalLexicon) throws {
        guard writable, !backupInProgress else { throw PersonalDataError("既存データを読み込めないため上書きを停止しています") }
        try restoreBackup(next)
    }
    /// Explicit, confirmed recovery can replace an unreadable current pointer.
    /// The store writes a new generation and leaves the old files intact.
    private func restoreBackup(_ next: PersonalLexicon) throws {
        let saved = try store.save(next)
        lexicon = saved.lexicon
        writable = true
        notice = nil
    }
    func exportBackup(completion: @escaping (Result<Data, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !backupInProgress, writable else {
            completion(.failure(PersonalDataError("現在バックアップを保存できません"))); return
        }
        backupInProgress = true
        let lexicon = lexicon, defaults = KeyboardSettings.appDefaults
        let learningURL = PersonalDataLocation.learningURL(allowShared: true)
        Self.backupQueue.async {
            let result = Result {
                try PersonalBackup.encode(.init(lexicon: lexicon,
                    settings: KeyboardSettingsSnapshot.capture(defaults: defaults),
                    learning: LearningStore(url: learningURL).snapshot()))
            }
            DispatchQueue.main.async { self.backupInProgress = false; completion(result) }
        }
    }
    static func readBackup(_ url: URL, completion: @escaping (Result<PersonalBackupImport, Error>) -> Void) {
        backupQueue.async {
            let access = url.startAccessingSecurityScopedResource()
            let result = Result { () -> PersonalBackupImport in
                let data = try Self.readBackupData(url)
                if let android = try AndroidPreferenceBackup.decodeIfMatching(data) {
                    return .androidSettings(android)
                }
                return .sumire(try PersonalBackup.decodeContents(data))
            }
            if access { url.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func readBackupData(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, PersonalBackup.maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= PersonalBackup.maximumBytes else {
                throw PersonalDataError("バックアップが大きすぎます")
            }
        }
        return data
    }
    func restoreBackup(_ contents: PersonalBackup.Contents, completion: @escaping (Result<Void, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !backupInProgress else {
            completion(.failure(PersonalDataError("バックアップを処理中です"))); return
        }
        backupInProgress = true; writable = false
        let restorer = backupRestorer, store = store
        Self.backupQueue.async {
            let result = Result { () throws -> PersonalLexicon in
                try restorer.restore(contents)
                return try store.load().lexicon
            }
            DispatchQueue.main.async {
                self.backupInProgress = false
                switch result {
                case .success(let lexicon):
                    self.lexicon = lexicon; self.writable = true; self.notice = nil
                    completion(.success(()))
                case .failure(let error):
                    self.notice = "復元を完了できませんでした：" + error.localizedDescription
                    completion(.failure(error))
                }
            }
        }
    }

    func restoreAndroidSettings(_ backup: AndroidPreferenceBackup, completion: @escaping (Result<Int, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !backupInProgress else {
            completion(.failure(PersonalDataError("バックアップを処理中です"))); return
        }
        backupInProgress = true
        let defaults = KeyboardSettings.appDefaults
        Self.backupQueue.async {
            let result = Result { () throws -> Int in
                try backup.apply(to: defaults)
                guard defaults.synchronize() else {
                    throw PersonalDataError("設定を保存できません。変更を確認できていません")
                }
                return backup.importedSettingCount
            }
            DispatchQueue.main.async {
                self.backupInProgress = false
                completion(result)
            }
        }
    }
    func put(_ word: PersonalWord, index: Int?, original: PersonalWord?, template: Bool) throws {
        var next = lexicon
        var entries = template ? next.templates : next.words
        if let index {
            guard entries.indices.contains(index), entries[index] == original else { throw PersonalDataError("編集対象が見つかりません") }
            entries[index] = word
        } else { entries.append(word) }
        if template { next.templates = entries } else { next.words = entries }
        try apply(next)
    }
    func remove(_ indices: IndexSet, template: Bool) throws {
        var next = lexicon
        if template { next.templates.remove(atOffsets: indices) }
        else { next.words.remove(atOffsets: indices) }
        try apply(next)
    }
    func importEntries(_ entries: [PersonalWord], template: Bool) throws {
        var next = lexicon
        var group = template ? next.templates : next.words
        func key(_ word: PersonalWord) -> String { "\(word.reading.utf8.count):" + word.reading + word.word }
        var positions = Dictionary(uniqueKeysWithValues: group.enumerated().map { (key($0.element), $0.offset) })
        for entry in entries {
            if let index = positions[key(entry)] { group[index] = entry }
            else { positions[key(entry)] = group.count; group.append(entry) }
        }
        if template { next.templates = group } else { next.words = group }
        try apply(next)
    }
}
