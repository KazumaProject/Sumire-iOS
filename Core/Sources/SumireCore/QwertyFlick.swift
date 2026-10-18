import Foundation

/// Letter-page mappings without the optional number row, pinned df1f383.
/// QWERTYKeyInfo first variation supplies up; handleDownFlick supplies uppercase.
public enum QwertyFlick {
    /// Char.toRomajiQwertyOutputChar: only ASCII digits/symbols obey the
    /// half-width preferences; Japanese punctuation and currency are preserved.
    public static func japaneseWidth(_ text: String, halfWidthNumbers: Bool, halfWidthSymbols: Bool) -> String {
        text.unicodeScalars.map { scalar in
            let raw = scalar.value
            let half = (0xff01...0xff5e).contains(raw) ? raw - 0xfee0 : raw
            let digit = (0x30...0x39).contains(half)
            let symbol = (0x21...0x2f).contains(half) || (0x3a...0x40).contains(half) ||
                (0x5b...0x60).contains(half) || (0x7b...0x7e).contains(half)
            if digit && halfWidthNumbers || symbol && halfWidthSymbols { return String(UnicodeScalar(half)!) }
            if (0x21...0x7e).contains(raw) { return String(UnicodeScalar(raw + 0xfee0)!) }
            if raw == 0x20 { return "　" }
            return String(scalar)
        }.joined()
    }
    public static func outputs(for label: String, japanese: Bool, up: Bool, down: Bool) -> [String] {
        guard let pair = (japanese ? self.japanese : english)[label.lowercased()] else { return [label, "", "", "", ""] }
        let uppercase = label != label.lowercased()
        let lowerOutput = label.uppercased().unicodeScalars.map { scalar -> String in
            if japanese && (0x21...0x7e).contains(scalar.value), let wide = UnicodeScalar(scalar.value + 0xfee0) { return String(wide) }
            return String(scalar)
        }.joined()
        return [label, "", up ? pair[uppercase ? 1 : 0] : "", "", down ? lowerOutput : ""]
    }
    private static let english: [String: [String]] = [
        "a": ["@", "@"],
        "b": [";", ";"],
        "c": ["'", "\""],
        "d": ["$", "$"],
        "e": ["3", "3"],
        "f": ["_", "_"],
        "g": ["&", "&"],
        "h": ["-", "-"],
        "i": ["8", "8"],
        "j": ["+", "+"],
        "k": ["(", "("],
        "l": [")", ")"],
        "m": ["?", "?"],
        "n": ["!", "!"],
        "o": ["9", "9"],
        "p": ["0", "0"],
        "q": ["1", "1"],
        "r": ["4", "4"],
        "s": ["#", "#"],
        "t": ["5", "5"],
        "u": ["7", "7"],
        "v": [":", ":"],
        "w": ["2", "2"],
        "x": ["\"", "\""],
        "y": ["6", "6"],
        "z": ["*", "*"]
    ]
    private static let japanese: [String: [String]] = [
        "a": ["＠", "＠"],
        "b": ["；", "；"],
        "c": ["’", "’"],
        "d": ["￥", "￥"],
        "e": ["３", "３"],
        "f": ["＿", "＿"],
        "g": ["＆", "＆"],
        "h": ["ー", "ー"],
        "i": ["８", "８"],
        "j": ["＋", "＋"],
        "k": ["（", "（"],
        "l": ["）", "）"],
        "m": ["？", "？"],
        "n": ["！", "！"],
        "o": ["９", "９"],
        "p": ["０", "０"],
        "q": ["１", "１"],
        "r": ["４", "４"],
        "s": ["＃", "＃"],
        "t": ["５", "５"],
        "u": ["７", "７"],
        "v": ["：", "："],
        "w": ["２", "２"],
        "x": ["”", "”"],
        "y": ["６", "６"],
        "z": ["＊", "＊"],
        "ー": ["/", "/"]
    ]

