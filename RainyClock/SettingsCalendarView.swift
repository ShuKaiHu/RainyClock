import SwiftUI
import UIKit
import UserNotifications

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
        .font(.body)
        .padding(18)
        .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case time, route, calendar, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .time: String(localized: "ux_category_time")
        case .route: String(localized: "ux_category_route")
        case .calendar: String(localized: "ux_category_calendar")
        case .other: String(localized: "ux_category_other")
        }
    }
}

struct SettingsNavigationRequest: Identifiable {
    let id = UUID()
    let category: SettingsCategory
    let anchor: String?
}

struct SettingsEntryRow: View {
    /// Something behind this row blocks scheduling; the text is read by VoiceOver.
    enum Attention: Equatable {
        case warning(String), error(String)
    }

    let title: LocalizedStringKey
    let icon: String
    var value: String = ""
    var attention: Attention? = nil
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 20)
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            if !value.isEmpty { Text(value).font(.body).foregroundStyle(.secondary).lineLimit(1) }
            switch attention {
            case .warning(let label):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).accessibilityLabel(label)
            case .error(let label):
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).accessibilityLabel(label)
            case nil:
                EmptyView()
            }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        }
        .font(.body).frame(minHeight: 28).padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

enum AlarmSettingsText {
    static func weekday(_ day: Int) -> String {
        let names = Calendar.current.weekdaySymbols
        return names[min(max(day - 1, 0), names.count - 1)]
    }
    static func weekdays(_ days: Set<Int>) -> String {
        if days.count == 7 { return String(localized: "ux_everyday") }
        if days == Set(2...6) { return String(localized: "ux_weekdays") }
        if days.isEmpty { return String(localized: "ux_no_repeat") }
        let names = Calendar.current.shortWeekdaySymbols
        return [2, 3, 4, 5, 6, 7, 1].filter(days.contains).map { names[$0 - 1] }.joined(separator: " ")
    }
}

