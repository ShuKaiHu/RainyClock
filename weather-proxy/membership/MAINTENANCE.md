# 會員刪除清理 Job

2026-09-21：程式、最小權限 Job 與每 5 分鐘排程已部署，已實際驗證 Scheduler
OAuth 派送及受控 TestFlight 刪除；本頁下方記錄範圍與證據，不代表完整使用者刪帳
UI 或所有正式會員情境均已驗收。其他發布紀錄見 `docs/MEMBERSHIP-STAGING.md`。

2026-10-02：排程由每 5 分鐘改為每天兩次（`7 4,16 * * *`、`Asia/Taipei`，即 04:07 與
16:07）。Job、環境變數與批次上限未變；原因與影響見「IAM 與 Cloud Scheduler」及文末
「排程調整 — 2026-10-02」。

2026-10-03：與本 Job 無關的一次正式庫手動處置：擁有者手機對 `/v1/membership/session` 持續
快速 401，刪除正式庫一份 `authDevices` 文件後恢復。確認與處置步驟見「運行手冊：單一裝置的
快速 401」，經過與 1.8.1 的後續見文末「裝置金鑰斷言失敗與處理 — 2026-10-03」。

## 行為

`node membership/maintenance-cli.js` 只處理已有 `deletedAt` 且
`deletionCleanupState=pending` 的會員，不開 HTTP port、不建立會員、不驗 Apple、
不呼叫語音／廣告、不增加或清零任何其他會員額度。前台刪除與 Job 使用同一組
storage-only 清理函式；仍保留既有 identity／purchase／reward 防重摘要政策。

雙環境依序處理 Production 與 TestFlight Sandbox。每次最多每庫 10 批、每批 100 位，
空批或完全無進展即停；單庫故障不阻止另一庫完成。部分失敗、仍有 pending backlog、
無法查庫或無法正常關閉 client 均回傳非零 exit code，讓 Cloud Run task 重試。
成功的會員不再查中；未完成的會員維持 pending，重跑／重疊 execution 均可繼續。

Job 不依賴 App Server API 私鑰、LevelPlay 私鑰、HMAC 身分密鑰、TTS 憑證或 migration
cutover；這些服務停用或輪替時仍能刪除。唯一雲端憑證是 Job service account 的 ADC。
日誌只輸出環境、成功／失敗／掃描計數及是否有剩餘，不輸出會員 ID 或原始錯誤。

## Job 設定

沿用包含目前程式的不可變 container image digest，另建 Cloud Run **Job**，不要用公開
Cloud Run service 的 URL 當刪除 API。

建議起始值：

| 項目 | 值 |
| --- | --- |
| 地區 | `asia-east1` |
| Command / args | `node` / `membership/maintenance-cli.js` |
| Tasks / parallelism | `1` / `1` |
| CPU / memory | `1` / `512Mi` |
| Task timeout / max retries | `600s` / `3` |
| Job 名稱建議 | `rainyclock-membership-deletion` |

環境變數（均非秘密）：

```yaml
GOOGLE_CLOUD_PROJECT: rainyclock
MEMBERSHIP_SERVER_MODE: dual
MEMBERSHIP_PRODUCTION_FIRESTORE_DATABASE: membership-production
MEMBERSHIP_SANDBOX_FIRESTORE_DATABASE: membership-testflight
MEMBERSHIP_PRODUCTION_NAMESPACE: membership_production_v1
MEMBERSHIP_SANDBOX_NAMESPACE: membership_testflight_v1
MEMBERSHIP_MAINTENANCE_BATCH_SIZE: "100"
MEMBERSHIP_MAINTENANCE_MAX_BATCHES: "10"
```

`MEMBERSHIP_FIRESTORE_PROJECT` 可覆寫 project。雙模式拒絕相同 database 或 namespace、
路徑穿越及不合法批次限制；會先驗證所有設定才開始存取。Emulator 只接受 `demo-` project，
避免誤把測試導向真實專案。Job 即使會員服務暫停仍可清理，無須 `MEMBERSHIP_ENABLED=1`。

