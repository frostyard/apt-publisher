<!-- readme-kind: packaging -->
# apt-publisher

apt-publisher is the single writer of the Frostyard APT repository at
`https://repository.frostyard.org/debian/`, built on
[aptly](https://www.aptly.info/). Producer repositories send a `publish-deb`
dispatch, and it publishes their GitHub releases under the `trixie` (Debian
13) and `forky` (Debian 14) codenames. It is for Frostyard maintainers and
for the producer repositories whose packages it publishes.

**Status:** in production. It publishes from `main`.

**Documentation:** [docs/README.md](docs/README.md)

## What it publishes

| Codename | Debian | Architectures | Components |
| --- | --- | --- | --- |
| `trixie` | 13 | amd64, arm64, all | `main`, `image` |
| `forky` | 14 | amd64, arm64, all | `main`, `image` |

| Producer | Packages | Component | Codenames |
| --- | --- | --- | --- |
| frostyard/updex | `frostyard-updex` | `main` | `trixie`, `forky` |
| frostyard/intuneme | `frostyard-intuneme` | `main` | `trixie`, `forky` |
| frostyard/firn | `frostyard-firn`, `frostyard-firn-gui` | `main` | `trixie`, `forky` |
| frostyard/chairlift | `frostyard-chairlift`, `frostyard-chairlift-system-integration` | `main` | `trixie`, `forky` |
| frostyard/omarchy-apps | `moonlight-qt`, `voxtype` | `main` | `trixie`, `forky` |
| frostyard/bootc-debian | `bootc`, `libostree-1-1` | `image` | `trixie`, `forky` |
| frostyard/incus | `incus`, `incus-base`, `incus-client`, `incus-extra`, `incus-ui-canonical` | `image` | `trixie`, `forky` |

`config/codenames.tsv` is the source of the first table and
`config/producers.tsv` of the second.

## Install

Add the repository once, then install:

```sh
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSLo /etc/apt/keyrings/frostyard.gpg https://repository.frostyard.org/debian/frostyard.gpg
printf 'Types: deb\nURIs: https://repository.frostyard.org/debian/\nSuites: trixie\nComponents: main\nSigned-By: /etc/apt/keyrings/frostyard.gpg\n' | sudo tee /etc/apt/sources.list.d/frostyard.sources
sudo apt update
sudo apt install frostyard-updex
```

Use `Suites: forky` on a Debian 14 host. A host that needs builds which
replace Debian packages of the same name adds `image` to `Components:`.

## Add a package

A producer repository registers a row in `config/producers.tsv` and replaces
its own publish step with a `publish-deb` dispatch, which needs the org
secret `APT_PUBLISH_TOKEN` and nothing else. [docs/runbooks/producers.md](docs/runbooks/producers.md)
has the three steps, the registration columns and the token command.

## How it works

A release's `.deb` files are verified against the producer's build
attestation, routed to their codenames, added to aptly and published as one
signed `Release` per codename, then read back from the bucket and downloaded
through the public URL by an apt canary.
[docs/design/overview.md](docs/design/overview.md) has the flow, the buckets
and the state rules;
[docs/runbooks/operations.md](docs/runbooks/operations.md) has withdraw,
retention, rollback, move and recovery.

## Limits

- Every run restores the whole aptly state pool, about 3 GiB.
- The audit parses asset names and checks only each producer's latest
  release. It reports a withdrawn latest release as missing, by design.
- A point-in-time rollback also unpublishes other producers' later packages
  until they are republished. Use withdraw for one bad version.
- A withdrawn version comes back if the same release is republished: there
  is no blocklist.

## Develop

```sh
mise install   # aptly, rclone, shellcheck, actionlint, jq
make verify    # shellcheck, actionlint, config and baseline checks, end-to-end test
make ci        # what CI runs: make verify
```

[docs/runbooks/development.md](docs/runbooks/development.md) has the system
tools the end-to-end test needs, and what it simulates.

## Where to go next

- [AGENTS.md](AGENTS.md): the invariants that agents and contributors must
  keep.
- [docs/README.md](docs/README.md): the decisions, the design, the specs and
  the runbooks.
- [SECURITY.md](SECURITY.md): report a vulnerability, and what gets fixes.
- [LICENSE](LICENSE): MIT.
