/* Spark 2->32->32->4 demapper using the official SpaceMIT Execution Provider.
 * The OAI ABI and FP16 input/output contract match Spark's TensorRT plugin.
 */
#include <cmath>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <riscv_vector.h>
#include <string>
#include <unordered_map>

#include <onnxruntime_cxx_api.h>
#include <spacemit_ort_env.h>

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

#ifndef SPARK_LLR_SCALE
#define SPARK_LLR_SCALE 256
#endif
#ifndef SPACEMIT_EP_MAX_RE
#define SPACEMIT_EP_MAX_RE 4096
#endif
#ifndef SPACEMIT_EP_FIXED_RE
#define SPACEMIT_EP_FIXED_RE 3312
#endif
#ifndef SPACEMIT_EP_INPUT_WIDTH
#define SPACEMIT_EP_INPUT_WIDTH 2
#endif
#ifndef SPACEMIT_EP_OUTPUT_WIDTH
#define SPACEMIT_EP_OUTPUT_WIDTH 4
#endif
#ifndef SPACEMIT_EP_CONV_LAYOUT
#define SPACEMIT_EP_CONV_LAYOUT 0
#endif

static std::unique_ptr<Ort::Env> ort_env;
static std::unique_ptr<Ort::Session> ort_session;
static std::unordered_map<uint32_t, std::unique_ptr<Ort::Session>> fixed_sessions;
static std::unique_ptr<Ort::MemoryInfo> memory_info;
static thread_local _Float16 input_fp16[SPACEMIT_EP_MAX_RE * SPACEMIT_EP_INPUT_WIDTH];
static thread_local _Float16 output_fp16[SPACEMIT_EP_MAX_RE * SPACEMIT_EP_OUTPUT_WIDTH];
struct FixedIo {
  std::unique_ptr<Ort::Value> input;
  std::unique_ptr<Ort::Value> output;
};
static thread_local std::unordered_map<uint32_t, FixedIo> fixed_io_cache;
static bool reuse_fixed_io = false;
static std::atomic<unsigned long long> calls{0};
static std::atomic<unsigned long long> batch_calls{0};
static std::atomic<unsigned long long> multi_ulsch_calls{0};

static void preprocess(const int16_t *samples, const int16_t *magnitudes,
                       uint32_t n, uint32_t destination_re = 0) {
#if SPACEMIT_EP_INPUT_WIDTH > 2
  std::memset(input_fp16 + destination_re * SPACEMIT_EP_INPUT_WIDTH, 0,
              n * SPACEMIT_EP_INPUT_WIDTH * sizeof(*input_fp16));
#endif
  for (unsigned axis = 0; axis < 2; ++axis) {
    for (uint32_t off = 0; off < n;) {
      size_t vl = __riscv_vsetvl_e16m4(n - off);
      vint16m4_t si = __riscv_vlse16_v_i16m4(samples + 2 * off + axis, 4, vl);
      vint16m4_t mi = __riscv_vlse16_v_i16m4(magnitudes + 2 * off + axis, 4, vl);
      vfloat32m8_t sf = __riscv_vfwcvt_f_x_v_f32m8(si, vl);
      vfloat32m8_t mf = __riscv_vfwcvt_f_x_v_f32m8(mi, vl);
      sf = __riscv_vfdiv_vv_f32m8(sf, mf, vl);
      vfloat16m4_t half = __riscv_vfncvt_f_f_w_f16m4(sf, vl);
#if SPACEMIT_EP_CONV_LAYOUT
      __riscv_vse16_v_f16m4(
          input_fp16 + axis * SPACEMIT_EP_FIXED_RE + destination_re + off,
          half, vl);
#else
      __riscv_vsse16_v_f16m4(
          input_fp16 + SPACEMIT_EP_INPUT_WIDTH * (destination_re + off) + axis,
          SPACEMIT_EP_INPUT_WIDTH * sizeof(*input_fp16), half, vl);
#endif
      off += vl;
    }
  }
}

