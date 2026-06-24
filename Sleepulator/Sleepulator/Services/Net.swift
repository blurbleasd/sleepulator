import Foundation

/// A thrown HTTP non-2xx status, so retry/backoff can classify 5xx (transient) vs 4xx (caller's
/// problem — don't retry).
struct HTTPStatusError: LocalizedError {
    let statusCode: Int
    var errorDescription: String? { "HTTP \(statusCode)" }
}

/// Configured URLSessions + a small retry helper. Replaces the bare `URLSession.shared` used for
/// feed fetches and search, which had default (long) timeouts and failed on the first transient
/// blip — a poor fit for an app people refresh half-asleep on flaky Wi-Fi.
enum Net {
    /// Short-ish timeouts; waits for connectivity so a momentary drop doesn't hard-fail.
    static let feed: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 60
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    /// Episode downloads can be large and slow — generous resource timeout, still waits for
    /// connectivity.
    static let download: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60 * 60
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    /// Whether a failure is worth retrying: transient transport errors and HTTP 5xx, but never a
    /// 4xx (retrying a 404 just wastes time). Pure + static so it's unit-tested without a network.
    static func isRetryable(_ error: Error) -> Bool {
        if let status = (error as? HTTPStatusError)?.statusCode {
            return (500...599).contains(status)
        }
        guard let code = (error as? URLError)?.code else { return false }
        switch code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
             .dnsLookupFailed, .cannotFindHost, .resourceUnavailable, .badServerResponse:
            return true
        default:
            return false
        }
    }

    /// Run `op`, retrying transient failures with exponential backoff. `attempts` is the total
    /// number of tries (1 = no retry). A non-retryable error throws immediately.
    // Closure params are @MainActor to match the module's default actor isolation
    // (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor): the default `Net.isRetryable` and the
    // op/isRetryable literals callers pass are all MainActor-isolated, so the parameter types
    // must be too — otherwise the default-argument conversion "loses global actor 'MainActor'".
    @discardableResult
    static func retry<T>(attempts: Int = 3,
                         baseDelay: TimeInterval = 0.8,
                         isRetryable: @MainActor (Error) -> Bool = Net.isRetryable,
                         _ op: @MainActor () async throws -> T) async throws -> T {
        var lastError: Error?
        let total = max(1, attempts)
        for attempt in 0..<total {
            try Task.checkCancellation()   // don't start a new attempt after the caller went away
            do {
                return try await op()
            } catch {
                lastError = error
                if attempt == total - 1 || !isRetryable(error) { throw error }
                // Exponential backoff with ±20% jitter, so many feeds refreshing at once don't
                // retry in lockstep and hammer one host (thundering herd).
                let delay = baseDelay * pow(2.0, Double(attempt)) * Double.random(in: 0.8...1.2)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError ?? URLError(.unknown)
    }
}
