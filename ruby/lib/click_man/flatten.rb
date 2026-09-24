require 'json'

module ClickMan
  module Flatten
    MAX_DEPTH = 5
    MAX_STRING_CHARS = 1024

    class << self
      def call(object)
        flat = {}
        walk(object, nil, 1, flat)
        flat
      end

      private

        def walk(object, prefix, depth, flat)
          object.each do |key, value|
            path = prefix ? "#{prefix}.#{key}" : key.to_s

            case value
            when Hash
              if depth < MAX_DEPTH
                walk(value, path, depth + 1, flat)
              else
                flat[path] = JSON.generate(value)
              end
            when Array
              flat[path] = JSON.generate(value)
            when String
              flat[path] = value[0, MAX_STRING_CHARS]
            when Numeric, true, false, nil
              flat[path] = value
            else
              flat[path] = scalar(value)
            end
          end
        end

        def scalar(value)
          text = value.respond_to?(:iso8601) ? value.iso8601(3) : value.to_s
          text[0, MAX_STRING_CHARS]
        end
    end
  end
end
