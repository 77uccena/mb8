#!/bin/bash
#
# Bateria de testes da rotina de recarga recorrente (SOMENTE NA VM DE TESTE).
# Relatorio: Cliente;tipo de plano;valor recorrente;saldo (na recarga);recarga;valor a pagar
#
# Cria um grupo e usuarios de teste (prefixo "tst_"), simula datas com faketime,
# roda a rotina e confere automaticamente cada resultado (OK / FALHOU).
# Os clientes reais NAO sao tocados: durante o teste a configuracao
# "Grupos da recarga recorrente" aponta so para o grupo de teste.
# Ao final tudo e desfeito (usuarios, lancamentos, arquivos e configuracao).
#
#   bash testar-cenarios.sh            -> roda e limpa no final
#   bash testar-cenarios.sh --manter   -> roda e mantem os dados de teste para olhar no painel
#
set -u
MB=/var/www/html/mbilling
DIR=$MB/protected/runtime/recurring_credit
MAILPIT=http://127.0.0.1:8025
MANTER=0; [ "${1:-}" = "--manter" ] && MANTER=1
OKS=0; FALHAS=0

[ "$(id -u)" = "0" ] || { echo "Rode como root."; exit 1; }
. "$(dirname "$0")/_guarda-vm.sh"
command -v faketime >/dev/null || { echo "Instalando faketime..."; apt-get install -y faketime >/dev/null || { echo "Instale: apt install faketime"; exit 1; }; }
curl -s -o /dev/null "$MAILPIT/api/v1/messages" || { echo "Mailpit nao responde em $MAILPIT (veja a secao 6 do guia)."; exit 1; }
# o PHP precisa estar no mesmo fuso do sistema (a rotina roda 00:00 / 00:30 no horario local)
if [ "$(php -r 'echo date("Y-m-d H");')" != "$(date '+%Y-%m-%d %H')" ]; then
    echo "ATENCAO: fuso do PHP ($(php -r 'echo date_default_timezone_get();')) diferente do sistema ($(timedatectl show -p Timezone --value 2>/dev/null))."
    echo "Corrija date.timezone em /etc/php/*/cli/conf.d e /etc/php/*/mods-available/magnusbilling.ini antes de testar."
    exit 1
fi
[ "$(mariadb mbilling -N -e "SELECT COUNT(*) FROM pkg_trunk WHERE status=1")" = "0" ] \
    || { echo "Existem troncos ativos: isto parece PRODUCAO. Abortado."; exit 1; }

