# apt-publisher contributor context

This repository is the single writer of Frostyard's APT metadata at
`repository.frostyard.org/debian`. aptly does the publishing; bash scripts in
`scripts/` hold the policy; GitHub workflows call them. The README explains
the flow and [ADR-0001](docs/adr/0001-aptly-single-writer.md) the decision.

## Invariants

- Only workflows in the `apt-repository` concurrency group (with
  `queue: max`) write the bucket or the state bucket. Do not add another
  writer; `tests/check-config.sh` enforces the group settings.
- Validation runs before any state change. `publish.sh` refuses unknown
  producers, foreign package names, disallowed codenames or architectures,
  and mismatched `~debNN` markers.
- Nothing deletes pool files. Keep `-skip-cleanup` on every switch; deletion
  would be a separate, explicit decision.
- `reconcile_state` must run before any change in every path that can
  publish, and publications go through `commit_publications` (pending marker,
  save, publish, clear, save). Only `switch.sh --force` skips reconciliation.
- The move (`scripts/move.sh`) goes through `reconcile_state` and
  `commit_publications` like every publishing path, and `switch.sh` refuses
  snapshots that contradict a registration (core ADR-0059): a move is
  reverted by a forward change, never by a rollback. It writes a move
  marker (`txn/move-<codename>`, with the snapshot names and the plan) and
  saves it before it moves any repository, and removes it only after the
  deep read-back; `reconcile_state` settles it (drops it when the move is
  visible, undoes it when not), so a later single-component publication
  never strands a move. `registered_component` dies when the producers file
  is unreadable.
- Rollback rebuilds the working repository from the snapshot (`rebuild_repo`);
  otherwise the next publication would restore what was rolled back.
- A codename publishes the components in `config/codenames.tsv` (`main`, or
  `main,image`; core ADR-0059). A package name lives in one component per
  codename: `publish.sh` refuses a name that the other component already has.
- A published codename that lacks a configured component gets it, empty,
  from the next publication run (`publish source add` + `publish update`, one
  signed `Release`), also from a publish run that does not target it.
  `publish switch` cannot add a component; removing one is refused.
- `main` keeps its names: repository `frostyard-<codename>`, snapshot
  `<codename>-<time>-<label>`, marker `txn/pending-<codename>`, and the same
  aptly commands. Only `image` adds `-image` to them. Do not change the
  `main` path for a main-only codename.
- Check snapshot existence with `snapshot_exists`, not `aptly snapshot show`,
  which fails once a snapshot's source repository has been rebuilt.
- Secrets arrive only through the environment (`R2_*`, `APT_SIGNING_KEY`,
  `CLOUDFLARE_*`, `GH_TOKEN`). Never write them to `aptly.conf` or logs.
- Request values (`repo`, `tag`, `codenames`) reach scripts through `env:`,
  never through `${{ }}` inside `run:`.

## Gates

`make verify` runs shellcheck, actionlint, `tests/check-config.sh` and the
end-to-end `tests/run.sh`. Tools are pinned in `mise.toml`. Add a test to
`tests/run.sh` for every new refusal or routing rule.
