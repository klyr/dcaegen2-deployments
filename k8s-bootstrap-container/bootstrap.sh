#!/bin/bash
# ================================================================================
# Copyright (c) 2018 AT&T Intellectual Property. All rights reserved.
# ================================================================================
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ============LICENSE_END=========================================================

# Install DCAE via Cloudify Manager
# Expects:
#   CM address (IP or DNS) in CMADDR environment variable
#   CM password in CMPASS environment variable (assumes user is "admin")
#   ONAP common Kubernetes namespace in ONAP_NAMESPACE environment variable
#   If DCAE components are deployed in a separate Kubernetes namespace, that namespace in DCAE_NAMESPACE variable.
#   Consul address with port in CONSUL variable
#   Plugin wagon files in /wagons
# 	Blueprints for components to be installed in /blueprints
#   Input files for components to be installed in /inputs
#   Configuration JSON files that need to be loaded into Consul in /dcae-configs
#   Consul is installed in /opt/consul/bin/consul, with base config in /opt/consul/config/00consul.json

### FUNCTION DEFINITIONS ###

# keep_running: Keep running after bootstrap finishes or after error
keep_running() {
    echo $1
    sleep infinity &
    wait
}

# cm_hasany: Query Cloudify Manager and return 0 (true) if there are any entities matching the query
# Used to see if something is already present on CM
# $1 -- query fragment, for instance "plugins?archive_name=xyz.wgn" to get
#  the number of plugins that came from the archive file "xyz.wgn"
function cm_hasany {
    # We use _include=id to limit the amount of data the CM sends back
    # We rely on the "metadata.pagination.total" field in the response
    # for the total number of matching entities
    COUNT=$(curl -Ss -H "Tenant: default_tenant" --user admin:${CMPASS} "${CMADDR}/api/v3.1/$1&_include=id" \
             | /bin/jq .metadata.pagination.total)
    if (( $COUNT > 0 ))
    then
        return 0
    else
        return 1
    fi
}

# deploy: Deploy components if they're not already deployed
# $1 -- name (for bp and deployment)
# $2 -- blueprint file name
# $3 -- inputs file name (optional)
function deploy {
    # Don't crash the script on error
    set +e

    # Upload blueprint if it's not already there
    if cm_hasany "blueprints?id=$1"
    then
        echo blueprint $1 is already installed on ${CMADDR}
    else
        cfy blueprints upload -b $1  /blueprints/$2
    fi

    # Create deployment if it doesn't already exist
    if cm_hasany "deployments?id=$1"
    then
       echo deployment $1 has already been created on ${CMADDR}
    else
        INPUTS=
        if [ -n "$3" ]
        then
            INPUTS="-i/inputs/$3"
        fi
        cfy deployments create -b $1 ${INPUTS} $1
    fi

    # Run the install workflow if it hasn't been run already
    # We don't have a completely certain way of determining this.
    # We check to see if the deployment has any node instances
    # that are in the 'uninitialized' or 'deleted' states.  (Note that
    # the & in the query acts as a logical OR for the multiple state values.)
    # We'll try to install when a deployment has node instances in those states
    if cm_hasany "node-instances?deployment_id=$1&state=uninitialized&state=deleted"
    then
        cfy executions start -d $1 install
    else
        echo deployment $1 appears to have had an install workflow executed already or is not ready for an install
    fi
}

# Install plugin if it's not already installed
# $1 -- path to wagon file for plugin
function install_plugin {
    ARCHIVE=$(basename $1)
    # See if it's already installed
    if cm_hasany "plugins?archive_name=$ARCHIVE"
    then
        echo plugin $1 already installed on ${CMADDR}
    else
        cfy plugin upload $1
    fi
}

### END FUNCTION DEFINTIONS ###

set -x

# Make sure we keep the container alive after an error
trap keep_running ERR

set -e

# Consul service registration data
CBS_REG='{"ID": "dcae-cbs0", "Name": "config_binding_service", "Address": "config-binding-service", "Port": 10000}'
CBS_REG1='{"ID": "dcae-cbs1", "Name": "config-binding-service", "Address": "config-binding-service", "Port": 10000}'
INV_REG='{"ID": "dcae-inv0", "Name": "inventory", "Address": "inventory", "Port": 8080}'
HE_REG='{"ID": "dcae-he0", "Name": "holmes-engine-mgmt", "Address": "holmes-engine-mgmt", "Port": 9102}'
HR_REG='{"ID": "dcae-hr0", "Name": "holmes-rule-mgmt", "Address": "holmes-rule-mgmt", "Port": 9101}'

