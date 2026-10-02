<?php

/**
 * Comunic - override do model User (Clientes > Usuarios).
 *
 * Carregado pelo mecanismo oficial de overrides do MagnusBilling
 * (BaseController::getOverrideModel + protected/config/overrides.php) SOMENTE nas
 * requisicoes do modulo "user". O arquivo oficial protected/models/User.php fica
 * intacto e a atualizacao oficial nao sobrescreve esta pasta.
 *
 * Campos novos (criados pelo PlanConsumptionSetup):
 *   plan_type        unlimited | franchise | minutes | NULL
 *   recurring_value  valor da recarga mensal (>= 0)
 *
 * Somente o administrador ve e altera esses campos. Para cliente e revenda (agente)
 * eles nao aparecem na leitura e nao sao gravados (o banco mantem o valor atual).
 */
class UserOR extends User
{
    public static $planTypes = ['unlimited', 'franchise', 'minutes'];

    public static function model($className = __CLASS__)
    {
        return parent::model($className);
    }

    public function rules()
    {
        $rules   = parent::rules();
        $rules[] = ['recurring_value', 'numerical', 'min' => 0, 'max' => 999999999];
        $rules[] = ['plan_type', 'in', 'range' => array_merge([''], self::$planTypes), 'allowEmpty' => true];
        return $rules;
    }

    /**
     * Esconde os campos de plano de quem nao e administrador. Vale para a leitura
     * (lista/formulario) e para a gravacao (insert/update usam getAttributes), entao
     * cliente e revenda nao conseguem alterar o plano nem o valor recorrente.
     */
    public function getAttributes($names = true)
    {
        $attributes = parent::getAttributes($names);
        if (! self::isAdminSession()) {
            unset($attributes['plan_type'], $attributes['recurring_value']);
        }
        return $attributes;
    }

    public function beforeSave()
    {
        if (self::isAdminSession()) {
            $this->recurring_value = ($this->recurring_value === '' || $this->recurring_value === null)
                ? 0 : $this->recurring_value;
            $this->plan_type = ($this->plan_type === '' || $this->plan_type === null) ? null : $this->plan_type;
        }
        return parent::beforeSave();
    }

    public static function isAdminSession()
    {
        return Yii::app() instanceof CWebApplication
            && ! empty(Yii::app()->session['isAdmin']);
    }
}
