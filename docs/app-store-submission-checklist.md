# Rainy Clock App Store Submission Checklist

Ongoing state and the backlog live in `docs/STATUS-IOS.md`; this file is the submission reference.

> The table below went three versions stale before anyone noticed, the same way `STATUS-IOS.md`
> did. Two files carrying the same state will drift; the App Store listing is the only thing
> that cannot. Before trusting either, run the `itunes.apple.com/lookup` command in
> `docs/STATUS-IOS.md`.

## Current Build

| Item | Status |
| --- | --- |
| App version | `1.8.0` — typhoon closures, alarm master switch, Next Alarm widget (1.7.1 is live) |
| Build number | `1.8.0 (39)` — uploaded 2026-10-02 08:27:46 (Asia/Taipei) from `4e218c2` (Xcode 27.0): the medium widget also shows weather on today's entry. Previously `1.8.0 (38)` — uploaded 2026-10-02 03:43:06 (Asia/Taipei), built with Xcode 27.0 / iOS 27 SDK from `3cf0fab`; TestFlight only, not submitted. Previously `1.7.1 (37)` — address suggestions restored and typed-address confirmation surfaced, on top of 36; uploaded 2026-09-24 15:00:13. Previously `36` — App Attest recovery after a reinstall and iOS 27 TestFlight price fallback, on top of 35's location, ATT timing and notification crash fixes; 387 tests passed; uploaded 2026-09-24 12:49:53, Apple processing. |
| Review status | 1.7.1 (37) approved and live on the App Store 2026-09-26 05:33 UTC (TW and US). Before that: Waiting for Review since 2026-09-25 00:10 (resubmission of the 1.7.0 (34) rejection). Earlier: 1.7.0 (34) rejected 2026-09-23: 6.5-inch screenshots, location lookup, and missing ATT prompt/recording. Build 35 uploaded to TestFlight, not resubmitted. zh-Hant 6.5-inch media verified inheriting the new 6.9-inch screenshots; en-US cleanup still unverified. iOS 27 physical-device validation and recording remain pending. |
| Last released | `1.6.9` — public listing confirmed 2026-09-10 |
| Bundle identifier | `com.shukaihu.RainyClock` |
| Extension bundle identifiers | `com.shukaihu.RainyClock.AlarmWidget`; `com.shukaihu.RainyClock.DayOffNotification` (temporary-closure rollout stays disabled in 1.7.0) |
| Device family | iPhone only |
| Primary language | Traditional Chinese |

Latest investigation handoff: [2026-09-23 — TestFlight USD cards / native TWD payment sheet](HANDOFF-IOS-2026-09-23.md). Build 35 does not change product pricing logic; no new physical-device price result has been received.

## Submission History

- `1.7.1 (37)` — Uploaded to TestFlight 2026-09-24 15:00:13; 395 tests passed, 0 failed/skipped. Restores the Home/Work suggestion list (the 1.7.0 sheet left its FocusState in the presenting view), confirms exact same-name typed addresses silently, and shows pending/not-found state on the Route rows. The App Store version record is still 1.7.0 and must become 1.7.1 before submission. Resubmitted to App Review 2026-09-25 00:10 with the reply to the 1.7.0 (34) rejection, the ATT recording (reply + App Review Information attachment) and new notes (`docs/appstore-review-notes-1.7.1-37.txt`); Approved; live on the App Store 2026-09-26 05:33 UTC.
- `1.7.0 (36)` — Uploaded to TestFlight 2026-09-24 12:49:53; 387 tests passed, 0 failed/skipped. Fixes membership stuck forever after a delete and reinstall (App Attest `invalidInput` never rotated the key), and iOS 27 TestFlight plans hidden because the storefront reports TWN while products still come back in USD. Not submitted to App Review.
- `1.7.0 (35)` — Uploaded to TestFlight 2026-09-23 22:31:20; 377 tests passed, 0 failed/skipped. Includes location, ATT and notification-response crash fixes. Apple processing complete; internal `SKHU tester` (1 tester) has access; bilingual test notes saved and verified. Not submitted to App Review.

