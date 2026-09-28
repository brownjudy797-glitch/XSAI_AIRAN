"""Make a fixed-batch copy of the small Spark ONNX model without an ONNX dependency.

The exporter represents every dynamic leading dimension as the protobuf field
``dim_param = "batch_size"``.  Replacing it with ``dim_value`` plus an ignored
padding field keeps all enclosing protobuf message lengths unchanged.  The
result is validated by ONNX Runtime before it is accepted.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import shutil

import onnxruntime as ort


def encode_varint(value: int) -> bytes:
    encoded = bytearray()
    while value >= 0x80:
        encoded.append((value & 0x7F) | 0x80)
        value >>= 7
    encoded.append(value)
    return bytes(encoded)


parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
parser.add_argument("destination", type=Path)
parser.add_argument("--batch", type=int, default=3312)
args = parser.parse_args()

old = b"\x12\x0abatch_size"
dim_value = b"\x08" + encode_varint(args.batch)
padding_bytes = len(old) - len(dim_value) - 2
if padding_bytes < 0 or padding_bytes > 127:
    raise ValueError("batch value cannot be encoded with the fixed-size patch")
# Unknown length-delimited field 15 is legal protobuf and ignored by ONNX.
new = dim_value + b"\x7a" + bytes([padding_bytes]) + bytes(padding_bytes)
assert len(new) == len(old)

model = args.source.read_bytes()
occurrences = model.count(old)
if occurrences != 6:
    raise RuntimeError(f"expected 6 dynamic dimensions, found {occurrences}")
args.destination.parent.mkdir(parents=True, exist_ok=True)
args.destination.write_bytes(model.replace(old, new))

# This Spark export stores the weights in an external data file whose relative
# name remains unchanged when the ONNX protobuf is copied.
external_name = "neural_demapper.2xfloat16.onnx.data"
external_source = args.source.parent / external_name
external_destination = args.destination.parent / external_name
if external_name.encode() in model and not external_destination.exists():
    if not external_source.is_file():
        raise RuntimeError(f"missing external weight file: {external_source}")
    shutil.copy2(external_source, external_destination)

session = ort.InferenceSession(str(args.destination), providers=["CPUExecutionProvider"])
input_shape = session.get_inputs()[0].shape
output_shape = session.get_outputs()[0].shape
if input_shape != [args.batch, 2] or output_shape != [args.batch, 4]:
    raise RuntimeError(f"unexpected fixed shapes: {input_shape} -> {output_shape}")
print(f"fixed_batch={args.batch} replacements={occurrences} "
      f"input={input_shape} output={output_shape} path={args.destination}")
