# Rainy Clock — iOS status & backlog

Living handoff document for the **iPhone app**. Read this first when picking iOS back up;
update it when something ships, gets blocked, or gets discovered.

The Android port keeps its own log in `docs/STATUS-ANDROID.md`. Keep the two apart: they ship
on different schedules and are often worked on at the same time, and a shared file means two
sessions writing over each other. Anything true of both platforms goes in `docs/STATUS.md`.

- Submission mechanics, rejection history, AdMob and app-ads.txt setup → `docs/app-store-submission-checklist.md`
- Store copy, release notes, review notes → `docs/appstore-metadata.md`
- Product reasoning and rejected alternatives (both platforms) → `docs/PRODUCT_DECISIONS.md`

Last updated: 2026-09-07.

## Where things stand

| | Version | State |
| --- | --- | --- |
| **In progress** | `1.6.9 (28)` | The ad report done the industry's way, the AI voice quota surviving a reinstall, and the evening-before preview notification — see below. Opened 2026-09-07; code and tests in, device check and upload still owed |
| **Live on the App Store** | `1.6.8` | **Released 2026-09-01**, first attempt — confirmed against the public listing, not against this file. The AI voice alarm. Production checked after release: weather and `/v1/tts` both answer 200 |
| Superseded | `1.6.7` | **Released 2026-08-30.** The ad-provider migration. Confirmed against the public listing on 2026-08-31 — this row had still been claiming 正在等待審查, the third time this file has gone stale the same way |
| Superseded | `1.6.6` | Released 2026-08-18 |
| Superseded | `1.6.5` | Released 2026-08-04 |
| Rejected, then resolved | `1.6.4 (19)` | Rejected 2026-08-01 on 5.1.2(i) and 2.1(a); both answered, and the fixes reached users in 1.6.5 |
| Superseded | `1.6.3 (18)` | Released 2026-07-28 |

**Ships with 1.6.6 (edited in ASC 2026-08-13):** both app names change — 繁體中文
`RainyClock` → `Rainy Clock`, English `Rainy Clock: Rain Alarm` → `Rainy-Clock`. Plain
"Rainy Clock" is still name-squatted in the English locale (409 on rename), but the
hyphenated variant was accepted (details in `docs/appstore-metadata.md`).

## 1.6.9 — the ad report, done the industry's way

Opened 2026-09-07 after the user found the "檢舉廣告" row odd. It sat inside the alarm
settings card between the snooze slider and the schedule button, and the mail it opened
could not say whether the complaint was about the banner or the rewarded video — the body
carried only the app version and "Unity LevelPlay". Apple's 2.5.18 says nothing about
placement or mechanism (the two official threads asking have no answers), so the shape is
the one most ad-carrying apps converge on: a per-ad route next to the creative, and a
generic route in the app's support area, both traceable to a creative.

What changed:

- **`RecentAds`** (`Services/AdReport.swift`) keeps the last banner and the last rewarded
  video as an `AdSighting` — network, `creativeId`, `auctionId`, time — recorded from the
  SDK's own callbacks: the banner on `didLoadAd` and `didDisplayAd` (every auto-refresh
  lands there), the video on `didDisplayAd` only, since a loaded-but-unshown video is not
  one anyone saw. Memory only, nothing about the person. `creativeId` is what Ad Quality
  blocks by and `auctionId` what ironSource support traces by; both were always in
  `LPMAdInfo` and never read.
- **The mail body lists both sightings**, one line each, labelled 橫幅廣告 / 獎勵影片 with the
  identifiers, and asks the user to keep the one they mean. Built at tap time (`Button` +
  `openURL`, no longer a `Link` evaluated at render) so it carries the ads shown *by then*.
  A session with no ad yet says so instead of leaving a blank.
- **A "檢舉這則廣告" caption under the banner**, `.caption2` secondary, right-aligned, shown
  only once a banner has been displayed. *Under*, not over: mediation terms forbid
  obscuring a creative, and an ironSource banner has no AdChoices-style icon of its own
  (Unity's full-screen videos carry a privacy icon; that is the SDK's layer for the
  rewarded slot).
- **A small "廣告" card at the end of the Alarm tab** holds the GDPR "廣告隱私設定" row
  (still only for GDPR geographies) and the report row (everywhere). Nothing ad-related
  remains inside the alarm settings card.
- **`AdReportTests`** (5 tests) pin the body: both slots with their identifiers, banner
  first; a slot that never showed is omitted; no ads says so; blank SDK strings become
  `?`; the `mailto` keeps a literal `+` encoded.

**Also in 1.6.9: the AI voice quota survives delete-and-reinstall.** The user found that
reinstalling handed out three free generations again. `AIVoiceQuota` had said so in its
own comment and called it a deliberate trade against "an identifier that survives
deletion" — but a counter is not an identifier, so the trade was never needed for this.
Now:

