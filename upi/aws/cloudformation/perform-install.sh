#!/usr/bin/env sh

## Prereqs:
# - aws (brew install awscli)
# - yq (brew install yq)
# - jq (brew install jq)
# - openshift-install (Found at https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/)

set -e

# Configurable defaults
: ${DIR:="upi"}
: ${REGION:="us-east-2"}
: ${BUCKET:="gisjedi-test-network-security"}
: ${PUBLIC_KEY:="$(cat $HOME/.ssh/id_rsa.pub)"}
: ${HOSTED_ZONE_NAME:="openshift.gisjedi.com"}
: ${WORKER_COUNT:=3}

# Unset required values
if [[ "${PULL_SECRET}x" == "x" ]]
then
    echo Missing PULL_SECRET environment variable!
    echo This value can be found at https://cloud.redhat.com/openshift/install/aws/installer-provisioned
    exit 1
fi
HOSTED_ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name $HOSTED_ZONE_NAME | jq '.HostedZones[0].Id' -r | cut -d/ -f3)"

# Generate initial configs (can be done interactively by openshift-install create install-config --dir=$DIR)
mkdir -p $DIR
cat templates/install-config.yaml \
    | yq w - baseDomain $HOSTED_ZONE_NAME \
    | yq w - platform.aws.region $REGION \
    | yq w - metadata.name $DIR \
    | yq w - sshKey "$PUBLIC_KEY" \
    | yq w - pullSecret $PULL_SECRET > $DIR/install-config.yaml

# Generate K8s manifests and ignition
openshift-install create manifests --dir=$DIR

# Removing K8s operators for Master and Worker machines, we are creating them with CF stacks
rm -f $DIR/openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -f $DIR/openshift/99_openshift-cluster-api_worker-machineset-*.yaml

# Patch for router Pods failing to run on Master machines since is not reachable by the ingress load balancer.
yq w -i $DIR/manifests/cluster-scheduler-02-config.yml spec.mastersSchedulable false

# Create ignition configs from the K8s manifests
openshift-install create ignition-configs --dir=$DIR

# Copy bootstrap ignition to bucket
aws s3 mb s3://$BUCKET --region $REGION || true
aws s3 cp $DIR/bootstrap.ign s3://$BUCKET/$DIR/bootstrap.ign

# Grab auto-generated infrastructure name 
export INF_NAME=$(jq -r .infraID $DIR/metadata.json)

# Deploy VPC stack
aws cloudformation create-stack --stack-name $INF_NAME-vpc --template-body file://01_vpc.yaml --parameters file://templates/01.json || true
sh scripts/stack-wait.sh $INF_NAME-vpc

OUTPUTS="$(aws cloudformation describe-stacks --stack-name $INF_NAME-vpc | jq '.Stacks[].Outputs[]' -r)"

PUBLIC_SUBNET_IDS="$(sh scripts/cf-output.sh $INF_NAME-vpc PublicSubnetIds)"
PRIVATE_SUBNET_IDS="$(sh scripts/cf-output.sh $INF_NAME-vpc PrivateSubnetIds)"
VPC_ID="$(sh scripts/cf-output.sh $INF_NAME-vpc VpcId)"

cat templates/02.json | jq 'map((select(.ParameterKey == "InfrastructureName") | .ParameterValue) |= "'$(echo $INF_NAME)'")' > $DIR/02.json

# Deploy infrastructure and security stacks
aws cloudformation create-stack --stack-name $INF_NAME-iam --template-body file://02_iam.yaml --parameters file://$DIR/02.json --capabilities CAPABILITY_NAMED_IAM || true
sh scripts/stack-wait.sh $INF_NAME-iam

