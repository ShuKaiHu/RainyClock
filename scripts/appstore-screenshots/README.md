# App Store screenshot compositor

Turns real 1320 × 2868 simulator captures into the framed App Store screenshots first made
for 1.8.1 (`docs/appstore-1.8.1-screenshots/`). The style is "Quiet Navy": the navy canvas
`#1A2433 → #0F1624` with the widget's 10% cyan `#6EE3FD` glow in the bottom-left corner,
left-aligned copy on a 120 px axis that the panel edge shares, and a frameless rounded panel
that bleeds off the bottom. There is deliberately no drawn iPhone: Apple's marketing
guidelines ask for its own bezels unmodified, and a frameless panel is simpler. On top of
that it has:

- One headline size for the whole set, at weight 500.
- Film grain on the canvas.
- An optional tint per frame.
- A callout held inside a band.
- Hard failures in place of warnings.

It needs Node 22+, Google Chrome and macOS `sips`, and no npm packages. `chrome-profile/`
and `.work/` are created next to the scripts and are gitignored.

## Usage

From the repo root, regenerating the 1.8.1 set:

```bash
node scripts/appstore-screenshots/compose.mjs docs/appstore-1.8.1-screenshots/spec-zh-Hant.json /tmp/shots
node scripts/appstore-screenshots/compose.mjs docs/appstore-1.8.1-screenshots/spec-en.json /tmp/shots
node scripts/appstore-screenshots/sheet.mjs docs/appstore-1.8.1-screenshots/spec-zh-Hant.json /tmp/shots
```

Output is `<out>/<lang>-<id>.png` (+ `.jpg`); the files in `docs/` are those PNGs renamed to
`<id>.png` inside a per-language folder. A relative `screenshot` path in a spec is resolved
against the spec file's folder.

