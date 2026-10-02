#!/usr/bin/env bash
# Check the apt-repository environment's secrets without publishing, after
# setting or rotating one. Runs every check, prints "ok -" or "FAIL -" per
# secret, and exits 1 if any failed.
#
#   APT_SIGNING_KEY  is APT_SIGNING_KEY_FPR, signs without a passphrase, and
#                    its signature verifies with APT_KEYRING.
#   R2_*             can list APT_BUCKET and APT_STATE_BUCKET. Read-only: a
#                    token without write access passes here and fails on the
#                    first publication.
#   CLOUDFLARE_*     can purge one index URL under APT_PUBLIC_URL from the
#                    zone, which only costs a cache miss.
#   GH_TOKEN         (DISPATCH_TOKEN) can dispatch to every notify repository.
#                    It sends event type apt-publisher-token-check, which
#                    starts nothing in a repository whose repository_dispatch
#                    triggers filter on types (snosi's accept only build).

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require gpg gpgv rclone curl jq gh
api=https://api.cloudflare.com/client/v4
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
failed=0

pass() { printf 'ok - %s\n' "$1"; }
fail() {
	printf 'FAIL - %s: %s\n' "$1" "$2"
	failed=1
}

# --- signing key ------------------------------------------------------------

if ! "$ROOT/scripts/import-signing-key.sh" 2>"$tmp/err"; then
	fail APT_SIGNING_KEY "$(cat "$tmp/err")"
elif ! echo "apt-publisher secrets check" |
	gpg --batch --pinentry-mode error --local-user "$APT_SIGNING_KEY_FPR" --clearsign \
		>"$tmp/signed" 2>"$tmp/err"; then
	fail APT_SIGNING_KEY "cannot sign without a passphrase: $(cat "$tmp/err")"
elif ! gpgv --keyring "$APT_KEYRING" "$tmp/signed" 2>"$tmp/err"; then
	fail APT_SIGNING_KEY "its signature does not verify with $APT_KEYRING"
else
	pass "APT_SIGNING_KEY signs as $APT_SIGNING_KEY_FPR"
fi

# --- R2 ---------------------------------------------------------------------

if ! (r2_env) 2>"$tmp/err"; then
	fail 'R2_*' "$(cat "$tmp/err")"
else
	r2_env
	for bucket in "$APT_BUCKET" "$APT_STATE_BUCKET"; do
		if rclone lsf --retries 1 --low-level-retries 1 "r2:$bucket" >/dev/null 2>"$tmp/err"; then
			pass "R2 credentials can list $bucket"
		else
			fail 'R2_*' "cannot list $bucket: $(tail -1 "$tmp/err")"
		fi
	done
fi

# --- Cloudflare -------------------------------------------------------------

cf() { curl -sS --retry 3 -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "$@"; }
cf_errors() { jq -r '[.errors[]?.message] | join("; ")' "$1" 2>/dev/null; }

if [[ -z ${CLOUDFLARE_ZONE:-} || -z ${CLOUDFLARE_API_TOKEN:-} ]]; then
	fail 'CLOUDFLARE_*' "CLOUDFLARE_ZONE and CLOUDFLARE_API_TOKEN are required"
else
	codename=$(awk -F'\t' '!/^#/ && NF { print $1; exit }' "$APT_CODENAMES_FILE")
	jq -n --arg url "$APT_PUBLIC_URL/dists/$codename/InRelease" '{files: [$url]}' |
		cf -X POST -H 'Content-Type: application/json' --data @- \
			"$api/zones/$CLOUDFLARE_ZONE/purge_cache" >"$tmp/purge.json" || true
	if jq -e '.success' "$tmp/purge.json" >/dev/null 2>&1; then
		pass "CLOUDFLARE_API_TOKEN can purge the CLOUDFLARE_ZONE zone"
	else
		# Tell a bad token from a wrong zone or a missing permission. User
		# tokens verify under /user, account tokens under /accounts.
		cf "$api/user/tokens/verify" >"$tmp/verify.json" || true
		status=$(jq -r '.result.status // empty' "$tmp/verify.json" 2>/dev/null || true)
		if [[ -z $status && -n ${R2_ACCOUNT_ID:-} ]]; then
			cf "$api/accounts/$R2_ACCOUNT_ID/tokens/verify" >"$tmp/verify.json" || true
			status=$(jq -r '.result.status // empty' "$tmp/verify.json" 2>/dev/null || true)
		fi
		fail 'CLOUDFLARE_*' "purge failed ($(cf_errors "$tmp/purge.json")); token status: ${status:-not a valid token}"
	fi
fi

# --- DISPATCH_TOKEN ---------------------------------------------------------

targets=$(awk -F'\t' '!/^#/ && NF && $5 != "-" { print $5 }' "$APT_PRODUCERS_FILE" | tr , '\n' | sort -u)
if [[ -z ${GH_TOKEN:-} ]]; then
	# Without it, gh would fall back to whoever is logged in.
	fail DISPATCH_TOKEN "GH_TOKEN (DISPATCH_TOKEN) is required"
else
	for target in $targets; do
		if gh api --method POST "repos/$target/dispatches" -f event_type=apt-publisher-token-check \
			>/dev/null 2>"$tmp/err"; then
			pass "DISPATCH_TOKEN can dispatch to $target"
		else
			fail DISPATCH_TOKEN "cannot dispatch to $target: $(cat "$tmp/err")"
		fi
	done
fi

exit "$failed"
