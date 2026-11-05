# M1 design decisions for implementation

Це робочий аркуш для побудови M1. Кодер має змогу реалізувати все з цього файлу разом з ADR. Пункти, які я не міг перевірити без доступу до sandbox, позначені як **VERIFY**.

## 1. Repository layout

```
README.md                          bring up, verify, what changed (M1 section)
openspec/changes/m1-infrastructure-setup/   proposal, design, tasks, specs (written before code)
docs/adr/0001-iac-tool.md
docs/adr/0002-stack-layout.md
docs/adr/0003-cidr-addressing.md
docs/architecture.md
docs/m1-design-decisions.md        this file
docs/m1-budget-and-quotas.md
docs/labrole.md                    student writes it from evidence (allow / deny / how found)
docs/ai-review/m1-critique.md      AI critique transcript plus accept/refute notes
docs/evidence/                     raw CLI output saved by scripts (JSON and logs), committed
infra/network.yaml                 stack kvs-network (sandbox)
infra/iam-readonly.yaml            stack kvs-iam-readonly (real account only)
infra/params/network-sandbox.json
infra/params/iam-readonly-example.json
scripts/lib.sh                     shared helpers (region, colours, evidence dir, require aws)
scripts/lint.sh
scripts/deploy-stack.sh
scripts/teardown.sh
scripts/verify-network.sh
scripts/drift-check.sh
scripts/recreate-timed.sh
scripts/labrole-dissect.sh
scripts/quotas-snapshot.sh
scripts/validate-iam.sh
scripts/extract-policy.py
tests/cfn_yaml.py                  YAML loader that understands CloudFormation short tags
tests/test_network_cidrs.py
tests/test_readonly_policy.py
requirements-dev.txt               cfn-lint, pyyaml, pytest
```

Усі скрипти це bash з `set -euo pipefail`, default `AWS_REGION=us-east-1`, і вони пишуть сирий вивід у `docs/evidence/<topic>/<UTC timestamp>-<name>.json`. Жоден скрипт не зберігає credentials. Кожен скрипт одразу зупиняється з чітким повідомленням, якщо `aws sts get-caller-identity` не працює (сесія закінчилась).

## 2. Naming and tagging standard

Префікс для всього це `kvs`. Імена stack це `kvs-network`, `kvs-iam-readonly` і пізніше `kvs-app`. Теги `Name` для ресурсів мають вигляд `kvs-<tier>-<az letter or role>`, наприклад `kvs-public-a`, `kvs-private-b`, `kvs-rt-private-a`.

Теги застосовуються як stack tags через `create-change-set --tags`, тож CloudFormation поширює їх на кожен ресурс, який підтримує теги. Самі шаблони задають лише тег `Name`.

| Key | Value | Чому |
|---|---|---|
| `Project` | `kvs-capstone` | облік витрат по продукту (лекція 2, слайд про теги) |
| `Milestone` | `m1` | показує, який milestone це створив |
| `Environment` | `sandbox` | поділ за середовищами, зручно для ABAC |
| `Owner` | handle студента, передається як змінна скрипта `OWNER` | відповідальність |
| `ManagedBy` | `cloudformation` | каже кожному в консолі не редагувати вручну (drift) |

## 3. `infra/network.yaml`

### Parameters

| Name | Type | Default | Notes |
|---|---|---|---|
| `ProjectName` | String | `kvs` | використовується в тегах Name |
| `VpcCidr` | String | `10.20.0.0/16` | AllowedPattern для IPv4 CIDR |
| `PublicSubnet1Cidr` | String | `10.20.0.0/24` | AZ index 0 |
| `PublicSubnet2Cidr` | String | `10.20.1.0/24` | AZ index 1 |
| `PrivateSubnet1Cidr` | String | `10.20.16.0/20` | AZ index 0 |
| `PrivateSubnet2Cidr` | String | `10.20.32.0/20` | AZ index 1 |
| `EnableNatGateway` | String | `false` | AllowedValues `true`, `false` |

Condition `CreateNat: !Equals [!Ref EnableNatGateway, 'true']`.

### Resources (logical IDs фіксовані, кодер мусить використати саме ці імена)

