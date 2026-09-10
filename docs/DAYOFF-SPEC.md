# Day-off suppression — shared specification

**Spec version: 1** · Researched and written 2026-09-10 on `ios/main`. Nothing is implemented yet.

Two features that answer the same question — *is there anything to get up for tomorrow?* — and
therefore share one data path, one decision function, and one set of test fixtures:

- **(A) 天然災害停止上班上課** — the 行政院人事行政總處 (DGPA) typhoon day-off announcement.
- **(B) 國定假日** — the national holiday calendar, including 補班日 make-up workdays.

This file is the **single source of truth for both platforms**. `docs/dayoff-fixtures.json` beside
it is the executable half.

---

## 0. The handoff rule (read this first)

iOS and Android are built in separate worktrees by separate sessions that never see each other's
work in progress. A prose spec drifts silently under those conditions; two implementations of
"does the alarm ring" that disagree is a bug that only shows up during a typhoon. So the contract
is deliberately mechanical:

1. **`docs/dayoff-fixtures.json` is the contract, not this file.** It carries the real feed strings
   and the expected decision for each. Both platforms load it in their unit tests. Prose here
   explains *why*; the fixtures decide *what*.
2. **Changing behaviour means changing the fixtures and bumping `specVersion`** in both the JSON and
   the heading of this file. Add a line to §9 saying what changed and why.
3. **The other platform finds out through a failing test, not through a message.** That is the
   point. A session that pulls a bumped `specVersion` and sees red tests knows exactly what to
   reconcile. Do not "fix" a failing fixture by changing the expectation to match your code.
4. **Each platform records the version it has implemented** in its own status log
   (`docs/STATUS-IOS.md` / `docs/STATUS-ANDROID.md`), as `Day-off: implemented against spec vN`.
   Version in the log < version here ⇒ that platform owes work.
5. **Never write the other platform's state into its log from your worktree.** This file and the
   fixtures are shared and may be edited from either side; the two `STATUS-*.md` files may not.
   See `CLAUDE.md` for why that rule exists.
6. **Open questions live in §8, not in someone's head.** A session that resolves one edits §8 and
   moves the answer into the body.

---

## 1. Product decisions (settled — do not re-litigate)

Decided by the owner on 2026-09-10:

| # | Decision | 中文 |
| --- | --- | --- |
| P1 | The user declares what their morning is **for**: work, school, or both. | 上班 / 上課 / 兩者，使用者自己設定 |
| P2 | Matching granularity is the **district (區/鄉/鎮/市)**, not the county. | 用區定義，不是縣市 |
| P3 | Two places are checked — **home and destination** — and the result is their **union**. Either one suspended counts as a day off. | home 跟 work 只要有一個在停班區就算放假 |
| P4 | Districts merely **passed through en route do not count**. | 路途中間經過的不算 |
| P5 | The alarm **fails open**. Any doubt, any failure, any unrecognised wording ⇒ it rings. | 有疑慮一律照響 |

**P1 truth table.** `mode` is what the user set; suppress only when there is genuinely nothing left
to get up for:

| mode | suppress when |
| --- | --- |
| `work` | 上班 suspended |
| `school` | 上課 suspended |
| `both` | 上班 **and** 上課 both suspended |

`both` is an AND, not an OR — a parent who also commutes still has to get up if only the school
closed. This reading follows from P5; it is the one place where the owner's wording ("A+B") was
interpreted rather than stated, so it is flagged in §8.

**P2 is supported by the data, not just preference.** Across 365 real historical announcements
(§3.2), the DGPA feed's geocode is **only ever 2, 5 or 7 digits** — county or district, never a
10-digit 里. District is both what the user asked for and the finest granularity the source
actually publishes. See §8 for the one caveat (Taipei's *own* archive does go to 里 level; the
national feed does not).

---

## 2. Data source (A) — 停班停課

### 2.1 The endpoint

```
https://alerts.ncdr.nat.gov.tw/JSONAtomFeed.ashx?AlertType=33
```

