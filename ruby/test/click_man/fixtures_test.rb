require 'test_helper'

module ClickMan
  class FixturesTest < ActiveSupport::TestCase
    test 'flattening matches the shared fixtures the ingest server answers to' do
      fixture('flatten.json')['cases'].each do |example|
        assert_equal example['output'], ClickMan::Flatten.call(example['input']), example['name']
      end
    end

    test 'sanitizing matches the shared fixtures the ingest server answers to' do
      sanitize = fixture('sanitize.json')
      sanitizer = ClickMan::Sanitizer.new(sanitize['fragments'])

      sanitize['cases'].each do |example|
        assert_equal example['output'], sanitizer.call(example['input']), example['name']
      end
    end

    test 'the default fragments are the documented ones' do
      assert_equal fixture('sanitize.json')['fragments'], ClickMan::Sanitizer::DEFAULT_FRAGMENTS
    end

    test 'ruby values outside json become strings when flattened' do
      flat = ClickMan::Flatten.call(at: Time.utc(2026, 9, 23, 12, 0, 0), plan: :pro)

      assert_equal({ 'at' => '2026-09-23T12:00:00.000Z', 'plan' => 'pro' }, flat)
    end
  end
end
