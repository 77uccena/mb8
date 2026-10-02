#!/bin/bash
#
# Comunic - confere se uma arvore do MagnusBilling (pacote novo extraido, ou a
# instalacao atual) e compativel com as customizacoes. Somente leitura.
#
#   bash comunic/compat.sh /var/lib/mb8-comunic/novo/arvore     (pacote novo)
#   bash comunic/compat.sh                                       (instalacao atual)
#
# Saida: linhas OK / INFO / AVISO / ERRO.  Codigo: 0 = compativel e sem mudancas nas
# dependencias, 2 = compativel mas arquivos de que dependemos mudaram (revisar),
# 1 = incompativel (nao atualizar).
#
set -u
COM="$(cd "$(dirname "$0")" && pwd)"
. "$COM/lib/comum.sh"
D="${1:-$MB}"
ERROS=0; AVISOS=0
ok()   { echo "OK    $*"; }
info() { echo "INFO  $*"; }
aviso(){ echo "AVISO $*"; AVISOS=$((AVISOS+1)); }
erro() { echo "ERRO  $*"; ERROS=$((ERROS+1)); }

[ -f "$D/protected/components/BaseController.php" ] || { erro "nao parece uma arvore do MagnusBilling: $D"; exit 1; }
echo "Conferindo: $D"

# 1. mecanismo oficial de overrides (e por onde entram cadastro e configuracoes)
BC="$D/protected/components/BaseController.php"
if grep -q "protected/config/overrides.php" "$BC" && grep -q "application.models.overrides." "$BC" \
   && grep -q "getOverrideModel" "$BC" && grep -q "\$GLOBALS\['overrides'\]\['models'\]" "$BC"; then
    ok "mecanismo de overrides presente no BaseController"
else
    erro "BaseController sem o mecanismo de overrides: cadastro (plano/valor) e configuracoes deixariam de funcionar"
fi

# 2. classes oficiais que estendemos
grep -q "^class User extends" "$D/protected/models/User.php" 2>/dev/null \
    && grep -q "public function beforeSave()" "$D/protected/models/User.php" \
    && grep -q "public function rules()" "$D/protected/models/User.php" \
    && ok "model User compativel (UserOR)" || erro "model User mudou de forma incompativel com UserOR"
grep -q "^class Configuration extends" "$D/protected/models/Configuration.php" 2>/dev/null \
    && grep -q "public function checkConfg(" "$D/protected/models/Configuration.php" \
    && ok "model Configuration compativel (ConfigurationOR)" || erro "model Configuration sem checkConfg(): validacao das configuracoes"
grep -q "session\['isAdmin'\]" "$D/protected/controllers/AuthenticationController.php" 2>/dev/null \
    && ok "sessao isAdmin presente (permissoes do relatorio e dos campos)" || erro "sessao isAdmin nao encontrada"

# 3. nenhum arquivo nosso pode vir no pacote oficial (seria sobrescrito)
if [ "$D" != "$MB" ]; then
    for ARQ in $(lista_manifest); do
        [ -e "$D/$ARQ" ] && erro "o pacote oficial passou a trazer $ARQ (conflito com a customizacao)"
    done
    for P in protected/models/overrides protected/controllers/overrides; do
        [ -d "$D/$P" ] && aviso "o pacote oficial passou a trazer a pasta $P (conferir conflito)"
    done
    [ $ERROS -eq 0 ] && ok "nenhum arquivo nosso no pacote oficial"
fi

# 4. migracao oficial do banco nao pode mexer nos nossos nomes
UM="$D/protected/commands/UpdateMysqlCommand.php"
if [ -f "$UM" ]; then
    C=0
    for N in $NOMES_BANCO; do
        if grep -q "$N" "$UM"; then erro "a migracao oficial do banco cita '$N' (conflito)"; C=1; fi
    done
    if [ -f "$D/script/database.sql" ]; then
        for N in $NOMES_BANCO; do
            if grep -q "$N" "$D/script/database.sql"; then erro "o banco oficial (database.sql) cita '$N' (conflito)"; C=1; fi
        done
    fi
    [ $C -eq 0 ] && ok "migracao oficial do banco nao usa nomes nossos"
    ALVO=$(grep -oE "\\\$version = '8\.[0-9.]+'" "$UM" | tail -1 | grep -oE "8\.[0-9.]+")
    info "versao do banco que o pacote leva: ${ALVO:-?} (atual: $(versao_banco))"
