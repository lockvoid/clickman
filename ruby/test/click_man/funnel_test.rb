require 'test_helper'

module ClickMan
  class FunnelTest < ActiveSupport::TestCase
    NOW = Time.iso8601('2026-09-23T12:00:00Z')

    PURCHASE = {
      'key' => 'purchase',
      'name' => 'Purchase',
      'steps' => [
        { 'event' => %w[paywall_viewed upsell_shown] },
        { 'event' => 'purchase_started' },
        { 'event' => 'purchase_completed', 'where' => { 'store' => 'app_store' } }
      ],
      'window' => '1d',
      'breakdown' => 'context.os.name'
    }.freeze

    def funnel(definition = PURCHASE)
      ClickMan::Funnel.new(definition)
    end

    def compute(definition = PURCHASE)
      ClickMan.rotate!(now: NOW)
      funnel(definition).compute(store: ClickMan.store, now: NOW)
    end

    def ios(**properties)
      { context: { os: { name: 'iOS' } }, properties: properties }
    end

    test 'an actor moves through the steps in order within the window' do
      raw('paywall_viewed', external_id: 'user_1', at: utc('2026-09-22T10:00:00Z'), **ios)
      raw('purchase_started', external_id: 'user_1', at: utc('2026-09-22T10:01:00Z'), **ios)
      raw('purchase_completed', external_id: 'user_1', at: utc('2026-09-22T10:02:30Z'), **ios(store: 'app_store'))

      result = compute

      assert_equal [1, 1, 1], result['steps'].map { it['actors'] }
      assert_equal [nil, 60, 90], result['steps'].map { it['median_seconds'] }
    end

    test 'any of the listed events starts a step' do
      raw('upsell_shown', external_id: 'user_2', at: utc('2026-09-22T10:00:00Z'), **ios)
      raw('purchase_started', external_id: 'user_2', at: utc('2026-09-22T10:05:00Z'), **ios)

      assert_equal [1, 1, 0], compute['steps'].map { it['actors'] }
    end

    test 'steps out of order, past the window or failing a filter do not count' do
      raw('purchase_started', external_id: 'early', at: utc('2026-09-22T09:00:00Z'), **ios)
      raw('paywall_viewed', external_id: 'early', at: utc('2026-09-22T10:00:00Z'), **ios)

      raw('paywall_viewed', external_id: 'slow', at: utc('2026-09-20T10:00:00Z'), **ios)
      raw('purchase_started', external_id: 'slow', at: utc('2026-09-21T10:00:01Z'), **ios)

      raw('paywall_viewed', external_id: 'elsewhere', at: utc('2026-09-22T10:00:00Z'), **ios)
      raw('purchase_started', external_id: 'elsewhere', at: utc('2026-09-22T10:01:00Z'), **ios)
      raw('purchase_completed', external_id: 'elsewhere', at: utc('2026-09-22T10:02:00Z'), **ios(store: 'play_store'))

      assert_equal [3, 1, 0], compute['steps'].map { it['actors'] }
    end

    test 'the anonymous actor never enters' do
      raw('paywall_viewed', external_id: ClickMan::ANONYMOUS, at: utc('2026-09-22T10:00:00Z'))

      assert_equal [0, 0, 0], compute['steps'].map { it['actors'] }
    end

    test 'an actor enters once, on the first step one event in the range' do
      raw('paywall_viewed', external_id: 'user_1', at: utc('2026-09-21T10:00:00Z'), **ios)
      raw('paywall_viewed', external_id: 'user_1', at: utc('2026-09-22T10:00:00Z'), **ios)
      raw('purchase_started', external_id: 'user_1', at: utc('2026-09-22T10:01:00Z'), **ios)

      result = compute

      assert_equal [1, 0, 0], result['steps'].map { it['actors'] }
      assert_equal [['2026-09-21', [1, 0, 0]]], result['days'].map { [it['day'], it['actors']] }
    end

    test 'the breakdown splits by the value at entry' do
      raw('paywall_viewed', external_id: 'user_1', at: utc('2026-09-22T10:00:00Z'), **ios)
      raw('paywall_viewed', external_id: 'user_2', at: utc('2026-09-22T10:00:00Z'), context: { os: { name: 'Android' } })
      raw('purchase_started', external_id: 'user_2', at: utc('2026-09-22T10:01:00Z'))

      breakdown = compute['breakdown'].to_h { [it['value'], it['actors']] }

      assert_equal({ 'iOS' => [1, 0, 0], 'Android' => [1, 1, 0] }, breakdown)
    end

    test 'a definition that breaks the rules is refused with the reason' do
      [
        [PURCHASE.merge('key' => 'Bad Key'), /key/],
        [PURCHASE.merge('steps' => PURCHASE['steps'].first(1)), /2 to 10 steps/],
        [PURCHASE.merge('steps' => [{ 'where' => {} }, { 'event' => 'x' }]), /event/],
        [PURCHASE.merge('window' => '7w'), /window/],
        [PURCHASE.merge('range' => 'forever'), /range/],
        [PURCHASE.except('name'), /name/]
      ].each do |definition, message|
        error = assert_raises(ClickMan::Funnel::Invalid) { ClickMan::Funnel.new(definition) }
        assert_match message, error.message
      end
    end

    test 'funnels load from the json files of a directory' do
      Dir.mktmpdir do |directory|
        File.write(File.join(directory, 'purchase.json'), JSON.generate(PURCHASE))
        File.write(File.join(directory, 'notes.txt'), 'not a funnel')

        funnels = ClickMan::Funnel.load(directory)

        assert_equal ['purchase'], funnels.map(&:key)
      end
    end

    test 'two funnels with one key are refused' do
      Dir.mktmpdir do |directory|
        File.write(File.join(directory, 'a.json'), JSON.generate(PURCHASE))
        File.write(File.join(directory, 'b.json'), JSON.generate(PURCHASE))

        assert_raises(ClickMan::Funnel::Invalid) { ClickMan::Funnel.load(directory) }
      end
    end

    test 'refreshing the reports caches every funnel' do
      raw('paywall_viewed', external_id: 'user_1', at: utc('2026-09-22T10:00:00Z'), **ios)
      ClickMan.rotate!(now: NOW)

      Dir.mktmpdir do |directory|
        File.write(File.join(directory, 'purchase.json'), JSON.generate(PURCHASE))
        ClickMan.configure { it.funnels_path = directory }

        ClickMan.refresh_reports!(now: NOW)
      end

      cached = ClickMan::Report.find('funnel:purchase').result
      assert_equal 'Purchase', cached['name']
      assert_equal [1, 0, 0], cached['steps'].map { it['actors'] }
    end

    test 'a funnel whose file is gone loses its cached report' do
      ClickMan::Report.create!(key: 'funnel:gone', result: {}, computed_at: NOW)

      Dir.mktmpdir do |directory|
        ClickMan.configure { it.funnels_path = directory }
        ClickMan.refresh_reports!(now: NOW)
      end

      assert_nil ClickMan::Report.find_by(key: 'funnel:gone')
    end
  end
end
