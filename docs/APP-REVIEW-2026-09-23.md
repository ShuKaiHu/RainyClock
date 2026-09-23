# 1.7.0（34）退審診斷 — 2026-09-23

依使用者提供的 Apple 審查訊息、後續截圖、本機原始碼及 Xcode Organizer 真機 crash 查核。已修正下述候選搜尋缺陷、ATT 提示時序及通知回呼執行緒問題，1.7.0（35）已上傳 TestFlight 且內部群組可更新；未重現 iOS 27 審核裝置完整操作，未重新提交 App Review 或回覆 Apple。

- Submission ID：`5a8a1d24-97da-4eb9-89a7-350274dccc85`
- 審查日期：2026-09-23；版本：1.7.0（34）。
- 裝置：iPad Air 11-inch（M3）、iPhone 17 Pro Max；iPadOS／iOS 27.0；網路正常。
- 三項問題：2.3.3（6.5 吋商店截圖）、2.1(a)（找不到地點而無法使用核心功能）、2.1 Information Needed（找不到 ATT 提示，要求真機錄影）。

## 收到審查截圖後：Home 搜尋缺陷已修正，待 iOS 27 真機確認

使用者提供 `Screenshot-0923-143933.png`（原圖 1320×2868）。Route 畫面明示：
“Could not preview route: Could not find this address: Taipei Main Station”。Home 為 Taipei Main Station、Work 為 Taipei 101、Mode 為 Car。

- 此錯誤確認 Home 的文字解析沒有取得可用座標。`MapKitRoutePreviewService` 先解析 Home 再解析 Work，因此這張圖不能證明 Taipei 101 也失敗；尚未進入導航計算。
- 地址列顯示輸入文字，不代表已確認座標。單憑截圖無法分辨是直接輸入，還是點選建議後座標解析失敗又回到文字搜尋。
- 地圖只在成功取得 preview 後顯示，失敗留下錯誤卡與大片空白，未見獨立的版面錯置證據。

程式修正（`MapItemResolver.swift`）：

- geocoder 與 MapKit 依原排序檢查所有候選；首筆比對／翻譯失敗不再直接丟棄整批搜尋結果。
- MapKit 比對同時參考 POI 名稱與地址。原資料已匹配時，即使額外反查失敗或丟失 POI 名稱，也保留原地點與座標。
- 增加取消檢查，取消中的舊搜尋不返回座標或繼續 Google fallback。原有錯誤城市、街道門牌及手動确认流程保留，未硬編地標座標。

驗證：Xcode 26.6、iPhone 17 Pro 模擬器 iOS 26.5，`RainyClock Membership Local` scheme 的 50 項相關測試通過、0 失敗。含新增 8 項候選搜尋回歸測試：首筆中文／反查失敗但後筆英文可用、原排序、翻譯丟失名称、保留已匹配座標、地址 metadata、全不符／錯誤城市、錯誤門牌、取消。另以 macOS 實際呼叫 Apple 服務，修改後這兩個查詢皆成功。日誌：`/tmp/rainyclock-review-20260923/location-tests.log`、`map-diagnostic-fixed.log`。

限制：尚不能宣稱 Apple 退審根因已唯一確定或 iOS 27 真機已修好。若所有結果只含無法匹配的中文且反查全部失敗，仍可能找不到；此修正沒有取消結果驗證。ATT 程式修正見下節，真機錄影與英文 6.5 吋素材核對尚未完成；TestFlight 交付狀態見下方 build 35 紀錄。

## 截圖：繁中 6.5 吋已繼承新版，英文待核對

[上次上傳紀錄](appstore-1.7.0-screenshots/README.md) 記載 9/21 的 6.5 吋舊圖為繁中 `C1/C2/C3`、英文 `E2/E1/E3`，與 Apple 點名尺寸吻合。**9/23 使用者清理後，繁中已確認改用 6.9 吋新版六張實際 UI 圖。** 使用者截圖及另開 ASC 頁讀回均顯示「使用 6.9 吋顯示器的檔案」和灰色繼承預覽；變更已保存，媒體管理頁沒有另一個待按的儲存按鈕。

英文（美國）6.5 吋尚未讀回本次清理結果，不可宣稱所有語系都已處理；9/21 的舊圖名稱也不是 9/23 即時狀態。仍需核對英文的實際繼承／替換結果。

在每個語系的 Previews and Screenshots → View All Sizes in Media Manager 檢查 6.5 吋組。移除或替換舊宣傳圖，確認首頁、時間、路線與月曆等實際 UI 是多數。Apple 的[截圖規格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)允許未提供 6.5 吋圖時使用 6.9 吋圖縮放；若沿用此方式，需在 ASC 預覽確認確實採用新版圖，不能僅清空就當作完成驗收。

