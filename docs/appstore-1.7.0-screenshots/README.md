# 1.7.0（30）商店截圖準備

拍攝日期：2026-09-21，拍攝版本為 1.7.0（30）。這批圖片是當時 iOS 程式在獨立模擬器實際操作後的原生截圖，未改寫 UI、合成天氣或偽造會員。使用者已於當日晚間手動上傳原始 PNG，補齊 IAP 審查圖及商品，並將 1.7.0（34）與相關項目提交審查。圖片上傳或提交成功不代表購買、會員後端或響鈴已驗收。

## 最新素材狀態 — 2026-09-23

- 1.7.0（34）因 6.5 吋截圖、地點搜尋及 ATT 退審；修正版 35 已可內部 TestFlight 測試，尚未重新提交 App Review。
- 使用者清理後，**繁中 6.5 吋已顯示「使用 6.9 吋顯示器的檔案」**，繼承六張新版真實 App UI。使用者截圖及另開 ASC 頁讀回均確認；灰色圖是繼承預覽，變更已保存，媒體管理頁沒有另一個待按的儲存按鈕。
- **英文（美國）6.5 吋本次清理結果尚未核對。** 下方 E2/E1/E3 是 9/21 的舊紀錄，不代表目前仍有或已移除；需讀回才能結案。
- 媒體管理：[iPhone 各尺寸](https://appstoreconnect.apple.com/apps/6780500386/distribution/ios/version/inflight/media-manager/iphone)。退審詳情見 [9/23 報告](../APP-REVIEW-2026-09-23.md)，完整交接見 [9/23 交接](../HANDOFF-IOS-2026-09-23.md)。

## 提交歷史 — 2026-09-21

- 使用者提供的提交前截圖列出四個項目：**iOS App 1.7.0（build 34）**、**RainyClock Plus 訂閱群組**、**One-Time Purchase**、**Plus Monthly**；沒有年訂閱。
- 使用者後續提供 ASC **「已提交 4 個項目」**成功畫面。據此記錄：使用者已手動補齊 IAP 審查圖／加入兩商品，並完成這四項的審查提交；先前缺圖與缺同組月訂閱的提交阻擋已排除。
- 以上證據來自使用者截圖，**不代表 Apple 已核准、審查通過或公開上架**；本次沒有由代理操作 ASC，也沒有程式、建置或測試變更。
- 6.5 吋舊圖是否已清理、審查聯絡電話／Email 的最終內容，本次都未重新核對；不以提交成功當作這些內容已確認正確的證據。

## 上傳核對與補件過程 — 2026-09-21 晚間歷史

- **iPhone 6.9 吋／繁體中文：**已讀回 `01-alarm`、`02-time`、`03b-route-collapsed`、`03-route`、`04-calendar-settings`、`05-alarm-calendar`，共六張，依此順序。
- **iPhone 6.9 吋／英文（美國）：**已讀回相同六張；前四張順序相同，最後依序為 `05-alarm-calendar`、`04-calendar-settings`。
- 實際上傳的是 `en-US/`、`zh-Hant/` 的原始 PNG，不是 `upload/` 中另存的 JPEG；下方保留兩種檔案的來源與輸出說明。
- **iPhone 6.5 吋最後讀回時仍是舊圖**：繁中 `C1/C2/C3`、英文 `E2/E1/E3`。後續未重新核對，不能解讀為所有裝置尺寸都已換圖。
- 補件前，月訂閱及買斷按「加入審查」均曾回覆「你必須為審查資訊新增截圖。」商店展示圖不能替代商品的審查圖欄；這項缺件已由使用者後續補齊。
- App 最初加入 2026-09-21 22:23 建立的審查提交草稿，當時尚未正式提交，並保留手動發佈。一般審查說明已保存 [build 34 版本](../appstore-review-notes-1.7.0-34.txt)，明示 Local StoreKit 截圖不是台灣售價驗證。
- 同一草稿最初只有 App 1.7.0（34）及 `RainyClock Plus` 訂閱群組兩項，曾被「新的訂閱群組須與該群組內的自動續訂型訂閱項目一同提交。」阻擋。之後使用者加入月訂閱與買斷並完成四項提交；年訂閱未加入。

## 可供 ASC 使用的畫面

商店展示用 JPEG 在 `upload/en-US/` 與 `upload/zh-Hant/`，各 6 張，共 12 張。每張 **1320 × 2868**，直式、無透明色版；由對應原生 PNG 等尺寸輸出，未裁切或加入宣傳字。原始 PNG 保存在 `en-US/`、`zh-Hant/`。

`manifest.json` 記錄這 12 張商店展示圖與另行保存的 2 張審查圖的用途、來源、尺寸、SHA-256 及與來源 PNG 的平均像素誤差；已逐張檢查輸出尺寸與無透明色版。各原生畫面完成目視檢查後才輸出 JPEG。最終 JPEG 使用 RGB、quality 100、無色度取樣壓縮及無縮放；逐張比對來源確定沒有缺失文字／介面元件。

這個尺寸屬於 Apple 支援的 iPhone 6.9 吋截圖規格；請放在對應裝置尺寸組，不放進 6.5 吋組。依據：[Apple 截圖規格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)。

| 檔名（兩語系皆有） | 畫面與建議用途 |
| --- | --- |
| `01-alarm.jpg` | 明日預計 7:30 響鈴、住家／公司皆晴天與降雨 0%，資料實際由 WeatherKit 取得，保留 Apple Weather 標示 |
| `02-time.jpg` | 時間設定：起床時間、提早時間、降雨門檻，以及兩種響鈴設定 |
| `03-route.jpg` | 路線設定與 Apple Maps 實際路線；英文／繁中公開地標名稱不同，導航距離亦可能不同 |
| `03b-route-collapsed.jpg` | 路線預覽收合，作為可選補充圖 |
| `04-calendar-settings.jpg` | 英文選美國、繁中選台灣，顯示各來源設定 |
| `05-alarm-calendar.jpg` | 2026 年 10 月月曆；週一至週五重複，15 日手動改成不響並顯示橘點 |

建議依首頁、時間、路線、月曆排列；收合路線及日曆來源畫面可視需要增補。首頁和英文收合路線中的台北公開地標保留使用者輸入的中文名稱，不代表 App 語系沒有切換。

## 僅供 IAP 審查的圖片

`review/en-US/06-membership-plans-local-storekit.jpg` 與 `review/zh-Hant/06-membership-plans-local-storekit.jpg` 為既有 **RainyClock Membership Local** scheme 的實際畫面；同目錄保留原始 PNG。兩張皆顯示免費方案、月訂閱、買斷、各自權益和選擇方案按鈕，並保留橘色「StoreKit 本機測試」提示。

這兩張可作為 IAP 審查的功能位置說明，不放入上述商店展示組。本機設定的美元商品為月 $1、買斷 $10；繁中畫面的美元價格 **不是台灣商店價格驗收**。沒有執行購買、產生正式會員／額度或驗證真正 Sandbox／TestFlight 交易。提交時須向審查者清楚說明這是本機 StoreKit 擷取，正式價格由 App Store 提供。

## 拍攝來源與範圍

- App：`com.shukaihu.RainyClock`，實際 bundle 版本已確認 **1.7.0（30）**。
- 模擬器：iPhone 17 Pro Max／iOS 26.2，名稱 `RainyClock 1.7.0 Store Screenshots`，UDID `AF4E3FE5-B4CB-4878-BE80-CE4A7EC50E5C`。全新獨立資料容器，未使用既有真機或會員資料。
- 使用目前 source 的 Debug 建置，建置記錄 `/tmp/rainyclock-170-screenshot-build-20260921.log`；build succeeded。未變更原始碼或版本。
- 首頁與會員圖後續改由 Xcode 的既有 **RainyClock Membership Local** scheme 實際啟動，重新確認安裝版本仍為 **1.7.0（30）**。透過正常 UI 確認台北車站／台北 101 兩地址，並允許此獨立模擬器排程／通知後，首頁顯示預計 7:30。Xcode console 記錄明天 2026-09-22 07:00 的 WeatherKit sample 為 `clear`／`precipitation=0`，非 `-weather-scene-preview` 或合成快取。
- 已存在的 `-membership-sandbox-test` 啟動選項搭配未設定 Sandbox URL：不連會員服務，依既有「會員未配置」行為可操作日曆。這只用於擷取現有付費日曆 UI，**不是付費權益驗收，也不表示免費方案可以使用日曆**。
- 模擬器原有程式會禁止正式廣告 SDK 初始化；本次沒有請求或觀看正式／測試廣告，沒有產生或發放 AI 額度。
- 範例地點為臺北車站／Taipei Main Station、台北 101／Taipei 101 等公開地標，透過正常 UI 輸入；不是使用者住家／公司地址。地圖來自實際 Apple Maps，保留 Apple Maps 法律標示。
- 設定頁以 `-AppleLanguages '(en)' -AppleLocale en_US` 與 `-AppleLanguages '(zh-Hant)' -AppleLocale zh_TW` 切換語系；後續 Xcode 本機 StoreKit 啟動由截圖專用模擬器語系切換，最終留下英文／en_US。狀態列時間使用模擬器的 9:41 顯示設定。
- 日曆畫面使用既有台灣／美國假日規則；沒有臨時放假、年訂閱或舊三次免費文案。

## 不可當成正式商店圖片的參考

`reference/` 不要直接上傳：

- `zh-Hant-alarm-weather-unavailable.png`：最初自行建置／啟動時 WeatherKit 無法取得預報的歷史診斷圖，日誌為 `com.apple.weatherkit.authservice` XPC connection failure／`NSCocoaErrorDomain Code=4097`。之後以 Xcode 正常啟動已成功取回預報並補齊兩語系正式首頁；沒有用假快取覆蓋此問題。
- `en-US-weather-sample-only.png`、`zh-Hant-weather-sample-only.png`：現有 `-weather-scene-preview -weather-home clear -weather-work rain` harness，畫面明示 sample data。它只有天氣卡，沒有完整明日鬧鐘卡及正式導航，不能取代完整首頁截圖。
- `native-simulator-capture-check.png`：以 Simulator 原生「Save Screen」交叉確認截圖方式的診斷圖，未列入上傳組。

## 仍需補齊

1. 真正 Sandbox／TestFlight 購買、到期、退款、會員認回、AI 與廣告端到端驗收仍由對應測試流程完成；截圖不代替交易或服務驗收。
2. 6.9 吋中英文商店圖已上傳並核對；9/23 繁中 6.5 吋已確認繼承新版，英文 6.5 吋仍待核對。兩商品曾與 App／訂閱群組完成四項提交，但 34 已退審；35 尚未重送。審查聯絡欄位最終內容未重新核對，不將上傳／提交成功記成核准或公開發布。

復現擷取使用 `xcrun simctl io <UDID> screenshot --type=png --mask=ignored <路徑>`，拍攝前確認畫面與字形完成渲染。PNG 的透明色版由平台輸出，供 ASC 使用的 JPEG 以同尺寸另存，不改畫面內容。所有最後圖片均須以檔案本身目視確認，不能只看模擬器視窗。
