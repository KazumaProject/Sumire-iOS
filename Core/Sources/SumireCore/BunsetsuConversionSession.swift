import Foundation

public enum BunsetsuConversionSessionError: Error, Equatable {
    case emptyConversionInput
    case rawInputDoesNotMatchConversionAndTail
    case noSplitPatterns
    case invalidPattern
}

/// Identifies a candidate returned by one exact conversion request. These are
/// request-scoped values only; they do not keep a service snapshot alive or
/// guarantee that a later commit call will still accept the reference.
/// Projected display text and Android's fallback candidate have no reference.
public enum BunsetsuSessionCandidateReference: Equatable {
    case displayOnly
    case conversionResult(generation: UInt64, candidateID: UInt64)
    case learnedPrediction(generation: UInt64, candidateID: UInt64, reading: String)
    case zenzLiveResult(generation: UInt64, candidateID: UInt64)

    public var conversionGeneration: UInt64? {
        switch self {
        case .displayOnly: return nil
        case let .conversionResult(generation, _),
             let .learnedPrediction(generation, _, _),
             let .zenzLiveResult(generation, _): return generation
        }
    }

    public var candidateID: UInt64? {
        switch self {
        case .displayOnly: return nil
        case let .conversionResult(_, candidateID),
             let .learnedPrediction(_, candidateID, _),
             let .zenzLiveResult(_, candidateID): return candidateID
        }
    }

    public var learnedPredictionReading: String? {
        guard case let .learnedPrediction(_, _, reading) = self else { return nil }
        return reading
    }

    fileprivate var isLocalConversionResult: Bool {
        switch self {
        case .conversionResult, .learnedPrediction: return true
        case .displayOnly, .zenzLiveResult: return false
        }
    }
}

/// Candidate and learning metadata copied from a conversion response.
/// `candidateIndex` is the final Android-compatible segment-list rank, including
/// a synthetic projected/fallback choice when one precedes local results.
public struct BunsetsuSessionCandidate: Equatable {
    public let text: String
    public let reference: BunsetsuSessionCandidateReference
    public let score: Int64
    public let candidateIndex: Int
    public let leftID: Int16?
    public let rightID: Int16?
    public let explicitlySelected: Bool
    /// Candidate text passed to the host when committed. It can differ from
    /// the label shown in the candidate bar.
    public let commitText: String
    /// Android Candidate.length measured in UTF-16 code units. A missing value
    /// means the bridge cannot safely use this row for Zenz duplicate removal.
    public let matchedReadingUTF16Length: Int?

    public init(
        text: String,
        reference: BunsetsuSessionCandidateReference = .displayOnly,
        score: Int64 = 3_000,
        candidateIndex: Int = 0,
        leftID: Int16? = nil,
        rightID: Int16? = nil,
        explicitlySelected: Bool = false,
        commitText: String? = nil,
        matchedReadingUTF16Length: Int? = nil
    ) {
        self.text = text
        self.reference = reference
        self.score = score
        self.candidateIndex = candidateIndex
        self.leftID = leftID
        self.rightID = rightID
        self.explicitlySelected = explicitlySelected
        self.commitText = commitText ?? text
        self.matchedReadingUTF16Length = matchedReadingUTF16Length
    }

    fileprivate func assigningCandidateIndex(
        _ index: Int,
        explicitlySelected: Bool? = nil
    ) -> BunsetsuSessionCandidate {
        BunsetsuSessionCandidate(
            text: text,
            reference: reference,
            score: score,
            candidateIndex: index,
            leftID: leftID,
            rightID: rightID,
            explicitlySelected: explicitlySelected ?? self.explicitlySelected,
            commitText: commitText,
            matchedReadingUTF16Length: matchedReadingUTF16Length
        )
    }
}

/// Semantic target used to reject a live Zenz result after the focused segment,
/// its reading, the conversion input, or its preceding display context changes.
public struct BunsetsuZenzSlotTarget: Equatable {
    public let conversionInput: String
    public let segmentIndex: Int
    public let segmentReading: String
    public let leftContext: String

    public init(conversionInput: String, segmentIndex: Int, segmentReading: String, leftContext: String) {
        self.conversionInput = conversionInput
        self.segmentIndex = segmentIndex
        self.segmentReading = segmentReading
        self.leftContext = leftContext
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.segmentIndex == rhs.segmentIndex &&
            bunsetsuStringsMatchUTF16(lhs.conversionInput, rhs.conversionInput) &&
            bunsetsuStringsMatchUTF16(lhs.segmentReading, rhs.segmentReading) &&
            bunsetsuStringsMatchUTF16(lhs.leftContext, rhs.leftContext)
    }
}

/// Request identity for one Zenz lookup. Unlike local candidate-load tokens,
/// this is validated against Android's semantic target rather than the entire
/// session revision, so unrelated later-segment loads do not stale the result.
public struct BunsetsuZenzSlotLoadToken: Equatable {
    public let sessionID: UUID
    public let sessionGeneration: UInt64
    public let requestID: UUID
    public let requestGeneration: UInt64
    public let target: BunsetsuZenzSlotTarget

