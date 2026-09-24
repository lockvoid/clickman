require 'test_helper'

module ClickMan
  class DashboardTest < ActionDispatch::IntegrationTest
    NOW = Time.iso8601('2026-09-23T12:00:00Z')
    ADMIN = { 'X-Admin' => 'yes' }.freeze

    PURCHASE = {
      'key' => 'purchase',
      'name' => 'Purchase',
      'steps' => [{ 'event' => 'paywall_viewed' }, { 'event' => 'purchase_completed' }]
    }.freeze

    setup do
      @funnels = Dir.mktmpdir
      File.write(File.join(@funnels, 'purchase.json'), JSON.generate(PURCHASE))
      ClickMan.configure { it.funnels_path = @funnels }
    end

    teardown do
      FileUtils.remove_entry(@funnels)
    end

    def refresh
      raw('paywall_viewed', external_id: 'user_1', at: utc('2026-09-22T10:00:00Z'))
      raw('purchase_completed', external_id: 'user_1', at: utc('2026-09-22T10:05:00Z'))
      raw('paywall_viewed', external_id: 'user_2', at: utc('2026-09-23T10:00:00Z'))
      ClickMan.rotate!(now: NOW)
      ClickMan.refresh_reports!(now: NOW)
    end

    test 'the host controller guards the dashboard' do
      get '/analytics'

      assert_response :forbidden
    end

    test 'the overview shows actives, top events and every funnel' do
      refresh

      get '/analytics', headers: ADMIN

      assert_response :success
      assert_select 'h1', 'Analytics'
      assert_select '[data-metric=dau]', '1'
      assert_select '[data-metric=mau]', '2'
      assert_select 'table.events td', 'paywall_viewed'
      assert_select "a[href='/analytics/funnels/purchase']", 'Purchase'
    end

    test 'a funnel page shows each step with its conversion' do
      refresh

      get '/analytics/funnels/purchase', headers: ADMIN

      assert_response :success
      assert_select 'h1', 'Purchase'
      assert_select '.step', 2
      assert_select '.step:first-child [data-actors]', '2'
      assert_select '.step:last-child [data-actors]', '1'
      assert_select '.step:last-child [data-conversion]', '50%'
    end

    test 'before the first refresh the pages say so instead of failing' do
      get '/analytics', headers: ADMIN
      assert_response :success
      assert_select '.empty', /not computed yet/

      get '/analytics/funnels/purchase', headers: ADMIN
      assert_response :success
      assert_select '.empty', /not computed yet/
    end

    test 'an unknown funnel is not found' do
      get '/analytics/funnels/nope', headers: ADMIN

      assert_response :not_found
    end

    test 'without a base controller the dashboard refuses to open' do
      assert_equal AdminController, ClickMan::ApplicationController.superclass
      ClickMan.configure { it.base_controller_class = nil }

      error = assert_raises(ClickMan::ConfigurationError) { get '/analytics', headers: ADMIN }
      assert_match 'base_controller_class', error.message
    end
  end
end
