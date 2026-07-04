# Continuous Integration / Continuous Deployment Configuration Examples

## GitHub Actions Workflow

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy Voting App

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]
  workflow_dispatch:

env:
  AWS_REGION: us-east-1
  REGISTRY: docker.io
  IMAGE_TAG: ${{ github.sha }}

jobs:
  validate:
    name: Validate Configuration
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Run validation checks
        run: chmod +x validate.sh && ./validate.sh

  build:
    name: Build & Push Images
    runs-on: ubuntu-latest
    needs: validate
    if: github.event_name == 'push' && (github.ref == 'refs/heads/main' || github.ref == 'refs/heads/develop')
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v2
      
      - name: Login to Docker Hub
        uses: docker/login-action@v2
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_PASSWORD }}
      
      - name: Build and push Vote image
        uses: docker/build-push-action@v4
        with:
          context: ./1-application-source/vote
          push: true
          tags: ${{ secrets.DOCKER_USERNAME }}/voting-app-vote:${{ env.IMAGE_TAG }}
          cache-from: type=registry,ref=${{ secrets.DOCKER_USERNAME }}/voting-app-vote:latest
          cache-to: type=inline
      
      - name: Build and push Result image
        uses: docker/build-push-action@v4
        with:
          context: ./1-application-source/result
          push: true
          tags: ${{ secrets.DOCKER_USERNAME }}/voting-app-result:${{ env.IMAGE_TAG }}
          cache-from: type=registry,ref=${{ secrets.DOCKER_USERNAME }}/voting-app-result:latest
          cache-to: type=inline
      
      - name: Build and push Worker image
        uses: docker/build-push-action@v4
        with:
          context: ./1-application-source/worker
          push: true
          tags: ${{ secrets.DOCKER_USERNAME }}/voting-app-worker:${{ env.IMAGE_TAG }}
          cache-from: type=registry,ref=${{ secrets.DOCKER_USERNAME }}/voting-app-worker:latest
          cache-to: type=inline

  deploy-dev:
    name: Deploy to Development
    runs-on: ubuntu-latest
    needs: build
    if: github.ref == 'refs/heads/develop'
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v2
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ env.AWS_REGION }}
      
      - name: Setup deployment environment
        run: |
          chmod +x deploy.sh validate.sh
          # Create config from secrets
          cat > deployment.config << EOF
          AWS_REGION=${{ env.AWS_REGION }}
          TF_VAR_key_name=${{ secrets.TF_KEY_NAME }}
          TF_VAR_ami_id=${{ secrets.TF_AMI_ID }}
          DOCKER_REGISTRY=${{ env.REGISTRY }}
          DOCKER_REGISTRY_USERNAME=${{ secrets.DOCKER_USERNAME }}
          POSTGRES_PASSWORD=${{ secrets.POSTGRES_PASSWORD }}
          DEPLOY_METHOD=kubernetes
          SKIP_BUILD=true
          EOF
      
      - name: Deploy to EKS Development
        run: ./deploy.sh kubernetes --dry-run

  deploy-prod:
    name: Deploy to Production
    runs-on: ubuntu-latest
    needs: build
    if: github.ref == 'refs/heads/main'
    environment: production
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v2
        with:
          aws-access-key-id: ${{ secrets.PROD_AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.PROD_AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ env.AWS_REGION }}
      
      - name: Setup deployment environment
        run: |
          chmod +x deploy.sh validate.sh
          # Create config from secrets
          cat > deployment.config << EOF
          AWS_REGION=${{ env.AWS_REGION }}
          TF_VAR_key_name=${{ secrets.PROD_TF_KEY_NAME }}
          TF_VAR_ami_id=${{ secrets.PROD_TF_AMI_ID }}
          DOCKER_REGISTRY=${{ env.REGISTRY }}
          DOCKER_REGISTRY_USERNAME=${{ secrets.DOCKER_USERNAME }}
          POSTGRES_PASSWORD=${{ secrets.PROD_POSTGRES_PASSWORD }}
          DEPLOY_METHOD=kubernetes
          SKIP_BUILD=true
          EOF
      
      - name: Deploy to EKS Production
        run: ./deploy.sh kubernetes

  notification:
    name: Notify Deployment Status
    runs-on: ubuntu-latest
    needs: [validate, build, deploy-dev, deploy-prod]
    if: always()
    
    steps:
      - name: Send Slack notification
        uses: slackapi/slack-github-action@v1
        with:
          payload: |
            {
              "text": "Voting App Deployment: ${{ job.status }}",
              "blocks": [
                {
                  "type": "section",
                  "text": {
                    "type": "mrkdwn",
                    "text": "*Voting App Deployment* - ${{ job.status }}\n*Commit:* ${{ github.sha }}\n*Branch:* ${{ github.ref }}"
                  }
                }
              ]
            }
        env:
          SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
