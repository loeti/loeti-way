import Foundation

/// The one error type of the kit. `message` is shown to the user as is.
public struct LWError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}
