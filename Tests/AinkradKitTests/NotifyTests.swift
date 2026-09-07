import Testing
import Foundation
import AinkradAppKit
@testable import ainkrad

@Suite("ainkrad notify")
struct NotifyTests {
    @Test("arguments become a well-formed payload")
    func buildsPayload() throws {
        let payload = try Notify.makePayload(
            token: "tok", kind: "build.failed", severity: "failure",
            title: "Build failed", body: "3 errors", importance: "urgent", dedupeKey: "b:main")
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(payload)) as? [String: Any]
        #expect(json?["kind"] as? String == "build.failed")
        #expect(json?["severity"] as? String == "failure")
        #expect(json?["source"] == nil, "the CLI cannot name a source; the host derives it")
        #expect(json?["token"] as? String == "tok")
    }

    @Test("an unknown severity is a usage error, not a silent default")
    func rejectsBadSeverity() {
        #expect(throws: (any Error).self) {
            _ = try Notify.makePayload(token: "t", kind: "test.event", severity: "catastrophic",
                                       title: "t", body: nil, importance: nil, dedupeKey: nil)
        }
    }

    @Test("an unknown importance is a usage error too")
    func rejectsBadImportance() {
        #expect(throws: (any Error).self) {
            _ = try Notify.makePayload(token: "t", kind: "test.event", severity: "info",
                                       title: "t", body: nil, importance: "screaming",
                                       dedupeKey: nil)
        }
    }

    @Test("an invalid kind is refused locally, before a socket is opened")
    func rejectsBadKind() {
        // The host would reject it anyway, but reporting it here tells the
        // operator what is wrong instead of leaving a silent no-op.
        #expect(throws: (any Error).self) {
            _ = try Notify.makePayload(token: "t", kind: "Not A Kind", severity: "info",
                                       title: "t", body: nil, importance: nil, dedupeKey: nil)
        }
    }

    @Test("a missing socket exits 0 — a notification must never fail a build")
    func missingSocketExitsZero() {
        // Short path on purpose. `sockaddr_un.sun_path` holds ~103 bytes, and
        // the first version of this test used the temp directory plus a full
        // UUID — about 111 — so it exercised the path-length guard and never
        // reached `connect` at all. Worth keeping as a comment because the
        // limit is easy to blow past by accident and the failure looks
        // nothing like its cause.
        let absent = URL(fileURLWithPath: "/tmp/ainkrad-absent-\(UUID().uuidString.prefix(8)).sock")
        #expect(absent.path.utf8.count <= SignalSocketPath.maxPathBytes)
        let outcome = SignalClient.send(
            payload: SignalWirePayload(token: "t", kind: "test.event", severity: .info, title: "t"),
            socket: absent)
        #expect(outcome == .hostNotRunning)
        #expect(outcome.exitCode == 0)
    }

    @Test("a socket path too long to represent is reported as such, not as absent")
    func overlongSocketPath() {
        // Distinguished from `.hostNotRunning` because the fixes differ: one is
        // "start Ainkrad", the other is "this path can never work".
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "d", count: 200) + "/x.sock")
        let outcome = SignalClient.send(
            payload: SignalWirePayload(token: "t", kind: "test.event", severity: .info, title: "t"),
            socket: long)
        #expect(outcome == .badSocketPath)
        #expect(outcome.exitCode == 0)
    }

    @Test("every outcome exits 0; failures are stderr warnings only")
    func allOutcomesExitZero() {
        for outcome in SignalClientOutcome.allCases {
            #expect(outcome.exitCode == 0,
                    "\(outcome) must not break a CI step over a notification")
        }
    }

    @Test("every outcome has a warning to print, so nothing fails silently")
    func everyFailureExplainsItself() {
        // Exit 0 is only defensible if the operator can find out why nothing
        // arrived. An outcome with no message would be a silent no-op.
        for outcome in SignalClientOutcome.allCases where outcome != .accepted {
            #expect(!(outcome.warning ?? "").isEmpty, "\(outcome) needs a stderr warning")
        }
        #expect(SignalClientOutcome.accepted.warning == nil, "success prints nothing")
    }

    @Test("with no token, the command explains how to pair and still exits 0")
    func missingTokenIsExplained() {
        let outcome = SignalClientOutcome.noToken
        #expect(outcome.exitCode == 0)
        #expect((outcome.warning ?? "").lowercased().contains("token"))
    }
}
