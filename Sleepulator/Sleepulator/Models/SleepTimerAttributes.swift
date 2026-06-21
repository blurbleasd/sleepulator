import Foundation
#if canImport(ActivityKit)
import ActivityKit

public struct SleepTimerAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var timerRemaining: TimeInterval
        var endDate: Date?
    }

    public init() {}
}
#endif
