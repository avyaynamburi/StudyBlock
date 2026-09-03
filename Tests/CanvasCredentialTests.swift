import Foundation

/// Guards the one failure that matters most: the feed URL is a bearer token,
/// and Foundation puts the whole URL inside `URLError`. Anything that renders
/// the underlying error writes a live credential to wherever that line goes.
@main
struct CanvasCredentialTests {
    static var failures = 0
    static var checks = 0

    static func check(_ c: Bool, _ label: String) {
        checks += 1
        if c { print("  ok   \(label)") } else { failures += 1; print("  FAIL \(label)") }
    }

    static func main() async {
        let secret = "SUPERSECRETTOKEN9137"
        let host = "no-such-canvas-host-zzz.invalid"
        let feed = "https://\(host)/feeds/calendars/user_\(secret).ics"

        print("\nURL normalizing")
        if case .failure(let e) = CanvasFeed.normalizedURL("http://canvas.edu/x.ics") {
            check(e == .insecureURL, "plain http is rejected, never silently upgraded")
        } else { check(false, "plain http is rejected") }
        if case .success(let u) = CanvasFeed.normalizedURL("webcal://canvas.edu/feeds/x.ics") {
            check(u.scheme == "https", "webcal:// becomes https://")
        } else { check(false, "webcal:// becomes https://") }
        if case .failure(let e) = CanvasFeed.normalizedURL("   ") {
            check(e == .noURL, "blank input reports noURL")
        } else { check(false, "blank input reports noURL") }

        print("\ncredential containment on a failed fetch")
        guard case .success(let url) = CanvasFeed.normalizedURL(feed) else {
            print("  FAIL could not build the test URL"); exit(1)
        }
        do {
            _ = try await CanvasFeed.fetch(url: url)
            check(false, "an unreachable host should have thrown")
        } catch let error as CanvasFeedError {
            let rendered = "\(error) | \(error.localizedDescription) | \(String(describing: error))"
            check(!rendered.contains(secret), "the thrown error carries no token")
            check(!rendered.contains(host), "the thrown error carries no host")
        } catch {
            check(false, "a non-CanvasFeedError escaped — that is the leak path")
        }

        print("\nevery error case, rendered")
        let all: [CanvasFeedError] = [.noURL, .malformedURL, .insecureURL, .offline, .timedOut,
                                      .unauthorized, .notFound, .server(status: 500), .transport,
                                      .empty, .noEvents]
        check(!all.contains { $0.localizedDescription.contains(secret) },
              "no error case can render a token")
        check(!all.contains { $0.localizedDescription.contains(host) },
              "no error case can render a host")

        print("\n\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
