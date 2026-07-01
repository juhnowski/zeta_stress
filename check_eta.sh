#!/usr/bin/env bash

# Принудительная локализация для корректной работы с точкой в числах
export LC_ALL=C

POINTER_FILE="riemann_block_pointer.txt"
TEMP_STATUS="/tmp/zeta_speed_marker"
MAX_LIMIT_BYTES=$(( 8100 * 1024 * 1024 * 1024 ))

if [ ! -f "$POINTER_FILE" ]; then
    echo "[ОШИБКА] Файл указателя не найден."
    exit 1
fi

# 1. Сбор текущих данных
OFFSET_NOW=$(tr -d '[:space:]' < "$POINTER_FILE")
TIME_NOW=$(date +%s)

# Инициализируем переменные нулями, чтобы избежать ошибок "унарного оператора"
SPEED_BPS=0
DIFF_TIME=0
DIFF_BYTES=0

# 2. Расчет скорости
if [ -f "$TEMP_STATUS" ]; then
    read -r OFFSET_PREV TIME_PREV < "$TEMP_STATUS"
    
    if [[ -n "$OFFSET_PREV" && -n "$TIME_PREV" ]]; then
        # Используем (( )) - это быстрее и надежнее для целых чисел в Bash
        (( DIFF_BYTES = OFFSET_NOW - OFFSET_PREV ))
        (( DIFF_TIME = TIME_NOW - TIME_PREV ))
        
        if (( DIFF_TIME > 0 && DIFF_BYTES > 0 )); then
            (( SPEED_BPS = DIFF_BYTES / DIFF_TIME ))
        fi
    fi
fi

# Обновляем маркер для следующего замера
echo "$OFFSET_NOW $TIME_NOW" > "$TEMP_STATUS"

# 3. Расчеты прогресса через awk (передаем переменные через -v)
CURRENT_GB=$(awk -v n="$OFFSET_NOW" 'BEGIN {printf "%.2f", n / (1024^3)}')
MAX_GB=$(awk -v m="$MAX_LIMIT_BYTES" 'BEGIN {printf "%.2f", m / (1024^3)}')
PERCENT=$(awk -v n="$OFFSET_NOW" -v m="$MAX_LIMIT_BYTES" 'BEGIN {printf "%.4f", (n * 100) / m}')
REMAINING_BYTES=$(( MAX_LIMIT_BYTES - OFFSET_NOW ))

printf "=== МОНИТОРИНГ ZETA-STRESS ===\n"
printf "Прогресс: %s%%\n" "$PERCENT"
printf "Записано: %s / %s Гб\n" "$CURRENT_GB" "$MAX_GB"

# 4. Вывод скорости и ETA
if (( SPEED_BPS > 0 )); then
    SPEED_MBPS=$(awk -v s="$SPEED_BPS" 'BEGIN {printf "%.2f", s / (1024^2)}')
    
    # Считаем секунды до финиша
    (( SECONDS_LEFT = REMAINING_BYTES / SPEED_BPS ))
    
    # Конвертируем секунды в Дни, Часы, Минуты
    (( DAYS = SECONDS_LEFT / 86400 ))
    (( HOURS = (SECONDS_LEFT % 86400) / 3600 ))
    (( MINS = (SECONDS_LEFT % 3600) / 60 ))
    
    printf "Скорость записи: %s Мб/сек\n" "$SPEED_MBPS"
    printf "Осталось времени (ETA): %dд %02dh %02dm\n" "$DAYS" "$HOURS" "$MINS"
else
    printf "Скорость: Замеряется (запустите повторно через 30 секунд)...\n"
fi
printf "==============================\n"
