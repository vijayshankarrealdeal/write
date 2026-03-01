# Firebase Setup for Writer App

## 1. Enable Authentication Providers

In [Firebase Console](https://console.firebase.google.com) → **Authentication** → **Sign-in method**:

- **Email/Password**: Enable
- **Google**: Enable and add your support email

## 2. Firestore Structure

### Collections

```
users/{userId}
  - id, email, name, photoUrl
  - createdAt, updatedAt (server timestamps)
  - onboardingData: { preferredGenres[], preferredWritingTypes[], interests[] }
  - likes: string[] (feed item IDs)
  - readingList: string[]

feed_items/{feedItemId}
  - title, author, authorId, description, imageUrl
  - genres: string[] (for array-contains-any queries)
  - writingTypes: string[]
  - tags: string[]
  - createdAt (Timestamp)
  - likesCount (number)

users/{userId}/writings/{writingId}
  - title, author, description, coverImagePath, status, writingType, subtype
  - sectionIds: string[] (ordered)
  - createdAt, updatedAt (Timestamps)

users/{userId}/writings/{writingId}/sections/{sectionId}
  - title, sectionColor (int), content (Quill Delta JSON)
  - updatedAt
```

### Optimizations

- **Single document reads**: User profile + preferences + likes in one document
- **Batched writes**: Like/unlike uses transactions to update user + feed_item atomically
- **Indexed queries**: `genres` + `createdAt` and `likesCount` + `createdAt` for personalized feed
- **Writings**: Metadata in parent doc; sections in subcollection for granular updates
- **Section saves**: Only the changed section doc is updated (not the whole book)

## 3. Deploy Firestore Rules & Indexes

```bash
firebase deploy --only firestore
```

Or deploy separately:
```bash
firebase deploy --only firestore:rules
firebase deploy --only firestore:indexes
```

## 4. Android: SHA-1 for Google Sign-In

Add your debug SHA-1 in Firebase Console → Project Settings → Your apps → Android app:

```bash
cd android && ./gradlew signingReport
```

Copy the SHA-1 and add it in Firebase Console.

## 5. iOS: URL Scheme

Already configured in `ios/Runner/Info.plist` with `REVERSED_CLIENT_ID` from GoogleService-Info.plist.
