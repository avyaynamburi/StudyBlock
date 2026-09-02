import Foundation

/// Why a sync failed, in terms safe to show and safe to log.
///
/// Every case is a fixed string. Nothing here interpolates the underlying
/// error, because the feed URL carries a live token and Foundation puts that
/// URL inside `URLError` — in `failingURL`, and in the localized description
/// of several codes. `"sync failed: \(error)"` is therefore a credential
/// written to wherever that line goes. Report the category, never the cause.
enum CanvasFeedError: LocalizedError, Equatable {
    case noURL
    case malformedURL
    case insecureURL
    case offline
    case timedOut
    case unauthorized
    case notFound
    case server(status: Int)
    case transport
    case empty
    case noEvents

    var errorDescription: String? {
        switch self {
        case .noURL:
            return "No Canvas feed URL saved yet."
        case .malformedURL:
            return "That doesn\u{2019}t look like a URL. Paste the whole link from Canvas."
        case .insecureURL:
            return "The feed URL has to be https (or the webcal link Canvas gives you)."
        case .offline:
            return "No internet connection."
        case .timedOut:
            return "Canvas didn\u{2019}t respond in time. Try again in a moment."
        case .unauthorized:
            return "Canvas rejected the feed URL. It may have been reset \u{2014} "
                + "copy a fresh one from Canvas \u{2192} Calendar \u{2192} Calendar Feed."
        case .notFound:
            return "Canvas couldn\u{2019}t find that feed. Check the URL was copied whole."
        case .server(let status):
            return "Canvas returned an error (HTTP \(status))."
        case .transport:
            return "Couldn\u{2019}t reach Canvas."
        case .empty:
            return "Canvas returned an empty feed."
        case .noEvents:
            return "That URL didn\u{2019}t contain a calendar. Make sure it\u{2019}s the "
                + "Calendar Feed link, not a Canvas page you were looking at."
        }
    }
}

/// Fetches the raw feed and interprets nothing.
///
/// Keeping it to network I/O alone is what lets every stage downstream be
/// tested from a saved fixture, with no network and no credential in reach.
enum CanvasFeed {
    /// Canvas hands out `webcal://` links, which `URLSession` won't load.
    /// The scheme is the only difference — swapping it for https is what the
    /// calendar apps do too. Anything already http(s) is passed through, with
    /// plain http rejected rather than silently upgraded: this URL is a
    /// bearer token and it is not going over the wire in clear text.
    static func normalizedURL(_ text: String) -> Result<URL, CanvasFeedError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.noURL) }

        var candidate = trimmed
        let lower = trimmed.lowercased()
        if lower.hasPrefix("webcal://") {
            candidate = "https://" + trimmed.dropFirst("webcal://".count)
        } else if lower.hasPrefix("http://") {
            return .failure(.insecureURL)
        } else if !lower.hasPrefix("https://") {
            return .failure(.insecureURL)
        }

        guard let url = URL(string: candidate), let host = url.host, !host.isEmpty else {
            return .failure(.malformedURL)
        }
        return .success(url)
    }

    /// Downloads the feed. `URLError` is mapped to a fixed case by code —
    /// never rendered — for the reason spelled out on `CanvasFeedError`.
    static func fetch(url: URL, session: URLSession = .shared) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("text/calendar", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw CanvasFeedError.offline
            case .timedOut:
                throw CanvasFeedError.timedOut
            default:
                throw CanvasFeedError.transport
            }
        } catch {
            throw CanvasFeedError.transport
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            switch http.statusCode {
            case 401, 403: throw CanvasFeedError.unauthorized
            case 404, 410: throw CanvasFeedError.notFound
            default: throw CanvasFeedError.server(status: http.statusCode)
            }
        }
        guard !data.isEmpty else { throw CanvasFeedError.empty }
        return data
    }
}

/// Stores the feed URL in the login keychain.
///
/// It lives here rather than in `UserDefaults` because it is a bearer
/// credential: anyone holding the URL can read the calendar. `UserDefaults`
/// would put it in a world-readable plist inside the app container and into
/// every preferences backup.
enum CanvasCredential {
    private static let service = "com.avyay.StudyBlock.canvas"
    private static let account = "ics-feed-url"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    @discardableResult
    static func save(_ url: String) -> Bool {
        let data = Data(url.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func clear() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
