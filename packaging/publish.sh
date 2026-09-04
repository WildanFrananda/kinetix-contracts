#!/usr/bin/env bash
# Publishes one generated language package. Called once per language by .github/workflows/release.yml.
#
# Only the four stacks that need a package are here. C#, Java, Rust and Elixir generate from the
# .proto files during their own builds, so publishing a package for them would add a second place
# to get a version wrong without removing any work.
#
# Every branch refuses to run without its credential rather than silently skipping. A publish
# job that exits 0 having published nothing is how a tag ends up meaning seven packages in one
# registry set and eight in another, and the discrepancy surfaces months later as a service
# importing a version that does not exist.

set -euo pipefail

language="${1:?usage: publish.sh <language>}"
version="${VERSION:?VERSION is required (the git tag, e.g. v1.0.0)}"
# Registries want 1.0.0, the tag is v1.0.0.
semver="${version#v}"

require() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "$name is not set. This job cannot publish without it, and will not pretend to."
    exit 1
  fi
}

case "$language" in
  typescript)
    require NPM_TOKEN
    cd gen/ts
    cp ../../packaging/npm/package.json .
    # The version comes from the tag, never from a committed file — two places to change a
    # version is one place to forget.
    npm version "$semver" --no-git-tag-version --allow-same-version
    printf '//registry.npmjs.org/:_authToken=%s\n' "$NPM_TOKEN" > .npmrc
    npm publish --access public
    ;;

  python)
    require PYPI_TOKEN
    cd gen/python
    cp ../../packaging/pypi/pyproject.toml .
    sed -i "s/__VERSION__/$semver/" pyproject.toml
    python -m pip install --quiet build twine
    python -m build
    TWINE_USERNAME=__token__ TWINE_PASSWORD="$PYPI_TOKEN" python -m twine upload dist/*
    ;;



  ruby)
    require RUBYGEMS_API_KEY
    cd gen/ruby
    cp ../../packaging/rubygems/kinetix-contracts.gemspec .
    sed -i "s/__VERSION__/$semver/" kinetix-contracts.gemspec
    gem build kinetix-contracts.gemspec
    mkdir -p ~/.gem
    printf -- '---\n:rubygems_api_key: %s\n' "$RUBYGEMS_API_KEY" > ~/.gem/credentials
    chmod 600 ~/.gem/credentials
    gem push ./*.gem
    ;;

  php)
    # Packagist publishes from the git tag itself; there is nothing to upload. The composer.json
    # has to be at the repository root for it to see, which is why this branch checks rather
    # than pushes.
    test -f composer.json || {
      echo "composer.json is missing from the repository root; Packagist reads the tag directly"
      exit 1
    }
    echo "Packagist publishes from tag $version once the repository webhook fires. Nothing to upload."
    ;;



  *)
    echo "unknown language: $language"
    exit 1
    ;;
esac

echo "published $language at $semver"
