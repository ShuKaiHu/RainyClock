# 停班停課服務部署（Cloud Run Job + service + Firestore）

2026-09-24：程式與測試完成（`npm test` 100 通過、7 個 Emulator 測試略過；Firestore Emulator 全套 107 通過）。
資料庫、TTL、索引豁免、secret、映像、service、Job、Scheduler 與 APNs 推播都已就緒並以 `open-data` 來源運行中；告警通道與三個 policy 已建，absence 告警實測寄達；只剩真機推播驗證，見最下方「執行紀錄」。
每一步實際執行後，把讀回的結果寫進最下方的「執行紀錄」，沒做過的不要寫成做過。
設計依據見 `docs/DISASTER-PREVIEW.md` 與 `README.md`；本頁只講怎麼部署、怎麼看、怎麼救。

## 形狀

Cloud Scheduler 每 5 分鐘啟動 Cloud Run **Job** `rainyclock-dayoff-poll`（`node src/job.js`）：
取租約、抓 NCDR、一筆交易寫入 Firestore、續傳推播、釋放租約、印一行摘要、`process.exit`。
Cloud Run **service** `rainyclock-dayoff`（`node src/server.js`）只讀 Job 寫好的 `state/current`
回覆手機，本身沒有輪詢、沒有金鑰、沒有磁碟。兩者用**同一個映像 digest**、各自的 service
account，只在具名資料庫 `dayoff-production` 上有權限。沿用 `weather-proxy/membership/MAINTENANCE.md`
的作法：不要用公開 URL 當 Job 的入口，Scheduler 打的是 Google 管理 API。

## 資源名稱

| 項目 | 值 |
| --- | --- |
| 專案／地區 | `rainyclock` / `asia-east1` |
| Firestore 資料庫 | `dayoff-production`（Standard、Native、刪除保護、`firestore.rules` 全部拒絕） |
| 文件前綴 | `dayoffNamespaces/dayoff_production_v1/` |
| Service | `rainyclock-dayoff` |
| Job | `rainyclock-dayoff-poll`（1 task、`--task-timeout 600s`、`--max-retries 1`） |
| Scheduler | `rainyclock-dayoff-poll`（`*/5 * * * *`、`Asia/Taipei`） |
| Service account | `rainyclock-dayoff-service@`、`rainyclock-dayoff-job@`、`rainyclock-dayoff-scheduler@`（皆 `rainyclock.iam.gserviceaccount.com`） |
| Secrets | `dayoff-ncdr-api-key`（環境變數）、`dayoff-apns-key`（`.p8` 檔案掛載） |
| 映像 | `asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff@sha256:<digest>` |
| Log 指標 | `dayoff_job_runs`、`dayoff_job_failures`、`dayoff_broadcast_incomplete` |
| 告警 | `alerts/absence.yaml`、`alerts/failed-executions.yaml`、`alerts/broadcast-incomplete.yaml` |

不得重用任何 `membership-*` 資料庫，也不得退回 `(default)`；`src/runtime.js` 拒絕 `(default)`，
但只有人能防止建立第二個同名資料庫，所以第 2 步先 `list` 再 `create`。

## 由擁有者親手完成、無法寫成指令的事

1. NCDR 會員 API Key（https://alerts.ncdr.nat.gov.tw/web/developer/alerts-api ）——只進 Secret
   Manager，不進 repo、shell history 或 log。
2. Apple 開發者網站：為 team `MQJ88U9NAJ` 建一把 **APNs** auth key（與 WeatherKit／IAP 金鑰分開；
   一個 team 最多兩把 APNs key），下載 `.p8` 一次、記下 Key ID，上傳到 Secret Manager 後刪除下載檔。
3. 確認 App Store／TestFlight 封存的 `aps-environment` 是 `production`（entitlement 檔寫的是
   `development`，Xcode 在 archive 時改成 production），且 `com.shukaihu.RainyClock` 已開 Push
   Notifications capability。`APNS_PRODUCTION` 必須跟裝置的環境一致，否則 APNs 回 `BadDeviceToken`。
4. Monitoring 通知管道（目前專案沒有任何一個）與下面第 9 步的告警。
5. 第一次 Job 成功後，把 Cloud Run 給的 URL（不含路徑、不經轉址、不用自訂網域）填進
   `RainyClock/Info.plist` 的 `DayOffServiceURL`；1.8.0 才翻 `supportsTemporaryClosures`。
6. 部署後把每個資源、digest、驗證結果記進本頁「執行紀錄」、`docs/STATUS-IOS.md`、
   `docs/DISASTER-PREVIEW.md`、`README.md`「快取、期限與部署方式」與 `CLAUDE.md`。

## 部署順序

在 repo 根目錄執行；`<...>` 是擁有者填的值。每一步都是冪等或先查再建；照順序做，
不要跳到後面的步驟——service 要先有 URL，Job 才能拿到 `DAYOFF_SERVICE_URL`。

### 1. 專案與 API

```sh
gcloud config set project rainyclock
gcloud services enable run.googleapis.com cloudscheduler.googleapis.com firestore.googleapis.com \
  secretmanager.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  logging.googleapis.com monitoring.googleapis.com
```

### 2. Firestore：資料庫、TTL、索引豁免、規則

```sh
gcloud firestore databases list   # 確認 dayoff-production 不存在；絕不建立重複的資料庫
gcloud firestore databases create --database=dayoff-production --location=asia-east1 \
  --type=firestore-native --edition=standard --delete-protection
for cg in devices caps broadcasts retries; do
  gcloud firestore fields ttls update expiresAt --collection-group=$cg --database=dayoff-production --enable-ttl
done
gcloud firestore indexes fields update noticesJSON --collection-group=state --database=dayoff-production --disable-indexes
gcloud firestore indexes fields update xml --collection-group=caps --database=dayoff-production --disable-indexes
(cd dayoff-service && npx firebase-tools deploy --only firestore:rules --project rainyclock)
gcloud firestore fields ttls list --database=dayoff-production   # 預期四筆 ACTIVE
```

索引豁免是必要的：Firestore 索引的字串上限 1500 bytes，`noticesJSON` 與 `xml` 都會超過，沒豁免就
寫不進去。`devices.updatedAt`（容量計數）與 `devices.deviceToken`（410 查詢）維持自動單欄索引，
不要一併豁免。規則部署失敗（firebase-tools 沒連到專案）可以略過：手機從不直接連 Firestore，
兩個 service account 由 IAM 管，deny-all 規則只擋 client SDK。

### 3. Service account 與 IAM

