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
      spirv-llvm-translator = (pkgs.spirv-llvm-translator.override {
        inherit (pkgs.llvmPackages_17) llvm;
      });

      meson = pkgs.meson.overrideAttrs (old: rec {
        version = "1.3.1";

        src = pkgs.fetchFromGitHub {
          owner = "mesonbuild";
          repo = "meson";
          rev = "refs/tags/${version}";
          hash = "sha256-KNNtHi3jx0MRiOgmluA4ucZJWB2WeIYdApfHuspbCqg=";
        };

        # The latest patch is already applied, so remove it here.
        patches = (pkgs.lib.reverseList (builtins.tail (pkgs.lib.reverseList old.patches)));
      });

      mesa = (pkgs.mesa.override {
        galliumDrivers = [ "swrast" "radeonsi" ];
        vulkanDrivers = [ ];
        vulkanLayers = [ ];
        withValgrind = false;
        enableGalliumNine = false;
        inherit spirv-llvm-translator meson;
        llvmPackages = pkgs.llvmPackages_17;
      }).overrideAttrs (old: {
        version = "24.01.07-git";
        src = pkgs.fetchFromGitLab {
          domain = "gitlab.freedesktop.org";
          owner = "mesa";
          repo = "mesa";
          rev = "a84729d36866bc79619523065a6038c3d8444f97";
          hash = "sha256-TzQDobHhyLuCD/M2xsAwnWIsagfOVkBzvLuzeLrYcFw=";
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

      oclcpuexp-bin = pkgs.callPackage ({ stdenv, fetchurl, autoPatchelfHook, zlib, tbb_2021_8, libxml2 }:
      stdenv.mkDerivation {
        pname = "oclcpuexp-bin";
        version = "2023-WW46";

        nativeBuildInputs = [ autoPatchelfHook ];

        propagatedBuildInputs = [ zlib tbb_2021_8 libxml2 ];

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
        llvmPackages_16,
        ocl-icd,
      }: stdenv.mkDerivation {
        pname = "pocl";
        version = "5.0";

        nativeBuildInputs = [
          cmake
          ninja
          python3
          llvmPackages_16.clang
        ];

        buildInputs = with llvmPackages_16; [
          llvm
          clang-unwrapped
          clang-unwrapped.lib
          ocl-icd
          spirv-llvm-translator
        ];

        src = fetchFromGitHub {
          owner = "pocl";
          repo = "pocl";
          rev = "0bffce03b71c2be14ced90019418e943fd770114";
          hash = "sha256-9Z7WG1r9FqxlQXwuyrTOW4/Y3c7u85rH2qfLJHgmZ3E=";
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
    };

    devShells.${system} = let
      mkEnv = {
        name,
        driver,
        extraPkgs ? [],
        env ? {},
      }: pkgs.mkShell {
        inherit name;

        nativeBuildInputs = [
          pkgs.khronos-ocl-icd-loader
          pkgs.clinfo
          pkgs.opencl-headers
          pkgs.spirv-tools
          pkgs.gdb
          packages.${system}.spirv-llvm-translator
          packages.${system}.shady
          packages.${system}.spirv2clc
        ] ++ extraPkgs;

        OCL_ICD_VENDORS = "${driver}/etc/OpenCL/vendors";

        LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.khronos-ocl-icd-loader pkgs.gcc-unwrapped ];
      } // env;
    in rec {
      intel = mkEnv {
        name = "zig-spirv-intel";
        driver = packages.${system}.oclcpuexp-bin;
      };

      rusticl = mkEnv {
        name = "zig-spirv-rusticl";
        driver = packages.${system}.mesa.opencl;
        env = {
          RUSTICL_ENABLE = "swrast:0,radeonsi:0";
        };
      };

      pocl = let
        # Otherwise pocl cannot find -lgcc
        libgcc = pkgs.runCommand "libgcc" {} ''
          mkdir -p $out/lib
          cp ${pkgs.gcc-unwrapped}/lib/gcc/x86_64-unknown-linux-gnu/*/libgcc.a $out/lib/libgcc.a
        '';
      in mkEnv {
        name = "zig-spirv-pocl";
        driver = packages.${system}.pocl;
        extraPkgs = [
          pkgs.gcc-unwrapped.lib
          libgcc
        ];
      };

      default = intel;
    };
  };
}
