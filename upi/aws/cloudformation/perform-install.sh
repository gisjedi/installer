#!/usr/bin/env sh

## Prereqs:
# - aws (brew install awscli)
# - yq (brew install yq)
# - jq (brew install jq)
# - openshift-install (Found at https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/)

set -e

wait_for_stack_complete()
{
    STACK=$1
    SLEEP_TIME=5
    BLOCKED_VAL = 'CREATE_IN_PROGRESS'
    SUCCESS_VAL = 'CREATE_COMPLETE'
    while [ "$(aws cloudformation describe-stacks --stack-name $STACK | jq '.Stacks[].StackStatus')" == "$BLOCKED_VAL" ]
    do
        sleep $SLEEP_TIME
        echo "Waiting $SLEEP_TIME seconds for stack $STACK to complete..."
    done

    if [ "$(aws cloudformation describe-stacks --stack-name $STACK | jq '.Stacks[].StackStatus')" != "$SUCCESS_VAL" ]
    then
        echo "Stack $STACK creation failed."
        exit 1
    fi
}

# Clean up any populated files from previous runs:
rm -f *.populated.json

export DIR="upi"
export BUCKET="gisjedi-test-infra"
export HOSTED_ZONE_NAME="openshift.gisjedi.com"
export HOSTED_ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name openshift.gisjedi.com | jq '.HostedZones[].Id' -r | cut -d/ -f3)"

# Generate initial configs
./openshift-install create install-config --dir=$DIR

# Clean up for UPI
yq w -i $DIR/install-config.yaml 'compute[*].replicas' 0
 
# Generate K8s manifests and ignition
./openshift-install create manifests --dir=$DIR

# Removing K8s operators for ControlPlane and Workers, we are doing that with CF stacks
rm -f $DIR/openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -f $DIR/openshift/99_openshift-cluster-api_worker-machineset-*.yaml

# Patch for router Pods failing to run on control plane machines will not be reachable by the ingress load balancer.
yq w -i $DIR/manifests/cluster-scheduler-02-config.yml spec.mastersSchedulable false

# Create ignition configs from the K8s manifests
./openshift-install create ignition-configs --dir=$DIR

# Copy bootstrap ignition to bucket
aws s3 cp $DIR/bootstrap.ign s3://$BUCKET/$DIR/bootstrap.ign

# Grab auto-generated infrastructure name 
export INF_NAME=$(jq -r .infraID $DIR/metadata.json)

# Deploy VPC stack
aws cloudformation create-stack --stack-name $INF_NAME-vpc --template-body file://01_vpc.yaml --parameters file://01.json
sh scripts/stack-wait.sh $INF_NAME-vpc

OUTPUTS="$(aws cloudformation describe-stacks --stack-name $INF_NAME-vpc | jq '.Stacks[].Outputs[]' -r)"

PUBLIC_SUBNET_IDS="$(sh scripts/cf-output.sh $INF_NAME-vpc PublicSubnetIds)"
PRIVATE_SUBNET_IDS="$(sh scripts/cf-output.sh $INF_NAME-vpc PrivateSubnetIds)"
VPC_ID="$(sh scripts/cf-output.sh $INF_NAME-vpc VpcId)"

cat 02.json | jq 'map((select(.ParameterKey == "ClusterName") | .ParameterValue) |= "'$(echo $DIR)'")' \
| jq 'map((select(.ParameterKey == "InfrastructureName") | .ParameterValue) |= "'$(echo $INF_NAME)'")' \
| jq 'map((select(.ParameterKey == "HostedZoneId") | .ParameterValue) |= "'$(echo $HOSTED_ZONE_ID)'")' \
| jq 'map((select(.ParameterKey == "HostedZoneName") | .ParameterValue) |= "'$(echo $HOSTED_ZONE_NAME)'")' \
| jq 'map((select(.ParameterKey == "PublicSubnets") | .ParameterValue) |= "'$(echo $PUBLIC_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "PrivateSubnets") | .ParameterValue) |= "'$(echo $PRIVATE_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "VpcId") | .ParameterValue) |= "'$(echo $VPC_ID)'")' > 02.populated.json

cat 03.json | jq 'map((select(.ParameterKey == "InfrastructureName") | .ParameterValue) |= "'$(echo $INF_NAME)'")' \
| jq 'map((select(.ParameterKey == "PrivateSubnets") | .ParameterValue) |= "'$(echo $PRIVATE_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "VpcId") | .ParameterValue) |= "'$(echo $VPC_ID)'")' > 03.populated.json

# Deploy infrastructure and security stacks
aws cloudformation create-stack --stack-name $INF_NAME-infra --template-body file://02_cluster_infra.yaml --parameters file://02.populated.json --capabilities CAPABILITY_NAMED_IAM
aws cloudformation create-stack --stack-name $INF_NAME-security --template-body file://03_cluster_security.yaml --parameters file://03.populated.json --capabilities CAPABILITY_IAM
sh scripts/stack-wait.sh $INF_NAME-infra
sh scripts/stack-wait.sh $INF_NAME-security

