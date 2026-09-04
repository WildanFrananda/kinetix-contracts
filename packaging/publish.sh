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
    # Packagist publishes from a git tag, and this repository's tags carry no generated code:
    # gen/ is gitignored on purpose, because a committed copy of a wire type is the exact defect
    # this repository exists to remove. So the PHP package lives in a read-only split repository
    # that this job rebuilds from the generated output and tags. Nothing there is ever
    # hand-edited; it is a build artifact that happens to have a git history, which is the only
    # thing Composer needs in order to resolve a version.
    require CONTRACTS_PHP_TOKEN
    split_repo="${CONTRACTS_PHP_REPO:-WildanFrananda/kinetix-contracts-php}"

    test -d gen/php || { echo "gen/php is missing; the generate job produced no PHP"; exit 1; }

    work="$(mktemp -d)"
    mkdir -p "$work/src"
    cp -R gen/php/. "$work/src/"
    cp packaging/composer/composer.json "$work/composer.json"

    # A real guard, not a formality. An empty src/ publishes a package that resolves, installs
    # cleanly, and then dies at the first `new Money()` with a class-not-found — the worst shape
    # of failure, because it reads as the consumer's bug.
    php_files="$(find "$work/src" -name '*.php' | wc -l | tr -d ' ')"
    test "$php_files" -gt 0 || {
      echo "no .php files were generated; refusing to publish an empty package"
      exit 1
    }
    echo "packaging $php_files generated PHP files"

    cat > "$work/README.md" <<EOF
# kinetix-contracts-php

Generated from [kinetix-contracts](https://github.com/WildanFrananda/kinetix-contracts) at \`$version\`.

**Do not edit this repository and do not open pull requests against it.** Every commit here is
overwritten by the release workflow in the source repository. Change the \`.proto\` files there.
EOF

    cd "$work"
    git init --quiet -b main
    git config user.name "kinetix-contracts release"
    git config user.email "noreply@github.com"
    git add -A
    git commit --quiet -m "Generated from kinetix-contracts $version"
    git tag "$version"

    remote="https://x-access-token:${CONTRACTS_PHP_TOKEN}@github.com/${split_repo}.git"

    # The branch is force-pushed because it is a rebuild, not a history. The tag is not, and
    # deliberately so: a tag that can move is a version that can change meaning underneath a
    # consumer that already resolved it. Plain `git push` fails outright if the tag exists.
    git push --quiet --force "$remote" main
    git push --quiet "$remote" "$version"

    echo "pushed $version to $split_repo; Packagist updates when its webhook fires"
    ;;


  *)
    echo "unknown language: $language"
    exit 1
    ;;
esac

echo "published $language at $semver"
