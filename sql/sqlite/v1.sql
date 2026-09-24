CREATE TABLE clickman_events (
  message_id text PRIMARY KEY NOT NULL,
  occurred_at datetime(6) NOT NULL,
  received_at datetime(6) NOT NULL,
  external_id text NOT NULL,
  event text NOT NULL,
  properties json NOT NULL DEFAULT '{}',
  context json NOT NULL DEFAULT '{}'
);

CREATE INDEX clickman_events_received ON clickman_events (received_at, message_id);

CREATE TABLE clickman_event_names (
  id integer PRIMARY KEY AUTOINCREMENT NOT NULL,
  name text NOT NULL
);

CREATE UNIQUE INDEX clickman_event_names_name ON clickman_event_names (name);

CREATE TABLE clickman_keys (
  id integer PRIMARY KEY AUTOINCREMENT NOT NULL,
  key text NOT NULL
);

CREATE UNIQUE INDEX clickman_keys_key ON clickman_keys (key);

CREATE TABLE clickman_actors (
  id integer PRIMARY KEY AUTOINCREMENT NOT NULL,
  external_id text,
  first_seen_on date NOT NULL,
  erased_at datetime(6),
  CONSTRAINT clickman_actors_erased CHECK ((external_id IS NULL) = (erased_at IS NOT NULL))
);

CREATE UNIQUE INDEX clickman_actors_external_id ON clickman_actors (external_id);

CREATE TABLE clickman_chunks (
  day date NOT NULL,
  event_name_id integer NOT NULL,
  seq integer NOT NULL,
  events integer NOT NULL,
  key_ids json NOT NULL,
  payload blob NOT NULL,
  PRIMARY KEY (day, event_name_id, seq)
) WITHOUT ROWID;

CREATE TABLE clickman_daily_counts (
  day date NOT NULL,
  event_name_id integer NOT NULL,
  events integer NOT NULL,
  actors integer NOT NULL,
  PRIMARY KEY (day, event_name_id)
) WITHOUT ROWID;

CREATE TABLE clickman_actor_days (
  actor_id integer NOT NULL,
  year integer NOT NULL,
  days varchar(366) NOT NULL,
  PRIMARY KEY (actor_id, year)
) WITHOUT ROWID;

CREATE TABLE clickman_reports (
  key text PRIMARY KEY NOT NULL,
  result json NOT NULL,
  computed_at datetime(6) NOT NULL
);

CREATE TABLE clickman_settings (
  key text PRIMARY KEY NOT NULL,
  value json NOT NULL,
  updated_at datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE clickman_cursors (
  name text PRIMARY KEY NOT NULL,
  received_at datetime(6) NOT NULL,
  message_id text NOT NULL
);
