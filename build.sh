#!/usr/bin/env bash
#
# build.sh — pack the live SAIA config into install-mcode-saia.sh
#
# Reads the current src/add-saia-mcode.sh, src/models.txt and the vendored
# keyring (src/saia_keyring.py, src/saia-keyring.sh — from opencode-extras) and
# emits a single self-contained installer that can be copied to other devices.
# Rerun this after ANY change to those files, and commit both.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

OUT="install-mcode-saia.sh"
MANIFEST=(
  src/add-saia-mcode.sh
  src/models.txt
  src/saia-keyring.sh
  src/saia_keyring.py
)

# ── Sanity checks ────────────────────────────────────────────────────
for f in "${MANIFEST[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: missing source file: $f" >&2
    exit 1
  fi
  if grep -qF "__MCS_EOF__" "$f"; then
    echo "ERROR: delimiter '__MCS_EOF__' occurs in $f — pick a different delimiter" >&2
    exit 1
  fi
  if [[ -n "$(tail -c 1 "$f")" ]]; then
    echo "ERROR: $f lacks a trailing newline (heredoc packing would add one)" >&2
    exit 1
  fi
done

COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY=""
git diff --quiet HEAD -- "${MANIFEST[@]}" 2>/dev/null || DIRTY="-dirty"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

TMP_OUT="$(mktemp "$OUT.XXXXXX")"
trap 'rm -f "$TMP_OUT"' EXIT

# ── Header (interpolates the stamp) ──────────────────────────────────
cat >"$TMP_OUT" <<MCS_GEN_HEADER
#!/usr/bin/env bash
#
# install-mcode-saia.sh — GENERATED FILE, DO NOT EDIT.
# Regenerate with: ./build.sh  (in the mcode-saia repo)
# Source: mcode-saia commit $COMMIT$DIRTY, packed $STAMP
#
# Installs the GWDG SAIA setup for mcode: provider + $(grep -cvE '^[[:space:]]*(#|$)' src/models.txt) models.

MCS_GEN_HEADER

# ── Static installer body ────────────────────────────────────────────
cat >>"$TMP_OUT" <<'MCS_GEN_BODY'
set -euo pipefail

CONFIG_DIR="${MINIMAX_DATA_DIR:-$HOME/.minimax}"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
BACKUP_DIR=""

usage() {
  cat <<'USAGE'
Usage: SAIA_API_KEY="your-key" bash install-mcode-saia.sh [OPTIONS]

Installs the GWDG SAIA setup for mcode:
  - Registers custom_provider:gwdg-saia with all ready SAIA models (src/models.txt)
  - Configures provider with base URL and API format

Options:
  -y, --yes           answer yes to prompts (e.g. installing mcode)
      --key <value>   SAIA API key (overrides SAIA_API_KEY env)
      --key-file <p>  file containing the SAIA API key
      --extra-keys <k2,k3>      extra SAIA keys for automatic failover
                                (or SAIA_API_KEYS_EXTRA, which keeps them out of ps)
      --extra-keys-file <path>  extra keys from {"keys": [...]} (opencode's
                                saia-gwdg-keys.json) or one key per line
      --keyring / --no-keyring  force the key-rotating proxy on / off
  -h, --help          show this help

The API key is taken from --key, --key-file or the SAIA_API_KEY environment
variable; if none of them is set, you are prompted for it.
Files that would be overwritten are backed up to ~/.minimax.bak-<timestamp>/ first.

With 2+ keys mcode talks to a local proxy (saia-keyring, 127.0.0.1:8788) that swaps
to the next key when the active one is revoked, drained or rate limited.
USAGE
}

# Pull the key out of a previous install so a reinstall does not ask again.
# Scoped to the gwdg-saia* block under custom_provider: the minimax provider
# has an apiKey too, and grabbing that one would install a broken key.
key_from_config() {
  local cfg="${MINIMAX_DATA_DIR:-$HOME/.minimax}/config.yaml"
  [[ -f "$cfg" ]] || return 0
  awk '/^custom_provider:/{s=1;next} /^[^ ]/{s=0} s&&/^  [A-Za-z]/{p=($1~/^gwdg-saia/)} s&&p&&$1=="apiKey:"{print $2;exit}' "$cfg"
  return 0
}

prompt_for_key() {
  if ! { : </dev/tty; } 2>/dev/null; then   # -r only stats; this actually opens it
    echo "ERROR: No SAIA API key given and no terminal to ask on." >&2
    echo "Set it: SAIA_API_KEY=\"your-key\" bash install-mcode-saia.sh" >&2
    echo "Get one at https://chat-ai.academiccloud.de/" >&2
    exit 1
  fi
  local key=""
  for _ in 1 2 3; do
    read -rsp "GWDG SAIA API key (input hidden): " key </dev/tty
    echo >&2
    key="${key//[[:space:]]/}"   # paste hygiene; SAIA keys carry no whitespace
    if [[ -n "$key" ]]; then
      export SAIA_API_KEY="$key"
      return
    fi
    echo "Key cannot be empty." >&2
  done
  echo "ERROR: no key entered." >&2
  exit 1
}

