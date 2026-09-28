# 天災停班停課：1.7.0 整合狀態

更新：2026-09-15。使用者先前要求的獨立預覽保留於 `RainyClock-dayoff-preview/`；現在已授權將這些功能整合回 **`RainyClock-iOS/` 的 1.7.0 (29)**，供模擬器檢視。App 使用原 bundle ID `com.shukaihu.RainyClock`，widget 為 `com.shukaihu.RainyClock.AlarmWidget`，不是另裝的 DayOffPreview 身分。合入前備份為 `/tmp/RainyClock-1.7.0-before-merge-20260915-220445.tar.gz`。

**2026-09-28 狀態：** 正式服務已部署（見下方「開發與啟用」），1.8.0 (38) 的工作樹已開啟 release gate 並填入 `DayOffServiceURL`；App 尚未封存，真機推播往返與權益歸屬仍待完成，見 [1.8.0 備忘](1.8.0-DEFERRED-DISASTER.md)。下段是 2026-09-15 合入時的原始說明。

**這是本機開發整合，尚未發布 App、部署天災伺服器或完成正式推播設定。** `DayOffServiceURL` 當時留白；NCDR key、APNs 憑證及真機流程仍待配置／驗證。正式廣告設定保留在原專案，模擬器的 Debug／Release 都由 `AppEnvironment.allowsAdvertising` 禁止廣告及追蹤授權流程，不需要額外啟動參數。畫面驗收見 [1.7.0 模擬器檢查表](1.7.0-SIMULATOR-CHECKLIST.md)。

## 採用的架構

```text
行政院人事行政總處公告
       ↓ NCDR 正式會員 Atom / CAP
單一共用服務，每 5 分鐘查詢、驗證、快取
       ├─ GET /v1/suspensions → 手機主動同步
       └─ 公告變更 → 同一則可見推播廣播給所有裝置（無位置資料）
              → 手機的通知擴充功能讀本機行政區、拉同一 API、改寫通知
手機比對原鬧鐘日期、住家／目的地行政區與停班／停課設定
       ↓
修改該日期的本機鬧鐘，成功後才顯示「已略過」
       ↓
POST /v1/devices/sync-receipt → 回報已處理的公告版本與時間
```

使用者已確認採用此架構。每次公告只同步資料與調整本機排程，**不需要重新發布或下載 App 版本**。集中取得公告可避免每支手機重複連線官方網站，且 NCDR key 不會放進 App。手機上傳選用推播所需的隨機 installation ID、APNs token 與裝置註冊 credential，以及最近一次成功處理的公告版本、資料檢查時間、處理時間與結果；住家、目的地、路線、行政區、鬧鐘時間及略過日期都保留本機。不代表背景推播能保證交付。

