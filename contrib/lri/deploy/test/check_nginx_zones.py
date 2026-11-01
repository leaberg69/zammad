"""Confere o Nginx das zonas (contrib/lri/deploy/nginx) contra o upstream de eco. Roda no namespace de rede do Nginx.

Cada verificação imprime OK ou FALHA com o motivo; o código de saída é o número de falhas.
"""

import http.client
import json
import sys

KEY = sys.argv[1]
PUBLIC = 8081
INTERNAL = 8082
FQDN = 'suporte.lri.com.br'
MW = 'suporte.meanwellbrasil.com.br'
IRD = 'suporte.ird.net.br'
STAFF = 'atendimento.lri.com.br'

FORGED = {
    'X-LRI-Zone': 'internal',
    'X-LRI-Zone-Key': KEY,
    'Cf-Access-Jwt-Assertion': 'forjado',
    'Remote-User': 'admin@lri.com.br',
    'X-Forwarded-User': 'admin@lri.com.br',
    'X-Forwarded-Host': 'evil.example',
    'X-Forwarded-For': '6.6.6.6',
    'CF-Connecting-IP': '203.0.113.7',
}

failures = 0


def req(port, host, path, headers=None):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
    conn.request('GET', path, headers={'Host': host, **(headers or {})})
    resp = conn.getresponse()
    body = resp.read().decode('utf-8', 'replace')
    conn.close()
    return resp.status, dict(resp.getheaders()), body


def check(name, cond, detail=''):
    global failures
    if cond:
        print(f'OK     {name}')
    else:
        failures += 1
        print(f'FALHA  {name} {detail}')


def upstream(port, host, path, headers=None):
    status, _, body = req(port, host, path, headers)
    if status != 200:
        return status, {}
    return status, json.loads(body)


# Zona pública: cabeçalhos forjados nunca chegam ao Zammad, em todas as locations.
for host in (FQDN, MW, IRD):
    for path in ('/', '/api/v1/users/me', '/graphql', '/ws', '/cable'):
        status, data = upstream(PUBLIC, host, path, FORGED)
        h = data.get('headers', {})
        check(f'público {host}{path}: zona public', status == 200 and h.get('x-lri-zone') == 'public', f'status={status} {h.get("x-lri-zone")}')
        check(f'público {host}{path}: sem segredo, JWT, Remote-User, X-Forwarded-User, X-Forwarded-Host',
              not any(h.get(k) for k in ('x-lri-zone-key', 'cf-access-jwt-assertion', 'remote-user', 'x-forwarded-user', 'x-forwarded-host')),
              str({k: h.get(k) for k in ('x-lri-zone-key', 'cf-access-jwt-assertion', 'remote-user', 'x-forwarded-user', 'x-forwarded-host')}))
        check(f'público {host}{path}: IP real da Cloudflare, não o X-Forwarded-For do cliente',
              h.get('x-forwarded-for') == '203.0.113.7', f'xff={h.get("x-forwarded-for")}')

# Zona interna: valor fixo, segredo de zona e JWT repassado.
for path in ('/', '/api/v1/users/me', '/graphql', '/ws', '/cable'):
    status, data = upstream(INTERNAL, STAFF, path, {'X-LRI-Zone': 'public', 'X-LRI-Zone-Key': 'errado', 'Cf-Access-Jwt-Assertion': 'jwt-do-access', 'Remote-User': 'x'})
    h = data.get('headers', {})
    check(f'interno {path}: zona internal com o segredo', h.get('x-lri-zone') == 'internal' and h.get('x-lri-zone-key') == KEY, str(h.get('x-lri-zone')))
    check(f'interno {path}: JWT do Access repassado', h.get('cf-access-jwt-assertion') == 'jwt-do-access')
    check(f'interno {path}: sem Remote-User', not h.get('remote-user'))

