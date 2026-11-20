ALTER TABLE runs
  ADD COLUMN environment text,
  ADD COLUMN kubernetes_context text;
