import Foundation

/// Display state for the popover's minimal service-status indicator. Pure view-model so it
/// can be unit-tested without spinning up SwiftUI. `internal` (not `private`) so
/// `@testable import` can reach it — see the plan's testability rule.
enum ServiceStatusDisplayState: Equatable {
    case loading
    case unavailable
    case ready(StatusSnapshot)

    static func make(snapshot: StatusSnapshot?, lastError: StatusError?) -> ServiceStatusDisplayState {
        if let snapshot {
            return .ready(snapshot)
        }
        if lastError != nil {
            return .unavailable
        }
        return .loading
    }
}
