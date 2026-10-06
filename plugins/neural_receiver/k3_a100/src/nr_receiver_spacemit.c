#define _GNU_SOURCE

#include "receiver_spacemit_runtime.h"

#include <alloca.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>

#include "common/utils/time_meas.h"
#include "openair1/PHY/defs_gNB.h"
#include "openair1/PHY/defs_nr_common.h"

/* The real OAI executable provides a strong symbol. The weak default keeps the
 * standalone smoke test usable while preserving OAI's normal -q control. */
__attribute__((weak)) int cpu_meas_enabled = 1;

static time_stats_t receiver_input_stats;
static time_stats_t receiver_inference_stats;
static time_stats_t receiver_output_stats;
static time_stats_t receiver_total_stats;
static pthread_mutex_t receiver_stats_mutex = PTHREAD_MUTEX_INITIALIZER;

static void print_one_stat(const char *name, const time_stats_t *stats) {
  if (!stats->trials) {
    printf("NEURAL_RECEIVER_TIME name=%s calls=0\n", name);
    return;
  }
  /* K3's OAI rdtsc_oai() is CLOCK_MONOTONIC_RAW in nanoseconds. */
  printf("NEURAL_RECEIVER_TIME name=%s calls=%d avg_us=%.3f max_us=%.3f\n",
         name,
         stats->trials,
         (double)stats->diff / (double)stats->trials / 1000.0,
         (double)stats->max / 1000.0);
}

static void print_receiver_stats(void) {
  print_one_stat("input", &receiver_input_stats);
  print_one_stat("a100_inference", &receiver_inference_stats);
  print_one_stat("llr_output", &receiver_output_stats);
  print_one_stat("total", &receiver_total_stats);
  fflush(stdout);
}

static void close_active_measurement(time_stats_t *stats) {
  if (stats->meas_flag) stop_meas(stats);
}

static void merge_receiver_stats(PHY_VARS_gNB *gNB,
                                 const time_stats_t *input,
                                 const time_stats_t *inference,
                                 const time_stats_t *output,
                                 const time_stats_t *total) {
  pthread_mutex_lock(&receiver_stats_mutex);
  merge_meas(&receiver_input_stats, input);
  merge_meas(&receiver_inference_stats, inference);
  merge_meas(&receiver_output_stats, output);
  merge_meas(&receiver_total_stats, total);
  /* Optional for an OAI binary rebuilt with the task-3 timing fields. The
   * default plugin remains ABI-compatible with the stable PHY-fixed binary. */
#ifdef OAI_RECEIVER_TIMING_FIELDS
  merge_meas(&gNB->neural_receiver_input_stats, input);
  merge_meas(&gNB->neural_receiver_inference_stats, inference);
  merge_meas(&gNB->neural_receiver_output_stats, output);
  merge_meas(&gNB->neural_receiver_total_stats, total);
#else
  (void)gNB;
#endif
  if (receiver_total_stats.trials <= 3 ||
      receiver_total_stats.trials % 100 == 0)
    print_receiver_stats();
  pthread_mutex_unlock(&receiver_stats_mutex);
}

int32_t receiver_init(void) {
  return spacemit_receiver_runtime_init();
}

int32_t receiver_init_thread(void) {
  /* SpaceMIT EP is deliberately serialized until its multi-thread crash is
   * fixed. There is one process-wide session, so no per-thread context. */
  return 0;
}

int32_t receiver_shutdown(void) {
  pthread_mutex_lock(&receiver_stats_mutex);
  print_receiver_stats();
  pthread_mutex_unlock(&receiver_stats_mutex);
  return spacemit_receiver_runtime_shutdown();
}

int receiver_symbols_requested(NR_DL_FRAME_PARMS *frame_parms) {
  (void)frame_parms;
  return -1;
}

