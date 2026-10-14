import SwiftUI

/// The soft layer: the version card at the top of Settings › Other, above the membership
/// row (owner, 2026-10-15: no prompts on the home screen). The first row always names the
/// running version; while the App Store lists a newer one, a second row offers it.
struct AppVersionCard: View {
    let update: AppUpdateGate.StoreListing?
    let storeURL: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "info.circle").foregroundStyle(Color.accentColor).frame(width: 20)
                Text("ux_version").foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(verbatim: "\(AppBuildInfo.version) (\(AppBuildInfo.buildString))")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.body).frame(minHeight: 28).padding(.horizontal, 16).padding(.vertical, 12)
            if let update {
                Divider().padding(.leading, 48)
                HStack(spacing: 11) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor).frame(width: 20)
                    Text(String.localizedStringWithFormat(String(localized: "update_available_message"), update.version))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        openURL(storeURL)
                    } label: {
                        Text("update_available_action").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("updateAvailableButton")
                }
                .font(.body).frame(minHeight: 28).padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 22))
        .accessibilityIdentifier("appVersionCard")
    }
}

/// The hard layer: covers the main UI while the running build is below the service's
/// minimum. Nothing here dismisses it; the only way on is the App Store. The alarms
/// already scheduled are untouched, and the text says so.
struct UpdateRequiredView: View {
    let storeURL: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
            Text("update_required_title")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("update_required_message")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                openURL(storeURL)
            } label: {
                Text("update_required_action")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text(verbatim: "\(AppBuildInfo.version) (\(AppBuildInfo.buildString))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("updateRequiredView")
    }
}