@MainActor
final class NotificationAccessState: ObservableObject {
    @Published private var status: UNAuthorizationStatus?
    func refresh() async { status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    var value: String {
        switch status {
        case .authorized, .provisional, .ephemeral: String(localized: "ux_allowed")
        case .denied: String(localized: "ux_not_allowed")
        case .notDetermined: String(localized: "ux_not_requested")
        default: String(localized: "ux_checking")
        }
    }
    var summary: String { String.localizedStringWithFormat(String(localized: "ux_notification_state"), value) }
}

struct SettingsTabView: View {
    @ObservedObject var viewModel: AlarmViewModel
    @ObservedObject private var membership = MembershipManager.shared
    var showsWeatherAttribution = false
    @Binding var request: SettingsNavigationRequest?
    @State private var category: SettingsCategory = .time
    @State private var path: [Detail] = []
    @State private var settingsVisible = false
    private enum Detail: Hashable { case privacy, about, weekdays, calendarEditor, disaster, disasterMap, disasterMapDemo, membership }
    private var advancedRulesAllowed: Bool { !membership.isConfigured || membership.canUseAdvancedRules }
    /// The closure rule has its own entitlement, so it cannot ride on the calendar lock:
    /// a plan can include calendar rules and still lack this one. Whether the saved rule
    /// is applied comes from what scheduling actually uses, not from the lock.
    private var closureControl: TemporaryClosureControlState {
        .resolve(membershipConfigured: membership.isConfigured, entitlements: membership.entitlements,
                 schedulingEntitlements: membership.schedulingEntitlements,
                 savedEnabled: viewModel.settings.isDisasterSuspensionEnabled,
                 appliedEnabled: viewModel.effectiveSchedulingSettings.isDisasterSuspensionEnabled)
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 15) {
                    Text("tab_settings").font(.largeTitle.bold())
                    Picker("ux_settings_categories", selection: categorySelection) {
                        ForEach(SettingsCategory.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                }.padding(.horizontal, 20).padding(.top, 8)
                TabView(selection: categorySelection) {
                    AlarmTimeSettingsView(viewModel: viewModel, navigationRequest: category == .time ? request : nil,
                                          onNavigationRequestHandled: consumeRequest)
                        .tag(SettingsCategory.time)
                    RouteTabView(viewModel: viewModel,
                                 navigationRequest: category == .route ? request : nil, onNavigationRequestHandled: consumeRequest,
                                 isActive: settingsVisible && category == .route && path.isEmpty)
                        .tag(SettingsCategory.route)
                    calendarSettings.tag(SettingsCategory.calendar)
                    otherSettings.tag(SettingsCategory.other)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.appBackground)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Detail.self) { detail in
                Group {
                    switch detail {
                    case .privacy: PrivacySupportSettingsView()
                    case .about: AppSupportSettingsView()
                    case .weekdays: RepeatDaysSettingsView(viewModel: viewModel)
                    case .membership: MembershipView(manager: membership)
                    case .calendarEditor:
                        if advancedRulesAllowed { AlarmCalendarView(viewModel: viewModel) }
                        else { MembershipView(manager: membership) }
                    case .disaster:
                        if AppEnvironment.supportsTemporaryClosures {
                            if closureControl.allowsEditing { DisasterSettingsView(viewModel: viewModel) }
                            else { MembershipView(manager: membership) }
                        }
                    case .disasterMap:
                        if AppEnvironment.supportsTemporaryClosures {
                            if closureControl.allowsEditing { DisasterMapView(viewModel: viewModel) }
                            else { MembershipView(manager: membership) }
                        }
                    case .disasterMapDemo:
                        // Deliberately not behind any plan: App Review (2.1(a)) and people
                        // deciding whether to pay must be able to see what the rule does.
                        // Demo mode reads only the time format; it never touches the feed
                        // cache, the saved regions, the alarm or push registration.
                        if AppEnvironment.supportsTemporaryClosures { DisasterMapView(viewModel: viewModel, isDemo: true) }
                    }
                }.toolbar(.visible, for: .navigationBar)
            }
        }
        .tint(Color.accentColor)
        .onAppear { settingsVisible = true }
        .onDisappear { settingsVisible = false }
        .onChange(of: request?.id, initial: true) { _, _ in
            guard let request else { return }
            if request.anchor == "weekdays" {
                category = .calendar
                path = [.weekdays]
                consumeRequest(request.id)
                return
            }
            category = request.category
            path = []
            if request.category == .calendar || (request.category == .other && request.anchor != "permissions") {
                consumeRequest(request.id)
            }
        }
        .onChange(of: viewModel.settings.calendarSettings.isEnabled) { _, enabled in
            if enabled { Task { await viewModel.refreshHolidays() } }
        }
        .onChange(of: viewModel.settings.calendarSettings.source) { _, _ in
            Task { await viewModel.refreshHolidays() }
        }
    }

    private func consumeRequest(_ id: UUID) {
        if request?.id == id { request = nil }
    }

    private var categorySelection: Binding<SettingsCategory> {
        Binding(get: { category }, set: { value in
            guard value != category else { return }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            category = value
            path = []
            request = nil
        })
    }

