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
# Then checks the automatic key swap: with two keys, the first one revoked, the
# installer registers the local saia-keyring proxy as the base URL and a real
# `mcode exec` turn succeeds on its first request — the proxy absorbs the 401 and
# fails over to the second key. The proxy runs with SAIA_KEYRING_SERVICE=none in
# a throwaway HOME, so no systemd unit or real shell rc is touched.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

FAIL_COUNT="${FAKE_FAIL_COUNT:-3}"
WORK="$(mktemp -d)"
export MINIMAX_DATA_DIR="$WORK/data"
export SAIA_KEYRING_SERVICE=none
mkdir -p "$MINIMAX_DATA_DIR"


cleanup() {
  [[ -n "${FAKE_PID:-}" ]] && kill "$FAKE_PID" 2>/dev/null || true
  [[ -n "${FAKE2_PID:-}" ]] && kill "$FAKE2_PID" 2>/dev/null || true
  if [[ -n "${KR_PORT:-}" ]]; then
    curl -s "http://127.0.0.1:$KR_PORT/_keyring/health" \
      | python3 -c 'import json,os,sys; os.kill(json.load(sys.stdin)["pid"], 15)' 2>/dev/null || true
  fi
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
OV="$WORK/override"; mkdir -p "$OV/home"
HOME="$OV/home" MINIMAX_DATA_DIR="$OV" SAIA_BASE_URL="http://127.0.0.1:$PORT/v1" SAIA_API_KEY=dummy \
  bash ../src/add-saia-mcode.sh >"$WORK/override.log" 2>&1 \
  || { OUT="$(cat "$WORK/override.log")"; fail "installer failed with SAIA_BASE_URL set"; }
MINIMAX_DATA_DIR="$OV" mcode provider list --json | grep -q "http://127.0.0.1:$PORT/v1" \
  || { OUT="$(cat "$WORK/override.log")"; fail "SAIA_BASE_URL not registered with mcode"; }
echo "PASS: SAIA_BASE_URL override"

# ── Automatic key swap: two keys, the first one revoked ───────────────
# A second fake that never 503s and answers 401 to the revoked key: the turn can
# only succeed on mcode's first request if the proxy fails over.
KR="$WORK/keyring"; mkdir -p "$KR/home" "$KR/data"
FAKE_FAIL_COUNT=0 FAKE_DEAD_KEYS=dead-key SEEN_FILE="$KR/seen" COUNT_FILE="$KR/count" \
  REPLY=OK-FAKE-KEYRING python3 ./fake-saia.py >"$KR/port" 2>"$KR/fake.log" &
FAKE2_PID=$!
for _ in $(seq 40); do [[ -s "$KR/port" ]] && break; sleep 0.1; done
PORT2="$(cat "$KR/port")"
[[ -n "$PORT2" ]] || { echo "FAIL: second fake-saia did not start" >&2; exit 1; }
KR_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
HOME="$KR/home" MINIMAX_DATA_DIR="$KR/data" SAIA_KEYRING_PORT="$KR_PORT" \
  SAIA_BASE_URL="http://127.0.0.1:$PORT2/v1" SAIA_API_KEY=dead-key \
  bash ../src/add-saia-mcode.sh --keyring --extra-keys good-key >"$KR/install.log" 2>&1 \
  || { OUT="$(cat "$KR/install.log")"; fail "installer failed with --keyring"; }
MINIMAX_DATA_DIR="$KR/data" mcode provider list --json | grep -q "http://127.0.0.1:$KR_PORT/v1" \
  || { OUT="$(cat "$KR/install.log")"; fail "mcode provider not pointed at the keyring proxy"; }
KR_CFG="$KR/home/.config/saia-keyring/keyring.json"
[[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$KR_CFG")" == 0o600 ]] \
  || fail "keyring.json is not chmod 600"
: >"$KR/seen"
set +e
OUT="$(MINIMAX_DATA_DIR="$KR/data" mcode exec \
  --model custom_provider:gwdg-saia/deepseek-v4-flash-0731 \
  --permission off --timeout 120s "reply with OK" 2>&1)"
RC=$?
set -e
[[ $RC -eq 0 ]] || fail "mcode exec through the keyring proxy exited $RC"
grep -q "OK-FAKE-KEYRING" <<<"$OUT" || fail "canned reply missing through the keyring proxy"
# mcode fires its token-count probes and the chat request concurrently, so each
# of them may hit the revoked key once before the first 401 marks it dead.
SEEN="$(paste -sd, "$KR/seen")"
grep -qx dead-key "$KR/seen" && grep -qx good-key "$KR/seen" \
  || fail "proxy did not fail over from the revoked key (saw: $SEEN)"
[[ "$(cat "$KR/count")" == 1 ]] \
  || fail "mcode needed $(cat "$KR/count") chat requests — the 401 leaked through to it"
# Once rejected, the key stays out of rotation: the next turn never touches it.
: >"$KR/seen"
OUT="$(MINIMAX_DATA_DIR="$KR/data" mcode exec \
  --model custom_provider:gwdg-saia/deepseek-v4-flash-0731 \
  --permission off --timeout 120s "reply with OK" 2>&1)" \
  || fail "second mcode exec through the keyring proxy failed"
grep -qx dead-key "$KR/seen" && fail "revoked key retried on the next turn (saw: $(paste -sd, "$KR/seen"))"
echo "PASS: automatic key swap (revoked key -> next key through the local proxy, 1 mcode request)"
