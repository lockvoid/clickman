require 'net/http'

module ClickMan
  class Transport
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 60

    def call(request)
      uri = URI(request[:url])
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.post(uri.request_uri, request[:body], request[:headers])
      end
      [response.code.to_i, response.body]
    end
  end
end
