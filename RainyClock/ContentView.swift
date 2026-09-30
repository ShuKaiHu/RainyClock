import AVFoundation
import MapKit
import SwiftUI
import UIKit

struct ContentView: View {
    private enum AppTab {
        case alarm
        case settings
    }

    @StateObject var viewModel: AlarmViewModel
    @ObservedObject private var consentManager = ConsentManager.shared
    @ObservedObject private var recentAds = RecentAds.shared
    @ObservedObject private var membership = MembershipManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var selectedTab: AppTab = .alarm
    @State private var settingsRequest: SettingsNavigationRequest?
    var showsWeatherAttribution = false

    var body: some View {
        TabView(selection: $selectedTab) {
            AlarmHomeView(viewModel: viewModel, showsWeatherAttribution: showsWeatherAttribution) { category, anchor in
                settingsRequest = SettingsNavigationRequest(category: category, anchor: anchor)
                selectedTab = .settings
            }
                .tabItem { Label("tab_alarm", systemImage: "alarm") }
                .tag(AppTab.alarm)

            SettingsTabView(viewModel: viewModel, showsWeatherAttribution: showsWeatherAttribution,
                            request: $settingsRequest)
                .tabItem { Label("tab_settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        // Each tab owns a NavigationStack. Page-style hosting can leave one of
        // those stacks off-screen after a push/pop or a keyboard transition.
        // Use normal tab containment while keeping our existing bottom controls.
        .tabViewStyle(.automatic)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomControls
        }
        .background(Color.appBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        // A GDPR user answers once before the first ad request; the same sheet
        // reopens from the Settings tab's privacy row to change the answer later.
        .sheet(isPresented: $consentManager.isConsentSheetPresented, onDismiss: {
            Task { await consentManager.consentSheetDidClose() }
        }) {
            AdConsentSheet()
        }
        .task {
            // Start ATT before work that may need another system permission.
            // Membership verification is not a prerequisite for this prompt.
            await consentManager.requestConsentThenStartAds()
            Task { await membership.start() }
            if !AppEnvironment.isRunningTests { viewModel.activateAutomaticScheduling() }
            Task { await DisasterPushRegistration.shared.update(enabled: viewModel.effectiveSchedulingSettings.isDisasterSuspensionEnabled) }
            // The armed alarm repeats weekly with the rain decision that was current
            // when it was scheduled; opening the app is what brings that decision up
            // to date. No-op when it is still fresh.
            await viewModel.refreshHolidays()
            await viewModel.refreshScheduledAlarmIfWeatherIsStale()
            // After the refresh, so a fresh registration has already planned the
            // previews and this only fires for an install that has never been
            // asked — the upgrade case.
            await viewModel.requestEveningPreviewAuthorizationIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                return
            }

            // Retry a deferred ATT request or failed SDK init on activation.
            Task { await consentManager.requestConsentThenStartAds() }
            Task { await DisasterPushRegistration.shared.update(enabled: viewModel.effectiveSchedulingSettings.isDisasterSuspensionEnabled) }
            Task {
                await viewModel.refreshScheduledAlarmIfWeatherIsStale()
            }
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton(
                    title: String(localized: "tab_alarm"),
                    systemImage: "alarm",
                    tab: .alarm
                )
                tabButton(
                    title: String(localized: "tab_settings"),
                    systemImage: "gearshape",
                    tab: .settings
                )
            }
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color.white.opacity(0.04), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 8)
            .padding(.horizontal, 34)
            .padding(.top, 8)
            .padding(.bottom, 10)

            // Kept out of the hierarchy until consent is settled and LevelPlay
            // has finished initialising, so no ad request can precede either.
            if !AppEnvironment.isRunningTests, consentManager.canRequestAds, !membership.entitlements.removeBanner {
                LevelPlayBannerView(adUnitID: AppEnvironment.levelPlayBannerAdUnitID)
                    // The banner configures its `LPMBannerAdView` once, so a revised
                    // consent choice or a late ATT grant only reaches the ad request
                    // stream by rebuilding it under a new identity.
                    .id(consentManager.adConfigurationRevision)
                    .frame(maxWidth: .infinity)
                    .background(Color.appBackground)
            }

            // The per-ad report route, the layer the ad SDK does not provide
            // here: Google's creatives carry an AdChoices icon and Unity's
            // full-screen videos a privacy icon, but an ironSource banner has
            // nothing to tap. Sits *under* the creative rather than over it —
            // mediation terms forbid obscuring an ad — and only once a banner
            // has actually been shown, so there is something to report.
            if recentAds.banner != nil, !membership.entitlements.removeBanner {
                HStack {
                    Spacer()
                    // The tap target is the words, not the row: a full-width
                    // strip this close to the home indicator would open Mail
                    // on mis-swipes.
                    Button {
                        openURL(AdReport.mailURL())
                    } label: {
                        Text("report_ad_banner_link")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .background(Color.appBackground)
            }
        }
        .background(Color.appBackground)
    }

    private func tabButton(title: String, systemImage: String, tab: AppTab) -> some View {
        Button {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            selectedTab = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: selectedTab == tab ? .semibold : .regular))
                Text(title)
                    .font(.caption)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                Group {
                    if selectedTab == tab {
                        Capsule()
                            .fill(Color.white.opacity(0.14))
                    }
                }
            )
            .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }
}

private struct AlarmHomeView: View {
    @ObservedObject var viewModel: AlarmViewModel
    let showsWeatherAttribution: Bool
    let openSettings: (SettingsCategory, String?) -> Void
    @State private var now = Date()
    @State private var isVisible = false
    /// The master switch was flipped off: what the choice dialog offers.
    @State private var offChoice: AlarmSkipAvailability?
    @Environment(\.scenePhase) private var scenePhase

    private var tomorrow: TomorrowAlarmStatus { viewModel.tomorrowStatus(now: now) }

    /// On: undo a skip or arm again, immediately. Off: nothing changes until the user
    /// picks "only the next alarm" or "until I turn it back on" — Cancel leaves it on.
    private var alarmSwitch: Binding<Bool> {
        Binding(get: { viewModel.isAlarmSwitchOn(now: now) }, set: { on in
            if on {
                Task { await viewModel.turnAlarmOn() }
            } else {
                offChoice = viewModel.skipAvailability(now: Date())
            }
        })
    }

