{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.git-repo-checkouts;
in
{
  options.services.git-repo-checkouts = {
    enable = lib.mkEnableOption "managed Git checkouts for runtime repositories";

    repositories = lib.mkOption {
      default = { };
      description = "Named runtime Git checkouts that should exist on the host.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption {
              type = lib.types.str;
              description = "Absolute path for the checkout.";
            };

            url = lib.mkOption {
              type = lib.types.str;
              description = "Git remote URL.";
            };

            branch = lib.mkOption {
              type = lib.types.str;
              description = "Branch to fetch when updating the checkout.";
            };

            rev = lib.mkOption {
              type = lib.types.str;
              description = ''
                Commit to pin the checkout to. When the working tree is clean,
                the service checks out this commit (detached HEAD); dirty
                working trees are left untouched.
              '';
            };

            user = lib.mkOption {
              type = lib.types.str;
              default = "root";
              description = "Service user used for clone, fetch, and checkout.";
            };

            group = lib.mkOption {
              type = lib.types.str;
              default = "root";
              description = "Service group used for clone, fetch, and checkout.";
            };

            dirMode = lib.mkOption {
              type = lib.types.str;
              default = "0755";
              description = "Mode for the checkout directory created via tmpfiles.";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = lib.mapAttrsToList (
      _name: repo: "d ${repo.path} ${repo.dirMode} ${repo.user} ${repo.group} -"
    ) cfg.repositories;

    systemd.services = lib.mapAttrs' (
      name: repo:
      lib.nameValuePair "git-checkout-${name}" {
        description = "Ensure runtime git checkout: ${name}";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        path = with pkgs; [
          bash
          coreutils
          git
          git-lfs
          openssh
        ];
        serviceConfig = {
          Type = "oneshot";
          # Stay "active (exited)" after success so dependent services see the
          # checkout unit as active.
          RemainAfterExit = true;
          User = repo.user;
          Group = repo.group;
          Restart = "on-failure";
          RestartSec = "10s";
        };
        script = ''
          set -euo pipefail

          repo_path=${lib.escapeShellArg repo.path}
          repo_url=${lib.escapeShellArg repo.url}
          repo_branch=${lib.escapeShellArg repo.branch}
          repo_rev=${lib.escapeShellArg repo.rev}

          # Make sure the pinned commit exists locally; a rev can be ahead of
          # the last fetched branch tip (GitHub allows fetching bare commits).
          ensure_rev_present() {
            if ! git -C "$repo_path" rev-parse --verify --quiet "$repo_rev^{commit}" >/dev/null; then
              git -C "$repo_path" fetch origin "$repo_rev"
            fi
          }

          if [ ! -d "$repo_path/.git" ]; then
            if [ -d "$repo_path" ] && [ -n "$(ls -A "$repo_path")" ]; then
              echo "Refusing to clone into non-empty non-git directory: $repo_path" >&2
              exit 1
            fi
            mkdir -p "$repo_path"
            git clone --origin origin --branch "$repo_branch" "$repo_url" "$repo_path"
            ensure_rev_present
            git -C "$repo_path" checkout --detach "$repo_rev"
            exit 0
          fi

          git -C "$repo_path" remote set-url origin "$repo_url"
          git -C "$repo_path" fetch --prune origin "$repo_branch"

          if [ -n "$(git -C "$repo_path" status --porcelain)" ]; then
            echo "Working tree has local changes; leaving $repo_path untouched."
            exit 0
          fi

          ensure_rev_present
          if [ "$(git -C "$repo_path" rev-parse HEAD)" = "$(git -C "$repo_path" rev-parse "$repo_rev^{commit}")" ]; then
            exit 0
          fi

          echo "Checking out pinned revision $repo_rev in $repo_path."
          git -C "$repo_path" checkout --detach "$repo_rev"
        '';
      }
    ) cfg.repositories;
  };
}
