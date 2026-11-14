# Development

Runbook for working on the publisher itself. Index:
[docs/README.md](../README.md). The operations:
[operations.md](operations.md). The design:
[design/overview.md](../design/overview.md).

## Tools

```sh
mise install   # aptly, rclone, shellcheck, actionlint, jq
make verify    # shellcheck, actionlint, the config checks, the end-to-end test
```

`mise.toml` and `mise.lock` pin every tool (core ADR-0043): aptly 1.6.3,
rclone 1.71.1, shellcheck 0.11.0, actionlint 1.7.7 and jq 1.8.1.

The end-to-end test also needs `gpg`, `gpgv`, `gpgconf`, `dpkg-deb`,
`apt-get`, `apt-cache`, `curl`, `python3`, `sha256sum`, `gzip` and `xz` from
the system, which Debian and the Ubuntu runners already have. `tests/run.sh`
checks for each tool before it starts.

Run the gate with `umask 022`: `dpkg-deb` refuses a package control
directory of mode 700, which a stricter umask gives the test fixtures.

## The gate

`make verify` is the gate; `make check` and `make ci` both run it.

- `make lint` runs `shellcheck scripts/*.sh tests/*.sh`, `actionlint`,
  `tests/check-config.sh`, `tests/check-baseline.sh` and
  `tests/check-baseline-test.sh`.
- `make test` runs `timeout 600 tests/run.sh`.
- `tests/check-config.sh` checks the committed configuration without
  credentials: the keyring's fingerprint, `config/codenames.tsv` and
  `config/producers.tsv` (columns, value sets, component and codename cross
  rules), the `withdrawals/` batch rows, the `apt-repository` concurrency
  group, the bash `defaults` and that no step overrides the shell.
- `tests/check-baseline.sh` checks the repository baseline (core
  [ADR-0071](https://github.com/frostyard/core/blob/main/docs/adr/0071-hold-every-code-repository-to-one-baseline.md)):
  the instruction-file symlinks, the `.memory/corrections/` records, the `docs/`
  shape, the make gate and the tool pins, the pinned actions and workflow
  permissions, the risk paths and their caller, the pull request template,
  the CI entry, Dependabot, `SECURITY.md`, no `CODEOWNERS`, no leftover
  agent-framework trees, and the README kind marker and length. The rows are
  in core's
  [repository baseline spec](https://github.com/frostyard/core/blob/main/docs/specs/repository-baseline.md).
- `tests/check-baseline-test.sh` is the baseline check's negative harness. Each
  case copies the working tree to a temporary directory, applies 1 mutation
  and requires the check to fail with a known message; 1 case requires the
  unmutated copy to pass, and a mutation that changes nothing fails its case.
  It prints `ok N - case` and `1..N`. Add a case for every new rule in
  `tests/check-baseline.sh`.

Tools are pinned in `mise.toml`. Add a test to `tests/run.sh` for every new
refusal or routing rule.

## What `tests/run.sh` does

- It starts `rclone serve s3` on a free port and creates a throwaway signing
  key.
- It builds a repogen-shaped legacy suite.
- It runs every script as a fresh runner.
- It checks the published result with `apt-get update` / `apt-cache policy`
  and the canary's `apt-get download` in a sandboxed apt root. A fake
  container runtime (`APT_CANARY_RUNTIME`) stands in for the canary's
  install check, so the test needs no `docker` or `podman`; it records each
  install target and fails a run on request.
- It simulates the failures it guards against: a stale database, an
  interrupted publication (an `rclone` shim that fails a save), leftover
  import files, corrupted pool files and tampered indexes.
- It runs the audit against a stubbed `gh`, and the secrets check against
  stubbed `curl` and `gh`.

`KEEP_TMP=1 tests/run.sh` keeps its work directory for inspection.

## Changing the publishing path

The paths that can publish, sign, withdraw or handle secrets are on the risk
path list in `.github/risk-paths.json`, so a pull request that touches one
gets that entry's level label (`level:L1` read every line, `level:L2` read the
diff, `level:L3` skim, `level:L4` title and CI), and `risk:high` at L1 and L2
(core ADR-0078). Its body names each matched path and why the change is safe.

- A change to a pinned tool (`mise.toml`, `mise.lock`) changes what the
  publisher runs. See [design/tool-behavior.md](../design/tool-behavior.md).
- A new refusal or routing rule needs a test in `tests/run.sh`.
- A blocking review point needs a guard: a test that fails without the fix,
  or an `AGENTS.md` rule when no test can catch it, plus 1 record file in
  `.memory/corrections/` ([`.memory/README.md`](../../.memory/README.md)).

## Checks to run before a pull request

```sh
mise exec -- make verify
```

`README.md` follows core's
[README spec](https://github.com/frostyard/core/blob/main/docs/specs/readme.md)
for a package repository (kind `packaging`). Check it from a frostyard/core
checkout, which holds the checker:

```sh
node .agents/skills/frostyard-readme/scripts/check-readme.mjs /path/to/apt-publisher
```