    fileprivate init(
        sessionID: UUID,
        sessionGeneration: UInt64,
        requestGeneration: UInt64,
        target: BunsetsuZenzSlotTarget
    ) {
        self.sessionID = sessionID
        self.sessionGeneration = sessionGeneration
        self.requestID = UUID()
        self.requestGeneration = requestGeneration
        self.target = target
    }
}

public enum BunsetsuZenzLiveSlotState: Equatable {
    case loading(token: BunsetsuZenzSlotLoadToken)
    case result(token: BunsetsuZenzSlotLoadToken, candidate: BunsetsuSessionCandidate)

    fileprivate var token: BunsetsuZenzSlotLoadToken {
        switch self {
        case let .loading(token), let .result(token, _): return token
        }
    }
}

public enum BunsetsuCandidateBarItemContent: Equatable {
    case zenzLoading
    case zenzResult(BunsetsuSessionCandidate)
    case segmentCandidate(index: Int, candidate: BunsetsuSessionCandidate)

    public var text: String {
        switch self {
        case .zenzLoading: return "..."
        case let .zenzResult(candidate), let .segmentCandidate(_, candidate): return candidate.text
        }
    }
}

/// Candidate-bar rows preserve their source kind and the exact session view
/// that produced them. A row is actionable only while that view is current.
public struct BunsetsuCandidateBarItem: Equatable {
    public let content: BunsetsuCandidateBarItemContent
    fileprivate let sessionID: UUID
    fileprivate let sessionGeneration: UInt64
    fileprivate let sessionRevision: UInt64
    fileprivate let focusedSegmentIndex: Int
    fileprivate let zenzToken: BunsetsuZenzSlotLoadToken?

    fileprivate init(
        content: BunsetsuCandidateBarItemContent,
        sessionID: UUID,
        sessionGeneration: UInt64,
        sessionRevision: UInt64,
        focusedSegmentIndex: Int,
        zenzToken: BunsetsuZenzSlotLoadToken? = nil
    ) {
        self.content = content
        self.sessionID = sessionID
        self.sessionGeneration = sessionGeneration
        self.sessionRevision = sessionRevision
        self.focusedSegmentIndex = focusedSegmentIndex
        self.zenzToken = zenzToken
    }

    public var text: String { content.text }
}

public enum BunsetsuCandidateBarSelection: Equatable {
    case stale
    case loadingSlotConsumed
    case zenzResultSelected
    case segmentCandidateSelected(commitPlan: BunsetsuFocusedPrefixCommitPlan?)
}

/// Learning input copied from Android's selected segment candidate. This is a
/// Core-owned DTO so the session does not depend on the separate learning PR.
public struct BunsetsuLearningFragment: Equatable {
    public let reading: String
    public let output: String
    public let candidateScore: Int32
    public let candidateIndex: Int32
    public let leftID: Int16?
    public let rightID: Int16?
    public let explicitlySelected: Bool

    public init(
        reading: String,
        output: String,
        candidateScore: Int32,
        candidateIndex: Int32,
        leftID: Int16?,
        rightID: Int16?,
        explicitlySelected: Bool
    ) {
        self.reading = reading
        self.output = output
        self.candidateScore = candidateScore
        self.candidateIndex = candidateIndex
        self.leftID = leftID
        self.rightID = rightID
        self.explicitlySelected = explicitlySelected
    }
}

/// A safe prefix commit plan for hosts that commit one bunsetsu at a time.
/// The remaining reading and tail stay composing; learning can remain tied to
/// the original input until the final plan consumes the remainder.
public struct BunsetsuSegmentCommitPlan: Equatable {
    public let text: String
    public let committedReading: String
    public let readingUTF16Length: Int
    public let remainingConversionInput: String
    public let remainingRawInput: String
    public let learningReading: String
    public let learningSessionContinues: Bool
    public let selectedCandidate: BunsetsuSessionCandidate

    public var learningFragment: BunsetsuLearningFragment {
        BunsetsuLearningFragment(
            reading: committedReading,
            output: text,
            candidateScore: Int32(clamping: selectedCandidate.score),
            candidateIndex: Int32(clamping: selectedCandidate.candidateIndex),
            leftID: selectedCandidate.leftID,
            rightID: selectedCandidate.rightID,
            explicitlySelected: selectedCandidate.explicitlySelected
        )
    }

    fileprivate init(
        text: String,
        committedReading: String,
        readingUTF16Length: Int,
        remainingConversionInput: String,
        tailText: String,
        learningReading: String,
        selectedCandidate: BunsetsuSessionCandidate
    ) {
        self.text = text
        self.committedReading = committedReading
        self.readingUTF16Length = readingUTF16Length
        self.remainingConversionInput = remainingConversionInput
        self.remainingRawInput = remainingConversionInput + tailText
        self.learningReading = learningReading
        self.learningSessionContinues = !self.remainingRawInput.isEmpty
        self.selectedCandidate = selectedCandidate
    }
}

/// Immutable description of Android's commit-through-focused-segment action.
/// The host commits `committedText`, retains `nextComposingInput`, and keeps the
/// original reading context and candidate metadata for learning across commits.
public struct BunsetsuFocusedPrefixCommitPlan: Equatable {
    public let committedText: String
    public let committedReading: String
    public let readingUTF16Length: Int
    public let remainingConversionInput: String
    public let nextComposingInput: String
    public let nextTailText: String
    public let learningReading: String
    public let learningSessionContinues: Bool
    public let selectedCandidates: [BunsetsuSessionCandidate]
    public let learningFragments: [BunsetsuLearningFragment]

