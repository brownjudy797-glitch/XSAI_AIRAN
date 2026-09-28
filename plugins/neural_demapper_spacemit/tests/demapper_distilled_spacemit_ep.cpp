/* Reliability-conditioned 2x16x16x2 demapper using the SpaceMIT EP.
 * CPU preprocessing preserves the frozen magnitude-bin contract; A100 runs
 * only the FP16 MLP.  The OAI batch ABI combines one slot into one inference.
 */
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <unordered_map>

#include <onnxruntime_cxx_api.h>
#include <spacemit_ort_env.h>

#include "analytical_app.h"

struct c16_t { int16_t r, i; };
struct demapper_batch_item_t {
  int32_t *iq;
  c16_t *mag;
  c16_t *magb;
  c16_t *magc;
  int16_t *llr;
  uint32_t nb_re;
  uint8_t symbol;
  uint8_t qm;
};
struct demapper_ulsch_batch_t {
  uint16_t ulsch_id;
  demapper_batch_item_t *items;
  uint32_t item_count;
};

constexpr uint32_t kMaxRe = 4096;
constexpr uint32_t kFixedRe = 3312;
constexpr uint32_t kMaxAxes = 2 * kMaxRe;

static std::unique_ptr<Ort::Env> ort_env;
static std::unique_ptr<Ort::Session> dynamic_session;
static std::unique_ptr<Ort::Session> fixed_session;
static std::unique_ptr<Ort::MemoryInfo> memory_info;
static thread_local _Float16 input_fp16[kMaxAxes * 2];
static thread_local _Float16 output_fp16[kMaxAxes * 2];
static thread_local double corrected[kMaxAxes];
static thread_local double fallback_values[kMaxAxes * 2];
static thread_local unsigned char use_fallback[kMaxAxes];
static thread_local std::unique_ptr<Ort::Value> fixed_input;
static thread_local std::unique_ptr<Ort::Value> fixed_output;
static bool reuse_fixed_io = false;
static double inv_gain[5][2];
static double effective_variance[5][2];
static double output_scale[4];
static std::atomic<unsigned long long> calls{0};
static std::atomic<unsigned long long> batch_calls{0};
static std::atomic<unsigned long long> fallback_axes{0};
static std::atomic<unsigned long long> rejected{0};

static int16_t quantize(double value) {
  value = std::max(-32768.0, std::min(32767.0, value));
  return static_cast<int16_t>(std::nearbyint(value));
}

static bool prepare(const int16_t *samples, const int16_t *magnitudes,
                    uint32_t n, uint32_t destination_re = 0) {
  unsigned long long local_fallbacks = 0;
  for (uint32_t r = 0; r < n; ++r) {
    for (unsigned axis = 0; axis < 2; ++axis) {
      const uint32_t source = 2 * r + axis;
      const uint32_t row = 2 * (destination_re + r) + axis;
      const double magnitude = magnitudes[source];
      if (!(magnitude > 0)) return false;
      unsigned bin = 0;
      while (bin < 4 && magnitude >= app_edges[bin]) ++bin;
      const double x = samples[source] / magnitude;
      const double u = (x - app_params[bin][1][axis]) * inv_gain[bin][axis];
      const double variance = effective_variance[bin][axis];
      corrected[row] = u;
      use_fallback[row] = !std::isfinite(u) || std::fabs(u) > 5.0 ||
                          variance < 0.30 || variance > 0.43;
      if (use_fallback[row]) {
        app_axis(x, magnitude, axis, &fallback_values[2 * row],
                 &fallback_values[2 * row + 1]);
        input_fp16[2 * row] = 0;
        input_fp16[2 * row + 1] = 0;
        ++local_fallbacks;
      } else {
        input_fp16[2 * row] = static_cast<_Float16>(std::fabs(u) / 4.0);
        input_fp16[2 * row + 1] = static_cast<_Float16>(variance);
      }
    }
  }
  fallback_axes.fetch_add(local_fallbacks, std::memory_order_relaxed);
  return true;
}

static void prepare_fixed_io() {
  if (fixed_input && fixed_output) return;
  int64_t shape[2] = {2 * kFixedRe, 2};
  fixed_input = std::make_unique<Ort::Value>(
      Ort::Value::CreateTensor<Ort::Float16_t>(
          *memory_info, reinterpret_cast<Ort::Float16_t *>(input_fp16),
          4 * kFixedRe, shape, 2));
  fixed_output = std::make_unique<Ort::Value>(
      Ort::Value::CreateTensor<Ort::Float16_t>(
          *memory_info, reinterpret_cast<Ort::Float16_t *>(output_fp16),
          4 * kFixedRe, shape, 2));
}

