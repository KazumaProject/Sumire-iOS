import Foundation

/// One committed conversion fragment captured while the original reading is still active.
/// The fields mirror the Android learning-session input, including candidate rank and
/// connection IDs needed by the learned-dictionary record.
public struct LearningFragment: Equatable, Sendable {
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
        leftID: Int16? = nil,
        rightID: Int16? = nil,
        explicitlySelected: Bool = false
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

/// A record produced by the Android-compatible conversion learning session.
public struct LearningSessionEntry: Equatable, Sendable {
    public let input: String
    public let output: String
    public let score: Int32
    public let leftID: Int16?
    public let rightID: Int16?
    public let usageCount: Int32
    public let lastUsedAt: Int64
    public let isPhrase: Bool

    public init(
        input: String,
        output: String,
        score: Int32,
        leftID: Int16?,
        rightID: Int16?,
        usageCount: Int32 = 1,
        lastUsedAt: Int64,
        isPhrase: Bool
    ) {
        self.input = input
        self.output = output
        self.score = score
        self.leftID = leftID
        self.rightID = rightID
        self.usageCount = usageCount
        self.lastUsedAt = lastUsedAt
        self.isPhrase = isPhrase
    }
}

/// Score arithmetic used by Android when learning candidate selections.
public enum LearningScorePolicy {
    private static let reinforcement: Int64 = 1_500

    public static func initial(candidateScore: Int32, candidateIndex: Int32) -> Int32 {
        let rank = Int64(max(candidateIndex, 0))
        let adjusted = Int64(candidateScore) - 500 * rank
        return Int32(min(max(adjusted, 0), Int64(Int32.max)))
    }

    public static func phrase(_ fragmentScores: [Int32]) -> Int32 {
        guard !fragmentScores.isEmpty else { return 3_000 }
        let average = fragmentScores.map(Double.init).reduce(0, +) / Double(fragmentScores.count)
        return Int32(min(max(average, 0), Double(Int32.max)))
    }

    public static func reinforce(existingScore: Int32, incomingScore: Int32) -> Int32 {
        let reinforced = min(Int64(existingScore), Int64(incomingScore)) - reinforcement
        return Int32(max(0, reinforced))
    }
}

/// Collects committed fragments until the original reading has been committed.
/// This is a value-type state machine; it performs no persistence or input capture itself.
public struct ConversionLearningSession: Equatable, Sendable {
    private var originalReading: String?
    private var expectedNextInput: String?
    private var fragments: [LearningFragment] = []

    public init() {}

    public var isActive: Bool { originalReading != nil }

    public mutating func beginIfNeeded(reading: String) {
        guard originalReading == nil, !reading.isEmpty else { return }
        originalReading = reading
    }

    public mutating func record(_ fragment: LearningFragment) {
        guard originalReading != nil, !fragment.reading.isEmpty, !fragment.output.isEmpty else { return }
        fragments.append(fragment)
    }

    /// Records a committed prefix from the current composing input and retains
    /// the session only while the host continues with the exact remainder.
    /// Android's IME accumulates these fragments until the original reading is
    /// committed; a replacement or destructive edit must not join two inputs.
    @discardableResult
    public mutating func append(
        _ fragment: LearningFragment,
        from input: String,
        remainingInput: String
    ) -> Bool {
        append([fragment], from: input, remainingInput: remainingInput)
    }

    /// Keeps one Android learning session across both ordinary and bunsetsu
    /// prefix commits. A bunsetsu plan may contribute several selected segment
    /// fragments while the composing remainder still belongs to this input.
    @discardableResult
    public mutating func append(
        _ newFragments: [LearningFragment],
        from input: String,
        remainingInput: String
    ) -> Bool {
        guard !input.isEmpty,
              !newFragments.isEmpty,
              newFragments.allSatisfy({ !$0.reading.isEmpty && !$0.output.isEmpty }) else {
            cancel()
            return false
        }
        if originalReading != nil {
            guard let expectedNextInput,
                  expectedNextInput.utf16.elementsEqual(input.utf16) else {
                cancel()
                return false
            }
        } else {
            beginIfNeeded(reading: input)
        }
        for fragment in newFragments { record(fragment) }
        expectedNextInput = remainingInput
        return true
    }

