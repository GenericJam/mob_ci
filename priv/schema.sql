-- mob_ci results store (MobCi.Store, MOB-414). Schema version 1.
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
