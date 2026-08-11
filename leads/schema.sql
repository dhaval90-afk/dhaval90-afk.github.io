-- Workhall Lead Workflow — Supabase/Postgres schema
-- Run this once in your Supabase project's SQL editor (Database > SQL Editor > New query).
-- Safe to re-run: uses IF NOT EXISTS / CREATE OR REPLACE throughout.

create extension if not exists pgcrypto;

-- =========================================================================
-- Reference lists (kept as CHECK constraints on text columns rather than
-- native enums, so adding a value later is an ALTER TABLE, not a migration
-- of the type itself).
-- =========================================================================

-- Stages, in funnel order. Won / Lost / Nurture / Recycle are terminal/side
-- states and are never touched by the automatic forward-only stage bump.
create table if not exists lead_stages (
  name text primary key,
  sort_order int not null
);
insert into lead_stages (name, sort_order) values
  ('New', 1),
  ('Attempting Contact', 2),
  ('Connected', 3),
  ('Qualified', 4),
  ('Meeting Booked', 5),
  ('Opportunity', 6),
  ('Won', 100),
  ('Lost', 100),
  ('Nurture / Recycle', 100)
on conflict (name) do nothing;

create table if not exists activity_types (
  name text primary key,
  creates_task boolean not null default false
);
insert into activity_types (name, creates_task) values
  ('Email sent', true),
  ('Email reply received', false),
  ('Call attempted', true),
  ('Call connected', true),
  ('LinkedIn message sent', true),
  ('LinkedIn reply received', false),
  ('WhatsApp message sent', true),
  ('WhatsApp message reply', false),
  ('Meeting booked', true),
  ('Meeting completed', true),
  ('Follow-up scheduled', true),
  ('Note added', false),
  ('Status updated', false)
on conflict (name) do nothing;

-- =========================================================================
-- Core tables
-- =========================================================================

