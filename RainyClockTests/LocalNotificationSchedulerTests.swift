import XCTest
import UserNotifications
@testable import RainyClock

/// The iOS 17–25 notification alarm, run against a fake pending-request queue and a clock
/// the test moves. The alarm is registered at 06:50 for 07:00; the tests then step into
/// the follow-up chain (07:00 + k × snooze) that ring starts.
final class LocalNotificationSchedulerTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) { self.value = value }

        var now: Date {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private final class FakeCenter: AlarmNotificationCenter, @unchecked Sendable {
        private let lock = NSLock()
        private let clock: Clock
        private var requests: [String: (request: UNNotificationRequest, addedAt: Date)] = [:]

        init(clock: Clock) { self.clock = clock }

        func pendingNotificationRequests() async -> [UNNotificationRequest] {
            lock.withLock { requests.values.map(\.request) }
        }

        func add(_ request: UNNotificationRequest) async throws {
            let now = clock.now
            lock.withLock { requests[request.identifier] = (request, now) }
        }

        func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
            lock.withLock { identifiers.forEach { requests[$0] = nil } }
        }

        func deliveredNotificationIdentifiers() async -> [String] { [] }

        func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}

        var identifiers: [String] { lock.withLock { Array(requests.keys) } }

        /// When each pending alarm request fires next, by the test clock.
        var fireDates: [Date] {
            let now = clock.now
            return lock.withLock {
                requests.values.compactMap { entry in
                    switch entry.request.trigger {
                    case let trigger as UNCalendarNotificationTrigger:
                        LocalNotificationScheduler.nextFireDate(of: trigger, after: now)
                    case let trigger as UNTimeIntervalNotificationTrigger:
                        entry.addedAt.addingTimeInterval(trigger.timeInterval)
                    default:
                        nil
                    }
                }
            }
        }

        func fires(within interval: TimeInterval) -> [Date] {
            let now = clock.now
            return fireDates.filter { $0 > now && $0 < now.addingTimeInterval(interval) }.sorted()
        }
    }

    private let calendar = Calendar.current
    private let ring = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 7, minute: 0))!
    private var clock: Clock!
    private var center: FakeCenter!
    private var scheduler: LocalNotificationScheduler!

    override func setUp() {
        super.setUp()
        let clock = Clock(ring.addingTimeInterval(-10 * 60))
        let suite = "LocalNotificationSchedulerTests.\(UUID().uuidString)"
        self.clock = clock
        center = FakeCenter(clock: clock)
        scheduler = LocalNotificationScheduler(center: center, defaults: UserDefaults(suiteName: suite)!, now: { clock.now })
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }

    /// `minutes` after this morning's 07:00.
    private func at(_ minutes: Double) -> Date { ring.addingTimeInterval(minutes * 60) }

    private func move(to minutes: Double) { clock.now = at(minutes) }

    private func minutes(_ values: StrideThrough<Double>) -> [Date] { values.map(at) }

    private func scheduleWeekly(ringingAt ringDate: Date, weekdays: Set<Int> = CommuteAlarmSettings.allWeekdays,
                                snoozeMinutes: Int = 5) async throws {
        try await scheduler.scheduleAlarm(at: ringDate, normalAlarmDate: ringDate, weekdays: weekdays,
            sound: .rainyClock, soundFileNameOverride: nil, snoozeMinutes: snoozeMinutes, title: "Alarm", body: "Wake up")
    }

    private func scheduleDated(_ ringDates: [Date]) async throws {
        let plan = CalendarAlarmPlan(occurrences: ringDates.map { .init(normalDate: $0, ringDate: $0) },
                                     coveredUntil: (ringDates.last ?? ring).addingTimeInterval(86_400))
        try await scheduler.scheduleCalendar(plan, sound: .rainyClock, soundFileNameOverride: nil,
                                             snoozeMinutes: 5, title: "Alarm", body: "Wake up")
    }

    /// All seven days with a 5-minute snooze: a ring and 7 follow-ups, the last at 07:35.
    /// Registered at 06:50; the clock stops at 07:07:30, with 07:10–07:35 still to come.
    private func ringThisMorning() async throws {
        try await scheduleWeekly(ringingAt: ring)
        move(to: 7.5)
    }

    private var restOfTheChain: [Date] { minutes(stride(from: 10, through: 35, by: 5)) }

    // MARK: A ring nobody stopped keeps following up

    func testReRegisteringKeepsAnUnstoppedChainRinging() async throws {
        try await ringThisMorning()
        XCTAssertEqual(center.fires(within: 3_600), restOfTheChain)

        try await scheduleWeekly(ringingAt: ring)
        XCTAssertEqual(center.fires(within: 3_600), restOfTheChain)
        XCTAssertLessThanOrEqual(center.identifiers.count, 56)
    }

    func testMovingTheAlarmKeepsTheChainThatRang() async throws {
        // Five weekdays leave room for 10 follow-ups: 07:00 runs to 07:50, 06:30 to 07:20.
        let today = calendar.component(.weekday, from: ring)
        let weekdays = Set((0..<5).map { (today - 1 + $0) % 7 + 1 })
        try await scheduleWeekly(ringingAt: ring, weekdays: weekdays)
        move(to: 7.5)

        // A background refresh decides tomorrow is rainy while this morning is still
        // following up: this morning's chain goes on, and 06:30's never started.
        try await scheduleWeekly(ringingAt: at(-30), weekdays: weekdays)
        XCTAssertEqual(center.fires(within: 3_600), minutes(stride(from: 10, through: 50, by: 5)))
        XCTAssertLessThanOrEqual(center.identifiers.count, 56)
    }

    func testMovingTheAlarmLaterRingsEachMomentOnce() async throws {
        try await ringThisMorning()
        // Set for 07:20 while 07:00 is still following up: from 07:20 on, both chains
        // land on the same minutes, and each rings once.
        try await scheduleWeekly(ringingAt: at(20))
        XCTAssertEqual(center.fires(within: 2 * 3_600), minutes(stride(from: 10, through: 55, by: 5)))
    }

    func testAnUnstoppedChainSurvivesASwitchToTheDatedPlanUntilStopped() async throws {
        try await ringThisMorning()
        // Tomorrow onwards, the whole 27-day horizon: 54 requests before the carried chain.
        try await scheduleDated((1...27).map { calendar.date(byAdding: .day, value: $0, to: ring)! })
        XCTAssertEqual(center.fires(within: 3_600), restOfTheChain)
        XCTAssertLessThanOrEqual(center.identifiers.count, 56)
        XCTAssertEqual(center.identifiers.filter { $0.contains("-date-") && $0.hasSuffix("-0") }.count, 27,
                       "every dated ring must stay armed")

        move(to: 11)
        await scheduler.acknowledgeAlarm(notificationDeliveredAt: at(10))
        XCTAssertEqual(center.fires(within: 3_600), [])

        // Once the chain would have ended, activation restores the dated plan in full.
        move(to: 40)
        await scheduler.rearmAlarmsIfNeeded()
        XCTAssertEqual(center.identifiers.count, 54)
    }

    func testRegisteringAfterTheRingTimeDoesNotInventFollowUps() async throws {
        // Turned on at 07:07:30: 07:00 never rang, so there is nothing to follow up on.
        move(to: 7.5)
        try await scheduleWeekly(ringingAt: ring)
        XCTAssertEqual(center.fires(within: 3_600), [])
        XCTAssertEqual(center.identifiers.count, 56, "next week keeps its follow-ups")
    }

    func testThePlanIsRestoredInFullOnceTheChainEnds() async throws {
        try await ringThisMorning()
        try await scheduleWeekly(ringingAt: ring)

        move(to: 40)
        await scheduler.rearmAlarmsIfNeeded()
        XCTAssertEqual(center.identifiers.count, 56)
        XCTAssertFalse(center.identifiers.contains { $0.contains("-carry-") })
        XCTAssertEqual(center.fires(within: 7 * 86_400).count, 56)
    }

    // MARK: A ring someone stopped stays stopped

    func testReRegisteringKeepsAStoppedMorningSilent() async throws {
        try await ringThisMorning()
        await scheduler.acknowledgeAlarm(notificationDeliveredAt: at(5))
        XCTAssertEqual(center.fires(within: 3_600), [])

        // A foreground refresh or settings change re-registers the same weekly alarm.
        try await scheduleWeekly(ringingAt: ring)
        XCTAssertEqual(center.fires(within: 3_600), [], "the stopped follow-ups came back")
        XCTAssertEqual(center.identifiers.count, 56, "the silenced follow-ups must stay armed for next week")
    }

    func testMovingTheAlarmEarlierKeepsAStoppedMorningSilent() async throws {
        try await ringThisMorning()
        await scheduler.acknowledgeAlarm(notificationDeliveredAt: at(5))

        try await scheduleWeekly(ringingAt: at(-10))
        XCTAssertEqual(center.fires(within: 3_600), [])
    }

    func testLengtheningSnoozeKeepsAStoppedMorningSilent() async throws {
        try await ringThisMorning()
        await scheduler.acknowledgeAlarm(notificationDeliveredAt: at(5))

        // At 10 minutes the chain runs 70 minutes, past the 5-minute chain's end.
        try await scheduleWeekly(ringingAt: ring, snoozeMinutes: 10)
        XCTAssertEqual(center.fires(within: 3 * 3_600), [])
        XCTAssertEqual(center.identifiers.count, 56)
    }

    func testAStoppedMorningDoesNotSilenceALaterRingSetToday() async throws {
        try await ringThisMorning()
        await scheduler.acknowledgeAlarm(notificationDeliveredAt: at(5))

        // After stopping this morning's alarm the user sets it for 07:40: a new ring,
        // with its own follow-ups.
        try await scheduleWeekly(ringingAt: at(40))
        XCTAssertEqual(center.fires(within: 2 * 3_600), minutes(stride(from: 40, through: 75, by: 5)))
    }

    func testStoppingABannerDeliveredBeforeAReRegistrationSilencesTheMorning() async throws {
        try await ringThisMorning()
        // A refresh re-registers the weekly alarm before the user reaches the 07:05 banner.
        try await scheduleWeekly(ringingAt: ring)
        move(to: 8)
        await scheduler.acknowledgeAlarm(notificationDeliveredAt: at(5))
        XCTAssertEqual(center.fires(within: 3_600), [])
    }

    func testSwitchingFromDatedToWeeklyKeepsAStoppedMorningSilent() async throws {
        try await scheduleDated([ring])
        move(to: 2)
        XCTAssertEqual(center.fires(within: 3_600), [at(5)])
        await scheduler.acknowledgeAlarm(notificationDeliveredAt: at(0))
        XCTAssertEqual(center.fires(within: 3_600), [])

        // Turning the calendar exceptions off goes back to the weekly alarm at the same time.
        try await scheduleWeekly(ringingAt: ring)
        XCTAssertEqual(center.fires(within: 3_600), [])
    }
}
