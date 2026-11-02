# Revisões — login por zona

Fatia: a tela de login da zona pública não mostra os provedores de login de terceiros da equipe.

| Etapa | Quem | Resultado |
| ----- | ---- | --------- |
| UX-A | `ui-ux-engineer` | `ux-spec-v1.yaml`: nenhuma interface muda; sem link para a equipe; limitação do tempo real legado aceita |
| Revisão de código (camada 1) | `code-reviewer` | aprovado com ressalvas; corrigido: spec da assinatura, nome do describe, zona no contexto GraphQL em vez de `:controller`/`:channel`, teste contra drift da lista de provedores, zona da conexão ActionCable sem cookie, GraphQL com cliente logado |
| UX-B | `ui-visual-reviewer` | screenshots do app real gerados pelo workflow `lri-telas.yaml` (artefato `telas-lri`) |
| Revisão por outra família | Codex no PR | pedido no PR |

Fica registrado, fora do escopo: `auth_saml_display_name` e `auth_openid_connect_display_name` continuam indo para a
zona pública (sem botão, só o nome do provedor).
