"""Gera as variantes de logo da ux-spec de branding a partir das fontes em docs/lri/brand-assets/.

Uso (na raiz do repositório): python contrib/lri/branding/gerar_logos.py

Saída em public/assets/lri/. Regras da ux-spec (visual_tokens.logos): não redesenhar, só recorte de
viewBox, cor de preenchimento e composição; SVG sem script, sem href externo e sem foreignObject;
raster só embutido como data:image/png;base64. O script falha com mensagem se a fonte mudar de forma
que quebre essas premissas.
"""

import base64
import io
import re
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[3]
SRC = ROOT / 'docs/lri/brand-assets'
OUT = ROOT / 'public/assets/lri'

VERDE_CLARO = '#3d7a12'   # LRI sobre fundo claro (ux-spec: lri-logo-claro)
VERDE_ESCURO = '#74b527'  # LRI sobre fundo escuro (ux-spec: lri-logo-escuro)

# Área útil medida nos paths do original (ux-spec): x 233-767, y 251-524, com 4% de respiro.
LRI_X, LRI_Y, LRI_W, LRI_H = 233.0, 251.0, 534.0, 273.0
PAD = 0.04
LRI_VIEWBOX = (LRI_X - LRI_W * PAD, LRI_Y - LRI_H * PAD, LRI_W * (1 + 2 * PAD), LRI_H * (1 + 2 * PAD))


def fail(msg):
    sys.exit(f'gerar_logos: {msg}')


def lri_paths():
    svg = (SRC / 'lri-logo.svg').read_text(encoding='utf-8')
    if re.search(r'<script|foreignObject|href\s*=', svg, re.I):
        fail('lri-logo.svg contém script, foreignObject ou href; a premissa da ux-spec não vale mais')
    paths = re.findall(r'<path\b[^>]*/>', svg, re.S)
    if len(paths) != 7:
        fail(f'lri-logo.svg tinha 7 paths quando a ux-spec foi escrita; agora tem {len(paths)}')
    if any('fill' in p for p in paths):
        fail('lri-logo.svg passou a ter fill nos paths; revisar a geração')
    return '\n'.join(re.sub(r'\s+', ' ', p) for p in paths)


def ird_png(dark):
    im = Image.open(SRC / 'ird-logo.png').convert('RGBA')
    if im.size != (874, 246):
        fail(f'ird-logo.png mudou de tamanho: {im.size}')
    if dark:
        # Tons de cinza (o preto e o antisserrilhado dele) viram branco com o mesmo alfa; o laranja fica.
        flat = getattr(im, 'get_flattened_data', im.getdata)  # getdata sai no Pillow 14
        pixels: list[tuple[int, int, int, int]] = list(flat())  # type: ignore[arg-type]
        im.putdata([(255, 255, 255, a) if a and max(r, g, b) - min(r, g, b) < 40 else (r, g, b, a)
                    for r, g, b, a in pixels])
    buf = io.BytesIO()
    im.save(buf, 'PNG', optimize=True)
    return buf.getvalue()


def data_uri(png):
    return 'data:image/png;base64,' + base64.b64encode(png).decode('ascii')


def lri_svg_inner(fill, x, y, w, h):
    vb = ' '.join(f'{v:.1f}' for v in LRI_VIEWBOX)
    return (f'<svg x="{x}" y="{y}" width="{w}" height="{h}" viewBox="{vb}" '
            f'preserveAspectRatio="xMidYMid meet"><g fill="{fill}">{lri_paths()}</g></svg>')


def standalone_lri(fill):
    vb = ' '.join(f'{v:.1f}' for v in LRI_VIEWBOX)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" role="img" aria-label="LRI">'
            f'<g fill="{fill}">{lri_paths()}</g></svg>\n')


def stacked(dark):
    lri_fill = VERDE_ESCURO if dark else VERDE_CLARO
    png = data_uri(ird_png(dark))
    return ('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
            'viewBox="0 0 400 200" width="400" height="200" role="img" aria-label="Grupo LRI: LRI e IRD.Net">'
            + lri_svg_inner(lri_fill, 112, 0, 176, 90)
            + f'<image x="40" y="110" width="320" height="90" preserveAspectRatio="xMidYMid meet" href="{png}"/>'
            + '</svg>\n')


def horizontal():
    png = data_uri(ird_png(False))
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 401 64" width="401" height="64" '
            'role="img" aria-label="Grupo LRI: LRI e IRD.Net">'
            + lri_svg_inner(VERDE_CLARO, 0, 0, 125, 64)
            + '<rect x="149" y="4" width="1" height="56" fill="#b7b7b7"/>'
            + f'<image x="174" y="0" width="227" height="64" preserveAspectRatio="xMidYMid meet" href="{png}"/>'
            + '</svg>\n')


def check(name, text):
    if re.search(r'<script|foreignObject|on[a-z]+\s*=', text, re.I):
        fail(f'{name} gerado com conteúdo ativo')
    for href in re.findall(r'href="([^"]+)"', text):
        if not href.startswith('data:image/png;base64,'):
            fail(f'{name} referencia recurso externo: {href[:40]}')


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    files = {
        'lri-logo-claro.svg': standalone_lri(VERDE_CLARO),
        'lri-logo-escuro.svg': standalone_lri(VERDE_ESCURO),
        'grupo-lri-logo.svg': stacked(False),
        'grupo-lri-logo-escuro.svg': stacked(True),
        'grupo-lri-logo-horizontal.svg': horizontal(),
    }
    for name, text in files.items():
        check(name, text)
        (OUT / name).write_text(text, encoding='utf-8', newline='\n')
    (OUT / 'ird-logo-escuro.png').write_bytes(ird_png(True))
    for f in sorted(OUT.iterdir()):
        print(f'{f.name}: {f.stat().st_size} bytes')


if __name__ == '__main__':
    main()
