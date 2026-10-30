import XCTest
import UIKit
@testable import SumireCore
@testable import Sumire

@MainActor final class SurfaceAuxiliaryMetadataTests: XCTestCase {
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
    private func fence(_ surface: Sumire.KeyboardSurface) {
        let done = expectation(description: "actual Surface learning fence")
        surface.synchronizeLearning { done.fulfill() }; wait(for: [done], timeout: 10)
    }
    func testActualFocusedAuxiliaryCandidatesReachFragmentsAndEligiblePhraseStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The canonical v1.7.277 raw token POS 11625 maps to 2641/2641 in
        // connection.sud for each exact row (independently checked offline).
        let fixtures = [("emoji", "えがお", "☺️", Int64(6_000)),
                        ("emoticon", "にこにこ", "(^^)", Int64(4_000)),
                        ("symbol", "ほし", "☆", Int64(4_000))]
        for (number, fixture) in fixtures.enumerated() {
            let (dictionary, reading, text, score) = fixture
            let database = root.appendingPathComponent("case-\(number).sqlite")
            try LearningStore(url: database).record(reading: "かな", text: "旧nil")
            let original = try XCTUnwrap(try LearningStore(url: database).snapshot().first)
            let domain = "surface-auxiliary-metadata-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            let surface = Sumire.KeyboardSurface()
            surface.configureAppearancePreview(.sumire, defaults: defaults)
            surface.bunsetsuSeparation = true; surface.liveConversion = false
            surface.learnFirstCandidate = true; surface.learnMixedSymbolsAndNumbers = true
            surface.configureLearning(url: database)
            defer { surface.invalidateComposition(); surface.configureLearning(url: nil); fence(surface) }
            let service = try XCTUnwrap(property(surface, "converter") as? Sumire.ConversionService)
            // Capture owned metadata before any learning can add a distinct
            // personal overlay row. This is the Surface's production Service.
            let got = expectation(description: "canonical normal12 auxiliary row")
            var probe: Result<Sumire.ConversionResponse, Error>?
            service.convert(reading, generation: 9_000, editStart: 0, includeBunsetsu: true) { probe = $0; got.fulfill() }
            wait(for: [got], timeout: 30)
            let response = try XCTUnwrap(probe).get()
            let provider = try XCTUnwrap(response.candidates.first { $0.text == text && $0.dictionaries.contains(dictionary) })
            XCTAssertEqual(provider.score, score); XCTAssertEqual(provider.range.length, reading.utf16.count)
            let owned = try XCTUnwrap(response.bunsetsuSnapshot?.candidates.first { $0.candidateID == provider.id })
            let rawFallback = try XCTUnwrap(response.bunsetsuSnapshot?.candidates.first { $0.identity.surface == reading && $0.tokenPath == nil })
            XCTAssertNil(rawFallback.leftID); XCTAssertNil(rawFallback.rightID)
            var commits: [String] = [], marked = ""
            surface.commitMarkedText = { commits.append($0) }
            surface.updateMarkedText = { marked = $0 }; surface.updateMarkedSelection = { value, _ in marked = value }
            let input = try XCTUnwrap(descendants(surface).first { $0.accessibilityIdentifier == "sumire-ka" } as? Sumire.MultiStageFlickKey)
            func enter(_ value: String) throws {
                try XCTUnwrap(input.onCommit)(.init(output: .text(value), isTap: false, wasFlick: true,
                    isLongPress: false, direction: .up, secondDirection: nil, circularSlot: nil))
            }
            let space = try XCTUnwrap(descendants(surface).first { $0.accessibilityIdentifier == "sumire-space_convert_key" } as? Sumire.DirectionalActionKey)
            try enter(reading + "あ"); try XCTUnwrap(space.action)(.tap)
            let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !surface.candidateBar.isUpdating && self.session(surface)?.segments.first?.candidatesLoaded == true &&
                    surface.candidateBar.candidates.contains(text)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 30), .completed, "Missing actual Surface \(dictionary): \(surface.candidateBar.candidates.prefix(30))")
            let active = try XCTUnwrap(session(surface))
            XCTAssertEqual(active.segments.map(\.reading), [reading, "あ"])
            let record = try XCTUnwrap(active.segments.first?.candidateRecords.first { $0.text == text })
            XCTAssertNotNil(record.reference.candidateID); XCTAssertNotNil(record.reference.conversionGeneration)
            XCTAssertEqual(record.score, score); XCTAssertEqual(record.leftID, 2641); XCTAssertEqual(record.rightID, 2641)
            surface.candidateBar.onSelect?(try XCTUnwrap(surface.candidateBar.candidates.firstIndex(of: text)))
            fence(surface)
            XCTAssertEqual(commits, [text]); XCTAssertTrue(surface.hasComposition); XCTAssertEqual(marked, "あ")
            let state = try XCTUnwrap(property(service, "state"))
            let pending = try XCTUnwrap(property(state, "learningSession") as? ConversionLearningSession)
            let fragments = try XCTUnwrap(property(pending, "fragments") as? [LearningFragment])
            XCTAssertEqual(fragments.count, 1)
            let fragment = try XCTUnwrap(fragments.first)
            XCTAssertEqual(fragment.reading, reading); XCTAssertEqual(fragment.output, record.text)
            XCTAssertEqual(fragment.candidateScore, Int32(score))
            // df1 IMEService recordBunsetsuLearning: only an override display
            // candidate is explicit; a normal local candidate remains false.
            XCTAssertFalse(fragment.explicitlySelected)
            XCTAssertEqual(fragment.leftID, 2641); XCTAssertEqual(fragment.rightID, 2641)
            let tailReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !surface.candidateBar.isUpdating && surface.candidateBar.candidates.first == "あ"
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [tailReady], timeout: 30), .completed)
            surface.candidateBar.onSelect?(0); fence(surface)
            XCTAssertEqual(commits, [text, "あ"]); XCTAssertFalse(surface.hasComposition)
            let saved = try LearningStore(url: database).snapshot()
            let phrase = try XCTUnwrap(saved.first { $0.reading == reading + "あ" && $0.text == text + "あ" && $0.isPhrase })
            XCTAssertEqual(phrase.leftID, 2641)
            XCTAssertFalse(LearningEligibilityPolicy.isEligible(input: reading, output: text, allowJapaneseWithSymbolsAndNumbers: true))
            XCTAssertFalse(saved.contains { $0.reading == reading && $0.text == text }, "Symbol-only rows remain excluded")
            XCTAssertEqual(saved.first { $0.reading == original.reading && $0.text == original.text }, original)
            XCTAssertEqual(owned.tokenPath?.first?.readingRange, NSRange(location: 0, length: reading.utf16.count))
            XCTAssertEqual(owned.leftID, 2641); XCTAssertEqual(owned.rightID, 2641)
            // A queued old bunsetsu result cannot revive a canceled composition.
            if number == fixtures.count - 1 {
                try enter(reading + "あ"); try XCTUnwrap(space.action)(.tap); surface.invalidateComposition()
                try enter("あ")
                let fresh = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    !surface.candidateBar.isUpdating && surface.candidateBar.candidates.first == "あ"
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [fresh], timeout: 30), .completed)
                XCTAssertNil(session(surface)); surface.invalidateComposition(); fence(surface)
                XCTAssertEqual(try LearningStore(url: database).snapshot(), saved)
            }
        }
    }
}
