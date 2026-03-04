#!/bin/bash

# ONNX to Core ML Conversion Script
# Run this script to convert your ONNX models to Core ML format

echo "🚀 Starting ONNX to Core ML conversion..."

# Check if Python 3 is available
if ! command -v python3 &> /dev/null; then
    echo "❌ Python 3 is not installed. Please install Python 3 first."
    exit 1
fi

# Check if coremltools is installed
python3 -c "import coremltools" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "📦 Installing coremltools..."
    pip3 install coremltools
fi

# Check if the conversion script exists
if [ ! -f "convert_onnx_to_coreml.py" ]; then
    echo "❌ convert_onnx_to_coreml.py not found in current directory"
    exit 1
fi

# Update the script with actual file paths
echo "📝 Please update the ONNX file paths in convert_onnx_to_coreml.py before running:"
echo "   - Replace 'path/to/your/urgency_score_model.onnx' with your actual score model path"
echo "   - Replace 'path/to/your/urgency_bucket_model.onnx' with your actual bucket model path"
echo ""
echo "Press Enter to continue after updating the paths, or Ctrl+C to cancel..."
read

# Run the conversion
echo "🔄 Converting ONNX models to Core ML..."
python3 convert_onnx_to_coreml.py

# Check if the conversion was successful
if [ -f "FirstModel.mlmodel" ] && [ -f "SecondModel.mlmodel" ]; then
    echo "✅ Conversion successful!"
    echo "📁 Generated files:"
    echo "   - FirstModel.mlmodel (Urgency Score Model)"
    echo "   - SecondModel.mlmodel (Urgency Bucket Model)"
    echo ""
    echo "📲 Next steps:"
    echo "1. Drag and drop both .mlmodel files into your Xcode project"
    echo "2. Make sure 'Add to target' is checked for your app target"
    echo "3. Build and run your project"
else
    echo "❌ Conversion failed. Check the error messages above."
    echo "💡 Common issues:"
    echo "   - ONNX files not found at specified paths"
    echo "   - ONNX files are corrupted or incompatible"
    echo "   - Missing dependencies"
fi