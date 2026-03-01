const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");

initializeApp();

const HOUR_MS = 3600000;

function computeRankScore(data) {
  const likes = data.likesCount || 0;
  const comments = data.commentsCount || 0;
  const engagement = Math.log2(likes + comments + 1);

  const createdAt = data.createdAt
    ? new Date(data.createdAt).getTime()
    : Date.now();
  const ageHours = (Date.now() - createdAt) / HOUR_MS;
  const freshness = Math.max(0, 1 - ageHours / 168);

  return engagement * 0.6 + freshness * 0.4;
}

exports.onFeedItemWrite = onDocumentWritten("feed_items/{itemId}", async (event) => {
  const after = event.data?.after?.data();
  if (!after) return;

  const score = computeRankScore(after);
  const current = after.rankScore;
  if (current !== undefined && Math.abs(current - score) < 0.01) return;

  await event.data.after.ref.update({
    rankScore: score,
    rankUpdatedAt: new Date().toISOString(),
  });
});

exports.batchRankUpdate = onSchedule("every 15 minutes", async () => {
  const db = getFirestore();
  const snapshot = await db.collection("feed_items").get();
  const batch = db.batch();
  let count = 0;

  for (const doc of snapshot.docs) {
    const score = computeRankScore(doc.data());
    batch.update(doc.ref, {
      rankScore: score,
      rankUpdatedAt: new Date().toISOString(),
    });
    count++;
    if (count % 500 === 0) {
      await batch.commit();
    }
  }
  if (count % 500 !== 0) {
    await batch.commit();
  }
});
