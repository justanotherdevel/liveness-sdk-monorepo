import os
import re

files = [
    "flutter-sdk/liveness_sdk/example/lib/home_screen.dart",
    "flutter-sdk/liveness_sdk/lib/src/live_face_auth.dart",
    "flutter-sdk/liveness_sdk/lib/src/ui/face_overlay_painter.dart",
    "flutter-sdk/liveness_sdk/lib/src/engines/face_extraction_engine.dart",
    "flutter-sdk/liveness_sdk/lib/src/ui/enroll_face_screen.dart",
    "flutter-sdk/liveness_sdk/lib/src/engines/passive_liveness_engine.dart",
    "flutter-sdk/liveness_sdk/lib/src/engines/face_match_engine.dart",
    "flutter-sdk/liveness_sdk/lib/src/ui/authenticate_face_screen.dart"
]

base_dir = "/home/shashwat/Programs/Yars/liveliness/liveness-sdk-monorepo"

for f in files:
    path = os.path.join(base_dir, f)
    with open(path, 'r') as fp:
        content = fp.read()
    
    modified = False
    
    if '.withOpacity(' in content:
        content = re.sub(r'\.withOpacity\((.*?)\)', r'.withValues(alpha: \1)', content)
        modified = True
        
    if re.search(r'\bprint\(', content):
        content = re.sub(r'\bprint\(', 'debugPrint(', content)
        modified = True
        
    if modified:
        if "import 'package:flutter/foundation.dart';" not in content:
            # Insert after the first import
            content = re.sub(r'(import [^\n]+;)', r"\1\nimport 'package:flutter/foundation.dart';", content, count=1)
            
        with open(path, 'w') as fp:
            fp.write(content)
            print(f"Updated {f}")

print("Done")
