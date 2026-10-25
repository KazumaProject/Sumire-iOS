// Run with -configuration Debug: this hosted adapter test inspects internal app types.
#if DEBUG
import XCTest
import UIKit
import SumireCore
@testable import Sumire

/// Samples enter the production UITouch adapter and actual Surface callbacks.
/// This does not simulate the OS delivering a physical multi-segment gesture.
@MainActor
final class FlickStyleTouchAdapterTests: XCTestCase {
    private final class SampleTouch: UITouch {
        var sample = CGPoint.zero
        override func location(in view: UIView?) -> CGPoint { sample }
    }
    @MainActor
    private final class Host {
        let suite = "FlickStyleTouchAdapter.\(UUID().uuidString)"
        let defaults: UserDefaults
        let surface: Sumire.KeyboardSurface
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        var reading = ""
        init(style: SumireFlickStyle, arrangement: SumireKeyArrangement, slots: [CircularSlotSetting] = []) {
            defaults = UserDefaults(suiteName: suite)!
            defaults.set("builtin:sumire", forKey: "keyboard.lastUsed")
            defaults.set(arrangement.rawValue, forKey: "sumire.keyArrangement")
            var settings = FlickStyleSettings(); settings.style = style
            if !slots.isEmpty { settings.circularDirectionCount = 5 }
            settings.save(defaults: defaults)
            _ = CircularSlotSetting.save(slots, defaults: defaults)
            var feedback = TouchFeedbackSettings(); feedback.popupVisible = true
            feedback.save(defaults: defaults)
            surface = Sumire.KeyboardSurface()
            surface.settingsDefaults = defaults
            surface.updateMarkedText = { [weak self] text, _ in self?.reading = text }
            surface.updateMarkedSelection = { [weak self] text, _, _ in self?.reading = text }
            surface.reloadAppearance()
            container.addSubview(surface)
            NSLayoutConstraint.activate([surface.widthAnchor.constraint(equalToConstant: 390),
                surface.topAnchor.constraint(equalTo: container.topAnchor),
                surface.leadingAnchor.constraint(equalTo: container.leadingAnchor)])
            container.layoutIfNeeded(); surface.layoutIfNeeded()
        }
        func cleanup() { defaults.removePersistentDomain(forName: suite) }
        func key(_ id: String = "sumire-ka") throws -> Sumire.MultiStageFlickKey {
            @MainActor func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
            return try XCTUnwrap(descendants(surface).first { $0.accessibilityIdentifier == id } as? Sumire.MultiStageFlickKey)
        }
        var popupCount: Int { surface.subviews.filter { $0 is Sumire.MultiStageFlickPopupView }.count }
    }
    private func trace(_ host: Host, _ points: [CGPoint]) throws {
        let key = try host.key(), touch = SampleTouch()
        let center = CGPoint(x: key.bounds.midX, y: key.bounds.midY)
        XCTAssertGreaterThan(key.bounds.width, 0)
        touch.sample = center
        key.touchesBegan([touch], with: nil)
        XCTAssertEqual(host.popupCount, 1)
        for point in points {
            touch.sample = CGPoint(x: center.x + point.x, y: center.y + point.y)
            key.touchesMoved([touch], with: nil)
        }
        key.touchesEnded([touch], with: nil)
        XCTAssertEqual(host.popupCount, 0)
        key.touchesEnded([touch], with: nil) // A duplicate end cannot commit twice.
    }
    func testRepeatedCenterTapsUseActualKeyTypeAcrossArrangements() throws {
        for arrangement in SumireKeyArrangement.allCases {
            for style in SumireFlickStyle.allCases {
                let host = Host(style: style, arrangement: arrangement); defer { host.cleanup() }
                try trace(host, []); try trace(host, [])
                let expected = style == .circle || style == .threeStep ? "かか" : "き"
                XCTAssertEqual(host.reading, expected, "\(arrangement)/\(style)")
            }
        }
    }
    func testTwoStageVoicingAndReturnAcrossAllArrangements() throws {
        for arrangement in SumireKeyArrangement.allCases {
            let host = Host(style: .twoStep, arrangement: arrangement); defer { host.cleanup() }
            try trace(host, [.init(x: -40, y: 0), .init(x: -60, y: 0)])
            XCTAssertEqual(host.reading, "き", "\(arrangement)")
            try trace(host, [.init(x: -40, y: 0), .init(x: -90, y: 35)])
            XCTAssertEqual(host.reading, "きぎ", "\(arrangement)")
            try trace(host, [.init(x: -40, y: 0), .zero])
            XCTAssertEqual(host.reading, "きぎか", "\(arrangement)")
        }
    }
    func testReturnToCenterUsesReferenceFinalDirection() throws {
        for style in [SumireFlickStyle.standard, .twoStep, .centerGuide, .donut] {
            let host = Host(style: style, arrangement: .toggle); defer { host.cleanup() }
            try trace(host, [])
            try trace(host, [.init(x: -65, y: 0), .zero])
            XCTAssertEqual(host.reading, "き", "\(style)")
        }
    }
    func testThreeStageContractedSoundAcrossAllArrangements() throws {
        for arrangement in SumireKeyArrangement.allCases {
            let host = Host(style: .threeStep, arrangement: arrangement); defer { host.cleanup() }
            try trace(host, [.init(x: -40, y: 0), .init(x: 0, y: -60), .init(x: -60, y: -100)])
            XCTAssertEqual(host.reading, "きゅう", "\(arrangement)")
        }
    }
    func testHierarchyReleaseDoesNotInventAnUndeliveredMove() throws {
        let host = Host(style: .threeStep, arrangement: .toggle); defer { host.cleanup() }
        let key = try host.key(), touch = SampleTouch()
        touch.sample = CGPoint(x: key.bounds.midX, y: key.bounds.midY)
        key.touchesBegan([touch], with: nil)
        touch.sample.x -= 65
        key.touchesEnded([touch], with: nil)
        XCTAssertEqual(host.reading, "か")
        XCTAssertEqual(host.popupCount, 0)
    }
    func testDonutDirectionsAndConfiguredMapSwitch() throws {
        for arrangement in SumireKeyArrangement.allCases {
            let host = Host(style: .donut, arrangement: arrangement); defer { host.cleanup() }
            try trace(host, [.init(x: 65, y: 0)])
            try trace(host, [.init(x: 0, y: -65)])
            XCTAssertEqual(host.reading, "けく", "\(arrangement)")
            let switched = Host(style: .donut, arrangement: arrangement,
                slots: [.init(mode: 0, keyIdentifier: "か", slot: 4, action: .switchMap)])
            defer { switched.cleanup() }
            let angle = 198.0 * Double.pi / 180
            try trace(switched, [.init(x: 65 * cos(angle), y: 65 * sin(angle)), .zero])
            XCTAssertEqual(switched.reading, "が", "\(arrangement)")
        }
    }
    func testLongPressTimerAndCancelFollowReferenceTapClassification() async throws {
        let host = Host(style: .twoStep, arrangement: .toggle); defer { host.cleanup() }
        try trace(host, [])
        XCTAssertEqual(host.reading, "か")
        let key = try host.key(), touch = SampleTouch()
        touch.sample = CGPoint(x: key.bounds.midX, y: key.bounds.midY)
        key.touchesBegan([touch], with: nil)
        let fired = expectation(description: "production hold timer has elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { fired.fulfill() }
        await fulfillment(of: [fired], timeout: 2)
        XCTAssertEqual(host.popupCount, 1)
        key.touchesEnded([touch], with: nil)
        XCTAssertEqual(host.reading, "き")
        XCTAssertEqual(host.popupCount, 0)
        key.touchesBegan([touch], with: nil)
        key.touchesCancelled([touch], with: nil)
        XCTAssertEqual(host.popupCount, 0)
        key.touchesEnded([touch], with: nil)
        XCTAssertEqual(host.reading, "き")
    }
}

#endif
