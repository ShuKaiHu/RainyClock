#!/bin/sh
# Day-off service: deploy (or redeploy) the HTTP service, the poll Job and the
# Scheduler from one immutable image digest. Run deploy/iam.sh first, and add
# a version to both secrets, or the Job refuses to start.
#
#   IMAGE=asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff@sha256:... \
#   APNS_KEY_ID=ABC123DEFG APNS_PRODUCTION=true sh dayoff-service/deploy/deploy.sh
#
# IMAGE comes from `gcloud builds submit` (see DEPLOYMENT.md §5). Nothing here
# prints a secret; the NCDR key and the .p8 are mounted by Cloud Run at run time.
set -eu
: "${IMAGE:?set IMAGE to the image digest from gcloud builds submit}"
: "${APNS_KEY_ID:?set APNS_KEY_ID to the Apple APNs auth key id (10 characters)}"
: "${APNS_PRODUCTION:?set APNS_PRODUCTION to true (TestFlight/App Store) or false (Xcode Debug devices)}"
P=rainyclock
R=asia-east1
DB=dayoff-production
NS=dayoff_production_v1

for s in dayoff-ncdr-api-key dayoff-apns-key; do
  if [ -z "$(gcloud secrets versions list "$s" --filter=state=enabled --format='value(name)' --limit=1)" ]; then
    echo "secret $s has no enabled version; add one before deploying the Job (DEPLOYMENT.md §4)" >&2
    exit 1
  fi
done

echo "== service rainyclock-dayoff"
gcloud run deploy rainyclock-dayoff --region="$R" --image="$IMAGE" --command=node --args=src/server.js \
  --service-account="rainyclock-dayoff-service@$P.iam.gserviceaccount.com" \
  --allow-unauthenticated --ingress=all --cpu=1 --memory=512Mi --concurrency=80 --timeout=30 \
  --min-instances=0 --max-instances=3 \
  --set-env-vars="GOOGLE_CLOUD_PROJECT=$P,DAYOFF_FIRESTORE_DATABASE=$DB,DAYOFF_NAMESPACE=$NS,MAX_CACHE_AGE_MS=900000,SNAPSHOT_CACHE_MS=5000,PUSH_CONFIGURED=1,APNS_PUSH_MODE=alert,TRUST_PROXY=1"
URL=$(gcloud run services describe rainyclock-dayoff --region="$R" --format='value(status.url)')
echo "service url: $URL"
curl -sS -o /dev/null -w "GET /health -> %{http_code}\n" "$URL/health"

echo "== job rainyclock-dayoff-poll"
JOB_ENV="GOOGLE_CLOUD_PROJECT=$P,DAYOFF_FIRESTORE_DATABASE=$DB,DAYOFF_NAMESPACE=$NS,POLL_INTERVAL_MS=300000,REQUEST_TIMEOUT_MS=10000,BROADCAST_CONCURRENCY=16,BROADCAST_PAGE_SIZE=200,LEASE_MS=120000,LEASE_RENEW_MS=30000,RUN_BUDGET_MS=420000,DAYOFF_SERVICE_URL=$URL,APNS_TEAM_ID=MQJ88U9NAJ,APNS_KEY_ID=$APNS_KEY_ID,APNS_TOPIC=com.shukaihu.RainyClock,APNS_PRODUCTION=$APNS_PRODUCTION,APNS_PUSH_MODE=alert,APNS_PRIVATE_KEY_PATH=/secrets/apns/AuthKey.p8"
JOB_SECRETS="NCDR_API_KEY=dayoff-ncdr-api-key:latest,/secrets/apns/AuthKey.p8=dayoff-apns-key:latest"
if gcloud run jobs describe rainyclock-dayoff-poll --region="$R" >/dev/null 2>&1; then
  gcloud run jobs update rainyclock-dayoff-poll --region="$R" --image="$IMAGE" \
    --set-env-vars="$JOB_ENV" --set-secrets="$JOB_SECRETS"
else
  gcloud run jobs create rainyclock-dayoff-poll --region="$R" --image="$IMAGE" --command=node --args=src/job.js \
    --service-account="rainyclock-dayoff-job@$P.iam.gserviceaccount.com" \
    --tasks=1 --parallelism=1 --max-retries=1 --task-timeout=600s --cpu=1 --memory=512Mi \
    --set-env-vars="$JOB_ENV" --set-secrets="$JOB_SECRETS"
fi

echo "== first execution (manual)"
gcloud run jobs execute rainyclock-dayoff-poll --region="$R" --wait
curl -sS -o /dev/null -w "GET /health -> %{http_code}\n" "$URL/health"
curl -sS "$URL/health/details" | head -c 600; echo

echo "== scheduler rainyclock-dayoff-poll (*/5, Asia/Taipei)"
if ! gcloud scheduler jobs describe rainyclock-dayoff-poll --location="$R" >/dev/null 2>&1; then
  gcloud scheduler jobs create http rainyclock-dayoff-poll --location="$R" \
    --schedule='*/5 * * * *' --time-zone=Asia/Taipei \
    --uri="https://run.googleapis.com/v2/projects/$P/locations/$R/jobs/rainyclock-dayoff-poll:run" \
    --http-method=POST --message-body='{}' --headers=Content-Type=application/json \
    --oauth-service-account-email="rainyclock-dayoff-scheduler@$P.iam.gserviceaccount.com" \
    --oauth-token-scope=https://www.googleapis.com/auth/cloud-platform \
    --attempt-deadline=60s --max-retry-attempts=3 --min-backoff=10s
fi
echo "done. Put $URL into RainyClock/Info.plist DayOffServiceURL when 1.7.1 flips the gate."
