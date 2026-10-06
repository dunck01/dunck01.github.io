# Snapshots fisicos locais experimentais

Implementados em desenvolvimento; **nao publicados como recurso de backup disponivel**.
Operacao manual de instancia inteira: copia e prepara todo o datadir, incluindo todos
os bancos. Nao e snapshot de um banco selecionado, backup agendado nem PITR.
`prepared` nao significa restore validado: **nenhuma garantia de protecao de producao
ou de recuperacao**. Mantenha backups independentes e ensaie recuperacao fora de producao.

## Prontidao e opt-in

- Docker Ops habilitado; API e agent com `PHYSICAL_SNAPSHOTS_ENABLED=true` (padrao `false`).
- `PHYSICAL_SNAPSHOT_TIMEOUT_MINUTES=60` por padrao; inteiro **1..120**, identico na API e agent.
- Ambas as imagens instaladas no Docker do agent. Nao ha download automatico pelo endpoint.
- Licenca autorizando a engine e usuario autenticado com papel admin ou superior na empresa.
- Espaco local para copia completa, prepare e metadados; TLS ativo em `127.0.0.1:3306` da origem.
- Usuario SQL com privilegios exigidos por XtraBackup/mariadb-backup para instancia inteira e locks.

Desenvolvimento, a partir do repositorio:

```bash
docker compose --env-file .env.example -f docker-compose.yml -f docker-compose.local.yml --profile tools build mysql-snapshot-runtime mariadb-snapshot-runtime
```

Tags locais: `dunckops-mysql-snapshot-runtime:development` e
`dunckops-mariadb-snapshot-runtime:development`. O agent recebe respectivamente
`MYSQL_SNAPSHOT_RUNTIME_IMAGE` e `MARIADB_SNAPSHOT_RUNTIME_IMAGE`.
Em producao, variaveis vazias usam `ghcr.io/${REGISTRY_OWNER}/dunckops-mysql-snapshot-runtime:${DUNCKOPS_VERSION}`
e `ghcr.io/${REGISTRY_OWNER}/dunckops-mariadb-snapshot-runtime:${DUNCKOPS_VERSION}`.
Confirme publicacao das duas imagens na versao escolhida **antes de ativar**.
Install/update baixam essas ferramentas multi-GB somente com opt-in explicito;
imagem ausente interrompe operacao com erro, sem declarar sucesso. Para desenvolvimento
sem release, construa localmente e configure as duas variaveis de imagem.
Override explicito nao vazio com imagem ja instalada e reutilizado sem pull.
Se imagem nao estiver instalada, install/update tentam pull somente do servico
da engine correspondente e falham com orientacao se indisponivel. Sem override,
imagens padrao de release sempre passam por pull para atualizar a versao selecionada.
Recrie API/agent ao mudar flags/configuracao; nao inicie servicos `tools` como servidores.
Bundle offline inclui ambas as imagens, mas mantem flag desativada.

## Autorizacao da origem

Somente operador com acesso Docker pode conceder labels. Isso autoriza leitura do
datadir completo: conceda somente a instancia explicitamente gerenciada e pertencente
a empresa selecionada. Nao rotule automaticamente containers descobertos.
Labels obrigatorias, com valor exato:

```yaml
# Fragmento no Compose DA ORIGEM, aplicado conscientemente pelo operador.
labels:
  pitr.managed: "true"
  pitr.company-id: "<UUID-CANONICO-DA-EMPRESA-SELF-HOSTED>"
volumes:
  - mysql-data:/var/lib/mysql
```

UUID deve usar formato canonico minusculo `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`,
igual ao companyId do contexto autenticado, nao UUID de outra empresa/comercial.
`DOCKER_ALLOW_ANY_CONTAINER=true` nao dispensa essas labels.
Labels de container existente exigem recriacao: preserve volume e planeje parada.
Nao execute recriacao/relabel indiscriminado nem use `docker compose down -v`.

Origem deve ser container standalone em execucao, sem pausa/restart, com **somente**
volume nomeado local padrao, gravavel, montado em `/var/lib/mysql`, driver `local`
sem opcoes/subpaths. Bind de host, volumes extras/config mounts, tmpfs, paths externos,
`--datadir`/`--defaults*`, Swarm/Kubernetes e network namespace compartilhado nao suportados.

## Engines e limites

MySQL Community 8.4.x com XtraBackup 8.4.0-7; MariaDB oficial **11.4.13** com
mariadb-backup 11.4.13. Exige binlog ativo, paths locais no datadir e TLS.
Outras versoes/forks, Galera, tablespaces/logs externos, symlinks de dados,
criptografia nativa de tablespaces/redo/undo e engines de armazenamento nao reconhecidas
sao rejeitados. Nao pressupor suporte a replicacao/cluster ou configuracoes customizadas.

## Requisicao manual

Solicite janela autorizada para locks breves de backup/DDL e possivel impacto no servico.
`allowBriefLocks=true` e consentimento explicito por requisicao, nao promessa de ausencia
de bloqueios. A chamada e sincrona; configure cliente/proxy para timeout adequado.
Exemplo com placeholders, sem credenciais reais:

```bash
curl --fail-with-body --request POST 'https://<HOST-DA-API>/api/v1/physical-snapshots' \
  --header 'Authorization: Bearer <TOKEN-DO-ADMIN-DA-EMPRESA>' \
  --header 'Content-Type: application/json' \
  --data '{"engine":"mysql","sourceContainer":"<CONTAINER-GERENCIADO>","username":"<USUARIO-SQL>","password":"<SENHA-SQL>","allowBriefLocks":true}'
```

Para MariaDB use `"engine":"mariadb"`. Nao envie companyId/snapshotId: API deriva
empresa autenticada e gera snapshotId. Nao coloque segredos reais no historico shell,
logs ou tickets; use entrada protegida para payload e token em operacao real.

Saida fica em `DUNCKOPS_LOCAL_BACKUP_VOLUME` (padrao `dunckops-local-backups`),
`/backups/physical-snapshots/<companyUUID-sem-hifens>/<snapshotUUID-sem-hifens>/`.
Use `relativePath` retornado, relativo a `/backups`; nao e path arbitrario do host.
Runtime cria diretorio proprio e publica artefatos/`manifest.json` apos prepare.
Datadir da origem e montado somente leitura; ferramenta pode executar comandos de
backup e locks no servidor. Prepare ocorre somente na copia. Nao envia S3/MinIO,
nao criptografa, nao restaura nem valida restore.
Manifest/checksums nao provam recuperabilidade. Proteja acesso local aos dados e gerencie
retencao manualmente; nao confundir esses artefatos com backups registrados no produto.

Limites deste recorte: ate 10.000 artefatos e 8 MiB de manifesto/resposta. Excedentes
sao rejeitados antes da publicacao. Volume deve ter somente escritores confiaveis;
hashes e descritores nao isolam arquivos contra operador root que possa altera-los.
Cancelamento normal tenta SIGTERM e limpa staging. Queda do host, OOM/SIGKILL ou
cleanup inconclusivo podem deixar staging; nao ha exclusao automatica desses residuos.
Em timeout, verifique estado local antes de repetir: pode existir snapshot publicado
cuja resposta nao chegou ao cliente. Nunca remova diretorios sem confirmar identidade
e ausencia de execucao ativa.
