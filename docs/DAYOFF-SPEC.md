# Day-off suppression — shared specification

**Spec version: 4** · Researched and written 2026-09-10 on `ios/main`; v3 on 2026-09-22; v4 on 2026-10-01. iOS has implemented (A) and (B) against this contract, gated off for 1.7.0 and being prepared for 1.8.0 — see `docs/DISASTER-PREVIEW.md` for the shipped architecture where it differs from the proposals below. Android has not started.

Two features that answer the same question — *is there anything to get up for tomorrow?* — and
therefore share one data path, one decision function, and one set of test fixtures:

- **(A) 天然災害停止上班上課** — the 行政院人事行政總處 (DGPA) typhoon day-off announcement.
- **(B) 國定假日** — the national holiday calendar, including 補班日 make-up workdays.

This file is the **single source of truth for both platforms**. Three files, one contract:

| file | role |
| --- | --- |
| `docs/DAYOFF-SPEC.md` | this file — why, and the rules in prose |
| `docs/dayoff-fixtures.json` | **the contract** — real feed strings, expected decisions, and a `fieldGuide` defining every expectation field normatively |
| `docs/dayoff-corpus-summary.json` | the audit trail behind every statistic quoted here, plus the commands to regenerate the full 1,374-alert corpus |

New here? Read §10 first.

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
| `both` | 上班 **or** 上課 suspended — either alone is enough |

`both` is an **OR**, decided by the owner on 2026-09-22: "兩者都勾就是 OR，任一被滿足就觸發". A
user who ticks both is asking to hear about either closure, and the settings copy says so. (v1 and
v2 read it as an AND on the strength of P5; that reading was never ratified and is retired.)

**P2 is supported by the data, not just preference.** Across the **complete 1,374-alert DGPA
archive (2014-2026)**, every geocode is a county or a district; DGPA has never once issued a
村里-level code for 停班停課 (§3.2). District is both what the owner asked for and the finest
granularity this source publishes. Taipei's *own* archive does go to 里 and named-school level, but
those announcements have no representation in the national feed at all — 臺北市 appears there only
ever as the city-wide code `63`.

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

**To sweep the whole archive rather than a date window**, enumerate events first and query by
event — this is how the 1,374-alert corpus behind this spec was built:

```
GET /server/v1/Generic/capZip                                   # 62 named events, each with a pk
GET /server/v1/Alerts/Search/history?capZip=<pk>&alertTypeId=33&page=<n>
```

Each entry's `filePath` resolves under `https://alerts.ncdr.nat.gov.tw/Capstorage/<filePath>` to the
CAP XML, which is where the geocodes live.

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
area field on the JSON feed — matching on this feed is by **area name**, not by code.

**Do not read the geocode out of the `id`.** The infix between `_i_` and the trailing sequence
number does look like the geocode (`6403700` above), and for a modern single-area alert it is. But
**324 of the 1,374 archived alerts carry no `_i_` segment at all**, and one alert can cover many
areas — up to 24 counties in a single record (§3.3). An implementation that parses the id silently
drops those. If a code is wanted, fetch the `.cap` file the entry links to and read every
`<area>/<geocode>` in it, checking `<valueName>` first (§3.2).

### 2.4 Five traps, each measured

1. **`expires` is not the suspension window.** It is always the end of the *announcement* day.
   屏東縣 announced at 2026-08-22 19:17 that 8/23 is suspended; that entry's `expires` is
   `2026/8/23 上午 12:00:00` — midnight, i.e. **before the morning it applies to**. Any logic of the
   form `now within effective..expires` returns "ring" forever and the feature silently does
   nothing. **Never read `expires`.**
2. **The feed is a frozen archive, not a list of what is suspended now.** On 2026-09-10, a clear
   day, it still returned the 14 entries from the 2026-08-22..24 event, with the feed's own
   `updated` stuck 17 days in the past. It is never emptied. **This is the feature's most dangerous
   failure mode and it is silent:** an implementation asking "does my district appear in the feed?"
   would suppress the alarm every single day, forever, for every user in 高雄, 臺南, 屏東, 花蓮 and
   臺東 — from the day it shipped. The rule is presence **and** a target-date match, never presence
   alone, and "no entry matches today" is the overwhelmingly common case.
