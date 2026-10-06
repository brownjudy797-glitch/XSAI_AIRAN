#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>

#ifdef __riscv_vector
#include <riscv_vector.h>
#endif

typedef struct {
  int16_t r;
  int16_t i;
} c16_t;

namespace {

struct WeightHeader {
  char magic[8];
  uint32_t input;
  uint32_t hidden1;
  uint32_t hidden2;
  uint32_t output;
  uint32_t count;
  uint32_t version;
};

constexpr uint32_t kInput = 2;
constexpr uint32_t kHidden = 32;
constexpr uint32_t kOutput = 4;
constexpr uint32_t kBatch = 256;
constexpr uint32_t kWeightCount =
    kInput * kHidden + kHidden + kHidden * kHidden + kHidden +
    kHidden * kOutput + kOutput;

std::mutex g_mutex;
std::unique_ptr<float[]> g_storage;
const float *g_w1;
const float *g_b1;
const float *g_w2;
const float *g_b2;
const float *g_w3;
const float *g_b3;
std::atomic<uint64_t> g_calls{0};
std::atomic<uint64_t> g_fallbacks{0};
std::atomic<uint64_t> g_errors{0};
float g_llr_scale = 256.0f;

struct ThreadContext {
  alignas(64) float input0[kBatch];
  alignas(64) float input1[kBatch];
  alignas(64) float hidden1[kHidden][kBatch];
  alignas(64) float hidden2[kHidden][kBatch];
  alignas(64) float output[kOutput][kBatch];
};
thread_local std::unique_ptr<ThreadContext> g_thread;

const char *weights_path()
{
  const char *configured = std::getenv("XSAI_DEMAPPER_WEIGHTS");
  return configured && configured[0]
             ? configured
             : "plugins/neural_demapper/models/demapper_a100.weights";
}

bool load_weights()
{
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_storage)
    return true;
  FILE *file = std::fopen(weights_path(), "rb");
  if (!file) {
    std::fprintf(stderr, "A100 RVV demapper: cannot open %s\n", weights_path());
    return false;
  }
  WeightHeader header{};
  const bool header_ok = std::fread(&header, sizeof(header), 1, file) == 1;
  if (!header_ok || std::memcmp(header.magic, "XSAIDM1", 7) != 0 ||
      header.input != kInput || header.hidden1 != kHidden ||
      header.hidden2 != kHidden || header.output != kOutput ||
      header.count != kWeightCount || header.version != 1) {
    std::fprintf(stderr, "A100 RVV demapper: invalid weight header\n");
    std::fclose(file);
    return false;
  }
  auto storage = std::make_unique<float[]>(kWeightCount);
  const bool payload_ok =
      std::fread(storage.get(), sizeof(float), kWeightCount, file) == kWeightCount;
  const int trailing = std::fgetc(file);
  std::fclose(file);
  if (!payload_ok || trailing != EOF) {
    std::fprintf(stderr, "A100 RVV demapper: invalid weight payload\n");
    return false;
  }

  const float *cursor = storage.get();
  g_w1 = cursor; cursor += kInput * kHidden;
  g_b1 = cursor; cursor += kHidden;
  g_w2 = cursor; cursor += kHidden * kHidden;
  g_b2 = cursor; cursor += kHidden;
  g_w3 = cursor; cursor += kHidden * kOutput;
  g_b3 = cursor;
  g_storage = std::move(storage);
  std::printf("Initialized A100 fused RVV neural demapper: weights=%s\n",
              weights_path());
  return true;
}

