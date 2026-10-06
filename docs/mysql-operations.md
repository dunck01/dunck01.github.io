# Operacoes MySQL/MariaDB isoladas

## Blocked: recovery after source deletion

Agent restore/PITR still requires the original managed source container and its
tenant labels. Snapshot validation verifies company/snapshot/engine fields, native
metadata and artifact hashes, but these unsigned local fields/hashes are not an
independent ownership anchor. Do not remove this guard or fabricate/relabel a
replacement source. Recovery after source deletion remains blocked until a trusted
signed ownership record or independently pinned authorized manifest is available
to the Agent. Promotion also currently contacts the source; offline promotion is
not implemented. Builds and installer configuration do not prove recovery.

Manual, experimental, instancia inteira (`scope=instance`). Nao e backup de banco
selecionado, backup agendado, garantia de integridade dos dados ou recurso publicado
de PITR. Sem integracao PostgreSQL, entidades de backup ou migrations.

## Implementado

- `verify-restore`: valida snapshot completo, restaura em volume exclusivo novo,
  inicia servidor isolado, autentica sessao SQL TLS e remove servidor/volume.
- `restore`: mesmo fluxo; `keepTarget=true` permite reter exclusivamente alvo novo,
  ainda read-only, sem rede externa ou portas publicadas. `false` descarta alvo.
- `start-log-collection`/`stop-log-collection`: collector persistente nativo,
  checksum CRC32, arquivos fechados, indice append-only encadeado por SHA-256.
- `restore-pitr`: plano previamente verificado, restore fisico novo e replay nativo
  ate limite completo de transacao anterior ao corte UTC exclusivo.
- `configure-standby`: restore novo read-only, rede interna exclusiva com origem
  autorizada e replicacao TLS com delay nativo confirmado.
- `promote-standby`: somente standby proprio, catch-up opcional e consentimento
  obrigatorio quando ainda atrasado; detach e writable apenas no alvo solicitado.
- Artefatos SHA-256, conjunto exato de arquivos, ausencia de symlinks, checkpoint
  preparado, coordenadas binlog, evidencias antes/depois e proveniencia conferidos.
- MySQL Community **8.4.11**, XtraBackup **8.4.0-7**; MariaDB **11.4.13**,
  mariadb-backup **11.4.13**. Outras versoes rejeitadas. Sufixo MariaDB `-log`
  nao muda versao; binlog e deliberadamente desativado no alvo.
- Restore usa `--copy-back` nativo, nunca uma copia editada da origem em execucao.
  Origem nao e montada por nenhum runtime de operacoes. Snapshot e montado
  somente leitura em inspect/copy; validacao monta backup volume gravavel
  exclusivamente para publicar relatorio separado, sem alterar snapshot.
  Novos runtimes de logs/replay/replicacao leem snapshots em `/backups` readonly e
  publicam via view `/archive` gravavel do mesmo volume. Isso nao e isolamento
  contra escritor/root malicioso; storage exige escritores confiaveis.
- Servidor executa `--no-defaults`, network `none`, sem portas, sem auto-start
  de replica, eventos desativados, rootfs somente leitura e dados apenas no volume
  novo. MySQL tambem ignora persisted globals e aplica super-read-only.
- Nenhuma imagem/path/comando/query Docker ou SQL pode vir da requisicao.
- Credenciais chegam via stdin; arquivo de cliente fica em tmpfs, nunca em env,
  argv, labels ou logs. Docker logging desativado. TLS local continua obrigatorio.

## Contrato Do Agent

Classe `MySqlOperations(IDockerClient docker, IConfiguration config)`, metodo
`Task<IResult> ExecuteAsync(string engine, string operation, HttpRequest http, CancellationToken ct)`.
`engine` aceita somente `mysql|mariadb`. Integrador deve registrar classe como
singleton e registrar rotas/autorizacao na API; este recorte nao altera `Program.cs`.
Agent nao substitui autenticacao da API: API deve derivar `companyId` do contexto
autorizado, gerar `operationId` e nunca aceitar empresa fornecida pelo cliente final.