| Logical ID | Type | Key properties |
|---|---|---|
| `Vpc` | `AWS::EC2::VPC` | `CidrBlock: !Ref VpcCidr`, `EnableDnsSupport: true`, `EnableDnsHostnames: true` |
| `InternetGateway` | `AWS::EC2::InternetGateway` | |
| `InternetGatewayAttachment` | `AWS::EC2::VPCGatewayAttachment` | VpcId, InternetGatewayId |
| `PublicSubnet1` | `AWS::EC2::Subnet` | AZ `!Select [0, !GetAZs '']`, `MapPublicIpOnLaunch: true` |
| `PublicSubnet2` | `AWS::EC2::Subnet` | AZ `!Select [1, !GetAZs '']`, `MapPublicIpOnLaunch: true` |
| `PrivateSubnet1` | `AWS::EC2::Subnet` | AZ index 0, `MapPublicIpOnLaunch: false` |
| `PrivateSubnet2` | `AWS::EC2::Subnet` | AZ index 1, `MapPublicIpOnLaunch: false` |
| `PublicRouteTable` | `AWS::EC2::RouteTable` | одна спільна таблиця для обох public subnet |
| `PublicDefaultRoute` | `AWS::EC2::Route` | `0.0.0.0/0` to `InternetGateway`, `DependsOn: InternetGatewayAttachment` |
| `PublicSubnet1RouteTableAssociation`, `PublicSubnet2RouteTableAssociation` | `AWS::EC2::SubnetRouteTableAssociation` | |
| `PrivateRouteTable1`, `PrivateRouteTable2` | `AWS::EC2::RouteTable` | по одній на AZ, щоб NAT для кожної AZ можна було додати пізніше без повторного association |
| `PrivateSubnet1RouteTableAssociation`, `PrivateSubnet2RouteTableAssociation` | `AWS::EC2::SubnetRouteTableAssociation` | |
| `S3GatewayEndpoint` | `AWS::EC2::VPCEndpoint` | `VpcEndpointType: Gateway`, `ServiceName: !Sub 'com.amazonaws.${AWS::Region}.s3'`, `RouteTableIds: [PrivateRouteTable1, PrivateRouteTable2]`, default (повна) endpoint policy, тег `Name` `kvs-s3-endpoint` |
| `NatEip` (Condition `CreateNat`) | `AWS::EC2::EIP` | `Domain: vpc`, `DependsOn: InternetGatewayAttachment` |
| `NatGateway` (Condition `CreateNat`) | `AWS::EC2::NatGateway` | у `PublicSubnet1`, `AllocationId: !GetAtt NatEip.AllocationId` |
| `PrivateDefaultRoute1`, `PrivateDefaultRoute2` (Condition `CreateNat`) | `AWS::EC2::Route` | `0.0.0.0/0` to `NatGateway` |

`DependsOn: InternetGatewayAttachment` на public route я залишаю навмисно. Без нього CloudFormation може спробувати створити route до того, як IGW приєднано, і впасти, а це класичний приклад `DependsOn` з лекції.

У M1 я не додаю власних NACL і жодних security groups. Ізоляція private tier походить з маршрутизації (немає default route), а security groups належать до app stack з M2, де є що захищати. Default security group і default NACL у VPC лишаються такими, якими їх створює AWS. У M1 я не додаю VPC Flow Logs, бо вони коштують грошей, а шлях доставки в CloudWatch потребує IAM role, яку я не можу створити. Це переїжджає в M4.

### Route tables (очікуваний стан, verify скрипт це перевіряє)

| Table | Associated subnets | Routes |
|---|---|---|
| `kvs-rt-public` | public a, public b | `10.20.0.0/16 local`, `0.0.0.0/0 igw-*` |
| `kvs-rt-private-a` | private a | `10.20.0.0/16 local`, S3 prefix list `pl-*` to `vpce-*` |
| `kvs-rt-private-b` | private b | `10.20.0.0/16 local`, S3 prefix list `pl-*` to `vpce-*` |

З `EnableNatGateway=true` обидві private таблиці також отримують `0.0.0.0/0 nat-*`.

### Outputs (усі експортуються як `${AWS::StackName}-<OutputName>`)

