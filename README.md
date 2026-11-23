# MindRoom NixOS MicroVM

<picture>
  <source media="(prefers-reduced-motion: no-preference)" srcset="https://raw.githubusercontent.com/mindroom-ai/mindroom/main/assets/logo/logo-mark-animated.svg" />
  <img src="https://raw.githubusercontent.com/mindroom-ai/mindroom/main/assets/logo/logo-mark.svg" alt="MindRoom Logo" align="right" width="120" />
</picture>

Deploy a self-contained MindRoom stack — local Matrix homeserver, MindRoom Chat web UI, reverse proxy, and AI agent runtime — in a standalone QEMU microVM via `microvm.nix`.
Secrets are encrypted and managed with `agenix` and `ragenix`.

## Quick Start

**[AGENTS.md](AGENTS.md) is the setup runbook**, written for AI coding agents (or humans) to follow verbatim from clone to verified agent reply.

Paste this prompt into your coding agent:

```text
Follow https://github.com/mindroom-ai/microvm-nixos/blob/main/AGENTS.md to deploy MindRoom.
```

**What you need:**

- An `x86_64-linux` host with `/dev/kvm` and at least 8 GiB free RAM
- Nix with flakes enabled
- An SSH key pair for operator access and secret encryption
- An OpenAI API key (`OPENAI_API_KEY`) for the runbook as written (other providers can be added to `agent-integrations.env`)

## What's Included

| Service | What it does |
| --- | --- |
| `tuwunel` | Local Matrix homeserver (MindRoom's Tuwunel fork) |
| `caddy` | HTTP reverse proxy routing the public hostnames |
| `mindroom-cinny` | MindRoom Chat web UI, built inside the VM on first boot |
| `mindroom-lab` | MindRoom AI agent runtime for the local homeserver (default on) |
| `mindroom-chat` | MindRoom AI agent runtime for hosted `mindroom.chat` (default off) |
| `git-checkout-*` | Keeps the MindRoom and MindRoom Chat source checkouts at pinned commits |

The guest also includes Docker, Incus, distrobox, and CLI dev tools for the operator and agents.

## Two Runtimes: Lab vs. Chat

- **Lab (`mindroom.runtime.lab.enable`, default on):** Self-contained setup where agents register and chat on the local Tuwunel homeserver inside the VM.
- **Chat (`mindroom.runtime.chat.enable`, default off):** Connects agents to hosted `mindroom.chat`; requires pairing credentials.

## Good to Know

- **Security boundary:** The microVM is the sandbox — agents run as the operator user with full passwordless root (`sudo`) and Docker/Incus access inside it by design, so treat the VM as expendable. Default SLIRP networking and the read-only host `/nix/store` share have host-isolation caveats; see [Security Model and Hardening](AGENTS.md#security-model-and-hardening) for hardening options.
- **Version-controlled setup from `mindroom config init`:** First boot generates `config.yaml` directly from `mindroom config init --no-input --matrix-server self-hosted --provider openai` (filling the owner from `MINDROOM_OWNER_USER_ID`), initializes `/var/lib/mindroom/lab` (`config.yaml` and agent workspaces) as a Git repo with a deny-by-default `.gitignore`, and instructs the agent to commit every setup change.
- **HTTPS / TLS:** Caddy listens on plain HTTP port 80 only; put a TLS-terminating reverse proxy in front before exposing publicly (see [TLS Model](AGENTS.md#tls-model)).
- **Updates:** Pinned versions update daily via GitHub Actions; `git pull`, rebuilding the runner, and restarting applies them while leaving local checkout edits untouched (see [Version Pinning and Updates](AGENTS.md#version-pinning-and-updates)).
- **Looking for LXC instead?** See [mindroom-ai/lxc-nixos](https://github.com/mindroom-ai/lxc-nixos) to deploy the same stack in an Incus LXC container.

## Repository Layout

- `flake.nix` — NixOS flake for the microVM runner, system config, and pinned `ragenix`
- `hosts/mindroom/` — host configuration, version pins, runtime toggles, and per-service configs
- `modules/` — microVM guest wiring, base system, git checkouts, runtime services, secrets wiring, and dev tooling
- `secrets/` + `hosts/mindroom/secrets/` — encrypted secrets and recipient lists (placeholders only in git)
- `templates/` — plaintext templates used to seed secrets during bootstrap
- `scripts/` — `bootstrap-secrets.sh` and `update-pins.sh`
- [AGENTS.md](AGENTS.md) — step-by-step deployment runbook and full technical reference
