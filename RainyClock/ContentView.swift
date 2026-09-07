import AVFoundation
import MapKit
import SwiftUI
import UIKit

struct ContentView: View {
    private enum AppTab {
        case route
        case alarm
    }

    @StateObject var viewModel: AlarmViewModel
    @ObservedObject private var consentManager = ConsentManager.shared
    @ObservedObject private var recentAds = RecentAds.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var selectedTab: AppTab = .route
    var showsWeatherAttribution = false

    var body: some View {
        TabView(selection: $selectedTab) {
            RouteTabView(
                viewModel: viewModel,
                showsWeatherAttribution: showsWeatherAttribution
            )
                .tag(AppTab.route)

            AlarmTabView(viewModel: viewModel)
            .tag(AppTab.alarm)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomControls
        }
        .background(Color.appBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        // A GDPR user answers once before the first ad request; the same sheet
        // reopens from the Alarm tab's privacy row to change the answer later.
        .sheet(isPresented: $consentManager.isConsentSheetPresented) {
            AdConsentSheet()
        }
        // Deliberately not `onDismiss`: the continuation (SDK start, then ATT)
        // hangs off our own state flipping false — produced only by an answer
        // or a real swipe-down — instead of UIKit's presentation callbacks,
        // whose timing around launch is not worth trusting.
        .onChange(of: consentManager.isConsentSheetPresented) { wasPresented, isPresented in
            if wasPresented, !isPresented {
                consentManager.consentSheetDidClose()
            }
        }
        .task {
            consentManager.requestConsentThenStartAds()
            // The armed alarm repeats weekly with the rain decision that was current
            // when it was scheduled; opening the app is what brings that decision up
            // to date. No-op when it is still fresh.
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

            // Harmless after the first activation: the SDK starts only once,
            // and AppLovin retries a failed handshake on its own.
            consentManager.requestConsentThenStartAds()
            Task {
                await viewModel.refreshScheduledAlarmIfWeatherIsStale()
            }
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton(
                    title: String(localized: "tab_route"),
                    systemImage: "map",
                    tab: .route
                )
                tabButton(
                    title: String(localized: "tab_alarm"),
                    systemImage: "alarm",
                    tab: .alarm
                )
            }
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color.white.opacity(0.04), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 8)
            .padding(.horizontal, 34)
            .padding(.top, 12)
            .padding(.bottom, 22)

            // Kept out of the hierarchy until consent is settled and LevelPlay
            // has finished initialising, so no ad request can precede either.
            if !AppEnvironment.isRunningTests, consentManager.canRequestAds {
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
            if recentAds.banner != nil {
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
            withAnimation(.easeInOut) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: selectedTab == tab ? .semibold : .regular))
                Text(title)
                    .font(.caption)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
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
    }
}

private struct RouteTabView: View {
    private static let routeModes: [CommuteAlarmSettings.CommuteMode] = [
        .car,
        .scooter,
        .publicTransit,
        .walking
    ]

    private enum AddressField: Hashable {
        case home
        case work
    }

    @ObservedObject var viewModel: AlarmViewModel
    let showsWeatherAttribution: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var addressCompleter = AddressSearchCompleter()
    @FocusState private var focusedAddressField: AddressField?
    @State private var expandedAddressSuggestionField: AddressField?
    @State private var addressSelectionGeneration = 0
    @State private var previewTask: Task<Void, Never>?
    @State private var weatherTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(spacing: 12) {
                            AddressFieldRow(
                                label: String(localized: "home_label"),
                                placeholder: String(localized: "home_address"),
                                text: $viewModel.settings.homeAddress,
                                isInvalid: viewModel.invalidAddressFields.contains(.home),
                                suggestedMatch: viewModel.suggestedAddressMatches[CommuteAddressField.home],
                                focusedField: $focusedAddressField,
                                field: .home,
                                onSubmit: submitAddressSearch,
                                onClear: { clearAddress(.home) },
                                onConfirmSuggestion: { viewModel.confirmSuggestedAddress(.home) },
                                onChooseAnotherSuggestion: { focusAddressForSuggestion(.home) }
                            )
                            AddressFieldRow(
                                label: String(localized: "work_label"),
                                placeholder: String(localized: "work_address"),
                                text: $viewModel.settings.workAddress,
                                isInvalid: viewModel.invalidAddressFields.contains(.work),
                                suggestedMatch: viewModel.suggestedAddressMatches[CommuteAddressField.work],
                                focusedField: $focusedAddressField,
                                field: .work,
                                onSubmit: submitAddressSearch,
                                onClear: { clearAddress(.work) },
                                onConfirmSuggestion: { viewModel.confirmSuggestedAddress(.work) },
                                onChooseAnotherSuggestion: { focusAddressForSuggestion(.work) }
                            )

                            if shouldShowAddressCompletionPanel {
                                AddressCompletionList(
                                    completions: addressCompleter.completions,
                                    isSearching: addressCompleter.isSearching
                                ) { completion in
                                    Task { @MainActor in
                                        await selectAddressCompletion(completion)
                                    }
                                }
                            }
                        }

