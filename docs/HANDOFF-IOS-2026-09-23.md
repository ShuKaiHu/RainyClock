# Rainy Clock iOS 交接 — 2026-09-23：商品卡美元／付款頁台幣

使用者本次要求把目前狀況交接給另一個 AI，優先重新調查：**「先前『商品卡美元、付款頁台幣』差異尚未確認解決。」**

本次只整理交接與文件入口，沒有修改 App、重新建置、上傳、部署或提交審查。下列真機結果來自先前使用者實測，TestFlight／截圖狀態來自本日先前已讀回的 ASC；不是本次重新執行那些測試。新接手者先讀本檔，再查實際工作樹；[9/22 交接](HANDOFF-IOS-2026-09-22.md) 是歷史背景，版本與審查狀態已過時。

## 目前結論與交付狀態

- **價格問題仍未確認解決。** 最新價格實測是 iPhone 16 Pro／iOS 26.6.2／TestFlight **1.7.0（34）**；沒有 build 35 或 iOS 27 的新價格結果。
- **1.7.0（35）已上傳、Apple 處理完成，內部 TestFlight `SKHU tester` 可更新。** 它修地點搜尋、ATT 與通知回呼閃退，沒有修商品價格來源或商品目錄邏輯。`MembershipManager.swift` 本日差異僅為等待新的 async consent 流程。
- **1.7.0（34）已退審**，原因是 6.5 吋截圖、地點搜尋失敗及 ATT 提示／真機錄影。35 尚未重新提交 App Review，未公開發布，也未代替使用者以 Xcode 安裝到手機。
- 使用者曾詢問把 iPhone 16 Pro 升到 iOS 27，以測試此次審查要求；**尚未收到升級完成、已安裝 35 或 ATT 錄影完成的確認**。不要把計畫當成結果，也不要把升級說成已證實的價格修法。
- 6.5 吋截圖：**繁中已確認改用 6.9 吋新版實際 UI 圖；英文（美國）尚未核對清理結果。**

## 價格問題：已取得的實測證據

2026-09-21 22:05，使用者同一台 iPhone 16 Pro／iOS 26.6.2／TestFlight 1.7.0（34）：

| 來源 | 實際結果 |
| --- | --- |
| App 方案卡／StoreKit 2 商品 | 月 US$1、買斷 US$10，幣別 USD |
| StoreKit 2 `Storefront.current` | USA；SK1 查詢前後仍是 USA |
| StoreKit 1 全新 `SKProductsRequest` | 商品同樣是 USD；SK1 storefront 由 unavailable 變成 USA |
| Apple 原生月訂閱付款確認頁 | **NT$10／月** |

這是商品查詢 metadata 與原生付款確認頁不一致的證據，不能用 API 的 USA 反過來斷言使用者一定登入美國商店。`MembershipView` 顯示的是 Apple `Product.displayPrice`，不是因英文介面而寫死美元。

證據範圍：尚未驗證原生買斷付款頁為 NT$100；付款確認頁的截圖也不代表交易已完成。沒有正式 App Store 安裝的同條件比較，不能保證正式版一定正常。Local StoreKit 測試與商店宣傳圖都不是台灣真實售價的驗收。

完整時序見 [STATUS-IOS 的 9/21 價格紀錄](STATUS-IOS.md) 與 [9/22 交接的價格段落](HANDOFF-IOS-2026-09-22.md)。

## 已嘗試的修正／排查，不要從零再做一次

| Build | 已完成內容 | 對本問題的意義 |
| --- | --- | --- |
| 31 | 加入會員／商品診斷；正式會員 challenge/session 曾實測回 200 | Apple 強制 refresh 的 `StoreKitError/3` 為 userCancelled；會員驗證與價格差異分開看 |
| 32 | 優先使用已驗證的 shared AppTransaction，減少不必要的 refresh／重新登入；保留身分隔離及有限重試 | 避免把 Apple 身分更新誤當查價修法，沒有消除美元／台幣差異的證據 |
| 33 | 會員頁、回前景、Storefront 更新、付款各種結束結果及恢復購買後重載商品；抓取前後比對 storefront ID／國家／幣別及商品幣別；最多重試一次；合併重疊查詢並取消過期結果 | 能擋跨商店更新競態，**不能辨識兩套 metadata 一致但與付款頁不同**的情況；價格載入失敗不清除會員權益 |
| 34 | 增加只讀 SK1／SK2 價格比較工具；使用者已完成實測 | **SK1 也回 USD，故直接改用 SK1 fallback 對本案例無效**。34 是診斷結果，不能記成已修好 |
| 35 | 地點、ATT、通知回呼修正並交付 TestFlight | 沒有改定價、商品目錄或會員後端；沒有新的價格驗收結果 |

