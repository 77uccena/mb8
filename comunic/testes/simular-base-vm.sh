#!/bin/bash
#
# Simulacao completa com os clientes da VM (SOMENTE NA VM DE TESTE).
#
#   1. ZERA todos os clientes (usuarios do tipo cliente, de todos os grupos):
#      saldo 0, sem tipo de plano, valor recorrente 0; apaga as recargas recorrentes
#      [RC-...] e as fotos (pkg_recurring_credit). CDRs e demais recargas sao mantidos.
#   2. Sorteia o STATUS: ~80% ativo, ~10% inativo, ~10% bloqueado.
#   3. Sorteia PLANO (Minutos / Franquia / Ilimitado; ~10% sem plano) e VALOR
#      RECORRENTE (49,90 a 1000,00; ~3% com recorrente 0).
#   4. Sorteia o SALDO: -1000,00 a 200,00; ~8% acima do recorrente; ~5% com 4 casas.
#   5. Roda a rotina de verdade com a data de hoje (backup + recarga) e confere
#      cliente a cliente se tudo esta dentro das regras.
#
# Antes de alterar, grava backup de pkg_user, pkg_refill e pkg_recurring_credit em /root.
# A foto dos valores sorteados fica na tabela mb8_sim_antes (para consulta).
#
#   bash simular-base-vm.sh
#
set -u
MB=/var/www/html/mbilling
DIR=$MB/protected/runtime/recurring_credit
MAILPIT=http://127.0.0.1:8025

[ "$(id -u)" = "0" ] || { echo "Rode como root."; exit 1; }
. "$(dirname "$0")/_guarda-vm.sh"
[ "$(mariadb mbilling -N -e "SELECT COUNT(*) FROM pkg_trunk WHERE status=1")" = "0" ] \
    || { echo "Existem troncos ativos: isto parece PRODUCAO. Abortado."; exit 1; }
if [ "$(php -r 'echo date("Y-m-d H");')" != "$(date '+%Y-%m-%d %H')" ]; then
    echo "ATENCAO: fuso do PHP diferente do sistema. Corrija date.timezone antes."; exit 1
fi

q() { mariadb mbilling -N -e "$1"; }

DIA=$(q "SELECT config_value FROM pkg_configuration WHERE config_key='recurring_credit_day'"); DIA=${DIA:-20}
GRUPOS=$(q "SELECT config_value FROM pkg_configuration WHERE config_key='recurring_credit_groups'"); GRUPOS=${GRUPOS:-3}
MES=$(date +%Y%m)
if [ "$(date +%-d)" -lt "$DIA" ]; then
    echo "Hoje e dia $(date +%-d); a rotina so roda a partir do dia $DIA. Rode a partir do dia $DIA."; exit 1
fi
TOTAL=$(q "SELECT COUNT(*) FROM pkg_user u JOIN pkg_group_user g ON g.id=u.id_group WHERE g.id_user_type=3")

echo "ATENCAO: isto ALTERA os $TOTAL clientes do banco 'mbilling' desta maquina ($(hostname), $(hostname -I | awk '{print $1}'))."
echo "Saldos, planos e valores recorrentes serao zerados e sorteados. Grupos da recarga: $GRUPOS. Ciclo: ${MES:4:2}/${MES:0:4}."
read -r -p "Digite SIM para continuar: " OK
[ "$OK" = "SIM" ] || { echo "Cancelado."; exit 1; }

BKP=/root/mb8-antes-simulacao-$(date +%Y%m%d-%H%M%S).sql.gz
echo "== Backup em $BKP"
mariadb-dump --single-transaction mbilling pkg_user pkg_refill pkg_recurring_credit | gzip > "$BKP" \
    || { echo "Falha no backup. Nada foi alterado."; exit 1; }

echo "== 1/5 Zerando todos os clientes"
q "UPDATE pkg_user u JOIN pkg_group_user g ON g.id=u.id_group
      SET u.credit = 0, u.plan_type = NULL, u.recurring_value = 0
    WHERE g.id_user_type = 3;
   DELETE FROM pkg_refill WHERE description LIKE '%[RC-%';
   DELETE FROM pkg_recurring_credit;"
rm -f "$DIR"/backup_saldo_antes_recarga_${MES}_*.csv "$DIR"/Relatorio_de_Recarga-*${MES:4:2}${MES:0:4}_*.csv 2>/dev/null
echo "   saldo total dos clientes agora: $(q "SELECT ROUND(SUM(u.credit),2) FROM pkg_user u JOIN pkg_group_user g ON g.id=u.id_group WHERE g.id_user_type=3")"

echo "== 2/5 Sorteando status (ativo / inativo / bloqueado)"
q "UPDATE pkg_user u JOIN pkg_group_user g ON g.id=u.id_group
      SET u.active = IF(RAND() < 0.80, 1, IF(RAND() < 0.5, 0, 3))
    WHERE g.id_user_type = 3;"

