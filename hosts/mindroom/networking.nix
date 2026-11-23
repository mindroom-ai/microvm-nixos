_:

{
  networking = {
    hostName = "mindroom";
    nftables.enable = true;
    firewall.enable = true;
    # Caddy binds port 80 only (TLS terminates at an external reverse proxy).
    firewall.allowedTCPPorts = [ 80 ];
  };
}
