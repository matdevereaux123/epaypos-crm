-- =============================================================================
-- 106 - Read-only. Are the tasks still there?
--
-- Reported: updating the task screen alongside the EPAY Back End work made
-- every task disappear. Nothing in migrations 95-105 touches the tasks table,
-- and the Back End commits do not change how tasks load, so the first
-- question is whether the rows still exist at all. Three possibilities and
-- this separates them:
--
--   total_tasks = 0        -> they really were deleted, and we go to backups.
--   total_tasks > 0        -> they exist and the screen is not showing them,
--                             which is a filter or a load failure, not data
--                             loss. The breakdown below says which.
--   open_tasks = 0 but
--   completed_tasks > 0    -> something marked them complete; the Tasks page
--                             opens on "Open", so they would look gone.
--
-- Nothing is changed by this file.
-- =============================================================================

select count(*)                                   as total_tasks,
       count(*) filter (where not completed)      as open_tasks,
       count(*) filter (where completed)          as completed_tasks,
       count(*) filter (where assigned_to is null
                          and created_by is null) as orphaned,
       min(created_at)::date                      as oldest,
       max(created_at)::date                      as newest
  from tasks;

-- Who they belong to. An empty "assignee"/"creator" means the user row they
-- pointed at was deleted (both columns are on delete set null), which hides
-- them from everyone except an admin.
select coalesce(cu.name, '(creator deleted)')  as creator,
       coalesce(au.name, '(nobody assigned)')  as assignee,
       count(*)                                as tasks,
       count(*) filter (where not t.completed) as still_open
  from tasks t
  left join users cu on cu.id = t.created_by
  left join users au on au.id = t.assigned_to
 group by 1, 2
 order by tasks desc;

-- The ten most recent, to recognise.
select title,
       completed,
       due_date,
       created_at::date as created
  from tasks
 order by created_at desc
 limit 10;
