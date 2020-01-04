#!/usr/bin/env sh

## Prereqs:
# - aws (brew install awscli)

set -e

# Configurable defaults
: ${DIR:="upi"}
: ${HOSTED_ZONE_NAME:="openshift.gisjedi.com"}
: ${WORKER_COUNT:=3}

# Grab auto-generated infrastructure name 
export INF_NAME=$(jq -r .infraID $DIR/metadata.json)

# Cleanup generated installer info
[ -d "$DIR" ] && rm -fr $DIR

# Cleanup nodes
aws cloudformation delete-stack --stack-name $INF_NAME-master
aws cloudformation delete-stack --stack-name $INF_NAME-bootstrap
for WORKER_ID in $(seq 1 $WORKER_COUNT)
do
    aws cloudformation delete-stack --stack-name $INF_NAME-worker-$WORKER_ID
done

sh scripts/delete-wait.sh $INF_NAME-master
sh scripts/delete-wait.sh $INF_NAME-bootstrap
for WORKER_ID in $(seq 1 $WORKER_COUNT); do sh scripts/delete-wait.sh $INF_NAME-worker-$WORKER_ID; done

# Cleanup dynamically generated componments
aws elb delete-load-balancer --load-balancer-name $(aws resourcegroupstaggingapi get-resources --tag-filters Key=kubernetes.io/cluster/nodes-qsfw4,Values=owned --resource-type-filters elasticloadbalancing | jq '.ResourceTagMappingList[].ResourceARN' -r | cut -d/ -f2)
sh scripts/delete-route53-records.sh $HOSTED_ZONE_NAME
sh scripts/delete-route53-records.sh nodes-$HOSTED_ZONE_NAME true

# Remove all virtual network components
aws cloudformation delete-stack --stack-name $INF_NAME-network-security
aws cloudformation delete-stack --stack-name $INF_NAME-iam
aws cloudformation delete-stack --stack-name $INF_NAME-vpc

sh scripts/delete-wait.sh $INF_NAME-iam
sh scripts/delete-wait.sh $INF_NAME-network-security
sh scripts/delete-wait.sh $INF_NAME-vpc