`VpcId`, `VpcCidr`, `PublicSubnet1Id`, `PublicSubnet2Id`, `PrivateSubnet1Id`, `PrivateSubnet2Id`, `PublicSubnetIds` (через кому), `PrivateSubnetIds` (через кому), `AvailabilityZones` (через кому, з атрибута `AvailabilityZone` двох subnet), `PublicRouteTableId`, `PrivateRouteTable1Id`, `PrivateRouteTable2Id`, `S3GatewayEndpointId`. Output `NatGatewayId` існує лише під `CreateNat` і не експортується, бо умовний export зламав би імпортерів, коли NAT вимкнено.

## 4. `infra/iam-readonly.yaml`

### Parameters

| Name | Type | Default | Notes |
|---|---|---|---|
| `ProjectName` | String | `kvs` | |
| `TrustedPrincipalArn` | String | немає | AllowedPattern `^arn:aws:iam::[0-9]{12}:(root\|role/[\w+=,.@/-]+\|user/[\w+=,.@/-]+)$`. Клас символів не пускає `*`, тож wildcard principal не може потрапити через параметр. |
| `ExternalId` | String | немає | MinLength 8, MaxLength 1224, AllowedPattern `^[\w+=,.@:/-]+$` |
| `RequireMfa` | String | `false` | AllowedValues `true`, `false` |
| `MaxSessionDuration` | Number | `3600` | MinValue 3600, MaxValue 43200. Це діапазон, який IAM приймає для role. Число 900 стосується іншого. Це найкоротша сесія, яку може попросити виклик `aws sts assume-role --duration-seconds 900`. |

### Resources

- `ReadOnlyViewPolicy`, тип `AWS::IAM::ManagedPolicy`, `ManagedPolicyName: !Sub '${ProjectName}-readonly-view'`, з документом з §5. Документ мусить містити **жодних intrinsic functions**, щоб `scripts/extract-policy.py` міг витягнути його як звичайний JSON для Access Analyzer і simulator.
- `ReadOnlyViewRole`, тип `AWS::IAM::Role`, `RoleName: !Sub '${ProjectName}-readonly-viewer'`, `ManagedPolicyArns: [!Ref ReadOnlyViewPolicy]`, `PermissionsBoundary: !Ref ReadOnlyViewPolicy`, `MaxSessionDuration: !Ref MaxSessionDuration`, trust policy з §6.

Ту саму policy я навмисно ставлю як permissions boundary. Boundary сама нічого не дає, але вона обмежує role, тож навіть якщо хтось пізніше прикріпить до цієї role `AdministratorAccess`, вона все одно зможе лише дивитись. Це коштує один рядок і це хороший живий приклад для контрольного питання про allow проти deny. Одне обмеження я кажу відкрито. Boundary обмежує identity policies, але resource based policy, яка називає сесію role напряму, може не обмежуватись нею (**VERIFY** у документації про policy evaluation в IAM). Явний Deny statement усе одно перемагає в усіх випадках, і це ще одна причина його тримати.

Outputs: `PolicyArn`, `RoleArn`, `AssumeRoleCommand` (рядок `!Sub` з прикладом `aws sts assume-role --role-arn ... --role-session-name audit --external-id <id>`).

Для deploy потрібен `--capabilities CAPABILITY_NAMED_IAM`, бо обидва ресурси мають явні імена.

## 5. The read-only policy

### Чому власний список, а не AWS managed `ReadOnlyAccess`

Я вибираю власний список з мінімальними правами, бо завдання каже "view resources", а `ReadOnlyAccess` читає ще й дані. Вона включає такі речі як `s3:GetObject`, `dynamodb:GetItem`, `dynamodb:Scan` і `logs:GetLogEvents`, а це означає, що viewer міг би прочитати кожен запис у нашому key-value store і кожен рядок логів. Її також підтримує AWS і вона змінюється піді мною, тож те, що я захищаю сьогодні, не є тим, що прикріплено завтра. AWS managed `ViewOnlyAccess` набагато ближча до того, що я хочу (лише metadata), і я називаю її в README як еталон і запасний варіант. Мінус мого вибору чесний: список, написаний вручну, за природою неповний, і viewer отримає `AccessDenied` на сервісах, яких я не вказав, тому я обмежив його сервісами, які цей проєкт справді використовує (M1 до M5), плюс перегляд вартості і quotas.

