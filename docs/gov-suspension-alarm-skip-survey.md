# Skipping the alarm on a 停班停課 day — feasibility survey

Question: can Rainy Clock read 行政院人事行政總處 (DGPA)'s 臨時停班停課 announcements and
skip the alarm when the user's city is closed?

Short answer: **yes, the data is public and openly licensed — but there is no official JSON
API, and the hard part is not the feed.** It is the 04:30 announcement deadline, what
"skip" means to an alarm that is armed as a *weekly repeat*, and the fact that a false
positive makes someone miss work. Those three decide whether this ships well.

> **Verified how far:** this survey was written from a sandbox whose egress policy blocks
> every `*.gov.tw` host, so none of the endpoints below were called. Formats, dataset ids
> and announcement deadlines come from the regulation, the open-data catalogue entries and
> third-party clients that consume the same pages. Before writing a parser, run one manual
> pass from a network that can reach DGPA and pin the real response bytes.

## What DGPA actually publishes

| Source | Shape | Notes |
| --- | --- | --- |
| `https://www.dgpa.gov.tw/typh/daily/nds.html` (English: `ndse.html`) | Server-rendered HTML table, one row per 縣市 | The canonical page, and the one every client that demonstrably works reads. Current markup has usable hooks (`#Table`, `.Table_Body`); the 2016 vintage did not. No documented licence. |
| data.gov.tw dataset **20457**「天然災害停止上班、停止上課情形-CAP 檔」 | **CAP** (Common Alerting Protocol) XML | Published by DGPA, listed 2015-08-20, 更新頻率 daily, free, 政府資料開放授權條款第 1 版. This is the only source with a real data contract and an explicit licence. |
| data.gov.tw dataset **61996**「天然災害停止上班及上課情形」 | Catalogue entry pointing back at the website | Not a separate feed. |
| `https://www.dgpa.gov.tw/opendata/typhoon/ndwork.json` / `.xml` | **Unverified** | One client calls these before falling back. May be the real thing, may not exist — see below. Highest-value single `curl` in this document. |
| data.gov.tw datasets **14718 / 26557**「政府行政機關辦公日曆表」 | CSV / XML / JSON | The *ordinary* calendar — 國定假日, 彈性放假 and 補班日. Different feature, same agency; see below. |

Dataset resource URLs are reachable programmatically through the catalogue's REST endpoint
(`https://data.gov.tw/api/v1/rest/dataset/<id>`) rather than being hardcoded, which is worth
using — the file URL behind a dataset has changed before.

There is no official rate limit, uptime target, or change notice for any of these. The DGPA
site is well known for buckling under load during a typhoon, which is exactly why every
third-party tool in this space (TWTools, the 天災假期 Android app, `mcp-tw-typhoon`) puts a
cache in front of it rather than hitting it per device.

### Is there an official JSON API? — one unverified lead, and it matters

A GitHub sweep turned up five more independent clients. Reading their source changed the
answer from a flat "no" to "there is a lead, and nobody has demonstrably used it".

**The lead.** `pengjun0429/-Suspension-of-work-and-classes`, a LINE bot claiming
sub-minute push, does not scrape at all. It calls, in order:

```
https://www.dgpa.gov.tw/opendata/typhoon/ndwork.json
https://www.dgpa.gov.tw/opendata/typhoon/ndwork.xml
```

A JSON endpoint on DGPA's own domain, under a plausible `/opendata/typhoon/` path. If it
is real it is strictly better than everything else in this document, and most of the
scraping advice above stops mattering.

**Why it is probably not evidence of anything.** That client's parser reads:

```ts
const items  = Array.isArray(data) ? data : data?.records || data?.dataset || []
const city   = item.CityName || item.city || item.location || ''
const status = item.Status   || item.status || item.description || ''
```

Four guesses at one field name, three at the container shape. Nobody who has seen the
response writes this. And when both URLs fail it returns `getDefaultCounties()` — every
county "照常上班上課" — with `isLive: false` and a `source` string that claims dataset
20457 it never fetched. **Outside typhoon season that fallback is indistinguishable from
success**, so the author would get no signal the URLs were wrong. The code is entirely
consistent with never having received a 200.

