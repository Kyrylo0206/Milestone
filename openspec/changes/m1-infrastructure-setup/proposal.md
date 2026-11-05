# Change: M1 infrastructure setup

## Why

Capstone потребує основи, на якій можна стояти, ще до того як у M2 з'явиться будь-який key-value код. Мені потрібна мережа, яку я можу створити, знищити і створити знову лише з коду. Мені потрібно знати, що AWS Academy sandbox дозволяє робити, а що відхиляє. Також мені потрібно знати, чи вміщається дизайн M2 з 2 shards у кредит sandbox. Я ще маю здати read-only IAM policy і assumable role як код, хоча sandbox не дозволить мені їх створити, і пояснити відмову доказами.

## What Changes

- Додати CloudFormation шаблон `infra/network.yaml` (stack `kvs-network`): VPC `10.20.0.0/16` в `us-east-1`, два public /24 subnet з маршрутом до Internet Gateway, два private /20 subnet без маршруту в інтернет, одна public і дві private route tables, безкоштовний S3 gateway endpoint для private tier, і NAT gateway, який за замовчуванням вимкнений за параметром `EnableNatGateway`. Усі ID експортуються для майбутнього stack `kvs-app`.
- Додати CloudFormation шаблон `infra/iam-readonly.yaml` (stack `kvs-iam-readonly`, лише реальний акаунт): customer-managed policy `kvs-readonly-view`, яка дозволяє лише перегляд metadata ресурсів і явно забороняє читання data-plane, та role `kvs-readonly-viewer`, яку один довірений principal може прийняти з ExternalId (необов'язково MFA), з тією самою policy як permissions boundary.
- Додати скрипти для deploy через change set, teardown, перевірки мережі, перевірки drift, timed recreate, розбору LabRole, знімка quotas і IAM validation. Усі вони зберігають сирий вивід у `docs/evidence/`, яке комітиться. `teardown.sh` видаляє лише stacks з тегом `Project=kvs-capstone`.
- Додати offline тести: CIDR containment і відсутність перетину, дієслова read-only policy.
- Додати docs: ADR 0001 (CloudFormation), ADR 0002 (окремі stacks з Exports), ADR 0003 (схема CIDR, NAT вимкнений, S3 endpoint), architecture, design decisions, quotas і бюджет M2, знахідки по LabRole, запис AI critique, README з bring-up, verify і що змінилось.

## Impact

- Affected specs: нова capability `infra`.
- Affected code: нові `infra/`, `scripts/`, `tests/`, `docs/`, `README.md`. Нічого існуючого не змінюється, бо це перший milestone.
- Cost: $0 на місяць у такому вигляді, як задеплоєно. Вмикання `EnableNatGateway` коштує приблизно $36.50 на місяць.
- Risks: дозволи sandbox можуть бути суворішими, ніж я припускав (наприклад, немає `iam:SimulateCustomPolicy` або немає Access Analyzer). У такому разі відповідний крок validation замінюється записаною помилкою і скриншотом консолі. Network stack не можна видалити, поки майбутній stack `kvs-app` імпортує його exports, і це задумано.
- Наступні milestone залежать від імен exports, визначених тут. Перейменування їх пізніше це breaking change.
