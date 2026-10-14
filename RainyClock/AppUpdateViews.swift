import SwiftUI

/// The soft layer: a strip above the tabs while the App Store lists a newer version.
/// Dismissing hides that version for good (`AppUpdateGate.dismissAvailableUpdate`).
struct UpdateAvailableBanner: View {
    let listing: AppUpdateGate.StoreListing
    let storeURL: URL
    let dismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("update_available_title")
                    .font(.subheadline.weight(.semibold))
                Text(String.localizedStringWithFormat(String(localized: "update_available_message"), listing.version))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                openURL(storeURL)
            } label: {
                Text("update_available_action")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("update_dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Color.appBackground)
        .accessibilityIdentifier("updateAvailableBanner")
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
