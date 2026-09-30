# ClickMan for Rails

The Rails engine of ClickMan: it keeps product events column-wise and compressed
in your own database, PostgreSQL or SQLite, computes actives, retention and
funnels in the background, serves the `/analytics` dashboard and forwards
events to destinations. The ingest server that receives the apps' batches is
`clickman-ingest`, built from `../rust`.

The [main README](../README.md) is the integration guide; the wire contract is
[PROTOCOL.md](../docs/PROTOCOL.md) and the tables are [STORAGE.md](../docs/STORAGE.md).

## Install in a Rails application

```ruby
# Gemfile
gem 'clickman', git: 'https://github.com/lockvoid/clickman.git'
```

```sh
bin/rails generate clickman:install --database analytics
bin/rails click_man:install:migrations DATABASE=analytics
bin/rails db:migrate
```

Leave out `--database` and `DATABASE` to keep the tables in the primary database.

## Tests

```sh
bundle exec rake test           # PostgreSQL
bundle exec rake test:sqlite    # SQLite
bundle exec rake e2e            # the Swift, Kotlin and Rust workers through the real ingest server
```
