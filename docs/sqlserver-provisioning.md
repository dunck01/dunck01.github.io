# SQL Server: provisionamento gerenciado e perfil avancado

SQL Server fica visivel na criacao de bancos, mesmo indisponivel. A API publica
capacidades e motivos; selecionar engine nao autoriza criacao. BACPAC/copia logica
nao sao anunciados. `nativeclone` restaura FULL assinado em alvo proprio, sem
simular copia logica. Provisionamento nao comprova homologacao SQL nem producao.

## Perfil gerenciado por empresa

Administrador habilita `SQLSERVER_MANAGED_SETUP_ENABLED=true`, os dois opt-ins
operacionais existentes e aprova o cliente por ID imutavel ou manifesto assinado.
Nenhum ID e inferido automaticamente de tag baixada. Cliente atualizado exige
label `io.dunckops.sqlserver-managed-protocol=2`.

No formulario SQL, `Preparar TLS e volumes automaticamente` chama comando
autenticado/admin com entitlement SQL. Agente gera cinco volumes local distintos,
com empresa e ownership da operacao: TLS, trust publico, backup, assinatura e CA
privada. Gera RSA >=3072, CA por dez anos, leaf por 365 dias, SAN DNS unico da
empresa e IP 127.0.0.1. Arquivos privados recebem 0600; diretorios 0700 e UID 10001.
Registro Docker inerte persiste metadados publicos, nao senhas/chaves em labels.
CA privada nunca vai ao SQL Server, cliente operacional ou control plane.
Assinatura privada nunca vai ao servidor ou API. Setup nao inicia SQL nem aceita EULA.

API valida cadeia/EKU/SAN e hashes do material publico recebido pelo canal do
agente autenticado. Persiste somente leaf publico no cache API/Worker compartilhado.
SqlClient usa `ServerCertificate` com correspondencia exata e Encrypt Mandatory;
TrustServerCertificate permanece false. Nenhuma CA e instalada no host, nenhum
trust global e alterado. Clientes recebem apenas trust publico e assinatura RO.
Download de CA publica aparece no formulario; nao contem chave privada.

Renovacao exige consentimento de manutencao. Coletores, standby e consumidores
desconhecidos ativos bloqueiam renovacao: pare atores pelo controle autenticado.
Agente serializa mutacoes, valida ownership, para/reinicia somente servidores SQL
gerenciados da empresa, troca chave/leaf, preserva datadirs, backup, CA e assinatura.
Falha antes da troca do registro restaura material anterior. Reinicio solicitado
nao e prova de prontidao TDS. Chave de assinatura permanece estavel para preservar
arquivos historicos; nao ha rotacao automatica que invalide manifests existentes.
Revogacao do acesso usa controle de credenciais/instalacao, nao CRL online implicita.

Os campos `SQLSERVER_PROVISIONING_*` abaixo ficam vazios neste modo. Perfil avancado
continua opcional para certificados e volumes administrados externamente.

## Criacao assincrona e recuperacao

### Guardas de admissao e compensacao

Enqueue e Worker validam o usuario efetivo (padrao dunckops, ate 32 caracteres,
sem dbo/guest/sys/information_schema) e senha efetiva (8..128, sem controles,
maiuscula/minuscula/digito/simbolo). Senha ausente gera segredo forte antes do
payload cifrado; entrada invalida nao transfere .bak nem despacha recursos.
Worker revalida MULTI_ENGINE_OPERATIONS_ENABLED e SQLSERVER_OPERATIONS_UNVERIFIED_OPT_IN
antes do dispatch. Opt-in SQL local desligado desabilita somente capacidades SQL.

Compensacao inspeciona nomes deterministas e ownership do container/datadir mesmo
quando CREATE Docker perdeu resposta. Token independente permite cleanup apos
timeout/cancelamento. Ownership divergente, mount compartilhado, ator ativo ou
inspecao indisponivel impedem confirmar cleanup. Apenas ausencia/remocao verificada
de recursos libera reserva; resposta perdida nunca significa automaticamente ausencia.

FULL inicial exige cliente aprovado atualizado com label
io.dunckops.sqlserver-bootstrap-cleanup=1. --prepare-bootstrap escreve marcador de
empresa/operacao/container/datadir antes do BACKUP, recusando pasta preexistente.
Compensacao remove o servidor para cessar escrita SQL, entao --cleanup-bootstrap
valida marcador e remove exclusivamente initial-full.bak e marcador na pasta
sqlserver/<empresa N>/bootstrap/<operacao N>. Nao remove volume compartilhado,
catalogo/snapshots nem pasta vizinha; symlinks/arquivos inesperados sao recusados.
Falha deixa cleanupCompleted=false e boundary duravel com operationId,
bootstrapNamespace e retencao para reconciliacao manual. Pastas legadas sem marcador
nao sao apagadas por inferencia. Builds nao aprovam imagem automaticamente.

Novo alvo de recuperacao pode referenciar snapshotId autorizado; standby exige
essa referencia e deriva a major daquele snapshot, nao do mais recente da origem.
UI envia snapshot/modo e invalida consentimentos quando mudam. Cliente compara
HEADERONLY real com major assinada e ProductMajorVersion do alvo antes de criar
estado/pasta de restore ou executar RESTORE: standby requer igualdade; clone/PITR
requerem target >= source. Erros sanitizados indicam incompatibilidade e ausencia
de efeitos de restore. Trocar snapshot apos criar alvo nao contorna essas guardas.

### Importacao externa nativa .bak