echo "== 3/5 Sorteando plano e valor recorrente"
q "UPDATE pkg_user u JOIN pkg_group_user g ON g.id=u.id_group
      SET u.plan_type = IF(RAND() < 0.10, NULL, ELT(1 + FLOOR(RAND() * 3), 'minutes', 'franchise', 'unlimited')),
          u.recurring_value = IF(RAND() < 0.03, 0, ROUND(49.90 + RAND() * 950.10, 2))
    WHERE g.id_user_type = 3;"

echo "== 4/5 Simulando saldo"
q "UPDATE pkg_user u JOIN pkg_group_user g ON g.id=u.id_group
      SET u.credit = ROUND(-1000 + RAND() * 1200, 2)
    WHERE g.id_user_type = 3;
   UPDATE pkg_user u JOIN pkg_group_user g ON g.id=u.id_group
      SET u.credit = u.recurring_value + ROUND(RAND() * 300, 2)
    WHERE g.id_user_type = 3 AND RAND() < 0.08;
   UPDATE pkg_user u JOIN pkg_group_user g ON g.id=u.id_group
      SET u.credit = u.credit - 0.0037
    WHERE g.id_user_type = 3 AND RAND() < 0.05;
   DROP TABLE IF EXISTS mb8_sim_antes;
   CREATE TABLE mb8_sim_antes AS
     SELECT u.id, u.username, u.firstname, u.lastname, u.company_name, u.id_group, u.active,
            u.plan_type, u.recurring_value, u.credit
     FROM pkg_user u JOIN pkg_group_user g ON g.id=u.id_group WHERE g.id_user_type = 3;"
mariadb mbilling -t -e "
SELECT IF(FIND_IN_SET(id_group, REPLACE('$GRUPOS',' ','')), 'recarga', 'fora') AS grupo,
       CASE active WHEN 1 THEN 'ativo' WHEN 0 THEN 'inativo' ELSE 'bloqueado' END AS status,
       COALESCE(plan_type, '(sem plano)') AS plano, COUNT(*) AS clientes,
       ROUND(SUM(credit), 2) AS saldo_total
FROM mb8_sim_antes GROUP BY 1, 2, 3 ORDER BY 1 DESC, 2, 3;"

echo "== 5/5 Rodando a rotina (backup + recarga) com a data de hoje"
curl -s -X DELETE "$MAILPIT/api/v1/messages" >/dev/null 2>&1
(cd "$MB" && php cron.php RecurringCredit backup >/dev/null 2>&1)
T0=$(date +%s)
(cd "$MB" && php cron.php RecurringCredit >/dev/null 2>&1)
echo "   recarga executada em $(( $(date +%s) - T0 )) s"
FR=$(ls -t "$DIR"/Relatorio_de_Recarga-*${MES:4:2}${MES:0:4}_*.csv 2>/dev/null | head -1)
[ -n "$FR" ] && cp "$FR" /root/relatorio-simulacao.csv

echo "== Conferindo cliente a cliente"
q "SELECT u.id, ROUND(u.credit,4), COALESCE(ROUND(SUM(r.credit),4),'sem'),
          (SELECT ROUND(f.credit_before,4) FROM pkg_recurring_credit f WHERE f.id_user=u.id AND f.month='$MES')
   FROM mb8_sim_antes a JOIN pkg_user u ON u.id=a.id
   LEFT JOIN pkg_refill r ON r.id_user=u.id AND r.description LIKE '%[RC-$MES]%'
   GROUP BY u.id" > /tmp/sim_depois.txt
# nomes em base64: TAB/quebra de linha no cadastro nao quebram a leitura
q "SELECT id, username, TO_BASE64(firstname), TO_BASE64(lastname), TO_BASE64(COALESCE(company_name,'')), id_group, active,
          COALESCE(plan_type,''), recurring_value, credit FROM mb8_sim_antes" | tr -d '\r' > /tmp/sim_antes.txt

php -r '
list(, $grupos, $csvFile) = $argv;
$grupos = array_map("intval", preg_split("/[;,\s]+/", $grupos, -1, PREG_SPLIT_NO_EMPTY));
$labels = ["franchise" => "Plano de Franquia", "minutes" => "Plano de Minutos", "unlimited" => "Plano Ilimitado"];
$n = function ($v) { return round((float) $v, 4); };
$m = function ($v) use ($n) { $s = number_format($n($v), 4, ",", ""); return preg_replace("/(,\d{2}\d*?)0+$/", "\$1", $s); };
$f4 = function ($v) use ($n) { return number_format($n($v), 4, ".", ""); };

$depois = [];
foreach (file("/tmp/sim_depois.txt") as $l) { $c = explode("\t", rtrim($l, "\n")); $depois[$c[0]] = $c; }
$csv = []; $csvCount = 0;
if (is_file($csvFile)) foreach (array_slice(file($csvFile), 1) as $l) {
    $l = rtrim($l, "\r\n"); if ($l === "") continue; $csvCount++;
    $f = str_getcsv($l, ";"); $csv[$f[0]][] = $l;
}

