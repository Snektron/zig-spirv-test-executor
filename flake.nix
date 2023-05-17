{
  description = "spirv test executor flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    mesa = (pkgs.mesa.override {
      galliumDrivers = [ "swrast" ];
      vulkanDrivers = [ ];
      vulkanLayers = [ ];
      withValgrind = false;
      enableGalliumNine = false;
    }).overrideAttrs (old: {
      version = "23.0.1-git";
      src = pkgs.fetchFromGitLab {
        domain = "gitlab.freedesktop.org";
        owner = "mesa";
        repo = "mesa";
        rev = "1df30b01ff151bbb5718270e49ca67b5e45e048d";
        hash = "sha256-fwdwnmv9ukgbCLJYO7Cj03tbw26WTM4L/u8ytnfEQNQ=";
      };
      # Set some extra flags to create an extra slim build
      mesonFlags = (old.mesonFlags or [ ]) ++ [
        "-Dgallium-vdpau=disabled"
        "-Dgallium-va=disabled"
        "-Dgallium-xa=disabled"
        "-Dandroid-libbacktrace=disabled"
        "-Dvalgrind=disabled"
        "-Dlibunwind=disabled"
        "-Dlmsensors=disabled"
        "-Db_ndebug=false"
        "--buildtype=debug"
      ];
      # Dirty patch to make one of the nixos-upstream patches working.
      patches = [ ./patches/mesa-meson-options.patch ] ++ (old.patches or [ ]);
    });

    oclcpuexp-bin = pkgs.callPackage ({ stdenv, fetchurl, autoPatchelfHook, zlib, tbb_2021_8 }:
    stdenv.mkDerivation {
      pname = "oclcpuexp-bin";
      version = "2023-WW13";

      nativeBuildInputs = [ autoPatchelfHook ];

      propagatedBuildInputs = [ zlib tbb_2021_8 ];

      src = fetchurl {
        url = "https://github.com/intel/llvm/releases/download/2023-WW13/oclcpuexp-2023.15.3.0.20_rel.tar.gz";
        hash = "sha256-lMcijaFO3Dw0KHC+pYgBJ9TzCIpp16Xtfxo5COoPK9Y=";
      };

      sourceRoot = ".";

      dontConfigure = true;
      dontBuild = true;

      installPhase = ''
        mkdir -p $out/lib
        mv x64/* $out/lib
        mv clbltfnshared.rtl $out/lib/
        chmod 644 $out/lib/*
        chmod 755 $out/lib/*.so.*

        mkdir -p $out/etc/OpenCL/vendors
        echo $out/lib/libintelocl.so > $out/etc/OpenCL/vendors/intelocl64.icd
      '';
    }) {};

    # Merge the ICD files from oclcpuexp and mesa
    ocl-vendors = pkgs.runCommand "ocl-vendors" {} ''
      mkdir -p $out/etc/OpenCL/vendors
      cp ${mesa.opencl}/etc/OpenCL/vendors/* $out/etc/OpenCL/vendors
      cp ${oclcpuexp-bin}/etc/OpenCL/vendors/* $out/etc/OpenCL/vendors
    '';
  in {
    packages.${system} = { inherit mesa oclcpuexp-bin; };

    devShells.${system}.default = pkgs.stdenv.mkDerivation {
      name = "zig-spirv";

      nativeBuildInputs = [
        mesa.opencl
        oclcpuexp-bin
        pkgs.khronos-ocl-icd-loader
        pkgs.clinfo
        pkgs.opencl-headers
        pkgs.spirv-tools
        pkgs.gdb
      ];

      OCL_ICD_VENDORS = "${ocl-vendors}/etc/OpenCL/vendors";

      LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.khronos-ocl-icd-loader ];

      RUSTICL_ENABLE = "swrast:0";
    };
  };
}