O modo SQL "Importar backup .bak" usa o mesmo job protegido `sqlserver_provision`.
Nao e BACPAC, copia logica por TDS nem copia de diretorio fisico. Nao conecta ao
servidor de origem. O cliente deposita previamente um FULL nativo completo, de
arquivo unico, com CHECKSUM, no storage S3 compativel ativo do projeto. Para criar
esse arquivo sem alterar a cadeia de backup da origem, use COPY_ONLY FULL WITH
CHECKSUM nas ferramentas administradas pelo cliente. DunckOps nao executa esse
backup remoto nem transfere um caminho do sistema operacional da origem por TDS.

`POST /api/v1/projects/{projectId}/databases/sqlserver/import` despacha o comando
dedicado EnqueueSqlServerNativeImportCommand e aceita os campos
de criacao/consentimento existentes e `nativeBackup`:

```json
{
  "storageConfigId": "<storage UUID da empresa/projeto>",
  "objectKey": "imports/database.bak",
  "sha256": "<64 caracteres hexadecimais minusculos>",
  "sizeBytes": 123456789
}
```

O bloco acima e o valor de `nativeBackup`, nao o pedido completo. `connectionString`
e `postgresVersion` devem estar ausentes/vazios neste modo. A chave e relativa ao
prefixo configurado no storage, nao uma URL nem caminho de host. Bucket, endpoint
e credenciais sao resolvidos exclusivamente do StorageConfig autorizado. Storage
local e endpoints sem HTTPS verificado sao recusados. HEAD + GET condicional por
ETag evitam troca do objeto entre consultas; SHA-256/tamanho declarados continuam
obrigatorios (ETag nao substitui SHA-256). Objeto original nunca e excluido/alterado.
O comando dedicado reutiliza a reserva/outbox `sqlserver_provision`, ja protegida
contra reprocessamento/cancelamento/exclusao genericos e incluida na quota; nao
introduz um novo tipo persistido sem essas protecoes. A rota de provisionamento
tambem reconhece o campo NativeBackup, mas import sem artefato na rota dedicada
e recusado, nunca convertido em criacao vazia.

Transferencia Worker -> agente autenticado -> cliente .NET aprovado usa streaming,
buffer de 1 MiB, sem arquivo temporario no Worker nem backup inteiro em memoria.
O receptor e isolado (rede none, rootfs RO, UID 10001, sem capabilities/logs) e
escreve somente `import/source.bak` no novo datadir exclusivo da operacao. Exige
EOF, tamanho exato e SHA-256 antes de publicar evidencia; nao sobrescreve arquivo.
Limite e `ENGINE_ARTIFACTS_MAX_BYTES` (maximo absoluto 1 TiB), aplicado tanto ao .bak
transferido quanto a soma D/L descomprimida de FILELISTONLY. Import completo tem
deadline de seis horas; etapa SQL admite ate duas horas. Espaco de disco, memoria,
I/O e throughput continuam responsabilidade do operador; erro nao significa copia.
Servidor de importacao recebe limite Docker de 4 GiB, 2 CPUs e 512 PIDs; o receptor
usa 256 MiB/1 CPU/64 PIDs. VERIFYONLY usa os MOVE gerados para verificacao nativa
do destino; nao ha reserva fisica universal de disco nem elasticidade implicita.

Catalogo consulta apenas `mcr.microsoft.com/v2/mssql/server/tags/list`, por HTTPS,
sem redirects, com timeout de oito segundos/cache de quinze minutos. Familias
conhecidas: 2019/15, 2022/16, 2025/17; CTP/RC/preview/windows/tags arbitrarias nao
sao aceitas. Novas majors exigem implementacao de perfil, nao descoberta automatica.
O perfil operacional integrado admite destinos 2022/2025, nao 2019: o protocolo de
logs usa metadados nativos introduzidos em 2022. Import de origem 2019 faz upgrade.
Offline ou falha de registry: somente imagens locais Linux/amd64; nao anuncia
imagem baixavel com cache expirado.

Como `.bak` nao tem parser de metadados portavel neste produto, o job escolhe a
maior familia elegivel disponivel e cria um unico servidor novo para inspecao e
restore. Nao inventa major a partir do nome/chave/sidecar. `HEADERONLY` descobre a
major real 15/16/17 e confirma target >= source; 17 em destino 16 offline e recusado.
Pull e feito somente quando permitido e necessario. Versao nativa, edicao, Linux,
UTC e TLS do servidor sao verificados antes de criar/restaurar user database.
O consentimento por pedido cobre explicitamente inspecao e restore no mesmo
servidor, na edicao declarada, com candidatos estaveis 2022/2025; nenhuma EULA e
aceita pela instalacao, build ou validacao offline.
Em 2025, a escolha Developer usa `MSSQL_PID=EnterpriseDeveloper`; em 2022 usa
Developer. Edicao real e validada por EditionID oficial (-2117995310 para ambas),
nao pelo texto "Developer Edition" que mudou em 2025. StandardDeveloper nao e
habilitado implicitamente. Enterprise conserva o PID Enterprise legado (Server/CAL,
20 cores), nao concede EnterpriseCore nem altera modelo de licenca silenciosamente.
ProductLevel deve ser RTM (incluindo CUs/GDR), nunca CTP. Referencias:
https://learn.microsoft.com/en-us/sql/linux/configure/environment-variables?view=sql-server-ver17
e https://learn.microsoft.com/en-us/sql/t-sql/functions/serverproperty-transact-sql?view=sql-server-ver17.

Requer cliente atualizado/aprovado por ID ou assinatura, com protocolo 2 e label
`io.dunckops.sqlserver-native-import=1`. Imagem antiga nao anuncia importacao; SQL
2025 tambem exige esse cliente atualizado. Build nao aprova automaticamente imagem.

