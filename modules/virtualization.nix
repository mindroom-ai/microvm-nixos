# Docker, Incus, and distrobox tooling inside the VM.
#
# libvirt/KVM is disabled by default so the guest does not require nested
# virtualization. If you enable nested KVM on the host and QEMU guest, add
# `virtualisation.libvirtd.enable = true;` in your host config.
{ pkgs, ... }:

{
  environment.systemPackages = [ pkgs.distrobox ];
  virtualisation.docker.enable = true;
  virtualisation.incus.enable = true;
}