Envelope exato, UUIDs canonicos minusculos nao vazios, sem campos extras/duplicados:

```json
{
  "companyId": "<UUID-DA-EMPRESA>",
  "operationId": "<UUID-UNICO-DA-OPERACAO>",
  "parameters": {
    "snapshotId": "<UUID-DO-SNAPSHOT>",
    "username": "<USUARIO-DO-SERVIDOR-RESTAURADO>",
    "password": "<SENHA-DO-SERVIDOR-RESTAURADO>"
  }
}
```

Schemas exatos, todos os campos obrigatorios:

| Operacao | `parameters` |
| --- | --- |
| `verify-restore` | `snapshotId:UUID, username:string, password:string` |
| `restore` | `snapshotId:UUID, username:string, password:string, keepTarget:boolean` |
| `start-log-collection` | `snapshotId:UUID, sourceContainer:string, username:string, password:string` |
| `stop-log-collection` | `collectionId:UUID` |
| `restore-pitr` | `snapshotId:UUID, collectionId:UUID, targetTimeUtc:string, username:string, password:string, keepTarget:boolean` |
| `configure-standby` | `snapshotId:UUID, sourceContainer:string, username:string, password:string, replicationUser:string, replicationPassword:string, delaySeconds:integer, allowSourceNetworkAttachment:true` |
| `promote-standby` | `targetContainer:string, username:string, password:string, catchUp:boolean, allowDataLoss:boolean` |

Usuario/admin 1..256 caracteres; senha/admin 1..4096; controles rejeitados.
Senha de replicacao: MySQL ate **32 bytes UTF-8** (limite nativo), MariaDB ate 96;
usuario de replicacao 1..256. Container e referencia Docker simples ate 128
caracteres, nao hostname/IP/path. `delaySeconds` 1..86400. `targetTimeUtc` ISO UTC
terminado em `Z`; MariaDB exige segundos inteiros, MySQL admite microssegundos.
`collectionId` de start e o `operationId`; nao existe resume/reuso implicito.
Corpo maximo 32 KiB, leitura 30 segundos. Restore/PITR/standby: 60 minutos;
start/stop/promote: 15 minutos; cleanup independente: 90 segundos. Collector
continua apos resposta ate stop/falha, sem restart automatico e sem prometer HA.

Resposta raiz sempre exatamente:

```json
{
  "operationId": "<UUID>",
  "engine": "mysql",
  "operation": "verify-restore",
  "state": "validated",
  "details": {}
}
```

Sucesso HTTP 200: `details` inclui `snapshotId`, `scope`, `manifestSha256`,
`validationReport`, `targetRetained`, `targetContainerId`, `targetVolume`,
`networkMode`, `readOnly`, `validation`, `pitr` e `standby`.
IDs/volume retornam null quando descartados; provas nao pertinentes retornam null.
`validation` inclui checkpoint/binlog, versao, hashes de identidade das imagens,
conectividade autenticada, TLS, read-only e contagem de tabelas de aplicacao.
`dataIntegrityCertified=false`: conexao e inventario nao certificam integridade
semantica, todas as linhas ou recuperabilidade de qualquer workload.

Falhas retornam apenas codigos fixos sanitizados. Estados: `rejected`, `failed`,
`disabled`, `cleanup-required`. Sucessos adicionais: `collecting`, `stopped`,
`standby`, `promoted`. HTTP 400 input invalido; 403 origem/alvo
nao autorizada/indisponivel; 409 operacao concorrente; 422 snapshot/restore rejeitado;
503 flag/imagem ausente; 504 timeout; 502 falha Docker/cleanup. Falha de cleanup
mantem gate bloqueado e retorna IDs proprios para inspecao manual.

## Autorizacao E Persistencia

