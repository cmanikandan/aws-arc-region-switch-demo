#!/bin/bash

# AWS Application Recovery Controller Region Switch Test Setup
# Testing between ap-south-1 (Mumbai) and ap-south-2 (Hyderabad)

set -e

# Configuration
PRIMARY_REGION="ap-south-1"
SECONDARY_REGION="ap-south-2"
KEY_NAME="arc-test-key"
INSTANCE_TYPE="t3.micro"

echo "=== AWS ARC Region Switch Test Setup ==="
echo "Primary Region: $PRIMARY_REGION"
echo "Secondary Region: $SECONDARY_REGION"

# Function to create VPC and networking
create_networking() {
    local region=$1
    local region_suffix=$2
    
    echo "Creating networking infrastructure in $region..."
    
    # Create VPC
    VPC_ID=$(aws ec2 create-vpc \
        --cidr-block 10.${region_suffix}.0.0/16 \
        --region $region \
        --query 'Vpc.VpcId' \
        --output text)
    
    aws ec2 create-tags \
        --resources $VPC_ID \
        --tags Key=Name,Value=arc-test-vpc-$region \
        --region $region
    
    # Enable DNS hostnames
    aws ec2 modify-vpc-attribute \
        --vpc-id $VPC_ID \
        --enable-dns-hostnames \
        --region $region
    
    # Create Internet Gateway
    IGW_ID=$(aws ec2 create-internet-gateway \
        --region $region \
        --query 'InternetGateway.InternetGatewayId' \
        --output text)
    
    aws ec2 attach-internet-gateway \
        --internet-gateway-id $IGW_ID \
        --vpc-id $VPC_ID \
        --region $region
    
    aws ec2 create-tags \
        --resources $IGW_ID \
        --tags Key=Name,Value=arc-test-igw-$region \
        --region $region
    
    # Create public subnets in two AZs
    SUBNET1_ID=$(aws ec2 create-subnet \
        --vpc-id $VPC_ID \
        --cidr-block 10.${region_suffix}.1.0/24 \
        --availability-zone ${region}a \
        --region $region \
        --query 'Subnet.SubnetId' \
        --output text)
    
    SUBNET2_ID=$(aws ec2 create-subnet \
        --vpc-id $VPC_ID \
        --cidr-block 10.${region_suffix}.2.0/24 \
        --availability-zone ${region}b \
        --region $region \
        --query 'Subnet.SubnetId' \
        --output text)
    
    aws ec2 create-tags \
        --resources $SUBNET1_ID \
        --tags Key=Name,Value=arc-test-subnet1-$region \
        --region $region
    
    aws ec2 create-tags \
        --resources $SUBNET2_ID \
        --tags Key=Name,Value=arc-test-subnet2-$region \
        --region $region
    
    # Enable auto-assign public IP
    aws ec2 modify-subnet-attribute \
        --subnet-id $SUBNET1_ID \
        --map-public-ip-on-launch \
        --region $region
    
    aws ec2 modify-subnet-attribute \
        --subnet-id $SUBNET2_ID \
        --map-public-ip-on-launch \
        --region $region
    
    # Create route table
    RT_ID=$(aws ec2 create-route-table \
        --vpc-id $VPC_ID \
        --region $region \
        --query 'RouteTable.RouteTableId' \
        --output text)
    
    aws ec2 create-tags \
        --resources $RT_ID \
        --tags Key=Name,Value=arc-test-rt-$region \
        --region $region
    
    # Add route to internet gateway
    aws ec2 create-route \
        --route-table-id $RT_ID \
        --destination-cidr-block 0.0.0.0/0 \
        --gateway-id $IGW_ID \
        --region $region
    
    # Associate subnets with route table
    aws ec2 associate-route-table \
        --subnet-id $SUBNET1_ID \
        --route-table-id $RT_ID \
        --region $region
    
    aws ec2 associate-route-table \
        --subnet-id $SUBNET2_ID \
        --route-table-id $RT_ID \
        --region $region
    
    # Create security group
    SG_ID=$(aws ec2 create-security-group \
        --group-name arc-test-sg-$region \
        --description "Security group for ARC test" \
        --vpc-id $VPC_ID \
        --region $region \
        --query 'GroupId' \
        --output text)
    
    # Add security group rules
    aws ec2 authorize-security-group-ingress \
        --group-id $SG_ID \
        --protocol tcp \
        --port 80 \
        --cidr 0.0.0.0/0 \
        --region $region
    
    aws ec2 authorize-security-group-ingress \
        --group-id $SG_ID \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 \
        --region $region
    
    echo "Networking created in $region:"
    echo "  VPC: $VPC_ID"
    echo "  Subnets: $SUBNET1_ID, $SUBNET2_ID"
    echo "  Security Group: $SG_ID"
    
    # Export variables for use in other functions
    eval "VPC_ID_${region_suffix}=$VPC_ID"
    eval "SUBNET1_ID_${region_suffix}=$SUBNET1_ID"
    eval "SUBNET2_ID_${region_suffix}=$SUBNET2_ID"
    eval "SG_ID_${region_suffix}=$SG_ID"
}

# Create key pair if it doesn't exist
create_key_pair() {
    local region=$1
    
    echo "Creating key pair in $region..."
    
    if ! aws ec2 describe-key-pairs --key-names $KEY_NAME --region $region >/dev/null 2>&1; then
        aws ec2 create-key-pair \
            --key-name $KEY_NAME \
            --region $region \
            --query 'KeyMaterial' \
            --output text > ${KEY_NAME}-${region}.pem
        chmod 400 ${KEY_NAME}-${region}.pem
        echo "Key pair created: ${KEY_NAME}-${region}.pem"
    else
        echo "Key pair $KEY_NAME already exists in $region"
    fi
}

# Get latest Amazon Linux 2 AMI
get_ami_id() {
    local region=$1
    aws ec2 describe-images \
        --owners amazon \
        --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text \
        --region $region
}

echo "=== Step 1: Creating networking infrastructure ==="
create_networking $PRIMARY_REGION "1"
create_networking $SECONDARY_REGION "2"

echo "=== Step 2: Creating key pairs ==="
create_key_pair $PRIMARY_REGION
create_key_pair $SECONDARY_REGION

echo "=== Step 3: Getting AMI IDs ==="
AMI_ID_PRIMARY=$(get_ami_id $PRIMARY_REGION)
AMI_ID_SECONDARY=$(get_ami_id $SECONDARY_REGION)

echo "AMI ID for $PRIMARY_REGION: $AMI_ID_PRIMARY"
echo "AMI ID for $SECONDARY_REGION: $AMI_ID_SECONDARY"

echo "=== Infrastructure setup complete! ==="
echo "Next: Run the application setup script"