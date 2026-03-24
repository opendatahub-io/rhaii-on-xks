FROM python:3.11-slim

LABEL name="vllm-mock" \
      summary="Mock vLLM server for e2e testing" \
      description="Lightweight OpenAI-compatible API server with HTTPS support. \
Used to validate KServe LLMInferenceService control plane without GPU or model download." \
      io.k8s.display-name="Mock vLLM Server"

RUN useradd -r -u 1000 -m -s /sbin/nologin vllm && \
    mkdir -p /app && \
    chown 1000:0 /app

COPY --chown=1000:0 server.py /app/server.py

USER 1000
WORKDIR /app
EXPOSE 8000

ENTRYPOINT ["python3"]
CMD ["/app/server.py"]