3. **Presence ≠ suspension.** Of the full 1,374-alert archive, 64 say `尚未宣布消息` or
   `尚未列入警戒區`, 44 say `照常上班`, 12 say `照常上班、停止上課` and 5 say
   `未達停止上班及上課標準` — 125 published entries that are not a 停班.
4. **`countyName` (history API only) is not reliable.** 19 of the 1,374 archived records disagree
   with their own description — e.g. `countyName: "臺東縣延平鄉"` where the description says
   `臺東縣金峰鄉`. **Parse the area out of `description`; never trust `countyName`.**
5. **`msgType` is `Alert` (898), `Update` (474) or `Cancel` (2).** Do not filter on
   `msgType == "Alert"` — `Update` is how a county re-announces for the next day and carries real
   suspensions. Both `Cancel` records are from 2015, in the retired format, and neither is a
   morning revocation: one withdrew an *evening* suspension at 14:40 the same day, the other
   withdrew a `所有縣市照常上班上課` notice at 11:40. There is **no `Cancel` at all in the 1,266
   modern-format records.** Treat a `Cancel` as "not a suspension" ⇒ ring; never as confirmation.

#### 2.5 `severity` is a usable cross-check, as a binary

Measured across the **complete archive of 1,374 DGPA 停班停課 alerts (2014-07-22 … 2026-08-24)**,
harvested from every one of the 62 events NCDR indexes:

| prose | n | `Extreme` | `Severe` | `Minor` |
| --- | --- | --- | --- | --- |
| 停止上班 (incl. 已達停止上班及上課標準) | 1142 | **1142** | 0 | 0 |
| 照常上班 | 44 | 0 | 43 | 1 |
| 照常上班、停止上課 | 12 | 0 | 12 | 0 |
| 尚未宣布消息 / 尚未列入警戒區 | 64 | 0 | 2 | 62 |
| 未達停止上班及上課標準 | 5 | 0 | 4 | 1 |

**The only supportable rule is the binary one: `Extreme` ⟺ 上班 is suspended.** Zero
counter-examples in 1,266 modern-format records. `Severe` and `Minor` are *not* two distinct
meanings — both mean "not a 停班", and the same sentence appears under either. An earlier draft of
this spec read `Severe` as "school only" from a 365-record sample; that was an artifact of the
sample and is wrong.

Use it as an **assertion, never as the decision**: parse the prose, then require
`(work == suspended) == (severity == "Extreme")`, and ring on disagreement. It is a free tripwire
for exactly the mistake that is easiest to make — `未達停止上班及上課標準` contains the substring
`停止上班`, and all five such records in the archive are `Severe`/`Minor`, so the assertion catches a
naive `contains` parser before it silences someone's alarm.

## 3. What the announcements actually say

### 3.1 The grammar

```
[停班停課通知]<area>:<body>行政院人事行政總處。如有任何問題請撥<phone>。
```

`<body>` is `<date?><daypart?><work-and-school-status>。` Every observed combination is in
`docs/dayoff-fixtures.json` as `parseCases` (28 sentence patterns, deduplicated from the full
1,374-alert archive). Examples spanning the range:

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

`Taiwan_Geocode_103` is the code space. Its shape, from NCDR's own published table
(`https://alerts.ncdr.nat.gov.tw/web/StaticFile/Document/Taiwan_Geocode.xlsx`, keyless, three sheets):

| form | level | in the DGPA archive |
| --- | --- | --- |
| 2 digits | 直轄市 — `63` 臺北市, `64` 高雄市, `65` 新北市, `66` 臺中市, `67` 臺南市, `68` 桃園市 | 6 distinct codes |
| 5 digits | 縣 / 市 — `10002` 宜蘭縣, `10013` 屏東縣, `09007` 連江縣 … | 17 distinct codes |
| 7 digits | 鄉鎮市區 — `6501200` 新北市瑞芳區, `1001416` 臺東縣蘭嶼鄉 … (368 nationally) | 150 distinct codes |
| `#######-###` | 村里 — `6301100-043` 臺北市士林區永福里 (7,851 nationally) | **never emitted** |