cat 04.json | jq 'map((select(.ParameterKey == "InfrastructureName") | .ParameterValue) |= "'$(echo $INF_NAME)'")' \
| jq 'map((select(.ParameterKey == "PublicSubnet") | .ParameterValue) |= "'$(echo $PUBLIC_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "MasterSecurityGroupId") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-security MasterSecurityGroupId)'")' \
| jq 'map((select(.ParameterKey == "VpcId") | .ParameterValue) |= "'$(echo $VPC_ID)'")' \
| jq 'map((select(.ParameterKey == "BootstrapIgnitionLocation") | .ParameterValue) |= "'$(echo s3://$BUCKET/$DIR/bootstrap.ign)'")' \
| jq 'map((select(.ParameterKey == "RegisterNlbIpTargetsLambdaArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-infra RegisterNlbIpTargetsLambda)'")' \
| jq 'map((select(.ParameterKey == "ExternalApiTargetGroupArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-infra ExternalApiTargetGroupArn)'")' \
| jq 'map((select(.ParameterKey == "InternalApiTargetGroupArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-infra InternalApiTargetGroupArn)'")' \
| jq 'map((select(.ParameterKey == "InternalServiceTargetGroupArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-infra InternalServiceTargetGroupArn)'")' > 04.populated.json

# Create bootstrap node and wait for it to be fully initialized
aws cloudformation create-stack --stack-name $INF_NAME-bootstrap --template-body file://04_cluster_security.yaml --parameters file://04.populated.json --capabilities CAPABILITY_IAM
sh scripts/stack-wait.sh $INF_NAME-boostrap

# Populate master nodes with needed config from upstream stacks
cat 05.json | jq 'map((select(.ParameterKey == "InfrastructureName") | .ParameterValue) |= "'$(echo $INF_NAME)'")' \
| jq 'map((select(.ParameterKey == "PublicSubnet") | .ParameterValue) |= "'$(echo $PUBLIC_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "PrivateHostedZoneId") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-infra PrivateHostedZoneId)'")' \
| jq 'map((select(.ParameterKey == "PrivateHostedZoneName") | .ParameterValue) |= "'$(echo $DIR.$HOSTED_ZONE_NAME)'")' \
| jq 'map((select(.ParameterKey == "Master0Subnet") | .ParameterValue) |= "'$(echo $PRIVATE_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "Master1Subnet") | .ParameterValue) |= "'$(echo $PRIVATE_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "Master2Subnet") | .ParameterValue) |= "'$(echo $PRIVATE_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "MasterSecurityGroupId") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-security MasterSecurityGroupId)'")' \
| jq 'map((select(.ParameterKey == "IgnitionLocation") | .ParameterValue) |= "'$(echo "https://api-int.$DIR.$HOSTED_ZONE_NAME:22623/config/master")'")' \
| jq 'map((select(.ParameterKey == "CertificateAuthorities") | .ParameterValue) |= "'$(jq '.ignition.security.tls.certificateAuthorities[].source' -r $DIR/master.ign)'")' \
| jq 'map((select(.ParameterKey == "MasterInstanceProfileName") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-security MasterInstanceProfileName)'")' \
| jq 'map((select(.ParameterKey == "RegisterNlbIpTargetsLambdaArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-infra RegisterNlbIpTargetsLambda)'")' \
| jq 'map((select(.ParameterKey == "ExternalApiTargetGroupArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-infra ExternalApiTargetGroupArn)'")' \
| jq 'map((select(.ParameterKey == "InternalApiTargetGroupArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-infra InternalApiTargetGroupArn)'")' \
| jq 'map((select(.ParameterKey == "InternalServiceTargetGroupArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-infra InternalServiceTargetGroupArn)'")' > 05.populated.json

# Populate worker nodes with needed config from upstream stacks
cat 06.json | jq 'map((select(.ParameterKey == "InfrastructureName") | .ParameterValue) |= "'$(echo $INF_NAME)'")' \
| jq 'map((select(.ParameterKey == "Subnet") | .ParameterValue) |= "'$(echo $PRIVATE_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "WorkerSecurityGroupId") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-security WorkerSecurityGroupId)'")' \
| jq 'map((select(.ParameterKey == "IgnitionLocation") | .ParameterValue) |= "'$(echo "https://api-int.$DIR.$HOSTED_ZONE_NAME:22623/config/worker")'")' \
| jq 'map((select(.ParameterKey == "CertificateAuthorities") | .ParameterValue) |= "'$(jq '.ignition.security.tls.certificateAuthorities[].source' -r $DIR/worker.ign)'")' \
| jq 'map((select(.ParameterKey == "WorkerInstanceProfileName") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-security WorkerInstanceProfile)'")' \
| jq 'map((select(.ParameterKey == "RegisterNlbIpTargetsLambdaArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-infra RegisterNlbIpTargetsLambda)'")' \
| jq 'map((select(.ParameterKey == "ExternalApiTargetGroupArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-infra ExternalApiTargetGroupArn)'")' \
| jq 'map((select(.ParameterKey == "InternalApiTargetGroupArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-infra InternalApiTargetGroupArn)'")' \
| jq 'map((select(.ParameterKey == "InternalServiceTargetGroupArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-infra InternalServiceTargetGroupArn)'")' > 06.populated.json


# Create master nodes
aws cloudformation create-stack --stack-name $INF_NAME-master --template-body file://05_cluster_master_nodes.yaml --parameters file://05.populated.json

# Create work nodes
aws cloudformation create-stack --stack-name $INF_NAME-worker --template-body file://06_cluster_worker_node.yaml --parameters file://06.populated.json

sh scripts/stack-wait.sh $INF_NAME-master
sh scripts/stack-wait.sh $INF_NAME-worker
