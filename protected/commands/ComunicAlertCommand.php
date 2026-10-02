<?php

/**
 * Comunic - envia um alerta tecnico por e-mail (vigia, atualizacao, conferencia).
 *
 *   php /var/www/html/mbilling/cron.php ComunicAlert "assunto" /caminho/relatorio.txt
 *
 * Destino: configuracao "comunic_alert_email" se existir e estiver preenchida,
 * senao o Admin Email. Usa o SMTP do administrador (Configuracoes > SMTP).
 */
class ComunicAlertCommand extends CConsoleCommand
{
    public function run($args)
    {
        $subject = isset($args[0]) ? $args[0] : 'MagnusBilling - alerta';
        $file    = isset($args[1]) ? $args[1] : '';
        $body    = ($file !== '' && is_file($file)) ? file_get_contents($file) : (string) $file;

        $to = '';
        foreach (['comunic_alert_email', 'admin_email'] as $key) {
            $value = Yii::app()->db->createCommand(
                'SELECT config_value FROM pkg_configuration WHERE config_key = :k'
            )->queryScalar([':k' => $key]);
            if (trim((string) $value) !== '') {
                $to = $value;
                break;
            }
        }

        $html   = '<pre style="font-family:monospace;font-size:12px">' . htmlspecialchars($body) . '</pre>';
        $result = FinanceReportMailer::send(FinanceReportMailer::parseAddresses($to), $subject, $html);
        echo '[ComunicAlert] ' . ($result === true ? 'enviado para ' . $to : 'NAO enviado: ' . $result) . PHP_EOL;
    }
}
