#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
STACK_NAME="insurance"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
POSTGRES_PASSWORD_FILE="${POSTGRES_PASSWORD_FILE:-}"
DOCKER_REGISTRY="${DOCKER_REGISTRY:-}"
DOCKER_USERNAME="${DOCKER_USERNAME:-}"
DOCKER_PASSWORD="${DOCKER_PASSWORD:-}"

# Functions
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_swarm() {
    print_info "Checking Docker Swarm status..."
    if ! docker info | grep -q "Swarm: active"; then
        print_warn "Docker Swarm is not initialized. Initializing now..."
        docker swarm init
        print_info "Docker Swarm initialized successfully"
    else
        print_info "Docker Swarm is already initialized"
    fi
}

create_secret() {
    print_info "Creating PostgreSQL password secret..."
    if docker secret ls | grep -q "postgres_password"; then
        print_warn "Secret 'postgres_password' already exists. Removing old one..."
        docker secret rm postgres_password || true
    fi
    
    if [ -n "$POSTGRES_PASSWORD_FILE" ] && [ -f "$POSTGRES_PASSWORD_FILE" ]; then
        docker secret create postgres_password "$POSTGRES_PASSWORD_FILE"
        print_info "Secret created from file: $POSTGRES_PASSWORD_FILE"
    else
        echo -n "$POSTGRES_PASSWORD" | docker secret create postgres_password -
        print_info "Secret created from environment variable"
    fi
}

create_configs() {
    print_info "Creating Docker configs..."
    
    # PostgreSQL init config
    if docker config ls | grep -q "postgres_init"; then
        print_warn "Config 'postgres_init' already exists. Removing old one..."
        docker config rm postgres_init || true
    fi
    
    if [ ! -f "database/init.sql" ]; then
        print_error "File database/init.sql not found!"
        exit 1
    fi
    
    docker config create postgres_init database/init.sql
    print_info "Config 'postgres_init' created"
    
    # Nginx config
    if docker config ls | grep -q "nginx_config"; then
        print_warn "Config 'nginx_config' already exists. Removing old one..."
        docker config rm nginx_config || true
    fi
    
    if [ ! -f "nginx-proxy/nginx.conf" ]; then
        print_error "File nginx-proxy/nginx.conf not found!"
        exit 1
    fi
    
    docker config create nginx_config nginx-proxy/nginx.conf
    print_info "Config 'nginx_config' created"
}

build_images() {
    print_info "Building Docker images..."
    
    docker build -t insurance-backend:latest -f backend-api/Dockerfile backend-api/
    print_info "Backend image built"
    
    docker build -t insurance-frontend:latest -f frontend/Dockerfile frontend/
    print_info "Frontend image built"
    
    docker build -t insurance-nginx:latest -f nginx-proxy/Dockerfile nginx-proxy/
    print_info "Nginx image built"
}

push_images() {
    if [ -z "$DOCKER_REGISTRY" ] || [ -z "$DOCKER_USERNAME" ]; then
        print_warn "Docker registry credentials not provided. Skipping image push."
        print_warn "Images will be used locally only."
        return
    fi
    
    print_info "Pushing images to registry..."
    
    if [ -n "$DOCKER_PASSWORD" ]; then
        echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin "$DOCKER_REGISTRY"
    else
        docker login -u "$DOCKER_USERNAME" "$DOCKER_REGISTRY"
    fi
    
    # Tag and push images
    docker tag insurance-backend:latest "${DOCKER_REGISTRY}/${DOCKER_USERNAME}/insurance-backend:latest"
    docker push "${DOCKER_REGISTRY}/${DOCKER_USERNAME}/insurance-backend:latest"
    print_info "Backend image pushed"
    
    docker tag insurance-frontend:latest "${DOCKER_REGISTRY}/${DOCKER_USERNAME}/insurance-frontend:latest"
    docker push "${DOCKER_REGISTRY}/${DOCKER_USERNAME}/insurance-frontend:latest"
    print_info "Frontend image pushed"
    
    docker tag insurance-nginx:latest "${DOCKER_REGISTRY}/${DOCKER_USERNAME}/insurance-nginx:latest"
    docker push "${DOCKER_REGISTRY}/${DOCKER_USERNAME}/insurance-nginx:latest"
    print_info "Nginx image pushed"
}

