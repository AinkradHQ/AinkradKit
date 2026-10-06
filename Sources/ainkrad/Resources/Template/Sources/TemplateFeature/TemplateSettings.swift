import AinkradAppKit
import Foundation
import Observation

/// Example persisted document for the settings page. Swap it for whatever your
/// plugin actually needs to remember.
struct SettingsDocument: Codable, Equatable {
    var showGreeting: Bool = true
}

/// Small `Codable` state through the host's key→data store — see
/// `HostServices.documents`. Observable, so a view that reads it re-renders the
/// moment the settings page changes it.
@MainActor
@Observable
final class TemplateSettings {
    static let key = "settings"

    private let documents: PluginDocumentStore
    private var document: SettingsDocument
    /// False only when unreadable settings could not be set aside — then no
    /// save may overwrite the user's only copy (see `loadDocument`).
    private let canSave: Bool

    init(documents: PluginDocumentStore) {
        self.documents = documents
        let loaded = loadDocument(SettingsDocument.self, key: Self.key, from: documents, app: MyApp.id)
        self.document = loaded.value ?? SettingsDocument()
        self.canSave = loaded.canSave
    }

    var showGreeting: Bool {
        get { document.showGreeting }
        set {
            document.showGreeting = newValue
            save()
        }
    }

    private func save() {
        guard canSave else { return }
        do {
            documents.setData(try JSONEncoder().encode(document), forKey: Self.key)
        } catch {
            AinkradLog.logger(app: MyApp.id, area: "persistence").error("settings were not saved: \(error)")
        }
    }

    /// One instance per loaded plugin, so the settings page and every open
    /// window observe the same value. The host scopes `documents` to this app,
    /// so there is only ever one store to mirror.
    private static var instance: TemplateSettings?

    static func shared(host: HostServices) -> TemplateSettings {
        if let instance { return instance }
        let made = TemplateSettings(documents: host.documents)
        instance = made
        return made
    }
}
