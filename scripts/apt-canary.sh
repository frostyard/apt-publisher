#!/usr/bin/env bash
# Install-path canary: point a sandboxed apt (no root, no system state) at
# APT_PUBLIC_URL, run apt-get update, and download each package with
# apt-get download, so apt itself checks the signature, the indexes and the
# package hashes through the public delivery path (CDN included).
#
#   apt-canary.sh CODENAME[/COMPONENT] ARCH NAME=VERSION...   (component: main)
#   apt-canary.sh --report FILE      rows of "codename name version arch component"
#
# arch:all packages are fetched with an amd64 apt configuration.
#
# This script owns the whole retry policy (apt's own Acquire::Retries is 0, so
# every try is counted and logged). Tunables, read from the environment:
#   APT_CANARY_TIMEOUT  apt http/https timeout, seconds, at least 1, connect and data (120)
#   APT_CANARY_TRIES    tries per apt-get command, at least 1 (4)
#   APT_CANARY_DELAY    seconds; the sleep before try n+1 is DELAY*n (30)
# Retried: apt-get update on any failure (a stale index right after the CDN
# purge is the known cause), and apt-get download only on a transient network
# error (see transient). Never retried: a 404, a hash or size mismatch, a bad
# signature on download, an unknown version; they fail at once with the log.
# Before the first download try of each package, a curl warm-up fetches the
# URL once and logs HTTP code, time, size and cf-cache-status. It is only a
# diagnostic: it never decides pass or fail.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require apt-get curl

