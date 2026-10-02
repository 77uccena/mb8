-- Tipo de plano / Valor recorrente / Relatorio "Consumo por Plano"
-- Use SOMENTE se nao puder rodar o comando que ja aplica tudo isto
-- (os arquivos continuam precisando do comunic/aplicar.sh: overrides, telas e cron):
--   php /var/www/html/mbilling/cron.php PlanConsumptionSetup
-- (nao altera a versao do banco, para nao conflitar com as atualizacoes oficiais)

ALTER TABLE `pkg_user`
  ADD COLUMN IF NOT EXISTS `plan_type` VARCHAR(20) NULL DEFAULT NULL AFTER `contract_value`,
  ADD COLUMN IF NOT EXISTS `recurring_value` DECIMAL(15,4) NOT NULL DEFAULT '0.0000' AFTER `plan_type`,
  ADD INDEX IF NOT EXISTS `idx_pkg_user_plan_type` (`plan_type`);

INSERT INTO pkg_module (text, module, icon_cls, id_module, priority)
SELECT 't(''Consumption per Plan'')', 'planconsumption', 'x-fa fa-desktop', 9, 15
WHERE NOT EXISTS (SELECT 1 FROM pkg_module WHERE module = 'planconsumption');

INSERT INTO pkg_group_module (id_group, id_module, action, show_menu, createShortCut, createQuickStart)
SELECT 1, m.id, 'r', 1, 0, 0 FROM pkg_module m
WHERE m.module = 'planconsumption'
  AND NOT EXISTS (SELECT 1 FROM pkg_group_module gm WHERE gm.id_group = 1 AND gm.id_module = m.id);

-- Recarga mensal do valor recorrente (aparece em Faturamento > Recargas).
-- Adicione no crontab do root (crontab -e):
-- 0 0 * * * php /var/www/html/mbilling/cron.php RecurringCredit backup
-- 30 0 * * * php /var/www/html/mbilling/cron.php RecurringCredit

INSERT INTO pkg_configuration (config_title, config_key, config_value, config_description, config_group_title, status)
SELECT 'E-mail do financeiro', 'finance_email', '', 'E-mail(s) que recebem os relatorios mensais da recarga recorrente (separe varios com ;). Vazio = Admin Email.', 'global', 1
WHERE NOT EXISTS (SELECT 1 FROM pkg_configuration WHERE config_key = 'finance_email');
INSERT INTO pkg_configuration (config_title, config_key, config_value, config_description, config_group_title, status)
SELECT 'Grupos da recarga recorrente', 'recurring_credit_groups', '3', 'IDs dos grupos de usuarios que recebem a recarga do valor recorrente, separados por virgula. 3 = Cliente.', 'global', 1
WHERE NOT EXISTS (SELECT 1 FROM pkg_configuration WHERE config_key = 'recurring_credit_groups');
INSERT INTO pkg_configuration (config_title, config_key, config_value, config_description, config_group_title, status)
SELECT 'Dia da recarga recorrente', 'recurring_credit_day', '20', 'Dia do mes (1 a 28) da rotina da recarga recorrente: backup as 00:00 e recarga as 00:30.', 'global', 1
WHERE NOT EXISTS (SELECT 1 FROM pkg_configuration WHERE config_key = 'recurring_credit_day');

INSERT INTO pkg_configuration (config_title, config_key, config_value, config_description, config_group_title, status)
SELECT 'E-mail de alertas tecnicos', 'comunic_alert_email', '', 'E-mail(s) que recebem os alertas do vigia e da atualizacao do MagnusBilling (separe varios com ;). Vazio = Admin Email.', 'global', 1
WHERE NOT EXISTS (SELECT 1 FROM pkg_configuration WHERE config_key = 'comunic_alert_email');

-- Foto de cada recarga recorrente (saldo antes da recarga) - base do Relatorio de Recarga
CREATE TABLE IF NOT EXISTS `pkg_recurring_credit` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `id_user` INT NOT NULL,
  `month` CHAR(6) NOT NULL,
  `plan_type` VARCHAR(20) NOT NULL,
  `recurring_value` DECIMAL(15,4) NOT NULL,
  `credit_before` DECIMAL(15,4) NOT NULL,
  `refill` DECIMAL(15,4) NOT NULL,
  `id_refill` INT NULL,
  `date` DATETIME NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_recurring_credit_user_month` (`id_user`, `month`),
  KEY `idx_recurring_credit_month` (`month`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
