# M1 research notes: IAM, FinOps, IaC / CloudFormation

Sources
- A = `/Users/admin/Downloads/2__Identity__Access__FinOps.pptx.pdf` (37 pp, lecture 2). Page refs = PDF page numbers. "ACAv3 Mxx s.N" = original AWS Academy slide number, credited on the slide.
- B = `/Users/admin/Downloads/2.1 IaC. CFN.pptx.pdf` (10 pp, lecture 2.1). Page refs = PDF page numbers.
- Slides are in Ukrainian with some English terms. Translations below are mine.

## 0. Coverage gap
The slides do NOT cover: CFN Mappings, Outputs/Exports, change sets, drift detection, rollback, nested or cross-stack references, and CFN code snippets. These need another source (AWS CloudFormation docs or lecture recording). Nothing below fills them in.

## 1. IAM concepts (A p.8-9, 12-13, 21)
- **Principal**: an entity that is granted or restricted rights (p.8-9).
- **IAM user**: long-term identity for people. Lecturer's standard for humans: IAM Identity Center (p.8-9).
- **User group**: a set of users that share attached policies (p.9, 12).
  - A user can be in several groups; their policies add up (union).
  - Groups do not nest.
  - A group is not an identity: you cannot be "a group", and you cannot name a group as a principal in a resource policy (p.12).
- **IAM role**: identity with no permanent credentials. It is assumed and issues temporary credentials for the session (p.13, 21). Used by people, services, EC2, Lambda, and (per slide) agents, "see week 9" (p.21).
  - A role can be a principal and work cross-account. A group cannot (p.13).
  - Lecturer's rule: people get Identity Center, machines get roles, long-lived keys go to nobody (p.21).
- **Least privilege**: grant rights as narrowly ("порційно", in small portions) as possible (p.8-9).

### Policy types (p.10)
1. Identity-based: attached to user, group, or role.
2. Resource-based: attached to the resource, e.g. S3 bucket policy. Says who may access it.
3. Permissions boundary: maximum rights an identity can use, whatever its policies say.
4. Organizations SCP: guardrail on an org or OU.

### Policy JSON (p.11)
- A policy is a JSON document of statements. Each statement answers: Effect (Allow/Deny), Action, Resource (ARN or `*`), Condition (IP, tags, MFA, time).
- Slide: "deny always stronger" than allow.
- Slide: `Principal` appears only in resource-based policies.

Snippet from slide p.11:
```json
{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::cafe-menu/*"}
```

### Evaluation logic (p.14, credit ACAv3 M03 s.32)
1. Evaluate all applicable policies.
2. Any explicit Deny -> Deny.
3. Else any explicit Allow -> Allow.
4. Else implicit Deny.

### Worked examples
- **Bob** (p.15, ACAv3 M03 s.34): identity policy allows Get, Put, List on bucket X. Resource policy on bucket X allows Get and List, denies Put. Slide answer: Bob can GET and LIST bucket X, cannot PUT.
- **Zhang** (p.11-12, ACAv3 M09 s.11-12): user policy allows S3 and DynamoDB, explicitly denies Kinesis. Developer group allows S3, Athena, DynamoDB, Kinesis.
  - Athena: allowed (via group).
  - Kinesis: denied (user-level explicit deny beats group allow).

### Access models (p.18-20)
- RBAC: permissions per job role. Scales badly: each new resource means editing multiple policies (p.18, ACAv3 M09 s.13). Leads to "role bloat".
- ABAC: one policy matches tags/attributes such as `env=dev`, `project=maint` (p.19, ACAv3 M09 s.16). Slide: one policy for all permissions; new resources must carry attributes.
- p.20 table (RBAC vs PBAC vs ABAC): basis, flexibility, maintenance, best-for. Table is from Clarity Security (third party), not AWS.

