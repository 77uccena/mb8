#!/bin/bash
#
# Comunic - migracao SELETIVA de um dump da producao (MagnusBilling 7 ou 8) para este
# MagnusBilling 8 Comunic (instalado com comunic/instalar.sh). Traz somente o que e
# pertinente para a Comunic; o resto do banco deste servidor fica como esta.
#
# Pode ser rodado de novo (ex.: migracao final com um dump mais novo): o tipo de plano e o
# valor recorrente ja preenchidos neste servidor sao mantidos (pelo login do usuario).
#
# O que vem (o restante NAO vem e aparece no relatorio final):
#   CLIENTES    usuarios (+ grupos e permissoes dos grupos), contas SIP
#   DIDs        DIDs, destinos de DID, uso de DID, historico de DID
#   FINANCEIRO  recargas, metodos de pagamento, vouchers, recargas de provedores, boletos,
#               recargas recorrentes (pkg_recurring_credit, se existir na origem)
#   TARIFAS     planos, tarifas, prefixos, tarifas de revenda, tarifas por usuario
#   ROTAS       provedores da lista PROVEDORES; troncos desses provedores; grupos de
#               tronco que tenham ao menos um desses troncos; tarifas e CNL desses provedores
#   AJUSTES     Configuracoes (menos a versao do banco), SMTP e modelos de e-mail
#               (desligue com --sem-configuracoes)
#
# Uso (como root):
#   bash comunic/migrar-dados.sh DUMP.sql.gz [opcoes]
#
# Opcoes:
#   --teste                  VM: e-mails para o Mailpit, troncos e servidores desativados,
#                            Asterisk desligado (nada sai da maquina)
#   --somente-ativos U1,U2   deixa ATIVOS somente estes usuarios (logins) entre clientes e
#                            revendas; os demais ficam inativos (mes de teste com operadoras)
#   --zerar-saldo            zera o saldo dos clientes dos grupos da recarga recorrente
#                            (Configuracoes > "Grupos da recarga", padrao 3), lancando um
#                            ajuste [ZERA-AAAAMM] em Faturamento > Recargas
#   --zerar-grupos 3,6       zera o saldo destes grupos (no lugar dos grupos da recarga)
#   --sem-registro           desativa os troncos que REGISTRAM na operadora (register=1).
#                            Use enquanto o servidor antigo continuar no ar: dois servidores
#                            registrando a mesma conta disputam as chamadas recebidas.
#   --manter-troncos A,B     troncos (trunkcode) que continuam ativos mesmo com --sem-registro
#   --com-cdr                traz tambem o historico de ligacoes (pkg_cdr e resumos)
#   --sem-configuracoes      nao copia Configuracoes / SMTP / modelos de e-mail
#   --provedores "A,B,C"     troca a lista de provedores (nomes como no painel)
#
set -u
COM="$(cd "$(dirname "$0")" && pwd)"
. "$COM/lib/comum.sh"

PROVEDORES="Voxbeam,Algar Telecom,Datora Telecom,TIP,NVoip,Directcall"
ORIG=mbilling_origem
DUMP=""; TESTE=0; SOMENTE=""; ZERAR=0; ZGRUPOS=""; COMCDR=0; CONFIG=1; SEMREG=0; MANTER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --teste) TESTE=1 ;;
        --somente-ativos) SOMENTE="${2:-}"; shift ;;
        --zerar-saldo) ZERAR=1 ;;
        --zerar-grupos) ZERAR=1; ZGRUPOS=$(echo "${2:-}" | tr -cd '0-9,'); shift ;;
        --sem-registro) SEMREG=1 ;;
        --manter-troncos) MANTER="${2:-}"; shift ;;
        --com-cdr) COMCDR=1 ;;
        --sem-configuracoes) CONFIG=0 ;;
        --provedores) PROVEDORES="${2:-}"; shift ;;
        -*) echo "Opcao desconhecida: $1"; exit 2 ;;
        *) DUMP="$1" ;;
    esac
    shift
done