Verified first-hand 2026-09-10: HTTP 200, `application/json; charset=utf-8`, 9,678 bytes, **no API
key, no cookie, no Referer**, TLS verified. `author.name` is `行政院人事行政總處`; `rights` is
`Public Domain`. It is the machine-readable publication of exactly the page the owner pointed at
(`https://www.dgpa.gov.tw/typh/daily/nds.html`), registered on data.gov.tw as
[dataset 20457](https://data.gov.tw/dataset/20457) under 政府資料開放授權條款第 1 版 (`license: "1"`).

**Do not scrape `nds.html`.** It is server-rendered HTML with no date column, its `robots.txt` is
`User-agent: * / Disallow: /`, and everything it shows is in this feed already, typed.

Two siblings, same data: `RssAtomFeed.ashx?AlertType=33` (Atom+CAP XML) and the per-alert `.cap`
files linked from each entry. Prefer the JSON — no XML parser, and the fields below are enough.

### 2.2 The historical query API — how to get more fixtures

```
https://alerts.ncdr.nat.gov.tw/server/v1/Alerts/Search/history?alertTypeId=33&sentdate=<D-1>&effective=<D>&page=<n>
```

Verified keyless. **Both `sentdate` and `effective` are required** and must be adjacent days
(`sentdate` = D-1, `effective` = D returns the alerts sent on D); a wide range returns zero, and
omitting either returns `capZip 或 (effective + sentdate) 必須擇一填寫`. 10 records per page, with
`total` in the envelope. Rows carry `description`, `severity`, `msgType`, `sentDate`, `identifier`,
`countyName`.

This is how `docs/dayoff-fixtures.json` was built, and how a future session should extend it after
the next typhoon. **Throttle it** — the public feed on the same host returns HTTP 429 with body
`限制存取間隔時間為3秒` and took ~65 s to recover in testing.

### 2.3 Entry shape

```json
{
  "id": "dgpa.gov.tw_workSchlClos_20260822141104_i_6403700_001",
  "updated": "2026-08-22T14:11:04+08:00",
  "author": { "name": "行政院人事行政總處" },
  "summary": { "#text": "[停班停課通知]高雄市桃源區:今天下午已達停止上班及上課標準。行政院人事行政總處。如有任何問題請撥1999(市內直撥)。" },
  "status": "Actual",
  "msgType": "Alert",
  "effective": "2026/8/22 下午 02:10:00",
  "expires": "2026/8/23 上午 12:00:00"
}
```

**The area and the date live in the prose.** There is no structured date field and no structured
area field on the JSON feed. The `id` infix between `_i_` and the trailing sequence number is the
geocode (`6403700` above).

### 2.4 Five traps, each measured

1. **`expires` is not the suspension window.** It is always the end of the *announcement* day.
   屏東縣 announced at 2026-08-22 19:17 that 8/23 is suspended; that entry's `expires` is
   `2026/8/23 上午 12:00:00` — midnight, i.e. **before the morning it applies to**. Any logic of the
   form `now within effective..expires` returns "ring" forever and the feature silently does
   nothing. **Never read `expires`.**
2. **The feed keeps old entries.** On 2026-09-10, a clear day, the live feed still held the 14
   entries from the 2026-08-22..24 event. "No new entry" does **not** mean "no suspension" and
   "an entry exists" does not mean "today". Always compare the resolved target date.
3. **Presence ≠ suspension.** `尚未宣布消息` (29 of 365), `尚未列入警戒區` (2) and
   `照常上班、照常上課` (1) are all published as entries.
4. **`countyName` (history API only) is not reliable.** Two of 365 records carry
   `countyName: "臺東縣延平鄉"` while the description says `臺東縣金峰鄉`. **Parse the area out of
   `description`; never trust `countyName`.**
5. **`msgType` includes `Update`, not just `Alert`** (145 of 365). Do not filter on
   `msgType == "Alert"`. No `Cancel` appeared in 365 records, and per the owner (2026-09-10) an
   announced suspension is never revoked, so there is nothing to handle — see §6.

### 2.5 `severity` is a usable cross-check

Across all 365 records the correlation is exact:

| `severity` | n | means | 上班 | 上課 |
| --- | --- | --- | --- | --- |
| `Extreme` | 328 | suspended | stopped | stopped |
| `Severe` | 5 | school only | normal | stopped |
| `Minor` | 32 | nothing announced / normal | — | — |

Zero counter-examples in either direction. **Use it as an assertion, not as the decision**: parse
the prose, then require the parse to agree with `severity`, and fail open (ring) on disagreement.
Five `Severe` records is a thin sample to build a rule on, but it is a free tripwire against a
parser regression.

---

## 3. What the announcements actually say

### 3.1 The grammar

```
[停班停課通知]<area>:<body>行政院人事行政總處。如有任何問題請撥<phone>。
```

`<body>` is `<date?><daypart?><work-and-school-status>。` Every observed combination is in
`docs/dayoff-fixtures.json` as `parseCases` (24 distinct sentence patterns, deduplicated from 365
records). Examples spanning the range:

```
[停班停課通知]宜蘭縣:7/24停止上班、停止上課。
[停班停課通知]新北市瑞芳區:明天停止上班、停止上課。
[停班停課通知]新竹縣尖石鄉:明天照常上班、停止上課。
[停班停課通知]桃園市復興區:今天下午照常上班、停止上課。
[停班停課通知]澎湖縣:7/6中午12:00起已達停止上班及上課標準。
[停班停課通知]臺中市:10/4照常上班、照常上課。
[停班停課通知]臺中市和平區:尚未宣布消息。
[停班停課通知]新竹縣:8/12尚未列入警戒區。
```

**Target date** — three forms, plus absent:
`今天` → the Asia/Taipei date of `sentDate`/`updated`; `明天` → that date + 1;
`M/D` → that day, year taken from `sentDate` (if `M` < the month of `sentDate`, roll the year
forward); absent → treat as unresolved and **ring**.

**Day part** — `上午` / `中午` / `下午` / `晚上`, else full day. A morning commute alarm is affected
only by **full day** or **上午**. `今天下午1:30起停止上班` does not silence that morning's alarm, and
`9/30晚上6:00起` does not silence the 9/30 morning either.

**Status** — `照常上班` before `停止上班` (the negation check must come first);
`已達停止上班及上課標準` covers both; `尚未宣布消息` / `尚未列入警戒區` are neither.

### 3.2 Granularity, measured

| geocode digits | level | n |
| --- | --- | --- |
| 2 | 直轄市 (`63` 臺北市, `65` 新北市, `66` 臺中市, `67` 臺南市, `64` 高雄市) | 55 |
| 5 | 縣 / 市 (`10002` 宜蘭縣, `10013` 屏東縣, `09007` 連江縣 …) | 163 |
| 7 | 鄉鎮市區 (`6501200` 新北市瑞芳區, `1001416` 臺東縣蘭嶼鄉 …) | 147 |
| 10 | 村里 | **0** |

All 22 counties appear in the corpus, 臺北市 and 新北市 included. **A county-level announcement
covers every district inside it; a district-level announcement covers only that district.**

**The case that makes P2 and P3 necessary** — 2025-11-10, 鳳凰颱風. New Taipei suspended exactly
seven mountain districts for the next morning and left the rest of the city working:

```
20:14 新北市瑞芳區:明天停止上班、停止上課。   20:16 新北市石碇區:…
20:18 新北市坪林區:…   20:20 新北市平溪區:…   20:22 新北市雙溪區:…
20:24 新北市貢寮區:…   20:26 新北市烏來區:…
```

A county-level rule would have silenced every alarm in New Taipei that morning. This is
`decide-01` … `decide-03` and `decide-20` in the fixtures.

---

## 4. Data source (B) — 國定假日

### 4.1 The endpoint

Discovery (never hardcode the CSV URL — it is a GUID that changes):

```
https://data.gov.tw/api/v2/rest/dataset/14718
```

Verified 2026-09-10: HTTP 200, JSON, 19,655 bytes, keyless, `license: "1"`. `result.distribution[]`
holds one entry per year with `resourceDescription`, `resourceDownloadUrl` and
`resourceCharacterEncoding`. 115年 (2026) and 116年 (2027) are both published; the next year lands
around June–July.

The CSV itself, fetched and parsed first-hand for 2026 — 6,499 bytes, UTF-8 **with BOM**, 365 rows:

```
西元日期,星期,是否放假,備註
20260101,四,2,開國紀念日
20260102,五,0,
```

`是否放假` is `0` (working) or `2` (off) and **nothing else**. Weekends, 補假 and 補班 are all
already folded into it: 2026 has 245 working days and 120 days off, of which 16 non-weekend days
are holidays.

### 4.2 Three selection traps

- **`_Google行事曆專用` resources are a different schema.** Filter them out by name.
- **Multiple revisions per year exist**, not in date order — 114年 has a `(1141020更新)` revision
  that is **BIG5, no BOM** while 115/116 are UTF-8 with BOM. Honour `resourceCharacterEncoding`.
- **A bad filename still returns HTTP 200** with a ~570-byte HTML error page. Validate: strip BOM,
  first line must equal `西元日期,星期,是否放假,備註` exactly, ≥ 365 data rows, no `<html`.

### 4.3 補班日, and the trap that is more common than 補班日

Read **only** `是否放假`. Never parse `備註` — its wording changed from 調整上班 to 補行上班 in 2021.
A make-up Saturday is simply `星期 ∈ {六,日} 且 是否放假 = 0`. 2026 and 2027 have none; the mechanism
still has to be right, because a law change brings them back with no warning.

The reverse trap bites far more people: **104 of 2026's 120 days off are just weekends.** A rule of
"是否放假 == 2 ⇒ silence" switches off the Saturday alarm a shift worker set on purpose. **Only
consult the calendar for a day the user's own repeat schedule would have rung anyway.**

### 4.4 Fallbacks

Ship the current and next year's CSV **in the app bundle** as the floor — `data.gov.tw/api/v1` is
already retired and v2 will follow one day. Community mirrors, verified working but single-
maintainer, in preference order: `ruyut/TaiwanCalendar`
(`https://cdn.jsdelivr.net/gh/ruyut/TaiwanCalendar/data/{YYYY}.json`, 158★, no CI, 2017–2027) and
`gilbertchiao/taiwan-work-calendar` (has CI and a JSON Schema, but young and 1★ — pin a tag, not
`@main`, whose jsDelivr `Cache-Control` is **7 days**). Avoid
`vancetang/taiwan-office-calendar`: its JSON field is `holiday` while its README says `isHoliday`,
which is a `Codable` landmine waiting for someone to "fix" the README.

### 4.5 EventKit is the wrong tool

Do not read the user's subscribed calendars for this. The system Taiwan holiday calendar's contents
are not under our control, it does not mark 補班日, and it would add a calendar permission prompt
and an App Review purpose string for data we can fetch as a 6 KB file. The `是否放假` column answers
the question exactly and offline.

---

## 5. The decision function

One entry point, one return type, on both platforms:

```
enum DayOffDecision {
    case ring
    case suppress(reason: Reason)   // Reason MUST carry: area, the source's own update time, and
                                    // which of 上班/上課 was suspended. Not constructible without them.
}
```

The `suppress` case cannot be built without the attribution fields, because §7 requires the UI to
show them and a type is a cheaper guarantee than a code review.

**Order of operations for (A).** Any step that cannot be completed returns `.ring`:

1. `status == "Actual"`.
2. Match `^\[停班停課通知\](?<area>[^:：]+)[:：](?<body>.*)$`. No match ⇒ ring.
3. Resolve `area` to a geocode level: exactly a county name ⇒ covers all its districts;
   county+district ⇒ that district only; anything longer or unrecognised ⇒ **ring** (see §8).
4. Does `area` cover the user's **home** district **or** their **destination** district? (P3, P4 —
   route interior points are never considered.) No ⇒ ring.
