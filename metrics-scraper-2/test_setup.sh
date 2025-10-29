#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

echo_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# Function to create a test deployment with zero replicas
create_test_deployment() {
    echo_info "Creating test deployment with zero replicas..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-zero-replicas
  namespace: default
  labels:
    app: test-zero-replicas
spec:
  replicas: 0
  selector:
    matchLabels:
      app: test-zero-replicas
  template:
    metadata:
      labels:
        app: test-zero-replicas
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
EOF
    
    echo_info "Test deployment created"
}

# Function to create a normal deployment for comparison
create_normal_deployment() {
    echo_info "Creating normal deployment with replicas..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-normal-replicas
  namespace: default
  labels:
    app: test-normal-replicas
spec:
  replicas: 2
  selector:
    matchLabels:
      app: test-normal-replicas
  template:
    metadata:
      labels:
        app: test-normal-replicas
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
EOF
    
    echo_info "Normal deployment created"
}

# Function to test PagerDuty connectivity
test_pagerduty_connection() {
    echo_info "Testing PagerDuty connection..."
    
    # Get credentials from the secret
    PAGERDUTY_TOKEN=$(kubectl get secret pagerduty-credentials -n metrics-scraper -o jsonpath='{.data.pagerduty-token}' | base64 -d)
    PAGERDUTY_ROUTING_KEY=$(kubectl get secret pagerduty-credentials -n metrics-scraper -o jsonpath='{.data.pagerduty-routing-key}' | base64 -d)
    
    if [ -z "$PAGERDUTY_TOKEN" ] || [ -z "$PAGERDUTY_ROUTING_KEY" ]; then
        echo_error "Could not retrieve PagerDuty credentials from secret"
        return 1
    fi
    
    # Send test alert
    RESPONSE=$(curl -s -w "%{http_code}" -X POST https://events.pagerduty.com/v2/enqueue \
        -H "Content-Type: application/json" \
        -H "Authorization: Token token=$PAGERDUTY_TOKEN" \
        -d "{
            \"routing_key\": \"$PAGERDUTY_ROUTING_KEY\",
            \"event_action\": \"trigger\",
            \"payload\": {
                \"summary\": \"Test alert from k8s-metrics-scraper\",
                \"severity\": \"info\",
                \"source\": \"test-setup\",
                \"component\": \"connectivity-test\",
                \"custom_details\": {
                    \"test\": true,
                    \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
                }
            }
        }")
    
    HTTP_CODE=${RESPONSE: -3}
    RESPONSE_BODY=${RESPONSE%???}
    
    if [ "$HTTP_CODE" = "202" ]; then
        echo_info "PagerDuty connectivity test successful"
        echo_debug "Response: $RESPONSE_BODY"
    else
        echo_error "PagerDuty connectivity test failed (HTTP $HTTP_CODE)"
        echo_error "Response: $RESPONSE_BODY"
        return 1
    fi
}

# Function to validate Kubernetes permissions
test_k8s_permissions() {
    echo_info "Testing Kubernetes permissions..."
    
    # Test if service account can list deployments
    kubectl auth can-i list deployments --as=system:serviceaccount:metrics-scraper:metrics-scraper
    if [ $? -eq 0 ]; then
        echo_info "✓ Can list deployments"
    else
        echo_error "✗ Cannot list deployments"
        return 1
    fi
    
    # Test if service account can list replicasets
    kubectl auth can-i list replicasets --as=system:serviceaccount:metrics-scraper:metrics-scraper
    if [ $? -eq 0 ]; then
        echo_info "✓ Can list replicasets"
    else
        echo_error "✗ Cannot list replicasets"
        return 1
    fi
    
    # Test if service account can list pods
    kubectl auth can-i list pods --as=system:serviceaccount:metrics-scraper:metrics-scraper
    if [ $? -eq 0 ]; then
        echo_info "✓ Can list pods"
    else
        echo_warn "✗ Cannot list pods (optional)"
    fi
}

# Function to test PVC access
test_pvc_access() {
    echo_info "Testing PVC access..."
    
    # Check PVC status
    PVC_STATUS=$(kubectl get pvc metrics-scraper-storage -n metrics-scraper -o jsonpath='{.status.phase}')
    
    if [ "$PVC_STATUS" = "Bound" ]; then
        echo_info "✓ PVC is bound"
    else
        echo_error "✗ PVC is not bound (status: $PVC_STATUS)"
        return 1
    fi
    
    # Create a test pod to verify PVC can be mounted
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pvc-test
  namespace: metrics-scraper
spec:
  serviceAccountName: metrics-scraper
  containers:
  - name: test
    image: busybox
    command: ['sh', '-c', 'echo "test" > /data/test.txt && cat /data/test.txt && sleep 10']
    volumeMounts:
    - name: storage
      mountPath: /data
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: metrics-scraper-storage
  restartPolicy: Never
EOF
    
    # Wait for pod to complete
    kubectl wait --for=condition=Ready pod/pvc-test -n metrics-scraper --timeout=60s
    
    # Check logs
    PVC_TEST_OUTPUT=$(kubectl logs pvc-test -n metrics-scraper)
    
    if [[ "$PVC_TEST_OUTPUT" == *"test"* ]]; then
        echo_info "✓ PVC read/write test successful"
    else
        echo_error "✗ PVC read/write test failed"
        echo_debug "Output: $PVC_TEST_OUTPUT"
        return 1
    fi
    
    # Cleanup test pod
    kubectl delete pod pvc-test -n metrics-scraper --ignore-not-found=true
}

