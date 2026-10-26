# frozen_string_literal: true

require "zlib"

# PrecompressedAssets: a .gz beside every digested stylesheet and script, so
# ActionDispatch::Static keeps serving them pre-encoded.
#
# Sprockets wrote a .gz beside each asset itself. Propshaft writes none, and
# without one Static serves the identity file. Static sits OUTSIDE Rack::Deflater
# (lib/response_compression.rb) and answers without calling inward, so Deflater
# never sees an asset: with no .gz, every stylesheet and script would go out
# uncompressed (tailwind.css is 180 KB identity, 31 KB gzipped).
# lib/tasks/precompressed_assets.rake runs #write after assets:precompile and
# #prune after assets:clean. Static then finds <file>.gz for a client that sends
# Accept-Encoding: gzip and answers with Content-Encoding: gzip.
#
# gzip only, as Sprockets did: the bundle carries no brotli encoder, and Static
# looks for .br first only when one exists.
module PrecompressedAssets
  # A digested stylesheet or script: a Propshaft digest (8 hex,
  # Propshaft::Asset#digest) or a pre-digested bundler output
  # (name-<digest>.digested.js) just before a .css or .js extension. Only those
  # are worth it: images are already compressed, and fonts are woff2.
  DIGESTED = /-(?:[0-9a-f]{8}|[0-9a-zA-Z_-]{7,128}\.digested)\.(?:css|js)\z/

  module_function

  # Writes <file>.gz for each digested css/js under +root+ that lacks a current
  # one. Returns the files written.
  def write(root)
    candidates(root).filter_map do |path|
      gz = "#{path}.gz"
      next if File.exist?(gz) && File.mtime(gz) >= File.mtime(path)

      Zlib::GzipWriter.open(gz, Zlib::BEST_COMPRESSION) do |out|
        out.mtime = File.mtime(path).to_i
        out.orig_name = File.basename(path)
        out.write(File.binread(path))
      end
      gz
    end
  end

  # Deletes each .gz whose source is gone (assets:clean removed an old digest,
  # and Propshaft's clean cannot parse a digest out of a .css.gz name, so it
  # never removes one itself). Returns the files removed.
  def prune(root)
    Dir.glob(File.join(root.to_s, "**", "*.gz")).reject { |gz| File.exist?(gz.delete_suffix(".gz")) }.each do |gz|
      File.delete(gz)
    end
  end

  def candidates(root)
    Dir.glob(File.join(root.to_s, "**", "*")).select do |path|
      File.file?(path) && DIGESTED.match?(File.basename(path))
    end
  end
end
