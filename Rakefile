require 'rake/testtask'

Rake::TestTask.new(:test) do |task|
  task.libs << 'ruby/test'
  task.libs << 'ruby/lib'
  task.test_files = FileList['ruby/test/**/*_test.rb'].exclude('ruby/test/e2e/**/*')
end

namespace :test do
  task :sqlite do
    ENV['CLICKMAN_TEST_ADAPTER'] = 'sqlite'
    Rake::Task[:test].invoke
  end
end

namespace :e2e do
  task :sqlite do
    ENV['CLICKMAN_TEST_ADAPTER'] = 'sqlite'
    Rake::Task[:e2e].invoke
  end
end

Rake::TestTask.new(:e2e) do |task|
  task.libs << 'ruby/test'
  task.libs << 'ruby/lib'
  task.pattern = 'ruby/test/e2e/**/*_test.rb'
end

task :ingest_binary do
  sh 'cargo build --locked --package clickman-ingest'
  ENV['CLICKMAN_INGEST_BINARY'] = File.expand_path('target/debug/clickman-ingest', __dir__)
end

task :client_libraries do
  sh 'scripts/build-xcframework.sh'
  sh 'kotlin/build.sh host'
end

task e2e: %i[ingest_binary client_libraries]
task default: :test
