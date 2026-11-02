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

# Hosts install the file as it is (core ADR-0059): a binary keyring.
if grep -q 'BEGIN PGP' "$APT_KEYRING"; then
	fail "keys/frostyard.gpg is ASCII-armored; it must be a binary keyring"
fi

awk -F'\t' '!/^#/ && NF {
	if (NF != 4 || $2 !~ /^[0-9]+$/ || $3 !~ /^[a-z0-9]+(,[a-z0-9]+)*$/) { print "codenames.tsv line " FNR ": expected 4 columns: codename, Debian major, architectures, components"; bad = 1; next }
	if ($4 != "main" && $4 != "main,image") { print "codenames.tsv line " FNR ": components must be main or main,image"; bad = 1 }
	if (seen[$2]++) { print "codenames.tsv line " FNR ": duplicate Debian major " $2; bad = 1 }
} END { exit bad }' "$APT_CODENAMES_FILE" >&2 || fail "codenames.tsv"

# producers.tsv: 6 columns, the last one the component, which every codename
# the producer lists must publish (read from codenames.tsv, the first file).
awk -F'\t' 'FILENAME == codenames { if (!/^#/ && NF) comps[$1] = $4; next }
!/^#/ && NF {
	if (NF != 6) { print "producers.tsv line " FNR ": expected 6 tab-separated columns"; bad = 1; next }
	if ($1 !~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/) { print "producers.tsv line " FNR ": bad repository " $1; bad = 1 }
	if ($4 != "yes" && $4 != "no") { print "producers.tsv line " FNR ": attested must be yes or no"; bad = 1 }
	if ($6 != "main" && $6 != "image") { print "producers.tsv line " FNR ": component must be main or image"; bad = 1; next }
	n = split($3, cs, ",")
	for (i = 1; i <= n; i++) {
		if (!(cs[i] in comps)) { print "producers.tsv line " FNR ": unknown codename " cs[i]; bad = 1 }
		else if (index("," comps[cs[i]] ",", "," $6 ",") == 0) { print "producers.tsv line " FNR ": " cs[i] " does not publish component " $6; bad = 1 }
	}
	if (seen[$1]++) { print "producers.tsv line " FNR ": duplicate producer " $1; bad = 1 }
} END { exit bad }' codenames="$APT_CODENAMES_FILE" "$APT_CODENAMES_FILE" "$APT_PRODUCERS_FILE" >&2 || fail "producers.tsv"

# withdrawals/: the batch files withdraw.sh reads, one "NAME VERSION [ARCH]"
# request row per line. The rows keep the shapes of the aptly query
# withdraw.sh builds (the same regular expressions), and no row repeats, so
# that a batch is what it looks like before anyone runs it.
for file in "$ROOT"/withdrawals/*; do
	[[ -e $file ]] || continue
	# awk prints one line per problem and exits 0, so that a real awk
	# failure stays a failure of this check.
	problem=$(awk '
		/^[[:space:]]*(#|$)/ { next }
		{
			if (NF < 2 || NF > 3) { print "line " FNR ": expected NAME VERSION [ARCH], got " NF " fields"; next }
			if ($1 !~ /^[a-z0-9][a-z0-9.+-]*$/) { print "line " FNR ": invalid package name " $1 }
			if ($2 !~ /^[A-Za-z0-9.+~:-]+$/) { print "line " FNR ": invalid version " $2 }
			if (NF == 3 && $3 !~ /^[a-z0-9]+$/) { print "line " FNR ": invalid architecture " $3 }
			key = $1 SUBSEP $2 SUBSEP $3
			if (seen[key]++) { print "line " FNR ": duplicate request " $1 " " $2 " " $3 }
		}' "$file")
	[[ -z $problem ]] || fail "withdrawals/$(basename "$file") ${problem%%$'\n'*}"
done

# Every workflow that can reach the writer's credentials (the apt-repository
# environment) queues in the one writer group, keeping up to 100 pending runs
# instead of GitHub's default of one. The writers must be among them.
uses_env() { grep -q '^ *environment: apt-repository$' "$1"; }
for workflow in publish import-stable rollback withdraw move; do
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

# Every workflow runs its steps with bash -eo pipefail: GitHub's implicit
# shell has no pipefail, so `script | tee` would hide a failed script.
for f in "$ROOT"/.github/workflows/*.yml; do
	# Blank and comment lines neither end the block nor count in it.
	block=$(awk '/^defaults:/ { d = 1; next } /^[[:space:]]*(#|$)/ { next } d && /^[^ ]/ { d = 0 } d' "$f")
	grep -qx '    shell: bash' <<<"$block" ||
		fail "$(basename "$f") must set defaults.run.shell: bash (pipefail)"
done

echo "ok - configuration"
