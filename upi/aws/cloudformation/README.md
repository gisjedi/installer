# Automated UPI install
I've created a script that distills the knowledge from https://docs.openshift.com/container-platform/4.2/installing/installing_restricted_networks/installing-restricted-networks-aws.html with a self-contained installation script. The `perform-install.sh` script can be found within the current directory of the repository. There are some basic prerequisites that must be in place to use.

## Prequisites

These prequisite CLI tools are necessary to leverage the automated script. They must be installed globally in your environment.

* aws (brew install awscli)
* yq (brew install yq)
* jq (brew install jq)
* openshift-install (Found at https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/)
  
You must also pre-configure 3 things prior to launching the script:

* Login credentials for AWS capable of full administrator access (accomplished with `aws configure`)
* `HOSTED_ZONE_NAME` environment variable. This must match the name of a Route53 Hosted Zone in your account.
* `PULL_SECRET` environment variable. This can be retreived from https://cloud.redhat.com/openshift/install/aws/installer-provisioned

Additional optional environment variables can be set and are documented within the `perform-install.sh` file.

## Install

Once the prerequisites above have been addressed, the following command is all that's needed:

```
sh perform-install.sh
```

This will run for ~20-30 minutes to fully complete the install. You can track initialization using the following commands:

```
# Replace upi with the appropriate value, if you used a custom cluster name
export KUBECONFIG=$(pwd)/upi/auth/kubeconfig

# Watch ClusterOperator status initialize
watch -n5 oc get clusteroperators

# Watch Master and Worker nodes status
watch -n5 oc get nodes
```

## Notes

I've been able to use this to consistently create an OpenShift cluster when `WORKER_COUNT` is set to 3. Any less and I've never been able to get a final working cluster - the docs claim a min of 2 worker nodes for functional ingress. I've also noticed that trying to create additional worker nodes after the initial set fails.

