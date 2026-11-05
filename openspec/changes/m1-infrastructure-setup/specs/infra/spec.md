# infra

## ADDED Requirements

### Requirement: Infrastructure as Code with CloudFormation
Уся AWS інфраструктура проєкту SHALL бути визначена в CloudFormation YAML шаблонах у `infra/` і SHALL розгортатися лише через change sets, створені `scripts/deploy-stack.sh`.

#### Scenario: Шаблон проходить lint і validation
- **WHEN** запускається `scripts/lint.sh`
- **THEN** `cfn-lint` не повідомляє про помилки для жодного файлу в `infra/*.yaml`
- **AND** `aws cloudformation validate-template` проходить для кожного шаблону, коли є credentials

#### Scenario: Deploy показує diff перед застосуванням
- **WHEN** запускається `scripts/deploy-stack.sh kvs-network infra/network.yaml infra/params/network-sandbox.json --plan-only`
- **THEN** створюється change set, і його зміни виводяться з action, logical ID, resource type і replacement
- **AND** жоден ресурс не створюється і не змінюється

#### Scenario: Порожній change set це не помилка
- **WHEN** deploy скрипт запускається для stack, який уже збігається з шаблоном
- **THEN** скрипт видаляє порожній change set і завершується з кодом 0

### Requirement: Separate network stack with exports
Мережа SHALL жити у власному stack `kvs-network` і SHALL експортувати кожен ID, який потрібен наступним stacks, під іменем `${AWS::StackName}-<OutputName>`.

#### Scenario: Exports існують після deploy
- **WHEN** stack `kvs-network` у стані `CREATE_COMPLETE`
- **THEN** `aws cloudformation list-exports` містить `kvs-network-VpcId`, `kvs-network-VpcCidr`, `kvs-network-PublicSubnet1Id`, `kvs-network-PublicSubnet2Id`, `kvs-network-PrivateSubnet1Id`, `kvs-network-PrivateSubnet2Id`, `kvs-network-PublicSubnetIds`, `kvs-network-PrivateSubnetIds`, `kvs-network-AvailabilityZones`, `kvs-network-PublicRouteTableId`, `kvs-network-PrivateRouteTable1Id`, `kvs-network-PrivateRouteTable2Id` і `kvs-network-S3GatewayEndpointId`

#### Scenario: IAM ресурсів немає в network stack
- **WHEN** перевіряється `infra/network.yaml`
- **THEN** він не містить жодного ресурсу типу `AWS::IAM::*`

### Requirement: VPC addressing
VPC SHALL використовувати CIDR `10.20.0.0/16` і SHALL містити public subnets `10.20.0.0/24` та `10.20.1.0/24` і private subnets `10.20.16.0/20` та `10.20.32.0/20`, з одним public і одним private subnet у кожній з перших двох Availability Zones регіону.

#### Scenario: Subnets вміщаються у VPC і не перетинаються
- **WHEN** `pytest tests/test_network_cidrs.py` запускається на defaults шаблону і на `infra/params/network-sandbox.json`
- **THEN** CIDR кожного subnet є підмережею CIDR VPC
- **AND** жодні два CIDR subnet не перетинаються
- **AND** жоден subnet не перетинається із зарезервованими діапазонами `10.20.2.0/24`, `10.20.48.0/20`, `10.20.64.0/18` і `10.20.128.0/17`

#### Scenario: Використовуються дві Availability Zones
- **WHEN** `scripts/verify-network.sh` запускається після deploy
- **THEN** чотири subnets охоплюють рівно дві різні Availability Zones
- **AND** кожна Availability Zone має один public і один private subnet

### Requirement: Public subnets reach the internet through an IGW
Public subnets SHALL бути прив'язані до route table, яка має маршрут `0.0.0.0/0` до Internet Gateway цього stack, і SHALL призначати public IPv4 адреси при запуску.

#### Scenario: Public route перевірено
- **WHEN** запускається `scripts/verify-network.sh`
- **THEN** route table, прив'язана до обох public subnets, має маршрут `0.0.0.0/0`, чия ціль починається з `igw-`
- **AND** обидва public subnets мають `MapPublicIpOnLaunch=true`