既有原生 PNG／同尺寸 JPEG 位於 `docs/appstore-1.7.0-screenshots/`；1320×2868 屬 6.9 吋，不應直接塞進 6.5 吋組。IAP 的 Local StoreKit 審查圖不是公共商店展示圖。

## 地址：原因尚未重現，不能先歸因 GPS 或 iOS 27

使用者已補充審查地址為 **Taipei Main station、Taipei 101**，後續截圖確認 Home 解析失敗，完整操作步驟仍未知。App 用使用者輸入／選取的 Home、Work 地址取得座標，主要流程沒有要求目前 GPS 位置；兩個地點都在台北，因此海外搜尋偏向不是本案例的主要假設。

針對這兩筆公開地名，已在 macOS 以目前 `MapItemResolver.swift` 的副本實際呼叫 Apple geocoder／MapKit。隔離 harness 將 Google fallback 設為 nil，沒有正式廣告／會員流量，也沒有修改 App：

| 查詢 | Apple 實際回應 | 本機 resolver 結果 |
| --- | --- | --- |
| Taipei Main station | geocoder 第一筆是新北烏來的 Maan，既有篩選拒絕；MapKit 第一筆為中文「台北車站」，第二筆為英文「Taipei Main Station」 | 第一筆 MapKit 經額外英文反查後成功，25.0485774 / 121.5148986 |
| Taipei 101 | geocoder 回 Code 8 無結果；MapKit 回中文「台北101」 | 額外英文反查取得含 Taipei City 的文字後成功，25.033649 / 121.564824 |

**沒有在此次 macOS 呼叫重現最終找不到地點**，不能宣稱已重現 iOS 27 的退審錯誤。但現有文字比對確實將 `Taipei Main station` 對 `台北車站`、`Taipei 101` 對 `台北101` 判為 false；這兩筆流程依賴額外反查成功並回傳可匹配文字。若反查失敗／仍回全中文，就可能把 MapKit 已找到的地點丟棄。這是可驗證的脆弱環節，仍需審查裝置或相同 OS 的實測來確認根因。暫存查核程式與輸出：`/tmp/rainyclock-review-20260923/`。

初始原始碼可確認的風險（其中候選檢查已由上節修正）：

- `MapItemResolver.search` 對所有 MapKit 手動搜尋指定 `taiwanRegion`；這是搜尋偏向，不能描述為完全禁止海外結果。Google fallback 同樣有 `region=tw`。
- `strictCandidateQueries` 將逗號分隔的地址拆成獨立片段；`AddressSearchCompleter.update` 優先選無逗號片段，可能丟掉國家／城市而只查街名。
- geocoder 與 MapKit 的網路／服務錯誤被捕捉後回傳 nil，最終與真正「沒有搜尋結果」共用 `addressNotFound`，無法由 UI 區分。
- 手動搜尋原先只檢查第一個具有座標的回傳結果，再以顯示文字篩選；第一個結果不合格時沒有繼續檢查同批其餘候選。已修正並補回歸測試。

下一步先用 **Taipei Main station → Taipei 101**，涵蓋英文／繁中裝置語系、鍵盤送出與選取建議兩條路徑；針對反查失敗及首筆不符／後續候選符合補回歸測試。再測試其他台灣／美國公開地標與完整街道地址。驗證新安裝及由上一正式版升級，在 iPhone 與 iPad 相容模式都能完成 Home／Work、路線、天氣及鬧鐘流程。網路錯誤應顯示可重試的服務錯誤，不能將不相干地點當成成功結果，也不要用硬編這兩個地標座標作為修法。

本機僅列出 iOS 26.2／26.4／26.5 可用模擬器；此次沒有 iOS 27 或真機驗收證據。

## ATT：已修正會跳過提示的條件與時序風險

修正前，`AppEnvironment.allowsDeviceAdvertising` 只在已驗證 Apple environment 為 `.production` 時放行；Sandbox／TestFlight、身分尚未辨識都不放行。`ConsentManager.requestConsentThenStartAds` 又先要求會員的 `rewardUserID` 存在，且 `requestTrackingAuthorizationIfNeeded` 也使用同一個 `allowsAdvertising` 開關。

因此 **build 34 的程式把「禁止正式廣告流量」與「不顯示 ATT」綁在一起**。此為可從程式直接確認的行為；審核員當時實際 Apple environment、會員結果及 ATT 系統設定尚未知，不能稱已證明審核裝置的唯一根因。

另外，`finishConsentFlow` 呼叫 ATT 後無條件繼續到 SDK 啟動判斷；若 ATT 因 App 尚非 active 而返回，仍可能先初始化 SDK。前景補提示不能代替「提示未完成就不啟動 SDK」的保護。