```sh
gcloud iam service-accounts create rainyclock-dayoff-service --display-name="RainyClock day-off HTTP service"
gcloud iam service-accounts create rainyclock-dayoff-job --display-name="RainyClock day-off poll job"
gcloud iam service-accounts create rainyclock-dayoff-scheduler --display-name="RainyClock day-off scheduler"
for SA in rainyclock-dayoff-service rainyclock-dayoff-job; do
  gcloud projects add-iam-policy-binding rainyclock \
    --member="serviceAccount:$SA@rainyclock.iam.gserviceaccount.com" --role=roles/datastore.user \
    --condition='title=DayoffProductionDatabaseOnly,expression=resource.name=="projects/rainyclock/databases/dayoff-production"'
done
```

### 4. Secrets（Job 才拿得到；service 一個都沒有）

```sh
gcloud secrets create dayoff-ncdr-api-key --replication-policy=user-managed --locations=asia-east1
read -rs NCDR_KEY; printf '%s' "$NCDR_KEY" | gcloud secrets versions add dayoff-ncdr-api-key --data-file=-; unset NCDR_KEY
gcloud secrets create dayoff-apns-key --replication-policy=user-managed --locations=asia-east1
gcloud secrets versions add dayoff-apns-key --data-file=<PATH_OUTSIDE_REPO>/AuthKey_<APNS_KEY_ID>.p8   # 之後刪除下載檔
for S in dayoff-ncdr-api-key dayoff-apns-key; do
  gcloud secrets add-iam-policy-binding $S \
    --member="serviceAccount:rainyclock-dayoff-job@rainyclock.iam.gserviceaccount.com" --role=roles/secretmanager.secretAccessor
done
```

`read -rs` 在 repo 之外的終端機執行，金鑰不會出現在指令列或 history。

### 5. 建置一個映像，兩個工作共用

```sh
TAG=$(git rev-parse --short HEAD)
gcloud builds submit dayoff-service --tag asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff:$TAG
IMAGE=$(gcloud artifacts docker images describe \
  asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff:$TAG \
  --format='value(image_summary.fully_qualified_digest)')
```

`.gcloudignore` 排除 `test/`、`.env*`、任何 `.p8`；`Dockerfile` 只複製 `src/` 與 `apns.js`。
之後一律用 `$IMAGE`（digest），service 與 Job 永遠指向同一個。

### 6. Service

```sh
gcloud run deploy rainyclock-dayoff --region=asia-east1 --image="$IMAGE" --command=node --args=src/server.js \
  --service-account=rainyclock-dayoff-service@rainyclock.iam.gserviceaccount.com \
  --allow-unauthenticated --ingress=all --cpu=1 --memory=512Mi --concurrency=80 --timeout=30 \
  --min-instances=0 --max-instances=3 \
  --set-env-vars=GOOGLE_CLOUD_PROJECT=rainyclock,DAYOFF_FIRESTORE_DATABASE=dayoff-production,DAYOFF_NAMESPACE=dayoff_production_v1,MAX_CACHE_AGE_MS=900000,SNAPSHOT_CACHE_MS=5000,PUSH_CONFIGURED=1,APNS_PUSH_MODE=alert,TRUST_PROXY=1
URL=$(gcloud run services describe rainyclock-dayoff --region=asia-east1 --format='value(status.url)')
curl -sS -i "$URL/health"          # 第一次 Job 跑完前是 503 not_configured，pushConfigured:true、pushMode:"alert"
curl -sS -i -X DELETE "$URL/v1/devices" -H 'Content-Type: application/json' --data '{"x":1}'   # 預期 400 invalid_device_request
```

那個 DELETE 證明 body 有被轉送、途中沒有轉址；iOS 端的裝置請求拒絕任何轉址。

### 7. Job，先手動跑一次

```sh
gcloud run jobs create rainyclock-dayoff-poll --region=asia-east1 --image="$IMAGE" --command=node --args=src/job.js \
  --service-account=rainyclock-dayoff-job@rainyclock.iam.gserviceaccount.com \
  --tasks=1 --parallelism=1 --max-retries=1 --task-timeout=600s --cpu=1 --memory=512Mi \
  --set-env-vars=GOOGLE_CLOUD_PROJECT=rainyclock,DAYOFF_FIRESTORE_DATABASE=dayoff-production,DAYOFF_NAMESPACE=dayoff_production_v1,POLL_INTERVAL_MS=300000,REQUEST_TIMEOUT_MS=10000,BROADCAST_CONCURRENCY=16,BROADCAST_PAGE_SIZE=200,LEASE_MS=120000,LEASE_RENEW_MS=30000,RUN_BUDGET_MS=420000,DAYOFF_SERVICE_URL=$URL,APNS_TEAM_ID=MQJ88U9NAJ,APNS_KEY_ID=<APNS_KEY_ID>,APNS_TOPIC=com.shukaihu.RainyClock,APNS_PRODUCTION=<true|false>,APNS_PUSH_MODE=alert,APNS_PRIVATE_KEY_PATH=/secrets/apns/AuthKey.p8 \
  --set-secrets=NCDR_API_KEY=dayoff-ncdr-api-key:latest,/secrets/apns/AuthKey.p8=dayoff-apns-key:latest
gcloud run jobs execute rainyclock-dayoff-poll --region=asia-east1 --wait
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="rainyclock-dayoff-poll" AND jsonPayload.event="dayoff_job"' --limit=3 --format=json
curl -sS -i "$URL/health" && curl -sS "$URL/v1/suspensions" | head -c 400 && curl -sS "$URL/health/details"   # 現在 200，有 revision 與 notices
gcloud run jobs execute rainyclock-dayoff-poll --region=asia-east1 & \
gcloud run jobs execute rainyclock-dayoff-poll --region=asia-east1 --wait; wait   # 重疊證明：其中一份摘要必須是 skipped:"lease_held"
```

`RUN_BUDGET_MS`（420 s）必須小於 `--task-timeout`（600 s），留給 `finally` 釋放租約、關閉連線；
`LEASE_RENEW_MS` 必須小於 `LEASE_MS`，`src/job.js` 啟動時會檢查。

### 8. Scheduler

