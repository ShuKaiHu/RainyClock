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

    /// Mirrors `AlarmViewModel.tomorrowStatus(now:)` after D1: the summary is rolled at `t`
    /// (ring and normal time as one pair), and the failure flag applies only while the
    /// failed request is still tomorrow's.
    /// `dayOffset: 0` mirrors `AlarmViewModel.todayStatus(now:)` the same way.
    private func statusProvider(_ settings: CommuteAlarmSettings, weather: TomorrowWeatherRecord?,
                                summary: ScheduledAlarmSummary?, failedRequest: TomorrowWeatherRequest? = nil,
                                dayOffset: Int = 1, calendar: Calendar? = nil)
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

        // Every reason maps, and to its own snapshot reason.
        let context = context(settings(), summary: nil)
        let pairs: [(TomorrowAlarmStatus.Reason, Snapshot.Reason)] = [
            (.normal, .normal), (.rain, .rain), (.holiday, .holiday), (.manual, .manual), (.weekend, .weekend),
            (.unselectedWeekday, .unselectedWeekday), (.disaster, .disaster), (.routeIncomplete, .routeIncomplete)]
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
        for reason in [TomorrowAlarmStatus.Reason.normal, .rain, .manual, .weekend, .unselectedWeekday, .disaster, .routeIncomplete] {
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

    /// Monday 21:00 as in `mondayEvening`, with the today provider the app passes.
    private func mondayEveningWithToday() -> (Snapshot, (Date) -> TomorrowAlarmStatus, (Date) -> TomorrowAlarmStatus) {
        let now = date(14, 21)
        let value = settings()
        let weather = record(value, requestedAt: now, checkedAt: now)
        let registered = summary(normal: date(15, 7, 30), ring: date(15, 7))
        let tomorrow = statusProvider(value, weather: weather, summary: registered)
        let today = statusProvider(value, weather: weather, summary: registered, dayOffset: 0)
        return (Builder.snapshot(now: now, context: context(value, summary: registered), status: tomorrow, today: today),
                tomorrow, today)
    }

    func testTodayRainEntryRunsFromMidnightThroughItsRing() throws {
        let (snapshot, tomorrow, _) = mondayEveningWithToday()
        XCTAssertTrue(snapshot.isValid)
        XCTAssertEqual(snapshot.entries.map(\.validFrom), [date(14, 21), date(14, 21, 30, 1), date(15, 0), date(15, 7, 0, 1)])
        XCTAssertEqual(snapshot.entries.map(\.isToday), [false, false, true, false])
        XCTAssertEqual(snapshot.expiresAt, date(16, 0))

        // Midnight: still Tuesday's 07:00, now called today, with the evening's decision.
        let today = try XCTUnwrap(entry(snapshot, at: date(15, 0)))
        XCTAssertEqual(today.day, date(15, 0))
        XCTAssertEqual(today.normalAlarmDate, date(15, 7, 30))
        XCTAssertEqual(today.expectedRingDate, date(15, 7), "What AlarmKit's registration rings")
        XCTAssertEqual(today.reason, .rain)
        XCTAssertEqual(today.reasonLine, .rainEarlier(minutes: 30), "Decided by Tuesday's forecast: 因雨提早")
        XCTAssertNil(today.weatherNotice, "Nothing can refresh a forecast for a morning that has begun")
        XCTAssertNil(today.scheduleIssue)
        XCTAssertNotNil(today.forecast, "The medium still shows the forecast it was decided on")
        // The card, meanwhile, already describes Wednesday.
        XCTAssertEqual(tomorrow(date(15, 0)).day, date(16, 0))

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
        // A registered date still ahead rolls only once strictly past (07:00:01); a projected
        // weekly repeat already rolls at its own second (`rollingForward`), so Wednesday's
        // today entry hands over at 07:00:00.
        XCTAssertEqual(snapshot.entries.map(\.validFrom), [now, date(15, 7, 0, 1), date(16, 0), date(16, 7)])
        XCTAssertEqual(snapshot.entries.map(\.isToday), [true, false, true, false])

        let first = snapshot.entries[0]
        XCTAssertEqual(first.expectedRingDate, date(15, 7))
        XCTAssertEqual(first.reasonLine, .rainEarlier(minutes: 30))
        XCTAssertNil(first.forecast)
        XCTAssertNil(first.weatherNotice, "Not 尚未取得明天天氣: that names tomorrow")

        // Wednesday before its ring: the same 07:00, but only the weekly repeat of Tuesday's rain.
        let wednesday = try XCTUnwrap(entry(snapshot, at: date(16, 0)))
        XCTAssertEqual(wednesday.day, date(16, 0))
        XCTAssertEqual(wednesday.expectedRingDate, date(16, 7))
        XCTAssertEqual(wednesday.reasonLine, .awaitingForecast)
        XCTAssertFalse(wednesday.appliesRainLead)
        XCTAssertNil(wednesday.scheduleIssue)
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
        XCTAssertNil(saturday.weatherNotice)
        XCTAssertEqual(snapshot.entries[2].day, date(20, 0), "After its normal time: Sunday, as tomorrow")
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
                       "A ring day with no registered ring left has rung")
        XCTAssertEqual(Builder.todayShownUntil(today(expected: normal, registered: nil, current: false)), normal,
                       "Nothing registered: the configured time")
    }

    func testConsumedDatedOccurrenceAndCrossMidnightLeadEndToday() {
        let value = settings()
        // A dated plan re-registered at 07:10, after Tuesday's 07:00 ring: Tuesday is gone from it.
        var plan = summary(normal: date(16, 7, 30), ring: date(16, 7, 30))
        plan.calendarPlan = .init(occurrences: [.init(normalDate: date(16, 7, 30), ringDate: date(16, 7, 30))],
                                  coveredUntil: date(20, 0), timeZoneID: calendar.timeZone.identifier)
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
        XCTAssertEqual(model.scheduledAlarmSummary, registered, "init must not roll a future summary")

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
        XCTAssertEqual(model.tomorrowStatus(now: at(day, 3, 0)).day, next, "The card keeps describing tomorrow")

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
        XCTAssertNil(store.data(for: .dark))
        XCTAssertTrue(store.needsRefresh(now: now, maximumAge: 60), "Nothing downloaded yet")
        XCTAssertTrue(store.save(png, for: .dark, now: now))
        XCTAssertEqual(store.data(for: .dark), png)
        XCTAssertNil(store.data(for: .light))
        XCTAssertTrue(store.needsRefresh(now: now, maximumAge: 60), "Both variants are needed")
        XCTAssertTrue(store.save(png, for: .light, now: now))
        XCTAssertEqual(store.savedAt(.light)?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertFalse(store.needsRefresh(now: now, maximumAge: 60))
        XCTAssertTrue(store.needsRefresh(now: now.addingTimeInterval(120), maximumAge: 60), "Refreshed when old")

        XCTAssertFalse(store.save(Data("<html>Not found</html>".utf8), for: .dark), "An error page is not a mark")
        XCTAssertFalse(store.save(png + Data(count: WeatherAttributionMarkStore.maximumBytes), for: .dark), "Oversized")
        XCTAssertEqual(store.data(for: .dark), png, "A refused download keeps the mark already there")

        // A file that is not a PNG is never drawn (the widget falls back to the text mark).
        try? Data("junk".utf8).write(to: store.fileURL(for: .light)!)
        XCTAssertNil(store.data(for: .light))
        XCTAssertNil(store.savedAt(.light))
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
