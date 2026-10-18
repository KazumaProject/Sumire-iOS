import UIKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import SumireCore

/// All database and image work is serialized off the UI queue. Clipboard reads require the host's permission gate.
final class ClipboardHistoryController {
    var onInsertText: ((String) -> Void)?
    var onHistoryEnabledChanged: ((Bool) -> Void)?
    var onNotice: ((String) -> Void)?
    private let queue = DispatchQueue(label: "sumire.clipboard.history", qos: .userInitiated)
    private var defaults: UserDefaults = .standard
    private var url: URL?
    private var allowed = false
    private weak var panel: SymbolKeyboardView?
    private var generation = UUID()
    private var current: ClipboardHistoryStore.Content?
    private var currentThumbnail: UIImage?
    private var thumbnails = NSCache<NSString, UIImage>()
    private var pendingThumbnails = Set<String>()
    // Accessed only on queue.
    private var store: ClipboardHistoryStore?
    private var storeURL: URL?
    private var lastSavedDigest: String?
    private var lastSavedID: Int64?

    init() { thumbnails.totalCostLimit = 512 * 1024; thumbnails.countLimit = 5 }
    func configure(defaults: UserDefaults, url: URL, allowed: Bool) {
        let changed = self.url != url || self.allowed != allowed || self.defaults !== defaults
        self.defaults = defaults; self.url = url; self.allowed = allowed
        if changed {
            generation = UUID(); current = nil; currentThumbnail = nil; thumbnails.removeAllObjects(); pendingThumbnails.removeAll()
            panel?.clipboardAccessAllowed = allowed
            reload()
        }
    }
    func attach(_ panel: SymbolKeyboardView) {
        self.panel = panel; panel.clipboardAccessAllowed = allowed
        panel.clipboardHistoryEnabled = ClipboardHistorySettings.isEnabled(defaults: defaults)
        panel.onClipboardRequested = { [weak self] in self?.reload() }
        panel.onClipboardProviders = { [weak self] in self?.receiveProviders($0) }
        panel.onClipboardThumbnailRequested = { [weak self] in self?.loadThumbnail(id: $0) }
        panel.onClipboardPaste = { [weak self] in self?.paste(id: $0) }
        panel.onClipboardPin = { [weak self] id, pinned in self?.mutate { try $0.setPinned(id: Int64(id) ?? -1, pinned: pinned) } }
        panel.onClipboardDelete = { [weak self] id in
            guard let self else { return }
            if id == "current" { self.current = nil; self.currentThumbnail = nil; self.reload() }
            else { self.mutate { try $0.delete(id: Int64(id) ?? -1) } }
        }
        panel.onClipboardHistoryChanged = { [weak self, weak panel] enabled in
            guard let self else { return }
            ClipboardHistorySettings.setEnabled(enabled, defaults: self.defaults)
            panel?.clipboardHistoryEnabled = enabled
            self.onHistoryEnabledChanged?(enabled)
        }
        reload()
    }
    func detach() { panel = nil; purgeThumbnails() }
    func purgeThumbnails() { generation = UUID(); pendingThumbnails.removeAll(); thumbnails.removeAllObjects(); currentThumbnail = nil; current = nil }

