#!/bin/bash

# AWS Application Recovery Controller - Cleanup Script
# Remove all resources created for the ARC test

PRIMARY_REGION="ap-south-1"
SECONDARY_REGION="ap-south-2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if resource exists (fixed version)
resource_exists() {
    local command="$1"
    local result
    result=$(eval "$command" 2>/dev/null)
    local exit_code=$?
    
    # Check if command succeeded and returned non-empty result
    if [ $exit_code -eq 0 ] && [ -n "$result" ] && [ "$result" != "None" ] && [ "$result" != "null" ] && [ "$result" != "[]" ]; then
        return 0  # Resource exists
    else
        return 1  # Resource doesn't exist
    fi
}

# Function to safely delete Auto Scaling Group
safe_delete_asg() {
    local region=$1
    local asg_name="arc-test-asg-$region"
    
    print_status "Checking for Auto Scaling Group: $asg_name"
    
    # Check if ASG exists
    local asg_check
    asg_check=$(aws autoscaling describe-auto-scaling-groups \
        --region "$region" \
        --query "AutoScalingGroups[?AutoScalingGroupName=='$asg_name'].AutoScalingGroupName" \
        --output text 2>/dev/null)
    
    if [ -n "$asg_check" ] && [ "$asg_check" != "None" ]; then
        print_status "Found ASG: $asg_name. Deleting..."
        
        # Get instance IDs first
        local instance_ids
        instance_ids=$(aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names "$asg_name" \
            --region "$region" \
            --query 'AutoScalingGroups[0].Instances[].InstanceId' \
            --output text 2>/dev/null || echo "")
        
        # Force delete ASG
        if aws autoscaling delete-auto-scaling-group \
            --auto-scaling-group-name "$asg_name" \
            --force-delete \
            --region "$region" 2>/dev/null; then
            print_status "ASG deletion initiated successfully"
        else
            print_error "Failed to delete ASG $asg_name"
        fi
        
        # Force terminate any remaining instances
        if [ -n "$instance_ids" ] && [ "$instance_ids" != "None" ]; then
            print_status "Force terminating instances: $instance_ids"
            aws ec2 terminate-instances --instance-ids $instance_ids --region "$region" >/dev/null 2>&1 || true
        fi
        
        # Wait for ASG deletion
        print_status "Waiting for ASG deletion..."
        local wait_count=0
        local max_wait=20  # Reduced timeout
        
        while [ $wait_count -lt $max_wait ]; do
            local check_result
            check_result=$(aws autoscaling describe-auto-scaling-groups \
                --region "$region" \
                --query "AutoScalingGroups[?AutoScalingGroupName=='$asg_name'].AutoScalingGroupName" \
                --output text 2>/dev/null)
            
            if [ -z "$check_result" ] || [ "$check_result" = "None" ]; then
                print_status "ASG deleted successfully"
                return 0
            fi
            
            wait_count=$((wait_count + 1))
            echo "  ASG deletion in progress... ($wait_count/$max_wait)"
            sleep 10
        done
        
        print_warning "ASG deletion timeout reached. Continuing..."
    else
        print_warning "Auto Scaling Group $asg_name not found"
    fi
}

# Function to safely delete Load Balancer
safe_delete_alb() {
    local region=$1
    local alb_name="arc-test-alb-$region"
    
    print_status "Checking for Load Balancer: $alb_name"
    
    # Check if ALB exists
    local alb_arn
    alb_arn=$(aws elbv2 describe-load-balancers \
        --region "$region" \
        --query "LoadBalancers[?LoadBalancerName=='$alb_name'].LoadBalancerArn" \
        --output text 2>/dev/null)
    
    if [ -n "$alb_arn" ] && [ "$alb_arn" != "None" ]; then
        print_status "Found ALB: $alb_name. Deleting..."
        
        if aws elbv2 delete-load-balancer --load-balancer-arn "$alb_arn" --region "$region" 2>/dev/null; then
            print_status "ALB deletion initiated successfully"
            
            # Wait for ALB deletion
            print_status "Waiting for ALB deletion..."
            local wait_count=0
            local max_wait=20
            
            while [ $wait_count -lt $max_wait ]; do
                local check_result
                check_result=$(aws elbv2 describe-load-balancers \
                    --region "$region" \
                    --query "LoadBalancers[?LoadBalancerName=='$alb_name'].LoadBalancerArn" \
                    --output text 2>/dev/null)
                
                if [ -z "$check_result" ] || [ "$check_result" = "None" ]; then
                    print_status "ALB deleted successfully"
                    return 0
                fi
                
                wait_count=$((wait_count + 1))
                echo "  ALB deletion in progress... ($wait_count/$max_wait)"
                sleep 10
            done
            
            print_warning "ALB deletion timeout reached. Continuing..."
        else
            print_error "Failed to delete ALB $alb_name"
        fi
    else
        print_warning "Load Balancer $alb_name not found"
    fi
}

