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