#!/usr/bin/env sh

# Description: Drops all records from a Route 53 zone, optionally deletes zone too if second parameter equals 'true'

HOSTED_ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name $1 | jq '.HostedZones[0].Id' -r | cut -d/ -f3)"
DELETE=${2:-false}

aws route53 list-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID |
jq -c '.ResourceRecordSets[]' |
while read -r resourcerecordset; do
  read -r name type <<<$(echo $(jq -r '.Name,.Type' <<<"$resourcerecordset"))
  if [ $type != "NS" -a $type != "SOA" ]; then
    aws route53 change-resource-record-sets \
      --hosted-zone-id $HOSTED_ZONE_ID \
      --change-batch '{"Changes":[{"Action":"DELETE","ResourceRecordSet":
          '"$resourcerecordset"'
        }]}' \
      --output text --query 'ChangeInfo.Id'
  fi
done

if [ "$DELETE" == "true" ]
then
    aws route53 delete-hosted-zone --id $HOSTED_ZONE_ID
fi