Treat `ndwork.json` as **the single highest-value thing to `curl`**, not as a finding. One
request settles it, and the answer changes the design.

**Everyone who demonstrably reached DGPA scrapes the HTML page.** Four of them:

| | `tw-nds-cli` (2016) | `mcp-tw-typhoon` (2026) | `notify-closed-school` (Go) | `get_dgpa` (2024) |
| --- | --- | --- | --- | --- |
| Finds the table by | `table[bgcolor="#cdfad9"]` | scanning tables for 「縣市名稱」 | `#Table>.Table_Body>tr` | BeautifulSoup |
| Timestamp from | `td>p>font[color]` | regex on 更新時間 | `#Content>.Content_Updata>h4` | — |

The 2016 selectors are long dead, but the Go client shows the **current** page does have
stable hooks — `#Table`, `.Table_Body`, `#Content`, `.Content_Updata` — so scraping it is
less desperate than `mcp-tw-typhoon`'s text-scanning suggests. It is still a page, not a
contract.

### The CAP dataset may be the wrong horse

`notify-closed-school` carries a dead constant and the reason it died:

```go
// const WorkSchoolCloseURL = "https://alerts.ncdr.nat.gov.tw/RssAtomFeed.ashx?AlertType=33"
// 由於政府資料開放平臺的資料更新時間不穩定，因此使用 https://www.dgpa.gov.tw/
```

Someone ran the NCDR CAP/Atom feed in production, found the open-data platform's update
timing unreliable, and moved back to scraping the web page. That is first-hand operational
evidence against the recommendation this survey started with — and it lands on exactly the
question that decides this feature, because a feed that lags the 04:30 deadline is not
merely stale, it is useless. The licensing argument for the CAP file stands; the timeliness
argument does not survive contact with someone who tried it.

### What the page actually contains

Assembled from the two parsers that read it, not from the page itself:

- **Three columns**: 區域 / 縣市名稱 / 是否停止上班上課情形. A row with a single cell means
  無停班停課訊息; region cells span rows, so a row may have 2 or 3 `td`s.
- **Today and tomorrow share one cell**, as sentences split by 「。」 or newline, each
  repeating the county name — the Go client splits on that and strips the leading 縣市 from
  every fragment. Any parser must separate 今天 from 明天; a commute alarm cares about one
  of them and reading the wrong sentence is a wrong answer, not a missing one.
- **The idle vocabulary is plural**, and no client enumerates it confidently:
  尚未列入警戒區 / 今天照常上班、照常上課 / 明天照常上班、照常上課 / 尚未宣布消息.
  "Not suspended" is a row that says so, never an absent row.
- **Partial closures are free text** — the LINE bot sniffs for 部分|局部|個別|下午|上午|晚上|
  特定|山區|鄉|鎮|村|學校 alongside 停止. That is a regex over prose, which is what the data
  is.
- **A page-level 更新時間** in `YYYY/MM/DD HH:MM:SS`, Asia/Taipei. The only way to tell a
  fresh "照常" from a stale one.
- **UTF-8**, county names use **臺**, and every client normalises 台 → 臺.

### The failure mode that bot demonstrates, and what it means here

`fetchDgpaOpenData` returning "all counties normal" when it reached nothing is the exact
bug this feature must not have. For an alarm the safe direction is luck rather than design:
"could not tell" collapsing into "no suspension" means the alarm rings, which is the
outcome we want anyway. But it must be **deliberate** — the app has to distinguish
*confirmed normal* from *unknown*, because the moment anyone wants the inverse behaviour
(skip on suspension) that conflation becomes a missed alarm. Store the 更新時間 and the
reachability separately from the status.

### The check that is still not done

GitHub **code** search — who has `dgpa.gov.tw` in their source — needs a signed-in session,
and this one is scoped to this repository; `grep.app` and `searchcode` sit behind the same
egress policy as the government hosts. Repository search was possible and is what found the
five clients above. Along with `curl`-ing `ndwork.json`, a logged-in code search is the
remaining way to find out whether anyone has actually used a structured endpoint.

## The timing constraint, which is the real design input

天然災害停止上班及上課作業辦法 fixes when a 縣市 may announce:

- **Full day / morning half-day** — announced **the previous evening between 19:00 and 22:00**,
  broadcast by 23:00. Effective from 00:00 the next day.
