# frozen_string_literal: true

# A year of cache on fingerprinted /assets/*, a week on everything else under
# public/ (see lib/digested_asset_cache.rb for why the two differ).
#
# Outside ActionDispatch::Static, so it sees the headers Static wrote and
# replaces them for a digested path. Required rather than autoloaded: the file
# is on the autoload_lib ignore list in config/application.rb, as
# response_compression.rb is.
require_relative "../../lib/digested_asset_cache"

Rails.application.config.middleware.insert_before ActionDispatch::Static, DigestedAssetCache
