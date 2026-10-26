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
            superbird.gui.kiosk_url = "http://10.44.0.1:8790/";
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
                # Self-healing: if the Pi forgot us (or we forgot it), drop the stale bond after 3 failed
                # connects and pair again. ConnectDevice creates the device by address, so the Pi doesn't
                # need to be discoverable (it still has to accept the pairing).
                PI=${piBtMac}
                FAILS=/run/carthing-pan.failures
                bluetoothctl power on || true
                n=$(cat $FAILS 2>/dev/null || echo 0)
                if [ "$n" -ge 3 ]; then
                  echo "3 failed connects: removing the bond with $PI and pairing again"
                  bluetoothctl remove "$PI" || true
                  echo 0 > $FAILS; n=0
                fi
                if ! bluetoothctl info "$PI" | grep -q "Paired: yes"; then
                  echo "pairing with $PI"
                  busctl call org.bluez /org/bluez/hci0 org.bluez.Adapter1 ConnectDevice 'a{sv}' 1 Address s "$PI" >/dev/null 2>&1 \
                    || timeout 25 bluetoothctl --timeout 20 scan on >/dev/null 2>&1 || true
                  bluetoothctl --agent NoInputNoOutput pair "$PI" || { echo $((n + 1)) > $FAILS; exit 1; }
                fi
                bluetoothctl trust "$PI" || true
                echo "connecting NAP"
                bt-network -c "$PI" nap || { echo $((n + 1)) > $FAILS; exit 1; }
                echo 0 > $FAILS
              '';
            };
            networking.interfaces.bnep0.useDHCP = true;

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
