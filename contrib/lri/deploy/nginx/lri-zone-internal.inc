# Cabeçalhos da ZONA INTERNA (atendimento.*, atrás do Cloudflare Access). Incluído em CADA location.
proxy_http_version 1.1;
proxy_set_header Host $http_host;
proxy_set_header CLIENT_IP $remote_addr;
proxy_set_header X-Forwarded-For $remote_addr;
proxy_set_header X-Forwarded-Proto https;
proxy_set_header Forwarded "";
proxy_set_header X-Forwarded-Scheme "";
proxy_set_header X-Forwarded-Ssl "";
proxy_set_header X-Forwarded-Host "";
proxy_set_header X-Forwarded-User "";
proxy_set_header Remote-User "";
# Zona interna: valor fixo, segredo de zona (renderizado na partida a partir de LRI_ZONE_KEY) e o JWT do Access,
# repassado como veio do cloudflared para a guarda conferir de novo.
proxy_set_header X-LRI-Zone "internal";
proxy_set_header X-LRI-Zone-Key "@LRI_ZONE_KEY@";
proxy_set_header Cf-Access-Jwt-Assertion $http_cf_access_jwt_assertion;
