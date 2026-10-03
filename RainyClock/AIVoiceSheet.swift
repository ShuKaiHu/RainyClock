import AVFoundation
import SwiftUI

/// Where a user writes what the alarm should say and hears who will say it.
///
/// Two decisions and a sentence, in that order, and only the last one costs
/// anything: every voice can be auditioned from clips shipped in the bundle, so
/// nobody spends a generation — or waits on the network — to find out what a
/// persona sounds like.
struct AIVoiceSheet: View {
    /// Roughly nine seconds of speech either way. The two numbers differ because
    /// the languages do: measured at about 4.4 Chinese characters a second
    /// against about 18 Latin characters, so one shared limit would be generous
    /// in one language and punishing in the other.
    static let chineseBudget = 40.0
    static let latinBudget = 150.0

    @ObservedObject var viewModel: AlarmViewModel
    let slot: CommuteAlarmSettings.SoundSlot
    @ObservedObject private var membership = MembershipManager.shared
    @ObservedObject private var consent = ConsentManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var persona: VoicePersona = .default
    @State private var isGenerating = false
    @State private var message: String?
    @State private var previewPlayer: AVAudioPlayer?
    @State private var playingPersona: VoicePersona?
    @State private var previewTask: Task<Void, Never>?
    @State private var remaining = AIVoiceQuota.remaining
    @State private var isPreparingReward = false
    @State private var expiredGeneration: MembershipPendingGeneration?
    @State private var confirmsNewGeneration = false
    @StateObject private var rewardedAd = RewardedAdController()

    private let client: AIVoiceGenerating = AIVoiceClient()

    /// Why the count is zero, which decides what the user can do about it.
    private var quotaExhaustedHint: LocalizedStringKey {
        if !RewardedAdController.isConfigured {
            return "ai_voice_quota_gone"
        }
        return rewardedAd.isReady ? "ai_voice_quota_watch" : "ai_voice_quota_no_ad"
    }

    /// How many are left, and what happens when they are not.
    ///
    /// The word "free" is dropped once any of the remaining count was bought with
    /// a video, because by then it is not free and saying so would be a small lie
    /// told every time the sheet opens.
    private var quotaSentence: String {
        if membership.isConfigured {
            guard let snapshot = membership.snapshot else {
                return MembershipText.value("生成時會安全同步會員與可用次數。", "Membership and available generations will be verified when you generate.")
            }
            if snapshot.quota.migrationPending && !snapshot.entitlements.dailyAI {
                return MembershipText.value("目前可用生成次數：", "Available generations: ") + String(membership.remaining)
                    + MembershipText.value("。原有廣告餘額仍保留於手機，待核對。", ". Your previous ad credits remain on this phone pending verification.")
            }
            return MembershipText.value("目前可用生成次數：", "Available generations: ") + String(membership.remaining)
        }
        let format: String
        if remaining == 1 {
            format = remaining == AIVoiceQuota.freeRemaining
                ? String(localized: "ai_voice_quota_free_one_remaining")
                : String(localized: "ai_voice_quota_one_remaining")
        } else {
            format = remaining == AIVoiceQuota.freeRemaining
                ? String(localized: "ai_voice_quota_free_remaining")
                : String(localized: "ai_voice_quota_remaining")
        }
        return String.localizedStringWithFormat(format, remaining)
    }

    /// One counter for both languages: a Chinese character costs a whole unit, a
    /// Latin one the fraction that makes 150 of them weigh the same as 40.
    private var used: Double {
        text.reduce(0) { total, character in
            let isCJK = character.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            return total + (isCJK ? 1 : Self.chineseBudget / Self.latinBudget)
        }
    }