static void run_model(uint32_t re_count) {
  const uint32_t rows = 2 * re_count;
  const char *input_names[] = {"axis_features"};
  const char *output_names[] = {"axis_logits"};
  if (re_count == kFixedRe && fixed_session) {
    if (reuse_fixed_io) {
      prepare_fixed_io();
      fixed_session->Run(Ort::RunOptions{nullptr}, input_names,
                         fixed_input.get(), 1, output_names,
                         fixed_output.get(), 1);
      return;
    }
  }
  Ort::Session *session = re_count == kFixedRe && fixed_session
      ? fixed_session.get() : dynamic_session.get();
  int64_t shape[2] = {rows, 2};
  Ort::Value input = Ort::Value::CreateTensor<Ort::Float16_t>(
      *memory_info, reinterpret_cast<Ort::Float16_t *>(input_fp16),
      2 * rows, shape, 2);
  Ort::Value output = Ort::Value::CreateTensor<Ort::Float16_t>(
      *memory_info, reinterpret_cast<Ort::Float16_t *>(output_fp16),
      2 * rows, shape, 2);
  session->Run(Ort::RunOptions{nullptr}, input_names, &input, 1,
               output_names, &output, 1);
}

static void finish(int16_t *llr, uint32_t n, uint32_t source_re = 0) {
  for (uint32_t r = 0; r < n; ++r) {
    for (unsigned axis = 0; axis < 2; ++axis) {
      const uint32_t row = 2 * (source_re + r) + axis;
      for (unsigned bit = 0; bit < 2; ++bit) {
        double value;
        if (use_fallback[row]) {
          value = fallback_values[2 * row + bit] * 4.0;
        } else {
          value = static_cast<double>(output_fp16[2 * row + bit]) *
                  output_scale[axis + 2 * bit];
          if (bit == 0)
            value *= (corrected[row] > 0) - (corrected[row] < 0);
        }
        llr[4 * r + axis + 2 * bit] = quantize(value);
      }
    }
  }
}

extern "C" int32_t demapper_init(void) {
  try {
    const char *model = std::getenv("XSAI_DISTILLED_ONNX");
    const char *fixed_model = std::getenv("XSAI_DISTILLED_FIXED_MODEL");
    if (!model || !model[0]) return -1;
    const char *threads = std::getenv("XSAI_SPACEMIT_EP_THREADS");
    const char *affinity = std::getenv("XSAI_SPACEMIT_EP_AFFINITY");
    const char *streams = std::getenv("XSAI_SPACEMIT_EP_STREAMS");
    std::unordered_map<std::string, std::string> options{
        {"SPACEMIT_EP_INTRA_THREAD_NUM", threads ? threads : "8"},
        {"SPACEMIT_EP_INTRA_THREAD_AFFINITY", affinity ? affinity : "8;9;10;11;12;13;14;15"},
        {"SPACEMIT_EP_INTER_THREAD_NUM", streams ? streams : "1"},
    };
    const char *global = std::getenv("XSAI_SPACEMIT_EP_USE_GLOBAL_INTRA_THREAD");
    if (global && global[0]) options["SPACEMIT_EP_USE_GLOBAL_INTRA_THREAD"] = global;
    ort_env = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_WARNING,
                                         "distilled-demapper");
    Ort::SessionOptions session_options;
    Ort::SessionOptionsSpaceMITEnvInit(session_options, options);
    dynamic_session = std::make_unique<Ort::Session>(*ort_env, model,
                                                      session_options);
    if (fixed_model && fixed_model[0])
      fixed_session = std::make_unique<Ort::Session>(*ort_env, fixed_model,
                                                      session_options);
    memory_info = std::make_unique<Ort::MemoryInfo>(
        Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault));
    const char *reuse = std::getenv("XSAI_SPACEMIT_REUSE_3312_IO");
    reuse_fixed_io = reuse && std::strcmp(reuse, "0") != 0;
    for (unsigned bin = 0; bin < 5; ++bin)
      for (unsigned axis = 0; axis < 2; ++axis) {
        const double gain = app_params[bin][0][axis];
        inv_gain[bin][axis] = 1.0 / gain;
        effective_variance[bin][axis] = app_params[bin][2][axis] / (gain * gain);
      }
    for (unsigned bit = 0; bit < 4; ++bit)
      output_scale[bit] = 32.0 * app_temperature[bit];
    calls = batch_calls = fallback_axes = rejected = 0;
    std::printf("DISTILLED_SPACEMIT_EP model=2x16x16x2 rows=2*RE threads=%s affinity=%s fixed=%d reuse=%d scale=4\n",
                options["SPACEMIT_EP_INTRA_THREAD_NUM"].c_str(),
                options["SPACEMIT_EP_INTRA_THREAD_AFFINITY"].c_str(),
                fixed_session ? 1 : 0, reuse_fixed_io ? 1 : 0);
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "DISTILLED_SPACEMIT_EP init failed: %s\n", error.what());
    return -1;
  }
}

