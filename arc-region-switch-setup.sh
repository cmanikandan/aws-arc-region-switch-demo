#!/bin/bash

# AWS Application Recovery Controller - Region Switch Setup
# Configure ARC Region Switch for ALB and ASG failover

set -e

# Configuration
PRIMARY_REGION="ap-south-1"
SECONDARY_REGION="ap-south-2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== AWS ARC Region Switch Setup ==="
echo "Account ID: $ACCOUNT_ID"

# Create IAM role for ARC Region Switch
create_arc_iam_role() {
    echo "Creating IAM role for ARC Region Switch..."
    
    # Create trust policy
    cat > arc-trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "arc-region-switch.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

    # Create permissions policy
    cat > arc-permissions-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "autoscaling:*",
                "ec2:*",
                "elasticloadbalancing:*",
                "route53:*",
                "cloudwatch:*",
                "logs:*",
                "iam:PassRole"
            ],
            "Resource": "*"
        }
    ]
}
EOF

    # Create the IAM role
    if ! aws iam get-role --role-name ARC-RegionSwitch-TestRole >/dev/null 2>&1; then
        aws iam create-role \
            --role-name ARC-RegionSwitch-TestRole \
            --assume-role-policy-document file://arc-trust-policy.json
        
        # Attach permissions to the role
        aws iam put-role-policy \
            --role-name ARC-RegionSwitch-TestRole \
            --policy-name ARC-RegionSwitch-Permissions \
            --policy-document file://arc-permissions-policy.json
        
        echo "IAM role created: ARC-RegionSwitch-TestRole"
        
        # Wait for role to be available
        echo "Waiting for IAM role to be available..."
        sleep 30
    else
        echo "IAM role ARC-RegionSwitch-TestRole already exists"
    fi
    
    # Get role ARN
    ROLE_ARN=$(aws iam get-role --role-name ARC-RegionSwitch-TestRole --query 'Role.Arn' --output text)
    echo "Role ARN: $ROLE_ARN"
}

# Create CloudWatch alarms for health monitoring
create_health_alarms() {
    echo "Creating CloudWatch alarms for health monitoring..."
    
    # Create alarm for primary region
    aws cloudwatch put-metric-alarm \
        --alarm-name "arc-test-health-primary" \
        --alarm-description "Health alarm for primary region" \
        --metric-name HealthyHostCount \
        --namespace AWS/ApplicationELB \
        --statistic Average \
        --period 60 \
        --threshold 1 \
        --comparison-operator LessThanThreshold \
        --evaluation-periods 2 \
        --dimensions Name=LoadBalancer,Value=$(aws elbv2 describe-load-balancers --names "arc-test-alb-$PRIMARY_REGION" --region $PRIMARY_REGION --query 'LoadBalancers[0].LoadBalancerArn' --output text | cut -d'/' -f2-) \
        --region $PRIMARY_REGION
    
    # Create alarm for secondary region
    aws cloudwatch put-metric-alarm \
        --alarm-name "arc-test-health-secondary" \
        --alarm-description "Health alarm for secondary region" \
        --metric-name HealthyHostCount \
        --namespace AWS/ApplicationELB \
        --statistic Average \
        --period 60 \
        --threshold 1 \
        --comparison-operator LessThanThreshold \
        --evaluation-periods 2 \
        --dimensions Name=LoadBalancer,Value=$(aws elbv2 describe-load-balancers --names "arc-test-alb-$SECONDARY_REGION" --region $SECONDARY_REGION --query 'LoadBalancers[0].LoadBalancerArn' --output text | cut -d'/' -f2-) \
        --region $SECONDARY_REGION
    
    echo "Health alarms created"
}