create table if not exists companies (
  id uuid primary key default gen_random_uuid(),
  company_name text not null,
  domain text,                              -- normalized: lowercase, no protocol/www/path
  industry text,
  company_size text,
  geography text,
  revenue text,
  source text,                              -- e.g. 'Website forms','Apollo.io','Instantly', ...
  source_category text check (source_category in ('Inbound','Outbound')),
  stage text not null default 'New' references lead_stages(name),
  priority text not null default 'P3' check (priority in ('P1','P2','P3')),
  owner text,
  verification_status text not null default 'Pending' check (verification_status in ('Pending','Verified','Rejected')),
  sla_type text,                            -- e.g. 'Inbound-4h','Outbound-Cadence'
  sla_due_at timestamptz,
  sla_completed_at timestamptz,
  sla_met boolean,
  last_activity_date timestamptz,
  next_action_due_date timestamptz,
  qualification_status text not null default 'Pending' check (qualification_status in ('Pending','Qualified','Not Qualified')),
  not_qualified_reason text,
  routing_path text,                        -- e.g. 'Nurture / Recycle','Lost'
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Domain is the strongest dedupe signal — enforce it at the database level
-- for any company that has one. Name-fallback dedupe is handled in the
-- import flow (fuzzy match), since names aren't reliably unique.
create unique index if not exists companies_domain_unique
  on companies (domain)
  where domain is not null and domain <> '';

create table if not exists contacts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  contact_name text not null,
  title text,
  email text,
  phone_whatsapp text,
  linkedin_url text,
  primary_contact_flag boolean not null default false,
  verification_status text not null default 'Pending' check (verification_status in ('Pending','Verified','Rejected')),
  owner text,
  last_activity_date timestamptz,
  next_activity_date timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists contacts_company_id_idx on contacts(company_id);

create table if not exists activities (
  id uuid primary key default gen_random_uuid(),
  activity_type text not null references activity_types(name),
  activity_datetime timestamptz not null default now(),
  company_id uuid not null references companies(id) on delete cascade,
  contact_id uuid references contacts(id) on delete set null,
  owner text,
  direction text check (direction in ('Inbound','Outbound')),
  outcome text,
  next_step_required boolean not null default false,
  next_step_due timestamptz,               -- used by 'Follow-up scheduled' to set the reminder date
  meeting_at timestamptz,                  -- actual scheduled meeting time, for 'Meeting booked'/'Meeting completed'
  notes text,
  source text,
  created_at timestamptz not null default now()
);
create index if not exists activities_company_id_idx on activities(company_id);
create index if not exists activities_contact_id_idx on activities(contact_id);

create table if not exists tasks (
  id uuid primary key default gen_random_uuid(),
  task_type text not null,                 -- 'Follow-up','Meeting Prep','Meeting Follow-up','Manual','Verification', ...
  company_id uuid references companies(id) on delete cascade,
  contact_id uuid references contacts(id) on delete set null,
  owner text,
  priority text check (priority in ('P1','P2','P3')),
  due_date timestamptz,
  status text not null default 'Open' check (status in ('Open','Completed')),
  linked_activity_id uuid references activities(id) on delete set null,
  created_from text,                       -- 'activity','meeting','import','manual','priority_override','qualification'
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create index if not exists tasks_company_id_idx on tasks(company_id);
create index if not exists tasks_status_due_idx on tasks(status, due_date);

create table if not exists priority_override_log (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  previous_priority text,
  new_priority text not null,
  reason text not null,
  changed_by text,
  changed_at timestamptz not null default now()
);

create table if not exists import_batches (
  id uuid primary key default gen_random_uuid(),
  filename text,
  imported_by text,
  imported_at timestamptz not null default now(),
  row_count int not null default 0
);

create table if not exists import_rows (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references import_batches(id) on delete cascade,
  raw_data jsonb not null,
  matched_company_id uuid references companies(id) on delete set null,
  is_duplicate boolean not null default false,
  status text not null default 'Pending' check (status in ('Pending','Approved','Rejected')),
  reviewed_by text,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists import_rows_batch_id_idx on import_rows(batch_id);
create index if not exists import_rows_status_idx on import_rows(status);

-- =========================================================================
-- Helpers
-- =========================================================================

create or replace function normalize_domain(raw text)
returns text language sql immutable as $$
  select case when raw is null or trim(raw) = '' then null else
    lower(regexp_replace(regexp_replace(trim(raw), '^https?://', '', 'i'), '^www\.', '', 'i'))
  end;
$$;

create or replace function add_business_days(start_ts timestamptz, n int)
returns timestamptz language plpgsql immutable as $$
declare
  d date := start_ts::date;
  remaining int := n;
  step int := case when n >= 0 then 1 else -1 end;
begin
  while remaining <> 0 loop
    d := d + step;
    if extract(isodow from d) < 6 then
      remaining := remaining - step;
    end if;
  end loop;
  return d + (start_ts - start_ts::date);
end;
$$;

create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_companies_updated_at on companies;
create trigger trg_companies_updated_at before update on companies
  for each row execute function set_updated_at();

drop trigger if exists trg_contacts_updated_at on contacts;
create trigger trg_contacts_updated_at before update on contacts
  for each row execute function set_updated_at();

-- =========================================================================
-- Company insert defaults: normalize domain, set SLA type/due from source
-- =========================================================================

create or replace function companies_before_insert()
returns trigger language plpgsql as $$
begin
  new.domain := normalize_domain(new.domain);
  if new.source_category = 'Inbound' then
    new.sla_type := coalesce(new.sla_type, 'Inbound-4h');
    new.sla_due_at := coalesce(new.sla_due_at, now() + interval '4 hours');
  elsif new.source_category = 'Outbound' then
    new.sla_type := coalesce(new.sla_type, 'Outbound-Cadence');
  end if;
  return new;
end;
$$;

drop trigger if exists trg_companies_before_insert on companies;
create trigger trg_companies_before_insert before insert on companies
  for each row execute function companies_before_insert();

create or replace function companies_before_update()
returns trigger language plpgsql as $$
begin
  new.domain := normalize_domain(new.domain);
  return new;
end;
$$;

drop trigger if exists trg_companies_before_update on companies;
create trigger trg_companies_before_update before update on companies
  for each row execute function companies_before_update();

-- =========================================================================
-- Activity logging drives: last-activity stamps, forward-only stage bump,
-- and automatic task creation (per section 10/11 of the workflow plan).
-- =========================================================================

create or replace function stage_rank(stage_name text)
returns int language sql immutable as $$
  select sort_order from lead_stages where name = stage_name;
$$;

create or replace function activities_after_insert()
returns trigger language plpgsql as $$
declare
  v_company companies%rowtype;
  v_target_stage text;
  v_task_type text;
  v_due timestamptz;
begin
  select * into v_company from companies where id = new.company_id;

  update companies
     set last_activity_date = new.activity_datetime
   where id = new.company_id;
  if new.contact_id is not null then
    update contacts set last_activity_date = new.activity_datetime where id = new.contact_id;
  end if;

  -- Forward-only auto stage transitions; never touch closed/terminal stages.
  if v_company.stage not in ('Won','Lost','Nurture / Recycle') then
    v_target_stage := case
      when new.activity_type = 'Meeting booked' then 'Meeting Booked'
      when new.activity_type in ('Email reply received','LinkedIn reply received','WhatsApp message reply','Call connected')
        then 'Connected'
      when new.activity_type in ('Email sent','Call attempted','LinkedIn message sent','WhatsApp message sent')
        then 'Attempting Contact'
      else null
    end;
    if v_target_stage is not null and stage_rank(v_target_stage) > stage_rank(v_company.stage) then
      update companies set stage = v_target_stage where id = new.company_id;
    end if;
  end if;

  -- Automatic task creation.
  if new.activity_type = 'Meeting booked' then
    insert into tasks (task_type, company_id, contact_id, owner, priority, due_date, created_from, linked_activity_id)
    values ('Meeting Prep', new.company_id, new.contact_id, new.owner, v_company.priority,
            add_business_days(coalesce(new.meeting_at, new.activity_datetime), -1), 'activity', new.id);
  elsif new.activity_type = 'Meeting completed' then
    insert into tasks (task_type, company_id, contact_id, owner, priority, due_date, created_from, linked_activity_id)
    values ('Meeting Follow-up', new.company_id, new.contact_id, new.owner, v_company.priority,
            add_business_days(coalesce(new.meeting_at, new.activity_datetime), 1), 'activity', new.id);
  elsif new.activity_type = 'Follow-up scheduled' then
    insert into tasks (task_type, company_id, contact_id, owner, priority, due_date, created_from, linked_activity_id)
    values ('Follow-up', new.company_id, new.contact_id, new.owner, v_company.priority,
            coalesce(new.next_step_due, add_business_days(new.activity_datetime, 2)), 'activity', new.id);
  elsif new.activity_type in ('Email sent','Call attempted','Call connected','LinkedIn message sent','WhatsApp message sent') then
    insert into tasks (task_type, company_id, contact_id, owner, priority, due_date, created_from, linked_activity_id)
    values ('Follow-up', new.company_id, new.contact_id, new.owner, v_company.priority,
            add_business_days(new.activity_datetime, 2), 'activity', new.id);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_activities_after_insert on activities;
create trigger trg_activities_after_insert after insert on activities
  for each row execute function activities_after_insert();

-- =========================================================================
-- RPCs the app calls for actions that need an audit trail (reason capture)
-- rather than a plain UPDATE.
-- =========================================================================

create or replace function override_priority(p_company_id uuid, p_new_priority text, p_reason text, p_changed_by text)
returns void language plpgsql as $$
declare
  v_previous text;
begin
  select priority into v_previous from companies where id = p_company_id;
  update companies set priority = p_new_priority where id = p_company_id;
  insert into priority_override_log (company_id, previous_priority, new_priority, reason, changed_by)
  values (p_company_id, v_previous, p_new_priority, p_reason, p_changed_by);
  if p_new_priority = 'P1' then
    insert into tasks (task_type, company_id, owner, priority, due_date, created_from)
    values ('Urgent Follow-up', p_company_id, p_changed_by, 'P1', now() + interval '4 hours', 'priority_override');
  end if;
end;
$$;

create or replace function override_stage(p_company_id uuid, p_new_stage text, p_reason text, p_changed_by text)
returns void language plpgsql as $$
begin
  update companies set stage = p_new_stage where id = p_company_id;
  insert into priority_override_log (company_id, previous_priority, new_priority, reason, changed_by)
  values (p_company_id, 'stage:' || (select stage from companies where id = p_company_id), 'stage:' || p_new_stage, p_reason, p_changed_by);
end;
$$;

create or replace function qualify_company(p_company_id uuid, p_decision text, p_reason text, p_routing_path text, p_changed_by text)
returns void language plpgsql as $$
begin
  if p_decision = 'Qualified' then
    update companies
       set qualification_status = 'Qualified',
           stage = case when stage_rank('Qualified') > stage_rank(stage) then 'Qualified' else stage end
     where id = p_company_id;
  else
    update companies
       set qualification_status = 'Not Qualified',
           not_qualified_reason = p_reason,
           routing_path = p_routing_path,
           stage = coalesce(p_routing_path, 'Nurture / Recycle')
     where id = p_company_id;
  end if;
end;
$$;

-- =========================================================================
-- Row Level Security — this is a small internal team: any authenticated
-- user has full read/write access to every table. Anonymous access is
-- blocked entirely.
-- =========================================================================

alter table companies enable row level security;
alter table contacts enable row level security;
alter table activities enable row level security;
alter table tasks enable row level security;
alter table priority_override_log enable row level security;
alter table import_batches enable row level security;
alter table import_rows enable row level security;
alter table lead_stages enable row level security;
alter table activity_types enable row level security;

drop policy if exists team_full_access on companies;
create policy team_full_access on companies for all to authenticated using (true) with check (true);
drop policy if exists team_full_access on contacts;
create policy team_full_access on contacts for all to authenticated using (true) with check (true);
drop policy if exists team_full_access on activities;
create policy team_full_access on activities for all to authenticated using (true) with check (true);
drop policy if exists team_full_access on tasks;
create policy team_full_access on tasks for all to authenticated using (true) with check (true);
drop policy if exists team_full_access on priority_override_log;
create policy team_full_access on priority_override_log for all to authenticated using (true) with check (true);
drop policy if exists team_full_access on import_batches;
create policy team_full_access on import_batches for all to authenticated using (true) with check (true);
drop policy if exists team_full_access on import_rows;
create policy team_full_access on import_rows for all to authenticated using (true) with check (true);
drop policy if exists team_read on lead_stages;
create policy team_read on lead_stages for select to authenticated using (true);
drop policy if exists team_read on activity_types;
create policy team_read on activity_types for select to authenticated using (true);