Antes de restore: SHA-256/tamanho novamente, LABELONLY com familia/media unica,
HEADERONLY unico FULL completo com
checksums, FILELISTONLY somente D/L presentes, VERIFYONLY CHECKSUM, destino sem
user databases e caminhos MOVE inexistentes gerados por UUID/file ID. Sem REPLACE,
paths fornecidos pelo backup, acesso ao filesystem da origem ou mutation da origem.
Depois: prova nativa ONLINE, restorehistory ligado ao BackupSetGUID, arquivos nos
paths gerados, CHECKDB PHYSICAL_ONLY sem erros e SHA-256 novamente. Nao se anuncia
validacao completa de aplicacao, contagem exata de linhas ou homologacao de producao.

Recusados explicitamente: majors fora de 15/16/17, bancos de sistema, backupsets
multiplos, diferencial/LOG/parcial/snapshot, backups sem checksum/danificados,
backup criptografado/TDE sem chaves, FILESTREAM/memory-optimized file containers,
CLR de usuario, tabelas/data sources externas, synonyms, triggers DDL de banco,
dependencias cross-database/server catalogadas, containment, banco read-only
ou broker ativo. Restricoes de edicao/plataforma/recursos restantes sao verificadas
pelo RESTORE nativo e retornam erro de incompatibilidade, nunca promessa de migracao
universal. Usuario operacional solicitado nao pode ja existir no backup; logins
de servidor e cadeia LOG original nao sao migrados. TRUSTWORTHY/DB_CHAINING ficam OFF.
Referencias em SQL dinamico e comportamento de aplicacao nao sao analisados
universalmente; requerem revisao/homologacao do cliente.

Somente apos essas provas o novo banco recebe recovery FULL e FULL normal inicial,
credencial operacional nova, registro de origem e snapshot COPY_ONLY assinado.
Coleta LOG opcional exige entitlement/consentimento separados e comeca nessa nova
cadeia, nao na origem. Evidencia retorna `sqlserver-native-backup-v1`, sourceVersion,
targetVersion, SHA-256 e bytes. `.bak` de staging e removido apos inicializacao
verificada; falhas removem apenas container/datadir de ownership exato. Resultado
incerto conserva reserva/evidencia para reconciliacao, sem retry/replay nativo.
`productionReady=false` permanece. Homologacao real ainda deve cobrir cada edicao,
familia, backup e plataforma sob licencas/consentimentos do operador.

Bundle offline permite `-IncludeSqlServer2022` e/ou `-IncludeSqlServer2025` com
declaracao de direitos de distribuicao. `-DryRun` apenas lista imagens; nao faz pull,
nao inicia SQL e nao aceita EULA. Microsoft Learn: containers Linux SQL 2019/2022/2025
em https://learn.microsoft.com/en-us/sql/linux/install-upgrade/quickstart-install-docker
e restore de backup em https://learn.microsoft.com/en-us/sql/linux/migrate/tutorial-restore-backup-sql-server-container.

UI e rota de criacao SQL retornam 202/jobId. Worker revalida usuario, empresa,
entitlement e quota. Pedido fica cifrado no job, expira em 24 horas e e removido
antes do dispatch. ID do job vincula container/datadir novos; reserva entra na
contagem global de bancos antes de criar recursos. Outbox reenfileira apenas
pending; running expirado vira resultado ambiguo, nunca replay nativo. Boundary
duravel e gravado em contexto independente antes do dispatch: rollback nao apaga reserva de dispatch
ambiguo. Somente ID do banco persistido ou compensacao comprovada libera essa
reserva; coincidencia de nome nao substitui identidade. Controles genericos,
exclusao de job e reprocessamento em lote nao apagam evidencias de provisionamento.

Pipeline cria servidor/banco, configura recovery FULL, verifica FULL normal inicial,
registra origem/credenciais cifradas atomicamente com DatabaseInstance, captura
COPY_ONLY assinado/catalogado e inicia coletor quando autorizado separadamente.
Developer exige declaracao adicional de desenvolvimento/testes. Logs exigem
entitlement PITR e consentimento de consumo/truncamento de cadeia.
Alvos de recuperacao usam a major do ultimo snapshot nativo catalogado quando
disponivel; servidores novos tambem carregam a major verificada em labels. Alvos
de origens gerenciadas anteriores sem esses metadados conservam o perfil legado
2022. O agente e o control plane verificam a major nativa do novo alvo, sem tratar
a selecao de imagem como prova de restore.

Coletor roda BACKUP LOG nativo a cada 300 segundos, sem SQL Agent. Agendamento
persistido acompanha atores parados/removidos e enfileira resume com credenciais
da origem cifrada, revalidando entitlement, usuario e ownership inclusive quando
coletor ja esta ativo. Revogacao tenta parar ator; falha de transporte preserva
retentativa. Falha transitoria de enqueue nao desabilita agendamento duravel.
Stop explicito desabilita
esse agendamento. Estado ambiguo desabilita retomada automatica. Limite conservador
de 1000 logs/catalogo permanece: crie novo snapshot/coleta apos atingir capacidade;
nao se anuncia catalogo ilimitado nem migracao automatica de standby entre cadeias.

Painel de recuperacao cria alvo por job com novos consentimentos de licenca/EULA,
datadir exclusivo, backup RO, TLS RO, rede none, sem portas e credencial restore
cifrada (dbcreator/metadados apenas no servidor dedicado). Nao cria user database
nem FULL no alvo. Perfil nativo vazio e autenticacao precisam passar antes de sucesso.
restoreId fica vinculado a container/volume/registro e nao pode ser trocado.
PITR/standby/clone resolvem credenciais pelo registro, sem envia-las ao navegador.
Clone nativo verifica snapshot e restaura FULL com MOVE/RECOVERY e prova ONLINE;
nao executa STOPAT/logs nem recebe rotulo logicalCopy.

