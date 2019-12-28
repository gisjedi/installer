#!/usr/bin/env sh

# Description: Extract an output value by key from successful CloudFormation stack

STACK=$1
OUTPUT_KEY=$2

aws cloudformation describe-stacks --stack-name $STACK --query "Stacks[0].Outputs[?OutputKey=='${OUTPUT_KEY}'].OutputValue" --output text