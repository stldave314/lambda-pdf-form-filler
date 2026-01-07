import { S3Client, GetObjectCommand, PutObjectCommand } from "@aws-sdk/client-s3";
import { PDFDocument } from "pdf-lib";

const s3 = new S3Client({});

const streamToBuffer = async (stream) => {
    return new Promise((resolve, reject) => {
        const chunks = [];
        stream.on("data", (chunk) => chunks.push(chunk));
        stream.on("error", reject);
        stream.on("end", () => resolve(Buffer.concat(chunks)));
    });
};

export const handler = async (event) => {
    try {
        console.log("Event:", JSON.stringify(event));

        // 1. Parse Event
        let payload = event;
        if (event.body) {
            try {
                payload = typeof event.body === 'string' ? JSON.parse(event.body) : event.body;
            } catch (e) {
                console.warn("Failed to parse body as JSON, using raw body", e);
            }
        }

        const bucketName = payload.bucket_name;
        const inputKey = payload.input_filename;
        const outputKey = payload.output_filename;
        const formData = payload.form_data;

        if (!bucketName || !inputKey) {
            return {
                statusCode: 400,
                body: JSON.stringify('Error: bucket_name and input_filename are required.')
            };
        }

        console.log(`Downloading ${inputKey} from ${bucketName}...`);
        const getCommand = new GetObjectCommand({ Bucket: bucketName, Key: inputKey });
        const response = await s3.send(getCommand);
        const pdfBuffer = await streamToBuffer(response.Body);

        const pdfDoc = await PDFDocument.load(pdfBuffer);
        const form = pdfDoc.getForm();

        // MODE A: INSPECT
        if (!outputKey) {
            const fields = form.getFields();
            const fieldSummary = {};

            fields.forEach(field => {
                const name = field.getName();
                // Getting value can be complex for different field types, trying simplified string access
                try {
                    // Try to get value if compatible
                    const value = field.getText(); // Often works for text fields
                    fieldSummary[name] = value || "";
                } catch (e) {
                    // If getText fails (e.g. checkbox), just default empty or specific type handling
                    // For simplicity in this migration, let's list them. 
                    // The python script did: str(v.get('/V', ''))
                    // pdf-lib doesn't have a generic "getValueAsString" for all types easily without checking type.
                    // But we can check constructor name or just leave empty for now as inspection usually mostly cares about names.
                    fieldSummary[name] = "";
                }
            });

            return {
                statusCode: 200,
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ mode: 'inspect', fields: fieldSummary })
            };
        }

        // MODE B: FILL
        else {
            if (!formData) {
                return {
                    statusCode: 400,
                    body: JSON.stringify('Error: form_data is required when output_filename is present.')
                };
            }

            console.log("Filling form with data:", JSON.stringify(formData));

            for (const [key, value] of Object.entries(formData)) {
                try {
                    const field = form.getField(key);
                    // Simple string filling for TextField. 
                    // Checkboxes/DropDowns would need specific handling but assuming text for the basic filler
                    // based on the python script using `update_page_form_field_values` which is generic.

                    // pdf-lib generic fill:
                    if (field.constructor.name === 'PDFTextField') {
                        field.setText(String(value));
                    } else if (field.constructor.name === 'PDFCheckBox') {
                        if (String(value).toLowerCase() === 'true' || String(value) === '1' || String(value).toLowerCase() === 'yes') {
                            field.check();
                        } else {
                            field.uncheck();
                        }
                    } else if (field.constructor.name === 'PDFDropdown') {
                        field.select(String(value));
                    } else {
                        // Fallback or log
                        console.log(`Field ${key} type ${field.constructor.name} not fully supported for auto-fill in this simplified script.`);
                    }

                } catch (e) {
                    console.warn(`Could not set field ${key}: ${e.message}`);
                }
            }

            // Read-only (Flatten)
            form.flatten();

            const pdfBytes = await pdfDoc.save();
            const uploadBuffer = Buffer.from(pdfBytes);

            console.log(`Uploading result to ${outputKey}...`);
            const putCommand = new PutObjectCommand({
                Bucket: bucketName,
                Key: outputKey,
                Body: uploadBuffer,
                ContentType: 'application/pdf'
            });
            await s3.send(putCommand);

            return {
                statusCode: 200,
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ mode: 'fill', message: `PDF filled and saved to ${outputKey}` })
            };
        }

    } catch (e) {
        console.error("Error:", e);
        return {
            statusCode: 500,
            body: JSON.stringify(`Internal Server Error: ${e.message}`)
        };
    }
};
