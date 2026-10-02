# MagnusBilling 8 — customizações Comunic

Este repositório é o código-fonte do MagnusBilling 8 com as customizações da Comunic.
Com ele dá para montar um servidor novo do zero (MB8 oficial + customizações, banco vazio)
e depois importar o banco da produção atual (MB7 ou MB8).

## O que foi customizado

| Funcionalidade | Onde aparece |
|---|---|
| **Tipo de plano** (Plano de Minutos, de Franquia, Ilimitado) e **Valor recorrente** no cadastro do usuário | Clientes > Usuários > aba Geral (e colunas opcionais na lista) |
| **Relatório de Recarga / Consumo por Plano**: cliente, tipo de plano, valor recorrente, saldo na recarga, recarga, valor a pagar, situação; totais; exportar CSV | Relatórios > Consumo por Plano (somente admin) |
| **Recarga mensal automática** do valor recorrente: backup às 00:00 e recarga às 00:30 (horário de Brasília) no dia configurado, com marca `[RC-AAAAMM]` e e-mails para o financeiro | Faturamento > Recargas; e-mails; `protected/runtime/recurring_credit/` |
| **Configurações novas**: `finance_email`, `recurring_credit_groups` (padrão 3), `recurring_credit_day` (padrão 20), `comunic_alert_email` (alertas técnicos) | Configurações > Configuração |
| Traduções pt_BR das telas novas | `resources/locale` |

Regras do cálculo: [docs/PRODUCAO-recarga-recorrente.md](docs/PRODUCAO-recarga-recorrente.md).

## Arquivos

**Nenhum arquivo oficial do MagnusBilling é alterado.** Tudo o que é nosso fica em arquivos
que não existem no pacote oficial, então a atualização oficial não os sobrescreve:

| Arquivo | O que faz |
|---|---|
| `protected/config/overrides.php` | liga o mecanismo **oficial** de overrides do MagnusBilling (`BaseController::getOverrideModel`) para os módulos `user` e `configuration` |
| `protected/models/overrides/UserOR.php` | estende o model `User` só no cadastro de usuários: valida `plan_type` e `recurring_value`; **cliente e revenda não veem nem alteram** esses campos |
| `protected/models/overrides/ConfigurationOR.php` | estende `Configuration`: valida `finance_email`, `comunic_alert_email`, `recurring_credit_groups` e `recurring_credit_day` |
| `protected/models/PlanConsumption.php` | regra do relatório (`cycleRows`) |
| `protected/controllers/PlanConsumptionController.php` | tela e exportação CSV (somente admin) |
| `protected/components/FinanceReportMailer.php` | e-mail com anexos (financeiro e alertas) |
| `protected/commands/RecurringCreditCommand.php` | rotina `backup` / recarga / `dryrun` |
| `protected/commands/PlanConsumptionSetupCommand.php` | cria colunas, tabela `pkg_recurring_credit`, menu, configurações e cron (idempotente) |
| `protected/commands/ComunicAlertCommand.php` | envia os alertas técnicos por e-mail |
| `custom/mb8-custom.js` | telas (carregado pelo `index.html` depois do `app.js` pré-compilado; **não recompila o Sencha**) |
| `comunic/` | instalação, importação, aplicação, vigia, atualização com conferência e testes |

Lista exata do que é copiado para o servidor: `comunic/MANIFEST`.

Só 3 arquivos oficiais recebem um acréscimo (sem trocar nada do que existe), e por isso
voltam ao original a cada atualização oficial: o `index.html` (uma linha `<script>` para o
`custom/mb8-custom.js`) e as duas traduções pt_BR (bloco `// mb8-custom:`). O **vigia** refaz
esses acréscimos sozinho (ver "Proteções" abaixo).

O instalador oficial não usa o código deste repositório: ele baixa o pacote pronto
`MagnusBilling8-current.tar.gz` do magnusbilling.org. O `comunic/aplicar.sh` copia por cima só
os arquivos do `MANIFEST`. Os arquivos oficiais que estão no repositório (incluindo
`User.php`, `UserController.php`, `Configuration.php`, `permissions.php`) são os originais da
8.0.0.16 (`comunic/originais.sha256`); a versão antiga (v11) alterava esses 4, e o
`aplicar.sh` devolve o original quando encontra a versão v11 no servidor.

## 1. Servidor novo (instalação limpa)

Debian 11, 12 ou 13 mínimo (só "Servidor SSH" e "Utilitários standard"), como root:

