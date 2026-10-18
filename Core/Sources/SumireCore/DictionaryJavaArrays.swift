import Foundation

public enum DictionaryPrimitiveKind: Int {
    case shorts = 2, ints = 4, longs = 8, characters = 16
    fileprivate var width: Int { self == .characters ? 2 : rawValue }
}

/// A view of one primitive array; retaining it retains the input mapping.
public struct DictionaryPrimitiveArray {
    public let kind: DictionaryPrimitiveKind
    public let count: Int
    private let data: Data
    private let start: Int
    fileprivate init(kind: DictionaryPrimitiveKind, count: Int, data: Data, start: Int) {
        self.kind = kind; self.count = count; self.data = data; self.start = start
    }
    public func unsigned(at index: Int) throws -> UInt64 {
        guard index >= 0, index < count else { throw PersonalDataError("辞書配列の範囲外です") }
        var value: UInt64 = 0
        for i in 0..<kind.width { value = value << 8 | UInt64(data[start + index * kind.width + i]) }
        return value
    }
    public func signed(at index: Int) throws -> Int64 {
        let value = try unsigned(at: index), shift = 64 - kind.width * 8
        return Int64(bitPattern: value << shift) >> shift
    }
}

/// A deliberately limited Java serialization reader. It accepts only the
/// pinned dictionary's four primitive arrays and java.util.BitSet, never
/// constructs arbitrary objects or invokes serialized code.
public enum DictionaryJavaArrays {
    public static func read(_ data: Data, kinds: [DictionaryPrimitiveKind]) throws -> [DictionaryPrimitiveArray] {
        guard !kinds.isEmpty, kinds.count <= 16, data.count <= 512 * 1024 * 1024 else {
            throw PersonalDataError("辞書配列の数または容量が上限を超えています")
        }
        var reader = Reader(data: Data(data))
        guard try reader.number(4) == 0xaced0005 else { throw reader.error() }
        var result: [DictionaryPrimitiveArray] = []
        for kind in kinds {
            let array: DictionaryPrimitiveArray
            switch try reader.object() {
            case .array(let value), .bitset(let value): array = value
            default: throw reader.error()
            }
            guard array.kind == kind else { throw reader.error() }
            result.append(array)
        }
        guard reader.position == data.count else { throw reader.error() }
        return result
    }
    private enum Reference {
        case descriptor(String), string(String), array(DictionaryPrimitiveArray), bitset(DictionaryPrimitiveArray), pending
    }
    private struct Reader {
        let data: Data
        var position = 0, depth = 0
        var references: [Reference] = []
        func error() -> PersonalDataError { PersonalDataError("辞書配列が壊れているか、未対応のJava形式です") }
        mutating func number(_ width: Int) throws -> UInt64 {
            guard width > 0, position <= data.count - width else { throw error() }
            var value: UInt64 = 0
            for _ in 0..<width { value = value << 8 | UInt64(data[position]); position += 1 }
            return value
        }
        mutating func text() throws -> String {
            let size = Int(try number(2))
            // All supported descriptor/field names are ASCII and at most 16 bytes.
            guard size <= 32, size <= data.count - position else { throw error() }
            let bytes = data[position..<position + size]; position += size
            guard bytes.allSatisfy({ $0 > 0 && $0 < 128 }), let text = String(data: bytes, encoding: .ascii) else { throw error() }
            return text
        }
        mutating func append(_ value: Reference) throws -> Int {
            guard references.count < 4096 else { throw error() }
            references.append(value); return references.count - 1
        }
        mutating func reference() throws -> Reference {
            let handle = try number(4)
            guard handle >= 0x7e0000, handle - 0x7e0000 < references.count else { throw error() }
            let value = references[Int(handle - 0x7e0000)]
            if case .pending = value { throw error() }
            return value
        }
        mutating func descriptor() throws -> String? {
            guard depth < 16 else { throw error() }
            depth += 1; defer { depth -= 1 }
            switch try number(1) {
            case 0x70: return nil
            case 0x71:
                guard case .descriptor(let name) = try reference() else { throw error() }; return name
            case 0x72:
                let name = try text(), uid = try number(8)
                let uids: [String: UInt64] = ["[S":0xef832e06e55db0fa, "[I":0x4dba602676eab2a5,
                    "[J":0x782004b512b17593, "[C":0xb02666b0e25d84ac, "java.util.BitSet":0x6efd887e3934ab21]
                guard uids[name] == uid else { throw error() }
                _ = try append(.descriptor(name))
                let flags = try number(1), fields = try number(2)
                if name == "java.util.BitSet" {
                    guard flags == 3, fields == 1, try number(1) == 0x5b, try text() == "bits",
                          case .string("[J") = try object() else { throw error() }
                } else { guard flags == 2, fields == 0 else { throw error() } }
                guard try number(1) == 0x78, try descriptor() == nil else { throw error() }
                return name
            default: throw error()
            }
        }
        mutating func object() throws -> Reference {
            guard depth < 16 else { throw error() }
            depth += 1; defer { depth -= 1 }
            switch try number(1) {
            case 0x71: return try reference()
            case 0x74:
                let value = try text(); guard value == "[J" else { throw error() }
                let ref = Reference.string(value); _ = try append(ref); return ref
            case 0x75:
                guard let name = try descriptor() else { throw error() }
                let kinds: [String: DictionaryPrimitiveKind] = ["[S":.shorts, "[I":.ints, "[J":.longs, "[C":.characters]
                guard let kind = kinds[name] else { throw error() }
                let index = try append(.pending), count = try number(4)
                // Negative Java lengths and multiplication overflow are rejected
                // before constructing any view or allocating element storage.
                guard count <= 0x7fffffff, count <= (data.count - position) / kind.width else { throw error() }
                let array = DictionaryPrimitiveArray(kind: kind, count: Int(count), data: data, start: position)
                position += Int(count) * kind.width
                let ref = Reference.array(array); references[index] = ref; return ref
            case 0x73:
                guard try descriptor() == "java.util.BitSet" else { throw error() }
                let index = try append(.pending)
                guard case .array(let bits) = try object(), bits.kind == .longs,
                      try number(1) == 0x78 else { throw error() }
                let ref = Reference.bitset(bits); references[index] = ref; return ref
            default: throw error()
            }
        }
    }
}
