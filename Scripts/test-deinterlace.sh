#!/bin/bash
# Test script for QTGMC deinterlacing
# Usage: ./Scripts/test-deinterlace.sh [input.avi] [output.avi]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Default paths
INPUT="${1:-$PROJECT_DIR/Tests/TestResources/interlaced_test.avi}"
OUTPUT="${2:-$PROJECT_DIR/Tests/TestResources/deinterlaced_output.avi}"

# Check input exists
if [ ! -f "$INPUT" ]; then
    echo "Error: Input file not found: $INPUT"
    exit 1
fi

# Create temp directory for script
TEMP_DIR=$(mktemp -d)
SCRIPT_FILE="$TEMP_DIR/test_qtgmc.vpy"

# Generate VapourSynth script
cat > "$SCRIPT_FILE" << EOF
"""
Test QTGMC deinterlacing script
Input: $INPUT
"""
import vapoursynth as vs
import sys

core = vs.core

# Load input video
clip = core.ffms2.Source(source=r"$INPUT")

# Print info
print(f"Input: {clip.width}x{clip.height}, {clip.num_frames} frames, {clip.fps.numerator}/{clip.fps.denominator} fps", file=sys.stderr)

# Import havsfunc and run QTGMC
import havsfunc as haf

# Deinterlace with QTGMC
# - Preset="Fast" for quick testing (use "Slower" for better quality)
# - TFF=True for top-field-first (common for PAL/DVB content)
# - opencl=True to use NNEDI3CL on GPU
clip = haf.QTGMC(
    clip,
    Preset="Fast",
    TFF=True,
    opencl=True,
    device=0,
)

print(f"Output: {clip.width}x{clip.height}, {clip.num_frames} frames, {clip.fps.numerator}/{clip.fps.denominator} fps", file=sys.stderr)

clip.set_output()
EOF

echo "=== QTGMC Deinterlace Test ==="
echo "Input:  $INPUT"
echo "Output: $OUTPUT"
echo "Script: $SCRIPT_FILE"
echo ""

# Run vspipe to check script and get info
echo "Checking script..."
/opt/homebrew/bin/vspipe --info "$SCRIPT_FILE" -

echo ""
echo "Processing (this may take a moment)..."

# Run vspipe | ffmpeg pipeline
# - Use -c y4m for Y4M container output from vspipe
# - FFV1 codec for lossless compression in AVI container
# - -level 3 for better compression
# Note: vspipe progress (-p) goes to stderr, Y4M goes to stdout
/opt/homebrew/bin/vspipe -c y4m -p "$SCRIPT_FILE" - | \
    /opt/homebrew/bin/ffmpeg -y -hide_banner -loglevel warning -stats \
    -i pipe:0 \
    -c:v ffv1 -level 3 -coder 1 -context 1 -slicecrc 1 \
    "$OUTPUT"

echo ""
echo "=== Complete ==="

# Show output file info
if [ -f "$OUTPUT" ]; then
    echo "Output file: $OUTPUT"
    ls -lh "$OUTPUT"
    echo ""
    echo "Output video info:"
    /opt/homebrew/bin/ffprobe -v quiet -show_streams -select_streams v:0 "$OUTPUT" 2>/dev/null | \
        grep -E "^(width|height|r_frame_rate|codec_name|nb_frames)" || true
else
    echo "Error: Output file was not created"
    exit 1
fi

# Cleanup
rm -rf "$TEMP_DIR"
