#!/bin/bash
#
# Preenche "Tipo de plano" e "Valor recorrente" dos clientes a partir de uma planilha CSV.
#
#   bash importar-planos.sh --modelo            -> gera /root/planos-clientes.csv com os clientes
#                                                  dos grupos da recarga e os valores atuais
#   bash importar-planos.sh planilha.csv        -> PREVIA: mostra o que vai mudar (nao grava nada)
#   bash importar-planos.sh planilha.csv --aplicar -> grava (faz backup de pkg_user antes)
#
# Formato (o mesmo do modelo; abre e salva no Excel como CSV separado por ";"):
#   usuario;nome;tipo de plano;valor recorrente;origem do valor
#   joao123;Joao da Silva;Plano de Minutos;49,90;Ajuste de Saldo 21/09/2026: saldo -9,74 + ajuste 59,64
# tipo de plano: Minutos | Plano de Minutos | Franquia | Plano de Franquia | Ilimitado |
#                Plano Ilimitado | (vazio = sem plano, nao recebe a recarga)
# As colunas "nome" e "origem do valor" sao so para conferencia; nao sao gravadas.
# No --modelo, o valor recorrente vem sugerido: saldo anterior + ultimo "Ajuste de Saldo" manual.
#
set -u
MODELO=/root/planos-clientes.csv
[ "$(id -u)" = "0" ] || { echo "Rode como root."; exit 1; }
q() { mariadb mbilling -N -B -e "$1"; }

GRUPOS=$(q "SELECT config_value FROM pkg_configuration WHERE config_key='recurring_credit_groups'")
IN=$(echo "${GRUPOS:-3}" | tr ';' ',' | tr -d ' ')
echo "$IN" | grep -Eq '^[0-9]+(,[0-9]+)*$' || { echo "Grupos da recarga invalidos: $GRUPOS"; exit 1; }

if [ "${1:-}" = "--modelo" ]; then
    # valor sugerido = saldo anterior + valor do ultimo "Ajuste de Saldo" manual (ultimos 60 dias),
    # ou seja, o valor ate onde o financeiro completava o saldo
    q "SELECT u.username, TO_BASE64(TRIM(CONCAT(u.firstname,' ',u.lastname))), COALESCE(u.plan_type,''), u.recurring_value,
              COALESCE((SELECT TO_BASE64(CONCAT(DATE_FORMAT(r.date,'%d/%m/%Y'),'|',r.credit,'|',REPLACE(r.description,'\n',' ')))
                        FROM pkg_refill r WHERE r.id_user = u.id AND r.description LIKE 'Ajuste de Saldo%'
                          AND r.date >= NOW() - INTERVAL 60 DAY ORDER BY r.date DESC, r.id DESC LIMIT 1), '')
       FROM pkg_user u WHERE u.id_group IN ($IN) ORDER BY u.username" | php -r '
        $l = ["minutes" => "Plano de Minutos", "franchise" => "Plano de Franquia", "unlimited" => "Plano Ilimitado"];
        $b = function ($v) { return base64_decode(str_replace("\\n", "", $v)); };
        $q = function ($v) { return strpbrk($v, ";\"") !== false ? "\"" . str_replace("\"", "\"\"", $v) . "\"" : $v; };
        $m = function ($v) { return number_format((float) $v, 2, ",", ""); };
        $out = "\xEF\xBB\xBF" . "usuario;nome;tipo de plano;valor recorrente;origem do valor\r\n"; $n = 0; $sug = 0;
        while (($r = fgets(STDIN)) !== false) {
            $c = explode("\t", rtrim($r, "\n"));
            $nome = trim(preg_replace("/[\s\x{00A0}]+/u", " ", $b($c[1])));
            $valor = (float) $c[3]; $origem = $valor > 0 ? "cadastro atual" : "";
            if ($valor <= 0 && $c[4] !== "") {
                list($data, $cred, $desc) = explode("|", $b($c[4]), 3);
                if (preg_match("/(-?\d+(?:\.\d+)?)\s*$/", $desc, $mm)) {
                    $valor = round((float) $mm[1] + (float) $cred, 2);
                    $origem = "Ajuste de Saldo $data: saldo " . $m($mm[1]) . " + ajuste " . $m($cred); $sug++;
                }
            }
            $out .= implode(";", [$c[0], $q($nome), $l[$c[2]] ?? "", $valor > 0 ? $m($valor) : "", $q($origem)]) . "\r\n"; $n++;
        }
        file_put_contents($argv[1], $out);
        echo "$n cliente(s) em $argv[1]; $sug com valor recorrente sugerido pelo ultimo Ajuste de Saldo\n";' "$MODELO"
    echo "Abra no Excel: preencha 'tipo de plano' e CONFIRA 'valor recorrente' (a coluna 'origem do valor' mostra de onde veio)."
    echo "Salve como CSV (;) e rode:   bash importar-planos.sh $MODELO"
    exit 0
fi