`sourceContainerId` vem exclusivamente do manifesto verificado. Container original
deve ainda existir com `pitr.managed=true` e `pitr.company-id` exatamente igual ao
UUID da empresa. Nao precisa estar executando para restore. Nenhum bypass via
`DOCKER_ALLOW_ANY_CONTAINER`. Snapshot sem origem autorizada e rejeitado, mesmo
quando preparado. Nunca rotular automaticamente containers de terceiros.

Local calculado: `/backups/physical-snapshots/<companyId:N>/<snapshotId:N>/`.
Sem path do usuario. Volume de backups exige driver local sem opcoes. Escritores
do volume/root devem ser confiaveis; hashes nao protegem contra operador root
malicioso alterando dados durante copia. Limites herdados: 10.000 artefatos,
manifesto/metadata ate 8 MiB. Arquivos e metadados sao reconferidos antes do
copy-back e depois do boot. Volume alvo aleatorio novo precisa estar vazio.

Manifesto original permanece `restoreValidated=false`. Relatorio independente,
publicado atomicamente sem sobrescrita, em
`/backups/mysql-operations/<companyId:N>/<operationId:N>/validation.json`, vincula
snapshotId/manifestSha256, checkpoint/binlog, empresa, operacao e alvo exclusivo.
ManifestSha256 vincula todos os hashes de artefatos; nao e assinatura autenticada.
Relatorio nao contem credenciais. Nao reutilize operationId.

Containers/volumes proprios levam `pitr.mysql-operations=runtime|target`,
`pitr.company-id`, `pitr.operation-id`, `pitr.snapshot-id`, `pitr.engine`.
Cleanup confere empresa/operacao/engine; nao remove volumes/origens de terceiros.
Alvo restore/PITR retido continua com network none e read-only. Standby fica em
bridge interno proprio, sem portas publicadas, somente com origem autorizada.
Promocao nao conecta aplicacao nem promove/fenceia origem.
Queda de host/SIGKILL pode deixar recursos ou relatorio staging; sem exclusao
automatica de residuos. Proteja volume local: dados nao sao criptografados.

## Configuracao E Build

| Configuracao | Padrao |
| --- | --- |
| `MULTI_ENGINE_OPERATIONS_ENABLED` | `false` |
| `DUNCKOPS_LOCAL_BACKUP_VOLUME` | `dunckops-local-backups` |
| `MYSQL_OPERATIONS_RUNTIME_IMAGE` | `dunckops-mysql-operations-runtime:development` |
| `MARIADB_OPERATIONS_RUNTIME_IMAGE` | `dunckops-mariadb-operations-runtime:development` |
| `MYSQL_RESTORE_SERVER_IMAGE` | `mysql:8.4.11` |
| `MARIADB_RESTORE_SERVER_IMAGE` | `mariadb:11.4.13` |

### Deployment Opt-In

Compose local usa build com contexto raiz; producao usa imagens
`ghcr.io/${REGISTRY_OWNER:-dunck01}/dunckops-<engine>-operations-runtime:${DUNCKOPS_VERSION}`.
Servicos `mysql-operations-runtime`, `mariadb-operations-runtime` e
`mongo-operations-runtime` pertencem ao profile `tools`. Install/update baixam
essas tres ferramentas somente com `MULTI_ENGINE_OPERATIONS_ENABLED=true`,
igual na API e agent. Padrao `false`: nenhum download novo de operacoes.
Overrides explicitos de ferramentas devem existir localmente; install/update
fazem inspect antes de qualquer pull e falham sem tentar registry para override
ausente. Deixe override vazio para usar download da imagem publicada.

`MULTI_ENGINE_RESTORE_SERVER_IMAGES_PULL=false` por padrao. Com ambos os flags
de multi-engine/pull habilitados, install/update tambem baixam os servicos
`mysql-restore-server` (`mysql:8.4.11`) e `mariadb-restore-server`
(`mariadb:11.4.13`), sem inicia-los. Execucao operacional pertence ao agent,
nao a `compose up --profile tools`. Bundle offline inclui ferramentas e imagens
de restore, mas nao habilita flags. Packaging/build nao certifica readiness.