    fileprivate init(
        committedText: String,
        committedReading: String,
        readingUTF16Length: Int,
        remainingConversionInput: String,
        tailText: String,
        learningReading: String,
        selectedCandidates: [BunsetsuSessionCandidate],
        learningFragments: [BunsetsuLearningFragment]
    ) {
        self.committedText = committedText
        self.committedReading = committedReading
        self.readingUTF16Length = readingUTF16Length
        self.remainingConversionInput = remainingConversionInput
        if remainingConversionInput.isEmpty {
            self.nextComposingInput = tailText
            self.nextTailText = ""
        } else {
            self.nextComposingInput = remainingConversionInput + tailText
            self.nextTailText = tailText
        }
        self.learningReading = learningReading
        self.learningSessionContinues = !self.nextComposingInput.isEmpty
        self.selectedCandidates = selectedCandidates
        self.learningFragments = learningFragments
    }
}

public struct BunsetsuSessionSegment: Equatable {
    public let readingRange: NSRange
    public let reading: String
    public let initialText: String
    public private(set) var candidateRecords: [BunsetsuSessionCandidate]
    public var candidates: [String] { candidateRecords.map(\.text) }
    public private(set) var selectedIndex: Int
    public private(set) var displayOverrideCandidate: BunsetsuSessionCandidate?
    public private(set) var candidatesLoaded: Bool
    public private(set) var isLoadingCandidates: Bool
    public private(set) var hasConvertedDisplay: Bool

    public var displayText: String {
        displayOverrideCandidate?.text ??
            (candidateRecords.indices.contains(selectedIndex) ? candidateRecords[selectedIndex].text : initialText)
    }

    public var selectedCandidate: BunsetsuSessionCandidate? {
        if let displayOverrideCandidate {
            return displayOverrideCandidate.assigningCandidateIndex(
                selectedIndex,
                explicitlySelected: true
            )
        }
        return candidateRecords.indices.contains(selectedIndex) ? candidateRecords[selectedIndex] : nil
    }

    fileprivate init(projected: BunsetsuSegment, initialTextOverride: String? = nil) {
        readingRange = projected.readingRange
        reading = projected.reading
        let initialText = initialTextOverride ?? projected.text
        self.initialText = initialText
        let sameProjectedText = bunsetsuStringsMatchUTF16(initialText, projected.text)
        candidateRecords = [BunsetsuSessionCandidate(text: initialText,
            leftID: sameProjectedText ? projected.leftID : nil,
            rightID: sameProjectedText ? projected.rightID : nil)]
        selectedIndex = 0
        displayOverrideCandidate = nil
        candidatesLoaded = false
        isLoadingCandidates = false
        hasConvertedDisplay = projected.hasConvertedDisplay || initialTextOverride != nil
    }

    fileprivate mutating func beginLoading() {
        isLoadingCandidates = true
    }

    fileprivate mutating func cancelLoading() {
        isLoadingCandidates = false
    }

    fileprivate mutating func installCandidates(_ values: [BunsetsuSessionCandidate]) {
        let selectedDisplayOverride = displayOverrideCandidate
        let firstLocalCandidate = values.first(where: { !$0.text.isEmpty })
        let initialTextKey = Array(initialText.utf16)
        let preferredCandidate = hasConvertedDisplay
            ? values.first(where: { Array($0.text.utf16) == initialTextKey }) ??
                candidateRecords.first(where: { Array($0.text.utf16) == initialTextKey }) ?? BunsetsuSessionCandidate(text: initialText)
            : (firstLocalCandidate ?? BunsetsuSessionCandidate(text: reading))
        var seen = Set<[UInt16]>()
        candidateRecords = ([preferredCandidate] + values)
            .filter { !$0.text.isEmpty && seen.insert(Array($0.text.utf16)).inserted }
            .enumerated()
            .map { $0.element.assigningCandidateIndex($0.offset) }
        selectedIndex = 0
        displayOverrideCandidate = selectedDisplayOverride
        candidatesLoaded = true
        isLoadingCandidates = false
        hasConvertedDisplay = true
    }

    fileprivate mutating func cycleCandidate(by delta: Int) -> Bool {
        guard candidatesLoaded, delta != 0 else { return false }
        guard candidateRecords.count > 1 else {
            guard displayOverrideCandidate != nil else { return false }
            displayOverrideCandidate = nil
            selectedIndex = 0
            return true
        }
        let count = candidateRecords.count
        let step = delta % count
        selectedIndex = ((selectedIndex + step) % count + count) % count
        displayOverrideCandidate = nil
        return true
    }

    fileprivate mutating func selectCandidate(at index: Int) -> Bool {
        guard candidatesLoaded, candidateRecords.indices.contains(index) else { return false }
        let changed = selectedIndex != index || displayOverrideCandidate != nil
        selectedIndex = index
        displayOverrideCandidate = nil
        return changed
    }

    fileprivate mutating func selectCandidateFromBar(at index: Int) -> Bool {
        guard candidatesLoaded, candidateRecords.indices.contains(index) else { return false }
        selectedIndex = index
        displayOverrideCandidate = nil
        return true
    }

