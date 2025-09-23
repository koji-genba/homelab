#!/bin/bash
set -e

echo "🚀 Starting k8s cluster deployment with Terraform"

# Check prerequisites
echo "📋 Checking prerequisites..."
if ! command -v terraform &> /dev/null; then
    echo "❌ Terraform not found. Please install terraform first."
    exit 1
fi

if [ ! -f ~/.ssh/k8s_ed25519 ]; then
    echo "❌ SSH key not found at ~/.ssh/k8s_ed25519"
    echo "Generate with: ssh-keygen -t ed25519 -f ~/.ssh/k8s_ed25519 -C 'k8s-cluster'"
    exit 1
fi

# Check terraform.tfvars
if [ ! -f terraform.tfvars ]; then
    echo "❌ terraform.tfvars not found"
    echo "Copy from example: cp terraform.tfvars.example terraform.tfvars"
    echo "Then edit with your values"
    exit 1
fi

# Clean previous state if exists
if [ -d .terraform ] || [ -f terraform.tfstate ]; then
    echo "⚠️  Found existing Terraform state"
    read -p "Do you want to clean it? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf .terraform terraform.tfstate* .terraform.lock.hcl
        echo "✅ Cleaned existing state"
    fi
fi

# Initialize Terraform
echo "📦 Initializing Terraform..."
terraform init

# Validate configuration
echo "✔️  Validating configuration..."
terraform validate

# Show plan
echo "📝 Creating execution plan..."
terraform plan -out=plan.out

# Apply
read -p "Do you want to apply this plan? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🔨 Applying configuration..."
    terraform apply plan.out
    rm plan.out
    
    echo "✅ VMs created successfully!"
    echo ""
    echo "🧪 Testing SSH connections..."
    sleep 30
    
    for ip in 21 22 23; do
        echo -n "Testing 192.168.10.$ip... "
        if ssh -i ~/.ssh/k8s_ed25519 -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@192.168.10.$ip 'hostname' 2>/dev/null; then
            echo "✅"
        else
            echo "⚠️  Not ready yet"
        fi
    done
    
    echo ""
    echo "🎉 Deployment complete! Check the output above for next steps."
else
    echo "❌ Deployment cancelled"
    rm plan.out
fi