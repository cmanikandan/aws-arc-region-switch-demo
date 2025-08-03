#!/bin/bash

# AWS Application Recovery Controller - Cleanup Script
# Remove all resources created for the ARC test

set -e

PRIMARY_REGION="ap-south-1"
SECONDARY_REGION="ap-south-2"

# Function to force terminate any remaining test instances
force_cleanup_instances() {
    local region=$1
    echo "Checking for any remaining test instances in $region..."
    
    # Find any instances with our test tags that are still running
    REMAINING_INSTANCES=$(aws ec2 describe-instances \
        --region $region \
        --filters "Name=tag:Name,Values=arc-test-instance-*" \
                  "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$REMAINING_INSTANCES" ] && [ "$REMAINING_INSTANCES" != "None" ]; then
        echo "Force terminating remaining instances: $REMAINING_INSTANCES"
        aws ec2 terminate-instances --instance-ids $REMAINING_INSTANCES --region $region || true
        
        # Wait a bit for termination to start
        sleep 5
    fi
}

echo "=== AWS ARC Test Cleanup ==="
echo "This will delete ALL resources created for the ARC test."
echo "Improvements in this version:"
echo "  ✓ Force deletion of Auto Scaling Groups"
echo "  ✓ Parallel cleanup of both regions"
echo "  ✓ Timeout protection (5 min max per ASG)"
echo "  ✓ Better error handling"
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Cleanup cancelled."
    exit 0
fi

cleanup_region() {
    local region=$1
    echo "Cleaning up resources in $region..."
    
    # First, force cleanup any remaining instances
    force_cleanup_instances $region
    
    # Delete Auto Scaling Group with force termination
    if aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "arc-test-asg-$region" --region $region >/dev/null 2>&1; then
        echo "Force deleting Auto Scaling Group and instances..."
        
        # Get instance IDs before deleting ASG
        INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names "arc-test-asg-$region" \
            --region $region \
            --query 'AutoScalingGroups[0].Instances[].InstanceId' \
            --output text 2>/dev/null || echo "")
        
        # Force delete ASG immediately (this will terminate instances)
        aws autoscaling delete-auto-scaling-group \
            --auto-scaling-group-name "arc-test-asg-$region" \
            --force-delete \
            --region $region
        
        # Force terminate any remaining instances
        if [ -n "$INSTANCE_IDS" ] && [ "$INSTANCE_IDS" != "None" ]; then
            echo "Force terminating instances: $INSTANCE_IDS"
            aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region $region >/dev/null 2>&1 || true
        fi
        
        # Wait for ASG deletion with timeout
        echo "Waiting for Auto Scaling Group deletion..."
        local wait_count=0
        local max_wait=30  # 5 minutes max (30 * 10 seconds)
        
        while aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "arc-test-asg-$region" --region $region >/dev/null 2>&1; do
            wait_count=$((wait_count + 1))
            if [ $wait_count -ge $max_wait ]; then
                echo "WARNING: ASG deletion timeout reached. Continuing with cleanup..."
                break
            fi
            echo "ASG deletion in progress... ($wait_count/$max_wait)"
            sleep 10
        done
        
        if [ $wait_count -lt $max_wait ]; then
            echo "Auto Scaling Group deleted successfully."
        fi
    fi
    
    # Delete Launch Template
    if aws ec2 describe-launch-templates --launch-template-names "arc-test-lt-$region" --region $region >/dev/null 2>&1; then
        echo "Deleting Launch Template..."
        aws ec2 delete-launch-template \
            --launch-template-name "arc-test-lt-$region" \
            --region $region
    fi
    
    # Delete Load Balancer
    if aws elbv2 describe-load-balancers --names "arc-test-alb-$region" --region $region >/dev/null 2>&1; then
        echo "Deleting Load Balancer..."
        ALB_ARN=$(aws elbv2 describe-load-balancers --names "arc-test-alb-$region" --region $region --query 'LoadBalancers[0].LoadBalancerArn' --output text)
        aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN --region $region
        
        # Wait for ALB to be deleted
        echo "Waiting for ALB to be deleted..."
        aws elbv2 wait load-balancer-deleted --load-balancer-arns $ALB_ARN --region $region
    fi
    
    # Delete Target Group
    if aws elbv2 describe-target-groups --names "arc-test-tg-$region" --region $region >/dev/null 2>&1; then
        echo "Deleting Target Group..."
        TG_ARN=$(aws elbv2 describe-target-groups --names "arc-test-tg-$region" --region $region --query 'TargetGroups[0].TargetGroupArn' --output text)
        aws elbv2 delete-target-group --target-group-arn $TG_ARN --region $region
    fi
    
    # Delete CloudWatch Alarms
    if [ "$region" = "$PRIMARY_REGION" ]; then
        aws cloudwatch delete-alarms --alarm-names "arc-test-health-primary" --region $region 2>/dev/null || true
    else
        aws cloudwatch delete-alarms --alarm-names "arc-test-health-secondary" --region $region 2>/dev/null || true
    fi
    
    # Get VPC ID
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=arc-test-vpc-$region" --query 'Vpcs[0].VpcId' --output text --region $region 2>/dev/null || echo "None")
    
    if [ "$VPC_ID" != "None" ] && [ "$VPC_ID" != "null" ]; then
        # Delete Security Group
        SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=arc-test-sg-$region" --query 'SecurityGroups[0].GroupId' --output text --region $region 2>/dev/null || echo "None")
        if [ "$SG_ID" != "None" ] && [ "$SG_ID" != "null" ]; then
            echo "Deleting Security Group..."
            aws ec2 delete-security-group --group-id $SG_ID --region $region
        fi
        
        # Delete Subnets
        SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId' --output text --region $region)
        for subnet_id in $SUBNET_IDS; do
            echo "Deleting Subnet: $subnet_id"
            aws ec2 delete-subnet --subnet-id $subnet_id --region $region
        done
        
        # Delete Route Tables (except main)
        RT_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=false" --query 'RouteTables[].RouteTableId' --output text --region $region)
        for rt_id in $RT_IDS; do
            echo "Deleting Route Table: $rt_id"
            aws ec2 delete-route-table --route-table-id $rt_id --region $region
        done
        
        # Delete Internet Gateway
        IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text --region $region 2>/dev/null || echo "None")
        if [ "$IGW_ID" != "None" ] && [ "$IGW_ID" != "null" ]; then
            echo "Detaching and deleting Internet Gateway..."
            aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $region
            aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID --region $region
        fi
        
        # Delete VPC
        echo "Deleting VPC..."
        aws ec2 delete-vpc --vpc-id $VPC_ID --region $region
    fi
    
    # Delete Key Pair
    if aws ec2 describe-key-pairs --key-names "arc-test-key" --region $region >/dev/null 2>&1; then
        echo "Deleting Key Pair..."
        aws ec2 delete-key-pair --key-name "arc-test-key" --region $region
        rm -f "arc-test-key-$region.pem"
    fi
}