### Document

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ViewInfrastructureMetadata",
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "elasticloadbalancing:Describe*",
        "autoscaling:Describe*",
        "cloudformation:Describe*",
        "cloudformation:List*",
        "cloudformation:GetTemplate",
        "cloudformation:GetTemplateSummary",
        "lambda:ListFunctions",
        "lambda:ListEventSourceMappings",
        "lambda:ListTags",
        "lambda:GetFunctionConfiguration",
        "lambda:GetAccountSettings",
        "dynamodb:ListTables",
        "dynamodb:DescribeTable",
        "dynamodb:DescribeTimeToLive",
        "dynamodb:DescribeContinuousBackups",
        "dynamodb:DescribeLimits",
        "dynamodb:ListTagsOfResource",
        "s3:ListAllMyBuckets",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:GetBucketPolicy",
        "s3:GetBucketTagging",
        "s3:GetBucketVersioning",
        "s3:GetEncryptionConfiguration",
        "s3:GetBucketPublicAccessBlock",
        "ecs:Describe*",
        "ecs:List*",
        "ecr:DescribeRepositories",
        "ecr:DescribeImages",
        "ecr:ListImages",
        "apigateway:GET",
        "cloudwatch:Describe*",
        "cloudwatch:Get*",
        "cloudwatch:List*",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:DescribeMetricFilters",
        "logs:ListTagsForResource",
        "sqs:ListQueues",
        "sqs:GetQueueAttributes",
        "sns:ListTopics",
        "sns:GetTopicAttributes",
        "iam:GetRole",
        "iam:GetPolicy",
        "iam:GetPolicyVersion",
        "iam:GetRolePolicy",
        "iam:ListRoles",
        "iam:ListPolicies",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies",
        "iam:ListInstanceProfiles",
        "iam:GetAccountSummary",
        "servicequotas:Get*",
        "servicequotas:List*",
        "tag:GetResources",
        "budgets:ViewBudget",
        "ce:GetCostAndUsage",
        "ce:GetCostForecast"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DenyDataPlaneReadsAndSecrets",
      "Effect": "Deny",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "dynamodb:GetItem",
        "dynamodb:BatchGetItem",
        "dynamodb:Query",
        "dynamodb:Scan",
        "dynamodb:PartiQLSelect",
        "secretsmanager:GetSecretValue",
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath",
        "kms:Decrypt",
        "lambda:InvokeFunction",
        "lambda:GetFunction",
        "logs:GetLogEvents",
        "logs:FilterLogEvents",
        "logs:StartQuery",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "sqs:ReceiveMessage"
      ],
      "Resource": "*"
    }
  ]
}
```

Нотатки, які потрібні кодеру і студенту для захисту:

- `Resource: "*"` потрібен, бо більшість дій `Describe*` і `List*` не підтримують resource-level permissions. **VERIFY** по кожній дії в Service Authorization Reference, якщо викладач запитає.
- `apigateway:GET` це спосіб, яким API Gateway називає доступ на читання (дії це HTTP verbs).
- `lambda:GetFunction` виключена і заборонена, бо повертає presigned URL на код функції, а це дані.
- Deny statement зайвий, поки ця policy одна (implicit deny вже блокує ці дії). Я його лишаю, бо явний deny перемагає будь-який allow з будь-якої іншої policy, тож він залишається правдивим, навіть якщо пізніше прикріпити ширшу policy. Це саме відповідь на питання "коли використовувати deny".
- Я навмисно пропускаю `cloudformation:DetectStackDrift`. Вона запускає операцію, тож це не чисте перегляд, хоча viewer усе одно може читати старі результати drift через `DescribeStackResourceDrifts`. **VERIFY** її рівень доступу в Service Authorization Reference.
- Відомі шляхи витоку, які "лише metadata" не закриває. `lambda:ListFunctions` і `lambda:GetFunctionConfiguration` повертають environment variables функції. `ecs:DescribeTaskDefinition` повертає environment variables контейнера. `ec2:DescribeInstanceAttribute` може повернути user data instance. `apigateway:GET` може повернути значення API key. `s3:ListBucket` повертає імена ключів об'єктів, а в key value store ім'я ключа може бути даними. **VERIFY** кожен пункт у API reference. Моє правило з M2 просте. Жодних secrets в environment variables, user data чи task definitions. Secrets йдуть у Secrets Manager, а `GetSecretValue` тут заборонений. Виняток у Deny для цих дій можливий, але він ламає тест "жоден Allow не перетинається з Deny", тому я залишив це для пізнішої зміни з власним оновленням spec.
- Policy займає близько 2 000 символів без пробілів. Ліміт для customer managed policy це 6 144, і тест це перевіряє.
- `tests/test_readonly_policy.py` перевіряє, що verb кожної дозволеної дії (частина після `:`) починається з `Describe`, `List`, `Get`, `View`, або дорівнює `apigateway:GET`, і що жодна дозволена дія не збігається з нічим зі списку deny чи зі wildcard у стилі `s3:Get*`, які включили б `GetObject`.

## 6. Trust policy of the assumable role

```yaml
AssumeRolePolicyDocument:
  Version: '2012-10-17'
  Statement:
    - Sid: AllowTrustedPrincipalWithExternalId
      Effect: Allow
      Principal:
        AWS: !Ref TrustedPrincipalArn
      Action: sts:AssumeRole
      Condition: !If
        - RequireMfaCondition
        - StringEquals: { 'sts:ExternalId': !Ref ExternalId }
          Bool: { 'aws:MultiFactorAuthPresent': 'true' }
        - StringEquals: { 'sts:ExternalId': !Ref ExternalId }
