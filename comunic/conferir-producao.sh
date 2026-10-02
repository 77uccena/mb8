#!/bin/bash
#
# Conferencia da PRODUCAO para a recarga recorrente. SOMENTE LEITURA: nao altera nada.
# Rode depois do aplicar.sh e de novo perto do dia da rotina (ex.: dia 19).
#
#   bash conferir-producao.sh            -> checklist
#   bash conferir-producao.sh --previa   -> checklist + previa do Relatorio_de_Recarga (dryrun)
#
set -u
MB=/var/www/html/mbilling
q() { mariadb mbilling -N -e "$1" 2>/dev/null; }
OK=0; AV=0
ok()    { OK=$((OK+1)); printf "   OK     %s\n" "$1"; }
aviso() { AV=$((AV+1)); printf "   AVISO  %s\n" "$1"; }

[ "$(id -u)" = "0" ] || { echo "Rode como root."; exit 1; }
[ -f "$MB/protected/commands/RecurringCreditCommand.php" ] || { echo "Customizacoes nao aplicadas (rode o aplicar.sh)."; exit 1; }

echo "== Servidor: $(hostname) ($(hostname -I | awk '{print $1}'))   MagnusBilling $(q "SELECT config_value FROM pkg_configuration WHERE config_key='version'")"

echo "== Customizacao (saude.sh)"
if bash "$(dirname "$0")/saude.sh" | sed 's/^/   /' | tee /tmp/mb8-comunic-saude.txt | grep -q FALHA; then
    AV=$((AV+1)); cat /tmp/mb8-comunic-saude.txt; echo "   -> corrija com: bash $(dirname "$0")/aplicar.sh"
else
    OK=$((OK+1)); echo "   OK     customizacao completa (arquivos, index.html, traducoes, banco, cron)"
fi

echo "== Relogio"
TZ_SYS=$(timedatectl show -p Timezone --value 2>/dev/null)
SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
ok "fuso do sistema: ${TZ_SYS:-?} (a rotina e agendada no horario de Brasilia, qualquer que seja o fuso)"
[ "$SYNC" = "yes" ] && ok "relogio sincronizado (NTP)" || aviso "relogio NAO sincronizado: timedatectl set-ntp true"
[ "$(php -r 'echo date("Y-m-d H:i");')" = "$(date '+%Y-%m-%d %H:%M')" ] \
    && ok "fuso do PHP igual ao do sistema ($(php -r 'echo date_default_timezone_get();'))" \
    || aviso "fuso do PHP ($(php -r 'echo date_default_timezone_get();')) diferente do sistema: ajuste date.timezone"
echo "   agora: $(date '+%d/%m/%Y %H:%M')"

echo "== Configuracoes"
DIA=$(q "SELECT config_value FROM pkg_configuration WHERE config_key='recurring_credit_day'")
GRUPOS=$(q "SELECT config_value FROM pkg_configuration WHERE config_key='recurring_credit_groups'")
FIN=$(q "SELECT config_value FROM pkg_configuration WHERE config_key='finance_email'")
ADM=$(q "SELECT config_value FROM pkg_configuration WHERE config_key='admin_email'")
ok "dia da rotina: ${DIA:-20}"
for G in $(echo "${GRUPOS:-3}" | tr ',;' '  '); do
    echo "   grupo da recarga: $G - $(q "SELECT CONCAT(name, ' (', (SELECT COUNT(*) FROM pkg_user WHERE id_group=$G), ' usuarios)') FROM pkg_group_user WHERE id=$G")"
done
[ -n "$FIN" ] && ok "e-mail do financeiro: $FIN" || aviso "e-mail do financeiro vazio (vai para o Admin Email: ${ADM:-vazio}). Configuracoes > Configuracao"
SMTP=$(q "SELECT CONCAT(host, ':', port, ' usuario ', username) FROM pkg_smtp WHERE id_user=1 LIMIT 1")
[ -n "$SMTP" ] && ok "SMTP do admin: $SMTP (envie um e-mail de teste pelo painel)" || aviso "sem SMTP do admin: Configuracoes > SMTP"
case "$SMTP" in 127.0.0.1:1025*) aviso "SMTP aponta para o Mailpit (configuracao de VM de teste!)";; esac

echo "== Crontab"
CR=$({ crontab -l 2>/dev/null; cat /var/spool/cron/crontabs/root 2>/dev/null; } | grep -v '^\s*#' | grep RecurringCredit | sort -u)
# horario do servidor que corresponde a 00:00 / 00:30 de Brasilia
read -r BM BH RM RH <<< "$(php -r '$d = new DateTime("today 00:00", new DateTimeZone("America/Sao_Paulo")); $d->setTimezone(new DateTimeZone(date_default_timezone_get())); $r = (clone $d)->modify("+30 minutes"); echo (int)$d->format("i"), " ", (int)$d->format("G"), " ", (int)$r->format("i"), " ", (int)$r->format("G");')"
echo "$CR" | grep -q "^$BM $BH \* \* \* .*RecurringCredit backup" && ok "backup: $(printf '%02d:%02d' $BH $BM) do servidor = 00:00 de Brasilia" \
    || aviso "linha do backup ausente ou em outro horario (esperado: $BM $BH * * *). Rode: cd $MB && php cron.php PlanConsumptionSetup"
