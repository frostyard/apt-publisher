#!/usr/bin/env bash
# End-to-end test of the publisher against a local S3 server (rclone serve
# s3) and a throwaway signing key. Each script runs with a fresh APTLY_ROOT,
# as on a new CI runner, so aptly state survives only through the state
# bucket. apt itself consumes the published result.
#
# KEEP_TMP=1 keeps the work directory for inspection.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
for tool in aptly rclone jq gpg gpgv gpgconf dpkg-deb apt-get apt-cache curl python3 sha256sum gzip xz; do
	command -v "$tool" >/dev/null || {
		echo "not ok - $tool is required" >&2
		exit 1
	}
done

tmp=$(mktemp -d)
server_pid=''
http_pid=''
cleanup() {
	[[ -n $server_pid ]] && kill "$server_pid" 2>/dev/null
	[[ -n $http_pid ]] && kill "$http_pid" 2>/dev/null
	GNUPGHOME=$tmp/gnupg gpgconf --kill gpg-agent 2>/dev/null || true
	if [[ -n ${KEEP_TMP:-} ]]; then
		echo "kept $tmp" >&2
	else
		rm -rf -- "$tmp"
	fi
}
trap cleanup EXIT

# The canary tests run without the pause between tries.
export APT_CANARY_DELAY=0

n=0
ok() {
	n=$((n + 1))
	printf 'ok %d - %s\n' "$n" "$1"
}
not_ok() {
	printf 'not ok - %s\n' "$1" >&2
	exit 1
}
check() {
	local desc=$1
	shift
	"$@" || not_ok "$desc"
	ok "$desc"
}
# must_fail DESC PATTERN CMD... expects CMD to fail with PATTERN on stderr.
must_fail() {
	local desc=$1 pattern=$2
	shift 2
	if "$@" >"$tmp/out" 2>"$tmp/err"; then
		not_ok "$desc (unexpectedly succeeded)"
	fi
	grep -q -- "$pattern" "$tmp/err" || {
		cat "$tmp/err" >&2
		not_ok "$desc (stderr lacks: $pattern)"
	}
	ok "$desc"
}
# must_pass DESC CMD... runs CMD, keeping stdout in $tmp/out and stderr in
# $tmp/err.
must_pass() {
	local desc=$1
	shift
	"$@" >"$tmp/out" 2>"$tmp/err" || {
		cat "$tmp/err" >&2
		not_ok "$desc"
	}
	ok "$desc"
}

# --- fixtures ---------------------------------------------------------------

port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
mkdir -p "$tmp/s3/frostyardrepo" "$tmp/s3/frostyard-apt-state"
# Keep rclone's default directory cache: with --dir-cache-time 0s, serve s3
# intermittently livelocks on uploads into new nested prefixes. Every change
# in this test goes through the S3 API, so the cache never goes stale.
rclone serve s3 --addr "127.0.0.1:$port" --auth-key testaccesskey,testsecretkey123 \
	"$tmp/s3" >"$tmp/s3.log" 2>&1 &
server_pid=$!
for _ in $(seq 50); do
	curl -s -o /dev/null "http://127.0.0.1:$port/" && break
	sleep 0.1
done

export GNUPGHOME=$tmp/gnupg
mkdir -m 700 "$GNUPGHOME"
for uid in 'apt-publisher test <test@invalid>' 'someone else <other@invalid>'; do
	gpg -q --batch --passphrase '' --quick-gen-key "$uid" ed25519 sign never 2>/dev/null
done
gpg -q --check-trustdb 2>/dev/null
mapfile -t fprs < <(gpg --list-keys --with-colons | awk -F: '/^fpr/ { print $10 }')
gpg --export "${fprs[0]}" >"$tmp/test-key.gpg"
gpg --export "${fprs[1]}" >"$tmp/other-key.gpg"

cat >"$tmp/producers.tsv" <<'EOF'
frostyard/updex	frostyard-updex	trixie,forky	release.yml@refs/tags/v*	frostyard/snosi	main
frostyard/bootc-debian	bootc,libostree-*	trixie,forky	no	-	main
frostyard/trixie-only	trixie-thing	trixie	no	-	main
frostyard/incus	incus,incus-base,incus-client,incus-extra,incus-ui-canonical	trixie	no	frostyard/snosi	main
EOF
# Producers registered for the image component (core ADR-0059), added to the
# main ones. Only the component tests use this file.
cp "$tmp/producers.tsv" "$tmp/producers-image.tsv"
cat >>"$tmp/producers-image.tsv" <<'EOF'
frostyard/image-only	imgpkg	trixie,forky	no	-	image
frostyard/bootc-image	bootc,libostree-1-1	trixie,forky	no	-	image
frostyard/docs-image	docs-thing	trixie,forky	no	-	image
EOF
# Codenames that publish both components, as config/codenames.tsv does. Only
# the image sections use this file.
printf 'trixie\t13\tamd64,arm64,all\tmain,image\nforky\t14\tamd64,arm64,all\tmain,image\n' >"$tmp/codenames-image.tsv"
# Codenames that publish main only, as every codename did before ADR-0059
# step 3. Every section before "the image component" runs with this file, so
# that path stays proven.
printf 'trixie\t13\tamd64,arm64,all\tmain\nforky\t14\tamd64,arm64,all\tmain\n' >"$tmp/codenames-main.tsv"

# Fail instead of hanging if the local server stalls.
export RCLONE_TIMEOUT=30s RCLONE_CONTIMEOUT=10s
: >"$tmp/rclone.conf"
export RCLONE_CONFIG=$tmp/rclone.conf
export R2_ACCESS_KEY_ID=testaccesskey R2_SECRET_ACCESS_KEY=testsecretkey123
export APT_S3_ENDPOINT=http://127.0.0.1:$port APT_RCLONE_PROVIDER=Other
export APT_SIGNING_KEY_FPR=${fprs[0]} APT_KEYRING=$tmp/test-key.gpg
export APT_PRODUCERS_FILE=$tmp/producers.tsv
export APT_CODENAMES_FILE=$tmp/codenames-main.tsv
unset R2_ACCOUNT_ID APTLY_ROOT
export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Other RCLONE_CONFIG_R2_ENDPOINT=$APT_S3_ENDPOINT
export RCLONE_CONFIG_R2_ACCESS_KEY_ID=testaccesskey RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=testsecretkey123

# scope NAME isolates a scenario under its own bucket prefix and state path.
# The public URL is the bucket's directory on disk.
scope() {
	export APT_PREFIX=$1 APT_STATE_PATH=$1
	pub=$tmp/s3/frostyardrepo/$1
	export APT_PUBLIC_URL=file://$pub
}
scope debian

# run SCRIPT ARGS... runs a publisher script as a fresh runner.
run() { APTLY_ROOT=$(mktemp -d "$tmp/runner.XXXXXX") "$ROOT/scripts/$1" "${@:2}"; }

# mkdeb DIR NAME VERSION ARCH [CONTENT] builds DIR/NAME_VERSION_ARCH.deb, with
# the epoch left out of the file name as Debian does. MKDEB_CONTROL adds one
# control line (for example a Provides: line).
mkdeb() {
	local dir=$1 name=$2 version=$3 arch=$4 src
	src=$(mktemp -d "$tmp/build.XXXXXX")
	mkdir -p "$src/DEBIAN" "$src/usr/share/doc/$name" "$dir"
	printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: test <test@invalid>\nDescription: test package\n' \
		"$name" "$version" "$arch" >"$src/DEBIAN/control"
	if [[ -n ${MKDEB_CONTROL:-} ]]; then
		printf '%s\n' "$MKDEB_CONTROL" >>"$src/DEBIAN/control"
	fi
	printf '%s\n' "${5:-$name $version $arch}" >"$src/usr/share/doc/$name/content"
	dpkg-deb --root-owner-group -b "$src" "$dir/${name}_${version#*:}_${arch}.deb" >/dev/null
}

# Legacy repogen-shaped suite: dists/stable with binary-all and binary-amd64.
make_legacy() {
	local legacy=$1 deb name arch letter dir rel
	for deb in "$tmp"/legacy-debs/*.deb; do
		name=$(dpkg-deb -f "$deb" Package)
		arch=$(dpkg-deb -f "$deb" Architecture)
		letter=${name:0:1}
		[[ $name == lib* ]] && letter=${name:0:4}
		dir=pool/main/$letter/$name
		mkdir -p "$legacy/$dir" "$legacy/dists/stable/main/binary-$arch"
		cp "$deb" "$legacy/$dir/"
		{
			dpkg-deb -f "$deb"
			printf 'Filename: %s/%s\nSize: %s\nSHA256: %s\n\n' "$dir" "$(basename "$deb")" \
				"$(stat -c %s "$deb")" "$(sha256sum <"$deb" | cut -d' ' -f1)"
		} >>"$legacy/dists/stable/main/binary-$arch/Packages"
	done
	{
		printf 'Origin: Repogen Repository\nLabel: Frostyard Repository\nSuite: stable\nCodename: stable\n'
		printf 'Architectures: all amd64\nComponents: main\nSHA256:\n'
		for rel in main/binary-all/Packages main/binary-amd64/Packages; do
			printf ' %s %s %s\n' "$(sha256sum <"$legacy/dists/stable/$rel" | cut -d' ' -f1)" \
				"$(stat -c %s "$legacy/dists/stable/$rel")" "$rel"
		done
	} >"$legacy/dists/stable/Release"
	gpg -q --batch --yes --local-user "${fprs[0]}" --clearsign \
		-o "$legacy/dists/stable/InRelease" "$legacy/dists/stable/Release"
}

# listed_in CODENAME COMPONENT NAME VERSION [ARCH]: the published indexes of
# that component on disk list it.
listed_in() {
	awk -v n="$3" -v v="$4" -v a="${5:-}" '
		BEGIN { RS = ""; FS = "\n" }
		{
			delete f
			for (i = 1; i <= NF; i++) if (match($i, /^[A-Za-z-]+: /)) f[substr($i, 1, RLENGTH - 2)] = substr($i, RLENGTH + 1)
			if (f["Package"] == n && f["Version"] == v && (a == "" || f["Architecture"] == a)) found = 1
		}
		END { exit !found }' "$pub/dists/$1/$2"/binary-*/Packages
}
not_listed_in() { ! listed_in "$@"; }
# listed CODENAME NAME VERSION [ARCH]: the same, for main.
listed() { listed_in "$1" main "${@:2}"; }
not_listed() { ! listed "$@"; }
# index_sum CODENAME COMPONENT: a hash of the component's published indexes.
index_sum() { cat "$pub/dists/$1/$2"/binary-*/Packages | sha256sum; }

# candidate CODENAME ARCH PACKAGE [COMPONENTS] prints apt's candidate version;
# COMPONENTS defaults to main.
candidate() {
	local d
	d=$(mktemp -d "$tmp/apt.XXXXXX")
	mkdir -p "$d/etc/sources.list.d" "$d/etc/apt.conf.d" "$d/etc/preferences.d" \
		"$d/state/lists/partial" "$d/cache/archives/partial"
	: >"$d/state/status"
	printf 'Types: deb\nURIs: file://%s\nSuites: %s\nComponents: %s\nSigned-By: %s\n' \
		"$pub" "$1" "${4:-main}" "$tmp/test-key.gpg" >"$d/etc/sources.list.d/test.sources"
	local opts=(-o "Dir::Etc=$d/etc" -o Dir::Etc::sourcelist=/dev/null
		-o "Dir::Etc::sourceparts=$d/etc/sources.list.d" -o "Dir::State=$d/state"
		-o "Dir::State::status=$d/state/status" -o "Dir::Cache=$d/cache"
		-o Debug::NoLocking=1 -o "APT::Architecture=$2" -o "APT::Architectures::=$2"
		-o "APT::Sandbox::User=$(id -un)")
	apt-get "${opts[@]}" -q update >"$d/update.log" 2>&1 || {
		cat "$d/update.log" >&2
		return 1
	}
	grep -q '^[WE]:' "$d/update.log" && {
		cat "$d/update.log" >&2
		return 1
	}
	apt-cache "${opts[@]}" policy "$3" | awk '/Candidate:/ { print $2 }'
}
candidate_is() { [[ $(candidate "$1" "$2" "$3" "${5:-}") == "$4" ]]; }

inrelease() { sha256sum <"$pub/dists/$1/InRelease"; }
pool_file() { find "$pub/pool" -name "$1" | head -1; }
# corrupt PATH replaces a bucket object below the current prefix.
corrupt() { printf 'corrupted bytes\n' | rclone rcat "r2:frostyardrepo/$APT_PREFIX/$1"; }

# A shim on PATH that fails the Nth save of a state path's database.
mkdir -p "$tmp/shim-rclone" "$tmp/shim-gh"
real_rclone=$(command -v rclone)
cat >"$tmp/shim-rclone/rclone" <<EOF
#!/usr/bin/env bash
if [[ \$1 == sync && \${*: -1} == r2:frostyard-apt-state/\$SHIM_STATE_PATH/db ]]; then
	count=\$(( \$(cat "$tmp/shim-rclone/count" 2>/dev/null || echo 0) + 1 ))
	echo "\$count" >"$tmp/shim-rclone/count"
	if [[ \$count == "\$SHIM_FAIL_AT" ]]; then
		echo "shim: simulated failure saving the database" >&2
		exit 1
	fi
