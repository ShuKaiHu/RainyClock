#!/bin/sh
# Day-off service: deploy (or redeploy) the SANDBOX stack from the same image
# digest production runs, which must be a build that knows NCDR_SOURCE=fixture
# (an older digest fails the first execution with invalid_configuration). It exists to put a push on a Debug phone on demand:
# the Job reads fixture/current instead of NCDR (NCDR_SOURCE=fixture), the
# APNs sandbox is used (Xcode Debug builds), and there is no Scheduler — every
# poll is started by hand, normally through deploy/fixture.sh.
#
#   IMAGE=asia-east1-docker.pkg.dev/rainyclock/cloud-run-source-deploy/rainyclock-dayoff@sha256:... \
#   APNS_KEY_ID=<APNS_KEY_ID> sh dayoff-service/deploy/sandbox.sh
#
# Same database as production, different namespace (dayoff_sandbox_v1), so
# the existing IAM bindings and secrets apply and nothing production serves
# is touched: the fixture source is refused by src/job.js outside a namespace
# that says sandbox. Nothing here prints a secret; the .p8 is mounted by
# Cloud Run at run time.
set -eu
: "${IMAGE:?set IMAGE to the image digest from gcloud builds submit}"
: "${APNS_KEY_ID:?set APNS_KEY_ID; the sandbox stack exists to push, so APNs is not optional here}"
P=rainyclock
R=asia-east1
DB=dayoff-production
NS=dayoff_sandbox_v1
SERVICE=rainyclock-dayoff-sandbox
JOB=rainyclock-dayoff-poll-sandbox

has_version() { [ -n "$(gcloud secrets versions list "$1" --filter=state=enabled --format='value(name)' --limit=1)" ]; }
has_version dayoff-apns-key || { echo "dayoff-apns-key has no enabled version (DEPLOYMENT.md §4)" >&2; exit 1; }

# APNS_PRODUCTION=false is the whole point: a Debug build's token only exists
# on the sandbox gateway, and a production token pushed there is rejected.
APNS_ENV=",APNS_TEAM_ID=MQJ88U9NAJ,APNS_KEY_ID=$APNS_KEY_ID,APNS_TOPIC=com.shukaihu.RainyClock,APNS_PRODUCTION=false,APNS_PUSH_MODE=alert,APNS_PRIVATE_KEY_PATH=/secrets/apns/AuthKey.p8"
JOB_SECRETS="/secrets/apns/AuthKey.p8=dayoff-apns-key:latest"

echo "== service $SERVICE"
gcloud run deploy "$SERVICE" --region="$R" --image="$IMAGE" --command=node --args=src/server.js \
  --service-account="rainyclock-dayoff-service@$P.iam.gserviceaccount.com" \
  --allow-unauthenticated --ingress=all --cpu=1 --memory=512Mi --concurrency=80 --timeout=30 \
  --min-instances=0 --max-instances=3 \
  --set-env-vars="GOOGLE_CLOUD_PROJECT=$P,DAYOFF_FIRESTORE_DATABASE=$DB,DAYOFF_NAMESPACE=$NS,MAX_CACHE_AGE_MS=3600000,SNAPSHOT_CACHE_MS=5000,PUSH_CONFIGURED=1,APNS_PUSH_MODE=alert,TRUST_PROXY=1"
URL=$(gcloud run services describe "$SERVICE" --region="$R" --format='value(status.url)')
echo "sandbox service url: $URL"
curl -sS -o /dev/null -w "GET /health -> %{http_code}\n" "$URL/health"

echo "== job $JOB (NCDR_SOURCE=fixture, no scheduler)"
JOB_ENV="GOOGLE_CLOUD_PROJECT=$P,DAYOFF_FIRESTORE_DATABASE=$DB,DAYOFF_NAMESPACE=$NS,NCDR_SOURCE=fixture,POLL_INTERVAL_MS=60000,REQUEST_TIMEOUT_MS=10000,BROADCAST_CONCURRENCY=16,BROADCAST_PAGE_SIZE=200,LEASE_MS=120000,LEASE_RENEW_MS=30000,RUN_BUDGET_MS=420000,DAYOFF_SERVICE_URL=$URL$APNS_ENV"
# --set-env-vars and --set-secrets each replace the whole set, so a redeploy
# never keeps a stale key.
if gcloud run jobs describe "$JOB" --region="$R" >/dev/null 2>&1; then
  gcloud run jobs update "$JOB" --region="$R" --image="$IMAGE" \
    --set-env-vars="$JOB_ENV" --set-secrets="$JOB_SECRETS"
else
  gcloud run jobs create "$JOB" --region="$R" --image="$IMAGE" --command=node --args=src/job.js \
    --service-account="rainyclock-dayoff-job@$P.iam.gserviceaccount.com" \
    --tasks=1 --parallelism=1 --max-retries=1 --task-timeout=600s --cpu=1 --memory=512Mi \
    --set-env-vars="$JOB_ENV" --set-secrets="$JOB_SECRETS"
fi

echo "== first execution (manual; an absent fixture is an empty feed)"
gcloud run jobs execute "$JOB" --region="$R" --wait
curl -sS -o /dev/null -w "GET /health -> %{http_code}\n" "$URL/health"
curl -sS "$URL/health/details" | head -c 600; echo
echo "done. No scheduler was created on purpose: run deploy/fixture.sh to set a notice and poll once."
# The app picks the sandbox origin itself: every Debug build reads
# DayOffSandboxServiceURL (AppEnvironment.dayOffServiceURL), so nothing is
# edited on the phone side; only a different host from Cloud Run needs that
# one key updated.
echo "Check that RainyClock/Info.plist DayOffSandboxServiceURL equals $URL (not DayOffServiceURL); then run a Debug build on a real device."
