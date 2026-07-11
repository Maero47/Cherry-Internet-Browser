//
//  SessionRestoreGroupTests.swift
//  Internet BrowserTests
//

import XCTest
@testable import Internet_Browser

final class SessionRestoreGroupTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SessionRestoreManager.shared.clearSession()
    }

    override func tearDown() {
        SessionRestoreManager.shared.clearSession()
        super.tearDown()
    }

    func testSavedTabEntryDecodesMissingGroupIDAsNil() throws {
        // Sessions saved before group persistence existed have no "groupID" key.
        let json = "[{\"urlString\":\"https://example.com\",\"title\":\"Example\"}]"
        let entries = try JSONDecoder().decode([SavedTabEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].groupID)
    }

    func testGroupAndMembershipRoundTrip() {
        let group = TabGroup(name: "Work", color: .purple, isCollapsed: true)

        let tabA = Tab(url: URL(string: "https://a.example")!)
        tabA.title = "A"
        tabA.group = group

        let privateTab = Tab(url: URL(string: "https://private.example")!, isPrivate: true)

        let tabB = Tab(url: URL(string: "https://b.example")!)
        tabB.title = "B"

        // selectedIndex refers to tabB's position (2) in the full array, but
        // the private tab at index 1 is excluded from what gets saved — the
        // persisted index must be remapped to tabB's position among saved entries (1).
        SessionRestoreManager.shared.saveSession(tabs: [tabA, privateTab, tabB], groups: [group], selectedIndex: 2)

        let loadedEntries = SessionRestoreManager.shared.loadSavedTabs()
        let loadedGroups = SessionRestoreManager.shared.loadSavedGroups()
        let loadedSelectedIndex = SessionRestoreManager.shared.loadSelectedIndex()

        XCTAssertEqual(loadedEntries.count, 2, "the private tab must be excluded")
        XCTAssertEqual(loadedEntries[0].urlString, "https://a.example")
        XCTAssertEqual(loadedEntries[0].groupID, group.id)
        XCTAssertEqual(loadedEntries[1].urlString, "https://b.example")
        XCTAssertNil(loadedEntries[1].groupID)
        XCTAssertEqual(loadedSelectedIndex, 1, "index must be remapped past the excluded private tab")

        XCTAssertEqual(loadedGroups.count, 1)
        XCTAssertEqual(loadedGroups[0].id, group.id)
        XCTAssertEqual(loadedGroups[0].name, "Work")
        XCTAssertEqual(loadedGroups[0].colorRawValue, TabGroupColor.purple.rawValue)
        XCTAssertTrue(loadedGroups[0].isCollapsed)
    }

    func testEmptyGroupIsNotPersisted() {
        // A group whose only member is dropped from the save (private tab)
        // must not be persisted, or restore would recreate an orphaned group.
        let group = TabGroup(name: "Orphan")
        let privateTab = Tab(url: URL(string: "https://private.example")!, isPrivate: true)
        privateTab.group = group

        let plainTab = Tab(url: URL(string: "https://plain.example")!)

        SessionRestoreManager.shared.saveSession(tabs: [privateTab, plainTab], groups: [group], selectedIndex: 1)

        XCTAssertTrue(SessionRestoreManager.shared.loadSavedGroups().isEmpty)
    }

    func testTabManagerRestoreGroupPreservesID() {
        let manager = TabManager(createDefaultTab: false)
        let id = UUID()
        let group = manager.restoreGroup(id: id, name: "Reading", color: .green, isCollapsed: false)
        XCTAssertEqual(group.id, id)
        XCTAssertTrue(manager.tabGroups.contains(where: { $0.id == id }))
    }
}
