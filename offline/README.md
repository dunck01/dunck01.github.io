# Instalacao offline DunckOps

## Antes de comecar

- Use uma VPS Linux `amd64` com Docker Engine e Docker Compose v2 ja instalados.
- Reserve espaco em disco para o bundle, imagens Docker e dados da plataforma.
- Use um pendrive ou midia removivel confiavel.

## Em uma maquina com internet

1. Acesse `https://get.dunckops.com/offline/`.
2. Baixe `dunckops-offline-vX.Y.Z.tar.gz` e confira o SHA-256 indicado em `latest.json`.
3. Copie o arquivo para o pendrive.

## Na VPS isolada

1. Copie o bundle para um diretorio local.
2. Extraia o arquivo: `tar -xzf dunckops-offline-vX.Y.Z.tar.gz`.
3. Entre no diretorio extraido.
4. Execute `sudo bash install-offline.sh`.
5. Acesse a interface em `http://IP_DA_VPS:9000`.

O instalador tambem prepara os runtimes PostgreSQL usados por backup e clone. Essa etapa pode levar alguns minutos.

## Licenca offline

1. Na VPS, abra Configuracoes e gere a solicitacao de licenca offline.
2. Baixe o arquivo e leve-o para uma maquina conectada.
3. Emita a licenca no portal Comercial e salve o arquivo assinado no pendrive.
4. Volte a VPS e importe o arquivo em Configuracoes.

## Atualizacoes

Baixe um bundle de versao mais nova, transfira-o pela midia removivel e execute o instalador novamente.
