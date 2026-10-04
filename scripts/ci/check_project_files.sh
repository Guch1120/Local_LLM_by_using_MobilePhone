#!/usr/bin/env bash
# Every Swift source file must be registered in the Xcode project: the project is maintained by hand,
# and a file that is only on disk compiles nowhere, which shows up as "cannot find ... in scope"
# after a long macOS build. Run from the repository root.
set -euo pipefail

project="iPhoneLocalAI.xcodeproj/project.pbxproj"
missing=0
while IFS= read -r file; do
  if ! grep -q "path = $(basename "$file");" "$project"; then
    echo "::error file=$file::not registered in $project (add a file reference, a build file, the group and the target's Sources phase)"
    missing=1
  fi
done < <(git ls-files 'App/*.swift' 'Core/*.swift' 'Backends/*.swift' 'Server/*.swift' 'Tests/*.swift')

if [ "$missing" -ne 0 ]; then
  exit 1
fi
echo "All Swift files are registered in the Xcode project."
