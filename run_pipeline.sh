#!/usr/bin/env bash

START_T=1000000000000.0
STEP=10000.0
BLOCK_NUM=2

echo "=== ЗАПУСК АВТОМАТИЧЕСКОГО КОНВЕЙЕРА ZETA-STRESS ==="

while true; do
    END_T=$(awk -v start="$START_T" -v step="$STEP" 'BEGIN {print start + step}')
    
    echo -e "\n[$(date +%T)] >>> Расчет Блока №${BLOCK_NUM} (Интервал: $START_T — $END_T) ..."
    
    ./zeta_stress "$BLOCK_NUM" "$START_T" "$END_T"
    STATUS=$?
    
    if [ $STATUS -eq 2 ]; then
        echo "[СТОП] Достигнут жесткий лимит 8.1 Тб на RAID-0. Пайплайн завершен."
        break
    fi
    
    if [ $STATUS -ne 0 ]; then
        echo "[ОШИБКА] Сбой выполнения на Блоке №${BLOCK_NUM}."
        break
    fi
    
    if (( BLOCK_NUM % 50 == 0 )); then
        echo "[АУДИТ] Плановая проверка целостности бинарных данных..."
        ./ZetaValidator
        if [ $? -ne 0 ]; then
            echo "[КРИТИЧЕСКИЙ ОСТАНОВ] Валидатор обнаружил порчу структуры!"
            break
        fi
    fi
    
    START_T=$END_T
    BLOCK_NUM=$((BLOCK_NUM + 1))
    
    sleep 0.2
done
