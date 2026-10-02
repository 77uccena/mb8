#!/bin/bash
#
# Comunic - gera de novo a configuracao PJSIP do MagnusBilling (troncos e contas SIP) e
# recarrega o Asterisk.
#
# Antes de gerar, corrige nomes de tronco REPETIDOS (o MB7/chan_sip aceitava, o PJSIP do MB8
# nao: "SIP name ... is used by trunks ..."). O tronco de menor id mantem o nome; os outros
# ganham "-ID" no final (ex.: DATORA-IN, DATORA-IN-41, DATORA-IN-93).
#
#   bash comunic/gerar-pjsip.sh               corrige, gera e recarrega o PJSIP
#   bash comunic/gerar-pjsip.sh --sem-reload  so corrige e gera (usado pelo migrar-dados.sh)
#
# Termina com codigo 1 se o MagnusBilling recusar a configuracao.
#
set -u
RELOAD=1; [ "${1:-}" = "--sem-reload" ] && RELOAD=0
[ "$(id -u)" = "0" ] || { echo "Rode como root."; exit 1; }
MB=/var/www/html/mbilling
q() { mariadb mbilling -N -e "$1"; }

REP=$(q "SELECT GROUP_CONCAT(CONCAT(t.trunkcode, ' (id ', t.id, ') -> ', TRIM(t.trunkcode), '-', t.id) SEPARATOR '; ')
         FROM pkg_trunk t JOIN (SELECT LOWER(TRIM(trunkcode)) k, MIN(id) primeiro FROM pkg_trunk
                               GROUP BY LOWER(TRIM(trunkcode)) HAVING COUNT(*) > 1) d
           ON LOWER(TRIM(t.trunkcode)) = d.k AND t.id <> d.primeiro")
if [ -n "$REP" ] && [ "$REP" != "NULL" ]; then
    q "UPDATE pkg_trunk t JOIN (SELECT LOWER(TRIM(trunkcode)) k, MIN(id) primeiro FROM pkg_trunk
                                GROUP BY LOWER(TRIM(trunkcode)) HAVING COUNT(*) > 1) d
         ON LOWER(TRIM(t.trunkcode)) = d.k AND t.id <> d.primeiro
       SET t.trunkcode = CONCAT(TRIM(t.trunkcode), '-', t.id)"
    echo "   troncos com nome repetido renomeados: $REP"
fi

SAIDA=$(cd "$MB" && php <<'PHP' 2>&1
<?php
require_once 'yii/framework/yii.php';
Yii::createConsoleApplication('protected/config/cron.php');
$trunks = Trunk::model()->findAll(['condition' => 'providertech = :t AND status = 1', 'params' => [':t' => 'pjsip']]);
$a = AsteriskAccess::instance(); $f = '/etc/asterisk/pjsip_magnus.conf';
if (count($trunks)) { $a->writeAsteriskFile($trunks, $f, 'trunkcode'); } else { file_put_contents($f, ''); }
$a->generateSipPeers();
printf("   %d tronco(s) pjsip ativo(s), %d conta(s) SIP.\n", count($trunks), Sip::model()->count());
echo "PJSIP-OK\n";
PHP
)
RC=$?
echo "$SAIDA" | grep -v '^PJSIP-OK$'
# o painel (Apache) precisa continuar podendo gravar estes arquivos: dono = usuario do Apache
APU=$(. /etc/apache2/envvars 2>/dev/null; echo "${APACHE_RUN_USER:-}"); id "$APU" >/dev/null 2>&1 || APU=asterisk
chown "$APU":asterisk /etc/asterisk/pjsip_magnus*.conf 2>/dev/null; chmod 0660 /etc/asterisk/pjsip_magnus*.conf 2>/dev/null
if [ $RC -ne 0 ] || ! echo "$SAIDA" | grep -q '^PJSIP-OK$'; then
    echo
    echo "   ERRO: o MagnusBilling NAO gerou a configuracao PJSIP (veja a mensagem acima)."
    echo "         O Asterisk continua com os arquivos anteriores."
    exit 1
fi
if [ $RELOAD -eq 1 ] && systemctl is-active -q asterisk; then
    asterisk -rx "module reload res_pjsip.so" >/dev/null
    sleep 5
    echo "   Asterisk recarregado: $(asterisk -rx 'pjsip show endpoints' | grep -c '^ Endpoint:') endpoint(s),"\
         "$(asterisk -rx 'pjsip show registrations' | grep -c 'Registered') registro(s) ativos"
fi
exit 0
