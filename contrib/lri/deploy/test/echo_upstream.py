# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

"""Upstream de teste: responde com o caminho e os cabeçalhos recebidos, em JSON (portas 3000 e 6042)."""

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Echo(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 (nome exigido por BaseHTTPRequestHandler)
        body = json.dumps({
            'port': self.server.server_address[1],  # type: ignore[index]
            'path': self.path,
            'headers': {k.lower(): v for k, v in self.headers.items()},
        }).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):  # noqa: A002 (assinatura da classe base)
        del format, args


servers = [ThreadingHTTPServer(('127.0.0.1', port), Echo) for port in (3000, 6042)]
for server in servers[1:]:
    threading.Thread(target=server.serve_forever, daemon=True).start()
servers[0].serve_forever()
