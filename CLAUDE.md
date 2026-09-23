# Rainy Clock

Rain-aware commute alarm. The iPhone app (repo root) is SwiftUI with Apple Maps
for routes, Apple Weather / WeatherKit for forecasts, AlarmKit for alarms on iOS 26+, and one
Unity LevelPlay banner. Two Node backends live beside it: `weather-proxy/` (Cloud Run — Android
weather relay, AI voice, and the RainyClock Plus membership service) and `dayoff-service/` (the
typhoon 停班停課 feed for 1.7.1: a Cloud Run Job polls NCDR into Firestore and a request-only
Cloud Run service serves it; deployment state is in `dayoff-service/DEPLOYMENT.md`). The Android port lives in `android/` (Kotlin + Jetpack Compose) —
platform substitutions and its own gotchas are in `docs/ANDROID.md`, and the Play Store
runbook is `docs/play-store-submission-checklist.md`.

## One worktree per platform

The two platforms are worked on at the same time, so each has its own git worktree and its
own branch. Same repository and same history — two checkouts of it:

| Platform | Directory | Branch |
| --- | --- | --- |
| iOS | `RainyClock-iOS/` | `ios/main` |
| Android | `RainyClock-Android/` | `claude/android-play-store-release-jykw59` |

Neither row says "this one". Each branch used to mark itself that way, which meant the table
could never be right on both at once and conflicted the first time they merged. Run
`git worktree list` — it answers the question the marker was trying to, and it is never stale.

**Work on the platform whose worktree you are in, and commit to its branch.** Both checkouts
contain the whole repo — a worktree splits branches, not directories — so nothing stops you
editing `android/` from the iOS worktree. Don't: that is the collision this arrangement
exists to end, after a day of iOS commits kept sweeping up the Android session's edits to
shared files.

**The other platform's files cannot be hidden**, so this rule is kept by hand rather than by
tooling: sparse-checkout would take `RainyClock/*.wav` out of the Android worktree, and the
Android build copies those alarm tones out of the iOS target at build time. Hide them and the
build stops working.

A session that finds itself in the wrong worktree has lost nothing — work lives in the branch,
not the directory. Confirm with `git branch -a --contains <sha>` before assuming otherwise:
right after a split both worktrees sit on the *same* commit, which looks like the branch was
reset when in fact every commit is still an ancestor of both tips.

Shared files (`docs/`, `CLAUDE.md`, `.gitignore`) drift between the two branches. Merge in the
direction of whoever needs the change; both branches are meant to land on `main` eventually.

`git worktree list` shows the current layout. Two things do not survive being created or
moved, because both are gitignored and hold absolute paths:

- Android's `android/local.properties` — a new worktree needs it written by hand, see
  `docs/ANDROID.md`.
- `DerivedData/SourcePackages` — Swift Package Manager records the *absolute* path of each
  resolved binary XCFramework, so renaming the checkout fails the build with "There is no
  XCFramework found at &lt;old path&gt;". `rm -rf DerivedData/SourcePackages` and build again;
  it re-resolves. This bit the rename to `RainyClock-iOS` on 2026-08-13.

## Read first

The two platforms keep **separate logs** — they ship on different schedules and are often
worked on at the same time, so never write one platform's state into the other's file:

- **`docs/STATUS-IOS.md`** — the iPhone app: what shipped, what is in review, what is being
  worked on, and the iOS backlog.
- **`docs/STATUS-ANDROID.md`** — the Android port and everything still owed before a first
  Play release.
- **`docs/STATUS.md`** — a one-page router: which platform is where, plus the handful of facts
  that are true of both.

Start with the log for the platform you are touching, and update it when state changes.

Supporting docs:

- `docs/app-store-submission-checklist.md` — submission mechanics, rejection history, AdMob
  and app-ads.txt setup, archiving and upload gotchas.
- `docs/appstore-metadata.md` — store copy, release notes, App Review notes.
- `docs/PRODUCT_DECISIONS.md` — product reasoning, including rejected alternatives.

## Things that are easy to get wrong

- **Version numbers live in two places.** The app's `Info.plist` hardcodes
  `CFBundleShortVersionString` / `CFBundleVersion` (`GENERATE_INFOPLIST_FILE = NO`), while the
  `RainyClockAlarmWidget` extension derives them from `MARKETING_VERSION` /
  `CURRENT_PROJECT_VERSION` in the project file. Bump both or App Store validation rejects
  the upload.
- **The published website is a different repo.** `ShuKaiHu/ShuKaiHu.github.io` owns
  `shukaihu.github.io/` and serves `app-ads.txt`. This repo's `docs/` folder is published at
  `shukaihu.github.io/RainyClock/` and carries the support and privacy-policy pages linked
  from the live App Store listing — so **this repo must stay public**.
- **Never point a real app key at a simulator or emulator.** Impressions from a build running
  a production key are real impressions on the account, and ironSource's terms put
  "non-human traffic" and manipulation under Forbidden Activity — which it judges at its
  sole discretion, and which lets it withhold *and claw back* payments. This is the same rule
  the AdMob build had, and the reason that account is gone. Register the device under
  **Setup → Test devices** in the LevelPlay dashboard, or verify with a blank key (the SDK
  then skips init and logs why).
- **The consent sheet's wording is not free copy.** ironSource's Data Protection Addendum
  requires it to name ironSource — and, for the personalised tier, its advertising partners —
  as controllers, and to reach ironSource's privacy policy from inside the app. It also
  requires that an unanswered or withdrawn consent leaves the SDK *uninitialised*, which is
  why `ConsentManager` gates SDK startup rather than just the ad request.
- **`OTHER_LDFLAGS = -ObjC` is load-bearing.** IronSource ships as a *static* framework whose
  Objective-C categories are not loaded without it, and the app then dies at launch with
  `-[NSConcreteMutableData ISAES256EncryptWithKey:]: unrecognized selector` — inside the SDK's
  own init, so nothing in this repo appears in the crash. It only reproduces once a real
  `LevelPlayAppKey` is set (a placeholder key skips init entirely), which is exactly when it
  is least expected. Do not remove the flag.
- **The banner is Unity LevelPlay, with no Google demand behind it.** The AdMob account is
  terminated (appeal denied, 2026-08), so the Google adapter, the Google Mobile Ads SDK,
  `GADApplicationIdentifier` and the UMP consent flow were all removed on purpose — do not
  reintroduce them. (A same-day AppLovin MAX detour was re-pointed here: the ad unit lives
  in the LevelPlay dashboard, not AppLovin's.) GDPR consent is the app's own
  `AdConsentSheet` feeding `LPMPrivacySettings.setGDPRConsent`. The app key lives in
  `Info.plist` under `LevelPlayAppKey`. There is no always-fill test unit id: use the Test
  Suite (`-showLevelPlayTestSuite`) or a dashboard test device before exercising ads.
- **Confirm which `.app` you are installing.** `DerivedData/Build/Products/` holds stale
  bundles; check `CFBundleShortVersionString` before installing to a simulator.

## Build

iOS:

```bash
xcodebuild -project RainyClock.xcodeproj -scheme RainyClock -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO build
```

Android (requires the Android SDK; CI runs this on every push touching `android/`):

```bash
cd android && ./gradlew testDebugUnitTest assembleDebug
```
