#!/bin/bash

set -e

# Configuration
AWS_REGION=
AWS_ACCOUNT_ID=
IMAGE_NAME="metrics-scraper"
IMAGE_TAG="latest"
NAMESPACE="metrics-scraper"
REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"  # ECRcontainer registry

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if required tools are installed
check_prerequisites() {
    echo_info "Checking prerequisites..."
    
    if ! command -v docker &> /dev/null; then
        echo_error "Docker is not installed or not in PATH"
        exit 1
    fi
    
    if ! command -v kubectl &> /dev/null; then
        echo_error "kubectl is not installed or not in PATH"
        exit 1
    fi
    
    # Check kubectl connectivity
    if ! kubectl cluster-info &> /dev/null; then
        echo_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    echo_info "Prerequisites check passed"
}

# Function to build Docker image
build_image() {
    echo_info "Building Docker image..."
    
    docker build -t ${IMAGE_NAME}:${IMAGE_TAG} .
    
    if [ $? -eq 0 ]; then
        echo_info "Docker image built successfully"
    else
        echo_error "Failed to build Docker image"
        exit 1
    fi
}

# Function to push image to registry (optional)
push_image() {
    if [ "$1" == "--push" ]; then
        echo_info "Pushing image to registry..."

        # Login to AWS
        aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
        
        # Tag for registry
        docker tag ${IMAGE_NAME}:${IMAGE_TAG} ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
        
        # Push to registry
        docker push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
        
        if [ $? -eq 0 ]; then
            echo_info "Image pushed successfully"
        else
            echo_error "Failed to push image"
            exit 1
        fi
    fi
}

# Function to update PagerDuty credentials
update_credentials() {
    echo_info "Updating PagerDuty credentials..."
    
    read -p "Enter your PagerDuty Integration Token: " -s PAGERDUTY_TOKEN
    echo
    read -p "Enter your PagerDuty Routing Key: " -s PAGERDUTY_ROUTING_KEY
    echo
    
    if [ -z "$PAGERDUTY_TOKEN" ] || [ -z "$PAGERDUTY_ROUTING_KEY" ]; then
        echo_error "PagerDuty credentials cannot be empty"
        exit 1
    fi
    
    # Base64 encode the credentials
    PAGERDUTY_TOKEN_B64=$(echo -n "$PAGERDUTY_TOKEN" | base64 -w 0)
    PAGERDUTY_ROUTING_KEY_B64=$(echo -n "$PAGERDUTY_ROUTING_KEY" | base64 -w 0)
    
    # Update the secret in the manifest
    sed -i "s/pagerduty-token: .*/pagerduty-token: $PAGERDUTY_TOKEN_B64/" k8s-manifests.yaml
    sed -i "s/pagerduty-routing-key: .*/pagerduty-routing-key: $PAGERDUTY_ROUTING_KEY_B64/" k8s-manifests.yaml
    
    echo_info "Credentials updated in manifest"
}

# Function to deploy to Kubernetes
deploy_to_kubernetes() {
    echo_info "Deploying to Kubernetes..."
    
    # Update image reference in manifest if using registry
    if [ "$1" == "--push" ]; then
        sed -i "s|image: metrics-scraper:latest|image: ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}|" k8s-manifests.yaml
    fi
    
    # Apply the manifests
    kubectl apply -f k8s-manifests.yaml
    
    if [ $? -eq 0 ]; then
        echo_info "Deployment successful"
    else
        echo_error "Deployment failed"
        exit 1
    fi
    
    # Wait for CronJob to be created
    echo_info "Waiting for CronJob to be ready..."
    kubectl wait --for=condition=Ready cronjob/metrics-scraper-cronjob -n ${NAMESPACE} --timeout=60s || true
    
    echo_info "Deployment completed"
}

# Function to show status
show_status() {
    echo_info "Checking deployment status..."
    
    echo_info "CronJob status:"
    kubectl get cronjob -n ${NAMESPACE}
    
    echo_info "Recent jobs:"
    kubectl get jobs -n ${NAMESPACE} --sort-by=.metadata.creationTimestamp
    
    echo_info "Recent pods:"
    kubectl get pods -n ${NAMESPACE} --sort-by=.metadata.creationTimestamp
    
    echo_info "PVC status:"
    kubectl get pvc -n ${NAMESPACE}
}

# Function to show logs
show_logs() {
    echo_info "Fetching recent logs..."
    
    # Get the most recent job
    LATEST_JOB=$(kubectl get jobs -n ${NAMESPACE} --sort-by=.metadata.creationTimestamp -o name | tail -1)
    
    if [ -n "$LATEST_JOB" ]; then
        echo_info "Logs from $LATEST_JOB:"
        kubectl logs $LATEST_JOB -n ${NAMESPACE}
    else
        echo_warn "No jobs found"
    fi
}

# Function to trigger manual run
trigger_manual_run() {
    echo_info "Triggering manual run..."
    
    kubectl create job --from=cronjob/metrics-scraper-cronjob manual-run-$(date +%s) -n ${NAMESPACE}
    
    echo_info "Manual job created. Use './deploy.sh logs' to check the output"
}

# Function to cleanup
cleanup() {
    echo_info "Cleaning up deployment..."
    
    read -p "Are you sure you want to delete the metrics-scraper deployment? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kubectl delete -f k8s-manifests.yaml
        echo_info "Cleanup completed"
    else
        echo_info "Cleanup cancelled"
    fi
}

# Main script logic
case "$1" in
    "build")
        check_prerequisites
        build_image
        ;;
    "deploy")
        check_prerequisites
        build_image
        push_image $2
        update_credentials
        deploy_to_kubernetes $2
        show_status
        ;;
    "status")
        show_status
        ;;
    "logs")
        show_logs
        ;;
    "run")
        trigger_manual_run
        ;;
    "cleanup")
        cleanup
        ;;
    *)
        echo "Usage: $0 {build|deploy [--push]|status|logs|run|cleanup}"
        echo ""
        echo "Commands:"
        echo "  build                 Build the Docker image"
        echo "  deploy [--push]       Deploy to Kubernetes (--push to push to registry)"
        echo "  status                Show deployment status"
        echo "  logs                  Show logs from the latest job"
        echo "  run                   Trigger a manual run"
        echo "  cleanup               Remove the deployment"
        exit 1
        ;;
esac