    /// Called only after CandidateBar's existing explicit/opt-in permission path has accepted the content.
    func capture(text: String?, image: Data?) {
        guard allowed else { return }
        if let text { accept(.text(text)) }
        else if let image { accept(.image(image)) }
    }
    private func receiveProviders(_ providers: [NSItemProvider]) {
        guard allowed, let provider = providers.first else { onNotice?("クリップボードの読み込みにはフルアクセスが必要です"); return }
        let token = generation
        let image = provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        let type = image ? UTType.image.identifier : UTType.utf8PlainText.identifier
        provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] file, _ in
            guard let self else { return }
            do {
                guard let file, file.isFileURL else { throw PersonalDataError("クリップボードの内容を読み込めません") }
                let limit = image ? ClipboardHistoryStore.Limits.maximumImageBytes : ClipboardHistoryStore.Limits.maximumTextBytes
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                let data = try handle.read(upToCount: limit + 1) ?? Data()
                guard data.count <= limit else { throw PersonalDataError(image ? "履歴に読み込める画像は4MiB以下です" : "履歴に読み込める文字列は64KiB以下です") }
                let content: ClipboardHistoryStore.Content
                if image { content = .image(data) }
                else {
                    guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { throw PersonalDataError("文字列の形式が未対応です") }
                    content = .text(text)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.allowed, self.generation == token else { return }
                    self.accept(content)
                }
            } catch { self.notice(error.localizedDescription, token: token) }
        }
    }
    private func accept(_ content: ClipboardHistoryStore.Content) {
        guard allowed, let url else { return }
        let token = generation, settings = defaults
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let bytes: Data
                switch content {
                case .text(let text):
                    guard !text.isEmpty, text.utf8.count <= ClipboardHistoryStore.Limits.maximumTextBytes else { throw PersonalDataError("履歴の文字列は64KiB以下です") }
                    bytes = Data(text.utf8)
                case .image(let data):
                    try ClipboardHistoryStore.validateImageData(data); bytes = data
                }
                let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                let saved = ClipboardHistorySettings.isEnabled(defaults: settings)
                if saved {
                    let store = try self.open(url)
                    let stillStored = try store.items().contains { $0.id == self.lastSavedID }
                    if self.lastSavedDigest != fingerprint || !stillStored {
                        switch content {
                        case .text(let text): self.lastSavedID = try store.recordText(text, historyEnabled: true)
                        case .image(let data): self.lastSavedID = try store.recordImage(data, historyEnabled: true)
                        }
                        self.lastSavedDigest = fingerprint
                    }
                }
                let thumbnail: UIImage?
                if case .image(let data) = content { thumbnail = Self.thumbnail(data) } else { thumbnail = nil }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.allowed, self.generation == token else { return }
                    self.current = saved ? nil : content; self.currentThumbnail = thumbnail
                    self.reload()
                }
            } catch { self.notice(error.localizedDescription, token: token) }
        }
    }
    func reload() {
        guard panel != nil, let url else { return }
        let token = generation, settings = defaults
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let store = try self.open(url)
                if settings.bool(forKey: "clipboard.expirationEnabled") {
                    let hours = settings.object(forKey: "clipboard.retentionHours") == nil ? 1 : min(72, max(1, settings.integer(forKey: "clipboard.retentionHours")))
                    try store.deleteExpiredUnpinned(retentionHours: hours)
                }
                let entries = try store.items()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    var items = entries.map { item in
                        SymbolClipboardItem(id: String(item.id), text: item.preview, image: nil, pinned: item.pinned, isImage: item.kind == .image)
                    }
                    if let current = self.current {
                        switch current {
                        case .text(let text): items.insert(.init(id: "current", text: String(text.prefix(150)), image: nil, pinned: false), at: 0)
                        case .image: items.insert(.init(id: "current", text: "現在の画像（未保存）", image: self.currentThumbnail, pinned: false, isImage: true), at: 0)
                        }
                    }
                    self.panel?.setClipboardItems(items)
                }
            } catch { self.notice(error.localizedDescription, token: token) }
        }
    }
    private func loadThumbnail(id: String) {
        guard id != "current", panel?.isClipboardItemVisible(id: id) == true else { return }
        if let image = thumbnails.object(forKey: id as NSString) { panel?.setClipboardThumbnail(id: id, image: image); return }
        guard let row = Int64(id), !pendingThumbnails.contains(id), let url else { return }
        pendingThumbnails.insert(id)
        let token = generation
        queue.async { [weak self] in
            guard let self else { return }
            let content = try? self.open(url).content(id: row)
            let image: UIImage?
            if case .image(let bytes) = content { image = Self.thumbnail(bytes) } else { image = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.pendingThumbnails.remove(id)
                if let image {
                    self.thumbnails.setObject(image, forKey: id as NSString, cost: 160 * 160 * 4)
                    self.panel?.setClipboardThumbnail(id: id, image: image)
                }
            }
        }
    }
    private func paste(id: String) {
        guard allowed else { onNotice?("クリップボードの操作にはフルアクセスが必要です"); return }
        if id == "current", let current { deliver(current); return }
        guard let row = Int64(id), let url else { return }
        let token = generation
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let content = try self.open(url).content(id: row)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.allowed, self.generation == token, let content else { return }
                    self.deliver(content)
                }
            } catch { self.notice(error.localizedDescription, token: token) }
        }
    }
    private func deliver(_ content: ClipboardHistoryStore.Content) {
        switch content {
        case .text(let text): onInsertText?(text)
        case .image(let data):
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), let type = CGImageSourceGetType(source) as String? else { return }
            UIPasteboard.general.setItems([[type: data]], options: [.localOnly: true])
            onNotice?("画像をコピーしました。入力先の貼り付けメニューから挿入してください")
        }
    }
    private func mutate(_ operation: @escaping (ClipboardHistoryStore) throws -> Void) {
        guard let url else { return }
        let token = generation
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try operation(self.open(url)); self.lastSavedDigest = nil
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.thumbnails.removeAllObjects(); self.reload()
                }
            } catch { self.notice(error.localizedDescription, token: token) }
        }
    }
    private func open(_ url: URL) throws -> ClipboardHistoryStore {
        if storeURL != url { store = nil; storeURL = nil; lastSavedDigest = nil }
        if let store { return store }
        let opened = try ClipboardHistoryStore(url: url); store = opened; storeURL = url
        return opened
    }
    private static func thumbnail(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 160, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    private func notice(_ text: String, token: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }; self.onNotice?(text)
        }
    }
}
