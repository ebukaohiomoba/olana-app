# ONNX to Core ML Conversion Guide

## Prerequisites

1. **Install Python 3** (if not already installed):
   ```bash
   # macOS (using Homebrew)
   brew install python3
   
   # Or download from python.org
   ```

2. **Install coremltools**:
   ```bash
   pip3 install coremltools
   ```

## Steps to Convert Your Models

### 1. Prepare Your ONNX Files

Make sure you have your ONNX model files ready. You'll need:
- Your urgency score model (outputs a continuous score 0-10)
- Your urgency bucket model (outputs a classification: 0=low, 1=medium, 2=high)

### 2. Update the Conversion Script

Edit `convert_onnx_to_coreml.py` and replace the placeholder paths:

```python
# Change these lines:
convert_onnx_to_coreml(
    onnx_path="path/to/your/urgency_score_model.onnx",  # ← Update this path
    coreml_path="FirstModel.mlmodel",
    model_name="Urgency Score Model",
    compute_units=ct.ComputeUnit.ALL
)

convert_onnx_to_coreml(
    onnx_path="path/to/your/urgency_bucket_model.onnx", # ← Update this path
    coreml_path="SecondModel.mlmodel", 
    model_name="Urgency Bucket Model",
    compute_units=ct.ComputeUnit.ALL
)
```

### 3. Run the Conversion

**Option A: Using the shell script (macOS/Linux)**
```bash
chmod +x run_conversion.sh
./run_conversion.sh
```

**Option B: Direct Python execution**
```bash
python3 convert_onnx_to_coreml.py
```

### 4. Verify Output

After successful conversion, you should see:
```
FirstModel.mlmodel   # Your urgency score model
SecondModel.mlmodel  # Your urgency bucket classification model
```

### 5. Add Models to Xcode

1. Open your Xcode project
2. Drag and drop both `.mlmodel` files into your project navigator
3. Make sure "Add to target" is checked for your app target
4. Verify the models appear in your project

## Expected Model Specifications

Your converted Core ML models should have:

**Input:**
- Name: "input"
- Type: MLMultiArray
- Shape: [1, 32] (batch size 1, 32 features)
- Data Type: Float32

**Output:**
- **FirstModel** (Score): Continuous value 0-10
- **SecondModel** (Bucket): Integer class index (0=low, 1=medium, 2=high)

## Troubleshooting

### Common Issues:

1. **"No module named 'coremltools'"**
   ```bash
   pip3 install coremltools
   ```

2. **"File not found" error**
   - Check that your ONNX file paths are correct
   - Use absolute paths if relative paths don't work

3. **Conversion fails with shape errors**
   - Verify your ONNX model input/output shapes
   - Make sure models expect exactly 32 input features

4. **Models load but predictions fail**
   - Check input/output tensor names in your ONNX models
   - You may need to adjust the Swift code to match actual tensor names

### Getting Model Information

To inspect your ONNX models before conversion:
```python
import onnx

model = onnx.load("your_model.onnx")
print("Input:")
for input in model.graph.input:
    print(f"  Name: {input.name}")
    print(f"  Shape: {input.type.tensor_type.shape}")

print("Output:")
for output in model.graph.output:
    print(f"  Name: {output.name}")
    print(f"  Shape: {output.type.tensor_type.shape}")
```

## Testing the Integration

Once your models are added to Xcode, test the integration:

```swift
// Test in your app or in a playground
UrgencyManager.example()
```

This should print:
```
Urgency: medium
Score: 6.8
Confidence: 0.95
Engine: coreml_v1
```

## Performance Notes

Core ML models will automatically use:
- Neural Engine (if available)
- GPU acceleration
- CPU fallback

For best performance:
- Test on actual devices, not just simulator
- Monitor prediction latency in your app
- Consider model optimization if needed