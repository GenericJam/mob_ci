-- mob_ci results store (MobCi.Store, MOB-414; queue tables MOB-416). Schema version 2.
--
-- Every statement is idempotent (IF NOT EXISTS): MobCi.Store.open/1 runs this
-- file on every open, then sets PRAGMA user_version. A later schema change
-- adds a numbered step to MobCi.Store's migrations, keyed on user_version;
-- never edit a shipped statement here.

-- One invocation of `mix ci.device` / `mix ci.sweep` (or a lane run).
CREATE TABLE IF NOT EXISTS runs (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at   TEXT NOT NULL,          -- ISO 8601 UTC
  trigger      TEXT NOT NULL,          -- ci.device | ci.sweep | nightly | ios-lane | ...
  versions_row TEXT NOT NULL,          -- hex | master | rc:<repo>@<sha> | harness | sloppy_joe
  host         TEXT NOT NULL,          -- the machine (nuc, mac-mini, ...)
  mob_ci_sha   TEXT                    -- git sha of the mob_ci checkout that ran
);

-- One outcome inside a run. `invariant` NULL is the cell's summary row (set ×
-- platform × path, outcome rolled up); otherwise one invariant of that cell
-- ("p2", "p12") or one plugin's self-test ("p12:mob_location").
CREATE TABLE IF NOT EXISTS cells (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id      INTEGER NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  "set"       TEXT NOT NULL,           -- default | all | singleton:mob_x | ...
  platform    TEXT NOT NULL,           -- android | ios | all (static)
  path        TEXT NOT NULL,           -- deploy:android | release:android | deploy:ios | static | ...
  invariant   TEXT,                    -- NULL = cell summary
  layer       TEXT,                    -- MobCi.Report.format_layer/1 of a non-pass, else NULL
  outcome     TEXT NOT NULL CHECK (outcome IN ('pass', 'fail', 'skip', 'error')),
  duration_ms INTEGER,
  log_path    TEXT,
  detail      TEXT,                    -- JSON object
  versions    TEXT                     -- JSON: MobCi.Versions.record/1 of the cell
);

CREATE INDEX IF NOT EXISTS cells_run ON cells(run_id);
CREATE INDEX IF NOT EXISTS cells_lookup ON cells("set", platform, path, invariant);
CREATE INDEX IF NOT EXISTS runs_row ON runs(versions_row);

-- ── Schema 2: the trigger queue (MobCi.Queue, MobCi.Poller; MOB-416) ─────────
-- MobCi.Store.migrate/1 also adds runs.job_id (the job that ran the run) and
-- jobs.publish_lane (the lane whose worker completed the job and owns its
-- report run).

-- One trigger's request: run these sets on this row, on these platforms.
CREATE TABLE IF NOT EXISTS jobs (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  trigger      TEXT NOT NULL,          -- nightly | poll | pre-push | rc | manual
  versions_row TEXT NOT NULL,          -- hex | master | rc:<repo>@<sha>
  sets         TEXT NOT NULL,          -- JSON list of set names, in run order
  platforms    TEXT NOT NULL,          -- JSON list: android, ios
  reason       TEXT,
  priority     INTEGER NOT NULL DEFAULT 0,  -- higher drains first
  not_after    TEXT,                   -- ISO 8601 UTC: cells not started by then expire
  enqueued_at  TEXT NOT NULL,
  finished_at  TEXT,
  publish_exit INTEGER,                -- exit code of mix ci.report [--publish] after it finished
  status       TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'done'))
);

-- One (set, platform) of a job: what a lane worker claims and runs.
CREATE TABLE IF NOT EXISTS job_cells (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id       INTEGER NOT NULL REFERENCES jobs(id),
  versions_row TEXT NOT NULL,
  "set"        TEXT NOT NULL,
  platform     TEXT NOT NULL,          -- android | ios: the lane
  paths        TEXT,                   -- --paths, NULL = the lane's default
  status       TEXT NOT NULL CHECK (status IN ('queued', 'running', 'done', 'duplicate', 'expired')),
  duplicate_of INTEGER,                -- the queued cell that already covers this one
  exit_code    INTEGER,                -- 0 pass, 1 fail, 2 error, 124 timeout
  started_at   TEXT,
  finished_at  TEXT,
  log_path     TEXT
);

CREATE INDEX IF NOT EXISTS job_cells_claim ON job_cells(platform, status);
CREATE INDEX IF NOT EXISTS job_cells_job ON job_cells(job_id);

-- The poller's last-seen default-branch sha per repo.
CREATE TABLE IF NOT EXISTS heads (
  repo    TEXT PRIMARY KEY,
  url     TEXT NOT NULL,
  sha     TEXT NOT NULL,
  seen_at TEXT NOT NULL
);

-- Pre-push notices from the Mac, confirmed against the remote by the poller.
CREATE TABLE IF NOT EXISTS pushes (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  repo        TEXT NOT NULL,
  sha         TEXT NOT NULL,
  ref         TEXT,                    -- the remote ref pushed to (refs/heads/master, …)
  received_at TEXT NOT NULL,
  status      TEXT NOT NULL CHECK (status IN ('pending', 'covered', 'enqueued', 'expired')),
  job_id      INTEGER,
  resolved_at TEXT
);
