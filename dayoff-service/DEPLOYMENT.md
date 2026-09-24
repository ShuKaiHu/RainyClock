# 停班停課服務部署（Cloud Run Job + service + Firestore）

2026-09-24：程式與測試完成（`npm test` 100 通過、7 個 Emulator 測試略過；Firestore Emulator 全套 107 通過）。
資料庫、TTL、索引豁免、secret 容器、映像、service、Job 與 Scheduler 都已建立並以 `open-data` 來源跑過；推播（APNs）與 Scheduler 的 `run.invoker` 尚缺，見最下方「執行紀錄」。
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
   `RainyClock/Info.plist` 的 `DayOffServiceURL`；1.7.1 才翻 `supportsTemporaryClosures`。
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

### 9. 告警（1.7.1 翻開開關之前必須存在）

```sh
gcloud beta monitoring channels create --display-name=owner-email --type=email --channel-labels=email_address=<OWNER_EMAIL>
gcloud beta monitoring channels list --format='value(name)'   # 取 <CHANNEL_ID>，填進 alerts/*.yaml
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
| `NCDR_SOURCE` | `member` 或 `open-data` | `open-data` 免金鑰（data.gov.tw 資料集 20457 的網址）；個人信箱申請不到 NCDR 會員時用它 |
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
只在真實警報期間 p95 延遲超過 3 秒時考慮。可選的 sandbox 堆疊（`dayoff-sandbox`、
`rainyclock-dayoff-sandbox`、`rainyclock-dayoff-poll-sandbox`、`DAYOFF_NAMESPACE=dayoff_sandbox_v1`、
`APNS_PRODUCTION=false`，給 Xcode Debug 裝置用）不測試時要 `pause` 它的 Scheduler。

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

**未執行**：`run.invoker`（擁有者重跑 `deploy/iam.sh`）；APNs `.p8` 版本（§4，擁有者）→ 之後帶
`APNS_KEY_ID`、`APNS_PRODUCTION` 重跑 `deploy/deploy.sh` 開啟推播；告警通道與三個 policy（§9）；
真機推播驗證（§10）。Firestore deny-all rules 未用 firebase-tools 部署（本機未登入）；服務帳號走 IAM，
rules 只影響手機 SDK。

### 更早
第一次執行時，在這裡逐條記錄：日期、指令、讀回的結果（資料庫設定、SA 與 IAM 條件、secret 版本號、
build id 與映像 digest、service URL、第一次 execution 名稱與摘要、重疊測試的兩份摘要、Scheduler
派送與 execution、告警建立與 absence 實測、真機推播證據），以及本機證據檔的路徑。