```bash
apt update && apt install -y git
git clone git@github.com:77uccena/mb8.git /opt/mb8-comunic
cd /opt/mb8-comunic
bash comunic/instalar.sh --fuso America/Sao_Paulo   # use o MESMO fuso da produção atual
reboot
```

O `instalar.sh` roda o instalador oficial (`script/install.sh`, 30 a 60 min), aplica as
customizações e **não** reinicia sozinho. No fim o painel abre com `root` / `magnus` e banco vazio.

> Repositório privado (`77uccena/mb8`): o servidor clona com uma **deploy key** somente leitura.
> Uma vez por servidor, como root:
> ```bash
> ssh-keygen -t ed25519 -N "" -C "mb8-$(hostname)" -f /root/.ssh/id_ed25519
> cat /root/.ssh/id_ed25519.pub
> ```
> No GitHub: repositório > Settings > Deploy keys > Add deploy key, cole a chave e **não**
> marque "Allow write access". Depois: `ssh -T git@github.com` (responda `yes`).
> Não clone dentro de `/var/www/html/mbilling`.

## 2. Importar o banco da produção (MB7 ou MB8)

No servidor **antigo**, com os serviços parados (congela os dados):

```bash
systemctl stop asterisk apache2 cron
mysqldump --single-transaction --quick --triggers --routines --hex-blob \
  --default-character-set=utf8 mbilling | gzip > /root/mbilling-producao.sql.gz
sha256sum /root/mbilling-producao.sql.gz
```

> Não use o menu Backup nem `cron.php Backup` para migrar: eles deixam de fora o histórico de CDR.

Copie para o servidor novo e:

```bash
cd /opt/mb8-comunic
bash comunic/importar-banco.sh /root/mbilling-producao.sql.gz           # definitivo
bash comunic/importar-banco.sh /root/mbilling-producao.sql.gz --teste   # ensaio: nada sai da máquina
```

O script faz backup do banco atual, importa, roda `UpdateMysql` (converte MB7 → MB8,
`sip` → `pjsip`), roda `PlanConsumptionSetup`, gera a configuração PJSIP e religa os serviços.
Faça **pelo menos um ensaio** com `--teste` antes da virada.

Depois da importação (fora do banco, copiar à parte): gravações (`/var/spool/asterisk/monitor`),
músicas de espera, áudios de URA, logos, certificados e scripts próprios. O módulo pago
`app_mbilling` do MB7 **não** deve ser copiado (pedir a versão MB8 à MagnusSolution).
Revise troncos e contas: `asterisk -rx "pjsip show endpoints"` e `"pjsip show registrations"`.

## 3. Colocar a recarga em operação

```bash
cd /opt/mb8-comunic
bash comunic/importar-planos.sh --modelo         # gera /root/planos-clientes.csv para o financeiro
bash comunic/importar-planos.sh planos-clientes.csv            # prévia
bash comunic/importar-planos.sh planos-clientes.csv --aplicar  # grava (com backup)
bash comunic/conferir-producao.sh                # somente leitura; resolver os AVISOS
bash comunic/conferir-producao.sh --previa       # véspera do dia da recarga
```

Painel: Configurações > Configuração (E-mail do financeiro, Grupos e Dia da recarga) e
Configurações > SMTP. Teste sem gravar nada: `php /var/www/html/mbilling/cron.php RecurringCredit dryrun`.

## 4. Proteções contra a atualização oficial

| Proteção | Como funciona |
|---|---|
| Atualização automática oficial (01:30) **desligada** | o `aplicar.sh` comenta a linha `update.sh` no crontab (`#COMUNIC-atualizacao-manual#`) |
| **Vigia** a cada 5 min (`comunic/vigia.sh`) | roda `saude.sh`; se faltar algo (ex.: alguém rodou a atualização oficial e o `index.html` voltou ao original), reaplica sozinho e manda e-mail. Não mexe no horário da recarga |
| **Conferência semanal** (segundas 07:10, Brasília) | `atualizar-mb8.sh --verificar`: baixa o pacote oficial numa pasta separada, confere a compatibilidade e manda e-mail quando sai versão nova. **Não aplica** |
| **Atualização com conferência** (`comunic/atualizar-mb8.sh`) | só aplica o pacote que passou na conferência; backup antes; teste completo depois |
| Janela da recarga | não atualiza de 2 dias antes até 1 dia depois do dia da recarga |

Os alertas vão para "E-mail de alertas técnicos" (Configurações > Configuração; vazio = Admin
Email), pelo SMTP do admin. Log: `/var/log/mb8-comunic.log`.