不要再無條件要求使用者重複刷新、重裝、切換語言／地區或重跑完全相同的 SK1／SK2 比較。若需要新實驗，先說明新增變因、要排除的假設及判讀方式。使用 StoreKit `ProductView` 也沒有本案已驗證的避開效果，不能當作必然修法。

先前曾查到 Apple [iOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes) 的 TestFlight Storefront metadata 修正線索 `181766819 / FB23646993`。這是**先前查核紀錄與待驗假設**，本次未重新查閱；下一個 AI 應核對官方原文及適用版本。它尚未證明本案就是同一缺陷，也沒有證明升級後已好或正式 App Store 不受影響。

## 程式與測試入口

以下路徑相對於 repository 根目錄；已在本次整理時核對存在。

| 檔案／符號 | 閱讀目的 |
| --- | --- |
| [MembershipView.swift](../RainyClock/MembershipView.swift) — `Text(product.displayPrice)`、價格檢查頁 `inspect()` | 方案卡實際顯示值；查詢與畫面是否使用同一組商品 |
| [MembershipManager.swift](../RainyClock/Services/MembershipManager.swift) — `refreshPrices()`、`loadProducts(invalidate:)`、`fetchProducts(version:)`、`purchase(_:)`、`restorePurchases()`、`Storefront.updates` | 商品載入、併發／版本保護、付款前後更新、價格與會員狀態分離 |
| [MembershipModels.swift](../RainyClock/Services/MembershipModels.swift) — `MembershipCatalogStorefront`、`MembershipProductCatalog.load`、`MembershipPlan` | 商店一致性檢查；比對的是 Apple metadata，不是付款頁真值。`currencyCode` 為 Apple storefront currency，沒有依語言推算售價 |
| [MembershipLegacyPriceProbe.swift](../RainyClock/Services/MembershipLegacyPriceProbe.swift) | SK1 查價及 `priceLocale` 格式化、10 秒逾時、取消、delegate／continuation 生命週期 |
| [MembershipTests.swift](../RainyClockTests/MembershipTests.swift) — `MembershipProductCatalogTests` | 商店切換、幣別矛盾、商店缺失、相同國家但不同 ID、最多一次重試等；**沒有獨立的 MembershipProductCatalogTests.swift 檔案** |
| [MembershipLegacyPriceProbeTests.swift](../RainyClockTests/MembershipLegacyPriceProbeTests.swift)、[MembershipStoreKitTests.swift](../RainyClockTests/MembershipStoreKitTests.swift) | 查價取消／失敗／格式化，以及真正 Local StoreKit 交易測試 |
| [RainyClockMembership.storekit](../Configuration/RainyClockMembership.storekit) | 本機測試 fixture，不能代表 TestFlight 台灣商店；已確認 build 35 Release bundle 未包含此檔 |

手機入口：**會員與方案 → ⋯ → 檢查測試商店價格**。`canInspectSandboxPrices` 僅允許已驗證 Apple Sandbox 或隔離 Local StoreKit 環境。檢查頁不購買、不刷新 Apple 身分、不同步會員、不改權益；只在使用者選擇複製時複製報告，不收集帳號／會員 ID／JWS／裝置識別碼。

## 定價與會員規則：不要用改產品掩蓋查價問題

| 項目 | 現行決定 |
| --- | --- |
| 美國 | 月 US$1、買斷 US$10 |
| 台灣 | 月 NT$10、買斷 NT$100；ASC 獨立設定，非匯率換算 |
| 供應 | 上次確認只供應美國、台灣；沒有授權擴增地區或自動供應 |
| 月訂閱 ID | `com.shukaihu.RainyClock.plus.monthly` |
| 買斷 ID | `com.shukaihu.RainyClock.banner.lifetime` |
| 年訂閱 | 停售、0 地區、未加入本次審查；仍承認有效歷史交易，不能刪除恢復與驗證支援 |
| 兩種方案 | 均移除 banner、開啟日曆、每日一次免看廣告 AI 生成；買斷顯示優先，同時持有不重複領每日次數 |
| 既有訂閱 | 買斷不會自動取消 Apple 自動續訂；顯示真實續訂狀態 |

