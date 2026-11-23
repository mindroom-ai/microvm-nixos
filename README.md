# MindRoom NixOS MicroVM

<picture>
  <source media="(prefers-reduced-motion: no-preference)" srcset="https://raw.githubusercontent.com/mindroom-ai/mindroom/main/assets/logo/logo-mark-animated.svg" />
  <img src="https://raw.githubusercontent.com/mindroom-ai/mindroom/main/assets/logo/logo-mark.svg" alt="MindRoom Logo" align="right" width="120" />
</picture>

Standalone NixOS flake that runs the full MindRoom stack (local Matrix homeserver, MindRoom Chat web UI, Caddy, and MindRoom AI agents) inside a QEMU microVM via `microvm.nix`.

Looking for an Incus LXC container instead? See [mindroom-ai/lxc-nixos](https://github.com/mindroom-ai/lxc-nixos).

## Deploy

Follow [AGENTS.md](AGENTS.md) for the exact copy-paste commands:

1. Clone this repo and add your SSH public key to [hosts/mindroom/default.nix](hosts/mindroom/default.nix).
2. Create a private state directory outside the repo and generate the VM's SSH host key.
3. Add both SSH keys to `secrets.nix`, then run `./scripts/bootstrap-secrets.sh` with your LLM API key.
4. Build the runner (`nix build --out-link runner "$REPO"`) and start the VM.
5. Register your Matrix user and message `@mindroom_mind`.

## What runs

| Service | Role | Port |
| --- | --- | --- |
| `tuwunel` | Local Matrix homeserver | `127.0.0.1:8008` |
| `caddy` | HTTP reverse proxy | `80` (forwarded from host `127.0.0.1:8080`) |
| `mindroom-cinny` | MindRoom Chat web UI (built in-guest) | `8090` (proxied by Caddy) |
| `mindroom-lab` | MindRoom agents on local Tuwunel (default on) | `127.0.0.1:8765` |
| `mindroom-chat` | MindRoom agents on hosted `mindroom.chat` (default off) | `127.0.0.1:8766` |
| `git-checkout-*` | Keeps MindRoom and MindRoom Chat at pinned commits | — |

The VM runs on QEMU (4 vCPU, 8 GiB RAM) with persistent `/var`, `/srv`, and a writable Nix store overlay, plus Docker, Incus, distrobox, and CLI dev tools. Toggle `lab` or `chat` in [hosts/mindroom/default.nix](hosts/mindroom/default.nix).

## Who has root

**Agents have full root inside the microVM by design.**
The MindRoom runtime runs as the `mindroom` operator account with passwordless `sudo`, Docker, and Incus access, and `/run/wrappers/bin` on its `PATH` so the agent's shell tool can run `sudo` directly.
Treat the VM as the security boundary and as expendable; keep anything agents must not touch outside it.

## Your setup is in git

On first boot, `mindroom-lab` runs `mindroom config init --no-input --matrix-server self-hosted --provider openai` (reading `MINDROOM_OWNER_USER_ID` from `lab-runtime.env.age`), turns `/var/lib/mindroom/lab` into a Git repository, and commits the generated `config.yaml` and agent workspace.
Secrets, `.env`, `.venv/`, databases, logs, and other runtime state under `mindroom_data/` are excluded by `.gitignore`, and `agenix` (`/run/agenix/*`) is the single source of runtime environment variables.
The agent's workspace `AGENTS.md` instructs it to commit every setup change with a clear message and never commit secrets.
The NixOS flake itself lives on the host, so the agent cannot rebuild the VM from inside.

## Security

- **TLS proxy required:** Caddy serves plain HTTP on port 80 only (forwarded from host loopback `127.0.0.1:8080`; SSH is on `127.0.0.1:2222`), while Matrix `.well-known` advertises `https://`. Put a TLS-terminating reverse proxy in front before exposing it.
- **Host loopback (`10.0.2.2`):** Default QEMU user networking lets the guest reach services bound to the host's `127.0.0.1` via `10.0.2.2`.
- **Shared host Nix store:** The default 9p `ro-store` share exposes the host's entire `/nix/store` read-only to the guest.
- **Hardening:** Only use the defaults on a host without sensitive loopback services or secrets in `/nix/store`. See [AGENTS.md](AGENTS.md#hardening-optional) for switching to `storeOnDisk` and `tap` networking.

## Updates

Tuwunel, MindRoom, and MindRoom Chat versions are pinned in [hosts/mindroom/constants.nix](hosts/mindroom/constants.nix) and bumped daily by CI (or locally via `./scripts/update-pins.sh`).
To update, run `git pull`, shut down the VM, rebuild the runner, and start it again (see [AGENTS.md](AGENTS.md#9-stop-reboot-and-update)). Clean checkouts advance to the new pins; checkouts with local changes are left untouched.

## Layout

- `AGENTS.md` — full step-by-step deployment runbook
- `flake.nix` — NixOS system, microVM runner, `ragenix` CLI, and eval check
- `hosts/mindroom/` — pins/domains (`constants.nix`), SSH keys & runtime toggles (`default.nix`), service configs
- `modules/` — microVM guest glue (`microvm-guest.nix`), base system, checkouts, agent runtimes, secrets
- `secrets/` + `hosts/mindroom/secrets/` — encrypted secrets and recipient lists (placeholders only)
- `templates/` + `scripts/` — secret templates, `bootstrap-secrets.sh`, `update-pins.sh`