    fileprivate mutating func selectDisplayOverride(_ candidate: BunsetsuSessionCandidate) {
        displayOverrideCandidate = candidate
    }
}

/// A pure value-state model for Android-compatible bunsetsu interaction.
/// Conversion, UIKit, and asynchronous work stay outside this type. A token
/// from beginLoadingFocusedCandidates() binds a result to one exact session
/// revision and split pattern, so stale replies are rejected after any edit.
public struct BunsetsuConversionSession: Equatable {
    public struct CandidateLoadToken: Equatable {
        public let sessionID: UUID
        public let sessionGeneration: UInt64
        public let revision: UInt64
        public let patternIndex: Int
        public let segmentIndex: Int
        public let segmentReading: String
        public let conversionRequestGeneration: UInt64
    }

    /// A unique value identity prevents a late reply from an earlier value
    /// session being accepted when the host reuses its numeric generation.
    public let sessionID: UUID
    public let rawInput: String
    public let conversionInput: String
    public let tailText: String
    public let wholeDisplayText: String
    /// Pass only when the whole-input candidate satisfies Android's unsplit
    /// eligibility checks (unmodified candidate with matching commit text).
    public let eligibleWholeCandidateDisplayText: String?
    public let generation: UInt64
    public let splitPatterns: [BunsetsuSplitPattern]
    public private(set) var activeSplitPatternIndex: Int
    public private(set) var focusedSegmentIndex: Int
    public private(set) var segments: [BunsetsuSessionSegment]
    public private(set) var revision: UInt64
    public private(set) var zenzLiveSlotState: BunsetsuZenzLiveSlotState?

    public var focusedSegment: BunsetsuSessionSegment? {
        segments.indices.contains(focusedSegmentIndex) ? segments[focusedSegmentIndex] : nil
    }

    public var focusedReadingRange: NSRange? { focusedSegment?.readingRange }

    /// Android's Zenz target includes only the focused segment's reading and
    /// the display text to its left. A later segment change does not stale it.
    public var focusedZenzSlotTarget: BunsetsuZenzSlotTarget? {
        guard let focusedSegment else { return nil }
        return BunsetsuZenzSlotTarget(
            conversionInput: conversionInput,
            segmentIndex: focusedSegmentIndex,
            segmentReading: focusedSegment.reading,
            leftContext: segments.prefix(focusedSegmentIndex).map(\.displayText).joined()
        )
    }

    /// The segment projection plus unconverted tail shown in the composing view.
    public var displayText: String { commitText + tailText }

    /// The text to commit. The unconverted tail remains composing after commit.
    public var commitText: String { segments.map(\.displayText).joined() }

    /// Plans committing one leading segment. Use focusedPrefixCommitPlan() to
    /// match Android's action that commits every segment through the focus.
    public func leadingSegmentCommitPlan() -> BunsetsuSegmentCommitPlan? {
        guard focusedSegmentIndex == 0,
              let segment = segments.first,
              segment.hasConvertedDisplay || segment.candidatesLoaded,
              let selectedCandidate = segment.selectedCandidate,
              segment.readingRange.location == 0,
              segment.readingRange.length > 0,
              segment.readingRange.length <= conversionInput.utf16.count,
              let remainderRange = Range(
                NSRange(
                    location: segment.readingRange.length,
                    length: conversionInput.utf16.count - segment.readingRange.length
                ),
                in: conversionInput
              ) else { return nil }

        return BunsetsuSegmentCommitPlan(
            text: segment.displayText,
            committedReading: segment.reading,
            readingUTF16Length: segment.readingRange.length,
            remainingConversionInput: String(conversionInput[remainderRange]),
            tailText: tailText,
            learningReading: rawInput,
            selectedCandidate: selectedCandidate
        )
    }

    /// Plans committing every segment from the start through the focused one,
    /// matching Android's `commitBunsetsuConversionUntilFocusedSegment` path.
    /// Each selected candidate's conversion identity and learning fields remain
    /// available after the host mutates the composing text.
    public func focusedPrefixCommitPlan() -> BunsetsuFocusedPrefixCommitPlan? {
        guard segments.indices.contains(focusedSegmentIndex) else { return nil }
        let committedSegments = Array(segments.prefix(focusedSegmentIndex + 1))
        guard !committedSegments.isEmpty,
              committedSegments.allSatisfy({ $0.hasConvertedDisplay || $0.candidatesLoaded }) else { return nil }

        var readingEnd = 0
        var selectedCandidates: [BunsetsuSessionCandidate] = []
        var learningFragments: [BunsetsuLearningFragment] = []
        for segment in committedSegments {
            guard segment.readingRange.location == readingEnd,
                  segment.readingRange.length > 0,
                  let candidate = segment.selectedCandidate else { return nil }
            readingEnd = NSMaxRange(segment.readingRange)
            selectedCandidates.append(candidate)
            learningFragments.append(Self.learningFragment(for: candidate, segment: segment))
        }
        guard readingEnd <= conversionInput.utf16.count,
              let committedRange = Range(NSRange(location: 0, length: readingEnd), in: conversionInput),
              let remainingRange = Range(
                NSRange(location: readingEnd, length: conversionInput.utf16.count - readingEnd),
                in: conversionInput
              ) else { return nil }

        return BunsetsuFocusedPrefixCommitPlan(
            committedText: committedSegments.map(\.displayText).joined(),
            committedReading: String(conversionInput[committedRange]),
            readingUTF16Length: readingEnd,
            remainingConversionInput: String(conversionInput[remainingRange]),
            tailText: tailText,
            learningReading: rawInput,
            selectedCandidates: selectedCandidates,
            learningFragments: learningFragments
        )
    }

