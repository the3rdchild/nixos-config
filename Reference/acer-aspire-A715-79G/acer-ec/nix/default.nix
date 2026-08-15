{ lib, stdenv, kernel, kmod }:

stdenv.mkDerivation {
  pname = "acer-ec";
  version = "1.0";

  src = lib.cleanSource ../.;

  nativeBuildInputs = kernel.moduleBuildDependencies ++ [ kmod ];

  # Out-of-tree kernel modules must match the kernel's own hardening flags.
  hardeningDisable = [ "pic" "format" ];

  makeFlags = [
    "-C" "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(PWD)"
  ];

  buildFlags = [ "modules" ];

  installPhase = ''
    runHook preInstall

    make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
      M=$PWD INSTALL_MOD_PATH=$out INSTALL_MOD_DIR=extra modules_install

    install -Dm755 src/acer-ec.sh $out/bin/acer-ec

    runHook postInstall
  '';

  meta = with lib; {
    description = "Acer EC fan control kernel modules (acer_ec_core, acer_fanctl)";
    license = licenses.gpl2Only;
    platforms = platforms.linux;
  };
}