    private var switchAccessibilityValue: String? {
        guard let skipped = viewModel.liveSkippedAlarmDate(now: now) else { return nil }
        return String.localizedStringWithFormat(String(localized: "ux_alarm_switch_skip_value"),
            skipped.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated)))
    }

    private func offMessage(_ choice: AlarmSkipAvailability) -> String {
        switch choice {
        case .available(let target):
            let when = target.ringDate.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated))
                + " " + viewModel.settings.timeFormat.time(target.ringDate)
            return String.localizedStringWithFormat(String(localized: "ux_alarm_off_message_next"), when)
        case .alarmInProgress:
            return String(localized: "ux_alarm_off_message_in_progress")
        case .unavailable:
            return String(localized: "ux_alarm_off_message_only")
        }
    }
    private var routeIncomplete: Bool {
        viewModel.settings.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewModel.settings.workAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// Selection shared with the Home Screen widget (TomorrowWidgetSnapshotBuilder),
    /// so the two say the same thing by construction. The card keeps the real
    /// `isScheduling`; only the widget snapshot treats it as false.
    private var scheduleIssue: String? {
        // The rules, including the master switch's (off: only a failure to turn off is worth a
        // banner) and the committed schedule missing a ring the card expects, are the
        // builder's, so the widget cannot drift from them.
        switch TomorrowWidgetSnapshotBuilder.scheduleIssue(for: tomorrow, flags: .init(model: viewModel)) {
        case nil: nil
        case .schedulingFailed: viewModel.scheduleErrorMessage
        case .alarmKitReschedule: String(localized: "alarmkit_reschedule_notice")
        case .closureUncertain: String(localized: "disaster_schedule_uncertain")
        case .closureUpdateFailed: String(localized: "ux_closure_update_failed")
        case .updateNeeded: String(localized: "ux_schedule_update_needed")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // One title row outside ViewThatFits, so the off-choice dialog has a single
            // anchor: it rises from the switch in the top-right corner.
            titleRow
            GeometryReader { _ in
                ViewThatFits(in: .vertical) {
                    homeContent(compact: false)
                    homeContent(compact: true)
                    ScrollView { homeContent(compact: true) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.horizontal, 20).padding(.top, 8)
        .background(Color.appBackground)
        .onAppear { now = Date(); isVisible = true; refreshWeather() }
        .onDisappear { isVisible = false }
        .onChange(of: TomorrowWeatherRequest(settings: viewModel.settings, now: now)) { _, _ in
            if isVisible { refreshWeather() }
        }
        // A new feed or committed schedule must be judged against the current instant, not the
        // last 30 s tick: a feed newer than `now` fails the evaluator's clock check.
        .onChange(of: viewModel.disasterFeed) { _, _ in now = Date() }
        .onChange(of: viewModel.scheduledAlarmSummary) { _, _ in now = Date() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) {
            now = $0
            if isVisible && scenePhase == .active {
                refreshWeather()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && isVisible {
                now = Date()
                refreshWeather()
            }
        }
    }

    private func refreshWeather(force: Bool = false) {
        let model = viewModel, date = now
        // Let an in-flight forecast finish and populate the cache when the user
        // changes tabs. Visibility changes must not cancel the initial request.
        // The model coalesces duplicates and rejects results for changed settings.
        Task { await model.refreshTomorrowWeatherIfNeeded(now: date, force: force) }
    }

    private var titleRow: some View {
        HStack(alignment: .center) {
            Text("tab_alarm").font(.largeTitle.bold())
            Spacer(minLength: 12)
            Toggle("tab_alarm", isOn: alarmSwitch)
                .labelsHidden()
                .modifier(OptionalAccessibilityValue(value: switchAccessibilityValue))
                .accessibilityIdentifier("alarmMasterSwitch")
                .confirmationDialog("ux_alarm_off_title",
                                    isPresented: Binding(get: { offChoice != nil }, set: { if !$0 { offChoice = nil } }),
                                    titleVisibility: .visible, presenting: offChoice) { choice in
                    if case .available(let target) = choice {
                        Button("ux_alarm_skip_next") {
                            Task {
                                // The next alarm changed while the dialog was open: ask again.
                                if !(await viewModel.skipNextAlarm(target)) { offChoice = viewModel.skipAvailability(now: Date()) }
                            }
                        }
                    }
                    Button("ux_alarm_turn_off", role: .destructive) { Task { await viewModel.turnAlarmOff() } }
                    Button("cancel", role: .cancel) {}
                } message: { choice in
                    Text(offMessage(choice))
                }
        }
    }

    private func homeContent(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            hero(compact: compact)
            if let message = scheduleIssue {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if viewModel.effectiveSchedulingSettings.isDisasterSuspensionEnabled && viewModel.disasterRefreshFailed
                        && viewModel.scheduleErrorMessage == nil {
                        Button("ux_category_calendar") { openSettings(.calendar, nil) }
                            .font(.caption.weight(.semibold))
                    } else if !viewModel.settings.isAlarmEnabled {
                        // Off, but alarms were left behind: try turning off again.
                        Button("ux_retry") { Task { await viewModel.turnAlarmOff() } }
                            .font(.caption.weight(.semibold)).disabled(viewModel.isScheduling)
                    } else {
                        Button("ux_retry") { Task { await viewModel.evaluateRouteAndScheduleAlarm() } }
                            .font(.caption.weight(.semibold)).disabled(viewModel.isScheduling || !viewModel.canSchedule)
                    }
                }.padding(12).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
            }
            weatherCard(compact: compact)
        }
    }

    private func hero(compact: Bool) -> some View {
        let userChoice = tomorrow.reason == .alarmOff || tomorrow.reason == .skippedOnce
        return VStack(spacing: compact ? 8 : 12) {
            // Off: no day above "Alarm Off" — it would read as an alarm on that day.
            if tomorrow.reason != .alarmOff {
                Button { openSettings(.calendar, nil) } label: {
                    HStack {
                        // After midnight the owner wants the morning named by what it is, not "today".
                        Text(tomorrow.isToday ? "ux_next_alarm" : "ux_tomorrow")
                        Spacer()
                        Text(tomorrow.day.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated)))
                    }
                    // Owner, 2026-09-30: larger than title3 so the day reads at a glance.
                    .font(compact ? .title2.bold() : .title.bold())
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if let ring = tomorrow.expectedRingDate {
                Button { openSettings(.time, "wake") } label: {
                    VStack(spacing: 3) {
                        Text(tomorrow.hasRung ? "ux_rang_at" : "ux_expected_ring").font(.caption).foregroundStyle(.secondary)
                        Text(viewModel.settings.timeFormat.time(ring))
                            .font(.system(size: compact ? 50 : 62, weight: .regular, design: .rounded))
                            .lineLimit(1).minimumScaleFactor(0.65).monospacedDigit()
                        if !AlarmCalendarSettings.calendar.isDate(ring, inSameDayAs: tomorrow.day) {
                            Text(ring.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.plain)
            } else if userChoice {
                // The user's own choice: nothing in Settings explains or changes it — the
                // switch above does.
                Text(tomorrow.reason == .alarmOff ? "ux_alarm_off" : "ux_tomorrow_skipped")
                    .font(.system(size: compact ? 32 : 38, weight: .medium, design: .rounded))
                    .padding(.vertical, compact ? 8 : 12).frame(maxWidth: .infinity)
            } else {
                Button { openSettings(tomorrow.reason == .routeIncomplete ? .route : .calendar, nil) } label: {
                    Text(tomorrow.reason == .routeIncomplete ? "ux_not_set" : "ux_tomorrow_skipped")
                        .font(.system(size: compact ? 32 : 38, weight: .medium, design: .rounded))
                        .padding(.vertical, compact ? 8 : 12).frame(maxWidth: .infinity)
                }.buttonStyle(.plain)
            }
            if let reason = reason, userChoice {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash").foregroundStyle(Color.accentColor)
                    Text(reason).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }.font(.subheadline).frame(maxWidth: .infinity)
            } else if let reason = reason {
                Button {
                    openSettings(tomorrow.reason == .rain ? .time : (tomorrow.reason == .routeIncomplete ? .route : .calendar),
                                 tomorrow.reason == .rain ? "rain" : nil)
                } label: {
                    HStack(spacing: 6) {
                        // A carried-over lead waits for its own forecast: not a rain icon (until it
                        // has rung; then the line says 因雨提早 too, see `reason`).
                        Image(systemName: tomorrow.rainLeadIsCarriedOver && !tomorrow.hasRung ? "hourglass"
                              : tomorrow.reason == .rain ? "cloud.rain" : (tomorrow.expectedRingDate == nil ? "bell.slash" : "calendar"))
                            .foregroundStyle(Color.accentColor)
                        Text(reason).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }.font(.subheadline).frame(maxWidth: .infinity)
                }.buttonStyle(.plain)
                if tomorrow.reason == .disaster { closureSourceCredit }
            }
            // A one-time skip for a later morning than the one this card describes.
            if tomorrow.reason != .alarmOff, let skipped = viewModel.liveSkippedAlarmDate(now: now),
               !AlarmCalendarSettings.calendar.isDate(skipped, inSameDayAs: tomorrow.day) {
                Text(String.localizedStringWithFormat(String(localized: "ux_skip_later"),
                    skipped.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated))))
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
        }.padding(compact ? 15 : 18)
            .frame(maxWidth: .infinity)
            .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    /// docs/DAYOFF-SPEC.md §7: a surface that reports a closure names the source (the OGDL
    /// credit is a licence condition) and the source's own update time. caption2 and
    /// secondary, so it never out-ranks the Apple Weather mark in the weather card.
    private var closureSourceCredit: some View {
        VStack(spacing: 2) {
            if let updated = viewModel.disasterFeed?.sourceUpdatedAt {
                Text(String.localizedStringWithFormat(String(localized: "disaster_source_updated"),
                    viewModel.settings.timeFormat.dateTime(updated)))
            }
            Text("disaster_source")
        }
        .font(.caption2).foregroundStyle(.secondary)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }

    private func weatherCard(compact: Bool) -> some View {
        CommuteWeatherCard(
            weather: tomorrow.weather,
            homeAddress: viewModel.settings.homeAddress,
            workAddress: viewModel.settings.workAddress,
            mode: viewModel.settings.commuteMode,
            title: tomorrow.isToday ? "ux_today_weather" : "ux_tomorrow_weather",
            compact: compact,
            isActive: isVisible,
            isLoading: viewModel.isRefreshingTomorrowWeather || isWaitingForFirstForecast,
            notice: weatherNotice,
            hasError: tomorrow.weatherRefreshFailed || tomorrow.weatherIsStale,
            showsWeatherAttribution: showsWeatherAttribution,
            openRoute: { openSettings(.route, nil) },
            retry: { refreshWeather(force: true) }
        )
    }

    private var weatherNotice: String? {
        let today = tomorrow.isToday
        return switch TomorrowWidgetSnapshotBuilder.weatherNotice(for: tomorrow, addressesMissing: routeIncomplete) {
        case nil: nil
        case .failed: String(localized: today ? "ux_today_weather_failed" : "ux_tomorrow_weather_failed")
        case .stale: String(localized: "ux_tomorrow_weather_stale")
        case .routeNeeded: String(localized: "ux_route_needed")
        // The card can load; the widget cannot.
        case .noForecast: String(localized: today ? "ux_today_weather_loading" : "ux_tomorrow_weather_loading")
        }
    }

    private var isWaitingForFirstForecast: Bool {
        tomorrow.weather == nil && !routeIncomplete && !tomorrow.weatherRefreshFailed
    }

    private var reason: String? {
        // The builder chooses the line (shared with the widget); the card words it for the
        // morning it describes: 今天 after midnight, 明天 before.
        let today = tomorrow.isToday
        return switch TomorrowWidgetSnapshotBuilder.reasonLine(for: tomorrow) {
        case nil: nil
        case .rainForecast(let percent, let minutes):
            String.localizedStringWithFormat(String(localized: "ux_rain_applied_forecast"), percent, minutes)
        case .rainEarlier(let minutes): String.localizedStringWithFormat(String(localized: "ux_rain_applied"), minutes)
        case .awaitingForecast:
            // Card only: a carried-over lead that has rung waits for nothing any more, and no
            // widget entry describes a morning after its ring.
            tomorrow.hasRung
                ? String.localizedStringWithFormat(String(localized: "ux_rain_applied"), tomorrow.leadTimeMinutes)
                : String(localized: today ? "ux_today_awaiting_forecast" : "ux_tomorrow_awaiting_forecast")
        case .holidayNamed(let name):
            String.localizedStringWithFormat(String(localized: today ? "ux_today_holiday_named" : "ux_tomorrow_holiday_named"), name)
        case .holiday: String(localized: today ? "ux_today_holiday" : "ux_tomorrow_holiday")
        case .manualSkip: String(localized: today ? "ux_today_manual_skip" : "ux_tomorrow_manual_skip")
        case .manualRing: String(localized: today ? "ux_today_manual_ring" : "ux_tomorrow_manual_ring")
        case .weekend: String(localized: today ? "ux_today_weekend" : "ux_tomorrow_weekend")
        case .unselectedWeekday: String(localized: today ? "ux_today_unselected" : "ux_tomorrow_unselected")
        case .closure:
            today ? String.localizedStringWithFormat(String(localized: "ux_today_closure_skipped"),
                                                     viewModel.settings.timeFormat.time(tomorrow.normalAlarmDate))
                  : String(localized: "ux_tomorrow_closure")
        case .routeNeeded: String(localized: "ux_route_needed")
        case .alarmOff: String(localized: "ux_alarm_off_reason")
        case .skippedOnce:
            if let resume = viewModel.ringAfterSkip(now: now) {
                String.localizedStringWithFormat(String(localized: "ux_skip_once_resume"),
                    resume.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated)))
            } else {
                String(localized: "ux_skip_once_reason")
            }
        }
    }

}

struct RouteTabView: View {
    private static let routeModes: [CommuteAlarmSettings.CommuteMode] = [
        .car, .scooter, .publicTransit, .walking
    ]

    private enum Setting: String, Identifiable {
        case home, work, mode
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: String(localized: "home_label")
            case .work: String(localized: "work_label")
            case .mode: String(localized: "mode")
            }
        }
    }

    @ObservedObject var viewModel: AlarmViewModel
    var navigationRequest: SettingsNavigationRequest? = nil
    var onNavigationRequestHandled: (UUID) -> Void = { _ in }
    var isActive = true
    @AppStorage("routePreviewExpanded") private var isRoutePreviewExpanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentedSetting: Setting?
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 0) {
                    routeSettingRow("home_label", icon: "house", value: viewModel.settings.homeAddress, setting: .home,
                                    attention: addressAttention(.home))
                    Divider().padding(.leading, 48)
                    routeSettingRow("work_label", icon: "building.2", value: viewModel.settings.workAddress, setting: .work,
                                    attention: addressAttention(.work))
                    Divider().padding(.leading, 48)
                    routeSettingRow("mode", icon: modeIcon(viewModel.settings.commuteMode),
                                    value: viewModel.settings.commuteMode.displayName, setting: .mode)
                }
                .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                routePreviewCard
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .navigationTitle(String(localized: "tab_route"))
        .toolbar(.hidden, for: .navigationBar)
        .background(Color.appBackground)
        .sheet(item: $presentedSetting, onDismiss: { scheduleRoutePreview(delay: .zero) }) { setting in
            settingSheet(setting)
        }
        .task(id: navigationRequest?.id) {
            guard let navigationRequest, navigationRequest.category == .route else { return }
            switch navigationRequest.anchor {
            case "home": presentedSetting = .home
            case "work": presentedSetting = .work
            case "mode": presentedSetting = .mode
            default: break
            }
            onNavigationRequestHandled(navigationRequest.id)
        }
        .onChange(of: isActive, initial: true) { _, active in
            if active {
                normalizeRouteMode()
                scheduleRoutePreview()
            } else {
                stopRouteTasks()
            }
        }
        .onDisappear { stopRouteTasks() }
        .onChange(of: viewModel.settings.commuteMode) { _, _ in
            guard isActive else { return }
            normalizeRouteMode()
            scheduleRoutePreview()
        }
    }

    private func routeSettingRow(_ title: LocalizedStringKey, icon: String, value: String, setting: Setting,
                                 attention: SettingsEntryRow.Attention? = nil) -> some View {
        Button { presentedSetting = setting } label: {
            SettingsEntryRow(title: title, icon: icon, value: value, attention: attention)
        }
        .buttonStyle(.plain)
    }

    /// The not-found and confirm states block scheduling but live inside the sheet;
    /// the row has to say so, or the alarm silently stays unset.
    private func addressAttention(_ field: CommuteAddressField) -> SettingsEntryRow.Attention? {
        if viewModel.invalidAddressFields.contains(field) {
            return .error(String(localized: "address_not_found_inline"))
        }
        if viewModel.suggestedAddressMatches[field]?.isConfirmed == false {
            return .warning(String(localized: "status_confirm_suggested_address"))
        }
        return nil
    }

    private var routePreviewCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    isRoutePreviewExpanded.toggle()
                }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "map").foregroundStyle(Color.accentColor).frame(width: 20)
                    Text("route_preview")
                    Spacer()
                    if viewModel.isPreviewingRoute { ProgressView().controlSize(.small) }
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isRoutePreviewExpanded ? 180 : 0))
                }
                .font(.body).frame(minHeight: 28).padding(.horizontal, 16).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isRoutePreviewExpanded ? "route_preview_collapse" : "route_preview_expand"))
            .accessibilityIdentifier("routePreviewDisclosure")

            if isRoutePreviewExpanded {
                VStack(spacing: 0) {
                    if let preview = viewModel.routePreview {
                        RoutePreviewMapView(preview: preview)
                            .padding(.horizontal, 16).padding(.bottom, 16)

                        if let travelMinutes = preview.expectedTravelTimeMinutes,
                           let distance = preview.distanceKilometers {
                            Divider().padding(.leading, 48)
                            routeMetricRow("route_preview_travel_time", icon: "clock",
                                           value: String.localizedStringWithFormat(String(localized: "route_preview_minutes_value"), travelMinutes))
                            Divider().padding(.leading, 48)
                            routeMetricRow("route_preview_distance", icon: "point.topleft.down.curvedto.point.bottomright.up",
                                           value: String.localizedStringWithFormat(String(localized: "route_preview_distance_value"), distance))
                        }
                    }
                    if viewModel.routePreview?.route == nil {
                        Text(viewModel.routePreviewStatusMessage)
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.bottom, 16)
                    }
                }
            }
        }
        .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func routeMetricRow(_ title: LocalizedStringKey, icon: String, value: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 20)
            Text(title)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(.secondary)
        }
        .font(.body).frame(minHeight: 28).padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func settingSheet(_ setting: Setting) -> some View {
        NavigationStack {
            ScrollView {
                if setting == .mode {
                    VStack(spacing: 0) {
                        ForEach(Self.routeModes) { mode in
                            Button {
                                viewModel.settings.commuteMode = mode
                                presentedSetting = nil
                            } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: modeIcon(mode)).foregroundStyle(Color.accentColor).frame(width: 20)
                                    Text(mode.displayName).foregroundStyle(.primary)
                                    Spacer()
                                    if mode == viewModel.settings.commuteMode {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                    }
                                }
                                .font(.body).frame(minHeight: 28).padding(.horizontal, 16).padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(mode == viewModel.settings.commuteMode ? .isSelected : [])
                            if mode != Self.routeModes.last { Divider().padding(.leading, 48) }
                        }
                    }
                    .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(20)
                } else {
                    let field: CommuteAddressField = setting == .home ? .home : .work
                    AddressEditor(viewModel: viewModel, field: field,
                                  onSearch: { scheduleRoutePreview(delay: .zero) },
                                  onClear: { clearAddress(field) },
                                  onFinish: { if presentedSetting == setting { presentedSetting = nil } })
                        .id(field)
                        .padding(20)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.appBackground)
            .navigationTitle(setting.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { presentedSetting = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("clock_close"))
                }
            }
        }
        .presentationDetents(setting == .mode ? [.height(390)] : [.large])
        .presentationDragIndicator(.visible)
    }

    private func modeIcon(_ mode: CommuteAlarmSettings.CommuteMode) -> String {
        switch mode {
        case .car: "car"
        case .scooter: "scooter"
        case .publicTransit: "tram"
        case .walking: "figure.walk"
        }
    }

    private func normalizeRouteMode() {
        guard !Self.routeModes.contains(viewModel.settings.commuteMode) else {
            return
        }

        viewModel.settings.commuteMode = .car
    }

    private func stopRouteTasks() {
        previewTask?.cancel()
    }

    private func clearAddress(_ field: CommuteAddressField) {
        switch field {
        case .home: viewModel.settings.homeAddress = ""
        case .work: viewModel.settings.workAddress = ""
        }
        viewModel.clearAddressState(field)
        previewTask?.cancel()
        viewModel.clearRoutePreview()
        viewModel.clearRouteWeather()
    }

    private func scheduleRoutePreview(delay: Duration = .milliseconds(700)) {
        guard isActive else { return }
        previewTask?.cancel()
        // Cancellation cannot abort an already-running fetch, so also invalidate it —
        // otherwise its stale result could land during the debounce delay below.
        viewModel.supersedeRoutePreview()
        previewTask = Task {
            guard viewModel.canPreviewRoute else {
                await MainActor.run {
                    viewModel.clearRoutePreview()
                }
                return
            }

            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else {
                    return
                }
            }

            await viewModel.previewRoute()
        }
    }

}

