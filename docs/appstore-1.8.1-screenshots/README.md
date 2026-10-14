# 1.8.1（42）商店截圖

製作日期：2026-10-09。16 張成品（繁中 8、英文 8），每張 1320 × 2868、RGB PNG、沒有透明色版，放在
App Store Connect 的 **iPhone 6.9 吋**組。檔名前的數字就是上傳順序。

**2026-10-10 已上傳並讀回**（擁有者：「我們就上傳app store吧」，用擁有者已登入的 Chrome）：先在 ASC 新增 iOS 版本 **1.8.1**
（準備提交；從 1.8.0 複製資料，未選建置版本、未貼 What's New、未送審），再到媒體管理的「配備『動態島』的 iPhone（大型顯示器）」
兩個語系各移除 1.7.0 留下的 6 張、依序上傳這 8 張。重新整理後讀回：繁中、英文（美國）各 8 張且順序正確；必填的中型顯示器
（6.1／6.3 吋）與 6.5 吋（配備 Face ID 的大型顯示器）都是「使用現有素材」沿用這 8 張，沒有自己的舊圖。商店描述未改。

**2026-10-10 改用開源授權字型重新產生並替換 ASC 1.8.1 上的版本**（Inter＋Noto Sans TC，OFL；Apple 的 SF 字型授權只涵蓋介面示意圖）。版面不變；英文 08 的副標因 Inter 較寬改成 "Home or work district closed? That alarm is skipped."。兩個語系重新上傳後讀回 8 張、順序正確。

整組風格是「Quiet Navy」：深海軍藍底（取自 widget 無天氣時的天空與 App icon），標題靠左，App 畫面以無邊框
圓角面板呈現。**刻意不畫手機外框**：Apple 行銷規範要求外框只能用官方素材且不可修改，無邊框面板較簡單也較安全。
標題字型用 OFL 的 Inter 與 Noto Sans TC（`scripts/appstore-screenshots/fetch-fonts.sh` 下載）。付費功能標「訂閱或買斷」／“Subscription or one-time purchase”（2.3.2），畫面上沒有價格（2.3.7），標題不含 Apple 商標。

總覽：[`overview/zh-Hant-sheet.png`](overview/zh-Hant-sheet.png)、[`overview/en-sheet.png`](overview/en-sheet.png)。

## 每張畫面

| # | 繁中（`zh-Hant/`） | 英文（`en-US/`） | 畫面 |
| --- | --- | --- | --- |
| 1 | 01-rain 下雨天，早點叫你 | 01-rain Rain ahead? Wake up earlier | 鬧鐘頁：明天 7:30 因路線降雨提早到 7:00，天氣卡住家下雨／公司多雲 |
| 2 | 02-typhoon 颱風假，就多睡一會（訂閱或買斷） | 02-rule 40% rain chance? 30 min earlier | 繁中：停班停課地圖**示範畫面**；英文：設定 › 時間 |
| 3 | 03-rule 降雨達 40%，提早 30 分鐘 | 03-widget Next alarm, at a glance | 繁中：設定 › 時間；英文：主畫面 widget |
| 4 | 04-widget 下次鬧鐘，主畫面就看得到 | 04-route Built around your commute | 繁中：主畫面中型＋小型 widget（註：小工具需 iOS 26 以上）；英文：路線預覽 |
| 5 | 05-route 從家到公司，怎麼去你決定 | 05-skip Day off? Skip the next one | 繁中：路線預覽（宜蘭 → 台北 101，開車 45–47 分）；英文：鬧鐘開關 |
| 6 | 06-skip 想休息一天？只關下一次 | 06-calendar Holidays stay quiet（付費） | 繁中：鬧鐘開關「僅關閉下一次鬧鐘」；英文：11 月月曆（退伍軍人節、感恩節不響，27 日手動改不響） |
| 7 | 07-calendar 國定假日，鬧鐘不響（訂閱或買斷） | 07-voice Wake up to your own words | 繁中：12 月月曆（12/25 不響，12/31 手動改不響）；英文：AI 人聲 |
| 8 | 08-voice 想聽什麼，寫下來就好 | 08-typhoon Typhoon day off? Sleep in（付費） | 繁中：AI 人聲；英文：停班停課地圖示範畫面（註：Taiwan only · Demo screen） |

