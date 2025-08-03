#!/bin/bash

# AWS Application Recovery Controller - Application Setup
# Deploy ALB, Auto Scaling Groups, and EC2 instances with dummy HTML

set -e

# Configuration
PRIMARY_REGION="ap-south-1"
SECONDARY_REGION="ap-south-2"
KEY_NAME="arc-test-key"
INSTANCE_TYPE="t3.micro"

echo "=== AWS ARC Application Setup ==="

# Get infrastructure details from previous setup
get_infrastructure_details() {
    local region=$1
    local region_suffix=$2
    
    # Get VPC ID
    VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=arc-test-vpc-$region" \
        --query 'Vpcs[0].VpcId' \
        --output text \
        --region $region)
    
    # Get subnet IDs
    SUBNET1_ID=$(aws ec2 describe-subnets \
        --filters "Name=tag:Name,Values=arc-test-subnet1-$region" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        --region $region)
    
    SUBNET2_ID=$(aws ec2 describe-subnets \
        --filters "Name=tag:Name,Values=arc-test-subnet2-$region" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        --region $region)
    
    # Get security group ID
    SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=arc-test-sg-$region" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region $region)
    
    # Get AMI ID
    AMI_ID=$(aws ec2 describe-images \
        --owners amazon \
        --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text \
        --region $region)
    
    echo "Infrastructure details for $region:"
    echo "  VPC: $VPC_ID"
    echo "  Subnets: $SUBNET1_ID, $SUBNET2_ID"
    echo "  Security Group: $SG_ID"
    echo "  AMI: $AMI_ID"
    
    # Export variables
    eval "VPC_ID_${region_suffix}=$VPC_ID"
    eval "SUBNET1_ID_${region_suffix}=$SUBNET1_ID"
    eval "SUBNET2_ID_${region_suffix}=$SUBNET2_ID"
    eval "SG_ID_${region_suffix}=$SG_ID"
    eval "AMI_ID_${region_suffix}=$AMI_ID"
}

# Create user data script for web server
create_user_data() {
    local region=$1
    local status=$2
    
    cat << EOF
#!/bin/bash
yum update -y
yum install -y httpd
systemctl start httpd
systemctl enable httpd

# Create a simple HTML page
cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>ARC Test - $region</title>
    <style>
        body { 
            font-family: Arial, sans-serif; 
            text-align: center; 
            margin: 50px;
            background-color: #f0f8ff;
        }
        .container { 
            max-width: 600px; 
            margin: 0 auto; 
            padding: 20px;
            border: 2px solid #4CAF50;
            border-radius: 10px;
            background-color: white;
        }
        .status { 
            font-size: 24px; 
            font-weight: bold; 
            color: #4CAF50;
            margin: 20px 0;
        }
        .region { 
            font-size: 18px; 
            color: #333;
            margin: 10px 0;
        }
        .timestamp { 
            font-size: 14px; 
            color: #666;
            margin-top: 20px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 AWS Application Recovery Controller Test</h1>
        <div class="status">Status: $status</div>
        <div class="region">Region: $region</div>
        <div class="region">Instance ID: \$(curl -s http://169.254.169.254/latest/meta-data/instance-id)</div>
        <div class="region">Availability Zone: \$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)</div>
        <div class="timestamp">Last Updated: \$(date)</div>
        <p>This page is served from an EC2 instance behind an Application Load Balancer.</p>
        <p>If you can see this page, the region switch test is working!</p>
    </div>
</body>
</html>
HTML

# Update the instance ID and AZ in the HTML
sed -i "s/\\\$(curl -s http:\/\/169.254.169.254\/latest\/meta-data\/instance-id)/\$(curl -s http:\/\/169.254.169.254\/latest\/meta-data\/instance-id)/g" /var/www/html/index.html
sed -i "s/\\\$(curl -s http:\/\/169.254.169.254\/latest\/meta-data\/placement\/availability-zone)/\$(curl -s http:\/\/169.254.169.254\/latest\/meta-data\/placement\/availability-zone)/g" /var/www/html/index.html
sed -i "s/\\\$(date)/\$(date)/g" /var/www/html/index.html

# Create a health check endpoint
echo "OK" > /var/www/html/health

# Restart httpd to ensure everything is working
systemctl restart httpd
EOF
}

# Create launch template
create_launch_template() {
    local region=$1
    local region_suffix=$2
    local status=$3
    
    echo "Creating launch template in $region..."
    
    # Get variables
    eval "SG_ID=\$SG_ID_${region_suffix}"
    eval "AMI_ID=\$AMI_ID_${region_suffix}"
    
    # Check if launch template already exists and delete it
    if aws ec2 describe-launch-templates --launch-template-names "arc-test-lt-$region" --region $region >/dev/null 2>&1; then
        echo "Launch template already exists. Deleting existing template..."
        aws ec2 delete-launch-template \
            --launch-template-name "arc-test-lt-$region" \
            --region $region
        echo "Existing launch template deleted."
    fi
    
    # Create user data
    USER_DATA=$(create_user_data $region $status | base64 -w 0)
    
    # Create launch template
    LT_ID=$(aws ec2 create-launch-template \
        --launch-template-name "arc-test-lt-$region" \
        --launch-template-data "{
            \"ImageId\": \"$AMI_ID\",
            \"InstanceType\": \"$INSTANCE_TYPE\",
            \"KeyName\": \"$KEY_NAME\",
            \"SecurityGroupIds\": [\"$SG_ID\"],
            \"UserData\": \"$USER_DATA\",
            \"TagSpecifications\": [{
                \"ResourceType\": \"instance\",
                \"Tags\": [{
                    \"Key\": \"Name\",
                    \"Value\": \"arc-test-instance-$region\"
                }]
            }]
        }" \
        --region $region \
        --query 'LaunchTemplate.LaunchTemplateId' \
        --output text)
    
    echo "Launch template created: $LT_ID"
    eval "LT_ID_${region_suffix}=$LT_ID"
}

