import SwiftUI

/// Announcement browsing is separate from alarm settings. Map selection never
/// changes either saved region or the user's alarm schedule.
struct DisasterMapView: View {
    @ObservedObject var viewModel: AlarmViewModel
    private let isDemo: Bool
    @State private var day = 0
    @State private var now = Date()
    @State private var demoFeed: DisasterFeed?
    @State private var feed: DisasterFeed?
    @State private var sourceFailed = false
    @State private var isLoading = false
    @State private var statuses: [DisasterRegion: DisasterMapStatus] = [:]
    @State private var focusedCounty: String?
    @State private var selectedRegion: DisasterRegion?
    @State private var showsList = false
    @State private var showsDetail = false

    init(viewModel: AlarmViewModel, isDemo: Bool = false, initialCounty: String? = nil) {
        self.viewModel = viewModel
        // Demo mode ships in Release: it is the reviewer-visible example the spec (§7) and
        // App Review 2.1(a) require. It shows only `DisasterMapDemo` and the orange
        // "Demo data · Not live" banner, and it neither fetches nor stores anything.
        self.isDemo = isDemo
        _demoFeed = State(initialValue: isDemo ? DisasterMapDemo.feed(now: Date()) : nil)
        _feed = State(initialValue: viewModel.disasterFeed)
        _focusedCounty = State(initialValue: initialCounty)
    }

