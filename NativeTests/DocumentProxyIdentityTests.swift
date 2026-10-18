import XCTest
import UIKit

final class DocumentProxyIdentityTests: XCTestCase {
    private final class Document: NSObject {
        @objc var documentIdentifier: NSUUID?
    }
    func testDisconnectedDocumentDoesNotForceBridgeNilUUID() {
        let document = Document()
        XCTAssertNil(DocumentProxyIdentity.read(document))
        let identifier = NSUUID()
        document.documentIdentifier = identifier
        XCTAssertEqual(DocumentProxyIdentity.read(document), identifier.uuidString)
        document.documentIdentifier = nil
        XCTAssertNil(DocumentProxyIdentity.read(document))
        XCTAssertNil(DocumentProxyIdentity.read(NSObject()))
    }
}
