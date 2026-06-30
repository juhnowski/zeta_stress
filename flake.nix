{
  description = "Riemann Zeta function heavy stress-test in Haskell on NixOS (Odlyzko-Schönhage FFT Optimization)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        
        haskellPackages = pkgs.haskellPackages.override {
          overrides = hself: hsuper: {
            vector-fftw = hsuper.vector-fftw.override {
              fftw = pkgs.fftw;
            };
          };
        };

        hpkgs = with haskellPackages; [
          parallel
          async
          vector
          vector-fftw
        ];
        
        # Решение проблемы: Используем актуальный и поддерживаемый LLVM 18
        llvmSuite = pkgs.llvmPackages_18;
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            (haskellPackages.ghcWithPackages (p: hpkgs))
            cabal-install
            fftw
            llvmSuite.llvm
            llvmSuite.clang
            htop
          ];
        };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "zeta_stress";
          version = "1.0.0";
          src = ./.;

          # Прокидываем корректные бинарники компилятора и утилит LLVM 18
          nativeBuildInputs = [ 
            llvmSuite.llvm
            llvmSuite.clang
          ];

          buildInputs = [ 
            (haskellPackages.ghcWithPackages (p: hpkgs))
            pkgs.fftw
          ];

          buildPhase = ''
            ghc -O2 -threaded -rtsopts -fllvm -optc-march=native -optc-O3 zeta_stress.hs -o zeta_stress
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp zeta_stress $out/bin/
          '';
        };
      });
}
