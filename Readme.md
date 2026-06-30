# Построение
```bash
nix build
```

# Запуск
```bash
nix-shell -p tmux --run "tmux new-session -A -s zeta '
  START=1000000000000
  STEP=10000000
  BLOCK_NUM=1
  
  if [ ! -f riemann_chunks_summary.csv ]; then
    echo \"block_number;t_start;t_end;zeros_count\" > riemann_chunks_summary.csv
  fi

  while true; do
    END=\$((START + STEP))
    ./result/bin/zeta_stress \$BLOCK_NUM \$START \$END +RTS -N124 -M950G -A128m -RTS
    START=\$END
    BLOCK_NUM=\$((BLOCK_NUM + 1))
    sleep 0.1
  done
'"
```
# Подключиться к расчету
```bash
nix-shell -p tmux --run "tmux a -t zeta"
```