Imagens devem existir localmente. Sem pull automatico. Operador configura imagens;
cada execucao resolve ID imutavel. Servidor de patch diferente falha na verificacao
isolada. Runtimes baseiam imagens oficiais/toolchain com digest fixado e incluem
modulo de snapshot a partir do fonte; nao dependem de imagem local nao publicada.

```bash
docker build -f Dockerfile.mysql-operations-runtime -t dunckops-mysql-operations-runtime:development .
docker build -f Dockerfile.mariadb-operations-runtime -t dunckops-mariadb-operations-runtime:development .
dotnet build apps/docker-agent/DunckOps.DockerAgent.csproj
```

Flags/imagens constam nos env examples, Compose, publicacao e bundle offline.
Este wiring de deployment nao altera contratos ou implementacoes das engines.

## Collector E PITR

Native `mysqlbinlog`/`mariadb-binlog --read-from-remote-server --raw --stop-never`
mantem conexao TLS persistente desde arquivo/posicao do snapshot. Stdin fornece
credenciais uma unica vez; cliente usa arquivo tmpfs e Docker logging `none`.
Readiness exige processo nativo vivo e arquivo de streaming inicial criado.
Namespace e o da origem autorizada; datadir vivo nunca montado.

Streaming parcial e **nunca** publicado como arquivo selado. Apos `SHOW BINARY LOGS`
confirmar arquivo nao ativo, downloader nativo captura arquivo completo desde
posicao 4 para preservar FDE/checksums; tamanho/identidade sao reconferidos na
origem. Parser independente confere magic, framing, posicoes, CRC32, server-id,
versao, FDE fechado e rotate para sucessor numerico exato. Decoder nativo valida
novamente. MariaDB admite log_pos=0 apenas em annotation/table-map/rows em cache;
posicao fisica e CRC32 conferidos e fechamento XID exige posicao real.
Timestamp FDE do primeiro arquivo nao pode ser posterior ao snapshot; reutilizar
nome/epoch depois de reset e rejeitado. Binlog inicial ausente/purgado, source
identity alterada, gaps, truncamento, checksum ou desconexao causam falha fechada.

Persistencia calculada: `/backups/mysql-log-collections/<companyId:N>/<collectionId:N>/`.
`collection.json` imutavel vincula snapshot/manifesto, engine, empresa, container,
server-id e UUID MySQL. `sealed/<arquivo>` publicado sem sobrescrita, com fsync.
`index.00000000.json` e sucessores sao publicados atomicamente, com sequence e
previousSha256 encadeados ao hash do genesis. Cada seal inclui tamanho/hash,
timestamps nativos, proximo arquivo e limites completos de transacoes.
**Hash-linked, nao assinatura criptografica**: operador root/escritor confiavel
continua fronteira de seguranca. Registros terminal `stopped|failed` sao append-only.
Stop confere labels de empresa/collection/engine, encerra somente collector proprio,
exige terminal limpo e remove container, preservando arquivos. Falha nativa resulta
em `collector_failed_stopped` (422), nao falso sucesso. Stop usa imagem/volume
originais do collector mesmo se overrides do operador mudarem.

PITR aceita somente **ROW + CRC32, InnoDB, transacoes completas GTID/anonymous-GTID
e XID** depois da posicao do snapshot. MySQL GTID mode deve ser OFF neste recorte;
anon-GTID ainda contem timestamp de commit nativo. MariaDB usa posicao de arquivo,
nao MASTER_USE_GTID. DDL/statement, XA, system tables, eventos desconhecidos,
compressao e transacoes incompletas sao rejeitados, nao parcialmente aplicados.
Limites: 1 GiB por arquivo, 64 MiB por evento, 100.000 transacoes por arquivo e
10.000 registros de indice. Storage/quota/retencao continuam responsabilidade do operador.

