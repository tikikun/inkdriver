import http.server, socketserver, json

PAGE = """<!doctype html><html><head><meta charset=utf-8><title>pen test</title></head>
<body style="margin:0;font:14px -apple-system,sans-serif">
<div style="padding:6px 10px;background:#222;color:#eee">Draw here with the pen. Results are sent to the local logger.</div>
<canvas id=c width=1400 height=760 style="background:#f4f4f4;display:block"></canvas>
<script>
const ctx=document.getElementById('c').getContext('2d');
let drawing=false, lx=0, ly=0, n=0;
const r=()=>document.getElementById('c').getBoundingClientRect();
function send(o){fetch('/log',{method:'POST',body:JSON.stringify(o)}).catch(()=>{});}
function rec(e,extra){
  const b=r();
  send(Object.assign({t:e.type,pt:e.pointerType,p:+e.pressure.toFixed(4),tx:e.tiltX,ty:e.tiltY,
    b:e.buttons,id:e.pointerId,w:+e.width.toFixed(2),h:+e.height.toFixed(2),
    ms:Math.round(performance.timeOrigin+e.timeStamp),
    x:Math.round(e.clientX-b.left),y:Math.round(e.clientY-b.top)},extra||{}));
}
function paint(e){
  const b=r(), x=e.clientX-b.left, y=e.clientY-b.top;
  if(drawing){ctx.beginPath();ctx.moveTo(lx,ly);ctx.lineTo(x,y);
    ctx.lineWidth=0.5+e.pressure*24;ctx.lineCap='round';ctx.strokeStyle='#111';ctx.stroke();}
  lx=x; ly=y;
}
addEventListener('pointerdown',e=>{drawing=true;rec(e,{marker:'down'});paint(e);});
addEventListener('pointermove',e=>{rec(e,{marker:'move'});paint(e);});
addEventListener('pointerup',e=>{drawing=false;rec(e,{marker:'up'});});
addEventListener('pointerover',e=>rec(e,{marker:'over'}));
addEventListener('pointerenter',e=>rec(e,{marker:'enter'}));
addEventListener('pointercancel',e=>rec(e,{marker:'cancel'}));
</script></body></html>"""

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Type','text/html'); self.send_header('Cache-Control','no-store'); self.end_headers()
        self.wfile.write(PAGE.encode())
    def do_POST(self):
        n=int(self.headers.get('Content-Length',0))
        with open('/tmp/ff_pen.log','a') as f: f.write(self.rfile.read(n).decode()+"\n")
        self.send_response(204); self.end_headers()
    def log_message(self,*a): pass

socketserver.TCPServer.allow_reuse_address=True
print("serving on 8799", flush=True)
with socketserver.TCPServer(("127.0.0.1",8799),H) as s: s.serve_forever()
