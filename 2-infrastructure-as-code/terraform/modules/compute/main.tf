# modules/compute/main.tf

# ------------------------------------------------------------------------------
# JENKINS MASTER HOST (Orchestration Dashboard)
# ------------------------------------------------------------------------------
resource "aws_instance" "jenkins_master" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = element(var.public_subnet_ids, 0) # Deploys in Public Subnet A
  vpc_security_group_ids      = [var.jenkins_sg_id]
  key_name                    = var.key_name
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    exec > >(tee /var/log/jenkins-bootstrap.log | logger -t jenkins-bootstrap -s 2>/dev/console) 2>&1

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release openjdk-17-jre docker.io git python3 python3-pip unzip

    systemctl enable --now docker

    if ! getent group docker >/dev/null; then
      groupadd docker
    fi

    if id ubuntu >/dev/null 2>&1; then
      usermod -aG docker ubuntu || true
    fi

    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | gpg --dearmor -o /etc/apt/keyrings/jenkins.gpg
    chmod a+r /etc/apt/keyrings/jenkins.gpg

    echo "deb [signed-by=/etc/apt/keyrings/jenkins.gpg] https://pkg.jenkins.io/debian-stable binary/" > /etc/apt/sources.list.d/jenkins.list

    apt-get update
    apt-get install -y jenkins

    if id jenkins >/dev/null 2>&1; then
      usermod -aG docker jenkins || true
    fi

    systemctl enable --now jenkins

    echo "Jenkins bootstrap completed"
  EOF

  root_block_device {
    volume_size           = 30 # Slightly larger for build history storage
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name      = "dev-jenkins-master"
    Project   = "Multi-Stack-Voting-App"
    Role      = "CI-CD-Orchestration"
    Terraform = "true"
  }
}

# ------------------------------------------------------------------------------
# JENKINS SLAVE HOST (The Build, Trivy & Docker Executor)
# ------------------------------------------------------------------------------
resource "aws_instance" "jenkins_slave" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = element(var.public_subnet_ids, 1) # Deploys in Public Subnet B for distribution
  vpc_security_group_ids = [var.jenkins_sg_id]
  key_name               = var.key_name

  root_block_device {
    volume_size           = 40 # Upgraded space to store Docker build layers and cache
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name      = "dev-jenkins-slave"
    Project   = "Multi-Stack-Voting-App"
    Role      = "Pipeline-Execution-Worker"
    Terraform = "true"
  }
}

# ------------------------------------------------------------------------------
# SONARQUBE SERVER HOST (Static Application Security Testing Dashboard)
# ------------------------------------------------------------------------------
resource "aws_instance" "sonarqube" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = element(var.public_subnet_ids, 0) # Deploys in Public Subnet A
  vpc_security_group_ids      = [var.jenkins_sg_id]
  key_name                    = var.key_name
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    exec > >(tee /var/log/sonar-bootstrap.log | logger -t sonar-bootstrap -s 2>/dev/console) 2>&1

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y ca-certificates curl docker.io

    systemctl enable --now docker

    sysctl -w vm.max_map_count=262144

    docker network create sonarnet || true

    docker rm -f sonar-db sonar-server >/dev/null 2>&1 || true

    docker run -d \
      --name sonar-db \
      --network sonarnet \
      --restart unless-stopped \
      -e POSTGRES_USER=sonar \
      -e POSTGRES_PASSWORD=sonar-dev-password \
      -e POSTGRES_DB=sonar \
      -v sonarqube_db:/var/lib/postgresql/data \
      postgres:15

    until docker exec sonar-db pg_isready -U sonar >/dev/null 2>&1; do
      sleep 5
    done

    docker run -d \
      --name sonar-server \
      --network sonarnet \
      --restart unless-stopped \
      -p 9000:9000 \
      -e SONAR_JDBC_URL=jdbc:postgresql://sonar-db:5432/sonar \
      -e SONAR_JDBC_USERNAME=sonar \
      -e SONAR_JDBC_PASSWORD=sonar-dev-password \
      -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
      -v sonarqube_data:/opt/sonarqube/data \
      -v sonarqube_extensions:/opt/sonarqube/extensions \
      -v sonarqube_logs:/opt/sonarqube/logs \
      sonarqube:lts-community

    echo "SonarQube bootstrap completed"
  EOF

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name      = "dev-sonarqube-server"
    Project   = "Multi-Stack-Voting-App"
    Role      = "SAST-Quality-Gate"
    Terraform = "true"
  }
}