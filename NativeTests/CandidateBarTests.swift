import XCTest
import UIKit

final class CandidateBarTests: XCTestCase {
    private func withBar(_ body: @escaping (CandidateBar, UICollectionView) -> Void) {
        let finished = expectation(description: "Rendered candidate bar")
        DispatchQueue.main.async {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            let controller = UIViewController()
            window.rootViewController = controller
            let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 390, height: 44))
            bar.clipboardAccessAllowed = false
            controller.view.addSubview(bar)
            window.isHidden = false
            bar.showsShortcuts = false
            window.layoutIfNeeded()
            let collection = bar.subviews.compactMap { $0 as? UICollectionView }.first!
            body(bar, collection)
            window.isHidden = true
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
    }

    func testPendingUpdateKeepsFrameAndRejectsOldCandidateSelection() {
        withBar { bar, list in
            bar.candidates = ["東京", "東京都", "東京駅"]
            list.layoutIfNeeded()
            let first = list.cellForItem(at: IndexPath(item: 0, section: 0))
            XCTAssertNotNil(first)
            var selections: [Int] = []
            bar.onSelect = { selections.append($0) }
            bar.isUpdating = true
            XCTAssertEqual(list.numberOfItems(inSection: 0), 3)
            XCTAssertEqual(first?.accessibilityLabel, "東京")
            XCTAssertTrue(first?.accessibilityTraits.contains(.notEnabled) == true)
            bar.collectionView(list, didSelectItemAt: IndexPath(item: 0, section: 0))
            XCTAssertTrue(selections.isEmpty)
            bar.candidates = ["東京", "東京都", "東京湾"]
            XCTAssertTrue(first === list.cellForItem(at: IndexPath(item: 0, section: 0)))
            bar.isUpdating = false
            bar.collectionView(list, didSelectItemAt: IndexPath(item: 0, section: 0))
            XCTAssertEqual(selections, [0])
            XCTAssertFalse(first?.accessibilityTraits.contains(.notEnabled) ?? true)
        }
    }

    func testIdenticalResultsAndSelectionDoNotReplaceCells() {
        withBar { bar, list in
            bar.candidates = ["日本", "日本語"]
            list.layoutIfNeeded()
            let first = list.cellForItem(at: IndexPath(item: 0, section: 0))
            let second = list.cellForItem(at: IndexPath(item: 1, section: 0))
            XCTAssertNotNil(first); XCTAssertNotNil(second)
            bar.candidates = ["日本", "日本語"]
            bar.selectedIndex = 1
            XCTAssertTrue(first === list.cellForItem(at: IndexPath(item: 0, section: 0)))
            XCTAssertTrue(second === list.cellForItem(at: IndexPath(item: 1, section: 0)))
            XCTAssertFalse(first?.accessibilityTraits.contains(.selected) ?? true)
            XCTAssertTrue(second?.accessibilityTraits.contains(.selected) == true)
            bar.selectedIndex = nil
            XCTAssertFalse(second?.accessibilityTraits.contains(.selected) ?? true)
        }
    }

    func testExpandedListRetainsDuplicateCandidateIndicesDuringUpdates() {
        withBar { bar, list in
            bar.useExpandedLayout()
            bar.candidates = ["同じ", "別の候補", "同じ"]
            list.layoutIfNeeded()
            var selections: [Int] = []
            bar.onSelect = { selections.append($0) }
            bar.collectionView(list, didSelectItemAt: IndexPath(item: 2, section: 0))
            XCTAssertEqual(selections, [2])
            bar.isUpdating = true
            bar.collectionView(list, didSelectItemAt: IndexPath(item: 0, section: 0))
            XCTAssertEqual(selections, [2])
            bar.candidates = ["新しい候補", "同じ"]
            bar.isUpdating = false
            bar.collectionView(list, didSelectItemAt: IndexPath(item: 1, section: 0))
            XCTAssertEqual(selections, [2, 1])
            XCTAssertEqual((list.collectionViewLayout as? UICollectionViewFlowLayout)?.scrollDirection, .vertical)
        }
    }

    func testScrollableOffsetSurvivesUpdateAndClampsWhenListShrinks() {
        withBar { bar, list in
            bar.candidates = (0..<30).map { "候補\($0)" }
            list.layoutIfNeeded()
            list.setContentOffset(CGPoint(x: 200, y: 0), animated: false)
            let offset = list.contentOffset.x
            bar.candidates = (0..<30).map { $0 == 29 ? "末尾変更" : "候補\($0)" }
            XCTAssertEqual(list.contentOffset.x, offset, accuracy: 1)
            bar.candidates = ["ひとつ"]
            XCTAssertLessThanOrEqual(list.contentOffset.x, 0.5)
            XCTAssertEqual(list.numberOfItems(inSection: 0), 1)
            bar.candidates = []
            XCTAssertEqual(list.numberOfItems(inSection: 0), 0)
        }
    }
}
