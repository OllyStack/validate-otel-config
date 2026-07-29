#!/usr/bin/env bash
# The body of the validate-otel-config action. Kept out of action.yml so it can be run and tested
# directly — an action whose logic lives inside YAML can only be tested by pushing to GitHub, which
# is how action bugs reach users.
#
#   IN_CONFIG IN_VERSION IN_DISTRO IN_UPGRADE_TO IN_FAIL_UPGRADE IN_FAIL_UNAVAILABLE IN_GATES IN_API
#
# Writes GitHub annotations (::error file=…) so the collector's own message lands on the offending
# file in the PR diff, and appends a human summary to $GITHUB_STEP_SUMMARY.
set -uo pipefail

API="${IN_API:-https://www.ollystack.com}"
DISTRO="${IN_DISTRO:-otelcol-contrib}"
VERSION="${IN_VERSION:-}"
REPORT="${RUNNER_TEMP:-/tmp}/otel-validate-report.json"
BODY="${RUNNER_TEMP:-/tmp}/otel-validate-body.json"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
: > "$REPORT.tmp"

command -v jq >/dev/null 2>&1 || { echo "::error::jq is required by validate-otel-config"; exit 1; }

# Expand the input into a file list: newline- or space-separated, globs allowed. `ls` rather than a
# bare glob so a pattern that matches nothing is reported instead of being passed through literally.
FILES=()
while read -r pattern; do
  [ -z "$pattern" ] && continue
  # shellcheck disable=SC2206  # word splitting is the point: a pattern may expand to many files
  matches=( $(ls -1 $pattern 2>/dev/null) )
  if [ ${#matches[@]} -eq 0 ]; then
    echo "::error::no file matches '$pattern'"
    echo "valid=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 1
  fi
  FILES+=("${matches[@]}")
done < <(printf '%s\n' $IN_CONFIG)

# api_call <url> <file> <body-out-path> -> prints the HTTP status; writes the body to <body-out-path>.
#
# The status is the RETURN VALUE rather than a global, because every caller uses `$(api_call …)` and
# a command substitution runs in a subshell — a global set in there is invisible to the caller. That
# is not a style preference: written the other way, every status read as unset, and under `set -u`
# the script died mid-file after reporting nothing.
api_call() {
  local url="$1" file="$2" dest="$3" out status
  # Retry once on 429: a busy minute should not fail someone's build.
  for attempt in 1 2; do
    out="$(curl -sS --max-time 300 -w $'\n%{http_code}' -X POST "$url" \
            -H 'content-type: application/x-yaml' --data-binary @"$file" 2>&1)"
    status="${out##*$'\n'}"
    out="${out%$'\n'*}"
    if [ "$status" = "429" ] && [ "$attempt" = 1 ]; then
      echo "::notice::rate limited by $API — waiting 60s" >&2
      sleep 60
      continue
    fi
    break
  done
  printf '%s' "$out" > "$dest"
  printf '%s' "$status"
}

FAILED=0
UNAVAILABLE=0
{
  echo "## OpenTelemetry Collector config validation"
  echo
  echo "Validated against **${DISTRO} ${VERSION:-(default)}** using the real collector binary."
  echo
} >> "$SUMMARY"

for file in "${FILES[@]}"; do
  q="distro=$DISTRO"
  [ -n "$VERSION" ] && q="$q&version=$VERSION"
  [ -n "${IN_GATES:-}" ] && q="$q&feature_gates=$IN_GATES"
  STATUS="$(api_call "$API/api/v1/validate?$q" "$file" "$BODY")"
  body="$(cat "$BODY")"

  if [ "$STATUS" = "200" ]; then
    ok="$(printf '%s' "$body" | jq -r '.ok')"
    ver="$(printf '%s' "$body" | jq -r '.validated_against.version // "?"')"
    img="$(printf '%s' "$body" | jq -r '.validated_against.image // "?"')"
    if [ "$ok" = "true" ]; then
      echo "::notice file=$file::valid for $DISTRO $ver"
      echo "- ✅ \`$file\` — valid for \`$img\`" >> "$SUMMARY"
    else
      FAILED=1
      detail="$(printf '%s' "$body" | jq -r '[.stages[] | select(.name=="schema")][0].detail // "invalid"')"
      # Annotations are single-line; the collector's message is many. Put the first meaningful line
      # on the file and the whole thing in the summary, so neither is lost.
      first="$(printf '%s' "$detail" | grep -v '^\s*$' | head -1)"
      echo "::error file=$file::invalid for $DISTRO $ver — $first"
      { echo "- ❌ \`$file\` — **invalid** for \`$img\`"; echo; echo '```'; printf '%s\n' "$detail"; echo '```'; } >> "$SUMMARY"
    fi
    # Guardrails and deprecated semconv names are advisory: reported, never a build failure.
    printf '%s' "$body" | jq -r '.warnings[]? | "::warning file='"$file"'::deprecated attribute \(.deprecated) — use \(.replacement)"'
  elif [ "$STATUS" = "503" ]; then
    UNAVAILABLE=1
    hint="$(printf '%s' "$body" | jq -r '.detail.hint // .detail.error // "no verdict"')"
    echo "::warning file=$file::could not validate — $hint"
    echo "- ⚠️ \`$file\` — **no verdict**: $hint" >> "$SUMMARY"
  else
    FAILED=1
    err="$(printf '%s' "$body" | jq -r '.detail.error // .error // .' 2>/dev/null | head -1)"
    echo "::error file=$file::validation request failed (HTTP $STATUS) — $err"
    echo "- ❌ \`$file\` — request failed (HTTP $STATUS): $err" >> "$SUMMARY"
  fi
  printf '%s\n' "{\"file\":\"$file\",\"status\":$STATUS,\"response\":$([ -n "$body" ] && printf '%s' "$body" | jq -c . 2>/dev/null || echo null)}" >> "$REPORT.tmp"

  # --- optional: what an upgrade would do ------------------------------------------------------
  if [ -n "${IN_UPGRADE_TO:-}" ] && [ -n "$VERSION" ]; then
    STATUS="$(api_call "$API/api/v1/upgrade?from=$VERSION&to=$IN_UPGRADE_TO&distro=$DISTRO" "$file" "$BODY")"
    up="$(cat "$BODY")"
    if [ "$STATUS" = "200" ]; then
      upok="$(printf '%s' "$up" | jq -r '.ok')"
      { echo; echo "### Upgrade $VERSION → $IN_UPGRADE_TO — \`$file\`"; echo; } >> "$SUMMARY"
      printf '%s' "$up" | jq -r '.findings[] | "- \(if .severity=="blocking" then (if .fixed then "🔧" else "❌" end) elif .severity=="warning" then "⚠️" else "ℹ️" end) \(.message)"' >> "$SUMMARY"
      if [ "$upok" != "true" ]; then
        echo "::warning file=$file::upgrading to $IN_UPGRADE_TO needs changes this tool cannot make for you"
        [ "${IN_FAIL_UPGRADE:-false}" = "true" ] && FAILED=1
      fi
      mig="$(printf '%s' "$up" | jq -r '.migrated // empty')"
      if [ -n "$mig" ]; then
        { echo; echo "<details><summary>Migrated config (automatic fixes applied)</summary>"; echo;
          echo '```yaml'; printf '%s\n' "$mig"; echo '```'; echo; echo "</details>"; } >> "$SUMMARY"
      fi
    fi
  fi
done

jq -s '.' "$REPORT.tmp" > "$REPORT" 2>/dev/null || cp "$REPORT.tmp" "$REPORT"
rm -f "$REPORT.tmp"

{
  echo "report=$REPORT"
  echo "valid=$([ "$FAILED" = 0 ] && echo true || echo false)"
} >> "${GITHUB_OUTPUT:-/dev/null}"

if [ "$FAILED" != 0 ]; then
  exit 1
fi
if [ "$UNAVAILABLE" != 0 ] && [ "${IN_FAIL_UNAVAILABLE:-true}" = "true" ]; then
  # No verdict is not a pass. Going green here would be a tick that means nothing.
  echo "::error::no verdict was produced for at least one config — failing rather than reporting a pass it did not earn (set fail-on-unavailable: false to change this)"
  exit 1
fi
exit 0