    private var isOverBudget: Bool { used > Self.chineseBudget }
    private var canGenerate: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isOverBudget && !isGenerating && (membership.isConfigured || remaining > 0)
    }

    private func watchAdForCredit() {
        if membership.isConfigured {
            isPreparingReward = true
            Task {
                defer { isPreparingReward = false }
                do {
                    // Revalidate Media & Purchases before every explicit ad view,
                    // even if an ad loaded under the previous member is still ready.
                    let attempt = try await MembershipRewardFlow.shared.prepare()
                    guard rewardedAd.isReady else {
                        rewardedAd.load()
                        message = MembershipText.value("正在準備獎勵廣告。", "Preparing a rewarded ad.")
                        return
                    }
                    rewardedAd.show {
                        Task {
                            message = MembershipText.value("正在確認廣告獎勵…", "Verifying your ad reward…")
                            do {
                                try await MembershipRewardFlow.shared.waitForCredit(attempt: attempt)
                                remaining = membership.remaining
                                message = MembershipText.value("已收到一次生成額度。", "One generation credit received.")
                            } catch { message = error.localizedDescription }
                        }
                    }
                } catch { message = error.localizedDescription }
            }
        } else {
            // The local initial allowance and earned credits remain in use until
            // membership rollout; changing sound slots never replenishes either.
            rewardedAd.show {
                AIVoiceQuota.grantCredit()
                remaining = AIVoiceQuota.remaining
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 90)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text(slot == .early ? LocalizedStringKey("ai_voice_placeholder") : "ai_voice_placeholder_normal")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                    HStack {
                        Spacer()
                        Text("\(Int(used.rounded())) / \(Int(Self.chineseBudget))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(isOverBudget ? Color.red : .secondary)
                    }
                } header: {
                    Text("ai_voice_what_to_say")
                } footer: {
                    Text("ai_voice_what_to_say_hint")
                }

                Section {
                    ForEach(VoicePersona.allCases) { candidate in
                        // Not a Button wrapping a Button: SwiftUI gives the outer
                        // one every tap, and the play control inside it silently
                        // never fires. The row selects through a tap gesture so the
                        // preview can stay a real button.
                        HStack(spacing: 12) {
                            Image(systemName: persona == candidate ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.displayName)
                                    .foregroundStyle(.primary)
                                Text(candidate.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        // The whole row selects, including the empty space beside
                        // the labels, but stops short of the preview button.
                        .contentShape(Rectangle())
                        .onTapGesture { persona = candidate }
                        .overlay(alignment: .trailing) {
                            Button {
                                playPreview(of: candidate)
                            } label: {
                                Image(systemName: playingPersona == candidate
                                      ? "stop.circle.fill" : "play.circle.fill")
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel(Text("preview_alarm_sound"))
                        }
                    }
                } header: {
                    Text("ai_voice_who_says_it")
                } footer: {
                    // The count and the rule in one sentence, rather than a bare
                    // number beside the button: how many are left only means
                    // anything next to what happens when they run out.
                    Text(quotaSentence)
                }

                // Only the way *back* from empty lives down here. The count itself
                // sits beside the button that spends it, where it is read.
                if remaining == 0 || (membership.isConfigured && membership.snapshot == nil) {
                    Section {
                        // Offered only when an ad is really there: a button that
                        // trades a video for a generation has to be able to honour
                        // the trade.
                        if RewardedAdController.isConfigured {
                            Button {
                                watchAdForCredit()
                            } label: {
                                if membership.isConfigured && !rewardedAd.isReady {
                                    Label(MembershipText.value("準備獎勵廣告", "Prepare rewarded ad"), systemImage: "play.rectangle")
                                } else {
                                    Label("ai_voice_watch_ad", systemImage: "play.rectangle")
                                }
                            }
                            .disabled(isPreparingReward || rewardedAd.isPresenting || (!membership.isConfigured && !rewardedAd.isReady))
                        }
                    } header: {
                        Text("ai_voice_quota")
                    } footer: {
                        if membership.isConfigured {
                            Text(MembershipText.value("每次額外生成需完成一次獎勵廣告，獎勵由伺服器確認。付費方案也可等隔天。", "Each extra generation requires a rewarded ad verified by the server. Paid members can also wait until tomorrow."))
                        } else { Text(quotaExhaustedHint) }
                    }
                }

                if let message {
                    Section {
                        Text(message).font(.footnote)
                    }
                }
            }
            .navigationTitle(slot == .early ? String(localized: "ai_voice_title_early") : String(localized: "ai_voice_title_normal"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }.disabled(isGenerating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isGenerating {
                        ProgressView()
                    } else {
                        Button("ai_voice_generate") { generate() }
                            .disabled(!canGenerate)
                    }
                }
            }
            .onAppear {
                // Reopen on what was last chosen rather than a blank page: the clip
                // is audio and cannot be read back into a text field, so the words
                // have to come from settings or they are gone.
                text = viewModel.settings.voiceText(for: slot)
                persona = viewModel.settings.voicePersona(for: slot)
                remaining = membership.isConfigured ? membership.remaining : AIVoiceQuota.remaining
                // Loaded ahead of being needed, so the exchange button can say
                // whether it will work rather than finding out on the tap.
                if remaining == 0 && !membership.isConfigured {
                    rewardedAd.load()
                }
            }
            .onDisappear { stopPreview() }
            .task { await membership.start() }
            .onChange(of: membership.snapshot) { _, _ in
                if membership.isConfigured { remaining = membership.remaining }
            }
            .onChange(of: consent.canRequestAds) { _, allowed in
                if allowed && remaining == 0 && consent.canRequestMembershipRewards { rewardedAd.load() }
            }
            .confirmationDialog(MembershipText.value("先前音檔已超過下載期限", "The previous audio download has expired"),
                                isPresented: $confirmsNewGeneration, titleVisibility: .visible) {
                Button(MembershipText.value("重新生成（使用一次額度）", "Generate again (uses one credit)")) {
                    if let expiredGeneration { generate(replacing: expiredGeneration) }
                }
                Button(MembershipText.value("取消", "Cancel"), role: .cancel) { }
            } message: {
                Text(MembershipText.value("伺服器無法再提供先前結果。重新生成是新的請求，成功後會使用一次額度。", "The server can no longer return the previous result. Generating again creates a new request and uses one credit on success."))
            }
        }
        .interactiveDismissDisabled(isGenerating)
    }

    private func playPreview(of candidate: VoicePersona) {
        let wasPlaying = playingPersona == candidate
        // Unconditionally, before anything else. Replacing the player alone does
        // not silence the old one — it plays on until it happens to be
        // deallocated — so tapping a second voice used to leave two talking over
        // each other.
        stopPreview()
        if wasPlaying {
            return
        }

        guard let url = Bundle.main.url(forResource: candidate.previewResourceName, withExtension: "m4a"),
              let player = try? AVAudioPlayer(contentsOf: url) else {
            return
        }
        // Without this the session inherits `.soloAmbient`, which plays nothing
        // while the ring switch is silenced — the same trap the tone preview hit.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        previewPlayer = player
        playingPersona = candidate
        player.prepareToPlay()
        player.play()

        // Reaching the end has to put the button back, or every voice the user
        // auditions is left showing a stop control for audio that finished.
        let duration = player.duration
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(Int(duration * 1_000)))
            guard !Task.isCancelled, playingPersona == candidate else {
                return
            }
            stopPreview()
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewPlayer?.stop()
        previewPlayer = nil
        playingPersona = nil
    }

    /// Generation happens here and nowhere else. It is deliberately not part of
    /// scheduling: that path also runs from a debounced settings change and from
    /// the background refresh task, and neither should be able to spend money or
    /// wait on a network call.
    private func generate(replacing expired: MembershipPendingGeneration? = nil) {
        stopPreview()
        isGenerating = true
        message = nil
        let requestedText = text
        let requestedPersona = persona

        Task {
            defer { isGenerating = false }
            if membership.isConfigured {
                do {
                    switch try await MembershipVoiceGeneration.shared.generate(requestedText,
                        persona: requestedPersona, replaceExpired: expired) {
                    case .speech(let pcm, let pending):
                        if saveVoice(pcm, text: requestedText, persona: requestedPersona) {
                            // Local file failure never discards recovery of the durable
                            // server result, which is already the same charged job.
                            try MembershipVoiceGeneration.shared.complete(pending)
                            remaining = membership.remaining
                            dismiss()
                        }
                    case .pending:
                        message = MembershipText.value("仍在生成，稍後再按生成會接續同一次，不會重複扣次數。", "Still generating. Tap Generate later to resume the same request without a second charge.")
                    case .expired(let pending):
                        expiredGeneration = pending
                        confirmsNewGeneration = true
                    }
                } catch MembershipError.server(let code, let status) {
                    if status == 422 { message = String(localized: "ai_voice_error_rejected") }
                    else if code == "legacy_migration_pending" {
                        message = MembershipText.value("目前可用次數已用完。原有廣告餘額仍保留於手機，待核對。", "Your available generations are used. Previous ad credits remain on this phone pending verification.")
                    } else { message = MembershipError.server(code, status).localizedDescription }
                } catch { message = (error as? MembershipError ?? .unavailable).localizedDescription }
                return
            }

            // Membership builds never fall back here after an authentication error.
            switch await client.speak(requestedText, as: requestedPersona) {
            case .speech(let pcm):
                if saveVoice(pcm, text: requestedText, persona: requestedPersona) {
                    AIVoiceQuota.consume()
                    remaining = AIVoiceQuota.remaining
                    dismiss()
                }
            case .rejected: message = String(localized: "ai_voice_error_rejected")
            case .busy: message = String(localized: "ai_voice_error_busy")
            case .unavailable: message = String(localized: "ai_voice_error_unavailable")
            }
        }
    }

    private func saveVoice(_ pcm: Data, text: String, persona: VoicePersona) -> Bool {
        guard let assembled = try? GeneratedVoiceAssembler.assemble(speech: pcm),
              let fileName = GeneratedVoiceStore.write(assembled, fileName: "ai-\(UUID().uuidString.prefix(8)).wav") else {
            message = String(localized: "ai_voice_error_unavailable")
            return false
        }
        var settings = viewModel.settings
        settings.setVoice(fileName: fileName, persona: persona, text: text, for: slot)
        viewModel.settings = settings
        // An existing scheduled or snoozed alarm can still reference the old clip.
        // Retain it until a future cleanup can prove no registered alarm uses it.
        return true
    }
}
