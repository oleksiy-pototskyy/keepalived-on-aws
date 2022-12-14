#!/bin/bash
. /lib/lsb/init-functions

function log { logger -t "vpc" -- $1; }

function die {
  [ -n "$1" ] && log "$1"
  log "Configuration of EIP/VIP failover failed!"
  exit 1
}

ELASTIC_IP=$2
PRIVATE_VIP=$3

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

        log "Taking over Private IP $PRIVATE_VIP ownership..."
        aws ec2 assign-private-ip-addresses \
        --network-interface-id $ENI_ETH0 \
        --private-ip-addresses $PRIVATE_VIP \
        --allow-reassignment 2>/dev/null \
        || die "Unable to associate the Private IP $PRIVATE_VIP with the instance."

        # Get list of subnets in same VPC that have tag Network=private
        PRIVATE_SUBNETS="$(aws ec2 describe-subnets --query 'Subnets[*].SubnetId' \
        --filters Name=vpc-id,Values=$VPC_ID Name=state,Values=available Name=tag:Network,Values=private)"

        # If no private subnets found, exit
        if [ -z "$PRIVATE_SUBNETS" ]; then
          die "No private subnets found to modify."
        else
          log "Modifying Route Tables for following private subnets: $PRIVATE_SUBNETS"
        fi

        for subnet in $PRIVATE_SUBNETS; do
          ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
          --query 'RouteTables[*].RouteTableId' \
          --filters Name=association.subnet-id,Values=$subnet);
          # If private tagged subnet is associated with Main Routing Table, do not create or modify route.
          if [[ "$ROUTE_TABLE_ID" == "$MAIN_RT" ]]; then
            log "$subnet is associated with the VPC Main Route Table. The script will NOT edit Main Route Table."
          # If subnet is not associated with a Route Table, skip it.
          elif [[ -z "$ROUTE_TABLE_ID" ]]; then
            log "$subnet is not associated with a Route Table. Skipping this subnet."
          else
            # Modify found private subnet's Routing Table to point to the private fail-over VIP
            aws ec2 create-route --route-table-id $ROUTE_TABLE_ID \
            --destination-cidr-block ${PRIVATE_VIP}/32 \
            --network-interface-id $ENI_ETH0 2>/dev/null \
            && log "Route created in $ROUTE_TABLE_ID pointing ${PRIVATE_VIP}/32 to interface with ID $ENI_ETH0."
            if [[ $? -ne 0 ]] ; then
              log "Route already exists, replacing existing route."
              aws ec2 replace-route --route-table-id $ROUTE_TABLE_ID \
              --destination-cidr-block ${PRIVATE_VIP}/32 \
              --network-interface-id $ENI_ETH0 2>/dev/null \
              && log "$ROUTE_TABLE_ID modified to point ${PRIVATE_VIP}/32 to interface with ID $ENI_ETH0."
            fi
          fi
        done

        log "Primary VIP config finished."
       ;;
    backup)
        log "Transitioned into backup state."
       ;;
    status)
        id=$(aws ec2 describe-addresses --public-ips $ELASTIC_IP --query 'Addresses[0].InstanceId' --output text)
        [[ $? -eq 0 ]] && [[ "$id" =~ ^i-[A-Fa-f0-9]{8,20}$ ]] && echo OK || echo FAIL
        ;;
esac

exit 0