```sh
gcloud run jobs add-iam-policy-binding rainyclock-dayoff-poll --region=asia-east1 \
  --member="serviceAccount:rainyclock-dayoff-scheduler@rainyclock.iam.gserviceaccount.com" --role=roles/run.invoker
gcloud scheduler jobs create http rainyclock-dayoff-poll --location=asia-east1 \
  --schedule='*/5 * * * *' --time-zone=Asia/Taipei \
  --uri=https://run.googleapis.com/v2/projects/rainyclock/locations/asia-east1/jobs/rainyclock-dayoff-poll:run \
  --http-method=POST --message-body='{}' --headers=Content-Type=application/json \
  --oauth-service-account-email=rainyclock-dayoff-scheduler@rainyclock.iam.gserviceaccount.com \
  --oauth-token-scope=https://www.googleapis.com/auth/cloud-platform \
  --attempt-deadline=60s --max-retry-attempts=3 --min-backoff=10s
gcloud scheduler jobs run rainyclock-dayoff-poll --location=asia-east1
gcloud run jobs executions list --job=rainyclock-dayoff-poll --region=asia-east1 --limit=3
```

用的是 Scheduler SA 的 **OAuth access token**（scope `cloud-platform`）打管理 API，不是打 Cloud Run
公開網址的 OIDC token。Scheduler 回 200 只代表 execution 啟動了，抓取成功與否看 Job 的摘要。

### 9. 告警（1.8.0 翻開開關之前必須存在）

```sh
gcloud beta monitoring channels create --display-name=owner-email --type=email --channel-labels=email_address=<OWNER_EMAIL>
gcloud beta monitoring channels list --format='value(name)'   # 取 <CHANNEL_ID>，填進 alerts/*.yaml
# 沒裝 beta/alpha 元件時，用 REST API 送 alerts/*.json（2026-09-24 實際採用）：
#   TOKEN=$(gcloud auth print-access-token); curl -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
#     https://monitoring.googleapis.com/v3/projects/rainyclock/notificationChannels --data '{"type":"email","displayName":"owner-email","labels":{"email_address":"<OWNER_EMAIL>"},"enabled":true}'
#   curl -X POST ... https://monitoring.googleapis.com/v3/projects/rainyclock/alertPolicies --data @dayoff-service/alerts/<name>.json
gcloud logging metrics create dayoff_job_runs --description='day-off poll executions' \
  --log-filter='resource.type="cloud_run_job" AND resource.labels.job_name="rainyclock-dayoff-poll" AND jsonPayload.event="dayoff_job"'
gcloud logging metrics create dayoff_job_failures --description='day-off poll runs with ok=false' \
  --log-filter='resource.type="cloud_run_job" AND resource.labels.job_name="rainyclock-dayoff-poll" AND jsonPayload.event="dayoff_job" AND jsonPayload.ok=false'
gcloud logging metrics create dayoff_broadcast_incomplete --description='day-off broadcast not done' \
  --log-filter='resource.type="cloud_run_job" AND resource.labels.job_name="rainyclock-dayoff-poll" AND jsonPayload.event="dayoff_job" AND jsonPayload.broadcast.state!="done" AND jsonPayload.broadcast.state!=""'
gcloud run jobs execute rainyclock-dayoff-poll --region=asia-east1 --wait   # 讓 dayoff_job_runs 先有一個資料點，absence 條件才建得起來
gcloud alpha monitoring policies create --policy-from-file=dayoff-service/alerts/absence.yaml
gcloud alpha monitoring policies create --policy-from-file=dayoff-service/alerts/failed-executions.yaml
gcloud alpha monitoring policies create --policy-from-file=dayoff-service/alerts/broadcast-incomplete.yaml
gcloud billing budgets create --billing-account=<BILLING_ACCOUNT_ID> --display-name=rainyclock-dayoff --budget-amount=5USD --threshold-rule=percent=1.0
```

三個告警裡 `absence.yaml` 是唯一不可省的：Scheduler 死掉不會產生失敗的 execution，只有「15 分鐘沒有
摘要」看得出來。來源失敗（`upstream_*`）退出碼是 0，也不會是失敗的 execution，靠
`dayoff_job_failures`。三份 YAML 沒有對著 Monitoring API 驗證過：建立時 `gcloud` 拒絕就改欄位，
建立後要用 `gcloud scheduler jobs pause` 停 20 分鐘，確認 absence 告警真的寄信，再 `resume`。

### 10. 驗收（記進「執行紀錄」，不能只記「建好了」）

- [ ] 第一次手動 execution 成功，`$URL/health` 200，`/v1/suspensions` 有 `revision` 與 `checkedAt`。
- [ ] 兩個 execution 重疊，其中一份摘要 `skipped:"lease_held"`，另一份 `refreshed:true`。
- [ ] `DELETE /v1/devices` 帶垃圾 JSON 回 400 `invalid_device_request`。
- [ ] Scheduler 手動派送一次，`executions list` 看得到對應的 execution。
- [ ] TestFlight 裝置註冊成功（201），強制一次 revision 改變（在 Firestore console 把
      `state/current.revision` 改成任意別的字串再 `execute` 一次：下一次抓取會判定內容改變、建立 claim；
      或等真實公告），log 只有**一個** `push_batch`，通知服務擴充功能改寫了橫幅。
- [ ] 下一個 execution 的摘要 `changed:false`、`broadcast:null`。
- [ ] 暫停 Scheduler 20 分鐘，absence 告警寄達；`resume` 後告警自動關閉。
- [ ] `gcloud firestore fields ttls list` 四筆 ACTIVE；`/health/details` 的 `storage:"firestore"`。

## 環境變數

Service（`rainyclock-dayoff`，都不是秘密）：

| 變數 | 值 | 說明 |
| --- | --- | --- |
| `PORT` | Cloud Run 注入 | 映像預設 8080 |
| `HOST` | `0.0.0.0` | 映像預設 |
| `GOOGLE_CLOUD_PROJECT` | `rainyclock` | `DAYOFF_FIRESTORE_PROJECT` 可覆寫 |
| `DAYOFF_FIRESTORE_DATABASE` | `dayoff-production` | 必填，`(default)` 被拒 |
| `DAYOFF_NAMESPACE` | `dayoff_production_v1` | 文件前綴 |
| `MAX_CACHE_AGE_MS` | `900000` | 超過 15 分鐘的快照回 503 `stale_cache` |
| `SNAPSHOT_CACHE_MS` | `5000` | 每個 instance 每 5 秒最多讀一次 `state/current` |
| `PUSH_CONFIGURED` | `1` | 只是宣告 Job 有 APNs；service 本身沒有金鑰 |
| `APNS_PUSH_MODE` | `alert` | 必須與 Job 相同 |
| `TRUST_PROXY` | `1` | 限速以最後一個 `X-Forwarded-For`（Cloud Run 接上的真正來源）為鍵 |

Job（`rainyclock-dayoff-poll`）：

