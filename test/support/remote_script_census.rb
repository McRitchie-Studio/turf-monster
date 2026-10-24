# Every remote script the app's source can load, read from the files: a static
# <script src="https://..."> or javascript_include_tag "https://..." in a view,
# and a script element whose .src is assigned an https:// literal (a dynamic
# insertion) in a view or in JavaScript. Comments are taken out first, as
# test/views/alpine_and_inline_script_ratchet_test.rb does, so a tag quoted in
# prose is not counted.
#
# Read by test/integration/app_script_src_test.rb (every load is named in the
# app policy's script-src) and test/views/remote_script_integrity_ceiling_test.rb
# (none loads without integrity).
#
# Knowingly not seen: a URL assembled at run time (tokens/_paypal_sdk builds
# the PayPal SDK URL in Ruby and assigns it with to_json; the integration test
# reads that one from the rendered page instead).
module RemoteScriptCensus
  Load = Struct.new(:file, :url, :integrity, :context, keyword_init: true)

  COMMENTS = {
    ".erb" => [ /<%#.*?%>/m, /<!--.*?-->/m, %r{^\s*//.*$} ],
    ".js" => [ %r{^\s*(?://|/\*|\*).*$} ]
  }.freeze

  STATIC_TAG = %r{<script\b((?:<%.*?%>|[^>])*?\bsrc\s*=\s*["'](https://[^"']+)["'](?:<%.*?%>|[^>])*)>}mi
  INCLUDE_TAG = %r{javascript_include_tag\s*\(?\s*["'](https://[^"']+)["']([^%]*)%>}
  DYNAMIC_SRC = %r{\.src\s*=\s*["'](https://[^"']+)["']}
  # A dynamic insertion's integrity is the next statements on the same element.
  DYNAMIC_WINDOW = 400

  def self.app_files(root = Rails.root)
    Dir.glob(root.join("app/views/**/*.erb").to_s) + Dir.glob(root.join("app/javascript/**/*.js").to_s)
  end

  # The views of the gems whose partials the app renders (studio-engine's
  # cropper and head, solana-studio's deep-link assets).
  def self.gem_files
    %w[studio-engine solana-studio].flat_map do |name|
      Dir.glob(File.join(Gem.loaded_specs.fetch(name).full_gem_path, "app/views/**/*.erb"))
    end
  end

  def self.scan(source, extension, file = "(source)")
    code = COMMENTS.fetch(extension).reduce(source) { |text, comment| text.gsub(comment, "") }
    loads = []
    if extension == ".erb"
      code.scan(STATIC_TAG) { |attributes, url| loads << Load.new(file:, url:, integrity: attributes.match?(/\bintegrity\s*=/), context: $~.pre_match[-200..] || $~.pre_match) }
      code.scan(INCLUDE_TAG) { |url, options| loads << Load.new(file:, url:, integrity: options.include?("integrity"), context: $~.pre_match[-200..] || $~.pre_match) }
    end
    code.to_enum(:scan, DYNAMIC_SRC).each do
      match = Regexp.last_match
      after = code[match.end(0), DYNAMIC_WINDOW]
      loads << Load.new(file:, url: match[1], integrity: after.match?(/\.integrity\s*=\s*["']sha(?:256|384|512)-/), context: match.pre_match[-200..] || match.pre_match)
    end
    loads
  end

  def self.loads(files)
    files.flat_map { |file| scan(File.read(file), File.extname(file), file) }
  end
end
