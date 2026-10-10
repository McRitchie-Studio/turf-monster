# frozen_string_literal: true

require "active_storage/service/studio_trash_s3_service"

module ActiveStorage
  # A public-read Active Storage service on Cloudflare R2, for the og:image
  # (link-preview) attachments OgImageAttachable routes to `amazon_public`.
  #
  # Why the S3 service alone is not enough: with `public: true` it answers `url`
  # with `object_for(key).public_url`, which the AWS SDK builds from the API
  # endpoint. On R2 that is https://<account>.r2.cloudflarestorage.com/<bucket>/<key>,
  # which needs a signature, so every unfurler would get a 400. R2 serves an
  # object anonymously only through a domain attached to the bucket, so this
  # service answers with "<public_url>/<key>" instead.
  #
  # It inherits the engine's StudioTrashS3Service, not S3Service, so a purged or
  # replaced og:image gets the same three-day grace window as a private
  # attachment: `delete` copies the object under trash/ before deleting it, and
  # refuses a "*-production" bucket from a process that is not real production.
  # (`/trash/*` is blocked on the public hosts, so a trashed image is not served.)
  #
  # No object ACL is sent. S3Service adds `acl: public-read` to every upload of a
  # public service; R2 has no ACLs and public read comes from the attached domain
  # alone, so the option is dropped here rather than by an initializer.
  #
  # Active Storage finds this file by `require "active_storage/service/r2_public_service"`
  # (service: R2Public in config/storage.yml), which is why it sits on lib's load
  # path and outside Zeitwerk (config/application.rb ignores lib/active_storage).
  class Service::R2PublicService < Service::StudioTrashS3Service
    def initialize(public_url:, **options)
      base = public_url.to_s.strip.chomp("/")
      raise ArgumentError, "R2Public needs a public_url (the domain attached to the bucket)" if base.empty?

      @public_base_url = base
      super(**options, public: true)
      upload_options.delete(:acl)
    end

    private
      def public_url(key, **)
        "#{@public_base_url}/#{key}"
      end
  end
end