若也要清理舊 Debug Sandbox，另建只有舊庫權限的 Job，使用
`MEMBERSHIP_SERVER_MODE=sandbox`、`MEMBERSHIP_APPLE_ENVIRONMENT=Sandbox`、
`MEMBERSHIP_FIRESTORE_DATABASE=membership-sandbox` 及 `MEMBERSHIP_NAMESPACE=membership_sandbox_v1`。
單庫模式要求明確 database，不退回 `(default)`；新的雙庫 Job 不需要舊庫的 IAM 權限。

## IAM 與 Cloud Scheduler

- Job runtime SA：優先獨立維護 SA，僅有 `membership-production`、`membership-testflight`
  兩 DB 的條件式 `roles/datastore.user`。可沿用已配置兩庫權限的 runtime SA，但不需
  掛任何 Secret，也不需要 Apple、Vertex AI 或 Cloud TTS 權限。
- Scheduler SA：僅在上述 **Job** 授予 `roles/run.invoker`，無 Firestore 權限。
  不授予 `allUsers` 或 `allAuthenticatedUsers`。
- 建立／更新 Job 的部署者另需 Cloud Run 管理權限及 runtime SA 的 `iam.serviceAccounts.actAs`；
  建立 Scheduler 者需 Scheduler 管理權限及 Scheduler SA 的 actAs。不要把管理權限
  給實際執行排程的 SA。維持 Google 建立的 Cloud Scheduler service agent 所需角色。

Scheduler 目前部署為每天兩次：`7 4,16 * * *`、時區 `Asia/Taipei`（04:07 與 16:07；
2026-10-02 以前為每 5 分鐘），向以下 Google 管理 API 發送 POST，body `{}`：

```text
https://run.googleapis.com/v2/projects/rainyclock/locations/asia-east1/jobs/rainyclock-membership-deletion:run
```

頻率的取捨：Cloud Run Job 每次 execution 以 instance 整段存活時間計費、最少 1 分鐘，
費用取決於執行次數而不是實際工作量；每 5 分鐘（每天 288 次）時，幾乎每次都是
pending=0、無事可做。使用者的刪除請求本身是同步完成的：先寫入 `deletedAt`，session 與
後續請求立即失效，再於同一請求內清理資料；本 Job 只補做該請求中途失敗（回 202
`cleanupPending`）留下的 `pending`。因此降頻不影響存取撤銷，只是中途失敗的清理最久
可能等到下一次排程，約 12 小時。

使用 Scheduler SA 的 **OAuth access token**，scope `https://www.googleapis.com/auth/cloud-platform`，
不是打 Cloud Run 公開網址的 OIDC token。Scheduler attempt deadline 可設 `60s`、派送失敗
重試 3 次；這個請求只啟動 execution，Scheduler 成功不代表資料已清完。真正清理失敗
由 Job exit code 與 task retry 處理。排程和 retry 偶爾重疊不破壞資料；持續失敗仍須告警。

針對 Job execution 失敗及 `membership_deletion_maintenance` 的 `ok=false`／
`pendingRemaining=true` 設告警；不要只監看 Scheduler POST 是否成功。
若刪除量長期超過每次上限，應檢查失敗原因並調整批次／頻率，不直接改寫 complete。

## 驗證

先以 Emulator 測試（需 Java 21；`FIRESTORE_EMULATOR_HOST` 指向本機）：

```sh
node --test test/membership-maintenance.test.js test/membership-domain.test.js test/membership-security.test.js test/membership-http.test.js
```

包含雙庫實際清理、故障後再試、並行重跑、active member 保護、防重摘要保留、auth key
換人後不可刪及失敗 exit code。沒啟動 Emulator 時 integration 明確標 skip。

部署後先手動 execute 一次，確認兩環境 summary，並讀回 Cloud Run execution 成功狀態。
再於測試庫使用測試會員建立可控的刪除中斷，確認 Job 清為 complete、原 session 失效，
且正式 active 會員完全未變。最後查 Scheduler 的實際派送與對應 execution；只建立
資源或本機通過，不能宣稱排程與雲端恢復流程已驗收。

## 運行手冊：單一裝置的快速 401

