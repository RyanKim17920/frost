import CoreGraphics
import Foundation
import Testing
@testable import FrostCore

/// macOS 27: which icons count as a new app's (`ItemMemoryStore.isNewOnArrangedBar`), driven through the launch path
/// with data seeded exactly as 0.4.2 stored it on macOS 27: remembered sections (`itemSections.v2`, written by layout
/// editor drops) and, only for a user who ran Frost on macOS 26 before, the seen icons (`knownItemIdentities.v2`);
/// 0.4.2 on 27 never wrote the seen set itself. The first launch of a version that places new icons must treat none of
/// the icons present then as new, and a second launch must change nothing.
@MainActor
@Suite struct ArrangedNewItemsUpgradeTests {
    let suiteName = "ArrangedNewItemsUpgradeTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    private var stored: NSDictionary { NSDictionary(dictionary: defaults.persistentDomain(forName: suiteName) ?? [:]) }

    private func item(_ windowID: CGWindowID, _ bundleID: String, _ key: String) -> MenuBarItem {
        MenuBarItem(windowID: windowID, frame: CGRect(x: CGFloat(windowID) * 30, y: 0, width: 29, height: 24),
                    isOnScreen: true, windowTitle: "", bundleID: bundleID, pid: 1, axDescription: nil,
                    identityKey: key)
    }

    /// One launch on 27: what `NewItemPlacer.evaluate` runs before a decision.
    private func launch(_ items: [MenuBarItem]) -> (store: ItemMemoryStore, seeded: Bool) {
        let store = ItemMemoryStore(defaults: defaults)
        store.migrateIdentities(items)
        let seeded = store.seedArrangedBaseline(items)
        return (store, seeded)
    }

    /// 0.4.2 on 27, arranged in the layout editor, never ran on 26: the seen set doesn't exist.
    @Test func iconsPresentAtTheFirstLaunchAreNotNew() {
        let sections = #"[{"bundleID":"com.example.vpn","key":"desc:VPN","section":"alwaysHidden"},"#
            + #"{"bundleID":"com.example.weather","key":"desc:Weather","section":"hidden"}]"#
        defaults.set(Data(sections.utf8), forKey: "itemSections.v2")
        let current = [item(1, "com.example.weather", "desc:Weather"), item(2, "com.example.vpn", "desc:VPN"),
                       item(3, "com.example.notes", "desc:Notes"), item(4, "com.example.timer", "desc:Timer")]

        let first = launch(current)
        #expect(first.seeded)
        // Arranged or not, nothing present now is a new app's icon.
        #expect(current.allSatisfy { !first.store.isNewOnArrangedBar($0, among: current) })
        // An app installed afterwards is.
        let later = item(5, "com.example.new", "desc:New")
        #expect(first.store.isNewOnArrangedBar(later, among: current + [later]))
        // The remembered sections are untouched.
        #expect(first.store.keeper.memory[ItemIdentity(bundleID: "com.example.vpn", key: "desc:VPN")] == .alwaysHidden)

        let afterFirst = stored
        let second = launch(current)
        #expect(!second.seeded)
        #expect(stored == afterFirst)
        #expect(current.allSatisfy { !second.store.isNewOnArrangedBar($0, among: current) })
    }

    /// A user who ran Frost on macOS 26 before upgrading macOS: the seen set is the 26 one, missing every icon added
    /// since. The first 27 launch adds them, so none of them is moved.
    @Test func aSeenSetFromMacOS26IsCompletedNotTrusted() {
        defaults.set(Data(#"[{"bundleID":"com.example.weather","key":"desc:Weather"}]"#.utf8),
                     forKey: "knownItemIdentities.v2")
        let current = [item(1, "com.example.weather", "desc:Weather"), item(2, "com.example.added", "desc:Added")]

        let first = launch(current)
        #expect(first.seeded)
        #expect(current.allSatisfy { !first.store.isNewOnArrangedBar($0, among: current) })
        #expect(first.store.known?.contains(ItemIdentity(bundleID: "com.example.added", key: "desc:Added")) == true)

        let afterFirst = stored
        #expect(!launch(current).seeded)
        #expect(stored == afterFirst)
    }

    /// Before the baseline exists nothing is new (a fresh install, or the first decision hasn't run yet).
    @Test func nothingIsNewBeforeTheBaseline() {
        let store = ItemMemoryStore(defaults: defaults)
        let fresh = item(1, "com.example.app", "desc:App")
        #expect(!store.isNewOnArrangedBar(fresh, among: [fresh]))
    }

    /// A remembered icon is never new, and recording a new one makes it seen and remembered in one step.
    @Test func recordingANewIconRemembersItsSection() {
        let (store, _) = launch([])
        let new = item(7, "com.example.new", "desc:New")
        #expect(store.isNewOnArrangedBar(new, among: [new]))
        #expect(store.recordArranged(new, in: .hidden, among: [new]))
        #expect(!store.isNewOnArrangedBar(new, among: [new]))
        #expect(store.keeper.memory[ItemIdentity(bundleID: "com.example.new", key: "desc:New")] == .hidden)

        // The next launch reads it back the same way.
        let reloaded = ItemMemoryStore(defaults: defaults)
        #expect(!reloaded.isNewOnArrangedBar(new, among: [new]))
        #expect(reloaded.keeper.memory[ItemIdentity(bundleID: "com.example.new", key: "desc:New")] == .hidden)
    }

    /// An icon whose identity is unresolved or shared with another current icon can't be told new.
    @Test func unresolvedOrSharedIdentitiesAreNotNew() {
        let (store, _) = launch([])
        let a = item(1, "com.example.app", "desc:Same"), b = item(2, "com.example.app", "desc:Same")
        #expect(!store.isNewOnArrangedBar(a, among: [a, b]))
        let unresolved = MenuBarItem(windowID: 3, frame: .zero, isOnScreen: true, windowTitle: "", bundleID: nil,
                                     pid: nil, axDescription: nil, identityKey: nil)
        #expect(!store.isNewOnArrangedBar(unresolved, among: [unresolved]))
    }
}