struct AlarmTimeSettingsView: View {
    private static let weekdayGridSpacing: CGFloat = 12
    private static let weekdayLabelInset: CGFloat = 4

    private let weekdayOrder = [1, 2, 3, 4, 5, 6, 7]

    @ObservedObject var viewModel: AlarmViewModel
    @ObservedObject private var consentManager = ConsentManager.shared
    @State private var showsAIVoiceSheet = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // Only consulted at accessibility text sizes, where the row wraps and the
    // chip finally has room to grow. Capped so AX5 doesn't produce a chip
    // taller than the alarm time underneath it.
    @ScaledMetric(relativeTo: .callout) private var scaledWeekdayChipHeight: CGFloat = 44
    // `.callout` at the reader's text size, as a number the row can fit labels to.
    @ScaledMetric(relativeTo: .callout) private var scaledWeekdayLabelSize: CGFloat = 16
    @State private var showsTimePicker = false
    @State private var audioPlayer: AVAudioPlayer?
    @State private var previewingSound: CommuteAlarmSettings.AlarmSound?
    @State private var soundPreviewTask: Task<Void, Never>?

    var navigationRequest: SettingsNavigationRequest? = nil
    var onNavigationRequestHandled: (UUID) -> Void = { _ in }
    @State private var presentedSetting: Setting?
    private enum Setting: String, Identifiable {
        case time, rain, normalSound, earlySound, snooze, evening
        var id: String { rawValue }
        var soundSlot: CommuteAlarmSettings.SoundSlot? {
            switch self {
            case .normalSound: .normal
            case .earlySound: .early
            default: nil
            }
        }
        var title: String {
            switch self {
            case .time: String(localized: "ux_wake_time")
            case .rain: String(localized: "ux_rain_earlier")
            case .normalSound: String(localized: "alarm_sound_normal")
            case .earlySound: String(localized: "alarm_sound_early")
            case .snooze: String(localized: "ux_snooze")
            case .evening: String(localized: "ux_evening")
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                settingsGroup {
                    settingRow("ux_wake_time", icon: "clock", value: timeText(for: viewModel.settings.alarmTime), setting: .time)
                    Divider().padding(.leading, 48)
                    settingRow("ux_early_time", icon: "cloud.rain", value: String.localizedStringWithFormat(String(localized: "rain_lead_time_value"), viewModel.settings.rainLeadTimeMinutes), setting: .rain)
                    Divider().padding(.leading, 48)
                    settingRow("rain_threshold", icon: "drop", value: "\(Int(viewModel.settings.rainProbabilityThreshold * 100))%", setting: .rain)
                }
                settingsGroup {
                    settingRow("alarm_sound_early", icon: "cloud.rain", value: viewModel.settings.sound(for: .early).displayName, setting: .earlySound)
                    Divider().padding(.leading, 48)
                    settingRow("alarm_sound_normal", icon: "music.note", value: viewModel.settings.sound(for: .normal).displayName, setting: .normalSound)
                    Divider().padding(.leading, 48)
                    settingRow("ux_snooze", icon: "timer", value: viewModel.settings.isSnoozeEnabled ? String.localizedStringWithFormat(String(localized: "snooze_duration_value"), viewModel.settings.snoozeDurationMinutes) : String(localized: "ux_off"), setting: .snooze)
                    Divider().padding(.leading, 48)
                    settingRow("ux_evening", icon: "moon", value: viewModel.settings.isEveningPreviewEnabled ? timeText(for: viewModel.settings.eveningPreviewTime) : String(localized: "ux_off"), setting: .evening)
                }
            }.padding(.horizontal, 20).padding(.bottom, 20)
        }
        .background(Color.appBackground)
        .sheet(item: $presentedSetting, onDismiss: stopSoundPreview) { setting in
            settingSheet(setting)
                .sheet(isPresented: $showsAIVoiceSheet) {
                    AIVoiceSheet(viewModel: viewModel, slot: setting.soundSlot ?? .normal)
                }
        }
        .task(id: navigationRequest?.id) {
            guard let navigationRequest, navigationRequest.category == .time else { return }
            // The parent routes legacy repeat-day links to Calendar.
            guard navigationRequest.anchor != "weekdays" else { return }
            switch navigationRequest.anchor {
            case "wake": presentedSetting = .time
            case "rain": presentedSetting = .rain
            case "evening": presentedSetting = .evening
            default: break
            }
            onNavigationRequestHandled(navigationRequest.id)
        }
        .onAppear { clampRainLeadTime() }
        .onDisappear { stopSoundPreview() }
    }