- `1.7.0 (34)` — **Rejected** 2026-09-23, submission `5a8a1d24-97da-4eb9-89a7-350274dccc85`: 2.3.3 (6.5-inch screenshots do not sufficiently show the app in use), 2.1(a) (location could not be found), and 2.1 Information Needed (ATT prompt not found; physical-device recording requested). Reviewed on iPad Air 11-inch M3 and iPhone 17 Pro Max running iPadOS/iOS 27.0. Source is the user's review message; no ASC changes or new build in this diagnostic pass. See [findings and resubmission requirements](APP-REVIEW-2026-09-23.md).
- `1.5 (7)` — **Rejected** 2026-07-22, Guideline 5.1.2(i) (Privacy – Data Use and Sharing): the App Privacy label declared data used to track the user, but the app has no App Tracking Transparency prompt.
- `1.6 (10)` — Resubmitted 2026-07-23 with the 5.1.2(i) fix below. **Rejected** 2026-07-24, Guideline 5.2.5 (Legal – Apple Sites and Services): WeatherKit data shown without the required Apple Weather attribution mark and legal link.
- `1.6.1 (16)` — Submitted 2026-07-25 with the 5.2.5 fix (official Apple Weather mark + legal link in the Route tab weather section), a review note explaining WeatherKit usage, and a screen recording captured on a physical iPhone. **Approved 2026-07-26 and released to the App Store the same day.**
- `1.6.4 (19)` — Submitted 2026-07-29. **Rejected 2026-08-01** on two guidelines (submission ID `102b5c98-1537-472f-a998-cb8de5f68cff`, reviewed on an iPad Air 11-inch M3 running iPadOS 26.6):
  - **5.1.2(i)** — the UMP GDPR prompt tells users the app personalizes advertising, but there is no ATT prompt. Fixed in `1.6.5`; see the 5.1.2(i) section below.
  - **2.1(a)** — "We were unable to add Widgets at the Home Screen." Not a defect; answered in the reply, see the 2.1(a) section below.
  Apple offered to approve the build as a bug-fix submission if asked; we declined and fixed both instead.
  Content of the build: Debug builds request Google's test banner unit instead of the production one, the weekday selector was redesigned as circle chips, and accents were unified on the system blue.
- `1.6.5 (23)` — Rebuilt 2026-08-03 with the background weather refresh (`UIBackgroundModes` = `fetch`, `processing`; the review note explains what they are for) and the audit's smaller fixes. **Shipped: this is the build behind the 1.6.5 released on 2026-08-04.**
- `1.6.5 (22)` — Never uploaded. Rebuilt 2026-08-02 after the pre-submission audit: live privacy-policy and support pages corrected, a failed alarm registration no longer looks scheduled, ad-consent withdrawal takes effect, and an armed alarm re-decides its rain check when the app is opened. See `docs/STATUS-IOS.md`.
- `1.6.5 (21)` — Rebuilt 2026-08-02 with `NSPrivacyTracking` back to `false`, which is what build 20 tripped over. Never uploaded; superseded by 22.
- `1.6.5 (20)` — **Submitted 2026-08-02 and invalidated the same day (ITMS-91064)** before review ever saw it. Adds App Tracking Transparency (5.1.2(i) fix), with the 2.1(a) finding answered by reply rather than by code. App Privacy in App Store Connect was changed the same day to declare tracking. Because `1.6.4` never shipped, this submission also carries its interface changes, its release notes, and the English (U.S.) localization — the shared-app-info changes App Store Connect listed in the submission dialog were that localization, which is expected.
- `1.6.3 (18)` — Submitted 2026-07-27. **Approved and released 2026-07-28, first attempt.** AlarmKit's usage-description prompt and the new widget extension raised no review questions. Adopts AlarmKit on iOS 26+ (alarm pierces silent mode and Focus), adds snooze on/off with a 1–15 minute interval, the system default alarm tone, automatic re-scheduling when settings change (address changes instead remove the alarm), and the colour-coded status line. First build to ship the `RainyClockAlarmWidget` extension. Release notes and updated description are in `docs/appstore-metadata.md`.
- `1.6.2 (17)` — Submitted 2026-07-27. **Approved and released the same day.** Declares Google's `SKAdNetworkItems` list (50 identifiers) in `Info.plist`, which the shipped builds were missing, and adds the UMP consent flow for EEA/UK/Swiss users. Also the first version to carry a marketing URL (`https://shukaihu.github.io/RainyClock/`), which is what unblocks AdMob's app-ads.txt verification — see below. Release notes are in `docs/appstore-metadata.md`.

