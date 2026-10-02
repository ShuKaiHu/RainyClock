import XCTest
@testable import RainyClock

/// The widget snapshot: card rules, the builder's timeline, storage, the plan the
/// widget renders from, and the publisher's dedupe. Taipei fixtures, as in
/// TomorrowAlarmStatusTests; 2026-09-14 is a Monday.
@MainActor
final class TomorrowWidgetSnapshotTests: XCTestCase {
    private typealias Builder = TomorrowWidgetSnapshotBuilder
    private typealias Snapshot = TomorrowWidgetSnapshot

    /// A fresh suite per test instance; immutable, so setUp/tearDown (nonisolated) may read it.
    private nonisolated let suiteName = "TomorrowWidgetSnapshotTests-\(UUID().uuidString)"
    private var storage: UserDefaults { UserDefaults(suiteName: suiteName)! }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Fixtures

    private var calendar: Calendar { DisasterNoticeParser.taipeiCalendar }

    private func date(_ day: Int, _ hour: Int = 18, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute, second: second))!
    }

    private func settings(home: String = "Home", work: String = "Work") -> CommuteAlarmSettings {
        var value = CommuteAlarmSettings()
        value.homeAddress = home
        value.workAddress = work
        value.alarmTime = date(15, 7, 30)
        value.selectedWeekdays = Set(1...7)
        value.rainLeadTimeMinutes = 30
        value.rainProbabilityThreshold = 0.5
        return value
    }

    private func record(_ settings: CommuteAlarmSettings, requestedAt: Date, checkedAt: Date, probability: Double = 0.8,
                        names: [String] = ["Home", "Work"]) -> TomorrowWeatherRecord {
        let request = TomorrowWeatherRequest(settings: settings, now: requestedAt, calendar: calendar)
        let segments = names.enumerated().map { index, name in
            RouteWeatherSegment(name: name, condition: index == 0 ? .rain : .cloudy,
                                precipitationProbability: index == 0 ? probability : probability / 2)
        }
        return .init(request: request, snapshot: .init(checkedAt: checkedAt, forecastAt: request.forecastDate, segments: segments))
    }

    /// A weekly registration as `evaluateRouteAndScheduleAlarm` records it: decided for `normal`.
    private func summary(normal: Date, ring: Date) -> ScheduledAlarmSummary {
        .init(normalAlarmDate: normal, scheduledAlarmDate: ring, weatherRefreshDate: normal.addingTimeInterval(-1_800),
              exceedsRainThreshold: ring < normal, leadTimeMinutes: ring < normal ? 30 : 0,
              rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: ring < normal ? 0.8 : 0.1,
              wettestSegmentName: "路程 ½", decisionNormalAlarmDate: normal)
    }

    /// Mirrors `AlarmViewModel.calendarTomorrowStatus(now:)`, the widget's tomorrow: the
    /// summary is rolled at `t` (ring and normal time as one pair), and the failure flag
    /// applies only while the failed request is still that day's.
    /// `dayOffset: 0` mirrors `AlarmViewModel.todayStatus(now:)` the same way, and `nil` the
    /// card's `tomorrowStatus(now:)` (the coming morning).
    private func statusProvider(_ settings: CommuteAlarmSettings, weather: TomorrowWeatherRecord?,
                                summary: ScheduledAlarmSummary?, failedRequest: TomorrowWeatherRequest? = nil,
                                dayOffset: Int? = 1, calendar: Calendar? = nil)
        -> (Date) -> TomorrowAlarmStatus {
        let calendar = calendar ?? self.calendar
        return { t in
            TomorrowAlarmStatus.resolve(
                settings: settings, holidays: .init(), weatherRecord: weather,
                weatherRefreshFailed: failedRequest == TomorrowWeatherRequest(settings: settings, now: t, calendar: calendar,
                                                                              dayOffset: dayOffset),
                summary: summary?.rollingForwardAsPair(selectedWeekdays: settings.selectedWeekdays, now: t, calendar: calendar),
                registeredFingerprint: summary == nil ? nil : settings.scheduleFingerprint(calendar: calendar),
                disasterFeed: nil, disasterSourceFailed: false, now: t, calendar: calendar, dayOffset: dayOffset)
        }
    }

    private func context(_ settings: CommuteAlarmSettings, summary: ScheduledAlarmSummary?,
                         flags: Builder.CardFlags = .init(), clock: ClockTimeFormat = .twelveHour) -> Builder.Context {
        Builder.Context(
            calendar: calendar, clockFormat: clock, mode: .car,
            addressesMissing: settings.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || settings.workAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            flags: flags, rainLeadTimeMinutes: settings.rainLeadTimeMinutes,
            ringAnchors: summary.map { [$0.scheduledAlarmDate, $0.normalAlarmDate] } ?? [])
    }

    private func status(reason: TomorrowAlarmStatus.Reason, expected: Date? = nil, holidayName: String? = nil,
                        weather: RouteWeatherSnapshot? = nil, stale: Bool = false, failed: Bool = false,
                        registered: Date? = nil, verified: Bool = false, lead: Int = 0) -> TomorrowAlarmStatus {
        TomorrowAlarmStatus(day: date(16, 0), normalAlarmDate: date(16, 7, 30), expectedRingDate: expected,
                            reason: reason, holidayName: holidayName, leadTimeMinutes: lead, weather: weather,
                            weatherIsStale: stale, weatherRefreshFailed: failed, registeredRingDate: registered,
                            isScheduleVerified: verified, disasterNoticeIDs: [])
    }

    private func weatherSnapshot(_ probabilities: [Double], checkedAt: Date? = nil) -> RouteWeatherSnapshot {
        RouteWeatherSnapshot(checkedAt: checkedAt ?? date(15, 21), forecastAt: date(16, 7), segments: probabilities.enumerated().map {
            RouteWeatherSegment(name: "Segment \($0.offset)", condition: $0.offset == 0 ? .clear : .rain, precipitationProbability: $0.element)
        })
    }

    /// Mon 21:00, weather checked 21:00 (rain 80%), weekly summary Tue 07:00 / 07:30.
    private func mondayEvening(failed: Bool = false, checkedAt: Date? = nil) -> (Snapshot, Builder.Context, (Date) -> TomorrowAlarmStatus) {
        let now = date(14, 21)
        let value = settings()
        let weather = record(value, requestedAt: now, checkedAt: checkedAt ?? now)
        let registered = summary(normal: date(15, 7, 30), ring: date(15, 7))
        let provider = statusProvider(value, weather: weather, summary: registered,
                                      failedRequest: failed ? weather.request : nil)
        let context = context(value, summary: registered)
        return (Builder.snapshot(now: now, context: context, status: provider), context, provider)
    }

    private func entry(_ snapshot: Snapshot, at moment: Date) -> Snapshot.Entry? {
        snapshot.entries.first { $0.validFrom == moment }
    }

    // MARK: Card rules

    func testReasonLineMirrorsCardForEveryReason() {
        let fresh = weatherSnapshot([0.8])
        XCTAssertNil(Builder.reasonLine(for: status(reason: .normal, expected: date(16, 7, 30))))
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .rain, expected: date(16, 7), weather: fresh, lead: 30)),
                       .rainForecast(percent: 80, minutes: 30))
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .holiday, holidayName: "國慶日"), language: "zh-Hant"),
                       .holidayNamed("國慶日"))
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .holiday, holidayName: "國慶日"), language: "en"),
                       .holidayNamed("National Day"))
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .holiday, holidayName: "原住民族日"), language: "en"), .holiday,
                       "An English UI never shows a Chinese name it cannot translate")
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .holiday, holidayName: " ")), .holidayNamed(" "),
                       "The card does not trim the holiday name")
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .holiday, holidayName: "")), .holiday)
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .holiday)), .holiday)
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .manual)), .manualSkip)
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .manual, expected: date(16, 7, 30))), .manualRing)
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .weekend)), .weekend)
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .unselectedWeekday)), .unselectedWeekday)
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .disaster)), .closure)
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .routeIncomplete)), .routeNeeded)
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .alarmOff)), .alarmOff)
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .skippedOnce)), .skippedOnce)

        // Every reason maps, and to its own snapshot reason.
        let context = context(settings(), summary: nil)
        let pairs: [(TomorrowAlarmStatus.Reason, Snapshot.Reason)] = [
            (.normal, .normal), (.rain, .rain), (.holiday, .holiday), (.manual, .manual), (.weekend, .weekend),
            (.unselectedWeekday, .unselectedWeekday), (.disaster, .disaster), (.routeIncomplete, .routeIncomplete),
            (.alarmOff, .alarmOff), (.skippedOnce, .skippedOnce)]
        XCTAssertEqual(pairs.count, Snapshot.Reason.allCases.count)
        for (source, expected) in pairs {
            XCTAssertEqual(Builder.entry(for: status(reason: source), context: context, validFrom: date(15, 21)).reason, expected)
        }

        // The snapshot stores DGPA's own name whatever the app's language: the widget names
        // it where it renders, so a language switch cannot strand the other language's name.
        for name in ["國慶日", "原住民族日", "補假"] {
            let holiday = status(reason: .holiday, holidayName: name)
            XCTAssertEqual(Builder.snapshotReasonLine(for: holiday), .holidayNamed(name))
            XCTAssertEqual(Builder.entry(for: holiday, context: context, validFrom: date(15, 21)).reasonLine, .holidayNamed(name))
        }
        // Everything else is the card's line as it is.
        for reason in [TomorrowAlarmStatus.Reason.normal, .rain, .manual, .weekend, .unselectedWeekday, .disaster, .routeIncomplete,
                       .alarmOff, .skippedOnce] {
            let value = status(reason: reason, weather: fresh, lead: 30)
            XCTAssertEqual(Builder.snapshotReasonLine(for: value), Builder.reasonLine(for: value, language: "en"), "\(reason)")
        }
    }

    func testHolidayNamesFollowTheUILanguage() {
        typealias Names = HolidayDisplayName
        // Chinese keeps every name as DGPA wrote it, and so does any zh localization.
        for language in ["zh-Hant", "zh-Hant-TW", "zh"] {
            XCTAssertEqual(Names.name(for: "國慶日", language: language), "國慶日")
            XCTAssertEqual(Names.name(for: "原住民族日", language: language), "原住民族日")
            XCTAssertEqual(Names.name(for: "Independence Day", language: language), "Independence Day")
        }
        // English maps every name in the bundled CSVs but 補假, and never leaves an ideograph behind.
        let bundled = Set(HolidayCalendar.load(storage: storage).days.values.map(\.name)).filter { !$0.isEmpty }
        XCTAssertTrue(bundled.isSuperset(of: ["開國紀念日", "小年夜", "春節", "補假", "孔子誕辰紀念日/教師節", "臺灣光復暨金門古寧頭大捷紀念日"]),
                      "The fixture must actually read the bundled CSVs")
        for name in bundled {
            let english = Names.name(for: name, language: "en")
            if name == "補假" {
                XCTAssertNil(english, "A day off in lieu has no name of its own: the unnamed line")
            } else {
                XCTAssertNotNil(english, "\(name) has no English name")
            }
            XCTAssertFalse(english?.unicodeScalars.contains(where: \.properties.isIdeographic) ?? false, name)
        }
        // No two names in a row may both claim the Eve: 小年夜 is the day before it.
        let eves = bundled.filter { Names.name(for: $0, language: "en") == "Lunar New Year's Eve" }
        XCTAssertEqual(eves, ["農曆除夕"])
        let expected = [
            "開國紀念日": "New Year's Day", "農曆除夕": "Lunar New Year's Eve", "除夕": "Lunar New Year's Eve",
            "小年夜": "Lunar New Year break",
            "春節": "Lunar New Year", "調整放假": "Bridge day",
            "和平紀念日": "Peace Memorial Day", "兒童節": "Children's Day", "民族掃墓節": "Tomb-Sweeping Day",
            "清明節": "Tomb-Sweeping Day", "勞動節": "Labor Day", "端午節": "Dragon Boat Festival",
            "中秋節": "Mid-Autumn Festival", "孔子誕辰紀念日/教師節": "Teachers' Day", "國慶日": "National Day",
            "臺灣光復暨金門古寧頭大捷紀念日": "Retrocession Day", "行憲紀念日": "Constitution Day",
        ]
        for (name, english) in expected {
            XCTAssertEqual(Names.name(for: name, language: "en"), english, name)
        }
        // Compound names: the holiday named first; anything with 光復 is Retrocession Day.
        XCTAssertEqual(Names.name(for: "兒童節及民族掃墓節", language: "en"), "Children's Day")
        XCTAssertEqual(Names.name(for: "中秋節補假", language: "en"), "Mid-Autumn Festival")
        XCTAssertEqual(Names.name(for: "臺灣光復節", language: "en"), "Retrocession Day")
        // Unknown Chinese: nil, the unnamed line. Names without ideographs pass through.
        XCTAssertNil(Names.name(for: "原住民族日", language: "en"))
        XCTAssertNil(Names.name(for: "原住民族日", language: "ja"))
        XCTAssertEqual(Names.name(for: "Independence Day (observed)", language: "en"), "Independence Day (observed)")
        XCTAssertEqual(Names.name(for: " ", language: "en"), " ")
    }

    func testRainLineUsesForecastPercentOnlyWhenFresh() {
        let weather = weatherSnapshot([0.8, 0.3])
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .rain, expected: date(16, 7), weather: weather, lead: 30)),
                       .rainForecast(percent: 80, minutes: 30))
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .rain, expected: date(16, 7), weather: weather, stale: true, lead: 30)),
                       .rainEarlier(minutes: 30))
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .rain, expected: date(16, 7), lead: 30)), .rainEarlier(minutes: 30))
        XCTAssertEqual(Builder.reasonLine(for: status(reason: .rain, expected: date(16, 7), weather: weatherSnapshot([0.2, 0.555]), lead: 30)),
                       .rainForecast(percent: 56, minutes: 30))
    }

    func testWeatherNoticePriority() {
        let weather = weatherSnapshot([0.2])
        XCTAssertEqual(Builder.weatherNotice(for: status(reason: .normal, weather: weather, stale: true, failed: true), addressesMissing: true), .failed)
        XCTAssertEqual(Builder.weatherNotice(for: status(reason: .normal, failed: true), addressesMissing: true), .failed)
        XCTAssertEqual(Builder.weatherNotice(for: status(reason: .normal, weather: weather, stale: true), addressesMissing: true), .stale)
        XCTAssertEqual(Builder.weatherNotice(for: status(reason: .normal), addressesMissing: true), .routeNeeded)
        XCTAssertEqual(Builder.weatherNotice(for: status(reason: .normal), addressesMissing: false), .noForecast)
        XCTAssertNil(Builder.weatherNotice(for: status(reason: .normal, weather: weather), addressesMissing: false))
    }

    func testScheduleIssueFirstMatchWinsAndIgnoresVerification() {
        let matching = status(reason: .normal, expected: date(16, 7, 30), registered: date(16, 7, 30))
        var flags = Builder.CardFlags(hasSchedulingError: true, requiresAlarmKitReschedule: true, closureScheduleUncertain: true,
                                      closureRefreshFailed: true, isScheduleStale: true)
        XCTAssertEqual(Builder.scheduleIssue(for: matching, flags: flags), .schedulingFailed)
        flags.hasSchedulingError = false
        XCTAssertEqual(Builder.scheduleIssue(for: matching, flags: flags), .alarmKitReschedule)
        flags.requiresAlarmKitReschedule = false
        XCTAssertEqual(Builder.scheduleIssue(for: matching, flags: flags), .closureUncertain)
        flags.closureScheduleUncertain = false
        XCTAssertEqual(Builder.scheduleIssue(for: matching, flags: flags), .closureUpdateFailed)
        flags.closureRefreshFailed = false
        XCTAssertEqual(Builder.scheduleIssue(for: matching, flags: flags), .updateNeeded)
        flags.isScheduling = true
        XCTAssertNil(Builder.scheduleIssue(for: matching, flags: flags), "In-flight scheduling suppresses the stale notice")

        let mismatch = status(reason: .normal, expected: date(16, 7, 30), registered: date(16, 7))
        XCTAssertEqual(Builder.scheduleIssue(for: mismatch, flags: .init()), .updateNeeded)
        XCTAssertNil(Builder.scheduleIssue(for: mismatch, flags: .init(isScheduling: true)))
        XCTAssertEqual(Builder.scheduleIssue(for: status(reason: .weekend, registered: date(16, 7, 30)), flags: .init()), .updateNeeded)

        // Unverified but equal: the card shows nothing, so neither does the widget.
        let unverified = status(reason: .normal, expected: date(16, 7, 30), registered: date(16, 7, 30), verified: false)
        XCTAssertNil(Builder.scheduleIssue(for: unverified, flags: .init()))
        XCTAssertNil(Builder.scheduleIssue(for: status(reason: .normal, expected: date(16, 7, 30)), flags: .init()))
    }

    func testForecastEndpointsAreFirstAndLastSegment() {
        XCTAssertNil(Builder.forecast(from: nil))
        XCTAssertNil(Builder.forecast(from: weatherSnapshot([])))
        let single = Builder.forecast(from: weatherSnapshot([0.42]))
        XCTAssertEqual(single?.home, .init(condition: .clear, percent: 42))
        XCTAssertNil(single?.work, "A partial response must not duplicate Home's forecast as Work's weather")
        XCTAssertEqual(single?.maximumPercent, 42)
        let three = Builder.forecast(from: weatherSnapshot([0.1, 0.9, 0.35]))
        XCTAssertEqual(three?.home, .init(condition: .clear, percent: 10))
        XCTAssertEqual(three?.work, .init(condition: .rain, percent: 35))
        XCTAssertEqual(three?.maximumPercent, 90)
        XCTAssertEqual(three?.checkedAt, date(15, 21))
    }

    func testSnapshotContainsNoAddressesOrSegmentNames() throws {
        let now = date(14, 21)
        let value = settings(home: "台北市信義區市府路1號", work: "新北市板橋區")
        let weather = record(value, requestedAt: now, checkedAt: now, names: ["台北市信義區市府路1號", "路程 ½", "新北市板橋區"])
        let registered = summary(normal: date(15, 7, 30), ring: date(15, 7))
        let snapshot = Builder.snapshot(now: now, context: context(value, summary: registered),
                                        status: statusProvider(value, weather: weather, summary: registered))
        XCTAssertNotNil(snapshot.entries.first?.forecast, "The fixture must actually carry weather")
        let data = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in ["台北市信義區市府路1號", "新北市板橋區", "路程 ½", "Home", "Work"] {
            XCTAssertFalse(json.contains(forbidden), "\(forbidden) leaked into the widget snapshot")
        }
        var keys = Set<String>()
        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary { keys.insert(key); walk(child) }
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(try JSONSerialization.jsonObject(with: data))
        XCTAssertFalse(keys.isEmpty)
        for forbidden in ["name", "id", "homeAddress", "workAddress", "segments", "wettestSegmentName"] {
            XCTAssertFalse(keys.contains(forbidden), "Key \(forbidden) must never reach the widget")
        }
    }

    func testCodableRoundTripValidityAndStoreKey() throws {
        XCTAssertNotEqual(Snapshot.storageKey, "dayOffSharedState.v1", "Must not collide with DayOffSharedState.storageKey")
        XCTAssertEqual(Snapshot.appGroupIdentifier, "group.com.shukaihu.RainyClock")
        let store = TomorrowWidgetStore(suiteName: suiteName)
        XCTAssertNil(store.load())

        let (snapshot, _, _) = mondayEvening()
        XCTAssertTrue(snapshot.isValid)
        XCTAssertTrue(store.save(snapshot))
        XCTAssertEqual(store.load(), snapshot)
        store.clear()
        XCTAssertNil(store.load())

        func loads(_ data: Data) -> Bool {
            storage.set(data, forKey: Snapshot.storageKey)
            return store.load() != nil
        }
        XCTAssertFalse(loads(Data("not json".utf8)))
        XCTAssertFalse(loads(Data(repeating: 0x20, count: Snapshot.maximumBytes + 1)))
        var huge = snapshot
        huge.entries[0].reasonLine = .holidayNamed(String(repeating: "假", count: Snapshot.maximumBytes))
        XCTAssertFalse(store.save(huge), "An oversized snapshot is refused")
        XCTAssertFalse(loads(try JSONEncoder().encode(huge)))
        var wrongVersion = snapshot
        wrongVersion.version = Snapshot.currentVersion + 1
        XCTAssertFalse(loads(try JSONEncoder().encode(wrongVersion)))
        var unsorted = snapshot
        XCTAssertGreaterThan(unsorted.entries.count, 2)
        unsorted.entries.swapAt(1, 2)
        XCTAssertFalse(loads(try JSONEncoder().encode(unsorted)))
        var empty = snapshot
        empty.entries = []
        XCTAssertFalse(loads(try JSONEncoder().encode(empty)))
        var expiresEarly = snapshot
        expiresEarly.expiresAt = snapshot.entries.last!.validFrom
        XCTAssertFalse(loads(try JSONEncoder().encode(expiresEarly)))
        var unpublished = snapshot
        unpublished.publishedAt = snapshot.publishedAt.addingTimeInterval(-1)
        XCTAssertFalse(loads(try JSONEncoder().encode(unpublished)))
        XCTAssertTrue(loads(try JSONEncoder().encode(snapshot)))

        // A today entry carrying its morning's forecast (2026-10-02) is the same shape: still
        // version 4, and it round-trips well under the size limit.
        XCTAssertEqual(Snapshot.currentVersion, 4)
        let (withToday, _, _) = mondayEveningWithToday()
        XCTAssertNotNil(withToday.entries.first { $0.isToday && $0.forecast != nil })
        XCTAssertTrue(store.save(withToday))
        XCTAssertEqual(store.load(), withToday)
        XCTAssertLessThan(try JSONEncoder().encode(withToday).count, Snapshot.maximumBytes / 4)
        store.clear()
    }

    // MARK: Builder timeline

    func testBoundariesCoverStalenessMidnightsAndRings() {
        let (snapshot, context, provider) = mondayEvening()
        let now = date(14, 21)
        let expires = Builder.expiresAt(now: now, calendar: calendar)
        XCTAssertEqual(expires, date(16, 0))
        XCTAssertEqual(snapshot.expiresAt, date(16, 0))
        let boundaries = Builder.boundaries(now: now, first: provider(now), atFirstMidnight: provider(date(15, 0)),
                                            context: context, expiresAt: expires)
        XCTAssertEqual(boundaries, boundaries.sorted())
        XCTAssertEqual(Set(boundaries).count, boundaries.count)
        XCTAssertTrue(boundaries.allSatisfy { $0 > now && $0 < expires })
        for moment in [date(14, 21, 30, 1), date(15, 0), date(15, 7, 0, 1), date(15, 7, 30, 1)] {
            XCTAssertTrue(boundaries.contains(moment), "missing boundary \(moment)")
        }
        // Once Tuesday's 07:00 ring has fired, AlarmKit's weekly repeat next rings Wednesday
        // 07:00, so 07:00:01 is new content; 07:30:01 says the same and is merged into it.
        XCTAssertEqual(snapshot.entries.map(\.validFrom), [now, date(14, 21, 30, 1), date(15, 0), date(15, 7, 0, 1)])
        XCTAssertTrue(snapshot.isValid)
        let first = snapshot.entries[0]
        XCTAssertEqual(first.expectedRingDate, date(15, 7))
        XCTAssertEqual(first.reasonLine, .rainForecast(percent: 80, minutes: 30))
        XCTAssertNil(first.weatherNotice)
        XCTAssertNil(first.scheduleIssue)
    }

    func testStaleEntryKeepsRegisteredRainTime() throws {
        let (snapshot, _, _) = mondayEvening()
        let stale = try XCTUnwrap(entry(snapshot, at: date(14, 21, 30, 1)))
        XCTAssertEqual(stale.expectedRingDate, date(15, 7))
        XCTAssertEqual(stale.reason, .rain)
        XCTAssertEqual(stale.reasonLine, .rainEarlier(minutes: 30))
        XCTAssertNil(stale.weatherNotice, "Half an hour old: the card warns, the widget does not yet (D-B)")
        XCTAssertNotNil(stale.forecast, "The card keeps showing the stale forecast")
        XCTAssertNil(stale.scheduleIssue)
    }

    /// D-B: the widget warns only after 3 hours; the card keeps its 30 minutes, and the
    /// decision (which stops reading the forecast at 30 minutes) is the card's either way.
    func testWidgetWarnsAboutStaleWeatherOnlyAfterThreeHours() throws {
        XCTAssertEqual(Builder.widgetWeatherLifetime, 3 * 3_600)
        XCTAssertEqual(TomorrowAlarmStatus.weatherLifetime, 30 * 60, "The card's rule is unchanged")
        let now = date(14, 19)
        let value = settings()
        let weather = record(value, requestedAt: now, checkedAt: now)
        let registered = summary(normal: date(15, 7, 30), ring: date(15, 7))
        let provider = statusProvider(value, weather: weather, summary: registered)
        let context = context(value, summary: registered)
        let snapshot = Builder.snapshot(now: now, context: context, status: provider)

        let fresh = try XCTUnwrap(entry(snapshot, at: now))
        XCTAssertNil(fresh.weatherNotice)
        XCTAssertEqual(fresh.reasonLine, .rainForecast(percent: 80, minutes: 30))

        // 19:30:01: the card already says 天氣資料需要更新; the widget stays quiet.
        let halfHour = date(14, 19, 30, 1)
        XCTAssertEqual(Builder.weatherNotice(for: provider(halfHour), addressesMissing: false), .stale)
        let quiet = try XCTUnwrap(entry(snapshot, at: halfHour))
        XCTAssertNil(quiet.weatherNotice)
        XCTAssertEqual(quiet.reasonLine, .rainEarlier(minutes: 30), "The decision no longer reads the stale forecast")
        XCTAssertNotNil(quiet.forecast)

        // Exactly three hours is not yet stale (strict >); one second later it is.
        XCTAssertNil(Builder.widgetWeatherNotice(for: provider(date(14, 22)), addressesMissing: false, at: date(14, 22)))
        let stale = try XCTUnwrap(entry(snapshot, at: date(14, 22, 0, 1)), "A precomputed entry at the widget's threshold")
        XCTAssertEqual(stale.weatherNotice, .stale)
        XCTAssertEqual(stale.expectedRingDate, date(15, 7))
        XCTAssertEqual(stale.reasonLine, .rainEarlier(minutes: 30))

        // A failed refresh is not about age: it shows at once, as on the card.
        let failing = statusProvider(value, weather: weather, summary: registered, failedRequest: weather.request)
        XCTAssertEqual(Builder.widgetWeatherNotice(for: failing(now), addressesMissing: false, at: now), .failed)
        // No forecast at all, or no route: the card's notices.
        let none = statusProvider(value, weather: nil, summary: registered)
        XCTAssertEqual(Builder.widgetWeatherNotice(for: none(now), addressesMissing: false, at: now), .noForecast)
        XCTAssertEqual(Builder.widgetWeatherNotice(for: none(now), addressesMissing: true, at: now), .routeNeeded)
    }

    func testMidnightEntryDescribesTheDayAfter() throws {
        let (snapshot, _, _) = mondayEvening(failed: true)
        XCTAssertEqual(snapshot.entries[0].weatherNotice, .failed)
        let midnight = try XCTUnwrap(entry(snapshot, at: date(15, 0)))
        XCTAssertEqual(midnight.day, date(16, 0))
        XCTAssertEqual(midnight.normalAlarmDate, date(16, 7, 30))
        XCTAssertEqual(midnight.expectedRingDate, date(16, 7, 30))
        XCTAssertNil(midnight.forecast)
        XCTAssertEqual(midnight.weatherNotice, .noForecast, "The failure belonged to Tuesday's request")
    }

    func testAfterRingUsesRolledSummary() throws {
        let (snapshot, _, _) = mondayEvening()
        // From the moment the early ring fires, not only after its normal time: the ring and
        // the normal time it served roll together.
        XCTAssertNil(entry(snapshot, at: date(15, 7, 30, 1)), "The normal time passing changes nothing")
        let afterRing = try XCTUnwrap(entry(snapshot, at: date(15, 7, 0, 1)))
        XCTAssertEqual(afterRing.day, date(16, 0))
        XCTAssertEqual(afterRing.expectedRingDate, date(16, 7))
        XCTAssertEqual(afterRing.reason, .rain)
        // D-D: Tuesday's forecast decided that 07:00, not Wednesday's.
        XCTAssertEqual(afterRing.reasonLine, .awaitingForecast)
        XCTAssertFalse(afterRing.appliesRainLead)
        XCTAssertNil(afterRing.scheduleIssue)
    }

    func testNoSilentMismatchWithWeeklyRegistration() {
        let start = date(14, 21)
        // 07:30, and 00:10 whose 30-minute lead crosses midnight (the early ring is Monday 23:40).
        for (normal, early) in [(date(15, 7, 30), date(15, 7)), (date(15, 0, 10), date(14, 23, 40))] {
        var value = settings()
        value.alarmTime = normal
        for rainDecided in [true, false] {
            for weatherFresh in [true, false] {
                let registered = summary(normal: normal, ring: rainDecided ? early : normal)
                let weather = record(value, requestedAt: start, checkedAt: weatherFresh ? start : start.addingTimeInterval(-3_600))
                let provider = statusProvider(value, weather: weather, summary: registered)
                let context = context(value, summary: registered)
                let publishes = [start, start.addingTimeInterval(86_400)].map {
                    Builder.snapshot(now: $0, context: context, status: provider)
                }
                var checked = 0
                for step in 0..<(48 * 4) {
                    let now = start.addingTimeInterval(Double(step) * 900)
                    guard let snapshot = publishes.last(where: { $0.publishedAt <= now }) else { continue }
                    let plan = TomorrowWidgetTimeline.plan(snapshot: snapshot, now: now, currentTimeZoneID: calendar.timeZone.identifier)
                    guard case .status(let shown) = plan.items[0].state else {
                        XCTFail("No status at \(now)"); continue
                    }
                    let rolled = registered.rollingForwardAsPair(selectedWeekdays: value.selectedWeekdays, now: now, calendar: calendar)
                    let truth = rolled.normalAlarmDate == shown.normalAlarmDate ? rolled.scheduledAlarmDate : nil
                    let label = "\(normal) rain \(rainDecided) fresh \(weatherFresh) at \(now)"
                    XCTAssertTrue(truth == nil || shown.expectedRingDate == truth || shown.scheduleIssue == .updateNeeded,
                                  "\(label): shows \(String(describing: shown.expectedRingDate)), AlarmKit rings \(String(describing: truth))")
                    // The registration took this very forecast's decision, so nothing may ever read
                    // as "update needed" — not even between an early ring and its normal time.
                    if rainDecided {
                        XCTAssertNil(shown.scheduleIssue, "\(label): shows \(String(describing: shown.expectedRingDate))")
                    }
                    checked += 1
                }
                XCTAssertEqual(checked, 48 * 4)
            }
        }
        }
    }

    func testPairRollKeepsEachRingWithTheNormalTimeItServes() {
        // Monday-only 00:20 whose rain lead moved the ring to Sunday 23:50 (2026-09-13).
        let crossing = summary(normal: date(14, 0, 20), ring: date(13, 23, 50))
        // Between the ring and its normal time: the next ring, and the Monday it serves.
        let rolled = crossing.rollingForwardAsPair(selectedWeekdays: [2], now: date(14, 0, 5), calendar: calendar)
        XCTAssertEqual(rolled.scheduledAlarmDate, date(20, 23, 50))
        XCTAssertEqual(rolled.normalAlarmDate, date(21, 0, 20))
        // A summary a relaunch already rolled one date at a time is re-paired the same way.
        let halfRolled = crossing.rollingForward(selectedWeekdays: [2], now: date(14, 0, 5), calendar: calendar)
        XCTAssertEqual(halfRolled.normalAlarmDate, date(14, 0, 20), "rollingForward leaves the normal time")
        XCTAssertEqual(halfRolled.rollingForwardAsPair(selectedWeekdays: [2], now: date(14, 0, 5), calendar: calendar), rolled)
        // Before the ring, and once everything is past, it agrees with rollingForward.
        for now in [date(13, 20), date(16, 12)] {
            XCTAssertEqual(crossing.rollingForwardAsPair(selectedWeekdays: [2], now: now, calendar: calendar),
                           crossing.rollingForward(selectedWeekdays: [2], now: now, calendar: calendar), "\(now)")
        }
        // Same day: after Tuesday's 07:00 ring the pair is Wednesday's, not (Tue 07:30, Wed 07:00).
        let sameDay = summary(normal: date(15, 7, 30), ring: date(15, 7))
        let afterRing = sameDay.rollingForwardAsPair(selectedWeekdays: Set(1...7), now: date(15, 7, 10), calendar: calendar)
        XCTAssertEqual(afterRing.scheduledAlarmDate, date(16, 7))
        XCTAssertEqual(afterRing.normalAlarmDate, date(16, 7, 30))
    }

    func testIdenticalNeighboursAreCoalescedAndCapTruncatesExpiry() {
        let now = date(14, 21)
        let fixed = status(reason: .normal, expected: date(16, 7, 30))
        var context = context(settings(), summary: nil)

        // Nothing changes: one entry, expiring at the second midnight.
        let quiet = Builder.snapshot(now: now, context: context) { _ in fixed }
        XCTAssertEqual(quiet.entries.count, 1)
        XCTAssertEqual(quiet.expiresAt, date(16, 0))

        // Something changes at every boundary: the cap stops the snapshot where the 25th would start.
        context.ringAnchors = (1...40).map { now.addingTimeInterval(Double($0) * 600) }
        let changing: (Date) -> TomorrowAlarmStatus = { t in
            var value = fixed
            value.leadTimeMinutes = Int(t.timeIntervalSince(now))
            return value
        }
        let boundaries = Builder.boundaries(now: now, first: changing(now), atFirstMidnight: changing(date(15, 0)),
                                            context: context, expiresAt: Builder.expiresAt(now: now, calendar: calendar))
        XCTAssertGreaterThan(boundaries.count, Builder.maximumEntries)
        let capped = Builder.snapshot(now: now, context: context, status: changing)
        XCTAssertEqual(capped.entries.count, Builder.maximumEntries)
        XCTAssertEqual(capped.entries.last?.validFrom, boundaries[Builder.maximumEntries - 2])
        XCTAssertEqual(capped.expiresAt, boundaries[Builder.maximumEntries - 1], "Expiry is the first dropped validFrom")
        XCTAssertTrue(capped.isValid)
    }

    func testExpiresAtIsSecondLocalMidnightAcrossDST() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let publish = newYork.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12))!
        let expiry = Builder.expiresAt(now: publish, calendar: newYork)
        XCTAssertEqual(expiry, newYork.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 0)))
        XCTAssertEqual(newYork.dateComponents([.hour, .minute], from: expiry), DateComponents(hour: 0, minute: 0))
        XCTAssertEqual(expiry.timeIntervalSince(publish), 37 * 3_600, "Nov 1 is 25 hours long in New York")
    }

    // MARK: Today before the ring (D-C)

    /// Monday 21:00 as in `mondayEvening`, with the today provider the app passes. `failed`:
    /// the refresh of Tuesday's forecast failed (the request that, after midnight, is today's).
    private func mondayEveningWithToday(failed: Bool = false)
        -> (Snapshot, (Date) -> TomorrowAlarmStatus, (Date) -> TomorrowAlarmStatus) {
        let now = date(14, 21)
        let value = settings()
        let weather = mondayEveningRecord()
        let registered = summary(normal: date(15, 7, 30), ring: date(15, 7))
        let failedRequest = failed ? weather.request : nil
        let tomorrow = statusProvider(value, weather: weather, summary: registered, failedRequest: failedRequest)
        let today = statusProvider(value, weather: weather, summary: registered, failedRequest: failedRequest, dayOffset: 0)
        return (Builder.snapshot(now: now, context: context(value, summary: registered), status: tomorrow, today: today),
                tomorrow, today)
    }

    /// `mondayEveningWithToday`'s forecast: Tuesday's morning (rain 80%), checked Monday 21:00.
    private func mondayEveningRecord() -> TomorrowWeatherRecord {
        record(settings(), requestedAt: date(14, 21), checkedAt: date(14, 21))
    }

    func testTodayRainEntryRunsFromMidnightThroughItsRing() throws {
        let (snapshot, tomorrow, _) = mondayEveningWithToday()
        XCTAssertTrue(snapshot.isValid)
        // 00:00:01: Monday 21:00's forecast, now today's, passes the widget's 3 hours (D-B).
        XCTAssertEqual(snapshot.entries.map(\.validFrom),
                       [date(14, 21), date(14, 21, 30, 1), date(15, 0), date(15, 0, 0, 1), date(15, 7, 0, 1)])
        XCTAssertEqual(snapshot.entries.map(\.isToday), [false, false, true, true, false])
        XCTAssertEqual(snapshot.expiresAt, date(16, 0))

        // Midnight: still Tuesday's 07:00, now called today, with the evening's decision.
        let today = try XCTUnwrap(entry(snapshot, at: date(15, 0)))
        XCTAssertEqual(today.day, date(15, 0))
        XCTAssertEqual(today.normalAlarmDate, date(15, 7, 30))
        XCTAssertEqual(today.expectedRingDate, date(15, 7), "What AlarmKit's registration rings")
        XCTAssertEqual(today.reason, .rain)
        XCTAssertEqual(today.reasonLine, .rainEarlier(minutes: 30), "Decided by Tuesday's forecast: 因雨提早")
        XCTAssertNil(today.scheduleIssue)
        // Owner 2026-10-02: today's entry carries this morning's forecast, the one last
        // evening's fetch was for. Exactly three hours old at midnight: not yet stale (strict >).
        XCTAssertEqual(today.forecast, Builder.forecast(from: mondayEveningRecord().snapshot))
        XCTAssertNil(today.weatherNotice)
        let stale = try XCTUnwrap(entry(snapshot, at: date(15, 0, 0, 1)))
        XCTAssertTrue(stale.isToday)
        XCTAssertEqual(stale.weatherNotice, .stale)
        XCTAssertEqual(stale.forecast, today.forecast)
        XCTAssertEqual(stale.expectedRingDate, date(15, 7))
        XCTAssertEqual(stale.reasonLine, .rainEarlier(minutes: 30), "The 30-minute decision rule is unchanged")
        XCTAssertNil(stale.scheduleIssue)
        let face = TomorrowWidgetPresentation(.status(stale), clockFormat: snapshot.clockFormat, language: "zh-Hant")
        XCTAssertEqual(face.line, .todayReason(.rainEarlier(minutes: 30)), "Small and Lock Screen: the decision only (D-C)")
        XCTAssertFalse(face.showsWarningBadge)
        XCTAssertTrue(face.showsWeatherColumn)
        // Owner 2026-10-02: the medium's column gives the forecast's time, no warning.
        XCTAssertNil(face.weatherColumnNotice, "Not 天氣資料需要更新")
        XCTAssertEqual(face.weatherColumnFooter,
                       LocalizedLine(key: "widget_forecast_as_of", arguments: [.time(date(14, 21), .twelveHour)]))
        XCTAssertEqual(TomorrowWidgetPresentation(.status(today), clockFormat: snapshot.clockFormat).weatherColumnFooter,
                       LocalizedLine(key: "ux_weather_updated", arguments: [.time(date(14, 21), .twelveHour)]),
                       "Until the stale second: 天氣更新於")
        XCTAssertEqual(face.home, .rain)
        XCTAssertEqual(face.mediumLine, .todayReason(.rainEarlier(minutes: 30)))
        // The widget's tomorrow is calendar tomorrow, Wednesday; the card describes Tuesday
        // too after midnight (the coming morning), under 下次鬧鐘.
        XCTAssertEqual(tomorrow(date(15, 0)).day, date(16, 0))
        let card = statusProvider(settings(), weather: nil, summary: summary(normal: date(15, 7, 30), ring: date(15, 7)),
                                  dayOffset: nil)(date(15, 0))
        XCTAssertEqual(card.day, date(15, 0))
        XCTAssertTrue(card.isToday)
        XCTAssertEqual(card.expectedRingDate, today.expectedRingDate, "The card and the widget's today say the same")

        // Through the ring second itself; then tomorrow, whose 07:00 is the carried-over repeat.
        let plan = TomorrowWidgetTimeline.plan(snapshot: snapshot, now: date(15, 7), currentTimeZoneID: calendar.timeZone.identifier)
        guard case .status(let atRing) = plan.items[0].state else { return XCTFail("status expected") }
        XCTAssertTrue(atRing.isToday)
        let after = try XCTUnwrap(entry(snapshot, at: date(15, 7, 0, 1)))
        XCTAssertFalse(after.isToday)
        XCTAssertEqual(after.day, date(16, 0))
        XCTAssertEqual(after.expectedRingDate, date(16, 7))
        XCTAssertEqual(after.reasonLine, .awaitingForecast)
    }

    func testTodayAfterMidnightPublishCarriesTwoMornings() throws {
        // Tuesday 03:00, the app ran and its tomorrow forecast is now Wednesday's (none for Tuesday).
        let now = date(15, 3)
        let value = settings()
        let registered = summary(normal: date(15, 7, 30), ring: date(15, 7))
        let snapshot = Builder.snapshot(now: now, context: context(value, summary: registered),
                                        status: statusProvider(value, weather: nil, summary: registered),
                                        today: statusProvider(value, weather: nil, summary: registered, dayOffset: 0))
        XCTAssertTrue(snapshot.isValid)
        XCTAssertEqual(snapshot.expiresAt, date(17, 0))
        // Both mornings hand over one second after their ring: a registered date rolls only
        // once strictly past, and a weekly repeat's own slot is still today's ring at its
        // second (`TomorrowAlarmStatus`, "the weekly repeat rings every selected day").
        XCTAssertEqual(snapshot.entries.map(\.validFrom), [now, date(15, 7, 0, 1), date(16, 0), date(16, 7, 0, 1)])
        XCTAssertEqual(snapshot.entries.map(\.isToday), [true, false, true, false])

        let first = snapshot.entries[0]
        XCTAssertEqual(first.expectedRingDate, date(15, 7))
        XCTAssertEqual(first.reasonLine, .rainEarlier(minutes: 30))
        XCTAssertNil(first.forecast)
        XCTAssertEqual(first.weatherNotice, .noForecast)
        let face = TomorrowWidgetPresentation(.status(first), language: "zh-Hant")
        XCTAssertEqual(face.line, .todayReason(.rainEarlier(minutes: 30)), "No weather notice outside the medium (D-C)")
        XCTAssertEqual(face.weatherColumnNotice, .todayNotice(.noForecast))
        XCTAssertEqual(face.weatherColumnNotice?.full.key, "widget_today_weather_unavailable",
                       "尚未取得今天天氣, not 尚未取得明天天氣")

        // Wednesday before its ring: the same 07:00, but only the weekly repeat of Tuesday's rain.
        let wednesday = try XCTUnwrap(entry(snapshot, at: date(16, 0)))
        XCTAssertEqual(wednesday.day, date(16, 0))
        XCTAssertEqual(wednesday.expectedRingDate, date(16, 7))
        XCTAssertEqual(wednesday.reasonLine, .awaitingForecast)
        XCTAssertFalse(wednesday.appliesRainLead)
        XCTAssertNil(wednesday.scheduleIssue)
        XCTAssertNil(wednesday.forecast)
        XCTAssertEqual(wednesday.weatherNotice, .noForecast)

        // The same publish after the app fetched Tuesday's forecast at 03:00: Tuesday's today
        // entry carries it; Wednesday's has none (the app never fetches a morning but the coming one).
        let fetched = record(value, requestedAt: now, checkedAt: now)
        let refreshed = Builder.snapshot(now: now, context: context(value, summary: registered),
                                         status: statusProvider(value, weather: fetched, summary: registered),
                                         today: statusProvider(value, weather: fetched, summary: registered, dayOffset: 0))
        XCTAssertTrue(refreshed.isValid)
        XCTAssertTrue(refreshed.entries[0].isToday)
        XCTAssertEqual(refreshed.entries[0].forecast, Builder.forecast(from: fetched.snapshot))
        XCTAssertNil(refreshed.entries[0].weatherNotice)
        XCTAssertEqual(refreshed.entries[0].reasonLine, .rainForecast(percent: 80, minutes: 30))
        let nextToday = try XCTUnwrap(refreshed.entries.first { $0.isToday && $0.day == date(16, 0) })
        XCTAssertNil(nextToday.forecast)
        XCTAssertEqual(nextToday.weatherNotice, .noForecast)
    }

    func testSkippedTodayRunsUntilItsNormalTime() throws {
        // Weekdays only; Saturday 2026-09-19 is skipped. Friday 21:00, nothing registered.
        var value = settings()
        value.selectedWeekdays = [2, 3, 4, 5, 6]
        let now = date(18, 21)
        let snapshot = Builder.snapshot(now: now, context: context(value, summary: nil),
                                        status: statusProvider(value, weather: nil, summary: nil),
                                        today: statusProvider(value, weather: nil, summary: nil, dayOffset: 0))
        XCTAssertEqual(snapshot.entries.map(\.validFrom), [now, date(19, 0), date(19, 7, 30, 1)])
        XCTAssertEqual(snapshot.entries.map(\.isToday), [false, true, false])
        let saturday = snapshot.entries[1]
        XCTAssertEqual(saturday.day, date(19, 0))
        XCTAssertNil(saturday.expectedRingDate)
        XCTAssertEqual(saturday.reason, .weekend)
        XCTAssertEqual(saturday.reasonLine, .weekend)
        XCTAssertEqual(saturday.weatherNotice, .noForecast, "The medium's column: 尚未取得今天天氣 (fetched even on a skipped day)")
        XCTAssertEqual(snapshot.entries[2].day, date(20, 0), "After its normal time: Sunday, as tomorrow")
        // Its last shown second is its normal time, and the column stays through it (the
        // builder's strict >), with no one-second entry without it before Sunday, although the
        // app's coming morning is already Sunday's at that second.
        XCTAssertEqual(TomorrowWeatherRequest(settings: value, now: date(19, 7, 30), calendar: calendar).normalAlarmDate,
                       date(20, 7, 30))
        XCTAssertNil(entry(snapshot, at: date(19, 7, 30)), "No one-second entry at the normal time: midnight's runs on")
        let last = try XCTUnwrap(shownEntry(snapshot, at: date(19, 7, 30)))
        XCTAssertTrue(last.isToday)
        XCTAssertEqual(last.day, date(19, 0))
        XCTAssertEqual(last.weatherNotice, .noForecast)
        XCTAssertTrue(TomorrowWidgetPresentation(.status(last)).showsWeatherColumn)
    }

    func testNoTodayEntryOnceTodaysRingHasPassed() {
        let now = date(15, 8)
        let value = settings()
        let registered = summary(normal: date(15, 7, 30), ring: date(15, 7))
        let snapshot = Builder.snapshot(now: now, context: context(value, summary: registered),
                                        status: statusProvider(value, weather: nil, summary: registered),
                                        today: statusProvider(value, weather: nil, summary: registered, dayOffset: 0))
        XCTAssertFalse(snapshot.entries[0].isToday)
        XCTAssertEqual(snapshot.entries[0].day, date(16, 0))
        XCTAssertFalse(snapshot.entries.contains { $0.day == date(15, 0) }, "Tuesday's ring is gone")
        XCTAssertEqual(snapshot.entries.first { $0.isToday }?.validFrom, date(16, 0), "Wednesday becomes today at midnight")
    }

    func testTodayEndsAtTheRegisteredRingOrNormalTime() {
        let normal = date(15, 7, 30)
        func today(expected: Date?, registered: Date?, current: Bool) -> TomorrowAlarmStatus {
            var value = status(reason: expected == nil ? .weekend : .normal, expected: expected, registered: registered)
            value.day = date(15, 0)
            value.normalAlarmDate = normal
            value.isRegistrationCurrent = current
            return value
        }
        XCTAssertEqual(Builder.todayShownUntil(today(expected: date(15, 7), registered: date(15, 7), current: true)), date(15, 7))
        XCTAssertEqual(Builder.todayShownUntil(today(expected: date(15, 7), registered: normal, current: true)), normal,
                       "The forecast moved it but the registration did not: AlarmKit rings at the registered time")
        XCTAssertEqual(Builder.todayShownUntil(today(expected: nil, registered: normal, current: true)), normal,
                       "A closure not yet registered still rings")
        XCTAssertEqual(Builder.todayShownUntil(today(expected: nil, registered: nil, current: true)), normal, "Skipped: its normal time")
        XCTAssertEqual(Builder.todayShownUntil(today(expected: normal, registered: nil, current: true)), .distantPast,
                       "A ring day with no registered ring left has rung (consumed)")
        XCTAssertEqual(Builder.todayShownUntil(today(expected: normal, registered: nil, current: false)), normal,
                       "Nothing registered: the configured time")
        // Not consumed: the committed schedule lacks a morning that should ring. The card warns
        // until the normal time (鬧鐘設定尚未更新完成), so the widget's today entry stays too.
        var withdrawn = today(expected: normal, registered: nil, current: true)
        withdrawn.hasCommittedClosureSkip = true
        XCTAssertTrue(withdrawn.ringIsNotRegistered)
        XCTAssertEqual(Builder.todayShownUntil(withdrawn), normal, "A committed skip the notice no longer supports")
        var lost = today(expected: date(15, 7), registered: nil, current: true)
        lost.isMissingFromPlan = true
        XCTAssertEqual(Builder.todayShownUntil(lost), normal, "A plan that lost the morning: until the normal time")
    }

    /// A committed closure skip for Tuesday, then the notice is withdrawn (here: the feature
    /// is off, so nothing supports it) before the re-registration runs. AlarmKit still skips
    /// Tuesday. From midnight to 07:30 the widget must show today with the card's warning,
    /// never jump to Wednesday as if Tuesday had rung.
    func testAWithdrawnClosureKeepsTodayWithTheCardsWarning() {
        let value = settings()
        var plan = summary(normal: date(16, 7, 30), ring: date(16, 7, 30))
        plan.calendarPlan = .init(occurrences: [.init(normalDate: date(16, 7, 30), ringDate: date(16, 7, 30))],
                                  coveredUntil: date(20, 0), timeZoneID: calendar.timeZone.identifier)
        plan.disasterSkips = [.init(normalDate: date(15, 7, 30), noticeIDs: ["n"], appliedAt: date(14, 20))]
        let snapshot = Builder.snapshot(now: date(14, 21), context: context(value, summary: plan),
                                        status: statusProvider(value, weather: nil, summary: plan),
                                        today: statusProvider(value, weather: nil, summary: plan, dayOffset: 0))
        XCTAssertTrue(snapshot.isValid)
        for moment in [date(15, 0), date(15, 3), date(15, 7, 29)] {
            let plan = TomorrowWidgetTimeline.plan(snapshot: snapshot, now: moment, currentTimeZoneID: calendar.timeZone.identifier)
            guard case .status(let shown) = plan.items[0].state else { XCTFail("No status at \(moment)"); continue }
            XCTAssertTrue(shown.isToday, "\(moment)")
            XCTAssertEqual(shown.day, date(15, 0), "\(moment)")
            XCTAssertEqual(shown.expectedRingDate, date(15, 7, 30), "\(moment)")
            XCTAssertEqual(shown.scheduleIssue, .updateNeeded, "\(moment): the card's 鬧鐘設定尚未更新完成")
        }
        let after = TomorrowWidgetTimeline.plan(snapshot: snapshot, now: date(15, 7, 31), currentTimeZoneID: calendar.timeZone.identifier)
        guard case .status(let tomorrow) = after.items[0].state else { return XCTFail("No status after the normal time") }
        XCTAssertFalse(tomorrow.isToday)
        XCTAssertEqual(tomorrow.day, date(16, 0))
    }

    func testConsumedDatedOccurrenceAndCrossMidnightLeadEndToday() {
        let value = settings()
        // A dated plan re-registered at 07:10, after Tuesday's 07:00 ring: Tuesday is gone from
        // it, and registerCalendar recorded when it rang.
        var plan = summary(normal: date(16, 7, 30), ring: date(16, 7, 30))
        plan.calendarPlan = .init(occurrences: [.init(normalDate: date(16, 7, 30), ringDate: date(16, 7, 30))],
                                  coveredUntil: date(20, 0), timeZoneID: calendar.timeZone.identifier)
        plan.firedEarlyRing = .init(normalDate: date(15, 7, 30), ringDate: date(15, 7))
        let afterRing = Builder.snapshot(now: date(15, 7, 10), context: context(value, summary: plan),
                                         status: statusProvider(value, weather: nil, summary: plan),
                                         today: statusProvider(value, weather: nil, summary: plan, dayOffset: 0))
        XCTAssertFalse(afterRing.entries[0].isToday, "Not 今天 07:30: AlarmKit will not ring again today")
        XCTAssertEqual(afterRing.entries[0].day, date(16, 0))

        // 00:10 whose rain lead rang Monday 23:40: Tuesday has no ring left after midnight.
        var early = settings()
        early.alarmTime = date(15, 0, 10)
        let crossing = summary(normal: date(15, 0, 10), ring: date(14, 23, 40))
        let snapshot = Builder.snapshot(now: date(14, 22), context: context(early, summary: crossing),
                                        status: statusProvider(early, weather: nil, summary: crossing),
                                        today: statusProvider(early, weather: nil, summary: crossing, dayOffset: 0))
        XCTAssertTrue(snapshot.isValid)
        XCTAssertFalse(snapshot.entries.contains { $0.isToday && $0.day == date(15, 0) }, "Tuesday's ring fired on Monday")
        XCTAssertEqual(snapshot.entries.first?.expectedRingDate, date(14, 23, 40))
    }

    /// Whatever the widget shows, today or tomorrow, is the ring AlarmKit's weekly repeat
    /// will fire for that morning, or it says the schedule needs an update.
    func testTodayEntriesNeverContradictTheRegistration() {
        let start = date(14, 21)
        for rainDecided in [true, false] {
            var value = settings()
            value.alarmTime = date(15, 7, 30)
            let registered = summary(normal: date(15, 7, 30), ring: rainDecided ? date(15, 7) : date(15, 7, 30))
            let weather = record(value, requestedAt: start, checkedAt: start)
            let tomorrow = statusProvider(value, weather: weather, summary: registered)
            let today = statusProvider(value, weather: weather, summary: registered, dayOffset: 0)
            let context = context(value, summary: registered)
            let publishes = [start, date(15, 3), start.addingTimeInterval(86_400)].map {
                Builder.snapshot(now: $0, context: context, status: tomorrow, today: today)
            }
            for step in 0..<(48 * 12) {
                let now = start.addingTimeInterval(Double(step) * 300)
                guard let snapshot = publishes.last(where: { $0.publishedAt <= now }) else { continue }
                let plan = TomorrowWidgetTimeline.plan(snapshot: snapshot, now: now, currentTimeZoneID: calendar.timeZone.identifier)
                guard case .status(let shown) = plan.items[0].state else { XCTFail("No status at \(now)"); continue }
                let label = "rain \(rainDecided) at \(now)"
                if shown.isToday {
                    XCTAssertEqual(shown.day, calendar.startOfDay(for: now), label)
                    XCTAssertLessThanOrEqual(now, shown.expectedRingDate ?? shown.normalAlarmDate, label)
                } else {
                    XCTAssertEqual(shown.day, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)), label)
                }
                let rolled = registered.rollingForwardAsPair(selectedWeekdays: value.selectedWeekdays, now: now, calendar: calendar)
                let truth = rolled.normalAlarmDate == shown.normalAlarmDate ? rolled.scheduledAlarmDate : nil
                XCTAssertTrue(truth == nil || shown.expectedRingDate == truth || shown.scheduleIssue == .updateNeeded,
                              "\(label): shows \(String(describing: shown.expectedRingDate)), AlarmKit rings \(String(describing: truth))")
                // Between midnight and the ring, the day that rings is today's.
                let midnight = calendar.startOfDay(for: now)
                if now >= midnight, now <= (rainDecided ? date(15, 7) : date(15, 7, 30)), calendar.isDate(now, inSameDayAs: date(15, 0)) {
                    XCTAssertTrue(shown.isToday, label)
                }
            }
        }
    }

    /// DST: the today entry starts at the local midnight and ends at the local ring time,
    /// however many real hours lie between them.
    func testTodayEntryFollowsLocalMidnightAndRingAcrossDST() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        func ny(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
            newYork.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute, second: second))!
        }
        // Spring forward (2026-03-08: 02:00 → 03:00) and fall back (2026-11-01: 02:00 → 01:00).
        for (month, day, hoursToRing) in [(3, 8, 5.0), (11, 1, 7.0)] {
            var value = settings()
            value.alarmTime = ny(month, day, 6, 30)
            let registered = summary(normal: ny(month, day, 6, 30), ring: ny(month, day, 6, 0))
            let context = Builder.Context(calendar: newYork, clockFormat: .twelveHour, mode: .car, addressesMissing: false,
                                          flags: .init(), rainLeadTimeMinutes: 30,
                                          ringAnchors: [registered.scheduledAlarmDate, registered.normalAlarmDate])
            let publish = newYork.date(byAdding: .hour, value: -3, to: ny(month, day, 0))!
            let snapshot = Builder.snapshot(
                now: publish, context: context,
                status: statusProvider(value, weather: nil, summary: registered, calendar: newYork),
                today: statusProvider(value, weather: nil, summary: registered, dayOffset: 0, calendar: newYork))
            XCTAssertTrue(snapshot.isValid, "\(month)/\(day)")
            let midnight = newYork.startOfDay(for: ny(month, day, 12))
            XCTAssertEqual(midnight, ny(month, day, 0))
            let today = try XCTUnwrap(snapshot.entries.first { $0.isToday }, "\(month)/\(day)")
            XCTAssertEqual(today.validFrom, midnight)
            XCTAssertEqual(today.expectedRingDate, ny(month, day, 6, 0))
            XCTAssertEqual(today.reasonLine, .rainEarlier(minutes: 30))
            XCTAssertEqual(today.expectedRingDate?.timeIntervalSince(midnight), hoursToRing * 3_600,
                           "\(month)/\(day): the local 06:00 is \(hoursToRing) real hours after midnight")
            let next = try XCTUnwrap(snapshot.entries.first { $0.validFrom > midnight && !$0.isToday }, "\(month)/\(day)")
            XCTAssertEqual(next.validFrom, ny(month, day, 6, 0, 1), "Tomorrow again one second after the ring")
            XCTAssertEqual(next.day, ny(month, day + 1, 0))
        }
    }

    // MARK: Timeline plan

    func testTimelinePlan() throws {
        typealias Timeline = TomorrowWidgetTimeline
        let tz = calendar.timeZone.identifier
        let (snapshot, _, _) = mondayEvening()
        let now = snapshot.publishedAt

        let missing = Timeline.plan(snapshot: nil, now: now, currentTimeZoneID: tz)
        XCTAssertEqual(missing.items, [.init(date: now, state: .needsApp(.missing))])
        XCTAssertEqual(missing.reloadAfter, now.addingTimeInterval(6 * 3_600))

        var outdated = snapshot
        outdated.version = 99
        XCTAssertEqual(Timeline.plan(snapshot: outdated, now: now, currentTimeZoneID: tz).items,
                       [.init(date: now, state: .needsApp(.outdated))])

        let moved = Timeline.plan(snapshot: snapshot, now: now, currentTimeZoneID: "America/New_York")
        XCTAssertEqual(moved.items, [.init(date: now, state: .needsApp(.timeZoneChanged))])
        XCTAssertEqual(moved.reloadAfter, now.addingTimeInterval(2 * 3_600))

        let early = now.addingTimeInterval(-Timeline.clockSkewTolerance - 1)
        XCTAssertEqual(Timeline.plan(snapshot: snapshot, now: early, currentTimeZoneID: tz).items,
                       [.init(date: early, state: .needsApp(.clockChanged))])

        let expired = Timeline.plan(snapshot: snapshot, now: snapshot.expiresAt, currentTimeZoneID: tz)
        XCTAssertEqual(expired.items, [.init(date: snapshot.expiresAt, state: .needsApp(.expired))])
        XCTAssertEqual(expired.reloadAfter, snapshot.expiresAt.addingTimeInterval(6 * 3_600))

        // Within the skew tolerance before publish: the first entry, re-stamped.
        let skewed = now.addingTimeInterval(-60)
        let beforeFirst = Timeline.plan(snapshot: snapshot, now: skewed, currentTimeZoneID: tz)
        var restamped = snapshot.entries[0]
        restamped.validFrom = skewed
        XCTAssertEqual(beforeFirst.items.first, .init(date: skewed, state: .status(restamped)))
        XCTAssertEqual(beforeFirst.items.count, snapshot.entries.count + 1)

        // Between entries: the active one re-stamped to now, then every later one, then expiry.
        let between = snapshot.entries[1].validFrom.addingTimeInterval(600)
        let plan = Timeline.plan(snapshot: snapshot, now: between, currentTimeZoneID: tz)
        var active = snapshot.entries[1]
        active.validFrom = between
        XCTAssertEqual(plan.items.first, .init(date: between, state: .status(active)))
        let later: [TomorrowWidgetTimeline.Item] = snapshot.entries.dropFirst(2).map {
            TomorrowWidgetTimeline.Item(date: $0.validFrom, state: .status($0))
        }
        XCTAssertEqual(Array(plan.items.dropFirst().dropLast()), later)
        XCTAssertEqual(plan.items.last, .init(date: snapshot.expiresAt, state: .needsApp(.expired)))
        XCTAssertEqual(plan.items.map(\.date), plan.items.map(\.date).sorted())

        // Reloads: never more than 6 h away, and at most 2 h while a status is shown.
        var moment = now
        while moment < snapshot.expiresAt.addingTimeInterval(3_600) {
            let result = Timeline.plan(snapshot: snapshot, now: moment, currentTimeZoneID: tz)
            XCTAssertLessThanOrEqual(result.reloadAfter, moment.addingTimeInterval(6 * 3_600))
            XCTAssertGreaterThan(result.reloadAfter, moment)
            if case .status = result.items[0].state {
                XCTAssertLessThanOrEqual(result.reloadAfter, moment.addingTimeInterval(2 * 3_600))
                XCTAssertLessThanOrEqual(result.reloadAfter, snapshot.expiresAt)
            }
            moment.addTimeInterval(1_800)
        }
    }

    func testEquivalenceIgnoresPublishTimeAndElapsedEntries() {
        let (original, context, provider) = mondayEvening()
        let later = date(14, 21, 10)
        let republished = Builder.snapshot(now: later, context: context, status: provider)
        XCTAssertNotEqual(original, republished)
        XCTAssertTrue(original.isEquivalent(to: republished, at: later))
        XCTAssertTrue(republished.isEquivalent(to: original, at: later))

        // After an entry has elapsed, the older snapshot simply carries more history.
        let afterStale = date(14, 21, 40)
        let trimmed = Builder.snapshot(now: afterStale, context: context, status: provider)
        XCTAssertLessThan(trimmed.entries.count, original.entries.count)
        XCTAssertTrue(original.isEquivalent(to: trimmed, at: afterStale))
        // A new local day moves the expiry (D3), so that is a rewrite, not a duplicate.
        let afterMidnight = date(15, 1)
        XCTAssertFalse(original.isEquivalent(to: Builder.snapshot(now: afterMidnight, context: context, status: provider),
                                             at: afterMidnight))

        let (rechecked, _, _) = mondayEvening(checkedAt: date(14, 20, 55))
        XCTAssertFalse(original.isEquivalent(to: rechecked, at: date(14, 21)), "A new checkedAt is new content")
        var extended = republished
        extended.expiresAt = extended.expiresAt.addingTimeInterval(3_600)
        XCTAssertFalse(original.isEquivalent(to: extended, at: later))
        var reformatted = republished
        reformatted.clockFormat = .twentyFourHour
        XCTAssertFalse(original.isEquivalent(to: reformatted, at: later))
    }

    func testPublisherWritesAndReloadsOnlyOnChange() {
        let reloads = ReloadCounter()
        let store = TomorrowWidgetStore(suiteName: suiteName)
        let publisher = TomorrowWidgetPublisher(store: store, reload: { reloads.count += 1 }, isEnabled: true)
        let (original, context, provider) = mondayEvening()
        XCTAssertTrue(publisher.write(original, now: original.publishedAt))
        let later = date(14, 21, 10)
        XCTAssertFalse(publisher.write(Builder.snapshot(now: later, context: context, status: provider), now: later))
        XCTAssertEqual(reloads.count, 1)
        XCTAssertEqual(store.load(), original, "An equivalent snapshot is not rewritten")

        var changed = Builder.snapshot(now: later, context: context, status: provider)
        changed.clockFormat = .twentyFourHour
        XCTAssertTrue(publisher.write(changed, now: later))
        XCTAssertEqual(reloads.count, 2)
        XCTAssertEqual(store.load(), changed)

        // The foreground publish reloads even an unchanged snapshot: the widget may be showing
        // a face only a reload clears (a time zone or clock change, since undone).
        XCTAssertFalse(publisher.write(changed, now: later, forceReload: true), "Still not rewritten")
        XCTAssertEqual(reloads.count, 3)
        XCTAssertEqual(store.load(), changed)

        XCTAssertFalse(publisher.publish(), "No model attached: nothing to publish")
        XCTAssertFalse(publisher.publish(forceReload: true))
        XCTAssertEqual(reloads.count, 3, "Without a model the forced reload waits for start(observing:)")
    }

    /// Adversarial review, 2026-10-01: a cold background or push launch attaches the publisher
    /// before the plan restore, and a snapshot built then drops a saved closure rule (no plan
    /// applies no closure): a skipped morning shown ringing, corrected only by a second reload
    /// that WidgetKit may throttle. Nothing is written until the restore has been tried; a forced
    /// reload asked for meanwhile comes with the first write.
    func testThePublisherWaitsForThePlanRestore() async throws {
        var value = settings()
        value.isDisasterSuspensionEnabled = true
        storage.set(try JSONEncoder().encode(value), forKey: "commuteAlarmSettings")
        let model = AlarmViewModel(notificationScheduler: SilentScheduler(), settingsStorage: storage,
                                   membershipEntitlements: { nil }, membershipConfigured: { true },
                                   restoreMembershipEntitlements: {}, supportsTemporaryClosures: true)
        XCTAssertFalse(model.membershipPlanIsSettled)
        let reloads = ReloadCounter()
        let store = TomorrowWidgetStore(suiteName: suiteName)
        let publisher = TomorrowWidgetPublisher(store: store, reload: { reloads.count += 1 }, isEnabled: true)
        publisher.start(observing: model)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(publisher.publish(forceReload: true))
        XCTAssertNil(store.load(), "No snapshot before the plan restore has been tried")
        XCTAssertEqual(reloads.count, 0)

        await model.loadMembershipEntitlements()
        XCTAssertTrue(model.membershipPlanIsSettled)
        XCTAssertTrue(publisher.publish())
        XCTAssertNotNil(store.load())
        XCTAssertEqual(reloads.count, 1)
    }

    // MARK: D1 on the real model

    func testModelTomorrowStatusRollsWeeklySummaryAfterRing() throws {
        let alarmCalendar = AlarmCalendarSettings.calendar
        let day = alarmCalendar.date(byAdding: .day, value: 2, to: alarmCalendar.startOfDay(for: Date()))!
        func at(_ base: Date, _ hour: Int, _ minute: Int) -> Date {
            alarmCalendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
        }
        var value = CommuteAlarmSettings()
        value.homeAddress = "Home"
        value.workAddress = "Work"
        value.selectedWeekdays = Set(1...7)
        value.alarmTime = at(day, 7, 30)
        value.rainLeadTimeMinutes = 30
        let registered = ScheduledAlarmSummary(
            normalAlarmDate: at(day, 7, 30), scheduledAlarmDate: at(day, 7, 0), weatherRefreshDate: at(day, 7, 0),
            exceedsRainThreshold: true, leadTimeMinutes: 30, rainProbabilityThreshold: 0.5,
            maximumPrecipitationProbability: 0.8)
        let encoder = JSONEncoder()
        storage.set(try encoder.encode(value), forKey: "commuteAlarmSettings")
        storage.set(try encoder.encode(registered), forKey: "scheduledAlarmSummaryDisplay")
        storage.set(try encoder.encode(value.scheduleFingerprint(calendar: alarmCalendar)), forKey: "scheduledAlarmFingerprint")

        let model = AlarmViewModel(notificationScheduler: SilentScheduler(), settingsStorage: storage,
                                   membershipEntitlements: { nil })
        var recorded = registered
        recorded.decisionNormalAlarmDate = registered.normalAlarmDate
        XCTAssertEqual(model.scheduledAlarmSummary, recorded,
                       "init must not roll a future summary; a pre-1.8.0 one gets the morning it was decided for")

        let next = alarmCalendar.date(byAdding: .day, value: 1, to: day)!
        let afterRing = model.tomorrowStatus(now: at(day, 7, 31))
        XCTAssertEqual(afterRing.expectedRingDate, at(next, 7, 0))
        XCTAssertEqual(afterRing.reason, .rain)
        XCTAssertEqual(afterRing.registeredRingDate, at(next, 7, 0))
        // The stored summary predates `decisionNormalAlarmDate`; the unrolled one the model
        // holds still names the morning that was decided, so the lead reads as carried over.
        XCTAssertTrue(afterRing.rainLeadIsCarriedOver)
        XCTAssertEqual(TomorrowWidgetSnapshotBuilder.reasonLine(for: afterRing), .awaitingForecast)

        // Before the ring nothing is rolled: identical to resolving with the stored summary.
        let evening = at(alarmCalendar.date(byAdding: .day, value: -1, to: day)!, 20, 0)
        let before = model.tomorrowStatus(now: evening)
        let unrolled = TomorrowAlarmStatus.resolve(
            settings: model.effectiveSchedulingSettings, holidays: model.holidayCalendar, weatherRecord: nil,
            weatherRefreshFailed: false, routeIsReady: true, summary: registered,
            registeredFingerprint: value.scheduleFingerprint(calendar: alarmCalendar),
            disasterFeed: nil, disasterSourceFailed: false, now: evening)
        XCTAssertEqual(before, unrolled)
        XCTAssertEqual(before.expectedRingDate, at(day, 7, 0))
        XCTAssertEqual(before.registeredRingDate, at(day, 7, 0))
    }
}