```

Хто може її прийняти. Один principal, заданий як параметр, зазвичай root ARN окремого audit акаунта (`arn:aws:iam::<audit account>:root`, що означає "кого дозволять адміни того акаунта") або ARN однієї конкретної role для вужчого охоплення. Я ніколи не використовую `"AWS": "*"`.

ExternalId. Я завжди його вимагаю, бо він захищає від проблеми confused deputy, коли третя сторона (наприклад, SaaS для аудиту) приймає roles у багатьох акаунтах клієнтів. Це не secret, це спільний ідентифікатор. MFA. Необов'язковий через `RequireMfa`. Я вмикаю його, коли principal, що приймає role, це людина IAM user, і вимикаю, коли це machine role, бо сесія role не може пред'явити MFA і assume завжди б провалювався. Мінус у тому, що з `RequireMfa=false` достатньо витоку credentials довіреного principal плюс ExternalId, що прийнятно для view-only role, але я це кажу.

## 7. Handling the sandbox refusal for IAM

Я очікую, що sandbox відхилить `iam:CreatePolicy` і `iam:CreateRole` для моєї сесії. Перевірено 5 листопада 2026 року: обидва дали AccessDenied з "no identity-based policy allows", тобто implicit deny (`docs/evidence/labrole/20261105T173117Z-04-iam-create-*.error.txt`). Причина в тому, що створення roles це шлях privilege escalation: студент, який може створити role і прикріпити `AdministratorAccess`, може обійти кожне обмеження sandbox (регіони, типи instance, витрати). Learner Lab зазвичай дає лише передавати готову `LabRole` (`iam:PassRole`) сервісам. У моєму акаунті `LabRole` немає (`NoSuchEntity`), а `iam:PassRole` у симуляторі `implicitDeny`, деталі в `docs/labrole.md`. Текст помилки каже мені, звідки береться deny: "with an explicit deny in a service control policy" означає SCP організації Vocareum, "with an explicit deny in an identity-based policy" означає policy role, а "because no identity-based policy allows" означає implicit deny. Мені треба записати, який саме я отримаю, бо це частина відповіді на питання "як ти це дізнався".

Тож `iam-readonly.yaml` це окремий stack (ADR 0002), який я перевіряю настільки, наскільки дозволяє sandbox:

1. Offline: `cfn-lint infra/iam-readonly.yaml` і `pytest tests/test_readonly_policy.py`.
2. `aws cloudformation validate-template --template-body file://infra/iam-readonly.yaml` (лише синтаксис і параметри, права не перевіряє).
3. `python3 scripts/extract-policy.py infra/iam-readonly.yaml > build/readonly-policy.json`.
4. `aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY --policy-document file://build/readonly-policy.json` (перевіряє граматику і best practice). Перевірено: у sandbox дозволено, `findings` порожній.
5. `aws accessanalyzer check-access-not-granted --policy-type IDENTITY_POLICY --policy-document file://build/readonly-policy.json --access '[{"actions":["s3:PutObject","ec2:RunInstances","ec2:CreateVpc","iam:CreateRole","dynamodb:PutItem","dynamodb:Scan","s3:GetObject"]}]'`. Це формальне доведення, що ці дії не надаються. Це платна перевірка custom policy, частки цента за виклик. Перевірено: у sandbox заборонено, AccessDeniedException з "no identity-based policy allows the access-analyzer:CheckAccessNotGranted action". Тому цей крок у sandbox я не маю.
6. `aws iam simulate-custom-policy --policy-input-list file://build/readonly-policy.json --action-names ec2:DescribeVpcs ec2:CreateVpc s3:ListAllMyBuckets s3:GetObject dynamodb:Scan iam:CreateRole`. Очікувані результати: `allowed`, `implicitDeny`, `allowed`, `explicitDeny`, `explicitDeny`, `implicitDeny`. Перевірено: `iam:SimulateCustomPolicy` дозволено, і всі 6 рішень збіглися з очікуваними (`docs/evidence/iam/20261105T173806Z-simulate-custom-policy.json`).
7. Одна справжня спроба створити stack у sandbox, щоб зберегти відмову як evidence: `create-stack --stack-name kvs-iam-readonly --capabilities CAPABILITY_NAMED_IAM ...`, дочекатись, зберегти `describe-stack-events` у `docs/evidence/iam/`, потім `delete-stack`. Stack має завершитись у `ROLLBACK_COMPLETE` з `CREATE_FAILED` на `ReadOnlyViewPolicy` і текстом AccessDenied у `ResourceStatusReason`. Так і сталося: AccessDenied на `iam:CreatePolicy`, implicit deny (`docs/evidence/iam/20261105T173806Z-describe-stack-events.json`).