fi
exec "$real_rclone" "\$@"
EOF
# gh release view --repo OWNER/REPO --json ... serves $tmp/gh/OWNER_REPO.json.
cat >"$tmp/shim-gh/gh" <<EOF
#!/usr/bin/env bash
[[ \$1 == release && \$2 == view ]] || exit 2
while ((\$#)); do
	[[ \$1 == --repo ]] && repo=\$2
	shift
done
f="$tmp/gh/\${repo//\//_}.json"
[[ -f \$f ]] || { echo "release not found" >&2; exit 1; }
cat "\$f"
EOF
# aptly whose snapshot list trickles out a line at a time and dies when the
# reader has gone, as aptly does on SIGPIPE: a check that stops reading at a
# match always closes the pipe while it is still writing.
mkdir -p "$tmp/shim-aptly"
real_aptly=$(command -v aptly)
cat >"$tmp/shim-aptly/aptly" <<EOF
#!/usr/bin/env bash
[[ " \$* " == *" snapshot list "* ]] || exec "$real_aptly" "\$@"
while IFS= read -r line; do
	printf '%s\n' "\$line" 2>/dev/null || exit 141
	sleep 0.01
done < <("$real_aptly" "\$@")
EOF
# aptly whose repository list fails.
mkdir -p "$tmp/shim-repolist"
cat >"$tmp/shim-repolist/aptly" <<EOF
#!/usr/bin/env bash
if [[ " \$* " == *" repo list "* ]]; then
	echo "ERROR: simulated repository list failure" >&2
	exit 1
fi
exec "$real_aptly" "\$@"
EOF
chmod +x "$tmp/shim-repolist/aptly" "$tmp/shim-rclone/rclone" "$tmp/shim-gh/gh" "$tmp/shim-aptly/aptly"
mkdir -p "$tmp/gh"

# --- dry run ------------------------------------------------------------------

# The committed configuration publishes both components (core ADR-0059);
# every section below runs with codenames-main.tsv instead.
check "the committed codenames publish main,image" \
	test "$(awk -F'\t' '!/^#/ && NF { print $1 "=" $4 }' "$ROOT/config/codenames.tsv" | paste -sd' ')" = \
	'trixie=main,image forky=main,image'

# The committed registrations (core ADR-0059 step 5): bootc-debian and incus
# route to image, every other producer to main.
check "the committed producers register bootc-debian and incus for image" \
	test "$(awk -F'\t' '!/^#/ && NF && $6 == "image" { print $1 }' "$ROOT/config/producers.tsv" | sort | paste -sd' ')" = \
	'frostyard/bootc-debian frostyard/incus'
mkdeb "$tmp/committed-bootc" bootc '1.16.8-1~deb13' amd64
mkdeb "$tmp/committed-bootc" libostree-1-1 '2026.3-1~deb13' amd64
must_pass "dry run of bootc-debian with the committed configuration" \
	env APT_PRODUCERS_FILE="$ROOT/config/producers.tsv" APT_CODENAMES_FILE="$ROOT/config/codenames.tsv" \
	"$ROOT/scripts/publish.sh" --producer frostyard/bootc-debian --debs "$tmp/committed-bootc" --dry-run
check "bootc routes to trixie/image" grep -q 'bootc_1.16.8-1~deb13_amd64.deb -> trixie/image' "$tmp/err"
check "libostree-1-1 routes to trixie/image" grep -q 'libostree-1-1_2026.3-1~deb13_amd64.deb -> trixie/image' "$tmp/err"
mkdeb "$tmp/committed-incus" incus '1:7.5.1-debian13-202610031200' amd64
must_pass "dry run of incus with the committed configuration" \
	env APT_PRODUCERS_FILE="$ROOT/config/producers.tsv" APT_CODENAMES_FILE="$ROOT/config/codenames.tsv" \
	"$ROOT/scripts/publish.sh" --producer frostyard/incus --debs "$tmp/committed-incus" --dry-run
check "incus routes to trixie/image" grep -q 'incus_7.5.1-debian13-202610031200_amd64.deb -> trixie/image' "$tmp/err"

mkdeb "$tmp/bootc" bootc '1.16.8-1~deb13' amd64
mkdeb "$tmp/bootc" bootc '1.16.8-1~deb14' amd64
must_pass "dry run succeeds" run publish.sh --producer frostyard/bootc-debian --debs "$tmp/bootc" --dry-run
check "dry run routes ~deb13 to trixie" grep -q 'bootc_1.16.8-1~deb13_amd64.deb -> trixie' "$tmp/err"
check "dry run routes ~deb14 to forky" grep -q 'bootc_1.16.8-1~deb14_amd64.deb -> forky' "$tmp/err"
check "dry run touches no state" test -z "$(ls -A "$tmp/s3/frostyard-apt-state")"

# An image producer cannot publish to a codename that does not publish image;
# the sections here run with a main-only codenames file.
mkdeb "$tmp/img-refused" imgpkg 1.0 amd64
must_fail "an image producer is refused, also in a dry run, for a main-only codename" \
	"trixie does not publish component image" \
	env APT_PRODUCERS_FILE="$tmp/producers-image.tsv" "$ROOT/scripts/publish.sh" \
	--producer frostyard/image-only --debs "$tmp/img-refused" --codenames trixie --dry-run
must_fail "an image producer is refused for a main-only codename" "does not publish component image" \
	env APT_PRODUCERS_FILE="$tmp/producers-image.tsv" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/image-only --debs "$tmp/img-refused"
check "the refusal touches no state" test -z "$(ls -A "$tmp/s3/frostyard-apt-state")"

# incus-style -debian13- is not a marker, so it goes to every target: why incus
# is registered for trixie only.
mkdeb "$tmp/unmarked" bootc '1:1.0-debian13-202610031200' amd64
must_pass "dry run of a -debian13- build" \
	run publish.sh --producer frostyard/bootc-debian --debs "$tmp/unmarked" --dry-run
check "-debian13- is not a codename marker" \
	grep -q 'bootc_1.0-debian13-202610031200_amd64.deb -> forky' "$tmp/err"

# --- import of the legacy suite -----------------------------------------------

mkdeb "$tmp/legacy-debs" frostyard-updex 2.0.0 amd64
mkdeb "$tmp/legacy-debs" frostyard-updex 2.0.1 amd64
mkdeb "$tmp/legacy-debs" docs-thing 1.0 all
mkdeb "$tmp/legacy-debs" libfoo1 1.0-1 amd64
mkdeb "$tmp/legacy-debs" incus '1:7.4-debian13-202609161516' amd64
make_legacy "$tmp/legacy"

cp -a "$tmp/legacy" "$tmp/legacy-tampered"
mkdeb "$tmp/evil" frostyard-updex 2.0.1 amd64 'tampered bytes'
cp "$tmp/evil/frostyard-updex_2.0.1_amd64.deb" "$tmp/legacy-tampered/pool/main/f/frostyard-updex/"
must_fail "import rejects a .deb that does not match its index" "wrong" \
	run import-stable.sh --codename trixie --base-url "file://$tmp/legacy-tampered" --download-only
must_fail "import rejects an InRelease signed by another key" "is not signed by" \
	env APT_KEYRING="$tmp/other-key.gpg" "$ROOT/scripts/import-stable.sh" \
	--codename trixie --base-url "file://$tmp/legacy" --work "$tmp/wrong-key" --download-only
must_fail "import requires a reviewed manifest to publish" "usage" \
	run import-stable.sh --codename trixie --base-url "file://$tmp/legacy"

legacy=(--codename trixie --base-url "file://$tmp/legacy" --work "$tmp/import-work")
must_pass "review run verifies the legacy suite" run import-stable.sh "${legacy[@]}" --download-only
manifest=$(cat "$tmp/out")
check "review run prints the manifest SHA256" grep -Eqx '[0-9a-f]{64}' <<<"$manifest"
check "review run touches no state" test -z "$(ls -A "$tmp/s3/frostyard-apt-state")"

must_fail "import refuses a manifest other than the reviewed one" "not the reviewed one" \
	run import-stable.sh "${legacy[@]}" --expect-manifest "$(printf '0%.0s' {1..64})"

# A leftover in the reused work directory is not in the signed indexes.
mkdeb "$tmp/import-work/pool/leftover" smuggled 6.6.6 amd64
must_pass "import publishes the reviewed manifest" run import-stable.sh "${legacy[@]}" --expect-manifest "$manifest"
import_snapshot=$(cut -d' ' -f2 "$tmp/out")
check "import publishes every legacy version" listed trixie frostyard-updex 2.0.0
check "import publishes the newest legacy version" listed trixie frostyard-updex 2.0.1
check "import keeps arch:all packages" listed trixie docs-thing 1.0
check "import keeps epoch versions" listed trixie incus '1:7.4-debian13-202609161516'
check "import ignores files outside the manifest" not_listed trixie smuggled 6.6.6
check "published suite is by-hash" grep -qx 'Acquire-By-Hash: yes' "$pub/dists/trixie/Release"
check "apt reads the imported suite" candidate_is trixie amd64 frostyard-updex 2.0.1

# --- producer publication -------------------------------------------------------

mkdeb "$tmp/updex" frostyard-updex 2.0.2 amd64
mkdeb "$tmp/updex" frostyard-updex 2.0.2 arm64
must_pass "publish updex 2.0.2" run publish.sh --producer frostyard/updex --debs "$tmp/updex" \
	--label updex-v2.0.2 --report "$tmp/report.tsv"
cp "$tmp/out" "$tmp/updex.out"
check "publish reports both codenames" test "$(cut -d' ' -f1 "$tmp/updex.out" | sort | tr '\n' ' ')" = 'forky trixie '
check "publish writes a report for the canary" grep -qxP 'forky\tfrostyard-updex\t2.0.2\tarm64\tmain' "$tmp/report.tsv"
check "trixie gains 2.0.2 and keeps the import" listed trixie frostyard-updex 2.0.2
check "trixie still lists 2.0.1" listed trixie frostyard-updex 2.0.1
check "forky is first-published with 2.0.2" listed forky frostyard-updex 2.0.2
check "forky does not inherit trixie's imports" not_listed forky frostyard-updex 2.0.1
check "apt on trixie/amd64 sees 2.0.2" candidate_is trixie amd64 frostyard-updex 2.0.2
check "apt on forky/arm64 sees 2.0.2" candidate_is forky arm64 frostyard-updex 2.0.2
check "both codenames share one pool file" \
	test "$(find "$pub/pool" -name 'frostyard-updex_2.0.2_amd64.deb' | wc -l)" = 1
must_pass "the canary installs the report through the public URL" run apt-canary.sh --report "$tmp/report.tsv"

must_pass "publish bootc" run publish.sh --producer frostyard/bootc-debian --debs "$tmp/bootc"
check "trixie gets the ~deb13 build" listed trixie bootc '1.16.8-1~deb13'
check "trixie does not get the ~deb14 build" not_listed trixie bootc '1.16.8-1~deb14'
check "forky gets the ~deb14 build" listed forky bootc '1.16.8-1~deb14'
check "apt on forky prefers ~deb14" candidate_is forky amd64 bootc '1.16.8-1~deb14'

# incus versions have an epoch, a UTC build time and -debian13-, which is not a
# codename marker. Its registration limits it to trixie.
incus_version='1:7.5.1-debian13-202610031200'
for name in incus incus-base incus-client incus-extra incus-ui-canonical; do
	mkdeb "$tmp/incus" "$name" "$incus_version" amd64
done
must_pass "publish an incus build" run publish.sh --producer frostyard/incus --debs "$tmp/incus" \
	--label incus-7.5.1-debian13-202610031200 --report "$tmp/incus-report.tsv"
check "incus routes to its registered codename" \
	grep -q 'incus_7.5.1-debian13-202610031200_amd64.deb -> trixie' "$tmp/err"
check "incus publishes trixie only" test "$(cut -d' ' -f1 "$tmp/out")" = trixie
check "trixie lists the new incus build" listed trixie incus-ui-canonical "$incus_version"
check "trixie keeps the imported incus build" listed trixie incus '1:7.4-debian13-202609161516'
check "forky gets no incus build" not_listed forky incus "$incus_version"
check "apt on trixie prefers the newer epoch version" candidate_is trixie amd64 incus "$incus_version"
must_pass "the canary downloads epoch versions" run apt-canary.sh --report "$tmp/incus-report.tsv"

# bootc-debian: trixie was seeded with unmarked builds; its releases now carry
# one build stamp and ~deb13, and GitHub serves their assets with . in place
# of ~. Routing and versions come from the packages, not the file names.
mkdeb "$tmp/bootc-seeded" bootc 1.16.8-frostyard202608140040 amd64
mkdeb "$tmp/bootc-seeded" libostree-1-1 2026.3-frostyard202608140040 amd64
must_pass "publish the seeded bootc-debian builds" run publish.sh --producer frostyard/bootc-debian \
	--debs "$tmp/bootc-seeded" --codenames trixie
bootc_rev=frostyard202610040130~deb13
mkdeb "$tmp/bootc-release" bootc "1.16.8-$bootc_rev" amd64
mkdeb "$tmp/bootc-release" libostree-1-1 "2026.3-$bootc_rev" amd64
for f in "$tmp"/bootc-release/*.deb; do mv "$f" "${f//\~/.}"; done
must_pass "publish a release with GitHub's asset names" run publish.sh --producer frostyard/bootc-debian \
	--debs "$tmp/bootc-release" --codenames trixie --report "$tmp/bootc-report.tsv"
check "renamed assets route by their ~deb13 versions" \
	grep -q 'libostree-1-1_2026.3-frostyard202610040130.deb13_amd64.deb -> trixie' "$tmp/err"
check "trixie lists the ~deb13 versions" listed trixie libostree-1-1 "2026.3-$bootc_rev"
check "trixie keeps the seeded build" listed trixie libostree-1-1 2026.3-frostyard202608140040
check "apt prefers the ~deb13 bootc to the seeded one" candidate_is trixie amd64 bootc "1.16.8-$bootc_rev"
check "apt prefers the ~deb13 libostree-1-1 to the seeded one" \
	candidate_is trixie amd64 libostree-1-1 "2026.3-$bootc_rev"
must_pass "the canary downloads ~deb13 versions" run apt-canary.sh --report "$tmp/bootc-report.tsv"

# --- refusals leave the published suite untouched ---------------------------------

before=$(inrelease trixie)

mkdeb "$tmp/hijack" bootc 9.9 amd64
must_fail "a producer cannot publish another producer's package" "may not publish package bootc" \
	run publish.sh --producer frostyard/updex --debs "$tmp/hijack"

mkdeb "$tmp/conflict" frostyard-updex 2.0.2 amd64 'different bytes, same version'
must_fail "republishing a version with different bytes fails" "failed to be added" \
	run publish.sh --producer frostyard/updex --debs "$tmp/conflict"

mkdeb "$tmp/forky-build" bootc '1.17.0-1~deb14' amd64
must_fail "a ~deb14 build cannot go to trixie" "not a target" \
	run publish.sh --producer frostyard/bootc-debian --debs "$tmp/forky-build" --codenames trixie

mkdeb "$tmp/trixie-only" trixie-thing 1.0 amd64
must_fail "a producer cannot publish outside its codenames" "may not publish to forky" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/trixie-only" --codenames forky

must_fail "an unregistered producer is refused" "not a registered producer" \
	run publish.sh --producer frostyard/stranger --debs "$tmp/updex"

mkdeb "$tmp/i386" frostyard-updex 2.0.3 i386
must_fail "an unpublished architecture is refused" "architecture i386" \
	run publish.sh --producer frostyard/updex --debs "$tmp/i386"

rclone move --quiet r2:frostyard-apt-state/debian r2:frostyard-apt-state/aside
mkdeb "$tmp/updex-next" frostyard-updex 2.0.3 amd64
must_fail "lost state never overwrites a published suite" "does not match aptly's database" \
	run publish.sh --producer frostyard/updex --debs "$tmp/updex-next"
rclone move --quiet r2:frostyard-apt-state/aside r2:frostyard-apt-state/debian

check "refusals left trixie unchanged" test "$(inrelease trixie)" = "$before"
must_pass "publishing resumes once state is back" run publish.sh --producer frostyard/updex --debs "$tmp/updex-next"
check "trixie lists the resumed publication" listed trixie frostyard-updex 2.0.3

# --- a publish that dies before becoming visible --------------------------------------

before=$(inrelease trixie)
mkdeb "$tmp/updex-signfail" frostyard-updex 2.0.4 amd64
must_fail "a signing failure aborts the publish" "unable to" \
	env APT_SIGNING_KEY_FPR=0000000000000000000000000000000000000000 \
	APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/updex --debs "$tmp/updex-signfail" --codenames trixie
check "the failed publish left InRelease unchanged" test "$(inrelease trixie)" = "$before"
mkdeb "$tmp/bootc-next" bootc '1.16.9-1~deb13' amd64
must_pass "the next producer's run drops the stale pending marker" \
	run publish.sh --producer frostyard/bootc-debian --debs "$tmp/bootc-next"
check "the next run publishes its own package" listed trixie bootc '1.16.9-1~deb13'
check "the next run also publishes the stranded package" listed trixie frostyard-updex 2.0.4

# --- point-in-time rollback -------------------------------------------------------------

must_pass "roll trixie back to the import" run switch.sh --codename trixie --snapshot "$import_snapshot"
check "rollback restores the imported versions" candidate_is trixie amd64 frostyard-updex 2.0.1
check "rollback unpublishes later packages" not_listed trixie bootc '1.16.9-1~deb13'
check "rollback deletes no pool files" test -n "$(pool_file 'frostyard-updex_2.0.3_amd64.deb')"
check "forky is untouched by a trixie rollback" listed forky frostyard-updex 2.0.2

must_pass "publish an unrelated package after the rollback" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/trixie-only"
check "the unrelated package is published" listed trixie trixie-thing 1.0
check "the rollback survives an unrelated publication" not_listed trixie frostyard-updex 2.0.3
check "rolled-back producers stay rolled back" not_listed trixie bootc '1.16.9-1~deb13'

must_pass "republishing a release rolls it forward" \
	run publish.sh --producer frostyard/updex --debs "$tmp/updex" --codenames trixie
check "the rolled-forward release is listed" listed trixie frostyard-updex 2.0.2 arm64
must_fail "switch refuses another codename's snapshot" "was not created for trixie" \
	run switch.sh --codename trixie --snapshot "$(grep '^forky ' "$tmp/updex.out" | cut -d' ' -f2)"

# --- withdraw ------------------------------------------------------------------------

must_pass "withdraw updex 2.0.2 from trixie" \
	run withdraw.sh --codename trixie --package frostyard-updex --version 2.0.2
check "trixie no longer lists 2.0.2" not_listed trixie frostyard-updex 2.0.2
check "withdraw keeps every other package" listed trixie trixie-thing 1.0
check "withdraw is per codename" listed forky frostyard-updex 2.0.2
check "withdraw deletes no pool files" test -n "$(pool_file 'frostyard-updex_2.0.2_amd64.deb')"

mkdeb "$tmp/trixie-only-next" trixie-thing 1.1 amd64
must_pass "publish an unrelated package after the withdrawal" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/trixie-only-next"
trixie_snapshot=$(cut -d' ' -f2 "$tmp/out")
check "the withdrawal survives an unrelated publication" not_listed trixie frostyard-updex 2.0.2

must_pass "withdraw one architecture" \
	run withdraw.sh --codename forky --package frostyard-updex --version 2.0.2 --arch arm64
check "forky keeps the other architecture" listed forky frostyard-updex 2.0.2 amd64
check "forky drops the withdrawn architecture" not_listed forky frostyard-updex 2.0.2 arm64
must_fail "withdrawing an unlisted version is refused" "has no" \
	run withdraw.sh --codename trixie --package frostyard-updex --version 9.9
must_fail "withdraw rejects a malformed package name" "invalid package name" \
	run withdraw.sh --codename trixie --package 'bad name' --version 1

# --- read-back verification and repair -----------------------------------------------

must_pass "verify accepts the published suite" \
	run verify.sh trixie trixie-thing=1.1 '!frostyard-updex=2.0.2'
must_fail "verify rejects a missing version" "does not list" run verify.sh trixie frostyard-updex=9.9
must_fail "verify rejects a version that should be gone" "still lists" \
	run verify.sh forky '!frostyard-updex=2.0.2'
must_pass "the canary installs from trixie" run apt-canary.sh trixie amd64 trixie-thing=1.1 frostyard-updex=2.0.1

corrupt "$(cd "$pub" && find pool -name 'trixie-thing_1.1_amd64.deb')"
must_pass "metadata-only verify cannot see a corrupted package" run verify.sh trixie
must_fail "verify checks a named package's bytes" "does not match its SHA256" \
	run verify.sh trixie trixie-thing=1.1
must_fail "deep verify finds the corrupted pool file" "MD5 mismatch" run verify.sh trixie --deep
must_fail "the canary refuses the corrupted package" "apt-get download trixie-thing=1.1" \
	run apt-canary.sh trixie amd64 trixie-thing=1.1
must_pass "switch --force repairs the pool file" \
	run switch.sh --codename trixie --snapshot "$trixie_snapshot" --force
must_pass "deep verify passes after the repair" run verify.sh trixie --deep
must_pass "the canary passes after the repair" run apt-canary.sh trixie amd64 trixie-thing=1.1

# --- canary retry policy over HTTP -----------------------------------------------------
#
# A copy of the published scope is served by a small handler. $tmp/http-ctl lists
# "SUBSTRING MODE N" rows: apt's first N GETs of a path with SUBSTRING get a 503
# (MODE 503) or stall for 4 s (MODE stall), which is longer than the timeout.
# apt reconnects once by itself after a timeout: a try needs two stalls to fail. The
# curl warm-up is never counted; MODE warmstall stalls only the warm-up, for
# 6 s. The first row is a sequence number: a new one resets the counters.
cp -r "$pub" "$tmp/http-pub"
cat >"$tmp/http-server.py" <<'EOF'
import functools, http.server, sys, threading, time

ctl, hits, lock = sys.argv[3], {}, threading.Lock()
seen = None

class Handler(http.server.SimpleHTTPRequestHandler):
	def do_GET(self):
		global seen
		rows = []
		try:
			with open(ctl) as f:
				rows = f.read().splitlines()
		except OSError:
			pass
		if rows[:1] != seen:
			seen = rows[:1]
			hits.clear()
		apt = self.headers.get("User-Agent", "").startswith("Debian APT")
		if not apt and any(r.split()[1:2] == ["warmstall"] and r.split()[0] in self.path for r in rows[1:]):
			time.sleep(6)
			return
		if apt:
			for row in rows[1:]:
				sub, mode, n = row.split()
				if mode == "warmstall":
					continue
				if sub in self.path:
					with lock:
						hits[row] = hits.get(row, 0) + 1
						over = hits[row] > int(n)
					if not over:
						if mode == "503":
							return self.send_error(503)
						time.sleep(4)
						return
		return super().do_GET()

	def log_message(self, *args):
		pass

class Server(http.server.ThreadingHTTPServer):
	daemon_threads = True
	def handle_error(self, *args):
		pass

Server(("127.0.0.1", int(sys.argv[1])), functools.partial(Handler, directory=sys.argv[2])).serve_forever()
EOF
http_port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
: >"$tmp/http-ctl"
python3 "$tmp/http-server.py" "$http_port" "$tmp/http-pub" "$tmp/http-ctl" &
http_pid=$!
for _ in $(seq 50); do
	curl -fs -o /dev/null "http://127.0.0.1:$http_port/frostyard.gpg" && break
	sleep 0.1
done
ctl_seq=0
# serve_ctl ROW... writes the control rows under a new sequence number.
serve_ctl() {
	ctl_seq=$((ctl_seq + 1))
	printf '%s\n' "$ctl_seq" "$@" >"$tmp/http-ctl"
}
thing_pool=$(cd "$pub" && find pool -name 'trixie-thing_1.1_amd64.deb')
canary_http() { env APT_PUBLIC_URL="http://127.0.0.1:$http_port" APT_CANARY_TIMEOUT=2 "$@" "$ROOT/scripts/apt-canary.sh" trixie amd64 trixie-thing=1.1; }
retry_lines() { grep -c 'canary: apt-get .* failed (try .*retrying in' "$tmp/err" || true; }

serve_ctl
must_pass "the canary installs over HTTP" canary_http
check "the warm-up logs the URL, status and cache status" \
	grep -q "canary warm-up http://127.0.0.1:$http_port/$thing_pool: HTTP 200, .*s, [1-9][0-9]* bytes, cf-cache-status -" "$tmp/err"
check "a clean run logs no retry" test "$(retry_lines)" = 0
serve_ctl 'trixie-thing_1.1 503 1'
must_pass "the canary retries a 503 from the CDN" canary_http
check "the 503 retry is logged" grep -q 'canary: apt-get download trixie-thing=1.1 from trixie/amd64 failed (try 1 of 4):.*503.*; retrying in 0s' "$tmp/err"
# apt 3 reconnects once by itself after a timeout, so two stalls make one failed try.
serve_ctl 'trixie-thing_1.1 stall 2'
must_pass "the canary retries a fetch that stalls past the timeout" canary_http
check "the stall retry is logged" grep -q 'failed (try 1 of 4):.*; retrying in' "$tmp/err"
check "the stall is a timeout" grep -q 'failed (try 1 of 4): E: .*Connection \(timed out\|failed\)' "$tmp/err"
serve_ctl 'trixie-thing_1.1 503 99'
must_fail "the canary fails when every fetch gives 503" "apt-get download trixie-thing=1.1 from trixie/amd64 failed (try 3 of 3)" \
	canary_http APT_CANARY_TRIES=3
check "it tried TRIES times, no more" test "$(retry_lines)" = 2
serve_ctl
rm "$tmp/http-pub/$thing_pool"
must_fail "a 404 fails the canary" "404" canary_http
check "a 404 is not retried" test "$(retry_lines)" = 0
printf 'corrupted bytes\n' >"$tmp/http-pub/$thing_pool"
must_fail "a size mismatch fails the canary" "apt-get download trixie-thing=1.1 from trixie/amd64 failed (try 1 of 4)" canary_http
check "a size mismatch is not retried" test "$(retry_lines)" = 0
# Same size, other bytes: only the hash can tell.
head -c "$(stat -c %s "$pub/$thing_pool")" /dev/zero >"$tmp/http-pub/$thing_pool"
must_fail "a hash mismatch fails the canary" "Hash Sum mismatch" canary_http
check "a hash mismatch is not retried" test "$(retry_lines)" = 0
cp "$pub/$thing_pool" "$tmp/http-pub/$thing_pool"
must_pass "the canary passes with the file restored" canary_http
must_fail "a bad signature fails the canary" "apt-get update of trixie/amd64 failed (try 3 of 3)" \
	canary_http APT_KEYRING="$tmp/other-key.gpg" APT_CANARY_TRIES=3
check "the update was tried TRIES times" test "$(retry_lines)" = 2
must_fail "a bad tunable is refused" "APT_CANARY_TRIES must be an integer >= 1 (got: x)" canary_http APT_CANARY_TRIES=x
must_fail "zero tries are refused" "APT_CANARY_TRIES must be an integer >= 1" canary_http APT_CANARY_TRIES=0
must_fail "a negative timeout is refused" "APT_CANARY_TIMEOUT must be an integer" canary_http APT_CANARY_TIMEOUT=-1
must_fail "a zero timeout is refused" "APT_CANARY_TIMEOUT must be an integer >= 1" canary_http APT_CANARY_TIMEOUT=0
must_fail "a bad delay is refused" "APT_CANARY_DELAY must be an integer" canary_http APT_CANARY_DELAY=1s
must_fail "a bad budget is refused" "APT_CANARY_BUDGET must be an integer >= 1" canary_http APT_CANARY_BUDGET=0
# The budget is a hard limit: no pause starts that would outlast it, and
# apt-get is stopped when it runs out.
serve_ctl 'trixie-thing_1.1 stall 99'
must_fail "the canary stops retrying when the budget is spent" "the canary budget of 6s is spent" \
	canary_http APT_CANARY_BUDGET=6 APT_CANARY_DELAY=3
must_fail "the budget stops a hanging apt-get" "the canary budget of 2s is spent; stopped" \
	canary_http APT_CANARY_BUDGET=2 APT_CANARY_TIMEOUT=60
# A stalled warm-up does not use the budget: apt still gets its time.
serve_ctl 'trixie-thing_1.1 warmstall 99'
must_pass "a stalled warm-up does not fail the canary" canary_http APT_CANARY_BUDGET=5
check "the stalled warm-up is logged" grep -q 'canary warm-up curl failed' "$tmp/err"
must_pass "the warm-up can be turned off" canary_http APT_CANARY_WARMUP=0
check "a turned-off warm-up is logged" grep -q 'warm-up allowance is spent' "$tmp/err"
serve_ctl

# The error classes, with apt 2.7's wording (the CI runner's apt), through a
# fake apt-get: update passes, download prints $SHIM_APT_LOG and fails.
mkdir -p "$tmp/shim-apt"
cat >"$tmp/shim-apt/apt-get" <<'EOF'
#!/usr/bin/env bash
for a; do [[ $a == --print-uris || $a == update ]] && exit 0; done
echo $(($(cat "$SHIM_APT_COUNT" 2>/dev/null || echo 0) + 1)) >"$SHIM_APT_COUNT"
cat "$SHIM_APT_LOG"
exit 100
EOF
chmod +x "$tmp/shim-apt/apt-get"
# apt_class DESC TRIES LOG... runs the canary against the fake apt-get with
# that download log, and checks the number of download tries.
apt_class() {
	local desc=$1 want=$2
	shift 2
	printf '%s\n' "$@" >"$tmp/shim-apt.log"
	rm -f "$tmp/shim-apt.count"
	if env PATH="$tmp/shim-apt:$PATH" SHIM_APT_LOG="$tmp/shim-apt.log" SHIM_APT_COUNT="$tmp/shim-apt.count" \
		APT_CANARY_TRIES=3 "$ROOT/scripts/apt-canary.sh" trixie amd64 v503=503 >"$tmp/out" 2>"$tmp/err"; then
		not_ok "$desc (unexpectedly succeeded)"
	fi
	check "$desc" test "$(cat "$tmp/shim-apt.count")" = "$want"
}
url=https://repo.invalid/debian/pool/main/v/v503/v503_503_amd64.deb
hdr='Err:1 https://repo.invalid/debian trixie/main amd64 v503 amd64 503'
apt_class "a 404 for version 503 is not retried" 1 "$hdr" '  404  Not Found [IP: 192.0.2.1 443]' \
	"E: Failed to fetch $url  404  Not Found [IP: 192.0.2.1 443]"
apt_class "a hash mismatch for version 503 is not retried" 1 "$hdr" '  Hash Sum mismatch' \
	"E: Failed to fetch $url  Hash Sum mismatch"
apt_class "a 503 is retried" 3 "$hdr" '  503  Service Unavailable [IP: 192.0.2.1 443]' \
	"E: Failed to fetch $url  503  Service Unavailable [IP: 192.0.2.1 443]"
apt_class "a Cloudflare 522 is retried" 3 "$hdr" '  522  <none> [IP: 192.0.2.1 443]' \
	"E: Failed to fetch $url  522  <none> [IP: 192.0.2.1 443]"
apt_class "an apt 2.7 timeout is retried" 3 "$hdr" '  Connection timed out [IP: 192.0.2.1 443]' \
	"E: Failed to fetch $url  Connection timed out [IP: 192.0.2.1 443]"
apt_class "a 404 on port 503 is not retried" 1 "$hdr" '  404  Not Found [IP: 192.0.2.1 503]' \
	"E: Failed to fetch http://repo.invalid:503/x_503_amd64.deb  404  Not Found [IP: 192.0.2.1 503]"

# Another writer's stanza, appended to the published index.
{
	rclone cat r2:frostyardrepo/debian/dists/trixie/main/binary-amd64/Packages
	printf '\nPackage: injected\nVersion: 1\nArchitecture: amd64\nFilename: pool/main/i/injected/injected_1_amd64.deb\nSHA256: %064d\n\n' 0
} >"$tmp/injected"
rclone rcat r2:frostyardrepo/debian/dists/trixie/main/binary-amd64/Packages <"$tmp/injected"
must_fail "verify rejects an index that does not match Release" "does not match its Release hash" \
	run verify.sh trixie
mkdeb "$tmp/trixie-only-later" trixie-thing 1.2 amd64
must_fail "a tampered index blocks publication" "does not match aptly's database" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/trixie-only-later"
must_pass "switch --force restores the index" \
	run switch.sh --codename trixie --snapshot "$trixie_snapshot" --force
must_pass "publication resumes after the repair" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/trixie-only-later"
check "the resumed publication is listed" listed trixie trixie-thing 1.2

check "state history keeps replaced database files" \
	test -n "$(rclone lsf r2:frostyard-apt-state/debian/history/)"
check "purge covers InRelease" grep -qx "$APT_PUBLIC_URL/dists/trixie/InRelease" \
	<("$ROOT/scripts/purge-cache.sh" --print trixie)

# The main-only codenames file publishes main only, exactly as before
# ADR-0059 step 3.
for codename in trixie forky; do
	check "$codename Release lists the main component only" grep -qx 'Components: main' "$pub/dists/$codename/Release"
	check "$codename has no image index" test ! -e "$pub/dists/$codename/image"
done
check "the pool has no image directory" test ! -e "$pub/pool/image"
must_pass "switch --list shows the snapshots" run switch.sh --list
check "every snapshot keeps the main name pattern" \
	test "$(grep -oE '\[(trixie|forky)[^]]*\]' "$tmp/out" | grep -Evc '^\[(trixie|forky)-[0-9]{8}T[0-9]{6}Z-')" = 0
check "no snapshot is named for image" test "$(grep -c 'image' "$tmp/out" || true)" = 0
check "purge lists no image URL" test "$("$ROOT/scripts/purge-cache.sh" --print trixie | grep -c '/image/' || true)" = 0
check "purge lists the same 15 URLs as before, plus the key" test "$("$ROOT/scripts/purge-cache.sh" --print trixie | wc -l)" = 16
expected=("$APT_PUBLIC_URL/dists/trixie/InRelease" "$APT_PUBLIC_URL/dists/trixie/Release" "$APT_PUBLIC_URL/dists/trixie/Release.gpg")
for arch in amd64 arm64 all; do
	for f in Packages Packages.gz Packages.bz2 Release; do
		expected+=("$APT_PUBLIC_URL/dists/trixie/main/binary-$arch/$f")
	done
done
check "purge lists the same URLs in the same order as before" \
	test "$("$ROOT/scripts/purge-cache.sh" --print trixie | grep -v '/frostyard.gpg$')" = "$(printf '%s\n' "${expected[@]}")"

# --- the published key (core ADR-0059) ---

scope keyfile
mkdeb "$tmp/key-a" frostyard-updex 1.0.0 amd64
mkdeb "$tmp/key-b" frostyard-updex 1.0.1 amd64
mkdeb "$tmp/key-c" frostyard-updex 1.0.2 amd64
check "the key is absent before the first publication" test ! -e "$pub/frostyard.gpg"
must_pass "a first publication uploads the key" \
	run publish.sh --producer frostyard/updex --debs "$tmp/key-a" --codenames trixie
check "the first publication logged the upload" grep -q 'uploaded the published key' "$tmp/err"
check "the published key is byte-identical to the keyring" cmp -s "$pub/frostyard.gpg" "$APT_KEYRING"
must_pass "a second publication succeeds" \
	run publish.sh --producer frostyard/updex --debs "$tmp/key-b" --codenames trixie
check "the second publication found the key current" grep -q 'published key is current' "$tmp/err"
check "the second publication did not upload it again" \
	test "$(grep -c 'uploaded the published key' "$tmp/err" || true)" = 0
must_pass "verify passes when the key matches" run verify.sh trixie
corrupt frostyard.gpg
must_fail "verify fails when the key object differs" "published key .* missing or differs" \
	run verify.sh trixie
must_pass "the next publication replaces a wrong key" \
	run publish.sh --producer frostyard/updex --debs "$tmp/key-c" --codenames trixie
check "the replacement was logged" grep -q 'uploaded the published key' "$tmp/err"
check "the key is byte-identical again" cmp -s "$pub/frostyard.gpg" "$APT_KEYRING"
must_pass "verify passes after the repair" run verify.sh trixie
# Different bytes with the keyring's length and modification time.
head -c "$(stat -c %s "$APT_KEYRING")" /dev/zero | tr '\0' x >"$tmp/key-same-size"
touch -r "$APT_KEYRING" "$tmp/key-same-size"
rclone copyto --ignore-times "$tmp/key-same-size" "r2:frostyardrepo/$APT_PREFIX/frostyard.gpg"
check "the same-size key object differs from the keyring" \
	test "$(stat -c %s "$pub/frostyard.gpg")" = "$(stat -c %s "$APT_KEYRING")" -a \
	"$(sha256sum <"$pub/frostyard.gpg")" != "$(sha256sum <"$APT_KEYRING")"
mkdeb "$tmp/key-d" frostyard-updex 1.0.3 amd64
must_pass "the next publication replaces a same-size, same-time key" \
	run publish.sh --producer frostyard/updex --debs "$tmp/key-d" --codenames trixie
check "the same-size key was replaced" cmp -s "$pub/frostyard.gpg" "$APT_KEYRING"
rclone deletefile "r2:frostyardrepo/$APT_PREFIX/frostyard.gpg"
must_fail "verify fails when the key object is missing" "published key .* missing or differs" \
	run verify.sh trixie
must_pass "withdraw restores a missing key" \
	run withdraw.sh --codename trixie --package frostyard-updex --version 1.0.3
check "the key is back after the withdrawal" cmp -s "$pub/frostyard.gpg" "$APT_KEYRING"

"$ROOT/scripts/purge-cache.sh" --print trixie forky >"$tmp/purge.txt"
check "purge lists the key URL once for two codenames" \
	test "$(grep -cx "$APT_PUBLIC_URL/frostyard.gpg" "$tmp/purge.txt")" = 1

jq -n '{tagName: "v1.0.1", assets: [{name: "frostyard-updex_1.0.1_amd64.deb"}]}' >"$tmp/gh/frostyard_updex.json"
# Only updex is audited here; the other producers have nothing in this scope.
grep -E '^(#|frostyard/updex	)' "$tmp/producers.tsv" >"$tmp/producers-key.tsv"
must_pass "the audit passes when the key matches" \
	env PATH="$tmp/shim-gh:$PATH" APT_PRODUCERS_FILE="$tmp/producers-key.tsv" "$ROOT/scripts/audit-producers.sh"
corrupt frostyard.gpg
if env PATH="$tmp/shim-gh:$PATH" APT_PRODUCERS_FILE="$tmp/producers-key.tsv" "$ROOT/scripts/audit-producers.sh" >"$tmp/out" 2>"$tmp/err"; then
	not_ok "the audit reports a different key (unexpectedly passed)"
fi
check "the audit reports a different key" grep -qx "MISMATCH key $APT_PUBLIC_URL/frostyard.gpg" "$tmp/out"
rclone deletefile "r2:frostyardrepo/$APT_PREFIX/frostyard.gpg"
if env PATH="$tmp/shim-gh:$PATH" APT_PRODUCERS_FILE="$tmp/producers-key.tsv" "$ROOT/scripts/audit-producers.sh" >"$tmp/out" 2>"$tmp/err"; then
	not_ok "the audit reports a missing key (unexpectedly passed)"
fi
check "the audit reports a missing key" grep -qx "MISSING key $APT_PUBLIC_URL/frostyard.gpg" "$tmp/out"

# The recovery of an interrupted publication also gates on the key.
scope keyrecover
export SHIM_STATE_PATH=keyrecover SHIM_FAIL_AT=2
rm -f -- "$tmp/shim-rclone/count"
mkdeb "$tmp/kr-a" frostyard-updex 2.0.0 amd64
must_fail "a publication interrupted after it became visible fails" "simulated failure" \
	env PATH="$tmp/shim-rclone:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/updex --debs "$tmp/kr-a" --codenames trixie
rclone deletefile "r2:frostyardrepo/$APT_PREFIX/frostyard.gpg"
# A shim that fails the upload of the key object.
mkdir -p "$tmp/shim-key"
cat >"$tmp/shim-key/rclone" <<EOF
#!/usr/bin/env bash
if [[ \$1 == copyto && \${*: -1} == */frostyard.gpg ]]; then
	echo "shim: simulated failure uploading the key" >&2
	exit 1
