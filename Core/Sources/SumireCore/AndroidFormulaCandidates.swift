import Foundation

/// The two text forms emitted by Android's offline formula-candidate feature.
public struct AndroidFormulaRendering: Equatable, Sendable {
    public let unicodeText: String
    public let normalizedTex: String

    public init(unicodeText: String, normalizedTex: String) {
        self.unicodeText = unicodeText
        self.normalizedTex = normalizedTex
    }
}

/// Local, bounded formula parsing and preference policy shared by the app and keyboard extension.
/// Unsupported syntax is rejected instead of being offered as a conversion candidate.
public enum AndroidFormulaCandidatePolicy {
    public static let enabledKey = "utilityFormulaCandidateEnabled"

    public static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
    }

    public static func candidates(for input: String, enabled: Bool = true) -> [AndroidFormulaRendering] {
        guard enabled, let rendering = parse(input) else { return [] }
        let source = normalize(input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard rendering.unicodeText != source || rendering.normalizedTex != source else { return [] }
        return [rendering]
    }

    public static func isCanonicalTexSource(_ source: String, rendering: AndroidFormulaRendering) -> Bool {
        rendering.normalizedTex == source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses the documented shorthand and a deliberately bounded TeX subset.
    public static func parse(_ input: String) -> AndroidFormulaRendering? {
        guard let node = parseNode(input) else { return nil }
        let rendered = AndroidFormulaRendering(
            unicodeText: FormulaTextRenderer.unicode(node),
            normalizedTex: FormulaTextRenderer.tex(node)
        )
        guard !rendered.unicodeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rendered.normalizedTex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return rendered
    }

    /// Produces the same font-independent drawing plan used by Android's FormulaView.
    /// The caller supplies platform text metrics; this method neither evaluates nor commits text.
    public static func layout(
        for input: String,
        config: AndroidFormulaLayoutConfig = AndroidFormulaLayoutConfig(),
        measureText: (String, Double) -> Double = { value, size in Double(value.utf16.count) * size * 0.58 }
    ) -> AndroidFormulaLayout? {
        guard let node = parseNode(input) else { return nil }
        return AndroidFormulaLayoutEngine.layout(node, config: config, measureText: measureText)
    }

    private static func parseNode(_ input: String) -> FormulaNode? {
        guard input.unicodeScalars.count <= 200, input.utf16.count <= 255 else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" || $0 == "`" || $0 == "\"" || $0 == "'" }),
              !trimmed.contains(";"),
              !trimmed.contains("//"), !trimmed.contains("/*"), !trimmed.contains("*/"),
              !trimmed.contains("://"),
              !(trimmed.hasPrefix("<") && trimmed.hasSuffix(">")),
              !trimmed.contains("@"),
              trimmed.range(of: #"(?i)^(?:fun|val|var|const|let|return|class|object|function|def|public|private|protected|new|if|else|for|while|switch|case|try|catch|throw|interface|package|import|select|insert|update|delete)\b"#, options: .regularExpression) == nil else { return nil }

        var source = normalize(trimmed)
        if source.hasPrefix("$$"), source.hasSuffix("$$"), source.count > 4 {
            source = String(source.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if source.hasPrefix("$"), source.hasSuffix("$"), source.count > 2 {
            source = String(source.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if source.contains("$") {
            return nil
        }
        guard !source.isEmpty, !source.hasPrefix("^") && !source.hasPrefix("_") else { return nil }

        var parser = FormulaExpressionParser(source)
        guard let node = parser.parse(), isMathLike(source, node: node) else { return nil }
        return node
    }

    private static func normalize(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
            let value = scalar.value
            if (0xFF01...0xFF5E).contains(value), let mapped = UnicodeScalar(value - 0xFEE0) { return mapped }
            if value == 0x3000 || value == 0x00A0 || (0x2000...0x200A).contains(value) || value == 0x202F || value == 0x205F {
                return UnicodeScalar(0x20)!
            }
            switch value {
            case 0x00D7: return UnicodeScalar(0x2A)!
            case 0x00F7: return UnicodeScalar(0x2F)!
            case 0x2212, 0x2013, 0x2014: return UnicodeScalar(0x2D)!
            default: return scalar
            }
        }))
    }

    private static func isMathLike(_ source: String, node: FormulaNode) -> Bool {
        if source.contains("\\") { return true }
        if source == "e" { return true }
        if source.contains(where: { "^_=/+*%!<>≤≥≠≈≃≡≢≅≍≰≱∼∝→⇒↔⇔←↦⟶⟹⟷⟺⟵⟼√|‖∥∣×÷±∓⋅⊄⊅⊈⊉∈∉∋⊂⊆⊃⊇∪∩∧∨¬⌊⌋⌈⌉⟨⟩".contains($0) }) { return true }
        if source.contains(where: { "πΠ∞∑∏∫∬∭∮∂∇∀∃ℕℤℚℝℂℵαβγδεζηθικλμνξοπρστυφχψωϵεϑϕφςϖϱΓΔΘΛΞΣΥΦΨΩ".contains($0) }) { return true }
        if source.range(of: #"(?i)(?:^|[^a-z])(?:sqrt|root|nroot|sum|sigma|prod|product|int|integral|lim|abs|norm|floor|ceil|vec|hat|bar|dot|ddot|tilde|underline|bold)\s*[({]"#, options: .regularExpression) != nil { return true }
        return node.containsMathStructure || node.containsMathSymbol
    }
}

indirect enum FormulaNode {
    case number(String)
    case symbol(String, tex: String? = nil)
    case row([FormulaNode])
    case fraction(FormulaNode, FormulaNode)
    case script(FormulaNode, sub: FormulaNode?, super: FormulaNode?, subGrouped: Bool, superGrouped: Bool)
    case radical(FormulaNode, index: FormulaNode?, grouped: Bool)
    case largeOperator(String, lower: FormulaNode?, upper: FormulaNode?, operand: FormulaNode?)
    case accent(String, FormulaNode, unicodeMark: String?)
    case delimited(String, FormulaNode, String, latexSized: Bool)

    var containsMathStructure: Bool {
        switch self {
        case .fraction, .script, .radical, .largeOperator, .accent: true
        case .row(let nodes): nodes.contains(where: \.containsMathStructure)
        case .delimited(_, let node, _, _): node.containsMathStructure
        case .number, .symbol: false
        }
    }

    var containsMathSymbol: Bool {
        switch self {
        case .symbol(let value, let tex): tex != nil || Greek.tex[value] != nil
        case .row(let nodes): nodes.contains(where: \.containsMathSymbol)
        case .delimited(_, let node, _, _): node.containsMathSymbol
        default: false
        }
    }
}

private struct FormulaExpressionParser {
    private let characters: [Character]
    private var index = 0
    private var depth = 0
    private var tokens = 0

    init(_ source: String) { characters = Array(source) }

    mutating func parse() -> FormulaNode? {
        guard let node = relation(stoppingAt: []), tokens <= 128 else { return nil }
        spaces()
        return index == characters.count ? node : nil
    }

    private mutating func relation(stoppingAt stop: Set<Character>) -> FormulaNode? {
        guard var left = additive(stoppingAt: stop) else { return nil }
        while true {
            spaces()
            guard !atStop(stop) else { break }
            if let op = relationOperator() {
                guard let right = additive(stoppingAt: stop) else { return nil }
                left = row([left, .symbol(op, tex: relationTex[op]), right])
            } else if consume(",") {
                tokens += 1
                guard let right = additive(stoppingAt: stop) else { return nil }
                left = row([left, .symbol(","), right])
            } else { break }
        }
        return left
    }

    private mutating func additive(stoppingAt stop: Set<Character>) -> FormulaNode? {
        guard var left = multiplicative(stoppingAt: stop) else { return nil }
        while true {
            spaces()
            guard !atStop(stop), let c = peek, c == "+" || (c == "-" && !matches("->")) else { break }
            index += 1; tokens += 1
            guard let right = multiplicative(stoppingAt: stop) else { return nil }
            left = row([left, .symbol(String(c)), right])
        }
        return left
    }

    private mutating func multiplicative(stoppingAt stop: Set<Character>) -> FormulaNode? {
        guard var left = unary(stoppingAt: stop) else { return nil }
        while true {
            spaces()
            guard !atStop(stop), let c = peek else { break }
            if ["*", "×", "⋅", "/", "÷"].contains(c) {
                index += 1; tokens += 1
                guard let right = unary(stoppingAt: stop) else { return nil }
                if c == "/" || c == "÷" { left = .fraction(left, right) }
                else { left = row([left, .symbol(c == "*" ? "×" : String(c), tex: c == "*" || c == "×" ? "\\times" : "\\cdot"), right]) }
            } else if startsPrimary(c), !stop.contains(c) {
                guard let right = unary(stoppingAt: stop) else { return nil }
                if case .largeOperator(let name, let lower, let upper, nil) = left {
                    left = .largeOperator(name, lower: lower, upper: upper, operand: right)
                } else {
                    left = row([left, right])
                }
            } else { break }
        }
        return left
    }

    private mutating func unary(stoppingAt stop: Set<Character>) -> FormulaNode? {
        spaces()
        if let c = peek, c == "+" || c == "-" {
            index += 1; tokens += 1
            guard let value = unary(stoppingAt: stop) else { return nil }
            return row([.symbol(String(c)), value])
        }
        return postfix(stoppingAt: stop)
    }

    private mutating func postfix(stoppingAt stop: Set<Character>) -> FormulaNode? {
        guard var base = primary(stoppingAt: stop) else { return nil }
        var sub: FormulaNode?, sup: FormulaNode?
        var subGrouped = false, supGrouped = false
        while true {
            spaces()
            guard let c = peek, c == "_" || c == "^" else { break }
            index += 1; tokens += 1
            guard let operand = scriptOperand(stoppingAt: stop) else { return nil }
            if c == "_" { guard sub == nil else { return nil }; sub = operand.node; subGrouped = operand.grouped }
            else { guard sup == nil else { return nil }; sup = operand.node; supGrouped = operand.grouped }
        }
        if let c = peek, c == "!" || c == "%" { index += 1; base = row([base, .symbol(String(c))]); tokens += 1 }
        if sub != nil || sup != nil {
            if case .largeOperator(let name, let currentSub, let currentSuper, let operand) = base {
                guard sub == nil || currentSub == nil, sup == nil || currentSuper == nil else { return nil }
                base = .largeOperator(name, lower: sub ?? currentSub, upper: sup ?? currentSuper, operand: operand)
            } else {
                base = .script(base, sub: sub, super: sup, subGrouped: subGrouped, superGrouped: supGrouped)
            }
        }
        return base
    }

    private mutating func scriptOperand(stoppingAt stop: Set<Character>) -> (node: FormulaNode, grouped: Bool)? {
        spaces()
        if consume("(") {
            guard enterDepth(), let value = relation(stoppingAt: [")"]), consume(")") else { return nil }
            leaveDepth(); return (value, true)
        }
        if consume("{") {
            guard enterDepth(), let value = relation(stoppingAt: ["}"]), consume("}") else { return nil }
            leaveDepth(); return (value, false)
        }
        return primary(stoppingAt: stop).map { ($0, false) }
    }

    private mutating func primary(stoppingAt stop: Set<Character>) -> FormulaNode? {
        spaces()
        guard let c = peek, !atStop(stop), !["+", "-", "*", "/", "^", "_", "=", ")", "}", "]"].contains(c) else { return nil }
        if consume("(") {
            guard enterDepth(), let value = relation(stoppingAt: [")"]), consume(")") else { return nil }
            leaveDepth(); return .delimited("(", value, ")", latexSized: false)
        }
        if consume("{") {
            guard enterDepth(), let value = relation(stoppingAt: ["}"]), consume("}") else { return nil }
            leaveDepth(); return value
        }
        if c == "\\" { return latexCommand() }
        if matches("||") { return literalDelimited("||", "||", left: "‖", right: "‖") }
        if c == "|" { return literalDelimited("|", "|", left: "|", right: "|") }
        if c == "‖" { return literalDelimited("‖", "‖", left: "‖", right: "‖") }
        if c == "⌊" { return literalDelimited("⌊", "⌋", left: "⌊", right: "⌋") }
        if c == "⌈" { return literalDelimited("⌈", "⌉", left: "⌈", right: "⌉") }
        if c == "⟨" { return literalDelimited("⟨", "⟩", left: "⟨", right: "⟩") }
        if c.isNumber {
            let start = index
            while let digit = peek, digit.isNumber || digit == "." { index += 1 }
            tokens += 1
            return .number(String(characters[start..<index]))
        }
        if c.isLetter {
            let word = identifier()
            tokens += 1
            let canonical = Greek.unicode[word] ?? word
            spaces()
            if let operatorName = largeOperatorNames[word], !["min", "max"].contains(word), consume("(") {
                guard let arguments = argumentListAfterOpeningParen() else { return nil }
                if operatorName == "lim", arguments.count == 2 {
                    return .largeOperator(operatorName, lower: arguments[0], upper: nil, operand: arguments[1])
                }
                guard arguments.count == 3 else { return nil }
                return .largeOperator(operatorName, lower: arguments[0], upper: arguments[1], operand: arguments[2])
            }
            if ["root", "nroot"].contains(word), consume("(") {
                guard let arguments = argumentListAfterOpeningParen(), arguments.count == 2 else { return nil }
                return .radical(arguments[1], index: arguments[0], grouped: false)
            }
            if ["min", "max"].contains(word), consume("(") {
                guard let arguments = argumentListAfterOpeningParen(), arguments.count >= 2 else { return nil }
                return row([.symbol(word, tex: "\\" + word), .delimited("(", row(arguments), ")", latexSized: false)])
            }
            if let function = mathFunctions[word], consume("(") {
                guard enterDepth(), let argument = relation(stoppingAt: [")"]), consume(")") else { return nil }
                leaveDepth()
                if function == "sqrt" { return .radical(argument, index: nil, grouped: true) }
                if let accent = accentFunctions[function] {
                    return .accent(accent.command, argument, unicodeMark: accent.unicodeMark)
                }
                switch function {
                case "abs": return .delimited("|", argument, "|", latexSized: false)
                case "norm": return .delimited("‖", argument, "‖", latexSized: false)
                case "floor": return .delimited("⌊", argument, "⌋", latexSized: false)
                case "ceil": return .delimited("⌈", argument, "⌉", latexSized: false)
                default: return row([.symbol(function, tex: "\\" + function), .delimited("(", argument, ")", latexSized: false)])
                }
            }
            if let symbol = namedSymbols[word] ?? namedSymbols[word.lowercased()] {
                return .symbol(symbol.unicode, tex: symbol.tex)
            }
            if let operatorName = largeOperatorNames[word] {
                return .largeOperator(operatorName, lower: nil, upper: nil, operand: nil)
            }
            return .symbol(canonical, tex: Greek.tex[canonical])
        }
        if c == "\\" { return nil }
        index += 1; tokens += 1
        if let symbol = symbolMap[String(c)] {
            if let name = largeOperatorNameBySymbol[symbol.unicode] {
                return .largeOperator(name, lower: nil, upper: nil, operand: nil)
            }
            return .symbol(symbol.unicode, tex: symbol.tex)
        }
        return .symbol(String(c))
    }

    private mutating func latexCommand() -> FormulaNode? {
        guard consume("\\") else { return nil }
        let command = identifier()
        if command.isEmpty {
            guard let spacing = peek, latexSpacingCharacters.contains(spacing) else { return nil }
            index += 1; tokens += 1
            return .symbol("")
        }
        tokens += 1
        if command == "left" { return sizedDelimited() }
        if let pair = pairedLatexDelimiters[command] {
            return pairedCommandDelimited(
                left: pair.left,
                openingCommand: command,
                rightCommand: pair.rightCommand,
                right: pair.right
            )
        }
        if command == "frac" || command == "dfrac" || command == "tfrac" {
            guard let numerator = requiredGroup(), let denominator = requiredGroup() else { return nil }
            return .fraction(numerator, denominator)
        }
        if command == "sqrt" {
            spaces()
            var index: FormulaNode?
            if consume("[") {
                guard enterDepth(), let parsedIndex = relation(stoppingAt: ["]"]), consume("]") else { return nil }
                leaveDepth()
                index = parsedIndex
            }
            guard let radicand = requiredGroup() else { return nil }
            return .radical(radicand, index: index, grouped: false)
        }
        if let accent = accentFunctions[command] {
            guard let base = requiredGroup() else { return nil }
            return .accent(accent.command, base, unicodeMark: accent.unicodeMark)
        }
        if command == "boldsymbol" {
            guard let base = requiredGroup() else { return nil }
            return .accent("mathbf", base, unicodeMark: nil)
        }
        if command == "mathbb" {
            guard let group = requiredGroup(), case .symbol(let value, _) = group,
                  let tex = Greek.blackboard[value] else { return nil }
            return .symbol(tex.glyph, tex: tex.command)
        }
        if command == "Bbb" {
            guard let group = requiredGroup(), case .symbol(let value, _) = group,
                  let tex = Greek.blackboard[value] else { return nil }
            return .symbol(tex.glyph, tex: tex.command)
        }
        if command == "operatorname" || command == "text" || command == "mathrm" {
            guard let base = requiredGroup() else { return nil }
            let text = FormulaTextRenderer.unicode(base)
            if command == "operatorname" {
                return .symbol(text, tex: "\\operatorname{" + text + "}")
            }
            return .symbol(text, tex: "\\" + command + "{" + text + "}")
        }
        if command == "not" {
            guard let next = latexCommand() else { return nil }
            let unicode = FormulaTextRenderer.unicode(next)
            let negated: [String: String] = ["=":"≠", "∈":"∉", "≡":"≢", "⊂":"⊄", "⊃":"⊅", "⊆":"⊈", "⊇":"⊉"]
            if let result = negated[unicode] {
                return .symbol(result, tex: "\\not" + FormulaTextRenderer.tex(next))
            }
            return row([.symbol("¬", tex: "\\neg"), next])
        }
        if command == "mathcal" || command == "mathsf" || command == "mathtt" || command == "mathit" || command == "mathnormal" {
            guard let base = requiredGroup() else { return nil }
            return .symbol(FormulaTextRenderer.unicode(base), tex: "\\" + command + "{" + FormulaTextRenderer.tex(base) + "}")
        }
        if let operatorName = largeOperatorNames[command] {
            return .largeOperator(operatorName, lower: nil, upper: nil, operand: nil)
        }
        if let glyph = Greek.commandToUnicode[command] { return .symbol(glyph, tex: "\\" + command) }
        if let glyph = commandSymbols[command] { return .symbol(glyph.unicode, tex: glyph.tex) }
        if mathFunctions[command] != nil { return .symbol(command, tex: "\\" + command) }
        if latexSpacingCommands.contains(command) { return .symbol("") }
        return nil
    }

    private mutating func sizedDelimited() -> FormulaNode? {
        guard let left = readDelimiter(), enterDepth(),
              let match = matchingCommand(from: index, opening: "left", closing: "right") else { return nil }
        let innerSource = String(characters[index..<match.commandStart])
        var innerParser = FormulaExpressionParser(innerSource)
        guard let content = innerParser.parse() else { return nil }
        tokens += innerParser.tokens
        guard tokens <= 128 else { return nil }
        index = match.commandEnd
        guard let right = readDelimiter() else { return nil }
        leaveDepth()
        return .delimited(left, content, right, latexSized: true)
    }

    private mutating func readDelimiter() -> String? {
        spaces()
        if consume("\\") {
            if peek?.isLetter == true {
                let command = identifier()
                return latexDelimiterCommands[command]
            }
            if consume("|") { return "‖" }
            guard let escaped = peek, "{}|".contains(escaped) else { return nil }
            index += 1
            return String(escaped)
        }
        guard let delimiter = peek, "()[]{}|.‖".contains(delimiter) else { return nil }
        index += 1
        return String(delimiter)
    }

    private func matchingCommand(
        from start: Int,
        opening: String?,
        closing: String
    ) -> (commandStart: Int, commandEnd: Int)? {
        var cursor = start
        var nested = 0
        while cursor < characters.count {
            guard characters[cursor] == "\\" else { cursor += 1; continue }
            let commandStart = cursor
            cursor += 1
            let nameStart = cursor
            while cursor < characters.count, characters[cursor].isLetter { cursor += 1 }
            guard cursor > nameStart else { continue }
            let command = String(characters[nameStart..<cursor])
            if let opening, command == opening { nested += 1 }
            else if command == closing {
                if nested == 0 { return (commandStart, cursor) }
                nested -= 1
            }
        }
        return nil
    }

    private mutating func requiredGroup() -> FormulaNode? {
        spaces()
        guard consume("{"), enterDepth(), let node = relation(stoppingAt: ["}"]), consume("}") else { return nil }
        leaveDepth(); return node
    }

    private mutating func literalDelimited(
        _ opening: String,
        _ closing: String,
        left: String,
        right: String
    ) -> FormulaNode? {
        guard consume(opening), enterDepth() else { return nil }
        defer { leaveDepth() }
        let closingCharacters = Set(closing)
        guard let content = relation(stoppingAt: closingCharacters), consume(closing) else { return nil }
        return .delimited(left, content, right, latexSized: false)
    }

    private mutating func pairedCommandDelimited(
        left: String,
        openingCommand: String,
        rightCommand: String,
        right: String
    ) -> FormulaNode? {
        guard enterDepth(), let match = matchingCommand(from: index, opening: openingCommand, closing: rightCommand) else { return nil }
        let innerSource = String(characters[index..<match.commandStart])
        var innerParser = FormulaExpressionParser(innerSource)
        guard let content = innerParser.parse() else { return nil }
        tokens += innerParser.tokens
        guard tokens <= 128 else { return nil }
        index = match.commandEnd
        leaveDepth()
        return .delimited(left, content, right, latexSized: false)
    }

    private mutating func argumentListAfterOpeningParen() -> [FormulaNode]? {
        guard enterDepth() else { return nil }
        defer { leaveDepth() }
        if consume(")") { return [] }
        var arguments: [FormulaNode] = []
        while let argument = relation(stoppingAt: [",", ")"]) {
            arguments.append(argument)
            guard arguments.count <= 16 else { return nil }
            if consume(")") { return arguments }
            guard consume(",") else { return nil }
            tokens += 1
        }
        return nil
    }

    private mutating func relationOperator() -> String? {
        for (source, output) in [("<->", "↔"), ("=>", "⇒"), ("->", "→"), ("<=", "≤"), (">=", "≥"), ("!=", "≠"), ("==", "=")] {
            if matches(source) { index += source.count; tokens += 1; return output }
        }
        guard let c = peek, "=<>≤≥≠≈≃≡≢≅≍≰≱∼∝→⇒↔⇔←↦⟶⟹⟷⟺⟵⟼∈∉∋⊂⊆⊃⊇⊄⊅⊈⊉∪∩∧∨∥∣±∓".contains(c) else { return nil }
        index += 1; tokens += 1
        return String(c)
    }

    private mutating func identifier() -> String {
        let start = index
        while let c = peek, c.isLetter || c == "π" { index += 1 }
        return String(characters[start..<index])
    }

    private var peek: Character? { characters.indices.contains(index) ? characters[index] : nil }
    private mutating func consume(_ value: Character) -> Bool {
        guard peek == value else { return false }; index += 1; return true
    }
    private mutating func consume(_ value: String) -> Bool {
        guard matches(value) else { return false }; index += value.count; return true
    }
    private func matches(_ value: String) -> Bool {
        let values = Array(value)
        return index + values.count <= characters.count && Array(characters[index..<(index + values.count)]) == values
    }
    private mutating func spaces() { while peek?.isWhitespace == true { index += 1 } }
    private func atStop(_ stop: Set<Character>) -> Bool { peek.map(stop.contains) ?? false }
    private func startsPrimary(_ c: Character) -> Bool {
        c.isNumber || c.isLetter || c == "(" || c == "{" || c == "\\" || "π∞∑∏∫√αβγΔ".contains(c)
    }
    private mutating func enterDepth() -> Bool { depth += 1; return depth <= 32 && tokens <= 128 }
    private mutating func leaveDepth() { depth = max(0, depth - 1) }
    private func row(_ nodes: [FormulaNode]) -> FormulaNode {
        let flattened = nodes.flatMap { node -> [FormulaNode] in if case .row(let children) = node { return children }; return [node] }
        return flattened.count == 1 ? flattened[0] : .row(flattened)
    }

    private static let relationTex: [String: String] = [
        "≤":"\\leq", "≥":"\\geq", "≠":"\\neq", "≈":"\\approx", "≃":"\\simeq", "≡":"\\equiv",
        "≢":"\\not\\equiv", "≅":"\\cong", "≍":"\\asymp", "≰":"\\nleq", "≱":"\\ngeq", "∼":"\\sim", "∝":"\\propto",
        "→":"\\to", "⇒":"\\Rightarrow", "↔":"\\leftrightarrow", "⇔":"\\Leftrightarrow", "←":"\\leftarrow", "↦":"\\mapsto",
        "⟶":"\\longrightarrow", "⟹":"\\Longrightarrow", "⟷":"\\longleftrightarrow", "⟺":"\\Longleftrightarrow", "⟵":"\\longleftarrow", "⟼":"\\longmapsto",
        "∈":"\\in", "∉":"\\notin", "∋":"\\ni", "⊂":"\\subset", "⊆":"\\subseteq", "⊃":"\\supset", "⊇":"\\supseteq",
        "⊄":"\\nsubset", "⊅":"\\nsupset", "⊈":"\\nsubseteq", "⊉":"\\nsupseteq", "∪":"\\cup", "∩":"\\cap",
        "∧":"\\land", "∨":"\\lor", "∥":"\\parallel", "∣":"\\mid", "±":"\\pm", "∓":"\\mp"
    ]
    private var relationTex: [String: String] { Self.relationTex }
}

private enum FormulaTextRenderer {
    private static let superscript: [Character: Character] = ["0":"⁰", "1":"¹", "2":"²", "3":"³", "4":"⁴", "5":"⁵", "6":"⁶", "7":"⁷", "8":"⁸", "9":"⁹", "+":"⁺", "-":"⁻", "−":"⁻", "=":"⁼", "(":"⁽", ")":"⁾", "a":"ᵃ", "b":"ᵇ", "c":"ᶜ", "d":"ᵈ", "e":"ᵉ", "f":"ᶠ", "g":"ᵍ", "h":"ʰ", "i":"ⁱ", "j":"ʲ", "k":"ᵏ", "l":"ˡ", "m":"ᵐ", "n":"ⁿ", "o":"ᵒ", "p":"ᵖ", "r":"ʳ", "s":"ˢ", "t":"ᵗ", "u":"ᵘ", "v":"ᵛ", "w":"ʷ", "x":"ˣ", "y":"ʸ", "z":"ᶻ"]
    private static let subscriptMap: [Character: Character] = ["0":"₀", "1":"₁", "2":"₂", "3":"₃", "4":"₄", "5":"₅", "6":"₆", "7":"₇", "8":"₈", "9":"₉", "+":"₊", "-":"₋", "−":"₋", "=":"₌", "(":"₍", ")":"₎", "a":"ₐ", "e":"ₑ", "h":"ₕ", "i":"ᵢ", "j":"ⱼ", "k":"ₖ", "l":"ₗ", "m":"ₘ", "n":"ₙ", "o":"ₒ", "p":"ₚ", "r":"ᵣ", "s":"ₛ", "t":"ₜ", "u":"ᵤ", "v":"ᵥ", "x":"ₓ"]
    private static let vulgar: [String: String] = ["1/2":"½", "1/3":"⅓", "2/3":"⅔", "1/4":"¼", "3/4":"¾", "1/5":"⅕", "2/5":"⅖", "3/5":"⅗", "4/5":"⅘", "1/6":"⅙", "5/6":"⅚", "1/8":"⅛", "3/8":"⅜", "5/8":"⅝", "7/8":"⅞"]

    static func unicode(_ node: FormulaNode) -> String {
        switch node {
        case .number(let value), .symbol(let value, _): return value
        case .row(let children): return children.map(unicode).joined()
        case .fraction(let numerator, let denominator):
            let n = unicode(numerator), d = unicode(denominator)
            if let fraction = vulgar[n + "/" + d] { return fraction }
            if n.allSatisfy(\.isNumber), d.allSatisfy(\.isNumber) { return map(n, using: superscript) + "⁄" + map(d, using: subscriptMap) }
            return groupedForFraction(numerator, rendered: n) + "⁄" + groupedForFraction(denominator, rendered: d)
        case .script(let base, let sub, let sup, let subGrouped, let superGrouped):
            var result = unicode(base)
            if let sub { result += scriptText(unicode(sub), using: subscriptMap, grouped: subGrouped) }
            if let sup { result += scriptText(unicode(sup), using: superscript, grouped: superGrouped) }
            return result
        case .radical(let radicand, let index, let grouped):
            let value = unicode(radicand)
            if let index {
                return "√" + scriptText(unicode(index), using: superscript, grouped: false) + "⟨" + value + "⟩"
            }
            return "√" + (grouped ? "(" + value + ")" : value)
        case .largeOperator(let name, let lower, let upper, let operand):
            var result = largeOperatorUnicode[name, default: name] +
                (lower.map { scriptText(unicode($0), using: subscriptMap, grouped: false) } ?? "") +
                (upper.map { scriptText(unicode($0), using: superscript, grouped: false) } ?? "")
            if let operand { result += " " + unicode(operand) }
            return result
        case .accent(_, let base, let mark): return unicode(base) + (mark ?? "")
        case .delimited(let left, let content, let right, _):
            return (left == "." ? "" : left) + unicode(content) + (right == "." ? "" : right)
        }
    }

    static func tex(_ node: FormulaNode) -> String {
        switch node {
        case .number(let value): return value
        case .symbol(let value, let hint): return hint ?? Greek.tex[value] ?? value
        case .row(let children):
            var result = "", previous = ""
            for child in children {
                let current = tex(child)
                if let slash = previous.lastIndex(of: "\\"),
                   !previous[previous.index(after: slash)...].isEmpty,
                   previous[previous.index(after: slash)...].allSatisfy(\.isLetter),
                   current.first?.isLetter == true { result += " " }
                result += current; previous = current
            }
            return result
        case .fraction(let numerator, let denominator): return "\\frac{" + tex(numerator) + "}{" + tex(denominator) + "}"
        case .script(let base, let sub, let sup, _, _):
            var result = tex(base)
            if let sub { result += "_{" + tex(sub) + "}" }
            if let sup { result += "^{" + tex(sup) + "}" }
            return result
        case .radical(let radicand, let index, _):
            if let index { return "\\sqrt[" + tex(index) + "]{" + tex(radicand) + "}" }
            return "\\sqrt{" + tex(radicand) + "}"
        case .largeOperator(let name, let lower, let upper, let operand):
            var result = "\\" + name
            if let lower { result += "_{" + tex(lower) + "}" }
            if let upper { result += "^{" + tex(upper) + "}" }
            if let operand {
                if lower == nil && upper == nil { result += " " }
                result += tex(operand)
            }
            return result
        case .accent(let command, let base, _): return "\\" + command + "{" + tex(base) + "}"
        case .delimited(let left, let content, let right, let latexSized):
            if latexSized {
                return "\\left" + delimiterTex(left, opening: true) + tex(content) + "\\right" + delimiterTex(right, opening: false)
            }
            return delimiterTex(left, opening: true) + tex(content) + delimiterTex(right, opening: false)
        }
    }

    private static func groupedForFraction(_ node: FormulaNode, rendered: String) -> String {
        if case .row(let children) = node, children.count > 1 { return "(" + rendered + ")" }
        if case .delimited = node { return rendered }
        return rendered
    }
    private static func scriptText(_ source: String, using map: [Character: Character], grouped: Bool) -> String {
        let body = Self.map(source, using: map)
        return grouped ? String(map["("] ?? "(") + body + String(map[")"] ?? ")") : body
    }
    private static func delimiterTex(_ value: String, opening: Bool) -> String {
        if value == "." { return "" }
        let commands = ["⟨":"\\langle", "⟩":"\\rangle", "⌊":"\\lfloor", "⌋":"\\rfloor", "⌈":"\\lceil", "⌉":"\\rceil", "‖":"\\Vert", "∥":"\\parallel", "∣":"\\mid", "{":"\\{", "}":"\\}"]
        let rendered = commands[value] ?? value
        return opening && rendered.last?.isLetter == true ? rendered + " " : rendered
    }
    private static func map(_ source: String, using mapping: [Character: Character]) -> String { String(source.map { mapping[$0] ?? $0 }) }
}

private enum Greek {
    static let unicode: [String: String] = [
        "alpha":"α", "beta":"β", "gamma":"γ", "delta":"δ", "epsilon":"ϵ", "varepsilon":"ε",
        "zeta":"ζ", "eta":"η", "theta":"θ", "vartheta":"ϑ", "iota":"ι", "kappa":"κ",
        "lambda":"λ", "mu":"μ", "nu":"ν", "xi":"ξ", "omicron":"ο", "pi":"π", "varpi":"ϖ",
        "rho":"ρ", "varrho":"ϱ", "sigma":"σ", "varsigma":"ς", "tau":"τ", "upsilon":"υ",
        "phi":"ϕ", "varphi":"φ", "chi":"χ", "psi":"ψ", "omega":"ω",
        "Gamma":"Γ", "Delta":"Δ", "Theta":"Θ", "Lambda":"Λ", "Xi":"Ξ", "Pi":"Π",
        "Sigma":"Σ", "Upsilon":"Υ", "Phi":"Φ", "Psi":"Ψ", "Omega":"Ω",
        "forall":"∀", "exists":"∃", "in":"∈"
    ]
    static let tex: [String: String] = [
        "α":"\\alpha", "β":"\\beta", "γ":"\\gamma", "δ":"\\delta", "ϵ":"\\epsilon", "ε":"\\varepsilon",
        "ζ":"\\zeta", "η":"\\eta", "θ":"\\theta", "ϑ":"\\vartheta", "ι":"\\iota", "κ":"\\kappa",
        "λ":"\\lambda", "μ":"\\mu", "ν":"\\nu", "ξ":"\\xi", "ο":"\\omicron", "π":"\\pi", "ϖ":"\\varpi",
        "ρ":"\\rho", "ϱ":"\\varrho", "σ":"\\sigma", "ς":"\\varsigma", "τ":"\\tau", "υ":"\\upsilon",
        "ϕ":"\\phi", "φ":"\\varphi", "χ":"\\chi", "ψ":"\\psi", "ω":"\\omega",
        "Γ":"\\Gamma", "Δ":"\\Delta", "Θ":"\\Theta", "Λ":"\\Lambda", "Ξ":"\\Xi", "Π":"\\Pi",
        "Σ":"\\Sigma", "Υ":"\\Upsilon", "Φ":"\\Phi", "Ψ":"\\Psi", "Ω":"\\Omega",
        "∀":"\\forall", "∃":"\\exists", "∈":"\\in",
        "ℕ":"\\mathbb{N}", "ℤ":"\\mathbb{Z}", "ℚ":"\\mathbb{Q}", "ℝ":"\\mathbb{R}", "ℂ":"\\mathbb{C}"
    ]
    static let blackboard: [String: (glyph: String, command: String)] = [
        "N": ("ℕ", "\\mathbb{N}"), "Z": ("ℤ", "\\mathbb{Z}"),
        "Q": ("ℚ", "\\mathbb{Q}"), "R": ("ℝ", "\\mathbb{R}"),
        "C": ("ℂ", "\\mathbb{C}")
    ]
    static let commandToUnicode = Dictionary(uniqueKeysWithValues: tex.map { (String($0.value.dropFirst()), $0.key) })
}

private struct FormulaSymbol { let unicode: String; let tex: String? }
private let latexSpacingCharacters: Set<Character> = [" ", "!", ",", ":", ";"]
private let latexSpacingCommands: Set<String> = ["quad", "qquad", "enspace", "thinspace", "medspace", "thickspace"]
private let latexDelimiterCommands: [String: String] = [
    "langle":"⟨", "rangle":"⟩", "lfloor":"⌊", "rfloor":"⌋", "lceil":"⌈", "rceil":"⌉",
    "lVert":"‖", "rVert":"‖", "Vert":"‖", "vert":"|", "lvert":"|", "rvert":"|",
    "lbrace":"{", "rbrace":"}", "lbrack":"[", "rbrack":"]", "lparen":"(", "rparen":")"
]
private let pairedLatexDelimiters: [String: (left: String, rightCommand: String, right: String)] = [
    "langle": ("⟨", "rangle", "⟩"), "lfloor": ("⌊", "rfloor", "⌋"), "lceil": ("⌈", "rceil", "⌉"),
    "lvert": ("|", "rvert", "|"), "lVert": ("‖", "rVert", "‖"), "lbrace": ("{", "rbrace", "}"),
    "lbrack": ("[", "rbrack", "]"), "lparen": ("(", "rparen", ")")
]
private let relationTex: [String: String] = [
    "≤":"\\leq", "≥":"\\geq", "≠":"\\neq", "≈":"\\approx", "≃":"\\simeq", "≡":"\\equiv",
    "≢":"\\not\\equiv", "≅":"\\cong", "≍":"\\asymp", "≰":"\\nleq", "≱":"\\ngeq", "∼":"\\sim", "∝":"\\propto",
    "→":"\\to", "⇒":"\\Rightarrow", "↔":"\\leftrightarrow", "⇔":"\\Leftrightarrow", "←":"\\leftarrow", "↦":"\\mapsto",
    "⟶":"\\longrightarrow", "⟹":"\\Longrightarrow", "⟷":"\\longleftrightarrow", "⟺":"\\Longleftrightarrow", "⟵":"\\longleftarrow", "⟼":"\\longmapsto",
    "∈":"\\in", "∉":"\\notin", "∋":"\\ni", "⊂":"\\subset", "⊆":"\\subseteq", "⊃":"\\supset", "⊇":"\\supseteq",
    "⊄":"\\nsubset", "⊅":"\\nsupset", "⊈":"\\nsubseteq", "⊉":"\\nsupseteq", "∪":"\\cup", "∩":"\\cap",
    "∧":"\\land", "∨":"\\lor", "¬":"\\neg", "∥":"\\parallel", "∣":"\\mid", "±":"\\pm", "∓":"\\mp"
]
private let symbolMap: [String: FormulaSymbol] = [
    "×": .init(unicode:"×", tex:"\\times"), "⋅": .init(unicode:"⋅", tex:"\\cdot"), "÷": .init(unicode:"÷", tex:"\\div"),
    "∞": .init(unicode:"∞", tex:"\\infty"), "ℵ": .init(unicode:"ℵ", tex:"\\aleph"), "√": .init(unicode:"√", tex:"\\sqrt"),
    "∑": .init(unicode:"∑", tex:"\\sum"), "∏": .init(unicode:"∏", tex:"\\prod"), "∫": .init(unicode:"∫", tex:"\\int"),
    "∬": .init(unicode:"∬", tex:"\\iint"), "∭": .init(unicode:"∭", tex:"\\iiint"), "∮": .init(unicode:"∮", tex:"\\oint"),
    "∂": .init(unicode:"∂", tex:"\\partial"), "∇": .init(unicode:"∇", tex:"\\nabla"), "∀": .init(unicode:"∀", tex:"\\forall"),
    "∃": .init(unicode:"∃", tex:"\\exists"), "ℕ": .init(unicode:"ℕ", tex:"\\mathbb{N}"), "ℤ": .init(unicode:"ℤ", tex:"\\mathbb{Z}"),
    "ℚ": .init(unicode:"ℚ", tex:"\\mathbb{Q}"), "ℝ": .init(unicode:"ℝ", tex:"\\mathbb{R}"), "ℂ": .init(unicode:"ℂ", tex:"\\mathbb{C}")
].merging(Dictionary(uniqueKeysWithValues: relationTex.map { key, value in
    (key, FormulaSymbol(unicode: key, tex: value))
})) { _, relation in relation }
private let commandSymbols: [String: FormulaSymbol] = [
    "times": .init(unicode:"×", tex:"\\times"), "cdot": .init(unicode:"⋅", tex:"\\cdot"), "div": .init(unicode:"÷", tex:"\\div"),
    "le": .init(unicode:"≤", tex:"\\leq"), "leq": .init(unicode:"≤", tex:"\\leq"), "ge": .init(unicode:"≥", tex:"\\geq"), "geq": .init(unicode:"≥", tex:"\\geq"),
    "ne": .init(unicode:"≠", tex:"\\neq"), "neq": .init(unicode:"≠", tex:"\\neq"), "notin": .init(unicode:"∉", tex:"\\notin"), "ni": .init(unicode:"∋", tex:"\\ni"),
    "subset": .init(unicode:"⊂", tex:"\\subset"), "subseteq": .init(unicode:"⊆", tex:"\\subseteq"), "nsubset": .init(unicode:"⊄", tex:"\\nsubset"),
    "nsubseteq": .init(unicode:"⊈", tex:"\\nsubseteq"), "supset": .init(unicode:"⊃", tex:"\\supset"), "supseteq": .init(unicode:"⊇", tex:"\\supseteq"),
    "nsupset": .init(unicode:"⊅", tex:"\\nsupset"), "nsupseteq": .init(unicode:"⊉", tex:"\\nsupseteq"), "cup": .init(unicode:"∪", tex:"\\cup"),
    "cap": .init(unicode:"∩", tex:"\\cap"), "land": .init(unicode:"∧", tex:"\\land"), "lor": .init(unicode:"∨", tex:"\\lor"), "neg": .init(unicode:"¬", tex:"\\neg"),
    "pm": .init(unicode:"±", tex:"\\pm"), "mp": .init(unicode:"∓", tex:"\\mp"), "propto": .init(unicode:"∝", tex:"\\propto"),
    "approx": .init(unicode:"≈", tex:"\\approx"), "simeq": .init(unicode:"≃", tex:"\\simeq"), "sim": .init(unicode:"∼", tex:"\\sim"),
    "equiv": .init(unicode:"≡", tex:"\\equiv"), "nequiv": .init(unicode:"≢", tex:"\\not\\equiv"), "cong": .init(unicode:"≅", tex:"\\cong"), "asymp": .init(unicode:"≍", tex:"\\asymp"),
    "infty": .init(unicode:"∞", tex:"\\infty"), "aleph": .init(unicode:"ℵ", tex:"\\aleph"),
    "to": .init(unicode:"→", tex:"\\to"), "rightarrow": .init(unicode:"→", tex:"\\rightarrow"), "longrightarrow": .init(unicode:"⟶", tex:"\\longrightarrow"),
    "Rightarrow": .init(unicode:"⇒", tex:"\\Rightarrow"), "Longrightarrow": .init(unicode:"⟹", tex:"\\Longrightarrow"), "leftrightarrow": .init(unicode:"↔", tex:"\\leftrightarrow"),
    "Leftrightarrow": .init(unicode:"⇔", tex:"\\Leftrightarrow"), "leftarrow": .init(unicode:"←", tex:"\\leftarrow"), "mapsto": .init(unicode:"↦", tex:"\\mapsto"),
    "partial": .init(unicode:"∂", tex:"\\partial"), "nabla": .init(unicode:"∇", tex:"\\nabla"), "emptyset": .init(unicode:"∅", tex:"\\emptyset"), "varnothing": .init(unicode:"∅", tex:"\\varnothing"),
    "parallel": .init(unicode:"∥", tex:"\\parallel"), "mid": .init(unicode:"∣", tex:"\\mid"), "Vert": .init(unicode:"‖", tex:"\\Vert")
].merging(Dictionary(uniqueKeysWithValues: relationTex.map { key, value in
    (key, FormulaSymbol(unicode: key, tex: value))
})) { _, relation in relation }
private let namedSymbols: [String: FormulaSymbol] = [
    "infty": .init(unicode:"∞", tex:"\\infty"), "infinity": .init(unicode:"∞", tex:"\\infty"), "aleph": .init(unicode:"ℵ", tex:"\\aleph"),
    "empty": .init(unicode:"∅", tex:"\\varnothing"), "emptyset": .init(unicode:"∅", tex:"\\emptyset"), "varnothing": .init(unicode:"∅", tex:"\\varnothing"),
    "union": .init(unicode:"∪", tex:"\\cup"), "intersect": .init(unicode:"∩", tex:"\\cap"), "intersection": .init(unicode:"∩", tex:"\\cap"),
    "and": .init(unicode:"∧", tex:"\\land"), "wedge": .init(unicode:"∧", tex:"\\land"), "or": .init(unicode:"∨", tex:"\\lor"), "vee": .init(unicode:"∨", tex:"\\lor"),
    "not": .init(unicode:"¬", tex:"\\neg"), "parallel": .init(unicode:"∥", tex:"\\parallel"), "mid": .init(unicode:"∣", tex:"\\mid"),
    "owns": .init(unicode:"∋", tex:"\\ni"), "subseteq": .init(unicode:"⊆", tex:"\\subseteq"), "supseteq": .init(unicode:"⊇", tex:"\\supseteq"),
    "notin": .init(unicode:"∉", tex:"\\notin"), "equiv": .init(unicode:"≡", tex:"\\equiv"), "nequiv": .init(unicode:"≢", tex:"\\not\\equiv"),
    "approx": .init(unicode:"≈", tex:"\\approx"), "simeq": .init(unicode:"≃", tex:"\\simeq"), "propto": .init(unicode:"∝", tex:"\\propto"),
    "to": .init(unicode:"→", tex:"\\to"), "rightarrow": .init(unicode:"→", tex:"\\rightarrow"), "leftarrow": .init(unicode:"←", tex:"\\leftarrow"),
    "mapsto": .init(unicode:"↦", tex:"\\mapsto"), "iff": .init(unicode:"⇔", tex:"\\Leftrightarrow"), "implies": .init(unicode:"⇒", tex:"\\Rightarrow")
]
private let mathFunctions: [String: String] = [
    "sqrt":"sqrt", "sin":"sin", "cos":"cos", "tan":"tan", "asin":"arcsin", "acos":"arccos", "atan":"arctan",
    "sinh":"sinh", "cosh":"cosh", "tanh":"tanh", "sec":"sec", "csc":"csc", "cot":"cot",
    "asinh":"arcsinh", "acosh":"arccosh", "atanh":"arctanh", "log":"log", "ln":"ln", "exp":"exp",
    "abs":"abs", "absolute":"abs", "norm":"norm", "floor":"floor", "ceil":"ceil", "ceiling":"ceil",
    "vec":"vec", "vector":"vec", "hat":"hat", "widehat":"hat", "bar":"bar", "overline":"overline", "dot":"dot",
    "ddot":"ddot", "tilde":"tilde", "widetilde":"tilde", "underline":"underline", "bold":"mathbf"
]
private let largeOperatorNames: [String: String] = [
    "sum":"sum", "sigma":"sum", "prod":"prod", "product":"prod", "int":"int", "integral":"int",
    "iint":"iint", "iiint":"iiint", "oint":"oint", "lim":"lim", "limit":"lim", "min":"min", "max":"max", "sup":"sup", "inf":"inf"
]
private let largeOperatorUnicode: [String: String] = ["sum":"∑", "prod":"∏", "int":"∫", "iint":"∬", "iiint":"∭", "oint":"∮", "lim":"lim"]
private let largeOperatorNameBySymbol: [String: String] = ["∑":"sum", "∏":"prod", "∫":"int", "∬":"iint", "∭":"iiint", "∮":"oint"]
private let accentFunctions: [String: (command: String, unicodeMark: String?)] = [
    "vec": ("vec", "⃗"), "hat": ("hat", "̂"), "widehat": ("hat", "̂"), "bar": ("bar", "̄"), "overline": ("overline", "̄"),
    "dot": ("dot", "̇"), "ddot": ("ddot", "̈"), "tilde": ("tilde", "̃"), "widetilde": ("tilde", "̃"), "underline": ("underline", "̲"),
    "mathbf": ("mathbf", nil)
]
