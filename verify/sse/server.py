# A slow SSE stream: three events, half a second apart. If a client sees them as they arrive,
# the deltas between arrivals are visible; if it buffers, all three land at once.
import http.server, sys, time
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        for i in range(3):
            self.wfile.write(('data: chunk%d\n\n' % i).encode())
            self.wfile.flush()
            time.sleep(0.5)
    def log_message(self, *args): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
