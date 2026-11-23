# Deployment Runbook

This file is the canonical, machine-followable runbook for deploying MindRoom as a standalone QEMU microVM (`microvm.nix`).
Follow steps 1–9 in order; each step lists the exact commands and what success looks like.

For background on what the deployed VM contains and its security model, read [README.md](README.md).

## Preconditions

- An `x86_64-linux` host with `/dev/kvm` readable and writable by your user (`[ -r /dev/kvm ] && [ -w /dev/kvm ]`; otherwise QEMU silently falls back to software TCG emulation).
- `git`, `ssh-keygen`, `ssh`, `curl`, and `nix` installed on the host.
  On a stock Nix install without flakes enabled in `nix.conf`, run `export NIX_CONFIG='extra-experimental-features = nix-command flakes'` once in your shell (flags on an outer `nix shell` do not reach inner `nix eval` calls in `scripts/bootstrap-secrets.sh`).
- At least 8 GiB free RAM (for the first-boot MindRoom Chat web UI build and `uv` installs) and an operator SSH public key.
- Outbound access to GitHub (the guest clones MindRoom and MindRoom Chat on first boot).
- **Host isolation note:** Default QEMU user (SLIRP) networking allows the guest to reach host `127.0.0.1` loopback services via `10.0.2.2`, and the 9p `ro-store` share exposes the entire host `/nix/store`.
  Run the defaults only on a host without sensitive loopback-only services or secrets in `/nix/store` (see [README.md](README.md#security-model) for `storeOnDisk` and `tap` hardening).

## 1. Clone and Configure the Host

```bash
git clone https://github.com/mindroom-ai/microvm-nixos.git
cd microvm-nixos
REPO="$PWD"
```

Edit [hosts/mindroom/default.nix](hosts/mindroom/default.nix):

1. Add your operator SSH public key to `mindroom.runtime.authorizedKeys` (required for SSH access into the VM).
2. **Runtime toggles (optional):**
   - `mindroom.runtime.lab.enable = true` (default): self-contained agents talking to the local Tuwunel homeserver inside the VM.
   - `mindroom.runtime.chat.enable = false` (default): agents connecting to hosted `mindroom.chat` (requires pairing credentials; if enabled, append `--with-chat` in step 4).

If host loopback ports `127.0.0.1:8080` (Caddy) or `127.0.0.1:2222` (SSH) are already in use, edit `microvm.forwardPorts` in [modules/microvm-guest.nix](modules/microvm-guest.nix) and substitute your ports in steps 7–8.
If you run multiple microVMs from this repo, also regenerate `microvm.machineId` in [modules/microvm-guest.nix](modules/microvm-guest.nix) with `systemd-id128 --uuid new`.

## 2. Create the Private State Directory and Guest SSH Host Key

Keep VM state **outside** any git work tree (a `path:` flake ref copies untracked files inside a repo into the world-readable `/nix/store`):

```bash
STATE_DIR=~/.local/state/mindroom-microvm
(
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

Add BOTH your operator SSH public key and the guest host public key printed in step 2 (`$STATE_DIR/ssh/ssh_host_ed25519_key.pub`) to the recipient lists in both files:

- [secrets/shared/secrets.nix](secrets/shared/secrets.nix)
- [hosts/mindroom/secrets/secrets.nix](hosts/mindroom/secrets/secrets.nix)

The repo ships empty recipient arrays and placeholder `.age` files; the bootstrap script refuses to run until recipients are configured.

## 4. Bootstrap Secrets

Run from `$REPO`. Put your LLM provider key(s) in a `0700` tmpfs directory, encrypt all secrets non-interactively with the repo-pinned `ragenix`, and delete the plaintext directory immediately afterwards:

```bash
cd "$REPO"
install -d -m 700 /dev/shm/mindroom-secrets
cat > /dev/shm/mindroom-secrets/agent-integrations.env <<'EOF'
OPENAI_API_KEY=sk-...
EOF
nix shell .#ragenix -c ./scripts/bootstrap-secrets.sh --non-interactive --values-dir /dev/shm/mindroom-secrets
rm -rf /dev/shm/mindroom-secrets
```

**Runtime toggle (`chat.enable = true`):** also provide `/dev/shm/mindroom-secrets/chat-runtime.env` and append `--with-chat` to the `bootstrap-secrets.sh` command above.

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
- Re-runs keep existing `.age` files and verify their recipients match `secrets.nix`; if a prior attempt encrypted files to stale recipients, delete the listed `.age` files and re-run.

## 5. Preflight Check and Build the GC-Rooted Runner

Verify flake evaluation (eval-only, catches Nix errors and missing SSH key warnings) and build the runner with `--out-link runner` inside `$STATE_DIR` so host Nix garbage collection cannot remove store paths the live guest mounts over 9p:

```bash
cd "$REPO"
nix flake check

cd "$STATE_DIR"
nix build --out-link runner "$REPO"
```

Expect `all checks passed!` (a `warning: Git tree ... is dirty` message is expected after steps 1–4; go back to step 1 if Nix warns that no SSH authorized keys are configured) and a `$STATE_DIR/runner` symlink pointing into `/nix/store`.
(`"$REPO"` selects `packages.x86_64-linux.default`, which is identical to `"$REPO#mindroom-microvm"`.)

## 6. Start the MicroVM

Run from `$STATE_DIR` (inside `tmux` or a dedicated terminal, as QEMU runs in the foreground with the serial console attached):

```bash
cd "$STATE_DIR"
./runner/bin/microvm-run
```

`microvm-run` refuses to start inside a git work tree, enforces `chmod 0700 .` and `umask 077`, and creates `0600` sparse ext4 images (`var.img`, `srv.img`, `nix-store.img`) plus `control.sock` in `$STATE_DIR`.
SSH comes up in ~30–40 seconds; first-boot git checkouts, the MindRoom Chat web UI build, and `mindroom-lab` `uv` environment install take ~2 minutes on a fast connection.

## 7. Verify Services and Endpoints

From another terminal on the host (adjust `STATE_DIR`, `2222`/`8080`, or the runtime unit list if you changed `forwardPorts` or the runtime toggles):

```bash
STATE_DIR=~/.local/state/mindroom-microvm
install -d -m 700 ~/.ssh
line="[127.0.0.1]:2222 $(cat "$STATE_DIR/ssh/ssh_host_ed25519_key.pub")"
grep -qxF "$line" ~/.ssh/known_hosts 2>/dev/null || echo "$line" >> ~/.ssh/known_hosts

# Wait for SSH and all first-boot services (checkouts + UI build + mindroom-lab uv install)
timeout 600 bash -c 'until ssh -n -o BatchMode=yes -p 2222 mindroom@127.0.0.1 \
  "systemctl is-active -q tuwunel && systemctl is-active -q caddy && systemctl is-active -q mindroom-cinny && systemctl is-active -q mindroom-lab" 2>/dev/null \
  && curl -sf -H "Host: chat.lab.mindroom.chat" http://127.0.0.1:8080/ >/dev/null; do sleep 10; done'

ssh -o BatchMode=yes -p 2222 mindroom@127.0.0.1 'systemctl --failed --no-pager && systemctl is-active tuwunel caddy mindroom-cinny mindroom-lab'
printf '%.200s\n' "$(curl -fsS -H 'Host: mindroom.lab.mindroom.chat' http://127.0.0.1:8080/_matrix/client/versions)"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: chat.lab.mindroom.chat' http://127.0.0.1:8080/
```

Expect:

- `0 loaded units listed.`
- Four `active` lines (`tuwunel`, `caddy`, `mindroom-cinny`, `mindroom-lab`)
- Matrix version JSON (`{"versions":[...]}`)
- `200`

Inspect logs or retry a transient network failure if any unit fails:

```bash
ssh -o BatchMode=yes -p 2222 mindroom@127.0.0.1 'journalctl -u mindroom-lab -u mindroom-cinny-build -u tuwunel -n 100 --no-pager'
ssh -o BatchMode=yes -p 2222 mindroom@127.0.0.1 'sudo systemctl restart git-checkout-cinny.service mindroom-cinny-build.service mindroom-cinny.service'
```

## 8. Register a Local Lab User and Verify an Agent Reply

`mindroom-lab` registers its agents (`@mindroom_user`, `@mindroom_router`, `@mindroom_mind`) on local Tuwunel and starts with a placeholder `__MINDROOM_OWNER_USER_ID_FROM_PAIRING__` in `/var/lib/mindroom/lab/config.yaml`.
Register a local user, bind it as the lab owner, accept the `personal` room invite, and verify a live reply from `@mindroom_mind` (requires a valid LLM provider key from step 4):

```bash
ssh -o BatchMode=yes -p 2222 mindroom@127.0.0.1 bash -s <<'EOF'
set -euo pipefail
USER_LOCALPART="you"
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
EXPECTED_ID="@${USER_LOCALPART}:mindroom.lab.mindroom.chat"
if [ "$USER_ID" != "$EXPECTED_ID" ] || [ -z "$ACCESS_TOKEN" ]; then
  echo "Registration failed (got '${USER_ID:-<empty>}')" >&2
  exit 1
fi
(umask 077 && printf '%s\n' "$PASSWORD" > "$HOME/.lab-user-password")
unset PASSWORD
printf 'Registered %s (password saved in ~/.lab-user-password, mode 0600)\n' "$USER_ID"

# YAML requires quotes around a leading '@'.
sed -i "s|__MINDROOM_OWNER_USER_ID_FROM_PAIRING__|\"$USER_ID\"|g" /var/lib/mindroom/lab/config.yaml
sudo systemctl restart mindroom-lab

# Wait for the invite to the personal room, join it, and send a test prompt.
ROOM_ID=""
for _ in $(seq 1 60); do
  ROOM_ID=$(curl -sS -H "Authorization: Bearer $ACCESS_TOKEN" \
    'http://127.0.0.1:8008/_matrix/client/v3/sync?timeout=2000' | \
    jq -r '
      ((.rooms.invite // {}) | to_entries | map(select(any(.value.invite_state.events[]?; .type == "m.room.name" and (.content.name // "" | ascii_downcase) == "personal"))) | .[0].key)
      // ((.rooms.invite // {}) | keys[0])
      // ((.rooms.join // {}) | keys[0])
      // empty
    ')
  [ -n "$ROOM_ID" ] && break
  sleep 2
done
[ -n "$ROOM_ID" ] || { echo "Timed out waiting for room invite" >&2; exit 1; }

ENC_ROOM=$(jq -rn --arg r "$ROOM_ID" '$r|@uri')
curl -sfS -X POST -H "Authorization: Bearer $ACCESS_TOKEN" -H 'Content-Type: application/json' \
  -d '{}' "http://127.0.0.1:8008/_matrix/client/v3/join/$ENC_ROOM" >/dev/null
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
- Nothing inside this VM terminates TLS. Put a TLS-terminating reverse proxy in front (see [README.md](README.md#tls-model)), or edit [hosts/mindroom/caddy.nix](hosts/mindroom/caddy.nix).

## 9. Stop, Reboot, and Update

Shut down cleanly so the ext4 volumes (`var.img`, `srv.img`, `nix-store.img`) unmount cleanly:

```bash
STATE_DIR=~/.local/state/mindroom-microvm
cd "$STATE_DIR"
./runner/bin/microvm-shutdown
```

Re-running `./runner/bin/microvm-run` from `$STATE_DIR` reuses all persistent volumes: SSH host key, git checkouts, built MindRoom Chat UI (no rebuild on second boot), Tuwunel database/accounts, guest-installed Nix store paths and DB, and multi-boot journals survive intact.

Pinned versions live in [hosts/mindroom/constants.nix](hosts/mindroom/constants.nix) (bumped daily by `.github/workflows/update-pins.yml`, or locally via `./scripts/update-pins.sh`).
To apply updates:

```bash
REPO=/abs/path/to/microvm-nixos
STATE_DIR=~/.local/state/mindroom-microvm
git -C "$REPO" pull
cd "$STATE_DIR"
./runner/bin/microvm-shutdown
nix build --out-link runner "$REPO"
./runner/bin/microvm-run
```

Checkouts with uncommitted local changes are never touched by updates.
