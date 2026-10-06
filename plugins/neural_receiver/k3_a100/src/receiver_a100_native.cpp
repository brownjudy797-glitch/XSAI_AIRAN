#include "receiver_spacemit_runtime.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>

#include <riscv_vector.h>
#include "common/utils/time_meas.h"

extern "C" int a100_worker_start(void);
extern "C" int a100_worker_call(void (*fn)(void *), void *arg);
extern "C" void a100_worker_stop(void);
extern "C" int a100_worker_pool_start(void);
extern "C" int a100_worker_pool_call(void (*fn)(void *),
                                      void *const args[4], unsigned mask);
extern "C" void a100_worker_pool_stop(void);

namespace {
#ifndef K3NRX_BATCH
#define K3NRX_BATCH 128
#endif
#ifndef K3NRX_INPUT
#define K3NRX_INPUT 4
#endif
#ifndef K3NRX_HIDDEN
#define K3NRX_HIDDEN 32
#endif
#ifndef K3NRX_BLOCK4
#define K3NRX_BLOCK4 0
#endif
#ifndef K3NRX_BLOCK8
#define K3NRX_BLOCK8 0
#endif
#ifndef K3NRX_PROFILE
#define K3NRX_PROFILE 0
#endif
#ifndef K3NRX_HCACHE
#define K3NRX_HCACHE 0
#endif
#ifndef K3NRX_WORKERS
#define K3NRX_WORKERS 1
#endif
static_assert(K3NRX_WORKERS == 1 || K3NRX_WORKERS == 2 ||
              K3NRX_WORKERS == 4);
constexpr size_t kInput = K3NRX_INPUT;
constexpr size_t kHidden = K3NRX_HIDDEN;
constexpr size_t kOutput = 4;
constexpr size_t kBatch = K3NRX_BATCH;
constexpr size_t kWeightCount =
    kInput * kHidden + kHidden + kHidden * kHidden + kHidden +
    kHidden * kOutput + kOutput;

struct WeightHeader {
  char magic[8];
  uint32_t input;
  uint32_t hidden1;
  uint32_t hidden2;
  uint32_t output;
};

struct Scratch {
  alignas(64) float inputs[kInput][kBatch];
  alignas(64) float hidden1[kHidden][kBatch];
  alignas(64) float hidden2[kHidden][kBatch];
  alignas(64) float outputs[kOutput][kBatch];
};

struct Request {
  const int16_t *symbols;
  const int16_t *channel;
  size_t subcarriers;
  float scale;
  const int32_t *dmrs_positions;
  int16_t *outputs;
#if K3NRX_WORKERS > 1
  size_t first_element;
  size_t last_element;
  Scratch *scratch;
#endif
};

std::mutex g_mutex;
std::unique_ptr<float[]> g_weights;
std::unique_ptr<Scratch> g_scratch;
#if K3NRX_WORKERS > 1
std::unique_ptr<Scratch> g_scratch_second;
#endif
#if K3NRX_WORKERS == 4
std::unique_ptr<Scratch> g_scratch_third;
std::unique_ptr<Scratch> g_scratch_fourth;
#endif
const float *g_w1, *g_b1, *g_w2, *g_b2, *g_w3, *g_b3;
unsigned long long g_calls = 0;
unsigned long long g_total_us = 0;
#if K3NRX_PROFILE
unsigned long long g_preprocess_ns = 0;
unsigned long long g_channel_cache_ns = 0;
unsigned long long g_input_pack_ns = 0;
unsigned long long g_dense_ns = 0;
unsigned long long g_quantize_ns = 0;
#endif
float g_llr_gain = 1.0f;
bool g_interpolate_channel = false;

bool load_weights() {
  const char *path = std::getenv("XSAI_RECEIVER_NATIVE_WEIGHTS");
  if (!path || !path[0])
    path = "/home/ubuntu/sionna-rk/.work-neural-receiver-a100/models/"
           "k3_native_joint.sionna.weights";
  FILE *file = std::fopen(path, "rb");
  if (!file) {
    std::fprintf(stderr, "K3 native receiver: missing weights %s\n", path);
    return false;
  }
  WeightHeader header{};
  bool valid = std::fread(&header, sizeof(header), 1, file) == 1 &&
               std::memcmp(header.magic, "K3NRX001", 8) == 0 &&
               header.input == kInput && header.hidden1 == kHidden &&
               header.hidden2 == kHidden && header.output == kOutput;
  auto values = std::make_unique<float[]>(kWeightCount);
  valid = valid &&
          std::fread(values.get(), sizeof(float), kWeightCount, file) ==
              kWeightCount &&
          std::fgetc(file) == EOF;
  std::fclose(file);
  if (!valid) {
    std::fprintf(stderr, "K3 native receiver: invalid weights %s\n", path);
    return false;
  }
  const float *cursor = values.get();
  g_w1 = cursor; cursor += kInput * kHidden;
  g_b1 = cursor; cursor += kHidden;
  g_w2 = cursor; cursor += kHidden * kHidden;
  g_b2 = cursor; cursor += kHidden;
  g_w3 = cursor; cursor += kHidden * kOutput;
  g_b3 = cursor;
  g_weights = std::move(values);
  return true;
}

#if K3NRX_BLOCK4 || K3NRX_BLOCK8
template <size_t Inputs, size_t Outputs, bool Relu>
inline void infer_layer(const float (&input)[Inputs][kBatch],
                        float (&output)[Outputs][kBatch],
                        const float *weights, const float *bias,
                        size_t count) {
  static_assert(Outputs % 4 == 0);
  for (size_t out = 0; out < Outputs; out += 4) {
    for (size_t offset = 0; offset < count;) {
      const size_t vl = __riscv_vsetvl_e32m4(count - offset);
      vfloat32m4_t v0 = __riscv_vfmv_v_f_f32m4(bias[out], vl);
      vfloat32m4_t v1 = __riscv_vfmv_v_f_f32m4(bias[out + 1], vl);
      vfloat32m4_t v2 = __riscv_vfmv_v_f_f32m4(bias[out + 2], vl);
      vfloat32m4_t v3 = __riscv_vfmv_v_f_f32m4(bias[out + 3], vl);
      for (size_t in = 0; in < Inputs; ++in) {
        const vfloat32m4_t x =
            __riscv_vle32_v_f32m4(input[in] + offset, vl);
        const float *row = weights + in * Outputs + out;
        v0 = __riscv_vfmacc_vf_f32m4(v0, row[0], x, vl);
        v1 = __riscv_vfmacc_vf_f32m4(v1, row[1], x, vl);
        v2 = __riscv_vfmacc_vf_f32m4(v2, row[2], x, vl);
        v3 = __riscv_vfmacc_vf_f32m4(v3, row[3], x, vl);
      }
      if constexpr (Relu) {
        v0 = __riscv_vfmax_vf_f32m4(v0, 0.0f, vl);
        v1 = __riscv_vfmax_vf_f32m4(v1, 0.0f, vl);
        v2 = __riscv_vfmax_vf_f32m4(v2, 0.0f, vl);
        v3 = __riscv_vfmax_vf_f32m4(v3, 0.0f, vl);
      }
      __riscv_vse32_v_f32m4(output[out] + offset, v0, vl);
      __riscv_vse32_v_f32m4(output[out + 1] + offset, v1, vl);
      __riscv_vse32_v_f32m4(output[out + 2] + offset, v2, vl);
      __riscv_vse32_v_f32m4(output[out + 3] + offset, v3, vl);
      offset += vl;
    }
  }
}
#endif

#if K3NRX_BLOCK8
template <size_t Inputs, size_t Outputs>
inline void infer_hidden8(const float (&input)[Inputs][kBatch],
                          float (&output)[Outputs][kBatch],
                          const float *weights, const float *bias,
                          size_t count) {
  static_assert(Outputs % 8 == 0);
  for (size_t out = 0; out < Outputs; out += 8) {
    for (size_t offset = 0; offset < count;) {
      const size_t vl = __riscv_vsetvl_e32m2(count - offset);
      vfloat32m2_t v0 = __riscv_vfmv_v_f_f32m2(bias[out], vl);
      vfloat32m2_t v1 = __riscv_vfmv_v_f_f32m2(bias[out + 1], vl);
      vfloat32m2_t v2 = __riscv_vfmv_v_f_f32m2(bias[out + 2], vl);
      vfloat32m2_t v3 = __riscv_vfmv_v_f_f32m2(bias[out + 3], vl);
      vfloat32m2_t v4 = __riscv_vfmv_v_f_f32m2(bias[out + 4], vl);
      vfloat32m2_t v5 = __riscv_vfmv_v_f_f32m2(bias[out + 5], vl);
      vfloat32m2_t v6 = __riscv_vfmv_v_f_f32m2(bias[out + 6], vl);
      vfloat32m2_t v7 = __riscv_vfmv_v_f_f32m2(bias[out + 7], vl);
      for (size_t in = 0; in < Inputs; ++in) {
        const vfloat32m2_t x =
            __riscv_vle32_v_f32m2(input[in] + offset, vl);
        const float *row = weights + in * Outputs + out;
        v0 = __riscv_vfmacc_vf_f32m2(v0, row[0], x, vl);
        v1 = __riscv_vfmacc_vf_f32m2(v1, row[1], x, vl);
        v2 = __riscv_vfmacc_vf_f32m2(v2, row[2], x, vl);
        v3 = __riscv_vfmacc_vf_f32m2(v3, row[3], x, vl);
        v4 = __riscv_vfmacc_vf_f32m2(v4, row[4], x, vl);
        v5 = __riscv_vfmacc_vf_f32m2(v5, row[5], x, vl);
        v6 = __riscv_vfmacc_vf_f32m2(v6, row[6], x, vl);
        v7 = __riscv_vfmacc_vf_f32m2(v7, row[7], x, vl);
      }
      v0 = __riscv_vfmax_vf_f32m2(v0, 0.0f, vl);
      v1 = __riscv_vfmax_vf_f32m2(v1, 0.0f, vl);
      v2 = __riscv_vfmax_vf_f32m2(v2, 0.0f, vl);
      v3 = __riscv_vfmax_vf_f32m2(v3, 0.0f, vl);
      v4 = __riscv_vfmax_vf_f32m2(v4, 0.0f, vl);
      v5 = __riscv_vfmax_vf_f32m2(v5, 0.0f, vl);
      v6 = __riscv_vfmax_vf_f32m2(v6, 0.0f, vl);
      v7 = __riscv_vfmax_vf_f32m2(v7, 0.0f, vl);
      __riscv_vse32_v_f32m2(output[out] + offset, v0, vl);
      __riscv_vse32_v_f32m2(output[out + 1] + offset, v1, vl);
      __riscv_vse32_v_f32m2(output[out + 2] + offset, v2, vl);
      __riscv_vse32_v_f32m2(output[out + 3] + offset, v3, vl);
      __riscv_vse32_v_f32m2(output[out + 4] + offset, v4, vl);
      __riscv_vse32_v_f32m2(output[out + 5] + offset, v5, vl);
      __riscv_vse32_v_f32m2(output[out + 6] + offset, v6, vl);
      __riscv_vse32_v_f32m2(output[out + 7] + offset, v7, vl);
      offset += vl;
    }
  }
}
#endif

inline void infer_batch(Scratch &scratch, size_t count) {
#if K3NRX_BLOCK8
  infer_hidden8<kInput, kHidden>(scratch.inputs, scratch.hidden1,
                                  g_w1, g_b1, count);
  infer_hidden8<kHidden, kHidden>(scratch.hidden1, scratch.hidden2,
                                   g_w2, g_b2, count);
  infer_layer<kHidden, kOutput, false>(scratch.hidden2, scratch.outputs,
                                        g_w3, g_b3, count);
#elif K3NRX_BLOCK4
  infer_layer<kInput, kHidden, true>(scratch.inputs, scratch.hidden1,
                                      g_w1, g_b1, count);
  infer_layer<kHidden, kHidden, true>(scratch.hidden1, scratch.hidden2,
                                       g_w2, g_b2, count);
  infer_layer<kHidden, kOutput, false>(scratch.hidden2, scratch.outputs,
                                        g_w3, g_b3, count);
#else
  for (size_t out = 0; out < kHidden; ++out) {
    for (size_t offset = 0; offset < count;) {
      const size_t vl = __riscv_vsetvl_e32m4(count - offset);
      vfloat32m4_t value = __riscv_vfmv_v_f_f32m4(g_b1[out], vl);
      for (size_t in = 0; in < kInput; ++in) {
        const vfloat32m4_t input =
            __riscv_vle32_v_f32m4(scratch.inputs[in] + offset, vl);
        value = __riscv_vfmacc_vf_f32m4(
            value, g_w1[in * kHidden + out], input, vl);
      }
      value = __riscv_vfmax_vf_f32m4(value, 0.0f, vl);
      __riscv_vse32_v_f32m4(scratch.hidden1[out] + offset, value, vl);
      offset += vl;
    }
  }
  for (size_t out = 0; out < kHidden; ++out) {
    for (size_t offset = 0; offset < count;) {
      const size_t vl = __riscv_vsetvl_e32m4(count - offset);
      vfloat32m4_t value = __riscv_vfmv_v_f_f32m4(g_b2[out], vl);
      for (size_t in = 0; in < kHidden; ++in) {
        const vfloat32m4_t input =
            __riscv_vle32_v_f32m4(scratch.hidden1[in] + offset, vl);
        value = __riscv_vfmacc_vf_f32m4(
            value, g_w2[in * kHidden + out], input, vl);
      }
      value = __riscv_vfmax_vf_f32m4(value, 0.0f, vl);
      __riscv_vse32_v_f32m4(scratch.hidden2[out] + offset, value, vl);
      offset += vl;
    }
  }
  for (size_t out = 0; out < kOutput; ++out) {
    for (size_t offset = 0; offset < count;) {
      const size_t vl = __riscv_vsetvl_e32m4(count - offset);
      vfloat32m4_t value = __riscv_vfmv_v_f_f32m4(g_b3[out], vl);
      for (size_t in = 0; in < kHidden; ++in) {
        const vfloat32m4_t input =
            __riscv_vle32_v_f32m4(scratch.hidden2[in] + offset, vl);
        value = __riscv_vfmacc_vf_f32m4(
            value, g_w3[in * kOutput + out], input, vl);
      }
      __riscv_vse32_v_f32m4(scratch.outputs[out] + offset, value, vl);
      offset += vl;
    }
  }
#endif
}

inline int16_t quantize(float value) {
  if (!std::isfinite(value)) return 0;
  return static_cast<int16_t>(
      std::clamp(std::nearbyint(value * 256.0f), -32768.0f, 32767.0f));
}

void run_on_a100(void *opaque) {
  const auto &request = *static_cast<Request *>(opaque);
  const size_t pilots_per_dmrs = request.subcarriers / 2;
  const size_t elements = request.subcarriers * 13;
#if K3NRX_WORKERS > 1
  Scratch &scratch = *request.scratch;
  const size_t first_element = request.first_element;
  const size_t last_element = request.last_element;
  const size_t first_subcarrier = first_element / 13;
  const size_t last_subcarrier = (last_element + 12) / 13;
#else
  Scratch &scratch = *g_scratch;
  const size_t first_element = 0;
  const size_t last_element = elements;
  const size_t first_subcarrier = 0;
  const size_t last_subcarrier = request.subcarriers;
#endif
#if K3NRX_HCACHE
#if K3NRX_PROFILE
  const auto cache_start = std::chrono::steady_clock::now();
#endif
  alignas(64) float channel_cache[288 * 13 * 2];
  if (g_interpolate_channel) {
    size_t first_dmrs[13];
    size_t second_dmrs[13];
    float time_fractions[13];
    for (size_t symbol = 0; symbol < 13; ++symbol) {
      first_dmrs[symbol] = second_dmrs[symbol] = 0;
      time_fractions[symbol] = 0.0f;
      if (symbol > static_cast<size_t>(request.dmrs_positions[0])) {
        first_dmrs[symbol] = symbol < static_cast<size_t>(request.dmrs_positions[1]) ? 0 : 1;
        second_dmrs[symbol] = first_dmrs[symbol] + 1;
        if (symbol >= static_cast<size_t>(request.dmrs_positions[2])) {
          first_dmrs[symbol] = second_dmrs[symbol] = 2;
        } else {
          time_fractions[symbol] =
              float(symbol - request.dmrs_positions[first_dmrs[symbol]]) /
              float(request.dmrs_positions[second_dmrs[symbol]] -
                    request.dmrs_positions[first_dmrs[symbol]]);
        }
      }
    }
    for (size_t subcarrier = first_subcarrier;
         subcarrier < last_subcarrier; ++subcarrier) {
      const size_t first_pilot = subcarrier / 2;
      const size_t second_pilot = first_pilot +
          ((subcarrier & 1) && first_pilot + 1 < pilots_per_dmrs);
      const float frequency_fraction = (subcarrier & 1) ? 0.5f : 0.0f;
      float pilot_values[3][2];
      for (size_t dmrs = 0; dmrs < 3; ++dmrs) {
        for (size_t component = 0; component < 2; ++component) {
          const float a = request.channel[
              (dmrs * pilots_per_dmrs + first_pilot) * 2 + component];
          const float b = request.channel[
              (dmrs * pilots_per_dmrs + second_pilot) * 2 + component];
          pilot_values[dmrs][component] =
              a + frequency_fraction * (b - a);
        }
      }
      for (size_t symbol = 0; symbol < 13; ++symbol) {
        for (size_t component = 0; component < 2; ++component) {
          const float h0 = pilot_values[first_dmrs[symbol]][component];
          const float h1 = pilot_values[second_dmrs[symbol]][component];
          channel_cache[(subcarrier * 13 + symbol) * 2 + component] =
              (h0 + time_fractions[symbol] * (h1 - h0)) * request.scale;
        }
      }
    }
  }
#if K3NRX_PROFILE
  const auto cache_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
      std::chrono::steady_clock::now() - cache_start).count();
  g_channel_cache_ns += cache_ns;
  g_preprocess_ns += cache_ns;
#endif
#endif
  for (size_t base = first_element; base < last_element; base += kBatch) {
#if K3NRX_PROFILE
    const auto stage_start = std::chrono::steady_clock::now();
#endif
    const size_t count = std::min(kBatch, last_element - base);
    for (size_t re = 0; re < count; ++re) {
      const size_t index = base + re;
      const size_t subcarrier = index / 13;
      const int symbol = static_cast<int>(index % 13);
      const size_t iq = index * 2;
      scratch.inputs[0][re] = request.symbols[iq] * request.scale;
      scratch.inputs[1][re] = request.symbols[iq + 1] * request.scale;
      if (g_interpolate_channel) {
#if K3NRX_HCACHE
        scratch.inputs[2][re] = channel_cache[index * 2];
        scratch.inputs[3][re] = channel_cache[index * 2 + 1];
#else
        size_t first_dmrs = 0;
        size_t second_dmrs = 0;
        float time_fraction = 0.0f;
        if (symbol > request.dmrs_positions[0]) {
          first_dmrs = symbol < request.dmrs_positions[1] ? 0 : 1;
          second_dmrs = first_dmrs + 1;
          if (symbol >= request.dmrs_positions[2]) {
            first_dmrs = 2;
            second_dmrs = 2;
          } else {
            time_fraction = float(symbol - request.dmrs_positions[first_dmrs]) /
                float(request.dmrs_positions[second_dmrs] -
                      request.dmrs_positions[first_dmrs]);
          }
        }
        const size_t first_pilot = subcarrier / 2;
        const size_t second_pilot =
            first_pilot + ((subcarrier & 1) && first_pilot + 1 < pilots_per_dmrs);
        const float frequency_fraction = (subcarrier & 1) ? 0.5f : 0.0f;
        for (size_t component = 0; component < 2; ++component) {
          const float a = request.channel[
              (first_dmrs * pilots_per_dmrs + first_pilot) * 2 + component];
          const float b = request.channel[
              (first_dmrs * pilots_per_dmrs + second_pilot) * 2 + component];
          const float c = request.channel[
              (second_dmrs * pilots_per_dmrs + first_pilot) * 2 + component];
          const float d = request.channel[
              (second_dmrs * pilots_per_dmrs + second_pilot) * 2 + component];
          const float h0 = a + frequency_fraction * (b - a);
          const float h1 = c + frequency_fraction * (d - c);
          scratch.inputs[2 + component][re] =
              (h0 + time_fraction * (h1 - h0)) * request.scale;
        }
#endif
      } else {
        size_t closest_dmrs = 0;
        for (size_t dmrs = 1; dmrs < 3; ++dmrs)
          if (std::abs(symbol - request.dmrs_positions[dmrs]) <
              std::abs(symbol - request.dmrs_positions[closest_dmrs]))
            closest_dmrs = dmrs;
        const size_t pilot = closest_dmrs * pilots_per_dmrs + subcarrier / 2;
        const size_t channel_iq = pilot * 2;
        scratch.inputs[2][re] = request.channel[channel_iq] * request.scale;
        scratch.inputs[3][re] = request.channel[channel_iq + 1] * request.scale;
      }
      if constexpr (kInput == 6) {
        const float yr = scratch.inputs[0][re];
        const float yi = scratch.inputs[1][re];
        const float hr = scratch.inputs[2][re];
        const float hi = scratch.inputs[3][re];
        const float inverse = 1.0f / (hr * hr + hi * hi + 0.05f);
        scratch.inputs[4][re] = (yr * hr + yi * hi) * inverse;
        scratch.inputs[5][re] = (yi * hr - yr * hi) * inverse;
      }
    }
#if K3NRX_PROFILE
    const auto preprocess_end = std::chrono::steady_clock::now();
#endif
    infer_batch(scratch, count);
#if K3NRX_PROFILE
    const auto dense_end = std::chrono::steady_clock::now();
#endif
    for (size_t re = 0; re < count; ++re)
      for (size_t bit = 0; bit < kOutput; ++bit)
        // Sionna's LLR sign is opposite to the OAI/Aerial receiver ABI.
        request.outputs[(base + re) * kOutput + bit] =
            quantize(-g_llr_gain * scratch.outputs[bit][re]);
#if K3NRX_PROFILE
    const auto quantize_end = std::chrono::steady_clock::now();
    const auto input_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
        preprocess_end - stage_start).count();
    g_input_pack_ns += input_ns;
    g_preprocess_ns += input_ns;
    g_dense_ns += std::chrono::duration_cast<std::chrono::nanoseconds>(
        dense_end - preprocess_end).count();
    g_quantize_ns += std::chrono::duration_cast<std::chrono::nanoseconds>(
        quantize_end - dense_end).count();
#endif
  }
}
}  // namespace

