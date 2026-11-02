# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

"""Renderiza a stack oficial com contrib/lri/deploy/docker-compose.lri.yml e confere as regras do go-live.

Uso: python3 check_compose_overlay.py <docker-compose.yml oficial> <overlay>
Cada regra violada é listada com o serviço e o motivo; o código de saída é o número de violações.
"""

import json
import os
import re
import subprocess
import sys

IMAGE_PREFIX = "ghcr.io/leaberg69/zammad-lri:"
ZAMMAD_SERVICES = {
    "zammad-backup", "zammad-init", "zammad-railsserver", "zammad-websocket", "zammad-scheduler", "zammad-nginx",
}
MAX_HEAP_BYTES = 1024 ** 3

DUMMY_ENV = {
    "LRI_IMAGE_TAG": "develop-" + "0" * 40,
    "LRI_ZONE_KEY": "k" * 40,
    "LRI_ACCESS_AUD": "aud-teste",
    "CLOUDFLARED_VERSION": "2025.1.0",
    "CLOUDFLARED_TUNNEL_TOKEN": "token-de-teste",
}


def render(official, overlay, env):
    return subprocess.run(
        ["docker", "compose", "-f", official, "-f", overlay, "config", "--format", "json"],
        capture_output=True, text=True, env={**os.environ, **env}, check=False,
    )


def heap_bytes(value):
    match = re.fullmatch(r"(\d+)([kKmMgG]?)", value)
    if not match:
        return None
    number, unit = int(match.group(1)), match.group(2).lower()
    return number * {"": 1, "k": 1024, "m": 1024 ** 2, "g": 1024 ** 3}[unit]


def check(config):
    problems = []
    services = config["services"]

    for name, service in sorted(services.items()):
        if service.get("ports"):
            problems.append(f"{name}: publica porta no host {service['ports']}")
        if not service.get("mem_limit"):
            problems.append(f"{name}: sem mem_limit")

    for name in sorted(ZAMMAD_SERVICES):
        image = services.get(name, {}).get("image", "")
        if not image.startswith(IMAGE_PREFIX) or image.endswith(":latest"):
            problems.append(f"{name}: imagem {image!r} não é uma tag fixa de {IMAGE_PREFIX}")

    opts = services.get("zammad-elasticsearch", {}).get("environment", {}).get("ES_JAVA_OPTS", "")
    heaps = [heap_bytes(h) for h in re.findall(r"-Xm[sx](\S+)", opts)]
    if len(heaps) != 2 or any(h is None or h > MAX_HEAP_BYTES for h in heaps):
        problems.append(f"zammad-elasticsearch: heap {opts!r} ausente ou acima de 1g")

    cloudflared = services.get("cloudflared", {})
    if cloudflared.get("network_mode") != "service:zammad-nginx":
        problems.append("cloudflared: fora do namespace de rede do zammad-nginx")
    if cloudflared.get("environment", {}).get("TUNNEL_TOKEN") != DUMMY_ENV["CLOUDFLARED_TUNNEL_TOKEN"]:
        problems.append("cloudflared: TUNNEL_TOKEN não vem de CLOUDFLARED_TUNNEL_TOKEN")

    return problems


def main(official, overlay):
    result = render(official, overlay, DUMMY_ENV)
    if result.returncode != 0:
        print(f"docker compose config falhou:\n{result.stderr}")
        return 1
    problems = check(json.loads(result.stdout))

    # Sem token, a stack não pode subir: o compose tem de recusar com a mensagem do overlay.
    without_token = {**DUMMY_ENV, "CLOUDFLARED_TUNNEL_TOKEN": ""}
    result = render(official, overlay, without_token)
    if result.returncode == 0 or "CLOUDFLARED_TUNNEL_TOKEN" not in result.stderr:
        problems.append("sem CLOUDFLARED_TUNNEL_TOKEN o compose deveria recusar e citar a variável")

    for problem in problems:
        print(f"ERRO  {problem}")
    if not problems:
        print("ok    overlay: sem portas no host, imagem do fork, heap do ES <= 1g, mem_limit em todos, token por env")
    return len(problems)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