deploy_stack() {
    print_info "Deploying stack: $STACK_NAME"
    
    if [ ! -f "docker-stack.yml" ]; then
        print_error "File docker-stack.yml not found!"
        exit 1
    fi
    
    # Create temporary docker-stack.yml with updated image names if using registry
    STACK_FILE="docker-stack.yml"
    if [ -n "$DOCKER_REGISTRY" ] && [ -n "$DOCKER_USERNAME" ]; then
        print_info "Updating image references for registry..."
        STACK_FILE="/tmp/docker-stack-$$.yml"
        cp docker-stack.yml "$STACK_FILE"
        
        # Update image names in the temporary file (compatible with both GNU and BSD sed)
        if [ "$DOCKER_REGISTRY" = "docker.io" ]; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                # macOS (BSD sed)
                sed -i '' "s|insurance-backend:latest|${DOCKER_USERNAME}/insurance-backend:latest|g" "$STACK_FILE"
                sed -i '' "s|insurance-frontend:latest|${DOCKER_USERNAME}/insurance-frontend:latest|g" "$STACK_FILE"
                sed -i '' "s|insurance-nginx:latest|${DOCKER_USERNAME}/insurance-nginx:latest|g" "$STACK_FILE"
            else
                # Linux (GNU sed)
                sed -i "s|insurance-backend:latest|${DOCKER_USERNAME}/insurance-backend:latest|g" "$STACK_FILE"
                sed -i "s|insurance-frontend:latest|${DOCKER_USERNAME}/insurance-frontend:latest|g" "$STACK_FILE"
                sed -i "s|insurance-nginx:latest|${DOCKER_USERNAME}/insurance-nginx:latest|g" "$STACK_FILE"
            fi
        else
            if [[ "$OSTYPE" == "darwin"* ]]; then
                # macOS (BSD sed)
                sed -i '' "s|insurance-backend:latest|${DOCKER_REGISTRY}/${DOCKER_USERNAME}/insurance-backend:latest|g" "$STACK_FILE"
                sed -i '' "s|insurance-frontend:latest|${DOCKER_REGISTRY}/${DOCKER_USERNAME}/insurance-frontend:latest|g" "$STACK_FILE"
                sed -i '' "s|insurance-nginx:latest|${DOCKER_REGISTRY}/${DOCKER_USERNAME}/insurance-nginx:latest|g" "$STACK_FILE"
            else
                # Linux (GNU sed)
                sed -i "s|insurance-backend:latest|${DOCKER_REGISTRY}/${DOCKER_USERNAME}/insurance-backend:latest|g" "$STACK_FILE"
                sed -i "s|insurance-frontend:latest|${DOCKER_REGISTRY}/${DOCKER_USERNAME}/insurance-frontend:latest|g" "$STACK_FILE"
                sed -i "s|insurance-nginx:latest|${DOCKER_REGISTRY}/${DOCKER_USERNAME}/insurance-nginx:latest|g" "$STACK_FILE"
            fi
        fi
    fi
    
    docker stack deploy -c "$STACK_FILE" "$STACK_NAME" --with-registry-auth
    print_info "Stack deployment initiated"
    
    # Clean up temporary file
    if [ "$STACK_FILE" != "docker-stack.yml" ]; then
        rm -f "$STACK_FILE"
    fi
    
    print_info "Waiting for services to start..."
    sleep 10
    
    print_info "Stack services status:"
    docker stack services "$STACK_NAME"
    
    print_info "Service details:"
    docker service ls | grep "$STACK_NAME" || true
}

show_status() {
    print_info "Stack status:"
    docker stack services "$STACK_NAME"
    
    echo ""
    print_info "Service replicas:"
    docker service ls | grep "$STACK_NAME" || true
    
    echo ""
    print_info "Service tasks:"
    for service in $(docker stack services -q "$STACK_NAME"); do
        echo "Service: $service"
        docker service ps "$service" --no-trunc || true
        echo ""
    done
}

down_stack() {
    print_info "Removing stack: $STACK_NAME"
    docker stack rm "$STACK_NAME"
    print_info "Stack removal initiated. Waiting for services to stop..."
    sleep 10
    print_info "Stack removed"
}

clean_stack() {
    print_info "Cleaning up stack resources..."
    
    # Remove stack
    if docker stack ls | grep -q "$STACK_NAME"; then
        down_stack
    fi
    
    # Remove secrets
    if docker secret ls | grep -q "postgres_password"; then
        print_info "Removing secret: postgres_password"
        docker secret rm postgres_password || true
    fi
    
    # Remove configs
    if docker config ls | grep -q "postgres_init"; then
        print_info "Removing config: postgres_init"
        docker config rm postgres_init || true
    fi
    
    if docker config ls | grep -q "nginx_config"; then
        print_info "Removing config: nginx_config"
        docker config rm nginx_config || true
    fi
    
    # Remove volumes (optional, be careful!)
    read -p "Do you want to remove volumes? This will delete all data! (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_warn "Removing volumes..."
        docker volume rm "${STACK_NAME}_postgres_data" "${STACK_NAME}_rabbitmq_data" 2>/dev/null || true
        print_info "Volumes removed"
    fi
    
    print_info "Cleanup complete"
}

# Main script logic
case "${1:-deploy}" in
    deploy)
        print_info "Starting deployment process..."
        check_swarm
        create_secret
        create_configs
        build_images
        push_images
        deploy_stack
        sleep 5
        show_status
        print_info "Deployment complete!"
        ;;
    down)
        down_stack
        ;;
    clean)
        clean_stack
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 {deploy|down|clean|status}"
        echo ""
        echo "Commands:"
        echo "  deploy  - Deploy the stack (default)"
        echo "  down    - Remove the stack"
        echo "  clean   - Remove stack, secrets, configs, and optionally volumes"
        echo "  status  - Show stack status"
        echo ""
        echo "Environment variables:"
        echo "  POSTGRES_PASSWORD      - PostgreSQL password (default: postgres)"
        echo "  POSTGRES_PASSWORD_FILE - File containing PostgreSQL password"
        echo "  DOCKER_REGISTRY        - Docker registry URL"
        echo "  DOCKER_USERNAME        - Docker registry username"
        echo "  DOCKER_PASSWORD        - Docker registry password"
        exit 1
        ;;
esac

