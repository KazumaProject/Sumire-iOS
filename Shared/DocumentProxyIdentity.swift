import UIKit

/// UIKit can return nil while a document disconnects, despite the nonnull API.
/// Avoid Swift's unconditional NSUUID -> UUID bridge during that transition.
enum DocumentProxyIdentity {
    static func read(_ object: AnyObject) -> String? {
        let selector = #selector(getter: UITextDocumentProxy.documentIdentifier)
        guard let object = object as? NSObject, object.responds(to: selector),
              let identifier = object.perform(selector)?.takeUnretainedValue() as? NSUUID else { return nil }
        return identifier.uuidString
    }
}