繁中把颱風放第 2 張（台灣的主要賣點，搜尋結果看得到前 3 張）；英文放最後，因為美國使用者用不到。

## 拍攝來源（全部是 App 真實狀態，沒有假資料或修圖）

- App：本 repo `3fbccba` 的 Debug 建置，`com.shukaihu.RainyClock` 1.8.1（42），已簽章（widget 需要 App Group），
  LevelPlay key 在建置後的 bundle 裡清空。模擬器：獨立新建的「RainyClock 1.8.1 Store」iPhone 17 Pro Max／iOS 26.5
  （`EC2659DB-B408-4D7C-ADD3-93D93A52115D`）。狀態列以 `simctl status_bar` 固定為 9:41、滿格、電池 100% 未充電。
- **雨天首圖是 2026-10-09 晚間（約 22:58–23:05）Apple Weather 對 10/10 早上的真實預報**：住家宜蘭幾米廣場（英文版
  選 Yilan Station，同一地點）降雨 42%（英文版那次抓到 41%），公司台北 101 降雨 18%。降雨門檻在 App 內設為 **40%**，所以鬧鐘
  真的從 7:30 提早到 7:00；設定那張顯示的就是同一個 40%。原本規劃的基隆，Apple 給的機率不到門檻，而且 Apple Maps
  回報基隆路段 BLOCKED_ROADS，所以改用宜蘭。widget 在 App 進背景時取得同一份決定。
- 付費畫面（月曆）用既有的 `-membership-sandbox-test`（不設 sandbox URL，會員未設定，付費 UI 可操作），所以圖上一律標
  「訂閱或買斷」。這不是付費權益的驗收。
- 停班停課地圖是 App 內「設定 › 日曆 › 查看地圖示範」的真實畫面；橘色「示範資料・非即時公告」保留不裁，並加註
  「實際以各縣市政府公告為準」（DAYOFF-SPEC §7）。示範資料寫死的住家／目的地（新北市新店區／臺北市信義區）在面板
  底部完整露出，與其他張的宜蘭／台北 101 不同，這是示範畫面本身的內容。
- AI 人聲只輸入文字、選聲音，**沒有按「產生」**，沒有呼叫語音後端或用掉免費次數。鬧鐘開關的對話框拍完後點旁邊關掉，
  沒有真的關鬧鐘。
- 主畫面 widget 用 IconState.plist 放置（見記憶筆記），桌布是 iOS 26 預設桌布的深色版（`simctl ui … appearance dark`），
  主畫面除了雨天鬧鐘只有系統 Safari／訊息。

## 已知的取捨

- **首圖日期是 10/10 週六（國慶日）**，同一組裡有「國定假日，鬧鐘不響」。首圖當下日曆規則是關的（免費方案的狀態），
  所以響鈴是真實行為；月曆那張改用 12 月避免同框出現 10/10。擁有者 10/9 選擇用當天的真實雨天預報拍，不等平日下雨。
  若要消除，等某個平日早上宜蘭／基隆真的有雨時重拍 01、04（widget）、06（開關）三張即可，其餘不動。
- 截圖裡 App 的字串是「路線降雨機率 42%，**提前** 30 分鐘」，和設定的「**提早**時間」用字不一。1.8.1 已把這行與其他看得到的
  繁中字串改成「提早」（2026-10-10，擁有者決定），所以首圖和搜尋結果素材裡的手機畫面比實際 App 舊一個字；不重拍（見 STATUS-IOS 10-10 那一點）。
- 設定 › 時間只有七列，面板下方約四分之一是 App 本身的黑底，沒有用裁切或拼貼掩蓋。

## iOS 27 標題與搜尋結果素材（`creative/`）

2026-10-10 製作，擁有者選的方向是 D1「窗上雨滴」：清晨藍調時分隔著起霧、滿是雨滴的車窗看街景，文字放在用手抹開的那一塊。
**2026-10-10 已放上 ASC 的 1.8.1 版本並讀回**（擁有者：跟 1.8.1 一起送審、不做 A/B 測試），兩個語系各一張標題、一張搜尋結果；
用 ASC 的裝置預覽看過 iPhone 產品頁、iPhone 搜尋結果與 iPhone Duo 產品頁，字標都沒被按鈕或鏡頭擋到。
這些素材只在 iOS 27 以上顯示；搜尋結果素材在搜尋結果裡取代前三張截圖。