extension TomorrowWidgetSnapshotTests {
    /// D-C on the real model: `todayStatus` is the registered morning, and the published
    /// snapshot opens on it after midnight.
    func testModelTodayStatusIsTheRegisteredMorning() throws {
        let alarmCalendar = AlarmCalendarSettings.calendar
        let day = alarmCalendar.date(byAdding: .day, value: 2, to: alarmCalendar.startOfDay(for: Date()))!
        let next = alarmCalendar.date(byAdding: .day, value: 1, to: day)!
        func at(_ base: Date, _ hour: Int, _ minute: Int) -> Date {
            alarmCalendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
        }
        var value = CommuteAlarmSettings()
        value.homeAddress = "Home"
        value.workAddress = "Work"
        value.selectedWeekdays = Set(1...7)
        value.alarmTime = at(day, 7, 30)
        value.rainLeadTimeMinutes = 30
        let registered = ScheduledAlarmSummary(
            normalAlarmDate: at(day, 7, 30), scheduledAlarmDate: at(day, 7, 0), weatherRefreshDate: at(day, 7, 0),
            exceedsRainThreshold: true, leadTimeMinutes: 30, rainProbabilityThreshold: 0.5,
            maximumPrecipitationProbability: 0.8, decisionNormalAlarmDate: at(day, 7, 30))
        let encoder = JSONEncoder()
        storage.set(try encoder.encode(value), forKey: "commuteAlarmSettings")
        storage.set(try encoder.encode(registered), forKey: "scheduledAlarmSummaryDisplay")
        storage.set(try encoder.encode(value.scheduleFingerprint(calendar: alarmCalendar)), forKey: "scheduledAlarmFingerprint")
        let model = AlarmViewModel(notificationScheduler: SilentScheduler(), settingsStorage: storage,
                                   membershipEntitlements: { nil })

        let early = model.todayStatus(now: at(day, 3, 0))
        XCTAssertEqual(early.day, day)
        XCTAssertEqual(early.expectedRingDate, at(day, 7, 0))
        XCTAssertEqual(early.registeredRingDate, at(day, 7, 0))
        XCTAssertEqual(early.reason, .rain)
        XCTAssertFalse(early.rainLeadIsCarriedOver)
        // Since 2026-09-29 the card describes the coming morning: after midnight that is
        // today's, the same reading as the widget's today. The widget's tomorrow is the next day.
        XCTAssertEqual(model.tomorrowStatus(now: at(day, 3, 0)), early, "The card and the widget's today agree")
        XCTAssertEqual(model.calendarTomorrowStatus(now: at(day, 3, 0)).day, next)

        let snapshot = Builder.snapshot(for: model, now: at(day, 3, 0))
        XCTAssertTrue(snapshot.isValid)
        XCTAssertTrue(snapshot.entries[0].isToday)
        XCTAssertEqual(snapshot.entries[0].expectedRingDate, at(day, 7, 0))
        XCTAssertEqual(snapshot.entries[0].reasonLine, .rainEarlier(minutes: 30))
        XCTAssertEqual(snapshot.entries[1].validFrom, at(day, 7, 0).addingTimeInterval(1))
        XCTAssertFalse(snapshot.entries[1].isToday)

        // The next morning, before its ring: the weekly repeat of that rain, carried over.
        let carried = model.todayStatus(now: at(next, 3, 0))
        XCTAssertEqual(carried.day, next)
        XCTAssertEqual(carried.expectedRingDate, at(next, 7, 0))
        XCTAssertTrue(carried.rainLeadIsCarriedOver)
    }
}

