#!/bin/sh
# Day-off service: write a sandbox announcement and push it now.
#
#   sh dayoff-service/deploy/fixture.sh set --county 新北市 --district 板橋區 [--when tomorrow] [--scope both] [--day-part full] [--geocode 65000]
#   sh dayoff-service/deploy/fixture.sh clear      # back to an empty feed (also a revision change, so also a push)
#   sh dayoff-service/deploy/fixture.sh show       # print the current fixture, no execution
#
# The CLI runs on this machine with the operator's own gcloud ADC (which has
# datastore access) against the sandbox namespace, then the sandbox Job is
# executed once with --wait so the broadcast happens while you watch. The
# namespace is the only thing that separates this from production, and both
# src/fixture-cli.js and src/job.js refuse a namespace that does not say
# sandbox, so pointing this at dayoff_production_v1 fails before any write.
# Nothing here prints a secret: the CLI prints one JSON line without ids
# from phones, and the Job's summary is designed the same way.
set -eu
cd "$(dirname "$0")/.."
# The command has to be $1: it decides below whether the Job runs, so an
# option first would write the fixture and then never push it.
case "${1:-}" in
  set|clear|show) ;;
  *) echo "usage: fixture.sh set|clear|show [options]" >&2; exit 2 ;;
esac
R=asia-east1
JOB=rainyclock-dayoff-poll-sandbox

# The gcloud login, not Application Default Credentials: ADC on this kind of
# machine is often lapsed or tied to another project, and gcloud is already
# required for the execution below. The token lives only in node's env.
DAYOFF_ACCESS_TOKEN=$(gcloud auth print-access-token) \
GOOGLE_CLOUD_PROJECT=rainyclock DAYOFF_FIRESTORE_DATABASE=dayoff-production DAYOFF_NAMESPACE=dayoff_sandbox_v1 \
  node src/fixture-cli.js "$@"

[ "$1" = show ] && exit 0
echo "== executing $JOB once (the fixture change is the revision change)"
EXEC=$(gcloud run jobs execute "$JOB" --region="$R" --wait --format='value(metadata.name)')
echo "execution: $EXEC"
# The summary is read for this execution by name: Job stdout reaches Cloud
# Logging seconds after --wait returns, and an unfiltered newest-first read
# would print the previous execution's numbers as this one's.
FILTER="resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"$JOB\" AND labels.\"run.googleapis.com/execution_name\"=\"$EXEC\" AND jsonPayload.event=\"dayoff_job\""
echo "skipped changed broadcast.state broadcast.accepted"
i=0
while [ $i -lt 6 ]; do
  LINE=$(gcloud logging read "$FILTER" --limit=1 --format='value(jsonPayload.skipped,jsonPayload.changed,jsonPayload.broadcast.state,jsonPayload.broadcast.accepted)')
  [ -n "$LINE" ] && { echo "$LINE"; exit 0; }
  i=$((i + 1))
  sleep 5
done
echo "no dayoff_job summary for $EXEC after 30 s; read it later with: gcloud logging read '$FILTER' --limit=1" >&2
exit 1