    private var calendarSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                NavigationLink(value: Detail.weekdays) {
                    SettingsEntryRow(title: "ux_repeat_days", icon: "repeat",
                                     value: AlarmSettingsText.weekdays(viewModel.settings.selectedWeekdays))
                }.buttonStyle(.plain)
                    .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 22))
                Toggle("ux_use_calendar", isOn: advancedBinding(\.calendarSettings.isEnabled))
                    .padding(17).background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 22))
                if !advancedRulesAllowed {
                    Button { path.append(.membership) } label: {
                        // Calendar only: the closure rule carries its own, plan-neutral lock
                        // line below, because which plans include it is not decided here.
                        Label(MembershipText.value("訂閱或買斷可使用日曆規則", "Calendar rules are included with a subscription or one-time purchase"), systemImage: "lock")
                            .font(.subheadline)
                    }
                }
                if viewModel.settings.calendarSettings.isEnabled && advancedRulesAllowed {
                    VStack(spacing: 0) {
                        HStack {
                            Label("ux_holiday_source", systemImage: "calendar.badge.checkmark").foregroundStyle(.primary)
                            Spacer()
                            Menu {
                                Button { viewModel.settings.calendarSettings.source = .taiwan } label: {
                                    if viewModel.settings.calendarSettings.source == .taiwan {
                                        Label("calendar_source_taiwan", systemImage: "checkmark")
                                    } else {
                                        Text("calendar_source_taiwan")
                                    }
                                }
                                Button { viewModel.settings.calendarSettings.source = .unitedStates } label: {
                                    if viewModel.settings.calendarSettings.source == .unitedStates {
                                        Label("calendar_source_us", systemImage: "checkmark")
                                    } else {
                                        Text("calendar_source_us")
                                    }
                                }
                            } label: {
                                Text(viewModel.settings.calendarSettings.source.title)
                                    .foregroundStyle(.secondary)
                            }
                        }.font(.body).padding(16)
                        Divider().padding(.leading, 48)
                        NavigationLink(value: Detail.calendarEditor) {
                            SettingsEntryRow(title: "calendar_edit", icon: "calendar")
                        }.buttonStyle(.plain)
                    }.background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 22))
                    if viewModel.settings.calendarSettings.source == .taiwan && viewModel.holidayRefreshFailed {
                        HStack {
                            Label("calendar_refresh_failed", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button("ux_retry") { Task { await viewModel.refreshHolidays(force: true) } }.font(.caption)
                        }
                    }
                    if viewModel.settings.calendarSettings.source == .taiwan {
                        Link("calendar_source_credit", destination: URL(string: "https://data.gov.tw/dataset/14718")!)
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if viewModel.settings.calendarSettings.source == .unitedStates {
                        Text("calendar_us_scope").font(.caption).foregroundStyle(.secondary)
                        Link("calendar_source_us_credit", destination: URL(string: "https://www.opm.gov/policy-data-oversight/pay-leave/federal-holidays/")!)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if AppEnvironment.supportsTemporaryClosures {
                    // A locked switch keeps showing the saved value (it is never cleared).
                    // It can always be turned off; turning it on needs the entitlement.
                    Toggle("ux_use_closure_rules", isOn: closureBinding)
                        .disabled(!closureControl.allowsToggle)
                        .padding(17).background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 22))
                    switch closureControl.access {
                    case .available:
                        EmptyView()
                    case .locked:
                        if closureControl.offersPlans {
                            Button { path.append(.membership) } label: {
                                Label("ux_closure_plan_locked", systemImage: "lock").font(.subheadline)
                            }
                        } else {
                            Label("ux_closure_plan_locked", systemImage: "lock")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    case .unconfirmed:
                        Label("ux_closure_plan_unconfirmed", systemImage: "clock")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if closureControl.keepsSavedRuleUnapplied {
                        Text("ux_closure_saved_not_applied")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if closureControl.savedRuleStillApplied {
                        Text("ux_closure_saved_still_applied")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: 0) {
                        if viewModel.settings.isDisasterSuspensionEnabled && closureControl.allowsEditing {
                            NavigationLink(value: Detail.disaster) {
                                SettingsEntryRow(title: "ux_disaster_preferences", icon: "cloud.bolt.rain")
                            }.buttonStyle(.plain)
                            Divider().padding(.leading, 48)
                            NavigationLink(value: Detail.disasterMap) {
                                SettingsEntryRow(title: "disaster_map_title", icon: "map")
                            }.buttonStyle(.plain)
                            Divider().padding(.leading, 48)
                        }
                        // Always present, with or without a plan or the switch: sample
                        // announcements, labelled "Demo data · Not live" on the map itself.
                        NavigationLink(value: Detail.disasterMapDemo) {
                            SettingsEntryRow(title: "disaster_map_show_demo", icon: "play.rectangle")
                        }.buttonStyle(.plain)
                    }.background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 22))
                }
            }.padding(.horizontal, 20).padding(.bottom, 20)
        }.task(id: category) {
            if category == .calendar { await viewModel.refreshHolidays() }
        }
    }

    private var otherSettings: some View {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                NavigationLink(value: Detail.membership) {
                    SettingsEntryRow(title: "membership_title", icon: "person.crop.circle",
                        value: membership.entitlements.lifetimeActive
                            ? MembershipText.value("已買斷", "Purchased")
                            : membership.entitlements.subscriptionActive ? MembershipText.value("已訂閱", "Subscribed") : "")
                }.buttonStyle(.plain)
                    .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 22))
                Text("ux_support").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                VStack(spacing: 0) {
                    NavigationLink(value: Detail.privacy) {
                        SettingsEntryRow(title: "ux_privacy_ads", icon: "hand.raised")
                    }.buttonStyle(.plain)
                    Divider().padding(.leading, 48)
                    NavigationLink(value: Detail.about) {
                        SettingsEntryRow(title: "ux_help_about", icon: "questionmark.circle")
                    }.buttonStyle(.plain)
                }.background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 22))
                Text("ux_notifications_background").font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).id("permissions")
                NotificationBackgroundSettingsCard()
            }.padding(.horizontal, 20).padding(.bottom, 20)
          }
          .task(id: request?.id) {
              guard let request, request.category == .other, request.anchor == "permissions" else { return }
              await Task.yield()
              guard !Task.isCancelled else { return }
              proxy.scrollTo("permissions", anchor: .top)
              consumeRequest(request.id)
          }
        }
    }

    private var closureBinding: Binding<Bool> {
        Binding(get: { viewModel.settings.isDisasterSuspensionEnabled }, set: { enabled in
            // Turning it off never needs a plan. Turning it on without one only
            // offers the plans, where there is something to buy.
            guard enabled, !closureControl.allowsEditing else {
                viewModel.settings.isDisasterSuspensionEnabled = enabled
                return
            }
            if closureControl.offersPlans { path.append(.membership) }
        })
    }

    private func advancedBinding(_ keyPath: WritableKeyPath<CommuteAlarmSettings, Bool>) -> Binding<Bool> {
        Binding(get: { viewModel.settings[keyPath: keyPath] }, set: { enabled in
            guard advancedRulesAllowed else { path.append(.membership); return }
            viewModel.settings[keyPath: keyPath] = enabled
        })
    }
}

