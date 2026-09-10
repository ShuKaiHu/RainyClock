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
| `https://www.dgpa.gov.tw/typh/daily/nds.html` (English: `ndse.html`) | Server-rendered HTML table, one row per 縣市 | The canonical page everyone screenshots. Legacy markup — `bobby1030/tw-nds-cli` selects it as `table[bgcolor="#cdfad9"]` and reads `td > p > font[color="#000000"]`, which is what a page of that vintage looks like. No documented licence. |
| data.gov.tw dataset **20457**「天然災害停止上班、停止上課情形-CAP 檔」 | **CAP** (Common Alerting Protocol) XML | Published by DGPA, listed 2015-08-20, 更新頻率 daily, free, 政府資料開放授權條款第 1 版. This is the only source with a real data contract and an explicit licence. |
| data.gov.tw dataset **61996**「天然災害停止上班及上課情形」 | Catalogue entry pointing back at the website | Not a separate feed. |
| data.gov.tw datasets **14718 / 26557**「政府行政機關辦公日曆表」 | CSV / XML / JSON | The *ordinary* calendar — 國定假日, 彈性放假 and 補班日. Different feature, same agency; see below. |

Dataset resource URLs are reachable programmatically through the catalogue's REST endpoint
(`https://data.gov.tw/api/v1/rest/dataset/<id>`) rather than being hardcoded, which is worth
using — the file URL behind a dataset has changed before.

There is no official rate limit, uptime target, or change notice for any of these. The DGPA
site is well known for buckling under load during a typhoon, which is exactly why every
third-party tool in this space (TWTools, the 天災假期 Android app, `mcp-tw-typhoon`) puts a
cache in front of it rather than hitting it per device.

### How solid is "no official JSON API"

This is an argument from absence, so it is worth being precise about its strength. DGPA's
own 開放資料 page and the open-data catalogue list the CAP file and the web page and nothing
else; every independent client found — a CLI, an MCP server, a web tool, a Play Store app —
either scrapes the HTML or proxies it, and a developer who had a JSON endpoint would not
choose `table[bgcolor="#cdfad9"]`. That is good converging evidence, but it is not proof:
an **undocumented** XHR endpoint behind the page would show up in none of those places, and
the strongest single data point (`tw-nds-cli`) is old enough to still reference the
pre-`/typh/daily/` URL.

Two checks settle it in about a minute from a network that can reach DGPA:

1. Open `nds.html` with devtools on the Network tab, filtered to Fetch/XHR. Rows arriving in
   the document body means server-rendered and scraping is the only route; a JSON request
   there **is** the undocumented API, and its URL is the answer.
2. `curl https://data.gov.tw/api/v1/rest/dataset/20457` returns the catalogue record as
   JSON, including the real resource URL and 更新頻率 — which is also the right way to
   resolve that URL at build time rather than hardcoding it.

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

Leaning: parse the **CAP dataset** rather than scrape the HTML page (it is the licensed one
with a real schema), and put it behind the proxy with a generous cache and a documented
fallback of "no answer → ring normally".

## Licensing and attribution

The open-data platform's 政府資料開放授權條款第 1 版 permits commercial use, including in a
paid or ad-supported app, and requires attribution to the source agency. Scraping
`nds.html` carries no such grant. For an app that carries ads, that difference is a reason to
prefer dataset 20457 on its own.

## Open questions before building

1. Real bytes: fetch `nds.html` and the 20457 CAP resource once from a Taiwanese network and
   record the encoding, the per-county field names, and what the "no suspension anywhere"
   response looks like (a distinct payload, or the same table full of 照常上班上課?).
2. Does the CAP file publish on the same schedule as the web page, or lag it? A feed that
   updates hours after 04:30 is useless for this.
3. Does AlarmKit on the shipping iOS version expose anything closer to "skip next occurrence"
   than cancel-and-re-arm?
4. Product call: cancel the alarm, or ring with the announcement? (See above — the second is
   safer and much cheaper.)

## Sources

- [行政院人事行政總處 — 天然災害停止上班及上課情形查詢](https://www.dgpa.gov.tw/typh/daily/nds.html)
- [天然災害停止上班、停止上課情形 (CAP) — 政府資料開放平臺 dataset 20457](https://data.gov.tw/dataset/20457)
- [中華民國政府行政機關辦公日曆表 — dataset 14718](https://data.gov.tw/dataset/14718)
- [天然災害停止上班及上課作業辦法 — 全國法規資料庫](https://law.moj.gov.tw/LawClass/LawAll.aspx?pcode=S0110022)
- [bobby1030/tw-nds-cli](https://github.com/bobby1030/tw-nds-cli) — HTML scraping precedent
- [ruyut/TaiwanCalendar](https://github.com/ruyut/TaiwanCalendar) — office-calendar JSON mirror
