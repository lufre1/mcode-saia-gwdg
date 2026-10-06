# GWDG SAIA Provider Setup for mcode

## Summary

This installer registers the GWDG SAIA provider in mcode (MiniMax Code) with all 14 ready models.

## Prerequisites

- **SAIA API key** (from GWDG SAIA) — the installer reuses the key from a previous
  install, and prompts for it only when there is none
- **mcode** will be installed automatically if missing (via the official GitHub installer)

## Quick start

```bash
SAIA_API_KEY="your-key" bash install-mcode-saia.sh --yes
```

This one-shot installer:
- Installs mcode (if missing) via the official GitHub installer
- Registers the GWDG SAIA provider with 14 ready models
- Works on macOS, Linux, and WSL

## Detailed installation

### 1. Obtain your SAIA API key

Your key is stored in `~/.local/share/opencode/auth.json` (if you use opencode with SAIA), or you can generate a new one at the GWDG SAIA portal.

### 2. Run the installer

```bash
# Option A: via environment variable (recommended)
SAIA_API_KEY="your-key" bash install-mcode-saia.sh --yes

# Option B: via --key argument
bash install-mcode-saia.sh --key "your-key" --yes

# Option C: via --key-file (reads from a file)
bash install-mcode-saia.sh --key-file ~/.local/share/opencode/auth.json --yes

# Option D: pass nothing — reuses the key from a previous install,
# or asks for it (input hidden) if this is the first one
bash install-mcode-saia.sh --yes
```

The `--yes` flag enables non-interactive mode and auto-installs mcode if missing. Without it, the installer will prompt before installing mcode.

```bash
# Option A: via environment variable
SAIA_API_KEY="your-key" bash install-mcode-saia.sh

# Option B: via --key argument
bash install-mcode-saia.sh --key "your-key"

# Option C: via --key-file (reads from a file)
bash install-mcode-saia.sh --key-file ~/.local/share/opencode/auth.json
```

The installer will:
- Verify mcode is installed
- Back up your existing `~/.minimax/config.yaml` if it contains a `custom_provider:` block
- Run `mcode provider add` with all 14 ready SAIA models
- Verify the provider was added successfully
- Set `defaultModel` to a SAIA model, so mcode runs without a MiniMax account

### 3. Verify installation

```bash
mcode provider list
```

You should see `custom_provider:gwdg-saia` listed.

### 4. Test the provider

```bash
mcode provider test custom_provider:gwdg-saia --model deepseek-v4-flash-0731
```

Expected output: `Provider available: custom_provider:gwdg-saia/deepseek-v4-flash-0731`

## Usage

### Start a session with a SAIA model

```bash
# Use the TUI
mcode

# Or start with a specific model
mcode --model "custom_provider:gwdg-saia/deepseek-v4-flash-0731"
```

### Available models

All 14 ready SAIA models:

- apertus-70b-instruct-2509
- devstral-2-123b-instruct-2512
- qwen3.8-27b
- deepseek-v4-flash-0731
- glm-5.3-flash
- qwen3-coder-next
- qwen3-omni-30b-a3b-instruct
- mistral-medium-3.5-128b
- qwen3.5-397b-a17b
- gemma-4-31b-it
- qwen3.6-35b-a3b
- meta-llama-3.1-8b-instruct
- openai-gpt-oss-120b
- qwen3-30b-a3b-instruct-2507

## Outage resilience

SAIA goes down. mcode does retry a failed turn on its own — but the envelope is
small and, as far as can be determined on 0.5.1, **not configurable**.

Measured against a fake endpoint that returns 503 (`test/test-resume.sh`):

| Path | Requests before giving up | Survives |
|------|---------------------------|----------|
| `mcode exec` | 6 (1 + 5 retries) | 5 consecutive failures |
| TUI (`mcode`) | 9 | 8 consecutive failures |

Retries are back-to-back, so this is seconds of coverage, not minutes. **A SAIA
outage lasting longer than that ends the turn** and you re-prompt by hand.

### Why there is no knob

mcode's bundled runtime contains a settings store with `retry.enabled`,
`retry.maxRetries`, `retry.baseDelayMs` and `httpIdleTimeoutMs` (defaults 3 /
2000 ms / 300 s), but mcode 0.5.1 never reads it: an `strace` of a full TUI
session issuing nine LLM requests shows `settings.json` is not opened at any
path, and `config.yaml` has no schema for those keys either. Writing
`~/.minimax/settings.json` by hand does nothing — verified, retry on vs. off
produced byte-identical behaviour.

If a later mcode release wires that store up, the values worth setting are
`retry.maxRetries: 8` and `retry.baseDelayMs: 5000` — an exponential ladder of
5 s, 10 s, 20 s, 40 s, 80 s, 160 s, 320 s, 640 s, about 21 minutes of cover.

### Measuring it yourself

```bash
bash test/test-resume.sh            # default: 3 failures, should PASS
FAKE_FAIL_COUNT=8 bash test/test-resume.sh   # past the ceiling, should FAIL
```

