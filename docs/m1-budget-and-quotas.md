# M1: service quotas для M2 і бюджет M2

Усе тут це план, зроблений без доступу до sandbox. Значення default quota це публічні AWS defaults так, як я їх пам'ятаю, а Learner Lab може бути суворішим за ці defaults через власні policies. Ціни це **приблизні on-demand ціни для us-east-1, перевір їх у AWS Pricing Calculator** перед захистом. Колонку "Actual" я заповнив з виводу `scripts/quotas-snapshot.sh` від 5 листопада 2026 року (`docs/evidence/quotas/20261105T173454Z-*`). Це applied значення з `list-service-quotas`. Де воно відрізняється від списку AWS defaults, я пишу обидва.

## 1. Quotas, які можуть обмежити M2

Слайд викладача про вартість називає shard compute найбільшою статтею в M2, тому я зосереджуюсь на тому, що може заблокувати або обмежити compute і мережу.

### 1.1 Service Quotas (рівень акаунта)

| Область | Quota | Публічний default (VERIFY) | Чому це важливо в M2 | Як перевірити | Actual |
|---|---|---|---|---|---|
| VPC | VPCs per region | 5 | Я використовую 1, друга копія для тесту recreate дає 2 | `service-quotas list-service-quotas --service-code vpc` | 5 (`L-F678F1CE`) |
| VPC | Subnets per VPC | 200 | Я використовую 4, з AZ c буде 6 | те саме | 200 (`L-407747CB`) |
| VPC | Internet gateways per region | 5 | 1 | те саме | 5 (`L-A4707A72`) |
| VPC | NAT gateways per AZ | 5 | 0 зараз, 1 якщо ввімкнено | те саме | 5 (`L-FE5A380F`) |
| VPC | Gateway VPC endpoints per region | 20 | 1 (S3) | те саме | 20 (`L-1B52E74A`) |
| VPC | Interface endpoints per VPC | 50 | 0 зараз, у M2 можливо 3 або 4 | те саме | 50 (`L-29B6F2EB`) |
| VPC | Security groups per region / rules per SG / SGs per ENI | 2500 / 60 in + 60 out / 5 | M2 додає приблизно 3 SG | те саме | 2500 / 60 / 5 (`L-E79EC296`, `L-0EA8095F`, `L-2AFB9258`) |
| EC2 | Elastic IP addresses per region | 5 | NAT EIP плюс будь-який фіксований IP coordinator | `ec2 describe-account-attributes` (`vpc-max-elastic-ips`) | 5 (`L-0263D0A3`, `vpc-max-elastic-ips` теж 5) |
| EC2 | Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances, у vCPU | залежить від акаунта, нові акаунти можуть мати низький | 3 x t3.micro = 6 vCPU у M2, 7 вузлів = 14 vCPU у M3 | `service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A` (код підтверджено в знімку) | 256 vCPU (`L-1216C47A`), у списку AWS defaults 5. `max-instances` 20 |
| EBS | gp3 storage per region | десятки TiB | не обмежує | `--service-code ebs` | 50 TiB (`L-7A658B76`) |
| Lambda | Concurrent executions | 1000, але нові або обмежені акаунти можуть мати 10 | якщо coordinator це Lambda, YCSB з більш ніж приблизно 10 threads буде throttled | `lambda get-account-settings` | 1000 (`L-B99A9384`), `get-account-settings` теж 1000, unreserved 1000 |
| Lambda | ENIs (Hyperplane) per VPC | 500 | не обмежує | `--service-code lambda` | немає в знімку, `list-service-quotas` для lambda цю quota не повернув |
| API Gateway | Account throttle (REST) | 10 000 rps steady, 5 000 burst | не обмежує YCSB на micro instances | `--service-code apigateway` | 10 000 rps (`L-8A5B8E43`), burst 5 000 (`L-CDF5615A`) |
| DynamoDB | Tables per region, per table throughput | 2 500 tables (старіша документація каже 256), 40 000 RRU/WRU on-demand | має значення лише якщо я використаю DynamoDB для shard registry | `dynamodb describe-limits` | 2 500 tables (`L-F98FE922`), 40 000 RCU і WCU на table, 80 000 на акаунт (`describe-limits`) |
| ECS / Fargate | Fargate On-Demand vCPU resource count | на нових акаунтах може бути лише 6 | 3 tasks x 0.25 vCPU це нормально, але scale-out в M3 і M5 може його досягти | `--service-code fargate` | 140 (`L-3032A538`), у списку AWS defaults 6. Але `ecs:CreateCluster` у симуляторі `implicitDeny` |
| ELB | Application load balancers per region | 50 | 0 або 1 | `--service-code elasticloadbalancing` | 50 (`L-53DA6B97`) |
| CloudFormation | Stacks per region / resources per template / outputs / exports per region | 2000 / 500 / 200 / кілька тисяч | не обмежує для 3 stacks | `--service-code cloudformation` | 2000 / 500 / 200 / exports немає в знімку (`L-0485CB21`, `L-05BC894F`, `L-87D14FB7`) |
| CloudWatch Logs | Log groups, ingestion rate | великі | не обмежує, але ingestion коштує грошей | `--service-code logs` | 1 000 000 log groups (`L-C7B9AAAB`), PutLogEvents 5 000 tps (`L-7E1FAE88`) |

