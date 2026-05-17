# Benchmark Suite

Performance and stability tests for AI training servers.

## Quick Start

```bash
# AI inference performance (recommended first test)
bash benchmark/gpu/download-mlperf-assets.sh bert
bash benchmark/gpu/mlperf-inference.sh bert Offline 0,1,2,3

# GPU stress / interconnect
bash benchmark/gpu/gpu-burn.sh 600
bash benchmark/gpu/p2p-bandwidth.sh

# Storage
bash benchmark/storage/fio-bench.sh /data/fio-test 10G

# Network (server on one node, client on another)
bash benchmark/network/iperf3-test.sh server              # node A
bash benchmark/network/iperf3-test.sh client 10.0.0.101   # node B
```

## GPU Benchmarks

### `mlperf-inference.sh` — MLPerf Inference

Industry-standard AI inference benchmark. Requires model download first.

| Script | Purpose | When to use |
|--------|---------|-------------|
| `download-mlperf-assets.sh` | Download models & datasets to `/data/work/mlperf/` | Run once per benchmark |
| `mlperf-inference.sh` | Build TensorRT engines + run inference | Repeated testing |

```
Usage:
  download-mlperf-assets.sh [BENCHMARK]
  mlperf-inference.sh [BENCHMARK] [SCENARIO] [GPUS]

Benchmarks:  bert  ·  resnet50  ·  dlrm  ·  rnnt  ·  ssd-mobilenet  ·  retinanet  ·  3d-unet
Scenarios:   Offline  ·  Server  ·  SingleStream
Defaults:    bert Offline 0
```

| Benchmark | Domain | Model size | Dataset | Typical throughput (RTX 6000D) |
|-----------|--------|------------|---------|------|
| `bert` | NLP (BERT-Large) | ~1.3GB | SQuAD v1.1 | ~3000 QPS |
| `resnet50` | Vision (ResNet-50) | ~100MB | ImageNet | ~10000 QPS |
| `dlrm` | Recommendation | ~4GB | Criteo 1TB | ~2M QPS |
| `rnnt` | Speech (RNN-T) | ~600MB | LibriSpeech | ~20000 QPS |

Assets are cached under `/data/work/mlperf/` across runs. Results are saved to `benchmark/results/`.

### `gpu-burn.sh` — GPU Stress Test

Sustained compute load to validate thermal/power stability.

```
Usage: gpu-burn.sh [DURATION_SECONDS]   (default: 300)
```

### `p2p-bandwidth.sh` — GPU Interconnect Topology

Shows NVLink / PCIe bandwidth between GPU pairs. Read-only, no GPU load.

### `nccl-test.sh` — NCCL Multi-GPU Communication

Tests all-reduce bandwidth across GPUs using PyTorch+NCCL in Docker.

## Network Benchmarks

### `iperf3-test.sh`

Point-to-point network bandwidth between nodes.

```
Usage:
  iperf3-test.sh server                # Run on server node
  iperf3-test.sh client <SERVER_IP>    # Run on client node
```

## Storage Benchmarks

### `fio-bench.sh`

Sequential read/write I/O throughput on a given directory.

```
Usage: fio-bench.sh [TEST_DIR] [TEST_SIZE]
Defaults: /data/fio-test 10G
```

## Adding a New Benchmark

1. Place the script under the relevant subdirectory (`gpu/`, `network/`, `storage/`)
2. Follow the existing conventions: `set -euo pipefail`, source `scripts/lib/utils.sh`
3. Add it to this README