[ "$(id -u)" = "0" ] || { echo "Rode como root."; exit 1; }
[ -n "$DUMP" ] && [ -f "$DUMP" ] || { echo "Uso: bash comunic/migrar-dados.sh DUMP.sql(.gz) [opcoes] (veja o cabecalho)"; exit 1; }
[ -f "$MB/protected/commands/PlanConsumptionSetupCommand.php" ] || { echo "Customizacoes nao aplicadas. Rode antes comunic/instalar.sh ou aplicar.sh."; exit 1; }

q()  { mariadb -N -e "$1" 2>/dev/null; }
qo() { mariadb "$ORIG" -N -e "$1" 2>/dev/null; }
esc() { printf '%s' "$1" | sed "s/'/''/g"; }

RTRONCOS=$(q "SELECT COUNT(*) FROM mbilling.pkg_trunk WHERE status=1")
echo "Servidor: $(hostname) - IP $(hostname -I | awk '{print $1}') - troncos ativos agora: ${RTRONCOS:-0}"
echo "Dump: $DUMP ($(du -h "$DUMP" | awk '{print $1}'))"
echo "Provedores: $PROVEDORES"
echo "Opcoes: teste=$TESTE somente-ativos=${SOMENTE:-nao} zerar-saldo=$ZERAR${ZGRUPOS:+ (grupos $ZGRUPOS)} sem-registro=$SEMREG${MANTER:+ (manter $MANTER)} com-cdr=$COMCDR configuracoes=$CONFIG"
echo
echo "Os dados de clientes, DIDs, financeiro, tarifas e rotas DESTE servidor serao SUBSTITUIDOS pelos do dump."
read -r -p "Digite o nome deste servidor ($(hostname)) para continuar: " OK
[ "$OK" = "$(hostname)" ] || { echo "Cancelado."; exit 1; }

BKP=/root/mb8-antes-migracao-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BKP"
REL="$BKP/relatorio-migracao.txt"
r() { echo "$*" | tee -a "$REL"; }

echo "== 1/8 Backup do banco atual em $BKP"
mariadb-dump --single-transaction --routines --triggers mbilling | gzip > "$BKP/mbilling.sql.gz" || { echo "ERRO no backup. Nada foi feito."; exit 1; }
crontab -l > "$BKP/crontab-root.txt" 2>/dev/null

echo "== 2/8 Parando cron, Asterisk e o painel"
systemctl stop cron; systemctl stop asterisk >/dev/null 2>&1; systemctl stop apache2 >/dev/null 2>&1
for S in $(systemctl list-units --type=service --no-legend 'php*-fpm*' | awk '{print $1}'); do systemctl stop "$S"; done
religar() {
    systemctl start apache2 >/dev/null 2>&1
    for S in $(systemctl list-unit-files --type=service --no-legend 'php*-fpm*' | awk '{print $1}'); do systemctl start "$S" >/dev/null 2>&1; done
    systemctl start cron
    if [ $TESTE -eq 1 ]; then systemctl disable --now asterisk >/dev/null 2>&1; else systemctl start asterisk; fi
}
falhou() { echo "ERRO: $1"; echo "Para voltar: gunzip -c $BKP/mbilling.sql.gz | mariadb mbilling"; religar; exit 1; }

echo "== 3/8 Carregando o dump num banco separado ($ORIG)"
mariadb -e "DROP DATABASE IF EXISTS $ORIG; CREATE DATABASE $ORIG CHARACTER SET utf8 COLLATE utf8_general_ci;"
if [[ "$DUMP" == *.gz ]]; then gunzip -c "$DUMP" | mariadb "$ORIG" || falhou "importacao do dump"
else mariadb "$ORIG" < "$DUMP" || falhou "importacao do dump"; fi
VO=$(qo "SELECT config_value FROM pkg_configuration WHERE config_key='version'")
VD=$(versao_banco)
r "Versao do banco: origem $VO / este servidor $VD"

