#!/bin/bash

# Istio Fundamentals Course - Production-grade Service Mesh Setup
# Tetrate Academy 80%+ completion - Local Kubernetes with Minikube
# Simulates production microservices networking

set -euo pipefail

# Configuration
ISTIO_VERSION="1.19.3"
MINIKUBE_MEMORY="8192"
MINIKUBE_CPUS="4"
LOG_FILE="/var/log/istio_setup.log"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check prerequisites
check_prerequisites() {
    log_message "Checking prerequisites..."
    
    local missing_tools=()
    
    # Check required tools
    command -v minikube >/dev/null 2>&1 || missing_tools+=("minikube")
    command -v kubectl >/dev/null 2>&1 || missing_tools+=("kubectl")
    command -v curl >/dev/null 2>&1 || missing_tools+=("curl")
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_message "Missing required tools: ${missing_tools[*]}"
        log_message "Please install missing tools and retry"
        exit 1
    fi
    
    log_message "✓ All prerequisites satisfied"
}

# Setup Minikube cluster
setup_minikube() {
    log_message "Setting up Minikube cluster for Istio..."
    
    # Stop existing cluster if running
    minikube stop 2>/dev/null || true
    
    # Start Minikube with adequate resources for Istio
    minikube start \
        --memory="$MINIKUBE_MEMORY" \
        --cpus="$MINIKUBE_CPUS" \
        --kubernetes-version=v1.28.0 \
        --driver=docker
    
    # Enable required addons
    minikube addons enable ingress
    minikube addons enable metrics-server
    
    # Verify cluster is ready
    kubectl cluster-info
    kubectl get nodes
    
    log_message "✓ Minikube cluster ready for Istio deployment"
}

# Download and install Istio
install_istio() {
    log_message "Downloading and installing Istio $ISTIO_VERSION..."
    
    # Download Istio
    curl -L https://istio.io/downloadIstio | ISTIO_VERSION="$ISTIO_VERSION" sh -
    
    # Add istioctl to PATH
    export PATH="$PWD/istio-$ISTIO_VERSION/bin:$PATH"
    
    # Verify installation
    istioctl version --remote=false
    
    log_message "✓ Istio $ISTIO_VERSION downloaded and configured"
}

# Install Istio control plane
install_control_plane() {
    log_message "Installing Istio control plane..."
    
    # Pre-check cluster compatibility
    istioctl x precheck
    
    # Install Istio with demo profile (suitable for learning)
    istioctl install --set values.defaultRevision=default -y
    
    # Verify installation
    kubectl get pods -n istio-system
    
    # Label default namespace for sidecar injection
    kubectl label namespace default istio-injection=enabled --overwrite
    
    log_message "✓ Istio control plane installed successfully"
}

# Install Istio addons for observability
install_addons() {
    log_message "Installing Istio observability addons..."
    
    # Install addons
    kubectl apply -f "istio-$ISTIO_VERSION/samples/addons/"
    
    # Wait for deployments to be ready
    log_message "Waiting for addon deployments..."
    
    # Wait for Kiali
    kubectl wait --for=condition=available --timeout=600s deployment/kiali -n istio-system
    
    # Wait for Prometheus
    kubectl wait --for=condition=available --timeout=600s deployment/prometheus -n istio-system
    
    # Wait for Grafana
    kubectl wait --for=condition=available --timeout=600s deployment/grafana -n istio-system
    
    # Wait for Jaeger
    kubectl wait --for=condition=available --timeout=600s deployment/jaeger -n istio-system
    
    log_message "✓ All Istio addons installed and ready"
}

# Deploy sample microservices application
deploy_sample_app() {
    log_message "Deploying sample microservices application..."
    
    # Deploy Bookinfo sample application
    kubectl apply -f "istio-$ISTIO_VERSION/samples/bookinfo/platform/kube/bookinfo.yaml"
    
    # Wait for services to be ready
    kubectl wait --for=condition=available --timeout=300s deployment --all
    
    # Verify application is running
    kubectl get services
    kubectl get pods
    
    # Test application internally
    kubectl exec "$(kubectl get pod -l app=ratings -o jsonpath='{.items[0].metadata.name}')" -c ratings -- curl -sS productpage:9080/productpage | grep -o "<title>.*</title>"
    
    log_message "✓ Sample microservices application deployed"
}

# Configure Istio Gateway and VirtualService
configure_gateway() {
    log_message "Configuring Istio Gateway and VirtualService..."
    
    # Apply gateway configuration
    kubectl apply -f "istio-$ISTIO_VERSION/samples/bookinfo/networking/bookinfo-gateway.yaml"
    
    # Verify gateway configuration
    istioctl analyze
    
    # Get ingress gateway details
    export INGRESS_HOST=$(minikube ip)
    export INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
    export GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT
    
    log_message "Gateway URL: http://$GATEWAY_URL/productpage"
    
    # Test external access
    curl -s "http://$GATEWAY_URL/productpage" | grep -o "<title>.*</title>" || log_message "Gateway configuration in progress..."
    
    log_message "✓ Istio Gateway and VirtualService configured"
}