FULL manual no painel gerenciado usa credenciais do registro e pipeline de jobs
com catalogacao, nao endpoint sincrono sem catalogo. Aguarde conclusao do job antes
de recuperar pelo UUID reservado. Standby oferece start, status, stop, resume e
promote sem pedir senha do alvo; retomada conserva configuracao original e
promocao exige consentimento proprio, com ator previamente parado. Status e stop
permanecem acessiveis em alvo reservado/pendente de reconciliacao, sem autorizar
novo restore nesse estado. Coleta tambem tem start, status, stop e resume pelo
registro cifrado; nenhum desses fluxos pede senha gerada do servidor ao navegador.

Exclusao exige confirmacao destrutiva separada e ownership exato de alvo/datadir
gerenciados. Atores, execucoes pendentes/ambiguas e datadir compartilhado bloqueiam.
Origem, backup, trust, CA e assinatura nunca sao removidos. Compensacao confirmada
libera reserva; incerteza retém quota e recursos para reconciliacao, sem falso sucesso.
Cancelar recuperacao antes do dispatch devolve alvo SQL ja criado ao estado ativo;
nao remove container/datadir nem libera sua quota. Retomada, promocao e controles
enfileirados tambem mantem referencia ao alvo, bloqueando exclusao concorrente.
Exclusao fisica usa comando
dedicado e confirmacao destrutiva.

## Configuracao do operador

No diretorio instalado, configure somente pre-requisitos tecnicos:

```dotenv
MULTI_ENGINE_OPERATIONS_ENABLED=true
ENGINE_PROVISIONING_ALLOW_IMAGE_PULL=true
SQLSERVER_PROVISIONING_ENCRYPT=true
SQLSERVER_PROVISIONING_TRUST_SERVER_CERTIFICATE=false
SQLSERVER_OPERATIONS_UNVERIFIED_OPT_IN=true
SQLSERVER_PROVISIONING_TLS_PROFILE_ENABLED=true
SQLSERVER_PROVISIONING_COMPANY_ID=<UUID da empresa>
SQLSERVER_PROVISIONING_TLS_VOLUME=<volume TLS privado da empresa>
SQLSERVER_PROVISIONING_TRUST_VOLUME=<volume publico da empresa>
SQLSERVER_PROVISIONING_TLS_HOSTNAME=sqlserver.internal
SQLSERVER_PROVISIONING_CA_SHA256=<SHA256 certificado raiz DER, hex minusculo>
SQLSERVER_OPERATIONS_BACKUP_VOLUME=<volume de backup da empresa>
SQLSERVER_OPERATIONS_SIGNING_VOLUME=<volume de assinatura da empresa>
SQLSERVER_OPERATIONS_SIGNING_PUBLIC_KEY_SHA256=<SHA256 SPKI DER da assinatura>
SQLSERVER_OPERATIONS_RUNTIME_IMAGE=sha256:<ID aprovado do cliente atualizado>
```

Instaladores online/offline persistem configuracao publica explicitamente fornecida,
validam formatos e preservam valores existentes ausentes no ambiente. Update e
rollback reaplicam overlay quando habilitado. Nao geram chaves, aceitam EULA,
escolhem edicao, aprovam imagem ou habilitam opt-in automaticamente.

Quatro volumes devem existir antes, distintos, driver `local`, sem opcoes de
driver, todos com label `pitr.company-id=<UUID D minusculo>` da empresa configurada.
Um perfil por agente/empresa; outra empresa e recusada antes de criar recursos.
Use arquivo de backup exclusivo por empresa; nao compartilhe entre tenants.
Datadir novo e gerado por operacao, com labels da empresa/operacao.

Conteudo fornecido fora do repositorio:

| Volume | Arquivo/permissao | Uso |
| --- | --- | --- |
| TLS | `server.pem` (leaf + intermediarias), `server-key.pem` RSA >=2048, modo 0600, UID 10001 | Servidor RO; probe cliente aprovado temporario RO |
| Trust publico | `ca-bundle.pem`, legivel pelo usuario da API/Worker e UID 10001 | Somente certificados publicos, nunca chaves privadas |
| Assinatura | `manifest-key.pem`, RSA >=3072, modo 0600, UID 10001 | Somente probe/cliente de operacoes RO, nunca servidor |
| Backup | Raiz gravavel por UID 10001, diretorios protegidos | Servidor/cliente RW; servidor alvo restore RO |

Diretorios/arquivos de identidade nao podem ser symlinks. Bundle CA deve incluir
raizes publicas necessarias para HTTPS comercial/storage alem da raiz SQL:
`SSL_CERT_FILE` seleciona esse bundle para os processos .NET. CA TLS e chave de
assinatura sao identidades distintas; fingerprint CA e certificado DER inteiro,
fingerprint assinatura e chave publica SPKI DER. Nao intercambiar.

Certificado exige SAN IP `127.0.0.1` e SAN DNS exato
`SQLSERVER_PROVISIONING_TLS_HOSTNAME`, sem wildcard. Hostname fixo e identidade
Docker interna configurada no servidor. Clientes API/Worker podem rotear por
short-ID imutavel ou endpoint publicado: connection string conserva
`Host Name In Certificate` fixado, sem desabilitar verificacao. IP dinamico nao
precisa entrar no SAN. Runtime de operacoes usa loopback com verificacao nativa.

Probe executa apenas CLIENTE aprovado com rede `none`, UID 10001, root RO,
capabilities removidas e sem logs. Valida cadeia contra CA fixada, validade/EKU,
SANs, chave correspondente, assinatura fixada e escrita de arquivo temporario
exclusivo no backup (removido). Nao conecta SQL, inicia servidor, aceita EULA
nem altera cadeia de logs. Nao e homologacao SQL. Revogacao nao consultada em
preflight offline; operador responde por revogacao/rotacao e renovacao.

