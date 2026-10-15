/* =========================================================================
   87_restore_set_lead_banking.sql — put back a function that went missing

   Saving banking details on a lead or account fails with:

     Could not find the function public.set_lead_banking(p_banking, p_lead_id)

   It is defined in database/02_encryption.sql and every one of its siblings
   from that same file is present and working — set_lead_ssn,
   set_lead_tax_id, set_lead_drivers_license, reveal_lead_banking. This one
   alone is absent, so it was dropped at some point rather than never
   created; most likely collateral from an earlier pass over the banking
   encryption.

   Recreated with the same behaviour, and one fix to the permission check.

   THE CHECK
     The original read (r.perms->>'editBanking')::boolean. That column is
     not always a boolean: portal roles carry the string 'own', meaning
     "their own payout details". Casting 'own' to boolean raises, so an
     agent saving banking got a 500 from inside the function rather than a
     clean refusal.

     This compares as text instead, and reads through current_app_perms()
     so a permission granted to one person individually
     (database/70_internal_management_and_grants.sql) is honoured — the
     original looked straight at the role and could not see those.

     'own' deliberately does NOT pass here. It means somebody may edit
     their own payout details; a merchant's bank account on a lead is not
     that.
   ========================================================================= */

create or replace function set_lead_banking(p_lead_id uuid, p_banking text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_app_perms()->>'editBanking', '') <> 'true' then
    raise exception 'Not authorized to edit this field';
  end if;
  update leads set banking = encrypt_sensitive(p_banking) where id = p_lead_id;
end;
$$;

revoke execute on function set_lead_banking(uuid, text) from public;
revoke execute on function set_lead_banking(uuid, text) from anon;
grant  execute on function set_lead_banking(uuid, text) to authenticated;

/* =========================================================================
   AFTER RUNNING THIS
     Open an account, Banking (deposit account), change the routing or
     account number and save. Then reopen it: the value should come back
     decrypted, which proves it was both written and encrypted.

     Worth knowing: the ::boolean cast described above is still in the
     other set_/reveal_ functions from 02_encryption.sql. It only bites a
     role whose editBanking is 'own', and it has clearly not come up — but
     it is the same trap, and worth a sweep when there is a reason to open
     that file again.
   ========================================================================= */
