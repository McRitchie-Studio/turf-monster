# frozen_string_literal: true

require "pathname"

module TurfMonster
  # Guards studio-engine's `studio:node:link` (lib/tasks/node_tooling.rake) in a
  # desk whose node_modules is a SYMLINK to another checkout's.
  #
  # `Studio::NodeTooling.link!` writes `node_modules/.studio-engine` through
  # whatever `node_modules` is. A desk that borrowed the primary's node_modules
  # (some agents `ln -s` it rather than run `npm ci`) would therefore write the
  # PRIMARY's link, pointed at the gem this desk bundles. On the same engine
  # version that is a no-op; on a relock desk it silently repoints the primary
  # (and every other desk that borrows it) at a different engine's tooling.
  #
  # So in a borrowed node_modules the link is left alone unless it already
  # points where this desk would point it. The desk instead runs `npm ci`
  # (its own node_modules, then link freely) or sets STUDIO_NODE_TOOLING, which
  # playwright.config.js and test/javascript/support/register.mjs read first.
  module NodeLinkGuard
    module_function

    # nil when linking here is safe; otherwise the sentence to abort with.
    def refusal(app_root, root: Studio::NodeTooling.root)
      app_root = Pathname(app_root)
      modules = app_root.join("node_modules")
      return nil unless modules.symlink?

      link = app_root.join(Studio::NodeTooling::LINK)
      return nil if link.symlink? && link.readlink == Pathname(root)

      "#{modules} is a symlink to #{modules.realpath rescue modules.readlink}, so " \
        "studio:node:link would write THAT checkout's .studio-engine link " \
        "(#{link.symlink? ? "now #{link.readlink}" : "absent"}) to #{root}. " \
        "Run `npm ci` in this desk for its own node_modules and link again, or " \
        "export STUDIO_NODE_TOOLING=#{root} instead of linking."
    end
  end
end
