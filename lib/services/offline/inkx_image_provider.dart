/// `ImageProvider` that decrypts an image embedded in a downloaded
/// `.inkx` and hands the bytes to Flutter's image pipeline.
///
/// Use this when rendering an offline-only book: the server-side
/// packager bundles cover + inline images into the same encrypted
/// container, and the on-disk store never writes plaintext bytes
/// anywhere outside the AES-GCM chunks. This provider keeps that
/// invariant — bytes hit `instantiateImageCodec` directly without
/// touching disk in plaintext form.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'package:inkspacex/services/offline/inkx_codec.dart';
import 'package:inkspacex/services/offline/offline_library.dart';

/// A lazy resolver that opens an [InkxBook] on demand. Held by the
/// provider so two image renders for the same book share a single
/// decode + key derivation.
typedef InkxBookResolver = Future<InkxBook> Function(String bookId);

class InkxImageProvider extends ImageProvider<InkxImageProvider> {
  const InkxImageProvider({
    required this.bookId,
    required this.imageId,
    required this.resolver,
    this.scale = 1.0,
  });

  final String bookId;
  final String imageId;
  final InkxBookResolver resolver;
  final double scale;

  @override
  Future<InkxImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<InkxImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    InkxImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: key.scale,
      debugLabel: 'inkx://$bookId/$imageId',
    );
  }

  Future<ui.Codec> _loadAsync(
    InkxImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final book = await key.resolver(key.bookId);
    final bytes = await book.readImage(key.imageId);
    final buffer = await ui.ImmutableBuffer.fromUint8List(
      bytes,
    );
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) {
    return other is InkxImageProvider &&
        other.bookId == bookId &&
        other.imageId == imageId &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(bookId, imageId, scale);

  @override
  String toString() => 'InkxImageProvider(inkx://$bookId/$imageId)';
}

/// Cache the decoded [InkxBook] handle so back-to-back image renders
/// don't re-derive the AES key + re-verify the HMAC on every paint.
///
/// The cache holds the handle for the lifetime of the resolver — the
/// caller (typically [OfflineProvider]) drops the resolver on logout
/// or when the user evicts the book, which releases the byte buffer.
class InkxBookHandleCache {
  InkxBookHandleCache({
    required this.library,
    required this.licensePublicKey,
  });

  final OfflineLibrary library;
  final List<int> licensePublicKey;

  final Map<String, Future<InkxBook>> _open = {};

  Future<InkxBook> resolve(String bookId) {
    return _open.putIfAbsent(
      bookId,
      () => library.open(
        bookId: bookId,
        licensePublicKey: licensePublicKey,
      ),
    );
  }

  void invalidate(String bookId) {
    _open.remove(bookId);
  }

  void clear() {
    _open.clear();
  }
}
