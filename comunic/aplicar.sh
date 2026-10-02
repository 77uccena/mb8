#!/bin/bash
#
# Comunic - aplica (ou reaplica) as customizacoes do repositorio no MagnusBilling 8
# instalado em /var/www/html/mbilling:
#   - tipo de plano e valor recorrente no cadastro do usuario (override UserOR)
#   - validacao das configuracoes novas (override ConfigurationOR)
#   - relatorio Relatorios > Consumo por Plano (Relatorio de Recarga)
#   - rotina mensal da recarga recorrente (backup 00:00 / recarga 00:30, Brasilia)
#   - vigia a cada 5 minutos (refaz o index.html/traducoes se uma atualizacao apagar)
#   - conferencia semanal de atualizacao oficial (avisa por e-mail; nao aplica sozinha)
#   - desliga a atualizacao automatica oficial das 01:30 (use comunic/atualizar-mb8.sh)
#
# NAO altera nenhum arquivo oficial do MagnusBilling (usa o mecanismo oficial de
# overrides), nao altera a versao do banco e nao recompila o frontend.
# Pode ser executado quantas vezes quiser.
#
# Uso (como root, de dentro do repositorio clonado):
#   bash comunic/aplicar.sh               confere, faz backup e aplica
#   bash comunic/aplicar.sh --silencioso  sem perguntas e com pouca saida (vigia/atualizacao)
#   bash comunic/aplicar.sh --forcar      aplica mesmo com ERRO de compatibilidade (SO VM)
#
set -u
COM="$(cd "$(dirname "$0")" && pwd)"
. "$COM/lib/comum.sh"
SILENCIOSO=0; FORCAR=0
for A in "$@"; do
    case "$A" in
        --silencioso) SILENCIOSO=1 ;;
        --forcar) FORCAR=1 ;;
        *) echo "Opcao desconhecida: $A"; exit 2 ;;
    esac
done
diga() { [ $SILENCIOSO -eq 1 ] || echo "$@"; }

[ "$(id -u)" = "0" ] || { echo "Rode como root (su -)."; exit 1; }
if [ ! -f "$MB/index.html" ] || [ ! -f "$MB/cron.php" ]; then
    echo "MagnusBilling nao encontrado em $MB. Rode antes o comunic/instalar.sh."; exit 1