cat templates/03.json | jq 'map((select(.ParameterKey == "ClusterName") | .ParameterValue) |= "'$(echo $DIR)'")' \
| jq 'map((select(.ParameterKey == "InfrastructureName") | .ParameterValue) |= "'$(echo $INF_NAME)'")' \
| jq 'map((select(.ParameterKey == "HostedZoneId") | .ParameterValue) |= "'$(echo $HOSTED_ZONE_ID)'")' \
| jq 'map((select(.ParameterKey == "HostedZoneName") | .ParameterValue) |= "'$(echo $HOSTED_ZONE_NAME)'")' \
| jq 'map((select(.ParameterKey == "PublicSubnets") | .ParameterValue) |= "'$(echo $PUBLIC_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "PrivateSubnets") | .ParameterValue) |= "'$(echo $PRIVATE_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "VpcId") | .ParameterValue) |= "'$(echo $VPC_ID)'")' \
| jq 'map((select(.ParameterKey == "RegisterTargetLambdaIamRoleArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-iam RegisterTargetLambdaIamRoleArn)'")' \
| jq 'map((select(.ParameterKey == "RegisterSubnetTagsLambdaIamRoleArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-iam RegisterSubnetTagsLambdaIamRoleArn)'")' > $DIR/03.json

aws cloudformation create-stack --stack-name $INF_NAME-network-security --template-body file://03_cluster_network_security.yaml --parameters file://$DIR/03.json || true
sh scripts/stack-wait.sh $INF_NAME-network-security

cat templates/04.json | jq 'map((select(.ParameterKey == "InfrastructureName") | .ParameterValue) |= "'$(echo $INF_NAME)'")' \
| jq 'map((select(.ParameterKey == "PublicSubnet") | .ParameterValue) |= "'$(echo $PUBLIC_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "MasterSecurityGroupId") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-network-security MasterSecurityGroupId)'")' \
| jq 'map((select(.ParameterKey == "VpcId") | .ParameterValue) |= "'$(echo $VPC_ID)'")' \
| jq 'map((select(.ParameterKey == "BootstrapInstanceProfileName") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-iam BootstrapInstanceProfile)'")' \
| jq 'map((select(.ParameterKey == "BootstrapIgnitionLocation") | .ParameterValue) |= "'$(echo s3://$BUCKET/$DIR/bootstrap.ign)'")' \
| jq 'map((select(.ParameterKey == "RegisterNlbIpTargetsLambdaArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-network-security RegisterNlbIpTargetsLambda)'")' \
| jq 'map((select(.ParameterKey == "ExternalApiTargetGroupArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-network-security ExternalApiTargetGroupArn)'")' \
| jq 'map((select(.ParameterKey == "InternalApiTargetGroupArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-network-security InternalApiTargetGroupArn)'")' \
| jq 'map((select(.ParameterKey == "InternalServiceTargetGroupArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-network-security InternalServiceTargetGroupArn)'")' > $DIR/04.json

# Create bootstrap node and wait for it to be fully initialized
aws cloudformation create-stack --stack-name $INF_NAME-bootstrap --template-body file://04_cluster_bootstrap.yaml --parameters file://$DIR/04.json || true
sh scripts/stack-wait.sh $INF_NAME-bootstrap