| 變數 | 值 | 說明 |
| --- | --- | --- |
| `GOOGLE_CLOUD_PROJECT`、`DAYOFF_FIRESTORE_DATABASE`、`DAYOFF_NAMESPACE` | 同 service | 兩者必須讀同一份文件 |
| `POLL_INTERVAL_MS` | `300000` | 成功後下一次允許抓取的時間，與排程相同 |
| `REQUEST_TIMEOUT_MS` | `10000` | 每個 NCDR 請求 |
| `BROADCAST_CONCURRENCY` | `16` | 1..64；APNs 回 429 時降低 |
| `BROADCAST_PAGE_SIZE` | `200` | 50..500；一次崩潰最多重送一頁 |
| `LEASE_MS` / `LEASE_RENEW_MS` | `120000` / `30000` | 續約必須短於租約 |
| `RUN_BUDGET_MS` | `420000` | 必須小於 task timeout 600 s |
| `DAYOFF_SERVICE_URL` | `$URL` | 內容改變時暖機一次；https、只有 origin |
| `APNS_TEAM_ID` | `MQJ88U9NAJ` | |
| `APNS_KEY_ID` | `<APNS_KEY_ID>` | 輪替時改這裡 |
| `APNS_TOPIC` | `com.shukaihu.RainyClock` | |
| `APNS_PRODUCTION` | `true`（TestFlight／App Store）或 `false`（Xcode Debug） | 必填，沒有預設 |
| `APNS_PUSH_MODE` | `alert` | |
| `APNS_PRIVATE_KEY_PATH` | `/secrets/apns/AuthKey.p8` | Secret 掛載路徑 |
| `NCDR_SOURCE` | `member` 或 `open-data` | `open-data` 免金鑰（data.gov.tw 資料集 20457 的網址）；個人信箱申請不到 NCDR 會員時用它。第三個值 `fixture` 只給 sandbox Job（namespace 不含 `sandbox` 即啟動失敗 `fixture_not_allowed`） |
| `NCDR_API_KEY` | secret `dayoff-ncdr-api-key:latest` | `--set-secrets` 注入的環境變數；只在 `member` 來源，`open-data` 時不要掛 |
| `CLOUD_RUN_EXECUTION` | Cloud Run 注入 | 租約的 owner；同一 execution 的 task 重試可接管 |

四個 `APNS_*` 設定全留白就是只抓不推；填一半會啟動失敗（`invalid_apns_configuration`）。

## IAM

- `rainyclock-dayoff-service@` 與 `rainyclock-dayoff-job@`：各自只有條件式 `roles/datastore.user`，
  條件限制 `projects/rainyclock/databases/dayoff-production`；沒有其他資料庫、沒有 Vertex／TTS。
- `rainyclock-dayoff-job@` 另有兩個 secret 的 `roles/secretmanager.secretAccessor`（逐 secret 授，
  不給專案層級）。service SA 沒有任何 secret。
- `rainyclock-dayoff-scheduler@`：只在 **Job** `rainyclock-dayoff-poll` 上有 `roles/run.invoker`，
  沒有專案層級授權、沒有 Firestore 權限。Job 不綁 `allUsers`／`allAuthenticatedUsers`。
- Service `rainyclock-dayoff` 是 `--allow-unauthenticated`：手機沒有 Google 身分。限速是每個
  instance 記憶體內的 30 次／分鐘，`max-instances 3` 表示每個來源最多約 90 次／分鐘；它擋濫用，
  不是安全邊界。
- 部署者要有 Cloud Run／Scheduler 管理權限與三個 SA 的 `iam.serviceAccounts.actAs`；不要把管理
  權限給實際跑排程的 SA。

## 秘密處理與輪替

- 兩個 secret 都是 `user-managed`、只在 `asia-east1`。加入版本一律用 `--data-file=-` 或 repo 外的
  檔案路徑；不要 `echo`。`.gcloudignore` 與 `.gitignore` 都排除 `*.p8`。
- Job 只印一行摘要，摘要與 stderr 診斷都沒有金鑰、token、installationId、URL 或原始錯誤文字
  （`test/job.test.js` 用假金鑰驗證）。
- APNs 金鑰輪替（`apns_credentials_rejected` 告警、或 Apple 要求時）：

```sh
gcloud secrets versions add dayoff-apns-key --data-file=<PATH_OUTSIDE_REPO>/AuthKey_<NEW_KEY_ID>.p8
gcloud run jobs update rainyclock-dayoff-poll --region=asia-east1 --update-env-vars=APNS_KEY_ID=<NEW_KEY_ID>
gcloud run jobs execute rainyclock-dayoff-poll --region=asia-east1 --wait
gcloud secrets versions disable <OLD_VERSION> --secret=dayoff-apns-key
```

  被拒時 claim 停在 `sending` 並保留租約，那一次不計入 3 次嘗試（否則三個 tick 就會把 revision 用盡），
  換鑰後的那次執行從游標續傳，不重送已送出的頁。
- NCDR key 輪替：加入新版本後 `gcloud run jobs update ... --update-secrets=NCDR_API_KEY=dayoff-ncdr-api-key:latest`
  （Job 每次執行都重新讀 `latest`，其實只要停用舊版本並執行一次確認）。

## Sandbox 堆疊（隨時在 Debug 手機上製造一次真正的推播）

正式 Job 只在 revision 改變時推播，NCDR 又只在颱風期間才變，所以「手機收到推播 → 通知擴充功能改寫
→ 鬧鐘判斷」在平常無法驗證。Sandbox 堆疊用**同一個映像 digest**（≥ 含 `NCDR_SOURCE=fixture` 的版本）跑第二組 service ＋ Job，差別只有：

| 項目 | 正式 | Sandbox |
| --- | --- | --- |
| Service | `rainyclock-dayoff` | `rainyclock-dayoff-sandbox`（其餘旗標與正式相同） |
| Job | `rainyclock-dayoff-poll` | `rainyclock-dayoff-poll-sandbox` |
| `DAYOFF_NAMESPACE` | `dayoff_production_v1` | `dayoff_sandbox_v1`（同一個 `dayoff-production` 資料庫） |
| `NCDR_SOURCE` | `open-data` | `fixture`：讀 `dayoffNamespaces/dayoff_sandbox_v1/fixture/current`，不連 NCDR |
| `APNS_PRODUCTION` | `true` | `false`（Xcode Debug 裝置的 token 在 APNs sandbox） |
| Scheduler | `*/5` | **沒有**；每次輪詢都是 `deploy/fixture.sh` 或手動 `jobs execute` |
| Service account、secret、IAM | 相同（`.p8` 掛載同一個 `dayoff-apns-key`；`datastore.user` 條件是整個資料庫） | 相同，不必新增 |