extern "C" int spacemit_receiver_runtime_init(void) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_weights) return 0;
  const char *gain_text = std::getenv("XSAI_RECEIVER_LLR_GAIN");
  if (gain_text && gain_text[0]) {
    char *end = nullptr;
    g_llr_gain = std::strtof(gain_text, &end);
    if (end == gain_text || *end || !std::isfinite(g_llr_gain) ||
        g_llr_gain <= 0.0f || g_llr_gain > 32.0f)
      return -1;
  }
  const char *interpolate_text = std::getenv("XSAI_RECEIVER_H_INTERP");
  g_interpolate_channel = interpolate_text &&
      std::strcmp(interpolate_text, "1") == 0;
  if (!load_weights()) return -1;
  g_scratch = std::make_unique<Scratch>();
#if K3NRX_WORKERS > 1
  g_scratch_second = std::make_unique<Scratch>();
#if K3NRX_WORKERS == 4
  g_scratch_third = std::make_unique<Scratch>();
  g_scratch_fourth = std::make_unique<Scratch>();
#endif
  const int worker_status = a100_worker_pool_start();
#else
  const int worker_status = a100_worker_start();
#endif
  if (worker_status != 0) {
    g_scratch.reset();
#if K3NRX_WORKERS > 1
    g_scratch_second.reset();
#if K3NRX_WORKERS == 4
    g_scratch_third.reset();
    g_scratch_fourth.reset();
#endif
#endif
    g_weights.reset();
    return -1;
  }
