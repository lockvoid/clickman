require 'test_helper'

module ClickMan
  class TrackTest < ActiveSupport::TestCase
    test 'a server-side event is stored flattened and sanitized' do
      at = utc('2026-09-23T10:00:00Z')

      assert ClickMan.track(
        'subscription_started',
        external_id: 42,
        properties: { plan: 'pro', store: { name: 'app_store' }, email: 'a@b.co' },
        context: { app: { version: '1.40' } },
        at: at
      )

      event = ClickMan::Event.sole
      assert_equal 'subscription_started', event.event
      assert_equal '42', event.external_id
      assert_equal at, event.occurred_at
      assert_equal({ 'plan' => 'pro', 'store.name' => 'app_store', 'email' => '[FILTERED]' }, event.properties)
      assert_equal({ 'app.version' => '1.40' }, event.context)
    end

    test 'the host fragments filter server-side events too' do
      ClickMan.configure { it.filter_fragments += %w[price] }

      ClickMan.track('purchase_completed', external_id: 'user_1', properties: { price: 9.99 })

      assert_equal({ 'price' => '[FILTERED]' }, ClickMan::Event.sole.properties)
    end

    test 'a failure to store never reaches the caller' do
      store = ClickMan.method(:store)
      ClickMan.singleton_class.remove_method(:store)
      ClickMan.define_singleton_method(:store) do
        raise ActiveRecord::ConnectionNotEstablished, 'the analytics database is down'
      end

      assert_error_reported(ActiveRecord::ConnectionNotEstablished) do
        assert_equal false, ClickMan.track('anything', external_id: 'user_1')
      end
    ensure
      ClickMan.singleton_class.remove_method(:store)
      ClickMan.define_singleton_method(:store, store)
    end
  end
end
