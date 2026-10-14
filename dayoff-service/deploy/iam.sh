#!/bin/sh
# Day-off service: the identity and permission steps the owner runs by hand.
# Everything here is a permission grant, which an unattended session must not do.
# Idempotent: re-running only re-applies the same bindings.
set -eu
P=rainyclock
R=asia-east1
DB=dayoff-production

# Three runtime identities, mirroring the membership stack.
for sa in "rainyclock-dayoff-service|RainyClock day-off HTTP service" \
          "rainyclock-dayoff-job|RainyClock day-off poll job" \
          "rainyclock-dayoff-scheduler|RainyClock day-off scheduler"; do
  n=${sa%%|*}; d=${sa#*|}
  gcloud iam service-accounts describe "$n@$P.iam.gserviceaccount.com" >/dev/null 2>&1 \
    || gcloud iam service-accounts create "$n" --display-name="$d"
done

# Firestore: only the day-off database, only for the service and the job.
for n in rainyclock-dayoff-service rainyclock-dayoff-job; do
  gcloud projects add-iam-policy-binding "$P" \
    --member="serviceAccount:$n@$P.iam.gserviceaccount.com" \
    --role=roles/datastore.user \
    --condition="title=DayoffProductionDatabaseOnly,expression=resource.name==\"projects/$P/databases/$DB\"" \
    --format="value(etag)"
done

# Secrets: the job reads the NCDR key and the APNs .p8; the HTTP service holds neither.
for s in dayoff-ncdr-api-key dayoff-apns-key; do
  gcloud secrets add-iam-policy-binding "$s" \
    --member="serviceAccount:rainyclock-dayoff-job@$P.iam.gserviceaccount.com" \
    --role=roles/secretmanager.secretAccessor --format="value(etag)"
done

# The scheduler may only start the poll job. Run this line after the job exists.
gcloud run jobs add-iam-policy-binding rainyclock-dayoff-poll --region="$R" \
  --member="serviceAccount:rainyclock-dayoff-scheduler@$P.iam.gserviceaccount.com" \
  --role=roles/run.invoker --format="value(etag)" 2>/dev/null \
  || echo "job rainyclock-dayoff-poll not created yet; re-run this script after deploying it"

echo "done"