private struct RepeatDaysSettingsView: View {
    @ObservedObject var viewModel: AlarmViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                    Toggle(AlarmSettingsText.weekday(day), isOn: Binding(
                        get: { viewModel.settings.selectedWeekdays.contains(day) },
                        set: { selected in
                            if selected { viewModel.settings.selectedWeekdays.insert(day) }
                            else { viewModel.settings.selectedWeekdays.remove(day) }
                        }))
                        .padding(16)
                    if day != 1 { Divider().padding(.horizontal, 16) }
                }
            }
            .font(.body)
            .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 22))
            .padding(20)
        }
        .background(Color.appBackground)
        .navigationTitle(String(localized: "ux_repeat_days"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NotificationBackgroundSettingsCard: View {
    @StateObject private var access = NotificationAccessState()
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
            VStack(spacing: 16) {
                VStack(spacing: 16) {
                    HStack { Text("ux_notifications"); Spacer(); Text(access.value).foregroundStyle(.secondary) }
                    Divider()
                    HStack { Text("ux_background_refresh"); Spacer(); Text(AlarmViewModel.systemCanRefreshInBackground() ? "ux_available" : "ux_limited").foregroundStyle(.secondary) }
                }.font(.body)
                Divider()
                Button("settings_system_permissions") {
                    openURL(URL(string: UIApplication.openSettingsURLString)!)
                }.font(.body).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(18).background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 22))
            .task { await access.refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await access.refresh() } } }
    }
}

private struct PrivacySupportSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                AdSupportCard()
                Link(destination: URL(string: "https://shukaihu.github.io/RainyClock/privacy-policy.html")!) {
                    SettingsEntryRow(title: "settings_privacy", icon: "doc.text")
                }.background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 22))
            }.padding(20)
        }.background(Color.appBackground)
            .navigationTitle(String(localized: "ux_privacy_ads")).navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppSupportSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("ux_help_text").font(.body).lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                    .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 22))
                VStack(spacing: 0) {
                    Link(destination: URL(string: "https://shukaihu.github.io/RainyClock/support.html")!) {
                        SettingsEntryRow(title: "settings_support", icon: "envelope")
                    }
                    Divider().padding(.leading, 48)
                    HStack {
                        Text("settings_version")
                        Spacer()
                        Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                            .foregroundStyle(.secondary)
                    }.font(.body).padding(16)
                }.background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 22))
            }.padding(20)
        }.background(Color.appBackground)
            .navigationTitle(String(localized: "ux_help_about")).navigationBarTitleDisplayMode(.inline)
    }
}

