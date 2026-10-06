#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int spacemit_receiver_runtime_init(void);
int spacemit_receiver_runtime_shutdown(void);

int spacemit_receiver_decode(const int16_t *active_ports,
                             size_t num_tx,
                             const int16_t *symbols,
                             size_t num_subcarriers,
                             size_t num_ofdm_symbols,
                             float norm_scale,
                             const int16_t *h_hat,
                             size_t num_dmrs_symbols,
                             const int32_t *dmrs_ofdm_pos,
                             const int32_t *dmrs_subcarrier_pos,
                             int16_t *outputs,
                             void *input_stats,
                             void *inference_stats,
                             void *output_stats);

#ifdef __cplusplus
}
#endif
