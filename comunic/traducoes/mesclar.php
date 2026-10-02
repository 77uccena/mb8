<?php
/**
 * Acrescenta ao arquivo de traducao somente as chaves que ainda nao existem
 * (nao altera as existentes). Usado pelo aplicar.sh.
 *
 *   php mesclar.php resources/locale/pt_BR.js comunic/traducoes/pt_BR.js.add js
 *   php mesclar.php resources/locale/php/pt_BR/zii.php comunic/traducoes/zii.php.add php
 */
if ($argc < 4) {
    fwrite(STDERR, "Uso: php mesclar.php ARQUIVO ADICOES js|php\n");
    exit(2);
}
list(, $file, $add, $tipo) = $argv;
$s     = file_get_contents($file);
$sep   = $tipo === 'js' ? ':' : '=>';
$novas = [];
foreach (file($add) as $l) {
    if (! preg_match("/^\s*'([^']+)'\s*(:|=>)/", $l, $m)) {
        continue;
    }
    if (! preg_match("/'" . preg_quote($m[1], '/') . "'\s*" . preg_quote($sep, '/') . '/', $s)) {
        $novas[] = $l;
    }
}
if (! $novas) {
    echo "   traducoes ja presentes em $file\n";
    exit(0);
}
$abre = $tipo === 'js' ? "/Locale\.load\(\{\r?\n/" : "/return array\(\r?\n/";
$ini  = $tipo === 'js' ? "Locale.load({\n" : "return array(\n";
$n    = preg_replace($abre, $ini . "    // mb8-custom:\n" . implode('', $novas), $s, 1, $c);
if (! $c) {
    echo "   AVISO: nao consegui inserir traducoes em $file\n";
    exit(1);
}
file_put_contents($file, $n);
echo '   ' . count($novas) . " traducao(oes) adicionada(s) em $file\n";