static void quantize(int16_t *llr, uint32_t n, uint32_t source_re = 0) {
  for (unsigned bit = 0; bit < 4; ++bit) {
    for (uint32_t off = 0; off < n;) {
      size_t vl = __riscv_vsetvl_e16m2(n - off);
#if SPACEMIT_EP_CONV_LAYOUT
      vfloat16m2_t half = __riscv_vle16_v_f16m2(
          output_fp16 + bit * SPACEMIT_EP_FIXED_RE + source_re + off, vl);
#else
      vfloat16m2_t half = __riscv_vlse16_v_f16m2(
          output_fp16 + SPACEMIT_EP_OUTPUT_WIDTH * (source_re + off) + bit,
          SPACEMIT_EP_OUTPUT_WIDTH * sizeof(*output_fp16), vl);
#endif
      vfloat32m4_t value = __riscv_vfwcvt_f_f_v_f32m4(half, vl);
      value = __riscv_vfmul_vf_f32m4(value, (float)SPARK_LLR_SCALE, vl);
      vint32m4_t q = __riscv_vfcvt_x_f_v_i32m4(value, vl);
      q = __riscv_vmax_vx_i32m4(q, INT16_MIN, vl);
      q = __riscv_vmin_vx_i32m4(q, INT16_MAX, vl);
      vint16m2_t q16 = __riscv_vncvt_x_x_w_i16m2(q, vl);
      __riscv_vsse16_v_i16m2(llr + 4 * off + bit, 8, q16, vl);
      off += vl;
    }
  }
}

static void prepare_fixed_io(uint32_t n) {
  FixedIo &io = fixed_io_cache[n];
  if (io.input && io.output) return;
#if SPACEMIT_EP_CONV_LAYOUT
  int64_t input_shape[4] = {1, 2, (int64_t)n, 1};
  int64_t output_shape[4] = {1, 4, (int64_t)n, 1};
  constexpr size_t rank = 4;
#else
  int64_t input_shape[2] = {(int64_t)n, SPACEMIT_EP_INPUT_WIDTH};
  int64_t output_shape[2] = {(int64_t)n, SPACEMIT_EP_OUTPUT_WIDTH};
  constexpr size_t rank = 2;
#endif
  io.input = std::make_unique<Ort::Value>(
      Ort::Value::CreateTensor<Ort::Float16_t>(
          *memory_info, reinterpret_cast<Ort::Float16_t *>(input_fp16),
          SPACEMIT_EP_INPUT_WIDTH * n, input_shape, rank));
  io.output = std::make_unique<Ort::Value>(
      Ort::Value::CreateTensor<Ort::Float16_t>(
          *memory_info, reinterpret_cast<Ort::Float16_t *>(output_fp16),
          SPACEMIT_EP_OUTPUT_WIDTH * n, output_shape, rank));
}

static void run_model(uint32_t n) {
  auto fixed = fixed_sessions.find(n);
  Ort::Session *session = fixed != fixed_sessions.end()
      ? fixed->second.get() : ort_session.get();
  const char *input_names[] = {"y"};
  const char *output_names[] = {"output_1"};
  if (fixed != fixed_sessions.end() && reuse_fixed_io) {
    prepare_fixed_io(n);
    FixedIo &io = fixed_io_cache[n];
    session->Run(Ort::RunOptions{nullptr}, input_names, io.input.get(), 1,
                 output_names, io.output.get(), 1);
    return;
  }
#if SPACEMIT_EP_CONV_LAYOUT
  int64_t input_shape[4] = {1, 2, (int64_t)n, 1};
  int64_t output_shape[4] = {1, 4, (int64_t)n, 1};
  constexpr size_t rank = 4;
#else
  int64_t input_shape[2] = {(int64_t)n, SPACEMIT_EP_INPUT_WIDTH};
  int64_t output_shape[2] = {(int64_t)n, SPACEMIT_EP_OUTPUT_WIDTH};
  constexpr size_t rank = 2;
#endif
  Ort::Value input = Ort::Value::CreateTensor<Ort::Float16_t>(
      *memory_info, reinterpret_cast<Ort::Float16_t *>(input_fp16),
      SPACEMIT_EP_INPUT_WIDTH * n,
      input_shape, rank);
  Ort::Value output = Ort::Value::CreateTensor<Ort::Float16_t>(
      *memory_info, reinterpret_cast<Ort::Float16_t *>(output_fp16),
      SPACEMIT_EP_OUTPUT_WIDTH * n,
      output_shape, rank);
  session->Run(Ort::RunOptions{nullptr}, input_names, &input, 1,
               output_names, &output, 1);
}

