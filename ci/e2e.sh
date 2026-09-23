#!/usr/bin/env bash
# Drives the imported, activated n8n workflow through its three webhooks and
# asserts on real Postgres rows and real mailpit messages. Every assertion
# exits non-zero with a clear message on failure. Run ci/setup-n8n.sh first.
set -euo pipefail

N8N_URL="http://localhost:5678"
MAILPIT_URL="http://localhost:8025"
PSQL="psql -v ON_ERROR_STOP=1 -X -q -h localhost -U postgres -d postgres -t -A"
export PGPASSWORD=postgres

RUN_ID="$$-$RANDOM"
CREATED_BY="11111111-1111-1111-1111-111111111111"

pass_count=0

ok() {
  pass_count=$((pass_count + 1))
  echo "PASS: $1"
}

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# extract a 64-char hex token from an /approve?token=<token> link in email text
extract_token() {
  grep -oE 'token=[a-f0-9]{64}' | head -1 | sed 's#token=##'
}

message_id_for() {
  # $1 = recipient address, prints the newest matching mailpit message ID (or nothing)
  local to="$1"
  curl -s "$MAILPIT_URL/api/v1/messages?limit=100" \
    | jq -r --arg to "$to" '[.messages[] | select(.To != null and (.To[0].Address == $to))] | .[0].ID // empty'
}

wait_for_message() {
  # $1 = recipient address, prints the mailpit message ID once found
  local to="$1"
  local id
  for i in $(seq 1 30); do
    id=$(message_id_for "$to")
    if [ -n "$id" ]; then
      echo "$id"
      return 0
    fi
    sleep 1
  done
  return 1
}

echo "=============================================="
echo "Scenario 1: two-stage proposal, sequential approval"
echo "=============================================="

APPROVER_A="approver-a-${RUN_ID}@example.test"
APPROVER_B="approver-b-${RUN_ID}@example.test"

# (a) POST the proposal webhook with a two-stage approver list
submit_body=$(jq -n \
  --arg title "Q3 Budget ${RUN_ID}" \
  --arg createdBy "$CREATED_BY" \
  --arg a "$APPROVER_A" \
  --arg b "$APPROVER_B" \
  '{title: $title, payload: {amount: 1000}, created_by: $createdBy, stages: [{n: 1, email: $a}, {n: 2, email: $b}]}')

http_code=$(curl -s -o /tmp/submit_resp.json -w '%{http_code}' \
  -X POST "$N8N_URL/webhook/proposal/submit" \
  -H 'Content-Type: application/json' \
  -d "$submit_body")

[ "$http_code" = "200" ] || { cat /tmp/submit_resp.json >&2; fail "proposal/submit webhook returned HTTP $http_code, expected 200"; }
ok "proposal/submit webhook returned HTTP 200"

# (b) a proposal row and two stage rows exist, and exactly one token is minted
PROPOSAL_ID=$($PSQL -c "select id from proposals where title = 'Q3 Budget ${RUN_ID}' order by created_at desc limit 1;")
[ -n "$PROPOSAL_ID" ] || fail "no proposal row was created for title 'Q3 Budget ${RUN_ID}'"
ok "proposal row created (id=$PROPOSAL_ID)"

STAGE_COUNT=$($PSQL -c "select count(*) from approval_stages where proposal_id = '${PROPOSAL_ID}';")
[ "$STAGE_COUNT" = "2" ] || fail "expected 2 approval_stages rows, found $STAGE_COUNT"
ok "two approval_stages rows created"

TOKEN_COUNT=$($PSQL -c "select count(*) from approval_tokens t join approval_stages s on s.id = t.stage_id where s.proposal_id = '${PROPOSAL_ID}';")
[ "$TOKEN_COUNT" = "1" ] || fail "expected exactly 1 token minted after submit, found $TOKEN_COUNT"
ok "exactly one token minted after submit (stage 1 only, not the whole chain)"

# (c) read the email from mailpit, assert it went to approver A, extract the token
MSG_ID=$(wait_for_message "$APPROVER_A") || fail "no email arrived for approver A ($APPROVER_A)"
ok "email arrived for approver A"

MSG_TEXT=$(curl -s "$MAILPIT_URL/api/v1/message/$MSG_ID" | jq -r '.Text')
TOKEN=$(printf '%s' "$MSG_TEXT" | extract_token)
[ -n "$TOKEN" ] || fail "could not extract an approval token from approver A's email body: $MSG_TEXT"
[ "${#TOKEN}" = "64" ] || fail "extracted token has unexpected length: $TOKEN"
ok "extracted a 64-char stage-1 token from approver A's email"

# make sure approver B has NOT been emailed yet (chain must not mint upfront).
# The submit webhook only responds after its whole execution chain finishes,
# so this is a single point-in-time check, not a race against async delivery.
if [ -n "$(message_id_for "$APPROVER_B")" ]; then
  fail "approver B was emailed before stage 1 was approved (whole chain minted upfront)"
