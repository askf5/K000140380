#!/bin/bash

CERT_NAME="mbiq-ado-vault-client-cert"
DEPLOYMENT_NAME="mbiq-device-feature"
LOG_POD="mbiq-fluentd-0"
LOG_CONTAINER="fluentd"
LOG_PATTERN="Sending PUT request to https://"
IP_REGEX="https://([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)"
TIME_WINDOW=5
MAX_RETRIES=3

# Function to get the expiry date of the certificate
get_expiry_date() {
  cmctl status certificate $CERT_NAME | grep "Not After" | awk '{print $3}'
}

# Initial expiry date
initial_expiry_date=$(get_expiry_date)
echo "Initial Expiry Date: $initial_expiry_date"

# Renew the certificate
cmctl renew $CERT_NAME
echo "Renew command executed for $CERT_NAME"

# Wait for the expiry date to change
while true; do
  new_expiry_date=$(get_expiry_date)
  if [ "$new_expiry_date" != "$initial_expiry_date" ]; then
    echo "Expiry Date Updated: $new_expiry_date"
    break
  fi
  echo "Waiting for expiry date to change..."
  sleep 1  # Check every 1 second
done

echo "Certificate renewal process completed."

# Restart the deployment
echo "Restarting CM device service"
kubectl rollout restart deployment $DEPLOYMENT_NAME

echo "Updating BIG-IP Next instances remote loggers"
# Wait for the deployment to be ready
while true; do
  # Check if the pods are in a ready state
  ready_replicas=$(kubectl get deployment $DEPLOYMENT_NAME -o jsonpath='{.status.readyReplicas}')
  desired_replicas=$(kubectl get deployment $DEPLOYMENT_NAME -o jsonpath='{.status.replicas}')

  if [ "$ready_replicas" == "$desired_replicas" ] && [ "$ready_replicas" != "" ]; then
    break
  fi
  sleep 1  # Check every second
done

# Function to check logs for the specified pattern and print IP addresses found within the last 5 seconds
check_logs_for_pattern() {
  local retries=0
  local last_check_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  while [ $retries -lt $MAX_RETRIES ]; do
    sleep $TIME_WINDOW
    log_output=$(kubectl logs $LOG_POD $LOG_CONTAINER --since-time=$last_check_time)
    if echo "$log_output" | grep -q "$LOG_PATTERN"; then
      ip_addresses=$(echo "$log_output" | grep "$LOG_PATTERN" | grep -oP "$IP_REGEX" | cut -d'/' -f3 | uniq)
      echo "Updated BIG-IP Next instance: $ip_addresses at $(date +"%Y-%m-%d %H:%M:%S")"
      retries=0  # Reset retries if pattern is found
    else
      retries=$((retries + 1))
    fi
    last_check_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  done
}

sleep $TIME_WINDOW
check_logs_for_pattern

echo "Done."
