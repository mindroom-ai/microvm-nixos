# MindRoom NixOS MicroVM

<picture>
  <source media="(prefers-reduced-motion: no-preference)" srcset="https://raw.githubusercontent.com/mindroom-ai/mindroom/main/assets/logo/logo-mark-animated.svg" />
  <img src="https://raw.githubusercontent.com/mindroom-ai/mindroom/main/assets/logo/logo-mark.svg" alt="MindRoom Logo" align="right" width="120" />
</picture>

Standalone NixOS flake that runs the MindRoom stack as a QEMU microVM via `microvm.nix`: local Matrix homeserver, MindRoom Chat web client, Caddy reverse proxy, and the MindRoom AI agent runtime, with all secrets managed through `ragenix`.

For deploying the same stack as an Incus LXC container instead of a microVM, see [mindroom-ai/lxc-nixos](https://github.com/mindroom-ai/lxc-nixos).

**To deploy, follow [AGENTS.md](AGENTS.md)** — it is the canonical step-by-step runbook, written to be followed verbatim by a human or an agent.
This README explains what runs inside the VM, how it is configured, and its security model.

## What Runs Inside the MicroVM

| Service | Purpose | Port |
| --- | --- | --- |
| `tuwunel` | Local Matrix homeserver (MindRoom Tuwunel fork, pinned release binary) | 8008 (loopback) |
| `caddy` | HTTP reverse proxy / routing for the public hostnames | 80 |
| `mindroom-cinny` | MindRoom Chat web client (built in-guest on first boot) | 8090 (all interfaces; not open in the guest firewall) |
| `mindroom-lab` | MindRoom agent runtime — local homeserver (optional, default on) | 8765 (loopback; unauthenticated dashboard/API, not proxied) |
| `mindroom-chat` | MindRoom agent runtime — hosted mindroom.chat (optional, default off) | 8766 (loopback; proxied by Caddy when enabled) |
| `git-checkout-*` | Keep the MindRoom and MindRoom Chat checkouts at the pinned revisions | — |

The microVM is configured in [modules/microvm-guest.nix](modules/microvm-guest.nix) and ships Docker, Incus, distrobox, and a CLI/dev toolbox for the operator account and the agents:

- **Compute:** QEMU hypervisor, 4 vCPU, 8 GiB RAM (sized for the first-boot MindRoom Chat Vite build and `uv` installs alongside the tmpfs root).
- **Nix store:** Shares the host `/nix/store` read-only over 9p with an 8 GiB sparse ext4 writable overlay (`nix-store.img`, label `mindroom-rw`, mounting `/nix/.rw-store` and bind-mounting `/nix/.rw-store/var` onto `/nix/var/nix`) so `nix shell` / `nix develop` work inside the guest and guest-built store paths remain registered across reboots.
- **Persistent storage:** `/var` (20 GiB sparse ext4: Tuwunel DB, MindRoom state/venvs, MindRoom Chat checkout/build, journals, Docker/Incus) and `/srv` (4 GiB sparse ext4: MindRoom source checkout) live as `0600` images inside your private `0700` state directory outside the repo, with a pinned `microvm.machineId` so journals survive reboots.
- **Identity & secrets:** A pre-generated SSH host key in `$STATE_DIR/ssh` is mounted read-only early in boot (`neededForBoot = true`), so `agenix` decrypts secrets on first boot and `sshd` keeps a stable host identity across reboots without placing key material in the git checkout.
- **Networking:** QEMU user networking forwarding host loopback `127.0.0.1:8080 -> 80` (Caddy) and `127.0.0.1:2222 -> 22` (SSH).
- **Virtualization inside the VM:** Docker, Incus, and distrobox from [modules/virtualization.nix](modules/virtualization.nix) are enabled; nested KVM/libvirt is disabled by default (`virtualisation.libvirtd.enable = true` can be added if nested KVM is enabled on the host and QEMU guest).

### One Application, Two Runtimes

MindRoom runs as up to two independent instances of the same application, toggled in [hosts/mindroom/default.nix](hosts/mindroom/default.nix):

- **lab** (`mindroom.runtime.lab.enable`, default `true`): agents that register and log in on the **local Tuwunel homeserver inside this VM**, using the registration token created during secret bootstrap. Self-contained — this is the default.
- **chat** (`mindroom.runtime.chat.enable`, default `false`): agents that connect out to the **hosted mindroom.chat homeserver**. Requires pairing credentials (`MINDROOM_LOCAL_CLIENT_ID/SECRET`) in `chat-runtime.env.age`, so it is off by default.

Each enabled runtime gets its own state directory, `config.yaml`, `uv` environment, and encrypted env file; both share the two org-wide secret bundles (`agent-integrations`, `agent-tooling`). Secrets are only required for runtimes you enable.

## Security Model

The microVM is the security boundary, and everything inside it is deliberately trusted:
the agents run as the operator account, which has passwordless sudo and Docker access, so **agents have root inside the guest by design**.
Treat the VM as expendable, and do not put anything inside it that the agents must not touch.

- **Network exposure:** The guest firewall opens TCP 80 (Caddy), TCP 22 (SSH), and UDP 60000–61000 (mosh); Tuwunel and the runtime APIs listen on loopback. On the host, QEMU forwards only host loopback `127.0.0.1:8080 -> 80` and `127.0.0.1:2222 -> 22`.
- **Default host-isolation caveats:**
  - QEMU user (SLIRP) networking lets the guest reach the host's `127.0.0.1` loopback services via `10.0.2.2`.
  - The 9p `ro-store` share exposes the host's entire `/nix/store` to the guest.
  - Run the defaults only on a host without sensitive loopback-only services or secrets in `/nix/store`.
- **Hardening options:** To isolate the guest from host loopback services and the host `/nix/store`, switch to `microvm.storeOnDisk = true` (eliminating the 9p host store share; the writable overlay uses label `mindroom-rw` so it does not collide with `storeOnDisk`'s `nix-store` label) and `tap` networking (eliminating SLIRP `10.0.2.2` access) in [modules/microvm-guest.nix](modules/microvm-guest.nix).

### TLS Model

Caddy binds **port 80 only**.
In the reference setup an external reverse proxy (Traefik) owns the certificates for the public `*.lab.mindroom.chat` hostnames and forwards plain HTTP to this VM.
The well-known responses advertise `https://` URLs on that assumption.

If you have no TLS-terminating proxy in front, do not expose port 80 to the internet as-is.
Either put a TLS-terminating reverse proxy in front, or remove the `":80"` suffixes in [hosts/mindroom/caddy.nix](hosts/mindroom/caddy.nix) and open port 443 in [hosts/mindroom/networking.nix](hosts/mindroom/networking.nix) so Caddy provisions certificates itself.

## Version Pinning and Updates

Everything that runs is pinned in [hosts/mindroom/constants.nix](hosts/mindroom/constants.nix): the Tuwunel release (`tuwunelVersion` + `tuwunelArchiveHash`) and the exact commits of the MindRoom and MindRoom Chat checkouts (`mindroomRev`, `cinnyRev`).
The daily [update-pins](.github/workflows/update-pins.yml) GitHub workflow bumps all three to the latest upstream and pushes only after `nix flake check` passes; run [scripts/update-pins.sh](scripts/update-pins.sh) to do the same locally.

Applying an update is `git pull`, `./runner/bin/microvm-shutdown`, `nix build --out-link runner "$REPO"`, and `./runner/bin/microvm-run` (see [AGENTS.md](AGENTS.md#9-stop-reboot-and-update)).
Checkouts with uncommitted local changes are never touched by updates; clean checkouts move to the pinned commit, and a MindRoom Chat pin bump rebuilds the web UI on the next boot.

## Repository Layout

- `flake.nix` — single-target flake (`nixosConfigurations.mindroom`, `packages.x86_64-linux.{default,mindroom-microvm,ragenix}`, eval-only `checks.x86_64-linux.mindroom`)
- `hosts/mindroom/` — host composition: domains/pins (`constants.nix`), runtime toggles and SSH keys (`default.nix`), per-service config (`caddy.nix`, `cinny.nix`, `mindroom.nix`, `networking.nix`, `tuwunel.nix`)
- `modules/` — microVM guest glue (`microvm-guest.nix`), base system, git checkouts, runtime services, secrets wiring, Docker/Incus tooling
- `secrets/shared/` + `hosts/mindroom/secrets/` — encrypted secrets and their recipient lists (the repo ships placeholders only)
- `templates/` — plaintext templates that seed each secret during bootstrap
- `scripts/` — `bootstrap-secrets.sh` and `update-pins.sh`
- `AGENTS.md` — the deployment runbook

### Customization Points

- [hosts/mindroom/default.nix](hosts/mindroom/default.nix): runtime toggles, operator SSH keys, state paths
- [modules/microvm-guest.nix](modules/microvm-guest.nix): vCPU/RAM, forwarded host ports, volume sizes, `machineId`, `storeOnDisk`/`tap` hardening
- [hosts/mindroom/constants.nix](hosts/mindroom/constants.nix): public domains, Tuwunel release pin, and MindRoom/MindRoom Chat commit pins

Changing the public domains in `constants.nix` is not enough by itself: `MATRIX_SERVER_NAME` inside `lab-runtime.env.age` must match, and MindRoom Chat bakes its homeserver defaults into its own build, so a full domain change also needs a matching client-side change.

## What Was Verified

Verified end-to-end on 2026-11-23 by booting a fresh microVM from a scratch copy of this repository on an `x86_64-linux` NixOS host with `/dev/kvm`, following [AGENTS.md](AGENTS.md) verbatim (with `microvm.forwardPorts` adjusted to `18080`/`12222` because `8080`/`2222` were already bound on the test host):

- **Static & flake checks:** fresh `flake.lock` (`nixpkgs` `2786a2a7`, `microvm.nix` `430a46d0`), `nix flake check` (eval-only for `nixosConfigurations.mindroom` and `packages.x86_64-linux.{default,mindroom-microvm,ragenix}`), `nixfmt --check`, `shellcheck scripts/*.sh`, `scripts/update-pins.sh`, and `microvm.storeOnDisk = true` volume label distinctness (`mindroom-rw` vs `nix-store`)
- **State isolation & first-boot secrets:** git work-tree guards (step 2 and runner `preStart`) refused placing state inside the repo; `0700` state dir/`ssh/` and `0600` private key + `var.img`/`srv.img`/`nix-store.img`; non-interactive secret bootstrap via `nix shell .#ragenix -c ./scripts/bootstrap-secrets.sh --non-interactive --values-dir ...` with a live `OPENAI_API_KEY`; all 5 secrets decrypted by `agenix` on first boot under `/run/agenix/`
- **First boot & services:** `nix build --out-link runner "$REPO" && ./runner/bin/microvm-run` settled in 83s with `systemctl --failed` empty and `tuwunel` (`v2.0.0-mindroom.11`), `caddy`, `mindroom-cinny` (`9d824c68c3`), `mindroom-lab` (`54cac35267`), `docker`, `incus`, and `sshd` all `active`
- **Forwarded HTTP endpoints:** Matrix client versions JSON (`Host: mindroom.lab.mindroom.chat`) and MindRoom Chat web UI HTTP `200` (`Host: chat.lab.mindroom.chat`) through host loopback forward `127.0.0.1:18080`
- **Agents & live LLM reply:** `@mindroom_user`, `@mindroom_router`, and `@mindroom_mind` registered on local Tuwunel; verbatim step 8 registered `@you:mindroom.lab.mindroom.chat` (password stored `0600` in `~/.lab-user-password`), bound lab owner in `/var/lib/mindroom/lab/config.yaml`, joined `personal`, and received live reply `MICROVM-OK` from `@mindroom_mind`
- **Reboot persistence & guest Nix DB:** clean `./runner/bin/microvm-shutdown` + `./runner/bin/microvm-run` settled in 17s with the same SSH host key, `dist/index.html` unchanged (`mindroom-cinny-build` exited in 0.06s with no rebuild), checkouts and Tuwunel user/room history intact, `journalctl --list-boots` showing 2 boots with `/etc/machine-id` `b8689be6ba919b3566250f34607521a2`, and `nix path-info --offline` succeeding after reboot for a `nixpkgs#hello` store path built on boot 1

Not verified: the optional `chat` runtime against hosted `mindroom.chat`, an external TLS-terminating reverse proxy, and hardened `storeOnDisk`/`tap` boot (only `storeOnDisk` evaluation was checked).
