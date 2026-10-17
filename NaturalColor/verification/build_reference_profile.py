#!/usr/bin/env python3
"""Build the bounded native-fallback CbCr resource from verified decoded XML.

Run after hncs-lab/scripts/decode_table_assets.py --all. No APK, ELF, camera
matrix, or original photos are copied into the application.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import sys

import numpy as np

PROFILE_NAME = "fx77eloqamxuqijs5plh"
PROFILE_SHA256 = "cf907782ff55cd7f824159964633f03b65a125879680885a1ad736e22ce1d5ae"


def main():
    app_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lab-root", type=Path, default=app_root.parent / "hncs-lab")
    parser.add_argument("--output-dir", type=Path,
                        default=app_root / "ios/HassyNatural/Resources")
    args = parser.parse_args()
    sys.path.insert(0, str(args.lab_root.resolve()))
    from profile_resources import load_resource
    from profile_interpolation import calculate_lut

    source = args.lab_root / "artifacts/decoded-tables/Colormaps" / (PROFILE_NAME + ".xml")
    profile, source_identity = load_resource(source)
    if source_identity["sha256"] != PROFILE_SHA256:
        raise ValueError("Decoded fallback profile does not match the verified source SHA-256")
    result = calculate_lut(profile, 5000, interpolate=False, reproduction=False)
    native = result.values
    output = native.astype("<f4")
    if output.shape != (89, 105, 2) or not np.isfinite(output).all():
        raise ValueError("Reference profile does not match its verified dimensions")
    # At the native fallback's exact tf, selected values must be copied unchanged.
    np.testing.assert_array_equal(native.ravel(), profile["LUTTableFlashStd"])
    data = output.tobytes(order="C")
    sha256 = hashlib.sha256(data).hexdigest()
    metadata = {
        "schema": "hncs-reference-chroma-v1",
        "resource": "ReferenceChroma.f32",
        "format": "little endian IEEE754 float32",
        "layout": "Cr rows, Cb columns, adjacent Cb/Cr double-derived components",
        "width": 105,
        "height": 89,
        "components": 2,
        "count": int(output.size),
        "byte_count": len(data),
        "sha256": sha256,
        "bounds": {key: profile[key] for key in ("CbS", "CbE", "CrS", "CrE")},
        "start": [profile["CbS"], profile["CrS"]],
        "limits": [104, 88],
        "divisor": profile["DivFactor"],
        "kelvin": 5000,
        "profile_id": PROFILE_NAME,
        "profile_role": "native GetFileName fallback; not an iPhone sensor profile",
        "profile_version": profile["Version"],
        "profile_timestamp": profile["TimeStamp"],
        "source": "Phocus Android 1.1.0 decoded Colormaps/" + PROFILE_NAME + ".xml",
        "source_sha256": source_identity["sha256"],
        "source_library_sha256": "d757237554529f8ab485f88f2c5e5399fbc8d56035c79b8e057b41a40fd055e4",
        "source_array": "LUTTableFlashStd",
        "source_value_transform": "None; LUT numbers are not affine-decoded",
        "interpolation_policy": {
            "interpolate": False,
            "reproduction": False,
            "basis": "explicit application policy; not inferred native preference defaults",
            "selected_anchors": list(result.anchors),
            "effective_kelvin": result.kelvin,
        },
        "float32_max_absolute_quantization_error": float(np.max(np.abs(output.astype(np.float64)-native))),
        "evidence": {
            "fallback_filename_function": "CXMLLut::GetFileName VA 0x3502480",
            "table_selection_function": "CXMLLut::CalculateLUT VA 0x3504b00",
            "row_major_layout_function": "Scaled2DLUT::FromCbCrData VA 0x369a440",
        },
        "limitations": [
            "Fallback profile dated 2007 is not claimed to represent X2D or iPhone 17 Pro calibration",
            "Applying its chroma transform to phone colorimetric RGB is application adaptation",
            "Phone sensor calibration and Apple RAW preprocessing remain separate",
            "An interpolated RGB cube approximates the recovered 2D shader mapping",
            "No Phocus render equivalence or native runtime parity established",
        ],
    }
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "ReferenceChroma.f32").write_bytes(data)
    (args.output_dir / "ReferenceProfile.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps({"resource": str(args.output_dir / "ReferenceChroma.f32"),
                      "shape": list(output.shape), "byte_count": len(data), "sha256": sha256}))


if __name__ == "__main__":
    main()
