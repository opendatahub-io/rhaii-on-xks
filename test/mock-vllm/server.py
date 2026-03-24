"""Mock vLLM server implementing OpenAI-compatible API for e2e testing.

Supports HTTPS with certificates (matching KServe mTLS behavior)
or plain HTTP when no certs are provided.

Environment variables:
  SSL_CERTFILE  - Path to TLS certificate (default: /var/run/kserve/tls/tls.crt)
  SSL_KEYFILE   - Path to TLS private key (default: /var/run/kserve/tls/tls.key)
  PORT          - Listen port (default: 8000)
"""

import json
import os
import ssl
import time
import uuid
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = int(os.environ.get("PORT", "8000"))
MODEL_NAME = "mock-model"
CERT_FILE = os.environ.get("SSL_CERTFILE", "/var/run/kserve/tls/tls.crt")
KEY_FILE = os.environ.get("SSL_KEYFILE", "/var/run/kserve/tls/tls.key")


class Handler(BaseHTTPRequestHandler):
    # Use HTTP/1.0 to avoid keep-alive issues with SSL
    protocol_version = "HTTP/1.0"

    def do_GET(self):
        if self.path == "/health":
            self._json(200, {"status": "ok"})
        elif self.path == "/v1/models":
            self._json(200, {
                "object": "list",
                "data": [{"id": MODEL_NAME, "object": "model", "owned_by": "mock"}],
            })
        elif self.path == "/metrics":
            self._text(200, "# mock vllm metrics\nvllm:num_requests_running 0\n")
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        except (json.JSONDecodeError, ValueError):
            self._json(400, {"error": "invalid JSON"})
            return

        if self.path == "/v1/chat/completions":
            prompt = body.get("messages", [{}])[-1].get("content", "")
            self._json(200, {
                "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": body.get("model", MODEL_NAME),
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": f"Mock response to: {prompt}"},
                    "finish_reason": "stop",
                }],
                "usage": {"prompt_tokens": 10, "completion_tokens": 8, "total_tokens": 18},
            })
        elif self.path == "/v1/completions":
            self._json(200, {
                "id": f"cmpl-{uuid.uuid4().hex[:12]}",
                "object": "text_completion",
                "created": int(time.time()),
                "model": body.get("model", MODEL_NAME),
                "choices": [{
                    "index": 0,
                    "text": " This is a mock completion response.",
                    "finish_reason": "stop",
                }],
                "usage": {"prompt_tokens": 5, "completion_tokens": 7, "total_tokens": 12},
            })
        else:
            self._json(404, {"error": "not found"})

    def _json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _text(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(f"[mock-vllm] {fmt % args}")


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), Handler)

    if os.path.exists(CERT_FILE) and os.path.exists(KEY_FILE):
        try:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(CERT_FILE, KEY_FILE)
            server.socket = ctx.wrap_socket(server.socket, server_side=True)
            print(f"[mock-vllm] Starting HTTPS on port {PORT}")
        except (ssl.SSLError, PermissionError, OSError) as e:
            print(f"[mock-vllm] TLS setup failed ({e}), falling back to HTTP on port {PORT}")
    else:
        print(f"[mock-vllm] No certs found, starting HTTP on port {PORT}")

    server.serve_forever()