本機已實作的修正：

1. 將授權流程與正式廣告流量開關分離，使 ATT 不依賴會員 API／廣告獎勵身分；保留 Sandbox／模擬器不打正式廣告的限制。
2. GDPR 表單完成並真正關閉、App 為 active、沒有另一個權限請求時再要求 ATT；避免重複並行請求。
3. ATT 狀態仍為 notDetermined 時保留待處理狀態，勿初始化廣告 SDK；在適當前景時機重試。對拒絕／受限制狀態遵守不追蹤要求，核心鬧鐘功能不依賴允許追蹤。
4. GDPR 答案先存本機，等 ATT 決定與正式廣告 gate 放行後，才傳給 LevelPlay 並初始化 SDK。Debug IDFA 日誌也只在 ATT authorized 後存取識別碼。
5. 新增 19 項隔離單元測試，覆蓋 Sandbox、會員未就緒、inactive→active、提示未決、拒絕／限制、重複並行呼叫、GDPR 實際關閉／滑掉、SDK 失敗重試、會員身分失效、撤銷／重置 ATT、取消與等待中的環境改變。以真機再驗完整顯示與資料收集時序。

驗證：`RainyClock Membership Local` scheme、iPhone 17 Pro 模擬器 iOS 26.5，19 項 ConsentManager、19 項 Membership、16 項 AlarmViewModelScheduling 共 **54 項通過、0 失敗**。日誌 `/tmp/rainyclock-att-20260923/tests.log`。編譯僅有既有 `MembershipTests.swift` actor-isolation 警告；尚無 iOS 27 真機證據。

另外建立隔離的 iPhone 17 Pro Max／iOS 26.5 模擬器 `RainyClock ATT Review Check`，使用本機測試會員模式、不啟動正式廣告，實際驗證：

- 乾淨安裝後首次開啟顯示 Apple 系統 ATT；選擇拒絕後可進入設定，重啟不再次要求 ATT。
- 移除測試 App 後重新安裝，以 Debug `-forceGDPRConsentGeography` 強制 GDPR 分支。先顯示 App 廣告隱私表單；選擇非個人化廣告，表單關閉後隨即出現 Apple ATT，選擇允許後回到鬧鐘首頁。
- 暫存畫面：`/tmp/rainyclock-att-20260923/att-first-launch.png`、`att-denied-settings.png`、`att-after-gdpr.png`。這些是模擬器驗證紀錄，不能代替 Apple 要求的實體裝置影片；尚未因此驗收完整路線／鬧鐘流程。

