#!/bin/bash

# Quick test script to verify cleanup improvements
# This script checks if resources still exist after cleanup

PRIMARY_REGION="ap-south-1"
SECONDARY_REGION="ap-south-2"

check_resources() {
    local region=$1
    echo "Checking remaining resources in $region..."
    
    # Check ASG
    if aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "arc-test-asg-$region" --region $region >/dev/null 2>&1; then
        echo "❌ ASG still exists in $region"
    else
        echo "✅ ASG deleted in $region"
    fi
    
    # Check instances
    INSTANCES=$(aws ec2 describe-instances \
        --region $region \
        --filters "Name=tag:Name,Values=arc-test-instance-*" \
                  "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$INSTANCES" ] && [ "$INSTANCES" != "None" ]; then
        echo "❌ Instances still exist in $region: $INSTANCES"
    else
        echo "✅ No test instances remaining in $region"
    fi
    
    # Check ALB
    if aws elbv2 describe-load-balancers --names "arc-test-alb-$region" --region $region >/dev/null 2>&1; then
        echo "❌ ALB still exists in $region"
    else
        echo "✅ ALB deleted in $region"
    fi
    
    # Check VPC
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=arc-test-vpc-$region" --query 'Vpcs[0].VpcId' --output text --region $region 2>/dev/null || echo "None")
    if [ "$VPC_ID" != "None" ] && [ "$VPC_ID" != "null" ]; then
        echo "❌ VPC still exists in $region: $VPC_ID"
    else
        echo "✅ VPC deleted in $region"
    fi
    
    echo ""
}

echo "=== ARC Cleanup Verification ==="
check_resources $PRIMARY_REGION
check_resources $SECONDARY_REGION

# Check IAM role
if aws iam get-role --role-name ARC-RegionSwitch-TestRole >/dev/null 2>&1; then
    echo "❌ IAM role still exists"
else
    echo "✅ IAM role deleted"
fi

echo "=== Verification Complete ==="