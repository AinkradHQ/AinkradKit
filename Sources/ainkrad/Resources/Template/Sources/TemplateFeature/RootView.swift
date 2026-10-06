import AinkradAppKit
import SwiftUI

/// The app's window. Built from kit components, so it follows the host's skin
/// and typography; it reads `settings`, so the "Show greeting" toggle on the
/// settings page shows and hides the greeting live.
struct RootView: View {
    let settings: TemplateSettings
    let theme: HostTheme

    var body: some View {
        Group {
            if settings.showGreeting {
                AinkradEmptyState(
                    icon: MyApp.icon,
                    title: "Hello from \(MyApp.displayName)",
                    message: "Start building in Sources/TemplateFeature.")
            } else {
                AinkradCaption("Greeting hidden. Turn it back on in Settings.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.tokens.background)
    }
}
