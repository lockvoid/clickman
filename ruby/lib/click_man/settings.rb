require 'digest'

module ClickMan
  module Settings
    KEY = 'ingest'.freeze

    class << self
      def payload(configuration = ClickMan.configuration)
        {
          'writeKeys' => configuration.write_keys.filter_map do |name, key|
            { 'name' => name.to_s, 'digest' => Digest::SHA256.hexdigest(key) } if key.present?
          end,
          'fragments' => configuration.filter_fragments.map(&:to_s),
          'maxEventAgeDays' => (configuration.max_event_age / 1.day).to_i,
          'rateLimit' => {
            'perSecond' => configuration.rate_limit[:per_second].to_f,
            'burst' => configuration.rate_limit[:burst].to_f
          }
        }
      end

      def publish!(configuration = ClickMan.configuration)
        Setting.upsert({ key: KEY, value: payload(configuration), updated_at: Time.current }, unique_by: :key)
      end

      # Assets precompiling or a first migration boots without the ClickMan
      # tables; publishing then waits for the next boot or `clickman:publish`.
      def publish_on_boot
        if Setting.table_exists?
          publish!
        else
          Rails.logger.info('[clickman] ingest settings not published at boot: the ClickMan tables are not migrated yet')
        end
      rescue ActiveRecord::ActiveRecordError => error
        Rails.logger.info("[clickman] ingest settings not published at boot: #{error.message}")
      end
    end
  end
end