/// The 2026-09-24 review of D-A to D-D: what AlarmKit will actually do, in the edge cases.
extension TomorrowWidgetSnapshotTests {
    /// The entry the widget renders at `moment`, as its timeline picks it.
    private func shownEntry(_ snapshot: Snapshot, at moment: Date) -> Snapshot.Entry? {
        let plan = TomorrowWidgetTimeline.plan(snapshot: snapshot, now: moment, currentTimeZoneID: calendar.timeZone.identifier)
        guard case .status(let entry) = plan.items[0].state else { return nil }
        return entry
    }

    /// A rain lead across midnight rang Monday 23:40 for Tuesday's 00:10. Until midnight the
    /// widget keeps that ring: never 明天 00:10 照常響鈴, which AlarmKit will not ring.
    func testRingFiredBeforeMidnightIsNotReplacedByOneThatWillNotRing() throws {
        var value = settings()
        value.alarmTime = date(15, 0, 10)
        let registered = summary(normal: date(15, 0, 10), ring: date(14, 23, 40))
        let publish = date(14, 22)
        for weather in [record(value, requestedAt: publish, checkedAt: publish), nil] {
            let label = weather == nil ? "no forecast" : "80% forecast"
            let snapshot = Builder.snapshot(now: publish, context: context(value, summary: registered),
                                            status: statusProvider(value, weather: weather, summary: registered),
                                            today: statusProvider(value, weather: weather, summary: registered, dayOffset: 0))
            XCTAssertTrue(snapshot.isValid, label)
            XCTAssertEqual(shownEntry(snapshot, at: date(14, 23, 30))?.expectedRingDate, date(14, 23, 40), label)
            for moment in [date(14, 23, 40, 1), date(14, 23, 50), date(14, 23, 59, 59)] {
                let shown = try XCTUnwrap(shownEntry(snapshot, at: moment), label)
                XCTAssertEqual(shown.day, date(15, 0), label)
                XCTAssertEqual(shown.expectedRingDate, date(14, 23, 40), "\(label) at \(moment): the ring that served Tuesday")
                XCTAssertTrue(shown.appliesRainLead, label)
                XCTAssertEqual(shown.reasonLine, .rainEarlier(minutes: 30), label)
                XCTAssertNil(shown.scheduleIssue, label)
                XCTAssertNotEqual(TomorrowWidgetPresentation(.status(shown)).line, .ringsAsUsual, label)
            }
            // From midnight Tuesday is over (its ring fired on Monday): Wednesday, as tomorrow.
            let midnight = try XCTUnwrap(shownEntry(snapshot, at: date(15, 0)), label)
            XCTAssertFalse(midnight.isToday, label)
            XCTAssertEqual(midnight.day, date(16, 0), label)
            XCTAssertEqual(midnight.expectedRingDate, date(15, 23, 40), label)
            XCTAssertEqual(midnight.reasonLine, .awaitingForecast, label)
        }
        // The status says so on its own: the pair roll moved past Tuesday's slot, which rang
        // (the registration was decided for Tuesday). The card reads the same: 已響鈴 23:40.
        let tuesday = statusProvider(value, weather: nil, summary: registered)(date(14, 23, 50))
        XCTAssertEqual(tuesday.passedRingDate, date(14, 23, 40))
        XCTAssertEqual(tuesday.registeredRingDate, date(14, 23, 40))
        XCTAssertEqual(tuesday.expectedRingDate, date(14, 23, 40))
        XCTAssertTrue(tuesday.hasRung)
        XCTAssertEqual(tuesday.reason, .rain)
        XCTAssertNil(Builder.scheduleIssue(for: tuesday, flags: .init()))
        XCTAssertEqual(statusProvider(value, weather: nil, summary: registered, dayOffset: nil)(date(14, 23, 50)), tuesday,
                       "Before midnight the card's coming morning is the widget's tomorrow")
    }

