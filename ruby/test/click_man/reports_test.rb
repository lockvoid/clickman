require 'test_helper'

module ClickMan
  class ReportsTest < ActiveSupport::TestCase
    NOW = Time.iso8601('2026-09-23T12:00:00Z')

    def active(external_id, *days)
      days.each { raw('app_opened', external_id: external_id, at: utc("#{it}T10:00:00Z")) }
    end

    def refresh
      ClickMan.rotate!(now: NOW)
      ClickMan.refresh_reports!(now: NOW)
    end

    def report(key)
      ClickMan::Report.find(key).result
    end

    test 'daily, weekly and monthly actives count identified actors in their windows' do
      active('user_1', '2026-09-23')
      active('user_2', '2026-09-20', '2026-09-23')
      active('user_3', '2026-09-10')
      active('user_4', '2025-12-31')
      active(ClickMan::ANONYMOUS, '2026-09-23')

      refresh

      today = report('actives')['days'].find { it['day'] == '2026-09-23' }
      assert_equal({ 'day' => '2026-09-23', 'dau' => 2, 'wau' => 2, 'mau' => 3 }, today)
      new_year = report('actives')['days'].find { it['day'] == '2026-01-05' }
      assert_nil new_year, 'the series covers the last 90 days'
    end

    test 'actives look across the new year' do
      active('user_1', '2025-12-30')
      ClickMan.rotate!(now: NOW)

      ClickMan.refresh_reports!(now: Time.iso8601('2026-01-02T12:00:00Z'))

      first = report('actives')['days'].find { it['day'] == '2026-01-02' }
      assert_equal({ 'day' => '2026-01-02', 'dau' => 0, 'wau' => 1, 'mau' => 1 }, first)
    end

    test 'retention follows each cohort to its first, seventh and thirtieth day' do
      active('user_1', '2026-08-01', '2026-08-02', '2026-08-31')
      active('user_2', '2026-08-01', '2026-08-08')
      active('user_3', '2026-08-01')
      active('user_4', '2026-09-22')

      refresh

      cohorts = report('retention')['cohorts'].index_by { it['day'] }
      assert_equal({ 'day' => '2026-08-01', 'size' => 3, 'd1' => 1, 'd7' => 1, 'd30' => 1 }, cohorts['2026-08-01'])
      assert_equal(
        { 'day' => '2026-09-22', 'size' => 1, 'd1' => 0, 'd7' => nil, 'd30' => nil },
        cohorts['2026-09-22'],
        'a day that has not come yet is nil, not zero'
      )
    end

    test 'the events report ranks the last thirty days' do
      active('user_1', '2026-09-20', '2026-09-21')
      raw('export_completed', external_id: 'user_1', at: utc('2026-09-21T11:00:00Z'))
      raw('ancient', external_id: 'user_1', at: utc('2026-07-01T11:00:00Z'))

      refresh

      events = report('events')['events']
      assert_equal [['app_opened', 2, 1], ['export_completed', 1, 1]], events.map { [it['event'], it['events'], it['actors']] }
    end
  end
end