Corte **exclusivo**: transacao incluida somente quando commit nativo e anterior a
`targetTimeUtc`. MySQL usa immediate_commit_timestamp do GTID; MariaDB usa timestamp
XID em segundos. Grupos completos sao selecionados antes do decoder; nunca usar
`--stop-datetime` dentro de transacao. Clock regression/ordem de commit nao monotona
rejeitadas. Exige transacao selada no corte ou depois dele para provar cobertura;
poll SQL, heartbeat, instante de stop ou log ativo nao estendem cobertura UTC.
Alvo anterior a conclusao do snapshot ou posterior a cobertura e rejeitado.

Plano fixa sequence/head SHA antes de criar alvo. Replay revalida mesmo prefixo,
todos os arquivos/metadados/hashes e tabelas InnoDB no alvo novo. Native decoder
usa posicao inicial exata do snapshot e stop-position no fim do ultimo XID
incluido, `TZ=UTC`, sem force-read/ignore-errors. SQL vai por pipe ao cliente TLS;
falha remove exclusivamente alvo novo. Read-only e restabelecido antes do sucesso.
`pitr.json` separado vincula plano/corte/coverage/arquivos/contagem ao snapshot.
Indice com gap/hash alterado ou colecao failed nunca e aceito como replay completo.

## Standby E Promocao

`configure-standby` exige origem standalone acessivel em bridge e consentimento
`allowSourceNetworkAttachment=true` para conectar origem a **novo bridge interno**.
Essa anexacao Docker explicita e unica alteracao de wiring da origem; nenhum SQL
de configuracao/locks/flush e executado na origem. Falha desconecta somente esse
bridge proprio. Alvo novo possui server-id diferente, datadir exclusivo, read-only,
sem eventos/auto-start/ports e apenas esse network. Arquivo inicial deve existir.

Admin restaurado e `replicationUser/replicationPassword` sao credenciais separadas.
Native CHANGE REPLICATION SOURCE usa SOURCE_DELAY/MySQL; CHANGE MASTER usa
MASTER_DELAY/MariaDB. TLS obrigatorio; MariaDB mantem verificacao de certificado.
MySQL requer criptografia, sem configurar bypass global de TLS. Delay efetivo,
IO/SQL threads Yes, read-only e SSL configurado conferidos antes de sucesso.
`standby.json` registra prova sanitizada. **Senha de replicacao persiste nos
metadados nativos do alvo**, conforme mecanismo do servidor: proteja volume alvo.
Nao aparece em argv, env, logs ou relatorio; CHANGE recebe SQL via stdin.

Promocao aceita somente container/volume/rede com ownership conjunto de empresa,
engine, snapshot e operacao criadora. Volume deve ser novo local padrao e diferente
de todos os mounts da origem. Rede deve conter exatamente origem e alvo; containers
originais e restores comuns nao sao candidatos. Admin deve autenticar alvo e origem
para observar watermark; rotacao dessa credencial exige procedimento do operador.

`catchUp=true` remove delay somente no alvo, espera SOURCE_POS_WAIT/MASTER_POS_WAIT
ate watermark observado e para replica. Posicao executada e comparada a nova
posicao da origem. Se atrasado, exige `allowDataLoss=true`; rejeicao mantem read-only
e restaura delay/threads do standby. Sucesso RESET REPLICA/SLAVE ALL, writable
confirmado e `promotion.json` separado. Origem nao e parada/promovida/modificada.
`sourceFenced=false`: **operador deve quiescer origem e planejar cutover**; watermark
observado nao impede novas escritas apos comparacao. Sem failover automatico.
Timeout/crash durante detach pode deixar promocao parcial: inspecione alvo proprio
antes de repetir. Nunca remover/reinicializar origem para tentar corrigir.