fi
exec "$real_rclone" "\$@"
EOF
chmod +x "$tmp/shim-key/rclone"
before=$(inrelease trixie)
db_before=$(rclone hashsum md5 r2:frostyard-apt-state/keyrecover/db | sort)
must_fail "a recovery whose key upload fails fails" "cannot upload the key" \
	env PATH="$tmp/shim-key:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/updex --debs "$tmp/kr-a" --codenames trixie
check "the failed recovery left InRelease unchanged" test "$(inrelease trixie)" = "$before"
check "the failed recovery left the state database unchanged" \
	test "$(rclone hashsum md5 r2:frostyard-apt-state/keyrecover/db | sort)" = "$db_before"
check "the key is still absent" test ! -e "$pub/frostyard.gpg"
must_pass "the next run completes the publication" \
	run publish.sh --producer frostyard/updex --debs "$tmp/kr-a" --codenames trixie
check "that run completed the interrupted publication" grep -q 'completing the interrupted publication of trixie' "$tmp/err"
check "the recovery restored the key byte for byte" cmp -s "$pub/frostyard.gpg" "$APT_KEYRING"
must_pass "the recovered suite verifies" run verify.sh trixie frostyard-updex=2.0.0
export SHIM_FAIL_AT=0
rm -f -- "$tmp/shim-rclone/count"

# --- an older database cannot overwrite newer publications -------------------------------

scope stale
mkdeb "$tmp/stale-a" frostyard-updex 2.0.0 amd64
mkdeb "$tmp/stale-b" frostyard-updex 2.9.0 amd64
mkdeb "$tmp/stale-c" bootc '1.0-1~deb13' amd64
must_pass "publish 2.0.0" run publish.sh --producer frostyard/updex --debs "$tmp/stale-a" --codenames trixie
rclone copy --quiet r2:frostyard-apt-state/stale/db r2:frostyard-apt-state/stale-old/db
must_pass "publish 2.9.0" run publish.sh --producer frostyard/updex --debs "$tmp/stale-b" --codenames trixie
rclone copy --quiet r2:frostyard-apt-state/stale/db r2:frostyard-apt-state/stale-new/db
rclone sync --quiet r2:frostyard-apt-state/stale-old/db r2:frostyard-apt-state/stale/db
before=$(inrelease trixie)
must_fail "an older database is refused" "does not match aptly's database" \
	run publish.sh --producer frostyard/bootc-debian --debs "$tmp/stale-c"
check "the refusal keeps 2.9.0 published" listed trixie frostyard-updex 2.9.0
check "the refusal left InRelease unchanged" test "$(inrelease trixie)" = "$before"
rclone sync --quiet r2:frostyard-apt-state/stale-new/db r2:frostyard-apt-state/stale/db
must_pass "the current database publishes" run publish.sh --producer frostyard/bootc-debian --debs "$tmp/stale-c"
check "2.9.0 survives" listed trixie frostyard-updex 2.9.0

# --- a publish that dies after becoming visible is completed --------------------------

scope interrupted
export SHIM_STATE_PATH=interrupted SHIM_FAIL_AT=2
mkdeb "$tmp/int-a" frostyard-updex 2.0.0 amd64
must_fail "a first publication interrupted after it became visible fails" "simulated failure" \
	env PATH="$tmp/shim-rclone:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/updex --debs "$tmp/int-a" --codenames trixie
check "the interrupted first publication is visible" listed trixie frostyard-updex 2.0.0
must_pass "retrying converges" run publish.sh --producer frostyard/updex --debs "$tmp/int-a" --codenames trixie
check "the retry completed the interrupted publication" grep -q 'completing the interrupted publication of trixie' "$tmp/err"
must_pass "the completed suite verifies" run verify.sh trixie --deep frostyard-updex=2.0.0

rm -f -- "$tmp/shim-rclone/count"
mkdeb "$tmp/int-b" frostyard-updex 2.0.1 amd64
must_fail "a switch interrupted after it became visible fails" "simulated failure" \
	env PATH="$tmp/shim-rclone:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/updex --debs "$tmp/int-b" --codenames trixie
mkdeb "$tmp/int-c" bootc '1.0-1~deb13' amd64
must_pass "another producer's run completes it and publishes" \
	run publish.sh --producer frostyard/bootc-debian --debs "$tmp/int-c"
check "that run reported the completion" grep -q 'completing the interrupted publication of trixie' "$tmp/err"
check "the interrupted release stays published" listed trixie frostyard-updex 2.0.1
check "the other producer's release is published" listed trixie bootc '1.0-1~deb13'

# --- audit of producers' latest releases ------------------------------------------------

scope audit
mkdeb "$tmp/audit-updex" frostyard-updex 3.1.0 amd64
mkdeb "$tmp/audit-bootc" bootc '2.1-1~deb13' amd64
mkdeb "$tmp/audit-bootc" libostree-1-1 '2.1-1~deb13' amd64
mkdeb "$tmp/audit-thing" trixie-thing 1.0 amd64
mkdeb "$tmp/audit-incus" incus '1:7.5.1-debian13-202610031200' amd64
must_pass "publish updex for the audit" run publish.sh --producer frostyard/updex --debs "$tmp/audit-updex"
must_pass "publish bootc for the audit" run publish.sh --producer frostyard/bootc-debian --debs "$tmp/audit-bootc"
must_pass "publish trixie-thing for the audit" run publish.sh --producer frostyard/trixie-only --debs "$tmp/audit-thing"
must_pass "publish incus for the audit" run publish.sh --producer frostyard/incus --debs "$tmp/audit-incus"
release() { jq -n --arg t "$2" '{tagName: $t, assets: ($ARGS.positional | map({name: .}))}' --args "${@:3}" >"$tmp/gh/$1.json"; }
release frostyard_updex v3.1.0 frostyard-updex_3.1.0_amd64.deb checksums.txt
# GitHub lists uploaded asset names with . in place of ~; match either.
release frostyard_bootc-debian v2.1 bootc_2.1-1.deb13_amd64.deb 'libostree-1-1_2.1-1~deb13_amd64.deb'
release frostyard_trixie-only v1.0 trixie-thing_1.0_amd64.deb
# Asset names omit the epoch that the indexes list.
release frostyard_incus 7.5.1-debian13-202610031200 incus_7.5.1-debian13-202610031200_amd64.deb
must_pass "the audit passes when every latest release is published" \
	env PATH="$tmp/shim-gh:$PATH" "$ROOT/scripts/audit-producers.sh"
release frostyard_updex v3.2.0 frostyard-updex_3.2.0_amd64.deb
if env PATH="$tmp/shim-gh:$PATH" "$ROOT/scripts/audit-producers.sh" >"$tmp/out" 2>"$tmp/err"; then
	not_ok "the audit reports an unpublished release (unexpectedly passed)"
fi
check "the audit reports an unpublished release" \
	grep -qx 'MISSING frostyard/updex v3.2.0 frostyard-updex_3.2.0_amd64.deb' "$tmp/out"

# --- Debian names in main (core ADR-0059) ---------------------------------------------