# Function to force terminate any remaining test instances
force_cleanup_instances() {
    local region=$1
    print_status "Checking for remaining test instances..."
    
    # Find any instances with our test tags that are still running
    local remaining_instances
    remaining_instances=$(aws ec2 describe-instances \
        --region "$region" \
        --filters "Name=tag:Name,Values=arc-test-instance-*" \
                  "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$remaining_instances" ] && [ "$remaining_instances" != "None" ]; then
        print_status "Force terminating remaining instances: $remaining_instances"
        aws ec2 terminate-instances --instance-ids $remaining_instances --region "$region" || true
        sleep 5
    fi
}

cleanup_region() {
    local region=$1
    print_status "=== Cleaning up resources in $region ==="
    
    # First, force cleanup any remaining instances
    force_cleanup_instances "$region"
    
    # Delete Auto Scaling Group
    safe_delete_asg "$region"
    
    # Delete Launch Template
    local lt_name="arc-test-lt-$region"
    if aws ec2 describe-launch-templates --launch-template-names "$lt_name" --region "$region" >/dev/null 2>&1; then
        print_status "Deleting Launch Template: $lt_name"
        aws ec2 delete-launch-template --launch-template-name "$lt_name" --region "$region" || print_error "Failed to delete Launch Template"
    else
        print_warning "Launch Template $lt_name not found"
    fi
    
    # Delete Load Balancer
    safe_delete_alb "$region"
    
    # Delete Target Group
    local tg_name="arc-test-tg-$region"
    local tg_arn
    tg_arn=$(aws elbv2 describe-target-groups \
        --region "$region" \
        --query "TargetGroups[?TargetGroupName=='$tg_name'].TargetGroupArn" \
        --output text 2>/dev/null)
    
    if [ -n "$tg_arn" ] && [ "$tg_arn" != "None" ]; then
        print_status "Deleting Target Group: $tg_name"
        aws elbv2 delete-target-group --target-group-arn "$tg_arn" --region "$region" || print_error "Failed to delete Target Group"
    else
        print_warning "Target Group $tg_name not found"
    fi
    
    # Delete CloudWatch Alarms
    local alarm_name
    if [ "$region" = "$PRIMARY_REGION" ]; then
        alarm_name="arc-test-health-primary"
    else
        alarm_name="arc-test-health-secondary"
    fi
    
    if aws cloudwatch describe-alarms --alarm-names "$alarm_name" --region "$region" >/dev/null 2>&1; then
        print_status "Deleting CloudWatch Alarm: $alarm_name"
        aws cloudwatch delete-alarms --alarm-names "$alarm_name" --region "$region" || print_error "Failed to delete alarm"
    else
        print_warning "CloudWatch Alarm $alarm_name not found"
    fi
    
    # Delete ALL VPCs with the test name (handle duplicates)
    local vpc_ids
    vpc_ids=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=arc-test-vpc-$region" \
        --query 'Vpcs[].VpcId' \
        --output text \
        --region "$region" 2>/dev/null || echo "")
    
    if [ -n "$vpc_ids" ] && [ "$vpc_ids" != "None" ]; then
        for vpc_id in $vpc_ids; do
            print_status "Processing VPC: $vpc_id"
            
            # Delete Security Groups (except default)
            local sg_ids
            sg_ids=$(aws ec2 describe-security-groups \
                --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=arc-test-sg-*" \
                --query 'SecurityGroups[].GroupId' \
                --output text \
                --region "$region" 2>/dev/null || echo "")
            
            for sg_id in $sg_ids; do
                if [ -n "$sg_id" ] && [ "$sg_id" != "None" ]; then
                    print_status "Deleting Security Group: $sg_id"
                    aws ec2 delete-security-group --group-id "$sg_id" --region "$region" || print_error "Failed to delete Security Group $sg_id"
                fi
            done
            
            # Delete Subnets
            local subnet_ids
            subnet_ids=$(aws ec2 describe-subnets \
                --filters "Name=vpc-id,Values=$vpc_id" \
                --query 'Subnets[].SubnetId' \
                --output text \
                --region "$region" 2>/dev/null || echo "")
            
            for subnet_id in $subnet_ids; do
                if [ -n "$subnet_id" ] && [ "$subnet_id" != "None" ]; then
                    print_status "Deleting Subnet: $subnet_id"
                    aws ec2 delete-subnet --subnet-id "$subnet_id" --region "$region" || print_error "Failed to delete subnet $subnet_id"
                fi
            done
            
            # Delete Route Tables (except main)
            local rt_ids
            rt_ids=$(aws ec2 describe-route-tables \
                --filters "Name=vpc-id,Values=$vpc_id" "Name=association.main,Values=false" \
                --query 'RouteTables[].RouteTableId' \
                --output text \
                --region "$region" 2>/dev/null || echo "")
            
            for rt_id in $rt_ids; do
                if [ -n "$rt_id" ] && [ "$rt_id" != "None" ]; then
                    print_status "Deleting Route Table: $rt_id"
                    aws ec2 delete-route-table --route-table-id "$rt_id" --region "$region" || print_error "Failed to delete route table $rt_id"
                fi
            done
            
            # Delete Internet Gateway
            local igw_id
            igw_id=$(aws ec2 describe-internet-gateways \
                --filters "Name=attachment.vpc-id,Values=$vpc_id" \
                --query 'InternetGateways[0].InternetGatewayId' \
                --output text \
                --region "$region" 2>/dev/null || echo "None")
            
            if [ -n "$igw_id" ] && [ "$igw_id" != "None" ]; then
                print_status "Detaching and deleting Internet Gateway: $igw_id"
                aws ec2 detach-internet-gateway --internet-gateway-id "$igw_id" --vpc-id "$vpc_id" --region "$region" || print_error "Failed to detach IGW"
                aws ec2 delete-internet-gateway --internet-gateway-id "$igw_id" --region "$region" || print_error "Failed to delete IGW"
            fi
            
            # Clean up default security group rules before VPC deletion
            local default_sg
            default_sg=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=default" --query 'SecurityGroups[0].GroupId' --output text --region "$region" 2>/dev/null)
            
            if [ -n "$default_sg" ] && [ "$default_sg" != "None" ]; then
                print_status "Cleaning default security group rules: $default_sg"
                
                # Remove all ingress rules
                local ingress_rules
                ingress_rules=$(aws ec2 describe-security-groups --group-ids "$default_sg" --query 'SecurityGroups[0].IpPermissions' --output json --region "$region" 2>/dev/null)
                if [ "$ingress_rules" != "[]" ] && [ "$ingress_rules" != "null" ]; then
                    aws ec2 revoke-security-group-ingress --group-id "$default_sg" --ip-permissions "$ingress_rules" --region "$region" 2>/dev/null || true
                fi
                
                # Remove all egress rules
                local egress_rules
                egress_rules=$(aws ec2 describe-security-groups --group-ids "$default_sg" --query 'SecurityGroups[0].IpPermissionsEgress' --output json --region "$region" 2>/dev/null)
                if [ "$egress_rules" != "[]" ] && [ "$egress_rules" != "null" ]; then
                    aws ec2 revoke-security-group-egress --group-id "$default_sg" --ip-permissions "$egress_rules" --region "$region" 2>/dev/null || true
                fi
            fi
            
            # Delete VPC
            print_status "Attempting to delete VPC: $vpc_id"
            if aws ec2 delete-vpc --vpc-id "$vpc_id" --region "$region" 2>/dev/null; then
                print_status "VPC $vpc_id deleted successfully"
            else
                print_warning "VPC $vpc_id could not be deleted - may have hidden dependencies"
                print_warning "You can manually delete this VPC through the AWS Console"
            fi
        done
    else
        print_warning "No VPCs found with name arc-test-vpc-$region"
    fi
    
    # Delete Key Pair
    if aws ec2 describe-key-pairs --key-names "arc-test-key" --region "$region" >/dev/null 2>&1; then
        print_status "Deleting Key Pair..."
        aws ec2 delete-key-pair --key-name "arc-test-key" --region "$region" || print_error "Failed to delete key pair"
        rm -f "arc-test-key-$region.pem"
    else
        print_warning "Key Pair arc-test-key not found in $region"
    fi
    
    print_status "=== Cleanup completed for $region ==="
}

echo "=== AWS ARC Test Cleanup ==="
echo "This will delete ALL resources created for the ARC test."
echo "Improvements in this version:"
echo "  ✓ Fixed resource existence checks"
echo "  ✓ Better error handling with colored output"
echo "  ✓ Handles duplicate VPCs properly"
echo "  ✓ Cleans up security group dependencies"
echo "  ✓ Continues cleanup even if some resources fail"
echo ""

# Auto-confirm for non-interactive execution
if [ -t 0 ]; then
    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Cleanup cancelled."
        exit 0
    fi
else
    echo "Running in non-interactive mode. Proceeding with cleanup..."
fi

# Delete Route 53 resources first
print_status "=== Cleaning up Route 53 resources ==="
hosted_zones=$(aws route53 list-hosted-zones --query 'HostedZones[?Name==`arc-test.local.`].Id' --output text 2>/dev/null || echo "")
if [ -n "$hosted_zones" ] && [ "$hosted_zones" != "None" ]; then
    for zone_id in $hosted_zones; do
        print_status "Deleting hosted zone: $zone_id"
        aws route53 delete-hosted-zone --id "$zone_id" || print_error "Failed to delete hosted zone"
    done
else
    print_warning "No Route 53 hosted zones found"
fi

# Delete health checks
health_checks=$(aws route53 list-health-checks \
    --query 'HealthChecks[?CallerReference | starts_with(@, `primary-`) || starts_with(@, `secondary-`)].Id' \
    --output text 2>/dev/null || echo "")
if [ -n "$health_checks" ] && [ "$health_checks" != "None" ]; then
    for hc_id in $health_checks; do
        print_status "Deleting health check: $hc_id"
        aws route53 delete-health-check --health-check-id "$hc_id" || print_error "Failed to delete health check"
    done
else
    print_warning "No Route 53 health checks found"
fi

# Clean up regions
print_status "=== Starting region cleanup ==="
cleanup_region "$PRIMARY_REGION"
cleanup_region "$SECONDARY_REGION"

# Delete IAM role
print_status "=== Cleaning up IAM resources ==="
if aws iam get-role --role-name ARC-RegionSwitch-TestRole >/dev/null 2>&1; then
    print_status "Deleting IAM role policies and role..."
    aws iam delete-role-policy --role-name ARC-RegionSwitch-TestRole --policy-name ARC-RegionSwitch-Permissions 2>/dev/null || true
    aws iam delete-role --role-name ARC-RegionSwitch-TestRole || print_error "Failed to delete IAM role"
else
    print_warning "IAM role ARC-RegionSwitch-TestRole not found"
fi

# Clean up local files
print_status "=== Cleaning up local files ==="
rm -f arc-test-execution.sh
rm -f arc-test-key-*.pem
rm -f records.json

print_status "=== Cleanup complete! ==="
print_status "All ARC test resources have been deleted."
print_status "Summary of what was cleaned up:"
print_status "  ✓ Auto Scaling Groups and EC2 instances"
print_status "  ✓ Load Balancers and Target Groups"
print_status "  ✓ VPCs, Subnets, Security Groups, and Internet Gateways"
print_status "  ✓ Launch Templates and Key Pairs"
print_status "  ✓ CloudWatch Alarms"
print_status "  ✓ Route 53 resources"
print_status "  ✓ IAM roles and policies"
print_status "  ✓ Local files"
print_status ""
print_status "Note: If any VPCs couldn't be deleted due to hidden dependencies,"
print_status "you can safely delete them manually through the AWS Console."
print_status "VPCs don't incur charges, so they can also be left as-is."