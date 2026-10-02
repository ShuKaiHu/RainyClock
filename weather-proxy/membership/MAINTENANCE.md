# 會員刪除清理 Job

2026-09-21：程式、最小權限 Job 與每 5 分鐘排程已部署，已實際驗證 Scheduler
OAuth 派送及受控 TestFlight 刪除；本頁下方記錄範圍與證據，不代表完整使用者刪帳
UI 或所有正式會員情境均已驗收。其他發布紀錄見 `docs/MEMBERSHIP-STAGING.md`。

2026-10-02：排程由每 5 分鐘改為每天兩次（`7 4,16 * * *`、`Asia/Taipei`，即 04:07 與
16:07）。Job、環境變數與批次上限未變；原因與影響見「IAM 與 Cloud Scheduler」及文末
「排程調整 — 2026-10-02」。

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
