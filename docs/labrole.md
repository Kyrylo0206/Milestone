# LabRole і моя роль у sandbox: що дозволено і що ні

Усе тут взято з моїх запусків у sandbox 5 листопада 2026 року. Акаунт `500819826436`, регіон `us-east-1`. Скрипти `scripts/labrole-dissect.sh` (потім з `--include-write-probes`), `scripts/validate-iam.sh --attempt-create`, `scripts/deploy-stack.sh`, `scripts/drift-check.sh` і `scripts/quotas-snapshot.sh`. Сирі файли лежать у `docs/evidence/`. Я брав другий запуск dissection (`20261105T173117Z`), бо він має ще й write probes. Перший запуск (`20261105T172852Z`) дав ті самі рішення, відрізняються лише authorization id у текстах помилок.

## Головне одразу

Моя CLI сесія це `assumed-role/voclabs/...`. Ролі `LabRole` у цьому акаунті немає. Кожен виклик з `--role-name LabRole` повернув `NoSuchEntity`, тобто "The role with name LabRole cannot be found". Тому все нижче це права ролі `voclabs`, а не `LabRole`.

## Як читати колонку "Джерело deny"

- **SCP explicit**. У тексті є "explicit deny in a service control policy". Це політика організації Vocareum над моїм акаунтом.
- **Identity explicit**. У тексті є "explicit deny in an identity-based policy". Це Deny у політиці самої ролі `voclabs`. Найімовірніше це inline `Pvoclabs`, бо `ReadOnlyAccess` не має Deny. Сам текст `Pvoclabs` я прочитати не можу.
- **Implicit**. У тексті є "no identity-based policy allows". Жодна політика не дає Allow.
- **Simulator**. Рішення з `simulate-principal-policy` для `voclabs`. Симулятор не знає умов мого запиту (тип instance, регіон), тому його "allowed" слабший за живу пробу.

## Таблиця

Префікс файлів у `docs/evidence/labrole/` це `20261105T173117Z-`. Я його нижче не пишу.

| Дія | Результат | Джерело deny | Як я перевірив | Файл доказу |
|---|---|---|---|---|
| `sts:GetCallerIdentity` | allowed, ARN `assumed-role/voclabs/...` | | CLI | `labrole/01-caller-identity.json` |
| `iam:ListAttachedRolePolicies` на `voclabs` | allowed, одна managed policy `ReadOnlyAccess` (версія v191) | | CLI | `labrole/02-caller-attached-policies.json`, `labrole/02-caller-policy-ReadOnlyAccess.json` |
| `iam:ListRolePolicies` на `voclabs` | allowed, одна inline policy `Pvoclabs` | | CLI | `labrole/02-caller-inline-policy-names.json` |
| `iam:GetRole` на `voclabs` | denied | Identity explicit | CLI | `labrole/02-caller-get-role.json.error.txt` |
| `iam:GetRolePolicy` для `Pvoclabs` | denied | Identity explicit | CLI | `labrole/02-caller-inline-Pvoclabs.json.error.txt` |
| `iam:GetRole` і ще 4 читання на `LabRole` | помилка `NoSuchEntity`, ролі немає | це не deny | CLI | `labrole/02-labrole-*.json.error.txt` |
| `iam:SimulatePrincipalPolicy` для `LabRole` | помилка `NoSuchEntity` | це не deny | CLI | `labrole/03-labrole-simulate.json.error.txt` |
| `ec2:CreateVpc` | allowed ("Request would have succeeded") | | `--dry-run` | `labrole/04-dryrun-create-vpc.txt.error.txt` |
| `ec2:RunInstances` з `t3.micro` | allowed ("Request would have succeeded") | | `--dry-run` | `labrole/04-dryrun-run-t3micro.txt.error.txt` |
| `ec2:RunInstances` з `m5.4xlarge` | denied (`UnauthorizedOperation`) | Identity explicit | `--dry-run` | `labrole/04-dryrun-run-m5-4xlarge.txt.error.txt` |
| `sts:DecodeAuthorizationMessage` | denied | Implicit | CLI | `labrole/04-dryrun-run-m5-4xlarge.txt.decoded.json.error.txt` |
| `ec2:DescribeVpcs` в `eu-central-1` | denied (`UnauthorizedOperation`) | SCP explicit | CLI в іншому регіоні | `labrole/04-describe-vpcs-eu-central-1.json.error.txt` |
| `organizations:DescribeOrganization` | denied (`AccessDeniedException`) | жива відповідь джерело не каже, симулятор каже `explicitDeny` | CLI і simulator | `labrole/04-organizations-describe.json.error.txt`, `labrole/03-caller-simulate.json` |
| `iam:CreatePolicy` | denied | Implicit | CLI write probe | `labrole/04-iam-create-policy.json.error.txt` |
| `iam:CreateRole` | denied | Implicit | CLI write probe | `labrole/04-iam-create-role.json.error.txt` |
| `iam:CreatePolicy` через CloudFormation (stack `kvs-iam-readonly`) | denied, `ReadOnlyViewPolicy` `CREATE_FAILED`, stack `ROLLBACK_COMPLETE` | Implicit | справжній `create-stack` | `iam/20261105T173806Z-describe-stack-events.json` |
| `access-analyzer:ValidatePolicy` | allowed, `findings` порожній | | CLI | `iam/20261105T173806Z-accessanalyzer-validate-policy.json` |
| `access-analyzer:CheckAccessNotGranted` | denied | Implicit | CLI | `iam/20261105T173806Z-accessanalyzer-check-access-not-granted.json.error.txt` |
| `iam:SimulateCustomPolicy` | allowed, усі 6 рішень як я очікував | | CLI | `iam/20261105T173806Z-simulate-custom-policy.json` |
| `iam:SimulatePrincipalPolicy` для `voclabs` | allowed | | CLI | `labrole/03-caller-simulate.json` |
| `cloudformation:CreateChangeSet`, `ExecuteChangeSet`, `DeleteStack` | allowed, `kvs-network` створено і знесено | | живий deploy і recreate | `deploy/`, `recreate/20261105T174116Z-recreate.log` |
| `cloudformation:DetectStackDrift` | allowed | | живий запуск | `drift/20261105T174053Z-kvs-network-status.json` |
| `servicequotas:ListServiceQuotas` | allowed | | живий запуск | `quotas/20261105T173454Z-summary.txt` |
| `iam:AttachRolePolicy` | implicitDeny | Simulator | simulator | `labrole/03-caller-simulate.json` |
| `iam:PassRole` | implicitDeny | Simulator | simulator | `labrole/03-caller-simulate.json` |
| `ecs:CreateCluster` | implicitDeny | Simulator | simulator | `labrole/03-caller-simulate.json` |
| `cloudformation:CreateStack` | allowed | | simulator | `labrole/03-caller-simulate.json` |
| `ec2:CreateNatGateway`, `ec2:AllocateAddress` | allowed | | simulator, живо не пробував | `labrole/03-caller-simulate.json` |
| `lambda:CreateFunction`, `dynamodb:CreateTable`, `s3:CreateBucket` | allowed | | simulator, живо не пробував | `labrole/03-caller-simulate.json` |
| `ce:GetCostAndUsage` | allowed | | simulator, живо не викликав | `labrole/03-caller-simulate.json` |