正式環境不受影響：`src/job.js` 在 namespace 不含 `sandbox` 時拒絕 `fixture` 來源，正式 Job 的
`open-data` 來源不讀 `fixture/current`，`src/fixture-cli.js` 拒絕寫入非 sandbox namespace。

### 部署（一次；換 digest 時重跑）

```sh
# 先照「更新程式」那節用含 fixture 來源的 HEAD 建新 image；sandbox 與正式要同 digest，所以之後也用同一個 IMAGE 重佈正式（gcloud run deploy rainyclock-dayoff / jobs update rainyclock-dayoff-poll）
# 執行紀錄裡正式在跑的 sha256:d4024db9… 早於 NCDR_SOURCE=fixture，拿它部署 sandbox 的第一次執行會以 invalid_configuration 失敗；sandbox 現行 digest 見「執行紀錄（sandbox）」
# APNS_KEY_ID 與正式 Job 相同（同一把 .p8 兩個 gateway 都能用）
IMAGE=asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff@sha256:<digest> \
APNS_KEY_ID=<APNS_KEY_ID> sh dayoff-service/deploy/sandbox.sh
SANDBOX_URL=$(gcloud run services describe rainyclock-dayoff-sandbox --region=asia-east1 --format='value(status.url)')
curl -sS "$SANDBOX_URL/health/details"   # 第一次執行後：state ready、source "fixture"、noticeCount 0（沒有 fixture = 空 Feed）
```

腳本會部署 service、建立／更新 Job（`NCDR_SOURCE=fixture`、`APNS_PRODUCTION=false`、`DAYOFF_SERVICE_URL`
指向 sandbox service）、手動執行一次，**不建 Scheduler**。

### 製造一次推播

```sh
# 本機以擁有者的 gcloud ADC 寫 fixture（project rainyclock、資料庫 dayoff-production、namespace dayoff_sandbox_v1），
# 再執行 sandbox Job 一次（--wait），推播當場發生
sh dayoff-service/deploy/fixture.sh set --county 新北市 --district 板橋區                  # 明天停止上班、停止上課
sh dayoff-service/deploy/fixture.sh set --county 臺東縣 --when today --scope school        # 今天照常上班、停止上課
sh dayoff-service/deploy/fixture.sh set --county 連江縣 --day-part morning                 # 明天上午停止上班、停止上課
sh dayoff-service/deploy/fixture.sh show                                                   # 只看，不執行 Job
sh dayoff-service/deploy/fixture.sh clear                                                  # 空 Feed，也是一次 revision 改變 → 也推播
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="rainyclock-dayoff-poll-sandbox" AND jsonPayload.event="dayoff_job"' --limit=3 --format=json
curl -sS "$SANDBOX_URL/v1/suspensions"   # 手機的通知擴充功能讀到的就是這個
```

同一份 fixture 再執行一次是 `changed:false`、`broadcast:null`，不會重複推播。沒有 Scheduler，所以最後一次
執行 15 分鐘後 sandbox service 回 503 `stale_cache`（手機退回保守規則），要再看就再執行一次 Job。
`gcloud logging read` 用正式的 metric 過濾不到 sandbox Job（`job_name` 不同），三個告警都不會被 sandbox 觸發。

### 手機端

1. **不改任何 plist。** App 自己選 sandbox：`AppEnvironment.dayOffServiceURL` 在每個 Debug build
   （`RainyClock`、`RainyClock Membership Local`、Debug Sandbox 皆是，因為它們都以 `aps-environment = development`
   簽章，token 只在 APNs sandbox）讀 `RainyClock/Info.plist` 的 `DayOffSandboxServiceURL`，Release 才讀
   `DayOffServiceURL`。確認 `$SANDBOX_URL` 等於 `DayOffSandboxServiceURL`（預期
   `https://rainyclock-dayoff-sandbox-510427696731.asia-east1.run.app`；Cloud Run 若印出別的 host，要更新的是
   `DayOffSandboxServiceURL`，不是 `DayOffServiceURL`），然後從 Xcode 以 Debug 裝到真機（模擬器沒有 APNs token）。
   通知擴充功能用的是 App 註冊時寫進 `DayOffSharedState.serviceURL` 的同一個網址，擴充功能那邊不必改。
2. 在 App 開啟停班停課功能、確認縣市／行政區，讓 App 向 sandbox service `POST /v1/devices`（201）。
   `curl -sS "$SANDBOX_URL/health"` 的 `pushConfigured:true`；Firestore console 的
   `dayoffNamespaces/dayoff_sandbox_v1/devices/` 多一筆（不要抄 token 到任何地方）。
3. `sh dayoff-service/deploy/fixture.sh set --county <手機設定的縣市> --district <手機設定的行政區>`；
   腳本印出這次 execution 名稱與它自己的摘要（`skipped changed broadcast.state broadcast.accepted`，
   依 execution 名稱過濾，不會拿到上一次的），應為 `changed:true`、`broadcast.accepted:1`；`skipped` 非空
   （`lease_held`／`backoff`）就是這次沒輪詢。手機在幾秒內收到橫幅，內容由通知擴充功能改寫成
   符合本機行政區的文字。鬧鐘要等 App 打開才會跟著改；**距上一次 Job 超過 15 分鐘就先重跑一次 Job**
   （`gcloud run jobs execute rainyclock-dayoff-poll-sandbox --region=asia-east1 --wait`，內容不變不會推播），
   否則 App 拿到 503 會照規則恢復鬧鐘，看起來像沒有套用。
4. 換 `--scope`／`--when`／`--day-part` 各跑一次，最後 `clear`，確認每次都是新的 revision、都收到一則、
   而且鬧鐘判斷符合 `docs/dayoff-fixtures.json` 的預期。
5. 結束後不必還原任何設定；TestFlight／App Store（Release）build 一直走正式 URL 與 production APNs。

### 執行紀錄（sandbox）

### 2026-09-28 18:43 – 09-29 00:07（真機：iPhone 16 Pro，Debug Sandbox build）

- `fixture.sh set --county 臺南市`（18:43，明天＝9/29）→ `accepted=1`；擴充功能 `GET /v1/suspensions` 200，
  通知改寫成時效性、有聲，睡眠專注模式下仍送達。打開 App 後 9/29 略過，receipt `applied`。
