# Milestone

Це key-value store, який я будую крок за кроком на AWS. Назва проєкту в AWS це `kvs`.

Цей файл про Milestone 1. У M1 ще немає коду бази даних. M1 будує основу, на якій стоять наступні milestone. Це мережа, read-only IAM policy і role як код, та факти про те, що дозволяє sandbox.

## Що входить у M1

| Частина | Файл | Де працює |
|---|---|---|
| Network stack `kvs-network` | `infra/network.yaml` | Learner Lab sandbox |
| Read-only IAM stack `kvs-iam-readonly` | `infra/iam-readonly.yaml` | Лише в реальному акаунті. Sandbox його відхиляє |
| Скрипти | `scripts/` | Мій ноутбук, з credentials від Learner Lab |
| Offline тести | `tests/`, `scripts/test_cidr.py` | Мій ноутбук, AWS не потрібен |
| Рішення | `docs/adr/`, `docs/m1-design-decisions.md` | Лише для читання |
| Spec | `openspec/changes/m1-infrastructure-setup/` | Лише для читання |

Мережа має один VPC `10.20.0.0/16` в `us-east-1`. У ній є два public subnet (`/24`) і два private subnet (`/20`) у двох Availability Zones. Public subnet мають маршрут до Internet Gateway. Private subnet не мають жодного маршруту в інтернет. Вони мають безкоштовний S3 gateway endpoint. NAT gateway є в шаблоні, але за замовчуванням вимкнений, бо коштує приблизно $36 на місяць. Причини описані в `docs/adr/0003-cidr-addressing.md`.

## Перед початком

Потрібні AWS CLI v2, bash, python3 і сесія Learner Lab.

1. Запусти lab. Відкрий AWS Details, потім AWS CLI, і скопіюй credentials у `~/.aws/credentials`. Сесія лаби триває 3 години, потім credentials треба копіювати знову.
2. Встанови регіон і свій handle.

```bash
export AWS_REGION=us-east-1
export OWNER=your-handle
```

3. Встанови локальні інструменти у virtual environment. Без `pyyaml` скрипт `validate-iam.sh` падає на `extract-policy.py`, саме так у мене і сталося з першої спроби.

```bash
python3 -m venv ~/.venvs/kvs
source ~/.venvs/kvs/bin/activate
pip3 install -r requirements-dev.txt
```

Кожен скрипт зупиняється з чітким повідомленням, якщо сесія закінчилась. Жоден скрипт не зберігає credentials.

## Спочатку перевір код offline

```bash
scripts/lint.sh
python3 -I scripts/test_cidr.py
```

`lint.sh` запускає cfn-lint на обох шаблонах, перевіряє що файли параметрів це валідний JSON, запускає тести і запускає `validate-template`, якщо є сесія. Обидва шаблони чисті для cfn-lint.

## Підняти стек

Спочатку подивись на change set. Це нічого не змінює.

```bash
scripts/deploy-stack.sh kvs-network infra/network.yaml infra/params/network-sandbox.json --plan-only
```

Для нового stack AWS після цього залишає його в `REVIEW_IN_PROGRESS`. Це нормально. Запусти ту саму команду без `--plan-only`, щоб створити все.

```bash
scripts/deploy-stack.sh kvs-network infra/network.yaml infra/params/network-sandbox.json
```

Скрипт сам вибирає create або update. Він додає п'ять тегів stack (`Project`, `Milestone`, `Environment`, `Owner`, `ManagedBy`). Якщо change set порожній, скрипт каже про це і завершується з кодом 0. Якщо change set видаляє або може замінити ресурс, скрипт зупиняється і просить `--allow-destructive`.

## Перевірка

```bash
scripts/verify-network.sh
```

Скрипт читає outputs stack і перевіряє справжні ресурси. Він перевіряє VPC CIDR, чотири subnet у двох AZ, public маршрут до IGW, відсутність маршруту до IGW і default route в private таблицях, маршрут S3 endpoint, exports і теги. Код виходу не нуль, якщо будь-яка перевірка не пройшла.

Додаткове ручне підтвердження. Запусти один маленький instance без public IP у private subnet і один у public subnet. З private instance команда `curl https://aws.amazon.com` має вийти за таймаутом. З public вона має спрацювати. Знищ обидва перед teardown, інакше видалення subnet завершиться з `DependencyViolation`.

## Drift і change sets

```bash
scripts/drift-check.sh kvs-network
```

Демо для захисту. Зміни вручну в консолі значення тега `Name` у VPC. Тег `Name` заданий у шаблоні, тому перевірка drift покаже VPC як `MODIFIED`. Потім запусти deploy скрипт. Звичайний change set не показує ручну зміну, бо він порівнює новий шаблон зі старим, а не з живим станом. Drift detection порівнює живий стан зі stack. Після демо поверни тег назад вручну.

Я це запустив у sandbox. Значення тега `Name` у VPC я змінив руками з `kvs-vpc` на `drift-demo-changed-by-hand`. `detect-stack-drift` дав `DRIFTED`, VPC `MODIFIED`, різниця в `/Tags/0/Value` (`docs/evidence/drift/20261105T174053Z-*`). Потім я повернув тег назад. Чи показується як drift новий тег, доданий вручну, я не перевіряв, тому в демо міняю тег, який задає шаблон. Чи ця версія CloudFormation пропонує drift aware change sets, я теж ще не перевірив (VERIFY). Якщо так, речення про change sets правдиве лише для режиму за замовчуванням.

## Teardown і recreate