    /// The input to restore if the user cancels the conversion session.
    public var cancellationInput: String { rawInput }

    /// Android displays the focused segment's local rows, with a current Zenz
    /// loading/result row inserted at the leading slot when available.
    public var focusedCandidateBarItems: [BunsetsuCandidateBarItem] {
        guard let focusedSegment else { return [] }
        var items: [BunsetsuCandidateBarItem] = []
        var zenzCandidate: BunsetsuSessionCandidate?

        if let state = zenzLiveSlotState,
           state.token.sessionID == sessionID,
           state.token.sessionGeneration == generation,
           state.token.target == focusedZenzSlotTarget {
            switch state {
            case let .loading(token):
                items.append(candidateBarItem(.zenzLoading, zenzToken: token))
            case let .result(token, candidate):
                zenzCandidate = candidate
                items.append(candidateBarItem(.zenzResult(candidate), zenzToken: token))
            }
        }

        var removedFirstZenzDuplicate = false
        for (index, candidate) in focusedSegment.candidateRecords.enumerated() {
            guard !candidate.text.isEmpty else { continue }
            if !removedFirstZenzDuplicate,
               let zenzCandidate,
               candidate.matchedReadingUTF16Length == focusedSegment.reading.utf16.count,
               bunsetsuStringsMatchUTF16(candidate.commitText, zenzCandidate.commitText) {
                removedFirstZenzDuplicate = true
                continue
            }
            items.append(candidateBarItem(
                .segmentCandidate(index: index, candidate: candidate)
            ))
        }
        return items
    }

    public var focusedCandidateBarTexts: [String] {
        focusedCandidateBarItems.map(\.text)
    }

    /// Android prepares the focused segment and every segment that still shows
    /// its reading because no whole-path token projection was available.
    public var candidatePreparationSegmentIndices: [Int] {
        segments.indices.filter { $0 == focusedSegmentIndex || !segments[$0].hasConvertedDisplay }
    }

    /// Starts from one owned native snapshot. Its original reading and request
    /// generation are checked before any split metadata enters the session.
    /// Surface/KVC and the conversion service remain responsible for applying
    /// this value state and retaining native candidate references.
    public init(
        rawInput: String,
        conversionInput: String,
        tailText: String = "",
        wholeDisplayText: String,
        generation: UInt64,
        snapshot: BunsetsuConversionSnapshot,
        orderedDisplayCandidates: [BunsetsuCandidateDisplayIdentity]
    ) throws {
        let patterns = try snapshot.projectedSplitPatterns(
            reading: conversionInput,
            requestGeneration: generation,
            orderedDisplayCandidates: orderedDisplayCandidates
        )
        try self.init(
            rawInput: rawInput, conversionInput: conversionInput, tailText: tailText,
            wholeDisplayText: wholeDisplayText, generation: generation,
            splitPatterns: patterns
        )
    }

    public init(rawInput: String, conversionInput: String, tailText: String = "",
                wholeDisplayText: String, generation: UInt64,
                splitPatterns: [BunsetsuSplitPattern],
                eligibleWholeCandidateDisplayText: String? = nil) throws {
        guard !conversionInput.isEmpty else {
            throw BunsetsuConversionSessionError.emptyConversionInput
        }
        guard Self.sameUTF16(rawInput, conversionInput + tailText) else {
            throw BunsetsuConversionSessionError.rawInputDoesNotMatchConversionAndTail
        }
        guard !splitPatterns.isEmpty else {
            throw BunsetsuConversionSessionError.noSplitPatterns
        }

        var uniquePatterns: [BunsetsuSplitPattern] = []
        var seenBoundaries = Set<[Int]>()
        for pattern in splitPatterns {
            guard Self.sameUTF16(pattern.reading, conversionInput),
                  !pattern.segments.isEmpty,
                  Self.coversWholeReading(pattern.segments, reading: conversionInput),
                  seenBoundaries.insert(pattern.boundaries).inserted else {
                if Self.sameUTF16(pattern.reading, conversionInput),
                   seenBoundaries.contains(pattern.boundaries) {
                    continue
                }
                throw BunsetsuConversionSessionError.invalidPattern
            }
            uniquePatterns.append(pattern)
        }
        guard !uniquePatterns.isEmpty else {
            throw BunsetsuConversionSessionError.noSplitPatterns
        }

        self.sessionID = UUID()
        self.rawInput = rawInput
        self.conversionInput = conversionInput
        self.tailText = tailText
        self.wholeDisplayText = wholeDisplayText
        self.eligibleWholeCandidateDisplayText = eligibleWholeCandidateDisplayText
        self.generation = generation
        self.splitPatterns = uniquePatterns
        self.activeSplitPatternIndex = 0
        self.focusedSegmentIndex = 0
        self.segments = Self.sessionSegments(
            for: uniquePatterns[0],
            eligibleWholeCandidateDisplayText: eligibleWholeCandidateDisplayText
        )
        self.revision = 0
        self.zenzLiveSlotState = nil
    }

