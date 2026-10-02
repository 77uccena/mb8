#!/bin/bash
#
# Comunic - atualizacao do MagnusBilling 8 COM CONFERENCIA, no lugar da automatica
# oficial das 01:30 (que fica desligada).
#
#   bash comunic/atualizar-mb8.sh --verificar   baixa o pacote oficial numa pasta separada,
#                                               confere a compatibilidade e mostra/manda o
#                                               relatorio. NAO aplica. (cron: segundas 07:10)
#   bash comunic/atualizar-mb8.sh               confere e, se estiver tudo certo, pergunta e aplica
#   bash comunic/atualizar-mb8.sh --auto        aplica sozinho SO se estiver 100% compativel e
#                                               nenhum arquivo oficial de que dependemos mudou
#
# Opcoes extras: --pacote ARQUIVO.tar.gz (usa um pacote ja baixado em vez de baixar),
# --silencioso (pouca saida, para o cron), --ignorar-janela (permite atualizar
# perto do dia da recarga; por padrao bloqueia de 2 dias antes ate 1 dia depois).
#
# Aplicar = backup (banco + arquivos) -> extrai o MESMO pacote que foi conferido ->
# updateCommand.sh oficial (migracao do banco) -> comunic/aplicar.sh -> saude.sh --completo.
# Se a conferencia final falhar, NAO desfaz sozinho: manda alerta com os comandos para voltar.
#
set -u
COM="$(cd "$(dirname "$0")" && pwd)"
. "$COM/lib/comum.sh"
MODO=interativo; SILENCIOSO=0; IGNJANELA=0; LOCAL=""
while [ $# -gt 0 ]; do
    A="$1"; shift
    case "$A" in
        --pacote) LOCAL="${1:-}"; shift; [ -f "$LOCAL" ] || { echo "Pacote nao encontrado: $LOCAL"; exit 2; } ;;
        --verificar) MODO=verificar ;;
        --auto) MODO=auto ;;
        --silencioso) SILENCIOSO=1 ;;
        --ignorar-janela) IGNJANELA=1 ;;
        *) echo "Opcao desconhecida: $A"; exit 2 ;;
    esac
done
[ "$(id -u)" = "0" ] || { echo "Rode como root."; exit 1; }
[ -f "$MB/index.html" ] || { echo "MagnusBilling nao encontrado em $MB."; exit 1; }

exec 9>/run/lock/mb8-comunic-atualizar.lock
flock -n 9 || { echo "Outra atualizacao/conferencia ja esta rodando."; exit 1; }

NOVO="$ESTADO/novo"; PAC="$NOVO/MagnusBilling8-current.tar.gz"; ARV="$NOVO/arvore"
REL="$NOVO/relatorio-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$NOVO"
r() { echo "$*" >> "$REL"; [ $SILENCIOSO -eq 1 ] || echo "$*"; }

r "Atualizacao do MagnusBilling - $(hostname) - $(date '+%d/%m/%Y %H:%M %Z') - modo $MODO"
r "Versao atual do banco: $(versao_banco)"

# 1. baixar e extrair o pacote oficial (fora do painel)
rm -rf "$ARV" "$PAC"
if [ -n "$LOCAL" ]; then
    cp "$LOCAL" "$PAC"; ORIGEM="$LOCAL"
else
    wget -q --https-only --timeout=60 --tries=3 -O "$PAC" "$PACOTE_URL"; ORIGEM="$PACOTE_URL"
fi
if ! tar tzf "$PAC" >/dev/null 2>&1; then
    r "ERRO: nao consegui obter um pacote valido de $ORIGEM"
    [ "$MODO" = "verificar" ] && [ $SILENCIOSO -eq 1 ] && alertar "MagnusBilling: falha ao conferir atualizacao" "$REL"
    exit 1
fi
mkdir -p "$ARV" && tar xzf "$PAC" -C "$ARV"
SHA=$(sha256sum "$PAC" | awk '{print $1}')
r "Pacote: $(du -h "$PAC" | awk '{print $1}'), sha256 $SHA"

