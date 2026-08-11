# Workhall Leads

An internal lead-management tool implementing the Workhall Marketing Lead
Workflow Plan: one company/contact record model, a 9-stage pipeline,
activity logging with automatic stage bumps and task creation, SLA
tracking, CSV import with a dedupe/verification queue, and a dashboard.

It's a static site (fits GitHub Pages, no build step) that talks directly
to a [Supabase](https://supabase.com) project for data storage, auth, and
the business-rule logic (stage transitions, auto task creation, SLA due
dates, dedupe) — that logic lives in `schema.sql` as Postgres functions
and triggers, so it's enforced no matter which page touches the data.

## One-time setup

1. **Create a free Supabase project** at [supabase.com](https://supabase.com/dashboard).
2. **Run the schema.** In the Supabase dashboard, go to *SQL Editor > New
   query*, paste the contents of `schema.sql`, and run it. This creates all
   tables, triggers, RPC functions, and Row Level Security policies.
3. **Get your API credentials.** In *Project Settings > API*, copy the
   *Project URL* and the `anon` *public* key.
4. **Fill in `config.js`** in this folder with those two values.
5. **Create team logins.** In *Authentication > Users*, add one user per
   team member (email + password). There's no self-signup — an admin adds
   people here.
6. Open `login.html` (or just `index.html`, which redirects to it) in a
   browser and sign in.

Because the anon key is public by design, access control comes entirely
from Row Level Security: every table only allows reads/writes from a
signed-in Supabase user, so the key being visible in the page source is
expected and safe as long as `schema.sql` has been run in full.

## Pages

| Page | Purpose |
|---|---|
| `index.html` | Dashboard: pipeline/source/owner/priority distribution, activity & task metrics, import/verification summary, top-5-sources table, with filters and period-over-period trend deltas. |
| `pipeline.html` | Kanban board (or list view) of every company by stage, with filters, and a form to add a company. |
| `company.html?id=…` | Company detail: edit fields, contacts, qualification decision, stage/priority overrides (with a required reason), activity log, and tasks. |
| `tasks.html` | Overdue / due today / upcoming / completed tasks across the whole team. |
| `import.html` | CSV upload → dedupe match against existing companies (domain first, name fallback) → verification queue → approve/reject. |

## Automatic behavior (enforced in `schema.sql`)

- Logging an outbound activity (email/call/LinkedIn/WhatsApp) on a `New`
  lead auto-advances it to `Attempting Contact`; a reply or connected call
  advances it to `Connected`. These bumps are forward-only and never touch
  a company that's `Won`, `Lost`, or in `Nurture / Recycle`.
- `Meeting booked` moves the stage to `Meeting Booked` and creates a
  **Meeting Prep** task due 1 business day before the meeting; `Meeting
  completed` creates a **Meeting Follow-up** task due the next business
  day.
- Outbound touches and `Follow-up scheduled` activities create a
  **Follow-up** task automatically.
- New companies get an SLA type/due date based on `source_category`:
  Inbound sources get a 4-hour due date; Outbound sources get a
  cadence-based (non-urgent) SLA.
- Setting priority to `P1` (via the override flow) creates an urgent task
  with a tight due date and logs the override with a reason.
- A company's `domain` is unique at the database level — the strongest
  dedupe signal from the workflow plan. Name-based fallback matching is
  handled in the import flow.

## Known simplifications

This is a first working version, not a literal 1:1 of every edge case in
the plan:

- "Status updated" activities and stage-driven task creation for arbitrary
  stage changes are not auto-ticketed — the plan doesn't fully specify the
  triggering mechanics, so those stay manual for now.
- Owners are free-text (matching whoever is signed in / typed in), not a
  separate roles/permissions table — appropriate for a small internal team,
  per the plan's own framing.
- Trend charts cover the metrics with clear historical fields (new leads,
  activity volume, task completions); some dashboard cells (e.g. "top
  summary" counts) reflect current pipeline state rather than a
  point-in-time snapshot.
