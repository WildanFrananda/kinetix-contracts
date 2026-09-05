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

    # The .proto sources travel with the package, not just the code generated from them.
    #
    # NestJS's gRPC transport takes a `protoPath` and parses the file at runtime — generated
    # JavaScript is no use to it. Elixir and Rust generate at build time and need the source for
    # the same reason. Shipping both means one dependency serves every consumption style, rather
    # than four stacks vendoring the .proto again and diverging, which is what this repository
    # exists to stop.
    mkdir -p proto
    cp -R ../../proto/. proto/
    # The version comes from the tag, never from a committed file — two places to change a
    # version is one place to forget.
    npm version "$semver" --no-git-tag-version --allow-same-version

    # What `npm publish` would actually ship, checked before it ships it.
    #
    # v1.0.0 went out containing package.json and nothing else: buf emitted `.ts` while
    # package.json's `files` asked for `.js` and `.d.ts`, so every generated file was excluded
    # and npm called that a success. A publish that packages no contract is worse than a failed
    # one, because everything downstream installs it and finds nothing.
    packed="$(npm pack --dry-run --json 2>/dev/null | node -e '
      let raw = ""
      process.stdin.on("data", (d) => (raw += d))
      process.stdin.on("end", () => {
        const files = JSON.parse(raw)[0].files.map((f) => f.path)
        // Counted separately. A package of .d.ts with no .js ships types for an implementation
        // that is not there — which is what `target=js` and `target=dts` as two list entries
        // produced: buf joins them into one comma-separated option string and the plugin keeps
        // the last, so v1.0.2 went out as ten declarations and zero modules.
        const js = files.filter((f) => f.endsWith(".js")).length
        const dts = files.filter((f) => f.endsWith(".d.ts")).length
        const proto = files.filter((f) => f.endsWith(".proto")).length
        console.log(JSON.stringify({ js, dts, proto }))
      })')"
    js="$(printf '%s' "$packed" | sed -n 's/.*"js":\([0-9]*\).*/\1/p')"
    dts="$(printf '%s' "$packed" | sed -n 's/.*"dts":\([0-9]*\).*/\1/p')"
    proto="$(printf '%s' "$packed" | sed -n 's/.*"proto":\([0-9]*\).*/\1/p')"

    for pair in "js:${js:-0}" "dts:${dts:-0}" "proto:${proto:-0}"; do
      kind="${pair%%:*}"; count="${pair##*:}"
      test "$count" -gt 0 || {
        echo "npm pack would ship no .$kind files; refusing to publish an incomplete package"
        echo "  js=${js:-0} dts=${dts:-0} proto=${proto:-0}"
        echo "check buf.gen.yaml's target option against package.json's \"files\" globs"
        exit 1
      }
    done
    echo "packaging ${js} modules, ${dts} declarations and ${proto} .proto sources"

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

    # The check that matters is not "did it build" but "can a consumer require it".
    #
    # v1.0.3 built, pushed, installed and reported success while `require
    # "identity/v1/identity_services_pb"` raised LoadError — the gemspec had no `require_paths`
    # so it defaulted to lib/, and every generated file sits at the gem root. Installing the
    # freshly built gem into a scratch directory and requiring one file out of it is the only
    # thing that would have caught that.
    built="$(ls -t ./*.gem | head -1)"
    scratch="$(mktemp -d)"
    gem install --install-dir "$scratch" --no-document --ignore-dependencies "$built" >/dev/null
    GEM_HOME="$scratch" GEM_PATH="$scratch" ruby -e '
      gem "kinetix-contracts"
      require "identity/v1/identity_pb"
      abort "the gem installed but Identity::V1 is not defined" unless defined?(Identity::V1)
      puts "requiring identity/v1/identity_pb out of the built gem works"
    ' || { echo "the built gem is not requirable; refusing to publish it"; rm -rf "$scratch"; exit 1; }
    rm -rf "$scratch"

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

    # Ask before doing the work. Without this, a token that cannot push fails on the very last
    # line — after generating, copying, committing and tagging — with git's "Permission to ...
    # denied", which says nothing about which of the three possible causes it was. The API
    # answers all three at once and costs one request.
    perm="$(curl -sS --max-time 20 \
      -H "Authorization: Bearer $CONTRACTS_PHP_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -o /tmp/split-repo.json -w '%{http_code}' \
      "https://api.github.com/repos/${split_repo}")"

    case "$perm" in
      404)
        echo "CONTRACTS_PHP_TOKEN cannot see $split_repo."
        echo "A fine-grained token must list that repository under 'Only select repositories';"
        echo "a token created before the repository existed will not have it."
        exit 1 ;;
      401)
        echo "CONTRACTS_PHP_TOKEN was rejected. It is expired, revoked, or was pasted truncated."
        exit 1 ;;
      200) : ;;
      *)
        echo "GitHub returned $perm for $split_repo; cannot establish whether this token may push."
        exit 1 ;;
    esac

    can_push="$(jq -r '.permissions.push // false' /tmp/split-repo.json)"
    if [ "$can_push" != "true" ]; then
      echo "CONTRACTS_PHP_TOKEN can read $split_repo but not push to it."
      echo "Fine-grained: Repository permissions > Contents must be 'Read and write', not 'Read-only'."
      echo "Classic: the 'repo' scope must be ticked."
      exit 1
    fi
    echo "token may push to $split_repo"

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