# Fake Debian and security mirrors: file:// trees with unsigned Release files
# whose SHA256 section matches the xz-compressed indexes.
# mkindex MIRROR SUITE COMPONENT ARCH NAME... writes the index and its Release line.
mkindex() {
	local mirror=$1 suite=$2 component=$3 arch=$4 dir
	shift 4
	dir=$mirror/dists/$suite/$component/binary-$arch
	mkdir -p "$dir"
	# With no names the index is empty, as some forky indexes are.
	if [[ $# == 0 ]]; then
		xz -c </dev/null >"$dir/Packages.xz"
	else
		printf 'Package: %s\nVersion: 1\nArchitecture: all\n\n' "$@" | xz -c >"$dir/Packages.xz"
	fi
	printf ' %s %s %s/binary-%s/Packages.xz\n' "$(sha256sum <"$dir/Packages.xz" | cut -d' ' -f1)" \
		"$(stat -c %s "$dir/Packages.xz")" "$component" "$arch" >>"$mirror/dists/$suite/Release.sha"
}
# mkrelease MIRROR SUITE writes Release from the lines mkindex collected.
mkrelease() {
	{
		printf 'Suite: %s\nComponents: main contrib\nSHA256:\n' "$2"
		printf ' %064d 0 main/Contents-amd64.gz\n' 0
		cat "$1/dists/$2/Release.sha"
	} >"$1/dists/$2/Release"
	rm "$1/dists/$2/Release.sha"
}
debmirror=$tmp/debmirror debsec=$tmp/debsec
rm -rf "$debmirror" "$debsec"
# trixie ships trixie-thing, also updated; imgpkg is an image name here.
for arch in amd64 arm64 all; do
	mkindex "$debmirror" trixie main "$arch" libc6 imgpkg trixie-thing
	mkindex "$debmirror" trixie-updates main "$arch" trixie-thing
	mkindex "$debsec" trixie-security main "$arch" incus
	mkindex "$debmirror" forky main "$arch"
	mkindex "$debmirror" forky-updates main "$arch" libc6
	mkindex "$debsec" forky-security main "$arch"
done
# Installer udebs (COMPONENT/debian-installer/) are not host packages: a
# Frostyard name there is not reported.
mkindex "$debmirror" trixie main/debian-installer amd64 frostyard-updex
# Another Debian component counts: contrib is reported. An architecture that
# the codename does not publish does not: i386 is read by no configured host.
# A present -backports suite is reported too.
mkindex "$debmirror" trixie contrib amd64 incus-base
mkindex "$debmirror" trixie main i386 incus-client
mkindex "$debmirror" trixie-backports main amd64 incus-extra
for suite in trixie trixie-updates trixie-backports forky forky-updates; do mkrelease "$debmirror" "$suite"; done
for suite in trixie-security forky-security; do mkrelease "$debsec" "$suite"; done

scope debnames
export APT_CODENAMES_FILE=$tmp/codenames-image.tsv APT_PRODUCERS_FILE=$tmp/producers-image.tsv
mkdeb "$tmp/dn-updex" frostyard-updex 1.0 amd64
mkdeb "$tmp/dn-thing" trixie-thing 1.0 amd64
mkdeb "$tmp/dn-incus" incus '1:7.5.1-debian13-202610031200' amd64
for name in incus-base incus-client incus-extra; do mkdeb "$tmp/dn-incus" "$name" '1:7.5.1-debian13-202610031200' amd64; done
mkdeb "$tmp/dn-img" imgpkg 1.0 amd64
must_pass "publish updex for the Debian-name audit" run publish.sh --producer frostyard/updex --debs "$tmp/dn-updex"
must_pass "publish trixie-thing for the Debian-name audit" run publish.sh --producer frostyard/trixie-only --debs "$tmp/dn-thing"
must_pass "publish incus for the Debian-name audit" run publish.sh --producer frostyard/incus --debs "$tmp/dn-incus"
must_pass "publish an image package with a Debian name" run publish.sh --producer frostyard/image-only --debs "$tmp/dn-img"
# absent PATTERN FILE: the pattern is not in the file.
absent() { ! grep -q "$@"; }
debnames() { env APT_DEBIAN_MIRROR=file://"$debmirror" APT_DEBIAN_SECURITY_MIRROR=file://"$debsec" "$ROOT/scripts/audit-debian-names.sh"; }
if debnames >"$tmp/out" 2>"$tmp/err"; then
	not_ok "the Debian-name audit reports Debian names (unexpectedly passed)"
fi
ok "the Debian-name audit exits 1 on a finding"
check "a name in the codename suite is reported with every suite that ships it" \
	grep -qx 'DEBIAN-NAME trixie trixie-thing trixie,trixie-updates' "$tmp/out"
check "a name in the security suite only is reported with -security" \
	grep -qx 'DEBIAN-NAME trixie incus trixie-security' "$tmp/out"
check "a Frostyard-only name is not reported, also when an installer udeb has it" \
	absent frostyard-updex "$tmp/out"
check "a Debian name in image is not reported" absent imgpkg "$tmp/out"
check "a name in another Debian component is reported" \
	grep -qx 'DEBIAN-NAME trixie incus-base trixie' "$tmp/out"
check "a name in a present -backports suite is reported with -backports" \
	grep -qx 'DEBIAN-NAME trixie incus-extra trixie-backports' "$tmp/out"
check "a name only in an architecture the codename does not publish is not reported" \
	absent incus-client "$tmp/out"
check "a missing suite is skipped" grep -q 'forky-backports does not exist' "$tmp/err"
check "the findings are the only output" test "$(wc -l <"$tmp/out")" = 4

# A hash that does not match the Release is fatal, not "no names".
cp -r "$debmirror" "$tmp/debmirror-bad"
printf 'tampered' >>"$tmp/debmirror-bad/dists/trixie/main/binary-amd64/Packages.xz"
must_fail "a Packages.xz that does not match its Release hash fails the audit" \
	"does not match the SHA256 in its Release" \
	env APT_DEBIAN_MIRROR=file://"$tmp/debmirror-bad" APT_DEBIAN_SECURITY_MIRROR=file://"$debsec" "$ROOT/scripts/audit-debian-names.sh"
# A failed fetch other than a missing suite is fatal too.
must_fail "an unreachable mirror fails the audit" "cannot fetch" \
	env APT_DEBIAN_MIRROR=http://127.0.0.1:1 APT_DEBIAN_SECURITY_MIRROR=file://"$debsec" "$ROOT/scripts/audit-debian-names.sh"

# bad_index MIRROR-COPY CONTENT... replaces trixie's main/amd64 index with the
# bytes from stdin, compressed or not as the caller made them, and fixes the
# Release hash so only the content is wrong.
bad_index() {
	local copy=$1 file=$1/dists/trixie/main/binary-amd64/Packages.xz hash size
	rm -rf "$copy"
	cp -r "$debmirror" "$copy"
	cat >"$file"
	hash=$(sha256sum <"$file" | cut -d' ' -f1)
	size=$(stat -c %s "$file")
	sed -i "s#^ [0-9a-f]\{64\} [0-9]* main/binary-amd64/Packages.xz\$# $hash $size main/binary-amd64/Packages.xz#" \
		"$copy/dists/trixie/Release"
}
# bad_release CONTENT... writes stdin as trixie's Release in a copy.
bad_release() {
	rm -rf "$1"
	cp -r "$debmirror" "$1"
	cat >"$1/dists/trixie/Release"
}
debnames_with() { env APT_DEBIAN_MIRROR=file://"$1" APT_DEBIAN_SECURITY_MIRROR=file://"$debsec" "$ROOT/scripts/audit-debian-names.sh"; }

printf 'this is not xz' | bad_index "$tmp/dm-notxz"
must_fail "an invalid xz index with a matching hash fails the audit" "is not valid xz" debnames_with "$tmp/dm-notxz"
printf 'Version: 1\nArchitecture: all\n\n' | xz -c | bad_index "$tmp/dm-nopkg"
must_fail "a Debian index whose stanza lacks Package fails the audit" "stanza without a Package field" debnames_with "$tmp/dm-nopkg"
printf '<html><body>Error</body></html>\n' | xz -c | bad_index "$tmp/dm-html-index"
must_fail "an HTML error page as a Debian index fails the audit" "stanza without a Package field" debnames_with "$tmp/dm-html-index"
printf '<html><body>Not found</body></html>\n' | bad_release "$tmp/dm-html"
must_fail "an HTML page as a Release fails the audit" "is not a Release file" debnames_with "$tmp/dm-html"
bad_release "$tmp/dm-empty" </dev/null
must_fail "an empty Release fails the audit" "is not a Release file" debnames_with "$tmp/dm-empty"
printf 'Suite: trixie\nComponents: main\n' | bad_release "$tmp/dm-nosha"
must_fail "a Release without a SHA256 section fails the audit" "is not a Release file" debnames_with "$tmp/dm-nosha"
printf 'Suite: trixie\nSHA256:\n abc 12 main/binary-amd64/Packages.xz\n' | bad_release "$tmp/dm-badline"
must_fail "a Release with a malformed SHA256 line fails the audit" "is not a Release file" debnames_with "$tmp/dm-badline"
printf 'Suite: trixie\nSHA256:\n %064d 0 main/Contents-amd64.gz\n' 0 | bad_release "$tmp/dm-noindex"
must_fail "a Release that lists no index for our architectures fails the audit" "lists no Packages.xz" debnames_with "$tmp/dm-noindex"

# Frostyard's own index must be a Packages index too.
rm -rf "$tmp/pub-html"
cp -r "$pub" "$tmp/pub-html"
printf '<html><body>Error</body></html>\n' >"$tmp/pub-html/dists/trixie/main/binary-amd64/Packages"
must_fail "an HTML page as Frostyard's index fails the audit" "is not a Packages index" \
	env APT_PUBLIC_URL=file://"$tmp/pub-html" "$ROOT/scripts/audit-debian-names.sh"
printf 'Filename: pool/main/x/x_1_amd64.deb\nSHA256: %064d\nVersion: 1\n\n' 0 \
	>"$tmp/pub-html/dists/trixie/main/binary-amd64/Packages"
must_fail "a Frostyard stanza without a Package field fails the audit" "without a Package field" \
	env APT_PUBLIC_URL=file://"$tmp/pub-html" "$ROOT/scripts/audit-debian-names.sh"
must_fail "a missing codenames file fails the audit" "cannot read" \
	env APT_CODENAMES_FILE="$tmp/no-such-codenames.tsv" "$ROOT/scripts/audit-debian-names.sh"
printf '# only a comment\n' >"$tmp/codenames-empty.tsv"
must_fail "a codenames file without a codename fails the audit" "lists no codename" \
	env APT_CODENAMES_FILE="$tmp/codenames-empty.tsv" "$ROOT/scripts/audit-debian-names.sh"

# With no Debian name in main the audit passes.
scope debnames-clean
mkdeb "$tmp/dn-clean" frostyard-updex 1.0 amd64
must_pass "publish only updex" run publish.sh --producer frostyard/updex --debs "$tmp/dn-clean"
must_pass "with no Debian name in main the audit exits 0" debnames
check "and prints no finding" test ! -s "$tmp/out"
export APT_CODENAMES_FILE=$tmp/codenames-main.tsv APT_PRODUCERS_FILE=$tmp/producers.tsv
# The next section continues in the audit scope.
scope audit

# --- a snapshot check reads the whole snapshot list -------------------------------------

# forky's published snapshot sorts before trixie's, so reconciling forky
# matches early in the list.
mkdeb "$tmp/updex-trickle" frostyard-updex 3.3.0 amd64
must_pass "an existing snapshot is found while aptly is still listing" \
	env PATH="$tmp/shim-aptly:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/updex --debs "$tmp/updex-trickle" --codenames forky
check "forky lists the publication" listed forky frostyard-updex 3.3.0

# --- the image component (core ADR-0059) ---------------------------------------
#
# From here every codename publishes main and image, and producers may be
# registered for image. The sections above ran with codenames-main.tsv and
# prove that path is unchanged.

export APT_CODENAMES_FILE=$tmp/codenames-image.tsv APT_PRODUCERS_FILE=$tmp/producers-image.tsv
# matches REGEX STRING
matches() { [[ $2 =~ $1 ]]; }
# state_sum: a hash of every object in the current scope's state path.
state_sum() { rclone hashsum md5 "r2:frostyard-apt-state/$APT_STATE_PATH" | sort | sha256sum; }
snapshot_re='[0-9]{8}T[0-9]{6}Z'

scope components
export SHIM_STATE_PATH=components

mkdeb "$tmp/c-updex" frostyard-updex 1.0 amd64
must_pass "a first publication by a main producer publishes both components" \
	run publish.sh --producer frostyard/updex --debs "$tmp/c-updex" --codenames trixie \
	--label updex-v1.0 --report "$tmp/c-report.tsv"
main0=$(cut -d' ' -f2 "$tmp/out")
check "the Release lists both components" grep -qx 'Components: image main' "$pub/dists/trixie/Release"
check "main lists the package" listed_in trixie main frostyard-updex 1.0
check "image has an index for every architecture" test "$(find "$pub/dists/trixie/image" -mindepth 2 -maxdepth 2 -name Packages | wc -l)" = 3
check "image starts empty" test "$(cat "$pub"/dists/trixie/image/binary-*/Packages | wc -c)" = 0
check "the main snapshot keeps its name pattern" matches "^trixie-$snapshot_re-updex-v1.0\$" "$main0"
check "the report row names the component" grep -qxP 'trixie\tfrostyard-updex\t1.0\tamd64\tmain' "$tmp/c-report.tsv"
must_pass "switch --list shows the image snapshot and no pending marker" run switch.sh --list
check "the empty image snapshot is named for image" grep -Eq "\[trixie-image-$snapshot_re-updex-v1.0\]" "$tmp/out"
check "no pending marker is left" test "$(grep -c '^pending:' "$tmp/out" || true)" = 0
must_pass "the canary reads the main component" run apt-canary.sh --report "$tmp/c-report.tsv"
must_pass "a both-component suite passes the deep check" run verify.sh trixie --deep frostyard-updex=1.0

# An image publication.
mkdeb "$tmp/c-img" imgpkg 1.0 amd64
main_sum=$(index_sum trixie main)
must_pass "publish an image package" run publish.sh --producer frostyard/image-only --debs "$tmp/c-img" \
	--codenames trixie --label imgpkg-1.0 --report "$tmp/c-img-report.tsv"
image1=$(cut -d' ' -f2 "$tmp/out")
check "the route names the component" grep -q 'imgpkg_1.0_amd64.deb -> trixie/image' "$tmp/err"
check "the image snapshot is named for image" matches "^trixie-image-$snapshot_re-imgpkg-1.0\$" "$image1"
check "image lists the package" listed_in trixie image imgpkg 1.0
check "main does not list it" not_listed_in trixie main imgpkg 1.0
check "the file is in pool/image" test -n "$(find "$pub/pool/image" -name 'imgpkg_1.0_amd64.deb' 2>/dev/null)"
check "the file is not in pool/main" test -z "$(find "$pub/pool/main" -name 'imgpkg_1.0_amd64.deb')"
check "apt with Components: image sees it" candidate_is trixie amd64 imgpkg 1.0 image
check "apt with Components: main has no candidate" candidate_is trixie amd64 imgpkg '' main
check "apt with both components sees it" candidate_is trixie amd64 imgpkg 1.0 'main image'
check "an image publication leaves the main indexes byte-identical" test "$(index_sum trixie main)" = "$main_sum"
check "the report row names image" grep -qxP 'trixie\timgpkg\t1.0\tamd64\timage' "$tmp/c-img-report.tsv"
must_pass "the canary reads the image component" run apt-canary.sh --report "$tmp/c-img-report.tsv"
must_pass "the canary takes CODENAME/COMPONENT" run apt-canary.sh trixie/image amd64 imgpkg=1.0
must_fail "the canary finds no image package in main" "apt-get download imgpkg=1.0" \
	run apt-canary.sh trixie amd64 imgpkg=1.0
must_pass "verify accepts image/NAME=VERSION" run verify.sh trixie image/imgpkg=1.0
must_fail "verify rejects main/NAME=VERSION" "does not list imgpkg 1.0 in main" run verify.sh trixie main/imgpkg=1.0
must_pass "verify accepts !main/NAME=VERSION" run verify.sh trixie '!main/imgpkg=1.0'
must_fail "verify rejects !image/NAME=VERSION" "still lists imgpkg 1.0 in image" run verify.sh trixie '!image/imgpkg=1.0'
must_pass "a bare NAME=VERSION matches any component" run verify.sh trixie --deep imgpkg=1.0 frostyard-updex=1.0

# A main publication leaves image alone.
image_sum=$(index_sum trixie image)
mkdeb "$tmp/c-thing" trixie-thing 1.0 amd64
must_pass "publish a main package" run publish.sh --producer frostyard/trixie-only --debs "$tmp/c-thing"
main1=$(cut -d' ' -f2 "$tmp/out")
check "a main publication lists the package in main" listed_in trixie main trixie-thing 1.0
check "a main publication leaves the image indexes byte-identical" test "$(index_sum trixie image)" = "$image_sum"

# One package name belongs in one component.
mkdeb "$tmp/c-bootc-img" bootc '1.0-1~deb13' amd64
must_pass "publish bootc to image" run publish.sh --producer frostyard/bootc-image --debs "$tmp/c-bootc-img"
mkdeb "$tmp/c-bootc-main" bootc '1.1-1~deb13' amd64
before=$(inrelease trixie)
must_fail "main cannot publish a name that image has" "trixie already publishes bootc in component image" \
	run publish.sh --producer frostyard/bootc-debian --debs "$tmp/c-bootc-main"
check "the refusal left InRelease unchanged" test "$(inrelease trixie)" = "$before"
mkdeb "$tmp/c-ostree-main" libostree-1-1 '1.0-1~deb13' amd64
must_pass "publish libostree-1-1 to main" run publish.sh --producer frostyard/bootc-debian --debs "$tmp/c-ostree-main"
mkdeb "$tmp/c-ostree-img" libostree-1-1 '1.1-1~deb13' amd64
before=$(inrelease trixie)
must_fail "image cannot publish a name that main has" "trixie already publishes libostree-1-1 in component main" \
	run publish.sh --producer frostyard/bootc-image --debs "$tmp/c-ostree-img"
check "that refusal left InRelease unchanged" test "$(inrelease trixie)" = "$before"
check "image still lacks libostree-1-1" not_listed_in trixie image libostree-1-1 '1.1-1~deb13'

# An image publication interrupted after it became visible is completed by the
# next run, whichever producer it is.
rm -f -- "$tmp/shim-rclone/count"
export SHIM_FAIL_AT=2
mkdeb "$tmp/c-img2" imgpkg 2.0 amd64
must_fail "an image switch interrupted after it became visible fails" "simulated failure" \
	env PATH="$tmp/shim-rclone:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/image-only --debs "$tmp/c-img2" --codenames trixie
check "the interrupted image publication is visible" listed_in trixie image imgpkg 2.0
must_pass "the pending marker names its component" run switch.sh --list
check "only the image marker is pending" test "$(grep '^pending:' "$tmp/out" | sed -E 's/ -> .*//')" = 'pending: trixie/image'
check "the marker names the image snapshot" \
	grep -Eq "^pending: trixie/image -> trixie-image-$snapshot_re-image-only\$" "$tmp/out"
mkdeb "$tmp/c-thing2" trixie-thing 1.1 amd64
must_pass "a main producer's run completes it and publishes" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/c-thing2"
check "that run reported the completion" grep -q 'completing the interrupted publication of trixie' "$tmp/err"
check "the image release stays published" listed_in trixie image imgpkg 2.0
check "the main release is published" listed_in trixie main trixie-thing 1.1
must_pass "the completed suite verifies" run verify.sh trixie --deep image/imgpkg=2.0 main/trixie-thing=1.1

# Withdraw touches one component.
main_sum=$(index_sum trixie main)
must_pass "withdraw an image package" run withdraw.sh --codename trixie --package imgpkg --version 2.0
image4=$(cut -d' ' -f2 "$tmp/out")
check "the withdrawal snapshot is named for image" matches "^trixie-image-$snapshot_re-withdraw-imgpkg-2.0\$" "$image4"
check "image no longer lists the version" not_listed_in trixie image imgpkg 2.0
check "image keeps its other versions" listed_in trixie image imgpkg 1.0
check "withdrawing from image leaves the main indexes byte-identical" test "$(index_sum trixie main)" = "$main_sum"
must_fail "withdrawing an unlisted version is refused in every component" "has no" \
	run withdraw.sh --codename trixie --package imgpkg --version 9.9
image_sum=$(index_sum trixie image)
must_pass "withdraw a main package" run withdraw.sh --codename trixie --package trixie-thing --version 1.1
check "withdrawing from main leaves the image indexes byte-identical" test "$(index_sum trixie image)" = "$image_sum"
check "main no longer lists the version" not_listed_in trixie main trixie-thing 1.1

# Rollback names one snapshot per component.
before=$(inrelease trixie)
must_fail "rollback with only a main snapshot is refused" "give a snapshot for component image too" \
	run switch.sh --codename trixie --snapshot "$main0"
must_fail "rollback with only an image snapshot is refused" "give a snapshot for component main too" \
	run switch.sh --codename trixie --snapshot "$image1"
must_fail "rollback with two snapshots of one component is refused" "two snapshots" \
	run switch.sh --codename trixie --snapshot "$main0" --snapshot "$main1" --snapshot "$image1"
must_fail "rollback refuses another codename's main snapshot" "was not created for trixie" \
	run switch.sh --codename trixie --snapshot forky-20260101T000000Z-x --snapshot "$image1"
must_fail "rollback refuses another codename's image snapshot" "was not created for trixie" \
	run switch.sh --codename trixie --snapshot "$main0" --snapshot forky-image-20260101T000000Z-x
must_fail "rollback refuses a snapshot that does not exist" "no snapshot named" \
	run switch.sh --codename trixie --snapshot trixie-20200101T000000Z-nope --snapshot "$image1"
check "the refusals left InRelease unchanged" test "$(inrelease trixie)" = "$before"
must_pass "roll back with both snapshots, in either order" \
	run switch.sh --codename trixie --snapshot "$image1" --snapshot "$main0"
check "rollback restores image" listed_in trixie image imgpkg 1.0
check "rollback unpublishes later image packages" not_listed_in trixie image bootc '1.0-1~deb13'
check "rollback restores main" not_listed_in trixie main trixie-thing 1.0
check "rollback unpublishes later main packages" not_listed_in trixie main libostree-1-1 '1.0-1~deb13'
check "rollback deletes no pool files" test -n "$(find "$pub/pool/image" -name 'imgpkg_2.0_amd64.deb')"
mkdeb "$tmp/c-thing3" trixie-thing 1.2 amd64
must_pass "a later main publication builds on the rolled-back contents" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/c-thing3"
cur_main=$(cut -d' ' -f2 "$tmp/out")
cur_image=$image1
check "the rollback survives a later publication" not_listed_in trixie main libostree-1-1 '1.0-1~deb13'
check "the later publication is listed" listed_in trixie main trixie-thing 1.2

# A tampered image index.
{
	rclone cat "r2:frostyardrepo/$APT_PREFIX/dists/trixie/image/binary-amd64/Packages"
	printf '\nPackage: injected\nVersion: 1\nArchitecture: amd64\nFilename: pool/image/i/injected/injected_1_amd64.deb\nSHA256: %064d\n\n' 0
} >"$tmp/injected-image"
rclone rcat "r2:frostyardrepo/$APT_PREFIX/dists/trixie/image/binary-amd64/Packages" <"$tmp/injected-image"
before=$(inrelease trixie)
must_fail "verify rejects a tampered image index" "image/binary-amd64/Packages does not match its Release hash" \
	run verify.sh trixie
mkdeb "$tmp/c-thing4" trixie-thing 1.3 amd64
must_fail "a tampered image index blocks publication" "does not match aptly's database" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/c-thing4"
check "the refusal left InRelease unchanged" test "$(inrelease trixie)" = "$before"
must_pass "switch --force with both snapshots repairs the image index" \
	run switch.sh --codename trixie --snapshot "$cur_main" --snapshot "$cur_image" --force
must_pass "the repaired suite verifies" run verify.sh trixie --deep
must_pass "publication resumes after the repair" run publish.sh --producer frostyard/trixie-only --debs "$tmp/c-thing4"
check "the resumed publication is listed" listed_in trixie main trixie-thing 1.3
cur_main=$(cut -d' ' -f2 "$tmp/out")

# A Release that lists other components than the configuration.
rclone cat "r2:frostyardrepo/$APT_PREFIX/dists/trixie/Release" | sed 's/^Components: .*/Components: main/' |
	rclone rcat "r2:frostyardrepo/$APT_PREFIX/dists/trixie/Release"
mkdeb "$tmp/c-thing5" trixie-thing 1.4 amd64
must_fail "a Release with the wrong components blocks publication" \
	"Release lists the components main, but the configuration says image,main" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/c-thing5"
must_pass "switch --force repairs the Release" \
	run switch.sh --codename trixie --snapshot "$cur_main" --snapshot "$cur_image" --force
check "the Release lists both components again" grep -qx 'Components: image main' "$pub/dists/trixie/Release"

# purge covers every component's indexes; main's URLs come first, unchanged.
"$ROOT/scripts/purge-cache.sh" --print trixie >"$tmp/purge.txt"
check "purge lists 27 URLs for two components, plus the key" test "$(wc -l <"$tmp/purge.txt")" = 28
for arch in amd64 arm64 all; do
	for f in Packages Packages.gz Packages.bz2 Release; do
		check "purge lists image/binary-$arch/$f" grep -qx "$APT_PUBLIC_URL/dists/trixie/image/binary-$arch/$f" "$tmp/purge.txt"
	done
done
check "purge lists main first" test "$(sed -n 4p "$tmp/purge.txt")" = "$APT_PUBLIC_URL/dists/trixie/main/binary-amd64/Packages"

# The import obeys the one-component rule.
scope importrule
mkdeb "$tmp/ir-docs" docs-thing 0.9 amd64
must_pass "publish docs-thing to image" run publish.sh --producer frostyard/docs-image --debs "$tmp/ir-docs" --codenames trixie
irule=(--codename trixie --base-url "file://$tmp/legacy" --work "$tmp/import-rule-work")
must_pass "review the legacy suite for a codename with image" run import-stable.sh "${irule[@]}" --download-only
manifest=$(cat "$tmp/out")
before=$(inrelease trixie)
state_before=$(state_sum)
must_fail "an import cannot bring a name into main that image has" \
	"trixie already publishes docs-thing in component image" \
	run import-stable.sh "${irule[@]}" --expect-manifest "$manifest"
check "the refused import left InRelease unchanged" test "$(inrelease trixie)" = "$before"
check "the refused import left the state bucket unchanged" test "$(state_sum)" = "$state_before"

# A rollback cannot publish one name in two components.
scope overlap
mkdeb "$tmp/ov-bootc" bootc '1.0-1~deb13' amd64
must_pass "publish bootc to main" run publish.sh --producer frostyard/bootc-debian --debs "$tmp/ov-bootc"
ov_main_old=$(cut -d' ' -f2 "$tmp/out")
must_pass "withdraw bootc from main" run withdraw.sh --codename trixie --package bootc --version '1.0-1~deb13'
ov_main_new=$(cut -d' ' -f2 "$tmp/out")
must_pass "publish bootc to image" run publish.sh --producer frostyard/bootc-image --debs "$tmp/ov-bootc"
ov_image=$(cut -d' ' -f2 "$tmp/out")
before=$(inrelease trixie)
state_before=$(state_sum)
must_fail "rollback refuses snapshots that publish one name in two components" "bootc in more than one component" \
	run switch.sh --codename trixie --snapshot "$ov_main_old" --snapshot "$ov_image"
must_fail "rollback --force refuses them too" "bootc in more than one component" \
	run switch.sh --codename trixie --snapshot "$ov_main_old" --snapshot "$ov_image" --force
check "the refusals left InRelease unchanged" test "$(inrelease trixie)" = "$before"
check "the refusals left the state bucket unchanged" test "$(state_sum)" = "$state_before"
# The rollback guard reads the registrations (core ADR-0059), and
# producers-image.tsv registers bootc for both components, which it refuses.
# This rollback runs with bootc registered for image only.
printf 'frostyard/bootc-image\tbootc\ttrixie,forky\tno\t-\timage\n' >"$tmp/producers-overlap.tsv"
must_pass "rollback to snapshots with disjoint names works" \
	env APT_PRODUCERS_FILE="$tmp/producers-overlap.tsv" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/switch.sh" --codename trixie --snapshot "$ov_main_new" --snapshot "$ov_image"

# A failing repository list is an error, not "no repository".
mkdeb "$tmp/ov-img" imgpkg 1.0 amd64
before=$(inrelease trixie)
state_before=$(state_sum)
must_fail "a failing repository list stops a publication" "cannot list aptly repositories" \
	env PATH="$tmp/shim-repolist:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/image-only --debs "$tmp/ov-img" --codenames trixie
check "the failed publication left InRelease unchanged" test "$(inrelease trixie)" = "$before"
check "the failed publication left the state bucket unchanged" test "$(state_sum)" = "$state_before"

# --- adding a component to a published codename -----------------------------------
#
# `aptly publish switch` cannot add a component. The first run after the
# configuration gains one stages the addition (`publish source add` and
# `publish source update`) and writes one signed Release with `publish update`.

# image_snapshot_count prints the number of distinct image snapshots.
image_snapshot_count() {
	run switch.sh --list >"$tmp/list" 2>&1
	grep -oE "(trixie|forky)-image-$snapshot_re-[A-Za-z0-9._-]+" "$tmp/list" | sort -u | wc -l
}

scope addimage

mkdeb "$tmp/add-thing-old" trixie-thing 1.0 amd64
mkdeb "$tmp/add-updex" frostyard-updex 1.0 amd64
must_pass "publish updex 1.0, main only" \
	env APT_CODENAMES_FILE="$tmp/codenames-main.tsv" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/updex --debs "$tmp/add-updex"
must_pass "publish trixie-thing 1.0, main only" \
	env APT_CODENAMES_FILE="$tmp/codenames-main.tsv" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/trixie-only --debs "$tmp/add-thing-old" --codenames trixie
mkdir -p "$tmp/addimage-saved"
cp -a "$pub/dists/forky/main" "$tmp/addimage-saved/"
addimage_same_main() {
	local f
	for f in "$pub"/dists/forky/main/binary-*/Packages; do
		cmp -s "$f" "$tmp/addimage-saved/${f##*/dists/forky/}" || return 1
	done
}

mkdeb "$tmp/add-thing" trixie-thing 1.1 amd64
must_pass "a trixie-only publication adds image to trixie and forky" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/add-thing"
check "the run names trixie's addition" grep -q 'adding component(s) image to trixie' "$tmp/err"
check "the run names forky's addition" grep -q 'adding component(s) image to forky' "$tmp/err"
for codename in trixie forky; do
	check "$codename Release lists both components after the addition" \
		grep -qx 'Components: image main' "$pub/dists/$codename/Release"
	check "$codename has an image index for every architecture" \
		test "$(find "$pub/dists/$codename/image" -mindepth 2 -maxdepth 2 -name Packages | wc -l)" = 3
	check "$codename image is empty" test "$(cat "$pub/dists/$codename"/image/binary-*/Packages | wc -c)" = 0
done
check "forky's main indexes stay byte-identical" addimage_same_main
check "trixie main lists the new package" listed_in trixie main trixie-thing 1.1
check "trixie main keeps the older package" listed_in trixie main trixie-thing 1.0
check "the adding run reports two codenames" test "$(wc -l <"$tmp/out")" = 2
check "the trixie line names the main snapshot" \
	matches "^trixie-$snapshot_re-trixie-only(\.[0-9]+)?\$" "$(awk '$1 == "trixie" { print $2 }' "$tmp/out")"
check "the forky line names the image snapshot" \
	matches "^forky-image-$snapshot_re-trixie-only(\.[0-9]+)?\$" "$(awk '$1 == "forky" { print $2 }' "$tmp/out")"
must_pass "trixie passes the deep check after the addition" run verify.sh trixie --deep
must_pass "forky passes the deep check after the addition" run verify.sh forky --deep
check "apt with both components reads trixie without a warning" \
	candidate_is trixie amd64 trixie-thing 1.1 'main image'
must_pass "switch --list after the addition" run switch.sh --list
check "the addition leaves no pending marker" test "$(grep -c '^pending:' "$tmp/out" || true)" = 0

# A second run must not add the component again.
image_trixie=$(index_sum trixie image)
image_forky=$(index_sum forky image)
mkdeb "$tmp/add-updex-next" frostyard-updex 1.1 amd64
must_pass "a later main publication switches as before" \
	run publish.sh --producer frostyard/updex --debs "$tmp/add-updex-next"
check "the second run logs no addition" test "$(grep -c 'adding component' "$tmp/err" || true)" = 0
check "trixie's image indexes are unchanged" test "$(index_sum trixie image)" = "$image_trixie"
check "forky's image indexes are unchanged" test "$(index_sum forky image)" = "$image_forky"
check "the second run created no image snapshot" test "$(image_snapshot_count)" = 2
check "the second run reports main snapshots" \
	test "$(grep -Ec "^(trixie|forky) (trixie|forky)-$snapshot_re-" "$tmp/out")" = 2

# A run that targets one codename leaves the other's InRelease alone.
before=$(inrelease forky)
mkdeb "$tmp/add-thing-next" trixie-thing 1.2 amd64
must_pass "a trixie-only run after the addition" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/add-thing-next"
check "a trixie-only run leaves forky's InRelease unchanged" test "$(inrelease forky)" = "$before"

# Removing a component is a separate migration.
before=$(inrelease trixie)
state_before=$(state_sum)
mkdeb "$tmp/add-thing-removal" trixie-thing 1.3 amd64
must_fail "a main-only configuration cannot remove image" \
	"Removing a component is a separate migration" \
	env APT_CODENAMES_FILE="$tmp/codenames-main.tsv" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/trixie-only --debs "$tmp/add-thing-removal" --codenames trixie
check "the removal refusal left InRelease unchanged" test "$(inrelease trixie)" = "$before"
check "the removal refusal left the state bucket unchanged" test "$(state_sum)" = "$state_before"

# A codename that the request targets but no package routes to also gets the
# component: bootc-debian's default codenames are trixie and forky, and a
# ~deb13 build goes to trixie only.
scope addrouted
mkdeb "$tmp/arouted-updex" frostyard-updex 1.0 amd64
must_pass "publish updex to trixie and forky, main only" \
	env APT_CODENAMES_FILE="$tmp/codenames-main.tsv" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/updex --debs "$tmp/arouted-updex"
mkdir -p "$tmp/arouted-saved"
cp -a "$pub/dists/forky/main" "$tmp/arouted-saved/"
mkdeb "$tmp/arouted-bootc" bootc '1.0-1~deb13' amd64
must_pass "a ~deb13 publication with default codenames" \
	run publish.sh --producer frostyard/bootc-debian --debs "$tmp/arouted-bootc"
check "the run names forky's addition" grep -q 'adding component(s) image to forky' "$tmp/err"
check "forky lists both components" grep -qx 'Components: image main' "$pub/dists/forky/Release"
check "forky's main indexes stay byte-identical" \
	diff -r "$tmp/arouted-saved/main" "$pub/dists/forky/main" -x by-hash -x Release -x 'Packages.*'
check "forky does not get the ~deb13 build" not_listed_in forky main bootc '1.0-1~deb13'
check "the run reports forky's image snapshot" \
	matches "^forky-image-$snapshot_re-bootc-debian(\.[0-9]+)?\$" "$(awk '$1 == "forky" { print $2 }' "$tmp/out")"
must_pass "forky passes the deep check" run verify.sh forky --deep

# An addition interrupted after it became visible: the bucket Release lists
# image, the database publishes main only, and the image marker names the new
# snapshot. The next run completes it.
scope addint
export SHIM_STATE_PATH=addint
mkdeb "$tmp/aint-main" frostyard-updex 1.0 amd64
must_pass "publish main only before the interrupted addition" \
	env APT_CODENAMES_FILE="$tmp/codenames-main.tsv" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/updex --debs "$tmp/aint-main" --codenames trixie
rm -f -- "$tmp/shim-rclone/count"
export SHIM_FAIL_AT=2
mkdeb "$tmp/aint-thing" trixie-thing 1.0 amd64
must_fail "an addition interrupted after it became visible fails" "simulated failure" \
	env PATH="$tmp/shim-rclone:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/trixie-only --debs "$tmp/aint-thing" --codenames trixie
check "the interrupted addition is visible" grep -qx 'Components: image main' "$pub/dists/trixie/Release"
mkdeb "$tmp/aint-thing-next" trixie-thing 1.1 amd64
must_pass "the next run completes the addition" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/aint-thing-next" --codenames trixie
check "that run reported the completion" \
	grep -q 'completing the interrupted publication of trixie' "$tmp/err"
must_pass "the completed addition verifies" run verify.sh trixie --deep
check "the completion created no second trixie image snapshot" test "$(image_snapshot_count)" = 1

# An addition interrupted before it became visible: the next run adds image.
scope addint2
export SHIM_STATE_PATH=addint2
mkdeb "$tmp/aint2-main" frostyard-updex 1.0 amd64
must_pass "publish main only before a failing addition" \
	env APT_CODENAMES_FILE="$tmp/codenames-main.tsv" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/updex --debs "$tmp/aint2-main" --codenames trixie
before=$(inrelease trixie)
rm -f -- "$tmp/shim-rclone/count"
export SHIM_FAIL_AT=1
mkdeb "$tmp/aint2-thing" trixie-thing 1.0 amd64
must_fail "an addition interrupted before it became visible fails" "simulated failure" \
	env PATH="$tmp/shim-rclone:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/trixie-only --debs "$tmp/aint2-thing" --codenames trixie
check "the failed addition left InRelease unchanged" test "$(inrelease trixie)" = "$before"
mkdeb "$tmp/aint2-thing-next" trixie-thing 1.1 amd64
must_pass "the next run adds image" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/aint2-thing-next" --codenames trixie
check "that run names the addition" grep -q 'adding component(s) image to trixie' "$tmp/err"
check "trixie publishes both components" grep -qx 'Components: image main' "$pub/dists/trixie/Release"
check "trixie image is still empty" test "$(cat "$pub"/dists/trixie/image/binary-*/Packages | wc -c)" = 0
must_pass "the added suite verifies" run verify.sh trixie --deep

# Both additions of a run interrupted after they became visible: the next
# trixie-only run completes forky's in its reconciliation, and still verifies
# and prints forky, so the workflow purges forky's CDN cache.
scope addint3
export SHIM_STATE_PATH=addint3
mkdeb "$tmp/aint3-updex" frostyard-updex 1.0 amd64
must_pass "publish updex to trixie and forky before two interrupted additions" \
	env APT_CODENAMES_FILE="$tmp/codenames-main.tsv" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/updex --debs "$tmp/aint3-updex"
rm -f -- "$tmp/shim-rclone/count"
export SHIM_FAIL_AT=2
mkdeb "$tmp/aint3-thing" trixie-thing 1.0 amd64
must_fail "two additions interrupted after they became visible fail" "simulated failure" \
	env PATH="$tmp/shim-rclone:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/trixie-only --debs "$tmp/aint3-thing"
check "forky's interrupted addition is visible" grep -qx 'Components: image main' "$pub/dists/forky/Release"
mkdeb "$tmp/aint3-thing-next" trixie-thing 1.1 amd64
must_pass "a trixie-only run completes both additions" \
	run publish.sh --producer frostyard/trixie-only --debs "$tmp/aint3-thing-next"
check "that run completed forky's addition" grep -q 'completing the interrupted publication of forky' "$tmp/err"
check "that run staged no second addition for forky" test "$(grep -c 'adding component(s) image to forky' "$tmp/err" || true)" = 1
check "that run prints forky with its image snapshot" \
	matches "^forky-image-$snapshot_re-trixie-only(\.[0-9]+)?\$" "$(awk '$1 == "forky" { print $2 }' "$tmp/out")"
check "that run read forky back" grep -q '^verified forky' "$tmp/err"
must_pass "forky passes the deep check after the completion" run verify.sh forky --deep
check "only 1 forky image snapshot exists" \
	test "$(run switch.sh --list 2>&1 | grep -oE "forky-image-$snapshot_re-[A-Za-z0-9._-]+" | sort -u | wc -l)" = 1

# A failed publication query is an error, not "no component published": the
# helper runs inside $(...), where errexit is off.
# shellcheck disable=SC2016 # the script expands in the child shell
check "missing_component_snapshots fails when the publication list fails" \
	bash -c '. "$1/scripts/lib.sh"
		calls=$2
		published_components() { return 1; }
		aptly_() { printf "%s\n" "$*" >>"$calls"; }
		if out=$(missing_component_snapshots forky label); then exit 1; fi
		[[ -z $out && ! -e $calls ]]' _ "$ROOT" "$tmp/mcs-aptly-calls"

# A withdrawal adds the component too, in the same Release.
scope addwithdraw
mkdeb "$tmp/awd-a" frostyard-updex 1.0 amd64
mkdeb "$tmp/awd-b" frostyard-updex 1.1 amd64
for deb in "$tmp/awd-a" "$tmp/awd-b"; do
	for f in "$deb"/*.deb; do
		must_pass "publish $(basename "$f"), main only" \
			env APT_CODENAMES_FILE="$tmp/codenames-main.tsv" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
			"$ROOT/scripts/publish.sh" --producer frostyard/updex --debs "$deb" --codenames trixie
	done
done
# The dry run reads the components from the published Release: image is
# configured but not published here, so its set is empty and the plan is the
# main row.
must_pass "a dry run before a component is published" \
	env -u R2_ACCESS_KEY_ID -u R2_SECRET_ACCESS_KEY "$ROOT/scripts/withdraw.sh" \
	--codename trixie --package frostyard-updex --version 1.0 --dry-run
check "the dry run plans the main row only" \
	test "$(grep '^withdraw ' "$tmp/err")" = 'withdraw trixie main frostyard-updex 1.0 amd64'
must_pass "a withdrawal adds image to trixie" \
	run withdraw.sh --codename trixie --package frostyard-updex --version 1.0
check "the withdrawal prints one line" test "$(wc -l <"$tmp/out")" = 1
check "the withdrawal's Release lists both components" grep -qx 'Components: image main' "$pub/dists/trixie/Release"
check "main lacks the withdrawn version" not_listed_in trixie main frostyard-updex 1.0
check "main keeps the other version" listed_in trixie main frostyard-updex 1.1
check "image is empty" test "$(cat "$pub"/dists/trixie/image/binary-*/Packages | wc -c)" = 0
must_pass "the withdrawal's suite verifies" run verify.sh trixie --deep

# A batch withdrawal withdraws many versions of one component from one
# codename in one publication, all or nothing, and --dry-run resolves the
# plan from the published index alone, so it needs no credentials and changes
# nothing.
scope batchwithdraw
export APT_CODENAMES_FILE=$tmp/codenames-image.tsv APT_PRODUCERS_FILE=$tmp/producers-image.tsv
export APT_WITHDRAWALS_DIR=$tmp/withdrawals
mkdir -p "$APT_WITHDRAWALS_DIR"

# One publish call per producer and release directory, as a producer does.
mkdeb "$tmp/bw-updex-10" frostyard-updex 1.0 amd64
mkdeb "$tmp/bw-updex-11" frostyard-updex 1.1 amd64
mkdeb "$tmp/bw-updex-11" frostyard-updex 1.1 arm64
mkdeb "$tmp/bw-updex-12" frostyard-updex 1.2 amd64
mkdeb "$tmp/bw-thing" trixie-thing 1.0 amd64
mkdeb "$tmp/bw-img-10" imgpkg 1.0 amd64
mkdeb "$tmp/bw-img-20" imgpkg 2.0 amd64
for d in bw-updex-10 bw-updex-11 bw-updex-12; do
	must_pass "publish $d" run publish.sh --producer frostyard/updex --debs "$tmp/$d"
done
must_pass "publish trixie-thing 1.0" run publish.sh --producer frostyard/trixie-only --debs "$tmp/bw-thing"
for d in bw-img-10 bw-img-20; do
	must_pass "publish $d" run publish.sh --producer frostyard/image-only --debs "$tmp/$d"
done

cat >"$APT_WITHDRAWALS_DIR/b1.txt" <<'EOF'
# keep frostyard-updex 1.2, trixie-thing 1.0 and imgpkg 1.0 and 2.0

frostyard-updex 1.0 amd64
frostyard-updex 1.1
EOF
trixie_before=$(inrelease trixie)
forky_before=$(inrelease forky)
image_sum=$(index_sum trixie image)

# A dry run needs neither credentials nor aptly state.
plan=$(printf '%s\n' \
	'withdraw trixie main frostyard-updex 1.0 amd64' \
	'withdraw trixie main frostyard-updex 1.1 amd64' \
	'withdraw trixie main frostyard-updex 1.1 arm64')
must_pass "a batch dry run needs no credentials" \
	env -u R2_ACCESS_KEY_ID -u R2_SECRET_ACCESS_KEY "$ROOT/scripts/withdraw.sh" \
	--codename trixie --batch b1.txt --dry-run
check "the batch dry run prints nothing on stdout" test -z "$(cat "$tmp/out")"
check "the batch dry run prints exactly the plan" test "$(grep '^withdraw ' "$tmp/err")" = "$plan"
check "the batch dry run left InRelease unchanged" test "$(inrelease trixie)" = "$trixie_before"

must_pass "a batch withdrawal publishes one Release" run withdraw.sh --codename trixie --batch b1.txt
check "the batch withdrawal prints one line" test "$(wc -l <"$tmp/out")" = 1
check "the line names the codename and one snapshot" test "$(wc -w <"$tmp/out")" = 2
check "the line starts with the codename" test "$(cut -d' ' -f1 "$tmp/out")" = trixie
check "the main snapshot is named for the batch" \
	matches "^trixie-$snapshot_re-withdraw-b1\$" "$(cut -d' ' -f2 "$tmp/out")"
check "main no longer lists 1.0" not_listed_in trixie main frostyard-updex 1.0 amd64
check "main no longer lists 1.1 in either architecture" not_listed_in trixie main frostyard-updex 1.1
check "main keeps the version no row named" listed_in trixie main frostyard-updex 1.2 amd64
check "main keeps another producer's package" listed_in trixie main trixie-thing 1.0 amd64
check "a main batch leaves the image indexes byte-identical" test "$(index_sum trixie image)" = "$image_sum"
check "the image component keeps its version" listed_in trixie image imgpkg 1.0 amd64
check "the batch deletes no pool file of a withdrawn version" test -n "$(pool_file 'frostyard-updex_1.0_amd64.deb')"
check "the batch deletes no pool file of the withdrawn architecture" test -n "$(pool_file 'frostyard-updex_1.1_arm64.deb')"
must_pass "the withdrawn suite passes the deep check" run verify.sh trixie --deep
check "the batch left forky unchanged" test "$(inrelease forky)" = "$forky_before"

# The same batch again has nothing left to withdraw.
before=$(inrelease trixie)
must_fail "a batch whose versions are gone is refused" "has no" \
	run withdraw.sh --codename trixie --batch b1.txt
check "the refused batch left InRelease unchanged" test "$(inrelease trixie)" = "$before"

# A batch withdraws from 1 component: two changed components are saved
# together but published one at a time, so a failure between the two would
# leave half of the batch behind.
printf 'frostyard-updex 1.2 amd64\nimgpkg 1.0 amd64\n' >"$APT_WITHDRAWALS_DIR/mixed.txt"
must_fail "a batch that resolves to two components is refused" \
	"withdraws from components main and image; a batch withdraws from 1 component" \
	run withdraw.sh --codename trixie --batch mixed.txt
check "the refused mixed batch withdrew nothing" listed_in trixie main frostyard-updex 1.2 amd64
check "the refused mixed batch left InRelease unchanged" test "$(inrelease trixie)" = "$before"
must_fail "a dry run refuses a batch of two components too" "a batch withdraws from 1 component" \
	env -u R2_ACCESS_KEY_ID -u R2_SECRET_ACCESS_KEY "$ROOT/scripts/withdraw.sh" \
	--codename trixie --batch mixed.txt --dry-run
check "the dry run refusal left InRelease unchanged" test "$(inrelease trixie)" = "$before"

# The same row on its own withdraws from image.
printf 'imgpkg 1.0 amd64\n' >"$APT_WITHDRAWALS_DIR/img.txt"
main_sum=$(index_sum trixie main)
must_pass "an image-only batch withdraws" run withdraw.sh --codename trixie --batch img.txt
check "the image batch prints one snapshot" test "$(wc -w <"$tmp/out")" = 2
check "the image snapshot is named for the batch" \
	matches "^trixie-image-$snapshot_re-withdraw-img\$" "$(cut -d' ' -f2 "$tmp/out")"
check "image no longer lists imgpkg 1.0" not_listed_in trixie image imgpkg 1.0 amd64
check "image keeps the version no row named" listed_in trixie image imgpkg 2.0 amd64
check "an image batch leaves the main indexes byte-identical" test "$(index_sum trixie main)" = "$main_sum"
check "the image batch deletes no pool file" test -n "$(pool_file 'imgpkg_1.0_amd64.deb')"
must_pass "the image batch's suite passes the deep check" run verify.sh trixie --deep

# One unresolvable row refuses the whole batch, live and in a dry run.
before=$(inrelease trixie)
printf 'frostyard-updex 1.2 amd64\nfrostyard-updex 9.9 amd64\n' >"$APT_WITHDRAWALS_DIR/b2.txt"
must_fail "a batch with one unresolvable row is refused" "has no" \
	run withdraw.sh --codename trixie --batch b2.txt
check "the refused batch kept the resolvable version" listed_in trixie main frostyard-updex 1.2 amd64
check "the refused batch left InRelease unchanged" test "$(inrelease trixie)" = "$before"
must_fail "a dry run refuses an unresolvable row too" "has no" \
	env -u R2_ACCESS_KEY_ID -u R2_SECRET_ACCESS_KEY "$ROOT/scripts/withdraw.sh" \
	--codename trixie --batch b2.txt --dry-run

printf '# comment\nfrostyard-updex 1.2 amd64\nfrostyard-updex 1.2 amd64\n' >"$APT_WITHDRAWALS_DIR/dup.txt"
must_fail "a batch with a duplicate row is refused" "duplicate" \
	run withdraw.sh --codename trixie --batch dup.txt
printf '# comment\nfrostyard-updex 1.2 amd64\nfrostyard-updex 1.2 amd64 extra\n' >"$APT_WITHDRAWALS_DIR/fields.txt"
must_fail "a batch row with four fields is refused with its line number" "line 3" \
	run withdraw.sh --codename trixie --batch fields.txt
printf 'Bad 1.0 amd64\n' >"$APT_WITHDRAWALS_DIR/badname.txt"
must_fail "a batch row with a malformed name is refused" "invalid package name" \
	run withdraw.sh --codename trixie --batch badname.txt
must_fail "a batch name with a path is refused" "invalid batch name" \
	run withdraw.sh --codename trixie --batch ../b1.txt
must_fail "a missing batch file is refused" "cannot read the batch file" \
	run withdraw.sh --codename trixie --batch no-such-batch.txt
must_fail "a batch and a package cannot be combined" "usage" \
	run withdraw.sh --codename trixie --batch b1.txt --package frostyard-updex
must_fail "a batch requires a known codename" "unknown codename" \
	run withdraw.sh --codename stable --batch b1.txt
printf '# only a comment\n\n' >"$APT_WITHDRAWALS_DIR/empty.txt"
must_fail "an empty batch is refused" "lists no request row" \
	run withdraw.sh --codename trixie --batch empty.txt
check "the refusals left InRelease unchanged" test "$(inrelease trixie)" = "$before"

# The single mode is a batch of one request row, so it has the dry run too.
must_pass "a single withdrawal has a dry run" \
	run withdraw.sh --codename trixie --package frostyard-updex --version 1.2 --dry-run
check "the single dry run prints one plan line" test "$(grep -c '^withdraw ' "$tmp/err")" = 1
check "the single dry run names the row" grep -qx 'withdraw trixie main frostyard-updex 1.2 amd64' "$tmp/err"
check "the single dry run prints nothing on stdout" test -z "$(cat "$tmp/out")"
check "the single dry run left InRelease unchanged" test "$(inrelease trixie)" = "$before"

# --- a name in two components (core ADR-0059) ----------------------------------
#
# The one-component rule is about names, not versions: a name that two
# components hold refuses any withdrawal of it, whatever row names it.
# publish.sh refuses to make that state, so each mode builds it its own way.

# fake_suite DIR CODENAME "NAME VERSION ARCH"... writes and signs a public
# suite whose every component lists the rows: only a fabricated index can
# show a published name in two components.
fake_suite() {
	local dir=$1 codename=$2 row name version arch c arch_file sha size
	shift 2
	for c in main image; do
		for arch in amd64 arm64 all; do
			arch_file=$dir/dists/$codename/$c/binary-$arch/Packages
			mkdir -p "${arch_file%/*}"
			: >"$arch_file"
		done
		for row in "$@"; do
			read -r name version arch <<<"$row"
			arch_file=$dir/dists/$codename/$c/binary-$arch/Packages
			{
				printf 'Package: %s\nVersion: %s\nArchitecture: %s\n' "$name" "$version" "$arch"
				printf 'Filename: pool/%s/%s/%s_%s_%s.deb\n' "$c" "${name:0:1}" "$name" "$version" "$arch"
				printf 'Size: 1\nSHA256: %064d\nMD5sum: %032d\n\n' 0 0
			} >>"$arch_file"
		done
	done
	{
		printf 'Origin: test\nLabel: test\nSuite: %s\nCodename: %s\n' "$codename" "$codename"
		printf 'Architectures: all amd64 arm64\nComponents: image main\nSHA256:\n'
		for c in main image; do
			for arch in amd64 arm64 all; do
				arch_file=dists/$codename/$c/binary-$arch/Packages
				sha=$(sha256sum <"$dir/$arch_file" | cut -d' ' -f1)
				size=$(stat -c %s "$dir/$arch_file")
				printf ' %s %s %s/binary-%s/Packages\n' "$sha" "$size" "$c" "$arch"
			done
		done
	} >"$dir/dists/$codename/Release"
	gpg -q --batch --yes --local-user "${fprs[0]}" --clearsign \
		-o "$dir/dists/$codename/InRelease" "$dir/dists/$codename/Release"
}

fake_suite "$tmp/two-component-pub" trixie 'imgpkg 1.0 amd64'
must_fail "a dry run refuses a name that two components hold" "imgpkg in more than one component" \
	env APT_PUBLIC_URL="file://$tmp/two-component-pub" "$ROOT/scripts/withdraw.sh" \
	--codename trixie --package imgpkg --version 1.0 --dry-run
fake_before=$(sha256sum <"$tmp/two-component-pub/dists/trixie/InRelease")
must_fail "a dry run refuses a published component that the configuration dropped" \
	"trixie publishes component image, but the configuration says main" \
	env APT_PUBLIC_URL="file://$tmp/two-component-pub" APT_CODENAMES_FILE="$tmp/codenames-main.tsv" \
	"$ROOT/scripts/withdraw.sh" --codename trixie --package imgpkg --version 1.0 --dry-run
check "that refusal left the suite unchanged" \
	test "$(sha256sum <"$tmp/two-component-pub/dists/trixie/InRelease")" = "$fake_before"

# The live mode reads the working repositories, where the state is built
# with aptly directly, as a state repaired by hand would be.
scope namecomp
mkdeb "$tmp/nc-img" imgpkg 1.0 amd64
must_pass "publish imgpkg 1.0 to image before the two-component state" \
	run publish.sh --producer frostyard/image-only --debs "$tmp/nc-img" --codenames trixie
mkdeb "$tmp/nc-main" imgpkg 9.9 amd64
# shellcheck disable=SC2016 # the script runs in the child shell
check "the same name is put into the main working repository" \
	env APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" bash -c '. "$1/scripts/lib.sh"; aptly_init >/dev/null 2>&1
		aptly_ repo add "$(repo_name trixie main)" "$2" >/dev/null 2>&1; state_save >/dev/null 2>&1' \
	_ "$ROOT" "$tmp/nc-main/imgpkg_9.9_amd64.deb"
must_fail "a live withdrawal refuses a name that two components hold" "imgpkg in more than one component" \
	run withdraw.sh --codename trixie --package imgpkg --version 1.0
check "the refusal withdrew nothing" listed_in trixie image imgpkg 1.0 amd64
unset APT_WITHDRAWALS_DIR

# A rollback adds the component too, and then needs one snapshot per component.
scope addrollback
mkdeb "$tmp/arb-a" frostyard-updex 1.0 amd64
must_pass "publish 1.0, main only" \
	env APT_CODENAMES_FILE="$tmp/codenames-main.tsv" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/updex --debs "$tmp/arb-a" --codenames trixie
rb_main1=$(cut -d' ' -f2 "$tmp/out")
mkdeb "$tmp/arb-b" frostyard-updex 1.1 amd64
must_pass "publish 1.1, main only" \
	env APT_CODENAMES_FILE="$tmp/codenames-main.tsv" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/updex --debs "$tmp/arb-b" --codenames trixie
rb_main2=$(cut -d' ' -f2 "$tmp/out")
must_pass "a rollback with one main snapshot adds image" \
	run switch.sh --codename trixie --snapshot "$rb_main1"
check "the rollback's Release lists both components" grep -qx 'Components: image main' "$pub/dists/trixie/Release"
check "image starts empty after the rollback" test "$(cat "$pub"/dists/trixie/image/binary-*/Packages | wc -c)" = 0
check "main lists only the first version" listed_in trixie main frostyard-updex 1.0
check "main does not list the later version" not_listed_in trixie main frostyard-updex 1.1
rb_image=$(run switch.sh --list >"$tmp/list" 2>&1
	grep -oE "trixie-image-$snapshot_re-[A-Za-z0-9._-]+" "$tmp/list" | sort -u | sed -n 1p)
before=$(inrelease trixie)
must_fail "a rollback with only a main snapshot is refused once image is published" \
	"give a snapshot for component image too" \
	run switch.sh --codename trixie --snapshot "$rb_main2"
check "the refused rollback left InRelease unchanged" test "$(inrelease trixie)" = "$before"
must_pass "a rollback with the second main snapshot and the image snapshot" \
	run switch.sh --codename trixie --snapshot "$rb_main2" --snapshot "$rb_image"
check "main lists the second version again" listed_in trixie main frostyard-updex 1.1

# An image producer's first publication also publishes main, empty.
scope auditimg
export APT_PRODUCERS_FILE=$tmp/producers-audit.tsv
cat >"$APT_PRODUCERS_FILE" <<'EOF'
frostyard/updex	frostyard-updex	trixie,forky	yes	-	main
frostyard/image-only	imgpkg	trixie,forky	no	-	image
EOF
mkdeb "$tmp/a-img" imgpkg 1.0 amd64
must_pass "an image producer's first publication succeeds" \
	run publish.sh --producer frostyard/image-only --debs "$tmp/a-img"
for codename in trixie forky; do
	check "$codename lists both components" grep -qx 'Components: image main' "$pub/dists/$codename/Release"
	check "$codename lists the image package" listed_in "$codename" image imgpkg 1.0
	check "$codename main starts empty" test "$(cat "$pub/dists/$codename"/main/binary-*/Packages | wc -c)" = 0
done
mkdeb "$tmp/a-updex" frostyard-updex 3.1.0 amd64
must_pass "a main producer publishes beside it" run publish.sh --producer frostyard/updex --debs "$tmp/a-updex"
check "main lists the package" listed_in forky main frostyard-updex 3.1.0
check "image still lists its package" listed_in forky image imgpkg 1.0

# The audit reads each producer's own component.
release frostyard_updex v3.1.0 frostyard-updex_3.1.0_amd64.deb
release frostyard_image-only v1.0 imgpkg_1.0_amd64.deb
must_pass "the audit finds an image producer's release in image" \
	env PATH="$tmp/shim-gh:$PATH" "$ROOT/scripts/audit-producers.sh"
release frostyard_image-only v1.1 imgpkg_1.1_amd64.deb
if env PATH="$tmp/shim-gh:$PATH" "$ROOT/scripts/audit-producers.sh" >"$tmp/out" 2>"$tmp/err"; then
	not_ok "the audit reports an image release that is absent (unexpectedly passed)"
fi
check "the audit reports an image release that is absent" \
	grep -qx 'MISSING frostyard/image-only v1.1 imgpkg_1.1_amd64.deb' "$tmp/out"
# A package published to main does not satisfy an image registration.
release frostyard_image-only v1.2 frostyard-updex_3.1.0_amd64.deb
if env PATH="$tmp/shim-gh:$PATH" "$ROOT/scripts/audit-producers.sh" >"$tmp/out" 2>"$tmp/err"; then
	not_ok "the audit does not look in main for an image producer (unexpectedly passed)"
fi
check "the audit does not look in main for an image producer" \
	grep -qx 'MISSING frostyard/image-only v1.2 frostyard-updex_3.1.0_amd64.deb' "$tmp/out"

# The secrets check reads no codename list, so the committed default is fine.
unset APT_CODENAMES_FILE
export APT_PRODUCERS_FILE=$tmp/producers.tsv

# --- the move between components (core ADR-0059) ---------------------------------
#
# move.sh moves every published package to the component its producer is
# registered for, in one publication per codename. The scopes here use their
# own producers files: "main" registers bootc-debian for main, "image" for
# image, and "image" has no producer for trixie-thing, which therefore stays
# where it is.

printf 'frostyard/updex\tfrostyard-updex\ttrixie,forky\tyes\t-\tmain\nfrostyard/bootc-debian\tbootc,libostree-1-1\ttrixie\tno\t-\tmain\nfrostyard/trixie-only\ttrixie-thing\ttrixie\tno\t-\tmain\n' \
	>"$tmp/producers-move-main.tsv"
printf 'frostyard/updex\tfrostyard-updex\ttrixie,forky\tyes\t-\tmain\nfrostyard/bootc-debian\tbootc,libostree-1-1\ttrixie\tno\t-\timage\n' \
	>"$tmp/producers-move-image.tsv"
export APT_CODENAMES_FILE=$tmp/codenames-image.tsv

# registered_component reads the registrations of the producers file.
# shellcheck disable=SC2016 # the script runs in the child shell
registered() { env APT_PRODUCERS_FILE="$1" bash -c '. "$1/scripts/lib.sh"; registered_component "$2"' _ "$ROOT" "$2"; }
must_pass "registered_component prints an image registration" registered "$tmp/producers-move-image.tsv" libostree-1-1
check "it prints image" test "$(cat "$tmp/out")" = image
must_pass "registered_component matches the globs" registered "$tmp/producers-image.tsv" libostree-1-1x
check "it prints main for a glob registration" test "$(cat "$tmp/out")" = main
check "it prints nothing when no producer matches" test -z "$(registered "$tmp/producers-move-image.tsv" unrelated-package)"
must_fail "producers that register one name for different components are refused" \
	"register bootc for different components" registered "$tmp/producers-image.tsv" bootc

# mv_publish PRODUCER NAME VERSION ARCH... publishes one deb per architecture.
mv_publish() {
	local producer=$1 name=$2 version=$3 d
	export APT_PRODUCERS_FILE=$tmp/producers-move-main.tsv
	d=$(mktemp -d "$tmp/mv.XXXXXX")
	shift 3
	for arch in "$@"; do mkdeb "$d" "$name" "$version" "$arch"; done
	must_pass "publish $name $version ($*) as $producer" run publish.sh --producer "$producer" --debs "$d" --codenames trixie
}
# mv_setup publishes the packages the move starts from, with main producers.
mv_setup() {
	export APT_PRODUCERS_FILE=$tmp/producers-move-main.tsv
	mv_publish frostyard/bootc-debian libostree-1-1 '2026.3-1~deb13' amd64 arm64
	mv_publish frostyard/bootc-debian bootc '1.2-1~deb13' amd64 arm64
	mv_publish frostyard/bootc-debian bootc '1.10-1~deb13' amd64
	mv_publish frostyard/bootc-debian bootc '1:0.5-1~deb13' amd64
	mv_publish frostyard/trixie-only trixie-thing 1.0 amd64
	mv_publish frostyard/updex frostyard-updex 1.0 amd64
}

# working_repo CODENAME COMPONENT prints the working repository's packages.
# shellcheck disable=SC2016 # the script runs in the child shell
working_repo() {
	APTLY_ROOT=$(mktemp -d "$tmp/runner.XXXXXX") bash -c '. "$1/scripts/lib.sh"; aptly_init >/dev/null 2>&1
		aptly_ repo search -format="{{.Package}} {{.Version}} {{.Architecture}}" "$(repo_name "$2" "$3")" 2>/dev/null | LC_ALL=C sort || true' \
		_ "$ROOT" "$1" "$2"
}
# mv_drift CODENAME NAME removes NAME from the main working repository and
# saves the state: drift that no move marker explains.
# shellcheck disable=SC2016 # the script runs in the child shell
mv_drift() {
	APTLY_ROOT=$(mktemp -d "$tmp/runner.XXXXXX") bash -c '. "$1/scripts/lib.sh"; aptly_init >/dev/null 2>&1
		aptly_ repo remove "$(repo_name "$2" main)" "$3" >/dev/null 2>&1; state_save >/dev/null 2>&1' _ "$ROOT" "$1" "$2"
}
# txn_markers prints the names in the state bucket's txn/ (none when absent).
txn_markers() { rclone lsf "r2:frostyard-apt-state/$APT_STATE_PATH/txn" 2>/dev/null || true; }
no_move_marker() { [[ $(txn_markers) != *move-* ]]; }
has_move_marker() { [[ $(txn_markers) == *move-trixie* ]]; }
# A shim that fails the Nth sync of a state path's txn/ (SHIM_TXN_FAIL_AT):
# the markers are saved after the database, so this dies between the two.
mkdir -p "$tmp/shim-rclone-txn"
cat >"$tmp/shim-rclone-txn/rclone" <<EOF
#!/usr/bin/env bash
if [[ \$1 == sync && \${*: -1} == r2:frostyard-apt-state/\$SHIM_STATE_PATH/txn ]]; then
	count=\$(( \$(cat "$tmp/shim-rclone-txn/count" 2>/dev/null || echo 0) + 1 ))
	echo "\$count" >"$tmp/shim-rclone-txn/count"
	if [[ \$count == "\$SHIM_TXN_FAIL_AT" ]]; then
		echo "shim: simulated failure saving the transaction markers" >&2
		exit 1
	fi
fi
exec "$real_rclone" "\$@"
EOF
# An aptly that corrupts the bucket's pool object SHIM_CORRUPT once a publish
# switch has succeeded: a move whose read-back must fail.
mkdir -p "$tmp/shim-corrupt"
cat >"$tmp/shim-corrupt/aptly" <<EOF
#!/usr/bin/env bash
"$real_aptly" "\$@"
rc=\$?
if [[ " \$* " == *" publish switch "* && \$rc == 0 ]]; then
	printf 'corrupted bytes\n' | "$real_rclone" rcat "r2:frostyardrepo/\$APT_PREFIX/\$SHIM_CORRUPT"
fi
exit \$rc
EOF
chmod +x "$tmp/shim-rclone-txn/rclone" "$tmp/shim-corrupt/aptly"

scope move
export SHIM_STATE_PATH=move
mv_setup
pre_main=$(cut -d' ' -f2 "$tmp/out")
run switch.sh --list >"$tmp/list" 2>&1
pre_image=$(grep -oE "trixie-image-$snapshot_re-[A-Za-z0-9._-]+" "$tmp/list" | sort -u | sed -n 1p)
check "the setup left a main snapshot and an empty image snapshot" test -n "$pre_main" -a -n "$pre_image"
check "bootc is in main" listed_in trixie main bootc '1:0.5-1~deb13' amd64
cand_bootc=$(candidate trixie amd64 bootc main)
cand_ostree=$(candidate trixie arm64 libostree-1-1 main)
check "apt's candidates before the move are the newest versions" \
	test "$cand_bootc $cand_ostree" = '1:0.5-1~deb13 2026.3-1~deb13'

# Registering bootc-debian for image makes a publication of bootc fail closed
# on the one-component rule, until the move has run.
export APT_PRODUCERS_FILE=$tmp/producers-move-image.tsv
mkdeb "$tmp/mv-new" bootc '1.3-1~deb13' amd64
before=$(inrelease trixie)
state_before=$(state_sum)
must_fail "after the registration, a bootc publication fails on the one-component rule" \
	"trixie already publishes bootc in component main" \
	run publish.sh --producer frostyard/bootc-debian --debs "$tmp/mv-new"
check "the failed publication left InRelease unchanged" test "$(inrelease trixie)" = "$before"

# Dry run: the plan, and no change.
must_pass "a dry run succeeds" run move.sh --dry-run
check "the plan lists every moved version of bootc and libostree-1-1" test "$(grep -c '^move ' "$tmp/err")" = 6
check "a plan line names codename, package, version, arch and components" \
	grep -qxF 'move trixie bootc 1:0.5-1~deb13 amd64 main -> image' "$tmp/err"
check "the plan covers the other architecture" grep -qxF 'move trixie libostree-1-1 2026.3-1~deb13 arm64 main -> image' "$tmp/err"
check "a package without a producer stays" grep -qF 'trixie-thing has no registered producer and stays in main' "$tmp/err"
check "a codename without packages has nothing to move" grep -qxF 'nothing to move in forky' "$tmp/err"
check "the dry run prints nothing on stdout" test ! -s "$tmp/out"
check "the dry run left InRelease unchanged" test "$(inrelease trixie)" = "$before"
check "the dry run left the state bucket unchanged" test "$(state_sum)" = "$state_before"
check "the dry run left main listing bootc" listed_in trixie main bootc '1.2-1~deb13' arm64

# The move.
moved_pairs=('bootc 1.2-1~deb13 amd64' 'bootc 1.2-1~deb13 arm64' 'bootc 1.10-1~deb13 amd64' 'bootc 1:0.5-1~deb13 amd64'
	'libostree-1-1 2026.3-1~deb13 amd64' 'libostree-1-1 2026.3-1~deb13 arm64')
must_pass "the move succeeds" run move.sh --report "$tmp/mv-report.tsv"
check "the move reported its plan" test "$(grep -c '^move ' "$tmp/err")" = 6
check "stdout names the codename and one snapshot for each changed component" \
	matches "^trixie trixie-$snapshot_re-move trixie-image-$snapshot_re-move\$" "$(cat "$tmp/out")"
mv_main=$(cut -d' ' -f2 "$tmp/out")
mv_image=$(cut -d' ' -f3 "$tmp/out")
check "the Release lists both components" grep -qx 'Components: image main' "$pub/dists/trixie/Release"
for pair in "${moved_pairs[@]}"; do
	read -r name version arch <<<"$pair"
	check "main no longer lists $name $version $arch" not_listed_in trixie main "$name" "$version" "$arch"
	check "image lists $name $version $arch" listed_in trixie image "$name" "$version" "$arch"
	check "the main pool file of $name $version $arch stays" test -n "$(find "$pub/pool/main" -name "${name}_${version#*:}_${arch}.deb")"
	check "the image pool file of $name $version $arch exists" test -n "$(find "$pub/pool/image" -name "${name}_${version#*:}_${arch}.deb")"
done
check "an unrelated main package stays in main" listed_in trixie main frostyard-updex 1.0
check "a package without a producer stays in main" listed_in trixie main trixie-thing 1.0
check "image lists no unrelated package" not_listed_in trixie image frostyard-updex 1.0
check "apt with main and image gives the same bootc candidate as before" \
	test "$(candidate trixie amd64 bootc 'main image')" = "$cand_bootc"
check "apt with main and image gives the same libostree-1-1 candidate as before" \
	test "$(candidate trixie arm64 libostree-1-1 'main image')" = "$cand_ostree"
check "apt with main alone has no bootc candidate" candidate_is trixie amd64 bootc '' main
check "the report keeps the newest version of each package and architecture only" \
	test "$(cat "$tmp/mv-report.tsv")" = "$(printf 'trixie\tbootc\t1.2-1~deb13\tarm64\timage\ntrixie\tbootc\t1:0.5-1~deb13\tamd64\timage\ntrixie\tlibostree-1-1\t2026.3-1~deb13\tamd64\timage\ntrixie\tlibostree-1-1\t2026.3-1~deb13\tarm64\timage\n')"
check "no move marker remains in the state bucket" no_move_marker
must_pass "no pending marker is left" run switch.sh --list
check "switch --list shows no pending marker" test "$(grep -c '^pending:' "$tmp/out" || true)" = 0
must_pass "the move's suite passes the deep check" \
	run verify.sh trixie --deep image/bootc=1:0.5-1~deb13 '!main/bootc=1:0.5-1~deb13' image/libostree-1-1=2026.3-1~deb13 main/frostyard-updex=1.0
must_pass "the canary installs the reported packages from image" run apt-canary.sh --report "$tmp/mv-report.tsv"

# --recheck reads the published suite back and changes nothing.
before=$(inrelease trixie)
state_before=$(state_sum)
must_pass "a recheck succeeds" run move.sh --recheck --codename trixie --report "$tmp/mv-recheck.tsv"
check "a recheck prints the codename and its published snapshots" \
	test "$(cat "$tmp/out")" = "trixie $mv_main $mv_image"
check "a recheck reads the suite back deeply" grep -q '^verified trixie' "$tmp/err"
check "a recheck reports the newest version of each image package, as the move did" \
	test "$(cat "$tmp/mv-recheck.tsv")" = "$(cat "$tmp/mv-report.tsv")"
check "a recheck left InRelease unchanged" test "$(inrelease trixie)" = "$before"
check "a recheck left the state bucket unchanged" test "$(state_sum)" = "$state_before"
must_pass "a recheck of an unpublished codename has nothing to check" run move.sh --recheck --codename forky
check "it prints nothing for it" test ! -s "$tmp/out"
must_fail "--recheck with --dry-run is refused" "cannot be combined with --dry-run or --rebuild" run move.sh --recheck --dry-run
must_fail "--recheck with --rebuild is refused" "cannot be combined with --dry-run or --rebuild" run move.sh --recheck --rebuild
# A failed publication query is a failure, never "not published".
mkdir -p "$tmp/shim-publist"
cat >"$tmp/shim-publist/aptly" <<EOF
#!/usr/bin/env bash
if [[ " \$* " == *" publish list "* ]]; then
	echo "ERROR: simulated publication list failure" >&2
	exit 1
fi
exec "$real_aptly" "\$@"
EOF
chmod +x "$tmp/shim-publist/aptly"
must_fail "a recheck fails when the publication query fails" "cannot query the publication of trixie" \
	env PATH="$tmp/shim-publist:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/move.sh" --recheck --codename trixie

# A missing producers file is an error, not "no producer registered": the
# rollback guard and the move must fail closed.
before=$(inrelease trixie)
state_before=$(state_sum)
must_fail "a rollback with a missing producers file fails" "cannot read the producers file" \
	env APT_PRODUCERS_FILE="$tmp/no-such-producers.tsv" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/switch.sh" --codename trixie --snapshot "$mv_main" --snapshot "$mv_image"
must_fail "a forced rollback with a missing producers file fails" "cannot read the producers file" \
	env APT_PRODUCERS_FILE="$tmp/no-such-producers.tsv" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/switch.sh" --codename trixie --snapshot "$mv_main" --snapshot "$mv_image" --force
must_fail "a move with a missing producers file fails" "cannot read the producers file" \
	env APT_PRODUCERS_FILE="$tmp/no-such-producers.tsv" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/move.sh"
check "the refusals left InRelease unchanged" test "$(inrelease trixie)" = "$before"
check "the refusals left the state bucket unchanged" test "$(state_sum)" = "$state_before"

# A second run is a no-op.
before=$(inrelease trixie)
state_before=$(state_sum)
must_pass "a second move succeeds" run move.sh
check "it has nothing to move" grep -qxF 'nothing to move in trixie' "$tmp/err"
check "it prints nothing on stdout" test ! -s "$tmp/out"
check "it left InRelease unchanged" test "$(inrelease trixie)" = "$before"
check "it left the state bucket unchanged" test "$(state_sum)" = "$state_before"
must_pass "a move of one codename also accepts --codename" run move.sh --codename trixie --report "$tmp/mv-report2.tsv"
check "an empty move writes an empty report" test -f "$tmp/mv-report2.tsv" -a ! -s "$tmp/mv-report2.tsv"
must_fail "an unknown codename is refused" "unknown codename sid" run move.sh --codename sid

# After the move, bootc publishes into image.
mkdeb "$tmp/mv-new" bootc '1.3-1~deb13' amd64
must_pass "a new bootc version publishes into image" run publish.sh --producer frostyard/bootc-debian --debs "$tmp/mv-new"
check "image lists it" listed_in trixie image bootc '1.3-1~deb13' amd64
check "main does not" not_listed_in trixie main bootc '1.3-1~deb13'
check "image keeps the moved versions" listed_in trixie image bootc '1.2-1~deb13' arm64

# A snapshot taken before the move is not a rollback target.
before=$(inrelease trixie)
state_before=$(state_sum)
must_fail "a rollback to the pre-move snapshots is refused" \
	"$pre_main puts bootc in main, but its producer is registered for image; a snapshot taken before a move is not a rollback target" \
	run switch.sh --codename trixie --snapshot "$pre_main" --snapshot "$pre_image"
check "the refusal names the forward change" grep -q 'revert a move by a forward change (registration plus move.sh)' "$tmp/err"
must_fail "--force does not skip the refusal" "a snapshot taken before a move is not a rollback target" \
	run switch.sh --codename trixie --snapshot "$pre_main" --snapshot "$pre_image" --force
check "the refusals left InRelease unchanged" test "$(inrelease trixie)" = "$before"
check "the refusals left the state bucket unchanged" test "$(state_sum)" = "$state_before"
# A snapshot taken by the move itself is a fine target.
must_pass "a rollback to the move's snapshots is accepted" \
	run switch.sh --codename trixie --snapshot "$mv_main" --snapshot "$mv_image"
check "it unpublished the later bootc version" not_listed_in trixie image bootc '1.3-1~deb13'
check "it kept the moved ones in image" listed_in trixie image bootc '1:0.5-1~deb13' amd64

# A move interrupted after it became visible is completed by the next run's
# reconciliation, and a registration back to main moves the names back.
scope moveint
export SHIM_STATE_PATH=moveint
mv_publish frostyard/updex frostyard-updex 1.0 amd64
mv_publish frostyard/bootc-debian bootc '1.2-1~deb13' amd64 arm64
export APT_PRODUCERS_FILE=$tmp/producers-move-image.tsv
rm -f -- "$tmp/shim-rclone/count"
must_fail "a move interrupted after it became visible fails" "simulated failure" \
	env SHIM_FAIL_AT=3 PATH="$tmp/shim-rclone:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" "$ROOT/scripts/move.sh"
check "the interrupted move is visible in image" listed_in trixie image bootc '1.2-1~deb13' arm64
check "and gone from main" not_listed_in trixie main bootc '1.2-1~deb13' arm64
check "its state holds the move marker" has_move_marker
must_pass "the next run completes it" run move.sh --report "$tmp/mv-recovered.tsv"
check "the next run reported the completion" grep -q 'completing the interrupted publication of trixie' "$tmp/err"
check "the next run dropped the move marker" grep -q 'the interrupted move of trixie .* is visible; dropping its marker' "$tmp/err"
check "no move marker remains" no_move_marker
check "the retry verified the recovered move" grep -q 'an earlier move of trixie became visible and died before its read-back' "$tmp/err"
check "the retry ran the deep read-back" grep -q '^verified trixie: image/bootc=1.2-1~deb13' "$tmp/err"
check "the retry printed the codename and its snapshots" \
	matches "^trixie trixie-$snapshot_re-move trixie-image-$snapshot_re-move\$" "$(cat "$tmp/out")"
check "the retry wrote the report rows of the recovered move" \
	test "$(cat "$tmp/mv-recovered.tsv")" = "$(printf 'trixie\tbootc\t1.2-1~deb13\tamd64\timage\ntrixie\tbootc\t1.2-1~deb13\tarm64\timage\n')"
check "the next run did not undo the move" test -z "$(grep -E 'never became visible|rebuilt frostyard' "$tmp/err" || true)"
check "and has nothing left to move" grep -qxF 'nothing to move in trixie' "$tmp/err"
must_pass "the completed suite verifies" run verify.sh trixie --deep image/bootc=1.2-1~deb13 '!main/bootc=1.2-1~deb13'
must_pass "no pending marker remains" run switch.sh --list
check "switch --list shows none" test "$(grep -c '^pending:' "$tmp/out" || true)" = 0

export APT_PRODUCERS_FILE=$tmp/producers-move-main.tsv
must_pass "dry run of the reverse move" run move.sh --dry-run
check "the plan moves image to main" grep -qxF 'move trixie bootc 1.2-1~deb13 arm64 image -> main' "$tmp/err"
must_pass "a registration back to main moves the names back" run move.sh --report "$tmp/mv-back.tsv"
check "main lists bootc again" listed_in trixie main bootc '1.2-1~deb13' amd64
check "image no longer lists it" not_listed_in trixie image bootc '1.2-1~deb13'
check "the reverse move reports it" grep -qxP 'trixie\tbootc\t1.2-1~deb13\tarm64\tmain' "$tmp/mv-back.tsv"
check "the files stay in both pools" test -n "$(find "$pub/pool/main" -name bootc_1.2-1~deb13_arm64.deb)" -a \
	-n "$(find "$pub/pool/image" -name bootc_1.2-1~deb13_arm64.deb)"
must_pass "main publishes bootc again" run publish.sh --producer frostyard/bootc-debian --debs "$tmp/mv-new"

# A move that dies after it saved its repositories and before it published
# (an R2 error in publish switch) must not leave the components half moved: a
# publication that waits in the queue switches one component only. The next
# run, whichever script it is, undoes the move (settle_move), so the move can
# run again.
mkdir -p "$tmp/shim-noswitch"
cat >"$tmp/shim-noswitch/aptly" <<EOF
#!/usr/bin/env bash
if [[ " \$* " == *" publish switch "* ]]; then
	echo "ERROR: simulated publish failure" >&2
	exit 1
fi
exec "$real_aptly" "\$@"
EOF
chmod +x "$tmp/shim-noswitch/aptly"
scope moveundo
export SHIM_STATE_PATH=moveundo
mv_publish frostyard/bootc-debian bootc '1.2-1~deb13' amd64 arm64
mv_publish frostyard/bootc-debian bootc '1.10-1~deb13' amd64
mv_publish frostyard/updex frostyard-updex 1.0 amd64
export APT_PRODUCERS_FILE=$tmp/producers-move-image.tsv
must_fail "a move whose publication fails" "simulated publish failure" \
	env PATH="$tmp/shim-noswitch:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" "$ROOT/scripts/move.sh"
check "the failed move left main listing bootc" listed_in trixie main bootc '1.2-1~deb13'
check "the saved state holds the move marker" has_move_marker
must_pass "switch --list shows the move marker" run switch.sh --list
check "it names the components and their snapshots" \
	grep -Eq "^move pending: trixie main=trixie-$snapshot_re-move image=trixie-image-$snapshot_re-move\$" "$tmp/out"
mkdeb "$tmp/mv-undo-updex" frostyard-updex 1.1 amd64
must_pass "a publication of an unrelated main package runs" \
	run publish.sh --producer frostyard/updex --debs "$tmp/mv-undo-updex" --codenames trixie
check "it undid the interrupted move" grep -q 'an interrupted move of trixie never became visible and was undone' "$tmp/err"
check "it published the package" listed_in trixie main frostyard-updex 1.1
for pair in 'bootc 1.2-1~deb13 amd64' 'bootc 1.2-1~deb13 arm64' 'bootc 1.10-1~deb13 amd64'; do
	read -r name version arch <<<"$pair"
	check "main still lists $name $version $arch" listed_in trixie main "$name" "$version" "$arch"
	check "the main working repository holds $name $version $arch" \
		grep -qxF "$name $version $arch" <<<"$(working_repo trixie main)"
done
check "the image working repository is empty" test -z "$(working_repo trixie image)"
check "no move marker remains" no_move_marker
must_pass "the move runs again" run move.sh --report "$tmp/mv-undo.tsv"
for pair in 'bootc 1.2-1~deb13 amd64' 'bootc 1.2-1~deb13 arm64' 'bootc 1.10-1~deb13 amd64'; do
	read -r name version arch <<<"$pair"
	check "image lists $name $version $arch" listed_in trixie image "$name" "$version" "$arch"
	check "main no longer lists $name $version $arch" not_listed_in trixie main "$name" "$version" "$arch"
done
check "main keeps frostyard-updex 1.1" listed_in trixie main frostyard-updex 1.1
must_pass "the repeated move verifies" run verify.sh trixie --deep image/bootc=1.10-1~deb13 '!main/bootc=1.10-1~deb13'
check "no move marker remains after the repeated move" no_move_marker

# The marker is saved before any moved repository: a move that dies between
# the database sync and the marker sync of its first publication save (the
# database holds the moved repositories, the pending markers are lost) is
# still undone by the next publication.
scope movemark
export SHIM_STATE_PATH=movemark
mv_publish frostyard/bootc-debian bootc '1.2-1~deb13' amd64 arm64
mv_publish frostyard/bootc-debian bootc '1.10-1~deb13' amd64
mv_publish frostyard/updex frostyard-updex 1.0 amd64
export APT_PRODUCERS_FILE=$tmp/producers-move-image.tsv
rm -f -- "$tmp/shim-rclone-txn/count"
# Saves of the move: 1 the marker, 2 the publication's (the one to fail), 3 and 4 after it.
must_fail "a move that dies between the database sync and the marker sync" "simulated failure saving the transaction markers" \
	env SHIM_TXN_FAIL_AT=2 PATH="$tmp/shim-rclone-txn:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" "$ROOT/scripts/move.sh"
check "the saved state holds the move marker, written before the repositories" has_move_marker
mkdeb "$tmp/mv-mark-updex" frostyard-updex 1.1 amd64
must_pass "an unrelated main publication runs" \
	run publish.sh --producer frostyard/updex --debs "$tmp/mv-mark-updex" --codenames trixie
check "it undid the move" grep -q 'an interrupted move of trixie never became visible and was undone' "$tmp/err"
for pair in 'bootc 1.2-1~deb13 amd64' 'bootc 1.2-1~deb13 arm64' 'bootc 1.10-1~deb13 amd64'; do
	read -r name version arch <<<"$pair"
	check "$name $version $arch is listed in main" listed_in trixie main "$name" "$version" "$arch"
	check "$name $version $arch is not listed in image" not_listed_in trixie image "$name" "$version" "$arch"
	check "the main working repository holds $name $version $arch" \
		grep -qxF "$name $version $arch" <<<"$(working_repo trixie main)"
done
check "the image working repository is empty" test -z "$(working_repo trixie image)"
check "no move marker remains" no_move_marker
must_pass "the move runs again and succeeds" run move.sh
check "image lists the moved versions" listed_in trixie image bootc '1.10-1~deb13' amd64
check "main does not" not_listed_in trixie main bootc '1.10-1~deb13' amd64

# A failure after the move was saved is repeatable. Here the last save of the
# move fails (after its read-back passed): the retry verifies it again.
scope moverec
export SHIM_STATE_PATH=moverec
mv_publish frostyard/bootc-debian bootc '1.2-1~deb13' amd64
mv_publish frostyard/updex frostyard-updex 1.0 amd64
export APT_PRODUCERS_FILE=$tmp/producers-move-image.tsv
rm -f -- "$tmp/shim-rclone/count"
must_fail "a move whose last save fails" "simulated failure" \
	env SHIM_FAIL_AT=4 PATH="$tmp/shim-rclone:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" "$ROOT/scripts/move.sh"
check "the move marker is still saved" has_move_marker
must_pass "the retry is not a silent no-op" run move.sh --report "$tmp/mv-rec.tsv"
check "it verified the recovered move" grep -q '^verified trixie: image/bootc=1.2-1~deb13' "$tmp/err"
check "it printed the codename" matches '^trixie ' "$(cat "$tmp/out")"
check "it wrote the report" grep -qxP 'trixie\tbootc\t1.2-1~deb13\tamd64\timage' "$tmp/mv-rec.tsv"
check "no move marker remains after the retry" no_move_marker

# A move whose deep read-back fails keeps its marker, and a retry verifies again.
scope moveverify
export SHIM_STATE_PATH=moveverify
mv_publish frostyard/bootc-debian bootc '1.2-1~deb13' amd64
mv_publish frostyard/updex frostyard-updex 1.0 amd64
export APT_PRODUCERS_FILE=$tmp/producers-move-image.tsv
must_fail "a move whose read-back finds a corrupted image pool file fails" "does not match its SHA256" \
	env SHIM_CORRUPT=pool/image/b/bootc/bootc_1.2-1~deb13_amd64.deb PATH="$tmp/shim-corrupt:$PATH" \
	APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" "$ROOT/scripts/move.sh"
check "the move is visible" listed_in trixie image bootc '1.2-1~deb13' amd64
check "the failed read-back keeps the move marker" has_move_marker
must_fail "a recheck finds the corruption too" "MD5 mismatch in the bucket" run move.sh --recheck --codename trixie
must_fail "the retry verifies again and fails again" "does not match its SHA256" run move.sh --report "$tmp/mv-verify.tsv"
check "the retry keeps the move marker" has_move_marker
check "the retry says it verifies a recovered move" grep -q 'became visible and died before its read-back' "$tmp/err"
rclone copyto "r2:frostyardrepo/$APT_PREFIX/pool/main/b/bootc/bootc_1.2-1~deb13_amd64.deb" \
	"r2:frostyardrepo/$APT_PREFIX/pool/image/b/bootc/bootc_1.2-1~deb13_amd64.deb"
must_pass "after the repair the retry passes" run move.sh --report "$tmp/mv-verify.tsv"
check "it printed the codename" matches '^trixie ' "$(cat "$tmp/out")"
check "it wrote the report" grep -qxP 'trixie\tbootc\t1.2-1~deb13\tamd64\timage' "$tmp/mv-verify.tsv"
check "no move marker remains after the passing retry" no_move_marker
must_pass "a recheck passes" run move.sh --recheck --codename trixie

# switch.sh --force drops a move marker, and says so.
scope moveforce
export SHIM_STATE_PATH=moveforce
mv_publish frostyard/bootc-debian bootc '1.2-1~deb13' amd64
mv_publish frostyard/updex frostyard-updex 1.0 amd64
force_main=$(cut -d' ' -f2 "$tmp/out")
run switch.sh --list >"$tmp/list" 2>&1
force_image=$(grep -oE "trixie-image-$snapshot_re-[A-Za-z0-9._-]+" "$tmp/list" | sort -u | sed -n 1p)
export APT_PRODUCERS_FILE=$tmp/producers-move-image.tsv
must_fail "a move whose publication fails, again" "simulated publish failure" \
	env PATH="$tmp/shim-noswitch:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" "$ROOT/scripts/move.sh"
check "the saved state holds the move marker, again" has_move_marker
must_pass "a forced rollback runs" \
	env APT_PRODUCERS_FILE="$tmp/producers-move-main.tsv" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/switch.sh" --codename trixie --snapshot "$force_main" --snapshot "$force_image" --force
check "it dropped the move marker" grep -q 'dropping the move marker of trixie' "$tmp/err"
check "no move marker remains after the forced rollback" no_move_marker
check "main lists bootc" listed_in trixie main bootc '1.2-1~deb13' amd64

# A working repository that differs from its published snapshot, with no move
# marker to explain it, is refused.
scope movedrift
export SHIM_STATE_PATH=movedrift
mv_publish frostyard/bootc-debian bootc '1.2-1~deb13' amd64
mv_publish frostyard/updex frostyard-updex 1.0 amd64
export APT_PRODUCERS_FILE=$tmp/producers-move-image.tsv
mv_drift trixie bootc
before=$(inrelease trixie)
state_before=$(state_sum)
must_fail "a run refuses the repository that differs from its published snapshot" \
	"frostyard-trixie does not hold the package set of its published snapshot" run move.sh
check "the refusal says the move starts from what the bucket serves" grep -q 'starts from what the bucket serves' "$tmp/err"
check "the refusal says nothing was changed" grep -q 'nothing was changed' "$tmp/err"
check "the refusal left InRelease unchanged" test "$(inrelease trixie)" = "$before"
check "the refusal left the state bucket unchanged" test "$(state_sum)" = "$state_before"
must_pass "a dry run with --rebuild shows what it would do" run move.sh --dry-run --rebuild
check "it would rebuild the repository" grep -q 'would rebuild frostyard-trixie from' "$tmp/err"
check "it still plans the move" grep -qxF 'move trixie bootc 1.2-1~deb13 amd64 main -> image' "$tmp/err"
check "and changed nothing" test "$(state_sum)" = "$state_before"
must_pass "--rebuild starts from the published snapshot and moves" run move.sh --rebuild
check "the move is published in image" listed_in trixie image bootc '1.2-1~deb13' amd64
check "and gone from main" not_listed_in trixie main bootc '1.2-1~deb13'
must_pass "the rebuilt move verifies" run verify.sh trixie --deep image/bootc=1.2-1~deb13 main/frostyard-updex=1.0

# A registration for a component the codename does not publish is refused.
scope moveno
APT_CODENAMES_FILE=$tmp/codenames-main.tsv mv_publish frostyard/bootc-debian bootc '1.2-1~deb13' amd64
before=$(inrelease trixie)
must_fail "a name registered for a component the codename lacks is refused" \
	"bootc is registered for component image, which trixie does not publish" \
	env APT_CODENAMES_FILE="$tmp/codenames-main.tsv" APT_PRODUCERS_FILE="$tmp/producers-move-image.tsv" \
	APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" "$ROOT/scripts/move.sh"
check "the refusal left InRelease unchanged" test "$(inrelease trixie)" = "$before"

# --- retention (core ADR-0067) ---------------------------------------------------
#
# A producer's keep column (config/producers.tsv column 7) keeps only the
# newest N versions of each of its packages, counted per name and
# architecture. The publication that adds newer versions withdraws the rest
# from the index in the same run; pool files stay. A six-column row and a -
# row keep every version.

scope retention
export APT_CODENAMES_FILE=$tmp/codenames-main.tsv APT_PRODUCERS_FILE=$tmp/producers-retain.tsv
cat >"$tmp/producers-retain.tsv" <<'EOF'
frostyard/trixie-only	trixie-thing	trixie	no	-	main
frostyard/dasher	dasher-*	trixie	no	-	main	-
frostyard/keeper	keeper-*	trixie	no	-	main	2
frostyard/provider	provider-*	trixie	no	-	main	-
EOF
# The same rows with keeper on - (no limit), for the three versions that a
# later run with keep 2 prunes, and one row with a keep value to refuse.
cat >"$tmp/producers-retain-nolimit.tsv" <<'EOF'
frostyard/trixie-only	trixie-thing	trixie	no	-	main
frostyard/dasher	dasher-*	trixie	no	-	main	-
frostyard/keeper	keeper-*	trixie	no	-	main	-
EOF
cat >"$tmp/producers-retain-bad.tsv" <<'EOF'
frostyard/keeper	keeper-*	trixie	no	-	main	0
EOF
cat >"$tmp/producers-retain-big.tsv" <<'EOF'
frostyard/keeper	keeper-*	trixie	no	-	main	18446744073709551617
EOF

# keep_publish DESC PRODUCER DIR publishes DIR to trixie and writes the
# withdrawn rows to $tmp/pruned.tsv.
keep_publish() {
	local desc=$1 producer=$2 dir=$3
	must_pass "$desc" run publish.sh --producer "$producer" --debs "$dir" --codenames trixie \
		--pruned "$tmp/pruned.tsv"
}

# Another producer's name and a six-column row: nothing is pruned.
mkdeb "$tmp/rt-six" trixie-thing 1.0 amd64
mkdeb "$tmp/rt-six" trixie-thing 2.0 amd64
mkdeb "$tmp/rt-six" trixie-thing 3.0 amd64
keep_publish "a six-column producer publishes three versions" frostyard/trixie-only "$tmp/rt-six"
check "a six-column row keeps every version" listed trixie trixie-thing 1.0
check "the six-column row keeps the middle version too" listed trixie trixie-thing 2.0
check "the six-column row writes an empty report" test -f "$tmp/pruned.tsv" -a ! -s "$tmp/pruned.tsv"
mkdeb "$tmp/rt-dash" dasher-one 1.0 amd64
mkdeb "$tmp/rt-dash" dasher-one 2.0 amd64
mkdeb "$tmp/rt-dash" dasher-one 3.0 amd64
keep_publish "a - row publishes three versions" frostyard/dasher "$tmp/rt-dash"
check "a - row keeps every version" listed trixie dasher-one 1.0
check "a - row keeps the middle version too" listed trixie dasher-one 2.0
check "a - row writes an empty report" test -f "$tmp/pruned.tsv" -a ! -s "$tmp/pruned.tsv"

# Three releases of the same packages: the third keeps the newest two.
mkdeb "$tmp/rt1" keeper-main 1.9 amd64
mkdeb "$tmp/rt1" keeper-tilde 2.0 amd64
mkdeb "$tmp/rt1" keeper-epoch 1.5 amd64
mkdeb "$tmp/rt1" keeper-arch 1.0 amd64
mkdeb "$tmp/rt1" keeper-arch 1.0 arm64
# An Architecture: all build with the version that amd64 prunes later.
mkdeb "$tmp/rt1" keeper-main 1.9 all
keep_publish "a first keeper release" frostyard/keeper "$tmp/rt1"
# Another producer's package that provides the version amd64 prunes later.
MKDEB_CONTROL='Provides: keeper-main (= 1.9)' mkdeb "$tmp/rt-prov" provider-x 5.0 amd64
keep_publish "a package that provides a keeper version" frostyard/provider "$tmp/rt-prov"
check "the first keeper release is listed" listed trixie keeper-main 1.9
check "a first release writes an empty report" test -f "$tmp/pruned.tsv" -a ! -s "$tmp/pruned.tsv"
mkdeb "$tmp/rt2" keeper-main 1.10 amd64
mkdeb "$tmp/rt2" keeper-tilde 2.0~rc1 amd64
mkdeb "$tmp/rt2" keeper-epoch 2.0 amd64
mkdeb "$tmp/rt2" keeper-arch 2.0 amd64
mkdeb "$tmp/rt2" keeper-arch 2.0 arm64
keep_publish "a second keeper release" frostyard/keeper "$tmp/rt2"
check "two versions are within the limit" listed trixie keeper-main 1.10
check "the older of two versions stays" listed trixie keeper-main 1.9
check "a ~ prerelease is older than its release, so both stay" listed trixie keeper-tilde 2.0
check "a second release writes an empty report" test -f "$tmp/pruned.tsv" -a ! -s "$tmp/pruned.tsv"
mkdeb "$tmp/rt3" keeper-main 6.2.0-frostyard20261102153446 amd64
mkdeb "$tmp/rt3" keeper-tilde 2.1 amd64
mkdeb "$tmp/rt3" keeper-epoch 10:0.1 amd64
mkdeb "$tmp/rt3" keeper-arch 3.0 amd64
keep_publish "a third keeper release" frostyard/keeper "$tmp/rt3"
check "the newest version is listed" listed trixie keeper-main 6.2.0-frostyard20261102153446
check "the second newest version is listed" listed trixie keeper-main 1.10
check "the oldest version left the index" not_listed trixie keeper-main 1.9 amd64
check "the all build of that version stays" listed trixie keeper-main 1.9 all
check "a package that provides the pruned version stays" listed trixie provider-x 5.0
check "the pruned version's pool file stays" test -n "$(pool_file keeper-main_1.9_amd64.deb)"
check "a newer release is listed above its ~ prerelease" listed trixie keeper-tilde 2.1
check "the ~ prerelease left the index" not_listed trixie keeper-tilde 2.0~rc1
check "its release stays" listed trixie keeper-tilde 2.0
check "the newest epoch version is listed" listed trixie keeper-epoch 10:0.1
check "the version below it stays" listed trixie keeper-epoch 2.0
check "the oldest epoch version left the index" not_listed trixie keeper-epoch 1.5
check "amd64 pruned its oldest version" not_listed trixie keeper-arch 1.0 amd64
check "arm64 kept two versions of the same name" listed trixie keeper-arch 1.0 arm64
check "the pruned amd64 pool file stays" test -n "$(pool_file keeper-arch_1.0_amd64.deb)"
check "the run logged each pruned version" grep -qx 'prune trixie main keeper-main 1.9 amd64' "$tmp/err"
pruned_want=$(printf 'trixie\tkeeper-arch\t1.0\tamd64\tmain\ntrixie\tkeeper-epoch\t1.5\tamd64\tmain\ntrixie\tkeeper-main\t1.9\tamd64\tmain\ntrixie\tkeeper-tilde\t2.0~rc1\tamd64\tmain')
check "--pruned writes codename name version arch component rows" test "$(cat "$tmp/pruned.tsv")" = "$pruned_want"
check "another producer's versions stay" listed trixie trixie-thing 1.0
check "another producer's middle version stays" listed trixie trixie-thing 2.0
check "a - producer's versions stay" listed trixie dasher-one 1.0

# A release older than the newest N is refused before any state change.
mkdeb "$tmp/rt-old" keeper-main 0.9 amd64
before=$(inrelease trixie)
state_before=$(state_sum)
must_fail "a release older than the newest N is refused" \
	"keeper-main 0.9 amd64 is older than the newest 2 published versions; retention would withdraw it at once" \
	run publish.sh --producer frostyard/keeper --debs "$tmp/rt-old" --codenames trixie
check "the refusal left InRelease unchanged" test "$(inrelease trixie)" = "$before"
check "the refusal left the state bucket unchanged" test "$(state_sum)" = "$state_before"

# - keeps three versions; switching the row to 2 and re-running the newest
# release prunes the oldest versions, including that of a package the
# release does not hold at all.
export APT_PRODUCERS_FILE=$tmp/producers-retain-nolimit.tsv
mkdeb "$tmp/rt-none1" keeper-rerun 1.0 amd64
mkdeb "$tmp/rt-none1" keeper-rerun 2.0 amd64
mkdeb "$tmp/rt-none1" keeper-hold 1.0 amd64
mkdeb "$tmp/rt-none1" keeper-hold 2.0 amd64
mkdeb "$tmp/rt-none1" keeper-hold 3.0 amd64
keep_publish "a keeper release while its row has no limit" frostyard/keeper "$tmp/rt-none1"
mkdeb "$tmp/rt-none2" keeper-rerun 3.0 amd64
keep_publish "a third version while the row has no limit" frostyard/keeper "$tmp/rt-none2"
check "a - row keeps three versions" listed trixie keeper-rerun 1.0
check "a - row keeps the newest of three" listed trixie keeper-rerun 3.0
check "a - row keeps a package no later release holds" listed trixie keeper-hold 3.0
export APT_PRODUCERS_FILE=$tmp/producers-retain.tsv
before=$(inrelease trixie)
keep_publish "a re-run of the newest release applies the rule and publishes" frostyard/keeper "$tmp/rt-none2"
check "the re-run left the oldest version out" not_listed trixie keeper-rerun 1.0
check "the re-run kept the newest two" listed trixie keeper-rerun 2.0
check "the re-run kept the release itself" listed trixie keeper-rerun 3.0
check "a package the release does not hold keeps its newest two" not_listed trixie keeper-hold 1.0
check "that package's other versions stay" listed trixie keeper-hold 2.0
check "the re-run published a new Release" test "$(inrelease trixie)" != "$before"
check "the re-run logged a package the release does not hold" grep -qx 'prune trixie main keeper-hold 1.0 amd64' "$tmp/err"
check "the re-run deletes no pool file" test -n "$(pool_file keeper-rerun_1.0_amd64.deb)"
rerun_want=$(printf 'trixie\tkeeper-hold\t1.0\tamd64\tmain\ntrixie\tkeeper-rerun\t1.0\tamd64\tmain')
check "--pruned lists both withdrawn versions" test "$(cat "$tmp/pruned.tsv")" = "$rerun_want"

# A dry run names the rule; a producer with no limit logs no rule.
must_pass "a dry run of a keeper release" run publish.sh --producer frostyard/keeper --debs "$tmp/rt3" --dry-run
check "the dry run names the retention rule" \
	grep -qx 'retention: keep the newest 2 versions of each package of frostyard/keeper in main' "$tmp/err"
must_pass "a dry run of a producer with no limit" run publish.sh --producer frostyard/dasher --debs "$tmp/rt-dash" --dry-run
check "a producer with no limit logs no retention rule" test -z "$(grep 'retention:' "$tmp/err" || true)"

# An invalid keep value is refused before any state change.
before=$(inrelease trixie)
must_fail "an invalid keep value is refused" "has keep '0' in config/producers.tsv" \
	env APT_PRODUCERS_FILE="$tmp/producers-retain-bad.tsv" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/keeper --debs "$tmp/rt3" --codenames trixie
check "the invalid keep refusal left InRelease unchanged" test "$(inrelease trixie)" = "$before"
must_fail "a keep value above 999 is refused" "give an integer from 1 to 999" \
	env APT_PRODUCERS_FILE="$tmp/producers-retain-big.tsv" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" \
	"$ROOT/scripts/publish.sh" --producer frostyard/keeper --debs "$tmp/rt3" --codenames trixie

# The secrets check reads no codename list, as in the section before this one.
unset APT_CODENAMES_FILE
export APT_PRODUCERS_FILE=$tmp/producers.tsv

# --- build provenance (ADR-0004) -----------------------------------------------

# gh that downloads one fake .deb and logs every call to $tmp/prov-calls;
# `attestation verify` fails when FAKE_VERIFY_FAIL is set.
mkdir -p "$tmp/shim-prov"
cat >"$tmp/shim-prov/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
'release download')
	printf '%s\n' "\$*" >>"$tmp/prov-calls"
	dir=''
	while ((\$#)); do
		[[ \$1 == --dir ]] && dir=\$2
		shift
	done
	mkdir -p "\$dir"
	printf 'not a real .deb\n' >"\$dir/pkg_1.0_amd64.deb"
	;;
'attestation verify')
	printf '%s\n' "\$*" >>"$tmp/prov-calls"
	if [[ -n \${FAKE_VERIFY_FAIL:-} ]]; then
		echo 'shim: no attestation for this file' >&2
		exit 1
	fi
	;;
*) exit 2 ;;
esac
EOF
chmod +x "$tmp/shim-prov/gh"
# A producer with a tag policy, one with a branch policy, an unattested one,
# the retired `yes`, and a value that is no valid form.
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
	frostyard/tagged pkg trixie 'release.yml@refs/tags/v*' - main - \
	frostyard/branch pkg trixie 'build.yml@refs/heads/main' - main - \
	frostyard/plain pkg trixie no - main - \
	frostyard/legacy pkg trixie yes - main - \
	frostyard/badref pkg trixie 'release.yml@refs/pull/1/merge' - main - \
	>"$tmp/producers-prov.tsv"
: >"$tmp/prov-calls"
prov() {
	env PATH="$tmp/shim-prov:$PATH" APT_PRODUCERS_FILE="$tmp/producers-prov.tsv" \
		"$ROOT/scripts/fetch-release.sh" "$@"
}

# a. The tag pattern matches, and the attestation must come from release.yml
# at that tag.
prov_tag=$(mktemp -d "$tmp/prov.XXXXXX")
: >"$tmp/prov-calls"
must_pass "a tag policy verifies a matching release" prov frostyard/tagged v1.2.0 "$prov_tag"
prov_want="attestation verify $prov_tag/pkg_1.0_amd64.deb --repo frostyard/tagged"
prov_want+=" --signer-workflow frostyard/tagged/.github/workflows/release.yml"
prov_want+=" --source-ref refs/tags/v1.2.0 --deny-self-hosted-runners"
check "the tag policy pins the signing workflow and the tag ref" \
	grep -qxF "$prov_want" "$tmp/prov-calls"
check "the tag policy reports the workflow and the ref" \
	grep -qF 'verified the provenance of 1 files: frostyard/tagged/.github/workflows/release.yml at refs/tags/v1.2.0' "$tmp/err"

# b. A tag outside the pattern is refused before the download.
: >"$tmp/prov-calls"
must_fail "a tag outside the policy's pattern is refused" 'releases only tags that match v\*; dev does not' \
	prov frostyard/tagged dev "$(mktemp -d "$tmp/prov.XXXXXX")"
if grep -q '^release download' "$tmp/prov-calls"; then
	not_ok "the refused tag downloads nothing"
fi
ok "the refused tag downloads nothing"

# c. A branch policy accepts any release tag and pins the branch ref.
prov_branch=$(mktemp -d "$tmp/prov.XXXXXX")
: >"$tmp/prov-calls"
must_pass "a branch policy verifies any release tag" \
	prov frostyard/branch main-20261102170521-31f199e "$prov_branch"
prov_want="attestation verify $prov_branch/pkg_1.0_amd64.deb --repo frostyard/branch"
prov_want+=" --signer-workflow frostyard/branch/.github/workflows/build.yml"
prov_want+=" --source-ref refs/heads/main --deny-self-hosted-runners"
check "the branch policy pins the signing workflow and the branch ref" \
	grep -qxF "$prov_want" "$tmp/prov-calls"

# d. A failed attestation check refuses the release.
: >"$tmp/prov-calls"
export FAKE_VERIFY_FAIL=1
must_fail "a failed attestation verification refuses the release" 'has no valid provenance' \
	prov frostyard/tagged v1.2.0 "$(mktemp -d "$tmp/prov.XXXXXX")"
unset FAKE_VERIFY_FAIL

# e. `no` keeps trusting the assets, with a warning and no check.
: >"$tmp/prov-calls"
must_pass "an unattested producer's release is trusted" prov frostyard/plain v1.2.0 "$(mktemp -d "$tmp/prov.XXXXXX")"
check "the unattested producer warns" grep -q 'is not attested' "$tmp/err"
if grep -q '^attestation verify' "$tmp/prov-calls"; then
	not_ok "the unattested producer runs no attestation check"
fi
ok "the unattested producer runs no attestation check"

# f. The retired `yes` fails closed, before the download.
: >"$tmp/prov-calls"
must_fail "the retired attested=yes is refused" \
	'must be no or WORKFLOW@refs/tags/PATTERN or WORKFLOW@refs/heads/BRANCH' \
	prov frostyard/legacy v1.2.0 "$(mktemp -d "$tmp/prov.XXXXXX")"
if grep -q '^release download' "$tmp/prov-calls"; then
	not_ok "attested=yes downloads nothing"
fi
ok "attested=yes downloads nothing"

# g. A ref that is no valid form fails closed, before the download.
: >"$tmp/prov-calls"
must_fail "a policy with an invalid ref is refused" \
	'must be no or WORKFLOW@refs/tags/PATTERN or WORKFLOW@refs/heads/BRANCH' \
	prov frostyard/badref v1.2.0 "$(mktemp -d "$tmp/prov.XXXXXX")"
if grep -q '^release download' "$tmp/prov-calls"; then
	not_ok "an invalid ref downloads nothing"
fi
ok "an invalid ref downloads nothing"

# --- secrets check ------------------------------------------------------------

# Cloudflare's API accepts token testcftoken and only zone testzone; gh
# accepts token testdispatch and logs each call to $tmp/dispatches.
mkdir -p "$tmp/shim-check"
cat >"$tmp/shim-check/curl" <<'EOF'
#!/usr/bin/env bash
[[ $* == *'Bearer testcftoken'* ]] || {
	echo '{"success": false, "errors": [{"message": "Authentication error"}]}'
	exit 0
}
case $* in
*/zones/testzone/purge_cache*) echo '{"success": true}' ;;
*/purge_cache*) echo '{"success": false, "errors": [{"message": "Could not route to zone"}]}' ;;
*/user/tokens/verify*) echo '{"success": true, "result": {"status": "active"}}' ;;
*) exit 2 ;;
esac
EOF
cat >"$tmp/shim-check/gh" <<EOF
#!/usr/bin/env bash
[[ \$GH_TOKEN == testdispatch ]] || { echo 'HTTP 401: Bad credentials' >&2; exit 1; }
echo "\$*" >>"$tmp/dispatches"
EOF
chmod +x "$tmp/shim-check/curl" "$tmp/shim-check/gh"
secrets=(PATH="$tmp/shim-check:$PATH" APT_SIGNING_KEY="$(gpg --armor --export-secret-keys "${fprs[0]}")"
	CLOUDFLARE_ZONE=testzone CLOUDFLARE_API_TOKEN=testcftoken GH_TOKEN=testdispatch)
