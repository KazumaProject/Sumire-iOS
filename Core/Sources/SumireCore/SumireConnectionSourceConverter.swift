import Foundation

public struct ValidatedConnectionSource {
    public let dimension: Int
    let leftPOS: DictionaryPrimitiveArray
    let rightPOS: DictionaryPrimitiveArray
    let matrix: Data

    fileprivate init(dimension: Int, leftPOS: DictionaryPrimitiveArray,
                     rightPOS: DictionaryPrimitiveArray, matrix: Data) {
        self.dimension = dimension
        self.leftPOS = leftPOS
        self.rightPOS = rightPOS
        self.matrix = matrix
    }
}

public enum ConnectionSourceValidation {
    public static func validate(posTable: [DictionaryPrimitiveArray], matrix: Data,
                                maximumDimension: Int = 8192) throws -> ValidatedConnectionSource {
        guard posTable.map(\.kind) == [.shorts, .shorts],
              posTable[0].count > 0, posTable[0].count == posTable[1].count,
              maximumDimension > 0, maximumDimension <= 8192,
              matrix.count > 0, matrix.count.isMultiple(of: MemoryLayout<Int16>.size),
              matrix.count <= maximumDimension * maximumDimension * MemoryLayout<Int16>.size,
              matrix.count <= 128 * 1024 * 1024 else {
            throw PersonalDataError("接続コスト辞書の品詞表が不正です")
        }
        let cells = matrix.count / MemoryLayout<Int16>.size
        let dimension = Int(Double(cells).squareRoot())
        guard dimension > 0, dimension * dimension == cells else {
            throw PersonalDataError("接続コスト行列のサイズが品詞表と一致しません")
        }
        for table in posTable {
            for index in 0..<table.count {
                let value = try table.signed(at: index)
                guard value >= 0, value < dimension else {
                    throw PersonalDataError("接続コスト辞書の品詞参照が範囲外です")
                }
            }
        }
        return ValidatedConnectionSource(dimension: dimension, leftPOS: posTable[0],
                                         rightPOS: posTable[1], matrix: matrix)
    }
}

public enum SumireConnectionSourceConverter {
    public static func write(_ source: ValidatedConnectionSource, to destination: URL) throws {
        let sections = try sections(for: source)
        try SumireDictionaryBinaryWriter.write(kind: .connection, dimension: UInt32(source.dimension),
                                               sections: sections, to: destination)
    }

    static func sections(for source: ValidatedConnectionSource) throws -> [Data] {
        let n = source.dimension
        let wordsPerRow = (n + 63) / 64
        var defaults = Data()
        defaults.reserveCapacity(n * MemoryLayout<Int16>.size)
        var bits = Data()
        bits.reserveCapacity(n * wordsPerRow * MemoryLayout<UInt64>.size)
        var values = Data()
        var starts = Data()
        starts.reserveCapacity((n + 1) * MemoryLayout<UInt32>.size)
        var ranks = Data()
        ranks.reserveCapacity(n * wordsPerRow * MemoryLayout<UInt16>.size)
        appendLE(UInt32(0), to: &starts)

        try source.matrix.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var rowValues = [Int16](repeating: 0, count: n)
            for row in 0..<n {
                var counts: [Int16: Int] = [:]
                counts.reserveCapacity(min(n, 4096))
                let rowStart = row * n
                for column in 0..<n {
                    let cell = rowStart + column
                    let byte = cell * MemoryLayout<Int16>.size
                    // connectionId.dat is a raw big-endian Java short matrix,
                    // unlike the primitive-array streams decoded above.
                    let rawValue = UInt16(bytes[byte]) << 8 | UInt16(bytes[byte + 1])
                    let value = Int16(bitPattern: rawValue)
                    rowValues[column] = value
                    counts[value, default: 0] += 1
                }

                // Python Counter.most_common(1) keeps the first-seen value on
                // ties; retain that rule so generated binaries stay identical.
                var defaultValue = rowValues[0]
                var defaultCount = 0
                for value in rowValues {
                    let count = counts[value, default: 0]
                    if count > defaultCount {
                        defaultValue = value
                        defaultCount = count
                    }
                }
                appendLE(UInt16(bitPattern: defaultValue), to: &defaults)

                var rank: UInt32 = 0
                for wordStart in stride(from: 0, to: n, by: 64) {
                    appendLE(UInt16(rank), to: &ranks)
                    var word: UInt64 = 0
                    let end = min(wordStart + 64, n)
                    for column in wordStart..<end where rowValues[column] != defaultValue {
                        word |= UInt64(1) << (column - wordStart)
                        appendLE(UInt16(bitPattern: rowValues[column]), to: &values)
                        rank += 1
                    }
                    appendLE(word, to: &bits)
                }
                let exceptionCount = values.count / MemoryLayout<Int16>.size
                guard exceptionCount <= Int(UInt32.max) else {
                    throw PersonalDataError("接続コスト例外が4 GiBを超えています")
                }
                appendLE(UInt32(exceptionCount), to: &starts)
            }
        }

        return [try source.leftPOS.littleEndianData(), try source.rightPOS.littleEndianData(),
                defaults, bits, values, starts, ranks]
    }

    private static func appendLE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendLE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func appendLE(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, to: 64, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}
