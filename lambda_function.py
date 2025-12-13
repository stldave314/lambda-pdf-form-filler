import json
import boto3
import io
from pypdf import PdfReader, PdfWriter
from pypdf.generic import NameObject, NumberObject

s3 = boto3.client('s3')

def set_fields_readonly(writer):
    """Recursively set all form fields to ReadOnly."""
    for page in writer.pages:
        if "/Annots" in page:
            for annot in page["/Annots"]:
                annot_obj = annot.get_object()
                current_flags = annot_obj.get("/Ff", NumberObject(0))
                annot_obj[NameObject("/Ff")] = NumberObject(int(current_flags) | 1)

def lambda_handler(event, context):
    try:
        bucket_name = event.get('bucket_name')
        input_key = event.get('input_filename')
        output_key = event.get('output_filename')
        form_data = event.get('form_data')

        if not bucket_name or not input_key:
            return {'statusCode': 400, 'body': json.dumps('Error: bucket_name and input_filename are required.')}

        print(f"Downloading {input_key} from {bucket_name}...")
        file_obj = s3.get_object(Bucket=bucket_name, Key=input_key)
        pdf_stream = io.BytesIO(file_obj['Body'].read())
        reader = PdfReader(pdf_stream)

        # MODE A: INSPECT
        if not output_key:
            fields = reader.get_fields()
            if fields:
                # Safely extract value, handling potential None types
                field_summary = {k: str(v.get('/V', '')) for k, v in fields.items()}
            else:
                field_summary = {}
            
            return {'statusCode': 200, 'mode': 'inspect', 'fields': field_summary}

        # MODE B: FILL
        else:
            if not form_data:
                return {'statusCode': 400, 'body': json.dumps('Error: form_data is required when output_filename is present.')}

            writer = PdfWriter()
            writer.append_pages_from_reader(reader)
            
            # --- FIX STARTS HERE ---
            # 1. Check if the original PDF actually has a form
            if "/AcroForm" not in reader.root_object:
                return {
                    'statusCode': 400, 
                    'body': json.dumps('Error: The input PDF does not contain an interactive form (AcroForm).')
                }

            # 2. Explicitly copy the global AcroForm dictionary to the Writer
            # This tells the Writer where the fields are defined.
            writer.root_object.update({
                NameObject("/AcroForm"): reader.root_object["/AcroForm"]
            })
            # --- FIX ENDS HERE ---

            writer.update_page_form_field_values(writer.pages[0], form_data, auto_regenerate=True)
            set_fields_readonly(writer)

            output_stream = io.BytesIO()
            writer.write(output_stream)
            output_stream.seek(0)

            print(f"Uploading result to {output_key}...")
            s3.put_object(Bucket=bucket_name, Key=output_key, Body=output_stream, ContentType='application/pdf')

            return {'statusCode': 200, 'mode': 'fill', 'message': f"PDF filled and saved to {output_key}"}

    except Exception as e:
        print(f"Error: {str(e)}")
        # Return the error in the body so we can see it in the client
        return {'statusCode': 500, 'body': json.dumps(f"Internal Server Error: {str(e)}")}
