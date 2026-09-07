import ArgumentParser
import Foundation
import AinkradAppKit

/// Posts one notification into Ainkrad's Signal feed.
///
/// Built for hooks and CI, which shapes every decision here: it exits 0
/// whatever happens (see `SignalClientOutcome.exitCode`), it does not wait for
/// the host to store anything, and it never prints on success — a hook that
/// chatters into a build log gets removed from the build.
///
/// The command cannot name its own source. It presents a token and the host
/// derives the source from it, so `--source` does not exist and cannot be
/// added without breaking the guarantee that attribution is not forgeable.
struct Notify: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify",
        abstract: "Post a notification into Ainkrad's feed.",
        discussion: """
        Intended for git hooks, CI steps and agent notification hooks. Exits 0 \
        even when Ainkrad is not running, so it can never fail the command that \
        called it; problems are reported on stderr.

        The token comes from AINKRAD_SIGNAL_TOKEN, or from the CLI's config \
        written when you pair it in Ainkrad › Settings › Notifications.

        Examples:
          ainkrad notify --kind build.failed --severity failure --title "Build failed"
          ainkrad notify --kind agent.waiting --severity info --title "Claude needs input" \\
            --importance urgent
        """
    )

    @Option(name: .long, help: "Event kind, e.g. build.failed. Lowercase, dots, dashes, underscores.")
    var kind: String

    @Option(name: .long, help: "info | success | warning | failure")
    var severity: String

    @Option(name: .long, help: "One-line summary shown in the feed.")
    var title: String

    @Option(name: .long, help: "Optional detail.")
    var body: String?

    @Option(name: .long, help: "background | normal | urgent. Default normal.")
    var importance: String?

    @Option(name: .customLong("dedupe-key"),
            help: "Repeats within a minute coalesce into one row with a count.")
    var dedupeKey: String?

    /// Builds and validates the payload.
    ///
    /// Static and pure so tests exercise it without a socket. Validation
    /// happens HERE, before anything is opened: the host would reject a bad
    /// kind anyway, but by then the operator has an exit 0 and no explanation,
    /// which is indistinguishable from a delivered notification.
    static func makePayload(token: String, kind: String, severity: String, title: String,
                            body: String?, importance: String?,
                            dedupeKey: String?) throws -> SignalWirePayload {
        guard let severity = SignalSeverity(rawValue: severity) else {
            throw ValidationError("Unknown severity '\(severity)'. Use one of: "
                + SignalSeverity.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }
        let resolvedImportance: SignalImportance
        if let importance {
            guard let parsed = SignalImportance(rawValue: importance) else {
                throw ValidationError("Unknown importance '\(importance)'. Use one of: "
                    + SignalImportance.allCases.map(\.rawValue).joined(separator: ", ") + ".")
            }
            resolvedImportance = parsed
        } else {
            resolvedImportance = .normal
        }
        guard SignalKind.isValid(kind) else {
            throw ValidationError("Invalid kind '\(kind)'. Use lowercase letters, digits, "
                + "'.', '-' and '_' — for example build.failed.")
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--title must not be empty.")
        }

        return SignalWirePayload(token: token, kind: kind, severity: severity, title: title,
                                 body: body, importance: resolvedImportance,
                                 dedupeKey: dedupeKey)
    }

    /// Where the CLI's token comes from.
    ///
    /// The environment variable wins so a CI job can supply a token without
    /// writing a credential to disk in the workspace.
    static func resolveToken(environment: [String: String] = ProcessInfo.processInfo.environment,
                             configURL: URL = Notify.defaultConfigURL()) -> String? {
        if let fromEnvironment = environment["AINKRAD_SIGNAL_TOKEN"],
           !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode([String: String].self, from: data),
              let token = config["token"], !token.isEmpty else { return nil }
        return token
    }

    static func defaultConfigURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Ainkrad", isDirectory: true)
            .appendingPathComponent("cli-signal.json")
    }

    func run() throws {
        // A validation error is the ONE thing that exits non-zero, and
        // deliberately: it means the invocation itself is wrong — a typo in a
        // hook the author is currently writing — not that delivery failed. It
        // is reported by ArgumentParser before anything is sent.
        guard let token = Self.resolveToken() else {
            Self.report(.noToken)
            return
        }
        let payload = try Self.makePayload(token: token, kind: kind, severity: severity,
                                           title: title, body: body, importance: importance,
                                           dedupeKey: dedupeKey)
        Self.report(SignalClient.send(payload: payload, socket: SignalSocketPath.default()))
    }

    private static func report(_ outcome: SignalClientOutcome) {
        if let warning = outcome.warning {
            FileHandle.standardError.write(Data((warning + "\n").utf8))
        }
    }
}