Я відхилив один шаблон з умовою `DeployIam`, бо він ховає частину IAM від change sets stack мережі і змішує два життєві цикли. Окремий файл простіше пояснити.

## 8. Scripts the coder writes and the student runs

### `scripts/deploy-stack.sh <stack-name> <template> [params-file] [--plan-only]`

Визначає, чи stack існує (`describe-stacks`), створює change set типу `CREATE` або `UPDATE` зі stack tags з §2, чекає на `change-set-create-complete`, виводить `describe-change-set` як таблицю (Action, LogicalResourceId, ResourceType, Replacement), зупиняється якщо `--plan-only`, інакше виконує і чекає на `stack-create-complete` або `stack-update-complete`. Порожній change set ("didn't contain changes") вважається успіхом, і change set видаляється.

### `scripts/teardown.sh`

Видаляє `kvs-app`, якщо він існує, потім `kvs-network`, і чекає на кожен. Виводить секунди, що минули. Без `--yes` лише показує, що видалив би. Відмовляється видаляти stack, який не має stack tag `Project=kvs-capstone`.

### `scripts/verify-network.sh`

Читає outputs stack і перевіряє через `describe-route-tables`, `describe-subnets` і `describe-vpc-endpoints`:
- VPC CIDR це `10.20.0.0/16`, 4 subnet, 2 різні AZ.
- public route table має `0.0.0.0/0` до `igw-` і прив'язана до обох public subnet.
- кожна private route table **не** має маршруту до `igw-`, не має `0.0.0.0/0` якщо NAT не ввімкнено, і має маршрут S3 endpoint.
- private subnet мають `MapPublicIpOnLaunch=false`.
Код виходу не нуль при будь-якій помилці, а вивід зберігається в evidence.

Необов'язкове ручне підтвердження (коштує центи, потребує `ec2:RunInstances`): запусти `t3.micro` без public IP у private subnet і один у public subnet, використай EC2 Instance Connect або консоль, щоб показати, що `curl https://aws.amazon.com` виходить за таймаутом з private і працює з public, потім знищ обидва. Знищ перед teardown, інакше видалення subnet впаде з `DependencyViolation`.

