#!/bin/bash

# ARC Region Switch Test Execution Script

PRIMARY_REGION="ap-south-1"
SECONDARY_REGION="ap-south-2"

echo "=== ARC Region Switch Test Execution ==="

# Function to check ASG status
check_asg_status() {
    local region=$1
    echo "Checking Auto Scaling Group status in $region:"
    aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "arc-test-asg-$region" \
        --region $region \
        --query 'AutoScalingGroups[0].[AutoScalingGroupName,DesiredCapacity,Instances[].InstanceId]' \
        --output table
}

# Function to check ALB target health
check_alb_health() {
    local region=$1
    echo "Checking ALB target health in $region:"
    TG_ARN=$(aws elbv2 describe-target-groups \
        --names "arc-test-tg-$region" \
        --region $region \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text)
    
    aws elbv2 describe-target-health \
        --target-group-arn $TG_ARN \
        --region $region \
        --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' \
        --output table
}

# Function to test web connectivity
test_web_connectivity() {
    local region=$1
    echo "Testing web connectivity for $region:"
    ALB_DNS=$(aws elbv2 describe-load-balancers \
        --names "arc-test-alb-$region" \
        --region $region \
        --query 'LoadBalancers[0].DNSName' \
        --output text)
    
    echo "ALB DNS: $ALB_DNS"
    echo "Testing HTTP connectivity..."
    
    if curl -s --connect-timeout 10 "http://$ALB_DNS" | grep -q "ARC Test"; then
        echo "✅ Web connectivity successful"
    else
        echo "❌ Web connectivity failed"
    fi
}

echo "=== Pre-failover Status ==="
check_asg_status $PRIMARY_REGION
check_asg_status $SECONDARY_REGION
check_alb_health $PRIMARY_REGION
check_alb_health $SECONDARY_REGION
test_web_connectivity $PRIMARY_REGION

echo ""
echo "=== Manual Failover Test ==="
echo "To test manual failover:"
echo "1. Scale down primary ASG:"
echo "   aws autoscaling update-auto-scaling-group --auto-scaling-group-name arc-test-asg-$PRIMARY_REGION --desired-capacity 0 --region $PRIMARY_REGION"
echo ""
echo "2. Scale up secondary ASG:"
echo "   aws autoscaling update-auto-scaling-group --auto-scaling-group-name arc-test-asg-$SECONDARY_REGION --desired-capacity 2 --region $SECONDARY_REGION"
echo ""
echo "3. Wait 5-10 minutes for instances to launch and health checks to pass"
echo ""
echo "4. Test secondary region connectivity:"
echo "   ./arc-test-execution.sh"

# If arguments provided, execute the failover
if [ "$1" = "failover" ]; then
    echo "Executing failover..."
    
    echo "Scaling down primary ASG..."
    aws autoscaling update-auto-scaling-group \
        --auto-scaling-group-name "arc-test-asg-$PRIMARY_REGION" \
        --desired-capacity 0 \
        --region $PRIMARY_REGION
    
    echo "Scaling up secondary ASG..."
    aws autoscaling update-auto-scaling-group \
        --auto-scaling-group-name "arc-test-asg-$SECONDARY_REGION" \
        --desired-capacity 2 \
        --region $SECONDARY_REGION
    
    echo "Failover initiated. Wait 5-10 minutes for completion."
fi

if [ "$1" = "failback" ]; then
    echo "Executing failback..."
    
    echo "Scaling down secondary ASG..."
    aws autoscaling update-auto-scaling-group \
        --auto-scaling-group-name "arc-test-asg-$SECONDARY_REGION" \
        --desired-capacity 0 \
        --region $SECONDARY_REGION
    
    echo "Scaling up primary ASG..."
    aws autoscaling update-auto-scaling-group \
        --auto-scaling-group-name "arc-test-asg-$PRIMARY_REGION" \
        --desired-capacity 2 \
        --region $PRIMARY_REGION
    
    echo "Failback initiated. Wait 5-10 minutes for completion."
fi