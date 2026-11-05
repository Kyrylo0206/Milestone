# Tasks: M1 infrastructure setup

## 0. Spec first
- [ ] 0.1 Закомітити `openspec/changes/m1-infrastructure-setup/` і `docs/adr/0001` до `0003` окремо, перед будь-яким шаблоном чи скриптом, щоб історія Git показувала spec перед кодом
- [ ] 0.2 Підтвердити корінь репозиторію (наявний клон `Milestone/Milestone` чи ця папка) і за потреби перенести файли туди

## 1. Tooling
- [ ] 1.1 Додати `requirements-dev.txt` з `cfn-lint`, `pyyaml`, `pytest`
- [ ] 1.2 Додати `tests/cfn_yaml.py`: підклас `yaml.SafeLoader` з multi-constructor для тегів `!`, щоб CloudFormation YAML парсився (короткі теги стають `{"Fn::X": value}` або `{"Ref": value}`)
- [ ] 1.3 Додати `scripts/lib.sh` (default регіон `us-east-1`, `require_session`, що викликає `sts get-caller-identity`, `evidence_path <topic> <name>`, `run_or_record`, що зберігає stdout або текст помилки і ніколи не перериває скрипт)
- [ ] 1.4 Додати `scripts/lint.sh` (`cfn-lint infra/*.yaml`, потім `validate-template` для кожного, якщо є сесія)

## 2. Network template
- [ ] 2.1 Написати `infra/network.yaml` з параметрами, logical IDs, умовою `CreateNat` і outputs з design D3 до D5
- [ ] 2.2 Написати `infra/params/network-sandbox.json` з явними значеннями всіх параметрів
- [ ] 2.3 Написати `tests/test_network_cidrs.py` (containment, відсутність перетину, зарезервовані діапазони не зачеплені, через `ipaddress`)
- [ ] 2.4 Перевірити, що шаблон не має ресурсу `AWS::IAM::*` (тест)

## 3. IAM template (лише реальний акаунт)
- [ ] 3.1 Написати `infra/iam-readonly.yaml` з параметрами, `ReadOnlyViewPolicy`, `ReadOnlyViewRole` і outputs з design D6, документ policy точно як у `docs/m1-design-decisions.md` §5
- [ ] 3.2 Написати `infra/params/iam-readonly-example.json` з placeholder ID акаунта `111111111111` і прикладом ExternalId
- [ ] 3.3 Написати `scripts/extract-policy.py`, який виводить документ policy як JSON і падає, якщо в ньому є `Ref` або `Fn::`
- [ ] 3.4 Написати `tests/test_readonly_policy.py` (дозволені дієслова, відсутність перетину зі списком deny, обов'язкові дії deny, форма trust policy для обох значень `RequireMfa`)

## 4. Operational scripts
- [ ] 4.1 `scripts/deploy-stack.sh` (change set CREATE або UPDATE, stack tags, вивід змін, `--plan-only`, обробка порожнього change set, очікування)
- [ ] 4.2 `scripts/teardown.sh` (видалити `kvs-app` якщо є, потім `kvs-network`, чекати, вивести секунди)
- [ ] 4.3 `scripts/verify-network.sh` (перевірки зі spec, зберегти вивід, не нуль при помилці)
- [ ] 4.4 `scripts/drift-check.sh`
- [ ] 4.5 `scripts/recreate-timed.sh`
- [ ] 4.6 `scripts/labrole-dissect.sh` (команди з `docs/m1-design-decisions.md` §9.1 до §9.4, прибирання probe ресурсів)
- [ ] 4.7 `scripts/quotas-snapshot.sh` (§9.5)
- [ ] 4.8 `scripts/validate-iam.sh` (§7 кроки 2 до 6, а крок 7 за `--attempt-create`)

## 5. Run in the sandbox (студент)
- [ ] 5.1 Запустити lab, вставити credentials, запустити `scripts/labrole-dissect.sh`
- [ ] 5.2 Написати `docs/labrole.md`: таблиця дозволених і заборонених дій, джерело кожного deny (SCP, identity policy чи implicit) і використаний метод
- [ ] 5.3 Запустити `scripts/quotas-snapshot.sh` і заповнити колонку "Actual" в `docs/m1-budget-and-quotas.md`
- [ ] 5.4 Прочитати ліміт кредиту і витрачену суму, оновити порівняльну таблицю в `docs/m1-budget-and-quotas.md`, внести прогноз M2 у бюджетну таблицю курсу
- [ ] 5.5 `scripts/deploy-stack.sh kvs-network ... --plan-only`, потім deploy, потім `scripts/verify-network.sh`
- [ ] 5.6 Drift демо: змінити вручну значення тега `Name` у VPC, запустити `scripts/drift-check.sh`, потім повернути старе значення
- [ ] 5.7 Необов'язково: демо change set для NAT з `EnableNatGateway=true --plan-only` (не виконувати без потреби)
- [ ] 5.8 Запустити `scripts/validate-iam.sh` і `scripts/validate-iam.sh --attempt-create`
- [ ] 5.9 Запустити `scripts/recreate-timed.sh`, записати час і що зламалось з першої спроби

## 6. Documentation and defense
- [ ] 6.1 README: передумови, bring up, verify, tear down, час recreate, що зламалось вперше, "що змінилось після попереднього milestone" (M1: все нове)
- [ ] 6.2 Отримати AI critique архітектури, зберегти повний запис у `docs/ai-review/m1-critique.md`, написати прийняти чи відхилити з аргументами для 2 до 3 пунктів
- [ ] 6.3 Оновити ADR і `docs/architecture.md`, якщо щось у sandbox суперечило припущенню з позначкою VERIFY
- [ ] 6.4 Прорепетирувати розповідь про реалізацію `infra/network.yaml` і `infra/iam-readonly.yaml` без нотаток
