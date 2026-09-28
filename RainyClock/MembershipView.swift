import SwiftUI
import StoreKit

struct MembershipView: View {
    @ObservedObject var manager: MembershipManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmsDeletion = false
    @State private var managementError: String?
    @State private var operationError: String?
    @State private var showsPriceInspection = false
    #if DEBUG
    @State private var isRequestingSandboxRefund = false
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard
                if let message = managementError ?? manager.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                if let diagnostic = manager.diagnosticSummary {
                    Text(diagnostic).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if manager.isLocalStoreKitTesting {
                    Label(text("StoreKit 本機測試・不會收費，也不會增加正式 AI 額度", "Local StoreKit test · No charge or production AI credits"), systemImage: "testtube.2")
                        .font(.footnote).foregroundStyle(.orange)
                } else if !manager.isConfigured {
                    Text(text("方案尚未開放購買", "Plans are not available for purchase yet"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if manager.isLoadingProducts {
                    ProgressView(text("正在更新價格…", "Updating prices…"))
                        .font(.footnote)
                } else if let message = manager.productMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                        Button(text("重試價格", "Retry prices")) {
                            Task { await manager.refreshPrices() }
                        }
                    }
                }
                ForEach(MembershipPlan.offeredPlans) { plan in planCard(plan) }
                Text(text("付費方案每日內含一次 AI 鈴聲生成。額外生成每次須完成一次獎勵廣告，或等隔天；播放已儲存的鈴聲不扣次數。", "Paid plans include one AI ringtone generation each day. Each extra generation requires a rewarded ad, or you can wait until tomorrow. Playing saved audio does not use a generation."))
                    .font(.footnote).foregroundStyle(.secondary)
                legal
            }.padding(20)
        }
        .background(Color.appBackground)
        .navigationTitle(text("會員與方案", "Membership & plans"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                membershipMenu
            }
        }
        .task {
            await manager.start()
            await manager.refreshAfterManagingSubscriptions()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await manager.refreshAfterManagingSubscriptions() } }
        }
        .onChange(of: manager.isBusy) { _, busy in
            if busy { managementError = nil }
        }
        .onChange(of: manager.manualOperationFailure) { _, failure in
            // Manual actions may begin below the fold. Their result is kept
            // separate from background refreshes triggered by Apple's sheet.
            if let failure { operationError = failure }
        }
        .sheet(isPresented: $showsPriceInspection) {
            NavigationStack {
                MembershipPriceInspectionView(manager: manager)
            }
        }
        .alert(text("無法完成會員操作", "Membership action could not be completed"), isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button(text("好", "OK"), role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
        .confirmationDialog(text("刪除會員資料？", "Delete membership data?"), isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button(text("刪除會員資料", "Delete membership data"), role: .destructive) {
                Task { await manager.deleteMembership() }
            }
            Button(text("取消", "Cancel"), role: .cancel) { }
        } message: {
            Text(text("刪除伺服器上的會員資料，不會取消 Apple 訂閱。若不想續訂，請先至「管理訂閱」取消。依法或防止重複領取所需的最少紀錄會依隱私政策保留。手機上的鬧鐘設定與音檔不會刪除。", "This deletes your server membership data, not your Apple subscription. To stop renewal, cancel in Manage subscriptions first. Minimal records required by law or to prevent duplicate grants may be retained as described in the privacy policy. Alarm settings and audio on this phone are preserved."))
        }
    }

    private var statusCard: some View {
        card {
            HStack {
                Image(systemName: manager.entitlements.removeBanner ? "checkmark.seal.fill" : "person.crop.circle")
                    .font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 5) {
                    Text(statusTitle).font(.headline)
                    if let snapshot = manager.snapshot, !manager.isLocalStoreKitTesting {
                        Text(text("會員編號：", "Member: ") + (snapshot.supportCode ?? snapshot.memberId))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer()
                if manager.isBusy { ProgressView() }
            }
            if needsMembershipSync {
                Text(text("尚未確認你的購買權益，請同步會員狀態。", "Sync your membership to verify your purchase benefits."))
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { Task { await manager.refresh() } } label: {
                    Text(text("同步會員狀態", "Refresh membership"))
                }
                .disabled(manager.isBusy)
            } else if !manager.entitlements.dailyAI {
                Text(text("初始免費 1 次 AI 鈴聲生成；用完後，每完成一次獎勵廣告可再生成一次。", "One initial free AI ringtone generation. After that, each completed rewarded ad earns one more."))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let snapshot = manager.snapshot, !manager.isLocalStoreKitTesting {
                if snapshot.entitlements.dailyAI {
                    Text(text("今日可用生成次數：", "Available generations today: ") + String(manager.remaining))
                        .font(.subheadline)
                }
            }
            if manager.entitlements.subscriptionActive {
                if manager.entitlements.lifetimeActive {
                    Text(text("買斷已包含目前訂閱的權益。Apple 訂閱不會自動取消；若不需續訂，請至「管理訂閱」關閉。", "Your one-time purchase includes your subscription benefits. It does not automatically cancel your Apple subscription; turn off renewal in Manage subscriptions if you no longer need it."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let plan = manager.entitlements.currentSubscriptionPlan {
                    Text(plan.title).font(.subheadline)
                }
                if let expiry = subscriptionExpiryText {
                    Text(text("訂閱有效至 ", "Subscription valid until ") + expiry)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button { Task { await manageSubscriptions() } } label: {
                    HStack {
                        Text(text("自動續訂", "Auto-renewal"))
                        Spacer()
                        Text(renewalStatusText).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(manager.isBusy)
                .accessibilityHint(text("在 Apple 訂閱設定更改", "Change in Apple subscription settings"))
                if manager.entitlements.subscriptionAutoRenews == false {
                    Text(manager.entitlements.lifetimeActive
                         ? text("已取消續訂，買斷權益不受訂閱到期影響。", "Renewal cancelled. Your one-time purchase benefits remain after the subscription expires.")
                         : text("已取消續訂，權益保留至效期結束。", "Renewal cancelled. Benefits remain until the end of this period."))
                        .font(.footnote).foregroundStyle(.secondary)
                } else if let next = manager.entitlements.pendingSubscriptionPlan {
                    Text(text("下次續訂方案：", "Next renewal: ") + next.title)
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if manager.isUsingCachedState {
                Text(text("顯示上次驗證的狀態", "Showing last verified status"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var statusTitle: String {
        if needsMembershipSync {
            return manager.isBusy
                ? text("正在確認會員狀態", "Checking membership")
                : text("會員尚未同步", "Membership not synced")
        }
        if manager.entitlements.preferredPlan == .lifetime { return text("買斷會員", "One-time member") }
        if manager.entitlements.subscriptionActive { return text("訂閱會員", "Subscriber") }
        return text("免費方案", "Free plan")
    }

    private var needsMembershipSync: Bool {
        manager.isConfigured && !manager.isLocalStoreKitTesting
            && manager.snapshot == nil && !manager.dataDeleted
    }

    private func planCard(_ plan: MembershipPlan) -> some View {
        let owned = manager.entitlements.owns(plan)
        let canSelect = !manager.isBusy && manager.isConfigured && manager.products[plan] != nil
            && manager.entitlements.canPurchase(plan)
        return card {
            VStack(alignment: .leading, spacing: 7) {
                Text(plan.title).font(.title3.weight(.semibold))
                if let product = manager.products[plan] {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(manager.listedPrices[plan] ?? product.displayPrice).font(.title3.weight(.semibold))
                        Text(plan == .monthly ? text("／月", "/ month") : plan == .yearly ? text("／年", "/ year") : text("一次付款", "once"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Label(text("移除 banner", "Remove banner ads"), systemImage: "checkmark")
            Label(text("每天一次免看廣告的 AI 鈴聲生成", "One daily AI generation without an ad"), systemImage: "checkmark")
            Label(text("日曆功能", "Calendar features"), systemImage: "checkmark")
            if plan.isSubscription && AppEnvironment.supportsTemporaryClosures {
                Label(text("颱風臨時放假", "Temporary disaster closures"), systemImage: "checkmark")
            }
            if plan == .lifetime {
                Text(text("一次付款，永久使用以上權益", "Pay once for permanent access to these benefits"))
                    .font(.footnote).foregroundStyle(.secondary)
                if manager.entitlements.subscriptionActive && !manager.entitlements.lifetimeActive {
                    Text(text("購買買斷不會自動取消現有訂閱；購買後可至「管理訂閱」關閉續訂。", "Buying this plan does not automatically cancel your existing subscription. After purchase, you can turn off renewal in Manage subscriptions."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button {
                Task {
                    if plan.isSubscription, manager.entitlements.subscriptionActive,
                       manager.entitlements.currentSubscriptionPlan == nil {
                        await manageSubscriptions()
                    } else {
                        await manager.purchase(plan)
                    }
                }
            } label: {
                VStack(spacing: 4) {
                    Text(planButtonTitle(plan))
                        .font(.body.weight(.semibold))
                    if plan.isSubscription, owned, !manager.entitlements.lifetimeActive, let expiry = subscriptionExpiryText {
                        Text(text("有效至 ", "Valid until ") + expiry).font(.caption)
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .foregroundStyle(canSelect ? Color.white : Color.primary.opacity(0.8))
                .background(canSelect ? Color.accentColor : Color.gray.opacity(0.24), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canSelect)
        }
    }

    private var subscriptionExpiryText: String? {
        guard let milliseconds = manager.entitlements.subscriptionExpiresAt else { return nil }
        let showsTime = manager.isLocalStoreKitTesting || manager.snapshot?.environment == "Sandbox"
        return Date(timeIntervalSince1970: milliseconds / 1_000)
            .formatted(date: .abbreviated, time: showsTime ? .shortened : .omitted)
    }

    private var renewalStatusText: String {
        switch manager.entitlements.subscriptionAutoRenews {
        case true: text("開啟", "On")
        case false: text("已關閉", "Off")
        case nil: text("待確認", "Not confirmed")
        }
    }

    private func planButtonTitle(_ plan: MembershipPlan) -> String {
        if plan.isSubscription, manager.entitlements.lifetimeActive {
            // The subscription card lists temporary closures, which lifetime does not
            // carry today (`MembershipEntitlements.temporaryClosures`); the button must
            // not read as saying the one-time purchase includes that line.
            if AppEnvironment.supportsTemporaryClosures && !manager.entitlements.temporaryClosures {
                return text("買斷已涵蓋其他權益", "Your one-time purchase covers the other benefits")
            }
            return text("已由買斷涵蓋", "Included in your one-time purchase")
        }
        if manager.entitlements.owns(plan) {
            return plan.isSubscription ? text("已訂閱", "Subscribed") : text("已購買", "Purchased")
        }
        if manager.entitlements.pendingSubscriptionPlan == plan {
            return text("下次續訂生效", "Starts at next renewal")
        }
        if plan.isSubscription, manager.entitlements.subscriptionActive {
            return manager.entitlements.currentSubscriptionPlan == nil
                ? text("管理訂閱", "Manage subscriptions") : text("更換方案", "Change plan")
        }
        return text("選擇方案", "Choose plan")
    }

    private var membershipMenu: some View {
        Menu {
            Button { Task { await manager.refresh() } } label: {
                Label(text("同步會員狀態", "Refresh membership"), systemImage: "arrow.clockwise")
            }
            .disabled(manager.isBusy || !manager.isConfigured)
            Button { Task { await manager.restorePurchases() } } label: {
                Label(text("恢復購買", "Restore purchases"), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(manager.isBusy || !manager.isConfigured)
            Button { Task { await manageSubscriptions() } } label: {
                Label(text("管理訂閱", "Manage subscriptions"), systemImage: "creditcard")
            }
            .disabled(manager.isBusy)
            if manager.canInspectSandboxPrices {
                Button { showsPriceInspection = true } label: {
                    Label(text("檢查測試商店價格", "Check test store prices"), systemImage: "testtube.2")
                }
                .disabled(manager.isBusy)
            }
            #if DEBUG
            if manager.snapshot?.environment == "Sandbox",
               MembershipConfiguration.sandboxTesting,
               manager.entitlements.lifetimeActive {
                Divider()
                Button { Task { await refundSandboxLifetime() } } label: {
                    Label(text("退回測試買斷", "Refund sandbox purchase"), systemImage: "testtube.2")
                }
                .disabled(manager.isBusy || isRequestingSandboxRefund)
            }
            #endif
            if manager.snapshot != nil && !manager.isLocalStoreKitTesting {
                Divider()
                Button(role: .destructive) { confirmsDeletion = true } label: {
                    Label(text("刪除會員資料", "Delete membership data"), systemImage: "trash")
                }
                .disabled(manager.isBusy)
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(text("會員管理", "Membership options"))
        .accessibilityHint(text("恢復購買、管理訂閱及會員資料", "Restore purchases, manage subscriptions and membership data"))
    }

    #if DEBUG
    @MainActor private func refundSandboxLifetime() async {
        guard !isRequestingSandboxRefund, !manager.isBusy,
              MembershipConfiguration.sandboxTesting,
              manager.snapshot?.environment == "Sandbox", manager.entitlements.lifetimeActive,
              let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
        isRequestingSandboxRefund = true
        managementError = nil
        defer { isRequestingSandboxRefund = false }
        // A test launch argument alone cannot prove the Apple transaction is a
        // Sandbox purchase. Never submit a refund for a production transaction.
        guard let result = await Transaction.latest(for: MembershipPlan.lifetime.rawValue),
              case .verified(let transaction) = result,
              transaction.environment == .sandbox, transaction.revocationDate == nil else {
            managementError = text("找不到可退款的沙盒買斷交易，請先恢復購買。", "No refundable Sandbox purchase was found. Restore purchases first.")
            return
        }
        do {
            switch try await transaction.beginRefundRequest(in: scene) {
            case .success:
                managementError = text("退款申請已送出，Apple 確認後將更新會員權益。", "Refund requested. Membership will update after Apple confirms it.")
                // The sheet's success is submission, not proof of revocation.
                // Existing signed transaction updates and server notifications
                // remain the only authority for removing paid benefits.
                await manager.refreshAfterManagingSubscriptions()
            case .userCancelled: break
            @unknown default: break
            }
        } catch {
            managementError = text("目前無法開啟沙盒退款，請稍後再試。", "Could not open the Sandbox refund request. Try again later.")
        }
    }
    #endif

    private var legal: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("訂閱將自動續訂，可在 Apple 訂閱設定管理或取消。價格以 App Store 顯示的當地價格為準。恢復購買只恢復權益，不會同步鬧鐘設定或音檔。", "Subscriptions renew automatically and can be managed or cancelled in Apple subscription settings. Your App Store provides the local price. Restoring purchases restores benefits, not alarm settings or audio."))
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Link(text("隱私政策", "Privacy policy"), destination: URL(string: "https://shukaihu.github.io/RainyClock/privacy-policy.html")!)
                Link(text("使用條款", "Terms of use"), destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            }.font(.footnote)
        }
    }

    @MainActor private func manageSubscriptions() async {
        managementError = nil
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
            await manager.refreshAfterManagingSubscriptions()
        } catch {
            managementError = manager.isLocalStoreKitTesting
                ? text("目前無法開啟測試訂閱管理，可到 Xcode → Debug → StoreKit → Manage Transactions 更改測試訂閱。", "Test subscription management is unavailable. Use Xcode → Debug → StoreKit → Manage Transactions to change the test subscription.")
                : text("目前無法開啟訂閱管理，請至 iPhone 設定的 Apple 帳號中管理訂閱。", "Could not open subscriptions. Manage them from your Apple Account in iPhone Settings.")
        }
    }

    private func text(_ chinese: String, _ english: String) -> String { MembershipText.value(chinese, english) }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 24))
    }
}

/// This comparison is deliberately separate from the paywall. A second API is
/// evidence to investigate, not permission to select whichever currency looks
/// right. It neither makes a purchase nor changes the displayed offer price.
private struct MembershipPriceInspectionView: View {
    @ObservedObject var manager: MembershipManager
    @Environment(\.dismiss) private var dismiss
    @State private var report = ""
    @State private var isLoading = false
    @State private var attempt = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(MembershipText.value(
                    "比較 Apple 兩個商品查詢介面的回傳資料。不會進行購買或扣款，也不會更改會員權益。",
                    "Compare the data returned by two Apple product APIs. This does not purchase, charge, or change membership benefits."))
                    .font(.subheadline).foregroundStyle(.secondary)
                if isLoading { ProgressView(MembershipText.value("正在檢查…", "Checking…")) }
                if !report.isEmpty {
                    Text(report).font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 24))
                }
                HStack {
                    Button(MembershipText.value("重新檢查", "Check again")) { attempt += 1 }
                        .disabled(isLoading)
                    Spacer()
                    Button(MembershipText.value("複製結果", "Copy results")) {
                        UIPasteboard.general.string = report
                    }
                    .disabled(isLoading || report.isEmpty)
                }
            }.padding(20)
        }
        .background(Color.appBackground)
        .navigationTitle(MembershipText.value("測試商店價格", "Test store prices"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(MembershipText.value("完成", "Done")) { dismiss() }
            }
        }
        .task(id: attempt) { await inspect() }
        .onChange(of: manager.canInspectSandboxPrices) { _, allowed in
            if !allowed { report = ""; dismiss() }
        }
    }

    @MainActor private func inspect() async {
        guard manager.canInspectSandboxPrices else { dismiss(); return }
        isLoading = true
        report = ""
        defer { isLoading = false }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var lines = ["RainyClock \(version) (\(build))", "iOS \(UIDevice.current.systemVersion)"]
        let storefrontBefore = await Storefront.current
        guard !Task.isCancelled, manager.canInspectSandboxPrices else { return }
        lines.append("StoreKit 2 store: \(storefrontBefore?.countryCode ?? "unavailable")")
        lines.append("Plan card products:")
        for plan in MembershipPlan.offeredPlans {
            if let product = manager.products[plan] {
                let card = manager.listedPrices[plan].map { " → card \($0)" } ?? ""
                lines.append("\(plan == .monthly ? "Monthly" : "One-time"): \(product.displayPrice) [\(product.priceFormatStyle.currencyCode)]\(card)")
            } else {
                lines.append("\(plan == .monthly ? "Monthly" : "One-time"): unavailable")
            }
        }
        // Legacy APIs are used only for this user-initiated Sandbox comparison.
        // Do not put payments on this queue or make this storefront authoritative.
        let legacyBefore = SKPaymentQueue.default().storefront?.countryCode
        lines.append("StoreKit 1 store before: \(legacyBefore ?? "unavailable")")
        report = lines.joined(separator: "\n")
        do {
            let quotes = try await MembershipLegacyPriceProbe().load(
                productIDs: Set(MembershipPlan.offeredPlans.map(\.rawValue)))
            try Task.checkCancellation()
            guard manager.canInspectSandboxPrices else { return }
            lines.append("StoreKit 1 products:")
            for plan in MembershipPlan.offeredPlans {
                if let quote = quotes.first(where: { $0.productID == plan.rawValue }) {
                    lines.append("\(plan == .monthly ? "Monthly" : "One-time"): \(quote.displayPrice) [\(quote.currencyCode)]")
                } else {
                    lines.append("\(plan == .monthly ? "Monthly" : "One-time"): unavailable")
                }
            }
        } catch is CancellationError {
            return
        } catch {
            let error = error as NSError
            lines.append("StoreKit 1 error: \(error.domain)/\(error.code)")
        }
        guard !Task.isCancelled, manager.canInspectSandboxPrices else { return }
        lines.append("StoreKit 1 store after: \(SKPaymentQueue.default().storefront?.countryCode ?? "unavailable")")
        let storefrontAfter = await Storefront.current
        guard !Task.isCancelled, manager.canInspectSandboxPrices else { return }
        lines.append("StoreKit 2 store after: \(storefrontAfter?.countryCode ?? "unavailable")")
        report = lines.joined(separator: "\n")
    }
}