# Function to run end-to-end test
run_e2e_test() {
    echo_info "Running end-to-end test..."
    
    # Create test deployments
    create_test_deployment
    create_normal_deployment
    
    # Wait a moment for deployments to be created
    sleep 5
    
    # Trigger manual run of metrics scraper
    echo_info "Triggering metrics scraper run..."
    kubectl create job --from=cronjob/metrics-scraper-cronjob e2e-test-$(date +%s) -n metrics-scraper
    
    # Wait for job to complete
    echo_info "Waiting for job to complete..."
    sleep 30
    
    # Get the latest job
    LATEST_JOB=$(kubectl get jobs -n metrics-scraper --sort-by=.metadata.creationTimestamp -o name | tail -1)
    
    if [ -n "$LATEST_JOB" ]; then
        echo_info "Job logs:"
        kubectl logs $LATEST_JOB -n metrics-scraper
        
        # Check if job completed successfully
        JOB_STATUS=$(kubectl get $LATEST_JOB -n metrics-scraper -o jsonpath='{.status.conditions[0].type}')
        if [ "$JOB_STATUS" = "Complete" ]; then
            echo_info "✓ Job completed successfully"
        else
            echo_error "✗ Job did not complete successfully"
            return 1
        fi
    else
        echo_error "No jobs found"
        return 1
    fi
    
    echo_info "E2E test completed"
}

# Function to cleanup test resources
cleanup_test_resources() {
    echo_info "Cleaning up test resources..."
    
    kubectl delete deployment test-zero-replicas -n default --ignore-not-found=true
    kubectl delete deployment test-normal-replicas -n default --ignore-not-found=true
    kubectl delete pod pvc-test -n metrics-scraper --ignore-not-found=true
    
    # Delete test jobs (keep only last 3)
    kubectl get jobs -n metrics-scraper --sort-by=.metadata.creationTimestamp -o name | head -n -3 | xargs --no-run-if-empty kubectl delete -n metrics-scraper
    
    echo_info "Test cleanup completed"
}

# Function to show comprehensive status
show_comprehensive_status() {
    echo_info "=== Comprehensive Status Report ==="
    
    echo_info "Namespace status:"
    kubectl get ns metrics-scraper
    
    echo_info "All resources in metrics-scraper namespace:"
    kubectl get all -n metrics-scraper
    
    echo_info "PVC status:"
    kubectl get pvc -n metrics-scraper
    
    echo_info "Secrets:"
    kubectl get secrets -n metrics-scraper
    
    echo_info "ConfigMaps:"
    kubectl get configmaps -n metrics-scraper
    
    echo_info "RBAC resources:"
    kubectl get serviceaccounts -n metrics-scraper
    kubectl get clusterroles | grep metrics-scraper
    kubectl get clusterrolebindings | grep metrics-scraper
    
    echo_info "Recent events:"
    kubectl get events -n metrics-scraper --sort-by=.metadata.creationTimestamp | tail -10
}

# Function to validate configuration
validate_config() {
    echo_info "Validating configuration..."
    
    # Check if namespace exists
    if kubectl get ns metrics-scraper &>/dev/null; then
        echo_info "✓ Namespace exists"
    else
        echo_error "✗ Namespace does not exist"
        return 1
    fi
    
    # Check if CronJob exists
    if kubectl get cronjob metrics-scraper-cronjob -n metrics-scraper &>/dev/null; then
        echo_info "✓ CronJob exists"
    else
        echo_error "✗ CronJob does not exist"
        return 1
    fi
    
    # Check if secret exists and has required keys
    if kubectl get secret pagerduty-credentials -n metrics-scraper &>/dev/null; then
        echo_info "✓ PagerDuty secret exists"
        
        # Check if keys exist
        if kubectl get secret pagerduty-credentials -n metrics-scraper -o jsonpath='{.data.pagerduty-token}' &>/dev/null; then
            echo_info "✓ PagerDuty token key exists"
        else
            echo_error "✗ PagerDuty token key missing"
            return 1
        fi
        
        if kubectl get secret pagerduty-credentials -n metrics-scraper -o jsonpath='{.data.pagerduty-routing-key}' &>/dev/null; then
            echo_info "✓ PagerDuty routing key exists"
        else
            echo_error "✗ PagerDuty routing key missing"
            return 1
        fi
    else
        echo_error "✗ PagerDuty secret does not exist"
        return 1
    fi
    
    # Check ConfigMap
    if kubectl get configmap metrics-scraper-config -n metrics-scraper &>/dev/null; then
        echo_info "✓ ConfigMap exists"
    else
        echo_error "✗ ConfigMap does not exist"
        return 1
    fi
    
    echo_info "Configuration validation completed"
}

# Main script logic
case "$1" in
    "validate")
        validate_config
        ;;
    "permissions")
        test_k8s_permissions
        ;;
    "pagerduty")
        test_pagerduty_connection
        ;;
    "pvc")
        test_pvc_access
        ;;
    "e2e")
        run_e2e_test
        ;;
    "cleanup")
        cleanup_test_resources
        ;;
    "status")
        show_comprehensive_status
        ;;
    "all")
        echo_info "Running comprehensive test suite..."
        validate_config && \
        test_k8s_permissions && \
        test_pvc_access && \
        test_pagerduty_connection && \
        run_e2e_test
        echo_info "All tests completed"
        ;;
    *)
        echo "Usage: $0 {validate|permissions|pagerduty|pvc|e2e|cleanup|status|all}"
        echo ""
        echo "Commands:"
        echo "  validate      Validate basic configuration"
        echo "  permissions   Test Kubernetes RBAC permissions"
        echo "  pagerduty     Test PagerDuty connectivity"
        echo "  pvc           Test persistent volume access"
        echo "  e2e           Run end-to-end test with sample deployments"
        echo "  cleanup       Remove test resources"
        echo "  status        Show comprehensive status"
        echo "  all           Run all tests"
        exit 1
        ;;
esac
