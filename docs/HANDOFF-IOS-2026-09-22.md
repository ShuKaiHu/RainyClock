# Rainy Clock iOS 交接 — 2026-09-22

> **歷史快照：最新請先讀 [2026-09-23 交接](HANDOFF-IOS-2026-09-23.md)。** 34 已退審、35 已提供內部 TestFlight；價格差異仍未確認解決，繁中 6.5 吋已改用新版圖。本檔的版本、審查與工作樹狀態僅代表整理當時，不覆蓋後續紀錄。

本檔供下一個 AI 直接接手。整理日期為 2026-09-22；雲端／ASC 最後已核對的操作與使用者截圖主要來自 9/21 晚間。本輪僅整理本機文件，**沒有重新查詢 9/22 的審查或雲端狀態**。

## 先掌握目前結果

- **1.7.0（34）已由使用者正式提交 App Review**。成功頁顯示「已提交 4 個項目」；提交前截圖確認是 App、訂閱群組、月訂閱、買斷。不是只有 TestFlight 上傳，也不是尚待按提交的草稿。
- **尚無審查通過或公開上線證據**。先前已確認採手動發佈；本輪沒有改動。下一步先查看 Apple 回覆／當前狀態，不要重做送審或重建商品。
- **TestFlight 卡片美元、Apple 原生付款台幣的問題尚未解決**。SK1 與 SK2 已比較完畢；不要又請使用者刷新、改手機語言、重裝或重跑相同測試。
- 會員、付款、後端額度與 UI 已實作且部分正式服務已部署；**模擬測試、雲端元件成功、實機完整驗收是不同層次**。下面保留仍缺的證據。
- 沒有建立自動監看審查狀態的排程。此前僅告知使用者收到通知後貼回。

## 工作目錄與保留事項

- 目錄：`/Users/shukaihu/Code_Project_Local/RainyClock-iOS`；本輪確認 branch 為 `ios/main`。
- **大量既有未提交修改與未追蹤檔案屬於這次功能及其他 session，必須保留。** `git status --short` 可看到會員、天災、UI、測試、後端及文件。不可 reset、clean、整批覆寫或為了整理而回退。
- 下一個 AI 必須讀取這個實際工作目錄；只 checkout HEAD／另建乾淨 worktree **不會帶入尚未提交的實作**，也不能假設遠端已保存它們。本次沒有 commit／push。
- 只處理 iOS 與其相關後端，不修改 `android/` 或 Android 工作樹。既有 `weather-proxy` 也服務其他版本／平台，修改前要確認影響。
- 先讀 `CLAUDE.md` 的工作樹規則。但其中開頭「No backend」已過時；詳細文件亦混有歷史快照。現況以本檔、`STATUS-IOS.md`／`1.7.0-RELEASE-READINESS.md` 最上方新紀錄和實際程式為準。
- 不將 Apple 私鑰、LevelPlay 私鑰實值、session/JWS、個人稅號、銀行資料或測試帳號密碼寫入交接檔／Git／日誌。相關秘密已由 Secret Manager 管理。

## 最新產品決策（不要套回舊方案）