struct AlarmCalendarView: View {
    @ObservedObject var viewModel: AlarmViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var month = AlarmCalendarSettings.calendar.dateInterval(of: .month, for: Date())!.start
    private var calendar: Calendar { AlarmCalendarSettings.calendar }
    private var year: Int { calendar.component(.year, from: month) }
    private var years: [Int] {
        let current = calendar.component(.year, from: Date())
        return Array(current...(current + 1))
    }
    private var months: [Date] {
        years.flatMap { year in
            (1...12).compactMap { calendar.date(from: DateComponents(year: year, month: $0, day: 1)) }
        }
    }
    private func dates(in month: Date) -> [Date] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        return range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
    }
    private var weekdays: [String] {
        let names = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { names[($0 + calendar.firstWeekday - 1) % 7] }
    }

    var body: some View {
        GeometryReader { geometry in
            let isShort = geometry.size.height < 350
            Group {
                if isShort {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 18) {
                            monthControls
                            legend(vertical: true)
                        }.frame(width: max(145, geometry.size.width * 0.24))
                        monthPages(availableHeight: geometry.size.height - 28)
                    }
                } else {
                    VStack(spacing: 16) {
                        monthControls
                        monthPages(availableHeight: geometry.size.height - 28 - 44 - 24 - 32)
                        legend(vertical: false)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color.appBackground)
        .navigationTitle(String(localized: "calendar_edit"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("calendar_today", action: goToToday)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("calendar_done") { dismiss() }
                    .fontWeight(.semibold)
            }
        }
    }

    private var monthControls: some View {
        HStack(spacing: 4) {
            Button { changeMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 44) }
                .accessibilityLabel(Text("calendar_previous_month"))
                .disabled(year == years.first && calendar.component(.month, from: month) == 1)
            Spacer(minLength: 0)
            Menu {
                ForEach(years, id: \.self) { value in
                    Button(String(value)) {
                        showMonth(calendar.date(from: DateComponents(year: value, month: calendar.component(.month, from: month), day: 1))!)
                    }
                }
            } label: {
                Text(month.formatted(.dateTime.year().month(.wide)))
                    .font(.title3.bold()).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .lineLimit(1).minimumScaleFactor(0.65).foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
            Button { changeMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 44) }
                .accessibilityLabel(Text("calendar_next_month"))
                .disabled(year == years.last && calendar.component(.month, from: month) == 12)
        }.frame(height: 44)
    }

    private func monthPages(availableHeight: CGFloat) -> some View {
        let pageHeight = max(0, min(availableHeight, 22 + 6 * (68 + 6)))
        // Stable page identities let the native pager follow the finger without fading date cells.
        return TabView(selection: $month) {
            ForEach(months, id: \.self) { pageMonth in
                monthGrid(for: pageMonth, availableHeight: pageHeight)
                    .padding(.horizontal, 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .tag(pageMonth)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: pageHeight)
    }

    private func monthGrid(for month: Date, availableHeight: CGFloat) -> some View {
        let dates = dates(in: month)
        let leadingBlanks = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let weekCount = (leadingBlanks + dates.count + 6) / 7
        let spacing: CGFloat = 6
        let height = max(18, min(68, (availableHeight - 22 - CGFloat(weekCount) * spacing) / CGFloat(weekCount)))
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: spacing) {
            ForEach(Array(weekdays.enumerated()), id: \.offset) { _, name in
                Text(name).font(.caption).foregroundStyle(.secondary).frame(height: 22)
            }
            ForEach(0..<leadingBlanks, id: \.self) { _ in Color.clear.frame(height: height) }
            ForEach(dates, id: \.self) { day in dayCell(day, height: height) }
        }
    }

    private func legend(vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 18))
        return layout {
            Label("calendar_ring", systemImage: "bell.fill").foregroundStyle(Color.accentColor)
            Label("calendar_silent", systemImage: "bell.slash").foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Circle().fill(.orange).frame(width: 5, height: 5)
                Text("calendar_manual").foregroundStyle(.orange)
            }
        }.font(.caption).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .lineLimit(1).minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayCell(_ day: Date, height: CGFloat) -> some View {
        let decision = viewModel.dayDecision(on: day)
        let custom = viewModel.calendarDayIsEdited(day)
        let isToday = calendar.isDateInToday(day)
        return Button { viewModel.toggleCalendarDay(day) } label: {
            Group {
                if height < 46 {
                    HStack(spacing: 3) {
                        Text(String(calendar.component(.day, from: day)))
                            .font(.system(size: min(17, max(12, height * 0.6)), weight: .semibold, design: .rounded))
                        Image(systemName: decision.rings ? "bell.fill" : "bell.slash").font(.system(size: 9))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        Circle().fill(custom ? Color.orange : .clear).frame(width: 4, height: 4).padding(3)
                    }
                } else {
                    VStack(spacing: 5) {
                        Text(String(calendar.component(.day, from: day))).font(.system(size: 17, weight: .semibold, design: .rounded))
                        Image(systemName: decision.rings ? "bell.fill" : "bell.slash").font(.system(size: 12))
                        Circle().fill(custom ? Color.orange : .clear).frame(width: 4, height: 4)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: height)
            .foregroundStyle(decision.rings ? Color.accentColor : Color.secondary)
            .background(decision.rings ? Color.accentColor.opacity(0.13) : Color.appCardBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isToday ? Color.accentColor : .clear, lineWidth: 2))
            .opacity(isPast(day) ? 0.35 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(isPast(day))
        .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)), \(decision.title)\(custom ? ", " + String(localized: "calendar_manual") : "")")
        .accessibilityHint(Text("calendar_tap_hint"))
    }

    private func isPast(_ day: Date) -> Bool { day < calendar.startOfDay(for: Date()) }
    private func goToToday() {
        showMonth(calendar.dateInterval(of: .month, for: Date())!.start)
    }
    private func changeMonth(_ delta: Int) {
        guard let value = calendar.date(byAdding: .month, value: delta, to: month), years.contains(calendar.component(.year, from: value)) else { return }
        showMonth(value)
    }
    private func showMonth(_ value: Date) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            month = value
        }
    }
}