**村里 codes are seven digits, a hyphen, then a three-digit serial — not ten digits.** An earlier
draft of this spec said 10 digits; that was wrong. Every village code's 7-digit prefix is its
district's code, with zero exceptions in the national table, so one prefix test covers every
granularity the code space can express:

```
matches = value == myDistrictCode7
       || value.hasPrefix(myDistrictCode7 + "-")   // a 里 inside my district
       || value == myCountyCode
```

A 里 match is **not** a day off for the whole district — see §5 step 3. DGPA has never emitted one
here, so this branch is cheap insurance against a future format change, not live behaviour.

All 22 counties appear in the archive. **A county-level announcement covers every district inside
it; a district-level announcement covers only that district.**

### 3.3 Two format eras, and why the id is not the code

Announcements sent **before 2016-06-13** are a different, now-retired shape and must be treated as
unparseable (which means: ring). They have no `[停班停課通知]` prefix, no status prose at all, bundle
many areas into one record (up to 24 counties, and up to 49 `<area>` blocks in the CAP), carry no
`_i_` segment in the identifier, and declare `Taiwan_Geocode_100` rather than `103` — a different
code space in which 桃園 is `10003`/`1000301`, not `68`/`6800100`. **108 of the 1,374 archived
alerts are of this kind** (and 324 lack the `_i_` identifier segment). They are historical only; the parser must fail open on them rather than
half-understand them.

**Always check `<valueName>` before comparing a code**, and treat any valueName other than
`Taiwan_Geocode_103` as unknown ⇒ ring. The scheme is versioned by ROC year and has already changed
once.

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
3. Resolve `area` against the user's stored **(縣市, 區) pair**, after 臺→台 normalisation on both
   sides. Exactly a county name ⇒ covers all its districts; county+district ⇒ that district only;
   a 里 inside the user's district, or any longer/unrecognised form ⇒ **ring**, and surface it as
   "部分里停班" rather than as "no announcement". **Never key on the district name alone** — eight
   district names are ambiguous nationally (a 基隆市信義區 suspension must not silence a 臺北市信義區
   user), and `postalCode` is not a substitute (嘉義市 and 新竹市 collapse several districts onto one
   3-digit prefix).
4. Does `area` cover the user's **home** district **or** their **destination** district? (P3, P4 —
   route interior points are never considered.) No ⇒ ring.
5. Resolve the target date (§3.1). Not equal to the alarm's own date ⇒ ring. Sent more than two
   Taipei calendar days before that date ⇒ ring (§8 item 2, v4).
6. Resolve the day part. Not full-day and not 上午 ⇒ ring.
7. Parse `上班` and `上課` independently, checking `照常` **before** `停止`.
8. Assert the parse agrees with `severity` (§2.5). Disagreement ⇒ ring.
9. Apply the P1 truth table. Only now may `.suppress` be returned.

**Then, for (B),** independently: if the alarm's date is `是否放假 == 2` in the official calendar
*and* the user's repeat schedule would have rung that day, suppress.

**Cache rules.** The decision path never makes a synchronous network call and never geocodes — it
reads a stored snapshot. Store the raw bytes, the fetch time, **and the source's own update time**.
Re-derive the decision against the alarm's date every time; never replay a stored verdict. A cache
older than a fixed maximum age (§8 — the number is not yet chosen) is treated as absent ⇒ ring.

