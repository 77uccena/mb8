#!/bin/bash
#
# Comunic - importa o banco da PRODUCAO (MagnusBilling 7 ou 8) neste servidor novo,
# ja instalado com o comunic/instalar.sh. Segue o procedimento oficial de migracao
# (wiki: EN--get_started--migrate_from_mb7):
#
#   1. backup do banco atual (vazio) deste servidor;
#   2. para cron, Asterisk e Apache/PHP;
#   3. recria o banco mbilling e importa o dump;
#   4. php cron.php UpdateMysql      -> converte MB7 -> MB8 (sip -> pjsip) e atualiza MB8 antigo;
#   5. php cron.php PlanConsumptionSetup -> colunas/menu/configuracoes/cron das customizacoes;
#   6. regenera /etc/asterisk/pjsip_magnus*.conf a partir do banco;
#   7. religa os servicos e mostra um resumo.
#
# Como gerar o dump no servidor ANTIGO (com os servicos parados para congelar os dados):
#   systemctl stop asterisk apache2 cron
#   mysqldump --single-transaction --quick --triggers --routines --hex-blob \
#     --default-character-set=utf8 mbilling | gzip > /root/mbilling-producao.sql.gz
#   sha256sum /root/mbilling-producao.sql.gz
#
# Uso (como root, no servidor NOVO):
#   bash comunic/importar-banco.sh /root/mbilling-producao.sql.gz
#   bash comunic/importar-banco.sh /root/mbilling-producao.sql.gz --teste
#        --teste = ensaio/VM: e-mails para o Mailpit local, troncos e servidores desativados,
#                  Asterisk desligado, crons de envio desligados. NADA sai da maquina.
#
set -u
MB=/var/www/html/mbilling
COM="$(cd "$(dirname "$0")" && pwd)"
DUMP="${1:-}"
TESTE=0
[ "${2:-}" = "--teste" ] && TESTE=1

[ "$(id -u)" = "0" ] || { echo "Rode como root."; exit 1; }
[ -n "$DUMP" ] && [ -f "$DUMP" ] || { echo "Uso: bash comunic/importar-banco.sh /caminho/dump.sql(.gz) [--teste]"; exit 1; }
[ -f "$MB/protected/commands/PlanConsumptionSetupCommand.php" ] || {
    echo "Customizacoes nao aplicadas neste servidor. Rode antes: bash $COM/instalar.sh (ou aplicar.sh)."; exit 1; }

if [[ "$DUMP" == *.gz ]]; then
    gzip -t "$DUMP" || { echo "Arquivo gz corrompido: $DUMP"; exit 1; }
    LER() { gunzip -c "$DUMP"; }
else
    LER() { cat "$DUMP"; }
fi
LER | head -c 2000000 | grep -q 'CREATE TABLE `pkg_user`\|CREATE TABLE `pkg_configuration`\|pkg_' \
    || { echo "O arquivo nao parece um dump do MagnusBilling."; exit 1; }

ATUAL=$(mariadb mbilling -N -e "SELECT COUNT(*) FROM pkg_user" 2>/dev/null || echo 0)
TRONCOS=$(mariadb mbilling -N -e "SELECT COUNT(*) FROM pkg_trunk WHERE status=1" 2>/dev/null || echo 0)
echo "Servidor: $(hostname) - IP $(hostname -I | awk '{print $1}')"
echo "Banco atual: $ATUAL usuario(s), $TRONCOS tronco(s) ativo(s)"
echo "Dump: $DUMP ($(du -h "$DUMP" | awk '{print $1}')) - sha256 $(sha256sum "$DUMP" | awk '{print $1}')"
[ $TESTE -eq 1 ] && echo "MODO TESTE: os dados serao neutralizados depois da importacao."
if [ "$TRONCOS" -gt 5 ]; then
    echo
    echo "ATENCAO: este servidor ja tem $TRONCOS troncos ativos. Ele parece ser uma PRODUCAO em uso."
    echo "Confira o IP acima. Este script e para o servidor NOVO."
fi
echo
echo "O banco 'mbilling' DESTE servidor sera APAGADO e substituido pelo dump."
read -r -p "Digite o nome deste servidor ($(hostname)) para continuar: " OK
[ "$OK" = "$(hostname)" ] || { echo "Cancelado."; exit 1; }

