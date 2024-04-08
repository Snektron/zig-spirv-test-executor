{
  description = "spirv test executor flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
  };

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in rec {
    packages.${system} = rec {
      spirv-llvm-translator_17 = (pkgs.spirv-llvm-translator.override {
        inherit (pkgs.llvmPackages_17) llvm;
      });

      spirv-llvm-translator_18 = (pkgs.spirv-llvm-translator.override {
        inherit (pkgs.llvmPackages_18) llvm;
      });

      mesa = (pkgs.mesa.override {
        galliumDrivers = [ "swrast" "radeonsi" ];
        vulkanDrivers = [ ];
        vulkanLayers = [ ];
        withValgrind = false;
        enableGalliumNine = false;
        spirv-llvm-translator = spirv-llvm-translator_17;
        llvmPackages = pkgs.llvmPackages_17;
      }).overrideAttrs (old: {
        version = "24.03.17-git";
        src = pkgs.fetchFromGitLab {
          domain = "gitlab.freedesktop.org";
          owner = "mesa";
          repo = "mesa";
          rev = "eac703f69128d5aa6879c9becbad627ce08a7920";
          hash = "sha256-S0iR/WqMHXa5E5ZinJgt7mWFCHheBLyvuIVnU/E9gKc=";
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
        patches = [ ./patches/mesa-opencl.patch ./patches/mesa-disk-cache-key.patch ./patches/mesa-rusticl-bindgen-cpp17.patch ];
      });

      oclcpuexp-bin = pkgs.callPackage ({ stdenv, fetchurl, autoPatchelfHook, zlib, tbb_2021_11, libxml2 }:
      stdenv.mkDerivation {
        pname = "oclcpuexp-bin";
        version = "2023-WW46";

        nativeBuildInputs = [ autoPatchelfHook ];

        propagatedBuildInputs = [ zlib tbb_2021_11 libxml2 ];

        src = fetchurl {
          url = "https://github.com/intel/llvm/releases/download/2023-WW46/oclcpuexp-2023.16.10.0.17_rel.tar.gz";
          hash = "sha256-959AgccjcaHXA86xKW++BPVHUiKu0vX5tAxw1BY7lUk=";
        };

        sourceRoot = ".";

        dontConfigure = true;
        dontBuild = true;

        installPhase = ''
          mkdir -p $out/lib
          # These require some additional external libraries
          rm x64/libomptarget*
          mv x64/* $out/lib
          chmod 644 $out/lib/*
          chmod 755 $out/lib/*.so*

          mkdir -p $out/etc/OpenCL/vendors
          echo $out/lib/libintelocl.so > $out/etc/OpenCL/vendors/intelocl64.icd
        '';
      }) {};

      pocl = pkgs.callPackage ({
        stdenv,
        gcc-unwrapped,
        fetchFromGitHub,
        cmake,
        ninja,
        python3,
        llvmPackages_18,
        ocl-icd,
        libxml2
      }: stdenv.mkDerivation {
        pname = "pocl";
        version = "5.0";

        nativeBuildInputs = [
          cmake
          ninja
          python3
          llvmPackages_18.clang
        ];

        buildInputs = with llvmPackages_18; [
          llvm
          clang-unwrapped
          clang-unwrapped.lib
          ocl-icd
          spirv-llvm-translator_18
          libxml2
        ];

        src = fetchFromGitHub {
          owner = "pocl";
          repo = "pocl";
          rev = "216815ecf503910711161e024f414ab459fb1cbf";
          hash = "sha256-1UgHBtA9bEa0XP0gV2uTxWttd/xBQBkw+gIii0ihRuQ=";
        };

        postPatch = ''
          substituteInPlace cmake/LLVM.cmake \
            --replace NO_CMAKE_PATH "" \
            --replace NO_CMAKE_ENVIRONMENT_PATH "" \
            --replace NO_DEFAULT_PATH ""
        '';

        cmakeFlags = [
          "-DENABLE_ICD=ON"
          "-DENABLE_TESTS=OFF"
          "-DENABLE_EXAMPLES=OFF"
          # Required to make POCL play nice with Mesa
          # See https://github.com/pocl/pocl/blob/main/README.packaging
          "-DSTATIC_LLVM=ON"
          "-DEXTRA_KERNEL_FLAGS=-L${gcc-unwrapped.lib}/lib"
        ];
      }) {};

      shady = pkgs.callPackage ({
        stdenv,
        fetchFromGitHub,
        cmake,
        ninja,
        spirv-headers,
        llvmPackages_17,
        libxml2,
        json_c
      }: stdenv.mkDerivation {
        pname = "shady";
        version = "0.1";

        src = fetchFromGitHub {
          owner = "Hugobros3";
          repo = "shady";
          rev = "fd9595b258e18bf953d9c437654318984898e1e8";
          sha256 = "sha256-1QFAqL4xa7Z3axigfQu4x1PtDvdFd//9rzz8X90EJfA=";
          fetchSubmodules = true;
        };

        nativeBuildInputs = [
          cmake
          ninja
        ];

        buildInputs = [
          spirv-headers
          llvmPackages_17.llvm
          libxml2
          json_c
        ];

        cmakeFlags = [
          "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON"
          "-DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON"
        ];

        installPhase = ''
          ninja install
          # slim is not installed by default for some reason
          mkdir -p $out/bin
          mv bin/slim $out/bin/slim
        '';
      }) {};

      spirv2clc = pkgs.callPackage ({
        stdenv,
        fetchFromGitHub,
        cmake,
        ninja,
        python3
      }: stdenv.mkDerivation {
        pname = "spirv2clc";
        version = "0.1";

        src = fetchFromGitHub {
          owner = "kpet";
          repo = "spirv2clc";
          rev = "b7972d03a707a6ad1b54b96ab1437c5cd1594a43";
          sha256 = "sha256-IYaJRsS4VpGHPJzRhjIBXlCoUWM44t84QV5l7PKSaJk=";
          fetchSubmodules = true;
        };

        nativeBuildInputs = [ cmake ninja python3];

        installPhase = ''
          ninja install
          # not installed by default for some reason
          mkdir -p $out/bin
          mv tools/spirv2clc $out/bin/spirv2clc
        '';
      }) {};

      ocl-vendors = pkgs.runCommand "ocl-vendors" {} ''
        mkdir -p $out/etc/OpenCL/vendors
        cp ${packages.${system}.mesa.opencl}/etc/OpenCL/vendors/rusticl.icd $out/etc/OpenCL/vendors/
        cp ${packages.${system}.oclcpuexp-bin}/etc/OpenCL/vendors/intelocl64.icd $out/etc/OpenCL/vendors/
        cp ${packages.${system}.pocl}/etc/OpenCL/vendors/pocl.icd $out/etc/OpenCL/vendors/
      '';

      # Otherwise pocl cannot find -lgcc
      libgcc = pkgs.runCommand "libgcc" {} ''
        mkdir -p $out/lib
        cp ${pkgs.gcc-unwrapped}/lib/gcc/x86_64-unknown-linux-gnu/*/libgcc.a $out/lib/libgcc.a
      '';
    };

    devShells.${system}.default = pkgs.mkShell {
      name = "zig-spirv";

      nativeBuildInputs = [
        pkgs.khronos-ocl-icd-loader
        pkgs.clinfo
        pkgs.opencl-headers
        pkgs.spirv-tools
        pkgs.gdb
        pkgs.gcc-unwrapped.lib
        packages.${system}.spirv-llvm-translator_18
        packages.${system}.shady
        packages.${system}.spirv2clc
        packages.${system}.libgcc
      ];

      OCL_ICD_VENDORS = "${packages.${system}.ocl-vendors}/etc/OpenCL/vendors";
      RUSTICL_ENABLE = "swrast:0"; # Don't enable radeonsi:0 by default because if something goes wrong it may crash the host
      LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
        pkgs.khronos-ocl-icd-loader
        pkgs.gcc-unwrapped
      ];
    };
  };
}