## AlarmKit Setup (`1.6.3`)

The alarm rings through silent mode and Focus on iOS 26+ via AlarmKit. Points that matter for submission:

- **No Apple approval needed.** AlarmKit is not gated like Critical Alerts — it only needs `NSAlarmKitUsageDescription` in `Info.plist` (localized in both `InfoPlist.strings`) plus the one-time user prompt. Verified on an iOS 26.2 simulator: the prompt shows the app's own description text.
- **A new target ships with the app: `RainyClockAlarmWidget`** (app extension, `MinimumOSVersion` 26.0, embedded under `PlugIns/`). It renders the snooze Live Activity. AlarmKit requires a widget extension for any alarm that can enter the countdown state, and Apple warns the system may drop such alarms without one — do not remove it. **Its `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` must stay in lockstep with the app's `Info.plist`**, or App Store validation rejects the upload. The app's `Info.plist` hardcodes the version (`GENERATE_INFOPLIST_FILE = NO`), while the extension derives it from build settings, so both need bumping.
- Automatic signing has to mint a second provisioning profile for `com.shukaihu.RainyClock.AlarmWidget` at archive time. First archive after this change may need a Xcode round-trip to register the new App ID.
- The app also declares `NSSupportsLiveActivities`.
- **Upgrade path.** An install that reaches iOS 26 without rescheduling keeps ringing through its old notification alarms (no gap, but no silent-mode piercing either). `rearmAlarmsIfNeeded()` therefore runs on every system, not just pre-26, and the Alarm tab shows `alarmkit_reschedule_notice` until the user schedules once and AlarmKit takes over.
- **Localized strings shown by the alarm** are built with `bundle: .atURL(Bundle.main.bundleURL)` rather than the default `.main`. The widget extension decodes them in its own process, where `.main` is the appex and the lookup would fall back to printing the raw key.
- **Verified on simulator:** authorization prompt, alarm arming, firing at the scheduled minute, `breaksThroughFocus: true` in the alert request, the selected `.wav` resolving from the app bundle, and the widget extension rendering `AlarmAttributes<CommuteAlarmMetadata>`.
- **AlarmKit alert sounds have no 30-second limit, and do not have to ship in the bundle.**
  Measured on a physical iPhone 16 Pro, iOS 26.5.2, 2026-08-30, with a throwaway harness
  (`RainyClock/AlarmSoundLab.swift` on branch `ios/alarm-sound-lab`) playing spoken
  second-by-second counting so the played extent is audible:
  - A **120 s** bundled `.wav` played as the alert sound — no fallback to the system tone.
    Every rung from 10 s to 120 s passed. This **contradicts the only public guidance**, an
    Apple engineer's forum reply saying "less than 30 seconds"; that number is
    `UNNotificationSound`'s documented limit (which *is* real, and still binds the pre-26
    fallback path) and does not apply to AlarmKit. Apple documents no AlarmKit limit at all.
  - A file **written at runtime** into the app container's `Library/Sounds`, under a name
    that exists nowhere in the bundle, also played. So alarm audio can be generated or
    downloaded on device — it does not have to be a build-time resource. Note the directory
    does not exist in a fresh container and must be created; the harness also sets
    `.completeUntilFirstUserAuthentication` so the file stays readable while the device is
    locked. This contradicts Apple Forums thread 798140 (FB19779004, iOS 26 beta 8), where
    the same manoeuvre silently fell back to the default — evidently fixed since.
  - Both facts are undocumented and were observed on one OS build. AlarmKit's sound
    behaviour has already changed across 26.0/26.1, so **re-check after any iOS update**
    before relying on either.
  - Still unmeasured: whether a long sound plays to its end, whether it loops, and how long
    an unattended alarm keeps alerting. AlarmKit exposes no looping API, and the observed
    behaviour flipped between 26.0 (played once) and 26.1 (repeats until stopped).