Важлива примітка про симулятор. Він сказав `ec2:RunInstances` allowed, а жива проба з `m5.4xlarge` отримала explicit deny від identity policy. Тобто Deny у `Pvoclabs` має умову, найімовірніше на тип instance. Симулятор цю умову не бачить, бо я не передавав йому context keys. Тому allowed від симулятора означає "дозволено хоча б для якогось запиту", а не "дозволено завжди".

## LabRole проти voclabs

Я чекав, що побачу дві ролі. `voclabs` це роль, якою я працюю в CLI. `LabRole` це готова роль, яку Learner Lab дає передавати в EC2 або Lambda. Так написано в багатьох інструкціях до Learner Lab, і так я планував у `docs/m1-design-decisions.md`.

У моєму акаунті цього немає. `get-role`, `list-attached-role-policies`, `list-role-policies`, `list-role-tags` і `list-instance-profiles-for-role` для `LabRole` усі повернули `NoSuchEntity`. Симулятор для ARN `role/LabRole` теж відповів "Unable to retrieve specified IAM entity". Тож я не можу сказати, що дозволяє `LabRole`. Її просто немає в цьому sandbox.

Що я знаю про `voclabs`. До неї прикріплена AWS managed `ReadOnlyAccess` і є одна inline policy `Pvoclabs`. Текст `Pvoclabs` я не бачу, бо `iam:GetRole` і `iam:GetRolePolicy` на саму себе мають explicit deny. Тому про вміст `Pvoclabs` я суджу лише з поведінки. Вона дає Allow на створення VPC, CloudFormation stacks і `t3.micro`. Вона має explicit Deny для великих типів instance, як `m5.4xlarge`. IAM writes вона не дозволяє взагалі, це implicit deny. Регіон поза `us-east-1` блокує вже SCP, а не роль. `us-west-2` я не перевіряв.

Що це означає для M2. Якщо compute у M2 потребує ролі (EC2 instance profile або Lambda execution role), мені не буде що передати. `LabRole` немає, створити роль я не можу, а `iam:PassRole` у симуляторі `implicitDeny`. Чи є в акаунті `LabInstanceProfile`, я не перевіряв. Це перше, що я подивлюсь на початку M2.
