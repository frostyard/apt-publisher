#!/usr/bin/env bash
# Static, credential-free checks of the repository baseline: the rows of
# frostyard/core docs/specs/repository-baseline.md (core ADR-0071) that apply
# to this repository. Reads the working tree; writes nothing.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

fail() {
	printf 'not ok - %s\n' "$*" >&2
	exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is not on PATH (mise install)"
shopt -s nullglob

# B1: AGENTS.md is the canonical file; the four aliases are relative symlinks
# to it (core ADR-0018, ADR-0029).
[[ -f $ROOT/AGENTS.md && ! -L $ROOT/AGENTS.md ]] ||
	fail "AGENTS.md must be a regular file, not a symlink"
for alias in CLAUDE.md GEMINI.md .cursorrules .github/copilot-instructions.md; do
	[[ -L $ROOT/$alias ]] || fail "$alias must be a symlink to AGENTS.md"
	target=$(readlink "$ROOT/$alias")
	[[ $target != /* ]] ||
		fail "$alias must be a relative symlink, not $target"
	resolved=$(realpath "$ROOT/$alias" 2>/dev/null) ||
		fail "$alias does not resolve; its target is $target"
	[[ $resolved == "$(realpath "$ROOT/AGENTS.md")" ]] ||
		fail "$alias resolves to $resolved, not AGENTS.md"
done

# B2: the corrections inbox (ADR-0018): the rules of core's
# scripts/check-corrections.mjs. Every line is a JSON object with exactly the 5
# string fields, no duplicate key, a real YYYY-MM-DD date, and no empty
# scope, correction or evidence. A blank line fails; the last line counts with
# or without a trailing newline. The path is an argument, never part of the
# Python source.
corrections=$ROOT/.memory/corrections.jsonl
[[ -f $corrections ]] || fail ".memory/corrections.jsonl is missing"
correction_lines=$(python3 - "$corrections" <<'PY'
import datetime
import json
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8", newline="") as handle:
    text = handle.read()
lines = text.split("\n")
if lines and lines[-1] == "":
    lines.pop()
required = ("date", "scope", "correction", "evidence", "promoted_to")
# The whitespace that JavaScript's String.prototype.trim() removes: a lone
# "\r" and a byte-order mark are whitespace to a reader's JavaScript.
WHITESPACE = (
    "\t\n\v\f\r \u00a0\u1680"
    + "".join(chr(code) for code in range(0x2000, 0x200B))
    + "\u2028\u2029\u202f\u205f\u3000\ufeff"
)


def trimmed(text):
    return text.strip(WHITESPACE)


class DuplicateKey(Exception):
    pass


def pairs(items):
    names = [name for name, _ in items]
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        raise DuplicateKey("duplicate key(s): " + ", ".join(duplicates))
    return dict(items)


def problem(number, message):
    sys.stderr.write(f"{path}:{number}: {message}\n")
    sys.exit(1)


for number, line in enumerate(lines, 1):
    if trimmed(line) == "":
        problem(number, "blank line")
    try:
        value = json.loads(line, object_pairs_hook=pairs)
    except DuplicateKey as error:
        problem(number, str(error))
    except ValueError:
        problem(number, "invalid JSON")
    if not isinstance(value, dict):
        problem(number, "not a JSON object")
    missing = [key for key in required if key not in value]
    unknown = [key for key in value if key not in required]
    if missing or unknown:
        parts = []
        if missing:
            parts.append("missing key(s): " + ", ".join(missing))
        if unknown:
            parts.append("unknown key(s): " + ", ".join(unknown))
        problem(number, "; ".join(parts))
    for key in required:
        if not isinstance(value[key], str):
            problem(number, f"value for {key} is not a string")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value["date"]):
        problem(number, f"invalid date: {value['date']}")
    try:
        datetime.date.fromisoformat(value["date"])
    except ValueError:
        problem(number, f"invalid date: {value['date']}")
    for key in ("scope", "correction", "evidence"):
        if trimmed(value[key]) == "":
            problem(number, f"{key} is empty")
sys.stdout.write(str(len(lines)))
PY
) || fail "the corrections check failed; see the line above"
[[ $correction_lines =~ ^[0-9]+$ ]] ||
	fail "the corrections check printed no line count"

# B3: the docs shape (core ADR-0025): the index, the org ADR list and the 4
# category templates.
for doc in docs/README.md docs/org-adrs.md docs/adr/TEMPLATE.md \
	docs/design/TEMPLATE.md docs/specs/TEMPLATE.md docs/plans/TEMPLATE.md; do
	[[ -f $ROOT/$doc ]] || fail "$doc is missing"
done
grep -q 'org-adrs\.md' "$ROOT/docs/README.md" ||
	fail "docs/README.md does not link org-adrs.md"

# B4: the make gate triad and the tool pins (core ADR-0043, ADR-0044).
for target in verify check ci; do
	grep -qE "^$target:" "$ROOT/Makefile" ||
		fail "the Makefile has no $target: target"
done
grep -qE '^ci:[[:space:]]+verify([[:space:]]|$)' "$ROOT/Makefile" ||
	fail "the Makefile ci: rule must list verify as a prerequisite"
for pin in mise.toml mise.lock; do
	[[ -f $ROOT/$pin ]] || fail "$pin is missing"
done

# B5: SHA-pinned actions, least-privilege permissions, no persisted
# credentials (core ADR-0021). A step action pins a full SHA with the version
# in a comment; a job-level reusable workflow pins a full SHA with a comment.
workflow_files=("$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml)
((${#workflow_files[@]})) || fail "no workflow files in .github/workflows"
for f in "${workflow_files[@]}"; do
	name=.github/workflows/$(basename "$f")
	problem=$(awk -v name="$name" '
		/^[[:space:]]*(#|$)/ { next }
		/^[[:space:]]*-[[:space:]]+uses:/ { step = 1 }
		/^[[:space:]]*uses:/ && !/^[[:space:]]*-/ { step = 0 }
		!/(^|[[:space:]-])uses:[[:space:]]/ { next }
		{
			value = $0
			sub(/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*/, "", value)
			if (value ~ /^\.\//) next
			ref = value
			sub(/^.*@/, "", ref)
			sha = ref
			sub(/[[:space:]].*$/, "", sha)
			if (sha !~ /^[0-9a-f]+$/ || length(sha) != 40) {
				print name ":" FNR ": uses is not pinned to a 40-character commit SHA: " value
				next
			}
			if (ref !~ /[[:space:]]+#[[:space:]]+[^[:space:]]/) {
				print name ":" FNR ": the pinned action has no version comment: " value
				next
			}
			if (step && ref !~ /#[[:space:]]+v[0-9]/) {
				print name ":" FNR ": the step action comment must name the version (# vX.Y.Z): " value
			}
		}' "$f") || fail "$name: the uses scan failed"
	[[ -z $problem ]] || fail "${problem%%$'\n'*}"

	problem=$(awk -v name="$name" '
		/^permissions:/ {
			seen = 1
			if ($0 ~ /\{\}/) {
				if ($0 !~ /^permissions:[[:space:]]*\{\}[[:space:]]*$/)
					print name ":" FNR ": the permissions line must hold {} alone"
				exit
			}
			if ($0 !~ /^permissions:[[:space:]]*$/) {
				print name ":" FNR ": the permissions line must be permissions: {} or a block of read scopes"
				exit
			}
			block = 1
			next
		}
		block {
			if ($0 ~ /^[[:space:]]*(#|$)/) next
			if ($0 ~ /^[^[:space:]]/) exit
			if ($0 !~ /^[[:space:]]+[A-Za-z-]+:[[:space:]]+read[[:space:]]*$/) {
				print name ":" FNR ": the permissions block holds a scope that is not read: " $0
				exit
			}
		}
		END { if (!seen) print name ": there is no top-level permissions line" }
	' "$f") || fail "$name: the permissions scan failed"
	[[ -z $problem ]] || fail "${problem%%$'\n'*}"

	# A checkout can be any key of a list item, not only its first key
	# (`- name: Checkout` then `uses: actions/checkout@...`). Scan by list
	# item: it starts at a `- ` line and ends at the next line that is not
	# blank and not a comment and whose indent is at most the dash indent, or
	# at end of file. A deeper `- ` line belongs to the item.
	problem=$(awk -v name="$name" '
		{
			line = $0
			quiet = (line ~ /^[[:space:]]*(#|$)/)
			rest = line
			sub(/^ */, "", rest)
			indent = length(line) - length(rest)
		}
		in_item && !quiet && indent <= dash {
			finish()
		}
		!in_item && line ~ /^ *-([[:space:]]|$)/ {
			in_item = 1
			start = FNR
			dash = indent
			has_checkout = 0
			has_persist = 0
		}
		in_item && !quiet {
			if (line ~ /(^|[[:space:]-])uses:[[:space:]]*actions\/checkout@/) has_checkout = 1
			if (line ~ /^[[:space:]]*persist-credentials:[[:space:]]*false[[:space:]]*$/) has_persist = 1
		}
		function finish() {
			if (has_checkout && !has_persist) {
				reported = 1
				print name ":" start ": the checkout step does not set persist-credentials: false"
				exit
			}
			in_item = 0
		}
		END { if (in_item && has_checkout && !has_persist && !reported) print name ":" start ": the checkout step does not set persist-credentials: false" }
	' "$f") || fail "$name: the checkout scan failed"
	[[ -z $problem ]] || fail "${problem%%$'\n'*}"

done

# ---- risk-path glob (start) ----
# A port of core's matchGlob (frostyard/core scripts/lib/risk-paths.mjs, core
# ADR-0068, docs/specs/risk-paths.md section A): brace groups expand over the
# whole glob first, left to right, with no nesting, at least 2 alternatives,
# none empty and at most 256 expansions; a malformed group matches nothing.
# Then each expansion matches whole path segments: `**` alone spans 0 or more
# segments, and every other segment matches exactly 1 path segment, with `*`
# any run and `?` 1 code point. `\`, `[`, `]` and every other character are
# literal; `a**b` is 2 stars inside 1 segment. An empty glob or an empty path
# matches nothing.
RISK_GLOB_MAX_EXPANSIONS=256

risk_glob_index() { # risk_glob_index NEEDLE HAYSTACK: sets risk_index to the
	# index of the first NEEDLE in HAYSTACK, or -1
	local needle=$1 hay=$2 pre
	if [[ $hay != *"$needle"* ]]; then
		risk_index=-1
		return
	fi
	pre=${hay%%"$needle"*}
	risk_index=${#pre}
}

risk_glob_repeat() { # risk_glob_repeat ALT...: multiplies risk_globs by 1 part
	local alt prefix
	local -a next=()
	for prefix in "${risk_globs[@]}"; do
		for alt in "$@"; do
			next+=("$prefix$alt")
		done
	done
	if ((${#next[@]} > RISK_GLOB_MAX_EXPANSIONS)); then
		risk_glob_brace_error=1
		risk_globs=()
		return
	fi
	risk_globs=("${next[@]}")
}

risk_glob_expand_braces() { # risk_glob_expand_braces GLOB: sets risk_globs[]
	local glob=$1 literal='' rest body alt i=0 c close next_open
	local -a alts
	risk_globs=("")
	risk_glob_brace_error=0
	while ((i < ${#glob})); do
		c=${glob:i:1}
		if [[ $c == '}' ]]; then
			risk_glob_brace_error=1
			i=$((i + 1))
			continue
		fi
		if [[ $c != '{' ]]; then
			literal+=$c
			i=$((i + 1))
			continue
		fi
		risk_glob_index '}' "${glob:i+1}"
		if ((risk_index < 0)); then
			close=-1
		else
			close=$((i + 1 + risk_index))
		fi
		risk_glob_index '{' "${glob:i+1}"
		if ((risk_index < 0)); then
			next_open=-1
		else
			next_open=$((i + 1 + risk_index))
		fi
		if ((close < 0)); then
			risk_glob_brace_error=1
			break
		fi
		if ((next_open >= 0 && next_open < close)); then
			risk_glob_brace_error=1
			break
		fi
		body=${glob:i+1:close-i-1}
		alts=()
		rest=$body
		while [[ $rest == *,* ]]; do
			alts+=("${rest%%,*}")
			rest=${rest#*,}
		done
		alts+=("$rest")
		if ((${#alts[@]} < 2)); then
			risk_glob_brace_error=1
		fi
		for alt in "${alts[@]}"; do
			[[ -n $alt ]] || risk_glob_brace_error=1
		done
		risk_glob_repeat "$literal"
		risk_glob_repeat "${alts[@]}"
		literal=''
		i=$((close + 1))
	done
	if ((risk_glob_brace_error)); then
		risk_globs=()
		return
	fi
	risk_glob_repeat "$literal"
	if ((risk_glob_brace_error)); then
		risk_globs=()
	fi
}

risk_glob_split() { # risk_glob_split TEXT: sets risk_parts[] with the "/" split,
	# keeping empty fields (core splits a glob and a path the same way)
	local rest=$1
	risk_parts=()
	while [[ $rest == */* ]]; do
		risk_parts+=("${rest%%/*}")
		rest=${rest#*/}
	done
	risk_parts+=("$rest")
}

risk_glob_segment_re() { # risk_glob_segment_re SEGMENT: sets risk_glob_seg_re to
	# the ERE of 1 segment that is not `**`. It sets a variable, not stdout: a
	# command substitution would strip a trailing LF from the pattern, so a glob
	# with a final newline would match 1 character less than core's does.
	local seg=$1 out='' i c
	for ((i = 0; i < ${#seg}; i++)); do
		c=${seg:i:1}
		case $c in
		'*') out+='[^/]*' ;;
		'?') out+='[^/]' ;;
		'.' | '+' | '^' | '$' | '(' | ')' | '|' | '[' | ']' | '{' | '}' | '/' | "\\")
			out+="\\$c"
			;;
		*) out+=$c ;;
		esac
	done
	risk_glob_seg_re=$out
}

risk_glob_walk() { # risk_glob_walk GLOB_INDEX PATH_INDEX: 1 whole-segment match
	local g=$1 p=$2
	if ((g == ${#risk_glob_re[@]})); then
		if ((p == ${#risk_path_parts[@]})); then return 0; fi
		return 1
	fi
	if [[ ${risk_glob_re[g]} == '**' ]]; then
		if risk_glob_walk $((g + 1)) "$p"; then return 0; fi
		if ((p < ${#risk_path_parts[@]})); then
			if risk_glob_walk "$g" $((p + 1)); then return 0; fi
		fi
		return 1
	fi
	if ((p < ${#risk_path_parts[@]})) &&
		[[ ${risk_path_parts[p]} =~ ^${risk_glob_re[g]}$ ]]; then
		if risk_glob_walk $((g + 1)) $((p + 1)); then return 0; fi
	fi
	return 1
}

risk_path_matches() { # risk_path_matches GLOB PATH: 0 when GLOB matches PATH
	local glob=$1 path=$2 expansion seg
	local -a risk_glob_re=()
	[[ -n $glob && -n $path ]] || return 1
	# C.UTF-8 counts 1 code point in ? and [^/], as core's "u" flag does.
	local LC_ALL=C.UTF-8
	risk_glob_expand_braces "$glob"
	if ((risk_glob_brace_error)); then return 1; fi
	for expansion in "${risk_globs[@]}"; do
		risk_glob_split "$expansion"
		risk_glob_re=()
		for seg in "${risk_parts[@]}"; do
			if [[ $seg == '**' ]]; then
				risk_glob_re+=('**')
			else
				risk_glob_segment_re "$seg"
				risk_glob_re+=("$risk_glob_seg_re")
			fi
		done
		risk_glob_split "$path"
		risk_path_parts=("${risk_parts[@]}")
		if risk_glob_walk 0 0; then return 0; fi
	done
	return 1
}
# ---- risk-path glob (end) ----

# B6: the risk paths in schema version 2 (core ADR-0068, ADR-0078;
# docs/specs/risk-paths.md). The list has a default level, a level on every
# entry, no unknown key at either level, and rule C: each glob that matches the
# list or the caller is L1 or L2, matched by core's matchGlob.
risk=$ROOT/.github/risk-paths.json
[[ -f $risk ]] || fail ".github/risk-paths.json is missing"
jq -e . "$risk" >/dev/null 2>&1 || fail ".github/risk-paths.json is not valid JSON"
[[ $(jq -r '.schema_version | tostring' "$risk") == 2 &&
	$(jq -r '.schema_version | type' "$risk") == number ]] ||
	fail ".github/risk-paths.json must set schema_version 2"
unknown=$(jq -r '[keys[] | select(. != "schema_version" and
	. != "default_level" and . != "paths")] | join(", ")' "$risk")
[[ -z $unknown ]] || fail ".github/risk-paths.json has unknown key(s): $unknown"
# A command substitution would strip a trailing LF from the value, so the type
# and the exact value are checked inside jq: "L3\n" is not L3.
jq -e '.default_level | type == "string" and
	(. == "L1" or . == "L2" or . == "L3" or . == "L4")' "$risk" >/dev/null ||
	fail ".github/risk-paths.json must set default_level to L1, L2, L3 or L4"
[[ $(jq -r '.paths | type' "$risk") == array ]] ||
	fail ".github/risk-paths.json has no valid paths list"
risk_count=$(jq -r '.paths | length' "$risk")
[[ $risk_count =~ ^[0-9]+$ ]] || fail ".github/risk-paths.json has no valid paths list"
((risk_count > 0)) || fail ".github/risk-paths.json has no paths entries"
unknown=$(jq -r '.paths[] | select(type == "object")
	| (keys - ["glob", "level", "why"]) as $extra
	| select($extra != [])
	| "\(.glob // "an entry"): unknown key(s): \($extra | join(", "))"' "$risk")
[[ -z $unknown ]] || fail ".github/risk-paths.json: $unknown"
# Each entry level is 1 of the 4 values exactly, read inside jq so a trailing LF
# cannot pass. The count below also catches an entry that is not an object.
unknown=$(jq -r '.paths[] | select(type == "object")
	| (.level // "") as $l
	| select(($l | type) != "string" or
		($l != "L1" and $l != "L2" and $l != "L3" and $l != "L4"))
	| "\(.glob // "an entry"): level must be L1, L2, L3 or L4, not \($l | tojson)"' "$risk")
[[ -z $unknown ]] || fail ".github/risk-paths.json: $unknown"
risk_checked=0
while IFS=$'\t' read -r glob level; do
	risk_checked=$((risk_checked + 1))
done < <(jq -r '.paths[] | select(type == "object") | [(.glob // ""), (.level // "")] | @tsv' "$risk")
((risk_checked == risk_count)) ||
	fail ".github/risk-paths.json: checked $risk_checked of $risk_count entries"
# Rule C: each glob that matches the list or the caller is L1 or L2, and each of
# the 2 required paths has at least 1 glob that matches it. The count is kept for
# each path, so 1 covered path cannot hide the other.
required_paths=(.github/risk-paths.json .github/workflows/risk-paths.yml)
rule_c_covered=()
for rule_c_i in "${!required_paths[@]}"; do
	rule_c_covered[rule_c_i]=0
done
while IFS=$'\t' read -r glob level; do
	for rule_c_i in "${!required_paths[@]}"; do
		needed=${required_paths[rule_c_i]}
		if risk_path_matches "$glob" "$needed"; then
			rule_c_covered[rule_c_i]=$((rule_c_covered[rule_c_i] + 1))
			[[ $level =~ ^L[12]$ ]] ||
				fail "rule C: the glob $glob matches $needed; its level must be L1 or L2, not ${level:-none}"
		fi
	done
done < <(jq -r '.paths[] | select(type == "object") | [(.glob // ""), (.level // "")] | @tsv' "$risk")
rule_c_uncovered=''
for rule_c_i in "${!required_paths[@]}"; do
	if ((rule_c_covered[rule_c_i] == 0)); then
		rule_c_uncovered+="${rule_c_uncovered:+, }${required_paths[rule_c_i]}"
	fi
done
[[ -z $rule_c_uncovered ]] ||
	fail "rule C: no glob in the list matches $rule_c_uncovered"

for glob in '.github/workflows/**' 'scripts/**' 'config/**' 'keys/**' 'withdrawals/**'; do
	[[ $(jq -r --arg g "$glob" '[.paths[].glob] | index($g) != null' "$risk") == true ]] ||
		fail ".github/risk-paths.json does not list the glob $glob"
done

# B6 caller: the caller workflow has 1 allowed shape (core
# docs/specs/pr-triage.md section E). The file may start with comment lines and
# blank lines; the rest must equal this repository's body line by line, after
# its trailing spaces go (a trailing space does not change how GitHub reads a
# line). Only the 40-character SHA in the `uses:` line and the comment after it
# may vary. This is stricter than YAML on purpose: a commented-out line, another
# job name or an extra trigger is a difference, and the file has 1 shape.
caller=$ROOT/.github/workflows/risk-paths.yml
[[ -f $caller ]] || fail ".github/workflows/risk-paths.yml is missing"
# YAML reads a bare CR, NEL, LS and PS as line breaks too, so a key can hide in
# the same LF line: a pin comment with a CR and a following `if: false` is 2 YAML
# lines but 1 line to a check that splits on LF. The caller uses LF and nothing
# else, so any of those characters fails before the text check reads a line.
# $(<file) drops only trailing LF bytes, which YAML ignores at the end of a
# file, so it cannot hide a line break; the guard below rejects every other
# line-break character in the bytes that remain.
caller_text=$(<"$caller")
case $caller_text in
*$'\r'*)
	fail ".github/workflows/risk-paths.yml holds a CR (U+000D): YAML reads it as a line break, so the file must use LF line ends only"
	;;
*$'\xc2\x85'*)
	fail ".github/workflows/risk-paths.yml holds a NEL (U+0085): YAML reads it as a line break, so the file must use LF line ends only"
	;;
*$'\xe2\x80\xa8'*)
	fail ".github/workflows/risk-paths.yml holds a LS (U+2028): YAML reads it as a line break, so the file must use LF line ends only"
	;;
*$'\xe2\x80\xa9'*)
	fail ".github/workflows/risk-paths.yml holds a PS (U+2029): YAML reads it as a line break, so the file must use LF line ends only"
	;;
esac
caller_body=(
	'name: PR triage'
	''
	'on:'
	'  pull_request_target:'
	'    types: [opened, synchronize, reopened, edited, labeled]'
	''
	'permissions: {}'
)
# The directives that only this repository requires, between permissions and jobs.
caller_body+=(
		''
	'defaults:'
	'  run:'
	'    shell: bash'
)
caller_body+=(
	''
	'jobs:'
	'  pr-triage:'
	'    permissions:'
	'      contents: read'
	'      pull-requests: write'
	'    uses: frostyard/core/.github/workflows/pr-triage.yml@<sha>'
)

mapfile -t caller_lines <"$caller"
caller_i=0
while ((caller_i < ${#caller_lines[@]})); do
	caller_line=${caller_lines[caller_i]}
	while [[ $caller_line == *[[:space:]] ]]; do caller_line=${caller_line%?}; done
	if [[ -n $caller_line ]]; then
		caller_lead=${caller_line%%[![:space:]]*}
		[[ ${caller_line#"$caller_lead"} == '#'* ]] || break
	fi
	caller_i=$((caller_i + 1))
done
caller_uses_re='^    uses: frostyard/core/\.github/workflows/pr-triage\.yml@[0-9a-f]{40}( #.*)?$'
caller_j=0
while ((caller_j < ${#caller_body[@]})); do
	caller_want=${caller_body[caller_j]}
	caller_at=$((caller_i + 1))
	if ((caller_i >= ${#caller_lines[@]})); then
		fail ".github/workflows/risk-paths.yml:$caller_at: the body ends here; expected '$caller_want'"
	fi
	caller_line=${caller_lines[caller_i]}
	while [[ $caller_line == *[[:space:]] ]]; do caller_line=${caller_line%?}; done
	if [[ $caller_want == *'<sha>'* ]]; then
		[[ $caller_line =~ $caller_uses_re ]] ||
			fail ".github/workflows/risk-paths.yml:$caller_at: expected '    uses: frostyard/core/.github/workflows/pr-triage.yml@<40 hex>' with only an optional trailing comment, found '${caller_line:-<blank>}'"
	elif [[ $caller_line != "$caller_want" ]]; then
		fail ".github/workflows/risk-paths.yml:$caller_at: expected '${caller_want:-<blank>}', found '${caller_line:-<blank>}'"
	fi
	caller_i=$((caller_i + 1))
	caller_j=$((caller_j + 1))
done
if ((caller_i < ${#caller_lines[@]})); then
	caller_line=${caller_lines[caller_i]}
	while [[ $caller_line == *[[:space:]] ]]; do caller_line=${caller_line%?}; done
	fail ".github/workflows/risk-paths.yml:$((caller_i + 1)): expected the end of the body, found '${caller_line:-<blank>}'"
fi

# B7: the pull request template declares a risk tier (core ADR-0019).
grep -qE '^#+ .*Risk tier' "$ROOT/.github/pull_request_template.md" ||
	fail ".github/pull_request_template.md has no heading that names the risk tier"

# B12: CI runs the make gate on pull requests (core ADR-0071).
ci=$ROOT/.github/workflows/ci.yml
[[ -f $ci ]] || fail ".github/workflows/ci.yml is missing"
awk '/^on:/ { on = 1; next } on && /^[^[:space:]]/ { on = 0 }
	on && /^[[:space:]]+pull_request:/ { found = 1 } END { exit !found }' "$ci" ||
	fail ".github/workflows/ci.yml does not run on pull_request"
grep -qE '^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]+make ci[[:space:]]*$' "$ci" ||
	fail ".github/workflows/ci.yml has no run: make ci step"

# B13: Dependabot updates the pinned actions (core ADR-0071).
dependabot=$ROOT/.github/dependabot.yml
[[ -f $dependabot ]] || fail ".github/dependabot.yml is missing"
grep -qE '^[[:space:]]*-[[:space:]]*package-ecosystem:[[:space:]]*"?github-actions"?[[:space:]]*$' "$dependabot" ||
	fail ".github/dependabot.yml has no github-actions entry"

# B14: the security policy names the repository's Security tab (core
# ADR-0040).
security=
for candidate in SECURITY.md .github/SECURITY.md; do
	if [[ -f $ROOT/$candidate ]]; then
		security=$ROOT/$candidate
		break
	fi
done
[[ -n $security ]] || fail "SECURITY.md is missing"
grep -qF 'https://github.com/frostyard/apt-publisher/security' "$security" ||
	fail "SECURITY.md does not link https://github.com/frostyard/apt-publisher/security"

# B15: no CODEOWNERS.
for path in CODEOWNERS .github/CODEOWNERS docs/CODEOWNERS; do
	if [[ -e $ROOT/$path ]]; then
		fail "$path must not exist (the baseline has no CODEOWNERS)"
	fi
done

# B16: no leftover agent-framework trees.
for path in docs/superpowers .planning .cursor/rules .gaai yeti cairn; do
	if [[ -e $ROOT/$path ]]; then
		fail "$path must not exist (leftover agent-framework tree)"
	fi
done
if [[ -d $ROOT/.claude ]]; then
	while IFS= read -r entry; do
		case $(basename "$entry") in
		settings.json | skills | session-summary.md) ;;
		*) fail ".claude/ holds $(basename "$entry"); it may hold only settings.json, skills and session-summary.md" ;;
		esac
	done < <(find "$ROOT/.claude" -mindepth 1 -maxdepth 1)
fi

# B17: the README follows core's README spec: 1 kind marker, at most 1000
# words (core ADR-0072).
marker=$(grep -cxF -- '<!-- readme-kind: packaging -->' "$ROOT/README.md" || true)
[[ $marker == 1 ]] ||
	fail "README.md must have exactly 1 line <!-- readme-kind: packaging -->; found $marker"
words=$(wc -w <"$ROOT/README.md")
words=${words//[[:space:]]/}
((words <= 1000)) || fail "README.md has $words words; the limit is 1000"

echo "ok - baseline: ${#workflow_files[@]} workflows, $correction_lines corrections lines, $risk_count risk-path entries, ${#caller_body[@]} caller lines, README $words words"
