// Shapes recorded keystrokes the way the Tadak tuner page does, and writes the finished clips for the app.
//   node tools/shape.js '<settings json from the tuner>' <in-dir> <out-dir>
// <in-dir> holds down_*.wav, up_*.wav and space_*.wav as 48 kHz 16-bit mono (afconvert -d LEI16@48000 -c 1).
// The app plays the output as is (see prepared() in main.swift): only its pitch and overall level are set there.
const atob = globalThis.atob ?? (b => Buffer.from(b, 'base64').toString('latin1'));
const SR = 48000;
function decode(b64) {
  const bin = atob(b64), x = new Float32Array(bin.length >> 1);
  for (let i = 0; i < x.length; i++) { const v = bin.charCodeAt(2 * i) | bin.charCodeAt(2 * i + 1) << 8; x[i] = (v > 32767 ? v - 65536 : v) / 32768; }
  return x;
}
// RBJ cookbook filters.
function bq(type, f, q, db) {
  const A = 10 ** (db / 40), w = 2 * Math.PI * f / SR, cs = Math.cos(w), sn = Math.sin(w);
  let b0, b1, b2, a0, a1, a2;
  if (type === 'peak') { const al = sn / (2 * q); [b0, b1, b2, a0, a1, a2] = [1 + al * A, -2 * cs, 1 - al * A, 1 + al / A, -2 * cs, 1 - al / A]; }
  else if (type === 'hp') { const al = sn / (2 * q); [b0, b1, b2, a0, a1, a2] = [(1 + cs) / 2, -(1 + cs), (1 + cs) / 2, 1 + al, -2 * cs, 1 - al]; }
  else {
    const al = sn / 2 * Math.SQRT2, r = 2 * Math.sqrt(A) * al;
    if (type === 'low') [b0, b1, b2, a0, a1, a2] = [A * ((A + 1) - (A - 1) * cs + r), 2 * A * ((A - 1) - (A + 1) * cs), A * ((A + 1) - (A - 1) * cs - r), (A + 1) + (A - 1) * cs + r, -2 * ((A - 1) + (A + 1) * cs), (A + 1) + (A - 1) * cs - r];
    else [b0, b1, b2, a0, a1, a2] = [A * ((A + 1) + (A - 1) * cs + r), -2 * A * ((A - 1) + (A + 1) * cs), A * ((A + 1) + (A - 1) * cs - r), (A + 1) - (A - 1) * cs + r, 2 * ((A - 1) - (A + 1) * cs), (A + 1) - (A - 1) * cs - r];
  }
  return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0];
}
function filt(x, c) {
  const y = new Float32Array(x.length); let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  for (let i = 0; i < x.length; i++) { const v = c[0] * x[i] + c[1] * x1 + c[2] * x2 - c[3] * y1 - c[4] * y2; x2 = x1; x1 = x[i]; y2 = y1; y1 = v; y[i] = v; }
  return y;
}
function peakAt(x) { let p = 0; for (let i = 1; i < x.length; i++) if (Math.abs(x[i]) > Math.abs(x[p])) p = i; return p; }
// Felt loudness, as in the app: energy above 300 Hz with 1.5 kHz+ weighted +4 dB.
function audible(x) { const y = filt(filt(x, bq('hp', 300, 0.707, 0)), bq('high', 1500, 0.707, 4)); let e = 0; for (const v of y) e += v * v; return Math.max(e / SR, 1e-12); }
// 1 ms RMS envelope, one value per 0.5 ms, from `from` on.
function envelope(y, from) { const out = []; for (let j = from; j + 48 < y.length; j += 24) { let e = 0; for (let k = j; k < j + 48; k++) e += y[k] * y[k]; out.push(Math.sqrt(e / 48)); } return out; }
function applyGains(y, from, g) { for (let i = from; i < y.length; i++) { const t = (i - from) / 24, k = Math.min(Math.floor(t), g.length - 1), n = Math.min(k + 1, g.length - 1), f = t - Math.floor(t); if (k >= 0) y[i] *= g[k] * (1 - f) + g[n] * f; } }