inline void infer_batch(ThreadContext &ctx, uint32_t count)
{
#ifdef __riscv_vector
  for (uint32_t o = 0; o < kHidden; ++o) {
    size_t offset = 0;
    while (offset < count) {
      const size_t vl = __riscv_vsetvl_e32m4(count - offset);
      vfloat32m4_t value = __riscv_vfmv_v_f_f32m4(g_b1[o], vl);
      const vfloat32m4_t x0 = __riscv_vle32_v_f32m4(ctx.input0 + offset, vl);
      const vfloat32m4_t x1 = __riscv_vle32_v_f32m4(ctx.input1 + offset, vl);
      value = __riscv_vfmacc_vf_f32m4(value, g_w1[o], x0, vl);
      value = __riscv_vfmacc_vf_f32m4(value, g_w1[kHidden + o], x1, vl);
      value = __riscv_vfmax_vf_f32m4(value, 0.0f, vl);
      __riscv_vse32_v_f32m4(ctx.hidden1[o] + offset, value, vl);
      offset += vl;
    }
  }
  for (uint32_t o = 0; o < kHidden; ++o) {
    size_t offset = 0;
    while (offset < count) {
      const size_t vl = __riscv_vsetvl_e32m4(count - offset);
      vfloat32m4_t value = __riscv_vfmv_v_f_f32m4(g_b2[o], vl);
      for (uint32_t i = 0; i < kHidden; ++i) {
        const vfloat32m4_t input =
            __riscv_vle32_v_f32m4(ctx.hidden1[i] + offset, vl);
        value = __riscv_vfmacc_vf_f32m4(value,
                                        g_w2[i * kHidden + o], input, vl);
      }
      value = __riscv_vfmax_vf_f32m4(value, 0.0f, vl);
      __riscv_vse32_v_f32m4(ctx.hidden2[o] + offset, value, vl);
      offset += vl;
    }
  }
  for (uint32_t o = 0; o < kOutput; ++o) {
    size_t offset = 0;
    while (offset < count) {
      const size_t vl = __riscv_vsetvl_e32m4(count - offset);
      vfloat32m4_t value = __riscv_vfmv_v_f_f32m4(g_b3[o], vl);
      for (uint32_t i = 0; i < kHidden; ++i) {
        const vfloat32m4_t input =
            __riscv_vle32_v_f32m4(ctx.hidden2[i] + offset, vl);
        value = __riscv_vfmacc_vf_f32m4(value,
                                        g_w3[i * kOutput + o], input, vl);
      }
      __riscv_vse32_v_f32m4(ctx.output[o] + offset, value, vl);
      offset += vl;
    }
  }
#else
  for (uint32_t re = 0; re < count; ++re) {
    for (uint32_t o = 0; o < kHidden; ++o)
      ctx.hidden1[o][re] = std::max(0.0f, g_b1[o] +
          ctx.input0[re] * g_w1[o] + ctx.input1[re] * g_w1[kHidden + o]);
    for (uint32_t o = 0; o < kHidden; ++o) {
      float value = g_b2[o];
      for (uint32_t i = 0; i < kHidden; ++i)
        value += ctx.hidden1[i][re] * g_w2[i * kHidden + o];
      ctx.hidden2[o][re] = std::max(0.0f, value);
    }
    for (uint32_t o = 0; o < kOutput; ++o) {
      float value = g_b3[o];
      for (uint32_t i = 0; i < kHidden; ++i)
        value += ctx.hidden2[i][re] * g_w3[i * kOutput + o];
      ctx.output[o][re] = value;
    }
  }
#endif
}

inline int16_t quantize(float value)
{
  return static_cast<int16_t>(
      std::clamp(std::nearbyint(value * g_llr_scale), -32768.0f, 32767.0f));
}

} // namespace

extern "C" int32_t demapper_init(void)
{
  const char *scale = std::getenv("XSAI_DEMAPPER_LLR_SCALE");
  if (scale) {
    char *end = nullptr;
    const float parsed = std::strtof(scale, &end);
    if (end == scale || *end || !std::isfinite(parsed) || parsed <= 0.0f)
      return -1;
    g_llr_scale = parsed;
  }
  std::printf("A100 RVV LLR scale: %.6g\n", g_llr_scale);
  if (!load_weights())
    return -1;
  g_thread = std::make_unique<ThreadContext>();
  return 0;
}

extern "C" int32_t demapper_init_thread(void)
{
  if (!g_storage && !load_weights())
    return -1;
  if (!g_thread)
    g_thread = std::make_unique<ThreadContext>();
  return 0;
}

extern "C" int32_t demapper_shutdown(void)
{
  g_thread.reset();
  std::lock_guard<std::mutex> lock(g_mutex);
  g_storage.reset();
  std::printf("A100 RVV demapper shutdown: calls=%llu fallbacks=%llu errors=%llu\n",
              static_cast<unsigned long long>(g_calls.load()),
              static_cast<unsigned long long>(g_fallbacks.load()),
              static_cast<unsigned long long>(g_errors.load()));
  return 0;
}

extern "C" int demapper_compute_llr(int32_t *rxdataF_comp,
                                      c16_t *ul_ch_mag,
                                      c16_t *, c16_t *,
                                      int16_t *ulsch_llr,
                                      uint32_t nb_re,
                                      uint8_t,
                                      uint8_t mod_order)
{
  if (mod_order != 4 || nb_re == 0) {
    ++g_fallbacks;
    return 0;
  }
  if (!rxdataF_comp || !ul_ch_mag || !ulsch_llr || !g_storage) {
    ++g_errors;
    return 0;
  }
  if (!g_thread) {
    ++g_errors;
    return 0;
  }
  const int16_t *symbols = reinterpret_cast<const int16_t *>(rxdataF_comp);
  const int16_t *magnitudes = reinterpret_cast<const int16_t *>(ul_ch_mag);
  // Reject the complete call before writing any output. This keeps OAI's
  // fallback path deterministic even when a later RE has invalid scaling.
  for (uint32_t re = 0; re < nb_re; ++re) {
    if (magnitudes[2 * re] == 0 || magnitudes[2 * re + 1] == 0) {
      ++g_errors;
      return 0;
    }
  }
  for (uint32_t base = 0; base < nb_re; base += kBatch) {
    const uint32_t count = std::min(kBatch, nb_re - base);
    for (uint32_t re = 0; re < count; ++re) {
      const uint32_t source = base + re;
      g_thread->input0[re] =
          static_cast<float>(symbols[2 * source]) / magnitudes[2 * source];
      g_thread->input1[re] =
          static_cast<float>(symbols[2 * source + 1]) / magnitudes[2 * source + 1];
    }
    infer_batch(*g_thread, count);
    for (uint32_t re = 0; re < count; ++re)
      for (uint32_t bit = 0; bit < kOutput; ++bit)
        ulsch_llr[(base + re) * kOutput + bit] =
            quantize(g_thread->output[bit][re]);
  }
  ++g_calls;
  return 1;
}
