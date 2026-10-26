{
  # Car Thing as a wireless Home Assistant dashboard (see carthing/README.md).
  # nixos-superbird + a Bluetooth PAN link to the Pi (NAP on bridge carthing0, 10.44.0.1)
  # + Chromium kiosk on the Pi-served dashboard. Built by .github/workflows/carthing-image.yml.
  description = "Car Thing HA dashboard (nixos-superbird)";

  nixConfig = {
    extra-substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
      "https://superbird.attic.claiborne.soy/superbird"
    ];
    extra-trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "superbird:r9Hm/REl7BEr6+9UQoS+nxzqxY2sKUhsDCNy5PGQbDU="
    ];
    auto-optimise-store = true;
  };

  inputs = {
    nixos-superbird.url = "github:joeyeamigh/nixos-superbird/main";
    nixpkgs.follows = "nixos-superbird/nixpkgs";
  };

  outputs = { self, nixpkgs, nixos-superbird }: {
    nixosConfigurations.superbird = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = { inherit self; };
      modules = [
        nixos-superbird.nixosModules.superbird
        ({ pkgs, lib, ... }:
          let
            piBtMac = "98:FE:54:01:0F:66";   # Raspberry Pi 5 Bluetooth controller = the NAP
          in
          {
            superbird.name = "carthing-ha";
            superbird.description = "Car Thing wireless Home Assistant dashboard";
            # the kiosk opens the local status screen first; it forwards to the dashboard (10.44.0.1:8790) once reachable
            superbird.gui.kiosk_url = "http://127.0.0.1:8080/";
            superbird.bluetooth.enable = true;
            superbird.bluetooth.name = "Car Thing HA";
            hardware.bluetooth.powerOnBoot = lib.mkForce true;

            time.timeZone = "Europe/Amsterdam";
            environment.systemPackages = [ pkgs.bluez pkgs.bluez-tools ];

            # Bluetooth PAN client: pair with the Pi once, then keep a NAP connection up (bnep0, DHCP from the Pi).
            systemd.services.carthing-pan = {
              description = "Bluetooth PAN link to the Pi (dashboard network)";
              after = [ "bluetooth.service" ];
              requires = [ "bluetooth.service" ];
              wantedBy = [ "multi-user.target" ];
              path = [ pkgs.bluez pkgs.bluez-tools pkgs.coreutils pkgs.gnugrep pkgs.systemd ];
              serviceConfig = { Restart = "always"; RestartSec = 10; };
              script = ''
                # Pair once (bonded), then keep the NAP link up. Being out of range just means retrying; the bond
                # is never dropped automatically (an earlier "remove after 3 failures" broke the pairing upstairs).
                PI=${piBtMac}
                bluetoothctl power on || true
                # Without "pairable" BlueZ pairs WITHOUT bonding: no link key is stored and both sides forget
                # each other after the first disconnect (what broke the reconnect after a power cut, 2026-10-26).
                bluetoothctl pairable-timeout 0 >/dev/null 2>&1 || true
                bluetoothctl pairable on || true
                if ! bluetoothctl info "$PI" | grep -q "Paired: yes"; then
                  echo "pairing with $PI (the Pi must be in its pairing window)"
                  busctl call org.bluez /org/bluez/hci0 org.bluez.Adapter1 ConnectDevice 'a{sv}' 1 Address s "$PI" >/dev/null 2>&1 \
                    || timeout 25 bluetoothctl --timeout 20 scan on >/dev/null 2>&1 || true
                  bluetoothctl --agent NoInputNoOutput pair "$PI" || exit 1
                fi
                bluetoothctl trust "$PI" || true
                echo "connecting NAP"
                exec bt-network -c "$PI" nap
              '';
            };
            networking.interfaces.bnep0.useDHCP = true;

            # Status screen: Bluetooth / bond / link / dashboard checklist + connection log (carthing/nixos/status)
            systemd.services.carthing-status = {
              description = "Car Thing status screen (127.0.0.1:8080)";
              wantedBy = [ "multi-user.target" ];
              before = [ "weston-tty1.service" ];
              path = [ pkgs.bluez pkgs.iproute2 pkgs.systemd pkgs.coreutils ];
              serviceConfig = {
                ExecStart = "${pkgs.python3Minimal}/bin/python3 ${./status}/status.py";
                Restart = "always";
                RestartSec = 3;
              };
            };

            users.users.root.openssh.authorizedKeys.keys = [
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOKaibkMNWFEQFnSgkhqcKEv74kF1eND7FYaugFipCe3"
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIaIprPfrcGft4/WcQz2qk8CO/zgDn0/DCZdasKlfaJ+"
            ];

            superbird.stateVersion = "0.2";
            system.stateVersion = "24.11";
          })
      ];
    };
  };
}