ASSUME_YES=0
KEY=""
KEY_FILE=""
KEYRING_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    --key|--key-file)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
      if [[ $1 == --key ]]; then KEY="$2"; else KEY_FILE="$2"; fi
      shift 2
      ;;
    --extra-keys|--extra-keys-file)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
      KEYRING_ARGS+=("$1" "$2")
      shift 2
      ;;
    --keyring|--no-keyring) KEYRING_ARGS+=("$1"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ── Obtain the API key ───────────────────────────────────────────────
# Reuse a key from a previous install; only ask when there is none to reuse,
# and ask before anything is installed, so an empty-handed user loses nothing.
if [[ -z "$KEY" && -z "$KEY_FILE" && -z "${SAIA_API_KEY:-}" ]]; then
  SAIA_API_KEY="$(key_from_config)"
  if [[ -n "$SAIA_API_KEY" ]]; then
    export SAIA_API_KEY
    echo "Reusing the SAIA key already in $CONFIG_FILE (pass --key to replace it)."
  else
    prompt_for_key
  fi
fi

# ── Check/install mcode ──────────────────────────────────────────────
MCODE_BIN="$HOME/.minimax-code/bin/mcode"
if ! command -v mcode &>/dev/null; then
  # mcode not in PATH - check if installed in default location
  if [[ -x "$MCODE_BIN" ]]; then
    # Found mcode in install location - add to PATH for this session
    export PATH="$HOME/.minimax-code/bin:$PATH"
  elif [[ $ASSUME_YES -eq 1 ]]; then
    echo "mcode not found — installing via official installer..."
  elif [[ -t 0 ]]; then
    read -r -p "mcode not found — install it via the official installer? [y/N] " reply
    if [[ $reply != [yY]* ]]; then
      echo "Aborted." >&2
      exit 1
    fi
  else
    echo "ERROR: mcode not found and not in TTY mode — use --yes to auto-install" >&2
    exit 1
  fi

  # Install mcode via official GitHub installer if still not found
  if ! command -v mcode &>/dev/null; then
    if ! command -v curl &>/dev/null; then
      echo "ERROR: curl is required to install mcode" >&2
      exit 1
    fi

    echo "Downloading and installing mcode..."
    if ! curl -fsSL https://filecdn.minimax.chat/public/install.sh | bash; then
      echo "ERROR: mcode installation failed" >&2
      exit 1
    fi

    # Add mcode to PATH for this session (official installer updates shell rc, not current PATH)
    export PATH="$HOME/.minimax-code/bin:$PATH"

    # Verify installation
    if ! command -v mcode &>/dev/null; then
      echo "ERROR: mcode installation completed but not found in PATH" >&2
      exit 1
    fi

    echo "mcode installed successfully"
  fi
fi

# ── Backup existing config if needed ─────────────────────────────────
if [[ -f "$CONFIG_FILE" ]]; then
  if grep -qF "custom_provider:" "$CONFIG_FILE"; then
    if [[ $ASSUME_YES -eq 1 ]]; then
      BACKUP_DIR=""
    elif [[ -t 0 ]]; then
      read -r -p "Backup existing config and overwrite? [y/N] " reply
      if [[ $reply == [yY]* ]]; then
        BACKUP_DIR="$CONFIG_DIR.bak-$(date +%Y%m%d%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        cp "$CONFIG_FILE" "$BACKUP_DIR/config.yaml"
        echo "Backed up $CONFIG_FILE to $BACKUP_DIR/"
      else
        echo "Aborted." >&2
        exit 1
      fi
    else
      echo "ERROR: Config exists with custom_provider block and not in TTY mode" >&2
      echo "Set SAIA_API_KEY and use --yes to overwrite" >&2
      exit 1
    fi
  fi
fi

# ── Unpack the bundled source files ──────────────────────────────────
# Into a temp dir, not next to the installer: this file is meant to be copied
# to a fresh machine on its own, and it must not litter (or overwrite) a repo
# checkout it happens to be run from.
EXTRACT_DIR="$(mktemp -d)"
trap 'rm -rf "$EXTRACT_DIR"' EXIT
mkdir -p "$EXTRACT_DIR/src"
MCS_GEN_BODY

# ── Append the packed source files ───────────────────────────────────
echo "" >>"$TMP_OUT"
echo "# ── Packed source files ────────────────────────────────────────────" >>"$TMP_OUT"

for f in "${MANIFEST[@]}"; do
  echo "cat >\"\$EXTRACT_DIR/$f\" <<'__MCS_EOF__'" >>"$TMP_OUT"
  cat "$f" >>"$TMP_OUT"
  echo "__MCS_EOF__" >>"$TMP_OUT"
  echo "" >>"$TMP_OUT"
done

# ── Static installer tail: run what we just unpacked ──────────────────
cat >>"$TMP_OUT" <<'MCS_GEN_TAIL'
chmod +x "$EXTRACT_DIR/src/add-saia-mcode.sh"
CHILD_ARGS=()
if [[ -n "$KEY" ]]; then CHILD_ARGS+=(--key "$KEY"); fi
if [[ -n "$KEY_FILE" ]]; then CHILD_ARGS+=(--key-file "$KEY_FILE"); fi
CHILD_ARGS+=(${KEYRING_ARGS[@]+"${KEYRING_ARGS[@]}"})
# ${a[@]+"${a[@]}"}: bash 3.2 (stock macOS) calls an empty array unbound under set -u
"$EXTRACT_DIR/src/add-saia-mcode.sh" ${CHILD_ARGS[@]+"${CHILD_ARGS[@]}"}

echo ""
echo "✓ GWDG SAIA provider installed successfully!"
echo "  Provider ID: custom_provider:gwdg-saia"
echo "  Models: $(grep -cvE '^[[:space:]]*(#|$)' "$EXTRACT_DIR/src/models.txt") ready SAIA models"
echo ""
echo "Usage: mcode                       # SAIA is the default model"
echo "       mcode --model custom_provider:gwdg-saia/<model>"
MCS_GEN_TAIL

# ── Finalize ─────────────────────────────────────────────────────────
mv "$TMP_OUT" "$OUT"
chmod +x "$OUT"

echo "Generated: $OUT"
echo "Commit: $COMMIT$DIRTY"
echo "Timestamp: $STAMP"