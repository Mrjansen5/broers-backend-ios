// Injected by the Broers Backend iPhone app into broersbackend.snjco.ca/cal/ (WebViewController.swift).
// The web Radio tab (public/cal/radio.js) is left exactly as it is; this script only:
//  1. catches taps on its Join / Leave / mute buttons first (capture phase) and sends them to the native radio,
//     which keeps running with the iPhone locked; the web radio itself never starts inside the app;
//  2. paints the native radio's state into the same Radio tab elements (#rJoin, #rLive, #rMute, #rStat, #rPeople,
//     #rDot), so it looks the same as on Android and the web;
//  3. swaps the "keep this screen open" iPhone note for the app's own note, with a switch for the headset-button mode.
;(() => {
  if (window.__broersNative || !window.webkit?.messageHandlers?.broersRadio) return
  const post = m => { try { window.webkit.messageHandlers.broersRadio.postMessage(m) } catch {} }
  const $ = id => document.getElementById(id)
  const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]))
  const MIC = '<svg viewBox="0 0 24 24"><rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/></svg>'
  const MICOFF = '<svg viewBox="0 0 24 24"><rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3M3 3l18 18"/></svg>'
  const tok = () => { try { return localStorage.getItem('bcal_token') || '' } catch { return '' } }
  const myName = () => { try { const me = window.BB?.me?.(); return me?.name || me?.email || 'You' } catch { return 'You' } }

  const N = window.__broersNative = {
    st: { on: false, muted: false, talking: false, you: '', status: '', callkit: true, peers: [] },
    update (s) { this.st = s; paint() }
  }

  // 1. buttons -> native
  addEventListener('click', e => {
    const b = e.target?.closest?.('#rJoin, #rLeave, #rMute, #rMode'); if (!b) return
    e.stopImmediatePropagation(); e.preventDefault()
    if (b.id === 'rJoin') {
      const t = tok()
      if (!t) { window.BB?.toast?.('Sign in again to use the radio.'); return }
      b.disabled = true; setTimeout(() => { b.disabled = false }, 1500)
      post({ cmd: 'join', token: t, name: myName() })
    } else if (b.id === 'rLeave') post({ cmd: 'leave' })
    else if (b.id === 'rMute') post({ cmd: 'toggle' })
    else if (b.id === 'rMode') post({ cmd: 'mode', callkit: !N.st.callkit })
  }, true)

  // 2. paint
  let painting = false
  function paint () {
    const sec = $('tRadio')
    painting = true
    try {
      const s = N.st, others = s.peers || []
      $('rJoin')?.classList.toggle('hide', s.on); $('rLive')?.classList.toggle('hide', !s.on)
      const m = $('rMute')
      if (m) {
        const cls = s.muted ? 'muted' : (s.talking ? 'talk' : '')
        const html = s.muted ? `${MICOFF}Muted<small>Press the headset button or tap to talk</small>` : `${MIC}Mic is ON<small>Press the headset button or tap to mute</small>`
        if (m.className !== cls) m.className = cls
        if (m.innerHTML !== html) m.innerHTML = html
      }
      const dot = $('rDot'); if (dot) { dot.classList.toggle('on', s.on); dot.classList.toggle('mut', s.on && s.muted) }
      // cal 1.8.0+: the radio opens from the Voice chat button in the team chat; show it lit while the native radio is on.
      const vb = $('tcVoice'); if (vb && vb.classList.contains('live') !== !!s.on) vb.classList.toggle('live', !!s.on)
      const stat = s.status || (s.on ? (others.length ? `On the channel with ${others.length} other${others.length === 1 ? '' : 's'}.` : 'You\'re on the channel. Nobody else is on yet.') : null)
      if (stat !== null && $('rStat') && $('rStat').textContent !== stat) $('rStat').textContent = stat
      if (s.on && $('rPeople')) {
        const rows = [{ id: s.you, name: myName() + ' (you)', muted: s.muted, talking: s.talking, self: true }].concat(others)
        const html = rows.map(p => {
          const bad = !p.self && p.link === 'bad'
          const cls = p.muted ? 'mut' : p.talking ? 'talk' : 'live'
          const what = bad ? 'can\'t hear — reconnecting' : p.muted ? 'muted' : p.talking ? 'talking' : (!p.self && p.link && p.link !== 'connected' ? 'connecting…' : 'listening')
          return `<div class="rp ${cls}${bad ? ' bad' : ''}" data-peer="${esc(p.id)}" data-state="${p.muted ? 'muted' : p.talking ? 'talking' : 'live'}"><i class="dot"></i><b>${esc(p.name)}</b><span>${what}</span></div>`
        }).join('')
        if ($('rPeople').innerHTML !== html) $('rPeople').innerHTML = html
      }
      const plat = $('rPlat')
      if (plat) {
        const html = 'iPhone app: voice chat keeps going with the screen locked or while you use another app, and it shows on the lock screen as a call called <b>Broers Radio</b> — its Mute button works too. Tap <b>Leave voice chat</b> here to hang up.' +
          `<br><button class="btn ghost" id="rMode" style="margin-top:10px;font-size:13px;padding:8px 12px">Headset button mode: ${s.callkit ? 'Call (default)' : 'Media'} — tap to switch</button>`
        if (plat.dataset.native !== html) { plat.innerHTML = html; plat.dataset.native = html }
      }
    } finally { painting = false }
  }

  // The web Radio repaints itself every 10 s (who's on) and on tab changes; put the native state back each time.
  let queued = false
  new MutationObserver(() => {
    if (painting || queued) return
    queued = true
    requestAnimationFrame(() => { queued = false; paint() })
  }).observe(document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ['class'] })

  post({ cmd: 'hello' }) // the native radio may already be on (page reloaded): ask for its state
})()
