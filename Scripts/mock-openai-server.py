from http.server import BaseHTTPRequestHandler, HTTPServer
import json, re

CLEAN = "你好，世界。这是对转写与翻译流水线的一次测试。"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(length) or b'{}')
        messages = body.get('messages', [])
        system = messages[0]['content'] if messages else ''
        user = messages[-1]['content'] if messages else ''
        if '润色' in system:
            lines = [ln.strip() for ln in user.splitlines() if re.match(r'^\[\d+\]', ln.strip())]
            out = "\n".join(re.sub(r'^(\[\d+\])\s*.*$', r'\1 ' + CLEAN, ln) for ln in lines)
        elif 'hello' in user.lower() or 'world' in user.lower():
            out = CLEAN
        else:
            out = '译：' + user.strip()
        payload = json.dumps({"choices": [{"message": {"role": "assistant", "content": out}}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

HTTPServer(('127.0.0.1', 8765), Handler).serve_forever()