```

---

## GitLab CI/CD Pipeline

Create `.gitlab-ci.yml`:

```yaml
variables:
  AWS_REGION: "us-east-1"
  DOCKER_REGISTRY: "docker.io"
  DOCKER_IMAGE_TAG: "$CI_COMMIT_SHA"

stages:
  - validate
  - build
  - deploy

# Validate configuration and prerequisites
validate:
  stage: validate
  image: ubuntu:22.04
  before_script:
    - apt-get update && apt-get install -y curl git
  script:
    - chmod +x validate.sh
    - ./validate.sh
  only:
    - main
    - develop

# Build Docker images
build:vote:
  stage: build
  image: docker:latest
  services:
    - docker:dind
  before_script:
    - docker login -u $DOCKER_USERNAME -p $DOCKER_PASSWORD
  script:
    - docker build -t $DOCKER_REGISTRY/$DOCKER_USERNAME/voting-app-vote:$DOCKER_IMAGE_TAG 1-application-source/vote
    - docker push $DOCKER_REGISTRY/$DOCKER_USERNAME/voting-app-vote:$DOCKER_IMAGE_TAG
  only:
    - main
    - develop

build:result:
  stage: build
  image: docker:latest
  services:
    - docker:dind
  before_script:
    - docker login -u $DOCKER_USERNAME -p $DOCKER_PASSWORD
  script:
    - docker build -t $DOCKER_REGISTRY/$DOCKER_USERNAME/voting-app-result:$DOCKER_IMAGE_TAG 1-application-source/result
    - docker push $DOCKER_REGISTRY/$DOCKER_USERNAME/voting-app-result:$DOCKER_IMAGE_TAG
  only:
    - main
    - develop

build:worker:
  stage: build
  image: docker:latest
  services:
    - docker:dind
  before_script:
    - docker login -u $DOCKER_USERNAME -p $DOCKER_PASSWORD
  script:
    - docker build -t $DOCKER_REGISTRY/$DOCKER_USERNAME/voting-app-worker:$DOCKER_IMAGE_TAG 1-application-source/worker
    - docker push $DOCKER_REGISTRY/$DOCKER_USERNAME/voting-app-worker:$DOCKER_IMAGE_TAG
  only:
    - main
    - develop

# Deploy to development
deploy:dev:
  stage: deploy
  image: ubuntu:22.04
  before_script:
    - apt-get update && apt-get install -y curl awscli kubectl git
    - curl -fsSL https://apt.releases.hashicorp.com/gpg | apt-key add -
    - apt-get install -y terraform
  script:
    - chmod +x deploy.sh
    - echo "AWS_REGION=$AWS_REGION" > deployment.config
    - echo "TF_VAR_key_name=$TF_KEY_NAME" >> deployment.config
    - echo "TF_VAR_ami_id=$TF_AMI_ID" >> deployment.config
    - echo "DOCKER_REGISTRY=$DOCKER_REGISTRY" >> deployment.config
    - echo "DOCKER_REGISTRY_USERNAME=$DOCKER_USERNAME" >> deployment.config
    - echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" >> deployment.config
    - echo "DEPLOY_METHOD=kubernetes" >> deployment.config
    - echo "SKIP_BUILD=true" >> deployment.config
    - ./deploy.sh kubernetes --dry-run
  only:
    - develop

# Deploy to production
deploy:prod:
  stage: deploy
  image: ubuntu:22.04
  before_script:
    - apt-get update && apt-get install -y curl awscli kubectl git
    - curl -fsSL https://apt.releases.hashicorp.com/gpg | apt-key add -
    - apt-get install -y terraform
  script:
    - chmod +x deploy.sh
    - echo "AWS_REGION=$AWS_REGION" > deployment.config
    - echo "TF_VAR_key_name=$PROD_TF_KEY_NAME" >> deployment.config
    - echo "TF_VAR_ami_id=$PROD_TF_AMI_ID" >> deployment.config
    - echo "DOCKER_REGISTRY=$DOCKER_REGISTRY" >> deployment.config
    - echo "DOCKER_REGISTRY_USERNAME=$DOCKER_USERNAME" >> deployment.config
    - echo "POSTGRES_PASSWORD=$PROD_POSTGRES_PASSWORD" >> deployment.config
    - echo "DEPLOY_METHOD=kubernetes" >> deployment.config
    - echo "SKIP_BUILD=true" >> deployment.config
    - ./deploy.sh kubernetes
  only:
    - main
  when: manual
