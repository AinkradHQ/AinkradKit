import Foundation
import AinkradAppKit

/// What happened when the CLI tried to post a notification.
///
/// `CaseIterable` so a test can walk every case and assert the property that
/// matters most about all of them: none of them fails the caller.
enum SignalClientOutcome: Equatable, CaseIterable {
    case accepted
    /// Nothing is listening. The ordinary case — Ainkrad is simply not running.
    case hostNotRunning
    /// No credential is configured for this CLI yet.
    case noToken
    /// The host received it and refused it (unknown token, bad kind, throttled).
    case rejected
    /// The socket exists but the write did not complete.
    case writeFailed
    /// The path cannot be represented in `sockaddr_un`.
    case badSocketPath

    /// **Always 0. This is a load-bearing property, not an oversight.**
    ///
    /// `ainkrad notify` is designed to be called from CI steps, git hooks and
    /// Claude Code's notification hook — places where a non-zero exit fails
    /// somebody's build. A notification tool that can break a build is worse
    /// than no notification tool, because it converts a missing convenience
    /// into a broken pipeline.
    ///
    /// If a future cleanup is tempted to make failures exit 1: the failures
    /// here are "Ainkrad is not running" and "your token is stale". Neither is
    /// a reason to stop a deploy. The operator learns about them from
    /// `warning`, on stderr, which is exactly where a non-fatal problem
    /// belongs. `NotifyTests.allOutcomesExitZero` enforces this.
    var exitCode: Int32 { 0 }

    /// One line for stderr, or nil when there is nothing to say.
    ///
    /// Every non-success case has one. Exit 0 is only defensible if the
    /// operator can find out why nothing arrived — silence plus success is
    /// indistinguishable from a notification that worked.
    var warning: String? {
        switch self {
        case .accepted:
            return nil
        case .hostNotRunning:
            return "ainkrad notify: Ainkrad is not running; the notification was not delivered."
        case .noToken:
            return "ainkrad notify: no token configured. Pair this CLI in "
                 + "Ainkrad › Settings › Notifications, or set AINKRAD_SIGNAL_TOKEN."
        case .rejected:
            return "ainkrad notify: Ainkrad refused the notification (unrecognised token, "
                 + "invalid kind, or rate limited). Check Settings › Notifications."
        case .writeFailed:
            return "ainkrad notify: the notification could not be written to the socket."
        case .badSocketPath:
            return "ainkrad notify: the notification socket path is too long to use."
        }
    }
}

enum SignalClient {
    /// Encodes and posts one payload. Never throws: every failure is an
    /// outcome, because a throw out of `run()` is how a CLI ends up with a
    /// non-zero exit.
    static func send(payload: SignalWirePayload, socket url: URL) -> SignalClientOutcome {
        guard var data = try? JSONEncoder().encode(payload) else { return .rejected }
        // Newline-terminated: the server reads until newline, one payload per
        // connection.
        data.append(UInt8(ascii: "\n"))

        do {
            try SignalSocketClient.send(data, to: url)
            // Accepted here means "handed over", not "stored". The server
            // replies nothing and closes, so the CLI deliberately does not
            // wait: a notification tool that blocks on the host's SQLite write
            // would add latency to every CI step for no benefit the caller can
            // act on. A payload the host refuses shows up as a
            // `signal.rejected` row in the feed, which is where the user will
            // look.
            return .accepted
        } catch let failure as SignalSocketClient.SendFailure {
            switch failure {
            case .notListening: return .hostNotRunning
            case .pathTooLong: return .badSocketPath
            case .writeFailed: return .writeFailed
            case .socketUnavailable: return .writeFailed
            // SendFailure is a resilient enum from the SDK: a newer AinkradSignal
            // can add a case this CLI was not built against. Treated as a send
            // failure rather than as success, because the one thing that must
            // never happen is reporting a notification as delivered when it
            // was not.
            @unknown default: return .writeFailed
            }
        } catch {
            return .writeFailed
        }
    }
}
