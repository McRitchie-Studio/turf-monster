# syntax = docker/dockerfile:1

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t my-app .
# docker run -d -p 80:80 -p 443:443 --name my-app -e RAILS_MASTER_KEY=<value from config/master.key> my-app

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.3.11
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips postgresql-client && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times
RUN bundle exec bootsnap precompile app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY.
# A production boot refuses to start without its storage and chain settings
# (the R2 four: StorageBackend.verify! in config/initializers/studio.rb; the
# wallet key: config/initializers/managed_wallet_encryption.rb; the Solana
# three: app/services/solana/config.rb), so this build-time boot names
# placeholders that reach nothing: `.invalid` never resolves (RFC 2606), and no
# asset embeds any of them. They live on this line only, never in an ENV
# instruction, so the running container gets the real values or refuses to boot
# (test/lib/dockerfile_build_env_test.rb). Heroku builds with the Ruby
# buildpack, not this file.
RUN SECRET_KEY_BASE_DUMMY=1 \
    R2_ENDPOINT=https://build-time.invalid R2_ACCESS_KEY_ID=build-time \
    R2_SECRET_ACCESS_KEY=build-time R2_PUBLIC_URL=https://build-time.invalid \
    MANAGED_WALLET_ENCRYPTION_KEY=build-time \
    SOLANA_PROGRAM_ID=build-time SOLANA_RPC_URL=https://build-time.invalid SOLANA_NETWORK=build-time \
    ./bin/rails assets:precompile




# Final stage for app image
FROM base

# Copy built artifacts: gems, application
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails db log storage tmp
USER 1000:1000

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start the server by default, this can be overwritten at runtime
EXPOSE 3000
CMD ["./bin/rails", "server"]
