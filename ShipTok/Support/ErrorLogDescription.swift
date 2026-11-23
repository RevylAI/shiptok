import Foundation

extension Error {
    var isTaskCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }

    // Revyl's own messages and URL error codes carry no content, while another error's description could, so only its type is named.
    var publicLogDescription: String {
        if let revylShipTokAPIError = self as? RevylShipTokAPIError {
            return revylShipTokAPIError.localizedDescription
        }
        if let urlError = self as? URLError {
            return "URLError \(urlError.code.rawValue)"
        }
        return String(describing: type(of: self))
    }
}
