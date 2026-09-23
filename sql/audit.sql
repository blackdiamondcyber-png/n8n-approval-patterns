-- Append-only decision log. Never updated, never deleted.
-- Depends on sql/approvals.sql: run approvals.sql before this file, since
-- the trigger below attaches to the approval_stages table it creates.
create table approval_audit (
  id           bigserial primary key,
  proposal_id  uuid not null,
  stage_number int  not null,
  actor_email  text not null,
  decision     text not null,
  reason       text,
  occurred_at  timestamptz not null default now()
);

create index approval_audit_proposal_idx on approval_audit (proposal_id, occurred_at);

create or replace function log_approval_decision()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is distinct from old.status then
    insert into approval_audit (proposal_id, stage_number, actor_email, decision, reason)
    values (new.proposal_id, new.stage_number, new.approver_email, new.status::text, new.reason);
  end if;
  return new;
end $$;

create trigger approval_stages_audit
  after update on approval_stages
  for each row execute function log_approval_decision();

revoke execute on function log_approval_decision() from public;
