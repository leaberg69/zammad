"""Captura as telas de aceite da ux-spec de branding (docs/lri/esteira/branding/ux-spec-v*.yaml).

Uso: python contrib/lri/qa/capture.py <url-base> <pasta-de-saida>

Roda só contra instância LOCAL do Zammad (recusa outra URL), com os usuários de teste do
contrib/lri/qa/wizard.json; a senha vem de LRI_QA_PASSWORD (padrão: a do wizard de teste).
Gera PNG por tela e tema e um relatorio.json com, por tela: os azuis de destaque residuais
(matiz 195-215, saturação > 40%), os textos com cor de marca abaixo de 4,5:1 (3:1 se grandes)
e os fundos de estado em cor de marca abaixo de 3:1 contra o vizinho (WCAG 1.4.11; ignorado
quando o elemento tem a barra inset #74b527). Qualquer falha de etapa entra no relatório com
o motivo, e todo corte de lista registra o total; nada é descartado em silêncio.
"""

import json
import os
import re
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

BASE = sys.argv[1].rstrip('/')
if not re.match(r'^http://(localhost|127\.0\.0\.1)(:\d+)?$', BASE):
    sys.exit(f'capture.py recusado: {BASE!r} não é instância local (http://localhost ou http://127.0.0.1)')
OUT = Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)
SENHA = os.environ.get('LRI_QA_PASSWORD', 'LriTeste#2026')
USERS = {
    'cliente': 'cliente1@cliente.example.com',
    'agente': 'agente@lri.example',
    'admin': 'admin@lri.example',
}

PROBE = r"""
() => {
  const parse = (c) => { const m = c && c.match(/rgba?\(([^)]+)\)/); if (!m) return null;
    const p = m[1].split(',').map(x => parseFloat(x)); if (p.length > 3 && p[3] === 0) return null; return p.slice(0, 3); };
  const hsl = ([r, g, b]) => { r/=255; g/=255; b/=255; const mx=Math.max(r,g,b), mn=Math.min(r,g,b); let h=0, s=0; const l=(mx+mn)/2;
    if (mx!==mn) { const d=mx-mn; s = l>0.5 ? d/(2-mx-mn) : d/(mx+mn);
      h = mx===r ? (g-b)/d + (g<b?6:0) : mx===g ? (b-r)/d+2 : (r-g)/d+4; h*=60; } return [h, s*100, l*100]; };
  const lum = (rgb) => { const a = rgb.map(v => { v/=255; return v <= 0.03928 ? v/12.92 : Math.pow((v+0.055)/1.055, 2.4); });
    return 0.2126*a[0] + 0.7152*a[1] + 0.0722*a[2]; };
  const ratio = (a, b) => { const la = lum(a), lb = lum(b); return (Math.max(la, lb)+0.05)/(Math.min(la, lb)+0.05); };
  const bgOf = (el) => { while (el) { const c = parse(getComputedStyle(el).backgroundColor); if (c) return c; el = el.parentElement; } return [255,255,255]; };
  const brand = ['116,181,39','61,122,18','44,90,13','158,203,104'];
  const blues = [], low = [], state = []; let skipped = 0;
  for (const el of document.querySelectorAll('body *')) {
    const r = el.getBoundingClientRect(); if (r.width === 0 || r.height === 0) continue;
    const cs = getComputedStyle(el); if (cs.visibility === 'hidden' || cs.display === 'none') continue;
    for (const prop of ['color', 'backgroundColor', 'borderTopColor', 'fill', 'outlineColor']) {
      const c = parse(cs[prop]); if (!c) continue; if (prop === 'borderTopColor' && parseFloat(cs.borderTopWidth) === 0) continue;
      if (prop === 'outlineColor' && cs.outlineStyle === 'none') continue;
      const [h, s] = hsl(c); if (h >= 195 && h <= 215 && s > 40 && !el.closest('.avatar, [data-zammad-target=CommonAvatar]'))
        blues.push({ tag: el.tagName.toLowerCase(), cls: String(el.className).slice(0, 60), prop, color: cs[prop] });
    }
    const ownBg = parse(cs.backgroundColor);
    // Botões ficam de fora (identificados pelo rótulo; ux-spec v3, sem_mudanca_com_motivo); elemento dentro de
    // superfície da mesma cor também (não há fronteira para medir).
    if (ownBg && brand.includes(ownBg.join(',')) && !cs.boxShadow.includes('rgb(116, 181, 39)') && !el.closest('.btn')) {
      const around = bgOf(el.parentElement); const sr = ratio(ownBg, around);
      if (around.join(',') === ownBg.join(',')) { skipped++; } else
      if (sr < 3) state.push({ tag: el.tagName.toLowerCase(), cls: String(el.className).slice(0, 60), bg: cs.backgroundColor,
        vizinho: `rgb(${around.join(',')})`, ratio: +sr.toFixed(2) });
    }
    // Pseudo-elementos com conteúdo (ex.: filete do item escolhido, li.is-selected::before) também indicam estado.
    for (const pseudo of ['::before', '::after']) {
      const ps = getComputedStyle(el, pseudo); if (!ps.content || ps.content === 'none' || ps.content === 'normal') continue;
      const pbg = parse(ps.backgroundColor); if (!pbg || !brand.includes(pbg.join(','))) continue;
      const around = ownBg || bgOf(el.parentElement); const pr = ratio(pbg, around);
      if (pr < 3 && pbg.join(',') !== around.join(',')) state.push({ tag: el.tagName.toLowerCase() + pseudo, cls: String(el.className).slice(0, 60),
        bg: ps.backgroundColor, vizinho: `rgb(${around.join(',')})`, ratio: +pr.toFixed(2) });
    }
    // Exceções com motivo: a miniatura de prévia do login em Admin > Marca é maquete inativa (WCAG isenta
    // componente inativo); o Zammad a desenha com opacidade reduzida.
    if (el.closest('.login.branding')) continue;
    const hasText = [...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
    if (hasText) { let fg = parse(cs.color); if (!fg) { skipped++; continue; } const bg = bgOf(el);
      // Opacidade efetiva (cor com alfa e `opacity` dos ancestrais) mistura o texto com o fundo.
      let alpha = 1; const m = cs.color.match(/rgba\([^)]*,\s*([\d.]+)\)/); if (m) alpha *= parseFloat(m[1]);
      for (let a = el; a && a !== document.body; a = a.parentElement) alpha *= parseFloat(getComputedStyle(a).opacity);
      if (alpha < 1) fg = fg.map((v, i) => Math.round(v * alpha + bg[i] * (1 - alpha)));
      const isBrand = brand.includes(parse(cs.color).join(',')) || brand.includes(bg.join(','));
      const rr = ratio(fg, bg); const big = parseFloat(cs.fontSize) >= 24 || (parseFloat(cs.fontSize) >= 18.66 && parseInt(cs.fontWeight) >= 700);
      if (isBrand && rr < (big ? 3 : 4.5)) low.push({ text: el.textContent.trim().slice(0, 40), fg: `rgb(${fg.join(',')})`, alfa: +alpha.toFixed(2), bg: `rgb(${bg.join(',')})`, ratio: +rr.toFixed(2) }); }
  }
  return { blues: blues.slice(0, 40), blue_count: blues.length, low_contrast_brand: low.slice(0, 40), low_count: low.length,
    state_low_contrast: state.slice(0, 40), state_low_count: state.length, ignorados_sem_medida: skipped };
}
"""

