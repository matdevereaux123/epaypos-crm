/* =========================================================================
   88_users_on_the_org_canvas.sql — employees get a place on the org chart

   The Team Structure hierarchy drew agents and offices only. In-house
   staff appeared on the board view but not on the chart, so the picture of
   the organisation left out the organisation.

   Everything needed to place them already exists — users.manager_id says
   who reports to whom, users.office_id says where they sit. The only
   missing piece was somewhere to remember where a box was dragged to,
   which partners and offices each have as canvas_x/canvas_y.
   ========================================================================= */

alter table users add column if not exists canvas_x numeric;
alter table users add column if not exists canvas_y numeric;

comment on column users.canvas_x is
  'Where this person''s box sits on the Team Structure chart. Same as partners.canvas_x and offices.canvas_x (database/88_users_on_the_org_canvas.sql).';

/* =========================================================================
   AFTER RUNNING THIS
     Team Structure -> Hierarchy shows every employee as well as every
     agent. Drag a box and reopen the tab: it should still be where you put
     it. Reporting lines come from "Reports to" in Settings -> Users.
   ========================================================================= */
