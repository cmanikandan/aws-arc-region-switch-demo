#!/bin/bash

# AWS Application Recovery Controller - Master Test Script
# Complete end-to-end test setup and execution

set -e

echo "🚀 AWS Application Recovery Controller Region Switch Test"
echo "========================================================"
echo ""
echo "This script will:"
echo "1. Create VPC and networking infrastructure in ap-south-1 and ap-south-2"
echo "2. Deploy ALB, Auto Scaling Groups, and EC2 instances with web servers"
echo "3. Set up ARC Region Switch configuration"
echo "4. Provide testing instructions"
echo ""

# Check AWS CLI and credentials
if ! command -v aws &> /dev/null; then
    echo "❌ AWS CLI is not installed. Please install it first."
    exit 1
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "❌ AWS credentials not configured. Please run 'aws configure' first."
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "✅ AWS Account: $ACCOUNT_ID"
echo ""

# Check for existing launch templates and offer to clean them up
echo "🔍 Checking for existing launch templates..."
PRIMARY_LT_EXISTS=$(aws ec2 describe-launch-templates --launch-template-names "arc-test-lt-ap-south-1" --region ap-south-1 >/dev/null 2>&1 && echo "true" || echo "false")
SECONDARY_LT_EXISTS=$(aws ec2 describe-launch-templates --launch-template-names "arc-test-lt-ap-south-2" --region ap-south-2 >/dev/null 2>&1 && echo "true" || echo "false")

if [ "$PRIMARY_LT_EXISTS" = "true" ] || [ "$SECONDARY_LT_EXISTS" = "true" ]; then
    echo "⚠️  Existing launch templates found. This might cause conflicts."
    echo "   Primary region (ap-south-1): $([[ $PRIMARY_LT_EXISTS == "true" ]] && echo "EXISTS" || echo "Not found")"
    echo "   Secondary region (ap-south-2): $([[ $SECONDARY_LT_EXISTS == "true" ]] && echo "EXISTS" || echo "Not found")"
    echo ""
    read -p "Do you want to clean up existing resources first? (recommended: yes/no): " cleanup_confirm
    if [ "$cleanup_confirm" = "yes" ]; then
        echo "Running cleanup script..."
        ./arc-cleanup.sh
        echo "Cleanup completed. Continuing with setup..."
        echo ""
    fi
fi

read -p "Do you want to proceed with the setup? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Setup cancelled."
    exit 0
fi

echo ""
echo "🏗️  Step 1: Creating infrastructure..."
echo "======================================"
./arc-test-setup.sh

echo ""
echo "📱 Step 2: Deploying applications..."
echo "===================================="
./arc-app-setup.sh

echo ""
echo "⚙️  Step 3: Setting up ARC Region Switch..."
echo "==========================================="
./arc-region-switch-setup.sh

echo ""
echo "🎉 Setup Complete!"
echo "=================="
echo ""
echo "Your ARC test environment is ready. Here's what was created:"
echo ""
echo "Primary Region (ap-south-1):"
echo "- VPC with public subnets"
echo "- Application Load Balancer"
echo "- Auto Scaling Group with 2 instances"
echo "- EC2 instances serving a test web page"
echo ""
echo "Secondary Region (ap-south-2):"
echo "- VPC with public subnets"
echo "- Application Load Balancer"
echo "- Auto Scaling Group with 0 instances (standby)"
echo ""
echo "ARC Configuration:"
echo "- IAM role for Region Switch"
echo "- CloudWatch health alarms"
echo "- Route 53 health checks"
echo ""

# Get ALB DNS names
PRIMARY_ALB_DNS=$(aws elbv2 describe-load-balancers --names "arc-test-alb-ap-south-1" --region ap-south-1 --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo "Not found")
SECONDARY_ALB_DNS=$(aws elbv2 describe-load-balancers --names "arc-test-alb-ap-south-2" --region ap-south-2 --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo "Not found")

echo "🌐 Test URLs:"
echo "============="
echo "Primary (ap-south-1):   http://$PRIMARY_ALB_DNS"
echo "Secondary (ap-south-2): http://$SECONDARY_ALB_DNS"
echo ""

echo "📋 Next Steps:"
echo "=============="
echo ""
echo "1. Wait 5-10 minutes for all resources to be healthy"
echo ""
echo "2. Test the primary region:"
echo "   curl http://$PRIMARY_ALB_DNS"
echo "   (or open in browser)"
echo ""
echo "3. Check resource status:"
echo "   ./arc-test-execution.sh"
echo ""
echo "4. Create ARC Region Switch Plan (Manual step):"
echo "   - Go to AWS Console → Application Recovery Controller → Region switch"
echo "   - Click 'Create Region switch plan'"
echo "   - Name: arc-test-plan"
echo "   - Approach: Active/passive"
echo "   - Primary: ap-south-1, Secondary: ap-south-2"
echo "   - RTO: 300 seconds"
echo "   - Use the IAM role: ARC-RegionSwitch-TestRole"
echo ""
echo "5. Test manual failover:"
echo "   ./arc-test-execution.sh failover"
echo "   (Wait 5-10 minutes, then test secondary URL)"
echo ""
echo "6. Test failback:"
echo "   ./arc-test-execution.sh failback"
echo ""
echo "7. When done, clean up all resources:"
echo "   ./arc-cleanup.sh"
echo ""
echo "💡 Tips:"
echo "========"
echo "- The web pages show which region is serving traffic"
echo "- Health checks monitor /health endpoint"
echo "- Auto Scaling Groups scale between 0-4 instances"
echo "- All resources are tagged for easy identification"
echo ""
echo "🔍 Monitoring:"
echo "=============="
echo "- CloudWatch: Monitor ASG and ALB metrics"
echo "- ARC Console: Track plan executions"
echo "- EC2 Console: View instance status"
echo ""
echo "Happy testing! 🎯"