#if K3NRX_WORKERS == 4
  std::printf("K3_NATIVE_JOINT_RECEIVER ready=1 ai_cpu=8-11 workers=4 batch=%zu "
              "weights=%zu llr_gain=%.3f h_interp=%d\n",
              kBatch, kWeightCount, g_llr_gain, g_interpolate_channel);
#elif K3NRX_WORKERS == 2
  std::printf("K3_NATIVE_JOINT_RECEIVER ready=1 ai_cpu=8,9 workers=2 batch=%zu "
              "weights=%zu llr_gain=%.3f h_interp=%d\n",
              kBatch, kWeightCount, g_llr_gain, g_interpolate_channel);
#else
  std::printf("K3_NATIVE_JOINT_RECEIVER ready=1 ai_cpu=8 batch=%zu "
              "weights=%zu llr_gain=%.3f h_interp=%d\n",
              kBatch, kWeightCount, g_llr_gain, g_interpolate_channel);
#endif
  return 0;
}

extern "C" int spacemit_receiver_runtime_shutdown(void) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_weights) {
#if K3NRX_WORKERS > 1
    a100_worker_pool_stop();
#else
    a100_worker_stop();
#endif
  }
  std::printf("K3_NATIVE_JOINT_RECEIVER calls=%llu avg_us=%llu\n",
              g_calls, g_calls ? g_total_us / g_calls : 0);
