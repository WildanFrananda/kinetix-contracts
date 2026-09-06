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

    # Install the built wheel into a throwaway environment and import out of it.
    #
    # The other three languages each shipped something unusable before this was checked:
    # npm packaged no contract at all, the gem's require_paths pointed at a directory it had no
    # files in. Python's layout happens to be right, and "happens to be" is the part worth
    # removing — a wheel that builds and uploads is not a wheel a consumer can import.
    wheel="$(ls -t dist/*.whl | head -1)"
    scratch="$(mktemp -d)"
    python -m venv "$scratch/venv"
    "$scratch/venv/bin/pip" install --quiet "$wheel"
    "$scratch/venv/bin/python" -c '
from identity.v1 import identity_pb2
from fulfillment.v1 import fulfillment_pb2
request = identity_pb2.GetUserProfileRequest(principal_id="probe")
assert request.principal_id == "probe", "the generated message did not round-trip a field"
fields = [f.name for f in fulfillment_pb2.CreateOrderRequest.DESCRIPTOR.fields]
assert "merchant_principal_id" in fields, f"CreateOrderRequest has no merchant_principal_id: {fields}"
print("importing identity.v1 and fulfillment.v1 out of the built wheel works")
' || { echo "the built wheel is not importable; refusing to publish it"; rm -rf "$scratch"; exit 1; }
    rm -rf "$scratch"

    TWINE_USERNAME=__token__ TWINE_PASSWORD="$PYPI_TOKEN" python -m twine upload dist/*
    ;;



  ruby)
    require RUBYGEMS_API_KEY
    cd gen/ruby
    cp ../../packaging/rubygems/kinetix-contracts.gemspec .
    sed -i "s/__VERSION__/$semver/" kinetix-contracts.gemspec
    gem build kinetix-contracts.gemspec

    # The check that matters is not "did it build" but "can a consumer reach what is inside".
    #
    # v1.0.3 built, pushed and installed while `require "identity/v1/identity_services_pb"` raised
    # LoadError: the gemspec declared no `require_paths`, so it defaulted to lib/, and every
    # generated file sits at the gem root instead.
    #
    # Read out of the built .gem rather than by installing and requiring. Installing means
    # resolving `grpc`, which compiles a native extension and would put minutes of C++ into a
    # publish job to answer a question about a manifest. This asks the manifest.
    built="$(ls -t ./*.gem | head -1)"
    ruby -rrubygems/package -e '
      spec = Gem::Package.new(ARGV[0]).spec
      rb = spec.files.grep(/\.rb\z/)
      abort "the gem contains no .rb files at all" if rb.empty?

      reachable = rb.select do |f|
        spec.require_paths.any? { |rp| rp == "." ? true : f.start_with?("#{rp}/") }
      end

      if reachable.empty?
        warn "require_paths #{spec.require_paths.inspect} reaches none of the #{rb.size} .rb files"
        warn "the first few are: #{rb.first(3).join(", ")}"
        abort "nothing in this gem is requirable; refusing to publish it"
      end

      puts "#{reachable.size} of #{rb.size} .rb files are reachable from #{spec.require_paths.inspect}"
    ' "$built" || exit 1

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
    # Packagist does not watch the split repository. It crawled it once, when the package was
    # first submitted, and never again — which is how v1.0.1 through v1.0.5 came to exist as tags
    # that Composer could not resolve. Pushing the tag is only half a publish; telling Packagist
    # is the other half, and it is checked here rather than after the push so a missing credential
    # costs nothing.
    require PACKAGIST_USERNAME
    require PACKAGIST_API_TOKEN
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

    # Ask Composer whether it can read the manifest, then whether a consumer can reach a class
    # through it. Both halves are needed and neither was checked before.
    #
    # v1.0.1 through v1.0.5 shipped with the reasoning behind the google/protobuf constraint
    # written as an entry inside `require`. Composer parses every value in that object as a
    # version constraint, so the note became `require _comment_protobuf: "Lower bound, not a
    # caret. ..."` and the package stopped loading at all:
    #
    #   Link constraint in wildanfrananda/kinetix-contracts requires > _comment_protobuf
    #   should be a valid version constraint, got "Lower bound, not a caret. ..."
    #
    # Five tags carried it. Nothing caught it because Packagist never crawled them, so the only
    # version anyone could install stayed v1.0.0 — the broken constraint was hidden behind a
    # broken publish, and fixing the publish alone would have shipped it.
    ( cd "$work" && composer validate --strict --no-check-publish --no-check-lock ) || {
      echo "the generated composer.json is not valid; refusing to publish it"
      exit 1
    }

    probe="$(mktemp -d)"
    # `*@dev` on this one package, not a global minimum-stability.
    #
    # A path repository takes its version from the checked-out branch, never from a tag, so the
    # package under test always presents itself as dev-main here however it is tagged. Requiring
    # it as `*` under stable stability therefore cannot resolve — which is what failed the v1.0.6
    # run, and it failed for a reason that has nothing to do with the package:
    #
    #   wildanfrananda/kinetix-contracts[dev-main] from path repo has higher repository priority.
    #   The packages from the higher priority repository do not match your minimum-stability
    #
    # The flag is per-constraint so google/protobuf and grpc/grpc still resolve stable. Version
    # resolution is not what this probe is for; Packagist reads the real version off the git tag.
    cat > "$probe/composer.json" <<PROBE
{
  "name": "kinetix/publish-probe",
  "repositories": [{ "type": "path", "url": "$work", "options": { "symlink": false } }],
  "require": { "wildanfrananda/kinetix-contracts": "*@dev" },
  "minimum-stability": "stable",
  "prefer-stable": true
}
PROBE
    # ext-grpc is a native extension and this probe does not make a call; it asks whether the
    # generated classes autoload and whether a money field survives the wire, which is the one
    # property the whole repository exists to guarantee.
    #
    # Not --quiet. A guard that fails without saying why costs more than it saves: the first run
    # of this one printed "could not be resolved to an installable set of packages" and nothing
    # else, and the sentence naming the cause was the one Composer had been told to swallow.
    ( cd "$probe" \
        && COMPOSER_NO_INTERACTION=1 composer install --no-progress --ignore-platform-req=ext-grpc \
        && php -r '
require "vendor/autoload.php";
$m = new \Common\V1\Money();
$m->setAmountMinor("9007199254740993");   // 2^53 + 1, the first integer a double cannot hold
$m->setCurrency("IDR");
$back = new \Common\V1\Money();
$back->mergeFromString($m->serializeToString());
if ((string) $back->getAmountMinor() !== "9007199254740993") {
    fwrite(STDERR, "amount_minor came back as " . $back->getAmountMinor() . "\n");
    exit(1);
}
new \Order\V1\GetOrderDetailsRequest();
echo "the package autoloads and 2^53+1 survives a Money round-trip\n";
' ) || {
      echo "the assembled package does not install or does not autoload; refusing to publish it"
      rm -rf "$probe"
      exit 1
    }
    rm -rf "$probe"

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

    echo "pushed $version to $split_repo"

    # Tell Packagist directly rather than hoping a webhook exists.
    #
    # It did not. The package was submitted by hand at v1.0.0 and Packagist's crawler was never
    # wired to the split repository, so five subsequent tags landed in git and nowhere else. A
    # webhook is invisible when it is absent — there is no failure, just a version that quietly
    # never appears — and it lives in a repository this workflow rebuilds and force-pushes, which
    # is the last place to keep configuration. One API call from the job that made the tag is
    # both visible and self-repairing.
    ping="$(curl -sS --max-time 30 -X POST \
      -H "Content-Type: application/json" \
      -d "{\"repository\":{\"url\":\"https://github.com/${split_repo}\"}}" \
      -o /tmp/packagist-update.json -w '%{http_code}' \
      "https://packagist.org/api/update-package?username=${PACKAGIST_USERNAME}&apiToken=${PACKAGIST_API_TOKEN}")"

    if [ "$ping" != "202" ] || [ "$(jq -r '.status // "missing"' /tmp/packagist-update.json)" != "success" ]; then
      echo "Packagist did not accept the update request (HTTP $ping):"
      cat /tmp/packagist-update.json
      echo
      echo "The tag is pushed and correct; only Packagist is behind. Check that PACKAGIST_API_TOKEN"
      echo "belongs to a maintainer of wildanfrananda/kinetix-contracts — the token of a user who"
      echo "is not a maintainer returns 403 here while working everywhere else."
      exit 1
    fi
    echo "Packagist accepted the update request for $split_repo"

    # Crawling is asynchronous, so this confirms rather than gates: a version that has not shown
    # up in two minutes is usually still coming, and failing the job would not bring it sooner.
    for _ in $(seq 1 8); do
      sleep 15
      if curl -sS --max-time 20 "https://repo.packagist.org/p2/wildanfrananda/kinetix-contracts.json?t=$(date +%s)" \
           | jq -e --arg v "$version" '.packages["wildanfrananda/kinetix-contracts"][] | select(.version == $v)' >/dev/null 2>&1; then
        echo "Packagist is serving $version"
        break
      fi
    done
    ;;


  *)
    echo "unknown language: $language"
    exit 1
    ;;
esac

echo "published $language at $semver"