- **Still needs a device pass before submitting:**
  - Ringing with the physical ring/silent switch off (a simulator has no switch).
  - The snooze button round-trip.
  - The snooze Live Activity showing translated text ("賴床中"), not the raw key `alarm_snoozing_title` — this is the cross-process bundle resolution above.
  - Archiving: automatic signing has to mint the extension's provisioning profile, and both version numbers must match.

## Rejection Resolution (5.2.5 — WeatherKit attribution)

- `WeatherAttributionView` fetches `WeatherService.shared.attribution` and renders the official combined dark Apple Weather mark, linked to Apple's `legalPageURL`.
- The mark sits outside the "forecast loaded" conditional so it is always visible in the Route tab weather section (the primary WeatherKit surface). Build 16 removed it from the Alarm tab by preference.
- App Review note (English) described the WeatherKit usage and where the attribution appears; a screen recording from a physical iPhone was attached to the reply.

## Rejection Resolution (5.1.2(i))

Rejected twice on this guideline, from opposite directions. Read both halves before touching
anything in this area — the two states each look correct in isolation.

### `1.5 (7)`: label said tracking, app had no ATT

Chosen approach then: the app does **not** track. No ATT prompt.

- App Privacy in App Store Connect corrected: every data type had "Used to Track You" **unchecked**.
- Ads forced to non-personalized (`npa=1`), IDFA never accessed, `NSPrivacyTracking = false`.

### `1.6.4 (19)`: the UMP prompt says the app personalizes ads