# tunable NAME DEFAULT MIN prints the value of environment variable NAME.
tunable() {
	local v=${!1-$2}
	if [[ ! $v =~ ^[0-9]+$ ]] || ((10#$v < $3)); then
		die "$1 must be an integer >= $3 (got: $v)"
	fi
	printf '%d\n' "$((10#$v))"
}
timeout=$(tunable APT_CANARY_TIMEOUT 120 1)
tries=$(tunable APT_CANARY_TRIES 4 1)
delay=$(tunable APT_CANARY_DELAY 30 0)

# transient LOG succeeds when the apt log shows a network error that can pass
# on its own: a timeout, a connect, resolve or reset failure, or an HTTP 5xx
# (Cloudflare 520-530 included) in an Err: or E: Failed to fetch line. A 404,
# a hash or size mismatch and the like are not transient.
transient() {
	grep -Eq 'Connection timed out|Could not connect|Connection failed|Temporary failure resolving|Could not resolve|Connection reset|Undetermined Error' "$1" && return 0
	# Drop the URL and the [IP: ...] part, so that a 5xx in a name or an address is not a status.
	grep -E '^(Err:|E: Failed to fetch)' "$1" |
		sed -E 's/\[IP: [^]]*\]//; s#[A-Za-z0-9+.-]+://[^ ]*##' |
		grep -Eq '(^|[[:space:]])5[0-9]{2}([[:space:]]|$)'
}

# warm_up DIR OPTS... SPEC logs how the CDN serves the package URL. It never fails.
warm_up() {
	local d=$1 spec=${!#} uri out code time size cache
	uri=$(cd "$d/download" && apt-get "${@:2:$#-2}" -q --print-uris download "$spec" 2>/dev/null |
		sed -n "s/^'\([^']*\)'.*/\1/p" | head -n 1) || uri=''
	if [[ -z $uri ]]; then
		log "canary warm-up $spec: no URL"
		return 0
	fi
	: >"$d/warm.hdr"
	out=$(curl -sS -o /dev/null --max-time 300 --speed-limit 1 --speed-time 120 -D "$d/warm.hdr" \
		-w '%{http_code} %{time_total} %{size_download}' "$uri" 2>"$d/warm.err") || log "canary warm-up curl failed: $(cat "$d/warm.err")"
	read -r code time size <<<"$out" || true
	cache=$(awk -F': *' 'tolower($1) == "cf-cache-status" { gsub(/\r/, "", $2); v = $2 } END { print v }' "$d/warm.hdr") || cache=''
	log "canary warm-up $uri: HTTP ${code:-000}, ${time:-0}s, ${size:-0} bytes, cf-cache-status ${cache:--}"
}

# canary CODENAME[/COMPONENT] ARCH NAME=VERSION...
canary() {
	local arch=$2 codename component=main target
	codename=${1%%/*}
	[[ $1 != */* ]] || component=${1#*/}
	[[ $component =~ ^[a-z0-9]+$ ]] || die "invalid component $component"
	# main is the default and stays out of the messages.
	target=$codename
	[[ $component == main ]] || target+=/$component
	shift 2
	local d opts spec
	d=$(mktemp -d)
	mkdir -p "$d/etc/sources.list.d" "$d/etc/apt.conf.d" "$d/etc/preferences.d" \
		"$d/state/lists/partial" "$d/cache/archives/partial" "$d/download"
	: >"$d/state/status"
	printf 'Types: deb\nURIs: %s/\nSuites: %s\nComponents: %s\nSigned-By: %s\n' \
		"$APT_PUBLIC_URL" "$codename" "$component" "$APT_KEYRING" >"$d/etc/sources.list.d/canary.sources"
	opts=(-o "Dir::Etc=$d/etc" -o Dir::Etc::sourcelist=/dev/null
		-o "Dir::Etc::sourceparts=$d/etc/sources.list.d" -o "Dir::State=$d/state"
		-o "Dir::State::status=$d/state/status" -o "Dir::Cache=$d/cache"
		-o Debug::NoLocking=1 -o "APT::Architecture=$arch" -o "APT::Architectures::=$arch"
		-o "APT::Sandbox::User=$(id -un)"
		-o Acquire::Retries=0 -o "Acquire::http::Timeout=$timeout" -o "Acquire::https::Timeout=$timeout")
	local try=1 first pause
	while :; do
		if apt-get "${opts[@]}" -q update >"$d/update.log" 2>&1 && ! grep -q '^[WE]:' "$d/update.log"; then
			break
		fi
		((try < tries)) || die "apt-get update of $target/$arch failed (try $try of $tries): $(cat "$d/update.log")"
		first=$(grep -m1 '^[WE]:' "$d/update.log" || tail -n 1 "$d/update.log")
		pause=$((delay * try))
		log "canary: apt-get update of $target/$arch failed (try $try of $tries): $first; retrying in ${pause}s"
		sleep "$pause"
		try=$((try + 1))
	done
	for spec in "$@"; do
		warm_up "$d" "${opts[@]}" "$spec" || true
		try=1
		while :; do
			if (cd "$d/download" && apt-get "${opts[@]}" -q download "$spec") >"$d/download.log" 2>&1; then
				break
			fi
			if ! transient "$d/download.log" || ((try >= tries)); then
				die "apt-get download $spec from $target/$arch failed (try $try of $tries): $(cat "$d/download.log")"
			fi
			first=$(grep -m1 '^E:' "$d/download.log" || tail -n 1 "$d/download.log")
			pause=$((delay * try))
			log "canary: apt-get download $spec from $target/$arch failed (try $try of $tries): $first; retrying in ${pause}s"
			sleep "$pause"
			try=$((try + 1))
		done
	done
	rm -rf -- "$d"
	log "canary $target/$arch: $*"
}

if [[ ${1:-} == --report ]]; then
	[[ -f ${2:-} ]] || die "usage: apt-canary.sh --report FILE"
	# One apt configuration per codename, component and architecture. Rows
	# without a fifth column are main.
	while read -r codename component arch; do
		mapfile -t specs < <(awk -F'\t' -v c="$codename" -v k="$component" -v a="$arch" \
			'$1 == c && ($5 == "" ? "main" : $5) == k && ($4 == a || ($4 == "all" && a == "amd64")) { print $2 "=" $3 }' "$2" | sort -u)
		canary "$codename/$component" "$arch" "${specs[@]}"
	done < <(awk -F'\t' '{ print $1, ($5 == "" ? "main" : $5), ($4 == "all" ? "amd64" : $4) }' "$2" | sort -u)
	exit 0
fi

(($# >= 3)) || die "usage: apt-canary.sh CODENAME[/COMPONENT] ARCH NAME=VERSION... | --report FILE"
canary "$@"
