"""Export the frozen reliability-conditioned 2x16x16x2 model to FP16 ONNX."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("model_json", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--rows", type=int, default=0,
                        help="fixed axis rows; 0 keeps the first dimension dynamic")
    args = parser.parse_args()

    payload = json.loads(args.model_json.read_text())
    assert payload["architecture"] == [2, 16, 16, 2]
    params = payload["parameters"]
    assert len(params) == 6
    arrays = [np.asarray(value, dtype=np.float16) for value in params]
    expected = ((2, 16), (16,), (16, 16), (16,), (16, 2), (2,))
    assert tuple(x.shape for x in arrays) == expected

    initializers = [
        numpy_helper.from_array(value, name=name)
        for value, name in zip(arrays, ("w1", "b1", "w2", "b2", "w3", "b3"))
    ]
    rows: int | str = args.rows if args.rows else "axis_rows"
    graph = helper.make_graph(
        [
            helper.make_node("Gemm", ["axis_features", "w1", "b1"], ["z1"]),
            helper.make_node("Relu", ["z1"], ["h1"]),
            helper.make_node("Gemm", ["h1", "w2", "b2"], ["z2"]),
            helper.make_node("Relu", ["z2"], ["h2"]),
            helper.make_node("Gemm", ["h2", "w3", "b3"], ["axis_logits"]),
        ],
        "distilled_reliability_demapper",
        [helper.make_tensor_value_info("axis_features", TensorProto.FLOAT16, [rows, 2])],
        [helper.make_tensor_value_info("axis_logits", TensorProto.FLOAT16, [rows, 2])],
        initializer=initializers,
    )
    model = helper.make_model(
        graph,
        producer_name="xsai-airan",
        opset_imports=[helper.make_opsetid("", 13)],
    )
    model.ir_version = 8
    model.metadata_props.add(key="source_sha256", value=digest(args.model_json))
    model.metadata_props.add(key="axis_rows", value=str(args.rows or "dynamic"))
    onnx.checker.check_model(model)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    onnx.save(model, args.output)
    print(json.dumps({
        "output": str(args.output),
        "sha256": digest(args.output),
        "shape": [rows, 2],
        "dtype": "float16",
        "ops": [node.op_type for node in graph.node],
    }, indent=2))


if __name__ == "__main__":
    main()