### Permission boundary vs SCP (p.24-26, ACAv3 M09 s.50-51)
- Permission boundary: applies to one IAM user or role. Sets the maximum identity policies can grant. Grants nothing on its own.
- SCP: applies to all accounts in an org or OU. Sets maximum permissions for those accounts. Grants nothing on its own. Can deny.
- Combined example (p.25): SCP on test OU denies `ec2*` and `sqs*`. Identity policy allows `ec2:DescribeInstances`, `kms*`, `s3*`, `sqs:SendMessage`. Permission boundary allows `s3*`, `sqs*`.
  - EC2 DescribeInstances: No (SCP explicit deny).
  - KMS: No (outside boundary).
  - S3: Yes (inside boundary, no explicit deny).
  - SQS SendMessage: No (SCP explicit deny).

### Organizations (p.23-24)
- Organization = account hierarchy with central management. OU = group of accounts, can nest. SCP = guardrail that nobody inside an account can bypass.
- Sandbox has no Org. In M1, write policies as code; do not try to attach SCPs (p.24).
- Slide warning (p.24): "If you create an org in the account, the free tier will fly away" (ЗЛЕТИТЬ ФРІ ТІР). Literal meaning is unclear; read it as "do not do this".

### Lab steps (p.22, Live demo)
1. Log in to awsacademy.instructure.com with school email (Canvas).
2. Dashboard -> course "AWS Academy Learner Lab". This is a separate course from Cloud Architecting.
3. Modules -> Launch AWS Academy Learner Lab -> Start Lab.
4. Wait for the AWS circle to turn green, then click it to open the console.
5. AWS Details: budget ($), CLI credentials, session timer.
- ACA labs (guided/cafe) launch from their own module in the Cloud Architecting course, each with its own environment.
- Lecturer's demo plan: create user and group, hit the wall, read LabRole policy, attach a role with S3-read to EC2 and verify (p.22).

## 2. FinOps, cost, regions, quotas (A p.2-7, 27-37)
### Regions and AZs
- Slide counts (p.2): 39 (+2) regions, 124 (+7 planned) AZs. Old figure: 32 regions / 102 AZs three years ago. The map credit reads 3-4-24. **Verify current counts before citing.**
- Region (p.3): geographic area with 3+ physically separated data center groups. Choosing a region matters for compliance (jurisdiction) and latency. Not all services exist in all regions (slide bolds this).
- Region example (p.4): us-west-1 (N. California) with AZs us-west-1a, 1b, 1c.
- AZ (p.5): one or more discrete data centers with redundant power and networking. Interconnected with low-latency, high-bandwidth fiber. All traffic between AZs is encrypted. Synchronous replication between AZs is feasible. AZs are many km apart, all within 100 km.
- Relevant to M1 VPC (public/private subnets across AZs). Cross-AZ traffic is a cost item (see Transit below).
- Local Zones, Wavelength, Outposts (p.6): one line each; not needed for M1.
- Snow Family (p.7): omitted, not M1. The slide's overlay says Snowcone is gone and gives new Snowball Edge models. Source is a third-party exam cheat sheet, so treat as dated.

### Cost structure (p.28)
- Total infra cost = Compute + Storage + Databases + Runtime (licences) + Transit (network, transfer) + Observability (logs, metrics, alerts) + Redundancy + Support + Dev infra (deploys, artifacts, AI assistants).
- Lecturer: each line item is a separate optimization handle. The chart legend includes "Tax".

### Savings example (p.29)
- No-upfront savings plan (2023): -33% on database Reserved Instances.
- -5% for moving DB to ARM.
- -14% for pre-purchase serverless compute for a cluster.
- Slide total: **-17% at once**.
- Lecturer: for upfront payments, compute present value (PV), because capital has a cost.
- Footnote: Cost Optimization Hub does not de-duplicate estimated savings between recommendations and RI/Savings Plan purchases.
- **Flag:** the three components sum to 52%, not 17%. The slide does not explain the basis, so treat -17% as an example, not a formula.

### Utilization and rightsizing (p.30)
- Observability first; without it, rightsizing is guesswork.
- Steady load -> serverless or autoscaling (slide example: DynamoDB on-demand).
- Usage spikes -> built-in alerts. Fixing anomalies saves money and speeds things up.
- Slide claims "12x ETL" with no context. **Flag as unclear.**