| 項目 | 現行決定 |
| --- | --- |
| 美國 | 月訂閱 US$1；買斷 US$10 |
| 台灣 | 月訂閱 NT$10；買斷 NT$100，獨立指定價格 |
| 其他商店 | 售價未定；上次 ASC 核對兩商品僅供應美國、台灣，未來新地區自動供應關閉 |
| 年訂閱 | 不再販售、0 供應地區、沒有加入本次送審；歷史已驗證年交易仍要正常處理，停售不等於撤權 |
| 月訂閱與買斷權益 | **均移除 banner、解鎖日曆、每天一次免看廣告的 AI 生成** |
| 買斷優先 | 買斷永久持有目前這些權益，會員顯示優先於訂閱；有效買斷不再提供重複月訂閱購買 |
| 同時持有 | 每日 AI 共用一次；已有 Apple 訂閱仍顯示真實續訂狀態，不會自動取消或退款 |
| 免費 AI | **初始一次，非每日一次**。原先三次已被最新要求取代 |
| 額外 AI | 每完成一次已驗證獎勵廣告可生成一次；播放、試聽或套用既有音檔不扣次 |
| 每日重置 | 使用者所在地午夜、未用不累積；會員各裝置共用時區／額度。時區變更有防多領措施 |
| 扣次時機 | 生成成功且伺服器可靠保存才扣；失敗返還原來源，重試／重下載不可重扣 |
| 舊會員遷移 | 符合條件的舊會員固定補一次，且不可重領；手機舊廣告申報保留待核對，不直接信任餘額 |
| 到期／離線 | 保留使用者設定及既有排程；確認無日曆權益後，下次安全重排才使用基本規則。有有效買斷則日曆仍可用 |
| 註冊／付款 | 免另外註冊 Email／密碼或另按 Apple 登入；Apple 驗證資料認回會員，付款用 StoreKit |
| 資料同步 | 恢復購買只恢復權益，不是鬧鐘設定／音檔跨裝置同步 |
| 對外文案 | 說「移除 banner」，不可說完全無廣告，因額外 AI 仍有獎勵廣告 |
| 天災功能 | **1.7.0 不公開颱風／臨時放假**；保留實作至 1.8.0（原定 1.7.1，2026-09-24 改），未來是否納入買斷尚未決定 |

`PRODUCT_DECISIONS.md` 記錄最新決策及歷史；舊「買斷不含日曆」「年費優惠」「免費三次」都不可當作現行規則。

## 目前 UI／功能形態

- 底部兩頁「鬧鐘／Alarm」與「設定／Settings」。Alarm 顯示**明天**預計響鈴時間、提早／略過原因及 Home／Work 動態天氣，不是今天的測試鬧鐘狀態。
- 晴天天藍、暖色太陽；雨天偏紫；陰天與雨天明顯區別。動畫已加強；減少動態效果／不在前景時停止。天氣卡只有 Home、Work、交通方式導向 Route，整張卡不可都能點。
- 設定四頁「時間／Time、路線／Route、日曆／Calendar、其他／Other」，可水平切換；選項直接保存，不設套用按鈕。Route 不顯示天氣，卡片樣式一致，路線預覽可收合。
- Repeat days 在 Calendar；Time 分別設定**提早響鈴／原定時間響鈴**，兩者共用 AI 額度。
- 日曆支援台灣及美國常態聯邦假日／標準補假，不含所有州、學校與雇主例外。月份水平滑動，只有今天有框；橘點表示與目前選定規則不同，還原即消失。
- 會員方案卡順序為 **Monthly subscription → One-time purchase**；買斷會員地位優先與卡片順序是不同規則。
- 已購買按鈕停用，訂閱顯示效期、auto-renewal 狀態；續訂列打開 Apple 管理介面，沒有假造本機續訂開關。恢復購買／管理訂閱／刪會員是正式功能，收在右上角 ⋯，不可當成測試功能刪掉。
- `AppEnvironment.supportsTemporaryClosures = false`，1.7.0 的 UI、排程、網路流程均受此開關限制。原天災偏好及程式保留；不要為此刪檔或解除所有 gate。

## App Store Connect 已完成狀態

| 識別 | 值 |
| --- | --- |
| App／Bundle | ASC `6780500386`；`com.shukaihu.RainyClock` |
| 已送審版本 | `1.7.0 (34)`，App 與 extension 本機版本也仍為 34 |
| ASC build ID | `b10ab298-bc2e-499e-9ae4-11e289fbafee` |
| 訂閱群組 | RainyClock Plus，`22390056` |
| 月訂閱 | `com.shukaihu.RainyClock.plus.monthly`；ASC `6812814060` |
| 買斷 | `com.shukaihu.RainyClock.banner.lifetime`；ASC `6812814810` |

