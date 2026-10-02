# Rainy Clock — iOS status & backlog

Living handoff document for the **iPhone app**. Read this first when picking iOS back up;
update it when something ships, gets blocked, or gets discovered.

The Android port keeps its own log in `docs/STATUS-ANDROID.md`. Keep the two apart: they ship
on different schedules and are often worked on at the same time, and a shared file means two
sessions writing over each other. Anything true of both platforms goes in `docs/STATUS.md`.

- Submission mechanics, rejection history, AdMob and app-ads.txt setup → `docs/app-store-submission-checklist.md`
- Store copy, release notes, review notes → `docs/appstore-metadata.md`
- Product reasoning and rejected alternatives (both platforms) → `docs/PRODUCT_DECISIONS.md`

Last updated: 2026-10-02.

> **1.7.1（37）已上架：2026-09-26 05:33 UTC（台灣 13:33）**，台灣與美國商店的 App Store lookup 都回 1.7.1。
> 這是 1.7.0（34）退審後的重送版，包含會員方案（月訂閱、買斷）、LevelPlay 廣告、地址建議清單修復。
> **上架後待確認（正式環境第一次有資料）：**
> 1. 用台灣 Apple 帳號從 App Store 安裝，會員頁卡片應為 NT$10／月、NT$100（9/23 的正式版價格檢查）。
> 2. 正式會員服務（production App Attest、Production Apple 交易）第一筆真實購買與恢復購買。
> 3. LevelPlay 正式廣告流量、ATT 同意率與 Organizer／Crashes 的 1.7.1 崩潰。

> **颱風／臨時放假改定 1.8.0（2026-09-24）**，1.7.1 另作他用。下方較早紀錄裡指這項功能的「1.7.1」
> 保留原文，一律讀成 1.8.0；現況見「1.8.0 準備中」一節。
>
> **1.8.0（39）= 颱風停班停課 ＋ 鬧鐘總開關 ＋ 主畫面／鎖定畫面「下次鬧鐘」widget**（39 比 38 多了中型 widget
> 今天的項目也顯示天氣，超過 3 小時的預報寫「預報時間」、不警告，2026-10-02）。38 已上傳 TestFlight（10/2，擁有者手機測試完成，widget 天氣是那時發現的）；**39 已於 10/2 08:27 上傳**，08:50 前後在 App Store Connect 改選 build 39、審查說明第一行改成 (39) 並儲存（讀回正確；仍未送審）。
> **1.8.0（40）已於 2026-10-03 00:14 送審，狀態「等待審查」**（發佈方式：手動）。40 比 39 多：停班停課輪詢改每 30 分鐘、App 的
> 公告新鮮度上限改 1 小時；小型 widget 的天空和中型一樣跟著預報，並帶  Weather 標記。10/2 21:44 上傳，10/3 00:1x 在 App Store
> Connect 改選 build 40、審查備註整份換成 (40) 版。見「1.8.0 準備中」最上方幾點。
> `ios/widget`（worktree `RainyClock-widget`，`ad0b628`）已於 **2026-10-01** 依擁有者決定以合併 commit 合入
> 1.8.0 線。合併時統一的規則見「1.8.0 準備中」的「`ios/widget` 合入 1.8.0 線」一點，
> 送審前欠項見同一點與該節末的 widget 小節。

> **1.7.1（37）已重新送審，正在等待審查（2026-09-25 00:10 提交，4 個項目：App、訂閱群組、月訂閱、買斷）。**
> 發佈方式維持「手動發佈」。以下為送審準備紀錄。
>
> **1.7.1（37）送審準備（2026-09-24／25）：** ASC 版本已改 1.7.1 並選 build 37；使用者 9/24 23:55 已回覆
> App Review（附 ATT 實機錄影 `.mov`）；審查備註已換成 [1.7.1 版](appstore-review-notes-1.7.1-37.txt)（3,966 字，
> 刪除價格限制段、加入 ATT 與地址測試步驟）並讀回確認；6.5 吋截圖兩語系皆用 6.9 吋實際畫面。
> 9/25 使用者已把同一支錄影上傳到 App 審查資訊「附件」並讀回；備註再修正為 3,981 字（加「Allow Apps to Request to
> Track」提示、SDK 等追蹤決定、列名 Membership、價格句）並讀回。使用者按「更新審查內容」與「重新提交至 App 審查」，ASC 讀回「等待審查」。
>
> 1.7.1（37）已上傳 TestFlight（2026-09-24 15:00:13）： 修正 1.7.0 起 Home／Work 輸入時完全沒有地址建議，
> 以及手動輸入的地址被藏在 sheet 裡的黃色確認擋住、首頁一直「No alarm set」。見下節。
>
> **1.7.0（36）已上傳 TestFlight（2026-09-24 12:49:53），尚未送審：** 修正重裝後會員永久卡住（App Attest），
> 以及 iOS 27 TestFlight 價格被整批擋下。見下節。9/23 的「App 不改」結論已被本節取代。

## 1.7.1（37）：地址建議清單修復、手動輸入不再被隱藏確認擋住 — 2026-09-24

- 使用者錄 2.1(a) 影片時發現：在 Home／Work sheet 輸入地址，下方完全不出現建議。iOS 26.5 模擬器
  也重現，所以不是 iOS 27 問題；Apple 的 `MKLocalSearchCompleter` 本身有回結果（macOS 探測
  「Taipei main st」6 筆、「Taipei 101」7 筆）。
- **根因：** 1.7.0 把地址欄搬進 `.sheet`，但 `@FocusState`、completer 與清單狀態仍屬於外層
  `RouteTabView`。外層的 FocusState 看不到 sheet 裡的欄位，永遠是 nil，每打一個字就清空
  completer，清單永遠不顯示；自動聚焦也因此失效。1.3–1.6 欄位在同一個 view，所以正常。
- **連帶問題：** 手動輸入的地址（清單壞了，每個人都走這條路）一律產生「實際使用地址／確認使用」，
  它會擋住排程（`canSchedule`），但 1.7.0 只在 sheet 裡顯示，首頁只剩「No alarm set」。
  審查員手動輸入 Taipei Main Station／Taipei 101 也會卡在這裡。
- **修正：**
  - 新的 `AddressEditor` 在 sheet 內自己持有 focus、completer 與清單狀態，清單跟著打字出現，
    先顯示「搜尋建議中」，查不到時顯示「找不到符合的地點，按『搜尋』可直接使用輸入內容」。
  - 點建議：存成已確認地址與座標，關閉 sheet，跑路線預覽。英文標題保留英文名稱
    （原本會因 Apple 中文副標題被改成中文街道地址）。
  - 按「搜尋」：只有一筆同名建議且沒有門牌號碼時直接選它；有多筆（例如兩個「Taipei 101」）
    就收起鍵盤讓使用者選；沒有建議就用輸入文字（審查員的路徑）。
  - Apple 精確比對到同名（只差大小寫、全半形、重音、臺/台、空白、標點）、沒有門牌號碼、
    2 公里外也沒有同名地點時，靜默確認並存座標；連鎖店名、門牌地址等其他情況照舊要求確認。
  - Route 頁的 Home／Work 列在待確認時顯示黃色三角形、找不到時顯示紅色標記。
  - 快速打字被 Apple 節流時保留舊清單並重試一次；注音組字中不閃「找不到」；
    關閉後重開的舊查詢不會蓋掉新的選擇。
- 模擬器（iOS 26.5，空白 LevelPlay key）實測：英文與中文介面都出現建議；點「Taipei Main Station」
  與「台北車站」各自保留原名稱；兩筆「Taipei 101」按搜尋會保留清單；Work 打字後關閉即自動確認，
  App 直接要求鬧鐘權限並排出 7:30 鬧鐘；亂打的地址顯示紅色標記與「找不到這個地址」。
- 完整 **395 項測試通過、0 失敗、0 跳過**（新增 8 項，更新 3 項）。xcresult：
  `DerivedData/Logs/Test/Test-RainyClock Membership Local-2026.09.24_14-07-57-+0800.xcresult`。
  三個 reviewer 的 4 個已確認問題（連鎖店名靜默確認、關閉重開的舊查詢、節流、重啟測試太弱）都已修正。
- 版本改為 **1.7.1（37）**：Info.plist 與 11 處 `MARKETING_VERSION`／`CURRENT_PROJECT_VERSION`。
  颱風停班停課已由另一個 session 改排 1.8.0（`ef40eab`）。App Store Connect 的版本頁仍是 1.7.0，
  送審前要改成 1.7.1 或新增 1.7.1 版本。
- **隱私：** 使用者 9/24 13:11 的地址錄影在 5–6 秒，鍵盤 QuickType 列露出通訊錄裡的真實住址
  （`.textContentType(.fullStreetAddress)` 的自動填入）。這支影片不要原樣交給 Apple，影格也不要放進公開 repo。
- 已提交 `380eedf`。Release archive `build/RainyClock-1.7.1-37.xcarchive`：App 與兩個 extension 皆為
  1.7.1（37），App Attest `production`、正式會員 URL、正式 LevelPlay key、沒有 `.storekit`，新字串在
  en／zh-Hant 皆有。**15:00:13 上傳成功**，Apple 處理中；IronSource dSYM 警告照舊。日誌
  `/tmp/rainyclock-171-37/archive.log`、`upload.log`。**尚未送審**；使用者將在 1.7.1 上重錄 ATT／地址影片。

## 1.7.0（36）準備：重裝後會員卡死、iOS 27 價格被擋 — 2026-09-24

- 使用者把 iPhone 16 Pro 升到 **iOS 27.0**，**刪除後重裝** TestFlight 1.7.0（35）錄 ATT 影片時，
  會員頁出現 `attest-assertion · com.apple.devicecheck.error/2 · store=TWN · currency=unknown`，
  以及「Could not update App Store prices」，方案沒有價格、無法選擇。ATT 在會員啟動前執行，
  影片本身可用，但會員頁不要入鏡。
- **App Attest：App 缺陷，已修。** Keychain 項目（ThisDeviceOnly）在刪除 App 後仍會保留
  `attestKeyID`／`attestedKeyID`／session，但 Secure Enclave 的 key 不會。重裝後
  `generateAssertion` 回傳 `invalidInput`（code 2），舊程式只在 `invalidKey`（3）時換 key，
  結果啟動、同步、恢復購買、購買（購買前會先同步）、AI 與刪除會員全部永久卡住，再刪除重裝也
  無效。正式版任何重裝的會員都會遇到，審查員刪掉 34 改裝 35 也會。Cloud Run 同時段只有
  `/challenge 200`、沒有 `/session`，符合裝置端就失敗的判斷。
  - 依據：Apple〈Establishing your app's integrity〉：key 不跨重裝、移機或備份還原。
    firebase-ios-sdk #12629、#11264 與 google/app-check PR #54：前一個安裝留下的 key 會回 `invalidInput`。
  - 修正：`MembershipDeviceProof.isUnusableLocalKey` 把 `invalidInput`／`invalidKey` 視為本機 key
    不可用；bootstrap 的單次重試會換新 key 並重新 attest（另含已存 key 的 assertion 回
    `unknownSystemFailure`，同 Google AppCheckCore 做法）。沿用 session 時若 key 不可用，
    `MembershipIdentitySynchronization.run` 與 `start()` 會清掉 session 再 bootstrap 一次。
    啟動時遇到伺服器 `invalid_session` 仍不自動 bootstrap，避免重建在另一台手機刪除的會員。
    新 key 仍需新鮮的 Apple proof 加 Apple attestation；後端未改。
- **價格：iOS 27 只修一半。** 價格檢查頁顯示 `iOS 27.0`、`1.7.0 (35)`、StoreKit 2 商店前後都是
  TWN，StoreKit 1 商品卻是 `$1.00`／`$10.00 [USD]`，方案卡 unavailable。這是 9/23 預測的第三種
  結果：Apple 修好了 Storefront，TestFlight 商品仍回美國目錄，舊的幣別一致性檢查把整批商品拒絕，
  等於隱藏價格又擋住購買。
  - 使用者決定寫死價格文字，實作採混合版：
    - Apple 商品幣別與商店一致時，照 `Product.displayPrice` 顯示。這是正式版的常態，ASC 改價不必改 App。
    - 最後一次查詢時商店穩定、商品為單一幣別但與商店不同時，仍採用 Apple 的商品，卡片改顯示該商店
      寫死的價格 `MembershipListedPrice`：TWN 是 NT$10／NT$100，USA 是 $1.00／$10.00；其他商店照 Apple 值。
    - 混合幣別或查詢途中換商店，仍然拒絕。
    - 購買仍使用 Apple 的 `Product`，實收以付款頁為準。**ASC 改價時必須同步修改 `MembershipListedPrice`。**
- 後端：9/23 06:37–06:40 UTC 有一台 Darwin/27.0.0 裝置用 build 34 取得 `/session 200`，之後多次
  `/status 200`，表示 iOS 27 的 assertion 能通過現有的 37-byte 檢查，後端不需要改。
- Build 號 35 → 36（Info.plist 與 11 處 `CURRENT_PROJECT_VERSION`），marketing version 仍是 1.7.0。
- 測試：簽章的 `RainyClock Membership Local` scheme、iOS 26.2 模擬器，完整 **387 項通過、0 失敗、
  0 跳過**（新增 12 項，改名或取代 2 項）。xcresult：
  `DerivedData/Logs/Test/Test-RainyClock Membership Local-2026.09.24_12-17-03-+0800.xcresult`。
- 已提交 `91f331a`（只含本次檔案，疊在另一個 session 的 dayoff-service commit 之上）。Release archive
  `build/RainyClock-1.7.0-36.xcarchive`：App 與兩個 extension 皆為 1.7.0（36），App Attest `production`，
  正式會員 URL，沒有打包 `.storekit`。**2026-09-24 12:49:53 上傳成功**，Apple 處理中；IronSource dSYM
  警告照舊，不影響上傳。日誌：`/tmp/rainyclock-170-36/archive.log`、`upload.log`。**尚未送審。**
- **真機驗收 1 已通過（13:00，iOS 27.0，35 原地更新到 36、未刪除 App）：** 會員頁直接正常，會員編號不變，
  沒有「Showing last verified status」與錯誤診斷；卡片顯示 NT$10／月、NT$100，Choose plan 可按。
  Cloud Run（UTC）：05:00:31 `/challenge`（舊 key 在手機端失敗）→ 05:00:35 `/challenge` → 05:00:38
  `/session 200`（新 key attest 成功）→ 05:00:46、05:00:56 `/status 200`（iOS 27 一般請求的 assertion 通過）。
- **真機驗收 2 已通過：** Apple 原生付款頁月訂閱為 **NT$10.00 per month**、買斷為 **NT$100.00 One-time
  charge**，與方案卡一致，並標示測試不收費；兩者都只開啟付款頁、未確認購買。9/21 起的「卡片 USD／付款 TWD」
  問題在 iOS 27＋36 上已不再出現。尚待：刪除後重裝 36、ATT 影片。重送前，build 34 審查備註的
  「KNOWN PRICE DISPLAY LIMITATION」段落應刪除。
- 36 上傳後的真機驗收，只用 TestFlight，不要用 Xcode Debug 覆蓋：
  1. 在卡住的手機把 35 原地更新到 36。啟動後不應再出現 attest-assertion。若 AppTransaction 太舊，
     可能先看到「Tap Refresh membership」或 `session · MembershipHTTP/401`；點同步後應恢復，會員編號不變。
  2. 方案卡應顯示 NT$10／NT$100，Choose plan 能打開 Apple 付款頁（可以取消，不必購買）。
  3. 刪除後重裝 36，第一次開啟就應正常。

## 商品卡美元／付款頁台幣：結案 — 2026-09-23（已被上節取代）

- **9/24 更新：** 下方的剩餘檢查 1 在 iOS 27 上出現了第三種結果，「App 不改」已由 1.7.0（36）取代，見上節。
- **結論：Apple TestFlight 的 StoreKit 缺陷，不是 App 缺陷；依使用者指示不修。** 信心高。
- Apple 官方：[iOS & iPadOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)
  StoreKit → **Resolved Issues**：「Fixed: `Storefront` API might return incorrect metadata when
  running in the TestFlight environment. (181766819) (FB23646993)」。本日由三個獨立查核讀回
  Apple 文件 JSON 確認。Wayback 存檔顯示 beta 4 沒有、beta 6 起出現，從未列為 Known Issue；
  iOS 26.0–26.6 release notes 都沒有這一條。macOS 27 notes 有同一條、Xcode 27 沒有，推論是
  系統層修正：要把手機升到 iOS 27，重新 build App 無效。測試機 iOS 26.6.2 沒有這個修正。
