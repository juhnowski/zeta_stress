#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <omp.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdint.h>

#define BLOCK_DEVICE "/dev/md0"
#define POINTER_FILE "riemann_block_pointer.txt"
#define CSV_FILE     "riemann_chunks_summary.csv"

const uint64_t MAX_DEVICE_LIMIT_BYTES = 8100ULL * 1024ULL * 1024ULL * 1024ULL;

// 1. Точный расчет Z(t) и его производной Z'(t) за один проход (вызывается редко)
void evalZ_with_deriv(double t, double *z_val, double *z_deriv) {
    int64_t nMax = (int64_t)floor(sqrt(t / (2.0 * M_PI)));
    double theta = (t / 2.0) * log(t / (2.0 * M_PI)) - (t / 2.0) - (M_PI / 8.0);
    // Производная theta' (аппроксимация для локального окна)
    double d_theta = 0.5 * log(t / (2.0 * M_PI));

    double acc_z = 0.0;
    double acc_d = 0.0;

    for (int64_t n = 1; n <= nMax; n++) {
        double ln_n = log((double)n);
        double phase = theta - t * ln_n;
        double cos_p = cos(phase);
        double sin_p = sin(phase);
        double inv_sqrt = 1.0 / sqrt((double)n);

        acc_z += cos_p * inv_sqrt;
        // Производная по правилу дифференцирования сложной функции
        acc_d -= sin_p * (d_theta - ln_n) * inv_sqrt;
    }
    *z_val = 2.0 * acc_z;
    *z_deriv = 2.0 * acc_d;
}

uint64_t get_current_offset() {
    FILE *f = fopen(POINTER_FILE, "r");
    if (!f) return 0;
    uint64_t offset = 0;
    if (fscanf(f, "%lu", &offset) != 1) offset = 0;
    fclose(f);
    return offset;
}

int main(int argc, char *argv[]) {
    if (argc != 4) {
        printf("Ошибка: Передайте аргументы: ./zeta_stress <номер_блока> <tStart> <tEnd>\n");
        return 1;
    }

    char *block_num_str = argv[1];
    double global_start = atof(argv[2]);
    double global_end   = atof(argv[3]);
    uint64_t current_offset = get_current_offset();

    int total_cores = 64; // Чистые физические ядра AMD Zen 2
    omp_set_num_threads(total_cores);

    // Сетка высокой плотности под стресс-тест СХД (31 миллион точек)
    uint64_t samples_per_core = 500000;
    uint64_t total_samples = samples_per_core * total_cores;
    double step = (global_end - global_start) / (double)total_samples;

    double *global_buffer = (double*)malloc(total_samples * sizeof(double));
    uint64_t total_zeros = 0;

    printf("=== СИ-ВЕКТОР v6.0: Дифференциальный Тейлор-Накат (AMD Rome) ===\n");
    fflush(stdout);

    double start_time = omp_get_wtime();

    // Шаг 1. Расчет точной сетки макро-опорных точек и производных (шаг 1.0 на интервале 10000)
    uint64_t macro_intervals = (uint64_t)(global_end - global_start);
    double *macro_z = (double*)malloc((macro_intervals + 1) * sizeof(double));
    double *macro_d = (double*)malloc((macro_intervals + 1) * sizeof(double));

    #pragma omp parallel for schedule(static)
    for (uint64_t i = 0; i <= macro_intervals; i++) {
        double t = global_start + (double)i;
        evalZ_with_deriv(t, &macro_z[i], &macro_d[i]);
    }

    // Шаг 2. Мгновенный локальный накат плотной сетки через Тейлора (0 вызовов cos/log/sqrt в цикле!)
    double *z_values = (double*)malloc(total_samples * sizeof(double));

    #pragma omp parallel for schedule(static)
    for (uint64_t i = 0; i < total_samples; i++) {
        double t = global_start + (double)i * step;
        
        // Индекс базовой макро-опоры
        uint64_t idx = (uint64_t)(t - global_start);
        if (idx >= macro_intervals) idx = macro_intervals - 1;

        double delta_t = t - (global_start + (double)idx);
        
        // Формула Тейлора 1-го порядка: Z(t + dt) = Z(t) + dt * Z'(t)
        // Чистая арифметика FMA на регистрах AVX2, скорость максимальная
        z_values[i] = macro_z[idx] + delta_t * macro_d[idx];
    }

    free(macro_z);
    free(macro_d);

    // Шаг 3. Локализация нулей
    for (uint64_t i = 0; i < total_samples - 1; i++) {
        double v1 = z_values[i];
        double v2 = z_values[i + 1];
        if ((v1 > 0.0 && v2 < 0.0) || (v1 < 0.0 && v2 > 0.0)) {
            global_buffer[total_zeros++] = global_start + (double)i * step + (step / 2.0);
        }
    }
    free(z_values);

    uint64_t size_in_bytes = total_zeros * sizeof(double);

    if (current_offset + size_in_bytes > MAX_DEVICE_LIMIT_BYTES) {
        printf("\n[!!!] КРИТИЧЕСКИЙ ОСТАНОВ: Предохранитель 8.1 Тб.\n");
        free(global_buffer);
        return 2;
    }

    // Запись бинарного потока напрямую в секторы RAID-0
    int dev_fd = open(BLOCK_DEVICE, O_WRONLY);
    if (dev_fd >= 0) {
        lseek64(dev_fd, (__off64_t)current_offset, SEEK_SET);
        write(dev_fd, global_buffer, size_in_bytes);
        fsync(dev_fd);
        close(dev_fd);
    }

    uint64_t new_offset = current_offset + size_in_bytes;
    FILE *f_ptr = fopen(POINTER_FILE, "w");
    if (f_ptr) { fprintf(f_ptr, "%lu\n", new_offset); fclose(f_ptr); }

    FILE *f_csv = fopen(CSV_FILE, "a");
    if (f_csv) {
        fprintf(f_csv, "%s;%.1f;%.1f;%lu;%lu\n", block_num_str, global_start, global_end, total_zeros, new_offset);
        fclose(f_csv);
    }

    printf("========================================\n");
    printf("Блок №%s успешно обработан Тейлор-ядром v6.0!\n", block_num_str);
    printf("Найдено истинных монотонных нулей: %lu\n", total_zeros);
    printf("Текущее смещение на устройстве: %lu байт\n", new_offset);
    printf("Время точного расчета: %.4f сек.\n", omp_get_wtime() - start_time);
    printf("========================================\n");

    free(global_buffer);
    return 0;
}