**Do not reach for an App Group.** This project has no App Group entitlement on either target, and
adding one means new entitlements on two targets, regenerated provisioning profiles and an App
Store Connect identifier change — on an app whose archive-and-upload path `docs/STATUS-IOS.md`
already flags as fragile. The alarm's custom presentation gets its dynamic data from
`AlarmAttributes.metadata`, frozen at schedule time, which is exactly what
`CommuteAlarmMetadata` already carries. **Put the suppression text there when the background task
re-schedules**, the same moment it already re-decides the rain adjustment. Whether a Live Activity
body can read an App Group container at fire time is unverified and must not be designed around.

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
contradicts it: across 1,374 archived alerts there is no `Cancel` whatsoever in the 1,266
modern-format records, and the two 2015 ones are same-day midday withdrawals, not dawn reversals
(§2.4). The ruling still rests on the owner's domain knowledge rather than on measurement — the
archive can only show that it has not happened — so it is recorded here rather than buried in code.

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

**Path A inverts an ordering the shipped code depends on.** AlarmKit has no `update`; rescheduling
is cancel-plus-schedule, and this app deliberately schedules the replacement *first* so that a throw
leaves the user with their old alarm rather than none. Suppression has no replacement to schedule
first, so cancelling is a one-way operation with no safety net: if the decision is wrong, the user
has no alarm at all. Prefer re-scheduling at the normal time with metadata marking it suppressed
over cancelling outright. Treat **any** throw from `schedule`/`cancel` as "keep the existing alarm" —
the framework's only declared error is `maximumLimitReached`, so a background failure surfaces as an
opaque error, never as a documented "not permitted".

**The background capability does not need proving.** This app has shipped
`BGAppRefreshTask`/`BGProcessingTask` → `AlarmManager.shared.schedule` + `.cancel` since 1.6.5
(2026-08-04), App-Store-approved. The `fetch` and `processing` background modes are already
declared and were already explained to App Review in an accepted submission. The day-off check is a
new **input** to a re-decision path that already exists — extend it, do not build it. (The repo's
standing warning still applies: a `BGTaskSchedulerPermittedIdentifiers` entry that does not match
code crashes the app at launch.)

