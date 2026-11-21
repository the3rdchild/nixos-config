{ lib, stdenv, kernel, kmod, kernelModuleMakeFlags }:

stdenv.mkDerivation {
  pname = "acer-ec";
  version = "1.0";

  src = lib.cleanSource ../.;

  nativeBuildInputs = kernel.moduleBuildDependencies ++ [ kmod ];

  # Out-of-tree kernel modules must match the kernel's own hardening flags.
  hardeningDisable = [ "pic" "format" ];

  # kernelModuleMakeFlags is nixpkgs' shared flag set for out-of-tree modules.
  # Since the 2026-11 nixpkgs it carries the `cmd_sign=kmodigest` override that
  # writes a <module>.ko.cer next to every .ko, and aggregateModules (what
  # builds the system's linux-<ver>-modules tree) reads those files while
  # merging modules.cer — without them that derivation fails with
  # "cat: extra/acer_fanctl.ko.cer: No such file or directory".
  #
  # DEPMOD=true: kbuild's modules_install now runs depmod and would leave
  # modules.dep* in this package's output, which then collides with the kernel's
  # own copies in the same buildEnv. aggregateModules regenerates them itself.
  makeFlags = kernelModuleMakeFlags ++ [
    "-C" "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(PWD)"
    "DEPMOD=true"
    "INSTALL_MOD_PATH=${placeholder "out"}"
    "INSTALL_MOD_DIR=extra"
  ];

  buildFlags = [ "modules" ];

  installPhase = ''
    runHook preInstall

    # Same flags as the build, so the signing override above also applies here.
    make $makeFlags modules_install

    install -Dm755 src/acer-ec.sh $out/bin/acer-ec

    runHook postInstall
  '';

  meta = with lib; {
    description = "Acer EC fan control kernel modules (acer_ec_core, acer_fanctl)";
    license = licenses.gpl2Only;
    platforms = platforms.linux;
  };
}