echo "== 4/8 Estrutura da origem"
if [ "$VO" != "$VD" ]; then
    echo "   migrando a origem para MB8 (UpdateMysql no banco $ORIG)"
    (cd "$MB" && ORIGEM_DB="$ORIG" php -r '
        $c = require "protected/config/cron.php";
        $c["components"]["db"]["connectionString"] = preg_replace("/dbname=[^;]*/", "dbname=" . getenv("ORIGEM_DB"), $c["components"]["db"]["connectionString"]);
        require "yii/framework/yii.php";
        $_SERVER["argv"] = ["cron.php", "UpdateMysql"];
        Yii::createConsoleApplication($c)->run();') || falhou "UpdateMysql na origem"
    VO=$(qo "SELECT config_value FROM pkg_configuration WHERE config_key='version'")
    r "   origem agora: $VO"
    [ "$VO" = "$VD" ] || r "   AVISO: versoes diferentes ($VO x $VD); so as colunas em comum serao copiadas"
fi

# provedores da lista (por nome, sem diferenciar maiusculas)
IN_NOMES=""
IFS=',' read -ra LP <<< "$PROVEDORES"
for N in "${LP[@]}"; do N=$(echo "$N" | sed 's/^ *//; s/ *$//'); [ -n "$N" ] && IN_NOMES="$IN_NOMES,'$(esc "${N,,}")'"; done
IN_NOMES=${IN_NOMES#,}
PIDS=$(qo "SELECT GROUP_CONCAT(id) FROM pkg_provider WHERE LOWER(TRIM(provider_name)) IN ($IN_NOMES)")
[ -n "$PIDS" ] || falhou "nenhum provedor da lista encontrado na origem"
r "Provedores encontrados: $(qo "SELECT GROUP_CONCAT(provider_name ORDER BY provider_name SEPARATOR ', ') FROM pkg_provider WHERE id IN ($PIDS)")"
for N in "${LP[@]}"; do
    N=$(echo "$N" | sed 's/^ *//; s/ *$//')
    [ -n "$(qo "SELECT 1 FROM pkg_provider WHERE LOWER(TRIM(provider_name))='$(esc "${N,,}")'")" ] || r "   AVISO: provedor '$N' nao existe na origem"
done
qo "DROP TABLE IF EXISTS _mig_trunk, _mig_group;
    CREATE TABLE _mig_trunk AS SELECT id FROM pkg_trunk WHERE id_provider IN ($PIDS);
    CREATE TABLE _mig_group AS SELECT DISTINCT gt.id_trunk_group AS id FROM pkg_trunk_group_trunk gt JOIN _mig_trunk t ON t.id=gt.id_trunk;"

# tabela -> filtro (vazio = tudo). Ordem nao importa (chaves estrangeiras desligadas).
declare -A FILTRO=(
  [pkg_group_user]="" [pkg_group_module]="id_module IN (SELECT id FROM mbilling.pkg_module)" [pkg_group_user_group]=""
  [pkg_user]="" [pkg_sip]=""
  [pkg_did]="" [pkg_did_destination]="" [pkg_did_use]="" [pkg_did_history]=""
  [pkg_refill]="" [pkg_method_pay]="" [pkg_voucher]="" [pkg_boleto]="" [pkg_recurring_credit]=""
  [pkg_refill_provider]="id_provider IN ($PIDS)"
  [pkg_plan]="" [pkg_rate]="" [pkg_prefix]="" [pkg_rate_agent]="" [pkg_user_rate]=""
  [pkg_provider]="id IN ($PIDS)" [pkg_trunk]="id IN (SELECT id FROM $ORIG._mig_trunk)"
  [pkg_trunk_group]="id IN (SELECT id FROM $ORIG._mig_group)"
  [pkg_trunk_group_trunk]="id_trunk IN (SELECT id FROM $ORIG._mig_trunk)"
  [pkg_rate_provider]="id_provider IN ($PIDS)" [pkg_provider_cnl]="id_provider IN ($PIDS)"
)
if [ $COMCDR -eq 1 ]; then
    for T in $(qo "SHOW TABLES LIKE 'pkg_cdr%'"); do case "$T" in pkg_cdr_failed|pkg_cdr_archive) ;; *) FILTRO[$T]="" ;; esac; done
fi
if [ $CONFIG -eq 1 ]; then FILTRO[pkg_smtp]=""; FILTRO[pkg_templatemail]=""; fi