must_pass "the secrets check passes with working secrets" env "${secrets[@]}" "$ROOT/scripts/check-secrets.sh"
check "the secrets check covers the key, both buckets, the zone and snosi" test "$(grep -c '^ok - ' "$tmp/out")" = 5
check "the dispatch check sends no build event" \
	grep -qx 'api --method POST repos/frostyard/snosi/dispatches -f event_type=apt-publisher-token-check' "$tmp/dispatches"
if env "${secrets[@]}" APT_SIGNING_KEY_FPR=0000000000000000000000000000000000000000 \
	APT_STATE_BUCKET=missing-bucket CLOUDFLARE_ZONE=otherzone \
	"$ROOT/scripts/check-secrets.sh" >"$tmp/out" 2>"$tmp/err"; then
	not_ok "the secrets check reports every failing secret (unexpectedly passed)"
fi
check "the secrets check reports every failing secret" test "$(grep -c '^FAIL - ' "$tmp/out")" = 3
check "a failing secret does not stop the other checks" grep -qx 'ok - DISPATCH_TOKEN can dispatch to frostyard/snosi' "$tmp/out"

# These cases fail on the old workflow text, so the shell check cannot silently stop working.
# Each case starts from a fresh repository copy under $tmp and edits only that copy.
copy_workflow_config() {
	rm -rf -- "$tmp/cfg"
	mkdir "$tmp/cfg"
	tar -C "$ROOT" --exclude=.git -cf - . | tar -C "$tmp/cfg" -xf -
}

