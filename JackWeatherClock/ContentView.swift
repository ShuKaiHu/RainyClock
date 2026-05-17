import SwiftUI

struct ContentView: View {
    @StateObject var viewModel: AlarmViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("commute") {
                    TextField("home_address", text: $viewModel.settings.homeAddress, axis: .vertical)
                        .textContentType(.fullStreetAddress)
                    TextField("work_address", text: $viewModel.settings.workAddress, axis: .vertical)
                        .textContentType(.fullStreetAddress)
                    Picker("mode", selection: $viewModel.settings.commuteMode) {
                        ForEach(CommuteAlarmSettings.CommuteMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }

                Section("alarm") {
                    DatePicker("normal_alarm", selection: $viewModel.settings.alarmTime, displayedComponents: .hourAndMinute)
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
                }

                Section {
                    Button {
                        Task { await viewModel.evaluateRouteAndScheduleAlarm() }
                    } label: {
                        Label(
                            viewModel.isScheduling ? String(localized: "checking_route") : String(localized: "schedule_smart_alarm"),
                            systemImage: "alarm"
                        )
                    }
                    .disabled(!viewModel.canSchedule || viewModel.isScheduling)

                    Text(viewModel.statusMessage)
                        .foregroundStyle(.secondary)
                }

                if let summary = viewModel.scheduledAlarmSummary {
                    Section("scheduled_result") {
                        LabeledContent("normal_alarm", value: summary.normalAlarmDate.formatted(date: .omitted, time: .shortened))
                        LabeledContent("scheduled_alarm", value: summary.scheduledAlarmDate.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("weather_refresh", value: summary.weatherRefreshDate.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("rain_threshold", value: "\(Int(summary.rainProbabilityThreshold * 100))%")
                        LabeledContent("route_max", value: "\(Int(summary.maximumPrecipitationProbability * 100))%")
                        LabeledContent("rain_adjustment", value: rainAdjustmentText(for: summary))
                    }
                }

                if let snapshot = viewModel.routeWeatherSnapshot {
                    Section("route_weather") {
                        ForEach(snapshot.segments) { segment in
                            HStack {
                                Image(systemName: iconName(for: segment.condition))
                                    .foregroundStyle(color(for: segment.condition))
                                    .frame(width: 28)
                                VStack(alignment: .leading) {
                                    Text(segment.name)
                                    Text(String.localizedStringWithFormat(String(localized: "precipitation_value"), Int(segment.precipitationProbability * 100)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "app_title"))
        }
    }

    private func rainAdjustmentText(for summary: ScheduledAlarmSummary) -> String {
        guard summary.exceedsRainThreshold else {
            return String(localized: "not_applied")
        }

        return String.localizedStringWithFormat(String(localized: "minutes_earlier"), summary.leadTimeMinutes)
    }

    private func iconName(for condition: RouteWeatherSegment.Condition) -> String {
        switch condition {
        case .clear:
            "sun.max.fill"
        case .cloudy:
            "cloud.fill"
        case .rain:
            "cloud.rain.fill"
        }
    }

    private func color(for condition: RouteWeatherSegment.Condition) -> Color {
        switch condition {
        case .clear:
            .yellow
        case .cloudy:
            .gray
        case .rain:
            .blue
        }
    }
}

#Preview {
    ContentView(viewModel: AlarmViewModel())
}