### `scripts/drift-check.sh <stack-name>`

`detect-stack-drift`, опитує `describe-stack-drift-detection-status`, виводить `describe-stack-resource-drifts`, відфільтровані по `MODIFIED` і `DELETED`. Демо для захисту: зміни вручну в консолі значення тега `Name` у VPC, запусти скрипт, покажи drift, потім запусти deploy, щоб побачити, що звичайний change set "не бачить" ручну зміну (він порівнює шаблони, а не живий стан). Це одне демо відповідає на питання change set проти drift. Я змінюю значення, яке задає шаблон, бо не впевнений, що новий додатковий тег рахується як drift (**VERIFY**). Зміна значення працює: `kvs-vpc` на `drift-demo-changed-by-hand` дала `DRIFTED` і VPC `MODIFIED` (`docs/evidence/drift/20261105T174053Z-*`). Також **VERIFY** чи CloudFormation тепер пропонує drift aware change sets. Якщо так, моє речення правдиве лише для режиму за замовчуванням.

### `scripts/recreate-timed.sh`

Запускає `teardown.sh`, потім `deploy-stack.sh kvs-network ...`, потім `verify-network.sh`, записуючи UTC часові мітки початку і кінця teardown, початку і кінця create та кінця verify у `docs/evidence/recreate/<ts>.log`. Студент додає в README вручну коротку нотатку "що зламалось з першої спроби". Я очікую звичні причини: прострочений токен сесії, регіон не `us-east-1`, вручну запущений тестовий instance, що блокує видалення subnet, або export, який ще імпортується.

## 9. What the student must run by hand in the sandbox

Вони запускаються з credentials від Learner Lab (AWS Details, потім AWS CLI, вставити в `~/.aws/credentials`, сесія 3 години). Я не можу запустити їх за тебе. `scripts/labrole-dissect.sh` і `scripts/quotas-snapshot.sh` обгортають їх і зберігають усе в `docs/evidence/`. Кожна команда, яку можуть відхилити, не повинна зупиняти скрипт: замість цього він зберігає текст помилки, бо помилка теж є доказом.

### 9.1 Who am I

```bash
aws sts get-caller-identity
aws configure get region            # should be us-east-1
```