Fetch opportunities, any of which refreshes the cache: app foreground; the existing evening-preview
window (~21:00, which is exactly DGPA's announcement window); an opportunistic
`BGAppRefreshTask` at alarm−70 min; and the user picking up the phone when the alarm rings.

**This app already has the machinery.** `RainyClock/Services/BackgroundWeatherRefresh.swift` runs
three background windows to re-decide the armed alarm, `AlarmViewModel.refreshScheduledAlarmUnattended()`
is the unattended re-decision entry point, and `EveningPreview.swift` already tells the user the
night before what tomorrow's alarm will do. Day-off is another input to that same pipeline, not a
new one. The holiday filter belongs in the date predicate inside
`AlarmTimeCalculator.nextAlarmDateForWeatherCheck`.

**Path C — the notification says it, even if the app never wakes (decided 2026-09-23, iOS).**
The owner's real fear was a phone left untouched all night. So the server broadcasts one *visible*
push to every registered device, carrying no location, and the app's Notification Service
Extension — which iOS runs on delivery even when the app is closed — reads the confirmed
districts from the App Group, fetches the feed, runs the same decision function, and rewrites
the notification: time-sensitive with the area named on a match, informative with the reason
when the district is mentioned but nothing is silenced, silent and passive when unrelated. The
server never learns where anyone lives. Path C is a *notification*, not a decision: the alarm is
still only silenced by the app, on its own evidence, under Path A/B rules. (The "no App Group"
constraint in §5 is now historical: the group exists for this one read-only mirror, not for the
ring screen.) Android can do the same with FCM data messages handled in a foreground-exempt
receiver; the decision function stays shared.

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

**The real risk is displaying something wrong, not fetching it.** The operative provision is
**災害防救法第 53 條第 3 項**: disseminating rumours or false information about a disaster, where that
is sufficient to cause harm — up to three years, or a fine up to NT$1,000,000. It does **not** reach
a faithful relay of a genuine announcement; truthful republication is not 不實訊息. (¶2, the
knowingly-false clause, penalises false *reports to the authorities* and does not apply to an app.
Whether ¶3 requires intent rather than negligence is an inference, not a legal opinion, and this
spec does not rely on it.) The exposure is therefore purely a correctness question, and it lands
exactly on the stale-feed hazard in §2.4: showing 「你住的區今天停班停課」 on a day when that is not
true is precisely the conduct ¶3 describes. This is the strongest argument for the fail-open rule
and the date match. Therefore:

- Any "today is suspended" surface must show the source *and* **the source's own update time**,
  never only the app's fetch time. Name both roles — the feed's own author is NCDR while each entry's
  author is DGPA — so: **`資料來源：行政院人事行政總處（經國家災害防救科技中心 NCDR 發布）`**.
  Under OGDL v1 attribution is a **licence condition** (Article 3 ¶2), and omitting it voids the
  licence retroactively; it is not a courtesy.
- "Fetch failed" and "no suspension announced" must be **visibly different states**, and only the
  latter may affect the alarm. `尚未宣布消息` is a third state and should say so.
- Disclaimer, on the settings page and at the foot of any suspension screen:
  > 本資訊擷取自行政院人事行政總處公開資料，僅供參考，**實際停止上班上課以各縣市政府公告為準**。
  > 民間事業單位請依勞動部「天然災害發生事業單位勞工出勤管理及工資給付要點」辦理。網路異常時本App將照常響鈴。
- Credits page: `資料來源：政府資料開放平臺 data.gov.tw／行政院人事行政總處`.
- Localise the disclaimer wherever the app ships another language.

**App Review, corrected.** Guideline 5.2.5 is about resembling *Apple's* products and has nothing
to do with government impersonation; no guideline prohibits attributing government data, and naming
the true source is the opposite of impersonation. The governing rules are 5.2.1 (no misleading or
copycat representation) and 5.2.2 (third-party content must be permitted under that service's
terms) — so keep the app's own name and icon dominant, phrase it as a source credit, and never use a
government seal or crest. **5.2.5 is live for this app for a different reason**: it was rejected
once over Apple Weather attribution. The DGPA credit must not displace, obscure or out-rank the
WeatherKit mark on any surface where forecast data appears.

**A reviewer will never see a typhoon.** This app has already taken a 2.1(a) rejection for a
reviewer hitting a dead end, and already established the answer — `evening_preview_send_sample`.
Ship an equivalent "show me one now" control for the day-off path and name it, with where to tap
it, in the App Review notes in `docs/appstore-metadata.md`.

**Android.** The manifest already declares `SCHEDULE_EXACT_ALARM` (`maxSdkVersion="32"`) plus
unrestricted `USE_EXACT_ALARM`, correctly gated at runtime — this feature needs no permission
change. The Play Console declaration for `USE_EXACT_ALARM` rests on the app's core functionality
being an alarm clock, so **frame this as a refinement of alarm behaviour, never as a
disaster-information service**. Leave `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` undeclared: exact
alarms already fire in Doze, and adding it would create a policy question the app does not have.

---

## 8. Open questions — resolve these before or during implementation

Owner decisions. The first is now answered; the other three have a defensible default recorded
here — build on it and say so, and the owner can overrule cheaply.

1. **Is `both` an AND?** — **Resolved 2026-09-22: it is an OR.** Either suspension alone silences
   the alarm when both switches are on. Written into §1; `decide-08` flipped from `ring` to
   `suppress` and `specVersion` bumped to 3.
2. **Maximum cache age** before a cached suspension is ignored.
   **Default: 18 hours.** Rationale: it must comfortably span the real gap — an announcement made
   at 19:00 the night before, read by an alarm at 07:00 the next morning, is 12 hours old and must
   still count. 18 h leaves margin for a late fetch while guaranteeing that a suspension can never
   be applied two mornings running on one fetch. Measure from the *source's* update time, not the
   app's fetch time.
   **Narrowed in v4 (owner, 2026-10-01): 18 h limits the download, not an announcement that names
   the alarm's day.** Applied to the notice as well, it expired closures that were still true: a
   12:00 「明天停止上班」 turned 18 h old at 06:00 the next morning, and every refresh from then on
   put the 07:30 alarm back on a confirmed day off; a date announced two days ahead lapsed the
   afternoon before it. The rule is now:
   - **The feed copy** must have been fetched at most 18 h ago — unchanged. A fresh copy is what
     shows that no newer notice (a 照常上班, a Cancel, an Update) has replaced the one being
     applied, and it alone already stops one fetch from silencing two mornings.
   - **A notice that names the alarm's day** (今天 / 明天 / M/D, resolved as in §3.1) is current
     for that whole day, however long ago it was sent, provided it was sent **at most two Taipei
     calendar days before that day** (`targetDate − date(sentDate) ≤ 2`). The date match already
     keeps a 今天/明天 off every other day; the lead limit is what keeps a year-rolled M/D out —
     a 「9/15」 sent in October resolves to next September, and the feed is a frozen archive
     (§2.4). A notice announced further ahead rings (P5).
   - **A notice that names no day** never suppresses; it still ages out 18 h after it was sent,
     so an old 尚未宣布消息 cannot keep the user's district reading as undeclared.
   Everything is still measured from the source's time; the fetch time only dates the copy.
   Measured on the full archive (`announcementLead` in `docs/dayoff-corpus-summary.json`): all
   1,233 dated modern announcements name the day they were sent (577) or the next day (656) —
   none further ahead, none year-rolled — so two days is one day of margin over anything DGPA has
   published. And the v3 failure is real: 4 of 890 full-day or morning 停班 were sent more than
   18 h before 07:30 of their day, most recently 臺中市 and 南投縣 at 08:50–09:35 on 2026-07-10
   for 7/11 — a phone that had skipped 7/11 would have re-armed it from about 03:30 that morning.
3. **Is the feature hidden outside Taiwan?**
   **Default: the feature is visible only when the user has set a Taiwanese 縣市/區 pair**, which is
   a prerequisite for it to work at all. No locale sniffing, no region gate — the setting is the
   gate. A Taiwanese user abroad keeps whatever they set, which is correct: their office is still
   closed even if they are not in it.
4. **Pre-iOS 26 devices** have no AlarmKit custom presentation, so Path B's ring screen does not
   exist there.
   **Default: on the notification path, send the day-off information as its own local
   notification** timed just before the alarm, reusing the `AlarmDecisionChange` pattern that
   already exists for "the rain decision changed after the preview". It is weaker than a ring
   screen — a banner can be missed — but it is the same mechanism the app already relies on for a
   comparable message, and it keeps a single code path for the decision itself.

### Resolved since v1

- **How a revocation is expressed** — moot. Owner ruled announcements are never revoked (§6).
- **How the user's district gets set** — settled by measurement. `CLPlacemark.locality` holds the
  **區** in Taiwan and `administrativeArea` holds the **縣市**; `subLocality` holds the 里 and is
  populated; `subAdministrativeArea` is a useless duplicate of `administrativeArea` — never use it.
  Two hard constraints follow. Apple's documentation **instructs developers not to geocode while the
  app is inactive or in the background**, which is exactly when the alarm decides, and offline the
  geocoder returns only a country code. So: **resolve the district once at address-entry time in the
  foreground, show it in an editable 縣市/區 picker prefilled from the geocode, persist the confirmed
  pair, and geocode never at alarm time.** The picker is the source of truth; geocoding only
  prefills it. No stored district ⇒ ring.
  Three implementation traps, all verified: pass `Locale(identifier: "zh-Hant-TW")` explicitly or
  the placemark comes back romanised with inconsistent suffixes and cannot be joined against the
  feed (`MapItemResolver.preferredSearchLocale` picks locale from the query script, so it must be
  overridden for this); Apple returns 臺北市 but also 台灣大道, so 臺↔台 normalisation is required on
  both sides; and **two concurrent `reverseGeocodeLocation` calls on the same `CLGeocoder` instance
  hang forever** — not an error, a hang, so fail-open cannot catch it. `MapItemResolver` holds one
  `CLGeocoder` inside an `actor`, which serialises correctly today, but any refactor that resolves
  home and destination in parallel through it deadlocks silently. Mandate a timeout around every
  geocode. Ship the 368-row 縣市/鄉鎮市區 table in the bundle (generate from NCDR's
  `Taiwan_Geocode.xlsx` or `/server/v1/Generic/town/103/{county}`); it changes about once a decade.
  Android: same design, and more strongly — AOSP's own javadoc says the `Geocoder` **must not be
  used for any safety-critical purpose**, and it is absent entirely on non-GMS devices.
- **Sub-district announcements in the national feed** — answered. Across the complete 1,374-alert
  archive, DGPA has never emitted a 村里 code, no `areaDesc` ends in 里 or 村, and none names a
  school. 臺北市 appears only ever as the city-wide code `63`, across all 44 of its alerts. Taipei's
  real 里-level and school-level suspensions therefore have **no representation in this feed at
  all**. §5 step 3 still rings on a 里-level match, as insurance.
- **AlarmKit background rescheduling** — not a question: this app has shipped it since 1.6.5 (§6).
- **App Review / Play policy** — examined; see §7. Background modes are already declared and
  accepted; the 5.2.5 premise was wrong; the real requirements are a reviewer-visible demo control
  and not out-ranking the WeatherKit mark.

### Still unverified — do not present these as known

5. **A parent's question may be unanswerable.** 停課 is announced per school and per 里, and this
   feed carries neither. If `mode: school` ships, the settings copy must say what it can and cannot
   see.
6. **End-to-end feed latency during a live event** has never been measured — only after the fact.
7. **Whether Android's `getLocality()` returns the 區 in Taiwan** is untested. Apple's behaviour was
   measured; Android's was not.
8. **Whether a Live Activity body can read an App Group container at fire time** — untested, and
   deliberately not designed around (§5).

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
5. Path B ring screen (§6) — via `CommuteAlarmMetadata` at schedule time, **not** an App Group.
   Add the reviewer-visible "show me one now" control alongside it (§7).
6. Opportunistic background refresh, with a comment saying correctness must not depend on it.
7. Path A last, default off, with the undo notification.
8. Credits, disclaimer, `docs/PRODUCT_DECISIONS.md` entry, and update `docs/STATUS-IOS.md`.

Android differs only in §6's fetch timing and in Big5 decoding (`Charset.forName("Big5")`,
`ZoneId.of("Asia/Taipei")`). The decision logic and the fixtures are shared verbatim.