    /// The alarm time moved in the evening and the re-registration failed (offline, or
    /// deferred): AlarmKit still holds the old alarm. Today's entry shows that ring, flagged
    /// "update needed", and ends with it, in either direction of the move.
    func testTodayShowsTheOutdatedRegistrationAlarmKitStillHolds() throws {
        for (old, new) in [((7, 30), (8, 0)), ((8, 0), (7, 30))] {
            var before = settings()
            before.alarmTime = date(15, old.0, old.1)
            var after = settings()
            after.alarmTime = date(15, new.0, new.1)
            let oldRing = date(15, old.0, old.1)
            let registered = summary(normal: oldRing, ring: oldRing)
            let fingerprint = before.scheduleFingerprint(calendar: calendar)
            func provider(_ offset: Int, weather: TomorrowWeatherRecord? = nil) -> (Date) -> TomorrowAlarmStatus {
                { t in
                    TomorrowAlarmStatus.resolve(
                        settings: after, holidays: .init(), weatherRecord: weather, weatherRefreshFailed: false,
                        summary: registered.rollingForwardAsPair(selectedWeekdays: fingerprint.selectedWeekdays, now: t, calendar: self.calendar),
                        registeredFingerprint: fingerprint, disasterFeed: nil, disasterSourceFailed: false,
                        now: t, calendar: self.calendar, dayOffset: offset)
                }
            }
            let snapshot = Builder.snapshot(now: date(14, 22),
                                            context: context(after, summary: registered, flags: .init(isScheduleStale: true)),
                                            status: provider(1), today: provider(0))
            let label = "\(old) → \(new)"
            XCTAssertTrue(snapshot.isValid, label)
            let today = try XCTUnwrap(shownEntry(snapshot, at: date(15, 0)), label)
            XCTAssertTrue(today.isToday, label)
            XCTAssertEqual(today.expectedRingDate, oldRing, "\(label): the ring AlarmKit still has")
            XCTAssertEqual(today.scheduleIssue, .updateNeeded, label)
            XCTAssertNil(today.reasonLine, label)
            XCTAssertEqual(TomorrowWidgetPresentation(.status(today)).line, .issue(.updateNeeded), label)
            XCTAssertEqual(shownEntry(snapshot, at: oldRing)?.isToday, true, "\(label): through the ring second")
            let afterRing = try XCTUnwrap(shownEntry(snapshot, at: oldRing.addingTimeInterval(1)), label)
            XCTAssertFalse(afterRing.isToday, "\(label): the old alarm rang, and nothing else rings today")
            XCTAssertEqual(afterRing.day, date(16, 0), label)
            XCTAssertEqual(afterRing.scheduleIssue, .updateNeeded, label)

            // Today's weather column (2026-10-02), with no forecast fetched for Tuesday.
            let early = try XCTUnwrap(shownEntry(snapshot, at: date(15, 7, 15)), label)
            XCTAssertTrue(early.isToday, label)
            XCTAssertNil(early.forecast, label)
            XCTAssertEqual(early.weatherNotice, .noForecast, "\(label): 尚未取得今天天氣 before today's normal time")
            guard old > new else { continue }
            // The old ring is later than the new normal time. Past that normal time the app has
            // moved on to Wednesday's forecast and never fetches Tuesday's again: no "not
            // available yet" that would never come true, and so no column at all.
            let late = try XCTUnwrap(shownEntry(snapshot, at: date(15, 7, 45)), label)
            XCTAssertTrue(late.isToday, label)
            XCTAssertEqual(late.expectedRingDate, oldRing, label)
            XCTAssertNil(late.forecast, label)
            XCTAssertNil(late.weatherNotice, label)
            XCTAssertFalse(TomorrowWidgetPresentation(.status(late)).showsWeatherColumn, label)
            // Strictly past: at the normal time itself the entry keeps its notice, for continuity,
            // although the app's coming morning has already moved on to Wednesday then.
            XCTAssertEqual(shownEntry(snapshot, at: date(15, 7, 30))?.weatherNotice, .noForecast,
                           "\(label): the normal-time second keeps the column (strict >)")
            XCTAssertEqual(TomorrowWeatherRequest(settings: after, now: date(15, 7, 30), calendar: calendar).normalAlarmDate,
                           date(16, 7, 30), "\(label): not because the coming morning is still Tuesday's")
            // A forecast the app did fetch for Tuesday still matches today's request then: the
            // column keeps showing it, with its age.
            let tuesday = record(after, requestedAt: date(14, 22), checkedAt: date(14, 22))
            let fetched = Builder.snapshot(now: date(14, 22),
                                           context: context(after, summary: registered, flags: .init(isScheduleStale: true)),
                                           status: provider(1, weather: tuesday), today: provider(0, weather: tuesday))
            XCTAssertTrue(fetched.isValid, label)
            let shown = try XCTUnwrap(shownEntry(fetched, at: date(15, 7, 45)), label)
            XCTAssertTrue(shown.isToday, label)
            XCTAssertEqual(shown.expectedRingDate, oldRing, label)
            XCTAssertEqual(shown.forecast, Builder.forecast(from: tuesday.snapshot), label)
            XCTAssertEqual(shown.weatherNotice, .stale, label)
            XCTAssertTrue(TomorrowWidgetPresentation(.status(shown)).showsWeatherColumn, label)
        }
    }

