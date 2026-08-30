#!/usr/bin/env python3
"""lanes-board-server.py — the tiny stdlib server behind scripts/lanes-board.sh.

    python3 scripts/lanes-board-server.py <port> <graph.json> <lanes-snapshot.py>

Two routes, no deps, binds 127.0.0.1 ONLY (the wrapper enforces the rest):
    GET /           → the board page (plain HTML + fetch, self-refreshes every 10s)
    GET /lanes.json → the SHARED renderer run fresh per request (--json --activity)
                      — one source of truth for line shape/sort (see its file head);
                      a renderer failure is a LOUD 500 carrying the renderer's stderr,
                      never a stale-looking empty board.

No auth by design: localhost-only by default, tailnet-only when the wrapper's
--tailnet flag maps it — the mesh is the boundary, never the public internet.
"""

import json
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GRAPH = sys.argv[2]
RENDERER = sys.argv[3]

PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>kickoff · lanes</title>
<style>
  :root{color-scheme:dark;--bg:#101214;--card:#171a1d;--line:#24292e;--fg:#e8e6e1;
        --dim:#8b949e;--acc:#e8b339;--ok:#3fb950;--bad:#f85149;--warn:#d29922;--cl:#58a6ff}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--fg);
       font:15px/1.45 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif}
  main{max-width:640px;margin:0 auto;padding:20px 16px 48px}
  h1{font-size:17px;font-weight:600;margin:0 0 2px}
  h1 em{font-style:normal;color:var(--acc)}
  #meta{color:var(--dim);font-size:12.5px;margin-bottom:14px}
  .lane{display:flex;align-items:center;gap:10px;background:var(--card);
        border:1px solid var(--line);border-radius:10px;padding:10px 12px;margin:8px 0}
  .lane.stale{border-color:var(--bad)}
  .ic{font-size:16px;width:22px;text-align:center;flex:none}
  .who{flex:1;min-width:0}
  .id{font:12px/1.2 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--dim)}
  .ag{font-weight:600;font-size:14.5px}
  .st{flex:none;font-size:11px;font-weight:600;letter-spacing:.4px;text-transform:uppercase;
      padding:3px 8px;border-radius:99px;border:1px solid var(--line);color:var(--dim)}
  .st.run{color:var(--acc);border-color:var(--acc)} .st.cl{color:var(--cl);border-color:var(--cl)}
  .st.ok{color:var(--ok);border-color:var(--ok)} .st.bad{color:var(--bad);border-color:var(--bad)}
  .st.warn{color:var(--warn);border-color:var(--warn)}
  .meta2{flex:none;text-align:right;color:var(--dim);font-size:12px;line-height:1.5}
  .meta2 .pr-ok{color:var(--ok)} .meta2 .pr-bad{color:var(--bad)}
  .meta2 .rs{color:var(--warn)} .meta2 .old{color:var(--bad)}
  .tail,.empty{color:var(--dim);font-size:13px;text-align:center;padding:14px 0}
  .err{border:1px solid var(--bad);border-radius:10px;padding:12px;color:var(--bad);
       font-size:13px;white-space:pre-wrap}
  @media (max-width:420px){ .st{display:none} }
</style></head><body><main>
<h1>kickoff <em>· lanes</em></h1>
<div id="meta">loading…</div>
<div id="board"><div class="empty">loading the fleet…</div></div>
<script>
const ST={running:["▶","run"],claimed:["⏳","cl"],done:["✅","ok"],
          "proof-failed":["🔴","bad"],unverified:["⚠️","warn"],failed:["❌","bad"]};
function age(m){if(m==null)return"n/a";
  if(m<60)return m+"m"; if(m<1440)return Math.floor(m/60)+"h"; return Math.floor(m/1440)+"d"}
function render(d){
  const n=d.total||0; 
  document.getElementById("meta").textContent=
    n ? (n+" lane"+(n>1?"s":"")+" · refreshes every 10s") : "";
  if(!n){document.getElementById("board").innerHTML=
    '<div class="empty">No lanes in the ledger — the fleet is idle.</div>';return}
  let h="";
  for(const r of d.lanes){
    const [ic,cl]=ST[r.status]||["·",""];
    const stale=r.status==="running"&&(r.age_min==null||r.age_min>15);
    const proof=r.status==="done"?'<span class="pr-ok">proof passed</span>'
      :r.status==="proof-failed"?'<span class="pr-bad">proof FAILED</span>'
      :(r.proof?"proof declared":"no proof");
    const bits=[age(r.age_min)+(stale?' <span class="old">stale</span>':"")];
    if(r.respawns)bits.push('<span class="rs">↻ '+r.respawns+"</span>");
    if(r.msgs!=null)bits.push(r.msgs+" msgs");
    bits.push(proof);
    h+=`<div class="lane${stale?" stale":""}"><div class="ic">${ic}</div>`
      +`<div class="who"><div class="ag">${r.agent}</div><div class="id">${r.short}</div></div>`
      +`<div class="st ${cl}">${r.status}</div>`
      +`<div class="meta2">${bits.join(" · ")}</div></div>`;
  }
  if(d.truncated>0)h+=`<div class="tail">+${d.truncated} more not shown</div>`;
  document.getElementById("board").innerHTML=h;
}
async function tick(){
  try{const r=await fetch("/lanes.json");
    if(!r.ok)throw new Error(await r.text());
    render(await r.json());
  }catch(e){document.getElementById("board").innerHTML=
    '<div class="err">board fetch failed — the server or renderer is degraded:\\n'+e.message+"</div>"}
}
setInterval(tick,10000);tick();
</script></main></body></html>
"""


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet — the wrapper's log file is for crashes
        pass

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/lanes.json"):
            try:
                # the SHARED renderer, fresh per request — never a cached snapshot,
                # never a re-implementation of the line shape
                p = subprocess.run(
                    [sys.executable, RENDERER, "--json", "--activity", GRAPH],
                    capture_output=True, text=True, timeout=15)
            except Exception as e:
                self._send(500, f"renderer failed to run: {e}".encode(),
                           "text/plain; charset=utf-8")
                return
            if p.returncode != 0:
                self._send(500, f"renderer failed: {p.stderr.strip()}",
                           "text/plain; charset=utf-8")
                return
            self._send(200, p.stdout.encode(), "application/json")
            return
        self._send(200, PAGE.encode(), "text/html; charset=utf-8")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
