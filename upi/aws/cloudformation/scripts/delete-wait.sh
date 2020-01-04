#!/usr/bin/env sh

# Description: Block in steps of 10 seconds until a CloudFormation stack has deleted.

STACK=$1
SLEEP_TIME=10
BLOCKED_VAL='DELETE_IN_PROGRESS'
SUCCESS_VAL='DELETE_COMPLETE'

while $(aws cloudformation list-stacks --stack-status-filter $BLOCKED_VAL | jq '.StackSummaries[].StackName' | grep $STACK > /dev/null) 
do
    sleep $SLEEP_TIME
    echo "Waiting $SLEEP_TIME seconds for stack $STACK to delete..."
done

if $(aws cloudformation list-stacks --stack-status-filter $SUCCESS_VAL | jq '.StackSummaries[].StackName' | grep $STACK > /dev/null)
then
    echo "Stack $STACK deletion completed."
else
    echo "Stack $STACK delete failed."
    exit 1
fi