    /// A weekly registration made inside today's check window (07:10, past the 07:00 check
    /// point) decides Wednesday; when Wednesday is dry its repeat still rings today at 07:30.
    func testWeeklyRegistrationForALaterMorningStillRingsTodaysSlot() throws {
        let value = settings()
        let now = date(15, 7, 10)
        for (ring, ringsToday) in [(date(16, 7, 30), true), (date(16, 7), false)] {
            let registered = summary(normal: date(16, 7, 30), ring: ring)
            let today = statusProvider(value, weather: nil, summary: registered, dayOffset: 0)
            let snapshot = Builder.snapshot(now: now, context: context(value, summary: registered),
                                            status: statusProvider(value, weather: nil, summary: registered), today: today)
            XCTAssertTrue(snapshot.isValid)
            let first = snapshot.entries[0]
            if ringsToday {
                XCTAssertEqual(today(now).registeredRingDate, date(15, 7, 30))
                XCTAssertTrue(first.isToday)
                XCTAssertEqual(first.day, date(15, 0))
                XCTAssertEqual(first.expectedRingDate, date(15, 7, 30))
                XCTAssertEqual(first.reason, .normal)
                XCTAssertNil(first.scheduleIssue)
                XCTAssertEqual(snapshot.entries[1].validFrom, date(15, 7, 30, 1))
                XCTAssertFalse(snapshot.entries[1].isToday)
                XCTAssertEqual(snapshot.entries[1].day, date(16, 0))
            } else {
                // A rainy Wednesday registers 07:00 weekly, and today's 07:00 has passed: nothing
                // rings today. The status names Wednesday's ring, so the card (still on today
                // until 07:30) flags the mismatch; the widget reads `passedRingDate` and moves on.
                XCTAssertEqual(today(now).registeredRingDate, date(16, 7))
                XCTAssertEqual(today(now).passedRingDate, date(15, 7))
                XCTAssertFalse(today(now).hasRung)
                XCTAssertEqual(Builder.scheduleIssue(for: today(now), flags: .init()), .updateNeeded)
                XCTAssertFalse(first.isToday)
                XCTAssertEqual(first.day, date(16, 0))
            }
        }
    }