    private var selectedDate: Date {
        let calendar = DisasterNoticeParser.taipeiCalendar
        return calendar.date(byAdding: .day, value: day, to: calendar.startOfDay(for: now))!
    }
    private var activeFeed: DisasterFeed? { isDemo ? demoFeed : feed }
    private var home: DisasterRegion? { isDemo ? .init(county: "新北市", district: "新店區") : viewModel.settings.homeSuspensionRegion }
    private var work: DisasterRegion? { isDemo ? .init(county: "臺北市", district: "信義區") : viewModel.settings.workSuspensionRegion }
    private var statusKey: String {
        "\(day)|\(Int(now.timeIntervalSince1970 / 60))|\(isDemo)|\(sourceFailed)|\(activeFeed?.revision ?? "")|\(activeFeed?.checkedAt.timeIntervalSince1970 ?? 0)"
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    if isDemo {
                        Label("disaster_map_demo_not_live", systemImage: "play.rectangle")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    dateControls
                    mapCard(height: max(235, min(410, geometry.size.height - (selectedRegion == nil ? 380 : 460))))
                    HStack(spacing: 10) {
                        placeButton("settings_home_region", icon: "house.fill", region: home)
                        placeButton("settings_work_region", icon: "building.2.fill", region: work)
                    }
                    if let selectedRegion { detailButton(for: selectedRegion) }
                }.padding(20)
            }
        }
        .background(Color.appBackground)
        .navigationTitle(String(localized: "disaster_map_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await refresh() }
        .task(id: statusKey) { await rebuildStatuses() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
        .sheet(isPresented: $showsList) { regionList }
        .sheet(isPresented: $showsDetail) {
            if let selectedRegion { announcementDetail(for: selectedRegion) }
        }
    }

    private var dateControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("disaster_map_date", selection: $day) {
                Text("disaster_map_today").tag(0)
                Text("disaster_map_tomorrow").tag(1)
            }.pickerStyle(.segmented)
            HStack(alignment: .firstTextBaseline) {
                Text(selectedDate.formatted(.dateTime.month().day().weekday(.abbreviated)))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                else {
                    Text(sourceLabel).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel(Text("disaster_refresh"))
                }
            }
        }
    }

    private var sourceLabel: String {
        if isDemo { return String(localized: "disaster_map_demo_source") }
        if sourceFailed || activeFeed == nil { return String(localized: "disaster_map_source_unavailable") }
        guard let checked = activeFeed?.checkedAt, now.timeIntervalSince(checked) <= 900 else {
            return String(localized: "disaster_map_source_stale")
        }
        return String.localizedStringWithFormat(String(localized: "disaster_map_updated"),
            viewModel.settings.timeFormat.time(checked))
    }

    private func mapCard(height: CGFloat) -> some View {
        VStack(spacing: 12) {
            HStack {
                Menu {
                    Button("disaster_map_all_taiwan") { focusedCounty = nil; selectedRegion = nil }
                    ForEach(DisasterRegion.counties, id: \.self) { county in
                        Button(county) { focusedCounty = county; selectedRegion = nil }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(focusedCounty ?? String(localized: "disaster_map_all_taiwan")).font(.subheadline.bold())
                        Image(systemName: "chevron.down").font(.caption2.bold())
                    }
                }
                Spacer()
                if focusedCounty != nil {
                    Button("disaster_map_all_taiwan") { focusedCounty = nil; selectedRegion = nil }
                        .font(.caption)
                } else {
                    Text("disaster_map_tap_county").font(.caption).foregroundStyle(.secondary)
                }
            }
            TaiwanDisasterMap(statuses: statuses, home: home, work: work,
                focusedCounty: $focusedCounty, selectedRegion: $selectedRegion)
                .frame(height: height)
            Divider()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 10) {
                ForEach(Array(DisasterMapState.legend.enumerated()), id: \.offset) { _, state in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(state.mapColor).frame(width: 10, height: 10)
                        Text(state.mapTitle).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                    }.accessibilityElement(children: .combine)
                }
            }
            HStack {
                Link("disaster_map_boundary_credit", destination: URL(string: "https://data.gov.tw/dataset/7441")!)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { showsList = true } label: {
                    Label("disaster_map_browse_regions", systemImage: "list.bullet")
                }
            }.font(.caption2)
            // Every surface that can say "suspended" names the source and its own update
            // time (spec §7), not only the fetch time shown in `sourceLabel`. The demo's
            // announcements are fictional, so it credits no agency and shows no update time.
            if !isDemo {
                DisasterSourceFooter(sourceUpdatedAt: activeFeed?.sourceUpdatedAt,
                                     timeFormat: viewModel.settings.timeFormat, includesDisclaimer: false)
            }
        }.padding(16).background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 24))
    }

    private func placeButton(_ title: LocalizedStringKey, icon: String, region: DisasterRegion?) -> some View {
        Button {
            if let region { focusedCounty = region.county; selectedRegion = region }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                Label(title, systemImage: icon).font(.caption).foregroundStyle(Color.accentColor)
                Text(region?.name ?? String(localized: "disaster_map_place_missing"))
                    .font(.subheadline.bold()).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.75)
                statusLabel(region.flatMap { statuses[$0] }?.state ?? .unknown).font(.caption)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(15)
                .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).disabled(region == nil)
    }

    private func detailButton(for region: DisasterRegion) -> some View {
        Button { showsDetail = true } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(region.name).font(.subheadline.bold()).foregroundStyle(.primary)
                    statusLabel(statuses[region]?.state ?? .unknown).font(.caption)
                }
                Spacer()
                Text("disaster_map_view_announcement").font(.caption)
                Image(systemName: "chevron.right").font(.caption)
            }.padding(16).background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain)
    }

    private func statusLabel(_ state: DisasterMapState) -> some View {
        Label(state.mapTitle, systemImage: state.mapIcon).foregroundStyle(state.mapColor)
    }

    private var regionList: some View {
        NavigationStack {
            List {
                ForEach(focusedCounty.map { [$0] } ?? DisasterRegion.counties, id: \.self) { county in
                    Section(county) {
                        ForEach(DisasterRegionCatalog.all.filter { $0.county == county }, id: \.self) { region in
                            Button {
                                focusedCounty = county; selectedRegion = region; showsList = false
                            } label: {
                                HStack {
                                    Text(region.district).foregroundStyle(.primary)
                                    Spacer()
                                    statusLabel(statuses[region]?.state ?? .unknown).font(.caption)
                                }
                            }
                        }
                    }
                }
            }.navigationTitle(String(localized: "disaster_map_browse_regions"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("clock_close") { showsList = false } } }
        }.preferredColorScheme(.dark)
    }

    private func announcementDetail(for region: DisasterRegion) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if isDemo { Label("disaster_map_demo_not_live", systemImage: "play.rectangle").foregroundStyle(.orange) }
                    Text(region.name).font(.title2.bold())
                    Text(selectedDate.formatted(.dateTime.month().day().weekday(.wide))).foregroundStyle(.secondary)
                    statusLabel(statuses[region]?.state ?? .unknown).font(.headline)
                    if let notice = statuses[region]?.latestNotice {
                        Text(notice.description).font(.body).textSelection(.enabled)
                        Text(String.localizedStringWithFormat(String(localized: "disaster_map_announced"),
                            viewModel.settings.timeFormat.dateTime(notice.sentAt)))
                            .font(.caption).foregroundStyle(.secondary)
                    } else { Text("disaster_map_no_announcement").foregroundStyle(.secondary) }
                    Link("disaster_official", destination: URL(string: "https://www.dgpa.gov.tw/typh/daily/nds.html")!)
                    if isDemo {
                        Text("disaster_map_demo_source").font(.caption).foregroundStyle(.secondary)
                    } else {
                        DisasterSourceFooter(sourceUpdatedAt: activeFeed?.sourceUpdatedAt,
                                             timeFormat: viewModel.settings.timeFormat)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }.background(Color.appBackground)
                .navigationTitle(String(localized: "disaster_map_announcement"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("clock_close") { showsDetail = false } } }
        }.preferredColorScheme(.dark).presentationDetents([.medium, .large])
    }

    private func refresh() async {
        guard !isLoading else { return }
        // Never reaches the network or `viewModel`, so a demo cannot overwrite the
        // real announcement cache, the alarm plan or push registration.
        if isDemo { now = Date(); demoFeed = DisasterMapDemo.feed(now: now); return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await DisasterFeedClient(endpoint: AppEnvironment.dayOffServiceURL?.appendingPathComponent("v1/suspensions")).fetch()
            guard !Task.isCancelled else { return }
            feed = fresh; sourceFailed = false; now = Date()
        } catch {
            guard !Task.isCancelled else { return }
            sourceFailed = true; now = Date()
        }
    }

    private func rebuildStatuses() async {
        let feed = activeFeed, date = selectedDate, timestamp = now, failed = !isDemo && sourceFailed
        let regions = DisasterRegionCatalog.all
        let values = await Task.detached(priority: .userInitiated) {
            DisasterMapStatus.resolve(regions: regions, date: date, feed: feed, now: timestamp, sourceFailed: failed)
        }.value
        guard !Task.isCancelled else { return }
        statuses = values
    }
}

