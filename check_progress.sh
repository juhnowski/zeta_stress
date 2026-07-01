#!/usr/bin/env bash

# Путь к файлу-указателю смещения
POINTER_FILE="riemann_block_pointer.txt"

# Общий объем выделенного пространства: строго 8.1 Тб в байтах (двоичные TiB)
MAX_LIMIT_BYTES=$(( 8100 * 1024 * 1024 * 1024 ))

if [ ! -f "$POINTER_FILE" ]; then
    echo "[ОШИБКА] Файл $POINTER_FILE не найден! Пайплайн еще не запускался."
    exit 1
fi

# Читаем текущее смещение (удаляя возможные пробелы)
CURRENT_OFFSET=$(tr -d '[:space:]' < "$POINTER_FILE")

# Защита от пустого или нечислового значения в файле
if ! [[ "$CURRENT_OFFSET" =~ ^[0-9]+$ ]]; then
    echo "[ОШИБКА] В файле указателя находится некорректное значение: '$CURRENT_OFFSET'"
    exit 1
fi

# Переводим байты в Гигабайты для человекочитаемого вывода
CURRENT_GB=$(awk "BEGIN {print $CURRENT_OFFSET / (1024^3)}")
MAX_LIMIT_GB=$(awk "BEGIN {print $MAX_LIMIT_BYTES / (1024^3)}")
REMAINING_GB=$(awk "BEGIN {print $MAX_LIMIT_GB - $CURRENT_GB}")

# Считаем точный процент выполнения
PERCENT=$(awk "BEGIN {printf \"%.4f\", ($CURRENT_OFFSET * 100) / $MAX_LIMIT_BYTES}")

# Считаем количество вычисленных нулей дзета-функции (каждый ноль — это 8 байт Double)
TOTAL_ZEROS=$(( CURRENT_OFFSET / 8 ))

# Рисуем визуальный прогресс-бар (шириной в 40 символов)
BAR_WIDTH=40
# Округляем процент до целого числа для заполнения бара
INT_PERCENT=$(awk "BEGIN {print int(($CURRENT_OFFSET * $BAR_WIDTH) / $MAX_LIMIT_BYTES)}")

printf "=== МОНИТОРИНГ ПРОГРЕССА СХД ZETA-STRESS ===\n"
# Безопасный вызов вывода целого числа без использования системных локалей
printf "Вычислено нулей дзета-функции:  %d\n" $TOTAL_ZEROS
printf "Записано данных на RAID-0:      %.2f Гб из %.2f Гб\n" $CURRENT_GB $MAX_LIMIT_GB
printf "Осталось свободного места:     %.2f Гб\n" $REMAINING_GB
printf "Текущий прогресс проекта:       %s%%\n" $PERCENT

# Вывод самого прогресс-бара [====>....]
printf "["
for ((i=0; i<BAR_WIDTH; i++)); do
    if [ $i -lt $INT_PERCENT ]; then
        printf "="
    elif [ $i -eq $INT_PERCENT ]; then
        printf ">"
    else
        printf "."
    fi
done
printf "]\n"
printf "============================================\n"
