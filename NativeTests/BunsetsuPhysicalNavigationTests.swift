import XCTest
import UIKit
import SumireCore
@testable import Sumire

@MainActor final class BunsetsuPhysicalNavigationTests: XCTestCase {
    private let reading = "わたしはとうきょうにいきます"
    private var surfaces: [Sumire.KeyboardSurface] = []
    private var suites: [String] = []
    private var directories: [URL] = []
    override func tearDown() {
        for surface in surfaces { surface.invalidateComposition(); surface.configureLearning(url: nil); fence(surface) }
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func key(_ id: String, _ surface: Sumire.KeyboardSurface) throws -> UIButton {
        try XCTUnwrap(descendants(surface).first { $0.accessibilityIdentifier == id } as? UIButton)
    }
    private func enter(_ text: String, _ surface: Sumire.KeyboardSurface) throws {
        for character in text {
            let pair = try XCTUnwrap(descendants(surface).compactMap { $0 as? Sumire.FlickKey }.compactMap { key -> (Sumire.FlickKey, Int)? in
                guard let index = key.directionalValues?.firstIndex(of: String(character)) else { return nil }
                return (key, index)
            }.first)
            pair.0.onFlick?(try XCTUnwrap(FlickDirection(rawValue: pair.1)))
        }
    }
    private func makeSurface() throws -> Sumire.KeyboardSurface {
        let suite = "bunsetsu-physical-" + UUID().uuidString
        suites.append(suite)
        let surface = Sumire.KeyboardSurface()
        surface.configureAppearancePreview(.gojuon, defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        surface.bunsetsuSeparation = true
        surfaces.append(surface)
        return surface
    }
    private func session(_ surface: Sumire.KeyboardSurface) -> BunsetsuConversionSession? {
        Mirror(reflecting: surface).children.first { $0.label == "bunsetsuSession" }?.value as? BunsetsuConversionSession
    }
    private func ready(_ surface: Sumire.KeyboardSurface, segmented: Bool = true) {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if segmented {
                guard let session = self.session(surface) else { return false }
                return session.focusedSegment.map { $0.candidatesLoaded && !$0.isLoadingCandidates } == true
                    && !surface.candidateBar.isUpdating
            }
            return !surface.candidateBar.isUpdating && !surface.candidateBar.candidates.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 30), .completed)
    }
    private func start(_ surface: Sumire.KeyboardSurface) throws {
        try enter(reading, surface)
        try key("gojuon-space", surface).sendActions(for: .touchUpInside)
        ready(surface)
    }
    private func fence(_ surface: Sumire.KeyboardSurface) {
        let done = expectation(description: "Service queue fence")
        surface.synchronizeLearning { done.fulfill() }
        wait(for: [done], timeout: 10)
    }
    func testActualBunsetsuContextAndFourPhysicalNavigationActions() throws {
        let surface = try makeSurface()
        var hostMoves = 0
        surface.moveCursorLeft = { hostMoves += 1 }
        surface.moveCursorRight = { hostMoves += 1 }
        try start(surface)
        let initial = try XCTUnwrap(session(surface))
        XCTAssertGreaterThan(initial.segments.count, 1)
        XCTAssertGreaterThan(initial.splitPatterns.count, 1)
        XCTAssertEqual(initial.focusedSegmentIndex, 0)
        XCTAssertEqual(surface.physicalKeyboardShortcutContext, .bunsetsuConversion)
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.segmentFocusRight))
        ready(surface)
        XCTAssertEqual(session(surface)?.focusedSegmentIndex, 1)
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.segmentFocusLeft))
        ready(surface)
        XCTAssertEqual(session(surface)?.focusedSegmentIndex, 0)
        // Android consumes an active-session focus key even at its clamped edge.
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.segmentFocusLeft))
        XCTAssertEqual(session(surface)?.focusedSegmentIndex, 0)
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.segmentWidthShrink))
        ready(surface)
        XCTAssertEqual(session(surface)?.activeSplitPatternIndex,
                       (initial.activeSplitPatternIndex + initial.splitPatterns.count - 1) % initial.splitPatterns.count)
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.segmentWidthExpand))
        ready(surface)
        let final = try XCTUnwrap(session(surface))
        XCTAssertEqual(final.activeSplitPatternIndex, initial.activeSplitPatternIndex)
        XCTAssertEqual(final.sessionID, initial.sessionID)
        XCTAssertEqual(final.generation, initial.generation)
        XCTAssertEqual(final.rawInput, reading)
        XCTAssertEqual(final.conversionInput, reading)
        XCTAssertEqual(hostMoves, 0)
    }
    func testInactiveInvalidatedAndSettingsCancelledNavigationCannotMoveHostCaretOrReviveSession() throws {
        let actions: [PhysicalKeyboardShortcutAction] = [.segmentFocusLeft, .segmentFocusRight, .segmentWidthShrink, .segmentWidthExpand]
        let surface = try makeSurface()
        var hostMoves = 0, commits = 0
        surface.moveCursorLeft = { hostMoves += 1 }; surface.moveCursorRight = { hostMoves += 1 }
        surface.commitMarkedText = { _ in commits += 1 }
        for action in actions { XCTAssertFalse(surface.performPhysicalKeyboardShortcut(action)) }
        try enter(reading, surface)
        try key("gojuon-space", surface).sendActions(for: .touchUpInside)
        surface.invalidateComposition()
        for action in actions { XCTAssertFalse(surface.performPhysicalKeyboardShortcut(action)) }
        try enter("あ", surface); ready(surface, segmented: false)
        XCTAssertEqual(surface.physicalKeyboardShortcutContext, .composition)
        XCTAssertNil(session(surface))
        XCTAssertEqual(commits, 0); XCTAssertEqual(hostMoves, 0)
        surface.invalidateComposition()
        try start(surface)
        var marked = ""
        surface.updateMarkedText = { marked = $0 }
        surface.updateMarkedSelection = { text, _ in marked = text }
        surface.configureTextMacroCandidates(enabled: false)
        ready(surface, segmented: false)
        XCTAssertNil(session(surface)); XCTAssertEqual(marked, reading)
        for action in actions { XCTAssertFalse(surface.performPhysicalKeyboardShortcut(action)) }
        XCTAssertEqual(hostMoves, 0)
        surface.invalidateComposition()
        try start(surface)
        surface.beforeInput = { surface.invalidateComposition() }
        XCTAssertFalse(surface.performPhysicalKeyboardShortcut(.segmentFocusRight))
        surface.beforeInput = nil
        XCTAssertFalse(surface.hasComposition)
        XCTAssertNil(session(surface)); XCTAssertEqual(hostMoves, 0)
    }

    func testPhysicalFocusAndSplitThenCandidateTapPreservesPartialLearningOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let url = directory.appendingPathComponent("learning.sqlite")
        let surface = try makeSurface()
        surface.learnFirstCandidate = true
        surface.configureLearning(url: url)
        var marked = "", commits: [String] = []
        surface.updateMarkedText = { marked = $0 }
        surface.updateMarkedSelection = { text, _ in marked = text }
        surface.commitMarkedText = { commits.append($0) }
        try start(surface)
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.segmentWidthExpand)); ready(surface)
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.segmentWidthShrink)); ready(surface)
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.segmentFocusRight)); ready(surface)
        surface.candidateBar.onSelect?(0); fence(surface)
        XCTAssertEqual(commits, ["私は東京に"])
        XCTAssertTrue(surface.hasComposition); XCTAssertEqual(marked, "いきます")
        XCTAssertTrue(try LearningStore(url: url).snapshot().isEmpty)
        ready(surface, segmented: false)
        surface.candidateBar.onSelect?(0); fence(surface)
        XCTAssertFalse(surface.hasComposition)
        let rows = try LearningStore(url: url).snapshot()
        XCTAssertEqual(rows.filter { $0.reading == reading && $0.isPhrase && $0.text == commits.joined() }.count, 1)
        for fragment in ["わたしは", "とうきょうに", "いきます"] {
            XCTAssertTrue(rows.contains { $0.reading == fragment })
        }
        XCTAssertTrue(rows.allSatisfy { $0.usageCount == 1 && $0.count == 1 })
    }

    func testPhysicalNextPreviousCyclesActualFocusedBunsetsuCandidates() throws {
        let surface = try makeSurface()
        var marked = ""
        surface.updateMarkedText = { marked = $0 }
        surface.updateMarkedSelection = { text, _ in marked = text }
        try start(surface)
        let initial = try XCTUnwrap(session(surface))
        let segment = try XCTUnwrap(initial.focusedSegment)
        XCTAssertGreaterThanOrEqual(segment.candidates.count, 2)
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertNext))
        let next = try XCTUnwrap(session(surface))
        XCTAssertEqual(next.focusedSegment?.selectedIndex, (segment.selectedIndex + 1) % segment.candidates.count)
        XCTAssertEqual(marked, next.displayText)
        XCTAssertNotEqual(next.displayText, initial.displayText)
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertPrevious))
        XCTAssertEqual(session(surface)?.focusedSegment?.selectedIndex, segment.selectedIndex)
        XCTAssertEqual(marked, initial.displayText)
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertPrevious))
        XCTAssertEqual(session(surface)?.focusedSegment?.selectedIndex,
                       (segment.selectedIndex + segment.candidates.count - 1) % segment.candidates.count)
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertNext))
        XCTAssertEqual(session(surface)?.focusedSegment?.selectedIndex, segment.selectedIndex)
    }

    func testPendingFocusedChoicesAreConsumedAndInvalidatedOwnerDoesNotFallBack() throws {
        let surface = try makeSurface()
        var marked = "", hostMoves = 0
        surface.updateMarkedText = { marked = $0 }
        surface.updateMarkedSelection = { text, _ in marked = text }
        surface.moveCursorLeft = { hostMoves += 1 }; surface.moveCursorRight = { hostMoves += 1 }
        try start(surface)
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.segmentFocusRight))
        let pending = try XCTUnwrap(session(surface))
        XCTAssertTrue(pending.focusedSegment?.isLoadingCandidates == true)
        XCTAssertEqual(pending.focusedSegment?.candidates.count, 1, "Projected fallback is the only pending choice")
        let preview = marked
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertNext))
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertPrevious))
        XCTAssertEqual(marked, preview)
        ready(surface)
        XCTAssertEqual(session(surface)?.focusedSegment?.selectedIndex, 0,
                       "Queued Next then Previous must both be applied after loading")
        XCTAssertEqual(session(surface)?.sessionID, pending.sessionID)
        XCTAssertEqual(session(surface)?.rawInput, reading)
        surface.beforeInput = { surface.invalidateComposition() }
        XCTAssertFalse(surface.performPhysicalKeyboardShortcut(.convertNext))
        surface.beforeInput = nil
        XCTAssertFalse(surface.hasComposition)
        XCTAssertEqual(hostMoves, 0)
        fence(surface)
        XCTAssertEqual(surface.physicalKeyboardShortcutContext, .any)
    }

    private func temporaryLearningURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory.appendingPathComponent("learning.sqlite")
    }

    func testPhysicalBunsetsuCommitSavesWholeDisplayAndLearningOnce() throws {
        let url = try temporaryLearningURL(), surface = try makeSurface()
        surface.configureLearning(url: url); surface.learnFirstCandidate = true
        var commits: [String] = []
        surface.commitMarkedText = { commits.append($0) }
        try start(surface)
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertNext))
        let current = try XCTUnwrap(session(surface))
        XCTAssertEqual(current.tailText, "", "Production starts this route only at reading end")
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.commit)); fence(surface)
        XCTAssertEqual(commits, [current.displayText])
        XCTAssertFalse(surface.hasComposition)
        let rows = try LearningStore(url: url).snapshot()
        XCTAssertEqual(rows.filter { $0.reading == reading && $0.text == current.displayText && $0.isPhrase }.count, 1)
        XCTAssertTrue(rows.allSatisfy { $0.usageCount == 1 && $0.count == 1 })
        XCTAssertFalse(surface.performPhysicalKeyboardShortcut(.commit)); fence(surface)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(try LearningStore(url: url).snapshot(), rows)
    }

    func testPhysicalBunsetsuCancelKeepsRawReadingAndDoesNotLearnOrRevivePendingResult() throws {
        let url = try temporaryLearningURL(), surface = try makeSurface()
        surface.configureLearning(url: url); surface.learnFirstCandidate = true
        var marked = "", commits: [String] = []
        surface.updateMarkedText = { marked = $0 }
        surface.updateMarkedSelection = { text, _ in marked = text }
        surface.commitMarkedText = { commits.append($0) }
        try start(surface)
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.segmentFocusRight))
        XCTAssertTrue(session(surface)?.focusedSegment?.isLoadingCandidates == true)
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.cancel)); fence(surface)
        XCTAssertEqual(marked, reading)
        XCTAssertTrue(surface.hasComposition)
        XCTAssertEqual(surface.physicalKeyboardShortcutContext, .composition)
        XCTAssertTrue(surface.candidateBar.candidates.isEmpty)
        XCTAssertTrue(try LearningStore(url: url).snapshot().isEmpty)
        try enter("あ", surface); ready(surface, segmented: false)
        XCTAssertEqual(marked, reading + "あ")
        XCTAssertEqual(surface.physicalKeyboardShortcutContext, .composition)
        XCTAssertTrue(commits.isEmpty)
        XCTAssertTrue(try LearningStore(url: url).snapshot().isEmpty)
    }

    func testOnePendingPhysicalNextIsAppliedAfterFocusedCandidateLoad() throws {
        let surface = try makeSurface()
        var marked = ""
        surface.updateMarkedText = { marked = $0 }
        surface.updateMarkedSelection = { text, _ in marked = text }
        try start(surface)
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.segmentFocusRight))
        let pending = try XCTUnwrap(session(surface))
        XCTAssertTrue(pending.focusedSegment?.isLoadingCandidates == true)
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertNext))
        ready(surface)
        let loaded = try XCTUnwrap(session(surface))
        let segment = try XCTUnwrap(loaded.focusedSegment)
        XCTAssertGreaterThanOrEqual(segment.candidates.count, 2)
        XCTAssertEqual(segment.selectedIndex, 1, "The single Next must be applied after loading, not merely consumed")
        XCTAssertEqual(marked, loaded.displayText)
        XCTAssertEqual(loaded.sessionID, pending.sessionID)
    }

    func testMultiplePendingPhysicalCandidateDirectionsApplyInArrivalOrder() throws {
        let surface = try makeSurface()
        var observations: [String] = []
        surface.updateMarkedText = { observations.append($0) }
        try start(surface)
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.segmentFocusRight))
        XCTAssertTrue(session(surface)?.focusedSegment?.isLoadingCandidates == true)
        observations = []
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertNext))
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertNext))
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertPrevious))
        ready(surface)
        let loaded = try XCTUnwrap(session(surface)), focused = try XCTUnwrap(loaded.focusedSegment)
        XCTAssertGreaterThanOrEqual(focused.candidates.count, 2)
        XCTAssertEqual(focused.selectedIndex, 1)
        let expected = [1, 2 % focused.candidates.count, 1].map { index in
            loaded.segments.enumerated().map { offset, segment in
                offset == loaded.focusedSegmentIndex ? focused.candidates[index] : segment.displayText
            }.joined()
        }
        let distinct = observations.reduce(into: [String]()) { result, text in
            if result.last != text { result.append(text) }
        }
        XCTAssertEqual(Array(distinct.suffix(3)), expected)
    }

    func testPendingDirectionsCannotLeakAcrossCancelSettingsFocusPatternOrOwner() throws {
        for boundary in ["cancel", "settings", "focus", "pattern", "owner"] {
            let url = try temporaryLearningURL(), surface = try makeSurface()
            surface.configureLearning(url: url); surface.learnFirstCandidate = true
            var marked = "", commits: [String] = []
            surface.updateMarkedText = { marked = $0 }
            surface.updateMarkedSelection = { text, _ in marked = text }
            surface.commitMarkedText = { commits.append($0) }
            try start(surface)
            let initial = try XCTUnwrap(session(surface))
            XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.segmentFocusRight))
            XCTAssertTrue(session(surface)?.focusedSegment?.isLoadingCandidates == true)
            XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertNext))
            switch boundary {
            case "cancel":
                XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.cancel)); fence(surface)
                XCTAssertEqual(marked, reading)
                XCTAssertEqual(surface.physicalKeyboardShortcutContext, .composition)
            case "settings":
                surface.configureTextMacroCandidates(enabled: false)
                ready(surface, segmented: false)
                XCTAssertEqual(marked, reading)
                XCTAssertEqual(surface.physicalKeyboardShortcutContext, .composition)
            case "focus":
                XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.segmentFocusLeft)); ready(surface)
                XCTAssertEqual(session(surface)?.focusedSegment?.selectedIndex, initial.focusedSegment?.selectedIndex)
                XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.segmentFocusRight)); ready(surface)
                XCTAssertEqual(session(surface)?.focusedSegment?.selectedIndex, 0)
            case "pattern":
                XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.segmentWidthExpand)); ready(surface)
                XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.segmentWidthShrink)); ready(surface)
                XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.segmentFocusRight)); ready(surface)
                XCTAssertEqual(session(surface)?.focusedSegment?.selectedIndex, 0)
            default:
                surface.beforeInput = { surface.invalidateComposition() }
                fence(surface)
                surface.beforeInput = nil
                XCTAssertFalse(surface.hasComposition)
                XCTAssertEqual(surface.physicalKeyboardShortcutContext, .any)
            }
            fence(surface)
            XCTAssertTrue(commits.isEmpty, boundary)
            XCTAssertTrue(try LearningStore(url: url).snapshot().isEmpty, boundary)
            surface.beforeInput = nil
            surface.invalidateComposition()
            try enter("あ", surface); ready(surface, segmented: false)
            XCTAssertEqual(marked, "あ")
            XCTAssertEqual(surface.physicalKeyboardShortcutContext, .composition)
            XCTAssertTrue(try LearningStore(url: url).snapshot().isEmpty, boundary)
        }
    }

}