[DGPA 官方頁](https://www.dgpa.gov.tw/typh/daily/nds.html)說明前晚、清晨及其他時間均可能公告，所以每天只查一次不足。程式採 [NCDR 正式 API Key 介面](https://alerts.ncdr.nat.gov.tw/web/home/news/1000027)，不抓 DGPA HTML、不自動退回舊免金鑰網址。官方 Feed 可以保留很久以前的最近事件；HTTP 200 不等於今天放假。

## 手機功能

新增原生台灣分區地圖：22 縣市／368 鄉鎮市區、日期切換、六種公告狀態、住家與目的地定位；詳見 [地圖預覽說明](DISASTER-MAP-PREVIEW.md)。

本次整合的頁面結構為 **鬧鐘／設定**；設定分成 **時間／路線／日曆／其他**，天災設定及地圖位於 **設定 → 日曆**。鬧鐘頁顯示狀態，資訊可連往對應設定。保留原深色、藍色重點與圓角卡片樣式；選項直接保存，不需要「套用」按鈕或設定完成橫幅。原生 UI 已移植，合入後驗證結果記錄於下方；先前預覽紀錄保留供追溯。

- 功能預設關閉；舊版本設定遷移不會自行開啟。
- 選擇停班、停課；同時勾選時採 **OR**：任一公告符合即略過（使用者 2026-09-22 決定，spec v3）。
- 各別選擇住家、目的地的縣市／鄉鎮市區。地圖辨識可供點選確認，不在背景猜地址，不檢查路途中間地區。
- 任何一個已選地點符合完整公告即可略過該日；不影響隔天、下週。
- 國定假日、原重複星期及啟用中的手動日期規則先決定是否本來要響；手動「照響」優先於自動天災規則。
- 以原本的鬧鐘日期比對公告。雨天提前跨午夜不會判錯放假日。
- 支援確定的全天／上午公告；上午公告不取消午後鬧鐘。下午、晚上、村里／個別學校、未知句型、非 Actual、撤銷、資訊矛盾、日期不符或超過 18 小時的公告均不新增略過。
- 公告與實際套用狀態分開保存。排程失敗時顯示待確認，保留修復資訊；關閉功能後未完成的恢復會在下次前景／背景機會重試，不受天氣快取阻擋。
- 晚間預覽使用已成功登記的略過日期；範例畫面只解說，不會操作真實鬧鐘。
- APNs payload 只是要求同步，不可直接指定取消哪個鬧鐘；可見推播的內容由手機改寫，見下方「推播與整晚沒碰手機的使用者」。裝置註冊使用 Keychain 隨機 credential，啟停請求依序對帳，避免重開功能被較晚完成的刪除請求蓋掉。
- 手機完成系統排程，或確認原排程符合最新公告後，才送出 `applied` 回報；没有啟用鬧鐘則回報不同的 `no_alarm`。下載失敗、排程失敗、設定變更尚未套用、公告已被更新版本取代或快取過期，都不能回報已套用。
- 回報失敗保留最新一筆，於後續啟動／推播機會重試；關閉功能清除待送回報並取消裝置註冊。回報與註冊依序執行，舊回報不能覆蓋新回報。
- 同步途中收到新的推播會排入下一次查詢，並讓呼叫端等到最新一輪完成；不會只重用上一筆快取就結束。

## 推播與整晚沒碰手機的使用者（作法 B，2026-09-23 決定）

iOS 不保證靜默推播或背景更新會執行；一支整晚沒被碰過的手機可能到早上都沒醒來。使用者選定的做法是**讓通知本身把話說完，而不是指望 App 醒來**：

- 伺服器一有新公告，就對**所有**登記的裝置送同一則可見推播（`APNS_PUSH_MODE=alert`），內容只有本地化的通用文字與公告版本號。伺服器不知道、也不保存任何人的縣市或行政區。
- App 把使用者在設定裡確認過的住家／目的地行政區、停班／停課開關、下一次鬧鐘的原定日期與服務網址，鏡射到 App Group（`group.com.shukaihu.RainyClock`，`DayOffSharedState`）。只有這些；沒有地址、路線、推播 token 或 credential。鏡射用的是**有效**設定，所以 1.7.0 的 release gate 和會員閘門在擴充功能裡同樣生效。
- `RainyClockDayOffNotification`（Notification Service Extension）在推播到達時由系統喚醒，App 不必在跑。它讀 App Group、自行 GET `/v1/suspensions`，用**和鬧鐘同一個** `DisasterSuspensionEvaluator` 判斷，再改寫通知（`DayOffPushContent`）：
  - 符合：標題「新竹縣尖石鄉已公告停班停課」，有聲音、時效性等級，鎖定畫面直接看到。
  - 相關但不略過（村里層級、句型未知、資料矛盾）：通用標題，正文是判斷理由，有聲音。
  - 無關：通用標題，「與你設定的地區無關，鬧鐘照常」，無聲、被動等級，只留在通知中心。
  - 判斷不了（功能關閉、沒設行政區、沒有下一次鬧鐘、拉不到公告）：不改寫，系統顯示伺服器的通用文字。
- `apns-collapse-id` 讓每台裝置永遠只有一則，新版本取代舊的；颱風夜不會堆一排。
- 擴充功能**不碰鬧鐘**。略過仍然只由 App 在自己成功比對、成功改排程後決定；通知說「會依設定處理」，不說「已取消」。
- 需要 App 的 App Group 與 Time Sensitive Notifications entitlement；擴充功能 bundle 為 `com.shukaihu.RainyClock.DayOffNotification`。Xcode 自動簽章會在開發者網站補上 App Group capability，首次真機安裝時留意。

## 伺服器確認的範圍

`POST /v1/devices/sync-status` 需要該裝置 credential，回應 `applied`、`no_alarm`、`pending` 或 `source_unavailable`，以及最近一次回報時間。只有回報版本符合目前可用公告，而且處理時間仍在台灣當日，才回應前兩種；新公告、跨日或來源失效不沿用舊成功狀態。這是**手機曾完成處理的紀錄**，不是持續監控手機、更不是保證未來鬧鐘狀態不變。

English: The accepted design uses a shared announcement service and on-device scheduling; individual disaster events do not require an App Store update. An authenticated, timestamped receipt records successful local processing only. Failed or superseded work cannot acknowledge the current revision. Receipts contain no locations, alarm times or skipped dates, and do not guarantee push delivery or future alarm state.

## 排程與可靠度界線

iOS 不保證背景任务或靜默推播何時執行；強制結束 App、網路中斷或低耗電均可能錯過更新。伺服器接受或發出推播，不代表手機已取消鬧鐘。[Apple 背景更新說明](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)

沒有可用公告時不建立天災略過；若已略過後在響鈴前取得錯誤／無效的新結果，當次執行會嘗試恢復原日期，並只在系統成功後更新顯示。已停止執行的 App 無法在快取過期那一刻自行恢復，因此這項功能不能宣稱即時或百分之百同步。

目前整合版的日期排程採 **27 天滾動視窗**，取代先前開發版 iOS 26 路徑一次排 366 天的方式。這是為控制系統鬧鐘／通知數量；頁面顯示涵蓋期限並沿用期限提醒，開啟或背景更新時延長。**超過期限且完全沒有執行機會，固定日期鬧鐘不會自行產生。** 此限制仍需在上架前完成產品評估與真機驗證，不能把日期排程當成永久重複鬧鐘的無條件替代品。

AlarmKit 更新重用未變動日期的 UUID，只新增／淘汰有變化的日期。若替代項目建立前失敗，清理本輪新增並保留舊排程；開始淘汰舊項目後發生錯誤，保留已建立的替代鬧鐘並回報待修復，避免清理動作造成漏響。AlarmKit 沒有原子交易，部分失敗可能短暫有重複項目，仍需下一次對帳及真機測試。

## 開發與啟用

1. 開啟 `RainyClock-iOS/RainyClock.xcodeproj`，選 RainyClock scheme。Debug／模擬器 build 無需連線天災後端即可檢視設定及明確標示的地圖範例。
2. 部署 [dayoff-service/](../dayoff-service/)：2026-09-24 起它已是無狀態設計（做法一）——Cloud Scheduler 每 5 分鐘觸發 Cloud Run Job `rainyclock-dayoff-poll` 抓 NCDR、寫 Firestore `dayoff-production`、推播；request-only Cloud Run 服務 `rainyclock-dayoff` 只讀寫 Firestore。指令、環境變數、runbook 與實際執行紀錄在 [dayoff-service/DEPLOYMENT.md](../dayoff-service/DEPLOYMENT.md)；NCDR key 與 APNs 金鑰放 Secret Manager，權限授予由 `dayoff-service/deploy/iam.sh` 手動執行。
3. **1.8.0 起 gate 已開：** `AppEnvironment.supportsTemporaryClosures = true`，設定 → 日曆的「使用臨時放假規則」開關、天災設定與地圖都隨之出現；規則是否生效仍由會員權益（`MembershipSchedulingAccess.effectiveSettings`）決定，而權益歸屬尚未決定（見 1.8.0 備忘）。
4. **服務網址已填：** `RainyClock/Info.plist` 的 `DayOffServiceURL` = `https://rainyclock-dayoff-510427696731.asia-east1.run.app`（正式），另有 `DayOffSandboxServiceURL` = `https://rainyclock-dayoff-sandbox-510427696731.asia-east1.run.app`。兩者都是公開根網址，不是機密；NCDR/APNs key 絕對不要放這裡。`AppEnvironment.dayOffServiceURL` 依 APNs 簽章環境選擇，**不**沿用會員 sandbox 規則：所有 `#if DEBUG` 建置（日常的 `RainyClock` scheme／`Debug`、`RainyClock Membership Local`、Debug Sandbox）都簽 `aps-environment = development`，token 屬 APNs sandbox，正式堆疊會回 `BadDeviceToken` 且不會清掉，所以 Debug 一律走 sandbox 堆疊；Release 永遠正式；sandbox 值缺少或格式不對時得到 nil，不會退回正式。XCTest 下永遠 nil。同一個網址經 `DayOffSharedState.serviceURL` 鏡射到 App Group，所以通知擴充功能跟 App 連同一個堆疊。因此 DEPLOYMENT.md「手機端」第 1 步（手改 `Info.plist` 指向 sandbox）已不需要：用任何 Debug scheme 裝真機即可。若將來要從 Debug 讀正式公告，應加明確的啟動參數並同時關掉推播註冊，不能讓正式成為預設。
5. 要啟用推播，需替正式 App bundle ID `com.shukaihu.RainyClock` 核對 Apple Push Notifications capability、有效簽章與 provisioning profile；伺服器設定獨立 APNs key、team、key ID、topic 與 sandbox／production 環境。目前天災 entitlements 宣告 development；TestFlight/App Store 前須確認正式簽章環境。Xcode Debug 裝置的 token 在 APNs sandbox，正式堆疊（`APNS_PRODUCTION=true`）會拒收，所以 Debug 真機一律走 sandbox 堆疊（`APNS_PRODUCTION=false`）。sandbox 堆疊的部署腳本 `dayoff-service/deploy/sandbox.sh` 截至 2026-09-28 尚未對專案執行，見 DEPLOYMENT.md「執行紀錄（sandbox）」。原獨立預覽的 APNs topic 不可直接沿用到本專案。
6. 真機驗證晚公告、重啟、背景／低耗電、關閉背景更新、強制結束、取消權限、公告撤銷與關閉功能恢復。尚未做這些實測，不能稱已上線。

本次沒有對外設定 NCDR 帳戶、Apple capability、付費訂閱或雲端帳務，也沒有發送真實 APNs。日曆與天災的付費方案／StoreKit 權益閘門**尚未實作**；本機整合不會啟用收費。

## 驗證紀錄與本次合入待驗項目

本次 MAIN 1.7.0 原生整合已完成 Debug 編譯與 XCTest：**169 通過、6 項既有未簽署 Keychain 測試略過、0 失敗，共 175 項**。包含新增的 6 項首次自動排程測試。結果：`/tmp/RainyClock-1.7.0-DerivedData/Logs/Test/Test-RainyClock-2026.09.15_22-13-10-+0800.xcresult`。隨後只調整首頁時間更新，最終 build 再次成功。Mac 鎖定，完整畫面點選仍待人工驗收。以下 163／6 屬於先前獨立預覽的歷史紀錄。

- iOS Debug 編譯及模擬器 XCTest 通過：163 項通過、6 項既有 Keychain 測試因未簽署的測試環境略過、0 項失敗；含共用 spec v2 的 28 組解析、25 組決策案例，收據傳輸／排程整合測試，以及 10 項地圖公告狀態、3 項完整圖資驗證。結果：`/tmp/RainyClock-DayOff-DerivedData/Logs/Test/Test-RainyClock-2026.09.15_21-43-02-+0800.xcresult`。
- Node 服務：本次在 **MAIN `RainyClock-iOS/dayoff-service`** 執行 `npm ci`（audit 0），再以 Node 22 執行全部 **52 項測試通過、0 失敗、0 略過**；包括 13 項回報驗證、身分驗證、持久化、舊回報去重、跨日及來源失效案例。全部為本機 fixture／假 transport，不使用真實 API Key 或推播憑證。
- 獨立預覽階段曾確認原 `RainyClock-iOS/` 的 tracked diff 未改變；使用者此次授權合入後，原目錄已包含整合修改，該歷史比對不再描述目前狀態。
- 先前地圖完成原生畫面檢視，但互動工具曾受 Mac 鎖定影響；本次合入後的互動檢查以新的檢查紀錄為準。真實 NCDR key、APNs 與裝置端取消鬧鐘仍未端到端驗證。

共用 `docs/dayoff-fixtures.json` 沒有改期望值。`DAYOFF-SPEC.md` 的舊 keyless 與背景能力敘述以本文實作界線為準；此次 iOS 1.7.0 整合不代表 Android 已接入。