BKP=/root/mb8-antes-importacao-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BKP"
echo "== 1/7 Backup do banco atual em $BKP"
mariadb-dump --single-transaction --routines --triggers mbilling | gzip > "$BKP/mbilling.sql.gz"
crontab -l > "$BKP/crontab-root.txt" 2>/dev/null
cp -p /etc/asterisk/pjsip_magnus*.conf "$BKP/" 2>/dev/null

echo "== 2/7 Parando cron, Asterisk e o painel"
systemctl stop cron
systemctl stop asterisk >/dev/null 2>&1
systemctl stop apache2 >/dev/null 2>&1
for S in $(systemctl list-units --type=service --no-legend 'php*-fpm*' | awk '{print $1}'); do systemctl stop "$S"; done
for ID in $(mariadb -N -e "SELECT id FROM information_schema.PROCESSLIST WHERE db='mbilling' AND id<>CONNECTION_ID()"); do
    mariadb -e "KILL $ID" 2>/dev/null
done
religar() {
    systemctl start apache2 >/dev/null 2>&1
    for S in $(systemctl list-unit-files --type=service --no-legend 'php*-fpm*' | awk '{print $1}'); do
        systemctl start "$S" >/dev/null 2>&1
    done
    systemctl start cron
    if [ $TESTE -eq 1 ]; then
        systemctl disable --now asterisk >/dev/null 2>&1
    else
        systemctl start asterisk
    fi
}
falhou() { echo "ERRO: $1"; echo "Para voltar: gunzip -c $BKP/mbilling.sql.gz | mariadb mbilling"; religar; exit 1; }

echo "== 3/7 Importando (pode demorar)"
mariadb --protocol=socket -e "DROP DATABASE IF EXISTS mbilling; CREATE DATABASE mbilling CHARACTER SET utf8 COLLATE utf8_general_ci;"
LER | mariadb --protocol=socket mbilling || falhou "importacao do dump."
ORIGEM=$(mariadb mbilling -N -e "SELECT config_value FROM pkg_configuration WHERE config_key='version'")
echo "   versao do banco importado: $ORIGEM"
mariadb mbilling -N -e "SELECT CONCAT('   ', COUNT(*), ' usuarios importados') FROM pkg_user"

echo "== 4/7 Migracao da estrutura do banco (UpdateMysql)"
cd "$MB" && php cron.php UpdateMysql || falhou "UpdateMysql terminou com erro (veja a mensagem acima)."
FINAL=$(mariadb mbilling -N -e "SELECT config_value FROM pkg_configuration WHERE config_key='version'")
echo "   versao do banco: $ORIGEM -> $FINAL"
case "$FINAL" in 8*) ;; *) falhou "o banco nao chegou a uma versao 8 ($FINAL)." ;; esac

if [ $TESTE -eq 1 ]; then
    echo "   MODO TESTE: neutralizando"
    mariadb mbilling <<'SQL'
UPDATE pkg_smtp SET host='127.0.0.1', port='1025', username='mb8-vm@teste.local', password='teste', encryption='null';
INSERT INTO pkg_smtp (id_user, host, username, password, port, encryption)
  SELECT 1, '127.0.0.1', 'mb8-vm@teste.local', 'teste', '1025', 'null'
  WHERE NOT EXISTS (SELECT 1 FROM pkg_smtp WHERE id_user = 1);
UPDATE pkg_user SET email = CONCAT('cliente', id, '@teste.local'), email2 = '';
UPDATE pkg_trunk SET status = 0;
UPDATE pkg_servers SET status = 0;
UPDATE pkg_templatemail SET status = 0 WHERE messagehtml LIKE '{%' AND messagehtml LIKE '%"url"%';
UPDATE pkg_configuration SET config_value = 'admin@teste.local' WHERE config_key = 'admin_email';
SQL
fi

echo "== 5/7 Customizacoes Comunic (PlanConsumptionSetup)"
php cron.php PlanConsumptionSetup || falhou "PlanConsumptionSetup."
[ $TESTE -eq 1 ] && mariadb mbilling -e "UPDATE pkg_configuration SET config_value='financeiro@teste.local' WHERE config_key='finance_email'"

