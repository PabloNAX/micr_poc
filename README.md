# MICR OCR App

A Flutter app POC that captures and processes images of checks to extract the MICR line, obtaining the cheque number, routing code, and account number.



https://github.com/user-attachments/assets/390e2e1b-de8a-4f97-bfa4-7b8df7a511e7



## How It Works

1. **Camera Capture**:
    - Initializes the device's camera.
    - Displays a live preview with an overlay to guide check placement.

2. **Image Processing**:
    - Captures the image when the user taps "Capture and Process".
    - Corrects image orientation if necessary.
    - Crops the area where the MICR line is expected (bottom 30% of the image).
    - Converts the cropped image to grayscale.
    - Enhances contrast and applies adaptive thresholding for better OCR accuracy.
    - Handles upside-down checks by rotating the image 180 degrees if needed.

3. **OCR Extraction**:
    - Uses Tesseract OCR with MICR-specific `e13b` trained data.
    - Extracts text from the processed image.
    - Cleans the OCR output by removing non-digit characters.
    - Searches for a sequence of exactly 25 digits (standard length of a MICR line).

4. **Data Parsing**:
    - Splits the 25-digit sequence into:
        - **Cheque Number**: First 6 digits.
        - **Routing Code**: Next 9 digits.
        - **Account Number**: Last 10 digits.

5. **Results Display**:
    - Shows the extracted cheque number, routing code, and account number.
    - Provides error messages if extraction fails or data is invalid.

## Advantages

- **Cost-Effective**: Eliminates the need for paid OCR services by using local processing.
- **Offline Functionality**: Works without an internet connection.
- **Privacy**: Processes sensitive financial data locally on the device.

## Disadvantages

- **Increased App Size**: Adds approximately 20 MB due to the inclusion of the OCR model and assets.
- **Performance**: Local image processing can be slow on some devices.
- **User Experience**: Requires precise check placement and good lighting conditions.
- **Development Complexity**: Handling image processing and device compatibility increases development and testing efforts.