    /// Android clamps focus at the first and last segment; it does not wrap.
    @discardableResult
    public mutating func moveFocus(by delta: Int) -> Bool {
        guard !segments.isEmpty, delta != 0 else { return false }
        let sum = focusedSegmentIndex.addingReportingOverflow(delta)
        let target = sum.overflow
            ? (delta > 0 ? segments.count - 1 : 0)
            : min(max(sum.partialValue, 0), segments.count - 1)
        guard target != focusedSegmentIndex else { return false }
        // The outstanding reply is invalidated by the revision change below.
        // Clear its loading state as well, otherwise returning to this segment
        // could never start a fresh request after the stale reply is rejected.
        cancelPendingCandidateLoads()
        focusedSegmentIndex = target
        revision &+= 1
        return true
    }

    /// Cycles split patterns. Splitting one whole-reading segment starts at
    /// the first segment like Android; other changes preserve focus by overlap.
    @discardableResult
    public mutating func cycleSplitPattern(by delta: Int) -> Bool {
        guard splitPatterns.count > 1, delta != 0,
              let oldFocused = focusedSegment else { return false }
        let count = splitPatterns.count
        let step = delta % count
        let next = ((activeSplitPatternIndex + step) % count + count) % count
        guard next != activeSplitPatternIndex else { return false }

        let newSegments = Self.sessionSegments(
            for: splitPatterns[next],
            eligibleWholeCandidateDisplayText: eligibleWholeCandidateDisplayText
        )
        guard !newSegments.isEmpty else { return false }
        let nextFocusedIndex: Int
        if segments.count == 1 && newSegments.count > 1 {
            nextFocusedIndex = 0
        } else {
            nextFocusedIndex = Self.mostOverlappingSegment(
                with: oldFocused.readingRange,
                in: newSegments
            )
        }
        activeSplitPatternIndex = next
        segments = newSegments
        focusedSegmentIndex = nextFocusedIndex
        revision &+= 1
        return true
    }

    /// Starts loading for the currently focused segment. The returned token
    /// must accompany the result passed to installCandidates.
    public mutating func beginLoadingFocusedCandidates(
        conversionRequestGeneration: UInt64
    ) -> CandidateLoadToken? {
        beginLoadingCandidates(
            forSegmentAt: focusedSegmentIndex,
            conversionRequestGeneration: conversionRequestGeneration
        )
    }

    /// Starts loading any segment selected by candidatePreparationSegmentIndices.
    /// Loads should be started and installed sequentially because each accepted
    /// result advances the session revision and invalidates older tokens.
    public mutating func beginLoadingCandidates(
        forSegmentAt segmentIndex: Int,
        conversionRequestGeneration: UInt64
    ) -> CandidateLoadToken? {
        guard segments.indices.contains(segmentIndex),
              !segments.contains(where: \.isLoadingCandidates),
              !segments[segmentIndex].candidatesLoaded,
              !segments[segmentIndex].isLoadingCandidates else { return nil }
        segments[segmentIndex].beginLoading()
        revision &+= 1
        return CandidateLoadToken(
            sessionID: sessionID,
            sessionGeneration: generation,
            revision: revision,
            patternIndex: activeSplitPatternIndex,
            segmentIndex: segmentIndex,
            segmentReading: segments[segmentIndex].reading,
            conversionRequestGeneration: conversionRequestGeneration
        )
    }

    /// Installs alternatives only if the pattern, session, revision, and segment
    /// still match the request that started the load.
    /// Installs local candidates without discarding the exact conversion
    /// generation, candidate ID, rank, or connection IDs required for commit
    /// and Android-compatible learning. Synthetic display-only values are
    /// created by the session itself and are rejected as query responses.
    @discardableResult
    public mutating func installCandidates(
        _ candidates: [BunsetsuSessionCandidate],
        responseReading: String,
        responseGeneration: UInt64,
        for token: CandidateLoadToken
    ) -> Bool {
        guard token.sessionID == sessionID,
              token.sessionGeneration == generation,
              token.revision == revision,
              token.patternIndex == activeSplitPatternIndex,
              segments.indices.contains(token.segmentIndex),
              segments[token.segmentIndex].isLoadingCandidates else { return false }
        let responseMatchesRequest = Self.sameUTF16(responseReading, token.segmentReading) &&
            token.conversionRequestGeneration == responseGeneration
        let candidatesMatchResponse = candidates.allSatisfy { candidate in
            guard candidate.reference.isLocalConversionResult,
                  let generation = candidate.reference.conversionGeneration else { return false }
            return generation == responseGeneration
        }
        guard responseMatchesRequest && candidatesMatchResponse else {
            segments[token.segmentIndex].cancelLoading()
            revision &+= 1
            return false
        }
        segments[token.segmentIndex].installCandidates(candidates)
        revision &+= 1
        return true
    }