    /// After an early ring a relaunch rolls the stored summary's normal date on to the next
    /// morning. An offline re-registration then (a holiday refresh, a rules change) must not
    /// read that rolled morning as the one the forecast decided: it registers the normal time.
    /// The morning that forecast did decide keeps its lead, even offline.
    func testOfflineReRegistrationReusesALeadOnlyForTheMorningItWasDecidedFor() async throws {
        let alarmCalendar = AlarmCalendarSettings.calendar
        let minute = try XCTUnwrap(alarmCalendar.dateInterval(of: .minute, for: Date())).start
        for decidedIsAhead in [false, true] {
            let label = decidedIsAhead ? "decided morning ahead" : "relaunched after its early ring"
            let decided = minute.addingTimeInterval(decidedIsAhead ? 2 * 3_600 : -2 * 3_600)
            var value = CommuteAlarmSettings()
            value.homeAddress = "Home"
            value.workAddress = "Work"
            value.selectedWeekdays = Set(1...7)
            value.alarmTime = decided
            value.rainLeadTimeMinutes = 30
            value.rainProbabilityThreshold = 0.5
            let registered = ScheduledAlarmSummary(
                normalAlarmDate: decided, scheduledAlarmDate: decided.addingTimeInterval(-1_800),
                weatherRefreshDate: decided.addingTimeInterval(-1_800), exceedsRainThreshold: true, leadTimeMinutes: 30,
                rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0.8, decisionNormalAlarmDate: decided)
            let suite = "TomorrowWidgetSnapshotTests-F1-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let encoder = JSONEncoder()
            defaults.set(try encoder.encode(value), forKey: "commuteAlarmSettings")
            defaults.set(try encoder.encode(registered), forKey: "scheduledAlarmSummaryDisplay")
            defaults.set(try encoder.encode(value.scheduleFingerprint(calendar: alarmCalendar)), forKey: "scheduledAlarmFingerprint")

            let scheduler = RecordingScheduler()
            let model = AlarmViewModel(notificationScheduler: scheduler, previewScheduler: QuietPreviews(),
                                       settingsStorage: defaults, membershipEntitlements: { nil })
            let next = decidedIsAhead ? decided : try XCTUnwrap(alarmCalendar.date(byAdding: .day, value: 1, to: decided))
            XCTAssertEqual(model.scheduledAlarmSummary?.normalAlarmDate, next, label)
            func status() -> TomorrowAlarmStatus {
                alarmCalendar.isDateInToday(next) ? model.todayStatus() : model.tomorrowStatus()
            }
            XCTAssertEqual(status().normalAlarmDate, next, label)
            XCTAssertEqual(status().rainLeadIsCarriedOver, !decidedIsAhead, label)

            await model.applyCalendarSettings()

            let registeredRing = try XCTUnwrap(scheduler.rings.last, "\(label): re-registered")
            let summary = try XCTUnwrap(model.scheduledAlarmSummary, label)
            XCTAssertEqual(summary.normalAlarmDate, next, label)
            XCTAssertEqual(summary.decisionNormalAlarmDate, next, label)
            if decidedIsAhead {
                XCTAssertEqual(registeredRing, next.addingTimeInterval(-1_800), "\(label): its own forecast's lead")
                XCTAssertTrue(summary.exceedsRainThreshold, label)
                XCTAssertEqual(status().reason, .rain, label)
            } else {
                XCTAssertEqual(registeredRing, next, "\(label): no forecast decided this morning")
                XCTAssertFalse(summary.exceedsRainThreshold, label)
                XCTAssertEqual(status().reason, .normal, "\(label): not 因雨提早 for a morning no forecast decided")
            }
            XCTAssertFalse(status().rainLeadIsCarriedOver, label)
        }
    }
}

/// ios/widget merged into the 1.8.0 line (2026-10-01): the card's coming morning (ios/main)
/// and the widget's calendar days read one registration the same way.
extension TomorrowWidgetSnapshotTests {
    /// Weekly, decided Monday evening for Tuesday's rain: 07:00 instead of 07:30. At 07:10
    /// the early ring has gone off. However the summary reached the status — rolled as a
    /// pair (the model, card and widget alike), rolled a date at a time (a relaunch), or not
    /// at all (the evening's registration) — the card says 已響鈴 07:00 for Tuesday with
    /// nothing to update, and the widget has moved on to Wednesday's carried-over 07:00.
    func testCardAndWidgetReadOneRolledWeeklySummary() throws {
        let value = settings()
        let registered = summary(normal: date(15, 7, 30), ring: date(15, 7))
        let now = date(15, 7, 10)
        // A dry forecast fetched after the check point: it cannot move a morning that rang.
        let lateDry = record(value, requestedAt: date(15, 7, 5), checkedAt: date(15, 7, 5), probability: 0.1)
        func card(_ summary: ScheduledAlarmSummary) -> TomorrowAlarmStatus {
            TomorrowAlarmStatus.resolve(settings: value, holidays: .init(), weatherRecord: lateDry, weatherRefreshFailed: false,
                                        summary: summary, registeredFingerprint: value.scheduleFingerprint(calendar: calendar),
                                        disasterFeed: nil, disasterSourceFailed: false, now: now, calendar: calendar)
        }
        let pair = registered.rollingForwardAsPair(selectedWeekdays: value.selectedWeekdays, now: now, calendar: calendar)
        XCTAssertEqual(pair.normalAlarmDate, date(16, 7, 30), "The pair roll has moved past Tuesday's ring")
        let relaunch = registered.rollingForward(selectedWeekdays: value.selectedWeekdays, now: now, calendar: calendar)
        XCTAssertEqual(relaunch.normalAlarmDate, date(15, 7, 30))
        XCTAssertEqual(relaunch.scheduledAlarmDate, date(16, 7))
        for (label, input) in [("pair", pair), ("relaunch", relaunch), ("unrolled", registered)] {
            let result = card(input)
            XCTAssertEqual(result.day, date(15, 0), label)
            XCTAssertTrue(result.isToday, label)
            XCTAssertEqual(result.expectedRingDate, date(15, 7), label)
            XCTAssertEqual(result.registeredRingDate, date(15, 7), label)
            XCTAssertEqual(result.reason, .rain, label)
            XCTAssertEqual(result.leadTimeMinutes, 30, label)
            XCTAssertTrue(result.hasRung, label)
            XCTAssertTrue(result.isScheduleVerified, label)
            XCTAssertFalse(result.rainLeadIsCarriedOver, label)
            XCTAssertFalse(result.ringIsNotRegistered, label)
            XCTAssertNil(Builder.scheduleIssue(for: result, flags: .init()), label)
            XCTAssertEqual(Builder.reasonLine(for: result), .rainEarlier(minutes: 30), "\(label): no percentage after the ring")
        }

        // The widget: today's ring is behind it, so no today entry; tomorrow is Wednesday's
        // 07:00, the weekly repeat of Tuesday's rain, which no forecast has decided (D-D).
        let today = statusProvider(value, weather: lateDry, summary: registered, dayOffset: 0)
        let tomorrow = statusProvider(value, weather: lateDry, summary: registered)
        XCTAssertEqual(today(now).passedRingDate, date(15, 7))
        XCTAssertEqual(Builder.todayShownUntil(today(now)), date(15, 7))
        let snapshot = Builder.snapshot(now: now, context: context(value, summary: registered), status: tomorrow, today: today)
        let first = snapshot.entries[0]
        XCTAssertFalse(first.isToday)
        XCTAssertEqual(first.day, date(16, 0))
        XCTAssertEqual(first.expectedRingDate, date(16, 7))
        XCTAssertEqual(first.reasonLine, .awaitingForecast)
        XCTAssertNil(first.scheduleIssue)

        // At Tuesday's normal time the card moves on too, and reads Wednesday as the widget does.
        let moved = statusProvider(value, weather: nil, summary: registered, dayOffset: nil)(date(15, 7, 30))
        XCTAssertEqual(moved.day, date(16, 0))
        XCTAssertFalse(moved.isToday)
        XCTAssertFalse(moved.hasRung)
        XCTAssertEqual(moved.expectedRingDate, date(16, 7))
        XCTAssertTrue(moved.rainLeadIsCarriedOver)
        XCTAssertEqual(moved, tomorrow(date(15, 7, 30)))

        // No app run since: Wednesday's 07:00 repeat of Tuesday's lead has gone off too. The card
        // (on Wednesday until 07:30) reads it as rung, with nothing to update; its line, not the
        // widget's, then says 因雨提早 (ContentView), since no forecast will decide it any more.
        let carriedRang = statusProvider(value, weather: nil, summary: registered, dayOffset: nil)(date(16, 7, 10))
        XCTAssertEqual(carriedRang.day, date(16, 0))
        XCTAssertEqual(carriedRang.expectedRingDate, date(16, 7))
        XCTAssertEqual(carriedRang.registeredRingDate, date(16, 7))
        XCTAssertTrue(carriedRang.hasRung)
        XCTAssertTrue(carriedRang.rainLeadIsCarriedOver)
        XCTAssertNil(Builder.scheduleIssue(for: carriedRang, flags: .init()))
        XCTAssertEqual(carriedRang.passedRingDate, date(16, 7), "The widget has moved on to Thursday")
    }

    /// The master switch reaches the widget: off shows "Alarm Off" under no day and only a
    /// failure to turn off; "only the next alarm" is that morning's line, today and tomorrow.
    func testMasterSwitchReachesTheWidget() throws {
        var off = settings()
        off.isAlarmEnabled = false
        let evening = date(14, 21)
        for flags in [Builder.CardFlags(), .init(requiresAlarmKitReschedule: true, closureScheduleUncertain: true, isScheduleStale: true)] {
            let snapshot = Builder.snapshot(now: evening, context: context(off, summary: nil, flags: flags),
                                            status: statusProvider(off, weather: nil, summary: nil),
                                            today: statusProvider(off, weather: nil, summary: nil, dayOffset: 0))
            XCTAssertTrue(snapshot.isValid)
            XCTAssertTrue(snapshot.entries.allSatisfy { $0.reason == .alarmOff && !$0.isToday && $0.expectedRingDate == nil })
            XCTAssertTrue(snapshot.entries.allSatisfy { $0.reasonLine == .alarmOff && $0.scheduleIssue == nil },
                          "Every other notice is about an alarm the user chose not to have")
        }
        let failed = Builder.snapshot(now: evening, context: context(off, summary: nil, flags: .init(hasSchedulingError: true)),
                                      status: statusProvider(off, weather: nil, summary: nil))
        XCTAssertEqual(failed.entries[0].scheduleIssue, .schedulingFailed, "Alarms left behind after turning off")
        XCTAssertEqual(TomorrowWidgetPresentation(.status(failed.entries[0])).hero, .off)

        // Only Tuesday off: Monday evening says so about tomorrow, Tuesday after midnight about
        // today until its normal time, then Wednesday rings as usual.
        var once = settings()
        once.skippedAlarmDay = "2026-09-15"
        let snapshot = Builder.snapshot(now: evening, context: context(once, summary: nil),
                                        status: statusProvider(once, weather: nil, summary: nil),
                                        today: statusProvider(once, weather: nil, summary: nil, dayOffset: 0))
        XCTAssertEqual(snapshot.entries.map(\.validFrom), [evening, date(15, 0), date(15, 7, 30, 1)])
        XCTAssertEqual(snapshot.entries.map(\.isToday), [false, true, false])
        XCTAssertEqual(snapshot.entries.map(\.reason), [.skippedOnce, .skippedOnce, .normal])
        XCTAssertEqual(snapshot.entries[1].reasonLine, .skippedOnce)
        XCTAssertNil(snapshot.entries[1].expectedRingDate)
        XCTAssertEqual(snapshot.entries[2].expectedRingDate, date(16, 7, 30))
    }

    /// Off warns only when turning off fails (2026-10-01). The card still fetches the coming
    /// morning while it is on screen, so a forecast can age past 3 h or fail while off: that
    /// must not put an orange badge on 鬧鐘已關閉 (merge review).
    func testAlarmOffCarriesNoWeatherWarning() {
        var off = settings()
        off.isAlarmEnabled = false
        let evening = date(14, 21)
        let old = record(off, requestedAt: evening, checkedAt: date(14, 17))
        for failed in [false, true] {
            let snapshot = Builder.snapshot(now: evening, context: context(off, summary: nil),
                                            status: statusProvider(off, weather: old, summary: nil,
                                                                   failedRequest: failed ? old.request : nil),
                                            today: statusProvider(off, weather: old, summary: nil, dayOffset: 0))
            XCTAssertTrue(snapshot.isValid)
            XCTAssertNotNil(snapshot.entries[0].forecast, "The medium's column still shows the weather it has")
            for entry in snapshot.entries {
                let label = "failed \(failed) at \(entry.validFrom)"
                XCTAssertEqual(entry.reason, .alarmOff, label)
                XCTAssertNotEqual(entry.weatherNotice, .stale, label)
                XCTAssertNotEqual(entry.weatherNotice, .failed, label)
                let presentation = TomorrowWidgetPresentation(.status(entry), language: "zh-Hant")
                XCTAssertEqual(presentation.hero, .off, label)
                XCTAssertFalse(presentation.showsWarningBadge, label)
                XCTAssertFalse(presentation.line?.isWarning ?? false, label)
            }
        }
        // The same weather with the alarm on still warns (D-B).
        let on = Builder.snapshot(now: evening, context: context(settings(), summary: nil),
                                  status: statusProvider(settings(), weather: record(settings(), requestedAt: evening,
                                                                                     checkedAt: date(14, 17)), summary: nil))
        XCTAssertEqual(on.entries[0].weatherNotice, .stale)
    }