extern "C" int32_t demapper_init(void) {
  try {
    const char *model = std::getenv("XSAI_SPARK_ONNX");
    if (!model)
      model = "models/neural_demapper.2xfloat16.onnx";
    // Use project-private environment names.  The EP also consumes its own
    // SPACEMIT_EP_* environment variables, so reusing those names here would
    // inject the same affinity twice (environment plus provider options).
    const char *threads = std::getenv("XSAI_SPACEMIT_EP_THREADS");
    const char *affinity = std::getenv("XSAI_SPACEMIT_EP_AFFINITY");
    const char *streams = std::getenv("XSAI_SPACEMIT_EP_STREAMS");
    std::unordered_map<std::string, std::string> options{
        {"SPACEMIT_EP_INTRA_THREAD_NUM", threads ? threads : "4"},
        {"SPACEMIT_EP_INTRA_THREAD_AFFINITY", affinity ? affinity : "8;9;10;11"},
        {"SPACEMIT_EP_INTER_THREAD_NUM", streams ? streams : "1"},
    };
    const std::pair<const char *, const char *> optional_options[] = {
        {"XSAI_SPACEMIT_EP_DISABLE_TLS_RELEASE", "SPACEMIT_EP_DISABLE_TLS_RELEASE"},
        {"XSAI_SPACEMIT_EP_USE_GLOBAL_INTRA_THREAD", "SPACEMIT_EP_USE_GLOBAL_INTRA_THREAD"},
        {"XSAI_SPACEMIT_EP_ENABLE_DMA", "SPACEMIT_EP_ENABLE_DMA"},
        {"XSAI_SPACEMIT_EP_ENABLE_BLOCKLAYOUT", "SPACEMIT_EP_ENABLE_BLOCKLAYOUT"},
    };
    for (const auto &[environment, provider] : optional_options) {
      const char *value = std::getenv(environment);
      if (value && value[0]) options[provider] = value;
    }
    ort_env = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_WARNING,
                                         "spark-demapper");
    Ort::SessionOptions session_options;
    Ort::SessionOptionsSpaceMITEnvInit(session_options, options);
    ort_session = std::make_unique<Ort::Session>(*ort_env, model, session_options);
    memory_info = std::make_unique<Ort::MemoryInfo>(
        Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault));
    const char *fixed_model = std::getenv("XSAI_SPACEMIT_FIXED_MODEL");
    if (fixed_model && fixed_model[0])
      fixed_sessions[SPACEMIT_EP_FIXED_RE] =
          std::make_unique<Ort::Session>(*ort_env, fixed_model, session_options);
    const uint32_t cached_shapes[] = {6624, 9936, 13248};
    for (uint32_t shape : cached_shapes) {
      const std::string name = "XSAI_SPACEMIT_FIXED_MODEL_" +
          std::to_string(shape);
      const char *path = std::getenv(name.c_str());
      if (path && path[0])
        fixed_sessions[shape] =
            std::make_unique<Ort::Session>(*ort_env, path, session_options);
    }
    const char *reuse = std::getenv("XSAI_SPACEMIT_REUSE_3312_IO");
    reuse_fixed_io = reuse && std::strcmp(reuse, "0") != 0;
    calls = 0;
    batch_calls = 0;
    multi_ulsch_calls = 0;
    std::printf("SPARK_SPACEMIT_EP model=2x32x32x4 threads=%s streams=%s affinity=%s scale=%d fixed=%s reuse3312=%d tls=%s global=%s dma=%s block=%s\n",
                options["SPACEMIT_EP_INTRA_THREAD_NUM"].c_str(),
                options["SPACEMIT_EP_INTER_THREAD_NUM"].c_str(),
                options["SPACEMIT_EP_INTRA_THREAD_AFFINITY"].c_str(),
                SPARK_LLR_SCALE,
                fixed_sessions.count(SPACEMIT_EP_FIXED_RE) ? fixed_model : "disabled",
                reuse_fixed_io ? 1 : 0,
                options.count("SPACEMIT_EP_DISABLE_TLS_RELEASE")
                    ? options["SPACEMIT_EP_DISABLE_TLS_RELEASE"].c_str() : "default",
                options.count("SPACEMIT_EP_USE_GLOBAL_INTRA_THREAD")
                    ? options["SPACEMIT_EP_USE_GLOBAL_INTRA_THREAD"].c_str() : "default",
                options.count("SPACEMIT_EP_ENABLE_DMA")
                    ? options["SPACEMIT_EP_ENABLE_DMA"].c_str() : "default",
                options.count("SPACEMIT_EP_ENABLE_BLOCKLAYOUT")
                    ? options["SPACEMIT_EP_ENABLE_BLOCKLAYOUT"].c_str() : "default");
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "SPARK_SPACEMIT_EP init failed: %s\n", error.what());
    return -1;
  }
}

