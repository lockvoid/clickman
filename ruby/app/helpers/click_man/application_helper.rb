module ClickMan
  module ApplicationHelper
    def count(value)
      value.nil? ? '—' : number_with_delimiter(value)
    end

    def percent(part, whole)
      return '—' if part.nil? || whole.to_i.zero?

      number_to_percentage(part * 100.0 / whole, precision: 1, strip_insignificant_zeros: true)
    end

    def median_time(seconds)
      distance_of_time_in_words(0, seconds, include_seconds: true)
    end

    def bars(values, label:, width: 720, height: 64)
      top = [values.max.to_i, 1].max
      step = width.to_f / [values.size, 1].max

      tag.svg(class: 'bars', viewBox: "0 0 #{width} #{height}", preserveAspectRatio: 'none', role: 'img', aria: { label: label }) do
        safe_join(
          values.each_with_index.map do |value, index|
            bar = (value.to_f / top * height).round(2)
            tag.rect(x: (index * step).round(2), y: (height - bar).round(2), width: (step * 0.75).round(2), height: bar)
          end
        )
      end
    end

    def share_bar(part, whole)
      share = whole.to_i.zero? ? 0 : (part * 100.0 / whole).round(2)

      tag.svg(class: 'share', viewBox: '0 0 100 6', preserveAspectRatio: 'none', aria: { hidden: true }) do
        tag.rect(class: 'track', width: 100, height: 6) + tag.rect(class: 'fill', width: share, height: 6)
      end
    end
  end
end
