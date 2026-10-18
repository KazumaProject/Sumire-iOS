import UIKit
import SumireCore

/// Dedicated adapter for the reference's multi-stage controllers. All output is
/// committed once on release; each key owns its evaluator, timer and overlay.
final class MultiStageFlickKey: UIButton, KeyTouchParticipant {
    weak var touchRouter: KeyTouchRouter?
    weak var popupHost: UIView?
    var touchPolicy: (() -> (exclusive: Bool, blocksFollowing: Bool))?
    var feedbackSettings = TouchFeedbackSettings()
    var popupPalette: KeyboardPalette?
    var styleSettings = FlickStyleSettings()
    // Android reference AVD: density 420 dpi, default slop 8 dp * 3.5.
    // Distances are converted to logical points here; callers may calibrate them
    // for iOS touch handling. Device feel still requires physical validation.
    var gestureConfiguration: MultiFlickConfiguration = {
        var config = MultiFlickConfiguration()
        config.threshold = 28
        config.centerReturnRadius = 70 / (420.0 / 160.0)
        return config
    }()
    var definition: ReferenceFlickDefinition?
    struct CommitEvent {
        let output: CircularFlickOutput
        let isTap: Bool
        let wasFlick: Bool
        let isLongPress: Bool
        let direction: MultiFlickDirection?
        let secondDirection: MultiFlickDirection?
        let circularSlot: CircularFlickSlot?
        var isPureTap: Bool { isTap && !wasFlick && !isLongPress }
    }
    var onCommit: ((CommitEvent) -> Void)?
    var onOutput: ((CircularFlickOutput) -> Void)?
    private var downPoint = FlickPoint(0, 0)
    private var wasFlick = false
    private var activeConfiguration = MultiFlickConfiguration()
    private var tracked: UITouch?
    private var holdTimer: Timer?
    private var engine: Engine?
    private var popup: MultiStageFlickPopupView?
    private var gestureSettings = TouchFeedbackSettings()
    private var gestureStyle = FlickStyleSettings()