[Apple ATT 文件](https://developer.apple.com/documentation/apptrackingtransparency/attrackingmanager/requesttrackingauthorization(completionhandler:))明示非 active 或另一個權限請求待處理時可能不顯示提示；系統也可能因全域設定／限制不顯示。原程式註解把 inactive 一律說成永久拒絕並不準確，已更新。

不能只將 ASC 問卷改成「不追蹤」來消除提示要求。App 含 LevelPlay，必須依實際 SDK 資料行為填寫；若要改成完全不追蹤，需另行驗證整個廣告／資料流程。

## build 35：額外修正 TestFlight 通知回呼閃退

9/23 於 Xcode Organizer 選擇 1.7.0，取得 9/22 的 build 34 真機 crash（iPhone 16 Pro、iOS 26.6.2）。Thread 5 的 `EXC_CRASH / SIGABRT` 堆疊依序包含 `NSAssertionHandler`、`UIApplication._performBlockAfterCATransactionCommitSynchronizes`、背景狀態還原／snapshot，以及 `@objc closure #1 in NotificationPresentationDelegate.userNotificationCenter(_:didReceive:)`、`completeTaskWithClosure`。未將含裝置識別資訊的原始 crash 加入 repo。

原 delegate 使用 async didReceive，Swift 產生的 Objective-C completion 在 worker thread 呼叫 UIKit。改用明確的 `withCompletionHandler` delegate，先複製 action、category、date，再於 MainActor 完成 acknowledgement 和系統 completion。鬧鐘點擊與停止仍保留既有每週排程；其他 action／category 也保證完成回呼。

新增五項 `NotificationResponseTests`：從背景 task 呼叫，驗證鬧鐘點擊、停止、dismiss、未知 action、其他 category；completion 必須在 main thread，且需等待 acknowledgement 的異步工作完成。這些測試不代替 TestFlight 真機的實際通知／锁定畫面回歸。

完整測試另发现 `CalendarSchedulingTests`／`SettingsPreferenceSchedulingTests`／`DisasterIntegrationTests` 依賴 App 的共享會員快取，乾淨測試環境會失敗或等待未觸發的 provider。已明確注入各測試需要的會員權益 fixture；正式權益限制未改，權益到期／撤銷仍由 `MembershipSchedulingTests` 覆蓋。

本機 iOS 26.5 StoreKit service 重現先前的 configuration / `SKInternalErrorDomain Code=3` 錯誤，購買測試不能有效執行；改用既有 iOS 26.2 專用 Simulator，保留簽章與 `RainyClock Membership Local` scheme。沒有以略過購買測試或放寬斷言代替驗證。

App 與兩個 extension 的版本均更新為 **1.7.0（35）**，臨時放假 gate 仍為 false。測試說明：[`testflight-1.7.0-35.txt`](testflight-1.7.0-35.txt)。

最終驗證：乾淨 iOS 26.2 Simulator、簽章 `RainyClock Membership Local` scheme，**377 項通過、0 失敗、0 跳過**（xcresult 已核對），包含六項實際 Local StoreKit 及五項通知回呼測試。Release archive 成功，production App Attest、正式會員 URL、兩語系 ATT 文案、App／兩個 extension 版本與簽章均確認，未打包 `.storekit`。既有 IronSource headers、Text `+` deprecated 及 GeneratedVoiceAssembler concurrency warnings 仍存在。22:31:20 upload/export 成功，Apple 已完成處理，內部 `SKHU tester`（1 人）可更新。中英文測試說明已保存並讀回「已儲存」。既有 IronSource 第三方 dSYM 缺漏警告未阻擋上傳。日誌目錄 `/tmp/rainyclock-170-35/`，最終測試為 `tests-final-passed.log`，archive 為 `archive-release.log`。

[TestFlight build 35](https://appstoreconnect.apple.com/teams/e7ff01f6-7d3d-42f7-aab6-135a4eaee789/apps/6780500386/testflight/ios/c3ad05c5-0e2c-42b5-b7e9-01d605ffd677)；尚未重新提交 App Review 或公開發布。

## 重新送審前的交付

- 修正並驗證 App 後，以新的 build number 提交；App 與所有內嵌 extension 版本一致，保持 1.7.1 天災功能關閉。
- 6.5 吋繁中已讀回新版繼承結果；完成英文清理／核對並確認各尺寸實際展示內容。
- 依 Apple 本次要求，用**實體裝置**錄製新安裝或追蹤權限重置後啟動、ATT 顯示及後續操作；提供廣告 SDK 在授權未決前未初始化的驗證。影片放到 App Review Information 的 Notes 可存取位置，並在回覆中引用。
- 英文回覆逐項說明實際完成的變更、build、測試裝置／OS、功能路徑與影片連結。尚未完成上述事項前，不宣稱已修復、已補圖或已附影片。

目前完成退審診斷、候選搜尋／ATT／通知回呼程式修正及完整自動測試；完整重新送審驗收尚未完成。

### ATT 真機錄影步驟（仍待執行）

1. 使用已可內部 TestFlight 更新的 **1.7.0（35）**；1.7.0（34）是原退審 binary，不必只為錄影再建置。若後續又修改程式，才使用下一個未使用 build 並同步 extensions。
2. 在可允許 App 要求追蹤的成人測試帳號／非受管理實體裝置，確認「設定 → 隱私權與安全性 → 追蹤 → 允許 App 要求追蹤」已開啟。錄下裝置型號、OS 與 build；優先在本次被點名的 iOS／iPadOS 27 驗證。
3. 備份需要保留的設定後，用新安裝或依 Apple 要求重置追蹤權限，從啟動 App 開始錄影。已有 authorized／denied／restricted 決定的裝置，不會每次開啟都再顯示 ATT。
4. 非 GDPR 地區應在首次可顯示時看到 Apple 系統 ATT；GDPR 地區先完成 App 的廣告隱私選擇，待表單關閉後顯示 ATT。直接滑掉 GDPR sheet 不視為答覆，本次啟動不初始化廣告 SDK。
5. 錄下選擇「要求 App 不要追蹤」後仍可進入設定，設定 Home／Work、取得路線預覽並完成鬧鐘操作。另以新的乾淨狀態驗證允許選項。無論選擇為何都不能以允許追蹤作為核心功能條件。
6. TestFlight 可驗提示，但仍不初始化正式廣告 SDK；影片本身不能證明所有網路行為。正式環境的 SDK 時序需搭配已註冊廣告測試裝置的初始化／網路查核，勿在模擬器啟動正式廣告。
7. 影片完成後才將可存取連結寫入 App Review Information 的 Notes 並回覆 Apple。說明首次啟動路徑、GDPR 分支、拒絕仍可使用，以及 SDK 在 ATT 未決時保持關閉；填寫實際 build／裝置／OS，不預先宣稱錄影完成。
