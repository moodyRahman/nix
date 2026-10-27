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

  services.alloy.enable = true;

  # Only the textfile collector is enabled, so the exporter emits just the
  # generation metric (no node_* noise).
  environment.etc."alloy/config.alloy".text = ''
    prometheus.exporter.unix "generation" {
      set_collectors = ["textfile"]
      textfile {
        directory = "${textfileDir}"
      }
    }

    prometheus.scrape "generation" {
      targets    = prometheus.exporter.unix.generation.targets
      forward_to = [prometheus.remote_write.default.receiver]
    }

    prometheus.remote_write "default" {
      endpoint {
        // TODO: point at your Prometheus/Mimir/Grafana Cloud endpoint
        url = "http://localhost:9090/api/v1/write"
      }
    }
  '';
}
