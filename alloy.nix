{ config, pkgs, ... }:

let
  textfileDir = "/var/lib/nixos-generation";
  hostname = config.networking.hostName;

  # Parses `nix-env --list-generations` and writes the "(current)" generation
  # number as a prometheus textfile metric.
  generationScript = pkgs.writeShellScript "nixos-generation-metric" ''
    set -euo pipefail
    gen=$(${config.nix.package}/bin/nix-env -p /nix/var/nix/profiles/system --list-generations \
      | ${pkgs.gawk}/bin/awk '/\(current\)/ { print $1 }')
    tmp=$(mktemp -p ${textfileDir} .gen.XXXXXX)
    cat > "$tmp" <<METRIC
    # HELP nixos_current_generation Currently active NixOS system generation number.
    # TYPE nixos_current_generation gauge
    nixos_current_generation{host="${hostname}"} $gen
    METRIC
    chmod 644 "$tmp"
    mv "$tmp" ${textfileDir}/nixos_generation.prom
  '';
in
{
  systemd.tmpfiles.rules = [ "d ${textfileDir} 0755 root root -" ];

  systemd.services.nixos-generation-metric = {
    description = "Export current NixOS generation as a prometheus textfile";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = generationScript;
    };
  };

  systemd.timers.nixos-generation-metric = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10s";
      OnUnitActiveSec = "1min";
    };
  };

  services.alloy = {
    enable = true;
    # Reachable only over tailscale0 (trusted interface); the firewall blocks it elsewhere.
    extraFlags = [ "--server.http.listen-addr=0.0.0.0:12345" ];
  };

  # Alloy's embedded unix exporter is node_exporter: default collectors plus
  # textfile (for the generation metric). Its metrics are served for pulling at
  # http://<host>:12345/api/v0/component/prometheus.exporter.unix.node/metrics
  environment.etc."alloy/config.alloy".text = ''
    prometheus.exporter.unix "node" {
      enable_collectors = ["textfile"]
      textfile {
        directory = "${textfileDir}"
      }
    }
  '';
}