    @discardableResult
    public mutating func append(_ plan: BunsetsuFocusedPrefixCommitPlan) -> Bool {
        let fragments = plan.learningFragments.map { fragment in
            LearningFragment(
                reading: fragment.reading,
                output: fragment.output,
                candidateScore: fragment.candidateScore,
                candidateIndex: fragment.candidateIndex,
                leftID: fragment.leftID,
                rightID: fragment.rightID,
                explicitlySelected: fragment.explicitlySelected
            )
        }
        return append(fragments, from: plan.learningReading, remainingInput: plan.nextComposingInput)
    }

    /// Retains a pending partial-conversion session when the user appends to
    /// its remaining reading. Exact UTF-16 comparison matches Android String.
    @discardableResult
    public mutating func extendExpectedRemainder(to input: String) -> Bool {
        guard let expectedNextInput else { return false }
        let expected = Array(expectedNextInput.utf16)
        let updated = Array(input.utf16)
        guard updated.count >= expected.count, updated.starts(with: expected) else { return false }
        self.expectedNextInput = input
        return true
    }

    /// Romaji input can rewrite a pending suffix while appending (for example,
    /// `k` to `か`), so the caller may adopt the processed remainder explicitly.
    @discardableResult
    public mutating func adoptAppendedRemainder(_ input: String) -> Bool {
        guard originalReading != nil, expectedNextInput != nil, !input.isEmpty else { return false }
        expectedNextInput = input
        return true
    }

    public mutating func finish(learnFirstCandidate: Bool, timestamp: Int64) -> [LearningSessionEntry] {
        let reading = originalReading
        let recorded = fragments
        cancel()

        guard let reading, !reading.isEmpty, !recorded.isEmpty else { return [] }

        let learnable = recorded.filter { isLearnable($0, learnFirstCandidate: learnFirstCandidate) }
        guard !learnable.isEmpty else { return [] }

        let segmentEntries = learnable.map {
            $0.entry(timestamp: timestamp, isPhrase: false)
        }

        let cumulativePhraseEntries = recorded.indices.dropFirst().compactMap { lastIndex -> LearningSessionEntry? in
            let prefix = Array(recorded.prefix(lastIndex + 1))
            guard prefix.contains(where: { isLearnable($0, learnFirstCandidate: learnFirstCandidate) }) else {
                return nil
            }
            return LearningSessionEntry(
                input: prefix.map(\.reading).joined(),
                output: prefix.map(\.output).joined(),
                score: LearningScorePolicy.phrase(prefix.map(\.initialScore)),
                leftID: prefix.first?.leftID,
                rightID: prefix.last?.rightID,
                lastUsedAt: timestamp,
                isPhrase: true
            )
        }

        let completeEntry = LearningSessionEntry(
            input: reading,
            output: recorded.map(\.output).joined(),
            score: LearningScorePolicy.phrase(recorded.map(\.initialScore)),
            leftID: recorded.first?.leftID,
            rightID: recorded.last?.rightID,
            lastUsedAt: timestamp,
            // Kotlin String equality compares UTF-16 code units. Swift String
            // equality treats canonically equivalent spellings as equal.
            isPhrase: recorded.count > 1 || !reading.utf16.elementsEqual(recorded[0].reading.utf16)
        )

        // Android keeps the first record for duplicate (input, output) pairs.
        var seen = Set<Data>()
        return (segmentEntries + cumulativePhraseEntries + [completeEntry]).filter { entry in
            // Kotlin String equality is code-unit exact. Swift String equality treats
            // canonically equivalent Unicode spellings as equal, so dedupe on UTF-8 bytes.
            var key = Data()
            var inputByteCount = UInt64(entry.input.utf8.count).bigEndian
            withUnsafeBytes(of: &inputByteCount) { key.append(contentsOf: $0) }
            key.append(contentsOf: entry.input.utf8)
            key.append(contentsOf: entry.output.utf8)
            return seen.insert(key).inserted
        }
    }

    public mutating func cancel() {
        originalReading = nil
        expectedNextInput = nil
        fragments.removeAll(keepingCapacity: false)
    }

    private func isLearnable(_ fragment: LearningFragment, learnFirstCandidate: Bool) -> Bool {
        learnFirstCandidate || fragment.explicitlySelected || fragment.candidateIndex != 0
    }
}

private extension LearningFragment {
    var initialScore: Int32 {
        LearningScorePolicy.initial(candidateScore: candidateScore, candidateIndex: candidateIndex)
    }

    func entry(timestamp: Int64, isPhrase: Bool) -> LearningSessionEntry {
        LearningSessionEntry(
            input: reading,
            output: output,
            score: initialScore,
            leftID: leftID,
            rightID: rightID,
            lastUsedAt: timestamp,
            isPhrase: isPhrase
        )
    }
}
