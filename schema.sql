-- My Video AI database schema (SQLite for v1 — free, no separate DB server).
-- server.js creates these tables automatically on first run.
-- To move later: the same schema works on PostgreSQL with minor type changes.

CREATE TABLE IF NOT EXISTS users (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  email         TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  credits       INTEGER NOT NULL DEFAULT 10,
  created_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS generations (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id       INTEGER NOT NULL REFERENCES users(id),
  fal_request_id TEXT,                          -- id returned by fal.ai queue
  prompt        TEXT NOT NULL,
  aspect_ratio  TEXT NOT NULL DEFAULT '16:9',
  duration      INTEGER NOT NULL DEFAULT 5,     -- seconds
  style         TEXT NOT NULL DEFAULT 'realistic',
  status        TEXT NOT NULL DEFAULT 'queued', -- queued | in_progress | completed | failed
  video_url     TEXT,                           -- set when status = completed
  error         TEXT,                           -- set when status = failed
  cost_credits  INTEGER NOT NULL DEFAULT 1,
  created_at    TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS reports (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id       INTEGER REFERENCES users(id),
  generation_id INTEGER REFERENCES generations(id),
  reason        TEXT NOT NULL,
  created_at    TEXT NOT NULL DEFAULT (datetime('now'))
);
