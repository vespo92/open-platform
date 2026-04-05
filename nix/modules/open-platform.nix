{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.open-platform;
  isServer = cfg.role == "server-init" || cfg.role == "server";
  isFirstServer = cfg.role == "server-init";
in
{
  options.services.open-platform = {
    enable = lib.mkEnableOption "Open Platform k3s deployment";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "Platform domain (e.g., open-platform.sh).";
    };

    role = lib.mkOption {
      type = lib.types.enum [
        "server-init"
        "server"
        "agent"
      ];
      default = "server-init";
      description = ''
        K3s cluster role:
        - server-init: First server node. Bootstraps embedded etcd with --cluster-init.
        - server: Additional server node. Joins existing cluster via serverAddr.
        - agent: Worker-only node. Joins existing cluster via serverAddr.
      '';
    };

    serverAddr = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://10.0.0.10:6443";
      description = "K3s server URL for joining an existing cluster. Required for 'server' and 'agent' roles.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/etc/k3s/token";
      description = "Path to file containing the k3s cluster token. Required for 'server' and 'agent' roles.";
    };

    installDir = lib.mkOption {
      type = lib.types.path;
      default = /opt/open-platform;
      description = "Directory containing the open-platform checkout.";
    };

    k3s = {
      disable = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "traefik" ] ++ lib.optionals (cfg.network.mode == "loadbalancer") [ "servicelb" ];
        description = "k3s components to disable. Traefik is managed by Helm. servicelb disabled when using MetalLB.";
      };

      clusterCidr = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "10.42.0.0/16";
        description = "Pod CIDR for the cluster. MUST be identical on all nodes. Set explicitly to avoid /24 vs /16 mismatch.";
      };

      serviceCidr = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "10.43.0.0/16";
        description = "Service CIDR for the cluster. MUST be identical on all nodes.";
      };

      nodeIp = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "10.0.0.10";
        description = "Advertised node IP. Set when node has multiple NICs to ensure flannel uses the correct interface.";
      };

      extraFlags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Additional k3s server/agent flags.";
      };

      oidc = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Enable OIDC flags for Headlamp authentication.
            Set this after first deploy once Forgejo is running and
            the Headlamp OIDC client ID is available.
          '';
        };

        clientId = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = ''
            Headlamp OIDC client ID. Retrieve after first deploy:
            kubectl get secret oidc -n headlamp -o jsonpath='{.data.OIDC_CLIENT_ID}' | base64 -d
          '';
        };

        caFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Path to CA cert for OIDC issuer verification (self-signed TLS only).";
        };
      };
    };

    network = {
      mode = lib.mkOption {
        type = lib.types.enum [
          "host"
          "loadbalancer"
        ];
        default = "host";
        description = "Traefik networking: 'host' (DaemonSet+hostNetwork) or 'loadbalancer' (MetalLB L2 VIP).";
      };

      edgeInterface = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "NIC for MetalLB L2 advertisements (e.g., eno3 for VLAN 101).";
      };
    };

    flannel = {
      externalIp = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Use --flannel-external-ip for cross-node networking over Tailscale.";
      };
    };

    tailscale = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable Tailscale for cross-node connectivity.";
      };
    };

    firewall = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Configure firewall rules for k3s and platform services.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [

    # --- Assertions ---
    {
      assertions = [
        {
          assertion = (cfg.role != "server" && cfg.role != "agent") || cfg.serverAddr != null;
          message = "services.open-platform.serverAddr is required when role is 'server' or 'agent'.";
        }
        {
          assertion = (cfg.role != "server" && cfg.role != "agent") || cfg.tokenFile != null;
          message = "services.open-platform.tokenFile is required when role is 'server' or 'agent'.";
        }
      ];
    }

    # --- Common config for all roles ---
    {
      # System packages
      environment.systemPackages = with pkgs; [
        kubectl
        kubernetes-helm
        helmfile
        git
        curl
        openssl
        jq
        gnused
        gawk
        bun
        gnumake
      ];

      # Docker
      virtualisation.docker.enable = true;

      # Tailscale
      services.tailscale.enable = lib.mkIf cfg.tailscale.enable true;

      # Firewall
      networking.firewall = lib.mkIf cfg.firewall.enable {
        enable = true;
        allowedTCPPorts =
          [ 6443 ] # k3s API server (all nodes need this for agent → server)
          ++ lib.optionals isServer [
            2379 # etcd client
            2380 # etcd peer
          ]
          ++ lib.optionals (isServer || cfg.network.mode == "host") [
            80 # HTTP (Traefik hostNetwork)
            443 # HTTPS (Traefik hostNetwork)
          ];
        allowedUDPPorts = [
          8472 # Flannel VXLAN
        ];
        trustedInterfaces = [
          "cni0"
          "flannel.1"
        ];
      };

      # helm-diff plugin (idempotent oneshot)
      systemd.services.helm-diff-install = {
        description = "Install helm-diff plugin for helmfile";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        path = [
          pkgs.git
          pkgs.bash
          pkgs.coreutils
          pkgs.gnutar
          pkgs.gzip
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "install-helm-diff" ''
            export HOME=/root
            if ! ${pkgs.kubernetes-helm}/bin/helm plugin list 2>/dev/null | grep -q diff; then
              ${pkgs.kubernetes-helm}/bin/helm plugin install https://github.com/databus23/helm-diff
            fi
          '';
        };
      };
    }

    # --- k3s configuration ---
    {
      services.k3s = {
        enable = true;
        role = if isServer then "server" else "agent";
        serverAddr = lib.mkIf (cfg.serverAddr != null) cfg.serverAddr;
        tokenFile = lib.mkIf (cfg.tokenFile != null) cfg.tokenFile;
        extraFlags =
          let
            # Only first server disables components and sets cluster-init
            clusterInitFlags = lib.optionals isFirstServer [
              "--cluster-init"
            ];
            disableFlags = lib.optionals isServer (map (c: "--disable ${c}") cfg.k3s.disable);
            flannelFlags = lib.optionals cfg.flannel.externalIp [
              "--flannel-external-ip"
            ];
            cidrFlags =
              lib.optionals (cfg.k3s.clusterCidr != null) [
                "--cluster-cidr=${cfg.k3s.clusterCidr}"
              ]
              ++ lib.optionals (cfg.k3s.serviceCidr != null) [
                "--service-cidr=${cfg.k3s.serviceCidr}"
              ];
            nodeIpFlags = lib.optionals (cfg.k3s.nodeIp != null) [
              "--node-ip=${cfg.k3s.nodeIp}"
            ];
            oidcFlags =
              lib.optionals (isServer && cfg.k3s.oidc.enable && cfg.k3s.oidc.clientId != "") [
                "--kube-apiserver-arg=oidc-issuer-url=https://forgejo.${cfg.domain}"
                "--kube-apiserver-arg=oidc-client-id=${cfg.k3s.oidc.clientId}"
                "--kube-apiserver-arg=oidc-username-claim=preferred_username"
                "--kube-apiserver-arg=oidc-username-prefix=-"
                "--kube-apiserver-arg=oidc-groups-claim=groups"
              ]
              ++ lib.optionals (isServer && cfg.k3s.oidc.caFile != null) [
                "--kube-apiserver-arg=oidc-ca-file=${cfg.k3s.oidc.caFile}"
              ];
          in
          clusterInitFlags ++ disableFlags ++ cidrFlags ++ nodeIpFlags ++ flannelFlags ++ oidcFlags ++ cfg.k3s.extraFlags;
      };
    }

    # --- Registry config (server nodes with self-signed CA) ---
    (lib.mkIf (isServer && cfg.k3s.oidc.caFile != null) {
      environment.etc."rancher/k3s/registries.yaml" = {
        text = ''
          mirrors:
            forgejo.${cfg.domain}:
              endpoint:
                - "https://forgejo.${cfg.domain}"
          configs:
            "forgejo.${cfg.domain}":
              tls:
                ca_file: "${cfg.k3s.oidc.caFile}"
        '';
      };
    })
  ]);
}
