#!/bin/bash

# Function to perform login and retrieve tokens
perform_login() {
    read -s -p "Enter admin password: " password
    echo  # Print a newline after password input

    echo "Logging in..."
    login_response=$(curl -s -X POST 'https://localhost/api/login' \
        -H 'Content-Type: application/json' \
        -d '{"username": "admin", "password": "'"$password"'"}' \
        -k)
    
    access_token=$(echo "$login_response" | jq -r '.access_token')
    refresh_token=$(echo "$login_response" | jq -r '.refresh_token')
    user_id=$(echo "$login_response" | jq -r '.user_id')

    if [[ -z "$access_token" || -z "$refresh_token" ]]; then
        echo "Login failed. Please check your credentials."
        exit 1
    fi

    echo "Login successful."
    export access_token
    export refresh_token
}

# Function to retrieve device inventory
retrieve_inventory() {
    inventory_response=$(curl -s -X GET 'https://localhost/api/device/v1/inventory' \
        -H "Authorization: Bearer $refresh_token" \
        -k)
    
    echo "$inventory_response"
}

# Function to retrieve services for a device
retrieve_services() {
    device_id="$1"
    services_response=$(curl -s -X GET "https://localhost/api/device/v1/proxy/$device_id?path=/services" \
        -H "Authorization: Bearer $refresh_token" \
        -k)
    
    echo "$services_response"
}

# Main script logic

perform_login

echo "Retrieving device inventory..."
inventory=$(retrieve_inventory)

# Ensure inventory is valid JSON before proceeding
if ! echo "$inventory" | jq . > /dev/null 2>&1; then
    echo "Failed to parse inventory response as JSON. Exiting."
    echo $inventory
    exit 1
fi

device_count=$(echo "$inventory" | jq -r '.total')

# Check if the inventory has no devices
if [[ "$device_count" -eq 0 ]]; then
    echo "No devices found in inventory. Exiting."
    exit 0
fi

devices=$(echo "$inventory" | jq -c '.["_embedded"].devices[]')

bad_device_count=0

while IFS= read -r device; do
    device_id=$(echo "$device" | jq -r '.id')
    device_hostname=$(echo "$device" | jq -r '.hostname')
    device_address=$(echo "$device" | jq -r '.address')

    echo "Processing device $device_hostname ($device_address)..."

    services=$(retrieve_services "$device_id")
    
    # Ensure services is valid JSON before proceeding
    if ! echo "$services" | jq . > /dev/null 2>&1; then
        echo "Failed to parse services response as JSON for device '$device_hostname' ($device_address). Skipping."
        ((bad_device_count++))
        echo "---"
        continue
    fi

    if [[ $(echo "$services" | jq -r '.count') -gt 0 ]]; then
        service_name=$(echo "$services" | jq -r '._embedded.services[] | select(.name == "Default Service") | .name')
        if [[ "$service_name" == "Default Service" ]]; then
            server_ado_svc=$(echo "$services" | jq -r '._embedded.services[] | select(.name == "Default Service") | .analytics.servers[] | select(.hostname == "server.ado.svc") | .hostname')
            if [[ -z "$server_ado_svc" ]]; then
                echo "Hostname 'server.ado.svc' not found in services for device '$device_hostname' ($device_address)"
                ((bad_device_count++))
            fi
        else
            echo "No default service found for device '$device_hostname' ($device_address)"
            ((bad_device_count++))
        fi
    else
        echo "No services found for device '$device_hostname' ($device_address)"
        ((bad_device_count++))
    fi

    echo "---"
done <<< "$devices"

echo "Total instances impacted: $bad_device_count out of $device_count"
