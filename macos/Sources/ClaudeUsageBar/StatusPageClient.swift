import Foundation

/// Minimal request abstraction so tests can inject canned `(Data, HTTPURLResponse)` pairs
/// without subclassing `URLSession`. Conforms to `Sendable` so it crosses actor boundaries
/// freely (concrete impls must be value-like or thread-safe).
protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Default `HTTPClient` backed by a hardened ephemeral `URLSession`:
/// no cookies, no cache, 10s request timeout, 15s resource timeout, no connectivity wait,
/// `Accept: application/json`.
///
/// `URLSession` is documented thread-safe — wrapping it in a struct keeps `Sendable` clean.
struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    /// Build the canonical session for `StatusPageClient`. Ephemeral (no cookies/cache/auth
    /// headers) — minimal outbound surface, no PII sent.
    static func defaultSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = ["Accept": "application/json"]
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }

    static func `default`() -> URLSessionHTTPClient {
        URLSessionHTTPClient(session: defaultSession())
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StatusError.invalidResponse
        }
        return (data, http)
    }
}

/// Fetches `https://status.claude.com/api/v2/summary.json` and decodes it into the domain
/// `StatusPageSummary` type. Pure infra — no caching, no retry, no UI side effects.
///
/// Wrapped in an `actor` so URLSession + JSON decode run off the main actor.
actor StatusPageClient {
    private let baseURL: URL
    private let http: HTTPClient
    private let decoder: JSONDecoder
    private let userAgent: String

    init(
        baseURL: URL = URL(string: "https://status.claude.com")!,
        http: HTTPClient = URLSessionHTTPClient.default(),
        decoder: JSONDecoder = StatusPageClient.makeDecoder(),
        userAgent: String = StatusPageClient.defaultUserAgent
    ) {
        self.baseURL = baseURL
        self.http = http
        self.decoder = decoder
        self.userAgent = userAgent
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom(Self.decodeISO8601Date)
        return d
    }

    /// `JSONDecoder`'s built-in `.iso8601` strategy uses a strict `ISO8601DateFormatter`
    /// with no fractional-seconds support. Statuspage.io emits millisecond-precision
    /// timestamps (e.g. `2026-05-06T08:41:02.090Z`), which that strategy rejects — this
    /// mirrors the fractional-seconds-then-fallback pattern already used in
    /// `UsageModel.parseResetDate` so both formats decode reliably.
    private static let decodeISO8601Date: @Sendable (Decoder) throws -> Date = { decoder in
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        let isoFormatters: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime]
        ]
        for options in isoFormatters {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: value) {
                return date
            }
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected date string to be ISO8601-formatted."
        )
    }

    static let defaultUserAgent: String = {
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "0.0.0"
        return "ClaudeUsageBar/\(bundleVersion)"
    }()

    /// Fetch `/api/v2/summary.json` and return the domain summary.
    /// Cancellation is mapped to `.cancelled`; all other failure modes map to `StatusError`.
    func fetchSummary() async throws -> StatusPageSummary {
        let url = baseURL.appendingPathComponent("api/v2/summary.json")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await self.http.data(for: request)
        } catch let error as StatusError {
            throw error
        } catch let urlError as URLError {
            if urlError.code == .cancelled || Task.isCancelled {
                throw StatusError.cancelled
            }
            throw StatusError.transport(urlError.code)
        } catch is CancellationError {
            throw StatusError.cancelled
        } catch {
            // Last-resort fallback — never leak raw error text to users (handled at UI layer).
            throw StatusError.transport(.unknown)
        }

        if Task.isCancelled {
            throw StatusError.cancelled
        }

        guard (200...299).contains(http.statusCode) else {
            throw StatusError.http(http.statusCode)
        }

        do {
            let dto = try decoder.decode(StatuspageSummaryDTO.self, from: data)
            return dto.toDomain()
        } catch {
            throw StatusError.decode(String(describing: error))
        }
    }
}
