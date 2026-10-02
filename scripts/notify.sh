#!/usr/bin/env bash
# Send a `build` repository_dispatch to each repository the producer lists
# in its notify column. Runs only after a successful publish, so downstream
# builds always see the new packages.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

[[ $# == 1 ]] || {
	echo "usage: notify.sh OWNER/REPO" >&2
	exit 2
}
require gh
notify=$(producer_field "$1" 5) || die "$1 is not a registered producer"
[[ $notify != - ]] || exit 0

IFS=, read -ra targets <<<"$notify"
for target in "${targets[@]}"; do
	gh api --method POST "repos/$target/dispatches" -f event_type=build >/dev/null
	log "dispatched build to $target"
done
