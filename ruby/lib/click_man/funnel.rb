require 'json'

module ClickMan
  class Funnel
    class Invalid < Error; end

    KEY = /\A[a-z0-9_]+\z/
    DURATION = /\A([1-9][0-9]*)([hd])\z/
    FIELDS = %w[key name steps window range breakdown].freeze
    STEP_FIELDS = %w[event where].freeze
    STEPS = (2..10)
    BREAKDOWN_VALUES = 10

    Step = Data.define(:events, :where) do
      def match?(occurrence)
        events.include?(occurrence.event) && where.all? { |key, values| values.include?(occurrence.fields[key]) }
      end
    end

    class Tally
      attr_reader :reached
      attr_reader :gaps
      attr_reader :days

      def initialize(steps, breakdown)
        @breakdown = breakdown
        @reached = Array.new(steps, 0)
        @gaps = Array.new(steps) { [] }
        @days = Hash.new { |hash, key| hash[key] = Array.new(steps, 0) }
        @values = Hash.new { |hash, key| hash[key] = Array.new(steps, 0) }
      end

      def add(path)
        entry = path.first
        day = Time.at(Rational(entry.at, 1000)).utc.to_date

        path.each_with_index do |occurrence, index|
          @reached[index] += 1
          @days[day][index] += 1
          @values[entry.fields[@breakdown]][index] += 1 if @breakdown
          @gaps[index] << (occurrence.at - path[index - 1].at) / 1000.0 if index.positive?
        end
      end

      def top(limit)
        @values.sort_by { |value, actors| [-actors.first, value.to_s] }.first(limit)
      end
    end
    private_constant :Tally

    attr_reader :key
    attr_reader :name
    attr_reader :steps
    attr_reader :window
    attr_reader :range
    attr_reader :breakdown

    def self.load(directory)
      return [] unless directory && Dir.exist?(directory)

      funnels = Dir[File.join(directory, '*.json')].sort.map do |path|
        new(JSON.parse(File.read(path)))
      rescue JSON::ParserError, Invalid => error
        raise Invalid, "#{path}: #{error.message}"
      end

      duplicate = funnels.map(&:key).tally.find { |_key, count| count > 1 }
      raise Invalid, "two funnels in #{directory} have the key #{duplicate.first}" if duplicate

      funnels
    end

    def initialize(definition)
      raise Invalid, 'a funnel is a JSON object' unless definition.is_a?(Hash)

      unknown = definition.keys - FIELDS
      raise Invalid, "unknown fields: #{unknown.join(', ')}" if unknown.any?

      @key = definition['key']
      raise Invalid, 'key must be lowercase letters, digits and underscores' unless @key.is_a?(String) && KEY.match?(@key)

      @name = definition['name']
      raise Invalid, 'name is required' unless @name.is_a?(String) && @name.strip.present?

      @steps = steps_from(definition['steps'])
      @window = duration(definition.fetch('window', '7d'), 'window')
      @range = duration(definition.fetch('range', '90d'), 'range')

      @breakdown = definition['breakdown']
      raise Invalid, 'breakdown must be a flattened key' unless @breakdown.nil? || (@breakdown.is_a?(String) && @breakdown.present?)
    end

    def compute(store:, now:)
      journeys = Hash.new { |hash, key| hash[key] = [] }
      names = steps.flat_map(&:events).uniq
      store.each_event(names: names, from: (now - range).utc.to_date, to: now.utc.to_date, keys: filter_keys) do |occurrence|
        journeys[occurrence.actor] << occurrence
      end

      tally = Tally.new(steps.size, breakdown)
      journeys.each_value do |occurrences|
        path = walk(occurrences.sort_by.with_index { |occurrence, index| [occurrence.at, index] }, now)
        tally.add(path) if path.any?
      end

      result(tally)
    end

    private

      def steps_from(steps)
        raise Invalid, 'a funnel needs 2 to 10 steps' unless steps.is_a?(Array) && STEPS.cover?(steps.size)

        steps.each_with_index.map { |step, index| step_from(step, index + 1) }
      end

      def step_from(step, number)
        raise Invalid, "step #{number} must be a JSON object" unless step.is_a?(Hash)

        unknown = step.keys - STEP_FIELDS
        raise Invalid, "step #{number} has unknown fields: #{unknown.join(', ')}" if unknown.any?

        events = step['event'].is_a?(Array) ? step['event'] : [step['event']]
        unless events.any? && events.all? { it.is_a?(String) && it.present? }
          raise Invalid, "step #{number} needs an event name or a list of them"
        end

        where = step.fetch('where', {})
        unless where.is_a?(Hash) && where.values.all? { valid_filter?(it) }
          raise Invalid, "step #{number}: where maps flattened keys to a value or a list of values"
        end

        Step.new(events: events, where: where.transform_values { it.is_a?(Array) ? it : [it] })
      end

      def valid_filter?(value)
        return value.any? && value.all? { scalar?(it) } if value.is_a?(Array)

        scalar?(value)
      end

      def scalar?(value)
        value.nil? || value == true || value == false || value.is_a?(String) || value.is_a?(Numeric)
      end

      def duration(text, field)
        match = DURATION.match(text.to_s)
        raise Invalid, "#{field} must look like 12h or 7d" unless match

        match[1].to_i * (match[2] == 'h' ? 1.hour : 1.day)
      end

      def filter_keys
        (steps.flat_map { it.where.keys } + [breakdown]).compact.uniq
      end

      def walk(occurrences, now)
        from = millisecond(now - range)
        to = millisecond(now)
        position = occurrences.index { it.at.between?(from, to) && steps.first.match?(it) }
        return [] unless position

        path = [occurrences[position]]
        deadline = path.first.at + (window.to_i * 1000)

        steps.drop(1).each do |step|
          position = (position + 1...occurrences.size).find { step.match?(occurrences[it]) }
          break if position.nil? || occurrences[position].at > deadline

          path << occurrences[position]
        end

        path
      end

      def result(tally)
        step_results = steps.each_with_index.map do |step, index|
          { 'events' => step.events, 'actors' => tally.reached[index], 'median_seconds' => median(tally.gaps[index]) }
        end

        {
          'key' => key,
          'name' => name,
          'steps' => step_results,
          'days' => tally.days.sort.map { |day, actors| { 'day' => day.iso8601, 'actors' => actors } },
          'breakdown_key' => breakdown,
          'breakdown' => tally.top(BREAKDOWN_VALUES).map { |value, actors| { 'value' => value, 'actors' => actors } }
        }
      end

      def millisecond(time)
        (time.to_r * 1000).floor
      end

      def median(values)
        return if values.empty?

        sorted = values.sort
        middle = sorted.size / 2
        (sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0).round
      end
  end
end