#if K3NRX_PROFILE
  if (g_calls) {
    std::printf("K3_NATIVE_STAGE avg_us preprocess=%.3f "
                "channel_cache=%.3f input_pack=%.3f dense=%.3f "
                "quantize=%.3f\n",
                (double)g_preprocess_ns / g_calls / 1000.0,
                (double)g_channel_cache_ns / g_calls / 1000.0,
                (double)g_input_pack_ns / g_calls / 1000.0,
                (double)g_dense_ns / g_calls / 1000.0,
                (double)g_quantize_ns / g_calls / 1000.0);
  }
#endif
  g_scratch.reset();
#if K3NRX_WORKERS > 1
  g_scratch_second.reset();
#if K3NRX_WORKERS == 4
  g_scratch_third.reset();
  g_scratch_fourth.reset();
#endif
#endif
  g_weights.reset();
  return 0;
}

extern "C" int spacemit_receiver_decode(
    const int16_t *active_ports, size_t num_tx,
    const int16_t *symbols, size_t num_subcarriers,
    size_t num_ofdm_symbols, float norm_scale,
    const int16_t *h_hat, size_t num_dmrs_symbols,
    const int32_t *dmrs_ofdm_pos,
    const int32_t *dmrs_subcarrier_pos, int16_t *outputs,
    void *input_stats_ptr, void *inference_stats_ptr, void *output_stats_ptr) {
  (void)dmrs_subcarrier_pos;
  auto *input_stats = static_cast<time_stats_t *>(input_stats_ptr);
  auto *inference_stats = static_cast<time_stats_t *>(inference_stats_ptr);
  auto *output_stats = static_cast<time_stats_t *>(output_stats_ptr);
  if (!active_ports || !active_ports[0] || num_tx != 1 || !symbols || !h_hat ||
      !outputs || !dmrs_ofdm_pos || num_subcarriers == 0 ||
      num_subcarriers > 288 || num_subcarriers % 12 ||
      num_ofdm_symbols != 13 || num_dmrs_symbols != 3 ||
      !std::isfinite(norm_scale) || norm_scale <= 0.0f)
    return 0;
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_weights) return 0;
  Request request{symbols, h_hat, num_subcarriers,
                  norm_scale / 256.0f, dmrs_ofdm_pos, outputs};