$ok = 0; $falhas = []; $cont = ["recarregado" => 0, "recarga_zero" => 0, "nao_ativo" => 0, "fora" => 0, "no_relatorio" => 0];
$totRecarga = 0; $totPagar = 0;
foreach (file("/tmp/sim_antes.txt") as $l) {
    list($id, $user, $fn, $ln, $comp, $grp, $active, $plan, $rec, $saldo) = explode("\t", rtrim($l, "\n"));
    $d = $depois[$id];
    $noRelatorio = in_array((int) $grp, $grupos, true) && isset($labels[$plan]);
    $elegivel = $noRelatorio && (int) $active === 1 && (float) $rec > 0;
    $recarga = $elegivel ? $n(max(0, $n($rec) - $n($saldo))) : 0.0;
    $pagar = ($noRelatorio && $plan !== "unlimited") ? $n(max(0, -$n($saldo))) : 0.0;
    $e = [];

    if ($elegivel) {
        if ($d[2] !== $f4($recarga)) $e[] = "recarga esperada " . $f4($recarga) . ", lancada " . $d[2];
        if ($d[3] !== $f4($saldo)) $e[] = "foto do saldo esperada " . $f4($saldo) . ", gravada " . ($d[3] === "NULL" ? "nenhuma" : $d[3]);
        $cont[$recarga > 0 ? "recarregado" : "recarga_zero"]++;
    } else {
        if ($d[2] !== "sem") $e[] = "NAO devia ter recarga (status $active, plano [" . $plan . "], grupo $grp, recorrente $rec) mas teve " . $d[2];
        $cont[$noRelatorio ? "nao_ativo" : "fora"]++;
    }
    $saldoFinal = $f4($n($saldo) + $recarga);
    if ($d[1] !== $saldoFinal) $e[] = "saldo final esperado $saldoFinal, obtido " . $d[1];

    $b = function ($v) { return base64_decode(str_replace("\\n", "", $v)); };
    $limpa = function ($v) { return trim(preg_replace("/[\\s\\x{00A0}]+/u", " ", $v)); };
    $nome = $limpa($b($fn) . " " . $b($ln)); if ($nome === "") $nome = $limpa($b($comp)); if ($nome === "") $nome = $user;
    $linhas = $csv[$nome] ?? [];
    if ($noRelatorio) {
        $cont["no_relatorio"]++; $totRecarga += $recarga; $totPagar += $pagar;
        $esperada = implode(";", array_map(function ($x) { return strpbrk($x, ";\"") !== false ? "\"" . str_replace("\"", "\"\"", $x) . "\"" : $x; },
            [$nome, $labels[$plan], $m($rec), $m($saldo), $m($recarga), $m($pagar)]));
        if (! in_array($esperada, $linhas, true)) $e[] = "linha do relatorio esperada [$esperada] obtida [" . implode(" / ", $linhas ?: ["ausente"]) . "]";
    }
    if ($e) $falhas[] = "   FALHOU  $user: " . implode(" | ", $e); else $ok++;
}
if ($csvCount !== $cont["no_relatorio"]) $falhas[] = "   FALHOU  relatorio com $csvCount linhas; esperado " . $cont["no_relatorio"];

echo "   clientes recarregados:                 {$cont["recarregado"]}\n";
echo "   ativos com saldo >= recorrente (0,00): {$cont["recarga_zero"]}\n";
echo "   no relatorio, mas inativo/bloqueado/recorrente 0 (sem recarga): {$cont["nao_ativo"]}\n";
echo "   fora da rotina (outro grupo ou sem plano): {$cont["fora"]}\n";
echo "   linhas no relatorio: $csvCount   total recarga: " . $m($totRecarga) . "   total valor a pagar: " . $m($totPagar) . "\n";
echo implode("\n", array_slice($falhas, 0, 40)) . ($falhas ? "\n" : "");
if (count($falhas) > 40) echo "   ... e mais " . (count($falhas) - 40) . "\n";
echo "\n================ RESULTADO: $ok clientes OK, " . count($falhas) . " FALHOU ================\n";
exit($falhas ? 1 : 0);
' "$GRUPOS" "${FR:-/nao/existe}"
RES=$?
rm -f /tmp/sim_antes.txt /tmp/sim_depois.txt

for ASSUNTO in "Backup de seguran" "da recarga recorrente"; do
    N=$(curl -s "$MAILPIT/api/v1/search?query=subject:%22${ASSUNTO// /%20}%22" 2>/dev/null | grep -o '"messages_count":[0-9]*' | cut -d: -f2)
    [ -z "$N" ] && N=$(curl -s "$MAILPIT/api/v1/messages?limit=1000" 2>/dev/null | grep -o "\"Subject\": *\"[^\"]*" | grep -c "$ASSUNTO")
    echo "   e-mail '$ASSUNTO...' no Mailpit: $N (esperado 1)"
done
echo
echo "Relatorio gerado: /root/relatorio-simulacao.csv  |  Tela: Relatorios > Consumo por Plano, ciclo ${MES:4:2}/${MES:0:4}"
echo "Valores sorteados: tabela mb8_sim_antes.  Para voltar ao estado anterior:"
echo "   gunzip -c $BKP | mariadb mbilling"
exit $RES
