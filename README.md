# AWS Application Recovery Controller (ARC) Region Switch Test

A complete end-to-end test setup for AWS Application Recovery Controller Region Switch between **ap-south-1 (Mumbai)** and **ap-south-2 (Hyderabad)**.

## 🚀 Quick Start

```bash
# Run the complete setup
./run-arc-test.sh

# Check status
./arc-test-execution.sh

# Test manual failover
./arc-test-execution.sh failover

# Test failback
./arc-test-execution.sh failback

# Clean up when done
./arc-cleanup.sh
```

## 📋 Prerequisites

- AWS CLI configured with appropriate permissions
- Access to ap-south-1 and ap-south-2 regions
- Permissions for EC2, ELB, Auto Scaling, IAM, CloudWatch, Route 53

## 🏗️ What Gets Created

### Infrastructure
- **2 VPCs** (10.1.0.0/16 in ap-south-1, 10.2.0.0/16 in ap-south-2)
- **4 Public Subnets** (2 per region across different AZs)
- **2 Application Load Balancers** with health checks
- **2 Auto Scaling Groups** (Primary: 2 instances, Secondary: 0 instances)
- **EC2 instances** with custom web servers showing region status
- **Security Groups** allowing HTTP (80) and SSH (22)

### ARC Components
- **IAM Role** for ARC Region Switch execution
- **CloudWatch Alarms** for health monitoring
- **Route 53 Health Checks** for DNS failover
- **Test execution scripts** for manual operations

## 🎯 Test Scenarios

### ✅ Test 1: Normal Operation
- Primary region (ap-south-1) serves traffic
- 2 instances running, showing "STATUS: ACTIVE"
- Secondary region (ap-south-2) in standby with 0 instances

### ✅ Test 2: Manual Failover
- Scale down primary region to 0 instances
- Scale up secondary region to 2 instances
- Traffic shifts to ap-south-2, showing "STATUS: STANDBY"

### ✅ Test 3: Manual Failback
- Scale down secondary region to 0 instances
- Scale up primary region to 2 instances
- Traffic returns to ap-south-1, showing "STATUS: ACTIVE"

## 🌐 Test URLs

After setup, test these URLs:

- **Primary**: `http://arc-test-alb-ap-south-1-*.ap-south-1.elb.amazonaws.com`
- **Secondary**: `http://arc-test-alb-ap-south-2-*.ap-south-2.elb.amazonaws.com`

## 📁 Files Overview

| File | Purpose |
|------|---------|
| `run-arc-test.sh` | Master script - runs complete setup |
| `arc-test-setup.sh` | Creates VPC and networking infrastructure |
| `arc-app-setup.sh` | Deploys ALB, ASG, and EC2 instances |
| `arc-region-switch-setup.sh` | Configures ARC components |
| `arc-test-execution.sh` | Test and monitor script |
| `arc-cleanup.sh` | Removes all created resources |
| `arc-test-summary.md` | Detailed test results and next steps |

## 🔧 Manual ARC Plan Creation

After running the setup, create the ARC Region Switch plan manually:

1. **Go to AWS Console** → Application Recovery Controller → Region switch
2. **Click "Create Region switch plan"**
3. **Configure**:
   - Name: `arc-test-plan`
   - Approach: `Active/passive`
   - Primary Region: `ap-south-1`
   - Standby Region: `ap-south-2`
   - RTO: `300 seconds`
   - IAM Role: `arn:aws:iam::YOUR-ACCOUNT:role/ARC-RegionSwitch-TestRole`
   - Health Alarms: `arc-test-health-primary`, `arc-test-health-secondary`

4. **Add Workflows** with execution blocks:
   - EC2 Auto Scaling Group blocks for both regions
   - Configure graceful/ungraceful execution modes

5. **Test in Practice Mode** first, then Recovery Mode

## 📊 Architecture Diagrams

Generated diagrams available in `generated-diagrams/`:

- `arc-region-switch-simple.png` - Basic architecture overview
- `arc-failover-process.png` - Failover process flow
- `arc-complete-architecture.png` - Comprehensive architecture
- `arc-test-results.png` - Test execution results

## 🔍 Monitoring & Verification

### Check Auto Scaling Groups
```bash
# Primary region
aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names arc-test-asg-ap-south-1 \
    --region ap-south-1

# Secondary region
aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names arc-test-asg-ap-south-2 \
    --region ap-south-2
```

### Check Load Balancer Health
```bash
# Primary ALB targets
aws elbv2 describe-target-health \
    --target-group-arn $(aws elbv2 describe-target-groups \
        --names arc-test-tg-ap-south-1 \
        --region ap-south-1 \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text) \
    --region ap-south-1
```

### Test Web Connectivity
```bash
# Test primary region
curl http://arc-test-alb-ap-south-1-*.ap-south-1.elb.amazonaws.com

# Test secondary region
curl http://arc-test-alb-ap-south-2-*.ap-south-2.elb.amazonaws.com
```

## 💰 Cost Considerations

- **EC2 instances**: t3.micro (free tier eligible)
- **Application Load Balancers**: ~$16/month per ALB when active
- **Data transfer**: Minimal for testing
- **ARC Region Switch**: No additional charges

**⚠️ Important**: Run `./arc-cleanup.sh` when testing is complete to avoid ongoing charges!

## 🛠️ Troubleshooting

### Common Issues

1. **Instances not launching**: Check security groups and subnet configuration
2. **Health checks failing**: Verify security group allows port 80
3. **ALB not accessible**: Ensure internet gateway and route tables are configured
4. **ARC permissions**: Verify IAM role has necessary permissions

### Debug Commands
```bash
# Check instance status
aws ec2 describe-instances --region ap-south-1 \
    --filters "Name=tag:Name,Values=arc-test-instance-*"

# Check ALB status
aws elbv2 describe-load-balancers --region ap-south-1 \
    --names arc-test-alb-ap-south-1

# Check CloudWatch alarms
aws cloudwatch describe-alarms --region ap-south-1 \
    --alarm-names arc-test-health-primary
```

## 🎉 Success Criteria

✅ **All tests passed successfully!**

- Primary region serves traffic normally
- Manual failover redirects traffic to secondary region
- Manual failback restores traffic to primary region
- Web pages show correct region status
- Health checks monitor ALB status
- ARC components are properly configured

## 📚 Next Steps

1. **Create ARC Region Switch Plan** through AWS Console
2. **Test Practice Mode** execution
3. **Configure automated triggers** with CloudWatch alarms
4. **Implement DNS failover** with Route 53 weighted routing
5. **Add more execution blocks** (RDS, Lambda, etc.)
6. **Set up cross-region monitoring** dashboards

## 🔗 Useful Links

- [AWS Application Recovery Controller Documentation](https://docs.aws.amazon.com/r53recovery/)
- [Region Switch User Guide](https://docs.aws.amazon.com/r53recovery/latest/dg/region-switch.html)
- [ARC Best Practices](https://docs.aws.amazon.com/r53recovery/latest/dg/best-practices.region-switch.html)

---

**Happy Testing!** 🎯

For questions or issues, refer to the detailed test summary in `arc-test-summary.md`.