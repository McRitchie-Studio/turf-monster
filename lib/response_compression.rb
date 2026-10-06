# Gzip for HTML and JSON responses: the policy Rack::Deflater runs, and where
# it sits in the stack. config/initializers/response_compression.rb installs it.
#
# Why the app does it. Production is served by the Heroku router directly:
# turfmonster.media's records are DNS-only at Cloudflare (no cf-ray, no proxy),
# and the router never compresses. /turf-monster-v2 measured 1,039,913 bytes on
# the wire with no Content-Encoding on 2026-10-06.
#
# Where it sits. Directly inside ActionDispatch::Static, outside the Executor:
#
#   Rack::Sendfile → ActionDispatch::Static → Rack::Deflater → Rack::ContentLength
#     → ActionDispatch::Executor → … → Rack::ConditionalGet → Rack::ETag → … → app
#
#   * Static answers precompiled assets before reaching Deflater. Sprockets
#     writes a .gz beside each asset and Static serves it with
#     Content-Encoding: gzip already, so assets are never compressed twice
#     (Deflater also skips any response that already carries a Content-Encoding).
#   * ETag and ConditionalGet run inside, on the identity body. The weak ETag is
#     the same for both encodings, which a weak validator allows, and a 304
#     carries no body, so Deflater leaves it alone.
#   * Rack::ContentLength turns a buffered body into an Array and stamps its
#     length, so the policy below can read the size without consuming the body
#     itself. It only touches a body that responds to #to_ary: a streamed
#     ActionController::Live body (a Queue) and a send_file body (#to_path) do
#     not, so neither is buffered and neither is compressed.
#
# Switch. On in production and test; off in development. COMPRESS_RESPONSES=1
# turns it on anywhere, COMPRESS_RESPONSES=0 off anywhere: setting it to 0 on a
# Heroku app is the rollback, with no deploy.
module ResponseCompression
  # Below this, gzip's ~20-byte frame and the CPU are not worth it.
  MIN_BYTES = 1024

  # Already compressed, or a stream that must reach the client unbuffered.
  # image/svg+xml is text and stays compressible.
  SKIPPED_TYPES = %w[
    text/event-stream
    application/octet-stream
    application/pdf
    application/zip
    application/gzip
    application/x-gzip
    application/x-bzip2
    application/x-xz
    application/x-7z-compressed
    application/x-rar-compressed
    application/zstd
    font/woff
    font/woff2
  ].freeze
  SKIPPED_FAMILIES = %w[image/ video/ audio/].freeze
  COMPRESSIBLE_IMAGES = %w[image/svg+xml].freeze

  module_function

  def enabled?(env_name, env = ENV)
    case env.fetch("COMPRESS_RESPONSES", "").strip
    when "1" then true
    when "0" then false
    else %w[production test].include?(env_name.to_s)
    end
  end

  # Rack::Deflater's :if option: called as (env, status, headers, body).
  def compress?(_env, _status, headers, _body)
    compressible_type?(headers["content-type"]) && large_enough?(headers)
  end

  def compressible_type?(content_type)
    media_type = content_type.to_s.split(";").first.to_s.strip.downcase
    return false if media_type.empty?
    return true if COMPRESSIBLE_IMAGES.include?(media_type)
    return false if SKIPPED_TYPES.include?(media_type)

    SKIPPED_FAMILIES.none? { |family| media_type.start_with?(family) }
  end

  # A body of unknown length is a stream or a file (see the header): skip it.
  def large_enough?(headers)
    length = headers["content-length"]
    return false if length.nil?

    length.to_i >= MIN_BYTES
  end
end
