import XCTest
import UIKit
@testable import SumireCore
@testable import Sumire

@MainActor final class SurfaceEnglishMetadataTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func property(_ value: Any, _ name: String) -> Any? {
        var mirror: Mirror? = Mirror(reflecting: value)
        while let current = mirror {
            if let child = current.children.first(where: { $0.label == name }) { return child.value }
            mirror = current.superclassMirror
        }
        return nil
    }
    private func session(_ surface: Sumire.KeyboardSurface) -> BunsetsuConversionSession? {
        guard let raw = property(surface, "bunsetsuSession") else { return nil }
        if let session = raw as? BunsetsuConversionSession { return session }
        return Mirror(reflecting: raw).children.first?.value as? BunsetsuConversionSession
    }
    private func ready(_ surface: Sumire.KeyboardSurface, focused: Bool = false) {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard !surface.candidateBar.isUpdating, surface.candidateBar.candidates.contains("can") else { return false }
            return !focused || self.session(surface)?.segments.first?.candidatesLoaded == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 30), .completed,
            "Expected actual focused can: \(surface.candidateBar.candidates.prefix(12))")
    }
    private func fence(_ surface: Sumire.KeyboardSurface) {
        let done = expectation(description: "actual Surface learning fence")
        surface.synchronizeLearning { done.fulfill() }; wait(for: [done], timeout: 10)
    }
    func testActualSurfaceFocusedEnglishSelectionPersistsUnknownEndpoints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("learning.sqlite")
        try LearningStore(url: database).record(reading: "かな", text: "旧nil")
        let original = try XCTUnwrap(try LearningStore(url: database).snapshot().first)
        XCTAssertNil(original.leftID); XCTAssertNil(original.rightID)
        let domain = "surface-english-metadata-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let surface = Sumire.KeyboardSurface()
        surface.configureAppearancePreview(.sumire, defaults: defaults)
        surface.bunsetsuSeparation = true; surface.liveConversion = false
        surface.learnFirstCandidate = true
        surface.configureLearning(url: database)
        defer { surface.invalidateComposition(); surface.configureLearning(url: nil); fence(surface) }
        var commits: [String] = []
        surface.commitMarkedText = { commits.append($0) }
        surface.updateMarkedText = { _ in }; surface.updateMarkedSelection = { _, _ in }
        // Obtain an owned snapshot before learning can legitimately add an
        // overlay path with native fallback IDs. No composition is active.
        let converter = try XCTUnwrap(property(surface, "converter") as? Sumire.ConversionService)
        let done = expectation(description: "normal-12 owned snapshot")
        var response: Result<Sumire.ConversionResponse, Error>?
        converter.convert("ca", generation: 9_000, editStart: 0, includeBunsetsu: true) { response = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        let result = try XCTUnwrap(response).get()
        let candidate = try XCTUnwrap(result.candidates.first { $0.text == "can" && $0.dictionaries.contains("english") })
        let owned = try XCTUnwrap(result.bunsetsuSnapshot?.candidates.first { $0.candidateID == candidate.id })

        XCTAssertNil(owned.tokenPath)
        let input = try XCTUnwrap(descendants(surface).first { $0.accessibilityIdentifier == "sumire-ka" } as? Sumire.MultiStageFlickKey)
        try XCTUnwrap(input.onCommit)(.init(output: .text("ca"), isTap: false, wasFlick: true,
            isLongPress: false, direction: .up, secondDirection: nil, circularSlot: nil))
        ready(surface)
        let space = try XCTUnwrap(descendants(surface).first { $0.accessibilityIdentifier == "sumire-space_convert_key" } as? Sumire.DirectionalActionKey)
        try XCTUnwrap(space.action)(.tap)
        ready(surface, focused: true)
        let active = try XCTUnwrap(session(surface))
        XCTAssertEqual(active.segments.first?.reading, "ca")
        let actual = try XCTUnwrap(active.segments.first?.candidateRecords.first { $0.text == "can" })
        XCTAssertNil(actual.leftID); XCTAssertNil(actual.rightID)
        let index = try XCTUnwrap(surface.candidateBar.candidates.firstIndex(of: "can"))
        surface.candidateBar.onSelect?(index); fence(surface)
        XCTAssertEqual(commits, ["can"]); XCTAssertFalse(surface.hasComposition)
        let rows = try LearningStore(url: database).snapshot()
        let saved = try XCTUnwrap(rows.first { $0.reading == "ca" && $0.text == "can" })
        XCTAssertNil(saved.leftID); XCTAssertNil(saved.rightID)
        XCTAssertEqual(rows.first { $0.reading == original.reading && $0.text == original.text }, original)
        XCTAssertEqual(owned.identity.surface, "can"); XCTAssertNil(owned.tokenPath)
    }
    func testActualSurfaceEnglishPrefixRetainsRemainderAndRejectsStaleAlternatives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("learning.sqlite")
        let domain = "surface-english-prefix-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let surface = Sumire.KeyboardSurface()
        surface.configureAppearancePreview(.sumire, defaults: defaults)
        surface.bunsetsuSeparation = true; surface.liveConversion = false
        surface.learnFirstCandidate = true; surface.configureLearning(url: database)
        defer { surface.invalidateComposition(); surface.configureLearning(url: nil); fence(surface) }
        var commits: [String] = [], marked = ""
        surface.commitMarkedText = { commits.append($0) }
        surface.updateMarkedText = { marked = $0 }; surface.updateMarkedSelection = { text, _ in marked = text }
        let input = try XCTUnwrap(descendants(surface).first { $0.accessibilityIdentifier == "sumire-ka" } as? Sumire.MultiStageFlickKey)
        let space = try XCTUnwrap(descendants(surface).first { $0.accessibilityIdentifier == "sumire-space_convert_key" } as? Sumire.DirectionalActionKey)
        func enter(_ text: String) throws {
            try XCTUnwrap(input.onCommit)(.init(output: .text(text), isTap: false, wasFlick: true,
                isLongPress: false, direction: .up, secondDirection: nil, circularSlot: nil))
        }
        try enter("caあ"); try XCTUnwrap(space.action)(.tap); ready(surface, focused: true)
        let active = try XCTUnwrap(session(surface))
        XCTAssertEqual(active.segments.map(\.reading), ["ca", "あ"])
        let record = try XCTUnwrap(active.segments.first?.candidateRecords.first { $0.text == "can" })
        XCTAssertNil(record.leftID); XCTAssertNil(record.rightID)
        surface.candidateBar.onSelect?(try XCTUnwrap(surface.candidateBar.candidates.firstIndex(of: "can")))
        fence(surface)
        XCTAssertEqual(commits, ["can"]); XCTAssertTrue(surface.hasComposition); XCTAssertEqual(marked, "あ")
        let readyTail = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !surface.candidateBar.isUpdating && surface.candidateBar.candidates.first == "あ"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [readyTail], timeout: 30), .completed)
        surface.candidateBar.onSelect?(0); fence(surface)
        XCTAssertEqual(commits, ["can", "あ"]); XCTAssertFalse(surface.hasComposition)
        let saved = try LearningStore(url: database).snapshot()
        let fragment = try XCTUnwrap(saved.first { $0.reading == "ca" && $0.text == "can" })
        XCTAssertNil(fragment.leftID); XCTAssertNil(fragment.rightID)
        XCTAssertTrue(saved.contains { $0.reading == "caあ" && $0.text == "canあ" && $0.isPhrase })
        // Invalidate while the real native session request is queued. A new
        // reading fences that request; no old English alternatives may return.
        try enter("ca"); try XCTUnwrap(space.action)(.tap); surface.invalidateComposition()
        try enter("あ")
        let fresh = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !surface.candidateBar.isUpdating && surface.candidateBar.candidates.first == "あ"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [fresh], timeout: 30), .completed)
        XCTAssertNil(session(surface)); XCTAssertFalse(surface.candidateBar.candidates.contains("can"))
        surface.invalidateComposition(); fence(surface)
        XCTAssertEqual(try LearningStore(url: database).snapshot(), saved)
    }

}