У Learner Lab ідентичність CLI зазвичай `assumed-role/voclabs/user<id>`, а не LabRole. LabRole це role, яку ти передаєш в EC2 або Lambda. Тому я розбираю обидві: role викликача (ім'я береться з ARN) і `LabRole`. Перевірено: caller це `assumed-role/voclabs/...`, а `LabRole` у цьому акаунті не існує (`NoSuchEntity` на всі виклики).

### 9.2 What policies LabRole (and the caller role) have

```bash
for R in LabRole "$CALLER_ROLE"; do
  aws iam get-role --role-name "$R"                       # trust policy, max session
  aws iam list-attached-role-policies --role-name "$R"
  aws iam list-role-policies --role-name "$R"             # inline names
done
# for every attached policy ARN:
aws iam get-policy --policy-arn "$ARN"                    # DefaultVersionId
aws iam get-policy-version --policy-arn "$ARN" --version-id "$VER"
# for every inline policy name:
aws iam get-role-policy --role-name "$R" --policy-name "$NAME"
aws iam list-role-tags --role-name LabRole
aws iam list-instance-profiles-for-role --role-name LabRole
```

### 9.3 What the policies actually allow (simulation)

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::$ACCOUNT:role/LabRole" \
  --action-names iam:CreateRole iam:CreatePolicy iam:AttachRolePolicy iam:PassRole \
     cloudformation:CreateStack ec2:CreateVpc ec2:CreateNatGateway ec2:AllocateAddress \
     ec2:RunInstances lambda:CreateFunction dynamodb:CreateTable ecs:CreateCluster \
     s3:CreateBucket organizations:DescribeOrganization ce:GetCostAndUsage \
     servicequotas:ListServiceQuotas access-analyzer:ValidatePolicy
```

**VERIFY**. Simulator оцінює identity policies, і я не впевнений, що він відображає SCP Vocareum. Тому я більше довіряю живим перевіркам нижче. Для `LabRole` симулятор дав `NoSuchEntity`, тому скрипт симулював роль викликача `voclabs`. Там `ec2:CreateNatGateway`, `ec2:RunInstances`, `ce:GetCostAndUsage` allowed, а `iam:PassRole` і `ecs:CreateCluster` implicitDeny. Живий dry-run `m5.4xlarge` отримав explicit deny, хоча симулятор каже `ec2:RunInstances` allowed. Отже allowed від симулятора не враховує умови запиту.

### 9.4 Live probes (the strongest evidence)

```bash
aws ec2 create-vpc --cidr-block 10.99.0.0/16 --dry-run                 # DryRunOperation means allowed
aws ec2 run-instances --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --instance-type t3.micro --dry-run          # checked: resolve:ssm works, default VPC exists, DryRunOperation
aws ec2 run-instances --image-id <same> --instance-type m5.4xlarge --dry-run   # instance type limits
aws ec2 describe-vpcs --region eu-central-1                             # region restriction
aws iam create-policy --policy-name kvs-probe --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:ListAllMyBuckets","Resource":"*"}]}'
aws iam create-role --role-name kvs-probe --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws organizations describe-organization
aws sts decode-authorization-message --encoded-message "<from an EC2 error>"   # if an encoded message appears
```

Якщо `create-policy` або `create-role` несподівано спрацьовує, скрипт одразу видаляє probe (`delete-policy`, `delete-role`), а студент записує це як знахідку.

### 9.5 Quotas and limits (`scripts/quotas-snapshot.sh`)

```bash
for S in vpc ec2 ebs lambda dynamodb apigateway ecs fargate elasticloadbalancing logs cloudformation; do
  aws service-quotas list-service-quotas --service-code "$S" --output json
  aws service-quotas list-aws-default-service-quotas --service-code "$S" --output json
done
aws lambda get-account-settings          # real ConcurrentExecutions in this account
aws dynamodb describe-limits
aws ec2 describe-account-attributes      # max-instances, vpc-max-elastic-ips
```

Список quotas, які треба витягти з цього виводу, є в `docs/m1-budget-and-quotas.md`.

### 9.6 Budget and credit

Студент читає бюджет Learner Lab (панель AWS Details, "used" проти total) і записує його в `docs/m1-budget-and-quotas.md`. Cost Explorer (`aws ce get-cost-and-usage`) у симуляторі для `voclabs` allowed, але сам виклик я не робив. Кредит я побачив на панелі: Used $0 of $20 на весь курс.

## 10. Order of work (spec before code)

1. Закомітити `openspec/` і `docs/adr/` першими, окремо, у Git репозиторій, щоб історія показувала, що spec був перед кодом.
2. Написати шаблони, скрипти і тести. Запустити `scripts/lint.sh` і `pytest` локально.
3. У sandbox: dissection, quotas, deploy мережі, verify, drift демо, IAM validation і збір відмови, timed recreate.
4. README, `docs/labrole.md`, запис AI critique.

## 11. Уроки з першого запуску в sandbox

1. `case` всередині `$( ... )` у bash ламається. У `verify-network.sh` був рядок з `case "$(stack_status ...)" in CREATE_COMPLETE|UPDATE_COMPLETE) echo yes ;; *) echo no ;; esac` усередині command substitution. Bash прочитав `)` після шаблону як кінець `$(`, і перший запуск дав 44 passed і 1 failed (`docs/evidence/verify/20261105T173351Z-kvs-network-verify.log`). Тепер статус спочатку йде в змінну, а `case` стоїть окремо. Другий запуск дав 45 passed і 0 failed.
2. `extract-policy.py` потребує `pyyaml`. Перший запуск `validate-iam.sh` впав, бо системний `python3` не мав цього модуля. Тепер я ставлю `requirements-dev.txt` у virtual environment до запуску скриптів, і README про це каже.
3. Не можна планувати на `LabRole`, не перевіривши, що вона є. У моєму акаунті її немає, тому план M2 для ролей EC2 і Lambda треба переглянути.
