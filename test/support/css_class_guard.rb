# A class name that no stylesheet defines paints NOTHING, and nothing else in
# the suite can see that. It is not a Ruby error, not an ERB error, not a failed
# request spec, not a broken link. The page returns 200 and the tests stay
# green. `input input-bordered` shipped on the /admin/authorities slot fields
# and on both vault-authority pages for the whole life of those pages —
# NEITHER class exists in this app; the engine's field primitive is
# `input-field`. Those fields rendered as bare unstyled text.
#
# This module is the one place that answers "does the stylesheet define this
# name?", so a hole in the answer is closed once rather than per call site.
module CssClassGuard
  # Tailwind compiles here, and CI builds it before the suite runs
  # (.github/workflows/ci.yml) for exactly this class of test.
  COMPILED_CSS = Rails.root.join("app/assets/builds/tailwind.css").freeze

  # Characters that CONTINUE a CSS identifier. A class selector ends only at a
  # character outside this set. The backslash is in it because an escape is
  # part of the name it sits in: `.p-1\.5` is the class `p-1.5`, NOT `p-1`.
  IDENT_CHAR = /[A-Za-z0-9_\\-]/

  class << self
    def stylesheet
      @stylesheet ||= begin
        raise "#{COMPILED_CSS} is missing — run `bin/rails tailwindcss:build` " \
              "before this suite, or these guards cannot see anything" unless COMPILED_CSS.exist?
        COMPILED_CSS.read
      end
    end

    # The CSS SOURCE form of a class name. Tailwind escapes every character
    # that cannot appear raw in an identifier, so `md:flex` is written
    # `.md\:flex` and `w-1/2` is written `.w-1\/2`.
    def css_escape(name)
      name.gsub(/[^A-Za-z0-9_-]/) { |c| "\\#{c}" }
    end

    # WHY THIS IS A REGEX AND NOT `css.include?(".#{name}")`.
    #
    # A plain substring match reports a PREFIX of a real class as defined,
    # because `.text-danger` is a substring of `.text-danger-ink`. Measured on
    # the shipped guard (PR 726): `text-danger` and `bg-transp` were both added
    # to live markup and the guard stayed GREEN. The same hole hid `input`
    # itself, which is a prefix of the real `.input-field` — so the guard that
    # caught `input-bordered` could never have caught its partner.
    #
    # Two boundaries close it, and both are load-bearing:
    #   (?<!\\)  the leading dot must START a selector, not be an escaped dot
    #            inside one — otherwise `bar` reads as defined from `.foo\.bar`.
    #   (?!…)    the name must END where the selector ends, so a prefix of a
    #            longer class no longer matches.
    # NO /o ON THIS REGEX. It interpolates the NAME, and /o compiles the
    # pattern once and reuses it for every later call — so the guard would
    # answer every question with the first name it was ever asked about.
    # Caught here by the prefix controls disagreeing with a measured run.
    def defined_in_css?(name, css = stylesheet)
      css.match?(/(?<!\\)\.#{Regexp.escape(css_escape(name))}(?!#{IDENT_CHAR})/)
    end

    # The class names in a `class="…"` value that the stylesheet leaves undefined.
    def phantoms(class_attribute, css = stylesheet)
      class_attribute.to_s.split.uniq.reject { |name| defined_in_css?(name, css) }
    end

    # Every STATIC class literal written in an ERB template, with the line it
    # sits on. Reading the source rather than a rendered body is deliberate: a
    # render only exercises the branch the test stubs, and both vault pages
    # carry three branches whose fields differ. The source carries all of them.
    #
    # ERB IS STRIPPED BEFORE THE ATTRIBUTE IS MATCHED, not after. A tag like
    # `class="p-2 <%= hero ? "a" : "b" %>"` contains quotes that END the
    # attribute early, and every bare Ruby local then leaks out looking like a
    # class name. Stripping first cost 16 false "phantoms" on one local alone.
    def class_literals_in_erb(path)
      src = File.read(path)
      src = blank_out(src, /<style[^>]*>.*?<\/style>/m)   # CSS is not markup
      src = blank_out(src, /<%.*?%>/m)                    # see above
      found = []
      src.each_line.with_index(1) do |line, number|
        line.scan(/(?<![:@\w.-])class=(["'])(.*?)\1/) do |_quote, value|
          value.split(/\s+/).each do |token|
            # A trailing-hyphen stub is a name COMPLETED at render time
            # (`class="level-badge-<%= n %>"`), not a class anyone can define.
            next unless token.match?(/\A!?[A-Za-z0-9][A-Za-z0-9_@:\/\[\]().%+*~-]*\z/)
            next if token.end_with?("-")
            found << [token, number]
          end
        end
      end
      found
    end

    private

    # Replace a region with spaces, keeping newlines so line numbers survive.
    def blank_out(src, pattern)
      src.gsub(pattern) { |m| m.gsub(/[^\n]/, " ") }
    end
  end
end
