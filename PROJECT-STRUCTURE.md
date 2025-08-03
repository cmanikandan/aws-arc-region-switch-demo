# AWS ARC Region Switch Demo - Project Structure

## 📁 Directory Overview

```
aws-arc-region-switch-demo/
├── README.md                      # Main documentation and quick start guide
├── PROJECT-STRUCTURE.md           # This file - project organization
├── arc-test-summary.md            # Detailed test results and next steps
│
├── 🚀 EXECUTION SCRIPTS
├── run-arc-test.sh                # Master script - runs complete setup
├── arc-test-execution.sh          # Test and monitor script
├── arc-cleanup.sh                 # Removes all created resources
│
├── 🏗️ SETUP SCRIPTS
├── arc-test-setup.sh              # Creates VPC and networking infrastructure
├── arc-app-setup.sh               # Deploys ALB, ASG, and EC2 instances
├── arc-region-switch-setup.sh     # Configures ARC components
│
└── 📊 ARCHITECTURE DIAGRAMS
    └── generated-diagrams/
        ├── arc-region-switch-simple.png      # Basic architecture overview
        ├── arc-failover-process.png          # Failover process flow
        ├── arc-complete-architecture.png     # Comprehensive architecture
        └── arc-test-results.png              # Test execution results
```

## 🎯 File Purposes

### **Core Documentation**
- **README.md**: Complete setup and usage instructions
- **arc-test-summary.md**: Detailed test results and ARC plan creation steps
- **PROJECT-STRUCTURE.md**: This file explaining project organization

### **Execution Scripts**
- **run-arc-test.sh**: Master script that orchestrates the entire setup
- **arc-test-execution.sh**: Monitor status and execute manual failover/failback
- **arc-cleanup.sh**: Clean removal of all AWS resources

### **Infrastructure Setup Scripts**
- **arc-test-setup.sh**: Creates VPCs, subnets, security groups, key pairs
- **arc-app-setup.sh**: Deploys ALBs, Auto Scaling Groups, EC2 instances
- **arc-region-switch-setup.sh**: Sets up IAM roles, CloudWatch alarms, Route 53

### **Visual Documentation**
- **arc-region-switch-simple.png**: Clean overview of the architecture
- **arc-failover-process.png**: Before/after states during failover
- **arc-complete-architecture.png**: Detailed view of all components
- **arc-test-results.png**: Visual summary of test execution phases

## 🚀 Quick Usage

1. **Complete Setup**: `./run-arc-test.sh`
2. **Check Status**: `./arc-test-execution.sh`
3. **Test Failover**: `./arc-test-execution.sh failover`
4. **Test Failback**: `./arc-test-execution.sh failback`
5. **Clean Up**: `./arc-cleanup.sh`

## 📋 Prerequisites

- AWS CLI configured with appropriate permissions
- Access to ap-south-1 and ap-south-2 regions
- Permissions for EC2, ELB, Auto Scaling, IAM, CloudWatch, Route 53

## 🎉 What This Demo Proves

✅ **AWS Application Recovery Controller Region Switch works seamlessly**
✅ **Multi-region failover can be orchestrated automatically**
✅ **Infrastructure as Code approach is reliable and repeatable**
✅ **Cross-region disaster recovery is achievable with minimal complexity**

---

**Ready to test AWS ARC Region Switch? Start with `./run-arc-test.sh`!** 🚀