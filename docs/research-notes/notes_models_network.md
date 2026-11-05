# Notes: cloud service models and cloud networking

Sources (English notes from Ukrainian/English slides; page numbers = PDF page index, printed slide number in brackets where visible):
- **[S]** `/Users/admin/Downloads/1 - _ як сервіс.pdf` (38 pp; "Cloud architectures" lecture; PDF page = slide number)
- **[N]** `/Users/admin/Downloads/3.2. Cloud networking.pptx.pdf` (20 pp; "Cloud networking" lecture; no printed numbers except p.17-18)

Flags: **[UNCLEAR]** = slide is ambiguous or inconsistent. **[NOT IN SLIDES]** = general AWS knowledge added for convenience; verify before using in an answer.

---

## 1. Course / Milestone context (S p.33-34, 38)

- M1 = Infrastructure: "IaC from scratch, budget" [S p.14]. Milestones M2 sharding, M3 replication, M4 monitoring, M5 production [S p.14].
- Grading: 40 skills, 10 are core (mandatory for passing), 100 points max, late penalties separate [S p.12].
- Lecturer's own practical examples: IaaS = Apache httpd on EC2; PaaS = Lambda; SaaS = OnePage landing generator [S p.35-37].

---

## 2. Cloud definition

- Cloud computing: on-demand network access to a shared, configurable pool of resources (networks, servers, storage, apps, services) that can be provisioned and released quickly with minimal management effort or provider interaction [S p.15].
- The three service groups (lecturer's list): IaaS, PaaS, SaaS, plus "XaaS = everything as a service" [S p.20].

## 3. Cloud advantages / disadvantages (S p.17-18)

Advantages: scalability and elasticity; security; lower infra support cost; ecology; compliance (GDPR etc.); proximity to users; fast deployment; high availability; pay-as-you-go (no upfront cost); high resource utilization.

Disadvantages: no direct control over data (security); infra cost; vendor lock-in; dependence on internet connectivity (intranet for some solutions).

---

## 4. Service models

### Control pyramid (S p.21)
| Model | Who uses it (slide) | Examples on slide | Control |
|---|---|---|---|
| SaaS | end users | Gmail, Trello, Salesforce CRM, Office 365, Google Docs | least |
| PaaS | software developers | Heroku, AWS Elastic Beanstalk, Google App Engine | middle |
| IaaS | IT administrators | EC2, Azure, Google Compute Engine | most |

### Shared-responsibility-style diagram (S p.22)
Slide shows the Azure stack (hosted apps / dev tools + DB + BI / OS / servers + storage / networking firewalls + security / DC building) with SaaS, PaaS and IaaS brackets.
**[UNCLEAR]** The slide does not state which layers the customer manages. Do not present a specific responsibility split as "from the slide" without checking the lecture or AWS shared-responsibility docs.

### IaaS (S p.23-25)
- Definition: computing infrastructure (usually as virtualization) provided as a service.
- Three components: hardware (servers, storage, client systems, network gear); OS and system software (virtualization, automation, resource management); middleware (e.g., for system management).
- Conclusion (p.24): removes the need to run complex data-center, client and network infrastructure; reduces capital and operating costs; extra savings when infra is shared.
- Examples (p.25): AWS EC2, S3, SQS, VPC; Azure VMs, Blob Storage; Google Compute Engine, Cloud Storage; DigitalOcean droplets, spaces.
  **[UNCLEAR]** p.25 writes "S3 (**not anymore**)" next to AWS. Meaning not explained.

### PaaS (S p.26-28)
- Definition: a platform for developing, testing and deploying applications, without managing physical infra or OS directly (p.26). Covers the full app lifecycle: build, test, deploy, manage, update.
- Three types (p.27):
  1. Platform for deploying platforms: Kubernetes, ECS, Google App Engine.
  2. Platform for running app code: AWS Lambda, Heroku.
  3. Application platform PaaS: Firebase, Backendless, Cloud Foundry.
- Conclusions (p.28): raises development and deployment speed while keeping flexibility; lecturer says enterprises starting in "202*" are mostly built on PaaS.
- Downside (p.28): you do not control the platform lifecycle. Lecturer's example: runtimes/cubes get updated, which can break you (e.g., you lose a domain).

### SaaS (S p.29-32)
- Definition: vendor builds, hosts and manages a web app; customers pay for use (via web/API), not ownership (p.29). "On-demand" is a close term.
- SaaS vs hosted application (p.30): SaaS is a higher abstraction (it solves a problem); the real difference is the distribution/monetization model. Cloud gaming = SaaS. Buying a game and running it on your own resources = hosted application.
- Pros (p.31): fast integration; low support cost for your team; automatic updates.
- Cons (p.31): dependency on the provider (if the partner fails, you may too); limited flexibility; isolation not always possible. Also cites Unity charging "20 cents" (no context on what is charged per; **[UNCLEAR]**).
- Examples (p.32): Salesforce, Google Docs, SAP ERP; Claude and ChatGPT (and their APIs) as SaaS; niche: TechWolf, Onepage. Emerging "agentic SaaS" (research agents, support, code review).

### Hybrids (S p.33)
- IaaS+PaaS: IaaS for legacy infrastructure, PaaS for new components.
- PaaS+SaaS: example Watson IoT hub (integration platform on one side, AI services offered on the other).

### Cloud timeline (S p.19, context only)
AWS SQS (Nov 2004); S3 and EC2 (2006); Google App Engine preview PaaS (Apr 2008); Project Red Dog / Azure announced (Oct 2008); AWS RDS SaaS database (Oct 2009); BigQuery + Predictions API (May 2010); ChatGPT (Nov 2022).

### Lecturer's model-choice hints (what the slides actually say)
- Move up the stack (IaaS -> PaaS -> SaaS) when you want less to operate and faster delivery; cost is less control and possible lock-in (S p.21, 28, 31).
- Use IaaS when you need full control over OS/network/hardware (S p.21, 23-24).
- Hybrids are shown as valid for mixing legacy (IaaS) with new code (PaaS) (S p.33).

---

## 5. Regions, Availability Zones, edge

- Region = geographic area; AZ = a site within a region. Slide shows AWS regions `us-east-1` and `eu-central-1` (S p.5-6). Diagram places S3 + CloudFront in us-east-1 and Cognito, API Gateway, Lambda, RDS, CloudWatch in eu-central-1 (S p.5).
- Edge: CloudFront sits in front of S3 for the user (S p.5). No further edge/CDN detail on slides.
- Lab lesson (S p.6): Lambda -> RDS needs a connection pool / **RDS Proxy** ("We need pool/RDS proxy"). Serverless functions open many DB connections; a proxy pools them.
- Network slides: each subnet lives in exactly one AZ (N p.7). Diagram (N p.7) shows Region > VPC spanning AZ A and AZ B, each with a public and private subnet.

---

## 6. VPC and IP addressing

### CIDR (N p.2-3)
- CIDR = Classless Inter-Domain Routing. Notation `ip/prefix`; prefix = number of leading 1-bits in the mask (N p.2).
- Slide example: `/28` -> mask `255.255.255.240` (last octet `1111 0000` = 240). Calculator screenshot shows `/28` = 16 total hosts.
  **[UNCLEAR]** the header example reads `255.255.255.255/28`. That is a mask, not a network address; use `x.x.x.x/28` in your own work.
- Derived math from slide numbers: addresses = 2^(32 - prefix). /8 = 16,777,216; /12 = 1,048,576; /16 = 65,536; /28 = 16.
- **[NOT IN SLIDES]** AWS reserves 5 IP addresses per subnet (network, VPC router, DNS, future use, broadcast), so a /28 gives 11 usable addresses. Verify against AWS docs.

### Private ranges (N p.4)
| Range | Addresses | Largest CIDR | Host bits | Classful description |
|---|---|---|---|---|
| 10.0.0.0 – 10.255.255.255 | 16,777,216 | 10.0.0.0/8 | 24 | single class A |
| 172.16.0.0 – 172.31.255.255 | 1,048,576 | 172.16.0.0/12 | 20 | 16 class B |
| 192.168.0.0 – 192.168.255.255 | 65,536 | 192.168.0.0/16 | 16 | 256 class C |
Slide says private addresses are not routed on the Internet; ISPs increasingly hand out private addresses because of IPv4 scarcity.

### VPC (N p.5-6)
- Amazon VPC = logically isolated section of AWS cloud. You choose the IP range, create subnets, configure route tables and gateways. IPv4 and IPv6 supported (N p.5).
- Console example (N p.6): "VPC and more", IPv4 CIDR `10.0.0.0/16` (65,536 IPs). Slide says the CIDR block size must be between **/16 and /28**. IPv6: none selected. Creates 4 subnets (public + private in eu-central-1a and eu-central-1b) and 3 route tables (`project-rtb-public`, `project-rtb-private1-eu-central-1a`, `project-rtb-private2-eu-central-1b`).

### Subnets (N p.7-8)
- A subnet is an IP range inside the VPC; resources such as EC2 are placed in subnets. Each subnet must sit entirely within one AZ; subnet CIDRs must **not overlap** (N p.7).
- Subnet types (N p.7):
  - **Public**: has a route to an Internet Gateway; resources can reach the internet.
  - **Private**: no direct route to an IGW; needs a NAT device to reach the internet.
  - **VPN-only**: route to a Site-to-Site VPN via a virtual private gateway; no route to the IGW.
  - **Isolated**: no routes outside the VPC; reachable only from inside the VPC.
- Recommendation: "**DB only in private subnets**" (N p.8).

### Route tables (N p.9)
- Route table = set of rules that decide where the subnet's traffic goes.
- Steps shown: (1) attach IGW to VPC (`igw-...`, state Attached); (2) add route `0.0.0.0/0 -> Internet Gateway` (the `10.0.0.0/16 -> local` route stays); (3) associate the route table with the subnet (subnet association).
  **[UNCLEAR]** The screenshot names the table `private-rt`, yet it has the `0.0.0.0/0 -> IGW` route and the subnets are associated with it. By the slide's own definition, subnets with an IGW route are public. Name and content contradict each other. Do not copy this as an example of a private subnet.

### Connectivity demo (N p.10)
- Connected to an EC2 instance in a public subnet and pinged a private IP (`10.0.28.109`) in the same VPC. Works via the `local` route.

---

## 7. Internet Gateway (IGW) and NAT

- **IGW**: bidirectional internet access for the VPC (N p.9). Needs a route `0.0.0.0/0 -> igw` in the subnet's route table.
- **NAT** (N p.11-13): NAT (Network Address Translation) rewrites the IP address in packet headers at the routing device. One public address lets many private resources reach the internet, and they stay unreachable from outside. Slide also mentions routing traffic between subnets with overlapping addresses. One word in the slide ("еллау-лістити") is garbled; probably "allow-listing"; **[UNCLEAR]**.
- Placement rule (N p.12): "**Public IPs can only be obtained in a public subnet**", hence "Put NAT in public subnets".
- Diagram (N p.13): traffic from private-subnet instances goes to the NAT Gateway in the public subnet, which then reaches the Internet Gateway, then WWW. Public-subnet instances go to the IGW directly.

---

## 8. Security groups vs Network ACLs

### Analogy (N p.16)
- Security group = key to the apartment door (per resource). Network ACL = doorman in the building (per subnet).

### Security groups (N p.14, 17)
- Firewall for a resource. Timeouts usually mean a misconfigured SG (N p.14).
- Example rule (N p.14): Custom TCP, port 5432 (PostgreSQL), source "My IP".
- Resources in the same SG can reach each other (N p.14).
- Example rule (N p.17): inbound HTTPS TCP 443 from the load balancer's SG ID.
- **Stateful**.

### Network ACLs (N p.18)
- Operate at subnet level. **Stateless**.
- Rules have a number; evaluation in ascending order, stop at first match. Last rule `*` = deny all.
- Example (N p.18): inbound 100 allow TCP 443 from a single /32; `*` deny all. Outbound 100 allow TCP 443 to `0.0.0.0/0`; `*` deny all.

### Comparison table (N p.19)
| | Security groups | Network ACLs |
|---|---|---|
| Level | resource | subnet |
| Rule types | allow only | allow and deny |
| State | stateful (return traffic auto-allowed) | stateless (return traffic evaluated against inbound/outbound set) |
| Evaluation | all rules | in number order; stops at first match |
| New object, inbound | nothing allowed | all allowed (slide) |
| New object, outbound | all allowed | all allowed (slide) |

**[UNCLEAR] / [NOT IN SLIDES]**: slide says a new NACL allows all inbound and outbound by default. AWS docs say a custom NACL created from console/API denies all by default; the default NACL of a VPC allows all. Verify before answering "defaults" questions.
**[NOT IN SLIDES]** Stateless means return traffic needs explicit allow rules, usually for ephemeral ports (1024-65535). Not on slides.

---

## 9. Elastic Network Interface (ENI) (N p.15)
- Virtual NIC; can attach to EC2, containers (ECS), Lambda and other compute.
- Can move between resources to give failover.
- Slide: "можна обходити обмеження в 5 elastic IP" = you can get around the 5-Elastic-IP limit (ENI). Slide claim, not verified here. **[NOT IN SLIDES]** 5 EIPs per region is the AWS default quota; check current quotas.

---

## 10. VPC endpoints (N p.20)
- Interface VPC endpoint: an ENI with a security group in a private subnet; traffic to other managed AWS services (e.g., S3 in the diagram) goes through the **AWS PrivateLink** network, not the internet.
- An IAM policy can be attached to the endpoint.
- **[NOT IN SLIDES]** Gateway endpoints (S3, DynamoDB, route-table based) are not covered in either file.

---

## 11. Not covered in these two files (do not answer from these notes)
- Peering, Transit Gateway (TGW), VPN details beyond the VPN-only subnet type.
- Infrastructure as Code (IaC) tools; roles vs groups; IAM policy allow/deny evaluation.
- Route-table longest-prefix rules; AWS shared-responsibility model in detail.

---

## 12. Quick facts for control questions
- Control order: IaaS (most) > PaaS > SaaS (least) (S p.21).
- Private IPv4 ranges: 10/8, 172.16/12, 192.168/16 (N p.4).
- VPC CIDR: /16 to /28 (N p.6).
- Subnet: single AZ; no CIDR overlap inside one VPC (N p.7).
- Public subnet = route to IGW; private = NAT route; isolated = no outside route (N p.7).
- SG = stateful, resource-level, allow-only. NACL = stateless, subnet-level, allow and deny, ordered rules (N p.19).
- Public IP only in public subnet; NAT goes in public subnet (N p.12).
- DB only in private subnets (N p.8).
