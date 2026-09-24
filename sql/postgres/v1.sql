CREATE TABLE clickman_events (
  message_id uuid PRIMARY KEY,
  occurred_at timestamptz NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  external_id text NOT NULL,
  event text NOT NULL,
  properties jsonb NOT NULL DEFAULT '{}',
  context jsonb NOT NULL DEFAULT '{}'
);

CREATE INDEX clickman_events_received ON clickman_events (received_at, message_id);

CREATE TABLE clickman_event_names (
  id serial PRIMARY KEY,
  name text NOT NULL UNIQUE
);

CREATE TABLE clickman_keys (
  id serial PRIMARY KEY,
  key text NOT NULL UNIQUE
);

CREATE TABLE clickman_actors (
  id serial PRIMARY KEY,
  external_id text UNIQUE,
  first_seen_on date NOT NULL,
  erased_at timestamptz,
  CONSTRAINT clickman_actors_erased CHECK ((external_id IS NULL) = (erased_at IS NOT NULL))
);

CREATE TABLE clickman_chunks (
  day date NOT NULL,
  event_name_id integer NOT NULL,
  seq integer NOT NULL,
  events integer NOT NULL,
  key_ids integer[] NOT NULL,
  payload bytea NOT NULL,
  PRIMARY KEY (day, event_name_id, seq)
) PARTITION BY RANGE (day);

-- The payload is compressed already; Postgres must not try again.
ALTER TABLE clickman_chunks ALTER COLUMN payload SET STORAGE EXTERNAL;

CREATE TABLE clickman_daily_counts (
  day date NOT NULL,
  event_name_id integer NOT NULL,
  events integer NOT NULL,
  actors integer NOT NULL,
  PRIMARY KEY (day, event_name_id)
);

CREATE TABLE clickman_actor_days (
  actor_id integer NOT NULL,
  year smallint NOT NULL,
  days bit varying(366) NOT NULL,
  PRIMARY KEY (actor_id, year)
);

CREATE TABLE clickman_reports (
  key text PRIMARY KEY,
  result jsonb NOT NULL,
  computed_at timestamptz NOT NULL
);

CREATE TABLE clickman_settings (
  key text PRIMARY KEY,
  value jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE clickman_cursors (
  name text PRIMARY KEY,
  received_at timestamptz NOT NULL,
  message_id uuid NOT NULL
);