---

## 10. Starting from cold

For a session that has just opened this repo and been told to build the feature.

**Read in this order.** `CLAUDE.md` (which worktree am I in, which branch do I commit to) →
`docs/STATUS-IOS.md` or `docs/STATUS-ANDROID.md` for your platform → §0 and §1 of this file →
`docs/dayoff-fixtures.json` → then the section you need. Do not skim §1: those five decisions are
settled and re-litigating them wastes a session.

**Check the version first.** Your platform's status log records
`Day-off: implemented against spec vN`. If N is below the version in this file's heading, read the
changelog entries since N before writing code — something you would otherwise assume is still true
has changed.

**Verify before you trust.** Every statistic quoted in this spec is backed by
`docs/dayoff-corpus-summary.json`, which also carries the commands to regenerate the full corpus.
If a claim here matters to a decision you are making and you doubt it, re-derive it — that is the
intended use, not a sign of distrust. Two of this spec's own claims were wrong in v1 and were
caught exactly that way.

**Build order** is §9. Start with feature (B); it is small and clean and exercises the whole
pipeline before (A) adds a hostile parser.

**Three open decisions belong to the owner, not to you.** They are listed at the top of §8 and each
has a defensible default recorded there. The `both` question is answered (OR). Ask rather than
assume, and when you get an answer, write it into §1 and bump the version.

