# frozen_string_literal: true

require "tmpdir"

# PrivatePublicRoot: a throwaway public/ for a test that needs ActionDispatch::Static
# to serve a file it wrote (task turf-asset-test-stops-racing).
#
# Tests used to drop probe files under the app's real public/assets, creating the
# directory when absent and removing it when empty. CI runs the suite in parallel
# worker processes, and two workers that both found public/assets absent each
# owned its removal: one worker's teardown rmdir'd it between another's mkdir_p of
# the parent and of its probe directory (Errno::ENOENT at
# precompressed_asset_serving_test.rb:30, turf PR #1024's first CI run). A
# Dir.mktmpdir per test is visible to no other worker, so nothing under the shared
# public/ is created or deleted.
#
# Include it, call #private_public_root in setup and #remove_private_public_root
# in teardown, then serve through #app_stack_serving_private_root: the app's own
# middleware stack, in the app's order, with only Static's root swapped.
module PrivatePublicRoot
  def private_public_root
    @private_public_root ||= Pathname(Dir.mktmpdir("private-public-root"))
  end

  def remove_private_public_root
    FileUtils.rm_r(@private_public_root) if @private_public_root
    @private_public_root = nil
  end

  # Rails.application.middleware built as Rails builds it (MiddlewareStack#build
  # over the routes), with ActionDispatch::Static re-created on the private root
  # and its configured options (index, headers) kept. Every other middleware,
  # DigestedAssetCache outside Static and Propshaft::Server and Rack::Deflater
  # inside it, is the app's own.
  def app_stack_serving_private_root
    static = Rails.application.middleware.middlewares.find { |m| m.klass == ActionDispatch::Static }
    raise "the app's middleware stack carries no ActionDispatch::Static" unless static

    _root, options = static.args
    stack = Rails.application.middleware.dup
    stack.swap(ActionDispatch::Static, ActionDispatch::Static, private_public_root.to_s, **options)
    stack.build(Rails.application.routes)
  end

  # Calls a Rack stack for +path+ and returns [status, headers, binary body].
  def call_rack_stack(stack, path, headers = {})
    env = Rack::MockRequest.env_for(path, headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" })
    status, response_headers, body = stack.call(env)
    chunks = +"".b
    body.each { |chunk| chunks << chunk.b }
    body.close if body.respond_to?(:close)
    [status.to_i, response_headers, chunks]
  end
end
