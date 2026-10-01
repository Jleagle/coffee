import Foundation

/// Posts a "last orders" notification at 14:20 each day the shop is open,
/// ten minutes before it closes at 14:30.
///
/// Driven by an in-app timer rather than a repeating calendar trigger in
/// Notification Center, because the delivery depends on the live open flag:
/// a reminder on a day the shop never opened would just be noise.
final class LastOrdersReminder {
    static let hour = 14
    static let minute = 20
    static let message = (title: "Last orders", body: "The coffee shop closes at 14:30. Get your order in now.")

    private let shopIsOpen: () -> Bool
    private let notify: () -> Void
    private var timer: Timer?

    init(shopIsOpen: @escaping () -> Bool, notify: @escaping () -> Void) {
        self.shopIsOpen = shopIsOpen
        self.notify = notify
    }

    deinit {
        timer?.invalidate()
    }

    /// Arms the timer for the next 14:20. Each firing re-arms it for the
    /// following day.
    func start() {
        schedule(after: Date())
    }

    private func schedule(after date: Date) {
        timer?.invalidate()
        let fireAt = Self.nextFireDate(after: date, calendar: .current)
        let timer = Timer(fire: fireAt, interval: 0, repeats: false) { [weak self] _ in
            self?.fire()
            self?.schedule(after: Date())
        }
        // Allow the system to coalesce the wake-up; a minute's drift is fine.
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Posts the reminder if the shop is open right now.
    func fire() {
        guard shopIsOpen() else { return }
        notify()
    }

    /// The next 14:20 strictly after `date`, in the calendar's time zone.
    static func nextFireDate(after date: Date, calendar: Calendar) -> Date {
        let components = DateComponents(hour: hour, minute: minute, second: 0)
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)!
    }
}
