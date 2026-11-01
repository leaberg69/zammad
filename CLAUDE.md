# CLAUDE.md — fork Grupo LRI do Zammad

As instruções do upstream continuam valendo: `.claude/CLAUDE.md` e `AGENTS.md` apontam para
`.dev/ai-agent-instructions.md`, que não é editado aqui (é do upstream). Este arquivo só acrescenta as regras do
Grupo LRI. Plano e decisões: `docs/lri/PLANO.md`; checklist da VPS: `docs/lri/VPS-CHECKLIST.md`.

## Regra OEM: produtos de marca LRI nunca citam o fornecedor

Produtos vendidos sob a marca LRI **nunca** citam o fornecedor ou fabricante em nenhum material público. Isso inclui:

- o nome do fornecedor ou fabricante;
- o site dele;
- os códigos de modelo dele;
- a palavra "fabricante".

Vale para tudo o que o cliente vê: portal, base de conhecimento, e-mails e respostas automáticas, assinaturas,
modelos de texto (macros e módulos de texto), anexos e documentos publicados pela central. O produto aparece com o nome
e o código LRI.

Ao escrever conteúdo ou dados de exemplo para a central, conferir isso antes do commit. Na dúvida se um produto é de
marca LRI, perguntar antes de publicar.

## Outras regras do fork

- Repositório público: nada de segredo, endereço de servidor, usuário ou detalhe operacional sensível.
- Textos em pt-BR; notação elétrica `Vcc`/`Vca`.
- Nada vai para produção sem OK do Leandro. Dúvidas técnicas: issue com o rótulo `pergunta`.