echo "== 5/8 Copiando"
SQL="$BKP/migracao.sql"
{
    echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;"
    # planos preenchidos neste servidor (tipo de plano / valor recorrente) sobrevivem a uma
    # nova migracao: se a origem nao tiver o plano do usuario, fica o daqui (pelo login)
    echo "DROP TABLE IF EXISTS mbilling._mig_planos;"
    echo "CREATE TABLE mbilling._mig_planos AS SELECT username, plan_type, recurring_value FROM mbilling.pkg_user WHERE plan_type IS NOT NULL OR recurring_value>0;"
    for T in "${!FILTRO[@]}"; do
        [ -n "$(q "SHOW TABLES FROM $ORIG LIKE '$T'")" ] || { echo "-- $T nao existe na origem"; echo "DELETE FROM mbilling.$T;" ; continue; }
        [ -n "$(q "SHOW TABLES FROM mbilling LIKE '$T'")" ] || { echo "-- $T nao existe neste servidor"; continue; }
        COLS=$(q "SELECT GROUP_CONCAT(CONCAT('\`',d.COLUMN_NAME,'\`') ORDER BY d.ORDINAL_POSITION)
                  FROM information_schema.COLUMNS d JOIN information_schema.COLUMNS o
                    ON o.TABLE_SCHEMA='$ORIG' AND o.TABLE_NAME=d.TABLE_NAME AND o.COLUMN_NAME=d.COLUMN_NAME
                  WHERE d.TABLE_SCHEMA='mbilling' AND d.TABLE_NAME='$T'")
        W=${FILTRO[$T]}; [ -n "$W" ] && W="WHERE $W"
        echo "DELETE FROM mbilling.$T;"
        echo "INSERT INTO mbilling.$T ($COLS) SELECT $COLS FROM $ORIG.$T $W;"
    done
    # referencias para o que ficou de fora
    echo "UPDATE mbilling.pkg_user u JOIN mbilling._mig_planos p ON p.username=u.username
          SET u.plan_type=p.plan_type, u.recurring_value=p.recurring_value
          WHERE u.plan_type IS NULL AND IFNULL(u.recurring_value,0)=0;"
    echo "UPDATE mbilling.pkg_trunk SET failover_trunk=0 WHERE failover_trunk>0 AND failover_trunk NOT IN (SELECT id FROM $ORIG._mig_trunk);"
    echo "UPDATE mbilling.pkg_sip SET id_trunk_group=0 WHERE id_trunk_group>0 AND id_trunk_group NOT IN (SELECT id FROM $ORIG._mig_group);"
    if [ $CONFIG -eq 1 ]; then
        echo "UPDATE mbilling.pkg_configuration d JOIN $ORIG.pkg_configuration o ON o.config_key=d.config_key
              SET d.config_value=o.config_value WHERE d.config_key<>'version';"
    fi
    echo "SET FOREIGN_KEY_CHECKS=1; SET UNIQUE_CHECKS=1;"
} > "$SQL"
# antes de copiar: o que vai ficar sem rota / sem grupo
SEMROTA=$(qo "SELECT CONCAT(pl.name,' (',COUNT(*),' tarifas -> grupo ',IFNULL(g.name,r.id_trunk_group),')') FROM pkg_rate r
              JOIN pkg_plan pl ON pl.id=r.id_plan LEFT JOIN pkg_trunk_group g ON g.id=r.id_trunk_group
              WHERE r.id_trunk_group NOT IN (SELECT id FROM _mig_group) GROUP BY pl.id, pl.name, g.name, r.id_trunk_group")
PLANOSEM=$(qo "SELECT CONCAT(u.username,' (plano ',pl.name,IF(u.active=1,', ativo',', inativo'),')') FROM pkg_user u JOIN pkg_plan pl ON pl.id=u.id_plan
               WHERE EXISTS (SELECT 1 FROM pkg_rate r WHERE r.id_plan=pl.id AND r.id_trunk_group NOT IN (SELECT id FROM _mig_group))")
SIPSEM=$(qo "SELECT CONCAT(s.name,' (grupo ',IFNULL(g.name,s.id_trunk_group),')') FROM pkg_sip s LEFT JOIN pkg_trunk_group g ON g.id=s.id_trunk_group
             WHERE s.id_trunk_group>0 AND s.id_trunk_group NOT IN (SELECT id FROM _mig_group)")
FORA=$(qo "SELECT CONCAT(p.provider_name,': ',COUNT(t.id),' tronco(s), ',IFNULL(SUM(t.status=1),0),' ativo(s)') FROM pkg_provider p LEFT JOIN pkg_trunk t ON t.id_provider=p.id
           WHERE p.id NOT IN ($PIDS) GROUP BY p.id, p.provider_name")
NPLANOS=$(q "SELECT COUNT(*) FROM mbilling.pkg_user WHERE plan_type IS NOT NULL")
mariadb < "$SQL" || falhou "copia dos dados (SQL em $SQL)"
r "Planos ja preenchidos neste servidor antes da migracao: ${NPLANOS:-0}; com plano depois: $(q "SELECT COUNT(*) FROM mbilling.pkg_user WHERE plan_type IS NOT NULL")"
q "DROP TABLE IF EXISTS mbilling._mig_planos"

echo "== 6/8 Customizacoes e opcoes"
(cd "$MB" && php cron.php PlanConsumptionSetup) | sed 's/^/   /' || falhou "PlanConsumptionSetup"
if [ $TESTE -eq 1 ]; then
    mariadb mbilling <<'SQL'
UPDATE pkg_smtp SET host='127.0.0.1', port='1025', username='mb8-vm@teste.local', password='teste', encryption='null';
INSERT INTO pkg_smtp (id_user, host, username, password, port, encryption)
  SELECT 1, '127.0.0.1', 'mb8-vm@teste.local', 'teste', '1025', 'null' WHERE NOT EXISTS (SELECT 1 FROM pkg_smtp WHERE id_user = 1);
UPDATE pkg_user SET email = CONCAT('cliente', id, '@teste.local'), email2 = '' WHERE id > 1;
UPDATE pkg_trunk SET status = 0;
UPDATE pkg_servers SET status = 0;
UPDATE pkg_templatemail SET status = 0 WHERE messagehtml LIKE '{%' AND messagehtml LIKE '%"url"%';
UPDATE pkg_configuration SET config_value = 'admin@teste.local' WHERE config_key = 'admin_email';
UPDATE pkg_configuration SET config_value = 'financeiro@teste.local' WHERE config_key = 'finance_email';
SQL
    r "MODO TESTE: e-mails no Mailpit, troncos desativados, Asterisk desligado"
fi
if [ -n "$SOMENTE" ]; then
    LISTA=""; IFS=',' read -ra LU <<< "$SOMENTE"
    for U in "${LU[@]}"; do U=$(echo "$U" | sed 's/^ *//; s/ *$//'); [ -n "$U" ] && LISTA="$LISTA,'$(esc "$U")'"; done
    LISTA=${LISTA#,}
    ACHADOS=$(q "SELECT GROUP_CONCAT(username) FROM mbilling.pkg_user WHERE username IN ($LISTA)")
    q "UPDATE mbilling.pkg_user u JOIN mbilling.pkg_group_user g ON g.id=u.id_group
       SET u.active=0 WHERE g.id_user_type IN (2,3) AND u.username NOT IN ($LISTA)"
    r "Somente ativos (clientes/revendas): ${ACHADOS:-NENHUM ENCONTRADO}  - os demais ficaram inativos"
fi
if [ $SEMREG -eq 1 ] && [ $TESTE -eq 0 ]; then
    LT="''"; IFS=',' read -ra LM <<< "$MANTER"
    for T in "${LM[@]}"; do T=$(echo "$T" | sed 's/^ *//; s/ *$//'); [ -n "$T" ] && LT="$LT,'$(esc "$T")'"; done
    DESL=$(q "SELECT GROUP_CONCAT(trunkcode SEPARATOR ', ') FROM mbilling.pkg_trunk WHERE register=1 AND status=1 AND trunkcode NOT IN ($LT)")
    q "UPDATE mbilling.pkg_trunk SET status=0 WHERE register=1 AND trunkcode NOT IN ($LT)"
    r "Troncos com registro desativados: ${DESL:-nenhum}"
fi
if [ $ZERAR -eq 1 ]; then
    GR=$(q "SELECT config_value FROM mbilling.pkg_configuration WHERE config_key='recurring_credit_groups'" | tr -cd '0-9,')
    GR=${GR:-3}; [ -n "$ZGRUPOS" ] && GR=$ZGRUPOS; MES=$(date +%Y%m)
    N=$(q "SELECT COUNT(*) FROM mbilling.pkg_user WHERE id_group IN ($GR) AND credit<>0")
    q "INSERT INTO mbilling.pkg_refill (id_user, date, credit, description, refill_type, payment)
       SELECT id, NOW(), -credit, CONCAT('[ZERA-$MES] Saldo zerado na migracao (saldo anterior: ', ROUND(credit,4), ')'), 0, 1
       FROM mbilling.pkg_user WHERE id_group IN ($GR) AND credit<>0;
       UPDATE mbilling.pkg_user SET credit=0 WHERE id_group IN ($GR) AND credit<>0;"
    r "Saldo zerado de $N cliente(s) dos grupos $GR (ajuste [ZERA-$MES] em Faturamento > Recargas)"
fi

echo "== 7/8 Configuracao PJSIP e servicos"
php <<'PHP' || echo "   AVISO: nao consegui gerar os arquivos PJSIP"
<?php
chdir('/var/www/html/mbilling');
require_once 'yii/framework/yii.php';
Yii::createConsoleApplication('protected/config/cron.php');
$trunks = Trunk::model()->findAll(['condition' => 'providertech = :t AND status = 1', 'params' => [':t' => 'pjsip']]);
$a = AsteriskAccess::instance(); $f = '/etc/asterisk/pjsip_magnus.conf';
if (count($trunks)) { $a->writeAsteriskFile($trunks, $f, 'trunkcode'); } else { file_put_contents($f, ''); }
$a->generateSipPeers();
printf("   %d tronco(s) pjsip ativo(s), %d conta(s) SIP.\n", count($trunks), Sip::model()->count());
PHP
chown root:asterisk /etc/asterisk/pjsip_magnus*.conf 2>/dev/null; chmod 0640 /etc/asterisk/pjsip_magnus*.conf 2>/dev/null
religar

echo "== 8/8 Relatorio"
{
echo
echo "== Migrado"
for T in pkg_user pkg_sip pkg_did pkg_did_destination pkg_refill pkg_method_pay pkg_plan pkg_rate pkg_prefix pkg_rate_agent pkg_provider pkg_trunk pkg_trunk_group pkg_trunk_group_trunk pkg_rate_provider pkg_provider_cnl; do
    printf '   %-24s origem %8s   aqui %8s\n' "$T" "$(qo "SELECT COUNT(*) FROM $T")" "$(q "SELECT COUNT(*) FROM mbilling.$T")"
done
echo
echo "== Ficou de fora (provedores)"; echo "${FORA:-   nenhum}" | sed 's/^/   /'
echo
echo "== ATENCAO: tarifas cujo grupo de tronco ficou de fora (ligacoes desses planos SEM ROTA)"
echo "${SEMROTA:-   nenhuma}" | sed 's/^/   /'
echo
echo "== Usuarios em planos com tarifas sem rota"
echo "${PLANOSEM:-   nenhum}" | sed 's/^/   /'
echo
echo "== Contas SIP que apontavam para grupo de tronco que ficou de fora (grupo zerado)"
echo "${SIPSEM:-   nenhuma}" | sed 's/^/   /'
echo
echo "== Nao migrado (tabelas com dados na origem)"
for T in pkg_cdr pkg_cdr_failed pkg_callerid pkg_restrict_phone pkg_ivr pkg_queue pkg_campaign pkg_offer pkg_services pkg_iax pkg_callshop pkg_servers pkg_api pkg_user_history; do
    [ $COMCDR -eq 1 ] && [ "$T" = "pkg_cdr" ] && continue
    N=$(qo "SELECT COUNT(*) FROM $T"); [ "${N:-0}" -gt 0 ] && printf '   %-22s %s registro(s)\n' "$T" "$N"
done
} | tee -a "$REL"
bash "$COM/saude.sh" | sed 's/^/   /' | tee -a "$REL"
qo "DROP TABLE IF EXISTS _mig_trunk, _mig_group"
cat <<FIM | tee -a "$REL"

Concluido. Relatorio: $REL   Backup anterior: $BKP/mbilling.sql.gz
O banco de origem ficou em '$ORIG' para consulta; apague quando nao precisar:
   mariadb -e "DROP DATABASE $ORIG"
Painel: entre com o usuario/senha da ORIGEM (Ctrl+F5). Revise os troncos: asterisk -rx "pjsip show registrations"
FIM
