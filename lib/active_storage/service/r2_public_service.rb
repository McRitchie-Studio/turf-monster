# frozen_string_literal: true

require "active_storage/service/s3_service"

module ActiveStorage
  # A public-read Active Storage service on Cloudflare R2, for the og:image
  # (link-preview) attachments OgImageAttachable routes to `amazon_public`.
  #
  # Why S3Service alone is not enough: with `public: true` it answers `url` with
  # `object_for(key).public_url`, which the AWS SDK builds from the API endpoint.
  # On R2 that is https://<account>.r2.cloudflarestorage.com/<bucket>/<key>, which
  # needs a signature, so every unfurler would get a 400. R2 serves an object
  # anonymously only through a domain attached to the bucket, so this service
  # answers with "<public_url>/<key>" instead. Everything else is S3Service.
  #
  # The `public-read` ACL S3Service adds on upload is harmless: R2 accepts the
  # header and ignores it (measured on turf-monster-dev, 2026-09-29).
  #
  # Active Storage finds this file by `require "active_storage/service/r2_public_service"`
  # (service: R2Public in config/storage.yml), which is why it sits on lib's load
  # path and outside Zeitwerk (config/application.rb ignores lib/active_storage).
  class Service::R2PublicService < Service::S3Service
    def initialize(public_url:, **options)
      base = public_url.to_s.strip.chomp("/")
      raise ArgumentError, "R2Public needs a public_url (the domain attached to the bucket)" if base.empty?

      @public_base_url = base
      super(**options, public: true)
    end

    private
      def public_url(key, **)
        "#{@public_base_url}/#{key}"
      end
  end
end
