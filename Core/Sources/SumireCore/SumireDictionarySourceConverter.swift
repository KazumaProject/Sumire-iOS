import Foundation

/// Converts checked Android primitive arrays to the section order consumed by
/// ConversionCore. The input arrays remain mapped views until this finishes.
public enum SumireDictionarySourceConverter {
    public static func write(_ source: ValidatedDictionarySource, to destination: URL) throws {
        try SumireDictionaryBinaryWriter.write(kind: .dictionary, sections: sections(for: source), to: destination)
    }

    static func sections(for source: ValidatedDictionarySource) throws -> [Data] {
        let reading = source.reading
        let surface = source.surface
        let tokens = source.tokens
        let costColumn = source.isEnglish ? 0 : 1
        let rank = try LOUDSRank(surface[0])
        var refs = Data()
        refs.reserveCapacity(source.tokenCount * MemoryLayout<UInt32>.size)
        var offsets: [UInt32] = [0]
        offsets.reserveCapacity(min(source.tokenCount + 1, 1_000_000))
        var strings = Data()
        var surfaceIDs: [Data: UInt32] = [:]
        surfaceIDs.reserveCapacity(min(source.tokenCount, 1_000_000))

        for token in 0..<source.tokenCount {
            let sourceNode = try source.nativeSurfaceReference(at: token)
            if sourceNode < 0 {
                guard sourceNode == -1 || sourceNode == -2 else {
                    throw PersonalDataError("辞書の表記sentinelが不正です")
                }
                appendLE(UInt32(bitPattern: Int32(sourceNode)), to: &refs)
                continue
            }
            guard sourceNode <= Int64(Int.max) else { throw PersonalDataError("辞書の表記参照が大きすぎます") }
            let nodeIndex = try rank.inclusiveRank(at: Int(sourceNode))
            guard nodeIndex > 0, nodeIndex < source.surfaceParents.count else {
                throw PersonalDataError("辞書の表記ノードが範囲外です")
            }
            let encodedSurface = try surfaceBytes(nodeIndex: nodeIndex, source: source)
            let surfaceID: UInt32
            if let existing = surfaceIDs[encodedSurface] {
                surfaceID = existing
            } else {
                guard offsets.count <= Int(UInt32.max),
                      encodedSurface.count <= Int(UInt32.max) - strings.count else {
                    throw PersonalDataError("辞書の表記領域が4 GiBを超えています")
                }
                surfaceID = UInt32(offsets.count - 1)
                surfaceIDs[encodedSurface] = surfaceID
                strings.append(encodedSurface)
                offsets.append(UInt32(strings.count))
            }
            appendLE(surfaceID, to: &refs)
        }

        let positions = source.isEnglish
            ? Data(repeating: 0, count: source.tokenCount * MemoryLayout<UInt16>.size)
            : try tokens[0].littleEndianData()
        let costs = try tokens[costColumn].littleEndianData()
        let terms = try reading[3].littleEndianData()
        let postings = uint32Data(source.postingOffsets)
        let surfaceOffsets = uint32Data(offsets)

        return [
            try reading[0].littleEndianData(),
            try reading[2].littleEndianData(),
            try reading[1].littleEndianData(),
            terms,
            postings,
            positions,
            costs,
            refs,
            surfaceOffsets,
            strings
        ]
    }

    private static func surfaceBytes(nodeIndex start: Int, source: ValidatedDictionarySource) throws -> Data {
        let labels = source.surface[2]
        var units: [UInt16] = []
        var node = start
        while node > 1 {
            guard node < labels.count, node < source.surfaceParents.count,
                  units.count < 4096 else { throw PersonalDataError("辞書の表記経路が不正です") }
            let label = try labels.unsigned(at: node)
            guard label <= UInt64(UInt16.max) else { throw PersonalDataError("辞書の表記文字が不正です") }
            units.append(UInt16(label))
            let parent = Int(source.surfaceParents[node])
            guard parent < node else { throw PersonalDataError("辞書の表記経路が循環しています") }
            node = parent
        }
        guard node == 1 else { throw PersonalDataError("辞書の表記経路がrootに接続していません") }
        let orderedUnits = Array(units.reversed())
        let text = String(decoding: orderedUnits, as: UTF16.self)
        guard Array(text.utf16) == orderedUnits else {
            throw PersonalDataError("辞書の表記に不正なUTF-16があります")
        }
        return Data(text.utf8)
    }

    private static func uint32Data(_ values: [UInt32]) -> Data {
        var data = Data()
        data.reserveCapacity(values.count * MemoryLayout<UInt32>.size)
        for value in values { appendLE(value, to: &data) }
        return data
    }

    private static func appendLE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private struct LOUDSRank {
        let words: DictionaryPrimitiveArray
        let prefix: [UInt32]

        init(_ words: DictionaryPrimitiveArray) throws {
            self.words = words
            var prefix: [UInt32] = [0]
            prefix.reserveCapacity(words.count + 1)
            for index in 0..<words.count {
                let count = prefix[index] + UInt32(try words.unsigned(at: index).nonzeroBitCount)
                prefix.append(count)
            }
            self.prefix = prefix
        }

        func inclusiveRank(at bitPosition: Int) throws -> Int {
            guard bitPosition >= 0 else { throw PersonalDataError("辞書の表記参照が負数です") }
            let wordIndex = bitPosition / 64
            guard wordIndex < words.count else { throw PersonalDataError("辞書の表記参照が範囲外です") }
            let bit = bitPosition % 64
            let mask = UInt64.max >> (63 - bit)
            let partial = try words.unsigned(at: wordIndex) & mask
            return Int(prefix[wordIndex] + UInt32(partial.nonzeroBitCount))
        }
    }
}
