#!/usr/bin/env bash
# The action's own tests, against a STUB API — so they run offline, in seconds, and assert the
# thing that actually matters: which cases fail the build.
#
# An action is a piece of software whose only bug report is "my CI went green when it shouldn't
# have". The exit codes below are the contract; the annotations are how anyone finds out why.
#
# Run: bash actions/validate-otel-config/test_action.sh   (exit 0 = pass). Wired into CI.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; kill %1 2>/dev/null' EXIT
FAILS=0

check() {  # check <name> <expected-exit> <actual-exit>
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 — expected exit $2, got $3"; FAILS=$((FAILS+1)); fi
}
contains() {  # contains <name> <needle> <file>
  if grep -qF "$2" "$3"; then echo "  PASS  $1"; else echo "  FAIL  $1 — no '$2' in $(cat "$3")"; FAILS=$((FAILS+1)); fi
}

# A stub API whose answer is chosen by the config's CONTENT, so one server covers every case.
cat > "$TMP/stub.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

VALID = {"ok": True, "validated_against": {"version": "0.157.0", "image": "otel/x:0.157.0"},
         "stages": [{"name": "schema", "ok": True, "detail": "ok"}], "warnings": []}
INVALID = {"ok": False, "validated_against": {"version": "0.157.0", "image": "otel/x:0.157.0"},
           "stages": [{"name": "schema", "ok": False,
                       "detail": "Error: 'receivers' unknown type: \"signalfx\"\nmore detail"}],
           "warnings": [{"deprecated": "http.method", "replacement": "http.request.method"}]}
UPGRADE = {"from": "0.155.0", "to": "0.157.0", "ok": False,
           "findings": [{"severity": "blocking", "kind": "component-removed", "fixed": False,
                         "message": "receiver 'signalfx' does not exist in 0.157.0"}],
           "applied": [], "manual": [{"kind": "component-removed"}],
           "migrated": "receivers: {}\n"}

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", "0"))).decode()
        if "upgrade" in self.path:
            return self.send(200, UPGRADE)
        if "BOOM" in body:
            return self.send(503, {"detail": {"error": "validation unavailable", "hint": "no oracle"}})
        if "signalfx" in body:
            return self.send(200, INVALID)
        return self.send(200, VALID)

    def send(self, code, payload):
        data = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

PORT=8791
python3 "$TMP/stub.py" "$PORT" &
for _ in $(seq 1 40); do curl -sS -o /dev/null "http://127.0.0.1:$PORT" -X POST -d x 2>/dev/null && break; sleep 0.25; done

export IN_API="http://127.0.0.1:$PORT" IN_DISTRO=otelcol-contrib IN_VERSION=0.157.0
export IN_UPGRADE_TO="" IN_FAIL_UPGRADE=false IN_FAIL_UNAVAILABLE=true IN_GATES=""
export RUNNER_TEMP="$TMP" GITHUB_OUTPUT="$TMP/out" GITHUB_STEP_SUMMARY="$TMP/summary"

printf 'receivers:\n  otlp: {}\n' > "$TMP/good.yaml"
printf 'receivers:\n  signalfx: {}\n' > "$TMP/bad.yaml"
printf 'receivers:\n  BOOM: {}\n' > "$TMP/unavailable.yaml"

echo
echo "validate-otel-config action"
echo

: > "$GITHUB_OUTPUT"
IN_CONFIG="$TMP/good.yaml" bash "$HERE/validate.sh" > "$TMP/log1" 2>&1
check "a valid config exits 0" 0 $?
contains "...and sets valid=true" "valid=true" "$GITHUB_OUTPUT"
contains "...and annotates it as valid" "::notice file=$TMP/good.yaml::valid" "$TMP/log1"

: > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
IN_CONFIG="$TMP/bad.yaml" bash "$HERE/validate.sh" > "$TMP/log2" 2>&1
check "an invalid config FAILS the build" 1 $?
contains "...and sets valid=false" "valid=false" "$GITHUB_OUTPUT"
# The annotation must carry the COLLECTOR'S message, not our paraphrase of it — that is the whole
# reason to call this service rather than a linter.
contains "...with the collector's own message on the file" "unknown type" "$TMP/log2"
contains "...and the full detail in the job summary" "more detail" "$GITHUB_STEP_SUMMARY"
# Deprecated attribute names are advisory. A build that fails on them would train people to skip
# the step entirely.
contains "...semconv findings are warnings, not failures" "::warning" "$TMP/log2"

: > "$GITHUB_OUTPUT"
IN_CONFIG="$TMP/unavailable.yaml" bash "$HERE/validate.sh" > "$TMP/log3" 2>&1
check "no verdict (503) FAILS by default" 1 $?
contains "...and says why it refused to pass" "no verdict was produced" "$TMP/log3"

: > "$GITHUB_OUTPUT"
IN_CONFIG="$TMP/unavailable.yaml" IN_FAIL_UNAVAILABLE=false bash "$HERE/validate.sh" > "$TMP/log4" 2>&1
check "...unless fail-on-unavailable is false" 0 $?

: > "$GITHUB_OUTPUT"
IN_CONFIG="$TMP/nope-*.yaml" bash "$HERE/validate.sh" > "$TMP/log5" 2>&1
check "a pattern matching nothing FAILS (not a silent pass)" 1 $?
contains "...and names the pattern" "no file matches" "$TMP/log5"

: > "$GITHUB_OUTPUT"
IN_CONFIG="$(printf '%s\n%s' "$TMP/good.yaml" "$TMP/bad.yaml")" bash "$HERE/validate.sh" > "$TMP/log6" 2>&1
check "one bad file among several fails the whole run" 1 $?

: > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
IN_CONFIG="$TMP/good.yaml" IN_UPGRADE_TO=0.157.0 bash "$HERE/validate.sh" > "$TMP/log7" 2>&1
check "an upgrade report is advisory by default" 0 $?
contains "...and reports what breaks" "does not exist in 0.157.0" "$GITHUB_STEP_SUMMARY"
contains "...and includes the migrated config" "Migrated config" "$GITHUB_STEP_SUMMARY"

: > "$GITHUB_OUTPUT"
IN_CONFIG="$TMP/good.yaml" IN_UPGRADE_TO=0.157.0 IN_FAIL_UPGRADE=true bash "$HERE/validate.sh" > "$TMP/log8" 2>&1
check "...and gates the build when asked to" 1 $?

# --- the published copy must be complete ---------------------------------------------------------
# sync.sh publishes an explicit file list. A runtime file missing from that list produces an action
# that cannot run — and the breakage lands in a CUSTOMER's CI, not ours, because our own tests run
# against this directory where the file exists. So the list is checked HERE, on every PR.
if [ -f "$HERE/sync.sh" ]; then
  listed="$(sed -n 's/^SYNC_FILES=(\(.*\))$/\1/p' "$HERE/sync.sh")"
  for ref in $(grep -oE '\$GITHUB_ACTION_PATH/[A-Za-z0-9_.-]+' "$HERE/action.yml" | sed 's|.*/||' | sort -u); do
    case " $listed " in
      *" $ref "*) echo "  PASS  sync.sh publishes $ref" ;;
      *) echo "  FAIL  action.yml runs $ref but sync.sh would not publish it"; FAILS=$((FAILS+1)) ;;
    esac
  done
fi

echo
if [ "$FAILS" != 0 ]; then echo "FAILED — $FAILS check(s)"; exit 1; fi
echo "all checks passed"