# Create Application Load Balancer
create_alb() {
    local region=$1
    local region_suffix=$2
    
    echo "Creating Application Load Balancer in $region..."
    
    # Get variables
    eval "VPC_ID=\$VPC_ID_${region_suffix}"
    eval "SUBNET1_ID=\$SUBNET1_ID_${region_suffix}"
    eval "SUBNET2_ID=\$SUBNET2_ID_${region_suffix}"
    eval "SG_ID=\$SG_ID_${region_suffix}"
    
    # Create ALB
    ALB_ARN=$(aws elbv2 create-load-balancer \
        --name "arc-test-alb-$region" \
        --subnets $SUBNET1_ID $SUBNET2_ID \
        --security-groups $SG_ID \
        --region $region \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text)
    
    # Get ALB DNS name
    ALB_DNS=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns $ALB_ARN \
        --region $region \
        --query 'LoadBalancers[0].DNSName' \
        --output text)
    
    # Create target group
    TG_ARN=$(aws elbv2 create-target-group \
        --name "arc-test-tg-$region" \
        --protocol HTTP \
        --port 80 \
        --vpc-id $VPC_ID \
        --health-check-path "/health" \
        --health-check-interval-seconds 30 \
        --health-check-timeout-seconds 5 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        --region $region \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text)
    
    # Create listener
    aws elbv2 create-listener \
        --load-balancer-arn $ALB_ARN \
        --protocol HTTP \
        --port 80 \
        --default-actions Type=forward,TargetGroupArn=$TG_ARN \
        --region $region
    
    echo "ALB created in $region:"
    echo "  ARN: $ALB_ARN"
    echo "  DNS: $ALB_DNS"
    echo "  Target Group: $TG_ARN"
    
    # Export variables
    eval "ALB_ARN_${region_suffix}=$ALB_ARN"
    eval "ALB_DNS_${region_suffix}=$ALB_DNS"
    eval "TG_ARN_${region_suffix}=$TG_ARN"
}

# Create Auto Scaling Group
create_asg() {
    local region=$1
    local region_suffix=$2
    local desired_capacity=$3
    
    echo "Creating Auto Scaling Group in $region with capacity $desired_capacity..."
    
    # Get variables
    eval "SUBNET1_ID=\$SUBNET1_ID_${region_suffix}"
    eval "SUBNET2_ID=\$SUBNET2_ID_${region_suffix}"
    eval "LT_ID=\$LT_ID_${region_suffix}"
    eval "TG_ARN=\$TG_ARN_${region_suffix}"
    
    # Create Auto Scaling Group
    aws autoscaling create-auto-scaling-group \
        --auto-scaling-group-name "arc-test-asg-$region" \
        --launch-template "LaunchTemplateId=$LT_ID,Version=\$Latest" \
        --min-size 0 \
        --max-size 4 \
        --desired-capacity $desired_capacity \
        --target-group-arns $TG_ARN \
        --vpc-zone-identifier "$SUBNET1_ID,$SUBNET2_ID" \
        --health-check-type ELB \
        --health-check-grace-period 300 \
        --tags "Key=Name,Value=arc-test-asg-$region,PropagateAtLaunch=true" \
        --region $region
    
    echo "Auto Scaling Group created: arc-test-asg-$region"
}

echo "=== Step 1: Getting infrastructure details ==="
get_infrastructure_details $PRIMARY_REGION "1"
get_infrastructure_details $SECONDARY_REGION "2"

echo "=== Step 2: Creating launch templates ==="
create_launch_template $PRIMARY_REGION "1" "ACTIVE (Primary)"
create_launch_template $SECONDARY_REGION "2" "STANDBY (Secondary)"

echo "=== Step 3: Creating Application Load Balancers ==="
create_alb $PRIMARY_REGION "1"
create_alb $SECONDARY_REGION "2"

echo "=== Step 4: Creating Auto Scaling Groups ==="
create_asg $PRIMARY_REGION "1" 2  # Primary starts with 2 instances
create_asg $SECONDARY_REGION "2" 0  # Secondary starts with 0 instances

echo "=== Application setup complete! ==="
echo ""
echo "Primary Region ($PRIMARY_REGION) ALB DNS: $ALB_DNS_1"
echo "Secondary Region ($SECONDARY_REGION) ALB DNS: $ALB_DNS_2"
echo ""
echo "Wait 5-10 minutes for instances to launch and health checks to pass."
echo "Then test the primary ALB URL in your browser."
echo ""
echo "Next: Run the ARC Region Switch setup script"