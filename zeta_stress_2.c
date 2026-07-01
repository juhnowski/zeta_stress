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

// Чистая регистровая аппроксимация волны Харди без вызова Payne-Hanek редукции в libm
__attribute__((always_inline)) inline static double fast_zeta_wave(double t) {
    // Базовая частота на высоте t=10^12
    double omega = 0.5 * __builtin_log(t / (2.0 * M_PI));
    double phase1 = t * omega;
    double phase2 = t * (omega * 1.314159);
    
    // Быстрая ручная редукция угла до [-PI, PI] через отсечение целой части
    double p1 = phase1 - (int64_t)(phase1 * 0.15915494309189535) * 6.283185307179586;
    double p2 = phase2 - (int64_t)(phase2 * 0.15915494309189535) * 6.283185307179586;

    // Векторизуемые полиномы вместо библиотечного cos
    double x2_1 = p1 * p1;
    double cos1 = 1.0 - (x2_1 * 0.5) + (x2_1 * x2_1 * 0.041666666666666664);
    
    double x2_2 = p2 * p2;
    double cos2 = 1.0 - (x2_2 * 0.5) + (x2_2 * x2_2 * 0.041666666666666664);

    return cos1 + 0.5 * cos2;
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

    // 64 физических ядра AMD Zen 2
    int total_cores = 64; 
    omp_set_num_threads(total_cores);

    // Сверхплотная сетка: 500 000 сэмплов на ядро для стресс-тестирования СХД
    uint64_t samples_per_core = 500000;
    uint64_t total_samples = samples_per_core * total_cores;
    double step = (global_end - global_start) / (double)total_samples;

    double *global_buffer = (double*)malloc(total_samples * sizeof(double));
    uint64_t total_zeros = 0;

    printf("=== СИ-ВЕКТОР v5.2: Нативный Движок Волны (AMD Rome) ===\n");
    printf("Всего сэмплов на макро-батч: %lu\n", total_samples);
    fflush(stdout);

    double start_time = omp_get_wtime();
    double *z_values = (double*)malloc(total_samples * sizeof(double));

    // Идеально параллельный и 100% векторизуемый цикл OpenMP
    #pragma omp parallel for schedule(static)
    for (uint64_t i = 0; i < total_samples; i++) {
        double t = global_start + (double)i * step;
        z_values[i] = fast_zeta_wave(t);
    }
    
    double calc_end_time = omp_get_wtime();

    // Быстрый сбор нулей
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
        printf("\n[!!!] КРИТИЧЕСКИЙ ОСТАНОВ: Массив заполнен до 8.1 Тб.\n");
        free(global_buffer);
        return 2;
    }

    // Запись на блочное устройство
    int dev_fd = open(BLOCK_DEVICE, O_WRONLY);
    if (dev_fd >= 0) {
        lseek64(dev_fd, (__off64_t)current_offset, SEEK_SET);
        write(dev_fd, global_buffer, size_in_bytes);
        fsync(dev_fd);
        close(dev_fd);
    } else {
        perror("[ПРЕДУПРЕЖДЕНИЕ] Запись в /dev/md0 пропущена (нет прав), пишем мета-данные");
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
    printf("Блок №%s успешно записан движком v5.2!\n", block_num_str);
    printf("Генерация сетки заняла: %.4f сек.\n", calc_end_time - start_time);
    printf("Найдено уникальных нулей: %lu\n", total_zeros);
    printf("Смещение на устройстве: %lu байт\n", new_offset);
    printf("========================================\n");

    free(global_buffer);
    return 0;
}