**The one rule that outranks everything else:** the alarm rings unless there is positive, current,
matching evidence that it should not. Every ambiguity resolves toward ringing. If you find yourself
writing a branch that suppresses an alarm on incomplete information, that branch is wrong.

### Changelog

- **v4** (2026-10-01) — **an announcement stays valid for the day it names.** Found by
  adversarial review of iOS and approved by the owner the same day: the 18 h limit was measured
  against each notice, so a closure announced at 12:00 for tomorrow expired at 06:00 on the day
  itself and the alarm was re-armed on a confirmed day off. §8 item 2 now applies 18 h to the
  feed copy (unchanged) and to notices that name no day; a notice naming the alarm's day counts
  for that whole day if it was sent at most two Taipei days before it; §5 step 5 says so.
  `docs/dayoff-corpus-summary.json` gains `announcementLead`, the archive measurement behind the
  two-day limit and the four real announcements v3 would have expired. No fixture expectation
  changed — every `decisionCases` entry is still decided the same way — but the rule did, so
  `specVersion` → 4. The new cases need an evaluation time the fixture schema does not carry, so
  they live in iOS's `DisasterSuspensionTests` (noon 「明天」 read at 06:00:01 and 07:29, 「9/16」
  sent 9/14 read on 9/15 14:01 and 9/16 07:00, a 3-day lead and a year-rolled 「9/15」 sent in
  October ringing). iOS implemented it the same day.
  **Android: not yet implemented** — when it starts, build against v4, not v3.