5. Resolve the target date (§3.1). Not equal to the alarm's own date ⇒ ring.
6. Resolve the day part. Not full-day and not 上午 ⇒ ring.
7. Parse `上班` and `上課` independently, checking `照常` **before** `停止`.
8. Assert the parse agrees with `severity` (§2.5). Disagreement ⇒ ring.
9. Apply the P1 truth table. Only now may `.suppress` be returned.

**Then, for (B),** independently: if the alarm's date is `是否放假 == 2` in the official calendar
*and* the user's repeat schedule would have rung that day, suppress.

**Cache rules.** The decision path never makes a synchronous network call — it reads a cache in the
App Group container (the alarm presentation and the widget extension read it too). Store the raw
bytes, the fetch time, **and the source's own update time**. Re-derive the decision against the
alarm's date every time; never replay a stored verdict. A cache older than a fixed maximum age
(§8 — the number is not yet chosen) is treated as absent, which means ring.

**Fail-open, exhaustively.** Ring on: HTTP error, 429, timeout, TLS failure, malformed JSON,
unparseable prose, empty feed, all entries stale, unrecognised area, unrecognised status wording,
severity disagreement, missing cache, expired cache, clock skew. There must be a unit test
asserting that a decode failure returns `.ring`.

---

## 6. Timing — the honest part

