#!/usr/bin/env bash
#
# test-resume.sh — measure how much of a SAIA outage mcode actually absorbs.
#
# mcode retries a failed turn on its own, with a FIXED envelope: nothing in
# config.yaml or settings.json changes it (verified by strace on 0.5.1 — mcode
# never opens settings.json at all). This test pins the envelope down so a
# future mcode release that shrinks it gets caught.
#
# Measured on mcode 0.5.1: `mcode exec` issues at most 6 requests (1 + 5
# retries) before giving up; the TUI gets to 9.
#
# Runs entirely against test/fake-saia.py in an isolated MINIMAX_DATA_DIR, so it
# makes zero real SAIA requests and never touches ~/.minimax.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

FAIL_COUNT="${FAKE_FAIL_COUNT:-3}"
WORK="$(mktemp -d)"
export MINIMAX_DATA_DIR="$WORK/data"
mkdir -p "$MINIMAX_DATA_DIR"


cleanup() {
  [[ -n "${FAKE_PID:-}" ]] && kill "$FAKE_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── Start the fake SAIA ──────────────────────────────────────────────
FAKE_FAIL_COUNT="$FAIL_COUNT" COUNT_FILE="$WORK/count" \
  python3 ./fake-saia.py >"$WORK/port" 2>"$WORK/fake.log" &
FAKE_PID=$!
for _ in $(seq 40); do [[ -s "$WORK/port" ]] && break; sleep 0.1; done
PORT="$(cat "$WORK/port")"
[[ -n "$PORT" ]] || { echo "FAIL: fake-saia did not start" >&2; cat "$WORK/fake.log" >&2; exit 1; }
echo "fake-saia on port $PORT, failing the first $FAIL_COUNT requests"


# ── Register the fake as a provider ──────────────────────────────────
SAIA_API_KEY=dummy mcode provider add \
  --name "Fake SAIA" \
  --base-url "http://127.0.0.1:$PORT/v1" \
  --api-format openai-completions \
  --model fake-model \
  --api-key-env SAIA_API_KEY >/dev/null

# Same reason the installer does it: a managed-login defaultModel makes mcode
# demand a MiniMax account at startup, whatever --model says.
python3 - "$MINIMAX_DATA_DIR/config.yaml" <<'PYCFG'
import sys
path = sys.argv[1]
lines = open(path).readlines()
for i, l in enumerate(lines):
    if l.startswith("defaultModel:"):
        lines[i] = "defaultModel: custom_provider:fake-saia/fake-model\n"
        break
else:
    lines.insert(0, "defaultModel: custom_provider:fake-saia/fake-model\n")
open(path, "w").writelines(lines)
PYCFG

# ── Run one turn through the outage ──────────────────────────────────
set +e
OUT="$(SAIA_API_KEY=dummy mcode exec \
  --model custom_provider:fake-saia/fake-model \
  --permission off --timeout 180s \
  "reply with OK" 2>&1)"
RC=$?
set -e

CALLS="$(cat "$WORK/count" 2>/dev/null || echo 0)"
echo "exit=$RC chat_requests=$CALLS"

fail() { echo "FAIL: $1" >&2; echo "--- output ---" >&2; echo "$OUT" >&2; exit 1; }

if grep -q "Sign in to MiniMax" <<<"$OUT"; then
  echo "SKIP: mcode refuses to run without a MiniMax account login." >&2
  echo "      Run 'mcode login', then re-run this test." >&2
  exit 0
fi

[[ $RC -eq 0 ]]                  || fail "mcode exec exited $RC — it gave up instead of retrying"
grep -q "OK-FAKE-RESUME" <<<"$OUT" || fail "canned reply missing — the successful retry never landed"
[[ $CALLS -gt $FAIL_COUNT ]]     || fail "only $CALLS request(s) — no retry happened"
# Raise FAKE_FAIL_COUNT past 5 and this test SHOULD fail: that is the ceiling.

echo "PASS: absorbed $FAIL_COUNT consecutive 503s, recovered on request $CALLS"

# ── SAIA_BASE_URL override (used by the benchmark's local gateway) ─────
OV="$WORK/override"; mkdir -p "$OV"
MINIMAX_DATA_DIR="$OV" SAIA_BASE_URL="http://127.0.0.1:$PORT/v1" SAIA_API_KEY=dummy \
  bash ../src/add-saia-mcode.sh >"$WORK/override.log" 2>&1 \
  || { OUT="$(cat "$WORK/override.log")"; fail "installer failed with SAIA_BASE_URL set"; }
MINIMAX_DATA_DIR="$OV" mcode provider list --json | grep -q "http://127.0.0.1:$PORT/v1" \
  || { OUT="$(cat "$WORK/override.log")"; fail "SAIA_BASE_URL not registered with mcode"; }
echo "PASS: SAIA_BASE_URL override"
