{
  config,
  lib,
  pkgs,
  ...
}:
let
  textfileDir = "/var/lib/alloy-textfile";
  generationMetricFile = "${textfileDir}/nixos_generation.prom";

  # Export the active NixOS system generation number for the textfile collector.
  # -1 means no generation link matches the running system.
  generationMetric = pkgs.writeShellScript "alloy-nixos-generation" ''
    set -euo pipefail

    profiles=/nix/var/nix/profiles
    current="$(${pkgs.coreutils}/bin/readlink -f /run/current-system)"

    generation=-1
    for link in $profiles/system-*-link; do
      [ -e "$link" ] || continue
      if [ "$(${pkgs.coreutils}/bin/readlink -f "$link")" = "$current" ]; then
        n="''${link##*/system-}"
        n="''${n%-link}"
        if [ "$n" -gt "$generation" ]; then
          generation="$n"
        fi
      fi
    done

    # Write to a temporary file first so the collector never reads a partial file.
    tmp="$(${pkgs.coreutils}/bin/mktemp ${generationMetricFile}.XXXXXX)"
    trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT

    {
      echo '# HELP nixos_system_generation Active NixOS system generation number.'
      echo '# TYPE nixos_system_generation gauge'
      echo "nixos_system_generation{host=\"${config.networking.hostName}\"} $generation"
    } > "$tmp"

    ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
    ${pkgs.coreutils}/bin/mv "$tmp" ${generationMetricFile}
  '';
in
{
  options.deployment.alloy.remoteWriteUrl = lib.mkOption {
    type = lib.types.str;
    default = "http://127.0.0.1:9009/api/v1/push";
    description = "Mimir remote-write endpoint Alloy sends metrics to.";
  };

  config = {
    # The Alloy service.
    services.alloy = {
      enable = true;
      extraFlags = [ "--disable-reporting" ];
    };

    # Directory the script writes to and the textfile collector reads from.
    systemd.tmpfiles.rules = [ "d ${textfileDir} 0755 root root -" ];

    # Run the script at boot and then every minute.
    systemd.services.alloy-nixos-generation = {
      description = "Export active NixOS generation for the Alloy textfile collector";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = generationMetric;
      };
    };

    systemd.timers.alloy-nixos-generation = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10s";
        OnUnitActiveSec = "1m";
      };
    };

    # Export the textfile metrics through Alloy to Mimir.
    environment.etc."alloy/config.alloy".text = ''
      prometheus.remote_write "mimir" {
        endpoint {
          url = "${config.deployment.alloy.remoteWriteUrl}"
        }
      }

      prometheus.exporter.unix "host" {
        enable_collectors = ["textfile"]

        textfile {
          directory = "${textfileDir}"
        }
      }

      prometheus.scrape "host" {
        targets = prometheus.exporter.unix.host.targets
        forward_to = [prometheus.remote_write.mimir.receiver]
        job_name = "node"
        scrape_interval = "15s"
      }
    '';
  };
}
