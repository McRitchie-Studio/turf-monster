# The ES modules a rendered page loads, read the way a browser reads them: the
# page's importmap, the modules its <script type="module"> tags import, and
# every module those import statically, each fetched from this app.
#
#   get admin_nfl_week_path(slot)
#   html = response.body
#   assert_includes page_modules(html), "application"
#   assert_includes page_modules(html, from: "studio/application"), "studio/board"
#
# `from:` names one module the page itself must import, and walks from there
# alone: the modules that one import brings in.
#
# page_modules fails on an import the importmap does not pin and on a pinned
# module this app does not serve: in a browser either one stops the whole graph
# from running. It leaves `response` on the last module fetched, so keep the
# page's HTML in a local before calling it.
module PageModuleGraph
  STATIC_IMPORT = /
    (?:^|;)\s*
    (?:import|export)\b
    (?:[^;"'()]*?\bfrom)?
    \s*["']([^"']+)["']
  /mx

  def page_importmap(html)
    tag = Nokogiri::HTML(html).at_css('script[type="importmap"]')
    assert tag, "the page carries no importmap"
    JSON.parse(tag.text).fetch("imports")
  end

  # Every specifier reachable from the page's module tags, or from the one
  # named `from`.
  def page_modules(html, from: nil)
    imports = page_importmap(html)
    entries = Nokogiri::HTML(html).css('script[type="module"]').flat_map { |tag| static_imports(tag.text) }
    assert entries.any?, "the page imports no module"
    if from
      assert_includes entries, from, "no module tag on the page imports #{from.inspect}"
      entries = [ from ]
    end

    seen = []
    queue = entries.map { |name| [ name, "the page" ] }
    until queue.empty?
      name, importer = queue.shift
      next if seen.include?(name)

      seen << name
      url = imports[name]
      assert url, "#{importer} imports #{name.inspect}, which the page's importmap does not pin"
      next unless url.start_with?("/")

      get url
      assert_response :success, "#{name} is pinned to #{url}, which this app does not serve"
      queue.concat(static_imports(response.body).map { |child| [ child, name ] })
    end
    seen
  end

  private

  def static_imports(javascript)
    code = javascript.gsub(%r{/\*.*?\*/}m, "").gsub(%r{^\s*//.*$}, "")
    code.scan(STATIC_IMPORT).flatten.uniq
  end
end