fi
case "$REPO" in $MB|$MB/*) echo "O repositorio nao pode ficar dentro de $MB."; exit 1 ;; esac
for F in MANIFEST originais.sha256 traducoes/mesclar.php compat.sh saude.sh vigia.sh; do
    [ -f "$COM/$F" ] || { echo "Arquivo do repositorio ausente: comunic/$F"; exit 1; }
done
LISTA=$(lista_manifest)
for ARQ in $LISTA; do
    [ -f "$REPO/$ARQ" ] || { echo "ERRO: $ARQ (MANIFEST) nao existe no repositorio"; exit 1; }
done

COMMIT=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo "sem-git")
VERSAO=$(versao_banco)
diga "MagnusBilling - versao do banco: ${VERSAO:-desconhecida} (nao sera alterada)"
diga "Repositorio: $REPO (commit $COMMIT)"
mkdir -p "$ESTADO"

diga "== 1/7 Compatibilidade da instalacao atual"
SAIDA=$(bash "$COM/compat.sh" "$MB"); RC=$?
[ $SILENCIOSO -eq 1 ] || echo "$SAIDA" | sed 's/^/   /'
if [ $RC -eq 1 ]; then
    if [ $FORCAR -eq 0 ]; then
        echo "   Instalacao INCOMPATIVEL com as customizacoes (veja os ERRO acima). Nada foi alterado."
        registrar ERRO "aplicar.sh: instalacao incompativel"
        exit 1
    fi
    echo "   --forcar: continuando mesmo assim."
fi

diga "== 2/7 Backup"
BKP=/root/mb8-custom-backup-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BKP"
for ARQ in $LISTA index.html resources/locale/pt_BR.js resources/locale/php/pt_BR/zii.php \
           $(awk '{print $2}' "$COM/originais.sha256"); do
    if [ -f "$MB/$ARQ" ]; then mkdir -p "$BKP/$(dirname "$ARQ")"; cp -p "$MB/$ARQ" "$BKP/$ARQ"; fi
done
crontab -l > "$BKP/crontab-root.txt" 2>/dev/null
mariadb-dump --single-transaction mbilling pkg_user pkg_module pkg_group_module pkg_configuration \
    > "$BKP/tabelas.sql" 2>/dev/null
diga "   $BKP"
# guarda so os 10 backups mais recentes deste tipo
ls -1dt /root/mb8-custom-backup-* 2>/dev/null | tail -n +11 | xargs -r rm -rf

diga "== 3/7 Arquivos oficiais alterados pela versao antiga (v11)"
DEVOLVIDOS=0
while read -r SUM ARQ; do
    [ -n "$ARQ" ] || continue
    if [ -f "$MB/$ARQ" ] && [ "$(sha256sum "$MB/$ARQ" | awk '{print $1}')" = "$SUM" ]; then
        OFI=$(awk -v a="$ARQ" '$2==a {print $1}' "$COM/originais.sha256")
        if [ "$(sha256sum "$REPO/$ARQ" | awk '{print $1}')" = "$OFI" ]; then
            cp "$REPO/$ARQ" "$MB/$ARQ"; chown root:root "$MB/$ARQ"; chmod 644 "$MB/$ARQ"
            diga "   devolvido o oficial: $ARQ"; DEVOLVIDOS=$((DEVOLVIDOS+1))
        else
            echo "   AVISO: $ARQ e da v11, mas o oficial do repositorio nao confere; mantido."
        fi
    fi
done <<< "$V11_ALTERADOS"
[ $DEVOLVIDOS -eq 0 ] && diga "   nenhum (instalacao ja usa os oficiais)"

diga "== 4/7 Copiando arquivos da customizacao"
JS_MUDOU=0
for ARQ in $LISTA; do
    if cmp -s "$REPO/$ARQ" "$MB/$ARQ"; then continue; fi
    [ "$ARQ" = "custom/mb8-custom.js" ] && JS_MUDOU=1
    mkdir -p "$MB/$(dirname "$ARQ")"
    cp "$REPO/$ARQ" "$MB/$ARQ"
    chown root:root "$MB/$ARQ"; chmod 644 "$MB/$ARQ"
    diga "   $ARQ"
done
chmod 755 "$MB/custom" "$MB/protected/models/overrides"
mkdir -p "$MB/protected/runtime/recurring_credit"

diga "== 5/7 Traducoes, index.html e dialplan"
if [ $SILENCIOSO -eq 1 ]; then
    php "$COM/traducoes/mesclar.php" "$MB/resources/locale/pt_BR.js" "$COM/traducoes/pt_BR.js.add" js >/dev/null
    php "$COM/traducoes/mesclar.php" "$MB/resources/locale/php/pt_BR/zii.php" "$COM/traducoes/zii.php.add" php >/dev/null
else
    php "$COM/traducoes/mesclar.php" "$MB/resources/locale/pt_BR.js" "$COM/traducoes/pt_BR.js.add" js
    php "$COM/traducoes/mesclar.php" "$MB/resources/locale/php/pt_BR/zii.php" "$COM/traducoes/zii.php.add" php
fi
php -l "$MB/resources/locale/php/pt_BR/zii.php" >/dev/null || echo "   ERRO de sintaxe em zii.php - restaure de $BKP!"
if [ $JS_MUDOU -eq 1 ] || ! grep -q "custom/mb8-custom.js" "$MB/index.html"; then
    sed -i '/custom\/mb8-custom\.js/d' "$MB/index.html"
    sed -i "s#</body>#    <script type=\"text/javascript\" src=\"custom/mb8-custom.js?v=$(date +%Y%m%d%H%M)\"></script>\n</body>#" "$MB/index.html"
fi
grep -q "custom/mb8-custom.js" "$MB/index.html" && diga "   index.html: script das telas novas incluido" \
    || echo "   AVISO: nao consegui incluir o script no index.html"
[ -f "$EXT_MAGNUS" ] && cp -p "$EXT_MAGNUS" "$BKP/" 2>/dev/null
if MSG=$(garantir_regras55); then
    diga "   dialplan: regras do 55 presentes${MSG:+ ($MSG)}"
else
    echo "   AVISO: nao consegui conferir/colocar as regras do 55 em $EXT_MAGNUS (sem contexto [billing]?)"
fi

diga "== 6/7 Banco e crontab"
# horario de Brasilia -> fuso do servidor
hora_local() { date -d "TZ=\"America/Sao_Paulo\" $1" '+%-M %-H'; }
# mantem o modo da conferencia semanal se alguem trocou para --auto
MODO_VER=--verificar
crontab -l 2>/dev/null | grep '# comunic-verificar$' | grep -q -- '--auto' && MODO_VER=--auto
NOVO=$(crontab -l 2>/dev/null \
    | sed -E 's@^([^#].*protected/commands/update\.sh.*)$@#COMUNIC-atualizacao-manual# \1@' \
    | grep -v '# comunic-vigia$' | grep -v '# comunic-verificar$')
NOVO="$NOVO
*/5 * * * * flock -n /run/lock/mb8-comunic-vigia.lock bash $COM/vigia.sh # comunic-vigia
$(hora_local 07:10) * * 1 bash $COM/atualizar-mb8.sh $MODO_VER --silencioso # comunic-verificar"
printf '%s\n' "$NOVO" | crontab -
diga "   atualizacao automatica oficial desligada; vigia a cada 5 min; conferencia de atualizacao ($MODO_VER) as segundas 07:10 (Brasilia)"
SETUP=$(cd "$MB" && php cron.php PlanConsumptionSetup 2>&1); RCS=$?
[ $SILENCIOSO -eq 1 ] || echo "$SETUP" | sed 's/^/   /'
[ $RCS -eq 0 ] || { echo "   ERRO no PlanConsumptionSetup:"; echo "$SETUP"; }