extension DisasterMapState {
    static let legend: [Self] = [.normal, .closed, .schoolOnly, .workOnly, .partial, .unknown]
    var mapTitle: String {
        switch self {
        case .normal: String(localized: "disaster_map_normal")
        case .closed: String(localized: "disaster_map_closed")
        case .schoolOnly: String(localized: "disaster_map_school_only")
        case .workOnly: String(localized: "disaster_map_work_only")
        case .partial: String(localized: "disaster_map_partial")
        case .unknown: String(localized: "disaster_map_unknown")
        }
    }
    var mapColor: Color {
        switch self {
        case .normal: Color(red: 0.196, green: 0.549, blue: 0.471)
        case .closed: Color(red: 0.906, green: 0.475, blue: 0.471)
        case .schoolOnly: Color(red: 0.871, green: 0.651, blue: 0.341)
        case .workOnly: Color(red: 0.651, green: 0.576, blue: 0.831)
        case .partial: Color(red: 0.8, green: 0.502, blue: 0.306)
        case .unknown: Color(red: 0.40, green: 0.43, blue: 0.49)
        }
    }
    var mapIcon: String {
        switch self {
        case .normal: "checkmark.circle.fill"
        case .closed: "pause.circle.fill"
        case .schoolOnly: "graduationcap.fill"
        case .workOnly: "briefcase.fill"
        case .partial: "clock.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

/// Fictional examples, never written to the real feed cache or alarm model. The notice
/// text deliberately omits the agency sign-off real announcements end with.
enum DisasterMapDemo {
    static func feed(now: Date) -> DisasterFeed {
        let sent = now
        var notices: [DisasterNotice] = []
        for offset in 0...1 {
            let token = offset == 0 ? "今天" : "明天"
            for (index, county) in DisasterRegion.counties.enumerated() where county != "連江縣" && county != "新北市" {
                var text = "照常上班、照常上課", severity = "Minor"
                if ["臺北市", "基隆市", "宜蘭縣"].contains(county) || (offset == 1 && county == "桃園市") {
                    text = "停止上班、停止上課"; severity = "Extreme"
                } else if county == "桃園市" { text = "照常上班、停止上課"; severity = "Severe" }
                else if county == "臺東縣" { text = "停止上班、照常上課"; severity = "Extreme" }
                else if county == "花蓮縣" { text = "上午停止上班、停止上課"; severity = "Extreme" }
                notices.append(.init(id: "example-\(offset)-\(index)", sentAt: sent,
                    description: "[停班停課通知]\(county):\(token)\(text)。", severity: severity))
            }
            for region in DisasterRegionCatalog.all where region.county == "新北市" {
                let district = region.district
                let closed = ["新店區", "烏來區", "坪林區", "石碇區", "三峽區"].contains(district)
                let text = closed ? "停止上班、停止上課" : "照常上班、照常上課"
                notices.append(.init(id: "example-local-\(offset)-\(district)", sentAt: sent,
                    description: "[停班停課通知]新北市\(district):\(token)\(text)。", severity: closed ? "Extreme" : "Minor"))
            }
        }
        return .init(revision: String(repeating: "d", count: 64), checkedAt: now, sourceUpdatedAt: sent, notices: notices)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        DisasterMapView(viewModel: AlarmViewModel(settingsStorage: UserDefaults(suiteName: "DisasterMapPreview")!), isDemo: true)
    }.preferredColorScheme(.dark)
}
#endif