ARQ="${1:-}"; APLICAR=0; [ "${2:-}" = "--aplicar" ] && APLICAR=1
[ -n "$ARQ" ] && [ -f "$ARQ" ] || { sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

q "SELECT username, id, COALESCE(plan_type,''), recurring_value FROM pkg_user WHERE id_group IN ($IN)" > /tmp/planos_atual.tsv
SQL=/tmp/importar-planos.sql
php -r '
list(, $arq, $sqlFile) = $argv;
$tipos = ["minutos" => "minutes", "plano de minutos" => "minutes", "franquia" => "franchise", "plano de franquia" => "franchise",
          "ilimitado" => "unlimited", "plano ilimitado" => "unlimited", "" => ""];
$nomes = ["minutes" => "Minutos", "franchise" => "Franquia", "unlimited" => "Ilimitado", "" => "(sem plano)"];
$atual = [];
foreach (file("/tmp/planos_atual.tsv") as $r) { $c = explode("\t", rtrim($r, "\n")); $atual[mb_strtolower($c[0])] = $c; }

$txt = file_get_contents($arq);
if (! mb_check_encoding($txt, "UTF-8")) $txt = mb_convert_encoding($txt, "UTF-8", "Windows-1252"); // Excel "CSV" sem UTF-8
$txt = preg_replace("/^\xEF\xBB\xBF/", "", $txt);
$linhas = preg_split("/\r\n|\n|\r/", $txt);
$sep = substr_count($linhas[0], ";") >= substr_count($linhas[0], ",") ? ";" : ",";

$erros = []; $mudancas = []; $iguais = 0; $vistos = []; $sql = ""; $semPlano = [];
foreach ($linhas as $i => $l) {
    if ($i === 0 || trim($l) === "" || trim(str_replace($sep, "", $l)) === "") continue;
    $c = str_getcsv($l, $sep);
    $u = trim($c[0] ?? ""); $tipoTxt = mb_strtolower(trim($c[2] ?? "")); $valTxt = trim($c[3] ?? "");
    $n = $i + 1;
    if ($u === "") { $erros[] = "linha $n: usuario vazio"; continue; }
    if (! isset($atual[mb_strtolower($u)])) { $erros[] = "linha $n: usuario \"$u\" nao existe nos grupos da recarga"; continue; }
    if (isset($vistos[mb_strtolower($u)])) { $erros[] = "linha $n: usuario \"$u\" repetido (linha " . $vistos[mb_strtolower($u)] . ")"; continue; }
    $vistos[mb_strtolower($u)] = $n;
    if (! array_key_exists($tipoTxt, $tipos)) { $erros[] = "linha $n ($u): tipo de plano \"" . trim($c[2]) . "\" invalido"; continue; }
    $v = preg_replace("/[R\$\s]/", "", $valTxt);
    if (strpos($v, ",") !== false) $v = str_replace(",", ".", str_replace(".", "", $v)); // 1.234,56 -> 1234.56
    if ($v === "") $v = "0";
    if (! is_numeric($v) || (float) $v < 0 || (float) $v > 999999) { $erros[] = "linha $n ($u): valor recorrente \"$valTxt\" invalido"; continue; }
    $tipo = $tipos[$tipoTxt]; $valor = round((float) $v, 2);
    if ($tipo === "") $semPlano[] = $u;
    if ($tipo !== "" && $valor <= 0) { $erros[] = "linha $n ($u): tem plano mas valor recorrente 0 (nao seria recarregado)"; continue; }
    list(, $id, $tAnt, $vAnt) = $atual[mb_strtolower($u)];
    if ($tAnt === $tipo && round((float) $vAnt, 2) == $valor) { $iguais++; continue; }
    $mudancas[] = sprintf("   %-22s %-12s %12s  ->  %-12s %12s", $u, $nomes[$tAnt], number_format((float) $vAnt, 2, ",", "."), $nomes[$tipo], number_format($valor, 2, ",", "."));
    $sql .= sprintf("UPDATE pkg_user SET plan_type = %s, recurring_value = %.2f WHERE id = %d;\n", $tipo === "" ? "NULL" : "\x27$tipo\x27", $valor, (int) $id);
}
$semLinha = array_diff_key($atual, $vistos);
echo "== Previa\n";
echo "   " . count($vistos) . " cliente(s) na planilha; " . count($mudancas) . " vao mudar; $iguais ja estao iguais\n";
if ($mudancas) { echo "   usuario                atual                          novo\n" . implode("\n", array_slice($mudancas, 0, 300)) . "\n"; }
if ($semPlano) echo "   ATENCAO: " . count($semPlano) . " cliente(s) SEM tipo de plano na planilha (NAO serao recarregados): " . implode(", ", array_slice($semPlano, 0, 15)) . (count($semPlano) > 15 ? ", ..." : "") . "\n";
if ($semLinha) echo "   " . count($semLinha) . " cliente(s) dos grupos da recarga NAO estao na planilha (ficam como estao)\n";
if ($erros) { echo "\n== " . count($erros) . " ERRO(S) - corrija a planilha; nada sera gravado\n   " . implode("\n   ", $erros) . "\n"; exit(2); }
file_put_contents($sqlFile, "START TRANSACTION;\n" . $sql . "COMMIT;\n");
exit($mudancas ? 0 : 3);
' "$ARQ" "$SQL"
RES=$?
rm -f /tmp/planos_atual.tsv
[ $RES -eq 2 ] && exit 2
[ $RES -eq 3 ] && { echo "Nada a alterar."; rm -f "$SQL"; exit 0; }

if [ $APLICAR -eq 0 ]; then
    echo
    echo "Nada foi gravado. Para gravar:  bash importar-planos.sh $ARQ --aplicar"
    rm -f "$SQL"; exit 0
fi

BKP=/root/pkg_user-antes-planos-$(date +%Y%m%d-%H%M%S).sql.gz
mariadb-dump --single-transaction mbilling pkg_user | gzip > "$BKP" || { echo "Falha no backup. Nada foi gravado."; rm -f "$SQL"; exit 1; }
mariadb mbilling < "$SQL" && echo "Gravado. Backup de pkg_user: $BKP" || echo "ERRO ao gravar (nada foi alterado: transacao desfeita)."
rm -f "$SQL"
echo "Para desfazer:  gunzip -c $BKP | mariadb mbilling"
