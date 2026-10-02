#!/bin/bash
#
# 100 cenarios do financeiro (SOMENTE NA VM DE TESTE).
#
# Gera 100 clientes de teste (prefixo "tc_") com plano e saldo aleatorios, igual ao
# script do financeiro (saldo entre -1000,00 e 200,00), roda a rotina de verdade
# (backup 00:00 + recarga 00:30, com data simulada) e confere, cliente a cliente,
# o Relatorio_de_Recarga e o saldo final contra a regra:
#
#   saldo >= 0 : recarga = max(0, recorrente - saldo)   valor a pagar = 0
#   saldo <  0 : recarga = recorrente + |saldo|         valor a pagar = |saldo|
#   Plano Ilimitado: valor a pagar = 0 sempre
#
# Os 5 primeiros sao os exemplos do financeiro (cenarios_teste.json).
# Arquivos gerados em /root: cenarios_teste.json, relatorio-100-cenarios.csv
#
#   bash testar-100-cenarios.sh            -> testa e apaga os clientes de teste
#   bash testar-100-cenarios.sh --manter   -> mantem os clientes para ver na tela
#
set -u
MB=/var/www/html/mbilling
DIR=$MB/protected/runtime/recurring_credit
MANTER=0; [ "${1:-}" = "--manter" ] && MANTER=1

[ "$(id -u)" = "0" ] || { echo "Rode como root."; exit 1; }
. "$(dirname "$0")/_guarda-vm.sh"
command -v faketime >/dev/null || { echo "Instalando faketime..."; apt-get install -y faketime >/dev/null || { echo "Instale: apt install faketime"; exit 1; }; }
if [ "$(php -r 'echo date("Y-m-d H");')" != "$(date '+%Y-%m-%d %H')" ]; then
    echo "ATENCAO: fuso do PHP diferente do sistema. Corrija date.timezone antes de testar."; exit 1
fi
[ "$(mariadb mbilling -N -e "SELECT COUNT(*) FROM pkg_trunk WHERE status=1")" = "0" ] \
    || { echo "Existem troncos ativos: isto parece PRODUCAO. Abortado."; exit 1; }

q() { mariadb mbilling -N -e "$1"; }

# mes simulado: daqui a 4 meses (nao mistura com o mes real nem com testar-cenarios.sh)
M=$(date -d "$(date +%Y-%m-01) +4 month" +%Y-%m); YM=${M/-/}
DDMMAAAA="20${M:5:2}${M:0:4}"
GRUPO='TESTE 100 cenarios'

