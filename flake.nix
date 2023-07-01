{
  description = "spirv test executor flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.05";
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

    spirv-llvm-translator = (pkgs.spirv-llvm-translator.override {
      inherit (pkgs.llvmPackages_16) llvm;
    }).overrideAttrs (old: {
      version = "16.0.0";
      src = pkgs.fetchFromGitHub {
        owner = "KhronosGroup";
        repo = "SPIRV-LLVM-Translator";
        rev = "42de1b449486edb0aa2b764e4f4f3771d3f1a4a3";
        hash = "sha256-rP7M52IDimfkF62Poa765LUL9dbIKNK5tn1FuS1k+c0=";
      };
    });

    pocl = pkgs.callPackage ({
      stdenv,
      gcc-unwrapped,
      fetchFromGitHub,
      cmake,
      ninja,
      python3,
      llvmPackages_16,
      ocl-icd,
      rocm-runtime
    }: llvmPackages_16.stdenv.mkDerivation {
      pname = "pocl";
      version = "3.1";

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
        rocm-runtime
      ];

      src = fetchFromGitHub {
        owner = "pocl";
        repo = "pocl";
        rev = "6de05a28bc81be5db50e4f8f9f7681aa4ff3edb5";
        hash = "sha256-sjlJNsgZWkjQDPQYzsA4SPZfAOLsxa3X0rxLBBR33BI=";
      };

      patches = [ ./patches/pocl.patch ];

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
        "-DENABLE_HSA=ON"
        "-DEXTRA_KERNEL_FLAGS=-L${gcc-unwrapped.lib}/lib"
        "-DHSA_RUNTIME_DIR=${rocm-runtime}"
        "-DWITH_HSA_RUNTIME_INCLUDE_DIR=${rocm-runtime}/include/hsa"
      ];
    }) {};

    # Merge the ICD files from oclcpuexp and mesa
    ocl-vendors = pkgs.runCommand "ocl-vendors" {} ''
      mkdir -p $out/etc/OpenCL/vendors
      cp ${mesa.opencl}/etc/OpenCL/vendors/* $out/etc/OpenCL/vendors
      cp ${oclcpuexp-bin}/etc/OpenCL/vendors/* $out/etc/OpenCL/vendors
      cp ${pocl}/etc/OpenCL/vendors/* $out/etc/OpenCL/vendors
    '';

    # Needed for pocl, otherwise it cannot find -lgcc
    libgcc = pkgs.runCommand "libgcc" {} ''
      mkdir -p $out/lib
      cp ${pkgs.gcc-unwrapped}/lib/gcc/x86_64-unknown-linux-gnu/*/libgcc.a $out/lib/libgcc.a
    '';
  in {
    packages.${system} = { inherit mesa oclcpuexp-bin pocl; };

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
        # Needed for pocl, otherwise it cannot find -lgcc / -lgcc_s
        pkgs.gcc-unwrapped.lib
        libgcc
        spirv-llvm-translator
      ];

      OCL_ICD_VENDORS = "${ocl-vendors}/etc/OpenCL/vendors";

      LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.khronos-ocl-icd-loader pkgs.gcc-unwrapped ];

      RUSTICL_ENABLE = "swrast:0";
    };
  };
}