copy_workflow_config
must_pass "workflow shell contract accepts the unchanged workflows" "$tmp/cfg/tests/check-config.sh"

copy_workflow_config
check "the publish defaults removal fixture exists" grep -q '^defaults:$' "$tmp/cfg/.github/workflows/publish.yml"
check "the publish run block fixture exists" grep -q '^  run:$' "$tmp/cfg/.github/workflows/publish.yml"
check "the publish shell fixture exists" grep -q '^    shell: bash$' "$tmp/cfg/.github/workflows/publish.yml"
sed -i -e '/^defaults:$/d' -e '/^  run:$/{d;}' -e '/^    shell: bash$/d' "$tmp/cfg/.github/workflows/publish.yml"
check "removing the publish defaults changed the file" test "$(grep -c '^defaults:$' "$tmp/cfg/.github/workflows/publish.yml")" = 0
must_fail "the workflow shell contract checks publish defaults" "publish.yml must set defaults.run.shell: bash" \
	"$tmp/cfg/tests/check-config.sh"

copy_workflow_config
check "the audit defaults removal fixture exists" grep -q '^defaults:$' "$tmp/cfg/.github/workflows/audit.yml"
check "the audit run block fixture exists" grep -q '^  run:$' "$tmp/cfg/.github/workflows/audit.yml"
check "the audit shell fixture exists" grep -q '^    shell: bash$' "$tmp/cfg/.github/workflows/audit.yml"
sed -i -e '/^defaults:$/d' -e '/^  run:$/{d;}' -e '/^    shell: bash$/d' "$tmp/cfg/.github/workflows/audit.yml"
check "removing the audit defaults changed the file" test "$(grep -c '^defaults:$' "$tmp/cfg/.github/workflows/audit.yml")" = 0
must_fail "the workflow shell contract checks audit defaults" "audit.yml must set defaults.run.shell: bash" \
	"$tmp/cfg/tests/check-config.sh"

