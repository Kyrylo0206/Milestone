# Design: M1 infrastructure setup

Цей дизайн є нормативним разом з `docs/m1-design-decisions.md`, де лежать повний список дій policy, поведінка скриптів і ручні команди для sandbox. ADR у `docs/adr/` містять обґрунтування.

## Context

- Середовище це AWS Academy Learner Lab, `us-east-1`, тимчасові credentials приблизно на 4 години, IAM write очікувано відхиляється, ліміт кредиту припущено $50 на весь курс.
- Курс вчить CloudFormation, а контрольні питання стосуються change sets і drift detection.
- M2 до M5 додадуть у цю мережу coordinator, shards, replicas (3 на shard), observability і autoscaling.

## Goals and Non-Goals

Goals:
- Network stack, який я можу створити знову лише з коду за хвилини, з public і private tier у двох AZ.
- Read-only policy і assumable role в IaC, перевірені настільки, наскільки дозволяє sandbox, з записаною відмовою.
- Розбір LabRole на основі доказів, знімок quotas і бюджет M2 у порівнянні з кредитом.

Non-Goals:
- Будь-який application compute, security groups для застосунку, load balancers чи CI/CD (M2).
- NAT gateway або interface endpoints у default deployment.
- Flow logs і моніторинг (M4).

## Decisions

### D1. IaC tool (ADR 0001)
Я використовую CloudFormation YAML з явними change sets, бо в нього немає state файлу, яким треба керувати в sandbox, де credentials змінюються, а change sets і drift detection це саме те, про що питає курс.

### D2. Stack layout (ADR 0002)
Я використовую три stacks: `kvs-network` (зараз), `kvs-iam-readonly` (лише реальний акаунт), `kvs-app` (M2), бо IAM в тому самому stack відкотив би всю мережу в sandbox. Зв'язок іде через Outputs з `Export: Name: !Sub '${AWS::StackName}-<Output>'`. Споживачі беруть параметр `NetworkStackName`.

### D3. Addressing (ADR 0003)

| Item | CIDR | AZ |
|---|---|---|
| VPC | `10.20.0.0/16` | |
| PublicSubnet1 | `10.20.0.0/24` | `!Select [0, !GetAZs '']` |
| PublicSubnet2 | `10.20.1.0/24` | `!Select [1, !GetAZs '']` |
| PrivateSubnet1 | `10.20.16.0/20` | index 0 |
| PrivateSubnet2 | `10.20.32.0/20` | index 1 |
| Reserved AZ c | `10.20.2.0/24`, `10.20.48.0/20` | M3 |
| Reserved data tier | `10.20.64.0/18` | M3 якщо потрібно |
| Reserved expansion | `10.20.128.0/17` | |

### D4. Routing, NAT and endpoints
Одна public route table з `0.0.0.0/0` до IGW (`DependsOn: InternetGatewayAttachment`). Дві private route tables, по одній на AZ, лише з local route і маршрутом S3 gateway endpoint. NAT gateway, його EIP і private default routes існують лише за умовою `CreateNat` (`EnableNatGateway=true`, default `false`), з одним NAT у public subnet 1. Я тримаю NAT вимкненим, бо він коштував би приблизно $36.50 на місяць, а це більша частина кредиту, і завдання каже, що private tier має бути лише внутрішнім.

### D5. Template contract for `infra/network.yaml`
Parameters: `ProjectName`, `VpcCidr`, `PublicSubnet1Cidr`, `PublicSubnet2Cidr`, `PrivateSubnet1Cidr`, `PrivateSubnet2Cidr`, `EnableNatGateway`, defaults як у D3.
Logical IDs: `Vpc`, `InternetGateway`, `InternetGatewayAttachment`, `PublicSubnet1`, `PublicSubnet2`, `PrivateSubnet1`, `PrivateSubnet2`, `PublicRouteTable`, `PublicDefaultRoute`, `PublicSubnet1RouteTableAssociation`, `PublicSubnet2RouteTableAssociation`, `PrivateRouteTable1`, `PrivateRouteTable2`, `PrivateSubnet1RouteTableAssociation`, `PrivateSubnet2RouteTableAssociation`, `S3GatewayEndpoint`, а під `CreateNat`: `NatEip`, `NatGateway`, `PrivateDefaultRoute1`, `PrivateDefaultRoute2`.
VPC має ввімкнені DNS support і DNS hostnames. Public subnets мають `MapPublicIpOnLaunch: true`, private `false`.
Exported outputs: `VpcId`, `VpcCidr`, `PublicSubnet1Id`, `PublicSubnet2Id`, `PrivateSubnet1Id`, `PrivateSubnet2Id`, `PublicSubnetIds`, `PrivateSubnetIds`, `AvailabilityZones`, `PublicRouteTableId`, `PrivateRouteTable1Id`, `PrivateRouteTable2Id`, `S3GatewayEndpointId`. `NatGatewayId` умовний і не експортується.

