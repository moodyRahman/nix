{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.deployment.alloy;

  nomadLogTargets = "/run/alloy-nomad-log-targets.json";

  textfileDir = "/var/lib/alloy-textfile";
  generationMetricFile = "${textfileDir}/nixos_generation.prom";

  # Export the active NixOS system generation number for the textfile
  # collector. Reads the profile symlinks directly, so no root is needed.
  generationMetric = pkgs.writeShellScript "alloy-nixos-generation" ''
    set -euo pipefail

    profiles=/nix/var/nix/profiles
    gen_of() {
      ${pkgs.gnused}/bin/sed -E 's/^system-([0-9]+)-link$/\1/' <<< "$(${pkgs.coreutils}/bin/basename "$1")"
    }

    # Prefer the generation matching the running system; fall back to the
    # profile's current link (e.g. after a `switch-to-configuration test`).
    current="$(${pkgs.coreutils}/bin/readlink -f /run/current-system)"
    generation=""
    for link in $profiles/system-*-link; do
      if [ "$(${pkgs.coreutils}/bin/readlink -f "$link")" = "$current" ]; then
        generation="$(gen_of "$link")"
      fi
    done
    if [ -z "$generation" ]; then
      generation="$(gen_of "$(${pkgs.coreutils}/bin/readlink $profiles/system)")"
    fi

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

  # Build Alloy file targets from Nomad allocation metadata. Only allocations
  # that still exist on this worker are included.
  nomadLogMetadata = pkgs.writeShellScript "alloy-nomad-log-metadata" ''
    set -euo pipefail

    token="$(cat ${config.sops.secrets."orchestration/nomad/alloy-observability-token".path})"

    # Get allocation IDs that have log directories on this worker.
    local_ids="$(
      ${pkgs.findutils}/bin/find /var/lib/nomad/alloc \
        -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        | ${pkgs.jq}/bin/jq -Rsc 'split("\n") | map(select(length > 0))'
    )"

    # Write to a temporary file first so Alloy never reads a partially written file.
    tmp="$(${pkgs.coreutils}/bin/mktemp ${nomadLogTargets}.XXXXXX)"
    trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT

    # While nomad.service (re)starts, e.g. mid `deploy-apply`, its API first refuses
    # connections, then answers 5xx until it reaches the servers. Both are transient:
    # keep the previous targets and let the next 10s tick retry, instead of failing
    # the unit (which fails the whole activation). Anything else (401/403: bad token) fails.
    rc=0
    resp="$(
      printf 'header = "X-Nomad-Token: %s"\n' "$token" \
        | ${pkgs.curl}/bin/curl -sS --max-time 10 --config - -w '\n%{http_code}' \
            http://127.0.0.1:4646/v1/allocations
    )" || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "Nomad API not reachable (curl exit $rc); keeping previous targets" >&2
      exit 0
    fi
    status="''${resp##*$'\n'}"
    allocs="''${resp%$'\n'*}"
    case "$status" in
      200) ;;
      5??)
        echo "Nomad API not ready (HTTP $status); keeping previous targets" >&2
        exit 0
        ;;
      *)
        echo "Nomad API returned HTTP $status: $allocs" >&2
        exit 1
        ;;
    esac

    # Match local allocation IDs with Nomad job metadata and build Alloy targets.
    printf '%s' "$allocs" \
      | ${pkgs.jq}/bin/jq \
          --arg node "${config.networking.hostName}" \
          --argjson local_ids "$local_ids" '
            [
              .[]
              | . as $alloc
              | select($local_ids | index($alloc.ID))
              | {
                  targets: ["localhost"],
                  labels: {
                    "__path__": ("/var/lib/nomad/alloc/" + $alloc.ID + "/alloc/logs/*"),
                    "job": "nomad",
                    "node": $node,
                    "service_name": $alloc.JobID,
                    "nomad_job": $alloc.JobID,
                    "nomad_group": $alloc.TaskGroup
                  }
                }
            ]
          ' > "$tmp"

    ${pkgs.coreutils}/bin/chown root:alloy "$tmp"
    ${pkgs.coreutils}/bin/chmod 0640 "$tmp"
    ${pkgs.coreutils}/bin/mv "$tmp" ${nomadLogTargets}
  '';

  # Nomad metrics are scraped locally so the central metrics backend
  # does not need to reach each node's Nomad HTTP port directly.
  nomadConfig = lib.optionalString cfg.scrapeNomad ''
    prometheus.scrape "nomad" {
      targets = [
        {
          "__address__" = "127.0.0.1:4646",
          "instance" = "${config.networking.hostName}",
        },
      ]

      forward_to = [prometheus.remote_write.mimir.receiver]
      job_name = "nomad"
      scrape_interval = "15s"
      metrics_path = "/v1/metrics"
      params = {
        "format" = ["prometheus"],
      }
    }
  '';

  # Garage metrics are scraped locally because the Garage admin API
  # only listens on loopback.
  garageConfig = lib.optionalString cfg.scrapeGarage ''
    prometheus.scrape "garage" {
      targets = [
        {
          "__address__" = "127.0.0.1:3903",
          "instance" = "${config.networking.hostName}",
          "garage_zone" = "${cfg.garageZone}",
        },
      ]

      forward_to = [prometheus.remote_write.mimir.receiver]
      job_name = "garage"
      scrape_interval = "15s"
      metrics_path = "/metrics"
    }
  '';

  nomadLogConfig = lib.optionalString cfg.collectNomadLogs ''
    // Load Nomad allocation paths enriched with job metadata.
    discovery.file "nomad_logs" {
      files = ["${nomadLogTargets}"]
      refresh_interval = "10s"
    }

    // Read Nomad task stdout/stderr logs using the enriched targets.
    loki.source.file "nomad" {
      targets = discovery.file.nomad_logs.targets
      forward_to = [loki.write.loki.receiver]
      tail_from_end = true

      file_match {
        enabled = true
        sync_period = "10s"
      }
    }
  '';

  systemLogConfig = lib.optionalString cfg.collectSystemLogs ''
    // Keep useful systemd journal fields as Loki labels.
    loki.relabel "system" {
      forward_to = []

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label = "unit"
      }

      rule {
        source_labels = ["__journal_priority_keyword"]
        target_label = "level"
      }
    }

    // Read system logs from the local systemd journal.
    loki.source.journal "system" {
      labels = {
        "node" = "${config.networking.hostName}",
      }

      relabel_rules = loki.relabel.system.rules
      forward_to = [loki.write.loki.receiver]
    }
  '';