    /// Begins the focused segment's distinct Zenz live-result request. The
    /// integration layer remains responsible for Android's Zenz eligibility
    /// policy and for supplying the request generation used by its service.
    public mutating func beginLoadingFocusedZenzSlot(
        requestGeneration: UInt64
    ) -> BunsetsuZenzSlotLoadToken? {
        guard let target = focusedZenzSlotTarget,
              !target.segmentReading.isEmpty else { return nil }
        cancelPendingCandidateLoads()
        let token = BunsetsuZenzSlotLoadToken(
            sessionID: sessionID,
            sessionGeneration: generation,
            requestGeneration: requestGeneration,
            target: target
        )
        zenzLiveSlotState = .loading(token: token)
        revision &+= 1
        return token
    }

    /// Installs only the first accepted result for the exact active Zenz token
    /// and semantic target. A stale response cannot clear a newer slot request.
    @discardableResult
    public mutating func installZenzLiveResult(
        _ candidate: BunsetsuSessionCandidate,
        responseReading: String,
        responseGeneration: UInt64,
        for token: BunsetsuZenzSlotLoadToken
    ) -> Bool {
        guard token.sessionID == sessionID,
              token.sessionGeneration == generation,
              case let .loading(activeToken)? = zenzLiveSlotState,
              activeToken == token else { return false }

        let referenceMatches: Bool
        if case let .zenzLiveResult(generation, _) = candidate.reference {
            referenceMatches = generation == responseGeneration
        } else {
            referenceMatches = false
        }
        let responseMatchesTarget = Self.sameUTF16(responseReading, token.target.segmentReading) &&
            responseGeneration == token.requestGeneration
        let candidateMatchesTarget = candidate.matchedReadingUTF16Length == token.target.segmentReading.utf16.count &&
            AndroidZenzOutputPolicy.acceptedTextOrNil(candidate.text) != nil &&
            AndroidZenzOutputPolicy.acceptedTextOrNil(candidate.commitText) != nil
        guard focusedZenzSlotTarget == token.target,
              responseMatchesTarget,
              referenceMatches,
              candidateMatchesTarget else {
            cancelPendingCandidateLoads()
            zenzLiveSlotState = nil
            revision &+= 1
            return false
        }

        cancelPendingCandidateLoads()
        zenzLiveSlotState = .result(token: token, candidate: candidate)
        revision &+= 1
        return true
    }

    /// Completes a Zenz request with no usable result. Only its own active
    /// loading row is removed; a late empty response cannot erase a newer row.
    @discardableResult
    public mutating func finishZenzSlotWithoutResult(
        for token: BunsetsuZenzSlotLoadToken
    ) -> Bool {
        guard token.sessionID == sessionID,
              token.sessionGeneration == generation,
              case let .loading(activeToken)? = zenzLiveSlotState,
              activeToken == token else { return false }
        cancelPendingCandidateLoads()
        zenzLiveSlotState = nil
        revision &+= 1
        return true
    }

    /// Applies Android's tap split: a Zenz row changes the focused segment's
    /// displayed/learning candidate without committing; a local row returns
    /// the normal commit-through-focused-prefix plan, even for the current row.
    public mutating func selectFocusedCandidateBarItem(
        _ item: BunsetsuCandidateBarItem
    ) -> BunsetsuCandidateBarSelection {
        guard item.sessionID == sessionID,
              item.sessionGeneration == generation,
              item.sessionRevision == revision,
              item.focusedSegmentIndex == focusedSegmentIndex,
              segments.indices.contains(focusedSegmentIndex) else { return .stale }

        switch item.content {
        case .zenzLoading:
            guard let token = item.zenzToken,
                  token.sessionID == sessionID,
                  token.sessionGeneration == generation,
                  token.target == focusedZenzSlotTarget,
                  case let .loading(activeToken)? = zenzLiveSlotState,
                  activeToken == token else { return .stale }
            return .loadingSlotConsumed

        case let .zenzResult(candidate):
            guard let token = item.zenzToken,
                  token.sessionID == sessionID,
                  token.sessionGeneration == generation,
                  token.target == focusedZenzSlotTarget,
                  case let .result(activeToken, activeCandidate)? = zenzLiveSlotState,
                  activeToken == token,
                  Self.sameCandidate(candidate, activeCandidate) else { return .stale }
            cancelPendingCandidateLoads()
            segments[focusedSegmentIndex].selectDisplayOverride(activeCandidate)
            revision &+= 1
            return .zenzResultSelected

        case let .segmentCandidate(index, candidate):
            guard segments[focusedSegmentIndex].candidatesLoaded,
                  segments[focusedSegmentIndex].candidateRecords.indices.contains(index),
                  Self.sameCandidate(
                    candidate,
                    segments[focusedSegmentIndex].candidateRecords[index]
                  ) else { return .stale }
            cancelPendingCandidateLoads()
            _ = segments[focusedSegmentIndex].selectCandidateFromBar(at: index)
            revision &+= 1
            return .segmentCandidateSelected(commitPlan: focusedPrefixCommitPlan())
        }
    }

    /// Candidate switching wraps within the focused segment's loaded choices.
    @discardableResult
    public mutating func cycleFocusedCandidate(by delta: Int) -> Bool {
        guard segments.indices.contains(focusedSegmentIndex),
              segments[focusedSegmentIndex].cycleCandidate(by: delta) else { return false }
        cancelPendingCandidateLoads()
        revision &+= 1
        return true
    }