### Tags and cost centers (p.31)
- Tagging strategy: environment / team / product.
- Spend should be visible per team and product; attribute anomalies to specific resources.

### FinOps framework (p.27, 32-35)
- Crawl (basic cost monitoring) -> Walk (forecasting, optimization) -> Run (strategic, data-driven decisions) (p.27).
- Principles (p.33-34): teams collaborate; business value drives tech decisions; everyone owns their usage; data accessible, timely, accurate; FinOps enabled centrally; use the variable cost model.
- Framework diagram (p.32) and personas (p.35) are from FinOps Foundation. Core personas: Engineering, FinOps Practitioner, Finance, Procurement, Product, Leadership.

### Capstone cost (p.36)
- Compute: shard nodes (M2), largest line item.
- Storage: EBS volumes for replicas (M3).
- Transit: replication traffic between AZs (M3). Lecturer: "students forget this first".
- Observability: metrics and alerts (M4).
- Budget = sandbox credit ceiling.
- M1 task: enter the M2 cost forecast into the sheet.

### Weekly skills and practice (p.37)
- SEC-1 (star): IAM foundations. Knowledge check M3.
- SEC-2: policies as code. Starts now, finishes in M1.
- CF-2: cost estimate. Budget worksheet plus M1.
- Practice order: LabRole dissection -> Examining IAM Policies (ACA) -> S3 + roles -> budget.
- ACA M1-M3 in Canvas, due before lecture 3.

## 3. Infrastructure as Code and CloudFormation (B)
- **Imperative vs declarative** (B p.2): imperative = explicit steps (bash scripts, CMake). Declarative = describe the outcome; the system decides how.
- **Idempotence** (B p.3-4): slide asks how to deploy 5 containers and a DB, answer "need idempotent". Slide does not give a formal definition.
- **Open question** (B p.3): "Is SQL declarative or imperative?" Slide gives no answer.
- **IaC definition** (B p.5): provisioning and managing compute and network resources through code, instead of manual setup. Can be scripts or declarative definitions and templates kept in version control. Term is mostly used for declarative descriptions.
- **Terraform** (B p.6): cloud-agnostic, HashiCorp. HCL or JSON. Declarative, performs CRUD toward desired state. Reusable modules. Not the M1 tool.
- **CloudFormation** (B p.7-8): declarative. Template in YAML or JSON. Workflow: code the template -> (optional S3 upload) -> CloudFormation creates a stack.
  - Stack = resources managed as one unit. Template defines the stack so resources can be created, deleted, or updated predictably.
- **Features list** (B p.9):
  - `DependsOn`: slide example is an S3 bucket and a Glue table in one stack; bucket must exist first.
  - Parameters: values given at create/update time. Example: DB size or replica count for qa vs prod.
  - Conditions: `Fn::If`, example "if env is QA, enable scale-down". Slide writes `Fn:If`.
  - Intrinsic functions: read params from SSM, calculate CIDR. Slide also says "limitless", which is unclear. **Flag.**
- **Idempotence caveat** (B p.10): not all things are idempotent (S3, Iceberg, etc.). Slide is unfinished.
- No CFN code snippets in the slides.

## 4. Uncertain or to verify
1. Region and AZ counts (A p.2) are dated; check AWS current numbers.
2. Snow Family overlay (A p.7) on model replacement; third-party source; not M1.
3. Savings case -17% (A p.29): components do not add to 17%.
4. "12x ETL" (A p.30): no context.
5. "ЗЛЕТИТЬ ФРІ ТІР" (A p.24): literal meaning unclear.
6. "limitless" in intrinsic functions (B p.9): unclear.
7. RBAC/PBAC/ABAC table (A p.20) is third-party (Clarity Security), not AWS.
8. Agents as IAM role consumers: slide says "see week 9" (A p.21).
9. Coverage gaps listed in section 0.
