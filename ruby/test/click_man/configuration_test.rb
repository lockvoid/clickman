require 'test_helper'

module ClickMan
  class ConfigurationTest < ActiveSupport::TestCase
    test 'the ingest settings carry key digests, fragments, the age limit and the rate' do
      ClickMan.configure do |config|
        config.write_keys = { ios: 'ios-key', android: 'android-key', web: '' }
        config.filter_fragments += %w[price]
        config.max_event_age = 30.days
        config.rate_limit = { per_second: 5, burst: 50 }
      end

      payload = ClickMan::Settings.payload

      assert_equal(
        [
          { 'name' => 'ios', 'digest' => Digest::SHA256.hexdigest('ios-key') },
          { 'name' => 'android', 'digest' => Digest::SHA256.hexdigest('android-key') }
        ],
        payload['writeKeys']
      )
      assert_includes payload['fragments'], 'price'
      assert_includes payload['fragments'], 'passw'
      assert_equal 30, payload['maxEventAgeDays']
      assert_equal({ 'perSecond' => 5.0, 'burst' => 50.0 }, payload['rateLimit'])
    end

    test 'publishing writes the ingest row the server reads' do
      ClickMan.publish_settings!
      ClickMan.publish_settings!

      assert_equal ClickMan::Settings.payload, ClickMan::Setting.find('ingest').value
      assert_equal 1, ClickMan::Setting.count
    end

    test 'nonsense settings are refused at configuration time' do
      [
        -> { it.rate_limit = { per_second: 0, burst: 10 } },
        -> { it.max_event_age = 0 },
        -> { it.dedup_window = -1 },
        -> { it.retention = 0 },
        -> { it.destinations = [Object.new] },
        -> { it.destinations = [RecordingDestination.new, RecordingDestination.new] }
      ].each do |change|
        assert_raises(ClickMan::ConfigurationError) { ClickMan.configure(&change) }
      end
    end

    test 'the store follows the adapter of the ClickMan database' do
      expected = ClickManTestDatabase.postgres? ? ClickMan::Stores::Postgres : ClickMan::Stores::SQLite

      assert_instance_of expected, ClickMan.store
    end

    test 'booting before the ClickMan tables exist publishes nothing and boots' do
      ClickMan::Record.lease_connection.drop_table(:clickman_settings)
      ClickMan::Setting.reset_column_information

      assert_nothing_raised { ClickMan::Settings.publish_on_boot }
    ensure
      ClickMan::Setting.reset_column_information
    end
  end
end
