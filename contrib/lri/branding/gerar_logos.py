"""Gera as variantes de logo da ux-spec de branding (v2) a partir das fontes em docs/lri/brand-assets/.

Uso (na raiz do repositório): python contrib/lri/branding/gerar_logos.py

Saída em public/assets/lri/. Regras (docs/lri/esteira/branding/ux-spec-v2.yaml, visual_tokens.logos): não redesenhar,
só recorte de viewBox, cor de preenchimento, retângulo branco sob o bloco da Mean Well e composição; tudo vetorial,
sem raster embutido, sem script, href, foreignObject ou <style>. O script falha com mensagem se uma fonte mudar de
forma que quebre essas premissas.
"""

import re
import sys
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parents[3]
SRC = ROOT / 'docs/lri/brand-assets'
OUT = ROOT / 'public/assets/lri'

VERDE_CLARO = '#3d7a12'   # LRI sobre fundo claro
VERDE_ESCURO = '#74b527'  # LRI sobre fundo escuro

# LRI: área útil medida nos paths do original (x 233-767, y 251-524), com 4% de respiro.
_LX, _LY, _LW, _LH, _PAD = 233.0, 251.0, 534.0, 273.0, 0.04
LRI_VIEWBOX = f'{_LX - _LW * _PAD:.1f} {_LY - _LH * _PAD:.1f} {_LW * (1 + 2 * _PAD):.1f} {_LH * (1 + 2 * _PAD):.1f}'
MW_VIEWBOX = '0 132 1000 743'  # recorte do bloco no viewBox 1000 x 1000 da fonte

FORBIDDEN = re.compile(r'<script|<image|foreignObject|href\s*=|\son[a-z]+\s*=', re.I)


def fail(msg) -> NoReturn:
    sys.exit(f'gerar_logos: {msg}')


def read_source(name):
    text = (SRC / name).read_text(encoding='utf-8')
    if FORBIDDEN.search(text):
        fail(f'{name} contém image, script, foreignObject, href ou handler; a premissa da ux-spec não vale mais')
    return text


def inner(svg_text):
    """Conteúdo entre <svg ...> e </svg>, sem declaração XML nem comentários."""
    m = re.search(r'<svg\b[^>]*>(.*)</svg>', svg_text, re.S)
    if not m:
        fail('fonte SVG sem elemento <svg>')
    return re.sub(r'<!--.*?-->', '', m.group(1), flags=re.S).strip()


def lri_body():
    paths = re.findall(r'<path\b[^>]*/>', read_source('lri-logo.svg'), re.S)
    if len(paths) != 7 or any('fill' in p for p in paths):
        fail('lri-logo.svg mudou (eram 7 paths sem fill); revisar a geração')
    return '\n'.join(re.sub(r'\s+', ' ', p) for p in paths)


def ird_body(dark):
    body = inner(read_source('ird-logo.svg'))
    fills = set(re.findall(r'fill="(#[0-9a-fA-F]{6})"', body))
    if fills != {'#000000', '#e76e33'}:
        fail(f'ird-logo.svg com cores inesperadas: {sorted(fills)}')
    return body.replace('fill="#000000"', 'fill="#ffffff"') if dark else body


def mw_body():
    src = read_source('mw-brasil-logo.svg')
    styles = dict(re.findall(r'\.(st\d+)\{fill:([^;]+);\}', src))
    if not styles:
        fail('mw-brasil-logo.svg sem as classes .stN esperadas')
    body = re.sub(r'<style\b.*?</style>', '', inner(src), flags=re.S)

    def to_fill(m):
        cls = m.group(1)
        if cls not in styles:
            fail(f'mw-brasil-logo.svg usa a classe {cls} sem regra de fill')
        return f'fill="{styles[cls]}"'

    body = re.sub(r'class="(st\d+)"', to_fill, body)
    body = body.replace('SVGID_', 'mw-SVGID_')
    if 'class=' in body or '<style' in body:
        fail('mw-brasil-logo.svg ainda tem class ou style depois da conversão')
    # Letras e faixas do vetor são vazadas; o retângulo branco reproduz o visual dos PNG oficiais.
    return '<rect x="0" y="132" width="1000" height="743" fill="#ffffff"/>' + re.sub(r'\s+', ' ', body)


