-- Adopts a store the 0.1 Rust core wrote, format 0 with a `state` table, after
-- queue.sql has run: the actor, the traits and the last launch move to `identity`.
-- Its `events` rows are format 1 rows already.
UPDATE identity SET
    external_id = COALESCE((SELECT value FROM state WHERE key = 'external_id'), '*'),
    traits = COALESCE((SELECT value FROM state WHERE key = 'traits'), '{}'),
    app_version = (SELECT value FROM state WHERE key = 'app_version'),
    app_build = (SELECT value FROM state WHERE key = 'app_build')
WHERE id = 1;

DROP INDEX IF EXISTS events_batch;

DROP TABLE state;
