<?php

/**
 * Comunic - override do model Configuration (Configuracoes > Configuracao).
 *
 * Carregado pelo mecanismo oficial de overrides do MagnusBilling somente nas
 * requisicoes do modulo "configuration". O protected/models/Configuration.php
 * oficial fica intacto.
 *
 * Acrescenta a validacao das configuracoes da recarga recorrente:
 *   finance_email            e-mails separados por ; ou , (vazio = Admin Email)
 *   comunic_alert_email      idem, para os alertas tecnicos (vigia / atualizacao)
 *   recurring_credit_groups  IDs de grupo separados por virgula
 *   recurring_credit_day     1 a 28
 */
class ConfigurationOR extends Configuration
{
    public static function model($className = __CLASS__)
    {
        return parent::model($className);
    }

    public function checkConfg($attribute, $params)
    {
        parent::checkConfg($attribute, $params);

        $error = false;
        $value = (string) $this->config_value;

        if (in_array($this->config_key, ['finance_email', 'comunic_alert_email']) && trim($value) !== '') {
            foreach (preg_split('/[;,\s]+/', trim($value)) as $email) {
                if ($email !== '' && ! filter_var($email, FILTER_VALIDATE_EMAIL)) {
                    $error = true;
                }
            }
        }

        if ($this->config_key == 'recurring_credit_groups'
            && ! preg_match('/^\s*\d+(\s*[,;]\s*\d+)*\s*$/', $value)) {
            $error = true;
        }

        if ($this->config_key == 'recurring_credit_day'
            && (! ctype_digit($value) || (int) $value < 1 || (int) $value > 28)) {
            $error = true;
        }

        if ($error && ! $this->hasErrors($attribute)) {
            $this->addError($attribute, Yii::t('zii', 'ERROR: Invalid option'));
        }
    }
}
