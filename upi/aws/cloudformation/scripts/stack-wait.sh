#!/usr/bin/env sh

# Description: Block in steps of 10 seconds until a CloudFormation stack has completed.

STACK=$1
SLEEP_TIME=10
BLOCKED_VAL='CREATE_IN_PROGRESS'
SUCCESS_VAL='CREATE_COMPLETE'
while [ "$(aws cloudformation describe-stacks --stack-name $STACK | jq '.Stacks[].StackStatus' -r)" == "$BLOCKED_VAL" ]
do
    sleep $SLEEP_TIME
    echo "Waiting $SLEEP_TIME seconds for stack $STACK to complete..."
done

if [ "$(aws cloudformation describe-stacks --stack-name $STACK | jq '.Stacks[].StackStatus' -r)" != "$SUCCESS_VAL" ]
then
    echo "Stack $STACK creation failed."
    exit 1
fi

echo "Stack $STACK creation completed."