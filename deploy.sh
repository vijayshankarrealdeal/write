#!/bin/bash
set -e

echo "🔨 Building Flutter web..."
flutter build web --release

echo "📝 Stamping version..."
TIMESTAMP=$(date +%s)
echo "{\"version\": \"$TIMESTAMP\"}" > build/web/version.json

echo "📋 Copying policy files..."
cp privacy_policy.html build/web/privacy_policy.html
cp terms_of_service.html build/web/terms_of_service.html

echo "🚀 Deploying to Firebase..."
npx firebase-tools deploy --only hosting

echo "✅ Deployed! Version: $TIMESTAMP"