copy_workflow_config
sed -i '/^        id: publish$/a\        shell: bash -e {0}' "$tmp/cfg/.github/workflows/publish.yml"
check "the publish shell override changed the file" grep -Fxq '        shell: bash -e {0}' "$tmp/cfg/.github/workflows/publish.yml"
must_fail "the workflow shell contract rejects publish shell overrides" "publish.yml:[0-9]* sets shell: bash -e {0}; only shell: bash" \
	"$tmp/cfg/tests/check-config.sh"

copy_workflow_config
sed -i '/^      - name: Audit producers.*latest releases$/a\        shell: sh' "$tmp/cfg/.github/workflows/audit.yml"
check "the audit shell override changed the file" grep -Fxq '        shell: sh' "$tmp/cfg/.github/workflows/audit.yml"
must_fail "the workflow shell contract rejects audit shell overrides" "audit.yml:[0-9]* sets shell: sh; only shell: bash" \
	"$tmp/cfg/tests/check-config.sh"

copy_workflow_config
sed -i '/^      - name: Publish$/i\      - shell: sh\n        run: "true"' "$tmp/cfg/.github/workflows/publish.yml"
check "the publish first-key shell override changed the file" grep -Fxq '      - shell: sh' "$tmp/cfg/.github/workflows/publish.yml"
must_fail "the workflow shell contract rejects first-key shell overrides" "publish.yml:[0-9]*.*only shell: bash" \
	"$tmp/cfg/tests/check-config.sh"