/// Both alarm and preview time pickers share the user's explicit hour cycle.
/// Binding edits are saved immediately; swipe down or close to return.
struct ClockTimePicker: View {
    @Binding var time: Date
    let format: ClockTimeFormat
    let title: String
    var formatSelection: Binding<ClockTimeFormat>? = nil
    @Environment(\.dismiss) private var dismiss
    private var calendar: Calendar { AlarmCalendarSettings.calendar }
    private var hour: Int { calendar.component(.hour, from: time) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
            HStack(spacing: 0) {
                if format == .twelveHour {
                    Picker("clock_period", selection: Binding(get: { hour / 12 }, set: { set(hour: hour % 12 + $0 * 12) })) {
                        Text("clock_am").tag(0)
                        Text("clock_pm").tag(1)
                    }.accessibilityLabel(Text("clock_period"))
                }
                Picker("clock_hour", selection: Binding(
                    get: { format == .twentyFourHour ? hour : (hour % 12 == 0 ? 12 : hour % 12) },
                    set: { set(hour: format == .twentyFourHour ? $0 : $0 % 12 + (hour / 12) * 12) }
                )) {
                    ForEach(format == .twentyFourHour ? Array(0...23) : Array(1...12), id: \.self) { value in
                        Text(format == .twentyFourHour ? String(format: "%02d", value) : String(value)).tag(value)
                    }
                }.accessibilityLabel(Text("clock_hour"))
                Picker("clock_minute", selection: Binding(get: { calendar.component(.minute, from: time) }, set: { set(minute: $0) })) {
                    ForEach(0..<60) { Text(String(format: "%02d", $0)).tag($0) }
                }.accessibilityLabel(Text("clock_minute"))
            }
            .pickerStyle(.wheel).labelsHidden().padding(.horizontal, 12)
            if let formatSelection {
                Picker("clock_format_header", selection: formatSelection) {
                    ForEach(ClockTimeFormat.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 16)
            }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("clock_close"))
                }
            }
        }
        .presentationDetents([.height(formatSelection == nil ? 320 : 385)])
        .presentationDragIndicator(.visible)
    }

    private func set(hour: Int? = nil, minute: Int? = nil) {
        time = calendar.date(bySettingHour: hour ?? self.hour,
                             minute: minute ?? calendar.component(.minute, from: time), second: 0, of: time) ?? time
    }
}
