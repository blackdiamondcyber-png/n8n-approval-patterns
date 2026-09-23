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
# BEFORE n8n's Express app has the webhook sub-router mounted, and BEFORE
# ActiveWorkflowManager has registered the workflow's own webhooks on top
# of that. Both gaps show up as a 404: the earliest requests get Express's
# own generic "Cannot POST ..." page (no router mounted yet at all), the
# next batch get n8n's own JSON "is not registered" (router mounted, this
# workflow's routes not added yet). Matching on that JSON string alone
# treated the first, earlier 404 as a false "ready", so check the bare
# HTTP status instead: n8n never answers a real hit on a registered route
# with 404, only with a real business outcome (200, or 500 for something
# like this probe's bogus token), so status 404 in any form means "keep
# waiting" and anything else means the route exists.
route_is_registered() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null) || return 1
  [ "$code" != "404" ]
}

echo "== Waiting for all three webhooks to finish registering =="
for i in $(seq 1 30); do
  ready=true

  route_is_registered -X POST "http://localhost:5678/webhook/proposal/submit" \
    -H 'Content-Type: application/json' \
    -d '{"title":"ci-warmup","payload":{},"created_by":"00000000-0000-0000-0000-000000000000","stages":[{"n":1,"email":"ci-warmup@example.test"}]}' \
    || ready=false

  route_is_registered "http://localhost:5678/webhook/approve?token=ci-warmup-token" \
    || ready=false

  route_is_registered -X POST "http://localhost:5678/webhook/approve/commit?token=ci-warmup-token" \
    -H 'Content-Type: application/json' \
    -d '{"decision":"approved","reason":"warmup"}' \
    || ready=false

  if [ "$ready" = "true" ]; then
    echo "all three webhooks are registered after ${i} attempt(s)"
    exit 0
  fi
  echo "attempt ${i}: still waiting on webhook registration"
  sleep 1
done

echo "the webhooks never finished registering"
docker logs n8n-e2e || true
exit 1