    /// Number/symbol pages: tap and first variation come from KeyMap/KeyInfo,
    /// independently of the displayed QWERTYKeys label. Japanese uses reference width defaults.
    public static func pageOutputs(for label: String, page: Int, japanese: Bool, up: Bool, down: Bool) -> [String] {
        guard page == 1 || page == 2 else { return [] }
        let table = japanese ? (page == 1 ? page2 : page3) : (page == 1 ? page0 : page1)
        guard let pair = table[label] else { return [] }
        func width(_ text: String) -> String {
            guard japanese else { return text }
            return text.unicodeScalars.map { scalar in
                if (0x21...0x7e).contains(scalar.value), let wide = UnicodeScalar(scalar.value + 0xfee0) { return String(wide) }
                return String(scalar)
            }.joined()
        }
        return [width(pair[0]), "", up ? width(pair[1]) : "", "", down ? width(label.uppercased()) : ""]
    }
    private static let page0: [String: [String]] = [
        "1": ["1", "１"],
        "2": ["2", "２"],
        "3": ["3", "３"],
        "4": ["4", "４"],
        "5": ["5", "５"],
        "6": ["6", "６"],
        "7": ["7", "7"],
        "8": ["8", "８"],
        "9": ["9", "９"],
        "0": ["0", "０"],
        "-": ["-", "-"],
        "/": ["/", "/"],
        ":": [":", ""],
        ";": [";", ""],
        "(": ["(", "("],
        ")": [")", ")"],
        "¥": ["¥", ""],
        "&": ["&", ""],
        "@": ["@", ""],
        "\"": ["\"", "\""],
        ".": [".", "."],
        ",": [",", "、"],
        "?": ["?", "?"],
        "!": ["!", "!"],
        "'": ["'", "'"]
    ]
    private static let page1: [String: [String]] = [
        "[": ["[", ""],
        "]": ["]", ""],
        "{": ["{", ""],
        "}": ["}", ""],
        "#": ["#", "#"],
        "%": ["%", "%"],
        "^": ["^", "^"],
        "*": ["*", "*"],
        "+": ["+", "+"],
        "=": ["=", "="],
        "_": ["_", ""],
        "/": ["/", "/"],
        "\\": ["\\", ""],
        "~": ["~", ""],
        "<": ["<", ""],
        ">": [">", ""],
        "$": ["$", "$"],
        "€": ["€", ""],
        "£": ["£", ""],
        "·": ["·", ""],
        ".": [".", "."],
        ",": [",", "、"],
        "?": ["?", "?"],
        "!": ["!", "!"],
        "'": ["'", "'"]
    ]
    private static let page2: [String: [String]] = [
        "1": ["1", "１"],
        "2": ["2", "２"],
        "3": ["3", "３"],
        "4": ["4", "４"],
        "5": ["5", "５"],
        "6": ["6", "６"],
        "7": ["7", "７"],
        "8": ["8", "８"],
        "9": ["9", "９"],
        "0": ["0", "０"],
        "-": ["-", "-"],
        "/": ["/", "/"],
        ":": [":", ""],
        "@": ["@", ""],
        "(": ["(", "("],
        ")": [")", ")"],
        "「": ["「", ""],
        "」": ["」", ""],
        "￥": ["¥", ""],
        "&": ["&", ""],
        "。": ["。", "。"],
        "、": ["、", "、"],
        "?": ["?", "?"],
        "!": ["!", "!"],
        "'": ["'", "'"]
    ]
    private static let page3: [String: [String]] = [
        "[": ["[", ""],
        "]": ["]", ""],
        "{": ["{", ""],
        "}": ["}", ""],
        "#": ["#", "#"],
        "%": ["%", "%"],
        "^": ["^", "^"],
        "*": ["*", "*"],
        "+": ["+", "+"],
        "=": ["=", "="],
        "_": ["_", ""],
        "/": ["/", "/"],
        ";": [";", ""],
        "|": ["|", ""],
        "<": ["<", ""],
        ">": [">", ""],
        "\"": ["\"", "\""],
        "'": ["'", "'"],
        "$": ["$", "$"],
        "€": ["€", ""],
        ".": [".", "."],
        ",": [",", "、"],
        "?": ["?", "?"],
        "!": ["!", "!"],
        "・": ["·", ""]
    ]
}
