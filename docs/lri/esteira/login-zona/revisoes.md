# Revisões — login por zona

Fatia: a tela de login da zona pública não mostra os provedores de login de terceiros da equipe.

| Etapa | Quem | Resultado |
| ----- | ---- | --------- |
| UX-A | `ui-ux-engineer` | `ux-spec-v1.yaml`: nenhuma interface muda; sem link para a equipe; limitação do tempo real legado aceita |
| Revisão de código (camada 1) | `code-reviewer` | aprovado com ressalvas; corrigido: spec da assinatura, nome do describe, zona no contexto GraphQL em vez de `:controller`/`:channel`, teste contra drift da lista de provedores, zona da conexão ActionCable sem cookie, GraphQL com cliente logado |
| UX-B, rodada 1 | `ui-visual-reviewer` | não revisável: faltavam a régua de tela, 1024 px e V6; nenhum bloqueante nas imagens |
| UX-B, rodada 2 | `ui-visual-reviewer` | **aprovado**: zona pública igual ou menor que a interna em todos os critérios da régua, nas três interfaces, em 1440 e 1024 px (e 390 px no celular); V6 não se aplica (a interface desktop nova não abre para cliente nesta versão) |
| Revisão por outra família | Codex no PR | código sem achados (`84788df1`); segurança: 1 achado P3, risco aceito (abaixo) |

Risco aceito (P3 do Codex): o workflow de telas entrega o secret `LRI_MEDIR_TELA` ao código do branch do PR, então
quem tem escrita no repositório poderia publicar o script. O secret não é credencial, só o script da régua; PR de
fork não o recebe. Se passar a guardar algo sensível, o passo vai para um Environment com aprovação.

Evidência do UX-B: workflow `lri-telas.yaml` (app real compilado, Chromium do Playwright), artefato `telas-lri` com um
PNG e a medição da régua por tela. A régua chega ao CI por um secret do repositório e não fica no código.

Melhorias registradas para fatias futuras: contraste abaixo de 4,5:1 em textos do Zammad original (zona interna
também); "Log in to" do legado mostra o mesmo endereço para as três marcas; página de bloqueio sem caminho de volta
ao portal.

Fica registrado, fora do escopo: `auth_saml_display_name` e `auth_openid_connect_display_name` continuam indo para a
zona pública (sem botão, só o nome do provedor).
