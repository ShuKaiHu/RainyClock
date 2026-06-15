import AVFoundation
import SwiftUI

struct ContentView: View {
    private enum AppTab {
        case route
        case alarm
    }

    @StateObject var viewModel: AlarmViewModel
    @State private var selectedTab: AppTab = .route
    var showsWeatherAttribution = false

    var body: some View {
        VStack(spacing: 0) {
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
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(Color.appCardBackground)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
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
            .frame(maxWidth: .infinity)
            .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct RouteTabView: View {
    private static let routeModes: [CommuteAlarmSettings.CommuteMode] = [
        .car,
        .scooter,
        .walking
    ]

    @ObservedObject var viewModel: AlarmViewModel
    let showsWeatherAttribution: Bool
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
                                text: $viewModel.settings.homeAddress
                            )
                            AddressFieldRow(
                                label: String(localized: "work_label"),
                                placeholder: String(localized: "work_address"),
                                text: $viewModel.settings.workAddress
                            )
                        }

                        HStack(spacing: 12) {
                            Text("mode")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .leading)
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

                            HStack(spacing: 12) {
                                MetricCard(
                                    title: String(localized: "route_preview_travel_time"),
                                    value: String.localizedStringWithFormat(
                                        String(localized: "route_preview_minutes_value"),
                                        preview.expectedTravelTimeMinutes
                                    )
                                )
                                MetricCard(
                                    title: String(localized: "route_preview_distance"),
                                    value: String.localizedStringWithFormat(
                                        String(localized: "route_preview_distance_value"),
                                        preview.distanceKilometers
                                    )
                                )
                            }
                        }
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
                            HStack(spacing: 10) {
                                ForEach(snapshot.segments) { segment in
                                    RouteWeatherCard(segment: segment)
                                }
                            }

                            if showsWeatherAttribution {
                                WeatherAttributionView()
                            }
                        } else {
                            RouteWeatherPlaceholderCards()
                        }

                        Text(viewModel.routeWeatherStatusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
            .navigationTitle(String(localized: "tab_route"))
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
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
        .onChange(of: viewModel.settings.homeAddress) { _, _ in
            scheduleRoutePreview()
            scheduleRouteWeather()
        }
        .onChange(of: viewModel.settings.workAddress) { _, _ in
            scheduleRoutePreview()
            scheduleRouteWeather()
        }
        .onChange(of: viewModel.settings.commuteMode) { _, _ in
            normalizeRouteMode()
            scheduleRoutePreview()
            scheduleRouteWeather()
        }
        .onChange(of: viewModel.settings.alarmTime) { _, _ in
            scheduleRouteWeather()
        }
    }

    private func normalizeRouteMode() {
        guard !Self.routeModes.contains(viewModel.settings.commuteMode) else {
            return
        }

        viewModel.settings.commuteMode = .car
    }

    private func scheduleRoutePreview() {
        previewTask?.cancel()
        previewTask = Task {
            guard viewModel.canPreviewRoute else {
                await MainActor.run {
                    viewModel.clearRoutePreview()
                }
                return
            }

            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else {
                return
            }

            await viewModel.previewRoute()
        }
    }

    private func scheduleRouteWeather() {
        weatherTask?.cancel()
        weatherTask = Task {
            guard viewModel.canPreviewRoute else {
                await MainActor.run {
                    viewModel.clearRouteWeather()
                }
                return
            }

            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else {
                return
            }

            await viewModel.refreshRouteWeather()
        }
    }
}

private struct AlarmTabView: View {
    private let weekdayOrder = [1, 2, 3, 4, 5, 6, 7]

    @ObservedObject var viewModel: AlarmViewModel
    @State private var alarmEnabled = true
    @State private var showsTimePicker = false
    @State private var audioPlayer: AVAudioPlayer?
    @State private var previewingSound: CommuteAlarmSettings.AlarmSound?
    @State private var soundPreviewTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("alarm")
                            .font(.title.weight(.bold))

