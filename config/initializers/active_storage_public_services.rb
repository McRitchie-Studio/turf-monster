# Modern S3 buckets default to "Bucket owner enforced" — object ACLs are
# DISABLED, and public read is granted by a BUCKET POLICY instead (the
# turf-monster buckets are public-read this way). But Active Storage's
# `public: true` S3 service unconditionally forces a per-object ACL on upload
# (s3_service.rb: `@upload_options[:acl] = "public-read" if public?`), which an
# ACL-disabled bucket rejects with Aws::S3::Errors::AccessControlListNotSupported.
#
# Strip the ACL from our public og-image services so uploads succeed. We KEEP
# `public: true` so `public_url` still emits the permanent, absolute,
# non-expiring URL that link-preview unfurlers cache; the bucket policy (not an
# ACL) is what actually grants public read.
Rails.application.config.after_initialize do
  %i[amazon_public amazon_public_dev].each do |name|
    begin
      service = ActiveStorage::Blob.services.fetch(name)
      # On a mirror stage of the R2 move (lib/storage_backend.rb) the name is a
      # MirrorService over halves the registry never hands out: strip each half.
      halves = service.respond_to?(:primary) ? [ service.primary, *service.mirrors ] : [ service ]
      halves.each { |half| half.upload_options.delete(:acl) if half.respond_to?(:upload_options) }
    rescue => e
      # This is a structural workaround for an Active Storage internal; if that
      # internal drifts, fail LOUD in dev/test/CI so we catch it at boot — not
      # months later as an AccessControlListNotSupported 500 on an admin upload.
      # Prod degrades gracefully (a missing image upload beats a boot crash).
      raise e unless Rails.env.production?
      Rails.logger.warn("[active_storage] could not strip ACL from #{name}: #{e.class}: #{e.message}")
    end
  end
end