尚未採用的方案：固定台幣表、依手機語言／GPS 選商城、讓使用者任意選國家改價、把舊交易金額當新購售價、隱藏價格。不要自行實作為既定決策；若研究後只剩這類替代方案，先列出證據、代價與需要使用者決定的產品行為。

## 給下一個 AI 的調查順序

1. 先核對上面商品顯示、載入與購買路徑，找仍未排除的 App 層原因；把已證實事實、推論、待測假設分開。不要只因看到 USA 就判定使用者帳號錯誤。
2. 查 Apple 官方文件／release notes，核對已知 TestFlight 行為的精確版本與限制；若主張替代 API 能取得付款幣別，需提出來源與能區別假設的實驗，不能只換 API 名稱。
3. 如需新真機證據，先確認**目前實際 OS、build 與 TestFlight 安裝來源**。若使用者已完成 iOS 27 升級，可做一次有對照的同次工作階段比較：卡片、SK2、全新 SK1、原生確認頁；記錄回到 App 後是否改變。查看付款頁可取消，不以完成購買為查價前提。不要自行登出帳號、改商店或移除 App 資料。
4. 若找出程式缺陷，提出可驗證的修正及有意義的回歸測試；若證據指向 Apple metadata，說明信心與尚缺的證據，提供可行替代方案及限制。**交付目標是可採取的結論，不是再把相同診斷工具上傳一次。**
5. 新 binary 不可覆用 35；需要上傳時再查 ASC 已用 build 號。沿用 marketing version 1.7.0 的現行修正流程，不因整理交接就改成 1.7.1。沒有提交 Apple Feedback，也沒有因此重新送審；不要把未做的外部動作寫成完成。

## 退審修正版與素材的最新狀態

詳見 [APP-REVIEW-2026-09-23.md](APP-REVIEW-2026-09-23.md)。

- 地點：審查截圖 Home 是 `Taipei Main Station`、Work 是 `Taipei 101`，錯誤明確發生在 Home 解析，不能說兩個都失敗或已確定是 GPS 問題。35 檢查後續候選、保留原 Apple 排序，且翻譯／反查失敗不再丟棄原先已匹配的地點。macOS Apple 查詢成功、8 項新增回歸測試通過；仍缺 iOS 27 真機完整驗收。
- ATT：35 將提示與 production-only 廣告 gate／會員就緒狀態分開，等 GDPR sheet 真正關閉且 App active 後要求 ATT；未決時 SDK 不初始化。TestFlight 可提示但仍不送正式廣告流量。19 項新增測試與 iOS 26.5 模擬器提示流程通過；仍缺 Apple 要求的真機錄影與資料時序驗證。
- 通知：Organizer 取得 build 34／iOS 26.6.2 的通知回呼 worker-thread UIKit assertion。改 explicit completion handler，MainActor acknowledgement 完成後回呼；5 項背景入口／完成順序測試通過。含識別資訊的原始 crash 不進 repo。
- 截圖：使用者 9/23 提供媒體管理畫面，繁中 6.9 吋為六張真實 UI、6.5 吋顯示「使用 6.9 吋顯示器的檔案」及灰色繼承預覽；先前另開 ASC 頁已讀回相同狀態。**繁中變更已保存，媒體管理頁沒有另一個待按的儲存按鈕。** 英文（美國）尚未讀回清理結果；9/21 舊紀錄為 E2/E1/E3，不可當作 9/23 即時狀態。
- 待重送：英文 6.5 吋核對、iOS 27／iPad 路線與核心流程真機驗收、ATT 實體裝置影片／Notes 連結、選用修正版與逐項回覆。沒有完成上述事項或公開發布的證據。

