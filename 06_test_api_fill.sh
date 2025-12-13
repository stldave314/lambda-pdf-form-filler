#!/bin/bash

# Configuration
API_URL=$(cat .last_api_url 2>/dev/null)
API_KEY=""
BUCKET_NAME=""
INPUT_FILE=""

# Helper: Input Prompt
get_input() {
    local prompt_text=$1
    local var_value=$2
    if [ -z "$var_value" ]; then
        read -p "$prompt_text: " input
        echo "$input"
    else
        echo "$var_value"
    fi
}

echo "--- API Auto-Fill Tester ---"

# 1. Gather Inputs
API_URL=$(get_input "Enter API URL" "$API_URL")
API_KEY=$(get_input "Enter API Key (x-api-key)" "$API_KEY")
BUCKET_NAME=$(get_input "Enter S3 Bucket Name" "$BUCKET_NAME")
INPUT_FILE=$(get_input "Enter Input PDF Key" "$INPUT_FILE")
OUTPUT_FILE="filled/map_$(basename "$INPUT_FILE")"

echo ""
echo "--- Step 1: Inspecting PDF Fields ---"

# 2. Inspect Payload
INSPECT_PAYLOAD=$(jq -n \
                  --arg bn "$BUCKET_NAME" \
                  --arg if "$INPUT_FILE" \
                  '{bucket_name: $bn, input_filename: $if}')

# 3. Call API (Inspect) - Capture HTTP Code
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_URL" \
    -H "x-api-key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$INSPECT_PAYLOAD")

# Separate Body and Status Code
HTTP_BODY=$(echo "$RESPONSE" | head -n -1)
HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)

# 4. Error Handling
if [ "$HTTP_CODE" != "200" ]; then
    echo "ERROR: API returned Status $HTTP_CODE"
    echo "Response Body: $HTTP_BODY"
    
    if [[ "$HTTP_BODY" == *"Forbidden"* ]]; then
        echo ""
        echo "Troubleshooting 'Forbidden':"
        echo "1. Wait 60 seconds (API Keys take time to propagate)."
        echo "2. Ensure the API Key is added to the Usage Plan."
        echo "3. Ensure the Usage Plan is linked to the 'prod' Stage."
    fi
    exit 1
fi

echo "Success! (Status 200)"

# 5. Extract Fields
FORM_DATA=$(echo "$HTTP_BODY" | jq '.fields | with_entries(.value = .key)')
FIELD_COUNT=$(echo "$FORM_DATA" | jq 'length')

if [ "$FIELD_COUNT" == "0" ]; then
    echo "Warning: No form fields found in this PDF. Cannot fill anything."
    exit 0
fi

echo "Found $FIELD_COUNT fields. Mapping names..."

echo ""
echo "--- Step 2: Filling PDF ---"

# 6. Fill Payload
FILL_PAYLOAD=$(jq -n \
                  --arg bn "$BUCKET_NAME" \
                  --arg if "$INPUT_FILE" \
                  --arg of "$OUTPUT_FILE" \
                  --argjson fd "$FORM_DATA" \
                  '{bucket_name: $bn, input_filename: $if, output_filename: $of, form_data: $fd}')

# 7. Call API (Fill)
FILL_RESPONSE=$(curl -s -X POST "$API_URL" \
    -H "x-api-key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$FILL_PAYLOAD")

echo "$FILL_RESPONSE" | jq .
