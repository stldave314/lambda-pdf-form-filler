#!/bin/bash

# Configuration
FUNC_NAME=$1
BUCKET_NAME=$2
INPUT_FILE=$3

# Helper function for input
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

echo "--- AWS Lambda PDF Tester ---"

# 1. Gather Inputs
FUNC_NAME=$(get_input "Enter Function Name" "$FUNC_NAME")
BUCKET_NAME=$(get_input "Enter S3 Bucket Name" "$BUCKET_NAME")
INPUT_FILE=$(get_input "Enter Input PDF Key (e.g. templates/form.pdf)" "$INPUT_FILE")

# 2. Select Mode
echo ""
echo "Select Operation Mode:"
echo "1) Inspect (Get Fields)"
echo "2) Fill (Generate PDF)"
read -p "Selection [1]: " MODE

# 3. Construct Payload
if [ "$MODE" == "2" ]; then
    # FILL MODE
    read -p "Enter Output Filename (e.g. filled/result.pdf): " OUTPUT_FILE
    
    echo "Enter JSON data for form fields (single line):"
    echo "Example: {\"Name\": \"Dave\", \"Date\": \"2025-01-01\"}"
    read -p "Data: " FORM_DATA
    
    if [ -z "$FORM_DATA" ]; then FORM_DATA="{}"; fi

    PAYLOAD=$(jq -n \
                  --arg bn "$BUCKET_NAME" \
                  --arg if "$INPUT_FILE" \
                  --arg of "$OUTPUT_FILE" \
                  --argjson fd "$FORM_DATA" \
                  '{bucket_name: $bn, input_filename: $if, output_filename: $of, form_data: $fd}')

else
    # INSPECT MODE (Default)
    PAYLOAD=$(jq -n \
                  --arg bn "$BUCKET_NAME" \
                  --arg if "$INPUT_FILE" \
                  '{bucket_name: $bn, input_filename: $if}')
fi

# 4. Invoke Lambda
echo ""
echo "Invoking $FUNC_NAME..."
echo "Payload: $PAYLOAD"

# *** FIX: Removed manual '| base64' piping ***
aws lambda invoke \
    --function-name "$FUNC_NAME" \
    --payload "$PAYLOAD" \
    --cli-binary-format raw-in-base64-out \
    response.json

# 5. Display Result
echo ""
echo "--- Lambda Response ---"
if [ -f response.json ]; then
    cat response.json | jq .
    rm response.json
else
    echo "Error: No response file generated."
fi