DGPA's own rule, printed on `nds.html`: a full-day or morning suspension should be announced
**between 19:00 and 22:00 the night before**, but if conditions worsen after midnight it may be
announced **by 04:30 that morning**. The corpus agrees — announcements cluster in the evening,
with a real minority during the day.

**iOS cannot reliably wake at 04:40 without a backend.** `BGAppRefreshTask` and `BGProcessingTask`
are opportunistic with no time guarantee; silent push is the only reliable trigger and needs a
server, which this app does not have and will not get. So:

**Announcements are not revoked.** Owner's ruling, 2026-09-10: a 停班停課 announcement, once made,
does not get reversed before the morning it applies to. This retires what had been the design's
most dangerous unknown, and it is why Path A below is viable at all. Nothing in the corpus
contradicts it — no `Cancel` in 365 records — but it rests on the owner's domain knowledge rather
than on measurement, so it is recorded here rather than buried in code.

What remains true is that an announcement can *arrive* as late as 04:30. That is a different
problem, and it fails in the safe direction: the alarm rings, the user gets up, and finds out. Only
an announcement that arrives while the phone can still act on it can silence anything.

**Path B — the alarm rings, and the ring screen says it (recommended default).** AlarmKit's custom
presentation reads the App Group cache at fire time and shows the suspension, the area, the source
and the source's update time, with 〔知道了，繼續睡〕 and 〔還是叫我起床〕. The user loses five
seconds and **can never be made late by a wrong decision** — the only direction that must not fail.
It is also the only path that covers a 04:30 announcement, and the only one that exists at all on
pre-iOS-26 devices.

