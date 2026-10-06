# Operacoes Manuais Por Engine

A UI `/engine-operations` envia operacoes manuais ao agent Docker local, no
contexto da empresa autenticada. Nao e scheduler, backup S3/MinIO, failover
automatico ou garantia geral de recuperacao. PostgreSQL segue seu fluxo existente.

- [MySQL/MariaDB](mysql-operations.md): perfis MySQL 8.4.11 e MariaDB 11.4.13
  ensaiados com restore, binlogs/PITR e standby; somente dentro dos limites descritos.
- [MongoDB](mongo-operations.md): perfil 8.0.12 com replica set autenticado,
  restore/PITR de corte exclusivo ensaiado; transacoes/retryable writes nao suportados.
- [SQL Server](sqlserver-operations.md): implementado, sem homologacao SQL real;
  lab explicitamente autorizado apenas, `productionReady=false`.
- [Snapshots fisicos](physical-snapshots.md): base MySQL/MariaDB de instancia
  inteira; `prepared` nao significa restore validado.

## Preparacao Manual

Usuario admin, empresa e vinculo ativos; licenca deve autorizar novas operacoes
da engine. Origem previamente provisionada pelo operador, com labels exatas
`pitr.managed=true` e `pitr.company-id=<UUID-canonico-minusculo-da-empresa>`.
`DOCKER_ALLOW_ANY_CONTAINER` nao dispensa ownership. Confira versao, topologia,
TLS, privilegios e mounts no guia da engine antes de conceder labels.

Mesmas engines em todos os planos nao libera os mesmos recursos. PITR exige
`pitr_enabled` e `pitr_recovery_window_hours` validos no entitlement assinado;
janela positiva limita idade do corte, e zero significa ilimitado explicitamente.
Iniciar/configurar standby exige `delayed_standby_enabled`. Claims ausentes,
duplicados ou malformados negam esses recursos. Nenhum campo local editavel libera
PITR/standby. Consulta/parada de ator proprio permanece fora desses gates.

API e agent devem receber `MULTI_ENGINE_OPERATIONS_ENABLED=true`; padrao `false`.
Snapshots fisicos exigem tambem `PHYSICAL_SNAPSHOTS_ENABLED=true`. Runtimes devem
estar instalados localmente e volume `DUNCKOPS_LOCAL_BACKUP_VOLUME` provisionado
conforme guia. Ferramentas Compose ficam no profile `tools`, excluido do start
padrao; use-o para build/pull, nao para iniciar servidores. Overrides de ferramentas
exigem imagem local existente. MySQL/MariaDB usam `MYSQL_RESTORE_SERVER_IMAGE=mysql:8.4.11`
e `MARIADB_RESTORE_SERVER_IMAGE=mariadb:11.4.13`. Install/update so baixam esses
servidores com multi-engine habilitado e `MULTI_ENGINE_RESTORE_SERVER_IMAGES_PULL=true`;
bundle offline de release os inclui sempre, sem habilitar operacoes.

SQL exige ainda `SQLSERVER_OPERATIONS_UNVERIFIED_OPT_IN=true` na API/agent.
`SQLSERVER_OPERATIONS_CLIENT_TOOLS_IMAGE` referencia somente cliente publicado ou
derivado aprovado; nao e servidor SQL. Apos instalar/verificar cliente e CA TLS,
configure manualmente `SQLSERVER_OPERATIONS_RUNTIME_IMAGE=sha256:<64-hex-minusculos>`.
Tag/registry digest nao substitui esse ID. Permanecem vazios nos exemplos:
`SQLSERVER_OPERATIONS_BACKUP_VOLUME`, `SQLSERVER_OPERATIONS_SIGNING_VOLUME` e
`SQLSERVER_OPERATIONS_SIGNING_PUBLIC_KEY_SHA256`. Provisione volumes distintos,
chave RSA privada externa e fingerprint publico conforme guia; timeout `1800`
segundos, inteiro `60..7200`, igual na API/agent. Origem/alvo SQL licenciados e TLS
confiavel sao responsabilidade do operador. Nenhuma EULA e aceita automaticamente,
nenhum servidor SQL ou material de assinatura e provisionado pelo deployment.

Stop de collector/actor proprio continua permitido com flag desativada ou licenca
expirada, mantendo autenticacao admin, empresa/vinculo ativos e ownership. Isso
nao libera novas operacoes, resume ou promocao. Stop nao remove origem nem arquivos
selados; timeout/cleanup desconhecido exige inspecao manual, nunca falso sucesso.