in
{
  options.deployment.alloy = {
    enable = lib.mkEnableOption "host-level Grafana Alloy observability";

    remoteWriteUrl = lib.mkOption {
      type = lib.types.str;
      description = "Mimir remote-write endpoint Alloy sends metrics to.";
    };

    lokiWriteUrl = lib.mkOption {
      type = lib.types.str;
      description = "Loki push endpoint Alloy sends logs to.";
    };

    scrapeNomad = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Scrape the local Nomad Prometheus metrics endpoint.";
    };

    scrapeGarage = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Scrape the local Garage Prometheus metrics endpoint.";
    };

    garageZone = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Garage zone assigned to this storage node.";
    };

    collectNomadLogs = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Collect local Nomad allocation logs and forward them to Loki.";
    };

    collectSystemLogs = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Collect local systemd journal logs and forward them to Loki.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.defaultSopsFile = lib.mkDefault ../../secrets/deployment.yaml;

    # Read-only Nomad ACL token used to enrich allocation logs with job metadata.
    sops.secrets."orchestration/nomad/alloy-observability-token" = lib.mkIf cfg.collectNomadLogs { };

    # Refresh regularly so new Nomad allocations are picked up automatically.
    systemd.timers.alloy-nomad-log-metadata = lib.mkIf cfg.collectNomadLogs {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10s";
        OnUnitActiveSec = "10s";
      };
    };

    systemd.services.alloy-nomad-log-metadata = lib.mkIf cfg.collectNomadLogs {
      description = "Refresh Alloy Nomad log metadata";
      after = [ "nomad.service" ];
      wants = [ "nomad.service" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = nomadLogMetadata;
      };
    };

    # Alloy needs permission to see the Nomad allocation folders so it can find
    # and read the task log files inside them.
    systemd.tmpfiles.rules = [
      "d ${textfileDir} 0755 root root -"
    ]
    ++ lib.optionals cfg.collectNomadLogs [
      "a+ /var/lib/nomad/alloc - - - - u:alloy:rx"
      "f ${nomadLogTargets} 0640 root alloy - []"
    ];
    services.alloy = {
      enable = true;
      extraFlags = [ "--disable-reporting" ];
    };

    environment.etc."alloy/config.alloy".text = ''
      // Forward locally collected metrics to Mimir.
      prometheus.remote_write "mimir" {
        endpoint {
          url = "${cfg.remoteWriteUrl}"
        }
      }

      // Collect host CPU, memory, network, and filesystem metrics.
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

      ${nomadConfig}

      ${garageConfig}

      ${nomadLogConfig}

      ${systemLogConfig}

      // Send collected logs to Loki.
      loki.write "loki" {
        endpoint {
          url = "${cfg.lokiWriteUrl}"
        }
      }
    '';
  };
}
