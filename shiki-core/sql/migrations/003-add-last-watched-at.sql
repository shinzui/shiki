-- The waiting shiki run process refreshes this about once a minute.
-- NULL means no process has ever reported watching the run.
ALTER TABLE runs ADD COLUMN last_watched_at timestamptz;
