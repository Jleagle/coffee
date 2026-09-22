import Foundation
import Testing
@testable import CoffeeMenuBar

@Suite struct SettingsTests {
    @Test func playSoundsIsOffByDefault() {
        let saved = UserDefaults.standard.object(forKey: "playSounds")
        defer { UserDefaults.standard.set(saved, forKey: "playSounds") }

        UserDefaults.standard.removeObject(forKey: "playSounds")
        #expect(Settings.playSounds == false)
    }
}
