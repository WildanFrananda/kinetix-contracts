# Packagist publishing: what broke, and the traps

Packagist served `v1.0.0` of `wildanfrananda/kinetix-contracts` for five releases. This is the
record of why, because both faults are the kind that come back.

Resolved at **v1.0.7** on 2026-09-06. All four registries now serve the same version.

## Two faults, and the second was hiding behind the first

### 1. Nothing ever told Packagist

The `publish (php)` job was never broken. Every release built the split repository, committed it
and pushed the tag. `WildanFrananda/kinetix-contracts-php` had `v1.0.0` through `v1.0.5` sitting
in git the whole time.

The package had been submitted to Packagist by hand at `v1.0.0`, and nothing was ever wired to
tell it about a new tag. `README.md` asserted a webhook existed. None did.

This is a failure with no failure signal — no red job, no error, just a version that quietly never
appears. Two API calls tell you:

```bash
# what actually exists
curl -s https://api.github.com/repos/WildanFrananda/kinetix-contracts-php/tags \
  | jq -r '.[].name'

# what Packagist knows, and whether it has ever crawled
curl -s https://repo.packagist.org/p2/wildanfrananda/kinetix-contracts.json \
  | jq -r '.packages[][].version'
curl -s https://packagist.org/packages/wildanfrananda/kinetix-contracts.json \
  | jq '.package | {repository, crawledAt, autoUpdated}'
```

A missing `crawledAt` means it has never auto-updated. That is the whole diagnosis.

### 2. The manifest could not be loaded at all

The reasoning behind the `google/protobuf` constraint had been written as an entry *inside*
`require`. Composer parses every value in that object as a version constraint, so an explanatory
sentence became a dependency:

```json
"require": {
  "php": ">=8.3",
  "_comment_protobuf": "Lower bound, not a caret. The generated classes use…",
  "google/protobuf": "^4.29"
}
```

```
Link constraint in wildanfrananda/kinetix-contracts requires > _comment_protobuf
should be a valid version constraint, got "Lower bound, not a caret. …"

Could not parse version constraint Lower: Invalid version string "Lower"
```

Five tags carried it. Nothing caught it because of fault 1 — the only version anyone could install
was `v1.0.0`, which predated the note. **The broken manifest was hidden behind the broken publish,
and fixing the publish alone would have shipped it.**

Order matters when unpicking this: fix the manifest, cut the tag, *then* tell Packagist. Pressing
"Update" first would have crawled five unloadable versions. (It eventually did crawl them, and
rejected all five — they are absent from Packagist's version list to this day, which is correct.)

## Three traps

**A comment belongs at the root of `composer.json`, never inside `require`.** Composer ignores
unknown root keys and parses every value in `require`. `composer validate --strict` catches this
in under a second.

**`google/protobuf` is a bounded range, not a caret.** `^4.29` excludes 5.x outright, and
`kinetix-review-service` runs Laravel 13, which already requires `google/protobuf ^5.36`. A
contracts package that cannot be installed beside a current framework is not a shared contract.
The constraint is `>=4.29 <6`: bounded, so `composer validate --strict` is happy, and satisfied by
`v5.36.1`.

**A `path` repository takes its version from the checked-out branch, never from a tag.** This one
cost a whole release. The install-and-autoload probe added to `publish.sh` required the assembled
package as `*` under `minimum-stability: stable`, and the assembled package always presents itself
as `dev-main`:

```
wildanfrananda/kinetix-contracts[dev-main] from path repo has higher repository
priority. The packages from the higher priority repository do not match your
minimum-stability and are therefore not installable.
```

Require it as `"*@dev"` instead — the stability flag then applies to that one constraint, and
`google/protobuf` and `grpc/grpc` still resolve stable.

The probe had been checked locally and passed, against a `git clone --depth 1 --branch v1.0.5`.
That is a **detached HEAD at a tag**, which does carry a stable version — a shape the job never
produces. Test a guard against a directory assembled with no git in it, the way CI assembles one.

## What the job does now

`packaging/publish.sh`, the `php` branch, in order:

1. Ask the GitHub API whether `CONTRACTS_PHP_TOKEN` may push, before doing any work.
2. Require `PACKAGIST_USERNAME` and `PACKAGIST_API_TOKEN` up front, for the same reason.
3. Assemble `src/` and `composer.json`; refuse if no `.php` files were generated.
4. `composer validate --strict` on the assembled manifest.
5. Install the assembled package into a throwaway project, autoload `Common\V1\Money`, and check
   that `2^53+1` survives a serialize/parse round-trip.
6. Commit, tag, push `main` force and the tag plain.
7. `POST https://packagist.org/api/update-package`. Fail unless it answers `202` with
   `{"status":"success"}`.
8. Poll `repo.packagist.org` for up to two minutes. This confirms rather than gates — crawling is
   asynchronous and failing the job would not make it faster.

`.github/workflows/ci.yml` gained a `manifests` job so a bad manifest fails on a pull request
instead of on a tag.

**Never add `--quiet` to a guard.** The first run of the probe printed `Your requirements could not
be resolved to an installable set of packages.` and nothing else. The sentence naming the cause was
the one Composer had been told to swallow.

## Verifying a release

```bash
curl -s https://repo.packagist.org/p2/wildanfrananda/kinetix-contracts.json \
  | jq -r '.packages[][].version'

cd "$(mktemp -d)"
composer require wildanfrananda/kinetix-contracts:^1.0.7 --ignore-platform-req=ext-grpc
php -r 'require "vendor/autoload.php";
  $m = new \Common\V1\Money(); $m->setAmountMinor("9007199254740993");
  $b = new \Common\V1\Money(); $b->mergeFromString($m->serializeToString());
  echo $b->getAmountMinor(), PHP_EOL;'   # 9007199254740993
```

Asking Packagist that a version exists is not the same question as asking Composer that it can be
used. The second one is what failed for five releases.

## Loose ends

- **`v1.0.1` through `v1.0.6` will never appear on Packagist.** The first five are unloadable and
  `v1.0.6` never reached the split repository — its `php` leg aborted at the probe, before pushing
  anything. The tags stay: this repository does not move or delete release tags, and nobody could
  ever have installed those versions anyway.
- **`v1.0.6` exists on npm, PyPI and RubyGems.** Those three legs succeeded while `php` failed, so
  the version is real and the tag could not be reused. `v1.0.7` is byte-identical for them.
- **RubyGems has no `1.0.4`.** An older gap, from before any of this. Never chased.
- **`\Order\V1\OrderServiceClient` is in the package.** buf generates the gRPC clients too, so
  `kinetix-review-service`'s hand-written stub in `generated/` could become a `composer require`.