Runs in a throwaway `MINIMAX_DATA_DIR` against `test/fake-saia.py`. Zero real
SAIA requests. Not packed into the installer.

## Multiple keys: automatic key swap

SAIA rate limits are per key (30/min, 200/hour, 1000/day, 3000/month). Opt in with
`--keyring`, give the installer extra keys, and mcode swaps to the next one by itself
when the active key is revoked (401/403), drained (its hour/day/month budget nearly used
up) or rate limited (429) — the same rotation the opencode setup does. mcode's own retry
loop (above) would just resend to the same dead key; the swap happens before mcode sees
an error.

```bash
# Extra keys via the environment, so they never show up in `ps`
SAIA_API_KEYS_EXTRA="key2,key3" bash install-mcode-saia.sh --yes --keyring

# Or reuse the extra keys of an opencode setup
bash install-mcode-saia.sh --yes --keyring --extra-keys-file ~/.local/share/opencode/saia-gwdg-keys.json
```

With `--keyring` the installer starts **saia-keyring**, a small local proxy
(`~/.local/share/saia-keyring/saia_keyring.py`, stdlib Python 3), and registers
`http://127.0.0.1:8788/v1` as the provider's `baseURL` (via `mcode provider add`, in
`~/.minimax/config.yaml`) instead of SAIA. mcode keeps sending its usual key; the proxy
only serves requests carrying one of the configured keys and forwards them on the
active key. Every harness installed with `--keyring` shares the same proxy and key list.
Keys are only swapped before a response starts — a stream in progress is never cut over.

| What | Where |
|------|-------|
| Keys | `~/.config/saia-keyring/keyring.json` (chmod 600), primary key first. A reinstall without extra keys keeps the stored ones; a changed list is backed up to `keyring.json.bak-<timestamp>` |
| Status | `saia-keyring status` — per-key budget, the active key, rejected keys |
| Log | `~/.cache/saia-keyring/proxy.log` |
| Service | systemd user unit `saia-keyring` (Linux), launchd agent `de.gwdg.saia-keyring` (macOS), otherwise a line in your shell rc |
| Turn off | re-run without `--keyring`: mcode talks to SAIA directly again |

Without `--keyring` none of this is installed: mcode talks to SAIA directly with one
key, as before (extra keys are then ignored). When every key is out, mcode shows why —
e.g. `All 3 SAIA key(s) rejected by SAIA (...) — the key(s) are revoked or expired`.
`test/test-resume.sh` checks the swap with a real `mcode exec` against the fake
endpoint.

## Config schema

The provider is stored in `~/.minimax/config.yaml` under `custom_provider:`:

```yaml
custom_provider:
  gwdg-saia:
    name: GWDG SAIA
    kind: custom
    enabled: true
    api: openai-completions
    options:
      apiKey: <your-key>
      baseURL: https://chat-ai.academiccloud.de/v1
      authMode: api-key
    models:
      <model-id>:
        reasoning: true
        thinking_config:
          mode: switchable
          default_value: 'true'
```

**Note**: mcode v0.5.0 stores the API key directly in `config.yaml` regardless of `--api-key-env`. The file has 600 permissions (owner read/write only).

## Troubleshooting

### Provider not showing in list

```bash
mcode provider list
mcode provider list --json | python3 -c "import json,sys; d=json.load(sys.stdin); providers=[p for p in d['providers'] if 'saia' in p.get('name','').lower()]; print(json.dumps(providers, indent=2))"
```

### Test provider

```bash
mcode provider test custom_provider:gwdg-saia --model deepseek-v4-flash-0731
```

### Remove provider

```bash
mcode provider remove custom_provider:gwdg-saia
```

### Re-add provider

```bash
SAIA_API_KEY="your-key" bash install-mcode-saia.sh
```

### mcode not found

The installer automatically installs mcode via the official GitHub installer if missing:

```bash
curl -fsSL https://filecdn.minimax.chat/public/install.sh | bash
```

This uses an isolated Node.js 24 runtime and prebuilt native SQLite, so no system Node/npm or build tools are required.

Alternatively, you can install manually:

```bash
npm install -g @minimax-ai/code
```

### API key errors

- Ensure `SAIA_API_KEY` is set correctly (no quotes in the env var value); with no
  key set at all, the installer asks for one, and fails only if there is no terminal
  to ask on (CI, cron) — set the env var there
- Verify the key is valid at the GWDG SAIA portal
- Check rate limits: 30 req/min, 200/hour, 1000/day, 3000/month per key

## Advanced: Regenerate the installer

If you modify `src/add-saia-mcode.sh` or `src/models.txt`, regenerate the installer.
`src/saia_keyring.py` and `src/saia-keyring.sh` are vendored from
`opencode-extras/keyring/` — change them there and run its `keyring/sync.sh`.

```bash
./build.sh
```

This creates a new `install-mcode-saia.sh` with the changes embedded.

## License

MIT