    /// DAYOFF-SPEC §7 (merge review 2026-10-01): a closure entry carries the closure feed's
    /// own update time, as the card prints it beside the source. Nothing else carries it.
    func testAClosureEntryCarriesTheSourcesOwnTime() {
        var closureContext = context(settings(), summary: nil)
        closureContext.closureSourceUpdatedAt = date(14, 17, 5)
        let closure = Builder.entry(for: status(reason: .disaster), context: closureContext, validFrom: date(14, 21))
        XCTAssertEqual(closure.closureSourceUpdatedAt, date(14, 17, 5))
        XCTAssertEqual(TomorrowWidgetPresentation(.status(closure)).closureSource, .init(updatedAt: date(14, 17, 5)))
        let today = Builder.entry(for: status(reason: .disaster), context: closureContext, validFrom: date(15, 1), isToday: true)
        XCTAssertEqual(today.closureSourceUpdatedAt, date(14, 17, 5))
        let others: [TomorrowAlarmStatus.Reason] = [.normal, .rain, .holiday, .manual, .weekend, .unselectedWeekday,
                                                    .routeIncomplete, .alarmOff, .skippedOnce]
        for reason in others {
            let entry = Builder.entry(for: status(reason: reason), context: closureContext, validFrom: date(14, 21))
            XCTAssertNil(entry.closureSourceUpdatedAt, "\(reason)")
            XCTAssertNil(TomorrowWidgetPresentation(.status(entry)).closureSource, "\(reason)")
        }
        closureContext.closureSourceUpdatedAt = nil
        let untimed = Builder.entry(for: status(reason: .disaster), context: closureContext, validFrom: date(14, 21))
        XCTAssertEqual(TomorrowWidgetPresentation(.status(untimed)).closureSource, .init(updatedAt: nil),
                       "Without a time from the feed the source is still named")
    }

    /// ios/main's card rules, now the builder's: a committed schedule missing an expected ring
    /// needs an update, and after the ring the rain line never prints a percentage.
    func testCardRulesOfTheComingMorningLiveInTheBuilder() {
        var missing = status(reason: .normal, expected: date(16, 7, 30))
        missing.isMissingFromPlan = true
        XCTAssertTrue(missing.ringIsNotRegistered)
        XCTAssertEqual(Builder.scheduleIssue(for: missing, flags: .init()), .updateNeeded)
        XCTAssertNil(Builder.scheduleIssue(for: missing, flags: .init(isScheduling: true)))
        var skipped = status(reason: .normal, expected: date(16, 7, 30))
        skipped.hasCommittedClosureSkip = true
        XCTAssertEqual(Builder.scheduleIssue(for: skipped, flags: .init()), .updateNeeded)
        var off = status(reason: .alarmOff)
        off.isMissingFromPlan = true
        XCTAssertNil(Builder.scheduleIssue(for: off, flags: .init(isScheduleStale: true)))

        let fresh = weatherSnapshot([0.8])
        var rang = status(reason: .rain, expected: date(16, 7), weather: fresh, lead: 30)
        XCTAssertEqual(Builder.reasonLine(for: rang), .rainForecast(percent: 80, minutes: 30))
        rang.hasRung = true
        XCTAssertEqual(Builder.reasonLine(for: rang), .rainEarlier(minutes: 30))
    }
}

/// Owner 2026-10-02: the medium widget shows the weather column on today's entries too, from
/// midnight until the alarm rings. The forecast is the coming morning's (`dayOffset` nil), which
/// after midnight IS today's; request equality pins it to that morning, route and lead.
extension TomorrowWidgetSnapshotTests {
    /// The owner's report: at 04:00 the medium said 今天 · 10月2日 上午7:30 照常響鈴 with no weather.
    /// The dry forecast fetched the evening before is that morning's: at 04:00 the column shows
    /// it with its time (預報時間, owner 2026-10-02: expected, not a warning); a failed refresh for
    /// it says so from midnight, worded 今天.
    func testTodayEntryShowsTheEveningsForecastAndItsAge() throws {
        let evening = date(14, 21)
        let value = settings()
        let dry = record(value, requestedAt: evening, checkedAt: evening, probability: 0.1)
        let registered = summary(normal: date(15, 7, 30), ring: date(15, 7, 30))
        for failed in [false, true] {
            let failedRequest = failed ? dry.request : nil
            let snapshot = Builder.snapshot(
                now: evening, context: context(value, summary: registered),
                status: statusProvider(value, weather: dry, summary: registered, failedRequest: failedRequest),
                today: statusProvider(value, weather: dry, summary: registered, failedRequest: failedRequest, dayOffset: 0))
            XCTAssertTrue(snapshot.isValid)
            let label = failed ? "failed" : "stale"
            let shown = try XCTUnwrap(shownEntry(snapshot, at: date(15, 4)), label)
            XCTAssertTrue(shown.isToday, label)
            XCTAssertEqual(shown.expectedRingDate, date(15, 7, 30), label)
            XCTAssertEqual(shown.forecast, Builder.forecast(from: dry.snapshot), label)
            XCTAssertEqual(shown.weatherNotice, failed ? .failed : .stale, label)
            let face = TomorrowWidgetPresentation(.status(shown), language: "zh-Hant")
            XCTAssertEqual(face.line, .ringsAsUsual, "\(label): small and Lock Screen as in build 38")
            XCTAssertFalse(face.showsWarningBadge, label)
            XCTAssertTrue(face.showsWeatherColumn, label)
            XCTAssertEqual(face.weatherColumnNotice, failed ? .todayNotice(.failed) : nil, label)
            XCTAssertEqual(face.mediumLine, .ringsAsUsual, label)
            if failed {
                XCTAssertEqual(face.weatherColumnNotice?.full.key, "ux_today_weather_failed")
                XCTAssertEqual(face.weatherColumnFooter, face.weatherColumnNotice?.full, label)
                XCTAssertEqual(entry(snapshot, at: date(15, 0))?.weatherNotice, .failed, "From midnight, not by age")
            } else {
                XCTAssertEqual(face.weatherColumnFooter,
                               LocalizedLine(key: "widget_forecast_as_of", arguments: [.time(evening, .twelveHour)]),
                               "預報時間 下午 9:00")
            }
        }
    }

    /// After midnight the app fetches today's forecast (on its Alarm page, or from the background),
    /// and the publish that follows carries it into today's column: the decision reads it for
    /// half an hour, the column shows it until the ring.
    func testAfterMidnightRefreshFeedsTodaysColumn() throws {
        let now = date(15, 4)
        let value = settings()
        let registered = summary(normal: date(15, 7, 30), ring: date(15, 7))
        let fetched = record(value, requestedAt: now, checkedAt: now)
        let snapshot = Builder.snapshot(now: now, context: context(value, summary: registered),
                                        status: statusProvider(value, weather: fetched, summary: registered),
                                        today: statusProvider(value, weather: fetched, summary: registered, dayOffset: 0))
        XCTAssertTrue(snapshot.isValid)
        XCTAssertEqual(Array(snapshot.entries.prefix(3).map(\.validFrom)), [now, date(15, 4, 30, 1), date(15, 7, 0, 1)])
        XCTAssertEqual(Array(snapshot.entries.prefix(3).map(\.isToday)), [true, true, false], "Today runs to the 07:00 ring")

        let first = snapshot.entries[0]
        XCTAssertEqual(first.forecast, Builder.forecast(from: fetched.snapshot))
        XCTAssertNil(first.weatherNotice)
        XCTAssertEqual(first.expectedRingDate, date(15, 7))
        XCTAssertEqual(first.reasonLine, .rainForecast(percent: 80, minutes: 30))
        let face = TomorrowWidgetPresentation(.status(first), language: "zh-Hant")
        XCTAssertEqual(face.mediumLine, .todayReason(.rainForecast(percent: 80, minutes: 30)), "Beside the  Weather mark")
        XCTAssertEqual(face.line, .todayReason(.rainEarlier(minutes: 30)), "Every other face: the decision, no percentage (D-A)")
        XCTAssertTrue(face.showsWeatherColumn)
        XCTAssertNil(face.weatherColumnNotice, "天氣更新於 上午4:00")
        XCTAssertEqual(face.home, .rain)

        let decided = snapshot.entries[1]
        XCTAssertTrue(decided.isToday)
        XCTAssertEqual(decided.reasonLine, .rainEarlier(minutes: 30), "Half an hour old: the decision stops reading it")
        XCTAssertEqual(decided.forecast, first.forecast)
        XCTAssertNil(decided.weatherNotice, "The widget warns only after 3 hours (D-B)")
        XCTAssertEqual(decided.expectedRingDate, date(15, 7))
        let after = snapshot.entries[2]
        XCTAssertEqual(after.day, date(16, 0))
        XCTAssertNil(after.forecast, "Wednesday's forecast is not fetched until Tuesday's normal time")
    }

    /// A today entry only ever shows its own morning's forecast: never the day before's, and
    /// never one fetched for another lead, address or commute mode.
    func testTodayNeverShowsAnotherMorningsForecast() throws {
        let value = settings()
        // Monday 06:00: the coming morning is Monday's, and so is the forecast.
        let monday = date(14, 6)
        let mondayRegistration = summary(normal: date(14, 7, 30), ring: date(14, 7))
        let mondays = record(value, requestedAt: monday, checkedAt: monday)
        XCTAssertEqual(mondays.request.normalAlarmDate, date(14, 7, 30))
        let snapshot = Builder.snapshot(now: monday, context: context(value, summary: mondayRegistration),
                                        status: statusProvider(value, weather: mondays, summary: mondayRegistration),
                                        today: statusProvider(value, weather: mondays, summary: mondayRegistration, dayOffset: 0))
        XCTAssertTrue(snapshot.isValid)
        XCTAssertTrue(snapshot.entries[0].isToday)
        XCTAssertEqual(snapshot.entries[0].day, date(14, 0))
        XCTAssertEqual(snapshot.entries[0].forecast, Builder.forecast(from: mondays.snapshot))
        for entry in snapshot.entries where entry.day != date(14, 0) {
            XCTAssertNil(entry.forecast, "\(entry.validFrom): Monday's forecast shown for \(entry.day)")
        }
        let tuesday = try XCTUnwrap(snapshot.entries.first { $0.isToday && $0.day == date(15, 0) })
        XCTAssertEqual(tuesday.validFrom, date(15, 0))
        XCTAssertNil(tuesday.forecast)
        XCTAssertEqual(tuesday.weatherNotice, .noForecast)

        // A forecast made under another lead, home address or commute mode is another request's.
        var otherLead = value
        otherLead.rainLeadTimeMinutes = 45
        var otherHome = value
        otherHome.homeAddress = "Elsewhere"
        var otherMode = value
        otherMode.commuteMode = .walking
        let evening = date(14, 21)
        let registered = summary(normal: date(15, 7, 30), ring: date(15, 7))
        for (label, other) in [("lead", otherLead), ("home", otherHome), ("mode", otherMode)] {
            let foreign = record(other, requestedAt: evening, checkedAt: evening)
            let published = Builder.snapshot(now: evening, context: context(value, summary: registered),
                                             status: statusProvider(value, weather: foreign, summary: registered),
                                             today: statusProvider(value, weather: foreign, summary: registered, dayOffset: 0))
            XCTAssertTrue(published.isValid, label)
            XCTAssertTrue(published.entries.contains { $0.isToday }, label)
            XCTAssertTrue(published.entries.allSatisfy { $0.forecast == nil }, label)
        }
    }

    /// D-B on every entry, today's included: an entry that shows a forecast without a warning
    /// never outlives that forecast's 3 hours, because the stale second is always a boundary.
    func testNoForecastIsSilentlyStale() {
        let value = settings()
        let weekly = summary(normal: date(15, 7, 30), ring: date(15, 7))
        for publish in [date(14, 18), date(14, 21), date(14, 23, 59), date(15, 3), date(15, 6, 50)] {
            let ages: [TimeInterval] = [0, 3_600, 2 * 3_600 + 50 * 60, 5 * 3_600]
            for age in ages {
                for plan in [weekly, nil] as [ScheduledAlarmSummary?] {
                    let weather = record(value, requestedAt: publish, checkedAt: publish.addingTimeInterval(-age))
                    let snapshot = Builder.snapshot(now: publish, context: context(value, summary: plan),
                                                    status: statusProvider(value, weather: weather, summary: plan),
                                                    today: statusProvider(value, weather: weather, summary: plan, dayOffset: 0))
                    let label = "published \(publish), \(Int(age)) s old, registered \(plan != nil)"
                    XCTAssertTrue(snapshot.isValid, label)
                    XCTAssertTrue(snapshot.entries.contains { $0.isToday && $0.forecast != nil }, label)
                    for (index, entry) in snapshot.entries.enumerated() {
                        guard let forecast = entry.forecast, entry.weatherNotice != .stale, entry.weatherNotice != .failed else {
                            continue
                        }
                        let end = index + 1 < snapshot.entries.count ? snapshot.entries[index + 1].validFrom : snapshot.expiresAt
                        XCTAssertLessThanOrEqual(end.timeIntervalSince(forecast.checkedAt),
                                                 Builder.widgetWeatherLifetime + Builder.epsilon,
                                                 "\(label): \(entry.validFrom) shows it unwarned for too long")
                    }
                }
            }
        }
    }

    /// A failed refresh of today's forecast names today in the medium's column (the app's own
    /// 今天天氣更新失敗) and keeps the last good forecast; the small and Lock Screen faces and the
    /// badge are as in build 38.
    func testTodayFailureNamesToday() throws {
        let (snapshot, _, _) = mondayEveningWithToday(failed: true)
        XCTAssertTrue(snapshot.isValid)
        let todays = snapshot.entries.filter(\.isToday)
        XCTAssertFalse(todays.isEmpty)
        for entry in todays {
            XCTAssertEqual(entry.weatherNotice, .failed, "\(entry.validFrom): at once, not by age")
            XCTAssertEqual(entry.forecast, Builder.forecast(from: mondayEveningRecord().snapshot), "The last good forecast stays")
            let face = TomorrowWidgetPresentation(.status(entry), language: "zh-Hant")
            XCTAssertEqual(face.weatherColumnNotice, .todayNotice(.failed))
            XCTAssertEqual(face.weatherColumnNotice?.full.key, "ux_today_weather_failed", "Not 明天天氣更新失敗")
            XCTAssertEqual(face.line, .todayReason(.rainEarlier(minutes: 30)))
            XCTAssertFalse(face.showsWarningBadge)
        }
        // The evening before, the same failure is tomorrow's, worded 明天 as before.
        XCTAssertFalse(snapshot.entries[0].isToday)
        XCTAssertEqual(snapshot.entries[0].weatherNotice, .failed)
        XCTAssertEqual(TomorrowWidgetPresentation(.status(snapshot.entries[0])).weatherColumnNotice, .notice(.failed))
    }