- 同症狀的外部回報：Apple Developer Forums
  [844269](https://developer.apple.com/forums/thread/844269)（2026-09，storefront id 是日本、
  countryCode 卻是 USA）、[845478](https://developer.apple.com/forums/thread/845478)（2026-09，
  FRA/EUR 商店卻回 USD 商品）、[794932](https://developer.apple.com/forums/thread/794932)（iOS 26
  beta）。共同特徵：只在 TestFlight 發生，同機 dev build 正常，付款頁幣別正確。
  RevenueCat [sandbox 文件](https://www.revenuecat.com/docs/test-and-launch/sandbox/apple-app-store)
  也把「App 內 USD、付款頁當地幣別」列為已知的 TestFlight 狀況。
- App 程式：價格路徑沒有會造成此症狀的缺陷。`MembershipView.swift:196` 直接顯示
  `Text(product.displayPrice)`；購買用的是剛抓到、正顯示在卡片上的同一個 `Product`
  （`MembershipManager.swift:185`、`:201`、`:207`），只附 `appAccountToken`。StoreKit 的
  `PurchaseOption` 沒有能指定幣別或商店的選項，價格也沒有存到磁碟。卡片的 1／10 是美國價格點，
  不是台灣的 10／100 套錯符號，可見 metadata 整份來自美國目錄。同一段程式碼在 Debug Sandbox
  ＋台灣 Sandbox 帳號時顯示 NT$10／NT$100（9/21 19:22）。付款前沒有任何 StoreKit API
  能取得付款頁幣別。
- 正式版風險：低，但這是判斷，不是實測。正式安裝只有 Media & Purchases 一個帳號，
  商品 metadata 與付款頁同源。付款頁顯示的才是實際收費，購買前一定看得到。
  1.6.5 沒有 IAP，所以上架前無法用正式版驗證。
- **不採用**：`onStorefrontChange`（只在交易途中商店改變時觸發，對此症狀無效）、
  另出會記錄 Storefront.id 的診斷 build、後端存 storefront／currency，以及已否決的替代方案
  （寫死台幣、依語言／GPS、自選國家、舊交易價、隱藏價格）。
- 剩餘檢查都不需要改程式：
  1. 手機升到 iOS 27 後（ATT 錄影本來就要升），開 TestFlight 35 → 會員與方案，只看卡片、不購買。
     NT$10／NT$100 表示 Apple 的修正涵蓋價格；$1／$10 表示仍是 TestFlight 問題，一樣結案。
     若出現「暫時無法更新 App Store 價格」，表示 Apple 只修了 Storefront、商品仍回 USD，被
     `MembershipModels.swift:26-43` 的幣別一致性檢查擋下（`MembershipTests.swift:45` 鎖定此行為），
     只有這種情況需要使用者決定是否在 sandbox 放寬檢查。
  2. 1.7.0 上架後，用台灣帳號從 App Store 安裝，確認卡片為 NT$10／NT$100。若顯示 US$，重開此項。
- 重送 35 前：[build 34 審查備註](appstore-review-notes-1.7.0-34.txt) 的「KNOWN PRICE DISPLAY
  LIMITATION」段落主動寫了「not proof ... that production will be unaffected」，可能招來付費說明的
  提問，而審查裝置本來就在 iOS 27。建議刪掉，或改成一句事實陳述，措辭由使用者決定。
- 本次只查證與更新文件：未改程式、未建置、未上傳、未送審、未回報 Apple Feedback。

## 1.7.0（35）TestFlight 修正版 — 2026-09-23

- 使用者授權上傳修正版至 TestFlight。版本保持 1.7.0，App／widget／notification extension
  同步 build 35；本輪不重新提交 App Review、不公開發布。
- 包含下方地點搜尋與 ATT 修正，並額外處理 Organizer 取得的 build 34 真機閃退：
  9/22、iPhone 16 Pro／iOS 26.6.2，通知 didReceive 的 async Objective-C completion
  在 worker thread 觸發 UIKit assertion。改為明確 completion handler，於 MainActor
  完成 acknowledgement 後才回呼；新增五項背景入口／主執行緒／完成順序測試。
- 全套測試發現日曆及天災整合測試依賴共享會員快取，已在測試注入明確權益；正式會員
  gate 與 1.7.0 的 `supportsTemporaryClosures = false` 未改。
- iOS 26.5 的本機 StoreKit service 再次出現 configuration / Code 3，已改用既有
  iOS 26.2 乾淨專用 Simulator 與簽章 Local scheme，完整 **377 項通過、0 失敗、0 跳過**。
  包含實際 Local StoreKit 購買、恢復、續訂、到期、退款與待批准。舊測試裝置啟動停滯，
  改用隔離的 `RainyClock Release 35 Tests` 後正常；測試結束已關閉。
- Release archive 成功，App 與兩個 extension 均為 1.7.0（35），production App Attest、
  正式會員 URL、兩語系 ATT 文案、無 `.storekit` fixture 及簽章均已核對。
  **22:31:20 上傳成功**，Apple 已完成處理；內部 `SKHU tester`（1 人）可更新。
  build ID `c3ad05c5-0e2c-42b5-b7e9-01d605ffd677`。中英文測試說明已保存，
  ASC「已儲存」與群組 1 人均已讀回確認，沒有覆蓋使用者手機的 App。
  IronSource 第三方 dSYM 缺漏警告仍存在，未阻擋 upload/export。
  日誌：`/tmp/rainyclock-170-35/tests-final-passed.log`、`archive-release.log`、`upload.log`。
- 真機 iOS 27／iPad 流程與 ATT 錄影仍待完成。6.5 吋繁中已讀回使用 6.9 吋新版圖，
  英文（美國）尚未核對清理結果。先前 TestFlight 價格卡
  USD／付款 TWD 問題未確認解決；本輪沒有修改定價、後端或 1.7.1 開關。
- 詳細原因與限制見 [退審報告](APP-REVIEW-2026-09-23.md)，
  [build 35 測試說明](testflight-1.7.0-35.txt)。

## 1.7.0（34）退審 — 2026-09-23

- 使用者提供 Apple 訊息，submission `5a8a1d24-97da-4eb9-89a7-350274dccc85`：
  **2.3.3**（6.5 吋截圖多數未展示實際 App）、**2.1(a)**（找不到地點，核心功能無法使用）、
  **2.1 Information Needed**（找不到 ATT 提示，要求新安裝／重置權限的真機錄影）。
  裝置為 iPad Air 11-inch M3／iPhone 17 Pro Max，iPadOS／iOS 27.0，網路正常。
- 本機診斷確認：ATT 與 production-only 廣告開關及會員廣告身分綁定，Sandbox／TestFlight
  會一起跳過；ATT 因非 active 延後時，SDK 初始化亦未等待授權狀態確定。
  **使用者補充地址為 Taipei Main station／Taipei 101**；macOS 實際 Apple 查詢兩者皆成功，
  **尚未重現 iOS 27 案例**。但 MapKit 中文名稱會被現有英文比對拒絕，依賴額外英文反查救回；
  反查失敗與後續候選未被檢查是後續重現重點。固定台灣偏向不是本案例主要假設。
- 退審時的舊素材紀錄與 6.5 吋尺寸相符；9/23 使用者清理後，繁中已重新讀回繼承
  6.9 吋新版圖，英文（美國）尚未核對。詳見[截圖紀錄](appstore-1.7.0-screenshots/README.md)。
- 後續使用者提供審查截圖：明確失敗的是 **Home / Taipei Main Station**，Work 尚未解析。
  已修正 `MapItemResolver` 首筆不符就放棄整批候選的缺陷，並保留翻譯失敗前已匹配的名稱／座標。
  iOS 26.5 模擬器 50 項相關測試全過（含新增 8 項候選回歸）；macOS 實際 Apple 查詢两筆皆成功。
- ATT 程式已修正：同意流程獨立於會員身分與 production 廣告開關，TestFlight 也可顯示系統提示；
  GDPR sheet 實際關閉後才要求 ATT，`notDetermined` 時 SDK 保持關閉。拒絕／受限制不阻擋核心功能；
  模擬器／TestFlight 仍禁止正式廣告流量。新增 19 項同意流程測試，連同會員及鬧鐘排程共 54 項全過。
  隔離的 iPhone 17 Pro Max／iOS 26.5 模擬器亦實際驗到首開 ATT、拒絕後進入設定且重啟不重問、
  GDPR sheet 關閉後出現 ATT，再選允許回到首頁；仍不是 Apple 要求的真機影片。
- 詳見 [退審診斷與重送條件](APP-REVIEW-2026-09-23.md)。尚未重現／驗收 iOS 27 真機完整流程，
  ATT 真機錄影與英文 6.5 吋素材核對尚未完成；build 35 交付進度見上方最新紀錄。

## 1.8.0 準備中：颱風／天災臨時放假 — 2026-09-22（原標 1.7.1，2026-09-24 改）

- **2026-10-03 00:14：1.8.0（40）已送審，App Store Connect 顯示「等待審查」。** 擁有者在自己的 Chrome 登入後，由 Claude 操作：
  - TestFlight 頁讀到 build 40「準備提交」（已處理完成，在內部群組 SKHU tester）。
  - 1.8.0 版本頁：移除 build 39、選 build 40；審查備註整份換成
    [`appstore-review-notes-1.8.0-40.txt`](appstore-review-notes-1.8.0-40.txt)；儲存。重新載入後讀回：build 40；備註第一行
    `RAINY CLOCK 1.8.0 (40)`、3,996 字（檔案去掉結尾換行）、有 “small opens the app's Alarm tab”、沒有 “Only medium shows
    weather”；繁中 What's New 614 字；「需要登入」未勾；發佈方式「手動發佈此版本」；「立即向所有使用者發佈更新」（沒有階段性
    發佈）；「保留現有評分」。英文 What's New 這次沒有另外讀回（10/2 讀回過，之後沒動）。附件欄仍是空的。
  - 「新增以供審查」→ 提交項目草稿只有一項（iOS App 1.8.0，1.8.0 (40)）→「提交以供審查」→ 畫面「已提交 1 個項目」。
    App 審查頁讀回：今天上午 12:14、iOS 1.8.0、1 個項目、等待審查。沒有出現出口合規或其他問卷。
  - 新的 widget 句子：擁有者在看過訊息裡的全文後說「我覺得很好，開始 submit」，據此貼上。
  - 接下來：等審查結果（Apple 說最長 48 小時）。通過後不會自動上架；上架當天的事見下面「還沒做」與 9/28 的買斷價調整。
    等審查期間可補做：用 TestFlight 40 打開「使用臨時放假規則」，從伺服器端確認正式服務收到登記與抓取（臨時放假還沒在
    正式簽章的 build 上對正式服務跑過）。
- **2026-10-03 00:10：擁有者決定送審 1.8.0（40）；支援頁改正並上線；App Store Connect 的動作還沒開始（內建瀏覽器未登入）。**
  - 擁有者回報：TestFlight 40 的小型 widget 在手機上看過，OK（未逐項記錄 StandBy、著色／透明主畫面、官方標記圖）。
  - 上傳已確認成功：送審前檢查的一個代理讀到 `/tmp/rainyclock-180-40/export-check.log` 的 `Upload succeeded`（21:44:23）。
    App Store Connect 是否處理完、正式簽章後的 `aps-environment` 仍未讀回。
  - 送審前檢查（四個唯讀代理：ASC 步驟與商店資料、本紀錄的未完成事項、Release 設定、後端與公開頁面）沒有找到會擋送審的問題。
    要做的只有兩處：版本頁 build 39 → 40、審查備註整份換成 (40) 版；What's New、截圖、隱私問卷不用動，發佈方式維持手動。
    已告知擁有者、擁有者仍決定送審的風險：臨時放假從未在正式簽章的 build 上對正式服務跑過（正式服務收到的 App 請求只有
    TestFlight 38 的一筆 `DELETE /v1/devices`；可在等審查期間用 TestFlight 40 補做）；審查附件欄是空的（1.7.1 附了 ATT 錄影）；
    上架當天調買斷價時，`MembershipListedPrice` 的備用價格仍是 NT$100／US$10。
  - 支援頁（`docs/support.html`，App Store 上的支援網址）原本寫「App 沒有後端伺服器，也不需要建立帳號」，從 1.6.8 起就不成立。
    擁有者：「該改就改」。改寫後由三個獨立檢查者對照程式與隱私權政策逐句查證；第一版把會員列為「選用功能」被駁回（App 一開啟就
    自動連線會員服務、替沒購買的使用者建立免費會員），改成：地址不會傳到我們的服務、不用註冊表單與密碼、會員在開啟 App 時自動
    建立或辨識、AI 語音鬧鈴與臨時停班停課只在使用時連線。`126311e`（`ios/main`）與 `75ad278`（`main`，已 push）；00:09 讀回線上
    頁面：新文字在、舊句子不在、隱私權政策連結 200。查證同時確認：三個 iOS target 送往我們服務的請求都不含地址、座標、行政區或路線。
    查證另外指出、沒有改的：同一頁「升級到 iOS 26」那題仍叫使用者「重新排程一次」，1.8.0 已沒有那個按鈕（提醒上的按鈕是「重試」），
    App 內的提醒文字與隱私權政策第 105 行也還寫 Schedule Smart Alarm。
- **2026-10-02 21:41–21:45：1.8.0（40）已 archive，匯出指令回報成功（destination 是 upload）；App Store Connect 那一端還沒讀回。**
  從 `8e6228a`（21:40 commit）以 Xcode 27.0 Release archive：`build/RainyClock-1.8.0-40.xcarchive`，`CreationDate` 21:41。封存檢查：
  App 與兩個 extension 都是 1.8.0（40）、iOS 27 SDK、三個 bundle 都有隱私清單、App Group 在、App Attest `production`、
  `DayOffServiceURL` 是正式網址、只有 IronSource 一個框架、沒有 `GAD*`、App 與 widget 的執行檔裡都有 `rainyclock://alarm`。
  接著原本要做「本機匯出檢查」（看正式簽章後的 `aps-environment`），用的 `build/ExportOptions-AppStoreConnect.plist` 其實也是
  `destination = upload`，所以那一步就是上傳：`xcodebuild -exportArchive` 結束碼 0、印出 `** EXPORT SUCCEEDED **`。
  **沒有確認的：** 上傳日誌的內容（`/tmp/rainyclock-180-40/export-check.log`，之後讀取被權限分類器擋下，沒有讀到
  `Upload succeeded` 那一行）、正式簽章後的 `aps-environment`、App Store Connect 是否已處理完 build 40。
  **還沒做：** 在 App Store Connect／TestFlight 確認 40 出現並處理完成；版本頁的 build 由 39 換成 40；審查備註整份換成
  [`appstore-review-notes-1.8.0-40.txt`](appstore-review-notes-1.8.0-40.txt)（新的 widget 句子先給擁有者看過）；下一點列的手機檢查。
- **2026-10-02 晚：小型 widget 的天空和中型一樣跟著預報，並帶  Weather 標記（擁有者決定；併入 1.8.0（40），build 號不變，
  40 尚未 archive、尚未上傳）。** 擁有者把小型與中型並排放在主畫面（TestFlight 1.8.0（39），週末、預報晴天）：小型品牌深藍、
  中型亮藍，問「不是應該一樣嗎？」。四個選項裡選了「兩個都跟天氣，小型也帶標記」，取代 D-A（9/24）的「只有 medium 顯示天氣」。
  理由、Apple 的規定原文、否決的選項、放棄的東西與擁有者接受的審查風險見[產品決策](PRODUCT_DECISIONS.md)最上方。
  - 現在的行為：小型的背景和中型是同一片預報天空；沒有預報、「開啟 App 更新」、路線未完成時兩個都是品牌深藍。小型的**文字**
    沒改（只寫決定，不寫降雨機率與天氣名稱）。小型畫預報天空時，最下面一列是  Weather 標記；不畫就沒有。標記跟著
    `showsWidgetContainerBackground`：StandBy 沒有背景（Apple 文件），著色／透明主畫面預期也沒有（未驗證），那時小型沒有天空、
    也沒有標記。小型有 `widgetURL`（`rainyclock://alarm`）：點小型開 App 並切到鬧鐘頁，不管上次停在哪一頁（天氣卡的
    `WeatherAttributionView` 連到 Apple 法律頁）；中型的點按不變。標記本身是 `Link`，系統在 systemSmall 接受的話，點標記就和中型的天氣欄一樣
    經 App 開法律頁。有標記時小型的 VoiceOver 最後多念天空與標示（例：“Home Sunny, Work Rainy, Apple Weather”）。
  - 程式：`RainyClockAlarmWidget/TomorrowWidgetViews.swift`（小型的 `containerBackground` 改用 `presentation.home`／`work`；
    `SmallTomorrowView` 的 `showsWeatherMark`：`hasForecastSky` 且 `showsWidgetContainerBackground`，標記列 `layoutPriority(1)`，
    上面的內容包進可以讓出高度的內層 `VStack`；有標記時 `HeroTime` 不把上午／下午疊到數字上面，改成同一行、數字縮小；小型加
    `.widgetURL(TomorrowWidgetSnapshot.alarmTabURL)`）；`RainyClock/ContentView.swift`（`onOpenURL` 收到 `rainyclock://alarm`
    就選鬧鐘頁）；`RainyClock/Models/TomorrowWidgetSnapshot.swift`（`alarmTabURL`）；
    `RainyClock/Models/TomorrowWidgetPresentation.swift`（拿掉 `decisionSky`，新增
    `hasForecastSky` 與 `skyAccessibilityLabel`；`home`／`work` 的規則沒改）。只改註解：`TomorrowWidgetSky.swift`、
    `TomorrowWidgetSnapshot.swift`、`WeatherAttributionView.swift`、`RainyClockApp.swift`、`BackgroundWeatherRefresh.swift`、
    `TomorrowWidgetDemo.swift`（另改 DEBUG 範例畫面上的一個標題：「Medium  Weather row」→「Widget  Weather mark」，不進 Release）、
    `TomorrowWidgetSnapshotTests.swift`。沒有新字串，snapshot 版本仍是 4；中型、鎖定畫面三種與
    天空上的 legibility overlay 都沒動。
  - 測試：`TomorrowWidgetPresentationTests` 改 3 項（`testGlyphHeroAndLinePerScenario`、`testTodayChangesNothingOutsideTheMedium`，
    以及 `testNoWeatherDataOutsideTheMedium` 改名 `testNoWeatherTextOutsideTheMedium`）。四個 widget 測試類別共 73 項通過。
    完整測試（審查修正之後，`RainyClock Membership Local` scheme、已簽章、1 個 worker、排除 `MembershipStoreKitTests`）：
    iOS 26.5 與 27.0 各 **631 通過、0 失敗、4 略過**。
  - 模擬器畫面（把 widget 寫進 SpringBoard 的 `IconState.plist`，用 DEBUG 範例 `-widget-demo -widget-demo-scenario <name>
    -widget-demo-clock 12h -widget-demo-mark text`，**只看了文字標記**）：iPhone 17 Pro iOS 26.5 繁中 13 個情境（`weekend`、
    `normalClear`、`cloudyNormal`、`rainForecast`、`rainMixed`、`closure`、`ringPreviousDay`、`alarmOff`、`forecastUnavailable`、
    `weatherFailed`、`todayClosure`、`todayRain`、`routeIncomplete`）；iPhone SE（第 3 代）iOS 26.5 繁中與英文各 6 個
    （`normalClear`、`rainForecast`、`closure`、`ringPreviousDay`、`alarmOff`、`weatherFailed`）。每一個小型的天空都和中型相同、
    標記列完整、沒有東西被裁掉；沒有預報的項目兩個都是深藍，小型沒有標記。放不下時 SwiftUI 讓出高度的方式：縮小時間數字
    （`ringPreviousDay`），或欄底改用短字（`closure`：「停班停課略過」／“Work or school closed”，來源兩行都還在）。
    SE 繁中的 `normalClear` 那張被系統通知橫幅蓋住標題列，標題要看英文那張或下面的重拍。
  - 同晚審查（四個獨立審查者：版面、模型與測試、標示合規、文件）之後改的：(1) 第一版在 `ringPreviousDay` 把「下午」疊在數字
    上面，標題與標記被擠到內容邊界外（沒有裁掉，但進了邊距），12 小時制 10:00–12:59 的一般鬧鐘在 SE 上推算也會；改成有標記時
    不疊、同一行縮小數字，重拍 iPhone 17 Pro 繁中與 SE 英文的 `ringPreviousDay`、`normalClear`、`closure`，都在邊界內。
    (2) App 停在設定頁時點小型只會把 App 叫回前景、看不到標記與連結；加 `widgetURL` 切到鬧鐘頁。(3) 測試：把一條永遠成立的
    斷言換成對照輸入預報的斷言，補單一端點預報、兩種語言的 VoiceOver 文字、`alarmTabURL`。四個 widget 測試類別 74 項通過。
    審查另外指出、這次沒有處理的既有問題：晚間預覽與「鬧鐘已調整」通知的文字直接寫降雨機率而沒有 Apple Weather 標示；
    「因雨提早 N 分鐘」在沒有標記的面（StandBy、鎖定畫面）是否算 value-added（D-A 已記為殘餘風險）；鬧鐘頁在最小機型上
    標記是否不用捲動就看得到（要在裝置上看）。
  - **沒有驗證：** 小型上的 Apple 官方標記圖（要在裝置上連 WeatherKit）、StandBy、著色／透明主畫面、iOS 26 在 systemSmall 是否
    接受 `Link`、真機。
  - 還沒做：
    1. （已完成：完整測試結果見上。）
    2. 40 的 archive 與上傳，步驟同下一點「還沒做」第 1 項。
    3. 審查備註的 widget 句子「Only medium shows weather, with the Apple Weather mark; tapping it opens Apple's legal attribution
       page via the app.」不再成立。`appstore-review-notes-1.8.0-40.txt` 已在同一晚改寫成「Small (forecast background) and medium
       (weather column) show the Apple Weather mark. Tapping that column opens Apple's legal page via the app; small opens the
       app's Alarm tab, whose weather card links to it.」（3,997 字，仍在 4,000 以內；為了騰出字數，前一句拿掉 “It” 與
       “e.g. … or”；`appstore-metadata.md` 的 widget 段落也已同步）。**新句子貼上 App Store Connect 之前要擁有者看過。****App Store Connect 上仍是 (39) 版的舊句子**：40 上傳後整份重貼（不是只改第一行）並讀回。What's New 的「中型另外顯示
       住家與公司天氣」說的是天氣文字，照舊成立，不用重貼。
    4. 手機待確認（TestFlight 的 40）：小型與中型並排、全彩，天空相同、小型有標記；著色與透明主畫面（小型沒有天空也沒有標記）；
       StandBy；標記的官方圖與文字兩種狀態；停班停課的日子（短字、來源兩行、標記都在）；點小型的標記是開 Apple 法律頁，
       還是只開 App。

- **2026-10-02 18:27–18:31：停班停課輪詢改為每 30 分鐘、會員刪除改為每天兩次；App 的公告新鮮度上限 15 分鐘 → 1 小時，
  工作樹的 build 號改為 40（擁有者決定；40 尚未 archive、尚未上傳）。**
  - 原因（9 月帳單）：Cloud Run 用量 US$5.64、免費額度折抵 −US$4.62、實付 US$1.02，全部是 Cloud Run。Cloud Run **Job** 以
    instance 的整段生命週期計費、**每次最少 1 分鐘**（[定價](https://cloud.google.com/run/pricing)；asia-east1 每 vCPU-秒
    US$0.000018、每 GiB-秒 US$0.000002），實際只跑約 12 秒也算 60 秒，所以花費看的是執行**次數**：每月免費 240,000 vCPU-秒
    （帳單帳戶共用），約等於 4,000 次 1 vCPU 的執行，每天約 129 次。原本兩個 Scheduler 都是每 5 分鐘，合計每天 576 次，
    10 月整月會是約 US$15。`dayoff-service/DEPLOYMENT.md` 原本的估計（每月約 US$0.50）沒算到 1 分鐘下限。其他項目
    （Firestore 約 US$0.10／月、Secret Manager 約 US$0.08／月、Vertex／TTS 幾美分、Maps 0）可以忽略。
  - 雲端新設定（18:27–18:31 套用並從雲端讀回；沒有重新部署程式，映像 digest 不變）：
    - Scheduler `rainyclock-dayoff-poll`：`5,35 * * * *` Asia/Taipei（原 `*/5 * * * *`），每 30 分鐘、每天 48 次。選 :05／:35
      而不是 :00／:30：改之前 9 天僅有的兩次 `upstream_rate_limited` 都在整點（9/29 15:00、20:00）。最後一次 5 分鐘排程
      是 18:25，新排程第一次是 18:35。
    - Job `rainyclock-dayoff-poll`：`POLL_INTERVAL_MS=1800000`（原 300000）。
    - 服務 `rainyclock-dayoff`：`MAX_CACHE_AGE_MS=3600000`（原 900000），revision `rainyclock-dayoff-00006-j42`、100% 流量、
      `/health` 200。snapshot 超過 **1 小時**（連漏兩次輪詢）才回 503 `stale_cache`，原本是 15 分鐘。Sandbox 服務同值
      （`rainyclock-dayoff-sandbox-00002-4c8`）；sandbox 仍然沒有 Scheduler，所以手動跑 Job 之後 1 小時（原 15 分鐘）回 503。
    - 告警：「poll absent」改為 **2 小時**沒有 `dayoff_job` summary 才寄信（原 15 分鐘；擁有者：兩個小時沒反應再寄信，等於連漏
      四次輪詢；`alignmentPeriod` 維持 300s，預期最後一次 summary 後 2 小時又幾分鐘寄達）。「poll degraded」兩個條件的視窗改為 2 小時（原 20 分鐘），仍是「超過 2 次」，也就是連續 4 次裡 3 次。
      「execution failed」（10 分鐘視窗）和輪詢頻率無關，沒改。
    - Scheduler `rainyclock-membership-deletion`：`7 4,16 * * *` Asia/Taipei（原 `*/5 * * * *`），每天 04:07、16:07 兩次
      （擁有者：「這沒這麼重要」）。Job、環境變數與批次上限沒改；下一次是 10/3 04:07。
    - 現在每天 48 ＋ 2 ＝ 50 次執行，31 天約 93,000 vCPU-秒，在 240,000 的免費額度內：這個頻率下 Cloud Run Job 每月 US$0。
    - 程式的**預設值**（`POLL_INTERVAL_MS` 300000、`MAX_CACHE_AGE_MS` 900000）刻意沒動：正式與 sandbox 都明確設定這兩個值，
      也沒有重建映像。工作樹同步改了 `dayoff-service/deploy/deploy.sh`、`deploy/sandbox.sh`（sandbox Job 的
      `POLL_INTERVAL_MS=60000` 不變）與 `dayoff-service/alerts/` 的 absence、broadcast-incomplete 兩組告警檔。
  - 行為上的差別：公告出現在來源之後，推播最晚約 30 分鐘到手機（原約 5 分鐘）。輪詢失敗時服務仍然立刻回 503，直到下一次
    成功為止，這段時間現在通常約 30 分鐘（原 5 分鐘；退避上限等於排程間隔，連續失敗第 7 次起會變成每小時才抓一次，
    見 `dayoff-service/DEPLOYMENT.md` 運行手冊）；改之前 9 天約 2,400 次執行裡來源失敗 3 次。推播重試（APNs 429／5xx）
    與廣播最多 3 次的限制每次輪詢前進一步，現在每一步相隔 30 分鐘。App 其他規則不變：略過鬧鐘的判斷仍接受下載後 18 小時內
    的公告資料，App 自己的 5 分鐘更新節流也不變。
  - App：地圖與 sync receipt 的新鮮度上限由 15 分鐘改為 **1 小時**，共用常數 `DisasterMapStatus.maximumFeedAge`（`60 * 60`）。
    `DisasterMapView` 的來源標示與 `AlarmViewModel.reportDisasterSync` 原本各寫一個字面值（`900`、`15 * 60`），現在都讀這個常數。
    測試改在 `DisasterMapStatusTests`、`DisasterIntegrationTests`，新增 `testFeedFromThePreviousPollStillProducesReceipt`
    （31 分鐘前檢查的公告資料仍送出 receipt）。
  - 版本：build 39 → **40**（`Info.plist` 的 `CFBundleVersion` 與 11 個 `CURRENT_PROJECT_VERSION`；`MARKETING_VERSION` 仍是
    1.8.0）。模擬器上建置通過，完整測試（`RainyClock Membership Local` scheme、已簽章、1 個 worker，依慣例排除在 26.5 runtime
    會卡住的 `MembershipStoreKitTests`）：iOS 26.5 與 27.0 各 630 項通過、0 失敗、4 略過；`dayoff-service` `npm test` 111 通過、0 失敗、9 略過（Emulator 那組）。
    **1.8.0（40）尚未 archive、尚未上傳；App Store Connect
    選的仍是 build 39，TestFlight 上也還是 39。** 審查說明的 build 40 版已備好：
    [`appstore-review-notes-1.8.0-40.txt`](appstore-review-notes-1.8.0-40.txt)（只改第一行，3,916 字；內文沒有寫輪詢頻率或
    新鮮度時間，不用改）。（2026-10-02 晚：這份檔案又改了 widget 的天氣句子「Only medium shows weather…」（小型的天空），不再是
    「只改第一行，3,916 字」，見本節最上方一點。）
  - 還沒做：
    1. 40 的 archive 與上傳；上傳後 App Store Connect 改選 build 40，審查備註換成 (40) 版並讀回，`docs/appstore-metadata.md`
       指向審查備註檔與 build 的兩處也跟著改成 40。（2026-10-02 晚：指向審查備註檔的那一處已先改成 -40，上傳後只剩 build 的那一處。）
    2. absence 告警在 2 小時視窗下還沒重做「暫停 Scheduler」的端到端測試（9/24 那次測的是 15 分鐘視窗）。
    3. TestFlight 的 39 仍用 15 分鐘判斷：輪詢改成 30 分鐘後，地圖大約一半時間顯示「公告待更新」、行政區轉灰，下載到的資料
       超過 15 分鐘時也不送 sync receipt；略過鬧鐘的判斷不受影響（18 小時）。40 取代 39 之前都會這樣，不是壞了。
    4. 會員刪除新排程的第一次派送與 execution 還沒看到（下一次 10/3 04:07）；之後讀回 Scheduler `lastAttemptTime` 與該
       execution 的 summary。
    5. 新排程的前兩次停班停課輪詢已讀回（18:35 `d46j6`、19:05 `kczt5`，都是 `ok=true refreshed=true changed=false`）。

- **2026-10-02 08:27：1.8.0（39）已上傳 App Store Connect（只進 TestFlight，未送審）。** Xcode 27.0 從 `4e218c2` archive
  （`CreationDate` 08:24，晚於 08:22 的 commit）。本機 App Store 匯出檢查同 38：三個 bundle 都是 1.8.0（39）、iOS 27 SDK，正式推播／
  App Attest、三個 bundle 都有 App Group 與隱私清單、正式網址、只有 IronSource、`-ObjC` 在、widget 帶新字 `widget_forecast_as_of`。
  上傳前完整測試：iOS 26.5 與 27.0 各 633 項、0 失敗、4 略過（`26623f4`；之後 `4e218c2` 只改註解與文件，重新編譯通過）。
  **注意：** 這台 Mac 的 `xcode-select` 在 10/2 08:22 左右被切到 `/Library/Developer/CommandLineTools`（不是這個 session 改的），
  之後的建置以 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 執行；要恢復預設請擁有者執行
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`。審查說明的 build 39 版：
  [`appstore-review-notes-1.8.0-39.txt`](appstore-review-notes-1.8.0-39.txt)（只改第一行，3,916 字）。
  **App Store Connect（10/2 08:50 前後）：** 1.8.0 版本的 build 由 38 換成 39，審查備註換成 build 39 版並儲存，重新整理後讀回：build 39、
  備註第一行 (39)、3,916 字、What's New 不變；39 也已在內部測試群組 SKHU tester。仍未送審。
  擁有者 10/2 已用 TestFlight 38 跑完手機測試；39 只多中型 widget 今天的天氣欄，**手機待確認**：凌晨看中型，今天的天氣欄有天氣、
  超過 3 小時寫「預報時間 22:00」不帶警示、 Weather 標示在且點了開 Apple 的法律頁。

- **2026-10-02：中型 widget 今天的項目也顯示天氣（擁有者決定，隨 1.8.0（39））。** 擁有者 04:00 看到中型寫
  「Today · Fri, Oct 2 7:30 AM／Rings as usual」、沒有天氣。改為：從午夜到今天的鬧鐘響，中型也畫天氣欄（住家／公司
  天氣、降雨機率、天空）與  Weather 標記、法律頁連結；理由與否決的做法見[產品決策](PRODUCT_DECISIONS.md)最上方。
  - 程式：`TomorrowWidgetSnapshotBuilder` 不再丟掉今天的預報（`todayStatus` 本來就讀 App 唯一抓的那份「接下來的早上」
    預報，午夜後就是今天的；請求相等保證不會是別的早上的），今天的提示改走 widget 的 3 小時規則（`todayWeatherNotice`；
    原定時間過後沒有預報時不給提示）。`TomorrowWidgetPresentation`：新的 `Line.todayNotice` 與 `weatherColumnNotice`
    （天氣欄寫「今天」）；今天的項目有預報或提示才畫天氣欄（build 38 寫的今天項目沒有預報，提示也只有缺地址時的「請完成
    路線」：沒有提示的照 38 畫；帶「請完成路線」的畫天氣欄，和 39 自己寫的、明天的項目一樣，見下方審查修正）；`line` 與警示
    標記在今天的項目只帶「請完成路線」，所以小型、StandBy 與鎖定畫面不變（2026-10-02 晚起小型的天空改跟預報並帶標記，
    見本節最上方一點）。widget 天氣欄的頁尾與 VoiceOver 改讀
    `weatherColumnNotice`。抓取、背景工作、排程與主卡都沒改；snapshot 版本仍是 4。
  - 字串：共用鍵 +1 `ux_today_weather_failed`（今天天氣更新失敗，App 主卡已有）；widget 專用 +1
    `widget_today_weather_unavailable`——新字「尚未取得今天天氣」／“Today's forecast is not available yet”，**擁有者已核准
    （2026-10-02）**。範例（gallery／DEBUG `-widget-demo` 與 tour）加 `todayStale`、`todayWeatherFailed`、
    `todayForecastUnavailable`，今天的其他範例也帶預報。
  - 版本：build 38 → **39**（`Info.plist` 的 `CFBundleVersion` 與 11 個 `CURRENT_PROJECT_VERSION`；`MARKETING_VERSION`
    仍是 1.8.0）。App Store Connect：39 上傳後改選 build 39；審查備註第一行「RAINY CLOCK 1.8.0 (38)」改成 (39) 再貼一次
    （字數不變，3,916；[審查說明](appstore-review-notes-1.8.0-38.txt) 保留當時貼上的原文）。What's New 與審查備註的天氣句子
    本來就沒限定明天，照舊成立、不用重貼。（2026-10-02 晚改：審查備註的 widget 句子已不成立，40 要整份重貼，見本節最上方「小型 widget 的天空」一點。）
  - 測試（Xcode 27.0、簽章的 `RainyClock Membership Local`、`-parallel-testing-worker-count 1`、略過 `MembershipStoreKitTests`）：
    每台 628 項（619 ＋ 新增 9）、**0 失敗**、624 過 4 略過（同 38：真實佇列通知測試沒有通知權限）——iPhone 17 Pro iOS 26.5
    （`B521C391`）與 iPhone 17 Pro iOS 27.0（`C2F654DB`）。新增 presentation 3 項（今天的提示寫「今天」、天氣資料只出現在標記
    旁邊、今天的預報與提示在中型以外什麼都不改）與 snapshot 6 項（擁有者 04:00 的情境、午夜後抓到的預報進今天的天氣欄、
    不會出現別的早上或別的路線／提前分鐘的預報、有預報又沒警告的項目不會超過 3 小時、今天的失敗寫「今天」、今天與明天
    同一套規則）；「今天不畫天氣欄」改寫成「今天也畫」，其餘今天的測試改成新的提示。把原定時間的判斷改成 `>=` 會讓 5 項
    失敗。xcresult：`DerivedData/Logs/Test/Test-39-today-weather-ios265-20261002-044108.xcresult`、
    `DerivedData/Logs/Test/Test-39-today-weather-ios270-20261002-044108.xcresult`。
  - 手機待確認（39，TestFlight）：午夜後中型今天的項目有天氣欄、 Weather 標記（圖與文字兩種狀態）、點天氣欄開法律頁；
    前一次抓取 3 小時後今天的項目寫「預報時間 22:00」（沒有三角形、沒有標記，12／24 小時制各看一次；明天的項目仍是
    「天氣資料需要更新」，見下方「預報時間」一點）、沒有預報時「尚未取得今天天氣」；VoiceOver 在今天的項目也讀得到連結與預報時間；
    著色與透明主畫面；中英文標題在 148 pt 天氣欄旁放得下（含因雨提早時的原定時間那一行）；小型與鎖定畫面和 38 一樣
    （39 是這樣；40 起小型的天空跟預報並帶標記，要看的項目見本節最上方一點）。
    缺地址時今天的項目也有天氣欄（端點「—」、欄底「請完成路線」），和明天的一樣。
    **預期：** 01:00 到 06:15 常會看到前一晚的預報加「預報時間 22:00」（背景工作何時跑由 iOS 決定；原本是「天氣資料需要
    更新」，擁有者 2026-10-02 改成不警告），打開 App 停在鬧鐘頁就會更新成「天氣更新於 …」（點天氣欄不算：App 直接轉到
    Apple 法律頁）；不是改壞了。
  - **審查修正（「Review fixes: today's weather on the medium widget」）：** 四項都是說法與程式不一致，行為沒改，補測試把
    實際行為釘住。①②build 38 對缺地址的使用者在今天的項目存了「請完成路線」（38 的規則：沒有預報且缺地址），所以「38 寫的
    snapshot 照 38 畫」只對其他今天項目成立；這種項目在 39 會畫天氣欄（端點「—」、欄底「請完成路線」、 Weather 標記），
    38 是左邊占滿。決定保留：39 對同一個狀態寫出的項目一模一樣、明天的項目也這樣畫，App 重新發布或今天換成明天時都不跳
    （改成保留 38 的樣子已列入[產品決策](PRODUCT_DECISIONS.md)的否決）。程式註解、產品決策與本節改寫；新增 snapshot 測試
    `testRouteIncompleteTodayEntryIsWhatBuild38Stored`（缺住家、公司只有空白、缺地址又剛好不選星期二：今天的每一項都等於 38
    會存的項目，天氣欄寫「請完成路線」，和明天的天氣欄同字），presentation 測試補上 38 存的「請完成路線」今天項目，
    `testTodayChangesNothingOutsideTheMedium` 不再略過 `.routeNeeded`。③「點中型的天氣欄也會開 App、就會更新」不成立：
    `WeatherAttributionLink.open` 一拿到法律頁網址就交給 Safari，抓預報只在鬧鐘頁顯示時才跑，進背景時發布的是舊資料；
    產品決策與本節改成「打開 App 停在鬧鐘頁」。④原定時間的判斷用嚴格大於，理由寫錯成「那一秒仍是今天的請求」：那一秒
    App 的「接下來的早上」已經是明天；真正的理由是連續（略過的日子今天的項目顯示到原定時間那一秒，天氣欄留到最後一秒）。
    註解、產品決策與測試訊息改寫；`testSkippedTodayRunsUntilItsNormalTime` 加上那一秒仍是午夜那一項、仍有天氣欄，而
    `TomorrowWeatherRequest` 已是星期日。測試（同上設定）：每台 **629 項（628 ＋ 新增 1）、0 失敗**、625 過 4 略過（同上：
    真實佇列通知測試）——iPhone 17 Pro iOS 26.5（`B521C391`）與 iOS 27.0（`C2F654DB`）。突變檢查：判斷改成 `>=` 有 5 項失敗
    （含 `testSkippedTodayRunsUntilItsNormalTime`）；改成「請完成路線」的今天項目不畫天氣欄有 2 項失敗（新測試與
    `testTodayEntriesShowTheMediumWeatherColumn`）。xcresult：`DerivedData/Logs/Test/Test-39-review-fixes-ios265-20261002-050819.xcresult`、
    `DerivedData/Logs/Test/Test-39-review-fixes-ios270-20261002-050819.xcresult`。
  - **今天的預報超過 3 小時寫「預報時間」、不警告（擁有者決定 2026-10-02，文字已核准；仍是 1.8.0（39），build 號不變）。**
    今天的項目（午夜到響鈴）預報超過 widget 的 3 小時（D-B）時，中型天氣欄不再寫「⚠ 天氣資料需要更新」、也沒有警示標記，
    改寫中性的「預報時間 22:00」／“Forecast as of 10:00 PM”，時間照 App 的 12／24 小時設定，VoiceOver 讀同一行。理由
    （擁有者）：預報通常是前一晚抓的、鬧鐘還沒響，04:00 看到前一晚的預報是預期中的事。不變：明天的項目超過 3 小時仍警告；
    抓取失敗兩者都警告；沒有預報仍寫「尚未取得今天天氣」（已核准）；小型、StandBy、鎖定畫面不變；標記與法律頁連結跟著天氣欄
    （2026-10-02 晚起小型畫預報天空時自己也帶標記，見本節最上方一點）。
    詳見[產品決策](PRODUCT_DECISIONS.md)最上方。
    - 程式：snapshot 與 builder 的規則不變（今天的項目照樣存 `.stale`，版本 4），widget 在抓取時間 ＋ 3 小時的下一秒自己換字。
      `TomorrowWidgetPresentation`：今天的 `.stale` 不算天氣欄的提示（`weatherColumnNotice` 為空，所以沒有三角形）；新的
      `weatherColumnFooter` 是天氣欄欄底與 VoiceOver 共用的那一行（提示的文字，否則「天氣更新於 …」，今天過期時「預報時間 …」）；
      `init` 多收 snapshot 的 `clockFormat`；`LocalizedLine.Argument.time` 用 `ClockTimeFormat` 寫時間；天氣欄的 VoiceOver 文字
      搬進 `weatherColumnAccessibilityLabel`（可測），widget 的 `WidgetStyle` 只呼叫它。widget 畫面：欄底改讀
      `weatherColumnFooter`，預報時間和「天氣更新於」一樣淡色、不帶符號。builder 只改註解。
    - 字串：widget 專用 +1 `widget_forecast_as_of`（「預報時間 %@」／“Forecast as of %@”），兩個 widget 字串表都加；
      `widgetOnlyKeys` 52 → 53。App 的字串表不動。
    - 測試（Xcode 27.0、簽章的 `RainyClock Membership Local`、`-parallel-testing-worker-count 1`、略過 `MembershipStoreKitTests`）：
      每台 **633 項（629 ＋ 新增 4）、0 失敗**、629 過 4 略過（同上：真實佇列通知測試）——iPhone 17 Pro iOS 26.5（`B521C391`）
      與 iOS 27.0（`C2F654DB`）。新增 presentation 2 項（今天過期寫預報時間：沒有提示、三角形與標記，12／24 小時兩種、中英文、
      VoiceOver 全文；只有今天的過期改：未滿 3 小時仍是「天氣更新於」、失敗仍警告、明天過期仍警告、沒有預報仍是「尚未取得今天天氣」）
      與 snapshot 2 項（前一晚 22:00 發布的 snapshot：00:00 與 01:00:00 是「天氣更新於 22:00」，01:00:01 起「預報時間 22:00」到
      07:30 響鈴；18:00 的預報在明天的項目 21:00:01 起警告，午夜變成今天的項目後改寫「預報時間 18:00」）；字串測試加新字的值與
      參數；原本斷言今天過期是 `.todayNotice(.stale)` 的 4 項改成新行為，另 2 項 presentation 測試把欄底也納入「天氣資料只在
      標記旁邊」的檢查。突變檢查（只跑三個 widget 測試類別，iOS 26.5）：
      今天過期改回警告有 8 項失敗；預報時間改回「天氣更新於」有 7 項失敗；時間不照 12／24 小時設定有 4 項失敗。xcresult：
      `DerivedData/Logs/Test/Test-39-forecast-time-ios265-20261002-080535.xcresult`、
      `DerivedData/Logs/Test/Test-39-forecast-time-ios270-20261002-080535.xcresult`。
    - 手機待確認（併入上面 39 的清單）：午夜後抓取滿 3 小時，中型今天的天氣欄寫「預報時間 …」、沒有三角形與標記（12／24 小時制
      各一次）；VoiceOver 讀到同一行；明天的項目過期仍是「⚠ 天氣資料需要更新」。
    - 審查修正（2026-10-02，只改註解與文件，行為不變）：產品決策裡 10/1 一節「仍刻意和主卡不同」的第 1、4 點與 10/2 今天天氣
      一節的「文字」還寫著今天的天氣欄 3 小時後警告「天氣資料需要更新」，三處都標成已被最上方一節取代，第 1 點也記下新的刻意
      不同：主卡午夜後超過 30 分鐘照樣警告，widget 今天的天氣欄從不因時間警告。`TomorrowWidgetPresentation`（`line`、
      `showsWarningBadge`、`alarmNotice`）與 presentation 測試的註解改寫：今天的失敗／沒有預報是天氣欄的提示（失敗帶三角形），
      今天的過期不是提示，是 `weatherColumnFooter` 的預報時間，中性、不帶三角形。測試同上條件，每台 633 項、0 失敗、629 過
      4 略過（同上）——iOS 26.5 與 iOS 27.0。xcresult：
      `DerivedData/Logs/Test/Test-39-forecast-time-review-ios265-20261002-082232.xcresult`、
      `DerivedData/Logs/Test/Test-39-forecast-time-review-ios270-20261002-082232.xcresult`。

- **2026-10-02 03:43：1.8.0（38）已上傳 App Store Connect（只進 TestFlight，未送審）。** Xcode 27.0（iOS 27 SDK）從 `3cf0fab`
  archive；本機 App Store 匯出逐項檢查（三個 bundle 都是 1.8.0（38）、正式推播與 App Attest、widget 也簽上 App Group——
  automatic signing 已替 widget 的 App ID 開好，**不用再到開發者網站手動開**、三個隱私清單、正式網址、只有 IronSource）後上傳，
  Apple 已處理完成。上傳前完整測試見下一點的「測試（2026-10-02…）」。
  **App Store Connect（2026-10-02 04:0x，擁有者核准內容後由 Claude 填入，未送審）：** 已建立 1.8.0 版本（「準備提交」），
  繁中與英文 What's New 已貼上並儲存（614／2,020 字；與 `appstore-metadata.md` 草稿只差一處：「不會上傳你的所在地」改為
  「不會把你的所在地傳給雨天鬧鐘」／「…is sent to Rainy Clock」，因為地址會送 Apple 地圖做地理編碼），審查備註換成
  [審查說明](appstore-review-notes-1.8.0-38.txt)（3,916 字），選 build 38 並儲存；重新整理後讀回三者皆正確。發佈方式仍為手動。
  審查資訊的附件欄是空的（1.7.1 的 ATT 錄影沒有沿用；新審查說明沒有提到附件）。
  **下一步：**①在 iPhone 上用 TestFlight 跑本節各點的「手機待確認」（**改用 39**，見上一點；38 的結果除了中型今天的天氣欄都適用）；
  ②（原為建版本與貼文字，已完成；**39 上傳後改選 build 39，審查備註第一行改成 (39)**；**10/2 傍晚起要送審的是 40**：40 上傳後改選 build 40、審查備註換成 (40) 版，見本節最上方一點）；③送審當天：發布 App 隱私問卷更新（Device ID、Other Diagnostic Data 加上停班停課用途，見 `appstore-metadata.md`）；
  ④上架當天：買斷改 US$15／NT$150。隱私權政策的停班停課一節已於 10/1 發布到公開網站（`main` `b4d2c65`）。

- **2026-10-01：1.8.0（38）修正系列（`f77a4ec`…`24cf509`，9 個 commit）與其審查修正（「Review fixes for the 1.8.0
  fix series」）。** 合併 `ios/widget` 後的對抗式審查找到的 9 項各自一個 commit；再審一輪找到 27 項（1 項 major），全在審查修正
  commit 處理。版本仍是 1.8.0（38）（10/2 已上傳，見上一點）。
  **`build/` 裡 10/1 00:33 的 1.8.0（38）archive 早於整個修正系列**，已改名為
  `build/RainyClock-1.8.0-38-STALE-pre-review-fixes-do-not-upload.xcarchive`，**不可匯出上傳**：測試全過後從整合後的 HEAD 重新
  archive，上傳前確認 archive 的 `CreationDate` 晚於最後一個 commit（38 一旦上傳就不能再用）。
  1. **AlarmKit：正在響／賴床的鬧鐘撐過重新登記（`f77a4ec`）。** 原本每次重新登記每週鬧鐘都取消 App 所有 AlarmKit 鬧鐘，包括正在響
     或賴床倒數的：7:30 響、按賴床，7:31 開 App（判斷已過期）重新登記，7:35 的賴床就不響。兩條登記路徑改成只取消「僅排定」的
     舊鬧鐘，在新鬧鐘登記**之後**讀狀態；正在響／賴床的記下來，等它回到排定狀態再取消。`AlarmKitScheduler` 改注入
     `AlarmManager`／`UserDefaults`，`AlarmKitSchedulerTests` 用假的鬧鐘清單。審查修正：
     - **（major）被替換的每週鬧鐘賴床結束後回到排定狀態，會在下一個選定日的舊時間和新鬧鐘一起響**，而收掉它原本只靠下一次開 App
       或背景更新——使用者在鎖定畫面按停止、App 一直在前景，或之後不開 App 又沒有背景更新，就不會發生。改為：①沒人要求的重新判斷
       （過期的開 App、背景更新、推播；`refreshScheduledAlarmUnattended`）在有鬧鐘正在響／賴床時不重新登記，下一次再判斷，這之間
       照上一次的判斷響；②程序存活期間監看 `AlarmManager.alarmUpdates`（`retireSupersededAlarmsAsTheyStop`，啟動時開始），被替換
       的鬧鐘一回到排定就取消；③停班停課推播也收一次。使用者自己的操作（改設定、重試、總開關）照常登記。
     - 改地址、清空重複星期（鬧鐘本身仍開著）移除登記時，仍會取消正在賴床的鬧鐘。改為和重新登記一樣留著響完：
       `NotificationScheduling.retireScheduledAlarms`（AlarmKit：取消僅排定的、記下進行中的；iOS 17–25：拿掉排程但保留沒按停止的
       補響鏈，按停止即停，關閉鬧鐘也停）。只有關閉鬧鐘（`cancelScheduledAlarms`）會結束賴床。
     - 測試：`AlarmKitSchedulerTests` 8 → 13（逐日登記期間開始響的鬧鐘留著、讀不到清單時撤回新鬧鐘只留舊的、取消失敗會記下並由
       下一次重試、移除登記留著賴床、程序存活時停止即取消）；`AlarmViewModelSchedulingTests` 改地址與清空星期改看 `retireCount`、
       無人要求的重新判斷在響／賴床時不登記；`LocalNotificationSchedulerTests` 移除登記保留補響鏈、關閉鬧鐘結束補響鏈。
  2. **主卡／widget：提早響過後改提前分鐘，沿用的鈴照 AlarmKit 真的會響的時間顯示（`3688000`）。** 審查修正：只在那個早上依現在的
     提前分鐘算出的檢查點之前才算「等待預報」。提前分鐘調長（例 30 → 60）時隔天檢查點 6:30 早於沿用的 7:00，過了檢查點就沒有東西
     會再判斷那個早上、按重試會登記 7:30：主卡顯示 7:30 並標「鬧鐘設定尚未更新完成」，widget 今天的項目顯示 AlarmKit 真的會響的
     7:00 並標同一個警示（和「舊設定的登記」同一種顯示，`keptRingDate`）。晚上預覽改讀和主卡相同的成對捲動摘要
     （`rollingForwardAsPair`）：提早響過到原定時間之間重新規劃時，隔天那則寫 7:00（D-D），不再寫 7:30。測試：
     `AlarmViewModelSchedulingTests` 2 項（提前分鐘調長後 6:35 的主卡與 widget、改提前分鐘後隔天的預覽）。
  3. **DAYOFF-SPEC v4（`032771c`，下一點）的審查補充。** 共用 fixture 補上 v4 規則：`decisionCases` 新增可省略的 `evaluatedAt`／
     `checkedAt` 與 8 個案例（`decide-26`…`33`，含真實的臺中市 7/10 08:50 公布 7/11），`specVersion` 仍是 4（v4 尚未在任何平台上架，
     suppress／ring 結果沒有改，見 spec 的「v4, amended」）；iOS 測試的 fixture 數 25 → 33。沒寫日期的公告超過 18 小時後視為沒有公告
     （`noAnnouncement`），不再是「公告已過期或時間異常」——NCDR feed 不會清空，上一次事件留下的「尚未列入警戒區」原本讓之後每則
     其他縣市的推播都對這支手機發出有聲的「公告已過期」；同一天後面還有較早的有日期公告時仍照響（P5）。提前超過兩天公布的日期有自己
     的理由「公告日期超出可判斷範圍，維持原鬧鐘」（英文 “The announcement is for a day further ahead than the app acts on, so your
     alarm stays on.”），不再說成過期。`DayOffPushContentTests` 2 項。
  4. **iOS 17–25 逐日排程：按過停止的早上，rearm 後不再補響（`3652414`）。** 例：逐日排程 7:00 響、點通知停止並打開 App，啟動時
     的 rearm 重新登記存下的計畫、今天那一筆也在內，7:05 的補響就回來了。改為：響鈴時間不晚於「被停止那則通知的送達時間」的那一筆，
     不登記補響（和 `carriedChains` 同一條規則）；之後的早上與沒人按停止的鏈照常補響。審查修正：只有**已經發生**的鈴能被停止
     （`min(送達時間, 現在)`），手動把時鐘調快一天時點的通知不會讓之後每次登記都拿掉明天的補響。`LocalNotificationSchedulerTests`
     13 → 16 項（`testRearmingTheDatedPlanKeepsAStoppedMorningSilent` 修正前失敗；新增時鐘調快、移除登記保留補響鏈、關閉結束補響鏈）。
  5. **鬧鐘關閉時的停班停課推播一律安靜（`34c5499`）**：見本節「2026-09-30：新增鬧鐘總開關」一點的子項。
  6. **停班停課的晚上預覽與「僅部分地區」推播標示來源（`7ee37a7`）。** 因停班停課略過的早上，晚上預覽原本寫「明天的鬧鐘依你的日曆
     關閉」，原因錯、也沒有來源；改為新的 `.closure`：「明天的鬧鐘因臨時停班／停課略過。」＋「來源更新時間：…」＋政府資料開放授權
     一行（主卡同一組字）。「僅部分地區停班停課」等相關推播也加上來源行。審查修正：預覽的來源時間不寫年份（「9/15 下午5:05」，和
     「檢查時間」同樣理由）；重新登記失敗（公告撤回後）保留舊摘要時，之後因改預覽時間／12・24 小時而重新規劃的預覽，不再把已不被
     公告支持的略過寫成停班停課、還標上撤回它的那一版資料的時間（等下一次登記成功再規劃）；新增 view model 層的測試，確認預覽用
     的是公告資料自己的更新時間（`sourceUpdatedAt`），不是 App 抓取的時間。
  7. **iOS 26 打開停班停課規則時詢問通知權限（`5d5f390`）。** 公告是可見推播，但 iOS 26 的鬧鐘權限是 AlarmKit 的，晚上預覽關閉時
     從來沒有人詢問通知權限，推播全被丟掉。打開規則時若尚未決定，詢問一次；拒絕仍保留規則；iOS 17–25 不變（鬧鐘本身在排程時詢問）。
     這是 App 詢問通知權限的第四個地方（見 1.6.9 預覽一節）。審查修正：①允許後補設逐日排程的「即將到期」提醒（打開規則造成的逐日
     登記通常在提示還開著時就完成，當時沒有權限設不了）；②拒絕過（例如為了晚上預覽）時，開關下方寫「雨天鬧鐘的通知已關閉，停班停課
     公告無法顯示；鬧鐘仍會依 App 取得的公告處理。」＋「開啟通知」按鈕（`UIApplication.openNotificationSettingsURLString`）；
     ③測試：只有開關會詢問（背景、推播、刷新不會）、方案不含規則或沒有方案時不詢問、拒絕後等提示的工作結束再確認規則仍開啟。
     1.8.0 審查備註（`appstore-metadata.md`）的通知段落中英都補上這個提示。
  8. **沒有確認的方案就不套用停班停課；決定前先還原方案（`95f09ff`）。** 背景工作與推播啟動不會跑到 `MembershipManager.start()`，
     前景啟動也在 `start()` 驗證前就排程；沒有方案時原本照存的設定套用停班停課，伺服器已確認到期的訂閱者照樣被略過。改為：服務已設定
     但沒有方案時不套用停班停課（日曆照舊）；背景、推播與前景啟動先還原快取的方案（`restoreSchedulingEntitlements`）。審查修正：
     ①方案在啟動決定之後才確認（`start()` 的同步、稍後完成的還原、購買、恢復購買、到期、刪除會員資料）時立刻重新決定：過期旗標、
     App Group、推播註冊與鬧鐘（`membershipPlanDidChange`，監看 `schedulingEntitlementChanges`）；②只有存了付費規則（停班停課或日曆）
     才等還原，最多等 5 秒、被取消（背景工作到期）就不再等，還原本身繼續、結果之後再套用；`start()` 仍等到還原結束
     （`SharedRestore`）；③背景更新先處理「鬧鐘已關閉」再還原方案；④widget 在還原嘗試之前不寫快照（冷啟動的背景／推播原本會先寫
     一次「停班停課被丟掉」的快照，再用第二次、可能被節流的重載修正）。測試：還原的共用／重試／逾時／取消（`SharedRestoreTests` 3 項）、
     背景更新與推播入口依還原的方案決定（`refreshArmedAlarm(model:)`、`handleDayOffSync(model:)`）、啟動後才確認的方案立即套用、
     只有付費規則才等、widget 等還原。
  9. **廣告同意也在瑞士詢問（`24cf509`）**，如隱私權政策所寫。審查修正：歐盟的海外領土與奧蘭群島有自己的地區代碼（RE、GP、MQ、GF、
     YT、MF、AX，以及 CLDR 的 IC、EA），設成這些地區的手機原本不會看到同意畫面，已加入；測試改成 EU27 ＋ 這些地區 ＋ IS/LI/NO ＋
     GB ＋ CH。**瑞士（與上述地區）的使用者更新到 38 後會看到一次同意畫面。** 審查備註的貼上說明補一句：1.7.1（37）備註的「In the
     EEA/UK」改成「In the EEA, the UK and Switzerland」。
  - **字串（待擁有者看過，已列入本節 ③）：** `evening_preview_closure`（中英）、預覽的來源兩行、相關推播的來源行、推播理由
    「公告日期超出可判斷範圍，維持原鬧鐘」＋英文、`ux_closure_notifications_denied`／`ux_closure_notifications_open_settings`（中英）。
  - **測試（2026-10-02，Xcode 27.0／iOS 27 SDK，擁有者同意授權後）：** `25074ac` 起建置 0 錯誤（警告都是既有的：測試檔
    actor 隔離、即時動態 `Text +` 在 iOS 26 deprecated、SDK 標頭 nullability）。完整測試（`RainyClock Membership Local`、簽章、
    `-parallel-testing-worker-count 1`、略過 `MembershipStoreKitTests`），每台 619 項、**0 失敗**：
    iPhone 17 Pro iOS 26.5 615 過 4 略過（真實佇列通知測試沒有通知權限）；iPhone 16 Pro iOS 18.6 604 過 15 略過
    （`AlarmKitSchedulerTests` 13 項只在 iOS 26 以上、2 項環境變數控制的輔助測試；真實佇列測試在這台有權限，照常通過）；
    **iPhone 17 Pro iOS 27.0（新增）**615 過 4 略過。iOS 27 第一次執行在最後一個類別前卡住（測試行程結束後 xcodebuild 沒再啟動
    App），重跑沒有再出現；同一次執行另揭露 iOS 27 拒收未授權通知的錯誤是 UNErrorDomain 2003（iOS 18 是
    `.notificationsNotAllowed`），真實佇列測試改為先查授權狀態再略過。`MembershipStoreKitTests`（iOS 26.2 暫時模擬器）：
    其他 5 項（購買、恢復、續訂、過期、退款、Ask to Buy）每次都過；`testVerifiedRenewalCancellationKeepsMonthlyAccessUntilExpiry`
    **不穩定**：Xcode 26 建置 4 次中 3 次過、Xcode 27 建置 3 次中 1 次過，失敗都在同一步——`enableAutoRenewForTransaction` 之後
    8 秒內讀不到 `willAutoRenew = true`（之前的取消、到期維持權益都正確）。偶發而非每次，判斷是本機 StoreKit 測試服務的狀態
    更新延遲，不是 App 的邏輯；送審不受影響，之後可以把那一步的等待放寬。
  - 手機待確認（38 上傳前）：①iOS 26：7:30 響、賴床，7:31 開 App（判斷已過期），7:35 照響；在鎖定畫面按停止、App 留在前景，隔天
    （選定日）舊時間不再多響一次。②賴床中改地址或清空重複星期，賴床照響完；關閉鬧鐘則立刻結束。③iOS 17–25（iPhone 16 Pro 18.6
    模擬器）：逐日排程 7:00 響、點通知停止並打開 App（rearm），7:05 不再響；賴床中改地址，補響照常到按停止。④iOS 26、晚上預覽關閉：
    打開停班停課規則會跳通知權限；允許後通知中心排定「日曆即將到期」提醒；拒絕後開關下方出現說明與「開啟通知」按鈕。⑤瑞士地區：
    第一次開啟先出現廣告同意畫面，再出現追蹤詢問。（**⑤ 2026-10-02 已在模擬器確認**：iOS 27 模擬器、Debug build 清空
    `LevelPlayAppKey` 並重新簽章、`-AppleLocale de_CH` 全新安裝，第一次開啟即出現「Ads in Rainy Clock」同意畫面；之後接追蹤詢問的
    順序與地區無關，由 `testGDPRAnswerWaitsForActualSheetDismissalBeforeATTAndSDK` 守住。）

- **2026-10-01：已套用的停班停課略過不再在公告滿 18 小時時被撤回（DAYOFF-SPEC v4，擁有者核准）。**
  對抗式審查找到：`DisasterSuspensionEvaluator` 以「現在 − 公告時間 ≤ 18 小時」判斷公告有效，12:00 公布的「明天
  停止上班」在隔天 06:00 後每次重新判斷都得到「公告已過期或時間異常」，把 07:30 排回確定放假的早上；提前兩天公布的日期
  也在前一天下午失效。改為：下載的公告資料仍須在 18 小時內；寫明鬧鐘那一天的公告在那一天內都有效，但只能在那一天之前
  最多兩個台北日發布（`maximumLeadDays = 2`，擋住凍結舊資料裡跨年滾動的 M/D）；沒寫日期的公告照舊 18 小時。排程、主卡、
  widget 快照與通知擴充功能共用同一個判斷，一起生效。重抓 NCDR 完整 1,374 則核對（寫進 `dayoff-corpus-summary.json` 的
  `announcementLead`）：有日期的公告都在指定日當天或前一天發布，沒有更早的；真實案例 2026-07-10 上午臺中市、南投縣公布 7/11 停班，
  舊規則會在 7/11 約 03:30 把已略過的鬧鐘排回。`dayoff-fixtures.json` 只把 `specVersion` 升為 4，沒有改任何期望值；
  新情境需要判斷時間，放在 iOS 測試：`DisasterSuspensionTests` 兩項（12:00「明天」在 06:00:01／07:29 仍略過、
  「9/16」9/14 公布在 9/15 14:01 與 9/16 07:00 仍略過）加上既有測試改一項（9/14 11:59:59 公布的「9/15」由照響改為略過）
  與新增的邊界（提前 3 天、跨年滾動、沒寫日期），`DisasterIntegrationTests` 一項（隔天 06:30 重新排程時 9/16 仍被略過）。
  **Xcode 建置與 XCTest 尚未執行**（整合時一起跑）；只用 `swiftc` 在 macOS 上單獨編譯評估器，重播上述新增／修改的斷言與
  25 組共用決策案例：新規則 0 失敗，舊規則 8 項失敗（正是 v4 的案例）。Day-off: implemented against spec v4。

- **2026-10-01：`ios/widget` 合入 1.8.0 線（擁有者決定 1.8.0 帶「下次鬧鐘」widget）。** 合併 commit 把 `ios/widget`
  （`ad0b628`）合進 `e02c1ff`（`ios/main` ＋ 測試 commit）；尚未上傳。版本維持 1.8.0（38）：`Info.plist` 與 11 個
  `MARKETING_VERSION`／`CURRENT_PROJECT_VERSION`（App、AlarmWidget、DayOffNotification 各 3，tests 2）一致；
  `Info.plist` 保留 widget 的 `CFBundleURLTypes`（`rainyclock`）與 `DayOffServiceURL`／`DayOffSandboxServiceURL`。
  兩邊各自解過的問題統一成一套（理由見[產品決策](PRODUCT_DECISIONS.md) 2026-10-01）：
  1. **哪個早上。** `TomorrowWeatherRequest`／`TomorrowAlarmStatus.resolve` 的 `dayOffset` 改成可省略：不給是主卡的
     「接下來的早上」（`tomorrowStatus`，也是 App 唯一抓預報的早上）；0／1 是 widget 的今天（`todayStatus`）與日曆明天
     （新的 `calendarTomorrowStatus`，widget 原本用 `tomorrowStatus`，合併後那是主卡）。
  2. **同一份摘要。** 主卡改讀與 widget 相同、成對往後捲的每週摘要（`rollingForwardAsPair`）。每週分支在摘要已被
     捲過今天那一格時看 `decidedNormalAlarmDate`：為今天或更早的早上決定的，那一格已響過（主卡「已響鈴」，無警示）；
     為之後的早上才登記的，今天沒有鈴了——`registeredRingDate` 是那個之後的鈴（主卡照 `ios/main` 警示），
     `passedRingDate` 是今天那一格（widget 結束今天）。App 一直開著、原定時間過後，主卡現在也顯示週重複真正會響的
     沿用提早（`ios/main` 原本顯示原定時間，重開 App 才正確）。
  3. **`decisionNormalAlarmDate` 與 `firedEarlyRing` 並用。** `restoreWeeklySchedule`：`hasSameForecast` ＝ 略過保存的預報、
     `calendarForecastDate` 或 `decidedNormalAlarmDate`；響過的鈴照 `ios/main` 留在已響的時間並記 `firedEarlyRing`；
     `decisionNormalAlarmDate` 記成這次登記的早上（沒有下一個早上時沿用前一個）。`registerCalendar` 保存略過那天的
     預報也改看 `decidedNormalAlarmDate`：重開後被捲到明天的沿用提早不會被記成明天的決定，取消略過回原定時間。
  4. **主卡規則移進 `TomorrowWidgetSnapshotBuilder`**（卡片與 widget 共用）：關閉時只有關閉失敗會警示、
     `ringIsNotRegistered` →「鬧鐘設定尚未更新完成」、響過後不顯示降雨 %；`ContentView` 只負責把同一行字寫成
     今天／明天版本、`ringAfterSkip` 的日期與停班停課的時間。新原因 `alarmOff`／`skippedOnce` 進 snapshot（版本 3）：
     widget 關閉時所有尺寸寫「鬧鐘已關閉」（鎖定畫面圓形寫「關閉」）且不寫日期、不出現今天的項目；僅關閉下一次寫
     「只關閉這一次，之後的鬧鐘照常響」（inline 寫「明天／今天只關閉這一次」）。
  5. **仍刻意和主卡不同：** 過期警告 3 小時 vs 30 分鐘（D-B）；widget 午夜到**響鈴**寫「今天」，主卡到**原定時間**、
     標題「下次鬧鐘」（D-C 仍照舊，「卡片整天講明天」那句被 9/29 取代）；沿用的提早響過後主卡寫「因雨提早」
     （widget 不會顯示響過的早上）。**最後這項是合併時的暫定做法，與 D-D「卡片同規則」不同，尚未經擁有者同意**
     （待決定：照這樣、改寫別的字，或不顯示原因）。
  6. **字串：** 英文 `ux_tomorrow_closure` 採 widget 的「Work or school is closed tomorrow」（widget 表逐字共用；中文兩邊
     相同）；英文 `ux_today_weekend` 對齊為「Today is a weekend day」；新增 `ux_today_awaiting_forecast`（等待今天預報）；
     widget 表加共用 3 鍵（`ux_alarm_off`、`ux_alarm_off_message_only`、`ux_skip_once_reason`）與 widget 專用 3 鍵
     （`widget_skip_off` 關閉／Off、`widget_alarm_off_short`、`widget_skip_once_short`）。另外三句主卡英文隨 widget 表
     改了（widget 表逐字共用 App 的字）：`ux_tomorrow_weekend`「Tomorrow is a weekend」→「… weekend day」、
     `ux_rain_applied_forecast`「Route rain %d%% · %d min earlier」→「Route rain %d%%, %d min earlier」、
     `ux_weather_rain`「Rain」→「Rainy」；主卡表也多了 `ux_tomorrow_awaiting_forecast`（D-D）。**新文字與這三句都待擁有者看過。**
  7. **文件：** `appstore-metadata.md` 的兩份 1.8.0 草稿合成一份（What's New 中英各一、審查備註事實一份）；
     審查備註要另外在 4,000 字內重寫。
  - 已知（未改）：BGTask 抓的是主卡的早上，所以今天提早響過到原定時間之間，widget 的「明天」沒有預報（顯示
    「尚未取得明天天氣」）；原定時間過後就是同一個早上。鬧鐘關閉時背景更新鏈停止，widget 在第二個午夜後變
    「開啟 App 更新」。
  - **合併審查後修正（同日，審查找到 14 項，全部處理）：**
    1. **App 一直開著時同一個早上會響兩次（`ios/main` 既有，合併後主卡已顯示矛盾）。** 例：週一晚判斷週二下雨，登記
       7:00（原定 7:30）；App 一直開著、之後沒有成功的重新登記；週三 AlarmKit 的每週重複照樣 7:00 響。7:05–7:30 之間
       背景更新、開 App、改設定或「僅關閉下一次」重新登記時，排程讀的是記憶體裡週二的摘要：檢查窗看的是週二、
       `earlyRingThatWentOff` 認不出週三已響，於是把週三 7:30 排回去（不需要網路），再響一次；主卡同時寫「已響鈴 7:00」。
       改為排程（背景的檢查窗、`restrictedRulesTransitionIsSafe`、`weeklyComingMorningIsDecided`、`restoreWeeklySchedule`
       的 `rang`、`datedBasePlan`）都讀 `registeredSummary(now:)`——每週摘要照啟動時的方式往後捲（逐日計畫原樣），
       和主卡與重開 App 讀到的一致。測試：`SkipNextAlarmTests` 2 項（App 一直開著：背景更新不動、僅關閉下一次不把今天
       排回、取消略過留在 7:00；前景執行留在 7:00），修正前都失敗。為了測，`AlarmViewModel` 加一個 DEBUG 專用的
       `holdRegistrationForTesting`（測試沒辦法等一天）。
    2. **晚上預覽照 D-D。** 沿用到隔天的每週提早，預覽不再當成隔天的判斷（「降雨機率 80%…提前到 7:00」其實是前一天的
       預報），改用「明天 7:00 有鬧鐘，早上會依當天預報決定…」，時間是 AlarmKit 真的會響的。`EveningPreviewPlannerTests` 1 項。
    3. **widget 不丟主卡的「鬧鐘設定尚未更新完成」。** 已提交的停班停課略過不再被公告支持、或逐日計畫少了這個早上
       （`ringIsNotRegistered`）時，widget 的今天原本在午夜就結束，直接顯示「明天 週三 照常響鈴」；現在和主卡一樣
       留到原定時間並帶同一個警示。合併時的測試夾具（沒記 `firedEarlyRing` 的逐日計畫）改成真的會發生的樣子。
    4. **widget 的停班停課標來源（DAYOFF-SPEC §7）。** snapshot 版本 3 → 4，停班停課項目帶公告資料的來源更新時間；
       小型、中型、長方形在停班停課那一行下面標「來源：人事總處／NCDR」與「來源更新 9/30 下午5:05」（長方形合成一行），
       VoiceOver 也念。鎖定畫面圓形與 inline 放不下，改成不報停班停課（圓形「不響」、inline「明天略過鬧鐘」、鈴鐺圖示）；
       擁有者 9/23 選的圓形「停班」字串保留、暫時不用。
    5. **關閉時的 widget 不再掛天氣警示。** 天氣過期或抓取失敗時，「鬧鐘已關閉」原本會帶橘色警示標記；現在關閉時只有
       關閉失敗才警示（照 2026-10-01 的規則）。
    6. **inline 的「僅關閉下一次」說出是哪個早上**（「明天只關閉這一次」／「今天只關閉這一次」）。
    7–14. 文件：沿用提早響過後主卡寫「因雨提早」標成待擁有者決定（本點「仍刻意和主卡不同」那一項）；本節互相參照改成寫明是哪一點；
       widget 小節過時的幾行加註；「所有尺寸寫鬧鐘已關閉」補上圓形寫「關閉」；三句英文字串的變更補記；D-B／D-C
       的理由更正；合併的狀態改成提交後仍成立的寫法；上面 1.（App 一直開著響兩次）原本要列進「已知」，已修正。
    - 測試（審查修正後）：結果在下面「測試」那一項的最後。新增 8 項，調整 5 項（`todayShownUntil` 分成「已響」與「未登記」、
      合併夾具補 `firedEarlyRing`、圓形字改成「不響」、字串鍵數 51 與新字的檢查）。突變測試：拿掉 1、2、3、5 的修正，
      對應的 6 項測試都失敗（4、6 是新的顯示資料，沒有修正就不能編譯）。
    - 手機待確認：①下雨天 App 一直開著跨一天、隔天沿用的 7:00 響過後 7:30 前在 App 裡做「僅關閉下一次」，今天 7:30
      不再響；②有停班停課時小型、中型、長方形的來源兩行（長方形一行）放得下、不被截掉，圓形／inline 顯示一般略過。
  - 測試：新增 5 項（主卡與 widget 讀同一份捲過的週摘要、總開關進 widget、主卡規則在 builder、`dayOffset` 的請求、
    取消略過不把沿用的提早當成那天的決定），調整 widget 測試中與新規則衝突的斷言（`tomorrowStatus` 午夜後是今天、
    捲過今天那一格時 `registeredRingDate` 的值、`ux_tomorrow_closure` 共用鍵、字串鍵數 36／47、D-D 測試的過期預報改在 07:30
    後取得）。`RainyClock Membership Local` 簽章、`-parallel-testing-worker-count 1`、略過 `MembershipStoreKitTests`：
    iPhone 17 Pro（iOS 26.5）**561 項、557 過、0 失敗、4 略過**（`LocalNotificationSchedulerSystemTests`，模擬器沒有通知權限）；
    iPhone 16 Pro（iOS 18.6）**561 項、559 過、0 失敗、2 略過**（同一組）。兩次都在 02:50 後執行，沒有測試被跨午夜保護略過。
    **合併審查修正後（同樣的設定）：iPhone 17 Pro（iOS 26.5）569 項、565 過、0 失敗、4 略過；iPhone 16 Pro（iOS 18.6）
    569 項、567 過、0 失敗、2 略過**（略過的都是 `LocalNotificationSchedulerSystemTests`，同上）；03:43 後執行，沒有測試被
    跨午夜保護略過。
  - 送審前還欠：widget 小節的四項（widget App ID 開 App Groups、真機、審查備註重寫並核准——草稿只有
    `appstore-metadata.md` 那一份，`.txt` 已作廢、`MembershipStoreKitTests`）；真機加看一次「關閉」「僅關閉下一次」
    「停班停課」的 widget 畫面（小型、中型、圓形、inline、長方形），以及上面「合併審查後修正」的兩項手機確認。
    **擁有者 2026-10-01 已決定：**①沿用的提早響過後，主卡只寫「已響鈴」與時間、不寫原因（合併時暫定的「因雨提早」已改）；
    ②圓形／inline 維持不報停班停課（§7 放不下來源；What's New 與審查備註的「顯示任何停班停課結果時都會標示資料來源」照舊成立）；
    ③合併與修正系列新增的文字全部採用（「來源：人事總處／NCDR」「來源更新 %@」「明天／今天只關閉這一次」、三句改過的英文、
    `evening_preview_closure`、相關推播的來源行、推播理由「公告日期超出可判斷範圍，維持原鬧鐘」、
    `ux_closure_notifications_denied`／`ux_closure_notifications_open_settings`）；④widget 午夜到響鈴寫「今天」、主卡寫
    「下次鬧鐘」，維持不同；⑤採用「只有關閉鬧鐘會結束正在響或賴床的鬧鐘，期間背景重新決定會等它結束」；⑥1.8.0 用 Xcode 27.0 建置。

- **2026-10-01：iOS 17–25 通知鬧鐘——沒按停止的補響，重新登記後照常響完**（下一點列為「仍未處理」的既有問題）。
  例：7:00 鬧鐘、賴床 5 分鐘，使用者還在睡；7:07 背景更新判斷明天下雨、把每週鬧鐘改成 6:30。原本重新登記會刪掉今天
  7:10 起的補響，換成 6:30 那條鏈落在今天的部分（五天鬧鐘是 7:10–7:20，七天鬧鐘則一則都沒有），人就這樣睡過頭。
  改成逐日排程（略過明天、日曆例外、停班停課）時也一樣會刪；逐日排程之間重新登記，則連它唯一的 1 次補響也會被刪。
  改為：`LocalNotificationScheduler` 每次登記（每週或逐日）前，先從待送通知裡找出「已經響了、還沒按停止、補響還沒
  響完」的鏈，把剩下的補響改成一次性通知保留下來，直到按停止（點通知或「停止」）或關閉鬧鐘為止；「僅關閉下一次」和
  改設定都不會中斷它，和 AlarmKit 上正在響／賴床的鬧鐘撐過重新登記一致。新計畫裡「響鈴時間已過」的鏈一律不在今天補響
  （改成下週的備援觸發）：響過的那條由上面保留，沒響過的不憑空補——例如 7:07 才開啟鬧鐘，今天不會 7:10 開始補響。
  （9/30 那一點「按停止前就該響的鏈才擋」的規則因此擴大成「響鈴時間已過的鏈都擋」，按停止只決定保不保留。）
  新舊兩條鏈同一秒都要響時只響一次。保留的補響和新計畫共用 56 則的額度；放不下時先讓出新計畫最晚才響的補響
  （從不讓出主鈴），補響鏈結束後下次開 App 或下一次登記就補回；`rearmAlarmsIfNeeded` 也改為逐日排程走逐日登記
  （原本一律用每週登記，會把逐日排程整個清掉；以前逐日排程不會留下待恢復的旗標，所以沒出過事）。
  AlarmViewModel 不改；`weeklyRestoreWouldReviveFollowUps` 擋的「沒響過的早上」現在排程本身也不會補響，保留無害。
  - 為了能測，`LocalNotificationScheduler` 另外注入時鐘，測試先在 6:50 登記、再把時間撥到 7:07:30；決定用的下一次
    響鈴時間改由 `nextFireDate(of:after:)` 以同一個時鐘計算（`nextTriggerDate()` 只看真實時間）。
  - 測試：`LocalNotificationSchedulerTests` 改用固定時鐘，12 項（之後 3652414 加 1 項、修正系列審查再加 3 項，現為 16 項，見本節「1.8.0（38）修正系列」一點）。修正前 3 項失敗（改時間後舊鏈被換掉、改逐日後舊鏈
    被刪、響鈴時間過後登記憑空補響）；另加「改到 7:20 時同一秒只響一次」。突變測試 6 種（不保留、不讓出額度、同一秒
    不合併、按過停止也保留、只擋按過停止的鏈、恢復時一律用每週登記）各有測試抓到。
    完整測試：iPhone 17 Pro（iOS 26.5）上 **501 項全過、0 失敗**，略過 `MembershipStoreKitTests`（同下）；00:16 那次完整
    執行有 7 項被跨午夜保護略過，另以 `TEST_RUNNER_TZ=America/Los_Angeles` 單獨重跑通過。
  - 待確認：同上一點，要 iOS 17–25 的裝置或模擬器——7:00 響、不要按停止，等背景更新或在 App 裡改時間，今天的補響照常
    響到按停止為止；按「停止」後不再響；關閉鬧鐘後不再響。

- **2026-09-30：iOS 17–25 通知鬧鐘——按過停止的早上，重新登記每週排程後不再補響**（下一點列為已知限制的既有問題，
  早於 `eaf5f18`）。例：7:00 鬧鐘、賴床 5 分鐘，7:01 按停止，排程把今天剩下的補響（7:05 起）換成下週的備援觸發；
  但 7:10 的前景更新、防抖自動更新、改設定或關掉日曆例外（`evaluateRouteAndScheduleAlarm`、`applyCalendarSettings` →
  `restoreWeeklySchedule`）重新登記每週排程時，會把 7:15、7:20⋯加回來，今天照響。
  改為：`LocalNotificationScheduler` 記下被停止的那則通知的送達時間（逐日排程按停止也記），之後每次登記每週排程，
  凡是在那之前就該響、補響還沒響完的鏈，剩下的補響一律改成下週的備援觸發；最後一個被擋下的補響過後，下次開 App
  恢復精確的每週觸發。只看鏈何時開始響，所以停止後把鬧鐘改到今天稍晚（例如 7:40）照常響、照常補響；停止後把賴床
  間隔調長，那條鏈也不會在原本的時間之後再響；沒按停止的鏈重新登記後照常補響。舊記錄只會對上還在補響中的鏈，不用清除。
  同一情境的反向順序一起修：補響送達後、按停止前剛好重新登記（例如 7:10 送達、7:10:30 背景更新、7:11 按停止），原本因
  「通知早於目前排程」整個被忽略，7:15 會再響。那個判斷是怕停掉剛排的新鈴，新規則只停送達前就該響的鏈，所以拿掉。
  AlarmViewModel 不改：`weeklyRestoreWouldReviveFollowUps` 仍要留，它擋的是被略過、根本沒響的早上（沒有「停止」可依據）。
  - 為了能測，`LocalNotificationScheduler` 改為注入通知中心（`AlarmNotificationCenter`；正式版是包
    `UNUserNotificationCenter` 的 `SystemNotificationCenter`）與 `UserDefaults`，其餘行為不變。
  - 測試：新增 `LocalNotificationSchedulerTests`（7 項，假的通知佇列）。先寫的 4 項（同一計畫重新登記、時間改早、
    賴床調長、逐日改每週）修正前都在重新登記那一步失敗（按停止那一步本身正確）；「停止後改到今天稍晚照響」「沒按停止
    照常補響」2 項修正前後都通過，防止改過頭；第 7 項是反向順序。突變測試：改成「按停止後一小時內一律不響」、逐日按停止
    不記錄、恢復舊的送達時間判斷，三者各有測試抓到。
    完整測試：iPhone 17 Pro（iOS 26.5）上 **496 項全過、0 失敗**，略過 `MembershipStoreKitTests`（同下）。其中 6 項
    「今天早上」情境測試在 23:50 那次完整執行時被自己的跨午夜保護略過，另以 `TEST_RUNNER_TZ=America/Los_Angeles` 單獨重跑通過。
  - 仍未處理（既有）：沒按停止時重新登記，今天的補響會換成新計畫那條鏈（例如明天下雨、時間改 6:30，今天 7:00 的補響
    就只剩 6:30 那條鏈落在今天的部分）。（**2026-10-01 已修正**，見本節「2026-10-01：iOS 17–25 通知鬧鐘——沒按停止的補響」一點。）
  - 待確認：要 iOS 17–25 的裝置或模擬器（這台 Mac 目前只有 iOS 26 runtime，iPhone 16 Pro 走 AlarmKit）——7:00 響、
    按停止後在 App 裡改一個會重新登記的設定，今天不再補響，下週同一天照響。

- **2026-09-30：修正檢查點到原定時間之間的三個既有排程問題**（9/29 主卡對抗式審查找到、當時另開任務的那三個；
  主卡的不一致警示保留，現在排程本身是對的）。檢查點＝原定時間減提前分鐘，下例為 7:30 鬧鐘、提前 30 分鐘。
  1. **每週排程吃掉今天的鈴／多響一次**：7:00–7:30 在前景改設定、按「重試」或自動更新，會替「明天」做雨天判斷，
     並把唯一的每週重複鬧鐘改成明天的時間——明天下雨，今天 7:30 就不響；明天晴天而今天 7:00 已提早響過，7:30 會再響一次。
     改為：這段時間（或今天已提早響過）的每週登記一律帶「今天自己的決定」——還沒響就是原定時間，已提早響過就維持那個
     已經過去的響鈴時間；設定修改照樣立即生效，明天的雨天判斷留給原定時間之後的下一次更新（背景更新改排到明天的檢查點）。
     否決「延後到原定時間之後再登記」：那段時間按「重試」會什麼都不做，改的鬧鐘時間也要等舊的原定時間過了才生效。
  2. **逐日排程冷啟動後響兩次**：7:00 提早響過、7:30 前冷啟動時，`rollingForward` 已把摘要移到明天，下一次重新登記
     就把今天 7:30 排回去；第二次重新登記也一樣（那時 `previous` 已是明天的摘要）。改為從不會被移動的排程內容判斷
     （`firedEarlyRing`、計畫裡當天那一筆、每週摘要的提前分鐘），不再看 `scheduledAlarmDate`。
  3. **停班停課刷新反覆重新登記**：刷新比對用的計畫沒扣掉已提早響過的早上，提早響之後才公布的「今天」停班停課每次刷新
     （5 分鐘節流）都像新變化，重新登記一次，而且送不出 receipt。登記、刷新與 receipt 現在共用 `datedBasePlan`：
     公告不會再觸發登記，receipt 照常回 `applied`。
  - 測試：先寫 4 項失敗測試並確認都因上述原因失敗（`AlarmViewModelSchedulingTests` 2 項、`DisasterIntegrationTests` 2 項），
    修正後通過；再用突變測試確認第 3 點與「今天已提早響過」條件各自有測試守住（只修第 2 點時，兩次刷新登記兩次）。
    完整測試：iPhone 17 Pro（iOS 26.5）上 **487 項全過、0 失敗**，略過 `MembershipStoreKitTests`（同下，這台模擬器上會卡住）。
  - 已知限制（既有行為，未改）：iOS 17–25 的通知鬧鐘在這段時間重新登記每週排程時，仍會把今天剩下的補響通知加回來。
    （按過停止的早上：同日已修正，見本節「2026-09-30：iOS 17–25 通知鬧鐘——按過停止的早上」一點。）
  - **同日擁有者決定：提早響過後到原定時間之間開放「僅關閉下一次」**（[產品決策](PRODUCT_DECISIONS.md)）。
    這段時間的「下一次鬧鐘」是明天的：略過明天之後，今天已提早響過的早上不會在原定時間再響；取消略過時，每週鬧鐘
    維持在已響過的那個時間。每週鬧鐘正在響／賴床時仍要先停止（那個重複鬧鐘撐得過逐日重新登記）。
    關閉對話框的「今天已提早響過，⋯之後才能只關閉下一次」字串已移除。iOS 17–25 在這段時間略過，會一併移除今天
    剩下的補響通知（使用者正在操作 App，已經醒了）。（**10/1 起改為照常補響到按停止為止**，與 AlarmKit 一致，見本節「2026-10-01：iOS 17–25 通知鬧鐘——沒按停止的補響」一點。）先寫 2 項失敗測試（每週、逐日各 1 項），修正後通過；
    完整測試 **489 項全過、0 失敗**（同上，略過 `MembershipStoreKitTests`）。
    手機待確認：下雨天 7:00 提早響過後，7:30 前關閉開關，對話框的「下一次鬧鐘：」應是明天的日期，選「僅關閉下一次」後今天 7:30 不響、明天不響、後天照響。

- **2026-09-30：新增鬧鐘總開關，併入 1.8.0**（擁有者要求；[產品決策](PRODUCT_DECISIONS.md)）。鬧鐘頁標題旁的開關，關閉時選
  「僅關閉下一次鬧鐘」或「關閉，直到我重新開啟」，所有方案免費。四位讀者＋三個方案＋評審設計，實作後對抗式審查。
  1.8.0 What's New 與審查說明已加入。對抗式審查後修正：關閉時立刻取消系統鬧鐘（不等正在跑的天氣查詢）、關閉途中被暫停時由背景／推播／啟動補完、
  關閉後才完成的登記不會排上鬧鐘；略過時保留那個早上的雨天判斷，取消略過會回到提早響的時間；更新中也能選「僅關閉下一次」；
  iOS 17–25 在今天的補響通知還會響時不切回每週排程；讀不到 AlarmKit 清單時不宣稱已關閉。
  **已知限制**（未修）：iOS 17–25 略過後到回復每週排程之前，每個早上只有 1 次補響（每週排程最多 10 次）；
  若略過後 27 天都沒開 App、背景更新也沒跑、又沒開通知權限，逐日排程會到期而沒有提醒。
  **降級注意**：裝回 1.8.0 以前的 TestFlight build 會丟掉「關閉」狀態並在啟動時重新排定。
  手機待確認：關閉／略過在 AlarmKit 上真的不響、略過後的下一個早上照響、正在賴床時關閉會結束賴床、關閉時的停班停課推播是安靜的
  ——**包括沒開停班停課規則、沒設行政區（地址沒有對應的區）、或功能已關閉仍收到推播的手機**（34c5499）。
  - 2026-10-01（34c5499）：鬧鐘關閉時，停班停課推播一律改寫成安靜的「你的鬧鐘目前關閉，這則公告不會改變鬧鐘。」，**在判斷停班停課
    設定之前**。原本沒開規則或沒設行政區時擴充功能不改寫，顯示伺服器有聲的通用「打開雨天鬧鐘確認下一次鬧鐘」。行為改變：功能關閉後
    仍收到的推播（取消註冊前送出的）也改成這則安靜通知，不再是伺服器的通用文字。測試：`DayOffPushContentTests`
    `testAnAnnouncementWhileTheAlarmIsOffIsQuietEvenWithAnIncompleteSetup`。`DayOffPushContent.Urgency.unknown` 的註解與
    `DISASTER-PREVIEW.md` 的改寫規則同步寫明「鬧鐘開啟時」（審查修正）。

- **2026-09-30：正式會員服務已重新部署——`rainyclock-membership-00006-hnb`，100% 流量**（擁有者 9/29 同意；9/29 第一次被 auto mode
  安全檢查擋下，9/30 擁有者要求再跑一次後通過）。映像 `rainyclock-membership@sha256:463da306…`（標籤
  `lifetime-closures-20260929`，來源與 sandbox 已驗證的版本相同）；和線上版比對過，只多買斷也給臨時放假那一行。
  部署前後比對：環境變數、secret 參照、容器設定、服務帳號都沒變；`/health` 200，新 revision 無錯誤記錄。
  唯一差異：revision 的 `maxScale` 由未設定變成 20（gcloud 548 帶入；其他服務是 1／3／3，並行 10，足夠）。
  回退：`gcloud run services update-traffic rainyclock-membership --region=asia-east1 --to-revisions=rainyclock-membership-00005-5pm=100`。
- **2026-09-29：買斷調價決定——US$15／NT$150（原 US$10／NT$100），月訂閱不變**；同時再次確認臨時放假給月訂閱與買斷
  （[產品決策](PRODUCT_DECISIONS.md)）。App 用 StoreKit 當地價格，不改程式；本機 `RainyClockMembership.storekit` 已改 15.00。
  **擁有者待辦（ASC → 買斷 `6812814810` → 價格）**：美國基準價改 US$15（Apple 重算其他自動地區）→ 台灣手動設 NT$150 →
  讀回「目前定價」；供應維持美國＋台灣。**生效日：1.8.0 上架當天**（擁有者 9/29 決定）。改好後更新
  `MEMBERSHIP-AND-PAYMENTS.md`、`appstore-metadata.md` 兩張價格表。

- **2026-09-28／29：真機驗證（iPhone 16 Pro，Debug Sandbox build，sandbox 堆疊＋`fixture.sh`）。**
  - 通過：臺南市「明天」公告推播到手機，擴充功能在 App 關閉時改寫成時效性、有聲的通知（睡眠專注模式下仍送達）；
    地圖顯示臺南市 37 區，框出所選行政區；打開 App 後 9/29 鬧鐘被略過，sync receipt 回報 `applied`。
  - 抓到並修正兩個錯誤：
    1. 重複公告時，擴充功能拿「下一個會響的鬧鐘」（9/30）比對，顯示「與你設定的地區無關」。
       改為鏡射未來幾天的日期與已略過的日期，已略過那天的重複公告改成安靜的「9/29 當天的鬧鐘已略過」（`7954488`）。
    2. App 的公告更新有 5 分鐘節流，連失敗後也一樣；可見推播不會喚醒 App，通知卻請使用者「打開 App 確認」。
       23:50 抓取失敗、23:51 推播、23:53 打開 App → 沒有重抓，仍顯示「無法更新」。改為擴充功能收到推播時在
       App Group 記下時間，推播晚於上次嘗試就略過節流（本次提交）。
  - Sandbox 沒有 Scheduler，Job 跑完 15 分鐘後 `/v1/suspensions` 回 503；App 照規則 fail-open 恢復鬧鐘，
    所以每一步真機測試前先重跑一次 Job（`gcloud run jobs execute rainyclock-dayoff-poll-sandbox --region=asia-east1 --wait`；
    公告內容不變就不會推播）。
  - 通過：9/29 00:07 對已略過的 9/29 再發一次公告（`--when today`），通知是安靜的「9/29: that day's alarm has
    already been skipped.」＋資料來源行，只進睡眠專注模式的通知群組，不響不亮；00:12 打開 App 抓到新 revision，
    receipt `applied`。
  - 第三個發現：過了午夜，鬧鐘頁主卡換成 9/30，整頁看不出今天 9/29 的鬧鐘已略過（清晨才公布的「今天」停班停課
    也一樣，而那正是使用者最會打開 App 的時候）。主卡上方加一行「今天 7:30 的鬧鐘因臨時停班／停課略過」＋資料來源，
    點了進設定 → 日曆，過了原定時間就消失。00:39 使用者截圖確認版面（`8e07321`），但見下一點，已被取代。
  - 第四個發現：00:39 同一張截圖裡，主卡寫「Tomorrow Wed, Sep 30 7:30」，擁有者讀成今天早上的鬧鐘、覺得也該略過。
    設計小組（三個方案＋評審）定案：主卡描述接下來的早上，今天的鬧鐘原定時間過了才換到明天，午夜只換「明天／今天」；
    上方那一行併入主卡，提早響過後顯示「已響鈴」，已提交但公告不再支持的略過顯示「鬧鐘設定尚未更新完成」
    （[產品決策](PRODUCT_DECISIONS.md)）。對抗式審查再修三點：①提早響鈴的時間改取排程時記下的實際響鈴，不用現在的
    提前分鐘回推；②每週排程在檢查點到原定時間之間被重新登記時，依新的重複鬧鐘時間判斷今天，今天已沒有鈴聲就警示；
    ③畫面時鐘在公告或排程更新時立刻刷新，避免最多 30 秒的假警示。同一審查找到三個既有的排程問題（每週排程在這段時間
    改設定會吃掉今天的鈴、冷啟動後可能響兩次、停班停課刷新在這段時間反覆重新登記），另開任務處理，不在 1.8.0 這次改。
    （**2026-09-30 已修正並併入 1.8.0**，見本節「2026-09-30：修正檢查點到原定時間之間的三個既有排程問題」一點。）
  - 測試（主卡改為接下來的早上，含審查修正）：iPhone 17 Pro 上 449 項全過，略過 `MembershipStoreKitTests`（同下）。
    標題依擁有者決定改為「下次鬧鐘」＋日期（英文 Next alarm），不寫「今天」。
    手機待確認：凌晨打開 App 標題是「下次鬧鐘」、天氣卡「今天的天氣」；有停班停課時主卡寫「今天 7:30 的鬧鐘因臨時停班／停課略過」。
  - 測試（`8e07321` 當時）：iPhone 17 Pro 上 423 項全過（含今天那一行的新測試；略過 `MembershipStoreKitTests`：在這台模擬器上第一項就卡住，同上方的
    StoreKit 環境問題，送審前在 Xcode 裡重跑）。

- **2026-09-28：權益已決定——月訂閱與買斷都包含臨時放假規則，免費不含**（[產品決策](PRODUCT_DECISIONS.md)）。
  - 工作樹已改：伺服器 `deriveEntitlements` 與 iOS `MembershipEntitlements.valid(at:)`／本機 StoreKit 讀取的
    `temporaryClosures` 改為買斷或訂閱任一有效；會員頁每張付費方案卡都列「颱風臨時放假」，「買斷已涵蓋其他權益」
    按鈕文字拿掉；鎖頭一行（現在只有免費會看到）改為「訂閱或買斷可使用臨時放假規則」。測試同步更新。
  - Sandbox 會員服務正隨此變更重新部署。正式會員服務 `rainyclock-membership` 當時尚未重新部署
    （**2026-09-30 已部署 `rainyclock-membership-00006-hnb`**，見上）；權益以伺服器為準，不部署的話買斷使用者在 1.8.0 會看到
    鎖住的開關。1.7.1 的 gate 為 false、不讀這個欄位，可以先部署。
  - `appstore-metadata.md` 的 1.8.0 What's New 與審查說明已改成定案的方案說法，方括號備註已刪除。
    ASC 買斷／月訂閱的商品說明若要列出臨時放假，由擁有者在 ASC 修改。

- **2026-09-28：1.8.0（38）開閘與送審準備已提交（`8031f51`），伺服器 sandbox 堆疊上線（`df5ec48`、`7c9b684`）。**
  - App：`supportsTemporaryClosures = true`；版本 1.8.0（38）；`DayOffServiceURL` 為正式網址，**所有 Debug build
    改走 `DayOffSandboxServiceURL`**（Debug 的推播 token 是 APNs 開發環境，不能登記到正式）。
  - 資料來源標示：設定、地圖、鬧鐘頁的停班停課說明與時效性通知都標人事行政總處／NCDR、政府資料開放授權與來源更新時間；
    示範地圖不標來源。
  - 方案不含此規則時（當時是免費與買斷；9/28 決定後只剩免費）不再靜默失效：開關鎖定並顯示說明；已存的設定保留、仍可關閉；
    「未套用」提示依排程實際使用的權益判斷。權益對應本身未改，仍待擁有者決定（已被上方 9/28 決定取代）。
  - 「查看地圖示範」在所有 build 都可進入、不需購買，給審查人員看停班停課長什麼樣子。
  - 隱私政策新增「天災臨時放假」一節（中英）；`appstore-metadata.md` 有 1.8.0 What's New 與審查說明草稿，
    兩者都不指名方案，審查說明裡的方括號備註要在擁有者決定權益後改寫再貼。（9/28 已改寫，見上。）
  - 伺服器：`NCDR_SOURCE=fixture` 只允許 sandbox namespace；`deploy/fixture.sh set --county … --district …`
    寫一則測試公告並立即推播。已實跑一次板橋區公告並清除。
  - 測試：iPhone 17 Pro 上 408 項全過（除 `MembershipStoreKitTests`）；**`MembershipStoreKitTests` 在這台模擬器的
    StoreKit 測試環境初始化失敗（`SKInternalErrorDomain 3`，App 程式執行前），送審 archive 前要在 Xcode 裡重跑。**
    dayoff-service 120 項（Emulator 全過）。
  - 還沒做：**真機驗證**（見 `dayoff-service/DEPLOYMENT.md` 的 sandbox 手機步驟）、擁有者的權益決定（9/28 已完成）、
    正式會員服務重新部署（9/30 已完成）、ASC 隱私問卷與截圖、archive／上傳。

- **2026-09-24：主畫面／鎖定畫面「明天」widget 也納入 1.8.0**，在 `ios/widget` 分支，現為
  **1.8.0（38）**；見本節末「主畫面／鎖定畫面 widget」小節。`supportsTemporaryClosures` 仍為
  `false`，下方開閘條件不變。（9/28 `8031f51` 已開閘；widget 已於 10/1 合入，見本節「2026-10-01：`ios/widget` 合入 1.8.0 線」一點。）
- **工作樹已全部提交到 `ios/main`**（四個 commit：App 與測試、weather-proxy 會員後端、
  dayoff-service 與天災文件、其餘文件與素材）。1.7.0（34）送審的原始碼從此有 git 紀錄；
  之前自 9/10 起 110 個檔案都只在本機。變體 PNG 的重複 `.zip` 已 gitignore，其餘 `docs/`
  素材照常發布到 GitHub Pages。
- **使用者決定：停班、停課兩者都勾時是 OR**，任一公告符合即略過。`DAYOFF-SPEC.md` 升到
  **v3**，`dayoff-fixtures.json` 的 `decide-08` 由 `ring` 改為 `suppress`，
  `DisasterSuspensionEvaluator` 與設定頁說明文字同步改為 OR。Android 尚未實作，
  升版只是給它的交接訊號。
- `AppEnvironment.supportsTemporaryClosures` 仍為 `false`；1.7.0 在審，版本號不動。
  **dayoff-service 已於 2026-09-24 重構為做法一（`d0e80ab`）**：Cloud Scheduler → Cloud Run Job
  `rainyclock-dayoff-poll`（抓 NCDR、寫 Firestore、推播）＋ request-only Cloud Run 服務
  `rainyclock-dayoff`；狀態全在 Firestore `dayoff-production`，無磁碟、無常駐程序。設計由
  三位設計者／三位評審／合成產生，實作經三位對抗式審查（8 項確認並修正）。測試 107 項：
  純本機 100 過 7 略過，Firestore Emulator（Java 21）107 全過。雲端已建：資料庫、四個 TTL、
  兩個索引豁免、兩個空 secret（`dayoff-ncdr-api-key`、`dayoff-apns-key`）。
- **2026-09-24 上午已上線（fetch-only）**：使用者跑 `deploy/iam.sh` 建好服務帳號與 IAM 後，服務
  `rainyclock-dayoff`（`https://rainyclock-dayoff-510427696731.asia-east1.run.app`）、Job
  `rainyclock-dayoff-poll`、Scheduler `*/5` 都已部署；第一次執行後 `/health` 200 `ready`，
  `/v1/suspensions` 回 8 月下旬颱風的 14 則真實公告。**資料來源用 `NCDR_SOURCE=open-data`**（`3c227c4`）：
  NCDR 會員只發給公務／公司／學校信箱，個人申請不到；改用 data.gov.tw 資料集 20457 登錄的免金鑰
  網址（政府資料開放授權；NCDR 公告 3/31 下架但 9/24 仍正常）。這是明確設定，不是備援。
  之後同日：`run.invoker` 補上、Scheduler 自動觸發驗證通過；APNs `.p8` 掛上、`pushConfigured:true`，
  第一次廣播對零台裝置走完 `done`；三個記錄指標、email 通知通道與三個告警 policy 建好；暫停 Scheduler 實測，absence 告警約
  20 分鐘後寄達 `shukaihu@icloud.com`，已恢復。**尚未**：真機推播驗證（等 1.8.0 開閘）。指令與逐條執行紀錄見
  [dayoff-service/DEPLOYMENT.md](../dayoff-service/DEPLOYMENT.md)。
  1.8.0 開閘前仍缺：把服務網址填入 `DayOffServiceURL`、確認正式 build 的 push capability、
  真機驗證（晚間公告、重啟、低耗電、關背景更新、強制結束、撤銷、關閉後恢復、
  **可見推播在 App 關閉時被擴充功能改寫**）、
  恢復設定入口與方案文案、發布 [1.8.0 備忘](1.8.0-DEFERRED-DISASTER.md) 的隱私條款、
  決定買斷是否包含此功能（2026-09-28 已決定：包含）。
- 本輪驗證：Debug 建置 0 警告；dayoff-service 52 過；weather-proxy 186 過 3 略過（無
  Emulator）；iOS 全套約 339 項，用 `RainyClock Membership Local` scheme 且**簽章**跑才
  全過 —— `CODE_SIGNING_ALLOWED=NO` 會讓 3 項 Keychain 路由測試失敗，一般 `RainyClock`
  scheme 會讓 StoreKit 測試碰真商店並在模擬器彈出 Apple ID 登入框。
- **2026-09-23 下午：使用者看過模擬器推播截圖，確認作法 B 的結果「很好」，正式納入 1.7.1 範圍（現為 1.8.0）。**
  模擬器以 `simctl push` 送 alert 模式 payload，App 顯示本地化橫幅「停班停課公告已更新」。
  這只證明 payload 與權限流程；擴充功能是否被喚醒、改寫是否生效，仍要真機用真 APNs 驗證。
  橫幅只見標題、未見正文，真機驗證時一併確認 `body-loc-key`。
- **2026-09-23：推播改為作法 B。** dayoff-service 新增 `APNS_PUSH_MODE=alert`（預設）：對所有裝置
  廣播同一則可見推播、無位置資料、collapse 成一則、10 小時過期；`/health` 回 `pushMode`。iOS 新增
  `RainyClockDayOffNotification` Notification Service Extension、App Group
  `group.com.shukaihu.RainyClock`、Time Sensitive entitlement；`DayOffSharedState` 由 AlarmViewModel
  在儲存設定與排程摘要時鏡射（有效設定，gate 仍生效），`DayOffPushContent` 用同一個評估器把
  通知改寫成符合／相關／無關／不改。設計見 [DISASTER-PREVIEW.md](DISASTER-PREVIEW.md)。
  **尚未在真機驗證**：擴充功能需要真的 APNs 推播才會執行；模擬器無法收 APNs。
- ASC 審查結果本輪未讀到（隔離瀏覽器為登入頁，Gmail 無 Apple 信件）。
  `RainyClock-dayoff-preview/` 工作樹每個檔案都比主工作樹舊，可移除。

### 主畫面／鎖定畫面「明天」widget — 2026-09-24

- **是什麼：** widget 名稱「下次鬧鐘／Next Alarm」（`kind` 不變）。顯示下一次鬧鐘幾點響、為什麼（下雨提早、
  假日、週末、停班停課、路線未設、天氣過期／失敗、排程待更新）：午夜到今天響鈴前是**今天**的，響過之後
  是明天的。規則與 App 鬧鐘頁的明天卡片（2026-09-29 起是描述「接下來的早上」的主卡，標題「下次鬧鐘」）共用
  `TomorrowWidgetSnapshotBuilder`（reason／notice／issue），
  停班停課走同一個 `DisasterSuspensionEvaluator`，widget 不自己判斷。尺寸：主畫面 small、medium；
  鎖定畫面 rectangular、circular、inline。放在既有 `RainyClockAlarmWidget` 擴充功能，所以**只有 iOS 26+**；
  iOS 17–25 看不到，`TomorrowWidgetPublisher` 不動作。App 仍是 iPhone only。
- **資料流：** App 把 Codable snapshot 寫進 App Group `group.com.shukaihu.RainyClock` 的
  `tomorrowWidgetSnapshot.v1`（天災擴充功能用 `dayOffSharedState.v1`，同 group 不同 key）並 reload
  timeline；前景、背景 BGTask、推播喚醒都會 publish。snapshot 先算好下一個邊界（天氣過期、午夜、
  提早點、響鈴），第二個午夜後改為「開啟 App 更新」。**widget 本身不連網**：無 WeatherKit、MapKit、
  定位、廣告 SDK（LevelPlay 只連 App target），不存地址或路段名稱（有測試）。隱私營養標籤不用改；
  widget 自帶 `PrivacyInfo.xcprivacy`（UserDefaults 1C8F.1）。DEBUG 的 `-widget-demo` 範例不進 Release。
- **分支：** `ios/widget`，worktree `/Users/shukaihu/Code_Project_Local/RainyClock-widget`。**尚未合回
  `ios/main`**（**2026-10-01 已合入 1.8.0 線**，見本節「2026-10-01：`ios/widget` 合入 1.8.0 線」一點），因為 1.7.0／1.7.1 可能還要從 `ios/main` 出 build；只做 `ios/main` → `ios/widget`，
  不可反向。今天合過三次：`8a29847`（1.7.0（36）＋作法 B）、`1ce7bf5`（1.7.1（37）地址修正＋
  dayoff-service absence 告警；只有版本號衝突，ContentView／AlarmViewModel／字串改的是不同段落）、
  `1d3d91f`（1.7.1（37）上傳紀錄，僅文件）。
  之後 `ios/main` 每多一個 commit 都要再合進來，否則 1.8.0 archive 會少掉它（例如 1.7.1 的地址建議）。
- **版本：** 本分支 **1.8.0（38）**。`43bedcf` 原設 1.8.0（37），但 `ios/main` 的 1.7.1 也是 37，兩邊
  相同時合併不會衝突、沒人會發現，故 `da9105e` 改 38（1.7.1（37）已於 15:00 上傳 TestFlight）。
  `Info.plist` 與 11 個 `MARKETING_VERSION`／`CURRENT_PROJECT_VERSION`（App ×3、AlarmWidget ×3、
  DayOffNotification ×3、tests ×2）一致；建置後三個 bundle 都是 1.8.0（38）。`-ObjC`、`LevelPlayAppKey` 未動。
- **合併審查修正（`b54483d`）：**
  - 圓形鎖定畫面的略過字曾被改成「停班課」，已改回**「停班」**：這是使用者 9/23 看過截圖後的決定，
    只停課時也寫「停班」，旁邊的長方形 widget 會寫「停班／停課」。英文 `Closed` 本來就中性。
    （**2026-10-01 起圓形暫時不寫「停班」**：圓形放不下 DAYOFF-SPEC §7 要求的資料來源與更新時間，所以不報停班停課，
    改寫一般的「不響」；字串保留，擁有者記下 §7 例外就能恢復。見本節「2026-10-01：`ios/widget` 合入 1.8.0 線」一點。）
  - `RainyClockDayOffNotification` 補 `PrivacyInfo.xcprivacy`（無追蹤、無收集、UserDefaults 1C8F.1），
    與 widget 一致。**`ios/main` 同樣缺**，1.7.x 若再出 build 要一起補。
  - `DisasterPushDelegate` 在 `completionHandler` 前同步 publish widget，與 BGTask 路徑相同（debounce 在
    App 被掛起前不會觸發）。目前 `supportsTemporaryClosures=false`，屬預先修正。（當時的狀態；9/28 `8031f51` 已開閘，
    合入 1.8.0 線後這條路徑是實際會跑的。）
- **建置／測試（`da9105e` 之後的程式碼）：** Debug 模擬器建置成功、0 錯誤；三個 bundle 都帶 manifest。
  `RainyClock Membership Local` 簽章、iPhone Air 模擬器（iOS 26.5，`8C5C0CD4`）：**420 項全過、0 失敗、0 跳過**
  （`-parallel-testing-worker-count 1 -skip-testing:RainyClockTests/MembershipStoreKitTests`，xcresult
  `DerivedData/Logs/Test/Test-RainyClock Membership Local-2026.09.24_15-12-07-+0800.xcresult`），含 widget
  31 項、`TomorrowAlarmStatusTests`、`AlarmViewModelSchedulingTests`（含 1.7.1 新增）、`DayOffPushContentTests`
  與全部 Disaster 測試。
  **`MembershipStoreKitTests`（7 項）在這台模擬器跑不了**：第一項 `testAskToBuyDoesNotUnlockBeforeApproval`
  一開始就彈出「登入 Apple 帳號」，App 啟動被 SpringBoard 拒絕、xcodebuild 無限等待，三次都一樣。
  會員程式與這些測試和 `ios/main` 完全相同（`ios/main` 的 395 項在 iOS 26.2 模擬器全過），判斷是
  iOS 26.5 模擬器環境問題，不是 widget 造成；送審前在 26.2 模擬器或真機補跑一次。
  另：預設兩個以上 clone 時多出來的 clone 會被 SpringBoard 拒絕啟動，照舊用 `-parallel-testing-worker-count 1`。
- **四項決定（使用者 2026-09-24 決定 D-A～D-D，理由與被否決的做法見 PRODUCT_DECISIONS「1.8.0「明天」widget 的四項決定 — 2026-09-24」一節；
  合併後它不在最上方了）：**
  - **D-A WeatherKit 標示（`0a746d9`）。** 只有 medium 顯示天氣資料（住家／公司天氣、降雨 %、依天氣畫的
    天空），天氣欄下方畫 Apple 官方組合標記：App 在已經連 WeatherKit 的地方（卡片的
    `WeatherAttributionView`、背景更新）下載 `combinedMarkDarkURL` 存進 App Group，下載前畫文字
    「 Weather」。天氣欄是 widget `Link`（`rainyclock://weather-attribution`），App 的 `onOpenURL` 開
    `legalPageURL`。依據：developer.apple.com/weatherkit/get-started「must clearly display the Apple
    Weather trademark ( Weather), as well as the legal link to other data sources」。其他尺寸（small、
    StandBy、長方形、圓形、inline）只顯示決定：「因雨提早 N 分鐘」（不帶 %）、一般日「照常響鈴」，small
    天空只在因雨提早時下雨、其他時候品牌深藍，StandBy 沒有天氣符號。過期／失敗／尚無預報是資料新舊，保留。
    （**2026-10-02 晚改：**「只有 medium 顯示天氣資料」與 small 的天空已被取代——small 也依預報畫和 medium 同一片天空，畫的時候帶
     Weather 標記；small 的文字、StandBy 與鎖定畫面照舊。見「1.8.0 準備中」最上方一點。）
  - **D-B 過期（`48967b9`）。** BGTask 在鬧鐘工作後、發布 widget 前也抓明天天氣
    （`refreshTomorrowWeatherIfNeeded`，只在前 15 秒內開始、逾時一併取消、不登記也不改鬧鐘）。widget 的
    snapshot 在天氣滿 3 小時的那一秒切成「天氣資料需要更新」。
  - **D-C 今天（`b1d7caa`，snapshot 版本 2）。** 午夜到今天響鈴（略過的日子到原本時間）所有尺寸顯示「今天」
    ＋時間＋原因，snapshot 事先算好，App 不用醒著。時間是 AlarmKit 真的會響的：已登記的響鈴；週登記在
    今天檢查點之後才做的，若今天那一格還沒到也算；設定改了但重新登記失敗時是仍在的舊登記（標「鬧鐘設定
    尚未更新完成」）。今天的項目不帶預報，medium 在今天不畫天氣欄與標記。（2026-10-02 起改：中型今天也畫天氣欄，
    見「1.8.0 準備中」最上方一點。）
  - **D-D 沿用的提早（`c5f146b`）。** 週鬧鐘提早響過後隔天仍在同一時間響：顯示這個時間，但在隔天自己的
    預報決定前說「等待明天預報」（今天的項目「等待今天預報」），卡片共用同一規則；同一天的預報決定、只是
    過期的提早仍說「因雨提早」。兩種情況都有單元測試。
- **刻意和卡片不同（寫在 `TomorrowWidgetSnapshotBuilder` 開頭）：**
  1. **過期警告：** widget 天氣超過 **3 小時**才警告，卡片仍 **30 分鐘**。widget 整天掛著又不能自己更新；
     卡片點開才看、會自己更新。鬧鐘決定（`TomorrowAlarmStatus.resolve`）仍用 30 分鐘，沒改。
  2. **今天：** widget 午夜到響鈴前講今天，卡片整天講明天（在 App 裡看的是要改什麼，今天已經登記了）。
     （**卡片那半句已被 9/29 主卡規則取代**：午夜後卡片也講今天、標題「下次鬧鐘」、到原定時間才換；見本節「2026-10-01：`ios/widget` 合入 1.8.0 線」一點。）
  3. 延伸：跨午夜的提早（00:10 在前一晚 23:40 響）響過後到午夜前，widget 維持響之前的項目，不改口說
     「明天 00:10 照常響鈴」；卡片那幾分鐘仍照舊。（合併後卡片那幾分鐘顯示「已響鈴 23:40」。）
- **實作後審查與修正（`1e106d0`）：** 15 項意見逐項對照程式，14 項屬實已修，1 項與另一項重複：
  - 屬實：重開 App 後離線重新登記把前一天的提早記成今天的（改看 `decisionNormalAlarmDate`，1.8.0 以前的
    摘要在啟動時補上；**這會改變登記**：重開後離線重新登記的早上，沒有預報決定過就用原本時間，與 App
    一直開著時一致）；跨午夜提早響後說 00:10 照常響鈴；重新登記失敗時今天顯示新設定的時間；檢查點後
    的週登記藏掉今天真的會響的那一格；今天的項目帶前一晚的預報卻不警告；著色／透明主畫面標記消失
    （改永遠用白字深色版、只下載這一版）；VoiceOver 點不到法律頁連結（天氣欄改成獨立的連結元素＋提示）；
    標記列把太陽光芒擠到「晴天」上（太陽改畫在天氣欄兩列之間的空隙）；送審草稿描述錯誤（已重寫，見下）；
    small 在非雨天畫晴天（改深藍；2026-10-02 晚起改跟預報並帶標記）；今天的項目天氣欄空白（今天不畫天氣欄；2026-10-02 起改為有預報或提示就畫）；medium 同時寫
    「等待明天預報」與「尚未取得明天天氣」（左邊不再重複）；widget 叫「明天的鬧鐘」卻顯示今天（改名）；
    DEBUG 範例看不到標記兩種狀態與今天的其他原因（已補）。
  - 重複：第 14 項「VoiceOver 點不到法律頁」與第 7 項同一件事，一起修。
- **DEBUG 範例（`-widget-demo`）：** 情境 `carriedOver`、`todayRain`、`todayNormal`、`todaySkipped`、
  `todayCarriedOver`、`todayHolidayNamed`、`todayHolidayUnnamed`、`todayManualSkip`、`todayManualRing`、
  `todayUnselectedWeekday`、`todayClosure`，2026-10-02 加 `todayStale`、`todayWeatherFailed`、`todayForecastUnavailable`
  （也都在 `tour` 裡）；標記：畫面上「mark: Apple image／text
  fallback」兩個按鈕，或啟動參數 `-widget-demo-mark image|text`（image 要 WeatherKit 能連）。
- **建置／測試（`1e106d0`）：** Debug 模擬器建置（簽章）成功、0 錯誤。`RainyClock Membership Local` 簽章、
  `8C5C0CD4`（iOS 26.5），`-parallel-testing-worker-count 1 -skip-testing:RainyClockTests/MembershipStoreKitTests`：
  **440 項全過、0 失敗、0 跳過**（原 435 ＋ 審查新增 5：跨午夜提早、舊登記、檢查點後的週登記、離線重新
  登記（真的 `AlarmViewModel`）、今天不畫天氣欄——2026-10-02 起改），xcresult
  `DerivedData/Logs/Test/Test-RainyClock Membership Local-2026.09.24_22-41-42-+0800.xcresult`。
  **還沒做的驗證：** 主畫面／鎖定畫面實際加 widget 看畫面（medium 標記列：圖與文字兩種狀態、太陽位置、
  著色與透明主畫面、點天氣欄開法律頁、VoiceOver 讀到連結）；這一輪只有單元測試與建置。
- **送審 1.8.0 前 widget 還欠：**
  1. **（你要做）widget 的 App ID 開 App Groups。** `com.shukaihu.RainyClock.AlarmWidget` 唯一的 profile
     （`6932dac7`，7/27）沒有 application-groups，1.7.0（36）archive 裡的 widget entitlements 也沒有；
     App 與 DayOffNotification 已有。在 Xcode Signing & Capabilities（team `MQJ88U9NAJ`）或開發者網站
     Identifiers 勾 `group.com.shukaihu.RainyClock`，archive 用 `-allowProvisioningUpdates`，再用
     `codesign -d --entitlements -` 確認 appex 帶 group。否則 archive 失敗，或 widget 永遠停在「開啟 App」。
  2. **真機驗證（TestFlight 1.8.0）。** 開一次 App 後 small／medium／鎖定畫面顯示真實鬧鐘；改時間、背景
     更新後會變；午夜後顯示「今天」、響過換明天（39 起中型今天的項目也有天氣欄）；medium 看得到  Weather（官方圖下載前後各一次）、點天氣欄
     開 Apple 法律頁、VoiceOver 讀得到連結；著色／透明圖示下標記仍在；gallery 兩種語言、五個尺寸、
     StandBy 日夜（紅）、12／24 小時、換時區。（40 起 small 畫預報天空時也有標記，著色／透明與 StandBy 下 small 沒有天空也沒有
     標記；要看的項目見「1.8.0 準備中」最上方一點。）
  3. **（你要核准）送審草稿。** `appstore-review-notes-1.8.0-DRAFT.txt` 與 `appstore-metadata.md` 的 1.8.0
     節已依 D-A～D-D 重寫：widget 叫「Next Alarm」、今天／明天、「等待明天預報」、天氣只在 medium、標記在
     天氣欄下方、點天氣欄開法律頁；What's New 兩種語言也提今天與等待明天預報。備註 3,824 字（含開閘段落
     3,994），上限 4,000。1.7.0 的「不是主畫面 widget」與 2.1(a) 回覆 1.8.0 起不可沿用。最終文字由你核准後再貼。
     **（2026-10-01 起這段過時：）**審查備註草稿只有 `appstore-metadata.md`「Version-specific note for 1.8.0 (38)」
     一份，是事實版、超過 4,000 字（含停班停課、總開關、widget 三段），要另外重寫再核准；`.txt` 已標 SUPERSEDED、
     還寫著停班停課沒開閘，不要貼。上面的 3,824／3,994 字是 `.txt` 當時的字數。
     **（2026-10-02 晚：）**「天氣只在 medium、標記在天氣欄下方」也不再成立：small 畫預報的天空並帶標記，審查備註那一句已在 build 40 版改寫，
     見「1.8.0 準備中」最上方一點。
  4. **`MembershipStoreKitTests`（7 項）在 iOS 26.2 模擬器或真機補跑。** 在 26.5 模擬器第一項就彈 Apple 帳號
     登入、xcodebuild 無限等待（見上）；會員程式與 `ios/main` 相同。
  - 其他：Apple 對「value-added」產品另要求標  Weather 並註明資料已修改；非 medium 的「因雨提早」是否算，
    依 D-A 不加標記，送審被問再議。（2026-10-02 晚起 small 畫預報天空時已帶標記；沒有天空的 small 與鎖定畫面仍照本句。）1.7.1 與 1.8.0 的送審順序（build 38 兩種都成立；**已過時**：1.7.1 已於 9/26 上架）。Archive 後 Organizer →
    Generate Privacy Report 確認三份 manifest。ASC 新增 1.8.0 版本頁。選擇性：`privacy-policy.html` 加一句
    widget 只顯示本機資料；`.disfavoredLocations([.carPlay], for: [.systemSmall])`。

> **下一個 AI 請先讀 [2026-09-23 iOS 交接檔](HANDOFF-IOS-2026-09-23.md)。**
> [9/22 交接](HANDOFF-IOS-2026-09-22.md) 與以下時序保留為歷史背景；目前已退審並交付 build 35，
> 不可沿用舊「34 等待審查／未有 35」狀態。此次交接整理僅改文件，未再建置、部署或發布。

## ASC 1.7.0（34）已由使用者提交審查 — 2026-09-21

- 使用者提供 ASC 成功頁「已提交 4 個項目」。前一張草稿截圖已確認四項為
  **iOS App 1.7.0（34）、RainyClock Plus 訂閱群組、RainyClock Plus Monthly、
  RainyClock One-Time Purchase**；年訂閱未包含在本次提交。
- 使用者已接續補入商品審查圖片並將兩個商品加入同一份提交；先前「缺 IAP
  圖片／只有兩項草稿／尚未送出」是歷史狀態，不再當作目前阻擋。
- 目前可確認的是**提交成功，尚無審核通過或公開上線證據**。先前已保存手動
  發佈設定；本輪未改發佈方式，也未代為提交、發布或建立定時監看。
- 6.5 吋舊圖是否移除、聯絡欄位最後內容未再次讀回，不由提交成功推定其結果。
  TestFlight 價格差異與其他未完成的實機驗收仍保留；送審成功不等於功能驗收通過。
- 本輪只依使用者提供的 ASC 截圖更新文件，未修改程式、重新建置或部署。

## ASC 1.7.0（34）已加入送審草稿，尚未送出 — 2026-09-21 晚間

- 使用者已手動上傳截圖目錄的原始 PNG。ASC 的 **iPhone 6.9 吋**繁中與英文均已讀回
  六張新版圖；繁中順序為 `01-alarm`、`02-time`、`03b-route-collapsed`、`03-route`、
  `04-calendar-settings`、`05-alarm-calendar`，英文前四張相同、最後兩張順序相反。
  **6.5 吋仍是舊圖**：繁中 `C1/C2/C3`、英文 `E2/E1/E3`，不能記成全部尺寸已更新。
- 1.7.0 版本草稿已選擇並保存 **build 34**；App 已加入 **9 月 21 日 22:23 建立的
  App Review submission 草稿**，仍未正式提交、未公開發布。手動發佈設定保留。
- 一般審查說明已在 ASC 保存並讀回，使用
  [build 34 英文說明](appstore-review-notes-1.7.0-34.txt)，取代舊 build 30 草稿。
  其中明示 TestFlight 價格差異、廣告限制及尚未完成的端到端驗收。
- 月訂閱與買斷的審查備註均已保存；各自按「加入審查」皆被明確擋下：
  **「你必須為審查資訊新增截圖。」** 下一步是為兩商品各手動加入 IAP 審查圖，
  再重新檢查可加入狀態。一般商店截圖不會自動填入商品的審查截圖欄。
- `RainyClock Plus` 訂閱群組已加入同一份 22:23 草稿；目前**恰為 App 1.7.0（34）
  與訂閱群組兩項**。Apple 阻擋最後提交：「新的訂閱群組須與該群組內的自動續訂型
  訂閱項目一同提交。」月訂閱仍因缺 IAP 審查圖未加入，買斷也未加入；年訂閱維持
  未提交，不應加入。補圖後須先加入月訂閱與買斷，再重讀提交檢查結果。
- 最後只讀核對 ASC 版本頁欄位，已確認**審查聯絡電話與 Email 均未填寫**。
  待使用者自行補齊，或明確授權沿用其聯絡資料；未代填、未在文件記錄個資。
  月訂閱審查區亦再次確認只有「選擇檔案」、沒有圖片，可接續手動補圖。
- 卡片 USD／Apple 原生付款 TWD 暫列疑似 TestFlight metadata 問題，尚未證實同一根因，
  也不保證正式安裝正常；本輪沒有據此要求新 build。沒有程式修改、建置、測試或部署。
  本節取代下方歷史中的「草稿仍為 30／新版商店圖尚未上傳」，其他驗收缺項仍保留。

## 商城價格真機結果 — 2026-09-21 22:05，build 34

- 使用者已完成 TestFlight 1.7.0（34）、iOS 26.6.2 的比較：SK2 商店為 USA，
  方案卡為月費 $1／買斷 $10（USD）；SK1 商品同為 USD，商店由 unavailable 變為
  USA，查詢後 SK2 仍為 USA。同次回報的 Apple 原生月訂閱確認頁為 NT$10。
- **兩套商品查詢均未取得付款頁的台灣價格；SK1 不能作為本次問題的替代來源。**
  不能再把診斷狀態寫成「待使用者回傳」，或要求重複 refresh／重裝同類改版。
- 這是查價／商店資料與付款頁不一致的實機證據，與 Apple 公告的 TestFlight
  Storefront metadata 問題相符；尚不足以斷言精確的系統根因或正式 App Store
  安裝必定正常。截圖也不是購買已完成的證據。
- 台灣／美國定價、付款流程與會員權益不變。本輪只補驗收紀錄，未新增 build、
  未送審；隱藏價格、手動選地區或其他顯示替代方案尚未決定。

## 商城價格來源進一步查核 — 2026-09-21，build 34 已可內測

- 已透過裝置資訊確認 iPhone 16 Pro 安裝 1.7.0（33）；不能再一律要求升級 33。
  使用者再次確認規則為台灣商城 NT$10／100、美國商城 US$1／10，中文／英文不影響。
  價目規則沒有爭議，尚待解決的是 TestFlight 讀到 USA/USD、原生付款卻為 TWD。
- 新增「會員與方案 → ⋯ → 檢查測試商店價格」，只在已驗證 Apple Sandbox 或隔離
  Local StoreKit 測試顯示。比較方案卡商品、SK2 商店、SK1 商店與 `SKProductsRequest`
  取得的 `priceLocale`／價格，供同一 TestFlight、同手機帳號實測。
- 檢查不購買、不登入／刷新 Apple 身分、不變更權益；不記錄帳號、會員 ID、JWS 或
  裝置識別碼。SK1 每次查詢獨立，10 秒逾時，離開可取消。正式方案價格與付款仍走原流程。
- 此為診斷工具，**不是已修好美元顯示**。SK1／SwiftUI ProductView 沒有官方保證可
  避開同類 TestFlight metadata 問題，不能任選較像正確答案的幣別、用舊交易價格冒充
  目前售價，或以手機語言／GPS 推定商城。測試／上傳結果見 [驗收](1.7.0-RELEASE-READINESS.md)。
- 27 項測試（含實際 Local StoreKit 兩套查詢）全過，0 失敗／跳過；隔離模擬器已
  檢視新頁版面。Release archive 通過，21:58:05 上傳成功，Apple 已完成處理，
  內部 `SKHU tester` 可更新 1.7.0（34）。未改後端、未由 Xcode 覆蓋手機、未送審。

## TestFlight 方案價與 Apple 付款價不一致 — 2026-09-21 21:19

- 使用者截圖確認 Apple 付款視窗已能開啟，原生視窗為 **NT$10／月**，App 卡片仍是
  **$1／月**。截圖未確認 build number，不能把這次成功直接歸於 build 32。
- 實機 iPhone 16 Pro 為 iOS 26.6.2。Apple 在
  [iOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)
  列出 TestFlight `Storefront` metadata 可能錯誤的修正（181766819／FB23646993）。
  此為相符的系統問題線索，**不是已證明本機必然同一 bug**；先前診斷 `USA/USD`
  只證明 API 回報值，不能推定付款帳號其實是美國。無須以語言／GPS 改寫價格。
- build 33 已完成：補會員頁返回、前景、付款／恢復購買結束後商品更新；比對抓取前後
  商店 ID／幣別，矛盾則丟棄並最多重試一次；重疊要求共用最新查詢。
  價格錯誤與會員結果分開，不清權益，購買先保存再更新價格。
- 合計 81 項 focused／Local StoreKit 測試通過，0 失敗、0 跳過，獨立覆核及 Release
  archive 通過，21:35:10 已上傳，約 21:39 Apple 處理完成，內部 `SKHU tester` 可更新。
  尚未送審／公開發布。
- 若系統持續一致地回傳錯誤 USA/USD，本修法仍無法辨識付款頁實際 TWD；
  需真機驗收，不承諾重新抓價已修好系統問題。進度見 [驗收](1.7.0-RELEASE-READINESS.md)。

## TestFlight（31）已定位重複 Apple 認證 — 2026-09-21 21:00

- 真機已成功建立會員：後端 challenge／session 均 200。接著手動同步因重做 Apple
  refresh 失敗，診斷碼 `StoreKit.StoreKitError/3` 在 iOS 原生 enum 測試中對應
  `userCancelled`；這表示認證流程未完成，不能當作後端斷線或推定使用者主動取消。
- 同畫面 `store=USA · currency=USD`，StoreKit 回報美國商品；21:19 已確認原生
  付款視窗卻為 TWD。台灣 ASC 定價仍 TWD 10／100，不能用介面語言改寫價格。
- 修正版（32）已完成：先驗證 shared App Transaction，同帳號有效 session 直接向後端
  對帳；只有必要時再要求 Apple refresh。AI 結果查詢不再重複完整同步。70 項 focused
  tests、獨立程式覆核與 Release archive 均通過。21:16:15 上傳成功，Apple 已完成處理，
  內部 `SKHU tester` 可更新。詳細證據、驗證邊界及上傳狀態見
  [上傳與接線驗收](1.7.0-RELEASE-READINESS.md)。真機升級與購買流程仍待確認。

## TestFlight 會員同步與美元顯示待釐清 — 2026-09-21 20:40 後

- TestFlight（30）重新整理後仍顯示美元，按 Choose plan 約轉圈 10 秒、沒有 Apple
  付款確認頁。ASC 即時讀回台灣月訂閱 TWD 10／買斷 TWD 100，archive 30 亦確認沒有
  本機 StoreKit 設定；新會員服務未見同期 HTTP 請求，尚不能歸因為帳號地區或價格設定。
- 準備（31）改善錯誤可見性及最小診斷：尚未驗證不再誤顯示 Free plan，手動失敗
  明確提示階段與安全錯誤碼；保留所有 Apple／App Attest 驗證與 StoreKit 當地定價。
  50 項 focused 測試與 Release archive 通過，錯誤 UI 已在隔離模擬器驗收；20:57:26
  上傳（31）成功，Apple 已完成處理並提供內部 `SKHU tester` 測試；已保存診斷步驟。
  **不代表真機根因已修復，也尚未送審或公開發布**。
- 詳細證據與後續結果見 [上傳與接線驗收](1.7.0-RELEASE-READINESS.md)。

## 1.7.0（30）LevelPlay 官方回呼已通過，TestFlight 仍在核對 — 2026-09-21 晚間

- 使用者確認 LevelPlay 已儲存、同意將所選私鑰放入 Secret Manager。已建立
  `membership-levelplay:1`，只授予會員執行帳號此 secret 的讀取權限；不記錄私鑰值。
- verifier 已移除自行設定的 16 字元最低長度，仍拒絕空白／缺漏密鑰、驗證原字串簽章、
  固定獎勵數量與事件防重。後續又修正官方 `YYYYMMDDHHMM` 被誤當 Unix 時間的錯誤。
  最新服務為 `rainyclock-membership-00005-5pm`，100% traffic，health 200；48 項相關
  測試及 Firestore Emulator 全套 189 項均通過、零跳過。
- 官方 Dashboard callback 使用隔離 TestFlight fixture，沒有真會員／Apple 身分或購買。
  原官方通知修後重送 HTTP 200、入帳一次，相同通知重送仍一次；Dashboard 再測顯示
  **Your callback settings are valid**，新事件 141 ms / HTTP 200，只增加對應的一次。
  所有隔離測試資料已清除，LevelPlay 顯示 **Your S2S settings have been saved**、S2S On。
  此為官方回呼、持久入帳及防重驗收，不等同真機看廣告至生成的完整流程。
- 使用者回報生成保存及重播成功只扣一次，但新 Production／TestFlight 資料庫沒有
  對應會員／session／生成。手機安裝的版本確為 1.7.0（30），同版本的 Debug Sandbox
  仍可能使用舊端點；20:08 舊服務確有 challenge／purchases，不能據此推定是哪台手機。
  已請使用者直接由 TestFlight 開啟並同步會員。未把先前回報列為新後端完整驗收成功。
- 新商店 UI 中英文各 6 張、Local StoreKit 審查圖各一張已備妥，均 1320×2868；
  [截圖說明](appstore-1.7.0-screenshots/README.md) 明示真實 WeatherKit 與本機付款測試範圍。
  ASC 上傳被 Chrome 擴充功能的檔案 URL 權限擋住，已請使用者開啟；尚未上傳截圖。
  未提交 App Review／未公開發布。完整狀態見
  [上傳與接線驗收](1.7.0-RELEASE-READINESS.md)。下節 revision 2 是先前驗收快照。

## 1.7.0（30）最新驗收：TTS 已回傳音訊、刪除排程已驗證 — 2026-09-21

- 新會員服務目前 revision `rainyclock-membership-00002-m5j`，映像為
  `sha256:1cd2844a1b03b0714149aac28768df055b64203d7138c7820cf1def49ad806c3`。
  Production／TestFlight Sandbox 維持分庫、分身分與 production App Attest；舊 Debug
  Sandbox 另行隔離。詳細資源與驗收見 [1.7.0 上傳與接線驗收](1.7.0-RELEASE-READINESS.md)。
- 19:43 紀錄的 Cloud TTS 逾時已修正為美國供應商端點：英文 11.33 秒取得有效 2.89 秒
  PCM；繁中分類 1.269 秒＋合成 8.404 秒，合計 9.787 秒取得有效 3.091 秒 PCM。
  這是雲端供應商成功證據，**不是新 TestFlight 真機完整生成／保存／扣額度驗收**。
- 最終後端全套＋Firestore Emulator **184 通過、0 失敗、0 跳過**，證據
  `/tmp/rainyclock-membership-final-emulator-tests-20260921.log`；繁中真實 TTS 證據
  `/tmp/rainyclock-membership-zh-us-final-logs-20260921.json`。iOS 本輪 45 個不同測試及
  Release archive 已通過；沒有把模擬測試計為真實退款／續訂驗收。
- 刪除維護 Job／Scheduler 已部署，每 5 分鐘 OAuth 派送；實際 HTTP 200 與成功
  execution `rainyclock-membership-deletion-v9gc5` 對應受控 Sandbox 清理，音訊與
  session 已移除，Production 未寫入。詳見[維護紀錄](../weather-proxy/membership/MAINTENANCE.md)。
  尚待設定失敗／backlog 通知告警；受控清理不等於所有使用者刪帳 UI 均已驗收。
- 公開隱私政策已由 `main` commit `4bad86ac44733cb6b1a6cc86575c535d59a7baf7` 發布；
  HTTP 確認頁面日期「21 September 2026」，並有會員、AI 用量、保存與刪除揭露。
  ASC 隱私問卷亦已發布，11 種資料類型讀回無未完成警告：新增音訊、使用者 ID、購買、
  其他診斷資料均為 App 功能、與身分連結、不追蹤；其他使用者內容改為連結身分。
  裝置 ID、產品互動與廣告資料增加 App 功能並保留原廣告／追蹤設定，原概略位置、
  當機及效能項目維持原設定。
  ASC 繁中／英文商店文字已保存，build 30 掛入 1.7.0 草稿、手動發佈，內部 TestFlight
  群組為 `SKHU tester`。**未提交 App Review／未公開發布**。
- 剩餘阻擋：LevelPlay S2S 私鑰待使用者授權 Save、後續安全
  接線及官方測試 callback；新 TestFlight 真機會員認回、購買、AI 保存重下載、實際退款、
  關閉續訂／到期與重裝換機仍待驗收。正式廣告在 Sandbox／TestFlight 保持停用。
  首次 IAP 送審連結與最新 UI 截圖也需完成。防重摘要無自動到期的保留需求仍須審查。

## 1.7.0（30）已上傳，新會員正式／TestFlight 接線 — 2026-09-21 19:43

以下保留當時紀錄；其中 Cloud TTS 逾時已由上方最新驗收結果取代。

最新狀態見 [上傳與接線驗收](1.7.0-RELEASE-READINESS.md)。Release URL 已啟用、雙環境
後端已部署、兩個 Firestore 資料庫已建立。Apple 已完成 build 30 處理，並加入 TestFlight
內部群組。**未公開送審／發布**：Cloud TTS 真實生成逾時、LevelPlay S2S 尚待設定與驗收，
TestFlight 新接線仍須真機確認。以下 19:22「只有 Sandbox／URL 空白」為當時盤點，已由本節取代。

## 台灣月訂閱驗收與正式上傳盤點 — 2026-09-21 19:22

- 使用者真機截圖確認 Subscriber、月費 NT$10、買斷 NT$100、Subscribed 停用按鈕與
  有效至 19:26、Auto-renewal On、每日一次，並表示滿意。Firestore 該會員已驗證
  Sandbox monthly、status=1、autoRenewStatus=1、未撤銷；11:21 UTC 的 session、
  purchases 及 Apple notification 均200。5分鐘效期為 Sandbox 加速週期，非正式月費週期。
- 買斷與月訂閱購入、UI與後端權益已有實測。實際退款、關閉續訂／到期、換機／重裝
  恢復、每日 AI 成功保存／失敗與廣告 S2S 尚未全部端到端驗收。
- **尚不能直接正式送審收費版**：一般 Release 會員 URL 仍空白；雲端只有會員 Sandbox
  （Apple Sandbox＋development App Attest、TTS_DISABLED=1、未配置 LevelPlay 私鑰）
  與既有 weather 服務。正式會員服務尚未部署，測試服務目前無法履行付費每日 AI。
- TestFlight／App Review 使用 production App Attest，現有 development 驗證入口不能
  直接沿用；正式 Release 還須安全分流測試／正式 Apple 購買資料，隔離權益與資料。
- 既有本地 archive 為 9/16 建立的 1.7.0（29）、會員 URL 空白，不含 9/21 最新修改。
  後續完成服務與驗收後須提高 App／widget build number、重新封存／上傳，並將首次
  月訂閱、訂閱群組與買斷一併加入版本送審。未因使用者詢問可否上傳而執行正式部署／送審。

## Sandbox 桌面重開失效修正 — 2026-09-21 19:13 後

- 使用者切換台灣沙盒帳號、從手機重新開 App 後又見方案未開放與正式 banner。
  根因是測試網址及廣告隔離只存在於 Xcode launch arguments／environment；與購買資格無關。
- 新增專用 **Debug Sandbox** configuration，Sandbox scheme 的 Run 使用它並保留
  StoreKit Configuration=None；App 的 `DEBUG && MEMBERSHIP_SANDBOX` 固定測試端點，
  從桌面啟動亦有效。Xcode UI 同步移除快取的舊參數／環境變數；Test 仍 Debug、Archive
  仍 Release，一般版會員 URL 不變。沿用原 Sandbox keychain namespace，不重設會員／額度。
- Sandbox build 在任何啟動方式皆停用廣告；測試退款入口亦採相同組態判斷。Release
  忽略測試參數及編譯條件，無 DEBUG 即不能開測試端點。
- Storefront.updates 重新載入商品；同步會員失敗仍更新商品，購買前再載入當地商品，
  載入期間不沿用舊地區 Product，且較舊請求不能覆蓋新結果。切換 Apple 帳號仍須明確
  使用「⋯ → 同步會員狀態」取得已驗證新身份；不以地區變化冒充會員切換。
- Configuration／Membership／StoreKit **35 項通過、0 失敗、0 跳過**，紀錄
  `/tmp/rainyclock-sandbox-relaunch-tests-20260921.log`。Debug Sandbox 實機建置成功，
  `/tmp/rainyclock-sandbox-relaunch-device-build-20260921.log`，編譯確認 App 同時有 DEBUG
  和 MEMBERSHIP_SANDBOX。實際組態來源在非 DEBUG 編譯下另有 7 項隔離斷言通過。
- 使用者解鎖後 Xcode 已安裝啟動 iPhone 16 Pro（PID 91796）；再停止偵錯，以**零額外
  參數／環境變數**獨立啟動成功（19:20:51、PID 91802），隔秒測試後端 challenge 200，
  證實測試設定不再依賴 Xcode。紀錄 `/tmp/rainyclock-sandbox-persistent-launch-20260921.json`。
  台灣會員同步、當地價格畫面及月訂閱購買仍需使用者在手機完成；不把啟動成功當購買成功。

## 會員頁簡化與真機買斷驗收 — 2026-09-21

- 使用者 18:55 截圖確認 One-time member、會員編號、每日可用一次、買斷 Purchased，
  月訂閱已由買斷涵蓋。Cloud Run 10:54–10:55 UTC 的 session、purchases、Apple notification
  皆有 200；讀取 Sandbox Firestore 該會員確認 environment=Sandbox、有效 lifetime 交易。
  此為真機買斷實測證據，不代表月訂閱、退款、換機或 AI／廣告已全面驗收。
- 最新方案排序改為月訂閱在前、買斷在後，英文 **Monthly subscription**；上方標題與價格
  分兩行，避免長英文擠壓。ASC 英文顯示名稱亦已保存並讀回；既有買斷優先權益不變。
- 底下操作卡改收進右上角「⋯／會員管理」；同步、恢復購買、管理訂閱、刪除會員皆仍可達。
  訂閱卡保留到期時間與 Auto-renewal 狀態，點該列開 Apple 管理頁；Sandbox 顯示時間供
  加速續訂驗收，App 不自行變更 Apple 續訂設定。
- Membership／StoreKit **23 項通過、0 失敗、0 跳過**，
  `/tmp/rainyclock-membership-menu-tests-20260921.log`。另實機 Debug 建置通過，
  `/tmp/rainyclock-membership-menu-device-build-20260921.log`；Xcode Sandbox scheme 已重跑
  iPhone 16 Pro，新程序 PID 91590。
- 為退回測試買斷，DEBUG＋Sandbox 會員＋Sandbox launch 下新增「Refund sandbox purchase」
  管理選單入口，再檢查 verified 交易 environment=Sandbox 才開 Apple 退款表單。沒有直接
  修改後端權益；送出只表示申請，仍由已驗證撤銷交易／REFUND 通知更新。使用者確認
  已送出後，11:10 UTC Apple 最新簽章交易仍 revocationDate=null，Refund History 為空，
  通知歷史只見 ONE_TIME_CHARGE。Xcode 實機 console 有 Apple 退款表單 cancelled／
  unknown error，故**退款尚未驗收成功**。11:06 的通知 HTTP 200 不能單獨當退款證據。
  可先用另一個尚未購買的台灣 Sandbox 帳號測月訂閱；美國買斷保留，未清空 ASC 紀錄
  或手改付費權益。正式資料未變更。

## iPhone 會員測試啟動排查 — 2026-09-21

- 使用者實機的「Plans are not available for purchase yet」與 banner 表示本次沒有啟用
  Sandbox 配置，不代表商品讀取或付款驗證失敗；未配置時根本不載入商品。
- 已完成最新版 Debug 實機建置並安裝到指定 iPhone 16 Pro，含路線預覽收合；一般版
  會員網址未變更，Sandbox health 正常。使用者解鎖後於 18:50 成功以 Sandbox 參數與網址
  啟動，裝置工具確認 launched；手機價格顯示、會員同步及購買仍待實機畫面驗收。
  詳細紀錄與後續驗收見 [MEMBERSHIP-STAGING.md](MEMBERSHIP-STAGING.md)。
- 18:51 後續截圖雖有價格且無 banner，認證 sheet 卻標示 `Environment: Xcode`：
  僅證明 App 測試參數已生效，Apple 仍用先前 Local 交易環境，**不是 Sandbox 商品驗收**。
  已重新載入 Xcode 專案、將目前方案由 Local 切至 Sandbox，親自確認 Run → Options →
  StoreKit Configuration 為 None，再由 Xcode Run 成功啟動指定 iPhone 16 Pro。
  仍待使用者在 Apple sheet 確認 Sandbox 及完成同步／購買；OK 認證本身不授予付費權益。

## 買斷解鎖日曆、優先於訂閱 — 2026-09-21（最新權益）

- 使用者明確將月訂閱及買斷都設為移除 banner＋日曆；買斷永久持有當前權益。
  兩者並存顯示買斷會員，已有有效買斷不再允許重複月訂閱新購。真實 Apple 訂閱仍保留
  效期、續訂狀態與管理入口，不代為取消或宣稱取消。
- 使用者另行確認 AI 規則不變：付費共用每日一次，額外每次需廣告；免費仍初始一次。
  訂閱到期而有效買斷存在時，日曆繼續可用；只有已無日曆權益才採原安全重排銜接。
- 定價與地區沿用下節。臨時放假仍延至 1.7.1，本次不擴張其未來買斷資格。
- 後端 domain／HTTP **43 項通過、0 失敗、1 跳過**（缺 Emulator 的那一項）；
  `/tmp/rainyclock-lifetime-calendar-backend-20260921.log`。
- 本輪 iOS **61 項通過、0 失敗**：Membership／Configuration／StoreKit／AlarmSchedulingSettings
  第一批 55 項，加 MembershipScheduling 第二批 6 項；Simulator App 建置完成。
  紀錄：`/tmp/rainyclock-lifetime-route-ios-tests-20260921.log`、
  `/tmp/rainyclock-lifetime-scheduling-tests-20260921.log`。下節 28／8 是稍早移除年方案批次。
- Sandbox 已部署 **`rainyclock-membership-sandbox-00004-kkd`**，讀回確認 100% 流量。
  為保留其他 session 修改，以既有上線映像衍生僅變更 `service.js` 的 calendar 判斷，
  不整包部署工作目錄。映像內 5 項退款／到期等驗證通過；health 200 enabled=true、
  未授權 status POST 401，既有安全驗證及 TTS_DISABLED 保持。完整 digest／Cloud Build
  與紀錄見 [staging](MEMBERSHIP-STAGING.md)，正式 weather 未改，真機端到端未驗收。
- ASC 買斷英文、繁中說明已保存並重讀核對，加入日曆及每日 AI；價格不變，未送審。

## Route 設定樣式統一 — 2026-09-21

- 後續加入路線預覽右上角展開／收合箭頭（整列標題亦可點），預設展開；收合時隱藏
  地圖、距離與預估時間，保留標題。以獨立 AppStorage 偏好記住選擇，不改鬧鐘設定或
  底層路線計算；載入中或尚未設定地址時仍可收合，支援減少動態效果。
- 收合改動另行 Simulator 建置通過：`/tmp/rainyclock-route-collapse-build-20260921.log`。
  專用 iOS 26.2 模擬器實際驗證右上角點按、展開／收合與 App 重啟後記住收合狀態；
  展開後 Taipei Main Station → Taipei 101 的開車地圖、23 分鐘／6.7 公里正常顯示，
  再收合後地圖及兩個資訊列均消失。此次未另裝實機。
- Route 改用與 Time／Calendar 相同的 `SettingsEntryRow` 卡片，住家、公司、交通方式
  各有清楚入口；住家／公司各自開地址編輯 sheet，交通方式即選即保存。
- 保留路線地圖、距離與時間；移除 Route 頁面的天氣內容及專用載入工作。
  Alarm 的天氣預覽與鬧鐘排程需要的天氣查詢保持不變。
- SettingsCalendar 呼叫與會員提示文案同步修正。上方 iOS 61 項與 Simulator 建置已通過。
- 專用 `RainyClockMembershipTests`／iOS 26.2 模擬器視覺驗收：Time、Route 卡片列比對一致；
  Home／Work 編輯 sheet 均可開關，分別輸入 Taipei Main Station／Taipei 101，返回後值保留。
  選步行即關閉選單並同步主頁；地圖更新為 94 分鐘／6.1 km、兩端位置正確，Route 卡片
  與下方 tab 不遮擋。Route 無天氣區塊，Alarm 仍保留原本 Tomorrow weather。
- 本輪未驗證 autocomplete 建議點選，不宣稱所有路線操作都已全面驗收；未安裝實機，
  模擬器結果不代表 iPhone Sandbox 登入、購買或會員端到端成功。

## 會員定價改為月訂閱與買斷 — 2026-09-21

- 使用者最新指定美國 US$1／月、買斷 US$10；台灣 NT$10／月、買斷 NT$100。
  不再提供年訂閱優惠方案，取代下方 9/16 的三方案及舊價格。買斷日曆權益由同日後續
  決定更新，見上節；每日 AI 與 1.7.0 隱藏臨時放假的範圍不變，價格仍由 StoreKit 提供。
- ASC 已保存並重讀核對上述美國／台灣價格；月訂閱、買斷都只供應美國＋台灣共 2 地區，
  未來新地區自動開放 OFF。台灣價格獨立指定；其他地區價格尚未定案且未供應。
  詳見 [會員測試環境](MEMBERSHIP-STAGING.md)，未提交或正式發布。
- 9/21 使用者最新確認及附圖的兩列資料證實 **台灣、美國兩個 Sandbox 帳號皆已建立**。
  圖上標題／總數顯示 1 與兩列不一致，不以該數字否定使用者及兩列證據。先前空列表、
  台灣 1 筆及美國待建立皆為已取代的中間狀態；憑證由使用者保管，不存入 repo。
  帳號建立不代表已登入手機；真機商品讀取、App Attest、購買與會員認回仍待驗收。
- iOS 新購目錄及方案畫面只列買斷、月訂閱；年方案 ID 保留給已驗證歷史交易／恢復，
  新購入口不再提供。免費、買斷、月訂閱及歷史權益相容的重點驗證已完成：
  MembershipStoreKit／Membership 共 **28 項通過、0 失敗**，`xcodebuild TEST SUCCEEDED`，
  Simulator App 建置成功。紀錄：`/tmp/rainyclock-membership-two-plans-tests-20260921.log`；
  結果：`/tmp/RainyClock-Membership-Pricing-DerivedData/Logs/Test/Test-RainyClock Membership Local-2026.09.21_17-09-00-+0800.xcresult`。
- 後端方案／權益重點測試 **8 項通過、0 失敗、0 跳過**：
  `/tmp/rainyclock-pricing-domain-20260921.log`。此為較早定價批次本機驗證，當時未部署；
  後續買斷日曆 Sandbox 部署見上節，真機購買仍未驗收。
- 年方案 `6812814314` 已停止銷售，重讀供應管理確認 **0 個國家或地區**。
  買斷以美國 US$10 作全球基準調整，再把台灣手動固定 NT$100；重新開啟目前價格確認
  台灣在手動 1 地區、美國為其餘 174 自動群組中的 US$10。其他自動換算地區價格不等於
  已核准商品定價，且未開放供應。所有新價格與供應已保存；未送審。定價批次之後的
  買斷日曆 Sandbox 部署另記上節，正式會員並未部署。

## 會員獨立 Google Cloud Sandbox 已接入 Apple 金鑰 — 2026-09-16

- 使用者授權後在既有 `rainyclock` 專案建立 `membership-sandbox` Firestore Standard／
  Native／asia-east1、專用 Cloud Run、限定資料庫的 IAM、Secret Manager 身分密鑰、
  deny-all rules、7 組 TTL 與 PCM 免索引。原 weather proxy revision `00012-win` 保持不變。
- 使用者已建立 `RainyClock Membership Sandbox` IAP key；驗證後保存於 repo 外及
  `membership-sandbox-apple-iap` v1（asia-east1），專用 SA 可讀並掛載
  `/secrets/apple/SubscriptionKey.p8`。金鑰名稱不限制 Sandbox，限制由後端環境實施。
- 同一映像的 revision `rainyclock-membership-sandbox-00003-vsr` 已啟用：
  **公開 HTTPS invocation、`MEMBERSHIP_ENABLED=1`、`TTS_DISABLED=1`**；
  Apple／App Attest／session 認證仍強制執行。網址及配置見 [MEMBERSHIP-STAGING.md](MEMBERSHIP-STAGING.md)。
- 真實 Apple Sandbox `getNotificationHistory` 最初認證成功、回傳空歷史。ASC Sandbox
  通知網址已保存並重讀確認，Production URL 空白。等待設定傳播後，15:27:51Z 的 TEST
  請求成功，15:28:28Z 查詢 `sendAttempts=SUCCESS`；官方 SignedDataVerifier＋線上憑證
  查核確認真實簽章為 Sandbox／`com.shukaihu.RainyClock`／TEST。Cloud Run 確認
  `15:27:52.124678Z` 對應通知 POST 200（revision `00003-vsr`），TEST 通知串接已通過。
  先前四次 `4040007` 已解除；TEST 不建立購買／額度 ledger，也不代表 IAP 認回已完成。
  結果：`/tmp/rainyclock-membership-apple-notification-result.json`（無 JWS／token）。
  Cloud Run 證據：`/tmp/rainyclock-membership-apple-notification-cloud-log.json`。
- 9/16 當時尚無 Sandbox 測試帳號；9/17 使用者截圖已確認台灣及美國帳號均建立，
  目前待真機驗收，見上方最新狀態。
- ASC 初次盤點為零，後續已建 `RainyClock Plus` 群組 `22390056`，月方案 `6812814060`
  （1 個月）與年方案 `6812814314`（1 年）均設 level 1；已修正初建預設的 1／2 分級。
  非消耗型 `RainyClock One-Time Purchase` 為 `6812814810`；Product ID 見 staging 文件。
  9/16 當時使用者批准僅美國 Sandbox 測試，三商品儲存並核對月 US$1／年 US$10／買斷 US$5、
  USA only、未來新地區自動開放 OFF。年方案為預付 1 年，未設 12 個月承諾逐月付款。
  以上為當時歷史狀態；價格與年方案已由 9/21 決策取代。當時非美國地區均不可售，
  Apple 自動產生的對應價不是已批准正式售價。
  六筆商品與兩筆群組英文／繁中本地化已儲存並重讀驗證；群組名稱 `RainyClock Plus`，
  使用 App 名稱 `Rainy Clock`，精確商品文字見 staging 文件。
  UI「準備提交」，均未提交／發布；審查截圖未提供，家庭共享關閉。真機商品讀取與購買仍未測。
- 新 `RainyClock Membership Sandbox` scheme 只供 Debug 真機，無 `.storekit`、只接受 HTTPS
  origin；權益／session／App Attest Keychain 依測試網域隔離。這個明確測試模式完全停用廣告。
- 後端含 Emulator 151 項全過；最後 health／challenge 上限入口 18 項全過。
  iOS focused 27 項全過，廣告防護後配置 9 項全過，正常 unsigned Release 建置成功；
  正式 URL 空白，沒有 Sandbox 參數、網址或 StoreKit 測試 bundle 混進 Release。
- 本輪尚未安裝或啟動真機，App Attest、購買／認回、LevelPlay、AI 端到端均未測。
  Apple API 憑證可用不代表上述流程已通過；完整缺項見 staging 文件。
- 真雲端專用 Job 的 8 個並行交易驗證成功、測試紀錄已清理；未授權 Firestore 讀寫 403。
  7 組 TTL 皆 ACTIVE。啟用後 `/health` 200／`enabled=true`、challenge 200、缺少 session
  401、無效 Apple 簽章 401、舊 `/v1/tts` 404。先前 `00002-6bc` private／會員關閉
  的 503／IAM 403 是建立初期紀錄，已由此次啟用狀態取代。

## App Store Connect 商務資料提交後狀態 — 2026-09-16

- 使用者提供提交後截圖：台灣稅務、美國外國受益人證明及 W-8BEN 都「已完成」。
  銀行與付費 App 協議仍「正在處理」，DSA「審查中」；尚不能視為已可收費。
- **稍後實際讀取 ASC：付費 App 協議已「有效」，銀行帳戶已「使用中」。** DSA 本輪未重查。
  後續先準備買斷、月／年商品與會員後端設定，
  付費協議 Active 後執行 Apple Sandbox 真機驗證；會員啟用後需重新建置上傳。
  目前已上傳的 1.7.0（29）仍沒有會員服務 URL；後續 Sandbox 部署與商品草稿見上節，均未送審。

## 1.7.0（29）已上傳 App Store Connect — 2026-09-16 22:19

- 使用目前工作目錄的 RainyClock Release 封存；App／widget 都是 1.7.0（29），
  保留既有未提交修改。一般 RainyClock scheme，不含 StoreKit 測試設定或測試 bundle。
- **22:19:55 Apple 回覆 Upload succeeded / Uploaded package is processing；
  xcodebuild EXPORT SUCCEEDED、exit 0。** 尚未送審、發布或確認 ASC 後續處理完成。
- 封存確認正式 VoiceProxyURL、12 個預覽音檔、沒有 GAD keys，唯一嵌入 framework 為
  IronSource。MembershipServiceURL 仍空白；這不是會員付款正式開通版，颱風功能仍延至 1.7.1。
- 上傳僅有已知 IronSource.framework 缺少 dSYM 警告，不阻擋上傳，該 SDK 的 crash
  堆疊可能無法完整符號化。建置編號未自動增加。
- ASC 瀏覽器停在登入頁，未確認此帳戶的銀行／稅務／協議狀態；已查官方需求並補到
  `MEMBERSHIP-AND-PAYMENTS.md`。未代簽協議、填寫銀行／稅務資訊或部署會員後端。

封存：`build/RainyClock-1.7.0-29.xcarchive`。
紀錄：`/tmp/rainyclock-170-29-archive.log`、`/tmp/rainyclock-170-29-archive-check.json`、
`/tmp/rainyclock-170-29-upload.log`。

## 鬧鐘首頁文字、點擊範圍與天氣動畫 — 2026-09-16 22:12

- Tomorrow／明天與日期統一為稍大的 title3 粗體；同一列共用字體設定。
- 天氣卡移除整張點擊導向與右上角箭頭，只留 Home、Work 位置區及中央交通方式
  三個按鈕。標題、預報文字、天空、兩側裝飾線不導向 Route。
- 太陽旋轉速度加快 4 倍，光線長度 10→14pt；雨滴速度約加倍、加長並略增粗；
  雲層移動頻率加快 3 倍、振幅 20→32pt，雨與雲對比稍提高。
  原 RGB 配色、24fps 設定、減少動態效果與離開前景暫停的機制保留。
- Simulator 與簽署 iPhone Debug 建置成功、簽章檢查通過。實際點擊驗證三個入口可
  導向 Route，卡片標題／預報／空白处不跳頁；晴雨混合及陰天畫面檢查、短動畫錄製完成。
  本輪為 UI 修改，未新增對照實作的單元測試，也未重跑先前已通過的會員／後端測試。
- **22:12 安裝到 iPhone 16 Pro，22:12:47 裝置查詢確認 1.7.0（29）**；原地更新，
  未清資料、未自行啟動手機 App、未上架或部署後端。

紀錄：`/tmp/rainyclock-home-polish-simulator-build.log`、
`/tmp/rainyclock-home-polish-device-build.log`、
`/tmp/rainyclock-home-polish-iphone16pro-install.json`、
`/tmp/rainyclock-home-polish-iphone16pro-verified.json`。
動態預览：`/tmp/rainyclock-home-polish-sun-rain.mov`、`/tmp/rainyclock-home-polish-cloudy.mov`。

## 最新版再次安裝到 iPhone 16 Pro — 2026-09-16 21:59

- 使用者要求實機測試，重新建置目前工作目錄的 RainyClock Debug，簽章驗證通過。
  App／widget 都是 1.7.0（29），採原 Bundle ID 原地更新，沒有解除安裝或重置資料。
- **21:59 安裝成功，21:59:15 裝置查詢確認**，目標為 Shu-Kai Hu 的 iPhone16Pro，
  本輪包含初始免費一次、兩種響鈴設定及最新會員方案／續訂介面修改。
  未自行啟動手機 App、測試響鈴或請求廣告；未部署後端、未上架。
- 真機會員服務 URL 仍空白，本機 StoreKit 模式仍限 Simulator；手機可測基本功能及
  舊免費 AI 流程，不能據此驗證付款、訂閱限制或付費每日額度。
- 既有 2026-08-30 紀錄顯示該 iPhone 16 Pro 已登記 LevelPlay Test devices；
  本輪未重新核對平台。廣告驗收前須確認登記仍有效。`-showLevelPlayTestSuite` 會
  啟動官方工具，但不隔離 App 的普通 banner 請求，不能單靠該旗標保證無正式流量。
- 測試清單已更新至 [1.7.0 實機指南](1.7.0-DEVICE-TEST-GUIDE.md)。

紀錄：`/tmp/rainyclock-latest-iphone16pro-build.log`、
`/tmp/rainyclock-latest-iphone16pro-install.json`、
`/tmp/rainyclock-latest-iphone16pro-verified.json`。

## 已訂閱方案與自動續訂顯示 — 2026-09-16

- 目前月／年方案的按鈕改成灰色「已訂閱」及效期；買斷顯示灰色「已購買」。
  其他訂閱方案可更換，Apple 已安排下期切换的方案顯示「下次續訂生效」。
- 會員狀態卡顯示目前方案、有效日期與自動續訂狀態；點該列進入 Apple 訂閱管理。
  取消續訂仍保留當期權益。未知資訊顯示待確認，未提供自行宣告續訂狀態的開關。
- 本機以已驗證交易及 renewalInfo 配對；正式版由後端查核 Apple Server API／V2 通知。
  新增三個可選權益欄位，舊快取相容；後端獨立合併續訂簽章時間，防止舊通知回退。
- 訂閱狀態更新、管理頁返回與回前景會同步；工作階段失效時標示快取並提示手動同步，
  不自動打開 Apple 登入。購買前再次檢查最新權益，避免重複打開已生效方案。
- 完整 iOS XCTest：**263 通過、0 失敗**。後端含 Firestore Emulator：
  **142 通過、0 失敗、0 跳過**。未部署後端、未上架、未更新實體手機。
- 最後補上快取提示與購買前重查後，重新建置並執行會員相關 **18 項測試全通過**。
- 專用 Simulator 的 Xcode 本機測試購買已實際驗證：月方案按鈕停用且有日期；
  自動續訂列可開啟 Apple「Edit Subscription [Xcode]」，取消後立即顯示已關閉，
  仍是訂閱會員且保留效期。使用者的 iPhone 17 測試交易未改動。
- 最後調整灰色按鈕文字對比，Xcode 再次建置／啟動成功並確認狀態重啟仍保留。
  已將執行目的地切回 iPhone 17（26.2），scheme 為 RainyClock Membership Local；
  使用者可重新 Run 取得新版，本次未自行啟動其測試裝置。

紀錄：`/tmp/rainyclock-renewal-ios-tests.log`、`/tmp/rainyclock-renewal-ios-final-tests.log`、
`/tmp/rainyclock-renewal-backend-all.log`。

## 免費初始一次、提前／原定時間鈴聲 — 2026-09-16

- 免費 AI 初始額度從 3 改為 1（非每日），本機仍沿用原 used 計數與廣告獎勵。
  新會員後端 grant=1；已存在的後端 ledger 保留、不補發。付費每日一次保持不變。
- 「時間」有「提早響鈴」和「原定時間響鈴」，各保存音色、AI 檔案、角色與台詞。
  舊 JSON／排程指紋將原音色及 AI 資料沿用到兩邊；更改一邊不影響另一邊。
- 每週、背景重排依實際響鈴時間選聲音；日曆逐日記錄，各日期與稍後提醒用自己的音檔。
  已錯過提早時間而維持正常響鈴時使用正常音色，零提前仍遵循既有設定驗證。
- AI 只有保存成功才切換該設定，取消編輯不改原音色；可重用另一邊已保存 AI 音檔，
  試聽／播放／套用都不扣次。生成中暫停取消和下拉關閉，避免跨頁並行生成與結果覆寫。
  暫不清除舊生成音檔，避免刪到已排程／響鈴／稍後提醒仍引用的檔案。
- 後端含 Firestore Emulator：**136 通過、0 失敗、0 跳過**。
  iOS 完整 XCTest：**258 通過、0 失敗**；簽署 iPhone Debug build 成功。
  首輪新測試誤用既有不允許的提前 0 分鐘，已修正為驗證拒絕，未放寬產品驗證。
- 專用 Simulator 實際選擇 Early=Morning Bell、Regular=Soft Piano，重啟後各自保留；
  打開一般 AI 編輯再取消仍保留 Soft Piano。英文 AI 標題縮短以免截斷；
  初始 1 次的英文字串改單數。最終 UI build 通過，未呼叫真實生成／廣告。
  使用者正在操作的 iPhone 17 StoreKit 測試交易未改動；本次未更新安裝到實體手機。
- 會員後端仍未啟用，Simulator 廣告仍停用，Local StoreKit AI 額度仍為 0；
  這些測試不代表正式付款／廣告回呼或真機實際響鈴端到端通過。無正式部署／上架。

紀錄：`/tmp/rainyclock-free-one-backend-all.log`、
`/tmp/rainyclock-split-sounds-ios-tests-final.log`、
`/tmp/rainyclock-split-sounds-device-build.log`。
最終介面建置：`/tmp/rainyclock-split-sounds-ui-build.log`。

## 會員手動驗收說明 — 2026-09-16

- 會員方案卡片順序改為「買斷 → 月訂閱 → 年訂閱」。Membership Local Simulator build
  通過，紀錄 `/tmp/rainyclock-membership-plan-order-build.log`；重新 Run 即可看到新順序。
- 測試指南補齊免費／僅買斷／僅訂閱的畫面矩陣、Xcode 測試交易重置與恢復步驟。
  明確註明真機一般版尚未啟用會員限制；Simulator 廣告停用，本機 AI 額度為 0，
  不能把介面與假購買驗證當成正式廣告／每日額度端到端驗證。
- StoreKit 本機商品說明清除延至 1.7.1 的颱風功能，補上繁體中文商品名稱與說明。
  JSON 格式檢查通過；未改商品 ID、價格、群組或 App 程式，未重新安裝或部署。

## 月曆水平分頁與今天標記 — 2026-09-16

- `AlarmCalendarView` 改用原生水平分頁，日期頁隨手指移動，不再逐格淡出／淡入。
  前後月份箭頭、年份選單與「今天」共用月份選取；支援當年至次年。
- 日期外框只標記今天，點其他日期只切換響鈴與有效修改橘點。
  分頁高度保留六週空間，上限避免圖例被推到畫面底部；無上下捲動。
- Simulator 與簽署 iPhone Debug build 成功，App／widget 版本仍為 1.7.0（29）。
  Simulator 實際確認日期點選與還原、今天外框、箭頭換月、六週月份、Today 返回。
  CUA 拖曳未觸發模擬器滑頁，未將該次自動操作列為手勢通過；真機滑動手感待使用者確認。
- **20:58 安裝到 iPhone 16 Pro，20:59 裝置查詢確認版本**；原地更新，未啟動手機 App。
  紀錄：`/tmp/rainyclock-calendar-slide-simulator-build.log`、
  `/tmp/rainyclock-calendar-slide-device-build.log`、
  `/tmp/rainyclock-calendar-slide-iphone16pro-install.json`、
  `/tmp/rainyclock-calendar-slide-iphone16pro-verified.json`。

## 1.7.0 發布範圍與美國日曆 — 2026-09-16

**已於 20:32 更新安裝到使用者的 iPhone 16 Pro，20:34 裝置查詢確認 1.7.0（29）。**
採原 App ID 原地更新，未解除安裝、未啟動手機 App、未發布 App Store 或部署後端。
手機測試步驟見 [1.7.0 測試指南](1.7.0-DEVICE-TEST-GUIDE.md)。

- 使用者決定將颱風／天災臨時放假保留至 **1.7.1**。中央 release gate 關閉；
  日曆設定、會員方案、狀態提示及公開隱私草稿不再公開此功能。
  原程式、偏好、地圖、快取與服務保留，詳見 [1.8.0 備忘](1.8.0-DEFERRED-DISASTER.md)（原 1.7.1）。
- 有效排程副本忽略臨時放假；舊 skip 在安全時機替換，失敗保留舊排程並允許重試。
  背景與推播不下載／套用公告，僅保留撤销舊推播註冊所需清理。
- 美國來源已可選，依 OPM 常態聯邦假日與標準補假規則離線計算，含跨年補假及
  Juneteenth 從 2021 年生效。規則支援 2000–2100，超範圍回到星期並標示資料不可用。
  州、學校、公司、輪班及一次性行政放假由使用者手動調整；台灣快取不套用到美國。
- 明天鬧鐘的休假名稱依選定國家取得；手動日期優先，恢復相同規則時不留橘點。
- **完整 iOS XCTest：246 通過、0 失敗、0 跳過**；含新增 14 項美國日期／狀態與
  停用災害後排程／推播回歸。簽署真機 Debug build 及簽章檢查通過。
- Simulator 實際確認可選美國、2026/11/11 與 11/26 不響、11/27 響；點 11/26
  兩次可恢復且移除橘點；日曆無颱風入口、方案頁無颱風權益。
- 會員服務 URL 仍為空，付款未開放；真機不能用本版驗證付費每日額度。
  StoreKit 本機測試繼續使用 Simulator scheme，平台實測缺項仍見下方會員段落。

驗證紀錄：`/tmp/rainyclock-170-us-calendar-tests.log`、
`/tmp/rainyclock-170-us-calendar-device-build.log`、
`/tmp/rainyclock-170-us-iphone16pro-install.json`、
`/tmp/rainyclock-170-us-iphone16pro-verified.json`。

## Membership implementation — 2026-09-16 (local/test only)

已加入免註冊 Apple 會員、StoreKit 2、Firestore 額度與 LevelPlay S2S 獎勵驗證。
**當時會員開關預設關閉，未部署會員服務或啟用收費。** 以下為先前本機實作批次的
歷史驗證及當時待辦；後續 Sandbox 雲端部署／Apple 接線以本文件最上方最新紀錄為準。
一般 App 的正式會員開關仍關閉。
既有 UI、天氣與臨時放假修改仍保留；沒有修改 Android，也沒有提交其他 session 的變更。
完整規則與限制見 [會員與付款](MEMBERSHIP-AND-PAYMENTS.md)，環境及資料結構見
[後端操作說明](../weather-proxy/membership/README.md)。

- 月／年／買斷商品、當地 StoreKit 價格、方案頁、會員狀態、恢復、管理訂閱及刪除入口。
  恢復購買只恢復權益，不同步鬧鐘設定或手機已存音檔。
- Apple 簽章與 Server API 對帳、Notifications V2 去重；App Attest challenge、工作階段、
  請求內容綁定與重放防護。iOS 17 使用現行 SDK 的 appTransactionID back-deployment。
- 每日一次、跨裝置原子預留、同請求重試、音訊可靠保存後才扣、失败同來源退款、
  中斷租約回收與下載重試。所有 paid 方案共用一次；免費仍初始三次加獎勵。
- 使用者已確認當地午夜／不累積，買斷與訂閱重疊規則，以及到期保留設定與安全重排。
  暫時離線或替換排程失敗不清除既有鬧鐘。
- LevelPlay 獎勵只由簽章 callback 入帳；手機只查詢。換帳號撤銷舊 session 與廣告 ID，
  已初始化舊 ID 的 LevelPlay 須重啟 App 才能換會員。模擬器禁用廣告 SDK。
- 舊額度 claim 保留待查核；未擅自補發或清空。**舊額度遷移與匿名語音端點切換仍待決定**；
  目前保留舊免費流程，不能宣稱整個既有語音服務已強制會員限額。
- 會員刪除立即撤銷存取，資料清理可重試；不取消 Apple 訂閱、不清手機鬧鐘與完成音檔。
  隱私政策／manifest／App Store metadata 只有本機草稿，公開揭露尚未發布。

### 驗證紀錄

- **後端 134 項通過、0 失敗、0 跳過**，包含 Firestore Emulator 真實 transaction、
  跨裝置並行、重複事件、成功後扣次、失敗退款、跨日／時區、到期／退款、刪除及
  重放拒絕。廣告同 event ID 或同已驗證簽章內容都只入帳一次。
  記錄：`/tmp/rainyclock-membership-all-backend-final.log`。
- **iOS 26.2 完整 XCTest：232 通過、0 失敗、0 跳過**，包含 StoreKit 本機購買、恢復、
  續訂、到期、退款與待批准，以及即將響鈴時禁止到期重排。StoreKit 異步通知以有上限
  的條件等待驗證。記錄：`/tmp/rainyclock-membership-ios-26.2-final-tests.log`。
- **Generic iOS Release 建置成功**（未簽署、未安裝），最低 iOS 17、原 Bundle ID、
  `1.7.0 (29)` 與空白會員 URL 已確認。記錄：`/tmp/rainyclock-membership-device-release-build.log`。
- Xcode 26.6 / iOS 26.5 的 StoreKit service 曾回報 `Error saving configuration file` /
  `not installed for development`；改用同機已安装的 iOS 26.2 runtime 可成功。
  這是本機 StoreKit 環境，**不是 App Store Sandbox 或正式付款測試**。
- 另以專用 Simulator 實際打開方案頁、看到 StoreKit 本地化價格，完成標示 Xcode／不收費的
  測試購買，確認畫面由「免費方案」更新為「訂閱會員」。
- 尚未執行真機 App Attest、Apple Sandbox 換機／重裝完整往返、真實 Server Notifications、
  LevelPlay dashboard test callback／Test Suite；未產生正式廣告流量。

### 當時列出的正式開放前工作（進度見最上方最新紀錄）

1. 重新盤點 Google Cloud 資源：本次 `rainyclock` 的 Firestore 查詢返回 `SERVICE_DISABLED`。
   經另行處理後建立 Standard / Native / asia-east1、服務帳號最小權限、Secrets、TTL／索引、
   刪除維護工作與監控，先部署隔離測試環境。
2. App Store Connect 建立月／年同群組與買斷商品；美國 $1／$10／$5，其他商店價格待決定。
   補 App Store Server API key／issuer、App ID、Apple 根憑證、Sandbox／正式通知 URL；
   Apple Developer 啟用 App Attest 並更新 profile。
3. LevelPlay 設定每次 reward=1、private key、S2S callback；只能以官方測試装置／Test Suite
   驗證，不能用正式廣告反覆測試。
4. 決定舊額度遷移、舊端點相容策略，以及刪除後最少防重摘要的保留期限；完成實際
   Sandbox／真機驗收，發布隱私政策並更新 App Store 隱私標籤後才可啟用會員開關。
5. 首次免費帳號沒有任何 IAP 時，須實測 Server API history 會回傳 `200` 空集合；
   Apple 未保證 `4040010` 表示免費帳號。目前查核失敗便不發 session，需在 Sandbox
   驗證此首次使用流程，不能吞掉錯誤以宣告驗證成功。正式入口限流也須配置可信代理／
   雲端入口；現有以轉送標頭計算的 IP 限流只作輔助。

## Where things stand

| | Version | State |
| --- | --- | --- |
| **Local development** | `1.7.0 (29)` | Owner-authorized integration in `RainyClock-iOS/`: calendar, disaster feed/client/scheduler/receipts and native township map copied from the separate preview; native two-tab UX integrated. Accepted purple-rain palette and native weather animations installed on the owner's iPhone 16 Pro on September 16 at 00:48, including earlier startup/cache/concurrent-fetch improvements. Latest full XCTest including membership: 232 passed, 0 skipped (iOS 26.2). Membership is local/test only and disabled by default; see above. Simulator layout/category taps/calendar editing checked; native swipe feel awaits phone validation. No archive/upload, no live disaster backend. See current handoff below |
| **Live on the App Store** | `1.6.9` (submitted build `28`) | **Confirmed 2026-09-10** against the Taiwan public listing and Apple's lookup API. Release timestamp `2026-09-07T21:33:44Z`, i.e. **2026-09-08 05:33:44 Asia/Taipei**. Evening-before previews, ad reporting, and AI voice quota persistence. The public listing confirms the version, not the build number |
| Superseded | `1.6.8` | **Released 2026-09-01**, first attempt — confirmed against the public listing, not against this file. The AI voice alarm. Production checked after release: weather and `/v1/tts` both answer 200 |
| Superseded | `1.6.7` | **Released 2026-08-30.** The ad-provider migration. Confirmed against the public listing on 2026-08-31 — this row had still been claiming 正在等待審查, the third time this file has gone stale the same way |
| Superseded | `1.6.6` | Released 2026-08-18 |
| Superseded | `1.6.5` | Released 2026-08-04 |
| Rejected, then resolved | `1.6.4 (19)` | Rejected 2026-08-01 on 5.1.2(i) and 2.1(a); both answered, and the fixes reached users in 1.6.5 |
| Superseded | `1.6.3 (18)` | Released 2026-07-28 |

## Voice backend update — 2026-09-16

Owner requested the screenshot's classification-model migration and backend rollout.
`weather-proxy/annotate.js` now defaults to `gemini-3.1-flash-lite` at the Vertex US
multi-region endpoint, with canonical REST `thinkingConfig.thinkingLevel: MINIMAL`.
It retains schema/per-sentence neutral fallback, ignores thought parts and emits structured
fallback metadata without user text or credentials. Existing Cloud TTS voices/model remain.
**73 backend tests passed; 12 live classification and 12 staged speech-generation checks
passed** across both languages and all six personas. Audio format/signal/duration were checked;
subjective voice listening remains available through the saved samples.
Cloud Run `asia-east1` revision `rainyclock-weather-proxy-00012-win` was promoted from staged
0% to **100% production traffic**, verified **September 16 at 19:20 Asia/Taipei**.
Real App URL weather and speech checks both returned 200. Existing env/secrets, runtime
resources and service account were preserved. No phone update is required for this backend
change; existing audio clips stay unchanged until regenerated.
Evidence, samples and rollback: [migration report](annotation-migration-2026-09-16/README.md).
This does not deploy the separate day-off service or change the App Store release.

## Current handoff — 2026-09-15: integrate previews into 1.7.0

The owner has now authorized merging all reviewed preview features into the original
`RainyClock-iOS/` workspace for simulator review. Earlier instructions to leave that directory
unchanged applied to the separate-preview phase, which is retained in
`RainyClock-dayoff-preview/`. This is a local working-tree integration, not a commit, release,
archive or server deployment. App and widget remain `1.7.0 (29)` with their original
`com.shukaihu.RainyClock` / `com.shukaihu.RainyClock.AlarmWidget` identities and original app name.
Pre-merge backup: `/tmp/RainyClock-1.7.0-before-merge-20260915-220445.tar.gz`.

- **Purple rain palette (September 16, subsequent owner refinement):** Changed only rain's
  sky, cloud and raindrop RGB values to deep violet/lavender. Sunny and cloudy styling remain
  exactly as reviewed in palette v2. Simulator build passed
  (`/tmp/rainyclock-weather-palette-v3-build.log`). The five rain-containing combinations were
  recaptured using the native Simulator Save Screen command; the four unchanged clear/cloudy
  screenshots were retained byte-for-byte. Updated grid, originals, provenance and ZIP:
  `docs/weather-variants-2026-09-16-palette-v3/`. On the owner's request, the signed device
  build passed and was installed on their iPhone 16 Pro **September 16, 00:48 Asia/Taipei**.
  Signature verification and `devicectl` confirmed the original app/widget identities and
  `1.7.0 (29)`. Updated in place without uninstalling or launching the phone app. Simulator
  preview entry points are excluded from the physical build; real forecast/animation logic
  remains active. Logs: `/tmp/rainyclock-weather-palette-v3-device-build.log`,
  `/tmp/rainyclock-purple-iphone16pro-install.json`,
  `/tmp/rainyclock-purple-iphone16pro-verified.json`.
- **Weather palette refinement (September 16):** Sunny skies now use a clearer, saturated
  sky blue with a warmer amber sun, sharper rays and a smaller halo. Cloudy skies use neutral
  silver gray and pale clouds; rain uses deep blue, cool clouds and more visible rain streaks.
  Brighter secondary text and quiet text zones retain readability. Layout, endpoint blending,
  animation behavior and forecast/alarm logic are unchanged. The Simulator build passed
  (`/tmp/rainyclock-weather-palette-v2-build.log`); all nine Home/Work combinations were
  captured and visually reviewed in iPhone 17 Pro / iOS 26.5 Simulator. Full native captures,
  a contact sheet and ZIP are in `docs/weather-variants-2026-09-16-palette-v2/`, preserving
  the original set. No forecast or alarm tests were added for this visual-only change.
  These previews contain explicit sample data. This palette is included in the subsequent
  purple-rain revision installed on the physical phone at 00:48, documented above.
- **Weather startup latency (September 16, after owner's phone feedback):** The prior
  forecast pipeline waited for Directions, then sampled Home, interior points and Work one
  by one; its tomorrow cache lived only in memory. The home view also keyed its task to
  visibility, allowing an appearance transition to cancel the first request. Home now starts
  one coalesced model refresh on appearance/request change and lets it finish when switching
  tabs. A central progress indicator appears immediately when no matching forecast exists.
  A versioned `tomorrowWeatherRecord.v1` stores the full request and snapshot, synchronously
  restoring matching data before the first render. Fresh data (30 minutes) skips networking;
  stale matching data remains labeled stale while refreshing. Date, forecast time, time zone,
  route addresses/coordinates and mode must match; invalid data, cancellation, old responses
  and failed updates cannot replace a valid cache. This is display cache only, not a recorded
  successful alarm registration. Weather acquisition now starts Home/Work alongside Directions,
  then samples the bounded interior points concurrently without changing route order or
  omitting the rainiest point. No first-request latency guarantee is claimed for Apple/network
  service time; no live iPhone speed measurement has been taken.
  Final Simulator and signed device builds passed. Full XCTest: **208 passed, 6 existing
  unsigned Keychain cases skipped, 0 failed** (214 total): four new persistent-cache tests,
  six concurrency/order/error/cancellation tests, and strengthened old-response persistence
  assertions. Result: `/tmp/RainyClock-1.7.0-DerivedData/Logs/Test/Test-RainyClock-2026.09.16_00-14-52-+0800.xcresult`.
  Simulator checked immediate startup progress, tab changes and the final single in-card
  loading indicator. Matching-cache first-render and no-network behavior were tested with
  injected data, because Simulator still cannot obtain live WeatherKit authorization.
  Installed the final signed build on the owner's iPhone 16 Pro **September 16, 00:16**;
  `devicectl` verified `com.shukaihu.RainyClock`, `1.7.0 (29)`. No uninstall or phone launch.
  Logs: `/tmp/rainyclock-1.7.0-weather-fast-tests-final.log`,
  `/tmp/rainyclock-1.7.0-weather-fast-device-build.log`,
  `/tmp/rainyclock-weather-fast-iphone16pro-install.json`.
- **Animated commute weather and settings regrouping (September 16):** Alarm now has only
  the tomorrow hero and a Home/Work weather card, with route addresses and travel mode inside
  the weather card. Different endpoint conditions blend horizontally; matching conditions use
  one sky. Native Canvas rain, slowly drifting clouds and a soft rotating/pulsing sun animate
  at at most 24 fps and pause offscreen, in background, or with Reduce Motion. Missing weather
  stays neutral, never pretending to be sunny; forecast retry/stale errors and WeatherKit
  attribution remain visible. The Time/Route/Calendar shortcut rows were removed; hero date,
  time/reason and weather card still open the corresponding settings. Repeat days moved to
  Calendar using the same saved weekday set; wake-up, early alarm and threshold share one Time
  card. Turning closure rules off hides both closure preferences and the map. Normal closure
  pages no longer offer examples, Demo or the ellipsis menu, and the verbose source footer was
  removed. The map keeps a linked NLSC credit and an accessible region list.
  The reported Tainan geometry matches the pinned official source; round joins fix exaggerated
  highlight spikes and interior house/building markers identify Home/Work. Three new geometry
  regressions cover name/boundary association, shared edges, projection, marker containment and
  outline extent. Evidence: [township boundary report](TAIWAN-TOWNSHIP-BOUNDARIES.md).
  A separate **Debug Simulator only** `-weather-scene-preview` entry can exercise clear/rain,
  all-rain, all-cloudy, all-clear and unavailable states with explicit sample labels. It never
  loads the real model, writes forecasts/settings, starts ads or initializes notifications.
  Simulator visual checks confirmed those weather styles, native animation movement, normal
  homepage fit, inline route addresses, the new Time group, and Calendar's hidden map when off.
  The actual forecast remains unavailable in Simulator; synthetic previews are not live data.
  Final normal-screen checks confirmed route navigation from the sky card, removal of examples,
  source footer, ellipsis and Demo, Home/Work marker selection in Tainan, and hidden map after
  restoring the original closure switch to off. Actual midnight rollover also advanced Tomorrow
  from September 16 to September 17. Full XCTest: **198 passed, 6 existing unsigned Keychain
  tests skipped, 0 failed** (204 total), including the three new geometry regressions.
  Result: `/tmp/RainyClock-1.7.0-DerivedData/Logs/Test/Test-RainyClock-2026.09.16_00-02-07-+0800.xcresult`.
  Signed device build passed; installed and verified on the owner's physical iPhone 16 Pro
  **September 16, 00:03 Asia/Taipei**, retaining `com.shukaihu.RainyClock`, `1.7.0 (29)`.
  No uninstall or phone launch. Logs: `/tmp/rainyclock-1.7.0-sky-tests-final.log`,
  `/tmp/rainyclock-1.7.0-sky-device-build.log`, `/tmp/rainyclock-sky-iphone16pro-install.json`.
- **Tomorrow overview and route-linked closures (later September 15 refinement):** Alarm
  now projects tomorrow's normal alarm day, including a visible skipped result for weekends,
  holidays, manual silence or temporary closures. It shows the expected time and rain reason,
  plus tomorrow's home/destination weather; the route maximum explains an early alarm. The
  normal Enabled badge, evening-reminder row and weather-check timestamp were removed.
  Tomorrow weather has a separate request/cache keyed by normal date, lead-time forecast
  point, time zone, addresses, map points and travel mode. It never registers alarms or treats
  a successful forecast as a successful registration; exact tomorrow registrations remain
  visible while forecasts are pending, and mismatched projections retain an update warning.
  Calendar has separate ordinary-calendar and temporary-closure switches; US explicitly says
  not supported yet. Other shows notification/background states inline, and bottom tabs keep
  44-point minimum targets with less vertical padding. Closure details display Route addresses
  and automatically derived county/township, with no independent picker. Legacy manual regions
  are migrated before comparing schedule fingerprints, and late previews cannot overwrite a
  newly selected map point. Full XCTest passed: **195 passed, 6 existing unsigned Keychain
  cases skipped, 0 failed** (201 total), including 14 tomorrow-projection/transport tests and
  6 route-region regressions. Result:
  `/tmp/RainyClock-1.7.0-DerivedData/Logs/Test/Test-RainyClock-2026.09.15_23-33-43-+0800.xcresult`.
  Final Simulator and signed device builds passed. Simulator checks confirmed the tomorrow
  date/time, forecast failure state, shorter bottom tabs, inline notification/background rows,
  separate calendar/closure switches, disabled US source with the unsupported label, and
  read-only Route addresses with county/township. Both switches were restored to their original
  off values. Live successful WeatherKit forecasts were unavailable in Simulator; forecast and
  skip/early scenarios were validated with injected test data.
  **23:40 Asia/Taipei: installed this revision on the owner's physical iPhone 16 Pro**;
  `devicectl` verified `com.shukaihu.RainyClock`, `1.7.0 (29)`. No uninstall or phone launch.
  Final build logs: `/tmp/rainyclock-1.7.0-tomorrow-final-sim-build.log` and
  `/tmp/rainyclock-1.7.0-tomorrow-device-build.log`; installation receipt:
  `/tmp/rainyclock-tomorrow-iphone16pro-install.json`.
- **Settings/calendar refinement (same day, after first device install):** Time, Route and
  Other primary labels/values share the system body size. Holiday source offers Taiwan and a
  disabled United States option. Legacy weekly settings remain compatible until Taiwan is
  explicitly selected. The orange calendar marker now compares the manual result with the
  current base calendar/weekday result; toggling back removes the override. Today and Done
  occupy the top corners, the legend is the final content, and horizontal drags change month
  without vertical scrolling. Calendar navigation uses typed destinations so an Alarm shortcut
  correctly exits retained details. Six new calendar regression tests cover comparison,
  toggling back, changing base rules and persistence. Latest XCTest: **175 passed, 6 existing
  unsigned Keychain tests skipped, 0 failed** (181 total), result
  `/tmp/RainyClock-1.7.0-DerivedData/Logs/Test/Test-RainyClock-2026.09.15_22-45-16-+0800.xcresult`.
  Simulator interaction is now available: month swipes, Today/Done, marker restoration,
  disabled US option, typography and calendar shortcut return were exercised successfully.
  Settings categories use native page-style TabView. The UI automation tool's drag events
  contained only touchesBegan/touchesEnded with different positions and no touchesMoved,
  so they cannot exercise native pager/ScrollView pans. Temporary recognizer diagnostics
  established this limitation and were removed; category taps were checked, while physical
  swipe feel remains an owner check. Final Simulator and signed device builds succeeded;
  all four category buttons were rechecked in the final native pager build. The original
  calendar enable switch and test date were restored after interaction checks.
  **23:04 Asia/Taipei: installed the final refinement on the owner's physical iPhone 16 Pro**
  and `devicectl` verified `com.shukaihu.RainyClock`, `1.7.0 (29)`. No uninstall or phone launch.
  Final build logs: `/tmp/rainyclock-1.7.0-settings-final-sim-build.log` and
  `/tmp/rainyclock-1.7.0-settings-final-device-build.log`; installation receipt:
  `/tmp/rainyclock-settings-iphone16pro-install.json`.
- **iPhone 16 Pro installed (2026-09-15):** signed Debug build succeeded and updated the
  owner's connected physical iPhone 16 Pro from `1.6.9 (28)` to `1.7.0 (29)` using the
  original bundle ID, without uninstalling. `devicectl` verified the installed version.
  Build: `/tmp/RainyClock-1.7.0-Device-DerivedData/Build/Products/Debug-iphoneos/RainyClock.app`;
  log: `/tmp/rainyclock-1.7.0-iphone16pro-build.log`. The app was not launched as part of
  this install request; real-device alarm/background/push acceptance remains pending.
  繁中：已更新安裝至實體 iPhone 16 Pro 並核對版本，未先刪除 App，待使用者開啟驗收。
- **Navigation integrated:** top tabs **鬧鐘 / 設定**; settings categories **時間 / 路線 /
  日曆 / 其他**. The alarm tab presents status and links to corresponding settings. Calendar,
  temporary-suspension settings and the township map belong under **日曆**. Preserve the prior
  route editor and the dark/blue rounded style; save edits directly without an Apply button or
  settings-completed banner. Other settings contain support and notifications/background updates.
  Foreground automatic scheduling may arm the first alarm only after both route addresses are
  confirmed and resolved and remaining settings are valid; typing address drafts does not arm it.
- **Disaster implementation:** shared Node service polls NCDR's formal API, iOS processes only
  matching announcements and applies local schedules, then sends authenticated receipts.
  The map is a separate read-only presentation. See [DISASTER-PREVIEW.md](DISASTER-PREVIEW.md)
  and [DISASTER-MAP-PREVIEW.md](DISASTER-MAP-PREVIEW.md).
- **Not enabled in production:** `DayOffServiceURL` is blank; NCDR key, a deployed HTTPS service,
  APNs credentials/capability/signing and physical-device background behavior remain unconfigured
  or unverified. Receipt acceptance is historical processing evidence, not guaranteed push
  delivery. Calendar/disaster subscription billing and StoreKit entitlement gates are not implemented.
- **Reliability:** fixed-date scheduling uses a 27-day rolling window and needs future execution
  to extend it. Missing background opportunities and partial AlarmKit replacement failures remain
  device-validation concerns; simulator builds do not prove timely background delivery or ringing.
- **Validated after integration:** Debug simulator build and XCTest passed: **169 passed, 6
  existing unsigned Keychain tests skipped, 0 failed** (175 total), including six new initial
  autoscheduling cases. Result: `/tmp/RainyClock-1.7.0-DerivedData/Logs/Test/Test-RainyClock-2026.09.15_22-13-10-+0800.xcresult`.
  The final home clock-refresh UI adjustment was subsequently rebuilt successfully. This was
  the initial integration run; the later refinement and interaction results above supersede it.
  Installed and launched the original bundle on iPhone 17 Pro / iOS 26.5; verified installed executable matches the final build.
  Follow [1.7.0-SIMULATOR-CHECKLIST.md](1.7.0-SIMULATOR-CHECKLIST.md).
- **Backend validated after integration:** `npm ci` in `RainyClock-iOS/dayoff-service` completed
  with audit 0; all 52 tests passed under Node 22.23.2, with 0 failures/skips. Fixtures and fake
  transports only; no official credentials or real APNs requests were used.
- **Simulator ads:** `AppEnvironment.allowsAdvertising` disables advertising/ATT paths on all
  simulators; no launch flag is needed, and original production keys remain intact for device builds.

繁中：目前已獲授權將預覽合回原 1.7.0 開發目錄，並保留合入前備份及獨立預覽。
這次只做本機整合與模擬器檢視，沒有發布 App 或啟用正式停班停課服務；金鑰、部署、
真機推播／排程驗證及收費權益仍未完成。後面的 9 月 10 日 handoff 與舊 backlog 是
歷史紀錄，停班停課的現況以此節與天災文件為準。

**Ships with 1.6.6 (edited in ASC 2026-08-13):** both app names change — 繁體中文
`RainyClock` → `Rainy Clock`, English `Rainy Clock: Rain Alarm` → `Rainy-Clock`. Plain
"Rainy Clock" is still name-squatted in the English locale (409 on rename), but the
hyphenated variant was accepted (details in `docs/appstore-metadata.md`).

## Handoff verification — 2026-09-10 (intake, before 1.7.0 work)

Read the dated release table and the actual implementation before treating older sections below
as current tasks. This file retains development history, including decisions since superseded.

- **Working tree:** iOS is `RainyClock-iOS/` on `ios/main`; Android has a separate worktree.
  At intake, HEAD was `d86c848`, clean and three commits ahead of the locally recorded
  `origin/ios/main`. Those three commits contain day-off documentation, not feature code.
- **Current runtime:** Swift 6 / SwiftUI, minimum iOS 17. `AppEnvironment` uses real
  `MapKitRouteWeatherService` in Debug as well as Release; README's mock-only Debug description
  is obsolete. iOS 26+ uses AlarmKit; iOS 17–25 uses local notifications.
- **There is a backend:** `weather-proxy/` provides the Android weather relay and iOS AI voice
  generation. `tts.js` currently calls Google Cloud Text-to-Speech with service-account auth;
  the earlier Gemini Developer API discussion and "AI voice — in progress" heading below are
  historical. AI voice shipped in 1.6.8. The older "No backend" descriptions are obsolete.
- **Day-off is still unimplemented (v0 against spec v2).** The 28 parser fixtures and 25
  decision fixtures exist, but are not yet loaded by iOS tests. They describe the intended
  cross-platform contract; they do not currently enforce it in CI.
- **Resolve spec inconsistencies before implementing day-off:** §5, §9 step 5 and the v2
  changelog require schedule-time `CommuteAlarmMetadata` and no App Group, while §6 Path B
  and §9 step 4 still mention an App Group. The fixture field guide defines
  `affectsMorningAlarm` solely by day part, but parse-25 through parse-28 use `false` despite
  `dayPart: full` (compare parse-13's normal/full/true). The changelog still says 107 ids
  lack `_i_`, while the corrected body and corpus summary say 324. Do not silently change
  fixture expectations to fit an implementation. §8's `both` AND/OR choice still needs the
  owner's answer before starting typhoon suppression; holiday work can precede it.
- **Outstanding device checks:** morning decision-change notification, the preview's
  background-refresh-disabled sentence, rewarded-ad reporting, and actual delete/reinstall
  quota persistence remain unconfirmed by this handoff. The preview delivery and banner
  creative id were already seen before the 1.6.9 upload. Adding Unity Ads demand remains
  backlog work; the old AdMob tasks must not be revived.
- **Local verification today:** Xcode 26.6 simulator Debug build passed without signing;
  app and extension both report `1.6.9 (28)`. All 46 `weather-proxy` unit tests passed.
  The iOS unit suite and physical-device checks were not rerun; the 92-test result below
  remains the recorded September 7 run. No app was launched to exercise production ads.

繁體中文交接摘要：1.6.9 已上架，非送審中；AI 語音已在 1.6.8 推出，已有 Cloud Run
後端。停班停課／國定假日只有 v2 規格與案例，尚未實作或接入 iOS 測試。後續從國定假日
開始，停班停課的「兩者」判斷仍待 owner 確認，且必須先處理上述規格矛盾。任何天氣更新
失敗都應保留原鬧鐘；任何停班判斷不確定都應照響。只在本工作目錄維護 iOS 狀態。

## 1.7.0 (29) — Settings and editable alarm calendar

Owner confirmed 2026-09-10: implement holidays and manual date exceptions in this version;
leave temporary work/school suspensions to a later version. Work and school are **independent
switches**, not a mutually exclusive three-way mode. Manual ring/silent overrides take
priority over all automatic rules. The future meaning of both switches being enabled for
mixed work/school announcements still needs its own decision before that feature ships.

### Implemented locally

- Third **Settings** tab. Calendar enable/source/editor, 12/24-hour display, evening preview controls, independent
  work/school preferences, map-derived home/destination districts, generic ad report/privacy options,
  system settings, help/privacy links and version. The per-banner report stays beside its ad.
- Removed **Send a preview** from the user interface and its view-model action. The normal
  evening preview remains, including a silent-day message. Internal planner fixtures remain.
- Month calendar covering every month of the current and following year. Each date shows
  ring/silent; a tap toggles it. Manual dates have an orange marker, a restore action, and a
  year-reset confirmation. Past days are read-only. Accessibility text sizes use a day list.
- Calendar is **off by default**, using weekly settings so upgrading does not alter existing alarms. Enabling
  **Taiwan office calendar** skips official off days (including weekends) among the selected
  weekdays. A make-up workday outside selected weekdays requires a manual ring override.
  Missing holiday data leaves the weekly rule in effect and explains that in the date detail.
- Bundled complete 2026/2027 DGPA CSVs (730 days). Source: data.gov.tw dataset 14718; exact
  download URLs/license/date in `RainyClock/Resources/holiday-sources.json`. Refresh monthly
  or explicitly; validate full-year date uniqueness, row count, encoding and schema before
  replacing cached data. The in-app live update succeeded on the simulator on September 10.
- Bundled 368 districts from NCDR's official Taiwan_Geocode.xlsx, accessed September 10:
  https://alerts.ncdr.nat.gov.tw/web/StaticFile/Document/Taiwan_Geocode.xlsx . These validate Apple's
  structured county/district fields for the route's map points; no manual district picker remains.
  Work/school switches **save preferences only**; this limitation is visible in Settings.
- Manual edits persist by Gregorian normal-alarm date, not the rain-adjusted date. They work
  offline and re-register an armed alarm after a debounce. Only a successful registration
  publishes its summary/fingerprint. A failed attempt retains the old summary and shows drift.
- Calendar mode schedules fixed dates, not weekly repeating alarms with impossible exceptions.
  iOS 26+: 366-day horizon via AlarmKit; replacement batch is registered before old alarms are
  retired. iOS 17–25: 27 days with one optional follow-up per date, leaving capacity for seven
  previews, the coverage reminder and the existing decision-change notice. Local notifications
  snapshot/restore old requests on registration error. Non-calendar mode keeps weekly repeats.
- Only the next occurrence has a weather decision. Later dates remain at normal time until
  evaluated. No forecast means the UI says so; advancing to another date does not borrow the
  previous day's rain probability. Editing holiday rules does not depend on a network forecast.
- Calendar UI states the coverage date and expiry; foreground/background refresh extends it,
  with a notification scheduled seven days before expiry. **Without another app execution,
  dated alarms stop at the coverage boundary.** iOS background refresh is not guaranteed.
  Time-zone changes rebuild the plan when the app next runs. Rules beyond the current horizon
  remain saved but are not yet registered as system alarms.

### UI follow-up — 2026-09-10

- Owner reported the lower-right Done control and black Alarm / intermittently black Settings.
  Reproduced the black Alarm page in the existing simulator: the bottom selector remained,
  but the selected page had no content/accessibility elements.
- Replaced page-style TabView hosting with normal tab containment, retaining the custom
  bottom selector and each tab's NavigationStack. Removed animated page selection; the selected
  tab now has its accessibility selected trait. Switch with the bottom tabs (no horizontal paging).
- Removed the route keyboard's Done toolbar. Tapping gaps in the route content dismisses focus;
  switching tabs resigns the keyboard and clears route focus. Interactive scroll dismissal is
  enabled, and the keyboard Search key still performs the existing address-search submit action.
  The subsequent preferences follow-up replaces the time picker with immediate edits and a top close control.
- Verified on iPhone 17 Pro / iOS 26.5: Alarm and Settings render after the fix; six successive
  cross-tab switches retain content, including leaving Settings' pushed calendar and returning.
  Keyboard open → Alarm dismisses the keyboard and displays the page; tapping the content gap
  dismisses the keyboard and suggestions without changing either address. No keyboard Done row.
- Simulator Debug build passed. This follow-up changes view containment / keyboard handling only;
  no new alarm-engine changes. Preview copy has a blank ad key; the project production key and
  existing simulator addresses are retained. No upload or physical-device installation performed.

### Preferences follow-up — 2026-09-10

- Removed the redundant calendar link from Alarm. Settings is the only entry to the month editor.
- Added **Use calendar for alarm dates**. Off hides the source, month editor, coverage and holiday
  update controls, and restores weekly scheduling without deleting holiday/manual preferences.
  On restores them. If no weekdays are selected, switching off a manual-only calendar cancels
  its alarm instead of accidentally enabling every weekday. Existing development-build calendar
  choices migrate with their previous behavior; 1.6.9 upgrades and new installs default off.
- Added **AM/PM / 24-hour** in Settings. Applied to the Alarm clock, result/status times, both
  time pickers, evening-preview times and notification text. Traditional Chinese uses only
  上午/下午, including midnight and noon. Existing pending previews are replaced with updated
  text; their firing dates and the registered alarm do not change for a display-only edit.
- Removed manual home/destination region selection. Resolve administrative fields from the
  route's Apple Maps points, enriching older stored coordinates when needed. Validate against
  the official district list, normalize 台/臺, and show pending if unknown/ambiguous/foreign.
  Changing an address discards the previous district. Simulator route returned distinct valid
  home/destination districts, confirming that both rows use their own map result.
- Renamed the permission link to **Open iPhone Settings** and explained its purpose: previously
  denied notifications can be enabled there; background refresh is a separate system control.
  People who already allowed notifications normally need no further action.
- Simulator verified: calendar off hides its controls and registers weekly repeats; on restores
  the dated plan; 07:30/21:00 and 上午 7:30/下午 9:00 update in both tabs and both hour-cycle picker
  layouts render correctly. Restored the user's calendar-on, AM/PM preferences, preserving their
  addresses, weekdays and alarm times. No black page or lower-right Done control encountered.

### Validation and release work

- Xcode 26.6 / iOS 26.5 unsigned simulator build and test suite: 120 tests, 6 Keychain skips,
  zero failures. New tests cover holiday/manual precedence, missing data, old-setting migration,
  leap/year boundaries, crossing midnight, preview messages, offline edits, failure preservation,
  restoring weekly scheduling, calendar disable/restore, hour cycles and unchanged firing times,
  map district matching, avoiding invented forecasts and a slow forecast timing out. The old auto-refresh test now
  waits for scheduling completion rather than observing a spy call before its async return.
- Final preference/status follow-up: 18 focused tests passed, including one additional regression
  proving an already-visible weather status switches hour cycle immediately without rescheduling.
  Test storage cleanup uses async setup/teardown for the new main-actor preference fixture.
- Simulator UI: Traditional Chinese Settings/calendar, tap/restore, holiday override,
  2027 navigation, independent work/school switches, map-derived districts and live data refresh checked. English and largest accessibility-size
  calendar checked; bottom labels/month navigation adjusted to avoid broken words.
- A separate disposable AlarmKit probe accepted **800 fixed-date alarms** on the iOS 26.5
  simulator and cancelled all of them (`remaining 0`). This supports replacement capacity in
  this environment only; it is not a guarantee about physical devices or every iOS release.
- The app registered a 246-occurrence calendar plan through September 10, 2027 on the
  simulator, including a manual ring on Mid-Autumn Festival. After confirming the test route,
  changing an armed holiday from silent to ring automatically replaced the plan and committed
  the matching fingerprint (246 occurrences). Test addresses and their alarms were removed. Without a WeatherKit response it
  showed the normal-time fallback explicitly. Calendar forecast attempts cancel after 12 seconds
  so a slow request can fall back to date rules; the timeout path has a regression test.
- Preview install used a copy with an empty LevelPlayAppKey. The project keeps its production
  key; no production ads were requested during this UI pass.
- **Before release:** physical-device fixed-date ring/snooze, app termination/reboot, silent
  holiday followed by working day, manual exception replacement, denied permission, and the
  iOS 17–25 notification-capacity/coverage renewal path still need device validation. Include
  the older 1.6.9 outstanding device checks listed below. Do not call this release-ready yet.
- App and widget versions are 1.7.0 (29). Release/review notes are local drafts in
  `docs/appstore-metadata.md`; the calendar privacy paragraph is a local draft for publication
  with 1.7.0. No archive, App Store upload, backend deploy, git commit or push was performed.
- The temporary-suspension parser and v2 fixture inconsistencies documented at intake remain
  deferred. This is the iOS holiday/manual subset, not implementation of the full DAYOFF v2 spec.

繁中交接：1.6.9 仍為線上版；1.7.0 已完成本機開發，新增設定、國定假日及可修改月曆。
上班／上課各自開關，手動設定最高優先。停班停課公告功能留待下一版。日曆排程有明示的
有效期限，仍需上述實機驗收；目前未上傳或發布。

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
the one item that is both a retention feature and the fix for backlog item 0. The evening
before each selected weekday, at a time the person picks (21:00 by default), a local
notification says what tomorrow's alarm will do; for the people whose background refresh
can never run, it is the only place the app tells them so.

- **`EveningPreviewPlanner`** (`Services/EveningPreview.swift`) is pure: from the armed
  `ScheduledAlarmSummary`, the selected weekdays and `now` it plans one preview per
  selected weekday for the coming week, each at the chosen clock time on the evening
  before, skipping an evening already gone. Only the summary's own ring carries the
  **decision** — rain or not, *where on the route* the highest probability was read
  (`ScheduledAlarmSummary.wettestSegmentName`, new, optional for stored summaries) and
  how it compares to the threshold, from what time to what time, and when the forecast
  was checked; the evaluate flow fetched that ring's forecast, so this is true. Every
  later weekday is **upcoming**:
  "there is an alarm; the morning's forecast decides", because that is what the
  background refresh does. Identifier `commute-rain-preview-YYYYMMDD` per alarm day.
- **Replaced on every registration, and nowhere else** — the foreground Schedule, the
  debounced settings reconcile, and `refreshScheduledAlarmUnattended()` from the
  background task all pass through `evaluateRouteAndScheduleAlarm()`, so an overnight
  refresh that changes the decision rewrites that evening's text with it.
- **"預報查詢時間" is when the forecast was fetched, not the preview time.** The user
  read the sample's stamp as "should be 21:00" (2026-09-07). A local notification is
  static text, so the stamp is the last evaluation — the last foreground open, or the
  last background run. To pull that towards the preview time there is now a third
  background task, `com.shukaihu.RainyClock.previewRefresh` (registered in
  `Info.plist`), requested for a window opening an hour before the first preview.
  When iOS grants it, the run re-decides and re-plans, and the stamp reads that evening;
  when it does not, the stamp is honest about what the text is based on. The request is
  dropped rather than resubmitted once its window has opened, or a run inside the window
  would re-plan, resubmit for "now", and spin until the preview time passed. **The user's
  position is that the preview must be decided at the preview time.** On-device that is
  not something iOS offers — no API runs app code at a chosen minute — so the choice is
  between this best effort and a server-sent silent push at the chosen time (the app would
  register a push token and its preview time with `weather-proxy`, which would need an
  APNs key and a scheduler; no route data leaves the phone, but "no backend state about
  users" stops being literally true). Recorded, not built: ship the best effort, read the
  stamps, decide from evidence.
- **The morning re-decision is announced when it changes the ring** (`AlarmDecisionChange`,
  same file). An unattended run that re-registers the *same* ring the preview described at
  a different time — rain went away and 07:00 is back to 07:30, or the reverse — sends one
  immediate, **silent** notification: where, the new probability against the threshold,
  the new time, and the minutes gained or lost. Silent because it lands minutes before an
  alarm; a sound would defeat the sleep it announces. Foreground runs stay quiet, the
  status line shows the result. Gated on the preview toggle. `AlarmDecisionChangeTests`
  (5 tests, a steerable weather stub and a preview spy) pin later, earlier, same-decision,
  foreground, and that every registration re-plans.
- **An unattended run inside today's check-point-to-ring window is skipped.** Found while
  answering the user's "what happens at 07:00" question (2026-09-07): with the normal alarm
  at 07:30 and the decision "no rain", a refresh granted at 07:10 would decide *tomorrow*
  (today's check point is past) and re-register the weekly alarm at tomorrow's time — and if
  tomorrow says rain, today's 07:30 never rings. Pre-existing, reachable, now guarded in
  `refreshScheduledAlarmUnattended()`: between `normalAlarmDate − rainLeadTime` and
  `normalAlarmDate`, return without touching anything. The 21:00
  default sits before the processing window opens (nine hours before the lead-time
  point); a later chosen time may land inside it, which only means the text is fresher.
- **Backlog item 0 is answered by detection, not guessing.** `UIApplication.shared.
  backgroundRefreshStatus != .available` or Low Power Mode at planning time puts a
  sentence on every preview: forecasts cannot update in the background right now, open
  the app. Nobody whose refresh works ever sees it, which is the "must not nag" line the
  backlog drew.
- **A toggle, `前一晚預告`, default on**, under snooze in the alarm settings card. On, it
  reveals **`預告時間`** (a compact hour-and-minute picker, `eveningPreviewTime`, default
  21:00 — the user asked for this the same day rather than a fixed hour), a one-line hint,
  and **`先看一則`**, which sends a sample three seconds later: the rainy variant for the
  next alarm, with the real background-refresh sentence if that applies. The button is
  also the most natural place to ask for notification permission, and it says where to
  turn notifications on if they are denied. None of this is in the schedule fingerprint.
  Off cancels the previews; on, or a new time, re-plans from the stored summary.
- **Notification permission on iOS 26 is new ground.** The alarm there is AlarmKit, whose
  permission is not notification permission, so this is the first thing that asks for
  `.alert` on iOS 26. It asks in three places, all foreground: an attended Schedule (after
  the alarm's own prompt), the toggle turning on, and `ContentView`'s launch task after
  the stale-refresh — that last one is for the install that upgraded with an alarm armed
  and never taps Schedule again. Unattended runs only read the status. On iOS 17–25 the
  alarm already asked, and the answer covers both. (1.8.0 adds a fourth place, on iOS 26 only:
  turning the temporary-closure rule on asks once while undecided, because the closure
  announcements are visible pushes; see "1.8.0 準備中".)
- **The 64-request budget is shared** with the iOS 17–25 notification alarms:
  `LocalNotificationScheduler.pendingNotificationLimit` dropped 64 → 56 to leave seven
  for previews. With all seven weekdays selected the alarm gets 8 requests a day (7
  follow-ups) instead of 9.
- **`EveningPreviewPlannerTests`** (9 tests): one evening per selected weekday inside a
  week; only the armed ring carries the decision; an evening already past is skipped and
  its decision with it; a ring several days out still gets its own eve; seven days give
  seven previews and never more; the background-refresh flag rides on every preview; only
  the chosen time's clock time counts; the sample is a rainy decision for the next alarm
  a few seconds out; an alarm just after midnight is previewed the evening before.
- Not done, on purpose: time-sensitive interruption level (needs an entitlement), and any
  "no rain tonight, so no notification" filtering — with the toggle the person chooses,
  and a reassuring "stays at 7:00" is the point on a dry night.

Checklist:

- [x] Version `1.6.9 (28)` in both places (`Info.plist` and the widget's
      `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`), verified in the built bundle.
- [x] Simulator build and the full unit suite pass (2026-09-07): 92 tests signed, all
      pass; unsigned (the documented command) 6 of the quota tests skip because the
      keychain refuses an unsigned host.
- [x] **Support card seen on the iPhone 17 Pro simulator 2026-09-07**, in both languages,
      with the installed bundle's `LevelPlayAppKey` blanked first so answering the consent
      sheet could not start the SDK. Under `-forceGDPRConsentGeography` the card shows
      both rows; without it, only 檢舉廣告 — the Taiwan view. The simulator bundle was
      rebuilt afterwards so `DerivedData` carries the real key again.
- [x] **Debug build installed on the iPhone 16 Pro 2026-09-07** — `1.6.9 (28)`, real
      LevelPlay key, all three background task ids in the bundle. The commands, for next
      time (the device id is from `xcrun devicectl list devices`):

      ```
      xcodebuild -project RainyClock.xcodeproj -scheme RainyClock -configuration Debug \
        -sdk iphoneos -destination 'id=291B73B2-5398-5E97-9103-EF98F048FEC3' \
        -derivedDataPath ./DerivedDataDevice -allowProvisioningUpdates build
      xcrun devicectl device install app --device 291B73B2-5398-5E97-9103-EF98F048FEC3 \
        DerivedDataDevice/Build/Products/Debug-iphoneos/RainyClock.app
      xcrun devicectl device process launch --device 291B73B2-5398-5E97-9103-EF98F048FEC3 \
        com.shukaihu.RainyClock
      ```
- [ ] **Check on the iPhone 16 Pro**, the registered test device: the caption appears
      under a real banner, the mail draft names it with a creative id, and — after
      spending the free generations — the rewarded line appears too. Then delete the app,
      reinstall, and confirm the voice sheet still shows the spent count. Then, with an
      alarm armed for tomorrow, wait for the preview time (or set the clock) and confirm
      the preview arrives with tomorrow's decision; toggle Background App Refresh off, reschedule, and
      confirm the extra sentence appears. The simulator cannot
      show this: a launch with `-forceGDPRConsentGeography` and the sheet swiped away
      leaves the SDK unstarted (correctly, per the no-simulator-impressions rule), so only
      the support card is visible there.
- [x] **Archived and uploaded 2026-09-07** as `build/RainyClock-1.6.9-28.xcarchive`, the
      CLI export path for the fourth release running. Verified first: app and appex both
      `1.6.9 (28)`, `LevelPlayAppKey`, the production `VoiceProxyURL`, all three background
      task ids, the ATT string, 152 SKAdNetwork ids, `IronSource.framework` the only embedded
      framework, `NSPrivacyTracking` still `false`, no `GAD*` keys, no Gemini key anywhere,
      LevelPlay and the new preview/keychain code both present in the binary. The usual
      IronSource dSYM warning appeared and means what it always means. On the phone before
      upload: the preview arrived, and the report mail carried the banner's creative id.
- [x] **Submitted 2026-09-07** with the 1.6.9 What's New and the review note — the 1.6.8
      note with "REPORTING ADS" replaced by the 2.5.18 paragraph, the evening-preview
      paragraph in front, and the AI voice section relabelled "added in 1.6.8". App Privacy
      unchanged.
- [x] **Release confirmed 2026-09-10** against the [Taiwan listing](https://apps.apple.com/tw/app/rainy-clock/id6780500386)
      and Apple's lookup API: `1.6.9`, released `2026-09-07T21:33:44Z` (September 8 in Taiwan).
      Remaining device checks are carried forward in the handoff section above.

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

**Day-off production activation and validation.** Local implementation is now integrated into
1.7.0 with owner approval (2026-09-15): shared formal NCDR API service, default-off device rules,
scheduling receipts and a read-only township map. This replaces the earlier unimplemented,
keyless/backendless proposal. Remaining work is a deployed HTTPS service with NCDR credentials,
APNs capability/signing/credentials, physical-device background and AlarmKit failure/recovery
checks, review of the 27-day date coverage limitation, and optional StoreKit entitlement gates.
Do not report this as live service or infer delivery from a successful push request. Current
contract: [DISASTER-PREVIEW.md](DISASTER-PREVIEW.md); simulator checks:
[1.7.0-SIMULATOR-CHECKLIST.md](1.7.0-SIMULATOR-CHECKLIST.md). Android remains separate.

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

## 2026-09-15 — 天災功能獨立預覽階段（歷史紀錄，後續已授權合入）

先在 `RainyClock-dayoff-preview/` 實作官方公告服務、手機判斷、日期略過與選用 APNs；當時未覆蓋原 `RainyClock-iOS/`。後續使用者授權合入 1.7.0，現在以本文件最前方 current handoff 為準。詳見 [DISASTER-PREVIEW.md](DISASTER-PREVIEW.md)。Day-off: preview parser/evaluator verified against spec v2 fixtures; backend API schema v1. 正式金鑰、部署、真機背景驗證與 StoreKit 付費閘門尚未完成；不應視為正式可用。

使用者確認伺服器方案後，預覽加入 authenticated sync receipts 與版本確認查詢；手機僅回報已成功處理的公告，失敗保留待送回報，後續執行機會重試。連續推播會再查最新 Feed，不丟棄同步中的新公告提示。No App Store update is required for each disaster announcement; production rollout remains pending.

原生天災地圖已加入預覽：22 縣市／368 鄉鎮市區、六種狀態、今天／明天、縣市放大、離島小圖及地點定位。公告解析不變更鬧鐘排程。163 iOS tests passed, 6 existing unsigned Keychain tests skipped; visual interaction checks pending Mac unlock. 詳見 [DISASTER-MAP-PREVIEW.md](DISASTER-MAP-PREVIEW.md)。
