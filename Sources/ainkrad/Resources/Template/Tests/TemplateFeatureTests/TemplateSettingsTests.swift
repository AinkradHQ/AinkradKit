import AinkradAppKit
import Foundation
import XCTest

@testable import TemplateFeature

@MainActor
final class TemplateSettingsTests: XCTestCase {
    func testSettingsDocumentRoundTripsThroughTheDocumentStore() {
        let docs = MemoryDocs()
        XCTAssertTrue(TemplateSettings(documents: docs).showGreeting, "an empty store reads the default")

        TemplateSettings(documents: docs).showGreeting = false

        XCTAssertFalse(TemplateSettings(documents: docs).showGreeting, "the saved value did not survive a reload")
        let saved = try? JSONDecoder().decode(SettingsDocument.self, from: docs.storage[TemplateSettings.key] ?? Data())
        XCTAssertEqual(saved, SettingsDocument(showGreeting: false))
    }

    func testUnreadableSettingsAreSetAsideNotOverwritten() {
        let docs = MemoryDocs()
        let garbage = Data("not json".utf8)
        docs.storage[TemplateSettings.key] = garbage

        let settings = TemplateSettings(documents: docs)
        XCTAssertTrue(settings.showGreeting, "unreadable settings fall back to the default")
        XCTAssertEqual(
            docs.storage.first { $0.key.hasPrefix("\(TemplateSettings.key).corrupt-") }?.value, garbage,
            "the unreadable bytes must be kept under a .corrupt- key")

        settings.showGreeting = false
        XCTAssertNotNil(docs.storage[TemplateSettings.key], "after setting aside, saving works again")
    }
}

/// In-memory `PluginDocumentStore`, standing in for the host's.
private final class MemoryDocs: PluginDocumentStore {
    var storage: [String: Data] = [:]
    func data(forKey key: String) -> Data? { storage[key] }
    func setData(_ data: Data?, forKey key: String) { storage[key] = data }
}
