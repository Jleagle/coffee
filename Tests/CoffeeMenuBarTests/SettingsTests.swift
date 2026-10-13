import Foundation
import Testing
@testable import CoffeeMenuBar

/// The per-event notification toggles. Serialized because every test
/// touches UserDefaults; the Play Sounds setting is covered by NotifierTests,
/// which owns that key.
@Suite(.serialized) struct SettingsTests {
    @Test func everyNotificationIsOnByDefault() {
        for kind in NotificationKind.allCases {
            let saved = UserDefaults.standard.object(forKey: kind.rawValue)
            defer { UserDefaults.standard.set(saved, forKey: kind.rawValue) }

            UserDefaults.standard.removeObject(forKey: kind.rawValue)
            #expect(Settings.notifies(kind), "\(kind) should default to on")
        }
    }

    @Test func aNotificationToggleIsRemembered() {
        let kind = NotificationKind.orderPlaced
        let saved = UserDefaults.standard.object(forKey: kind.rawValue)
        defer { UserDefaults.standard.set(saved, forKey: kind.rawValue) }

        Settings.setNotifies(kind, false)
        #expect(!Settings.notifies(kind))
        Settings.setNotifies(kind, true)
        #expect(Settings.notifies(kind))
    }

    @Test func eachNotificationKindHasItsOwnKeyAndTitle() {
        let keys = NotificationKind.allCases.map(\.rawValue)
        #expect(Set(keys).count == keys.count)
        let titles = NotificationKind.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
    }
}