- **`KeychainCounters`** (`Services/KeychainCounters.swift`) stores small integers as
  generic-password items — this device only, not iCloud-synchronised — under the service
  `com.shukaihu.RainyClock.aiVoiceQuota`. Keychain items outlive the app container;
  Apple documents no guarantee of that, so this is fairness, not a security boundary
  (the boundary is `weather-proxy`'s daily budget, which meters nothing per device).
- **`UserDefaults` stays as a write-through mirror**, and the read is keychain-first with
  the mirror as fallback. That covers three cases at once: a count 1.6.8 left behind is
  picked up and carried into the keychain on first read; a reinstall has only the
  keychain and keeps the count; a process the keychain refuses (an unsigned build gets
  `errSecMissingEntitlement`; a read before first unlock) still sees the mirror instead
  of an unlimited allowance. Earned credits survive a reinstall too, which is the
  user-facing half worth saying in the notes.
- **`AIVoiceQuotaTests`** (8 tests). The ones that need the keychain `XCTSkip` when the
  host is unsigned — the documented build command passes `CODE_SIGNING_ALLOWED=NO`, and
  in that run six skip (three outright, three after their mirror half); drop the flag and
  all eight run and pass, reinstall simulation included.
  The lifecycle overrides are the `async throws` forms, because in a `@MainActor` test
  class the synchronous `setUp`/`tearDown` overrides are nonisolated and cannot touch the
  class's own state under Swift 6.
- Considered and not done: **DeviceCheck** (Apple's design for exactly this — two bits per
  device, read and set by the server, no identifier reaches the app; the proxy would need
  an Apple `.p8` in Secret Manager and a round trip per generation) and **iCloud KVS**
  (needs the entitlement, defeated by signing out). DeviceCheck is the right move if the
  server-side cost ever matters; at NT$0.10 a generation and three per reinstall, it does
  not yet.

**Also in 1.6.9: the evening-before preview.** Picked from the feature list on 2026-09-07 as
the one item that is both a retention feature and the fix for backlog item 0. At 9 p.m. the
night before each selected weekday, a local notification says what tomorrow's alarm will
do; for the people whose background refresh can never run, it is the only place the app
tells them so.

- **`EveningPreviewPlanner`** (`Services/EveningPreview.swift`) is pure: from the armed
  `ScheduledAlarmSummary`, the selected weekdays and `now` it plans one preview per
  selected weekday for the coming week, each at 21:00 the evening before, skipping an
  evening already gone. Only the summary's own ring carries the **decision** (rain or not,
  from what time to what time, and when the forecast was checked — the evaluate flow
  fetched that ring's forecast, so this is true). Every later weekday is **upcoming**:
  "there is an alarm; the morning's forecast decides", because that is what the
  background refresh does. Identifier `commute-rain-preview-YYYYMMDD` per alarm day.
- **Replaced on every registration, and nowhere else** — the foreground Schedule, the
  debounced settings reconcile, and `refreshScheduledAlarmUnattended()` from the
  background task all pass through `evaluateRouteAndScheduleAlarm()`, so an overnight
  refresh that changes the decision rewrites that evening's text with it. 21:00 sits
  before the processing window opens (nine hours before the lead-time point) on purpose.
- **Backlog item 0 is answered by detection, not guessing.** `UIApplication.shared.
  backgroundRefreshStatus != .available` or Low Power Mode at planning time puts a
  sentence on every preview: forecasts cannot update in the background right now, open
  the app. Nobody whose refresh works ever sees it, which is the "must not nag" line the
  backlog drew.
- **A toggle, `前一晚預告`, default on**, under snooze in the alarm settings card, with a
  one-line hint. Not in the schedule fingerprint. Off cancels the previews; on re-plans
  from the stored summary.
- **Notification permission on iOS 26 is new ground.** The alarm there is AlarmKit, whose
  permission is not notification permission, so this is the first thing that asks for
  `.alert` on iOS 26. It asks in three places, all foreground: an attended Schedule (after
  the alarm's own prompt), the toggle turning on, and `ContentView`'s launch task after
  the stale-refresh — that last one is for the install that upgraded with an alarm armed
  and never taps Schedule again. Unattended runs only read the status. On iOS 17–25 the
  alarm already asked, and the answer covers both.
- **The 64-request budget is shared** with the iOS 17–25 notification alarms:
  `LocalNotificationScheduler.pendingNotificationLimit` dropped 64 → 56 to leave seven
  for previews. With all seven weekdays selected the alarm gets 8 requests a day (7
  follow-ups) instead of 9.
- **`EveningPreviewPlannerTests`** (7 tests): one evening per selected weekday inside a
  week; only the armed ring carries the decision; an evening already past is skipped and
  its decision with it; a ring several days out still gets its own eve; seven days give
  seven previews and never more; the background-refresh flag rides on every preview; an
  alarm just after midnight is previewed the evening before.
- Not done, on purpose: a preview time setting (21:00 is a guess; make it a setting only
  if someone asks), time-sensitive interruption level (needs an entitlement), and any
  "no rain tonight, so no notification" filtering — with the toggle the person chooses,
  and a reassuring "stays at 7:00" is the point on a dry night.

Checklist:

- [x] Version `1.6.9 (28)` in both places (`Info.plist` and the widget's
      `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`), verified in the built bundle.
- [x] Simulator build and the full unit suite pass (2026-09-07): 85 tests signed, all
      pass; unsigned (the documented command) 6 of the quota tests skip because the
      keychain refuses an unsigned host.
- [x] **Support card seen on the iPhone 17 Pro simulator 2026-09-07**, in both languages,
      with the installed bundle's `LevelPlayAppKey` blanked first so answering the consent
      sheet could not start the SDK. Under `-forceGDPRConsentGeography` the card shows
      both rows; without it, only 檢舉廣告 — the Taiwan view. The simulator bundle was
      rebuilt afterwards so `DerivedData` carries the real key again.
- [ ] **Check on the iPhone 16 Pro**, the registered test device: the caption appears
      under a real banner, the mail draft names it with a creative id, and — after
      spending the free generations — the rewarded line appears too. Then delete the app,
      reinstall, and confirm the voice sheet still shows the spent count. Then, with an
      alarm armed for tomorrow, wait for 21:00 (or set the clock) and confirm the preview
      arrives with tomorrow's decision; toggle Background App Refresh off, reschedule, and
      confirm the extra sentence appears. The simulator cannot
      show this: a launch with `-forceGDPRConsentGeography` and the sheet swiped away
      leaves the SDK unstarted (correctly, per the no-simulator-impressions rule), so only
      the support card is visible there.
- [ ] Archive, upload, submit with the 1.6.9 note in `docs/appstore-metadata.md`.

## 1.6.7 — off Google ads, onto Unity LevelPlay

**The AdMob account was terminated and the appeal was denied (2026-08-29).** Every Google
advertising component is gone on purpose — `GoogleMobileAds`, the UMP consent flow,
`GADApplicationIdentifier` — and must not come back: Google demand needs a live AdMob
account under any mediator, and UMP's forms are configured in that same dead console. A
same-day AppLovin MAX detour was re-pointed to LevelPlay once the ad unit turned out to live
in the Unity dashboard; the MAX code survives in git history if it is ever needed.

What ships:

- **Unity LevelPlay 9.6.0** (ironSource SDK via SPM, product `UnityMediationSDK`), one
  anchored adaptive banner, ad unit `kay9cneaxvesx4p4`, app key `27d81ff8d` in `Info.plist`.
- **The app's own GDPR consent sheet** (`AdConsentSheet`) feeding
  `LPMPrivacySettings.setGDPRConsent`. The device region decides who is a GDPR user, and an
  unanswered GDPR user keeps the SDK from initialising at all — stricter than the UMP flow,
  which only gated the ad request.
- Order restored to **consent → ATT → SDK start**, as the AdMob build had it.

Two traps worth remembering:

- **`OTHER_LDFLAGS = -ObjC` is mandatory.** IronSource is a static framework; without it the
  app dies at launch inside the SDK's own init on a missing `ISAES256EncryptWithKey:`
  selector. It only reproduces once a real app key is set, because a placeholder key skips
  init entirely.
- The **iOS ad unit and app key are iOS-only**. LevelPlay keys and units are per app, so
  Android needs its own of both.

Verified on the simulator on 2026-08-29: real creatives serve, a fresh one per launch. Those
were real impressions on a real key — see the test-device rule in `CLAUDE.md`; do it through
**Setup → Test devices** next time.

**Consent wording reworked 2026-08-30** after reading the platform terms. The Data Protection
Addendum requires the consent to name ironSource, and its advertising partners for the
personalised tier, as controllers, and to carry a link to ironSource's privacy policy. The
sheet now does all three, with both policy links pinned above the buttons rather than inside
the scrolling prose — a link nobody scrolls to is not "included". The addendum's URLs for
ironSource's privacy policy and its advertising-partner list are both dead (they redirect to
Unity's generic legal and docs indexes); the app links Unity's live Game Player and App User
Privacy Policy instead. **Ask ironSource support for the canonical URLs** and swap them in —
it is one constant per platform.

Still owed before submitting:

- [x] **`app-ads.txt` published 2026-08-29** and verified live at
      `https://shukaihu.github.io/app-ads.txt`: `OWNERDOMAIN=shukaihu.github.io` plus
      `ironsrc.com, 679093, DIRECT`. The publisher id came from ironSource → Account → API
      tab; the terminated AdMob line is gone. This was not optional housekeeping — a file
      that lists no current seller reads as "LevelPlay is unauthorised" to any DSP that
      checks it. The optional certification-authority field is deliberately omitted: it is
      optional, and real-world files carrying it disagree on the value. The id is also the
      account's `seller_id` in `ironsrc.com/sellers.json`, which is how a future check can
      confirm it without logging in — the account was not listed there yet on 2026-08-29,
      since sellers.json only carries accounts that have started transacting.
- [x] **Archived 2026-08-30 as `build/RainyClock-1.6.7-26.xcarchive`** and verified: app and
      `RainyClockAlarmWidget.appex` both report `1.6.7 (26)` (the lockstep that rejects
      uploads when it slips), `LevelPlayAppKey` and the ATT usage string are present, no
      `GAD*` keys survive, the only embedded framework is `IronSource.framework`, the privacy
      manifest still carries the ITMS-91064-safe `NSPrivacyTracking = false` with an empty
      domain list, and 152 SKAdNetwork ids are in place. The SDK really is in the shipped
      binary — `LPMBannerAdView` and `LevelPlay` appear throughout it — and so is
      `ISAES256EncryptWithKey:`, which is the proof that `-ObjC` did its job. The 51 KB
      `IronSource.framework` in `Frameworks/` is a stub that carries the SDK's privacy
      manifest; the code itself is statically linked, and `otool -L` shows no dynamic
      dependency on it.
- [x] **Uploaded 2026-08-30.** `xcodebuild -exportArchive` with
      `ExportOptions-AppStoreUpload.plist` again needed no credentials by hand. One warning
      worth knowing rather than fixing: `Upload Symbols Failed … did not include a dSYM for
      the IronSource.framework`. It does not block the upload or review; it only means crash
      frames inside ironSource's own code arrive unsymbolicated, because the vendor ships no
      dSYM with the static framework. Turning `uploadSymbols` off to silence it would cost
      the symbols for our own code too, so leave it.
- [x] **Submitted 2026-08-30** with the notes and App Review text from
      `docs/appstore-metadata.md`. **The App Privacy declaration needed no change for the ad
      swap** — an earlier draft of this list claimed it did, and sent someone hunting for a
      field that does not exist. Apple's questionnaire asks only which data types are
      collected, for what purpose, and whether they are used for tracking; it phrases the
      question as "you or your third-party partners" and never asks which partner. Data
      types, purposes and the tracking answers are all unchanged by moving from Google to
      Unity. The vendor name matters in the two places that already carry it: the privacy
      policy page and the App Review note.
- [x] **Test device registered 2026-08-30** — the iPhone 16 Pro, under **Setup → Test
      devices**. Debug builds print the advertising id at launch
      (`[RainyClock] Advertising ID for LevelPlay → Setup → Test devices: …`), which is the
      only way to read it: iOS shows it nowhere, and SDK 9.6.0 dropped the old
      `ISIntegrationHelper`. It reads as all zeros until ATT is granted — no prompt appeared
      here because the App Store build had already been allowed on that phone, and the
      decision survives installing a debug build over it, since the bundle id is the same.
- [x] **Verified on the device 2026-08-30, and it is the check that mattered.** The device
      build links IronSource statically, which the simulator never exercised — the `-ObjC`
      launch crash came out of exactly that difference. `[LevelPlay] banner loaded from
      ironsourceads, 402x50` on the iPhone 16 Pro, 402pt being that device's logical width,
      so the anchored adaptive sizing is right too; a screenshot confirmed the banner on
      screen. Getting there without billable impressions is worth remembering: launching with
      `-forceGDPRConsentGeography` and dismissing the sheet without answering leaves
      `startAdSdk()` uncalled, so the advertising id can be read with no ad request at all.
- [x] **ironSource Ads account approved 2026-09-06** (email "Your ironSource Ads account is
      approved"). Nothing was left to do on our side: both instances under app key
      `27d81ff8d` — Banner `25243021` and Rewarded Video `25248417`, both bidding — were
      already Active, and the SDK had been in the shipping app since 1.6.7. First 14 days of
      Performance (Aug 24 – Sep 6): $0.57 revenue on 552 impressions across 140 sessions,
      peak 12 DAU on 2026-09-01 (the 1.6.8 release day), settling to 1–3 DAU after — so
      eCPM is about $1, and single days move the chart. The dashboard also notes that the
      **ironSource Ads direct demand network was sunset on 2026-04-30**; supply now comes
      through the ironSource Exchange, which the current LevelPlay SDK still reaches. Unity
      recommends moving to the Unity Ads SDK ("Unity Vector") eventually — a backlog
      candidate, not an action item.

> **This file said "1.6.5 waiting to upload" for nine days after 1.6.5 had already shipped.**
> Nobody updated it after the upload, and an agent reading it repeated the claim back as
> fact. The listing is the source of truth for what is live, and it is one command away
> without any credentials:
>
> ```
> curl -s "https://itunes.apple.com/lookup?bundleId=com.shukaihu.RainyClock&country=tw" | python3 -m json.tool | grep -E '"version"|currentVersionReleaseDate'
> ```
>
> Check it before trusting any "what is live" line here, and update the table when a version
> goes out.

`1.6.3` is the AlarmKit release: alarms pierce silent mode and Focus on iOS 26+, snooze with
a 1–15 minute interval, and the first shipped `RainyClockAlarmWidget` extension. It cleared
review on the first attempt, so AlarmKit's `NSAlarmKitUsageDescription` prompt and the new
widget extension are both proven acceptable to App Review — nothing extra was asked for.

Apple offered to approve `1.6.4` as a bug-fix submission if asked; we chose to fix both
findings and resubmit as `1.6.5` instead, and that is the version that went out on
2026-08-04. It carries everything `1.6.4` contained, so the interface redesign and the
English (U.S.) localization reached users through it.

## The 1.6.4 rejection

Reviewed on an **iPad Air 11-inch (M3), iPadOS 26.6** — worth remembering, it explains the
second finding entirely.

**5.1.2(i) — tracking without ATT.** The AdMob-hosted GDPR message asks for consent to
"personalised advertising and content"; App Review reads that as a declaration that the app
tracks, and there was no ATT prompt behind it. The app itself never used that consent —
`npa=1` was hardcoded since the `1.5 (7)` rejection — so the message and the code disagreed.
Fixed by implementing ATT and actually honouring it. Full reasoning, and the manual App Store
Connect steps this creates, are in `docs/app-store-submission-checklist.md`.

**2.1(a) — "unable to add Widgets at the Home Screen."** Not a defect, answered by reply. The
app ships no Home Screen widget at all: the widget extension holds only the AlarmKit Live
Activity, which is why it exists. And on an iPad the app runs in iPhone compatibility mode,
where iOS offers no third-party widgets whatever the app contains.

## Monetization: unblocked, waiting on traffic

AdMob's app-ads.txt verification passed on 2026-07-27 and the app's approval status is 就緒
(Ready). Nothing is left to configure. What the AdMob report showed the next day:

| Metric | Value | Reading |
| --- | --- | --- |
| Requests | 168 | The integration works — requests reach Google |
| Impressions | 0 | Google returned no ad, 168 times |
| Match rate | 0.00% | Same thing stated as a rate |
| Revenue | US$0.00 | Expected at this stage |

Verified on 2026-07-28 that this is **not** a code fault: swapping in Google's test ad unit
made a banner appear immediately, and the log showed the UMP consent call to
`fundingchoicesmessages.google.com/a/consent` followed by ad requests to
`googleads.g.doubleclick.net/mads/gma`. Zero fill is explained by the requests coming almost
entirely from simulators (AdMob does not serve production ads to simulators and filters that
traffic) plus a newly verified app with no install base.

Do not diagnose this by opening the app repeatedly — a failed load renders at height 0 and
looks identical to no ad, and self-requests against the production unit look like invalid
traffic. Read the AdMob report instead: requests > 0 with impressions 0 means "wait", and
requests == 0 means "something broke".

The 使用者指標 / user metrics panel in AdMob reads all zeros because the app has no Firebase
or Google Analytics SDK. It is not a signal. Real download numbers are in App Store Connect
under 分析 / Analytics.

## 1.6.5 — released 2026-08-04

Everything `1.6.4` contained, plus the rejection fixes. Version numbers already bumped in both
places (`Info.plist` → `1.6.5 (20)`, project file → `MARKETING_VERSION 1.6.5` /
`CURRENT_PROJECT_VERSION 20`).

- [x] ATT prompt implemented in `ConsentManager`, fired after the UMP form, honoured by
      `AdMobBannerView` (personalized request only when granted). `NSUserTrackingUsageDescription`
      added in `Info.plist` and both `InfoPlist.strings`; `PrivacyInfo.xcprivacy` now declares
      `NSPrivacyTracking = true`. Builds clean, tests pass.
- [x] Verified on an iPhone 17 simulator 2026-08-02: the prompt appears on first launch right
      after the consent flow, granting writes `kTCCServiceUserTracking = 2` to the simulator's
      TCC database, and the banner then loads through the personalized (no `npa`) request.
      Worth re-checking after any change to the launch sequence — a prompt requested while the
      app is inactive is silently denied forever.
- [x] App Privacy in App Store Connect changed to declare tracking 2026-08-02: Device ID,
      Advertising Data, Product Interaction and Coarse Location answer "yes" to the tracking
      question; crash and performance data stay "no". This was the manual half of the 5.1.2(i)
      fix — the code change alone does not resolve the rejection.
- [x] `build/RainyClock-1.6.5-20.xcarchive` created and verified: app and extension both at
      `1.6.5 (20)`, ATT string present, `NSPrivacyTracking = true`.
- [x] Build 20 uploaded, the rejected `1.6.4` version renamed to `1.6.5` with the build
      attached, release notes and review note pasted, the rejection message answered in
      Resolution Center, and the whole thing submitted 2026-08-02. Copy used is in
      `docs/appstore-metadata.md`.
- [x] **Build 20 was then invalidated by ITMS-91064** — `NSPrivacyTracking = true` with an
      empty `NSPrivacyTrackingDomains` is not a valid combination, and filling the list would
      have blocked AdMob's endpoint for everyone who declines the prompt. Manifest reverted to
      `false`, `build/RainyClock-1.6.5-21.xcarchive` built and verified. Details in
      `docs/app-store-submission-checklist.md`.
- [x] **Pre-submission audit, 2026-08-02.** Six review dimensions, each adversarially verified.
      What it caught and what was fixed is in the section below; the archive is now
      `build/RainyClock-1.6.5-22.xcarchive` (21 was superseded before it was ever uploaded).
- [x] Website fixes pushed 2026-08-03 and verified live: `privacy-policy.html` serves the new
      Tracking section, the old "Track you across apps or websites" line is gone, and
      `support.html` describes the AlarmKit behaviour.
- [x] Second cleanup pass, 2026-08-03 — the audit's smaller findings, listed below.
- [x] **Uploaded, approved and released 2026-08-04.** 1.6.5 is the version live on the App
      Store today; the 5.1.2(i) and 2.1(a) findings are closed. The build number that shipped
      is not visible from the public listing — read it off App Store Connect if it matters.

## Pre-submission audit — what it found

The audit that ran before build 22 turned up one thing that would very likely have caused a
third 5.1.2(i) rejection, and two real bugs. Fixed:

1. **The live privacy policy said the app does not track you.** `docs/privacy-policy.html`
   listed "Track you across apps or websites" under *Data We Do Not Collect*, in both
   languages, while the app now shows an ATT prompt and the App Store Connect label declares
   tracking. That page is linked from the listing and from the AdMob consent form, so App
   Review reads it. Rewritten with a Tracking section that describes the ATT choice honestly.
   **This repo's `docs/` is the published site — the fix only counts once it is pushed.**
2. **The support page said the alarm cannot ring through silent mode.** Stale since `1.6.3`
   shipped AlarmKit, and directly contradicted by the store description. Rewritten, with a
   second entry covering the upgrade case where an old alarm still uses the notification path.
3. **A failed registration still looked like a scheduled alarm.** `AlarmViewModel` published
   and persisted `scheduledAlarmSummary` *before* `scheduleAlarm` could throw, while the error
   message lived only in memory — so the next launch showed the green "alarm scheduled" state
   for an alarm the system had never accepted. For an alarm app that is a missed alarm. The
   assignment now happens only after registration succeeds.
4. **Withdrawing ad consent did nothing.** `refreshConsentState()` could only ever latch
   `canRequestAds` to true, and the banner's `BannerView` is configured once in `makeUIView`,
   so a user who revoked consent through the privacy options form kept seeing ads until they
   relaunched — the opposite of what that form promises. The flag is two-way now, and
   `adConfigurationRevision` rebuilds the banner whenever an answer that shapes the ad request
   changes (which also fixes a late ATT grant never reaching the current session).
5. **The rain decision was frozen at scheduling time.** Both paths register a *weekly
   repeating* alarm at whatever time the rain check produced, so an alarm armed on a rainy day
   kept ringing early every week and one armed on a dry day never moved — against the intended
   behaviour recorded in `PRODUCT_DECISIONS.md`. Opening the app now re-decides an armed alarm
   whenever its rain check is older than four hours
   (`refreshScheduledAlarmIfWeatherIsStale()`), silently, keeping the previous status line if
   the refresh fails. Three regression tests cover 3 and 5.

6. **The rain check now runs while the app is closed.** Item 5 only covered users who open the
   app, which is not the product: an alarm set for Mon/Tue/Wed has to be decided by *each*
   morning's forecast. `BackgroundWeatherRefresh` registers two `BGTaskScheduler` budgets and
   re-asks for them after every successful scheduling — a `BGAppRefreshTask` aimed 45 minutes
   before the next lead-time point, and a `BGProcessingTask` aimed the evening before, which is
   the window iOS grants most readily because the phone is usually idle and charging. Whichever
   runs first re-decides that morning's alarm and re-arms the next pair. `Info.plist` now
   declares `UIBackgroundModes` (`fetch`, `processing`) and `BGTaskSchedulerPermittedIdentifiers`
   — **an identifier here that does not match the code crashes the app at launch**, so verify a
   launch after touching either.

   **iOS never guarantees background execution**, so the honest contract is three paths — the
   overnight processing task, the morning refresh task, and opening the app — and a morning
   where none of them ran still rings, on the previous decision. The alarm itself is a weekly
   repeat and never disappears; only the earlier-or-not decision can go stale. A hard guarantee
   would need silent pushes from a server, which this app deliberately does not have.

### Second cleanup pass (build 23)

- The alarm-time headline used the app's only hand-built formatter: it forced a 12-hour clock,
  so with 24-Hour Time on it read "7:00 PM" above a picker set to 19:00, and it took the
  Chinese word order from the *device* language, putting "AM" in front of English strings on a
  Simplified Chinese device. Now `date.formatted(.dateTime.hour().minute())`; the orphaned
  `alarm_am`/`alarm_pm` keys are gone from both `.strings` files.
- The sound preview set no `AVAudioSession`, so it inherited `.soloAmbient` and played nothing
  under the ring switch — in an app whose premise is piercing silent mode. Now `.playback` with
  `.duckOthers`, released with `.notifyOthersOnDeactivation`.
- The banner asked for `inlineAdaptiveBanner(maxHeight: 36)` in an anchored slot. Google
  documents inline adaptive as the scroll-view variant, and a 36pt cap excludes the standard
  50pt creative — the one untested hypothesis left for the 0.00% match rate. Now
  `currentOrientationAnchoredAdaptiveBanner`, reserving the height the creative reports.
- A failed ad load discarded its error; it logs under `#if DEBUG` now. That was the blind spot
  behind every "is the integration broken?" round-trip described above.
- A failed UMP consent update latched `hasRequestedConsent` permanently, so one networkless
  cold start cost both ads and the privacy-options row for that whole launch. The latch clears
  on error and the foreground handler retries.
- "Ad privacy options" used `try?` and showed nothing when the form had not finished loading —
  a documented no-op with no feedback. It now surfaces a localized alert.
- `AppEnvironment` gated the test ad unit on `#if DEBUG` alone, so a Release build run on a
  simulator requested production ads. Now `#if DEBUG || targetEnvironment(simulator)`.
- Deleted `RoutePolylineSampler` (nothing shipped calls it, and it traps on `Int(Double.nan)`
  at `maximumCount == 1`) and `AlarmTimeCalculator.nextAlarmDate` (only ever called by five
  tests, none of which touched the shipped entry point). The invariant those tests guarded —
  never schedule in the past — is now asserted against the function the app actually calls.

**Still open** (none block this submission): the store screenshots predate the 1.6.4 interface
redesign and the English (U.S.) listing carries only the Traditional Chinese ones; and the app
never reconciles its persisted "armed" state against AlarmKit's actual alarm list — worth doing,
but `scheduledAlarmIdentifiers()` swallows its throw, so a transient error would read as "your
alarm is gone". Propagate it first.

Also fixed in the same pass, from the audit's own list: an unbounded retry loop where a failed
re-registration and the auto-refresh reconciler spun against each other every 1.5 seconds; an
unattended refresh marking correctly typed addresses as invalid; and the ATT purpose string,
which promised "the ad at the bottom of the screen" — a banner that renders at zero height
whenever the request does not fill. If 2.1(a) comes back a second time, the appeal did not land and
      the options narrow to shipping a real Home Screen widget (iPhone only — still invisible
      on an iPad reviewer's device) or adding full iPad support.
- [ ] Optional, no longer blocking: check whether AdMob → Privacy & messaging lets the GDPR
      message drop its personalization purposes. Only worth acting on if the no-tracking
      posture is wanted back — it would mean reversing the privacy label a second time.

## 1.6.4 — rejected 2026-08-01

- [x] Debug builds use Google's test banner unit (`ca-app-pub-3940256099942544/2934735716`)
      via `#if DEBUG` in `RainyClock/AppEnvironment.swift`, so development traffic never hits
      the production unit again.
- [x] Alarm-tab weekday selector redesigned: selected days are filled blue circles with white
      text, unselected days plain dim text (no visible chip). All interface accents unified on
      the system blue — the cyan tints on the sound-preview button, Snooze toggle, Schedule
      button, ad-privacy button, and the Route tab's transport-mode chips are gone. Weather
      condition colors (yellow/cyan/blue on forecast icons) intentionally kept as-is.
- [x] Build 19 uploaded to App Store Connect 2026-07-29 (CLI export failed with the usual
      `Failed to Use Accounts`; Organizer upload worked, two known Google-SDK dSYM warnings).
- [x] English (U.S.) localization added to the listing — store name `Rainy Clock: Rain Alarm`
      ("Rainy Clock" and "RainyClock" are taken by other accounts). Done via the iris API from
      the browser session because the ASC UI hides the name-conflict error; details in
      `docs/appstore-metadata.md`.
- [x] New store screenshots uploaded by hand (source images in `pics/20260729/`).
- [x] Submitted 2026-07-29 and rejected 2026-08-01; the store metadata and screenshots uploaded
      for it stay valid for 1.6.5.

## 1.6.6 (24) — content settled, holds until 1.6.5 clears review

**Called done on 2026-08-09.** Nothing further is planned for this version; it waits for the
1.6.5 verdict and is then archived and uploaded. What it carries, all of it verified on
simulators in English and zh-Hant, 58 unit tests passing:

1. On-route rain sampling — the rain check covers points along the route, not just the two
   endpoints.
2. Dynamic Type no longer truncates the weekday chips, the commute-mode pills or the weather
   cards, and each row now renders at one consistent text size.
3. The route weather cards wrap instead of overflowing the screen, and five of them lay out
   as a W that reads home → office left to right.
4. Card labels rewritten: 住家 / 公司, Home / Office, and 路程 ¼ ½ ¾ / ¼ way, Halfway, ¾ way.

Each of those has its own section below.

**Archived 2026-08-09 as `build/RainyClock-1.6.6-24.xcarchive`** and checked: app and
`RainyClockAlarmWidget.appex` both report `1.6.6 (24)`, the ATT usage string is present,
`NSPrivacyTracking` is `false` (the combination ITMS-91064 accepts), and the binary carries
the production ad unit rather than Google's test one. Release notes for `1.6.6` are written in
`docs/appstore-metadata.md`, in both languages, and merge the `1.6.4`/`1.6.5` bullets because
neither of those ever reached a user.

**Build 24 was uploaded to App Store Connect on 2026-08-13** and accepted — "Upload
succeeded", then processing. It went up from the command line, which the checklist said was
impossible here:

```bash
xcodebuild -exportArchive -archivePath build/RainyClock-1.6.6-24.xcarchive \
  -exportOptionsPlist build/ExportOptions-AppStoreUpload.plist \
  -exportPath build/export-1.6.6-24 -allowProvisioningUpdates
```

The Apple Account grant that lapsed around `1.6.2 (17)` is evidently valid again, so the
Organizer detour is no longer needed — try the CLI first and keep Organizer as the fallback.
The two dSYM warnings for `GoogleMobileAds` and `UserMessagingPlatform` appeared as always;
they are expected and do not block the upload.

**Uploading is not submitting.** Build 24 is only sitting in App Store Connect. Still to do
there, by hand: create a new **`1.6.6` version record**, paste the 1.6.6 notes from
`docs/appstore-metadata.md` (both languages), attach build 24 once it finishes processing,
then submit for review.

No Resolution Center reply is involved this time: the 1.6.4 rejection was closed by the
1.6.5 release.

**Version numbers bumped 2026-08-09** to `1.6.6` / build `24`, in `Info.plist` *and* the
project file, verified in a Debug build: app and `RainyClockAlarmWidget.appex` both report
`1.6.6 (24)`. **`build/RainyClock-1.6.5-23.xcarchive` is unaffected and is still the archive
to upload for the pending 1.6.5 submission** — it was archived before the bump. Only rebuild
build 23 from source if you first put the version numbers back.

**On-route rain sampling** landed in `MapKitRouteWeatherService` 2026-08-08: the rain check
now covers interior points along the MKDirections route (midpoint from 4 km, quarter points
from 20 km) in addition to home and office — any of them over the threshold pulls the alarm
earlier. Transit and any route failure degrade to the endpoint-only check. The distance
rules and the sampler match the Android `RouteSampler` exactly; the degenerate cases that
trapped the deleted `RoutePolylineSampler` are covered in `WeatherSampleMapperTests.swift`
(`RoutePolylineSamplerTests`). Decision recorded in `PRODUCT_DECISIONS.md`.

Note the behaviour change in the release notes when this version goes out. Written on a Linux
container without Xcode, so the code needed a compile check before archiving — **done
2026-08-09 on the Mac**: `xcodebuild test` against an iPhone 17 Pro simulator, 57 tests passed
and none failed, the six `RoutePolylineSamplerTests` among them. Re-run after the Dynamic Type
work below landed, so that count covers both.

**The extra sample points broke the card row, fixed 2026-08-09.** The Route tab laid the
weather cards out in a plain `HStack` written when there were only ever two of them. Rendered
on an iPhone 16e simulator against a stubbed snapshot (the real path needs addresses, network
and a signed WeatherKit build), the sample counts the sampler can actually produce look like
this:

| Segments | Commute | Before | After |
| --- | --- | --- | --- |
| 2 | < 4 km, transit, route failure | fine | unchanged |
| 3 | 4–20 km | fine at standard sizes | unchanged; wraps 2+1 at accessibility sizes |
| 5 | ≥ 20 km | **row wider than the screen** — first and last card clipped at the bezel, the page lost its 20pt margins, titles broke to "Com-/mute s…" | wraps 3+2 |

`RouteWeatherGrid` now wraps at three cards per row (two at accessibility sizes), and the
card's condition line went `lineLimit(1)` → `2`, which is what truncated "62% 降雨機率" to
"62…" at accessibility sizes even with only three cards. A ≥20 km commute is ordinary here —
Taipei to Hsinchu hits it — so this was a real user-facing break, not a corner case.

**Five cards then became a W** (2026-08-09): stops 1, 3, 5 on the top row, stops 2 and 4
dropped onto a lower row nesting in the gaps between them. A plain 3+2 grid reads wrong —
the fourth stop starts a new row at the far left, *behind* the second one — whereas the W
keeps every card further right than the one before it, so the block reads home → office left
to right. Geometry: the lower row is simply centred, which lands each card exactly half a
card plus half a gap off the row above; the width comes from a `GeometryReader` in the top
row's background. Only odd counts stagger (an even count fills the lower row completely and
leaves no gap to nest into), and only below accessibility sizes.

Shortening the labels was considered first and **measured, not assumed**: with
"中點1/2/3" and the old `HStack` the row still overflowed by 40pt. A card cannot go below
~70pt wide whatever the title says — the weather glyph is a hardcoded 42pt, the condition
line needs ~60pt at its minimum scale, and "住家附近"/"公司附近" are not shortenable. Five of
those plus spacing is 390pt against 350pt of usable width.

**The card labels were rewritten** the same day. The endpoints lost their qualifier in both
languages — `segment_home_area` and `segment_office_area` now read "Home" / "Office" and
住家 / 公司, not "Home area" / 住家附近. (The keys still say `_area`; the addresses above them
still say 住家 / 工作, so the card and the field it comes from differ by a word in Chinese.)
The interior samples stopped being "通勤途中取樣 N" / "Commute sample N"
and now say where they are: **路程 ¼ / ½ / ¾**, **¼ way / Halfway / ¾ way**. A short commute
samples one point and it is the true midpoint, so it reads 路程 ½ / Halfway.

**The card text now shares baselines across the row.** Each card centres a title / icon /
rain-figure stack, so a one-line "Cloudy" made a shorter stack than a two-line "62%
precipitation" beside it and centring dropped that card's title below its neighbours'. Each
card now lays every peer's title and rain figure out behind its own with `.hidden()`, so all
of them reserve the tallest card's height for each line and the three tiers line up. This
beats reserving a fixed two lines: nothing is padded when the row happens to be all
one-liners, and it holds in any language and at any text size without measuring text.

"中點1/2/3" was rejected for this: at ≥20 km the three points sit at 1/4, 1/2 and 3/4, so
two of the three are not the midpoint and the label would mislead. `interiorSegmentName`
therefore derives the fraction from the position — sample `index` of `total` sits at
`(index + 1) / (total + 1)` — rather than hardcoding three names. That only holds while the
sampler spaces its points evenly, so `RoutePolylineSampler.interiorSampleFractions` is now a
separate function and `testSampleFractionsAreEvenlySpacedSoTheNamesStayTrue` fails if a
future fraction list breaks the assumption. **The Android strings still say the old thing**
and are untouched here.

**Dynamic Type no longer truncates the controls** (2026-08-09). Reported from a real user:
on an iPhone with an enlarged system font the weekday circles all read "…". Three controls
sized text into a fixed box and truncated once the text style scaled past xxxLarge:

- the seven weekday chips (~34pt wide each on a 6.1" phone) — now wrap to **four per row**
  at accessibility sizes, and the circle grows with the text (`@ScaledMetric`, capped at 76pt);
- the four `RouteModePicker` pills — now **two columns** at accessibility sizes, with the
  "Mode" label moved onto its own line (`AnyLayout` switching `HStack`→`VStack`);
- the route weather card titles — `lineLimit(1)` → `2`, centred.

`minimumScaleFactor` alone was not enough, and is the reason both rows then looked ragged:
it shrinks each label independently to fit its own box, so "Fri" stayed full size next to a
shrunken "Wed", and `大眾交通` came out visibly smaller than `開車`. `RowLabelFont.fittedSize`
measures the widest label in the row with `UIFont` and gives every label in that row the same
size; a `GeometryReader` supplies the row width, which is free here because both grids have a
computed height. `minimumScaleFactor` stays as a fallback for the first layout pass.

Deliberately *not* fixed by pinning the font size or swapping in images: both would leave the
people who enlarged the font unable to read the control, and images cannot localize. Nothing
below xxxLarge changes shape. Verified on an iPhone 16e simulator via
`xcrun simctl ui <device> content_size accessibility-extra-extra-extra-large`, in English and
zh-Hant. **The Android `WeekdaySelector` has the same defect** — a fixed `Modifier.size(40.dp)`
circle — and is untouched here.

## AI voice alarm — in progress

An alarm that wakes you with generated speech instead of a tone. Not shipping in any version yet.

**The user writes the words; the app writes the delivery.** Decided 2026-08-30. The text is
the user's own — the app does not compose it — but the app splits it into sentences and tags
each with an emotion before synthesis, so the line is performed rather than read flat.

That split is why the proxy takes an emotion *id* per segment and never a tag. Google sorts
bracketed markup into four modes, and the one everybody reaches for first is the broken one:

> **Mode 3: Vocalized markup (adjectives)** — "The markup tag itself is spoken as a word,
> while also influencing the tone of the entire sentence." … "Warning: Because the tag itself
> is spoken, this mode is likely an undesired side effect for most use cases. Prefer using the
> Style Prompt to set these emotional tones instead."

`[cheerful]`, `[urgent]`, `[encouraging]` are all Mode 3, so an alarm built the obvious way
says the word "cheerful" out loud at 7 a.m. The emotion table therefore maps each intent onto
Mode 2 (delivery: `[shouting]`, `[extremely fast]`) or Mode 4 (pacing), which carry the same
feeling without being read out, and a test asserts no adjective-form tag can ever reach the
model. Adverb-form tags (`[cheerfully]`, `[warmly]`, `[gently]`) are reported reliable by a
third-party evaluation but are undocumented by Google; they are recorded against each emotion
and stay off behind `TTS_ALLOW_UNVERIFIED_TAGS` until somebody has actually listened.

**Which sentence gets which emotion is decided by a model, not by the app.** The split is done
in code and the model only labels the pieces — it is never handed the text and asked for a
rewrite, because the words are the user's and an alarm that says something they did not type
is worse than one read flat. Labels come from the same closed vocabulary, so the labeller
cannot invent a tag either. Any failure — quota, timeout, a hallucinated id — degrades that
sentence to neutral and the clip is still generated.

**First contact with the live API, 2026-08-30.** A key was issued and the pipeline ran
end-to-end; three things came out of it that would otherwise cost someone an afternoon:

- **`gemini-2.5-flash` is not available to new projects at all.** The API answers 404 with
  "no longer available to new users … We recommend you to use the Interactions API". The three
  TTS models *are* available, including `gemini-2.5-flash-preview-tts`, so the cheap costing
  above still holds — but anything text-only must use `gemini-3.6-flash` or a `-lite` sibling.
- **The free tier is unusable for development, not only for shipping.** Roughly ten TTS calls
  exhausted the quota, and it does not recover on a useful timescale. Billing has to be
  enabled before any real work; the EEA/UK clause already required it before any release.
- **Content blocking is noise, not judgement.** `早安，該起床囉` — good morning, time to get
  up — was refused with `content_blocked` on roughly one call in six, with identical requests
  either side of it succeeding. It is not about the words, so the proxy retries it like a 5xx
  and only reports 422 when every attempt is refused. An app that surfaced the first refusal
  as "your text was rejected" would be telling users something both wrong and unactionable.

**The Mode 3 warning does not reproduce, measured 2026-08-30.** Google documents that
adjective-form markup is "spoken as a word". On `gemini-2.5-flash-preview-tts` with a
Traditional Chinese transcript, it is not — across four samples each of eight tags, including
Google's own examples:

| tag | spoken? | vs untagged |
| --- | --- | --- |
| control: planted word "hello" | **4/4 spoken** | +1.11 s |
| `[curious]`, `[bored]` (Google's own Mode 3 examples) | 0/4 | +0.33 s, +0.79 s |
| `[cheerful]`, `[urgent]`, `[encouraging]` | 0/4 | +0.20 s, +0.29 s, +0.12 s |
| `[cheerfully]` (adverb form) | 0/4 | +0.30 s |
| `[shouting]`, `[extremely fast]` (documented Mode 2) | 0/4 | +0.60 s, −0.06 s |

The positive control is what makes the negatives mean anything: a real word costs 1.1 s and is
transcribed every time, while no tag cost more than 0.79 s or appeared once in 32 transcripts.
The durations also show the tags *working* — `[bored]` drags the line out, `[extremely fast]`
shortens it.

**Rate limits decide the model, not price — measured 2026-08-30 on a paid Tier 1 project.**
`gemini-2.5-flash-preview-tts` on the Gemini API is capped at **100 requests per day**; the
error names the metric outright (`generate_requests_per_model_per_day, limit: 100`) and says
to retry in ten hours. That is the whole app's budget for a day, not one user's — it is not a
rate limit, it is an off switch. `gemini-3.1-flash-tts-preview` uses dynamic throughput limits
and kept serving after 2.5 had stopped, so it is now the default despite costing twice as much
per second (NT$0.20 against NT$0.10 for a ten-second clip, which is not the number that
decides this). Tier 2 needs US$100 of cumulative spend plus three days, and whether it lifts
the 2.5 cap is unknown.

**The bigger consequence: the Gemini API is probably the wrong surface for production.** The
same models are reachable through Cloud Text-to-Speech at **150 QPM with no documented daily
cap**, raisable on request, and with an explicit `cmn-TW` locale field the Gemini API path does
not have. The original reason for choosing the Gemini API — Cloud TTS refuses API keys and
wants a service account — was reasoning about a bake-off script, not production: this proxy
runs on Cloud Run, where a service account is the *native* credential and strictly less work
than shipping and rotating a key. Switching surfaces is the next infrastructure decision.

Scope: one model, one voice, one style prompt, zh-Hant only, four samples. Enough to stop
designing around the warning, not enough to assume it is wrong everywhere — English in
particular is untested, and these are preview models. The emotion table records how each tag
was cleared so a future reader can tell measurement from assumption.

**Vendor: Google Gemini-TTS**, decided 2026-08-30. It is the only one with both Taiwanese
Mandarin and real prompt-driven tone control. Azure has the best zh-TW accent but its three
zh-TW voices support **zero** emotion styles; OpenAI has the best tone control but its voices
are English-native and audibly foreign in Mandarin. Model is `gemini-2.5-flash-preview-tts`,
not `3.1` — half the price for output audio and without 3.1's documented habit of returning
text tokens instead of audio.

Costing, verified against Google's own pricing page: output audio is billed per token at
US$10/1M, 25–32 tokens a second (the pricing page and the tokenisation doc disagree; assume
32). A 10-second clip is therefore about **NT$0.10**. The Gemini API's free tier is unusable
here — Google's terms require paid services for API clients available to users in the EEA,
Switzerland or the UK, which an App Store listing reaches.

Done:

- [x] **Runtime-generated sounds work at all** — the device test above. This was the feature's
      single make-or-break unknown, and the only prior public report of it was a failure.
- [x] **Foundation in the app** (`0a87602`): `AlarmSound.aiVoice`, the clip name beside the
      enum rather than in it, `restorableCases` so the settings decoder stops erasing it, a
      fallback to a shipped tone when the file is missing, and `GeneratedVoiceStore` owning
      `Library/Sounds` and the 28 s / 10 s constants.
- [x] **`/v1/tts` on the existing `weather-proxy/`.** The Gemini key never ships. Reuses the
      same three guards the weather route has, sized for a different asset: WeatherKit's
      allowance is a call count that resets, but Gemini bills per token, so a scraped key is
      an unbounded bill and `DAILY_TTS_LIMIT` (2,000 clips ≈ US$6.40) is a real ceiling rather
      than an alert. **A Cloud Billing budget would not do this — those only notify.**
      The client sends a persona id and the words; it cannot send a voice name or a style
      prompt, or the endpoint becomes free general-purpose Gemini for anyone who reads the URL
      out of the app. Deploy needs `GEMINI_API_KEY` set; without it the route answers 503 and
      the app falls back to a tone, so a weather-only deployment still boots.

Still open, roughly in order:

- [x] **Deployed 2026-08-31.** `/v1/tts` is live on the same Cloud Run service as the weather
      proxy, revision `00007-jjc`, memory raised 256Mi → 512Mi because the TTS cache holds
      audio rather than a few hundred bytes of forecast and an OOM here would take the
      weather down with it. The Gemini key is in Secret Manager as `gemini-api-key`,
      matching how the WeatherKit private key is already held — it is not in the service's
      env config, not in the repo, and not in the app. The Cloud Run service account needed
      `roles/secretmanager.secretAccessor` granted **on the new secret**; the first deploy
      failed on exactly that and left the previous revision serving, so the weather never
      went down. Verified after: weather returns the same 25 hours it did before, and a
      real clip generates end to end. `VoiceProxyURL` in `Info.plist` now points at it.
- Free quota and the rewarded exchange ship, but nothing meters cost server-side beyond
  `DAILY_TTS_LIMIT` (2,000 clips ≈ US$6.40/day).
- **Whether the alarm can name a road.** `RouteWeatherSegment.name` is not a street name — it
  is `住家` / `路程 ½` / `公司`, from a closed set of localised constants, and interior samples
  are empty below 4 km and for transit entirely. So "忠孝東路那段會濕" is not currently
  sayable; it renders as "路程一半那段會濕". Either reverse-geocode a thoroughfare at the
  wettest sample (real work, needs its own fallback for Taiwan geocoding) or reword around
  elapsed time. **This is a product decision and it is load-bearing** — the route-level line is
  the only part of this feature no competitor can copy.
- Free quota, and whether to meter at all. **Recomputed 2026-09-01: rewarded video now pays
  for this.** Two things changed under the old arithmetic: speech is capped at 10 s
  (`GeneratedVoiceStore.maximumSpeechDuration` — the 28 s clip is mostly tone, which costs
  nothing), and the Cloud TTS switch in `weather-proxy/tts.js` escapes the 100/day cap that
  had forced the default onto `3.1`, so the model is `gemini-2.5-flash-tts` again at
  US$10/1M audio tokens. One generation is ~320 tokens ≈ US$0.0032 ≈ NT$0.10; a completed
  view at the US$5 eCPM planning figure returns ~NT$0.155, about 1.5× — break-even is
  ~US$3.2 eCPM, below plausible iOS rewarded rates rather than above all of them. (The
  earlier "US$19 eCPM to break even" was 30 s clips on `3.1` at twice the token price.) So
  the one-video-one-generation exchange is at worst break-even, and Guideline 3.2.2(x)
  permits ad-gating — what stays open is only how generous the free tier should be. One
  caveat: billing follows what the model speaks, not what `truncateToSeconds` keeps, so
  text long enough to overrun the cap still costs ~NT$0.01 a second past it.
- `docs/privacy-policy.html` states the app transmits nothing to a server and names alarm time
  and rain lead time as never leaving the device. Both become false the moment this ships;
  those sentences need rewriting, not an appended paragraph.
- Google's API terms prohibit use in a service "likely to be accessed by individuals under the
  age of 18". Unresolved, and it is a binary ship gate.

## Backlog

Ordered by value, not urgency. None of these block a release.

**Next update: add Unity Ads as a second demand source under LevelPlay.** *(Decided
2026-09-06 after the ironSource approval email; not urgent, ride along with the next build.)*
The app links only the LevelPlay core (`UnityMediationSDK`) and no network adapter, so the
banner has exactly one bidder: the ironSource Exchange. ironSource's own direct-demand
network was sunset on 2026-04-30 and those budgets moved to Unity Ads ("Unity Vector"),
which is why the main line in Performance clears about $0.20 eCPM. Unity's sunset FAQ
says LevelPlay users need do nothing to keep iSX serving, and in the same breath says to
integrate the Unity Ads SDK and activate the network in LevelPlay to reach the moved demand.
This is *adding a network under LevelPlay*, not replacing LevelPlay; the consent
architecture stays. Steps: (1) dashboard Setup → Networks → Unity Ads, link the app to a
Unity project for a Game ID and let it create the Banner bidding instance; (2) add the SPM
package `ironsource-mobile/LevelPlay-UnityAds-Adapter-Swift-Package`, which pulls in the
Unity Ads SDK; (3) verify on the **device**, not the simulator — another statically linked
SDK is exactly the `-ObjC` launch-crash shape, and the test device must still be listed
under Setup → Test devices first; (4) re-check the privacy manifest the Unity Ads SDK ships
and the App Privacy answers (already declare tracking; Unity Ads and ironSource are the
same controller, so the consent copy should not need to change); (5) accept the larger
binary. Expected effect is eCPM, not volume — at the current scale the dollars stay small
either way, and whether the banner is worth keeping at this DAU is a product call, not
this item.

0. **Handle the users whose background refresh can never run.** *(Raised 2026-08-03, approach
   not decided.)* `BackgroundWeatherRefresh` is what makes each morning's alarm reflect that
   morning's forecast, and it silently does nothing when **Background App Refresh is switched
   off** (Settings › General) or the phone is in **Low Power Mode**. Those users keep whatever
   decision the last foreground run made and have no way to know. The app can detect both —
   `UIApplication.shared.backgroundRefreshStatus` and `ProcessInfo.processInfo.isLowPowerModeEnabled`,
   the latter with `NSProcessInfoPowerStateDidChange` — so the open question is what to *do*
   with that, not how to know. Sketches, none chosen: a notice on the Alarm tab with a
   deep link to Settings via `UIApplication.openSettingsURLString`; a local notification the
   evening before a scheduled day asking the user to open the app once; or state it plainly in
   the UI and accept it. Whatever is chosen must not nag people who never see rain anyway.

1. **Add the English App Store localization.** The listing has only Traditional Chinese, so
   every storefront including the US serves Chinese description, keywords, and release notes.
   The English copy is already written in `docs/appstore-metadata.md` and has never been used.
   Metadata-only change — no new build needed, but it must ride along with a version submission.
2. **Clear the "Sign-in required" checkbox in App Review Information.** It is checked with a
   demo account even though the app has no login. It has never caused a rejection, but the
   credentials sit there for no reason.
3. **Refresh `SKAdNetworkItems` occasionally.** 50 identifiers were declared in `1.6.2 (17)`
   from Google's list; the relevant list is now ironSource's / Unity's, and adding Unity Ads
   (above) is the natural moment to regenerate it.
4. **Confirm the ironSource payments and tax profile is complete.** Earnings are withheld
   past the payout threshold otherwise. Worth settling before there is anything to withhold
   — the first $0.57 arrived in the 14 days to 2026-09-06. (This item used to say AdMob;
   that account is gone.)
5. **Google Places fallback is dormant.** `GooglePlacesAPIKey` is empty in
   `RainyClock/Info.plist`, so address lookup relies entirely on Apple geocoding.

## Environment gotchas

Things that have cost time before and will again.

- **Xcode's Apple Account grant lapses.** `xcodebuild -exportArchive` then fails with
  `Failed to Use Accounts`. The reliable path is `open -a Xcode build/<name>.xcarchive` and
  Distribute App from Organizer, leaving **Manage Version and Build Number** unchecked.
- **`find`ing the built `.app` picks up stale bundles.** `DerivedData/Build/Products/` still
  holds a `Release-iphonesimulator` build from June. Always take the explicit
  `Debug-iphonesimulator/RainyClock.app` path and confirm `CFBundleShortVersionString` before
  installing to a simulator.
- **Version numbers live in two places.** The app's `Info.plist` hardcodes them
  (`GENERATE_INFOPLIST_FILE = NO`) while `RainyClockAlarmWidget` derives them from build
  settings. Both must be bumped together or App Store validation rejects the upload.
