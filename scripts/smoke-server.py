#!/usr/bin/env python3
"""Local, disposable browser fixture. Run with python3 scripts/smoke-server.py."""
from http.server import BaseHTTPRequestHandler, HTTPServer

ARTICLE = """<article><h1>A quieter way to explore</h1>
<p>Oasis keeps the browser familiar, so you can concentrate on what you came to read. This local test page exercises navigation, search, downloads, file selection, and reading mode without sending any data to an external service.</p>
<h2>Room for the web</h2><p>A browser should leave room for ideas. Native controls, a clear address field, and a dependable history make it easy to find your way back. A private window should keep its visits out of the saved library.</p></article>"""

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/download':
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="oasis-test.txt"')
            self.end_headers()
            self.wfile.write(b'Oasis download verified.\n')
            return
        title = 'Second page' if self.path == '/second' else 'Oasis Browser Check'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(f'''<!doctype html><html><head><title>{title}</title>
<meta name="viewport" content="width=device-width"><style>body{{font:18px system-ui;max-width:760px;margin:60px auto;padding:20px;background:#fafaf7;color:#253d32;line-height:1.6}}nav{{display:flex;gap:20px;flex-wrap:wrap}}button,input{{font:inherit;margin:10px 0}}a{{color:#315e4d}}</style></head>
<body><h1>{title}</h1><nav><a href="/">Home</a><a href="/second">Second page</a><a href="/second" target="_blank">New tab</a><a href="/download" download>Download test file</a></nav>
{ARTICLE}<button onclick="alert('JavaScript dialog works')">Show alert</button>
<button onclick="document.getElementById('result').innerText=confirm('Confirm this local test?')?'Confirmed':'Cancelled'">Confirm</button>
<input type="file"><p id="result"></p></body></html>'''.encode())

if __name__ == '__main__':
    print('Oasis browser fixture: http://127.0.0.1:8793', flush=True)
    HTTPServer(('127.0.0.1', 8793), Handler).serve_forever()
