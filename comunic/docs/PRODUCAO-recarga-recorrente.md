# Checklist para colocar a recarga recorrente em produção

> **Desde o repositório:** onde este guia fala em pacote `mb8-custom-producao-*.tar.gz` e `bash aplicar.sh`, use agora `cd /opt/mb8-comunic && git pull && bash comunic/aplicar.sh`; os scripts `importar-planos.sh` e `conferir-producao.sh` ficam em `comunic/`. Servidor novo: ver [../README.md](../README.md).


## Antes (na VM)
- [ ] `bash testar-cenarios.sh` → **0 FALHOU** (52 verificações automáticas)
- [ ] `bash testar-100-cenarios.sh` → **100 de 100 OK** (regra do financeiro; relatório em /root/relatorio-100-cenarios.csv)
- [ ] `bash simular-base-vm.sh` → **0 FALHOU** (zera e sorteia status/plano/recorrente/saldo de todos os clientes da VM, roda a rotina e confere um a um)
- [ ] Teste com dados reais (dump importado): `RecurringCredit dryrun`, conferir 5 a 10 clientes
      conhecidos (saldo, recarga prevista e valor a pagar) com o financeiro
- [ ] Financeiro abriu os 2 CSV no Excel e aprovou o formato
- [ ] Fuso do PHP = fuso do sistema:
      `php -r 'echo date_default_timezone_get();'` e `timedatectl` → America/Sao_Paulo

## Na produção (antes do dia 20) — pacote `mb8-custom-producao-AAAAMMDD.tar.gz`
O pacote de produção NÃO traz os scripts de teste/simulação (eles alteram dados).

1. [ ] Backup completo do banco:
       `mariadb-dump --single-transaction --routines --triggers mbilling | gzip > /root/mbilling-antes-recarga-$(date +%Y%m%d).sql.gz`
2. [ ] Extrair e aplicar (para sozinho se algum arquivo for de outra versão do MagnusBilling):
       `cd /root && tar xzmf mb8-custom-producao-*.tar.gz && cd mb8-custom && bash aplicar.sh`
3. [ ] Painel: sair, entrar de novo, Ctrl+F5. Conferir os campos no cadastro do cliente e
       Relatórios > Consumo por Plano.
4. [ ] Configurações > Configuração: "E-mail do financeiro" (real), "Grupos da recarga recorrente"
       (3 = Cliente; decidir o grupo 6), "Dia da recarga recorrente" = 20.
5. [ ] Configurações > SMTP do admin: enviar um e-mail de teste pelo painel.
6. [ ] Preencher Tipo de plano + Valor recorrente de todos os clientes:
       `bash importar-planos.sh --modelo` → financeiro preenche /root/planos-clientes.csv no Excel →
       `bash importar-planos.sh planos-clientes.csv` (prévia) → `... --aplicar`
7. [ ] `bash conferir-producao.sh` → resolver todos os AVISOS (relógio/NTP, fuso, e-mail, SMTP,
       crontab, clientes sem plano, ajustes manuais no mês).
8. [ ] Dia 19: `bash conferir-producao.sh --previa` → financeiro confere /root/previa-relatorio-recarga.csv
       (é exatamente o que a rotina vai lançar, com o saldo daquele momento).
9. [ ] Dia 20 de manhã: conferir os 2 e-mails e Faturamento > Recargas ([RC-AAAAMM]).

**Se algo sair errado no dia 20:** ver "Se algo sair errado" no fim deste guia (desfaz só as recargas do mês).

## Mudança de processo (a partir da implantação)
- O financeiro **deixa de fazer "Ajuste de Saldo" manual**. A rotina faz a recarga sozinha.
- No mês da implantação: confirmar que nenhum ajuste manual daquele mês foi lançado antes do dia 20
  (senão o cliente recebe em dobro). Para conferir:
  `mariadb mbilling -t -e "SELECT u.username, r.date, r.credit, LEFT(r.description,60) FROM pkg_refill r JOIN pkg_user u ON u.id=r.id_user WHERE r.date >= DATE_FORMAT(NOW(),'%Y-%m-01') AND r.description LIKE '%juste%';"`

