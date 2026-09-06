# kinetix-contracts

The one place a Kinetix wire type is defined.

## Why this repo exists

Before it, nine protobuf packages lived in 43 files scattered across the service repositories,
and three of those packages had already drifted apart:

| package | copies | state |
|---|---|---|
| `pricing.v1` | 3 | all three different |
| `shipping.v1` | 3 | all three different |
| `payment.v1` | 2 | both different |
| `common.v1`, `fleet.v1`, `fulfillment.v1`, `returns.v1` | 3–6 each | identical, for now |

Every copy declared the same package name. Two services could therefore generate incompatible
stubs from "the same" contract, and nothing would report it — the failure surfaces as a field
arriving empty on the wire, in production, at the far end of a saga.

## The rule

**No `.proto` outside this module may define a wire type.** A copy is a future divergence.
Service repositories consume the published packages; they do not carry their own definitions.

## Layout

    proto/<domain>/v1/…      ten packages, one directory each
    buf.yaml                 module, lint and breaking-change configuration
    buf.gen.yaml             managed mode; language options live here, never in a .proto

Managed mode is deliberate. Part of why the vendored copies diverged is that each repo edited
the language options inside its own copy — `go_package` here, `csharp_namespace` there — until a
real change to a field was indistinguishable from someone adjusting their own namespace.

## Status

The module skeleton is in place and every package is reserved. The packages are empty by
design: a placeholder carrying invented messages is worse than an empty one, because somebody
imports it. Each file names the task that will author it.

## Running the checks locally

    cd tools/moneylint && go build -o moneylint . && cd ../..
    buf lint      # standard rules + moneylint
    buf format --diff --exit-code
    buf breaking --against '.git#branch=main'

`buf lint` will not run until the plugin is built — the binary is gitignored on purpose, so the
rule and its source can never drift apart.

## moneylint

Two rules, both failing the build rather than warning:

| rule | rejects |
|---|---|
| `MONEY_NO_FLOATING_POINT` | a money-bearing field declared `double` or `float` |
| `MONEY_USE_COMMON_TYPE` | a message declaring its own amount/currency pair instead of importing `common.v1.Money` |

IEEE-754 cannot represent `0.1`. A price expressed as a double drifts, and a total computed in
one of this platform's eight languages disagrees with the same total computed in another.

The matching is deliberately conservative. `quantity`, `count`, `rate`, `percentage` and
`amount_minor` are exempt, because a rule that cries wolf is a rule someone disables. CI runs a
self-test job that feeds the plugin a violation and fails if it stays quiet — a lint rule never
seen to fail is not a lint rule.

## Publishing

One tag, four registries. `.github/workflows/release.yml` fires on `v*.*.*` and runs
`packaging/publish.sh` once per language.

The tag is the version. Nothing computes or bumps one: packages claiming the same version must
come from the same commit, or the guarantee this repository exists to provide — one `.proto`, one
shape everywhere — is false in the way hardest to notice.

| stack | how it gets the contract |
|---|---|
| TypeScript | `kinetix-contracts` on **npm** |
| Python | `kinetix-contracts` on **PyPI** |
| Ruby | `kinetix-contracts` on **RubyGems** |
| PHP | `wildanfrananda/kinetix-contracts` on **Packagist**, via a generated split repository |
| C# | generates from `.proto` at build (`Grpc.Tools`) |
| Java | generates from `.proto` at build (`protobuf-maven-plugin`) |
| Rust | generates from `.proto` at build (`tonic-build`) |
| Elixir | generates from `.proto` at build (`protoc-gen-elixir`) |

### Why four and not eight

A published package buys exactly one thing: a version-pinned dependency, so "which contract does
this service speak?" is answered by a manifest rather than by reading the code. Four of the eight
stacks already generate from `.proto` during their own build, and they pin the version by
consuming this repository at the git tag.

That pins just as firmly. The one real difference is that a tag can be moved and a published
version cannot — so the discipline is that **a release tag is never moved**. Two services
building from the same tag name must always get the same bytes.

Dropping the other four removes Maven Central's verified-namespace and GPG-signing setup
entirely, which was the longest lead time here and bought nothing the build did not already do.

### Names

None of these are scoped or namespaced under `kinetix`. The npm organisation and the Packagist
vendor of that name are both already owned by someone else, and neither registry lets a name be
reserved by intent. The npm package is therefore unscoped, which has the side benefit of making
the name identical on npm, PyPI and RubyGems; the Composer package sits under the `wildanfrananda`
vendor, which is the GitHub account that owns the repository anyway.

### PHP is not like the other three

Composer resolves a version from a git tag, and the tags of *this* repository carry no generated
code — `gen/` is gitignored on purpose, because a committed copy of a wire type is the exact
defect this repository exists to remove.

So the release workflow rebuilds a read-only split repository, `kinetix-contracts-php`, from the
generated PHP and tags it with the same version. Composer reads that; nobody edits it. Its `main`
is force-pushed on every release because it is a build output, not a history — but its **tags are
never force-pushed**, and `publish.sh` will fail loudly rather than move one.

The job also refuses to publish when no `.php` files were generated. An empty package resolves,
installs cleanly, and then dies at the first `new Money()` with a class-not-found, which reads as
the consumer's bug rather than as this repository's.

### What has to exist before the first tag

Four accounts, one extra repository, and six repository secrets:

    NPM_TOKEN     PYPI_TOKEN     RUBYGEMS_API_KEY     CONTRACTS_PHP_TOKEN
    PACKAGIST_USERNAME     PACKAGIST_API_TOKEN

`CONTRACTS_PHP_TOKEN` is a fine-grained GitHub token with `contents: write` on
`kinetix-contracts-php` and nothing else. The package still has to be submitted to Packagist once
by hand.

The two Packagist secrets are not optional and this README used to say they were: it claimed
Packagist reads the split repository through a webhook. No webhook existed, and Packagist served
v1.0.0 for five releases while every tag landed correctly in git. `publish.sh` now calls
Packagist's update API itself. See [docs/packagist-publishing.md](docs/packagist-publishing.md)
for what went wrong and the three traps worth remembering.

Every branch of `publish.sh` refuses to run without its credential rather than skipping quietly.
A publish job that exits 0 having published nothing is how a tag comes to mean three packages in
one registry set and four in another, and that discrepancy surfaces months later as a service
importing a version that does not exist.

### Consuming from the tag (C#, Java, Rust, Elixir)

Fetch this repository at the tag and point the build's codegen at `proto/`. The version lives in
whatever pins the fetch — a submodule commit, a `git fetch --depth 1 --branch v1.0.0`, or a
vendoring step in CI. Do not copy the files into the service repository: a copy is the divergence
this repository exists to remove.
