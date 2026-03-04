# Core ML Integration Setup Guide

## Overview
This guide explains how to fix the compilation errors and set up Core ML models in your Novel app.

## Files Fixed

### 1. ONNXUrgencyEngine.swift → CoreMLUrgencyEngine.swift
- **Issue**: `onnxruntime_objc` module not found
- **Solution**: Replaced ONNX Runtime with Core ML framework
- **Changes**:
  - Import `CoreML` instead of `onnxruntime_objc`
  - Use `MLModel` instead of `ORTSession`
  - Use `MLMultiArray` for input/output handling

### 2. UrgencyManager.swift
- **Issue**: Top-level expressions not allowed
- **Solution**: Moved example usage code into a static method within an extension
- **Changes**:
  - Wrapped example code in `UrgencyManager.example()` static method
  - Updated to use `CoreMLUrgencyEngine` instead of `ONNXUrgencyEngine`

### 3. MLModelManager.swift (Created)
- **Issue**: File was missing, causing "Cannot find FirstModel/SecondModel" errors
- **Solution**: Created comprehensive ML model management class
- **Features**:
  - Loads FirstModel.mlmodel and SecondModel.mlmodel
  - Provides prediction methods for both models
  - Handles UIImage processing for image-based models
  - Includes error handling and logging

### 4. XcodeGeneratedModelUsage.swift (Created)
- **Issue**: File was missing, causing "Cannot find YourModel" errors
- **Solution**: Created example usage patterns for Core ML models
- **Features**:
  - Examples for both FirstModel and SecondModel usage
  - Generic model handler for flexible model loading
  - Proper error handling and input validation

## Steps to Complete Setup

### 1. Convert ONNX Models to Core ML

```bash
# Update the paths in convert_onnx_to_coreml.py to point to your actual ONNX files
python3 convert_onnx_to_coreml.py
```

This will generate:
- `FirstModel.mlmodel` (for urgency scoring)
- `SecondModel.mlmodel` (for urgency bucket classification)

### 2. Add Models to Xcode Project

1. Drag and drop the generated `.mlmodel` files into your Xcode project
2. Make sure "Add to target" is checked for your app target
3. Verify the models appear in your project navigator

### 3. Import Required Frameworks

Ensure your project has access to:
- `CoreML` framework (should be available by default)
- `Foundation` framework
- `UIKit` (for iOS) or `AppKit` (for macOS)

### 4. Remove ONNX Dependencies

If you had ONNX Runtime dependencies, you can remove them:
- Remove any ONNX Runtime packages from Package Manager
- Delete any ONNX Runtime related build settings
- Remove the old ONNXUrgencyEngine.swift file (replaced by CoreMLUrgencyEngine.swift)

## Usage Examples

### Basic Urgency Classification

```swift
let manager = UrgencyManager()
let classification = manager.classifyEvent(
    hoursUntilStart: 12.0,
    isPastDue: false,
    hasDeadline: true,
    isAllDay: false,
    attendeeCount: 3
)

print("Urgency: \(classification.bucket.rawValue)")
print("Score: \(classification.score)")
```

### Direct Model Usage

```swift
let modelManager = MLModelManager()

// For numeric predictions
let input: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0]
if let result = modelManager.predictWithFirstModel(input: input) {
    print("Prediction: \(result)")
}

// For image-based predictions (iOS only)
if let image = UIImage(named: "test_image"),
   let result = modelManager.predictFromImage(image) {
    print("Image prediction: \(result)")
}
```

## Model Input Requirements

Both models expect:
- **Input Shape**: `[1, 32]` (batch size 1, 32 features)
- **Data Type**: Float32
- **Input Name**: "input"

Make sure your feature extraction code provides exactly 32 float values.

## Troubleshooting

### Model Not Found Errors
- Verify `.mlmodel` files are added to your Xcode project
- Check that files are included in your app target
- Ensure file names match exactly: "FirstModel.mlmodel" and "SecondModel.mlmodel"

### Prediction Errors
- Verify input array has exactly 32 elements
- Check that input values are in the expected range
- Review model output names (may need to adjust from "output" to actual names)

### Build Errors
- Clean build folder (Cmd+Shift+K)
- Ensure all import statements are correct
- Verify Core ML framework is available for your deployment target

## Performance Optimization

The Core ML models are configured to use:
- `computeUnits = .all` (uses Neural Engine, GPU, and CPU as available)
- Automatic optimization based on device capabilities
- Efficient memory management

For production, consider:
- Testing on different device types
- Monitoring prediction latency
- Implementing model caching if needed

## Migration Notes

If migrating from ONNX Runtime:
1. The API is largely similar, but uses Core ML types
2. Error handling is more robust with Core ML
3. Performance should be better on Apple devices
4. No external dependencies required