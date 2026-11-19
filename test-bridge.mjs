import { createRequire } from 'node:module'
import crypto from 'node:crypto'
import fs from 'node:fs'
const require = createRequire(import.meta.url)
const { chromium } = require('/opt/playwright/node_modules/playwright')
const Database = require('/opt/broers-app/node_modules/better-sqlite3')
const BRIDGE = fs.readFileSync('/home/stephen/business/Master Session/broers-backend-ios/BroersBackend/RadioBridge.js', 'utf8')
const db = new Database('/opt/broers-app/data/broers.db')
const sha = s => crypto.createHash('sha256').update(s).digest('hex')
const sleep = ms => new Promise(r => setTimeout(r, ms))
let fails = 0; const ok = (c, m) => { console.log((c ? 'PASS ' : 'FAIL ') + m); if (!c) fails++ }
const made = []; let b
try {
  const now = new Date().toISOString(), email = 'staff-test-iosbridge@invalid'
  const share = db.prepare("INSERT INTO wall_shares (email, name, role, created_at) VALUES (?, 'iOS Bridge Test', 'view', ?)").run(email, now).lastInsertRowid
  made.push(share)
  const token = crypto.randomBytes(32).toString('hex')
  db.prepare('INSERT INTO wall_sessions (token_hash, share_id, created_at, last_used) VALUES (?, ?, ?, ?)').run(sha(token), share, now, now)
  b = await chromium.launch({ args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'] })
  const ctx = await b.newContext({ viewport: { width: 400, height: 860 }, userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 BroersBackendiOS/1.0.0' })
  await ctx.addInitScript(t => {
    localStorage.setItem('bcal_token', t)
    window.__posted = []
    window.webkit = { messageHandlers: { broersRadio: { postMessage: m => window.__posted.push(m) } } }
    window.BROERS_IOS_APP = '1.0.0'
  }, token)
  await ctx.addInitScript(src => document.addEventListener('DOMContentLoaded', () => { (0, eval)(src) }), BRIDGE)
  const page = await ctx.newPage(); const errs = []
  page.on('pageerror', e => errs.push(e.message))
  await page.goto('http://127.0.0.1:8800/cal/', { waitUntil: 'networkidle' })
  ok(await page.evaluate(() => !!window.__broersNative), 'bridge loaded in the real page')
  ok((await page.evaluate(() => window.__posted)).some(m => m.cmd === 'hello'), 'bridge asked native for state on load')
  await page.click('#radioTab'); await sleep(500)
  await page.click('#rJoin'); await sleep(800)
  const posted = await page.evaluate(() => window.__posted)
  const j = posted.find(m => m.cmd === 'join')
  ok(j && j.token === token, 'Join tap went to native with the sign-in token')
  ok(!(await page.evaluate(() => window.BBRadio.state().on)), 'web radio did NOT start inside the app')
  await page.evaluate(() => window.__broersNative.update({ on: true, muted: false, talking: false, you: 'me1', status: '', callkit: true, peers: [{ id: 'p2', name: 'Sam', muted: false, talking: true, link: 'connected' }, { id: 'p3', name: 'Josh', muted: true, talking: false, link: 'connecting' }] }))
  await sleep(300)
  const dom = () => page.evaluate(() => ({ join: document.getElementById('rJoin').classList.contains('hide'), live: !document.getElementById('rLive').classList.contains('hide'), mute: document.getElementById('rMute').textContent, stat: document.getElementById('rStat').textContent, people: [...document.querySelectorAll('#rPeople .rp')].map(r => r.textContent), plat: document.getElementById('rPlat').textContent }))
  let d = await dom(); console.log(JSON.stringify(d))
  ok(d.join && d.live && /Mic is ON/.test(d.mute) && /2 others/.test(d.stat) && d.people.length === 3 && /Samtalking/.test(d.people.join('|')) && /Joshmuted/.test(d.people.join('|')), 'native state painted into the Radio tab')
  ok(/lock screen/.test(d.plat) && /Call \(default\)/.test(d.plat), 'iPhone app note + mode switch shown')
  console.log('waiting 12 s for the web page\'s own 10 s refresh…'); await sleep(12000)
  d = await dom()
  ok(d.join && d.live && d.people.length === 3 && /2 others/.test(d.stat), 'native state survives the web radio\'s periodic repaint')
  await page.click('#rMute'); await page.click('#rMode'); await page.click('#rLeave'); await sleep(300)
  const cmds = (await page.evaluate(() => window.__posted)).map(m => m.cmd)
  ok(cmds.includes('toggle') && cmds.includes('mode') && cmds.includes('leave'), 'mute / mode / leave taps went to native: ' + cmds.join(','))
  await page.evaluate(() => window.__broersNative.update({ on: true, muted: true, talking: false, you: 'me1', status: '', callkit: false, peers: [] }))
  await sleep(200); d = await dom()
  ok(/Muted/.test(d.mute) && /Media/.test(d.plat) && /Nobody else/.test(d.stat), 'muted + media mode painted')
  ok(!(await page.evaluate(() => window.BBRadio.state().on)), 'web radio still never started')
  ok(errs.length === 0, 'no page errors ' + errs.join(' | '))
} finally {
  for (const id of made) { db.prepare('DELETE FROM wall_sessions WHERE share_id = ?').run(id); db.prepare('DELETE FROM wall_shares WHERE id = ?').run(id) }
  console.log('temp share removed:', !db.prepare("SELECT 1 FROM wall_shares WHERE email='staff-test-iosbridge@invalid'").get())
  await b?.close()
}
console.log(fails ? `${fails} FAILED` : 'ALL PASS'); process.exit(fails ? 1 : 0)
