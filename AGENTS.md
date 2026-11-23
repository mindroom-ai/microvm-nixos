# Deployment Runbook

This file is the canonical, machine-followable runbook for deploying MindRoom as a standalone QEMU microVM (`microvm.nix`).
Follow steps 1–9 in order; every code block is self-contained and can be run verbatim in a fresh shell.

For background on what the deployed VM contains and its security model, read [README.md](README.md).

## Preconditions

- An `x86_64-linux` host with `/dev/kvm` readable and writable by your user (`[ -r /dev/kvm ] && [ -w /dev/kvm ]`; otherwise QEMU silently falls back to software TCG emulation).
- `git`, `ssh-keygen`, `ssh`, `curl`, `setsid`, and `nix` with flakes enabled (on stock Nix, add `experimental-features = nix-command flakes` to `~/.config/nix/nix.conf` once so every fresh shell and inner `nix eval` call has flakes enabled).
- At least 8 GiB free RAM (for the first-boot MindRoom Chat web UI build and `uv` installs).
- An operator SSH public key at `~/.ssh/id_ed25519.pub` with its matching private key loaded in `ssh-agent` (`ssh-add -l` lists it) so non-interactive `ssh -o BatchMode=yes` succeeds (change `OP_KEY_FILE` in steps 1 and 3 if your key is elsewhere; must be `ssh-ed25519` or `ssh-rsa` for `ragenix`).
- Outbound access to GitHub (the guest clones MindRoom and MindRoom Chat on first boot).
- **Host isolation note:** Default QEMU user (SLIRP) networking allows the guest to reach host `127.0.0.1` loopback services via `10.0.2.2`, and the 9p `ro-store` share exposes the entire host `/nix/store`.
  Run the defaults only on a host without sensitive loopback-only services or secrets in `/nix/store` (see [Hardening (optional)](#hardening-optional) below).

## 1. Clone and Configure the Host

Clone the repo to `~/microvm-nixos` and add your operator SSH public key to `hosts/mindroom/default.nix`:

```bash
REPO=~/microvm-nixos STATE_DIR=~/.local/state/mindroom-microvm
(
  set -euo pipefail
  OP_KEY_FILE=~/.ssh/id_ed25519.pub
  OP_KEY="$(awk 'NR==1 {print $1, $2}' "$OP_KEY_FILE")"
  [ -n "$OP_KEY" ] || { echo "Missing operator public key in $OP_KEY_FILE" >&2; exit 1; }
  git clone https://github.com/mindroom-ai/microvm-nixos.git "$REPO"
  sed -i "s|# \"ssh-ed25519 AAAA\.\.\. you@example\"|\"$OP_KEY\"|" "$REPO/hosts/mindroom/default.nix"
  grep -qF "\"$OP_KEY\"" "$REPO/hosts/mindroom/default.nix"
)
```

Expect exit 0 and your key present in `hosts/mindroom/default.nix`.

- **Runtime toggles (optional):** edit [hosts/mindroom/default.nix](hosts/mindroom/default.nix) if you want to change the defaults:
  - `mindroom.runtime.lab.enable = true` (default): self-contained agents talking to the local Tuwunel homeserver inside the VM.
  - `mindroom.runtime.chat.enable = false` (default): agents connecting to hosted `mindroom.chat` (requires pairing credentials; if enabled, append `--with-chat` in step 4).
- If host loopback ports `127.0.0.1:8080` (Caddy) or `127.0.0.1:2222` (SSH) are already in use, edit `microvm.forwardPorts` in [modules/microvm-guest.nix](modules/microvm-guest.nix) and substitute your ports in steps 7–8.
- If you run more than one microVM from this repo, give each VM its own `microvm.machineId` in [modules/microvm-guest.nix](modules/microvm-guest.nix) (`systemd-id128 --uuid new`).

## 2. Create the Private State Directory and Guest SSH Host Key

Keep VM state **outside** any git work tree (a `path:` flake ref copies untracked files inside a repo into the world-readable `/nix/store`):

```bash
REPO=~/microvm-nixos STATE_DIR=~/.local/state/mindroom-microvm
(
  set -euo pipefail
  install -d -m 700 "$STATE_DIR"
  if [ "$(git -C "$STATE_DIR" rev-parse --is-inside-work-tree 2>/dev/null || true)" = "true" ]; then
    echo "Refusing to place VM state inside a git work tree: $STATE_DIR" >&2
    exit 1
  fi
  install -d -m 700 "$STATE_DIR/ssh"
  ssh-keygen -q -t ed25519 -N "" -C "root@mindroom" -f "$STATE_DIR/ssh/ssh_host_ed25519_key"
  cat "$STATE_DIR/ssh/ssh_host_ed25519_key.pub"
)
```

Expect an `ssh-ed25519 AAAA... root@mindroom` public key line.
The runner mounts `$STATE_DIR/ssh` read-only early in boot (`neededForBoot = true`), so `agenix` decrypts secrets on first boot and `sshd` keeps a stable host identity across reboots.

## 3. Configure Secret Recipients

Insert BOTH your operator SSH public key (`~/.ssh/id_ed25519.pub`) and the guest host public key (`$STATE_DIR/ssh/ssh_host_ed25519_key.pub`) into both recipient files ([secrets/shared/secrets.nix](secrets/shared/secrets.nix) and [hosts/mindroom/secrets/secrets.nix](hosts/mindroom/secrets/secrets.nix)):

```bash
REPO=~/microvm-nixos STATE_DIR=~/.local/state/mindroom-microvm
(
  set -euo pipefail
  OP_KEY_FILE=~/.ssh/id_ed25519.pub
  OP_KEY="$(awk 'NR==1 {print $1, $2}' "$OP_KEY_FILE")"
  HOST_KEY="$(awk 'NR==1 {print $1, $2}' "$STATE_DIR/ssh/ssh_host_ed25519_key.pub")"
  [ -n "$OP_KEY" ] && [ -n "$HOST_KEY" ] || { echo "Missing operator or host public key" >&2; exit 1; }
  for f in "$REPO/secrets/shared/secrets.nix" "$REPO/hosts/mindroom/secrets/secrets.nix"; do
    sed -i \
      -e "s|# \"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA\.\.\. you@example\"|\"$OP_KEY\"|" \
      -e "s|# \"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA\.\.\. root@mindroom\"|\"$HOST_KEY\"|" \
      "$f"
    grep -qF "\"$OP_KEY\"" "$f" && grep -qF "\"$HOST_KEY\"" "$f"
  done
)
```

Expect exit 0. The repo ships empty recipient arrays and placeholder `.age` files; the bootstrap script refuses to run until recipients are configured.

## 4. Bootstrap Secrets

Encrypt all secrets non-interactively using the repo-pinned `ragenix`.
If `OPENAI_API_KEY` is already exported in your environment, it is used directly; otherwise `read -rsp` prompts silently on a TTY (or fails with a clear message if stdin is not a TTY) so the key never enters shell history.
Plaintext staging requires a filesystem verified as `tmpfs` (`$XDG_RUNTIME_DIR` then `/dev/shm`, failing closed otherwise) and is deleted on subshell exit:

```bash
REPO=~/microvm-nixos STATE_DIR=~/.local/state/mindroom-microvm
(
  set -euo pipefail
  cd "$REPO"
  if [ -z "${OPENAI_API_KEY:-}" ]; then
    if [ ! -t 0 ]; then
      echo "OPENAI_API_KEY is not set and stdin is not a TTY; export OPENAI_API_KEY and re-run." >&2
      exit 1
    fi
    read -rsp "OPENAI_API_KEY: " OPENAI_API_KEY
    echo
  fi
  TMPFS_BASE=""
  for candidate in "${XDG_RUNTIME_DIR:-}" /dev/shm; do
    if [ -n "$candidate" ] && [ -d "$candidate" ] && [ -w "$candidate" ] \
      && [ "$(stat -f -c %T "$candidate" 2>/dev/null || true)" = "tmpfs" ]; then
      TMPFS_BASE="$candidate"
      break
    fi
  done
  [ -n "$TMPFS_BASE" ] || { echo "Neither \$XDG_RUNTIME_DIR nor /dev/shm is a writable tmpfs; refusing to stage plaintext secrets on disk." >&2; exit 1; }
  SECRETS_TMP="$(umask 077 && mktemp -d "$TMPFS_BASE/mindroom-secrets.XXXXXX")"
  trap 'rm -rf "$SECRETS_TMP"' EXIT
  (umask 077 && printf 'OPENAI_API_KEY=%s\n' "$OPENAI_API_KEY" > "$SECRETS_TMP/agent-integrations.env")
  nix shell .#ragenix -c ./scripts/bootstrap-secrets.sh --non-interactive --values-dir "$SECRETS_TMP"
)
```

**Runtime toggle (`chat.enable = true`):** also write `$SECRETS_TMP/chat-runtime.env` before running the script and append `--with-chat`.

Expect `Secrets bootstrapped for host 'mindroom'.` and these encrypted files:

| Secret | Content |
| --- | --- |
| `secrets/shared/agent-integrations.env.age` | LLM provider API keys shared by all runtimes |
| `secrets/shared/agent-tooling.env.age` | Tool credentials (GitHub, search, ...) |
| `hosts/mindroom/secrets/agent-runtime.env.age` | Host-local settings shared by all runtimes |
| `hosts/mindroom/secrets/lab-runtime.env.age` | Lab runtime env (local Tuwunel URL, server name, synced registration token) |
| `hosts/mindroom/secrets/registration-token.age` | Tuwunel registration token (bare token only) |

Notes:

- Supported filenames in `--values-dir` (no `.age` suffix): `agent-integrations.env`, `agent-tooling.env`, `agent-runtime.env`, `lab-runtime.env`, `chat-runtime.env`, `registration-token`. Missing files fall back to `templates/`.
- The Tuwunel registration token is auto-generated and written to BOTH `registration-token.age` and `MATRIX_REGISTRATION_TOKEN` in `lab-runtime.env.age` so they stay in sync.
- Keep `MATRIX_HOMESERVER=http://127.0.0.1:8008` and `MATRIX_SERVER_NAME=mindroom.lab.mindroom.chat` from the lab template unless you also change [hosts/mindroom/constants.nix](hosts/mindroom/constants.nix).
- `templates/lab-runtime.env.example` sets `MINDROOM_OWNER_USER_ID=@you:mindroom.lab.mindroom.chat`, which `mindroom config init` reads on first boot to populate `administrators` and `room_defaults` without editing `config.yaml` (change the localpart in `lab-runtime.env` before first boot if you want a different username). agenix provides the runtime env; config init's starter `.env` is removed.
- Upgrading an existing deployment: agenix values now win over any local `.env`; put overrides in the encrypted runtime env (`lab-runtime.env.age` / `chat-runtime.env.age`), add `MINDROOM_OWNER_USER_ID` to `lab-runtime.env.age`, and replace `__MINDROOM_OWNER_USER_ID_FROM_PAIRING__` in `/var/lib/mindroom/lab/config.yaml` once.
- Re-runs keep existing `.age` files and verify their recipients match `secrets.nix`; if a prior attempt encrypted files to stale recipients, delete the listed `.age` files and re-run.

## 5. Preflight Check and Build the GC-Rooted Runner

Verify flake evaluation (eval-only, catches Nix errors and missing SSH key warnings) and build the runner with `--out-link runner` inside `$STATE_DIR` so host Nix garbage collection cannot remove store paths the live guest mounts over 9p:

```bash
REPO=~/microvm-nixos STATE_DIR=~/.local/state/mindroom-microvm
(
  set -euo pipefail
  cd "$REPO"
  nix flake check
  cd "$STATE_DIR"
  nix build --out-link runner "$REPO"
)
```

Expect `all checks passed!` (a `warning: Git tree ... is dirty` message is expected after steps 1–4; go back to step 1 if Nix warns that no SSH authorized keys are configured) and a `$STATE_DIR/runner` symlink pointing into `/nix/store`.
(`"$REPO"` selects `packages.x86_64-linux.default`, which is identical to `"$REPO#mindroom-microvm"`.)

## 6. Start the MicroVM

Start the microVM detached in its own session (`setsid -f`) so the shell returns immediately.
Serial console output is written to `$STATE_DIR/console.log` (mode `0600`):

```bash
REPO=~/microvm-nixos STATE_DIR=~/.local/state/mindroom-microvm
(
  set -euo pipefail
  cd "$STATE_DIR"
  umask 077
  setsid -f ./runner/bin/microvm-run > "$STATE_DIR/console.log" 2>&1 < /dev/null
)
```

`microvm-run` refuses to start inside a git work tree, enforces `chmod 0700 .` and `umask 077`, and creates `0600` sparse ext4 images (`var.img`, `srv.img`, `nix-store.img`) plus `control.sock` in `$STATE_DIR`.
SSH comes up in ~30–40 seconds; first-boot git checkouts, the MindRoom Chat web UI build, and `mindroom-lab` `uv` environment install take ~2 minutes on a fast connection.
Inspect `$STATE_DIR/console.log` (`tail -n 50 "$STATE_DIR/console.log"`) if boot fails.

## 7. Verify Services and Endpoints

Pin the VM host key (clearing any stale `[127.0.0.1]:2222` entry via `ssh-keygen -R '[127.0.0.1]:2222'` when redeploying), wait for first-boot services, and verify systemd status plus forwarded HTTP endpoints (adjust `2222`/`8080` or the runtime unit list if you changed `forwardPorts` or the runtime toggles):

```bash
REPO=~/microvm-nixos STATE_DIR=~/.local/state/mindroom-microvm
(
  set -euo pipefail
  install -d -m 700 ~/.ssh
  ssh-keygen -R '[127.0.0.1]:2222' >/dev/null 2>&1 || true
  echo "[127.0.0.1]:2222 $(cat "$STATE_DIR/ssh/ssh_host_ed25519_key.pub")" >> ~/.ssh/known_hosts

  # Wait for SSH and all first-boot services (checkouts + UI build + mindroom-lab uv install).
  SSH_ERR="$(mktemp)"
  trap 'rm -f "$SSH_ERR"' EXIT
  if ! timeout 600 bash -c '
    until ssh -n -o BatchMode=yes -o ConnectTimeout=5 -p 2222 mindroom@127.0.0.1 \
      "systemctl is-active -q tuwunel && systemctl is-active -q caddy && systemctl is-active -q mindroom-cinny && systemctl is-active -q mindroom-lab" 2>"$1" \
      && curl -sf -H "Host: chat.lab.mindroom.chat" http://127.0.0.1:8080/ >/dev/null; do
      grep -qE "Connection refused|Connection reset|Connection closed|kex_exchange_identification|timed out" "$1" 2>/dev/null || cat "$1" >&2
      sleep 10
    done
  ' _ "$SSH_ERR"; then
    echo "Timed out waiting for microVM services. Last SSH error:" >&2
    cat "$SSH_ERR" >&2
    echo "See $STATE_DIR/console.log for boot output." >&2
    exit 1
  fi

  ssh -o BatchMode=yes -p 2222 mindroom@127.0.0.1 'systemctl --failed --no-pager && systemctl is-active tuwunel caddy mindroom-cinny mindroom-lab'
  printf '%.200s\n' "$(curl -fsS -H 'Host: mindroom.lab.mindroom.chat' http://127.0.0.1:8080/_matrix/client/versions)"
  curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: chat.lab.mindroom.chat' http://127.0.0.1:8080/
)
```

Expect:

- `0 loaded units listed.`
- Four `active` lines (`tuwunel`, `caddy`, `mindroom-cinny`, `mindroom-lab`)
- Matrix version JSON (`{"versions":[...]}`)
- `200`

Inspect logs or retry a transient network failure if any unit fails:

```bash
REPO=~/microvm-nixos STATE_DIR=~/.local/state/mindroom-microvm
tail -n 50 "$STATE_DIR/console.log"
ssh -o BatchMode=yes -p 2222 mindroom@127.0.0.1 'journalctl -u mindroom-lab -u mindroom-cinny-build -u tuwunel -n 100 --no-pager'
ssh -o BatchMode=yes -p 2222 mindroom@127.0.0.1 'sudo systemctl restart git-checkout-cinny.service mindroom-cinny-build.service mindroom-cinny.service'
```

## 8. Register a Local Lab User and Verify an Agent Reply

On first boot, `mindroom-lab` runs `mindroom config init --no-input --matrix-server self-hosted --provider openai` (filling your owner ID from `MINDROOM_OWNER_USER_ID` in `lab-runtime.env.age`), registers its agents (`@mindroom_user`, `@mindroom_router`, `@mindroom_mind`) on local Tuwunel, and initializes `/var/lib/mindroom/lab` as a Git repository with an initial commit.
Register the owner Matrix account, restart `mindroom-lab` so it invites you to the `personal` room, accept the invite, and verify a live reply from `@mindroom_mind` (requires a valid LLM provider key from step 4):

```bash
REPO=~/microvm-nixos STATE_DIR=~/.local/state/mindroom-microvm
ssh -o BatchMode=yes -p 2222 mindroom@127.0.0.1 bash -s <<'EOF'
set -euo pipefail
OWNER_ID=$(sudo awk -F= '$1=="MINDROOM_OWNER_USER_ID"{sub(/^[^=]*=/,""); print; exit}' /run/agenix/lab-runtime-env | tr -d '\r')
if [ -z "$OWNER_ID" ] || [ "$OWNER_ID" = "__MINDROOM_OWNER_USER_ID_FROM_PAIRING__" ]; then
  echo "MINDROOM_OWNER_USER_ID is unset or still a placeholder in /run/agenix/lab-runtime-env; set it to @<user>:mindroom.lab.mindroom.chat and re-deploy before registering." >&2
  exit 1
fi
if grep -qF "__MINDROOM_OWNER_USER_ID_FROM_PAIRING__" /var/lib/mindroom/lab/config.yaml; then
  echo "/var/lib/mindroom/lab/config.yaml still contains __MINDROOM_OWNER_USER_ID_FROM_PAIRING__; replace it with \"$OWNER_ID\" and restart mindroom-lab before registering." >&2
  exit 1
fi
case "$OWNER_ID" in
  @*:* ) ;;
  *)
    echo "Invalid MINDROOM_OWNER_USER_ID '$OWNER_ID' (expected @<user>:<server>)." >&2
    exit 1
    ;;
esac
USER_LOCALPART="${OWNER_ID#@}"
USER_LOCALPART="${USER_LOCALPART%%:*}"
PASSWORD=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
TOKEN=$(sudo cat /run/agenix/registration-token)
SESSION=$(curl -sS -X POST http://127.0.0.1:8008/_matrix/client/v3/register \
  -H 'Content-Type: application/json' \
  -d "$(jq -cn --arg u "$USER_LOCALPART" --arg p "$PASSWORD" '{username:$u,password:$p}')" | jq -r .session)
REG=$(jq -cn --arg u "$USER_LOCALPART" --arg p "$PASSWORD" --arg s "$SESSION" --arg t "$TOKEN" \
  '{username:$u,password:$p,auth:{type:"m.login.registration_token",token:$t,session:$s}}' | \
  curl -sS -X POST http://127.0.0.1:8008/_matrix/client/v3/register -H 'Content-Type: application/json' -d @-)
unset TOKEN
USER_ID=$(printf '%s' "$REG" | jq -r '.user_id // empty')
ACCESS_TOKEN=$(printf '%s' "$REG" | jq -r '.access_token // empty')
if [ "$USER_ID" != "$OWNER_ID" ] || [ -z "$ACCESS_TOKEN" ]; then
  echo "Registration failed (got '${USER_ID:-<empty>}')" >&2
  exit 1
fi
(umask 077 && printf '%s\n' "$PASSWORD" > "$HOME/.lab-user-password")
unset PASSWORD
printf 'Registered %s (password saved in ~/.lab-user-password, mode 0600)\n' "$USER_ID"

# Restart mindroom-lab so it invites the newly registered owner to the personal room.
sudo systemctl restart mindroom-lab

# Wait for the invite to the personal room, join it, and send a test prompt.
ROOM_ID=""
for _ in $(seq 1 60); do
  ROOM_ID=$(curl -sS -H "Authorization: Bearer $ACCESS_TOKEN" \
    'http://127.0.0.1:8008/_matrix/client/v3/sync?timeout=2000' | \
    jq -r '
      ((.rooms.invite // {}) | to_entries | map(select(any(.value.invite_state.events[]?; .type == "m.room.name" and (.content.name // "" | ascii_downcase) == "personal"))) | .[0].key)
      // empty
    ')
  [ -n "$ROOM_ID" ] && break
  sleep 2
done
[ -n "$ROOM_ID" ] || { echo "Timed out waiting for personal room invite" >&2; exit 1; }

ENC_ROOM=$(jq -rn --arg r "$ROOM_ID" '$r|@uri')
curl -sfS -X POST -H "Authorization: Bearer $ACCESS_TOKEN" -H 'Content-Type: application/json' \
  -d '{}' "http://127.0.0.1:8008/_matrix/client/v3/join/$ENC_ROOM" >/dev/null
sleep 2
curl -sfS -X PUT -H "Authorization: Bearer $ACCESS_TOKEN" -H 'Content-Type: application/json' \
  -d '{"msgtype":"m.text","body":"@mindroom_mind reply with exactly: MICROVM-OK","m.mentions":{"user_ids":["@mindroom_mind:mindroom.lab.mindroom.chat"]}}' \
  "http://127.0.0.1:8008/_matrix/client/v3/rooms/$ENC_ROOM/send/m.room.message/test-$(date +%s)" >/dev/null

# Poll for @mindroom_mind's reply (handles both initial messages and streaming edits).
REPLY=""
for _ in $(seq 1 45); do
  REPLY=$(curl -sS -H "Authorization: Bearer $ACCESS_TOKEN" \
    "http://127.0.0.1:8008/_matrix/client/v3/rooms/$ENC_ROOM/messages?dir=b&limit=20" | \
    jq -r '.chunk[]
      | select(.type == "m.room.message" and .sender == "@mindroom_mind:mindroom.lab.mindroom.chat")
      | (.content."m.new_content".body // .content.body // "")
      | select(contains("MICROVM-OK"))' | head -n 1)
  [ -n "$REPLY" ] && break
  sleep 2
done
unset ACCESS_TOKEN
[ -n "$REPLY" ] || { echo "Timed out waiting for @mindroom_mind reply" >&2; exit 1; }
printf 'Reply from @mindroom_mind: %s\n' "$REPLY"
EOF
```

Expect `Registered @you:mindroom.lab.mindroom.chat ...` followed by `Reply from @mindroom_mind: MICROVM-OK`.

Notes for browser login and TLS:

- When signing in through MindRoom Chat (which defaults to hosted `mindroom.chat`), enter the lab homeserver `https://mindroom.lab.mindroom.chat` (served through your TLS proxy) before logging in.
  The raw forwarded `http://127.0.0.1:8080` is not a homeserver URL: Caddy routes by hostname.
- Nothing inside this VM terminates TLS. Put a TLS-terminating reverse proxy in front of `127.0.0.1:8080` (see [README.md](README.md#security)).

## 9. Stop, Reboot, and Update

Shut down cleanly so the ext4 volumes (`var.img`, `srv.img`, `nix-store.img`) unmount cleanly (`microvm-shutdown` blocks until QEMU exits):

```bash
REPO=~/microvm-nixos STATE_DIR=~/.local/state/mindroom-microvm
(
  set -euo pipefail
  cd "$STATE_DIR"
  ./runner/bin/microvm-shutdown
)
```

Re-running step 6 from `$STATE_DIR` reuses all persistent volumes: SSH host key, git checkouts, built MindRoom Chat UI (no rebuild on second boot), Tuwunel database/accounts, guest-installed Nix store paths and DB, and multi-boot journals survive intact.

Pinned versions live in [hosts/mindroom/constants.nix](hosts/mindroom/constants.nix) (bumped daily by `.github/workflows/update-pins.yml`, or locally via `./scripts/update-pins.sh`).
To apply updates:

```bash
REPO=~/microvm-nixos STATE_DIR=~/.local/state/mindroom-microvm
(
  set -euo pipefail
  git -C "$REPO" pull
  cd "$STATE_DIR"
  ./runner/bin/microvm-shutdown
  nix build --out-link runner "$REPO"
  umask 077
  setsid -f ./runner/bin/microvm-run > "$STATE_DIR/console.log" 2>&1 < /dev/null
)
```

Checkouts with uncommitted local changes are never touched by updates.

## Hardening (optional)

To isolate the microVM from host loopback services (`10.0.2.2`) and the host `/nix/store`, edit [modules/microvm-guest.nix](modules/microvm-guest.nix) to:

1. Set `microvm.storeOnDisk = true` **and remove the `ro-store` entry from `microvm.shares` (keeping `ssh-host-key`)** so `/nix/.ro-store` is not defined twice (the writable overlay uses label `mindroom-rw`, avoiding collision with `storeOnDisk`'s `nix-store` label).
2. Switch `microvm.interfaces` from `type = "user"` to `tap` networking (eliminating SLIRP `10.0.2.2` access): remove `microvm.forwardPorts` (which requires a `user` interface), configure the host-side TAP device/bridge, and connect to the VM's network address instead of `127.0.0.1:8080`/`2222` in steps 7–8.
3. After host Nix garbage collection when using the default 9p store share, run `nix-store --verify` inside the guest if guest `nix` commands report missing paths.
