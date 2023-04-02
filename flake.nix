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
        rev = "4de9a4b2b8c41864aadae89be705ef125a745a0a";
        hash = "sha256-MzfM+7ngvkubvkFgODRUXBNm8P7WWXQ24nChHeVLiRM=";
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
      ];
      # Dirty patch to make one of the nixos-upstream patches working.
      patches = [ ./mesa.patch ] ++ (old.patches or [ ]);
    });
  in {
    packages.${system}.mesa = mesa;

    devShells.${system}.default = pkgs.stdenv.mkDerivation {
      name = "zig-spirv";

      nativeBuildInputs = [
        mesa.opencl
        pkgs.khronos-ocl-icd-loader
        pkgs.clinfo
        pkgs.opencl-headers
        pkgs.spirv-tools
      ];

      OCL_ICD_VENDORS = "${mesa.opencl}/etc/OpenCL/vendors";

      LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.khronos-ocl-icd-loader ];

      RUSTICL_ENABLE = "swrast:0";
    };
  };
}
