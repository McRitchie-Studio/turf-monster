# Gzip HTML and JSON responses. Placement, skip list and the
# COMPRESS_RESPONSES switch are explained in lib/response_compression.rb.
require_relative "../../lib/response_compression"

if ResponseCompression.enabled?(Rails.env)
  Rails.application.config.middleware.insert_before ActionDispatch::Executor, Rack::Deflater,
                                                    if: ResponseCompression.method(:compress?), sync: false
  Rails.application.config.middleware.insert_before ActionDispatch::Executor, Rack::ContentLength
end