# 2. o que muda em relacao ao instalado
# script/, doc/, assets/ e tmp/ do pacote sao apagados pelo instalador/updateCommand.sh
# oficiais depois de extrair, entao nunca existem na instalacao: nao contam como diferenca.
ignorado() { case "$1" in script/*|doc/*|assets/*|tmp/*) return 0 ;; esac; return 1; }
DIFS=0; NOVOS=0
while IFS= read -r -d '' F; do
    F=${F#./}
    ignorado "$F" && continue
    if [ ! -e "$MB/$F" ]; then NOVOS=$((NOVOS+1)); elif ! cmp -s "$ARV/$F" "$MB/$F"; then DIFS=$((DIFS+1)); fi
done < <(cd "$ARV" && find . -type f ! -name 'MagnusBilling8-current.tar.gz' -print0)
r "Diferencas para o instalado: $DIFS arquivo(s) alterado(s), $NOVOS novo(s)"
# arquivos que a customizacao altera depois de aplicar (index.html e traducoes) sempre diferem
if [ $NOVOS -eq 0 ] && [ $DIFS -le 3 ]; then
    SO_NOSSOS=1
    for F in $(cd "$ARV" && find . -type f | sed 's#^\./##'); do
        case "$F" in index.html|resources/locale/pt_BR.js|resources/locale/php/pt_BR/zii.php) continue ;; esac
        ignorado "$F" && continue
        [ -e "$MB/$F" ] && ! cmp -s "$ARV/$F" "$MB/$F" && { SO_NOSSOS=0; break; }
    done
    if [ $SO_NOSSOS -eq 1 ]; then
        r "Nenhuma versao nova: o instalado ja e este pacote."
        echo "$SHA" > "$ESTADO/ultimo-visto.sha256"
        exit 0
    fi
fi

# 3. compatibilidade
r ""
r "== Compatibilidade com a customizacao Comunic"
COMP=$(bash "$COM/compat.sh" "$ARV"); RCC=$?
r "$COMP"
case $RCC in
    0) VEREDITO="COMPATIVEL (nenhum arquivo de que dependemos mudou)" ;;
    2) VEREDITO="PROVAVELMENTE COMPATIVEL - arquivos de que dependemos mudaram: REVISAR antes de aplicar" ;;
    *) VEREDITO="INCOMPATIVEL - NAO aplicar; o repositorio precisa ser ajustado" ;;
esac
r ""
r "Veredito: $VEREDITO"

# 4. so conferencia
if [ "$MODO" = "verificar" ]; then
    if [ "$(cat "$ESTADO/ultimo-visto.sha256" 2>/dev/null)" != "$SHA" ] || [ $SILENCIOSO -eq 0 ]; then
        [ $SILENCIOSO -eq 1 ] && alertar "MagnusBilling: nova versao oficial - $VEREDITO" "$REL"
        echo "$SHA" > "$ESTADO/ultimo-visto.sha256"
    fi
    r "Nada foi aplicado. Para aplicar: bash $COM/atualizar-mb8.sh"
    exit 0
fi

# 5. pode aplicar?
if janela_da_recarga && [ $IGNJANELA -eq 0 ]; then
    r "BLOQUEADO: perto do dia da recarga (dia $(dia_recarga)). Tente depois ou use --ignorar-janela."
    [ "$MODO" = "auto" ] && alertar "MagnusBilling: atualizacao adiada (dia da recarga)" "$REL"
    exit 1
fi
if [ $RCC -eq 1 ]; then
    r "NAO aplicado: incompativel."
    [ "$MODO" = "auto" ] && alertar "MagnusBilling: atualizacao NAO aplicada (incompativel)" "$REL"
    exit 1
fi
if [ "$MODO" = "auto" ] && [ $RCC -ne 0 ]; then
    r "NAO aplicado automaticamente: precisa de revisao (arquivos de que dependemos mudaram)."
    alertar "MagnusBilling: atualizacao aguardando revisao" "$REL"
    exit 1
fi
if [ -e "$MB/protected/commands/update2.sh" ]; then
    r "NAO aplicado: existe protected/commands/update2.sh (procedimento especial do MagnusBilling). Rode manualmente."
    exit 1
fi
if [ "$MODO" = "interativo" ]; then
    if [ $RCC -eq 2 ]; then
        echo; echo "Arquivos de que dependemos mudaram. Compare antes (exemplo):"
        echo "  diff -u $MB/protected/models/User.php $ARV/protected/models/User.php"
        read -r -p "Ja revisei e quero aplicar. Digite REVISADO: " OK
        [ "$OK" = "REVISADO" ] || { echo "Cancelado."; exit 1; }
    fi
    read -r -p "Aplicar a atualizacao agora? Digite SIM: " OK
    [ "$OK" = "SIM" ] || { echo "Cancelado."; exit 1; }
fi

# 6. aplicar
BKP=/root/mb8-antes-atualizacao-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BKP"
r ""
r "== Aplicando (backup em $BKP)"
mariadb-dump --single-transaction --routines --triggers mbilling | gzip > "$BKP/mbilling.sql.gz" \
    || { r "ERRO no backup do banco. Nada foi aplicado."; exit 1; }
tar czf "$BKP/mbilling-arquivos.tar.gz" -C /var/www/html \
    --exclude='mbilling/protected/runtime' --exclude='mbilling/MagnusBilling8-current.tar.gz' mbilling \
    || { r "ERRO no backup dos arquivos. Nada foi aplicado."; exit 1; }
crontab -l > "$BKP/crontab-root.txt" 2>/dev/null
ANTES=$(versao_banco)

cp "$PAC" "$MB/MagnusBilling8-current.tar.gz"
(cd "$MB" && tar xzf MagnusBilling8-current.tar.gz) || { r "ERRO ao extrair o pacote."; }
if [ -f "$MB/protected/commands/updateCommand.sh" ]; then
    (cd "$MB" && bash protected/commands/updateCommand.sh) >> "$REL" 2>&1; RCU=$?
else
    r "AVISO: updateCommand.sh nao veio no pacote; rodando so a migracao do banco (UpdateMysql)"
    (cd "$MB" && php cron.php UpdateMysql) >> "$REL" 2>&1; RCU=$?
fi
[ -f "$MB/protected/commands/update3.sh" ] && (bash "$MB/protected/commands/update3.sh") >> "$REL" 2>&1
r "Atualizacao oficial: codigo $RCU, banco $ANTES -> $(versao_banco)"

bash "$COM/aplicar.sh" --silencioso >> "$REL" 2>&1; RCA=$?
r "Customizacao reaplicada: codigo $RCA"
r ""
r "== Conferencia final"
SAU=$(bash "$COM/saude.sh" --completo 2>&1); RCS=$?
r "$SAU"
VOLTAR="Para voltar tudo:
  tar xzf $BKP/mbilling-arquivos.tar.gz -C /var/www/html
  gunzip -c $BKP/mbilling.sql.gz | mariadb mbilling
  crontab $BKP/crontab-root.txt"
if [ $RCU -eq 0 ] && [ $RCA -eq 0 ] && [ $RCS -eq 0 ]; then
    echo "$SHA" > "$ESTADO/ultimo-aplicado.sha256"; echo "$SHA" > "$ESTADO/ultimo-visto.sha256"
    r ""; r "ATUALIZADO COM SUCESSO."; r "$VOLTAR"
    registrar OK "atualizar-mb8: aplicado $ANTES -> $(versao_banco)"
    [ "$MODO" = "auto" ] || [ $SILENCIOSO -eq 1 ] && alertar "MagnusBilling atualizado ($ANTES -> $(versao_banco))" "$REL"
    exit 0
fi
r ""; r "ATENCAO: a conferencia final FALHOU. Nada foi desfeito automaticamente."; r "$VOLTAR"
registrar ERRO "atualizar-mb8: conferencia final falhou"
alertar "URGENTE MagnusBilling: atualizacao com falha" "$REL"
exit 1
