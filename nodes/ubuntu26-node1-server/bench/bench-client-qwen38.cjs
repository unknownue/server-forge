// Benchmark client for local SGLang (Qwen3.8-27B-NVFP4 sweep).
// Modes:
//   bench  — fixed workload, streaming, measures TTFT/ITL/output tok/s
//   ladder — sequential single requests with growing prompt sizes to find max usable context
//
// Env:
//   MODEL_ID        model id to send (default /data/work/models/RadixArk/Qwen3.8-27B-NVFP4)
//   BASE_URL        (default http://127.0.0.1:30000/v1)
//   N_PROMPTS       bench: number of requests (default 64)
//   CONC            bench: concurrency (default 8)
//   INPUT_TOKENS    bench: approx input tokens per prompt (default 512)
//   MAX_TOKENS      bench/ladder: max output tokens (default 128 bench / 32 ladder)
//   LADDER_SIZES    ladder: comma-separated approx token sizes (default a standard list)
//   CHARS_PER_TOKEN filler chars per approx token (default 4; Qwen3.8 tokenizer is ~6.1)
const OpenAI = require('/home/unknownue/.dsh/profiles/node_modules/openai');

const MODEL = process.env.MODEL_ID || '/data/work/models/RadixArk/Qwen3.8-27B-NVFP4';
const BASE = process.env.BASE_URL || 'http://127.0.0.1:30000/v1';

const WORDS = ['the','quick','brown','fox','jumps','over','lazy','dog','server','forge','model','benchmark','context','window','memory','kernel','token','stream','batch','graph'];
function filler(chars) {
  let out = '';
  let i = 0;
  while (out.length < chars) {
    out += WORDS[i % WORDS.length] + ' ';
    i++;
  }
  return out;
}

function median(arr) {
  if (!arr.length) return null;
  const a = [...arr].sort((x, y) => x - y);
  return a[Math.floor(a.length / 2)];
}

async function oneStream(client, prompt, maxTokens) {
  const start = Date.now();
  const s = await client.chat.completions.create({
    model: MODEL,
    messages: [{ role: 'user', content: prompt }],
    max_tokens: maxTokens,
    stream: true,
    stream_options: { include_usage: true },
  });
  let first = null, lastTs = start, chunks = 0, outTok = 0, itlSum = 0, itlN = 0;
  for await (const c of s) {
    const now = Date.now();
    if (first === null && c.choices && c.choices.length && c.choices[0].delta && c.choices[0].delta.content) first = now;
    if (c.usage && c.usage.completion_tokens) outTok = c.usage.completion_tokens;
    if (first !== null && chunks > 0) { itlSum += now - lastTs; itlN++; }
    lastTs = now;
    chunks++;
  }
  return { ok: 1, ttft: first === null ? -1 : first - start, dur: Date.now() - start, outTok, itlMean: itlN ? itlSum / itlN : 0 };
}

async function bench() {
  const CONC = +process.env.CONC || 8;
  const N = +process.env.N_PROMPTS || 64;
  const CPT = +process.env.CHARS_PER_TOKEN || 4;
  const IN_CHARS = (+process.env.INPUT_TOKENS || 512) * CPT;
  const MAX_TOKENS = +process.env.MAX_TOKENS || 128;
  const prompts = Array.from({ length: N }, (_, i) => filler(IN_CHARS) + `\n[prompt ${i}]\n`);
  const stats = [];
  let idx = 0;
  const t0 = Date.now();
  async function worker() {
    while (true) {
      const i = idx++;
      if (i >= N) return;
      const client = new OpenAI({ baseURL: BASE, apiKey: 'unused', timeout: 600000, maxRetries: 0 });
      try {
        stats.push(await oneStream(client, prompts[i], MAX_TOKENS));
      } catch (e) {
        stats.push({ ok: 0, err: String(e && e.message || e).slice(0, 120), dur: Date.now() - t0 });
      }
    }
  }
  await Promise.all(Array.from({ length: CONC }, worker));
  const wall = (Date.now() - t0) / 1000;
  const ok = stats.filter(s => s.ok);
  const outTokTotal = ok.reduce((a, s) => a + s.outTok, 0);
  const ttfts = ok.filter(s => s.ttft >= 0).map(s => s.ttft);
  console.log(JSON.stringify({
    n: N,
    ok: ok.length,
    failed: stats.length - ok.length,
    wallSec: +wall.toFixed(1),
    outTokTotal,
    outputTokPerSec: +(outTokTotal / wall).toFixed(1),
    ttftMeanMs: ttfts.length ? +(ttfts.reduce((a, b) => a + b, 0) / ttfts.length).toFixed(0) : null,
    ttftP50Ms: median(ttfts),
    itlMeanMs: +(ok.reduce((a, s) => a + s.itlMean, 0) / ok.length).toFixed(1),
    firstErr: stats.find(s => !s.ok) ? stats.find(s => !s.ok).err : null,
  }));
}

async function ladder() {
  const sizes = (process.env.LADDER_SIZES || '8192,16384,32768,65536,98304,131072,163840,196608,229376,262144')
    .split(',').map(s => +s.trim()).filter(Boolean);
  const MAX_TOKENS = +process.env.MAX_TOKENS || 32;
  const CPT = +process.env.CHARS_PER_TOKEN || 4;
  const results = [];
  for (const size of sizes) {
    const client = new OpenAI({ baseURL: BASE, apiKey: 'unused', timeout: 900000, maxRetries: 0 });
    const prompt = filler(size * CPT);
    const start = Date.now();
    try {
      const r = await client.chat.completions.create({
        model: MODEL,
        messages: [{ role: 'user', content: prompt }],
        max_tokens: MAX_TOKENS,
        stream: false,
      });
      results.push({ size, ok: 1, promptTokens: r.usage ? r.usage.prompt_tokens : null, sec: +((Date.now() - start) / 1000).toFixed(1) });
    } catch (e) {
      results.push({ size, ok: 0, err: String(e && e.message || e).slice(0, 120), sec: +((Date.now() - start) / 1000).toFixed(1) });
      break; // ascending order: stop at first failure
    }
  }
  // check whether the server survived
  let alive = 0;
  try {
    const client = new OpenAI({ baseURL: BASE, apiKey: 'unused', timeout: 5000, maxRetries: 0 });
    await client.models.list();
    alive = 1;
  } catch (e) { alive = 0; }
  console.log(JSON.stringify({ results, serverAlive: alive }));
}

const mode = process.argv[2] || 'bench';
(mode === 'ladder' ? ladder() : bench()).then(() => process.exit(0)).catch((e) => {
  console.error('FATAL', e && e.message);
  process.exit(1);
});