# Populate master nodes with needed config from upstream stacks
cat templates/05.json | jq 'map((select(.ParameterKey == "InfrastructureName") | .ParameterValue) |= "'$(echo $INF_NAME)'")' \
| jq 'map((select(.ParameterKey == "PublicSubnet") | .ParameterValue) |= "'$(echo $PUBLIC_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "PrivateHostedZoneId") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-network-security PrivateHostedZoneId)'")' \
| jq 'map((select(.ParameterKey == "PrivateHostedZoneName") | .ParameterValue) |= "'$(echo $DIR.$HOSTED_ZONE_NAME)'")' \
| jq 'map((select(.ParameterKey == "Master0Subnet") | .ParameterValue) |= "'$(echo $PRIVATE_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "Master1Subnet") | .ParameterValue) |= "'$(echo $PRIVATE_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "Master2Subnet") | .ParameterValue) |= "'$(echo $PRIVATE_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "MasterSecurityGroupId") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-network-security MasterSecurityGroupId)'")' \
| jq 'map((select(.ParameterKey == "IgnitionLocation") | .ParameterValue) |= "'$(echo "https://api-int.$DIR.$HOSTED_ZONE_NAME:22623/config/master")'")' \
| jq 'map((select(.ParameterKey == "CertificateAuthorities") | .ParameterValue) |= "'$(jq '.ignition.security.tls.certificateAuthorities[].source' -r $DIR/master.ign)'")' \
| jq 'map((select(.ParameterKey == "MasterInstanceProfileName") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-iam MasterInstanceProfile)'")' \
| jq 'map((select(.ParameterKey == "RegisterNlbIpTargetsLambdaArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-network-security RegisterNlbIpTargetsLambda)'")' \
| jq 'map((select(.ParameterKey == "ExternalApiTargetGroupArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-network-security ExternalApiTargetGroupArn)'")' \
| jq 'map((select(.ParameterKey == "InternalApiTargetGroupArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-network-security InternalApiTargetGroupArn)'")' \
| jq 'map((select(.ParameterKey == "InternalServiceTargetGroupArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-network-security InternalServiceTargetGroupArn)'")' > $DIR/05.json

# Populate worker nodes with needed config from upstream stacks
cat templates/06.json | jq 'map((select(.ParameterKey == "InfrastructureName") | .ParameterValue) |= "'$(echo $INF_NAME)'")' \
| jq 'map((select(.ParameterKey == "Subnet") | .ParameterValue) |= "'$(echo $PRIVATE_SUBNET_IDS)'")' \
| jq 'map((select(.ParameterKey == "WorkerSecurityGroupId") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-network-security WorkerSecurityGroupId)'")' \
| jq 'map((select(.ParameterKey == "IgnitionLocation") | .ParameterValue) |= "'$(echo "https://api-int.$DIR.$HOSTED_ZONE_NAME:22623/config/worker")'")' \
| jq 'map((select(.ParameterKey == "CertificateAuthorities") | .ParameterValue) |= "'$(jq '.ignition.security.tls.certificateAuthorities[].source' -r $DIR/worker.ign)'")' \
| jq 'map((select(.ParameterKey == "WorkerInstanceProfileName") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-iam WorkerInstanceProfile)'")' \
| jq 'map((select(.ParameterKey == "RegisterNlbIpTargetsLambdaArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-network-security RegisterNlbIpTargetsLambda)'")' \
| jq 'map((select(.ParameterKey == "ExternalApiTargetGroupArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-network-security ExternalApiTargetGroupArn)'")' \
| jq 'map((select(.ParameterKey == "InternalApiTargetGroupArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-network-security InternalApiTargetGroupArn)'")' \
| jq 'map((select(.ParameterKey == "InternalServiceTargetGroupArn") | .ParameterValue) |= "'$(sh scripts/cf-output.sh $INF_NAME-network-security InternalServiceTargetGroupArn)'")' > $DIR/06.json

# Create master nodes
aws cloudformation create-stack --stack-name $INF_NAME-master --template-body file://05_cluster_master_nodes.yaml --parameters file://$DIR/05.json

# Create worker nodes
for WORKER_ID in $(seq 1 $WORKER_COUNT)
do
    aws cloudformation create-stack --stack-name $INF_NAME-worker-$WORKER_ID --template-body file://06_cluster_worker_node.yaml --parameters file://$DIR/06.json
done

sh scripts/stack-wait.sh $INF_NAME-master
for WORKER_ID in $(seq 1 $WORKER_COUNT); do sh scripts/stack-wait.sh $INF_NAME-worker-$WORKER_ID; done

# Validate that bootstrap and install are complete
openshift-install wait-for bootstrap-complete --dir=$DIR --log-level=info 
openshift-install wait-for install-complete --dir=$DIR --log-level=info 
