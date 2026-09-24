require 'test_helper'
require 'open3'

module ClickMan
  class LoadingTest < ActiveSupport::TestCase
    test 'the engine loads with Bundler even when a Puma plugin required ClickMan before Rails' do
      script = <<~RUBY
        require 'click_man'
        require 'rails'
        require 'clickman'
        print defined?(ClickMan::Engine).inspect
      RUBY

      output, status = Open3.capture2e(Gem.ruby, '-I', File.expand_path('../../lib', __dir__), '-e', script)

      assert status.success?, output
      assert_equal '"constant"', output.lines.last
    end
  end
end
