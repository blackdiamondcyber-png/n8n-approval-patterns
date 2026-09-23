-- Assertions against the token lifecycle and the audit trail.
-- Run against a scratch database, after approvals.sql and audit.sql.
-- Raises on first failed assertion.

begin;

do $$
declare
  v_proposal_id uuid;
  v_stage_id    uuid;
  v_stage2_id   uuid;
  raw_token     text;
  wrong_token   text := encode(gen_random_bytes(32), 'hex');
  v_result      approval_stages;
  hash_count    int;
  reuse_ok      boolean := false;
  expired_ok    boolean := false;
  wrong_ok      boolean := false;
begin
  insert into proposals (title, created_by)
    values ('Test proposal', gen_random_uuid()) returning id into v_proposal_id;
  insert into approval_stages (proposal_id, stage_number, approver_email)
    values (v_proposal_id, 1, 'approver@example.com') returning id into v_stage_id;

  -- 1. Minting a token returns a raw token and stores only its sha256 hash.
  select mint_approval_token(v_stage_id) into raw_token;
  if raw_token is null or length(raw_token) <> 64 then
    raise exception 'mint_approval_token should return a 64-char hex token, got %', raw_token;
  end if;

  select count(*) into hash_count
    from approval_tokens
   where token_hash = encode(digest(raw_token, 'sha256'), 'hex');
  if hash_count <> 1 then
    raise exception 'expected one stored row keyed by sha256(raw_token), found %', hash_count;
  end if;

  if exists (select 1 from approval_tokens where token_hash = raw_token) then
    raise exception 'the raw token is stored in plaintext; only its hash should persist';
  end if;

  -- 2. Consuming that token once succeeds and returns the stage.
  select * into v_result from consume_approval_token(raw_token, 'approved', 'looks good');
  if v_result.id is distinct from v_stage_id then
    raise exception 'consume_approval_token returned stage %, expected %', v_result.id, v_stage_id;
  end if;
  if v_result.status <> 'approved' then
    raise exception 'expected stage status approved, got %', v_result.status;
  end if;

  -- 3. Consuming the same token a second time fails. The success/failure
  -- flag is set outside the exception handler below, on purpose: raising
  -- the "this should have failed" exception from inside a block whose own
  -- handler is still listening would let that handler catch it too, and
  -- turn a real test failure into a confusing double-wrapped message.
  begin
    perform consume_approval_token(raw_token, 'approved', 'again');
    reuse_ok := true;
  exception when others then
    if sqlerrm not like '%invalid, expired, or already used%' then
      raise exception 'unexpected error re-consuming a used token: %', sqlerrm;
    end if;
  end;
  if reuse_ok then
    raise exception 'consuming an already-used token should have raised, but it succeeded';
  end if;

  -- 4. An expired token cannot be consumed.
  insert into approval_stages (proposal_id, stage_number, approver_email)
    values (v_proposal_id, 2, 'later@example.com') returning id into v_stage2_id;
  select mint_approval_token(v_stage2_id, interval '-1 second') into raw_token;
  begin
    perform consume_approval_token(raw_token, 'approved', null);
    expired_ok := true;
  exception when others then
    if sqlerrm not like '%invalid, expired, or already used%' then
      raise exception 'unexpected error consuming an expired token: %', sqlerrm;
    end if;
  end;
  if expired_ok then
    raise exception 'consuming an expired token should have raised, but it succeeded';
  end if;

  -- 5. A wrong token cannot be consumed.
  begin
    perform consume_approval_token(wrong_token, 'approved', null);
    wrong_ok := true;
  exception when others then
    if sqlerrm not like '%invalid, expired, or already used%' then
      raise exception 'unexpected error consuming a wrong token: %', sqlerrm;
    end if;
  end;
  if wrong_ok then
    raise exception 'consuming a token that was never minted should have raised, but it succeeded';
  end if;

  raise notice 'token lifecycle assertions passed';
end $$;

-- 6. Every state change writes exactly one audit row, and approval_audit
-- cannot be updated or deleted by the role the workflow runs as. audit.sql
-- calls this table append-only in its header comment; this is the part of
-- the suite that actually holds it to that claim, using the same low
-- privilege the n8n Postgres credential would have (EXECUTE on the two
-- token functions, nothing granted directly on approval_audit).
do $$
declare
  v_proposal_id uuid;
  v_stage_id    uuid;
  raw_token     text;
  audit_rows    int;
begin
  if not exists (select 1 from pg_roles where rolname = 'approval_worker') then
    create role approval_worker nologin;
  end if;

  grant execute on function mint_approval_token(uuid, interval) to approval_worker;
  grant execute on function consume_approval_token(text, approval_status, text) to approval_worker;

  insert into proposals (title, created_by)
    values ('Audit test proposal', gen_random_uuid()) returning id into v_proposal_id;
  insert into approval_stages (proposal_id, stage_number, approver_email)
    values (v_proposal_id, 1, 'auditor@example.com') returning id into v_stage_id;

  perform set_config('role', 'approval_worker', true);

  select mint_approval_token(v_stage_id) into raw_token;
  perform consume_approval_token(raw_token, 'approved', 'ship it');

  reset role;

  select count(*) into audit_rows from approval_audit where proposal_id = v_proposal_id;
  if audit_rows <> 1 then
    raise exception 'expected exactly one audit row for the one state change, found %', audit_rows;
  end if;

  perform set_config('role', 'approval_worker', true);

  begin
    update approval_audit set reason = 'tampered' where proposal_id = v_proposal_id;
    raise exception 'approval_worker updated approval_audit; the append-only claim is false';
  exception when insufficient_privilege then
    null; -- expected
  end;

  begin
    delete from approval_audit where proposal_id = v_proposal_id;
    raise exception 'approval_worker deleted from approval_audit; the append-only claim is false';
  exception when insufficient_privilege then
    null; -- expected
  end;

  reset role;
  raise notice 'audit append-only assertions passed';
end $$;

rollback;