echo "$CR" | grep -q "^$RM $RH \* \* \* .*RecurringCredit\s*$" && ok "recarga: $(printf '%02d:%02d' $RH $RM) do servidor = 00:30 de Brasilia" \
    || aviso "linha da recarga ausente ou em outro horario (esperado: $RM $RH * * *). Rode: cd $MB && php cron.php PlanConsumptionSetup"
[ "$(echo "$CR" | grep -c RecurringCredit)" -le 2 ] || aviso "ha mais de 2 linhas RecurringCredit no crontab (duplicadas?)"
systemctl is-active --quiet cron 2>/dev/null && ok "servico cron ativo" || aviso "servico cron parado"

echo "== Clientes dos grupos da recarga"
IN=$(echo "${GRUPOS:-3}" | tr ';' ',' | tr -d ' ')
mariadb mbilling -t -e "
SELECT COALESCE(plan_type, '(sem plano)') AS plano,
       SUM(active=1) AS ativos, SUM(active<>1) AS nao_ativos,
       SUM(active=1 AND recurring_value>0) AS vao_recarregar,
       SUM(active=1 AND COALESCE(recurring_value,0)=0 AND plan_type IS NOT NULL) AS ativos_recorrente_zero,
       ROUND(SUM(IF(active=1 AND recurring_value>0, GREATEST(0, recurring_value-credit), 0)),2) AS recarga_prevista_hoje
FROM pkg_user WHERE id_group IN ($IN) GROUP BY plan_type ORDER BY plan_type IS NULL, plan_type;" 2>/dev/null
SEM=$(q "SELECT COUNT(*) FROM pkg_user WHERE id_group IN ($IN) AND active=1 AND (plan_type IS NULL OR recurring_value<=0)")
if [ "${SEM:-0}" -gt 0 ]; then
    aviso "$SEM cliente(s) ativo(s) sem tipo de plano ou com valor recorrente 0 (NAO serao recarregados). Primeiros 20:"
    q "SELECT CONCAT('          ', username, '  ', TRIM(CONCAT(firstname,' ',lastname)), '  plano=', COALESCE(plan_type,'-'), '  recorrente=', recurring_value)
       FROM pkg_user WHERE id_group IN ($IN) AND active=1 AND (plan_type IS NULL OR recurring_value<=0) ORDER BY username LIMIT 20"
else
    ok "todos os clientes ativos tem plano e valor recorrente"
fi

echo "== Recargas do mes $(date +%m/%Y)"
RC=$(q "SELECT COUNT(*) FROM pkg_refill WHERE description LIKE '%[RC-$(date +%Y%m)]%'")
echo "   recargas recorrentes ja feitas neste mes: ${RC:-0}"
AJ=$(q "SELECT COUNT(*) FROM pkg_refill r JOIN pkg_user u ON u.id=r.id_user WHERE u.id_group IN ($IN) AND r.date >= DATE_FORMAT(NOW(),'%Y-%m-01') AND r.description NOT LIKE '%[RC-%'")
if [ "${AJ:-0}" -gt 0 ]; then
    aviso "$AJ recarga(s)/ajuste(s) manual(is) neste mes nos grupos da recarga (conferir se nao duplica com a rotina):"
    q "SELECT CONCAT('          ', DATE_FORMAT(r.date,'%d/%m %H:%i'), '  ', u.username, '  ', ROUND(r.credit,2), '  ', LEFT(REPLACE(r.description,'\n',' '),60))
       FROM pkg_refill r JOIN pkg_user u ON u.id=r.id_user
       WHERE u.id_group IN ($IN) AND r.date >= DATE_FORMAT(NOW(),'%Y-%m-01') AND r.description NOT LIKE '%[RC-%' ORDER BY r.date DESC LIMIT 15"
else
    ok "nenhum ajuste manual neste mes nos grupos da recarga"
fi

if [ "${1:-}" = "--previa" ]; then
    echo "== Previa do Relatorio_de_Recarga (dryrun: nao grava nem envia nada)"
    (cd "$MB" && php cron.php RecurringCredit dryrun | sed -n '/=== Relatorio_de_Recarga/,$p' | sed '1d; s/^\xef\xbb\xbf//' > /root/previa-relatorio-recarga.csv)
    echo "   $(($(wc -l < /root/previa-relatorio-recarga.csv) - 1)) cliente(s). Arquivo: /root/previa-relatorio-recarga.csv (abra no Excel)"
    head -11 /root/previa-relatorio-recarga.csv | sed 's/^/   /'
fi

echo
echo "================ $OK OK, $AV AVISO(S) ================"
[ $AV -eq 0 ] && echo "Tudo pronto para a rotina do dia ${DIA:-20}." || echo "Resolva os AVISOS antes do dia ${DIA:-20}."