```bash
scripts/teardown.sh          # shows what exists, deletes nothing
scripts/teardown.sh --yes    # deletes kvs-app if present, then kvs-network
scripts/recreate-timed.sh --yes
```

Порядок фіксований. Stack застосунку йде першим, бо він імпортуватиме exports зі stack мережі. `recreate-timed.sh` видаляє, створює, перевіряє і записує UTC час та секунди в `docs/evidence/recreate/`. `teardown.sh` відмовляється видаляти stack, який не має тега `Project=kvs-capstone`.

Таймінги з `docs/evidence/recreate/20261105T174116Z-recreate.log`. Знесення 51 секунда, створення 90 секунд, перевірка 71 секунда з exit 0 і 45 passed. Разом 212 секунд. Поки це один запуск recreate.

### Що зламалось з першої спроби

Deploy `kvs-network` пройшов з першого разу. Change set мав 16 `Add`, стек дійшов до `CREATE_COMPLETE`. Зламались дві інші речі.

1. `verify-network.sh` перший раз дав 44 passed і 1 failed (`docs/evidence/verify/20261105T173351Z-kvs-network-verify.log`). Bash написав `command substitution: line 35: syntax error near unexpected token 'newline'`, і перевірка статусу стеку впала, хоча стек був `CREATE_COMPLETE`. Причина в тому, що `case ... in A|B) ... ;; esac` стояв усередині `$( ... )`. Bash прочитав `)` після шаблону як кінець command substitution. Я виніс статус у змінну `STACK_STATE`, а `case` поставив окремо. Повторний запуск дав 45 passed і 0 failed (`docs/evidence/verify/20261105T173659Z-kvs-network-verify.log`).
2. Перший запуск `validate-iam.sh` впав на `extract-policy.py`, бо в системному `python3` не було `pyyaml`. Я створив virtual environment і поставив `requirements-dev.txt`. Після цього скрипт пройшов до кінця. Текст цієї помилки я в `docs/evidence` не зберіг.

## Факти про sandbox

```bash
scripts/labrole-dissect.sh                         # who am I, LabRole policies, simulation, dry-run probes
scripts/labrole-dissect.sh --include-write-probes  # also tries to create an IAM policy and role, deletes them at once if it works
scripts/quotas-snapshot.sh                         # service quotas and account limits
```

Відхилений виклик не зупиняє ці скрипти. Текст помилки зберігається, бо помилка теж є доказом. З тексту я можу зрозуміти, звідки береться deny. "Explicit deny in a service control policy" означає політику організації. "Explicit deny in an identity-based policy" означає policy role. "No identity-based policy allows" означає implicit deny. Результат записаний у `docs/labrole.md`, а колонка Actual заповнена в `docs/m1-budget-and-quotas.md`. Коротко. Моя сесія це роль `voclabs`, а ролі `LabRole` у цьому акаунті немає (`NoSuchEntity`). IAM writes заборонені, `m5.4xlarge` заборонений identity policy, `eu-central-1` заборонений SCP, а `create-vpc` і `t3.micro` у dry-run дозволені.

## Read-only частина IAM

Sandbox не дозволяє мені створювати IAM roles, тому я не можу задеплоїти цей stack там. Замість цього я перевіряю його наскільки можу. У sandbox `validate-policy` дав порожній список findings, `simulate-custom-policy` дав усі 6 очікуваних рішень, а `check-access-not-granted` заборонений (implicit deny). Спроба створити stack закінчилась `ROLLBACK_COMPLETE`, бо `ReadOnlyViewPolicy` отримав `CREATE_FAILED` з AccessDenied на `iam:CreatePolicy` (`docs/evidence/iam/`).

```bash
scripts/validate-iam.sh                    # lint, validate-template, Access Analyzer, policy simulation
scripts/validate-iam.sh --attempt-create   # one real create attempt, saves the refusal, deletes the stack
```

Policy `kvs-readonly-view` дозволяє лише describe, list і кілька get дій над конфігурацією. Вона явно забороняє читати дані, наприклад `s3:GetObject`, `dynamodb:Scan`, `secretsmanager:GetSecretValue` і `lambda:InvokeFunction`. Та сама policy прикріплена до role і задана як її permissions boundary. Цю role може прийняти лише один principal, з ExternalId, і з MFA якщо `RequireMfa` дорівнює `true`. Я не використав AWS managed `ReadOnlyAccess`, бо вона може читати дані. `ViewOnlyAccess` це найближча managed policy і мій запасний варіант.

## Evidence

Усі скрипти пишуть сирий вивід у `docs/evidence/<topic>/<UTC time>-<name>`. Цю папку я комічу, бо це доказ для захисту. Я читаю кожен файл перед комітом. У файлах є ID акаунта і ARN ролей, а credentials жоден скрипт не записує ніколи. Встанови `EVIDENCE_DIR`, щоб писати в інше місце.

## Що змінилось після попереднього milestone

Це перший milestone, тому все нове. До M1 у репозиторії були лише LICENSE і один рядок README. M1 додає шаблон мережі, шаблон IAM, скрипти, offline тести, три ADR, spec в `openspec/`, нотатки про архітектуру та план бюджету і quotas для M2.

## Обмеження цієї версії

Код я писав без credentials, а 5 листопада 2026 року запустив усі скрипти в Learner Lab (акаунт `500819826436`, `us-east-1`). Докази лежать у `docs/evidence/`. Шаблони і policy проходять cfn-lint, Python тести і `bash -n`. Що досі не перевірено: drift aware change sets, `us-west-2`, повний список дозволених типів instance, чи є в акаунті `LabInstanceProfile`, і ручна перевірка з instance у private subnet.