copy_workflow_config
sed -i '/^      - name: Audit producers.*latest releases$/a\        '\''shell'\'': sh' "$tmp/cfg/.github/workflows/audit.yml"
check "the audit single-quoted shell key changed the file" grep -Fxq "        'shell': sh" "$tmp/cfg/.github/workflows/audit.yml"
must_fail "the workflow shell contract rejects single-quoted shell keys" "audit.yml:[0-9]*.*only shell: bash" \
	"$tmp/cfg/tests/check-config.sh"

copy_workflow_config
sed -i '/^      - name: Audit producers.*latest releases$/a\        "shell": sh' "$tmp/cfg/.github/workflows/audit.yml"
check "the audit double-quoted shell key changed the file" grep -Fxq '        "shell": sh' "$tmp/cfg/.github/workflows/audit.yml"
must_fail "the workflow shell contract rejects double-quoted shell keys" "audit.yml:[0-9]*.*only shell: bash" \
	"$tmp/cfg/tests/check-config.sh"

copy_workflow_config
sed -i '/^    timeout-minutes: 15$/a\    defaults: {run: {shell: sh}}' "$tmp/cfg/.github/workflows/audit.yml"
check "the audit inline defaults shell override changed the file" grep -Fxq '    defaults: {run: {shell: sh}}' "$tmp/cfg/.github/workflows/audit.yml"
must_fail "the workflow shell contract rejects inline defaults shell overrides" "audit.yml:[0-9]*.*only shell: bash" \
	"$tmp/cfg/tests/check-config.sh"

echo "1..$n"
