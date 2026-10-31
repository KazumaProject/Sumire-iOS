import Foundation

/// A platform-neutral operation emitted by Android's formula layout rules.
public enum AndroidFormulaDrawOperation: Equatable, Sendable {
    case text(value: String, x: Double, baseline: Double, fontSize: Double, bold: Bool)
    case line(startX: Double, startY: Double, endX: Double, endY: Double, strokeWidth: Double)
}

/// Formula bounds and drawing operations around a baseline at `y == 0`.
public struct AndroidFormulaLayout: Equatable, Sendable {
    public let width: Double
    public let ascent: Double
    public let descent: Double
    public let operations: [AndroidFormulaDrawOperation]

    public var height: Double { ascent + descent }

    init(width: Double, ascent: Double, descent: Double, operations: [AndroidFormulaDrawOperation]) {
        self.width = width
        self.ascent = ascent
        self.descent = descent
        self.operations = operations
    }
}

/// Geometry constants shared with the pinned Android `FormulaLayoutConfig`.
public struct AndroidFormulaLayoutConfig: Equatable, Sendable {
    public var fontSize: Double
    public var scriptScale: Double
    public var fractionScale: Double
    public var ascentRatio: Double
    public var descentRatio: Double
    public var horizontalGapRatio: Double
    public var verticalGapRatio: Double
    public var ruleThicknessRatio: Double

    public init(
        fontSize: Double = 16,
        scriptScale: Double = 0.72,
        fractionScale: Double = 0.82,
        ascentRatio: Double = 0.80,
        descentRatio: Double = 0.22,
        horizontalGapRatio: Double = 0.12,
        verticalGapRatio: Double = 0.10,
        ruleThicknessRatio: Double = 0.06
    ) {
        self.fontSize = fontSize.isFinite ? min(max(fontSize, 1), 96) : 16
        self.scriptScale = scriptScale.isFinite ? min(max(scriptScale, 0), 2) : 0.72
        self.fractionScale = fractionScale.isFinite ? min(max(fractionScale, 0), 2) : 0.82
        self.ascentRatio = ascentRatio.isFinite ? min(max(ascentRatio, 0), 2) : 0.80
        self.descentRatio = descentRatio.isFinite ? min(max(descentRatio, 0), 2) : 0.22
        self.horizontalGapRatio = horizontalGapRatio.isFinite ? min(max(horizontalGapRatio, 0), 2) : 0.12
        self.verticalGapRatio = verticalGapRatio.isFinite ? min(max(verticalGapRatio, 0), 2) : 0.10
        self.ruleThicknessRatio = ruleThicknessRatio.isFinite ? min(max(ruleThicknessRatio, 0), 2) : 0.06
    }
}

/// Font-independent placement ported from the pinned Android `FormulaLayout.kt`.
enum AndroidFormulaLayoutEngine {
    static func layout(
        _ node: FormulaNode,
        config: AndroidFormulaLayoutConfig,
        measureText: (String, Double) -> Double
    ) -> AndroidFormulaLayout {
        layoutNode(node, size: config.fontSize, config: config, measureText: measureText)
    }

    private static func layoutNode(
        _ node: FormulaNode,
        size: Double,
        config: AndroidFormulaLayoutConfig,
        measureText: (String, Double) -> Double
    ) -> AndroidFormulaLayout {
        switch node {
        case .number(let value), .symbol(let value, _):
            return textLayout(value, size: size, config: config, measureText: measureText)
        case .row(let children):
            return rowLayout(children, size: size, config: config, measureText: measureText)
        case .fraction(let numerator, let denominator):
            return fractionLayout(numerator, denominator, size: size, config: config, measureText: measureText)
        case .script(let base, let sub, let sup, _, _):
            return scriptLayout(base, sub: sub, sup: sup, size: size, config: config, measureText: measureText)
        case .radical(let radicand, let index, let grouped):
            return radicalLayout(radicand, index: index, grouped: grouped, size: size, config: config, measureText: measureText)
        case .largeOperator(let name, let lower, let upper, let operand):
            return largeOperatorLayout(name, lower: lower, upper: upper, operand: operand, size: size, config: config, measureText: measureText)
        case .accent(let command, let base, _):
            return accentLayout(command, base: base, size: size, config: config, measureText: measureText)
        case .delimited(let left, let content, let right, _):
            return delimitedLayout(left, content: content, right: right, size: size, config: config, measureText: measureText)
        }
    }