    /// The today path is the tomorrow path for that morning: the same forecast, notice and
    /// decision, only named 今天, wherever the morning has not reached its normal time or still
    /// has a forecast. (An outdated or kept registration's ring is shown instead on a today
    /// entry, and past the normal time without a forecast a today entry has no notice.)
    func testTodayEntryIsTheTomorrowRuleForItsMorning() {
        let weekly = summary(normal: date(15, 7, 30), ring: date(15, 7))
        let weather = mondayEveningRecord()
        var off = settings()
        off.isAlarmEnabled = false
        let cases: [(String, CommuteAlarmSettings, TomorrowWeatherRecord?, ScheduledAlarmSummary?, Bool)] = [
            ("forecast", settings(), weather, weekly, false),
            ("failed", settings(), weather, weekly, true),
            ("none", settings(), nil, weekly, false),
            ("unregistered", settings(), weather, nil, false),
            ("no route", settings(home: ""), nil, nil, false),
            ("off", off, weather, nil, false),
        ]
        for (label, value, record, plan, failed) in cases {
            let context = context(value, summary: plan)
            let today = statusProvider(value, weather: record, summary: plan,
                                       failedRequest: failed ? record?.request : nil, dayOffset: 0)
            var checked = 0
            for step in 0...50 {
                let moment = date(15, 0).addingTimeInterval(Double(step) * 600)
                let status = today(moment)
                guard status.outdatedRegistrationRingDate == nil, status.keptRingDate == nil,
                      moment <= status.normalAlarmDate || status.weather != nil else { continue }
                var asToday = Builder.entry(for: status, context: context, validFrom: moment, isToday: true)
                let asTomorrow = Builder.entry(for: status, context: context, validFrom: moment, isToday: false)
                XCTAssertTrue(asToday.isToday, label)
                asToday.isToday = false
                XCTAssertEqual(asToday, asTomorrow, "\(label) at \(moment)")
                checked += 1
            }
            XCTAssertGreaterThan(checked, 40, label)
        }
    }

    /// Build 38 stored every today entry without a forecast, and with no notice except
    /// "complete your route" (its rule: `status.weather == nil && addressesMissing`). For a
    /// route-incomplete user 39 writes exactly that entry, so a 38 snapshot draws on 39 as
    /// 39's own publish will: the medium's column with 請完成路線 over endpoints —, as on the
    /// tomorrow entry after it, where 38 drew today full width. Nothing changes when the app
    /// republishes, and the column does not appear when today's entry gives way to tomorrow's.
    func testRouteIncompleteTodayEntryIsWhatBuild38Stored() throws {
        var skipped = settings(home: "")
        skipped.selectedWeekdays = [1, 2, 4, 5, 6, 7]                    // not Tuesday
        let cases: [(String, CommuteAlarmSettings)] = [
            ("no home", settings(home: "")), ("blank work", settings(work: "  ")), ("skipped, no home", skipped)]
        for (name, value) in cases {
            for publish in [date(14, 21), date(15, 3)] {
                let label = "\(name), published \(publish)"
                let snapshot = Builder.snapshot(now: publish, context: context(value, summary: nil),
                                                status: statusProvider(value, weather: nil, summary: nil),
                                                today: statusProvider(value, weather: nil, summary: nil, dayOffset: 0))
                XCTAssertTrue(snapshot.isValid, label)
                let todays = snapshot.entries.filter { $0.isToday && $0.day == date(15, 0) }
                XCTAssertFalse(todays.isEmpty, label)
                for entry in todays {
                    var asBuild38Stored = entry
                    asBuild38Stored.forecast = nil
                    asBuild38Stored.weatherNotice = .routeNeeded
                    XCTAssertEqual(entry, asBuild38Stored, "\(label) at \(entry.validFrom)")
                    let face = TomorrowWidgetPresentation(.status(entry), language: "zh-Hant")
                    XCTAssertTrue(face.showsWeatherColumn, label)
                    XCTAssertEqual(face.weatherColumnNotice, .todayNotice(.routeNeeded), label)
                    XCTAssertEqual(face.weatherColumnNotice?.full.key, "ux_route_needed", label)
                    XCTAssertNil(face.home, "\(label): endpoints —")
                    XCTAssertNil(face.work, label)
                    XCTAssertNotEqual(face.mediumLine?.full, face.weatherColumnNotice?.full, "\(label): said once")
                    if entry.reason == .routeIncomplete {
                        XCTAssertEqual(face.line, .todayReason(.routeNeeded), "\(label): small and Lock Screen as in 38")
                        XCTAssertNil(face.mediumLine, label)
                    } else {
                        XCTAssertEqual(entry.reason, .unselectedWeekday, label)
                        XCTAssertEqual(face.line, .todayReason(.unselectedWeekday), label)
                        XCTAssertEqual(face.mediumLine, .todayReason(.unselectedWeekday), label)
                    }
                }
                let tomorrow = try XCTUnwrap(snapshot.entries.first { !$0.isToday && $0.day == date(16, 0) }, label)
                let tomorrowFace = TomorrowWidgetPresentation(.status(tomorrow), language: "zh-Hant")
                XCTAssertTrue(tomorrowFace.showsWeatherColumn, label)
                XCTAssertEqual(tomorrowFace.weatherColumnNotice?.full,
                               TomorrowWidgetPresentation.Line.todayNotice(.routeNeeded).full, "\(label): the same column")
            }
        }
    }

    // MARK: Today's forecast past 3 hours (owner, 2026-10-02)

    /// Owner 2026-10-02, on a snapshot published the evening before (the app need not be awake
    /// after midnight): a forecast checked at 22:00 reads 天氣更新於 22:00 on tomorrow's entry and,
    /// from midnight, on today's, until it is 3 hours old; from the next second (01:00:01, D-B's
    /// strict >) today's column gives 預報時間 22:00 instead, neutral, through the ring. The time
    /// follows the snapshot's 12/24-hour setting, and VoiceOver reads the same line.
    func testTodaysColumnTurnsToTheForecastTimeAtThreeHours() throws {
        let evening = date(14, 22)
        let value = settings()
        let dry = record(value, requestedAt: evening, checkedAt: evening, probability: 0.1)
        let registered = summary(normal: date(15, 7, 30), ring: date(15, 7, 30))
        let zh = try WidgetStringTable("zh-Hant")
        let en = try WidgetStringTable("en")
        for clock in ClockTimeFormat.allCases {
            let snapshot = Builder.snapshot(now: evening, context: context(value, summary: registered, clock: clock),
                                            status: statusProvider(value, weather: dry, summary: registered),
                                            today: statusProvider(value, weather: dry, summary: registered, dayOffset: 0))
            XCTAssertTrue(snapshot.isValid, "\(clock)")
            XCTAssertEqual(snapshot.clockFormat, clock)
            XCTAssertEqual(entry(snapshot, at: date(15, 1, 0, 1))?.weatherNotice, .stale, "\(clock): the stale second is precomputed")
            let twentyFour = clock == .twentyFourHour
            let checked = twentyFour ? ("天氣更新於 22:00", "Weather checked 22:00") : ("天氣更新於 下午 10:00", "Weather checked 10:00 PM")
            let asOf = twentyFour ? ("預報時間 22:00", "Forecast as of 22:00") : ("預報時間 下午 10:00", "Forecast as of 10:00 PM")
            let moments: [(Date, Bool, (String, String))] = [
                (date(14, 23), false, checked), (date(15, 0), true, checked), (date(15, 1), true, checked),
                (date(15, 1, 0, 1), true, asOf), (date(15, 4), true, asOf), (date(15, 7, 30), true, asOf),
            ]
            for (moment, isToday, (chinese, english)) in moments {
                let label = "\(clock) at \(moment)"
                let shown = try XCTUnwrap(shownEntry(snapshot, at: moment), label)
                XCTAssertEqual(shown.isToday, isToday, label)
                XCTAssertEqual(shown.forecast, Builder.forecast(from: dry.snapshot), label)
                let face = TomorrowWidgetPresentation(.status(shown), clockFormat: snapshot.clockFormat, language: "zh-Hant")
                XCTAssertTrue(face.showsWeatherColumn, label)
                XCTAssertNil(face.weatherColumnNotice, "\(label): no ⚠, no warning text")
                XCTAssertEqual(face.weatherColumnFooter.map { zh.text($0, timeZone: calendar.timeZone) }, chinese, label)
                XCTAssertEqual(face.weatherColumnFooter.map { en.text($0, timeZone: calendar.timeZone) }, english, label)
                XCTAssertFalse(face.showsWarningBadge, label)
                XCTAssertEqual(face.line, .ringsAsUsual, label)
                let spoken = face.weatherColumnAccessibilityLabel(forecast: shown.forecast, separator: "，",
                                                                  text: { zh.text($0, timeZone: calendar.timeZone) })
                XCTAssertTrue(spoken.hasSuffix("，\(chinese)，Apple Weather"), "\(label): \(spoken)")
            }
            // One second after the ring: Wednesday, whose forecast the app has not fetched.
            let after = try XCTUnwrap(shownEntry(snapshot, at: date(15, 7, 30, 1)))
            XCTAssertFalse(after.isToday, "\(clock)")
            XCTAssertNil(after.forecast, "\(clock)")
        }
    }

    /// The same forecast is tomorrow's warning in the evening and today's neutral time after
    /// midnight. Checked at 18:00, it is stale from 21:00:01 on tomorrow's entry (D-B, unchanged:
    /// ⚠ 天氣資料需要更新 in the column, and on the small and Lock Screen faces); from midnight,
    /// when the entry is today's, the column says 預報時間 18:00 and nothing warns.
    func testTomorrowsStaleWarningGivesWayToTodaysForecastTimeAtMidnight() throws {
        let afternoon = date(14, 18)
        let value = settings()
        let dry = record(value, requestedAt: afternoon, checkedAt: afternoon, probability: 0.1)
        let registered = summary(normal: date(15, 7, 30), ring: date(15, 7, 30))
        let snapshot = Builder.snapshot(now: afternoon, context: context(value, summary: registered, clock: .twentyFourHour),
                                        status: statusProvider(value, weather: dry, summary: registered),
                                        today: statusProvider(value, weather: dry, summary: registered, dayOffset: 0))
        XCTAssertTrue(snapshot.isValid)
        let zh = try WidgetStringTable("zh-Hant")
        func shown(at moment: Date) throws -> (TomorrowWidgetSnapshot.Entry, TomorrowWidgetPresentation) {
            let entry = try XCTUnwrap(shownEntry(snapshot, at: moment), "\(moment)")
            return (entry, TomorrowWidgetPresentation(.status(entry), clockFormat: snapshot.clockFormat, language: "zh-Hant"))
        }
        func footer(_ face: TomorrowWidgetPresentation) -> String? {
            face.weatherColumnFooter.map { zh.text($0, timeZone: calendar.timeZone) }
        }

        let (fresh, freshFace) = try shown(at: date(14, 21))
        XCTAssertFalse(fresh.isToday)
        XCTAssertNil(fresh.weatherNotice, "Exactly 3 hours: not yet (strict >)")
        XCTAssertEqual(footer(freshFace), "天氣更新於 18:00")

        for moment in [date(14, 21, 0, 1), date(14, 23, 59, 59)] {
            let (warned, face) = try shown(at: moment)
            XCTAssertFalse(warned.isToday, "\(moment)")
            XCTAssertEqual(warned.weatherNotice, .stale, "\(moment)")
            XCTAssertEqual(face.weatherColumnNotice, .notice(.stale), "\(moment)")
            XCTAssertEqual(face.weatherColumnNotice?.leadingSymbol, TomorrowWidgetPresentation.Glyph.warning.rawValue)
            XCTAssertEqual(footer(face), "天氣資料需要更新", "\(moment)")
            XCTAssertEqual(face.line, .notice(.stale), "\(moment): tomorrow's small and Lock Screen faces warn, as before")
        }

        for moment in [date(15, 0), date(15, 4), date(15, 7, 30)] {
            let (today, face) = try shown(at: moment)
            XCTAssertTrue(today.isToday, "\(moment)")
            XCTAssertEqual(today.weatherNotice, .stale, "\(moment): the snapshot still marks its age")
            XCTAssertEqual(today.forecast, Builder.forecast(from: dry.snapshot), "\(moment)")
            XCTAssertNil(face.weatherColumnNotice, "\(moment)")
            XCTAssertEqual(footer(face), "預報時間 18:00", "\(moment)")
            XCTAssertEqual(face.line, .ringsAsUsual, "\(moment)")
            XCTAssertFalse(face.showsWarningBadge, "\(moment)")
        }
    }
}

@MainActor
private final class ReloadCounter {
    var count = 0
}

private final class SilentScheduler: NotificationScheduling, @unchecked Sendable {
    func requestAuthorization() async throws -> Bool { true }
    func scheduleAlarm(at date: Date, normalAlarmDate: Date, weekdays: Set<Int>, sound: CommuteAlarmSettings.AlarmSound,
                       soundFileNameOverride: String?, snoozeMinutes: Int?, title: String, body: String) async throws {}
    func cancelScheduledAlarms() async {}
}

/// Records each weekly registration's ring time.
private final class RecordingScheduler: NotificationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Date] = []
    var rings: [Date] { lock.withLock { recorded } }
    func requestAuthorization() async throws -> Bool { true }
    func scheduleAlarm(at date: Date, normalAlarmDate: Date, weekdays: Set<Int>, sound: CommuteAlarmSettings.AlarmSound,
                       soundFileNameOverride: String?, snoozeMinutes: Int?, title: String, body: String) async throws {
        lock.withLock { recorded.append(date) }
    }
    func cancelScheduledAlarms() async {}
}

private struct QuietPreviews: EveningPreviewScheduling {
    func authorizationStatus() async -> EveningPreviewAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func replacePreviews(_ previews: [EveningPreview]) async {}
    func cancelPreviews() async {}
    func showSample(_ preview: EveningPreview) async {}
    func notifyDecisionChange(_ change: AlarmDecisionChange) async {}
}

/// D-A: the medium widget's  Weather mark and its link to Apple's legal page.
final class WeatherAttributionMarkTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WeatherAttributionMarkTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x42, count: 64))

    func testStoreKeepsOnlyBoundedPNGsPerVariant() {
        let store = WeatherAttributionMarkStore(directory: directory)
        let now = Date()
        // White glyphs: accented and clear rendering map luminance to alpha, which would erase
        // the light variant's black ones; full colour draws on the dark sky anyway.
        XCTAssertEqual(WeatherAttributionMarkStore.widgetVariant, .dark)
        XCTAssertNil(store.data(for: .dark))
        XCTAssertTrue(store.needsRefresh(now: now, maximumAge: 60), "Nothing downloaded yet")
        XCTAssertTrue(store.save(png, for: .dark, now: now))
        XCTAssertEqual(store.data(for: .dark), png)
        XCTAssertNil(store.data(for: .light))
        XCTAssertFalse(store.needsRefresh(now: now, maximumAge: 60), "Only the variant the widget draws is needed")
        XCTAssertEqual(store.savedAt(.dark)?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertTrue(store.needsRefresh(now: now.addingTimeInterval(120), maximumAge: 60), "Refreshed when old")

        XCTAssertFalse(store.save(Data("<html>Not found</html>".utf8), for: .dark), "An error page is not a mark")
        XCTAssertFalse(store.save(png + Data(count: WeatherAttributionMarkStore.maximumBytes), for: .dark), "Oversized")
        XCTAssertEqual(store.data(for: .dark), png, "A refused download keeps the mark already there")

        // A file that is not a PNG is never drawn (the widget falls back to the text mark).
        try? Data("junk".utf8).write(to: store.fileURL(for: .dark)!)
        XCTAssertNil(store.data(for: .dark))
        XCTAssertNil(store.savedAt(.dark))
        XCTAssertTrue(store.needsRefresh(now: now, maximumAge: 60))

        // The demo's text-fallback state.
        XCTAssertTrue(store.save(png, for: .dark, now: now))
        store.clear()
        XCTAssertNil(store.data(for: .dark))
        XCTAssertTrue(store.needsRefresh(now: now, maximumAge: 60))

        let unavailable = WeatherAttributionMarkStore(directory: nil)
        XCTAssertFalse(unavailable.save(png, for: .dark))
        XCTAssertNil(unavailable.data(for: .dark))
        XCTAssertTrue(unavailable.needsRefresh(now: now, maximumAge: 60))
    }

    func testTextMarkAndLegalLinkAreWiredToTheApp() throws {
        XCTAssertEqual(WeatherAttributionMarkStore.fallbackText, "\u{F8FF} Weather")
        let link = WeatherAttributionMarkStore.legalLinkURL
        XCTAssertTrue(WeatherAttributionLink.isAttributionLink(link))
        XCTAssertFalse(WeatherAttributionLink.isAttributionLink(URL(string: "rainyclock://settings")!))
        XCTAssertFalse(WeatherAttributionLink.isAttributionLink(URL(string: "https://weather-attribution/")!))
        // The app claims the scheme, so the widget's link lands in its onOpenURL.
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains(try XCTUnwrap(link.scheme)))
        XCTAssertEqual(WeatherAttributionLink.fallbackLegalURL.absoluteString, "https://weatherkit.apple.com/legal-attribution.html")
    }
}