                        // The label keeps its intrinsic width, so at an
                        // accessibility text size it would eat most of the row
                        // and leave the pills too narrow to read. Put it on its
                        // own line there instead.
                        modeRowLayout {
                            Text("mode")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(minWidth: 44, alignment: .leading)
                            RouteModePicker(
                                selection: $viewModel.settings.commuteMode,
                                modes: Self.routeModes
                            )
                        }
                        .padding(14)
                        .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }

                    if let preview = viewModel.routePreview {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("route_preview")
                                .font(.headline)
                                .foregroundStyle(.secondary)

                            RoutePreviewMapView(preview: preview)

                            if let expectedTravelTimeMinutes = preview.expectedTravelTimeMinutes,
                               let distanceKilometers = preview.distanceKilometers {
                                HStack(spacing: 12) {
                                    MetricCard(
                                        title: String(localized: "route_preview_travel_time"),
                                        value: String.localizedStringWithFormat(
                                            String(localized: "route_preview_minutes_value"),
                                            expectedTravelTimeMinutes
                                        )
                                    )
                                    MetricCard(
                                        title: String(localized: "route_preview_distance"),
                                        value: String.localizedStringWithFormat(
                                            String(localized: "route_preview_distance_value"),
                                            distanceKilometers
                                        )
                                    )
                                }
                            }

                            Text(viewModel.routePreviewStatusMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if viewModel.isPreviewingRoute || viewModel.routePreviewStatusMessage != String(localized: "route_preview_empty") {
                        Text(viewModel.routePreviewStatusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("route_weather")
                                .font(.title.weight(.bold))
                            Spacer()
                            if viewModel.isRefreshingRouteWeather {
                                ProgressView()
                            }
                        }

                        if let snapshot = viewModel.routeWeatherSnapshot {
                            RouteWeatherGrid(segments: snapshot.segments)
                        } else {
                            RouteWeatherPlaceholderCards()
                        }

                        Text(viewModel.routeWeatherStatusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        // WeatherKit attribution must always be visible where weather
                        // data is presented, not only once a forecast has loaded.
                        if showsWeatherAttribution {
                            WeatherAttributionView()
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 0)
                .padding(.bottom, 20)
            }
            .navigationTitle(String(localized: "tab_route"))
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("done") {
                        focusedAddressField = nil
                    }
                }
            }
            .background(Color.appBackground)
        }
        .onAppear {
            normalizeRouteMode()
            scheduleRoutePreview()
            scheduleRouteWeather()
        }
        .onDisappear {
            previewTask?.cancel()
            weatherTask?.cancel()
        }
        .onChange(of: focusedAddressField) { _, _ in
            updateAddressCompletions()
        }
        .onChange(of: viewModel.settings.homeAddress) { _, _ in
            updateAddressCompletions()
        }
        .onChange(of: viewModel.settings.workAddress) { _, _ in
            updateAddressCompletions()
        }
        .onChange(of: viewModel.settings.commuteMode) { _, _ in
            normalizeRouteMode()
            scheduleRoutePreview()
            scheduleRouteWeather()
        }
        .onChange(of: viewModel.settings.alarmTime) { _, _ in
            scheduleRouteWeather()
        }
        .onChange(of: viewModel.settings.selectedWeekdays) { _, _ in
            scheduleRouteWeather()
        }
    }

    private var modeRowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    private func normalizeRouteMode() {
        guard !Self.routeModes.contains(viewModel.settings.commuteMode) else {
            return
        }

        viewModel.settings.commuteMode = .car
    }

    private func submitAddressSearch() {
        focusedAddressField = nil
        expandedAddressSuggestionField = nil
        addressCompleter.clear()
        scheduleRoutePreview(delay: .zero)
        scheduleRouteWeather(delay: .zero)
    }

    private func clearAddress(_ field: AddressField) {
        switch field {
        case .home:
            viewModel.settings.homeAddress = ""
            viewModel.clearAddressState(.home)
        case .work:
            viewModel.settings.workAddress = ""
            viewModel.clearAddressState(.work)
        }

        focusedAddressField = field
        expandedAddressSuggestionField = nil
        addressCompleter.clear()
        previewTask?.cancel()
        weatherTask?.cancel()
        viewModel.clearRoutePreview()
        viewModel.clearRouteWeather()
    }

    private func focusAddressForSuggestion(_ field: AddressField) {
        focusedAddressField = field
        expandedAddressSuggestionField = field
        updateAddressCompletions(forceRefresh: true)
    }

    @MainActor
    private func selectAddressCompletion(_ completion: MKLocalSearchCompletion) async {
        // Capture the target field before any await: focus can move (or clear) while
        // the completion resolves over the network, and the result must not follow it.
        // The generation makes the LATEST tap win when taps overlap in flight.
        guard let targetField = focusedAddressField else {
            return
        }

        addressSelectionGeneration += 1
        let generation = addressSelectionGeneration

        let fallbackAddress = [completion.title, completion.subtitle]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: ", ")
        let resolvedLocation = await MapItemResolver.resolvedLocation(for: completion)
        guard generation == addressSelectionGeneration else {
            return
        }

        let resolvedAddress = resolvedLocation?.displayAddress?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let address = resolvedAddress?.isEmpty == false ? resolvedAddress! : fallbackAddress

        switch targetField {
        case .home:
            viewModel.setAddressFromSuggestion(address, location: resolvedLocation, field: .home)
        case .work:
            viewModel.setAddressFromSuggestion(address, location: resolvedLocation, field: .work)
        }

        submitAddressSearch()
    }

    private var shouldShowAddressCompletionPanel: Bool {
        guard let focusedAddressField else {
            return false
        }

        return !addressCompleter.completions.isEmpty || expandedAddressSuggestionField == focusedAddressField
    }

    private func updateAddressCompletions(forceRefresh: Bool = false) {
        switch focusedAddressField {
        case .home:
            addressCompleter.update(query: viewModel.settings.homeAddress, forceRefresh: forceRefresh)
        case .work:
            addressCompleter.update(query: viewModel.settings.workAddress, forceRefresh: forceRefresh)
        case nil:
            expandedAddressSuggestionField = nil
            addressCompleter.clear()
        }
    }

    private func scheduleRoutePreview(delay: Duration = .milliseconds(700)) {
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

    private func scheduleRouteWeather(delay: Duration = .milliseconds(700)) {
        weatherTask?.cancel()
        viewModel.supersedeRouteWeather()
        weatherTask = Task {
            guard viewModel.canPreviewRoute else {
                await MainActor.run {
                    viewModel.clearRouteWeather()
                }
                return
            }

            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else {
                    return
                }
            }

            await viewModel.refreshRouteWeather()
        }
    }
}

