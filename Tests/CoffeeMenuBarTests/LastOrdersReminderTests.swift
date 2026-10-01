import Foundation
import Testing
@testable import CoffeeMenuBar

/// The daily "last orders" notification ten minutes before the shop closes.
@Suite struct LastOrdersReminderTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    @Test func firesAt1420TodayWhenStillToCome() {
        let next = LastOrdersReminder.nextFireDate(after: date(2026, 10, 1, 9, 0), calendar: calendar)
        #expect(next == date(2026, 10, 1, 14, 20))
    }

    @Test func firesTomorrowOncePastToday() {
        let next = LastOrdersReminder.nextFireDate(after: date(2026, 10, 1, 14, 25), calendar: calendar)
        #expect(next == date(2026, 10, 2, 14, 20))
    }

    @Test func exactlyOnTimeIsAlreadyPast() {
        // Re-arming right after firing must not pick the same instant again.
        let next = LastOrdersReminder.nextFireDate(after: date(2026, 10, 1, 14, 20), calendar: calendar)
        #expect(next == date(2026, 10, 2, 14, 20))
    }

    @Test func onlyFiresWhileTheShopIsOpen() {
        var fired = 0
        let reminder = LastOrdersReminder(shopIsOpen: { false }, notify: { fired += 1 })
        reminder.fire()
        #expect(fired == 0)

        let open = LastOrdersReminder(shopIsOpen: { true }, notify: { fired += 1 })
        open.fire()
        #expect(fired == 1)
    }

    @Test func messageNamesTheClosingTime() {
        #expect(LastOrdersReminder.message.title == "Last orders")
        #expect(LastOrdersReminder.message.body == "The coffee shop closes at 14:30. Get your order in now.")
    }
}
