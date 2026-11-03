// Drives the CodeLLDB debug adapter the way VS Code does when you press F5, without the UI:
// sends the generated "Xcode: Debug" launch config, sets a breakpoint, and checks it is hit
// with the right local variable value. Used by the CI test for setup-vscode-xcode.sh.
//
// node dap-test.mjs --adapter <codelldb> --liblldb <LLDB> --workspace <dir>
//                   --file <abs source path> --line <n> --var name=value [--console <file> --expect <text>]
import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";

const args = {};
for (let i = 2; i < process.argv.length; i += 2) args[process.argv[i].replace(/^--/, "")] = process.argv[i + 1];
const [varName, varValue] = (args.var || "").split("=");
const log = (...a) => console.log("[dap]", ...a);
const fail = (msg) => { console.error("[dap] FAIL:", msg); cleanup(1); };

let adapter, sock, seq = 1, buf = Buffer.alloc(0);
const pending = new Map();
const events = [];
const waiters = [];

function cleanup(code) {
  try { sock && sock.destroy(); } catch {}
  try { adapter && adapter.kill(); } catch {}
  process.exit(code);
}
setTimeout(() => fail("timed out after 180s"), 180_000).unref();

function onData(chunk) {
  buf = Buffer.concat([buf, chunk]);
  for (;;) {
    const sep = buf.indexOf("\r\n\r\n");
    if (sep < 0) return;
    const len = Number(/Content-Length: (\d+)/i.exec(buf.slice(0, sep).toString())[1]);
    if (buf.length < sep + 4 + len) return;
    const msg = JSON.parse(buf.slice(sep + 4, sep + 4 + len).toString());
    buf = buf.slice(sep + 4 + len);
    if (msg.type === "response") {
      const p = pending.get(msg.request_seq);
      pending.delete(msg.request_seq);
      if (p) msg.success ? p.resolve(msg.body || {}) : p.reject(new Error(`${msg.command}: ${msg.message} ${JSON.stringify(msg.body || {})}`));
    } else if (msg.type === "event") {
      if (msg.event === "output") process.stdout.write(`[dap:${msg.body.category || "out"}] ${msg.body.output}`);
      else log("event", msg.event, JSON.stringify(msg.body || {}));
      events.push(msg);
      for (const w of [...waiters]) if (w.pred(msg)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(msg); }
    } else if (msg.type === "request") {
      // Reverse requests (e.g. runInTerminal) aren't supported by this client.
      send({ type: "response", request_seq: msg.seq, command: msg.command, success: false, message: "unsupported" });
    }
  }
}

function send(obj) {
  const body = JSON.stringify({ seq: seq++, ...obj });
  sock.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
  return obj.seq;
}
function request(command, a = {}) {
  const s = seq;
  send({ type: "request", command, arguments: a });
  return new Promise((resolve, reject) => pending.set(s, { resolve, reject }));
}
function waitEvent(pred, ms, what) {
  const existing = events.find(pred);
  if (existing) { events.splice(events.indexOf(existing), 1); return Promise.resolve(existing); }
  return new Promise((resolve, reject) => {
    const w = { pred, resolve };
    waiters.push(w);
    setTimeout(() => reject(new Error(`no ${what} within ${ms / 1000}s`)), ms).unref();
  });
}

// CodeLLDB's extension starts the adapter with --connect <port> (adapter dials back to us);
// older versions used --port <port> (adapter listens). Support both.
async function connect() {
  const viaConnect = await new Promise((resolve) => {
    const server = net.createServer((s) => { server.close(); resolve(s); });
    server.listen(0, "127.0.0.1", () => {
      const port = server.address().port;
      adapter = spawn(args.adapter, ["--liblldb", args.liblldb, "--connect", String(port)], { stdio: ["ignore", "inherit", "inherit"] });
      adapter.on("exit", (c) => { log("adapter exited", c); resolve(null); });
      setTimeout(() => { server.close(); resolve(null); }, 20_000).unref();
    });
  });
  if (viaConnect) { log("adapter connected back (--connect)"); return viaConnect; }
  try { adapter.kill(); } catch {}
  const port = 40000 + Math.floor(Math.random() * 10000);
  adapter = spawn(args.adapter, ["--liblldb", args.liblldb, "--port", String(port)], { stdio: ["ignore", "inherit", "inherit"] });
  for (let i = 0; i < 40; i++) {
    await new Promise((r) => setTimeout(r, 500));
    const s = await new Promise((resolve) => {
      const c = net.connect(port, "127.0.0.1", () => resolve(c));
      c.on("error", () => resolve(null));
    });
    if (s) { log("connected to adapter (--port)"); return s; }
  }
  fail("couldn't connect to the CodeLLDB adapter");
}