- 再發一次時，擴充功能拿下一個會響的 9/30 比對，說「與你設定的地區無關」：App 端錯誤，`7954488` 修正。
- 23:50 App 拿到 503（上一次 Job 已超過 15 分鐘），照規則恢復 9/29；23:51 重發 → 有聲通知（正確，當時 9/29 未略過）。
  23:53 打開 App 沒有重抓：5 分鐘節流擋住了推播後的更新，App 端錯誤，本次修正（推播時間晚於上次嘗試就不節流）。
- 23:58 App 抓到 200，receipt `applied`（revision `ef03b536c0`）。00:05 重跑 Job：`changed=false`、未推播。
- 00:07 `fixture.sh set --county 臺南市 --when today`（今天＝9/29，已略過）→ `accepted=1`，擴充功能 200；
  手機顯示安靜的「9/29: that day's alarm has already been skipped.」。00:12 App 抓到 revision `5b94fa0e15`，receipt `applied`。

### 2026-09-28 01:54–02:05（Claude 執行，讀回值）

- Cloud Build `d9d55807-0981-472f-ba6a-d115af119378`，37 秒，SUCCESS，來源 commit `df5ec48`（含 fixture 來源）；
  digest `asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff@sha256:20a7a485862bc2588bfd202d5a8dc11556c91030f4143ccc55f3d7c5eccdfce3`。
  **正式堆疊仍跑 `sha256:d4024db9…`**，未重新部署；正式與 sandbox 暫時不同 digest，下次正式更新時對齊。
- `IMAGE=<上面 digest> APNS_KEY_ID=H9SMW8923R sh deploy/sandbox.sh` → service `rainyclock-dayoff-sandbox`
  revision `rainyclock-dayoff-sandbox-00001-fkk`（URL `https://rainyclock-dayoff-sandbox-510427696731.asia-east1.run.app`），
  Job `rainyclock-dayoff-poll-sandbox`（`NCDR_SOURCE=fixture`、`dayoff_sandbox_v1`、`APNS_PRODUCTION=false`、無 Scheduler）。
  第一次執行 `…-2kxtg`：`source=fixture changed=true noticeCount=0`、broadcast `done`、`accepted=0`（沒有裝置）。
- 第一次 `fixture.sh set` 失敗：本機 ADC 過期（`invalid_grant`）且屬於另一個專案。`7c9b684` 起 `fixture.sh`
  改用 `gcloud auth print-access-token` 的權杖，不再依賴 ADC。
- `fixture.sh set --county 新北市 --district 板橋區` → execution `…-gs5tf`：`changed=true`、broadcast `done`、
  `accepted=0`；sandbox `/v1/suspensions` 回 1 則：`[停班停課通知]新北市板橋區:明天停止上班、停止上課。行政院人事行政總處。`
  （Extreme／Alert／Actual，geocode `65000`）。隨後 `fixture.sh clear` → 0 則。
- 正式堆疊全程不受影響：`source=open-data`、14 則。

**尚未執行**：手機端（Debug build 登記到 sandbox、收到橫幅、擴充功能改寫、隔天鬧鐘被略過）。

## 更新程式

```sh
TAG=$(git rev-parse --short HEAD)
gcloud builds submit dayoff-service --tag asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff:$TAG
IMAGE=$(gcloud artifacts docker images describe asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff:$TAG --format='value(image_summary.fully_qualified_digest)')
gcloud run deploy rainyclock-dayoff --region=asia-east1 --image="$IMAGE"
gcloud run jobs update rainyclock-dayoff-poll --region=asia-east1 --image="$IMAGE"
```

兩個工作永遠同一個 digest。改 `state/current` 的欄位時先讀 `README.md` 的 schema 段：service 讀的是
Job 寫的文件，兩邊的映像不同會讓 `/v1/suspensions` 直接 503 或送出錯的欄位。

## 運行手冊

一個畫面看完：

```sh
curl -s $URL/health/details | jq
```

可以信任的狀態：`state:"ready"`、`ageMs < 600000`、`job.finishedAt` 在 6 分鐘內、`broadcast` 是
`null` 或 `state:"done"`。不是的話：

```sh
gcloud run jobs executions list --job rainyclock-dayoff-poll --region asia-east1 --limit 5
gcloud run jobs execute rainyclock-dayoff-poll --region asia-east1 --wait
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="rainyclock-dayoff-poll" AND jsonPayload.event="dayoff_job"' --limit 3
```

| 看到 | 意思 | 做法 |
| --- | --- | --- |
| `errorCode:"upstream_*"`、`invalid_source_*` | NCDR 端的問題 | `nextAttemptAt` 是下一次真正抓取的時間；要立刻重試一次，在 Firestore console 把 `state/current.nextAttemptAt` 改成 `0`（看得到、有稽核），再 `jobs execute` |
| `skipped:"backoff"` | 上一次失敗的退避還沒到 | 同上；不要把 Cloud Run 的 retry 調高，那只會撞同一個閘門 |
| `skipped:"lease_held"` 連續出現 | 前一個 execution 還在跑或被殺時沒釋放 | 租約最長 `LEASE_MS`（2 分鐘）自動過期；連續超過 3 次看 executions 是否有卡住的 task |
| `errorCode:"apns_credentials_rejected"` | APNs 金鑰過期／被撤 | 上面的輪替步驟；被拒的執行不計入嘗試次數，換鑰後 claim 從游標續傳 |
| `broadcast.state:"partial"` 且 `complete:false` | 預算、斷路器或 SIGTERM | task 重試會從游標續傳；連續三次（`attempts:3`）後下一次認領把 claim 標為 `exhausted`、清掉 `pendingBroadcastRevision`，`ok:false` 只告警一次，看 `failed`／`retryPending` 判斷是 APNs 還是我們 |
| `broadcast.state:"exhausted"` | 三次嘗試都沒送完，已停止 | 要再送：在 Firestore console 把 `broadcasts/<rev>` 的 `attempts` 改成 `0`、`state` 改成 `pending`，並把 `state/current.pendingBroadcastRevision` 改回 `<rev>`（看得到、有稽核），再 `jobs execute`；游標會從上次停的地方續傳 |
| `stale_cache` 但 execution 都成功 | 時鐘或 `MAX_CACHE_AGE_MS` 與排程不合 | 排程 5 分鐘、上限 15 分鐘；先確認 Scheduler 沒被暫停 |
| `storage_unavailable` | Firestore 不可用或 IAM 條件錯 | `gcloud projects get-iam-policy rainyclock` 看條件表達式的資料庫名 |

暫停整個功能：`gcloud scheduler jobs pause rainyclock-dayoff-poll --location=asia-east1`。手機 15 分鐘後
收到 503 `stale_cache`，會回到自己的保守規則（不會把舊公告當今天的）。恢復：`resume` 後手動
`execute` 一次。