fi

# 5. frontend: index.html, traducoes e classes do app.js usadas pelo mb8-custom.js
grep -q "</body>" "$D/index.html" 2>/dev/null && ok "index.html tem </body> (onde o script e incluido)" \
    || erro "index.html sem </body>: nao da para incluir o custom/mb8-custom.js"
grep -q "Locale.load({" "$D/resources/locale/pt_BR.js" 2>/dev/null && ok "traducao pt_BR.js no formato esperado" \
    || aviso "pt_BR.js mudou de formato (traducoes novas podem nao entrar)"
grep -q "return array(" "$D/resources/locale/php/pt_BR/zii.php" 2>/dev/null && ok "traducao zii.php no formato esperado" \
    || aviso "zii.php mudou de formato (traducoes novas podem nao entrar)"
# so conta como ERRO nos temas que podem ser escolhidos no painel (lista do
# Configuration.php) e no tema configurado agora; nos demais (ex.: red-classic, antigo)
# e so INFO, porque nunca sao carregados.
SELEC=$(grep -oE "'[a-z]+-(triton|neptune|crisp)'" "$D/protected/models/Configuration.php" 2>/dev/null | tr -d "'" | sort -u)
ATUAL=$(mariadb mbilling -N -e "SELECT config_value FROM pkg_configuration WHERE config_key='template'" 2>/dev/null)
APPS=$(ls "$D"/*/app.js 2>/dev/null)
if [ -z "$APPS" ]; then
    aviso "nenhum app.js compilado encontrado (arvore de codigo-fonte?) - frontend nao conferido"
else
    FALTA=""; IGNORADOS=""; N=0
    for A in $APPS; do
        TEMA=$(basename "$(dirname "$A")")
        USADO=0
        if [ -z "$SELEC" ] || echo "$SELEC" | grep -qx "$TEMA" || [ "$TEMA" = "$ATUAL" ]; then USADO=1; fi
        for T in $TOKENS_FRONTEND; do
            if ! grep -qF "$T" "$A"; then
                if [ $USADO -eq 1 ]; then FALTA="$FALTA $T@$TEMA"; else IGNORADOS="$IGNORADOS $T@$TEMA"; fi
            fi
        done
        [ $USADO -eq 1 ] && N=$((N+1))
    done
    if [ -z "$FALTA" ]; then ok "app.js dos $N tema(s) usados tem todas as classes usadas pelo mb8-custom.js (tema atual: ${ATUAL:-?})"
    else erro "app.js sem classes usadas pelo mb8-custom.js:$FALTA"; fi
    [ -n "$IGNORADOS" ] && info "temas que nao podem ser escolhidos no painel, ignorados:$IGNORADOS"
fi

# 6. dependencias mudaram desde a ultima versao validada?
BASE="$ESTADO/base-validada.sha256"
if [ -f "$BASE" ]; then
    MUD=""
    while read -r SUM ARQ; do
        [ -n "$ARQ" ] || continue
        if [ ! -f "$D/$ARQ" ]; then MUD="$MUD $ARQ(removido)"
        elif [ "$(sha256sum "$D/$ARQ" | awk '{print $1}')" != "$SUM" ]; then MUD="$MUD $ARQ"; fi
    done < "$BASE"
    if [ -z "$MUD" ]; then ok "arquivos oficiais de que dependemos iguais a versao validada"
    else aviso "mudaram desde a versao validada (revisar antes de atualizar):$MUD"; fi
else
    info "sem base validada ainda ($BASE) - sera gravada pelo proximo aplicar.sh bem-sucedido"
fi

echo "Resultado: $ERROS erro(s), $AVISOS aviso(s)"
[ $ERROS -gt 0 ] && exit 1
[ $AVISOS -gt 0 ] && exit 2
exit 0