// Same substitution VS Code does for the generated launch.json.
function loadLaunchConfig() {
  const raw = fs.readFileSync(`${args.workspace}/.vscode/launch.json`, "utf8").replace(/^\/\/.*\n/, "");
  const cfg = JSON.parse(raw).configurations.find((c) => c.name === "Xcode: Debug");
  if (!cfg) fail("launch.json has no 'Xcode: Debug' configuration");
  const sub = (v) => typeof v === "string" ? v.replaceAll("${workspaceFolder}", args.workspace)
    : Array.isArray(v) ? v.map(sub) : v && typeof v === "object" ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, sub(x)])) : v;
  const out = sub(cfg);
  delete out.preLaunchTask; delete out.postDebugTask; // the CI script runs those tasks itself
  if (out.request === "custom") { out.request = "launch"; out.custom = true; } // what the CodeLLDB extension does
  return out;
}

async function main() {
  sock = await connect();
  sock.on("data", onData);
  const caps = await request("initialize", { clientID: "vscode", adapterID: "lldb", linesStartAt1: true, columnsStartAt1: true, pathFormat: "path" });
  log("initialized adapter; supportsConfigurationDoneRequest =", !!caps.supportsConfigurationDoneRequest);

  const cfg = loadLaunchConfig();
  log("launch config:", JSON.stringify(cfg));
  const launched = request("launch", cfg).catch((e) => fail(`launch failed: ${e.message}`));
  await waitEvent((e) => e.event === "initialized", 60_000, "initialized event");
  const bps = await request("setBreakpoints", { source: { path: args.file }, breakpoints: [{ line: Number(args.line) }] });
  log("breakpoint:", JSON.stringify(bps.breakpoints));
  await request("configurationDone");
  await launched;
  log("launch request completed");

  let stopped;
  for (let i = 0; i < 3; i++) {
    stopped = await waitEvent((e) => e.event === "stopped", 60_000, "stopped event");
    if (stopped.body.reason === "breakpoint") break;
    log(`stopped with reason '${stopped.body.reason}' (not our breakpoint); continuing`);
    await request("continue", { threadId: stopped.body.threadId });
  }
  if (stopped.body.reason !== "breakpoint") fail(`never stopped at the breakpoint (last reason: ${stopped.body.reason})`);

  const { stackFrames } = await request("stackTrace", { threadId: stopped.body.threadId, levels: 5 });
  const top = stackFrames[0];
  log(`stopped at ${top.name} ${top.source && top.source.path}:${top.line}`);
  if (Number(top.line) !== Number(args.line)) fail(`stopped at line ${top.line}, expected ${args.line}`);
  if (varName) {
    const { scopes } = await request("scopes", { frameId: top.id });
    let found;
    for (const sc of scopes) {
      const { variables } = await request("variables", { variablesReference: sc.variablesReference });
      found = variables.find((v) => v.name === varName) || found;
    }
    if (!found) fail(`variable '${varName}' not visible in the debugger`);
    log(`${varName} = ${found.value}`);
    if (!String(found.value).includes(varValue)) fail(`${varName} = ${found.value}, expected it to contain ${varValue}`);
  }

  await request("continue", { threadId: stopped.body.threadId });
  if (args.console) {
    await new Promise((r) => setTimeout(r, 4000));
    const text = fs.existsSync(args.console) ? fs.readFileSync(args.console, "utf8") : "";
    if (!text.includes(args.expect)) fail(`app output in ${args.console} doesn't contain '${args.expect}' while running:\n${text}`);
    log(`app output streams while debugging (found '${args.expect}')`);
  }
  await request("disconnect", { terminateDebuggee: true }).catch(() => {});
  log("PASS");
  cleanup(0);
}

main().catch((e) => fail(e.stack || e.message));