## 成本

一套正式環境、`min-instances 0`：估計每月約 US$0.50。具名 Firestore 資料庫沒有免費額度（每天
288 次 Job 各讀寫幾份小文件，手機讀取被 5 秒快取吸收）；Secret Manager 已超過 6 個免費版本
（約 US$0.12）；Cloud Scheduler 免費額度 3 個 job，這是第 2 個。`min-instances 1`（約 US$5–8／月）
只在真實警報期間 p95 延遲超過 3 秒時考慮。Sandbox 堆疊（`rainyclock-dayoff-sandbox`、
`rainyclock-dayoff-poll-sandbox`、同一資料庫的 `DAYOFF_NAMESPACE=dayoff_sandbox_v1`、`APNS_PRODUCTION=false`，
給 Xcode Debug 裝置用，見「Sandbox 堆疊」）沒有 Scheduler、`min-instances 0`，不用時幾乎零成本。

## 部署前在本機做的驗證

```sh
cd dayoff-service
npm test                                   # 100 通過，Emulator 那 7 個標 skip
npx firebase-tools emulators:start --only firestore --project demo-rc-dayoff &   # 需要 Java 21；或直接跑 ~/.cache/firebase/emulators/cloud-firestore-emulator-*.jar --host 127.0.0.1 --port 8686
FIRESTORE_EMULATOR_HOST=127.0.0.1:8686 npm test   # 107 通過；test/firestore.test.js 用 demo-rc-dayoff、dayoff-emulator、隨機 namespace
pkill -f cloud-firestore-emulator
```

Emulator 那一組跑的是真的 Firestore 交易：容量上限下的並行註冊、410 與重新註冊的競賽、並行回報
的排序、租約不在手上時提交失敗、兩個 execution 搶租約、兩個送出者搶同一個 claim、以及完整的
`runJob`（改變 → claim → 推播 done → 指標清空）。Emulator 每次交易衝突會印 `Transaction lock timeout`
警告，那是測試刻意製造的。

## 執行紀錄

### 2026-09-24 凌晨（Claude 執行，讀回值）

- Firestore：`projects/rainyclock/databases/dayoff-production`，FIRESTORE_NATIVE，asia-east1，
  DELETE_PROTECTION_ENABLED（`gcloud firestore databases create … --edition=standard --delete-protection`）。
- TTL：`expiresAt` 在 `devices`、`caps`、`broadcasts`、`retries` 四個 collection group 皆 ACTIVE。
- 索引豁免：`state.noticesJSON`、`caps.xml` 皆 0 個索引（`--disable-indexes`）。
- Secret 容器：`dayoff-ncdr-api-key`、`dayoff-apns-key`，user-managed，asia-east1，**都還沒有版本**。
- 映像：Cloud Build `065aed86-83ae-4f1b-acda-817bf0f5d251`，37 秒，SUCCESS，來源為 commit `d0e80ab`；
  `asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff@sha256:dabe3190a127fb5ac0c31af85cc5c1a862eb72ed6562650caebcb1835d472196`。
- 本機：`npm test` 100 過 7 略過；Firestore Emulator 1.22.0 ＋ Homebrew `openjdk@21` 107 全過。

### 2026-09-24 09:2x（擁有者執行 `deploy/iam.sh`，讀回值）

- 建立 `rainyclock-dayoff-service@`、`rainyclock-dayoff-job@`、`rainyclock-dayoff-scheduler@`。
- `roles/datastore.user` 條件 `resource.name=="projects/rainyclock/databases/dayoff-production"` 綁到
  service 與 job 兩個 SA（etag `BwZcMJgIpic=`、`BwZcMJhEZ2Y=`）；兩個 secret 的 `secretAccessor` 綁到 job SA。
- Scheduler 的 `run.invoker` 尚未綁（Job 還不存在，Job 建好後重跑腳本）。

### 2026-09-24 09:35（Claude 部署 service，讀回值）

- `gcloud run deploy rainyclock-dayoff`（§6 的參數，digest `sha256:dabe3190…`）→ revision
  `rainyclock-dayoff-00001-h5r`，URL `https://rainyclock-dayoff-510427696731.asia-east1.run.app`
  （`status.url` 另回 `https://rainyclock-dayoff-hclsjropwq-de.a.run.app`，兩者同一服務）。
- 前幾分鐘 `/health` 回 503 `storage_unavailable`：新 SA 的 IAM 還在傳播。約 5 分鐘後回
  503 `{"configured":false,"available":false,"state":"not_configured",…,"pushConfigured":true,"pushMode":"alert"}`，
  九個鍵完整。`DELETE /v1/devices` 帶垃圾 JSON → 400 `invalid_device_request`（body 有轉送、無轉址）。
- 教訓寫進程式：`10d9951` 起 store 在 SDK 失敗時記一筆 `storage_failure` 與 gRPC 狀態碼（不含訊息）。
  重建映像並以新 digest 重新部署，見下一條。

### 2026-09-24 09:40（Claude 重建並重新部署 service，讀回值）

- Cloud Build `43e2bed6-a679-4b25-bc93-7bf082d40dac`，40 秒，SUCCESS，來源 commit `10d9951`；
  **目前 service 與未來 Job 都要用這個 digest**：
  `asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff@sha256:dbe6fca534098277f2c9ce5f02520413cddaccbd70449a277620c0ed8c39aef5`。
- `gcloud run deploy rainyclock-dayoff --image=<上面 digest>` → revision `rainyclock-dayoff-00002-f6j`，100% 流量；
  `/health` 503 `not_configured`，九鍵完整。等第一次 Job 跑完才會變 200。

### 2026-09-24 11:24–11:27（Claude 執行 `deploy/deploy.sh`，`NCDR_SOURCE=open-data`、無 APNs，讀回值）

- 為什麼是 open-data：NCDR 會員註冊頁「僅受理公務、公司或學校信箱」，個人申請不到金鑰（`3c227c4`）。
- Cloud Build `120a877b-4a38-4995-adbc-37b18365a130`，35 秒，SUCCESS，來源 commit `3c227c4`；**現行 digest**
  `asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff@sha256:d4024db97dc0243b32b7a3f38985d29350616c3ec23b325e16d937ecb936349d`。