    private static func textLayout(
        _ value: String,
        size: Double,
        config: AndroidFormulaLayoutConfig,
        measureText: (String, Double) -> Double,
        bold: Bool = false
    ) -> AndroidFormulaLayout {
        let measured = measureText(value, size)
        let width = measured.isFinite ? max(0, measured) : 0
        let (ascent, descent) = config.metrics(size)
        let operations: [AndroidFormulaDrawOperation] = value.isEmpty
            ? [] : [.text(value: value, x: 0, baseline: 0, fontSize: size, bold: bold)]
        return AndroidFormulaLayout(width: width, ascent: ascent, descent: descent, operations: operations)
    }

    private static func rowLayout(
        _ children: [FormulaNode],
        size: Double,
        config: AndroidFormulaLayoutConfig,
        measureText: (String, Double) -> Double
    ) -> AndroidFormulaLayout {
        guard !children.isEmpty else { return textLayout("", size: size, config: config, measureText: measureText) }
        let layouts = children.map { layoutNode($0, size: size, config: config, measureText: measureText) }
        var x = 0.0
        var ascent = 0.0
        var descent = 0.0
        var operations: [AndroidFormulaDrawOperation] = []
        for (index, child) in layouts.enumerated() {
            operations += child.operations.map { $0.translated(x: x, y: 0) }
            x += child.width
            let source = children[index]
            let hasLimits: Bool
            if case .largeOperator(_, let lower, let upper, _) = source { hasLimits = lower != nil || upper != nil }
            else { hasLimits = false }
            let next = children.indices.contains(index + 1) ? children[index + 1] : nil
            let nextIsDelimited: Bool
            if case .delimited? = next { nextIsDelimited = true } else { nextIsDelimited = false }
            if index < layouts.count - 1 && (hasLimits || (!nextIsDelimited && source.needsOperandGap)) {
                x += config.horizontalGap(size)
            }
            ascent = max(ascent, child.ascent)
            descent = max(descent, child.descent)
        }
        return AndroidFormulaLayout(width: x, ascent: ascent, descent: descent, operations: operations)
    }

    private static func fractionLayout(
        _ numeratorNode: FormulaNode,
        _ denominatorNode: FormulaNode,
        size: Double,
        config: AndroidFormulaLayoutConfig,
        measureText: (String, Double) -> Double
    ) -> AndroidFormulaLayout {
        let childSize = size * config.fractionScale
        let numerator = layoutNode(numeratorNode, size: childSize, config: config, measureText: measureText)
        let denominator = layoutNode(denominatorNode, size: childSize, config: config, measureText: measureText)
        let horizontalGap = config.horizontalGap(size)
        let verticalGap = config.verticalGap(size)
        let rule = config.ruleThickness(size)
        let width = max(numerator.width, denominator.width) + horizontalGap * 2
        let numeratorBaseline = -(rule / 2 + verticalGap + numerator.descent)
        let denominatorBaseline = rule / 2 + verticalGap + denominator.ascent
        let numeratorX = (width - numerator.width) / 2
        let denominatorX = (width - denominator.width) / 2
        let top = numeratorBaseline - numerator.ascent
        let bottom = denominatorBaseline + denominator.descent
        let operations = numerator.operations.map { $0.translated(x: numeratorX, y: numeratorBaseline) } +
            [.line(startX: horizontalGap / 2, startY: 0, endX: width - horizontalGap / 2, endY: 0, strokeWidth: rule)] +
            denominator.operations.map { $0.translated(x: denominatorX, y: denominatorBaseline) }
        return AndroidFormulaLayout(width: width, ascent: max(0, -top), descent: max(0, bottom), operations: operations)
    }

    private static func scriptLayout(
        _ baseNode: FormulaNode,
        sub: FormulaNode?,
        sup: FormulaNode?,
        size: Double,
        config: AndroidFormulaLayoutConfig,
        measureText: (String, Double) -> Double
    ) -> AndroidFormulaLayout {
        let base = layoutNode(baseNode, size: size, config: config, measureText: measureText)
        let superscript = sup.map { layoutNode($0, size: size * config.scriptScale, config: config, measureText: measureText) }
        let subscriptLayout = sub.map { layoutNode($0, size: size * config.scriptScale, config: config, measureText: measureText) }
        guard superscript != nil || subscriptLayout != nil else { return base }
        let scriptX = base.width + max(1, size * 0.04)
        let paired = superscript != nil && subscriptLayout != nil
        let supBaseline = paired ? -(config.verticalGap(size) + (superscript?.descent ?? 0)) : -base.ascent * 0.56
        let subBaseline = paired ? config.verticalGap(size) + (subscriptLayout?.ascent ?? 0) : base.descent * 0.72
        let scriptWidth = max(superscript?.width ?? 0, subscriptLayout?.width ?? 0)
        let ascent = max(base.ascent, superscript.map { -supBaseline + $0.ascent } ?? 0)
        let descent = max(base.descent, subscriptLayout.map { subBaseline + $0.descent } ?? 0)
        var operations = base.operations
        if let superscript { operations += superscript.operations.map { $0.translated(x: scriptX, y: supBaseline) } }
        if let subscriptLayout { operations += subscriptLayout.operations.map { $0.translated(x: scriptX, y: subBaseline) } }
        return AndroidFormulaLayout(width: scriptX + scriptWidth, ascent: ascent, descent: descent, operations: operations)
    }