### Requirement: Private subnets are internal only
Private subnets SHALL не мати маршруту до Internet Gateway і, поки `EnableNatGateway` дорівнює `false`, SHALL не мати жодного маршруту `0.0.0.0/0`. Вони SHALL мати маршрут до S3 через gateway VPC endpoint.

#### Scenario: Private routes перевірено з вимкненим NAT
- **WHEN** stack розгорнуто з параметрами за замовчуванням і запускається `scripts/verify-network.sh`
- **THEN** жодна з private route tables не має маршруту, чия ціль починається з `igw-`
- **AND** жодна з private route tables не має маршруту `0.0.0.0/0`
- **AND** обидві private route tables мають маршрут до S3 prefix list через ціль `vpce-`
- **AND** обидва private subnets мають `MapPublicIpOnLaunch=false`

#### Scenario: NAT можна ввімкнути параметром
- **WHEN** stack оновлюється з `EnableNatGateway=true`
- **THEN** change set додає `NatEip`, `NatGateway`, `PrivateDefaultRoute1` і `PrivateDefaultRoute2` і більше нічого не змінює
- **AND** після виконання обидві private route tables мають `0.0.0.0/0` до цілі `nat-`

### Requirement: Read-only policy as code
`infra/iam-readonly.yaml` SHALL визначати customer-managed policy `kvs-readonly-view`, яка дозволяє лише дії перегляду і явно забороняє читання data-plane та доступ до secrets. Документ policy SHALL не містити intrinsic functions.

#### Scenario: Дозволені лише дієслова перегляду
- **WHEN** запускається `pytest tests/test_readonly_policy.py`
- **THEN** кожна дія в Allow statement має дієслово, що починається з `Describe`, `List`, `Get` або `View`, або дорівнює `apigateway:GET`
- **AND** жодна дія Allow не збігається з жодною дією в Deny statement, включно з wildcard
- **AND** Deny statement містить щонайменше `s3:GetObject`, `dynamodb:GetItem`, `dynamodb:Query`, `dynamodb:Scan`, `secretsmanager:GetSecretValue`, `kms:Decrypt` і `lambda:InvokeFunction`

#### Scenario: Simulator підтверджує read-only поведінку
- **WHEN** `scripts/validate-iam.sh` запускає `aws iam simulate-custom-policy` з витягнутою policy
- **THEN** `ec2:DescribeVpcs` і `s3:ListAllMyBuckets` мають `allowed`
- **AND** `ec2:CreateVpc` і `iam:CreateRole` мають `implicitDeny`
- **AND** `s3:GetObject` і `dynamodb:Scan` мають `explicitDeny`
- **AND** якщо сам виклик simulator відхилено, скрипт зберігає текст помилки в `docs/evidence/iam/` і продовжує

### Requirement: Assumable read-only role as code
`infra/iam-readonly.yaml` SHALL визначати role `kvs-readonly-viewer`, яку може прийняти лише `TrustedPrincipalArn`, лише з відповідним `sts:ExternalId`, і з обов'язковим MFA, коли `RequireMfa` дорівнює `true`. Role SHALL мати `kvs-readonly-view` і прикріпленою, і заданою як permissions boundary.

#### Scenario: Wildcard principal відхиляється параметром
- **WHEN** `TrustedPrincipalArn` містить `*`
- **THEN** `AllowedPattern` параметра відхиляє його до створення будь-якого ресурсу

#### Scenario: Обмеження тривалості сесії
- **WHEN** role створюється
- **THEN** `MaxSessionDuration` між 3600 і 43200 секундами, а це діапазон, який IAM приймає для role
- **AND** викликач усе ще може попросити коротшу сесію до 900 секунд через `--duration-seconds`

#### Scenario: Форма trust policy
- **WHEN** шаблон рендериться з `RequireMfa=false`
- **THEN** trust policy має один Allow statement для `sts:AssumeRole` з principal, що дорівнює `TrustedPrincipalArn`, і умовою `StringEquals sts:ExternalId`
- **AND** жоден statement не використовує wildcard principal