| 檔案 | 尺寸 | 內容 | SHA-256（前 16 碼） |
| --- | --- | --- | --- |
| creative/header-zh-Hant.png | 3840 × 1646 | 「雨天鬧鐘」＋ RAINY CLOCK | 4034fc7f979574a4 |
| creative/header-en.png | 3840 × 1646 | RAINY CLOCK | 03371268bb3b67ce |
| creative/search-zh-Hant.png | 3840 × 2560 | 下雨天 早點叫你／通勤路線會下雨，鬧鐘就提早響＋01 首圖的真實鬧鐘畫面 | 9696d40f4cf5e319 |
| creative/search-en.png | 3840 × 2560 | Rain ahead? Wake up earlier. / Rain on your commute route moves your alarm up.＋同一張英文擷取 | 9708f6f3def4e6bf |

全部是不透明 RGB PNG、每張 8 MB 以下；文字與手機畫面都在 Apple Sketch 樣板的安全範圍內（搜尋結果的手機上緣剛好貼齊
安全範圍上緣 y 765，狀態列不會被裁）。手機畫面是 `raw/` 裡 01 首圖的原始擷取，沒有修改。`creative/review/` 是示意：
`mock-product-*`（產品頁上方的標題裁切，非官方的 iPhone 裁切範圍 x 330–3530，左右上角壓著返回／分享按鈕）、
`mock-search-*`（搜尋結果列）、`sheet.png`（四張總覽）。實際的 iPhone 標題裁切比示意圖窄，以 ASC 預覽為準。

重新產生：`node scripts/appstore-screenshots/creative/generate.mjs`（說明在該資料夾上層的 README 最後一節）。兩次執行輸出逐位元組相同。

## 重新產生

`raw/` 是 16 張原始擷取，`spec-zh-Hant.json`／`spec-en.json` 是文案與排版設定，排版工具在
[`scripts/appstore-screenshots/`](../../scripts/appstore-screenshots/README.md)（Node 22＋Chrome，無 npm 套件）。
改文案後在 repo 根目錄執行：

```bash
node scripts/appstore-screenshots/compose.mjs docs/appstore-1.8.1-screenshots/spec-zh-Hant.json /tmp/rc-shots
```

輸出在 `/tmp/rc-shots/zh-Hant-<id>.png`，再改名放回 `zh-Hant/<id>.png`。工具遇到文字溢出、斷字、付費標籤換行、
畫面可見範圍低於 85% 等情況會直接失敗、不產出檔案。以目前的 spec 重跑，輸出與這裡的 PNG 逐位元組相同（10/9 驗證）。

## 檢查

三個獨立審查（文案、App Store 規範與真實性、視覺）各自找問題，每個問題再由另一個 agent 嘗試推翻；確認的 17 項中，
已修：英文 AI 人聲原本是空白輸入框（重拍）、主畫面改深色桌布、颱風與 AI 人聲面板底部切到半行字、兩個放大卡片邊緣
對不齊、四句文案（en-02、en-08、zh-05、兩語系 AI 人聲註腳改說「廣告」）。未修的就是上一節列的取捨。

| 檔案 | SHA-256（前 16 碼） |
| --- | --- |
| zh-Hant/01-rain.png | d47f0c5819b944ab |
| zh-Hant/02-typhoon.png | 074e0d959882b7b6 |
| zh-Hant/03-rule.png | d45c6f1b314ee70a |
| zh-Hant/04-widget.png | 18daff0186046fb5 |
| zh-Hant/05-route.png | e2cbe8c743592288 |
| zh-Hant/06-skip.png | 6e7aca7bbad18d74 |
| zh-Hant/07-calendar.png | 9f61c5a71d9b0ee6 |
| zh-Hant/08-voice.png | 6550455ab566e0fc |
| en-US/01-rain.png | caed408e8fa772a9 |
| en-US/02-rule.png | 5d25d763882e877a |
| en-US/03-widget.png | e8370257fd8dce38 |
| en-US/04-route.png | 258887f7470bb0dd |
| en-US/05-skip.png | c7c85a2275273f10 |
| en-US/06-calendar.png | 18477def0775a2c0 |
| en-US/07-voice.png | eaf751637cbc02b6 |
| en-US/08-typhoon.png | b8baa6bc63c2b920 |
