-- The device queue, format 1 (`PRAGMA user_version = 1`), the same in the Swift,
-- Kotlin and Rust clients: tools/queue_schema.rb embeds this file in each.

-- Tracked events until the ingest server has them, oldest first. `created_at` is
-- milliseconds since the Unix epoch by the device clock, `body` the event's JSON
-- exactly as it is sent (docs/PROTOCOL.md).
CREATE TABLE IF NOT EXISTS events (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at INTEGER NOT NULL,
    body TEXT NOT NULL
);

-- Who later events are about, and the version and build of the last launch.
CREATE TABLE IF NOT EXISTS identity (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    external_id TEXT NOT NULL DEFAULT '*',
    traits TEXT NOT NULL DEFAULT '{}',
    app_version TEXT,
    app_build TEXT
);

INSERT OR IGNORE INTO identity (id) VALUES (1);
