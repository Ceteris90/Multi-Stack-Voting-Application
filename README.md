<!-- © 2024 | Ironhack -->

---

# Multi-Stack Voting Application

This repository is a practical DevOps demo project that shows how a simple voting application evolves into a real distributed system with containers, cloud infrastructure, and automation. It combines a Python voting frontend, a Redis queue, a .NET worker, a PostgreSQL database, and a Node.js result dashboard in one end-to-end workflow.

This project is especially useful for presentations and live demos because it demonstrates how infrastructure, deployment automation, and application runtime behavior all work together in a real environment.

### What this project shows

- how a web application is split into multiple services
- how Docker containers communicate in a real stack
- how Terraform provisions AWS resources
- how Ansible deploys containers to target hosts
- how a database-backed dashboard updates from real vote data
- how runtime issues are diagnosed in a distributed setup

- Docker and container networking
- Infrastructure-as-code with Terraform
- Configuration management with Ansible
- AWS-managed database and networking
- Real-time dashboards with Socket.IO
- Runtime troubleshooting in a multi-service environment

---

## 1. Presentation Summary

For an editable system architecture diagram, see [docs/Aws_web_voting.jpeg](docs/Aws_web_voting.jpeg).

This project is designed to be explained in a short presentation as follows:

1. Start with the user-facing voting app.
2. Explain how the vote is queued in Redis.
3. Show how the .NET worker processes the vote and writes it into PostgreSQL.
4. Show how the Node.js result app reads the database and displays live totals.
5. Explain how Terraform and Ansible automate the AWS deployment path.

This gives the audience a complete picture of the application lifecycle from code to live infrastructure.

---

## 2. Architecture Overview

### Runtime flow

1. A user opens the voting app in the browser.
2. The vote is written to the Redis queue.
3. The .NET worker consumes the queue entry and writes the vote into PostgreSQL.
4. The Node.js result app queries PostgreSQL and streams the updated totals to the browser.

### Current deployment model

This repository supports two main deployment paths:

- Local development with Docker Compose
- Cloud deployment on AWS with Terraform + Ansible

The cloud path uses:

- AWS EC2 instances for the frontend and backend tiers
- An AWS RDS PostgreSQL Multi-AZ instance for the database
- Docker containers deployed with Ansible
- Host networking for the worker and result containers to reach RDS reliably

---

## 2. Repository Layout

- `vote/` – Python Flask voting app
- `worker/` – .NET worker that processes Redis votes into PostgreSQL
- `result/` – Node.js + Express + Socket.IO result dashboard
- `Ansible/` – Ansible deployment playbooks and inventory
- `terraform/` – AWS Terraform modules and environment configuration
- `healthchecks/` – Docker healthcheck scripts
- `docker-compose.yml` – local Docker Compose stack for development/testing

---

## 3. Services in Detail

### Vote app (`vote/`)

- Technology: Python + Flask
- Responsibility: accepts votes from users
- Default port: 80 in Docker, 5000 locally
- Depends on: Redis

### Worker (`worker/`)

- Technology: .NET 8 + Npgsql + StackExchange.Redis
- Responsibility: reads votes from Redis and writes them to PostgreSQL
- Important behavior: retries until the database is reachable
- Depends on: Redis and PostgreSQL

### Result app (`result/`)

- Technology: Node.js + Express + Socket.IO + pg
- Responsibility: reads vote totals from PostgreSQL and serves the dashboard
- Default port: 8080 in the deployed environment, 4000 locally
- Important behavior: uses real-time Socket.IO updates and polls the DB for totals

### Redis (`redis:alpine`)

- Responsibility: temporary queue for votes
- Default port: 6379

### PostgreSQL (`RDS` in cloud, `postgres:15-alpine` in local Compose)

- Responsibility: durable storage of votes
- In the cloud deployment, this is an AWS RDS Multi-AZ PostgreSQL instance for higher availability

---

## 4. Local Development

### Prerequisites

Install the following tools:

- Docker Engine + Docker Compose
- Python 3.10+
- Node.js 18+
- .NET 8 SDK
- Redis (optional if not using Docker Compose)
- PostgreSQL (optional if not using Docker Compose)

### Option A: Run the full local stack with Docker Compose

From the repository root:

```bash
docker compose up --build
```

This starts:

- vote app on http://localhost:8080
- result app on http://localhost:8081
- Redis on localhost:6379
- PostgreSQL on localhost:5432

To stop the stack:

```bash
docker compose down
```

To remove volumes and reset the DB:

```bash
docker compose down -v
```

### Option B: Run services individually

#### Vote app

```bash
cd vote
pip install -r requirements.txt
python app.py
```

Open: http://localhost:5000

#### Worker

```bash
cd worker
dotnet restore
dotnet run
```

#### Result app

```bash
cd result
npm install
node server.js
```

Open: http://localhost:4000

#### Redis

```bash
redis-server
```

#### PostgreSQL

Use any local PostgreSQL instance, or run the Compose-managed database.

---

## 5. Docker Images

The project uses the following image naming convention:

- `ceteris90/vote:latest`
- `ceteris90/worker:latest`
- `ceteris90/result:latest`

To build locally:

```bash
docker build -t ceteris90/vote:latest ./vote
docker build -t ceteris90/worker:latest ./worker
docker build -t ceteris90/result:latest ./result
```

To push to Docker Hub:

```bash
docker push ceteris90/vote:latest
docker push ceteris90/worker:latest
docker push ceteris90/result:latest
```

---

