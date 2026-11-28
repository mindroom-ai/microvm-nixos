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
  tuwunelVersion = "v2.1.0-mindroom.2";
  tuwunelArchiveHash = "sha256-NfXM/+yDu38AxX5gr5akZEvLKfzuW0Mul/n9uzkJi14=";

  # Pinned commits for the runtime git checkouts. All pins in this file are
  # bumped daily by .github/workflows/update-pins.yml; to bump by hand run
  # scripts/update-pins.sh and rebuild.
  mindroomRev = "bb99cb5e50b200e54116804ae7e77c0f2fc73ff6";
  mindroomChatRev = "ec1e01ad9db3f6ff79baebe9cf3d5abf95ce6dff";
}