症狀：同一支手機反覆 `POST /v1/membership/challenge` 200 → `POST /v1/membership/session` 401，
每次 60–100 ms，其他會員的 `/session` 正常；App 的會員畫面顯示「Showing last verified status」、
診斷列 `session · MembershipHTTP/401`（1.8.1 起會帶錯誤碼：`session · MembershipHTTP/401 · invalid_assertion ·
store=TWN · currency=TWD`），同步失敗；若 keychain 快照太舊，設定 › 行事曆的臨時放假
開關還會停用並顯示「尚未確認你的方案」。這麼快的 401 表示請求還沒走到 Apple 那一段，不是 App Store
交易或收據的問題。

確認：

0. 從帶有 `membership_request_failed` 的 revision（00007 以後）起，先查 log 就有錯誤碼：
   `gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="rainyclock-membership" AND jsonPayload.event="membership_request_failed" AND jsonPayload.code!="app_transaction_refresh_required"' --limit 50`，
   看 `jsonPayload.code`（`invalid_assertion`／`assertion_replayed`／`key_not_registered` 是裝置金鑰那一類；
   `app_transaction_refresh_required` 是每天都會有的正常過期）。這個事件的 severity 是 NOTICE（5xx 才是 ERROR），
   用 `jsonPayload.event` 查，不要用 severity 篩。00006 以前的 revision 沒有這行，只能靠下面兩項旁證。

1. 延遲。`/session` 在 App Attest 斷言檢查就失敗（`auth.js` `bootstrapIdentityAndDevice` →
   `attestation.js` `verifyAssertion`，推斷為 `invalid_assertion`）只有兩次 Firestore 讀取加本機
   ECDSA，60–100 ms；Apple JWS 階段失敗約 0.6–0.7 s；成功 1.9–2.6 s。Cloud Run `responseSize`
   185 對應 17 字元的錯誤碼。
2. 未消耗的 challenge。由支援碼取得會員 id（支援碼是會員 id 前 8 碼轉大寫），在正式庫
   `membershipNamespaces/membership_production_v1/authDevices` 找 `memberId` 等於該會員的文件，
   拿到 `deviceKeyHash`；再查同一 namespace 的 `authChallenges` 裡 `purpose == "bootstrap"`、
   `deviceKeyHash` 相同的文件。成功的 bootstrap 會在交易裡刪掉 challenge，所以留著好幾份就是每次
   都在 challenge 之後、交易之前失敗。順便讀 `authDevices` 文件的 `signCount`、`lastUsedAt`、
   `appleEnvironment`，確認它是舊的、而不是別人剛登記的。

處置：1.8.1 以後的 client 收到 `invalid_assertion` 會自己換鑰（bootstrap 與既有 session 的 `/status` 兩條路徑都會），
通常不用人介入；1.8.0 以前的 client 不會，要由操作者刪除正式庫那一份 `authDevices/<deviceKeyHash>` 文件（只這一份；先把
文件 JSON 備份到 repo 之外）。下一次 bootstrap 會因 `key_not_registered` 讓 client 換一把 App Attest 金鑰並重新 attest，
server 照常驗證 attestation、`device_key_already_registered` 與 `apple_proof_replayed_on_other_device`，
所以這個動作不會多給任何權益。使用者端只要強制關閉 App、再按「同步會員狀態」，預期先看到幾組
快速 401，然後 200。**App 裡的「刪除會員資料」幫不上忙，也不能用在這裡**：那個請求本身需要有效
session（這支手機正是拿不到 session），而且它刪的是會員與購買資料，不是這把裝置金鑰。識別碼寫進
文件時一律截成 6 碼；實例見文末「裝置金鑰斷言失敗與處理 — 2026-10-03」。

## 官方操作依據