## 6. AWS Infrastructure with Terraform

The Terraform configuration under `terraform/` provisions the cloud environment used for the live deployment.

### What is created

- VPC and subnets
- Public and private subnet tiers
- Security groups for frontend, backend, and database access
- EC2 instances for frontend and backend roles
- An AWS RDS PostgreSQL Multi-AZ instance
- ALB and ASG-related resources for the web tier

### Important notes

- The database is not a manually installed EC2 PostgreSQL host anymore; it is managed by AWS RDS.
- The RDS instance is designed for availability across multiple AZs.
- The worker and result containers use host networking in the deployed environment to reach the managed database reliably.

### Validate and plan Terraform

From `terraform/environments/dev/`:

```bash
terraform fmt -recursive
terraform init -backend=false
terraform validate
terraform plan -refresh=false -no-color
```

### Apply Terraform

```bash
terraform apply -auto-approve
```

### Useful outputs

The environment exposes:

- `db_endpoint` – RDS DNS name
- `db_port` – RDS port
- `alb_dns_name` – ALB DNS name
- `asg_name` – autoscaling group name

---

## 7. Deployment with Ansible

The Ansible playbooks under `Ansible/` deploy the containerized services to the AWS hosts.

### Main playbooks

- `Ansible/playbook-setup.yml` – prepares the target hosts
- `Ansible/playbook-deploy.yml` – deploys Redis, the worker, the vote app, and the result app

### Inventory

The inventory is defined in:

- `Ansible/hosts`
- `Ansible/inventory.ini`

### Deploy the stack

From `Ansible/`:

```bash
~/.local/bin/ansible-playbook -i inventory.ini playbook-deploy.yml
```

### Syntax check only

```bash
~/.local/bin/ansible-playbook --syntax-check playbook-deploy.yml
```

### What the deployment does

- Starts `redis-queue` on the backend host
- Starts `integration-worker` on the backend host
- Starts `voting-app` on the frontend host
- Starts `results-app` on the frontend host
- Injects DB endpoint and credentials into the containers

---

## 8. Environment Variables

### Result app

The result app uses these variables:

- `PG_HOST`
- `PG_PORT`
- `PG_USER`
- `PG_PASSWORD`
- `PG_DATABASE`
- `DATABASE_CONNECTION_STRING`
- `CONNECTION_STRING`
- `PG_SSL`
- `PORT`

### Worker app

The worker uses:

- `DB_HOST`
- `DB_PORT`
- `DB_USERNAME`
- `DB_PASSWORD`
- `DB_NAME`
- `DB_SSL`
- `REDIS_HOST`

If you change the database endpoint, ensure both the app and the deployment playbook reference the same values.

---

## 9. Troubleshooting

### Result page shows 50/50 or no real data

This usually means one of the following:

1. The result app is still running an old image version
2. The DB connection is failing
3. The database is reachable but the vote table is empty

Useful checks:

```bash
ssh -i ./Ansible/myironhackerkey.pem ubuntu@3.219.170.134
sudo docker logs --tail 100 results-app
sudo docker exec -it results-app node -e "...pg connection test..."
```

### Worker container is stuck on “Waiting for db”

If the worker is still waiting for the database after the deployment changes, the issue is usually infrastructure-level and not fixed by re-running Ansible alone. In that case, confirm:

- the RDS endpoint is reachable from the worker host
- the security group allows PostgreSQL traffic
- the database is actually available in the VPC
- the worker image and environment variables are current

### RDS TLS / SSL issues

If PostgreSQL TLS validation fails, ensure:

- the connection string uses the correct DB endpoint
- the app uses the same SSL handling expected by the PostgreSQL client library
- the runtime image contains the needed CA certificate store

---

## 10. Recommended Validation Commands

After any deployment change, run these checks:

```bash
# Terraform
terraform fmt -recursive
terraform init -backend=false
terraform validate
terraform plan -refresh=false -no-color

# Ansible
~/.local/bin/ansible-playbook --syntax-check playbook-deploy.yml
~/.local/bin/ansible-playbook -i inventory.ini playbook-deploy.yml

# Docker
docker compose up --build
docker ps
docker logs results-app
docker logs integration-worker
```

---

## 11. How to Demo This in 5 Minutes

Use this flow for a short presentation or submission demo:

1. Open the voting page and explain that the user action starts the workflow.
2. Show the Redis/worker/database path briefly and describe how votes are persisted.
3. Open the result page and show that the totals are being read from PostgreSQL.
4. Highlight the Terraform and Ansible automation that deployed the stack to AWS.
5. Mention one real troubleshooting lesson from the project, such as the RDS connectivity and TLS issue that was resolved during deployment.

This gives the audience a clear story: application → infrastructure → automation → troubleshooting.

---

## 12. Demo Talking Points

If you are presenting this project, these are the strongest points to emphasize:

- The app is intentionally multi-service, which makes it realistic.
- The result page is not just a static UI; it reflects real database state.
- The infrastructure is automated with Terraform and Ansible rather than manual setup.
- The database uses AWS RDS Multi-AZ, which shows how availability is handled in cloud architecture.
- Troubleshooting the result app and worker container demonstrates real-world DevOps operations.

## 13. Summary

This project is a practical example of a small but realistic distributed application that combines:

- containerized microservices
- real database persistence
- AWS infrastructure automation
- deployment automation with Ansible
- live dashboarding and troubleshooting workflows

It is suitable for learning how modern DevOps pipelines connect code, infrastructure, and runtime behavior in one end-to-end project.

---