# Create Route 53 hosted zone and records for DNS failover
create_route53_setup() {
    echo "Creating Route 53 setup for DNS failover..."
    
    # Create a hosted zone (you'll need to own a domain for this to work fully)
    # For testing, we'll create a private hosted zone
    HOSTED_ZONE_ID=$(aws route53 create-hosted-zone \
        --name "arc-test.local" \
        --caller-reference "arc-test-$(date +%s)" \
        --vpc VPCRegion=$PRIMARY_REGION,VPCId=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=arc-test-vpc-$PRIMARY_REGION" --query 'Vpcs[0].VpcId' --output text --region $PRIMARY_REGION) \
        --query 'HostedZone.Id' \
        --output text)
    
    echo "Hosted Zone created: $HOSTED_ZONE_ID"
    
    # Get ALB DNS names
    PRIMARY_ALB_DNS=$(aws elbv2 describe-load-balancers --names "arc-test-alb-$PRIMARY_REGION" --region $PRIMARY_REGION --query 'LoadBalancers[0].DNSName' --output text)
    SECONDARY_ALB_DNS=$(aws elbv2 describe-load-balancers --names "arc-test-alb-$SECONDARY_REGION" --region $SECONDARY_REGION --query 'LoadBalancers[0].DNSName' --output text)
    
    # Create health checks
    PRIMARY_HEALTH_CHECK_ID=$(aws route53 create-health-check \
        --caller-reference "primary-$(date +%s)" \
        --health-check-config Type=HTTP,ResourcePath=/health,FullyQualifiedDomainName=$PRIMARY_ALB_DNS,Port=80,RequestInterval=30,FailureThreshold=3 \
        --query 'HealthCheck.Id' \
        --output text)
    
    SECONDARY_HEALTH_CHECK_ID=$(aws route53 create-health-check \
        --caller-reference "secondary-$(date +%s)" \
        --health-check-config Type=HTTP,ResourcePath=/health,FullyQualifiedDomainName=$SECONDARY_ALB_DNS,Port=80,RequestInterval=30,FailureThreshold=3 \
        --query 'HealthCheck.Id' \
        --output text)
    
    echo "Health checks created: $PRIMARY_HEALTH_CHECK_ID, $SECONDARY_HEALTH_CHECK_ID"
    
    # Export variables
    export HOSTED_ZONE_ID
    export PRIMARY_HEALTH_CHECK_ID
    export SECONDARY_HEALTH_CHECK_ID
}

# Create ARC Region Switch plan using AWS CLI
create_arc_plan() {
    echo "Creating ARC Region Switch plan..."
    
    # Get role ARN
    ROLE_ARN=$(aws iam get-role --role-name ARC-RegionSwitch-TestRole --query 'Role.Arn' --output text)
    
    # Create plan configuration
    cat > plan-config.json << EOF
{
    "name": "arc-test-plan",
    "recoveryApproach": "active-passive",
    "primaryRegion": "$PRIMARY_REGION",
    "standbyRegion": "$SECONDARY_REGION",
    "recoveryTimeObjective": 300,
    "executionRoleArn": "$ROLE_ARN",
    "applicationHealthAlarms": [
        {
            "region": "$PRIMARY_REGION",
            "alarmName": "arc-test-health-primary"
        },
        {
            "region": "$SECONDARY_REGION",
            "alarmName": "arc-test-health-secondary"
        }
    ],
    "tags": [
        {
            "key": "Environment",
            "value": "Test"
        },
        {
            "key": "Purpose",
            "value": "ARC-RegionSwitch-Demo"
        }
    ]
}
EOF

    echo "Plan configuration created. Note: You'll need to create the plan through the AWS Console"
    echo "as the CLI commands for ARC Region Switch are still being finalized."
    echo ""
    echo "To create the plan manually:"
    echo "1. Go to AWS Console -> Application Recovery Controller -> Region switch"
    echo "2. Click 'Create Region switch plan'"
    echo "3. Use the following configuration:"
    echo "   - Name: arc-test-plan"
    echo "   - Approach: Active/passive"
    echo "   - Primary Region: $PRIMARY_REGION"
    echo "   - Standby Region: $SECONDARY_REGION"
    echo "   - RTO: 300 seconds"
    echo "   - IAM Role: $ROLE_ARN"
    echo "   - Health Alarms: arc-test-health-primary, arc-test-health-secondary"
}

# Create test execution script
create_test_script() {
    echo "Creating test execution script..."
    
    cat > arc-test-execution.sh << 'EOF'
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
EOF

    chmod +x arc-test-execution.sh
    echo "Test execution script created: arc-test-execution.sh"
}

echo "=== Step 1: Creating IAM role ==="
create_arc_iam_role

echo "=== Step 2: Creating health alarms ==="
create_health_alarms

echo "=== Step 3: Creating Route 53 setup ==="
create_route53_setup

echo "=== Step 4: Creating ARC plan configuration ==="
create_arc_plan

echo "=== Step 5: Creating test execution script ==="
create_test_script

echo "=== ARC Region Switch setup complete! ==="
echo ""
echo "Next steps:"
echo "1. Wait for all resources to be healthy (5-10 minutes)"
echo "2. Test the primary region ALB"
echo "3. Create the ARC plan through AWS Console (see instructions above)"
echo "4. Run ./arc-test-execution.sh to check status"
echo "5. Run ./arc-test-execution.sh failover to test manual failover"
echo "6. Run ./arc-test-execution.sh failback to test failback"

# Clean up temporary files
rm -f arc-trust-policy.json arc-permissions-policy.json plan-config.json