#### Scenario: Умова MFA додається на запит
- **WHEN** шаблон рендериться з `RequireMfa=true`
- **THEN** умова trust також містить `Bool aws:MultiFactorAuthPresent = true`

### Requirement: Sandbox refusal is evidenced
Проєкт SHALL записати сирим виводом CLI, як sandbox відхиляє IAM stack.

#### Scenario: Відмову зафіксовано
- **WHEN** `scripts/validate-iam.sh --attempt-create` запускається в sandbox
- **THEN** він пробує `create-stack` для `kvs-iam-readonly` з `CAPABILITY_NAMED_IAM`, чекає на кінцевий стан, зберігає `describe-stack-events` у `docs/evidence/iam/` і видаляє невдалий stack
- **AND** збережені events містять `ResourceStatusReason`, який називає заборонену дію IAM

### Requirement: LabRole dissection with method
Проєкт SHALL записати, що LabRole і role викликача дозволяють і забороняють, а для кожної знахідки використаний метод (читання policies через CLI, policy simulator, dry-run probe або текст помилки).

#### Scenario: Dissection запущено
- **WHEN** `scripts/labrole-dissect.sh` запускається в sandbox
- **THEN** він зберігає ідентичність викликача, trust policies roles, документи прикріплених і inline policies, результати simulation і вивід probes у `docs/evidence/labrole/`
- **AND** відхилений виклик не зупиняє скрипт, замість цього зберігається текст його помилки
- **AND** будь-який probe ресурс, створений несподівано, видаляється перед виходом зі скрипта

### Requirement: Quotas and budget for M2
Проєкт SHALL записати service quotas, які можуть обмежити M2, і параметризований місячний бюджет M2 для 2 shards у порівнянні з кредитом sandbox.

#### Scenario: Знімок quotas збережено
- **WHEN** запускається `scripts/quotas-snapshot.sh`
- **THEN** він зберігає вивід Service Quotas для `vpc`, `ec2`, `ebs`, `lambda`, `dynamodb`, `apigateway`, `ecs`, `fargate`, `elasticloadbalancing`, `logs` і `cloudformation`, плюс `lambda get-account-settings`, `dynamodb describe-limits` і `ec2 describe-account-attributes`

#### Scenario: Бюджет порівняно з лімітом
- **WHEN** переглядається `docs/m1-budget-and-quotas.md`
- **THEN** він показує формули, щонайменше один сценарій, розрахований рядок за рядком, і відсоток підтвердженого ліміту кредиту, який використав би M2

### Requirement: Recreatability
Network stack SHALL бути можливо знищити і створити знову лише з репозиторію, а тривалість і збої першої спроби SHALL бути записані.

#### Scenario: Timed recreate
- **WHEN** запускається `scripts/recreate-timed.sh`
- **THEN** він видаляє `kvs-network`, створює його знову через change set, запускає `scripts/verify-network.sh` і записує UTC часові мітки та тривалість для teardown, create і verify у `docs/evidence/recreate/`
- **AND** скрипт завершується з ненульовим кодом, якщо verification не пройшла

#### Scenario: Teardown видаляє лише stacks проєкту
- **WHEN** `scripts/teardown.sh --yes` знаходить цільовий stack без stack tag `Project=kvs-capstone`
- **THEN** він нічого не видаляє і завершується з ненульовим кодом

#### Scenario: Drift можна виявити
- **WHEN** значення тега `Name` у VPC змінено вручну в консолі і запускається `scripts/drift-check.sh kvs-network`
- **THEN** вивід показує VPC як `MODIFIED`

### Requirement: Mandatory tagging
Кожен stack SHALL розгортатися зі stack tags `Project=kvs-capstone`, `Milestone=m1`, `Environment=sandbox`, `Owner=<student>` і `ManagedBy=cloudformation`, і кожен ресурс у шаблонах, що підтримує теги, SHALL мати тег `Name`.

#### Scenario: Теги присутні
- **WHEN** `aws ec2 describe-vpcs` запускається для VPC цього stack
- **THEN** VPC має всі п'ять stack tags і тег `Name`