diga "== 7/7 Conferencia"
if [ $SILENCIOSO -eq 1 ]; then
    bash "$COM/saude.sh" --quieto; RCH=$?
else
    bash "$COM/saude.sh" --completo | sed 's/^/   /'; RCH=${PIPESTATUS[0]}
fi
printf 'repositorio=%s\ncommit=%s\naplicado_em=%s\nversao_banco=%s\nsaude=%s\n' \
    "$REPO" "$COMMIT" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "${VERSAO:-}" "$([ $RCH -eq 0 ] && echo ok || echo FALHA)" \
    > "$MB/custom/APLICADO.txt"

if [ $RCH -eq 0 ] && [ $RCS -eq 0 ]; then
    # esta combinacao (oficial + customizacao) funcionou: vira a base validada
    for ARQ in $DEPENDENCIAS; do [ -f "$MB/$ARQ" ] && (cd "$MB" && sha256sum "$ARQ"); done > "$ESTADO/base-validada.sha256"
    echo "$VERSAO" > "$ESTADO/base-validada.versao"
    registrar OK "aplicar.sh: aplicado (commit $COMMIT, banco $VERSAO)"
else
    registrar ERRO "aplicar.sh: conferencia final com falha (commit $COMMIT)"
fi

if [ $SILENCIOSO -eq 0 ]; then
cat <<FIM

Pronto. Backup do que foi substituido: $BKP
 1. Saia do painel e entre de novo (Ctrl+F5 para limpar o cache).
 2. Clientes > Usuarios > usuario: "Tipo de plano" e "Valor recorrente".
    Relatorios > Consumo por Plano.
 3. Configuracoes > Configuracao: "E-mail do financeiro" e "E-mail de alertas tecnicos".
    Configuracoes > SMTP.
 4. Teste sem gravar nada:  php $MB/cron.php RecurringCredit dryrun
FIM
fi
[ $RCH -eq 0 ] && [ $RCS -eq 0 ] || exit 3
exit 0