echo "== 6/7 Gerando a configuracao PJSIP a partir do banco"
php <<'PHP' || echo "   AVISO: nao consegui gerar os arquivos PJSIP (veja acima)."
<?php
chdir('/var/www/html/mbilling');
require_once 'yii/framework/yii.php';
Yii::createConsoleApplication('protected/config/cron.php');
$trunks = Trunk::model()->findAll(['condition' => 'providertech = :t AND status = 1', 'params' => [':t' => 'pjsip']]);
$asterisk = AsteriskAccess::instance();
$file = '/etc/asterisk/pjsip_magnus.conf';
if (count($trunks)) { $asterisk->writeAsteriskFile($trunks, $file, 'trunkcode'); } else { file_put_contents($file, ''); }
$asterisk->generateSipPeers();
printf("   %d tronco(s) pjsip ativo(s), %d conta(s) SIP.\n", count($trunks), Sip::model()->count());
PHP
# o painel (Apache) precisa continuar podendo gravar estes arquivos: dono = usuario do Apache
APU=$(. /etc/apache2/envvars 2>/dev/null; echo "${APACHE_RUN_USER:-}"); id "$APU" >/dev/null 2>&1 || APU=asterisk
chown "$APU":asterisk /etc/asterisk/pjsip_magnus*.conf 2>/dev/null; chmod 0660 /etc/asterisk/pjsip_magnus*.conf 2>/dev/null
SEMPJSIP=$(mariadb mbilling -N -e "SELECT COUNT(*) FROM pkg_trunk WHERE status=1 AND providertech<>'pjsip'")
[ "${SEMPJSIP:-0}" -gt 0 ] && echo "   AVISO: $SEMPJSIP tronco(s) ativo(s) com tecnologia diferente de pjsip (revise em Rotas > Troncos)."

if [ $TESTE -eq 1 ]; then
    crontab -l 2>/dev/null | sed -E '/cron\.php/{/RecurringCredit|SummaryTablesCdr/!s/^([^#])/#TESTE# \1/}' | crontab -
    sed -i -E '/cron\.php cryptocurrency/s/^([^#])/#TESTE# \1/' /etc/crontab
    echo "   MODO TESTE: crontab so com RecurringCredit e SummaryTablesCdr"
fi

echo "== 7/7 Religando os servicos"
religar
sleep 3
if [ $TESTE -eq 0 ]; then
    asterisk -rx 'core show version' 2>/dev/null | sed 's/^/   /'
    asterisk -rx 'pjsip show registrations' 2>/dev/null | tail -3 | sed 's/^/   /'
fi

echo
echo "== Customizacao"
bash "$COM/saude.sh" | sed 's/^/   /'

echo
echo "== Resumo"
mariadb mbilling -t -e "
SELECT g.id AS grupo_id, g.name AS grupo, COUNT(u.id) AS usuarios, SUM(u.active = 1) AS ativos,
       ROUND(SUM(u.credit), 2) AS saldo_total,
       SUM(u.plan_type IS NOT NULL) AS com_plano
FROM pkg_user u JOIN pkg_group_user g ON g.id = u.id_group GROUP BY g.id, g.name;
SELECT COUNT(*) AS troncos_ativos FROM pkg_trunk WHERE status = 1;
SELECT DATE_FORMAT(MIN(starttime), '%d/%m/%Y') AS cdr_desde, DATE_FORMAT(MAX(starttime), '%d/%m/%Y') AS cdr_ate, COUNT(*) AS ligacoes FROM pkg_cdr;"

cat <<FIM

Importacao concluida ($ORIGEM -> $FINAL). Backup do banco anterior: $BKP
Entre no painel com o usuario/senha da PRODUCAO (Ctrl+F5).

Falta conferir/copiar (nao estao no banco):
 - gravacoes (/var/spool/asterisk/monitor), musicas de espera e audios de URA;
 - logos personalizados (resources/images), certificados e scripts proprios;
 - o modulo pago app_mbilling NAO deve ser copiado do MB7 (pedir a versao MB8 a MagnusSolution).
Depois:
 - revise cada tronco/conta PJSIP: asterisk -rx "pjsip show endpoints" / "pjsip show registrations";
 - "Grupos da recarga recorrente" deve ter o ID do grupo dos clientes (veja a tabela acima);
 - se a coluna com_plano estiver zerada: bash $COM/importar-planos.sh --modelo
 - bash $COM/conferir-producao.sh
$( [ $TESTE -eq 1 ] && echo " - MODO TESTE: e-mails no Mailpit; apague o dump depois (tem dados reais)." )
FIM