### 1.2 Обмеження Learner Lab (policies, не quotas)

Зазвичай їх не видно в Service Quotas, бо їх застосовують IAM або SCP policies sandbox. Спочатку це були припущення. 5 листопада 2026 року я перевірив частину з них dry-run пробами з `docs/m1-design-decisions.md` §9.4. Усі деталі в `docs/labrole.md`.

- Регіони. `describe-vpcs` в `eu-central-1` отримав explicit deny від SCP. `us-west-2` я не пробував, тому що він дозволений, поки лише припущення.
- Типи EC2 instance. Dry-run `t3.micro` дозволений, dry-run `m5.4xlarge` отримав explicit deny від identity policy моєї ролі. Повний список дозволених типів я не знаю. Атрибут акаунта `max-instances` дорівнює 20. Число біля 9 я в доказах не бачив.
- Немає IAM writes. `iam:CreateRole` і `iam:CreatePolicy` дають implicit deny. Я думав, що замість цього буду брати готову `LabRole`, але в цьому акаунті її немає (`NoSuchEntity`), а `iam:PassRole` у симуляторі `implicitDeny`. Чи є `LabInstanceProfile`, я ще не перевірив. Це треба вирішити до M2.
- Сесія 3 години, це видно на панелі sandbox. Працюючі EC2 instances можуть бути зупинені, коли сесія закінчується, і запущені знову з наступною сесією (VERIFY), але NAT gateways, EIPs, EBS volumes, load balancers і Fargate services продовжують рахуватися між сесіями.
- Lambda concurrency. Я боявся ліміту 10, але `get-account-settings` і quota `L-B99A9384` показують 1000. `lambda:CreateFunction` у симуляторі allowed, але функції потрібна роль, а з ролями тут проблема вище.
- Якщо кредит вичерпано, lab акаунт вимикається. VERIFY що стається з ресурсами.

Після знімка картина інша, ніж я думав. Service Quotas мають великий запас: 256 vCPU, Lambda 1000, Fargate 140, усі VPC quotas теж. Справді обмежують M2 політика моєї ролі (типи instance, IAM, можливо ECS, бо `ecs:CreateCluster` у симуляторі `implicitDeny`) і кредит $20.

## 2. Бюджет M2 з 2 shards

### 2.1 Змінні

| Символ | Значення | Default |
|---|---|---|
| `N` | compute вузли (1 coordinator + 2 shards) | 3 |
| `H` | години на місяць, поки вузли працюють | 730 (завжди ввімкнено) або 100 (режим lab-hours) |
| `P_ec2` | t3.micro за годину | $0.0104 |
| `G` | gp3 GB на вузол | 8 |
| `P_gp3` | gp3 за GB-місяць | $0.08 |
| `P_ip` | public IPv4 за годину (з лютого 2024) | $0.005 |
| `P_nat_h`, `P_nat_gb` | NAT gateway за годину, за GB оброблених даних | $0.045, $0.045 |
| `P_fg` | Fargate 0.25 vCPU + 0.5 GB за годину (0.25 x 0.04048 + 0.5 x 0.004445) | $0.01234 |
| `L` | GB CloudWatch Logs, що надходять, `P_log` за GB | 2, $0.50 |
| `X` | cross-AZ GB, `P_xaz` за GB (рахується $0.01 out і $0.01 in) | 20, $0.02 |
| `S3` | S3 GB по $0.023 | 1 |
| `Y` | години YCSB client t3.small по $0.0208 | 10 |

### 2.2 Формули

```
compute_ec2  = N * P_ec2 * H
storage      = N * G * P_gp3                      (billed 730 h even when stopped)
public_ip    = n_public_ips * P_ip * H_ip         (H_ip = H for auto-assigned IPs, 730 for EIPs)
nat          = enable_nat * (P_nat_h * 730 + P_nat_gb * nat_gb + P_ip * 730)
logs         = L * P_log
transfer     = X * P_xaz                          (internet egress first 100 GB/month free; VERIFY in Learner Lab)
ycsb         = Y * (0.0208 + P_ip)
total        = compute + storage + public_ip + nat + logs + transfer + S3 + ycsb
```

Я припускаю, що в Learner Lab немає free tier (VERIFY). Якщо free tier діє, реальні числа будуть нижчими.

### 2.3 Сценарії (округлено, USD на місяць)

