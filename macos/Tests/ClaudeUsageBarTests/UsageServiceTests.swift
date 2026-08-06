import XCTest
@testable import ClaudeUsageBar

@MainActor
final class UsageServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testBackoffIntervalCapsAtSixtyMinutes() {
        XCTAssertEqual(
            UsageService.backoffInterval(retryAfter: 120, currentInterval: 30 * 60),
            60 * 60
        )
    }

    func testBackoffIntervalNeverReducesSixtyMinutePolling() {
        XCTAssertEqual(
            UsageService.backoffInterval(retryAfter: 120, currentInterval: 60 * 60),
            60 * 60
        )
    }

    func testFetchUsageRefreshesOn401AndRetriesOnce() async throws {
        let store = try makeStore()
        try store.save(
            StoredCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!
        let session = makeSession()
        var requests: [String] = []

        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            requests.append("\(request.httpMethod ?? "GET") \(request.url?.path ?? "") \(authorization)")

            switch (request.httpMethod, request.url?.path, authorization) {
            case ("GET", "/api/oauth/usage", "Bearer old-access"):
                return try Self.httpResponse(url: usageURL, statusCode: 401)
            case ("POST", "/v1/oauth/token", _):
                let body = try XCTUnwrap(Self.jsonBody(for: request))
                XCTAssertEqual(body["grant_type"], "refresh_token")
                XCTAssertEqual(body["refresh_token"], "refresh-old")
                XCTAssertEqual(body["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
                XCTAssertEqual(body["scope"], "user:profile user:inference")

                return try Self.httpResponse(
                    url: tokenURL,
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "new-access",
                      "refresh_token": "refresh-new",
                      "expires_in": 3600,
                      "scope": "user:profile user:inference"
                    }
                    """
                )
            case ("GET", "/api/oauth/usage", "Bearer new-access"):
                return try Self.httpResponse(
                    url: usageURL,
                    statusCode: 200,
                    body: """
                    {
                      "five_hour": { "utilization": 12, "resets_at": "2026-03-08T18:00:00Z" },
                      "seven_day": { "utilization": 20, "resets_at": "2026-03-15T18:00:00Z" }
                    }
                    """
                )
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: session,
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )

        await service.fetchUsage()

        XCTAssertTrue(service.isAuthenticated)
        XCTAssertNil(service.lastError)
        XCTAssertEqual(service.usage?.fiveHour?.utilization, 12)
        XCTAssertEqual(requests.count, 3)

        let saved = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(saved.refreshToken, "refresh-new")
        XCTAssertNotNil(saved.expiresAt)
    }

    func testFetchUsageDoesNotSignOutWhenRetriedRequestIsRateLimited() async throws {
        let store = try makeStore()
        try store.save(
            StoredCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!

        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""

            switch (request.httpMethod, request.url?.path, authorization) {
            case ("GET", "/api/oauth/usage", "Bearer old-access"):
                return try Self.httpResponse(url: usageURL, statusCode: 401)
            case ("POST", "/v1/oauth/token", _):
                return try Self.httpResponse(
                    url: tokenURL,
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "new-access",
                      "expires_in": 3600,
                      "scope": "user:profile user:inference"
                    }
                    """
                )
            case ("GET", "/api/oauth/usage", "Bearer new-access"):
                return try Self.httpResponse(
                    url: usageURL,
                    statusCode: 429,
                    headers: ["Retry-After": "120"]
                )
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )

        await service.fetchUsage()

        XCTAssertTrue(service.isAuthenticated)
        XCTAssertEqual(service.lastError, "Rate limited — backing off to 3600s")

        let saved = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(saved.refreshToken, "refresh-old")
    }

    func testFetchUsageSignsOutWhenRefreshFails() async throws {
        let store = try makeStore()
        try store.save(
            StoredCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!

        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""

            switch (request.httpMethod, request.url?.path, authorization) {
            case ("GET", "/api/oauth/usage", "Bearer old-access"):
                return try Self.httpResponse(url: usageURL, statusCode: 401)
            case ("POST", "/v1/oauth/token", _):
                return try Self.httpResponse(
                    url: tokenURL,
                    statusCode: 400,
                    body: #"{"error":"invalid_grant"}"#
                )
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )

        await service.fetchUsage()

        XCTAssertFalse(service.isAuthenticated)
        XCTAssertEqual(service.lastError, "Session expired — please sign in again")
        XCTAssertNil(store.load(defaultScopes: UsageService.defaultOAuthScopes))
    }

    func testFetchProfileDoesNotSignOutWhenUserinfoStillReturns401AfterRefresh() async throws {
        let store = try makeStore()
        try store.save(
            StoredCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let userinfoURL = URL(string: "https://example.com/api/oauth/userinfo")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!

        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""

            switch (request.httpMethod, request.url?.path, authorization) {
            case ("GET", "/api/oauth/userinfo", "Bearer old-access"):
                return try Self.httpResponse(url: userinfoURL, statusCode: 401)
            case ("POST", "/v1/oauth/token", _):
                return try Self.httpResponse(
                    url: tokenURL,
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "new-access",
                      "refresh_token": "refresh-new",
                      "expires_in": 3600,
                      "scope": "user:profile user:inference"
                    }
                    """
                )
            case ("GET", "/api/oauth/userinfo", "Bearer new-access"):
                return try Self.httpResponse(url: userinfoURL, statusCode: 401)
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: URL(string: "https://example.com/api/oauth/usage")!,
            userinfoEndpoint: userinfoURL,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )

        await service.fetchProfile()

        XCTAssertTrue(service.isAuthenticated)
        XCTAssertNil(service.accountEmail)
        XCTAssertNil(service.lastError)

        let saved = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(saved.refreshToken, "refresh-new")
    }

    func testFetchUsage429TriggersTokenRefresh() async throws {
        let store = try makeStore()
        try store.save(
            StoredCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!
        var refreshRequested = false

        MockURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/oauth/usage"):
                return try Self.httpResponse(
                    url: usageURL,
                    statusCode: 429,
                    headers: ["Retry-After": "60"]
                )
            case ("POST", "/v1/oauth/token"):
                refreshRequested = true
                return try Self.httpResponse(
                    url: tokenURL,
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "new-access",
                      "refresh_token": "refresh-new",
                      "expires_in": 3600,
                      "scope": "user:profile user:inference"
                    }
                    """
                )
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )

        await service.fetchUsage()

        XCTAssertTrue(refreshRequested, "Should attempt token refresh on 429")
        XCTAssertTrue(service.isAuthenticated)
        XCTAssertEqual(service.lastError, "Rate limited — backing off to 3600s")

        let saved = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(saved.refreshToken, "refresh-new")
    }

    func testFetchUsage429WithNoRefreshTokenJustBacksOff() async throws {
        let store = try makeStore()
        try store.save(
            StoredCredentials(
                accessToken: "old-access",
                refreshToken: nil,
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!
        var refreshRequested = false

        MockURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/oauth/usage"):
                return try Self.httpResponse(
                    url: usageURL,
                    statusCode: 429,
                    headers: ["Retry-After": "60"]
                )
            case ("POST", "/v1/oauth/token"):
                refreshRequested = true
                return try Self.httpResponse(url: tokenURL, statusCode: 200, body: "{}")
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )

        await service.fetchUsage()

        XCTAssertFalse(refreshRequested, "Should not attempt refresh when no refresh token")
        XCTAssertTrue(service.isAuthenticated)
        XCTAssertEqual(service.lastError, "Rate limited — backing off to 3600s")

        let saved = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(saved.accessToken, "old-access")
    }

    // MARK: - OAuth submission hardening (Task 2)

    func testSubmitOAuthCodeWhitespaceOnlyDoesNotCrashAndLeavesAwaitingCodeTrue() async throws {
        let store = try makeStore()
        let service = UsageService(
            session: makeSession(),
            usageEndpoint: URL(string: "https://example.com/api/oauth/usage")!,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: URL(string: "https://example.com/v1/oauth/token")!,
            credentialsStore: store,
            urlOpener: { _ in true }
        )

        service.startOAuthFlow()
        XCTAssertTrue(service.isAwaitingCode)

        await service.submitOAuthCode("   ")

        XCTAssertNotNil(service.lastError)
        XCTAssertTrue(service.isAwaitingCode, "whitespace-only paste must let the user retry")
    }

    func testSubmitOAuthCodeBareCodeWithPendingFlowIsRejected() async throws {
        let store = try makeStore()
        let service = UsageService(
            session: makeSession(),
            usageEndpoint: URL(string: "https://example.com/api/oauth/usage")!,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: URL(string: "https://example.com/v1/oauth/token")!,
            credentialsStore: store,
            urlOpener: { _ in true }
        )

        service.startOAuthFlow()
        XCTAssertTrue(service.isAwaitingCode)

        await service.submitOAuthCode("bare-code-without-state")

        XCTAssertEqual(service.lastError, "OAuth state mismatch — try again")
        XCTAssertFalse(service.isAwaitingCode)
        XCTAssertNil(store.load(defaultScopes: UsageService.defaultOAuthScopes))
    }

    func testSubmitOAuthCodeMismatchedStateIsRejected() async throws {
        let store = try makeStore()
        let service = UsageService(
            session: makeSession(),
            usageEndpoint: URL(string: "https://example.com/api/oauth/usage")!,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: URL(string: "https://example.com/v1/oauth/token")!,
            credentialsStore: store,
            urlOpener: { _ in true }
        )

        service.startOAuthFlow()

        await service.submitOAuthCode("some-code#totally-wrong-state")

        XCTAssertEqual(service.lastError, "OAuth state mismatch — try again")
        XCTAssertFalse(service.isAwaitingCode)
    }

    func testSubmitOAuthCodeWithCorrectStateSucceeds() async throws {
        let store = try makeStore()
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!
        var capturedURL: URL?

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: URL(string: "https://example.com/api/oauth/usage")!,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store,
            urlOpener: { url in
                capturedURL = url
                return true
            }
        )

        service.startOAuthFlow()
        let openedURL = try XCTUnwrap(capturedURL)
        let state = try XCTUnwrap(
            URLComponents(url: openedURL, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "state" })?
                .value
        )

        MockURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/oauth/token"):
                let body = try XCTUnwrap(Self.jsonBody(for: request))
                XCTAssertEqual(body["code"], "good-code")
                XCTAssertEqual(body["state"], state)
                return try Self.httpResponse(
                    url: tokenURL,
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "new-access",
                      "refresh_token": "refresh-new",
                      "expires_in": 3600,
                      "scope": "user:profile user:inference"
                    }
                    """
                )
            case ("GET", "/api/oauth/usage"), ("GET", "/api/oauth/userinfo"):
                return try Self.httpResponse(url: request.url!, statusCode: 200, body: "{}")
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        await service.submitOAuthCode("good-code#\(state)")

        XCTAssertNil(service.lastError)
        XCTAssertTrue(service.isAuthenticated)
        XCTAssertFalse(service.isAwaitingCode)

        let saved = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(saved.accessToken, "new-access")

        // On success, submitOAuthCode fires off startPolling()'s unstructured Task. Drain it
        // against our own handler so it doesn't race the next test's MockURLProtocol.handler.
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func testStartOAuthFlowUrlOpenerFalseSetsErrorAndDoesNotAwaitCode() throws {
        let store = try makeStore()
        let service = UsageService(
            session: makeSession(),
            usageEndpoint: URL(string: "https://example.com/api/oauth/usage")!,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: URL(string: "https://example.com/v1/oauth/token")!,
            credentialsStore: store,
            urlOpener: { _ in false }
        )

        service.startOAuthFlow()

        XCTAssertEqual(service.lastError, "Could not open Claude sign-in page")
        XCTAssertFalse(service.isAwaitingCode)
    }

    func testStartOAuthFlowUrlOpenerTrueAwaitsCode() throws {
        let store = try makeStore()
        let service = UsageService(
            session: makeSession(),
            usageEndpoint: URL(string: "https://example.com/api/oauth/usage")!,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: URL(string: "https://example.com/v1/oauth/token")!,
            credentialsStore: store,
            urlOpener: { _ in true }
        )

        service.startOAuthFlow()

        XCTAssertNil(service.lastError)
        XCTAssertTrue(service.isAwaitingCode)
    }

    // MARK: - fetchUsage re-entrancy guard (Task 4)

    func testConcurrentFetchUsageCallsResultInASingleRequest() async throws {
        let store = try makeStore()
        defer { store.delete() } // real Keychain entry — don't leak into later tests
        try store.save(
            StoredCredentials(
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let requestCount = Counter()

        MockURLProtocol.handler = { request in
            requestCount.increment()
            return try Self.httpResponse(
                url: usageURL,
                statusCode: 200,
                body: """
                {
                  "five_hour": { "utilization": 12, "resets_at": "2026-03-08T18:00:00Z" },
                  "seven_day": { "utilization": 20, "resets_at": "2026-03-15T18:00:00Z" }
                }
                """
            )
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: URL(string: "https://example.com/v1/oauth/token")!,
            credentialsStore: store
        )

        // Both child tasks are created back-to-back with no `await` in between, so
        // neither has had a chance to start running yet (this test method is itself
        // @MainActor and hasn't yielded). Whichever the actor scheduler runs first
        // will flip `isFetching` before it suspends on the network call; the other
        // is guaranteed to observe `isFetching == true` and bail out via the guard
        // the instant it gets its turn — deterministic, no artificial delay needed.
        async let first: Void = service.fetchUsage()
        async let second: Void = service.fetchUsage()
        _ = await (first, second)

        XCTAssertEqual(requestCount.value, 1, "second call should be dropped while the first is in flight")
        XCTAssertFalse(service.isFetching)
        XCTAssertEqual(service.usage?.fiveHour?.utilization, 12)
    }

    func testIsFetchingTrueDuringFlightFalseAfterOnSuccess() async throws {
        let store = try makeStore()
        defer { store.delete() } // real Keychain entry — don't leak into later tests
        try store.save(
            StoredCredentials(
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let gate = Gate()

        MockURLProtocol.handler = { request in
            gate.wait()
            return try Self.httpResponse(
                url: usageURL,
                statusCode: 200,
                body: """
                {
                  "five_hour": { "utilization": 12, "resets_at": "2026-03-08T18:00:00Z" },
                  "seven_day": { "utilization": 20, "resets_at": "2026-03-15T18:00:00Z" }
                }
                """
            )
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: URL(string: "https://example.com/v1/oauth/token")!,
            credentialsStore: store
        )

        XCTAssertFalse(service.isFetching)
        let inFlight = Task { await service.fetchUsage() }
        // Give the task a moment to reach the network call and flip isFetching.
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(service.isFetching)

        gate.open()
        await inFlight.value

        XCTAssertFalse(service.isFetching)
        XCTAssertNil(service.lastError)
    }

    func testIsFetchingFalseAfterErrorPath() async throws {
        let store = try makeStore()
        defer { store.delete() } // real Keychain entry — don't leak into later tests
        try store.save(
            StoredCredentials(
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!

        MockURLProtocol.handler = { request in
            try Self.httpResponse(url: usageURL, statusCode: 500)
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: URL(string: "https://example.com/v1/oauth/token")!,
            credentialsStore: store
        )

        await service.fetchUsage()

        XCTAssertFalse(service.isFetching)
        XCTAssertEqual(service.lastError, "HTTP 500")
    }

    func testIsFetchingGuardDoesNotBreak429Backoff() async throws {
        let store = try makeStore()
        defer { store.delete() } // real Keychain entry — don't leak into later tests
        try store.save(
            StoredCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!

        MockURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/oauth/usage"):
                return try Self.httpResponse(
                    url: usageURL,
                    statusCode: 429,
                    headers: ["Retry-After": "60"]
                )
            case ("POST", "/v1/oauth/token"):
                return try Self.httpResponse(
                    url: tokenURL,
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "new-access",
                      "refresh_token": "refresh-new",
                      "expires_in": 3600,
                      "scope": "user:profile user:inference"
                    }
                    """
                )
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )

        await service.fetchUsage()

        XCTAssertFalse(service.isFetching, "isFetching must clear on the 429 backoff return path too")
        XCTAssertEqual(service.lastError, "Rate limited — backing off to 3600s")

        // The guard must not leave isFetching stuck true — a subsequent call must be
        // able to run (and, since we're still rate limited, hit backoff again).
        await service.fetchUsage()
        XCTAssertFalse(service.isFetching)
    }

    private func makeStore(accountId: String = "test-account") throws -> StoredCredentialsStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return StoredCredentialsStore(accountId: accountId, directoryURL: directory)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func jsonBody(for request: URLRequest) -> [String: String]? {
        guard let body = bodyData(for: request),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: String] else {
            return nil
        }
        return object
    }

    private static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            guard bytesRead > 0 else { break }
            data.append(buffer, count: bytesRead)
        }

        return data.isEmpty ? nil : data
    }

    private static func httpResponse(
        url: URL,
        statusCode: Int,
        headers: [String: String] = [:],
        body: String = ""
    ) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )
        )
        return (response, Data(body.utf8))
    }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Concurrency test helpers

/// Thread-safe counter for observing how many times MockURLProtocol's handler ran.
/// startLoading() is invoked off the main actor by URLSession, so this can't be a
/// plain `@MainActor var` — it needs its own lock.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
    }
}

/// Blocks the calling (background) thread until opened, letting a test hold a mocked
/// network response open so two `fetchUsage()` calls can be made to race deliberately.
private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var opened = false

    func wait() {
        lock.lock()
        let alreadyOpen = opened
        lock.unlock()
        guard !alreadyOpen else { return }
        semaphore.wait()
    }

    func open() {
        lock.lock()
        let wasOpen = opened
        opened = true
        lock.unlock()
        guard !wasOpen else { return }
        semaphore.signal()
    }
}