    /// Selects one exact loaded candidate, as used by a candidate-bar tap.
    /// Returns false for an invalid index or when the selected index is unchanged.
    @discardableResult
    public mutating func selectFocusedCandidate(at index: Int) -> Bool {
        guard segments.indices.contains(focusedSegmentIndex),
              segments[focusedSegmentIndex].candidatesLoaded,
              segments[focusedSegmentIndex].selectCandidate(at: index) else { return false }
        cancelPendingCandidateLoads()
        revision &+= 1
        return true
    }

    private mutating func cancelPendingCandidateLoads() {
        for index in segments.indices where segments[index].isLoadingCandidates {
            segments[index].cancelLoading()
        }
    }

    private func candidateBarItem(
        _ content: BunsetsuCandidateBarItemContent,
        zenzToken: BunsetsuZenzSlotLoadToken? = nil
    ) -> BunsetsuCandidateBarItem {
        BunsetsuCandidateBarItem(
            content: content,
            sessionID: sessionID,
            sessionGeneration: generation,
            sessionRevision: revision,
            focusedSegmentIndex: focusedSegmentIndex,
            zenzToken: zenzToken
        )
    }

    private static func sameCandidate(
        _ lhs: BunsetsuSessionCandidate,
        _ rhs: BunsetsuSessionCandidate
    ) -> Bool {
        sameUTF16(lhs.text, rhs.text) &&
            sameUTF16(lhs.commitText, rhs.commitText) &&
            sameReference(lhs.reference, rhs.reference) &&
            lhs.score == rhs.score &&
            lhs.candidateIndex == rhs.candidateIndex &&
            lhs.leftID == rhs.leftID &&
            lhs.rightID == rhs.rightID &&
            lhs.explicitlySelected == rhs.explicitlySelected &&
            lhs.matchedReadingUTF16Length == rhs.matchedReadingUTF16Length
    }

    private static func sameReference(
        _ lhs: BunsetsuSessionCandidateReference,
        _ rhs: BunsetsuSessionCandidateReference
    ) -> Bool {
        switch (lhs, rhs) {
        case (.displayOnly, .displayOnly): return true
        case let (.conversionResult(leftGeneration, leftID), .conversionResult(rightGeneration, rightID)):
            return leftGeneration == rightGeneration && leftID == rightID
        case let (.learnedPrediction(leftGeneration, leftID, leftReading),
                  .learnedPrediction(rightGeneration, rightID, rightReading)):
            return leftGeneration == rightGeneration && leftID == rightID && sameUTF16(leftReading, rightReading)
        case let (.zenzLiveResult(leftGeneration, leftID), .zenzLiveResult(rightGeneration, rightID)):
            return leftGeneration == rightGeneration && leftID == rightID
        default: return false
        }
    }

    private static func learningFragment(
        for candidate: BunsetsuSessionCandidate,
        segment: BunsetsuSessionSegment
    ) -> BunsetsuLearningFragment {
        BunsetsuLearningFragment(
            reading: segment.reading,
            output: segment.displayText,
            candidateScore: Int32(clamping: candidate.score),
            candidateIndex: Int32(clamping: candidate.candidateIndex),
            leftID: candidate.leftID,
            rightID: candidate.rightID,
            explicitlySelected: candidate.explicitlySelected
        )
    }

    private static func sameUTF16(_ lhs: String, _ rhs: String) -> Bool {
        bunsetsuStringsMatchUTF16(lhs, rhs)
    }

    private static func coversWholeReading(_ segments: [BunsetsuSegment], reading: String) -> Bool {
        var expectedLocation = 0
        for segment in segments {
            let range = segment.readingRange
            guard range.location == expectedLocation, range.length > 0,
                  range.length <= reading.utf16.count - expectedLocation,
                  let stringRange = Range(range, in: reading),
                  sameUTF16(String(reading[stringRange]), segment.reading) else { return false }
            expectedLocation += range.length
        }
        return expectedLocation == reading.utf16.count
    }

    private static func sessionSegments(
        for pattern: BunsetsuSplitPattern,
        eligibleWholeCandidateDisplayText: String?
    ) -> [BunsetsuSessionSegment] {
        let wholeCandidate = pattern.segments.count == 1
            ? eligibleWholeCandidateDisplayText.flatMap { $0.isEmpty ? nil : $0 }
            : nil
        return pattern.segments.map { projected in
            BunsetsuSessionSegment(
                projected: projected,
                initialTextOverride: wholeCandidate
            )
        }
    }

    private static func mostOverlappingSegment(
        with range: NSRange,
        in segments: [BunsetsuSessionSegment]
    ) -> Int {
        var bestIndex = 0
        var bestOverlap = -1
        var bestDistance = Int.max
        for (index, segment) in segments.enumerated() {
            let overlap = NSIntersectionRange(range, segment.readingRange).length
            let distance = abs(segment.readingRange.location - range.location)
            // Android takes maxWith(compareBy(overlap).thenByDescending(-distance)).
            // The double reversal chooses the greater distance for equal overlap.
            if overlap > bestOverlap || (overlap == bestOverlap && distance > bestDistance) {
                bestIndex = index
                bestOverlap = overlap
                bestDistance = distance
            }
        }
        return bestIndex
    }
}