- service `rainyclock-dayoff` revision `rainyclock-dayoff-00003-x2l`，`PUSH_CONFIGURED=0`（無 APNs）。
- Job `rainyclock-dayoff-poll` 建立（`NCDR_SOURCE=open-data`，無 secret 掛載）。第一次執行
  `rainyclock-dayoff-poll-kzsx5`：摘要 `ok=true refreshed=true changed=true noticeCount=14 source=open-data
  warmup={status:200, revisionMatches:true}`，1,240 ms。之後 `/health` 200 `ready`；`/v1/suspensions`
  回 14 則 2026-08-22～08-24 的真實 DGPA 公告（`sourceUpdatedAt` 2026-08-24T10:29Z）；`/health/details`
  `source:"open-data"`、`storage:"firestore"`、`broadcast.state:"pending"`（沒有 dispatcher 就不送，指標保留）。
- 重疊證明：同時執行兩次 → `hq47r` `refreshed=true changed=false`、`px7vj` `skipped=lease_held`，兩者 exit 0。
- Scheduler `rainyclock-dayoff-poll` 建立，`*/5 * * * *` Asia/Taipei，ENABLED；**在擁有者重跑 `deploy/iam.sh`
  補 `run.invoker` 之前，整點觸發會被拒**。

### 2026-09-24 11:44（擁有者重跑 `deploy/iam.sh`，補 `run.invoker`；讀回值）

- `gcloud scheduler jobs run` 手動觸發 → execution `rainyclock-dayoff-poll-b5vmw` 成功；03:45Z 整點自動觸發 →
  `rainyclock-dayoff-poll-88db6` 成功；Scheduler `lastAttemptTime` 03:45:04Z、`status: {}`。兩次摘要
  `refreshed=true changed=false`。**從這一刻起每 5 分鐘自動輪詢。**

### 2026-09-24 11:58（擁有者加入 `dayoff-apns-key` 版本 1；Claude 重跑 `deploy/deploy.sh` 開推播，讀回值）

- 第一次重跑因腳本同時給 `--clear-env-vars` 與 `--set-env-vars` 而在 Job 更新失敗（service 已先升到
  `00004-2c2`）；修正腳本後重跑成功：service `rainyclock-dayoff-00005-xgg`（`PUSH_CONFIGURED=1`），
  Job 更新為掛載 `/secrets/apns/AuthKey.p8` 與 APNs 環境變數（Team、Key ID、topic、`APNS_PRODUCTION=true`、
  `APNS_PUSH_MODE=alert`），仍 `NCDR_SOURCE=open-data`、無 NCDR key。
- Job 啟動時讀取並解析 `.p8` 成功（金鑰格式無誤）。execution `rainyclock-dayoff-poll-5vz68`：
  `refreshed=true changed=false`，**broadcast 從 `pending` 走到 `done`**：`attempts=1 accepted=0 failed=0
  unregistered=0 retryPending=0`，因為目前沒有任何裝置登記（1.7.0 閘門關著）。`pendingBroadcastRevision`
  已清空。`/health` `pushConfigured:true pushMode:"alert"`。
- 尚未對真實裝置送過任何推播；第一次真機驗證要等 1.8.0 開閘、手機登記後，再看 `push_batch` 記錄。

### 2026-09-24 12:10–12:25（擁有者提供 email；Claude 建告警，讀回值）

- 記錄指標：`dayoff_job_runs`、`dayoff_job_failures`、`dayoff_broadcast_incomplete` 已建立（`gcloud logging metrics create`）。
- 本機 gcloud 沒裝 `beta`／`alpha` 元件，`gcloud beta monitoring channels` 與 `gcloud alpha monitoring policies` 都不可用；
  改走 Monitoring REST API（`curl` ＋ `gcloud auth print-access-token`）。`alerts/*.json` 是實際送出的內容，
  與 `alerts/*.yaml` 同義；YAML 已填入真實通道 ID。
- 通知通道 `projects/rainyclock/notificationChannels/10219649454523194367`（email，`shukaihu@icloud.com`，enabled）。
  **需要擁有者點 Google 寄來的驗證信**，未驗證前告警不會寄出。
- Policy：`…/alertPolicies/6544845589806021377` poll absent（15 分鐘無摘要）、`…/14647107143383542161`
  execution failed、`…/12166636093063786863` poll degraded。API 只接受 `COMPARISON_GT`／`LT`，
  「至少 3 次」改寫成「多於 2 次」。三個都 enabled。
- absence 告警的實測（暫停 Scheduler 20 分鐘看是否寄信）**尚未做**，要等通道驗證後執行。

### 2026-09-24 13:20–13:48（absence 告警實測，讀回值與擁有者回報）

- email 通道**不需要驗證**：API 回的 `verificationStatus` 未設定，官方文件定義為「該類型不需驗證」。
  先前「待驗證信」的說法有誤。
- 13:20:24 `gcloud scheduler jobs pause`。暫停前 13:20 那次排程剛好跑完，`dayoff_job_runs` 最後一個資料點
  05:22:23Z，之後沒有任何點。
- 13:43 另以 `notificationChannels/…:sendVerificationCode` 請 Google 寄一封測試碼信，單獨驗證送達。
- **擁有者回報兩封都收到**（`shukaihu@icloud.com`）：測試碼信，以及 `rainyclock-dayoff poll absent` 告警信。
  也就是「Scheduler 停了沒人知道」的保險端到端有效，iCloud 不擋 Google Monitoring 的信。
- 經驗值：absence 告警在最後資料點後約 20 分鐘寄達（15 分鐘條件＋5 分鐘對齊＋評估延遲）。
  暫停期間服務超過 15 分鐘沒更新，`/health` 轉為 `unavailable`（`stale_cache`），手機會拿到 503 並照響——符合設計。
- 13:48:32 恢復（ENABLED），補跑 `rainyclock-dayoff-poll-n784k` 成功，`/health` 回到 `ready`。
  注意：`sh` 在 `sleep` 期間收到 SIGTERM 不會立刻跑 trap，要連 `sleep` 一起結束。

**未執行**：真機推播驗證（§10，等 1.8.0 開閘）。之後若要輪替 APNs 金鑰，帶新 Key ID 重跑
`deploy/deploy.sh`（§秘密處理與輪替）。Firestore deny-all rules 未用 firebase-tools 部署（本機未登入）；
服務帳號走 IAM，rules 只影響手機 SDK。

### 更早
第一次執行時，在這裡逐條記錄：日期、指令、讀回的結果（資料庫設定、SA 與 IAM 條件、secret 版本號、
build id 與映像 digest、service URL、第一次 execution 名稱與摘要、重疊測試的兩份摘要、Scheduler
派送與 execution、告警建立與 absence 實測、真機推播證據），以及本機證據檔的路徑。
