// 用 CDP 在真实 Chrome 里打开 camweb 页面，自动点「开始」，抓控制台报错与 <video> 状态
import fs from "node:fs";
const CDP = "http://127.0.0.1:9222";
const PAGE = process.env.PAGE || "http://10.0.0.18:8080/";
const MODE = process.env.MODE || "passthrough";
const WAIT = +(process.env.WAIT || 22);
const SHOT = process.env.SHOT || "";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const list = await (await fetch(CDP + "/json/list")).json();
const target = list.find((t) => t.type === "page");
if (!target) {
  console.error("找不到 page target:", JSON.stringify(list));
  process.exit(1);
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
let id = 0;
const pending = new Map();
const logs = [];
ws.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) {
    pending.get(m.id)(m);
    pending.delete(m.id);
    return;
  }
  if (m.method === "Runtime.consoleAPICalled") {
    logs.push(
      "[console." + m.params.type + "] " +
        m.params.args.map((a) => a.value ?? a.description ?? a.type).join(" ")
    );
  } else if (m.method === "Log.entryAdded") {
    const e = m.params.entry;
    logs.push("[log." + e.level + "] " + e.text + (e.url ? "   <" + e.url + ">" : ""));
  } else if (m.method === "Runtime.exceptionThrown") {
    logs.push(
      "[exception] " +
        (m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text)
    );
  }
};
function send(method, params = {}) {
  return new Promise((res, rej) => {
    const i = ++id;
    pending.set(i, (m) =>
      m.error ? rej(new Error(method + " -> " + JSON.stringify(m.error))) : res(m.result)
    );
    ws.send(JSON.stringify({ id: i, method, params }));
  });
}
await new Promise((r) => (ws.onopen = r));
await send("Runtime.enable");
await send("Log.enable");
await send("Page.enable");
await send("Network.enable");
try { await send("Network.clearBrowserCache"); } catch (e) {}
try { await send("Network.setCacheDisabled", { cacheDisabled: true }); } catch (e) {}

await send("Page.navigate", { url: PAGE });
await sleep(4000);

const click = await send("Runtime.evaluate", {
  expression: `(function(){
    var b = document.querySelector('.modes button[data-mode="${MODE}"]'); if (b) b.click();
    var ch = document.getElementById('selChan');
    if (ch && "${process.env.CHAN || ""}") ch.value = "${process.env.CHAN || ""}";
    var s = document.getElementById('btnStart'); if (s) s.click();
    return 'mode=${MODE} chan=' + (ch ? ch.value : '-') + ' clicked';
  })()`,
  returnByValue: true,
});
console.log("操作:", click.result.value);

await sleep(WAIT * 1000);

const probe = await send("Runtime.evaluate", {
  expression: `(function(){
    var v = document.getElementById('view');
    var out = {
      modeBadge: document.getElementById('modeBadge').textContent,
      chipPlay:  document.getElementById('chipPlay').textContent,
      hint:      document.getElementById('hint').textContent,
      errText:   document.getElementById('errText').textContent,
      stReal:    document.getElementById('stReal').textContent,
      stFps:     document.getElementById('stFps').textContent,
      stPlay:    document.getElementById('stPlay').textContent,
      stLat:     document.getElementById('stLat').textContent,
      stCpu:     document.getElementById('stCpu').textContent,
      hlsGlobal: window.Hls ? 'loaded' : 'MISSING',
      video: v ? {
        display: v.style.display,
        readyState: v.readyState,
        networkState: v.networkState,
        paused: v.paused,
        currentTime: +v.currentTime.toFixed(2),
        duration: v.duration,
        w: v.videoWidth, h: v.videoHeight,
        err: v.error ? (v.error.code + ' / ' + v.error.message) : null,
        buffered: (function(){ var a=[]; for(var i=0;i<v.buffered.length;i++) a.push([+v.buffered.start(i).toFixed(2), +v.buffered.end(i).toFixed(2)]); return a; })()
      } : null
    };
    return JSON.stringify(out, null, 1);
  })()`,
  returnByValue: true,
});
console.log("=== 页面探针 (" + MODE + ") ===");
console.log(probe.result.value);

if (SHOT) {
  const rect = await send("Runtime.evaluate", {
    expression:
      `(function(){var r=document.getElementById('videowrap').getBoundingClientRect();` +
      `return JSON.stringify({x:r.x,y:r.y,width:r.width,height:r.height});})()`,
    returnByValue: true,
  });
  const r = JSON.parse(rect.result.value);
  const shot = await send("Page.captureScreenshot", {
    format: "png",
    clip: { x: r.x, y: r.y, width: r.width, height: r.height, scale: 1 },
  });
  fs.writeFileSync(SHOT, Buffer.from(shot.data, "base64"));
  console.log("截图已保存: " + SHOT + "  (" + r.width + "x" + r.height + ")");
}

console.log("=== 控制台 / 网络日志（去重） ===");
const seen = new Set();
for (const l of logs) {
  if (!seen.has(l)) { seen.add(l); console.log(l); }
}
ws.close();
