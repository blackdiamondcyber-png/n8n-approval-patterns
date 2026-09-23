#!/usr/bin/env bash
# Builds a CI-only copy of the workflow with throwaway credentials attached,
# then imports it into a real n8n instance and activates it, all via the
# n8n CLI (no browser, no REST login). Must run before ci/e2e.sh.
set -euo pipefail

cd "$(dirname "$0")/.."

N8N_IMAGE="n8nio/n8n:1.123.81"
ENV_FILE="ci/n8n.env"
PSQL="psql -v ON_ERROR_STOP=1 -X -q -h localhost -U postgres -d postgres"

echo "== Creating a dedicated database for n8n's own storage =="
PGPASSWORD=postgres $PSQL -c "create database n8n;"

echo "== Building the CI-only workflow copy with credential ids attached =="
WEBHOOK_ID_1=$(cat /proc/sys/kernel/random/uuid)
WEBHOOK_ID_2=$(cat /proc/sys/kernel/random/uuid)
WEBHOOK_ID_3=$(cat /proc/sys/kernel/random/uuid)

jq \
  --arg pgId "ci-postgres-cred" \
  --arg pgName "CI Postgres" \
  --arg smtpId "ci-smtp-cred" \
  --arg smtpName "CI SMTP" \
  --arg wh1 "$WEBHOOK_ID_1" \
  --arg wh2 "$WEBHOOK_ID_2" \
  --arg wh3 "$WEBHOOK_ID_3" \
  '
  del(.tags)
  | .id = "ci-approval-chain"
  | .nodes |= map(
      if .type == "n8n-nodes-base.postgres" then
        .credentials = { postgres: { id: $pgId, name: $pgName } }
      elif .type == "n8n-nodes-base.emailSend" then
        .credentials = { smtp: { id: $smtpId, name: $smtpName } }
      else . end
    )
  | .nodes |= map(
      if .name == "Webhook: Proposal Submitted" then .webhookId = $wh1
      elif .name == "Webhook: Confirm Page (GET)" then .webhookId = $wh2
      elif .name == "Webhook: Commit Decision (POST)" then .webhookId = $wh3
      else . end
    )
  ' workflow/approval-chain.json > ci/workflow.ci.json

echo "== Verifying the CI copy still has 12 nodes =="
count=$(jq '.nodes | length' ci/workflow.ci.json)
if [ "$count" != "12" ]; then
  echo "expected 12 nodes in the CI workflow copy, found $count"
  exit 1
fi

run() {
  docker run --rm --network host --env-file "$ENV_FILE" "$@"
}

echo "== Resetting n8n user management to create the instance owner =="
run "$N8N_IMAGE" user-management:reset

echo "== Importing CI-only throwaway credentials =="
run -v "$(pwd)/ci:/ci" "$N8N_IMAGE" import:credentials --input=/ci/credentials.ci.json

echo "== Importing the workflow =="
run -v "$(pwd)/ci:/ci" "$N8N_IMAGE" import:workflow --input=/ci/workflow.ci.json

echo "== Activating the workflow (takes effect on next start) =="
run "$N8N_IMAGE" update:workflow --id=ci-approval-chain --active=true

echo "== Starting n8n =="
docker run -d --name n8n-e2e --network host --env-file "$ENV_FILE" "$N8N_IMAGE" start

echo "== Waiting for n8n to become healthy =="
healthy=false
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:5678/healthz" || true)
  if [ "$code" = "200" ]; then
    echo "n8n is healthy after ${i} attempt(s)"
    healthy=true
    break
  fi
  sleep 2
done

if [ "$healthy" != "true" ]; then
  echo "n8n did not become healthy in time"
  docker logs n8n-e2e || true
  exit 1
fi

# /healthz turns green as soon as the HTTP listener is bound, which is
# BEFORE ActiveWorkflowManager finishes registering the active workflow's
# webhooks at boot. A request in that window gets a 404 "is not registered"
# even though the workflow is active, so poll the real webhook (a harmless
# no-op proposal with zero stages) until that race is over.
echo "== Waiting for the workflow's webhooks to finish registering =="
for i in $(seq 1 30); do
  code=$(curl -s -o /tmp/warmup_resp.json -w '%{http_code}' -X POST "http://localhost:5678/webhook/proposal/submit" \
    -H 'Content-Type: application/json' \
    -d '{"title":"ci-warmup","payload":{},"created_by":"00000000-0000-0000-0000-000000000000","stages":[]}' || true)
  if [ "$code" = "200" ]; then
    echo "webhooks are registered after ${i} attempt(s)"
    exit 0
  fi
  echo "attempt ${i}: HTTP ${code:-<none>}"
  sleep 1
done

echo "the proposal/submit webhook never finished registering"
cat /tmp/warmup_resp.json 2>/dev/null || true
docker logs n8n-e2e || true
exit 1