report = {}


def note(key, **data):
    report.setdefault(key, {}).update(data)


def set_theme(page, theme):
    page.emulate_media(color_scheme=theme)
    page.evaluate("t => document.documentElement.setAttribute('data-theme', t)", theme)
    page.wait_for_timeout(400)


def shot(page, key, theme):
    name = f'{key}-{theme}'
    try:
        set_theme(page, theme)
        page.screenshot(path=str(OUT / f'{name}.png'), full_page=False)
        note(name, **page.evaluate(PROBE))
    except Exception as exc:  # registra o motivo; não interrompe as outras telas
        note(name, erro=f'{type(exc).__name__}: {exc}'[:300])


def legacy_login(page, who):
    page.goto(f'{BASE}/#login')
    page.wait_for_selector('input[name=username]', timeout=30000)
    page.fill('input[name=username]', USERS[who])
    page.fill('input[name=password]', SENHA)
    page.click('form button[type=submit]')
    page.wait_for_selector('.navigation, .main-navigation, #navigation', timeout=30000)
    page.wait_for_timeout(1500)


def go(page, hash_url, wait=1800):
    page.goto(f'{BASE}/{hash_url}')
    page.wait_for_timeout(wait)


with sync_playwright() as p:
    browser = p.chromium.launch()
    errors = []

    def ctx(**kw):
        c = browser.new_context(viewport={'width': 1440, 'height': 900}, locale='pt-BR', **kw)
        c.on('page', lambda pg: pg.on('console', lambda m: errors.append(m.text) if m.type == 'error' else None))
        return c

    # V1 / V2 — login, sem sessão
    c = ctx(); pg = c.new_page()
    pg.on('response', lambda r: errors.append(f'{r.status} {r.url}') if r.status >= 400 and ('/assets/lri/' in r.url or 'product_logo' in r.url) else None)
    pg.goto(f'{BASE}/#login'); pg.wait_for_selector('input[name=username]', timeout=60000); pg.wait_for_timeout(1500)
    note('meta', titulo=pg.title())
    for th in ('light', 'dark'):
        shot(pg, 'V1-login', th)
        set_theme(pg, th)
        pg.focus('input[name=username]'); pg.keyboard.press('Tab')
        shot(pg, 'V2-foco-senha', th)
        pg.focus('form button[type=submit]')
        pg.evaluate("document.querySelector('form button[type=submit]').focus({focusVisible:true})")
        shot(pg, 'V2-foco-entrar', th)
    c.close()

    # V3 / V4 — cliente
    c = ctx(); pg = c.new_page()
    try:
        legacy_login(pg, 'cliente')
        go(pg, '#ticket/view/my_tickets')
        note('V3-visibilidade', chamados_visiveis=pg.locator('text=Cliente Dois').count())
        for th in ('light', 'dark'):
            shot(pg, 'V3-portal-lista', th)
        go(pg, '#customer_ticket_new')
        pg.locator('input[name=title]').first.focus()
        shot(pg, 'V4-novo-chamado', 'light')
        for th in ('light', 'dark'):
            try:
                set_theme(pg, th)
                pg.locator('[data-attribute-name=group_id] input.js-input').first.click(timeout=5000, force=True)
                pg.wait_for_timeout(400)
                pg.keyboard.press('ArrowDown')
                pg.wait_for_timeout(300)
                shot(pg, 'V4-grupo-aberto', th)
                pg.keyboard.press('Escape')
            except Exception as exc:
                note(f'V4-grupo-aberto-{th}', erro=f'{type(exc).__name__}: {exc}'[:300])
    except Exception as exc:
        note('V3-V4', erro=f'{type(exc).__name__}: {exc}'[:300])
    c.close()

    # V5 / V6 / V7 / V8 — agente
    c = ctx(); pg = c.new_page()
    try:
        legacy_login(pg, 'agente')
        go(pg, '#dashboard')
        for th in ('light', 'dark'):
            shot(pg, 'V5-agente-dashboard', th)
        go(pg, '#ticket/zoom/2', 2500)
        for th in ('light', 'dark'):
            shot(pg, 'V6-agente-chamado', th)
            try:
                pg.locator('.btn--primary:visible').first.hover(timeout=5000)
                shot(pg, 'V7-primario-hover', th)
            except Exception as exc:
                note(f'V7-primario-hover-{th}', erro=f'{type(exc).__name__}: {exc}'[:300])
    except Exception as exc:
        note('V5-V8', erro=f'{type(exc).__name__}: {exc}'[:300])
    c.close()

    # V10 — admin
    c = ctx(); pg = c.new_page()
    try:
        legacy_login(pg, 'admin')
        go(pg, '#settings/branding')
        shot(pg, 'V10-admin-marca', 'light')
        shot(pg, 'V10-admin-marca', 'dark')
    except Exception as exc:
        note('V10', erro=f'{type(exc).__name__}: {exc}'[:300])
    c.close()

    # V9 — KB pública (só claro)
    c = ctx(); pg = c.new_page()
    try:
        pg.goto(f'{BASE}/help/pt-br'); pg.wait_for_timeout(1500)
        shot(pg, 'V9-kb', 'light')
    except Exception as exc:
        note('V9', erro=f'{type(exc).__name__}: {exc}'[:300])
    c.close()

    # V11 — mobile
    c = browser.new_context(viewport={'width': 390, 'height': 844}, locale='pt-BR', device_scale_factor=1)
    c.on('page', lambda p_: p_.on('console', lambda m: errors.append(f'mobile: {m.text}') if m.type == 'error' else None))
    pg = c.new_page()
    try:
        pg.goto(f'{BASE}/mobile/login'); pg.wait_for_timeout(2500)
        shot(pg, 'V11-mobile-login', 'dark')
        pg.fill('input[name=login]', USERS['agente']); pg.fill('input[name=password]', SENHA)
        pg.keyboard.press('Enter'); pg.wait_for_timeout(3500)
        shot(pg, 'V11-mobile-inicio', 'dark')
        pg.goto(f'{BASE}/mobile/tickets/2'); pg.wait_for_timeout(3500)
        shot(pg, 'V11-mobile-chamado', 'dark')
    except Exception as exc:
        note('V11', erro=f'{type(exc).__name__}: {exc}'[:300])
    c.close()

    note('meta', erros_console_e_rede=errors[:50], erros_total=len(errors))
    browser.close()

(OUT / 'relatorio.json').write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding='utf-8')
print(json.dumps({k: {kk: v for kk, v in d.items() if kk in ('blue_count', 'low_count', 'state_low_count', 'erro', 'titulo', 'chamados_visiveis', 'erros_total')} for k, d in report.items()}, ensure_ascii=False, indent=1))
