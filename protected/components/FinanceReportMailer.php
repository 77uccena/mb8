<?php

/**
 * Envia e-mails com anexos para o financeiro usando o SMTP do administrador
 * (Configuracoes > SMTP). O componente Mail padrao nao suporta anexos.
 */
class FinanceReportMailer
{
    /**
     * Converte "a@x.com; b@y.com, c@z.com" em lista de e-mails validos.
     */
    public static function parseAddresses($value)
    {
        $list = [];
        foreach (preg_split('/[;,\s]+/', (string) $value) as $email) {
            $email = trim($email);
            if ($email !== '' && filter_var($email, FILTER_VALIDATE_EMAIL)) {
                $list[] = $email;
            }
        }
        return array_values(array_unique($list));
    }

    /**
     * @param array  $to          lista de e-mails
     * @param string $subject
     * @param string $html
     * @param array  $attachments caminho do arquivo => nome exibido
     * @return true|string true em caso de sucesso, ou a mensagem de erro
     */
    public static function send(array $to, $subject, $html, array $attachments = [])
    {
        if (! count($to)) {
            return 'no recipient';
        }

        $smtp = Smtps::model()->find('id_user = 1');
        if (! isset($smtp->id) || $smtp->host == '' || $smtp->host == 'mail.magnusbilling.com'
            || $smtp->username == '' || $smtp->password == '' || $smtp->port == '') {
            return 'admin SMTP not configured';
        }

        Yii::import('application.extensions.phpmailer.JPhpMailer');
        $mail = new JPhpMailer;
        $mail->IsSMTP();
        $mail->SMTPAuth = true;
        $mail->Host     = $smtp->host;
        $mail->Username = $smtp->username;
        $mail->Password = $smtp->password;
        $mail->Port     = $smtp->port;

        if ($smtp->port == 465) {
            $mail->SMTPSecure = 'ssl';
        } elseif ($smtp->port == 587) {
            $mail->SMTPSecure = 'tls';
        } else {
            $mail->SMTPSecure = $smtp->encryption == 'null' ? '' : $smtp->encryption;
        }

        $mail->CharSet = 'utf-8';
        $mail->SetFrom($smtp->username, 'MagnusBilling');
        $mail->Subject = $subject;
        $mail->MsgHTML($html);
        $mail->AltBody = strip_tags($html);

        foreach ($to as $email) {
            $mail->AddAddress($email);
        }
        foreach ($attachments as $path => $name) {
            if (is_file($path)) {
                $mail->AddAttachment($path, $name);
            }
        }

        ob_start();
        $ok = @$mail->Send();
        ob_end_clean();

        return $ok ? true : ('send failed: ' . $mail->ErrorInfo);
    }
}
