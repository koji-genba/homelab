# syntax=docker/dockerfile:1
# Export tools never enter the serving image. Locks target Linux amd64 / CPython 3.12.
FROM python:3.12-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b AS export
ENV HF_HUB_DISABLE_XET=1 HF_HUB_DISABLE_TELEMETRY=1 DO_NOT_TRACK=1
WORKDIR /build
COPY requirements.txt ./
RUN pip install --no-cache-dir --only-binary=:all: --require-hashes -r requirements.txt
COPY export_model.py LICENSE NOTICE ./
RUN python export_model.py

# Local/CI reference only: same TEI, original safetensors + unchanged config.
FROM ghcr.io/huggingface/text-embeddings-inference:cpu-1.9.4@sha256:2538ea1c9640d3763b15af668039d24172d063b42337b0c27796fc2be180c78d AS candle-reference
COPY --from=export /source /model
ENV HF_HUB_OFFLINE=1
CMD ["--model-id", "/model"]

FROM ghcr.io/huggingface/text-embeddings-inference:cpu-1.9.4@sha256:2538ea1c9640d3763b15af668039d24172d063b42337b0c27796fc2be180c78d AS runtime
# ONNX exists, safetensors do not: TEI selects ORT and cannot fall back to Candle.
COPY --from=export /model /model
ENV HF_HUB_OFFLINE=1
LABEL org.opencontainers.image.title="homelab TEI Ruri reranker ONNX" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/koji-genba/homelab"
CMD ["--model-id", "/model"]