# Delete Route 53 resources
echo "Cleaning up Route 53 resources..."
HOSTED_ZONES=$(aws route53 list-hosted-zones --query 'HostedZones[?Name==`arc-test.local.`].Id' --output text)
for zone_id in $HOSTED_ZONES; do
    echo "Deleting hosted zone: $zone_id"
    # Delete all records except NS and SOA
    aws route53 list-resource-record-sets --hosted-zone-id $zone_id --query 'ResourceRecordSets[?Type!=`NS` && Type!=`SOA`]' --output json > records.json
    if [ -s records.json ] && [ "$(cat records.json)" != "[]" ]; then
        aws route53 change-resource-record-sets --hosted-zone-id $zone_id --change-batch '{"Changes":[]}' --cli-input-json file://records.json
    fi
    aws route53 delete-hosted-zone --id $zone_id
    rm -f records.json
done

# Delete health checks
HEALTH_CHECKS=$(aws route53 list-health-checks --query 'HealthChecks[?CallerReference | starts_with(@, `primary-`) || starts_with(@, `secondary-`)].Id' --output text)
for hc_id in $HEALTH_CHECKS; do
    echo "Deleting health check: $hc_id"
    aws route53 delete-health-check --health-check-id $hc_id
done

# Clean up regions in parallel for faster execution
echo "Starting parallel cleanup of both regions..."
cleanup_region $PRIMARY_REGION &
PRIMARY_PID=$!
cleanup_region $SECONDARY_REGION &
SECONDARY_PID=$!

# Wait for both cleanups to complete
echo "Waiting for primary region cleanup to complete..."
wait $PRIMARY_PID
echo "Primary region cleanup completed."

echo "Waiting for secondary region cleanup to complete..."
wait $SECONDARY_PID
echo "Secondary region cleanup completed."

# Delete IAM role
echo "Deleting IAM role..."
if aws iam get-role --role-name ARC-RegionSwitch-TestRole >/dev/null 2>&1; then
    aws iam delete-role-policy --role-name ARC-RegionSwitch-TestRole --policy-name ARC-RegionSwitch-Permissions
    aws iam delete-role --role-name ARC-RegionSwitch-TestRole
fi

# Clean up local files
echo "Cleaning up local files..."
rm -f arc-test-execution.sh
rm -f arc-test-key-*.pem

echo "=== Cleanup complete! ==="
echo "All ARC test resources have been deleted."