That resolution held until App Review read the **AdMob-hosted GDPR message** itself. Its copy
("Personalised advertising and content, advertising and content measurement, audience research
and services development") reads as a declaration of tracking regardless of what the app then
does with the consent, and no ATT prompt backed it. The app's own behaviour was never the
problem — `npa=1` was hardcoded — the message and the code disagreed.

Approach taken in `1.6.5 (20)`: **implement ATT and use it**, so the consent the message asks
for is real.

- `ConsentManager.requestTrackingAuthorizationIfNeeded()` runs the ATT prompt *after* the UMP
  form resolves (Google's documented ordering) and everywhere, not only in regulated regions.
  A launch that has not reached the foreground defers — the system denies a request made while
  the app is inactive **without showing the prompt**, permanently — and `RainyClockApp` retries
  from the `scenePhase` handler.
- `AdMobBannerView` sends `npa=1` unless ATT was granted, so declining changes nothing about
  how the app behaves; the banner is still built only after `canRequestAds`.
- `NSUserTrackingUsageDescription` in `Info.plist` and both `InfoPlist.strings`.
- `RainyClock/PrivacyInfo.xcprivacy` keeps `NSPrivacyTracking = false` with an empty
  `NSPrivacyTrackingDomains`. **Do not set it to true** — see the trap below.
- **The privacy-manifest trap that killed build 20.** Setting `NSPrivacyTracking = true` while
  `NSPrivacyTrackingDomains` stays empty invalidates the binary at submission time:

  > ITMS-91064: Invalid tracking information — NSPrivacyTracking must be true if
  > NSPrivacyTrackingDomains isn't empty.

  The wording states one direction; the validator enforces both. The two keys must agree.
  Filling the list is **not** the fix: iOS blocks connections to every listed domain when ATT
  is not granted, and AdMob serves personalized and non-personalized ads from the same
  endpoint (`googleads.g.doubleclick.net`), so listing it would leave every user who declines
  the prompt — most of them — with no ads at all. Google publishes no domain list for
  publishers, and its own SDK manifest is not the precedent it looks like: `GoogleMobileAds`
  declares six data types with `Tracking = false` but marks `NSPrivacyCollectedDataTypeDeviceID`
  — the IDFA, the one type ATT governs — as `Tracking = true`, and neither Google framework
  carries a top-level `NSPrivacyTracking` key at all. The real reason to stay at `false` is the
  pairing rule plus the blocking behaviour above; `1.6.3 (18)` shipped and was approved with
  exactly this combination. So the app manifest stays `false` + empty; the ATT prompt and the App
  Store Connect privacy label are what disclose tracking, and those are what App Review reads.
- **Manual step, App Store Connect (Account Holder/Admin):** App Privacy must be changed to
  declare tracking — Identifiers → Device ID, plus advertising/usage data, checked as "Used to
  Track You". This reverses the `1.5` fix, which is correct now that the prompt exists.
- **Manual step, review note:** state where the ATT prompt appears — first launch, immediately
  after the ad-consent dialog, on the Route tab.
- Alternative left on the table: trim the personalization purposes out of the AdMob GDPR
  message and keep the no-tracking posture. Worth checking in AdMob → Privacy & messaging;
  if the purposes can be removed, ATT could be withdrawn again in a later version.

## Rejection Resolution (2.1(a) — "unable to add Widgets")

Answered by reply, not by code. Two independent reasons the reviewer could not add one:

- **The app ships no Home Screen widget.** `RainyClockAlarmWidgetBundle` contains only
  `CommuteAlarmLiveActivity`, an `ActivityConfiguration`. The extension exists solely because
  AlarmKit requires one for alarms that enter the countdown state. Nothing is offered in the
  widget gallery, and no store metadata or screenshot has ever promised a widget.
- **The review device was an iPad.** The app is iPhone-only (`TARGETED_DEVICE_FAMILY = 1`), so
  on iPadOS it runs in iPhone compatibility mode, which does not offer third-party widgets at
  all. Adding a Home Screen widget would not have changed the outcome on that device.

Reply asks for re-review on an iPhone running iOS 26. If App Review pushes back a second time,
the options are a real Home Screen widget (iPhone only — still invisible on iPad) or full iPad
support, which is a much larger change.

## Completed

- App name and bundle renamed to Rainy Clock / 雨天鬧鐘; app is iPhone only.
- App icon is included in the Xcode asset catalog.
- GitHub Pages support and privacy pages exist under `docs/`.
- Weather source is Apple Weather / WeatherKit; route preview uses Apple Maps.
- Bottom ad uses Google AdMob banner placement; non-personalized (`npa=1`) unless the user grants ATT.
- Local notification alarm scheduling implemented for iOS 17–25, incl. 5-minute follow-up rings (max 10, capped to iOS's 64-pending limit) that stop when the alarm is acknowledged while the weekly schedule stays armed. On iOS 26+ AlarmKit replaces this path entirely (see AlarmKit Setup); scheduling through AlarmKit also clears any notification requests an upgraded install still has armed, so it cannot ring twice.
- Public-transit commute mode shows home/work pins plus `calculateETA` travel time and distance (MapKit cannot route transit geometry).
- Taiwan address validation generalized (postal-romanization table + dynamic Han→Latin transliteration, house-number and wrong-city guards).
- Address search results follow the language the user typed (Chinese input → Chinese results, English input → English results).
- App Privacy answers completed in App Store Connect (see Rejection Resolution).
- App Review notes and contact info filled in App Store Connect.
- App Store screenshots uploaded (3 iPhone 6.5" screenshots).
- App Store metadata draft is in `docs/appstore-metadata.md`.
- Source pushed to `origin/main` (commits `69155da`, `e12bacf`).

## AdMob Setup

The app serves one inline adaptive banner, forced non-personalized (`npa=1`).

| Item | Value |
| --- | --- |
| AdMob app ID (`GADApplicationIdentifier`) | `ca-app-pub-2920259088304022~6773413597` |
| Banner ad unit (`AppEnvironment.adMobBannerAdUnitID`) | `ca-app-pub-2920259088304022/7372515130` |

- **Link the app to its App Store listing in AdMob.** Google only reviews and approves an app once it is listed in a supported store and linked in the AdMob account; unlinked apps get limited ad serving, so revenue stays near zero until this is done. Do it now that `1.6.1 (16)` is live, then wait for AdMob's review.
- Confirm the AdMob payments and tax profile is complete, otherwise earnings are withheld even past the payout threshold.
- `SKAdNetworkItems` is declared as of `1.6.2 (17)` — see the AdMob third-party SKAdNetwork list and refresh it occasionally, as Google adds buyers.
- **EEA consent (UMP) is implemented as of `1.6.2 (17)`.** A GDPR "European regulations" message is published in AdMob (targeted at EEA/UK/Switzerland only, with the "Do not consent" option and close icon enabled, Google's default ad-partner list, and the GitHub Pages privacy policy URL). `ConsentManager` runs the flow and the Mobile Ads SDK only starts once `canRequestAds` is true. To rehearse the regulated-region path from a non-EEA simulator, launch a Debug build with `-forceEEAConsentGeography`:

  ```bash
  xcrun simctl launch booted com.shukaihu.RainyClock -forceEEAConsentGeography
  ```

- Changes to the AdMob message take up to an hour to reach devices, so treat "the form did not appear" as a propagation question before treating it as a bug.

### app-ads.txt

AdMob reported "we can't verify Rainy Clock (iOS)" for two independent reasons: the App Store listing had **no marketing URL** (`itunes.apple.com/lookup` returned `sellerUrl: null`, so Google had no domain to crawl), and no `app-ads.txt` existed at any domain root.

| Item | Value |
| --- | --- |
| Developer website domain | `shukaihu.github.io` |
| app-ads.txt | `https://shukaihu.github.io/app-ads.txt` |
| Hosting repo | [`ShuKaiHu/ShuKaiHu.github.io`](https://github.com/ShuKaiHu/ShuKaiHu.github.io) (public, Pages from `main` `/`) |
| Line served | `google.com, pub-2920259088304022, DIRECT, f08c47fec0942fa0` |

- The file **must** sit at the domain root. Google takes the domain from the store listing's developer website and discards the path, so `shukaihu.github.io/RainyClock/app-ads.txt` would never be read. GitHub Pages only serves the root from a repo named exactly `<user>.github.io`, which is why the developer site lives in its own repo instead of in `docs/` here.
- `shukaihu.com` was deliberately **not** used. It is on Cloudflare with Google Workspace MX records and a dead origin (522); pointing it at Pages would have meant DNS surgery for no benefit, and the domain root would have had to host the publisher line.
- **This repo must stay public.** Its Pages site at `shukaihu.github.io/RainyClock/` serves the support and privacy-policy URLs on the live App Store listing; GitHub Pages from a private repo requires GitHub Pro. Making it private would 404 those links.
- Marketing URL: `https://shukaihu.github.io/RainyClock/`, added on the `1.6.2` version page. It is a version-level field, so it only reached the public product page when `1.6.2` was released on 2026-07-27; before that `itunes.apple.com/lookup` kept returning `sellerUrl: null` and AdMob could not pass. Support and privacy-policy URLs were unaffected and needed no change.
- **Verified 2026-07-27**, within hours of `1.6.2` going live — AdMob's app settings now show 應用程式驗證「已驗證」 and 核准狀態「就緒」. The expected 24-hour-to-several-day re-crawl did not materialise.

  ```bash
  curl -s "https://itunes.apple.com/lookup?id=6780500386" | grep -o '"sellerUrl":"[^"]*"'
  ```

- One publisher line covers every app under `pub-2920259088304022`; future apps need no new file.
- Google re-crawls store listings on its own schedule. Expect 24 hours to several days after the marketing URL goes live before "Check for updates" in AdMob passes — though in practice it passed within hours.

### Debug builds use a test ad unit (`1.6.4`)

`AppEnvironment.adMobBannerAdUnitID` returns Google's test banner unit
(`ca-app-pub-3940256099942544/2934735716`) under `#if DEBUG` and the production unit otherwise.
Google requires test ads during development; requesting production ads from simulators counts
as invalid traffic and enough of it puts the AdMob account at risk. Before this change every
run from Xcode hit the production unit.

### Reading the AdMob report when no ads appear

A banner that fails to load renders at height 0 with opacity 0 (`AdMobBannerView`), so "no ad
on screen" and "ad failed" look identical. Do not diagnose by launching the app repeatedly —
read the report:

| Requests | Impressions | Meaning |
| --- | --- | --- |
| > 0 | 0 | Integration works; Google has no ad to return. Wait. |
| 0 | 0 | Something is broken in the app or the SDK never started. |

Observed 2026-07-28: 168 requests, 0 impressions, 0.00% match rate. Confirmed to be the first
row, not a fault — swapping in the test ad unit produced a banner immediately, and the log
showed the UMP call to `fundingchoicesmessages.google.com/a/consent` followed by ad requests to
`googleads.g.doubleclick.net/mads/gma`. Nearly all of those requests came from simulators, and
AdMob does not serve production ads to simulators.

The 使用者指標 / user metrics panel in AdMob shows zeros because the app integrates no Firebase
or Google Analytics SDK. It is not a signal about real usage; App Store Connect's 分析 tab is.

## Archiving and Uploading

**`1.8.0 (39)` uploaded 2026-10-02 08:27:46 (Asia/Taipei)** from `4e218c2`, same checks as 38 below.
`xcode-select` had been switched to the Command Line Tools around 08:22 by something outside this
session, so `xcodebuild` failed with "requires Xcode, but active developer directory … is a command
line tools instance"; the archive, export and upload ran with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` instead of changing the system setting.

**`1.8.0 (38)` uploaded 2026-10-02 03:43:06 (Asia/Taipei).** First build made with **Xcode 27.0
(27A266a, iOS 27 SDK)**, which the Mac App Store installed over Xcode 26 on 2026-10-01 04:15; its
licence had to be accepted with `sudo xcodebuild -license accept` before any `xcodebuild` (and the
`/usr/bin/git` shim) worked again. Archived from `3cf0fab` (archive `CreationDate` 03:39:44, after
the last commit). Local App Store export checked before upload: app, `RainyClockAlarmWidget.appex`
and `RainyClockDayOffNotification.appex` all `1.8.0 (38)`, `DTSDKName iphoneos27.0`; app
`aps-environment production`, App Attest production, App Group; **the widget appex now carries the
App Group too** (automatic signing with `-allowProvisioningUpdates` enabled it on the
`com.shukaihu.RainyClock.AlarmWidget` App ID, so no manual portal step was needed); privacy
manifests in all three bundles (app `UserDefaults` CA92.1 + 1C8F.1, both extensions 1C8F.1),
`NSPrivacyTracking` false, production service URLs, `GooglePlacesAPIKey` empty, the `rainyclock`
URL scheme, three BG task identifiers, `IronSource.framework` the only framework, no `.storekit`,
no DEBUG widget demo, the `-ObjC` selector present. Upload by the usual CLI path; the IronSource
dSYM warning again, non-blocking. Logs: session scratchpad `archive-180-38-x27.log`,
`upload-180-38.log`.

**`1.7.0 (31)` uploaded 2026-09-21 20:57:26 (Asia/Taipei).** Membership startup failures
are now visible, unknown membership is not labeled Free plan, and manual actions show
privacy-safe failure diagnostics separately from background refreshes. All 50 focused iOS
tests and Release archive passed; app/widget match, App Attest is production, and no local
StoreKit configuration is bundled. Apple processing is complete and internal group `SKHU tester`
has access; testing instructions were saved. This is a diagnostic build,
not proof that the TestFlight purchase/currency issue is fixed. No review submission or
public release. Logs: `/tmp/rainyclock-170-31-archive.log`, `/tmp/rainyclock-170-31-upload.log`.
The existing IronSource dSYM warning remains non-blocking.


**`1.7.0 (30)` uploaded 2026-09-21 19:43:35 (Asia/Taipei).** Archive/export succeeded,
and ASC processing is complete. Internal TestFlight group `SKHU tester` includes build 30.
App/widget versions match and App Attest is production; membership URL now points to the
isolated Production/TestFlight service. The known IronSource dSYM warning remains non-blocking.
The 1.7.0 version draft has build 30 attached and manual release selected. No review submission
or public release has occurred. Current service validation and blockers are recorded in
[1.7.0 release readiness](1.7.0-RELEASE-READINESS.md). Logs:
`/tmp/rainyclock-170-30-archive.log`, `/tmp/rainyclock-170-30-upload.log`.

**`1.7.0 (29)` uploaded 2026-09-16 22:19:55 (Asia/Taipei).** Release archive and CLI
export succeeded with automatic signing and `manageAppVersionAndBuildNumber=false`.
Apple reported `Upload succeeded` and `Uploaded package is processing`; subsequent ASC
processing completion is not yet confirmed, and this build has not been submitted for review.
App and widget versions match. The membership backend URL remains empty, and disaster
closures remain disabled until 1.7.1. The known IronSource dSYM warning was non-blocking.
Logs: `/tmp/rainyclock-170-29-archive.log`, `/tmp/rainyclock-170-29-upload.log`.

**`1.6.9 (28)` uploaded 2026-09-07.** Fourth release through the CLI path, same command,
same dSYM warning. The archive check gained the three `BGTaskSchedulerPermittedIdentifiers`
(a new one, `previewRefresh`, ships in this build) and a grep for the new code in the binary.

**`1.6.8 (27)` uploaded 2026-09-01.** The CLI path worked for the third release running —
plain `xcodebuild -exportArchive` with `ExportOptions-AppStoreUpload.plist`, no Organizer and
no credentials entered by hand. Archive verified before upload: app and appex both at
`1.6.8 (27)`, the production `VoiceProxyURL`, all twelve preview clips, `NSPrivacyTracking`
still `false`, no `GAD*` keys, `IronSource.framework` the only embedded framework, and the
Gemini key absent from the whole bundle — which it should be, since nothing in the app has
one any more.

The `Upload Symbols Failed … dSYM for the IronSource.framework` warning appeared again. It
does not block anything; the vendor ships no dSYM with its static framework, so crash frames
inside ironSource's own code arrive unsymbolicated.

```bash
xcodebuild -project RainyClock.xcodeproj -scheme RainyClock -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath ./build/RainyClock-<version>-<build>.xcarchive -allowProvisioningUpdates archive
```

- `xcodebuild -exportArchive` with `build/ExportOptions-AppStoreUpload.plist` uploads straight to App Store Connect, but it needs an Apple Account signed in under Xcode → Settings → Accounts. Without one it fails with `Failed to Use Accounts` / "Failed to find an account with App Store Connect access for team MQJ88U9NAJ", and the local keychain holds only Apple Development certificates — the Apple Distribution certificate is created during export.
- **The CLI upload worked again on 2026-08-13** for `1.6.6 (24)` — plain `xcodebuild -exportArchive` with `ExportOptions-AppStoreUpload.plist`, no Organizer, no credentials entered by hand. Try it first; the fallback below is only needed when the account grant is not valid.
- The account grant lapsed after the Xcode 26.6 upgrade for `1.6.2 (17)`. The fallback that works without CLI credentials is `open -a Xcode build/<archive>.xcarchive`, then Distribute App → App Store Connect → Upload in Organizer, leaving **Manage Version and Build Number** unchecked so Xcode does not bump the build number.

## After Release

- Watch App Analytics and Crashes (Xcode Organizer) for the first real-user data; note that Google SDK frames symbolicate poorly (missing dSYMs).
- Keep `docs/appstore-metadata.md` and the screenshots in sync with the next feature release.

## Known Review / QA Risks

- iOS local notifications can only play short bundled notification sounds; this app is not a full-screen system alarm replacement.
- Apple Maps / Apple's Taiwan geocoder can mis-resolve some queries. Notably the English POI phrase "Taipei Main Station" mis-geocodes to Maan / Wulai District in both CLGeocoder and MKLocalSearch; the app's address-validation layer correctly rejects the mismatch (shows "address not found") rather than pinning the wrong location, and the autocomplete-dropdown path resolves it correctly. When Apple returns a nearby suggested location, the app shows the actual address in use for confirmation.
- Google Places fallback requires a valid API key before enabling; `GooglePlacesAPIKey` is currently empty in `RainyClock/Info.plist`, so the app relies on Apple geocoding.
- Xcode upload warns about missing dSYM files for Google SDK frameworks (GoogleMobileAds, UserMessagingPlatform). This does not block upload; only Google SDK crash symbolication is limited.

## Useful URLs

- Support: `https://shukaihu.github.io/RainyClock/support.html`
- Privacy Policy: `https://shukaihu.github.io/RainyClock/privacy-policy.html`
- Repository: `https://github.com/ShuKaiHu/RainyClock`