    private static func radicalLayout(
        _ radicandNode: FormulaNode,
        index: FormulaNode?,
        grouped: Bool,
        size: Double,
        config: AndroidFormulaLayoutConfig,
        measureText: (String, Double) -> Double
    ) -> AndroidFormulaLayout {
        let presentedRadicand: FormulaNode = grouped ? .delimited("(", radicandNode, ")", latexSized: false) : radicandNode
        let radicand = layoutNode(presentedRadicand, size: size, config: config, measureText: measureText)
        let root = textLayout("√", size: size, config: config, measureText: measureText)
        let radicandX = root.width + config.horizontalGap(size)
        let overlineY = -radicand.ascent - config.verticalGap(size) / 2
        let indexLayout = index.map { layoutNode($0, size: size * config.scriptScale, config: config, measureText: measureText) }
        let indexBaseline = -root.ascent * 0.58
        let width = radicandX + radicand.width
        let ascent = max(root.ascent, max(-overlineY + config.ruleThickness(size) / 2, indexLayout.map { -indexBaseline + $0.ascent } ?? 0))
        let descent = max(root.descent, radicand.descent)
        var operations = root.operations + radicand.operations.map { $0.translated(x: radicandX, y: 0) }
        operations.append(.line(startX: radicandX, startY: overlineY, endX: width, endY: overlineY, strokeWidth: config.ruleThickness(size)))
        if let indexLayout { operations += indexLayout.operations.map { $0.translated(x: 0, y: indexBaseline) } }
        return AndroidFormulaLayout(width: width, ascent: ascent, descent: descent, operations: operations)
    }

    private static func delimitedLayout(
        _ leftValue: String,
        content contentNode: FormulaNode,
        right rightValue: String,
        size: Double,
        config: AndroidFormulaLayoutConfig,
        measureText: (String, Double) -> Double
    ) -> AndroidFormulaLayout {
        let content = layoutNode(contentNode, size: size, config: config, measureText: measureText)
        let baseMetrics = config.metrics(size)
        let baseHeight = baseMetrics.0 + baseMetrics.1
        let scale = baseHeight > 0 ? max(1, content.height / baseHeight) : 1
        let delimiterSize = size * scale
        let left = textLayout(leftValue, size: leftValue.isEmpty ? size : delimiterSize, config: config, measureText: measureText)
        let right = textLayout(rightValue, size: rightValue.isEmpty ? size : delimiterSize, config: config, measureText: measureText)
        let rightX = left.width + content.width
        let operations = left.operations + content.operations.map { $0.translated(x: left.width, y: 0) } + right.operations.map { $0.translated(x: rightX, y: 0) }
        return AndroidFormulaLayout(
            width: left.width + content.width + right.width,
            ascent: max(left.ascent, max(content.ascent, right.ascent)),
            descent: max(left.descent, max(content.descent, right.descent)),
            operations: operations
        )
    }