fi
ok "approver B has not been emailed yet"

# (d) GET the confirm webhook with that token; assert it is NOT consumed afterwards
http_code=$(curl -s -o /tmp/confirm_resp.json -w '%{http_code}' "$N8N_URL/webhook/approve?token=${TOKEN}")
[ "$http_code" = "200" ] || { cat /tmp/confirm_resp.json >&2; fail "GET approve returned HTTP $http_code, expected 200"; }
ok "GET confirm page returned HTTP 200"

STILL_UNCONSUMED=$($PSQL -c "select (consumed_at is null) from approval_tokens where token_hash = encode(digest('${TOKEN}','sha256'),'hex');")
[ "$STILL_UNCONSUMED" = "t" ] || fail "GET on the confirm page consumed the token (a link scanner could approve things)"
ok "token is still unconsumed after the GET confirm page (link scanners cannot approve)"

# (e) POST the commit-decision webhook approving; assert the stage-1 decision,
# an audit row, and that a second token was minted and a second email sent to approver B
commit_body='{"decision":"approved","reason":"looks good"}'
http_code=$(curl -s -o /tmp/commit1_resp.json -w '%{http_code}' \
  -X POST "$N8N_URL/webhook/approve/commit?token=${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "$commit_body")
[ "$http_code" = "200" ] || { cat /tmp/commit1_resp.json >&2; fail "POST approve/commit (stage 1 approve) returned HTTP $http_code, expected 200"; }
ok "POST commit-decision (stage 1 approve) returned HTTP 200"

STAGE1_STATUS=$($PSQL -c "select status from approval_stages where proposal_id = '${PROPOSAL_ID}' and stage_number = 1;")
[ "$STAGE1_STATUS" = "approved" ] || fail "expected stage 1 status 'approved', found '$STAGE1_STATUS'"
ok "stage 1 decision recorded as approved"

AUDIT_COUNT_1=$($PSQL -c "select count(*) from approval_audit where proposal_id = '${PROPOSAL_ID}' and stage_number = 1;")
[ "$AUDIT_COUNT_1" = "1" ] || fail "expected exactly 1 audit row for stage 1, found $AUDIT_COUNT_1"
ok "exactly one audit row written for the stage-1 decision"

TOKEN2_COUNT=$($PSQL -c "select count(*) from approval_tokens t join approval_stages s on s.id = t.stage_id where s.proposal_id = '${PROPOSAL_ID}' and s.stage_number = 2;")
[ "$TOKEN2_COUNT" = "1" ] || fail "expected exactly 1 token minted for stage 2, found $TOKEN2_COUNT"
ok "a second token was minted for stage 2"

MSG2_ID=$(wait_for_message "$APPROVER_B") || fail "no email arrived for approver B ($APPROVER_B) after stage 1 approval"
ok "a second email arrived for approver B"

MSG2_TEXT=$(curl -s "$MAILPIT_URL/api/v1/message/$MSG2_ID" | jq -r '.Text')
TOKEN2=$(printf '%s' "$MSG2_TEXT" | extract_token)
[ -n "$TOKEN2" ] || fail "could not extract a stage-2 approval token from approver B's email body: $MSG2_TEXT"
[ "$TOKEN2" != "$TOKEN" ] || fail "stage 2 token is identical to the stage 1 token"
ok "extracted a distinct 64-char stage-2 token from approver B's email"

# (f) replay the stage-1 token; assert it is rejected and nothing changes
http_code=$(curl -s -o /tmp/replay_resp.json -w '%{http_code}' \
  -X POST "$N8N_URL/webhook/approve/commit?token=${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"decision":"approved","reason":"replay attempt"}')
[ "$http_code" -ge 400 ] || fail "replaying the consumed stage-1 token should fail, got HTTP $http_code"
ok "replaying the consumed stage-1 token was rejected (HTTP $http_code)"

AUDIT_COUNT_1_AFTER=$($PSQL -c "select count(*) from approval_audit where proposal_id = '${PROPOSAL_ID}' and stage_number = 1;")
[ "$AUDIT_COUNT_1_AFTER" = "1" ] || fail "replaying the stage-1 token changed the audit trail (now $AUDIT_COUNT_1_AFTER rows)"
ok "replay did not add another audit row or change stage-1 state"

# (g) approve stage 2; assert the final state the schema defines
http_code=$(curl -s -o /tmp/commit2_resp.json -w '%{http_code}' \
  -X POST "$N8N_URL/webhook/approve/commit?token=${TOKEN2}" \
  -H 'Content-Type: application/json' \
  -d '{"decision":"approved","reason":"final sign-off"}')
[ "$http_code" = "200" ] || { cat /tmp/commit2_resp.json >&2; fail "POST approve/commit (stage 2 approve) returned HTTP $http_code, expected 200"; }
ok "POST commit-decision (stage 2 approve) returned HTTP 200"

FINAL_STATUS=$($PSQL -c "select status from proposals where id = '${PROPOSAL_ID}';")
[ "$FINAL_STATUS" = "approved" ] || fail "expected final proposal status 'approved', found '$FINAL_STATUS'"
ok "proposal reached final status 'approved' after both stages cleared"

AUDIT_COUNT_TOTAL=$($PSQL -c "select count(*) from approval_audit where proposal_id = '${PROPOSAL_ID}';")
[ "$AUDIT_COUNT_TOTAL" = "2" ] || fail "expected 2 total audit rows for the proposal, found $AUDIT_COUNT_TOTAL"
ok "audit trail has exactly one row per decision (2 total)"

echo "=============================================="
echo "Scenario 2: single-stage proposal, rejected"
echo "=============================================="

# (h) a second proposal where approver A rejects and the Notify Rejection email arrives
APPROVER_C="approver-c-${RUN_ID}@example.test"

reject_submit_body=$(jq -n \
  --arg title "Reject Me ${RUN_ID}" \
  --arg createdBy "$CREATED_BY" \
  --arg c "$APPROVER_C" \
  '{title: $title, payload: {}, created_by: $createdBy, stages: [{n: 1, email: $c}]}')

http_code=$(curl -s -o /tmp/submit2_resp.json -w '%{http_code}' \
  -X POST "$N8N_URL/webhook/proposal/submit" \
  -H 'Content-Type: application/json' \
  -d "$reject_submit_body")
[ "$http_code" = "200" ] || { cat /tmp/submit2_resp.json >&2; fail "second proposal/submit webhook returned HTTP $http_code, expected 200"; }
ok "second proposal submitted"

PROPOSAL2_ID=$($PSQL -c "select id from proposals where title = 'Reject Me ${RUN_ID}' order by created_at desc limit 1;")
[ -n "$PROPOSAL2_ID" ] || fail "no proposal row was created for the reject scenario"

MSG3_ID=$(wait_for_message "$APPROVER_C") || fail "no email arrived for approver C ($APPROVER_C)"
MSG3_TEXT=$(curl -s "$MAILPIT_URL/api/v1/message/$MSG3_ID" | jq -r '.Text')
TOKEN3=$(printf '%s' "$MSG3_TEXT" | extract_token)
[ -n "$TOKEN3" ] || fail "could not extract a token from approver C's email body: $MSG3_TEXT"
ok "extracted the token for the single-stage reject scenario"

http_code=$(curl -s -o /tmp/reject_resp.json -w '%{http_code}' \
  -X POST "$N8N_URL/webhook/approve/commit?token=${TOKEN3}" \
  -H 'Content-Type: application/json' \
  -d '{"decision":"rejected","reason":"budget too high"}')
[ "$http_code" = "200" ] || { cat /tmp/reject_resp.json >&2; fail "POST approve/commit (reject) returned HTTP $http_code, expected 200"; }
ok "POST commit-decision (reject) returned HTTP 200"

STAGE3_STATUS=$($PSQL -c "select status from approval_stages where proposal_id = '${PROPOSAL2_ID}' and stage_number = 1;")
[ "$STAGE3_STATUS" = "rejected" ] || fail "expected stage 1 status 'rejected', found '$STAGE3_STATUS'"
ok "stage 1 decision recorded as rejected"

PROPOSAL2_STATUS=$($PSQL -c "select status from proposals where id = '${PROPOSAL2_ID}';")
[ "$PROPOSAL2_STATUS" = "rejected" ] || fail "expected proposal status 'rejected', found '$PROPOSAL2_STATUS'"
ok "proposal status is 'rejected'"

# the rejection notice is the SECOND message to this address (the first was
# the original approval request); mailpit lists newest first, so the newest
# match for this address is the rejection notice once it has been sent
REJECT_MSG_ID=""
for i in $(seq 1 30); do
  REJECT_MSG_ID=$(curl -s "$MAILPIT_URL/api/v1/messages?limit=100" \
    | jq -r --arg to "$APPROVER_C" '[.messages[] | select(.To != null and (.To[0].Address == $to))] | sort_by(.Created) | last | .ID // empty')
  [ -n "$REJECT_MSG_ID" ] && [ "$REJECT_MSG_ID" != "$MSG3_ID" ] && break
  sleep 1
done
[ -n "$REJECT_MSG_ID" ] && [ "$REJECT_MSG_ID" != "$MSG3_ID" ] || fail "no separate rejection notice email found for $APPROVER_C"
REJECT_SUBJECT=$(curl -s "$MAILPIT_URL/api/v1/message/$REJECT_MSG_ID" | jq -r '.Subject')
case "$REJECT_SUBJECT" in
  *"rejected"*) ok "Notify Rejection email arrived (subject: $REJECT_SUBJECT)" ;;
  *) fail "expected a rejection-notice subject, got: $REJECT_SUBJECT" ;;
esac

echo "=============================================="
echo "All $pass_count assertions passed"
echo "=============================================="