    private var guideLabels: [(UILabel, CGPoint)] = []
    func configureGuides(visible: Bool, fontSize: CGFloat, color: UIColor) {
        guideLabels.forEach { $0.0.removeFromSuperview() }; guideLabels = []
        guard visible, let definition else { return }
        var items: [(String, CGPoint)] = []
        func add(_ map: [MultiFlickDirection: String]) {
            let positions: [MultiFlickDirection: CGPoint] = [.up:.init(x:0.5,y:0),.down:.init(x:0.5,y:1),
                .left:.init(x:0,y:0.5),.right:.init(x:1,y:0.5),.upLeft:.init(x:0,y:0),.upRight:.init(x:1,y:0),
                .downLeft:.init(x:0,y:1),.downRight:.init(x:1,y:1)]
            for direction in MultiFlickDirection.allCases {
                if let text = map[direction], let point = positions[direction], !text.isEmpty { items.append((text, point)) }
            }
        }
        switch definition {
        case .single(_, let map, _): add(map)
        case .twoStep(let map, _, _): add(Dictionary(uniqueKeysWithValues: map.map { ($0.key, $0.value[$0.key] ?? $0.value[.tap] ?? "") }))
        case .hierarchical(let maps, _): add((maps[.normal] ?? [:]).compactMapValues { $0.label })
        case .circular(let maps):
            let evaluator = CircularFlickEvaluator(maps: maps, directionCount: styleSettings.circularDirectionCount)
            for slot in evaluator.activeSlots {
                guard let range = evaluator.effectiveRanges[slot], let output = evaluator.currentMap[slot] else { continue }
                let angle = (range.start + range.sweep / 2) * .pi / 180
                let label: String
                switch output {
                case .text(let text, let display): label = display ?? text
                case .action(_, _, let display): label = display
                case .referenceAction(_, let display): label = display ?? ""
                case .mapSwitch: label = "⇄"
                }
                items.append((label, CGPoint(x: 0.5 + cos(angle) * 0.5, y: 0.5 + sin(angle) * 0.5)))
            }
        }
        for (text, position) in items {
            let label = UILabel(); label.text = text; label.textColor = color
            label.font = .systemFont(ofSize: fontSize); label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.5
            label.isUserInteractionEnabled = false; label.isAccessibilityElement = false
            addSubview(label); guideLabels.append((label, position))
        }
        setNeedsLayout()
    }
    private enum Engine {
        case single(SingleStageFlickEvaluator), two(TwoStepFlickEvaluator)
        case hierarchy(HierarchicalFlickEvaluator), circle(CircularFlickEvaluator)
        init(_ definition: ReferenceFlickDefinition, settings: FlickStyleSettings) {
            switch definition {
            case .single(let style, let map, let alternate): self = .single(.init(style: style, map: map, alternate: alternate))
            case .twoStep(let map, let alternate, let sticky): self = .two(.init(map: map, longPressMap: alternate, sticky: sticky))
            case .hierarchical(let maps, let orders):
                var evaluator = HierarchicalFlickEvaluator(maps: maps, directionOrders: orders)
                evaluator.modeSwitchAngleMargin = Double(settings.hierarchicalModeAngleMargin)
                self = .hierarchy(evaluator)
            case .circular(let maps): self = .circle(.init(maps: maps, directionCount: settings.circularDirectionCount))
            }
        }
        mutating func begin(_ point: FlickPoint, _ config: MultiFlickConfiguration) {
            switch self {
            case .single(var e): e.begin(at: point, configuration: config); self = .single(e)
            case .two(var e): e.begin(at: point, configuration: config); self = .two(e)
            case .hierarchy(var e): e.begin(at: point, configuration: config); self = .hierarchy(e)
            case .circle(var e): e.begin(at: point, configuration: config); self = .circle(e)
            }
        }
        mutating func move(_ point: FlickPoint) {
            switch self {
            case .single(var e): e.move(to: point); self = .single(e)
            case .two(var e): e.move(to: point); self = .two(e)
            case .hierarchy(var e): e.move(to: point); self = .hierarchy(e)
            case .circle(var e): e.move(to: point); self = .circle(e)
            }
        }
        mutating func hold() {
            switch self {
            case .single(var e): e.hold(); self = .single(e)
            case .two(var e): e.hold(); self = .two(e)
            case .hierarchy(var e): e.hold(); self = .hierarchy(e)
            case .circle(var e): e.hold(); self = .circle(e)
            }
        }
        var holdPending: Bool {
            switch self { case .single(let e): return e.holdPending; case .two(let e): return e.holdPending
            case .hierarchy(let e): return e.holdPending; case .circle(let e): return e.holdPending }
        }
        mutating func end(_ point: FlickPoint, wasFlick: Bool) -> CommitEvent? {
            switch self {
            case .single(var e):
                guard let value = e.endSelection(at: point), let text = value.text else { return nil }
                return CommitEvent(output: .text(text), isTap: value.direction == .tap, wasFlick: wasFlick,
                    isLongPress: value.longPress, direction: value.direction, secondDirection: nil, circularSlot: nil)
            case .two(var e):
                guard let value = e.endSelection(at: point), let text = value.text else { return nil }
                return CommitEvent(output: .text(text), isTap: value.first == .tap && value.second == .tap, wasFlick: wasFlick,
                    isLongPress: value.longPress, direction: value.first, secondDirection: value.second, circularSlot: nil)
            case .hierarchy(var e):
                let direction = e.selected, held = e.expandedGuide
                guard let text = e.end() else { return nil }
                return CommitEvent(output: .text(text), isTap: direction == .tap, wasFlick: wasFlick,
                    isLongPress: held, direction: direction, secondDirection: nil, circularSlot: nil)
            case .circle(var e):
                let slot = e.direction(at: point), held = e.expandedGuide
                guard let output = e.end(at: point) else { return nil }
                return CommitEvent(output: output, isTap: slot == .tap, wasFlick: wasFlick,
                    isLongPress: held, direction: nil, secondDirection: nil, circularSlot: slot)
            }
        }
        var defaultPopupTextSize: CGFloat {
            switch self {
            case .two, .hierarchy: return 20
            case .circle: return 55 / 2.625
            case .single(let e):
                switch e.style {
                case .petal, .crossAction: return e.longPress ? 18 : 28
                case .standard: return 19
                case .centerGuide, .directionalLongPress: return 20
                }
            }
        }
        var preview: MultiStageFlickPopupView.Content {
            switch self {
            case .single(let e):
                let values = e.longPress ? e.map.merging(e.alternate) { _, new in new } : e.map
                if e.style == .petal && !e.longPress {
                    let visible = e.selected.flatMap { direction in values[direction].map { [direction: $0] } } ?? [:]
                    return .grid(visible, selected: e.selected)
                }
                return .grid(values, selected: e.selected)
            case .two(let e):
                let source = e.longPress ? e.map.merging(e.longPressMap) { old, new in old.merging(new) { _, value in value } } : e.map
                let values = e.secondStage ? (source[e.first] ?? [:]) : (e.expandedGuide ? Dictionary(uniqueKeysWithValues: source.map { ($0.key, $0.value[$0.key] ?? $0.value[.tap] ?? "") }) : [.tap: source[.tap]?[.tap] ?? ""])
                return .grid(values, selected: e.secondStage ? e.second : .tap)
            case .hierarchy(let e):
                let values = e.visibleMap.compactMapValues { $0.label }
                return .grid(e.depth > 1 || e.expandedGuide ? values : [.tap: values[.tap] ?? ""], selected: e.selected)
            case .circle(let e): return .circle(e.currentMap, ranges: e.effectiveRanges, selected: e.selected, expanded: e.expandedGuide)
            }
        }
    }
    private func point(_ touch: UITouch) -> FlickPoint {
        let point = touch.location(in: self)
        return FlickPoint(point.x, point.y)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracked == nil, isEnabled, let touch = touches.first, let definition else { return }
        let policy = touchPolicy?() ?? (false, false)
        guard touchRouter?.begin(self, exclusive: policy.0, blocksSequentialTouches: policy.1) != false else { return }
        tracked = touch; isHighlighted = true
        gestureSettings = feedbackSettings.normalized(); gestureStyle = styleSettings.normalized
        var config = gestureConfiguration
        config.keyWidth = bounds.width; config.keyHeight = bounds.height
        config.stableDiagonal = gestureStyle.diagonal == .stable
        config.guideGrid = gestureStyle.presentation == .guideAboveKey
        config.startsAtKeyCenter = gestureStyle.startPosition == .keyCenter
        engine = Engine(definition, settings: gestureStyle)
        downPoint = point(touch); wasFlick = false; activeConfiguration = config
        engine?.begin(downPoint, config)
        updatePopup()
        let timer = Timer(timeInterval: Double(gestureSettings.longPressMilliseconds) / 1000, repeats: false) { [weak self] _ in
            guard let self, self.tracked != nil, self.engine?.holdPending == true else { return }
            self.engine?.hold(); self.updatePopup()
        }
        holdTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch) else { return }
        updateMovement(point(touch))
        engine?.move(point(touch))
        if engine?.holdPending != true { holdTimer?.invalidate(); holdTimer = nil }
        updatePopup()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch) else { return }
        finishActiveInput()
    }
    func finishActiveInput() {
        guard let touch = tracked else { return }
        updateMovement(point(touch))
        let result = engine?.end(point(touch), wasFlick: wasFlick)
        cancelActiveInput()
        if let result { emit(result) }
    }
    private func emit(_ result: CommitEvent) {
        if let onCommit { onCommit(result) } else { onOutput?(result.output) }
    }
    private func updateMovement(_ point: FlickPoint) {
        let dx = point.x - downPoint.x, dy = point.y - downPoint.y
        let distance = activeConfiguration.circularThreshold ? hypot(dx, dy) : max(abs(dx), abs(dy))
        wasFlick = wasFlick || distance >= max(1, activeConfiguration.threshold)
    }
    func cancelActiveInput() {
        touchRouter?.end(self)
        holdTimer?.invalidate(); holdTimer = nil
        tracked = nil; engine = nil; isHighlighted = false
        popup?.removeFromSuperview(); popup = nil
    }
    private func updatePopup() {
        guard gestureSettings.popupVisible, let host = popupHost, let engine else { return }
        if popup == nil { let view = MultiStageFlickPopupView(); host.addSubview(view); popup = view }
        let palette = popupPalette ?? KeyboardPalette(hue: 0.73, dark: traitCollection.userInterfaceStyle == .dark)
        popup?.update(engine.preview, palette: palette, fontSize: gestureStyle.popupTextSize.map { CGFloat($0) } ?? engine.defaultPopupTextSize)
        popup?.place(keyRect: convert(bounds, to: host), host: host,
                     scale: CGFloat(gestureSettings.popupScalePercent / 100), above: gestureStyle.presentation == .guideAboveKey)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        for (label, position) in guideLabels {
            let size = CGSize(width: bounds.width / 3, height: bounds.height / 3)
            label.frame = CGRect(x: position.x * (bounds.width - size.width), y: position.y * (bounds.height - size.height), width: size.width, height: size.height).insetBy(dx: 1, dy: 1)
        }
        if !guideLabels.isEmpty { titleLabel?.frame = bounds.insetBy(dx: bounds.width / 3, dy: bounds.height / 3) }
        if tracked != nil { updatePopup() }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelActiveInput() }
    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { cancelActiveInput() }; super.willMove(toWindow: newWindow)
    }
    override func accessibilityActivate() -> Bool {
        guard let definition else { return false }
        var evaluator = Engine(definition, settings: styleSettings.normalized)
        let center = FlickPoint(bounds.midX, bounds.midY)
        evaluator.begin(center, gestureConfiguration)
        if let result = evaluator.end(center, wasFlick: false) { emit(result); return true }
        return false
    }
    deinit { holdTimer?.invalidate(); popup?.removeFromSuperview() }
}