> **Não apague nem mova `/opt/mb8-comunic`**: o vigia e a conferência rodam de lá.

### O que a conferência (`comunic/compat.sh`) verifica no pacote novo

- o `BaseController` continua com o mecanismo de overrides;
- `User` e `Configuration` continuam com os métodos que estendemos;
- o pacote não traz nenhum arquivo com o mesmo nome dos nossos;
- a migração oficial do banco não usa nossos nomes (`plan_type`, `recurring_value`, `pkg_recurring_credit`, configurações, menu);
- o `index.html` e as traduções continuam no formato onde fazemos o acréscimo;
- o `app.js` de cada tema ainda tem todas as classes que o `mb8-custom.js` usa;
- se os arquivos oficiais de que dependemos mudaram desde a última versão que funcionou (base validada, gravada pelo `aplicar.sh` em `/var/lib/mb8-comunic/`).

Veredito: **COMPATÍVEL** (pode aplicar), **REVISAR** (dependências mudaram: comparar antes)
ou **INCOMPATÍVEL** (não aplicar; ajustar o repositório).

### Atualizar o MagnusBilling

```bash
cd /opt/mb8-comunic && git pull
bash comunic/atualizar-mb8.sh --verificar   # só confere e mostra o relatório
bash comunic/atualizar-mb8.sh               # confere, pergunta e aplica
```

Aplicar = backup (banco + arquivos) → extrai **o mesmo pacote conferido** → `updateCommand.sh`
oficial (migração do banco) → `aplicar.sh` → `saude.sh --completo`. Se a conferência final
falhar, nada é desfeito sozinho: o relatório e o e-mail trazem os 3 comandos para voltar.

Se quiser que atualizações **100% compatíveis** entrem sozinhas, troque no `crontab -e` a linha
`# comunic-verificar` de `--verificar` para `--auto` (quando houver REVISAR ou INCOMPATÍVEL, ele
não aplica e manda e-mail). O `aplicar.sh` mantém a escolha.

### Mudou só a customização (novo commit)

```bash
cd /opt/mb8-comunic && git pull && bash comunic/aplicar.sh
```

O que está aplicado no servidor fica em `/var/www/html/mbilling/custom/APLICADO.txt`.
Conferência a qualquer momento: `bash comunic/saude.sh --completo` e `bash comunic/compat.sh`.

### Quando der REVISAR ou INCOMPATÍVEL

1. ver no relatório o que mudou (ex.: `diff -u /var/www/html/mbilling/protected/models/User.php /var/lib/mb8-comunic/novo/arvore/protected/models/User.php`);
2. ajustar no repositório só o necessário (normalmente `UserOR.php`, `ConfigurationOR.php` ou o `mb8-custom.js`), testar numa VM com `--teste`;
3. commit, `git pull` no servidor e `bash comunic/atualizar-mb8.sh` (no REVISAR ele pede para digitar `REVISADO`).

## 5. Testes (somente VM)

`comunic/testes/` — **alteram clientes e saldos**. Só rodam sem troncos ativos e pedindo o
nome da máquina. Use numa VM com a base importada via `importar-banco.sh ... --teste`.

| Script | O que faz |
|---|---|
| `testar-cenarios.sh` | 52 verificações automáticas (precisa do Mailpit) |
| `testar-100-cenarios.sh` | 100 cenários da regra do financeiro |
| `simular-base-vm.sh` | sorteia plano/saldo para todos os clientes e confere a rotina um a um |

Montagem da VM no Hyper-V e Mailpit: [docs/VM-HyperV-teste.md](docs/VM-HyperV-teste.md).

## Desfazer

- Recargas de um mês: ver "Se algo sair errado" em [docs/PRODUCAO-recarga-recorrente.md](docs/PRODUCAO-recarga-recorrente.md).
- Arquivos: cada `aplicar.sh` guarda o que substituiu em `/root/mb8-custom-backup-DATA/` (ficam os 10 mais recentes).
- Atualização oficial: `/root/mb8-antes-atualizacao-DATA/` (banco + arquivos + crontab).
- Desligar o vigia/conferência: comentar as linhas `# comunic-vigia` e `# comunic-verificar` no `crontab -e`.
- Suspender a rotina: comentar as 2 linhas `RecurringCredit` no `crontab -e`.
- SQL manual (se não puder rodar o `PlanConsumptionSetup`): `comunic/sql/plan_consumption_manual.sql`.