int receiver_compute_llr(PHY_VARS_gNB *gNB,
                         int ulsch_id,
                         int slot,
                         frame_t frame,
                         NR_DL_FRAME_PARMS *frame_parms,
                         NR_gNB_PUSCH *pusch_vars,
                         nfapi_nr_pusch_pdu_t *rel15_ul,
                         c16_t **rxFs,
                         c16_t **ul_chs,
                         int16_t *llr,
                         int soffset,
                         int16_t const *lengths,
                         int start_symbol,
                         int num_symbols,
                         int output_shift,
                         uint32_t nvar) {
  (void)gNB;
  (void)ulsch_id;
  (void)slot;
  (void)frame;
  (void)ul_chs;
  (void)lengths;
  (void)output_shift;
  (void)nvar;

  if (!frame_parms || !pusch_vars || !rel15_ul || !rxFs || !rxFs[0] ||
      !llr)
    return 0;

  /* First functional version: Spark's trained contract is 16QAM, one layer,
   * at most 24 PRB, 13 symbols and three DMRS symbols. Other grants cleanly
   * fall back to OAI's conventional receiver. */
  if (rel15_ul->qam_mod_order != 4 || rel15_ul->rb_size == 0 ||
      rel15_ul->rb_size > 24 || rel15_ul->nrOfLayers != 1 ||
      start_symbol != 0 || num_symbols != 13 ||
      frame_parms->symbols_per_slot - 1 != 13)
    return 0;

  int32_t dmrs_positions[12] = {0};
  uint32_t num_dmrs = 0;
  uint32_t mask = rel15_ul->ul_dmrs_symb_pos & ((1U << 12) - 1U);
  while (mask && num_dmrs < 12) {
    dmrs_positions[num_dmrs] = __builtin_ffs(mask) - 1;
    mask ^= 1U << dmrs_positions[num_dmrs++];
  }
  if (num_dmrs != 3) return 0;

  time_stats_t input_stats = {0};
  time_stats_t inference_stats = {0};
  time_stats_t output_stats = {0};
  time_stats_t total_stats = {0};
  start_meas(&total_stats);
  start_meas(&input_stats);

  const int num_ofdm_symbols = 13;
  const int re_per_symbol = 12 * rel15_ul->rb_size;
  const int start_re =
      (frame_parms->first_carrier_offset +
       (rel15_ul->rb_start + rel15_ul->bwp_start) * 12) %
      frame_parms->ofdm_symbol_size;

  c16_t *symbols = alloca(sizeof(*symbols) * re_per_symbol *
                          num_ofdm_symbols);
  c16_t *h_hat = alloca(sizeof(*h_hat) * (re_per_symbol / 2) * num_dmrs);
  int16_t *outputs = alloca(sizeof(*outputs) * re_per_symbol *
                            num_ofdm_symbols * 4);
  memset(symbols, 0, sizeof(*symbols) * re_per_symbol * num_ofdm_symbols);
  memset(h_hat, 0, sizeof(*h_hat) * (re_per_symbol / 2) * num_dmrs);

  /* Accumulate power and normalize once. The previous online mean performed
   * a floating-point division for every RE in this hot input path. */
  uint64_t power_sum = 0;
  for (int symbol = 0; symbol < num_symbols; ++symbol) {
    c16_t *rxF = (c16_t *)rxFs[0] +
                 symbol * frame_parms->ofdm_symbol_size + soffset;
    for (int i = 0, k = start_re; i < re_per_symbol;
         ++i, k = (k + 1 < frame_parms->ofdm_symbol_size) ? k + 1 : 0) {
      const c16_t sample = rxF[k];
      symbols[num_ofdm_symbols * i + symbol] = sample;
      const int32_t real = sample.r;
      const int32_t imag = sample.i;
      power_sum += (uint64_t)((int64_t)real * real + (int64_t)imag * imag);
    }
  }
  const float mean_power =
      (float)((double)power_sum /
              ((double)re_per_symbol * num_ofdm_symbols * 65536.0));
  if (!isfinite(mean_power) || mean_power <= 0.0f) return 0;
  const float norm_scale = 1.0f / sqrtf(mean_power);

  for (uint32_t d = 0; d < num_dmrs; ++d) {
    const int dmrs_symbol = dmrs_positions[d];
    c16_t *estimate =
        (c16_t *)pusch_vars->ul_ch_estimates[0] +
        dmrs_symbol * frame_parms->ofdm_symbol_size;
    for (int i = 0, pilot = 0; i < re_per_symbol; i += 2, ++pilot)
      h_hat[pilot + d * re_per_symbol / 2] = estimate[i];
  }

  const int16_t port_mask[] = {1};
  const int32_t subcarrier_positions[] = {0, 2, 4, 6, 8, 10};
  if (!spacemit_receiver_decode(
          port_mask, 1, (const int16_t *)symbols, re_per_symbol,
          num_ofdm_symbols, norm_scale, (const int16_t *)h_hat, num_dmrs,
          dmrs_positions, subcarrier_positions, outputs, &input_stats,
          &inference_stats, &output_stats)) {
    close_active_measurement(&input_stats);
    close_active_measurement(&inference_stats);
    close_active_measurement(&output_stats);
    close_active_measurement(&total_stats);
    return 0;
  }

  for (int symbol = 0; symbol < num_symbols; ++symbol) {
    int16_t *symbol_llr = &llr[pusch_vars->llr_offset[symbol]];
    const int is_dmrs =
        (rel15_ul->ul_dmrs_symb_pos & (1U << symbol)) != 0;
    for (int sc = is_dmrs, out_sc = 0; sc < re_per_symbol;
         sc += 1 + is_dmrs, ++out_sc) {
      for (int bit = 0; bit < 4; ++bit) {
        const int16_t raw =
            outputs[(symbol + sc * num_ofdm_symbols) * 4 + bit];
        int16_t value = raw / 256;
        if (value > 255) value = 255;
        if (value < -255) value = -255;
        symbol_llr[out_sc * 4 + bit] = value ? value : (raw < 0 ? -1 : 1);
      }
    }
  }

  close_active_measurement(&output_stats);
  close_active_measurement(&total_stats);
  merge_receiver_stats(gNB, &input_stats, &inference_stats, &output_stats,
                       &total_stats);

  return 1;
}