# Cloudify Manager will always be in the ONAP namespace.
CM_REG='{"ID": "dcae-cm0", "Name": "cloudify_manager", "Port": 80, "Address": "dcae-cloudify-manager.'${ONAP_NAMESPACE}'"}'
# Policy handler will be looked up from a plugin on CM.  If DCAE components are running in a different k8s
# namespace than CM (which always runs in the common ONAP namespace), then the policy handler address must
# be qualified with the DCAE namespace.
PH_REG='{"ID": "dcae-ph0", "Name": "policy_handler", "Port": 25577, "Address": "policy-handler'
if [ ! -z "${DCAE_NAMESPACE}" ]
then
	PH_REG="${PH_REG}.${DCAE_NAMESPACE}"
fi
PH_REG="${PH_REG}\"}"



# Set up profile to access Cloudify Manager
cfy profiles use -u admin -t default_tenant -p "${CMPASS}"  "${CMADDR}"

# Output status, for debugging purposes
cfy status

# Check Consul readiness
# The readiness container waits for a "consul-server" container to be ready,
# but this isn't always enough.  We need the Consul API to be up and for
# the cluster to be formed, otherwise our Consul accesses might fail.
# (Note in ONAP R2, we never saw a problem, but occasionally in R3 we
# have seen Consul not be fully ready, so we add these checks, originally
# used in the R1 HEAT-based deployment.)
# Wait for Consul API to come up
until curl http://${CONSUL}/v1/agent/services
do
    echo Waiting for Consul API
    sleep 60
done
# Wait for a leader to be elected
until [[ "$(curl -Ss http://{$CONSUL}/v1/status/leader)" != '""' ]]
do
    echo Waiting for leader
    sleep 30
done

# Load configurations into Consul KV store
for config in /dcae-configs/*.json
do
    # The basename of the file is the Consul key
    key=$(basename ${config} .json)
    # Strip out comments, empty lines
    egrep -v "^#|^$" ${config} > /tmp/dcae-upload
    curl -v -X PUT -H "Content-Type: application/json" --data-binary @/tmp/dcae-upload ${CONSUL}/v1/kv/${key}
done

# Put service registrations into the local Consul configuration directory
for sr in CBS_REG CBS_REG1 INV_REG HE_REG HR_REG CM_REG PH_REG
do
  echo '{"service" : ' ${!sr}  ' }'> /opt/consul/config/${sr}.json
done

# Start the local consul agent instance
/opt/consul/bin/consul agent --config-dir /opt/consul/config 2>&1 | tee /opt/consul/consul.log &

# Store the CM password into a Cloudify secret
cfy secret create -s ${CMPASS} cmpass

# Load plugins onto CM
for wagon in /wagons/*.wgn
do
    install_plugin ${wagon}
done

# After this point, failures should not stop the script or block later commands
trap - ERR
set +e

# Deploy platform components
# Allow for some parallelism to speed up the process.  Probably could be somewhat more aggressive.
# config_binding_service and pgaas_initdb needed by others, but can execute in parallel
deploy config_binding_service k8s-config_binding_service.yaml k8s-config_binding_service-inputs.yaml &
CBS_PID=$!
deploy pgaas_initdb k8s-pgaas-initdb.yaml k8s-pgaas-initdb-inputs.yaml &
PG_PID=$!
wait ${CBS_PID} ${PG_PID}
# inventory, deployment_handler, and policy_handler can be deployed simultaneously
deploy inventory k8s-inventory.yaml k8s-inventory-inputs.yaml &
INV_PID=$!
deploy deployment_handler k8s-deployment_handler.yaml k8s-deployment_handler-inputs.yaml &
DH_PID=$!
deploy policy_handler k8s-policy_handler.yaml k8s-policy_handler-inputs.yaml&
PH_PID=$!
wait ${INV_PID} ${DH_PID} ${PH_PID}

# Deploy service components
# tca, ves, prh can be deployed simultaneously
deploy tca k8s-tca.yaml k8s-tca-inputs.yaml &
deploy ves k8s-ves.yaml k8s-ves-inputs.yaml &
deploy prh k8s-prh.yaml &
# holmes_rules must be deployed before holmes_engine, but holmes_rules can go in parallel with other service components
deploy holmes_rules k8s-holmes-rules.yaml k8s-holmes_rules-inputs.yaml
deploy holmes_engine k8s-holmes-engine.yaml k8s-holmes_engine-inputs.yaml

# Display deployments, for debugging purposes
cfy deployments list

# Continue running
keep_running "Finished bootstrap steps."
echo "Exiting!"