/// The two ad rows every region or some region needs: the GDPR consent
/// re-entry, and the App Review 2.5.18 report route, which is required
/// everywhere and so is not behind `showsPrivacyOptions`. The report button
/// builds its mail at tap time so the body carries the ads shown *by then*.
private struct AdSupportCard: View {
    @ObservedObject private var consentManager = ConsentManager.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ad_support_header")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            // Only GDPR regions have a choice to revisit — the geography
            // answer from LevelPlay init decides.
            if consentManager.showsPrivacyOptions {
                HStack {
                    Text("ad_privacy_options")
                    Spacer()
                    Button("ad_privacy_options_manage") {
                        consentManager.presentPrivacyOptions()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }

            HStack {
                Text("report_ad")
                Spacer()
                Button("report_ad_action") {
                    openURL(AdReport.mailURL())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .font(.subheadline)
        .padding(18)
        .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct AlarmTabView: View {
    private static let weekdayGridSpacing: CGFloat = 12
    private static let weekdayLabelInset: CGFloat = 4

    private let weekdayOrder = [1, 2, 3, 4, 5, 6, 7]

    @ObservedObject var viewModel: AlarmViewModel
    @ObservedObject private var consentManager = ConsentManager.shared
    @State private var showsAIVoiceSheet = false
    @State private var sampleNoticeVisible = false
    @State private var soundBeforeAIVoice: CommuteAlarmSettings.AlarmSound?
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 20) {
                        // The geometry reader is what lets every chip share one
                        // font size; the grid's height is fixed either way, so
                        // it costs no layout ambiguity.
                        GeometryReader { proxy in
                            let labelSize = weekdayLabelSize(inRowOfWidth: proxy.size.width)

                            VStack(spacing: Self.weekdayGridSpacing) {
                                ForEach(Array(weekdayRows.enumerated()), id: \.offset) { _, row in
                                    HStack(spacing: Self.weekdayGridSpacing) {
                                        ForEach(row, id: \.self) { weekday in
                                            weekdayChip(for: weekday, labelSize: labelSize)
                                        }

                                        // Keep the short trailing row's chips the
                                        // same width as the full row's.
                                        ForEach(Array(row.count..<weekdayColumnCount), id: \.self) { _ in
                                            Color.clear
                                                .frame(maxWidth: .infinity)
                                                .frame(height: weekdayChipHeight)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(height: weekdayGridHeight)

                        Button {
                            showsTimePicker = true
                        } label: {
                            Text(timeText(for: viewModel.settings.alarmTime))
                                .font(.system(size: 60, weight: .regular, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                    .padding(22)
                    .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 30, style: .continuous))

                    VStack(spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("rain_lead_time")
                                Spacer()
                                Text(String.localizedStringWithFormat(String(localized: "rain_lead_time_value"), viewModel.settings.rainLeadTimeMinutes))
                                    .foregroundStyle(.secondary)
                            }

                            Slider(value: rainLeadTimeSliderValue, in: 1...60, step: 1)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("rain_threshold")
                                Spacer()
                                Text("\(Int(viewModel.settings.rainProbabilityThreshold * 100))%")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $viewModel.settings.rainProbabilityThreshold, in: 0.1...0.9, step: 0.05)
                        }

                        HStack {
                            Text("alarm_sound")
                            Spacer()
                            Menu {
                                Picker("alarm_sound", selection: $viewModel.settings.alarmSound) {
                                    ForEach(soundChoices) { sound in
                                        Text(sound.displayName).tag(sound)
                                    }
                                }
                            } label: {
                                Text(viewModel.settings.alarmSound.displayName)
                                    .foregroundStyle(.secondary)
                            }
                            // Selecting the spoken alarm opens the sheet, but only
                            // on a change — so once it is chosen there is nothing
                            // left to tap to edit it. This is that.
                            if viewModel.settings.alarmSound == .aiVoice {
                                Button {
                                    stopSoundPreview()
                                    showsAIVoiceSheet = true
                                } label: {
                                    Image(systemName: "square.and.pencil")
                                        .font(.title3)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel(Text("alarm_sound_ai_voice"))
                            }
                            // The system alarm tone lives in iOS, not in the app
                            // bundle, so there is nothing to play here.
                            if !viewModel.settings.alarmSound.usesSystemAlarmTone {
                                Button {
                                    toggleSelectedSoundPreview()
                                } label: {
                                    Image(systemName: isPreviewingSelectedSound ? "stop.circle.fill" : "play.circle.fill")
                                        .font(.title3)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel(Text("preview_alarm_sound"))
                            }
                        }

                        Toggle(isOn: $viewModel.settings.isSnoozeEnabled) {
                            Text("snooze")
                        }
                        .tint(Color.accentColor)

                        if viewModel.settings.isSnoozeEnabled {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("snooze_duration")
                                    Spacer()
                                    Text(String.localizedStringWithFormat(String(localized: "snooze_duration_value"), viewModel.settings.snoozeDurationMinutes))
                                        .foregroundStyle(.secondary)
                                }

                                Slider(
                                    value: snoozeDurationSliderValue,
                                    in: Double(CommuteAlarmSettings.snoozeDurationRange.lowerBound)...Double(CommuteAlarmSettings.snoozeDurationRange.upperBound),
                                    step: 1
                                )
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: $viewModel.settings.isEveningPreviewEnabled) {
                                Text("evening_preview")
                            }
                            .tint(Color.accentColor)

                            if viewModel.settings.isEveningPreviewEnabled {
                                HStack {
                                    Text("evening_preview_time")
                                    Spacer()
                                    DatePicker(
                                        "evening_preview_time",
                                        selection: $viewModel.settings.eveningPreviewTime,
                                        displayedComponents: .hourAndMinute
                                    )
                                    .labelsHidden()
                                    .tint(Color.accentColor)
                                }

                                HStack(alignment: .firstTextBaseline) {
                                    Text("evening_preview_hint")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    // Sends one now-ish, so the shape of the thing can
                                    // be seen before the first real evening. Also the
                                    // most natural moment to ask for permission.
                                    Button("evening_preview_send_sample") {
                                        Task {
                                            sampleNoticeVisible = !(await viewModel.sendSampleEveningPreview())
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .fixedSize()
                                }
                                if sampleNoticeVisible {
                                    Text("evening_preview_denied")
                                        .font(.footnote)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    .padding(18)
                    .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                    Button {
                        Task { await viewModel.evaluateRouteAndScheduleAlarm() }
                    } label: {
                        Label(
                            viewModel.isScheduling ? String(localized: "checking_route") : String(localized: "schedule_smart_alarm"),
                            systemImage: "alarm"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                    .disabled(!viewModel.canSchedule || viewModel.isScheduling)

                    // Colour answers "is an alarm actually armed right now?" at a
                    // glance: green = armed and matching the settings above,
                    // orange = armed but syncing/stale, grey = nothing armed.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: scheduleStatusIcon)
                        Text(viewModel.statusMessage)
                    }
                    .font(.subheadline.weight(viewModel.hasScheduledAlarm ? .semibold : .regular))
                    .foregroundStyle(scheduleStatusColor)

                    if let summary = viewModel.scheduledAlarmSummary {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("scheduled_result")
                                .font(.headline)
                            if viewModel.isScheduleStale {
                                Label(String(localized: "schedule_stale_notice"), systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                            if viewModel.requiresAlarmKitReschedule {
                                Label(String(localized: "alarmkit_reschedule_notice"), systemImage: "bell.badge.fill")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                            MetricRow(title: String(localized: "normal_alarm"), value: summary.normalAlarmDate.formatted(date: .omitted, time: .shortened))
                            MetricRow(title: String(localized: "scheduled_alarm"), value: summary.scheduledAlarmDate.formatted(date: .abbreviated, time: .shortened))
                            MetricRow(title: String(localized: "weather_refresh"), value: summary.weatherRefreshDate.formatted(date: .abbreviated, time: .shortened))
                            MetricRow(title: String(localized: "rain_threshold"), value: "\(Int(summary.rainProbabilityThreshold * 100))%")
                            MetricRow(title: String(localized: "route_max"), value: "\(Int(summary.maximumPrecipitationProbability * 100))%")
                            MetricRow(title: String(localized: "rain_adjustment"), value: rainAdjustmentText(for: summary))
                        }
                        .padding(18)
                        .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }

                    // Ad housekeeping, last and apart from the alarm's own
                    // settings — where the privacy policy and "contact us" rows
                    // of most apps live. It used to sit between the snooze
                    // slider and the schedule button, which read as an alarm
                    // setting that had wandered in.
                    AdSupportCard()
                }
                .padding(.horizontal, 20)
                .padding(.top, 0)
                .padding(.bottom, 20)
            }
            .navigationTitle(String(localized: "tab_alarm"))
            .toolbar(.hidden, for: .navigationBar)
            .background(Color.appBackground)
        }
        .onChange(of: viewModel.settings.alarmSound) { previous, current in
            soundSelectionChanged(from: previous, to: current)
        }
        .sheet(isPresented: $showsAIVoiceSheet, onDismiss: aiVoiceSheetDismissed) {
            AIVoiceSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showsTimePicker) {
            NavigationStack {
                DatePicker(
                    "normal_alarm",
                    selection: $viewModel.settings.alarmTime,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .padding()
                .presentationDetents([.height(320)])
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("done") {
                            showsTimePicker = false
                        }
                    }
                }
            }
        }
        .onAppear {
            clampRainLeadTime()
        }
        .onDisappear {
            stopSoundPreview()
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
        date.formatted(.dateTime.hour().minute())
    }

    private var isPreviewingSelectedSound: Bool {
        previewingSound == viewModel.settings.alarmSound
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

    /// Choosing the spoken alarm means writing it, so the picker opens the sheet
    /// rather than selecting a file that may not exist yet. Backing out without a
    /// clip puts the previous tone back — leaving `aiVoice` selected with nothing
    /// behind it would show a sound the alarm would not actually ring.
    private func soundSelectionChanged(from previous: CommuteAlarmSettings.AlarmSound,
                                       to current: CommuteAlarmSettings.AlarmSound) {
        guard current == .aiVoice, previous != .aiVoice, !showsAIVoiceSheet else {
            return
        }
        stopSoundPreview()
        soundBeforeAIVoice = previous
        showsAIVoiceSheet = true
    }

    private func aiVoiceSheetDismissed() {
        guard viewModel.settings.alarmSound == .aiVoice,
              viewModel.settings.aiVoiceFileName.flatMap(GeneratedVoiceStore.existingFileName) == nil,
              let previous = soundBeforeAIVoice else {
            soundBeforeAIVoice = nil
            return
        }
        viewModel.settings.alarmSound = previous
        soundBeforeAIVoice = nil
    }

    private func toggleSelectedSoundPreview() {
        if isPreviewingSelectedSound {
            stopSoundPreview()
        } else {
            previewSound(viewModel.settings.alarmSound)
        }
    }

    /// The shipped tones live in the bundle; a generated one lives in the app's
    /// own container. The alarm itself never needs to know the difference — both
    /// paths resolve a bare file name — but this player opens the file directly,
    /// so it does.
    private func previewURL(for sound: CommuteAlarmSettings.AlarmSound) -> URL? {
        if sound == .aiVoice {
            return viewModel.settings.aiVoiceFileName.flatMap(GeneratedVoiceStore.url(named:))
        }
        let parts = sound.fileName.split(separator: ".", maxSplits: 1).map(String.init)
        guard let resource = parts.first, let ext = parts.dropFirst().first else {
            return nil
        }
        return Bundle.main.url(forResource: resource, withExtension: ext)
    }

    private func previewSound(_ sound: CommuteAlarmSettings.AlarmSound) {
        stopSoundPreview()
        guard let url = previewURL(for: sound),
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

private struct RouteModePicker: View {
    private static let gridSpacing: CGFloat = 6
    private static let labelInset: CGFloat = 8

    @Binding var selection: CommuteAlarmSettings.CommuteMode
    let modes: [CommuteAlarmSettings.CommuteMode]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var scaledLabelSize: CGFloat = 15

    var body: some View {
        GeometryReader { proxy in
            let labelSize = labelSize(inRowOfWidth: proxy.size.width)

            VStack(spacing: Self.gridSpacing) {
                ForEach(rowStarts, id: \.self) { start in
                    HStack(spacing: Self.gridSpacing) {
                        ForEach(modes[start..<min(start + columnCount, modes.count)]) { mode in
                            Button {
                                selection = mode
                            } label: {
                                Text(mode.displayName)
                                    .font(.system(size: labelSize, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                                    .allowsTightening(true)
                                    .padding(.horizontal, Self.labelInset)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: pillHeight)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                            .background(selection == mode ? Color.accentColor : Color.appFieldBackground)
                            .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .frame(height: gridHeight)
    }

    /// Four pills on one row leave each label ~45pt wide at an accessibility
    /// text size, which truncates every one of them to "…". Two columns give
    /// the labels room to grow instead.
    private var columnCount: Int {
        dynamicTypeSize.isAccessibilitySize ? 2 : modes.count
    }

    private var rowStarts: [Int] {
        Array(stride(from: 0, to: modes.count, by: columnCount))
    }

    /// Sized from the unshrunk text so the pill height does not depend on the
    /// fitted label size, which in turn depends on the row width.
    private var pillHeight: CGFloat {
        UIFont.systemFont(ofSize: scaledLabelSize, weight: .semibold).lineHeight.rounded(.up) + 20
    }

    private var gridHeight: CGFloat {
        let rows = (CGFloat(modes.count) / CGFloat(columnCount)).rounded(.up)
        return rows * pillHeight + (rows - 1) * Self.gridSpacing
    }

    private func labelSize(inRowOfWidth rowWidth: CGFloat) -> CGFloat {
        let columns = CGFloat(columnCount)
        let pillWidth = (rowWidth - Self.gridSpacing * (columns - 1)) / columns

        return RowLabelFont.fittedSize(
            labels: modes.map(\.displayName),
            fittingWidth: pillWidth - Self.labelInset * 2,
            baseSize: scaledLabelSize,
            weight: .semibold
        )
    }
}

private struct AddressCompletionList: View {
    let completions: [MKLocalSearchCompletion]
    let isSearching: Bool
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
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Text(String(localized: isSearching ? "address_suggestions_loading" : "address_suggestions_empty"))
                        .font(.subheadline.weight(.semibold))
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
                            Image(systemName: "magnifyingglass")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(completion.title)
                                    .font(.subheadline.weight(.semibold))
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

    private let completer = MKLocalSearchCompleter()

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
        completions = []
        isSearching = false
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isInvalid ? Color.red : .secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 44, alignment: .leading)

                TextField(placeholder, text: $text)
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

private struct MetricCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct MetricRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// The card count is dynamic: the two endpoints, plus up to three interior
/// samples once the commute is long enough. Five cards in one `HStack` are
/// wider than the screen — they clip at both edges and drag the whole page's
/// horizontal margins with them — so the cards move onto two rows instead.
///
/// Five of them do that as a **W**: stops 1, 3 and 5 on the top row, stops 2
/// and 4 dropped onto a second row nesting in the gaps between them. Every
/// card then still sits further right than the one before it, so the row reads
/// home → office left to right, which a plain 3+2 grid loses — there the
/// fourth stop starts a new row at the far left, behind the second.
private struct RouteWeatherGrid: View {
    private static let spacing: CGFloat = 10

    let segments: [RouteWeatherSegment]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var rowWidth: CGFloat = 0

    var body: some View {
        if usesStaggeredRows {
            staggeredRows
        } else {
            wrappedRows
        }
    }

    private var staggeredRows: some View {
        VStack(spacing: Self.spacing) {
            HStack(spacing: Self.spacing) {
                ForEach(topIndices, id: \.self) { index in
                    RouteWeatherCard(segment: segments[index], peers: segments)
                }
            }
            .background(rowWidthReader)

            HStack(spacing: Self.spacing) {
                ForEach(bottomIndices, id: \.self) { index in
                    RouteWeatherCard(segment: segments[index], peers: segments)
                }
            }
            // One card lands the lower row exactly between the two above it.
            .padding(.horizontal, staggerInset)
        }
    }

    private var wrappedRows: some View {
        VStack(spacing: Self.spacing) {
            ForEach(rowStarts, id: \.self) { start in
                let end = min(start + columnCount, segments.count)

                HStack(spacing: Self.spacing) {
                    ForEach(segments[start..<end]) { segment in
                        RouteWeatherCard(segment: segment, peers: segments)
                    }

                    // Keep a short trailing row's cards the same width as a
                    // full row's rather than letting them stretch.
                    ForEach(Array((end - start)..<columnCount), id: \.self) { _ in
                        Color.clear
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var rowWidthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: proxy.size.width, initial: true) { _, width in
                    rowWidth = width
                }
        }
    }

    /// An even count would put as many cards on the lower row as the upper one,
    /// leaving no gap to nest into; only an odd count staggers. In practice the
    /// sampler produces two, three or five. Accessibility sizes stay on the
    /// wrapped rows — a W at those sizes is back to five cards' worth of width.
    private var usesStaggeredRows: Bool {
        !dynamicTypeSize.isAccessibilitySize && segments.count >= 5 && !segments.count.isMultiple(of: 2)
    }

    private var topIndices: [Int] {
        Array(stride(from: 0, to: segments.count, by: 2))
    }

    private var bottomIndices: [Int] {
        Array(stride(from: 1, to: segments.count, by: 2))
    }

    private var staggerInset: CGFloat {
        guard rowWidth > 0, !topIndices.isEmpty else {
            return 0
        }

        let columns = CGFloat(topIndices.count)
        let cardWidth = (rowWidth - Self.spacing * (columns - 1)) / columns
        return (cardWidth + Self.spacing) / 2
    }

    /// Two endpoints alone keep the historical side-by-side pair.
    private var columnCount: Int {
        min(max(segments.count, 1), dynamicTypeSize.isAccessibilitySize ? 2 : 3)
    }

    private var rowStarts: [Int] {
        Array(stride(from: 0, to: segments.count, by: columnCount))
    }
}

private struct RouteWeatherCard: View {
    let segment: RouteWeatherSegment
    /// Every card on screen, this one included. Their titles and rain figures
    /// are laid out invisibly behind this card's own so each line reserves the
    /// same height in every card, which keeps the three tiers on shared
    /// baselines. Without it a one-line "Cloudy" makes its card's stack shorter
    /// than a neighbour's two-line "62% precipitation", and centring that
    /// shorter stack drops the title below the titles either side of it.
    let peers: [RouteWeatherSegment]

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                ForEach(peers.indices, id: \.self) { index in
                    title(peers[index].name)
                        .hidden()
                }

                title(segment.name)
            }

            Image(systemName: segment.condition.iconName)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 42))
                .foregroundStyle(segment.condition.color)

            ZStack {
                ForEach(peers.indices, id: \.self) { index in
                    conditionLabel(Self.conditionText(for: peers[index]))
                        .hidden()
                }

                conditionLabel(conditionText)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding(.vertical, 18)
        .padding(.horizontal, 8)
        .background(
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.12, blue: 0.15), Color(red: 0.02, green: 0.28, blue: 0.42)],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.headline.weight(.semibold))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.7)
    }

    private func conditionLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.6)
    }

    private var conditionText: String {
        Self.conditionText(for: segment)
    }

    static func conditionText(for segment: RouteWeatherSegment) -> String {
        switch segment.condition {
        case .clear:
            return String(localized: "weather_clear")
        case .cloudy:
            return String(localized: "weather_cloudy")
        case .rain:
            return String.localizedStringWithFormat(
                String(localized: "precipitation_value"),
                Int(segment.precipitationProbability * 100)
            )
        }
    }
}

private struct RouteWeatherPlaceholderCards: View {
    private let titles = [
        String(localized: "segment_home_area"),
        String(localized: "segment_office_area")
    ]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(titles, id: \.self) { title in
                VStack(spacing: 12) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)

                    Image(systemName: "cloud.sun.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 42))

                    Text("weather_waiting")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .padding(.vertical, 18)
                .padding(.horizontal, 8)
                .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            }
        }
    }
}

private extension RouteWeatherSegment.Condition {
    var iconName: String {
        switch self {
        case .clear:
            "sun.max.fill"
        case .cloudy:
            "cloud.sun.fill"
        case .rain:
            "cloud.rain.fill"
        }
    }

    var color: Color {
        switch self {
        case .clear:
            .yellow
        case .cloudy:
            .cyan
        case .rain:
            .blue
        }
    }
}

private extension Color {
    static let appBackground = Color.black
    static let appCardBackground = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let appFieldBackground = Color(red: 0.18, green: 0.18, blue: 0.20)
}

#Preview {
    ContentView(viewModel: AlarmViewModel())
}
