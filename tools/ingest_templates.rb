#!/usr/bin/env ruby
# The databases the ingest server tests copy, built by the migration hosts run: BUNDLE_GEMFILE=ruby/Gemfile.

require 'active_record'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
MIGRATIONS = File.join(ROOT, 'ruby/db/migrate')
POSTGRES_TEMPLATE = ENV.fetch('CLICKMAN_INGEST_TEMPLATE', 'clickman_ingest_template')
SQLITE_TEMPLATE = ENV.fetch('CLICKMAN_INGEST_SQLITE_TEMPLATE', File.join(ROOT, 'tmp/clickman_ingest_template.sqlite3'))

def migrate(config)
  ActiveRecord::Base.establish_connection(config)
  ActiveRecord::Migration.suppress_messages { ActiveRecord::MigrationContext.new([MIGRATIONS]).migrate }
  ActiveRecord::Base.connection_handler.clear_all_connections!
end

def postgres(database)
  { adapter: 'postgresql', database: database, host: ENV.fetch('PGHOST', 'localhost'), username: ENV.fetch('PGUSER', ENV.fetch('USER')) }
end

def prepare_postgres
  ActiveRecord::Base.establish_connection(postgres('postgres'))
  ActiveRecord::Base.connection.execute("DROP DATABASE IF EXISTS #{POSTGRES_TEMPLATE} WITH (FORCE)")
  ActiveRecord::Base.connection.execute("CREATE DATABASE #{POSTGRES_TEMPLATE}")
  migrate(postgres(POSTGRES_TEMPLATE))
end

def prepare_sqlite
  FileUtils.mkdir_p(File.dirname(SQLITE_TEMPLATE))
  FileUtils.rm_f(Dir["#{SQLITE_TEMPLATE}*"])
  migrate(adapter: 'sqlite3', database: SQLITE_TEMPLATE)
end

prepare_postgres
prepare_sqlite
puts "ingest templates: #{POSTGRES_TEMPLATE}, #{SQLITE_TEMPLATE}"
