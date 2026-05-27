ALTER TABLE runs ADD COLUMN error_summary text;
ALTER TABLE runs ADD COLUMN error_summary_source text NOT NULL DEFAULT 'heuristic';
