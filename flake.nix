{
  description = "spirv test executor flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
  };

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

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

    mesa = (pkgs.mesa.override {
      galliumDrivers = [ "swrast" "radeonsi" ];
      vulkanDrivers = [ ];
      vulkanLayers = [ ];
      withValgrind = false;
      enableGalliumNine = false;
      llvmPackages_15 = pkgs.llvmPackages_16;
      inherit spirv-llvm-translator;
    }).overrideAttrs (old: {
      version = "23.8.26-git";
      src = pkgs.fetchFromGitLab {
        domain = "gitlab.freedesktop.org";
        owner = "mesa";
        repo = "mesa";
        rev = "3a307e2248333dc95330b390167463c28bc4f9a7";
        hash = "sha256-Wy0LgqXz7Sd1u4pIr0SUU6zus6cjjy8rd48YkPhJpKM=";
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
      patches = [ ./patches/mesa-opencl.patch ./patches/mesa-disk-cache-key.patch ];
    });

    oclcpuexp-bin = pkgs.callPackage ({ stdenv, fetchurl, autoPatchelfHook, zlib, tbb_2021_8 }:
    stdenv.mkDerivation {
      pname = "oclcpuexp-bin";
      version = "2023-WW13";

      nativeBuildInputs = [ autoPatchelfHook ];

      propagatedBuildInputs = [ zlib tbb_2021_8 ];

      src = fetchurl {
        url = "https://github.com/intel/llvm/releases/download/2023-WW27/oclcpuexp-2023.16.6.0.28_rel.tar.gz";
        hash = "sha256-iJB5fRNgjSAKNishxJ0QFhIFDadwxNS1I/tbVupduRk=";
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
    }: stdenv.mkDerivation {
      pname = "pocl";
      version = "4.0";

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
        rev = "d6ec42378fe6f618b92170d2be45f47eae22343f";
        hash = "sha256-Uo4Np4io1s/NMK+twX36PLBFP0j5j/0NkkBvS2Zv9ng=";
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
        "-DENABLE_HSA=ON"
        "-DEXTRA_KERNEL_FLAGS=-L${gcc-unwrapped.lib}/lib"
        "-DHSA_RUNTIME_DIR=${rocm-runtime}"
        "-DWITH_HSA_RUNTIME_INCLUDE_DIR=${rocm-runtime}/include/hsa"
      ];
    }) {};

    # Merge the ICD files from all the drivers.
    ocl-vendors = pkgs.runCommand "ocl-vendors" {} ''
      mkdir -p $out/etc/OpenCL/vendors
      cp ${mesa.opencl}/etc/OpenCL/vendors/* $out/etc/OpenCL/vendors
      cp ${oclcpuexp-bin}/etc/OpenCL/vendors/* $out/etc/OpenCL/vendors
    '';
    # TODO: POCL cannot be combined with Mesa using dynamic linking...
    # See https://github.com/pocl/pocl/blob/main/README.packaging.
    # cp ${pocl}/etc/OpenCL/vendors/* $out/etc/OpenCL/vendors

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