## Declaracao por novo container

Matriz publicada pelo agente: SQL Server `2022-latest`, `Developer`, `Standard`
ou `Enterprise`. Express indisponivel: runtime de backup rejeita essa edicao.
SQL 2019 tambem indisponivel: runtime exige major 16, Linux amd64.
Developer somente desenvolvimento/testes, nunca producao.
Standard/Enterprise exigem direitos de uso adequados. Escolher edicao nao verifica
licenca. Nao existe edicao preselecionada.

Dois checkboxes inicialmente desmarcados separam responsabilidade do cliente
pelo licenciamento e aceite da EULA Microsoft aplicavel, com autorizacao para
aceitar e catalogo oficial: https://www.microsoft.com/en-us/useterms.
Cliente deve consultar termos da versao, edicao e canal de aquisicao, incluindo
termos que acompanham a imagem e contrato Microsoft para licenciamento por volume.
Trocar modo, engine, versao ou edicao limpa os aceites. API e agente autenticado
validam edicao permitida, `sqlServerLicenseAcknowledged` e `sqlServerEulaAccepted`
antes de criar; nenhuma flag global substitui consentimento por requisicao.
Somente apos aceite explicito a imagem recebe `ACCEPT_EULA=Y` e `MSSQL_PID`
da edicao escolhida. Imagem previamente instalada tambem exige os aceites para
criar novo container. Vincular container existente nao exige esses checkboxes
nem altera sua edicao/EULA. Outras engines nao recebem novos bloqueios.

DunckOps gerencia backups, nao fornece nem verifica licencas Microsoft. Cliente
responde pelo uso legal de licencas de qualquer banco. Declaracao nao elimina
obrigacoes proprias do DunckOps nem garante protecao juridica; revisar texto com
assessoria juridica conforme contratos, jurisdicao e forma de distribuicao.

Auditoria existente registra usuario, empresa, data UTC, versao, edicao,
versao da declaracao e URL dos termos antes do envio ao agente, sem senhas.
Evento comprova registro da solicitacao autorizada, nao sucesso da criacao
nem verificacao da licenca. Nao foram adicionadas tabelas ou migrations.

`emptyProvisioning` e `backupIntegrationAvailable` tornam-se verdadeiros somente
apos probe do perfil da empresa; criacao tambem repete preflight antes de pull/data.
Sem configuracao/material/imagem retorna motivo seguro especifico, nunca bloqueio
permanente incondicional. API exige trust publico local; conexao nativa no agente
e depois na API continua obrigatoria. Opt-in TrustServerCertificate=true e recusado.

Compose ja encaminha configuracoes ao agente e flag multi-engine a API. Aplique:

```bash
docker compose --env-file .env -f docker-compose.prod.yml -f docker-compose.docker-ops.prod.yml -f docker-compose.sqlserver-tls.yml up -d --force-recreate api worker docker-agent
```

Reabra formulario para consultar capacidades. Rede bridge configurada em
`ENGINE_PROVISIONING_NETWORK` precisa existir. Com pull desativado, operador
precisa carregar previamente imagem SQL 2022 aprovada no Docker do agente;
imagem instalada nao dispensa preflight. Bundle offline inclui overlay, scripts e
cliente atualizado, nao imagem do servidor, certificados, chaves nem licenca.
Bundle privado opcional pode incluir servidor SQL 2022 com
`-IncludeSqlServer2022 -SqlServerDistributionRightsAcknowledged -MultiEngineOperations`.
Declaracao exige direitos de distribuicao adequados, nao concede esses direitos
nem aceita EULA. Bundle generico nao inclui servidor. Operador aprova ID do cliente.
Entitlement comercial assinado tambem precisa permitir `sqlserver`; flags locais
nao substituem claims nem autorizam engines ausentes na licenca.

## Provisionamento e operacoes

Servidor recebe datadir RW novo, backup RW da empresa e TLS RO no caminho fixo
`/etc/dunckops/sqlserver-tls`, sem tmpfs. Agente grava somente `mssql.conf` no
datadir proprio, UID 10001, TLS 1.2 e `forceencryption=1`. Senha inicial via attach
stdin para variavel de processo, nunca arquivo, Docker Env/Cmd ou logs. Restart
usa master inicializado e dispensa segredo inicial. Timezone solicitada UTC.

Usuario nao-sa recebe db_datareader/db_datawriter/db_backupoperator,
VIEW DATABASE STATE, CREATE ANY DATABASE, VIEW SERVER STATE e
VIEW SERVER PERFORMANCE STATE exigidos por captura/VERIFYONLY e metadata.
Nao recebe sysadmin/db_owner; recebe usuario msdb com SELECT somente em
dbo.backupset, necessario para provar a base FULL na coleta nativa.
Esses grants e limites aparecem no formulario antes da solicitacao. Segregue
credenciais de aplicacao depois conforme politica local. Usuario sa exige escolha
explicita; nao e default. Consentimento separado `sqlServerBackupIoAccepted`
autoriza recovery FULL e FULL normal inicial com CHECKSUM/VERIFYONLY somente no
banco novo da operacao. Agente valida historico nativo, GUID e caminho exclusivo
antes de responder `initialFullVerified=true`; API exige essa prova.

Criacao registra container+database em Operacoes de Engines no projeto, com
credenciais cifradas. Reutiliza admissao existente, confirma ownership no agente e
persiste DatabaseInstance, fonte, credenciais e auditoria no mesmo SaveChanges,
sem duplicar quota. Inicializacao assincrona captura `fullsnapshot` assinado e
catalogado; FULL de bootstrap isolado nao e snapshot catalogado. Capturas seguintes
usam botao de FULL catalogado com consentimento I/O e credenciais do registro.
Backup classico continua indisponivel; use engine-operations, sem politica PG falsa.

