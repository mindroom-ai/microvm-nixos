let
  # This microVM serves the lab Matrix/app domain. TLS is NOT terminated
  # here: an external reverse proxy (Traefik in the reference setup) owns the
  # public *.lab.mindroom.chat certificates and forwards plain HTTP to this
  # VM on port 80.
  siteDomain = "mindroom.lab.mindroom.chat";
in
{
  inherit siteDomain;
  publicBaseDomain = "lab.mindroom.chat";
  publicSiteDomain = siteDomain;
  publicChatDomain = "chat.lab.mindroom.chat";
  tuwunelVersion = "v2.0.0-mindroom.14";
  tuwunelArchiveHash = "sha256-JLeBQLeVFgFRVi4TL4I9GNg0d7TcxIrkxuv2SDIRjsc=";

  # Pinned commits for the runtime git checkouts. All pins in this file are
  # bumped daily by .github/workflows/update-pins.yml; to bump by hand run
  # scripts/update-pins.sh and rebuild.
  mindroomRev = "c1710890b7032d44b6d240a93cad7eef485c8a98";
  mindroomChatRev = "9f1b124f7e1262cee4997cb5341d92dddec3b355";
}