- 34 已 archive／上傳／處理完成，內部 TestFlight 群組 `SKHU tester` 可用。**9/21 使用者最後自行提交上述四項，成功截圖已確認。**不要因前段文件寫「缺圖片」而要求重傳一次。
- 一般審查說明已保存為 [appstore-review-notes-1.7.0-34.txt](appstore-review-notes-1.7.0-34.txt)，並已寫入 ASC。包括功能入口、方案權益、Local StoreKit 圖片範圍、TestFlight 廣告限制及價格差異；亦坦白說明仍在驗收的流程。
- 中英文 Description／What's New 已更新。公開隱私政策及 ASC 隱私問卷已更新，詳見下方服務紀錄。
- 商店 6.9 吋截圖：繁中、英文各六張原生 PNG 已由使用者手動上傳並讀回。素材實際拍攝 build 30，供 1.7.0 新 UI 使用；送審 binary 是 34。見 [截圖 README](appstore-1.7.0-screenshots/README.md)。
- IAP 審查圖片是帶橘色測試提示的**真實 Local StoreKit 畫面**，僅供功能位置說明，不是台灣價格驗證、不放公共行銷組。使用者最終已補商品圖、加入兩商品並提交；「1024×1024 影像（可留空）」是另一個宣傳欄，不是審查截圖欄。
- **未再次核對**：6.5 吋舊圖是否已移除、審查電話／Email 最後值、DSA 最新狀態。提交前上次看到 6.5 吋繁中 C1/C2/C3、英文 E2/E1/E3，聯絡兩欄空白；不要由提交成功推論後來填了什麼，也不要直接宣稱它們仍阻擋提交。
- 上次確認銀行使用中、Paid Apps Agreement 有效、稅表完成；不重做稅務／銀行表單，不在文件複製個資。
- Chrome 上傳曾被擴充功能「允許存取檔案網址」權限擋住；使用者選擇手動上傳。不要繞過該權限或再次假設代理可上傳。
- ASC [App 審查](https://appstoreconnect.apple.com/apps/6780500386/distribution/reviewsubmissions)、[版本頁](https://appstoreconnect.apple.com/apps/6780500386/distribution/ios/version/inflight)。使用新工具時重新讀取頁面，舊 session 的 tab ID／元素編號不是長期識別碼。

## 未解決的 TestFlight 價格差異

9/21 22:05，使用者 iPhone 16 Pro／iOS 26.6.2／TestFlight 1.7.0（34）實測：

| 資料來源 | 實際結果 |
| --- | --- |
| StoreKit 2 Storefront／商品 | USA；月 US$1、買斷 US$10 |
| StoreKit 1 全新商品查詢 | 也為 USD；查詢後 storefront USA |
| Apple 原生月訂閱確認頁 | **NT$10／月** |

- `MembershipView` 使用 `Product.displayPrice`，不是依英文介面硬寫美元；手機在台灣／使用英文也不能決定商城。
- **SK1 fallback 在這個案例無效**；不能再用 API 回報 USA 斷言使用者登入美國帳號。付款視窗價格與 App 商品 metadata 確實不同。
- 31 加入診斷；32 修正不必要的 Apple 身分 refresh；33 加入商品重載與商店一致性保護；34 加入只讀兩套 Apple API 比較。34 是診斷完成，不是價格問題已修好。
- Apple [iOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes) 曾列 TestFlight Storefront metadata 修正 `181766819 / FB23646993`。它是相符線索，**不是已證明本案一定同一 bug，更不是正式 App Store 必定正常的保證**。
- 未批准固定 TWD 表、依語言／GPS 改價、用舊交易金額當新購報價、隱藏價格或使用者手動選國家的變通方案。不可默默實作它們。
- 沒有因本次問題再發 build 35，沒有提交 Apple Feedback。若後續需要回報 Apple 或測其他 OS，先利用已取得的證據；不要要求使用者為此升級手機系統。
- 月訂閱確認 NT$10 不代表這次也驗證了買斷 NT$100，更不代表圖片中的購買已完成。價格展示與會員交易驗收要分開。

## 會員／後端的實際接線

最後雲端核對是 9/21；下列為已部署紀錄，不是 9/22 即時探測。

| 環境 | 服務／資料庫／驗證 |
| --- | --- |
| 正式 App Store | Cloud Run `rainyclock-membership`，Firestore `membership-production`／namespace `membership_production_v1`，Apple Production，production App Attest |
| TestFlight | **同一 Cloud Run，獨立** `membership-testflight`／namespace `membership_testflight_v1`，Apple Sandbox，仍為 production App Attest |
| Xcode Debug Sandbox | 舊獨立 `rainyclock-membership-sandbox`／`membership-sandbox`，development App Attest；不是 TestFlight 資料庫 |
| Local StoreKit | Xcode 本機 fixture，只驗 UI／StoreKit 流程，不連正式會員與不發正式 AI 額度 |

- Google Cloud 專案 `rainyclock`、區域 `asia-east1`，Firestore Standard／Native。手機／Web deny-all，僅後端最小權限帳號讀寫。不要另建重複資料庫。
- Release URL：`https://rainyclock-membership-510427696731.asia-east1.run.app`。最後 active revision `rainyclock-membership-00005-5pm`（100% traffic，health 200）。
- 環境 header 只是路由提示，Apple JWS／App／商品／App Attest／session 都要獨立驗證，不能由手機宣告付費或環境即可獲權益。`appTransactionID` 現行 SDK 支援 back-deployment；本專案按 iOS 17 實作，空識別拒絕、不以裝置 UUID 替代會員。
- Apple Notifications V2 路徑 `/v1/membership/apple/notifications/production`、`/sandbox` 已在 ASC 設定；兩環境 TEST 投遞 SUCCESS。Sandbox 驗簽後才可轉送舊 Debug Sandbox；TEST 成功不等於續訂／退款事件完成驗收。
- 會員 Firestore transaction 處理並行預留、成功保存音訊與扣次、失敗歸還；同 request ID 重試取原結果，不重生成。音訊最大 480 KB、成功後可取回 24 小時；過期不可默默重新生成。
- LevelPlay S2S 官方簽章＋event ID 去重已接入；reward=1。callback：`/v1/membership/levelplay/callback`。手機「看完廣告」只觸發查詢，不能直接加額度；不可重新加入 AdMob。
- 私鑰由使用者指定並批准保留，已入 `membership-levelplay:1`；不要在新檔重述實值。其他 Secret Manager 名稱為 `membership-production-identity`、`membership-testflight-identity`、Apple IAP `membership-sandbox-apple-iap`。名稱含 sandbox 不代表該 Apple 金鑰只可驗 Sandbox；真正隔離由 verifier／服務設定處理。
- 身分 HMAC 密鑰不可直接輪替，否則可能無法認回原會員；須先設計版本化移轉。兩環境另共用 UTC 日 2,000 次上游生成嘗試的成本上限，這與每會員當地每日一次是兩套不同限制。
- **目前 simulator／Debug Sandbox／TestFlight 都禁止正式廣告 SDK 流量**；TestFlight 的免費方案沒 banner 不能直接判斷權益錯。官方測試廣告要另外按測試設定驗證，不解除保護來製造正式廣告流量。
- 兩庫 TTL／索引已部署；`rainyclock-membership-deletion` Cloud Run Job＋同名 Scheduler 每五分鐘清理刪除待辦，已受控驗證。失敗／backlog 通知告警尚待設定目的地。
- 舊 `rainyclock-weather-proxy`／匿名 TTS 仍有舊版與其他平台相容性，不能直接停掉，也不能宣稱所有語音路徑都已受新會員額度限制。
- `annotate.js` 已移往 `gemini-3.1-flash-lite`／`us` 端點；真實英文與繁中分類及美國 Cloud TTS 已成功。部署細節以 release readiness 為準，不把舊 README 的 TTS_DISABLED 狀態套到新正式服務。
- 9/21 已發布公開 [隱私政策](https://shukaihu.github.io/RainyClock/privacy-policy.html)，日期 21 September 2026；ASC 11 類隱私資料已發布。刪會員不取消 Apple 訂閱。刪後最少 HMAC 防重紀錄仍無自動期限，**保留政策審查尚未完成，不能稱完全匿名或已全數合規**。

## 測試證據與尚缺驗收

以下是先前已跑結果，本次交接整理**沒有重新執行測試**，不同批次有重疊，勿加總成一個總數。

| 已有證據 | 範圍／限制 |
| --- | --- |
| 最新後端＋Firestore Emulator 189 passed，0 failed/skipped | 並行、重送、跨日、失敗返還、遷移、權益、安全與清理；不是所有真實交易已跑過 |
| build 32：70 項；33：81 項；34：27 項 iOS focused／Local StoreKit 通過 | 各版修正範圍不同、非全部完整產品測試；34 含真實本機 SK1／SK2 比較 |
| Release archive／upload 34 成功 | 無 `.storekit` 打包；已知 IronSource 第三方 dSYM 警告非當次上傳阻擋 |
| Debug Sandbox 真機美國買斷、台灣月訂閱 | 已看到權益與訂閱效期／續訂 UI；不是新 TestFlight 雙庫完整驗收 |
| TestFlight build 31 challenge／session 200 | 新服務會員建立成功；之後32修正重複 Apple 認證，付款視窗可開啟 |
| Apple Production／Sandbox TEST 通知成功 | 只證明通知投遞與驗章，不是退款／續訂真事件證據 |
| LevelPlay 官方 Dashboard「Your callback settings are valid」及重送一次入帳 | 使用隔離 fixture，資料已清除；不是手機看測試廣告→領獎→生成整條流程 |
| 真雲端英文／繁中 TTS 有效 PCM、刪除維護受控成功 | 元件已通，仍不能替代手機生成下載／刪帳 UI 完整驗收 |

仍需取得或核對的端到端證據：

1. **確實從 TestFlight 開啟**，買斷／月訂閱成功後 Apple 交易、後端權益及 App UI 一致；同環境恢復、重新安裝與換機認回，並行用量不重領。
2. 真實退款、取消續訂、續訂／到期，確認無日曆權益後安全重排；有買斷則保留權益。使用者曾送出 Sandbox 退款申請，不能直接當成 Apple 已撤銷成功。
3. TestFlight 新會員服務的 AI 生成→保存→只扣一次→重播／重下載不扣。使用者曾回報成功，但當時新庫找不到對應紀錄、可能為相同 build 的 Debug Sandbox，所以尚不能標新服務全程驗收通過。
4. 官方測試廣告→S2S→會員獎勵→生成；中途關閉、重送、生成失敗時保留獎勵。不得以手機假回報或真廣告流量替代。
5. 實際鎖屏響鈴、提早／原定兩種聲音、稍後提醒、離線保留排程；首頁預覽的是明天，不能以首頁時間斷定今天測試排程。
6. HMAC 防重保留政策與刪除維護告警；6.5 吋舊商店圖、最後聯絡欄位及最新 DSA 狀態尚未重新查核。

## 接續工作的順序

1. 先讀此檔和最新 STATUS；確認當前工作樹，保留所有未提交實作。不要先重建所有功能或再提相同產品問題。
2. 使用者提供 Apple 回覆時，或要求查看狀態時，再即時讀 ASC。若退件，按實際理由修正；若通過，仍需完成待驗收項目並確認後續發佈安排。不要僅為價格診斷重複相同 build，或自行撤回已送審項目。
3. 如要補測，依上節挑有明確判別力的一次操作，對照環境與後端記錄；不要再要求已完成的 SK1／SK2 價格比較。
4. 後續若確需新 binary，App `Info.plist` 與 extension 的 project build number 要一起提高；保留 Release production App Attest、會員 URL，且不可帶入 Local StoreKit fixture。
5. 1.8.0 天災工作另依 [保留備忘](1.8.0-DEFERRED-DISASTER.md) 接續，先前原則為家／工作地行政區匹配，經過地區不算。不要默默把尚未批准的下一版的權益加到買斷承諾。

## 程式入口與文件導航

| 工作 | 主要檔案 |
| --- | --- |
| 最新時序／雲端證據 | [STATUS-IOS.md](STATUS-IOS.md)、[1.7.0-RELEASE-READINESS.md](1.7.0-RELEASE-READINESS.md)（先看頂端新節） |
| 產品規則／歷史測試環境 | [PRODUCT_DECISIONS.md](PRODUCT_DECISIONS.md)、[MEMBERSHIP-AND-PAYMENTS.md](MEMBERSHIP-AND-PAYMENTS.md)、[MEMBERSHIP-STAGING.md](MEMBERSHIP-STAGING.md) |
| 原生 UI | `RainyClock/ContentView.swift`、`MembershipView.swift`、`SettingsCalendarView.swift`、`CommuteWeatherCard.swift` |
| 會員 StoreKit／權益 | `RainyClock/Services/MembershipManager.swift`、`MembershipModels.swift`、`MembershipClient.swift`、`MembershipSecurity.swift` |
| AI／廣告 | `MembershipVoiceGeneration.swift`、`MembershipRewardFlow.swift`、`AIVoiceQuota.swift`、`RewardedAdController.swift`、`RainyClock/AppEnvironment.swift` |
| 價格診斷 | `RainyClock/Services/MembershipLegacyPriceProbe.swift`、`MembershipView.swift`、`RainyClockTests/MembershipLegacyPriceProbeTests.swift` |
| 排程／日曆 | `AlarmCalendar.swift`、`TomorrowAlarmStatus.swift`、`AlarmKitScheduler.swift`、`NotificationScheduling.swift`、`ViewModels/AlarmViewModel.swift` |
| 後端 | `weather-proxy/membership/server.js`／`runtime.js`／`router.js`；`apple.js`、`attestation.js`、`auth.js`、`service.js`、`store.js`、`generation.js`、`rewards.js`、`budget.js`、`policy.js` |
| 清理作業 | `weather-proxy/membership/maintenance-cli.js`、`maintenance.js`、[MAINTENANCE.md](../weather-proxy/membership/MAINTENANCE.md) |
| 實機指南 | [1.7.0-DEVICE-TEST-GUIDE.md](1.7.0-DEVICE-TEST-GUIDE.md)；下半部普通 Debug／舊價目為歷史，不可蓋過本檔 |
| 上架素材／文字 | [appstore-1.7.0-screenshots/README.md](appstore-1.7.0-screenshots/README.md)、[appstore-review-notes-1.7.0-34.txt](appstore-review-notes-1.7.0-34.txt)、[app-store-submission-checklist.md](app-store-submission-checklist.md) |

本機測試可用 Xcode schemes `RainyClock`、`RainyClock Membership Local`、`RainyClock Membership Sandbox`。後端 `npm test` 在 `weather-proxy/`；Firestore 交易測試需 Java 21／Emulator，`FIRESTORE_EMULATOR_HOST=127.0.0.1:8686`，詳見後端 README 的測試章節。缺 Emulator 時的 skipped 不可當整套通過。

重要歷史記錄在 `/tmp/rainyclock-170-34-archive.log`、`/tmp/rainyclock-170-34-upload.log`、`/tmp/rainyclock-membership-34-regression-tests-20260921.log`、`/tmp/rainyclock-levelplay-calendar-full-20260921.log`。暫存檔可能已清理、也可能包含敏感診斷；先確認存在並篩除秘密，不盲目整包提交。

使用者希望直接完成已授權工作，簡潔繁中回報；重要缺項一次整理，避免反覆索取相同確認。但不可把歷史授權、送審成功或使用者滿意解讀成所有測試已通過或可代為公開發佈。
