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

# B2: the corrections inbox: one JSON object per line, 5 fields (ADR-0018).
corrections=$ROOT/.memory/corrections.jsonl
[[ -f $corrections ]] || fail ".memory/corrections.jsonl is missing"
correction_lines=0
while IFS= read -r line; do
	[[ -n ${line//[[:space:]]/} ]] || continue
	keys=$(printf '%s' "$line" |
		jq -r 'if type == "object" then (keys | sort | join(",")) else "not-an-object" end' 2>/dev/null) ||
		fail ".memory/corrections.jsonl is not valid JSON: $line"
	[[ $keys == correction,date,evidence,promoted_to,scope ]] ||
		fail ".memory/corrections.jsonl needs exactly the fields correction, date, evidence, promoted_to, scope; got $keys"
	correction_lines=$((correction_lines + 1))
done <"$corrections"

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

	problem=$(awk -v name="$name" '
		/-[[:space:]]+uses:[[:space:]]+actions\/checkout@/ { want = 1; start = FNR; found = 0 }
		want && FNR != start && /^[[:space:]]*-[[:space:]]/ {
			if (!found) { print name ":" start ": the checkout step does not set persist-credentials: false"; want = 0; exit }
			want = 0
		}
		want && /^[[:space:]]+persist-credentials:[[:space:]]+false[[:space:]]*$/ { found = 1 }
		END {
			if (want && !found) print name ":" start ": the checkout step does not set persist-credentials: false"
		}
	' "$f") || fail "$name: the checkout scan failed"
	[[ -z $problem ]] || fail "${problem%%$'\n'*}"

done

# B6: the risk paths and their caller (core ADR-0068).
risk=$ROOT/.github/risk-paths.json
[[ -f $risk ]] || fail ".github/risk-paths.json is missing"
jq -e . "$risk" >/dev/null 2>&1 || fail ".github/risk-paths.json is not valid JSON"
[[ $(jq -r '.schema_version' "$risk") == 1 ]] ||
	fail ".github/risk-paths.json must set schema_version 1"
for glob in '.github/workflows/**' 'scripts/**' 'config/**' 'keys/**' 'withdrawals/**'; do
	[[ $(jq -r --arg g "$glob" '[.paths[].glob] | index($g) != null' "$risk") == true ]] ||
		fail ".github/risk-paths.json does not list the glob $glob"
done
grep -Eqs \
	'uses:[[:space:]]+frostyard/core/\.github/workflows/risk-paths\.yml@[0-9a-f]{40}([[:space:]]|$)' \
	"$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml ||
	fail "no workflow calls frostyard/core's risk-paths.yml at a 40-character commit SHA"

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

echo "ok - baseline: ${#workflow_files[@]} workflows, $correction_lines corrections lines, README $words words"
