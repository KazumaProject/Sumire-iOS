import Foundation

/// Checked views of immutable source arrays. No strings or token objects are expanded.
public struct ValidatedDictionarySource {
    public let isEnglish: Bool
    public let reading: [DictionaryPrimitiveArray]
    public let surface: [DictionaryPrimitiveArray]
    public let tokens: [DictionaryPrimitiveArray]
    /// BFS label index -> parent label index, as used by build_dictionary.py.
    public let surfaceParents: [UInt32]
    public let postingOffsets: [UInt32]
    public let tokenCount: Int
    /// Legal in the distributed English dictionary: term IDs need not cover every posting.
    public let unreferencedTokenCount: Int
    /// Japanese -1 = katakana reading; -2 = unchanged reading.
    /// English -1 = unchanged reading, encoded as -2 in the native dictionary.
    public func nativeSurfaceReference(at index: Int) throws -> Int64 {
        let node = try tokens[isEnglish ? 1 : 2].signed(at: index)
        return isEnglish && node == -1 ? -2 : node
    }
}

public enum DictionarySourceValidation {
    public struct Limits {
        public var nodes = 8_000_000
        public var tokens = 8_000_000
        public var postingGroups = 8_000_000
        public var utf16Length = 4096
        public init() {}
    }
    public static func validate(reading: [DictionaryPrimitiveArray], surface: [DictionaryPrimitiveArray],
                                tokens: [DictionaryPrimitiveArray], isEnglish: Bool = false,
                                posTableCount: Int, limits: Limits = Limits()) throws -> ValidatedDictionarySource {
        guard limits.nodes >= 2, limits.nodes <= 32_000_000, limits.tokens >= 0, limits.tokens <= 32_000_000,
              limits.postingGroups >= 0, limits.postingGroups <= 32_000_000,
              (1...65535).contains(limits.utf16Length), isEnglish || posTableCount > 0 else { throw bad("上限設定・品詞表") }
        try kinds(reading, [.longs, .longs, .characters, .ints], "読み")
        try kinds(surface, [.longs, .longs, .characters], "表記")
        try kinds(tokens, isEnglish ? [.shorts, .ints, .longs] : [.shorts, .shorts, .ints, .longs], "単語")
        let count = tokens[0].count
        guard count <= limits.tokens,
              tokens.dropLast().allSatisfy({ $0.count == count }) else { throw bad("単語列の長さ") }
        let yomi = try trie(reading, retainParents: false, limits: limits)
        let tango = try trie(surface, retainParents: true, limits: limits)
        guard yomi.leafCount == reading[3].count else { throw bad("読み終端とterm数") }
        let post = try Bits(tokens.last!, maxBits: limits.tokens + limits.postingGroups + 64)
        guard post.ones == count, count == 0 || !post.at(0) else { throw bad("postingの単語数・先頭") }
        var offsets: [UInt32] = [0], seenTokens = 0
        outer: for word in post.words {
            for bit in 0..<64 {
                if word & (UInt64(1) << bit) != 0 { seenTokens += 1 }
                else {
                    guard offsets.count <= limits.postingGroups + 1 else { throw bad("postingグループ数") }
                    offsets.append(UInt32(seenTokens))
                }
                if seenTokens == count { break outer }
            }
        }
        offsets.append(UInt32(seenTokens))
        var used = [Bool](repeating: false, count: offsets.count), referenced = 0
        for i in 0..<reading[3].count {
            let term = try reading[3].signed(at: i)
            guard term > 0, term + 1 < offsets.count else { throw bad("termのposting範囲") }
            let t = Int(term)
            if !used[t] { used[t] = true; referenced += Int(offsets[t + 1] - offsets[t]) }
        }
        let nodeColumn = isEnglish ? 1 : 2
        for i in 0..<count {
            if !isEnglish {
                let pos = try tokens[0].signed(at: i)
                guard pos >= 0, pos < posTableCount else { throw bad("単語の品詞範囲") }
            }
            let node = try tokens[nodeColumn].signed(at: i)
            if node < 0 {
                guard node == -1 || (!isEnglish && node == -2) else { throw bad("表記sentinel") }
            } else {
                // Android spells the referenced node directly; it does not
                // require that the node also be marked as a trie terminal.
                guard node > 0, tango.bits.at(Int(node)) else { throw bad("表記ノード") }
            }
        }
        return .init(isEnglish: isEnglish, reading: reading, surface: surface, tokens: tokens,
                     surfaceParents: tango.parents, postingOffsets: offsets, tokenCount: count,
                     unreferencedTokenCount: count - referenced)
    }
    private static func bad(_ part: String) -> PersonalDataError { PersonalDataError("辞書の構造が不正です: " + part) }
    private static func kinds(_ arrays: [DictionaryPrimitiveArray], _ expected: [DictionaryPrimitiveKind], _ part: String) throws {
        guard arrays.map(\.kind) == expected else { throw bad(part + "配列型・数") }
    }
    private struct Bits {
        let words: [UInt64]
        let ones: Int
        init(_ source: DictionaryPrimitiveArray, maxBits: Int) throws {
            guard source.count <= maxBits / 64 else { throw bad("ビット列容量") }
            var values: [UInt64] = []; values.reserveCapacity(source.count)
            var count = 0
            for i in 0..<source.count { let value = try source.unsigned(at: i); values.append(value); count += value.nonzeroBitCount }
            words = values; ones = count
        }
        func at(_ position: Int) -> Bool {
            position >= 0 && position / 64 < words.count && words[position / 64] & (UInt64(1) << (position % 64)) != 0
        }
    }
    private struct Trie {
        let bits: Bits
        let leaves: Bits
        let parents: [UInt32]
        var leafCount: Int { leaves.ones }
    }
    private static func trie(_ arrays: [DictionaryPrimitiveArray], retainParents: Bool, limits: Limits) throws -> Trie {
        let bits = try Bits(arrays[0], maxBits: limits.nodes * 2 + 64)
        let leaves = try Bits(arrays[1], maxBits: limits.nodes * 2 + 64)
        let labels = arrays[2], count = labels.count
        guard count >= 2, count <= limits.nodes, bits.ones + 1 == count,
              bits.at(0), !bits.at(1), !leaves.at(0),
              bits.words.count * 64 - bits.ones >= bits.ones else { throw bad("LOUDSのroot・文字数・終端容量") }
        for i in leaves.words.indices {
            let tree = i < bits.words.count ? bits.words[i] : 0
            guard leaves.words[i] & ~tree == 0 else { throw bad("終端ビットの範囲") }
        }
        var parents = retainParents ? [UInt32](repeating: 0, count: count) : []
        var depth = [UInt16](repeating: 0, count: count)
        var index = 0
        for (wordIndex, initial) in bits.words.enumerated() {
            var word = initial
            while word != 0 {
                let bit = word.trailingZeroBitCount, position = wordIndex * 64 + bit
                word &= word - 1; index += 1
                let parent = position + 1 - index
                if index == 1 { guard parent == 0 else { throw bad("人工root") }; continue }
                guard parent >= 1, parent < index else { throw bad("親ノード循環・範囲") }
                if retainParents { parents[index] = UInt32(parent) }
                let length = Int(depth[parent]) + 1
                guard length <= limits.utf16Length else { throw bad("文字列長") }
                depth[index] = UInt16(length)
                _ = try labels.unsigned(at: index)
            }
        }
        return .init(bits: bits, leaves: leaves, parents: parents)
    }
}
