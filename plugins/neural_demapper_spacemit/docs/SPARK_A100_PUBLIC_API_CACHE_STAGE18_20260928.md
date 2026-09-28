# Stage 18: vendor API audit and adaptive multi-ULSCH shape cache

## Vendor public-interface conclusion

The public SpacemiT ONNX Runtime documentation and the installed K3 SDK were
checked for a persistent executor, a loadable precompiled subgraph, asynchronous
submit/completion, or a direct application-facing IME/fused-MLP API.

No such supported application API was found in the material inspected.

- The official provider reference publishes thread count/affinity,
  multi-session streams, a shared thread pool, subgraph/tensor/profile dumps,
  operator filters and accuracy controls.
- SpacemiT publishes Spine-Triton and A100 compiler/instruction support, but the
  project already tested its current fused MLP path and rejected it on latency.
- K3 has SpaceMIT EP 2.0.3.  Its only public provider header exposes
  `SessionOptionsSpaceMITEnvInit()`.  Internal library symbols such as
  `SpaceMITExecutionProvider::Compile` and `SpineGraph` are not accompanied by
  public headers or a stable external ABI and are not used.

Therefore Stage 18 follows the requested fallback: multi-ULSCH batching plus a
cache of fixed-shape sessions.

## Implementation

One plugin process can now cache fixed sessions for:

| ULSCH count | total RE | environment selector |
|---:|---:|---|
| 1 | 3312 | `XSAI_SPACEMIT_FIXED_MODEL` |
| 2 | 6624 | `XSAI_SPACEMIT_FIXED_MODEL_6624` |
| 3 | 9936 | `XSAI_SPACEMIT_FIXED_MODEL_9936` |
| 4 | 13248 | `XSAI_SPACEMIT_FIXED_MODEL_13248` |

Each calling thread also caches an `Ort::Value` input/output wrapper for every
loaded shape.  `run_model(total_re)` selects the exact fixed session; an
unsupported size retains the dynamic-session fallback.

The sessions use the documented `SPACEMIT_EP_USE_GLOBAL_INTRA_THREAD=1` option.
This is required because four independent per-session thread pools contend on
the same eight A100 workers even when inference calls are serial.

## Fixed-cache overhead gate

Five order-rotated 2,000-call runs compared the unified cache with a separately
compiled fixed plugin for every size.

| RE | ULSCH | specialized | unified cache | cache delta |
|---:|---:|---:|---:|---:|
| 3312 | 1 | 143.508 us | 143.279 us | -0.16% |
| 6624 | 2 | 224.496 us | 224.418 us | -0.03% |
| 9936 | 3 | 306.343 us | 310.621 us | +1.40% |
| 13248 | 4 | 422.284 us | 420.339 us | -0.46% |

The unified cache is effectively neutral for 1, 2 and 4 ULSCHs.  The 3-ULSCH
shape retains the previously observed higher variability and is 1.4% slower in
this gate.

Raw result:
`/home/ubuntu/sionna-rk/.work-neural-demapper-a100/results/spacemit-shape-cache-stage18-7_0yw12h/results.json`

## Shape-switching gate

A single process rotated 3312, 6624, 9936 and 13248 RE on every cycle for 5,000
cycles per shape.

| RE | dynamic session | fixed cache + shared pool | improvement |
|---:|---:|---:|---:|
| 3312 | 191.069 us | 178.023 us | 13.046 us / 6.83% |
| 6624 | 285.061 us | 261.323 us | 23.738 us / 8.33% |
| 9936 | 387.188 us | 356.477 us | 30.711 us / 7.93% |
| 13248 | 486.439 us | 454.252 us | 32.187 us / 6.62% |

Without the documented shared pool, the cached values were
188.303/278.580/374.608/472.493 us.  Sharing the pool removes 10--18 us of
multi-session contention, although switching among four sessions is still
slower than repeatedly using one hot shape.

The 3312 shared-pool run contained one 17.5-ms OS outlier; its p50/p95/p99 were
175.990/184.948/199.406 us.  The outlier is retained rather than hidden.

## Two-ULSCH ABI gate

The explicit multi-ULSCH ABI was rerun against the unified cache for 5,000
iterations:

| path | mean | p50 | p95 | p99 |
|---|---:|---:|---:|---:|
| two individual 3312 calls | 302.717 us | 299.816 | 322.107 | 339.398 |
| one combined 6624 call | **228.863 us** | **231.612** | **242.362** | **255.611** |

The combined path saves **73.854 us (24.4%)**.  All 26,496 int16 LLRs are
bit-exact between the two paths.  Single-group and duplicate-ULSCH-ID guards
remain enforced, and the legacy one-group batch ABI remains accepted.

## Decision

Retain the multi-shape cache and require the shared EP thread pool when more
than one fixed session is loaded.  The cache improves varying-shape workloads
and lets the explicit multi-ULSCH API select a fixed 6624/9936/13248 executor
without loading a different plugin.

This stage does not change OAI scheduling.  Promotion into the end-to-end path
still requires the slot-level prepare/infer/scatter coordinator and an
immediate single-ULSCH fallback; that work remains separate from today's
demapper-only optimization.

## Artifacts

- `tests/demapper_spacemit_ep.cpp`: fixed-session and per-thread I/O cache.
- `tests/bench_demapper_shape_mix.c`: rotating-shape stress benchmark.
- `tools/run_spacemit_shape_cache_stage18.py`: specialized-versus-cache gate.

All work used isolated libraries and models.  No live gNB process or source
tree was changed.  A100 TCM was 8/8 free after the tests.