Options:
- `compose.mjs … --only 01-rain,04-typhoon` renders only those frames. Every frame is still
  measured, so the set-wide size and panel top come out the same as in a full run. A full
  run records them in `<out>/<lang>-set.json`; when an `--only` run comes out different (the
  edited copy moved the set's size or panel top), it warns that the frames it left alone
  are now stale and the whole set needs rendering again.
- `--weight 400|500|600` overrides the headline weight. It was used for the weight test below.
- `sheet.mjs --files a.png b.png … --out x.png [--width 420] [--no-labels]` builds a sheet
  from any list of frames.

**Exit codes:**
- `compose.mjs` exits 0 when every frame passed. It exits 1 when any frame failed, or when
  Chrome or `sips` failed.
- A frame that fails gets **no file**, and any `.png` or `.jpg` left for it by an earlier run
  is deleted, so a stale image can't be mistaken for a fresh one.
- The frames that passed are still written.

### Output

The output goes to `<out>/<lang>-<id>.png` and `.jpg`. `<lang>` is `zh-Hant` or `en`, or the
spec's `prefix` if it has one.
- **PNG:** 1320 × 2868, 8-bit RGB (colour type 2) with **no alpha channel**, plus an `sRGB`
  chunk. Chrome's screenshot is re-encoded by `png.mjs`.
- **JPEG:** made by `sips` at quality 100, with the sRGB profile.

In the 1.8.1 set sizes are 1.9–3.0 MB for the PNG and 2.1–3.1 MB for the JPEG. The grain is
why they are not smaller.

A frame takes about 4 s to render, or about 7 s for the home-screen capture, because its PNG
is large. A six-frame set takes about 30 s.

### How a run works

Chrome runs one job at a time, and a spec is processed in three stages:

1. **Measure:** one page holds the copy of every frame.
   - It picks each headline's line break.
   - It finds the set-wide headline size: the largest size at which the widest line in the
     set fits the 1080 px measure, clamped to the language's range.
   - It breaks the sublines and footnotes.
2. **Verify:** one page holds every frame's final copy block, placed exactly as it will be on
   the canvas.
   - Every line is fixed by now; nothing wraps on its own.
   - This stage measures each block's height and the width of every line.
   - The panel top for the whole set and all per-frame checks follow from these numbers.
3. **Render:** one screenshot for each frame that passed, then the PNG re-encode and the
   `sips` JPEG.

Intermediate files go in `.work/<prefix>/`: `measure.html`, `verify.html`, one HTML file per
frame, and `grain.png`. The Chrome profile is `chrome-profile/` in this folder.

Chrome is run the way that works on this Mac (see `chrome.mjs`):
- Flags: `--headless=new --force-color-profile=srgb --force-device-scale-factor=1`, its own
  `--user-data-dir`.
- stdout and stderr go to files.
- A screenshot run is done when Chrome prints `bytes written`. A DOM dump is done when the
  output ends in `</html>`.
- After that comes a short grace period, and then the whole process group is killed. Headless
  Chrome here often never exits on its own.
- Any run still going after 60 s is killed and reported as an error.

## Spec format

The format:

```json
{
  "lang": "zh-Hant",
  "panelTop": 860,
  "frames": [
    {
      "id": "01-rain",
      "headline": "下雨天，早點叫你",
      "highlight": "早點",
      "subline": "通勤路線可能下雨時，鬧鐘提早響",
      "screenshot": "/abs/path/01-alarm.png",
      "tag": "訂閱或買斷",
      "footnote": "台灣與美國假日",
      "tint": "#3B2963",
      "callout": { "x": 60, "y": 374, "w": 1200, "h": 490, "radius": 84,
                   "band": { "top": 330, "bottom": 896 } },
      "panelCrop": { "top": 0, "bottom": 0 }
    }
  ]
}
```

### Top-level fields

| field | meaning |
| --- | --- |
| `lang` | `zh-Hant` (anything starting with `zh`) or `en`. |
| `panelTop` | Optional. Sets the panel top for the whole set and replaces the automatic value. The checks still apply to it. |
| `prefix` | Optional (from A). Replaces the `<lang>` in filenames. |
| `headlineWeight` | Optional. Replaces the chosen weight, 500. Only for experiments. |

### Frame fields

**Copy**

| field | meaning |
| --- | --- |
| `headline` | Breaks automatically into two lines; the rules are under "Line breaking". `\n` or `\|` forces the break. |
| `highlight` | One substring of the headline, shown in `#6EE3FD`. It may span the line break. You get a warning if it isn't found. |
| `subline` | One line if it fits. Otherwise two lines: at the clause mark that gives the most even pair, as long as the shorter line keeps 45% (en) / 30% (zh) of the longer; failing that, at the word (en) or character (zh, with kinsoku and no split Latin runs) that gives the most even pair; en avoids ending line 1 on "a" or "I". Only if no two-line split fits does Chrome wrap it, which then fails. `\n` forces a break. The limit is 2 lines. |
| `tag` | Shown as a pill. It never wraps and never shrinks. |
| `footnote` | Shown on the tag's row if it fits there. Otherwise it gets its own row under the tag and breaks like the subline. |
| `keepBreakPunct` | zh only. Keeps the ，or 、 at a headline line break, which is dropped by default. |

In `en`, all copy gets typographic quotes, so `Taiwan's` becomes `Taiwan’s` and `"x"` becomes
`“x”`.

**Capture and panel**

| field | meaning |
| --- | --- |
| `screenshot` | A path to a PNG that is **exactly 1320 × 2868**, absolute or relative to the spec file. |
| `panelCrop` | `{top, bottom}` in capture px. `bottom > 0` ends the panel above the canvas edge, so its bottom corners are rounded. |

**Tint and callout**

| field | meaning |
| --- | --- |
| `tint` | Optional. A hex colour for one extra glow in the top-right corner. Use it only on the rain hero (`#3B2963`) and perhaps the typhoon frame; every other frame stays plain navy. |
| `tintStrength` | Optional, default 0.16, clamped to 0.14–0.18. |
| `callout` | Optional; at most one per frame. `x, y, w, h` is the source rectangle in capture px. |
| `callout.band` | **Required.** The free rows around the source, in capture px: from just below the UI above it to just above the UI below it. `{top, bottom}` or `[top, bottom]`. |
| `callout.radius` | The source element's own corner radius in capture px. Default 84, the alarm card. The rule card is 72. |
| `callout.scale` | Optional; caps the enlargement. |
| `callout.nudge` | Optional, `{x, y}` in capture px. Moves the callout before it is clamped. |

To find a callout's rectangle and band, use these tools:
- `node tools/textrows.mjs capture.png y0 y1 [threshold]` prints the rows that contain ink.
- `node tools/inspect.mjs capture.png [row] [col]` prints the non-black row runs, plus a probe
  of a single row or column.

You can measure a card's corner radius by probing a few rows just inside its top edge.

### Line breaking (headline)

**Chinese (zh)**
1. Break after the strongest mark present: 。？！；： first, then ，, then 、.
2. If that mark occurs more than once, use the one nearest the middle.
3. Use a break only if both lines keep **two real characters**. So 「好，早點起床吧」 does not
   break at its comma.
4. With no usable mark, try every break point that orphans nothing, and keep the one whose
   longer line is narrowest when measured.
5. A ，or 、 left at the end of a line is dropped. A ，、。：； in the middle of a line has its
   side bearings trimmed by −0.2em each. A ？or ！ that ends a line has its leading side
   bearing trimmed by −0.2em: TW forms centre it, which left 「想休息一天？」 with a gap
   before the mark over twice the normal one.

**English (en)**
1. Break after `.?!`, then `;:`, then `,`, then a standalone `—`, at the occurrence nearest the
   middle.
2. With none, pick the break between words that gives the narrowest longer line. For example,
   "Holidays / stay quiet." and "Weather along / your commute.".

## Hard failures (exit 1, no file for that frame)

| check | rule | example message |
| --- | --- | --- |
| headline overflow | A line is wider than 1080 px even at the minimum size. That frame fails on its own and does not set the size, just as a broken frame does not set the panel top; the other frames render at the size they will have once it is fixed. (A line that fits somewhere between min and max still sets the size for the whole set, as intended.) | `headline line 1 "…" overflows by 536 px even at the minimum 132px (the set stays at 160px)` |
| subline overflow | It needs more than 2 lines, or a line is wider than 1080. | `subline overflows: it needs 3 lines (max 2)` |
| zh orphan | In a multi-line headline, subline or footnote, a line has at most one real character (punctuation is not counted). | `subline line 2 「間」 orphans a single character` |
| copy-to-panel gap | The copy block ends less than **90 px** above the panel. | `copy ends 69 px above the panel (min gap 90); cut 21 px of copy` |
| wrapped tag | The pill would need more than 1080 px, or it measures taller than one line. | `tag "…" does not fit on one line (1179 px of 1080)` |
| capture visible | Less than **85%** of the capture's 2868 rows is on the canvas. | `only 79.1% of the capture's height is visible (min 85%)` |
| capture size | The capture is not exactly 1320 × 2868, is missing, or is not a PNG. | `capture is 1320x2860, must be exactly 1320x2868` |
| callout band | The callout would cross its band. This happens when the band can't hold even a 1.05× enlargement, when the band does not contain the source rows, or when the band is missing. | `callout crosses its band: it can only grow 1.020x (limited by band), min 1.05x` |

Warnings only:
- The highlight is not in the headline.
- The footnote runs to more than 2 lines.
- More than 2 frames carry a tint.
- The set has more than one callout per three frames.
- The headline has no break point.

## Every size (canvas px, 1320 × 2868)

### Canvas

| element | value |
| --- | --- |
| Base | `linear-gradient(180deg, #1A2433 0%, #0F1624 100%)` |
| Brand glow | `radial-gradient(circle 1188px at 0% 100%, rgba(110,227,253,.10) → 0)` (0.9 × width) |
| Tint (optional) | `radial-gradient(circle 900px at 100% 0%)`. The peak α defaults to **0.16** and is clamped to 0.14–0.18; the rain hero uses 0.18. It falls off smoothly: α×1 at 0%, ×.72 at 30%, ×.33 at 60%, ×.08 at 85%, 0 at 100%. At the corner, #3B2963 at 0.16 adds about +5 R and +7 B to the navy. |
| Film grain | A 512 px tile of Gaussian noise: mean 128, σ = **4.5%** of full scale (11.5 levels), seeded so every run is identical. `mix-blend-mode: overlay` at full opacity. Mid-grey adds no tone, and the noise is monochrome. It sits **under the copy, panel and callout**, so only the canvas carries it. Measured σ on the canvas is 2.3–2.8 (R), 3.0–3.4 (G) and 4.4–5.1 (B) levels. Inside the panel it is 0.00. |

### Grid

| element | value |
| --- | --- |
| Margins | 120 left and right. The copy's left edge equals the panel's left edge. |
| Copy top | **150**, the top of the first headline line box. Ink starts at y ≈ 171 (zh) or 178 (en cap height). |
| Optical alignment | Headline zh `-0.06em`, en `-0.045em`; subline zh `-0.06em`. Han side bearings would otherwise put the ink 9–12 px inside the panel edge. The ink now starts at x 121–123, and a W hangs 3 px. |
| Panel | 1080 wide at x 120, so capture × **0.8182**. Radius **81** (7.5% of width). 1.5 px inner stroke at 13% white. Shadow `0 50 140 rgba(3,7,14,.55), 0 12 40 rgba(3,7,14,.35)`. It bleeds off the bottom. |
| Panel top | One value per set: `clamp(ceil(tallest sound copy block bottom + 100), 800, 873)`, or the spec's `panelTop`. "Sound" means a frame whose copy passed, so a broken frame can't push the whole set down. 800 keeps the 1.7 captures' tab bar (row 2569+) below the fold. 873 is the lowest top that still shows 85% of the capture. |
| 1.8.1 set | zh **800**, en **802** (88% of each capture visible). |

### Type

The family is `system-ui, BlinkMacSystemFont, "PingFang TC", sans-serif`. This gives SF Pro
with automatic optical sizes, and PingFang TC for Han characters. `lang="zh-Hant"` selects the
Traditional glyph forms. Text colour is `#F4F7FB` and the highlight is `#6EE3FD`.

**Headline**

| | zh-Hant | en |
| --- | --- | --- |
| Size | **132–160 px**, one size per set (1.8.1: **151**) | **112–140 px**, one size per set (1.8.1: **140**) |
| Weight | **500** (PingFang TC Medium) | **500** (SF Pro Medium) |
| Line-height | **1.18** (189 px at 160) | **1.08** (151 px at 140) |
| Tracking | +0.02em | −0.02em |

**Subline** (weight 400, `rgba(226,234,246,.72)` ≈ 72% white, measure 1080, at most 2 lines)

| | zh-Hant | en |
| --- | --- | --- |
| Size | **46 px** | **48 px** |
| Line-height | 1.42 | 1.30 |
| Tracking | +0.04em | −0.004em |
| Top margin | 0.20 × headline size (32 px) | 0.22 × headline size (31 px) |

**Meta row** (30 px below the subline)

| element | value |
| --- | --- |
| Tag pill | Height 64, radius 32, padding 0 28. Text **36 px** weight 500 in **`#6EE3FD`**, tracking zh +0.04em / en +0.005em. Fill `rgba(110,227,253,.10)`, 2 px inset stroke at .42. `white-space: nowrap; flex: none`, so it never wraps or shrinks. |
| Footnote | **34 px** weight 400, line-height 1.36, `rgba(226,234,246,.60)` ≈ 60% white. Tracking zh +0.03em / en 0. It sits 22 px after the tag on the same row when it fits. Otherwise it gets its own row 14 px below the tag. |

### Callout

| element | value |
| --- | --- |
| Scale | k is the smallest of: 1.3 · `callout.scale` · band height ÷ source height · (1080 + 2·40) ÷ (source width × 0.8182). It is relative to the panel scale, so it is 0.86–1.06 of the capture's own pixels. Below **1.05×** the frame fails. |
| Placement | Centred on its source, then clamped into the band vertically. Horizontally it is clamped so the overhang past either panel edge is **≤ 40 px**. |
| Look | Corner radius = `callout.radius` × 0.8182 × k, the crop's own radius. Shadow: `0 36 90 rgba(0,0,0,.6), 0 10 28 rgba(0,0,0,.4)`. Same 1.5 px stroke as the panel. |
| 1.8.1 values | **Alarm card** (60, 368, 1200 × 612, r 84, band 330–1010) and **Time card** (60, 518, 1200 × 470, r 72, band 485–1018), both capped at `scale` 1.1, so each is exactly the panel's 1080 px wide: flush with its edges rather than a 4–5 px overhang that read as misregistration. |

## Headline weight: 500, and why

Both languages were rendered at 400, 500 and 600 on the same frames, full size and scaled
as with `sips -Z 640`:

- **400** is the most elegant at full size, but at 640 px its strokes thin to about 2 px. The
  cyan highlight word then loses most of its pull.
- **600** is punchy at 640 px, but at 160 px it fills the counters of dense Han characters
  (響, 鬧, 鐘). In English at −0.02em the letters crowd ("Wake up").
- **500** keeps the counters open at 160 px, and it still reads as a bold headline at 640 px. It is chosen for both languages so the
  two localisations match.

## Gotchas worth knowing

- **Chrome ignores `-apple-system`; that name only works in WebKit.** A stack that starts with it
  renders English in PingFang TC's Latin glyphs. The stack now starts with `system-ui`, which is SF Pro in Chrome. A pixel test
  confirmed that PingFang renders identical TC glyph forms under `lang="zh-Hant"` either way.
- Every line is fixed before the final page is built. Measurement and render therefore can't
  disagree, and the checks run on exactly the copy that gets rendered.

## Files

| path | contents |
| --- | --- |
| `compose.mjs` | The compositor. |
| `creative/generate.mjs`, `creative/scene.js` | The iOS 27 header and search-results assets, "rain on glass at blue hour"; see the last section. |
| `sheet.mjs` | The review overview: frames about 420 px wide, 24 px gap, `#26272B` background, id labels. A missing (failed) frame shows as a dashed "failed" slot. |
| `chrome.mjs` | The headless Chrome runner with kill-after-write. |
| `png.mjs` | A dependency-free PNG codec (opaque RGB output, plus `encodeGray` for the grain tile). |
| `tools/textrows.mjs`, `tools/inspect.mjs` | Measure captures to find callout rects, bands and radii. |
| `tools/crop.mjs` | A 1:1 crop, for checking type at full size. |
| `tools/stack.mjs` | Stacks the same crop from several frames, for comparisons. |

## Known limits

- The panel top follows the set's tallest copy, so one frame with a tag plus a footnote on its
  own row pushes every panel down (to at most 873, the 85% floor). Shorten that footnote so it
  fits beside the tag, or pin `panelTop`.
- At 160 px, a zh frame has room for a one-line subline plus a meta row with the footnote on
  its own row, or a two-line subline plus the tag with the footnote beside it. A two-line
  subline plus a footnote on its own row fails the 90 px gap, as it should.
- When a zh subline or footnote has no usable clause mark, the two-line split falls on an
  ICU word boundary (`Intl.Segmenter`). ICU's dictionary misses some compounds, e.g. it
  splits 停班 into 停|班, so check the break or force it with `\n`.

## Creative assets (iOS 27): `creative/generate.mjs`

"Rain on glass at blue hour": a city street at dawn seen through a rain-covered, fogged window;
the type sits in a patch wiped clear by hand. `scene.js` paints the art on a canvas in headless
Chrome (no image files, one seeded generator); `generate.mjs` lays the type over it in Inter and
Noto Sans TC, measures every key box against Apple's safe rect, renders, and re-encodes opaque
RGB through `png.mjs`.

```bash
node scripts/appstore-screenshots/creative/generate.mjs                 # all four, then review/
node scripts/appstore-screenshots/creative/generate.mjs --only header-en --no-review
```

**Output:** `docs/appstore-1.8.1-screenshots/creative/`
- `header-<lang>.png` (3840 × 1646) and `search-<lang>.png` (3840 × 2560).
- `review/`: `mock-product-<lang>` (the header under an iPhone's status bar and back/share
  buttons, crop x 320..3520), `mock-search-<lang>` (the search asset at 370 pt under its result
  row), and `sheet`.

**Hard failures** (no file, stale one removed, exit 1):
- Before rendering: a character that neither OFL face maps (checked against the fonts' own
  `cmap` tables, so it is exactly what a system font would draw; the run prints which face
  draws each line); type outside the safe rect; a header line under 11 pt on an iPhone; a
  search headline under 150 px; the phone's rim outside the safe rect horizontally or above
  its top, or its alarm card outside it vertically; less than 100 px between copy and phone.
- After rendering, read back from the PNG: more than 1% of pixels in the page colour
  `#0A0F2C` (scene.js threw and the canvas never painted); under 2,000 px of type ink in any
  wordmark or headline box (the fonts arrived after Chrome's virtual-time budget and the type
  stayed hidden). Real lines have 16,000 px and up; the art alone has 0–1.
- A PNG over 8 MB also exits 1.
- `generate.mjs` refuses to start if the fonts' sha256 is not the pinned one (`fetch-fonts.sh`
  downloads from google/fonts commit `e1d6480`, not `main`).

The search screen is the real `raw/*-01-rain.png`, untouched, 1092 px wide: the largest that keeps
the rim's top at y 765, Apple's safe top, so a crop to the safe rect keeps the screen's corners
and its status bar. It bleeds off the bottom at capture row 2150, just under the Weather
attribution, so none of the app's empty black shows.

File size is set by texture, not grain. The search asset is ~7.5 MB with no grain at all, and
10 MB with grain at amplitude 1.5. So the search asset has no grain, the header has a trace
(1.5), and the search asset has fewer condensation beads (`micro`). Current sizes: headers
7.49 MB, search 7.54 (zh-Hant) and 7.60 MB (en).

Two runs give byte-identical PNGs (store assets and review files), from any cwd and checkout
path, as of Chrome 154.0.8037.98 and the pinned fonts. Chrome updates itself, and a new build can
change the bytes and, through glyph metrics, the measured boxes; each run prints the Chrome
version and warns when it is not that one. Chrome's profile lives in the OS temp dir, and the
page HTML in `.work/creative-rain/`.
