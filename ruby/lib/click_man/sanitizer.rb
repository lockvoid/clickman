module ClickMan
  class Sanitizer
    FILTERED = '[FILTERED]'.freeze

    DEFAULT_FRAGMENTS = %w[
      passw
      email
      secret
      token
      _key
      crypt
      salt
      certificate
      otp
      ssn
      cvv
      cvc
      phone
      address
      first_name
      last_name
      full_name
      birth
    ].freeze

    EMAIL = /[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}/i
    CARD_DIGITS = (13..19)
    PHONE_DIGITS = (10..15)
    CARD_SEPARATORS = [' ', '-'].freeze
    PHONE_SEPARATORS = [' ', '-', '.', '(', ')'].freeze

    def initialize(fragments = DEFAULT_FRAGMENTS)
      @fragments = fragments.map { it.to_s.downcase }
    end

    def call(flat)
      flat.to_h do |key, value|
        sensitive = filtered_key?(key) || (value.is_a?(String) && sensitive_text?(value))
        [key, sensitive ? FILTERED : value]
      end
    end

    private

      def filtered_key?(key)
        last = key.to_s.rpartition('.').last.downcase
        @fragments.any? { last.include?(it) }
      end

      def sensitive_text?(text)
        EMAIL.match?(text) || card?(text.chars) || phone?(text.chars)
      end

      def card?(chars)
        chars.each_index.any? do |start|
          next false unless digit?(chars[start]) && detached_before?(chars, start)

          digits, finish = card_digits(chars, start)
          detached_after?(chars, finish) &&
            CARD_DIGITS.cover?(digits.size) &&
            ('2'..'6').cover?(digits.first) &&
            luhn?(digits)
        end
      end

      def card_digits(chars, start)
        digits = []
        index = start

        while index < chars.size
          if digit?(chars[index])
            digits << chars[index]
            index += 1
          elsif CARD_SEPARATORS.include?(chars[index]) && digit?(chars[index + 1])
            index += 1
          else
            break
          end
        end

        [digits, index]
      end

      def luhn?(digits)
        sum = digits.reverse.each_with_index.sum do |digit, position|
          value = digit.to_i
          next value if position.even?

          doubled = value * 2
          doubled > 9 ? doubled - 9 : doubled
        end

        (sum % 10).zero?
      end

      def phone?(chars)
        chars.each_index.any? do |start|
          next false unless chars[start] == '+' && detached_before?(chars, start) && digit?(chars[start + 1])

          digits, finish = phone_digits(chars, start + 1)
          PHONE_DIGITS.cover?(digits) && detached_after?(chars, finish)
        end
      end

      def phone_digits(chars, start)
        digits = 0
        finish = start

        chars[start..].each.with_index(start) do |char, index|
          if digit?(char)
            digits += 1
            finish = index + 1
          elsif !PHONE_SEPARATORS.include?(char)
            break
          end
        end

        [digits, finish]
      end

      def detached_before?(chars, start)
        start.zero? || !alphanumeric?(chars[start - 1])
      end

      def detached_after?(chars, finish)
        finish >= chars.size || !alphanumeric?(chars[finish])
      end

      def digit?(char)
        char&.match?(/\A[0-9]\z/)
      end

      def alphanumeric?(char)
        char.match?(/\A[[:alnum:]]\z/)
      end
  end
end
