namespace :clickman do
  desc 'Publish the ingest settings (write keys, sanitizer, limits) to the ClickMan database'
  task publish: :environment do
    ClickMan.publish_settings!
  end

  desc 'Rotate raw events into chunks, prune what is no longer needed and refresh the reports'
  task rotate: :environment do
    puts "rotated #{ClickMan.rotate!} events"
    ClickMan.prune!
    ClickMan.refresh_reports!
  end

  desc 'Forward new events to the configured destinations'
  task deliver: :environment do
    puts "delivered #{ClickMan.deliver!} events"
  end

  desc 'Erase every event of an actor: bin/rails "clickman:erase[42]"'
  task :erase, [:external_id] => :environment do |_task, arguments|
    ClickMan.erase!(arguments.fetch(:external_id))
  end
end
