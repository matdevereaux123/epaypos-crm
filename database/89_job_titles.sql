/* =========================================================================
   89_job_titles.sql — a job title on the person, not on their pay record

   The org chart shows a name and a role. "In House Sales" is the CRM's
   permission classification, not what somebody does — General Manager,
   Regional Sales Director, Installer. That is what people expect to read
   on an org chart, and there was nowhere to put it.

   There WAS a title field, on internal_sales_comp: a pay record. Wrong
   home for it twice over — only sales people have one, and a job title is
   not pay data, so it sat behind a policy written to keep salaries
   private. It moves to the person, where everyone can have one and
   everyone can read it.

   Agents get one too. Both kinds of box appear on the same chart, and a
   title that only half of them can carry is a chart that reads
   inconsistently.
   ========================================================================= */

alter table users    add column if not exists job_title text;
alter table partners add column if not exists job_title text;

-- Carry across whatever was already typed into the pay record, without
-- overwriting anything set on the person since.
update users u
   set job_title = c.title
  from internal_sales_comp c
 where c.user_id = u.id
   and coalesce(nullif(btrim(c.title), ''), '') <> ''
   and coalesce(nullif(btrim(u.job_title), ''), '') = '';

comment on column users.job_title is
  'What this person does — General Manager, Installer. Distinct from users.role, which is the permission classification (database/89_job_titles.sql).';

/* =========================================================================
   AFTER RUNNING THIS
     Settings -> Users, or any person on Team Structure, takes a job title,
     and it shows on their tile on the chart.

     internal_sales_comp.title is left in place rather than dropped: it is
     the source this copied from, and dropping a column is not something to
     do in the same breath as reading it. Nothing writes to it any more.
   ========================================================================= */
