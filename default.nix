let
  sources = import ./nix/sources.nix;
  pkgs = import (builtins.fetchTarball https://github.com/input-output-hk/nixpkgs/archive/0ee0489d42e.tar.gz) {};
  lib = pkgs.lib;
  overlay = self: super: {
    littlekernel = self.stdenv.mkDerivation {
      name = "littlekernel";
      src = lib.cleanSource ./.;
      #nativeBuildInputs = [ x86_64.uart-manager ];
      nativeBuildInputs = [ x86_64.python ];
      hardeningDisable = [ "format" ];
    };
    uart-manager = self.stdenv.mkDerivation {
      name = "uart-manager";
      src = sources.rpi-open-firmware + "/uart-manager";
    };
  };
  vc4 = pkgs.pkgsCross.vc4.extend overlay;
  x86_64 = pkgs.extend overlay;
  arm7 = pkgs.pkgsCross.arm-embedded.extend overlay;
in lib.fix (self: {
  arm7 = {
    inherit (arm7) littlekernel;
  };
  arm = {
    rpi2-test = arm7.callPackage ./lk.nix { project = "rpi2-test"; };
  };
  vc4 = {
    shell = vc4.littlekernel;
    rpi3.bootcode = vc4.callPackage ./lk.nix { project = "rpi3-bootcode"; };
    rpi3.start = vc4.callPackage ./lk.nix { project = "rpi3-start"; };
    rpi4.start4 = vc4.callPackage ./lk.nix { project = "rpi4-start4"; };
    vc4.stage1 = vc4.callPackage ./lk.nix { project = "vc4-stage1"; };
    vc4.stage2 = vc4.callPackage ./lk.nix { project = "vc4-stage2"; };
  };
  x86_64 = {
    inherit (x86_64) uart-manager;
  };
  testcycle = pkgs.writeShellScript "testcycle" ''
    set -e
    scp ${self.vc4.rpi3.bootcode}/lk.bin root@router.localnet:/tftproot/open-firmware/bootcode.bin
    exec ${x86_64.uart-manager}/bin/uart-manager
  '';
  disk_image = pkgs.vmTools.runInLinuxVM (pkgs.runCommand "disk-image" {
    buildInputs = with pkgs; [ utillinux dosfstools e2fsprogs mtools libfaketime ];
    preVM = ''
      mkdir -p $out
      diskImage=$out/disk-image.img
      truncate $diskImage -s 64m
    '';
    postVM = ''
    '';
  } ''
    sfdisk /dev/vda <<EOF
    label: dos
    label-id: 0x245a585c
    unit: sectors

    1: size=${toString (32 * 2048)}, type=c
    2: type=83
    EOF

    mkdir ext-dir
    cp ${self.vc4.vc4.stage2}/lk.elf ext-dir/lk.elf -v

    faketime "1970-01-01 00:00:00" mkfs.fat /dev/vda1 -i 0x2178694e
    mkfs.ext2 /dev/vda2 -d ext-dir

    mkdir fat-dir
    cp -v ${self.vc4.vc4.stage1}/lk.bin fat-dir/bootcode.bin
    cd fat-dir
    faketime "1970-01-01 00:00:00" mcopy -psvm -i /dev/vda1 * ::
  '');
})
