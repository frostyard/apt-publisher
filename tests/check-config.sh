#!/usr/bin/env bash
# Static, credential-free checks of the committed configuration.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Read the committed defaults, not whatever the caller's environment sets.
unset "${!APT_@}"
. "$ROOT/config/publisher.conf"

fail() {
	printf 'not ok - %s\n' "$*" >&2
	exit 1
}

fpr=$(gpg --show-keys --with-colons "$APT_KEYRING" | awk -F: '/^fpr/ { print $10; exit }')
[[ $fpr == "$APT_SIGNING_KEY_FPR" ]] ||
	fail "keys/frostyard.gpg ($fpr) is not APT_SIGNING_KEY_FPR ($APT_SIGNING_KEY_FPR)"

awk -F'\t' '!/^#/ && NF {
	if (NF != 3 || $2 !~ /^[0-9]+$/ || $3 !~ /^[a-z0-9]+(,[a-z0-9]+)*$/) { print "codenames.tsv line " NR ": malformed"; bad = 1 }
	if (seen[$2]++) { print "codenames.tsv line " NR ": duplicate Debian major " $2; bad = 1 }
} END { exit bad }' "$APT_CODENAMES_FILE" >&2 || fail "codenames.tsv"

codenames=$(awk -F'\t' '!/^#/ && NF { print $1 }' "$APT_CODENAMES_FILE")
awk -F'\t' -v known="$(tr '\n' , <<<"$codenames")" '!/^#/ && NF {
	if (NF != 5) { print "producers.tsv line " NR ": expected 5 tab-separated columns"; bad = 1; next }
	if ($1 !~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/) { print "producers.tsv line " NR ": bad repository " $1; bad = 1 }
	if ($4 != "yes" && $4 != "no") { print "producers.tsv line " NR ": attested must be yes or no"; bad = 1 }
	n = split($3, cs, ",")
	for (i = 1; i <= n; i++) if (index("," known, "," cs[i] ",") == 0) { print "producers.tsv line " NR ": unknown codename " cs[i]; bad = 1 }
	if (seen[$1]++) { print "producers.tsv line " NR ": duplicate producer " $1; bad = 1 }
} END { exit bad }' "$APT_PRODUCERS_FILE" >&2 || fail "producers.tsv"

# Every workflow that can reach the writer's credentials (the apt-repository
# environment) queues in the one writer group, keeping up to 100 pending runs
# instead of GitHub's default of one. The writers must be among them.
uses_env() { grep -q '^ *environment: apt-repository$' "$1"; }
for workflow in publish import-stable rollback withdraw; do
	uses_env "$ROOT/.github/workflows/$workflow.yml" ||
		fail "$workflow.yml must use the apt-repository environment"
done
for f in "$ROOT"/.github/workflows/*.yml; do
	uses_env "$f" || continue
	block=$(awk '/^concurrency:/ { c = 1; next } c && /^[^ ]/ { c = 0 } c' "$f")
	for line in 'group: apt-repository' 'cancel-in-progress: false' 'queue: max'; do
		grep -qx "  $line" <<<"$block" ||
			fail "$(basename "$f") concurrency must set $line (one queued writer group)"
	done
done

echo "ok - configuration"
