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
  tuwunelVersion = "v2.0.0-mindroom.11";
  tuwunelArchiveHash = "sha256-NHtgJhn8YXk6lAvKYs4ZXN+j32cxCa0aaKeJtT7UXv4=";

  # Pinned commits for the runtime git checkouts. All pins in this file are
  # bumped daily by .github/workflows/update-pins.yml; to bump by hand run
  # scripts/update-pins.sh and rebuild.
  mindroomRev = "54cac35267cda51bc7568a4eafe571aa0ea939ec";
  mindroomChatRev = "9d824c68c3d776e195fe804986868063c0e8a08e";
}
