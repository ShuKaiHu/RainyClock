import SwiftUI

struct ContentView: View {
    @StateObject var viewModel: AlarmViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Commute") {
                    TextField("Home address", text: $viewModel.settings.homeAddress, axis: .vertical)
                        .textContentType(.fullStreetAddress)
                    TextField("Work address", text: $viewModel.settings.workAddress, axis: .vertical)
                        .textContentType(.fullStreetAddress)
                }

                Section("Alarm") {
                    DatePicker("Normal alarm", selection: $viewModel.settings.alarmTime, displayedComponents: .hourAndMinute)
                    Stepper(value: $viewModel.settings.rainLeadTimeMinutes, in: 5...120, step: 5) {
                        HStack {
                            Text("Rain lead time")
                            Spacer()
                            Text("\(viewModel.settings.rainLeadTimeMinutes) min")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button {
                        Task { await viewModel.evaluateRouteAndScheduleAlarm() }
                    } label: {
                        Label(viewModel.isScheduling ? "Checking route..." : "Schedule Smart Alarm", systemImage: "alarm")
                    }
                    .disabled(!viewModel.canSchedule || viewModel.isScheduling)

                    Text(viewModel.statusMessage)
                        .foregroundStyle(.secondary)
                }

                if let summary = viewModel.scheduledAlarmSummary {
                    Section("Scheduled Result") {
                        LabeledContent("Normal alarm", value: summary.normalAlarmDate.formatted(date: .omitted, time: .shortened))
                        LabeledContent("Scheduled alarm", value: summary.scheduledAlarmDate.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Rain adjustment", value: summary.rainDetected ? "\(summary.leadTimeMinutes) min earlier" : "Not applied")
                    }
                }

                if let snapshot = viewModel.routeWeatherSnapshot {
                    Section("Route Weather") {
                        ForEach(snapshot.segments) { segment in
                            HStack {
                                Image(systemName: iconName(for: segment.condition))
                                    .foregroundStyle(color(for: segment.condition))
                                    .frame(width: 28)
                                VStack(alignment: .leading) {
                                    Text(segment.name)
                                    Text("\(Int(segment.precipitationProbability * 100))% precipitation")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Jack Clock")
        }
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
