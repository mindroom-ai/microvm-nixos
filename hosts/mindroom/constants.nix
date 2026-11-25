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
  tuwunelVersion = "v2.0.0-mindroom.16";
  tuwunelArchiveHash = "sha256-wiI7+P6gMl8Uurs5K4EnWpvCcG/bzDdM9ORmInP01RY=";

  # Pinned commits for the runtime git checkouts. All pins in this file are
  # bumped daily by .github/workflows/update-pins.yml; to bump by hand run
  # scripts/update-pins.sh and rebuild.
  mindroomRev = "4ee07193dc0214472507628701816e6c21653408";
  mindroomChatRev = "715a11d0210a12e6fb1819f64da03feac07b3d22";
}