#if K3NRX_WORKERS > 1
  const size_t elements = num_subcarriers * 13;
  const size_t active_workers = num_subcarriers <= 12 ? 1 :
#if K3NRX_WORKERS == 4
      (num_subcarriers >= 288 ? 4 : 2);
#else
      2;
#endif
  const size_t share = ((elements + active_workers - 1) / active_workers +
                        kBatch - 1) / kBatch * kBatch;
  Request requests[K3NRX_WORKERS];
  void *arguments[4] = {};
  Scratch *scratches[4] = {g_scratch.get(), g_scratch_second.get(),
#if K3NRX_WORKERS == 4
                            g_scratch_third.get(), g_scratch_fourth.get()
#else
                            nullptr, nullptr
#endif
  };
  for (size_t i = 0; i < active_workers; ++i) {
    requests[i] = request;
    requests[i].first_element = std::min(i * share, elements);
    requests[i].last_element = std::min((i + 1) * share, elements);
    requests[i].scratch = scratches[i];
    arguments[i] = &requests[i];
  }
#endif
  if (input_stats) stop_meas(input_stats);
  if (inference_stats) start_meas(inference_stats);
  const auto begin = std::chrono::steady_clock::now();
#if K3NRX_WORKERS > 1
  const int result = a100_worker_pool_call(
      run_on_a100, arguments, (1u << active_workers) - 1);
#else
  const int result = a100_worker_call(run_on_a100, &request);
#endif
  const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
      std::chrono::steady_clock::now() - begin).count();
  if (inference_stats) stop_meas(inference_stats);
  if (output_stats) start_meas(output_stats);
  if (result != 0) return 0;
  ++g_calls;
  g_total_us += elapsed;
  if (g_calls <= 3 || g_calls % 100 == 0) {
    std::printf("K3_NATIVE_JOINT_RECEIVER call=%llu rb=%zu inference_us=%lld\n",
                g_calls, num_subcarriers / 12,
                static_cast<long long>(elapsed));
    std::fflush(stdout);
  }
  return 1;
}