PITR/coleta exigem FULL recovery, FULL normal inicial e permissoes msdb.
Provisionamento gerenciado prepara esses requisitos; fontes externas continuam
responsabilidade do operador e nao recebem ALTER recovery nem FULL automaticos.
Alvo restore pode ser criado pelo painel gerenciado ou fornecido pelo operador,
sempre com direitos de uso validos: vazio, dedicado,
role `sqlserver-restore-target`, rede `none`, sem portas, datadir exclusivo e
backup RO. Pode adicionar o mesmo TLS RO configurado; cliente recebe somente CA
publica RO e assinatura RO, nunca TLS privado ou datadir. Fonte externa com TLS
no datadir preserva perfil anterior de dois mounts. Outros mounts continuam rejeitados.

Falha compensa apenas container e datadir novos com ownership da operacao. Backup,
TLS, trust e signing preexistentes nunca sao removidos. Falha de compensacao exige
reconciliacao manual; nao reporta criacao concluida.

## Homologacao pendente

### Correcoes da revisao de 2026-10-09

Captura FULL, coleta LOG e recuperacao usam o mesmo gate nativo: SQL 16/17,
Linux, ProductLevel RTM e EditionID/EngineEdition oficiais, sem texto localizado.
Developer 2025 apresenta Enterprise Developer Edition, mas o bootstrap direto
de sqlservr exige MSSQL_PID=Developer; EnterpriseDeveloper foi recusado em SQL real.
Edicoes de provisionamento continuam
Standard, Enterprise (CAL legado) e Developer, sem aceitar preview ou major 15.
Standby exige mesma major; clone/PITR nao permitem downgrade.

Novo alvo gerenciado nao concede sysadmin, CONTROL SERVER ou IMPERSONATE sa ao
operador. Recebe dbcreator, visibilidade/DMVs e SELECT limitado ao historico msdb.
Ownership estrangeiro do FULL e corrigido por procedimento assinado em master:
somente login operador e restoreId fixos, um unico banco pitr_<restoreId>, estado
ONLINE, ultimo backupset FULL/LOG nativo esperado e arquivos no namespace exclusivo.
NORECOVERY nao aceita ALTER AUTHORIZATION (SQL 927): o runtime exige owner_sid
estabelecido pelo RESTORE no login operador, sem tentar abrir o banco. STANDBY
read-only tambem nao aceita a alteracao (SQL 3906); o modulo apenas valida ownership
de servidor e le metadados/contagens sob assinatura. Apos RECOVERY/promocao, normaliza
ownership de dbo antes de validar abertura normal pelo operador. GUID do namespace
e convertido para minusculas antes da comparacao binaria dos caminhos.
A assinatura agrega CONTROL SERVER somente ao token de execucao desse modulo,
via login de certificado nao autenticavel, nunca ao operador. Nao usa EXECUTE AS
sa: retorno, erro e cancelamento nao deixam contexto de sessao elevado. A
chave privada do certificado e removida depois da assinatura. Operador nao pode
alterar/reassinar o modulo. Runtime verifica owner_sid, arquivos e historico antes
de prosseguir. Credencial administrativa inicial nao e persistida pela API.

Requer nova imagem aprovada com io.dunckops.sqlserver-flow-protocol=2 e
io.dunckops.sqlserver-scoped-restore-owner=1. Gate comum do cliente recusa versao
antiga na aprovacao, capacidades e novos fluxos; inicializador tambem exige label
de ownership antes de criar recursos. Controle de atores existentes permanece
disponivel. Build nao construiu
nem aprovou imagem. Alvos preexistentes nao sao migrados automaticamente e seus
grants devem ser reconciliados pelo operador, com autorizacao especifica.

Logs cobertos pelo FULL so entram em SkippedLogs depois de hash, HEADERONLY,
FILELISTONLY e VERIFYONLY reais. Nao contam como AppliedLogs. PITR sem log terminal
aplicavel e recusado no planejamento, antes de RESTORE FULL, em vez de anunciar
RECOVERY/STOPAT nao executados. Estados antigos que declaram prefixo coberto como
aplicado sao recusados na retomada, nao convertidos silenciosamente em evidencia.
STOPAT exige valor UTC exatamente representavel como SQL datetime na admissao;
UI sugere segundos inteiros e nao arredonda o corte solicitado.

Payloads cifrados expirados sao removidos antes do dispatch, mantendo estado,
codigo seguro e referencia de quota sem declarar efeitos desconhecidos como
compensados. Fronteiras native_dispatched e metadados de reconciliacao nao mudam.
GET /api/v1/companies/current/quota-usage expoe uso calculado pelo mesmo helper de
admissao, sob lock de quota e autorizacao admin. EngineJobView inclui alvo e
NativeDispatchedAtUtc para comprovar vinculo e ausencia de dispatch.

homolog-evidence/proof_faults.json esta INVALIDATED: script anterior usava rotas
incorretas, aceitava erros HTTP nao relacionados e continha PASS fixo. Script
corrigido exige fixture previamente enfileirada, endpoint de cancelamento real,
estado cancelled sem dispatch, alvo preservado e quota observada antes/depois.
Exclusao exige status observado do ator ativo, registro assinado e alvo vinculado
antes do endpoint especifico com 403/sqlserver.target_active_actor; demais
cenarios e TLS sem prova independente permanecem NOT_EXECUTED.

