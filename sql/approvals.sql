-- Approval chain: proposals move through ordered stages.
-- Tokens are single-use, hashed at rest, and scoped to one stage.

create extension if not exists pgcrypto;

create type approval_status as enum ('pending','approved','rejected','expired');

create table proposals (
  id            uuid primary key default gen_random_uuid(),
  title         text not null,
  payload       jsonb not null default '{}'::jsonb,
  status        approval_status not null default 'pending',
  current_stage int not null default 1,
  created_by    uuid not null,
  created_at    timestamptz not null default now()
);

create table approval_stages (
  id             uuid primary key default gen_random_uuid(),
  proposal_id    uuid not null references proposals(id) on delete cascade,
  stage_number   int  not null,
  approver_email text not null,
  status         approval_status not null default 'pending',
  decided_at     timestamptz,
  reason         text,
  unique (proposal_id, stage_number)
);

-- Only the hash is stored. The plaintext token exists once, in the email.
create table approval_tokens (
  token_hash   text primary key,
  stage_id     uuid not null references approval_stages(id) on delete cascade,
  expires_at   timestamptz not null,
  consumed_at  timestamptz,
  created_at   timestamptz not null default now()
);

create index approval_tokens_stage_idx on approval_tokens (stage_id);

-- Mint a token for a stage. Returns plaintext ONCE; only the hash persists.
create or replace function mint_approval_token(p_stage_id uuid, p_ttl interval default '14 days')
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  raw text := encode(gen_random_bytes(32), 'hex');
begin
  insert into approval_tokens (token_hash, stage_id, expires_at)
  values (encode(digest(raw, 'sha256'), 'hex'), p_stage_id, now() + p_ttl);
  return raw;
end $$;

-- Consume a token and record the decision. A second call fails.
create or replace function consume_approval_token(
  p_token text,
  p_decision approval_status,
  p_reason text default null
)
returns approval_stages
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hash     text := encode(digest(p_token, 'sha256'), 'hex');
  v_stage_id uuid;
  v_stage    approval_stages;
  v_next     int;
begin
  update approval_tokens
     set consumed_at = now()
   where token_hash = v_hash
     and consumed_at is null
     and expires_at > now()
  returning stage_id into v_stage_id;

  if v_stage_id is null then
    raise exception 'token invalid, expired, or already used';
  end if;

  update approval_stages
     set status = p_decision, decided_at = now(), reason = p_reason
   where id = v_stage_id
  returning * into v_stage;

  if p_decision = 'rejected' then
    update proposals set status = 'rejected' where id = v_stage.proposal_id;
  else
    select min(stage_number) into v_next
      from approval_stages
     where proposal_id = v_stage.proposal_id and status = 'pending';

    if v_next is null then
      update proposals set status = 'approved' where id = v_stage.proposal_id;
    else
      update proposals set current_stage = v_next where id = v_stage.proposal_id;
    end if;
  end if;

  return v_stage;
end $$;

revoke execute on function mint_approval_token(uuid, interval) from public;
revoke execute on function consume_approval_token(text, approval_status, text) from public;
