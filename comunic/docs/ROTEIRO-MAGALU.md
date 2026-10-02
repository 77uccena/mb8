# Roteiro — MB8 Comunic na Magalu (outubro/novembro de 2026)

Plano:

1. Pegar as informações do MB7 e aplicar no MB8 (só o que é pertinente — `migrar-dados.sh`).
2. Zerar o saldo dos clientes.
3. Preencher os planos (tipo de plano e valor recorrente) de todos os clientes, **manualmente no painel**.
4. Deixar **todos os clientes inativos**, menos o cliente **comunic**.
5. Configurar o servidor para fazer e receber chamadas (IP liberado nas operadoras).
6. Validar tudo com o cliente comunic e as 9 contas SIP dele (1 número de cada operadora).
7. Usar até o dia 20/10. Se a recarga do dia 20 rodar certo → em **20/11** ativar todos os clientes, troncos e afins.

O que é migrado do MB7:

| Bloco | O que vem |
|---|---|
| CLIENTES | usuários (com grupos e permissões), contas SIP |
| DIDs | DIDs, destinos de DID, uso e histórico |
| FINANCEIRO | recargas, métodos de pagamento, vouchers, boletos, recargas de provedores |
| TARIFAS | planos, tarifas, prefixos, tarifas de revenda e por usuário |
| ROTAS | provedores Voxbeam, Algar Telecom, Datora Telecom, TIP, NVoip, Directcall; só os troncos deles; só os grupos de tronco que usam esses troncos; só as tarifas desses provedores |
| AJUSTES | Configurações (menos a versão), SMTP e modelos de e-mail |

O resto (CDRs, outros provedores/troncos, servidores, etc.) **não vem** e aparece no relatório final.

> **Atenção:** o hostname da Magalu também é `mb8`, igual ao da VM. Antes de qualquer
> comando, confira o IP (`hostname -I`). O `migrar-dados.sh` pede para digitar o nome da máquina.

## 1. Instalar o MB8 limpo na Magalu

1. **Snapshot** no painel da Magalu (e, se já houver algo instalado, backup do banco).
2. Deploy key própria (como root):
   ```bash
   ssh-keygen -t ed25519 -N "" -C "mb8-magalu" -f /root/.ssh/id_ed25519
   cat /root/.ssh/id_ed25519.pub
   ```
   GitHub: `77uccena/mb8` > Settings > Deploy keys > Add deploy key, título "Magalu produção",
   **sem** "Allow write access". Depois `ssh -T git@github.com` deve responder "Hi 77uccena/mb8!".
3. Instalar (30 a 60 min):
   ```bash
   apt update && apt install -y git
   git clone git@github.com:77uccena/mb8.git /opt/mb8-comunic
   cd /opt/mb8-comunic
   bash comunic/instalar.sh --fuso America/Sao_Paulo   # o MESMO fuso do MB7 (timedatectl no MB7)
   reboot
   ```
4. Conferir: `bash comunic/saude.sh --completo` → **0 falha(s)**.

## 2. Trazer os dados do MB7

No **MB7** (sem parar nada — em outubro ele continua em produção):

```bash
mysqldump --single-transaction --quick --triggers --routines --hex-blob \
  --default-character-set=utf8 mbilling | gzip > /root/mb7-$(date +%Y%m%d).sql.gz
```

Copie para `/root` da Magalu (MobaXterm) e rode:

```bash
cd /opt/mb8-comunic
bash comunic/migrar-dados.sh /root/mb7-AAAAMMDD.sql.gz \
  --somente-ativos comunic --zerar-grupos 3,6 --sem-registro
```

| Opção | Por quê |
|---|---|
| `--somente-ativos comunic` | todos os clientes e revendas ficam **inativos**, menos o comunic |
| `--zerar-grupos 3,6` | saldo 0 nos grupos 3 (Clientes Comunic.se) e 6 (Clientes Revenda), com ajuste `[ZERA-AAAAMM]` em Faturamento > Recargas. Para zerar só o grupo 3, troque por `--zerar-saldo` |
| `--sem-registro` | desliga os troncos que **registram** na operadora (18 da Datora). Com o MB7 no ar, dois servidores registrando a mesma conta disputam as chamadas recebidas |

Se algum tronco que registra for **só de teste da Comunic**, mantenha-o ligado com
`--manter-troncos TRONCO1,TRONCO2` (nome do tronco, como no painel).

O script faz backup antes (`/root/mb8-antes-migracao-DATA/`), converte o MB7 para MB8 numa base
separada (`mbilling_origem`), copia, e no fim mostra o relatório e roda o `saude.sh`.
Pode ser rodado de novo: **o tipo de plano e o valor recorrente já preenchidos no MB8 são mantidos**.

Leia o relatório final (`/root/mb8-antes-migracao-DATA/relatorio-migracao.txt`), principalmente:

- **Planos sem rota:** planos com tarifa apontando para grupo de tronco que não veio.
- **Contas SIP sem grupo de tronco:** contas que usavam um grupo que não veio.
- **Não migrado:** o que ficou de fora.

Depois, no painel (Ctrl+F5):

- Configurações > Configuração: **Grupos da recarga = 3**, Dia = 20, e-mail do financeiro, e-mail de alertas.
- Configurações > SMTP: e-mail de teste.
- Grupo 3 com o nome **Clientes Comunic.se**.

## 3. Planos de todos os clientes

Preencha no painel (Clientes > Usuários) **tipo de plano** e **valor recorrente** de todos.

- Clientes inativos **nunca** são recarregados, então pode preencher todos já em outubro.
- **Cuidado:** cliente com plano ativado entre os dias 20 e 31 é recarregado na madrugada seguinte.
- `bash comunic/conferir-producao.sh` mostra quem ainda está sem plano.

## 4. Fazer e receber chamadas

1. Nas operadoras, liberar o **IP da Magalu** (`hostname -I` / IP público):
   Voxbeam, Algar, Datora, TIP, NVoip, Directcall.
2. Firewall da Magalu: SIP 5060 (UDP/TCP) e RTP 10000–20000 UDP liberados para os IPs das operadoras;
   SIP dos clientes (comunic) liberado.
3. Conferir no servidor:
   ```bash
   asterisk -rx "pjsip show endpoints"
   asterisk -rx "pjsip show registrations"
   asterisk -rx "pjsip show contacts"
   ```
4. Apontar os números de teste da Comunic (1 por operadora) para o IP da Magalu.

## 5. Validar com o cliente comunic (até 20/10)

Para **cada uma das 9 contas SIP** do comunic (comunic-algar-0258, comunic-algar-4009,
comunic-dc-4000, comunic-9939, comunic-3060-tip, comunic-teste, comunic-lab, comunic-9696,
comunic-voxbeam):

| Teste | Conferir |
|---|---|
| Ligação sai para fixo e celular | áudio nos dois sentidos, CDR com a tarifa certa, saldo descontado |
| Ligação entra pelo número da operadora | toca na conta SIP certa (destino do DID) |
| Ligação de mais de 1 minuto | sem queda aos 30 s / 32 s (NAT/RTP) |
| Chamada não atendida / ocupado | CDR em "chamadas com falha" |

Recarga de 20/10 (só o comunic tem plano e está ativo):

1. Dia 19: `php /var/www/html/mbilling/cron.php RecurringCredit dryrun` → só o comunic aparece.
2. Dia 20 de manhã: e-mail com os 2 anexos; Faturamento > Recargas com `[RC-202610]`;
   Relatórios > Consumo por Plano, ciclo 10/2026.

## 6. Novembro — virada (20/11)

1. Até 19/11: planos de todos preenchidos; `conferir-producao.sh` sem "cliente sem plano"; snapshot.
2. **Congelar o MB7** e tirar dump novo:
   ```bash
   systemctl stop asterisk apache2 cron
   mysqldump --single-transaction --quick --triggers --routines --hex-blob \
     --default-character-set=utf8 mbilling | gzip > /root/mb7-final.sql.gz
   ```
3. Na Magalu, migração final (traz o uso e as recargas de outubro/novembro do MB7; **planos mantidos**;
   ativos e troncos como estavam no MB7):
   ```bash
   bash comunic/migrar-dados.sh /root/mb7-final.sql.gz --zerar-grupos 3,6
   ```
   O financeiro passa a ser o do MB7: a recarga de **teste** de outubro feita no MB8 (`[RC-202610]`
   do comunic) e as ligações de teste somem. É esperado — eram testes.
4. Prévia: `php /var/www/html/mbilling/cron.php RecurringCredit dryrun` → recarga = valor recorrente.
5. Recarga na hora:
   ```bash
   php /var/www/html/mbilling/cron.php RecurringCredit backup
   php /var/www/html/mbilling/cron.php RecurringCredit
   ```
6. Apontar todos os números/DNS para a Magalu; conferir `pjsip show registrations` (agora os troncos
   que registram ficam ligados só aqui).
7. Conferir e-mail com anexos, `[RC-202611]` e Consumo por Plano ciclo 11/2026.

Se algo der errado: o backup de antes da migração está em `/root/mb8-antes-migracao-DATA/`
(`gunzip -c mbilling.sql.gz | mariadb mbilling`), e o MB7 continua parado, pronto para religar.
Recargas do mês: seção "Se algo sair errado" de `PRODUCAO-recarga-recorrente.md`.

Mudou algo na customização? Windows: `git push`. Magalu: `cd /opt/mb8-comunic && git pull && bash comunic/aplicar.sh`.