function shape(x, s) {
  let y = Float32Array.from(x);
  for (const [t, f, q, k] of [['low', 150, 0.707, 'low'], ['peak', 400, 1, 'lowmid'], ['peak', 1200, 1, 'mid'], ['peak', 4000, 1, 'high'], ['high', 9000, 0.707, 'air']])
    if (s[k]) y = filt(y, bq(t, f, q, s[k]));
  let p = peakAt(y);
  const pre = s.pre ?? 10;
  if (pre < 10) {  // drop what comes before the main hit (a smaller first impact, or the previous key's tail)
    const start = Math.max(0, p - Math.round(pre / 1000 * SR)); y = y.slice(start); p -= start;
    const fade = Math.min(p, 24); for (let i = 0; i < fade; i++) y[i] *= i / fade;
  }
  if (s.tick > 0) {   // the impact: everything above 1.5 kHz quieter until 3 ms past the peak, easing back over 5 ms
    const hi = filt(filt(y, bq('hp', 1500, 0.707, 0)), bq('hp', 1500, 0.707, 0)), g0 = 10 ** (-s.tick / 20), n3 = p + 144, n8 = n3 + 240;
    for (let i = 0; i < y.length; i++) { const g = i < n3 ? g0 : i < n8 ? g0 + (1 - g0) * (i - n3) / (n8 - n3) : 1; y[i] += hi[i] * (g - 1); }
  }
  if (s.tail < 80) { const hold = p + 288, tau = s.tail / 1000 * SR; for (let i = hold; i < y.length; i++) y[i] *= Math.exp(-(i - hold) / tau); }
  const rate = s.rebound === true ? 1.2 : +s.rebound || 0;
  if (rate > 0) {     // nothing rises again after the hit: the envelope may only fall, at most `rate` dB/ms
    const from = p + 24, e = envelope(y, from), step = 10 ** (-rate * 0.5 / 20); let m = 0;
    applyGains(y, from, e.map(v => { m = m === 0 ? v : Math.min(m, Math.max(v, m * step)); return Math.min(1, m / Math.max(v, 1e-12)); }));
  }
  if (s.gate > -60) { // what's left under the threshold (hiss, room) fades out
    const top = Math.abs(y[p]), thr = top * 10 ** (s.gate / 20), from = p + 48;
    applyGains(y, from, envelope(y, from).map(v => Math.min(1, (v / thr) ** 2)));
  }
  if (pre >= 10) for (let i = 0; i < Math.min(24, y.length); i++) y[i] *= i / 24;
  for (let i = 0; i < Math.min(96, y.length); i++) y[y.length - 1 - i] *= i / 96;
  return y;
}
// A whole set: presses scaled to a fixed felt loudness, releases keep their natural level plus `rel`, and `even`
// pulls each stroke toward its set's median (0 % keeps the recording's own variation, 100 % makes them equal).
// Separate impacts in a stroke, relative to the main one: [ms, dB] for envelope peaks over 20 % of it with a dip between.
function impacts(y) {
  const h = 12, env = []; for (let j = 0; j + h < y.length; j += h) { let e = 0; for (let k = j; k < j + h; k++) e += y[k] * y[k]; env.push(Math.sqrt(e / h)); }
  let top = 0; for (const v of env) top = Math.max(top, v);
  const pk = [];
  for (let i = 1; i < env.length - 1; i++) if (env[i] > top * 0.2 && env[i] >= env[i - 1] && env[i] > env[i + 1]) {
    const last = pk[pk.length - 1];
    if (last) { let dip = Infinity; for (let k = last.i; k <= i; k++) dip = Math.min(dip, env[k]); if (dip > 0.55 * Math.min(env[i], last.v)) { if (env[i] > last.v) { last.i = i; last.v = env[i]; } continue; } }
    pk.push({ i, v: env[i] });
  }
  const m = pk.reduce((a, b) => b.v > a.v ? b : a, pk[0] || { i: 0, v: 1 });
  return pk.map(q => [(q.i - m.i) * 0.25, 20 * Math.log10(q.v / m.v)]);
}
const doubled = y => impacts(y).some(([ms, db]) => ms !== 0 && Math.abs(ms) <= 6 && db > -4);
function build(base, s) {
  const med = a => a.slice().sort((p, q) => p - q)[a.length >> 1];
  let down = base.down.map(x => shape(x, s)), up = base.up.map(x => shape(x, s));
  if (s.single) {   // keep at least half the set so it doesn't get repetitive
    const keep = set => { const ok = set.filter(y => !doubled(y)); return ok.length >= set.length / 2 ? ok : set; };
    down = keep(down); up = keep(up);
  }
  let space = (base.space || []).map(x => shape(x, s)); if (s.single && space.length) { const ok = space.filter(y => !doubled(y)); if (ok.length >= space.length / 2) space = ok; }
  const ed = down.map(audible), eu = up.map(audible), k = Math.sqrt(1.25e-4 / med(ed));
  const scale = (set, es, extra) => { const m = med(es); return set.map((y, i) => {
    let a = k * extra * (m / es[i]) ** (0.5 * s.even / 100), top = 0;
    for (const v of y) top = Math.max(top, Math.abs(v));
    a = Math.min(a, 0.9 / Math.max(top, 1e-9));
    return y.map(v => v * a);
  }); };
  return { down: scale(down, ed, 1), up: scale(up, eu, 10 ** (s.rel / 20)), space: space.length ? scale(space, space.map(audible), 1) : [] };
}

if (require.main === module) {
  const fs = require('fs'), path = require('path'), [settings, inDir, outDir] = process.argv.slice(2);
  const s = JSON.parse(settings);
  const read = f => { const b = fs.readFileSync(f), i = b.indexOf('data'), n = b.readUInt32LE(i + 4), x = new Float32Array(n / 2);
    for (let k = 0; k < x.length; k++) x[k] = b.readInt16LE(i + 8 + 2 * k) / 32768; return x; };
  const write = (f, y, g) => { const b = Buffer.alloc(44 + 2 * y.length);
    b.write('RIFF', 0); b.writeUInt32LE(36 + 2 * y.length, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
    b.writeUInt32LE(SR, 24); b.writeUInt32LE(SR * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(2 * y.length, 40);
    for (let k = 0; k < y.length; k++) b.writeInt16LE(Math.max(-32767, Math.min(32767, Math.round(y[k] * g * 32767))), 44 + 2 * k);
    fs.writeFileSync(f, b); };
  const list = p => fs.readdirSync(inDir).filter(f => f.startsWith(p + '_') && f.endsWith('.wav')).sort().map(f => read(path.join(inDir, f)));
  const out = build({ down: list('down'), up: list('up'), space: list('space') }, s);
  let top = 0; for (const set of Object.values(out)) for (const y of set) for (const v of y) top = Math.max(top, Math.abs(v));
  const g = 0.89 / top;   // one gain for every clip: the relative levels are the sound, the app sets the overall level
  fs.mkdirSync(outDir, { recursive: true });
  for (const [kind, set] of Object.entries(out)) set.forEach((y, i) => write(path.join(outDir, `${kind}_${String(i).padStart(2, '0')}.wav`), y, g));
  console.log(Object.entries(out).map(([k, v]) => `${k} ${v.length}`).join(', '));
}
