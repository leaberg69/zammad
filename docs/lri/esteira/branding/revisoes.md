# Revisões do slice "Branding Grupo LRI"

Esteira no Nível 1: os papéis seguem `leaberg69/esteira-softwarehouse-LR` sem registrar o ciclo no CLI. Revisor ≠
autor em todas as rodadas; cada revisor trabalhou em contexto novo, sobre a tela real (imagem Docker construída a
partir do commit revisado, rodando localmente com os dados de `contrib/lri/qa/`).

## Contrato

| Artefato | Autor | Conteúdo |
| -------- | ----- | -------- |
| [`ux-spec-v1.yaml`](ux-spec-v1.yaml) | UX-A | cores, tokens por interface, contraste WCAG AA, logos, pt-BR, telas de aceite |
| [`ux-spec-v2.yaml`](ux-spec-v2.yaml) | UX-A | Mean Well Brasil como terceira marca; logos 100% vetoriais da pasta oficial |
| [`ux-spec-v3.yaml`](ux-spec-v3.yaml) | UX-A | estado em verde sobre superfície escura (barra e peças pretas sobre verde), botões de envio, mobile |

## Rodadas

| Commit | Revisão | Veredito | Principais achados e destino |
| ------ | ------- | -------- | ---------------------------- |
| `23952e79` | UX-B 1 | reprovado | estado verde < 3:1 em dropdown e visões (→ ux-spec v3); ordem da KB |
| `23952e79` | code-reviewer | aprovado com ressalvas | `--text-nav` escuro, mobile branco sobre verde, WebAuthn, premissa de rede do plano, vazamento operacional (corrigidos em `47b90687`) |
| `23952e79` | security-B | aprovado (branding); zonas com condições | segredo de zona + JWT do Access, cabeçalhos por `location`, `Remote-User`, sessão com zona (no plano, §2.9) |
| `3c2a174b` | UX-B 2 | reprovado | ordem da KB sem efeito (modo alfabético; o script dava falso sucesso) |
| `3c2a174b` | Codex (cross-model) | 2 × P2 | texto preto em botão mobile não verde; hover escuro no desktop (corrigidos em `ec4f8607`) |
| `ec4f8607` | Codex (cross-model) | sem achados | — |
| `ec4f8607` | UX-B 3 | reprovado | seletor do grupo mirava `.searchableSelect .dropdown` (o elemento é a própria `.dropdown`) |
| `3aa04c03` | UX-B 4 | **aprovado** | — |

## Medição final (`3aa04c03`)

`contrib/lri/qa/capture.py`, 24 telas (claro e escuro, mobile 390 px): 0 azul de destaque residual (exceto a
superfície neutra `.textBubble`, exceção da v3), 0 texto em cor de marca abaixo de 4,5:1 com opacidade efetiva, 0
indicador de estado abaixo de 3:1 (inclusive pseudo-elementos), 0 erro de console ou de rede. A miniatura de prévia do
login em Admin > Marca é isenta (maquete inativa).

## Fora do que foi verificado

App desktop Vue (interface beta, desligada por padrão), RTL com idioma real, `content: url()` em Firefox e Safari,
telas em 1024 px. Perguntas de produto abertas na [issue #3](https://github.com/leaberg69/zammad/issues/3).
