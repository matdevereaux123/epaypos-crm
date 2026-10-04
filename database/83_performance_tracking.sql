/* =========================================================================
   83_performance_tracking.sql — how a partner, agent or rep is doing

   Two different questions, and the CRM could answer neither quickly:

     How many deals have they submitted?   Countable — leads carrying their
                                           id — but only if you went and
                                           counted them.

     Are they any good?                    Not countable at all. The rep who
                                           sends four deals a month and the
                                           one who sent four last January
                                           both show "4".

   So: a standing somebody sets by hand, and a manual deal count for
   business that never went through the CRM — deals written before we
   boarded them, or submitted on paper. The counted figure and the typed
   figure stay separate columns and are shown as separate numbers, because
   a total that silently mixes the two is a number nobody can check.

   Same five columns on partners (Referral Partners and Agents/ISOs are both
   rows there) and on internal_sales_comp, so one panel serves all three.
   ========================================================================= */

do $$
declare
  t text;
begin
  foreach t in array array['partners', 'internal_sales_comp'] loop
    execute format('alter table %I add column if not exists standing text', t);
    execute format('alter table %I add column if not exists standing_note text', t);
    execute format('alter table %I add column if not exists manual_deals integer not null default 0', t);
    execute format('alter table %I add column if not exists manual_deals_note text', t);
    execute format('alter table %I add column if not exists standing_updated_at timestamptz', t);
    execute format('alter table %I add column if not exists standing_updated_by uuid references users(id) on delete set null', t);

    -- Named check constraints so this file can be re-run.
    if not exists (select 1 from pg_constraint where conname = t || '_standing_check') then
      execute format(
        'alter table %I add constraint %I check (standing is null or standing in (''star'',''good'',''steady'',''watch'',''inactive''))',
        t, t || '_standing_check');
    end if;
  end loop;
end $$;

create index if not exists partners_standing_idx on partners (standing);

comment on column partners.standing is
  'How they are doing, set by hand: star, good, steady, watch, inactive. Deliberately a judgement and not derived from the deal count — four deals this month and four deals last January are not the same thing (database/83_performance_tracking.sql).';
comment on column partners.manual_deals is
  'Deals that never went through the CRM. Kept apart from the counted figure and shown as its own number, because a total that mixes the two cannot be checked.';

/* =========================================================================
   AFTER RUNNING THIS
     Open any referral partner, agent or internal sales person — the top of
     the drawer now leads with their numbers and their standing.
   ========================================================================= */