## Dia 20
- 00:00 → e-mail "Backup de segurança" (nenhum saldo alterado)
- 00:30 → e-mail "Relatório da recarga recorrente" com 2 anexos (Relatorio_de_Recarga-DDMMAAAA.csv + backup)
- Conferir Faturamento > Recargas (marca [RC-AAAAMM])

## O que o financeiro valida no dia 20
**00:00 – Backup de segurança** (`backup_saldo_antes_recarga_AAAAMM.csv`)
- Linha TOTAL: soma dos saldos antes da recarga e da RECARGA PREVISTA. É o valor que vai entrar às 00:30.
- Algum cliente com RECARGA PREVISTA estranha (muito alta)? Confira o VALOR RECORRENTE dele.
- Se algo estiver errado: avisar o responsável **antes das 00:30** (ele comenta a linha das 00:30 no crontab).

**00:30 – Relatório de Recarga** (`Relatorio_de_Recarga-DDMMAAAA.csv`) — mesma regra da tela
Relatórios > Consumo por Plano:

`Cliente;tipo de plano;valor recorrente;saldo;recarga;valor a pagar`

| Coluna | Regra |
|---|---|
| saldo | saldo do cliente no momento da recarga (o mês começa com o recorrente e as ligações descontam) |
| recarga | saldo ≥ 0: recorrente − saldo (0 se o saldo já estava igual ou acima). Saldo < 0: recorrente + saldo devedor |
| valor a pagar | saldo negativo → o valor devido. Saldo positivo → 0. **Plano Ilimitado: sempre 0** |

| Plano | Recorrente | Saldo | Recarga | Valor a pagar |
|---|---|---|---|---|
| Plano de Minutos | 49,90 | 30,00 | 19,90 | 0,00 |
| Plano de Franquia | 100,00 | −150,45 | 250,45 | 150,45 |
| Plano Ilimitado | 300,00 | −950,00 | 1250,00 | 0,00 |
| Plano de Franquia | 100,00 | 120,00 | 0,00 | 0,00 |

- O valor recorrente já é cobrado todo mês; aparece só para explicar o cálculo. **Faturar o "valor a pagar".**
- Valores exatos: 2 casas, ou até 4 quando o saldo tiver (ex.: 12,3456). Sem linha de total (o total fica só na tela).
- Soma da recarga = RECARGA PREVISTA do backup (diferença só se alguém ligou entre 00:00 e 00:30).
- Cliente inativo/bloqueado aparece com recarga 0,00 (não é recarregado até ser reativado).
- O corpo do e-mail mostra quantos clientes foram recarregados e **se houve falha** em algum.
- No painel: Faturamento > Recargas, lançamentos "Crédito recorrente ... [RC-AAAAMM]".

**Não chegou e-mail?** Os arquivos ficam em `/var/www/html/mbilling/protected/runtime/recurring_credit/`
(pedir ao responsável técnico). Conferir Configurações > SMTP.

## Se algo sair errado
- Desfazer as recargas do mês (troque AAAAMM):
  ```
  mariadb mbilling -e "UPDATE pkg_user u JOIN pkg_refill r ON r.id_user=u.id SET u.credit=u.credit-r.credit WHERE r.description LIKE '%[RC-AAAAMM]%';
                       DELETE FROM pkg_refill WHERE description LIKE '%[RC-AAAAMM]%';
                       DELETE FROM pkg_recurring_credit WHERE month = 'AAAAMM';"
  ```
  Depois disso a rotina pode rodar de novo para o mês (manualmente: `php /var/www/html/mbilling/cron.php RecurringCredit`).
- Suspender a rotina: comente as 2 linhas RecurringCredit no `crontab -e`
- Arquivos do mês: `/var/www/html/mbilling/protected/runtime/recurring_credit/`
