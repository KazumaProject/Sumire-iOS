#!/usr/bin/env python3
"""Reject network APIs/dependencies in shipping sources. This is a static guard, not a packet audit."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIRS = ("App", "Shared", "Keyboard", "Core/Sources", "ConversionCore/src")
SOURCE_SUFFIXES = {".swift", ".m", ".mm", ".h", ".hpp", ".c", ".cpp"}
FORBIDDEN = re.compile(
    r"\b(?:URLSession|URLRequest|NSURLSession|NSURLRequest|NSURLConnection|"
    r"NWConnection|NWListener|NWBrowser|WKWebView|UIWebView|SFSafariViewController|"
    r"CKContainer|CloudKit|Firebase|Crashlytics|Sentry|Alamofire|CFHTTPMessageCreateRequest|"
    r"CFReadStreamCreateForHTTPRequest|CFStreamCreatePairWithSocketToHost)\b"
    r"|\b(?:socket|connect|sendto|getaddrinfo|curl_easy_perform)\s*\("
    r"|\bimport\s+(?:Network|WebKit|SafariServices)\b"
    r"|(?:https?|wss?|ftp)://"
)
errors = []
files = [p for directory in SOURCE_DIRS for p in (ROOT / directory).rglob("*")
         if p.suffix in SOURCE_SUFFIXES]
for path in files:
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if FORBIDDEN.search(line):
            errors.append(f"{path.relative_to(ROOT)}:{number}: network API/URL requires removal: {line.strip()}")
dependency_files = ["Core/Package.swift", "project.yml"]
generated_project = ROOT / "Sumire.xcodeproj/project.pbxproj"
if generated_project.exists():
    dependency_files.append("Sumire.xcodeproj/project.pbxproj")
for name in dependency_files:
    path = ROOT / name
    if re.search(r"https?://|XCRemoteSwiftPackageReference|repositoryURL", path.read_text()):
        errors.append(f"{name}: remote dependency is not permitted")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"Offline source check passed ({len(files)} source files; local dependencies).")
if not generated_project.exists():
    print("Generated Xcode project is absent; dependency checks cover project.yml and Core/Package.swift.")
print("Scope: source-level guard only; OS services and actual network traffic are not measured.")