| Сценарій | Що працює | H = 730 | H = 100 |
|---|---|---|---|
| **A. EC2 lean (мій baseline)** | coordinator t3.micro у public subnet з public IP, 2 shard t3.micro у private subnets, без NAT, S3 endpoint для artifacts | **30.10** | **7.29** |
| B. Fargate + NAT | 3 Fargate tasks, shards private, NAT для ECR pulls, NAT залишений ввімкненим на весь місяць | 68.92 | 42.44 |
| C. Fargate all public | 3 Fargate tasks з public IPs, без NAT (ламає правило "shards private") | 39.49 | 6.71 |
| D. A + NAT | сценарій A плюс один NAT gateway, залишений ввімкненим | 66.83 | 44.02 |
| E. Lambda coordinator | HTTP API + Lambda coordinator у VPC, 2 shard t3.micro private, 1 M requests | 19.95 | 6.85 |

Сценарій A при H = 730, рядок за рядком: compute 3 x 0.0104 x 730 = 22.78, EBS 3 x 8 x 0.08 = 1.92, public IP 1 x 0.005 x 730 = 3.65, logs 2 x 0.50 + storage = 1.06, cross-AZ 20 x 0.02 = 0.40, S3 = 0.03, YCSB client 10 x (0.0208 + 0.005) = 0.26. Сума 30.10.

Сценарій A при H = 100: compute 3.12, EBS 1.92, public IP 0.50, logs 1.06, cross-AZ 0.40, S3 0.03, YCSB 0.26. Сума 7.29.

Сценарій E при H = 730: shards 2 x 7.59 = 15.18, EBS 2 x 8 x 0.08 = 1.28, HTTP API 1 M x $1.00 per M = 1.00, Lambda 1 M x $0.20 per M плюс 1 M x 0.1 s x 0.5 GB x $0.0000166667 = 1.03, logs 1.06, cross-AZ 0.40. Сума 19.95. При H = 100 shards стають 2.08, а решта лишається, тож 6.85. Кожен додатковий мільйон операцій YCSB через API додає приблизно $2.03.

T3 instances за замовчуванням мають "unlimited" CPU credits. Тривале навантаження YCSB може додати $0.05 за vCPU-годину надлишку, тому шаблон M2 мусить задати `CreditSpecification: standard`.

### 2.4 Порівняння з кредитом sandbox

Ліміт я побачив сам на панелі sandbox: **Used $0 of $20**. Це $20 на весь курс, а не на місяць. Спочатку я припускав $50, і це було неправильно, тому всі висновки нижче перераховані від $20. Скільки з цього вже витрачено на інших лабах, я перевірю на AWS Details перед кожною сесією.

| | Ліміт $20 |
|---|---|
| A, завжди ввімкнено | 150 % ліміту за один місяць, не вміщається |
| A, lab-hours (H = 100) | 36 % |
| E, завжди ввімкнено | близько 100 %, не лишає нічого на M3 |
| E, lab-hours | 34 % |
| B або D (NAT залишений ввімкненим) | 220 % і більше, не вміщається |
| Прогноз M3: 7 x t3.micro завжди ввімкнено | понад 250 %, не вміщається |

Мій висновок такий. Завжди ввімкнені сценарії нам не підходять взагалі. M2 вміщається тільки в режимі lab-hours, коли я вмикаю compute на час роботи, видаляю або зупиняю його в кінці кожної сесії і тримаю NAT вимкненим. Ціль для M2 я ставлю **$5 або менше**, щоб залишити хоча б $12 для M3 до M5, де replicas утричі збільшують кількість вузлів. Для M3 і далі може знадобитися запускати локально через docker compose, бо вмістити 7 вузлів у $20 в AWS навіть у lab-hours буде важко. Це я вважаю головним ризиком по бюджету.

Ще одна річ про sandbox. На екрані видно, що сервіси там обмежені списком (Cloud9 лише nano, micro і small, CloudFormation, CloudFront, CloudShell і так далі). Тепер я частину перевірив. VPC і CloudFormation працюють, бо `kvs-network` створився. Dry-run `t3.micro` дозволений. Симулятор для моєї ролі каже allowed для `ec2:CreateNatGateway`, `ec2:AllocateAddress`, `lambda:CreateFunction`, `dynamodb:CreateTable` і `s3:CreateBucket`, а `ecs:CreateCluster` і всі IAM writes заборонені. NAT і Lambda я живо не створював, тому це рішення симулятора, а не доказ. Cost Explorer `ce:GetCostAndUsage` у симуляторі теж allowed, але сам виклик я не робив, тому витрати дивлюсь на панелі sandbox. Мінус чесний: кожна сесія починається з deploy на 3 до 5 хвилин, а все, чого немає в IaC, втрачається.

Лекція також просить внести прогноз M2 у бюджетну таблицю курсу (лекція 2, с.36). Студент робить це з числами сценарію A і вибраним H.