                        VStack(alignment: .leading, spacing: 20) {
                            HStack(alignment: .top) {
                                HStack(spacing: 14) {
                                    ForEach(weekdayOrder, id: \.self) { weekday in
                                        Button {
                                            toggleWeekday(weekday)
                                        } label: {
                                            Text(label(for: weekday))
                                                .font(.title3.weight(.semibold))
                                                .foregroundStyle(viewModel.settings.selectedWeekdays.contains(weekday) ? .white : .secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                Spacer()

                                Toggle("", isOn: $alarmEnabled)
                                    .labelsHidden()
                                    .tint(.cyan)
                            }

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
                    }

                    VStack(spacing: 18) {
                        Stepper(value: $viewModel.settings.rainLeadTimeMinutes, in: 1...120, step: 1) {
                            HStack {
                                Text("rain_lead_time")
                                Spacer()
                                Text(String.localizedStringWithFormat(String(localized: "rain_lead_time_value"), viewModel.settings.rainLeadTimeMinutes))
                                    .foregroundStyle(.secondary)
                            }
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
                                    ForEach(CommuteAlarmSettings.AlarmSound.allCases) { sound in
                                        Text(sound.displayName).tag(sound)
                                    }
                                }
                            } label: {
                                Text(viewModel.settings.alarmSound.displayName)
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                toggleSelectedSoundPreview()
                            } label: {
                                Image(systemName: isPreviewingSelectedSound ? "stop.circle.fill" : "play.circle.fill")
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.cyan)
                            .accessibilityLabel(Text("preview_alarm_sound"))
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
                    .tint(.cyan)
                    .disabled(!alarmEnabled || !viewModel.canSchedule || viewModel.isScheduling)

                    Text(viewModel.statusMessage)
                        .foregroundStyle(.secondary)

                    if let summary = viewModel.scheduledAlarmSummary {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("scheduled_result")
                                .font(.headline)
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
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
            .navigationTitle(String(localized: "tab_alarm"))
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .background(Color.appBackground)
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
        .onDisappear {
            stopSoundPreview()
        }
    }

    private func toggleWeekday(_ weekday: Int) {
        if viewModel.settings.selectedWeekdays.contains(weekday) {
            viewModel.settings.selectedWeekdays.remove(weekday)
        } else {
            viewModel.settings.selectedWeekdays.insert(weekday)
        }
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

    private func timeText(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let period = hour < 12 ? String(localized: "alarm_am") : String(localized: "alarm_pm")
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        let time = "\(displayHour):\(String(format: "%02d", minute))"

        if Locale.current.language.languageCode?.identifier.hasPrefix("zh") == true {
            return "\(period)\(time)"
        }

        return "\(time) \(period)"
    }

    private var isPreviewingSelectedSound: Bool {
        previewingSound == viewModel.settings.alarmSound
    }

    private func toggleSelectedSoundPreview() {
        if isPreviewingSelectedSound {
            stopSoundPreview()
        } else {
            previewSound(viewModel.settings.alarmSound)
        }
    }

    private func previewSound(_ sound: CommuteAlarmSettings.AlarmSound) {
        stopSoundPreview()
        let soundFile = sound.fileName.split(separator: ".", maxSplits: 1).map(String.init)
        guard let resource = soundFile.first,
              let fileExtension = soundFile.dropFirst().first,
              let url = Bundle.main.url(forResource: resource, withExtension: fileExtension),
              let player = try? AVAudioPlayer(contentsOf: url) else {
            return
        }

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
    }
}

private struct RouteModePicker: View {
    @Binding var selection: CommuteAlarmSettings.CommuteMode
    let modes: [CommuteAlarmSettings.CommuteMode]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(modes) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(mode.displayName)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == mode ? .black : .white)
                .background(selection == mode ? Color.cyan : Color.appFieldBackground)
                .clipShape(Capsule())
            }
        }
    }
}

private struct AddressFieldRow: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            TextField(placeholder, text: $text, axis: .vertical)
                .textContentType(.fullStreetAddress)
                .textFieldStyle(.plain)
        }
        .padding(14)
        .background(Color.appFieldBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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

private struct RouteWeatherCard: View {
    let segment: RouteWeatherSegment

    var body: some View {
        VStack(spacing: 12) {
            Text(segment.name)
                .font(.headline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Image(systemName: segment.condition.iconName)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 42))
                .foregroundStyle(segment.condition.color)

            Text(conditionText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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

    private var conditionText: String {
        if segment.condition == .rain {
            return String.localizedStringWithFormat(
                String(localized: "precipitation_value"),
                Int(segment.precipitationProbability * 100)
            )
        }

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
        String(localized: "segment_route_placeholder"),
        String(localized: "segment_office_area")
    ]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(titles, id: \.self) { title in
                VStack(spacing: 12) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
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
