class CreateClickManTables < ActiveRecord::Migration[8.0]
  def change
    create_events
    create_dictionaries
    create_chunks
    create_daily_counts
    create_actor_days
    create_bookkeeping
  end

  private

    def create_events
      create_table :clickman_events, id: false do |t|
        t.column :message_id, uuid, null: false, primary_key: true
        t.column :occurred_at, time, null: false
        t.column :received_at, time, null: false, **received_default
        t.text :external_id, null: false
        t.text :event, null: false
        t.column :properties, json, null: false, default: {}
        t.column :context, json, null: false, default: {}
        t.index %i[received_at message_id], name: 'clickman_events_received'
      end
    end

    def create_dictionaries
      create_table :clickman_event_names, id: dictionary_id do |t|
        t.text :name, null: false
        unique t, :name
      end
      create_table :clickman_keys, id: dictionary_id do |t|
        t.text :key, null: false
        unique t, :key
      end
      create_actors
    end

    def create_actors
      create_table :clickman_actors, id: dictionary_id do |t|
        t.text :external_id
        t.date :first_seen_on, null: false
        t.column :erased_at, time
        t.check_constraint '(external_id IS NULL) = (erased_at IS NOT NULL)', name: 'clickman_actors_erased'
        unique t, :external_id
      end
    end

    def create_chunks
      create_table :clickman_chunks, primary_key: %i[day event_name_id seq], options: chunk_options do |t|
        t.date :day, null: false
        t.integer :event_name_id, null: false
        t.integer :seq, null: false
        t.integer :events, null: false
        key_ids t
        t.binary :payload, null: false
      end
      store_payloads_as_they_are
    end

    def create_daily_counts
      create_table :clickman_daily_counts, primary_key: %i[day event_name_id], options: without_rowid do |t|
        t.date :day, null: false
        t.integer :event_name_id, null: false
        t.integer :events, null: false
        t.integer :actors, null: false
      end
    end

    def create_actor_days
      create_table :clickman_actor_days, primary_key: %i[actor_id year], options: without_rowid do |t|
        t.integer :actor_id, null: false
        t.integer :year, null: false, limit: year_limit
        days t
      end
    end

    def create_bookkeeping
      create_table :clickman_reports, id: :text, primary_key: :key do |t|
        t.column :result, json, null: false
        t.column :computed_at, time, null: false
      end
      create_table :clickman_settings, id: :text, primary_key: :key do |t|
        t.column :value, json, null: false
        t.column :updated_at, time, null: false, default: -> { now }
      end
      create_table :clickman_cursors, id: :text, primary_key: :name do |t|
        t.column :received_at, time, null: false
        t.column :message_id, uuid, null: false
      end
    end

    def unique(table, column)
      if postgres?
        table.unique_constraint column, name: "#{table.name}_#{column}_key"
      else
        table.index column, unique: true, name: "#{table.name}_#{column}"
      end
    end

    def store_payloads_as_they_are
      return unless postgres?

      reversible do |direction|
        direction.up { execute 'ALTER TABLE clickman_chunks ALTER COLUMN payload SET STORAGE EXTERNAL' }
      end
    end

    def postgres?
      connection.adapter_name == 'PostgreSQL'
    end

    def uuid
      postgres? ? :uuid : :text
    end

    def time
      postgres? ? :timestamptz : :datetime
    end

    def json
      postgres? ? :jsonb : :json
    end

    def now
      postgres? ? 'now()' : 'CURRENT_TIMESTAMP'
    end

    def received_default
      postgres? ? { default: -> { 'now()' } } : {}
    end

    def dictionary_id
      postgres? ? :serial : :primary_key
    end

    def chunk_options
      postgres? ? 'PARTITION BY RANGE (day)' : 'WITHOUT ROWID'
    end

    def without_rowid
      postgres? ? nil : 'WITHOUT ROWID'
    end

    def year_limit
      2 if postgres?
    end

    def key_ids(table)
      if postgres?
        table.integer :key_ids, array: true, null: false
      else
        table.json :key_ids, null: false
      end
    end

    def days(table)
      if postgres?
        table.bit_varying :days, limit: 366, null: false
      else
        table.string :days, limit: 366, null: false
      end
    end
end