def place(body, viewbox, x, y, w, h):
    return (f'<svg x="{x}" y="{y}" width="{w}" height="{h}" viewBox="{viewbox}" '
            f'preserveAspectRatio="xMidYMid meet">{body}</svg>')


def lri(fill, x, y, w, h):
    return place(f'<g fill="{fill}">{lri_body()}</g>', LRI_VIEWBOX, x, y, w, h)


def ird(dark, x, y, w, h):
    return place(ird_body(dark), '0 0 606.9 116.5', x, y, w, h)


def mw(x, y, w, h):
    return place(mw_body(), MW_VIEWBOX, x, y, w, h)


def root(vw, vh, content, label='Grupo LRI: LRI, IRD.Net e Mean Well Brasil'):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {vw} {vh}" width="{vw}" height="{vh}" '
            f'role="img" aria-label="{label}">{content}</svg>\n')


def stacked(dark):
    """400 x 200: LRI em cima (188 x 96); embaixo IRD.Net (250 x 48) à esquerda e Mean Well (118 x 88) à direita."""
    return root(400, 200,
                lri(VERDE_ESCURO if dark else VERDE_CLARO, 106, 0, 188, 96)
                + ird(dark, 2, 132, 250, 48)
                + mw(280, 112, 118, 88))


def horizontal():
    """470 x 64 para o cabeçalho da KB: LRI | IRD.Net | Mean Well, com fios #b7b7b7."""
    return root(470, 64,
                lri(VERDE_CLARO, 0, 0, 125, 64)
                + '<rect x="145" y="4" width="1" height="56" fill="#b7b7b7"/>'
                + ird(False, 166, 15, 177, 34)
                + '<rect x="363" y="4" width="1" height="56" fill="#b7b7b7"/>'
                + mw(384, 0, 86, 64))


def standalone_lri(fill):
    return root(_LW * (1 + 2 * _PAD), _LH * (1 + 2 * _PAD), '', 'LRI').replace(
        f'viewBox="0 0 {_LW * (1 + 2 * _PAD)} {_LH * (1 + 2 * _PAD)}"', f'viewBox="{LRI_VIEWBOX}"').replace(
        '></svg>', f'><g fill="{fill}">{lri_body()}</g></svg>')


def check(name, text):
    if FORBIDDEN.search(text) or '<style' in text:
        fail(f'{name} gerado com conteúdo proibido')


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    files = {
        'lri-logo-claro.svg': standalone_lri(VERDE_CLARO),
        'lri-logo-escuro.svg': standalone_lri(VERDE_ESCURO),
        'ird-logo-claro.svg': root(606.9, 116.5, ird_body(False), 'IRD.Net'),
        'ird-logo-escuro.svg': root(606.9, 116.5, ird_body(True), 'IRD.Net'),
        'mw-brasil-logo.svg': root(1000, 743, place(mw_body(), MW_VIEWBOX, 0, 0, 1000, 743), 'Mean Well Brasil'),
        'grupo-lri-logo.svg': stacked(False),
        'grupo-lri-logo-escuro.svg': stacked(True),
        'grupo-lri-logo-horizontal.svg': horizontal(),
    }
    expected = set(files)
    for stale in OUT.iterdir():
        if stale.name not in expected:
            print(f'atenção: {stale.name} em {OUT} não é gerado por este script (v1?); remova-o se não for mais usado')
    for name, text in files.items():
        check(name, text)
        (OUT / name).write_text(text, encoding='utf-8', newline='\n')
        print(f'{name}: {len(text.encode())} bytes')


if __name__ == '__main__':
    main()
