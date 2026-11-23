{ config, ... }:
let
  constants = import ./constants.nix;
in
{
  services.git-repo-checkouts = {
    enable = true;
    repositories.mindroom-chat = {
      path = "/var/www/mindroom-chat";
      url = "https://github.com/mindroom-ai/mindroom-chat.git";
      branch = "main";
      rev = constants.mindroomChatRev;
      user = config.mindroom.runtime.user;
      group = config.mindroom.runtime.group;
    };
  };

}
