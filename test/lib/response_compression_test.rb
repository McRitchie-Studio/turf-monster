require "test_helper"

# [unit] The policy Rack::Deflater runs (lib/response_compression.rb): what it
# compresses, what it skips, and the COMPRESS_RESPONSES switch.
class ResponseCompressionTest < ActiveSupport::TestCase
  BIG = { "content-length" => "4096" }.freeze

  def compress?(type, length: "4096")
    headers = { "content-type" => type }
    headers["content-length"] = length if length
    ResponseCompression.compress?({}, 200, headers, [])
  end

  test "compresses HTML, JSON, CSV, JavaScript and SVG" do
    ["text/html; charset=utf-8", "application/json; charset=utf-8", "text/csv",
     "text/javascript", "image/svg+xml"].each do |type|
      assert compress?(type), "#{type} should compress"
    end
  end

  test "skips a server-sent event stream" do
    refute compress?("text/event-stream")
    refute compress?("text/event-stream; charset=utf-8")
  end

  test "skips images, video and audio, which are already compressed" do
    %w[image/png image/jpeg image/webp image/gif video/mp4 audio/mpeg].each do |type|
      refute compress?(type), "#{type} should be skipped"
    end
  end

  test "skips archives, PDFs, web fonts and opaque binaries" do
    %w[application/zip application/gzip application/pdf font/woff2 font/woff
       application/octet-stream].each do |type|
      refute compress?(type), "#{type} should be skipped"
    end
  end

  test "matches the media type case-insensitively and ignores parameters" do
    refute compress?("Application/PDF; name=x.pdf")
    assert compress?("TEXT/HTML; charset=utf-8")
  end

  test "skips a response with no content type" do
    refute ResponseCompression.compress?({}, 200, BIG.dup, [])
  end

  test "skips a body under MIN_BYTES and compresses one at it" do
    refute compress?("text/html", length: (ResponseCompression::MIN_BYTES - 1).to_s)
    assert compress?("text/html", length: ResponseCompression::MIN_BYTES.to_s)
  end

  test "skips a body of unknown length: a stream or a file" do
    refute compress?("text/html", length: nil)
  end

  # The same two middlewares the initializer installs, around a bare Rack app.
  def through_stack(content_type, body)
    app = ->(_env) { [200, { "content-type" => content_type }, body] }
    stack = Rack::Deflater.new(Rack::ContentLength.new(app), if: ResponseCompression.method(:compress?), sync: false)
    stack.call(Rack::MockRequest.env_for("/", "HTTP_ACCEPT_ENCODING" => "gzip"))
  end

  test "a streamed body (each only, like ActionController::Live) is neither buffered nor compressed" do
    stream = Object.new
    def stream.each = yield("x" * 5_000)

    _status, headers, body = through_stack("text/html", stream)

    assert_nil headers["content-encoding"]
    assert_nil headers["content-length"]
    assert_same stream, body
  end

  test "a buffered event stream is not compressed, a buffered page is" do
    _status, headers, = through_stack("text/event-stream", ["data: x\n\n" * 500])
    assert_nil headers["content-encoding"]

    _status, headers, body = through_stack("text/html", ["<p>hi</p>" * 500])
    assert_equal "gzip", headers["content-encoding"]
    assert_equal "<p>hi</p>" * 500, ActiveSupport::Gzip.decompress(body.to_enum(:each).to_a.join)
  end

  test "is on in production and test, off in development, unless COMPRESS_RESPONSES says otherwise" do
    assert ResponseCompression.enabled?("production", {})
    assert ResponseCompression.enabled?("test", {})
    refute ResponseCompression.enabled?("development", {})

    assert ResponseCompression.enabled?("development", { "COMPRESS_RESPONSES" => "1" })
    refute ResponseCompression.enabled?("production", { "COMPRESS_RESPONSES" => "0" })
    assert ResponseCompression.enabled?("production", { "COMPRESS_RESPONSES" => "" })
  end

  test "sits inside ActionDispatch::Static and outside the Executor, with ContentLength between" do
    stack = Rails.application.middleware.map(&:klass)
    static, deflater, length, executor = [ActionDispatch::Static, Rack::Deflater, Rack::ContentLength,
                                          ActionDispatch::Executor].map { |klass| stack.index(klass) }

    assert deflater, "Rack::Deflater must be in the test stack"
    assert_equal [static + 1, deflater + 1, length + 1], [deflater, length, executor]
  end
end