## Ensaios Manuais

Docker local, fontes sinteticas descartaveis, reflection .NET, sem arquivos de
testes/harness ou rotas temporarias. MySQL 8.4.11 e MariaDB 11.4.13: snapshot
completo, restore TLS retido, dados `1:alpha,2:beta`, verify com descarte automatico.
Campos extras/empresa divergente/artefato corrompido rejeitados; managed=false
rejeitado mesmo com allow-any. Manifesto permanece imutavel e restoreValidated=false.

Nas duas engines: streaming continuo real, seal apos FLUSH manual somente na fonte
sintetica, stop limpo; PITR recuperou exatamente `1:baseline,2:before` excluindo
`3:after`. Native standby com delay 2, IO/SQL ativos e conta de replicacao REQUIRE
SSL; catch-up e promocao recuperaram `1:baseline,2:before,3:after`. Todos os recursos
sinteticos removidos; nenhum collector ativo. Sem garantia para workload fora dos
limites acima. Build agent e ambas imagens passaram; NU1903 preexistente em
Microsoft.OpenApi 2.0.0 (severidade alta) permanece fora deste recorte.

Ensaio final em ambas engines: **dois arquivos selados**, transacao com duas
escritas atravessando corte UTC excluida inteira, rejeicao de cobertura baseada
somente em log ativo. Delay nativo 60 confirmado; promocao sem catch-up/consentimento
rejeitada e alvo permaneceu read-only; catch-up/promocao posterior recuperou todas
as cinco linhas, identicas a origem. Rejeitados stop de outra empresa, reuso de
collector, gap no indice, byte alterado no binlog selado e binlog inicial purgado.
Promocao da propria origem rejeitada. SHA do manifesto original e
restoreValidated=false reconferidos. Containers, volumes e redes sinteticos:
zero restantes. Builds dos runtimes tambem compilam Python para detectar erro de
sintaxe antes de publicar imagem. Nenhum arquivo de testes/harness foi criado.

Somente `stop-log-collection` de collector proprio permanece permitido apos
desativar feature flag ou perder autorizacao comercial. A API ainda exige admin,
empresa e vinculo ativos; o agente confere ownership. Nenhuma nova operacao recebe
esse bypass. Em stop forcado/SIGKILL, nao
declarar terminal limpo ou usar staging como seal; indice publicado e artefatos
permanecem para inspecao manual, nunca para sobrescrita/resume automatico.

### Cancelamento Do Collector

SIGTERM marca stop; comandos SQL e download/decoder do collector verificam flag
a cada 200 ms. Cancelamento termina exclusivamente grupo do filho nativo: TERM
ate 5 segundos, KILL ate 5 segundos, sem wait indefinido. Flag tambem e conferida
entre arquivos, apos validacao/hash e antes de iniciar publicacao. Uma publicacao
ja iniciada termina arquivo verificado + indice completo, ou falha fechada;
nenhum ponto de cancelamento transforma publicacao desconhecida em stop limpo.
`stopped` so e escrito apos confirmar termino dos filhos, remover credenciais e
descartar incoming/streaming. Falhas de termino/publicacao/limpeza nao geram ACK
limpo. Grace Docker: 45 segundos, chamada stop limitada a 60 segundos; cleanup
independente continua limitado a 90 segundos. I/O/kernel travado pode exceder
grace e provocar kill do container, caso em que nao ha declaracao de terminal limpo.

Smokes adicionais nas duas engines suspenderam com SIGSTOP filho real de download
e cliente SQL real durante janela ativa, exercitando fallback SIGKILL. Stop via
classe concluiu em 5,63..5,67 segundos nos quatro cenarios: terminal stopped,
cadeia/SHA dos arquivos anteriores preservados, captura pendente nao publicada,
incoming/streaming removidos, collector removido e origem viva com tres linhas.
Todas as fontes/volumes sinteticos removidos ao final; nenhum arquivo de testes.
