import AinkradAppKit
import SwiftUI

/// Your app. Rename `MyApp`, the id, name, and icon. Read theme via
/// `host.theme.tokens` and persist via `host.documents` — never host internals.
public struct MyApp: AinkradApp {
    public static let id = "myplugin"
    public static let displayName = "My Plugin"
    public static let icon = "puzzlepiece.extension"

    public static func makeRootView(host: HostServices) -> AnyView {
        AnyView(RootView(settings: TemplateSettings.shared(host: host), theme: host.theme))
    }

    public static func makeSettingsView(host: HostServices) -> AnyView {
        AnyView(AinkradCaption("Your own settings view goes here."))
    }

    /// Worked example of the additive settings contract: declare the fields
    /// you can as real descriptors (searchable, deep-linkable, laid out with
    /// every other setting), and leave anything bespoke as a single
    /// `.custom` field wrapping your own view. Returning `nil` here (the
    /// protocol default) is also valid — it just falls back to rendering
    /// `makeSettingsView(host:)` as-is, searchable by app name only.
    public static func settingsCatalog(host: HostServices) -> SettingsPage? {
        let root = SettingsPath(["app", id])
        let general = root.appending("general")
        let settings = TemplateSettings.shared(host: host)

        return SettingsPage(
            path: root, title: displayName, icon: icon,
            group: .installedApps, order: 0,
            groups: [
                SettingsGroup(
                    path: general, title: "General",
                    fields: [
                        // A real, declared field: shows up in search and gets
                        // the shared toggle UI for free.
                        SettingsField(
                            path: general.appending("greeting"),
                            label: "Show greeting",
                            help: "Show the \"Hello from My Plugin\" banner.",
                            keywords: ["greeting", "hello", "banner"],
                            kind: .toggle(
                                Binding(
                                    get: { settings.showGreeting },
                                    set: { settings.showGreeting = $0 })),
                            defaultDescription: "On",
                            isModified: { settings.showGreeting != true },
                            reset: { settings.showGreeting = true }),
                        // The escape hatch: anything that isn't a toggle/select/
                        // slider/text field can still be indexed and found by
                        // wrapping your existing view in `.custom`.
                        SettingsField(
                            path: general.appending("advanced"),
                            label: "Advanced",
                            help: "The plugin's own settings pane.",
                            keywords: ["advanced", "custom"],
                            kind: .custom(makeSettingsView(host: host))),
                    ])
            ],
            appID: id)
    }
}