- [Cloud Scheduler 執行 Cloud Run Job](https://docs.cloud.google.com/run/docs/execute/jobs-on-schedule)
- [Cloud Run Job task timeout](https://docs.cloud.google.com/run/docs/configuring/task-timeout)
- [Cloud Run Job 最大重試](https://docs.cloud.google.com/run/docs/configuring/max-retries)

此 Job 延續原本刪除策略，沒有替最少防重資料新增保留期限，也不代表保留政策已完成法律審查。

## 本次部署與驗證 — 2026-09-21

- Cloud Scheduler API 原未啟用，本次啟用。先盤點未有刪除 Job、排程或專用身分。
- Runtime SA：`rainyclock-deletion-runtime@rainyclock.iam.gserviceaccount.com`，唯一 project
  grant 為 `roles/datastore.user`，condition `MembershipDeletionDatabasesOnly` 精準限制
  `projects/rainyclock/databases/membership-production` 與
  `projects/rainyclock/databases/membership-testflight`。未授予舊 Sandbox 庫權限或秘密存取。
- Scheduler SA：`rainyclock-deletion-scheduler@rainyclock.iam.gserviceaccount.com`，僅在
  `rainyclock-membership-deletion` Job 授予 `roles/run.invoker`，無 project grant，
  Job 沒有 `allUsers`／`allAuthenticatedUsers` 綁定。
- Job 與 Scheduler 同名 `rainyclock-membership-deletion`，地區 `asia-east1`。
  設定讀回：1 task、1 parallelism、1 CPU、512Mi、600 秒、retry 3，沒有掛 secrets；
  排程 `*/5 * * * *`、`Asia/Taipei`、ENABLED，OAuth SA 與管理 API URL 符合本頁。
- 使用新 Cloud Build `ae56c64b-3992-4602-88e2-d885a5a2c487` 的 image：
  `asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-membership@sha256:1cd2844a1b03b0714149aac28768df055b64203d7138c7820cf1def49ad806c3`。
  沒有沿用缺少新 CLI 的舊映像。
- 首次手動執行 `rainyclock-membership-deletion-8gczx` 成功；11:54:22Z summary 證明兩庫
  都可查詢，pending=0、error=false。
- 在 **TestFlight 庫**建立獨立、已刪除狀態的 `deletion-probe-*` 測試會員及假音訊／
  session，共 3 筆資料；沒有 Apple 身分、交易或有效權益。手動要求 Scheduler 派送，
  11:56:19Z HTTP 200，execution `rainyclock-membership-deletion-v9gc5` 成功；
  11:56:25Z summary 為 Production completed=0、Sandbox completed=1，兩者 failed=0、
  pendingRemaining=false。讀回 marker=complete、音訊及 session 均 404，接著清除自己
  建立的完成 marker 並確認 404。未寫入任何正式會員資料。
- 最終 Java 21／Firestore Emulator 後端全套：**184 通過、0 失敗、0 跳過**，包含兩個
  named DB 清理、失敗續做及並行情境。本次雲端成功測試是受控清理與 OAuth 派送，
  並未故意在正式平台製造中斷。
- Monitoring notification channels 盤點為空，**尚未建立通知告警**。需由使用者指定
  通知目的地後另設 Job execution 失敗／backlog 告警；本次沒有擅自寄 Email。

本機證據：

- `/tmp/rainyclock-membership-final-emulator-tests-20260921.log`
- `/tmp/rainyclock-maintenance-iam-prepared.json`
- `/tmp/rainyclock-membership-deletion-job-created.json`
- `/tmp/rainyclock-membership-deletion-job-iam-verified.json`
- `/tmp/rainyclock-membership-deletion-scheduler-verified.json`
- `/tmp/rainyclock-membership-deletion-scheduler-dispatch.json`
- `/tmp/rainyclock-membership-deletion-scheduled-executions.json`
- `/tmp/rainyclock-membership-deletion-scheduled-summaries.json`
- `/tmp/rainyclock-membership-deletion-cloud-probe-verification.json`

## 排程調整 — 2026-10-02

- Cloud Scheduler `rainyclock-membership-deletion` 的排程由 `*/5 * * * *` 改為
  `7 4,16 * * *`、`Asia/Taipei`（每天 04:07 與 16:07），18:27–18:31（台灣時間）之間套用
  並自雲端讀回。只改這一個排程字串；Job、環境變數與批次上限均未變，沒有重新部署程式。
- 原因：9 月帳單 Cloud Run 用量 US$5.64、免費額度折抵 US$4.62、實付 US$1.02。
  [Cloud Run Job](https://cloud.google.com/run/pricing) 每次 execution 最少計費 1 分鐘，
  同一 billing account 每月共用的 240,000 vCPU-seconds 免費額度約只夠 4,000 次 1 vCPU
  execution；本排程每 5 分鐘即每天 288 次（31 天約 8,900 次），單獨就超過，且幾乎每次
  都無待辦。與同樣每 5 分鐘的停班停課輪詢合計每天 576 次，10 月整月估計約 US$15。
  調整後本 Job 每天 2 次、停班停課輪詢每天 48 次，31 天約 93,000 vCPU-seconds，
  落在免費額度內。使用者決定：這個清理沒有那麼急。
- 影響：刪除請求仍同步撤銷存取並清理；只有中途失敗留下的 `pending` 會等到下一次排程，
  正常最久約 12 小時。該次 execution 若也失敗（含 3 次 task 重試）就再等 12 小時，而本 Job
  目前仍沒有失敗／backlog 告警（見 2026-09-21 紀錄）；存取權在這段期間一直是撤銷的。
- Scheduler 的 `description` 同日改成 `Retry pending membership deletion twice a day (04:07 and
  16:07 Asia/Taipei) in production and TestFlight databases`（原文寫 every five minutes），讀回時
  URI、OAuth service account 與 scope、POST、body、重試 3 次、deadline 60s 都沒有變。
- 尚未驗證：新排程的第一次實際派送與對應 execution（下一次為 2026-10-03 04:07）。

## 裝置金鑰斷言失敗與處理 — 2026-10-03

時間為台灣時間（CST），標 Z 的是 UTC。數值均自 App Store Connect、Cloud Logging、Firestore 或擁有者
截圖讀回；只有 401 的錯誤碼是推斷，原因見下。

- 症狀：1.8.0（40）審核通過、擁有者手動發佈後約 14:36 公開。14:39–14:47 擁有者的 iPhone（iOS 27，
  App Store build 40）設定 › 行事曆的「使用臨時放假規則」開關停用並顯示「尚未確認你的方案」
  （`ux_closure_plan_unconfirmed`），重啟 App 也一樣；會員畫面顯示「One-time member」、「Showing last
  verified status」、診斷列 `session · MembershipHTTP/401 · store=TWN · currency=TWD`，按同步得到
  「Membership action could not be completed」。
- 正式會員服務 log：`POST /v1/membership/challenge` 200 之後 `POST /v1/membership/session` 401，
  60–100 ms，06:39:55Z、06:41:32Z、06:47:33Z（`RainyClock/40`）。同一支手機在 TestFlight 38
  （10-01 19:55Z）與 TestFlight 40（10-02 13:48Z）就已出現同樣的快速 401 特徵。
- 診斷（三次互相獨立的唯讀調查結論一致）：401 是 App Attest 斷言檢查失敗（`auth.js`
  `bootstrapIdentityAndDevice` → `attestation.js` `verifyAssertion`），錯誤碼推斷為 `invalid_assertion`。
  證據：(a) 延遲 60–100 ms 等於兩次 Firestore 讀取加本機 ECDSA，Apple JWS 階段失敗是 0.6–0.7 s、
  成功是 1.9–2.6 s；(b) Cloud Run `responseSize` 185，對應 17 字元的錯誤碼，`app_transaction_refresh_required`
  會是 200；(c) 正式庫 `membershipNamespaces/membership_production_v1/authChallenges` 有三份該裝置金鑰
  `561e4b…` 未消耗的 bootstrap challenge。裝置文件 `authDevices/561e4b…` 存在：`appleEnvironment`
  Production、`signCount` 26、2026-09-26T05:39:45Z 由 App Store 1.7.1（37）登記、`lastUsedAt`
  09-26T05:44:55Z、會員 `3f2390…`、終身購買、未刪除。錯誤碼之所以是推斷：server 不記錄
  錯誤碼（`http.js` 只在 body 回 `{error: code}`），App 的 `MembershipDiagnostic` 又把 server 錯誤縮成
  `MembershipHTTP/<status>`。
- 排除：TestFlight 與 App Store 環境混用。Client 的 Keychain service 依 Apple 環境與 host 分開
  （`RainyClock/Services/MembershipModels.swift` 約 317–318 行），server 的 Production 與 Sandbox 是不同
  資料庫；沒有任何裝置金鑰 hash 同時出現在兩庫。這支手機的兩把金鑰（Production `561e4b…`、Sandbox
  `436f90…`）都是在 TestFlight 與 App Store 安裝互換之後才不再通過驗證；確切機制（App Attest 簽章
  計數器對上已存的 `signCount` 26，或簽章本身）看不到，原因同上。
- 為什麼 App 顯示「尚未確認你的方案」：Production keychain 裡的快照最後一次是 2026-09-26 由 server
  revision 00005 寫入，當時 `deriveEntitlements` 對終身會員給 `temporaryClosures=false`
  （lifetime||subscription 的修正是 `c822562`，09-30 部署為 revision 00006）；
  `TemporaryClosureControlState.resolve`（`MembershipModels.swift` 約 591–604 行）對終身會員因此得到
  `.locked`、`offersPlans=false`，就印出這一行。每次同步都失敗，快照一直沒被取代。手機上沒有任何
  操作能修：client 只在 `key_not_registered`、`invalid_key` 或本機 `DCError` 時換 App Attest 金鑰
  （`RainyClock/Services/MembershipSecurity.swift` `requiresKeyRotation` 約 148–159 行）；重新整理與
  還原只在 `app_transaction_refresh_required` 時重試。
- 其他會員不受影響：另一位會員 10-02 21:08Z 在 revision 00006 上 `/session` 成功；新會員 `c3a049…`
  （裝置 `0ef25f…`）15:06（07:06Z）以 1.8.0 bootstrap，session 200、2.4 s。
- 處置（擁有者的明確決定：「先用 A」）：約 15:16 Claude 以 REST `DELETE` 刪除正式庫單一文件
  `membership-production/membershipNamespaces/membership_production_v1/authDevices/561e4b…`（200，
  之後 `GET` 404）。文件的 JSON 備份只放在該 session 的 scratchpad，不在 repo。沒有動會員、購買、
  session 或其他裝置文件。
- 恢復：擁有者強制關閉 App、按「同步會員狀態」。15:18:09–15:18:35（07:18Z）log 有五組 challenge →
  session 快速 401（client 換鑰與重新 attest 的過程；各次的錯誤碼同樣沒有記錄），15:18:37 session
  200、1.35 s；會員 `3f2390…` 名下有新裝置文件 `33a940…`（`signCount` 0、`verifiedAt` 07:18:37Z）。
  行事曆開關解鎖（15:19 擁有者截圖：開關開啟，Closure preferences、Closure map 兩列可見）。
  隨後 15:18:42 起停班停課第一次在正式簽章的 build 上對正式服務登記並完成推播實測，記在
  `dayoff-service/DEPLOYMENT.md` 執行紀錄。
- 1.8.1 後續（同日下午已改好並測試，`dd65a13` 於 `ios/main`；server 的部分**尚未部署**，App **尚未上傳**）：(1) client：
  `MembershipDeviceProof.requiresKeyRotation` 在 server 回 `invalid_assertion`（與 `attestation_key_rotation_required`）時也換鑰，
  bootstrap 之外，既有 session 的 `/status` 回 `invalid_assertion` 時 `MembershipIdentitySynchronization.run` 也會清 session 再
  bootstrap；server 仍驗 attestation、
  `device_key_already_registered` 與 `apple_proof_replayed_on_other_device`，所以不會因此多拿到權益。
  (2) server：`weather-proxy/membership/http.js` 在錯誤回應時記一行不含秘密的
  `{event:"membership_request_failed", severity, path, status, code}`，沒有 JWS、token 或 body；`code`、`path` 只接受字串且限定
  形狀。(3) client：`MembershipDiagnostic` 帶上 server 錯誤碼（固定字彙，不是使用者資料；要求含 g–z 的字母，所以雜湊與純數字的
  識別碼不會被顯示），會員畫面改讀如 `session · MembershipHTTP/401 · invalid_assertion · store=TWN · currency=TWD`。
  (4) `MembershipListedPrice` 的終身價改為 NT$150／$15.00（App Store Connect 當天只改了台灣，美國基準價仍 US$10，是擁有者的
  待辦，也是 1.8.1 送審前的擋板）。(5) 以上各有測試。(6) 待做：部署 weather-proxy 成 `rainyclock-membership` 00007+，讀回
  `membership_server_listening` 與第一筆 `membership_request_failed`，更新 README.md 與 `MEMBERSHIP-AND-PAYMENTS.md` 的 revision 紀錄。