Revisao independente identificou sanitizacao incompleta nos scripts auxiliares:
chave de decifragem e payload cifrado literais em quatro scripts infra, chave de
agente no inspector e logins literais em Playwright. Esses casos foram corrigidos,
sem executar scripts. Helper comum requiredEnv recusa variaveis ausentes, nao
carrega .env e nao imprime valores. Referencias de banco/container/artefato nao
sao mais inferidas das fixtures SQL antigas nesses auxiliares.

Variaveis obrigatorias, sem fallback:
- SQLSERVER_HOMOLOG_ENCRYPTION_KEY: chave atual do contexto de laboratorio.
- SQLSERVER_HOMOLOG_ENCRYPTED_PARAMETERS: payload cifrado atual com username e
  password, no formato AES-256-GCM usado pelo contexto; nunca literal no script.
- SQLSERVER_HOMOLOG_WEB_USERNAME / SQLSERVER_HOMOLOG_WEB_PASSWORD: login do
  navegador nos quatro scripts Playwright; username corresponde ao email local.
- SQLSERVER_HOMOLOG_CONTAINER / SQLSERVER_HOMOLOG_SQL_QUERY: container autorizado
  e consulta SQL completa atual para run-sqlcmd/test-chain-restore, sem credenciais
  embutidas. Consulta pode
  restaurar/excluir dados; sua execucao exige autorizacao separada e nao e feita
  por validacao de sintaxe ou contracts:check.
- SQLSERVER_HOMOLOG_SQL_HOST / SQLSERVER_HOMOLOG_SQL_PORT /
  SQLSERVER_HOMOLOG_BACKUP_PATH: conexao e arquivo atuais de read-header.
- SQLSERVER_HOMOLOG_AGENT_URL / DOCKER_AGENT_API_KEY: URL base e chave atual do
  agente para coleta/inspecao, sem default-local-key.
- SQLSERVER_HOMOLOG_FLOW_PAYLOAD: JSON objeto com companyId e parameters atuais
  para transactionlogs; credenciais vem exclusivamente do payload cifrado.
- SQLSERVER_HOMOLOG_ARTIFACT_SELECTOR: JSON seletor atual para inspector,
  incluindo referencias, identidades e hashes esperados pelo protocolo.
- HOMOLOG_MYSQL_USERNAME / HOMOLOG_MYSQL_PASSWORD / HOMOLOG_MARIADB_USERNAME /
  HOMOLOG_MARIADB_PASSWORD / HOMOLOG_INVALID_DB_PASSWORD: fixtures atuais do
  diagnostico multi-engine; senha negativa deve diferir da senha MySQL valida.
- HOMOLOG_LOGIN_EMAIL / HOMOLOG_LOGIN_PASSWORD / HOMOLOG_SQL_IMPORT_PASSWORD /
  HOMOLOG_SQL_SOURCE_PASSWORD: nomes anteriores dos scripts API/import/FULL,
  mantidos explicitos; nao sao fallback dos nomes SQLSERVER_HOMOLOG_*.

Vars do laboratorio nao alteram TTL de credenciais do backend nem substituem
autorizacao, licenciamento ou consentimento por operacao. Valores cifrados antigos
podem representar credenciais expiradas/rotacionadas e nao devem ser reutilizados.
Chaves e senhas historicamente expostas precisam de rotacao pelo operador;
remover literal nao revoga credencial nem apaga copias em historico/artefatos.
Nenhuma credencial ou arquivo PFX existente foi rotacionado/removido/ignorado.
Checker agora reporta PFX/P12 versionavel por nome, sem ler material binario, e
sniffa literais de chave, payload, credencial e browser sem excecao para labs.
Varredura focada e checker nao comprovam ausencia completa de segredos: evidencias,
arquivos ignorados, capturas de tela e material criptografico exigem revisao propria.
Os auxiliares SQL conservam opcoes TLS legadas; sanitizacao nao homologa TLS.

Recibo de validacao desta sanitizacao: node --check passou nos 13 arquivos JS/MJS
alterados, sem executar cenarios. pnpm contracts:check passou com --no-restore,
-m:1, BaseOutputPath temporario e UseAppHost=false; backend sem avisos/erros,
frontend com avisos preexistentes de anotacao SignalR. Argumentos MSBuild foram
passados como strings para evitar separacao de -m:1 pelo shell. git diff --check
passou com avisos de conversao LF/CRLF. pnpm secrets:check permanece bloqueado
somente por homolog-evidence/localhost.pfx, untracked e fora do staging; arquivo
preservado, nao lido e nao adicionado ao .gitignore. Varredura rg -l focada nao
encontrou os literais de chave/payload/header de agente corrigidos nos scripts.

Esta revisao nao executou SQL, scripts de homologacao, containers, EULA ou release.
Build/lint/sintaxe nao homologam permissoes SQL, ownership em NORECOVERY, PITR ou
TLS real. Esses fluxos ainda exigem homologacao licenciada em 16/17; nenhum
indicador productionReady/implementationVerified foi promovido por esta revisao.
Ownership NORECOVERY do modulo assinado continua nao verificado em SQL real,
nao um defeito confirmado. CONTROL SERVER permanece somente no login de
certificado nao autenticavel e no token do modulo restrito. Nao foi reduzido para
ALTER ANY DATABASE + IMPERSONATE do operador: essa combinacao nao comprova TAKE
OWNERSHIP sobre banco ainda inexistente na inicializacao. Reducao adicional deve
ser avaliada com evidencia nativa autorizada, sem conceder esses direitos ao
operador nem anunciar homologacao por inspecao estatica.