    private static func largeOperatorLayout(
        _ name: String,
        lower: FormulaNode?,
        upper: FormulaNode?,
        operand: FormulaNode?,
        size: Double,
        config: AndroidFormulaLayoutConfig,
        measureText: (String, Double) -> Double
    ) -> AndroidFormulaLayout {
        let display = ["sum":"∑", "prod":"∏", "int":"∫", "iint":"∬", "iiint":"∭", "oint":"∮", "lim":"lim"][name] ?? name
        let operatorLayout = textLayout(display, size: size, config: config, measureText: measureText)
        let limitSize = size * config.scriptScale
        let lowerLayout = lower.map { layoutNode($0, size: limitSize, config: config, measureText: measureText) }
        let upperLayout = upper.map { layoutNode($0, size: limitSize, config: config, measureText: measureText) }
        let regionWidth = max(operatorLayout.width, max(lowerLayout?.width ?? 0, upperLayout?.width ?? 0))
        let operatorX = (regionWidth - operatorLayout.width) / 2
        let limitGap = config.verticalGap(size)
        let upperBaseline = upperLayout.map { -(operatorLayout.ascent + limitGap + $0.descent) }
        let lowerBaseline = lowerLayout.map { operatorLayout.descent + limitGap + $0.ascent }
        let operandLayout = operand.map { layoutNode($0, size: size, config: config, measureText: measureText) }
        let operandX = operandLayout == nil ? regionWidth : regionWidth + config.horizontalGap(size)
        var operations = operatorLayout.operations.map { $0.translated(x: operatorX, y: 0) }
        if let upperLayout, let upperBaseline { operations += upperLayout.operations.map { $0.translated(x: (regionWidth - upperLayout.width) / 2, y: upperBaseline) } }
        if let lowerLayout, let lowerBaseline { operations += lowerLayout.operations.map { $0.translated(x: (regionWidth - lowerLayout.width) / 2, y: lowerBaseline) } }
        if let operandLayout { operations += operandLayout.operations.map { $0.translated(x: operandX, y: 0) } }
        return AndroidFormulaLayout(
            width: operandX + (operandLayout?.width ?? 0),
            ascent: max(operatorLayout.ascent, max(upperLayout.map { -(upperBaseline ?? 0) + $0.ascent } ?? 0, operandLayout?.ascent ?? 0)),
            descent: max(operatorLayout.descent, max(lowerLayout.map { (lowerBaseline ?? 0) + $0.descent } ?? 0, operandLayout?.descent ?? 0)),
            operations: operations
        )
    }

    private static func accentLayout(
        _ command: String,
        base baseNode: FormulaNode,
        size: Double,
        config: AndroidFormulaLayoutConfig,
        measureText: (String, Double) -> Double
    ) -> AndroidFormulaLayout {
        let base = layoutNode(baseNode, size: size, config: config, measureText: measureText)
        if command == "mathbf" {
            return AndroidFormulaLayout(width: base.width, ascent: base.ascent, descent: base.descent, operations: base.operations.map { $0.bold() })
        }
        if command == "underline" {
            let y = base.descent + config.verticalGap(size)
            return AndroidFormulaLayout(
                width: base.width, ascent: base.ascent, descent: y + config.ruleThickness(size),
                operations: base.operations + [.line(startX: 0, startY: y, endX: base.width, endY: y, strokeWidth: config.ruleThickness(size))]
            )
        }
        let mark: String
        switch command {
        case "hat": mark = "⌃"
        case "bar", "overline": mark = "¯"
        case "dot": mark = "˙"
        case "ddot": mark = "¨"
        case "tilde": mark = "˜"
        case "vec": mark = "→"
        default: mark = ""
        }
        guard !mark.isEmpty else { return base }
        let accent = textLayout(mark, size: size * 0.9, config: config, measureText: measureText)
        let baseline = -base.ascent - config.verticalGap(size) / 2
        let operations = base.operations + accent.operations.map { $0.translated(x: (base.width - accent.width) / 2, y: baseline) }
        return AndroidFormulaLayout(width: base.width, ascent: max(base.ascent, -baseline + accent.ascent), descent: base.descent, operations: operations)
    }
}

private extension AndroidFormulaLayoutConfig {
    func metrics(_ size: Double) -> (Double, Double) { (size * ascentRatio, size * descentRatio) }
    func horizontalGap(_ size: Double) -> Double { size * horizontalGapRatio }
    func verticalGap(_ size: Double) -> Double { size * verticalGapRatio }
    func ruleThickness(_ size: Double) -> Double { max(1, size * ruleThicknessRatio) }
}

private extension FormulaNode {
    var needsOperandGap: Bool {
        switch self {
        case .symbol(let value, _):
            return ["sin", "cos", "tan", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "sec", "csc", "cot", "arcsinh", "arccosh", "arctanh", "ln", "log", "exp", "lim", "min", "max", "sup", "inf", "mod"].contains(value)
        case .script(let base, _, _, _, _): return base.needsOperandGap
        default: return false
        }
    }
}

private extension AndroidFormulaDrawOperation {
    func translated(x dx: Double, y dy: Double) -> AndroidFormulaDrawOperation {
        switch self {
        case .text(let value, let x, let baseline, let fontSize, let bold):
            return .text(value: value, x: x + dx, baseline: baseline + dy, fontSize: fontSize, bold: bold)
        case .line(let startX, let startY, let endX, let endY, let strokeWidth):
            return .line(startX: startX + dx, startY: startY + dy, endX: endX + dx, endY: endY + dy, strokeWidth: strokeWidth)
        }
    }

    func bold() -> AndroidFormulaDrawOperation {
        switch self {
        case .text(let value, let x, let baseline, let fontSize, _):
            return .text(value: value, x: x, baseline: baseline, fontSize: fontSize, bold: true)
        case .line:
            return self
        }
    }
}
