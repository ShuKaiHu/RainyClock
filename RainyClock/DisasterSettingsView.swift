import SwiftUI

enum DisasterRegionCatalog {
    static let all: [DisasterRegion] = {
        guard let url = Bundle.main.url(forResource: "taiwan-districts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([DisasterRegion].self, from: data) else { return [] }
        return values.sorted { $0.name < $1.name }
    }()
    static func matching(_ name: String?) -> DisasterRegion? {
        guard let name else { return nil }
        return all.first { DisasterRegion.normalize($0.name) == DisasterRegion.normalize(name) }
    }
}

struct DisasterSettingsView: View {
    @ObservedObject var viewModel: AlarmViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                NavigationLink { DisasterMapView(viewModel: viewModel) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "map.fill").font(.title2).foregroundStyle(Color.accentColor)
                        Text("disaster_map_title").font(.headline).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(20).background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 24))
                }.buttonStyle(.plain)
                card {
                    Toggle("settings_observe_work", isOn: $viewModel.settings.observesWorkSuspensions)
                    Toggle("settings_observe_school", isOn: $viewModel.settings.observesSchoolSuspensions)
                    if viewModel.settings.observesWorkSuspensions && viewModel.settings.observesSchoolSuspensions {
                        Text("disaster_both_rule").font(.footnote).foregroundStyle(.secondary)
                    }
                    if viewModel.settings.isDisasterSuspensionEnabled
                        && !viewModel.settings.observesWorkSuspensions && !viewModel.settings.observesSchoolSuspensions {
                        Text("disaster_choose_rule").font(.footnote).foregroundStyle(.orange)
                    }
                }
                card {
                    routeAddress("home_address", address: viewModel.settings.homeAddress,
                                 region: viewModel.homeAutomaticSuspensionRegion)
                    Divider()
                    routeAddress("work_address", address: viewModel.settings.workAddress,
                                 region: viewModel.workAutomaticSuspensionRegion)
                }
                if viewModel.settings.isDisasterSuspensionEnabled {
                    if AppEnvironment.dayOffServiceURL == nil {
                        Label("disaster_not_configured", systemImage: "wifi.exclamationmark")
                            .font(.footnote).foregroundStyle(.orange)
                    } else if viewModel.disasterRefreshFailed {
                        Label("disaster_refresh_failed", systemImage: "wifi.exclamationmark")
                            .font(.footnote).foregroundStyle(.orange)
                        Button("disaster_refresh") { Task { await viewModel.refreshDisasterSuspensions(force: true) } }
                            .disabled(viewModel.isRefreshingDisasters)
                    }
                }
                if viewModel.disasterScheduleNeedsAttention
                    || (!viewModel.settings.isDisasterSuspensionEnabled && viewModel.nextAppliedDisasterSkip != nil) {
                    Label("disaster_schedule_uncertain", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                    Button("disaster_retry_schedule") { Task { await viewModel.refreshDisasterSuspensions(force: true) } }
                        .disabled(viewModel.isRefreshingDisasters || viewModel.isScheduling)
                }
                card {
                    Link("disaster_official", destination: URL(string: "https://www.dgpa.gov.tw/typh/daily/nds.html")!)
                }
            }.padding(20)
        }
        .background(Color.appBackground)
        .navigationTitle(String(localized: "disaster_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            if viewModel.canPreviewRoute,
               viewModel.homeAutomaticSuspensionRegion == nil || viewModel.workAutomaticSuspensionRegion == nil {
                await viewModel.previewRoute()
            }
            await viewModel.refreshDisasterSuspensions()
        }
    }

    private func routeAddress(_ title: LocalizedStringKey, address: String, region: DisasterRegion?) -> some View {
        let hasAddress = !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.body.weight(.semibold))
            if hasAddress {
                Text(address).font(.body).fixedSize(horizontal: false, vertical: true)
                if let region {
                    Label(region.name, systemImage: "mappin.and.ellipse")
                        .font(.body).foregroundStyle(.secondary)
                } else {
                    Text("disaster_route_region_unavailable").font(.body).foregroundStyle(.secondary)
                }
            } else {
                Text("disaster_route_address_missing").font(.body).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 24))
    }
}

struct DisasterStatusView: View {
    @ObservedObject var viewModel: AlarmViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("disaster_title", systemImage: "cloud.bolt.rain").font(.headline)
            if viewModel.disasterScheduleNeedsAttention {
                Label("disaster_schedule_uncertain", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if let skip = viewModel.nextAppliedDisasterSkip {
                Label(String.localizedStringWithFormat(String(localized: "disaster_applied"),
                    viewModel.settings.timeFormat.dateTime(skip.normalDate)), systemImage: "bell.slash.fill")
                    .foregroundStyle(Color.accentColor)
            } else if !viewModel.hasScheduledAlarm {
                Text("disaster_no_alarm").foregroundStyle(.secondary)
            } else {
                Text("disaster_no_applied_skip").foregroundStyle(.secondary)
            }
            if viewModel.isScheduleStale {
                Label("disaster_pending", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if viewModel.isRefreshingDisasters {
                HStack { ProgressView(); Text("disaster_checking") }
            } else if AppEnvironment.dayOffServiceURL == nil {
                Text("disaster_not_configured").foregroundStyle(.orange)
            } else if viewModel.disasterRefreshFailed {
                Label("disaster_refresh_failed", systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
            } else if let checked = viewModel.disasterFeed?.checkedAt {
                Text(String.localizedStringWithFormat(String(localized: "disaster_checked"),
                    viewModel.settings.timeFormat.dateTime(checked))).foregroundStyle(.secondary)
            }
            if let plan = viewModel.scheduledAlarmSummary?.calendarPlan {
                Text(String.localizedStringWithFormat(String(localized: "calendar_coverage"),
                    plan.coveredUntil.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted)))
                    .foregroundStyle(.secondary)
                Text("calendar_coverage_hint").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
}

