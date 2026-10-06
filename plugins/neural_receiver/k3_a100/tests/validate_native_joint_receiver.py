#!/usr/bin/env python3
"""Compare the K3 RVV receiver with an independent NumPy dense-network oracle."""
from __future__ import annotations

import argparse
import ctypes
import os
from pathlib import Path
import struct
import time

import numpy as np


def weights_from_file(path: Path) -> list[np.ndarray]:
    data = path.read_bytes()
    magic, *dims = struct.unpack_from("<8s4I", data)
    if (magic != b"K3NRX001" or dims[0] not in (4, 6) or
            dims[1] not in (16, 24, 32) or dims[1] != dims[2] or dims[3] != 4):
        raise ValueError("invalid joint receiver weight header")
    hidden = dims[1]
    floats = np.frombuffer(data, dtype="<f4", offset=24)
    if floats.size != dims[0] * hidden + hidden * hidden + 6 * hidden + 4:
        raise ValueError("invalid weight count")
    shapes = [(dims[0], hidden), (hidden,), (hidden, hidden),
              (hidden,), (hidden, 4), (4,)]
    tensors = []
    offset = 0
    for shape in shapes:
        count = int(np.prod(shape))
        tensors.append(floats[offset:offset + count].reshape(shape))
        offset += count
    return tensors


def check_case(library, weights: list[np.ndarray], rb: int, repeats: int) -> None:
    rng = np.random.default_rng(20261001 + rb)
    subcarriers = rb * 12
    received = rng.integers(-500, 501, size=(subcarriers, 13, 2), dtype=np.int16)
    channel = rng.integers(-350, 351, size=(3, subcarriers // 2, 2), dtype=np.int16)
    output = np.zeros((subcarriers, 13, 4), dtype=np.int16)
    ports = np.array([1], dtype=np.int16)
    dmrs = np.array([2, 7, 11], dtype=np.int32)
    pilot_positions = np.array([0, 2, 4, 6, 8, 10], dtype=np.int32)
    scale = 0.5
    input_count = weights[0].shape[0]
    x = np.empty((subcarriers, 13, input_count), dtype=np.float32)
    x[:, :, :2] = received.astype(np.float32) * (scale / 256.0)
    interpolate = os.environ.get("XSAI_RECEIVER_H_INTERP") == "1"
    for sc in range(subcarriers):
        for symbol in range(13):
            if interpolate:
                if symbol <= dmrs[0]:
                    left = right = 0
                    time_fraction = 0.0
                elif symbol >= dmrs[2]:
                    left = right = 2
                    time_fraction = 0.0
                else:
                    left = 0 if symbol < dmrs[1] else 1
                    right = left + 1
                    time_fraction = (symbol - dmrs[left]) / (dmrs[right] - dmrs[left])
                first = sc // 2
                second = min(first + (sc & 1), subcarriers // 2 - 1)
                frequency_fraction = 0.5 if sc & 1 else 0.0
                h0 = (1 - frequency_fraction) * channel[left, first].astype(np.float32) + frequency_fraction * channel[left, second].astype(np.float32)
                h1 = (1 - frequency_fraction) * channel[right, first].astype(np.float32) + frequency_fraction * channel[right, second].astype(np.float32)
                x[sc, symbol, 2:4] = ((1 - time_fraction) * h0 + time_fraction * h1) * (scale / 256.0)
            else:
                nearest = int(np.argmin(np.abs(dmrs - symbol)))
                x[sc, symbol, 2:4] = (
                    channel[nearest, sc // 2].astype(np.float32) * (scale / 256.0)
                )
    if input_count == 6:
        yr, yi, hr, hi = (x[..., component] for component in range(4))
        inverse = 1.0 / (hr * hr + hi * hi + 0.05)
        x[..., 4] = (yr * hr + yi * hi) * inverse
        x[..., 5] = (yi * hr - yr * hi) * inverse
    w1, b1, w2, b2, w3, b3 = weights
    hidden1 = np.maximum(x.reshape(-1, input_count) @ w1 + b1, 0)
    hidden2 = np.maximum(hidden1 @ w2 + b2, 0)
    gain = float(os.environ.get("XSAI_RECEIVER_LLR_GAIN", "1"))
    expected = np.clip(
        np.rint((-gain * (hidden2 @ w3 + b3)) * 256), -32768, 32767
    )
    expected = expected.astype(np.int16).reshape(output.shape)

    elapsed = []
    for _ in range(repeats):
        begin = time.perf_counter_ns()
        ok = library.spacemit_receiver_decode(
            ports.ctypes.data_as(ctypes.POINTER(ctypes.c_int16)), 1,
            received.ctypes.data_as(ctypes.POINTER(ctypes.c_int16)),
            subcarriers, 13, ctypes.c_float(scale),
            channel.ctypes.data_as(ctypes.POINTER(ctypes.c_int16)), 3,
            dmrs.ctypes.data_as(ctypes.POINTER(ctypes.c_int32)),
            pilot_positions.ctypes.data_as(ctypes.POINTER(ctypes.c_int32)),
            output.ctypes.data_as(ctypes.POINTER(ctypes.c_int16)),
            None, None, None,
        )
        elapsed.append((time.perf_counter_ns() - begin) / 1000)
        if ok != 1:
            raise RuntimeError(f"native receiver failed for {rb} RB")
    delta = np.abs(output.astype(np.int32) - expected.astype(np.int32))
    sign_mismatch = np.count_nonzero(
        (output < 0) != (expected < 0)
    )
    print(
        f"rb={rb} mean_us={np.mean(elapsed):.3f} p95_us={np.percentile(elapsed,95):.3f} "
        f"max_llr_delta={delta.max()} sign_mismatch={sign_mismatch} "
        f"llr_count={output.size}", flush=True
    )
    if sign_mismatch or delta.max() > 2:
        raise AssertionError("RVV and NumPy output disagree")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("library", type=Path)
    parser.add_argument("weights", type=Path)
    parser.add_argument("--repeats", type=int, default=20)
    parser.add_argument("--rb", type=int, choices=(1, 5, 12, 24), action="append")
    args = parser.parse_args()
    library = ctypes.CDLL(str(args.library.resolve()))
    library.spacemit_receiver_runtime_init.restype = ctypes.c_int
    library.spacemit_receiver_runtime_shutdown.restype = ctypes.c_int
    library.spacemit_receiver_decode.restype = ctypes.c_int
    library.spacemit_receiver_decode.argtypes = [
        ctypes.POINTER(ctypes.c_int16), ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_int16), ctypes.c_size_t, ctypes.c_size_t,
        ctypes.c_float, ctypes.POINTER(ctypes.c_int16), ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_int32), ctypes.POINTER(ctypes.c_int32),
        ctypes.POINTER(ctypes.c_int16), ctypes.c_void_p, ctypes.c_void_p,
        ctypes.c_void_p,
    ]
    if library.spacemit_receiver_runtime_init():
        raise RuntimeError("native receiver initialization failed")
    try:
        for rb in (args.rb or (24, 12)):
            check_case(library, weights_from_file(args.weights), rb, args.repeats)
    finally:
        library.spacemit_receiver_runtime_shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