extern "C" int32_t demapper_init_thread(void) {
  if (reuse_fixed_io)
    for (const auto &[shape, session] : fixed_sessions) prepare_fixed_io(shape);
  return 0;
}

extern "C" int32_t demapper_shutdown(void) {
  std::printf("SPARK_SPACEMIT_EP calls=%llu batch_calls=%llu multi_ulsch_calls=%llu\n",
              static_cast<unsigned long long>(calls.load()),
              static_cast<unsigned long long>(batch_calls.load()),
              static_cast<unsigned long long>(multi_ulsch_calls.load()));
  fixed_io_cache.clear();
  memory_info.reset();
  fixed_sessions.clear();
  ort_session.reset();
  ort_env.reset();
  return 0;
}

extern "C" int demapper_compute_llr(int32_t *iq, c16_t *mag, c16_t *magb,
                                     c16_t *magc, int16_t *llr, uint32_t n,
                                     uint8_t symbol, uint8_t qm) {
  (void)magb;
  (void)magc;
  (void)symbol;
  if (qm != 4 || !n) return 0;
  if (!iq || !mag || !llr || n > SPACEMIT_EP_MAX_RE || !ort_session) return 0;

  try {
    preprocess(reinterpret_cast<const int16_t *>(iq),
               reinterpret_cast<const int16_t *>(mag), n);
    run_model(n);
    quantize(llr, n);
    calls.fetch_add(1, std::memory_order_relaxed);
    return 1;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "SPARK_SPACEMIT_EP run failed: %s\n", error.what());
    return 0;
  }
}

static int run_ulsch_groups(demapper_ulsch_batch_t *groups,
                            uint32_t group_count) {
  if (!groups || !group_count || !ort_session) return 0;
  uint32_t total = 0;
  uint64_t logical_calls = 0;
  for (uint32_t group_index = 0; group_index < group_count; ++group_index) {
    const auto &group = groups[group_index];
    if (!group.items || !group.item_count) return 0;
    logical_calls += group.item_count;
    for (uint32_t item_index = 0; item_index < group.item_count; ++item_index) {
      const auto &item = group.items[item_index];
      if (!item.iq || !item.mag || !item.llr || item.qm != 4 || !item.nb_re ||
          item.nb_re > SPACEMIT_EP_MAX_RE - total)
        return 0;
      total += item.nb_re;
    }
  }
  try {
    uint32_t offset = 0;
    for (uint32_t group_index = 0; group_index < group_count; ++group_index) {
      auto &group = groups[group_index];
      for (uint32_t item_index = 0; item_index < group.item_count; ++item_index) {
        auto &item = group.items[item_index];
        preprocess(reinterpret_cast<const int16_t *>(item.iq),
                   reinterpret_cast<const int16_t *>(item.mag), item.nb_re,
                   offset);
        offset += item.nb_re;
      }
    }
    run_model(total);
    offset = 0;
    for (uint32_t group_index = 0; group_index < group_count; ++group_index) {
      auto &group = groups[group_index];
      for (uint32_t item_index = 0; item_index < group.item_count; ++item_index) {
        auto &item = group.items[item_index];
        quantize(item.llr, item.nb_re, offset);
        offset += item.nb_re;
      }
    }
    calls.fetch_add(logical_calls, std::memory_order_relaxed);
    batch_calls.fetch_add(1, std::memory_order_relaxed);
    return 1;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "SPARK_SPACEMIT_EP batch failed: %s\n", error.what());
    return 0;
  }
}

extern "C" int demapper_compute_llr_batch(uint32_t frame, uint16_t slot,
                                            uint16_t ulsch_id,
                                            demapper_batch_item_t *items,
                                            uint32_t item_count) {
  (void)frame;
  (void)slot;
  demapper_ulsch_batch_t group = {
      .ulsch_id = ulsch_id,
      .items = items,
      .item_count = item_count,
  };
  return run_ulsch_groups(&group, 1);
}

extern "C" int demapper_compute_llr_multi_ulsch(
    uint32_t frame, uint16_t slot, demapper_ulsch_batch_t *groups,
    uint32_t group_count) {
  (void)frame;
  (void)slot;
  if (group_count < 2) return 0;
  for (uint32_t i = 0; i < group_count; ++i)
    for (uint32_t j = i + 1; j < group_count; ++j)
      if (groups[i].ulsch_id == groups[j].ulsch_id) return 0;
  const int handled = run_ulsch_groups(groups, group_count);
  if (handled) multi_ulsch_calls.fetch_add(1, std::memory_order_relaxed);
  return handled;
}