Verificacao de implementacao em 2026-10-07: contracts/secrets e builds backend,
agente e cliente passaram; cliente Linux amd64 protocolo 2 foi construido. Compose
local/producao/overlay avancado e sintaxe Bash passaram; bundle foi planejado com
DryRun, sem download/execucao de servidor. Cliente descartavel, rede none e sem
entrada, rejeitou inicializacao com codigo sanitizado antes de TDS. Nenhuma EULA
foi aceita e nenhum servidor SQL foi iniciado. Graphify nao foi regenerado porque
Python/py nao estao disponiveis nesta maquina. Nenhum teste automatizado foi alterado.

Fluxos gerenciados estao implementados; esta documentacao nao converte builds em
evidencia SQL. Escopo implementado e standalone SQL 2022/2025 Linux amd64, uma empresa por
perfil, modelos/layouts nativos restritos e alvo dedicado. Windows/SQL 2019/Express/
Web/Evaluation, BACPAC e transferencia automatica de chaves TDE nao sao anunciados.

Entrega habilita caminho condicional implementado, nao prontidao de producao.
Nenhum servidor SQL/EULA foi executado nesta entrega. Homologacao exige ambiente
licenciado: TLS real, grants nativos, bootstrap/restart, backup/restauracao com dados,
PITR/standby, cancelamento e distribuicao offline. Indicadores `implementationVerified`,
`productionReady` e `seededDataVerified` permanecem false.

Verificacao desta entrega: contracts/secrets, builds agente/cliente Linux e Compose
local/producao passaram. Smoke inline descartavel do CLIENTE, rede none: perfil
sintetico valido passou com trust .NET ativo via SSL_CERT_FILE; SAN errado, pin CA
errado e pin de assinatura errado foram recusados (exits 13/14/15). Containers
removidos; nenhum certificado/chave real lido ou arquivo de teste criado. Esses
resultados validam preflight criptografico, nao TDS, grants, backup ou restore SQL.

## Homologacao autorizada em 2026-10-09

Esta etapa substitui os bloqueios de laboratorio das revisoes anteriores acima,
sem transformar Developer em suporte ou licenciamento de producao. Usuario aceitou
explicitamente EULA Microsoft para containers Developer 2022/2025 descartaveis e
autorizou manutencao/rotacao/reinicio dos servicos pertencentes ao laboratorio.

Runtime aprovado por ID imutavel e instalado somente neste laboratorio:
`sha256:9a5ff60f4afe2fe31f4a9ab94d69b14467aaadba4a3489281208733465bcf220`.
API e Worker Release atuais executam com agente atualizado. Imagem possui os gates
flow=2, managed=2, scoped-restore-owner=1, native-import=1 e bootstrap-cleanup=1.

Pipeline autenticado API/Worker/agente/SQL passou em major 16 e 17: FULL assinado,
clone com SHA-256 igual ao snapshot e escrita posterior ausente, PITR STOPAT UTC com
marcador anterior presente/posterior ausente, standby ONLINE/read-only, controle
status/stop e promocao com dados preservados. Matriz adicional usa proprietario SQL
exclusivo em cada origem, com SID diferente de sa e ausente no alvo. Modulo rejeitou
restoreId incorreto sem elevar sessao; operadores permaneceram 0/0/0 para sysadmin,
CONTROL SERVER e IMPERSONATE sa. Playwright executou criacao e clone reais pelas
interfaces 2022/2025, validou consentimentos novos e layout mobile sem overflow.

Seis clones retidos foram inspecionados nativamente: nenhum tinha sysadmin ou
CONTROL SERVER. Receberam modulo atual assinado, chave privada removida e credenciais
novas, preservando volumes, dados e estados assinados antigos. Permanecem parados
e em reconciliation_required; nao foram promovidos, refeitos ou declarados
retroativamente concluidos. Recursos cujo container original nao existe nao
receberam migracao ficticia. Atores antigos parados nao foram reiniciados.

sa das duas origens e dos seis clones retidos foi rotacionado com o modo nativo
`--setup --reset-sa-password`, validado primeiro em copia fria, nunca --force-setup.
GUID/fork, metadados e hashes SHA-256 dos dados foram comparados. Operadores das
origens/alvos, web admin/sessoes, agente, JWT, PostgreSQL e MinIO tambem foram
rotacionados. Chave Encryption__MasterKey mudou somente apos recifrar 51 valores
existentes em transacao; outros campos cifrados/MFA estavam vazios. Valores novos
continuam cifrados com a chave atual. Arquivos .env locais foram coordenados; nao
foram impressos ou versionados. Credenciais antigas de MinIO/PostgreSQL e operadores
foram recusadas por autenticacao real.

PFX localhost original permanece em quarentena privada fora do repositorio; novo
certificado/chave/PFX/senha e CA publica ficam no diretorio privado de homologacao.
Proxy escuta somente 127.0.0.1:9003. Importador nao aceita mais qualquer certificado
loopback: `SQLSERVER_NATIVE_IMPORT_CA_FILE` opcional referencia CA publica explicita,
com chain/hostname/EKU validados e downloads de certificado desativados. Ausencia
mantem TLS normal do sistema. Oracle .NET do factory real aceitou CA correta e
recusou CA estrangeira/host incorreto, sem alterar trust store do Windows.

Evidencias atuais: `homolog-evidence/maintenance-status.md`, `api-sql-16-foreign.json`,
`api-sql-17-foreign.json`, `current-ui-proof.json`, `sa-rotation-sources.json`,
`sa-rotation-targets.json`, `retained-module-upgrade.json`, `rotation-verification.json`
e `native-import-tls-proof.json`. Arquivos e imagens de revisoes anteriores conservam
seu significado historico; nao representam os resultados atuais automaticamente.
`productionReady`, `implementationVerified` e `seededDataVerified` do produto seguem
false. Nenhum commit, release, acesso a producao ou licenca nova foi criado.
