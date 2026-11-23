{ config, ... }:
let
  constants = import ./constants.nix;
in
{
  services.git-repo-checkouts = {
    enable = true;
    repositories.cinny = {
      path = "/var/www/cinny";
      url = "https://github.com/mindroom-ai/mindroom-chat.git";
      branch = "main";
      rev = constants.cinnyRev;
      user = config.mindroom.runtime.user;
      group = config.mindroom.runtime.group;
    };
  };

}