```

---

## Jenkins Pipeline

Create `Jenkinsfile.deployment`:

```groovy
pipeline {
    agent any
    
    parameters {
        choice(
            name: 'ENVIRONMENT',
            choices: ['dev', 'staging', 'prod'],
            description: 'Target environment for deployment'
        )
        choice(
            name: 'ACTION',
            choices: ['deploy', 'cleanup'],
            description: 'Deployment action'
        )
        booleanParam(
            name: 'DRY_RUN',
            defaultValue: false,
            description: 'Execute in dry-run mode'
        )
    }
    
    environment {
        AWS_REGION = 'us-east-1'
        DOCKER_REGISTRY = 'docker.io'
        CREDENTIALS_ID = credentials("voting-app-${params.ENVIRONMENT}-creds")
    }
    
    stages {
        stage('Validate') {
            steps {
                sh '''
                    chmod +x validate.sh
                    ./validate.sh
                '''
            }
        }
        
        stage('Load Configuration') {
            steps {
                sh '''
                    cp deployment-${ENVIRONMENT}.config deployment.config
                    source deployment.config
                    echo "Configuration loaded for: ${ENVIRONMENT}"
                '''
            }
        }
        
        stage('Build Images') {
            when {
                expression { params.ACTION == 'deploy' }
            }
            steps {
                sh '''
                    chmod +x deploy.sh
                    ./deploy.sh build
                '''
            }
        }
        
        stage('Deploy') {
            when {
                expression { params.ACTION == 'deploy' }
            }
            steps {
                script {
                    def dryRunFlag = params.DRY_RUN ? '--dry-run' : ''
                    sh '''
                        chmod +x deploy.sh
                        ./deploy.sh deploy ${dryRunFlag}
                    '''
                }
            }
        }
        
        stage('Cleanup') {
            when {
                expression { params.ACTION == 'cleanup' }
            }
            steps {
                sh '''
                    chmod +x deploy.sh
                    ./deploy.sh cleanup
                '''
            }
        }
        
        stage('Verify Deployment') {
            when {
                expression { params.ACTION == 'deploy' }
            }
            steps {
                sh '''
                    echo "Verifying deployment in ${ENVIRONMENT}..."
                    kubectl get deployments -n voting-app
                    kubectl get pods -n voting-app
                '''
            }
        }
    }
    
    post {
        always {
            cleanWs()
        }
        success {
            echo "Deployment completed successfully!"
        }
        failure {
            echo "Deployment failed - check logs above"
        }
    }
}
```

---

## Required Environment Variables / Secrets

### GitHub Actions Secrets

Set these in Settings → Secrets and variables → Actions:

```
DOCKER_USERNAME        - Docker Hub username
DOCKER_PASSWORD        - Docker Hub access token
AWS_ACCESS_KEY_ID      - AWS access key for dev environment
AWS_SECRET_ACCESS_KEY  - AWS secret key for dev environment
PROD_AWS_ACCESS_KEY_ID - AWS access key for prod environment
PROD_AWS_SECRET_ACCESS_KEY - AWS secret key for prod environment
TF_KEY_NAME           - EC2 key pair name for dev
TF_AMI_ID             - Ubuntu AMI ID for dev
PROD_TF_KEY_NAME      - EC2 key pair name for prod
PROD_TF_AMI_ID        - Ubuntu AMI ID for prod
POSTGRES_PASSWORD     - Database password for dev
PROD_POSTGRES_PASSWORD - Database password for prod
SLACK_WEBHOOK_URL     - Optional: Slack notification webhook
```

### GitLab CI/CD Variables

Set in Settings → CI/CD → Variables:

```
DOCKER_USERNAME       - Docker Hub username
DOCKER_PASSWORD       - Docker Hub access token
AWS_ACCESS_KEY_ID     - AWS access key
AWS_SECRET_ACCESS_KEY - AWS secret key
TF_KEY_NAME          - EC2 key pair name
TF_AMI_ID            - Ubuntu AMI ID
POSTGRES_PASSWORD    - Database password
PROD_POSTGRES_PASSWORD - Production database password
```

### Jenkins Credentials

Create credentials with ID format: `voting-app-{environment}-creds`

```
voting-app-dev-creds    → Contains dev AWS/Docker credentials
voting-app-staging-creds → Contains staging credentials
voting-app-prod-creds    → Contains production credentials
```

---

## Local Deployment via CI/CD Simulation

Test CI/CD pipeline locally before pushing:

```bash
# Use act for GitHub Actions
brew install act
act push --secret-file .secrets

# Use gitlab-runner for GitLab CI
brew install gitlab-runner
gitlab-runner exec docker deploy:dev

# Use Jenkins Docker
docker run -d -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  jenkins/jenkins:latest
```

---

## Best Practices

1. **Use environment-specific configs**: Keep `deployment-dev.config`, `deployment-staging.config`, `deployment-prod.config`
2. **Secrets management**: Never commit sensitive values - use CI/CD secrets
3. **Approval gates**: Add manual approval for production deployments
4. **Run validation first**: Always validate before deploying
5. **Dry-run tests**: Use `--dry-run` flag to preview changes
6. **Notifications**: Alert team on deployment status
7. **Rollback strategy**: Keep previous versions for quick rollback
8. **Terraform state**: Secure remote state storage (S3 backend)

---

For more information, see `README_DEPLOYMENT.md`