# Setup traffic management
configure_traffic_management() {
    log_message "Configuring advanced traffic management..."
    
    # Apply destination rules
    kubectl apply -f "istio-$ISTIO_VERSION/samples/bookinfo/networking/destination-rule-all.yaml"
    
    # Configure traffic splitting (90% v1, 10% v3)
    cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: reviews
spec:
  http:
  - match:
    - headers:
        end-user:
          exact: jason
    route:
    - destination:
        host: reviews
        subset: v2
  - route:
    - destination:
        host: reviews
        subset: v1
      weight: 90
    - destination:
        host: reviews
        subset: v3
      weight: 10
EOF
    
    log_message "✓ Traffic management rules configured"
}

# Setup security policies
configure_security() {
    log_message "Configuring Istio security policies..."
    
    # Enable strict mTLS for default namespace
    cat <<EOF | kubectl apply -f -
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: default
spec:
  mtls:
    mode: STRICT
EOF
    
    # Create authorization policy
    cat <<EOF | kubectl apply -f -
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-all
  namespace: default
spec:
  rules:
  - {}
EOF
    
    log_message "✓ Security policies configured (mTLS enabled)"
}

# Generate access URLs for observability tools
generate_access_info() {
    log_message "Generating access information for observability tools..."
    
    local info_file="istio_access_info.txt"
    
    {
        echo "=== Istio Service Mesh Access Information ==="
        echo "Generated: $(date)"
        echo
        
        echo "=== Application Access ==="
        echo "Bookinfo Application: http://$GATEWAY_URL/productpage"
        echo
        
        echo "=== Observability Tools ==="
        echo "Access these tools using kubectl port-forward:"
        echo
        echo "Kiali (Service Mesh UI):"
        echo "  kubectl port-forward svc/kiali 20001:20001 -n istio-system"
        echo "  Access: http://localhost:20001"
        echo
        echo "Grafana (Metrics Dashboard):"
        echo "  kubectl port-forward svc/grafana 3000:3000 -n istio-system"
        echo "  Access: http://localhost:3000"
        echo
        echo "Prometheus (Metrics Collection):"
        echo "  kubectl port-forward svc/prometheus 9090:9090 -n istio-system"
        echo "  Access: http://localhost:9090"
        echo
        echo "Jaeger (Distributed Tracing):"
        echo "  kubectl port-forward svc/jaeger 16686:16686 -n istio-system"
        echo "  Access: http://localhost:16686"
        echo
        
        echo "=== Useful Commands ==="
        echo "Check Istio configuration: istioctl analyze"
        echo "View proxy configuration: istioctl proxy-config cluster <pod-name>"
        echo "Generate traffic: while true; do curl -s http://$GATEWAY_URL/productpage > /dev/null; sleep 1; done"
        
    } > "$info_file"
    
    cat "$info_file"
    log_message "✓ Access information saved to $info_file"
}

# Validate Istio installation
validate_installation() {
    log_message "Validating Istio installation..."
    
    # Check Istio system pods
    local failed_pods
    failed_pods=$(kubectl get pods -n istio-system --field-selector=status.phase!=Running --no-headers | wc -l)
    
    if [ "$failed_pods" -gt 0 ]; then
        log_message "⚠ Warning: $failed_pods pods not running in istio-system"
        kubectl get pods -n istio-system
    fi
    
    # Check sidecar injection
    local injected_pods
    injected_pods=$(kubectl get pods -o jsonpath='{.items[*].spec.containers[*].name}' | grep -o istio-proxy | wc -l)
    
    log_message "Sidecar proxies injected: $injected_pods"
    
    # Verify mTLS is working
    istioctl authn tls-check productpage.default.svc.cluster.local
    
    log_message "✓ Istio installation validation completed"
}

# Main installation function
main() {
    case "${1:-}" in
        --setup-cluster)
            check_prerequisites
            setup_minikube
            ;;
        --install-istio)
            install_istio
            install_control_plane
            install_addons
            ;;
        --deploy-app)
            deploy_sample_app
            configure_gateway
            ;;
        --configure-advanced)
            configure_traffic_management
            configure_security
            ;;
        --validate)
            validate_installation
            ;;
        --info)
            generate_access_info
            ;;
        --help)
            echo "Istio Fundamentals Course - Service Mesh Setup"
            echo "Usage: $0 [option]"
            echo "  --setup-cluster      Setup Minikube cluster"
            echo "  --install-istio      Install Istio control plane and addons"
            echo "  --deploy-app         Deploy sample microservices application"
            echo "  --configure-advanced Configure traffic management and security"
            echo "  --validate           Validate Istio installation"
            echo "  --info               Show access information"
            echo "  --help               Show this help"
            ;;
        *)
            log_message "=== Starting complete Istio setup ==="
            check_prerequisites
            setup_minikube
            install_istio
            install_control_plane
            install_addons
            deploy_sample_app
            configure_gateway
            configure_traffic_management
            configure_security
            validate_installation
            generate_access_info
            log_message "=== Istio service mesh setup completed successfully ==="
            ;;
    esac
}

main "$@"
