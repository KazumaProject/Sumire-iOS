/// NORMAL key lifecycle corresponding to Android TapLongPressInputController.
/// A long press is an event of its own; releasing it never also emits a tap.
public struct TapHoldEvaluator {
    public enum Output: Equatable { case tap, longPress, upAfterLongPress, longPressCancelled }
    public private(set) var isActive = false
    public private(set) var holdPending = false
    public private(set) var tapCancelled = false
    private var held = false
    private var down = FlickPoint(0, 0)
    private var config = MultiFlickConfiguration()
    public init() {}
    public mutating func begin(at point: FlickPoint, configuration: MultiFlickConfiguration) {
        clear(); down = point; config = configuration; isActive = true; holdPending = true
    }
    public mutating func move(to point: FlickPoint) {
        guard isActive else { return }
        if config.crossed(point - down) { holdPending = false }
        if point.x < -config.threshold || point.x > config.keyWidth + config.threshold ||
            point.y < -config.threshold || point.y > config.keyHeight + config.threshold {
            tapCancelled = true; holdPending = false
        }
    }
    public mutating func hold() -> Output? {
        guard isActive, holdPending, !tapCancelled, !held else { return nil }
        holdPending = false; held = true; return .longPress
    }
    public mutating func end() -> Output? {
        guard isActive else { return nil }
        let output: Output? = held ? .upAfterLongPress : (tapCancelled ? nil : .tap)
        clear(); return output
    }
    public mutating func cancel() -> Output? {
        let output: Output? = held ? .longPressCancelled : nil
        clear(); return output
    }
    private mutating func clear() { isActive = false; holdPending = false; tapCancelled = false; held = false }
}