extern "C" int32_t demapper_init_thread(void) {
  if (fixed_session && reuse_fixed_io) prepare_fixed_io();
  return 0;
}

extern "C" int32_t demapper_shutdown(void) {
  std::printf("DISTILLED_SPACEMIT_EP calls=%llu batch_calls=%llu fallback_axes=%llu rejected=%llu\n",
              static_cast<unsigned long long>(calls.load()),
              static_cast<unsigned long long>(batch_calls.load()),
              static_cast<unsigned long long>(fallback_axes.load()),
              static_cast<unsigned long long>(rejected.load()));
  fixed_input.reset();
  fixed_output.reset();
  memory_info.reset();
  fixed_session.reset();
  dynamic_session.reset();
  ort_env.reset();
  return 0;
}

extern "C" int demapper_compute_llr(int32_t *iq, c16_t *mag, c16_t *, c16_t *,
                                     int16_t *llr, uint32_t n, uint8_t, uint8_t qm) {
  if (qm != 4 || !n) return 0;
  if (!iq || !mag || !llr || n > kMaxRe || !dynamic_session) {
    rejected.fetch_add(1, std::memory_order_relaxed);
    return 0;
  }
  try {
    if (!prepare(reinterpret_cast<const int16_t *>(iq),
                 reinterpret_cast<const int16_t *>(mag), n)) return 0;
    run_model(n);
    finish(llr, n);
    calls.fetch_add(1, std::memory_order_relaxed);
    return 1;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "DISTILLED_SPACEMIT_EP run failed: %s\n", error.what());
    return 0;
  }
}

static int run_groups(demapper_ulsch_batch_t *groups, uint32_t group_count) {
  if (!groups || !group_count || !dynamic_session) return 0;
  uint32_t total = 0;
  uint64_t logical_calls = 0;
  for (uint32_t g = 0; g < group_count; ++g) {
    if (!groups[g].items || !groups[g].item_count) return 0;
    logical_calls += groups[g].item_count;
    for (uint32_t i = 0; i < groups[g].item_count; ++i) {
      const auto &item = groups[g].items[i];
      if (!item.iq || !item.mag || !item.llr || item.qm != 4 || !item.nb_re ||
          item.nb_re > kMaxRe - total) return 0;
      total += item.nb_re;
    }
  }
  try {
    uint32_t offset = 0;
    for (uint32_t g = 0; g < group_count; ++g)
      for (uint32_t i = 0; i < groups[g].item_count; ++i) {
        auto &item = groups[g].items[i];
        if (!prepare(reinterpret_cast<const int16_t *>(item.iq),
                     reinterpret_cast<const int16_t *>(item.mag), item.nb_re,
                     offset)) return 0;
        offset += item.nb_re;
      }
    run_model(total);
    offset = 0;
    for (uint32_t g = 0; g < group_count; ++g)
      for (uint32_t i = 0; i < groups[g].item_count; ++i) {
        auto &item = groups[g].items[i];
        finish(item.llr, item.nb_re, offset);
        offset += item.nb_re;
      }
    calls.fetch_add(logical_calls, std::memory_order_relaxed);
    batch_calls.fetch_add(1, std::memory_order_relaxed);
    return 1;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "DISTILLED_SPACEMIT_EP batch failed: %s\n", error.what());
    return 0;
  }
}

extern "C" int demapper_compute_llr_batch(uint32_t, uint16_t, uint16_t ulsch_id,
                                           demapper_batch_item_t *items,
                                           uint32_t item_count) {
  demapper_ulsch_batch_t group{ulsch_id, items, item_count};
  return run_groups(&group, 1);
}

extern "C" int demapper_compute_llr_multi_ulsch(
    uint32_t, uint16_t, demapper_ulsch_batch_t *groups, uint32_t group_count) {
  if (group_count < 2) return 0;
  for (uint32_t i = 0; i < group_count; ++i)
    for (uint32_t j = i + 1; j < group_count; ++j)
      if (groups[i].ulsch_id == groups[j].ulsch_id) return 0;
  return run_groups(groups, group_count);
}