    private func settingRow(_ title: LocalizedStringKey, icon: String, value: String, setting: Setting) -> some View {
        Button { presentedSetting = setting } label: {
            SettingsEntryRow(title: title, icon: icon, value: value)
        }.buttonStyle(.plain)
    }

    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder private func settingSheet(_ setting: Setting) -> some View {
        if setting == .time {
            ClockTimePicker(time: $viewModel.settings.alarmTime, format: viewModel.settings.timeFormat,
                            title: setting.title, formatSelection: $viewModel.settings.timeFormat)
        } else {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 20) {
                        switch setting {
                        case .rain:
                            VStack(alignment: .leading, spacing: 12) {
                                HStack { Text("ux_early_time"); Spacer(); Text(String.localizedStringWithFormat(String(localized: "rain_lead_time_value"), viewModel.settings.rainLeadTimeMinutes)).foregroundStyle(Color.accentColor) }
                                Slider(value: rainLeadTimeSliderValue, in: 1...60, step: 1)
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                HStack { Text("rain_threshold"); Spacer(); Text("\(Int(viewModel.settings.rainProbabilityThreshold * 100))%").foregroundStyle(Color.accentColor) }
                                Slider(value: $viewModel.settings.rainProbabilityThreshold, in: 0.1...0.9, step: 0.05)
                            }
                        case .normalSound, .earlySound:
                            soundSettings(for: setting.soundSlot ?? .normal)
                        case .snooze:
                            Toggle("ux_snooze", isOn: $viewModel.settings.isSnoozeEnabled)
                            if viewModel.settings.isSnoozeEnabled {
                                HStack { Text("snooze_duration"); Spacer(); Text(String.localizedStringWithFormat(String(localized: "snooze_duration_value"), viewModel.settings.snoozeDurationMinutes)).foregroundStyle(Color.accentColor) }
                                Slider(value: snoozeDurationSliderValue, in: Double(CommuteAlarmSettings.snoozeDurationRange.lowerBound)...Double(CommuteAlarmSettings.snoozeDurationRange.upperBound), step: 1)
                            }
                        case .evening:
                            Toggle("ux_evening", isOn: $viewModel.settings.isEveningPreviewEnabled)
                            if viewModel.settings.isEveningPreviewEnabled {
                                DatePicker("evening_preview_time", selection: $viewModel.settings.eveningPreviewTime, displayedComponents: .hourAndMinute)
                                    .datePickerStyle(.wheel).labelsHidden()
                                    .environment(\.locale, Locale(identifier: viewModel.settings.timeFormat == .twentyFourHour ? "en_GB" : (Locale.current.language.languageCode?.identifier == "zh" ? "zh_TW" : "en_US")))
                            }
                        case .time: EmptyView()
                        }
                    }.font(.body).padding(22)
                }
                .navigationTitle(setting.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button { presentedSetting = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("clock_close"))
                } }
                .background(Color.appBackground)
            }
            .presentationDetents(setting.soundSlot != nil ? [.large] : [.height(390)])
            .presentationDragIndicator(.visible)
        }
    }

    /// Seven chips across one row leave each one only ~34pt wide on a small
    /// phone. That is fine up to xxxLarge, but an accessibility text size makes
    /// the label wider than the circle even at the minimum scale factor, and
    /// SwiftUI truncates it to "…". Wrap onto four per row instead: the chips
    /// then have room to actually grow with the reader's text size.
    private var weekdayColumnCount: Int {
        dynamicTypeSize.isAccessibilitySize ? 4 : 7
    }

    private var weekdayRows: [[Int]] {
        stride(from: 0, to: weekdayOrder.count, by: weekdayColumnCount).map { start in
            Array(weekdayOrder[start..<min(start + weekdayColumnCount, weekdayOrder.count)])
        }
    }

    /// Standard sizes keep the historical 44pt circle — width, not height, is
    /// the constraint there, so growing it would only add empty space.
    private var weekdayChipHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? min(scaledWeekdayChipHeight, 76) : 44
    }

    private var weekdayGridHeight: CGFloat {
        let rows = CGFloat(weekdayRows.count)
        return rows * weekdayChipHeight + (rows - 1) * Self.weekdayGridSpacing
    }

    private func weekdayLabelSize(inRowOfWidth rowWidth: CGFloat) -> CGFloat {
        let columns = CGFloat(weekdayColumnCount)
        let chipWidth = (rowWidth - Self.weekdayGridSpacing * (columns - 1)) / columns

        return RowLabelFont.fittedSize(
            labels: weekdayOrder.map(label(for:)),
            fittingWidth: chipWidth - Self.weekdayLabelInset * 2,
            baseSize: scaledWeekdayLabelSize,
            weight: .semibold
        )
    }

    private func weekdayChip(for weekday: Int, labelSize: CGFloat) -> some View {
        let isSelected = viewModel.settings.selectedWeekdays.contains(weekday)

        return Button {
            toggleWeekday(weekday)
        } label: {
            Text(label(for: weekday))
                .font(.system(size: labelSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .allowsTightening(true)
                .foregroundStyle(isSelected ? .white : Color.white.opacity(0.45))
                .padding(.horizontal, Self.weekdayLabelInset)
                .frame(maxWidth: .infinity)
                .frame(height: weekdayChipHeight)
                .background(
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color.appCardBackground)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    private func toggleWeekday(_ weekday: Int) {
        if viewModel.settings.selectedWeekdays.contains(weekday) {
            viewModel.settings.selectedWeekdays.remove(weekday)
        } else {
            viewModel.settings.selectedWeekdays.insert(weekday)
        }
    }

    private var rainLeadTimeSliderValue: Binding<Double> {
        Binding {
            Double(min(max(viewModel.settings.rainLeadTimeMinutes, 1), 60))
        } set: { newValue in
            viewModel.settings.rainLeadTimeMinutes = min(max(Int(newValue.rounded()), 1), 60)
        }
    }

    private var scheduleStatusIcon: String {
        guard viewModel.hasScheduledAlarm else {
            return "minus.circle"
        }

        return viewModel.isScheduleStale ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var scheduleStatusColor: Color {
        guard viewModel.hasScheduledAlarm else {
            return .secondary
        }

        return viewModel.isScheduleStale ? .orange : .green
    }

    private var snoozeDurationSliderValue: Binding<Double> {
        let range = CommuteAlarmSettings.snoozeDurationRange
        return Binding {
            Double(min(max(viewModel.settings.snoozeDurationMinutes, range.lowerBound), range.upperBound))
        } set: { newValue in
            viewModel.settings.snoozeDurationMinutes = min(max(Int(newValue.rounded()), range.lowerBound), range.upperBound)
        }
    }

    private func clampRainLeadTime() {
        viewModel.settings.rainLeadTimeMinutes = min(max(viewModel.settings.rainLeadTimeMinutes, 1), 60)
    }

    private func label(for weekday: Int) -> String {
        switch weekday {
        case 1:
            String(localized: "weekday_sunday_short")
        case 2:
            String(localized: "weekday_monday_short")
        case 3:
            String(localized: "weekday_tuesday_short")
        case 4:
            String(localized: "weekday_wednesday_short")
        case 5:
            String(localized: "weekday_thursday_short")
        case 6:
            String(localized: "weekday_friday_short")
        default:
            String(localized: "weekday_saturday_short")
        }
    }

    private func rainAdjustmentText(for summary: ScheduledAlarmSummary) -> String {
        guard summary.exceedsRainThreshold else {
            return String(localized: "not_applied")
        }

        return String.localizedStringWithFormat(String(localized: "minutes_earlier"), summary.leadTimeMinutes)
    }

    /// The only hand-built time formatter in the app used to live here: it forced a
    /// 12-hour clock, so with 24-Hour Time on the headline read "7:00 PM" above a
    /// picker set to 19:00, and it chose the Chinese word order from the *device*
    /// language, which put "AM" in front of the English strings for a Simplified
    /// Chinese device. `.dateTime` answers both questions from the resolved locale.
    private func timeText(for date: Date) -> String {
        viewModel.settings.timeFormat.time(date)
    }

    @ViewBuilder private func soundSettings(for slot: CommuteAlarmSettings.SoundSlot) -> some View {
        let selected = viewModel.settings.sound(for: slot)
        ForEach(soundChoices) { sound in
            Button { selectSound(sound, for: slot) } label: {
                HStack {
                    Text(sound.displayName).foregroundStyle(.primary)
                    Spacer()
                    if selected == sound { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                }.frame(minHeight: 32).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        if selected == .aiVoice {
            Button("ai_voice_edit") { stopSoundPreview(); showsAIVoiceSheet = true }
        }
        let otherSlot: CommuteAlarmSettings.SoundSlot = slot == .early ? .normal : .early
        if let fileName = viewModel.settings.voiceFileName(for: otherSlot),
           GeneratedVoiceStore.existingFileName(named: fileName) != nil,
           selected != .aiVoice || fileName != viewModel.settings.voiceFileName(for: slot) {
            Button(LocalizedStringKey(slot == .early ? "ai_voice_use_normal" : "ai_voice_use_early")) {
                stopSoundPreview()
                var settings = viewModel.settings
                settings.setVoice(fileName: fileName, persona: settings.voicePersona(for: otherSlot),
                                  text: settings.voiceText(for: otherSlot), for: slot)
                viewModel.settings = settings
            }
        }
        if !selected.usesSystemAlarmTone {
            Button { toggleSelectedSoundPreview(for: slot) } label: {
                Label("preview_alarm_sound", systemImage: previewingSound == selected ? "stop.circle.fill" : "play.circle.fill")
            }
        }
    }

    /// The picker's contents. `aiVoice` appears only where it can actually be
    /// produced, the same way an unset `LevelPlayAppKey` keeps the ad SDK out of
    /// the build's behaviour rather than leaving a control that does nothing.
    private var soundChoices: [CommuteAlarmSettings.AlarmSound] {
        var choices = CommuteAlarmSettings.AlarmSound.selectableCases
        if AIVoiceClient.isConfigured {
            choices.append(.aiVoice)
        }
        return choices
    }

    /// Select a saved voice without generating again. A new voice is selected
    /// only after saving succeeds, so cancelling leaves this slot unchanged.
    private func selectSound(_ sound: CommuteAlarmSettings.AlarmSound, for slot: CommuteAlarmSettings.SoundSlot) {
        stopSoundPreview()
        if sound == .aiVoice,
           viewModel.settings.voiceFileName(for: slot).flatMap(GeneratedVoiceStore.existingFileName) == nil {
            showsAIVoiceSheet = true
            return
        }
        viewModel.settings.setSound(sound, for: slot)
    }

    private func toggleSelectedSoundPreview(for slot: CommuteAlarmSettings.SoundSlot) {
        let sound = viewModel.settings.sound(for: slot)
        if previewingSound == sound {
            stopSoundPreview()
        } else {
            previewSound(sound, for: slot)
        }
    }

    /// The shipped tones live in the bundle; a generated one lives in the app's
    /// own container. The alarm itself never needs to know the difference — both
    /// paths resolve a bare file name — but this player opens the file directly,
    /// so it does.
    private func previewURL(for sound: CommuteAlarmSettings.AlarmSound, slot: CommuteAlarmSettings.SoundSlot) -> URL? {
        if sound == .aiVoice {
            return viewModel.settings.voiceFileName(for: slot).flatMap(GeneratedVoiceStore.url(named:))
        }
        let parts = sound.fileName.split(separator: ".", maxSplits: 1).map(String.init)
        guard let resource = parts.first, let ext = parts.dropFirst().first else {
            return nil
        }
        return Bundle.main.url(forResource: resource, withExtension: ext)
    }

    private func previewSound(_ sound: CommuteAlarmSettings.AlarmSound, for slot: CommuteAlarmSettings.SoundSlot) {
        stopSoundPreview()
        guard let url = previewURL(for: sound, slot: slot),
              let player = try? AVAudioPlayer(contentsOf: url) else {
            return
        }

        // Without a category the session defaults to `.soloAmbient`, which obeys the
        // ring/silent switch — so in an app whose whole premise is piercing silent
        // mode, the preview button flipped to "stop" and played nothing.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.duckOthers])
        try? session.setActive(true)

        audioPlayer = player
        previewingSound = sound
        player.prepareToPlay()
        player.play()

        let duration = player.duration
        soundPreviewTask = Task {
            try? await Task.sleep(for: .milliseconds(Int(duration * 1_000)))
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                if previewingSound == sound {
                    audioPlayer?.stop()
                    audioPlayer = nil
                    previewingSound = nil
                    soundPreviewTask = nil
                }
            }
        }
    }

    private func stopSoundPreview() {
        soundPreviewTask?.cancel()
        soundPreviewTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        previewingSound = nil
        // Hand audio back rather than leaving other apps ducked after a 20s clip.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// One font size for a row of equal-width labels.
///
/// `minimumScaleFactor` shrinks each label independently to fit its own box, so
/// a row ends up with mismatched text sizes — "Fri" stays full size while "Wed"
/// shrinks, and `大眾交通` comes out visibly smaller than `開車`. Sizing every
/// label in the row to whichever one is widest keeps them consistent.
private enum RowLabelFont {
    static func fittedSize(
        labels: [String],
        fittingWidth: CGFloat,
        baseSize: CGFloat,
        weight: UIFont.Weight,
        minimumScale: CGFloat = 0.5
    ) -> CGFloat {
        guard fittingWidth > 0, baseSize > 0 else {
            return baseSize
        }

        let font = UIFont.systemFont(ofSize: baseSize, weight: weight)
        let widest = labels.reduce(CGFloat.zero) { widest, label in
            max(widest, (label as NSString).size(withAttributes: [.font: font]).width)
        }

        guard widest > fittingWidth else {
            return baseSize
        }

        return max(baseSize * fittingWidth / widest, baseSize * minimumScale)
    }
}

/// Everything the Home/Work sheet types into. Focus and the completer must live
/// inside the sheet: a FocusState owned by the presenting view never sees a field in
/// its sheet, which left the 1.7.0 suggestion list permanently hidden.
private struct AddressEditor: View {
    @ObservedObject var viewModel: AlarmViewModel
    let field: CommuteAddressField
    /// Runs the route preview without closing the sheet.
    let onSearch: () -> Void
    let onClear: () -> Void
    /// Closes the sheet; its onDismiss runs the route preview.
    let onFinish: () -> Void

    /// Per field and shared by every editor instance: a lookup started in a sheet that
    /// was closed and reopened must lose to the newer pick, typing or Clear.
    private static var selectionGenerations: [CommuteAddressField: Int] = [:]

    @StateObject private var completer = AddressSearchCompleter()
    @FocusState private var focusedField: CommuteAddressField?
    @State private var showsSuggestions = false
    @State private var isChoosingAnother = false
    @State private var resolving: MKLocalSearchCompletion?

    private var savedText: Binding<String> {
        field == .home ? $viewModel.settings.homeAddress : $viewModel.settings.workAddress
    }

    /// Only typing goes through this setter, so the list follows the user and never a
    /// rewrite by "Use this location", a picked row or Clear.
    private var typedText: Binding<String> {
        Binding(get: { savedText.wrappedValue }, set: { newValue in
            guard newValue != savedText.wrappedValue else { return }
            savedText.wrappedValue = newValue
            Self.selectionGenerations[field, default: 0] += 1
            resolving = nil
            isChoosingAnother = false
            showsSuggestions = true
            completer.update(query: newValue)
        })
    }

    private var showsPanel: Bool {
        guard showsSuggestions else { return false }
        if isChoosingAnother { return true }
        let query = savedText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return false }
        // Zhuyin still being composed: wait for the committed characters.
        return !(completer.completions.isEmpty && !completer.isSearching
                 && AddressSearchCompleter.isComposingZhuyin(query))
    }

    var body: some View {
        VStack(spacing: 14) {
            AddressFieldRow(
                label: String(localized: field == .home ? "home_label" : "work_label"),
                placeholder: String(localized: field == .home ? "home_address" : "work_address"),
                text: typedText,
                isInvalid: viewModel.invalidAddressFields.contains(field),
                suggestedMatch: viewModel.suggestedAddressMatches[field],
                focusedField: $focusedField,
                field: field,
                onSubmit: submit,
                onClear: clear,
                onConfirmSuggestion: {
                    viewModel.confirmSuggestedAddress(field)
                    hideSuggestions()
                },
                onChooseAnotherSuggestion: chooseAnother
            )
            if showsPanel {
                AddressCompletionList(
                    completions: completer.completions,
                    isSearching: completer.isSearching,
                    emptyText: String(localized: isChoosingAnother ? "address_suggestions_empty" : "address_suggestions_no_match"),
                    resolving: resolving
                ) { completion in
                    Task { @MainActor in await select(completion) }
                }
            }
        }
        .task { focusedField = field }
        .onAppear {
            completer.isPresented = true
            // Reopening a not-found address should offer places straight away.
            if viewModel.invalidAddressFields.contains(field) { chooseAnother() }
        }
        .onDisappear {
            completer.isPresented = false
            completer.clear()
        }
    }

    /// Search picks the one row named exactly as typed, as Maps does; otherwise the
    /// list stays for the user to choose. Without suggestions the typed text is used,
    /// the path App Review took.
    private func submit() {
        let typed = savedText.wrappedValue
        let matches = completer.completions.filter { MapItemResolver.isSameAddressText($0.title, typed) }
        if showsSuggestions, matches.count == 1, !MapItemResolver.containsHouseNumber(typed) {
            Task { @MainActor in await select(matches[0]) }
            return
        }
        focusedField = nil
        if showsPanel, !completer.completions.isEmpty { return }
        hideSuggestions()
        onFinish()
    }

    @MainActor
    private func select(_ completion: MKLocalSearchCompletion) async {
        // The completer outlives this view's State if the sheet closes mid-lookup.
        let session = completer
        Self.selectionGenerations[field, default: 0] += 1
        let generation = Self.selectionGenerations[field, default: 0]
        let requestedInput = savedText.wrappedValue
        resolving = completion
        let location = await MapItemResolver.resolvedLocation(for: completion)
        // The latest tap wins, and typing or Clear during the lookup cancels it.
        guard generation == Self.selectionGenerations[field, default: 0],
              savedText.wrappedValue == requestedInput else {
            if session.isPresented, resolving === completion { resolving = nil }
            return
        }
        let fallback = [completion.title, completion.subtitle]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: ", ")
        if let location {
            let resolved = location.displayAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            viewModel.setAddressFromSuggestion(resolved.isEmpty ? fallback : resolved, location: location, field: field)
        } else {
            // No coordinate: keep it as typed text, so the preview still confirms it.
            savedText.wrappedValue = fallback
        }
        guard session.isPresented else {
            // Closed while resolving; the dismissal preview used the old text.
            onSearch()
            return
        }
        resolving = nil
        hideSuggestions()
        onFinish()
    }

    private func clear() {
        Self.selectionGenerations[field, default: 0] += 1
        resolving = nil
        hideSuggestions()
        onClear()
        focusedField = field
    }

    private func chooseAnother() {
        isChoosingAnother = true
        showsSuggestions = true
        focusedField = field
        completer.update(query: savedText.wrappedValue, forceRefresh: true)
    }

    private func hideSuggestions() {
        showsSuggestions = false
        isChoosingAnother = false
        completer.clear()
    }
}

private struct AddressCompletionList: View {
    let completions: [MKLocalSearchCompletion]
    let isSearching: Bool
    let emptyText: String
    var resolving: MKLocalSearchCompletion?
    let onSelect: (MKLocalSearchCompletion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if completions.isEmpty {
                HStack(spacing: 12) {
                    if isSearching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Text(isSearching ? String(localized: "address_suggestions_loading") : emptyText)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            } else {
                ForEach(completions.indices, id: \.self) { index in
                    let completion = completions[index]
                    Button {
                        onSelect(completion)
                    } label: {
                        HStack(spacing: 12) {
                            Group {
                                if resolving === completion {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "magnifyingglass")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 22)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(completion.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if !completion.subtitle.isEmpty {
                                    Text(completion.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(resolving != nil)

                    if index < completions.indices.last ?? 0 {
                        Divider()
                            .overlay(Color.white.opacity(0.08))
                            .padding(.leading, 48)
                    }
                }
            }
        }
        .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private final class AddressSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate, @unchecked Sendable {
    @Published private(set) var completions: [MKLocalSearchCompletion] = []
    @Published private(set) var isSearching = false
    /// A reference, so a lookup that outlives the sheet can tell the sheet is gone.
    var isPresented = false

    private let completer = MKLocalSearchCompleter()
    private var retriedThrottledQuery: String?

    /// Bopomofo still being composed is not a place name yet.
    static func isComposingZhuyin(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3100...0x312F).contains($0.value) || (0x31A0...0x31BF).contains($0.value) }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String, forceRefresh: Bool = false) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.count >= 2 else {
            clear()
            return
        }
        // Keep the current rows until the syllable is committed.
        guard !Self.isComposingZhuyin(trimmedQuery) else { return }

        let candidates = MapItemResolver.candidateQueries(for: trimmedQuery)
        let autocompleteQuery = candidates.first { candidate in
            !candidate.contains(",")
                && !candidate.contains("，")
                && !candidate.localizedStandardContains("股份有限公司")
                && !candidate.localizedStandardContains("Corporation")
        } ?? candidates.first ?? trimmedQuery

        if forceRefresh && completer.queryFragment == autocompleteQuery {
            isSearching = true
            completions = []
            completer.queryFragment = ""
            DispatchQueue.main.async { [weak self] in
                self?.completer.queryFragment = autocompleteQuery
            }
        } else if completer.queryFragment != autocompleteQuery {
            isSearching = true
            completer.queryFragment = autocompleteQuery
        }
        // Same query as the current search: assigning an unchanged queryFragment never
        // triggers a delegate callback, so leave isSearching untouched to avoid a stuck spinner.
    }

    func clear() {
        completer.queryFragment = ""
        completions = []
        isSearching = false
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        completions = Array(completer.results.prefix(5))
        isSearching = false
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        isSearching = false
        guard (error as? MKError)?.code == .loadingThrottled else {
            completions = []
            return
        }
        // Typing fast can throttle the final query. Keep the rows, and ask once more
        // unless the text moved on; an unchanged fragment never re-queries by itself.
        let throttled = completer.queryFragment
        guard retriedThrottledQuery != throttled else { return }
        retriedThrottledQuery = throttled
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !throttled.isEmpty, self.completer.queryFragment == throttled else { return }
            self.isSearching = true
            self.completer.queryFragment = ""
            DispatchQueue.main.async { self.completer.queryFragment = throttled }
        }
    }
}

private struct AddressFieldRow<Field: Hashable>: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let isInvalid: Bool
    let suggestedMatch: SuggestedAddressMatch?
    var focusedField: FocusState<Field?>.Binding
    let field: Field
    let onSubmit: () -> Void
    let onClear: () -> Void
    let onConfirmSuggestion: () -> Void
    let onChooseAnotherSuggestion: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isInvalid ? Color.red : .secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 44, alignment: .leading)

                TextField(placeholder, text: $text)
                    .font(.body)
                    .textContentType(.fullStreetAddress)
                    .submitLabel(.search)
                    .focused(focusedField, equals: field)
                    .onSubmit(onSubmit)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .tint(isInvalid ? .red : .accentColor)

                if !text.isEmpty {
                    Button {
                        onClear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "clear_address"))
                }
            }
            .padding(14)
            .background(
                (isInvalid ? Color.red.opacity(0.20) : Color.appFieldBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isInvalid ? Color.red : Color.clear, lineWidth: 2.5)
            )

            if isInvalid {
                Text(String(localized: "address_not_found_inline"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
            } else if let suggestedMatch {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: suggestedMatch.isConfirmed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(suggestedMatch.isConfirmed ? .green : .yellow)
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "suggested_address_prefix"),
                                suggestedMatch.suggestedAddress
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(suggestedMatch.isConfirmed ? Color.secondary : Color.yellow)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if suggestedMatch.isConfirmed {
                        Text(String(localized: "confirmed_suggested_address"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    } else {
                        HStack(spacing: 8) {
                            Button(String(localized: "confirm_suggested_address")) {
                                onConfirmSuggestion()
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .tint(.yellow)

                            Button(String(localized: "choose_another_address")) {
                                onChooseAnotherSuggestion()
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .tint(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }
}

extension Color {
    static let appBackground = Color.black
    static let appCardBackground = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let appFieldBackground = Color(red: 0.18, green: 0.18, blue: 0.20)
}

#Preview {
    ContentView(viewModel: AlarmViewModel())
}

/// Applies an accessibility value only when there is one, so the system's own on/off
/// reading stays in place otherwise.
private struct OptionalAccessibilityValue: ViewModifier {
    let value: String?
    func body(content: Content) -> some View {
        if let value { content.accessibilityValue(Text(value)) } else { content }
    }
}
