#!/bin/bash

# Quick cleanup script for launch templates only
# Use this if you just need to clean up launch templates without full cleanup

set -e

PRIMARY_REGION="ap-south-1"
SECONDARY_REGION="ap-south-2"

echo "=== Launch Template Cleanup ==="
echo "This will delete only the launch templates for the ARC test."

cleanup_launch_template() {
    local region=$1
    echo "Checking launch template in $region..."
    
    if aws ec2 describe-launch-templates --launch-template-names "arc-test-lt-$region" --region $region >/dev/null 2>&1; then
        echo "Deleting launch template in $region..."
        aws ec2 delete-launch-template \
            --launch-template-name "arc-test-lt-$region" \
            --region $region
        echo "Launch template deleted in $region"
    else
        echo "No launch template found in $region"
    fi
}

cleanup_launch_template $PRIMARY_REGION
cleanup_launch_template $SECONDARY_REGION

echo "=== Launch template cleanup complete! ==="