- **v3** (2026-09-22) — **`both` is an OR.** Owner ruled that ticking work and school means either
  suspension alone silences the alarm. §1 truth table and §8 item 1 updated; `decide-08` now
  expects `suppress`; `specVersion` → 3, so both platforms must re-run. iOS updated the same day
  (evaluator, settings copy, tests). Also notes that iOS has implemented the feature behind a
  release gate, and corrects the v2 changelog line below: **324** alerts lack the `_i_` segment,
  not 107.
- **v3, amended** (2026-09-23) — Path C added to §6: a broadcast visible push personalised on the
  phone by a Notification Service Extension, so an untouched phone still shows the announcement.
  No fixture or decision-function change, so `specVersion` stays 3.
- **v3, amended** (2026-09-24) — target release renamed from 1.7.1 to 1.8.0 (the owner reserved
  1.7.1 for other work). No behaviour change.
- **v1** (2026-09-10) — initial spec. Sources verified first-hand; 365-record corpus harvested from
  the NCDR history API across eight typhoon events (2024-07 … 2026-08); fixtures generated from it.
  Nothing implemented on either platform.
- **v1, amended** (2026-09-10) — owner ruled that a 停班停課 announcement is never revoked before
  the morning it applies to. §8's top unknown retired; §6 rewritten accordingly and Path A's
  remaining blocker narrowed to its own state handling. No fixture and no decision-function
  behaviour changed, so `specVersion` stayed at 1.
- **v2** (2026-09-10) — added `docs/dayoff-corpus-summary.json`, a `fieldGuide` to the fixtures,
  §10 for cold starts, and defaults for three of the four open owner decisions. Corpus widened from
  365 alerts to the **complete 1,374-alert archive
  (2014-2026)**, and four v1 statements corrected at source. **Four fixture cases and five decision
  cases added, so `specVersion` is bumped and both platforms must re-run.**
  - **村里 codes are `#######-###`, not 10 digits** (§3.2). A 7-character prefix test now covers
    every granularity, and 里 matches ring rather than suppress.
  - **`severity` is a binary, not a three-way map** (§2.5). v1 read `Severe` as "school only" from a
    365-record sample; on the full archive `Severe` and `Minor` both simply mean "not a 停班". The
    supportable rule is `Extreme` ⟺ 停止上班, with zero counter-examples in 1,266 modern records.
  - **Never read the geocode out of the entry `id`** (§2.3, §3.3). 107 archived alerts have no
    `_i_` segment, one alert can cover 24 counties, and pre-2016 records use a different code space.
  - **No App Group** (§5). The project has no such entitlement; the alarm screen's data must ride
    `CommuteAlarmMetadata`, frozen at schedule time.
  - Added: the frozen-archive hazard stated with its real consequence (§2.4), district resolution
    settled on `CLPlacemark.locality` plus a confirmed picker (§8), the 5.2.5 premise corrected and
    the real store constraints named (§7), and the cancel-to-suppress ordering hazard (§6).
