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

export DIR="upi"
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

# Grab auto-generated infrastructure name 
export INF_NAME=$(jq -r .infraID $DIR/metadata.json)

aws cloudformation create-stack --stack-name $INF_NAME-vpc --template-body file://01_vpc.yaml --parameters file://01.json 
sh stack-wait.sh $INF_NAME-vpc

aws cloudformation describe-stacks --stack-name $STACK | jq '.Stacks[].Outputs[] | select(.OutputKey=="PrivateSubnetIds") | .OutputValue' -r

PUBLIC_SUBNET_IDS="$(aws cloudformation describe-stacks --stack-name $STACK | jq '.Stacks[].Outputs[] | select(.OutputKey=="PublicSubnetIds") | .OutputValue' -r)"
PRIVATE_SUBNET_IDS="$(aws cloudformation describe-stacks --stack-name $STACK | jq '.Stacks[].Outputs[] | select(.OutputKey=="PrivateSubnetIds") | .OutputValue' -r)"
VPC_ID="$(aws cloudformation describe-stacks --stack-name $STACK | jq '.Stacks[].Outputs[] | select(.OutputKey=="VpcId") | .OutputValue' -r)"

cat 02.json | jq 'map((select(.ParameterKey == "ClusterName") | .ParameterValue) |= "'$(echo $DIR)'")' \
| jq 'map((select(.ParameterKey == "InfrastructureName") | .ParameterValue) |= "'$(echo $INF_NAME)'")' \
| jq 'map((select(.ParameterKey == "HostedZoneId") | .ParameterValue) |= "'$(echo $HOSTED_ZONE_ID)'")' \
| jq 'map((select(.ParameterKey == "HostedZoneName") | .ParameterValue) |= "'$(echo $HOSTED_ZONE_NAME)'")' \
| jq 'map((select(.ParameterKey == "PublicSubnets") | .ParameterValue) |= "'$(echo $PUBLIC_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "PrivateSubnets") | .ParameterValue) |= "'$(echo $PRIVATE_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "VpcId") | .ParameterValue) |= "'$(echo $VPC_ID)'")' > 02.populated.json




