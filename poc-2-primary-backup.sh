#!/bin/bash
. /lib/lsb/init-functions

function log { logger -t "vpc" -- $1; }

function die {
  [ -n "$1" ] && log "$1"
  log "Configuration of EIP/VIP failover failed!"
  exit 1
}

ELASTIC_IP=$2

URL="http://169.254.169.254/latest"

log "Determining the MAC address on eth0..."
ETH0_MAC=$(cat /sys/class/net/eth0/address) ||
    die "Unable to determine MAC address on eth0."
log "Found MAC ${ETH0_MAC} for eth0."

# CLI read and connect timeouts so we don't wait forever
AWS_CLI_PARAMS="--cli-read-timeout 3 --cli-connect-timeout 2"

# Set CLI Output to text
export AWS_DEFAULT_OUTPUT="text"

# Collect instance data
ii=$(curl -s $URL/dynamic/instance-identity/document | grep -v -E "{|}" | sed 's/[ \t"]//g;s/,$//')

# Set region of the instance
REGION=$(echo "$ii" | grep region | cut -d":" -f2)

# Set AWS CLI default Region
export AWS_DEFAULT_REGION=$REGION

# Set AZ of the instance
AVAILABILITY_ZONE=$(echo "$ii" | grep availabilityZone | cut -d":" -f2)

# Set Instance ID from metadata
INSTANCE_ID=$(echo "$ii" | grep instanceId | cut -d":" -f2)

# Set Instance main IP from metadata
IP_ETH0=$(echo "$ii" | grep privateIp | cut -d":" -f2)

# Find the eth0 ENI
log "Determining the ENI of eth0..."
ENI_ETH0=$(curl -s $URL/meta-data/network/interfaces/macs/${ETH0_MAC}/interface-id) \
  && log "Found ENI of $ENI_ETH0 for eth0." \
  || die "Failed to find the ENI for eth0."

# EIP Allocation ID
log "Determining the AllocationId for $ELASTIC_IP..."
ALOC_ID=$(aws ec2 describe-addresses $AWS_CLI_PARAMS \
  --public-ips $ELASTIC_IP --query 'Addresses[0].AllocationId' --output text) \
  && log "Found AllocationId of $ALOC_ID for $ELASTIC_IP" \
  || die "Failed to find the AllocationId for $ELASTIC_IP."

# Set VPC_ID of Instance
VPC_ID=$(aws ec2 describe-instances $AWS_CLI_PARAMS \
  --instance-ids $INSTANCE_ID --query 'Reservations[*].Instances[*].VpcId') \
  || die "Unable to determine VPC ID for instance."

case $1 in
    primary)
        log "Taking over EIP $ELASTIC_IP ownership..."
        aws ec2 associate-address --allocation-id $ALOC_ID \
        --network-interface-id $ENI_ETH0 \
        --private-ip-address $IP_ETH0 \
        --allow-reassociation 2>/dev/null \
        || die "Unable to associate the EIP $ELASTIC_IP with the instance."

        log "Primary VIP config finished."
       ;;
    backup)
        log "Transitioned into backup state."
       ;;
esac

exit 0