**Path A — actually cancel the alarm the night before.** When a suspension for tomorrow is in the
cache between roughly 21:00 and bedtime, cancel or defer that occurrence *and immediately post a
local notification saying so, with an undo*, so the user sees it before sleeping and can override.
Given that announcements are final, the evening case is safe and Path A may reasonably ship
default-on — but not until its state handling is defined: what happens to a cancelled occurrence
across a reboot, app termination, or the user deleting and reinstalling, and how the next
occurrence is re-armed. Ship it default-off until those are answered, then revisit the default.

Fetch opportunities, any of which refreshes the cache: app foreground; the existing evening-preview
window (~21:00, which is exactly DGPA's announcement window); an opportunistic
`BGAppRefreshTask` at alarm−70 min; and the user picking up the phone when the alarm rings.

**This app already has the machinery.** `RainyClock/Services/BackgroundWeatherRefresh.swift` runs
three background windows to re-decide the armed alarm, `AlarmViewModel.refreshScheduledAlarmUnattended()`
is the unattended re-decision entry point, and `EveningPreview.swift` already tells the user the
night before what tomorrow's alarm will do. Day-off is another input to that same pipeline, not a
new one. The holiday filter belongs in the date predicate inside
`AlarmTimeCalculator.nextAlarmDateForWeatherCheck`.

**Android is genuinely better here.** An alarm-clock app may hold `USE_EXACT_ALARM` and use
`setExactAndAllowWhileIdle()` to wake at 04:35 and re-decide before the real alarm. Keep Path B
anyway — OEM battery managers kill background work regardless — and keep the decision logic
identical, which is what the shared fixtures enforce.

---

## 7. Legal and display obligations

**Polling NCDR is clean.** `AlertType=33` is a registered open-data resource of dataset 20457
(provider: 行政院人事行政總處) under 政府資料開放授權條款第 1 版, which permits reuse and requires
attribution. The feed body additionally declares `rights: "Public Domain"` — the two statements do
not agree, so **rely on the licence, and attribute**. `nds.html` is a different matter: its
`robots.txt` disallows all non-Google agents, which is why §2.1 says not to scrape it at all.

**The real risk is displaying something wrong, not fetching it.** `nds.html` itself prints
災害防救法第 53 條 — spreading false disaster information causing harm carries up to three years or
a NT$1,000,000 fine. Therefore:

- Any "today is suspended" surface must show **`資料來源：行政院人事行政總處`** *and* **the source's
  own update time**, never only the app's fetch time.
- "Fetch failed" and "no suspension announced" must be **visibly different states**, and only the
  latter may affect the alarm. `尚未宣布消息` is a third state and should say so.
- Disclaimer, on the settings page and at the foot of any suspension screen:
  > 本資訊擷取自行政院人事行政總處公開資料，僅供參考，**實際停止上班上課以各縣市政府公告為準**。
  > 民間事業單位請依勞動部「天然災害發生事業單位勞工出勤管理及工資給付要點」辦理。網路異常時本App將照常響鈴。
- Credits page: `資料來源：政府資料開放平臺 data.gov.tw／行政院人事行政總處`.
- Localise the disclaimer wherever the app ships another language.

---

## 8. Open questions — resolve these before or during implementation

Owner decisions still needed:

1. **Is `both` an AND?** §1 reads "A+B" as *suppress only when both are suspended*. Derived from
   P5, not stated. Confirm.
2. **How does the user's district get set?** Reverse geocoding from the existing home/work
   addresses, or an explicit picker? A picker avoids a new location-privacy surface and cannot be
   wrong; reverse geocoding is invisible but must be verified to return 區 reliably in Taiwan.
   **Note the mismatch:** DGPA suspends by 工作地, and this is a commute app whose two addresses are
   usually in different districts — which is exactly why P3 takes the union.
3. **Maximum cache age** before a cached suspension is ignored. Not chosen.
4. **Is the feature hidden outside Taiwan**, and what does a Taiwanese user abroad get?
5. **Pre-iOS 26 devices** have no AlarmKit custom presentation, so Path B's ring screen does not
   exist there. Decide what those users get.

*Resolved:* how a revocation is expressed was the top item here until 2026-09-10, when the owner
ruled that announcements are never revoked. See §6.

Unverified facts — do not present these as known:

7. **Sub-district announcements in the national feed.** Zero 10-digit geocodes in 365 records, but
   Taipei's *own* archive routinely lists 里 and named schools
   (`臺北市士林區永福里、新安里…停止上班、停止上課`, `臺北市士林區陽明山國民小學…`). Either DGPA does
   not forward those nationally, or the corpus missed them. Until this is settled, step 3 of §5
   rings on any area string longer than county+district — a suspension covering one 里 must not
   silence the whole district.
8. **A parent's question may be unanswerable.** 停課 is announced per school and per 里; no source
   found answers it at that granularity. If `mode: school` ships, the settings copy must say what it
   can and cannot see.
9. **End-to-end feed latency during a live event** has never been measured — only after the fact.
10. **AlarmKit specifics**: whether a scheduled alarm can be cancelled from a background task, and
    what its custom presentation can read at fire time, are untested on device.
11. **App Review / Play policy** for this feature is unexamined: background-mode justification, the
    fact that a reviewer will never see a typhoon (needs a demo path and a note in
    `docs/appstore-metadata.md`), and whether prominent government attribution reads as false
    endorsement. Android: the `USE_EXACT_ALARM` Play Console declaration.

---

## 9. Implementation order

Feature (B) first — the data is clean, the logic is small, and it exercises the whole pipeline
(fetch → validate → cache → gate the alarm → tell the user the night before) before (A) adds a
hostile parser on top.

1. `HolidayCalendar`: bundled 2026/2027 CSVs, monthly foreground refresh via dataset 14718
   discovery, the §4.2 validation, decode by declared encoding.
2. Gate it on the user's own repeat schedule (§4.3). Feature is **opt-in**. Evening notice the
   night before.
3. `SuspensionParser` against `docs/dayoff-fixtures.json`, **offline, no network**. Acceptance:
   every input that is not (covered area × target date × full-day-or-morning × the user's mode)
   returns `.ring`.
4. Wire the NCDR fetch: 8 s timeout, identifying User-Agent, ≥3 s backoff on 429 (recovery took
   ~65 s in testing — a 429 is never "no suspension"), raw bytes + both timestamps into App Group.
5. Path B ring screen (§6).
6. Opportunistic background refresh, with a comment saying correctness must not depend on it.
7. Path A last, default off, with the undo notification.
8. Credits, disclaimer, `docs/PRODUCT_DECISIONS.md` entry, and update `docs/STATUS-IOS.md`.

Android differs only in §6's fetch timing and in Big5 decoding (`Charset.forName("Big5")`,
`ZoneId.of("Asia/Taipei")`). The decision logic and the fixtures are shared verbatim.

### Changelog

- **v1** (2026-09-10) — initial spec. Sources verified first-hand; 365-record corpus harvested from
  the NCDR history API across eight typhoon events (2024-07 … 2026-08); fixtures generated from it.
  Nothing implemented on either platform.
- **v1, amended** (2026-09-10) — owner ruled that a 停班停課 announcement is never revoked before
  the morning it applies to. §8's top unknown retired; §6 rewritten accordingly and Path A's
  remaining blocker narrowed to its own state handling. No fixture and no decision-function
  behaviour changed, so `specVersion` stays at 1.