- **If conditions worsen after midnight** and the previous evening produced no announcement —
  **by 04:30 that morning**. Effective from the normal start of work (usually 08:00).
- **Afternoon or evening only** — by **10:30** that morning.

So a commute alarm can be skipped correctly only if the decision is taken **after 04:30 on
the morning itself**. An evening-before check catches the common case and misses precisely
the case where the news is most surprising.

Rainy Clock already has the right hook: `BackgroundWeatherRefresh` (iOS) and
`WeatherRefreshWorker` (Android) both run ~45 minutes before the lead-time point to re-decide
the rain adjustment. For a 07:00 alarm that window sits comfortably after 04:30. The
suspension check wants the same trigger and the same "if it did not run, fall back safely"
contract that file already documents.

## What "skip" costs on each platform

The two schedulers are not symmetric here, and this is the biggest implementation asymmetry
in the feature.

**Android is easy.** `AlarmScheduler.registerExact(triggerAt:)` arms a *one-shot* exact alarm
and `scheduleNextAfterFire()` re-arms the following one. Skipping a day is just computing the
next trigger past today — no new mechanism, and nothing stays broken if a later run is missed.

**iOS is not.** `AlarmKitScheduler.scheduleAlarm` arms a single `Alarm.Schedule.relative` with
`repeats: .weekly(...)`. Cancelling and re-arming the same weekly schedule at 04:35 still
fires at 07:00 today, so "skip today" has to be emulated — either a one-shot `.fixed`
schedule for the next valid occurrence with the weekly schedule restored afterwards, or the
weekly schedule re-armed with today's weekday temporarily removed and restored later.

Both emulations **invert the app's current failure mode**. Today's contract is stated in
`BackgroundWeatherRefresh`: a morning where no background task ran still rings, on a stale
decision — never a missed alarm. A skip that depends on a later background run to restore the
schedule can leave the user with *no* alarm, which is a strictly worse way to fail. Whatever
shape this takes needs a restore path that does not depend on the same budget that armed it
(AlarmKit's alarm-update stream on iOS 26, plus the existing app-open path in
`AlarmViewModel.refreshScheduledAlarmIfWeatherIsStale()`).

A cheaper first version sidesteps all of it: **do not cancel — announce.** Keep the alarm
armed and, when the city is closed, change what the ring says ("今天台北市停止上班上課"),
or ring and immediately post the notification. The user gets the information at the moment
they would have got up, and a wrong answer costs them a snooze instead of a job.

## Which city governs

停班停課 is announced per 縣市, and sometimes narrower — 花蓮縣 and 臺東縣 routinely close
only named 鄉鎮. The app has a route, so it has two candidate cities: the origin (home) and
the destination (workplace). 停班 follows the **workplace**, so the destination is the right
default, with an explicit override — plenty of people commute across a county line into a
city that stayed open. 停班 and 停課 also diverge (schools close more readily than offices),
and the announcement has more states than open/closed: 停止上班上課, 上午停班, 延後上班.
Collapsing all of that to a boolean will be wrong for someone.

## The adjacent feature that is probably worth more

Typhoon days are a handful of mornings a year. **`政府行政機關辦公日曆表` (dataset 14718)
covers every 國定假日, 彈性放假 and — the one people actually get wrong — 補班日**, the
make-up Saturdays where the alarm *should* ring and currently will not unless Saturday is
selected. It is static JSON published a year ahead, needs no background timing, has no
false-positive risk, and can be bundled or refreshed once a year. `ruyut/TaiwanCalendar`
already mirrors it as `https://cdn.jsdelivr.net/gh/ruyut/TaiwanCalendar/data/{year}.json`
with `{date, week, isHoliday, description}`.

If the goal is "don't wake me when I don't have to work", the calendar delivers most of it
for a fraction of the risk, and the suspension feed becomes the exceptional case layered on
top.

## Fetch architecture

`weather-proxy/` already exists (Cloud Run, Node, stateless, no storage). It signs the
WeatherKit tokens the Android app cannot hold itself and serves the AI voice. **Both apps
already call it** — Android for `/v1/weather`, and iOS for `/v1/tts` through
`AIVoiceClient`, whose base URL is `VoiceProxyURL` in `Info.plist`. A `/v1/nds` endpoint
there would:

