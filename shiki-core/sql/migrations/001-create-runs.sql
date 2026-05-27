CREATE TABLE runs (
  id              uuid PRIMARY KEY,
  service_name    text NOT NULL,
  command         text[] NOT NULL,
  namespace       text NOT NULL,
  job_name        text NOT NULL,
  image           text,
  status          text NOT NULL CHECK (status IN ('pending','running','succeeded','failed')),
  exit_code       integer,
  started_at      timestamptz NOT NULL,
  ended_at        timestamptz,
  duration_ms     bigint,
  log_tail        text,
  service_config  jsonb NOT NULL,
  error           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX runs_service_started_idx ON runs (service_name, started_at DESC);
CREATE INDEX runs_status_idx          ON runs (status);