### D6. Template contract for `infra/iam-readonly.yaml`
Parameters: `ProjectName`, `TrustedPrincipalArn`, `ExternalId`, `RequireMfa` (default `false`), `MaxSessionDuration` (default 3600, дозволено 3600 до 43200, діапазон, який IAM приймає для role).
`ReadOnlyViewPolicy` (`AWS::IAM::ManagedPolicy`, name `kvs-readonly-view`): один Allow statement лише з metadata діями (`Describe*`, `List*`, вибрані `Get*` на конфігурацію, `apigateway:GET`, `budgets:ViewBudget`, перегляд вартості і quotas) на `*`, і один Deny statement для читання data-plane і secrets (`s3:GetObject`, читання елементів DynamoDB, `secretsmanager:GetSecretValue`, `ssm:GetParameter*`, `kms:Decrypt`, `lambda:InvokeFunction`, `lambda:GetFunction`, читання подій логів, ECR image pulls, `sqs:ReceiveMessage`). Точний список у `docs/m1-design-decisions.md` §5. Документ не має intrinsic functions.
`ReadOnlyViewRole` (`AWS::IAM::Role`, name `kvs-readonly-viewer`): trust дозволяє `sts:AssumeRole` лише для `TrustedPrincipalArn`, з `StringEquals sts:ExternalId`, плюс `Bool aws:MultiFactorAuthPresent true` коли `RequireMfa=true`. `ManagedPolicyArns` і `PermissionsBoundary` обидва вказують на `ReadOnlyViewPolicy`.
Я вибрав власний список замість AWS managed `ReadOnlyAccess`, бо та читає дані (об'єкти, елементи, логи), а це більше, ніж "view resources". Мінус у тому, що мій список пропустить сервіси, яких я не передбачив.

### D7. Sandbox refusal handling
IAM stack ніколи не входить у звичайний deploy в sandbox. У sandbox я запускаю lint, `validate-template`, Access Analyzer `validate-policy` і `check-access-not-granted`, `simulate-custom-policy`, і рівно одну спробу `create-stack`, чий `describe-stack-events` я зберігаю як evidence перед видаленням невдалого stack. Кожен крок, який сам відхилено, записується з текстом помилки замість того, щоб ламати скрипт.

### D8. Tags
Stack tags на кожному change set: `Project=kvs-capstone`, `Milestone=m1`, `Environment=sandbox`, `Owner=<student>`, `ManagedBy=cloudformation`. Шаблони додають лише `Name`.

### D9. Region and sessions
Скрипти за замовчуванням беруть `us-east-1`, спочатку перевіряють `sts get-caller-identity` і зупиняються з чітким повідомленням, якщо сесія закінчилась.

## Risks / Trade-offs

- Без NAT private subnets не можуть вийти в інтернет. Це вимога для M1, але M2 мусить вибрати між NAT, interface endpoints або compute поза VPC.
- Дві AZ зараз означають, що M3 мусить додати AZ c перед розміщенням 3 replicas, інакше дві replicas ділитимуть одну AZ.
- Exports блокують видалення або зміну імпортованих значень. Це пом'якшується запасом CIDR і лише адитивним ростом.
- Read-only список може бути неповним. Запасний еталон це AWS managed `ViewOnlyAccess`.
- Кілька поведінок sandbox це припущення, доки не запрацює dissection (регіони, типи instance, IAM simulation, Access Analyzer, Cost Explorer). У docs вони позначені VERIFY.

## Migration Plan

Це перший milestone, тому мігрувати нічого. Rollback це `scripts/teardown.sh`. Recreate це `scripts/recreate-timed.sh`.

## Open Questions

- Точний ліміт кредиту і вже витрачена сума (студент читає це в AWS Details).
- Чи ідентичність CLI це `voclabs` чи щось інше в lab цього курсу.
- Чи deny походять з SCP чи з policy role (читається з тексту помилки).
- Чи курс хоче Git репозиторій у `Milestone/Milestone` (наявний клон GitHub) як корінь проєкту.
