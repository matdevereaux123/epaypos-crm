-- =============================================================================
-- EPAY POS / Envision ATM Control Center — shareable application links
-- ---------------------------------------------------------------------------
-- Run after 27_assignment_scope.sql.
--
-- A third way to collect an application, alongside the Wix form and manual
-- entry: a link anyone internal can generate and send, which opens a branded
-- landing page and drops the submission straight into Applications.
--
-- Built the same way as the referral links in 12_public_referral.sql — a slug
-- identifies the link, and an anonymous visitor can only reach two
-- SECURITY DEFINER functions, never the tables. The applications table itself
-- stays closed to anon.
-- =============================================================================


create table if not exists application_link_tokens (
  id            uuid primary key default gen_random_uuid(),
  slug          text unique not null,
  label         text not null,
  brand         text not null default 'epay' check (brand in ('epay','atm')),
  -- Who sent it, so a submission can be credited. Either an internal user or
  -- a partner — a partner link lets an agent collect applications too.
  created_by    uuid references users(id) on delete set null,
  partner_id    uuid references partners(id) on delete set null,
  is_active     boolean not null default true,
  submissions   integer not null default 0,
  created_at    timestamptz not null default now()
);

create index if not exists application_link_tokens_slug_idx on application_link_tokens (slug);
create index if not exists application_link_tokens_partner_idx on application_link_tokens (partner_id);

alter table application_link_tokens enable row level security;

-- Any signed-in user can see the links; creating and editing needs the same
-- bar as working leads.
create policy "application_link_tokens_select" on application_link_tokens
  for select to authenticated
  using (true);

create policy "application_link_tokens_write" on application_link_tokens
  for all to authenticated
  using (current_app_has_perm('fullDashboard') or created_by = current_app_user_id())
  with check (current_app_has_perm('fullDashboard') or created_by = current_app_user_id());


-- Applications need somewhere to record which link brought them in.
alter table applications
  add column if not exists link_token_id uuid references application_link_tokens(id) on delete set null;


-- ---------------------------------------------------------------------------
-- What an anonymous visitor may read: enough to brand the page, nothing else.
-- Deliberately returns no ids, no counts and nothing about who created it.
-- ---------------------------------------------------------------------------
create or replace function public_lookup_application_link(p_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_row application_link_tokens%rowtype;
  v_partner_name text;
begin
  select * into v_row from application_link_tokens
   where slug = p_slug and is_active = true;

  if not found then
    return null;
  end if;

  if v_row.partner_id is not null then
    select name into v_partner_name from partners where id = v_row.partner_id;
  end if;

  return jsonb_build_object(
    'brand', v_row.brand,
    'label', v_row.label,
    'partner_name', v_partner_name
  );
end;
$$;

grant execute on function public_lookup_application_link(text) to anon, authenticated;


-- ---------------------------------------------------------------------------
-- The submission itself. Everything the form collects is kept in raw_payload,
-- the same way the Wix intake does, so nothing is lost if the shape changes
-- later. The named columns carry what Applications lists on screen.
-- ---------------------------------------------------------------------------
create or replace function public_submit_application(
  p_slug              text,
  p_business_name     text,
  p_contact_name      text,
  p_email             text,
  p_phone             text,
  p_business_address  text,
  p_business_type     text,
  p_monthly_volume    text,
  p_average_ticket    text,
  p_current_processor text,
  p_notes             text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token application_link_tokens%rowtype;
  v_id uuid;
begin
  select * into v_token from application_link_tokens
   where slug = p_slug and is_active = true;

  if not found then
    raise exception 'This application link is no longer active';
  end if;

  if p_business_name is null or trim(p_business_name) = ''
     or p_contact_name is null or trim(p_contact_name) = '' then
    raise exception 'Business name and contact name are required';
  end if;

  insert into applications (
    business_name, contact_name, email, phone,
    source, link_token_id, raw_payload
  ) values (
    trim(p_business_name),
    trim(p_contact_name),
    nullif(trim(coalesce(p_email, '')), ''),
    nullif(trim(coalesce(p_phone, '')), ''),
    'link',
    v_token.id,
    jsonb_strip_nulls(jsonb_build_object(
      'business_address',  nullif(trim(coalesce(p_business_address, '')), ''),
      'business_type',     nullif(trim(coalesce(p_business_type, '')), ''),
      'monthly_volume',    nullif(trim(coalesce(p_monthly_volume, '')), ''),
      'average_ticket',    nullif(trim(coalesce(p_average_ticket, '')), ''),
      'current_processor', nullif(trim(coalesce(p_current_processor, '')), ''),
      'notes',             nullif(trim(coalesce(p_notes, '')), ''),
      'link_label',        v_token.label,
      'link_slug',         v_token.slug
    ))
  )
  returning id into v_id;

  update application_link_tokens
     set submissions = submissions + 1
   where id = v_token.id;

  return v_id;
end;
$$;

grant execute on function public_submit_application(
  text, text, text, text, text, text, text, text, text, text, text
) to anon, authenticated;


-- =============================================================================
-- AFTER RUNNING THIS
--   The two public_* functions above are the ONLY things anon may call here.
--   Confirm application_link_tokens and applications both still refuse a
--   direct read with the anon key — the landing page needs neither.
-- =============================================================================