- keep one brittle HTML/CAP parser instead of one in Swift and one in Kotlin,
- put a cache between a typhoon morning and a government site that falls over,
- give a kill switch when DGPA changes its markup, without an App Store release.

The cost is not a new dependency — that precedent is already set — but a heavier one. The
proxy's two current jobs both fail softly: an unreachable proxy costs Android the *freshest*
rain decision (it keeps the previous one) and costs iOS the AI voice (it keeps a bundled
tone). Neither changes whether the alarm rings. A suspension answer would be the first
proxy response that feeds the ring/skip decision itself, so it needs the same contract
stated up front and tested: **no answer → ring normally**, never "wait and see".

The alternative — parse on-device on both platforms, straight from the CAP file — avoids
leaning on a single server during exactly the storm when servers are least reliable, at the
price of duplicated parsers and every device hitting DGPA directly.

Leaning, in order: **`ndwork.json` if it is real**, else the HTML page — *not* the CAP
dataset, whose timeliness a production user already rejected. Whichever it is, put it behind
the proxy with a generous cache and a documented fallback of "no answer → ring normally",
and keep reachability distinct from status so "unknown" never renders as "照常".

## Licensing and attribution

The open-data platform's 政府資料開放授權條款第 1 版 permits commercial use, including in a
paid or ad-supported app, and requires attribution to the source agency. Scraping
`nds.html` carries no such grant, and for an ad-supported app that difference is real.

It also cuts against the timeliness finding above, which is the genuine tension in this
survey: the licensed source may be the late one. If `ndwork.json` exists and sits under
DGPA's own `/opendata/` path, it plausibly resolves both at once — another reason that one
request is worth making before any other decision here.

## Open questions before building

1. **`curl https://www.dgpa.gov.tw/opendata/typhoon/ndwork.json`** (and `.xml`). Everything
   else here is downstream of the answer. One client calls it; nothing shows it works.
2. If that 404s: is there an undocumented XHR behind `nds.html`? Open it with devtools on the
   Network tab. Rows in the document body means scraping is the only route.
3. How late is the CAP feed really? A production user moved off `alerts.ncdr.nat.gov.tw`
   because open-data timing was unreliable, but did not quantify it. Anything that lands
   after 04:30 is useless here regardless of licence.
4. Does AlarmKit on the shipping iOS version expose anything closer to "skip next occurrence"
   than cancel-and-re-arm?
5. Product call: cancel the alarm, or ring with the announcement? (See above — the second is
   safer and much cheaper.)

## Sources

- [行政院人事行政總處 — 天然災害停止上班及上課情形查詢](https://www.dgpa.gov.tw/typh/daily/nds.html)
- [天然災害停止上班、停止上課情形 (CAP) — 政府資料開放平臺 dataset 20457](https://data.gov.tw/dataset/20457)
- [中華民國政府行政機關辦公日曆表 — dataset 14718](https://data.gov.tw/dataset/14718)
- [天然災害停止上班及上課作業辦法 — 全國法規資料庫](https://law.moj.gov.tw/LawClass/LawAll.aspx?pcode=S0110022)
- [bobby1030/tw-nds-cli](https://github.com/bobby1030/tw-nds-cli) — 2016 scraper, `table[bgcolor]`
- [simonliu-moltbot/mcp-tw-typhoon](https://github.com/simonliu-moltbot/mcp-tw-typhoon) — 2026 scraper, `src/logic.py`
- [qmkc/notify-closed-school](https://github.com/qmkc/notify-closed-school) — Go, `api.go`; the NCDR-feed comment and the current selectors
- [pengjun0429/-Suspension-of-work-and-classes](https://github.com/pengjun0429/-Suspension-of-work-and-classes) — `server/dgpaData.ts`; the unverified `ndwork.json` lead
- [laiii97/get_dgpa](https://github.com/laiii97/get_dgpa), [aliceric27/betterdgpa](https://github.com/aliceric27/betterdgpa) — further scrapers
- [ruyut/TaiwanCalendar](https://github.com/ruyut/TaiwanCalendar) — office-calendar JSON mirror