# WebSocket e ActionCable vão para o upstream certo.
check('público /ws vai ao websocket (6042)', upstream(PUBLIC, FQDN, '/ws')[1].get('port') == 6042)
check('público /cable vai ao railsserver (3000)', upstream(PUBLIC, FQDN, '/cable')[1].get('port') == 3000)
check('interno /ws vai ao websocket (6042)', upstream(INTERNAL, STAFF, '/ws')[1].get('port') == 6042)

# Troca exata de Origin.
def origin_seen(port, host, path, origin):
    headers = {'Origin': origin} if origin is not None else {}
    return upstream(port, host, path, headers)[1].get('headers', {}).get('origin')


check('interno /ws: Origin do nome interno vira o fqdn', origin_seen(INTERNAL, STAFF, '/ws', f'https://{STAFF}') == f'https://{FQDN}')
for other in (f'https://{STAFF}.evil.com', 'https://intranet.lri.com.br', 'null', f'HTTPS://{STAFF.upper()}',
              'https://atendimentoXlri.com.br', f'http://{STAFF}'):
    check(f'interno /ws: Origin {other} passa inalterado', origin_seen(INTERNAL, STAFF, '/ws', other) == other)
check('interno /ws: Origin ausente continua ausente', origin_seen(INTERNAL, STAFF, '/ws', None) is None)
check('interno /cable: sem troca (ActionCable aceita Origin igual ao Host)', origin_seen(INTERNAL, STAFF, '/cable', f'https://{STAFF}') == f'https://{STAFF}')
check('público /ws: Origin da Mean Well vira o fqdn', origin_seen(PUBLIC, MW, '/ws', f'https://{MW}') == f'https://{FQDN}')
check('público /cable: Origin da Mean Well vira o fqdn', origin_seen(PUBLIC, MW, '/cable', f'https://{MW}') == f'https://{FQDN}')
check('público /ws: Origin de terceiro passa inalterado', origin_seen(PUBLIC, MW, '/ws', 'https://evil.example') == 'https://evil.example')
check('público /ws: Origin ausente continua ausente', origin_seen(PUBLIC, MW, '/ws', None) is None)
check('público /: sem troca fora de /ws e /cable', origin_seen(PUBLIC, MW, '/', f'https://{MW}') == f'https://{MW}')

# Retornos de OAuth: 302 exato para o nome interno, com a query, destino fixo.
for path in ('/auth/google_oauth2/callback', '/auth/microsoft_office365/callback',
             '/api/v1/external_credentials/google/callback', '/api/v1/external_credentials/microsoft_graph/callback'):
    status, headers, _ = req(PUBLIC, FQDN, f'{path}?code=abc&state=xyz', {'X-Forwarded-Host': 'evil.example'})
    location = headers.get('Location', '')
    check(f'público {path}: 302 para o nome interno com a query', status == 302 and location == f'https://{STAFF}{path}?code=abc&state=xyz', f'{status} {location}')
status, headers, _ = req(PUBLIC, 'evil.example', '/auth/google_oauth2/callback?code=abc')
check('Host desconhecido não redireciona (404)', status == 404, f'{status} {headers.get("Location")}')

# Rotas da equipe bloqueadas na zona pública, em qualquer caixa e com barra final.
for path in ('/auth/sso', '/auth/google_oauth2', '/AUTH/GOOGLE_OAUTH2/CALLBACK', '/auth/google_oauth2/callback/',
             '/oauth/token', '/api/v1/external_credentials/google/link_account', '/API/V1/Monitoring/health_check'):
    status, _, body = req(PUBLIC, FQDN, path)
    check(f'público {path}: 403 com a página de bloqueio', status == 403 and 'endereço interno' in body, f'status={status}')

# Nomes desconhecidos.
check('público: Host desconhecido dá 404', req(PUBLIC, 'evil.example', '/')[0] == 404)
check('interno: Host público no listener interno dá 404', req(INTERNAL, FQDN, '/')[0] == 404)

print(f'\n{failures} falha(s)')
sys.exit(failures)
