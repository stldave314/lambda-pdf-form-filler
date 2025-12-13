#!/bin/bash

# Configuration
PLAN_FILE=".last_usage_plan_id"

# Check for Usage Plan ID
if [ -f "$PLAN_FILE" ]; then
    PLAN_ID=$(cat "$PLAN_FILE")
else
    echo "Error: Usage Plan ID not found in $PLAN_FILE."
    read -p "Please enter the Usage Plan ID manually: " PLAN_ID
fi

show_menu() {
    echo "--- API Key Manager ($PLAN_ID) ---"
    echo "1. Create New API Key"
    echo "2. List API Keys"
    echo "3. Delete API Key"
    echo "4. Exit"
}

create_key() {
    read -p "Enter Key Name (e.g. client-dave): " KEY_NAME
    
    # Create Key
    KEY_ID=$(aws apigateway create-api-key \
        --name "$KEY_NAME" \
        --enabled \
        --query 'id' --output text)
        
    # Get Key Value (Secret)
    KEY_VAL=$(aws apigateway get-api-key --api-key "$KEY_ID" --include-value --query 'value' --output text)

    # Attach to Usage Plan
    aws apigateway create-usage-plan-key \
        --usage-plan-id "$PLAN_ID" \
        --key-id "$KEY_ID" \
        --key-type "API_KEY" > /dev/null
        
    echo ""
    echo "SUCCESS!"
    echo "Key ID:    $KEY_ID"
    echo "x-api-key: $KEY_VAL"
    echo "(Save the 'x-api-key' value securely. It is your password.)"
    echo ""
}

list_keys() {
    echo ""
    echo "--- Active Keys ---"
    aws apigateway get-usage-plan-keys --usage-plan-id "$PLAN_ID" \
        | jq -r '.items[] | "\(.name) \t [\(.id)]"'
    echo ""
}

delete_key() {
    list_keys
    read -p "Enter Key ID to delete: " KEY_ID
    
    # Detach from Plan
    aws apigateway delete-usage-plan-key --usage-plan-id "$PLAN_ID" --key-id "$KEY_ID"
    
    # Delete Key
    aws apigateway delete-api-key --api-key "$KEY_ID"
    
    echo "Key deleted."
}

# Main Loop
while true; do
    show_menu
    read -p "Select option: " OPT
    case $OPT in
        1) create_key ;;
        2) list_keys ;;
        3) delete_key ;;
        4) exit 0 ;;
        *) echo "Invalid option" ;;
    esac
done