ASC：[TestFlight build 35](https://appstoreconnect.apple.com/teams/e7ff01f6-7d3d-42f7-aab6-135a4eaee789/apps/6780500386/testflight/ios/c3ad05c5-0e2c-42b5-b7e9-01d605ffd677)、[iPhone 媒體管理](https://appstoreconnect.apple.com/apps/6780500386/distribution/ios/version/inflight/media-manager/iphone)、[1.7.0 版本頁](https://appstoreconnect.apple.com/apps/6780500386/distribution/ios/version/inflight)。

## 建置證據、工作樹與限制

- 目錄 `/Users/shukaihu/Code_Project_Local/RainyClock-iOS`，branch `ios/main`；本次讀到 HEAD `cbdfdb4`。**35 修正與部分文件仍未提交，不能只 checkout HEAD 就宣稱取得最新程式。** 9/22 舊功能曾提交，9/23 又有新差異；先看 `git status`／`git diff`，保留全部既有修改，不 reset／clean。
- 35 的 App／AlarmWidget／DayOffNotification extension 版本均為 1.7.0（35）。Archive `build/RainyClock-1.7.0-35.xcarchive`；2026-09-23 22:31:20 +0800 upload/export 成功；Apple 處理完成、內部群組 1 人及中英文測試說明已讀回。測試說明：[testflight-1.7.0-35.txt](testflight-1.7.0-35.txt)。
- 完整 **377 tests passed，0 failed／skipped**，乾淨 iOS 26.2 Simulator、簽章 `RainyClock Membership Local` scheme，包括 Local StoreKit。日曆／天災 fixture 改為明確注入權益，正式 gate 未放寬。這些不是 TestFlight 真實價格或 iOS 27 真機驗收。
- 日誌 `/tmp/rainyclock-170-35/tests-final-passed.log`、`archive-release.log`、`upload.log`；結果 `DerivedData/Logs/Test/Test-RainyClock Membership Local-2026.09.23_22-28-23-+0800.xcresult`。暫存路徑可能日後清除。
- iOS 26.5 Local StoreKit 曾 configuration／Code 3 失敗，改用乾淨 26.2 才跑完；不要為了全綠略過交易測試。一般 `RainyClock` scheme 可能連真正 StoreKit 並彈登入；`CODE_SIGNING_ALLOWED=NO` 會讓 Keychain 測試失敗。
- Release 的 production App Attest、正式會員 URL、簽章、兩語系 ATT 文案、未包含 `.storekit` 已核對。既有第三方 IronSource dSYM 警告未阻擋上傳；未把所有既有編譯警告都宣稱已修完。
- 先讀 [CLAUDE.md](../CLAUDE.md)。僅處理 iOS 與必要相關後端，不改 Android；Unity LevelPlay 保留 `-ObjC`、GDPR 文案，以及 ATT 未決或 GDPR 未答覆／已撤回時不啟動 SDK 的規則。拒絕 ATT 不等於永久禁止所有非個人化廣告，仍依正式環境與同意 gate 判斷；TestFlight／Simulator 不送正式廣告。
- `AppEnvironment.supportsTemporaryClosures = false`；颱風／臨時放假維持延後至 1.7.1。35 未改後端或方案權益。
- TestFlight 與 Production 使用同一正式會員服務、不同 Apple transaction environment 及資料隔離；Local StoreKit 是本機 fixture。App Attest 的 production 不等於 TestFlight IAP 是正式交易。完整接線／其他端到端驗收缺項見 [1.7.0-RELEASE-READINESS.md](1.7.0-RELEASE-READINESS.md) 與 9/22 交接；本次未重新部署或探測雲端。
- Repo／docs 是公開內容。不要加入私鑰、帳密、session／JWS、會員／裝置識別碼或原始私人 crash。

## 可直接交給另一個 AI 的任務

> 請先讀 `docs/HANDOFF-IOS-2026-09-23.md`，在目前未提交的工作樹調查 Rainy Clock「商品卡美元、Apple 原生付款頁台幣」的差異。build 34 已證實 SK1、SK2 都回 USA/USD，月訂閱原生付款頁卻是 NT$10；build 35 已可 TestFlight 測試，但沒有修改價格邏輯，也沒有新的真機價格結果。請先檢查程式與 Apple 官方依據，提出新且可區分原因的調查或修法；不要重複要求同樣的刷新／重裝測試，不要依語言／GPS 或硬編台幣改價，不要將測試通過或上傳成功當成問題已解決。保留既有退審修正與未提交檔案，清楚列出已證實原因、尚待驗證假設與下一步。