q()  { mariadb mbilling -N -e "$1"; }
ok() { # ok "descricao" "esperado" "obtido"
    if [ "$2" = "$3" ]; then OKS=$((OKS+1)); printf "   OK      %s\n" "$1"
    else FALHAS=$((FALHAS+1)); printf "   FALHOU  %s  (esperado: %s | obtido: %s)\n" "$1" "$2" "$3"; fi
}
rodar() { # rodar "AAAA-MM-DD HH:MM:SS" [backup]
    (cd "$MB" && faketime "$1" php cron.php RecurringCredit ${2:-} >/dev/null 2>&1)
}
csv() { # csv arquivo usuario coluna  -> valor da coluna (1 = primeira)
    awk -F';' -v u="$2" -v c="$3" '{gsub(/\r|\xef\xbb\xbf/,"")} $1==u {print $c; exit}' "$1" 2>/dev/null
}
emails() { # emails "trecho do assunto" -> "quantidade:anexos_do_ultimo"
    curl -s "$MAILPIT/api/v1/messages?limit=200" | php -r '
        $d = json_decode(stream_get_contents(STDIN), true); $n = 0; $a = "-";
        foreach (($d["messages"] ?? []) as $m) {
            if (strpos($m["Subject"], $argv[1]) !== false) { $n++; if ($a === "-") $a = $m["Attachments"]; }
        }
        echo $n . ":" . $a;' "$1"
}
corpo_contem() { # corpo_contem "trecho do assunto" "texto" -> 1/0
    ID=$(curl -s "$MAILPIT/api/v1/messages?limit=200" | php -r '
        $d = json_decode(stream_get_contents(STDIN), true);
        foreach (($d["messages"] ?? []) as $m) if (strpos($m["Subject"], $argv[1]) !== false) { echo $m["ID"]; break; }' "$1")
    [ -n "$ID" ] && curl -s "$MAILPIT/api/v1/message/$ID" | grep -q "$2" && echo 1 || echo 0
}
refills() { q "SELECT COUNT(*) FROM pkg_refill r JOIN pkg_user u ON u.id=r.id_user WHERE u.username LIKE 'tst\\_%' AND r.description LIKE '%[RC-$1]%'"; }
refill_de() { q "SELECT COALESCE(ROUND(SUM(r.credit),2),'sem') FROM pkg_refill r JOIN pkg_user u ON u.id=r.id_user WHERE u.username='$1' AND r.description LIKE '%[RC-$2]%'"; }
saldo() { q "SELECT ROUND(credit,2) FROM pkg_user WHERE username='$1'"; }
saldo4() { q "SELECT ROUND(credit,4) FROM pkg_user WHERE username='$1'"; }
refill4() { q "SELECT COALESCE(ROUND(SUM(r.credit),4),'sem') FROM pkg_refill r JOIN pkg_user u ON u.id=r.id_user WHERE u.username='$1' AND r.description LIKE '%[RC-$2]%'"; }
fotos() { q "SELECT COUNT(*) FROM pkg_recurring_credit f JOIN pkg_user u ON u.id=f.id_user WHERE u.username LIKE 'tst\\_%' AND f.month='$1'"; }
relatorio() { ls -t "$DIR"/Relatorio_de_Recarga-20${1:5:2}${1:0:4}_*.csv 2>/dev/null | head -1; } # relatorio AAAA-MM (rotina do dia 20)

# ---------- datas do teste (meses futuros, para nao misturar com o mes real)
M0=$(date -d "$(date +%Y-%m-01) +1 month" +%Y-%m)   # mes A
MA=$(date -d "$M0-01 -1 month" +%Y-%m)              # mes anterior (janela de consumo)
M1=$(date -d "$M0-01 +1 month" +%Y-%m)              # mes B
M2=$(date -d "$M0-01 +2 month" +%Y-%m)              # mes C
A=${M0/-/}; B=${M1/-/}; C=${M2/-/}; ANT=${MA/-/}
LA="${M0:5:2}/${M0:0:4}"; LB="${M1:5:2}/${M1:0:4}"; LC="${M2:5:2}/${M2:0:4}"

limpar() {
    q "DELETE c FROM pkg_cdr c JOIN pkg_user u ON u.id=c.id_user WHERE u.username LIKE 'tst\\_%';
       DELETE f FROM pkg_recurring_credit f JOIN pkg_user u ON u.id=f.id_user WHERE u.username LIKE 'tst\\_%';
       DELETE r FROM pkg_refill r JOIN pkg_user u ON u.id=r.id_user WHERE u.username LIKE 'tst\\_%';
       DELETE FROM pkg_user WHERE username LIKE 'tst\\_%';
       DELETE FROM pkg_group_user WHERE name = 'TESTE recarga recorrente';" 2>/dev/null
    rm -f "$DIR"/*_{${A},${B},${C}}_*.csv "$DIR"/Relatorio_de_Recarga-??{${M0:5:2}${M0:0:4},${M1:5:2}${M1:0:4},${M2:5:2}${M2:0:4}}_*.csv 2>/dev/null
}

echo "== Preparando (meses simulados: $LA, $LB e $LC)"
CFG_GRUPOS=$(q "SELECT config_value FROM pkg_configuration WHERE config_key='recurring_credit_groups'")
CFG_DIA=$(q "SELECT config_value FROM pkg_configuration WHERE config_key='recurring_credit_day'")
limpar
curl -s -X DELETE "$MAILPIT/api/v1/messages" >/dev/null
q "INSERT INTO pkg_group_user (name, id_user_type) VALUES ('TESTE recarga recorrente', 3)"
TG=$(q "SELECT id FROM pkg_group_user WHERE name='TESTE recarga recorrente'")
q "UPDATE pkg_configuration SET config_value='$TG' WHERE config_key='recurring_credit_groups';
   UPDATE pkg_configuration SET config_value='20'  WHERE config_key='recurring_credit_day';"

# usuario;grupo;plano;recorrente;saldo;status
while IFS=';' read -r U G P R S AT; do
    [ -z "$U" ] && continue
    [ "$G" = "TG" ] && G=$TG
    q "INSERT INTO pkg_user (id_user, id_group, username, password, callingcard_pin, firstname, active, plan_type, recurring_value, credit, email)
       VALUES (1, $G, '$U', 'Tst#${RANDOM}x', 100000 + FLOOR(RAND()*899999), 'Cliente $U', $AT, $P, $R, 0, '$U@teste.local')"
done <<EOF
tst_01;TG;'franchise';100;-50;1
tst_02;TG;'minutes';200;0;1
tst_03;TG;'unlimited';300;120.55;1
tst_04;TG;'franchise';150;150;1
tst_05;TG;'minutes';100;480;1
tst_06;TG;'franchise';100;10;0
tst_07;TG;'minutes';100;10;3
tst_08;TG;NULL;500;5;1
tst_09;TG;'franchise';0;5;1
tst_10;3;'franchise';100;0;1
EOF

id_de() { q "SELECT id FROM pkg_user WHERE username='$1'"; }
cdr() { q "INSERT INTO pkg_cdr (id_user, uniqueid, calledstation, src, starttime, sessionbill, sessiontime) VALUES ($(id_de $1), 'tst$RANDOM$RANDOM', '5511999999999', '$1', '$2', $3, 60)"; }
# janela de consumo do mes A: desde a ultima recarga recorrente (dia 20 do mes anterior, 00:30)
for U in tst_01 tst_03; do
    q "INSERT INTO pkg_refill (id_user, date, credit, description, payment) VALUES ($(id_de $U), '$MA-20 00:30:00', 0, 'Credito recorrente teste [RC-$ANT]', 1)"
done
cdr tst_01 "$MA-19 10:00:00" 99      # antes da janela: NAO conta
cdr tst_01 "$MA-25 10:00:00" 60
cdr tst_01 "$M0-10 10:00:00" 70
cdr tst_01 "$M0-20 01:00:00" 999     # depois da recarga do mes A: conta so no mes B
cdr tst_02 "$MA-19 23:59:00" 11      # sem recarga anterior: janela desde o dia 20 anterior -> NAO conta
cdr tst_02 "$MA-21 09:00:00" 50
cdr tst_03 "$M0-05 10:00:00" 500
# saldos definidos depois das ligacoes (as ligacoes descontam saldo)
while IFS=';' read -r U S; do q "UPDATE pkg_user SET credit=$S WHERE username='$U'"; done <<EOF
tst_01;-50
tst_02;-12.3456
tst_03;120.55
tst_04;150
tst_05;480
tst_06;10
tst_07;10
tst_08;5
tst_09;5
tst_10;0
EOF

echo
echo "== Cenario 1: dia 19 (antes do dia configurado) - nada pode acontecer"
rodar "$M0-19 23:50:00" backup; rodar "$M0-19 23:59:30"
ok "nenhuma recarga no dia 19" "0" "$(refills $A)"
ok "nenhum arquivo gerado no dia 19" "0" "$(ls "$DIR"/*_${A}_*.csv 2>/dev/null | wc -l)"

echo
echo "== Cenario 2: dia 20, 00:00 - backup de seguranca"
rodar "$M0-20 00:00:10" backup
FB=$(ls -t "$DIR"/backup_saldo_antes_recarga_${A}_*.csv 2>/dev/null | head -1)
ok "arquivo de backup criado" "1" "$([ -n "$FB" ] && echo 1 || echo 0)"
ok "backup NAO altera saldos (nenhuma recarga)" "0" "$(refills $A)"
ok "backup: saldo de tst_01 = -50,00" "-50,00" "$(csv "$FB" tst_01 9)"
ok "backup: recarga prevista de tst_01 = 150,00" "150,00" "$(csv "$FB" tst_01 10)"
ok "backup inclui cliente SEM plano (tst_08)" "5,00" "$(csv "$FB" tst_08 9)"
ok "backup NAO inclui outro grupo (tst_10)" "" "$(csv "$FB" tst_10 1)"
ok "e-mail do backup com 1 anexo" "1:1" "$(emails "Backup de segurança - saldo antes da recarga $LA")"

echo
echo "== Cenario 3: dia 20, 00:30 - recarga"
rodar "$M0-20 00:30:10"
FR=$(relatorio $M0)
ok "Relatorio_de_Recarga-20${M0:5:2}${M0:0:4} criado" "1" "$([ -n "$FR" ] && echo 1 || echo 0)"
ok "tst_01 saldo negativo: recarga 150,00"      "150.00" "$(refill_de tst_01 $A)"
ok "tst_01 saldo final = recorrente (100,00)"  "100.00" "$(saldo tst_01)"
ok "tst_02 saldo -12,3456: recarga exata 212,3456" "212.3456" "$(refill4 tst_02 $A)"
ok "tst_02 saldo final exato 200,0000"           "200.0000" "$(saldo4 tst_02)"
ok "tst_03 saldo abaixo: recarga 179,45"        "179.45" "$(refill_de tst_03 $A)"
ok "tst_04 saldo igual: recarga 0,00"           "0.00"   "$(refill_de tst_04 $A)"
ok "tst_05 saldo acima: recarga 0,00"           "0.00"   "$(refill_de tst_05 $A)"
ok "tst_05 saldo acima permanece 480,00"        "480.00" "$(saldo tst_05)"
ok "tst_06 inativo: sem lancamento"             "sem"    "$(refill_de tst_06 $A)"
ok "tst_07 bloqueado: sem lancamento"           "sem"    "$(refill_de tst_07 $A)"
ok "tst_07 bloqueado: saldo intacto (10,00)"    "10.00"  "$(saldo tst_07)"
ok "tst_08 sem plano: sem lancamento"           "sem"    "$(refill_de tst_08 $A)"
ok "tst_09 recorrente zero: sem lancamento"     "sem"    "$(refill_de tst_09 $A)"
ok "tst_10 outro grupo: sem lancamento"         "sem"    "$(refill_de tst_10 $A)"
ok "tst_10 outro grupo: saldo intacto (0,00)"   "0.00"   "$(saldo tst_10)"
ok "total de lancamentos do mes = 5"            "5"      "$(refills $A)"
ok "5 fotos gravadas (saldo antes da recarga)"   "5"      "$(fotos $A)"
echo "   -- Relatorio_de_Recarga (1 Cliente 2 tipo 3 recorrente 4 saldo na recarga 5 recarga 6 valor a pagar)"
C1="Cliente tst_01"; C2="Cliente tst_02"; C3="Cliente tst_03"
ok "cabecalho no formato do financeiro" "Cliente;tipo de plano;valor recorrente;saldo;recarga;valor a pagar" \
   "$(head -1 "$FR" | sed 's/^\xef\xbb\xbf//; s/\r$//')"
ok "sem linha de total no relatorio"             "0" "$(grep -ci '^total' "$FR")"
ok "tst_01 linha completa (Franquia, saldo -50)" "Cliente tst_01;Plano de Franquia;100,00;-50,00;150,00;50,00" "$(grep "^$C1;" "$FR" | tr -d '\r')"
ok "tst_02 linha exata (Minutos, saldo -12,3456)" "Cliente tst_02;Plano de Minutos;200,00;-12,3456;212,3456;12,3456" "$(grep "^$C2;" "$FR" | tr -d '\r')"
ok "tst_03 ilimitado nao paga (saldo 120,55)"    "Cliente tst_03;Plano Ilimitado;300,00;120,55;179,45;0,00" "$(grep "^$C3;" "$FR" | tr -d '\r')"
ok "tst_04 saldo igual: recarga 0 e paga 0"      "150,00;0,00;0,00" "$(csv "$FR" "Cliente tst_04" 4);$(csv "$FR" "Cliente tst_04" 5);$(csv "$FR" "Cliente tst_04" 6)"
ok "tst_05 saldo acima: saldo 480, recarga 0"     "480,00;0,00;0,00" "$(csv "$FR" "Cliente tst_05" 4);$(csv "$FR" "Cliente tst_05" 5);$(csv "$FR" "Cliente tst_05" 6)"
ok "tst_06 inativo aparece com recarga 0,00"     "10,00;0,00" "$(csv "$FR" "Cliente tst_06" 4);$(csv "$FR" "Cliente tst_06" 5)"
ok "tst_08 sem plano NAO aparece"                ""       "$(csv "$FR" "Cliente tst_08" 1)"
ok "tst_10 outro grupo NAO aparece"              ""       "$(csv "$FR" "Cliente tst_10" 1)"
ok "e-mail da rotina com 2 anexos" "1:2" "$(emails "Relatório da recarga recorrente $LA")"
ok "e-mail da rotina sem aviso de backup ausente" "0" "$(corpo_contem "Relatório da recarga recorrente $LA" "não foi encontrado")"

echo
echo "== Cenario 4: rodar a recarga de novo no mesmo mes - nao pode duplicar"
rodar "$M0-20 00:45:00"; rodar "$M0-21 00:30:00"
ok "continua com 5 lancamentos" "5" "$(refills $A)"
ok "tst_01 continua com 100,00" "100.00" "$(saldo tst_01)"
ok "nenhum e-mail de rotina a mais" "1:2" "$(emails "Relatório da recarga recorrente $LA")"

echo
echo "== Cenario 5: cliente reativado no meio do mes recebe no dia seguinte"
q "UPDATE pkg_user SET active=1 WHERE username='tst_06'"
rodar "$M0-25 00:00:05" backup; rodar "$M0-25 00:30:05"
ok "tst_06 reativado: recarga 90,00" "90.00" "$(refill_de tst_06 $A)"
ok "tst_06 saldo final 100,00" "100.00" "$(saldo tst_06)"

echo
echo "== Cenario 6: mes seguinte SEM o backup das 00:00 (backup gerado na hora)"
q "UPDATE pkg_user SET credit = credit - 40 WHERE username='tst_02'"
q "UPDATE pkg_user SET credit = credit - 350 WHERE username='tst_01'"   # usou 350 com recorrente 100
rodar "$M1-20 00:30:10"
ok "backup gerado antes da recarga" "1" "$(ls "$DIR"/backup_saldo_antes_recarga_${B}_*.csv 2>/dev/null | wc -l)"
ok "e-mail avisa que o backup das 00:00 nao existia" "1" "$(corpo_contem "Relatório da recarga recorrente $LB" "não foi encontrado")"
FR2=$(relatorio $M1)
ok "tst_02 mes B: saldo 160,00 e recarga 40,00" "160,00;40,00" "$(csv "$FR2" "Cliente tst_02" 4);$(csv "$FR2" "Cliente tst_02" 5)"
ok "tst_01 mes B: comecou com 100, usou 350 -> saldo -250, recarga 350, paga 250" "-250,00;350,00;250,00" "$(csv "$FR2" "Cliente tst_01" 4);$(csv "$FR2" "Cliente tst_01" 5);$(csv "$FR2" "Cliente tst_01" 6)"
ok "mes A continua com a foto original (tst_01 saldo -50)" "-50.0000" "$(q "SELECT f.credit_before FROM pkg_recurring_credit f JOIN pkg_user u ON u.id=f.id_user WHERE u.username='tst_01' AND f.month='$A'")"
ok "tst_02 recarga do mes B = 40,00" "40.00" "$(refill_de tst_02 $B)"

echo
echo "== Cenario 7: falha ao gravar o backup - NENHUMA recarga pode acontecer"
mv "$DIR" "$DIR.teste-bkp" && touch "$DIR"
rodar "$M2-20 00:30:10"
rm -f "$DIR" && mv "$DIR.teste-bkp" "$DIR"
ok "nenhuma recarga no mes C" "0" "$(refills $C)"
ok "e-mail de erro enviado" "1:0" "$(emails "recarga recorrente NÃO executada $LC")"

echo
echo "== Restaurando configuracao"
q "UPDATE pkg_configuration SET config_value='$CFG_GRUPOS' WHERE config_key='recurring_credit_groups';
   UPDATE pkg_configuration SET config_value='$CFG_DIA'    WHERE config_key='recurring_credit_day';"
if [ $MANTER -eq 1 ]; then
    echo "   Dados de teste mantidos (usuarios tst_*, grupo 'TESTE recarga recorrente')."
    echo "   Para limpar depois: rode de novo sem --manter."
else
    limpar; echo "   Usuarios, lancamentos e arquivos de teste removidos."
fi

echo
echo "================ RESULTADO: $OKS OK, $FALHAS FALHOU ================"
[ $FALHAS -eq 0 ] && echo "Todos os cenarios passaram." || echo "Me mande as linhas FALHOU."
