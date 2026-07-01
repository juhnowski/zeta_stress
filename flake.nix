{
  description = "Riemann Zeta function heavy stress-test in Haskell with InfluxDB on NixOS";

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

        # Haskell-зависимости проекта
        hpkgs = with haskellPackages; [
          parallel
          async
          vector
          vector-fftw
          wreq         # Библиотека для простых и быстрых HTTP-запросов
          http-client  # Базовый HTTP-движок
          bytestring   # Эффективная работа с бинарными строками для отправки в БД
          text         # Текстовые типы данных
        ];
        
        # Актуальный и поддерживаемый LLVM 18 для сборщика GHC
        llvmSuite = pkgs.llvmPackages_18;

        # Python-окружение для работы с InfluxDB
        pythonEnv = pkgs.python3.withPackages (ps: [
          ps.influxdb-client 
        ]);
      in
      {
        # Интегрированное окружение разработки (devShell)
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            (haskellPackages.ghcWithPackages (p: hpkgs))
            cabal-install
            fftw
            llvmSuite.llvm
            llvmSuite.clang
            htop
            
            # Перенесенные зависимости InfluxDB и Python
            influxdb2
            influxdb2-cli
            pythonEnv
          ];

          # Объединенный shellHook для работы с InfluxDB прямо в dev-окружении
          shellHook = ''
            export INFLUX_DIR="$PWD/influx_data"
            export PORT=8086
            
            # Настройки агрессивного сброса кэша на диск в TSM-файлы из вашего проекта
            export INFLUX_STORAGE_CACHE_SNAPSHOT_MEMORY_SIZE=16777216  # 16 MB
            export INFLUX_STORAGE_CACHE_SNAPSHOT_WRITE_COLD_DURATION=1s # 1 сек

            mkdir -p "$INFLUX_DIR/engine"

            echo "--------------------------------------------------------"
            echo " Доступные команды InfluxDB-стенда:"
            echo "   start-influx - Запустить локальный сервер InfluxDB"
            echo "   stop-influx  - Безопасно остановить сервер InfluxDB"
            echo "--------------------------------------------------------"

            alias start-influx="influxd --bolt-path=\$INFLUX_DIR/influxd.bolt --engine-path=\$INFLUX_DIR/engine --http-bind-address=127.0.0.1:\$PORT > \$INFLUX_DIR/stdout.log 2>&1 & echo \$! > \$INFLUX_DIR/influxd.pid && echo '[+] InfluxDB запущен в фоне.'"
            alias stop-influx="if [ -f \$INFLUX_DIR/influxd.pid ]; then kill \$(cat \$INFLUX_DIR/influxd.pid) && rm \$INFLUX_DIR/influxd.pid && echo '[+] InfluxDB остановлен.'; else echo '[!] PID-файл не найден.'; fi"
          '';
        };

        # Сборка финального оптимизированного бинарника математического движка
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "zeta_stress";
          version = "1.0.3";
          src = ./.;

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
