// Radio interop self-test: a web phone on CT215 (Chromium, fake 700 Hz mic, via the PUBLIC address) + the native iPhone
// app in a GitHub Actions simulator on the same channel. Temp shares deleted in finally; GitHub secret deleted after.
import { createRequire } from 'node:module'
import crypto from 'node:crypto'
import fs from 'node:fs'
import { execFileSync } from 'node:child_process'
const require = createRequire(import.meta.url)
const { chromium } = require('/opt/playwright/node_modules/playwright')
const Database = require('/opt/broers-app/node_modules/better-sqlite3')
const db = new Database('/opt/broers-app/data/broers.db')
const sha = s => crypto.createHash('sha256').update(s).digest('hex')
const sleep = ms => new Promise(r => setTimeout(r, ms))
const GH = process.env.GHT, REPO = 'Mrjansen5/broers-backend-ios'
const gh = async (path, opt = {}) => { const r = await fetch('https://api.github.com/repos/' + REPO + path, { ...opt, headers: { Authorization: 'token ' + GH, Accept: 'application/vnd.github+json', 'Content-Type': 'application/json' } }); return r.status === 204 ? {} : r.json().catch(() => ({})) }
const made = []; let b; const t0 = Date.now(); const log = (...a) => console.log(((Date.now() - t0) / 1000).toFixed(0).padStart(4) + 's', ...a)
try {
  const now = new Date().toISOString(), tok = {}
  for (const [k, email, name] of [['ios', 'staff-test-ios-selftest@invalid', 'iPhone Selftest'], ['web', 'staff-test-ios-webpeer@invalid', 'Web Peer Test']]) {
    if (db.prepare('SELECT 1 FROM wall_shares WHERE email=?').get(email)) throw new Error('exists ' + email)
    const id = db.prepare("INSERT INTO wall_shares (email, name, role, created_at) VALUES (?, ?, 'view', ?)").run(email, name, now).lastInsertRowid
    made.push(id); tok[k] = crypto.randomBytes(32).toString('hex')
    db.prepare('INSERT INTO wall_sessions (token_hash, share_id, created_at, last_used) VALUES (?, ?, ?, ?)').run(sha(tok[k]), id, now, now)
  }
  // secret
  const pk = await gh('/actions/secrets/public-key')
  const enc = execFileSync('python3', ['-c', 'import sys,base64;from nacl import public,encoding;k=public.PublicKey(sys.argv[1].encode(),encoding.Base64Encoder());print(base64.b64encode(public.SealedBox(k).encrypt(sys.stdin.read().encode())).decode())', pk.key], { input: tok.ios }).toString().trim()
  await gh('/actions/secrets/RADIO_SELFTEST_TOKEN', { method: 'PUT', body: JSON.stringify({ encrypted_value: enc, key_id: pk.key_id }) })
  log('secret set')
  // web peer
  execFileSync('sox', ['-n', '-r', '48000', '-c', '1', '-b', '16', '/tmp/ios-selftest-700.wav', 'synth', '1500', 'sine', '700', 'vol', '0.5'])
  b = await chromium.launch({ args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', '--use-file-for-fake-audio-capture=/tmp/ios-selftest-700.wav', '--autoplay-policy=no-user-gesture-required'] })
  const ctx = await b.newContext({ permissions: ['microphone'] })
  await ctx.addInitScript(t => localStorage.setItem('bcal_token', t), tok.web)
  const page = await ctx.newPage(); page.on('pageerror', e => log('pageerror', e.message))
  await page.goto('https://broersbackend.snjco.ca/cal/', { waitUntil: 'networkidle' })
  const pre = await page.evaluate(async t => (await (await fetch('/api/app/radio', { headers: { Authorization: 'Bearer ' + t } })).json()).peers, tok.web)
  if (pre.length) throw new Error('real people are on the radio right now - not testing: ' + pre.map(p => p.name).join(', '))
  await page.click('#radioTab'); await sleep(500); await page.click('#rJoin'); await sleep(3000)
  log('web peer on:', JSON.stringify(await page.evaluate(() => window.BBRadio.state().on)))
  await gh('/actions/workflows/ios.yml/dispatches', { method: 'POST', body: JSON.stringify({ ref: 'main', inputs: { selftest: true } }) })
  log('workflow dispatched')
  let last = '', seenOn = false, done = 0
  const hear = () => page.evaluate(async () => {
    const C = window.__ac || (window.__ac = new AudioContext()); await C.resume(); const out = {}
    for (const a of document.querySelectorAll('audio[data-peer]')) { if (!a.srcObject) continue
      if (!a.__an) { const an = C.createAnalyser(); an.fftSize = 2048; C.createMediaStreamSource(a.srcObject).connect(an); a.__an = an; await new Promise(r => setTimeout(r, 300)) }
      const t = new Float32Array(a.__an.fftSize); a.__an.getFloatTimeDomainData(t); let s = 0; for (const x of t) s += x * x; out[a.dataset.peer] = +Math.sqrt(s / t.length).toFixed(4) }
    return out })
  while (Date.now() - t0 < 35 * 60e3) {
    const s = await page.evaluate(() => window.BBRadio.state())
    const ios = s.peers.find(p => p.device === 'iphone-app')
    const strangers = s.peers.filter(p => !['iPhone Selftest'].includes(p.name))
    if (strangers.length) { log('SOMEONE REAL JOINED - leaving now:', strangers.map(p => p.name).join(', ')); await page.evaluate(() => window.BBRadio.leave('test')); break }
    const line = ios ? `iphone on: muted=${ios.muted} talking=${ios.talking} link=${(s.links.find(l => l.id === ios.id) || {}).state}` : 'iphone not on'
    if (line !== last) { log(line, ios ? JSON.stringify(await hear()) : ''); last = line }
    if (ios) seenOn = true
    if (seenOn && !ios) { if (++done > 3) break }
    await sleep(1000)
  }
  log('web log tail:', (await page.evaluate(() => window.BBRadio.log())).slice(-15).join('\n'))
} finally {
  try { await gh('/actions/secrets/RADIO_SELFTEST_TOKEN', { method: 'DELETE' }); log('secret deleted') } catch (e) { log('secret delete failed', e.message) }
  for (const id of made) { db.prepare('DELETE FROM wall_sessions WHERE share_id=?').run(id); db.prepare('DELETE FROM wall_shares WHERE id=?').run(id) }
  log('temp shares removed:', !db.prepare("SELECT 1 FROM wall_shares WHERE email LIKE 'staff-test-ios-%@invalid'").get())
  await b?.close()
}
