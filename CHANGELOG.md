# Changelog

This file records notable user-visible changes to the MagnusBilling 8 release
line. The project is under active development; release tags and database
migration instructions remain authoritative for deployment.

## Comunic 1.2 (2026-10-02)

- `custom/mb8-custom.js`: espera o login sem limite de tempo. Antes desistia depois de 2 minutos na tela de login,
  e as telas novas (campos do usuario e Consumo por Plano) nao apareciam ate recarregar a pagina.

- `PlanConsumptionSetup`: o menu Relatorios > Consumo por Plano passa a ser liberado para todos os grupos de
  administrador (Gestor, Suporte...), nao so o grupo 1 (na producao ninguem usa o grupo 1).

- Novo `comunic/gerar-pjsip.sh`: renomeia troncos com nome repetido (MB7 aceitava, PJSIP nao: "SIP name ... is used by
  trunks ..."), gera a configuracao PJSIP e recarrega o Asterisk. O `migrar-dados.sh` usa esse script e marca FALHA
  no relatorio se a configuracao nao for gerada.

- `migrar-dados.sh`: da ao usuario do MagnusBilling (`mbillingUser`) permissao no banco
  `mbilling_origem` antes do `UpdateMysql` (na Magalu dava "CDbConnection failed to open the DB connection").

- Novo `comunic/migrar-dados.sh`: migração **seletiva** de um dump do MB7/MB8 (clientes, SIP, DIDs,
  financeiro, tarifas, provedores Voxbeam/Algar/Datora/TIP/NVoip/Directcall com seus troncos,
  grupos e tarifas). Converte o dump numa base separada (`mbilling_origem`), faz backup antes,
  mantém os planos já preenchidos no MB8 e gera relatório (planos sem rota, SIP sem grupo, não migrado).
  Opções: `--somente-ativos`, `--zerar-saldo`, `--zerar-grupos`, `--sem-registro`, `--manter-troncos`,
  `--com-cdr`, `--sem-configuracoes`, `--provedores`, `--teste`.
- `docs/ROTEIRO-MAGALU.md` reescrito para o plano outubro (só comunic ativo) / 20 de novembro (virada).

## Comunic 1.1.2 (2026-10-01)

- `atualizar-mb8.sh --verificar`: ignora `script/`, `doc/`, `assets/` e `tmp/` do pacote (o instalador
  oficial apaga essas pastas), para reconhecer "Nenhuma versao nova" numa instalacao real.

## Comunic 1.1.1 (2026-10-01)

- `compat.sh`: falta de classe no `app.js` so e ERRO nos temas que podem ser escolhidos no painel
  (e no tema atual). Temas antigos como `red-classic` viram INFO (apareceu na instalacao da VM).

## Comunic 1.1 (2026-10-01)

Proteção contra as atualizações oficiais do MagnusBilling.

- **Nenhum arquivo oficial alterado**: `User.php`, `UserController.php`, `Configuration.php`
  e `permissions.php` voltaram ao original; as mudanças entram pelo mecanismo oficial de
  overrides (`protected/config/overrides.php`, `protected/models/overrides/UserOR.php`,
  `ConfigurationOR.php`). Cliente e revenda não veem nem alteram tipo de plano e valor
  recorrente. O `aplicar.sh` devolve o original onde encontrar a versão v11.
- `comunic/vigia.sh` (a cada 5 min): refaz `index.html`/traduções/arquivos se sumirem e avisa por e-mail.
- `comunic/atualizar-mb8.sh`: `--verificar` (segundas 07:10, só avisa), interativo e `--auto`;
  aplica somente o pacote conferido, bloqueia perto do dia da recarga e testa no fim.
- `comunic/compat.sh` (conferência do pacote novo) e `comunic/saude.sh` (conferência da instalação).
- Configuração `comunic_alert_email` e comando `ComunicAlert` para os alertas técnicos.
- Testado num MagnusBilling real (código oficial 8.0.0.15 + migração real para 8.0.0.16):
  cadastro por admin/cliente/revenda via HTTP, configurações, relatório, `dryrun`,
  vigia e 7 cenários de pacote (igual, compatível, dependência alterada, sem overrides,
  arquivo em conflito, frontend sem classe, banco em conflito).

## Comunic 1.0 (2026-10-01)

Customizações Comunic integradas ao código-fonte (antes distribuídas como pacote
`mb8-custom-v11.tar.gz`). Base oficial: MagnusBilling 8.0.0.16.

- Tipo de plano e valor recorrente no cadastro do usuário (`pkg_user.plan_type`, `recurring_value`).
- Relatórios > Consumo por Plano (Relatório de Recarga) com exportação CSV.
- Rotina mensal `RecurringCredit` (00:00 backup / 00:30 recarga, horário de Brasília) e
  e-mails ao financeiro; tabela `pkg_recurring_credit`.
- Configurações `finance_email`, `recurring_credit_groups`, `recurring_credit_day`.
- `comunic/instalar.sh` (servidor novo), `comunic/importar-banco.sh` (dump MB7/MB8),
  `comunic/aplicar.sh`, `comunic/atualizar-mb8.sh` (atualização manual; a automática
  das 01:30 fica desligada), testes em `comunic/testes/`.

## Unreleased

### Documentation

- Reworked the repository introduction, installation, migration, development,
  architecture, support, security, and contribution guidance.
- Added the project mission, scope, engineering priorities, and roadmap.
- Corrected the repository license description to LGPL-3.0.

## MagnusBilling 8

### Changed

- Moved the supported telephony baseline to Asterisk 20.
- Replaced `chan_sip` with PJSIP for new installations.
- Added a side-by-side MagnusBilling 7 to 8 migration path.

For detailed version 8 behavior, see
[What's new in MB8](wiki/en/whats_new_mb8.rst). For database-specific changes,
review the update command and migration guidance before deployment.
