import Foundation
import Testing
import UserNotifications
@testable import CoffeeMenuBar

/// The notification content each "alert" (order ready, placed, failed…) is
/// delivered with, now that they go through Notification Center instead of
/// modal dialogs.
@Suite struct NotifierTests {
    @Test func contentCarriesTitleBodyAndSound() {
        let content = Notifier.content(title: "Order ready", body: "Your Latte is ready.", sound: true)
        #expect(content.title == "Order ready")
        #expect(content.body == "Your Latte is ready.")
        #expect(content.sound == .default)
    }

    @Test func contentCanBeSilent() {
        let content = Notifier.content(title: "Shop open", body: "The coffee shop is now open.", sound: false)
        #expect(content.sound == nil)
    }

    @Test func requestsFollowThePlaySoundsSetting() {
        let saved = UserDefaults.standard.object(forKey: "playSounds")
        defer { UserDefaults.standard.set(saved, forKey: "playSounds") }

        Settings.playSounds = false
        #expect(Notifier.request(title: "Order ready", body: "Your Latte is ready.").content.sound == nil)

        Settings.playSounds = true
        #expect(Notifier.request(title: "Order ready", body: "Your Latte is ready.").content.sound == .default)
    }

    @Test func requestsGetUniqueIdentifiers() {
        // Each event must be its own notification; reusing an identifier
        // would silently replace the previous one in Notification Center.
        let a = Notifier.request(title: "Order placed", body: "Latte ordered.")
        let b = Notifier.request(title: "Order placed", body: "Latte ordered.")
        #expect(a.identifier != b.identifier)
        #expect(a.trigger == nil) // deliver immediately
    }
}
