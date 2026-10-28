#!/usr/bin/env bash
# End-to-end test of the publisher against a local S3 server (rclone serve
# s3) and a throwaway signing key. Each script runs with a fresh APTLY_ROOT,
# as on a new CI runner, so aptly state survives only through the state
# bucket. apt itself consumes the published result.
#
# KEEP_TMP=1 keeps the work directory for inspection.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
for tool in aptly rclone jq gpg gpgv gpgconf dpkg-deb apt-get apt-cache curl python3 sha256sum gzip; do
	command -v "$tool" >/dev/null || {
		echo "not ok - $tool is required" >&2
		exit 1
	}
done

tmp=$(mktemp -d)
server_pid=''
cleanup() {
	[[ -n $server_pid ]] && kill "$server_pid" 2>/dev/null
	GNUPGHOME=$tmp/gnupg gpgconf --kill gpg-agent 2>/dev/null || true
	if [[ -n ${KEEP_TMP:-} ]]; then
		echo "kept $tmp" >&2
	else
		rm -rf -- "$tmp"
	fi
}
trap cleanup EXIT

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
frostyard/updex	frostyard-updex	trixie,forky	yes	frostyard/snosi	main
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
# the epoch left out of the file name as Debian does.
mkdeb() {
	local dir=$1 name=$2 version=$3 arch=$4 src
	src=$(mktemp -d "$tmp/build.XXXXXX")
	mkdir -p "$src/DEBIAN" "$src/usr/share/doc/$name" "$dir"
	printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: test <test@invalid>\nDescription: test package\n' \
		"$name" "$version" "$arch" >"$src/DEBIAN/control"
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
check "purge lists the same 15 URLs as before" test "$("$ROOT/scripts/purge-cache.sh" --print trixie | wc -l)" = 15
expected=("$APT_PUBLIC_URL/dists/trixie/InRelease" "$APT_PUBLIC_URL/dists/trixie/Release" "$APT_PUBLIC_URL/dists/trixie/Release.gpg")
for arch in amd64 arm64 all; do
	for f in Packages Packages.gz Packages.bz2 Release; do
		expected+=("$APT_PUBLIC_URL/dists/trixie/main/binary-$arch/$f")
	done
done
check "purge lists the same URLs in the same order as before" \
	test "$("$ROOT/scripts/purge-cache.sh" --print trixie)" = "$(printf '%s\n' "${expected[@]}")"

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
check "purge lists 27 URLs for two components" test "$(wc -l <"$tmp/purge.txt")" = 27
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
must_pass "a withdrawal adds image to trixie" \
	run withdraw.sh --codename trixie --package frostyard-updex --version 1.0
check "the withdrawal prints one line" test "$(wc -l <"$tmp/out")" = 1
check "the withdrawal's Release lists both components" grep -qx 'Components: image main' "$pub/dists/trixie/Release"
check "main lacks the withdrawn version" not_listed_in trixie main frostyard-updex 1.0
check "main keeps the other version" listed_in trixie main frostyard-updex 1.1
check "image is empty" test "$(cat "$pub"/dists/trixie/image/binary-*/Packages | wc -c)" = 0
must_pass "the withdrawal's suite verifies" run verify.sh trixie --deep

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
	env SHIM_FAIL_AT=2 PATH="$tmp/shim-rclone:$PATH" APTLY_ROOT="$(mktemp -d "$tmp/runner.XXXXXX")" "$ROOT/scripts/move.sh"
check "the interrupted move is visible in image" listed_in trixie image bootc '1.2-1~deb13' arm64
check "and gone from main" not_listed_in trixie main bootc '1.2-1~deb13' arm64
check "its state holds the move marker" has_move_marker
must_pass "the next run completes it" run move.sh
check "the next run reported the completion" grep -q 'completing the interrupted publication of trixie' "$tmp/err"
check "the next run dropped the move marker" grep -q 'the interrupted move of trixie .* is visible; dropping its marker' "$tmp/err"
check "no move marker remains" no_move_marker
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

# The secrets check reads no codename list, as in the section before this one.
unset APT_CODENAMES_FILE
export APT_PRODUCERS_FILE=$tmp/producers.tsv

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

echo "1..$n"