limpar() {
    q "DELETE f FROM pkg_recurring_credit f JOIN pkg_user u ON u.id=f.id_user WHERE u.username LIKE 'tc\\_%';
       DELETE r FROM pkg_refill r JOIN pkg_user u ON u.id=r.id_user WHERE u.username LIKE 'tc\\_%';
       DELETE FROM pkg_user WHERE username LIKE 'tc\\_%';
       DELETE FROM pkg_group_user WHERE name = '$GRUPO';" 2>/dev/null
    rm -f "$DIR"/*_${YM}_*.csv "$DIR"/Relatorio_de_Recarga-${DDMMAAAA}_*.csv 2>/dev/null
}

echo "== Preparando 100 clientes de teste (mes simulado ${M:5:2}/${M:0:4})"
CFG_GRUPOS=$(q "SELECT config_value FROM pkg_configuration WHERE config_key='recurring_credit_groups'")
CFG_DIA=$(q "SELECT config_value FROM pkg_configuration WHERE config_key='recurring_credit_day'")
limpar
q "INSERT INTO pkg_group_user (name, id_user_type) VALUES ('$GRUPO', 3)"
TG=$(q "SELECT id FROM pkg_group_user WHERE name='$GRUPO'")
q "UPDATE pkg_configuration SET config_value='$TG' WHERE config_key='recurring_credit_groups';
   UPDATE pkg_configuration SET config_value='20'  WHERE config_key='recurring_credit_day';"

# gera os cenarios (5 fixos do financeiro + 95 aleatorios) e o SQL dos clientes
php -r '
$planos = [["minutes", "Plano de Minutos", 49.90], ["franchise", "Plano de Franquia", 100.00], ["unlimited", "Plano Ilimitado", 300.00]];
$fixos  = [[0, 30.00], [1, -150.45], [2, -950.00], [0, -15.50], [1, 120.00]];
$c = []; $sql = "";
for ($i = 1; $i <= 100; $i++) {
    if ($i <= 5) { list($p, $saldo) = $fixos[$i - 1]; }
    else { $p = mt_rand(0, 2); $saldo = round(mt_rand(-100000, 20000) / 100, 2); }
    list($tipo, $nome, $rec) = $planos[$p];
    if ($saldo >= 0) { $recarga = max(0.0, round($rec - $saldo, 2)); $pagar = 0.0; }
    else { $recarga = round($rec + abs($saldo), 2); $pagar = abs($saldo); }
    if ($tipo === "unlimited") { $pagar = 0.0; }
    $u = sprintf("tc_%03d", $i);
    $c[] = ["id" => $i, "usuario" => $u, "plano" => $nome, "recorrencia" => $rec, "saldo" => $saldo, "recarga" => $recarga, "valor_a_pagar" => $pagar];
    $sql .= sprintf("INSERT INTO pkg_user (id_user,id_group,username,password,callingcard_pin,firstname,active,plan_type,recurring_value,credit,email) VALUES (1,%d,\x27%s\x27,\x27Tc#%dx\x27,%d,\x27Cenario %03d\x27,1,\x27%s\x27,%.2f,%.2f,\x27%s@teste.local\x27);\n",
        $argv[1], $u, mt_rand(1000, 9999), 7000000 + $i * 7 + mt_rand(0, 6), $i, $tipo, $rec, $saldo, $u);
}
file_put_contents("/root/cenarios_teste.json", json_encode($c, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_PRESERVE_ZERO_FRACTION));
file_put_contents("/tmp/tc_users.sql", $sql);
' "$TG" || { echo "Falha ao gerar os cenarios."; exit 1; }
mariadb mbilling < /tmp/tc_users.sql && rm -f /tmp/tc_users.sql
echo "   $(q "SELECT COUNT(*) FROM pkg_user WHERE username LIKE 'tc\\_%'") clientes criados; cenarios em /root/cenarios_teste.json"

echo "== Rodando a rotina (backup 00:00 e recarga 00:30 do dia 20/${M:5:2}/${M:0:4})"
(cd "$MB" && faketime "$M-20 00:00:10" php cron.php RecurringCredit backup >/dev/null 2>&1)
T0=$(date +%s)
(cd "$MB" && faketime "$M-20 00:30:10" php cron.php RecurringCredit >/dev/null 2>&1)
echo "   recarga executada em $(( $(date +%s) - T0 )) s"
FR=$(ls -t "$DIR"/Relatorio_de_Recarga-${DDMMAAAA}_*.csv 2>/dev/null | head -1)
[ -n "$FR" ] || { echo "   FALHOU: Relatorio_de_Recarga-${DDMMAAAA} nao foi gerado. Veja o log da rotina."; }
[ -n "$FR" ] && cp "$FR" /root/relatorio-100-cenarios.csv

echo "== Conferindo cliente a cliente"
q "SELECT u.username, ROUND(u.credit,2), COALESCE(ROUND(SUM(r.credit),2),'sem')
   FROM pkg_user u LEFT JOIN pkg_refill r ON r.id_user=u.id AND r.description LIKE '%[RC-$YM]%'
   WHERE u.username LIKE 'tc\\_%' GROUP BY u.id" > /tmp/tc_banco.txt
php -r '
$c = json_decode(file_get_contents("/root/cenarios_teste.json"), true);
$m = function ($v) { $s = number_format(round($v, 4), 4, ",", ""); return preg_replace("/(,\d{2}\d*?)0+$/", "\$1", $s); };
$csv = [];
if (is_file($argv[1])) foreach (file($argv[1]) as $l) {
    $l = rtrim(str_replace("\xEF\xBB\xBF", "", $l), "\r\n"); $f = explode(";", $l); $csv[$f[0]] = $l;
}
$banco = [];
foreach (file("/tmp/tc_banco.txt") as $l) { $f = explode("\t", trim($l)); $banco[$f[0]] = $f; }
$ok = 0; $falhas = [];
foreach ($c as $x) {
    $cli = sprintf("Cenario %03d", $x["id"]);
    $esperado = implode(";", [$cli, $x["plano"], $m($x["recorrencia"]), $m($x["saldo"]), $m($x["recarga"]), $m($x["valor_a_pagar"])]);
    $saldoFinal = number_format(round($x["saldo"] + $x["recarga"], 2), 2, ".", "");
    $b = $banco[$x["usuario"]] ?? ["", "?", "?"];
    $erros = [];
    if (($csv[$cli] ?? "(ausente)") !== $esperado) $erros[] = "relatorio: esperado [$esperado] obtido [" . ($csv[$cli] ?? "ausente") . "]";
    if ($b[2] !== number_format($x["recarga"], 2, ".", "")) $erros[] = "lancamento em Recargas: esperado " . number_format($x["recarga"], 2, ".", "") . " obtido " . $b[2];
    if ($b[1] !== $saldoFinal) $erros[] = "saldo final: esperado $saldoFinal obtido " . $b[1];
    if ($erros) $falhas[] = sprintf("   FALHOU  %s (%s, saldo %s): ", $x["usuario"], $x["plano"], $m($x["saldo"])) . implode(" | ", $erros);
    else $ok++;
}
$porPlano = [];
foreach ($c as $x) { $porPlano[$x["plano"]] = ($porPlano[$x["plano"]] ?? 0) + 1; }
foreach ($porPlano as $p => $n) echo "   $p: $n clientes\n";
echo "   com saldo negativo: " . count(array_filter($c, function ($x) { return $x["saldo"] < 0; })) . "\n";
echo "   com saldo acima do recorrente (recarga 0): " . count(array_filter($c, function ($x) { return $x["saldo"] >= $x["recorrencia"]; })) . "\n";
echo implode("\n", $falhas) . ($falhas ? "\n" : "");
echo "\n================ RESULTADO: $ok de " . count($c) . " cenarios OK, " . count($falhas) . " FALHOU ================\n";
exit($falhas ? 1 : 0);
' "${FR:-/nao/existe}"
RES=$?
rm -f /tmp/tc_banco.txt

echo
echo "== Restaurando configuracao"
q "UPDATE pkg_configuration SET config_value='$CFG_GRUPOS' WHERE config_key='recurring_credit_groups';
   UPDATE pkg_configuration SET config_value='$CFG_DIA'    WHERE config_key='recurring_credit_day';"
if [ $MANTER -eq 1 ]; then
    echo "   Clientes tc_* mantidos (grupo '$GRUPO'). Na tela: Relatorios > Consumo por Plano, ciclo ${M:5:2}/${M:0:4}"
    echo "   (antes, coloque o ID $TG em 'Grupos da recarga recorrente'). Para limpar: rode de novo sem --manter."
else
    limpar; echo "   Clientes, lancamentos e arquivos de teste removidos."
fi
echo "   Relatorio gerado (para o financeiro conferir no Excel): /root/relatorio-100-cenarios.csv"
exit $RES
